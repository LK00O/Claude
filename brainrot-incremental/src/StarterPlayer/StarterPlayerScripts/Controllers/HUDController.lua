-- HUDController (só na partida): tudo que fica sempre na tela durante o jogo.
--
-- Mostra:
--   * Moedas (com animação ao ganhar/gastar) e renda por segundo.
--   * Brainrots vivos e a recarga do quadro "Plantar brainrots".
--   * Mira no centro, com hitmarker quando o servidor confirma um acerto.
--   * Missão ativa com barra de progresso (ou o tempo até a próxima missão).
--   * Painel de "Bônus ativos" (receitas, encantamento garantido, leva gigante, passes).
--   * Barra de calor da arma (Deserto) e barra do Brainrot Supremo (Deserto).
--   * Lista do time (nome e moedas de cada um).
--   * Aviso do portal com votos e botão "Votar" quando o portal está aberto.
--   * Botões: Configurações, Voltar ao lobby (com confirmação), Receitas (Deserto),
--     Colocar torreta (mapas com torretas) e Vantagens (game passes; só aparece
--     quando Config.Game.Gamepasses.Enabled = true e algum id de pass é > 0).
--
-- Como usar os botões em cada aparelho:
--   * Celular: é só tocar.
--   * PC: o mouse fica preso no centro para mirar. Aperte Alt para soltar o mouse
--     e clicar nos botões (Alt de novo, ou clicar no jogo, volta a mirar).
--     Atalho: T coloca torreta (se T não estiver sendo usada por outra tecla).
--   * Controle: o botão Select do Roblox navega pelos botões; Y coloca torreta.
--
-- O HUD só MOSTRA o estado que o servidor manda (StateController). Toda ação
-- (votar, voltar ao lobby) é um pedido ao servidor, que decide se pode.
--
-- API pública:
--   HUDController.ShowHitmarker(crit)   mostra o "X" de acerto na mira (dourado se crítico)
--   HUDController.SetVisible(visible)   mostra/esconde o HUD inteiro (extra)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local GameConfig = require(Config:WaitForChild("Game"))
local Maps = require(Config:WaitForChild("Maps"))
local RecipesConfig = require(Config:WaitForChild("Recipes"))
local StatsConfig = require(Config:WaitForChild("Stats"))
local Keybinds = require(Config:WaitForChild("Keybinds"))
local Net = require(Util:WaitForChild("Net"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))
local Formulas = require(Util:WaitForChild("Formulas"))
local Trove = require(Util:WaitForChild("Trove"))
local Gamepasses = require(Util:WaitForChild("Gamepasses"))

local Controllers = script.Parent
local UIKit = require(Controllers.Parent:WaitForChild("UI"):WaitForChild("UIKit"))
local StateController = require(Controllers:WaitForChild("StateController"))
local NotifyController = require(Controllers:WaitForChild("NotifyController"))

local Theme = UIKit.Theme
local LocalPlayer = Players.LocalPlayer

local HUDController = {}

-- Outros controllers só são carregados dentro de funções (regra anti-require-circular).
local function getController(name)
	local module = Controllers:FindFirstChild(name)
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
-- Constantes (técnicas e de layout; nada de balanceamento aqui)
-------------------------------------------------------------------------------

local SCREEN_NAME = "HUD"
local DISPLAY_ORDER = 5 -- abaixo das janelas (30) e dos avisos (60)

local SIDE_MARGIN = 16 -- distância das bordas da tela
local TOP_GAP = 10 -- espaço abaixo da barra do Roblox
local LEFT_WIDTH = 280 -- coluna da esquerda (moedas, missão, bônus)
local RIGHT_WIDTH = 268 -- coluna da direita (botões e time)
local BOTTOM_WIDTH = 500 -- faixa de baixo (portal e Supremo)
local PANEL_TRANSPARENCY = 0.18

local SUPREME_BUTTON_WIDTH = 104 -- botão "Alimentar" ao lado da barra do Supremo

local QUEST_ACTIVE_HEIGHT = 100
local QUEST_IDLE_HEIGHT = 40
local TEAM_MAX_ROWS = 8 -- limite de jogadores por partida (Config.Lobby.MaxPlayersLimit)
local TEAM_ROW_HEIGHT = 26

local COIN_LERP_SPEED = 9 -- quão rápido o número de moedas "corre" até o valor novo
local COIN_POP_INTERVAL = 0.12 -- intervalo mínimo entre "pulos" do ícone da moeda
local GAIN_HOLD_TIME = 0.9 -- tempo que o "+X" fica na tela antes de sumir
local TIMER_INTERVAL = 0.1 -- atualização dos relógios (recarga, bônus, missão)
local HITMARKER_TIME = 0.3 -- duração do hitmarker
local GLOW_SPEED = 120 -- graus por segundo do brilho girando no aviso do portal

local CURSOR_MODAL = "HUDCursor" -- "modal" usado para soltar o mouse no PC
local CURSOR_KEYS = { [Enum.KeyCode.LeftAlt] = true, [Enum.KeyCode.RightAlt] = true }
local TURRET_KEY = Enum.KeyCode.T
local TURRET_GAMEPAD_KEY = Enum.KeyCode.ButtonY

-- Os game passes vendidos na janela "Vantagens" (nome, descrição e a regra "está à venda?")
-- vêm de Shared/Util/Gamepasses, o mesmo módulo que o servidor e a loja do lobby usam.
-- Quem vende e ativa o pass é o servidor (MonetizationService, Request "BuyGamepass").
local PASS_WINDOW_SIZE = UDim2.fromOffset(580, 560)
local PASS_CARD_MIN_HEIGHT = 96 -- o cartão cresce sozinho se a descrição for longa

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local trove = Trove.new() -- conexões que vivem enquanto o HUD existe
local ui = {} -- referências para as peças da interface
local built = false
local visible = true

local currentMap = nil -- definição do mapa atual (Config.Maps[x])

local coinsReady = false
local targetCoins = 0 -- valor real de moedas (do servidor)
local displayedCoins = 0 -- valor mostrado (anima até o real)
local lastCoinsText = ""
local lastCoinPop = 0
local pendingGain = 0 -- soma dos ganhos recentes (para o "+X")
local gainSerial = 0
local spendSerial = 0

local hitSerial = 0
local cursorMode = false
local cursorClickPending = false -- clique no mundo começou no modo cursor (sai ao soltar)
local votedLocally = false -- este jogador já votou no portal atual
local voteBusy = false

local buffRows = {} -- [id] = {Frame, Label, Dot}
local confirm = nil -- janela de confirmação "Voltar ao lobby"
local passWindow = nil -- janela "Vantagens" (game passes), criada só quando abrir pela 1ª vez

-------------------------------------------------------------------------------
-- Ajudantes gerais
-------------------------------------------------------------------------------

-- Número seguro (nil, texto ou NaN viram o padrão).
local function num(value, default)
	value = tonumber(value)
	if value == nil or value ~= value then
		return default or 0
	end
	return value
end

-- Definição do mapa da partida atual (ou nil se ainda não chegou).
local function getMapDef()
	local match = StateController.Get("Match")
	local mapId = type(match) == "table" and match.MapId or nil
	local mapDef = type(mapId) == "string" and Maps[mapId] or nil
	-- "Order" também é uma chave de Maps, por isso conferimos o campo Act.
	if type(mapDef) == "table" and mapDef.Act ~= nil then
		return mapDef
	end
	return nil
end

-- Segundos restantes em texto curto: "3 s" ou "1:05".
local function shortTime(seconds)
	seconds = math.max(0, seconds)
	if seconds >= 60 then
		return NumberFormat.Time(seconds)
	end
	return tostring(math.ceil(seconds - 1e-6)) .. " s"
end

-- true se o último tipo de entrada foi teclado ou mouse.
local function isKeyboardMouse()
	local inputType = UserInputService:GetLastInputType()
	return inputType == Enum.UserInputType.Keyboard or string.match(inputType.Name, "^Mouse") ~= nil
end

-- true se o último tipo de entrada foi um controle.
local function isGamepad()
	return string.match(UserInputService:GetLastInputType().Name, "^Gamepad") ~= nil
end

