--!nonstrict
-- AdminService: poderes de administrador para o dono do jogo e amigos de confiança.
-- Roda no lobby e na partida (os comandos que precisam da partida avisam no lobby).
--
-- Quem é admin (lista em Config.Admins; quem decide é SÓ este serviço, no servidor):
--   * cargo "Owner" (Dono): quem está em OwnerUserIds, o criador da experiência ou,
--     se o jogo for de um grupo (comunidade), o dono do grupo;
--   * cargo "Admin": quem está em UserIds, membros do grupo com cargo >= GroupMinRank e,
--     no Roblox Studio, todo jogador de teste (StudioEveryoneAdmin).
--
-- Dois jeitos de usar:
--   * chat: ":fly", ":coins all 1000", ":ban Fulano 7d xingando" (prefixo = Config.Admins.ChatPrefix);
--   * painel do cliente: Net.Request("AdminCommand", nome, {argumentos em texto}) -> ok, mensagem.
-- Em cada pedido o servidor confere de novo se a pessoa é admin, valida os argumentos,
-- limita a frequência e escreve uma linha no Output começando com "[Admin]".
--
-- O que o servidor manda para o cliente:
--   * atributos do Player: IsAdmin (bool), AdminRole ("Owner"|"Admin"), AdminFly (bool) e,
--     só enquanto ":speed"/":jump" estão mudados, AdminWalkSpeed / AdminJumpPower (números);
--   * estado global "GlobalEvent" = nil ou {Key, Name, EndsAt (GetServerTimeNow), Effects};
--   * RemoteEvent "Announcement" {Text (já filtrado), From (nome de exibição), Duration (s)}.
--
-- Entre todos os servidores do jogo (lobby e partidas):
--   * MessagingService, tópico "BrainrotAdmin": avisos (":announce") e início/fim de evento;
--   * MemoryStoreService (HashMap, chave "Current"): o evento atual, para os servidores que
--     abrirem depois (ou que perderam a mensagem) também ligarem o evento.
--
-- API para os outros serviços (use com Svc("AdminService"), dentro de funções):
--   AdminService.IsAdmin(player) -> boolean
--   AdminService.GetRole(player) -> "Owner" | "Admin" | nil
--   AdminService.GetEventEffects() -> tabela Effects do evento ativo | nil  (só LER, nunca alterar)
--   AdminService.EventChanged: Signal(effects | nil)  -> dispara quando um evento começa ou acaba
--
-- Os eventos globais são GRÁTIS (um admin liga para todo mundo; ninguém paga Robux),
-- então não são "sorte paga" e não precisam mostrar chances.

