-- SupremeWindow (partida, Deserto): a janela do Brainrot Supremo.
--
-- Abre pelo prompt da Grande Cova (ClientAction "Supreme"), pelo botão da barraca de
-- Crescimento e pelo botão "Alimentar" do HUD. Mostra:
--   * quanto do céu o Supremo já cobre ("X% do céu") e a altura dele;
--   * um desenho do céu com o sol e o Supremo crescendo até tampar o sol;
--   * como ele cresce sozinho (efeito dos upgrades da barraca de Crescimento);
--   * os botões "Alimentar 10% / 50% / 100% das moedas" (Request "FeedSupreme"),
--     com uma estimativa de quanto cada um gasta e quanto faz o Supremo crescer.
-- O Supremo é do time todo: qualquer um que alimenta ajuda todo mundo.
--
-- O cliente só PEDE (Net.Request); quem cobra as moedas e faz crescer é o servidor.
--
-- API:
--   PromptController.Register("Supreme", fn) é feito no Init.
--   SupremeWindow.Open()     abre a janela (extra)
--   SupremeWindow.Close()    fecha (extra)
--   SupremeWindow.IsOpen()   true se está aberta (extra)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maps = require(Config:WaitForChild("Maps"))
local Brainrots = require(Config:WaitForChild("Brainrots"))
local Net = require(Util:WaitForChild("Net"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))
local Trove = require(Util:WaitForChild("Trove"))

local UIKit = require(script.Parent:WaitForChild("UIKit"))
local ControllersFolder = script.Parent.Parent:WaitForChild("Controllers")
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme

local SupremeWindow = {}

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
-- Constantes (layout, cores e a fórmula de custo usada só na estimativa)
-------------------------------------------------------------------------------

local WINDOW_NAME = "Supreme"
local WINDOW_SIZE = UDim2.fromOffset(760, 580)

-- Desenho do céu (pixels da interface).
local SKY_WIDTH, SKY_HEIGHT = 200, 260
local GROUND_HEIGHT = 34
local SUN_SIZE = 50
local SUN_CENTER_Y = 46 -- distância do topo do céu até o centro do sol
local BODY_MIN_WIDTH, BODY_MAX_WIDTH = 46, 92
local BODY_MIN_HEIGHT = 40 -- o Supremo sempre aparece um pouquinho (a cabeça saindo da cova)
-- Altura do desenho no 100%: do chão até passar do topo do sol (tampando ele todo).
local BODY_MAX_HEIGHT = (SKY_HEIGHT - GROUND_HEIGHT + 8) - (SUN_CENTER_Y - SUN_SIZE / 2) + 6
local SHADE_MAX = 0.6 -- quanto o céu escurece quando o sol é tampado

local SKY_TOP = Color3.fromRGB(255, 176, 96) -- fim de tarde alaranjado
local SKY_BOTTOM = Color3.fromRGB(255, 226, 150)
local SUN_COLOR = Color3.fromRGB(255, 236, 110)
local SAND_COLOR = Color3.fromRGB(226, 188, 120)
local BAR_COLOR = Color3.fromRGB(255, 150, 60)

-- A mesma conta do servidor (seção 8.12 da especificação): encher 100% custa
-- BaseFullCost × CostScale × (1 + 3 × Progress). Aqui ela serve SÓ para mostrar
-- uma estimativa nos botões; quem decide de verdade é o SupremeService.
local FEED_PROGRESS_COST_FACTOR = 3

-- Botões de alimentar (as frações aceitas pelo servidor: 0.1, 0.5 e 1).
local FEED_OPTIONS = {
	{ Name = "Feed10", Fraction = 0.1, Text = "Alimentar 10%", Color = Theme.Success },
	{ Name = "Feed50", Fraction = 0.5, Text = "Alimentar 50%", Color = Theme.Warning },
	{ Name = "Feed100", Fraction = 1, Text = "Alimentar 100%", Color = Theme.Accent },
}

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local window = nil
local ui = {} -- referências das peças da janela
local listenTrove = Trove.new() -- conexões enquanto a janela está aberta
local lifeTrove = Trove.new() -- conexões que vivem o jogo todo
local busy = false -- true enquanto um pedido de alimentar está a caminho
local refreshQueued = false
local lastBodyHeight = nil

