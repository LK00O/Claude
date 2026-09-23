-- Main.client.lua: ponto de partida do cliente (LocalScript).
--
-- 1. Espera o servidor dizer o papel deste servidor (workspace "Role" = "Lobby" ou "Match").
-- 2. Carrega (require) os controllers e janelas na ordem da especificação (seção 10.1).
-- 3. Chama Init() de todos e depois Start() de todos, cada um protegido:
--    se um módulo der erro, aparece um aviso no Output e os outros continuam.
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

-- Módulos que rodam sempre (lobby e partida), nesta ordem.
local ALWAYS = {
	{ ControllersFolder, "StateController" },
	{ ControllersFolder, "NotifyController" },
	{ UIFolder, "UIKit" },
	{ ControllersFolder, "PromptController" },
	{ ControllersFolder, "MobileController" },
	{ ControllersFolder, "MusicController" },
	{ ControllersFolder, "MovementController" },
	{ UIFolder, "SettingsWindow" },
	{ UIFolder, "DebugPanel" },
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

-- Carrega um módulo (require). Devolve a tabela do módulo ou nil.
local function loadModule(folder, name)
	local moduleScript = folder:FindFirstChild(name) or folder:WaitForChild(name, 10)
	if not moduleScript then
		warn(("[Main] Módulo %s/%s não encontrado; pulando."):format(folder.Name, name))
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

-------------------------------------------------------------------------------
-- Inicialização
-------------------------------------------------------------------------------

local role = waitForRole()

-- Monta a lista de módulos deste papel.
local list = {}
for _, item in ipairs(ALWAYS) do
	table.insert(list, item)
end
for _, item in ipairs(role == "Match" and MATCH_ONLY or LOBBY_ONLY) do
	table.insert(list, item)
end

-- 1. Carrega todos.
local entries = {}
for _, item in ipairs(list) do
	local folder, name = item[1], item[2]
	local module = loadModule(folder, name)
	if module then
		table.insert(entries, { Name = name, Module = module })
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
end

print(("[Main] Cliente pronto (%s): %d módulos iniciados."):format(role, #entries))
