-- CauldronWindow (partida, Deserto): o Caldeirão e o Livro de Receitas.
--
-- Aba "Caldeirão":
--   * inventário de ingredientes (estado "Ingredients" = {[ingredientId] = quantidade},
--     nomes e cores em Config.Recipes.Ingredients); tocar num ingrediente joga ele no caldeirão;
--   * 3 espaços do caldeirão (tocar num espaço cheio devolve o ingrediente);
--   * prévia: se a combinação é uma receita que o jogador JÁ CONHECE (Profile.RecipesKnown),
--     mostra nome, efeito e custo (verde se dá para pagar, vermelho se não). Se não conhece,
--     mostra "Combinação misteriosa..." (não entrega se é receita ou não);
--   * botão "Cozinhar!" -> Net.Request("Craft", {ids}). O servidor confere tudo, cobra e
--     avisa todo mundo; aqui só comemoramos (bolhas + nome da receita).
-- Aba "Livro de Receitas": todas as receitas de Config.Recipes. Conhecidas mostram nome,
--   ingredientes, efeito (Description), tipo e custo, com o botão "Colocar no caldeirão".
--   Desconhecidas mostram "???" e a dica (Hint).
--
-- Abre pelo prompt do caldeirão (ClientAction "Cauldron") e pelo botão do HUD (Dispatch("Cauldron")).
-- API extra: CauldronWindow.Open(tab?) com tab = "Book" para abrir no Livro; Close(); IsOpen().

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Recipes = require(Config:WaitForChild("Recipes"))
local Maps = require(Config:WaitForChild("Maps"))
local Net = require(Util:WaitForChild("Net"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))
local Trove = require(Util:WaitForChild("Trove"))

local UIFolder = script.Parent
local ControllersFolder = UIFolder.Parent:WaitForChild("Controllers")
local UIKit = require(UIFolder:WaitForChild("UIKit"))
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme

local CauldronWindow = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

local WINDOW_NAME = "Cauldron"
local WINDOW_SIZE = UDim2.fromOffset(820, 620)
local SLOT_COUNT = 3 -- espaços do caldeirão (toda receita usa 2 ou 3 ingredientes)
local MIN_INGREDIENTS = 2
local TICK_INTERVAL = 0.5 -- atualização do tempo dos efeitos ativos (s)
local PAGE_HEIGHT = 440 -- altura da aba Caldeirão
local INGREDIENT_CELL = UDim2.fromOffset(160, 92)
local SLOT_SIZE = 100
local BUBBLE_COUNT = 10

local CAULDRON_COLOR = Color3.fromRGB(58, 44, 70) -- panela
local BREW_COLOR = Color3.fromRGB(120, 230, 120) -- caldo verde borbulhante

-- Texto e cor de cada tipo de receita.
local KIND_INFO = {
	Permanent = { Text = "Permanente", Color = Theme.Accent2 },
	Timed = { Text = "Temporária", Color = Theme.Info },
	Instant = { Text = "Na hora", Color = Theme.Warning },
}

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local window = nil
local ui = nil
local currentTab = "Cauldron"
local slots = {} -- [1..3] = ingredientId ou nil
local crafting = false
local listenTrove = Trove.new() -- conexões enquanto a janela está aberta
local bookTrove = Trove.new() -- cartões do Livro (remontados quando o livro muda)
local bookDirty = true

-------------------------------------------------------------------------------
-- Ajudantes de estado
-------------------------------------------------------------------------------

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

local function tableOr(value)
	if type(value) == "table" then
		return value
	end
	return {}
end

-- Mapa atual (Config.Maps[x]) ou nil.
local function getMapDef()
	local match = StateController.Get("Match")
	local mapId = type(match) == "table" and match.MapId or nil
	local def = type(mapId) == "string" and Maps[mapId] or nil
	if type(def) == "table" and def.Act ~= nil then
		return def
	end
	return nil
end

-- O caldeirão funciona neste mapa?
local function mapHasRecipes()
	local def = getMapDef()
	return def ~= nil and def.HasRecipes == true
end

-- Multiplicador de custo das receitas: o do mapa atual (ou o do mapa que tem receitas).
local function getCostScale()
	local def = getMapDef()
	if def and def.HasRecipes then
		return tonumber(def.CostScale) or 1
	end
	for _, mapId in ipairs(Maps.Order) do
		local other = Maps[mapId]
		if type(other) == "table" and other.HasRecipes then
			return tonumber(other.CostScale) or 1
		end
	end
	return 1
end

local function recipeCost(recipe)
	return (tonumber(recipe.CoinCost) or 0) * getCostScale()
end

local function getCoins()
	return math.max(0, tonumber(StateController.Get("Coins")) or 0)
end

local function getInventory()
	return tableOr(StateController.Get("Ingredients"))
end

local function getKnown()
	local profile = StateController.Get("Profile")
	return tableOr(type(profile) == "table" and profile.RecipesKnown or nil)