-------------------------------------------------------------------------------
-- Ajudantes de estado
-------------------------------------------------------------------------------

-- Número seguro (nil, texto ou NaN viram o padrão).
local function num(value, default)
	value = tonumber(value)
	if value == nil or value ~= value then
		return default or 0
	end
	return value
end

-- Mapa atual (Config.Maps[x]) ou nil.
local function getMap()
	local match = StateController.Get("Match")
	local mapId = type(match) == "table" and match.MapId or nil
	local mapDef = type(mapId) == "string" and Maps[mapId] or nil
	-- "Order" também é uma chave de Maps, por isso conferimos o campo Act.
	if type(mapDef) == "table" and mapDef.Act ~= nil then
		return mapDef
	end
	return nil
end

local function getCoins()
	return math.max(0, num(StateController.Get("Coins"), 0))
end

-- Lê o estado "Supreme" e a configuração do mapa.
-- Devolve progresso (0..1), altura, altura mínima e altura máxima.
local function readSupreme(mapDef)
	local supremeConfig = mapDef and type(mapDef.Supreme) == "table" and mapDef.Supreme or {}
	local minHeight = num(supremeConfig.MinHeight, 8)
	local maxHeight = math.max(minHeight + 1, num(supremeConfig.MaxHeight, 500))

	local supreme = StateController.Get("Supreme")
	local progress = type(supreme) == "table" and math.clamp(num(supreme.Progress, 0), 0, 1) or 0
	local height = type(supreme) == "table" and num(supreme.Height, 0) or 0
	if height <= 0 then
		-- Ainda não chegou a altura: usa a mesma fórmula do servidor (seção 8.12).
		height = minHeight + (maxHeight - minHeight) * progress ^ 1.5
	end
	return progress, height, minHeight, maxHeight
end

-- Moedas para encher o Supremo de 0 a 100% com o progresso atual (sem o rendimento).
local function fullCost(mapDef, progress)
	local supremeConfig = mapDef and type(mapDef.Supreme) == "table" and mapDef.Supreme or nil
	if not supremeConfig then
		return 0
	end
	return num(supremeConfig.BaseFullCost, 0) * num(mapDef.CostScale, 1) * (1 + FEED_PROGRESS_COST_FACTOR * progress)
end

-- Estimativa de um botão de alimentar: (moedas gastas, progresso ganho).
-- Espelha o servidor: gasta floor(moedas × fração), no mínimo 1, e nunca mais que o
-- necessário para chegar a 100%.
local function estimateFeed(mapDef, fraction, coins, progress, feedPower)
	local cost = fullCost(mapDef, progress)
	if coins < 1 or progress >= 1 or cost <= 0 or feedPower <= 0 then
		return 0, 0
	end
	local spend = math.max(1, math.floor(coins * fraction))
	local neededForFull = math.max(1, math.ceil((1 - progress) * cost / feedPower))
	spend = math.min(spend, neededForFull)
	return spend, spend / cost * feedPower
end

-------------------------------------------------------------------------------
-- Peças visuais
-------------------------------------------------------------------------------

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
	UIKit.Stroke(coin, 2, UIKit.Darken(Theme.Coin, 0.5))
	local inner = UIKit.New("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		BackgroundColor3 = UIKit.Lighten(Theme.Coin, 0.3),
		Parent = coin,
	})
	UIKit.Corner(inner, UDim.new(1, 0))
	return coin
end

-- Círculo simples (sol, olhos, brilho).
local function makeCircle(parent, name, size, position, color, zIndex)
	local circle = UIKit.New("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = size,
		BackgroundColor3 = color,
		ZIndex = zIndex or 1,
		Parent = parent,
	})
	UIKit.Corner(circle, UDim.new(1, 0))
	return circle
end

