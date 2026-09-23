--!nonstrict
-- Builders/Desert: monta o mapa do Ato 3, "Deserto Sahur" (seção 7.5).
--
-- Layout (Y = 0 é a areia):
--   * Areia ~460×460 jogável, dunas nas bordas, pirâmides e dunas grandes no horizonte.
--   * Oásis no centro: lago azul, anel de grama, palmeiras e toldos. Em volta dele ficam as
--     5 barracas, o quadro (Board), o caixote, o caldeirão (Cauldron), a estação de torretas
--     (RecallPrompt) e os pads das torretas (TurretBase). Tudo isso dentro da "sombra" do
--     oásis (OasisRadius), onde o calor do deserto não pega.
--   * A Grande Cova (cratera) fica a 150 studs do oásis NA DIREÇÃO DO SOL
--     (Lighting:GetSunDirection() depois de ajustar o ClockTime, projetado no plano XZ),
--     para o Brainrot Supremo crescer bem na frente do sol. O prompt da cova (ClientAction
--     "Supreme") fica num altar na borda, do lado do oásis, com uma trilha até lá.
--   * Atributos OasisCenter (Vector3) e OasisRadius (number) na pasta workspace.Map
--     (o MovementController do cliente usa para o calor).
--
-- O layout do oásis é montado num "referencial do sol": o -Z local aponta para a cova,
-- então a abertura entre as barracas sempre fica virada para ela.
--
-- Build(folder) devolve o ctx da seção 7.2.
-- Módulo de World: NÃO dá require em nenhum serviço (regra 1.2).

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Maps = require(Config:WaitForChild("Maps"))
local Upgrades = require(Config:WaitForChild("Upgrades"))

local Common = require(script.Parent:WaitForChild("Common"))

local Desert = {}

-------------------------------------------------------------------------------
-- Constantes do layout (tamanhos e posições, não são balanceamento)
-------------------------------------------------------------------------------

local MAP_ID = "Desert"
local GROUND_Y = 0
local GROUND_SIZE = 1000
local PLAY_SIZE = 460

local OASIS_CENTER = Vector3.new(0, GROUND_Y, 0)
local OASIS_RADIUS = 60 -- raio da sombra do oásis (seguro contra o calor)
local LAKE_RADIUS = 15
local GRASS_RADIUS = 36
local DECK_Y = GROUND_Y + 0.1 -- topo do anel de grama (onde ficam as estações)

-- Posições no "referencial do sol": ângulo (graus, 0 = direção da cova) e raio.
local STALL_RING = 46
local STALL_ANGLES = { 80, 130, 180, 230, 280 } -- deixa a abertura virada para a cova
local BOARD_SPOT = { Angle = 38, Radius = 38 }
local CRATE_SPOT = { Angle = -38, Radius = 40 }
local COIN_SPOT = { Angle = -28, Radius = 27 }
local COIN_MARKER_RADIUS = 7.5
local CAULDRON_SPOT = { Angle = 155, Radius = 30 }
local RECALL_SPOT = { Angle = 205, Radius = 30 }
local SPAWN_SPOT = { Angle = 180, Radius = 20 }
local PORTAL_SPOT = { Angle = 0, Radius = 30 } -- o Deserto não tem portal; fica só a referência
local PAD_RING = 56
local PAD_COUNT = 12

-- Palmeiras do oásis: {ângulo, raio}.
local OASIS_PALMS = {
	{ 20, 29 },
	{ 60, 25 },
	{ 100, 30 },
	{ 125, 23 },
	{ 235, 23 },
	{ 260, 30 },
	{ 300, 25 },
	{ 45, 64 },
	{ 105, 64 },
	{ 155, 64 },
	{ 205, 64 },
	{ 255, 64 },
	{ 315, 64 },
}

-- Grande Cova.
local PIT_DISTANCE = 150 -- distância do oásis até o centro da cova
local PIT_FLOOR_RADIUS = 28 -- fundo plano
local PIT_CREST_RADIUS = 34 -- topo da borda
local PIT_OUTER_RADIUS = 42 -- pé da borda do lado de fora
local PIT_RIM_HEIGHT = 7
local PIT_RIM_THICKNESS = 1.5
local PIT_SEGMENTS = 20
local PIT_ALTAR_DISTANCE = 47 -- do centro da cova até o altar (lado do oásis)

