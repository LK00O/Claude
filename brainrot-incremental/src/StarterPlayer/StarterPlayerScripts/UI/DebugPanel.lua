-- DebugPanel (lobby e partida): painel de comandos de teste para desenvolver mais rápido.
--
-- Só aparece quando o servidor liga o atributo workspace "DebugEnabled" (no Studio,
-- com Config.Game.DebugMode = true ou com o atributo DebugMode no Workspace).
-- Mostra um botãozinho "DEBUG" no topo da tela que abre um painel com botões para
-- cada comando do DebugService:
--   coins <n>, maxall, wave, nextact, supreme <0..1>, ingredients, unlockall,
--   tokens <n>, reset e help.
-- Cada botão chama Net.Request("Debug", comando, argumento); a resposta do servidor
-- aparece no quadro "Resposta" do painel. Quem confere se pode é o servidor.
--
-- Atalho no PC: F2 abre/fecha o painel (se F2 não estiver sendo usada por outra tecla).
-- Na partida o mouse fica preso no centro: use o F2 (ou Alt para soltar o mouse).
--
-- API:
--   DebugPanel.Open() / DebugPanel.Close() / DebugPanel.IsOpen()  (extras)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maps = require(Config:WaitForChild("Maps"))
local Keybinds = require(Config:WaitForChild("Keybinds"))
local Net = require(Util:WaitForChild("Net"))
local Trove = require(Util:WaitForChild("Trove"))

local UIKit = require(script.Parent:WaitForChild("UIKit"))
local ControllersFolder = script.Parent.Parent:WaitForChild("Controllers")
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme

local DebugPanel = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

local WINDOW_NAME = "Debug"
local WINDOW_SIZE = UDim2.fromOffset(720, 600)
local SCREEN_NAME = "DebugButton"
local SCREEN_ORDER = 25 -- acima do HUD (5), abaixo das janelas (30) e dos avisos (60)

local TOGGLE_KEY = Enum.KeyCode.F2
local CONFIRM_TIME = 3 -- segundos para confirmar comandos perigosos (segundo clique)
local BUTTON_HEIGHT = 46
local GRID_PADDING = 8

-- Atalhos prontos (valores de teste, não de balanceamento).
local COIN_PRESETS = {
	{ Text = "+1M × mapa", Arg = nil }, -- sem argumento: o servidor dá 1M × CostScale do mapa
	{ Text = "+1B", Arg = 1e9 },
	{ Text = "+1T", Arg = 1e12 },
	{ Text = "+1Qa", Arg = 1e15 },
}
local TOKEN_PRESETS = {
	{ Text = "+100", Arg = 100 },
	{ Text = "+1.000", Arg = 1000 },
	{ Text = "-100", Arg = -100 },
}
local SUPREME_PRESETS = { 0, 0.25, 0.5, 0.75, 0.99, 1 }

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local lifeTrove = Trove.new() -- conexões que vivem o jogo todo
local toggleButton = nil -- o botão "DEBUG" no topo da tela
local window = nil
local ui = {} -- peças do painel
local busy = false -- true enquanto um comando está rodando no servidor

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- O servidor ligou os comandos de teste?
local function isEnabled()
	return workspace:GetAttribute("DebugEnabled") == true
end

-- "Match" (partida) ou "Lobby".
local function getRole()
	return workspace:GetAttribute("Role")
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

-- Mostra a resposta do servidor no quadro "Resposta".
local function setOutput(text, color)
	if not ui.Output then
		return
	end
	ui.Output.Text = text
	ui.Output.TextColor3 = color or Theme.Text
end

-------------------------------------------------------------------------------
-- Rodar comandos
-------------------------------------------------------------------------------

-- Pede ao servidor para rodar um comando do DebugService.
local function runCommand(command, arg, button)
	if busy then
		NotifyController.Show("Espere o comando anterior terminar.", "warning", 2)
		return
	end
	busy = true
	local argText = if arg ~= nil then " " .. tostring(arg) else ""
	setOutput("Rodando /" .. command .. argText .. "...", Theme.TextDim)

	local ok, result = Net.Request("Debug", command, arg)
	busy = false

	local text = tostring(result or "")
	if text == "" then
		text = if ok then "Pronto!" else "Não deu certo."
	end
	setOutput("/" .. command .. argText .. "\n" .. text, if ok then Theme.Success else Theme.Danger)
	UIKit.PlaySound(if ok then "Purchase" else "Error")
	if button and button.Parent then
		UIKit.Pop(button, 0.12)
	end
