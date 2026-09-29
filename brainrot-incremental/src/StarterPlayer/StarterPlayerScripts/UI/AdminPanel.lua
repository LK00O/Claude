-- AdminPanel (lobby e partida): o painel de administrador.
--
-- Só aparece para admins: o servidor (AdminService) grava no jogador o atributo
-- "IsAdmin" = true (e "AdminRole" = "Owner" ou "Admin"). Enquanto ele for true,
-- aparece um botãozinho "ADMIN" no topo da tela (ao lado do "DEBUG", no meio da barra
-- do Roblox, onde não há botões do HUD nem do lobby). Atalho no PC: F3.
--
-- Abas do painel:
--   * Eu         — voar, velocidade, pulo e renascer.
--   * Jogadores  — lista de quem está no servidor; ir até, trazer, moedas, tokens,
--                  liberar mapas, expulsar e banir (com duração e motivo; sempre pede
--                  confirmação) e desbanir por UserId.
--   * Partida    — plantar leva, leva de gigantes, chuva de moedas, maxar tudo, concluir
--                  ato e Supremo (só dentro de uma partida; no lobby aparece um aviso).
--   * Eventos    — aviso para todos os servidores (até 200 letras) e eventos globais.
--   * Comandos   — a lista de Config.Admins.Commands (o que faz e como digitar no chat)
--                  e uma "linha de comando" para digitar qualquer comando.
--
-- Todo botão chama Net.Request("AdminCommand", nome, {argumentos em texto}) e mostra a
-- resposta do servidor num aviso (NotifyController). QUEM DECIDE é o servidor: ele confere
-- de novo se você é admin em TODA chamada. Este painel só facilita os cliques.
--
-- Funciona com mouse, toque e controle (o direcional navega; LB/RB trocam de aba).
-- Como toda janela do UIKit, abrir o painel solta o mouse (a câmera para de girar).
--
-- API:
--   AdminPanel.Open(tab?) / AdminPanel.Close() / AdminPanel.Toggle() / AdminPanel.IsOpen()
--   tab = "Me", "Players", "Match", "Events" ou "Commands".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Admins = require(Config:WaitForChild("Admins"))
local GameConfig = require(Config:WaitForChild("Game"))
local Maps = require(Config:WaitForChild("Maps"))
local Keybinds = require(Config:WaitForChild("Keybinds"))
local Net = require(Util:WaitForChild("Net"))
local Trove = require(Util:WaitForChild("Trove"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))

local UIKit = require(script.Parent:WaitForChild("UIKit"))
local ControllersFolder = script.Parent.Parent:WaitForChild("Controllers")
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme
local LocalPlayer = Players.LocalPlayer

local AdminPanel = {}

-- Outros controllers só dentro de funções (regra anti-require-circular).
local function getController(name)
	local module = ControllersFolder:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

local WINDOW_NAME = "Admin"
local WINDOW_TITLE = "Painel de Admin"
local WINDOW_SIZE = UDim2.fromOffset(780, 620)

local TOGGLE_SCREEN = "AdminButton"
local TOGGLE_ORDER = 25 -- igual ao botão DEBUG: acima do HUD, abaixo das janelas
local TOGGLE_SIZE = UDim2.fromOffset(96, 34)
local TOGGLE_TOP = 8 -- no meio da barra do Roblox (lá não tem botões do Roblox nem do HUD)
local TOGGLE_DEBUG_GAP = 60 -- ao lado do DEBUG (que tem 104 de largura, centralizado)
local TOGGLE_KEY = Enum.KeyCode.F3
local TOGGLE_COLOR = Color3.fromRGB(64, 170, 255)

local TAB_BAR_HEIGHT = 44
local TAB_GAP = 6
local DEFAULT_HEADER_HEIGHT = 56 -- altura do cabeçalho das janelas do UIKit
local CONTENT_MARGIN = 14

local BUTTON_HEIGHT = 44
local GRID_PADDING = 8
local PLAYER_ROW_HEIGHT = 48
local REFRESH_INTERVAL = 0.5 -- atualização dos textos que mudam sozinhos (tempo, velocidade)

local ADMIN_ATTRIBUTE = "IsAdmin"
local ROLE_ATTRIBUTE = "AdminRole"
local FLY_ATTRIBUTE = "AdminFly"

local TABS = {
	{ Id = "Me", Text = "Eu" },
	{ Id = "Players", Text = "Jogadores" },
	{ Id = "Match", Text = "Partida" },
	{ Id = "Events", Text = "Eventos" },
	{ Id = "Commands", Text = "Comandos" },
}

-- Atalhos prontos dos botões (valores de ferramenta de admin, não de balanceamento).
local SPEED_PRESETS = { 16, 32, 50, 100, 200 }
local JUMP_PRESETS = { 50, 100, 150, 300 }
-- O servidor entende "1m", "1b", "1t" e "1e15" (mesmo leitor de números do DebugService).
local COIN_PRESETS = {
	{ Text = "+1M", Arg = "1m" },
	{ Text = "+1B", Arg = "1b" },
	{ Text = "+1T", Arg = "1t" },
	{ Text = "+1Qa", Arg = "1e15" },
}
local TOKEN_PRESETS = {
	{ Text = "+10", Arg = "10" },
	{ Text = "+100", Arg = "100" },
	{ Text = "+1.000", Arg = "1000" },
	{ Text = "-100", Arg = "-100" },
}
local SUPREME_PRESETS = { 0, 0.25, 0.5, 0.75, 0.99, 1 }
local BAN_DURATIONS = {
	{ Value = "30m", Text = "30 min" },
	{ Value = "2h", Text = "2 horas" },
	{ Value = "1d", Text = "1 dia" },
	{ Value = "7d", Text = "7 dias" },
	{ Value = "perm", Text = "Para sempre" },
}
local EVENT_MINUTE_PRESETS = { 5, 15, 30, 60, 120 }
local REASON_MAX_LENGTH = 200

-- Cores das etiquetas (as mesmas do chat: ChatTagController).
local OWNER_COLOR = Color3.fromRGB(255, 90, 90)
local ADMIN_COLOR = Color3.fromRGB(77, 195, 255)

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local lifeTrove = Trove.new() -- conexões que vivem o jogo todo
local toggleButton = nil
local window = nil
local ui = {} -- peças do painel
local currentTab = "Me"
local busy = {} -- [nome do comando] = true enquanto o servidor responde

local selectedTarget = nil -- UserId (número) do jogador escolhido, ou "all" (todos)
local playersDirty = true -- a lista de jogadores precisa ser remontada
local playerRows = {} -- [UserId ou "all"] = botão da linha
local thumbCache = {} -- [UserId] = imagem do rosto
local playerConnections = {} -- [Player] = {conexões dos atributos dele}
local leavingPlayers = setmetatable({}, { __mode = "k" }) -- jogadores saindo (fora da lista)

local banDuration = "1d"
local selectedEvent = nil -- chave de Admins.Events
local eventMinutes = "30"
local confirmAction = nil -- função que roda se o admin confirmar

-------------------------------------------------------------------------------
-- Ajudantes gerais
-------------------------------------------------------------------------------

local function isAdmin()
	return LocalPlayer:GetAttribute(ADMIN_ATTRIBUTE) == true
end

local function inMatch()
	return workspace:GetAttribute("Role") == "Match"
end