-- true se alguma ação de Config.Keybinds usa esta tecla (para não roubar a tecla do jogador).
local function isKeyUsedByAction(keyCode)
	for _, action in ipairs(Keybinds.Actions) do
		if StateController.GetKeybind(action.Id) == keyCode then
			return true
		end
	end
	return false
end

-- Texto de um efeito de receita: "Dano ×2", "Tamanho dos Brainrots ×1,5".
local function effectText(effect)
	local display = StatsConfig.Display[effect.Stat]
	local name = display and display.Name or tostring(effect.Stat)
	if effect.Mode == "Add" then
		return name .. " +" .. NumberFormat.Stat(effect.Value, display and display.Format or "number")
	end
	local multiplier = Formulas.ApplyEffect(1, effect.Mode, effect.Value, 1)
	return name .. " ×" .. NumberFormat.Abbrev(multiplier)
end

-- Resumo curto de uma receita permanente: "Dano ×2".
local function recipeSummary(recipe)
	local parts = {}
	for _, effect in ipairs(recipe.Effects or {}) do
		table.insert(parts, effectText(effect))
	end
	return table.concat(parts, ", ")
end

-- Nome da receita que dá o encantamento garantido (para o painel de bônus).
local function timedEnchantName()
	for _, recipe in ipairs(RecipesConfig.Recipes or {}) do
		if recipe.Special == "EnchantAll" then
			return recipe.Name
		end
	end
	return "Encantamento garantido"
end

-------------------------------------------------------------------------------
-- Peças visuais reutilizáveis
-------------------------------------------------------------------------------

-- Painel escuro arredondado (fundo dos blocos do HUD).
local function makePanel(name, size, parent, layoutOrder)
	local frame = UIKit.New("Frame", {
		Name = name,
		Size = size,
		BackgroundColor3 = Theme.Background,
		BackgroundTransparency = PANEL_TRANSPARENCY,
		LayoutOrder = layoutOrder or 0,
		Parent = parent,
	})
	UIKit.Corner(frame, 14)
	UIKit.Stroke(frame, 2.5, Theme.Stroke)
	return frame
end

-- Texto de uma linha só (corta com "..." se não couber).
local function makeLine(props)
	local label = UIKit.Label(props)
	label.TextWrapped = false
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.TextStrokeTransparency = 0.45
	return label
end

-- Moedinha desenhada com Frames (não depende de imagem).
local function makeCoinIcon(parent, size, position, anchor)
	local coin = UIKit.New("Frame", {
		Name = "CoinIcon",
		Size = UDim2.fromOffset(size, size),
		Position = position or UDim2.new(),
		AnchorPoint = anchor or Vector2.zero,
		BackgroundColor3 = Theme.Coin,
		Parent = parent,
	})
	UIKit.Corner(coin, UDim.new(1, 0))
	UIKit.Stroke(coin, 3, UIKit.Darken(Theme.Coin, 0.5))
	local inner = UIKit.New("Frame", {
		Name = "Inner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.7, 0.7),
		BackgroundColor3 = UIKit.Lighten(Theme.Coin, 0.3),
		Parent = coin,
	})
	UIKit.Corner(inner, UDim.new(1, 0))
	UIKit.New("TextLabel", {
		Name = "Letter",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "B",
		Font = Theme.TitleFont,
		TextScaled = true,
		TextColor3 = UIKit.Darken(Theme.Coin, 0.45),
		Parent = inner,
	})
	return coin
end

-- "Pílula" com uma bolinha colorida e um texto (ex.: "Brainrots: 12").
local function makeChip(name, parent, color, layoutOrder)
	local chip = UIKit.New("Frame", {
		Name = name,
		Size = UDim2.new(0.5, -4, 1, 0),
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.15,
		LayoutOrder = layoutOrder,
		Parent = parent,
	})
	UIKit.Corner(chip, UDim.new(1, 0))
	UIKit.Stroke(chip, 2, Theme.Stroke)
	local dot = UIKit.New("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 10, 0.5, 0),
		Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = color,
		Parent = chip,
	})
	UIKit.Corner(dot, UDim.new(1, 0))
	local label = makeLine({
		Name = "Text",
		Position = UDim2.fromOffset(28, 0),
		Size = UDim2.new(1, -34, 1, 0),
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = chip,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 16, MinTextSize = 9, Parent = label })
	return chip, label, dot
end

-------------------------------------------------------------------------------
-- Ações dos botões
-------------------------------------------------------------------------------

-- Liga/desliga o "modo cursor" do PC (solta o mouse para clicar nos botões do HUD).
local function refreshHint()
	if not ui.Hint then
		return
	end
	ui.Hint.Visible = isKeyboardMouse() and UserInputService.KeyboardEnabled
	ui.Hint.Text = if cursorMode then "Alt: voltar a mirar" else "Alt: usar o mouse nos botões"
end

local function setCursorMode(on)
	on = on == true
	-- Qualquer troca (ou confirmação) do modo cancela um clique pendente antigo.
	cursorClickPending = false
	if on == cursorMode then
		return
	end
	cursorMode = on
	if on then
		UIKit.OpenModal(CURSOR_MODAL)
	else
		UIKit.CloseModal(CURSOR_MODAL)
	end
	refreshHint()
end

-- Abre as Configurações (a SettingsWindow registrou a ação "Settings").
local function openSettings()
	setCursorMode(false)
	local PromptController = getController("PromptController")
	if PromptController and PromptController.Dispatch then
		PromptController.Dispatch("Settings")
	end
end

-- Abre o Caldeirão / Livro de Receitas (a CauldronWindow registrou "Cauldron").
local function openRecipes()
	setCursorMode(false)
	local PromptController = getController("PromptController")
	if PromptController and PromptController.Dispatch then
		PromptController.Dispatch("Cauldron")
	end
end

-- Abre a janela do Brainrot Supremo (a SupremeWindow registrou "Supreme").
local function openSupreme()
	setCursorMode(false)
	local PromptController = getController("PromptController")
	if PromptController and PromptController.Dispatch then
		PromptController.Dispatch("Supreme")
	end
end

-- Entra no modo de colocar torreta (o PlacementController confere limite e mapa).
local function enterPlacement()
	if not (currentMap and currentMap.HasTurrets) then
		return
	end
	setCursorMode(false)
	local PlacementController = getController("PlacementController")
	if not PlacementController or not PlacementController.Enter then
		NotifyController.Show("O modo de torreta não está disponível agora.", "error")
		return
	end
	PlacementController.Enter()
end

-- Vota para entrar no portal (ou, no modo "Host", o dono ativa o portal).
local refreshPortal -- declarada aqui, definida mais abaixo

local function votePortal()
	if voteBusy then
		return
	end
	voteBusy = true
	setCursorMode(false)
	local ok, result = Net.Request("VotePortal")
	voteBusy = false
	if ok then
		votedLocally = true
		UIKit.PlaySound("Portal")
	else
		NotifyController.Show(tostring(result or "Não deu para votar agora."), "error")
	end
	refreshPortal()
end

-------------------------------------------------------------------------------
-- Janela de confirmação "Voltar ao lobby"
-------------------------------------------------------------------------------

local CONFIRM_TEXT = "Seu progresso nesta partida fica salvo. Depois você pode reconectar pelo lobby."

local function resetConfirm()
	if not confirm then
		return
	end
	confirm.Leaving = false
	confirm.Message.Text = CONFIRM_TEXT
	confirm.ConfirmButton.Text = "Sim, voltar"
	confirm.ConfirmButton:SetAttribute("Disabled", false)
	confirm.CancelButton:SetAttribute("Disabled", false)
end

