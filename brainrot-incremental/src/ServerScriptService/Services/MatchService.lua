--!nonstrict
-- MatchService: o "coração" do servidor da partida.
--
-- O que ele faz:
--   * Init: descobre qual partida é esta (handoff do lobby no MemoryStore, TeleportData ou Studio),
--     monta o mapa, cria as pastas do workspace e, se for "continuar partida", carrega o save do time.
--   * Start: aceita (ou recusa) jogadores, cria/restaura o "run" (progresso individual) de cada um,
--     posiciona o personagem no spawn, salva tudo de tempos em tempos e mantém a lista do time.
--   * Carteira: AddCoins / SpendCoins / GetCoins (individual ou cofre do time, se SharedWallet).
--   * CompleteAct: dá as recompensas do ato e leva o grupo para o próximo mapa (ou para o lobby).
--
-- Estado público (seção 8.2 da especificação):
--   MatchService.MapId, .MapDef, .Act, .Context (ctx do mapa), .Handoff
--   MatchService.Team  = progresso do time
--   MatchService.Runs[userId] = progresso de cada jogador (fica na memória mesmo se ele sair)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local MemoryStoreService = game:GetService("MemoryStoreService")

-- Módulos compartilhados (Config e Util).
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local GameConfig = require(ConfigFolder:WaitForChild("Game"))
local LobbyConfig = require(ConfigFolder:WaitForChild("Lobby"))
local Maps = require(ConfigFolder:WaitForChild("Maps"))
local Upgrades = require(ConfigFolder:WaitForChild("Upgrades"))
local Recipes = require(ConfigFolder:WaitForChild("Recipes"))

local Signal = require(UtilFolder:WaitForChild("Signal"))
local Trove = require(UtilFolder:WaitForChild("Trove"))
local Net = require(UtilFolder:WaitForChild("Net"))
local Tables = require(UtilFolder:WaitForChild("Tables"))
local PlaceRole = require(UtilFolder:WaitForChild("PlaceRole"))

-- Módulo de mundo (pode ser usado no topo: World não depende de serviços).
local MapBuilder = require(ServerScriptService:WaitForChild("World"):WaitForChild("MapBuilder"))

-- Serviços-folha (podem ser usados no topo, regra 1.2).
local Services = script.Parent
local DataService = require(Services:WaitForChild("DataService"))
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções (evita require circular).
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-------------------------------------------------------------------------------
-- Constantes técnicas (não são balanceamento)
-------------------------------------------------------------------------------
local HANDOFF_READ_ATTEMPTS = 10 -- tentativas de ler o handoff no MemoryStore
local HANDOFF_RETRY_DELAY = 1 -- segundos entre as tentativas
local FIRST_PLAYER_TIMEOUT = 60 -- quanto esperar o 1º jogador quando não há handoff
local INCOME_WINDOW = 10 -- janela (s) da média móvel da renda por segundo
local TEAM_LIST_INTERVAL = 1 -- TeamList a 1 Hz
local BOUNCE_KICK_DELAY = 25 -- se o teleporte de volta não acontecer, expulsa depois disso
local MAX_SAVED_TURRETS = 64 -- trava de segurança ao carregar torretas salvas
local PLAYERS_GROUP = "Players" -- grupo de colisão dos personagens
local SAVE_VERSION = 1 -- versão do formato do save do time

-- Fontes de moedas que NÃO ganham bônus (gamepass) nem contam como "TotalCoins".
local NO_BONUS_SOURCES = { Refund = true, Debug = true }
-- Fontes de moedas que entram no cálculo da renda por segundo.
-- (Missões ficam de fora: a recompensa depende da renda, e contar ela inflaria a renda.)
local INCOME_SOURCES = { Pickup = true, Turret = true }

-------------------------------------------------------------------------------
-- Estado do módulo
-------------------------------------------------------------------------------
local MatchService = {}

-- Tabela do time "vazia" (formato da seção 8.2).
local function newTeam()
	return {
		Upgrades = {},
		ShelfLevel = 1,
		Recipes = {},
		Buffs = { TimedEnchantUntil = 0, NextWaveGiant = false },
		SupremeProgress = 0,
		Turrets = {},
		SharedCoins = 0,
	}
end

MatchService.MapId = nil
MatchService.MapDef = nil
MatchService.Act = nil
MatchService.Context = nil
MatchService.Handoff = nil
MatchService.Team = newTeam()
MatchService.Runs = {}

-- Sinais públicos.
MatchService.CoinsAdded = Signal.new() -- (player, amount, source)
MatchService.RunReady = Signal.new() -- (player, run)

-- Estado privado.
local bounceEveryone = false -- true num servidor público do place de partida (todo mundo volta ao lobby)
local accepted = {} -- [player] = true  (jogadores aceitos e presentes)
local joinOrder = {} -- {userId} na ordem em que entraram (sem repetir)
local playerTroves = {} -- [player] = Trove (conexões do jogador)
local characterTroves = {} -- [player] = Trove (conexões do personagem atual)
local incomeAccum = {} -- [userId] = moedas ganhas desde o último tick de 1 Hz
local friendCache = {} -- ["menorId:maiorId"] = boolean
local rewardedUserIds = {} -- [userId] = true (já recebeu a recompensa do ato)
local savedPlayersSnapshot = {} -- ["userId"] = parte de cada jogador guardada no save do time
local actCompleting = false -- CompleteAct em andamento (evita chamar duas vezes)
local actCompleted = false -- ato concluído: para de salvar o run (ele foi apagado)
-- true = este servidor reservado foi aberto DE NOVO (ele fechou quando todos saíram e alguém
-- voltou pelo "Reconectar") e achamos o save gravado por esta mesma partida: os runs são
-- restaurados como no "continuar partida", em vez de começar do zero.
local resumingSameMatch = false
-- true = deu erro ao LER o save do time no Init. Enquanto for true, não gravamos o save do
-- time (senão um time vazio apagaria um save que só não conseguimos ler).
local teamSaveBlocked = false
local runReadyPlayers = {} -- [player] = true (o run dele já foi criado e enviado nesta entrada)
local startedAt = 0
local lastTeamListKey = nil
local rng = Random.new()

-------------------------------------------------------------------------------
-- Pequenos ajudantes
-------------------------------------------------------------------------------