-- Tira espaços do começo e do fim.
local function trim(text)
	text = string.gsub(tostring(text or ""), "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	return text
end

-- Mapa da partida atual (ou nil no lobby / carregando).
local function getMap()
	local match = StateController.Get("Match")
	local mapId = type(match) == "table" and match.MapId or nil
	local mapDef = type(mapId) == "string" and Maps[mapId] or nil
	if type(mapDef) == "table" and mapDef.Act ~= nil then
		return mapDef
	end
	return nil
end

-- true se alguma ação de Config.Keybinds usa esta tecla (não roubamos a tecla do jogador).
local function isKeyUsedByAction(keyCode)
	for _, action in ipairs(Keybinds.Actions) do
		if StateController.GetKeybind(action.Id) == keyCode then
			return true
		end
	end
	return false
end

-- "Owner", "Admin" ou nil, pelo atributo que o servidor grava.
local function getRole(player)
	if player:GetAttribute(ADMIN_ATTRIBUTE) ~= true then
		return nil
	end
	return if player:GetAttribute(ROLE_ATTRIBUTE) == "Owner" then "Owner" else "Admin"
end

-- Como digitar um comando no chat: ":coins <jogador> <quantia>".
local function commandSyntax(command)
	local parts = { (Admins.ChatPrefix or ":") .. command.Name }
	for _, arg in ipairs(command.Args or {}) do
		if arg.Optional then
			table.insert(parts, "[" .. arg.Name .. "]")
		else
			table.insert(parts, "<" .. arg.Name .. ">")
		end
	end
	return table.concat(parts, " ")
end

-- Eventos na ordem do Config (EventOrder), com os que faltarem no fim.
local function getEventKeys()
	local keys, seen = {}, {}
	for _, key in ipairs(Admins.EventOrder or {}) do
		if type(Admins.Events) == "table" and Admins.Events[key] and not seen[key] then
			seen[key] = true
			table.insert(keys, key)
		end
	end
	local rest = {}
	for key in pairs(Admins.Events or {}) do
		if not seen[key] then
			table.insert(rest, key)
		end
	end
	table.sort(rest)
	for _, key in ipairs(rest) do
		table.insert(keys, key)
	end
	return keys
end

-------------------------------------------------------------------------------
-- Rodar comandos no servidor
-------------------------------------------------------------------------------

-- Pede ao servidor para rodar um comando de admin e mostra a resposta num aviso.
-- args = lista de valores (viram texto). Devolve ok, mensagem.
local function runCommand(name, args, button)
	if busy[name] then
		NotifyController.Show("Espere o comando anterior terminar.", "warning", 2)
		return false, nil
	end
	busy[name] = true

	local textArgs = {}
	for _, value in ipairs(args or {}) do
		table.insert(textArgs, tostring(value))
	end
	local ok, message = Net.Request("AdminCommand", name, textArgs)
	busy[name] = nil

	local text = if type(message) == "string" and message ~= "" then message elseif ok then "Pronto!" else "Não deu certo."
	NotifyController.Show(text, if ok then "success" else "error", if ok then 4 else 5)
	if ok then
		UIKit.PlaySound("Purchase")
		if button and button.Parent then
			UIKit.Pop(button, 0.12)
		end
	end
	return ok, message
end

-------------------------------------------------------------------------------
-- Peças visuais
-------------------------------------------------------------------------------

-- Cartão de seção com título, texto de ajuda e uma área para os botões.
-- Devolve (cartão, corpo, legenda).
local function makeSection(parent, title, subtitle, color, layoutOrder)
	local card = UIKit.New("Frame", {
		Name = "Section",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		LayoutOrder = layoutOrder,
		Parent = parent,
	})
	UIKit.Corner(card, 14)
	UIKit.Stroke(card, 2, UIKit.Darken(color, 0.35))
	UIKit.Padding(card, { Top = 8, Bottom = 12, Left = 12, Right = 12 })
	local layout = UIKit.List(card, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	local titleLabel = UIKit.Label({
		Name = "Title",
		Text = title,
		Title = true,
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 26),
		Color = UIKit.Lighten(color, 0.15),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Parent = card,
	})
	local subtitleLabel = UIKit.Label({
		Name = "Subtitle",
		Text = subtitle or "",
		TextSize = 14,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Visible = subtitle ~= nil and subtitle ~= "",
		Parent = card,
	})
	local body = UIKit.New("Frame", {
		Name = "Body",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = card,
	})
	local bodyLayout = UIKit.List(body, GRID_PADDING)
	bodyLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	return card, body, subtitleLabel, titleLabel
end

-- Grade de botões (columns por linha).
local function makeGrid(parent, columns, layoutOrder, height)
	local grid = UIKit.New("Frame", {
		Name = "Grid",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder or 0,
		Parent = parent,
	})
	UIKit.Grid(grid, UDim2.new(1 / columns, -GRID_PADDING, 0, height or BUTTON_HEIGHT), GRID_PADDING)
	return grid
end

-- Botão padrão do painel.
local function makeButton(parent, text, color, layoutOrder, onClick)
	return UIKit.Button({
		Name = "Button",
		Text = text,
		Color = color,
		TextSize = 18,
		LayoutOrder = layoutOrder or 0,
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		Parent = parent,
	}, onClick)
end

-- Texto simples de uma linha dentro de uma seção.
local function makeInfo(parent, text, layoutOrder, color)
	return UIKit.Label({
		Name = "Info",
		Text = text,
		TextSize = 16,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Color = color or Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = layoutOrder or 0,
		Parent = parent,
	})
end

-- Caixa de texto no estilo do jogo.
local function makeTextBox(parent, placeholder, props)
	props = props or {}
	local box = UIKit.New("TextBox", {
		Name = props.Name or "Box",
		Text = "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.TextDim,
		ClearTextOnFocus = false,
		TextSize = 18,
		TextWrapped = props.MultiLine == true,
		MultiLine = props.MultiLine == true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = if props.MultiLine then Enum.TextYAlignment.Top else Enum.TextYAlignment.Center,
		BackgroundColor3 = Theme.PanelDark,
		Size = props.Size or UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		Position = props.Position or UDim2.new(),
		LayoutOrder = props.LayoutOrder or 0,
		Parent = parent,
	})
	UIKit.Corner(box, 10)
	UIKit.Stroke(box, 2, UIKit.Darken(props.Color or Theme.Accent2, 0.3))
	UIKit.Padding(box, { Top = if props.MultiLine then 8 else 0, Bottom = 0, Left = 12, Right = 12 })
	-- Limite de letras (corta o que passar).
	if props.MaxLength then
		box:GetPropertyChangedSignal("Text"):Connect(function()
			if utf8.len(box.Text) and utf8.len(box.Text) > props.MaxLength then
				local cut = utf8.offset(box.Text, props.MaxLength + 1)
				if cut then
					box.Text = string.sub(box.Text, 1, cut - 1)
				end
			end
		end)
	end
	return box
end

-- Caixa de texto + botão na mesma linha. onSubmit(texto) roda no botão ou no Enter.
local function makeInputRow(parent, placeholder, buttonText, color, layoutOrder, onSubmit)
	local row = UIKit.New("Frame", {
		Name = "InputRow",
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder or 0,
		Parent = parent,
	})
	local box = makeTextBox(row, placeholder, { Size = UDim2.new(1, -200, 1, 0), Color = color })
	local button
	local function submit()
		local text = trim(box.Text)
		if text == "" then
			NotifyController.Show("Digite um valor primeiro.", "warning", 3)
			return
		end
		onSubmit(text, button)
	end
	button = UIKit.Button({
		Name = "Run",
		Text = buttonText,
		Color = color,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 190, 1, 0),
		TextSize = 18,
		Parent = row,
	}, submit)
	-- Enter na caixa de texto também envia.
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			task.spawn(submit)
		end
	end)
	return row, box, button
end

-- Deixa um botão com cara de "escolhido" (colorido) ou "não escolhido" (apagado).
local function setSelected(button, selected, color)
	local target = if selected then (color or Theme.Accent) else Theme.PanelLight
	if button.BackgroundColor3 ~= target then
		button.BackgroundColor3 = target
	end
	button.TextColor3 = if selected then Theme.Text else Theme.TextDim
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = if selected then 4 else 2.5
	end
end

-- Liga/desliga um botão (desligado fica cinza e "balança" ao clicar).
local function setEnabled(button, enabled)
	button:SetAttribute("Disabled", not enabled)
end

-------------------------------------------------------------------------------
-- Confirmação (expulsar, banir, aviso global, concluir ato...)
-------------------------------------------------------------------------------

local function hideConfirm()
	confirmAction = nil
	if ui.Confirm then
		ui.Confirm.Visible = false
	end
end

-- Mostra a pergunta por cima do painel. onConfirm roda só se o admin apertar "Confirmar".
local function askConfirm(title, message, confirmText, onConfirm)
	if not ui.Confirm then
		return
	end
	confirmAction = onConfirm
	ui.ConfirmTitle.Text = title
	ui.ConfirmMessage.Text = message
	ui.ConfirmButton.Text = confirmText
	ui.Confirm.Visible = true
	UIKit.Pop(ui.ConfirmCard, 0.1)
	-- No controle, começa no "Cancelar" (mais seguro).
	if string.match(UserInputService:GetLastInputType().Name, "^Gamepad") then
		task.defer(function()
			pcall(function()
				GuiService.SelectedObject = ui.ConfirmCancel
			end)
		end)
	end
