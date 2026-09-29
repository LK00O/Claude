-- TravelService: leva jogadores de um servidor para outro (teleporte).
--
--   SendToNewMatch(players, handoff) -> ok, err   lobby/partida -> NOVA partida (servidor reservado)
--   SendToLobby(players)             -> ok, err   partida -> lobby
--   Reconnect(player)                -> ok, err   lobby -> a última partida do jogador
--   SetStudioMatchSwitch(fn)                       só no Studio: liga a troca lobby -> partida
--                                                  no MESMO servidor (o Main registra fn)
--
-- No Studio o teleporte não funciona. Então, com o papel "Lobby" e a troca registrada
-- (Config.Game.StudioInPlaceMatch), SendToNewMatch não teleporta: agenda a troca
-- (task.defer) e o servidor de teste vira a partida do mapa escolhido. Nesse caminho
-- nada vai para o MemoryStore, o LastMatch não é gravado e nenhum perfil é liberado.
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
local PlaceRole = require(Shared.Util.PlaceRole)

local DataService = require(script.Parent:WaitForChild("DataService"))
local StateService = require(script.Parent:WaitForChild("StateService"))

local TravelService = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Mensagens para o jogador.
-- Studio sem a troca no mesmo servidor (Config.Game.StudioInPlaceMatch = false).
local MSG_STUDIO_MATCH =
	'No Studio o teleporte não funciona. Para testar a partida, deixe Config.Game.StudioInPlaceMatch = true (o grupo vira a partida neste mesmo servidor) ou mude Config.Game.StudioRole para "Match".'
-- Studio, já dentro da partida: o próximo ato não abre no mesmo servidor.
local MSG_STUDIO_NEXT_ACT =
	"No Studio o próximo ato não abre no mesmo servidor. Pare o teste e dê Play de novo; no lobby use /unlockall e escolha o mapa."
-- Studio: a troca para a partida já foi pedida (outro grupo chegou primeiro).
local MSG_STUDIO_SWITCHING = "A partida de teste já está sendo preparada neste servidor. Aguarde."
-- Studio: não existe lobby para onde voltar (o teste acaba com um Kick).
local MSG_STUDIO_LOBBY = "Fim do teste no Studio: pare e dê Play de novo para voltar ao lobby."
-- Studio: não existe servidor reservado para reconectar.
local MSG_STUDIO_RECONNECT =
	"No Studio não dá para reconectar a uma partida. Crie um grupo e clique em Iniciar: a partida abre neste mesmo servidor."
local MSG_NO_MATCH_PLACE = "O place da partida ainda não foi configurado (Config.Game.MatchPlaceId)."
local MSG_NO_LOBBY_PLACE = "O place do lobby ainda não foi configurado (Config.Game.LobbyPlaceId)."
local MSG_ALREADY_LOBBY_PLACE =
	"Este servidor já está no place do lobby (Config.Game.LobbyPlaceId). O teleporte foi cancelado para não entrar em loop."
local MSG_SAME_PLACE_IDS =
	"Config.Game.LobbyPlaceId e MatchPlaceId estão iguais. Corrija os PlaceIds para as partidas funcionarem."
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

-- Só no Studio: função do Main que transforma este servidor de lobby em partida
-- (SetStudioMatchSwitch). nil = troca desligada (StudioInPlaceMatch = false ou não é lobby).
local studioMatchSwitch = nil
-- A troca já foi agendada? Ela acontece uma vez só por sessão de teste.
local studioSwitchQueued = false

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

local function isStudio()
	return RunService:IsStudio()
end

-- Papel atual do servidor ("Lobby" ou "Match"). O Main grava no atributo "Role" do
-- Workspace (e muda para "Match" depois da troca no Studio); se o atributo ainda não
-- existe, pergunta ao PlaceRole.
local function currentRole()
	local role = workspace:GetAttribute("Role")
	if role == "Lobby" or role == "Match" then
		return role
	end
	local ok, result = pcall(PlaceRole.Get)
	if ok and (result == "Lobby" or result == "Match") then
		return result
	end
	return "Lobby"
end

-- Mapa que pode virar partida: existe em Config.Maps, tem Act e não é o lobby.
local function isPlayableMap(mapId)
	if type(mapId) ~= "string" or mapId == "Lobby" then
		return false
	end
	local mapDef = MapsConfig[mapId]
	return type(mapDef) == "table" and mapDef.Act ~= nil
end

-- Config errado: lobby e partida com o mesmo PlaceId (0 = ainda não configurado).
-- O PlaceRole trata esse servidor como lobby, então teleportar "para a partida"
-- só levaria o grupo para outro lobby. Recusamos o teleporte com um aviso claro.
local function hasSamePlaceIds()
	return GameConfig.LobbyPlaceId ~= 0 and GameConfig.LobbyPlaceId == GameConfig.MatchPlaceId
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