local function ensureConfirmWindow()
	if confirm then
		return confirm
	end
	local window = UIKit.Window("ReturnToLobby", "Voltar ao lobby?", UDim2.fromOffset(500, 280))
	local content = window.Content
	local layout = UIKit.List(content, 14)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIKit.Padding(content, { Top = 8, Bottom = 8, Left = 6, Right = 6 })

	local message = UIKit.Label({
		Name = "Message",
		Text = CONFIRM_TEXT,
		Size = UDim2.new(1, 0, 0, 78),
		TextSize = 19,
		Color = Theme.TextDim,
		LayoutOrder = 1,
		Parent = content,
	})

	local row = UIKit.New("Frame", {
		Name = "Buttons",
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = content,
	})
	local rowLayout = UIKit.List(row, 16, Enum.FillDirection.Horizontal)
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	confirm = { Window = window, Message = message, Leaving = false }

	confirm.ConfirmButton = UIKit.Button({
		Name = "Confirm",
		Text = "Sim, voltar",
		Color = Theme.Danger,
		Size = UDim2.fromOffset(200, 52),
		LayoutOrder = 1,
		Parent = row,
	}, function(button)
		if confirm.Leaving then
			return
		end
		confirm.Leaving = true
		button.Text = "Voltando..."
		button:SetAttribute("Disabled", true)
		confirm.CancelButton:SetAttribute("Disabled", true)

		local ok, result = Net.Request("ReturnToLobby")
		if ok then
			message.Text = "Salvando e levando você ao lobby..."
			-- Se o teleporte demorar demais, devolve o controle ao jogador.
			task.delay(20, function()
				if confirm and confirm.Leaving then
					resetConfirm()
				end
			end)
		else
			resetConfirm()
			NotifyController.Show(tostring(result or "Não deu para voltar ao lobby agora."), "error")
		end
	end)

	confirm.CancelButton = UIKit.Button({
		Name = "Cancel",
		Text = "Ficar aqui",
		Color = Theme.Success,
		Size = UDim2.fromOffset(200, 52),
		LayoutOrder = 2,
		Parent = row,
	}, function()
		window.Close()
	end)

	window.OnOpen:Connect(function()
		if not confirm.Leaving then
			resetConfirm()
		end
	end)
	return confirm
end

local function openReturnConfirm()
	setCursorMode(false)
	ensureConfirmWindow().Window.Open()
end

-------------------------------------------------------------------------------
-- Janela "Vantagens" (game passes)
-------------------------------------------------------------------------------

-- true se pelo menos um pass está à venda (passes ligados no Config e algum id > 0).
-- Se nenhum está, o botão "Vantagens" nem aparece. É a mesma regra do servidor.
local function anyPassForSale()
	return Gamepasses.AnyForSale()
end

-- Atualiza cada cartão: preço ("..." enquanto carrega; some se não deu para ler) e o
-- botão: "Comprar", "Abrindo...", "Já é seu!" ou "Indisponível" (tirado de venda no Roblox).
local function refreshPassWindow()
	if not passWindow then
		return
	end
	local passes = StateController.Get("Gamepasses")
	for _, row in ipairs(passWindow.Rows) do
		local owned = type(passes) == "table" and passes[row.Key] == true
		local sale = row.Sale -- {IsForSale, Price} do Roblox, ou nil (carregando / falhou)
		if owned then
			row.Button.Text = "Já é seu!"
			row.Button.BackgroundColor3 = Theme.Info
			row.Button:SetAttribute("Disabled", true)
			row.Price.Visible = false
		elseif sale and not sale.IsForSale then
			row.Button.Text = "Indisponível"
			row.Button.BackgroundColor3 = Theme.Disabled
			row.Button:SetAttribute("Disabled", true)
			row.Price.Visible = false
		else
			row.Button.Text = if passWindow.Busy then "Abrindo..." else "Comprar"
			row.Button.BackgroundColor3 = Theme.Success
			row.Button:SetAttribute("Disabled", passWindow.Busy)
			if row.Loading then
				row.Price.Text = "..."
				row.Price.Visible = true
			elseif sale and sale.Price then
				row.Price.Text = NumberFormat.Commas(sale.Price) .. " Robux"
				row.Price.Visible = true
			else
				row.Price.Visible = false -- não deu para ler o preço: esconde
			end
		end
	end
end

-- Busca no Roblox o preço e o "está à venda?" de cada pass (Gamepasses.FetchSaleInfo, que
-- guarda o resultado por id). O que falhou tenta de novo na próxima vez que a janela abrir.
local function loadPassPrices()
	if not passWindow then
		return
	end
	for _, row in ipairs(passWindow.Rows) do
		if not row.Sale and not row.Loading then
			row.Loading = true
			task.spawn(function()
				row.Sale = Gamepasses.FetchSaleInfo(row.Key)
				row.Loading = false
				refreshPassWindow()
			end)
		end
	end
	refreshPassWindow()
end

-- Pede ao servidor para abrir a janela de compra do Roblox (Request "BuyGamepass").
-- Quem ativa a vantagem é o servidor, quando a compra termina: aí o estado "Gamepasses"
-- muda e refreshPassWindow troca o botão para "Já é seu!".
local function buyPass(key)
	if not passWindow or passWindow.Busy then
		return
	end
	passWindow.Busy = true
	refreshPassWindow()
	local ok, result = Net.Request("BuyGamepass", key)
	passWindow.Busy = false
	refreshPassWindow()
	if not ok then
		NotifyController.Show(tostring(result or "Não deu para abrir a compra agora."), "error")
	end
end

-- Monta a janela na primeira vez (uma linha por pass à venda) e devolve a mesma depois.
local function ensurePassWindow()
	if passWindow then
		return passWindow
	end
	local window = UIKit.Window("Gamepasses", "Vantagens", PASS_WINDOW_SIZE)
	local content = window.Content
	local layout = UIKit.List(content, 10)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIKit.Padding(content, { Top = 8, Bottom = 8, Left = 6, Right = 6 })

	passWindow = { Window = window, Rows = {}, Busy = false }

	UIKit.Label({
		Name = "Info",
		Text = "Vantagens compradas com Robux são suas para sempre, em todas as partidas.",
		Size = UDim2.new(1, 0, 0, 44),
		TextSize = 16,
		Color = Theme.TextDim,
		LayoutOrder = 0,
		Parent = content,
	})

	for index, pass in ipairs(Gamepasses.List) do
		-- Pass sem id (0) ainda não está à venda: nem aparece na lista.
		if Gamepasses.IsForSale(pass.Key) then
			local card = UIKit.New("Frame", {
				Name = pass.Key,
				Size = UDim2.new(1, 0, 0, PASS_CARD_MIN_HEIGHT),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = Theme.PanelDark,
				BackgroundTransparency = 0.2,
				LayoutOrder = index,
				Parent = content,
			})
			UIKit.Corner(card, 14)
			UIKit.Stroke(card, 2, pass.Color)
			-- Espaço embaixo da descrição quando o cartão cresce.
			UIKit.Padding(card, { Top = 0, Bottom = 10, Left = 0, Right = 0 })
			makeLine({
				Name = "Title",
				Text = pass.Name,
				Font = Theme.TitleFont,
				Position = UDim2.fromOffset(14, 8),
				Size = UDim2.new(1, -190, 0, 26),
				TextSize = 21,
				Color = pass.Color,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = card,
			})
			UIKit.Label({
				Name = "Description",
				Text = pass.Description,
				Position = UDim2.fromOffset(14, 36),
				Size = UDim2.new(1, -190, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextSize = 15,
				Color = Theme.TextDim,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				Parent = card,
			})
			-- Preço (lido do Roblox, nunca escrito no código) em cima do botão.
			local price = makeLine({
				Name = "Price",
				Text = "...",
				Font = Theme.TitleFont,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -14, 0, 8),
				Size = UDim2.fromOffset(156, 22),
				TextSize = 18,
				Color = Theme.Coin,
				Parent = card,
			})
			local button = UIKit.Button({
				Name = "Buy",
				Text = "Comprar",
				Color = Theme.Success,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -14, 0, 34),
				Size = UDim2.fromOffset(156, 50),
				TextSize = 20,
				Parent = card,
			}, function()
				buyPass(pass.Key)
			end)
			table.insert(passWindow.Rows, { Key = pass.Key, Button = button, Price = price })
		end
	end

	window.OnOpen:Connect(loadPassPrices)
	refreshPassWindow()
	return passWindow
end

local function openPasses()
	if not anyPassForSale() then
		return
	end
	setCursorMode(false)
	ensurePassWindow().Window.Open()
end

-------------------------------------------------------------------------------
-- Construção do HUD
-------------------------------------------------------------------------------

