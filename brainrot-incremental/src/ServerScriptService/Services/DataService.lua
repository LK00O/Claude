-- DataService: carrega, guarda e salva o perfil (progresso permanente) de cada jogador.
--
-- Como funciona, em resumo:
--   1. O jogador entra -> lemos o registro dele no DataStore com UpdateAsync e,
--      na mesma operação, colocamos uma "trava de sessão" (Lock) com o id deste servidor.
--      A trava impede que dois servidores mexam no mesmo perfil ao mesmo tempo
--      (ex.: o jogador pula do lobby para a partida antes do lobby terminar de salvar).
--   2. Enquanto ele joga, os outros serviços mexem na tabela viva do perfil
--      (DataService.GetProfile) e chamam SyncProfile para o cliente ver a mudança.
--   3. A cada AutosaveInterval segundos salvamos (e renovamos a hora da trava).
--   4. Ao sair ou teleportar, salvamos uma última vez e tiramos a trava (Lock = nil).
--
-- Formato do registro no DataStore: { Data = perfil, Lock = { JobId = texto, Time = os.time() } }
--
-- No Studio, se o DataStore não estiver liberado, usamos um armazenamento em memória
-- (mock) com a mesma interface: dá para testar tudo, só não fica salvo de verdade.
--
-- É um serviço-folha: não dá require em outros serviços no topo do arquivo.
-- (O StateService é pego dentro das funções, pelo helper Svc.)

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.Game)
local LobbyConfig = require(Shared.Config.Lobby)
local Signal = require(Shared.Util.Signal)
local Tables = require(Shared.Util.Tables)

-- Outros serviços só são pegos dentro de funções (regra anti-require-circular).
local Services = script.Parent
local function Svc(name)
	return require(Services:WaitForChild(name))
end

local DataService = {}

-- Sinais públicos (criados já no carregamento do módulo, para quem conectar no Init).
DataService.ProfileLoaded = Signal.new() -- (player, profile)
DataService.StatChanged = Signal.new() -- (player, path, newValue)

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Template do perfil (seção 4.2 da especificação). Nunca é alterado: sempre copiamos.
local PROFILE_TEMPLATE = {
	Version = 1,
	UnlockedMaps = { Meadow = true },
	CompletedMaps = {},
	GameCompleted = false,
	Stats = {
		Kills = { Low = 0, Medium = 0, High = 0 },
		KillsTotal = 0,
		TotalCoins = 0,
		Shots = 0,
		Crits = 0,
		Chains = 0,
		Giants = 0,
		Enchanted = 0,
		Galactic = 0,
		PlayTime = 0,
		ActsCompleted = 0,
		RecipesDiscovered = 0,
		QuestsCompleted = 0,
	},
	Achievements = {},
	RecipesKnown = {},
	Settings = {
		Sensitivity = 0.5,
		InvertY = false,
		FOV = 80,
		ToggleSprint = false,
		MusicVolume = 0.5,
		SfxVolume = 0.7,
		DamageNumbers = true,
		Keybinds = {},
	},
	Tokens = 0,
	Cosmetics = { Owned = { Classic = true }, Equipped = "Classic" },
	LastMatch = nil,
	RunSaves = {},
	RunData = {},
}
local CURRENT_VERSION = PROFILE_TEMPLATE.Version

-- Prefixos das chaves no DataStore.
local PROFILE_KEY_PREFIX = "Player_"

-- Id deste servidor para a trava de sessão. No Studio o JobId é vazio,
-- então geramos um id aleatório (cada teste no Studio é um "servidor" diferente).
local SERVER_ID = if game.JobId ~= "" then game.JobId else ("Studio_" .. HttpService:GenerateGUID(false))

-- Trava de sessão (seção 4.1): se outro servidor tem a trava, espera 5 s e tenta de novo, até 6 vezes.
local LOCK_RETRY_WAIT = 5
local LOCK_RETRY_COUNT = 6

-- Constantes técnicas de tentativas em caso de erro de rede do DataStore.
local LOAD_ERROR_ATTEMPTS = 5 -- tentativas de leitura antes de desistir (e expulsar o jogador)
local SAVE_ATTEMPTS = 3 -- tentativas de gravação do perfil
local RUN_ATTEMPTS = 3 -- tentativas nas partidas salvas do time (seção 4.3)

-- Tempo máximo esperando todos salvarem ao fechar o servidor (seção 4.1).
local CLOSE_TIMEOUT = 25
-- Pequena espera antes de salvar na saída/fechamento, para que os outros serviços
-- (ex.: MatchService gravando RunData) terminem de escrever no perfil primeiro.
local REMOVE_GRACE = 0.25
local CLOSE_GRACE = 1