-- Só no Studio: agenda a troca lobby -> partida no mesmo servidor (sem teleporte).
-- O handoff de teste é uma tabela NOVA (a do chamador não é mexida), no formato que o
-- MatchService lê em MatchService.StudioHandoff:
--   Members = nil (todos os jogadores do servidor entram), sem AccessCode/PrivateServerId
--   (não é servidor reservado), sem CreatedAt, e Resume só quando o Studio usa as lojas
--   separadas "_Studio" (assim um teste nunca continua nem sobrescreve um save real).
-- Nada é gravado: nem MemoryStore, nem LastMatch; nenhum perfil é liberado.
local function queueStudioSwitch(list, handoff)
	local hostUserId = handoff.HostUserId
	if type(hostUserId) ~= "number" or hostUserId ~= hostUserId then
		hostUserId = list[1].UserId
	end
	local maxPlayers = handoff.MaxPlayers
	if type(maxPlayers) ~= "number" or maxPlayers ~= maxPlayers then
		maxPlayers = LobbyConfig.MaxPlayersLimit
	end
	local privacy = handoff.Privacy
	if type(privacy) ~= "string" then
		privacy = "Invite"
	end

	local studioHandoff = {
		MapId = handoff.MapId,
		HostUserId = hostUserId,
		MaxPlayers = maxPlayers,
		Privacy = privacy,
		Resume = handoff.Resume == true and DataService.UsesStudioStores(),
		Members = nil,
		CreatedAt = nil,
		AccessCode = nil,
		PrivateServerId = nil,
		Studio = true,
	}

	studioSwitchQueued = true
	print(("[TravelService] Studio: o lobby vai virar a partida %s neste servidor (sem teleporte)."):format(
		tostring(handoff.MapId)
	))
	-- task.defer: a troca roda logo depois desta chamada terminar (quem chamou, como o
	-- PartyService, termina o que estava fazendo antes de o lobby ser desligado).
	task.defer(studioMatchSwitch, studioHandoff)
	return true
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- TravelService.SendToNewMatch(players, handoff) -> ok, err
-- handoff = {MapId, HostUserId, MaxPlayers, Privacy, Resume}
-- (completado aqui com AccessCode, PrivateServerId, Members e CreatedAt)
-- No Studio não teleporta: com o papel "Lobby" e a troca registrada, agenda a troca
-- para a partida neste mesmo servidor (queueStudioSwitch); senão devolve false e um aviso.
function TravelService.SendToNewMatch(players, handoff)
	TravelService.Init()

	-- O mapa é conferido antes de tudo (também no Studio).
	if type(handoff) ~= "table" or not isPlayableMap(handoff.MapId) then
		return false, MSG_BAD_MAP
	end

	if isStudio() then
		-- Já é a partida: o próximo ato não abre no mesmo servidor (os serviços da
		-- partida só ligam uma vez por servidor).
		if currentRole() == "Match" then
			return false, MSG_STUDIO_NEXT_ACT
		end
		-- Lobby sem a troca registrada (Config.Game.StudioInPlaceMatch = false).
		if type(studioMatchSwitch) ~= "function" then
			return false, MSG_STUDIO_MATCH
		end
		-- A troca acontece uma vez só: outro grupo já pediu.
		if studioSwitchQueued then
			return false, MSG_STUDIO_SWITCHING
		end
		local list = normalizePlayers(players)
		if #list == 0 then
			return false, MSG_NO_PLAYERS
		end
		return queueStudioSwitch(list, handoff)
	end

	if GameConfig.MatchPlaceId == 0 then
		return false, MSG_NO_MATCH_PLACE
	end
	if hasSamePlaceIds() then
		warn("[TravelService] " .. MSG_SAME_PLACE_IDS)
		return false, MSG_SAME_PLACE_IDS
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
-- Fora do Studio devolve false (sem teleportar) quando o lobby não está configurado
-- (LobbyPlaceId = 0) ou quando ESTE servidor já é o place do lobby (LobbyPlaceId igual
-- ao game.PlaceId): teleportar para o próprio place faria o jogador voltar para cá sem
-- fim. Quando recebe false, o MatchService expulsa (Kick) quem ele estava mandando de
-- volta ao lobby (sendBackToLobby) ou avisa o jogador que pediu para voltar.
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

	-- No Studio não há lobby para onde ir (o teleporte não funciona lá): o teste acaba
	-- com um Kick, e a saída salva os dados normalmente.
	if isStudio() then
		for _, player in ipairs(list) do
			player:Kick(MSG_STUDIO_LOBBY)
		end
		return true
	end

	if GameConfig.LobbyPlaceId == 0 then
		return false, MSG_NO_LOBBY_PLACE
	end
	if GameConfig.LobbyPlaceId == game.PlaceId then
		warn("[TravelService] " .. MSG_ALREADY_LOBBY_PLACE)
		return false, MSG_ALREADY_LOBBY_PLACE
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
	if hasSamePlaceIds() then
		return false, MSG_SAME_PLACE_IDS
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

-- TravelService.SetStudioMatchSwitch(fn)
-- Só no Studio. O Main registra aqui a função que transforma o lobby de teste na
-- partida (switchToMatch). Com ela registrada, SendToNewMatch no lobby do Studio chama
-- fn(studioHandoff) com task.defer em vez de teleportar. nil desliga a troca.
-- Fora do Studio é ignorado (num jogo publicado o grupo sempre é teleportado).
function TravelService.SetStudioMatchSwitch(fn)
	if not isStudio() then
		warn("[TravelService] SetStudioMatchSwitch só funciona no Studio; ignorado.")
		return
	end
	if fn ~= nil and type(fn) ~= "function" then
		warn("[TravelService] SetStudioMatchSwitch precisa de uma função (ou nil).")
		return
	end
	studioMatchSwitch = fn
end

return TravelService
