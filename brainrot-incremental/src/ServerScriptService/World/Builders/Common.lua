--!nonstrict
-- Builders/Common: "peças de montar" usadas por todos os mapas (seção 7.4 da especificação).
--
-- Tudo é feito só com Parts (nada de modelos prontos), para o jogo funcionar
-- sem precisar montar o mapa à mão no Studio.
--
-- Funções da especificação:
--   Common.Part(props) -> Part                          (ancorada por padrão)
--   Common.Model(name, parent) -> Model
--   Common.Prompt(parent, actionText, objectText, attributes) -> ProximityPrompt
--   Common.Sign(part, face, text, textColor?, bgColor?) -> SurfaceGui, TextLabel
--   Common.Billboard(part, text, offset) -> BillboardGui
--   Common.Tree(parent, position, style, scale, options?) -> Model
--       style: "Oak" | "Birch" | "Pine" | "Palm" | "Dead"
--       options: { Lod = "Hero"|"Standard"|"Far", Snow = true, Ghost = true, Color = Color3, Fronds = n }
--   Common.Rock(parent, position, size, options?) -> Model
--   Common.Fence(parent, center, size, height, gapSide?) -> Model
--   Common.Stall(parent, stallId, cframe, color, title) -> stallTable
--   Common.Board(parent, cframe) -> part, prompt
--   Common.Crate(parent, cframe) -> part
--   Common.Ground(parent, size, color, material) -> Part
--   Common.Lamp(parent, position) -> Model                (hoje é um Common.Lantern num poste)
--
-- Versão 2.0 (kit do mundo; seção 7.4 e 7.8 da especificação):
--   Tags:     Common.Tag(instance, tagName, attributes?) -> instance
--             Common.Ghost(instance) -> instance            (folhagem: não colide, não bloqueia tiro)
--   Terreno:  Common.UseTerrain() -> boolean               (Config.Game.UseTerrain ~= false)
--             Common.TerrainBase(size, material, center?)  (chão de terreno com o topo em Y = 0)
--             Common.TerrainHill(center, capRadius, height, material, capMaterial?) -> {Position, Size}
--             Common.TerrainPath(points, width, material)  (caminho de 1 voxel de fundo, Y -4..0)
--             Common.TerrainPond(center, radius, depth, shoreMaterial) -> info
--             Common.TerrainCave(center, outerRadius, innerRadius, shellMaterial, options?) -> {Position, Size}
--             Common.TerrainColors({ [Enum.Material] = Color3 })
--   Enfeites: Common.Bush, Common.FlowerPatch, Common.GrassTuft, Common.Stump, Common.Log,
--             Common.Mushroom, Common.Lantern, Common.Critter, Common.SecretZone
--   Luz:      Common.ApplyLighting(config) aplica a BASE e depois a config (com PostFX, Sky,
--             Clouds, Wind e Water); Common.LightingEffect agora reaproveita o efeito existente.
--
-- Ajudantes extras (usados só pelos builders e pelo MapBuilder):
--   Common.Folder, Common.Block, Common.Cylinder, Common.Ball, Common.Slab, Common.CylinderBetween,
--   Common.Zone, Common.Bounds, Common.SpawnPad, Common.Hill, Common.SurfaceHeight,
--   Common.CoinMarker, Common.TurretPad, Common.RecallStation, Common.PortalPad, Common.SignPost,
--   Common.SetVisible, Common.ApplyLighting, Common.LightingEffect, Common.ClearLightingEffects,
--   Common.SetSun, Common.Colors
--
-- Convenção de orientação: um CFrame "olha" para a frente (LookVector = -Z local).
-- Barraca, quadro, caixote etc. mostram a "cara" (balcão, placa) para o lado do LookVector.
--
-- Materiais: enfeites usam materiais "de verdade" (Wood, WoodPlanks, Slate, Rock, Fabric,
-- Metal, Brick...). SmoothPlastic fica só para coisas de brinquedo (mini brainrots).
--
-- Módulo de World: NÃO dá require em nenhum serviço (regra 1.2). Só lê Shared/Config.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Config"):WaitForChild("Game"))

local Common = {}

-------------------------------------------------------------------------------
-- Constantes técnicas (aparência e tamanhos), não são balanceamento
-------------------------------------------------------------------------------

local PROMPT_DISTANCE = 12 -- seção 7.3: todo prompt tem MaxActivationDistance = 12
local SIGN_PIXELS_PER_STUD = 40 -- resolução dos textos nas placas
local BILLBOARD_MAX_DISTANCE = 150 -- plaquinhas flutuantes somem de longe

local FENCE_POST_SPACING = 9 -- distância máxima entre os postes da cerca
local FENCE_GAP_WIDTH = 14 -- largura da abertura (portão) da cerca

local STALL_WIDTH = 16 -- largura da barraca (X local)
local STALL_DEPTH = 12 -- profundidade da barraca (Z local)
local SHELF_HEIGHTS = { 4.9, 7.0, 9.1 } -- altura (centro da tábua) das prateleiras 1, 2 e 3
local SHELF_ITEM_X = { -4.8, -1.6, 1.6, 4.8 } -- posição dos 4 itens em cada prateleira
local ROOF_STRIPES = 8 -- listras do toldo
local ROOF_TILT = math.rad(-10) -- toldo inclinado (mais alto atrás)

local MAX_BALL_RADIUS = 1000 -- uma Part pode ter no máximo 2048 studs de lado

-- Atributos que guardam a aparência original de uma peça escondida (SetVisible).
local ATTR_TRANSPARENCY = "HiddenBaseTransparency"
local ATTR_COLLIDE = "HiddenBaseCanCollide"
local ATTR_QUERY = "HiddenBaseCanQuery"
local ATTR_ENABLED = "HiddenBaseEnabled"

-- Atributo que marca efeitos de iluminação criados pelo mapa (para limpar depois).
local MAP_EFFECT_ATTRIBUTE = "MapEffect"

-- Tag que todo ProximityPrompt do jogo recebe (o PromptController do cliente acha por ela).
local GAME_PROMPT_TAG = "GamePrompt"

-- Tags de ambiente (lidas pelo AmbientController no cliente; seção 7.8 da especificação).
local TAG_FLICKER = "AmbientFlicker"
local TAG_CRITTER = "AmbientCritter"
local TAG_SECRET = "Secret"

-- Tipos de bichinho que o AmbientController sabe animar.
-- ("Pet" fica de fora: o bichinho de estimação não usa âncora, a tag vai no Model dele.)
local CRITTER_KINDS = {
	Butterfly = true,
	Bird = true,
	Fish = true,
	Koi = true,
	Tumbleweed = true,
	Vulture = true,
	Firefly = true,
}

-- Peça "pequena" (a segunda maior medida abaixo disto) não faz sombra (Common.Ghost).
local SMALL_PART_SIZE = 1

-- Terreno (voxels de 4 studs).
local VOXEL = 4 -- tamanho de um voxel do terreno (o Roblox só aceita 4)
local TERRAIN_BASE_DEPTH = 8 -- espessura do chão de terreno (2 voxels abaixo de Y = 0)
local TERRAIN_TILE = 512 -- o chão é preenchido em pedaços deste tamanho (studs)
local TERRAIN_HILL_TILE = 64 -- colinas são escritas em blocos de até 64×64 colunas de voxels
local HILL_CAP_FRACTION = 0.62 -- acima desta fração da altura a colina usa o capMaterial
local POND_SHORE_FACTOR = 1.35 -- a margem (areia, lama...) vai até 1,35× o raio do lago
local POND_WATER_DROP = 0.6 -- a água fica um pouquinho abaixo do chão (studs)

-- Lanterna 2.0 (seção 3.3: luzes sem sombra, alcance 16, brilho 1,2).
local LANTERN_LIGHT_RANGE = 16
local LANTERN_LIGHT_BRIGHTNESS = 1.2
local LANTERN_POST_HEIGHT = 8

-- Gerador de números aleatórios (variação de pedras e árvores).
local rng = Random.new()

-------------------------------------------------------------------------------
-- Paleta de cores compartilhada (os builders também usam)
-------------------------------------------------------------------------------

local rgb = Color3.fromRGB

Common.Colors = {
	Wood = rgb(160, 115, 70),
	DarkWood = rgb(105, 72, 45),
	LightWood = rgb(210, 170, 120),
	Trunk = rgb(112, 78, 48),
	Stone = rgb(150, 148, 145),
	DarkStone = rgb(95, 95, 100),
	Metal = rgb(110, 116, 126),
	DarkMetal = rgb(52, 55, 62),
	White = rgb(245, 245, 245),
	Snow = rgb(240, 246, 255),
	Gold = rgb(245, 196, 60),
	Leaf = rgb(82, 158, 66),
	LeafDark = rgb(58, 128, 52),
	Pine = rgb(42, 98, 60),
	PineDark = rgb(32, 80, 50),
	Warm = rgb(255, 214, 140),
	Red = rgb(215, 60, 55),
	Purple = rgb(160, 90, 230),
	-- Cores novas do kit 2.0 (as de cima continuam iguais).
	BirchBark = rgb(232, 228, 216),
	BirchLeaf = rgb(156, 196, 88),
	BirchLeafDark = rgb(124, 170, 70),
	DeadWood = rgb(118, 104, 92),
	FrostWood = rgb(150, 156, 170),
	PalmBark = rgb(150, 110, 70),
	PalmBarkDark = rgb(125, 90, 58),
	Coconut = rgb(95, 65, 35),
	Bush = rgb(76, 140, 60),
	BushDark = rgb(58, 116, 50),
	Stem = rgb(84, 142, 62),
	LanternGlow = rgb(255, 196, 120),
	MushroomCap = rgb(205, 64, 52),
	MushroomStem = rgb(236, 226, 206),
	MushroomGlow = rgb(90, 232, 214),
}

local Colors = Common.Colors

-- Propriedades de peças "fantasma": decoração que não bloqueia tiros nem jogadores.
-- (CanQuery = false só funciona com CanCollide = false; ver seção 7.3.)
local GHOST = { CanCollide = false, CanQuery = false }

-------------------------------------------------------------------------------
-- Criação básica de peças
-------------------------------------------------------------------------------

-- Ordem em que algumas propriedades precisam ser aplicadas:
-- Shape antes de Size (a bola força o tamanho), e Size antes de CFrame/Position.
local ORDERED_KEYS = { "Shape", "Size", "CFrame", "Position", "Orientation" }

-- Chaves que não são propriedades comuns (tratadas à parte).
local SPECIAL_KEYS = {
	ClassName = true,
	Parent = true,
	Attributes = true,
	Shape = true,
	Size = true,
	CFrame = true,
	Position = true,
	Orientation = true,
}

-- Cria uma Part (ou outra BasePart, se props.ClassName for dado) com padrões bons:
-- ancorada, sem CanTouch (economiza física), superfícies lisas, material SmoothPlastic.
-- props.Attributes = { nome = valor } grava atributos; props.Parent é aplicado por último.
function Common.Part(props)
	props = props or {}
	local part = Instance.new(props.ClassName or "Part")
	part.Anchored = true
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic

	-- Primeiro as propriedades que dependem de ordem.
	for _, key in ipairs(ORDERED_KEYS) do
		local value = props[key]
		if value ~= nil then
			part[key] = value
		end
	end
	-- Depois o resto (Color, Material, Transparency, CanCollide...).
	for key, value in pairs(props) do
		if not SPECIAL_KEYS[key] then
			part[key] = value
		end
	end
	if type(props.Attributes) == "table" then
		for name, value in pairs(props.Attributes) do
			part:SetAttribute(name, value)
		end
	end
	-- O pai por último: a peça só aparece no mundo já pronta.
	if props.Parent then
		part.Parent = props.Parent
	end
	return part
end

-- Monta a tabela de props juntando os argumentos com as extras (sem mexer nas extras).
local function withExtra(extra, props)
	local result = extra and table.clone(extra) or {}
	for key, value in pairs(props) do
		result[key] = value
	end
	return result
end

-- Cria um Model vazio com nome e pai.
function Common.Model(name, parent)
	local model = Instance.new("Model")
	model.Name = name or "Model"
	model.Parent = parent
	return model
end

-- Cria uma Folder (só para organizar o Explorer).
function Common.Folder(name, parent)
	local folder = Instance.new("Folder")
	folder.Name = name or "Folder"
	folder.Parent = parent
	return folder
end

-- Bloco retangular. cframe = centro; extra = props adicionais (ex.: GHOST).
function Common.Block(parent, cframe, size, color, material, extra)
	return Common.Part(withExtra(extra, {
		Name = extra and extra.Name or "Block",
		CFrame = cframe,
		Size = size,
		Color = color or Colors.Stone,
		Material = material or Enum.Material.SmoothPlastic,
		Parent = parent,
	}))
end

-- Cilindro "em pé". center pode ser Vector3 ou CFrame (o eixo do cilindro fica no UpVector).
-- No Roblox o eixo do cilindro é o X da peça, então giramos 90° no Z.
function Common.Cylinder(parent, center, height, diameter, color, material, extra)
	local base = typeof(center) == "CFrame" and center or CFrame.new(center)
	return Common.Part(withExtra(extra, {
		Name = extra and extra.Name or "Cylinder",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, diameter, diameter),
		CFrame = base * CFrame.Angles(0, 0, math.pi / 2),
		Color = color or Colors.Stone,
		Material = material or Enum.Material.SmoothPlastic,
		Parent = parent,
	}))
end

-- Esfera de diâmetro "diameter" com centro em "center" (Vector3).
function Common.Ball(parent, center, diameter, color, material, extra)
	return Common.Part(withExtra(extra, {
		Name = extra and extra.Name or "Ball",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(diameter, diameter, diameter),
		CFrame = CFrame.new(center),
		Color = color or Colors.Stone,
		Material = material or Enum.Material.SmoothPlastic,
		Parent = parent,
	}))
end

-- Escolhe um vetor "para cima" que não seja paralelo à direção (evita CFrame inválido).
local function pickUp(direction)
	if direction.Magnitude < 1e-3 then
		return Vector3.yAxis
	end
	if math.abs(direction.Unit.Y) > 0.99 then
		return Vector3.xAxis
	end
	return Vector3.yAxis
end

-- Placa retangular esticada de um ponto a outro (rampas, folhas de palmeira, bordas de cratera).
-- A linha fromPos → toPos passa pelo CENTRO da placa; width é a largura e thickness a espessura.
function Common.Slab(parent, fromPos, toPos, width, thickness, color, material, extra)
	local delta = toPos - fromPos
	local length = math.max(delta.Magnitude, 0.05)
	local mid = (fromPos + toPos) / 2
	local cframe = if delta.Magnitude > 1e-3 then CFrame.lookAt(mid, toPos, pickUp(delta)) else CFrame.new(mid)
	return Common.Part(withExtra(extra, {
		Name = extra and extra.Name or "Slab",
		Size = Vector3.new(width, thickness, length),
		CFrame = cframe,
		Color = color or Colors.Wood,
		Material = material or Enum.Material.SmoothPlastic,
		Parent = parent,
	}))
