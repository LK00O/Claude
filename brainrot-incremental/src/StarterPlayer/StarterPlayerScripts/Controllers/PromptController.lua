-- PromptController: liga os ProximityPrompts do mundo às janelas do cliente.
--
-- Prompts com o atributo "ClientAction" (ex.: "Stall:Weapon", "Cauldron", "Shop")
-- são tratados aqui no cliente: quando o jogador aperta o prompt, chamamos a função
-- registrada para aquela ação. O formato é "Ação" ou "Ação:Argumento".
-- (Prompts com "ServerAction" são tratados pelo servidor; aqui só ignoramos.)
--
-- API (seção 10.3 da especificação):
--   PromptController.Register(action, fn(arg, prompt)) -> conexão
--   PromptController.Dispatch(action, arg?, prompt?)   -> chama as funções registradas
-- Também:
--   - o servidor pode pedir para abrir uma interface pelo evento "OpenUI" (action, arg);
--   - a tecla "Interact" escolhida nas Configurações vale para todos os prompts;
--   - enquanto uma janela está aberta, os prompts ficam escondidos.
-- Extra: PromptController.SetHidden(reason, hidden) esconde os prompts por outro motivo.

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Util"):WaitForChild("Net"))
local Keybinds = require(Shared:WaitForChild("Config"):WaitForChild("Keybinds"))

local UIKit = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("UIKit"))
local StateController = require(script.Parent:WaitForChild("StateController"))

local PromptController = {}

-------------------------------------------------------------------------------
-- Constantes e estado
-------------------------------------------------------------------------------

-- Tecla padrão do "Interagir" (a mesma que o servidor coloca em todos os prompts).
local interactAction = Keybinds.ById.Interact
local DEFAULT_INTERACT_KEY = interactAction and interactAction.Default or Enum.KeyCode.E

-- Atributo (local, não vai para o servidor) que marca os prompts que usam a tecla do jogador.
local MANAGED_ATTRIBUTE = "InteractManaged"

-- Por quanto tempo guardamos um pedido que chegou antes de alguém registrar a ação.
local PENDING_TTL = 10

local handlers = {} -- [action] = {fn, fn, ...}
local pending = {} -- [action] = {Arg, Prompt, Time}
local managedPrompts = {} -- [ProximityPrompt] = {conexões}
local currentKey = DEFAULT_INTERACT_KEY
local hideReasons = {} -- [motivo] = true (qualquer motivo esconde os prompts)
local warned = {}
local initialized = false

local function warnOnce(message)
	if not warned[message] then
		warned[message] = true
		warn(message)
	end
end

-------------------------------------------------------------------------------
-- Ações
-------------------------------------------------------------------------------

-- Separa "Ação:Argumento" em ("Ação", "Argumento"). Sem ":" -> ("Ação", nil).
local function parseAction(text)
	local action, arg = string.match(text, "^([^:]+):(.*)$")
	if action then
		if arg == "" then
			arg = nil
		end
		return action, arg
	end
	return text, nil
end

-- Roda uma função registrada com proteção (um erro não derruba as outras).
local function runHandler(action, fn, arg, prompt)
	task.spawn(function()
		local ok, err = pcall(fn, arg, prompt)
		if not ok then
			warn(("[PromptController] Erro na ação '%s': %s"):format(action, tostring(err)))
		end
	end)
end

-- PromptController.Register(action, fn(arg, prompt)) -> conexão (com :Disconnect())
-- Ex.: PromptController.Register("Stall", function(stallId) ... end)
function PromptController.Register(action, fn)
	assert(type(action) == "string" and action ~= "", "[PromptController] Register: action precisa ser um texto")
	assert(type(fn) == "function", "[PromptController] Register: fn precisa ser uma função")

	local list = handlers[action]
	if not list then
		list = {}
		handlers[action] = list
	end
	table.insert(list, fn)

	-- Se um pedido chegou há pouco, antes de alguém registrar, atende agora.
	local waiting = pending[action]
	if waiting then
		pending[action] = nil
		if os.clock() - waiting.Time <= PENDING_TTL then
			runHandler(action, fn, waiting.Arg, waiting.Prompt)
		end
	end

	local connection = { Connected = true }
	function connection.Disconnect()
		if not connection.Connected then
			return
		end
		connection.Connected = false
		local index = table.find(list, fn)
		if index then
			table.remove(list, index)
		end
	end
	return connection
end

-- PromptController.Dispatch(action, arg?, prompt?) -> true se alguém tratou
-- Também aceita Dispatch("Stall:Weapon") (separa o argumento sozinho).
function PromptController.Dispatch(action, arg, prompt)
	if type(action) ~= "string" or action == "" then
		return false
	end
	if arg == nil then
		action, arg = parseAction(action)
	end

	local list = handlers[action]
	if not list or #list == 0 then
		-- Ninguém registrou ainda: guarda por alguns segundos (o módulo pode estar iniciando).
		pending[action] = { Arg = arg, Prompt = prompt, Time = os.clock() }
		warnOnce(("[PromptController] Nenhuma função registrada para a ação '%s'."):format(action))
		return false
	end

	for _, fn in ipairs(table.clone(list)) do
		runHandler(action, fn, arg, prompt)
	end
	return true
