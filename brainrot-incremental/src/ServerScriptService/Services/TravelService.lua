-- TravelService: leva jogadores de um servidor para outro (teleporte).
--
--   SendToNewMatch(players, handoff) -> ok, err   lobby/partida -> NOVA partida (servidor reservado)
--   SendToLobby(players)             -> ok, err   partida -> lobby
--   Reconnect(player)                -> ok, err   lobby -> a última partida do jogador
--
-- Regra de ouro dos dados: ANTES de teleportar, salvamos o perfil e liberamos a
-- trava de sessão (DataService.ReleaseForTeleport). Se o teleporte falhar, pegamos
-- a trava de volta (DataService.Reacquire) para o progresso continuar sendo salvo.
--
-- Os dados do grupo (quem é membro, mapa, dono...) vão para o MemoryStore, e não só
-- no TeleportData, porque o TeleportData passa pelo cliente e pode ser falsificado.

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.Config.Game)
local LobbyConfig = require(Shared.Config.Lobby)
local MapsConfig = require(Shared.Config.Maps)

local DataService = require(script.Parent:WaitForChild("DataService"))
local StateService = require(script.Parent:WaitForChild("StateService"))

local TravelService = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Mensagens para o jogador.
local MSG_STUDIO_MATCH =
	'O teleporte só funciona no jogo publicado. No Studio, mude Config.Game.StudioRole para "Match" para testar a partida.'
local MSG_STUDIO_LOBBY =
	'No Studio não existe lobby para voltar (o teleporte só funciona no jogo publicado). Para testar o lobby, mude Config.Game.StudioRole para "Lobby".'
local MSG_STUDIO_RECONNECT = "A reconexão só funciona no jogo publicado."
local MSG_NO_MATCH_PLACE = "O place da partida ainda não foi configurado (Config.Game.MatchPlaceId)."
local MSG_NO_LOBBY_PLACE = "O place do lobby ainda não foi configurado (Config.Game.LobbyPlaceId)."
local MSG_NO_PLAYERS = "Nenhum jogador para teleportar."
local MSG_BAD_MAP = "Mapa inválido."
local MSG_RESERVE_FAILED = "Não foi possível criar o servidor da partida. Tente de novo."
local MSG_HANDOFF_FAILED = "Não foi possível preparar a partida. Tente de novo."
local MSG_TELEPORT_FAILED = "O teleporte falhou. Tente de novo em instantes."
local MSG_TELEPORT_FAILED_PERSONAL = "Não foi possível teleportar você. Tente de novo."
local MSG_NO_RECONNECT = "Não há partida para reconectar."
local MSG_ALREADY_TRAVELING = "Você já está sendo teleportado."
local MSG_DATA_NOT_SAVING =
	"Não foi possível voltar a salvar seus dados depois do teleporte. Entre de novo para continuar sem perder progresso."

-- Constantes técnicas.
local RESERVE_ATTEMPTS = 3 -- tentativas de ReserveServer
local MEMORY_ATTEMPTS = 3 -- tentativas de gravar no MemoryStore
local RELEASE_TIMEOUT = 20 -- tempo máximo esperando os perfis serem liberados (s)
local INIT_FAILED_RETRIES = 3 -- novas tentativas por jogador depois de TeleportInitFailed
local INIT_FAILED_WAIT = 2 -- espera antes de tentar de novo (s)
local WATCHDOG_TIMEOUT = 60 -- se o jogador ainda está aqui depois disso, o teleporte falhou (s)
local REACQUIRE_ROUNDS = 3 -- rodadas de Reacquire (cada uma já tenta 3 vezes no DataService)
local REACQUIRE_RETRY_WAIT = 5 -- espera entre as rodadas: 5 s, 10 s...

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

-- Teleportes em andamento: [player] = {PlaceId, Options, Attempts, Token}
local pending = {}
local tokenCounter = 0
local initialized = false

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

local function isStudio()
	return RunService:IsStudio()
end

