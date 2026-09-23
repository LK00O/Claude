--!nonstrict
-- Builders/Lobby: monta o lobby, uma praça de fazenda brainrot colorida (seção 7.5).
--
-- Layout (~200×200, Y = 0 é o chão, -Z = norte):
--   * Spawn no centro de uma praça redonda de pedra.
--   * Placa grande com o nome do jogo ao norte.
--   * Terminal "Criar Partida" (ClientAction "CreateParty") e quadro "Partidas Abertas"
--     (ClientAction "PartyList") logo à frente do spawn.
--   * Placar de líderes (Part com SurfaceGui "Board" que tem o Frame "List").
--   * Barraca de skins (ClientAction "Shop"), estátua de conquistas (ClientAction
--     "Achievements") e um totem de configurações (ClientAction "Settings").
--   * Estátuas de brainrots em volta da praça (BrainrotFactory, dentro de pcall),
--     celeiro, plantações, árvores, cerca e lampiões. Luz de fim de tarde.
--
-- Build(folder) devolve o ctx do lobby:
--   { MapId = "Lobby", Folder, SpawnLocation, CreateTerminal, PartyBoard, Leaderboard,
--     ShopStand, AchievementsStand }
--
-- Módulo de World: NÃO dá require em nenhum serviço (regra 1.2). A BrainrotFactory é
-- outro módulo de World, então pode ser usada aqui.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local GameConfig = require(Config:WaitForChild("Game"))
local Maps = require(Config:WaitForChild("Maps"))
local Brainrots = require(Config:WaitForChild("Brainrots"))
local Cosmetics = require(Config:WaitForChild("Cosmetics"))

local Common = require(script.Parent:WaitForChild("Common"))

local Lobby = {}

-------------------------------------------------------------------------------
-- Constantes do layout (tamanhos, posições e cores; não são balanceamento)
-------------------------------------------------------------------------------

local GROUND_Y = 0
local GROUND_SIZE = 700
local PLAY_SIZE = 200
local PLAZA_RADIUS = 36
local PLAZA_Y = GROUND_Y + 0.2

local CENTER = Vector3.new(0, PLAZA_Y, 0)
local TITLE_POSITION = Vector3.new(0, GROUND_Y, -80)
local LEADERBOARD_POSITION = Vector3.new(-52, GROUND_Y, -44)
local TERMINAL_POSITION = Vector3.new(-24, PLAZA_Y, -24)
local PARTY_BOARD_POSITION = Vector3.new(24, PLAZA_Y, -24)
local SHOP_POSITION = Vector3.new(-38, GROUND_Y, 30)
local ACHIEVEMENTS_POSITION = Vector3.new(38, GROUND_Y, 30)
local SETTINGS_POSITION = Vector3.new(0, GROUND_Y, 42)
local BARN_POSITION = Vector3.new(68, GROUND_Y, -66)

local STATUE_RADIUS = 62
local STATUE_SCALE = 1.8

-- Iluminação de fim de tarde (o lobby não está em Config.Maps).
local LOBBY_LIGHTING = {
	ClockTime = 17.4,
	Brightness = 2,
	Ambient = Color3.fromRGB(135, 115, 105),
	OutdoorAmbient = Color3.fromRGB(175, 145, 125),
	Atmosphere = {
		Density = 0.28,
		Offset = 0.15,
		Color = Color3.fromRGB(255, 205, 165),
		Decay = Color3.fromRGB(215, 125, 95),
		Glare = 0.35,
		Haze = 1.4,
	},
}

local rgb = Color3.fromRGB
local GRASS = rgb(98, 172, 74)
local COBBLE = rgb(192, 182, 166)
local DIRT = rgb(170, 132, 92)
local MARBLE = rgb(236, 232, 224)
local PINK = rgb(255, 95, 175)
local BRAINROT_PURPLE = rgb(170, 95, 230)
local FLOWER_COLORS = { rgb(255, 90, 120), rgb(255, 210, 60), rgb(170, 110, 255), rgb(255, 255, 255) }