-- Número "de verdade": nem NaN, nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Confere se é um Player que ainda está no jogo.
local function isPlayerInGame(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Mapa válido = existe em Config.Maps e tem Act (Maps.Order não conta).
local function isValidMapId(mapId)
	return type(mapId) == "string" and type(Maps[mapId]) == "table" and Maps[mapId].Act ~= nil
end

-- Inteiro dentro de uma faixa (com valor padrão se vier lixo).
local function sanitizeInteger(value, minValue, maxValue, default)
	if not isFiniteNumber(value) then
		return default
	end
	return math.clamp(math.floor(value), minValue, maxValue)
end

-- Moedas: número finito e não negativo.
local function sanitizeCoins(value)
	if not isFiniteNumber(value) or value < 0 then
		return 0
	end
	return value
end

-- Chama uma função de outro serviço protegida por pcall.
-- Devolve (true, ...resultados) ou (false) se deu erro (o erro aparece no Output).
local function callService(serviceName, fnName, ...)
	local results = table.pack(pcall(function(...)
		local service = Svc(serviceName)
		local fn = service[fnName]
		if type(fn) ~= "function" then
			error(serviceName .. "." .. fnName .. " não existe")
		end
		return fn(...)
	end, ...))
	if not results[1] then
		warn(("[MatchService] Erro ao chamar %s.%s: %s"):format(serviceName, fnName, tostring(results[2])))
		return false
	end
	return true, table.unpack(results, 2, results.n)
end

-- Lista de upgrades de um escopo ("Player"/"Team") vinda de um save: só ids deste mapa,
-- do escopo certo, com nível inteiro entre 1 e MaxLevel.
local function sanitizeLevels(levels, scope)
	local result = {}
	if type(levels) ~= "table" then
		return result
	end
	for upgradeId, level in pairs(levels) do
		local def = type(upgradeId) == "string" and Upgrades.ById[upgradeId] or nil
		if def and def.Map == MatchService.MapId and def.Scope == scope and isFiniteNumber(level) then
			local clean = math.clamp(math.floor(level), 0, def.MaxLevel or math.huge)
			if clean > 0 then
				result[upgradeId] = clean
			end
		end
	end
	return result
end

-- Ingredientes vindos de um save: só ids conhecidos, contagem inteira > 0.
local function sanitizeIngredients(ingredients)
	local result = {}
	if type(ingredients) ~= "table" then
		return result
	end
	for ingredientId, count in pairs(ingredients) do
		if type(ingredientId) == "string" and Recipes.IngredientsById[ingredientId] and isFiniteNumber(count) then
			local clean = math.max(0, math.floor(count))
			if clean > 0 then
				result[ingredientId] = clean
			end
		end
	end
	return result
end

-- Receitas permanentes já aplicadas (vindas de um save).
local function sanitizeRecipes(recipes)
	local result = {}
	if type(recipes) ~= "table" then
		return result
	end
	for recipeId, applied in pairs(recipes) do
		local def = type(recipeId) == "string" and Recipes.ById[recipeId] or nil
		if def and def.Kind == "Permanent" and applied == true then
			result[recipeId] = true
		end
	end
	return result
end

-- Torretas salvas: {OwnerUserId, Position = {x, y, z}, RotY, Mode?}.
local function sanitizeTurrets(turrets)
	local result = {}
	if type(turrets) ~= "table" then
		return result
	end
	for _, turret in ipairs(turrets) do
		if #result >= MAX_SAVED_TURRETS then
			break
		end
		local position = type(turret) == "table" and turret.Position or nil
		if
			type(position) == "table"
			and isFiniteNumber(turret.OwnerUserId)
			and isFiniteNumber(position[1])
			and isFiniteNumber(position[2])
			and isFiniteNumber(position[3])
		then
			local mode = turret.Mode
			table.insert(result, {
				OwnerUserId = turret.OwnerUserId,
				Position = { position[1], position[2], position[3] },
				RotY = isFiniteNumber(turret.RotY) and turret.RotY or 0,
				Mode = (mode == "Valuable" or mode == "Nearest") and mode or nil,
			})
		end
	end
	return result
end

-- Cria (ou reaproveita) uma pasta direto no workspace.
local function ensureWorkspaceFolder(name)
	local existing = workspace:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = workspace
	return folder
end

-- Quantos jogadores aceitos estão no servidor agora.
local function countAccepted()
	local count = 0
	for player in pairs(accepted) do
		if player.Parent == Players then
			count += 1
		end
	end
	return count
end

-- Chave do save do time: "Run_<host>_<mapa>" (nil se ainda não sabemos quem é o host).
local function getRunKey()
	local hostUserId = MatchService.GetHostUserId()
	if hostUserId == nil or MatchService.MapId == nil then
		return nil
	end
	return "Run_" .. tostring(hostUserId) .. "_" .. MatchService.MapId
end

-- O retrato (save do time ou profile.RunData) foi gravado DEPOIS que esta partida foi criada?
-- Um servidor reservado que fechou pode ser aberto de novo com o mesmo código de acesso
-- (botão "Reconectar"): o Roblox cria uma instância nova, com o mesmo PrivateServerId, que
-- lê o MESMO handoff do MemoryStore (com o Resume original). O handoff.CreatedAt é a hora
-- em que o lobby criou esta partida, e todo save guarda SavedAt: se SavedAt >= CreatedAt,
-- o save é o progresso desta partida (ou um mais novo do mesmo dono e mapa) e não um antigo.
local function isSavedByThisMatch(snapshot)
	local handoff = MatchService.Handoff
	local createdAt = handoff and handoff.CreatedAt
	return type(snapshot) == "table"
		and isFiniteNumber(createdAt)
		and isFiniteNumber(snapshot.SavedAt)
		and snapshot.SavedAt >= createdAt
end

-------------------------------------------------------------------------------
-- Handoff: quem montou esta partida e com quais regras
-------------------------------------------------------------------------------

-- Limpa e valida o handoff lido do MemoryStore (formato gravado pelo TravelService).
local function sanitizeHandoff(raw)
	if type(raw) ~= "table" or not isValidMapId(raw.MapId) then
		return nil
	end

	local handoff = {
		MapId = raw.MapId,
		HostUserId = isFiniteNumber(raw.HostUserId) and math.floor(raw.HostUserId) or nil,
		MaxPlayers = sanitizeInteger(
			raw.MaxPlayers,
			LobbyConfig.MinMaxPlayers,
			LobbyConfig.MaxPlayersLimit,
			LobbyConfig.MaxPlayersLimit
		),
		Privacy = (type(raw.Privacy) == "string" and LobbyConfig.Privacy[raw.Privacy]) and raw.Privacy or "Invite",
		Resume = raw.Resume == true,
		AccessCode = type(raw.AccessCode) == "string" and raw.AccessCode or nil,
		PrivateServerId = type(raw.PrivateServerId) == "string" and raw.PrivateServerId or game.PrivateServerId,
		CreatedAt = isFiniteNumber(raw.CreatedAt) and raw.CreatedAt or nil,
		Members = nil,
	}

	-- Lista de membros (userIds). Sem lista = todos podem entrar.
	if type(raw.Members) == "table" then
		local members = {}
		for _, userId in ipairs(raw.Members) do
			if isFiniteNumber(userId) then
				local clean = math.floor(userId)
				if not table.find(members, clean) then
					table.insert(members, clean)
				end
			end
		end
		if #members > 0 then
			-- O dono sempre faz parte da partida.
			if handoff.HostUserId and not table.find(members, handoff.HostUserId) then
				table.insert(members, handoff.HostUserId)
			end
			handoff.Members = members
		end
	end

	return handoff
end

-- Lê o handoff do MemoryStore (até 10 tentativas, 1 s entre elas).
local function readHandoffFromMemoryStore(privateServerId)
	local okMap, hashMap = pcall(function()
		return MemoryStoreService:GetHashMap(LobbyConfig.HandoffMapName)
	end)
	if not okMap then
		warn("[MatchService] Não foi possível abrir o MemoryStore do handoff: " .. tostring(hashMap))
		return nil
	end

	for attempt = 1, HANDOFF_READ_ATTEMPTS do
		local ok, value = pcall(function()
			return hashMap:GetAsync(privateServerId)
		end)
		if ok and value ~= nil then
			local handoff = sanitizeHandoff(value)
			if not handoff then
				warn("[MatchService] Handoff inválido no MemoryStore; ignorando.")
			end
			return handoff
		elseif not ok then
			warn(("[MatchService] Falha ao ler o handoff (tentativa %d): %s"):format(attempt, tostring(value)))
		end
		if attempt < HANDOFF_READ_ATTEMPTS then
			task.wait(HANDOFF_RETRY_DELAY)
		end
	end
	return nil
end

-- Espera o primeiro jogador chegar (ou desiste depois de "timeout" segundos).
local function waitForFirstPlayer(timeout)
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		local first = Players:GetPlayers()[1]
		if first then
			return first
		end
		task.wait(0.25)
	end
	return nil
end

-- Lê TeleportData.MapId de um jogador (dado vindo do cliente: só usamos se for um mapa válido).
local function readTeleportMapId(player)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or type(joinData) ~= "table" then
		return nil
	end
	local teleportData = joinData.TeleportData
	if type(teleportData) == "table" and isValidMapId(teleportData.MapId) then
		return teleportData.MapId
	end
	return nil
end

-- Monta um handoff "padrão" (Studio ou servidor sem handoff): todos entram.
local function defaultHandoff(mapId, hostUserId)
	return {
		MapId = mapId,
		HostUserId = hostUserId,
		MaxPlayers = LobbyConfig.MaxPlayersLimit,
		Privacy = "Invite",
		Resume = false,
		AccessCode = nil,
		PrivateServerId = game.PrivateServerId ~= "" and game.PrivateServerId or nil,
		Members = nil,
	}
end

-- Decide qual partida é esta. Devolve (handoff, mandarTodosParaOLobby).
local function resolveHandoff()
	-- 1. Studio: mapa do Config, todos entram, host = primeiro jogador.
	if PlaceRole.IsStudio() then
		local mapId = isValidMapId(GameConfig.StudioMapId) and GameConfig.StudioMapId or Maps.Order[1]
		if mapId ~= GameConfig.StudioMapId then
			warn("[MatchService] Config.Game.StudioMapId inválido; usando " .. mapId)
		end
		return defaultHandoff(mapId, nil), false
	end

	-- 2. Servidor reservado (criado pelo lobby): lê o handoff do MemoryStore.
	local isReserved = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
	if isReserved then
		local handoff = readHandoffFromMemoryStore(game.PrivateServerId)
		if handoff then
			return handoff, false
		end

		-- Sem handoff: usa o TeleportData do primeiro jogador e aceita todos.
		warn("[MatchService] Handoff não encontrado; usando o TeleportData do primeiro jogador.")
		local first = waitForFirstPlayer(FIRST_PLAYER_TIMEOUT)
		local mapId = first and readTeleportMapId(first) or nil
		if not mapId then
			warn("[MatchService] TeleportData sem mapa válido; usando " .. tostring(Maps.Order[1]))
			mapId = Maps.Order[1]
		end
		return defaultHandoff(mapId, first and first.UserId or nil), false
	end

	-- 3. Servidor público do place de partida: não é uma partida de verdade.
	--    Monta o primeiro mapa (para os outros serviços não quebrarem) e manda todos ao lobby.
	return defaultHandoff(Maps.Order[1], nil), true
end

-------------------------------------------------------------------------------
-- Save do time e dos jogadores
-------------------------------------------------------------------------------

-- Retrato do run de um jogador (formato de profile.RunData[mapId], seção 4.2).
local function runSnapshot(run)
	return {
		HostUserId = MatchService.GetHostUserId(),
		Coins = run.Coins,
		Upgrades = table.clone(run.Upgrades),
		Ingredients = table.clone(run.Ingredients),
		SavedAt = os.time(),
	}
end

-- Monta a tabela salva em DataService.SaveRun (time + cópia da parte de cada jogador).
local function buildTeamSave()
	local team = MatchService.Team

	-- Parte de cada jogador (inclusive de quem saiu). Chaves em texto: o DataStore
	-- guarda JSON, e tabelas com números "soltos" como chave dão problema.
	-- Começa com os jogadores do save antigo que ainda não voltaram...
	local playersData = table.clone(savedPlayersSnapshot)
	-- ...e escreve por cima os runs atuais.
	for userId, run in pairs(MatchService.Runs) do
		playersData[tostring(userId)] = runSnapshot(run)
	end

	return {
		Version = SAVE_VERSION,
		MapId = MatchService.MapId,
		HostUserId = MatchService.GetHostUserId(),
		SavedAt = os.time(),
		Team = {
			Upgrades = table.clone(team.Upgrades),
			ShelfLevel = team.ShelfLevel,
			Recipes = table.clone(team.Recipes),
			Buffs = {
				TimedEnchantUntil = team.Buffs.TimedEnchantUntil or 0,
				NextWaveGiant = team.Buffs.NextWaveGiant == true,
			},
			SupremeProgress = team.SupremeProgress,
			Turrets = Tables.DeepCopy(team.Turrets),
			SharedCoins = team.SharedCoins,
		},
		Players = playersData,
	}
end

-- Aplica um save do time (vindo de DataService.LoadRun) em MatchService.Team.
local function applyTeamSave(saved)
	if type(saved) ~= "table" or type(saved.Team) ~= "table" then
		warn("[MatchService] Save do time em formato desconhecido; começando do zero.")
		return
	end
	if saved.MapId ~= nil and saved.MapId ~= MatchService.MapId then
		warn("[MatchService] Save do time é de outro mapa; começando do zero.")
		return
	end

	local raw = saved.Team
	local team = MatchService.Team
	local maxShelf = MatchService.MapDef.MaxShelf or 1
	local rawBuffs = type(raw.Buffs) == "table" and raw.Buffs or {}

	team.Upgrades = sanitizeLevels(raw.Upgrades, "Team")
	team.ShelfLevel = sanitizeInteger(raw.ShelfLevel, 1, maxShelf, 1)
	team.Recipes = sanitizeRecipes(raw.Recipes)
	team.Buffs = {
		TimedEnchantUntil = isFiniteNumber(rawBuffs.TimedEnchantUntil) and rawBuffs.TimedEnchantUntil or 0,
		NextWaveGiant = rawBuffs.NextWaveGiant == true,
	}
	team.SupremeProgress = isFiniteNumber(raw.SupremeProgress) and math.clamp(raw.SupremeProgress, 0, 1) or 0
	team.Turrets = sanitizeTurrets(raw.Turrets)
	team.SharedCoins = sanitizeCoins(raw.SharedCoins)

	-- Guarda a parte de cada jogador (usada se o perfil dele não tiver o RunData).
	savedPlayersSnapshot = {}
	if type(saved.Players) == "table" then
		for key, snapshot in pairs(saved.Players) do
			if type(key) == "string" and type(snapshot) == "table" then
				savedPlayersSnapshot[key] = snapshot
			end
		end
	end
end

-- Copia o run do jogador para profile.RunData[mapId] (o DataService salva o perfil).
local function syncRunToProfile(player)
	if actCompleted or bounceEveryone then
		return
	end
	local run = MatchService.Runs[player.UserId]
	if not run then
		return
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return
	end
	if type(profile.RunData) ~= "table" then
		profile.RunData = {}
	end
	profile.RunData[MatchService.MapId] = runSnapshot(run)

	-- Renova a hora da "última partida" enquanto o jogador está aqui. Assim a janela do
	-- botão "Reconectar" (ReconnectWindowSeconds) conta a partir de quando ele SAIU, e não
	-- de quando entrou (quem joga mais de 2 horas e cai também pode voltar).
	local lastMatch = profile.LastMatch
	local privateServerId = MatchService.Handoff.PrivateServerId or game.PrivateServerId
	if type(lastMatch) == "table" and privateServerId ~= "" and lastMatch.PrivateServerId == privateServerId then
		lastMatch.Time = os.time()
	end
end

-------------------------------------------------------------------------------
-- Runs (progresso individual)
-------------------------------------------------------------------------------

-- Run novo, zerado (formato da seção 8.2).
local function newRun(player)
	return {
		UserId = player.UserId,
		Name = player.DisplayName,
		Coins = 0,
		Upgrades = {},
		Ingredients = {},
		Quest = nil,
		QuestCooldownEnd = 0,
		IncomeEMA = 0,
		Heat = 0,
		Overheated = false,
	}
end

-- Run restaurado de um retrato salvo (perfil ou save do time).
local function runFromSnapshot(player, snapshot)
	local run = newRun(player)
	run.Coins = sanitizeCoins(snapshot.Coins)
	run.Upgrades = sanitizeLevels(snapshot.Upgrades, "Player")
	run.Ingredients = sanitizeIngredients(snapshot.Ingredients)
	return run
end

-- Cria ou restaura o run do jogador:
--   1. voltou para este servidor -> usa o que ficou na memória;
--   2. "continuar partida" (ou este servidor reservado aberto de novo pelo "Reconectar")
--      -> o retrato mais novo entre profile.RunData (do mesmo host) e a cópia guardada
--      no save do time;
--   3. senão -> run novo e apaga o RunData antigo deste mapa.
local function createOrRestoreRun(player, profile)
	local userId = player.UserId
	local existing = MatchService.Runs[userId]
	if existing then
		existing.Name = player.DisplayName
		return existing
	end

	if type(profile.RunData) ~= "table" then
		profile.RunData = {}
	end

	local run = nil
	local resuming = MatchService.Handoff.Resume or resumingSameMatch
	local hostUserId = MatchService.GetHostUserId()
	local best = nil

	-- Retrato do perfil: vale no "continuar partida" e também quando foi gravado por esta
	-- mesma partida (servidor reservado que fechou e foi aberto de novo), mesmo que o save
	-- do time não tenha sido encontrado.
	local fromProfile = profile.RunData[MatchService.MapId]
	if
		type(fromProfile) == "table"
		and fromProfile.HostUserId == hostUserId
		and (resuming or isSavedByThisMatch(fromProfile))
	then
		best = fromProfile
	end

	-- Cópia guardada no save do time (só existe se o Init carregou esse save).
	local fromTeam = savedPlayersSnapshot[tostring(userId)]
	if resuming and type(fromTeam) == "table" then
		local teamTime = isFiniteNumber(fromTeam.SavedAt) and fromTeam.SavedAt or 0
		local bestTime = best and isFiniteNumber(best.SavedAt) and best.SavedAt or -1
		if teamTime > bestTime then
			best = fromTeam
		end
	end

	if best then
		run = runFromSnapshot(player, best)
	end

	if not run then
		run = newRun(player)
		profile.RunData[MatchService.MapId] = nil
	end

	MatchService.Runs[userId] = run
	return run
end

-- Envia ao jogador as chaves de estado que são dele.
local function sendPlayerState(player, run)
	if GameConfig.SharedWallet then
		StateService.SetAll("Coins", MatchService.Team.SharedCoins)
	else
		StateService.Set(player, "Coins", run.Coins)
	end
	StateService.Set(player, "Income", run.IncomeEMA)
	StateService.Set(player, "PlayerUpgrades", table.clone(run.Upgrades))
	StateService.Set(player, "Ingredients", table.clone(run.Ingredients))
	StateService.Set(player, "Quest", {
		Active = run.Quest and Tables.DeepCopy(run.Quest) or nil,
		CooldownEnd = run.QuestCooldownEnd or 0,
	})

	-- Calor da arma (a capacidade vem dos stats do jogador).
	local capacity = 0
	local okStats, stats = callService("StatService", "Get", player)
	if okStats and type(stats) == "table" and isFiniteNumber(stats.HeatCapacity) then
		capacity = stats.HeatCapacity
	end
	StateService.Set(player, "Heat", { Value = run.Heat or 0, Capacity = capacity, Overheated = run.Overheated == true })
end

-- Publica a chave global "Match".
local function publishMatch()
	local handoff = MatchService.Handoff
	local members = handoff.Members and table.clone(handoff.Members) or table.clone(joinOrder)
	StateService.SetAll("Match", {
		MapId = MatchService.MapId,
		Act = MatchService.Act,
		HostUserId = handoff.HostUserId,
		Members = members,
		StartedAt = startedAt,
	})
end

-------------------------------------------------------------------------------
-- Personagem
-------------------------------------------------------------------------------

-- Coloca uma parte do personagem no grupo de colisão "Players".
local function setPlayerCollisionGroup(instance)
	if instance:IsA("BasePart") then
		instance.CollisionGroup = PLAYERS_GROUP
	end
end

-- Leva o personagem até o SpawnLocation do mapa (com um pequeno desvio aleatório
-- para os jogadores não nascerem um em cima do outro).
local function placeAtSpawn(character)
	local ctx = MatchService.Context
	local spawnPart = ctx and ctx.SpawnLocation
	if not spawnPart or not spawnPart.Parent then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)
	if not root or not character:IsDescendantOf(workspace) then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local hipHeight = humanoid and humanoid.HipHeight or 2

	-- Ponto aleatório no topo do spawn (deixando 2 studs de margem na borda).
	local halfX = math.max(0, spawnPart.Size.X / 2 - 2)
	local halfZ = math.max(0, spawnPart.Size.Z / 2 - 2)
	local localTop = Vector3.new(rng:NextNumber(-halfX, halfX), spawnPart.Size.Y / 2, rng:NextNumber(-halfZ, halfZ))
	local worldTop = spawnPart.CFrame:PointToWorldSpace(localTop)

	-- Altura do centro do HumanoidRootPart acima do chão + folguinha.
	local height = hipHeight + root.Size.Y / 2 + 0.5
	local _, yaw = spawnPart.CFrame:ToOrientation()
	character:PivotTo(CFrame.new(worldTop + Vector3.new(0, height, 0)) * CFrame.Angles(0, yaw, 0))