end

local function getActive()
	return tableOr(StateController.Get("Recipes"))
end

-- Quantos de cada ingrediente estão nos espaços do caldeirão.
local function slotCounts()
	local counts = {}
	local total = 0
	for index = 1, SLOT_COUNT do
		local id = slots[index]
		if id then
			counts[id] = (counts[id] or 0) + 1
			total += 1
		end
	end
	return counts, total
end

-- Quantos desse ingrediente ainda sobram no inventário (fora os do caldeirão).
local function available(ingredientId)
	local counts = slotCounts()
	return math.max(0, math.floor(tonumber(getInventory()[ingredientId]) or 0) - (counts[ingredientId] or 0))
end

-- Receita com exatamente esses ingredientes (ou nil).
local function matchRecipe(counts)
	for _, recipe in ipairs(Recipes.Recipes) do
		local same = true
		for id, count in pairs(recipe.Ingredients) do
			if counts[id] ~= count then
				same = false
				break
			end
		end
		if same then
			for id, count in pairs(counts) do
				if recipe.Ingredients[id] ~= count then
					same = false
					break
				end
			end
		end
		if same then
			return recipe
		end
	end
	return nil
end

-- Tira dos espaços os ingredientes que o jogador não tem mais (ex.: gastou numa receita).
local function validateSlots()
	local inventory = getInventory()
	local used = {}
	for index = 1, SLOT_COUNT do
		local id = slots[index]
		if id then
			used[id] = (used[id] or 0) + 1
			if used[id] > (tonumber(inventory[id]) or 0) then
				slots[index] = nil
				used[id] -= 1
			end
		end
	end
end

-- Iniciais do nome para o ícone ("Areia Mística" -> "AM"; ignora palavras minúsculas como "de").
local function initialsOf(name)
	local letters = {}
	for word in string.gmatch(tostring(name), "%S+") do
		local first = string.match(word, "^[\1-\127\194-\244][\128-\191]*") or ""
		if first ~= "" and not string.match(first, "^%l") then
			table.insert(letters, first)
			if #letters >= 2 then
				break
			end
		end
	end
	return table.concat(letters)
end

-- Texto escuro em cores claras, texto branco em cores escuras.
local function textColorFor(color)
	local luminance = 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
	return luminance > 0.62 and Theme.TextDark or Theme.Text
end

-- "2× Espresso Assassino + 1× Areia Mística"
local function ingredientsText(recipe)
	local parts = {}
	for _, ingredient in ipairs(Recipes.Ingredients) do
		local count = recipe.Ingredients[ingredient.Id]
		if count then
			table.insert(parts, ("%d× %s"):format(count, ingredient.Name))
		end
	end
	return table.concat(parts, " + ")
end

-------------------------------------------------------------------------------
-- Peças visuais
-------------------------------------------------------------------------------

-- Bolinha colorida do ingrediente (com brilho e as iniciais).
local function ingredientIcon(parent, ingredient, size, props)
	local color = typeof(ingredient.Color) == "Color3" and ingredient.Color or Theme.Accent
	local icon = UIKit.New("Frame", {
		Name = "Icon",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = color,
	})
	for key, value in pairs(props or {}) do
		icon[key] = value
	end
	UIKit.Corner(icon, UDim.new(1, 0))
	UIKit.Stroke(icon, math.max(2, size * 0.06), UIKit.Darken(color, 0.5))
	local shine = UIKit.New("Frame", {
		Name = "Shine",
		Position = UDim2.fromScale(0.18, 0.14),
		Size = UDim2.fromScale(0.3, 0.3),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.45,
		Parent = icon,
	})
	UIKit.Corner(shine, UDim.new(1, 0))
	local label = UIKit.New("TextLabel", {
		Name = "Initials",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = initialsOf(ingredient.Name),
		Font = Theme.TitleFont,
		TextScaled = true,
		TextColor3 = textColorFor(color),
		Parent = icon,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = math.floor(size * 0.42), MinTextSize = 8, Parent = label })
	UIKit.Padding(label, math.floor(size * 0.18))
	icon.Parent = parent
	return icon
end

-- Etiqueta em forma de pílula.
local function pill(parent, text, color, order, textColor)
	local tag = UIKit.New("TextLabel", {
		Name = "Tag",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		BackgroundColor3 = color,
		Text = text,
		Font = Theme.ButtonFont,
		TextSize = 14,
		TextColor3 = textColor or Theme.Text,
		LayoutOrder = order or 0,
		Parent = parent,
	})
	UIKit.Corner(tag, UDim.new(1, 0))
	UIKit.Padding(tag, { Top = 0, Bottom = 0, Left = 10, Right = 10 })
	UIKit.Stroke(tag, 1.5, UIKit.Darken(color, 0.45))
	return tag
end

