-- Main.client.lua: ponto de partida do cliente (LocalScript).
--
-- 1. Espera o servidor dizer o papel deste servidor (workspace "Role" = "Lobby" ou "Match").
-- 2. Carrega (require) os controllers e janelas na ordem da especificação (seção 10.1).
-- 3. Chama Init() de todos e depois Start() de todos, cada um protegido:
--    se um módulo der erro, aparece um aviso no Output e os outros continuam.
--    (Isso tudo fica na função bootList(lista), usada no começo e na troca de papel.)
-- 4. Teste no Studio: o servidor abre no lobby e, quando um grupo começa, vira a partida
--    no MESMO servidor (o "Role" muda de "Lobby" para "Match", uma vez só). Aí este script
--    liga os módulos da partida (MATCH_ONLY) e desliga a interface do lobby
--    (LobbyUI.Shutdown). A volta (Match -> Lobby) não existe: o servidor expulsa no fim.
--
-- Os módulos ficam em Players.LocalPlayer.PlayerScripts (irmãos deste script).

local root = script.Parent
local ControllersFolder = root:WaitForChild("Controllers")
local UIFolder = root:WaitForChild("UI")

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Tempo máximo esperando um módulo terminar cada etapa antes de seguir em frente
-- (o módulo continua rodando; só não seguramos os outros por causa dele).
local REQUIRE_TIMEOUT = 15
local INIT_TIMEOUT = 15
local START_TIMEOUT = 10
-- O StateController espera o estado completo do servidor (que pode demorar um pouco
-- quando o servidor acabou de abrir), então ele ganha mais tempo.
local STATE_INIT_TIMEOUT = 45
-- Quanto tempo esperamos um ModuleScript aparecer na pasta (normal / opcional).
local MODULE_WAIT = 10
local OPTIONAL_WAIT = 2

-- Módulos que rodam sempre (lobby e partida), nesta ordem.
-- Cada item: { pasta, "Nome", opcional? } (opcional = true: pode não existir).
local ALWAYS = {
	{ ControllersFolder, "StateController" },
	{ ControllersFolder, "NotifyController" },
	{ UIFolder, "UIKit" },
	{ ControllersFolder, "PromptController" },
	{ ControllersFolder, "MobileController" },
	{ ControllersFolder, "MusicController" },
	-- Ambiente do mapa (bichinhos, partículas, luzes piscando...). É opcional (o "true" no
	-- fim): se o arquivo não existir, o jogo segue sem ele (só um aviso no Output).
	{ ControllersFolder, "AmbientController", true },
	{ ControllersFolder, "MovementController" },
	{ ControllersFolder, "ChatTagController" },
	-- Admin (lobby e partida): voo do admin, faixas de aviso/evento para todos e o painel.
	{ ControllersFolder, "FlyController" },
	{ ControllersFolder, "AnnouncementController" },
	{ UIFolder, "SettingsWindow" },
	{ UIFolder, "DebugPanel" },
	{ UIFolder, "AdminPanel" },
}

-- Só na partida.
local MATCH_ONLY = {
	{ ControllersFolder, "CameraController" },
	{ ControllersFolder, "EffectsController" },
	{ ControllersFolder, "WeaponController" },
	{ ControllersFolder, "PlacementController" },
	{ ControllersFolder, "HUDController" },
	{ UIFolder, "StallWindow" },
	{ UIFolder, "CauldronWindow" },
	{ UIFolder, "SupremeWindow" },
	{ ControllersFolder, "EndingController" },
}

-- Só no lobby.
local LOBBY_ONLY = {
	{ UIFolder, "LobbyUI" },
}

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- true se o texto é um papel válido.
local function isValidRole(role)
	return role == "Lobby" or role == "Match"
end

-- Espera o atributo "Role" que o servidor grava no workspace.
local function waitForRole()
	local role = workspace:GetAttribute("Role")
	if isValidRole(role) then
		return role
	end

	-- Se demorar muito, avisa no Output (ajuda a achar erro no servidor).
	local warnThread = task.delay(20, function()
		warn("[Main] Ainda esperando o servidor definir workspace.Role (Lobby ou Match)...")
	end)

	-- Ainda não existe: espera o atributo mudar.
	repeat
		workspace:GetAttributeChangedSignal("Role"):Wait()
		role = workspace:GetAttribute("Role")
	until isValidRole(role)

	pcall(task.cancel, warnThread)
	return role
end

-- Roda fn(...) numa thread separada e espera até ela terminar ou o tempo acabar.
-- Devolve: terminou (boolean), deu certo (boolean), resultado ou erro.
local function runWithTimeout(timeout, fn, ...)
	local finished, success, result = false, false, nil
	local args = table.pack(...)

	task.spawn(function()
		local ok, value = xpcall(function()
			return fn(table.unpack(args, 1, args.n))
		end, debug.traceback)
		success, result = ok, value
		finished = true
	end)

	local startTime = os.clock()
	while not finished and os.clock() - startTime < timeout do
		task.wait()
	end
	return finished, success, result
end

-- Módulos que já avisamos que estão faltando (o aviso sai uma vez só por módulo).
local warnedMissing = {}

