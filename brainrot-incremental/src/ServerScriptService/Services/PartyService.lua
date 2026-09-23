-- PartyService: grupos do lobby (criar, entrar, sair, prontos, contagem e teleporte).
--
-- Seção 9.2 da especificação. Um grupo é uma tabela:
--   {Id, HostUserId, MapId, MaxPlayers, Privacy, Resume,
--    Members = {userId} (ordem de entrada), Ready = {[userId] = true},
--    Invited = {[userId] = true}, State = "Waiting"|"Countdown"|"Teleporting", CountdownEnd}
--
-- Regras principais:
--   - um jogador fica em no máximo um grupo;
--   - o mapa precisa estar liberado (UnlockedMaps) no perfil do dono;
--   - Resume (continuar partida salva) só se o dono tem RunSaves[MapId];
--   - MaxPlayers entre MinMaxPlayers e MaxPlayersLimit e nunca menor que o nº de membros;
--   - quem vê/entra: Public = todos; Friends = amigos do dono; Invite = convidados
--     (um convite do dono também vale num grupo "Só amigos");
--   - se o dono sai, o membro mais antigo vira dono; grupo vazio some;
--   - iniciar: só o dono, com todos prontos (o dono conta como pronto) ou forçando;
--     contagem de CountdownSeconds, cancelada se alguém sai, desmarca pronto ou o dono cancela;
--     no fim, TravelService.SendToNewMatch; se falhar, volta a "Waiting" com aviso.
--
-- Depois de qualquer mudança, cada jogador do lobby recebe o evento "PartyState" com
-- a visão dele (grupo dele, grupos que ele pode ver e convites pendentes).
--
-- Amizade: player:IsFriendsWith(hostUserId) faz uma chamada web (demora). Por isso
-- guardamos o resultado num cache e, na hora de montar o PartyState, só usamos o que
-- já está no cache; o que falta é buscado em segundo plano e, quando chega, mandamos
-- o estado de novo. Assim o envio do PartyState nunca fica esperando a web.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared.Config.Lobby)
local MapsConfig = require(Shared.Config.Maps)
local Net = require(Shared.Util.Net)
local Trove = require(Shared.Util.Trove)

local DataService = require(script.Parent:WaitForChild("DataService"))
local StateService = require(script.Parent:WaitForChild("StateService"))

-- Outros serviços só são pegos dentro de funções (regra anti-require-circular).
local Services = script.Parent
local function Svc(name)
	return require(Services:WaitForChild(name))
end

local PartyService = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Privacidades aceitas.
local VALID_PRIVACY = { Public = true, Friends = true, Invite = true }

-- Mapas que podem ser escolhidos (os da ordem oficial em Config.Maps).
local VALID_MAPS = {}
for _, mapId in ipairs(MapsConfig.Order) do
	if type(MapsConfig[mapId]) == "table" then
		VALID_MAPS[mapId] = true
	end
end

-- Constantes técnicas.
local MAX_ID_LENGTH = 64 -- tamanho máximo de um id de grupo vindo do cliente
local MAX_SAFE_INTEGER = 2 ^ 53 -- maior inteiro exato num double
local FRIEND_CACHE_TTL = 300 -- por quanto tempo confiamos numa resposta de amizade (s)
local FRIEND_FAIL_RETRY = 30 -- se a checagem falhou, tenta de novo depois disso (s)
local TELEPORT_STUCK_TIMEOUT = 75 -- depois do teleporte "dar certo", quem ficou para trás volta a esperar (s)
local JOIN_RESEND_DELAYS = { 3, 8 } -- reenvia o PartyState para quem acabou de entrar (s)

-- Limites de frequência (pedidos por segundo e rajada) de cada Request.
local RATE_CREATE = { Rate = 1, Burst = 3 }
local RATE_JOIN = { Rate = 2, Burst = 5 }
local RATE_INVITE = { Rate = 1, Burst = 4 }
local RATE_SETTINGS = { Rate = 4, Burst = 8 }

-- Mensagens de erro (português do Brasil).
local MSG_NO_PROFILE = "Seus dados ainda estão carregando. Tente de novo em instantes."
local MSG_BAD_OPTIONS = "Opções do grupo inválidas."
local MSG_BAD_MAP = "Mapa inválido."
local MSG_MAP_LOCKED = "Você ainda não liberou este mapa."
local MSG_NO_SAVE = "Você não tem uma partida salva neste mapa."
local MSG_BAD_MAX = "O limite de jogadores precisa ser um número inteiro entre %d e %d."
local MSG_BAD_PRIVACY = "Privacidade inválida."
local MSG_BAD_VALUE = "Valor inválido."
local MSG_BAD_PLAYER = "Jogador inválido."
local MSG_ALREADY_IN_PARTY = "Você já está em um grupo. Saia dele primeiro."
local MSG_NOT_IN_PARTY = "Você não está em um grupo."
local MSG_NOT_HOST = "Só o dono do grupo pode fazer isso."
local MSG_PARTY_GONE = "Esse grupo não existe mais."
local MSG_ALREADY_MEMBER = "Você já está neste grupo."
local MSG_IN_OTHER_PARTY = "Saia do seu grupo atual para entrar em outro."
local MSG_FULL = "O grupo está cheio."
local MSG_FRIENDS_ONLY = "Só amigos do dono podem entrar."
local MSG_INVITE_ONLY = "Só convidados podem entrar."
local MSG_COUNTDOWN_RUNNING = "A partida deste grupo já está começando."
local MSG_TELEPORTING = "O grupo já está entrando na partida."
local MSG_BUSY_COUNTDOWN = "Cancele a contagem regressiva antes."
local MSG_FRIEND_CHECK_FAILED = "Não foi possível verificar a amizade agora. Tente de novo."
local MSG_TRY_AGAIN = "O grupo mudou enquanto você entrava. Tente de novo."
local MSG_ALREADY_COUNTDOWN = "A contagem regressiva já começou."
local MSG_NO_COUNTDOWN = "Não há contagem regressiva para cancelar."
local MSG_NOT_READY = "Nem todos estão prontos: %s."
local MSG_MEMBER_MISSING = "Um dos membros não está mais no servidor."
local MSG_HOST_NO_PROFILE = "Os dados do dono ainda estão carregando. Tente de novo em instantes."
local MSG_HOST_MAP_LOCKED = "O dono do grupo ainda não liberou este mapa."
local MSG_HOST_NO_SAVE = "O dono do grupo não tem partida salva neste mapa."
local MSG_KICK_SELF = "Você não pode expulsar a si mesmo."
local MSG_TRANSFER_SELF = "Você já é o dono do grupo."
local MSG_NOT_MEMBER = "Esse jogador não está no seu grupo."
local MSG_TARGET_NO_PROFILE = "Os dados desse jogador ainda estão carregando."
local MSG_TARGET_MAP_LOCKED = "%s ainda não liberou o mapa %s. Troque o mapa antes."
local MSG_MAX_BELOW_MEMBERS = "O grupo já tem %d membros."
local MSG_TARGET_NOT_HERE = "Esse jogador não está neste servidor."
local MSG_INVITE_SELF = "Você não pode convidar a si mesmo."
local MSG_TARGET_ALREADY_MEMBER = "Esse jogador já está no seu grupo."
local MSG_TELEPORT_FAILED = "Não foi possível iniciar a partida. Tente de novo."