local CACTUS_COUNT = 24
local ROCK_COUNT = 10

local rgb = Color3.fromRGB
local SAND = rgb(226, 196, 138)
local DUNE = rgb(218, 186, 128)
local SANDSTONE = rgb(205, 165, 105)
local RIM_SAND = rgb(208, 172, 118)
local GRASS = rgb(110, 172, 72)
local WATER = rgb(55, 160, 210)
local CACTUS_GREEN = rgb(70, 150, 80)

-------------------------------------------------------------------------------
-- Peças do mapa
-------------------------------------------------------------------------------

-- Tocha (poste com fogo e luz).
local function buildTorch(parent, position)
	local model = Common.Model("Torch", parent)
	local pole = Common.Cylinder(model, position + Vector3.new(0, 3, 0), 6, 0.45, Common.Colors.Trunk, Enum.Material.Wood)
	Common.Cylinder(model, position + Vector3.new(0, 6.2, 0), 0.8, 1.3, Common.Colors.DarkMetal, Enum.Material.Metal)
	local flame = Common.Block(model, CFrame.new(position + Vector3.new(0, 6.9, 0)), Vector3.new(0.6, 0.6, 0.6), rgb(255, 150, 50), Enum.Material.Neon, {
		Name = "Flame",
		CanCollide = false,
		CanQuery = false,
	})
	local fire = Instance.new("Fire")
	fire.Size = 2.5
	fire.Heat = 5
	fire.Parent = flame
	local light = Instance.new("PointLight")
	light.Color = rgb(255, 160, 80)
	light.Range = 12
	light.Brightness = 1.2
	light.Shadows = false
	light.Parent = flame
	model.PrimaryPart = pole
	return model
end

-- Cacto com braços (decoração no meio do campo: não bloqueia tiros).
local function buildCactus(parent, rng, position)
	local ghost = { CanCollide = false, CanQuery = false }
	local model = Common.Model("Cactus", parent)
	local height = rng:NextNumber(5, 9)
	local trunk = Common.Cylinder(model, position + Vector3.new(0, height / 2, 0), height, 1.6, CACTUS_GREEN, Enum.Material.Grass, ghost)
	Common.Ball(model, position + Vector3.new(0, height, 0), 1.6, CACTUS_GREEN, Enum.Material.Grass, ghost)
	local yaw = rng:NextNumber(0, math.pi * 2)
	local right = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
	for _, side in ipairs({ -1, 1 }) do
		if rng:NextNumber() < 0.8 then
			local armBase = position + Vector3.new(0, height * rng:NextNumber(0.4, 0.65), 0)
			local elbow = armBase + right * side * 1.9
			local armTop = elbow + Vector3.new(0, rng:NextNumber(1.6, 2.8), 0)
			Common.CylinderBetween(model, armBase, elbow, 1, CACTUS_GREEN, Enum.Material.Grass, ghost)
			Common.CylinderBetween(model, elbow, armTop, 1, CACTUS_GREEN, Enum.Material.Grass, ghost)
			Common.Ball(model, armTop, 1, CACTUS_GREEN, Enum.Material.Grass, ghost)
		end
	end
	Common.Ball(model, position + Vector3.new(0, height + 0.75, 0), 0.6, rgb(255, 105, 170), Enum.Material.SmoothPlastic, ghost)
	model.PrimaryPart = trunk
	return model
end

-- Pirâmide em degraus (paisagem no horizonte).
local function buildPyramid(parent, position, baseSize, layers)
	local model = Common.Model("Pyramid", parent)
	local layerHeight = baseSize / (layers * 1.7)
	for index = 0, layers - 1 do
		local size = baseSize * (1 - index / layers)
		local shade = if index % 2 == 0 then SANDSTONE else rgb(195, 155, 98)
		Common.Block(model, CFrame.new(position + Vector3.new(0, layerHeight * (index + 0.5), 0)), Vector3.new(size, layerHeight, size), shade, Enum.Material.Sandstone)
	end
	return model
