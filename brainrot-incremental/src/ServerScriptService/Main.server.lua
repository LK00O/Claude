-- Main (Script do servidor): liga o jogo inteiro, na ordem certa.
--
-- Ordem (seção 8.1 da especificação):
--   1. Cria os remotes (Net.Init) e os grupos de colisão.
--   2. Descobre o papel do servidor ("Lobby" ou "Match") e grava no atributo "Role"
--      do Workspace (o cliente lê daí). Se o modo de teste estiver ligado, grava "DebugEnabled".
--   3. Serviços comuns (lobby e partida, inclusive o AdminService): Init.
--   4. Lobby: LobbyService, PartyService, ShopService, MonetizationService (Init, depois Start de todos).
--   5. Partida: MatchService.Init() (resolve a partida e constrói o mapa — pode demorar),
--      depois o Init de todos os serviços da partida, o Start de todos e, por último,
--      MatchService.Start() (começa a aceitar jogadores).
--   6. Cada Init/Start roda protegido: se um serviço quebrar, o erro aparece no Output
--      com o nome dele e os outros continuam funcionando.
--   7. Cada Init/Start roda no máximo UMA vez por servidor (tabela phaseDone): um serviço
--      que aparece em duas listas (MonetizationService) ou uma fase chamada de novo
--      nunca registra handlers ou conexões em dobro.
--   8. Só no Studio (Config.Game.StudioInPlaceMatch): o lobby de teste pode virar a
--      partida NO MESMO servidor, porque o teleporte não funciona no Studio. O Main
--      registra switchToMatch no TravelService; quando um grupo inicia, a troca desliga
--      o lobby, liga os serviços da partida e muda o atributo "Role" para "Match"
--      (uma vez só por teste). Num jogo publicado nada disso existe.

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
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
-- O AdminService (comandos de administrador, avisos e eventos globais) roda nos dois
-- papéis; os comandos que precisam da partida respondem com um aviso no lobby.
-- O TravelService vem no fim: ele precisa do Init para escutar TeleportInitFailed
-- e é usado tanto no lobby (grupos, reconexão) quanto na partida (portal, voltar ao lobby).
local COMMON_SERVICES = {
	"StateService",
	"DataService",
	"SettingsService",
	"AchievementService",
	"DebugService",
	"AdminService",
	"TravelService",
}