end

local function buildConfirm(frame)
	local overlay = UIKit.New("Frame", {
		Name = "Confirm",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Backdrop,
		BackgroundTransparency = 0.3,
		Active = true, -- segura os cliques (os botões de trás não recebem)
		Visible = false,
		ZIndex = 20,
		-- No controle, a seleção não sai da pergunta.
		SelectionGroup = true,
		SelectionBehaviorUp = Enum.SelectionBehavior.Stop,
		SelectionBehaviorDown = Enum.SelectionBehavior.Stop,
		SelectionBehaviorLeft = Enum.SelectionBehavior.Stop,
		SelectionBehaviorRight = Enum.SelectionBehavior.Stop,
		Parent = frame,
	})
	UIKit.Corner(overlay, 20)

	local card = UIKit.New("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.8, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.PanelDark,
		Parent = overlay,
	})
	UIKit.Corner(card, 16)
	UIKit.Stroke(card, 3, Theme.Danger)
	UIKit.Padding(card, 16)
	UIKit.New("UIScale", { Name = "UIKitScale", Parent = card }):SetAttribute("Rest", 1)
	UIKit.List(card, 12)

	ui.ConfirmTitle = UIKit.Label({
		Name = "Title",
		Text = "",
		Title = true,
		TextSize = 26,
		Size = UDim2.new(1, 0, 0, 32),
		Color = Theme.Danger,
		LayoutOrder = 1,
		Parent = card,
	})
	ui.ConfirmMessage = UIKit.Label({
		Name = "Message",
		Text = "",
		TextSize = 18,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Color = Theme.Text,
		LayoutOrder = 2,
		Parent = card,
	})
	local row = UIKit.New("Frame", {
		Name = "Buttons",
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = card,
	})
	local rowLayout = UIKit.List(row, 14, Enum.FillDirection.Horizontal)
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	ui.ConfirmButton = UIKit.Button({
		Name = "Yes",
		Text = "Confirmar",
		Color = Theme.Danger,
		Size = UDim2.new(0.45, 0, 1, 0),
		LayoutOrder = 1,
		TextSize = 20,
		Parent = row,
	}, function()
		local action = confirmAction
		hideConfirm()
		if action then
			action()
		end
	end)
	ui.ConfirmCancel = UIKit.Button({
		Name = "No",
		Text = "Cancelar",
		Color = Theme.PanelLight,
		Size = UDim2.new(0.45, 0, 1, 0),
		LayoutOrder = 2,
		TextSize = 20,
		Parent = row,
	}, hideConfirm)

	ui.Confirm = overlay
	ui.ConfirmCard = card
end

-------------------------------------------------------------------------------
-- Aba "Eu"
-------------------------------------------------------------------------------

-- Lê um atributo numérico do jogador; se não existir (ou não for número válido),
-- devolve o valor padrão. (value == value é falso só para NaN, "não é número".)
local function readNumberAttribute(name, default)
	local value = LocalPlayer:GetAttribute(name)
	if type(value) == "number" and value == value then
		return value
	end
	return default
end

-- Velocidade de andar e força do pulo atuais.
-- O servidor grava "AdminWalkSpeed" / "AdminJumpPower" só enquanto estão mudados;
-- sem o atributo, vale o valor normal do jogo.
local function getMySpeeds()
	local speed = readNumberAttribute("AdminWalkSpeed", GameConfig.WalkSpeed)
	local jump = readNumberAttribute("AdminJumpPower", StarterPlayer.CharacterJumpPower)
	return speed, jump
end

local function refreshMe()
	if not ui.FlyButton then
		return
	end
	local flying = LocalPlayer:GetAttribute(FLY_ATTRIBUTE) == true
	ui.FlyStatus.Text = if flying then "Voo: LIGADO" else "Voo: desligado"
	ui.FlyStatus.TextColor3 = if flying then Theme.Success else Theme.TextDim
	ui.FlyButton.Text = if flying then "Parar de voar" else "Voar"
	ui.FlyButton.BackgroundColor3 = if flying then Theme.Danger else Theme.Success

	local speed, jump = getMySpeeds()
	ui.SpeedInfo.Text = ("Agora: %s  (normal: %s)"):format(
		NumberFormat.Abbrev(speed, 1),
		NumberFormat.Abbrev(GameConfig.WalkSpeed, 1)
	)
	ui.JumpInfo.Text = ("Agora: %s  (normal: %s)"):format(
		if jump then NumberFormat.Abbrev(jump, 1) else "-",
		NumberFormat.Abbrev(StarterPlayer.CharacterJumpPower, 1)
	)
end

local function buildMePage(page)
	-- Voo.
	local _, flyBody = makeSection(
		page,
		"Voo",
		"PC: WASD move, Espaço sobe, Ctrl ou Q desce, Shift acelera. Controle: A sobe, L2 desce. "
			.. "Celular: olhe para cima ou para baixo enquanto anda. No chat: :fly",
		Theme.Info,
		1
	)
	ui.FlyStatus = makeInfo(flyBody, "Voo: desligado", 1, Theme.TextDim)
	ui.FlyButton = makeButton(flyBody, "Voar", Theme.Success, 2, function(button)
		runCommand("fly", {}, button)
		task.delay(0.3, refreshMe)
	end)

	-- Velocidade.
	local _, speedBody = makeSection(page, "Velocidade", "De 1 a 200. No chat: :speed 50", Theme.Accent2, 2)
	ui.SpeedInfo = makeInfo(speedBody, "", 1)
	local speedGrid = makeGrid(speedBody, #SPEED_PRESETS, 2)
	for index, value in ipairs(SPEED_PRESETS) do
		local text = if value == GameConfig.WalkSpeed then value .. " (normal)" else tostring(value)
		makeButton(speedGrid, text, Theme.Accent2, index, function(button)
			runCommand("speed", { value }, button)
			task.delay(0.4, refreshMe)
		end)
	end
	makeInputRow(speedBody, "Outra velocidade (1 a 200)", "Mudar velocidade", Theme.Accent2, 3, function(text, button)
		runCommand("speed", { text }, button)
		task.delay(0.4, refreshMe)
	end)

	-- Pulo.
	local _, jumpBody = makeSection(page, "Pulo", "De 0 a 300. No chat: :jump 100", Theme.Accent, 3)
	ui.JumpInfo = makeInfo(jumpBody, "", 1)
	local jumpGrid = makeGrid(jumpBody, #JUMP_PRESETS, 2)
	for index, value in ipairs(JUMP_PRESETS) do
		local text = if value == StarterPlayer.CharacterJumpPower then value .. " (normal)" else tostring(value)
		makeButton(jumpGrid, text, Theme.Accent, index, function(button)
			runCommand("jump", { value }, button)
			task.delay(0.4, refreshMe)
		end)
	end
	makeInputRow(jumpBody, "Outra força de pulo (0 a 300)", "Mudar pulo", Theme.Accent, 3, function(text, button)
		runCommand("jump", { text }, button)
		task.delay(0.4, refreshMe)
	end)

	-- Personagem.
	local _, charBody = makeSection(page, "Personagem", "Renasce no ponto de nascimento. No chat: :respawn", Theme.Warning, 4)
	local respawn = makeButton(charBody, "Renascer", Theme.Warning, 1, function(button)
		runCommand("respawn", {}, button)
	end)
	respawn.TextColor3 = Theme.TextDark
end

-------------------------------------------------------------------------------
-- Aba "Jogadores"
-------------------------------------------------------------------------------

-- Jogador escolhido (ou nil). Para "Todos", devolve nil e isAll = true.
local function getSelectedPlayer()
	if selectedTarget == "all" then
		return nil, true
	end
	if type(selectedTarget) == "number" then
		return Players:GetPlayerByUserId(selectedTarget), false
	end
	return nil, false
end

-- Texto que vai para o servidor como <jogador>: o UserId (não tem como confundir nomes).
local function getTargetArg()
	local player, isAll = getSelectedPlayer()
	if isAll then
		return "all"
	end
	if player then
		return tostring(player.UserId)
	end
	return nil
end

-- Nome para mostrar ("Fulano (@fulano)" ou "todos os jogadores").
local function getTargetName()
	local player, isAll = getSelectedPlayer()
	if isAll then
		return "todos os jogadores"
	end
	if player then
		if player.DisplayName ~= player.Name then
			return player.DisplayName .. " (@" .. player.Name .. ")"
		end
		return player.Name
	end
	return "?"
end

-- Roda um comando que precisa do jogador escolhido (o <jogador> vai primeiro).
local function runOnTarget(name, extraArgs, button)
	local target = getTargetArg()
	if not target then
		NotifyController.Show("Escolha um jogador na lista primeiro.", "warning", 3)
		return
	end
	local args = { target }
	for _, value in ipairs(extraArgs or {}) do
		table.insert(args, value)
	end
	runCommand(name, args, button)
end

-- Carrega a foto do rosto de um jogador (sem travar a tela; pode falhar sem problema).
local function loadThumbnail(userId, image)
	if thumbCache[userId] then
		image.Image = thumbCache[userId]
		return
	end
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		end)
		if ok and type(content) == "string" then
			thumbCache[userId] = content
			if image.Parent then
				image.Image = content
			end
		end
	end)