-- SyncProfile: no máximo 2 envios por segundo (junta chamadas seguidas).
local SYNC_INTERVAL = 0.5

-- De quanto em quanto tempo somamos o tempo de jogo (Stats.PlayTime, em segundos).
local PLAYTIME_INTERVAL = 60

-- Tempo máximo esperando o salvamento de saída anterior do mesmo jogador (reentrada rápida).
local PREVIOUS_SESSION_WAIT = 30

-- Mensagens para o jogador.
local MSG_LOAD_FAILED = "Não foi possível carregar seus dados. Tente entrar de novo."
local MSG_SESSION_STOLEN = "Seus dados foram abertos em outro servidor. Entre de novo para continuar."
local MSG_MOCK_WARNING = "[DataService] Usando dados temporários (ative Studio Access to API Services para salvar de verdade)"

-------------------------------------------------------------------------------
-- Armazenamento em memória (mock) para o Studio
-------------------------------------------------------------------------------
-- Tem os mesmos métodos que um DataStore de verdade (GetAsync, SetAsync,
-- UpdateAsync, RemoveAsync), mas guarda tudo numa tabela que some quando o teste acaba.
local MockStore = {}
MockStore.__index = MockStore

function MockStore.new()
	return setmetatable({ _data = {} }, MockStore)
end

function MockStore:GetAsync(key)
	return Tables.DeepCopy(self._data[key])
end

function MockStore:SetAsync(key, value)
	self._data[key] = Tables.DeepCopy(value)
end

function MockStore:UpdateAsync(key, transform)
	-- Igual ao DataStore: a função recebe uma cópia do valor antigo;
	-- se ela devolver nil, nada é gravado.
	local newValue = transform(Tables.DeepCopy(self._data[key]))
	if newValue ~= nil then
		self._data[key] = Tables.DeepCopy(newValue)
	end
	return Tables.DeepCopy(newValue)
end

function MockStore:RemoveAsync(key)
	local old = self._data[key]
	self._data[key] = nil
	return old
end

-------------------------------------------------------------------------------
-- Escolha do armazenamento (DataStore de verdade ou mock)
-------------------------------------------------------------------------------

local useMock = false -- true = usando o armazenamento em memória
local backendState = "idle" -- "idle" -> "resolving" -> "ready"
local stores = {} -- [nome do DataStore] = store (cache)

-- Decide qual armazenamento usar. No Studio testamos se o DataStore funciona;
-- se não funcionar (API desligada ou place não publicado), usamos o mock.
local function resolveBackend()
	if not RunService:IsStudio() then
		useMock = false
		return
	end

	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(GameConfig.DataStoreName)
	end)
	if ok and store then
		-- Uma leitura de teste: com a API desligada no Studio ela dá erro.
		ok = pcall(function()
			return store:GetAsync("__DataServiceProbe")
		end)
	end

	if not ok then
		useMock = true
		warn(MSG_MOCK_WARNING)
	end
end

-- Garante que o armazenamento já foi escolhido (espera se outra thread está escolhendo).
local function ensureBackend()
	if backendState == "ready" then
		return
	end
	if backendState == "idle" then
		backendState = "resolving"
		local ok, err = pcall(resolveBackend)
		if not ok then
			warn("[DataService] Erro ao preparar o armazenamento: " .. tostring(err))
			if RunService:IsStudio() then
				useMock = true
				warn(MSG_MOCK_WARNING)
			end
		end
		backendState = "ready"
		return
	end
	while backendState ~= "ready" do
		task.wait(0.05)
	end
end

-- Devolve o store com esse nome (cria na primeira vez). Dá erro se não conseguir,
-- por isso é sempre chamado dentro de pcall.
local function getStore(name)
	ensureBackend()
	local store = stores[name]
	if store then
		return store
	end
	if useMock then
		store = MockStore.new()
	else
		store = DataStoreService:GetDataStore(name)
	end
	stores[name] = store
	return store
end

-------------------------------------------------------------------------------
-- Ajudantes de dados
-------------------------------------------------------------------------------

-- Números que o DataStore não aceita (NaN e infinito) viram números válidos.
local MAX_STORE_NUMBER = 1e308

