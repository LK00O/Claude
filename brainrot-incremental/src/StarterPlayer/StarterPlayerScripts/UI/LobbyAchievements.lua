-- LobbyAchievements (lobby): a janela "Conquistas e Estatísticas".
--
-- Aba "Conquistas": todas as conquistas de Config.Achievements com nome, descrição,
-- recompensa em tokens, data em que foi desbloqueada (Profile.Achievements[id] = os.time())
-- ou o progresso (conquistas de estatística, ex.: 340/1.000). Conquistas secretas ainda
-- não desbloqueadas ficam escondidas: aparecem só como "???" (sem nome, descrição nem prêmio).
-- Aba "Estatísticas": os números do perfil (Profile.Stats): brainrots destruídos por tier,
-- moedas totais, tiros, críticos, tempo jogado, atos concluídos, receitas etc.
--
-- Aberta pelo LobbyUI (botão lateral e prompt "Achievements"). Recebe o LobbyUI no Init.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Achievements = require(Config:WaitForChild("Achievements"))
local Brainrots = require(Config:WaitForChild("Brainrots"))
local Recipes = require(Config:WaitForChild("Recipes"))
local Maps = require(Config:WaitForChild("Maps"))
local Trove = require(Util:WaitForChild("Trove"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))

local UIFolder = script.Parent
local ControllersFolder = UIFolder.Parent:WaitForChild("Controllers")
local UIKit = require(UIFolder:WaitForChild("UIKit"))
local StateController = require(ControllersFolder:WaitForChild("StateController"))

local Theme = UIKit.Theme

local LobbyAchievements = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

local WINDOW_NAME = "LobbyAchievements"
local WINDOW_SIZE = UDim2.fromOffset(800, 600)
local CARD_HEIGHT = 92
local RIGHT_AREA_WIDTH = 190
local TILE_SIZE = UDim2.fromOffset(234, 82)
local TILE_PADDING = 10

local TABS = {
	{ Id = "Achievements", Text = "Conquistas" },
	{ Id = "Stats", Text = "Estatísticas" },
}

-- Cores dos tiers (do Config.Brainrots), com um padrão se faltar.
local function tierColor(tier)
	local def = Brainrots.Tiers and Brainrots.Tiers[tier]
	return def and def.Color or Theme.Accent
end

local function tierName(tier)
	local def = Brainrots.Tiers and Brainrots.Tiers[tier]
	return def and def.Name or tier
end