end

-- Caldeirão das receitas (ClientAction = "Cauldron"). cframe = centro no chão.
local function buildCauldron(parent, cframe)
	local model = Common.Model("CauldronStation", parent)
	local ghost = { CanCollide = false, CanQuery = false }
	local iron = rgb(48, 48, 56)

	-- Três pés.
	for index = 0, 2 do
		local angle = index * math.pi * 2 / 3
		Common.Block(model, cframe * CFrame.new(math.cos(angle) * 3, 0.9, math.sin(angle) * 3), Vector3.new(0.6, 1.8, 0.6), iron, Enum.Material.Metal)
	end

	-- Fogueira embaixo do caldeirão.
	for index = 1, 2 do
		local angle = index * math.pi / 2 + 0.3
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local base = (cframe * CFrame.new(0, 0.3, 0)).Position
		Common.CylinderBetween(model, base - direction * 1.8, base + direction * 1.8, 0.6, Common.Colors.Trunk, Enum.Material.Wood, ghost)
	end
	local fireCore = Common.Block(model, cframe * CFrame.new(0, 0.6, 0), Vector3.new(0.5, 0.5, 0.5), rgb(255, 140, 50), Enum.Material.Neon, {
		Name = "CauldronFire",
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
	})
	local fire = Instance.new("Fire")
	fire.Size = 4
	fire.Heat = 3
	fire.Parent = fireCore

	-- Corpo (é a parte "Cauldron" do contexto), base mais estreita e borda.
	local pot = Common.Cylinder(model, cframe * CFrame.new(0, 3.8, 0), 4, 7, iron, Enum.Material.Metal)
	pot.Name = "Cauldron"
	Common.Cylinder(model, cframe * CFrame.new(0, 1.4, 0), 0.8, 5.4, iron, Enum.Material.Metal)
	Common.Cylinder(model, cframe * CFrame.new(0, 5.95, 0), 0.5, 7.8, rgb(35, 35, 42), Enum.Material.Metal)

	-- Poção verde brilhante com bolhas subindo.
	local potion = Common.Cylinder(model, cframe * CFrame.new(0, 6.26, 0), 0.12, 6.8, rgb(120, 255, 90), Enum.Material.Neon, ghost)
	potion.Name = "Potion"
	local bubbles = Instance.new("ParticleEmitter")
	bubbles.Name = "Bubbles"
	bubbles.Color = ColorSequence.new(rgb(150, 255, 120))
	bubbles.LightEmission = 0.6
	bubbles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0.7),
	})
	bubbles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	bubbles.Lifetime = NumberRange.new(1, 1.8)
	bubbles.Rate = 8
	bubbles.Speed = NumberRange.new(1.5, 3)
	bubbles.SpreadAngle = Vector2.new(15, 15)
	bubbles.EmissionDirection = Enum.NormalId.Right -- o eixo do cilindro (X) aponta para cima
	bubbles.Parent = potion
	local glow = Instance.new("PointLight")
	glow.Color = rgb(130, 255, 100)
	glow.Range = 14
	glow.Brightness = 1.5
	glow.Shadows = false
	glow.Parent = potion

	Common.Billboard(pot, "Caldeirão", Vector3.new(0, 5.5, 0))
	Common.Prompt(pot, "Cozinhar receitas", "Caldeirão", { ClientAction = "Cauldron" })
	model.PrimaryPart = pot
	return pot
end

-- Toldo de pano entre dois postes (sombra decorativa).
local function buildShadeSail(parent, fromTop, toTop, color)
	local model = Common.Model("ShadeSail", parent)
	for _, top in ipairs({ fromTop, toTop }) do
		Common.CylinderBetween(model, Vector3.new(top.X, GROUND_Y, top.Z), top, 0.5, Common.Colors.DarkWood, Enum.Material.Wood)
	end
	Common.Slab(model, fromTop, toTop, 12, 0.2, color, Enum.Material.Fabric, { CanCollide = false, CanQuery = false })
	return model