-- Avisos (Notify) para os membros.
local NOTE_JOINED = "%s entrou no grupo."
local NOTE_LEFT = "%s saiu do grupo."
local NOTE_KICKED_MEMBERS = "%s foi expulso do grupo."
local NOTE_KICKED_TARGET = "Você foi expulso do grupo de %s."
local NOTE_NEW_HOST_SELF = "Agora você é o dono do grupo!"
local NOTE_NEW_HOST_OTHERS = "%s agora é o dono do grupo."
local NOTE_MAP_CHANGED = "Mapa do grupo: %s."
local NOTE_RESUME_OFF = "O dono não tem partida salva neste mapa: a partida vai começar do zero."
local NOTE_SETTINGS_CHANGED = "O dono mudou o grupo: %s."
local NOTE_COUNTDOWN = "A partida começa em %d segundos!"
local NOTE_CANCEL_LEFT = "Contagem cancelada: %s saiu do grupo."
local NOTE_CANCEL_UNREADY = "Contagem cancelada: %s não está mais pronto."
local NOTE_CANCEL_HOST = "O dono cancelou a contagem."
local NOTE_INVITED = "%s convidou você para o grupo (%s)! Veja em Partidas Abertas."
local NOTE_STUCK = "Nem todos foram teleportados. O grupo voltou a esperar."

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local parties = {} -- [partyId] = grupo
local partyOrder = {} -- {partyId} na ordem de criação (para a lista ficar estável)
local partyOfUser = {} -- [userId] = partyId do grupo em que ele está
local runtime = {} -- [partyId] = {Trove, Token, CountdownThread, WatchdogThread} (só no servidor)
local displayNames = {} -- [userId] = {Name, DisplayName} de quem está (ou estava) no servidor

local friendCache = {} -- [userIdA] = {[userIdB] = {Value = boolean, Time = os.clock()}}
local friendPending = {} -- ["a:b"] = true enquanto a checagem está em andamento

local serviceTrove = Trove.new() -- conexões do serviço
local broadcastScheduled = false -- já tem um envio de PartyState marcado?

-------------------------------------------------------------------------------
-- Ajudantes gerais
-------------------------------------------------------------------------------

-- Número "de verdade": não é NaN nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Número inteiro válido (sem casas decimais, dentro da faixa exata do double).
local function isInteger(value)
	return isFiniteNumber(value) and value == math.floor(value) and math.abs(value) <= MAX_SAFE_INTEGER
end

-- UserId vindo do cliente: inteiro diferente de zero (no Studio os jogadores de teste são negativos).
local function isValidUserId(value)
	return isInteger(value) and value ~= 0
end

-- Hora compartilhada entre servidor e cliente.
local function now()
	return workspace:GetServerTimeNow()
end

-- Jogador presente no servidor com esse UserId (ou nil).
local function getPlayer(userId)
	return Players:GetPlayerByUserId(userId)
end

-- Guarda os nomes de um jogador (usados mesmo depois que ele sai, nos avisos).
local function rememberNames(player)
	displayNames[player.UserId] = { Name = player.Name, DisplayName = player.DisplayName }
end

-- Nome de exibição de um UserId.
local function displayNameOf(userId)
	local player = getPlayer(userId)
	if player then
		return player.DisplayName
	end
	local names = displayNames[userId]
	if names then
		return names.DisplayName
	end
	return "Jogador " .. tostring(userId)
end

-- Nome de usuário (@nome) de um UserId.
local function userNameOf(userId)
	local player = getPlayer(userId)
	if player then
		return player.Name
	end
	local names = displayNames[userId]
	if names then
		return names.Name
	end
	return "Jogador " .. tostring(userId)
end

-- Nome bonito do mapa.
local function mapDisplayName(mapId)
	local def = MapsConfig[mapId]
	if type(def) == "table" and type(def.DisplayName) == "string" then
		return def.DisplayName
	end
	return tostring(mapId)
end

-- Perfil de um UserId presente (ou nil).
local function getProfileByUserId(userId)
	local player = getPlayer(userId)
	if not player then
		return nil
	end
	return DataService.GetProfile(player)
end

-- O perfil liberou esse mapa?
local function hasUnlocked(profile, mapId)
	return type(profile) == "table" and type(profile.UnlockedMaps) == "table" and profile.UnlockedMaps[mapId] == true
end

