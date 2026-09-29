--!nonstrict
-- Builders/Meadow: monta o mapa do Ato 1, "Prado Brainrot" (seção 7.5).
--
-- Layout (Y = 0 é o chão; -Z = norte, +Z = sul):
--   * Chão de grama ~420×420 jogável (paredes invisíveis na borda) e grama além dela.
--   * Campo retangular 200×150 no centro-norte, com listras de grama cortada e cerca
--     de madeira com portão ao sul. FieldArea = o retângulo do campo, 2 studs acima do chão.
--   * Ao sul, a "praça" de pedra: quadro (Board), caixote e círculo das moedas,
--     as barracas lado a lado viradas para o campo, o spawn e a base do portal.
--   * Em volta: colinas (esferas meio enterradas), árvores, lago, moinho, flores e lampiões.
--
-- Build(folder) devolve o ctx da seção 7.2.
-- Módulo de World: NÃO dá require em nenhum serviço (regra 1.2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Maps = require(Config:WaitForChild("Maps"))
local Upgrades = require(Config:WaitForChild("Upgrades"))

local Common = require(script.Parent:WaitForChild("Common"))

local Meadow = {}

-------------------------------------------------------------------------------
-- Constantes do layout (tamanhos e posições, não são balanceamento)
-------------------------------------------------------------------------------

local MAP_ID = "Meadow"
local GROUND_Y = 0
local GROUND_SIZE = 900 -- o chão vai além da área jogável (horizonte bonito)
local PLAY_SIZE = 420 -- área jogável (paredes invisíveis)

local FIELD_CENTER = Vector3.new(0, GROUND_Y, -40)
local FIELD_SIZE = Vector2.new(200, 150)
local FIELD_STRIPES = 10

local PLAZA_CENTER = Vector3.new(0, GROUND_Y, 95)
local PLAZA_SIZE = Vector2.new(170, 90)
local PLAZA_THICKNESS = 0.3
local PLAZA_Y = GROUND_Y + PLAZA_THICKNESS -- topo da praça

local STALL_Z = 122 -- linha das barracas (viradas para o norte, para o campo)
local STALL_SLOTS_X = { -34, 0, 34, -68, 68 } -- posições X das barracas, na ordem do Config

local BOARD_POSITION = Vector3.new(-30, PLAZA_Y, 64)
local CRATE_POSITION = Vector3.new(42, PLAZA_Y, 64)
local COIN_DROP_POINT = Vector3.new(28, PLAZA_Y, 72)
local COIN_MARKER_RADIUS = 8
local SPAWN_POSITION = Vector3.new(0, PLAZA_Y, 92)
local PORTAL_POSITION = Vector3.new(72, PLAZA_Y, 80)
local LOOK_TARGET = Vector3.new(0, PLAZA_Y, 95) -- quadro e caixote olham para o meio da praça

local POND_CENTER = Vector3.new(-140, GROUND_Y, 10)
local POND_RADIUS = 15
local WINDMILL_POSITION = Vector3.new(150, GROUND_Y, 118)

local TREE_COUNT = 44
local FLOWER_COUNT = 60

-- Colinas dentro da área jogável: {x, z, raio da base, altura}.
local HILLS = {
	{ -160, -150, 45, 14 },
	{ -172, -45, 38, 11 },
	{ -165, 72, 36, 10 },
	{ -150, 170, 45, 14 },
	{ 160, -150, 45, 14 },
	{ 172, -45, 38, 11 },
	{ 170, 60, 34, 10 },
	{ -60, -172, 40, 12 },
	{ 60, -172, 40, 12 },
	{ 0, 182, 32, 8 },
}

-- Morros grandes fora da área jogável (só paisagem).
local BACKGROUND_HILLS = {
	{ -300, -250, 120, 55 },
	{ 0, -330, 140, 60 },
	{ 300, -240, 130, 50 },
	{ 330, 60, 110, 40 },
	{ 280, 300, 120, 45 },
	{ -20, 330, 130, 42 },
	{ -310, 260, 120, 48 },
	{ -340, 20, 110, 38 },
}

local rgb = Color3.fromRGB
local GRASS = rgb(96, 170, 72)
local STRIPE_A = rgb(104, 178, 74)
local STRIPE_B = rgb(88, 160, 62)
local HILL_GREEN = rgb(92, 165, 66)
local COBBLE = rgb(186, 176, 160)
local DIRT = rgb(165, 125, 85)
local FLOWER_COLORS = {
	rgb(255, 90, 120),
	rgb(255, 210, 60),
	rgb(170, 110, 255),
	rgb(255, 255, 255),
	rgb(255, 140, 60),
}

-------------------------------------------------------------------------------
-- Ajudantes de posição
-------------------------------------------------------------------------------

-- true se (x, z) fica livre do campo, da praça, do lago e do moinho (com uma margem).
local function isFree(x, z, margin)
	margin = margin or 0
	-- Campo (com a cerca).
	if math.abs(x - FIELD_CENTER.X) < FIELD_SIZE.X / 2 + 8 + margin and math.abs(z - FIELD_CENTER.Z) < FIELD_SIZE.Y / 2 + 8 + margin then
		return false
	end
	-- Praça e barracas.
	if math.abs(x - PLAZA_CENTER.X) < PLAZA_SIZE.X / 2 + 6 + margin and math.abs(z - PLAZA_CENTER.Z) < PLAZA_SIZE.Y / 2 + 6 + margin then
		return false
	end
	-- Lago.
	if Vector2.new(x - POND_CENTER.X, z - POND_CENTER.Z).Magnitude < POND_RADIUS + 6 + margin then
		return false
	end
	-- Moinho.
	if Vector2.new(x - WINDMILL_POSITION.X, z - WINDMILL_POSITION.Z).Magnitude < 10 + margin then
		return false
	end
	return true
end

-- Sorteia pontos livres dentro da área jogável.
local function scatterPoints(rng, count, margin, limit)
	local points = {}
	local attempts = 0
	while #points < count and attempts < count * 25 do
		attempts += 1
		local x = rng:NextNumber(-limit, limit)
		local z = rng:NextNumber(-limit, limit)
		if isFree(x, z, margin) then
			local tooClose = false
			for _, other in ipairs(points) do
				if (Vector2.new(x, z) - other).Magnitude < margin * 2 + 4 then
					tooClose = true
					break
				end
			end
			if not tooClose then
				table.insert(points, Vector2.new(x, z))
			end
		end
	end
	return points
end

-------------------------------------------------------------------------------
-- Partes do mapa
-------------------------------------------------------------------------------

-- Moinho de vento decorativo (torre, telhado e 4 pás).
local function buildWindmill(parent, position)
	local model = Common.Model("Windmill", parent)
	local tower = Common.Cylinder(model, position + Vector3.new(0, 9, 0), 18, 9, rgb(235, 225, 205), Enum.Material.Brick)
	tower.Name = "Tower"
	Common.Cylinder(model, position + Vector3.new(0, 18.6, 0), 1.2, 10, Common.Colors.DarkWood, Enum.Material.Wood)
	Common.Ball(model, position + Vector3.new(0, 19.5, 0), 9, Common.Colors.Red, Enum.Material.WoodPlanks)
	Common.Block(model, CFrame.new(position + Vector3.new(0, 2.5, -4.4)), Vector3.new(3, 5, 0.6), Common.Colors.DarkWood, Enum.Material.Wood)

	-- Pás viradas para a praça (sul), num X inclinado.
	local hub = position + Vector3.new(0, 16, 5.2)
	Common.Cylinder(model, CFrame.new(hub) * CFrame.Angles(math.pi / 2, 0, 0), 1.6, 1.6, Common.Colors.DarkWood, Enum.Material.Wood)
	for index = 0, 3 do
		local angle = math.rad(45 + index * 90)
		local direction = Vector3.new(math.cos(angle), math.sin(angle), 0)
		local bladeCenter = hub + direction * 6 + Vector3.new(0, 0, 0.6)
		Common.Block(model, CFrame.lookAt(bladeCenter, bladeCenter + Vector3.new(0, 0, 1), direction), Vector3.new(2.4, 11, 0.25), rgb(245, 240, 230), Enum.Material.Fabric)
	end
	model.PrimaryPart = tower
	return model
end

-- Lago com borda de areia e alguns juncos.
local function buildPond(parent, center, radius)
	local model = Common.Model("Pond", parent)
	Common.Cylinder(model, center + Vector3.new(0, 0.05, 0), 0.1, radius * 2 + 5, rgb(214, 196, 150), Enum.Material.Sand)
	local water = Common.Cylinder(model, center + Vector3.new(0, 0.12, 0), 0.12, radius * 2, rgb(70, 150, 210), Enum.Material.Glass, {
		Name = "Water",
		Transparency = 0.25,
		Reflectance = 0.15,
	})
	for index = 1, 8 do
		local angle = index * 0.8
		local point = center + Vector3.new(math.cos(angle) * (radius + 1.2), 0, math.sin(angle) * (radius + 1.2))
		Common.Cylinder(model, point + Vector3.new(0, 1.2, 0), 2.4, 0.25, rgb(90, 140, 60), Enum.Material.Grass, { CanCollide = false, CanQuery = false })
	end
	model.PrimaryPart = water
	return model
end

-- Banco de praça (assento, encosto e pés).
local function buildBench(parent, cframe)
	local model = Common.Model("Bench", parent)
	Common.Block(model, cframe * CFrame.new(0, 1.6, 0), Vector3.new(6, 0.35, 1.6), Common.Colors.Wood, Enum.Material.WoodPlanks)
	Common.Block(model, cframe * CFrame.new(0, 2.6, 0.75), Vector3.new(6, 1.4, 0.3), Common.Colors.Wood, Enum.Material.WoodPlanks)
	for _, x in ipairs({ -2.6, 2.6 }) do
		Common.Block(model, cframe * CFrame.new(x, 0.8, 0), Vector3.new(0.4, 1.6, 1.4), Common.Colors.DarkMetal, Enum.Material.Metal)
	end
	return model
end

-- Fardo de feno (cilindro deitado).
local function buildHayBale(parent, position, yaw)
	return Common.Part({
		Name = "HayBale",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(3, 3, 3),
		CFrame = CFrame.new(position + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, yaw, 0),
		Color = rgb(225, 190, 90),
		Material = Enum.Material.Fabric,
		Parent = parent,
	})
end

-------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------

function Meadow.Build(folder)
	local rng = Random.new()
	local mapDef = Maps[MAP_ID]

	-- Pastas para organizar o Explorer.
	local terrainFolder = Common.Folder("Terrain", folder)
	local fieldFolder = Common.Folder("Field", folder)
	local plazaFolder = Common.Folder("Plaza", folder)
	local stallsFolder = Common.Folder("Stalls", folder)
	local natureFolder = Common.Folder("Nature", folder)
	local helpersFolder = Common.Folder("Helpers", folder)

	-- 1. Chão, colinas e limites -------------------------------------------------
	Common.Ground(terrainFolder, Vector3.new(GROUND_SIZE, 4, GROUND_SIZE), GRASS, Enum.Material.Grass)
	Common.Bounds(helpersFolder, Vector3.new(0, GROUND_Y, 0), Vector2.new(PLAY_SIZE, PLAY_SIZE), 90)

	local hills = {}
	for _, hill in ipairs(HILLS) do
		table.insert(hills, Common.Hill(terrainFolder, Vector3.new(hill[1], GROUND_Y, hill[2]), hill[3], hill[4], HILL_GREEN, Enum.Material.Grass))
	end
	for _, hill in ipairs(BACKGROUND_HILLS) do
		Common.Hill(terrainFolder, Vector3.new(hill[1], GROUND_Y, hill[2]), hill[3], hill[4], HILL_GREEN, Enum.Material.Grass)
	end

	-- 2. Campo: listras de grama cortada, cerca, portão e FieldArea ------------
	local stripeWidth = FIELD_SIZE.X / FIELD_STRIPES
	for index = 0, FIELD_STRIPES - 1 do
		local x = FIELD_CENTER.X - FIELD_SIZE.X / 2 + stripeWidth * (index + 0.5)
		local stripe = Common.Block(fieldFolder, CFrame.new(x, GROUND_Y + 0.1, FIELD_CENTER.Z), Vector3.new(stripeWidth, 0.2, FIELD_SIZE.Y), if index % 2 == 0 then STRIPE_A else STRIPE_B, Enum.Material.Grass)
		stripe.Name = "FieldGrass"
	end
	Common.Fence(fieldFolder, FIELD_CENTER, FIELD_SIZE + Vector2.new(4, 4), 3.5, "South")

	-- Portal de entrada do campo (arco com o nome do mapa sobre o portão sul).
	local gateZ = FIELD_CENTER.Z + (FIELD_SIZE.Y + 4) / 2
	Common.SignPost(fieldFolder, CFrame.lookAt(Vector3.new(0, GROUND_Y, gateZ), Vector3.new(0, GROUND_Y, gateZ + 1)), mapDef and mapDef.DisplayName or "Prado Brainrot", Vector2.new(19, 3.2), rgb(220, 75, 150), Common.Colors.White, 12)

	local fieldArea = Common.Zone(helpersFolder, "FieldArea", CFrame.new(FIELD_CENTER + Vector3.new(0, 2, 0)), Vector3.new(FIELD_SIZE.X - 4, 4, FIELD_SIZE.Y - 4))

	-- 3. Praça ---------------------------------------------------------------------
	local plaza = Common.Block(plazaFolder, CFrame.new(PLAZA_CENTER + Vector3.new(0, PLAZA_THICKNESS / 2, 0)), Vector3.new(PLAZA_SIZE.X, PLAZA_THICKNESS, PLAZA_SIZE.Y), COBBLE, Enum.Material.Cobblestone)
	plaza.Name = "Plaza"
	-- Trilha de terra do portão até a praça.
	local pathStart = gateZ - 2
	local pathEnd = PLAZA_CENTER.Z - PLAZA_SIZE.Y / 2 + 1
	Common.Block(plazaFolder, CFrame.new(0, GROUND_Y + 0.12, (pathStart + pathEnd) / 2), Vector3.new(14, 0.24, pathEnd - pathStart), DIRT, Enum.Material.Ground)

	-- Barracas lado a lado, viradas para o campo (norte).
	local stalls = {}
	for index, stallId in ipairs(mapDef and mapDef.Stalls or {}) do
		local slotX = STALL_SLOTS_X[index]
		if not slotX then
			warn(("[Meadow] Sem lugar para a barraca %s (máximo %d)."):format(tostring(stallId), #STALL_SLOTS_X))
			break
		end
		local position = Vector3.new(slotX, PLAZA_Y, STALL_Z)
		local info = Upgrades.Stalls[stallId] or {}
		stalls[stallId] = Common.Stall(stallsFolder, stallId, CFrame.lookAt(position, position + Vector3.new(0, 0, -1)), info.Color, info.Name or stallId)
	end

	-- Quadro, caixote, círculo das moedas e spawn.
	local board, boardPrompt = Common.Board(plazaFolder, CFrame.lookAt(BOARD_POSITION, LOOK_TARGET))
	local crate = Common.Crate(plazaFolder, CFrame.lookAt(CRATE_POSITION, LOOK_TARGET))
	Common.CoinMarker(plazaFolder, COIN_DROP_POINT, COIN_MARKER_RADIUS)
	local spawnLocation = Common.SpawnPad(plazaFolder, SPAWN_POSITION, Vector2.new(12, 12))

	-- Base do portal (o portal em si só aparece com MapBuilder.OpenPortal).
	local portalSpot = CFrame.lookAt(PORTAL_POSITION, Vector3.new(0, PLAZA_Y, PORTAL_POSITION.Z))
	Common.PortalPad(plazaFolder, portalSpot)

	-- Lampiões, bancos e fardos de feno em volta da praça.
	local halfX, halfZ = PLAZA_SIZE.X / 2, PLAZA_SIZE.Y / 2
	for _, x in ipairs({ -halfX + 3, halfX - 3 }) do
		for _, z in ipairs({ PLAZA_CENTER.Z - halfZ + 3, PLAZA_CENTER.Z, PLAZA_CENTER.Z + halfZ - 3 }) do
			Common.Lamp(plazaFolder, Vector3.new(x, PLAZA_Y, z))
		end
	end
	for _, x in ipairs({ -12, 12 }) do
		Common.Lamp(plazaFolder, Vector3.new(x, PLAZA_Y, PLAZA_CENTER.Z - halfZ + 3))
	end
	buildBench(plazaFolder, CFrame.lookAt(Vector3.new(-62, PLAZA_Y, 86), Vector3.new(-62, PLAZA_Y, 70)))
	buildBench(plazaFolder, CFrame.lookAt(Vector3.new(-50, PLAZA_Y, 86), Vector3.new(-50, PLAZA_Y, 70)))
	buildHayBale(plazaFolder, Vector3.new(56, PLAZA_Y, 58), 0.3)
	buildHayBale(plazaFolder, Vector3.new(59.5, PLAZA_Y, 60), 1.2)
	buildHayBale(plazaFolder, Vector3.new(-45, PLAZA_Y, 58), 2.1)

	-- 4. Natureza: lago, moinho, árvores e flores ------------------------------------
	buildPond(natureFolder, POND_CENTER, POND_RADIUS)
	buildWindmill(natureFolder, WINDMILL_POSITION)

	local limit = PLAY_SIZE / 2 - 12
	for _, point in ipairs(scatterPoints(rng, TREE_COUNT, 4, limit)) do
		local y = Common.SurfaceHeight(hills, point.X, point.Y, GROUND_Y) - 0.4
		local style = if rng:NextNumber() < 0.2 then "Pine" else "Oak"
		Common.Tree(natureFolder, Vector3.new(point.X, y, point.Y), style, rng:NextNumber(0.9, 1.4))
	end
	-- Algumas árvores fora das paredes, só para o horizonte não ficar vazio.
	for index = 1, 16 do
		local angle = (index / 16) * math.pi * 2 + rng:NextNumber(-0.1, 0.1)
		local distance = rng:NextNumber(PLAY_SIZE / 2 + 15, PLAY_SIZE / 2 + 45)
		Common.Tree(natureFolder, Vector3.new(math.cos(angle) * distance, GROUND_Y, math.sin(angle) * distance), "Oak", rng:NextNumber(1.2, 1.7))
	end

	-- Flores: bolinhas coloridas (decoração baixa, não bloqueiam nada).
	local flowers = Common.Folder("Flowers", natureFolder)
	for _, point in ipairs(scatterPoints(rng, FLOWER_COUNT, 0.5, limit - 10)) do
		local y = Common.SurfaceHeight(hills, point.X, point.Y, GROUND_Y)
		local color = FLOWER_COLORS[rng:NextInteger(1, #FLOWER_COLORS)]
		Common.Ball(flowers, Vector3.new(point.X, y + 0.45, point.Y), 0.9, color, Enum.Material.SmoothPlastic, {
			Name = "Flower",
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		})
	end

	-- 5. Céu e efeitos: sol grande e visível, luz de tarde ensolarada ---------------
	Common.SetSun(24)
	Common.LightingEffect("SunRaysEffect", { Intensity = 0.04, Spread = 0.55 })
	Common.LightingEffect("BloomEffect", { Intensity = 0.35, Size = 24, Threshold = 2 })
	Common.LightingEffect("ColorCorrectionEffect", { Saturation = 0.08, Contrast = 0.03 })

	-- 6. Contexto (seção 7.2) -------------------------------------------------------
	return {
		MapId = MAP_ID,
		Folder = folder,
		SpawnLocation = spawnLocation,
		GroundY = GROUND_Y,
		FieldArea = fieldArea,
		Board = board,
		BoardPrompt = boardPrompt,
		Crate = crate,
		CoinDropPoint = COIN_DROP_POINT,
		Stalls = stalls,
		PortalSpot = portalSpot,
		TurretZones = {}, -- o Prado não tem torretas
		TurretBase = {},
	}
end

return Meadow