-- Quadradinhos da aba Estatísticas. Path = caminho em Profile.Stats (com ponto).
-- Format: "count" (padrão), "coins" (abreviado) ou "time" (segundos -> horas/minutos).
local STAT_TILES = {
	{ Name = "Brainrots destruídos", Path = "KillsTotal", Color = Theme.Accent },
	{ Name = "Tier " .. tierName("Low"), Path = "Kills.Low", Color = tierColor("Low") },
	{ Name = "Tier " .. tierName("Medium"), Path = "Kills.Medium", Color = tierColor("Medium") },
	{ Name = "Tier " .. tierName("High"), Path = "Kills.High", Color = tierColor("High") },
	{ Name = "Moedas coletadas", Path = "TotalCoins", Format = "coins", Color = Theme.Coin },
	{ Name = "Tempo jogado", Path = "PlayTime", Format = "time", Color = Theme.Info },
	{ Name = "Tiros disparados", Path = "Shots", Color = Theme.Accent2 },
	{ Name = "Acertos críticos", Path = "Crits", Color = Theme.Danger },
	{ Name = "Explosões em cadeia", Path = "Chains", Color = Theme.Warning },
	{ Name = "Gigantes destruídos", Path = "Giants", Color = Color3.fromRGB(120, 220, 160) },
	{ Name = "Encantados destruídos", Path = "Enchanted", Color = Color3.fromRGB(255, 130, 220) },
	{ Name = "Galácticos destruídos", Path = "Galactic", Color = Color3.fromRGB(170, 140, 255) },
	{ Name = "Missões concluídas", Path = "QuestsCompleted", Color = Theme.Warning },
	{ Name = "Receitas descobertas", Path = "RecipesDiscovered", Max = #Recipes.Recipes, Color = Theme.Success },
	{ Name = "Atos concluídos", Path = "ActsCompleted", Color = Theme.Rare },
}

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local Lobby = nil -- o módulo LobbyUI (recebido no Init)
local window = nil
local ui = nil
local listenTrove = Trove.new()
local pageTrove = Trove.new() -- o que a última montagem das páginas criou
local currentTab = "Achievements"

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Pega o LobbyUI mesmo se o Init não tiver recebido (require dentro de função).
local function getLobby()
	if Lobby == nil then
		local module = UIFolder:FindFirstChild("LobbyUI")
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				Lobby = result
			end
		end
	end
	return Lobby
end

-- Lê um número de Profile.Stats por caminho com ponto ("Kills.Low").
local function readStat(stats, path)
	local current = stats
	for key in string.gmatch(path, "[^%.]+") do
		if type(current) ~= "table" then
			return 0
		end
		current = current[key]
	end
	return tonumber(current) or 0
end

-- Número inteiro com pontos (abreviado se for enorme).
local function formatCount(value)
	value = tonumber(value) or 0
	if math.abs(value) >= 1e6 then
		return NumberFormat.Abbrev(value)
	end
	return NumberFormat.Commas(value)
end

-- Segundos jogados -> "3h 05min", "12 min" ou "40 s".
local function formatPlayTime(seconds)
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if hours > 0 then
		return ("%dh %02dmin"):format(hours, minutes)
	elseif minutes > 0 then
		return ("%d min"):format(minutes)
	end
	return ("%d s"):format(seconds)
end

local function tokensText(amount)
	amount = tonumber(amount) or 0
	return ("+%d %s"):format(amount, amount == 1 and "token" or "tokens")
end

-------------------------------------------------------------------------------
-- Aba Conquistas
-------------------------------------------------------------------------------

local function buildAchievementCard(parent, def, unlockedAt, profile, order)
	local unlocked = unlockedAt ~= nil
	local hidden = def.Secret == true and not unlocked

	local card = UIKit.New("Frame", {
		Name = def.Id,
		Size = UDim2.new(1, 0, 0, CARD_HEIGHT),
		BackgroundColor3 = unlocked and UIKit.Darken(Theme.Rare, 0.72) or Theme.PanelLight,
		BackgroundTransparency = 0.05,
		LayoutOrder = order,
		Parent = parent,
	})
	UIKit.Corner(card, 14)
	UIKit.Stroke(card, unlocked and 3 or 2, unlocked and Theme.Rare or Theme.PanelDark)

	-- Medalha: estrela dourada (desbloqueada), apagada (trancada) ou "?" (secreta).
	local medal = UIKit.New("TextLabel", {
		Name = "Medal",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.5, 0),
		Size = UDim2.fromOffset(58, 58),
		BackgroundColor3 = unlocked and Theme.Rare or Theme.PanelDark,
		Text = hidden and "?" or "★",
		Font = Theme.TitleFont,
		TextSize = 32,
		TextColor3 = unlocked and Theme.TextDark or Theme.TextDim,
		Parent = card,
	})
	UIKit.Corner(medal, UDim.new(1, 0))
	UIKit.Stroke(medal, 3, unlocked and UIKit.Darken(Theme.Rare, 0.4) or Theme.Stroke)

	UIKit.Label({
		Name = "AchievementName",
		Text = hidden and "???" or tostring(def.Name or def.Id),
		Title = true,
		TextSize = 21,
		Color = unlocked and Theme.Rare or Theme.Text,
		Position = UDim2.fromOffset(86, 10),
		Size = UDim2.new(1, -(86 + RIGHT_AREA_WIDTH + 16), 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = card,
	})
	UIKit.Label({
		Name = "Description",
		Text = hidden and "Conquista secreta. Continue jogando para descobrir!" or tostring(def.Description or ""),
		TextSize = 14,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(86, 38),
		Size = UDim2.new(1, -(86 + RIGHT_AREA_WIDTH + 16), 0, 44),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = card,
	})

	-- Área da direita: prêmio + data ou progresso.
	local right = UIKit.New("Frame", {
		Name = "Right",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.new(0, RIGHT_AREA_WIDTH, 1, -16),
		BackgroundTransparency = 1,
		Parent = card,
	})
	if not hidden then
		Lobby.Tag({
			Name = "Reward",
			Text = tokensText(def.Tokens),
			Color = Theme.Rare,
			TextColor = Theme.TextDark,
			Height = 24,
			TextSize = 14,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Parent = right,
		})
	end

	if unlocked then
		local dateText = type(unlockedAt) == "number" and ("Desbloqueada em " .. Lobby.FormatDate(unlockedAt))
			or "Desbloqueada!"
		UIKit.Label({
			Name = "Date",
			Text = dateText,
			TextSize = 13,
			Color = Theme.Success,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.new(1, 0, 0, 34),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = right,
		})
	elseif hidden then
		UIKit.Label({
			Name = "Secret",
			Text = "Secreta",
			TextSize = 14,
			Color = Theme.TextDim,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.new(1, 0, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = right,
		})
	elseif type(def.Stat) == "string" then
		-- Conquista de estatística: barra com o progresso.
		local threshold = math.max(1, tonumber(def.Threshold) or 1)
		local value = readStat(profile.Stats, def.Stat)
		local bar = UIKit.ProgressBar(right, {
			Name = "Progress",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.new(1, 0, 0, 24),
			Color = Theme.Accent,
			TextSize = 14,
		})
		bar.Set(math.min(1, value / threshold), ("%s/%s"):format(formatCount(math.min(value, threshold)), formatCount(threshold)), true)
	else
		-- Conquista de evento (completar mapa, jogar com amigos).
		local text = "Ainda não conseguiu"
		if def.Event == "CompleteMap" then
			text = "Conclua o mapa"
		elseif def.Event == "PlayWithFriends" then
			text = ("Jogue com %d amigos"):format(tonumber(def.Count) or 0)
		end
		UIKit.Label({
			Name = "Status",
			Text = text,
			TextSize = 13,
			Color = Theme.TextDim,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.fromScale(1, 1),
			Size = UDim2.new(1, 0, 0, 34),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = right,
		})
	end

	return card
end

local function buildAchievementsPage(page, profile)
	local unlockedMap = type(profile.Achievements) == "table" and profile.Achievements or {}

	local total = #Achievements.List
	local unlockedCount = 0
	for _, def in ipairs(Achievements.List) do
		if unlockedMap[def.Id] ~= nil then
			unlockedCount += 1
		end
	end

	-- Resumo no topo.
	local summary = Lobby.Section(page, nil, 1)
	pageTrove:Add(summary)
	UIKit.Label({
		Name = "Summary",
		Text = ("Desbloqueadas: %d de %d"):format(unlockedCount, total),
		Title = true,
		TextSize = 24,
		Size = UDim2.new(1, 0, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Parent = summary,
	})
	local bar = UIKit.ProgressBar(summary, {
		Name = "Total",
		Size = UDim2.new(1, 0, 0, 24),
		Color = Theme.Rare,
		LayoutOrder = 2,
	})
	bar.Set(total > 0 and unlockedCount / total or 0, NumberFormat.Percent(total > 0 and unlockedCount / total or 0, 0), true)
	UIKit.Label({
		Name = "Hint",
		Text = "Cada conquista dá Brainrot Tokens para gastar na Loja.",
		TextSize = 14,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 3,
		Parent = summary,
	})

	-- Cartões (na ordem do Config).
	for index, def in ipairs(Achievements.List) do
		pageTrove:Add(buildAchievementCard(page, def, unlockedMap[def.Id], profile, index + 1))
	end
end

-------------------------------------------------------------------------------
-- Aba Estatísticas
-------------------------------------------------------------------------------

local function buildTile(parent, name, valueText, color, order)
	local tile = UIKit.New("Frame", {
		Name = "Tile",
		BackgroundColor3 = Theme.PanelLight,
		LayoutOrder = order,
		Parent = parent,
	})
	UIKit.Corner(tile, 12)
	UIKit.Stroke(tile, 2, Theme.PanelDark)
	local stripe = UIKit.New("Frame", {
		Name = "Stripe",
		Size = UDim2.new(0, 8, 1, 0),
		BackgroundColor3 = color or Theme.Accent,
		Parent = tile,
	})
	UIKit.Corner(stripe, 12)
	UIKit.Label({
		Name = "StatName",
		Text = name,
		TextSize = 14,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(18, 8),
		Size = UDim2.new(1, -26, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = tile,
	})
	local value = UIKit.Label({
		Name = "Value",
		Text = valueText,
		Title = true,
		TextSize = 28,
		Color = UIKit.Lighten(color or Theme.Text, 0.35),
		Position = UDim2.fromOffset(18, 32),
		Size = UDim2.new(1, -26, 0, 36),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		Parent = tile,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 28, MinTextSize = 12, Parent = value })
	return tile
end

local function buildStatsPage(page, profile)
	local stats = type(profile.Stats) == "table" and profile.Stats or {}

	-- Progresso da aventura (mapas concluídos e fim do jogo).
	local journey = Lobby.Section(page, "Sua aventura", 1)
	pageTrove:Add(journey)
	local mapsRow = Lobby.Row(journey, 30, 1, 8)
	local completedCount = 0
	for index, mapId in ipairs(Maps.Order) do
		local def = Lobby.GetMapDef(mapId)
		if def then
			local completed = Lobby.IsMapCompleted(mapId)
			local unlocked = Lobby.IsMapUnlocked(mapId)
			if completed then
				completedCount += 1
			end
			local status = completed and "concluído" or (unlocked and "liberado" or "trancado")
			Lobby.Tag({
				Name = mapId,
				Text = ("%s: %s"):format(def.DisplayName, status),
				Color = completed and Lobby.GetMapColor(mapId) or (unlocked and Theme.PanelLight or Theme.PanelDark),
				Height = 28,
				TextSize = 14,
				LayoutOrder = index,
				Parent = mapsRow,
			})
		end
	end
	UIKit.Label({
		Name = "Ending",
		Text = profile.GameCompleted == true and "Você tampou o sol com o Brainrot Supremo. Jogo concluído!"
			or ("Mapas concluídos: %d de %d. O final espera no Deserto..."):format(completedCount, #Maps.Order),
		TextSize = 15,
		Color = profile.GameCompleted == true and Theme.Rare or Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = journey,
	})

	-- Grade de números.
	local grid = UIKit.New("Frame", {
		Name = "Grid",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = page,
	})
	pageTrove:Add(grid)
	UIKit.Grid(grid, TILE_SIZE, TILE_PADDING)

	for index, tileDef in ipairs(STAT_TILES) do
		local value = readStat(stats, tileDef.Path)
		local text
		if tileDef.Format == "time" then
			text = formatPlayTime(value)
		elseif tileDef.Format == "coins" then
			text = NumberFormat.Abbrev(value)
		else
			text = formatCount(value)
		end
		if tileDef.Max then
			text ..= "/" .. tostring(tileDef.Max)
		end
		buildTile(grid, tileDef.Name, text, tileDef.Color, index)
	end
	buildTile(grid, "Brainrot Tokens", formatCount(Lobby.GetTokens()), Theme.Rare, #STAT_TILES + 1)
end

-------------------------------------------------------------------------------
-- Atualização
-------------------------------------------------------------------------------

local function refresh()
	if not ui then
		return
	end
	pageTrove:Clean()
	local profile = Lobby.GetProfile()

	for _, tab in ipairs(TABS) do
		local button = ui.TabButtons[tab.Id]
		Lobby.SetSelected(button, tab.Id == currentTab, tab.Id == "Achievements" and Theme.Rare or Theme.Info)
		if tab.Id == currentTab and tab.Id == "Achievements" then
			button.TextColor3 = Theme.TextDark
		end
	end

	ui.AchievementsPage.Visible = currentTab == "Achievements"
	ui.StatsPage.Visible = currentTab == "Stats"
	if currentTab == "Achievements" then
		buildAchievementsPage(ui.AchievementsPage, profile)
	else
		buildStatsPage(ui.StatsPage, profile)
	end
	task.defer(Lobby.FixSelection, window)
end

local function setTab(tabId)
	if currentTab == tabId then
		return
	end
	currentTab = tabId
	refresh()
	if window then
		window.Content.CanvasPosition = Vector2.zero
	end
end

-------------------------------------------------------------------------------
-- Montagem
-------------------------------------------------------------------------------

local function build()
	window = UIKit.Window(WINDOW_NAME, "Conquistas e Estatísticas", WINDOW_SIZE)
	local content = window.Content
	Lobby.PrepareContent(content)
	ui = { TabButtons = {} }

	-- Abas.
	local tabsRow = Lobby.Row(content, 50, 1, 10, Enum.HorizontalAlignment.Center)
	for index, tab in ipairs(TABS) do
		ui.TabButtons[tab.Id] = UIKit.Button({
			Name = tab.Id,
			Text = tab.Text,
			Size = UDim2.fromOffset(240, 46),
			LayoutOrder = index,
			TextSize = 22,
			Parent = tabsRow,
		}, function()
			setTab(tab.Id)
		end)
	end

	-- Páginas (o conteúdo é montado no refresh).
	local function page(name, order)
		local frame = UIKit.New("Frame", {
			Name = name,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Parent = content,
		})
		UIKit.List(frame, 8)
		return frame
	end
	ui.AchievementsPage = page("AchievementsPage", 2)
	ui.StatsPage = page("StatsPage", 3)
end

-- Escuta mudanças enquanto a janela está aberta.
local function startListening()
	listenTrove:Clean()
	listenTrove:Add(StateController.OnChanged("Profile", function()
		refresh()
	end))
end

local function ensureWindow()
	if window then
		return
	end
	build()
	window.OnOpen:Connect(startListening)
	window.OnClose:Connect(function()
		listenTrove:Clean()
	end)
end

-------------------------------------------------------------------------------
-- API
-------------------------------------------------------------------------------

-- Abre a janela. arg = "Stats" abre direto na aba de estatísticas.
function LobbyAchievements.Open(arg)
	if not getLobby() then
		return
	end
	ensureWindow()
	if arg == "Stats" or arg == "Achievements" then
		currentTab = arg
	end
	refresh()
	if not window.IsOpen() then
		window.Content.CanvasPosition = Vector2.zero
		window.Open()
	end
end

function LobbyAchievements.Close()
	if window then
		window.Close()
	end
end

function LobbyAchievements.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function LobbyAchievements.Init(lobby)
	if type(lobby) == "table" and lobby.GetPartyState then
		Lobby = lobby
	else
		getLobby()
	end
end

function LobbyAchievements.Start() end

return LobbyAchievements