-- O perfil tem uma partida salva nesse mapa?
local function hasSave(profile, mapId)
	return type(profile) == "table" and type(profile.RunSaves) == "table" and profile.RunSaves[mapId] ~= nil
end

-- Mapa mais avançado que o perfil já liberou (ou o primeiro da lista).
local function bestUnlockedMap(profile)
	local best = MapsConfig.Order[1]
	for _, mapId in ipairs(MapsConfig.Order) do
		if hasUnlocked(profile, mapId) then
			best = mapId
		end
	end
	return best
end

-- Cancela uma thread agendada (task.delay), menos a que está rodando agora.
local function cancelThread(thread)
	if thread and thread ~= coroutine.running() then
		pcall(task.cancel, thread)
	end
end

-- Manda um aviso para todos os membros do grupo (menos exceptUserId, se tiver).
local function notifyMembers(party, text, kind, exceptUserId)
	for _, userId in ipairs(party.Members) do
		if userId ~= exceptUserId then
			local player = getPlayer(userId)
			if player then
				StateService.Notify(player, text, kind)
			end
		end
	end
end

-- Grupo em que o jogador está (ou nil). Limpa referências velhas.
local function getPartyOf(userId)
	local partyId = partyOfUser[userId]
	if not partyId then
		return nil
	end
	local party = parties[partyId]
	if not party or not table.find(party.Members, userId) then
		partyOfUser[userId] = nil
		return nil
	end
	return party
end

-- Grupo do jogador, exigindo que ele seja o dono. Devolve party ou nil, mensagem.
local function getHostParty(player)
	local party = getPartyOf(player.UserId)
	if not party then
		return nil, MSG_NOT_IN_PARTY
	end
	if party.HostUserId ~= player.UserId then
		return nil, MSG_NOT_HOST
	end
	return party
end

-- Mudanças de configuração só com o grupo esperando. Devolve a mensagem de erro ou nil.
local function waitingError(party)
	if party.State == "Countdown" then
		return MSG_BUSY_COUNTDOWN
	elseif party.State == "Teleporting" then
		return MSG_TELEPORTING
	end
	return nil
end

-------------------------------------------------------------------------------
-- Envio do PartyState
-------------------------------------------------------------------------------

-- Declarada aqui porque o cache de amizade precisa dela (a função vem mais abaixo).
local scheduleBroadcast

-- Chave do "em andamento" da checagem de amizade.
local function friendKey(a, b)
	return tostring(a) .. ":" .. tostring(b)
end

-- Guarda uma resposta de amizade nos dois sentidos (amizade é mútua).
local function storeFriendship(userA, userB, value, time)
	friendCache[userA] = friendCache[userA] or {}
	friendCache[userB] = friendCache[userB] or {}
	local entry = { Value = value, Time = time }
	friendCache[userA][userB] = entry
	friendCache[userB][userA] = entry
end

-- Entrada do cache (ou nil).
local function getFriendEntry(userA, userB)
	local cache = friendCache[userA]
	return cache and cache[userB] or nil
end

-- A entrada ainda vale?
local function isFresh(entry)
	return entry ~= nil and os.clock() - entry.Time < FRIEND_CACHE_TTL
end

-- Busca a amizade em segundo plano (não espera). Quando a resposta muda o que o
-- jogador pode ver, manda o PartyState de novo.
local function prefetchFriendship(viewer, otherUserId)
	local viewerId = viewer.UserId
	if viewerId == otherUserId or isFresh(getFriendEntry(viewerId, otherUserId)) then
		return
	end
	local key = friendKey(viewerId, otherUserId)
	if friendPending[key] then
		return
	end
	friendPending[key] = true

	task.spawn(function()
		local previous = getFriendEntry(viewerId, otherUserId)
		local ok, result = pcall(function()
			return viewer:IsFriendsWith(otherUserId)
		end)
		friendPending[key] = nil
		if viewer.Parent ~= Players then
			return -- saiu enquanto esperava
		end

		if ok then
			local value = result == true
			storeFriendship(viewerId, otherUserId, value, os.clock())
			-- Só reenvia se a visibilidade mudou (desconhecido conta como "não amigo").
			local before = previous ~= nil and previous.Value == true
			if before ~= value then
				scheduleBroadcast()
			end
		else
			-- Falhou: mantém o valor antigo (ou "não amigo") e tenta de novo em breve.
			local keep = previous ~= nil and previous.Value == true
			storeFriendship(viewerId, otherUserId, keep, os.clock() - (FRIEND_CACHE_TTL - FRIEND_FAIL_RETRY))
		end
	end)
end

-- Amizade pelo cache (sem esperar). Se não sabe ou está velha, busca em segundo plano.
-- Devolve true/false (desconhecido = false até a resposta chegar).
local function getCachedFriendship(viewer, otherUserId)
	if viewer.UserId == otherUserId then
		return true
	end
	local entry = getFriendEntry(viewer.UserId, otherUserId)
	if not isFresh(entry) then
		prefetchFriendship(viewer, otherUserId)
	end
	return entry ~= nil and entry.Value == true
end

-- Amizade agora (espera a web se precisar). Devolve true/false ou nil se falhou.
local function checkFriendshipNow(player, otherUserId)
	if player.UserId == otherUserId then
		return true
	end
	local entry = getFriendEntry(player.UserId, otherUserId)
	if isFresh(entry) then
		return entry.Value
	end
	local ok, result = pcall(function()
		return player:IsFriendsWith(otherUserId)
	end)
	if not ok then
		warn("[PartyService] IsFriendsWith falhou: " .. tostring(result))
		return nil
	end
	local value = result == true
	storeFriendship(player.UserId, otherUserId, value, os.clock())
	return value
end