-- Filtra a lista recebida: só jogadores válidos que ainda estão no servidor, sem repetidos.
local function normalizePlayers(list)
	local result = {}
	local seen = {}
	if typeof(list) == "Instance" then
		list = { list }
	end
	if type(list) ~= "table" then
		return result
	end
	for _, player in ipairs(list) do
		if
			typeof(player) == "Instance"
			and player:IsA("Player")
			and player.Parent == Players
			and not seen[player]
		then
			seen[player] = true
			table.insert(result, player)
		end
	end
	return result
end

-- Roda fn(player) para cada jogador em paralelo e espera todos (ou o tempo acabar).
-- Devolve {[player] = resultado}.
local function runParallel(list, fn, timeout)
	local results = {}
	local remaining = #list
	for _, player in ipairs(list) do
		task.spawn(function()
			local ok, result = pcall(fn, player)
			if not ok then
				warn("[TravelService] Erro: " .. tostring(result))
				result = false
			end
			results[player] = result
			remaining -= 1
		end)
	end
	local deadline = os.clock() + timeout
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.05)
	end
	return results
end

-- Libera o perfil de todos antes do teleporte (em paralelo).
local function releaseAll(list)
	local results = runParallel(list, function(player)
		return DataService.ReleaseForTeleport(player)
	end, RELEASE_TIMEOUT)
	for _, player in ipairs(list) do
		if results[player] ~= true then
			-- Seguimos mesmo assim: o outro servidor espera a trava vencer e assume.
			warn("[TravelService] Não foi possível liberar o perfil de " .. player.Name .. " antes do teleporte.")
		end
	end
end

-- Pega a trava do perfil de volta depois de um teleporte que falhou.
-- Se não der (DataStore fora do ar ou perfil aberto em outro servidor), o DataService
-- deixaria o perfil "liberado" e SEM salvar pelo resto da sessão: tudo o que o jogador
-- ganhasse seria perdido em silêncio. Por isso tentamos algumas vezes e, se continuar
-- falhando, expulsamos com uma mensagem clara (ao entrar de novo, o perfil é carregado
-- do zero e volta a ser salvo normalmente).
local function reacquireOrKick(player)
	for round = 1, REACQUIRE_ROUNDS do
		-- Saiu do servidor ou começou outro teleporte: não há o que fazer aqui.
		if player.Parent ~= Players or pending[player] then
			return false
		end
		if DataService.Reacquire(player) then
			return true
		end
		if round < REACQUIRE_ROUNDS then
			task.wait(REACQUIRE_RETRY_WAIT * round)
		end
	end

	if player.Parent == Players and not pending[player] then
		warn("[TravelService] Não foi possível pegar a trava do perfil de " .. player.Name .. " de volta; expulsando.")
		player:Kick(MSG_DATA_NOT_SAVING)
	end
	return false
end

-- Pega a trava de volta de todos (teleporte falhou).
local function reacquireAll(list)
	runParallel(list, reacquireOrKick, RELEASE_TIMEOUT)
end

-- Marca o jogador como "teleportando" e liga um vigia: se ele ainda estiver aqui
-- depois de WATCHDOG_TIMEOUT segundos, consideramos que o teleporte falhou.
local function markPending(player, placeId, options)
	tokenCounter += 1
	local token = tokenCounter
	local previous = pending[player]
	pending[player] = {
		PlaceId = placeId,
		Options = options,
		Attempts = if previous then previous.Attempts else 0,
		Token = token,
	}

	task.delay(WATCHDOG_TIMEOUT, function()
		local entry = pending[player]
		if entry and entry.Token == token and player.Parent == Players then
			pending[player] = nil
			warn("[TravelService] Teleporte de " .. player.Name .. " não aconteceu a tempo; voltando a salvar os dados.")
			StateService.Notify(player, MSG_TELEPORT_FAILED_PERSONAL, "error")
			reacquireOrKick(player)
		end
	end)
end