end

-- Chamado a cada (re)nascimento do personagem.
local function onCharacterAdded(player, character)
	if characterTroves[player] then
		characterTroves[player]:Clean()
	end
	local trove = Trove.new()
	characterTroves[player] = trove

	-- Grupo de colisão em todas as partes (e nas que aparecerem depois, ex.: acessórios).
	for _, descendant in ipairs(character:GetDescendants()) do
		setPlayerCollisionGroup(descendant)
	end
	trove:Connect(character.DescendantAdded, setPlayerCollisionGroup)

	-- Posiciona e ajusta a velocidade numa thread separada (pode esperar partes carregarem).
	trove:Add(task.spawn(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.WalkSpeed = GameConfig.WalkSpeed
		end

		-- O personagem pode ainda não estar no workspace quando CharacterAdded dispara.
		local deadline = os.clock() + 10
		while character.Parent == nil and os.clock() < deadline do
			task.wait()
		end
		-- Espera um quadro para o Roblox terminar o posicionamento padrão dele.
		task.wait()
		if character.Parent and player.Character == character then
			placeAtSpawn(character)
		end
	end))
end

-------------------------------------------------------------------------------
-- Amigos (conquista "PlayWithFriends")
-------------------------------------------------------------------------------

-- true se os dois jogadores são amigos (com cache; IsFriendsWith é chamada web).
local function areFriends(a, b)
	local low = math.min(a.UserId, b.UserId)
	local high = math.max(a.UserId, b.UserId)
	local key = tostring(low) .. ":" .. tostring(high)
	local cached = friendCache[key]
	if cached ~= nil then
		return cached
	end
	local ok, result = pcall(function()
		return a:IsFriendsWith(b.UserId)
	end)
	if not ok then
		return false -- não guarda no cache: tenta de novo numa próxima vez
	end
	friendCache[key] = result == true
	return friendCache[key]