-- Barra do topo: moedas do jogador e lembrete de que o Supremo é do time.
local function buildTopBar(parent)
	local bar = UIKit.New("Frame", {
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.1,
		LayoutOrder = 1,
		Parent = parent,
	})
	UIKit.Corner(bar, UDim.new(1, 0))
	UIKit.Stroke(bar, 2, UIKit.Darken(Theme.Rare, 0.35))
	makeCoinIcon(bar, 28, UDim2.new(0, 12, 0.5, 0), Vector2.new(0, 0.5))
	ui.Coins = UIKit.Label({
		Name = "Coins",
		Text = "",
		Title = true,
		TextSize = 24,
		Position = UDim2.fromOffset(48, 0),
		Size = UDim2.new(0.5, -48, 1, 0),
		Color = Theme.Coin,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = bar,
	})
	UIKit.Label({
		Name = "Team",
		Text = "O Supremo é do time todo!",
		TextSize = 15,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 0),
		Size = UDim2.new(0.5, -18, 1, 0),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = bar,
	})
end

-- O desenho do céu: sol, areia, e o Supremo que cresce da cova até tampar o sol.
local function buildSky(parent)
	local sky = UIKit.New("Frame", {
		Name = "Sky",
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(SKY_WIDTH, SKY_HEIGHT),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ClipsDescendants = true,
		Parent = parent,
	})
	UIKit.Corner(sky, 14)
	UIKit.Stroke(sky, 2.5, Theme.Stroke)
	UIKit.New("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(SKY_TOP, SKY_BOTTOM),
		Parent = sky,
	})

	-- Sol com um brilho em volta.
	local sunPosition = UDim2.new(0.5, 0, 0, SUN_CENTER_Y)
	local glow = makeCircle(sky, "SunGlow", UDim2.fromOffset(SUN_SIZE + 30, SUN_SIZE + 30), sunPosition, SUN_COLOR, 1)
	glow.BackgroundTransparency = 0.6
	local sun = makeCircle(sky, "Sun", UDim2.fromOffset(SUN_SIZE, SUN_SIZE), sunPosition, SUN_COLOR, 1)
	UIKit.Stroke(sun, 3, UIKit.Lighten(SUN_COLOR, 0.5))

	-- O Supremo (cores do Config.Brainrots.Supreme): corpo, barriga, olhos e coroa.
	local colors = type(Brainrots.Supreme) == "table" and Brainrots.Supreme.Colors or {}
	local primary = typeof(colors.Primary) == "Color3" and colors.Primary or Theme.Info
	local secondary = typeof(colors.Secondary) == "Color3" and colors.Secondary or Theme.Text
	local accent = typeof(colors.Accent) == "Color3" and colors.Accent or Theme.Rare

	local body = UIKit.New("Frame", {
		Name = "Supreme",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(GROUND_HEIGHT - 8)),
		Size = UDim2.fromOffset(BODY_MIN_WIDTH, BODY_MIN_HEIGHT),
		BackgroundColor3 = primary,
		ZIndex = 2,
		Parent = sky,
	})
	UIKit.Corner(body, UDim.new(0, 20))
	UIKit.Stroke(body, 2.5, UIKit.Darken(primary, 0.45))
	local belly = UIKit.New("Frame", {
		Name = "Belly",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(0.56, 0, 1, -30),
		BackgroundColor3 = secondary,
		ZIndex = 1,
		Parent = body,
	})
	UIKit.Corner(belly, UDim.new(0, 14))
	for index, x in ipairs({ 0.3, 0.7 }) do
		local eye = makeCircle(body, "Eye" .. index, UDim2.fromOffset(16, 16), UDim2.new(x, 0, 0, 16), Color3.new(1, 1, 1), 2)
		UIKit.Stroke(eye, 1.5, Theme.Stroke)
		makeCircle(eye, "Pupil", UDim2.fromOffset(7, 7), UDim2.fromScale(0.55, 0.55), Color3.new(0, 0, 0), 2)
	end
	-- Coroa: uma faixa dourada com três pontas (quadradinhos girados).
	local crown = UIKit.New("Frame", {
		Name = "Crown",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, 4),
		Size = UDim2.fromOffset(34, 10),
		BackgroundColor3 = accent,
		ZIndex = 3,
		Parent = body,
	})
	UIKit.Corner(crown, 3)
	for _, x in ipairs({ 0.15, 0.5, 0.85 }) do
		local spike = UIKit.New("Frame", {
			Name = "Spike",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(x, 0, 0, 0),
			Size = UDim2.fromOffset(9, 9),
			Rotation = 45,
			BackgroundColor3 = accent,
			ZIndex = 3,
			Parent = crown,
		})
		UIKit.Corner(spike, 2)
	end

	-- Areia na frente (esconde a base do Supremo, como se ele saísse da cova).
	local ground = UIKit.New("Frame", {
		Name = "Ground",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, GROUND_HEIGHT),
		BackgroundColor3 = SAND_COLOR,
		ZIndex = 3,
		Parent = sky,
	})
	UIKit.New("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(UIKit.Lighten(SAND_COLOR, 0.15), UIKit.Darken(SAND_COLOR, 0.2)),
		Parent = ground,
	})
	-- A borda escura da cova.
	local pit = UIKit.New("Frame", {
		Name = "Pit",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(BODY_MAX_WIDTH + 20, 10),
		BackgroundColor3 = UIKit.Darken(SAND_COLOR, 0.55),
		ZIndex = 3,
		Parent = ground,
	})
	UIKit.Corner(pit, UDim.new(1, 0))

	-- Véu escuro: o céu escurece conforme o Supremo tampa o sol.
	local shade = UIKit.New("Frame", {
		Name = "Shade",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(20, 8, 40),
		BackgroundTransparency = 1,
		ZIndex = 5,
		Parent = sky,
	})

	ui.Sky = sky
	ui.Body = body
	ui.Shade = shade
	ui.Sun = sun
	ui.SunGlow = glow