-- Faz uma cópia "limpa" para gravar: tira funções, Instances e outros tipos que
-- o DataStore não aceita, e conserta números inválidos.
local function sanitizeForStore(value, seen)
	local kind = type(value)
	if kind == "number" then
		if value ~= value then
			return 0 -- NaN
		end
		return math.clamp(value, -MAX_STORE_NUMBER, MAX_STORE_NUMBER)
	elseif kind == "string" or kind == "boolean" then
		return value
	elseif kind == "table" then
		seen = seen or {}
		if seen[value] then
			return nil -- tabela que aponta para ela mesma: corta o ciclo
		end
		seen[value] = true
		local copy = {}
		for key, inner in pairs(value) do
			local keyKind = type(key)
			if keyKind == "string" or keyKind == "number" then
				local cleaned = sanitizeForStore(inner, seen)
				if cleaned ~= nil then
					copy[key] = cleaned
				end
			end
		end
		seen[value] = nil
		return copy
	end
	return nil
end

-- Conserta campos com o tipo errado (ex.: Stats virou número por algum bug):
-- se o template diz "tabela" e o perfil tem outra coisa, volta para o padrão.
-- Não apaga chaves extras nem mexe em valores com o tipo certo.
local function repairTypes(target, template)
	for key, templateValue in pairs(template) do
		local current = target[key]
		if current ~= nil and type(current) ~= type(templateValue) then
			target[key] = Tables.DeepCopy(templateValue)
		elseif type(current) == "table" and type(templateValue) == "table" then
			repairTypes(current, templateValue)
		end
	end
end

-- Prepara um perfil carregado: preenche chaves novas do template (reconcile),
-- conserta tipos e atualiza a versão.
local function prepareProfile(data)
	local profile = if type(data) == "table" then data else Tables.DeepCopy(PROFILE_TEMPLATE)

	-- Chaves novas do template entram em perfis antigos, sem apagar nada.
	Tables.Reconcile(profile, PROFILE_TEMPLATE)
	repairTypes(profile, PROFILE_TEMPLATE)

	-- LastMatch pode não existir (nil); se existir com formato estranho, descarta.
	if profile.LastMatch ~= nil and type(profile.LastMatch) ~= "table" then
		profile.LastMatch = nil
	end

	-- Migrações futuras entram aqui (ex.: if profile.Version < 2 then ... end).
	if type(profile.Version) ~= "number" or profile.Version < CURRENT_VERSION then
		profile.Version = CURRENT_VERSION
	end

	-- A skin clássica é de graça: todo mundo tem.
	profile.Cosmetics.Owned.Classic = true
	if type(profile.Cosmetics.Equipped) ~= "string" then
		profile.Cosmetics.Equipped = "Classic"
	end

	return profile
end

-- Lê o registro cru do DataStore no formato {Data, Lock}.
-- Aceita também um perfil "solto" antigo (sem Data/Lock) e trata como Data.
local function normalizeRecord(old)
	if type(old) ~= "table" then
		return { Data = nil, Lock = nil }
	end
	if old.Data ~= nil or old.Lock ~= nil then
		return {
			Data = if type(old.Data) == "table" then old.Data else nil,
			Lock = if type(old.Lock) == "table" then old.Lock else nil,
		}
	end
	return { Data = old, Lock = nil }
end

-- A trava é de OUTRO servidor e ainda está "fresca" (menos de SessionLockTimeout segundos)?
local function isForeignLockActive(lock)
	if type(lock) ~= "table" or lock.JobId == SERVER_ID then
		return false
	end
	local lockTime = tonumber(lock.Time) or 0
	return os.time() - lockTime < GameConfig.SessionLockTimeout
end

-- A trava existe e é de outro servidor (fresca ou não)?
local function isForeignLock(lock)
	return type(lock) == "table" and lock.JobId ~= nil and lock.JobId ~= SERVER_ID
end

-- Uma trava nova deste servidor, com a hora atual.
local function newLock()
	return { JobId = SERVER_ID, Time = os.time() }
end

-------------------------------------------------------------------------------
-- Sessões (um perfil carregado por jogador)
-------------------------------------------------------------------------------
-- sessions[player] = {
--   Player, UserId, Key,
--   Profile = tabela viva | nil (ainda carregando),
--   Loading = boolean,           -- carregamento em andamento
--   Failed = boolean,            -- não conseguiu carregar (jogador expulso)
--   Removed = boolean,           -- o jogador saiu do servidor
--   Released = boolean,          -- trava liberada (teleporte/saída): não salva mais
--   ReleaseRequested = boolean,  -- pediram para liberar enquanto ainda carregava
--   Saving = boolean,            -- "cadeado" para não gravar duas vezes ao mesmo tempo
--   FinalState = nil | "running" | "done",  -- salvamento final (saída/fechamento)
--   PlayTimeMark = os.clock() da última soma de tempo de jogo,
-- }
local sessions = {}