end

-- Cilindro ligando dois pontos (tronco de palmeira, braços de cacto inclinados...).
function Common.CylinderBetween(parent, fromPos, toPos, diameter, color, material, extra)
	local delta = toPos - fromPos
	local length = math.max(delta.Magnitude, 0.05)
	local mid = (fromPos + toPos) / 2
	local look = if delta.Magnitude > 1e-3 then CFrame.lookAt(mid, toPos, pickUp(delta)) else CFrame.new(mid)
	-- Girar 90° no Y faz o eixo X do cilindro apontar para o LookVector (a direção da linha).
	return Common.Part(withExtra(extra, {
		Name = extra and extra.Name or "Cylinder",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(length, diameter, diameter),
		CFrame = look * CFrame.Angles(0, math.pi / 2, 0),
		Color = color or Colors.Wood,
		Material = material or Enum.Material.SmoothPlastic,
		Parent = parent,
	}))
end

-- Parte auxiliar invisível (FieldArea, TurretZone, emissor de neve...):
-- não colide, não bloqueia tiros nem raycasts, não faz sombra.
function Common.Zone(parent, name, cframe, size, attributes)
	return Common.Part({
		Name = name or "Zone",
		CFrame = cframe,
		Size = size,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Attributes = attributes,
		Parent = parent,
	})
end

-- Paredes invisíveis em volta da área jogável (ninguém cai do mapa; moedas também batem nelas).
-- center = centro no chão; size = Vector2 (largura X, comprimento Z); height = altura das paredes.
function Common.Bounds(parent, center, size, height)
	height = height or 80
	local model = Common.Model("Bounds", parent)
	local thickness = 4
	local halfX, halfZ = size.X / 2, size.Y / 2
	local y = center.Y + height / 2
	local walls = {
		{ Vector3.new(center.X, y, center.Z - halfZ - thickness / 2), Vector3.new(size.X + thickness * 2, height, thickness) },
		{ Vector3.new(center.X, y, center.Z + halfZ + thickness / 2), Vector3.new(size.X + thickness * 2, height, thickness) },
		{ Vector3.new(center.X - halfX - thickness / 2, y, center.Z), Vector3.new(thickness, height, size.Y) },
		{ Vector3.new(center.X + halfX + thickness / 2, y, center.Z), Vector3.new(thickness, height, size.Y) },
	}
	for _, wall in ipairs(walls) do
		Common.Part({
			Name = "Boundary",
			CFrame = CFrame.new(wall[1]),
			Size = wall[2],
			Transparency = 1,
			CanCollide = true,
			CastShadow = false,
			Parent = model,
		})
	end
	return model
end

-------------------------------------------------------------------------------
-- Prompts e textos
-------------------------------------------------------------------------------

-- Cria um ProximityPrompt com o padrão da seção 7.3.
-- attributes = { ClientAction = "Stall:Weapon" } ou { ServerAction = "Board" }.
function Common.Prompt(parent, actionText, objectText, attributes)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Prompt"
	prompt.ActionText = actionText or ""
	prompt.ObjectText = objectText or ""
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.HoldDuration = 0
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	if type(attributes) == "table" then
		for name, value in pairs(attributes) do
			prompt:SetAttribute(name, value)
		end
	end
	-- Tag "GamePrompt": o PromptController do cliente acha os prompts do jogo por ela.
	prompt:AddTag(GAME_PROMPT_TAG)
	prompt.Parent = parent
	return prompt
end

-- Converte "Front" (texto) ou Enum.NormalId.Front no Enum certo.
local function toNormalId(face)
	if typeof(face) == "EnumItem" then
		return face
	end
	if type(face) == "string" then
		for _, item in ipairs(Enum.NormalId:GetEnumItems()) do
			if item.Name == face then
				return item
			end
		end
	end
	return Enum.NormalId.Front
end

-- Escreve um texto numa face da peça (SurfaceGui + TextLabel que ocupa a face toda).
-- bgColor = cor de fundo (nil = fundo transparente, mostra a cor da peça).
function Common.Sign(part, face, text, textColor, bgColor)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Sign"
	gui.Face = toNormalId(face)
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = SIGN_PIXELS_PER_STUD
	gui.LightInfluence = 0.15 -- quase não escurece: dá para ler de longe
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = bgColor and 0 or 1
	label.BackgroundColor3 = bgColor or Color3.new(0, 0, 0)
	label.BorderSizePixel = 0
	label.Font = Enum.Font.FredokaOne
	label.Text = tostring(text or "")
	label.TextColor3 = textColor or Colors.White
	label.TextScaled = true
	label.TextWrapped = true
	label.TextStrokeTransparency = 0.55
	label.TextStrokeColor3 = Color3.fromRGB(30, 25, 25)

	-- Margem interna para o texto não encostar na borda.
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0.05, 0)
	padding.PaddingRight = UDim.new(0.05, 0)
	padding.PaddingTop = UDim.new(0.08, 0)
	padding.PaddingBottom = UDim.new(0.08, 0)
	padding.Parent = label

	label.Parent = gui
	gui.Parent = part
	return gui, label
end

-- Texto flutuante acima de uma peça (BillboardGui). offset = deslocamento em studs (mundo).
function Common.Billboard(part, text, offset)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Billboard"
	gui.Size = UDim2.fromOffset(260, 56)
	gui.StudsOffsetWorldSpace = typeof(offset) == "Vector3" and offset or Vector3.new(0, 4, 0)
	gui.MaxDistance = BILLBOARD_MAX_DISTANCE
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.Text = tostring(text or "")
	label.TextColor3 = Colors.White
	label.TextScaled = true
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Color3.fromRGB(25, 20, 30)
	label.Parent = gui

	gui.Parent = part
	return gui
end

-------------------------------------------------------------------------------
-- Tags e peças "fantasma"
-------------------------------------------------------------------------------

-- Põe uma tag (CollectionService) numa instância e, se vierem, grava atributos nela.
-- Os atributos são gravados ANTES da tag: quem escuta a tag já encontra tudo pronto.
-- Exemplo: Common.Tag(moinho, "AmbientSpin", { Axis = Vector3.zAxis, Speed = 0.5 })
-- Devolve a própria instância (dá para encadear).
function Common.Tag(instance, tagName, attributes)
	if typeof(instance) ~= "Instance" or type(tagName) ~= "string" or tagName == "" then
		return instance
	end
	if type(attributes) == "table" then
		for name, value in pairs(attributes) do
			instance:SetAttribute(name, value)
		end
	end
	instance:AddTag(tagName)
	return instance
end

-- A segunda maior medida da peça é menor que SMALL_PART_SIZE? (folhinha, talo, florzinha...)
local function isSmallPart(part)
	local size = part.Size
	local biggest = math.max(size.X, size.Y, size.Z)
	local smallest = math.min(size.X, size.Y, size.Z)
	local middle = size.X + size.Y + size.Z - biggest - smallest
	return middle < SMALL_PART_SIZE
end

local function ghostPart(part)
	if part:IsA("Terrain") then
		return
	end
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	if isSmallPart(part) then
		part.CastShadow = false -- sombra de peça minúscula custa caro e quase não aparece
	end
end

-- Deixa uma peça (ou um modelo inteiro) como "folhagem": não colide, não bloqueia tiros
-- nem raycasts, não dispara toques, e as peças pequenas não fazem sombra.
-- Devolve a própria instância.
function Common.Ghost(instance)
	if typeof(instance) ~= "Instance" then
		return instance
	end
	if instance:IsA("BasePart") then
		ghostPart(instance)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			ghostPart(descendant)
		end
	end
	return instance
end

-------------------------------------------------------------------------------
-- Terreno e natureza
-------------------------------------------------------------------------------

-- Chão grande do mapa, com o topo exatamente em Y = 0 (GroundY dos mapas).
function Common.Ground(parent, size, color, material)
	return Common.Part({
		Name = "Ground",
		Size = size,
		CFrame = CFrame.new(0, -size.Y / 2, 0),
		Color = color or Colors.Leaf,
		Material = material or Enum.Material.Grass,
		Parent = parent,
	})
end

-- Colina/duna: uma esfera grande enterrada, de onde só aparece a "tampa".
-- center = ponto no chão; capRadius = raio da base visível; height = altura do topo.
function Common.Hill(parent, center, capRadius, height, color, material)
	height = math.max(0.5, height)
	capRadius = math.max(1, capRadius)
	-- Geometria da calota esférica: R = (r² + h²) / (2h).
	local radius = math.min((capRadius * capRadius + height * height) / (2 * height), MAX_BALL_RADIUS)
	return Common.Part({
		Name = "Hill",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(radius * 2, radius * 2, radius * 2),
		CFrame = CFrame.new(center.X, center.Y + height - radius, center.Z),
		Color = color or Colors.Leaf,
		Material = material or Enum.Material.Grass,
		Parent = parent,
	})
end

-- Altura do chão num ponto (x, z) considerando as colinas (esferas) da lista.
-- Usado para pôr árvores e pedras em cima das colinas.
function Common.SurfaceHeight(hills, x, z, baseY)
	local best = baseY or 0
	for _, hill in ipairs(hills or {}) do
		local radius = hill.Size.X / 2
		local dx, dz = x - hill.Position.X, z - hill.Position.Z
		local distanceSq = dx * dx + dz * dz
		if distanceSq < radius * radius then
			local y = hill.Position.Y + math.sqrt(radius * radius - distanceSq)
			if y > best then
				best = y
			end
		end
	end
	return best
end

-- Mistura uma cor com outra (t = 0 → a, t = 1 → b).
local function mix(a, b, t)
	return a:Lerp(b, math.clamp(t, 0, 1))
end

-- Árvores 2.0 ----------------------------------------------------------------
--
-- Common.Tree(parent, position, style, scale, options?) -> Model
--   position = ponto no chão (pé do tronco); scale = tamanho (1 = normal).
--   style: "Oak" (carvalho), "Birch" (bétula), "Pine" (pinheiro), "Palm" (palmeira)
--          ou "Dead" (árvore seca). Estilo desconhecido vira carvalho (como antes).
--   options (opcional):
--     Lod   = "Hero" (perto de pontos de interesse, mais peças), "Standard" (padrão)
--             ou "Far" (horizonte: só 3 peças, sem sombra e sem colisão).
--     Snow  = true   neve em cima (pinheiro: capinhas de neve inclinadas).
--     Ghost = true   tronco sem colisão (árvores no meio da área de tiro).
--     Color = Color3 cor das folhas (senão sorteia um tom perto da cor padrão).
--     Fronds = n     quantas folhas a palmeira tem (padrão: 12 Hero, 7 Standard).
--   Folhas e galhos nunca bloqueiam tiros nem jogadores.
--   Quantidade de peças (Standard / Hero / Far): Oak 9/12/3, Birch 7/9/3, Pine 10/14/3,
--   Palm 27/45/3, Dead 6/8/3.

-- Lê o nível de detalhe pedido (qualquer outro valor vira "Standard").
local function resolveLod(options)
	local lod = options.Lod
	if lod == "Hero" or lod == "Far" then
		return lod
	end
	return "Standard"
end

-- Monta a função "at": ponto local da árvore (em unidades de escala 1) -> ponto no mundo,
-- já girado por um ângulo sorteado (cada árvore fica um pouco diferente).
local function treeFrame(position, scale)
	local yaw = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	return function(x, y, z)
		return position + yaw:VectorToWorldSpace(Vector3.new(x, y, z) * scale)
	end, yaw
end

-- CFrame "em pé" num ponto, com uma inclinação pequena sorteada (visual mais natural).
local function tiltedAt(point, maxTiltDegrees)
	local tilt = math.rad(maxTiltDegrees or 0)
	return CFrame.new(point) * CFrame.Angles(rng:NextNumber(-tilt, tilt), rng:NextNumber(0, math.pi * 2), rng:NextNumber(-tilt, tilt))
end

-- Cor das folhas: a pedida em options.Color ou um tom sorteado entre "escura" e "clara".
local function leafShades(options, dark, light)
	if typeof(options.Color) == "Color3" then
		return options.Color, mix(options.Color, Color3.new(0, 0, 0), 0.18)
	end
	local base = mix(dark, light, rng:NextNumber(0.35, 1))
	return base, mix(base, Color3.new(0, 0, 0), 0.16)
end

local TreeBuilders = {}

-- Carvalho: tronco com base mais larga, 2 galhos e copa de 5 bolas (Hero: 3 galhos, 7 bolas).
function TreeBuilders.Oak(model, position, scale, options, lod)
	local at = treeFrame(position, scale)
	local leafA, leafB = leafShades(options, Colors.LeafDark, Colors.Leaf)
	local trunkExtra = options.Ghost and GHOST or nil

	if lod == "Far" then
		local trunk = Common.Cylinder(model, at(0, 3.5, 0), 7 * scale, 1.6 * scale, Colors.Trunk, Enum.Material.Wood, GHOST)
		Common.Ball(model, at(0, 9.4, 0), 8.6 * scale, leafA, Enum.Material.LeafyGrass, GHOST)
		Common.Ball(model, at(1.9, 8.2, 1.2), 6 * scale, leafB, Enum.Material.LeafyGrass, GHOST)
		return trunk
	end

	local trunk = Common.Cylinder(model, at(0, 3.9, 0), 7.8 * scale, 1.6 * scale, Colors.Trunk, Enum.Material.Wood, trunkExtra)
	-- Base do tronco mais larga (raízes).
	Common.Cylinder(model, at(0, 0.6, 0), 1.2 * scale, 2.5 * scale, mix(Colors.Trunk, Color3.new(0, 0, 0), 0.12), Enum.Material.Wood, trunkExtra)
	-- Galhos saindo para os lados, escondidos dentro da copa.
	Common.CylinderBetween(model, at(0, 5.2, 0), at(2.6, 8.0, 0.6), 0.75 * scale, Colors.Trunk, Enum.Material.Wood, GHOST)
	Common.CylinderBetween(model, at(0, 5.8, 0), at(-2.4, 8.4, -1.0), 0.7 * scale, Colors.Trunk, Enum.Material.Wood, GHOST)

	local canopy = {
		{ Vector3.new(0, 10.0, 0), 8.4, leafA },
		{ Vector3.new(2.9, 8.9, 0.8), 6.0, leafB },
		{ Vector3.new(-2.7, 9.1, -1.1), 6.2, leafA },
		{ Vector3.new(-0.6, 8.6, 2.7), 5.2, leafB },
		{ Vector3.new(0.4, 12.8, 0.3), 4.8, mix(leafA, Color3.new(1, 1, 0.8), 0.08) },
	}
	if lod == "Hero" then
		Common.CylinderBetween(model, at(0, 6.2, 0), at(0.4, 8.8, 2.4), 0.6 * scale, Colors.Trunk, Enum.Material.Wood, GHOST)
		table.insert(canopy, { Vector3.new(1.6, 11.6, -1.9), 4.2, mix(leafA, Color3.new(1, 1, 0.8), 0.12) })
		table.insert(canopy, { Vector3.new(-2.0, 11.4, 1.6), 3.8, leafB })
	end
	for _, blob in ipairs(canopy) do
		local offset = blob[1]
		Common.Ball(model, at(offset.X, offset.Y, offset.Z), blob[2] * scale, blob[3], Enum.Material.LeafyGrass, GHOST)
	end
	return trunk
