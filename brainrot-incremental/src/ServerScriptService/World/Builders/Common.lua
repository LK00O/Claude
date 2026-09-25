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
--   Common.Tree(parent, position, style, scale, options?) -> Model   style: "Oak" | "Pine" | "Palm"
--   Common.Rock(parent, position, size, options?) -> Model
--   Common.Fence(parent, center, size, height, gapSide?) -> Model
--   Common.Stall(parent, stallId, cframe, color, title) -> stallTable
--   Common.Board(parent, cframe) -> part, prompt
--   Common.Crate(parent, cframe) -> part
--   Common.Ground(parent, size, color, material) -> Part
--   Common.Lamp(parent, position) -> Model
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
-- Módulo de World: NÃO dá require em nenhum serviço (regra 1.2).

local Lighting = game:GetService("Lighting")

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

-- Árvore feita de peças. style: "Oak" (carvalho), "Pine" (pinheiro) ou "Palm" (palmeira).
-- options (opcional): { Snow = true } neve em cima; { Ghost = true } tronco sem colisão
-- (para árvores no meio da área de tiro, como as palmeiras do oásis).
-- Folhas nunca bloqueiam tiros nem jogadores.
function Common.Tree(parent, position, style, scale, options)
	scale = (type(scale) == "number" and scale > 0) and scale or 1
	options = type(options) == "table" and options or {}
	style = style or "Oak"
	local trunkExtra = options.Ghost and GHOST or nil
	local model = Common.Model(style .. "Tree", parent)
	local trunk

	if style == "Pine" then
		-- Tronco curto + 4 camadas de "saia" cada vez menores.
		trunk = Common.Cylinder(model, position + Vector3.new(0, 2 * scale, 0), 4 * scale, 1.1 * scale, Colors.Trunk, Enum.Material.Wood, trunkExtra)
		local tiers = {
			{ Diameter = 9.2, Y = 4.2 },
			{ Diameter = 7.2, Y = 6.4 },
			{ Diameter = 5.2, Y = 8.6 },
			{ Diameter = 3.2, Y = 10.6 },
		}
		for index, tier in ipairs(tiers) do
			local shade = mix(Colors.PineDark, Colors.Pine, index / #tiers)
			Common.Cylinder(model, position + Vector3.new(0, tier.Y * scale, 0), 2.6 * scale, tier.Diameter * scale, shade, Enum.Material.Grass, GHOST)
			if options.Snow then
				-- Camadinha de neve em cima de cada "saia".
				Common.Cylinder(model, position + Vector3.new(0, (tier.Y + 1.45) * scale, 0), 0.3 * scale, tier.Diameter * 0.86 * scale, Colors.Snow, Enum.Material.Snow, GHOST)
			end
		end
		Common.Ball(model, position + Vector3.new(0, 12.2 * scale, 0), 1.6 * scale, options.Snow and Colors.Snow or Colors.Pine, Enum.Material.Grass, GHOST)
	elseif style == "Palm" then
		-- Tronco curvo feito de 5 gomos, inclinando para um lado sorteado.
		local leanAngle = rng:NextNumber(0, math.pi * 2)
		local leanDir = Vector3.new(math.cos(leanAngle), 0, math.sin(leanAngle))
		local segmentLength = 2.8 * scale
		local points = { position }
		for index = 1, 5 do
			local bend = math.rad(4 + index * 5)
			local direction = (Vector3.yAxis * math.cos(bend) + leanDir * math.sin(bend)).Unit
			points[index + 1] = points[index] + direction * segmentLength
		end
		local barkA = Color3.fromRGB(150, 110, 70)
		local barkB = Color3.fromRGB(125, 90, 58)
		for index = 1, 5 do
			local diameter = (1.35 - index * 0.09) * scale
			local segment = Common.CylinderBetween(model, points[index], points[index + 1], diameter, index % 2 == 0 and barkA or barkB, Enum.Material.Wood, trunkExtra)
			if index == 1 then
				trunk = segment
			end
		end
		-- Folhas: cada uma sobe um pouco e depois cai (duas placas).
		local top = points[#points]
		local frondCount = 6
		for index = 1, frondCount do
			local angle = (index / frondCount) * math.pi * 2 + rng:NextNumber(-0.25, 0.25)
			local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
			local mid = top + out * 3.4 * scale + Vector3.new(0, 0.9 * scale, 0)
			local tip = top + out * 6.6 * scale + Vector3.new(0, -2.3 * scale, 0)
			Common.Slab(model, top, mid, 1.9 * scale, 0.2 * scale, Colors.Leaf, Enum.Material.Grass, GHOST)
			Common.Slab(model, mid, tip, 1.5 * scale, 0.2 * scale, Colors.LeafDark, Enum.Material.Grass, GHOST)
		end
		-- Cocos.
		for index = 1, 3 do
			local angle = index * 2.1
			local offset = Vector3.new(math.cos(angle) * 0.7, -0.7, math.sin(angle) * 0.7) * scale
			Common.Ball(model, top + offset, 0.9 * scale, Color3.fromRGB(95, 65, 35), Enum.Material.Wood, GHOST)
		end
	else
		-- Carvalho: tronco grosso e copa de várias bolas.
		trunk = Common.Cylinder(model, position + Vector3.new(0, 4 * scale, 0), 8 * scale, 1.6 * scale, Colors.Trunk, Enum.Material.Wood, trunkExtra)
		local canopy = {
			{ Vector3.new(0, 9.6, 0), 8 },
			{ Vector3.new(2.6, 8.4, 0.8), 5.6 },
			{ Vector3.new(-2.3, 8.6, -1.2), 5.8 },
			{ Vector3.new(0.6, 12, 0.3), 4.2 },
		}
		for index, blob in ipairs(canopy) do
			local shade = if index % 2 == 0 then Colors.LeafDark else Colors.Leaf
			Common.Ball(model, position + blob[1] * scale, blob[2] * scale, shade, Enum.Material.LeafyGrass, GHOST)
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
function Common.Lamp(parent, position)
	local model = Common.Model("Lamp", parent)
	Common.Cylinder(model, position + Vector3.new(0, 0.3, 0), 0.6, 1.6, Colors.DarkMetal, Enum.Material.Metal)
	local pole = Common.Cylinder(model, position + Vector3.new(0, 5.3, 0), 10, 0.45, Colors.DarkMetal, Enum.Material.Metal)
	pole.Name = "Pole"
	Common.Block(model, CFrame.new(position + Vector3.new(0, 10.45, 0)), Vector3.new(1.7, 0.3, 1.7), Colors.DarkMetal, Enum.Material.Metal)
	local lantern = Common.Block(model, CFrame.new(position + Vector3.new(0, 11.35, 0)), Vector3.new(1.2, 1.5, 1.2), Colors.Warm, Enum.Material.Neon, GHOST)
	lantern.Name = "Lantern"
	Common.Block(model, CFrame.new(position + Vector3.new(0, 12.3, 0)), Vector3.new(1.6, 0.4, 1.6), Colors.DarkMetal, Enum.Material.Metal)

	local light = Instance.new("PointLight")
	light.Color = Colors.Warm
	light.Range = 20
	light.Brightness = 1.4
	light.Shadows = false
	light.Parent = lantern

	model.PrimaryPart = pole
	return model
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

-- Propriedades do Lighting que um mapa pode trocar.
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
}
local ATMOSPHERE_KEYS = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" }

-- Aplica uma tabela de iluminação no formato de Config.Maps[x].Lighting:
-- { ClockTime, Brightness, Ambient, OutdoorAmbient, Atmosphere = { Density, Offset, Color, Decay, Glare, Haze } }.
-- Usa sempre UMA Atmosphere só (o StatService e o SupremeService mexem nela depois).
function Common.ApplyLighting(config)
	if type(config) ~= "table" then
		return
	end
	-- Volta ao "normal" o que outros mapas/efeitos podem ter mudado.
	Lighting.ExposureCompensation = 0
	Lighting.GlobalShadows = true

	for _, key in ipairs(LIGHTING_KEYS) do
		local value = config[key]
		if value ~= nil then
			local ok, err = pcall(function()
				Lighting[key] = value
			end)
			if not ok then
				warn(("[Common] Não deu para ajustar Lighting.%s: %s"):format(key, tostring(err)))
			end
		end
	end

	if type(config.Atmosphere) == "table" then
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		if not atmosphere then
			atmosphere = Instance.new("Atmosphere")
			atmosphere.Parent = Lighting
		end
		for _, key in ipairs(ATMOSPHERE_KEYS) do
			local value = config.Atmosphere[key]
			if value ~= nil then
				local ok, err = pcall(function()
					atmosphere[key] = value
				end)
				if not ok then
					warn(("[Common] Não deu para ajustar Atmosphere.%s: %s"):format(key, tostring(err)))
				end
			end
		end
	end
end

-- Cria um efeito de pós-processamento (ColorCorrection, Bloom, SunRays...) no Lighting,
-- marcado para ser apagado quando outro mapa for montado.
function Common.LightingEffect(className, props)
	local effect = Instance.new(className)
	effect.Name = "Map" .. className
	for key, value in pairs(props or {}) do
		effect[key] = value
	end
	effect:SetAttribute(MAP_EFFECT_ATTRIBUTE, true)
	effect.Parent = Lighting
	return effect
end

-- Apaga os efeitos criados por mapas anteriores.
function Common.ClearLightingEffects()
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:GetAttribute(MAP_EFFECT_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
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