-- O jogador pode ver o grupo? (membro, público, amigo do dono ou convidado)
local function canSee(party, viewer, isMember, isFriend)
	if isMember then
		return true
	end
	local invited = party.Invited[viewer.UserId] == true
	if party.Privacy == "Public" then
		return true
	elseif party.Privacy == "Friends" then
		return isFriend or invited
	end
	return invited
end

-- Motivo para o jogador NÃO poder entrar no grupo (nil = pode entrar).
local function joinBlockReason(party, player, isFriend)
	local userId = player.UserId
	local currentId = partyOfUser[userId]
	if currentId == party.Id then
		return MSG_ALREADY_MEMBER
	end
	if currentId and parties[currentId] then
		return MSG_IN_OTHER_PARTY
	end
	if party.State == "Teleporting" then
		return MSG_TELEPORTING
	end
	if party.State == "Countdown" then
		return MSG_COUNTDOWN_RUNNING
	end
	if #party.Members >= party.MaxPlayers then
		return MSG_FULL
	end
	local invited = party.Invited[userId] == true
	if party.Privacy == "Friends" and not (isFriend or invited) then
		return MSG_FRIENDS_ONLY
	end
	if party.Privacy == "Invite" and not invited then
		return MSG_INVITE_ONLY
	end
	return nil
end

-- Parte da visão que é igual para todos os jogadores (montada uma vez por envio).
local function buildBaseView(party)
	local members = {}
	for _, userId in ipairs(party.Members) do
		table.insert(members, {
			UserId = userId,
			Name = userNameOf(userId),
			DisplayName = displayNameOf(userId),
			-- O dono conta como pronto.
			Ready = party.Ready[userId] == true or userId == party.HostUserId,
		})
	end
	return {
		Id = party.Id,
		HostUserId = party.HostUserId,
		HostName = displayNameOf(party.HostUserId),
		MapId = party.MapId,
		MaxPlayers = party.MaxPlayers,
		Privacy = party.Privacy,
		Resume = party.Resume,
		State = party.State,
		CountdownEnd = party.CountdownEnd,
		Members = members,
	}
end

-- PartyView de um jogador: a base + CanJoin/JoinBlockReason calculados para ele.
local function buildViewerView(base, party, viewer, isFriend)
	local view = table.clone(base)
	local reason = joinBlockReason(party, viewer, isFriend)
	view.CanJoin = reason == nil
	view.JoinBlockReason = reason
	return view
end

-- Monta o PartyStatePayload de um jogador.
local function buildPayload(viewer, bases)
	local myPartyId = partyOfUser[viewer.UserId]
	local payload = {
		MyParty = nil,
		Parties = {},
		Invites = {},
	}

	for _, partyId in ipairs(partyOrder) do
		local party = parties[partyId]
		if party then
			local isMember = myPartyId == partyId
			local invited = party.Invited[viewer.UserId] == true

			-- A amizade só importa em grupos "Só amigos" de quem não é membro nem convidado.
			local isFriend = false
			if party.Privacy == "Friends" and not isMember and not invited then
				isFriend = getCachedFriendship(viewer, party.HostUserId)
			end

			if canSee(party, viewer, isMember, isFriend) then
				local base = bases[partyId] or buildBaseView(party)
				local view = buildViewerView(base, party, viewer, isFriend)
				if isMember then
					payload.MyParty = view
				end
				table.insert(payload.Parties, view)
			end

			if invited and not isMember then
				table.insert(payload.Invites, partyId)
			end
		end
	end

	return payload
end

-- Visões-base de todos os grupos.
local function buildAllBases()
	local bases = {}
	for partyId, party in pairs(parties) do
		bases[partyId] = buildBaseView(party)
	end
	return bases
end

-- Manda o PartyState para um jogador só.
local function sendTo(player)
	if typeof(player) ~= "Instance" or player.Parent ~= Players then
		return
	end
	Net.FireClient(player, "PartyState", buildPayload(player, buildAllBases()))
end

-- Manda o PartyState para todos os jogadores do lobby.
local function broadcastNow()
	local bases = buildAllBases()
	for _, player in ipairs(Players:GetPlayers()) do
		Net.FireClient(player, "PartyState", buildPayload(player, bases))
	end
end

-- Marca um envio para o fim deste quadro (várias mudanças seguidas viram um envio só).
scheduleBroadcast = function()
	if broadcastScheduled then
		return
	end
	broadcastScheduled = true
	task.defer(function()
		broadcastScheduled = false
		local ok, err = pcall(broadcastNow)
		if not ok then
			warn("[PartyService] Erro ao enviar PartyState: " .. tostring(err))
		end
	end)
end

-------------------------------------------------------------------------------
-- Ciclo de vida de um grupo
-------------------------------------------------------------------------------

-- Cria o grupo com o jogador como dono.
local function createParty(host, mapId, maxPlayers, privacy, resume)
	local partyId = HttpService:GenerateGUID(false)
	local party = {
		Id = partyId,
		HostUserId = host.UserId,
		MapId = mapId,
		MaxPlayers = maxPlayers,
		Privacy = privacy,
		Resume = resume,
		Members = { host.UserId },
		Ready = {},
		Invited = {},
		State = "Waiting",
		CountdownEnd = nil,
	}
	parties[partyId] = party
	table.insert(partyOrder, partyId)
	partyOfUser[host.UserId] = partyId

	-- Dados internos (threads da contagem e do vigia do teleporte).
	local rt = {
		Trove = Trove.new(),
		Token = 0,
		CountdownThread = nil,
		WatchdogThread = nil,
	}
	-- Ao desfazer o grupo, o Trove cancela as threads agendadas.
	rt.Trove:Add(function()
		cancelThread(rt.CountdownThread)
		cancelThread(rt.WatchdogThread)
		rt.CountdownThread = nil
		rt.WatchdogThread = nil
	end)
	runtime[partyId] = rt

	return party
end