-------------------------------------------------------------------------------
-- Estações do lobby
-------------------------------------------------------------------------------

-- CFrame num ponto olhando para o centro da praça.
local function facingCenter(position)
	return CFrame.lookAt(position, Vector3.new(CENTER.X, position.Y, CENTER.Z))
end

-- Terminal "Criar Partida" (quiosque com tela).
local function buildTerminal(parent, cframe)
	local model = Common.Model("CreateTerminalStation", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end
	Common.Block(model, at(0, 0.3, 0), Vector3.new(5, 0.6, 4), Common.Colors.DarkMetal, Enum.Material.DiamondPlate)
	local body = Common.Block(model, at(0, 3.1, 0), Vector3.new(3.6, 5, 2.4), rgb(70, 200, 120), Enum.Material.Metal)
	body.Name = "CreateTerminal"
	-- Tela inclinada para cima (o topo vai para trás).
	local screen = Common.Block(model, at(0, 4.3, -1.3) * CFrame.Angles(math.rad(20), 0, 0), Vector3.new(3, 2, 0.15), rgb(90, 220, 255), Enum.Material.Neon, {
		Name = "Screen",
		CanCollide = false,
		CanQuery = false,
	})
	Common.Sign(screen, Enum.NormalId.Front, "CRIAR\nPARTIDA", rgb(15, 40, 70))
	Common.Block(model, at(0, 5.8, 0), Vector3.new(3.9, 0.4, 2.7), Common.Colors.DarkMetal, Enum.Material.Metal)
	Common.Billboard(body, "Criar Partida", Vector3.new(0, 5, 0))
	Common.Prompt(body, "Criar partida", "Terminal de Partidas", { ClientAction = "CreateParty" })
	model.PrimaryPart = body
	return body
end

-- Quadro "Partidas Abertas".
local function buildPartyBoard(parent, cframe)
	local model = Common.Model("PartyBoardStation", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end
	for _, side in ipairs({ -1, 1 }) do
		Common.Block(model, at(side * 6.8, 4.8, 0), Vector3.new(0.8, 9.6, 0.8), Common.Colors.DarkWood, Enum.Material.Wood)
	end
	local board = Common.Block(model, at(0, 6, 0), Vector3.new(13, 6.5, 0.5), rgb(55, 75, 140), Enum.Material.Wood)
	board.Name = "PartyBoard"
	Common.Block(model, at(0, 9.6, 0), Vector3.new(14.6, 0.6, 1), Common.Colors.Wood, Enum.Material.Wood)
	Common.Block(model, at(0, 2.5, 0), Vector3.new(14.6, 0.5, 0.8), Common.Colors.Wood, Enum.Material.Wood)
	Common.Sign(board, Enum.NormalId.Front, "PARTIDAS\nABERTAS", Common.Colors.White)
	Common.Sign(board, Enum.NormalId.Back, "PARTIDAS\nABERTAS", Common.Colors.White)
	Common.Prompt(board, "Ver partidas abertas", "Quadro de Partidas", { ClientAction = "PartyList" })
	model.PrimaryPart = board
	return board
end

-- Placar de líderes: Part "Leaderboard" com SurfaceGui "Board" e Frame "List" (o LobbyService preenche).
local function buildLeaderboard(parent, cframe)
	local model = Common.Model("LeaderboardStation", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end
	for _, side in ipairs({ -1, 1 }) do
		Common.Block(model, at(side * 8.6, 11, 0), Vector3.new(1, 22, 1), Common.Colors.DarkWood, Enum.Material.Wood)
	end
	local board = Common.Block(model, at(0, 12.5, 0), Vector3.new(16, 20, 0.8), rgb(32, 28, 48), Enum.Material.SmoothPlastic)
	board.Name = "Leaderboard"
	Common.Block(model, at(0, 22.8, 0), Vector3.new(18.2, 0.8, 1.2), Common.Colors.Gold, Enum.Material.Metal)
	Common.Block(model, at(0, 2.2, 0), Vector3.new(18.2, 0.8, 1.2), Common.Colors.Gold, Enum.Material.Metal)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Board"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromScale(0.05, 0.02)
	title.Size = UDim2.fromScale(0.9, 0.1)
	title.Font = Enum.Font.FredokaOne
	title.Text = "TOP MOEDAS"
	title.TextColor3 = rgb(255, 215, 80)
	title.TextScaled = true
	title.TextStrokeTransparency = 0.4
	title.Parent = gui

	local list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromScale(0.05, 0.14)
	list.Size = UDim2.fromScale(0.9, 0.83)
	list.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.Name = "Layout"
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list

	gui.Parent = board

	-- No verso, só o nome do placar.
	Common.Sign(board, Enum.NormalId.Back, "PLACAR DE LÍDERES", rgb(255, 215, 80))
	model.PrimaryPart = board
	return board
end

-- Barraca de skins (balcão rosa, toldo listrado e armas em exposição nas cores das skins).
local function buildShop(parent, cframe)
	local model = Common.Model("ShopStation", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end
	local width, depth = 14, 10
	Common.Block(model, at(0, 0.3, 0), Vector3.new(width, 0.6, depth), Common.Colors.LightWood, Enum.Material.WoodPlanks)
	local counter = Common.Block(model, at(0, 2.3, -depth / 2 + 1.5), Vector3.new(width - 2, 3.4, 2.2), PINK, Enum.Material.Wood)
	counter.Name = "ShopStand"
	Common.Block(model, at(0, 4.2, -depth / 2 + 1.4), Vector3.new(width - 1, 0.4, 2.8), MARBLE, Enum.Material.Marble)
	Common.Sign(counter, Enum.NormalId.Front, "SKINS", Common.Colors.White)
	local backWall = Common.Block(model, at(0, 5.6, depth / 2 - 0.3), Vector3.new(width, 10, 0.6), rgb(120, 60, 110), Enum.Material.WoodPlanks)
	backWall.Name = "BackWall"
	for _, side in ipairs({ -1, 1 }) do
		Common.Block(model, at(side * (width / 2 - 0.4), 5, -depth / 2 + 0.4), Vector3.new(0.8, 9, 0.8), MARBLE, Enum.Material.Wood)
	end
	-- Toldo listrado rosa e branco.
	local stripes = 7
	local stripeWidth = (width + 1) / stripes
	for index = 1, stripes do
		local x = -(width + 1) / 2 + stripeWidth * (index - 0.5)
		Common.Block(model, at(x, 10, -0.5) * CFrame.Angles(math.rad(-10), 0, 0), Vector3.new(stripeWidth + 0.02, 0.4, depth + 2), if index % 2 == 1 then PINK else Common.Colors.White, Enum.Material.Fabric)
	end
	local sign = Common.Block(model, at(0, 10.3, -depth / 2 - 1.3), Vector3.new(width - 2, 2.4, 0.35), PINK, Enum.Material.Wood)
	Common.Sign(sign, Enum.NormalId.Front, "LOJA DE SKINS", Common.Colors.White)
	Common.Sign(sign, Enum.NormalId.Back, "LOJA DE SKINS", Common.Colors.White)

	-- Armas em exposição na parede do fundo, uma para cada skin.
	local skins = Cosmetics.Skins or {}
	local shown = math.min(#skins, 6)
	for index = 1, shown do
		local skin = skins[index]
		local column = (index - 1) % 3
		local row = math.floor((index - 1) / 3)
		local base = at(-4 + column * 4, 7 - row * 2.6, depth / 2 - 0.9)
		local color = typeof(skin.GunColor) == "Color3" and skin.GunColor or Common.Colors.DarkMetal
		Common.Block(model, base, Vector3.new(2, 0.7, 0.4), color, Enum.Material.Metal, { CanCollide = false, CanQuery = false })
		Common.Block(model, base * CFrame.new(-0.55, -0.6, 0), Vector3.new(0.45, 0.8, 0.35), Common.Colors.DarkMetal, Enum.Material.Metal, { CanCollide = false, CanQuery = false })
		Common.Part({
			Name = "Barrel",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.1, 0.35, 0.35),
			CFrame = base * CFrame.new(1.4, 0.1, 0),
			Color = Common.Colors.DarkMetal,
			Material = Enum.Material.Metal,
			CanCollide = false,
			CanQuery = false,
			Parent = model,
		})
	end

	Common.Prompt(counter, "Abrir loja", "Loja de Skins", { ClientAction = "Shop" })
	model.PrimaryPart = counter
	return counter
end

-- Estátua de conquistas: pedestal de mármore com um troféu dourado.
local function buildAchievements(parent, cframe)
	local model = Common.Model("AchievementsStation", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end
	local gold = Common.Colors.Gold
	Common.Cylinder(model, at(0, 0.4, 0), 0.8, 9, MARBLE, Enum.Material.Marble)
	local pedestal = Common.Block(model, at(0, 2.8, 0), Vector3.new(4.5, 4, 4.5), MARBLE, Enum.Material.Marble)
	pedestal.Name = "AchievementsStand"
	Common.Block(model, at(0, 5.1, 0), Vector3.new(2.4, 0.6, 2.4), gold, Enum.Material.Metal)
	Common.Cylinder(model, at(0, 5.9, 0), 1, 0.6, gold, Enum.Material.Metal)
	Common.Cylinder(model, at(0, 7.5, 0), 2.2, 2.6, gold, Enum.Material.Metal)
	for _, side in ipairs({ -1, 1 }) do
		Common.Block(model, at(side * 1.65, 7.6, 0), Vector3.new(0.45, 1.3, 0.45), gold, Enum.Material.Metal)
	end
	local star = Common.Ball(model, at(0, 9.1, 0).Position, 0.9, rgb(255, 240, 120), Enum.Material.Neon, { CanCollide = false, CanQuery = false })
	local light = Instance.new("PointLight")
	light.Color = rgb(255, 225, 120)
	light.Range = 12
	light.Brightness = 1.5
	light.Shadows = false
	light.Parent = star
	Common.Sign(pedestal, Enum.NormalId.Front, "CONQUISTAS", rgb(150, 105, 20))
	Common.Billboard(pedestal, "Conquistas", Vector3.new(0, 8.5, 0))
	Common.Prompt(pedestal, "Ver conquistas", "Conquistas e Estatísticas", { ClientAction = "Achievements" })
	model.PrimaryPart = pedestal
	return pedestal
end

-- Totem de configurações.
local function buildSettingsKiosk(parent, cframe)
	local model = Common.Model("SettingsKiosk", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end
	Common.Cylinder(model, at(0, 2, 0), 4, 0.5, Common.Colors.DarkMetal, Enum.Material.Metal)
	local box = Common.Block(model, at(0, 4.8, 0), Vector3.new(4.4, 2, 0.6), rgb(110, 115, 140), Enum.Material.Metal)
	box.Name = "SettingsKiosk"
	Common.Sign(box, Enum.NormalId.Front, "CONFIGURAÇÕES", Common.Colors.White)
	Common.Sign(box, Enum.NormalId.Back, "CONFIGURAÇÕES", Common.Colors.White)
	Common.Prompt(box, "Abrir configurações", "Configurações", { ClientAction = "Settings" })
	model.PrimaryPart = box
	return box
end

-- Celeiro vermelho com telhado de duas águas. cframe = centro no chão, frente = porta.
local function buildBarn(parent, cframe)
	local model = Common.Model("Barn", parent)
	local red = rgb(172, 48, 42)
	local roof = rgb(85, 70, 65)
	local white = Common.Colors.White
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end
	local body = Common.Block(model, at(0, 7, 0), Vector3.new(24, 14, 18), red, Enum.Material.WoodPlanks)
	body.Name = "Barn"
	-- Empena em degraus (o "triângulo" da frente e de trás).
	Common.Block(model, at(0, 15.6, 0), Vector3.new(16, 3.2, 17.9), red, Enum.Material.WoodPlanks)
	Common.Block(model, at(0, 18.4, 0), Vector3.new(8, 2.6, 17.9), red, Enum.Material.WoodPlanks)
	-- Telhado: duas placas da cumeeira até os beirais.
	local ridge = cframe:PointToWorldSpace(Vector3.new(0, 20.6, 0))
	for _, side in ipairs({ -1, 1 }) do
		local eave = cframe:PointToWorldSpace(Vector3.new(side * 13.4, 13.2, 0))
		Common.Slab(model, ridge, eave, 19.5, 0.8, roof, Enum.Material.Slate)
	end
	-- Porta com X branco e janela do sótão.
	local door = Common.Block(model, at(0, 4.6, -9.1), Vector3.new(7, 9.2, 0.3), rgb(130, 35, 32), Enum.Material.WoodPlanks)
	door.Name = "Door"
	local doorTopLeft = cframe:PointToWorldSpace(Vector3.new(-3.2, 8.9, -9.3))
	local doorBottomRight = cframe:PointToWorldSpace(Vector3.new(3.2, 0.3, -9.3))
	local doorTopRight = cframe:PointToWorldSpace(Vector3.new(3.2, 8.9, -9.3))
	local doorBottomLeft = cframe:PointToWorldSpace(Vector3.new(-3.2, 0.3, -9.3))
	Common.Slab(model, doorTopLeft, doorBottomRight, 0.5, 0.2, white, Enum.Material.Wood, { CanCollide = false, CanQuery = false })
	Common.Slab(model, doorTopRight, doorBottomLeft, 0.5, 0.2, white, Enum.Material.Wood, { CanCollide = false, CanQuery = false })
	Common.Block(model, at(0, 9.3, -9.2), Vector3.new(7.6, 0.5, 0.3), white, Enum.Material.Wood)
	Common.Block(model, at(0, 15.4, -9.1), Vector3.new(3.6, 3, 0.3), rgb(60, 40, 35), Enum.Material.WoodPlanks)
	Common.Block(model, at(0, 15.4, -9.2), Vector3.new(4.2, 3.6, 0.1), white, Enum.Material.Wood)
	model.PrimaryPart = body
	return model
end

-- Plantação (terra arada com fileiras de brotos).
local function buildCropField(parent, center, size, cropColor)
	local model = Common.Model("CropField", parent)
	Common.Block(model, CFrame.new(center + Vector3.new(0, 0.15, 0)), Vector3.new(size.X, 0.3, size.Y), rgb(120, 80, 50), Enum.Material.Ground)
	local rows = 5
	for index = 1, rows do
		local z = -size.Y / 2 + size.Y * (index - 0.5) / rows
		Common.Block(model, CFrame.new(center + Vector3.new(0, 0.8, z)), Vector3.new(size.X - 3, 1, 1.1), cropColor, Enum.Material.Grass, { CanCollide = false, CanQuery = false })
	end
	-- Algumas abóboras.
	for index = 1, 4 do
		local x = -size.X / 2 + 3 + (index - 1) * (size.X - 6) / 3
		Common.Ball(model, center + Vector3.new(x, 0.9, size.Y / 2 + 1.5), 1.6, rgb(245, 140, 40), Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
	end
	return model
end

-- Estátua de brainrot num pedestal, virada para o centro da praça.
local function buildStatue(parent, factory, def, position)
	local model = Common.Model("Statue", parent)
	local frame = facingCenter(position)
	local pedestal = Common.Block(model, frame * CFrame.new(0, 1.5, 0), Vector3.new(6, 3, 6), MARBLE, Enum.Material.Marble)
	pedestal.Name = "Pedestal"
	Common.Block(model, frame * CFrame.new(0, 3.15, 0), Vector3.new(6.6, 0.3, 6.6), Common.Colors.Gold, Enum.Material.Metal)
	Common.Sign(pedestal, Enum.NormalId.Front, def.DisplayName or def.Id or "Brainrot", rgb(90, 70, 40))

	local top = (frame * CFrame.new(0, 3.3, 0)).Position
	local placed = false
	if factory then
		local ok, result = pcall(function()
			local brainrot = factory.Build(def)
			brainrot.Name = "BrainrotStatue"
			brainrot:ScaleTo(STATUE_SCALE)
			brainrot:PivotTo(CFrame.lookAt(top, top + frame.LookVector))
			brainrot.Parent = model
			return brainrot
		end)
		if ok and result then
			placed = true
		else
			warn("[Lobby] Não deu para montar a estátua de " .. tostring(def.Id) .. ": " .. tostring(result))
		end
	end
	if not placed then
		-- Sem a fábrica: um "brainrot" genérico (bola roxa com olhos).
		Common.Ball(model, top + Vector3.new(0, 2.5, 0), 5, BRAINROT_PURPLE, Enum.Material.SmoothPlastic)
		for _, x in ipairs({ -0.9, 0.9 }) do
			Common.Ball(model, (frame * CFrame.new(x, 6.6, -2.1)).Position, 1.1, Common.Colors.White, Enum.Material.SmoothPlastic)
		end
	end
	model.PrimaryPart = pedestal
	return model
end

-- Escolhe os brainrots das estátuas: o primeiro de tier Baixo e o primeiro de tier Alto de cada mapa.
local function pickStatueDefs()
	local defs = {}
	local byMap = Brainrots.ByMap or {}
	for _, mapId in ipairs(Maps.Order or {}) do
		local list = byMap[mapId] or {}
		for _, tier in ipairs({ "High", "Low" }) do
			for _, def in ipairs(list) do
				if def.Tier == tier then
					table.insert(defs, def)
					break
				end
			end
		end
	end
	return defs
end

-------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------

function Lobby.Build(folder)
	local rng = Random.new()

	-- Iluminação própria do lobby (fim de tarde) e efeitos quentinhos.
	Common.ApplyLighting(LOBBY_LIGHTING)
	Common.SetSun(20)
	Common.LightingEffect("ColorCorrectionEffect", { TintColor = rgb(255, 238, 222), Saturation = 0.12, Contrast = 0.04 })
	Common.LightingEffect("BloomEffect", { Intensity = 0.45, Size = 26, Threshold = 1.8 })
	Common.LightingEffect("SunRaysEffect", { Intensity = 0.06, Spread = 0.7 })

	local terrainFolder = Common.Folder("Terrain", folder)
	local plazaFolder = Common.Folder("Plaza", folder)
	local stationsFolder = Common.Folder("Stations", folder)
	local decorFolder = Common.Folder("Decor", folder)
	local helpersFolder = Common.Folder("Helpers", folder)

	-- 1. Chão, cerca e limites -----------------------------------------------------------
	Common.Ground(terrainFolder, Vector3.new(GROUND_SIZE, 4, GROUND_SIZE), GRASS, Enum.Material.Grass)
	Common.Bounds(helpersFolder, Vector3.new(0, GROUND_Y, 0), Vector2.new(PLAY_SIZE, PLAY_SIZE), 60)
	Common.Fence(decorFolder, Vector3.new(0, GROUND_Y, 0), Vector2.new(PLAY_SIZE - 6, PLAY_SIZE - 6), 3.5)
	-- Morros verdes no horizonte.
	for index = 0, 7 do
		local angle = index * math.pi / 4 + 0.3
		Common.Hill(terrainFolder, Vector3.new(math.cos(angle) * 230, GROUND_Y, math.sin(angle) * 230), 90, 34, rgb(92, 165, 68), Enum.Material.Grass)
	end

	-- 2. Praça, caminhos e spawn --------------------------------------------------------------
	Common.Cylinder(plazaFolder, Vector3.new(0, GROUND_Y + 0.1, 0), 0.2, PLAZA_RADIUS * 2, COBBLE, Enum.Material.Cobblestone, { Name = "Plaza" })
	Common.Cylinder(plazaFolder, Vector3.new(0, GROUND_Y + 0.06, 0), 0.12, PLAZA_RADIUS * 2 + 3, rgb(150, 140, 128), Enum.Material.Slate, { Name = "PlazaBorder" })
	-- Caminho de terra até a placa do nome (norte) e para o sul.
	Common.Block(plazaFolder, CFrame.new(0, GROUND_Y + 0.08, -58), Vector3.new(10, 0.16, 44), DIRT, Enum.Material.Ground)
	Common.Block(plazaFolder, CFrame.new(0, GROUND_Y + 0.08, 64), Vector3.new(10, 0.16, 56), DIRT, Enum.Material.Ground)

	local spawnLocation = Common.SpawnPad(plazaFolder, CENTER, Vector2.new(12, 12), rgb(255, 200, 90))

	-- Canteiros de flores em volta da praça.
	for index = 1, 16 do
		local angle = index * math.pi / 8 + math.pi / 16
		local point = Vector3.new(math.cos(angle) * (PLAZA_RADIUS + 3.5), GROUND_Y, math.sin(angle) * (PLAZA_RADIUS + 3.5))
		local color = FLOWER_COLORS[(index % #FLOWER_COLORS) + 1]
		Common.Ball(decorFolder, point + Vector3.new(0, 0.5, 0), 1.2, color, Enum.Material.SmoothPlastic, { Name = "Flower", CanCollide = false, CanQuery = false })
	end

	-- 3. Placa com o nome do jogo --------------------------------------------------------------
	local titleFrame = CFrame.lookAt(TITLE_POSITION, Vector3.new(0, GROUND_Y, 0))
	Common.SignPost(decorFolder, titleFrame, GameConfig.GameName or "Brainrot Incremental But With Guns", Vector2.new(56, 11), PINK, Common.Colors.White, 18)
	for _, side in ipairs({ -1, 1 }) do
		-- "Cabecinhas" brainrot em cima dos postes.
		local head = (titleFrame * CFrame.new(side * 27.5, 19.6, 0)).Position
		Common.Ball(decorFolder, head, 3.2, if side < 0 then BRAINROT_PURPLE else rgb(255, 170, 40), Enum.Material.SmoothPlastic)
		Common.Ball(decorFolder, (titleFrame * CFrame.new(side * 27.5 - 0.6, 20.1, -1.35)).Position, 0.8, Common.Colors.White, Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
		Common.Ball(decorFolder, (titleFrame * CFrame.new(side * 27.5 + 0.6, 20.1, -1.35)).Position, 0.8, Common.Colors.White, Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
	end

	-- 4. Estações ---------------------------------------------------------------------------------
	local createTerminal = buildTerminal(stationsFolder, facingCenter(TERMINAL_POSITION))
	local partyBoard = buildPartyBoard(stationsFolder, facingCenter(PARTY_BOARD_POSITION))
	local leaderboard = buildLeaderboard(stationsFolder, facingCenter(LEADERBOARD_POSITION))
	local shopStand = buildShop(stationsFolder, facingCenter(SHOP_POSITION))
	local achievementsStand = buildAchievements(stationsFolder, facingCenter(ACHIEVEMENTS_POSITION))
	buildSettingsKiosk(stationsFolder, facingCenter(SETTINGS_POSITION))

	-- 5. Estátuas de brainrots em volta da praça ---------------------------------------------------
	local factory = nil
	local okFactory, factoryResult = pcall(function()
		local worldFolder = script.Parent.Parent
		local module = worldFolder:FindFirstChild("BrainrotFactory")
		return module and require(module) or nil
	end)
	if okFactory and type(factoryResult) == "table" and type(factoryResult.Build) == "function" then
		factory = factoryResult
	else
		warn("[Lobby] BrainrotFactory indisponível; usando estátuas simples. " .. tostring(factoryResult))
	end
	local statuesFolder = Common.Folder("Statues", decorFolder)
	local statueDefs = pickStatueDefs()
	for index, def in ipairs(statueDefs) do
		local angle = (index - 1) * (math.pi * 2 / math.max(#statueDefs, 1))
		local position = Vector3.new(math.cos(angle) * STATUE_RADIUS, GROUND_Y, math.sin(angle) * STATUE_RADIUS)
		buildStatue(statuesFolder, factory, def, position)
	end

	-- 6. Fazenda: celeiro, plantações e feno -------------------------------------------------------
	buildBarn(decorFolder, CFrame.lookAt(BARN_POSITION, Vector3.new(0, GROUND_Y, 0)))
	buildCropField(decorFolder, Vector3.new(-68, GROUND_Y, 70), Vector2.new(26, 20), rgb(90, 170, 60))
	buildCropField(decorFolder, Vector3.new(68, GROUND_Y, 70), Vector2.new(26, 20), rgb(120, 190, 70))
	for index = 1, 5 do
		local position = BARN_POSITION + Vector3.new(-18 + index * 2.2, 1.5, 12 + (index % 2) * 3)
		Common.Part({
			Name = "HayBale",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(3, 3, 3),
			CFrame = CFrame.new(position) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
			Color = rgb(225, 190, 90),
			Material = Enum.Material.Fabric,
			Parent = decorFolder,
		})
	end

	-- 7. Árvores e lampiões --------------------------------------------------------------------------
	local function isFreeForTree(x, z)
		if Vector2.new(x - BARN_POSITION.X, z - BARN_POSITION.Z).Magnitude < 24 then
			return false
		end
		for _, field in ipairs({ Vector2.new(-68, 70), Vector2.new(68, 70) }) do
			if math.abs(x - field.X) < 18 and math.abs(z - field.Y) < 16 then
				return false
			end
		end
		if math.abs(x) < 34 and z < -66 then
			return false -- placa do nome
		end
		if math.abs(x) < 8 then
			return false -- caminhos
		end
		return true
	end
	local treesFolder = Common.Folder("Trees", decorFolder)
	local placed = {}
	local attempts = 0
	while #placed < 26 and attempts < 600 do
		attempts += 1
		local x = rng:NextNumber(-90, 90)
		local z = rng:NextNumber(-90, 90)
		if (math.abs(x) > 76 or math.abs(z) > 76) and isFreeForTree(x, z) then
			local ok = true
			for _, other in ipairs(placed) do
				if (other - Vector2.new(x, z)).Magnitude < 12 then
					ok = false
					break
				end
			end
			if ok then
				table.insert(placed, Vector2.new(x, z))
				Common.Tree(treesFolder, Vector3.new(x, GROUND_Y - 0.2, z), if rng:NextNumber() < 0.25 then "Pine" else "Oak", rng:NextNumber(1, 1.4))
			end
		end
	end
	-- Árvores fora da cerca (horizonte).
	for index = 1, 18 do
		local angle = (index / 18) * math.pi * 2 + rng:NextNumber(-0.1, 0.1)
		local distance = rng:NextNumber(PLAY_SIZE / 2 + 12, PLAY_SIZE / 2 + 40)
		Common.Tree(treesFolder, Vector3.new(math.cos(angle) * distance, GROUND_Y, math.sin(angle) * distance), "Oak", rng:NextNumber(1.3, 1.8))
	end

	for index = 0, 7 do
		local angle = index * math.pi / 4 + math.pi / 8
		Common.Lamp(decorFolder, Vector3.new(math.cos(angle) * (PLAZA_RADIUS + 6), GROUND_Y, math.sin(angle) * (PLAZA_RADIUS + 6)))
	end

	-- 8. Contexto do lobby (seção 7.2) -------------------------------------------------------------
	return {
		MapId = "Lobby",
		Folder = folder,
		SpawnLocation = spawnLocation,
		GroundY = GROUND_Y,
		CreateTerminal = createTerminal,
		PartyBoard = partyBoard,
		Leaderboard = leaderboard,
		ShopStand = shopStand,
		AchievementsStand = achievementsStand,
	}
end

return Lobby
