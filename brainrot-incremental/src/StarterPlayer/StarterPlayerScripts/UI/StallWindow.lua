-- StallWindow (partida): a janela das barracas de upgrade.
--
-- Abre quando o jogador usa o balcão de uma barraca (prompt com ClientAction "Stall:<id>").
-- Mostra os upgrades daquela barraca no mapa atual, agrupados por prateleira:
--   * prateleiras liberadas: cada upgrade com nome, descrição, nível/máx, efeito atual → próximo,
--     custo (verde se dá para comprar, vermelho se não) e botões x1, x10 e Máx;
--   * o painel "Melhorar Barraca (prateleira N)", que só fica ativo quando TODOS os upgrades
--     liberados de TODAS as barracas estão no máximo (conta feita aqui no cliente com o estado);
--   * prateleiras trancadas: aparecem com cadeado, mostrando o que vem por aí.
-- Barracas especiais ganham um painel no topo:
--   * Missões: missão ativa com progresso ou botão "Pegar missão" (com o tempo de espera) e "Abandonar";
--   * Torretas: "Colocar torreta", "Chamar torretas de volta" e a contagem colocadas/máximo;
--   * Crescimento: progresso do Brainrot Supremo e botão para abrir a janela dele.
-- A janela se atualiza sozinha quando o estado muda (moedas, níveis, prateleira...).
--
-- O cliente só PEDE as compras (Net.Request); quem confere e cobra é o servidor.
--
-- API:
--   PromptController.Register("Stall", fn(stallId)) é feito no Init.
--   StallWindow.Open(stallId)   abre a janela de uma barraca (extra)
--   StallWindow.Close()         fecha (extra)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local GameConfig = require(Config:WaitForChild("Game"))
local Maps = require(Config:WaitForChild("Maps"))
local Upgrades = require(Config:WaitForChild("Upgrades"))
local StatsConfig = require(Config:WaitForChild("Stats"))
local Net = require(Util:WaitForChild("Net"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))
local Formulas = require(Util:WaitForChild("Formulas"))
local Trove = require(Util:WaitForChild("Trove"))

local UIKit = require(script.Parent:WaitForChild("UIKit"))
local ControllersFolder = script.Parent.Parent:WaitForChild("Controllers")
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme

local StallWindow = {}

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
-- Constantes de layout e tempo
-------------------------------------------------------------------------------

local WINDOW_NAME = "Stall"
local WINDOW_SIZE = UDim2.fromOffset(800, 590)
local ROW_HEIGHT = 116
local RIGHT_AREA = 250 -- largura da área de custo e botões de cada linha
local TICK_INTERVAL = 0.2 -- atualização da contagem regressiva da missão
local CONFIRM_TIMEOUT = 3 -- tempo para confirmar o "Abandonar"
local MISSING_NAMES_SHOWN = 4 -- quantos nomes de upgrades faltando aparecem no texto

-- Quantidades dos botões de compra.
local BUY_OPTIONS = {
	{ Name = "x1", Text = "x1", Amount = 1 },
	{ Name = "x10", Text = "x10", Amount = 10 },
	{ Name = "Max", Text = "Máx", Amount = "max" },
}

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local window = nil
local currentStall = nil -- id da barraca aberta ("Weapon", "Quest"...)
local builtShelfLevel = nil -- prateleira usada na última montagem
local builtMapId = nil

local listenTrove = Trove.new() -- conexões enquanto a janela está aberta
local contentTrove = Trove.new() -- tudo que a última montagem criou

local rows = {} -- linhas de upgrade: {Def, Frame, Level, Effect, Cost, CostIcon, Buttons, Status, Busy}
local panel = {} -- referências do painel especial (missão, torretas, crescimento)
local unlock = nil -- referências do painel "Melhorar Barraca"
local header = nil -- referências da barra do topo

local pendingFull = false
local pendingCheap = false
local flushQueued = false
local shelfBusy = false

-------------------------------------------------------------------------------
-- Ajudantes de estado
-------------------------------------------------------------------------------

local function num(value, default)
	value = tonumber(value)
	if value == nil or value ~= value then
		return default or 0
	end
	return value
end

local function tableOr(value)
	if type(value) == "table" then
		return value
	end
	return {}
end

-- Mapa atual (Config.Maps[x]) e o id dele.
local function getMap()
	local match = StateController.Get("Match")
	local mapId = type(match) == "table" and match.MapId or nil
	local mapDef = type(mapId) == "string" and Maps[mapId] or nil
	if type(mapDef) == "table" and mapDef.Act ~= nil then
		return mapDef, mapId
	end
	return nil, nil
end

-- A barraca existe no mapa?
local function mapHasStall(mapDef, stallId)
	return type(mapDef) == "table" and type(mapDef.Stalls) == "table" and table.find(mapDef.Stalls, stallId) ~= nil
end

local function getCoins()
	return math.max(0, num(StateController.Get("Coins"), 0))
end

local function getShelfLevel()
	return math.max(1, math.floor(num(StateController.Get("ShelfLevel"), 1)))
end

-- Nível atual de um upgrade no escopo certo (do time ou deste jogador).
local function getLevel(def)
	local levels = if def.Scope == "Team"
		then tableOr(StateController.Get("TeamUpgrades"))
		else tableOr(StateController.Get("PlayerUpgrades"))
	return math.max(0, math.floor(num(levels[def.Id], 0)))
end

-- true se há outros jogadores na lista do time (TeamList).
local function hasTeammates()
	local list = StateController.Get("TeamList")
	if type(list) ~= "table" then
		return false
	end
	for _, entry in ipairs(list) do
		if type(entry) == "table" and entry.UserId ~= Players.LocalPlayer.UserId then
			return true
		end
	end
	return false
end