-- Desfaz o grupo (ficou vazio).
local function destroyParty(party)
	if parties[party.Id] ~= party then
		return
	end
	parties[party.Id] = nil
	local index = table.find(partyOrder, party.Id)
	if index then
		table.remove(partyOrder, index)
	end
	for _, userId in ipairs(party.Members) do
		if partyOfUser[userId] == party.Id then
			partyOfUser[userId] = nil
		end
	end

	local rt = runtime[party.Id]
	runtime[party.Id] = nil
	if rt then
		rt.Token += 1 -- invalida qualquer thread que ainda esteja rodando
		rt.Trove:Clean()
	end
end

-- Cancela a contagem regressiva (se estiver rodando) e volta a "Waiting".
local function cancelCountdown(party, message)
	if party.State ~= "Countdown" then
		return false
	end
	local rt = runtime[party.Id]
	if rt then
		rt.Token += 1
		cancelThread(rt.CountdownThread)
		rt.CountdownThread = nil
	end
	party.State = "Waiting"
	party.CountdownEnd = nil
	if message then
		notifyMembers(party, message, "warning")
	end
	scheduleBroadcast()
	return true
end

-- Ajusta o grupo às regras do dono atual (usado quando a liderança muda sozinha):
-- mapa liberado por ele e Resume só se ele tem a partida salva.
local function adjustForHost(party, silent)
	local profile = getProfileByUserId(party.HostUserId)
	if profile and not hasUnlocked(profile, party.MapId) then
		local newMap = bestUnlockedMap(profile)
		if newMap and newMap ~= party.MapId then
			party.MapId = newMap
			if not silent then
				notifyMembers(party, NOTE_MAP_CHANGED:format(mapDisplayName(newMap)), "info")
			end
		end
	end
	if party.Resume and not hasSave(profile, party.MapId) then
		party.Resume = false
		if not silent then
			notifyMembers(party, NOTE_RESUME_OFF, "info")
		end
	end
end

-- Tira um membro do grupo. cause: "Left" (saiu), "Kicked" (expulso) ou "Disconnected".
local function removeMember(party, userId, cause)
	local index = table.find(party.Members, userId)
	if not index then
		return
	end
	table.remove(party.Members, index)
	party.Ready[userId] = nil
	if partyOfUser[userId] == party.Id then
		partyOfUser[userId] = nil
	end
	if cause == "Kicked" then
		-- Expulso perde o convite (senão poderia entrar de novo num grupo "Só convidados").
		party.Invited[userId] = nil
	end

	-- Grupo vazio some.
	if #party.Members == 0 then
		destroyParty(party)
		scheduleBroadcast()
		return
	end

	-- Durante o teleporte, as saídas são esperadas (os jogadores estão indo para a
	-- partida): não avisamos ninguém, só mantemos o grupo em ordem.
	local silent = party.State == "Teleporting"
	local name = displayNameOf(userId)

	-- Alguém saiu durante a contagem: cancela.
	local canceled = cancelCountdown(party, NOTE_CANCEL_LEFT:format(name))

	-- O dono saiu: a liderança passa para o membro mais antigo.
	if party.HostUserId == userId then
		party.HostUserId = party.Members[1]
		adjustForHost(party, silent)
		if not silent then
			local newHost = getPlayer(party.HostUserId)
			if newHost then
				StateService.Notify(newHost, NOTE_NEW_HOST_SELF, "success")
			end
			notifyMembers(party, NOTE_NEW_HOST_OTHERS:format(displayNameOf(party.HostUserId)), "info", party.HostUserId)
		end
	end

	if not silent and not canceled then
		local note = if cause == "Kicked" then NOTE_KICKED_MEMBERS else NOTE_LEFT
		notifyMembers(party, note:format(name), "info")
	end

	scheduleBroadcast()
end

-- Confere se o grupo pode começar (dono com perfil, mapa liberado, save, membros presentes).
-- Devolve a mensagem de erro ou nil.
local function startError(party)
	local host = getPlayer(party.HostUserId)
	local profile = host and DataService.GetProfile(host)
	if not profile then
		return MSG_HOST_NO_PROFILE
	end
	if not VALID_MAPS[party.MapId] or not hasUnlocked(profile, party.MapId) then
		return MSG_HOST_MAP_LOCKED
	end
	if party.Resume and not hasSave(profile, party.MapId) then
		return MSG_HOST_NO_SAVE
	end
	for _, userId in ipairs(party.Members) do
		if not getPlayer(userId) then
			return MSG_MEMBER_MISSING
		end
	end
	return nil
end

-- Vigia do teleporte: se alguém ainda está aqui muito depois do teleporte "dar certo",
-- o grupo volta a esperar (os que ficaram podem tentar de novo).
local function onTeleportStuck(party, token)
	local rt = runtime[party.Id]
	if parties[party.Id] ~= party or not rt or rt.Token ~= token or party.State ~= "Teleporting" then
		return
	end
	rt.WatchdogThread = nil
	rt.Token += 1
	party.State = "Waiting"
	party.CountdownEnd = nil
	notifyMembers(party, NOTE_STUCK, "warning")
	scheduleBroadcast()
end