end

-- Bétula: tronco fino e claro, copa alta e estreita (5 bolas; Hero: +1 galho e +1 bola).
function TreeBuilders.Birch(model, position, scale, options, lod)
	local at = treeFrame(position, scale)
	local leafA, leafB = leafShades(options, Colors.BirchLeafDark, Colors.BirchLeaf)
	local trunkExtra = options.Ghost and GHOST or nil

	if lod == "Far" then
		local trunk = Common.Cylinder(model, at(0, 5, 0), 10 * scale, 0.8 * scale, Colors.BirchBark, Enum.Material.Wood, GHOST)
		Common.Ball(model, at(0, 11.6, 0), 5.6 * scale, leafA, Enum.Material.LeafyGrass, GHOST)
		Common.Ball(model, at(0.4, 14, 0), 3.6 * scale, leafB, Enum.Material.LeafyGrass, GHOST)
		return trunk
	end

	local trunk = Common.Cylinder(model, at(0, 5.5, 0), 11 * scale, 0.85 * scale, Colors.BirchBark, Enum.Material.Wood, trunkExtra)
	Common.CylinderBetween(model, at(0, 6.5, 0), at(1.7, 9.4, 0.4), 0.35 * scale, Colors.BirchBark, Enum.Material.Wood, GHOST)

	local canopy = {
		{ Vector3.new(0, 11.2, 0), 5.2, leafA },
		{ Vector3.new(0.9, 13.4, -0.4), 4.2, leafB },
		{ Vector3.new(-1.0, 12.4, 0.8), 4.4, leafA },
		{ Vector3.new(0.6, 9.6, 0.7), 3.8, leafB },
		{ Vector3.new(-0.2, 15.2, 0.1), 2.8, leafA },
	}
	if lod == "Hero" then
		Common.CylinderBetween(model, at(0, 7.5, 0), at(-1.5, 10, -0.6), 0.3 * scale, Colors.BirchBark, Enum.Material.Wood, GHOST)
		table.insert(canopy, { Vector3.new(1.4, 11.2, -1.4), 3.4, leafB })
	end
	for _, blob in ipairs(canopy) do
		local offset = blob[1]
		Common.Ball(model, at(offset.X, offset.Y, offset.Z), blob[2] * scale, blob[3], Enum.Material.LeafyGrass, GHOST)
	end
	return trunk
end