-- Espelho no cliente de UpgradeService.IsShelfMaxed(shelf): todos os upgrades do mapa
-- (de barracas que existem no mapa) com Shelf <= shelf estão no máximo.
-- O cliente só enxerga os níveis DESTE jogador nos upgrades "Player". Com a regra
-- Config.Game.WeaponMaxRule = "AnyPlayer", basta ALGUÉM do time ter maxado; então um
-- upgrade "Player" que você não maxou não bloqueia o botão quando há outros jogadores
-- no time (o servidor confere de verdade). Jogando sozinho, conta só o seu nível.
-- Devolve (podeTentar, listaDosQueFaltam, listaDosSeusQueTalvezFaltem).
local function computeShelfStatus(shelf)
	local mapDef, mapId = getMap()
	local missing = {} -- faltam com certeza
	local ownMissing = {} -- upgrades "Player" que você não maxou (outro jogador pode ter maxado)
	if not mapDef then
		return false, missing, ownMissing
	end
	local anyPlayerRule = GameConfig.WeaponMaxRule ~= "AllPlayers" and hasTeammates()
	for _, def in ipairs(Upgrades.ByMap[mapId] or {}) do
		if def.Shelf <= shelf and mapHasStall(mapDef, def.Stall) then
			if not Formulas.IsUpgradeMaxed(def, getLevel(def)) then
				if def.Scope ~= "Team" and anyPlayerRule then
					table.insert(ownMissing, def)
				else
					table.insert(missing, def)
				end
			end
		end
	end
	return #missing == 0, missing, ownMissing
end