-- Deixa um botão de aba com cara de escolhido ou não.
local function setTabLook(button, selected)
	button.BackgroundColor3 = selected and Theme.Accent or Theme.PanelLight
	button.TextColor3 = selected and Theme.Text or Theme.TextDim
end

-------------------------------------------------------------------------------
-- Aba Caldeirão: atualização
-------------------------------------------------------------------------------

local function refreshInventory()
	local inventory = getInventory()
	local total = 0
	for _, ingredient in ipairs(Recipes.Ingredients) do
		local cell = ui.IngredientCells[ingredient.Id]
		if cell then
			local have = math.max(0, math.floor(tonumber(inventory[ingredient.Id]) or 0))
			local free = available(ingredient.Id)
			total += have
			cell.Count.Text = "x" .. NumberFormat.Commas(free)
			cell.Count.TextColor3 = free > 0 and Theme.Text or Theme.TextDim
			cell.Button.BackgroundColor3 = free > 0 and Theme.PanelLight or Theme.PanelDark
			cell.Icon.BackgroundTransparency = free > 0 and 0 or 0.55
		end
	end
	if total == 0 then
		ui.InventoryHint.Text = "Você ainda não tem ingredientes. Brainrots do deserto às vezes deixam cair alguns!"
	else
		ui.InventoryHint.Text = "Toque num ingrediente para jogar no caldeirão."
	end
end

local function refreshSlots()
	for index = 1, SLOT_COUNT do
		local slot = ui.Slots[index]
		local id = slots[index]
		if slot.ShownId ~= id then
			slot.ShownId = id
			slot.Holder:ClearAllChildren()
			local ingredient = id and Recipes.IngredientsById[id]
			if ingredient then
				ingredientIcon(slot.Holder, ingredient, 62, {
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.new(0.5, 0, 0, 4),
				})
				UIKit.Label({
					Name = "IngredientName",
					Text = ingredient.Name,
					TextSize = 12,
					AnchorPoint = Vector2.new(0.5, 1),
					Position = UDim2.new(0.5, 0, 1, -2),
					Size = UDim2.new(1, 4, 0, 24),
					TextScaled = true,
					Parent = slot.Holder,
				})
			else
				UIKit.Label({
					Name = "Empty",
					Text = "+",
					Title = true,
					TextSize = 40,
					Color = Theme.TextDim,
					Size = UDim2.fromScale(1, 1),
					Parent = slot.Holder,
				})
			end
		end
	end
end

local function refreshPreview()
	local counts, total = slotCounts()
	local coins = getCoins()
	local hasRecipes = mapHasRecipes()
	ui.Coins.Text = "Suas moedas: " .. NumberFormat.Abbrev(coins)

	local title, description, costText = "", "", ""
	local titleColor, costColor = Theme.Text, Theme.TextDim
	local canCraft = hasRecipes and total >= MIN_INGREDIENTS and not crafting
	local craftText = crafting and "Cozinhando..." or "Cozinhar!"

	if total == 0 then
		title = "Caldeirão vazio"
		description = "Coloque 2 ou 3 ingredientes. Cada combinação certa vira uma receita poderosa para o time!"
	else
		local recipe = matchRecipe(counts)
		local known = recipe and getKnown()[recipe.Id] == true
		if recipe and known then
			local cost = recipeCost(recipe)
			title = recipe.Name
			titleColor = Theme.Rare
			description = tostring(recipe.Description or "")
			if recipe.Kind == "Permanent" and getActive()[recipe.Id] == true then
				costText = "Essa receita já está ativa nesta partida!"
				costColor = Theme.Danger
				canCraft = false
			else
				local affordable = coins >= cost
				costText = "Custo: " .. NumberFormat.Abbrev(cost) .. " moedas"
				costColor = affordable and Theme.Success or Theme.Danger
				if not affordable then
					canCraft = false
					craftText = "Moedas insuficientes"
				end
			end
		else
			title = "Combinação misteriosa..."
			titleColor = Theme.Accent
			if total < MIN_INGREDIENTS then
				description = "Coloque pelo menos 2 ingredientes."
			else
				description =
					"Você não conhece essa mistura. Se for uma receita, ela vai direto para o seu Livro de Receitas!"
			end
			costText = "Custo: ???"
		end
	end

	if not hasRecipes then
		craftText = "Só no Deserto"
		canCraft = false
		costText = "O caldeirão só funciona no Deserto Sahur."
		costColor = Theme.Warning
	end

	ui.PreviewTitle.Text = title
	ui.PreviewTitle.TextColor3 = titleColor
	ui.PreviewText.Text = description
	ui.PreviewCost.Text = costText
	ui.PreviewCost.TextColor3 = costColor
	ui.CraftButton.Text = craftText
	ui.CraftButton.BackgroundColor3 = canCraft and Theme.Success or Theme.Disabled
	ui.CraftButton:SetAttribute("Disabled", not canCraft)
	ui.ClearButton.Visible = total > 0
end

