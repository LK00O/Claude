-- LobbyShop (lobby): a Loja. Tem duas abas:
--
-- Aba "Skins" (skins de arma, pagas com Brainrot Tokens):
--   Mostra os Tokens do jogador (Profile.Tokens) e um cartão para cada skin de
--   Config.Cosmetics.Skins, com uma prévia desenhada da arma (cor da arma e do rastro
--   da bala; a skin Arco-íris fica mudando de cor), o nome, o preço e um botão:
--     "Equipada" (já está em uso), "Equipar" (já tem), "Comprar" (dá para pagar)
--     ou "Faltam N" (não tem tokens suficientes).
--   Comprar pede BuyCosmetic e, dando certo, já equipa (EquipCosmetic).
--   Quem confere o preço e desconta os tokens é o servidor (ShopService).
--
-- Aba "Vantagens" (game passes, pagos com Robux):
--   Um cartão para cada pass à venda (Shared/Util/Gamepasses: Config.Game.Gamepasses
--   com Enabled = true e id > 0) com nome, descrição, preço em Robux (lido do Roblox com
--   Gamepasses.FetchSaleInfo: "..." enquanto carrega, some se falhar) e o botão "Comprar"
--   (Request "BuyGamepass", que abre a janela de compra do Roblox), "Já é seu!" ou
--   "Indisponível" (o pass foi tirado de venda no Creator Hub).
--   Quem ativa o pass é o servidor (MonetizationService): quando a compra termina, o
--   estado "Gamepasses" muda e o botão vira "Já é seu!".
--   Se nenhum pass está à venda, as abas nem aparecem (a janela vira só a Loja de Skins).
--
-- Aberta pelo LobbyUI (botão lateral e prompt "Shop"). Recebe o LobbyUI no Init.
-- LobbyShop.Open("Passes") abre direto na aba Vantagens; Open("Skins") na aba de skins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Cosmetics = require(Config:WaitForChild("Cosmetics"))
local Trove = require(Util:WaitForChild("Trove"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))
local Net = require(Util:WaitForChild("Net"))
local Gamepasses = require(Util:WaitForChild("Gamepasses"))

local UIFolder = script.Parent
local ControllersFolder = UIFolder.Parent:WaitForChild("Controllers")
local UIKit = require(UIFolder:WaitForChild("UIKit"))
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme

local LobbyShop = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

local WINDOW_NAME = "LobbyShop"
local WINDOW_SIZE = UDim2.fromOffset(780, 600)
local CARD_SIZE = UDim2.fromOffset(226, 268)
local CARD_PADDING = 14
local PREVIEW_HEIGHT = 112
local RAINBOW_SPEED = 90 -- graus por segundo que o degradê arco-íris gira

-- Abas (só aparecem quando há game passes à venda).
local TABS = {
	{ Id = "Skins", Text = "Skins" },
	{ Id = "Passes", Text = "Vantagens" },
}
local TAB_SIZE = UDim2.fromOffset(240, 46)
local PASS_CARD_MIN_HEIGHT = 104 -- o cartão do pass cresce sozinho se a descrição for longa
local PASS_BUTTON_SIZE = UDim2.fromOffset(170, 52)

-- Cores do arco-íris (skins com Rainbow = true).
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 70, 70)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 170, 40)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 240, 70)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(80, 230, 110)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(80, 160, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 90, 255)),
})

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local Lobby = nil -- o módulo LobbyUI (recebido no Init)
local window = nil
local ui = nil
local listenTrove = Trove.new()
local cards = {} -- [skinId] = cartão
local rainbowGradients = {} -- UIGradients que giram (skins arco-íris)
local busy = false
local currentTab = "Skins" -- aba aberta: "Skins" ou "Passes"
local passRows = {} -- cartões dos game passes: {Key, Button, Price, Sale, Loading}
local passBusy = false -- true enquanto o pedido de compra de um pass não voltou

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

-- Parte "Cosmetics" do perfil: {Owned = {[id] = true}, Equipped = id}.
local function getCosmetics()
	local cosmetics = Lobby.GetProfile().Cosmetics
	if type(cosmetics) == "table" then
		return cosmetics
	end
	return { Owned = { Classic = true }, Equipped = "Classic" }