end

-------------------------------------------------------------------------------
-- Tecla de interação
-------------------------------------------------------------------------------

-- Coloca a tecla escolhida pelo jogador num prompt.
local function applyKey(prompt)
	if prompt.KeyboardKeyCode ~= currentKey then
		prompt.KeyboardKeyCode = currentKey
	end
end

-- Para de cuidar de um prompt (saiu do workspace ou foi destruído).
local function forgetPrompt(prompt)
	local connections = managedPrompts[prompt]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		managedPrompts[prompt] = nil
	end
end

-- Começa a cuidar de um prompt novo do workspace.
local function trackPrompt(prompt)
	if managedPrompts[prompt] then
		return
	end
	-- Só trocamos prompts que usam a tecla padrão (um prompt com outra tecla
	-- de propósito continua como está, ex.: o "ModePrompt" da torreta, na tecla F).
	-- Não basta a tecla ser igual à do jogador: se o Interagir fosse F, o ModePrompt
	-- seria "adotado" por engano e iria junto para a próxima tecla escolhida.
	-- Por isso marcamos os prompts adotados com um atributo (só neste cliente): um
	-- prompt que saiu do workspace e voltou já com a tecla do jogador é reconhecido.
	local adopted = prompt:GetAttribute(MANAGED_ATTRIBUTE) == true
	if prompt.KeyboardKeyCode ~= DEFAULT_INTERACT_KEY and not adopted then
		return
	end

	local connections = {}
	managedPrompts[prompt] = connections
	prompt:SetAttribute(MANAGED_ATTRIBUTE, true)
	applyKey(prompt)

	-- Se o servidor voltar a tecla para a padrão, colocamos a do jogador de novo.
	table.insert(
		connections,
		prompt:GetPropertyChangedSignal("KeyboardKeyCode"):Connect(function()
			if prompt.KeyboardKeyCode == DEFAULT_INTERACT_KEY then
				applyKey(prompt)
			end
		end)
	)
	-- Saiu do workspace: esquece (se voltar, o DescendantAdded pega de novo).
	table.insert(
		connections,
		prompt.AncestryChanged:Connect(function()
			if not prompt:IsDescendantOf(workspace) then
				forgetPrompt(prompt)
			end
		end)
	)
end

-- Relê a tecla "Interact" das configurações e aplica em todos os prompts.
local function refreshInteractKey()
	local key = StateController.GetKeybind("Interact") or DEFAULT_INTERACT_KEY
	if key == currentKey then
		return
	end
	currentKey = key
	for prompt in pairs(managedPrompts) do
		if prompt.Parent then
			applyKey(prompt)
		end
	end
end

-------------------------------------------------------------------------------
-- Esconder prompts
-------------------------------------------------------------------------------

-- Liga/desliga todos os prompts deste jogador conforme os motivos ativos.
local function refreshPromptVisibility()
	local shouldShow = next(hideReasons) == nil
	local ok, err = pcall(function()
		ProximityPromptService.Enabled = shouldShow
	end)
	if not ok then
		warnOnce("[PromptController] Não consegui esconder os prompts: " .. tostring(err))
	end
end

-- PromptController.SetHidden(reason, hidden) — esconde os prompts enquanto
-- algum motivo estiver ativo (ex.: "Modal").
function PromptController.SetHidden(reason, hidden)
	reason = tostring(reason or "Other")
	hideReasons[reason] = hidden and true or nil
	refreshPromptVisibility()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function PromptController.Init()
	if initialized then
		return
	end
	initialized = true

	-- Prompt apertado pelo jogador local.
	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if player ~= Players.LocalPlayer then
			return
		end
		local clientAction = prompt:GetAttribute("ClientAction")
		if type(clientAction) ~= "string" or clientAction == "" then
			return -- prompt do servidor (ServerAction) ou sem ação
		end
		local action, arg = parseAction(clientAction)
		PromptController.Dispatch(action, arg, prompt)
	end)

	-- O servidor pediu para abrir uma interface (mesmo formato do ClientAction).
	Net.On("OpenUI", function(action, arg)
		if type(action) ~= "string" then
			return
		end
		PromptController.Dispatch(action, arg, nil)
	end)

	-- Janela aberta = prompts escondidos.
	UIKit.ModalChanged:Connect(function(isAnyOpen)
		PromptController.SetHidden("Modal", isAnyOpen)
	end)

	-- Todos os prompts do workspace, inclusive os que aparecerem depois.
	workspace.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") then
			trackPrompt(descendant)
		end
	end)
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			trackPrompt(descendant)
		end
	end
end

function PromptController.Start()
	-- Aplica a tecla atual e acompanha mudanças nas Configurações.
	refreshInteractKey()
	StateController.OnChanged("Profile", refreshInteractKey)

	-- Estado inicial (caso algum modal já esteja aberto).
	PromptController.SetHidden("Modal", UIKit.IsAnyModalOpen())
end

-- Deixa as funções do módulo funcionarem com "." e também com ":"
-- (ex.: PromptController.Algo(x) e PromptController:Algo(x) fazem a mesma coisa).
for name, fn in pairs(PromptController) do
	if type(fn) == "function" then
		PromptController[name] = function(first, ...)
			if first == PromptController then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return PromptController
