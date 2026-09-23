-- Main (Script do servidor): liga o jogo inteiro, na ordem certa.
--
-- Ordem (seção 8.1 da especificação):
--   1. Cria os remotes (Net.Init) e os grupos de colisão.
--   2. Descobre o papel do servidor ("Lobby" ou "Match") e grava no atributo "Role"
--      do Workspace (o cliente lê daí). Se o modo de teste estiver ligado, grava "DebugEnabled".
--   3. Serviços comuns (lobby e partida): Init.
--   4. Lobby: LobbyService, PartyService, ShopService (Init, depois Start de todos).
--   5. Partida: MatchService.Init() (resolve a partida e constrói o mapa — pode demorar),
--      depois o Init de todos os serviços da partida, o Start de todos e, por último,
--      MatchService.Start() (começa a aceitar jogadores).
--   6. Cada Init/Start roda protegido: se um serviço quebrar, o erro aparece no Output
--      com o nome dele e os outros continuam funcionando.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Util.Net)
local PlaceRole = require(Shared.Util.PlaceRole)
local GameConfig = require(Shared.Config.Game)

local ServicesFolder = ServerScriptService:WaitForChild("Services")

-------------------------------------------------------------------------------
-- Listas de serviços
-------------------------------------------------------------------------------

-- Comuns aos dois papéis, na ordem da especificação.
-- O TravelService vem no fim: ele precisa do Init para escutar TeleportInitFailed
-- e é usado tanto no lobby (grupos, reconexão) quanto na partida (portal, voltar ao lobby).
local COMMON_SERVICES = {
	"StateService",
	"DataService",
	"SettingsService",
	"AchievementService",
	"DebugService",
	"TravelService",
}

local LOBBY_SERVICES = {
	"LobbyService",
	"PartyService",
	"ShopService",
}

-- Serviços da partida (o MatchService é tratado à parte, antes e depois deles).
local MATCH_SERVICES = {
	"StatService",
	"MonetizationService",
	"CoinService",
	"BrainrotService",
	"CombatService",
	"UpgradeService",
	"ProgressionService",
	"QuestService",
	"TurretService",
	"RecipeService",
	"SupremeService",
}

-- Grupos de colisão e os pares que NÃO colidem entre si.
local COLLISION_GROUPS = { "Players", "Brainrots", "Coins", "Turrets" }
local NON_COLLIDING_PAIRS = {
	{ "Coins", "Players" },
	{ "Coins", "Brainrots" },
	{ "Coins", "Coins" },
	{ "Coins", "Turrets" },
	{ "Brainrots", "Players" },
	{ "Brainrots", "Brainrots" },
}

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Carrega (require) um serviço pelo nome. Devolve a tabela ou nil (com aviso) se falhar.
local loaded = {}
local function loadService(name)
	if loaded[name] ~= nil then
		return loaded[name] or nil
	end

	local moduleScript = ServicesFolder:FindFirstChild(name) or ServicesFolder:WaitForChild(name, 5)
	if not moduleScript then
		warn("[Main] Serviço não encontrado: " .. name)
		loaded[name] = false
		return nil
	end

	local ok, result = xpcall(require, debug.traceback, moduleScript)
	if not ok then
		warn("[Main] Erro ao carregar " .. name .. ": " .. tostring(result))
		loaded[name] = false
		return nil
	end
	if type(result) ~= "table" then
		warn("[Main] " .. name .. " não devolveu uma tabela.")
		loaded[name] = false
		return nil
	end

	loaded[name] = result
	return result
end

-- Chama service[method]() protegido. Um erro vira um aviso com o nome do serviço.
local function callPhase(name, method)
	local service = loadService(name)
	if not service then
		return
	end
	local fn = service[method]
	if type(fn) ~= "function" then
		warn(("[Main] %s não tem a função %s()."):format(name, method))
		return
	end

	local ok, err = xpcall(fn, debug.traceback)
	if not ok then
		warn(("[Main] Erro em %s.%s(): %s"):format(name, method, tostring(err)))
	end
end

-- Roda uma fase (Init ou Start) para uma lista de serviços, em ordem.
local function runPhase(list, method)
	for _, name in ipairs(list) do
		callPhase(name, method)
	end
end

-- Registra os grupos de colisão e as regras entre eles.
local function setupCollisionGroups()
	for _, groupName in ipairs(COLLISION_GROUPS) do
		local ok, err = pcall(function()
			if not PhysicsService:IsCollisionGroupRegistered(groupName) then
				PhysicsService:RegisterCollisionGroup(groupName)
			end
		end)
		if not ok then
			warn("[Main] Não foi possível registrar o grupo de colisão " .. groupName .. ": " .. tostring(err))
		end
	end

	for _, pair in ipairs(NON_COLLIDING_PAIRS) do
		local ok, err = pcall(function()
			PhysicsService:CollisionGroupSetCollidable(pair[1], pair[2], false)
		end)
		if not ok then
			warn(("[Main] Erro na regra de colisão %s x %s: %s"):format(pair[1], pair[2], tostring(err)))
		end
	end
end

-- Modo de teste ligado? (mesma regra do DebugService)
local function isDebugEnabled()
	return RunService:IsStudio() or GameConfig.DebugMode == true or workspace:GetAttribute("DebugMode") == true
end

-------------------------------------------------------------------------------
-- 1. Rede e colisões
-------------------------------------------------------------------------------

local netOk, netErr = xpcall(Net.Init, debug.traceback)
if not netOk then
	warn("[Main] Erro em Net.Init(): " .. tostring(netErr))
end
setupCollisionGroups()

-------------------------------------------------------------------------------
-- 2. Papel do servidor
-------------------------------------------------------------------------------

local roleOk, role = pcall(PlaceRole.Get)
if not roleOk or (role ~= "Lobby" and role ~= "Match") then
	warn("[Main] Não foi possível decidir o papel do servidor; usando Lobby. " .. tostring(role))
	role = "Lobby"
end
workspace:SetAttribute("Role", role)
if isDebugEnabled() then
	workspace:SetAttribute("DebugEnabled", true)
end
print(("[Main] %s — servidor iniciando como %s."):format(GameConfig.GameName, role))

-------------------------------------------------------------------------------
-- 3. Serviços comuns (Init)
-------------------------------------------------------------------------------

runPhase(COMMON_SERVICES, "Init")

-------------------------------------------------------------------------------
-- 4 e 5. Serviços do papel
-------------------------------------------------------------------------------

if role == "Lobby" then
	-- Lobby: Init de todos, depois Start de todos (comuns primeiro).
	runPhase(LOBBY_SERVICES, "Init")
	runPhase(COMMON_SERVICES, "Start")
	runPhase(LOBBY_SERVICES, "Start")
else
	-- Partida: o MatchService resolve a partida e constrói o mapa (pode esperar).
	callPhase("MatchService", "Init")
	runPhase(MATCH_SERVICES, "Init")
	runPhase(COMMON_SERVICES, "Start")
	runPhase(MATCH_SERVICES, "Start")
	-- Por último: começa a aceitar jogadores.
	callPhase("MatchService", "Start")
end

print(("[Main] Servidor pronto (%s)."):format(role))