-- Faz o teleporte do grupo (roda numa thread própria, que NUNCA é cancelada:
-- interromper o TravelService no meio deixaria perfis liberados sem teleporte).
local function runTeleport(party, token)
	local list = {}
	for _, userId in ipairs(party.Members) do
		local player = getPlayer(userId)
		if player then
			table.insert(list, player)
		end
	end
	local handoff = {
		MapId = party.MapId,
		HostUserId = party.HostUserId,
		MaxPlayers = party.MaxPlayers,
		Privacy = party.Privacy,
		Resume = party.Resume,
	}

	local called, ok, err = pcall(function()
		return Svc("TravelService").SendToNewMatch(list, handoff)
	end)
	if not called then
		warn("[PartyService] Erro no teleporte do grupo: " .. tostring(ok))
		ok, err = false, MSG_TELEPORT_FAILED
	end

	-- O grupo pode ter sumido (todos saíram) ou mudado enquanto esperávamos.
	local rt = runtime[party.Id]
	if parties[party.Id] ~= party or not rt or rt.Token ~= token or party.State ~= "Teleporting" then
		return
	end

	if ok then
		-- Deu certo: os jogadores vão sair do servidor. Se alguém ficar para trás, o vigia resolve.
		rt.WatchdogThread = task.delay(TELEPORT_STUCK_TIMEOUT, onTeleportStuck, party, token)
		return
	end

	-- Falhou: volta a esperar e avisa o motivo.
	rt.Token += 1
	party.State = "Waiting"
	party.CountdownEnd = nil
	notifyMembers(party, if type(err) == "string" and err ~= "" then err else MSG_TELEPORT_FAILED, "error")
	scheduleBroadcast()
end

-- Fim da contagem: confere tudo de novo e começa o teleporte.
local function onCountdownFinished(party, token)
	local rt = runtime[party.Id]
	if parties[party.Id] ~= party or not rt or rt.Token ~= token or party.State ~= "Countdown" then
		return
	end
	rt.CountdownThread = nil

	-- Algo pode ter mudado durante a contagem (ex.: perfil do dono).
	local problem = startError(party)
	if problem then
		rt.Token += 1
		party.State = "Waiting"
		party.CountdownEnd = nil
		notifyMembers(party, problem, "error")
		scheduleBroadcast()
		return
	end

	rt.Token += 1
	local teleportToken = rt.Token
	party.State = "Teleporting"
	party.CountdownEnd = nil
	scheduleBroadcast()

	-- Thread separada: a contagem termina aqui e o teleporte não pode ser cancelado.
	task.spawn(runTeleport, party, teleportToken)
end

-- Começa a contagem regressiva.
local function startCountdown(party)
	local rt = runtime[party.Id]
	if not rt then
		return
	end
	local seconds = math.max(0, tonumber(LobbyConfig.CountdownSeconds) or 0)
	rt.Token += 1
	local token = rt.Token
	cancelThread(rt.CountdownThread)
	party.State = "Countdown"
	party.CountdownEnd = now() + seconds
	rt.CountdownThread = task.delay(seconds, onCountdownFinished, party, token)
	notifyMembers(party, NOTE_COUNTDOWN:format(math.ceil(seconds)), "info")
	scheduleBroadcast()
end

-------------------------------------------------------------------------------
-- Handlers dos Requests
-------------------------------------------------------------------------------

-- PartyCreate(opts = {MapId, MaxPlayers, Privacy, Resume}) -> partyId
local function onPartyCreate(player, opts)
	if type(opts) ~= "table" then
		return false, MSG_BAD_OPTIONS
	end

	local mapId = opts.MapId
	if type(mapId) ~= "string" or not VALID_MAPS[mapId] then
		return false, MSG_BAD_MAP
	end

	-- Limite de jogadores (padrão do Config se não veio).
	local minMax, maxMax = LobbyConfig.MinMaxPlayers, LobbyConfig.MaxPlayersLimit
	local maxPlayers = opts.MaxPlayers
	if maxPlayers == nil then
		maxPlayers = math.clamp(LobbyConfig.DefaultMaxPlayers, minMax, maxMax)
	elseif not isInteger(maxPlayers) or maxPlayers < minMax or maxPlayers > maxMax then
		return false, MSG_BAD_MAX:format(minMax, maxMax)
	end

	local privacy = opts.Privacy
	if privacy == nil then
		privacy = "Public"
	elseif type(privacy) ~= "string" or not VALID_PRIVACY[privacy] then
		return false, MSG_BAD_PRIVACY
	end

	local resume = opts.Resume
	if resume == nil then
		resume = false
	elseif type(resume) ~= "boolean" then
		return false, MSG_BAD_OPTIONS
	end

	if getPartyOf(player.UserId) then
		return false, MSG_ALREADY_IN_PARTY
	end

	local profile = DataService.GetProfile(player)
	if not profile then
		return false, MSG_NO_PROFILE
	end
	if not hasUnlocked(profile, mapId) then
		return false, MSG_MAP_LOCKED
	end
	if resume and not hasSave(profile, mapId) then
		return false, MSG_NO_SAVE
	end

	local party = createParty(player, mapId, maxPlayers, privacy, resume)
	scheduleBroadcast()
	return true, party.Id
end

-- PartyJoin(partyId) -> true
local function onPartyJoin(player, partyId)
	if type(partyId) ~= "string" or #partyId == 0 or #partyId > MAX_ID_LENGTH then
		return false, MSG_PARTY_GONE
	end
	local party = parties[partyId]
	if not party then
		return false, MSG_PARTY_GONE
	end

	local userId = player.UserId
	local isFriend = false

	-- Grupo "Só amigos" sem convite: precisa confirmar a amizade (pode demorar).
	if party.Privacy == "Friends" and not party.Invited[userId] then
		-- Primeiro os outros motivos, para não chamar a web à toa.
		local reason = joinBlockReason(party, player, true)
		if reason then
			return false, reason
		end

		local hostId = party.HostUserId
		local friend = checkFriendshipNow(player, hostId)
		if friend == nil then
			return false, MSG_FRIEND_CHECK_FAILED
		end

		-- Enquanto esperávamos, o grupo pode ter sumido ou trocado de dono.
		if parties[partyId] ~= party then
			return false, MSG_PARTY_GONE
		end
		if player.Parent ~= Players then
			return false, MSG_BAD_PLAYER
		end
		if party.HostUserId ~= hostId then
			return false, MSG_TRY_AGAIN
		end
		isFriend = friend
	end

	local reason = joinBlockReason(party, player, isFriend)
	if reason then
		return false, reason
	end

	table.insert(party.Members, userId)
	party.Ready[userId] = nil
	partyOfUser[userId] = party.Id
	notifyMembers(party, NOTE_JOINED:format(displayNameOf(userId)), "info", userId)
	scheduleBroadcast()
	return true, true