end

-- Lista (cópia) dos outros jogadores aceitos e presentes. Usamos uma cópia porque
-- IsFriendsWith espera a web, e a tabela "accepted" pode mudar enquanto isso.
local function otherAcceptedPlayers(player)
	local list = {}
	for other in pairs(accepted) do
		if other ~= player and other.Parent == Players then
			table.insert(list, other)
		end
	end
	return list
end

-- Quantos amigos de "player" estão na partida.
local function countFriendsInMatch(player)
	local count = 0
	for _, other in ipairs(otherAcceptedPlayers(player)) do
		if other.Parent == Players and areFriends(player, other) then
			count += 1
		end
	end
	return count
end

-- Avisa o AchievementService: o jogador que entrou e os amigos dele que já estavam aqui.
local function firePlayWithFriends(player)
	for _, other in ipairs(otherAcceptedPlayers(player)) do
		if other.Parent == Players and accepted[other] and areFriends(player, other) then
			callService("AchievementService", "FireEvent", other, "PlayWithFriends", { Count = countFriendsInMatch(other) })
		end
	end
	if player.Parent == Players then
		callService("AchievementService", "FireEvent", player, "PlayWithFriends", { Count = countFriendsInMatch(player) })
	end
end

-------------------------------------------------------------------------------
-- Entrada e saída de jogadores
-------------------------------------------------------------------------------