-- Usuários cujo salvamento de saída ainda está rodando: [userId] = número de saídas pendentes.
-- Se o mesmo jogador entrar de novo muito rápido, esperamos isso terminar.
local releasingUserIds = {}

-- Controle do SyncProfile: [player] = {Last = os.clock(), Scheduled = boolean}.
local syncInfo = {}

local initialized = false
local shuttingDown = false

-- Espera o "cadeado" de gravação da sessão ficar livre e o pega.
local function lockSaving(session)
	while session.Saving do
		task.wait(0.05)
	end
	session.Saving = true
end

local function unlockSaving(session)
	session.Saving = false
end

-- Soma no Stats.PlayTime os segundos jogados desde a última soma.
-- "silent" = não dispara sinais nem sync (usado na saída do jogador).
local function accruePlayTime(session, silent)
	if not session.Profile or session.Released then
		return
	end
	local nowClock = os.clock()
	local elapsed = math.floor(nowClock - session.PlayTimeMark)
	if elapsed <= 0 then
		return
	end
	-- Guarda a sobra (fração de segundo) para a próxima soma.
	session.PlayTimeMark += elapsed
	if silent then
		local stats = session.Profile.Stats
		stats.PlayTime = (tonumber(stats.PlayTime) or 0) + elapsed
	else
		DataService.IncrementStat(session.Player, "PlayTime", elapsed)
	end
end

-- Grava o perfil da sessão no DataStore (com tentativas).
-- releaseLock = true grava Lock = nil (saída/teleporte).
-- Devolve true se gravou. Se outro servidor pegou a trava, não sobrescreve nada.
-- Quem chama deve estar segurando o cadeado (lockSaving).
local function writeSession(session, releaseLock)
	local profile = session.Profile
	if not profile then
		return false
	end

	-- Foto do perfil tirada agora (o jogo continua mexendo na tabela viva).
	local snapshot = sanitizeForStore(profile)

	for attempt = 1, SAVE_ATTEMPTS do
		local lostLock = false
		local ok, err = pcall(function()
			local store = getStore(GameConfig.DataStoreName)
			store:UpdateAsync(session.Key, function(old)
				lostLock = false
				local record = normalizeRecord(old)
				-- Outro servidor assumiu a trava depois de nós: não sobrescreve.
				if isForeignLock(record.Lock) then
					lostLock = true
					return nil
				end
				return {
					Data = snapshot,
					Lock = if releaseLock then nil else newLock(),
				}
			end)
		end)

		if ok then
			if lostLock then
				-- Perdemos a sessão: paramos de salvar este perfil aqui.
				warn(("[DataService] A trava do jogador %d foi assumida por outro servidor."):format(session.UserId))
				session.Released = true
				local player = session.Player
				if not session.Removed and player.Parent == Players then
					player:Kick(MSG_SESSION_STOLEN)
				end
				return false
			end
			return true
		end

		warn(("[DataService] Falha ao salvar o jogador %d (tentativa %d/%d): %s"):format(
			session.UserId,
			attempt,
			SAVE_ATTEMPTS,
			tostring(err)
		))
		if attempt < SAVE_ATTEMPTS then
			task.wait(attempt)
		end
	end
	return false
end

-- Tenta pegar a trava e ler o perfil numa única operação (UpdateAsync).
-- force = true assume a trava mesmo se outro servidor tiver.
-- Devolve: "ok", data | "locked" | "error", mensagem
local function tryAcquire(key, force)
	local lockedByOther = false
	local loadedData = nil

	local ok, err = pcall(function()
		local store = getStore(GameConfig.DataStoreName)
		store:UpdateAsync(key, function(old)
			-- (A função pode rodar mais de uma vez; por isso zeramos as variáveis aqui.)
			lockedByOther = false
			loadedData = nil

			local record = normalizeRecord(old)
			if not force and isForeignLockActive(record.Lock) then
				lockedByOther = true
				return nil -- não grava nada
			end

			loadedData = record.Data
			return {
				Data = record.Data,
				Lock = newLock(),
			}
		end)
	end)

	if not ok then
		return "error", tostring(err)
	end
	if lockedByOther then
		return "locked"
	end
	return "ok", loadedData
end