-- Coluna da esquerda: moedas, contadores, missão e bônus.
local function buildLeftColumn(root)
	local column = UIKit.New("Frame", {
		Name = "Left",
		Position = UDim2.fromOffset(SIDE_MARGIN, 0),
		Size = UDim2.new(0, LEFT_WIDTH, 1, -SIDE_MARGIN),
		BackgroundTransparency = 1,
		Parent = root,
	})
	local layout = UIKit.List(column, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	ui.Left = column

	-- Moedas + renda por segundo.
	local coinsCard = makePanel("Coins", UDim2.new(1, 0, 0, 80), column, 1)
	ui.CoinIcon = makeCoinIcon(coinsCard, 52, UDim2.new(0, 12, 0.5, 0), Vector2.new(0, 0.5))
	if GameConfig.SharedWallet then
		makeLine({
			Name = "WalletCaption",
			Text = "Cofre do time",
			Position = UDim2.fromOffset(76, 2),
			Size = UDim2.new(1, -86, 0, 16),
			TextSize = 13,
			Color = Theme.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = coinsCard,
		})
	end
	ui.CoinsLabel = makeLine({
		Name = "Amount",
		Text = "0",
		Font = Theme.TitleFont,
		Position = UDim2.fromOffset(76, 12),
		Size = UDim2.new(1, -86, 0, 38),
		TextScaled = true,
		Color = Theme.Coin,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = coinsCard,
	})
	ui.CoinsLabel.TextStrokeTransparency = 0.2
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 36, MinTextSize = 12, Parent = ui.CoinsLabel })
	ui.IncomeLabel = makeLine({
		Name = "Income",
		Text = "+0/s",
		Position = UDim2.fromOffset(76, 50),
		Size = UDim2.new(1, -86, 0, 22),
		TextSize = 17,
		Color = Theme.Success,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = coinsCard,
	})
	-- "+X" que sobe quando você ganha moedas.
	ui.GainLabel = makeLine({
		Name = "Gain",
		Text = "",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 8),
		Size = UDim2.new(0, 120, 0, 24),
		Font = Theme.TitleFont,
		TextSize = 22,
		Color = Theme.Success,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		ZIndex = 3,
		Parent = coinsCard,
	})

	-- Brainrots vivos e recarga do quadro.
	local info = UIKit.New("Frame", {
		Name = "Info",
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = column,
	})
	UIKit.List(info, 8, Enum.FillDirection.Horizontal)
	local _, aliveLabel = makeChip("Alive", info, Theme.Accent2, 1)
	local _, boardLabel, boardDot = makeChip("Board", info, Theme.Success, 2)
	ui.AliveLabel = aliveLabel
	ui.BoardLabel = boardLabel
	ui.BoardDot = boardDot

	-- Missão.
	local questCard = makePanel("Quest", UDim2.new(1, 0, 0, QUEST_IDLE_HEIGHT), column, 3)
	ui.QuestCard = questCard
	ui.QuestTitle = makeLine({
		Name = "Title",
		Text = "Missão",
		Font = Theme.TitleFont,
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(0.5, -12, 0, 22),
		TextSize = 19,
		Color = Theme.Warning,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = questCard,
	})
	ui.QuestReward = makeLine({
		Name = "Reward",
		Text = "",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 6),
		Size = UDim2.new(0.5, -12, 0, 22),
		TextSize = 16,
		Color = Theme.Coin,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = questCard,
	})
	ui.QuestText = UIKit.Label({
		Name = "Text",
		Text = "",
		Position = UDim2.fromOffset(12, 30),
		Size = UDim2.new(1, -24, 0, 36),
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = questCard,
	})
	ui.QuestBar = UIKit.ProgressBar(questCard, {
		Name = "Progress",
		Position = UDim2.new(0, 12, 1, -28),
		Size = UDim2.new(1, -24, 0, 20),
		Color = Theme.Warning,
		TextSize = 14,
	})
	ui.QuestIdle = makeLine({
		Name = "Idle",
		Text = "",
		Position = UDim2.fromOffset(84, 0),
		Size = UDim2.new(1, -96, 1, 0),
		TextSize = 15,
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = questCard,
	})

	-- Bônus ativos (cresce sozinho conforme a quantidade de linhas).
	local buffsCard = makePanel("Buffs", UDim2.new(1, 0, 0, 0), column, 4)
	buffsCard.AutomaticSize = Enum.AutomaticSize.Y
	buffsCard.Visible = false
	UIKit.Padding(buffsCard, { Top = 8, Bottom = 10, Left = 12, Right = 12 })
	local buffsLayout = UIKit.List(buffsCard, 4)
	buffsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	makeLine({
		Name = "Title",
		Text = "Bônus ativos",
		Font = Theme.TitleFont,
		Size = UDim2.new(1, 0, 0, 22),
		TextSize = 18,
		Color = Theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 0,
		Parent = buffsCard,
	})
	ui.BuffsCard = buffsCard
end

-- Coluna da direita: botões, dica do Alt e lista do time.
local function buildRightColumn(root)
	local column = UIKit.New("Frame", {
		Name = "Right",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -SIDE_MARGIN, 0, 0),
		Size = UDim2.new(0, RIGHT_WIDTH, 1, -SIDE_MARGIN),
		BackgroundTransparency = 1,
		Parent = root,
	})
	local layout = UIKit.List(column, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	ui.Right = column

	-- Grade de botões (2 por linha).
	local grid = UIKit.New("Frame", {
		Name = "Buttons",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = column,
	})
	local gridLayout = UIKit.Grid(grid, UDim2.new(0.5, -4, 0, 44), 8)
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right

	ui.SettingsButton = UIKit.Button({
		Name = "Settings",
		Text = "Configurações",
		Color = Theme.Accent2,
		TextSize = 18,
		LayoutOrder = 1,
		Parent = grid,
	}, openSettings)
	ui.LobbyButton = UIKit.Button({
		Name = "Lobby",
		Text = "Voltar ao lobby",
		Color = Theme.Danger,
		TextSize = 18,
		LayoutOrder = 2,
		Parent = grid,
	}, openReturnConfirm)
	ui.RecipesButton = UIKit.Button({
		Name = "Recipes",
		Text = "Receitas",
		Color = Theme.Warning,
		TextSize = 18,
		LayoutOrder = 3,
		Visible = false,
		Parent = grid,
	}, openRecipes)
	ui.TurretButton = UIKit.Button({
		Name = "Turret",
		Text = "Colocar torreta",
		Color = Theme.Info,
		TextSize = 18,
		LayoutOrder = 4,
		Visible = false,
		Parent = grid,
	}, enterPlacement)
	-- Loja de game passes: escondida de vez se os passes estão desligados no Config
	-- ou nenhum id foi preenchido (o servidor recusaria a compra de qualquer jeito).
	ui.PassesButton = UIKit.Button({
		Name = "Gamepasses",
		Text = "Vantagens",
		Color = Theme.Accent,
		TextSize = 18,
		LayoutOrder = 5,
		Visible = anyPassForSale(),
		Parent = grid,
	}, openPasses)

	ui.Hint = makeLine({
		Name = "Hint",
		Text = "",
		Size = UDim2.new(1, 0, 0, 18),
		TextSize = 14,
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		LayoutOrder = 2,
		Parent = column,
	})

	-- Lista do time.
	local teamCard = makePanel("Team", UDim2.new(1, 0, 0, 0), column, 3)
	teamCard.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.Padding(teamCard, { Top = 8, Bottom = 10, Left = 12, Right = 12 })
	local teamLayout = UIKit.List(teamCard, 2)
	teamLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	ui.TeamTitle = makeLine({
		Name = "Title",
		Text = "Time",
		Font = Theme.TitleFont,
		Size = UDim2.new(1, 0, 0, 24),
		TextSize = 19,
		Color = Theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 0,
		Parent = teamCard,
	})
	ui.TeamCard = teamCard
	ui.TeamRows = {}
	for index = 1, TEAM_MAX_ROWS do
		local row = UIKit.New("Frame", {
			Name = "Row" .. index,
			Size = UDim2.new(1, 0, 0, TEAM_ROW_HEIGHT),
			BackgroundColor3 = Theme.Accent,
			BackgroundTransparency = 1,
			LayoutOrder = index,
			Visible = false,
			Parent = teamCard,
		})
		UIKit.Corner(row, 8)
		local nameLabel = makeLine({
			Name = "Name",
			Position = UDim2.fromOffset(6, 0),
			Size = UDim2.new(0.6, -6, 1, 0),
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = row,
		})
		local coinsLabel = makeLine({
			Name = "Coins",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 0),
			Size = UDim2.new(0.4, -6, 1, 0),
			TextSize = 15,
			Color = Theme.Coin,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = row,
		})
		ui.TeamRows[index] = { Frame = row, Name = nameLabel, Coins = coinsLabel }
	end