end

-- Cartão principal: desenho à esquerda e números à direita.
local function buildMainCard(parent)
	local card = UIKit.New("Frame", {
		Name = "Main",
		Size = UDim2.new(1, 0, 0, SKY_HEIGHT + 20),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		LayoutOrder = 2,
		Parent = parent,
	})
	UIKit.Corner(card, 16)
	UIKit.Stroke(card, 2, UIKit.Darken(Theme.Rare, 0.4))

	buildSky(card)

	local info = UIKit.New("Frame", {
		Name = "Info",
		Position = UDim2.fromOffset(SKY_WIDTH + 26, 10),
		Size = UDim2.new(1, -(SKY_WIDTH + 40), 1, -20),
		BackgroundTransparency = 1,
		Parent = card,
	})
	local layout = UIKit.List(info, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	local supremeName = type(Brainrots.Supreme) == "table" and Brainrots.Supreme.DisplayName or "Brainrot Supremo"
	UIKit.Label({
		Name = "Name",
		Text = supremeName,
		Title = true,
		TextSize = 28,
		Size = UDim2.new(1, 0, 0, 32),
		Color = Theme.Rare,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Parent = info,
	})
	ui.BigPercent = UIKit.Label({
		Name = "Percent",
		Text = "",
		Title = true,
		TextSize = 34,
		Size = UDim2.new(1, 0, 0, 40),
		Color = BAR_COLOR,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = info,
	})
	ui.Bar = UIKit.ProgressBar(info, {
		Name = "Progress",
		Size = UDim2.new(1, 0, 0, 30),
		Color = BAR_COLOR,
		TextSize = 17,
		LayoutOrder = 3,
	})
	ui.Height = UIKit.Label({
		Name = "Height",
		Text = "",
		TextSize = 17,
		Size = UDim2.new(1, 0, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 4,
		Parent = info,
	})
	ui.Growth = UIKit.Label({
		Name = "Growth",
		Text = "",
		TextSize = 15,
		RichText = true,
		Size = UDim2.new(1, 0, 0, 66),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 5,
		Parent = info,
	})
	ui.Goal = UIKit.Label({
		Name = "Goal",
		Text = "",
		TextSize = 15,
		Size = UDim2.new(1, 0, 0, 40),
		Color = Theme.Warning,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 6,
		Parent = info,
	})
end

-------------------------------------------------------------------------------
-- Alimentar
-------------------------------------------------------------------------------

local refresh -- declarada aqui, definida mais abaixo

local function feed(option)
	if busy then
		return
	end
	local mapDef = getMap()
	local progressBefore = readSupreme(mapDef)
	busy = true
	refresh()

	local ok, result = Net.Request("FeedSupreme", option.Fraction)
	busy = false
	if ok then
		local spent = type(result) == "table" and num(result.Spent, 0) or 0
		local progressAfter = type(result) == "table" and math.clamp(num(result.Progress, progressBefore), 0, 1)
			or progressBefore
		local gained = math.max(0, progressAfter - progressBefore)
		UIKit.PlaySound("Purchase")
		if ui.Body then
			UIKit.Pop(ui.Body, 0.12)
		end
		if ui.Result then
			ui.Result.Text = ("Você deu %s moedas ao Supremo: +%s. Agora ele cobre %s do céu!"):format(
				NumberFormat.Abbrev(spent),
				NumberFormat.Percent(gained),
				NumberFormat.Percent(progressAfter)
			)
			ui.Result.TextColor3 = Theme.Success
			UIKit.Pop(ui.Result, 0.08)
		end
	else
		local message = tostring(result or "Não deu para alimentar o Supremo agora.")
		NotifyController.Show(message, "error")
		if ui.Result then
			ui.Result.Text = message
			ui.Result.TextColor3 = Theme.Danger
		end
	end
	refresh()
end

-- Seção dos botões "Alimentar 10% / 50% / 100% das moedas".
local function buildFeedSection(parent)
	local section = UIKit.New("Frame", {
		Name = "Feed",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		LayoutOrder = 3,
		Parent = parent,
	})
	UIKit.Corner(section, 16)
	UIKit.Stroke(section, 2, UIKit.Darken(Theme.Warning, 0.4))
	UIKit.Padding(section, { Top = 10, Bottom = 12, Left = 12, Right = 12 })
	local layout = UIKit.List(section, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	UIKit.Label({
		Name = "Title",
		Text = "Alimentar com moedas",
		Title = true,
		TextSize = 24,
		Size = UDim2.new(1, 0, 0, 28),
		Color = Theme.Warning,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Parent = section,
	})
	UIKit.Label({
		Name = "Subtitle",
		Text = "Suas moedas viram crescimento para o time todo. Quanto maior ele fica, mais caro é crescer.",
		TextSize = 14,
		Size = UDim2.new(1, 0, 0, 36),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 2,
		Parent = section,
	})

	local row = UIKit.New("Frame", {
		Name = "Options",
		Size = UDim2.new(1, 0, 0, 124),
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = section,
	})
	local rowLayout = UIKit.List(row, 10, Enum.FillDirection.Horizontal)
	rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	ui.Options = {}
	for index, option in ipairs(FEED_OPTIONS) do
		local card = UIKit.New("Frame", {
			Name = option.Name,
			Size = UDim2.new(1 / #FEED_OPTIONS, -7, 1, 0),
			BackgroundColor3 = Theme.PanelLight,
			BackgroundTransparency = 0.1,
			LayoutOrder = index,
			Parent = row,
		})
		UIKit.Corner(card, 14)
		UIKit.Stroke(card, 2, Theme.Stroke)

		local button = UIKit.Button({
			Name = "Feed",
			Text = option.Text,
			Color = option.Color,
			Position = UDim2.fromOffset(8, 8),
			Size = UDim2.new(1, -16, 0, 54),
			TextSize = 22,
			Sound = false, -- o som toca quando o servidor confirma
			Parent = card,
		}, function(self)
			if self:GetAttribute("Disabled") == true then
				return
			end
			feed(option)
		end)
		local spend = UIKit.Label({
			Name = "Spend",
			Text = "",
			TextSize = 15,
			Position = UDim2.fromOffset(10, 68),
			Size = UDim2.new(1, -20, 0, 22),
			Color = Theme.Coin,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = card,
		})
		local gain = UIKit.Label({
			Name = "Gain",
			Text = "",
			TextSize = 15,
			Position = UDim2.fromOffset(10, 92),
			Size = UDim2.new(1, -20, 0, 22),
			Color = Theme.Success,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = card,
		})
		ui.Options[index] = { Option = option, Button = button, Spend = spend, Gain = gain }
	end

	ui.Result = UIKit.Label({
		Name = "Result",
		Text = "",
		TextSize = 15,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 4,
		Parent = section,
	})
end

-------------------------------------------------------------------------------
-- Atualização
-------------------------------------------------------------------------------

-- Atualiza o desenho do céu (tamanho do Supremo e escuridão).
local function refreshSky(progress, height, minHeight, maxHeight)
	if not ui.Body then
		return
	end
	local fraction = math.clamp((height - minHeight) / (maxHeight - minHeight), 0, 1)
	if progress >= 1 then
		fraction = 1
	end
	local bodyHeight = math.floor(BODY_MIN_HEIGHT + (BODY_MAX_HEIGHT - BODY_MIN_HEIGHT) * fraction + 0.5)
	local bodyWidth = math.floor(BODY_MIN_WIDTH + (BODY_MAX_WIDTH - BODY_MIN_WIDTH) * fraction + 0.5)
	local target = UDim2.fromOffset(bodyWidth, bodyHeight)
	if lastBodyHeight == nil or not (window and window.IsOpen()) then
		ui.Body.Size = target
	elseif bodyHeight ~= lastBodyHeight then
		UIKit.Tween(ui.Body, { Size = target }, 0.5, Enum.EasingStyle.Back)
	end
	lastBodyHeight = bodyHeight

	-- O céu escurece com o progresso (e fica bem escuro no eclipse).
	ui.Shade.BackgroundTransparency = 1 - SHADE_MAX * progress
	ui.SunGlow.BackgroundTransparency = 0.6 + 0.4 * progress
end

-- Atualiza tudo com o estado atual.
function refresh()
	if not window then
		return
	end
	local mapDef = getMap()
	local progress, height, minHeight, maxHeight = readSupreme(mapDef)
	local coins = getCoins()
	local stats = StateController.GetStats()
	local feedPower = stats and num(stats.SupremeFeed, 1) or 1
	local passive = stats and num(stats.SupremePassive, 0) or 0
	local perKill = stats and num(stats.SupremeKill, 0) or 0
	local finished = progress >= 1

	ui.Coins.Text = NumberFormat.Abbrev(math.floor(coins)) .. " moedas"

	-- Progresso ("X% do céu") e altura.
	local percentText = NumberFormat.Percent(progress) .. " do céu"
	ui.BigPercent.Text = if finished then "O SOL FOI TAMPADO!" else percentText
	ui.BigPercent.TextColor3 = if finished then Theme.Rare else BAR_COLOR
	ui.Bar.Set(progress, percentText)
	ui.Height.Text = ("Altura: %s studs (vai até %s)"):format(
		NumberFormat.Abbrev(math.floor(height + 0.5)),
		NumberFormat.Abbrev(math.floor(maxHeight + 0.5))
	)

	-- Como ele cresce (efeito dos upgrades da barraca de Crescimento).
	local white = Theme.Text:ToHex()
	local lines = {
		('Cresce sozinho: <font color="#%s">+%s por segundo</font>'):format(white, NumberFormat.Percent(passive)),
	}
	if perKill > 0 then
		table.insert(
			lines,
			('Cada brainrot destruído: <font color="#%s">+%s</font>'):format(white, NumberFormat.Percent(perKill))
		)
	else
		table.insert(lines, "Cada brainrot destruído: compre \"Raiz Profunda\"")
	end
	table.insert(
		lines,
		('Rendimento ao alimentar: <font color="#%s">×%s</font>'):format(white, NumberFormat.Abbrev(feedPower))
	)
	ui.Growth.Text = table.concat(lines, "\n")

	-- Quanto falta para tampar o sol (em moedas, alimentando agora).
	local cost = fullCost(mapDef, progress)
	if finished then
		ui.Goal.Text = "Ele conseguiu! Olhe para o sol..."
		ui.Goal.TextColor3 = Theme.Rare
	elseif cost > 0 and feedPower > 0 then
		local needed = math.ceil((1 - progress) * cost / feedPower)
		ui.Goal.Text = ("Faltam cerca de %s moedas para ele tampar o sol."):format(NumberFormat.Abbrev(needed))
		ui.Goal.TextColor3 = Theme.Warning
	else
		ui.Goal.Text = "Faça ele crescer até tampar o sol!"
		ui.Goal.TextColor3 = Theme.Warning
	end

	-- Botões de alimentar com a estimativa de cada um.
	for _, item in ipairs(ui.Options) do
		local spend, gain = estimateFeed(mapDef, item.Option.Fraction, coins, progress, feedPower)
		local enabled = not busy and not finished and spend >= 1
		item.Button:SetAttribute("Disabled", not enabled)
		if finished then
			item.Spend.Text = "Completo!"
			item.Gain.Text = ""
		elseif spend < 1 then
			item.Spend.Text = "Sem moedas"
			item.Spend.TextColor3 = Theme.Danger
			item.Gain.Text = ""
		else
			item.Spend.Text = "Gasta " .. NumberFormat.Abbrev(spend) .. " moedas"
			item.Spend.TextColor3 = Theme.Coin
			item.Gain.Text = "+" .. NumberFormat.Percent(gain) .. " do céu"
		end
		item.Button.Text = if busy then "Alimentando..." else item.Option.Text
	end

	refreshSky(progress, height, minHeight, maxHeight)
end

-- Junta várias mudanças do mesmo quadro numa atualização só.
local function scheduleRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		if window and window.IsOpen() then
			refresh()
		end
	end)
end

-- Liga os "ouvintes" enquanto a janela está aberta.
local function startListening()
	listenTrove:Clean()
	listenTrove:Add(StateController.OnChanged("Supreme", scheduleRefresh))
	listenTrove:Add(StateController.OnChanged("Coins", scheduleRefresh))
	listenTrove:Add(StateController.OnChanged("Match", scheduleRefresh))
	listenTrove:Add(StateController.StatsChanged:Connect(scheduleRefresh))
end

local function ensureWindow()
	if window then
		return window
	end
	window = UIKit.Window(WINDOW_NAME, "Brainrot Supremo", WINDOW_SIZE)

	-- Tudo fica dentro de um "holder" que cresce com o conteúdo (o Content rola).
	local holder = UIKit.New("Frame", {
		Name = "SupremeContent",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = window.Content,
	})
	UIKit.Padding(holder, { Top = 4, Bottom = 12, Left = 2, Right = 6 })
	UIKit.List(holder, 10)

	buildTopBar(holder)
	buildMainCard(holder)
	buildFeedSection(holder)

	window.OnOpen:Connect(startListening)
	window.OnClose:Connect(function()
		listenTrove:Clean()
	end)
	return window
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Abre a janela (só no mapa que tem o Brainrot Supremo).
function SupremeWindow.Open()
	local mapDef = getMap()
	if not mapDef then
		NotifyController.Show("A partida ainda está carregando. Tente de novo em instantes.", "warning", 3)
		return
	end
	if not mapDef.HasSupreme then
		NotifyController.Show("Não há Brainrot Supremo neste mapa.", "warning", 3)
		return
	end
	ensureWindow()
	lastBodyHeight = nil
	if ui.Result and not busy then
		ui.Result.Text = ""
	end
	refresh()
	window.Content.CanvasPosition = Vector2.zero
	window.Open()
end

function SupremeWindow.Close()
	if window then
		window.Close()
	end
end

function SupremeWindow.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function SupremeWindow.Init()
	-- Prompt da Grande Cova (ClientAction "Supreme"), HUD e barraca de Crescimento.
	local PromptController = getController("PromptController")
	if PromptController and PromptController.Register then
		lifeTrove:Add(PromptController.Register("Supreme", function()
			SupremeWindow.Open()
		end))
	else
		warn("[SupremeWindow] PromptController não encontrado; a janela do Supremo não vai abrir pelo prompt.")
	end
end

function SupremeWindow.Start()
	-- Na cena final a janela fecha sozinha (a câmera vai mostrar o Supremo tampando o sol).
	lifeTrove:Add(Net.On("Ending", function()
		SupremeWindow.Close()
	end))
end

-- Deixa as funções do módulo funcionarem com "." e também com ":".
for name, fn in pairs(SupremeWindow) do
	if type(fn) == "function" then
		SupremeWindow[name] = function(first, ...)
			if first == SupremeWindow then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return SupremeWindow