-- O MonetizationService aparece nas duas listas (lobby e partida): no lobby ele vende
-- os game passes e mostra o VIP; na partida também aplica os efeitos dos passes.
local LOBBY_SERVICES = {
	"LobbyService",
	"PartyService",
	"ShopService",
	"MonetizationService",
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

-- Fases que já rodaram: ["NomeDoServiço.Init"] = true. Chamar a mesma fase de novo
-- não faz nada (ex.: o MonetizationService está na lista do lobby E na da partida).
local phaseDone = {}

-- Chama service[method]() protegido. Um erro vira um aviso com o nome do serviço.
-- Cada fase roda uma vez só: a marca vem ANTES de rodar, então nem uma fase que deu
-- erro é repetida (um Init pela metade rodando de novo duplicaria conexões).
-- Devolve true se a fase rodou sem erro agora, false se deu erro (ou o serviço/função
-- não existe) e nil se ela já tinha rodado antes. (Só a troca do Studio usa o retorno.)
local function callPhase(name, method)
	local key = name .. "." .. method
	if phaseDone[key] then
		return nil
	end
	phaseDone[key] = true

	local service = loadService(name)
	if not service then
		return false
	end
	local fn = service[method]
	if type(fn) ~= "function" then
		warn(("[Main] %s não tem a função %s()."):format(name, method))
		return false
	end

	local ok, err = xpcall(fn, debug.traceback)
	if not ok then
		warn(("[Main] Erro em %s.%s(): %s"):format(name, method, tostring(err)))
	end
	return ok
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
-- O atributo "DebugMode" do Workspace só vale no Studio: se ele ficar salvo no place
-- publicado, é ignorado. Fora do Studio, só o Config.Game.DebugMode liga o modo (e,
-- mesmo assim, o DebugService só aceita comandos de administradores).
local function isDebugEnabled()
	if RunService:IsStudio() then
		return true
	end
	return GameConfig.DebugMode == true
end

-------------------------------------------------------------------------------
-- Troca lobby -> partida no mesmo servidor (só no Studio)
-------------------------------------------------------------------------------

-- Aviso do Kick quando a troca dá errado (o erro completo fica no Output).
local MSG_SWITCH_FAILED =
	"O teste no Studio não conseguiu abrir a partida (veja o erro no Output). Pare o teste e dê Play de novo."

-- Papel atual deste servidor (gravado no passo 2; a troca do Studio muda para "Match").
local role = "Lobby"
-- A troca já aconteceu (ou está acontecendo)? Ela roda no máximo uma vez por teste.
local switched = false

-- Chama service.Stop() protegido (PartyService e LobbyService têm Stop; é seguro chamar
-- duas vezes). Um erro vira aviso e a troca continua.
local function stopService(name)
	local service = loadService(name)
	local fn = service and service.Stop
	if type(fn) ~= "function" then
		warn(("[Main] %s não tem a função Stop(); seguindo sem desligar."):format(name))
		return
	end
	local ok, err = xpcall(fn, debug.traceback)
	if not ok then
		warn(("[Main] Erro em %s.Stop(): %s"):format(name, tostring(err)))
	end
end

-- Prende (Anchored) o HumanoidRootPart de todos os personagens: o mapa do lobby vai ser
-- apagado, e sem isso eles cairiam no vazio antes de renascer na partida.
-- Devolve a lista das partes presas (para soltar quem não renascer).
local function anchorAllCharacters()
	local anchored = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local ok = pcall(function()
				root.Anchored = true
			end)
			if ok then
				table.insert(anchored, root)
			end
		end
	end
	return anchored
end

-- Faz todo mundo renascer (Player:LoadCharacterAsync): o personagem novo nasce no
-- SpawnLocation da partida (o MatchService já preencheu player.RespawnLocation) e a
-- etiqueta VIP é montada de novo com as regras da partida. Um por vez, protegido.
-- Quem não conseguiu renascer tem o HumanoidRootPart antigo solto de novo (o
-- MatchService já levou esse personagem para o spawn da partida).
local function respawnEveryone(anchoredRoots)
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Parent == Players then
			local ok, err = pcall(function()
				player:LoadCharacterAsync()
			end)
			if not ok then
				warn(("[Main] Studio: %s não renasceu na partida: %s"):format(player.Name, tostring(err)))
			end
		end
	end
	for _, root in ipairs(anchoredRoots) do
		if root.Parent ~= nil and root:IsDescendantOf(workspace) then
			pcall(function()
				root.Anchored = false
			end)
		end
	end
end

-- Os passos da troca (seção 8.16 da especificação), na ordem. Qualquer erro sobe para
-- switchToMatch, que avisa e encerra o teste.
local function runStudioSwitch(handoff)
	local mapId = tostring(handoff.MapId)
	print(("[Main] Studio: trocando o lobby pela partida %s neste servidor..."):format(mapId))

	-- a. Avisa os clientes (o LobbyUI mostra a tela de transição). O mapa vai primeiro:
	--    quando o cliente vê StudioSwitching = true, o StudioSwitchMap já chegou.
	workspace:SetAttribute("StudioSwitchMap", mapId)
	workspace:SetAttribute("StudioSwitching", true)

	-- b. Ninguém cai enquanto o mapa é trocado.
	local anchoredRoots = anchorAllCharacters()

	-- c. Desliga o lobby: grupos, contagens, placares e laços param de rodar.
	stopService("PartyService")
	stopService("LobbyService")

	-- d. MatchService.Init com o handoff do grupo (o MapBuilder apaga o lobby e monta o mapa).
	local matchService = loadService("MatchService")
	if not matchService then
		error("MatchService não carregou")
	end
	matchService.StudioHandoff = handoff
	if callPhase("MatchService", "Init") ~= true then
		error("MatchService.Init() falhou (veja o erro acima)")
	end
	if matchService.MapId == nil or matchService.Context == nil then
		error("o mapa " .. mapId .. " não foi montado")
	end

	-- e. Init dos serviços da partida (o MonetizationService já rodou no lobby: é pulado).
	runPhase(MATCH_SERVICES, "Init")

	-- f. Agora este servidor é a partida (o cliente liga os controles da partida ao ver
	--    o atributo "Role" mudar).
	PlaceRole.SetRuntimeRole("Match")
	role = "Match"
	workspace:SetAttribute("Role", "Match")

	-- g. Start dos serviços da partida e, por último, do MatchService (ele trata os
	--    jogadores que já estão no servidor).
	runPhase(MATCH_SERVICES, "Start")
	callPhase("MatchService", "Start")

	-- h. Todos renascem no spawn da partida.
	respawnEveryone(anchoredRoots)

	print(("[Main] Studio: servidor pronto como partida (%s)."):format(mapId))
end

-- switchToMatch(handoff): transforma o lobby de teste na partida, no mesmo servidor.
-- Só no Studio, só a partir do lobby e uma vez só (uma segunda chamada é ignorada).
-- O TravelService chama com task.defer quando um grupo inicia (SetStudioMatchSwitch).
-- Se algo der errado no meio, o servidor fica pela metade: avisamos bem alto no Output e
-- expulsamos todos com uma mensagem clara (é só dar Play de novo).
local function switchToMatch(handoff)
	if not RunService:IsStudio() or role ~= "Lobby" then
		return
	end
	if switched then
		warn("[Main] Studio: a troca para a partida já aconteceu; pedido ignorado.")
		return
	end
	if type(handoff) ~= "table" then
		warn("[Main] Studio: troca para a partida sem handoff; pedido ignorado.")
		return
	end
	switched = true

	local ok, err = xpcall(runStudioSwitch, debug.traceback, handoff)

	-- i. Fim da troca (deu certo ou não).
	workspace:SetAttribute("StudioSwitching", nil)
	workspace:SetAttribute("StudioSwitchMap", nil)

	if not ok then
		warn("[Main] ============================================================")
		warn("[Main] Studio: a troca do lobby para a partida FALHOU: " .. tostring(err))
		warn("[Main] ============================================================")
		for _, player in ipairs(Players:GetPlayers()) do
			pcall(function()
				player:Kick(MSG_SWITCH_FAILED)
			end)
		end
	end
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

local roleOk, placeRole = pcall(PlaceRole.Get)
if roleOk and (placeRole == "Lobby" or placeRole == "Match") then
	role = placeRole
else
	warn("[Main] Não foi possível decidir o papel do servidor; usando Lobby. " .. tostring(placeRole))
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

	-- Só no Studio: iniciar um grupo transforma este servidor na partida (sem teleporte).
	if RunService:IsStudio() and GameConfig.StudioInPlaceMatch ~= false then
		local travelService = loadService("TravelService")
		if travelService and type(travelService.SetStudioMatchSwitch) == "function" then
			travelService.SetStudioMatchSwitch(switchToMatch)
			print("[Main] Studio: crie um grupo e clique em Iniciar para abrir a partida neste mesmo servidor.")
		else
			warn("[Main] TravelService.SetStudioMatchSwitch não existe; a partida não abre pelo lobby do Studio.")
		end
	end
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