-- Salvamento final da sessão (saída do jogador ou servidor fechando): grava e libera a trava.
-- Pode ser chamado por várias threads: só a primeira grava, as outras esperam ela terminar.
local function finalRelease(session)
	if session.FinalState == "done" then
		return
	end
	if session.FinalState == "running" then
		local deadline = os.clock() + CLOSE_TIMEOUT
		while session.FinalState == "running" and os.clock() < deadline do
			task.wait(0.05)
		end
		return
	end

	session.FinalState = "running"
	releasingUserIds[session.UserId] = (releasingUserIds[session.UserId] or 0) + 1

	local ok, err = pcall(function()
		lockSaving(session)
		local innerOk, innerErr = pcall(function()
			if session.Profile and not session.Released then
				accruePlayTime(session, true)
				writeSession(session, true)
				session.Released = true
			end
		end)
		unlockSaving(session)
		if not innerOk then
			error(innerErr, 0)
		end
	end)
	if not ok then
		warn("[DataService] Erro no salvamento final: " .. tostring(err))
	end

	local pending = (releasingUserIds[session.UserId] or 1) - 1
	releasingUserIds[session.UserId] = if pending > 0 then pending else nil
	session.FinalState = "done"
end

-- Remove a sessão da lista, se ela ainda for a atual daquele jogador.
local function dropSession(session)
	if sessions[session.Player] == session then
		sessions[session.Player] = nil
	end
	syncInfo[session.Player] = nil
end

-------------------------------------------------------------------------------
-- Carregamento
-------------------------------------------------------------------------------

local function loadPlayer(player)
	if sessions[player] then
		return -- já carregando/carregado
	end

	local session = {
		Player = player,
		UserId = player.UserId,
		Key = PROFILE_KEY_PREFIX .. player.UserId,
		Profile = nil,
		Loading = true,
		Failed = false,
		Removed = false,
		Released = false,
		ReleaseRequested = false,
		Saving = false,
		FinalState = nil,
		PlayTimeMark = os.clock(),
	}
	sessions[player] = session

	-- Se este mesmo jogador acabou de sair deste servidor, espera o salvamento de saída terminar.
	local waitDeadline = os.clock() + PREVIOUS_SESSION_WAIT
	while releasingUserIds[session.UserId] and os.clock() < waitDeadline do
		task.wait(0.1)
	end

	-- Tenta pegar a trava e ler o perfil.
	local lockWaits = 0
	local errorCount = 0
	local loadedData = nil
	local loaded = false

	while not session.Removed and player.Parent == Players do
		-- Depois de esperar LOCK_RETRY_COUNT vezes, assume a trava (o outro servidor provavelmente caiu).
		local force = lockWaits >= LOCK_RETRY_COUNT
		local status, result = tryAcquire(session.Key, force)

		if status == "ok" then
			loadedData = result
			loaded = true
			break
		elseif status == "locked" then
			lockWaits += 1
			task.wait(LOCK_RETRY_WAIT)
		else
			errorCount += 1
			warn(("[DataService] Falha ao carregar o jogador %d (tentativa %d/%d): %s"):format(
				session.UserId,
				errorCount,
				LOAD_ERROR_ATTEMPTS,
				tostring(result)
			))
			if errorCount >= LOAD_ERROR_ATTEMPTS then
				break
			end
			task.wait(math.min(2 ^ errorCount, 8))
		end
	end

	session.Loading = false

	if not loaded then
		-- Não carregou: se ele ainda está aqui, expulsa com uma mensagem clara.
		session.Failed = true
		if not session.Removed and player.Parent == Players then
			player:Kick(MSG_LOAD_FAILED)
		end
		if session.Removed then
			dropSession(session)
		end
		return
	end

	session.Profile = prepareProfile(loadedData)
	session.PlayTimeMark = os.clock()

	-- O jogador saiu durante o carregamento: devolve a trava na hora e esquece a sessão.
	if session.Removed or player.Parent ~= Players then
		session.Removed = true
		finalRelease(session)
		dropSession(session)
		return
	end

	-- Pediram para liberar (teleporte) enquanto carregava: libera agora, mas mantém a
	-- tabela em memória para quem precisar ler (e para Reacquire, se o teleporte falhar).
	if session.ReleaseRequested then
		lockSaving(session)
		pcall(writeSession, session, true)
		unlockSaving(session)
		session.Released = true
	end

	-- Manda a visão do perfil para o cliente já, sem esperar o limite de frequência.
	DataService.SyncProfile(player)
	DataService.ProfileLoaded:Fire(player, session.Profile)
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- DataService.GetProfile(player) -> profile | nil (a tabela viva)
function DataService.GetProfile(player)
	local session = sessions[player]
	return session and session.Profile or nil
end