end

local function isOwned(skin)
	local owned = getCosmetics().Owned
	if (tonumber(skin.Price) or 0) <= 0 then
		return true -- skins grátis todo mundo já tem
	end
	return type(owned) == "table" and owned[skin.Id] == true
end

local function isEquipped(skin)
	local equipped = getCosmetics().Equipped
	if type(equipped) ~= "string" then
		equipped = "Classic"
	end
	return equipped == skin.Id
end

local function priceText(price)
	price = tonumber(price) or 0
	if price <= 0 then
		return "Grátis"
	end
	return NumberFormat.Commas(price) .. (price == 1 and " Token" or " Tokens")
end

-------------------------------------------------------------------------------
-- Ações
-------------------------------------------------------------------------------

local function onSkinButton(skin)
	if busy then
		return
	end
	if isEquipped(skin) then
		NotifyController.Show(("A skin %s já está equipada."):format(skin.Name), "info", 2.5)
		return
	end

	busy = true
	if isOwned(skin) then
		local ok = Lobby.Request("EquipCosmetic", skin.Id)
		if ok then
			NotifyController.Show(("Skin %s equipada!"):format(skin.Name), "success", 3)
		end
	else
		local price = tonumber(skin.Price) or 0
		local tokens = Lobby.GetTokens()
		if tokens < price then
			NotifyController.Show(
				("Faltam %s para a skin %s. Ganhe tokens concluindo atos e conquistas!"):format(
					priceText(price - tokens),
					skin.Name
				),
				"warning",
				4
			)
			UIKit.PlaySound("Error")
		else
			local ok = Lobby.Request("BuyCosmetic", skin.Id)
			if ok then
				UIKit.PlaySound("Purchase")
				-- Comprou: já equipa para o jogador ver a skin nova na próxima partida.
				local equipped = Lobby.Request("EquipCosmetic", skin.Id)
				if equipped then
					NotifyController.Show(("Skin %s comprada e equipada!"):format(skin.Name), "success", 4)
				else
					NotifyController.Show(("Skin %s comprada!"):format(skin.Name), "success", 4)
				end
				local card = cards[skin.Id]
				if card then
					UIKit.Pop(card.Frame, 0.08)
				end
			end
		end
	end
	busy = false
end

-- true se o jogador já tem o pass (estado "Gamepasses" que o servidor manda).
local function ownsPass(key)
	local passes = StateController.Get("Gamepasses")
	return type(passes) == "table" and passes[key] == true
end

local refresh -- declarada aqui porque buyPass chama e é definida mais abaixo

-- Pede ao servidor para abrir a janela de compra do Roblox (Request "BuyGamepass").
-- Quem ativa o pass é o servidor, quando a compra termina: aí o estado "Gamepasses"
-- muda e o botão vira "Já é seu!".
local function buyPass(key)
	if passBusy or ownsPass(key) then
		return
	end
	passBusy = true
	refresh()
	local ok, result = Net.Request("BuyGamepass", key)
	passBusy = false
	refresh()
	if not ok then
		Lobby.ShowError(type(result) == "string" and result or "Não deu para abrir a compra agora.")
	end
end

-------------------------------------------------------------------------------
-- Atualização
-------------------------------------------------------------------------------

-- Cartão de cada pass: preço ("..." enquanto carrega; some se não deu para ler) e o
-- botão: "Comprar", "Abrindo...", "Já é seu!" ou "Indisponível".
local function refreshPasses()
	for _, row in ipairs(passRows) do
		local sale = row.Sale -- {IsForSale, Price} do Roblox, ou nil (carregando / falhou)
		if ownsPass(row.Key) then
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
			row.Button.Text = if passBusy then "Abrindo..." else "Comprar"
			row.Button.BackgroundColor3 = Theme.Success
			row.Button:SetAttribute("Disabled", passBusy)
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
-- guarda o resultado por id). O que falhou tenta de novo na próxima vez que a loja abrir.
local function loadPassPrices()
	for _, row in ipairs(passRows) do
		if not row.Sale and not row.Loading then
			row.Loading = true
			task.spawn(function()
				row.Sale = Gamepasses.FetchSaleInfo(row.Key)
				row.Loading = false
				refreshPasses()
			end)
		end
	end
	refreshPasses()