-- "A, B, C e mais 2" (nomes dos upgrades de uma lista).
local function joinNames(defs)
	local names = {}
	for index, def in ipairs(defs) do
		if index > MISSING_NAMES_SHOWN then
			break
		end
		table.insert(names, def.Name)
	end
	local list = table.concat(names, ", ")
	if #defs > MISSING_NAMES_SHOWN then
		list ..= (" e mais %d"):format(#defs - MISSING_NAMES_SHOWN)
	end
	return list
end

-- Valor que o stat do upgrade teria com "newLevel" (todo o resto igual).
local function previewStat(def, newLevel)
	local match = StateController.Get("Match")
	if type(match) ~= "table" then
		return nil
	end
	local playerLevels = table.clone(tableOr(StateController.Get("PlayerUpgrades")))
	local teamLevels = table.clone(tableOr(StateController.Get("TeamUpgrades")))
	if def.Scope == "Team" then
		teamLevels[def.Id] = newLevel
	else
		playerLevels[def.Id] = newLevel
	end
	local passes = StateController.Get("Gamepasses")
	local ok, stats = pcall(
		Formulas.ComputeStats,
		match.MapId,
		playerLevels,
		teamLevels,
		tableOr(StateController.Get("Recipes")),
		{ DoubleCoins = type(passes) == "table" and passes.DoubleCoins == true }
	)
	if ok and type(stats) == "table" then
		return stats[def.Stat]
	end
	return nil
end

-- Texto (com cores) do efeito: "Dano: 12,2  →  15,3".
local function effectText(def, level)
	local display = StatsConfig.Display[def.Stat]
	local statName = display and display.Name or tostring(def.Stat)
	local format = display and display.Format or "number"
	local stats = StateController.GetStats()
	local current = stats and stats[def.Stat]
	if current == nil then
		return statName
	end
	local currentText = NumberFormat.Stat(current, format)
	local white = Theme.Text:ToHex()
	if level >= def.MaxLevel then
		return ('%s: <font color="#%s">%s</font>'):format(statName, white, currentText)
	end
	local nextValue = previewStat(def, level + 1)
	if nextValue == nil then
		return ('%s: <font color="#%s">%s</font>'):format(statName, white, currentText)
	end
	local nextText = NumberFormat.Stat(nextValue, format)
	if nextText == currentText and math.abs(nextValue - current) < 1e-9 then
		nextText = currentText .. " (limite)"
	end
	return ('%s: <font color="#%s">%s</font>  →  <font color="#%s">%s</font>'):format(
		statName,
		white,
		currentText,
		Theme.Success:ToHex(),
		nextText
	)
end

-------------------------------------------------------------------------------
-- Peças visuais
-------------------------------------------------------------------------------

-- Cadeado desenhado com Frames (argola + corpo + buraco da chave).
local function makeLockIcon(parent, size, color, position, anchor)
	local holder = UIKit.New("Frame", {
		Name = "Lock",
		Size = UDim2.fromOffset(size, size),
		Position = position or UDim2.new(),
		AnchorPoint = anchor or Vector2.zero,
		BackgroundTransparency = 1,
		Parent = parent,
	})
	local shackle = UIKit.New("Frame", {
		Name = "Shackle",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.04),
		Size = UDim2.fromScale(0.54, 0.62),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	UIKit.Corner(shackle, UDim.new(0.5, 0))
	UIKit.Stroke(shackle, math.max(2, math.floor(size * 0.12)), color)
	local body = UIKit.New("Frame", {
		Name = "Body",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(0.86, 0.58),
		BackgroundColor3 = color,
		ZIndex = 2,
		Parent = holder,
	})
	UIKit.Corner(body, UDim.new(0.22, 0))
	local hole = UIKit.New("Frame", {
		Name = "Keyhole",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.16, 0.42),
		BackgroundColor3 = Theme.PanelDark,
		ZIndex = 2,
		Parent = body,
	})
	UIKit.Corner(hole, UDim.new(1, 0))
	return holder
end

-- Moedinha pequena (para os custos).
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

-- Etiqueta "pílula" que cresce com o texto (ex.: "Nv. 3/25", "Time").
local function makeTag(parent, text, color, layoutOrder)
	local tag = UIKit.New("TextLabel", {
		Name = "Tag",
		Text = text,
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color,
		TextSize = 14,
		TextStrokeTransparency = 0.6,
		TextStrokeColor3 = Theme.Stroke,
		LayoutOrder = layoutOrder or 0,
		Parent = parent,
	})
	UIKit.Corner(tag, UDim.new(1, 0))
	UIKit.Padding(tag, { Top = 0, Bottom = 0, Left = 9, Right = 9 })
	return tag
end

-- Painel arredondado com uma faixa colorida à esquerda.
local function makeCard(name, height, accent, layoutOrder)
	local card = UIKit.New("Frame", {
		Name = name,
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.05,
		LayoutOrder = layoutOrder,
	})
	UIKit.Corner(card, 14)
	UIKit.Stroke(card, 2, UIKit.Darken(accent, 0.35))
	local stripe = UIKit.New("Frame", {
		Name = "Stripe",
		Size = UDim2.new(0, 6, 1, -16),
		Position = UDim2.fromOffset(6, 8),
		BackgroundColor3 = accent,
		Parent = card,
	})
	UIKit.Corner(stripe, UDim.new(1, 0))
	return card
end

-- Liga/desliga um botão do UIKit.
local function setEnabled(button, enabled)
	button:SetAttribute("Disabled", not enabled)
end

-------------------------------------------------------------------------------
-- Compras
-------------------------------------------------------------------------------

local refreshAll -- declarada aqui, definida mais abaixo

local function buyUpgrade(row, amount)
	if row.Busy then
		return
	end
	row.Busy = true
	refreshAll(false)

	local ok, result = Net.Request("BuyUpgrade", row.Def.Id, amount)
	row.Busy = false
	if ok then
		UIKit.PlaySound("Purchase")
		if row.Frame.Parent then
			UIKit.Pop(row.Frame, 0.05)
			UIKit.Pop(row.LevelTag, 0.3)
		end
	else
		NotifyController.Show(tostring(result or "Não deu para comprar agora."), "error")
	end
	refreshAll(false)
end

local function buyShelf()
	if shelfBusy then
		return
	end
	shelfBusy = true
	refreshAll(false)
	local ok, result = Net.Request("BuyShelf")
	shelfBusy = false
	if ok then
		UIKit.PlaySound("Purchase")
	else
		NotifyController.Show(tostring(result or "Não deu para melhorar a barraca agora."), "error")
	end
	refreshAll(false)
end

-------------------------------------------------------------------------------
-- Painéis especiais
-------------------------------------------------------------------------------

-- Missões: pegar, acompanhar e abandonar.
local function buildQuestPanel(parent, accent, layoutOrder)
	local card = makeCard("QuestPanel", 150, accent, layoutOrder)
	card.Parent = parent

	UIKit.Label({
		Name = "Title",
		Text = "Sua missão",
		Title = true,
		TextSize = 22,
		Position = UDim2.fromOffset(24, 8),
		Size = UDim2.new(1, -260, 0, 28),
		Color = accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	local text = UIKit.Label({
		Name = "Text",
		Text = "",
		TextSize = 17,
		Position = UDim2.fromOffset(24, 40),
		Size = UDim2.new(1, -260, 0, 44),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = card,
	})
	local bar = UIKit.ProgressBar(card, {
		Name = "Progress",
		Position = UDim2.new(0, 24, 1, -58),
		Size = UDim2.new(1, -260, 0, 24),
		Color = accent,
		TextSize = 15,
	})
	local reward = UIKit.Label({
		Name = "Reward",
		Text = "",
		TextSize = 15,
		Position = UDim2.new(0, 24, 1, -30),
		Size = UDim2.new(1, -260, 0, 22),
		Color = Theme.Coin,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})

	local takeButton = UIKit.Button({
		Name = "Take",
		Text = "Pegar missão",
		Color = Theme.Success,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(210, 58),
		TextSize = 22,
		Parent = card,
	})
	local abandonButton = UIKit.Button({
		Name = "Abandon",
		Text = "Abandonar",
		Color = Theme.Danger,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(210, 50),
		TextSize = 20,
		Parent = card,
	})

	panel.Kind = "Quest"
	panel.Text = text
	panel.Bar = bar
	panel.Reward = reward
	panel.TakeButton = takeButton
	panel.AbandonButton = abandonButton
	panel.Busy = false
	panel.ConfirmUntil = 0

	takeButton.Activated:Connect(function()
		if panel.Busy or takeButton:GetAttribute("Disabled") == true then
			return
		end
		panel.Busy = true
		setEnabled(takeButton, false)
		task.spawn(function()
			local ok, result = Net.Request("TakeQuest")
			panel.Busy = false
			if ok then
				UIKit.PlaySound("Notify")
			else
				NotifyController.Show(tostring(result or "Não deu para pegar a missão agora."), "error")
			end
			refreshAll(false)
		end)
	end)

	-- "Abandonar" pede confirmação: o primeiro clique só pergunta "Certeza?".
	abandonButton.Activated:Connect(function()
		if panel.Busy then
			return
		end
		local now = os.clock()
		if now > panel.ConfirmUntil then
			panel.ConfirmUntil = now + CONFIRM_TIMEOUT
			abandonButton.Text = "Certeza? Clique de novo"
			UIKit.Pop(abandonButton, 0.1)
			return
		end
		panel.ConfirmUntil = 0
		panel.Busy = true
		setEnabled(abandonButton, false)
		task.spawn(function()
			local ok, result = Net.Request("AbandonQuest")
			panel.Busy = false
			if not ok then
				NotifyController.Show(tostring(result or "Não deu para abandonar agora."), "error")
			end
			refreshAll(false)
		end)
	end)
end

-- Atualiza o painel de missões (também chamado pelo relógio, por causa da espera).
local function refreshQuestPanel()
	if panel.Kind ~= "Quest" then
		return
	end
	local quest = StateController.Get("Quest")
	local active = type(quest) == "table" and type(quest.Active) == "table" and quest.Active or nil
	local now = workspace:GetServerTimeNow()

	panel.Bar.Frame.Visible = active ~= nil
	panel.Reward.Visible = active ~= nil
	panel.AbandonButton.Visible = active ~= nil
	panel.TakeButton.Visible = active == nil

	if active then
		local target = math.max(1, num(active.Target, 1))
		local progress = math.clamp(num(active.Progress, 0), 0, target)
		panel.Text.Text = tostring(active.Text or "Missão")
		panel.Bar.Set(progress / target, NumberFormat.Abbrev(math.floor(progress)) .. " / " .. NumberFormat.Abbrev(target))
		panel.Reward.Text = "Recompensa: " .. NumberFormat.Abbrev(num(active.Reward, 0)) .. " moedas"
		if os.clock() > panel.ConfirmUntil then
			panel.AbandonButton.Text = "Abandonar"
		end
		setEnabled(panel.AbandonButton, not panel.Busy)
	else
		local cooldownEnd = type(quest) == "table" and num(quest.CooldownEnd, 0) or 0
		local remaining = cooldownEnd - now
		if remaining > 0 then
			panel.Text.Text = "Descansando... uma missão nova fica pronta em " .. NumberFormat.Time(remaining) .. "."
			panel.TakeButton.Text = "Espere " .. NumberFormat.Time(remaining)
			setEnabled(panel.TakeButton, false)
		else
			panel.Text.Text = "Pegue uma missão aleatória e ganhe um montão de moedas!"
			panel.TakeButton.Text = "Pegar missão"
			setEnabled(panel.TakeButton, not panel.Busy)
		end
	end
end

-- Torretas: colocar, chamar de volta e contagem.
local function buildTurretPanel(parent, accent, layoutOrder)
	local card = makeCard("TurretPanel", 132, accent, layoutOrder)
	card.Parent = parent

	UIKit.Label({
		Name = "Title",
		Text = "Suas torretas",
		Title = true,
		TextSize = 22,
		Position = UDim2.fromOffset(24, 8),
		Size = UDim2.new(0.5, -24, 0, 28),
		Color = accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	local count = UIKit.Label({
		Name = "Count",
		Text = "",
		Title = true,
		TextSize = 22,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 8),
		Size = UDim2.new(0.5, -16, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = card,
	})
	local hint = UIKit.Label({
		Name = "Hint",
		Text = "",
		TextSize = 14,
		Position = UDim2.fromOffset(24, 38),
		Size = UDim2.new(1, -40, 0, 22),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})

	local buttons = UIKit.New("Frame", {
		Name = "Buttons",
		Position = UDim2.new(0, 24, 1, -62),
		Size = UDim2.new(1, -40, 0, 52),
		BackgroundTransparency = 1,
		Parent = card,
	})
	local layout = UIKit.List(buttons, 12, Enum.FillDirection.Horizontal)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	local placeButton = UIKit.Button({
		Name = "Place",
		Text = "Colocar torreta",
		Color = Theme.Info,
		Size = UDim2.new(0.5, -6, 1, 0),
		TextSize = 20,
		LayoutOrder = 1,
		Parent = buttons,
	}, function()
		-- Fecha a janela e entra no modo de colocação (o fantasma verde/vermelho).
		StallWindow.Close()
		local PlacementController = getController("PlacementController")
		if PlacementController and PlacementController.Enter then
			PlacementController.Enter()
		end
	end)

	local recallButton = UIKit.Button({
		Name = "Recall",
		Text = "Chamar torretas de volta",
		Color = Theme.Warning,
		Size = UDim2.new(0.5, -6, 1, 0),
		TextSize = 20,
		LayoutOrder = 2,
		Parent = buttons,
	})

	panel.Kind = "Turret"
	panel.Count = count
	panel.Hint = hint
	panel.PlaceButton = placeButton
	panel.RecallButton = recallButton
	panel.Busy = false

	recallButton.Activated:Connect(function()
		if panel.Busy or recallButton:GetAttribute("Disabled") == true then
			return
		end
		panel.Busy = true
		setEnabled(recallButton, false)
		task.spawn(function()
			local ok, result = Net.Request("RecallTurrets")
			panel.Busy = false
			if ok then
				UIKit.PlaySound("Turret")
				NotifyController.Show("Torretas chamadas de volta para a base!", "success", 3)
			else
				NotifyController.Show(tostring(result or "Não deu para chamar as torretas agora."), "error")
			end
			refreshAll(false)
		end)
	end)
end

local function refreshTurretPanel()
	if panel.Kind ~= "Turret" then
		return
	end
	local turrets = StateController.Get("Turrets")
	local placed = type(turrets) == "table" and math.max(0, math.floor(num(turrets.Placed, 0))) or 0
	local max = type(turrets) == "table" and math.max(0, math.floor(num(turrets.Max, 0))) or 0
	panel.Count.Text = ("%d/%d"):format(placed, max)
	if max <= 0 then
		panel.Hint.Text = "Compre \"Mais Torretas\" aqui embaixo para ganhar a sua primeira torreta!"
		panel.Count.TextColor3 = Theme.TextDim
	elseif placed >= max then
		panel.Hint.Text = "Todas as torretas estão no campo. Recolha uma (segure E nela) para mudar de lugar."
		panel.Count.TextColor3 = Theme.Warning
	else
		panel.Hint.Text = "Coloque torretas no campo: elas atiram sozinhas nos brainrots!"
		panel.Count.TextColor3 = Theme.Success
	end
	setEnabled(panel.PlaceButton, max > 0 and placed < max)
	setEnabled(panel.RecallButton, placed > 0 and not panel.Busy)
end

-- Crescimento: resumo do Brainrot Supremo e atalho para alimentar.
local function buildGrowthPanel(parent, accent, layoutOrder)
	local card = makeCard("GrowthPanel", 132, accent, layoutOrder)
	card.Parent = parent

	UIKit.Label({
		Name = "Title",
		Text = "Brainrot Supremo",
		Title = true,
		TextSize = 22,
		Position = UDim2.fromOffset(24, 8),
		Size = UDim2.new(1, -260, 0, 28),
		Color = accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	local bar = UIKit.ProgressBar(card, {
		Name = "Progress",
		Position = UDim2.fromOffset(24, 44),
		Size = UDim2.new(1, -260, 0, 28),
		Color = Color3.fromRGB(255, 150, 60),
		TextSize = 16,
	})
	local height = UIKit.Label({
		Name = "Height",
		Text = "",
		TextSize = 15,
		Position = UDim2.new(0, 24, 1, -48),
		Size = UDim2.new(1, -260, 0, 36),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = card,
	})
	UIKit.Button({
		Name = "Feed",
		Text = "Alimentar o Supremo",
		Color = Theme.Warning,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(210, 58),
		TextSize = 20,
		Parent = card,
	}, function()
		-- A SupremeWindow registrou a ação "Supreme" no PromptController.
		local PromptController = getController("PromptController")
		if PromptController and PromptController.Dispatch then
			PromptController.Dispatch("Supreme")
		end
	end)

	panel.Kind = "Growth"
	panel.Bar = bar
	panel.Height = height
end

local function refreshGrowthPanel()
	if panel.Kind ~= "Growth" then
		return
	end
	local mapDef = getMap()
	local supreme = StateController.Get("Supreme")
	local progress = type(supreme) == "table" and math.clamp(num(supreme.Progress, 0), 0, 1) or 0
	local height = type(supreme) == "table" and num(supreme.Height, 0) or 0
	panel.Bar.Set(progress, NumberFormat.Percent(progress) .. " do céu")
	local maxHeight = mapDef and mapDef.Supreme and mapDef.Supreme.MaxHeight or nil
	local heightText = "Altura: " .. NumberFormat.Abbrev(height) .. " studs"
	if maxHeight then
		heightText ..= " de " .. NumberFormat.Abbrev(maxHeight)
	end
	panel.Height.Text = heightText .. ". Os upgrades daqui fazem ele crescer mais rápido."
end

-------------------------------------------------------------------------------
-- Linhas de upgrade
-------------------------------------------------------------------------------

local function buildRow(parent, def, accent, layoutOrder)
	local frame = UIKit.New("Frame", {
		Name = def.Id,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.1,
		LayoutOrder = layoutOrder,
		Parent = parent,
	})
	UIKit.Corner(frame, 14)
	UIKit.Stroke(frame, 2, Theme.Stroke)

	local leftWidth = -(RIGHT_AREA + 24)

	-- Nome e etiquetas (escopo e nível).
	UIKit.Label({
		Name = "UpgradeName",
		Text = def.Name,
		Title = true,
		TextSize = 21,
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, leftWidth - 170, 0, 26),
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	local tags = UIKit.New("Frame", {
		Name = "Tags",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -(RIGHT_AREA + 16), 0, 10),
		Size = UDim2.fromOffset(170, 22),
		BackgroundTransparency = 1,
		Parent = frame,
	})
	local tagsLayout = UIKit.List(tags, 6, Enum.FillDirection.Horizontal)
	tagsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	if def.Scope == "Team" then
		makeTag(tags, "Time", Theme.Accent2, 1)
	else
		makeTag(tags, "Só você", Theme.Info, 1)
	end
	local levelTag = makeTag(tags, "", Theme.PanelDark, 2)

	-- Descrição e efeito.
	UIKit.Label({
		Name = "Description",
		Text = def.Description or "",
		TextSize = 14,
		Position = UDim2.fromOffset(16, 36),
		Size = UDim2.new(1, leftWidth, 0, 38),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})
	local effect = UIKit.Label({
		Name = "Effect",
		Text = "",
		TextSize = 16,
		RichText = true,
		Position = UDim2.new(0, 16, 1, -34),
		Size = UDim2.new(1, leftWidth, 0, 24),
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

	-- Área da direita: custo em cima, botões embaixo.
	local right = UIKit.New("Frame", {
		Name = "Buy",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.new(0, RIGHT_AREA, 1, -16),
		BackgroundTransparency = 1,
		Parent = frame,
	})
	local costIcon = makeCoinIcon(right, 24, UDim2.fromOffset(4, 6))
	local cost = UIKit.Label({
		Name = "Cost",
		Text = "",
		Title = true,
		TextSize = 24,
		Position = UDim2.fromOffset(36, 2),
		Size = UDim2.new(1, -40, 0, 32),
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = right,
	})
	local status = UIKit.Label({
		Name = "Status",
		Text = "",
		Title = true,
		TextSize = 22,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 44),
		Visible = false,
		Parent = right,
	})
	local lock = makeLockIcon(right, 30, Theme.Disabled, UDim2.new(0, 2, 0, 4))
	lock.Visible = false

	local buttonRow = UIKit.New("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundTransparency = 1,
		Parent = right,
	})
	local buttonLayout = UIKit.List(buttonRow, 8, Enum.FillDirection.Horizontal)
	buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	local row = {
		Def = def,
		Frame = frame,
		LevelTag = levelTag,
		Effect = effect,
		Cost = cost,
		CostIcon = costIcon,
		Status = status,
		Lock = lock,
		ButtonRow = buttonRow,
		Buttons = {},
		Busy = false,
	}

	for index, option in ipairs(BUY_OPTIONS) do
		row.Buttons[option.Name] = UIKit.Button({
			Name = option.Name,
			Text = option.Text,
			Color = if option.Amount == "max" then Theme.Accent else Theme.Success,
			Size = UDim2.new(1 / #BUY_OPTIONS, -6, 1, 0),
			TextSize = 20,
			LayoutOrder = index,
			Parent = buttonRow,
		}, function(button)
			if button:GetAttribute("Disabled") == true then
				return
			end
			buyUpgrade(row, option.Amount)
		end)
	end

	table.insert(rows, row)
	return row
end

-- Atualiza uma linha. "full" = também recalcula o texto do efeito (mais pesado).
local function refreshRow(row, coins, shelfLevel, full)
	local def = row.Def
	local level = getLevel(def)
	local maxed = level >= def.MaxLevel
	local locked = def.Shelf > shelfLevel

	row.LevelTag.Text = if maxed then "MÁX" else ("Nv. %d/%d"):format(level, def.MaxLevel)
	row.LevelTag.BackgroundColor3 = if maxed then Theme.Rare else Theme.PanelDark
	row.LevelTag.TextColor3 = if maxed then Theme.TextDark else Theme.Text

	if full then
		if locked then
			row.Effect.Text = ('<font color="#%s">Libera na prateleira %d</font>'):format(Theme.TextDim:ToHex(), def.Shelf)
		else
			row.Effect.Text = effectText(def, level)
		end
	end

	row.Frame.BackgroundTransparency = if locked then 0.55 else 0.1
	row.Lock.Visible = locked
	row.CostIcon.Visible = not locked and not maxed

	if locked then
		row.Cost.Text = "Trancado"
		row.Cost.TextColor3 = Theme.Disabled
		row.Cost.Position = UDim2.fromOffset(40, 2)
		row.ButtonRow.Visible = false
		row.Status.Visible = true
		row.Status.Text = "Prateleira " .. def.Shelf
		row.Status.TextColor3 = Theme.TextDim
		return
	end
	row.Cost.Position = UDim2.fromOffset(36, 2)

	if maxed then
		row.Cost.Text = "No máximo!"
		row.Cost.TextColor3 = Theme.Rare
		row.Cost.Position = UDim2.fromOffset(4, 2)
		row.ButtonRow.Visible = false
		row.Status.Visible = true
		row.Status.Text = "Completo"
		row.Status.TextColor3 = Theme.Success
		return
	end

	local nextCost = Formulas.UpgradeCost(def, level)
	local canBuy = coins >= nextCost
	local maxLevels = Formulas.MaxAffordable(def, level, coins)
	row.Cost.Text = NumberFormat.Abbrev(nextCost)
	row.Cost.TextColor3 = if canBuy then Theme.Success else Theme.Danger
	row.ButtonRow.Visible = true
	row.Status.Visible = false

	setEnabled(row.Buttons.x1, canBuy and not row.Busy)
	setEnabled(row.Buttons.x10, canBuy and not row.Busy)
	setEnabled(row.Buttons.Max, maxLevels >= 1 and not row.Busy)
	row.Buttons.Max.Text = if maxLevels >= 1 then ("Máx (%d)"):format(maxLevels) else "Máx"
end

-------------------------------------------------------------------------------
-- Painel "Melhorar Barraca"
-------------------------------------------------------------------------------

local function buildUnlockPanel(parent, accent, nextShelf, layoutOrder)
	local card = makeCard("ShelfUpgrade", 128, accent, layoutOrder)
	card.BackgroundColor3 = Theme.PanelDark
	card.Parent = parent

	local title = UIKit.Label({
		Name = "Title",
		Text = ("Melhorar Barraca (prateleira %d)"):format(nextShelf),
		Title = true,
		TextSize = 22,
		Position = UDim2.fromOffset(24, 8),
		Size = UDim2.new(1, -270, 0, 28),
		Color = Theme.Rare,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	local info = UIKit.Label({
		Name = "Info",
		Text = "",
		TextSize = 14,
		Position = UDim2.fromOffset(24, 40),
		Size = UDim2.new(1, -270, 0, 78),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = card,
	})
	local button = UIKit.Button({
		Name = "BuyShelf",
		Text = "Melhorar",
		Color = Theme.Rare,
		TextColor = Theme.TextDark,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(230, 66),
		TextSize = 22,
		Parent = card,
	}, function(self)
		if self:GetAttribute("Disabled") == true then
			return
		end
		buyShelf()
	end)

	unlock = { Card = card, Title = title, Info = info, Button = button, NextShelf = nextShelf }
end

local function refreshUnlockPanel(coins)
	if not unlock then
		return
	end
	local _, mapId = getMap()
	local shelfLevel = getShelfLevel()
	local ready, missing, ownMissing = computeShelfStatus(shelfLevel)
	local cost = mapId and Formulas.ShelfCost(mapId, unlock.NextShelf) or math.huge
	local canPay = coins >= cost

	if ready and #ownMissing > 0 then
		-- Só faltam upgrades "Só você" que outro jogador do time pode já ter maxado.
		unlock.Info.Text = (
			"Upgrades do time no máximo! Você ainda não maxou: %s. Se alguém do time já maxou, dá para melhorar%s."
		):format(joinNames(ownMissing), if canPay then "" else " (junte " .. NumberFormat.Abbrev(cost) .. " moedas)")
	elseif ready then
		if canPay then
			unlock.Info.Text = ("Tudo no máximo! Libere a prateleira %d em TODAS as barracas, com upgrades novos."):format(
				unlock.NextShelf
			)
		else
			unlock.Info.Text = ("Tudo no máximo! Junte %s moedas para liberar a prateleira %d."):format(
				NumberFormat.Abbrev(cost),
				unlock.NextShelf
			)
		end
	else
		local all = table.clone(missing)
		for _, def in ipairs(ownMissing) do
			table.insert(all, def)
		end
		unlock.Info.Text = ("Deixe no máximo todos os upgrades liberados de todas as barracas. Faltam %d: %s."):format(
			#all,
			joinNames(all)
		)
	end

	unlock.Button.Text = if cost < math.huge then "Melhorar (" .. NumberFormat.Abbrev(cost) .. ")" else "Melhorar"
	unlock.Button.BackgroundColor3 = if ready and canPay then Theme.Rare else Theme.Disabled
	setEnabled(unlock.Button, ready and canPay and not shelfBusy)
end

-------------------------------------------------------------------------------
-- Barra do topo (moedas e prateleira)
-------------------------------------------------------------------------------

local function buildHeader(parent, accent)
	local bar = UIKit.New("Frame", {
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.1,
		LayoutOrder = 0,
		Parent = parent,
	})
	UIKit.Corner(bar, UDim.new(1, 0))
	UIKit.Stroke(bar, 2, UIKit.Darken(accent, 0.3))
	makeCoinIcon(bar, 28, UDim2.new(0, 12, 0.5, 0), Vector2.new(0, 0.5))
	local coins = UIKit.Label({
		Name = "Coins",
		Text = "",
		Title = true,
		TextSize = 24,
		Position = UDim2.fromOffset(48, 0),
		Size = UDim2.new(0.5, -48, 1, 0),
		Color = Theme.Coin,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = bar,
	})
	local shelf = UIKit.Label({
		Name = "Shelf",
		Text = "",
		TextSize = 16,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 0),
		Size = UDim2.new(0.5, -18, 1, 0),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = bar,
	})
	header = { Coins = coins, Shelf = shelf }
end

local function refreshHeader(coins)
	if not header then
		return
	end
	local mapDef = getMap()
	local shelfLevel = getShelfLevel()
	local maxShelf = mapDef and mapDef.MaxShelf or shelfLevel
	header.Coins.Text = NumberFormat.Abbrev(math.floor(coins)) .. " moedas"
	if shelfLevel >= maxShelf then
		header.Shelf.Text = "Barraca no nível máximo!"
		header.Shelf.TextColor3 = Theme.Rare
	else
		local ready, _, ownMissing = computeShelfStatus(shelfLevel)
		local sure = ready and #ownMissing == 0
		header.Shelf.Text = ("Prateleira %d de %d%s"):format(shelfLevel, maxShelf, if sure then " — pronta para melhorar!" else "")
		header.Shelf.TextColor3 = if sure then Theme.Success else Theme.TextDim
	end
end

-------------------------------------------------------------------------------
-- Montagem e atualização da janela
-------------------------------------------------------------------------------

-- Pinta o cabeçalho da janela com a cor da barraca.
local function tintWindow(color)
	local frame = window and window.Frame
	if not frame then
		return
	end
	local sequence = ColorSequence.new(color, UIKit.Darken(color, 0.35))
	local headerFrame = frame:FindFirstChild("Header")
	if headerFrame then
		local gradient = headerFrame:FindFirstChildOfClass("UIGradient")
		if gradient then
			gradient.Color = sequence
		end
		local fill = headerFrame:FindFirstChild("HeaderFill")
		local fillGradient = fill and fill:FindFirstChildOfClass("UIGradient")
		if fillGradient then
			fillGradient.Color = sequence
		end
	end
end

-- Seleciona o primeiro botão (controle) se a seleção atual sumiu na remontagem.
local function reselectForGamepad()
	if not window or not window.IsOpen() then
		return
	end
	if not string.match(UserInputService:GetLastInputType().Name, "^Gamepad") then
		return
	end
	local selected = GuiService.SelectedObject
	if selected and selected.Parent and selected:IsDescendantOf(window.Gui) then
		return
	end
	for _, descendant in ipairs(window.Content:GetDescendants()) do
		if descendant:IsA("GuiButton") and descendant.Visible and descendant.Selectable then
			pcall(function()
				GuiService.SelectedObject = descendant
			end)
			return
		end
	end
end

-- Monta todo o conteúdo da barraca aberta (chamado ao abrir e quando a prateleira muda).
local function rebuild()
	contentTrove:Clean()
	table.clear(rows)
	table.clear(panel)
	unlock = nil
	header = nil

	local content = window.Content
	local mapDef, mapId = getMap()
	local stallDef = Upgrades.Stalls[currentStall]
	if not mapDef or not stallDef then
		return
	end
	local accent = stallDef.Color or Theme.Accent
	local shelfLevel = getShelfLevel()
	local maxShelf = mapDef.MaxShelf or 1
	builtShelfLevel = shelfLevel
	builtMapId = mapId

	-- Tudo fica dentro de um "holder" (limpar = destruir ele).
	local holder = UIKit.New("Frame", {
		Name = "StallContent",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = content,
	})
	contentTrove:Add(holder)
	UIKit.Padding(holder, { Top = 4, Bottom = 12, Left = 2, Right = 6 })
	UIKit.List(holder, 10)

	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	buildHeader(holder, accent)

	-- Painel especial da barraca.
	if currentStall == "Quest" then
		buildQuestPanel(holder, accent, nextOrder())
	elseif currentStall == "Turret" then
		buildTurretPanel(holder, accent, nextOrder())
	elseif currentStall == "Growth" then
		buildGrowthPanel(holder, accent, nextOrder())
	end

	-- Upgrades desta barraca, agrupados por prateleira (na ordem do Config).
	local byShelf = {}
	for _, def in ipairs(Upgrades.ByMap[mapId] or {}) do
		if def.Stall == currentStall then
			byShelf[def.Shelf] = byShelf[def.Shelf] or {}
			table.insert(byShelf[def.Shelf], def)
		end
	end

	local function buildShelfHeader(shelf, locked)
		local bar = UIKit.New("Frame", {
			Name = "Shelf" .. shelf,
			Size = UDim2.new(1, 0, 0, 38),
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
			Parent = holder,
		})
		UIKit.Label({
			Name = "Title",
			Text = "Prateleira " .. shelf,
			Title = true,
			TextSize = 24,
			Position = UDim2.fromOffset(if locked then 40 else 6, 0),
			Size = UDim2.new(0.6, 0, 1, -6),
			Color = if locked then Theme.TextDim else UIKit.Lighten(accent, 0.25),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = bar,
		})
		if locked then
			makeLockIcon(bar, 26, Theme.TextDim, UDim2.new(0, 6, 0.5, -3), Vector2.new(0, 0.5))
		end
		local statusText
		if not locked then
			statusText = "Liberada"
		elseif shelf == shelfLevel + 1 then
			statusText = "Trancada: custa " .. NumberFormat.Abbrev(Formulas.ShelfCost(mapId, shelf))
		else
			statusText = ("Trancada: libere a prateleira %d antes"):format(shelf - 1)
		end
		UIKit.Label({
			Name = "Status",
			Text = statusText,
			TextSize = 15,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 0),
			Size = UDim2.new(0.4, 0, 1, -6),
			Color = if locked then Theme.TextDim else Theme.Success,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = bar,
		})
		local line = UIKit.New("Frame", {
			Name = "Line",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 3),
			BackgroundColor3 = if locked then Theme.Disabled else accent,
			Parent = bar,
		})
		UIKit.Corner(line, UDim.new(1, 0))
	end

	-- Prateleiras liberadas.
	for shelf = 1, math.min(shelfLevel, maxShelf) do
		local defs = byShelf[shelf]
		if defs and #defs > 0 then
			buildShelfHeader(shelf, false)
			for _, def in ipairs(defs) do
				buildRow(holder, def, accent, nextOrder())
			end
		end
	end

	-- Botão de melhorar a barraca (vale para todas as barracas do mapa).
	if shelfLevel < maxShelf then
		buildUnlockPanel(holder, accent, shelfLevel + 1, nextOrder())
	else
		local done = UIKit.Label({
			Name = "AllShelves",
			Text = "Todas as prateleiras liberadas! Maxe tudo para concluir o ato.",
			TextSize = 16,
			Size = UDim2.new(1, 0, 0, 30),
			Color = Theme.Rare,
			LayoutOrder = nextOrder(),
			Parent = holder,
		})
		done.TextStrokeTransparency = 0.5
	end

	-- Prateleiras trancadas (mostram o que vem por aí).
	for shelf = shelfLevel + 1, maxShelf do
		local defs = byShelf[shelf]
		if defs and #defs > 0 then
			buildShelfHeader(shelf, true)
			for _, def in ipairs(defs) do
				buildRow(holder, def, accent, nextOrder())
			end
		end
	end

	-- Barraca sem nenhum upgrade neste mapa (não deveria acontecer, mas fica bonito).
	if #rows == 0 then
		UIKit.Label({
			Name = "Empty",
			Text = "Esta barraca não tem upgrades neste mapa.",
			TextSize = 17,
			Size = UDim2.new(1, 0, 0, 40),
			Color = Theme.TextDim,
			LayoutOrder = nextOrder(),
			Parent = holder,
		})
	end
end

-- Atualiza tudo em cima dos objetos já criados. full = recalcula também os efeitos.
function refreshAll(full)
	if not window or not currentStall then
		return
	end
	local _, mapId = getMap()
	if getShelfLevel() ~= builtShelfLevel or mapId ~= builtMapId then
		-- A prateleira (ou o mapa) mudou: monta tudo de novo.
		rebuild()
		full = true
		task.defer(reselectForGamepad)
	end

	local coins = getCoins()
	local shelfLevel = getShelfLevel()
	refreshHeader(coins)
	for _, row in ipairs(rows) do
		refreshRow(row, coins, shelfLevel, full)
	end
	refreshUnlockPanel(coins)
	refreshQuestPanel()
	refreshTurretPanel()
	refreshGrowthPanel()
end

-- Junta várias mudanças no mesmo quadro numa atualização só.
local function scheduleRefresh(full)
	if full then
		pendingFull = true
	else
		pendingCheap = true
	end
	if flushQueued then
		return
	end
	flushQueued = true
	task.defer(function()
		flushQueued = false
		local doFull = pendingFull
		local doAny = pendingFull or pendingCheap
		pendingFull = false
		pendingCheap = false
		if doAny and window and window.IsOpen() then
			refreshAll(doFull)
		end
	end)
end

-- Liga os "ouvintes" enquanto a janela está aberta.
local function startListening()
	listenTrove:Clean()
	local function cheap()
		scheduleRefresh(false)
	end
	local function full()
		scheduleRefresh(true)
	end
	listenTrove:Add(StateController.OnChanged("Coins", cheap))
	listenTrove:Add(StateController.OnChanged("Quest", cheap))
	listenTrove:Add(StateController.OnChanged("Turrets", cheap))
	listenTrove:Add(StateController.OnChanged("Supreme", cheap))
	listenTrove:Add(StateController.OnChanged("TeamList", cheap)) -- quem está no time (regra do "Melhorar Barraca")
	listenTrove:Add(StateController.OnChanged("PlayerUpgrades", full))
	listenTrove:Add(StateController.OnChanged("TeamUpgrades", full))
	listenTrove:Add(StateController.OnChanged("ShelfLevel", full))
	listenTrove:Add(StateController.OnChanged("Match", full))
	listenTrove:Add(StateController.StatsChanged:Connect(full))

	-- Relógio da contagem regressiva da missão (e do "Certeza?" do Abandonar).
	local accumulator = 0
	listenTrove:Connect(RunService.Heartbeat, function(dt)
		accumulator += dt
		if accumulator >= TICK_INTERVAL then
			accumulator = 0
			refreshQuestPanel()
		end
	end)
end

local function ensureWindow()
	if window then
		return window
	end
	window = UIKit.Window(WINDOW_NAME, "Barraca", WINDOW_SIZE)
	window.OnOpen:Connect(startListening)
	window.OnClose:Connect(function()
		listenTrove:Clean()
	end)
	return window
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Abre a janela de uma barraca ("Weapon", "Brainrot", "Quest", "Turret", "Growth").
function StallWindow.Open(stallId)
	if type(stallId) ~= "string" or stallId == "" then
		return
	end
	local mapDef = getMap()
	if not mapDef then
		NotifyController.Show("A partida ainda está carregando. Tente de novo em instantes.", "warning", 3)
		return
	end
	local stallDef = Upgrades.Stalls[stallId]
	if not stallDef or not mapHasStall(mapDef, stallId) then
		NotifyController.Show("Essa barraca não existe neste mapa.", "error", 3)
		return
	end

	ensureWindow()
	currentStall = stallId
	window.SetTitle(stallDef.Name)
	tintWindow(stallDef.Color or Theme.Accent)
	rebuild()
	refreshAll(true)
	window.Content.CanvasPosition = Vector2.zero
	if window.IsOpen() then
		task.defer(reselectForGamepad)
	else
		window.Open()
	end
end

function StallWindow.Close()
	if window then
		window.Close()
	end
end

-- true se a janela está aberta.
function StallWindow.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function StallWindow.Init()
	-- Balcões das barracas: ClientAction "Stall:<id>" chega aqui como ("Stall", id).
	local PromptController = getController("PromptController")
	if PromptController and PromptController.Register then
		PromptController.Register("Stall", function(stallId)
			StallWindow.Open(stallId)
		end)
	else
		warn("[StallWindow] PromptController não encontrado; os balcões não vão abrir a janela.")
	end
end

function StallWindow.Start() end

-- Deixa as funções do módulo funcionarem com "." e também com ":".
for name, fn in pairs(StallWindow) do
	if type(fn) == "function" then
		StallWindow[name] = function(first, ...)
			if first == StallWindow then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return StallWindow
