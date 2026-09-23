--!nonstrict
-- TurretFactory: monta o modelo 3D das torretas (Atos 2 e 3).
--
--   TurretFactory.Build(ownerName, colors?) -> Model
--       Cria uma torreta nova (sem pai) com:
--         * "Base"  (PrimaryPart): chapa de aço no chão. O pivô do modelo fica no CENTRO
--                   DA PARTE DE BAIXO da base, então Model:PivotTo(CFrame no chão) já
--                   deixa a torreta apoiada certinho no chão.
--         * "Head"  : a cabeça que gira no eixo Y. O cano aponta para -Z da Head.
--         * "Muzzle": Attachment dentro da Head, na ponta dos canos (de onde sai o tiro).
--         * BillboardGui "OwnerTag" com o nome do dono e o modo de mira.
--         * Dois ProximityPrompts: "PickupPrompt" (ServerAction = "PickupTurret",
--           "Recolher", segurar 0,3 s) e "ModePrompt" (ServerAction = "TurretMode",
--           "Mirar: mais valioso").
--         Tudo ancorado e no grupo de colisão "Turrets".
--       colors (opcional) = { Primary = Color3, Secondary = Color3, Accent = Color3 }.
--
--   TurretFactory.AimHead(model, targetPosition)
--       Gira a cabeça (e tudo que está preso nela: canos, olho, antena...) para o alvo.
--
-- Como a cabeça gira se tudo é ancorado? Cada parte da cabeça guarda no atributo
-- "HeadOffset" (um CFrame) onde ela fica em relação à Head. Para girar, calculamos o
-- novo CFrame da Head e movemos todas as partes da cabeça juntas com workspace:BulkMoveTo
-- (bem mais rápido que mudar o CFrame de cada parte separadamente).
--
-- World/* não dá require em nenhum serviço (regra 1.2 da especificação).

local TurretFactory = {}

-------------------------------------------------------------------------------
-- Constantes visuais (não são balanceamento)
-------------------------------------------------------------------------------
local COLLISION_GROUP = "Turrets"
local PROMPT_DISTANCE = 12 -- seção 7.3: todos os prompts têm MaxActivationDistance = 12
local PICKUP_HOLD = 0.3 -- seção 7.7: segurar 0,3 s para recolher
local BILLBOARD_MAX_DISTANCE = 80 -- a plaquinha com o nome some de longe
local HEAD_OFFSET_ATTRIBUTE = "HeadOffset" -- CFrame de cada parte em relação à Head
local MIN_AIM_DOT = 0.99995 -- se a cabeça já está quase mirando (< ~0,6°), não mexe

-- Cores padrão (azul da Barraca de Torretas, aço escuro e detalhe amarelo).
local DEFAULT_COLORS = {
	Primary = Color3.fromRGB(70, 150, 230),
	Secondary = Color3.fromRGB(62, 66, 78),
	Accent = Color3.fromRGB(255, 212, 70),
}

-- Textos do prompt de modo (o mesmo texto que o TurretService usa ao trocar o modo).
local MODE_ACTION_TEXT = "Mirar: mais valioso"
local MODE_LABEL_TEXT = "Alvo: mais valioso"

-- Geometria (em studs). A torreta inteira tem ~4,8 studs de altura.
local BASE_SIZE = Vector3.new(4, 0.6, 4)
local TURNTABLE_HEIGHT, TURNTABLE_DIAMETER = 0.5, 3.2
local PILLAR_HEIGHT, PILLAR_DIAMETER = 1.6, 1.3
local HEAD_SIZE = Vector3.new(2.4, 1.5, 2.6)
local BARREL_LENGTH, BARREL_DIAMETER = 2.8, 0.45
local BRAKE_LENGTH, BRAKE_DIAMETER = 0.5, 0.65
local BARREL_SPACING = 0.45 -- distância de cada cano até o centro (são dois canos)
local BARREL_DROP = -0.1 -- canos um pouquinho abaixo do centro da cabeça

-- Rotações usadas para "deitar" cilindros (o cilindro do Roblox tem o eixo em X).
local CYLINDER_UP = CFrame.Angles(0, 0, math.rad(90)) -- eixo em Y (em pé)
local CYLINDER_FORWARD = CFrame.Angles(0, math.rad(90), 0) -- eixo em Z (apontando para frente)

-- Cache das partes da cabeça de cada modelo: [model] = { Parts = {BasePart}, Offsets = {CFrame} }.
-- Tabela "fraca" nas chaves: quando o modelo é destruído e esquecido, o cache some junto.
local headCache = setmetatable({}, { __mode = "k" })

-------------------------------------------------------------------------------
-- Ajudantes de construção
-------------------------------------------------------------------------------

-- Cria uma parte ancorada no grupo "Turrets" com as propriedades dadas.
local function makePart(className, props)
	local part = Instance.new(className)
	part.Anchored = true
	part.CanTouch = false
	part.CanCollide = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CollisionGroup = COLLISION_GROUP
	for key, value in pairs(props) do
		part[key] = value
	end
	return part
end

-- Cria um cilindro (Part com Shape = Cylinder).
-- length = comprimento no eixo do cilindro; diameter = grossura.
local function makeCylinder(props, length, diameter)
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(length, diameter, diameter)
	return makePart("Part", props)
end

-- Uma TextLabel simples para a plaquinha do dono.
local function makeLabel(name, text, font, color, size, position)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Size = size
	label.Position = position
	label.Font = font
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextStrokeTransparency = 0.25
	label.TextStrokeColor3 = Color3.fromRGB(20, 20, 30)
	return label
end

-- Cria um ProximityPrompt no padrão da seção 7.3.
local function makePrompt(parent, name, actionText, objectText, serverAction, holdDuration, keyCode, gamepadKey)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.HoldDuration = holdDuration
	prompt.KeyboardKeyCode = keyCode
	prompt.GamepadKeyCode = gamepadKey
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt:SetAttribute("ServerAction", serverAction)
	prompt.Parent = parent
	return prompt
end

-- Lê as cores pedidas, completando o que faltar com as cores padrão.
local function resolveColors(colors)
	local result = table.clone(DEFAULT_COLORS)
	if type(colors) == "table" then
		for key in pairs(DEFAULT_COLORS) do
			if typeof(colors[key]) == "Color3" then
				result[key] = colors[key]
			end
		end
	end
	return result
end

-------------------------------------------------------------------------------
-- TurretFactory.Build
-------------------------------------------------------------------------------

function TurretFactory.Build(ownerName, colors)
	local palette = resolveColors(colors)
	local displayName = (type(ownerName) == "string" and ownerName ~= "") and ownerName or "Jogador"

	local model = Instance.new("Model")
	model.Name = "Turret"

	-- Alturas (y = 0 é o chão; o modelo é montado na origem e depois movido com PivotTo).
	local baseTop = BASE_SIZE.Y
	local turntableY = baseTop + TURNTABLE_HEIGHT / 2
	local pillarY = baseTop + TURNTABLE_HEIGHT + PILLAR_HEIGHT / 2
	local headY = baseTop + TURNTABLE_HEIGHT + PILLAR_HEIGHT + HEAD_SIZE.Y / 2

	---------------------------------------------------------------------------
	-- Parte fixa (não gira): base, parafusos, mesa giratória e coluna
	---------------------------------------------------------------------------

	-- Base: chapa de aço quadrada. É a PrimaryPart.
	local base = makePart("Part", {
		Name = "Base",
		Size = BASE_SIZE,
		CFrame = CFrame.new(0, BASE_SIZE.Y / 2, 0),
		Color = palette.Secondary,
		Material = Enum.Material.DiamondPlate,
		CanCollide = true,
	})
	-- Pivô do modelo = centro da face de baixo da base (fica "no chão").
	base.PivotOffset = CFrame.new(0, -BASE_SIZE.Y / 2, 0)
	base.Parent = model

	-- Quatro parafusos amarelos nos cantos (só enfeite).
	local boltInset = BASE_SIZE.X / 2 - 0.4
	for _, corner in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
		makePart("Part", {
			Name = "Bolt",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.4, 0.4, 0.4),
			CFrame = CFrame.new(corner[1] * boltInset, baseTop, corner[2] * boltInset),
			Color = palette.Accent,
			Material = Enum.Material.Metal,
			CastShadow = false,
		}).Parent = model
	end

	-- Mesa giratória (disco) em cima da base.
	makeCylinder({
		Name = "Turntable",
		CFrame = CFrame.new(0, turntableY, 0) * CYLINDER_UP,
		Color = palette.Primary:Lerp(Color3.new(0, 0, 0), 0.35),
		Material = Enum.Material.Metal,
		CanCollide = true,
	}, TURNTABLE_HEIGHT, TURNTABLE_DIAMETER).Parent = model

	-- Coluna que segura a cabeça.
	makeCylinder({
		Name = "Pillar",
		CFrame = CFrame.new(0, pillarY, 0) * CYLINDER_UP,
		Color = palette.Secondary,
		Material = Enum.Material.Metal,
		CanCollide = true,
	}, PILLAR_HEIGHT, PILLAR_DIAMETER).Parent = model

	---------------------------------------------------------------------------
	-- Cabeça (gira no eixo Y). Tudo aqui é posicionado em relação à Head.
	---------------------------------------------------------------------------
	local headCFrame = CFrame.new(0, headY, 0)

	local head = makePart("Part", {
		Name = "Head",
		Size = HEAD_SIZE,
		CFrame = headCFrame,
		Color = palette.Primary,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = true,
	})
	head.Parent = model

	-- Lista das partes que acompanham a cabeça: {parte, CFrame relativo à Head}.
	local headParts = { { head, CFrame.identity } }
	local function addHeadPart(part, localCFrame)
		part.CFrame = headCFrame * localCFrame
		part.Parent = model
		table.insert(headParts, { part, localCFrame })
		return part
	end

	-- Blindagem inclinada na frente de cima da cabeça.
	addHeadPart(
		makePart("WedgePart", {
			Name = "HeadArmor",
			Size = Vector3.new(HEAD_SIZE.X, 0.6, 1.3),
			Color = palette.Primary:Lerp(Color3.new(1, 1, 1), 0.2),
			Material = Enum.Material.SmoothPlastic,
		}),
		CFrame.new(0, HEAD_SIZE.Y / 2 + 0.3, -HEAD_SIZE.Z / 2 + 0.65)
	)

	-- Dois canos apontando para -Z, cada um com um "freio de boca" amarelo na ponta.
	local barrelCenterZ = -HEAD_SIZE.Z / 2 - BARREL_LENGTH / 2 + 0.1
	local brakeCenterZ = barrelCenterZ - BARREL_LENGTH / 2 - BRAKE_LENGTH / 2 + 0.05
	for index, side in ipairs({ -1, 1 }) do
		addHeadPart(
			makeCylinder({
				Name = "Barrel" .. index,
				Color = palette.Secondary:Lerp(Color3.new(0, 0, 0), 0.3),
				Material = Enum.Material.Metal,
			}, BARREL_LENGTH, BARREL_DIAMETER),
			CFrame.new(side * BARREL_SPACING, BARREL_DROP, barrelCenterZ) * CYLINDER_FORWARD
		)
		addHeadPart(
			makeCylinder({
				Name = "MuzzleBrake" .. index,
				Color = palette.Accent,
				Material = Enum.Material.Metal,
				CastShadow = false,
			}, BRAKE_LENGTH, BRAKE_DIAMETER),
			CFrame.new(side * BARREL_SPACING, BARREL_DROP, brakeCenterZ) * CYLINDER_FORWARD
		)
	end

	-- "Olho" sensor brilhante na frente (com uma luz fraca).
	local eye = addHeadPart(
		makePart("Part", {
			Name = "Eye",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.55, 0.55, 0.55),
			Color = palette.Accent,
			Material = Enum.Material.Neon,
			CastShadow = false,
		}),
		CFrame.new(HEAD_SIZE.X / 2 - 0.35, HEAD_SIZE.Y / 2 - 0.2, -HEAD_SIZE.Z / 2 - 0.05)
	)
	local light = Instance.new("PointLight")
	light.Color = palette.Accent
	light.Range = 6
	light.Brightness = 1.2
	light.Shadows = false
	light.Parent = eye

	-- Caixa de munição na lateral.
	addHeadPart(
		makePart("Part", {
			Name = "AmmoBox",
			Size = Vector3.new(0.6, 0.9, 1.3),
			Color = palette.Secondary,
			Material = Enum.Material.Metal,
		}),
		CFrame.new(HEAD_SIZE.X / 2 + 0.3, -0.1, 0.25)
	)
	addHeadPart(
		makePart("Part", {
			Name = "AmmoStripe",
			Size = Vector3.new(0.62, 0.18, 1.32),
			Color = palette.Accent,
			Material = Enum.Material.SmoothPlastic,
			CastShadow = false,
		}),
		CFrame.new(HEAD_SIZE.X / 2 + 0.3, 0.15, 0.25)
	)

	-- Antena com uma bolinha brilhante na ponta.
	addHeadPart(
		makeCylinder({
			Name = "Antenna",
			Color = palette.Secondary,
			Material = Enum.Material.Metal,
			CastShadow = false,
		}, 1.2, 0.12),
		CFrame.new(-HEAD_SIZE.X / 2 + 0.4, HEAD_SIZE.Y / 2 + 0.6, HEAD_SIZE.Z / 2 - 0.4) * CYLINDER_UP
	)
	addHeadPart(
		makePart("Part", {
			Name = "AntennaTip",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.3, 0.3, 0.3),
			Color = palette.Accent,
			Material = Enum.Material.Neon,
			CastShadow = false,
		}),
		CFrame.new(-HEAD_SIZE.X / 2 + 0.4, HEAD_SIZE.Y / 2 + 1.25, HEAD_SIZE.Z / 2 - 0.4)
	)

	-- Guarda o CFrame relativo de cada parte da cabeça (usado pelo AimHead).
	for _, entry in ipairs(headParts) do
		entry[1]:SetAttribute(HEAD_OFFSET_ATTRIBUTE, entry[2])
	end

	-- Muzzle: ponto de onde sai o tiro, entre os dois canos, na ponta.
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, BARREL_DROP, brakeCenterZ - BRAKE_LENGTH / 2 - 0.1)
	muzzle.Parent = head

	---------------------------------------------------------------------------
	-- Plaquinha com o nome do dono e o modo de mira
	---------------------------------------------------------------------------
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "OwnerTag"
	billboard.Adornee = base
	billboard.Size = UDim2.fromOffset(170, 46)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, headY + HEAD_SIZE.Y / 2 + 2.2, 0)
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0
	billboard.MaxDistance = BILLBOARD_MAX_DISTANCE
	billboard.Parent = base

	makeLabel(
		"OwnerName",
		"Torreta de " .. displayName,
		Enum.Font.FredokaOne,
		Color3.new(1, 1, 1),
		UDim2.fromScale(1, 0.6),
		UDim2.fromScale(0, 0)
	).Parent =
		billboard
	makeLabel(
		"Mode",
		MODE_LABEL_TEXT,
		Enum.Font.GothamBold,
		palette.Accent,
		UDim2.fromScale(1, 0.4),
		UDim2.fromScale(0, 0.6)
	).Parent =
		billboard

	---------------------------------------------------------------------------
	-- Prompts (cada um num Attachment da base, em alturas diferentes, para não
	-- ficarem um em cima do outro na tela).
	---------------------------------------------------------------------------
	local pickupAttachment = Instance.new("Attachment")
	pickupAttachment.Name = "PickupAttachment"
	pickupAttachment.Position = Vector3.new(0, 1.3, 0) -- em relação ao centro da base
	pickupAttachment.Parent = base

	local modeAttachment = Instance.new("Attachment")
	modeAttachment.Name = "ModeAttachment"
	modeAttachment.Position = Vector3.new(0, headY + HEAD_SIZE.Y / 2 - BASE_SIZE.Y / 2 + 0.4, 0)
	modeAttachment.Parent = base

	-- Recolher: tecla E (a de interação), segurando 0,3 s.
	makePrompt(
		pickupAttachment,
		"PickupPrompt",
		"Recolher",
		"Torreta",
		"PickupTurret",
		PICKUP_HOLD,
		Enum.KeyCode.E,
		Enum.KeyCode.ButtonX
	)
	-- Modo de mira: tecla F. Dois prompts com a MESMA tecla no mesmo lugar fariam o
	-- Roblox mostrar só um deles (Exclusivity = OnePerButton), então este usa outra tecla.
	makePrompt(
		modeAttachment,
		"ModePrompt",
		MODE_ACTION_TEXT,
		"Modo da torreta",
		"TurretMode",
		0,
		Enum.KeyCode.F,
		Enum.KeyCode.ButtonY
	)

	model.PrimaryPart = base
	return model
end

-------------------------------------------------------------------------------
-- TurretFactory.AimHead
-------------------------------------------------------------------------------

-- Lê (e guarda no cache) as partes da cabeça do modelo e seus CFrames relativos.
local function getHeadRig(model)
	local rig = headCache[model]
	if rig and rig.Head.Parent == model then
		return rig
	end

	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return nil
	end

	local parts, offsets = {}, {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local offset = descendant:GetAttribute(HEAD_OFFSET_ATTRIBUTE)
			if typeof(offset) == "CFrame" then
				table.insert(parts, descendant)
				table.insert(offsets, offset)
			end
		end
	end
	-- Garante que a própria Head está na lista (mesmo num modelo sem atributos).
	if not table.find(parts, head) then
		table.insert(parts, head)
		table.insert(offsets, CFrame.identity)
	end

	rig = { Head = head, Parts = parts, Offsets = offsets }
	headCache[model] = rig
	return rig
end

-- Gira a cabeça no eixo Y para que o cano (-Z da Head) aponte para targetPosition.
function TurretFactory.AimHead(model, targetPosition)
	if typeof(model) ~= "Instance" or not model:IsA("Model") or typeof(targetPosition) ~= "Vector3" then
		return
	end
	local rig = getHeadRig(model)
	if not rig then
		return
	end

	local headPosition = rig.Head.Position
	-- Só a direção no plano XZ importa (a cabeça gira apenas em Y).
	local flat = Vector3.new(targetPosition.X - headPosition.X, 0, targetPosition.Z - headPosition.Z)
	if flat.Magnitude < 0.05 then
		return -- alvo bem em cima/embaixo: não dá para saber para onde virar
	end
	local direction = flat.Unit

	-- Já está mirando para lá? Então não mexe (economiza replicação).
	local look = rig.Head.CFrame.LookVector
	local currentFlat = Vector3.new(look.X, 0, look.Z)
	if currentFlat.Magnitude > 0.01 and currentFlat.Unit:Dot(direction) >= MIN_AIM_DOT then
		return
	end

	-- Novo CFrame da cabeça: mesma posição, olhando para o alvo (lookAt deixa -Z virado para ele).
	local newHeadCFrame = CFrame.lookAt(headPosition, headPosition + direction)

	-- Move todas as partes da cabeça de uma vez só.
	local cframes = table.create(#rig.Parts)
	for index, offset in ipairs(rig.Offsets) do
		cframes[index] = newHeadCFrame * offset
	end
	workspace:BulkMoveTo(rig.Parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

return TurretFactory