-- DataService.WaitForProfile(player, timeout?) -> profile | nil (espera até 30 s por padrão)
function DataService.WaitForProfile(player, timeout)
	timeout = tonumber(timeout)
	if not timeout or timeout ~= timeout or timeout < 0 then
		timeout = 30
	end

	local deadline = os.clock() + timeout
	while true do
		local session = sessions[player]
		if session then
			if session.Profile then
				return session.Profile
			end
			if session.Failed then
				return nil
			end
		end
		if typeof(player) ~= "Instance" or player.Parent ~= Players then
			return nil
		end
		if os.clock() >= deadline then
			return nil
		end
		task.wait(0.1)
	end
end

-- DataService.Save(player) -> boolean (espera terminar)
function DataService.Save(player)
	local session = sessions[player]
	if not session or not session.Profile or session.Released then
		return false
	end

	lockSaving(session)
	local ok, result = pcall(function()
		-- Pode ter sido liberado enquanto esperávamos o cadeado.
		if session.Released then
			return false
		end
		return writeSession(session, false)
	end)
	unlockSaving(session)

	if not ok then
		warn("[DataService] Erro ao salvar: " .. tostring(result))
		return false
	end
	return result == true
end

-- DataService.ReleaseForTeleport(player) -> boolean
-- Salva e libera a trava antes do teleporte. Depois disso o autosave e a saída
-- do jogador não gravam mais por cima (o outro servidor é quem manda no perfil).
function DataService.ReleaseForTeleport(player)
	local session = sessions[player]
	if not session then
		return false
	end
	if session.Released then
		return true
	end

	-- Ainda carregando: marca para liberar assim que terminar de carregar.
	if not session.Profile then
		if session.Loading then
			session.ReleaseRequested = true
			return true
		end
		return false
	end

	-- Marca como liberado ANTES de gravar, para o autosave não renovar a trava no meio.
	accruePlayTime(session, true)
	session.Released = true

	lockSaving(session)
	local ok, result = pcall(writeSession, session, true)
	unlockSaving(session)

	if not ok then
		warn("[DataService] Erro ao liberar para teleporte: " .. tostring(result))
		return false
	end
	return result == true
end

-- DataService.Reacquire(player) -> boolean
-- O teleporte falhou: pega a trava de novo e volta a salvar normalmente.
function DataService.Reacquire(player)
	local session = sessions[player]
	if not session or session.Removed or player.Parent ~= Players then
		return false
	end

	-- Ainda carregando: basta cancelar o pedido de liberação.
	if not session.Profile then
		session.ReleaseRequested = false
		return session.Loading
	end

	if not session.Released then
		return true
	end

	lockSaving(session)
	local ok, result = pcall(function()
		local snapshot = sanitizeForStore(session.Profile)
		for attempt = 1, SAVE_ATTEMPTS do
			local blocked = false
			local callOk, err = pcall(function()
				local store = getStore(GameConfig.DataStoreName)
				store:UpdateAsync(session.Key, function(old)
					blocked = false
					local record = normalizeRecord(old)
					-- Outro servidor está usando o perfil de verdade: não mexe.
					if isForeignLockActive(record.Lock) then
						blocked = true
						return nil
					end
					return { Data = snapshot, Lock = newLock() }
				end)
			end)
			if callOk then
				return not blocked
			end
			warn(("[DataService] Falha ao pegar a trava de novo (tentativa %d/%d): %s"):format(
				attempt,
				SAVE_ATTEMPTS,
				tostring(err)
			))
			if attempt < SAVE_ATTEMPTS then
				task.wait(attempt)
			end
		end
		return false
	end)
	unlockSaving(session)

	if ok and result == true then
		session.Released = false
		session.ReleaseRequested = false
		session.PlayTimeMark = os.clock()
		return true
	end
	if not ok then
		warn("[DataService] Erro ao pegar a trava de novo: " .. tostring(result))
	end
	return false
end

-- DataService.BuildClientView(profile) -> cópia só com o que o cliente pode ver.
-- NÃO manda RunData nem o AccessCode da última partida.
function DataService.BuildClientView(profile)
	if type(profile) ~= "table" then
		return nil
	end

	local view = {
		UnlockedMaps = Tables.DeepCopy(profile.UnlockedMaps),
		CompletedMaps = Tables.DeepCopy(profile.CompletedMaps),
		GameCompleted = profile.GameCompleted == true,
		Stats = Tables.DeepCopy(profile.Stats),
		Achievements = Tables.DeepCopy(profile.Achievements),
		RecipesKnown = Tables.DeepCopy(profile.RecipesKnown),
		Settings = Tables.DeepCopy(profile.Settings),
		Tokens = profile.Tokens,
		Cosmetics = Tables.DeepCopy(profile.Cosmetics),
		RunSaves = Tables.DeepCopy(profile.RunSaves),
		CanReconnect = false,
		LastMatchMap = nil,
	}

	-- Reconexão: existe uma última partida com código de acesso e dentro da janela de tempo.
	local lastMatch = profile.LastMatch
	if type(lastMatch) == "table" then
		if type(lastMatch.MapId) == "string" then
			view.LastMatchMap = lastMatch.MapId
		end
		local lastTime = tonumber(lastMatch.Time)
		if
			type(lastMatch.AccessCode) == "string"
			and lastMatch.AccessCode ~= ""
			and lastTime
			and os.time() - lastTime < LobbyConfig.ReconnectWindowSeconds
		then
			view.CanReconnect = true
		end
	end

	return view