-- Tenta TeleportAsync até "attempts" vezes, esperando 2 s, 4 s... entre elas.
local function teleportWithRetries(placeId, list, options)
	local attempts = math.max(1, LobbyConfig.TeleportRetries or 1)
	local lastError = nil
	for attempt = 1, attempts do
		-- Só teleporta quem ainda está no servidor.
		local present = normalizePlayers(list)
		if #present == 0 then
			return true
		end
		local ok, err = pcall(function()
			return TeleportService:TeleportAsync(placeId, present, options)
		end)
		if ok then
			return true
		end
		lastError = err
		warn(("[TravelService] TeleportAsync falhou (tentativa %d/%d): %s"):format(attempt, attempts, tostring(err)))
		if attempt < attempts then
			task.wait(2 ^ attempt) -- 2 s, 4 s, ...
		end
	end
	return false, lastError
end

-- Cria um TeleportOptions (com código de servidor reservado opcional e TeleportData).
local function makeOptions(accessCode, teleportData)
	local options = Instance.new("TeleportOptions")
	if accessCode then
		options.ReservedServerAccessCode = accessCode
	end
	if teleportData then
		options:SetTeleportData(teleportData)
	end
	return options
end

-- Teleporte completo de um grupo: libera perfis, teleporta e trata a falha total.
local function performTeleport(list, placeId, options, onTotalFailure)
	for _, player in ipairs(list) do
		markPending(player, placeId, options)
	end

	releaseAll(list)

	local ok = teleportWithRetries(placeId, list, options)
	if ok then
		return true
	end

	-- Falhou de vez: ninguém vai sair; voltamos a salvar os dados de todos.
	for _, player in ipairs(list) do
		pending[player] = nil
	end
	if onTotalFailure then
		pcall(onTotalFailure)
	end
	reacquireAll(list)
	return false
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- TravelService.SendToNewMatch(players, handoff) -> ok, err
-- handoff = {MapId, HostUserId, MaxPlayers, Privacy, Resume}
-- (completado aqui com AccessCode, PrivateServerId, Members e CreatedAt)
function TravelService.SendToNewMatch(players, handoff)
	TravelService.Init()

	if isStudio() then
		return false, MSG_STUDIO_MATCH
	end
	if type(handoff) ~= "table" then
		return false, MSG_BAD_MAP
	end
	local mapDef = MapsConfig[handoff.MapId]
	if type(handoff.MapId) ~= "string" or type(mapDef) ~= "table" or mapDef.Act == nil then
		return false, MSG_BAD_MAP
	end
	if GameConfig.MatchPlaceId == 0 then
		return false, MSG_NO_MATCH_PLACE
	end

	-- Quem já está sendo teleportado fica de fora.
	local list = {}
	for _, player in ipairs(normalizePlayers(players)) do
		if not pending[player] then
			table.insert(list, player)
		end
	end
	if #list == 0 then
		return false, MSG_NO_PLAYERS
	end

	-- 1. Reserva um servidor novo no place da partida.
	local accessCode, privateServerId
	for attempt = 1, RESERVE_ATTEMPTS do
		local ok, codeOrErr, serverId = pcall(function()
			return TeleportService:ReserveServerAsync(GameConfig.MatchPlaceId) -- versão Async (ReserveServer foi descontinuada)
		end)
		if ok and type(codeOrErr) == "string" then
			accessCode, privateServerId = codeOrErr, serverId
			break
		end
		warn(("[TravelService] ReserveServer falhou (tentativa %d/%d): %s"):format(
			attempt,
			RESERVE_ATTEMPTS,
			tostring(codeOrErr)
		))
		if attempt < RESERVE_ATTEMPTS then
			task.wait(attempt)
		end
	end
	if not accessCode or type(privateServerId) ~= "string" then
		return false, MSG_RESERVE_FAILED
	end

	-- 2. Completa os dados do grupo.
	local members = {}
	for _, player in ipairs(list) do
		table.insert(members, player.UserId)
	end
	handoff.AccessCode = accessCode
	handoff.PrivateServerId = privateServerId
	handoff.Members = members
	handoff.CreatedAt = os.time()
	if type(handoff.HostUserId) ~= "number" then
		handoff.HostUserId = list[1].UserId
	end
	if type(handoff.MaxPlayers) ~= "number" then
		handoff.MaxPlayers = LobbyConfig.MaxPlayersLimit
	end
	if type(handoff.Privacy) ~= "string" then
		handoff.Privacy = "Invite"
	end
	handoff.Resume = handoff.Resume == true

	-- 3. Grava no MemoryStore (o servidor da partida lê daqui, chave = PrivateServerId).
	local hashMap
	local stored = false
	for attempt = 1, MEMORY_ATTEMPTS do
		local ok, err = pcall(function()
			hashMap = hashMap or MemoryStoreService:GetHashMap(LobbyConfig.HandoffMapName)
			hashMap:SetAsync(privateServerId, handoff, LobbyConfig.HandoffExpiration)
		end)
		if ok then
			stored = true
			break
		end
		warn(("[TravelService] MemoryStore falhou (tentativa %d/%d): %s"):format(attempt, MEMORY_ATTEMPTS, tostring(err)))
		if attempt < MEMORY_ATTEMPTS then
			task.wait(attempt)
		end
	end
	if not stored then
		return false, MSG_HANDOFF_FAILED
	end

	-- 4. Grava a última partida no perfil de cada um (para o botão "Reconectar").
	--    Guardamos o valor antigo para desfazer se o teleporte falhar de vez.
	local previousLastMatch = {}
	for _, player in ipairs(list) do
		local profile = DataService.GetProfile(player)
		if profile then
			previousLastMatch[player] = profile.LastMatch or false
			profile.LastMatch = {
				AccessCode = accessCode,
				PrivateServerId = privateServerId,
				MapId = handoff.MapId,
				Time = os.time(),
			}
		end
	end

	-- 5. Libera os perfis e teleporta.
	local options = makeOptions(accessCode, { MapId = handoff.MapId })
	local ok = performTeleport(list, GameConfig.MatchPlaceId, options, function()
		-- Desfaz a "última partida" (essa partida nunca começou) e apaga o handoff.
		for player, previous in pairs(previousLastMatch) do
			local profile = DataService.GetProfile(player)
			if profile then
				profile.LastMatch = if previous == false then nil else previous
				DataService.SyncProfile(player)
			end
		end
		pcall(function()
			hashMap:RemoveAsync(privateServerId)
		end)
	end)

	if not ok then
		return false, MSG_TELEPORT_FAILED
	end
	return true