end

local refreshPlayerActions -- declarada aqui, definida mais abaixo

-- Destaca a linha escolhida.
local function refreshPlayerSelection()
	for key, row in pairs(playerRows) do
		local color = Theme.Accent
		if key == "all" then
			color = Theme.Warning
		end
		setSelected(row, key == selectedTarget, color)
	end
end

-- Monta de novo a lista de jogadores (quando alguém entra, sai ou vira admin).
local function rebuildPlayerList()
	if not ui.PlayerList then
		return
	end
	playersDirty = false
	for _, row in pairs(playerRows) do
		row:Destroy()
	end
	table.clear(playerRows)

	-- Ordem: você, depois os admins, depois o resto (por nome).
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if not leavingPlayers[player] then
			table.insert(list, player)
		end
	end
	table.sort(list, function(a, b)
		local rankA = if a == LocalPlayer then 0 elseif getRole(a) then 1 else 2
		local rankB = if b == LocalPlayer then 0 elseif getRole(b) then 1 else 2
		if rankA ~= rankB then
			return rankA < rankB
		end
		return string.lower(a.DisplayName) < string.lower(b.DisplayName)
	end)

	-- "Todos": para dar moedas/tokens ou trazer todo mundo de uma vez.
	local allRow = UIKit.Button({
		Name = "All",
		Text = "Todos os jogadores",
		Color = Theme.PanelLight,
		TextSize = 18,
		LayoutOrder = 0,
		Parent = ui.PlayerList,
	}, function()
		selectedTarget = "all"
		refreshPlayerSelection()
		refreshPlayerActions()
	end)
	playerRows.all = allRow

	for index, player in ipairs(list) do
		local role = getRole(player)
		local tag = ""
		if player == LocalPlayer then
			tag = " • VOCÊ"
		end
		if role == "Owner" then
			tag ..= " • DONO"
		elseif role == "Admin" then
			tag ..= " • ADMIN"
		end
		local name = if player.DisplayName ~= player.Name
			then player.DisplayName .. " (@" .. player.Name .. ")"
			else player.Name
		local userId = player.UserId
		local row = UIKit.Button({
			Name = "Player_" .. userId,
			Text = name .. tag,
			Color = Theme.PanelLight,
			TextSize = 17,
			LayoutOrder = index,
			Parent = ui.PlayerList,
		}, function()
			selectedTarget = userId
			refreshPlayerSelection()
			refreshPlayerActions()
		end)
		row.TextXAlignment = Enum.TextXAlignment.Left
		-- Espaço à esquerda para a foto.
		local padding = row:FindFirstChildOfClass("UIPadding")
		if padding then
			padding.PaddingLeft = UDim.new(0, 52)
		end
		local photo = UIKit.New("ImageLabel", {
			Name = "Photo",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, -44, 0.5, 0),
			Size = UDim2.fromOffset(36, 36),
			BackgroundColor3 = Theme.PanelDark,
			Image = "",
			Parent = row,
		})
		UIKit.Corner(photo, UDim.new(1, 0))
		if role then
			UIKit.Stroke(photo, 2, if role == "Owner" then OWNER_COLOR else ADMIN_COLOR)
		end
		loadThumbnail(userId, photo)
		playerRows[userId] = row
	end

	ui.PlayersTitle.Text = ("Jogadores no servidor (%d)"):format(#list)

	-- O escolhido saiu do servidor: limpa a escolha.
	if type(selectedTarget) == "number" and not Players:GetPlayerByUserId(selectedTarget) then
		selectedTarget = nil
	end
	refreshPlayerSelection()
	refreshPlayerActions()
end

-- Atualiza a seção de ações conforme o jogador escolhido.
function refreshPlayerActions()
	if not ui.ActionsCard then
		return
	end
	local player, isAll = getSelectedPlayer()
	local hasTarget = player ~= nil or isAll
	ui.ActionsCard.Visible = hasTarget
	ui.PickHint.Visible = not hasTarget
	if not hasTarget then
		return
	end

	ui.ActionsTitle.Text = "Ações: " .. getTargetName()
	local match = inMatch()
	local mapDef = getMap()

	-- "Ir até" não faz sentido para "todos".
	setEnabled(ui.GoToButton, not isAll and player ~= LocalPlayer)
	setEnabled(ui.BringButton, isAll or player ~= LocalPlayer)
	setEnabled(ui.IngredientsButton, match and mapDef ~= nil and mapDef.HasRecipes == true)
	ui.CoinsSection.Visible = match
	ui.CoinsLobbyNote.Visible = not match

	-- Ninguém expulsa/bane admin, o dono, a si mesmo ou "todos" (o servidor também confere).
	local protected = isAll or player == LocalPlayer or (player ~= nil and getRole(player) ~= nil)
	setEnabled(ui.KickButton, not protected)
	setEnabled(ui.BanButton, not protected)
	if isAll then
		ui.ModerationNote.Text = "Expulsar e banir só funcionam com UM jogador (nunca \"todos\")."
	elseif player == LocalPlayer then
		ui.ModerationNote.Text = "Você não pode expulsar nem banir a si mesmo."
	elseif protected then
		ui.ModerationNote.Text = "Admins e o dono do jogo não podem ser expulsos nem banidos."
	else
		ui.ModerationNote.Text = "Expulsar: sai só deste servidor. Banir: não entra mais no jogo pelo tempo escolhido."
	end
	ui.ModerationNote.TextColor3 = if protected then Theme.Warning else Theme.TextDim
end

local function refreshBanDurations()
	for value, button in pairs(ui.BanDurationButtons or {}) do
		setSelected(button, value == banDuration, Theme.Danger)
	end
end

-- Pergunta antes de expulsar.
local function confirmKick()
	local player = getSelectedPlayer()
	if not player then
		NotifyController.Show("Escolha UM jogador na lista primeiro.", "warning", 3)
		return
	end
	local reason = trim(ui.ReasonBox.Text)
	local userId = player.UserId
	local displayName = getTargetName()
	local message = "Expulsar " .. displayName .. " deste servidor?"
	if reason ~= "" then
		message ..= "\nMotivo: " .. reason
	end
	askConfirm("Expulsar jogador?", message, "Sim, expulsar", function()
		local args = { tostring(userId) }
		if reason ~= "" then
			table.insert(args, reason)
		end
		local ok = runCommand("kick", args, ui.KickButton)
		if ok then
			ui.ReasonBox.Text = ""
		end
	end)
end

-- Pergunta antes de banir.
local function confirmBan()
	local player = getSelectedPlayer()
	if not player then
		NotifyController.Show("Escolha UM jogador na lista primeiro.", "warning", 3)
		return
	end
	local reason = trim(ui.ReasonBox.Text)
	local userId = player.UserId
	local duration = banDuration
	local durationText = duration
	for _, option in ipairs(BAN_DURATIONS) do
		if option.Value == duration then
			durationText = string.lower(option.Text)
		end
	end
	-- "por 7 dias", mas "para sempre" (sem o "por" na frente).
	local durationPhrase = if duration == "perm" then durationText else "por " .. durationText
	local message = "Banir " .. getTargetName() .. " do jogo todo " .. durationPhrase .. "?"
	if reason ~= "" then
		message ..= "\nMotivo: " .. reason
	end
	askConfirm("Banir jogador?", message, "Sim, banir", function()
		local args = { tostring(userId), duration }
		if reason ~= "" then
			table.insert(args, reason)
		end
		local ok = runCommand("ban", args, ui.BanButton)
		if ok then
			ui.ReasonBox.Text = ""
		end
	end)
end

local function buildPlayersPage(page)
	-- Lista de jogadores (2 por linha).
	local _, listBody, _, listTitle = makeSection(
		page,
		"Jogadores no servidor",
		"Toque em um jogador para ver as ações. Os comandos usam o UserId, então nomes parecidos não se confundem.",
		Theme.Info,
		1
	)
	ui.PlayersTitle = listTitle
	ui.PlayerList = makeGrid(listBody, 2, 1, PLAYER_ROW_HEIGHT)

	ui.PickHint = makeInfo(page, "Escolha um jogador na lista acima.", 2, Theme.TextDim)

	-- Ações do jogador escolhido.
	local actionsCard, actionsBody, _, actionsTitle = makeSection(page, "Ações", nil, Theme.Accent, 3)
	ui.ActionsCard = actionsCard
	ui.ActionsTitle = actionsTitle

	local moveGrid = makeGrid(actionsBody, 3, 1)
	ui.GoToButton = makeButton(moveGrid, "Ir até", Theme.Info, 1, function(button)
		runOnTarget("tp", {}, button)
	end)
	ui.BringButton = makeButton(moveGrid, "Trazer", Theme.Info, 2, function(button)
		runOnTarget("bring", {}, button)
	end)
	makeButton(moveGrid, "Renascer", Theme.Warning, 3, function(button)
		runOnTarget("respawn", {}, button)
	end).TextColor3 = Theme.TextDark
	makeButton(moveGrid, "Liberar mapas", Theme.Accent2, 4, function(button)
		runOnTarget("unlockall", {}, button)
	end)
	ui.IngredientsButton = makeButton(moveGrid, "+5 ingredientes", Theme.Success, 5, function(button)
		runOnTarget("ingredients", {}, button)
	end)

	-- Moedas (só na partida).
	local coinsSection = UIKit.New("Frame", {
		Name = "Coins",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = actionsBody,
	})
	UIKit.List(coinsSection, GRID_PADDING).HorizontalAlignment = Enum.HorizontalAlignment.Left
	makeInfo(coinsSection, "Moedas (aceita 1000, 10k, 2,5m, 1b, 1e9...)", 1, Theme.Coin)
	makeInputRow(coinsSection, "Quantia de moedas", "Dar moedas", Theme.Success, 2, function(text, button)
		runOnTarget("coins", { text }, button)
	end)
	local coinGrid = makeGrid(coinsSection, #COIN_PRESETS, 3)
	for index, preset in ipairs(COIN_PRESETS) do
		makeButton(coinGrid, preset.Text, Theme.Coin, index, function(button)
			runOnTarget("coins", { preset.Arg }, button)
		end).TextColor3 = Theme.TextDark
	end
	ui.CoinsSection = coinsSection
	ui.CoinsLobbyNote = makeInfo(actionsBody, "Moedas só dentro de uma partida.", 3, Theme.TextDim)

	-- Tokens (salvos no perfil; lobby e partida).
	makeInfo(actionsBody, "Brainrot Tokens (número negativo tira)", 4, Theme.Rare)
	makeInputRow(actionsBody, "Tokens (ex.: 50 ou -20)", "Dar tokens", Theme.Accent, 5, function(text, button)
		runOnTarget("tokens", { text }, button)
	end)
	local tokenGrid = makeGrid(actionsBody, #TOKEN_PRESETS, 6)
	for index, preset in ipairs(TOKEN_PRESETS) do
		makeButton(tokenGrid, preset.Text, Theme.Accent, index, function(button)
			runOnTarget("tokens", { preset.Arg }, button)
		end)
	end

	-- Moderação: motivo, expulsar, duração e banir.
	makeInfo(actionsBody, "Moderação", 7, Theme.Danger).Font = Theme.TitleFont
	ui.ModerationNote = makeInfo(actionsBody, "", 8, Theme.TextDim)
	ui.ReasonBox = makeTextBox(actionsBody, "Motivo (opcional)", {
		Name = "Reason",
		LayoutOrder = 9,
		MaxLength = REASON_MAX_LENGTH,
		Color = Theme.Danger,
	})
	ui.KickButton = makeButton(actionsBody, "Expulsar do servidor", Theme.Danger, 10, confirmKick)
	makeInfo(actionsBody, "Tempo do banimento:", 11, Theme.TextDim)
	local durationGrid = makeGrid(actionsBody, #BAN_DURATIONS, 12, 40)
	ui.BanDurationButtons = {}
	for index, option in ipairs(BAN_DURATIONS) do
		local button = UIKit.Button({
			Name = option.Value,
			Text = option.Text,
			Color = Theme.PanelLight,
			TextSize = 16,
			LayoutOrder = index,
			Parent = durationGrid,
		}, function()
			banDuration = option.Value
			refreshBanDurations()
		end)
		ui.BanDurationButtons[option.Value] = button
	end
	ui.BanButton = makeButton(actionsBody, "Banir do jogo", Theme.Danger, 13, confirmBan)
	refreshBanDurations()

	-- Desbanir por UserId.
	local _, unbanBody = makeSection(
		page,
		"Desbanir",
		"Digite o UserId (o número do perfil: roblox.com/users/NUMERO/profile). No chat: :unban 123456",
		Theme.Success,
		4
	)
	makeInputRow(unbanBody, "UserId (só números)", "Desbanir", Theme.Success, 1, function(text, button)
		if not string.match(text, "^%d+$") then
			NotifyController.Show("O UserId tem só números (ex.: 1179661787).", "warning", 4)
			return
		end
		runCommand("unban", { text }, button)
	end)
end

-------------------------------------------------------------------------------
-- Aba "Partida"
-------------------------------------------------------------------------------

local function refreshMatchPage()
	if not ui.MatchLobbyNote then
		return
	end
	local match = inMatch()
	local mapDef = getMap()
	ui.MatchLobbyNote.Visible = not match
	for _, card in ipairs(ui.MatchSections) do
		card.Visible = match
	end
	ui.SupremeCard.Visible = match and mapDef ~= nil and mapDef.HasSupreme == true
	setEnabled(ui.MyIngredientsButton, match and mapDef ~= nil and mapDef.HasRecipes == true)
end

local function buildMatchPage(page)
	ui.MatchLobbyNote = makeInfo(
		page,
		"Você está no lobby: os comandos de partida (leva, gigantes, chuva de moedas, Supremo...) "
			.. "aparecem aqui dentro de uma partida.",
		0,
		Theme.Warning
	)

	-- Brainrots e moedas.
	local wavesCard, wavesBody = makeSection(
		page,
		"Brainrots",
		"Plantar leva = o mesmo que o quadro. Leva de gigantes = só brainrots gigantes, agora.",
		Theme.Success,
		1
	)
	local waveGrid = makeGrid(wavesBody, 3, 1)
	makeButton(waveGrid, "Plantar leva", Theme.Success, 1, function(button)
		runCommand("wave", {}, button)
	end)
	makeButton(waveGrid, "Leva de gigantes", Theme.Warning, 2, function(button)
		runCommand("giant", {}, button)
	end).TextColor3 = Theme.TextDark
	makeButton(waveGrid, "Chuva de moedas", Theme.Coin, 3, function(button)
		runCommand("coinrain", {}, button)
	end).TextColor3 = Theme.TextDark
	makeInputRow(
		wavesBody,
		"Moedas da chuva por jogador (opcional)",
		"Chover moedas",
		Theme.Coin,
		2,
		function(text, button)
			runCommand("coinrain", { text }, button)
		end
	)

	-- Moedas para mim / para todos.
	local coinsCard, coinsBody = makeSection(
		page,
		"Moedas",
		"Aceita 1000, 10k, 2,5m, 1b, 1e9... Para um jogador só, use a aba Jogadores.",
		Theme.Coin,
		2
	)
	makeInputRow(coinsBody, "Quantia para você", "Dar para mim", Theme.Success, 1, function(text, button)
		runCommand("coins", { "me", text }, button)
	end)
	makeInputRow(coinsBody, "Quantia para cada jogador", "Dar para todos", Theme.Accent, 2, function(text, button)
		runCommand("coins", { "all", text }, button)
	end)
	local myCoinsGrid = makeGrid(coinsBody, #COIN_PRESETS, 3)
	for index, preset in ipairs(COIN_PRESETS) do
		makeButton(myCoinsGrid, preset.Text .. " para mim", Theme.Coin, index, function(button)
			runCommand("coins", { "me", preset.Arg }, button)
		end).TextColor3 = Theme.TextDark
	end

	-- Progresso.
	local progressCard, progressBody = makeSection(
		page,
		"Progresso",
		"\"Maxar tudo\" libera todas as prateleiras. \"Concluir ato\" pede confirmação.",
		Theme.Accent2,
		3
	)
	local progressGrid = makeGrid(progressBody, 3, 1)
	makeButton(progressGrid, "Maxar tudo", Theme.Accent, 1, function(button)
		runCommand("maxall", {}, button)
	end)
	makeButton(progressGrid, "Concluir ato", Theme.Warning, 2, function(button)
		askConfirm(
			"Concluir o ato?",
			"O ato atual termina agora para o time todo (o portal ou o final aparecem).",
			"Sim, concluir",
			function()
				runCommand("nextact", {}, button)
			end
		)
	end).TextColor3 = Theme.TextDark
	ui.MyIngredientsButton = makeButton(progressGrid, "+5 ingredientes", Theme.Info, 3, function(button)
		runCommand("ingredients", {}, button)
	end)

	-- Supremo (só no Deserto).
	local supremeCard, supremeBody = makeSection(
		page,
		"Brainrot Supremo",
		"Define o progresso do Supremo. 100% começa o final do jogo!",
		Theme.Rare,
		4
	)
	local supremeGrid = makeGrid(supremeBody, #SUPREME_PRESETS, 1)
	for index, value in ipairs(SUPREME_PRESETS) do
		local text = ("%d%%"):format(math.floor(value * 100 + 0.5))
		local button
		button = makeButton(supremeGrid, text, Theme.Rare, index, function()
			if value >= 1 then
				askConfirm("Começar o final?", "Com 100% o Supremo tampa o sol e o final do jogo começa.", "Sim, 100%", function()
					runCommand("supreme", { value }, button)
				end)
				return
			end
			runCommand("supreme", { value }, button)
		end)
		button.TextColor3 = Theme.TextDark
	end

	ui.MatchSections = { wavesCard, coinsCard, progressCard }
	ui.SupremeCard = supremeCard
end

-------------------------------------------------------------------------------
-- Aba "Eventos"
-------------------------------------------------------------------------------

-- Evento global valendo agora (ou nil).
local function getActiveEvent()
	local event = StateController.Get("GlobalEvent")
	if type(event) ~= "table" then
		return nil
	end
	local endsAt = tonumber(event.EndsAt) or 0
	if endsAt <= workspace:GetServerTimeNow() then
		return nil
	end
	return event
end

local function refreshAnnounceCounter()
	if not ui.AnnounceBox then
		return
	end
	local length = utf8.len(ui.AnnounceBox.Text) or #ui.AnnounceBox.Text
	local limit = Admins.AnnounceMaxLength or 200
	ui.AnnounceCounter.Text = ("%d/%d"):format(length, limit)
	ui.AnnounceCounter.TextColor3 = if length >= limit then Theme.Warning else Theme.TextDim
end

local function refreshEventsPage()
	if not ui.EventStatus then
		return
	end
	local event = getActiveEvent()
	if event then
		local remaining = (tonumber(event.EndsAt) or 0) - workspace:GetServerTimeNow()
		ui.EventStatus.Text = ("Valendo agora: %s (termina em %s)"):format(
			tostring(event.Name or event.Key or "Evento"),
			NumberFormat.Time(remaining)
		)
		ui.EventStatus.TextColor3 = Theme.Rare
	else
		ui.EventStatus.Text = "Nenhum evento valendo agora."
		ui.EventStatus.TextColor3 = Theme.TextDim
	end
	-- "Encerrar" fica sempre ligado, mesmo sem evento neste servidor: o evento pode estar
	-- valendo em outros servidores, e se o Roblox não deixou apagar o evento salvo, o
	-- servidor pede para apertar de novo (aqui ele já foi desligado).
	setEnabled(ui.EndEventButton, true)

	for key, button in pairs(ui.EventButtons or {}) do
		setSelected(button, key == selectedEvent, Theme.Rare)
		if key == selectedEvent then
			button.TextColor3 = Theme.TextDark
		end
	end
	local def = selectedEvent and Admins.Events[selectedEvent] or nil
	if def then
		local effects = {}
		local announcements = getController("AnnouncementController")
		if announcements and type(announcements.DescribeEffects) == "function" then
			local ok, lines = pcall(announcements.DescribeEffects, def.Effects)
			if ok and type(lines) == "table" then
				effects = lines
			end
		end
		local text = tostring(def.Description or "")
		if #effects > 0 then
			text ..= "\nEfeitos: " .. table.concat(effects, ", ")
		end
		ui.EventDescription.Text = text
	else
		ui.EventDescription.Text = "Escolha um evento."
	end

	for minutes, button in pairs(ui.MinuteButtons or {}) do
		setSelected(button, tostring(minutes) == eventMinutes, Theme.Info)
	end
	ui.StartEventButton.Text = ("Começar evento (%s min)"):format(eventMinutes)
end

local function buildEventsPage(page)
	local limit = Admins.AnnounceMaxLength or 200

	-- Aviso para todos os servidores.
	local _, announceBody = makeSection(
		page,
		"Aviso para todos os servidores",
		"Aparece no topo da tela de todos os jogadores, em todos os servidores do jogo. O Roblox filtra o texto.",
		Theme.Accent,
		1
	)
	ui.AnnounceBox = makeTextBox(announceBody, "Escreva o aviso aqui...", {
		Name = "Announce",
		Size = UDim2.new(1, 0, 0, 84),
		MultiLine = true,
		MaxLength = limit,
		LayoutOrder = 1,
		Color = Theme.Accent,
	})
	ui.AnnounceCounter = makeInfo(announceBody, "0/" .. limit, 2, Theme.TextDim)
	ui.AnnounceCounter.TextXAlignment = Enum.TextXAlignment.Right
	ui.AnnounceBox:GetPropertyChangedSignal("Text"):Connect(refreshAnnounceCounter)
	makeButton(announceBody, "Enviar aviso para todos", Theme.Accent, 3, function(button)
		local text = trim(ui.AnnounceBox.Text)
		if text == "" then
			NotifyController.Show("Escreva o aviso primeiro.", "warning", 3)
			return
		end
		askConfirm(
			"Enviar aviso?",
			"Todo mundo, em todos os servidores, vai ver:\n\"" .. text .. "\"",
			"Sim, enviar",
			function()
				local ok = runCommand("announce", { text }, button)
				if ok then
					ui.AnnounceBox.Text = ""
				end
			end
		)
	end)

	-- Evento global.
	local _, eventBody = makeSection(
		page,
		"Evento global",
		"Liga um bônus para todo mundo, em todos os servidores, por alguns minutos (máximo "
			.. tostring(Admins.MaxMinutes or 120)
			.. ").",
		Theme.Rare,
		2
	)
	ui.EventStatus = makeInfo(eventBody, "", 1, Theme.TextDim)
	local eventKeys = getEventKeys()
	if selectedEvent == nil then
		selectedEvent = eventKeys[1]
	end
	local eventGrid = makeGrid(eventBody, math.max(1, math.min(#eventKeys, 4)), 2)
	ui.EventButtons = {}
	for index, key in ipairs(eventKeys) do
		local def = Admins.Events[key]
		ui.EventButtons[key] = UIKit.Button({
			Name = key,
			Text = tostring(def.Name or key),
			Color = Theme.PanelLight,
			TextSize = 17,
			LayoutOrder = index,
			Parent = eventGrid,
		}, function()
			selectedEvent = key
			refreshEventsPage()
		end)
	end
	ui.EventDescription = makeInfo(eventBody, "", 3, Theme.Text)

	makeInfo(eventBody, "Duração (minutos):", 4, Theme.TextDim)
	local maxMinutes = tonumber(Admins.MaxMinutes) or 120
	local minuteOptions = {}
	for _, minutes in ipairs(EVENT_MINUTE_PRESETS) do
		if minutes <= maxMinutes then
			table.insert(minuteOptions, minutes)
		end
	end
	local minuteGrid = makeGrid(eventBody, math.max(1, #minuteOptions), 5, 40)
	ui.MinuteButtons = {}
	for index, minutes in ipairs(minuteOptions) do
		ui.MinuteButtons[minutes] = UIKit.Button({
			Name = "Min" .. minutes,
			Text = minutes .. " min",
			Color = Theme.PanelLight,
			TextSize = 16,
			LayoutOrder = index,
			Parent = minuteGrid,
		}, function()
			eventMinutes = tostring(minutes)
			refreshEventsPage()
		end)
	end
	local _, minutesBox = makeInputRow(eventBody, "Outro tempo (1 a " .. maxMinutes .. ")", "Usar este tempo", Theme.Info, 6, function(text)
		if not tonumber(text) then
			NotifyController.Show("Digite só o número de minutos (ex.: 45).", "warning", 3)
			return
		end
		eventMinutes = text
		refreshEventsPage()
	end)
	minutesBox.Name = "Minutes"

	local actionGrid = makeGrid(eventBody, 2, 7, 48)
	ui.StartEventButton = makeButton(actionGrid, "Começar evento", Theme.Success, 1, function(button)
		if not selectedEvent then
			NotifyController.Show("Escolha um evento primeiro.", "warning", 3)
			return
		end
		runCommand("event", { selectedEvent, eventMinutes }, button)
		task.delay(0.5, refreshEventsPage)
	end)
	ui.EndEventButton = makeButton(actionGrid, "Encerrar evento", Theme.Danger, 2, function(button)
		runCommand("endevent", {}, button)
		task.delay(0.5, refreshEventsPage)
	end)
end

-------------------------------------------------------------------------------
-- Aba "Comandos"
-------------------------------------------------------------------------------

-- Lê uma linha como ":coins all 1m" e separa o comando e os argumentos.
-- Um argumento do tipo "text" (motivo, aviso) pega o resto da frase inteiro.
local function parseCommandLine(text)
	text = trim(text)
	local prefix = Admins.ChatPrefix or ":"
	if string.sub(text, 1, #prefix) == prefix then
		text = string.sub(text, #prefix + 1)
	end
	local tokens = {}
	for token in string.gmatch(text, "%S+") do
		table.insert(tokens, token)
	end
	if #tokens == 0 then
		return nil, "Digite um comando (ex.: :fly)."
	end
	local name = string.lower(tokens[1])
	local command = Admins.CommandsByName and Admins.CommandsByName[name]
	if not command then
		return nil, "Comando desconhecido: " .. name .. ". Veja a lista abaixo."
	end
	local args = {}
	local tokenIndex = 2
	for _, argDef in ipairs(command.Args or {}) do
		if tokenIndex > #tokens then
			break
		end
		if argDef.Type == "text" then
			table.insert(args, table.concat(tokens, " ", tokenIndex))
			tokenIndex = #tokens + 1
			break
		end
		table.insert(args, tokens[tokenIndex])
		tokenIndex += 1
	end
	-- Sobrou coisa: manda junto (o servidor avisa se estiver errado).
	for index = tokenIndex, #tokens do
		table.insert(args, tokens[index])
	end
	return name, args
end

local function buildCommandsPage(page)
	-- Linha de comando.
	local _, lineBody = makeSection(
		page,
		"Linha de comando",
		"Digite igual no chat (ex.: :coins all 1m). No chat do jogo também funciona, começando com \""
			.. (Admins.ChatPrefix or ":")
			.. "\".",
		Theme.Accent2,
		1
	)
	local _, lineBox = makeInputRow(lineBody, "Ex.: :speed 50", "Rodar", Theme.Accent2, 1, function(text, button)
		local name, args = parseCommandLine(text)
		if not name then
			NotifyController.Show(args, "warning", 4)
			return
		end
		local ok = runCommand(name, args, button)
		if ok then
			ui.CommandLine.Text = ""
		end
	end)
	ui.CommandLine = lineBox

	-- Lista por categoria, na ordem do Config.
	local categories = {}
	local byCategory = {}
	for _, command in ipairs(Admins.Commands or {}) do
		local category = tostring(command.Category or "Outros")
		if not byCategory[category] then
			byCategory[category] = {}
			table.insert(categories, category)
		end
		table.insert(byCategory[category], command)
	end

	for categoryIndex, category in ipairs(categories) do
		local _, body = makeSection(page, category, nil, Theme.Info, categoryIndex + 1)
		for commandIndex, command in ipairs(byCategory[category]) do
			-- Cada comando é um botão: tocar coloca o começo dele na linha de comando.
			local row = UIKit.New("TextButton", {
				Name = command.Name,
				Text = "",
				AutoButtonColor = false,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = Theme.PanelDark,
				BackgroundTransparency = 0.2,
				LayoutOrder = commandIndex,
				Selectable = true,
				Parent = body,
			})
			UIKit.Corner(row, 10)
			UIKit.Padding(row, { Top = 6, Bottom = 8, Left = 10, Right = 10 })
			local rowLayout = UIKit.List(row, 2)
			rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
			local syntax = commandSyntax(command)
			if command.Scope == "Match" then
				syntax ..= "   (só na partida)"
			end
			UIKit.Label({
				Name = "Syntax",
				Text = syntax,
				TextSize = 17,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Color = if command.Scope == "Match" then Theme.Warning else Theme.Info,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 1,
				Parent = row,
			}).Font = Theme.TitleFont
			UIKit.Label({
				Name = "Description",
				Text = tostring(command.Description or ""),
				TextSize = 15,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Color = Theme.TextDim,
				TextXAlignment = Enum.TextXAlignment.Left,
				LayoutOrder = 2,
				Parent = row,
			})
			row.MouseEnter:Connect(function()
				row.BackgroundTransparency = 0
			end)
			row.MouseLeave:Connect(function()
				row.BackgroundTransparency = 0.2
			end)
			row.SelectionGained:Connect(function()
				row.BackgroundTransparency = 0
			end)
			row.SelectionLost:Connect(function()
				row.BackgroundTransparency = 0.2
			end)
			row.Activated:Connect(function()
				ui.CommandLine.Text = (Admins.ChatPrefix or ":") .. command.Name .. (if #(command.Args or {}) > 0 then " " else "")
				UIKit.PlaySound("Click")
				-- No PC já deixa pronto para digitar o resto.
				if UserInputService.KeyboardEnabled and not string.match(UserInputService:GetLastInputType().Name, "^Gamepad") then
					ui.CommandLine:CaptureFocus()
				end
				if window then
					window.Content.CanvasPosition = Vector2.zero
				end
			end)
		end
	end
end

-------------------------------------------------------------------------------
-- Janela e abas
-------------------------------------------------------------------------------

local function refreshCurrentTab()
	if currentTab == "Me" then
		refreshMe()
	elseif currentTab == "Players" then
		if playersDirty then
			rebuildPlayerList()
		else
			refreshPlayerActions()
		end
	elseif currentTab == "Match" then
		refreshMatchPage()
	elseif currentTab == "Events" then
		refreshEventsPage()
		refreshAnnounceCounter()
	end
end

local function setTab(tabId)
	if not window then
		return
	end
	currentTab = tabId
	for _, tab in ipairs(TABS) do
		setSelected(ui.TabButtons[tab.Id], tab.Id == tabId, Theme.Accent)
		ui.Pages[tab.Id].Visible = tab.Id == tabId
	end
	hideConfirm()
	window.Content.CanvasPosition = Vector2.zero
	refreshCurrentTab()
end

-- Aba anterior (-1) ou seguinte (+1), para o LB/RB do controle.
local function cycleTab(direction)
	local index = 1
	for i, tab in ipairs(TABS) do
		if tab.Id == currentTab then
			index = i
		end
	end
	index = ((index - 1 + direction) % #TABS) + 1
	setTab(TABS[index].Id)
end

local function buildWindow()
	window = UIKit.Window(WINDOW_NAME, WINDOW_TITLE, WINDOW_SIZE)
	local frame = window.Frame

	-- Barra de abas logo abaixo do cabeçalho (fica parada; só o conteúdo rola).
	local header = frame:FindFirstChild("Header")
	local headerHeight = if header and header:IsA("GuiObject") then header.Size.Y.Offset else DEFAULT_HEADER_HEIGHT
	local tabBar = UIKit.New("Frame", {
		Name = "Tabs",
		Position = UDim2.fromOffset(CONTENT_MARGIN, headerHeight + 8),
		Size = UDim2.new(1, -CONTENT_MARGIN * 2, 0, TAB_BAR_HEIGHT),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = frame,
	})
	local tabLayout = UIKit.List(tabBar, TAB_GAP, Enum.FillDirection.Horizontal)
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	ui.TabButtons = {}
	for index, tab in ipairs(TABS) do
		ui.TabButtons[tab.Id] = UIKit.Button({
			Name = tab.Id,
			Text = tab.Text,
			Color = Theme.PanelLight,
			Size = UDim2.new(1 / #TABS, -TAB_GAP, 1, 0),
			TextSize = 19,
			LayoutOrder = index,
			Parent = tabBar,
		}, function()
			setTab(tab.Id)
		end)
	end

	-- O conteúdo começa depois da barra de abas.
	local contentTop = headerHeight + 8 + TAB_BAR_HEIGHT + 8
	window.Content.Position = UDim2.fromOffset(CONTENT_MARGIN, contentTop)
	window.Content.Size = UDim2.new(1, -CONTENT_MARGIN * 2, 1, -(contentTop + CONTENT_MARGIN))
	UIKit.List(window.Content, 0)

	-- Uma página por aba (só a da aba escolhida fica visível).
	ui.Pages = {}
	for index, tab in ipairs(TABS) do
		local page = UIKit.New("Frame", {
			Name = "Page_" .. tab.Id,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = index,
			Visible = false,
			Parent = window.Content,
		})
		UIKit.Padding(page, { Top = 2, Bottom = 14, Left = 2, Right = 6 })
		UIKit.List(page, 10)
		ui.Pages[tab.Id] = page
	end

	buildMePage(ui.Pages.Me)
	buildPlayersPage(ui.Pages.Players)
	buildMatchPage(ui.Pages.Match)
	buildEventsPage(ui.Pages.Events)
	buildCommandsPage(ui.Pages.Commands)
	buildConfirm(frame)

	window.OnClose:Connect(hideConfirm)
	window.OnOpen:Connect(function()
		setTab(currentTab)
	end)
	return window
end

-------------------------------------------------------------------------------
-- Botão "ADMIN"
-------------------------------------------------------------------------------

-- Posição do botão: ao lado do DEBUG quando ele aparece; senão, no meio.
local function layoutToggle()
	if not toggleButton then
		return
	end
	if workspace:GetAttribute("DebugEnabled") == true then
		toggleButton.AnchorPoint = Vector2.new(0, 0)
		toggleButton.Position = UDim2.new(0.5, TOGGLE_DEBUG_GAP, 0, TOGGLE_TOP)
	else
		toggleButton.AnchorPoint = Vector2.new(0.5, 0)
		toggleButton.Position = UDim2.new(0.5, 0, 0, TOGGLE_TOP)
	end
end

-- Mostra/esconde o botão conforme o atributo do servidor (e fecha o painel se deixou de ser admin).
local function refreshAdmin()
	local admin = isAdmin()
	if toggleButton then
		toggleButton.Visible = admin
	end
	if not admin and window and window.IsOpen() then
		window.Close()
	end
end

local function buildToggleButton()
	local screen = UIKit.GetScreen(TOGGLE_SCREEN, TOGGLE_ORDER)
	toggleButton = UIKit.Button({
		Name = "AdminToggle",
		Text = "ADMIN",
		Color = TOGGLE_COLOR,
		Size = TOGGLE_SIZE,
		TextSize = 18,
		CornerRadius = UDim.new(1, 0),
		Visible = false,
		Parent = screen,
	}, function()
		AdminPanel.Toggle()
	end)
	lifeTrove:Add(toggleButton)
	layoutToggle()
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

function AdminPanel.Open(tab)
	if not isAdmin() then
		return
	end
	if not window then
		buildWindow()
	end
	if type(tab) == "string" and ui.Pages[tab] then
		currentTab = tab
	end
	if window.IsOpen() then
		setTab(currentTab)
	else
		window.Open()
	end
end

function AdminPanel.Close()
	if window then
		window.Close()
	end
end

function AdminPanel.Toggle()
	if window and window.IsOpen() then
		AdminPanel.Close()
	else
		AdminPanel.Open()
	end
end

function AdminPanel.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function AdminPanel.Init()
	-- Nada a preparar: o botão é criado no Start (depois do UIKit).
end

function AdminPanel.Start()
	buildToggleButton()
	refreshAdmin()

	-- O servidor liga/desliga o admin (e o cargo) com atributos no jogador.
	lifeTrove:Connect(LocalPlayer:GetAttributeChangedSignal(ADMIN_ATTRIBUTE), refreshAdmin)
	lifeTrove:Connect(LocalPlayer:GetAttributeChangedSignal(ROLE_ATTRIBUTE), refreshAdmin)
	-- Voo, velocidade e pulo mudaram: atualiza a aba "Eu" se ela estiver aberta.
	local function refreshMeIfVisible()
		if AdminPanel.IsOpen() and currentTab == "Me" then
			refreshMe()
		end
	end
	for _, attributeName in ipairs({ FLY_ATTRIBUTE, "AdminWalkSpeed", "AdminJumpPower" }) do
		lifeTrove:Connect(LocalPlayer:GetAttributeChangedSignal(attributeName), refreshMeIfVisible)
	end
	lifeTrove:Connect(workspace:GetAttributeChangedSignal("DebugEnabled"), layoutToggle)

	-- Alguém entrou, saiu ou virou admin: a lista de jogadores precisa ser remontada.
	local function markPlayersDirty()
		playersDirty = true
		if AdminPanel.IsOpen() and currentTab == "Players" then
			rebuildPlayerList()
		end
	end
	local function watchPlayer(player)
		if playerConnections[player] then
			return
		end
		playerConnections[player] = {
			player:GetAttributeChangedSignal(ADMIN_ATTRIBUTE):Connect(markPlayersDirty),
			player:GetAttributeChangedSignal(ROLE_ATTRIBUTE):Connect(markPlayersDirty),
		}
	end
	for _, player in ipairs(Players:GetPlayers()) do
		watchPlayer(player)
	end
	lifeTrove:Connect(Players.PlayerAdded, function(player)
		watchPlayer(player)
		markPlayersDirty()
	end)
	lifeTrove:Connect(Players.PlayerRemoving, function(player)
		for _, connection in ipairs(playerConnections[player] or {}) do
			connection:Disconnect()
		end
		playerConnections[player] = nil
		leavingPlayers[player] = true -- ainda está em GetPlayers() neste instante
		if selectedTarget == player.UserId then
			selectedTarget = nil
		end
		markPlayersDirty()
	end)

	-- Mudanças da partida e do evento global.
	lifeTrove:Add(StateController.OnChanged("Match", function()
		if AdminPanel.IsOpen() then
			refreshCurrentTab()
		end
	end))
	lifeTrove:Add(StateController.OnChanged("GlobalEvent", function()
		if AdminPanel.IsOpen() and currentTab == "Events" then
			refreshEventsPage()
		end
	end))

	-- Textos que mudam sozinhos (tempo do evento, velocidade atual).
	local accumulator = 0
	lifeTrove:Connect(RunService.Heartbeat, function(dt)
		accumulator += dt
		if accumulator < REFRESH_INTERVAL then
			return
		end
		accumulator = 0
		if not AdminPanel.IsOpen() then
			return
		end
		if currentTab == "Events" then
			refreshEventsPage()
		elseif currentTab == "Me" then
			refreshMe()
		end
	end)

	-- Teclas: F3 abre/fecha; LB/RB do controle trocam de aba com o painel aberto.
	lifeTrove:Connect(UserInputService.InputBegan, function(input, gameProcessed)
		local keyCode = input.KeyCode
		if AdminPanel.IsOpen() and (keyCode == Enum.KeyCode.ButtonL1 or keyCode == Enum.KeyCode.ButtonR1) then
			if not (ui.Confirm and ui.Confirm.Visible) then
				cycleTab(if keyCode == Enum.KeyCode.ButtonL1 then -1 else 1)
			end
			return
		end
		if gameProcessed or keyCode ~= TOGGLE_KEY or not isAdmin() then
			return
		end
		if UserInputService:GetFocusedTextBox() or isKeyUsedByAction(TOGGLE_KEY) then
			return
		end
		AdminPanel.Toggle()
	end)
end

-- Deixa as funções do módulo funcionarem com "." e também com ":".
for name, fn in pairs(AdminPanel) do
	if type(fn) == "function" then
		AdminPanel[name] = function(first, ...)
			if first == AdminPanel then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return AdminPanel