end

-- PartyLeave() -> true
local function onPartyLeave(player)
	local party = getPartyOf(player.UserId)
	if not party then
		return false, MSG_NOT_IN_PARTY
	end
	if party.State == "Teleporting" then
		return false, MSG_TELEPORTING
	end
	removeMember(party, player.UserId, "Left")
	return true, true
end

-- PartyReady(ready: boolean) -> true
local function onPartyReady(player, ready)
	if type(ready) ~= "boolean" then
		return false, MSG_BAD_VALUE
	end
	local party = getPartyOf(player.UserId)
	if not party then
		return false, MSG_NOT_IN_PARTY
	end
	if party.State == "Teleporting" then
		return false, MSG_TELEPORTING
	end

	local userId = player.UserId
	party.Ready[userId] = if ready then true else nil

	-- Um membro desmarcou "pronto" durante a contagem: cancela.
	-- (O dono sempre conta como pronto; para parar, ele usa "Cancelar".)
	if not ready and party.State == "Countdown" and userId ~= party.HostUserId then
		cancelCountdown(party, NOTE_CANCEL_UNREADY:format(displayNameOf(userId)))
	end

	scheduleBroadcast()
	return true, true
end

-- PartyStart(force: boolean) -> true
local function onPartyStart(player, force)
	if force == nil then
		force = false
	elseif type(force) ~= "boolean" then
		return false, MSG_BAD_VALUE
	end

	local party, err = getHostParty(player)
	if not party then
		return false, err
	end
	if party.State == "Countdown" then
		return false, MSG_ALREADY_COUNTDOWN
	elseif party.State == "Teleporting" then
		return false, MSG_TELEPORTING
	end

	local problem = startError(party)
	if problem then
		return false, problem
	end

	-- Sem forçar: todos precisam estar prontos (o dono conta como pronto).
	if not force then
		local notReady = {}
		for _, userId in ipairs(party.Members) do
			if userId ~= party.HostUserId and not party.Ready[userId] then
				table.insert(notReady, displayNameOf(userId))
			end
		end
		if #notReady > 0 then
			return false, MSG_NOT_READY:format(table.concat(notReady, ", "))
		end
	end

	startCountdown(party)
	return true, true
end

-- PartyCancelCountdown() -> true
local function onPartyCancelCountdown(player)
	local party, err = getHostParty(player)
	if not party then
		return false, err
	end
	if party.State ~= "Countdown" then
		return false, MSG_NO_COUNTDOWN
	end
	cancelCountdown(party, NOTE_CANCEL_HOST)
	return true, true
end

-- PartyKick(userId) -> true
local function onPartyKick(player, targetUserId)
	if not isValidUserId(targetUserId) then
		return false, MSG_BAD_PLAYER
	end
	local party, err = getHostParty(player)
	if not party then
		return false, err
	end
	if targetUserId == player.UserId then
		return false, MSG_KICK_SELF
	end
	if not table.find(party.Members, targetUserId) then
		return false, MSG_NOT_MEMBER
	end
	if party.State == "Teleporting" then
		return false, MSG_TELEPORTING
	end

	removeMember(party, targetUserId, "Kicked")
	local target = getPlayer(targetUserId)
	if target then
		StateService.Notify(target, NOTE_KICKED_TARGET:format(player.DisplayName), "warning")
	end
	return true, true
end

-- PartyTransfer(userId) -> true
local function onPartyTransfer(player, targetUserId)
	if not isValidUserId(targetUserId) then
		return false, MSG_BAD_PLAYER
	end
	local party, err = getHostParty(player)
	if not party then
		return false, err
	end
	local busy = waitingError(party)
	if busy then
		return false, busy
	end
	if targetUserId == player.UserId then
		return false, MSG_TRANSFER_SELF
	end
	if not table.find(party.Members, targetUserId) then
		return false, MSG_NOT_MEMBER
	end

	-- O novo dono precisa ter liberado o mapa atual.
	local targetProfile = getProfileByUserId(targetUserId)
	if not targetProfile then
		return false, MSG_TARGET_NO_PROFILE
	end
	if not hasUnlocked(targetProfile, party.MapId) then
		return false, MSG_TARGET_MAP_LOCKED:format(displayNameOf(targetUserId), mapDisplayName(party.MapId))
	end

	party.HostUserId = targetUserId
	-- O antigo dono "contava como pronto": continua pronto como membro.
	party.Ready[player.UserId] = true
	party.Ready[targetUserId] = nil
	-- Continuar partida salva só se o novo dono tem o save.
	adjustForHost(party, false)

	local target = getPlayer(targetUserId)
	if target then
		StateService.Notify(target, NOTE_NEW_HOST_SELF, "success")
	end
	notifyMembers(party, NOTE_NEW_HOST_OTHERS:format(displayNameOf(targetUserId)), "info", targetUserId)
	scheduleBroadcast()
	return true, true
end

-- PartySetMap(mapId) -> true
local function onPartySetMap(player, mapId)
	if type(mapId) ~= "string" or not VALID_MAPS[mapId] then
		return false, MSG_BAD_MAP
	end
	local party, err = getHostParty(player)
	if not party then
		return false, err
	end
	local busy = waitingError(party)
	if busy then
		return false, busy
	end

	local profile = DataService.GetProfile(player)
	if not profile then
		return false, MSG_NO_PROFILE
	end
	if not hasUnlocked(profile, mapId) then
		return false, MSG_MAP_LOCKED
	end
	if party.MapId == mapId then
		return true, true
	end

	party.MapId = mapId
	-- Sem save no mapa novo: desliga o "continuar".
	if party.Resume and not hasSave(profile, mapId) then
		party.Resume = false
	end
	notifyMembers(party, NOTE_MAP_CHANGED:format(mapDisplayName(mapId)), "info", player.UserId)
	scheduleBroadcast()
	return true, true