end

-- Mira no centro da tela, hitmarker e barra de calor.
local function buildCenter(root)
	local crosshair = UIKit.New("Frame", {
		Name = "Crosshair",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(44, 44),
		BackgroundTransparency = 1,
		Parent = root,
	})
	ui.Crosshair = crosshair

	-- Ponto central e quatro "tracinhos" (brancos com contorno escuro).
	local function crossPart(name, size, position)
		local part = UIKit.New("Frame", {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = position,
			Size = size,
			BackgroundColor3 = Color3.new(1, 1, 1),
			Parent = crosshair,
		})
		UIKit.Corner(part, 2)
		UIKit.Stroke(part, 1.5, Theme.Stroke)
		return part
	end
	crossPart("Dot", UDim2.fromOffset(4, 4), UDim2.fromScale(0.5, 0.5))
	crossPart("Top", UDim2.fromOffset(3, 9), UDim2.new(0.5, 0, 0.5, -11))
	crossPart("Bottom", UDim2.fromOffset(3, 9), UDim2.new(0.5, 0, 0.5, 11))
	crossPart("Left", UDim2.fromOffset(9, 3), UDim2.new(0.5, -11, 0.5, 0))
	crossPart("Right", UDim2.fromOffset(9, 3), UDim2.new(0.5, 11, 0.5, 0))

	-- Hitmarker: um "X" feito de 4 barrinhas diagonais.
	local hitmarker = UIKit.New("Frame", {
		Name = "Hitmarker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(44, 44),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = root,
	})
	local hitScale = UIKit.New("UIScale", { Parent = hitmarker })
	ui.Hitmarker = hitmarker
	ui.HitScale = hitScale
	ui.HitBars = {}
	local offsets = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
	for _, offset in ipairs(offsets) do
		local bar = UIKit.New("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, offset[1] * 11, 0.5, offset[2] * 11),
			Size = UDim2.fromOffset(4, 13),
			Rotation = offset[1] * offset[2] * -45,
			BackgroundColor3 = Color3.new(1, 1, 1),
			Parent = hitmarker,
		})
		UIKit.Corner(bar, 2)
		local stroke = UIKit.Stroke(bar, 1.5, Theme.Stroke)
		table.insert(ui.HitBars, { Bar = bar, Stroke = stroke })
	end

	-- Barra de calor (só aparece quando a arma esquenta: Deserto).
	local heat = UIKit.New("Frame", {
		Name = "Heat",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 48),
		Size = UDim2.fromOffset(220, 40),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = root,
	})
	ui.HeatFrame = heat
	ui.HeatTitle = makeLine({
		Name = "Title",
		Text = "Calor da arma",
		Size = UDim2.new(1, 0, 0, 16),
		TextSize = 13,
		Color = Theme.TextDim,
		Parent = heat,
	})
	ui.HeatBar = UIKit.ProgressBar(heat, {
		Name = "Bar",
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 18),
		Color = Theme.Warning,
		TextSize = 13,
	})
end

-- Faixa de baixo: aviso do portal (ou do ato concluído) e barra do Supremo.
local function buildBottom(root)
	local stack = UIKit.New("Frame", {
		Name = "Bottom",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -SIDE_MARGIN),
		Size = UDim2.new(0, BOTTOM_WIDTH, 0, 220),
		BackgroundTransparency = 1,
		Parent = root,
	})
	local layout = UIKit.List(stack, 8)
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	ui.Bottom = stack

	-- Aviso do portal.
	local banner = makePanel("Portal", UDim2.new(1, 0, 0, 96), stack, 1)
	banner.BackgroundColor3 = Color3.fromRGB(52, 22, 86)
	banner.Visible = false
	local bannerStroke = UIKit.Stroke(banner, 3.5, Color3.new(1, 1, 1))
	ui.PortalGlow = UIKit.New("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Accent),
			ColorSequenceKeypoint.new(0.5, Theme.Rare),
			ColorSequenceKeypoint.new(1, Theme.Accent2),
		}),
		Parent = bannerStroke,
	})
	ui.PortalBanner = banner
	ui.PortalTitle = makeLine({
		Name = "Title",
		Text = "",
		Font = Theme.TitleFont,
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.new(1, -190, 0, 30),
		TextScaled = true,
		Color = Theme.Rare,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = banner,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 12, Parent = ui.PortalTitle })
	ui.PortalInfo = UIKit.Label({
		Name = "Info",
		Text = "",
		Position = UDim2.fromOffset(16, 44),
		Size = UDim2.new(1, -190, 0, 42),
		TextSize = 15,
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = banner,
	})
	ui.PortalButton = UIKit.Button({
		Name = "Vote",
		Text = "Votar",
		Color = Theme.Success,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(156, 56),
		TextSize = 24,
		Parent = banner,
	}, function()
		if ui.PortalButton:GetAttribute("Mode") == "Supreme" then
			openSupreme()
		else
			votePortal()
		end
	end)

	-- Barra do Supremo (Deserto), com um atalho para a janela de alimentar.
	local supreme = makePanel("Supreme", UDim2.new(1, 0, 0, 58), stack, 2)
	supreme.Visible = false
	ui.SupremeCard = supreme
	makeLine({
		Name = "Title",
		Text = "Tamanho do Supremo",
		Font = Theme.TitleFont,
		Position = UDim2.fromOffset(14, 4),
		Size = UDim2.new(1, -(28 + SUPREME_BUTTON_WIDTH + 10), 0, 20),
		TextSize = 17,
		Color = Theme.Rare,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = supreme,
	})
	ui.SupremeBar = UIKit.ProgressBar(supreme, {
		Name = "Bar",
		Position = UDim2.fromOffset(14, 28),
		Size = UDim2.new(1, -(28 + SUPREME_BUTTON_WIDTH + 10), 0, 22),
		Color = Color3.fromRGB(255, 150, 60),
		TextSize = 15,
	})
	UIKit.Button({
		Name = "Feed",
		Text = "Alimentar",
		Color = Theme.Warning,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(SUPREME_BUTTON_WIDTH, 40),
		TextSize = 18,
		Parent = supreme,
	}, openSupreme)
end

-- Posiciona as colunas logo abaixo da barra do Roblox (a altura dela muda por aparelho).
local function layoutTop()
	if not ui.Left then
		return
	end
	local inset = GuiService:GetGuiInset()
	local scale = UIKit.GetScale()
	if scale <= 0 then
		scale = 1
	end
	local top = math.ceil(inset.Y / scale) + TOP_GAP
	ui.Left.Position = UDim2.fromOffset(SIDE_MARGIN, top)
	ui.Left.Size = UDim2.new(0, LEFT_WIDTH, 1, -(top + SIDE_MARGIN))
	ui.Right.Position = UDim2.new(1, -SIDE_MARGIN, 0, top)
	ui.Right.Size = UDim2.new(0, RIGHT_WIDTH, 1, -(top + SIDE_MARGIN))
end

-------------------------------------------------------------------------------
-- Atualizações a partir do estado
-------------------------------------------------------------------------------

-- Moedas: guarda o valor novo; o número na tela "corre" até ele (updateCoins).
local function onCoinsChanged(value)
	value = num(value, 0)
	if not coinsReady then
		coinsReady = true
		targetCoins = value
		displayedCoins = value
		return
	end
	local delta = value - targetCoins
	targetCoins = value
	if not ui.GainLabel then
		return
	end

	if delta > 0 then
		-- Soma os ganhos seguidos num "+X" só.
		pendingGain += delta
		gainSerial += 1
		local serial = gainSerial
		local label = ui.GainLabel
		label.Text = "+" .. NumberFormat.Abbrev(pendingGain)
		label.TextColor3 = Theme.Success
		label.TextTransparency = 0
		label.TextStrokeTransparency = 0.3
		label.Position = UDim2.new(1, -10, 0, 8)
		UIKit.Pop(label, 0.25)
		task.delay(GAIN_HOLD_TIME, function()
			if serial ~= gainSerial then
				return
			end
			pendingGain = 0
			UIKit.Tween(label, {
				TextTransparency = 1,
				TextStrokeTransparency = 1,
				Position = UDim2.new(1, -10, 0, -10),
			}, 0.35)
		end)

		local now = os.clock()
		if now - lastCoinPop >= COIN_POP_INTERVAL then
			lastCoinPop = now
			UIKit.Pop(ui.CoinIcon, 0.18)
		end
	elseif delta < 0 then
		-- Gastou: o número pisca em vermelho rapidinho.
		spendSerial += 1
		local serial = spendSerial
		ui.CoinsLabel.TextColor3 = Theme.Danger
		task.delay(0.35, function()
			if serial == spendSerial and ui.CoinsLabel then
				UIKit.Tween(ui.CoinsLabel, { TextColor3 = Theme.Coin }, 0.25)
			end
		end)
	end