-- Efeitos ativos das receitas (encantamento por tempo, próxima leva gigante).
local function refreshBuffs()
	local buffs = tableOr(StateController.Get("Buffs"))
	local parts = {}
	local enchantUntil = tonumber(buffs.TimedEnchantUntil) or 0
	local remaining = enchantUntil - workspace:GetServerTimeNow()
	if remaining > 0 then
		table.insert(parts, "Todo brainrot encantado: " .. NumberFormat.Time(remaining))
	end
	if buffs.NextWaveGiant == true then
		table.insert(parts, "A próxima leva nasce gigante!")
	end
	local active = getActive()
	local activeCount = 0
	for _, recipe in ipairs(Recipes.Recipes) do
		if active[recipe.Id] == true then
			activeCount += 1
		end
	end
	if activeCount > 0 then
		table.insert(parts, ("Receitas ativas: %d"):format(activeCount))
	end
	ui.Buffs.Text = table.concat(parts, "  •  ")
	ui.Buffs.Visible = #parts > 0
end

local function refreshCauldron()
	validateSlots()
	refreshInventory()
	refreshSlots()
	refreshPreview()
	refreshBuffs()
end

-------------------------------------------------------------------------------
-- Aba Livro de Receitas
-------------------------------------------------------------------------------

local fillFromRecipe -- declarada mais abaixo

local function buildBookCard(recipe, known, active, order)
	local card = UIKit.New("Frame", {
		Name = recipe.Id,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = known and Theme.PanelLight or Theme.PanelDark,
		LayoutOrder = order,
		Parent = ui.BookList,
	})
	UIKit.Corner(card, 14)
	UIKit.Stroke(card, known and 2.5 or 2, known and Theme.Accent2 or Theme.Stroke)
	UIKit.Padding(card, 12)
	local layout = UIKit.List(card, 6)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	if not known then
		UIKit.Label({
			Name = "RecipeName",
			Text = "???",
			Title = true,
			TextSize = 24,
			Color = Theme.TextDim,
			Size = UDim2.new(1, 0, 0, 28),
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 1,
			Parent = card,
		})
		UIKit.Label({
			Name = "Hint",
			Text = "Dica: " .. tostring(recipe.Hint or "..."),
			TextSize = 15,
			Color = Theme.TextDim,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 2,
			Parent = card,
		})
		return card
	end

	-- Nome + etiquetas (tipo e "Ativa").
	local top = UIKit.New("Frame", {
		Name = "Top",
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = card,
	})
	UIKit.List(top, 8, "Horizontal")
	local nameLabel = UIKit.Label({
		Name = "RecipeName",
		Text = recipe.Name,
		Title = true,
		TextSize = 23,
		Color = Theme.Rare,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 30),
		TextWrapped = false,
		LayoutOrder = 1,
		Parent = top,
	})
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	local kind = KIND_INFO[recipe.Kind] or KIND_INFO.Instant
	local kindText = kind.Text
	if recipe.Kind == "Timed" and tonumber(recipe.Duration) then
		kindText = ("%s (%d s)"):format(kind.Text, recipe.Duration)
	end
	pill(top, kindText, kind.Color, 2)
	if active then
		pill(top, "Ativa!", Theme.Success, 3)
	end

	-- Ingredientes (bolinhas + texto).
	local ingredientsRow = UIKit.New("Frame", {
		Name = "Ingredients",
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = card,
	})
	UIKit.List(ingredientsRow, 6, "Horizontal")
	local order2 = 0
	for _, ingredient in ipairs(Recipes.Ingredients) do
		local count = recipe.Ingredients[ingredient.Id]
		if count then
			for _ = 1, count do
				order2 += 1
				ingredientIcon(ingredientsRow, ingredient, 26, { LayoutOrder = order2 })
			end
		end
	end
	order2 += 1
	UIKit.Label({
		Name = "IngredientsText",
		Text = ingredientsText(recipe),
		TextSize = 14,
		Color = Theme.TextDim,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		TextWrapped = false,
		LayoutOrder = order2,
		Parent = ingredientsRow,
	})

	-- Efeito.
	UIKit.Label({
		Name = "Effect",
		Text = tostring(recipe.Description or ""),
		TextSize = 16,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 3,
		Parent = card,
	})

	-- Custo + botão para montar a receita no caldeirão.
	local bottom = UIKit.New("Frame", {
		Name = "Bottom",
		Size = UDim2.new(1, 0, 0, 42),
		BackgroundTransparency = 1,
		LayoutOrder = 4,
		Parent = card,
	})
	UIKit.Label({
		Name = "Cost",
		Text = "Custo: " .. NumberFormat.Abbrev(recipeCost(recipe)) .. " moedas",
		TextSize = 16,
		Color = Theme.Coin,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, -250, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = bottom,
	})
	UIKit.Button({
		Name = "Use",
		Text = "Colocar no caldeirão",
		Color = Theme.Accent2,
		Size = UDim2.fromOffset(240, 40),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		TextSize = 17,
		Parent = bottom,
	}, function()
		fillFromRecipe(recipe)
	end)

	return card