-- Manda um jogador de volta ao lobby (com aviso). Se o teleporte falhar, expulsa.
local function sendBackToLobby(player, message)
	StateService.Notify(player, message, "warning", 8)
	task.spawn(function()
		local ok, result = callService("TravelService", "SendToLobby", { player })
		if not ok or result == false then
			if player.Parent == Players then
				player:Kick(message)
			end
			return
		end
		-- Rede de segurança: se o teleporte não aconteceu depois de um tempo, expulsa.
		task.delay(BOUNCE_KICK_DELAY, function()
			if player.Parent == Players and not accepted[player] then
				player:Kick(message)
			end
		end)
	end)
end

-- Cria (ou restaura) o run do jogador e avisa os outros serviços. Roda só UMA vez por
-- entrada, mesmo que onPlayerAdded e ProfileLoaded cheguem aqui ao mesmo tempo.
local function setupPlayerRun(player, profile)
	if runReadyPlayers[player] or not profile or player.Parent ~= Players or not accepted[player] then
		return
	end
	runReadyPlayers[player] = true

	-- Run (memória, save ou novo).
	local run = createOrRestoreRun(player, profile)

	-- Guarda a partida no perfil para o botão "Reconectar" do lobby.
	local handoff = MatchService.Handoff
	if handoff.AccessCode then
		profile.LastMatch = {
			AccessCode = handoff.AccessCode,
			PrivateServerId = handoff.PrivateServerId or game.PrivateServerId,
			MapId = MatchService.MapId,
			Time = os.time(),
		}
	end
	syncRunToProfile(player)
	DataService.SyncProfile(player)

	-- Estado do jogador e aviso para os outros serviços.
	sendPlayerState(player, run)
	MatchService.RunReady:Fire(player, run)

	-- Conquista de jogar com amigos (IsFriendsWith espera a web: roda separado).
	task.spawn(firePlayWithFriends, player)