end

-- Mostra a aba escolhida e pinta o botão dela.
local function refreshTabs()
	if not ui.TabButtons then
		return -- sem passes à venda: não há abas, só a página de skins
	end
	for _, tab in ipairs(TABS) do
		Lobby.SetSelected(ui.TabButtons[tab.Id], tab.Id == currentTab, tab.Id == "Passes" and Theme.Rare or Theme.Accent)
		if tab.Id == currentTab and tab.Id == "Passes" then
			ui.TabButtons[tab.Id].TextColor3 = Theme.TextDark -- texto escuro no botão dourado
		end
	end
	ui.SkinsPage.Visible = currentTab == "Skins"
	ui.PassesPage.Visible = currentTab == "Passes"
end

function refresh()
	if not ui then
		return
	end
	refreshTabs()
	refreshPasses()

	local tokens = Lobby.GetTokens()
	ui.Tokens.Text = NumberFormat.Commas(tokens) .. (tokens == 1 and " Brainrot Token" or " Brainrot Tokens")

	local ownedCount = 0
	for _, skin in ipairs(Cosmetics.Skins) do
		local card = cards[skin.Id]
		if card then
			local owned = isOwned(skin)
			local equipped = isEquipped(skin)
			if owned then
				ownedCount += 1
			end

			card.Stroke.Color = equipped and Theme.Success or Theme.PanelDark
			card.Stroke.Thickness = equipped and 4 or 2
			card.EquippedTag.Visible = equipped

			local price = tonumber(skin.Price) or 0
			if equipped then
				card.Button.Text = "Equipada"
				card.Button.BackgroundColor3 = Theme.Disabled
				card.Price.Text = "Em uso"
				card.Price.TextColor3 = Theme.Success
			elseif owned then
				card.Button.Text = "Equipar"
				card.Button.BackgroundColor3 = Theme.Accent2
				card.Price.Text = "Você já tem"
				card.Price.TextColor3 = Theme.TextDim
			elseif tokens >= price then
				card.Button.Text = "Comprar"
				card.Button.BackgroundColor3 = Theme.Success
				card.Price.Text = priceText(price)
				card.Price.TextColor3 = Theme.Rare
			else
				card.Button.Text = "Faltam " .. NumberFormat.Commas(price - tokens)
				card.Button.BackgroundColor3 = Theme.Danger
				card.Price.Text = priceText(price)
				card.Price.TextColor3 = Theme.Danger
			end
		end
	end
	ui.Owned.Text = ("Skins: %d/%d"):format(ownedCount, #Cosmetics.Skins)
	task.defer(Lobby.FixSelection, window)
end

-------------------------------------------------------------------------------
-- Montagem
-------------------------------------------------------------------------------

-- Pinta uma parte da prévia: cor normal ou degradê arco-íris que gira.
local function paint(part, color, rainbow)
	if rainbow then
		part.BackgroundColor3 = Color3.new(1, 1, 1)
		local gradient = UIKit.New("UIGradient", { Color = RAINBOW, Parent = part })
		table.insert(rainbowGradients, gradient)
		return gradient
	end
	part.BackgroundColor3 = color
	return nil
end

-- Desenha a arma da skin (corpo, cano, cabo) e o rastro da bala.
local function buildPreview(parent, skin)
	local preview = UIKit.New("Frame", {
		Name = "Preview",
		Size = UDim2.new(1, 0, 0, PREVIEW_HEIGHT),
		BackgroundColor3 = Theme.PanelDark,
		ClipsDescendants = true,
		Parent = parent,
	})
	UIKit.Corner(preview, 12)

	local gunColor = typeof(skin.GunColor) == "Color3" and skin.GunColor or Theme.Disabled
	local tracerColor = typeof(skin.TracerColor) == "Color3" and skin.TracerColor or Theme.Rare
	local rainbow = skin.Rainbow == true

	-- Rastro da bala: some aos poucos para a direita.
	local tracer = UIKit.New("Frame", {
		Name = "Tracer",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0.32, 84, 0.36, 0),
		Size = UDim2.fromOffset(90, 6),
		Parent = preview,
	})
	UIKit.Corner(tracer, UDim.new(1, 0))
	local tracerGradient = paint(tracer, tracerColor, rainbow)
	if not tracerGradient then
		tracerGradient = UIKit.New("UIGradient", { Parent = tracer })
	end
	tracerGradient.Transparency = NumberSequence.new(0, 1)

	-- Cano.
	local barrel = UIKit.New("Frame", {
		Name = "Barrel",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0.32, 40, 0.36, 0),
		Size = UDim2.fromOffset(46, 14),
		Parent = preview,
	})
	UIKit.Corner(barrel, 4)
	UIKit.Stroke(barrel, 2, Theme.Stroke)
	paint(barrel, UIKit.Darken(gunColor, 0.15), rainbow)

	-- Cabo (um pouco inclinado).
	local handle = UIKit.New("Frame", {
		Name = "Handle",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.32, -22, 0.42, 4),
		Size = UDim2.fromOffset(24, 42),
		Rotation = 14,
		Parent = preview,
	})
	UIKit.Corner(handle, 6)
	UIKit.Stroke(handle, 2, Theme.Stroke)
	paint(handle, UIKit.Darken(gunColor, 0.3), rainbow)

	-- Corpo da arma.
	local body = UIKit.New("Frame", {
		Name = "Body",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.32, 0.42),
		Size = UDim2.fromOffset(96, 32),
		ZIndex = 2,
		Parent = preview,
	})
	UIKit.Corner(body, 9)
	UIKit.Stroke(body, 2.5, Theme.Stroke)
	paint(body, gunColor, rainbow)
	-- Brilho em cima do corpo.
	local shine = UIKit.New("Frame", {
		Name = "Shine",
		Position = UDim2.fromOffset(8, 5),
		Size = UDim2.new(1, -16, 0, 6),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.55,
		ZIndex = 3,
		Parent = body,
	})
	UIKit.Corner(shine, UDim.new(1, 0))

	return preview