end

-- TravelService.SendToLobby(players) -> ok, err
-- Salva, libera e teleporta para o lobby. No Studio, expulsa com uma mensagem explicando.
function TravelService.SendToLobby(players)
	TravelService.Init()

	local list = {}
	for _, player in ipairs(normalizePlayers(players)) do
		if not pending[player] then
			table.insert(list, player)
		end
	end
	if #list == 0 then
		return false, MSG_NO_PLAYERS
	end

	-- No Studio não há lobby para onde ir: a saída (Kick) salva os dados normalmente.
	if isStudio() then
		for _, player in ipairs(list) do
			player:Kick(MSG_STUDIO_LOBBY)
		end
		return true
	end

	if GameConfig.LobbyPlaceId == 0 then
		return false, MSG_NO_LOBBY_PLACE
	end

	local options = makeOptions(nil, nil)
	local ok = performTeleport(list, GameConfig.LobbyPlaceId, options, nil)
	if not ok then
		return false, MSG_TELEPORT_FAILED
	end
	return true
end

-- TravelService.Reconnect(player) -> ok, err
-- Volta para a última partida (profile.LastMatch), se ainda estiver dentro da janela de tempo.
function TravelService.Reconnect(player)
	TravelService.Init()

	local list = normalizePlayers({ player })
	if #list == 0 then
		return false, MSG_NO_PLAYERS
	end
	if pending[player] then
		return false, MSG_ALREADY_TRAVELING
	end

	local profile = DataService.GetProfile(player)
	local lastMatch = profile and profile.LastMatch
	if type(lastMatch) ~= "table" or type(lastMatch.AccessCode) ~= "string" or lastMatch.AccessCode == "" then
		return false, MSG_NO_RECONNECT
	end
	local lastTime = tonumber(lastMatch.Time)
	if not lastTime or os.time() - lastTime >= LobbyConfig.ReconnectWindowSeconds then
		return false, MSG_NO_RECONNECT
	end

	if isStudio() then
		return false, MSG_STUDIO_RECONNECT
	end
	if GameConfig.MatchPlaceId == 0 then
		return false, MSG_NO_MATCH_PLACE
	end

	local options = makeOptions(lastMatch.AccessCode, { MapId = lastMatch.MapId })
	local ok = performTeleport(list, GameConfig.MatchPlaceId, options, nil)
	if not ok then
		return false, MSG_TELEPORT_FAILED
	end
	return true