end

local function onPlayerAdded(player)
	if playerTroves[player] then
		return -- já tratado (PlayerAdded + lista inicial)
	end
	local trove = Trove.new()
	playerTroves[player] = trove

	-- Servidor público do place de partida: todo mundo volta ao lobby.
	if bounceEveryone then
		sendBackToLobby(player, "Este servidor não é uma partida. Voltando para o lobby...")
		return
	end

	-- Só membros do grupo podem entrar.
	if not MatchService.IsMember(player.UserId) then
		sendBackToLobby(player, "Você não faz parte desta partida. Voltando para o lobby...")
		return
	end

	-- Limite de jogadores escolhido no lobby.
	if countAccepted() >= (MatchService.Handoff.MaxPlayers or LobbyConfig.MaxPlayersLimit) then
		sendBackToLobby(player, "Esta partida está cheia. Voltando para o lobby...")
		return
	end

	-- Aceito!
	accepted[player] = true
	if not table.find(joinOrder, player.UserId) then
		table.insert(joinOrder, player.UserId)
	end
	if MatchService.Handoff.HostUserId == nil then
		-- Studio (ou servidor sem handoff): o primeiro jogador vira o dono.
		MatchService.Handoff.HostUserId = player.UserId
	end
	publishMatch()

	-- Personagem: grupo de colisão, velocidade e spawn.
	local ctx = MatchService.Context
	if ctx and ctx.SpawnLocation and ctx.SpawnLocation:IsA("SpawnLocation") then
		player.RespawnLocation = ctx.SpawnLocation
	end
	trove:Connect(player.CharacterAdded, function(character)
		onCharacterAdded(player, character)
	end)
	trove:Connect(player.CharacterRemoving, function()
		if characterTroves[player] then
			characterTroves[player]:Clean()
			characterTroves[player] = nil
		end
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end

	-- Espera o perfil (se não carregar, o DataService expulsa o jogador).
	-- Se outro servidor ainda segura a trava do perfil, o DataService espera ela vencer
	-- (6 x 5 s + as leituras), o que passa dos 30 s do WaitForProfile. Nesse caso quem
	-- termina o trabalho é o DataService.ProfileLoaded (ligado no Start), que chama
	-- setupPlayerRun quando o perfil finalmente chega.
	local profile = DataService.WaitForProfile(player)
	if profile then
		setupPlayerRun(player, profile)
	end
end

local function onPlayerRemoving(player)
	-- Guarda a parte dele no perfil (o run continua na memória se ele voltar).
	syncRunToProfile(player)

	accepted[player] = nil
	runReadyPlayers[player] = nil
	incomeAccum[player.UserId] = nil

	if characterTroves[player] then
		characterTroves[player]:Clean()
		characterTroves[player] = nil
	end
	if playerTroves[player] then
		playerTroves[player]:Clean()
		playerTroves[player] = nil
	end
end

-------------------------------------------------------------------------------
-- Loops
-------------------------------------------------------------------------------

-- 1 Hz: renda por segundo (média móvel), TeamList e cópia do run no perfil.
local function teamListTick(dt)
	-- Fator da média móvel exponencial para uma janela de ~10 s.
	local alpha = 1 - math.exp(-dt / INCOME_WINDOW)
	local list = {}
	local keyParts = {}

	for _, userId in ipairs(joinOrder) do
		local player = Players:GetPlayerByUserId(userId)
		local run = MatchService.Runs[userId]
		if player and accepted[player] and run then
			-- Renda: moedas ganhas neste segundo entram na média.
			local earned = incomeAccum[userId] or 0
			incomeAccum[userId] = 0
			local previous = run.IncomeEMA or 0
			local ema = previous + alpha * (earned / dt - previous)
			if ema < 0.01 then
				ema = 0
			end
			run.IncomeEMA = ema
			if math.abs(ema - previous) > math.max(0.01, previous * 0.001) or (ema == 0 and previous ~= 0) then
				StateService.Set(player, "Income", ema)
			end

			local coins = MatchService.GetCoins(player)
			table.insert(list, { UserId = userId, Name = run.Name, Coins = coins })
			table.insert(keyParts, tostring(userId) .. "=" .. tostring(coins))

			syncRunToProfile(player)
		end
	end

	-- Só manda a lista quando algo mudou.
	local key = table.concat(keyParts, "|")
	if key ~= lastTeamListKey then
		lastTeamListKey = key
		StateService.SetAll("TeamList", list)
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

function MatchService.GetRun(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end
	return MatchService.Runs[player.UserId]
end

function MatchService.GetRunByUserId(userId)
	if type(userId) ~= "number" then
		return nil
	end
	return MatchService.Runs[userId]
end

function MatchService.GetTeam()
	return MatchService.Team
end

function MatchService.GetMapId()
	return MatchService.MapId
end

function MatchService.GetMapDef()
	return MatchService.MapDef
end

function MatchService.GetContext()
	return MatchService.Context
end

function MatchService.GetHostUserId()
	return MatchService.Handoff and MatchService.Handoff.HostUserId or nil
end

-- true se o jogador pode estar nesta partida (sem lista de membros = todos podem).
function MatchService.IsMember(userId)
	local handoff = MatchService.Handoff
	if not handoff or not handoff.Members then
		return true
	end
	return table.find(handoff.Members, userId) ~= nil
end

-- Jogadores aceitos presentes agora (usado, por exemplo, na vida dos brainrots).
function MatchService.GetPlayerCount()
	return countAccepted()
end

-- Dá moedas ao jogador. source: "Pickup", "Quest", "Turret", "Debug" ou "Refund".
-- Devolve o valor realmente creditado (0 se não deu).
function MatchService.AddCoins(player, amount, source)
	if not isPlayerInGame(player) or not isFiniteNumber(amount) or amount <= 0 then
		return 0
	end
	local run = MatchService.Runs[player.UserId]
	if not run then
		return 0
	end
	if type(source) ~= "string" then
		source = "Pickup"
	end

	-- Gamepass de moedas em dobro (não vale para reembolso nem para o comando de teste).
	local noBonus = NO_BONUS_SOURCES[source] == true
	if not noBonus then
		local okPass, hasDouble = callService("MonetizationService", "HasPass", player, "DoubleCoins")
		if okPass and hasDouble == true then
			amount *= 2
		end
	end

	-- Soma na carteira (individual ou cofre do time).
	if GameConfig.SharedWallet then
		local team = MatchService.Team
		team.SharedCoins += amount
		StateService.SetAll("Coins", team.SharedCoins)
	else
		run.Coins += amount
		StateService.Set(player, "Coins", run.Coins)
	end

	-- Estatística permanente de moedas totais.
	if not noBonus then
		DataService.IncrementStat(player, "TotalCoins", amount)
	end

	-- Renda por segundo (a média é atualizada no loop de 1 Hz).
	if INCOME_SOURCES[source] then
		incomeAccum[player.UserId] = (incomeAccum[player.UserId] or 0) + amount
	end

	MatchService.CoinsAdded:Fire(player, amount, source)
	return amount
end

-- Tenta gastar moedas. Devolve true se deu (e já desconta), false se não tinha o suficiente.
function MatchService.SpendCoins(player, amount)
	if not isPlayerInGame(player) or not isFiniteNumber(amount) or amount < 0 then
		return false
	end
	local run = MatchService.Runs[player.UserId]
	if not run then
		return false
	end
	if amount == 0 then
		return true
	end

	if GameConfig.SharedWallet then
		local team = MatchService.Team
		if team.SharedCoins < amount then
			return false
		end
		team.SharedCoins = math.max(0, team.SharedCoins - amount)
		StateService.SetAll("Coins", team.SharedCoins)
	else
		if run.Coins < amount then
			return false
		end
		run.Coins = math.max(0, run.Coins - amount)
		StateService.Set(player, "Coins", run.Coins)
	end
	return true
end

-- Moedas que o jogador pode gastar agora.
function MatchService.GetCoins(player)
	if GameConfig.SharedWallet then
		return MatchService.Team.SharedCoins
	end
	local run = MatchService.GetRun(player)
	return run and run.Coins or 0
end

-- Chamado pelo SaveAll quando o Init não conseguiu ler o save do time (teamSaveBlocked).
-- Lê de novo e só libera a gravação quando é seguro: não existe save, ou ele é de outra
-- partida e esta começou do zero de propósito. Se existe um save que esta partida deveria
-- ter carregado ("continuar" ou "Reconectar"), nunca gravamos por cima dele.
local function retryBlockedTeamSave(key)
	local okLoad, saved, loadError = pcall(DataService.LoadRun, key)
	if not okLoad or loadError ~= nil then
		return false -- o DataStore ainda está falhando: continua sem gravar
	end
	if saved ~= nil and (MatchService.Handoff.Resume or isSavedByThisMatch(saved)) then
		return false
	end
	teamSaveBlocked = false
	return true
end

-- Salva o time (DataService.SaveRun), copia os runs para os perfis e marca
-- RunSaves[mapa] no perfil do dono (para o lobby oferecer "Continuar").
function MatchService.SaveAll()
	if actCompleted or bounceEveryone then
		return false
	end
	local key = getRunKey()
	if not key or next(MatchService.Runs) == nil then
		return false -- ninguém jogou ainda: nada para salvar
	end

	for player in pairs(accepted) do
		if player.Parent == Players then
			syncRunToProfile(player)
		end
	end

	-- O Init não conseguiu ler o save do time: tenta ler de novo antes de gravar por cima.
	if teamSaveBlocked and not retryBlockedTeamSave(key) then
		return false
	end

	local hostPlayer = Players:GetPlayerByUserId(MatchService.GetHostUserId())
	if hostPlayer then
		local profile = DataService.GetProfile(hostPlayer)
		if profile then
			if type(profile.RunSaves) ~= "table" then
				profile.RunSaves = {}
			end
			profile.RunSaves[MatchService.MapId] = os.time()
			DataService.SyncProfile(hostPlayer)
		end
	end

	local ok, err = pcall(DataService.SaveRun, key, buildTeamSave())
	if not ok then
		warn("[MatchService] Falha ao salvar a partida do time: " .. tostring(err))
	end
	return ok
end

-- Conclui o ato: recompensas no perfil de cada jogador presente e viagem para o
-- próximo mapa (ou para o lobby, no último ato). Devolve ok, mensagemDeErro.
function MatchService.CompleteAct()
	if actCompleting then
		return false, "A viagem já está em andamento."
	end
	actCompleting = true

	local mapId = MatchService.MapId
	local mapDef = MatchService.MapDef
	local nextMapId = mapDef.Next
	local runKey = getRunKey()

	-- A partir daqui o run deste mapa não é mais salvo (ele foi concluído).
	actCompleted = true

	local travelers = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = accepted[player] and MatchService.Runs[player.UserId] and DataService.GetProfile(player)
		if profile then
			table.insert(travelers, player)

			-- Recompensas (só uma vez por jogador, mesmo se a viagem falhar e for repetida).
			if not rewardedUserIds[player.UserId] then
				rewardedUserIds[player.UserId] = true

				if type(profile.CompletedMaps) ~= "table" then
					profile.CompletedMaps = {}
				end
				profile.CompletedMaps[mapId] = true
				if nextMapId then
					if type(profile.UnlockedMaps) ~= "table" then
						profile.UnlockedMaps = {}
					end
					profile.UnlockedMaps[nextMapId] = true
				else
					profile.GameCompleted = true
				end
				profile.Tokens = (tonumber(profile.Tokens) or 0) + (mapDef.TokensReward or 0)

				-- O save deste mapa acabou.
				if type(profile.RunData) == "table" then
					profile.RunData[mapId] = nil
				end
				if type(profile.RunSaves) == "table" then
					profile.RunSaves[mapId] = nil
				end
				-- A partida acabou: não faz sentido "Reconectar" nela.
				profile.LastMatch = nil

				DataService.IncrementStat(player, "ActsCompleted", 1)
				callService("AchievementService", "FireEvent", player, "CompleteMap", { Map = mapId })
				DataService.SyncProfile(player)

				local reward = mapDef.TokensReward or 0
				if reward > 0 then
					StateService.Notify(player, ("Ato concluído! +%d Brainrot Tokens"):format(reward), "success", 6)
				end
			end
		end
	end

	-- Apaga a partida salva do time (em segundo plano).
	if runKey then
		task.spawn(function()
			local ok, err = pcall(DataService.DeleteRun, runKey)
			if not ok then
				warn("[MatchService] Falha ao apagar a partida salva: " .. tostring(err))
			end
		end)
	end

	if #travelers == 0 then
		actCompleting = false
		return false, "Não há jogadores para levar."
	end

	-- Último ato (Deserto): fim de jogo, todos voltam ao lobby.
	if not nextMapId or not isValidMapId(nextMapId) then
		StateService.NotifyAll("Vocês completaram o jogo! Voltando para o lobby...", "rare", 8)
		local ok, result = callService("TravelService", "SendToLobby", travelers)
		if not ok or result == false then
			actCompleting = false
			return false, "Não foi possível voltar ao lobby agora."
		end
		return true
	end

	-- Próximo ato: novo servidor reservado com o próximo mapa.
	-- Dono = o dono atual, se estiver aqui; senão o primeiro jogador da lista.
	local hostUserId = MatchService.GetHostUserId()
	if not hostUserId or not Players:GetPlayerByUserId(hostUserId) then
		hostUserId = travelers[1].UserId
	end
	local handoff = MatchService.Handoff
	StateService.NotifyAll(("Viajando para %s..."):format(Maps[nextMapId].DisplayName), "success", 6)

	local okCall, ok, err = callService("TravelService", "SendToNewMatch", travelers, {
		MapId = nextMapId,
		HostUserId = hostUserId,
		MaxPlayers = handoff.MaxPlayers or LobbyConfig.MaxPlayersLimit,
		Privacy = handoff.Privacy or "Invite",
		Resume = false,
	})
	if not okCall or ok == false then
		local message = (okCall and type(err) == "string" and err) or "Não foi possível viajar para o próximo ato."
		StateService.NotifyAll(message, "error", 10)
		actCompleting = false
		return false, message
	end
	return true
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function MatchService.Init()
	-- Request "ReturnToLobby" (registrado antes de qualquer espera).
	Net.Handle("ReturnToLobby", function(player)
		if not accepted[player] then
			return false, "Você não está nesta partida."
		end
		syncRunToProfile(player)
		StateService.Notify(player, "Voltando para o lobby...", "info")
		task.spawn(function()
			local ok, result = callService("TravelService", "SendToLobby", { player })
			if (not ok or result == false) and player.Parent == Players then
				StateService.Notify(player, "Não foi possível voltar ao lobby agora. Tente de novo.", "error")
			end
		end)
		return true, true
	end, { Rate = 1, Burst = 2 })

	-- 1. Descobre qual partida é esta (pode esperar o MemoryStore).
	local handoff, bounce = resolveHandoff()
	bounceEveryone = bounce
	MatchService.Handoff = handoff
	MatchService.MapId = handoff.MapId
	MatchService.MapDef = Maps[handoff.MapId]
	MatchService.Act = MatchService.MapDef.Act
	startedAt = workspace:GetServerTimeNow()

	-- 2. Monta o mapa.
	local okBuild, ctx = pcall(MapBuilder.Build, MatchService.MapId)
	if okBuild and type(ctx) == "table" then
		MatchService.Context = ctx
	else
		warn("[MatchService] Falha ao montar o mapa " .. tostring(MatchService.MapId) .. ": " .. tostring(ctx))
	end

	-- 3. Pastas usadas pelos outros serviços.
	ensureWorkspaceFolder("Brainrots")
	ensureWorkspaceFolder("Coins")
	ensureWorkspaceFolder("Turrets")

	-- 4. Save do time.
	--    * "Continuar partida" (Resume): carrega o save do time.
	--    * Partida criada pelo lobby (handoff com CreatedAt) SEM Resume: também lê o save,
	--      porque este pode ser o mesmo servidor reservado aberto de novo pelo "Reconectar"
	--      (todos saíram, ele fechou, e o handoff do MemoryStore ainda diz Resume = false).
	--      Se o save foi gravado por esta partida (isSavedByThisMatch), restauramos tudo;
	--      senão é um save antigo e a partida começa do zero, como antes.
	if not bounceEveryone and (handoff.Resume or handoff.CreatedAt ~= nil) then
		local key = getRunKey()
		if key then
			-- LoadRun devolve (nil, "error") quando o DataStore falhou (diferente de "não existe save").
			local okLoad, saved, loadError = pcall(DataService.LoadRun, key)
			if not okLoad or loadError ~= nil then
				-- Não conseguimos LER o save: não sabemos o que tem lá. Para não apagar um
				-- progresso bom com um time vazio, o SaveAll não grava por cima até conseguir ler.
				teamSaveBlocked = true
				warn("[MatchService] Falha ao carregar a partida salva: " .. tostring(if okLoad then loadError else saved))
			elseif saved ~= nil then
				if handoff.Resume then
					applyTeamSave(saved)
				elseif isSavedByThisMatch(saved) then
					applyTeamSave(saved)
					resumingSameMatch = true
				end
			end
		end
	end

	-- 5. Prateleiras visíveis de acordo com o nível salvo.
	if MatchService.Context then
		local okShelf, shelfErr = pcall(MapBuilder.SetShelfLevel, MatchService.Context, MatchService.Team.ShelfLevel)
		if not okShelf then
			warn("[MatchService] Falha ao ajustar as prateleiras: " .. tostring(shelfErr))
		end
	end

	-- 6. Estado global inicial.
	local team = MatchService.Team
	publishMatch()
	StateService.SetAll("TeamUpgrades", table.clone(team.Upgrades))
	StateService.SetAll("ShelfLevel", team.ShelfLevel)
	StateService.SetAll("Recipes", table.clone(team.Recipes))
	StateService.SetAll("Buffs", table.clone(team.Buffs))
	StateService.SetAll("Completed", false)
	StateService.SetAll("TeamList", {})
	if GameConfig.SharedWallet then
		StateService.SetAll("Coins", team.SharedCoins)
	end
end

function MatchService.Start()
	-- Perfil que chegou depois de onPlayerAdded desistir de esperar (trava de outro servidor
	-- demorando para vencer): cria o run agora. setupPlayerRun ignora quem já tem o run pronto.
	DataService.ProfileLoaded:Connect(function(player, profile)
		if accepted[player] then
			setupPlayerRun(player, profile)
		end
	end)

	-- Jogadores (inclusive os que chegaram enquanto o servidor preparava o mapa).
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	-- Loop de 1 Hz: renda, TeamList e cópia dos runs nos perfis.
	task.spawn(function()
		local dt = TEAM_LIST_INTERVAL
		while true do
			local ok, err = pcall(teamListTick, math.max(dt, 0.05))
			if not ok then
				warn("[MatchService] Erro no loop do time: " .. tostring(err))
			end
			dt = task.wait(TEAM_LIST_INTERVAL)
		end
	end)

	-- Autosave do time.
	task.spawn(function()
		while true do
			task.wait(GameConfig.AutosaveInterval)
			local ok, err = pcall(MatchService.SaveAll)
			if not ok then
				warn("[MatchService] Erro no autosave: " .. tostring(err))
			end
		end
	end)

	-- Servidor fechando: salva a partida do time.
	game:BindToClose(function()
		local ok, err = pcall(MatchService.SaveAll)
		if not ok then
			warn("[MatchService] Erro ao salvar no fechamento: " .. tostring(err))
		end
	end)
end

return MatchService