end

local function buildCard(parent, skin, order)
	local card = UIKit.New("Frame", {
		Name = skin.Id,
		Size = CARD_SIZE,
		BackgroundColor3 = Theme.PanelLight,
		LayoutOrder = order,
		Parent = parent,
	})
	UIKit.Corner(card, 16)
	local stroke = UIKit.Stroke(card, 2, Theme.PanelDark)
	UIKit.Padding(card, 8)

	buildPreview(card, skin)

	local equippedTag = Lobby.Tag({
		Name = "Equipped",
		Text = "Equipada",
		Color = Theme.Success,
		Height = 22,
		TextSize = 13,
		Position = UDim2.fromOffset(6, 6),
		Visible = false,
		Parent = card,
	})
	equippedTag.ZIndex = 4

	UIKit.Label({
		Name = "SkinName",
		Text = skin.Name,
		Title = true,
		TextSize = 22,
		Position = UDim2.fromOffset(4, PREVIEW_HEIGHT + 8),
		Size = UDim2.new(1, -8, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	local price = UIKit.Label({
		Name = "Price",
		Text = priceText(skin.Price),
		TextSize = 16,
		Color = Theme.Rare,
		Position = UDim2.fromOffset(4, PREVIEW_HEIGHT + 38),
		Size = UDim2.new(1, -8, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	local button = UIKit.Button({
		Name = "Action",
		Text = "",
		Color = Theme.Success,
		Size = UDim2.new(1, 0, 0, 46),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		TextSize = 20,
		Parent = card,
	}, function()
		onSkinButton(skin)
	end)

	return { Frame = card, Stroke = stroke, EquippedTag = equippedTag, Price = price, Button = button }
end

-- Uma página (conteúdo de uma aba), que cresce com o que tem dentro.
local function makePage(parent, name, order)
	local page = UIKit.New("Frame", {
		Name = name,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = order,
		Parent = parent,
	})
	local layout = UIKit.List(page, 10)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	return page
end

-- Cartão de um game pass: nome, descrição, preço e botão de compra.
local function buildPassCard(parent, pass, order)
	local card = UIKit.New("Frame", {
		Name = pass.Key,
		Size = UDim2.new(1, 0, 0, PASS_CARD_MIN_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.PanelLight,
		LayoutOrder = order,
		Parent = parent,
	})
	UIKit.Corner(card, 16)
	UIKit.Stroke(card, 2.5, pass.Color)
	-- Espaço embaixo da descrição quando o cartão cresce.
	UIKit.Padding(card, { Top = 0, Bottom = 12, Left = 0, Right = 0 })

	-- Pílula colorida ao lado do nome, na cor do pass.
	local pill = UIKit.New("Frame", {
		Name = "Pill",
		Position = UDim2.fromOffset(14, 13),
		Size = UDim2.fromOffset(8, 26),
		BackgroundColor3 = pass.Color,
		Parent = card,
	})
	UIKit.Corner(pill, UDim.new(1, 0))

	UIKit.Label({
		Name = "PassName",
		Text = pass.Name,
		Title = true,
		TextSize = 24,
		Color = pass.Color,
		Position = UDim2.fromOffset(32, 10),
		Size = UDim2.new(1, -(PASS_BUTTON_SIZE.X.Offset + 60), 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	UIKit.Label({
		Name = "Description",
		Text = pass.Description,
		TextSize = 15,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(32, 44),
		Size = UDim2.new(1, -(PASS_BUTTON_SIZE.X.Offset + 60), 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = card,
	})
	-- Preço (lido do Roblox, nunca escrito no código) em cima do botão.
	local price = UIKit.Label({
		Name = "Price",
		Text = "...",
		Title = true,
		TextSize = 20,
		Color = Theme.Rare,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 10),
		Size = UDim2.fromOffset(PASS_BUTTON_SIZE.X.Offset, 24),
		Parent = card,
	})
	local button = UIKit.Button({
		Name = "Buy",
		Text = "Comprar",
		Color = Theme.Success,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 38),
		Size = PASS_BUTTON_SIZE,
		TextSize = 21,
		Parent = card,
	}, function()
		buyPass(pass.Key)
	end)

	return { Key = pass.Key, Button = button, Price = price }
end

-- Página "Vantagens": um cartão para cada pass à venda.
local function buildPassesPage(page)
	local intro = Lobby.Section(page, nil, 0)
	UIKit.Label({
		Name = "Hint",
		Text = "Vantagens compradas com Robux são suas para sempre. Elas valem em todas as partidas, e o VIP já aparece aqui no lobby.",
		TextSize = 15,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Parent = intro,
	})
	for index, pass in ipairs(Gamepasses.List) do
		-- Pass sem id (0) ainda não está à venda: nem aparece.
		if Gamepasses.IsForSale(pass.Key) then
			table.insert(passRows, buildPassCard(page, pass, index))
		end
	end
end

local function setTab(tabId)
	if currentTab == tabId or not ui or not ui.TabButtons then
		return
	end
	currentTab = tabId
	refresh()
	if window then
		window.Content.CanvasPosition = Vector2.zero
	end
end

local function build()
	-- Com game passes à venda a janela vira "Loja" com duas abas; sem, só skins.
	local showPasses = Gamepasses.AnyForSale()
	window = UIKit.Window(WINDOW_NAME, showPasses and "Loja" or "Loja de Skins", WINDOW_SIZE)
	local content = window.Content
	Lobby.PrepareContent(content)
	ui = {}

	if showPasses then
		ui.TabButtons = {}
		local tabsRow = Lobby.Row(content, 50, 0, 10, Enum.HorizontalAlignment.Center)
		for index, tab in ipairs(TABS) do
			ui.TabButtons[tab.Id] = UIKit.Button({
				Name = tab.Id,
				Text = tab.Text,
				Size = TAB_SIZE,
				LayoutOrder = index,
				TextSize = 22,
				Parent = tabsRow,
			}, function()
				setTab(tab.Id)
			end)
		end
		ui.PassesPage = makePage(content, "PassesPage", 2)
		buildPassesPage(ui.PassesPage)
	else
		currentTab = "Skins"
	end
	ui.SkinsPage = makePage(content, "SkinsPage", 1)
	local skinsPage = ui.SkinsPage

	-- Topo: tokens do jogador.
	local top = Lobby.Section(skinsPage, nil, 1)
	local topRow = UIKit.New("Frame", {
		Name = "Top",
		Size = UDim2.new(1, 0, 0, 48),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = top,
	})
	local coin = UIKit.New("TextLabel", {
		Name = "Coin",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(44, 44),
		BackgroundColor3 = Theme.Rare,
		Text = "T",
		Font = Theme.TitleFont,
		TextSize = 26,
		TextColor3 = Theme.TextDark,
		Parent = topRow,
	})
	UIKit.Corner(coin, UDim.new(1, 0))
	UIKit.Stroke(coin, 3, UIKit.Darken(Theme.Rare, 0.4))
	ui.Tokens = UIKit.Label({
		Name = "Tokens",
		Text = "",
		Title = true,
		TextSize = 28,
		Color = Theme.Rare,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 56, 0.5, 0),
		Size = UDim2.new(1, -210, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = topRow,
	})
	ui.Owned = UIKit.Label({
		Name = "Owned",
		Text = "",
		TextSize = 16,
		Color = Theme.TextDim,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(150, 24),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = topRow,
	})
	UIKit.Label({
		Name = "Hint",
		Text = "Ganhe tokens concluindo atos e conquistas. A skin muda a cor da arma e do rastro das balas.",
		TextSize = 14,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = top,
	})

	-- Grade de skins.
	local grid = UIKit.New("Frame", {
		Name = "Grid",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = skinsPage,
	})
	UIKit.Grid(grid, CARD_SIZE, CARD_PADDING)
	for index, skin in ipairs(Cosmetics.Skins) do
		cards[skin.Id] = buildCard(grid, skin, index)
	end
end

-- Escuta mudanças enquanto a janela está aberta (e gira o arco-íris).
local function startListening()
	listenTrove:Clean()
	listenTrove:Add(StateController.OnChanged("Profile", function()
		refresh()
	end))
	-- Comprou um pass (ou a posse foi conferida na entrada): troca o botão para "Já é seu!".
	listenTrove:Add(StateController.OnChanged("Gamepasses", function()
		refresh()
	end))
	if #rainbowGradients > 0 then
		local angle = 0
		listenTrove:Connect(RunService.Heartbeat, function(dt)
			angle = (angle + dt * RAINBOW_SPEED) % 360
			for _, gradient in ipairs(rainbowGradients) do
				gradient.Rotation = angle
			end
		end)
	end
end

local function ensureWindow()
	if window then
		return
	end
	build()
	window.OnOpen:Connect(startListening)
	window.OnOpen:Connect(loadPassPrices)
	window.OnClose:Connect(function()
		listenTrove:Clean()
	end)
end

-------------------------------------------------------------------------------
-- API
-------------------------------------------------------------------------------

-- Abre a loja. arg = "Passes" abre direto na aba Vantagens; "Skins" na aba de skins
-- (sem arg, fica na última aba usada).
function LobbyShop.Open(arg)
	if not getLobby() then
		return
	end
	ensureWindow()
	if (arg == "Passes" and ui.TabButtons) or arg == "Skins" then
		currentTab = arg
	end
	refresh()
	if not window.IsOpen() then
		window.Content.CanvasPosition = Vector2.zero
		window.Open()
	end
end

function LobbyShop.Close()
	if window then
		window.Close()
	end
end

function LobbyShop.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function LobbyShop.Init(lobby)
	if type(lobby) == "table" and lobby.GetPartyState then
		Lobby = lobby
	else
		getLobby()
	end
end

function LobbyShop.Start() end

return LobbyShop