end

-------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------

function Desert.Build(folder)
	local rng = Random.new()
	local mapDef = Maps[MAP_ID]

	local terrainFolder = Common.Folder("Terrain", folder)
	local oasisFolder = Common.Folder("Oasis", folder)
	local stallsFolder = Common.Folder("Stalls", folder)
	local pitFolder = Common.Folder("GreatPit", folder)
	local natureFolder = Common.Folder("Nature", folder)
	local helpersFolder = Common.Folder("Helpers", folder)

	-- 0. Direção do sol ----------------------------------------------------------------
	-- O MapBuilder já aplicou a iluminação; por garantia, ajustamos o ClockTime aqui
	-- também antes de perguntar ao Lighting onde está o sol.
	local lightingConfig = mapDef and mapDef.Lighting
	if type(lightingConfig) == "table" and type(lightingConfig.ClockTime) == "number" then
		Lighting.ClockTime = lightingConfig.ClockTime
	end
	local sun = Lighting:GetSunDirection()
	local flatSun = Vector3.new(sun.X, 0, sun.Z)
	local forward = if flatSun.Magnitude > 0.05 then flatSun.Unit else Vector3.new(0, 0, -1)

	-- Referencial do oásis: LookVector (-Z local) aponta para a cova / para o sol.
	local frame = CFrame.lookAt(OASIS_CENTER, OASIS_CENTER + forward)

	-- Ponto no anel do oásis: ângulo em graus (0 = direção da cova), raio e altura.
	local function ringPoint(angleDegrees, radius, y)
		local angle = math.rad(angleDegrees)
		local localPoint = Vector3.new(math.sin(angle) * radius, 0, -math.cos(angle) * radius)
		local world = frame:PointToWorldSpace(localPoint)
		return Vector3.new(world.X, y or DECK_Y, world.Z)
	end
	-- CFrame num ponto olhando para o centro do oásis.
	local function facingCenter(position)
		return CFrame.lookAt(position, Vector3.new(OASIS_CENTER.X, position.Y, OASIS_CENTER.Z))
	end

	local pitCenter = OASIS_CENTER + forward * PIT_DISTANCE
	local pitPosition = Vector3.new(pitCenter.X, GROUND_Y + 0.2, pitCenter.Z)

	-- 1. Areia, dunas e limites ----------------------------------------------------------
	Common.Ground(terrainFolder, Vector3.new(GROUND_SIZE, 4, GROUND_SIZE), SAND, Enum.Material.Sand)
	Common.Bounds(helpersFolder, Vector3.new(0, GROUND_Y, 0), Vector2.new(PLAY_SIZE, PLAY_SIZE), 90)

	-- Ângulo (radianos) entre uma direção plana e a direção da cova.
	local function angleFromPit(direction)
		local flat = Vector3.new(direction.X, 0, direction.Z)
		if flat.Magnitude < 1e-3 then
			return math.pi
		end
		return math.acos(math.clamp(flat.Unit:Dot(forward), -1, 1))
	end

	local dunes = {}
	for index = 0, 11 do
		local angle = index * math.pi / 6 + 0.15
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		if angleFromPit(direction) > math.rad(28) then
			table.insert(dunes, Common.Hill(terrainFolder, OASIS_CENTER + direction * 212, 36, 10, DUNE, Enum.Material.Sand))
		end
	end
	for index = 0, 9 do
		local angle = index * math.pi / 5
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		Common.Hill(terrainFolder, OASIS_CENTER + direction * 320, 95, 32, DUNE, Enum.Material.Sand)
	end
	-- Pirâmides no horizonte, do lado oposto ao sol.
	for _, angleDegrees in ipairs({ 150, 215 }) do
		buildPyramid(terrainFolder, ringPoint(angleDegrees, 380, GROUND_Y), 110, 9)
	end

	-- 2. Oásis ---------------------------------------------------------------------------
	-- Sombra do oásis (disco escuro bem transparente) e borda de pedrinhas marcando o limite.
	Common.Cylinder(oasisFolder, OASIS_CENTER + Vector3.new(0, 0.02, 0), 0.04, OASIS_RADIUS * 2, rgb(90, 70, 40), Enum.Material.SmoothPlastic, {
		Name = "OasisShade",
		Transparency = 0.8,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
	for index = 1, 28 do
		local point = ringPoint(index * 360 / 28, OASIS_RADIUS, GROUND_Y)
		Common.Block(oasisFolder, CFrame.lookAt(point + Vector3.new(0, 0.3, 0), Vector3.new(0, 0.3, 0)), Vector3.new(2.2, 0.6, 1.2), SANDSTONE, Enum.Material.Sandstone, {
			Name = "ShadeBorder",
			CanCollide = false,
			CanQuery = false,
		})
	end

	Common.Cylinder(oasisFolder, OASIS_CENTER + Vector3.new(0, 0.05, 0), 0.1, GRASS_RADIUS * 2, GRASS, Enum.Material.LeafyGrass, { Name = "OasisGrass" })
	Common.Cylinder(oasisFolder, OASIS_CENTER + Vector3.new(0, 0.08, 0), 0.16, (LAKE_RADIUS + 2) * 2, rgb(236, 214, 160), Enum.Material.Sand, { Name = "LakeShore" })
	Common.Cylinder(oasisFolder, OASIS_CENTER + Vector3.new(0, 0.2, 0), 0.12, LAKE_RADIUS * 2, WATER, Enum.Material.Glass, {
		Name = "Lake",
		Transparency = 0.2,
		Reflectance = 0.2,
	})
	-- Vitórias-régias e pedrinhas na margem.
	for index = 1, 4 do
		local angle = index * 1.7
		local point = OASIS_CENTER + Vector3.new(math.cos(angle) * 8, 0.28, math.sin(angle) * 8)
		Common.Cylinder(oasisFolder, point, 0.05, 2.4, rgb(70, 160, 70), Enum.Material.SmoothPlastic, { CanCollide = false, CanQuery = false })
	end
	for index = 1, 6 do
		local angle = index * math.pi / 3 + 0.3
		Common.Rock(oasisFolder, OASIS_CENTER + Vector3.new(math.cos(angle) * (LAKE_RADIUS + 1.5), 0, math.sin(angle) * (LAKE_RADIUS + 1.5)), 2.2, { Color = SANDSTONE, Material = Enum.Material.Sandstone })
	end

	-- Palmeiras (sem colisão: ficam no meio de onde o time atira).
	for _, palm in ipairs(OASIS_PALMS) do
		Common.Tree(oasisFolder, ringPoint(palm[1], palm[2], GROUND_Y), "Palm", rng:NextNumber(1.1, 1.5), { Ghost = true })
	end

	-- Toldos sobre o caldeirão e a estação de torretas.
	buildShadeSail(oasisFolder, ringPoint(140, 26, GROUND_Y + 11), ringPoint(165, 36, GROUND_Y + 9), rgb(240, 120, 80))
	buildShadeSail(oasisFolder, ringPoint(220, 26, GROUND_Y + 11), ringPoint(195, 36, GROUND_Y + 9), rgb(80, 170, 200))

	-- 3. Estações do oásis ----------------------------------------------------------------
	local stalls = {}
	for index, stallId in ipairs(mapDef and mapDef.Stalls or {}) do
		local angle = STALL_ANGLES[index]
		if not angle then
			warn(("[Desert] Sem lugar para a barraca %s (máximo %d)."):format(tostring(stallId), #STALL_ANGLES))
			break
		end
		local info = Upgrades.Stalls[stallId] or {}
		stalls[stallId] = Common.Stall(stallsFolder, stallId, facingCenter(ringPoint(angle, STALL_RING)), info.Color, info.Name or stallId)
	end

	local board, boardPrompt = Common.Board(oasisFolder, facingCenter(ringPoint(BOARD_SPOT.Angle, BOARD_SPOT.Radius)))
	local crate = Common.Crate(oasisFolder, facingCenter(ringPoint(CRATE_SPOT.Angle, CRATE_SPOT.Radius)))
	local coinDropPoint = ringPoint(COIN_SPOT.Angle, COIN_SPOT.Radius)
	Common.CoinMarker(oasisFolder, coinDropPoint, COIN_MARKER_RADIUS)
	local cauldron = buildCauldron(oasisFolder, facingCenter(ringPoint(CAULDRON_SPOT.Angle, CAULDRON_SPOT.Radius)))
	local _, recallPrompt = Common.RecallStation(oasisFolder, facingCenter(ringPoint(RECALL_SPOT.Angle, RECALL_SPOT.Radius)))
	local spawnLocation = Common.SpawnPad(oasisFolder, ringPoint(SPAWN_SPOT.Angle, SPAWN_SPOT.Radius), Vector2.new(10, 10), rgb(255, 190, 110))
	local portalSpot = facingCenter(ringPoint(PORTAL_SPOT.Angle, PORTAL_SPOT.Radius))

	-- Pads das torretas em volta do oásis, virados para fora.
	local turretBase = {}
	local padsFolder = Common.Folder("TurretPads", oasisFolder)
	for index = 0, PAD_COUNT - 1 do
		local position = ringPoint(index * 360 / PAD_COUNT, PAD_RING, GROUND_Y)
		local outward = Vector3.new(position.X - OASIS_CENTER.X, 0, position.Z - OASIS_CENTER.Z).Unit
		local padCFrame = Common.TurretPad(padsFolder, CFrame.lookAt(position, position + outward))
		table.insert(turretBase, padCFrame)
	end

	-- Placa apontando para a Grande Cova, na saída do oásis (ao lado da trilha).
	local signPosition = ringPoint(12, OASIS_RADIUS + 3, GROUND_Y)
	Common.SignPost(oasisFolder, facingCenter(signPosition), "Grande Cova", Vector2.new(10, 2.6), rgb(170, 90, 50), Common.Colors.White, 6)

	-- 4. Grande Cova -------------------------------------------------------------------------
	-- Fundo escuro com rachaduras brilhantes (o Supremo nasce aqui).
	Common.Cylinder(pitFolder, Vector3.new(pitCenter.X, GROUND_Y + 0.1, pitCenter.Z), 0.2, PIT_FLOOR_RADIUS * 2 + 1, rgb(105, 78, 58), Enum.Material.Ground, { Name = "PitFloor" })
	for index = 1, 7 do
		local angle = index * math.pi * 2 / 7 + rng:NextNumber(-0.2, 0.2)
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local fromPos = pitPosition + direction * 3 + Vector3.new(0, 0.03, 0)
		local toPos = pitPosition + direction * (PIT_FLOOR_RADIUS - 3) + Vector3.new(0, 0.03, 0)
		Common.Slab(pitFolder, fromPos, toPos, 0.7, 0.08, rgb(255, 120, 40), Enum.Material.Neon, {
			Name = "Crack",
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		})
	end

	-- Borda da cratera: cada segmento tem uma rampa por dentro e outra por fora.
	local rimFolder = Common.Folder("Rim", pitFolder)
	for index = 1, PIT_SEGMENTS do
		local angle = (index / PIT_SEGMENTS) * math.pi * 2
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local inner = pitCenter + direction * PIT_FLOOR_RADIUS
		local crest = pitCenter + direction * PIT_CREST_RADIUS + Vector3.new(0, PIT_RIM_HEIGHT, 0)
		local outer = pitCenter + direction * PIT_OUTER_RADIUS
		local innerWidth = 2 * PIT_CREST_RADIUS * math.sin(math.pi / PIT_SEGMENTS) * 1.15
		local outerWidth = 2 * PIT_OUTER_RADIUS * math.sin(math.pi / PIT_SEGMENTS) * 1.15
		for _, piece in ipairs({ { inner, crest, innerWidth }, { crest, outer, outerWidth } }) do
			local slab = Common.Slab(rimFolder, piece[1], piece[2], piece[3], PIT_RIM_THICKNESS, RIM_SAND, Enum.Material.Sand)
			slab.Name = "PitRim"
			-- Desce meia espessura para a superfície de cima ficar na linha da borda.
			slab.CFrame = slab.CFrame * CFrame.new(0, -PIT_RIM_THICKNESS / 2, 0)
		end
	end
	for index = 1, 8 do
		local angle = index * math.pi / 4 + 0.2
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		-- Pula as pedras que cairiam em cima do altar (lado do oásis).
		if direction:Dot(-forward) < math.cos(math.rad(30)) then
			Common.Rock(pitFolder, pitCenter + direction * (PIT_OUTER_RADIUS + 2), rng:NextNumber(3, 6), { Color = SANDSTONE, Material = Enum.Material.Sandstone })
		end
	end

	-- Altar na borda, do lado do oásis: é aqui que se alimenta o Supremo.
	local altarPosition = pitCenter - forward * PIT_ALTAR_DISTANCE
	local altarFrame = CFrame.lookAt(altarPosition, Vector3.new(pitCenter.X, altarPosition.Y, pitCenter.Z))
	Common.Block(pitFolder, altarFrame * CFrame.new(0, 0.4, 0), Vector3.new(7, 0.8, 7), SANDSTONE, Enum.Material.Sandstone)
	local altar = Common.Block(pitFolder, altarFrame * CFrame.new(0, 2.4, 0), Vector3.new(4, 3.2, 4), rgb(190, 150, 95), Enum.Material.Sandstone)
	altar.Name = "PitAltar"
	Common.Cylinder(pitFolder, altarFrame * CFrame.new(0, 4.3, 0), 0.6, 3.4, Common.Colors.Gold, Enum.Material.Metal)
	Common.Cylinder(pitFolder, altarFrame * CFrame.new(0, 4.65, 0), 0.1, 2.8, rgb(255, 170, 60), Enum.Material.Neon, { CanCollide = false, CanQuery = false })
	Common.Sign(altar, Enum.NormalId.Back, "GRANDE\nCOVA", rgb(255, 225, 150))
	Common.Billboard(altar, "Grande Cova", Vector3.new(0, 5, 0))
	local pitPrompt = Common.Prompt(altar, "Alimentar o Supremo", "Grande Cova", { ClientAction = "Supreme" })
	for _, side in ipairs({ -1, 1 }) do
		buildTorch(pitFolder, (altarFrame * CFrame.new(side * 5, 0, 0)).Position)
	end

	-- Trilha de lajotas do oásis até o altar, com tochas dos lados.
	local right = frame.RightVector
	local pathEnd = PIT_DISTANCE - PIT_ALTAR_DISTANCE - 5
	for distance = OASIS_RADIUS + 4, pathEnd, 6 do
		local point = OASIS_CENTER + forward * distance
		Common.Block(pitFolder, CFrame.new(point.X, GROUND_Y + 0.1, point.Z) * CFrame.Angles(0, rng:NextNumber(-0.3, 0.3), 0), Vector3.new(4.5, 0.2, 4.5), SANDSTONE, Enum.Material.Sandstone, {
			Name = "PathTile",
			CanCollide = false,
			CanQuery = false,
		})
	end
	for _, distance in ipairs({ OASIS_RADIUS + 10, pathEnd - 6 }) do
		for _, side in ipairs({ -1, 1 }) do
			buildTorch(pitFolder, OASIS_CENTER + forward * distance + right * side * 5)
		end
	end

	-- 5. Deserto em volta: cactos, pedras e poças de miragem ------------------------------
	-- true se o ponto fica livre do oásis, da cova e da trilha.
	local function isFreeDesert(point, margin)
		local flat = Vector3.new(point.X, 0, point.Z)
		if (flat - Vector3.new(OASIS_CENTER.X, 0, OASIS_CENTER.Z)).Magnitude < OASIS_RADIUS + 14 + margin then
			return false
		end
		if (flat - Vector3.new(pitCenter.X, 0, pitCenter.Z)).Magnitude < PIT_ALTAR_DISTANCE + 10 + margin then
			return false
		end
		-- Trilha: perto da linha oásis → cova.
		local along = flat:Dot(forward)
		local across = math.abs(flat:Dot(right))
		if along > 0 and along < PIT_DISTANCE and across < 10 + margin then
			return false
		end
		return true
	end

	local function scatter(count, margin, minSpacing)
		local points = {}
		local limit = PLAY_SIZE / 2 - 14
		local attempts = 0
		while #points < count and attempts < count * 30 do
			attempts += 1
			local point = Vector3.new(rng:NextNumber(-limit, limit), 0, rng:NextNumber(-limit, limit))
			if isFreeDesert(point, margin) then
				local ok = true
				for _, other in ipairs(points) do
					if (other - point).Magnitude < minSpacing then
						ok = false
						break
					end
				end
				if ok then
					table.insert(points, point)
				end
			end
		end
		return points
	end

	for _, point in ipairs(scatter(CACTUS_COUNT, 2, 18)) do
		local y = Common.SurfaceHeight(dunes, point.X, point.Z, GROUND_Y) - 0.3
		buildCactus(natureFolder, rng, Vector3.new(point.X, y, point.Z))
	end
	for _, point in ipairs(scatter(ROCK_COUNT, 4, 30)) do
		local y = Common.SurfaceHeight(dunes, point.X, point.Z, GROUND_Y)
		Common.Rock(natureFolder, Vector3.new(point.X, y, point.Z), rng:NextNumber(5, 11), { Color = SANDSTONE, Material = Enum.Material.Sandstone })
	end
	for _, point in ipairs(scatter(5, 10, 60)) do
		-- Miragem: poça brilhante que parece água de longe (só visual).
		Common.Cylinder(natureFolder, Vector3.new(point.X, GROUND_Y + 0.03, point.Z), 0.05, rng:NextNumber(14, 22), rgb(170, 215, 240), Enum.Material.Glass, {
			Name = "Mirage",
			Transparency = 0.55,
			Reflectance = 0.5,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		})
	end
	-- Palmeiras perdidas no deserto (longe do oásis).
	for _, point in ipairs(scatter(4, 6, 50)) do
		Common.Tree(natureFolder, Vector3.new(point.X, GROUND_Y, point.Z), "Palm", rng:NextNumber(1, 1.3), { Ghost = true })
	end

	-- 6. Partes auxiliares -----------------------------------------------------------------
	local fieldSize = PLAY_SIZE - 20
	local fieldArea = Common.Zone(helpersFolder, "FieldArea", CFrame.new(0, GROUND_Y + 2, 0), Vector3.new(fieldSize, 4, fieldSize))
	local turretZones = {
		Common.Zone(helpersFolder, "TurretZone", CFrame.new(0, GROUND_Y + 1, 0), Vector3.new(PLAY_SIZE - 10, 2, PLAY_SIZE - 10), { TurretZone = true }),
	}

	-- Atributos para o cliente (calor do deserto) e para quem quiser achar a cova.
	folder:SetAttribute("OasisCenter", OASIS_CENTER)
	folder:SetAttribute("OasisRadius", OASIS_RADIUS)
	folder:SetAttribute("PitPosition", pitPosition)

	-- 7. Céu e efeitos: sol grande, ar quente e "miragem" leve ------------------------------
	Common.SetSun(30)
	Common.LightingEffect("ColorCorrectionEffect", { TintColor = rgb(255, 242, 222), Saturation = 0.1, Contrast = 0.05, Brightness = 0.02 })
	Common.LightingEffect("BloomEffect", { Intensity = 0.55, Size = 30, Threshold = 1.6 })
	Common.LightingEffect("SunRaysEffect", { Intensity = 0.08, Spread = 0.8 })

	-- 8. Contexto (seção 7.2) --------------------------------------------------------------
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
		Cauldron = cauldron,
		Pit = pitPosition,
		PitPrompt = pitPrompt,
		OasisCenter = OASIS_CENTER,
		OasisRadius = OASIS_RADIUS,
	}
end

return Desert