-- Pinheiro: tronco curto e "saias" de folhas cada vez menores.
-- Sem neve, cada saia ganha uma borda escura por baixo (dá volume); com neve, uma capinha
-- de neve levemente inclinada em cima. Standard: 4 saias (10 peças). Hero: 5 saias (14 peças).
function TreeBuilders.Pine(model, position, scale, options, lod)
	local snow = options.Snow == true
	local green, greenDark = leafShades(options, Colors.PineDark, Colors.Pine)
	local trunkExtra = options.Ghost and GHOST or nil
	local function at(y)
		return position + Vector3.new(0, y * scale, 0)
	end

	if lod == "Far" then
		local trunk = Common.Cylinder(model, at(1.5), 3 * scale, 1 * scale, Colors.Trunk, Enum.Material.Wood, GHOST)
		Common.Cylinder(model, tiltedAt(at(4.8), 2), 4 * scale, 9 * scale, greenDark, Enum.Material.LeafyGrass, GHOST)
		Common.Cylinder(model, tiltedAt(at(8.4), 2), 4 * scale, 5.4 * scale, if snow then mix(green, Colors.Snow, 0.55) else green, Enum.Material.LeafyGrass, GHOST)
		return trunk
	end

	local tiers
	if lod == "Hero" then
		tiers = {
			{ Diameter = 10.6, Y = 3.6 },
			{ Diameter = 8.8, Y = 5.6 },
			{ Diameter = 7.0, Y = 7.6 },
			{ Diameter = 5.2, Y = 9.5 },
			{ Diameter = 3.4, Y = 11.3 },
		}
	else
		tiers = {
			{ Diameter = 9.4, Y = 4.0 },
			{ Diameter = 7.6, Y = 6.2 },
			{ Diameter = 5.8, Y = 8.3 },
			{ Diameter = 4.0, Y = 10.3 },
		}
	end
	local tierHeight = 2.4
	local topY = tiers[#tiers].Y + 1.9

	local trunk = Common.Cylinder(model, at(2), 4 * scale, 1.1 * scale, Colors.Trunk, Enum.Material.Wood, trunkExtra)
	if lod == "Hero" then
		-- Base do tronco mais larga.
		Common.Cylinder(model, at(0.5), 1 * scale, 1.9 * scale, mix(Colors.Trunk, Color3.new(0, 0, 0), 0.12), Enum.Material.Wood, trunkExtra)
	end

	for index, tier in ipairs(tiers) do
		local shade = mix(greenDark, green, index / #tiers)
		Common.Cylinder(model, tiltedAt(at(tier.Y), 2.5), tierHeight * scale, tier.Diameter * scale, shade, Enum.Material.LeafyGrass, GHOST)
		if snow then
			-- Capinha de neve em cima da saia, inclinada uns graus (neve acumulada de lado).
			local capY = tier.Y + tierHeight / 2 + 0.1
			Common.Cylinder(model, tiltedAt(at(capY), 7), 0.4 * scale, tier.Diameter * 0.84 * scale, Colors.Snow, Enum.Material.Snow, GHOST)
		else
			-- Borda escura por baixo da saia (parece que as folhas caem).
			local skirtY = tier.Y - tierHeight / 2 - 0.1
			Common.Cylinder(model, tiltedAt(at(skirtY), 2.5), 0.5 * scale, tier.Diameter * 1.05 * scale, mix(shade, Color3.new(0, 0, 0), 0.22), Enum.Material.LeafyGrass, GHOST)
		end
	end

	-- Ponta: com neve vira uma bolinha branca; sem neve, uma pontinha verde.
	if snow then
		Common.Ball(model, at(topY), 1.8 * scale, Colors.Snow, Enum.Material.Snow, GHOST)
	else
		Common.Cylinder(model, at(topY), 2.4 * scale, 1.6 * scale, green, Enum.Material.LeafyGrass, GHOST)
	end
	if lod == "Hero" then
		Common.Ball(model, at(topY + 1.3), 1 * scale, if snow then Colors.Snow else green, if snow then Enum.Material.Snow else Enum.Material.LeafyGrass, GHOST)
	end
	return trunk
end

-- Palmeira 2.0: tronco curvo em gomos e folhas "caídas" feitas de 3 placas cada
-- (sobe, fica reta e cai), com cocos embaixo das folhas.
function TreeBuilders.Palm(model, position, scale, options, lod)
	local trunkExtra = options.Ghost and GHOST or nil
	local leafA, leafB = leafShades(options, Colors.LeafDark, Colors.Leaf)
	local leanAngle = rng:NextNumber(0, math.pi * 2)
	local leanDir = Vector3.new(math.cos(leanAngle), 0, math.sin(leanAngle))

	if lod == "Far" then
		local top = position + (Vector3.yAxis * 12 + leanDir * 2.5) * scale
		local trunk = Common.CylinderBetween(model, position, top, 1.1 * scale, Colors.PalmBark, Enum.Material.Wood, GHOST)
		for index = 0, 1 do
			local angle = leanAngle + index * math.pi / 2
			local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
			Common.Slab(model, top - out * 5 * scale - Vector3.new(0, 1.2, 0) * scale, top + out * 5 * scale - Vector3.new(0, 1.2, 0) * scale, 1.6 * scale, 0.2 * scale, leafA, Enum.Material.LeafyGrass, GHOST)
		end
		return trunk
	end

	-- Tronco curvo: cada gomo inclina um pouco mais para o lado sorteado.
	local segmentCount = if lod == "Hero" then 5 else 4
	local segmentLength = (if lod == "Hero" then 2.8 else 3.4) * scale
	local points = { position }
	for index = 1, segmentCount do
		local bend = math.rad(4 + index * 5)
		local direction = (Vector3.yAxis * math.cos(bend) + leanDir * math.sin(bend)).Unit
		points[index + 1] = points[index] + direction * segmentLength
	end
	local trunk
	for index = 1, segmentCount do
		local diameter = (1.35 - index * 0.09) * scale
		local segment = Common.CylinderBetween(model, points[index], points[index + 1], diameter, if index % 2 == 0 then Colors.PalmBark else Colors.PalmBarkDark, Enum.Material.Wood, trunkExtra)
		if index == 1 then
			trunk = segment
		end
	end

	-- Folhas: 3 placas cada (sobe, segue, cai), afinando na ponta.
	local top = points[#points]
	local frondCount = math.clamp(math.floor(tonumber(options.Fronds) or (if lod == "Hero" then 12 else 7)), 3, 16)
	for index = 1, frondCount do
		local angle = (index / frondCount) * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local droop = rng:NextNumber(0.8, 1.25)
		local lift = rng:NextNumber(0.6, 1.1)
		local p1 = top + (out * 2.3 + Vector3.new(0, 0.8 * lift, 0)) * scale
		local p2 = p1 + (out * 2.3 + Vector3.new(0, -0.3 * droop, 0)) * scale
		local p3 = p2 + (out * 1.9 + Vector3.new(0, -1.9 * droop, 0)) * scale
		local shade = if index % 2 == 0 then leafA else leafB
		Common.Slab(model, top, p1, 1.7 * scale, 0.16 * scale, mix(shade, Color3.new(1, 1, 0.7), 0.08), Enum.Material.LeafyGrass, GHOST)
		Common.Slab(model, p1, p2, 1.45 * scale, 0.16 * scale, shade, Enum.Material.LeafyGrass, GHOST)
		Common.Slab(model, p2, p3, 0.9 * scale, 0.16 * scale, mix(shade, Color3.new(0, 0, 0), 0.15), Enum.Material.LeafyGrass, GHOST)
	end

	-- Cocos embaixo das folhas.
	local coconutCount = if lod == "Hero" then 4 else 2
	for index = 1, coconutCount do
		local angle = index * (math.pi * 2 / coconutCount) + 0.4
		local offset = Vector3.new(math.cos(angle) * 0.7, -0.75, math.sin(angle) * 0.7) * scale
		Common.Ball(model, top + offset, 0.85 * scale, Colors.Coconut, Enum.Material.Wood, GHOST)
	end
	return trunk
end

-- Árvore seca: tronco torto e galhos pelados (com Snow = true fica acinzentada de geada).
function TreeBuilders.Dead(model, position, scale, options, lod)
	local at = treeFrame(position, scale)
	local color = if options.Snow then Colors.FrostWood else Colors.DeadWood
	local branchExtra = GHOST
	local trunkExtra = if lod == "Far" or options.Ghost then GHOST else nil

	local trunkTop = at(0.6, 8, 0.3)
	local trunk = Common.CylinderBetween(model, position, trunkTop, 1.1 * scale, color, Enum.Material.Wood, trunkExtra)
	local branches
	if lod == "Far" then
		branches = {
			{ at(0, 5, 0), at(2.6, 8.4, 0.4), 0.45 },
			{ at(0.3, 6.2, 0.1), at(-2.2, 9.4, -0.6), 0.4 },
		}
	else
		branches = {
			{ at(0, 4.2, 0), at(2.8, 7.2, 0.5), 0.5 },
			{ at(0.2, 5.4, 0.1), at(-2.6, 8.6, -0.8), 0.45 },
			{ at(0.4, 6.6, 0.2), at(0.8, 9.6, 2.6), 0.4 },
			{ trunkTop, at(0.2, 10.6, -0.9), 0.35 },
			{ at(1.6, 6.2, 0.3), at(3.4, 7.4, -1.2), 0.25 },
		}
		if lod == "Hero" then
			table.insert(branches, { at(-1.5, 7.1, -0.4), at(-3.3, 8.2, 1.0), 0.25 })
			table.insert(branches, { at(0.5, 8.3, 1.3), at(1.9, 10.4, 2.2), 0.22 })
		end
	end
	for _, branch in ipairs(branches) do
		Common.CylinderBetween(model, branch[1], branch[2], branch[3] * scale, color, Enum.Material.Wood, branchExtra)
	end
	return trunk
end

function Common.Tree(parent, position, style, scale, options)
	scale = (type(scale) == "number" and scale > 0) and scale or 1
	options = type(options) == "table" and options or {}
	style = if type(style) == "string" and TreeBuilders[style] then style else "Oak"
	local lod = resolveLod(options)

	local model = Common.Model(style .. "Tree", parent)
	local trunk = TreeBuilders[style](model, position, scale, options, lod)

	if lod == "Far" then
		-- Árvore do horizonte: ninguém chega perto, então nada de sombra nem colisão.
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") then
				part.CastShadow = false
				part.CanCollide = false
				part.CanQuery = false
			end
		end
	end

	model.PrimaryPart = trunk
	return model
end

-- Pedra feita de 2 ou 3 blocos tortos. size = número (tamanho aproximado) ou Vector3.
-- options (opcional): { Color = Color3, Material = Enum.Material, Snow = true }.
function Common.Rock(parent, position, size, options)
	options = type(options) == "table" and options or {}
	local base = if typeof(size) == "Vector3" then size else Vector3.new(size or 6, (size or 6) * 0.7, (size or 6) * 0.85)
	local color = options.Color or Colors.Stone
	local material = options.Material or Enum.Material.Slate
	local model = Common.Model("Rock", parent)

	local yaw = rng:NextNumber(0, math.pi * 2)
	local tilt = function()
		return rng:NextNumber(-0.18, 0.18)
	end

	-- Bloco principal (meio enterrado).
	local mainCFrame = CFrame.new(position + Vector3.new(0, base.Y * 0.32, 0)) * CFrame.Angles(tilt(), yaw, tilt())
	local main = Common.Block(model, mainCFrame, base, color, material)
	main.Name = "Rock"

	-- Dois blocos menores encostados, com tons um pouco diferentes.
	local second = mainCFrame * CFrame.new(base.X * 0.38, -base.Y * 0.12, base.Z * 0.22) * CFrame.Angles(tilt(), rng:NextNumber(0, 1.5), tilt())
	Common.Block(model, second, base * 0.58, mix(color, Color3.new(0, 0, 0), 0.12), material)
	local third = mainCFrame * CFrame.new(-base.X * 0.34, -base.Y * 0.2, -base.Z * 0.28) * CFrame.Angles(tilt(), rng:NextNumber(0, 1.5), tilt())
	Common.Block(model, third, base * 0.42, mix(color, Color3.new(1, 1, 1), 0.08), material)

	if options.Snow then
		-- Capa de neve em cima do bloco principal (segue a inclinação dele).
		Common.Block(model, mainCFrame * CFrame.new(0, base.Y / 2 + 0.2, 0), Vector3.new(base.X * 0.92, 0.5, base.Z * 0.9), Colors.Snow, Enum.Material.Snow)
	end

	model.PrimaryPart = main
	return model
end

-- Um trecho reto de cerca entre dois pontos (postes + 2 ripas).
local function buildFenceSegment(parent, fromPos, toPos, height)
	local delta = toPos - fromPos
	local length = delta.Magnitude
	if length < 0.5 then
		return
	end
	local direction = delta / length
	local postCount = math.max(1, math.ceil(length / FENCE_POST_SPACING))
	for index = 0, postCount do
		local point = fromPos + direction * (length * index / postCount)
		Common.Block(parent, CFrame.new(point + Vector3.new(0, (height + 0.4) / 2, 0)), Vector3.new(0.6, height + 0.4, 0.6), Colors.DarkWood, Enum.Material.Wood, GHOST)
	end
	for _, fraction in ipairs({ 0.42, 0.85 }) do
		local mid = (fromPos + toPos) / 2 + Vector3.new(0, height * fraction, 0)
		Common.Block(parent, CFrame.lookAt(mid, mid + direction), Vector3.new(0.25, 0.45, length), Colors.LightWood, Enum.Material.Wood, GHOST)
	end
end

-- Cerca retangular de madeira em volta de "center" (ponto no chão).
-- size = Vector2 (largura em X, comprimento em Z). gapSide (opcional) abre um portão no meio
-- de um lado: "North" (-Z), "South" (+Z), "West" (-X) ou "East" (+X).
-- Cerca é decoração baixa: não bloqueia tiros (seção 7.3), então também não tem colisão.
function Common.Fence(parent, center, size, height, gapSide)
	height = height or 3.5
	local model = Common.Model("Fence", parent)
	local halfX, halfZ = size.X / 2, size.Y / 2
	local sides = {
		{ Name = "North", From = Vector3.new(-halfX, 0, -halfZ), To = Vector3.new(halfX, 0, -halfZ) },
		{ Name = "South", From = Vector3.new(-halfX, 0, halfZ), To = Vector3.new(halfX, 0, halfZ) },
		{ Name = "West", From = Vector3.new(-halfX, 0, -halfZ), To = Vector3.new(-halfX, 0, halfZ) },
		{ Name = "East", From = Vector3.new(halfX, 0, -halfZ), To = Vector3.new(halfX, 0, halfZ) },
	}
	for _, side in ipairs(sides) do
		local a = center + side.From
		local b = center + side.To
		if side.Name == gapSide then
			-- Divide o lado em dois trechos, deixando o portão no meio.
			local mid = (a + b) / 2
			local direction = (b - a).Unit
			local halfGap = math.min(FENCE_GAP_WIDTH / 2, (b - a).Magnitude / 2 - 1)
			buildFenceSegment(model, a, mid - direction * halfGap, height)
			buildFenceSegment(model, mid + direction * halfGap, b, height)
		else
			buildFenceSegment(model, a, b, height)
		end
	end
	return model
end

-- Poste de luz com lanterna acesa. position = ponto no chão.
-- Desde a 2.0 é uma Common.Lantern num poste (continua com as peças "Pole" e "Lantern").
function Common.Lamp(parent, position)
	return Common.Lantern(parent, CFrame.new(position), { Height = 10, Name = "Lamp" })
end

-------------------------------------------------------------------------------
-- Terreno de voxels (Terrain): seção 3.4 do plano
-------------------------------------------------------------------------------
--
-- O terreno é feito de "voxels" (cubinhos de 4×4×4 studs). Cada voxel tem um material e
-- quanto dele está cheio (0 a 1); o Roblox "alisa" tudo e o chão fica suave.
-- Regras (seção 3.4): dentro de uma FieldArea o terreno fica entre GroundY - 3 e GroundY + 3 e
-- sem água; embaixo do CoinDropPoint e das estações continua existindo um piso de Part.
-- Ordem boa num builder: TerrainBase -> TerrainHill -> TerrainPond/TerrainCave -> TerrainPath.

-- Os mapas usam terreno de voxels? (Config.Game.UseTerrain; o padrão é true).
-- Com false, os builders voltam para o chão e as colinas de Part (Common.Ground/Common.Hill).
function Common.UseTerrain()
	return GameConfig.UseTerrain ~= false
end

local function getTerrain()
	return workspace:FindFirstChildOfClass("Terrain")
end

-- Arredonda para a grade de 4 studs (para baixo / para cima).
local function snapDown(value)
	return math.floor(value / VOXEL) * VOXEL
end
local function snapUp(value)
	return math.ceil(value / VOXEL) * VOXEL
end

-- Chama um método do Terrain protegido: um erro no terreno avisa no Output, mas não derruba o mapa.
local function terrainCall(label, method, ...)
	local ok, err = pcall(method, ...)
	if not ok then
		warn(("[Common] Terreno (%s) falhou: %s"):format(label, tostring(err)))
	end
	return ok
end

local function asMaterial(value, default)
	if typeof(value) == "EnumItem" and value.EnumType == Enum.Material then
		return value
	end
	return default
end

-- Lê o material e o "quanto está cheio" de cada voxel de uma região alinhada na grade.
-- Devolve materials[x][y][z], occupancy[x][y][z] e se usou a API de canais (a nova).
local SOLID_CHANNELS = { "SolidMaterial", "SolidOccupancy" }
local function readSolid(terrain, region)
	local ok, channels = pcall(terrain.ReadVoxelChannels, terrain, region, VOXEL, SOLID_CHANNELS)
	if ok and type(channels) == "table" and channels.SolidMaterial and channels.SolidOccupancy then
		return channels.SolidMaterial, channels.SolidOccupancy, true
	end
	local okOld, materials, occupancy = pcall(terrain.ReadVoxels, terrain, region, VOXEL)
	if okOld and type(materials) == "table" and type(occupancy) == "table" then
		return materials, occupancy, false
	end
	return nil, nil, false
end

local function writeSolid(terrain, region, materials, occupancy, useChannels)
	if useChannels then
		return terrainCall("WriteVoxelChannels", terrain.WriteVoxelChannels, terrain, region, VOXEL, {
			SolidMaterial = materials,
			SolidOccupancy = occupancy,
		})
	end
	return terrainCall("WriteVoxels", terrain.WriteVoxels, terrain, region, VOXEL, materials, occupancy)
end

-- Chão de terreno do mapa: um bloco de 8 studs de espessura com o topo em Y = 0
-- (ou em center.Y, se vier um center). size = lado do quadrado (studs).
-- É preenchido em pedaços de 512 studs, sempre alinhados na grade de 4 studs.
function Common.TerrainBase(size, material, center)
	local terrain = getTerrain()
	size = tonumber(size)
	if not terrain or not size or size <= 0 then
		return
	end
	material = asMaterial(material, Enum.Material.Grass)
	local centerX, centerZ, top = 0, 0, 0
	if typeof(center) == "Vector3" then
		centerX, centerZ, top = center.X, center.Z, center.Y
	end
	local x0, x1 = snapDown(centerX - size / 2), snapUp(centerX + size / 2)
	local z0, z1 = snapDown(centerZ - size / 2), snapUp(centerZ + size / 2)
	local y = top - TERRAIN_BASE_DEPTH / 2

	local x = x0
	while x < x1 do
		local width = math.min(TERRAIN_TILE, x1 - x)
		local z = z0
		while z < z1 do
			local depth = math.min(TERRAIN_TILE, z1 - z)
			terrainCall("TerrainBase", terrain.FillBlock, terrain, CFrame.new(x + width / 2, y, z + depth / 2), Vector3.new(width, TERRAIN_BASE_DEPTH, depth), material)
			z += depth
		end
		x += width
	end
end

-- Colina de terreno com o mesmo formato do Common.Hill (tampa de uma esfera enterrada):
-- center = ponto no chão; capRadius = raio da base; height = altura do topo.
-- capMaterial (opcional) cobre a parte de cima (acima de ~62% da altura, com borda irregular),
-- por exemplo neve no alto de uma montanha de pedra.
-- Só escreve do chão para cima (nada de esfera gigante enterrada) e junta com o terreno que
-- já existe (colinas que se encostam viram um morro só).
-- Devolve { Position, Size } no formato da esfera: serve direto no Common.SurfaceHeight.
function Common.TerrainHill(center, capRadius, height, material, capMaterial)
	height = math.max(0.5, tonumber(height) or 0.5)
	capRadius = math.max(1, tonumber(capRadius) or 1)
	material = asMaterial(material, Enum.Material.Grass)
	capMaterial = asMaterial(capMaterial, nil)
	if capMaterial == material then
		capMaterial = nil
	end
	-- Geometria da calota esférica: R = (r² + h²) / (2h) (a mesma conta do Common.Hill).
	local radius = math.min((capRadius * capRadius + height * height) / (2 * height), MAX_BALL_RADIUS)
	local sphereY = center.Y + height - radius
	local record = {
		Position = Vector3.new(center.X, sphereY, center.Z),
		Size = Vector3.new(radius * 2, radius * 2, radius * 2),
	}

	local terrain = getTerrain()
	if not terrain then
		return record
	end

	local radiusSq = radius * radius
	local capRadiusSq = capRadius * capRadius
	local capLine = center.Y + height * HILL_CAP_FRACTION
	local capWobble = height * 0.12

	local x0, x1 = snapDown(center.X - capRadius), snapUp(center.X + capRadius)
	local z0, z1 = snapDown(center.Z - capRadius), snapUp(center.Z + capRadius)
	local y0, y1 = snapDown(center.Y), snapUp(center.Y + height) + VOXEL
	local layers = (y1 - y0) / VOXEL
	local tileSpan = TERRAIN_HILL_TILE * VOXEL

	-- Escreve em blocos (cada leitura/escrita fica pequena e rápida).
	for tileX = x0, x1 - 1, tileSpan do
		local tileX1 = math.min(tileX + tileSpan, x1)
		for tileZ = z0, z1 - 1, tileSpan do
			local tileZ1 = math.min(tileZ + tileSpan, z1)
			local region = Region3.new(Vector3.new(tileX, y0, tileZ), Vector3.new(tileX1, y1, tileZ1))
			local materials, occupancy, useChannels = readSolid(terrain, region)
			if materials then
				local countX = (tileX1 - tileX) / VOXEL
				local countZ = (tileZ1 - tileZ) / VOXEL
				local changed = false
				for ix = 1, countX do
					local worldX = tileX + (ix - 0.5) * VOXEL
					local dx = worldX - center.X
					local materialsX, occupancyX = materials[ix], occupancy[ix]
					for iz = 1, countZ do
						local worldZ = tileZ + (iz - 0.5) * VOXEL
						local dz = worldZ - center.Z
						local distanceSq = dx * dx + dz * dz
						if distanceSq < capRadiusSq then
							-- Altura da superfície nesta coluna (a esfera), e onde começa o "topo".
							local surface = sphereY + math.sqrt(radiusSq - distanceSq)
							local capY = if capMaterial then capLine + math.noise(worldX / 37, worldZ / 37, 0.5) * capWobble else math.huge
							for iy = 1, layers do
								local bottom = y0 + (iy - 1) * VOXEL
								if bottom >= surface then
									break
								end
								-- Quanto deste voxel fica abaixo da superfície (0 a 1): é isso que deixa o morro liso.
								local fill = math.min(1, (surface - bottom) / VOXEL)
								local occupancyRow = occupancyX[iy]
								if fill > occupancyRow[iz] then
									occupancyRow[iz] = fill
									materialsX[iy][iz] = if bottom + VOXEL / 2 >= capY then capMaterial else material
									changed = true
								end
							end
						end
					end
				end
				if changed then
					writeSolid(terrain, region, materials, occupancy, useChannels)
				end
			else
				-- Sem acesso aos voxels (não deveria acontecer): usa uma bola simples.
				terrainCall("TerrainHill", terrain.FillBall, terrain, record.Position, radius, material)
			end
		end
	end
	return record
end

-- Caminho de terreno ligando os pontos da lista (Vector3). width = largura (studs).
-- Tem 1 voxel de fundo: troca o material da camada de cima do chão (Y -4..0 quando o
-- ponto está em Y = 0), então fica rente à grama. Use DEPOIS das colinas.
function Common.TerrainPath(points, width, material)
	local terrain = getTerrain()
	if not terrain or type(points) ~= "table" then
		return
	end
	width = math.max(1, tonumber(width) or 8)
	material = asMaterial(material, Enum.Material.Ground)
	local half = VOXEL / 2
	for index, point in ipairs(points) do
		if typeof(point) == "Vector3" then
			-- Um disco em cada ponto deixa as curvas redondas.
			local a = Vector3.new(point.X, point.Y - half, point.Z)
			terrainCall("TerrainPath", terrain.FillCylinder, terrain, CFrame.new(a), VOXEL, width / 2, material)
			local nextPoint = points[index + 1]
			if typeof(nextPoint) == "Vector3" then
				local b = Vector3.new(nextPoint.X, nextPoint.Y - half, nextPoint.Z)
				local delta = b - a
				local length = delta.Magnitude
				if length > 0.1 then
					local cframe = CFrame.lookAt((a + b) / 2, b, pickUp(delta))
					terrainCall("TerrainPath", terrain.FillBlock, terrain, cframe, Vector3.new(width, VOXEL, length), material)
				end
			end
		end
	end
end

-- Plano B do lago (se a API de canais de voxel falhar): discos de água cada vez menores.
local function pondWithFills(terrain, center, radius, depth, shoreMaterial)
	terrainCall("TerrainPond", terrain.FillCylinder, terrain, CFrame.new(center.X, center.Y - VOXEL / 2, center.Z), VOXEL, radius * POND_SHORE_FACTOR, shoreMaterial)
	terrainCall("TerrainPond", terrain.FillCylinder, terrain, CFrame.new(center.X, center.Y + VOXEL / 2, center.Z), VOXEL, radius, Enum.Material.Air)
	local layers = math.max(1, math.ceil(depth / VOXEL))
	for layer = 1, layers do
		local layerTop = center.Y - (layer - 1) * VOXEL
		local layerRadius = radius * math.sqrt(1 - (layer - 1) / layers)
		terrainCall("TerrainPond", terrain.FillCylinder, terrain, CFrame.new(center.X, layerTop - VOXEL / 2, center.Z), VOXEL, layerRadius, Enum.Material.Water)
	end
end

-- Lago de terreno: uma "tigela" de raio radius e fundo depth (studs), cheia de água até
-- um pouquinho abaixo do chão, com margem de shoreMaterial (areia, lama...) em volta.
-- center = ponto no chão, no meio do lago. Devolve { Center, Radius, Depth, WaterLevel }.
-- Lembrete (seção 3.4): nada de água dentro da FieldArea; numa TurretZone ponha um "LakeCap".
function Common.TerrainPond(center, radius, depth, shoreMaterial)
	radius = math.max(2, tonumber(radius) or 10)
	depth = math.max(1, tonumber(depth) or 4)
	shoreMaterial = asMaterial(shoreMaterial, Enum.Material.Sand)
	local waterLevel = center.Y - POND_WATER_DROP
	local info = { Center = center, Radius = radius, Depth = depth, WaterLevel = waterLevel }

	local terrain = getTerrain()
	if not terrain then
		return info
	end

	local outer = radius * (POND_SHORE_FACTOR + 0.15)
	local x0, x1 = snapDown(center.X - outer), snapUp(center.X + outer)
	local z0, z1 = snapDown(center.Z - outer), snapUp(center.Z + outer)
	local y0, y1 = snapDown(center.Y - depth - VOXEL), snapUp(center.Y) + VOXEL
	local region = Region3.new(Vector3.new(x0, y0, z0), Vector3.new(x1, y1, z1))

	local ok, channels = pcall(terrain.ReadVoxelChannels, terrain, region, VOXEL, { "SolidMaterial", "SolidOccupancy", "LiquidOccupancy" })
	if not (ok and type(channels) == "table" and channels.SolidMaterial and channels.SolidOccupancy and channels.LiquidOccupancy) then
		pondWithFills(terrain, center, radius, depth, shoreMaterial)
		return info
	end
	local materials, occupancy, liquid = channels.SolidMaterial, channels.SolidOccupancy, channels.LiquidOccupancy
	local countX, countY, countZ = (x1 - x0) / VOXEL, (y1 - y0) / VOXEL, (z1 - z0) / VOXEL
	local air = Enum.Material.Air

	for ix = 1, countX do
		local worldX = x0 + (ix - 0.5) * VOXEL
		for iz = 1, countZ do
			local worldZ = z0 + (iz - 0.5) * VOXEL
			local dx, dz = worldX - center.X, worldZ - center.Z
			local t = math.sqrt(dx * dx + dz * dz) / radius
			if t < 1 then
				-- Dentro do lago: fundo em forma de tigela e água por cima.
				local bedY = center.Y - depth * (1 - t * t)
				for iy = 1, countY do
					local bottom = y0 + (iy - 1) * VOXEL
					local top = bottom + VOXEL
					local solid = math.clamp((bedY - bottom) / VOXEL, 0, 1)
					local water = 0
					if bottom < waterLevel and solid < 1 then
						water = math.clamp((math.min(waterLevel, top) - math.max(bedY, bottom)) / VOXEL, 0, 1)
					end
					materials[ix][iy][iz] = if solid > 0 then shoreMaterial else air
					occupancy[ix][iy][iz] = solid
					liquid[ix][iy][iz] = water
				end
			else
				-- Margem: a camada de cima do chão vira shoreMaterial (borda irregular).
				local shoreLimit = POND_SHORE_FACTOR + 0.12 * math.noise(worldX / 9, worldZ / 9, 0.25)
				if t < shoreLimit then
					for iy = 1, countY do
						local bottom = y0 + (iy - 1) * VOXEL
						if bottom >= center.Y - VOXEL - 0.01 and bottom < center.Y + VOXEL then
							if occupancy[ix][iy][iz] > 0.05 and materials[ix][iy][iz] ~= air then
								materials[ix][iy][iz] = shoreMaterial
							end
						end
					end
				end
			end
		end
	end

	local written = terrainCall("TerrainPond", terrain.WriteVoxelChannels, terrain, region, VOXEL, {
		SolidMaterial = materials,
		SolidOccupancy = occupancy,
		LiquidOccupancy = liquid,
	})
	if not written then
		pondWithFills(terrain, center, radius, depth, shoreMaterial)
	end
	return info
end

-- Caverna de terreno: uma casca (bola de raio outerRadius, material shellMaterial) com um
-- buraco (bola de raio innerRadius) e piso reto na altura de center.Y.
-- center = ponto no chão, no meio da caverna.
-- options (opcional): { Entrance = Vector3 (direção da boca, no plano XZ),
--   EntranceWidth = 10, EntranceHeight = 10, Floor = Enum.Material (material do piso) }.
-- Sem Entrance a caverna fica fechada (o builder pode abrir a boca ele mesmo).
-- Devolve { Position, Size } (a bola de fora; serve no Common.SurfaceHeight).
function Common.TerrainCave(center, outerRadius, innerRadius, shellMaterial, options)
	options = type(options) == "table" and options or {}
	outerRadius = math.max(4, tonumber(outerRadius) or 24)
	innerRadius = math.clamp(tonumber(innerRadius) or outerRadius * 0.7, 2, outerRadius - 2)
	shellMaterial = asMaterial(shellMaterial, Enum.Material.Rock)
	local record = { Position = center, Size = Vector3.new(outerRadius * 2, outerRadius * 2, outerRadius * 2) }

	local terrain = getTerrain()
	if not terrain then
		return record
	end

	terrainCall("TerrainCave", terrain.FillBall, terrain, center, outerRadius, shellMaterial)
	terrainCall("TerrainCave", terrain.FillBall, terrain, center, innerRadius, Enum.Material.Air)

	-- Piso reto: preenche a metade de baixo do buraco até center.Y.
	local floorMaterial = asMaterial(options.Floor, shellMaterial)
	local floorDepth = innerRadius + VOXEL
	terrainCall(
		"TerrainCave",
		terrain.FillBlock,
		terrain,
		CFrame.new(center.X, center.Y - floorDepth / 2, center.Z),
		Vector3.new(innerRadius * 2 + VOXEL, floorDepth, innerRadius * 2 + VOXEL),
		floorMaterial
	)

	-- Boca da caverna: um túnel reto do centro para fora, com o chão em center.Y.
	local entrance = options.Entrance
	if typeof(entrance) == "Vector3" then
		local flat = Vector3.new(entrance.X, 0, entrance.Z)
		if flat.Magnitude > 0.01 then
			local direction = flat.Unit
			local width = math.max(4, tonumber(options.EntranceWidth) or 10)
			local tunnelHeight = math.max(4, tonumber(options.EntranceHeight) or 10)
			local length = outerRadius + VOXEL * 2
			local middle = Vector3.new(center.X, center.Y + tunnelHeight / 2, center.Z) + direction * (length / 2)
			terrainCall("TerrainCave", terrain.FillBlock, terrain, CFrame.lookAt(middle, middle + direction), Vector3.new(width, tunnelHeight, length), Enum.Material.Air)
		end
	end
	return record
end

-- Cores originais dos materiais do terreno que algum mapa trocou (para voltar depois).
local terrainColorBackup = {}

-- Troca a cor de materiais do terreno: { [Enum.Material.Grass] = Color3, ... } (seção 3.4).
-- A cor original é guardada e volta no Common.ClearLightingEffects (troca de mapa).
function Common.TerrainColors(map)
	local terrain = getTerrain()
	if not terrain or type(map) ~= "table" then
		return
	end
	for material, color in pairs(map) do
		if asMaterial(material, nil) and typeof(color) == "Color3" then
			if terrainColorBackup[material] == nil then
				local ok, original = pcall(terrain.GetMaterialColor, terrain, material)
				if ok and typeof(original) == "Color3" then
					terrainColorBackup[material] = original
				end
			end
			terrainCall("TerrainColors", terrain.SetMaterialColor, terrain, material, color)
		end
	end
end

-- Devolve as cores originais dos materiais trocados por Common.TerrainColors.
local function restoreTerrainColors()
	local terrain = getTerrain()
	if terrain then
		for material, color in pairs(terrainColorBackup) do
			pcall(terrain.SetMaterialColor, terrain, material, color)
		end
	end
	table.clear(terrainColorBackup)
end

-------------------------------------------------------------------------------
-- Enfeites 2.0 (folhagem e objetos pequenos)
-------------------------------------------------------------------------------

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)

-- Cores padrão das flores.
local FLOWER_PALETTE = {
	rgb(255, 92, 120),
	rgb(255, 208, 64),
	rgb(176, 112, 255),
	rgb(255, 255, 255),
	rgb(255, 150, 60),
}

local function positiveScale(scale)
	return (type(scale) == "number" and scale > 0) and scale or 1
end

-- Arbusto: 3 bolas de folhas encostadas (fantasma: não bloqueia tiros).
function Common.Bush(parent, position, scale, color)
	scale = positiveScale(scale)
	local base = if typeof(color) == "Color3" then color else mix(Colors.BushDark, Colors.Bush, rng:NextNumber(0.3, 1))
	local dark = mix(base, BLACK, 0.15)
	local yaw = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	local model = Common.Model("Bush", parent)
	local blobs = {
		{ Vector3.new(0, 0.9, 0), 2.6, base },
		{ Vector3.new(1.1, 0.7, 0.4), 2.0, dark },
		{ Vector3.new(-0.9, 0.65, -0.5), 1.8, mix(base, WHITE, 0.06) },
	}
	local main
	for index, blob in ipairs(blobs) do
		local part = Common.Ball(model, position + yaw:VectorToWorldSpace(blob[1] * scale), blob[2] * scale, blob[3], Enum.Material.LeafyGrass, GHOST)
		if index == 1 then
			main = part
		end
	end
	Common.Ghost(model)
	model.PrimaryPart = main
	return model
end

-- Canteiro de flores: um tufo de folhas com 4 flores coloridas (palette = lista de Color3).
function Common.FlowerPatch(parent, position, palette)
	if type(palette) ~= "table" or #palette == 0 then
		palette = FLOWER_PALETTE
	end
	local model = Common.Model("FlowerPatch", parent)
	local leaves = Common.Cylinder(model, position + Vector3.new(0, 0.2, 0), 0.4, rng:NextNumber(2.2, 2.8), mix(Colors.Stem, Colors.LeafDark, rng:NextNumber()), Enum.Material.LeafyGrass, GHOST)
	for index = 1, 4 do
		local angle = index * (math.pi / 2) + rng:NextNumber(-0.4, 0.4)
		local distance = rng:NextNumber(0.35, 0.95)
		local point = position + Vector3.new(math.cos(angle) * distance, rng:NextNumber(0.5, 0.75), math.sin(angle) * distance)
		local color = palette[rng:NextInteger(1, #palette)]
		if typeof(color) ~= "Color3" then
			color = FLOWER_PALETTE[1]
		end
		Common.Ball(model, point, rng:NextNumber(0.45, 0.6), color, Enum.Material.Fabric, GHOST)
	end
	Common.Ghost(model)
	model.PrimaryPart = leaves
	return model
end

-- Tufo de grama alta: 3 folhas pontudas (cunhas finas) abertas em leque.
function Common.GrassTuft(parent, position, color)
	local base = if typeof(color) == "Color3" then color else mix(Colors.LeafDark, Colors.Leaf, rng:NextNumber(0.2, 0.9))
	local model = Common.Model("GrassTuft", parent)
	local startYaw = rng:NextNumber(0, math.pi * 2)
	local first
	for index = 1, 3 do
		local bladeHeight = rng:NextNumber(1.1, 1.7)
		local lean = rng:NextNumber(0.15, 0.35)
		local cframe = CFrame.new(position) * CFrame.Angles(0, startYaw + index * 2.1, 0) * CFrame.Angles(lean, 0, 0) * CFrame.new(0, bladeHeight / 2, 0)
		local blade = Common.Part({
			ClassName = "WedgePart",
			Name = "Blade",
			Size = Vector3.new(0.12, bladeHeight, 0.55),
			CFrame = cframe,
			Color = mix(base, BLACK, index * 0.06),
			Material = Enum.Material.LeafyGrass,
			Parent = model,
		})
		first = first or blade
	end
	Common.Ghost(model)
	model.PrimaryPart = first
	return model
end

-- Toco de árvore com o topo cortado (madeira clara) e duas raízes.
function Common.Stump(parent, position, scale)
	scale = positiveScale(scale)
	local model = Common.Model("Stump", parent)
	local stumpHeight, diameter = 1.4 * scale, 2.2 * scale
	local stump = Common.Cylinder(model, position + Vector3.new(0, stumpHeight / 2, 0), stumpHeight, diameter, Colors.Trunk, Enum.Material.Wood)
	stump.Name = "Stump"
	Common.Cylinder(model, position + Vector3.new(0, stumpHeight + 0.04, 0), 0.1, diameter * 0.86, Colors.LightWood, Enum.Material.WoodPlanks, GHOST)
	local startAngle = rng:NextNumber(0, math.pi * 2)
	for index = 1, 2 do
		local angle = startAngle + index * math.pi + rng:NextNumber(-0.5, 0.5)
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
		Common.CylinderBetween(
			model,
			position + Vector3.new(0, 0.5 * scale, 0) + out * 0.6 * scale,
			position + out * 1.7 * scale + Vector3.new(0, 0.05, 0),
			0.5 * scale,
			mix(Colors.Trunk, BLACK, 0.1),
			Enum.Material.Wood,
			GHOST
		)
	end
	model.PrimaryPart = stump
	return model
end

-- Tora de madeira deitada. cframe = centro da tora; ela fica na direção do LookVector.
-- length = comprimento; diameter (opcional, padrão 1,4). As pontas mostram a madeira cortada.
-- Devolve o Model e a peça da tora (paredes de cabana, pilhas de lenha, bancos...).
function Common.Log(parent, cframe, length, diameter)
	if typeof(cframe) == "Vector3" then
		cframe = CFrame.new(cframe)
	elseif typeof(cframe) ~= "CFrame" then
		cframe = CFrame.new()
	end
	length = math.max(0.5, tonumber(length) or 8)
	diameter = math.max(0.2, tonumber(diameter) or 1.4)
	local model = Common.Model("Log", parent)
	-- O eixo do cilindro é o X da peça; girar 90° no Y deixa o X na direção do LookVector.
	local axis = cframe * CFrame.Angles(0, math.pi / 2, 0)
	local log = Common.Part({
		Name = "Log",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(length, diameter, diameter),
		CFrame = axis,
		Color = Colors.Trunk,
		Material = Enum.Material.Wood,
		Parent = model,
	})
	for _, side in ipairs({ -1, 1 }) do
		Common.Part({
			Name = "LogEnd",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.08, diameter * 0.84, diameter * 0.84),
			CFrame = axis * CFrame.new(side * (length / 2 + 0.02), 0, 0),
			Color = Colors.LightWood,
			Material = Enum.Material.WoodPlanks,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
			Parent = model,
		})
	end
	model.PrimaryPart = log
	return model, log
end

-- Cogumelo: talo, chapéu redondo com a "saia" clara por baixo e pintinhas brancas.
-- glow = true: chapéu brilhante (Neon ciano, sem pintas) para cavernas. Não põe luz
-- (quem monta o mapa decide onde vai a PointLight, dentro do limite de luzes).
function Common.Mushroom(parent, position, scale, glow)
	scale = positiveScale(scale)
	local model = Common.Model("Mushroom", parent)
	local stemHeight = 0.9 * scale
	local stem = Common.Cylinder(model, position + Vector3.new(0, stemHeight / 2, 0), stemHeight, 0.34 * scale, Colors.MushroomStem, Enum.Material.Plaster, GHOST)
	local capColor = if glow then Colors.MushroomGlow else Colors.MushroomCap
	local capMaterial = if glow then Enum.Material.Neon else Enum.Material.Plaster
	local capCenter = position + Vector3.new(0, stemHeight + 0.25 * scale, 0)
	-- "Saia" clara por baixo do chapéu.
	Common.Cylinder(model, position + Vector3.new(0, stemHeight + 0.1 * scale, 0), 0.1 * scale, 1.12 * scale, mix(Colors.MushroomStem, BLACK, 0.12), Enum.Material.Plaster, GHOST)
	Common.Ball(model, capCenter, 1.1 * scale, capColor, capMaterial, GHOST)
	if not glow then
		for index = 1, 2 do
			local angle = index * 2.4 + rng:NextNumber(-0.3, 0.3)
			local spot = capCenter + Vector3.new(math.cos(angle) * 0.3, 0.42, math.sin(angle) * 0.3) * scale
			Common.Ball(model, spot, 0.2 * scale, Colors.White, Enum.Material.Plaster, GHOST)
		end
	end
	Common.Ghost(model)
	model.PrimaryPart = stem
	return model
end

-- Lanterna 2.0 (o "lampião" dos mapas). cframe = ponto no chão (com poste) ou ponto de onde
-- ela fica pendurada (options.Hanging = true).
-- options (opcional):
--   Hanging = true      pendurada por uma correntinha (sem poste)
--   Height = 8          altura do poste (studs)
--   ChainLength = 1.2   tamanho da corrente (pendurada)
--   Color = Color3      cor da luz; MetalColor = Color3 cor do metal
--   Light = false       sem PointLight (economiza o limite de luzes do mapa)
--   Range = 16, Brightness = 1.2, Shadows = true (só para as no máximo 2 luzes "herói")
--   Name = "Lantern"
-- A luz fica numa pecinha Neon chamada "Lantern" dentro de um vidro. O modelo recebe a tag
-- "AmbientFlicker" (o cliente faz a chama tremer um pouco). Devolve o Model.
function Common.Lantern(parent, cframe, options)
	options = type(options) == "table" and options or {}
	if typeof(cframe) == "Vector3" then
		cframe = CFrame.new(cframe)
	elseif typeof(cframe) ~= "CFrame" then
		cframe = CFrame.new()
	end
	local metal = if typeof(options.MetalColor) == "Color3" then options.MetalColor else Colors.DarkMetal
	local glowColor = if typeof(options.Color) == "Color3" then options.Color else Colors.LanternGlow
	local model = Common.Model(if type(options.Name) == "string" then options.Name else "Lantern", parent)
	local function at(y)
		return cframe * CFrame.new(0, y, 0)
	end

	-- Corpo da lanterna (de baixo para cima): chapa 0,18 + vidro 1,1 + telhadinho 0,26 + pontinha.
	local bodyHeight = 1.87
	local bottomY
	local pole = nil
	if options.Hanging == true then
		local chain = math.max(0.2, tonumber(options.ChainLength) or 1.2)
		Common.Cylinder(model, at(-chain / 2), chain, 0.12, metal, Enum.Material.Metal, GHOST)
		bottomY = -chain - bodyHeight
	else
		local postHeight = math.max(1, tonumber(options.Height) or LANTERN_POST_HEIGHT)
		Common.Cylinder(model, at(0.25), 0.5, 1.5, metal, Enum.Material.Metal)
		pole = Common.Cylinder(model, at(postHeight / 2), postHeight, 0.36, metal, Enum.Material.Metal)
		pole.Name = "Pole"
		Common.Cylinder(model, at(postHeight + 0.12), 0.24, 0.8, metal, Enum.Material.Metal, GHOST)
		bottomY = postHeight + 0.24
	end

	Common.Block(model, at(bottomY + 0.09), Vector3.new(1.1, 0.18, 1.1), metal, Enum.Material.Metal, GHOST)
	local glassY = bottomY + 0.18 + 0.55
	local glass = Common.Block(model, at(glassY), Vector3.new(0.95, 1.1, 0.95), mix(glowColor, WHITE, 0.35), Enum.Material.Glass, {
		Name = "LanternGlass",
		Transparency = 0.45,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
	local core = Common.Block(model, at(glassY), Vector3.new(0.4, 0.62, 0.4), glowColor, Enum.Material.Neon, {
		Name = "Lantern",
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
	local roofY = bottomY + 0.18 + 1.1
	Common.Cylinder(model, at(roofY + 0.13), 0.26, 1.35, metal, Enum.Material.Metal, GHOST)
	Common.Ball(model, at(roofY + 0.43).Position, 0.34, metal, Enum.Material.Metal, GHOST)

	if options.Light ~= false then
		local light = Instance.new("PointLight")
		light.Color = glowColor
		light.Range = tonumber(options.Range) or LANTERN_LIGHT_RANGE
		light.Brightness = tonumber(options.Brightness) or LANTERN_LIGHT_BRIGHTNESS
		light.Shadows = options.Shadows == true -- sombra só nas luzes "herói" (no máximo 2 por mapa)
		light.Parent = core
	end

	Common.Tag(model, TAG_FLICKER)
	model.PrimaryPart = pole or glass
	return model
end

-------------------------------------------------------------------------------
-- Marcadores invisíveis (bichinhos e segredos)
-------------------------------------------------------------------------------

-- Âncora de bichinhos do cliente (AmbientController): uma peça invisível com a tag
-- "AmbientCritter" e os atributos Kind, Radius e Count.
-- kind: "Butterfly" | "Bird" | "Fish" | "Koi" | "Tumbleweed" | "Vulture" | "Firefly"
-- ("Pet" não usa âncora: a tag vai direto no Model do bichinho, com Common.Tag).
-- position = centro da área (pássaros e urubus: ponha na altura do voo).
-- radius = tamanho da área (studs); count (opcional) = quantos bichinhos.
function Common.Critter(parent, position, kind, radius, count)
	kind = tostring(kind)
	if kind == "Pet" then
		-- Uma âncora de Pet seria uma peça invisível passeando sozinha: não cria nada.
		warn('[Common] Critter "Pet" não usa âncora: use Common.Tag(modeloDoPet, "AmbientCritter", {Kind = "Pet", Radius = ...})')
		return nil
	end
	if not CRITTER_KINDS[kind] then
		warn(("[Common] Tipo de bichinho desconhecido: %s"):format(kind))
	end
	local anchor = Common.Zone(parent, "Critter_" .. kind, CFrame.new(position), Vector3.new(1, 1, 1))
	local attributes = { Kind = kind, Radius = math.max(1, tonumber(radius) or 10) }
	if type(count) == "number" and count >= 1 then
		attributes.Count = math.floor(count)
	end
	return Common.Tag(anchor, TAG_CRITTER, attributes)
end

-- Zona secreta (seção 3.5): peça invisível e fantasma com a tag "Secret" e os atributos
-- SecretId e Title. O cliente mostra "Segredo encontrado" quando o jogador chega perto
-- (sem recompensa; nada passa pelo servidor). cframe = centro da zona; size = Vector3.
function Common.SecretZone(parent, cframe, size, secretId, title)
	if typeof(cframe) == "Vector3" then
		cframe = CFrame.new(cframe)
	elseif typeof(cframe) ~= "CFrame" then
		cframe = CFrame.new()
	end
	if typeof(size) ~= "Vector3" then
		size = Vector3.new(12, 10, 12)
	end
	local id = tostring(secretId or "Secret")
	local zone = Common.Zone(parent, "Secret_" .. id, cframe, size)
	return Common.Tag(zone, TAG_SECRET, { SecretId = id, Title = tostring(title or id) })
end

-------------------------------------------------------------------------------
-- Visibilidade (prateleiras escondidas)
-------------------------------------------------------------------------------

-- Esconde/mostra uma instância guardando a aparência original em atributos.
local function setInstanceVisible(instance, visible)
	if instance:IsA("BasePart") then
		if instance:GetAttribute(ATTR_TRANSPARENCY) == nil then
			if visible then
				return -- nunca foi escondida: já está do jeito original
			end
			instance:SetAttribute(ATTR_TRANSPARENCY, instance.Transparency)
			instance:SetAttribute(ATTR_COLLIDE, instance.CanCollide)
			instance:SetAttribute(ATTR_QUERY, instance.CanQuery)
		end
		if visible then
			instance.Transparency = instance:GetAttribute(ATTR_TRANSPARENCY)
			instance.CanCollide = instance:GetAttribute(ATTR_COLLIDE) == true
			instance.CanQuery = instance:GetAttribute(ATTR_QUERY) ~= false
		else
			instance.Transparency = 1
			instance.CanCollide = false
			instance.CanQuery = false
		end
	elseif instance:IsA("Decal") then
		-- Decal e Texture (Texture herda de Decal).
		if instance:GetAttribute(ATTR_TRANSPARENCY) == nil then
			if visible then
				return
			end
			instance:SetAttribute(ATTR_TRANSPARENCY, instance.Transparency)
		end
		instance.Transparency = if visible then instance:GetAttribute(ATTR_TRANSPARENCY) else 1
	elseif
		instance:IsA("LayerCollector")
		or instance:IsA("Light")
		or instance:IsA("ParticleEmitter")
		or instance:IsA("Beam")
		or instance:IsA("Trail")
		or instance:IsA("ProximityPrompt")
	then
		if instance:GetAttribute(ATTR_ENABLED) == nil then
			if visible then
				return
			end
			instance:SetAttribute(ATTR_ENABLED, instance.Enabled)
		end
		instance.Enabled = if visible then instance:GetAttribute(ATTR_ENABLED) == true else false
	end
end

-- Mostra (visible = true) ou esconde uma lista de peças e tudo que estiver dentro delas.
-- Peças escondidas ficam invisíveis, sem colisão e sem bloquear raycasts.
function Common.SetVisible(parts, visible)
	if type(parts) ~= "table" then
		return
	end
	for _, part in ipairs(parts) do
		if typeof(part) == "Instance" then
			setInstanceVisible(part, visible)
			for _, descendant in ipairs(part:GetDescendants()) do
				setInstanceVisible(descendant, visible)
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Barraca (stall)
-------------------------------------------------------------------------------

-- Cores das prateleiras 2 e 3 (a 1 usa a cor da barraca): prata e ouro.
local SHELF_ACCENTS = { nil, Color3.fromRGB(200, 210, 225), Colors.Gold }
-- Cores alegres para os mini-brainrots da barraca de brainrots.
local BRAINROT_TOY_COLORS = {
	Color3.fromRGB(120, 205, 95),
	Color3.fromRGB(190, 95, 225),
	Color3.fromRGB(255, 165, 40),
	Color3.fromRGB(80, 155, 255),
}

-- Itens decorativos das prateleiras. Cada função recebe (pai, CFrame da base do item
-- em cima da tábua, cor de destaque, índice do item) e devolve a lista de peças criadas.
local ShelfItems = {}

-- Mini pistola de lado (cano apontando para +X).
function ShelfItems.Weapon(parent, cframe, accent)
	return {
		Common.Block(parent, cframe * CFrame.new(0, 0.75, 0), Vector3.new(1.3, 0.5, 0.35), accent, Enum.Material.Metal, GHOST),
		Common.Block(parent, cframe * CFrame.new(-0.35, 0.3, 0), Vector3.new(0.35, 0.6, 0.3), Colors.DarkMetal, Enum.Material.Metal, GHOST),
		Common.Part({
			Name = "Barrel",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.8, 0.28, 0.28),
			CFrame = cframe * CFrame.new(0.95, 0.8, 0),
			Color = Colors.DarkMetal,
			Material = Enum.Material.Metal,
			CanCollide = false,
			CanQuery = false,
			Parent = parent,
		}),
	}
end

-- Mini brainrot: bolinha colorida com dois olhos virados para o cliente (-Z).
function ShelfItems.Brainrot(parent, cframe, accent, index, level)
	local color = if level == 3 then Colors.Gold else BRAINROT_TOY_COLORS[((index - 1) % #BRAINROT_TOY_COLORS) + 1]
	local body = Common.Ball(parent, (cframe * CFrame.new(0, 0.5, 0)).Position, 0.95, color, Enum.Material.SmoothPlastic, GHOST)
	local eyeLeft = Common.Ball(parent, (cframe * CFrame.new(-0.2, 0.62, -0.38)).Position, 0.3, Colors.White, Enum.Material.SmoothPlastic, GHOST)
	local eyeRight = Common.Ball(parent, (cframe * CFrame.new(0.2, 0.62, -0.38)).Position, 0.3, Colors.White, Enum.Material.SmoothPlastic, GHOST)
	return { body, eyeLeft, eyeRight }
end

-- Pergaminhos e livros de missão.
function ShelfItems.Quest(parent, cframe, accent, index)
	if index % 2 == 1 then
		local scroll = Common.Part({
			Name = "Scroll",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.2, 0.45, 0.45),
			CFrame = cframe * CFrame.new(0, 0.23, 0),
			Color = Color3.fromRGB(240, 225, 185),
			CanCollide = false,
			CanQuery = false,
			Parent = parent,
		})
		local ribbon = Common.Part({
			Name = "Ribbon",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.16, 0.5, 0.5),
			CFrame = cframe * CFrame.new(0, 0.23, 0),
			Color = accent,
			CanCollide = false,
			CanQuery = false,
			Parent = parent,
		})
		return { scroll, ribbon }
	end
	return {
		Common.Block(parent, cframe * CFrame.new(0, 0.55, 0), Vector3.new(0.9, 1.1, 0.3), accent, Enum.Material.SmoothPlastic, GHOST),
		Common.Block(parent, cframe * CFrame.new(0.05, 0.55, 0), Vector3.new(0.85, 1.0, 0.34), Colors.White, Enum.Material.SmoothPlastic, GHOST),
	}
end

-- Mini torreta: base, cabeça e cano.
function ShelfItems.Turret(parent, cframe, accent)
	return {
		Common.Cylinder(parent, cframe * CFrame.new(0, 0.13, 0), 0.26, 0.85, Colors.DarkMetal, Enum.Material.Metal, GHOST),
		Common.Block(parent, cframe * CFrame.new(0, 0.5, 0), Vector3.new(0.6, 0.45, 0.6), accent, Enum.Material.Metal, GHOST),
		Common.Part({
			Name = "Barrel",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.6, 0.18, 0.18),
			CFrame = cframe * CFrame.new(0.45, 0.52, 0),
			Color = Colors.DarkMetal,
			Material = Enum.Material.Metal,
			CanCollide = false,
			CanQuery = false,
			Parent = parent,
		}),
	}
end

-- Vasinho com planta (ou saco de adubo) para a barraca de crescimento.
function ShelfItems.Growth(parent, cframe, accent, index)
	if index % 2 == 0 then
		return {
			Common.Block(parent, cframe * CFrame.new(0, 0.5, 0), Vector3.new(0.8, 1.0, 0.5), Color3.fromRGB(215, 190, 140), Enum.Material.Fabric, GHOST),
			Common.Block(parent, cframe * CFrame.new(0, 0.55, -0.26), Vector3.new(0.5, 0.4, 0.05), accent, Enum.Material.SmoothPlastic, GHOST),
		}
	end
	return {
		Common.Cylinder(parent, cframe * CFrame.new(0, 0.3, 0), 0.6, 0.8, Color3.fromRGB(190, 95, 60), Enum.Material.Slate, GHOST),
		Common.Ball(parent, (cframe * CFrame.new(0, 0.95, 0)).Position, 0.9, accent, Enum.Material.Grass, GHOST),
	}
end

-- Item genérico (caixinha colorida) para barracas sem tema.
function ShelfItems.Default(parent, cframe, accent)
	return {
		Common.Block(parent, cframe * CFrame.new(0, 0.4, 0), Vector3.new(0.8, 0.8, 0.8), accent, Enum.Material.SmoothPlastic, GHOST),
	}
end

-- Barraca de upgrades: base, balcão com prompt (ClientAction = "Stall:<id>"), toldo listrado,
-- placa com o nome e 3 prateleiras atrás do balcão com itens decorativos.
-- cframe = centro da base no chão, olhando para os clientes (o balcão fica na frente).
-- Devolve { Id, Model, Counter, Prompt, Shelves = { [nível] = {BasePart} }, Position }.
-- A prateleira 1 começa visível; a 2 e a 3 ficam escondidas até MapBuilder.SetShelfLevel.
function Common.Stall(parent, stallId, cframe, color, title)
	stallId = tostring(stallId)
	color = typeof(color) == "Color3" and color or Colors.Wood
	title = tostring(title or stallId)
	local width, depth = STALL_WIDTH, STALL_DEPTH

	local model = Common.Model("Stall_" .. stallId, parent)
	model:SetAttribute("StallId", stallId)

	-- Atalho: CFrame num ponto local da barraca.
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end

	-- Piso de tábuas.
	local floor = Common.Block(model, at(0, 0.3, 0), Vector3.new(width, 0.6, depth), Colors.LightWood, Enum.Material.WoodPlanks)
	floor.Name = "Floor"

	-- Balcão (na cor da barraca) com tampo de madeira clara.
	local counter = Common.Block(model, at(0, 2.3, -depth / 2 + 1.6), Vector3.new(width - 2, 3.4, 2.4), color, Enum.Material.Wood)
	counter.Name = "Counter"
	Common.Block(model, at(0, 4.2, -depth / 2 + 1.5), Vector3.new(width - 1.2, 0.4, 3), Colors.LightWood, Enum.Material.WoodPlanks)
	Common.Sign(counter, Enum.NormalId.Front, title, Colors.White)

	-- Parede do fundo e divisórias baixas nas laterais.
	local backWall = Common.Block(model, at(0, 6.4, depth / 2 - 0.3), Vector3.new(width, 11.6, 0.6), Colors.DarkWood, Enum.Material.WoodPlanks)
	backWall.Name = "BackWall"
	for _, side in ipairs({ -1, 1 }) do
		Common.Block(model, at(side * (width / 2 - 0.3), 2.8, 1.5), Vector3.new(0.6, 4.4, depth - 3), Colors.Wood, Enum.Material.Wood)
	end

	-- Postes da frente que seguram o toldo.
	for _, side in ipairs({ -1, 1 }) do
		Common.Block(model, at(side * (width / 2 - 0.4), 5.5, -depth / 2 + 0.4), Vector3.new(0.8, 9.8, 0.8), Colors.LightWood, Enum.Material.Wood)
	end

	-- Toldo listrado (cor da barraca + branco), mais alto atrás.
	local stripeWidth = (width + 1) / ROOF_STRIPES
	for index = 1, ROOF_STRIPES do
		local x = -(width + 1) / 2 + stripeWidth * (index - 0.5)
		local stripeColor = if index % 2 == 1 then color else Colors.White
		Common.Block(model, at(x, 11.2, -0.5) * CFrame.Angles(ROOF_TILT, 0, 0), Vector3.new(stripeWidth + 0.02, 0.4, depth + 2), stripeColor, Enum.Material.Fabric)
	end

	-- Placa com o nome em cima da frente do toldo.
	local sign = Common.Block(model, at(0, 11.4, -depth / 2 - 1.3), Vector3.new(width - 2, 2.6, 0.35), color, Enum.Material.Wood)
	sign.Name = "TitleSign"
	Common.Sign(sign, Enum.NormalId.Front, title, Colors.White)
	Common.Sign(sign, Enum.NormalId.Back, title, Colors.White)

	-- Prateleiras (3 níveis) encostadas na parede do fundo.
	local shelves = {}
	local itemBuilder = ShelfItems[stallId] or ShelfItems.Default
	for level = 1, #SHELF_HEIGHTS do
		local height = SHELF_HEIGHTS[level]
		local parts = {}
		local plank = Common.Block(model, at(0, height, depth / 2 - 1.6), Vector3.new(width - 3, 0.3, 1.8), Colors.Wood, Enum.Material.WoodPlanks, GHOST)
		plank.Name = "Shelf" .. level
		table.insert(parts, plank)

		local accent = SHELF_ACCENTS[level] or color
		for index, x in ipairs(SHELF_ITEM_X) do
			local itemCFrame = at(x, height + 0.15, depth / 2 - 1.6)
			for _, part in ipairs(itemBuilder(model, itemCFrame, accent, index, level)) do
				part:SetAttribute("ShelfLevel", level)
				table.insert(parts, part)
			end
		end
		plank:SetAttribute("ShelfLevel", level)
		shelves[level] = parts
	end

	-- Prompt no balcão: o cliente abre a janela da barraca.
	local prompt = Common.Prompt(counter, "Ver upgrades", title, { ClientAction = "Stall:" .. stallId })

	-- Prateleiras 2 e 3 começam escondidas.
	for level = 2, #SHELF_HEIGHTS do
		Common.SetVisible(shelves[level], false)
	end

	model.PrimaryPart = floor
	return {
		Id = stallId,
		Model = model,
		Counter = counter,
		Prompt = prompt,
		Shelves = shelves,
		Position = at(0, 6, -depth / 2).Position, -- acima do balcão (confete de compra)
	}
end

-------------------------------------------------------------------------------
-- Estações da praça
-------------------------------------------------------------------------------

-- Quadro "Plantar brainrots" (ServerAction = "Board"). cframe = pé do quadro, virado para os jogadores.
function Common.Board(parent, cframe)
	local model = Common.Model("BoardStation", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end

	-- Pernas.
	for _, side in ipairs({ -1, 1 }) do
		Common.Block(model, at(side * 4.7, 4.2, 0), Vector3.new(0.7, 8.4, 0.7), Colors.DarkWood, Enum.Material.Wood)
	end

	-- Lousa verde (é a parte "Board" do contexto).
	local board = Common.Block(model, at(0, 5.6, 0), Vector3.new(8.6, 5, 0.4), Color3.fromRGB(45, 95, 65), Enum.Material.Slate)
	board.Name = "Board"

	-- Moldura de madeira e um telhadinho vermelho.
	Common.Block(model, at(0, 8.3, 0), Vector3.new(9.6, 0.5, 0.6), Colors.Wood, Enum.Material.Wood)
	Common.Block(model, at(0, 2.9, 0), Vector3.new(9.6, 0.5, 0.6), Colors.Wood, Enum.Material.Wood)
	Common.Block(model, at(0, 8.85, 0), Vector3.new(10.6, 0.4, 1.8), Colors.Red, Enum.Material.WoodPlanks)

	-- Texto de giz nas duas faces.
	local chalk = Color3.fromRGB(235, 245, 235)
	Common.Sign(board, Enum.NormalId.Front, "PLANTAR\nBRAINROTS", chalk)
	Common.Sign(board, Enum.NormalId.Back, "PLANTAR\nBRAINROTS", chalk)

	-- Saquinhos de sementes no pé do quadro.
	Common.Block(model, at(-2.2, 0.55, -0.9), Vector3.new(1.2, 1.1, 0.8), Color3.fromRGB(215, 190, 140), Enum.Material.Fabric, GHOST)
	Common.Block(model, at(2.4, 0.45, -0.8), Vector3.new(1.0, 0.9, 0.7), Color3.fromRGB(200, 170, 120), Enum.Material.Fabric, GHOST)

	local prompt = Common.Prompt(board, "Plantar brainrots", "Quadro", { ServerAction = "Board" })
	model.PrimaryPart = board
	return board, prompt
end

-- Caixote das moedas. cframe = centro da base no chão.
function Common.Crate(parent, cframe)
	local model = Common.Model("CrateStation", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end

	local crate = Common.Block(model, at(0, 2, 0), Vector3.new(5, 4, 5), Color3.fromRGB(170, 118, 66), Enum.Material.WoodPlanks)
	crate.Name = "Crate"

	-- Cantoneiras escuras.
	for _, x in ipairs({ -2.4, 2.4 }) do
		for _, z in ipairs({ -2.4, 2.4 }) do
			Common.Block(model, at(x, 2, z), Vector3.new(0.45, 4.1, 0.45), Colors.DarkWood, Enum.Material.Wood)
		end
	end

	-- Pilhas de moedas douradas em cima.
	for index, offset in ipairs({ Vector3.new(-1, 0, -0.6), Vector3.new(0.9, 0, 0.5), Vector3.new(-0.2, 0, 1.1) }) do
		local stack = 1 + (index % 2)
		for level = 1, stack do
			Common.Cylinder(model, at(offset.X, 4 + level * 0.28, offset.Z), 0.25, 1.2, Colors.Gold, Enum.Material.Metal, GHOST)
		end
	end

	local gold = Color3.fromRGB(255, 215, 80)
	Common.Sign(crate, Enum.NormalId.Front, "MOEDAS", gold)
	Common.Sign(crate, Enum.NormalId.Back, "MOEDAS", gold)

	model.PrimaryPart = crate
	return crate
end

-- Círculo dourado no chão marcando onde as moedas caem.
function Common.CoinMarker(parent, position, radius)
	local marker = Common.Cylinder(parent, position + Vector3.new(0, 0.05, 0), 0.1, radius * 2, Colors.Gold, Enum.Material.SmoothPlastic, {
		Name = "CoinSpot",
		Transparency = 0.55,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
	return marker
end

-- Ponto de nascimento (SpawnLocation) em forma de placa. position = ponto no chão.
function Common.SpawnPad(parent, position, size, color)
	size = typeof(size) == "Vector2" and size or Vector2.new(10, 10)
	-- Borda escura por baixo, para destacar a placa.
	Common.Block(parent, CFrame.new(position + Vector3.new(0, 0.2, 0)), Vector3.new(size.X + 1.2, 0.4, size.Y + 1.2), Colors.DarkStone, Enum.Material.Slate)
	local spawn = Common.Part({
		ClassName = "SpawnLocation",
		Name = "SpawnLocation",
		Size = Vector3.new(size.X, 0.6, size.Y),
		CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0)),
		Color = color or Color3.fromRGB(255, 205, 95),
		Material = Enum.Material.Marble,
	})
	spawn.Neutral = true
	spawn.Duration = 0 -- sem campo de força ao nascer
	spawn.Enabled = true
	spawn.AllowTeamChangeOnTouch = false
	spawn.Parent = parent
	return spawn
end

-- Pad para onde as torretas voltam no "recall". cframe = ponto no chão (a rotação vira a mira).
-- Devolve o CFrame em cima do pad (para ctx.TurretBase) e a peça.
function Common.TurretPad(parent, cframe)
	Common.Cylinder(parent, cframe * CFrame.new(0, 0.1, 0), 0.2, 5.2, Color3.fromRGB(240, 190, 50), Enum.Material.SmoothPlastic)
	local pad = Common.Cylinder(parent, cframe * CFrame.new(0, 0.25, 0), 0.3, 4.4, Colors.Metal, Enum.Material.DiamondPlate)
	pad.Name = "TurretPad"
	return cframe * CFrame.new(0, 0.4, 0), pad
end

-- Estação de respawn de torretas (ServerAction = "RecallTurrets"). cframe = ponto no chão.
function Common.RecallStation(parent, cframe)
	local model = Common.Model("RecallStation", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end
	Common.Block(model, at(0, 0.3, 0), Vector3.new(4.2, 0.6, 4.2), Colors.DarkMetal, Enum.Material.DiamondPlate)
	local pedestal = Common.Block(model, at(0, 2.1, 0), Vector3.new(2.8, 3, 2.8), Color3.fromRGB(70, 150, 230), Enum.Material.Metal)
	pedestal.Name = "RecallStation"
	Common.Cylinder(model, at(0, 3.75, 0), 0.3, 2.2, Colors.DarkMetal, Enum.Material.Metal)
	Common.Cylinder(model, at(0, 4.05, 0), 0.4, 1.5, Color3.fromRGB(235, 50, 50), Enum.Material.Neon, GHOST)

	-- Antena com luz piscando (só visual).
	Common.Cylinder(model, at(1.1, 5.2, 1.1), 3, 0.2, Colors.DarkMetal, Enum.Material.Metal, GHOST)
	local beacon = Common.Ball(model, at(1.1, 6.9, 1.1).Position, 0.6, Color3.fromRGB(90, 200, 255), Enum.Material.Neon, GHOST)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(90, 200, 255)
	light.Range = 10
	light.Brightness = 1
	light.Shadows = false
	light.Parent = beacon

	Common.Sign(pedestal, Enum.NormalId.Front, "TORRETAS", Colors.White)
	local prompt = Common.Prompt(pedestal, "Chamar torretas de volta", "Estação de Torretas", { ServerAction = "RecallTurrets" })
	model.PrimaryPart = pedestal
	return pedestal, prompt
end

-- Base de pedra onde o portal aparece (arco com duas colunas e orbes apagados).
-- cframe = centro no chão, virado para o lado de onde os jogadores chegam.
-- O MapBuilder.OpenPortal acende os orbes (peças "PortalOrb") quando o portal abre.
function Common.PortalPad(parent, cframe)
	local model = Common.Model("PortalPad", parent)
	local function at(x, y, z)
		return cframe * CFrame.new(x, y, z)
	end
	Common.Cylinder(model, at(0, 0.2, 0), 0.4, 16, Colors.Stone, Enum.Material.Slate)
	Common.Cylinder(model, at(0, 0.45, 0), 0.1, 13, Color3.fromRGB(120, 100, 150), Enum.Material.Slate, GHOST)
	for _, side in ipairs({ -1, 1 }) do
		Common.Block(model, at(side * 8.6, 7.5, 0), Vector3.new(1.6, 15, 1.6), Colors.Stone, Enum.Material.Slate)
		local orb = Common.Ball(model, at(side * 8.6, 17.2, 0).Position, 2, Color3.fromRGB(90, 75, 120), Enum.Material.SmoothPlastic, GHOST)
		orb.Name = "PortalOrb"
	end
	Common.Block(model, at(0, 15.6, 0), Vector3.new(19.2, 1.2, 1.9), Colors.DarkStone, Enum.Material.Slate)
	return model
end

-- Placa grande em dois postes (boas-vindas, nome do mapa...). cframe = centro no chão, virado para quem lê.
-- size = Vector2 (largura, altura da placa). Devolve a peça da placa.
function Common.SignPost(parent, cframe, text, size, bgColor, textColor, postHeight)
	size = typeof(size) == "Vector2" and size or Vector2.new(12, 4)
	postHeight = postHeight or (size.Y + 4)
	local model = Common.Model("SignPost", parent)
	for _, side in ipairs({ -1, 1 }) do
		Common.Block(model, cframe * CFrame.new(side * (size.X / 2 - 0.5), postHeight / 2, 0), Vector3.new(0.8, postHeight, 0.8), Colors.DarkWood, Enum.Material.Wood)
	end
	local board = Common.Block(model, cframe * CFrame.new(0, postHeight - size.Y / 2, 0), Vector3.new(size.X, size.Y, 0.5), bgColor or Colors.Wood, Enum.Material.Wood)
	board.Name = "SignBoard"
	Common.Sign(board, Enum.NormalId.Front, text, textColor)
	Common.Sign(board, Enum.NormalId.Back, text, textColor)
	model.PrimaryPart = board
	return board
end

-------------------------------------------------------------------------------
-- Iluminação
-------------------------------------------------------------------------------

-- Propriedades do Lighting que um mapa pode trocar (chaves de Config.Maps[x].Lighting).
local LIGHTING_KEYS = {
	"ClockTime",
	"Brightness",
	"Ambient",
	"OutdoorAmbient",
	"ExposureCompensation",
	"EnvironmentDiffuseScale",
	"EnvironmentSpecularScale",
	"GeographicLatitude",
	"ColorShift_Top",
	"ColorShift_Bottom",
	"ShadowSoftness",
	"GlobalShadows",
	"LightingStyle",
	"PrioritizeLightingQuality",
	"FogColor",
	"FogStart",
	"FogEnd",
}
local ATMOSPHERE_KEYS = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" }

-- BASE (seção 3.2 do plano): tudo volta a este "normal" antes de cada mapa, para nada do
-- mapa anterior vazar para o próximo. (Technology fica no default.project.json: script não
-- consegue mudar.)
local LIGHTING_BASE = {
	Ambient = rgb(0, 0, 0),
	OutdoorAmbient = rgb(128, 128, 128),
	ColorShift_Top = rgb(0, 0, 0),
	ColorShift_Bottom = rgb(0, 0, 0),
	EnvironmentDiffuseScale = 1,
	EnvironmentSpecularScale = 1,
	ShadowSoftness = 0.2,
	Brightness = 2,
	ExposureCompensation = 0,
	GeographicLatitude = 41.733,
	FogEnd = 100000,
	FogStart = 0,
	FogColor = rgb(192, 192, 192),
	ClockTime = 14,
	GlobalShadows = true,
	LightingStyle = Enum.LightingStyle.Realistic,
	PrioritizeLightingQuality = true,
}

-- Valores padrão de uma Atmosphere nova do Roblox (a BASE da atmosfera).
local ATMOSPHERE_BASE = {
	Density = 0.395,
	Offset = 0,
	Color = rgb(199, 199, 199),
	Decay = rgb(106, 112, 125),
	Glare = 0,
	Haze = 0,
}

-- Água do terreno: chave da config -> propriedade do Terrain, e os valores padrão do Roblox.
local WATER_PROPERTIES = {
	Color = "WaterColor",
	Transparency = "WaterTransparency",
	WaveSize = "WaterWaveSize",
	WaveSpeed = "WaterWaveSpeed",
	Reflectance = "WaterReflectance",
}
local WATER_BASE = {
	Color = Color3.new(0.05, 0.33, 0.36),
	Transparency = 0.3,
	WaveSize = 0.15,
	WaveSpeed = 10,
	Reflectance = 1,
}

-- Efeitos de pós-processamento aceitos em config.PostFX (nome na config -> classe do Roblox).
local POSTFX_ORDER = { "ColorCorrection", "Bloom", "SunRays", "DepthOfField" }
local POSTFX_CLASSES = {
	ColorCorrection = "ColorCorrectionEffect",
	Bloom = "BloomEffect",
	SunRays = "SunRaysEffect",
	DepthOfField = "DepthOfFieldEffect",
}
local SKY_KEYS = { "SunAngularSize", "MoonAngularSize", "StarCount" }
local CLOUD_KEYS = { "Cover", "Density", "Color" }

-- Ajusta uma propriedade protegida (um valor errado na config só gera um aviso).
local function setProperty(instance, key, value, label)
	local ok, err = pcall(function()
		instance[key] = value
	end)
	if not ok then
		warn(("[Common] Não deu para ajustar %s.%s: %s"):format(label or instance.Name, key, tostring(err)))
	end
end

-- Aceita "Realistic" (texto) ou Enum.LightingStyle.Realistic na config.
local function normalizeLightingValue(key, value)
	if key == "LightingStyle" and type(value) == "string" then
		local ok, item = pcall(function()
			return Enum.LightingStyle[value]
		end)
		return if ok then item else nil
	end
	return value
end

-- Apaga tudo que um mapa criou no Lighting e no Terrain (atributo MapEffect = true):
-- efeitos de pós-processamento, céu (MapSky) e nuvens (MapClouds).
local function clearMapEffects()
	for _, container in ipairs({ Lighting, getTerrain() }) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:GetAttribute(MAP_EFFECT_ATTRIBUTE) == true then
					child:Destroy()
				end
			end
		end
	end
end

-- A única Atmosphere do Lighting (apaga cópias extras). Cria uma se "create" for true.
-- Ela NUNCA é marcada com MapEffect: o StatService (nevasca) e o SupremeService mexem nela.
local function getAtmosphere(create)
	local atmosphere = nil
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:IsA("Atmosphere") then
			if atmosphere == nil then
				atmosphere = child
			else
				child:Destroy()
			end
		end
	end
	if not atmosphere and create then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	return atmosphere
end

-- Acha um filho da classe pedida que NÃO seja do mapa (colocado à mão pelo dono do jogo).
local function findOwnerInstance(container, className)
	for _, child in ipairs(container:GetChildren()) do
		if child.ClassName == className and child:GetAttribute(MAP_EFFECT_ATTRIBUTE) ~= true then
			return child
		end
	end
	return nil
end

-- Céu: config.Sky = { SunAngularSize, MoonAngularSize, StarCount }.
-- Se o dono do jogo pôs um Sky próprio no Lighting, usamos ele (só ajustamos os tamanhos).
local function applySky(settings)
	local sky = findOwnerInstance(Lighting, "Sky")
	if not sky then
		sky = Lighting:FindFirstChild("MapSky")
		if not (sky and sky:IsA("Sky")) then
			sky = Instance.new("Sky")
			sky.Name = "MapSky"
		end
		sky:SetAttribute(MAP_EFFECT_ATTRIBUTE, true)
	end
	sky.CelestialBodiesShown = true
	for _, key in ipairs(SKY_KEYS) do
		if settings[key] ~= nil then
			setProperty(sky, key, settings[key], "Sky")
		end
	end
	sky.Parent = Lighting
end

-- Nuvens dinâmicas: config.Clouds = { Cover, Density, Color } (objeto Clouds no Terrain).
local function applyClouds(settings)
	local terrain = getTerrain()
	if not terrain then
		return
	end
	local clouds = findOwnerInstance(terrain, "Clouds")
	if not clouds then
		clouds = terrain:FindFirstChild("MapClouds")
		if not (clouds and clouds:IsA("Clouds")) then
			clouds = Instance.new("Clouds")
			clouds.Name = "MapClouds"
		end
		clouds:SetAttribute(MAP_EFFECT_ATTRIBUTE, true)
	end
	clouds.Enabled = true
	for _, key in ipairs(CLOUD_KEYS) do
		if settings[key] ~= nil then
			setProperty(clouds, key, settings[key], "Clouds")
		end
	end
	clouds.Parent = terrain
end

-- Água do terreno: primeiro os valores padrão, depois os da config (se vierem).
local function applyWater(settings)
	local terrain = getTerrain()
	if not terrain then
		return
	end
	for key, property in pairs(WATER_PROPERTIES) do
		local value = WATER_BASE[key]
		if type(settings) == "table" and settings[key] ~= nil then
			value = settings[key]
		end
		setProperty(terrain, property, value, "Terrain")
	end
end

-- Aplica uma tabela de iluminação no formato de Config.Maps[x].Lighting (seção 3.3 do plano):
--   { ClockTime, Brightness, Ambient, OutdoorAmbient, ColorShift_Top, GeographicLatitude,
--     EnvironmentSpecularScale, ShadowSoftness, LightingStyle, PrioritizeLightingQuality, ...,
--     Atmosphere = { Density, Offset, Color, Decay, Glare, Haze },
--     PostFX = { Bloom = {...}, ColorCorrection = {...}, SunRays = {...}, DepthOfField = {...} },
--     Sky = { SunAngularSize, MoonAngularSize, StarCount },
--     Clouds = { Cover, Density, Color },
--     Wind = Vector3,                                  (vira workspace.GlobalWind)
--     Water = { Color, Transparency, WaveSize, WaveSpeed, Reflectance } }
-- Ordem: 1) BASE (apaga efeitos/céu/nuvens do mapa anterior, zera vento e água);
-- 2) chaves do Lighting; 3) Atmosphere; 4) PostFX, Sky, Clouds, Wind, Water.
-- Sub-tabela que faltar = fica como na BASE. Usa sempre UMA Atmosphere só.
function Common.ApplyLighting(config)
	if type(config) ~= "table" then
		return
	end

	-- 1. BASE: nada do mapa anterior sobra.
	clearMapEffects()
	for key, value in pairs(LIGHTING_BASE) do
		setProperty(Lighting, key, value, "Lighting")
	end
	workspace.GlobalWind = Vector3.zero

	-- 2. Chaves do próprio Lighting.
	for _, key in ipairs(LIGHTING_KEYS) do
		local value = normalizeLightingValue(key, config[key])
		if value ~= nil then
			setProperty(Lighting, key, value, "Lighting")
		end
	end

	-- 3. Atmosphere (BASE + config).
	local atmosphereConfig = if type(config.Atmosphere) == "table" then config.Atmosphere else nil
	local atmosphere = getAtmosphere(atmosphereConfig ~= nil)
	if atmosphere then
		for key, value in pairs(ATMOSPHERE_BASE) do
			setProperty(atmosphere, key, value, "Atmosphere")
		end
		if atmosphereConfig then
			for _, key in ipairs(ATMOSPHERE_KEYS) do
				if atmosphereConfig[key] ~= nil then
					setProperty(atmosphere, key, atmosphereConfig[key], "Atmosphere")
				end
			end
		end
	end

	-- 4. Pós-processamento.
	if type(config.PostFX) == "table" then
		for _, name in ipairs(POSTFX_ORDER) do
			local props = config.PostFX[name]
			if type(props) == "table" then
				Common.LightingEffect(POSTFX_CLASSES[name], props)
			end
		end
	end

	-- 5. Céu e nuvens.
	if type(config.Sky) == "table" then
		applySky(config.Sky)
	end
	if type(config.Clouds) == "table" then
		applyClouds(config.Clouds)
	end

	-- 6. Vento (grama do terreno, nuvens e partículas com WindAffectsDrag).
	if typeof(config.Wind) == "Vector3" then
		workspace.GlobalWind = config.Wind
	end

	-- 7. Água do terreno.
	applyWater(if type(config.Water) == "table" then config.Water else nil)
end

-- Cria (ou reaproveita, se já existe) um efeito de pós-processamento (ColorCorrection,
-- Bloom, SunRays...) no Lighting, chamado "Map" .. className e marcado para ser apagado
-- quando outro mapa for montado. Chamar de novo com a mesma classe só ajusta o mesmo efeito.
function Common.LightingEffect(className, props)
	local name = "Map" .. tostring(className)
	local effect = Lighting:FindFirstChild(name)
	if effect and effect.ClassName ~= className then
		effect:Destroy()
		effect = nil
	end
	if not effect then
		effect = Instance.new(className)
		effect.Name = name
	end
	for key, value in pairs(props or {}) do
		setProperty(effect, key, value, name)
	end
	effect:SetAttribute(MAP_EFFECT_ATTRIBUTE, true)
	effect.Parent = Lighting
	return effect
end

-- Apaga os efeitos criados por mapas anteriores (no Lighting e no Terrain, como as nuvens),
-- zera o vento (workspace.GlobalWind) e devolve as cores originais do terreno.
function Common.ClearLightingEffects()
	clearMapEffects()
	workspace.GlobalWind = Vector3.zero
	restoreTerrainColors()
end

-- Garante um céu (Sky) com o sol visível e ajusta o tamanho do sol (em graus).
function Common.SetSun(angularSize)
	local sky = Lighting:FindFirstChildOfClass("Sky")
	if not sky then
		sky = Instance.new("Sky")
		sky.Name = "MapSky"
		sky:SetAttribute(MAP_EFFECT_ATTRIBUTE, true)
		sky.Parent = Lighting
	end
	sky.CelestialBodiesShown = true
	if type(angularSize) == "number" and angularSize > 0 then
		sky.SunAngularSize = angularSize
	end
	return sky
end

return Common