-- Carrega um módulo (require). Devolve a tabela do módulo ou nil.
-- optional = true: o módulo pode não existir (espera pouco e avisa uma vez só).
local function loadModule(folder, name, optional)
	local waitTime = optional and OPTIONAL_WAIT or MODULE_WAIT
	local moduleScript = folder:FindFirstChild(name) or folder:WaitForChild(name, waitTime)
	if not moduleScript then
		local key = folder.Name .. "/" .. name
		if not warnedMissing[key] then
			warnedMissing[key] = true
			if optional then
				warn(("[Main] Módulo opcional %s não encontrado; o jogo segue sem ele."):format(key))
			else
				warn(("[Main] Módulo %s não encontrado; pulando."):format(key))
			end
		end
		return nil
	end

	local finished, ok, result = runWithTimeout(REQUIRE_TIMEOUT, require, moduleScript)
	if not finished then
		warn(("[Main] require de %s demorou mais de %d s; pulando."):format(name, REQUIRE_TIMEOUT))
		return nil
	end
	if not ok then
		warn(("[Main] Erro ao carregar %s:\n%s"):format(name, tostring(result)))
		return nil
	end
	if type(result) ~= "table" then
		warn(("[Main] %s não devolveu uma tabela; pulando."):format(name))
		return nil
	end
	return result
end

-- Chama module[methodName]() (Init ou Start) com proteção e tempo máximo.
local function runLifecycle(entry, methodName, timeout)
	local fn = entry.Module[methodName]
	if type(fn) ~= "function" then
		return
	end
	-- Passamos o próprio módulo como argumento: funciona com "function M.Init()"
	-- e também com "function M:Init()".
	local finished, ok, err = runWithTimeout(timeout, fn, entry.Module)
	if not finished then
		warn(
			("[Main] %s.%s() ainda não terminou depois de %d s; seguindo com os outros módulos."):format(
				entry.Name,
				methodName,
				timeout
			)
		)
	elseif not ok then
		warn(("[Main] Erro em %s.%s():\n%s"):format(entry.Name, methodName, tostring(err)))
	end
end

-- Tudo que já foi ligado: [nome] = tabela do módulo. Um módulo nunca liga duas vezes.
local loadedModules = {}

-- Liga uma lista de módulos: carrega todos, depois Init de todos (na ordem) e por fim
-- Start de todos (na ordem). Cada etapa é protegida e tem tempo máximo.
-- list = { {pasta, "Nome", opcional?}, ... }
-- Devolve a lista de módulos que carregaram: { {Name = "Nome", Module = tabela}, ... }
local function bootList(list)
	-- 1. Carrega todos.
	local entries = {}
	for _, item in ipairs(list) do
		local folder, name = item[1], item[2]
		if loadedModules[name] == nil then
			local module = loadModule(folder, name, item[3] == true)
			if module then
				table.insert(entries, { Name = name, Module = module })
			end
		end
	end

	-- 2. Init de todos, na ordem.
	for _, entry in ipairs(entries) do
		local timeout = entry.Name == "StateController" and STATE_INIT_TIMEOUT or INIT_TIMEOUT
		runLifecycle(entry, "Init", timeout)
	end

	-- 3. Start de todos, na ordem.
	for _, entry in ipairs(entries) do
		runLifecycle(entry, "Start", START_TIMEOUT)
		loadedModules[entry.Name] = entry.Module
	end

	return entries
end

-- Junta várias listas numa só (mantendo a ordem).
local function joinLists(...)
	local result = {}
	for _, list in ipairs({ ... }) do
		for _, item in ipairs(list) do
			table.insert(result, item)
		end
	end
	return result
end

-------------------------------------------------------------------------------
-- Troca de papel no Studio (lobby -> partida no mesmo servidor)
-------------------------------------------------------------------------------

-- O servidor do Studio virou partida: liga os módulos da partida e desliga o lobby.
-- Roda uma vez só (o servidor também só troca uma vez).
local switchedToMatch = false
local function switchToMatch()
	if switchedToMatch then
		return
	end
	switchedToMatch = true
	print("[Main] O servidor virou partida (teste no Studio): ligando os módulos da partida...")

	local entries = bootList(MATCH_ONLY)

	-- Só agora (com o HUD da partida pronto) a interface do lobby some: a tela de
	-- transição do LobbyUI fica por cima enquanto os módulos da partida ligam.
	local LobbyUI = loadedModules.LobbyUI
	if LobbyUI and type(LobbyUI.Shutdown) == "function" then
		local ok, err = pcall(LobbyUI.Shutdown)
		if not ok then
			warn("[Main] Erro ao desligar o LobbyUI: " .. tostring(err))
		end
	end

	print(("[Main] Cliente pronto (Match, trocado no Studio): %d módulos da partida iniciados."):format(#entries))
end

-- Escuta o atributo "Role" depois do boot no lobby. Só a troca Lobby -> Match conta.
local function watchRoleSwitch()
	local connection
	local function check()
		if switchedToMatch or workspace:GetAttribute("Role") ~= "Match" then
			return -- Match -> Lobby (ou outro valor) é ignorado: o servidor expulsa no fim do teste
		end
		if connection then
			connection:Disconnect()
			connection = nil
		end
		task.spawn(switchToMatch)
	end
	connection = workspace:GetAttributeChangedSignal("Role"):Connect(check)
	-- O papel pode ter mudado enquanto os módulos do lobby ainda estavam ligando.
	check()
end

-------------------------------------------------------------------------------
-- Inicialização
-------------------------------------------------------------------------------

local role = waitForRole()

-- Primeiro boot: módulos de sempre + os do papel atual, numa lista só (assim todos os
-- Init rodam antes de todos os Start, como sempre foi).
local entries = bootList(joinLists(ALWAYS, role == "Match" and MATCH_ONLY or LOBBY_ONLY))

print(("[Main] Cliente pronto (%s): %d módulos iniciados."):format(role, #entries))

-- No lobby, fica de olho na troca para partida (teste no Studio).
if role == "Lobby" then
	watchRoleSwitch()
end