end

-- Envia de fato a visão do perfil para o cliente (via StateService).
local function sendProfile(player, info)
	-- Se o controle foi apagado (jogador saiu), não faz nada.
	if syncInfo[player] ~= info then
		return
	end
	info.Scheduled = false
	info.Last = os.clock()

	local session = sessions[player]
	if not session or not session.Profile or player.Parent ~= Players then
		return
	end
	Svc("StateService").Set(player, "Profile", DataService.BuildClientView(session.Profile))
end

-- DataService.SyncProfile(player): manda o perfil para o cliente, no máximo 2 vezes por segundo.
-- Chamadas seguidas são juntadas num envio só (que leva o estado mais novo).
function DataService.SyncProfile(player)
	local session = sessions[player]
	if not session or not session.Profile then
		return
	end

	local info = syncInfo[player]
	if not info then
		info = { Last = -math.huge, Scheduled = false }
		syncInfo[player] = info
	end
	if info.Scheduled then
		return -- já tem um envio marcado; ele vai levar esta mudança junto
	end

	local elapsed = os.clock() - info.Last
	if elapsed >= SYNC_INTERVAL then
		sendProfile(player, info)
	else
		info.Scheduled = true
		task.delay(SYNC_INTERVAL - elapsed, sendProfile, player, info)
	end
end