end

local function refreshBook()
	if not bookDirty then
		return
	end
	bookDirty = false
	bookTrove:Clean()

	local known = getKnown()
	local active = getActive()
	local knownCount = 0
	for _, recipe in ipairs(Recipes.Recipes) do
		if known[recipe.Id] == true then
			knownCount += 1
		end
	end
	ui.BookSummary.Text = ("Receitas descobertas: %d de %d"):format(knownCount, #Recipes.Recipes)
	ui.BookBar.Set(#Recipes.Recipes > 0 and knownCount / #Recipes.Recipes or 0, nil, true)
	ui.BookTab.Text = ("Livro de Receitas (%d/%d)"):format(knownCount, #Recipes.Recipes)

	-- Conhecidas primeiro (na ordem do Config), depois as "???".
	local order = 0
	for pass = 1, 2 do
		for _, recipe in ipairs(Recipes.Recipes) do
			local isKnown = known[recipe.Id] == true
			if (pass == 1) == isKnown then
				order += 1
				bookTrove:Add(buildBookCard(recipe, isKnown, active[recipe.Id] == true, order))
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Troca de aba
-------------------------------------------------------------------------------

-- No controle: se a seleção sumiu (botão destruído/escondido), volta para a aba atual.
local function fixSelection()
	if not (window and window.IsOpen()) then
		return
	end
	local GuiService = game:GetService("GuiService")
	local UserInputService = game:GetService("UserInputService")
	if not string.match(UserInputService:GetLastInputType().Name, "^Gamepad") then
		return
	end
	local selected = GuiService.SelectedObject
	if selected and selected.Parent and selected:IsDescendantOf(window.Gui) and selected.Visible then
		return
	end
	local target = currentTab == "Book" and ui.BookTab or ui.CauldronTab
	pcall(function()
		GuiService.SelectedObject = target
	end)
end

local function setTab(tab)
	currentTab = tab
	setTabLook(ui.CauldronTab, tab == "Cauldron")
	setTabLook(ui.BookTab, tab == "Book")
	ui.CauldronPage.Visible = tab == "Cauldron"
	ui.BookPage.Visible = tab == "Book"
	if tab == "Book" then
		refreshBook()
	else
		refreshCauldron()
	end
	window.Content.CanvasPosition = Vector2.zero
	task.defer(fixSelection)
end

-------------------------------------------------------------------------------
-- Ações
-------------------------------------------------------------------------------

local function addIngredient(ingredientId)
	if crafting then
		return
	end
	local ingredient = Recipes.IngredientsById[ingredientId]
	if not ingredient then
		return
	end
	if available(ingredientId) <= 0 then
		NotifyController.Show(("Você não tem mais %s."):format(ingredient.Name), "warning", 2.5)
		UIKit.PlaySound("Error")
		return
	end
	for index = 1, SLOT_COUNT do
		if slots[index] == nil then
			slots[index] = ingredientId
			refreshCauldron()
			UIKit.Pop(ui.Slots[index].Button, 0.12)
			return
		end
	end
	NotifyController.Show("O caldeirão está cheio! Tire um ingrediente antes.", "warning", 2.5)
	UIKit.PlaySound("Error")
end

local function removeSlot(index)
	if crafting or slots[index] == nil then
		return
	end
	slots[index] = nil
	refreshCauldron()
end

local function clearSlots()
	if crafting then
		return
	end
	table.clear(slots)
	refreshCauldron()
end

-- Monta no caldeirão os ingredientes de uma receita do Livro.
fillFromRecipe = function(recipe)
	if crafting then
		return
	end
	local inventory = getInventory()
	local missing = {}
	for _, ingredient in ipairs(Recipes.Ingredients) do
		local need = recipe.Ingredients[ingredient.Id]
		if need then
			local have = math.floor(tonumber(inventory[ingredient.Id]) or 0)
			if have < need then
				table.insert(missing, ("%d× %s"):format(need - have, ingredient.Name))
			end
		end
	end
	if #missing > 0 then
		NotifyController.Show("Faltam ingredientes: " .. table.concat(missing, ", ") .. ".", "warning", 4)
		UIKit.PlaySound("Error")
		return
	end

	table.clear(slots)
	local index = 0
	for _, ingredient in ipairs(Recipes.Ingredients) do
		local need = recipe.Ingredients[ingredient.Id]
		if need then
			for _ = 1, need do
				index += 1
				if index <= SLOT_COUNT then
					slots[index] = ingredient.Id
				end
			end
		end
	end
	setTab("Cauldron")
end

-- Comemoração: bolhas coloridas saindo do caldeirão e o nome da receita pulando.
local function celebrate(recipeName, colors)
	UIKit.PlaySound("Craft")
	local pot = ui.Pot
	for index = 1, BUBBLE_COUNT do
		local color = colors[(index - 1) % math.max(1, #colors) + 1] or BREW_COLOR
		local size = math.random(12, 26)
		local bubble = UIKit.New("Frame", {
			Name = "Bubble",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(math.random(15, 85) / 100, 0, 0.35, 0),
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = color,
			ZIndex = 6,
			Parent = pot,
		})
		UIKit.Corner(bubble, UDim.new(1, 0))
		local duration = 0.7 + math.random() * 0.6
		UIKit.Tween(bubble, {
			Position = bubble.Position - UDim2.fromOffset(math.random(-30, 30), math.random(90, 150)),
			BackgroundTransparency = 1,
		}, duration)
		task.delay(duration + 0.05, function()
			bubble:Destroy()
		end)
	end

	local burst = ui.Burst
	burst.Text = tostring(recipeName) .. "!"
	burst.TextTransparency = 0
	burst.Visible = true
	UIKit.Pop(burst, 0.35)
	task.delay(1.6, function()
		if burst.Text == tostring(recipeName) .. "!" then
			local tween = UIKit.Tween(burst, { TextTransparency = 1 }, 0.4)
			tween.Completed:Connect(function(state)
				if state == Enum.PlaybackState.Completed then
					burst.Visible = false
				end
			end)
		end
	end)
end

local function craft()
	if crafting then
		return
	end
	if not mapHasRecipes() then
		NotifyController.Show("O caldeirão só funciona no Deserto Sahur.", "warning", 3)
		return
	end
	local ids = {}
	local colors = {}
	for index = 1, SLOT_COUNT do
		local id = slots[index]
		if id then
			table.insert(ids, id)
			local ingredient = Recipes.IngredientsById[id]
			if ingredient and typeof(ingredient.Color) == "Color3" then
				table.insert(colors, ingredient.Color)
			end
		end
	end
	if #ids < MIN_INGREDIENTS then
		NotifyController.Show("Coloque pelo menos 2 ingredientes no caldeirão.", "warning", 3)
		UIKit.PlaySound("Error")
		return
	end

	crafting = true
	refreshPreview()
	local ok, result = Net.Request("Craft", ids)
	crafting = false

	if ok then
		-- Deu certo: o servidor já gastou os ingredientes e avisou todo mundo.
		table.clear(slots)
		local name = type(result) == "table" and result.Name or "Receita"
		celebrate(name, colors)
		if type(result) == "table" and result.NewDiscovery == true then
			bookDirty = true
		end
	else
		NotifyController.Show(
			type(result) == "string" and result or "Não foi possível cozinhar agora.",
			"error",
			3.5
		)
		UIKit.PlaySound("Error")
		-- Chacoalha o caldeirão.
		local pot = ui.Pot
		local tween = UIKit.Tween(
			pot,
			{ Rotation = 3 },
			TweenInfo.new(0.05, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 3, true)
		)
		tween.Completed:Connect(function()
			pot.Rotation = 0
		end)
	end
	if window and window.IsOpen() then
		refreshCauldron()
	end
end

-------------------------------------------------------------------------------
-- Montagem da janela
-------------------------------------------------------------------------------

local function buildCauldronPage(content)
	local page = UIKit.New("Frame", {
		Name = "CauldronPage",
		Size = UDim2.new(1, 0, 0, PAGE_HEIGHT),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = content,
	})

	-- Esquerda: inventário.
	local left = UIKit.New("Frame", {
		Name = "Inventory",
		Size = UDim2.new(0.44, -6, 1, 0),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.1,
		Parent = page,
	})
	UIKit.Corner(left, 14)
	UIKit.Stroke(left, 2, Theme.PanelDark)
	UIKit.Padding(left, 10)
	UIKit.Label({
		Name = "Title",
		Text = "Seus ingredientes",
		Title = true,
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = left,
	})
	local grid = UIKit.New("Frame", {
		Name = "Grid",
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 1, -84),
		BackgroundTransparency = 1,
		Parent = left,
	})
	UIKit.Grid(grid, INGREDIENT_CELL, 8)
	ui.IngredientCells = {}
	for index, ingredient in ipairs(Recipes.Ingredients) do
		local button = UIKit.Button({
			Name = ingredient.Id,
			Text = "",
			Color = Theme.PanelLight,
			LayoutOrder = index,
			Parent = grid,
		}, function()
			addIngredient(ingredient.Id)
		end)
		local icon = ingredientIcon(button, ingredient, 46, {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
		})
		UIKit.Label({
			Name = "IngredientName",
			Text = ingredient.Name,
			TextSize = 13,
			Position = UDim2.fromOffset(54, 4),
			Size = UDim2.new(1, -54, 0, 38),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = button,
		})
		local count = UIKit.Label({
			Name = "Count",
			Text = "x0",
			Title = true,
			TextSize = 22,
			Position = UDim2.new(0, 54, 1, -30),
			Size = UDim2.new(1, -54, 0, 26),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = button,
		})
		ui.IngredientCells[ingredient.Id] = { Button = button, Icon = icon, Count = count }
	end
	ui.InventoryHint = UIKit.Label({
		Name = "Hint",
		Text = "",
		TextSize = 13,
		Color = Theme.TextDim,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 44),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Parent = left,
	})

	-- Direita: moedas, caldeirão com 3 espaços, prévia e botão.
	local right = UIKit.New("Frame", {
		Name = "Brew",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.56, -6, 1, 0),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.1,
		Parent = page,
	})
	UIKit.Corner(right, 14)
	UIKit.Stroke(right, 2, Theme.PanelDark)
	UIKit.Padding(right, 10)

	ui.Coins = UIKit.Label({
		Name = "Coins",
		Text = "",
		Title = true,
		TextSize = 20,
		Color = Theme.Coin,
		Size = UDim2.new(1, -110, 0, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = right,
	})
	ui.ClearButton = UIKit.Button({
		Name = "Clear",
		Text = "Limpar",
		Color = Theme.Warning,
		Size = UDim2.fromOffset(100, 30),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		TextSize = 16,
		Visible = false,
		Parent = right,
	}, clearSlots)

	-- A panela: caldo verde em cima e os 3 espaços.
	local pot = UIKit.New("Frame", {
		Name = "Pot",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 34),
		Size = UDim2.new(1, -10, 0, 150),
		BackgroundColor3 = CAULDRON_COLOR,
		Parent = right,
	})
	UIKit.Corner(pot, UDim.new(0, 40))
	UIKit.Stroke(pot, 4, UIKit.Darken(CAULDRON_COLOR, 0.5))
	local brew = UIKit.New("Frame", {
		Name = "Brew",
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundColor3 = BREW_COLOR,
		Parent = pot,
	})
	UIKit.Corner(brew, UDim.new(0, 12))
	UIKit.New("UIGradient", {
		Color = ColorSequence.new(BREW_COLOR, Color3.fromRGB(70, 190, 150)),
		Parent = brew,
	})
	local slotsRow = UIKit.New("Frame", {
		Name = "Slots",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 30),
		Size = UDim2.new(1, -20, 0, SLOT_SIZE + 8),
		BackgroundTransparency = 1,
		Parent = pot,
	})
	local slotsLayout = UIKit.List(slotsRow, 14, "Horizontal")
	slotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	ui.Slots = {}
	for index = 1, SLOT_COUNT do
		local button = UIKit.Button({
			Name = "Slot" .. index,
			Text = "",
			Color = UIKit.Darken(CAULDRON_COLOR, 0.35),
			Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE),
			LayoutOrder = index,
			CornerRadius = UDim.new(0, 22),
			Parent = slotsRow,
		}, function()
			removeSlot(index)
		end)
		local holder = UIKit.New("Frame", {
			Name = "Holder",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Parent = button,
		})
		ui.Slots[index] = { Button = button, Holder = holder, ShownId = false }
	end
	ui.Pot = pot

	-- Nome da receita que pula quando cozinha.
	ui.Burst = UIKit.New("TextLabel", {
		Name = "Burst",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundTransparency = 1,
		Font = Theme.TitleFont,
		TextSize = 34,
		TextScaled = true,
		TextColor3 = Theme.Rare,
		Text = "",
		Visible = false,
		ZIndex = 8,
		Parent = pot,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 34, MinTextSize = 14, Parent = ui.Burst })
	UIKit.Stroke(ui.Burst, 3, Theme.Stroke)

	-- Prévia da receita.
	local preview = UIKit.New("Frame", {
		Name = "Preview",
		Position = UDim2.fromOffset(0, 194),
		Size = UDim2.new(1, 0, 0, 132),
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.2,
		Parent = right,
	})
	UIKit.Corner(preview, 12)
	UIKit.Padding(preview, 10)
	ui.PreviewTitle = UIKit.Label({
		Name = "Title",
		Text = "",
		Title = true,
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = preview,
	})
	ui.PreviewText = UIKit.Label({
		Name = "Text",
		Text = "",
		TextSize = 14,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 54),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = preview,
	})
	ui.PreviewCost = UIKit.Label({
		Name = "Cost",
		Text = "",
		TextSize = 16,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = preview,
	})

	ui.CraftButton = UIKit.Button({
		Name = "Craft",
		Text = "Cozinhar!",
		Color = Theme.Success,
		Size = UDim2.new(1, -60, 0, 56),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 336),
		TextSize = 28,
		Parent = right,
	}, craft)

	ui.Buffs = UIKit.Label({
		Name = "Buffs",
		Text = "",
		TextSize = 13,
		Color = Theme.Info,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 20),
		Visible = false,
		Parent = right,
	})

	return page