end

-- A cada quadro: aproxima o número mostrado do valor real.
local function updateCoins(dt)
	if not ui.CoinsLabel then
		return
	end
	if displayedCoins ~= targetCoins then
		local diff = targetCoins - displayedCoins
		if math.abs(diff) <= math.max(0.5, math.abs(targetCoins) * 0.0005) then
			displayedCoins = targetCoins
		else
			displayedCoins += diff * (1 - math.exp(-COIN_LERP_SPEED * dt))
		end
	end
	local text = NumberFormat.Abbrev(math.floor(displayedCoins + 1e-6))
	if text ~= lastCoinsText then
		lastCoinsText = text
		ui.CoinsLabel.Text = text
	end
end

local function refreshIncome()
	if ui.IncomeLabel then
		ui.IncomeLabel.Text = "+" .. NumberFormat.Abbrev(math.max(0, num(StateController.Get("Income"), 0))) .. "/s"
	end
end

local function refreshAlive()
	if ui.AliveLabel then
		ui.AliveLabel.Text = "Brainrots: " .. NumberFormat.Abbrev(math.max(0, math.floor(num(StateController.Get("Alive"), 0))))
	end
end

-- Missão ativa (texto, progresso e recompensa) ou modo "sem missão".
local function refreshQuest()
	if not ui.QuestCard then
		return
	end
	local quest = StateController.Get("Quest")
	local active = type(quest) == "table" and type(quest.Active) == "table" and quest.Active or nil
	local hasActive = active ~= nil

	ui.QuestCard.Size = UDim2.new(1, 0, 0, if hasActive then QUEST_ACTIVE_HEIGHT else QUEST_IDLE_HEIGHT)
	ui.QuestText.Visible = hasActive
	ui.QuestBar.Frame.Visible = hasActive
	ui.QuestReward.Visible = hasActive
	ui.QuestIdle.Visible = not hasActive
	ui.QuestTitle.Position = if hasActive then UDim2.fromOffset(12, 6) else UDim2.fromOffset(12, 9)

	if hasActive then
		local target = math.max(1, num(active.Target, 1))
		local progress = math.clamp(num(active.Progress, 0), 0, target)
		ui.QuestText.Text = tostring(active.Text or "Missão")
		ui.QuestBar.Set(
			progress / target,
			NumberFormat.Abbrev(math.floor(progress)) .. " / " .. NumberFormat.Abbrev(target)
		)
		-- Mostra o que cai na carteira: o servidor paga a recompensa × os passes de moedas.
		local reward = num(active.Reward, 0) * Formulas.PassCoinMult(StateController.GetStatExtras())
		ui.QuestReward.Text = "+" .. NumberFormat.Abbrev(reward)
	end
end

-- Texto do "sem missão" (atualizado pelo relógio, por causa da contagem regressiva).
local function updateQuestIdle(now)
	if not ui.QuestIdle or not ui.QuestIdle.Visible then
		return
	end
	local quest = StateController.Get("Quest")
	local cooldownEnd = type(quest) == "table" and num(quest.CooldownEnd, 0) or 0
	local remaining = cooldownEnd - now
	if remaining > 0 then
		ui.QuestIdle.Text = "Nova missão em " .. NumberFormat.Time(remaining)
		ui.QuestIdle.TextColor3 = Theme.TextDim
	else
		ui.QuestIdle.Text = "Pegue na Barraca de Missões!"
		ui.QuestIdle.TextColor3 = Theme.Success
	end
end

-- Recarga do quadro "Plantar brainrots".
local function updateBoard(now)
	if not ui.BoardLabel then
		return
	end
	local board = StateController.Get("Board")
	local remaining = (type(board) == "table" and num(board.CooldownEnd, 0) or 0) - now
	if remaining > 0 then
		ui.BoardLabel.Text = "Plantar: " .. shortTime(remaining)
		ui.BoardDot.BackgroundColor3 = Theme.Warning
	else
		ui.BoardLabel.Text = "Plantar: pronto!"
		ui.BoardDot.BackgroundColor3 = Theme.Success
	end
end

-- Monta a lista de bônus ativos agora.
local function collectBuffs(now)
	local list = {}

	local buffs = StateController.Get("Buffs")
	if type(buffs) == "table" then
		local enchantUntil = num(buffs.TimedEnchantUntil, 0)
		if enchantUntil > now then
			table.insert(list, {
				Id = "TimedEnchant",
				Text = timedEnchantName() .. ": todos nascem encantados (" .. NumberFormat.Time(enchantUntil - now) .. ")",
				Color = Theme.Accent2,
			})
		end
		if buffs.NextWaveGiant == true then
			table.insert(list, {
				Id = "NextWaveGiant",
				Text = "Próxima leva: só Gigantes!",
				Color = Theme.Warning,
			})
		end
	end

	-- Receitas permanentes feitas nesta partida (na ordem do Config).
	local recipes = StateController.Get("Recipes")
	if type(recipes) == "table" then
		for _, recipe in ipairs(RecipesConfig.Recipes or {}) do
			if recipes[recipe.Id] and recipe.Kind == "Permanent" then
				local summary = recipeSummary(recipe)
				table.insert(list, {
					Id = "Recipe_" .. recipe.Id,
					Text = if summary ~= "" then recipe.Name .. " (" .. summary .. ")" else recipe.Name,
					Color = Theme.Success,
				})
			end
		end
	end

	-- Game passes que estão valendo agora (texto curto de Shared/Util/Gamepasses).
	local passes = StateController.Get("Gamepasses")
	if type(passes) == "table" then
		for _, pass in ipairs(Gamepasses.List) do
			local active
			if pass.Key == "ExtraTurret" then
				-- Torreta extra só faz sentido nos mapas com torretas.
				active = passes.ExtraTurret == true and currentMap ~= nil and currentMap.HasTurrets == true
			else
				active = passes[pass.Key] == true
			end
			if active then
				table.insert(list, { Id = "Pass_" .. pass.Key, Text = pass.BuffText, Color = pass.Color })
			end
		end
	end
	return list
end