-- DataService.IncrementStat(player, path, amount) -> novo valor | nil
-- path com ponto para subtabelas: "Kills.Low", "TotalCoins", "PlayTime"...
function DataService.IncrementStat(player, path, amount)
	local profile = DataService.GetProfile(player)
	if not profile then
		return nil
	end
	if type(path) ~= "string" or path == "" then
		warn("[DataService] IncrementStat com caminho inválido: " .. tostring(path))
		return nil
	end
	amount = tonumber(amount) or 0
	if amount ~= amount or amount == math.huge or amount == -math.huge then
		warn("[DataService] IncrementStat com quantidade inválida em " .. path)
		return nil
	end

	-- Anda pelas subtabelas de Stats seguindo o caminho.
	local parts = string.split(path, ".")
	local node = profile.Stats
	for index = 1, #parts - 1 do
		local part = parts[index]
		local child = node[part]
		if child == nil then
			child = {}
			node[part] = child
		elseif type(child) ~= "table" then
			warn("[DataService] IncrementStat: '" .. path .. "' não é um caminho válido em Stats")
			return nil
		end
		node = child
	end

	local leaf = parts[#parts]
	local current = node[leaf]
	if current ~= nil and type(current) ~= "number" then
		warn("[DataService] IncrementStat: '" .. path .. "' não é um número em Stats")
		return nil
	end
	local newValue = (current or 0) + amount
	node[leaf] = newValue

	DataService.StatChanged:Fire(player, path, newValue)
	DataService.SyncProfile(player)
	return newValue
end

-- Executa uma operação no DataStore das partidas com até RUN_ATTEMPTS tentativas.
local function runStoreCall(label, key, fn)
	for attempt = 1, RUN_ATTEMPTS do
		local ok, result = pcall(function()
			return fn(getStore(GameConfig.RunStoreName))
		end)
		if ok then
			return true, result
		end
		warn(("[DataService] %s('%s') falhou (tentativa %d/%d): %s"):format(
			label,
			key,
			attempt,
			RUN_ATTEMPTS,
			tostring(result)
		))
		if attempt < RUN_ATTEMPTS then
			task.wait(attempt)
		end
	end
	return false, nil
end

-- DataService.LoadRun(key) -> table | nil (partida salva do time)
function DataService.LoadRun(key)
	if type(key) ~= "string" or key == "" then
		return nil
	end
	local ok, value = runStoreCall("LoadRun", key, function(store)
		return store:GetAsync(key)
	end)
	if ok and type(value) == "table" then
		return value
	end
	return nil
end

-- DataService.SaveRun(key, data) -> boolean
function DataService.SaveRun(key, data)
	if type(key) ~= "string" or key == "" or type(data) ~= "table" then
		return false
	end
	local snapshot = sanitizeForStore(data)
	local ok = runStoreCall("SaveRun", key, function(store)
		store:SetAsync(key, snapshot)
		return true
	end)
	return ok
end

-- DataService.DeleteRun(key) -> boolean
function DataService.DeleteRun(key)
	if type(key) ~= "string" or key == "" then
		return false
	end
	local ok = runStoreCall("DeleteRun", key, function(store)
		store:RemoveAsync(key)
		return true
	end)
	return ok
end

-------------------------------------------------------------------------------
-- Eventos de jogadores, autosave e fechamento
-------------------------------------------------------------------------------

local function onPlayerAdded(player)
	if shuttingDown then
		return
	end
	local ok, err = pcall(loadPlayer, player)
	if not ok then
		warn("[DataService] Erro ao carregar o jogador " .. player.Name .. ": " .. tostring(err))
		local session = sessions[player]
		if session and not session.Profile then
			session.Loading = false
			session.Failed = true
			if player.Parent == Players then
				player:Kick(MSG_LOAD_FAILED)
			else
				dropSession(session)
			end
		end
	end
end

local function onPlayerRemoving(player)
	local session = sessions[player]
	syncInfo[player] = nil
	if not session then
		return
	end
	session.Removed = true

	if session.Profile then
		-- Dá um instante para os outros serviços gravarem no perfil (ex.: RunData).
		task.wait(REMOVE_GRACE)
		finalRelease(session)
		dropSession(session)
	elseif not session.Loading then
		-- Falhou ao carregar: não há nada para salvar.
		dropSession(session)
	end
	-- Se ainda está carregando, o próprio loadPlayer libera a trava e limpa ao terminar.
end

-- Autosave: salva todos os perfis carregados (e renova a hora da trava).
local function autosaveAll()
	local list = {}
	for _, session in pairs(sessions) do
		if session.Profile and not session.Released and not session.Removed then
			table.insert(list, session)
		end
	end
	if #list == 0 then
		return
	end

	-- Espalha os salvamentos ao longo de alguns segundos para não pesar tudo de uma vez.
	local spacing = math.min(1, (GameConfig.AutosaveInterval * 0.5) / #list)
	for _, session in ipairs(list) do
		task.spawn(function()
			if session.Released or session.Removed then
				return
			end
			lockSaving(session)
			local ok, err = pcall(function()
				if not session.Released then
					writeSession(session, false)
				end
			end)
			unlockSaving(session)
			if not ok then
				warn("[DataService] Erro no autosave: " .. tostring(err))
			end
		end)
		task.wait(spacing)
	end
end

-- Soma o tempo de jogo de todos (a cada minuto).
local function accrueAllPlayTime()
	for _, session in pairs(sessions) do
		if session.Profile and not session.Released and not session.Removed then
			local ok, err = pcall(accruePlayTime, session, false)
			if not ok then
				warn("[DataService] Erro ao somar tempo de jogo: " .. tostring(err))
			end
		end
	end
end

-- Servidor fechando: salva todo mundo em paralelo e espera até 25 s.
local function onClose()
	shuttingDown = true
	task.wait(CLOSE_GRACE)

	local pending = 0
	for _, session in pairs(sessions) do
		if session.Profile and not session.Released then
			pending += 1
			task.spawn(function()
				local ok, err = pcall(finalRelease, session)
				if not ok then
					warn("[DataService] Erro ao salvar no fechamento: " .. tostring(err))
				end
				pending -= 1
			end)
		end
	end

	local deadline = os.clock() + CLOSE_TIMEOUT
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function DataService.Init()
	if initialized then
		return
	end
	initialized = true

	-- Escolhe o armazenamento em segundo plano (pode demorar um pouco no Studio).
	task.spawn(ensureBackend)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	-- Jogadores que entraram antes deste código rodar.
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	game:BindToClose(onClose)

	-- Autosave periódico.
	task.spawn(function()
		while true do
			task.wait(GameConfig.AutosaveInterval)
			if shuttingDown then
				break
			end
			local ok, err = pcall(autosaveAll)
			if not ok then
				warn("[DataService] Erro no autosave: " .. tostring(err))
			end
		end
	end)

	-- Tempo de jogo: soma a cada minuto.
	task.spawn(function()
		while true do
			task.wait(PLAYTIME_INTERVAL)
			if shuttingDown then
				break
			end
			accrueAllPlayTime()
		end
	end)
end

function DataService.Start() end

return DataService