end

-------------------------------------------------------------------------------
-- Peças visuais
-------------------------------------------------------------------------------

-- Cartão de seção com título, texto de ajuda e uma área para os botões.
-- Devolve (cartão, corpo).
local function makeSection(parent, title, subtitle, color, layoutOrder)
	local card = UIKit.New("Frame", {
		Name = "Section_" .. title,
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

	UIKit.Label({
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
	if subtitle and subtitle ~= "" then
		UIKit.Label({
			Name = "Subtitle",
			Text = subtitle,
			TextSize = 13,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Color = Theme.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 2,
			Parent = card,
		})
	end
	local body = UIKit.New("Frame", {
		Name = "Body",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = card,
	})
	return card, body
end

-- Grade de botões dentro de um corpo de seção (columns por linha).
local function makeGrid(parent, columns, layoutOrder)
	local grid = UIKit.New("Frame", {
		Name = "Grid",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder or 0,
		Parent = parent,
	})
	UIKit.Grid(grid, UDim2.new(1 / columns, -GRID_PADDING, 0, BUTTON_HEIGHT), GRID_PADDING)
	return grid
end

-- Botão de comando. Com "confirm", o primeiro clique só pergunta "Certeza?".
-- "arg" é o argumento do comando (nil = sem argumento); se for uma função,
-- ela é chamada na hora do clique para montar o argumento.
local function makeCommandButton(parent, text, color, layoutOrder, command, arg, confirm)
	local confirmUntil = 0
	local button
	button = UIKit.Button({
		Name = command,
		Text = text,
		Color = color,
		TextSize = 18,
		LayoutOrder = layoutOrder,
		Parent = parent,
	}, function()
		if button:GetAttribute("Disabled") == true then
			return
		end
		if confirm then
			local now = os.clock()
			if now > confirmUntil then
				confirmUntil = now + CONFIRM_TIME
				button.Text = "Certeza?"
				task.delay(CONFIRM_TIME, function()
					if os.clock() >= confirmUntil and button.Parent then
						button.Text = text
					end
				end)
				return
			end
			confirmUntil = 0
			button.Text = text
		end
		local value = arg
		if type(arg) == "function" then
			value = arg()
		end
		runCommand(command, value, button)
	end)
	return button
end

-- Caixa de texto + botão (para "coins <n>" e "tokens <n>").
local function makeInputRow(parent, placeholder, buttonText, color, command, layoutOrder)
	local row = UIKit.New("Frame", {
		Name = "Input_" .. command,
		Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
		Parent = parent,
	})
	local box = UIKit.New("TextBox", {
		Name = "Box",
		Text = "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.TextDim,
		ClearTextOnFocus = false,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = Theme.PanelDark,
		Size = UDim2.new(1, -200, 1, 0),
		Parent = row,
	})
	UIKit.Corner(box, 10)
	UIKit.Stroke(box, 2, UIKit.Darken(color, 0.3))
	UIKit.Padding(box, { Top = 0, Bottom = 0, Left = 12, Right = 12 })

	local button
	local function submit()
		local text = string.gsub(box.Text, "^%s+", "")
		text = string.gsub(text, "%s+$", "")
		if text == "" then
			NotifyController.Show("Digite um número primeiro (ex.: 1000, 10k, 1e9).", "warning", 3)
			return
		end
		-- O servidor entende texto como "10k", "2,5" ou "1e6".
		runCommand(command, text, button)
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

	-- Enter na caixa de texto também roda o comando.
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			submit()
		end
	end)
	return row, box
end

-------------------------------------------------------------------------------
-- Montagem do painel
-------------------------------------------------------------------------------

local function buildWindow()
	window = UIKit.Window(WINDOW_NAME, "Painel de Testes (DEBUG)", WINDOW_SIZE)

	local holder = UIKit.New("Frame", {
		Name = "DebugContent",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = window.Content,
	})
	UIKit.Padding(holder, { Top = 4, Bottom = 14, Left = 2, Right = 6 })
	UIKit.List(holder, 10)

	-- Quadro com a resposta do servidor.
	local outputCard = UIKit.New("Frame", {
		Name = "OutputCard",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.05,
		LayoutOrder = 1,
		Parent = holder,
	})
	UIKit.Corner(outputCard, 14)
	UIKit.Stroke(outputCard, 2, Theme.Stroke)
	UIKit.Padding(outputCard, { Top = 8, Bottom = 10, Left = 12, Right = 12 })
	local outputLayout = UIKit.List(outputCard, 4)
	outputLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	UIKit.Label({
		Name = "Caption",
		Text = "Resposta do servidor",
		Title = true,
		TextSize = 18,
		Size = UDim2.new(1, 0, 0, 22),
		Color = Theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Parent = outputCard,
	})
	ui.Output = UIKit.Label({
		Name = "Output",
		Text = "Clique num comando. Dica: F2 abre/fecha este painel. No chat também dá: /help",
		TextSize = 15,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 2,
		Parent = outputCard,
	})

	-- Aviso do lobby (os comandos de partida ficam escondidos).
	ui.LobbyNote = UIKit.Label({
		Name = "LobbyNote",
		Text = "Você está no lobby: os comandos de partida (moedas, upgrades, Supremo...) aparecem dentro de uma partida.",
		TextSize = 14,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Color = Theme.Warning,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = holder,
	})

	-- Moedas: coins <n>.
	local coinsCard, coinsBody = makeSection(
		holder,
		"Moedas",
		"coins <n> — aceita 1000, 10k, 2,5m, 1e9...",
		Theme.Coin,
		3
	)
	UIKit.List(coinsBody, GRID_PADDING)
	makeInputRow(coinsBody, "Quantidade (ex.: 1e9)", "Ganhar moedas", Theme.Success, "coins", 1)
	local coinsGrid = makeGrid(coinsBody, #COIN_PRESETS, 2)
	for index, preset in ipairs(COIN_PRESETS) do
		makeCommandButton(coinsGrid, preset.Text, Theme.Coin, index, "coins", preset.Arg, false).TextColor3 = Theme.TextDark
	end

	-- Partida: maxall, wave, ingredients, nextact, reset.
	local matchCard, matchBody = makeSection(
		holder,
		"Partida",
		"Maxar tudo também libera as prateleiras. \"Concluir ato\" e \"Zerar\" pedem confirmação.",
		Theme.Accent2,
		4
	)
	local matchGrid = makeGrid(matchBody, 3)
	makeCommandButton(matchGrid, "Maxar tudo", Theme.Accent, 1, "maxall", nil, false)
	makeCommandButton(matchGrid, "Plantar leva", Theme.Success, 2, "wave", nil, false)
	ui.IngredientsButton = makeCommandButton(matchGrid, "+5 ingredientes", Theme.Info, 3, "ingredients", nil, false)
	makeCommandButton(matchGrid, "Concluir ato", Theme.Warning, 4, "nextact", nil, true).TextColor3 = Theme.TextDark
	makeCommandButton(matchGrid, "Zerar meu progresso", Theme.Danger, 5, "reset", nil, true)

	-- Supremo: supreme <0..1>.
	local supremeCard, supremeBody = makeSection(
		holder,
		"Brainrot Supremo",
		"supreme <0..1> — define o progresso (100% começa o final!).",
		Theme.Rare,
		5
	)
	local supremeGrid = makeGrid(supremeBody, #SUPREME_PRESETS)
	for index, value in ipairs(SUPREME_PRESETS) do
		local text = ("%d%%"):format(math.floor(value * 100 + 0.5))
		local button = makeCommandButton(supremeGrid, text, Theme.Rare, index, "supreme", value, value >= 1)
		button.TextColor3 = Theme.TextDark
	end

	-- Perfil: unlockall e tokens <n> (funcionam no lobby também).
	local _, profileBody = makeSection(
		holder,
		"Perfil",
		"Liberar mapas e Brainrot Tokens valem no lobby e na partida.",
		Theme.Info,
		6
	)
	UIKit.List(profileBody, GRID_PADDING)
	local profileGrid = makeGrid(profileBody, 2, 1)
	makeCommandButton(profileGrid, "Liberar todos os mapas", Theme.Info, 1, "unlockall", nil, false)
	makeCommandButton(profileGrid, "Lista de comandos", Theme.Accent2, 2, "help", nil, false)
	makeInputRow(profileBody, "Tokens (ex.: 50 ou -20)", "Dar tokens", Theme.Accent, "tokens", 2)
	local tokenGrid = makeGrid(profileBody, #TOKEN_PRESETS, 3)
	for index, preset in ipairs(TOKEN_PRESETS) do
		makeCommandButton(tokenGrid, preset.Text, Theme.Accent, index, "tokens", preset.Arg, false)
	end

	ui.MatchSections = { coinsCard, matchCard }
	ui.SupremeCard = supremeCard
	return window
end

-- Mostra/esconde as seções conforme o lugar (lobby/partida) e o mapa.
local function refreshSections()
	if not window then
		return
	end
	local inMatch = getRole() == "Match"
	local mapDef = getMap()
	for _, card in ipairs(ui.MatchSections) do
		card.Visible = inMatch
	end
	ui.SupremeCard.Visible = inMatch and mapDef ~= nil and mapDef.HasSupreme == true
	ui.LobbyNote.Visible = not inMatch
	if ui.IngredientsButton then
		ui.IngredientsButton:SetAttribute("Disabled", not (mapDef and mapDef.HasRecipes == true))
	end
end

-------------------------------------------------------------------------------
-- Botão "DEBUG"
-------------------------------------------------------------------------------

-- Mostra/esconde o botão "DEBUG" conforme o atributo do servidor.
local function refreshEnabled()
	local enabled = isEnabled()
	if toggleButton then
		toggleButton.Visible = enabled
	end
	if not enabled and window and window.IsOpen() then
		window.Close()
	end
end

local function buildToggleButton()
	local screen = UIKit.GetScreen(SCREEN_NAME, SCREEN_ORDER)
	toggleButton = UIKit.Button({
		Name = "DebugToggle",
		Text = "DEBUG",
		Color = Theme.Danger,
		AnchorPoint = Vector2.new(0.5, 0),
		-- No topo, no meio da barra do Roblox (lá não tem botões do Roblox nem do HUD).
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(104, 34),
		TextSize = 18,
		CornerRadius = UDim.new(1, 0),
		Visible = false,
		Parent = screen,
	}, function()
		DebugPanel.Toggle()
	end)
	lifeTrove:Add(toggleButton)
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

function DebugPanel.Open()
	if not isEnabled() then
		return
	end
	if not window then
		buildWindow()
	end
	refreshSections()
	window.Open()
end

function DebugPanel.Close()
	if window then
		window.Close()
	end
end

function DebugPanel.Toggle()
	if window and window.IsOpen() then
		DebugPanel.Close()
	else
		DebugPanel.Open()
	end
end

function DebugPanel.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function DebugPanel.Init()
	-- Nada a preparar: o botão é criado no Start (depois do UIKit).
end

function DebugPanel.Start()
	buildToggleButton()
	refreshEnabled()

	-- O servidor pode ligar/desligar os comandos com o jogo rodando.
	lifeTrove:Connect(workspace:GetAttributeChangedSignal("DebugEnabled"), refreshEnabled)

	-- O mapa da partida chegou/mudou: atualiza as seções do painel.
	lifeTrove:Add(StateController.OnChanged("Match", function()
		if window and window.IsOpen() then
			refreshSections()
		end
	end))

	-- Atalho F2 (teclado).
	lifeTrove:Connect(UserInputService.InputBegan, function(input, gameProcessed)
		if gameProcessed or input.KeyCode ~= TOGGLE_KEY or not isEnabled() then
			return
		end
		if UserInputService:GetFocusedTextBox() or isKeyUsedByAction(TOGGLE_KEY) then
			return
		end
		DebugPanel.Toggle()
	end)
end

-- Deixa as funções do módulo funcionarem com "." e também com ":".
for name, fn in pairs(DebugPanel) do
	if type(fn) == "function" then
		DebugPanel[name] = function(first, ...)
			if first == DebugPanel then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return DebugPanel