local GroupService = game:GetService("GroupService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")
local TextChatService = game:GetService("TextChatService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Util.Net)
local Signal = require(Shared.Util.Signal)
local NumberFormat = require(Shared.Util.NumberFormat)
local PlaceRole = require(Shared.Util.PlaceRole)
local GameConfig = require(Shared.Config.Game)
local AdminsConfig = require(Shared.Config.Admins)

-- Serviço-folha (permitido no topo, regra 1.2 da especificação).
local StateService = require(script.Parent:WaitForChild("StateService"))

-- Outros serviços só dentro de funções (regra anti-require-circular).
local Services = script.Parent
local function Svc(name)
	return require(Services:WaitForChild(name))
end

local AdminService = {}
AdminService.EventChanged = Signal.new() -- (effects | nil)

-------------------------------------------------------------------------------
-- Constantes técnicas (não são balanceamento)
-------------------------------------------------------------------------------

local MESSAGING_TOPIC = "BrainrotAdmin" -- tópico do MessagingService (avisos e eventos)
local EVENT_MAP_NAME = "BrainrotAdminEvent_v1" -- HashMap do MemoryStore com o evento atual
local EVENT_STORE_KEY = "Current"

-- Limite de comandos por admin (token bucket, igual ao do Net): vale para o chat e o painel.
local COMMAND_RATE = 1 -- fichas recarregadas por segundo
local COMMAND_BURST = 5 -- rajada máxima
local ANNOUNCE_COOLDOWN = 10 -- segundos entre dois avisos do mesmo admin

-- Tamanhos máximos do que chega do cliente/chat.
local MAX_COMMAND_NAME_LENGTH = 24
local MAX_ARGS = 8 -- argumentos no painel
local MAX_ARG_LENGTH = 800 -- bytes por argumento (um aviso de 200 letras com acentos/emojis passa de 300 bytes)
local MAX_TEXT_BYTES = 1000 -- texto livre (aviso, motivo)
local MAX_CHAT_LENGTH = 500 -- mensagem de chat inteira
local MAX_CHAT_WORDS = 80
local ANNOUNCE_MAX_BYTES = 800 -- uma mensagem do MessagingService tem no máximo 1 kB
local REASON_MAX_LENGTH = 200 -- motivo de kick/ban (letras)
local BAN_DISPLAY_MAX = 400 -- limite do Roblox para DisplayReason
local BAN_PRIVATE_MAX = 1000 -- limite do Roblox para PrivateReason
local MAX_BAN_SECONDS = 365 * 86400 -- ban com tempo: até 1 ano (mais que isso, use "perm")
local MAX_NAME_BYTES = 64 -- nomes vindos de outros servidores
local MAX_LOG_BYTES = 600 -- tamanho máximo de cada texto do jogador escrito no Output

-- Cargo e grupo.
local ROLE_RETRY_SECONDS = 30 -- se a checagem do grupo falhou, tenta de novo depois disso
local GROUP_OWNER_RANK = 255 -- o dono do grupo sempre tem o cargo 255

-- Evento global.
local EVENT_TICK_INTERVAL = 1 -- confere a cada 1 s se o evento acabou
local EVENT_POLL_INTERVAL = 60 -- relê o MemoryStore (mensagens entre servidores podem se perder)
local EVENT_CLOCK_SLACK = 120 -- tolerância (s) para relógios um pouco diferentes entre servidores

-- MessagingService.
local SUBSCRIBE_ATTEMPTS = 5
local SUBSCRIBE_RETRY_DELAY = 5
local MAX_SEEN_MESSAGES = 100 -- ids de mensagens já tratadas (para não mostrar duas vezes)

-- Chat.
local CHAT_DEDUPE_WINDOW = 1 -- o chat novo e o antigo podem avisar a mesma mensagem duas vezes
local CMDS_NOTIFY_DURATION = 15 -- a lista de comandos fica mais tempo na tela
local ERROR_NOTIFY_DURATION = 5

-- Movimento.
local TP_OFFSET = 4 -- ":tp" para 4 studs atrás do jogador
local BRING_RADIUS = 5 -- ":bring" põe os jogadores numa roda de 5 studs em volta do admin
local DEFAULT_ANNOUNCE_DURATION = 8
local MAX_ANNOUNCE_DURATION = 30

-- Chuva de moedas.
local COIN_RAIN_RADIUS = 10 -- montinhos a 10 studs de cada jogador
local COIN_RAIN_SCATTER = 5 -- espalhamento de cada montinho
local MAX_COIN_RAIN_PILES = 12

-- Mensagens (português do Brasil).
local MSG_NO_PERMISSION = "Você não tem permissão para usar comandos de administrador."
local MSG_UNKNOWN = "Comando desconhecido. Use %scmds para ver a lista."
local MSG_MATCH_ONLY = "O comando %s%s só funciona dentro de uma partida (você está no lobby)."
local MSG_RATE_LIMIT = "Calma! Muitos comandos seguidos."
local MSG_PROTECTED = "Não é permitido expulsar ou banir um administrador (nem o dono do jogo)."
local MSG_ROLE_UNKNOWN =
	"Não deu para confirmar se esse usuário é administrador (o Roblox não respondeu). Tente de novo."
local MSG_ONE_PLAYER = 'Escolha um jogador só ("all" e "others" não valem para este comando).'
local MSG_NOT_READY = "A partida ainda está carregando. Tente de novo em instantes."
local MSG_NO_CHARACTER = "Seu personagem não está vivo agora."

-- Prefixo do chat (":" por padrão).
local PREFIX = if type(AdminsConfig.ChatPrefix) == "string" and AdminsConfig.ChatPrefix ~= ""
	then AdminsConfig.ChatPrefix
	else ":"

-- Comandos que aceitam um UserId de quem NÃO está no servidor (banir quem já saiu).
local OFFLINE_TARGET_COMMANDS = { ban = true }

-- Comandos de moderação: o alvo precisa ser EXATO (nome completo, nome de exibição completo
-- ou UserId). Aqui não vale "começo do nome": um erro de digitação não pode expulsar ou
-- banir a pessoa errada. E um número é sempre um UserId (nunca um nome feito de números).
local EXACT_TARGET_COMMANDS = { kick = true, ban = true }

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local roleCache = {} -- [userId] = {Role = "Owner"|"Admin"|false, Complete = boolean, CheckedAt = os.clock()}
local groupOwnerId = nil -- dono do grupo (se o jogo for de um grupo)
local groupOwnerLoaded = false
local buckets = {} -- [player] = {Tokens, Last}  (limite de frequência)
local lastAnnounce = {} -- [player] = os.clock() do último aviso
local lastChat = {} -- [player] = {Text, Time}
local deniedWarned = {} -- [player] = true depois do 1º aviso "sem permissão" no Output
local walkOverrides = {} -- [player] = velocidade escolhida no ":speed"
local jumpOverrides = {} -- [player] = força escolhida no ":jump"
local characterConnections = {} -- [player] = conexão que protege a velocidade do personagem atual
local currentEvent = nil -- {Key, EndsAt (os.time), StartedBy, Id, Stored}
local seenMessages = {} -- [id] = true
local seenOrder = {} -- {id} na ordem em que chegaram
local eventMap = nil -- MemoryStoreHashMap (criado na primeira vez que precisa)
local chatCommandsCreated = false
local started = false
local rng = Random.new()

-- Funções dos comandos: Handlers[nome] = function(ctx) -> ok, mensagem
-- ctx = {Player = admin, Role = cargo, Args = {argumentos já convertidos}, Def = definição, Name = nome}
local Handlers = {}

-------------------------------------------------------------------------------
-- Ajudantes gerais
-------------------------------------------------------------------------------

-- true se "value" é um jogador (objeto Player).
local function isPlayer(value)
	return typeof(value) == "Instance" and value:IsA("Player")
end

-- Tira os espaços do começo e do fim.
local function trim(text)
	return string.match(text, "^%s*(.-)%s*$")
end

-- Corta um texto (UTF-8 válido) em no máximo "maxChars" letras.
local function truncateUtf8(text, maxChars)
	local cut = utf8.offset(text, maxChars + 1)
	if cut then
		return string.sub(text, 1, cut - 1)
	end
	return text
end

-- "O Roblox respondeu com erro": pega só a primeira linha, curta, para mostrar ao admin.
local function shortError(err)
	local text = tostring(err)
	text = string.match(text, "^[^\n]*") or text
	if #text > 120 then
		text = string.sub(text, 1, 120) .. "..."
	end
	return text
end

-- Deixa um texto que veio do jogador seguro para o Output: troca quebras de linha e outros
-- caracteres de controle por espaço (assim ninguém "inventa" uma linha falsa de "[Admin]"
-- no registro) e corta textos enormes.
local function logSafe(value)
	local text = (string.gsub(tostring(value), "%c", " "))
	if #text > MAX_LOG_BYTES then
		text = string.sub(text, 1, MAX_LOG_BYTES) .. "..."
	end
	return text
end

-- Papel deste servidor ("Lobby" ou "Match"). O Main grava no atributo "Role".
local function getPlaceRole()
	local role = workspace:GetAttribute("Role")
	if role == "Lobby" or role == "Match" then
		return role
	end
	return PlaceRole.Get()
end

-- "2 horas", "30 minutos", "7 dias" ou "para sempre" (-1).
local function plural(count, singular, pluralWord)
	return ("%d %s"):format(count, if count == 1 then singular else pluralWord)
end
local function formatDuration(seconds)
	if seconds < 0 then
		return "para sempre"
	end
	seconds = math.floor(seconds + 0.5)
	if seconds >= 86400 and seconds % 86400 == 0 then
		return plural(seconds // 86400, "dia", "dias")
	end
	if seconds >= 3600 and seconds % 3600 == 0 then
		return plural(seconds // 3600, "hora", "horas")
	end
	return plural(math.max(1, math.floor(seconds / 60 + 0.5)), "minuto", "minutos")
end

-- Lista dos eventos para mostrar ao admin: "moedas2x (Moedas x2), sorte (...)".
local function eventList()
	local parts = {}
	local order = AdminsConfig.EventOrder or {}
	for _, key in ipairs(order) do
		local def = AdminsConfig.Events[key]
		if type(def) == "table" then
			table.insert(parts, ("%s (%s)"):format(key, tostring(def.Name)))
		end
	end
	return table.concat(parts, ", ")
end

-- Mostra um aviso no Output só uma vez por "key" (erros que se repetem a cada minuto,
-- como o MemoryStore desligado no Studio, não lotam o Output).
local warnedKeys = {}
local function warnOnce(key, message)
	if warnedKeys[key] then
		return
	end
	warnedKeys[key] = true
	warn(message)
end

-- Id único para as mensagens entre servidores (não é chamada web, não precisa de pcall).
local function newMessageId()
	return HttpService:GenerateGUID(false)
end

-- Lembra que uma mensagem já foi tratada (guarda só as últimas MAX_SEEN_MESSAGES).
local function markSeen(id)
	if type(id) ~= "string" or seenMessages[id] then
		return
	end
	seenMessages[id] = true
	table.insert(seenOrder, id)
	if #seenOrder > MAX_SEEN_MESSAGES then
		local oldest = table.remove(seenOrder, 1)
		seenMessages[oldest] = nil
	end
end

-------------------------------------------------------------------------------
-- Quem é admin
-------------------------------------------------------------------------------

-- true se a lista (do Config) tem este UserId.
local function listHas(list, userId)
	if type(list) ~= "table" then
		return false
	end
	for _, value in ipairs(list) do
		if tonumber(value) == userId then
			return true
		end
	end
	return false
end

-- true se o jogo pertence a um grupo (comunidade).
local function isGroupGame()
	return game.CreatorType == Enum.CreatorType.Group and game.CreatorId > 0
end

-- Dono do grupo dono do jogo (uma chamada web por servidor, depois fica guardado).
-- Devolve (ownerUserId ou nil, conseguiuLer).
local function getGroupOwnerId()
	if groupOwnerLoaded then
		return groupOwnerId, true
	end
	local ok, info = pcall(function()
		return GroupService:GetGroupInfoAsync(game.CreatorId)
	end)
	if not ok then
		warn("[AdminService] Não foi possível ler o dono do grupo: " .. tostring(info))
		return nil, false
	end
	groupOwnerLoaded = true
	local owner = type(info) == "table" and info.Owner or nil
	groupOwnerId = if type(owner) == "table" then tonumber(owner.Id) else nil
	return groupOwnerId, true
end

-- Maior cargo (0 a 255) do usuário no grupo dono do jogo (chamada web).
-- Devolve (rank, conseguiuLer).
local function getGroupRank(userId)
	local ok, result = pcall(function()
		return GroupService:GetRolesInGroupAsync(userId, game.CreatorId)
	end)
	if not ok then
		warn("[AdminService] Não foi possível ler o cargo no grupo: " .. tostring(result))
		return 0, false
	end
	local best = 0
	if type(result) == "table" and type(result.Roles) == "table" then
		for _, role in ipairs(result.Roles) do
			local rank = type(role) == "table" and tonumber(role.Rank) or nil
			if rank and rank > best then
				best = rank
			end
		end
	end
	return best, true
end

-- Calcula o cargo de um UserId (pode esperar chamadas web do grupo).
-- Devolve (cargo "Owner"|"Admin"|false, completo). "completo = false" quer dizer que uma
-- chamada web falhou: o resultado vale por ROLE_RETRY_SECONDS e depois é refeito.
local function computeRole(userId)
	if type(userId) ~= "number" then
		return false, true
	end

	-- 1. Donos escritos no Config (valem sempre, até se o jogo mudar para um grupo).
	if listHas(AdminsConfig.OwnerUserIds, userId) then
		return "Owner", true
	end

	local ownerIsAdmin = AdminsConfig.OwnerIsAdmin == true
	local complete = true

	-- 2. Criador da experiência (jogo de uma pessoa).
	if ownerIsAdmin and game.CreatorType == Enum.CreatorType.User and game.CreatorId > 0 and userId == game.CreatorId then
		return "Owner", true
	end

	-- 3. Jogo de um grupo: dono do grupo e cargos altos.
	if isGroupGame() then
		local minRank = math.floor(tonumber(AdminsConfig.GroupMinRank) or 0)
		local ownerKnown = false
		if ownerIsAdmin then
			local ownerId, okOwner = getGroupOwnerId()
			if okOwner and ownerId == userId then
				return "Owner", true
			end
			ownerKnown = okOwner
		end
		-- O cargo no grupo só é lido quando serve para algo (economiza chamadas web).
		if minRank > 0 or (ownerIsAdmin and not ownerKnown) then
			local rank, okRank = getGroupRank(userId)
			if not okRank then
				complete = false
			elseif ownerIsAdmin and rank >= GROUP_OWNER_RANK then
				return "Owner", true
			elseif minRank > 0 and rank >= minRank then
				return "Admin", true
			end
		end
	end

	-- 4. Admins escritos no Config.
	if listHas(AdminsConfig.UserIds, userId) then
		return "Admin", complete
	end

	-- 5. No Studio, todo jogador de teste é admin (se ligado no Config).
	if AdminsConfig.StudioEveryoneAdmin == true and RunService:IsStudio() then
		return "Admin", complete
	end

	return false, complete
end

-- Cargo de um UserId com cache. Refaz a conta se a última deu erro na web e já passou um tempo.
local function resolveRole(userId)
	local entry = roleCache[userId]
	if entry and (entry.Complete or os.clock() - entry.CheckedAt < ROLE_RETRY_SECONDS) then
		return entry
	end
	local role, complete = computeRole(userId)
	entry = { Role = role, Complete = complete, CheckedAt = os.clock() }
	roleCache[userId] = entry
	return entry
end

-- Grava os atributos que o cliente lê (o cliente só usa para mostrar o painel; quem
-- decide é sempre o servidor).
local function setRoleAttributes(player, role)
	if not isPlayer(player) then
		return
	end
	local isAdmin = role == "Owner" or role == "Admin"
	player:SetAttribute("IsAdmin", isAdmin)
	player:SetAttribute("AdminRole", if isAdmin then role else nil)
	if isAdmin then
		if player:GetAttribute("AdminFly") == nil then
			player:SetAttribute("AdminFly", false)
		end
	else
		player:SetAttribute("AdminFly", nil)
	end
end

-- AdminService.GetRole(player) -> "Owner" | "Admin" | nil
function AdminService.GetRole(player)
	if not isPlayer(player) then
		return nil
	end
	local before = roleCache[player.UserId]
	local entry = resolveRole(player.UserId)
	if entry ~= before then
		-- Conta nova (primeira vez ou nova tentativa depois de erro): atualiza os atributos.
		setRoleAttributes(player, entry.Role)
	end
	return entry.Role or nil
end

-- AdminService.IsAdmin(player) -> boolean
function AdminService.IsAdmin(player)
	return AdminService.GetRole(player) ~= nil
end

-------------------------------------------------------------------------------
-- Limite de frequência (token bucket, como no Net)
-------------------------------------------------------------------------------

local function consumeToken(player)
	local t = os.clock()
	local bucket = buckets[player]
	if not bucket then
		bucket = { Tokens = COMMAND_BURST, Last = t }
		buckets[player] = bucket
	else
		bucket.Tokens = math.min(COMMAND_BURST, bucket.Tokens + (t - bucket.Last) * COMMAND_RATE)
		bucket.Last = t
	end
	if bucket.Tokens < 1 then
		return false
	end
	bucket.Tokens -= 1
	return true
end

-------------------------------------------------------------------------------
-- Leitura dos argumentos (tipos do Config.Admins)
-------------------------------------------------------------------------------

-- ":coins <jogador> <quantia>" — como usar um comando.
local function usageOf(def)
	local parts = { PREFIX .. def.Name }
	for _, argDef in ipairs(def.Args or {}) do
		table.insert(parts, if argDef.Optional then "[" .. argDef.Name .. "]" else "<" .. argDef.Name .. ">")
	end
	return table.concat(parts, " ")
end

-- Argumento "player". Devolve {List = {Player}, Multi = boolean, OfflineUserId = número?}
-- ou (nil, mensagem de erro).
--   "me"/"eu" = você; "all"/"todos" = todos; "others"/"outros" = todos menos você;
--   número = UserId; senão nome exato, nome de exibição exato, começo do nome, começo
--   do nome de exibição (nessa ordem; sem diferença de maiúsculas).
--   allowOffline = aceita o UserId de quem não está no servidor (só o ":ban").
--   exactOnly = moderação (":kick"/":ban"): sem "começo do nome", e número é só UserId.
-- Um número nunca é lido como "começo do nome": o painel manda o UserId, e se essa pessoa
-- acabou de sair, o comando não pode cair em outro jogador cujo nome começa com os mesmos dígitos.
local function resolvePlayers(query, caller, allowOffline, exactOnly)
	local lower = string.lower(query)
	if lower == "me" or lower == "eu" then
		return { List = { caller }, Multi = false }
	end
	if lower == "all" or lower == "todos" then
		return { List = Players:GetPlayers(), Multi = true }
	end
	if lower == "others" or lower == "outros" then
		local list = {}
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= caller then
				table.insert(list, other)
			end
		end
		if #list == 0 then
			return nil, "Não há outros jogadores neste servidor"
		end
		return { List = list, Multi = true }
	end

	-- Só dígitos = número. Até 15 dígitos pode ser um UserId (mais que isso nunca é).
	local isNumeric = string.match(query, "^%d+$") ~= nil
	if isNumeric and #query <= 15 then
		local byId = Players:GetPlayerByUserId(tonumber(query))
		if byId then
			return { List = { byId }, Multi = false }
		end
	end

	-- Procura pelo nome, do jeito mais exato para o menos exato.
	-- Na moderação, um número é SEMPRE um UserId (pula a busca por nome).
	local tests = {}
	if not (exactOnly and isNumeric) then
		table.insert(tests, function(other)
			return string.lower(other.Name) == lower
		end)
		table.insert(tests, function(other)
			return string.lower(other.DisplayName) == lower
		end)
	end
	if not exactOnly and not isNumeric then
		table.insert(tests, function(other)
			return string.sub(string.lower(other.Name), 1, #lower) == lower
		end)
		table.insert(tests, function(other)
			return string.sub(string.lower(other.DisplayName), 1, #lower) == lower
		end)
	end
	for _, matches in ipairs(tests) do
		local found = {}
		for _, other in ipairs(Players:GetPlayers()) do
			if matches(other) then
				table.insert(found, other)
			end
		end
		if #found == 1 then
			return { List = found, Multi = false }
		elseif #found > 1 then
			local names = {}
			for index, other in ipairs(found) do
				if index > 5 then
					break
				end
				table.insert(names, other.Name)
			end
			return nil,
				('Mais de um jogador combina com "%s" (%s). %s'):format(
					query,
					table.concat(names, ", "),
					if exactOnly then "Use o nome de usuário ou o UserId" else "Escreva mais letras do nome"
				)
		end
	end

	-- UserId de quem não está aqui (só para banir quem já saiu).
	if allowOffline and isNumeric and #query <= 15 then
		local userId = tonumber(query)
		if userId and userId > 0 and userId < 1e15 then
			return { List = {}, Multi = false, OfflineUserId = userId }
		end
	end
	if exactOnly then
		return nil,
			('Jogador "%s" não encontrado neste servidor (aqui vale só o nome completo, o nome de exibição completo ou o UserId)'):format(
				query
			)
	end
	return nil, ('Jogador "%s" não encontrado neste servidor'):format(query)
end

-- Argumento "duration": "30m", "2h", "1d", "7d" -> segundos; "perm" -> -1.
local DURATION_UNITS = { m = 60, h = 3600, d = 86400 }
local PERMANENT_WORDS = { perm = true, permanente = true, sempre = true }
local function parseDuration(text)
	local lower = string.lower(text)
	if PERMANENT_WORDS[lower] then
		return -1
	end
	local amount, unit = string.match(lower, "^(%d+)%s*([mhd])$")
	local value = tonumber(amount)
	if not value or value <= 0 then
		return nil
	end
	local seconds = value * DURATION_UNITS[unit]
	if seconds > MAX_BAN_SECONDS then
		return nil
	end
	return seconds
end

-- Converte um argumento de texto no tipo certo. Devolve (valor) ou (nil, mensagem).
local function parseValue(argDef, raw, caller, def)
	local kind = argDef.Type
	if kind == "player" then
		return resolvePlayers(
			raw,
			caller,
			OFFLINE_TARGET_COMMANDS[def.Name] == true,
			EXACT_TARGET_COMMANDS[def.Name] == true
		)
	elseif kind == "number" then
		local value = Svc("DebugService").ParseNumber(raw)
		if value == nil then
			return nil, ('"%s" não é um número'):format(raw)
		end
		if argDef.Integer then
			value = math.floor(value)
		end
		local minValue, maxValue = tonumber(argDef.Min), tonumber(argDef.Max)
		if minValue and maxValue and (value < minValue or value > maxValue) then
			return nil,
				("<%s> precisa ser de %s a %s"):format(
					argDef.Name,
					NumberFormat.Abbrev(minValue),
					NumberFormat.Abbrev(maxValue)
				)
		elseif minValue and value < minValue then
			return nil, ("<%s> precisa ser pelo menos %s"):format(argDef.Name, NumberFormat.Abbrev(minValue))
		elseif maxValue and value > maxValue then
			return nil, ("<%s> pode ser no máximo %s"):format(argDef.Name, NumberFormat.Abbrev(maxValue))
		end
		return value
	elseif kind == "text" then
		if not utf8.len(raw) then
			return nil, "Texto inválido"
		end
		if #raw > MAX_TEXT_BYTES then
			return nil, "Texto grande demais"
		end
		return raw
	elseif kind == "duration" then
		local seconds = parseDuration(raw)
		if not seconds then
			return nil, "Duração inválida (use 30m, 2h, 1d, 7d ou perm)"
		end
		return seconds
	elseif kind == "event" then
		local key = string.lower(raw)
		if type(AdminsConfig.Events[key]) ~= "table" then
			return nil, "Evento desconhecido. Eventos: " .. eventList()
		end
		return key
	end
	return nil, "Tipo de argumento desconhecido no Config.Admins: " .. tostring(kind)
end

-- Lê todos os argumentos de um comando. rawArgs = lista de textos.
-- O último argumento do tipo "text" junta o resto das palavras ("motivo com espaços").
-- Devolve (lista de valores) ou (nil, mensagem com o jeito certo de usar).
local function parseArgs(def, rawArgs, caller)
	local parsed = {}
	local argDefs = def.Args or {}
	for index, argDef in ipairs(argDefs) do
		local raw = rawArgs[index]
		if argDef.Type == "text" and index == #argDefs and #rawArgs > index then
			raw = table.concat(rawArgs, " ", index)
		end
		raw = if type(raw) == "string" then trim(raw) else nil

		if raw == nil or raw == "" then
			if not argDef.Optional then
				return nil, ("Falta <%s>. Use: %s"):format(argDef.Name, usageOf(def))
			end
			-- Jogador opcional ausente = você mesmo. Os outros opcionais ficam vazios (nil).
			if argDef.Type == "player" then
				parsed[index] = { List = { caller }, Multi = false }
			end
		else
			local value, err = parseValue(argDef, raw, caller, def)
			if value == nil then
				return nil, ("%s. Use: %s"):format(err or "Argumento inválido", usageOf(def))
			end
			parsed[index] = value
		end
	end
	return parsed
end

-------------------------------------------------------------------------------
-- Ajudantes dos comandos
-------------------------------------------------------------------------------

-- Parte principal do personagem vivo: (root, character, humanoid) ou nil.
local function getRoot(player)
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root, character, humanoid
end

-- Aplica no personagem a velocidade/pulo escolhidos pelo admin.
-- restore = true volta ao normal o que não tem mais valor escolhido.
local function applyMovement(player, restore)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local walk = walkOverrides[player]
	if walk then
		humanoid.WalkSpeed = walk
	elseif restore then
		humanoid.WalkSpeed = GameConfig.WalkSpeed
	end
	local jump = jumpOverrides[player]
	if jump then
		humanoid.UseJumpPower = true
		humanoid.JumpPower = jump
	elseif restore then
		humanoid.UseJumpPower = StarterPlayer.CharacterUseJumpPower
		humanoid.JumpPower = StarterPlayer.CharacterJumpPower
		humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
	end
end

-- Liga a velocidade/pulo escolhidos no personagem atual e protege a velocidade: se outro
-- serviço do servidor (ex.: MatchService, logo depois de nascer) mudar a WalkSpeed, volta
-- para a escolhida. (Mudanças feitas pelo cliente não chegam ao servidor, então não brigam.)
local function watchMovement(player)
	if characterConnections[player] then
		characterConnections[player]:Disconnect()
		characterConnections[player] = nil
	end
	if not walkOverrides[player] and not jumpOverrides[player] then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	applyMovement(player, false)
	characterConnections[player] = humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
		local walk = walkOverrides[player]
		if walk and player.Character == character and humanoid.WalkSpeed ~= walk then
			humanoid.WalkSpeed = walk
		end
	end)
end

-- Personagem novo: reaplica velocidade/pulo (o Humanoid novo nasce com os valores padrão).
local function onCharacterAdded(player, character)
	if not walkOverrides[player] and not jumpOverrides[player] then
		return
	end
	task.spawn(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
		if humanoid and player.Character == character then
			watchMovement(player)
		end
	end)
end

-- Roda um comando do DebugService em cada alvo (moedas, tokens, ingredientes...).
-- Quem recebe (se não for o próprio admin) ganha um aviso na tela.
local function runDebugOnTargets(ctx, debugName, targets, arg)
	if #targets == 0 then
		return false, "Nenhum jogador encontrado."
	end
	local DebugService = Svc("DebugService")
	local okCount = 0
	local singleMessage = nil
	local lastError = nil
	for _, target in ipairs(targets) do
		local ok, message = DebugService.RunCommand(target, debugName, arg, ctx.Player)
		message = tostring(message or "")
		if ok then
			okCount += 1
			if target ~= ctx.Player then
				StateService.Notify(target, ("%s (admin: %s)"):format(message, ctx.Player.DisplayName), "success")
			end
		else
			lastError = ("%s: %s"):format(target.DisplayName, message)
		end
		singleMessage = if target == ctx.Player then message else ("%s: %s"):format(target.DisplayName, message)
	end
	if #targets == 1 then
		return okCount == 1, singleMessage
	end
	local text = ("Feito para %d de %d jogadores."):format(okCount, #targets)
	if lastError then
		text ..= " Último erro: " .. lastError
	end
	return okCount > 0, text
end

-- Roda um comando do DebugService que vale para a partida inteira (wave, maxall...).
local function runDebugForMatch(ctx, debugName, arg)
	return Svc("DebugService").RunCommand(ctx.Player, debugName, arg, ctx.Player)
end

-- Filtra um texto do admin para UMA pessoa ler (motivo do kick). nil se o filtro falhar.
local function filterForUser(text, fromPlayer, toUserId)
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(text, fromPlayer.UserId, Enum.TextFilterContext.PrivateChat)
		return result:GetNonChatStringForUserAsync(toUserId)
	end)
	if ok and type(filtered) == "string" and filtered ~= "" then
		return filtered
	end
	if not ok then
		warn("[AdminService] Filtro de texto falhou: " .. tostring(filtered))
	end
	return nil
end

-------------------------------------------------------------------------------
-- Avisos entre servidores (":announce")
-------------------------------------------------------------------------------

-- Duração da faixa do aviso na tela (segundos), lida do Config com valor seguro.
local function announceDuration()
	local value = tonumber(AdminsConfig.AnnounceDuration) or DEFAULT_ANNOUNCE_DURATION
	return math.clamp(value, 1, MAX_ANNOUNCE_DURATION)
end

-- Mostra o aviso para todos os jogadores deste servidor.
local function showAnnouncement(text, from, duration)
	Net.FireAll("Announcement", { Text = text, From = from, Duration = duration })
end

-- Publica uma mensagem para todos os servidores (inclusive este). Devolve true se deu certo.
local function publish(data)
	local ok, err = pcall(function()
		MessagingService:PublishAsync(MESSAGING_TOPIC, data)
	end)
	if not ok then
		warn("[AdminService] Não foi possível avisar os outros servidores: " .. tostring(err))
	end
	return ok
end

-------------------------------------------------------------------------------
-- Evento global (":event" / ":endevent")
-------------------------------------------------------------------------------

-- O HashMap do MemoryStore onde fica o evento atual (nil se o serviço não estiver disponível).
local function getEventMap()
	if eventMap then
		return eventMap
	end
	local ok, map = pcall(function()
		return MemoryStoreService:GetHashMap(EVENT_MAP_NAME)
	end)
	if ok then
		eventMap = map
	else
		warnOnce("GetHashMap", "[AdminService] MemoryStore indisponível: " .. tostring(map))
	end
	return eventMap
end

-- Confere um evento vindo do MemoryStore ou de outro servidor. Devolve uma cópia limpa ou nil.
local function sanitizeRecord(record)
	if type(record) ~= "table" then
		return nil
	end
	local key = record.Key
	if type(key) ~= "string" or type(AdminsConfig.Events[key]) ~= "table" then
		return nil
	end
	local endsAt = tonumber(record.EndsAt)
	if not endsAt or endsAt ~= endsAt then
		return nil
	end
	local now = os.time()
	local maxSeconds = (tonumber(AdminsConfig.MaxMinutes) or 0) * 60
	if endsAt <= now or endsAt - now > maxSeconds + EVENT_CLOCK_SLACK then
		return nil -- já acabou, ou dura mais do que o permitido
	end
	local startedBy = record.StartedBy
	if type(startedBy) ~= "string" or #startedBy > MAX_NAME_BYTES or not utf8.len(startedBy) then
		startedBy = "um admin"
	end
	return {
		Key = key,
		EndsAt = endsAt,
		StartedBy = startedBy,
		Id = if type(record.Id) == "string" and #record.Id <= MAX_NAME_BYTES then record.Id else nil,
		Stored = record.Stored == true,
	}
end

-- Publica a chave de estado "GlobalEvent" (o cliente mostra a faixa com o tempo restante).
-- EndsAt vai no relógio compartilhado (GetServerTimeNow), que é o que o cliente usa.
local function publishEventState()
	if not currentEvent then
		StateService.SetAll("GlobalEvent", nil)
		return
	end
	local def = AdminsConfig.Events[currentEvent.Key]
	local remaining = math.max(0, currentEvent.EndsAt - os.time())
	StateService.SetAll("GlobalEvent", {
		Key = currentEvent.Key,
		Name = def.Name,
		EndsAt = workspace:GetServerTimeNow() + remaining,
		Effects = table.clone(def.Effects or {}),
	})
end

-- O evento mudou: na partida os stats (sorte, gigantes, moedas na tela) são recalculados.
local function onEventChanged()
	local effects = AdminService.GetEventEffects()
	if getPlaceRole() == "Match" then
		local ok, err = pcall(function()
			Svc("StatService").Invalidate()
		end)
		if not ok then
			warn("[AdminService] Erro ao recalcular os stats: " .. tostring(err))
		end
	end
	AdminService.EventChanged:Fire(effects)
end

-- Liga um evento neste servidor. announce = mostra o aviso para os jogadores.
local function applyEvent(record, announce)
	if currentEvent and record.Id ~= nil and currentEvent.Id == record.Id and currentEvent.EndsAt == record.EndsAt then
		return -- já é o evento atual (ex.: a mensagem voltou para o servidor que mandou)
	end
	currentEvent = record
	publishEventState()
	onEventChanged()
	if announce then
		local def = AdminsConfig.Events[record.Key]
		StateService.NotifyAll(
			("Evento %s ligado por %s! %s"):format(
				tostring(def.Name),
				formatDuration(record.EndsAt - os.time()),
				tostring(def.Description or "")
			),
			"rare",
			8
		)
	end
end

-- Desliga o evento deste servidor. announce = avisa os jogadores.
local function clearEvent(announce)
	if not currentEvent then
		return
	end
	local def = AdminsConfig.Events[currentEvent.Key]
	currentEvent = nil
	publishEventState()
	onEventChanged()
	if announce then
		StateService.NotifyAll(("O evento %s acabou."):format(tostring(def and def.Name or "")), "info", 6)
	end
end

-- Lê o evento guardado no MemoryStore e liga/desliga aqui para ficar igual.
-- announce = avisa os jogadores se algo mudar (falso na abertura do servidor).
local function syncFromStore(announce)
	local map = getEventMap()
	if not map then
		return
	end
	local ok, value = pcall(function()
		return map:GetAsync(EVENT_STORE_KEY)
	end)
	if not ok then
		warnOnce("GetAsync", "[AdminService] Não foi possível ler o evento no MemoryStore: " .. tostring(value))
		return
	end
	local record = sanitizeRecord(value)
	if record then
		record.Stored = true
		applyEvent(record, announce)
	elseif currentEvent and currentEvent.Stored then
		-- O evento sumiu do MemoryStore (acabou ou foi encerrado) e a mensagem se perdeu.
		clearEvent(announce)
	end
end

-- AdminService.GetEventEffects() -> Effects do evento ativo (tabela do Config; só ler) ou nil.
function AdminService.GetEventEffects()
	if currentEvent and os.time() < currentEvent.EndsAt then
		local def = AdminsConfig.Events[currentEvent.Key]
		return def and def.Effects or nil
	end
	return nil
end

-------------------------------------------------------------------------------
-- Mensagens de outros servidores (MessagingService)
-------------------------------------------------------------------------------

local function handleMessage(message)
	local data = type(message) == "table" and message.Data or nil
	if type(data) ~= "table" or type(data.Kind) ~= "string" then
		return
	end
	if type(data.Id) == "string" then
		if seenMessages[data.Id] then
			return -- já tratada (é a nossa própria mensagem voltando)
		end
		markSeen(data.Id)
	end

	if data.Kind == "Announce" then
		-- O texto já foi filtrado no servidor de quem mandou; aqui só conferimos o formato.
		local text, from = data.Text, data.From
		if type(text) ~= "string" or text == "" or #text > ANNOUNCE_MAX_BYTES * 2 or not utf8.len(text) then
			return
		end
		if type(from) ~= "string" or #from > MAX_NAME_BYTES or not utf8.len(from) then
			from = "Admin"
		end
		local duration = math.clamp(tonumber(data.Duration) or DEFAULT_ANNOUNCE_DURATION, 1, MAX_ANNOUNCE_DURATION)
		showAnnouncement(text, from, duration)
	elseif data.Kind == "Event" then
		local record = sanitizeRecord(data.Event)
		if record then
			applyEvent(record, true)
		end
	elseif data.Kind == "EventEnd" then
		-- Só desliga se for o mesmo evento (um "fim" atrasado não apaga um evento novo).
		if currentEvent and (data.EventId == nil or data.EventId == currentEvent.Id) then
			clearEvent(true)
		end
	end
end

-- Assina o tópico (tenta algumas vezes; no Studio sem acesso às APIs pode falhar).
local function subscribe()
	local lastError = nil
	for attempt = 1, SUBSCRIBE_ATTEMPTS do
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(MESSAGING_TOPIC, function(message)
				local success, handlerErr = pcall(handleMessage, message)
				if not success then
					warn("[AdminService] Erro ao tratar mensagem de outro servidor: " .. tostring(handlerErr))
				end
			end)
		end)
		if ok then
			return
		end
		lastError = err
		if attempt < SUBSCRIBE_ATTEMPTS then
			task.wait(SUBSCRIBE_RETRY_DELAY * attempt)
		end
	end
	warn(
		"[AdminService] Não foi possível ouvir os outros servidores (avisos e eventos vindos de lá não vão chegar): "
			.. tostring(lastError)
	)
end

-------------------------------------------------------------------------------
-- Comandos: movimento
-------------------------------------------------------------------------------

-- Voo: o servidor só liga/desliga o atributo AdminFly; o voo em si é física do cliente.
Handlers.fly = function(ctx)
	local player = ctx.Player
	local on = player:GetAttribute("AdminFly") ~= true
	player:SetAttribute("AdminFly", on)
	return true, if on then "Voo ligado!" else "Voo desligado."
end

Handlers.speed = function(ctx)
	local player = ctx.Player
	local value = ctx.Args[1]
	if math.abs(value - GameConfig.WalkSpeed) < 1e-3 then
		walkOverrides[player] = nil
	else
		walkOverrides[player] = value
	end
	player:SetAttribute("AdminWalkSpeed", walkOverrides[player])
	applyMovement(player, true)
	watchMovement(player)
	if walkOverrides[player] == nil then
		return true, "Sua velocidade voltou ao normal."
	end
	return true, ("Sua velocidade agora é %s."):format(NumberFormat.Abbrev(value))
end

Handlers.jump = function(ctx)
	local player = ctx.Player
	local value = ctx.Args[1]
	if math.abs(value - StarterPlayer.CharacterJumpPower) < 1e-3 then
		jumpOverrides[player] = nil
	else
		jumpOverrides[player] = value
	end
	player:SetAttribute("AdminJumpPower", jumpOverrides[player])
	applyMovement(player, true)
	watchMovement(player)
	if jumpOverrides[player] == nil then
		return true, "Seu pulo voltou ao normal."
	end
	return true, ("A força do seu pulo agora é %s."):format(NumberFormat.Abbrev(value))
end

Handlers.tp = function(ctx)
	local target = ctx.Args[1]
	if target.Multi or #target.List ~= 1 then
		return false, MSG_ONE_PLAYER
	end
	local other = target.List[1]
	if other == ctx.Player then
		return false, "Você já está aí!"
	end
	local _, myCharacter = getRoot(ctx.Player)
	if not myCharacter then
		return false, MSG_NO_CHARACTER
	end
	local otherRoot = getRoot(other)
	if not otherRoot then
		return false, other.DisplayName .. " não está com o personagem vivo agora."
	end
	myCharacter:PivotTo(otherRoot.CFrame * CFrame.new(0, 0, TP_OFFSET))
	return true, "Você foi até " .. other.DisplayName .. "."
end

Handlers.bring = function(ctx)
	local myRoot = getRoot(ctx.Player)
	if not myRoot then
		return false, MSG_NO_CHARACTER
	end
	local others = {}
	for _, other in ipairs(ctx.Args[1].List) do
		if other ~= ctx.Player then
			table.insert(others, other)
		end
	end
	if #others == 0 then
		return false, "Escolha outro jogador (você já está aqui)."
	end
	-- Põe todo mundo numa roda em volta do admin, olhando para ele.
	local brought = 0
	for index, other in ipairs(others) do
		local _, character = getRoot(other)
		if character then
			local angle = (index - 1) / #others * math.pi * 2
			local position = myRoot.Position + Vector3.new(math.sin(angle), 0, -math.cos(angle)) * BRING_RADIUS
			local lookAt = Vector3.new(myRoot.Position.X, position.Y, myRoot.Position.Z)
			character:PivotTo(CFrame.lookAt(position, lookAt))
			brought += 1
		end
	end
	if brought == 0 then
		return false, "Ninguém com o personagem vivo para trazer agora."
	end
	if #others == 1 then
		return true, others[1].DisplayName .. " veio até você."
	end
	return true, ("%d jogadores vieram até você."):format(brought)
end

Handlers.respawn = function(ctx)
	local list = ctx.Args[1].List
	if #list == 0 then
		return false, "Nenhum jogador encontrado."
	end
	for _, target in ipairs(list) do
		-- LoadCharacterAsync espera o personagem carregar: roda em outra thread.
		task.spawn(function()
			local ok, err = pcall(function()
				target:LoadCharacterAsync()
			end)
			if not ok then
				warn("[AdminService] Erro ao renascer " .. target.Name .. ": " .. tostring(err))
			end
		end)
	end
	if #list == 1 then
		return true, if list[1] == ctx.Player then "Renascendo..." else list[1].DisplayName .. " vai renascer."
	end
	return true, ("%d jogadores vão renascer."):format(#list)
end

-------------------------------------------------------------------------------
-- Comandos: partida (reaproveitam o DebugService quando dá)
-------------------------------------------------------------------------------

Handlers.coins = function(ctx)
	return runDebugOnTargets(ctx, "coins", ctx.Args[1].List, ctx.Args[2])
end

Handlers.wave = function(ctx)
	return runDebugForMatch(ctx, "wave")
end

-- Leva só de gigantes, na hora (sem esperar a recarga do quadro).
Handlers.giant = function(ctx)
	local ok, message = Svc("BrainrotService").SpawnWave(ctx.Player, { AllGiant = true, IgnoreCooldown = true })
	if ok then
		return true, "Leva de gigantes! " .. tostring(message or "")
	end
	return false, tostring(message or "Não foi possível plantar agora.")
end

-- Chuva de moedas: montinhos em volta de cada jogador vivo (as moedas são pegas andando).
Handlers.coinrain = function(ctx)
	local MatchService = Svc("MatchService")
	local mapDef = MatchService.GetMapDef()
	if not mapDef then
		return false, MSG_NOT_READY
	end
	local perPlayer = ctx.Args[1] or (tonumber(AdminsConfig.CoinRainDefault) or 0) * (tonumber(mapDef.CostScale) or 1)
	if perPlayer <= 0 then
		return false, "Use: " .. usageOf(ctx.Def)
	end
	local piles = math.clamp(math.floor(tonumber(AdminsConfig.CoinRainPiles) or 1), 1, MAX_COIN_RAIN_PILES)
	local CoinService = Svc("CoinService")
	local count = 0
	for _, other in ipairs(Players:GetPlayers()) do
		local root = getRoot(other)
		if root then
			count += 1
			local startAngle = rng:NextNumber(0, math.pi * 2)
			for pile = 1, piles do
				local angle = startAngle + (pile - 1) / piles * math.pi * 2
				local position = root.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * COIN_RAIN_RADIUS
				CoinService.SpawnCoins(perPlayer / piles, position, { AtPosition = true, Scatter = COIN_RAIN_SCATTER })
			end
		end
	end
	if count == 0 then
		return false, "Nenhum jogador com o personagem vivo agora."
	end
	StateService.NotifyAll("Chuva de moedas! Pegue as moedas em volta de você.", "rare", 5)
	return true, ("Chuva de %s moedas para cada um de %d jogador(es)."):format(NumberFormat.Abbrev(perPlayer), count)
end

Handlers.maxall = function(ctx)
	return runDebugForMatch(ctx, "maxall")
end

Handlers.nextact = function(ctx)
	return runDebugForMatch(ctx, "nextact")
end

Handlers.supreme = function(ctx)
	return runDebugForMatch(ctx, "supreme", ctx.Args[1])
end

Handlers.ingredients = function(ctx)
	return runDebugOnTargets(ctx, "ingredients", ctx.Args[1].List)
end

-------------------------------------------------------------------------------
-- Comandos: perfil
-------------------------------------------------------------------------------

Handlers.tokens = function(ctx)
	-- Tirar tokens (número negativo) é só de um jogador por vez: um ":tokens all -1000"
	-- digitado sem querer apagaria para sempre os tokens de todo mundo do servidor.
	if ctx.Args[2] < 0 and ctx.Args[1].Multi then
		return false, 'Para tirar tokens, escolha um jogador só ("all" e "others" só valem para dar).'
	end
	return runDebugOnTargets(ctx, "tokens", ctx.Args[1].List, ctx.Args[2])
end

Handlers.unlockall = function(ctx)
	return runDebugOnTargets(ctx, "unlockall", ctx.Args[1].List)
end

-------------------------------------------------------------------------------
-- Comandos: avisos e eventos (todos os servidores)
-------------------------------------------------------------------------------

Handlers.announce = function(ctx)
	local player = ctx.Player
	local text = ctx.Args[1]
	local maxLength = math.floor(tonumber(AdminsConfig.AnnounceMaxLength) or 0)
	local length = utf8.len(text)
	if not length then
		return false, "Texto inválido."
	end
	if length > maxLength or #text > ANNOUNCE_MAX_BYTES then
		return false, ("Aviso grande demais (máximo de %d letras)."):format(maxLength)
	end
	local last = lastAnnounce[player]
	if last and os.clock() - last < ANNOUNCE_COOLDOWN then
		return false, ("Espere %d s para mandar outro aviso."):format(math.ceil(ANNOUNCE_COOLDOWN - (os.clock() - last)))
	end

	-- Filtro de texto do Roblox: obrigatório para um texto que todo mundo vai ler.
	-- Se o filtro falhar, o aviso NÃO é mostrado (regra do Roblox).
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return result:GetNonChatStringForBroadcastAsync()
	end)
	if not ok or type(filtered) ~= "string" or filtered == "" then
		warn("[AdminService] Filtro de texto falhou no aviso: " .. tostring(filtered))
		return false, "O filtro de texto do Roblox não respondeu. O aviso não foi enviado; tente de novo."
	end
	lastAnnounce[player] = os.clock()

	local id = newMessageId()
	local duration = announceDuration()
	markSeen(id) -- quando a mensagem voltar para este servidor, não mostra de novo
	showAnnouncement(filtered, player.DisplayName, duration)
	local published = publish({
		Kind = "Announce",
		Id = id,
		Text = filtered,
		From = player.DisplayName,
		Duration = duration,
	})
	if published then
		return true, "Aviso enviado para todos os servidores."
	end
	return true, "Aviso mostrado neste servidor, mas não deu para enviar aos outros servidores agora."
end

Handlers.event = function(ctx)
	local key = ctx.Args[1]
	local minutes = ctx.Args[2]
	local def = AdminsConfig.Events[key]
	local seconds = math.max(60, math.floor(minutes * 60))
	local record = {
		Key = key,
		EndsAt = os.time() + seconds,
		StartedBy = ctx.Player.DisplayName,
		Id = newMessageId(),
	}

	-- 1. Guarda no MemoryStore (servidores que abrirem depois leem daqui). Expira sozinho.
	local stored = false
	local map = getEventMap()
	if map then
		local ok, err = pcall(function()
			map:SetAsync(EVENT_STORE_KEY, {
				Key = record.Key,
				EndsAt = record.EndsAt,
				StartedBy = record.StartedBy,
				Id = record.Id,
			}, seconds)
		end)
		stored = ok
		if not ok then
			warn("[AdminService] Não foi possível salvar o evento no MemoryStore: " .. tostring(err))
		end
	end
	record.Stored = stored

	-- 2. Liga aqui na hora.
	applyEvent(record, true)

	-- 3. Avisa os outros servidores.
	local messageId = newMessageId()
	markSeen(messageId)
	local published = publish({ Kind = "Event", Id = messageId, Event = record })

	local text = ('Evento "%s" ligado por %s.'):format(tostring(def.Name), formatDuration(seconds))
	if not stored or not published then
		text ..= " Atenção: não deu para avisar todos os servidores agora (neste ele já está valendo)."
	end
	return true, text
end

Handlers.endevent = function(ctx)
	local hadEvent = currentEvent ~= nil
	local eventId = currentEvent and currentEvent.Id or nil

	-- 1. Apaga do MemoryStore. Se não der, os servidores leem o evento de novo lá (a cada
	-- EVENT_POLL_INTERVAL s) e ele VOLTA: o admin precisa saber para tentar de novo.
	local removed = true
	local map = getEventMap()
	if map then
		local ok, err = pcall(function()
			map:RemoveAsync(EVENT_STORE_KEY)
		end)
		if not ok then
			removed = false
			warn("[AdminService] Não foi possível apagar o evento do MemoryStore: " .. tostring(err))
		end
	end

	-- 2. Desliga aqui e 3. avisa os outros servidores.
	clearEvent(true)
	local messageId = newMessageId()
	markSeen(messageId)
	local published = publish({ Kind = "EventEnd", Id = messageId, EventId = eventId })

	if not removed then
		return false,
			('O evento foi desligado agora, mas o Roblox não deixou apagar o evento salvo: ele pode voltar em até %d s. Encerre de novo (%sendevent ou o botão "Encerrar evento" do painel).'):format(
				EVENT_POLL_INTERVAL,
				PREFIX
			)
	end
	if not hadEvent then
		return true, "Não havia evento ativo neste servidor. O pedido de encerrar foi enviado aos outros servidores."
	end
	if not published then
		return true, "Evento encerrado neste servidor, mas não deu para avisar os outros servidores agora."
	end
	return true, "Evento encerrado em todos os servidores."
end

-------------------------------------------------------------------------------
-- Comandos: moderação
-------------------------------------------------------------------------------

-- Pode expulsar/banir este UserId? Devolve nil (pode) ou a mensagem de recusa.
-- Admins e o dono são protegidos. Se o Roblox não respondeu sobre o cargo (grupo),
-- recusa também: na dúvida, é melhor não expulsar um possível admin.
local function protectionError(userId)
	local entry = resolveRole(userId)
	if entry.Role then
		return MSG_PROTECTED
	end
	if not entry.Complete then
		return MSG_ROLE_UNKNOWN
	end
	return nil
end

Handlers.kick = function(ctx)
	local target = ctx.Args[1]
	if target.Multi or #target.List ~= 1 then
		return false, MSG_ONE_PLAYER
	end
	local victim = target.List[1]
	local refusal = protectionError(victim.UserId)
	if refusal then
		return false, refusal
	end

	local message = "Você foi expulso do servidor por um administrador."
	local reason = ctx.Args[2]
	if reason then
		if utf8.len(reason) > REASON_MAX_LENGTH then
			return false, ("Motivo grande demais (máximo de %d letras)."):format(REASON_MAX_LENGTH)
		end
		-- O motivo vai ser lido pelo jogador expulso: passa pelo filtro do Roblox.
		local filtered = filterForUser(reason, ctx.Player, victim.UserId)
		if filtered then
			message ..= "\nMotivo: " .. filtered
		end
	end
	victim:Kick(message)
	return true, victim.Name .. " foi expulso do servidor."
end

Handlers.ban = function(ctx)
	local target = ctx.Args[1]
	if target.Multi or #target.List > 1 then
		return false, MSG_ONE_PLAYER
	end
	local victim = target.List[1]
	local userId = if victim then victim.UserId else target.OfflineUserId
	if type(userId) ~= "number" then
		return false, "Jogador não encontrado."
	end

	-- Protege admins e o dono (também quem não está neste servidor).
	local refusal = protectionError(userId)
	if refusal then
		return false, refusal
	end

	local seconds = ctx.Args[2]
	local reason = ctx.Args[3]
	if reason and utf8.len(reason) > REASON_MAX_LENGTH then
		return false, ("Motivo grande demais (máximo de %d letras)."):format(REASON_MAX_LENGTH)
	end

	-- DisplayReason: o que a pessoa banida vê (o Roblox filtra esse texto sozinho).
	local banText = if seconds < 0
		then "Você foi banido deste jogo para sempre por um administrador."
		else ("Você foi banido deste jogo por %s por um administrador."):format(formatDuration(seconds))
	local displayReason = truncateUtf8(banText .. (if reason then " Motivo: " .. reason else ""), BAN_DISPLAY_MAX)
	-- PrivateReason: anotação só para os donos (aparece no histórico de banimentos).
	local privateReason = truncateUtf8(
		("Banido por %s (UserId %d) com o comando %sban. Motivo: %s"):format(
			ctx.Player.Name,
			ctx.Player.UserId,
			PREFIX,
			reason or "(sem motivo)"
		),
		BAN_PRIVATE_MAX
	)

	local okBan, err = pcall(function()
		Players:BanAsync({
			UserIds = { userId },
			ApplyToUniverse = true, -- vale no lobby e na partida (a experiência inteira)
			Duration = seconds, -- em segundos; -1 = para sempre
			DisplayReason = displayReason,
			PrivateReason = privateReason,
			ExcludeAltAccounts = false, -- também bane as contas alternativas suspeitas
			ApplyDeviceBlock = false,
		})
	end)

	-- Se a pessoa está neste servidor, sai na hora (mesmo se o banimento falhou).
	local online = Players:GetPlayerByUserId(userId)
	if online then
		online:Kick(banText)
	end

	local label = if victim then victim.Name else ("UserId " .. tostring(userId))
	if not okBan then
		warn("[AdminService] BanAsync falhou: " .. tostring(err))
		return false,
			("Não foi possível banir %s (%s). Confira se Players > BanningEnabled está ligado no Studio e publique de novo.%s"):format(
				label,
				shortError(err),
				if online then " A pessoa foi expulsa deste servidor." else ""
			)
	end
	return true, ("%s foi banido %s."):format(label, if seconds < 0 then "para sempre" else "por " .. formatDuration(seconds))
end

Handlers.unban = function(ctx)
	local userId = ctx.Args[1]
	local ok, err = pcall(function()
		Players:UnbanAsync({
			UserIds = { userId },
			ApplyToUniverse = true, -- precisa ser igual ao do ban (que é true)
		})
	end)
	if not ok then
		warn("[AdminService] UnbanAsync falhou: " .. tostring(err))
		return false, ("Não foi possível tirar o banimento (%s)."):format(shortError(err))
	end
	return true, ("O UserId %d pode entrar no jogo de novo."):format(userId)
end

-------------------------------------------------------------------------------
-- Comandos: ajuda
-------------------------------------------------------------------------------

Handlers.cmds = function()
	local inMatch = getPlaceRole() == "Match"
	local byCategory = {}
	local order = {}
	for _, def in ipairs(AdminsConfig.Commands) do
		if def.Scope ~= "Match" or inMatch then
			local category = tostring(def.Category or "Outros")
			if not byCategory[category] then
				byCategory[category] = {}
				table.insert(order, category)
			end
			table.insert(byCategory[category], usageOf(def))
		end
	end
	local lines = {
		if inMatch then "Comandos de admin:" else "Comandos de admin (no lobby; os da partida ficam de fora):",
	}
	for _, category in ipairs(order) do
		table.insert(lines, category .. ": " .. table.concat(byCategory[category], ", "))
	end
	table.insert(lines, "Jogador: nome, UserId, me, all ou others. Eventos: " .. eventList())
	return true, table.concat(lines, "\n")
end

-------------------------------------------------------------------------------
-- Execução
-------------------------------------------------------------------------------

-- Roda um comando de admin e devolve (ok, mensagem em português).
-- rawArgs = lista de textos; via = "chat" ou "painel" (só para o registro no Output).
local function runCommand(player, commandName, rawArgs, via)
	if not isPlayer(player) then
		return false, MSG_NO_PERMISSION
	end

	-- 1. É admin? (conferido de novo em cada pedido)
	local role = AdminService.GetRole(player)
	if not role then
		-- Avisa no Output só na 1ª vez por jogador (um exploiter mandando o pedido sem parar
		-- não lota o Output) e com o nome limpo (sem quebras de linha, tamanho limitado).
		if not deniedWarned[player] then
			deniedWarned[player] = true
			warn(
				("[Admin] %s (%d) tentou usar um comando de admin sem permissão: %s (as próximas tentativas não aparecem)"):format(
					player.Name,
					player.UserId,
					logSafe(string.sub(tostring(commandName), 1, MAX_COMMAND_NAME_LENGTH))
				)
			)
		end
		return false, MSG_NO_PERMISSION
	end

	-- 2. O comando existe? (aceita "fly" ou ":fly", em qualquer caixa)
	if type(commandName) ~= "string" or commandName == "" or #commandName > MAX_COMMAND_NAME_LENGTH then
		return false, MSG_UNKNOWN:format(PREFIX)
	end
	local name = string.lower(commandName)
	if string.sub(name, 1, #PREFIX) == PREFIX then
		name = string.sub(name, #PREFIX + 1)
	end
	local def = AdminsConfig.CommandsByName[name]
	local handler = Handlers[name]
	if type(def) ~= "table" or not handler then
		return false, MSG_UNKNOWN:format(PREFIX)
	end

	-- 3. Limite de frequência.
	if not consumeToken(player) then
		return false, MSG_RATE_LIMIT
	end

	-- 4. Lugar certo? (comandos da partida não rodam no lobby)
	if def.Scope == "Match" and getPlaceRole() ~= "Match" then
		return false, MSG_MATCH_ONLY:format(PREFIX, name)
	end

	-- 5. Argumentos e 6. execução, tudo protegido (um erro vira aviso no Output).
	local ok, message
	local success, result, text = pcall(function()
		local parsed, parseError = parseArgs(def, rawArgs, player)
		if not parsed then
			return false, parseError
		end
		return handler({
			Player = player,
			Role = role,
			Args = parsed,
			Def = def,
			Name = name,
		})
	end)
	if not success then
		warn(("[Admin] Erro no comando %s%s: %s"):format(PREFIX, name, tostring(result)))
		ok, message = false, "Erro ao rodar o comando (veja o Output)."
	else
		ok, message = result == true, tostring(text or "")
	end

	-- 7. Registro no Output (quem, onde, o quê e o resultado).
	print(
		("[Admin] %s (%d, %s) via %s: %s%s %s -> %s: %s"):format(
			player.Name,
			player.UserId,
			role,
			via,
			PREFIX,
			name,
			logSafe(table.concat(rawArgs, " ")),
			if ok then "ok" else "falhou",
			logSafe(message)
		)
	)
	return ok, message
end

-- Confere a lista de argumentos que veio do painel do cliente: só textos (ou números),
-- em sequência 1..n, no máximo MAX_ARGS, cada um até MAX_ARG_LENGTH. Devolve a lista ou nil.
local function sanitizeRawArgs(args)
	if args == nil then
		return {}
	end
	if type(args) ~= "table" then
		return nil
	end
	local list = {}
	local count = 0
	for key, value in pairs(args) do
		count += 1
		if count > MAX_ARGS or type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > MAX_ARGS then
			return nil
		end
		if type(value) == "number" then
			if value ~= value or value == math.huge or value == -math.huge then
				return nil
			end
			value = tostring(value)
		elseif type(value) ~= "string" then
			return nil
		end
		if #value > MAX_ARG_LENGTH then
			return nil
		end
		list[key] = value
	end
	-- Sem buracos: precisa ser 1, 2, 3... até "count".
	for index = 1, count do
		if list[index] == nil then
			return nil
		end
	end
	return list
end

-------------------------------------------------------------------------------
-- Chat (":comando argumentos")
-------------------------------------------------------------------------------

-- Padrão que reconhece ":comando resto" (o prefixo vira texto literal no padrão).
-- (string.gsub devolve 2 valores; os parênteses pegam só o texto)
local CHAT_PATTERN = "^%s*" .. (string.gsub(PREFIX, "%W", "%%%0")) .. "(%S+)%s*(.-)%s*$"

-- Trata uma mensagem de chat. Mensagens que não são comandos de admin são ignoradas,
-- e quem não é admin também é ignorado em silêncio (não mostra que os comandos existem).
local function handleChat(player, message)
	if not isPlayer(player) or type(message) ~= "string" or #message > MAX_CHAT_LENGTH then
		return
	end
	local commandName, rest = string.match(message, CHAT_PATTERN)
	if not commandName then
		return
	end
	commandName = string.lower(commandName)
	if not AdminsConfig.CommandsByName[commandName] then
		return
	end
	if not AdminService.IsAdmin(player) then
		return
	end

	-- A mesma mensagem pode chegar duas vezes (TextChatCommand + Player.Chatted).
	local nowClock = os.clock()
	local last = lastChat[player]
	if last and last.Text == message and nowClock - last.Time < CHAT_DEDUPE_WINDOW then
		return
	end
	lastChat[player] = { Text = message, Time = nowClock }

	local words = {}
	for word in string.gmatch(rest, "%S+") do
		table.insert(words, word)
		if #words >= MAX_CHAT_WORDS then
			break
		end
	end

	local ok, result = runCommand(player, commandName, words, "chat")
	local duration = if commandName == "cmds" and ok
		then CMDS_NOTIFY_DURATION
		elseif ok then nil
		else ERROR_NOTIFY_DURATION
	StateService.Notify(player, result, if ok then "success" else "error", duration)
end

-- Versão protegida (um erro vira aviso no Output em vez de sumir).
local function handleChatSafe(player, message)
	local ok, err = pcall(handleChat, player, message)
	if not ok then
		warn("[AdminService] Erro no comando de chat: " .. tostring(err))
	end
end

-- Cria um TextChatCommand para cada comando (chat novo, TextChatService). Não aparecem
-- na lista de sugestões do chat, para quem não é admin nem saber que existem.
-- Os TextChatCommand do DebugService ("/coins"...) ficam numa pasta separada e continuam iguais.
local function ensureChatCommands()
	if chatCommandsCreated then
		return
	end
	chatCommandsCreated = true
	local ok, err = pcall(function()
		local folder = Instance.new("Folder")
		folder.Name = "AdminCommands"
		for _, def in ipairs(AdminsConfig.Commands) do
			local command = Instance.new("TextChatCommand")
			command.Name = "Admin_" .. def.Name
			command.PrimaryAlias = PREFIX .. def.Name
			command.AutocompleteVisible = false
			command.Triggered:Connect(function(textSource, unfilteredText)
				local player = textSource and Players:GetPlayerByUserId(textSource.UserId)
				if player then
					task.spawn(handleChatSafe, player, unfilteredText)
				end
			end)
			command.Parent = folder
		end
		folder.Parent = TextChatService
	end)
	if not ok then
		warn("[AdminService] Não foi possível criar os comandos de chat: " .. tostring(err))
	end
end

-------------------------------------------------------------------------------
-- Jogadores
-------------------------------------------------------------------------------

local function onPlayerAdded(player)
	-- Chat antigo (e plano B do novo): Player.Chatted.
	player.Chatted:Connect(function(message)
		task.spawn(handleChatSafe, player, message)
	end)
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)

	-- Descobre o cargo (pode esperar a web, no caso de grupo) e grava os atributos.
	task.spawn(function()
		local ok, role = pcall(AdminService.GetRole, player)
		if not ok then
			warn("[AdminService] Erro ao conferir o cargo de " .. player.Name .. ": " .. tostring(role))
			return
		end
		if player.Parent == Players then
			setRoleAttributes(player, role or false)
			if role then
				print(("[Admin] %s (%d) entrou como %s."):format(player.Name, player.UserId, role))
			end
		end
	end)
end

local function onPlayerRemoving(player)
	buckets[player] = nil
	lastAnnounce[player] = nil
	lastChat[player] = nil
	deniedWarned[player] = nil
	walkOverrides[player] = nil
	jumpOverrides[player] = nil
	if characterConnections[player] then
		characterConnections[player]:Disconnect()
		characterConnections[player] = nil
	end
	-- Se a pessoa voltar, o cargo é conferido de novo.
	roleCache[player.UserId] = nil
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function AdminService.Init()
	-- Request "AdminCommand"(nome, {argumentos}) -> ok, mensagem
	Net.Handle("AdminCommand", function(player, commandName, args)
		if type(commandName) ~= "string" then
			return false, "Comando inválido."
		end
		local rawArgs = sanitizeRawArgs(args)
		if not rawArgs then
			return false, "Argumentos inválidos."
		end
		return runCommand(player, commandName, rawArgs, "painel")
	end, { Rate = 2, Burst = 6 })

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	ensureChatCommands()
end

function AdminService.Start()
	if started then
		return
	end
	started = true

	-- Ouve os outros servidores (avisos e eventos). SubscribeAsync espera: outra thread.
	task.spawn(subscribe)

	-- Lê o evento que já estava ligado antes de este servidor abrir, depois confere
	-- a cada 1 s se ele acabou e a cada EVENT_POLL_INTERVAL s relê o MemoryStore.
	task.spawn(function()
		local okSync, syncErr = pcall(syncFromStore, false)
		if not okSync then
			warn("[AdminService] Erro ao ler o evento atual: " .. tostring(syncErr))
		end
		local sincePoll = 0
		while true do
			task.wait(EVENT_TICK_INTERVAL)
			sincePoll += EVENT_TICK_INTERVAL
			local ok, err = pcall(function()
				if currentEvent and os.time() >= currentEvent.EndsAt then
					clearEvent(true)
				end
				if sincePoll >= EVENT_POLL_INTERVAL then
					sincePoll = 0
					syncFromStore(true)
				end
			end)
			if not ok then
				warn("[AdminService] Erro no laço do evento: " .. tostring(err))
			end
		end
	end)
end

return AdminService