end

local function buildBookPage(content)
	local page = UIKit.New("Frame", {
		Name = "BookPage",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Visible = false,
		Parent = content,
	})
	local layout = UIKit.List(page, 10)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	local summary = UIKit.New("Frame", {
		Name = "Summary",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.1,
		LayoutOrder = 1,
		Parent = page,
	})
	UIKit.Corner(summary, 14)
	UIKit.Padding(summary, 12)
	local summaryLayout = UIKit.List(summary, 8)
	summaryLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	ui.BookSummary = UIKit.Label({
		Name = "Title",
		Text = "",
		Title = true,
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Parent = summary,
	})
	ui.BookBar = UIKit.ProgressBar(summary, {
		Name = "Progress",
		Size = UDim2.new(1, 0, 0, 18),
		Color = Theme.Rare,
		LayoutOrder = 2,
	})
	UIKit.Label({
		Name = "Hint",
		Text = "Receitas novas aparecem aqui quando alguém do seu time acerta a combinação no caldeirão.",
		TextSize = 14,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 3,
		Parent = summary,
	})

	ui.BookList = UIKit.New("Frame", {
		Name = "List",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = page,
	})
	UIKit.List(ui.BookList, 8)
	return page
end

local function build()
	window = UIKit.Window(WINDOW_NAME, "Caldeirão Brainrot", WINDOW_SIZE)
	local content = window.Content
	local layout = UIKit.List(content, 10)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIKit.Padding(content, { Top = 4, Bottom = 12, Left = 4, Right = 4 })
	ui = {}

	-- Abas.
	local tabs = UIKit.New("Frame", {
		Name = "Tabs",
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = content,
	})
	local tabsLayout = UIKit.List(tabs, 10, "Horizontal")
	tabsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	ui.CauldronTab = UIKit.Button({
		Name = "CauldronTab",
		Text = "Caldeirão",
		Size = UDim2.fromOffset(240, 46),
		LayoutOrder = 1,
		TextSize = 22,
		Parent = tabs,
	}, function()
		setTab("Cauldron")
	end)
	ui.BookTab = UIKit.Button({
		Name = "BookTab",
		Text = "Livro de Receitas",
		Size = UDim2.fromOffset(300, 46),
		LayoutOrder = 2,
		TextSize = 22,
		Parent = tabs,
	}, function()
		setTab("Book")
	end)

	ui.CauldronPage = buildCauldronPage(content)
	ui.BookPage = buildBookPage(content)