end

-- PartySetMaxPlayers(n) -> true
local function onPartySetMaxPlayers(player, n)
	local minMax, maxMax = LobbyConfig.MinMaxPlayers, LobbyConfig.MaxPlayersLimit
	if not isInteger(n) or n < minMax or n > maxMax then
		return false, MSG_BAD_MAX:format(minMax, maxMax)
	end
	local party, err = getHostParty(player)
	if not party then
		return false, err
	end
	local busy = waitingError(party)
	if busy then
		return false, busy
	end
	if n < #party.Members then
		return false, MSG_MAX_BELOW_MEMBERS:format(#party.Members)
	end

	party.MaxPlayers = n
	scheduleBroadcast()
	return true, true
end

-- PartySetPrivacy(privacy) -> true
local function onPartySetPrivacy(player, privacy)
	if type(privacy) ~= "string" or not VALID_PRIVACY[privacy] then
		return false, MSG_BAD_PRIVACY
	end
	local party, err = getHostParty(player)
	if not party then
		return false, err
	end
	local busy = waitingError(party)
	if busy then
		return false, busy
	end
	if party.Privacy == privacy then
		return true, true
	end

	party.Privacy = privacy
	local label = LobbyConfig.Privacy[privacy] or privacy
	notifyMembers(party, NOTE_SETTINGS_CHANGED:format(label), "info", player.UserId)
	scheduleBroadcast()
	return true, true
end

-- PartySetResume(resume: boolean) -> true
local function onPartySetResume(player, resume)
	if type(resume) ~= "boolean" then
		return false, MSG_BAD_VALUE
	end
	local party, err = getHostParty(player)
	if not party then
		return false, err
	end
	local busy = waitingError(party)
	if busy then
		return false, busy
	end
	if resume then
		local profile = DataService.GetProfile(player)
		if not profile then
			return false, MSG_NO_PROFILE
		end
		if not hasSave(profile, party.MapId) then
			return false, MSG_NO_SAVE
		end
	end

	party.Resume = resume
	scheduleBroadcast()
	return true, true
end

-- PartyInvite(userId) -> true
local function onPartyInvite(player, targetUserId)
	if not isValidUserId(targetUserId) then
		return false, MSG_BAD_PLAYER
	end
	local party, err = getHostParty(player)
	if not party then
		return false, err
	end
	if party.State == "Teleporting" then
		return false, MSG_TELEPORTING
	end
	if targetUserId == player.UserId then
		return false, MSG_INVITE_SELF
	end
	local target = getPlayer(targetUserId)
	if not target then
		return false, MSG_TARGET_NOT_HERE
	end
	if table.find(party.Members, targetUserId) then
		return false, MSG_TARGET_ALREADY_MEMBER
	end

	party.Invited[targetUserId] = true
	StateService.Notify(target, NOTE_INVITED:format(player.DisplayName, mapDisplayName(party.MapId)), "info", 8)
	scheduleBroadcast()
	return true, true
end

-------------------------------------------------------------------------------
-- Entrada e saída de jogadores
-------------------------------------------------------------------------------

-- Entrou no lobby: manda o estado atual (e de novo daqui a pouco, caso a interface
-- dele ainda não estivesse pronta para receber).
local function onPlayerAdded(player)
	rememberNames(player)
	sendTo(player)
	for _, delaySeconds in ipairs(JOIN_RESEND_DELAYS) do
		task.delay(delaySeconds, sendTo, player)
	end
end

-- Saiu do servidor: sai do grupo, perde os convites e limpa o cache de amizade.
local function onPlayerRemoving(player)
	local userId = player.UserId
	rememberNames(player)

	local party = getPartyOf(userId)
	if party then
		removeMember(party, userId, "Disconnected")
	end
	partyOfUser[userId] = nil

	for _, other in pairs(parties) do
		other.Invited[userId] = nil
	end

	friendCache[userId] = nil
	for _, cache in pairs(friendCache) do
		cache[userId] = nil
	end

	-- Os nomes só eram necessários para os avisos acima.
	displayNames[userId] = nil

	scheduleBroadcast()
end

-------------------------------------------------------------------------------
-- Ciclo de vida do serviço
-------------------------------------------------------------------------------

function PartyService.Init()
	Net.Handle("PartyCreate", onPartyCreate, RATE_CREATE)
	Net.Handle("PartyJoin", onPartyJoin, RATE_JOIN)
	Net.Handle("PartyLeave", onPartyLeave, RATE_SETTINGS)
	Net.Handle("PartyReady", onPartyReady, RATE_SETTINGS)
	Net.Handle("PartyStart", onPartyStart, RATE_SETTINGS)
	Net.Handle("PartyCancelCountdown", onPartyCancelCountdown, RATE_SETTINGS)
	Net.Handle("PartyKick", onPartyKick, RATE_SETTINGS)
	Net.Handle("PartyTransfer", onPartyTransfer, RATE_SETTINGS)
	Net.Handle("PartySetMap", onPartySetMap, RATE_SETTINGS)
	Net.Handle("PartySetMaxPlayers", onPartySetMaxPlayers, RATE_SETTINGS)
	Net.Handle("PartySetPrivacy", onPartySetPrivacy, RATE_SETTINGS)
	Net.Handle("PartySetResume", onPartySetResume, RATE_SETTINGS)
	Net.Handle("PartyInvite", onPartyInvite, RATE_INVITE)

	serviceTrove:Connect(Players.PlayerAdded, onPlayerAdded)
	serviceTrove:Connect(Players.PlayerRemoving, onPlayerRemoving)
end

function PartyService.Start()
	-- Jogadores que entraram antes do serviço ligar.
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end
end

return PartyService
