--!nonstrict
-- Builders/Winter: monta o mapa do Ato 2, "Tundra Congelini" (seção 7.5).
--
-- Layout "peixe no barril" (Y = 0 é o chão do vale; -Z = norte, +Z = sul):
--   * Vale de neve ~420×420 jogável, cercado de morros nevados, pinheiros e pedras.
--   * No centro, uma plataforma de madeira elevada (80×80, topo em Y = 14) sobre pilares,
--     com guarda-corpo e uma rampa descendo para o sul.
--   * Em cima da plataforma: as barracas, o quadro (Board), o caixote e o círculo das moedas,
--     a estação de torretas (RecallPrompt), os pads das torretas (TurretBase) e a base do portal.
--   * Os brainrots nascem no vale em volta (FieldArea grande; o BrainrotService evita a
--     plataforma). Torretas podem ficar na plataforma ou no vale (TurretZones).
--   * SnowEmitterPart: peça invisível bem alta com partículas de neve cobrindo o mapa.
--
-- Build(folder) devolve o ctx da seção 7.2.
-- Módulo de World: NÃO dá require em nenhum serviço (regra 1.2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Maps = require(Config:WaitForChild("Maps"))
local Upgrades = require(Config:WaitForChild("Upgrades"))

local Common = require(script.Parent:WaitForChild("Common"))

local Winter = {}

-------------------------------------------------------------------------------
-- Constantes do layout (tamanhos e posições, não são balanceamento)
-------------------------------------------------------------------------------

local MAP_ID = "Winter"
local GROUND_Y = 0
local GROUND_SIZE = 900
local PLAY_SIZE = 420

local PLATFORM_SIZE = 80
local PLATFORM_TOP = GROUND_Y + 14 -- altura do piso da plataforma
local PLATFORM_THICKNESS = 2
local PILLAR_GRID = { -36, -12, 12, 36 }

local RAMP_WIDTH = 12
local RAMP_LENGTH = 34 -- distância horizontal da rampa (a partir da borda sul)

local FIELD_SIZE = 340 -- área (quadrada) onde os brainrots nascem
local TREE_BAND_START = 178 -- pinheiros ficam além do campo, perto das paredes

-- Barracas na plataforma: posição (topo da plataforma) e para onde olham.
-- As três primeiras ficam no lado norte, viradas para o sul; a quarta no lado oeste.
local STALL_SLOTS = {
	{ Position = Vector3.new(-24, 0, -33), Facing = Vector3.new(0, 0, 1) },
	{ Position = Vector3.new(0, 0, -33), Facing = Vector3.new(0, 0, 1) },
	{ Position = Vector3.new(24, 0, -33), Facing = Vector3.new(0, 0, 1) },
	{ Position = Vector3.new(-33, 0, -4), Facing = Vector3.new(1, 0, 0) },
}

local BOARD_OFFSET = Vector3.new(34, 0, -14) -- lado leste, virado para oeste
local RECALL_OFFSET = Vector3.new(33, 0, 6)
local CRATE_OFFSET = Vector3.new(28, 0, 20)
local COIN_DROP_OFFSET = Vector3.new(15, 0, 16)
local COIN_MARKER_RADIUS = 7.5
local SPAWN_OFFSET = Vector3.new(0, 0, 2)
local PORTAL_OFFSET = Vector3.new(-30, 0, 20) -- lado oeste-sul, virado para leste

-- Pads das torretas (12): duas fileiras perto da borda sul, dos dois lados da rampa.
local TURRET_PAD_OFFSETS = {
	Vector3.new(-33, 0, 34),
	Vector3.new(-27, 0, 34),
	Vector3.new(-21, 0, 34),
	Vector3.new(-15, 0, 34),
	Vector3.new(15, 0, 34),
	Vector3.new(21, 0, 34),
	Vector3.new(27, 0, 34),
	Vector3.new(33, 0, 34),
	Vector3.new(-21, 0, 28),
	Vector3.new(-15, 0, 28),
	Vector3.new(15, 0, 28),
	Vector3.new(21, 0, 28),
}

-- Morros nevados dentro da área jogável: {x, z, raio da base, altura}.
local HILLS = {
	{ -190, -190, 50, 16 },
	{ 190, -190, 50, 16 },
	{ -190, 190, 50, 16 },
	{ 190, 190, 50, 16 },
	{ 0, -205, 45, 12 },
	{ -205, 0, 45, 12 },
	{ 205, 0, 45, 12 },
}

-- Montanhas fora da área jogável: fazem o "vale".
local MOUNTAINS = {
	{ -320, -320, 170, 90 },
	{ 0, -360, 170, 80 },
	{ 320, -320, 170, 95 },
	{ 360, 0, 160, 75 },
	{ 320, 320, 170, 90 },
	{ 0, 360, 170, 80 },
	{ -320, 320, 170, 85 },
	{ -360, 0, 160, 75 },
}

local rgb = Color3.fromRGB
local SNOW = rgb(236, 242, 250)
local SNOW_SHADE = rgb(222, 232, 246)
local ICE = rgb(170, 215, 240)
local DECK_WOOD = rgb(150, 110, 75)
local PILLAR_WOOD = rgb(100, 70, 48)

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Ponto em cima da plataforma (offset em X/Z a partir do centro).
local function onDeck(offset)
	return Vector3.new(offset.X, PLATFORM_TOP, offset.Z)
end

-- Sorteia pontos na faixa entre o campo e as paredes (onde ficam as árvores).
local function bandPoints(rng, count, minSpacing)
	local points = {}
	local limit = PLAY_SIZE / 2 - 8
	local attempts = 0
	while #points < count and attempts < count * 30 do
		attempts += 1
		local x = rng:NextNumber(-limit, limit)
		local z = rng:NextNumber(-limit, limit)
		if math.abs(x) >= TREE_BAND_START or math.abs(z) >= TREE_BAND_START then
			local ok = true
			for _, other in ipairs(points) do
				if (Vector2.new(x, z) - other).Magnitude < minSpacing then
					ok = false
					break
				end
			end
			if ok then
				table.insert(points, Vector2.new(x, z))
			end
		end
	end
	return points
end

-- Boneco de neve (3 bolas, nariz de cenoura, olhos e cachecol).
local function buildSnowman(parent, position, facing)
	local model = Common.Model("Snowman", parent)
	local look = CFrame.lookAt(position, position + facing)
	local base = Common.Ball(model, position + Vector3.new(0, 1.8, 0), 4, SNOW, Enum.Material.Snow)
	Common.Ball(model, position + Vector3.new(0, 4.6, 0), 3, SNOW, Enum.Material.Snow)
	Common.Ball(model, position + Vector3.new(0, 6.7, 0), 2.1, SNOW, Enum.Material.Snow)
	Common.Cylinder(model, position + Vector3.new(0, 5.6, 0), 0.5, 2.6, Common.Colors.Red, Enum.Material.Fabric, { CanCollide = false, CanQuery = false })
	-- Nariz de cenoura: começa dentro da cabeça e sai 1 stud para a frente.
	local nose = look * CFrame.new(0, 6.7, -0.8)
	Common.CylinderBetween(model, nose.Position, (nose * CFrame.new(0, 0, -1.1)).Position, 0.3, rgb(255, 140, 40), Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
	for _, x in ipairs({ -0.4, 0.4 }) do
		Common.Ball(model, (look * CFrame.new(x, 7.05, -0.95)).Position, 0.25, rgb(25, 25, 30), Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
	end
	model.PrimaryPart = base
	return model
end

-- Aglomerado de cristais de gelo (blocos translúcidos inclinados).
local function buildIceCrystals(parent, rng, position)
	local model = Common.Model("IceCrystals", parent)
	for index = 1, 3 do
		local height = rng:NextNumber(4, 9)
		local offset = Vector3.new(rng:NextNumber(-1.5, 1.5), 0, rng:NextNumber(-1.5, 1.5))
		local cframe = CFrame.new(position + offset + Vector3.new(0, height / 2 - 0.5, 0))
			* CFrame.Angles(rng:NextNumber(-0.35, 0.35), rng:NextNumber(0, math.pi), rng:NextNumber(-0.35, 0.35))
		local crystal = Common.Block(model, cframe, Vector3.new(1.4, height, 1.4), ICE, Enum.Material.Glass, {
			Transparency = 0.25,
			Reflectance = 0.2,
		})
		crystal.Name = "Crystal" .. index
	end
	return model
end

-- Iglu: meia esfera de neve com entrada.
local function buildIgloo(parent, position, facing)
	local model = Common.Model("Igloo", parent)
	local dome = Common.Ball(model, position + Vector3.new(0, -1, 0), 14, SNOW_SHADE, Enum.Material.Snow)
	dome.Name = "Dome"
	local look = CFrame.lookAt(position, position + facing)
	Common.Block(model, look * CFrame.new(0, 2, -6.8), Vector3.new(4, 4, 3), SNOW, Enum.Material.Snow)
	Common.Block(model, look * CFrame.new(0, 1.6, -8.35), Vector3.new(2.6, 3.2, 0.2), rgb(40, 50, 70), Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
	model.PrimaryPart = dome
	return model
end

-- Emissor de partículas de neve (flocos caindo devagar com um ventinho).
local function addSnowEmitter(part)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Snow"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	emitter.LightEmission = 0.2
	emitter.LightInfluence = 0.8
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0.25),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.85, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(10, 14)
	emitter.Rate = 500
	emitter.Speed = NumberRange.new(6, 9)
	emitter.SpreadAngle = Vector2.new(20, 20)
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.Acceleration = Vector3.new(1.5, -0.6, 0.6)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-45, 45)
	emitter.Parent = part
	return emitter
end

-------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------

function Winter.Build(folder)
	local rng = Random.new()
	local mapDef = Maps[MAP_ID]

	local terrainFolder = Common.Folder("Terrain", folder)
	local platformFolder = Common.Folder("Platform", folder)
	local stallsFolder = Common.Folder("Stalls", folder)
	local natureFolder = Common.Folder("Nature", folder)
	local helpersFolder = Common.Folder("Helpers", folder)

	-- 1. Vale de neve, morros e limites ---------------------------------------------
	Common.Ground(terrainFolder, Vector3.new(GROUND_SIZE, 4, GROUND_SIZE), SNOW, Enum.Material.Snow)
	Common.Bounds(helpersFolder, Vector3.new(0, GROUND_Y, 0), Vector2.new(PLAY_SIZE, PLAY_SIZE), 90)

	local hills = {}
	for _, hill in ipairs(HILLS) do
		table.insert(hills, Common.Hill(terrainFolder, Vector3.new(hill[1], GROUND_Y, hill[2]), hill[3], hill[4], SNOW_SHADE, Enum.Material.Snow))
	end
	for _, mountain in ipairs(MOUNTAINS) do
		Common.Hill(terrainFolder, Vector3.new(mountain[1], GROUND_Y, mountain[2]), mountain[3], mountain[4], SNOW_SHADE, Enum.Material.Snow)
	end

	-- Lagos congelados no vale (os brainrots podem nascer em cima deles).
	for _, pond in ipairs({ { -95, 95, 22 }, { 105, -85, 18 }, { -110, -120, 14 } }) do
		local ice = Common.Cylinder(terrainFolder, Vector3.new(pond[1], GROUND_Y + 0.1, pond[2]), 0.2, pond[3] * 2, ICE, Enum.Material.Ice, {
			Name = "FrozenPond",
			Reflectance = 0.25,
		})
		ice.Transparency = 0.1
	end

	-- 2. Plataforma elevada ------------------------------------------------------------
	local platform = Common.Block(platformFolder, CFrame.new(0, PLATFORM_TOP - PLATFORM_THICKNESS / 2, 0), Vector3.new(PLATFORM_SIZE, PLATFORM_THICKNESS, PLATFORM_SIZE), DECK_WOOD, Enum.Material.WoodPlanks)
	platform.Name = "Platform"

	-- Pilares (troncos) e vigas em volta.
	local pillarHeight = PLATFORM_TOP - PLATFORM_THICKNESS
	for _, x in ipairs(PILLAR_GRID) do
		for _, z in ipairs(PILLAR_GRID) do
			Common.Cylinder(platformFolder, Vector3.new(x, GROUND_Y + pillarHeight / 2, z), pillarHeight, 2.4, PILLAR_WOOD, Enum.Material.Wood)
		end
	end
	local half = PLATFORM_SIZE / 2
	for _, beam in ipairs({
		{ Vector3.new(0, 7, -36), Vector3.new(PLATFORM_SIZE - 6, 1, 1) },
		{ Vector3.new(0, 7, 36), Vector3.new(PLATFORM_SIZE - 6, 1, 1) },
		{ Vector3.new(-36, 7, 0), Vector3.new(1, 1, PLATFORM_SIZE - 6) },
		{ Vector3.new(36, 7, 0), Vector3.new(1, 1, PLATFORM_SIZE - 6) },
	}) do
		Common.Block(platformFolder, CFrame.new(beam[1]), beam[2], PILLAR_WOOD, Enum.Material.Wood)
	end
	-- Borda de neve acumulada na beirada da plataforma (só visual).
	for _, edge in ipairs({
		{ Vector3.new(0, PLATFORM_TOP + 0.1, -half + 0.6), Vector3.new(PLATFORM_SIZE, 0.2, 1.2) },
		{ Vector3.new(-half + 0.6, PLATFORM_TOP + 0.1, 0), Vector3.new(1.2, 0.2, PLATFORM_SIZE) },
		{ Vector3.new(half - 0.6, PLATFORM_TOP + 0.1, 0), Vector3.new(1.2, 0.2, PLATFORM_SIZE) },
	}) do
		Common.Block(platformFolder, CFrame.new(edge[1]), edge[2], SNOW, Enum.Material.Snow, { CanCollide = false, CanQuery = false })
	end

	-- Guarda-corpo com abertura ao sul (para a rampa). Não bloqueia tiros.
	Common.Fence(platformFolder, Vector3.new(0, PLATFORM_TOP, 0), Vector2.new(PLATFORM_SIZE - 1, PLATFORM_SIZE - 1), 3, "South")

	-- Rampa do sul até o chão (placa inclinada; o topo dela encosta no piso da plataforma).
	local rampTop = Vector3.new(0, PLATFORM_TOP, half)
	local rampBottom = Vector3.new(0, GROUND_Y - 0.3, half + RAMP_LENGTH)
	local rampThickness = 1
	local ramp = Common.Slab(platformFolder, rampTop, rampBottom, RAMP_WIDTH, rampThickness, DECK_WOOD, Enum.Material.WoodPlanks)
	ramp.Name = "Ramp"
	ramp.CFrame = ramp.CFrame * CFrame.new(0, -rampThickness / 2, 0) -- desce meia espessura: o topo fica na linha
	-- Corrimãos da rampa e dois apoios embaixo.
	for _, side in ipairs({ -1, 1 }) do
		local x = side * (RAMP_WIDTH / 2 + 0.2)
		Common.Slab(platformFolder, Vector3.new(x, PLATFORM_TOP + 2.6, half), Vector3.new(x, GROUND_Y + 2.6, half + RAMP_LENGTH), 0.35, 0.35, Common.Colors.LightWood, Enum.Material.Wood, { CanCollide = false, CanQuery = false })
		Common.Block(platformFolder, CFrame.new(side * (RAMP_WIDTH / 2 - 1), GROUND_Y + 2.8, half + RAMP_LENGTH / 2), Vector3.new(1, 5.6, 1), PILLAR_WOOD, Enum.Material.Wood)
	end

	-- 3. Estações na plataforma ----------------------------------------------------------
	local stalls = {}
	for index, stallId in ipairs(mapDef and mapDef.Stalls or {}) do
		local slot = STALL_SLOTS[index]
		if not slot then
			warn(("[Winter] Sem lugar para a barraca %s (máximo %d)."):format(tostring(stallId), #STALL_SLOTS))
			break
		end
		local position = onDeck(slot.Position)
		local info = Upgrades.Stalls[stallId] or {}
		stalls[stallId] = Common.Stall(stallsFolder, stallId, CFrame.lookAt(position, position + slot.Facing), info.Color, info.Name or stallId)
	end

	local deckCenter = Vector3.new(0, PLATFORM_TOP, 0)
	local boardPosition = onDeck(BOARD_OFFSET)
	local board, boardPrompt = Common.Board(platformFolder, CFrame.lookAt(boardPosition, Vector3.new(0, PLATFORM_TOP, boardPosition.Z)))

	local recallPosition = onDeck(RECALL_OFFSET)
	local _, recallPrompt = Common.RecallStation(platformFolder, CFrame.lookAt(recallPosition, Vector3.new(0, PLATFORM_TOP, recallPosition.Z)))

	local cratePosition = onDeck(CRATE_OFFSET)
	local crate = Common.Crate(platformFolder, CFrame.lookAt(cratePosition, deckCenter))
	local coinDropPoint = onDeck(COIN_DROP_OFFSET)
	Common.CoinMarker(platformFolder, coinDropPoint, COIN_MARKER_RADIUS)

	local spawnLocation = Common.SpawnPad(platformFolder, onDeck(SPAWN_OFFSET), Vector2.new(10, 10), rgb(170, 220, 255))

	local portalPosition = onDeck(PORTAL_OFFSET)
	local portalSpot = CFrame.lookAt(portalPosition, Vector3.new(0, PLATFORM_TOP, portalPosition.Z))
	Common.PortalPad(platformFolder, portalSpot)

	-- Pads das torretas, virados para o vale (sul).
	local turretBase = {}
	local padsFolder = Common.Folder("TurretPads", platformFolder)
	for _, offset in ipairs(TURRET_PAD_OFFSETS) do
		local position = onDeck(offset)
		local padCFrame = Common.TurretPad(padsFolder, CFrame.lookAt(position, position + Vector3.new(0, 0, 1)))
		table.insert(turretBase, padCFrame)
	end

	-- Lampiões nos cantos e uma fogueira decorativa perto do spawn.
	for _, corner in ipairs({ Vector3.new(-37.5, 0, -37.5), Vector3.new(37.5, 0, -37.5), Vector3.new(-37.5, 0, 37.5), Vector3.new(37.5, 0, 37.5) }) do
		Common.Lamp(platformFolder, onDeck(corner))
	end
	local firePosition = onDeck(Vector3.new(-12, 0, 12))
	for index = 1, 2 do
		local angle = index * math.pi / 2 + 0.4
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		Common.CylinderBetween(platformFolder, firePosition - direction * 1.6 + Vector3.new(0, 0.35, 0), firePosition + direction * 1.6 + Vector3.new(0, 0.35, 0), 0.7, Common.Colors.Trunk, Enum.Material.Wood, { CanCollide = false, CanQuery = false })
	end
	local fireCore = Common.Block(platformFolder, CFrame.new(firePosition + Vector3.new(0, 0.6, 0)), Vector3.new(0.6, 0.6, 0.6), rgb(255, 140, 50), Enum.Material.Neon, {
		Name = "Campfire",
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	local fire = Instance.new("Fire")
	fire.Size = 4
	fire.Heat = 6
	fire.Parent = fireCore
	local fireLight = Instance.new("PointLight")
	fireLight.Color = rgb(255, 150, 70)
	fireLight.Range = 16
	fireLight.Brightness = 1.6
	fireLight.Shadows = false
	fireLight.Parent = fireCore

	-- Placa de boas-vindas no pé da rampa.
	local signPosition = Vector3.new(14, GROUND_Y, half + RAMP_LENGTH + 4)
	Common.SignPost(natureFolder, CFrame.lookAt(signPosition, signPosition + Vector3.new(0, 0, 1)), mapDef and mapDef.DisplayName or "Tundra Congelini", Vector2.new(14, 3), rgb(70, 130, 200), Common.Colors.White, 7)

	-- 4. Natureza: pinheiros nevados, pedras, bonecos de neve, cristais e iglu ------------
	for _, point in ipairs(bandPoints(rng, 46, 9)) do
		local y = Common.SurfaceHeight(hills, point.X, point.Y, GROUND_Y) - 0.4
		Common.Tree(natureFolder, Vector3.new(point.X, y, point.Y), "Pine", rng:NextNumber(1.1, 1.7), { Snow = true })
	end
	for _, point in ipairs(bandPoints(rng, 14, 14)) do
		local y = Common.SurfaceHeight(hills, point.X, point.Y, GROUND_Y)
		Common.Rock(natureFolder, Vector3.new(point.X, y, point.Y), rng:NextNumber(5, 10), { Color = rgb(120, 125, 135), Snow = true })
	end
	for _, spot in ipairs({ Vector3.new(185, GROUND_Y, 40), Vector3.new(-185, GROUND_Y, -60), Vector3.new(60, GROUND_Y, 190), Vector3.new(-40, GROUND_Y, -188) }) do
		buildSnowman(natureFolder, spot, (Vector3.new(0, GROUND_Y, 0) - spot).Unit)
	end
	for _, spot in ipairs({ Vector3.new(-186, GROUND_Y, 120), Vector3.new(188, GROUND_Y, -110), Vector3.new(120, GROUND_Y, 188), Vector3.new(-120, GROUND_Y, -186), Vector3.new(186, GROUND_Y, 130) }) do
		buildIceCrystals(natureFolder, rng, spot)
	end
	buildIgloo(natureFolder, Vector3.new(-150, GROUND_Y, 192), Vector3.new(0.3, 0, -1).Unit)
	-- Pinheiros além das paredes (horizonte).
	for index = 1, 20 do
		local angle = (index / 20) * math.pi * 2 + rng:NextNumber(-0.08, 0.08)
		local distance = rng:NextNumber(PLAY_SIZE / 2 + 15, PLAY_SIZE / 2 + 50)
		Common.Tree(natureFolder, Vector3.new(math.cos(angle) * distance, GROUND_Y, math.sin(angle) * distance), "Pine", rng:NextNumber(1.5, 2.2), { Snow = true })
	end

	-- 5. Partes auxiliares: FieldArea, zonas de torreta e neve ---------------------------
	local fieldArea = Common.Zone(helpersFolder, "FieldArea", CFrame.new(0, GROUND_Y + 2, 0), Vector3.new(FIELD_SIZE, 4, FIELD_SIZE))

	local turretZones = {
		Common.Zone(helpersFolder, "TurretZone", CFrame.new(0, PLATFORM_TOP, 0), Vector3.new(PLATFORM_SIZE, 2, PLATFORM_SIZE), { TurretZone = true }),
		Common.Zone(helpersFolder, "TurretZone", CFrame.new(0, GROUND_Y + 1, 0), Vector3.new(PLAY_SIZE - 20, 2, PLAY_SIZE - 20), { TurretZone = true }),
	}

	local snowEmitterPart = Common.Zone(helpersFolder, "SnowEmitter", CFrame.new(0, GROUND_Y + 90, 0), Vector3.new(PLAY_SIZE, 1, PLAY_SIZE))
	addSnowEmitter(snowEmitterPart)

	-- 6. Céu e efeitos: luz fria e sol pequeno atrás da nevasca ---------------------------
	Common.SetSun(12)
	Common.LightingEffect("ColorCorrectionEffect", { TintColor = rgb(228, 240, 255), Saturation = -0.06, Contrast = 0.02 })
	Common.LightingEffect("BloomEffect", { Intensity = 0.3, Size = 20, Threshold = 2.2 })

	-- 7. Contexto (seção 7.2) -----------------------------------------------------------
	return {
		MapId = MAP_ID,
		Folder = folder,
		SpawnLocation = spawnLocation,
		GroundY = GROUND_Y,
		FieldArea = fieldArea,
		Board = board,
		BoardPrompt = boardPrompt,
		Crate = crate,
		CoinDropPoint = coinDropPoint,
		Stalls = stalls,
		PortalSpot = portalSpot,
		TurretZones = turretZones,
		TurretBase = turretBase,
		RecallPrompt = recallPrompt,
		Platform = platform,
		SnowEmitterPart = snowEmitterPart,
	}
end

return Winter