-- Atualiza as linhas do painel de bônus (cria, muda o texto ou remove).
local function updateBuffs(now)
	if not ui.BuffsCard then
		return
	end
	local list = collectBuffs(now)
	local seen = {}
	for index, buff in ipairs(list) do
		seen[buff.Id] = true
		local row = buffRows[buff.Id]
		if not row then
			local frame = UIKit.New("Frame", {
				Name = buff.Id,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				Parent = ui.BuffsCard,
			})
			local dot = UIKit.New("Frame", {
				Name = "Dot",
				Position = UDim2.fromOffset(0, 5),
				Size = UDim2.fromOffset(10, 10),
				BackgroundColor3 = buff.Color,
				Parent = frame,
			})
			UIKit.Corner(dot, UDim.new(1, 0))
			local label = UIKit.Label({
				Name = "Text",
				Position = UDim2.fromOffset(18, 0),
				Size = UDim2.new(1, -18, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = frame,
			})
			row = { Frame = frame, Label = label, Dot = dot }
			buffRows[buff.Id] = row
			UIKit.Pop(frame, 0.2)
		end
		row.Frame.LayoutOrder = index
		row.Dot.BackgroundColor3 = buff.Color
		if row.Label.Text ~= buff.Text then
			row.Label.Text = buff.Text
		end
	end
	for id, row in pairs(buffRows) do
		if not seen[id] then
			row.Frame:Destroy()
			buffRows[id] = nil
		end
	end
	ui.BuffsCard.Visible = #list > 0
end

-- Lista do time: ordenada por moedas (quem tem mais fica em cima).
local function refreshTeam()
	if not ui.TeamRows then
		return
	end
	local raw = StateController.Get("TeamList")
	local list = {}
	if type(raw) == "table" then
		for _, entry in ipairs(raw) do
			if type(entry) == "table" then
				table.insert(list, entry)
			end
		end
	end
	table.sort(list, function(a, b)
		return num(a.Coins, 0) > num(b.Coins, 0)
	end)

	local match = StateController.Get("Match")
	local hostId = type(match) == "table" and match.HostUserId or nil

	for index, row in ipairs(ui.TeamRows) do
		local entry = list[index]
		row.Frame.Visible = entry ~= nil
		if entry then
			local isMe = entry.UserId == LocalPlayer.UserId
			local name = tostring(entry.Name or "?")
			if entry.UserId == hostId then
				name ..= " (dono)"
			end
			row.Name.Text = index .. ". " .. name
			row.Name.TextColor3 = if isMe then Theme.Rare else Theme.Text
			row.Coins.Text = NumberFormat.Abbrev(math.floor(num(entry.Coins, 0)))
			row.Frame.BackgroundTransparency = if isMe then 0.8 else 1
		end
	end
	ui.TeamTitle.Text = "Time (" .. #list .. ")"
	ui.TeamCard.Visible = #list > 0
end

-- Barra de calor da arma.
local function refreshHeat()
	if not ui.HeatFrame then
		return
	end
	local heat = StateController.Get("Heat")
	local stats = StateController.GetStats()
	local capacity = type(heat) == "table" and num(heat.Capacity, 0) or 0
	if capacity <= 0 and stats then
		capacity = num(stats.HeatCapacity, 0)
	end
	if capacity <= 0 then
		ui.HeatFrame.Visible = false
		return
	end
	ui.HeatFrame.Visible = true

	local value = type(heat) == "table" and num(heat.Value, 0) or 0
	local overheated = type(heat) == "table" and heat.Overheated == true
	local fraction = math.clamp(value / capacity, 0, 1)
	if overheated then
		ui.HeatBar.SetColor(Theme.Danger)
		ui.HeatBar.Set(fraction, "SUPERAQUECIDO!")
		ui.HeatTitle.Text = "Espere esfriar..."
		ui.HeatTitle.TextColor3 = Theme.Danger
	else
		-- Amarelo quando frio, vermelho quando quase cheio.
		ui.HeatBar.SetColor(Theme.Warning:Lerp(Theme.Danger, fraction))
		ui.HeatBar.Set(fraction, NumberFormat.Percent(fraction, 0))
		ui.HeatTitle.Text = "Calor da arma"
		ui.HeatTitle.TextColor3 = Theme.TextDim
	end
end

-- Barra do Supremo.
local function refreshSupreme()
	if not ui.SupremeCard then
		return
	end
	local hasSupreme = currentMap ~= nil and currentMap.HasSupreme == true
	ui.SupremeCard.Visible = hasSupreme
	if not hasSupreme then
		return
	end
	local supreme = StateController.Get("Supreme")
	local progress = type(supreme) == "table" and math.clamp(num(supreme.Progress, 0), 0, 1) or 0
	ui.SupremeBar.Set(progress, NumberFormat.Percent(progress) .. " do céu")
end

-- Aviso do portal (ou do ato concluído no último mapa).
function refreshPortal()
	if not ui.PortalBanner then
		return
	end
	local portal = StateController.Get("Portal")
	local isOpen = type(portal) == "table" and portal.Open == true

	if not isOpen then
		votedLocally = false
		-- Último mapa concluído: não tem portal, o foco passa a ser o Supremo.
		local completed = StateController.Get("Completed") == true
		if completed and currentMap and currentMap.Next == nil then
			ui.PortalBanner.Visible = true
			ui.PortalTitle.Text = "Barracas no máximo!"
			ui.PortalInfo.Text = if currentMap.HasSupreme
				then "Agora faça o Supremo crescer até tampar o sol!"
				else "Ato concluído! Parabéns, time!"
			ui.PortalButton.Visible = currentMap.HasSupreme == true
			ui.PortalButton:SetAttribute("Mode", "Supreme")
			ui.PortalButton.Text = "Supremo"
			ui.PortalButton.BackgroundColor3 = Theme.Warning
			ui.PortalButton:SetAttribute("Disabled", false)
		else
			ui.PortalBanner.Visible = false
		end
		return
	end

	local targetDef = type(portal.Target) == "string" and Maps[portal.Target] or nil
	local targetName = if type(targetDef) == "table" and targetDef.DisplayName then targetDef.DisplayName else "o próximo ato"
	local votes = math.max(0, math.floor(num(portal.Votes, 0)))
	local needed = math.max(1, math.floor(num(portal.Needed, 1)))
	if votes == 0 and not voteBusy then
		votedLocally = false
	end

	local wasVisible = ui.PortalBanner.Visible
	ui.PortalBanner.Visible = true
	ui.PortalTitle.Text = "Portal para " .. targetName .. " aberto!"
	ui.PortalButton:SetAttribute("Mode", "Vote")
	ui.PortalButton.BackgroundColor3 = Theme.Success

	if portal.Decision == "Host" then
		-- Só uma pessoa decide: o servidor manda quem é em portal.Decider (o dono ou,
		-- se ele saiu, quem ficou no lugar). Antes o HUD tentava adivinhar pela TeamList
		-- e, sem o dono, mostrava o botão para todo mundo, mas o servidor só aceitava um.
		local deciderId = portal.Decider
		local canDecide = deciderId ~= nil and deciderId == LocalPlayer.UserId
		local match = StateController.Get("Match")
		local hostId = type(match) == "table" and match.HostUserId or nil
		local othersText = "O dono da partida decide quando o time entra."
		if deciderId ~= nil and deciderId ~= hostId then
			-- O dono saiu: mostra o nome de quem ficou no lugar (se estiver na TeamList).
			othersText = "Quem ficou no lugar do dono decide quando o time entra."
			local teamList = StateController.Get("TeamList")
			if type(teamList) == "table" then
				for _, entry in ipairs(teamList) do
					if type(entry) == "table" and entry.UserId == deciderId and type(entry.Name) == "string" then
						othersText = entry.Name .. " decide quando o time entra (o dono saiu)."
						break
					end
				end
			end
		end
		ui.PortalInfo.Text = if canDecide then "Você decide quando o time entra no portal." else othersText
		ui.PortalButton.Visible = canDecide
		ui.PortalButton.Text = "Entrar"
		ui.PortalButton:SetAttribute("Disabled", voteBusy)
	else
		ui.PortalInfo.Text = ("Votos: %d/%d. A maioria decide: entrem no portal ou votem aqui!"):format(votes, needed)
		ui.PortalButton.Visible = true
		if votedLocally then
			ui.PortalButton.Text = "Votou!"
			ui.PortalButton:SetAttribute("Disabled", true)
		else
			ui.PortalButton.Text = "Votar"
			ui.PortalButton:SetAttribute("Disabled", voteBusy)
		end
	end

	if not wasVisible then
		UIKit.Pop(ui.PortalBanner, 0.12)
	end
end

-- Mostra/esconde as partes que dependem do mapa (torretas, receitas, Supremo).
local function applyMapFeatures()
	currentMap = getMapDef()
	if not built then
		return
	end
	ui.TurretButton.Visible = currentMap ~= nil and currentMap.HasTurrets == true
	ui.RecipesButton.Visible = currentMap ~= nil and currentMap.HasRecipes == true
	refreshSupreme()
	refreshHeat()
	refreshPortal()
end

-- Textos dos botões com o atalho do aparelho atual.
local function refreshButtonHints()
	if not ui.TurretButton then
		return
	end
	-- Contagem de torretas do time ("2/5"), quando já dá para ter alguma.
	local turrets = StateController.Get("Turrets")
	local placed = type(turrets) == "table" and math.max(0, math.floor(num(turrets.Placed, 0))) or 0
	local max = type(turrets) == "table" and math.max(0, math.floor(num(turrets.Max, 0))) or 0
	local count = if max > 0 then (" %d/%d"):format(placed, max) else ""

	if isGamepad() then
		ui.TurretButton.Text = "Torreta" .. count .. " (Y)"
	elseif isKeyboardMouse() and not isKeyUsedByAction(TURRET_KEY) then
		ui.TurretButton.Text = "Torreta" .. count .. " (T)"
	elseif count ~= "" then
		ui.TurretButton.Text = "Torreta" .. count
	else
		ui.TurretButton.Text = "Colocar torreta"
	end
	refreshHint()
end

-- Esconde a mira quando uma janela está aberta (o mouse fica solto).
local function refreshCrosshair()
	if ui.Crosshair then
		ui.Crosshair.Visible = not UIKit.IsAnyModalOpen()
	end
end

-- Roda a cada TIMER_INTERVAL segundos: tudo que tem contagem regressiva.
local function updateTimers()
	local now = workspace:GetServerTimeNow()
	updateBoard(now)
	updateQuestIdle(now)
	updateBuffs(now)
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Mostra o hitmarker: branco num acerto normal, dourado e maior num crítico.
function HUDController.ShowHitmarker(crit)
	if not ui.Hitmarker then
		return
	end
	hitSerial += 1
	local serial = hitSerial
	local color = if crit then Theme.Rare else Color3.new(1, 1, 1)

	ui.Hitmarker.Visible = true
	for _, item in ipairs(ui.HitBars) do
		item.Bar.BackgroundColor3 = color
		item.Bar.BackgroundTransparency = 0
		item.Stroke.Transparency = 0
		UIKit.Tween(item.Bar, { BackgroundTransparency = 1 }, HITMARKER_TIME)
		UIKit.Tween(item.Stroke, { Transparency = 1 }, HITMARKER_TIME)
	end
	ui.HitScale.Scale = if crit then 1.5 else 1.2
	UIKit.Tween(ui.HitScale, { Scale = 1 }, HITMARKER_TIME * 0.6)

	task.delay(HITMARKER_TIME, function()
		if serial == hitSerial and ui.Hitmarker then
			ui.Hitmarker.Visible = false
		end
	end)
end

-- Mostra/esconde o HUD inteiro (usado em cenas especiais).
function HUDController.SetVisible(value)
	visible = value ~= false
	if ui.Root then
		ui.Root.Visible = visible
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function HUDController.Init()
	-- Nada a preparar antes dos outros módulos: o HUD é montado no Start.
end

function HUDController.Start()
	if built then
		return
	end

	-- A nossa lista do time substitui a lista de jogadores padrão do Roblox
	-- (que ficaria por cima dos botões no canto direito).
	pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.PlayerList, false)

	local screen = UIKit.GetScreen(SCREEN_NAME, DISPLAY_ORDER)
	local root = UIKit.New("Frame", {
		Name = "Root",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = visible,
		Parent = screen,
	})
	ui.Root = root
	trove:Add(root)

	buildLeftColumn(root)
	buildRightColumn(root)
	buildCenter(root)
	buildBottom(root)
	built = true

	-- Posição abaixo da barra do Roblox (e de novo quando a tela muda de tamanho).
	layoutTop()
	local function watchViewport()
		local camera = workspace.CurrentCamera
		if camera then
			trove:Connect(camera:GetPropertyChangedSignal("ViewportSize"), function()
				-- Espera o UIKit recalcular a escala antes de reposicionar.
				task.defer(layoutTop)
			end)
		end
	end
	watchViewport()
	trove:Connect(workspace:GetPropertyChangedSignal("CurrentCamera"), function()
		watchViewport()
		task.defer(layoutTop)
	end)

	-- Estado inicial.
	onCoinsChanged(StateController.Get("Coins"))
	updateCoins(0)
	applyMapFeatures()
	refreshIncome()
	refreshAlive()
	refreshQuest()
	refreshTeam()
	refreshButtonHints()
	refreshCrosshair()
	updateTimers()

	-- Mudanças de estado vindas do servidor.
	trove:Add(StateController.OnChanged("Coins", onCoinsChanged))
	trove:Add(StateController.OnChanged("Income", refreshIncome))
	trove:Add(StateController.OnChanged("Alive", refreshAlive))
	trove:Add(StateController.OnChanged("Quest", function()
		refreshQuest()
		updateQuestIdle(workspace:GetServerTimeNow())
	end))
	trove:Add(StateController.OnChanged("TeamList", function()
		refreshTeam()
		refreshPortal()
	end))
	trove:Add(StateController.OnChanged("Match", function()
		applyMapFeatures()
		refreshTeam()
	end))
	trove:Add(StateController.OnChanged("Heat", refreshHeat))
	trove:Add(StateController.OnChanged("Supreme", refreshSupreme))
	trove:Add(StateController.OnChanged("Portal", refreshPortal))
	trove:Add(StateController.OnChanged("Completed", refreshPortal))
	trove:Add(StateController.OnChanged("Board", function()
		updateBoard(workspace:GetServerTimeNow())
	end))
	trove:Add(StateController.OnChanged("Profile", refreshButtonHints))
	trove:Add(StateController.OnChanged("Turrets", refreshButtonHints))
	-- Comprou um pass (ou a posse foi conferida na entrada): atualiza a janela "Vantagens".
	trove:Add(StateController.OnChanged("Gamepasses", refreshPassWindow))
	trove:Add(StateController.StatsChanged:Connect(refreshHeat))
	trove:Add(UIKit.ModalChanged:Connect(refreshCrosshair))
	trove:Connect(UserInputService.LastInputTypeChanged, refreshButtonHints)

	-- A cena final esconde tudo: garante que o mouse não fica "solto" pelo modo cursor.
	trove:Add(Net.On("Ending", function()
		setCursorMode(false)
	end))

	-- Teclas do HUD: Alt (soltar o mouse), T / Y (colocar torreta).
	trove:Connect(UserInputService.InputBegan, function(input, gameProcessed)
		local keyCode = input.KeyCode
		if CURSOR_KEYS[keyCode] then
			if not UserInputService:GetFocusedTextBox() then
				setCursorMode(not cursorMode)
			end
			return
		end
		-- No modo cursor, clicar no jogo (fora dos botões) volta a mirar.
		-- Só saímos do modo cursor quando o botão é SOLTO (InputEnded, abaixo): assim,
		-- enquanto o botão desce, o mouse ainda está "solto" e a arma ignora esse clique
		-- (ele serve só para voltar a mirar; para atirar, é preciso clicar de novo).
		if cursorMode and input.UserInputType == Enum.UserInputType.MouseButton1 and not gameProcessed then
			cursorClickPending = true
			return
		end
		if gameProcessed then
			return
		end
		local wantsTurret = keyCode == TURRET_GAMEPAD_KEY or (keyCode == TURRET_KEY and not isKeyUsedByAction(TURRET_KEY))
		if wantsTurret and currentMap and currentMap.HasTurrets and not UIKit.IsAnyModalOpen() then
			local PlacementController = getController("PlacementController")
			if PlacementController and PlacementController.IsActive and PlacementController.IsActive() then
				return
			end
			enterPlacement()
		end
	end)

	-- Soltou o clique que começou no mundo durante o modo cursor: agora sim volta a mirar.
	trove:Connect(UserInputService.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and cursorClickPending then
			setCursorMode(false)
		end
	end)

	-- Relógio único: moedas animadas (todo quadro), brilho do portal e contagens.
	local timerAccumulator = 0
	trove:Connect(RunService.Heartbeat, function(dt)
		updateCoins(dt)
		if ui.PortalBanner and ui.PortalBanner.Visible then
			ui.PortalGlow.Rotation = (ui.PortalGlow.Rotation + dt * GLOW_SPEED) % 360
		end
		timerAccumulator += dt
		if timerAccumulator >= TIMER_INTERVAL then
			timerAccumulator = 0
			updateTimers()
		end
	end)

	-- Se o HUD for destruído (não deveria), solta o mouse.
	trove:Add(function()
		setCursorMode(false)
		built = false
	end)
end

-- Deixa as funções do módulo funcionarem com "." e também com ":"
-- (ex.: HUDController.ShowHitmarker(true) e HUDController:ShowHitmarker(true)).
for name, fn in pairs(HUDController) do
	if type(fn) == "function" then
		HUDController[name] = function(first, ...)
			if first == HUDController then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return HUDController