end

-- Escuta mudanças enquanto a janela está aberta.
local function startListening()
	listenTrove:Clean()

	local function onCauldronChange()
		if currentTab == "Cauldron" then
			refreshCauldron()
		end
	end
	local function onBookChange()
		bookDirty = true
		if currentTab == "Book" then
			refreshBook()
			task.defer(fixSelection)
		else
			refreshCauldron()
		end
	end

	listenTrove:Add(StateController.OnChanged("Ingredients", onCauldronChange))
	listenTrove:Add(StateController.OnChanged("Coins", onCauldronChange))
	listenTrove:Add(StateController.OnChanged("Buffs", onCauldronChange))
	listenTrove:Add(StateController.OnChanged("Match", onBookChange))
	listenTrove:Add(StateController.OnChanged("Profile", onBookChange))
	listenTrove:Add(StateController.OnChanged("Recipes", onBookChange))

	-- Relógio do efeito temporário (encantamento por tempo).
	local accumulator = 0
	listenTrove:Connect(RunService.Heartbeat, function(dt)
		accumulator += dt
		if accumulator >= TICK_INTERVAL then
			accumulator = 0
			if currentTab == "Cauldron" then
				refreshBuffs()
			end
		end
	end)
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

-- Abre a janela. tab = "Book" abre no Livro de Receitas.
-- Fora do Deserto (sem caldeirão), abre direto no Livro.
function CauldronWindow.Open(tab)
	ensureWindow()
	bookDirty = true
	if tab ~= "Book" and tab ~= "Cauldron" then
		tab = mapHasRecipes() and "Cauldron" or "Book"
	end
	-- Atualiza o título da aba do livro mesmo abrindo no caldeirão.
	refreshBook()
	setTab(tab)
	if not window.IsOpen() then
		window.Open()
	end
end

function CauldronWindow.Close()
	if window then
		window.Close()
	end
end

function CauldronWindow.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function CauldronWindow.Init()
	-- Prompt do caldeirão (ClientAction "Cauldron") e botão do HUD.
	local PromptController = getController("PromptController")
	if PromptController and PromptController.Register then
		PromptController.Register("Cauldron", function(arg)
			CauldronWindow.Open(arg)
		end)
	else
		warn("[CauldronWindow] PromptController não encontrado; o caldeirão não vai abrir a janela.")
	end
end

function CauldronWindow.Start() end

-- Deixa as funções do módulo funcionarem com "." e também com ":".
for name, fn in pairs(CauldronWindow) do
	if type(fn) == "function" then
		CauldronWindow[name] = function(first, ...)
			if first == CauldronWindow then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return CauldronWindow