end

-------------------------------------------------------------------------------
-- Falhas depois do teleporte começar (TeleportInitFailed)
-------------------------------------------------------------------------------

-- Tenta de novo aquele jogador até INIT_FAILED_RETRIES vezes; depois desiste,
-- pega a trava de volta e avisa o jogador.
local function onTeleportInitFailed(player, teleportResult, errorMessage, placeId, teleportOptions)
	local entry = pending[player]
	if not entry then
		return -- não foi um teleporte nosso (ou já desistimos)
	end

	-- "Já está teleportando": não é falha de verdade, só ignoramos.
	if teleportResult == Enum.TeleportResult.IsTeleporting then
		return
	end

	warn(("[TravelService] Teleporte de %s falhou (%s): %s"):format(
		player.Name,
		tostring(teleportResult),
		tostring(errorMessage)
	))

	entry.Attempts += 1
	if entry.Attempts > INIT_FAILED_RETRIES then
		pending[player] = nil
		StateService.Notify(player, MSG_TELEPORT_FAILED_PERSONAL, "error")
		reacquireOrKick(player)
		return
	end

	-- Espera um pouco (mais se o serviço estiver sobrecarregado) e tenta de novo.
	local waitTime = INIT_FAILED_WAIT * entry.Attempts
	if teleportResult == Enum.TeleportResult.Flooded then
		waitTime *= 2
	end
	task.wait(waitTime)

	if pending[player] ~= entry or player.Parent ~= Players then
		return
	end

	local options = if typeof(teleportOptions) == "Instance" then teleportOptions else entry.Options
	local targetPlace = if type(placeId) == "number" and placeId ~= 0 then placeId else entry.PlaceId
	-- Renova o vigia para esta nova tentativa.
	markPending(player, targetPlace, options)

	local ok, err = pcall(function()
		return TeleportService:TeleportAsync(targetPlace, { player }, options)
	end)
	if not ok then
		warn("[TravelService] Nova tentativa de teleporte falhou: " .. tostring(err))
		if pending[player] then
			-- A chamada nem começou, então não virá outro evento: desiste já.
			pending[player] = nil
			StateService.Notify(player, MSG_TELEPORT_FAILED_PERSONAL, "error")
			reacquireOrKick(player)
		end
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

-- Pode ser chamado mais de uma vez (as funções públicas chamam para garantir).
function TravelService.Init()
	if initialized then
		return
	end
	initialized = true

	TeleportService.TeleportInitFailed:Connect(function(...)
		local ok, err = pcall(onTeleportInitFailed, ...)
		if not ok then
			warn("[TravelService] Erro em TeleportInitFailed: " .. tostring(err))
		end
	end)

	-- Quem saiu do servidor (teleporte deu certo) não está mais pendente.
	Players.PlayerRemoving:Connect(function(player)
		pending[player] = nil
	end)
end

function TravelService.Start() end

return TravelService
