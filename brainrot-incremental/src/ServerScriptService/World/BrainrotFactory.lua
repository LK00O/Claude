--!nonstrict
-- BrainrotFactory: monta os modelos 3D dos brainrots.
--
--   BrainrotFactory.Build(def) -> Model
--       Se existir ServerStorage.BrainrotModels.<def.ModelName>, clona e "normaliza" esse modelo.
--       Senão, monta um modelo provisório feito de Parts, pelo Archetype do brainrot
--       ("Totem", "Quadruped", "Flyer", "Fish", "Blob", "Biped", "Tree", "Cactus"),
--       com as cores de def.Colors, olhos e detalhes de cada personagem.
--       O modelo volta em escala 1 (~5 studs de altura), sem pai, com:
--         * PrimaryPart = parte "Body";
--         * pivô no centro da BASE (assim Model:ScaleTo mantém os pés no chão);
--         * todas as partes ancoradas, sem colisão, CollisionGroup "Brainrots".
--   BrainrotFactory.BuildSupreme(def) -> Model      versão caprichada do Brainrot Supremo
--   BrainrotFactory.AttachBillboard(model, displayName, tierColor, enchantName?, enchantColor?) -> {Gui, Fill}
--   BrainrotFactory.ApplyEnchantVisual(model, enchantDef) -> {Particles, Light, Aura?}
--   BrainrotFactory.AddIceBlock(model) -> Part
--
-- Módulo de World: NÃO dá require em nenhum serviço.
-- O atributo "BrainrotId" do modelo é gravado pelo BrainrotService, não aqui.

local ServerStorage = game:GetService("ServerStorage")

local BrainrotFactory = {}

-------------------------------------------------------------------------------
-- Constantes técnicas (aparência), não são balanceamento
-------------------------------------------------------------------------------

local TARGET_HEIGHT = 5 -- altura (studs) de um brainrot em escala 1
local COLLISION_GROUP = "Brainrots"
local MODELS_FOLDER_NAME = "BrainrotModels" -- pasta em ServerStorage com modelos finais

local BILLBOARD_MAX_DISTANCE = 250
local BILLBOARD_OFFSET = Vector3.new(0, 1.2, 0) -- acima da cabeça (studs, espaço do mundo)
local BILLBOARD_WIDTH = 190

local ICE_PADDING = 0.5 -- folga do bloco de gelo em volta do modelo

-- Nomes de partes que não recebem a "tinta" do encantamento (olhos, boca, efeitos).
local NO_TINT = {
	Eye = true,
	Pupil = true,
	Mouth = true,
	FxVolume = true,
	EnchantAura = true,
	IceBlock = true,
	IceCrystal = true,
}

-- Partes de efeito que não entram na medida do tamanho do modelo.
local FX_PARTS = {
	FxVolume = true,
	EnchantAura = true,
	IceBlock = true,
}

-- Cores fixas.
local WHITE = Color3.fromRGB(250, 250, 250)
local BLACK = Color3.fromRGB(20, 20, 25)
local GOLD = Color3.fromRGB(255, 205, 60)
local ROYAL_RED = Color3.fromRGB(150, 20, 45)
local METAL_GRAY = Color3.fromRGB(165, 165, 175)
local HEALTH_COLOR = Color3.fromRGB(95, 225, 95)
local BAR_BACK_COLOR = Color3.fromRGB(35, 35, 40)
local ICE_COLOR = Color3.fromRGB(170, 220, 255)

-- Cores usadas se a configuração não trouxer Colors.
local DEFAULT_COLORS = {
	Primary = Color3.fromRGB(200, 120, 220),
	Secondary = Color3.fromRGB(120, 80, 160),
	Accent = Color3.fromRGB(255, 220, 120),
}

-- Texturas de partícula que já vêm com o Roblox (não precisam de upload).
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local FIRE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"

-------------------------------------------------------------------------------
-- Ajudantes gerais
-------------------------------------------------------------------------------

-- Graus para radianos (só para deixar as posições mais legíveis).
local function deg(value)
	return math.rad(value)
end

-- Deixa uma parte do jeito que todo brainrot precisa: ancorada, sem colisão,
-- sem Touched e (se canQuery) atingível por raycasts/tiros.
local function configurePart(part, canQuery)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = canQuery
	part.Massless = true
	pcall(function()
		part.CollisionGroup = COLLISION_GROUP
	end)
end

-- Caixa alinhada ao mundo que envolve todas as partes do modelo.
-- Devolve (mínimo, máximo) como Vector3, ou nil se não houver partes.
-- "skip" = nomes de partes ignoradas (efeitos).
local function worldBounds(model, skip)
	local minV, maxV = nil, nil
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and not (skip and skip[descendant.Name]) then
			local cf = descendant.CFrame
			local half = descendant.Size / 2
			local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector
			-- Meia-extensão da parte girada, projetada nos eixos do mundo.
			local extent = Vector3.new(
				math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z,
				math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z,
				math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
			)
			local low = cf.Position - extent
			local high = cf.Position + extent
			minV = if minV then minV:Min(low) else low
			maxV = if maxV then maxV:Max(high) else high
		end
	end
	return minV, maxV
end

-- Parte principal de um modelo: PrimaryPart, depois "Body", depois a maior parte.
local function getBody(model)
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	local body = model:FindFirstChild("Body", true)
	if body and body:IsA("BasePart") then
		return body
	end
	local best, bestVolume = nil, -1
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") and not FX_PARTS[descendant.Name] then
			local size = descendant.Size
			local volume = size.X * size.Y * size.Z
			if volume > bestVolume then
				best, bestVolume = descendant, volume
			end
		end
	end
	return best
end

-- Cria um Attachment num ponto do MUNDO, preso à parte "part".
local function attachmentAt(part, name, worldPosition)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	-- CFrame do attachment é relativo à parte; convertemos a posição do mundo.
	attachment.CFrame = part.CFrame:ToObjectSpace(CFrame.new(worldPosition))
	attachment.Parent = part
	return attachment
end

-- Parte invisível que cobre o corpo do brainrot. Serve de "emissor" para partículas
-- e luzes (encantamento, fogo, lentidão). Como fica dentro do modelo, é escalada e
-- movida junto com ele pelo ScaleTo/PivotTo.
local function createFxVolume(model, minV, maxV)
	local part = Instance.new("Part")
	part.Name = "FxVolume"
	part.Size = (maxV - minV) * 0.8
	part.CFrame = CFrame.new((minV + maxV) / 2)
	part.Transparency = 1
	part.CastShadow = false
	configurePart(part, false)
	part.Parent = model
	return part
end

-- Passos finais comuns a todos os modelos:
--   * pivô no centro da base (pés no chão ao escalar);
--   * PrimaryPart;
--   * attachment no topo para o BillboardGui;
--   * volume invisível para efeitos;
--   * atributo "BaseHeight" com a altura em escala 1;
--   * modelo movido para a origem.
local function finalizeModel(model, primary)
	local minV, maxV = worldBounds(model, FX_PARTS)
	if not minV then
		return model
	end
	local height = maxV.Y - minV.Y
	local baseCenter = Vector3.new((minV.X + maxV.X) / 2, minV.Y, (minV.Z + maxV.Z) / 2)
	local basePivot = CFrame.new(baseCenter)

	-- Sem PrimaryPart o pivô é o WorldPivot; com PrimaryPart é o PivotOffset dela.
	-- Gravamos os dois para ficar certo nos dois casos.
	model.WorldPivot = basePivot
	model.PrimaryPart = primary
	primary.PivotOffset = primary.CFrame:ToObjectSpace(basePivot)

	if not model:FindFirstChild("BillboardAttachment", true) then
		attachmentAt(primary, "BillboardAttachment", baseCenter + Vector3.new(0, height, 0))
	end
	if not model:FindFirstChild("FxVolume") then
		createFxVolume(model, minV, maxV)
	end
	model:SetAttribute("BaseHeight", height)

	-- Coloca o centro da base na origem do mundo (fica organizado para quem usar depois).
	model:PivotTo(CFrame.identity)
	return model
end

-------------------------------------------------------------------------------
-- Modelos finais em ServerStorage/BrainrotModels
-------------------------------------------------------------------------------

-- Procura o modelo final com o nome dado (ou nil se não existir).
local function findCustomTemplate(modelName)
	if type(modelName) ~= "string" or modelName == "" then
		return nil
	end
	local folder = ServerStorage:FindFirstChild(MODELS_FOLDER_NAME)
	if not folder then
		return nil
	end
	local template = folder:FindFirstChild(modelName)
	if template and (template:IsA("Model") or template:IsA("BasePart")) then
		return template
	end
	return nil
end

-- Clona o modelo final e o deixa no padrão do jogo (ancorado, sem colisão,
-- grupo "Brainrots", ~targetHeight studs, pivô no centro da base, escala 1).
local function buildFromTemplate(template, name, targetHeight, canQuery)
	local source = template:Clone()

	-- Se o dono colocou uma Part solta em vez de um Model, embrulha num Model.
	if source:IsA("BasePart") then
		local wrapper = Instance.new("Model")
		wrapper.Name = source.Name
		source.Parent = wrapper
		source = wrapper
	end

	local partCount = 0
	for _, descendant in ipairs(source:GetDescendants()) do
		if descendant:IsA("BasePart") then
			configurePart(descendant, canQuery)
			partCount += 1
		elseif descendant:IsA("Humanoid") then
			-- Humanoid mostraria nome e vida padrão do Roblox por cima do nosso BillboardGui.
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			descendant.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		end
	end
	if partCount == 0 then
		source:Destroy()
		warn("[BrainrotFactory] O modelo '" .. template.Name .. "' não tem partes; usando o provisório.")
		return nil
	end

	local primary = getBody(source)
	source.PrimaryPart = primary

	-- Ajusta a escala para a altura padrão.
	local minV, maxV = worldBounds(source)
	local height = maxV.Y - minV.Y
	if height > 1e-3 and math.abs(height - targetHeight) > 1e-3 then
		local ok, err = pcall(function()
			source:ScaleTo(source:GetScale() * (targetHeight / height))
		end)
		if not ok then
			warn("[BrainrotFactory] Não foi possível ajustar a escala de '" .. template.Name .. "': " .. tostring(err))
		end
	end

	-- O ScaleTo guarda a escala no próprio Model. Para o tamanho ajustado virar a
	-- "escala 1", movemos todas as peças para um Model novo (que começa em escala 1).
	local model = Instance.new("Model")
	model.Name = name
	for key, value in pairs(source:GetAttributes()) do
		model:SetAttribute(key, value)
	end
	for _, child in ipairs(source:GetChildren()) do
		child.Parent = model
	end
	source:Destroy()

	return finalizeModel(model, primary)
end

-------------------------------------------------------------------------------
-- Construtor de modelos provisórios
-------------------------------------------------------------------------------
-- Convenções: o modelo é montado com o centro da base em (0, 0, 0), altura ~5,
-- e a FRENTE (rosto) virada para -Z (a mesma direção do LookVector de um CFrame).

local Builder = {}
Builder.__index = Builder

local function newBuilder(def, canQuery)
	local colors = if type(def.Colors) == "table" then def.Colors else {}
	local self = setmetatable({
		Model = Instance.new("Model"),
		Primary = colors.Primary or DEFAULT_COLORS.Primary,
		Secondary = colors.Secondary or DEFAULT_COLORS.Secondary,
		Accent = colors.Accent or DEFAULT_COLORS.Accent,
		Parts = {}, -- [nome] = primeira parte criada com esse nome
		CanQuery = canQuery,
	}, Builder)
	self.Model.Name = tostring(def.Id or def.ModelName or "Brainrot")
	return self
end

-- Cria uma parte (Part ou WedgePart) já configurada e dentro do modelo.
function Builder:Add(className, name, shape, size, cframe, color, material)
	local part = Instance.new(className)
	part.Name = name
	if shape then
		part.Shape = shape -- o formato vem antes do tamanho (bola força tamanho igual)
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	configurePart(part, self.CanQuery)
	part.Parent = self.Model
	if not self.Parts[name] then
		self.Parts[name] = part
	end
	return part
end

-- Esfera de diâmetro "diameter".
function Builder:Ball(name, diameter, position, color, material)
	return self:Add("Part", name, Enum.PartType.Ball, Vector3.one * diameter, CFrame.new(position), color, material)
end

-- Bloco; "where" pode ser um Vector3 (posição) ou um CFrame (posição + rotação).
function Builder:Block(name, size, where, color, material)
	local cframe = if typeof(where) == "Vector3" then CFrame.new(where) else where
	return self:Add("Part", name, Enum.PartType.Block, size, cframe, color, material)
end

-- Cunha (WedgePart): a rampa fica virada para a frente (-Z) e a parede reta para trás.
function Builder:Wedge(name, size, where, color, material)
	local cframe = if typeof(where) == "Vector3" then CFrame.new(where) else where
	return self:Add("WedgePart", name, nil, size, cframe, color, material)
end

-- Cilindro em pé (eixo vertical). "tilt" (CFrame de rotação) inclina o cilindro.
function Builder:VCylinder(name, diameter, height, position, color, material, tilt)
	local cframe = CFrame.new(position) * (tilt or CFrame.identity) * CFrame.Angles(0, 0, deg(90))
	return self:Add("Part", name, Enum.PartType.Cylinder, Vector3.new(height, diameter, diameter), cframe, color, material)
end

-- Cilindro deitado no eixo Z (da frente para trás).
function Builder:ZCylinder(name, diameter, length, position, color, material)
	local cframe = CFrame.new(position) * CFrame.Angles(0, deg(90), 0)
	return self:Add("Part", name, Enum.PartType.Cylinder, Vector3.new(length, diameter, diameter), cframe, color, material)
end

-- Cilindro deitado no eixo X (de um lado para o outro).
function Builder:XCylinder(name, diameter, length, position, color, material)
	return self:Add(
		"Part",
		name,
		Enum.PartType.Cylinder,
		Vector3.new(length, diameter, diameter),
		CFrame.new(position),
		color,
		material
	)
end

-- Dois olhos brancos com pupila preta, olhando para a frente (-Z).
function Builder:Eyes(center, spacing, size)
	for _, side in ipairs({ -1, 1 }) do
		local eyePosition = center + Vector3.new(side * spacing / 2, 0, 0)
		self:Ball("Eye", size, eyePosition, WHITE)
		self:Ball("Pupil", size * 0.5, eyePosition + Vector3.new(0, 0, -size * 0.32), BLACK)
	end
end

-- Boca: um risquinho preto.
function Builder:Mouth(position, width, height)
	return self:Block("Mouth", Vector3.new(width, height or 0.16, 0.12), position, BLACK)
end

-- Pinta todas as partes com esse nome.
function Builder:Paint(name, color)
	for _, child in ipairs(self.Model:GetChildren()) do
		if child.Name == name and child:IsA("BasePart") then
			child.Color = color
		end
	end
end

-- Remove todas as partes com esse nome (para detalhes que trocam uma peça do arquétipo).
function Builder:Remove(name)
	for _, child in ipairs(self.Model:GetChildren()) do
		if child.Name == name then
			child:Destroy()
		end
	end
	self.Parts[name] = nil
end

-- Termina o modelo: PrimaryPart "Body", pivô na base, attachment do BillboardGui etc.
function Builder:Finish()
	local body = self.Parts.Body or getBody(self.Model)
	return finalizeModel(self.Model, body)
end

-------------------------------------------------------------------------------
-- Arquétipos (formas básicas)
-------------------------------------------------------------------------------

local Archetypes = {}

-- Totem: tronco em pé com braços (ex.: Tung Tung Tung Sahur).
function Archetypes.Totem(b)
	local P, S, A = b.Primary, b.Secondary, b.Accent
	b:Block("Foot", Vector3.new(0.7, 0.4, 0.9), Vector3.new(-0.5, 0.2, -0.15), S)
	b:Block("Foot", Vector3.new(0.7, 0.4, 0.9), Vector3.new(0.5, 0.2, -0.15), S)
	b:VCylinder("Body", 2.2, 4.2, Vector3.new(0, 2.5, 0), P)
	b:VCylinder("TopRing", 2.3, 0.3, Vector3.new(0, 4.65, 0), S)
	b:VCylinder("BottomRing", 2.3, 0.25, Vector3.new(0, 0.55, 0), S)
	b:Eyes(Vector3.new(0, 3.8, -1.05), 0.8, 0.6)
	b:Mouth(Vector3.new(0, 3.1, -1.1), 0.9)
	-- Braços inclinados para fora, com mãozinhas na ponta.
	b:Block("Arm", Vector3.new(0.35, 1.8, 0.35), CFrame.new(-1.35, 2.6, -0.1) * CFrame.Angles(0, 0, deg(-18)), S)
	b:Block("Arm", Vector3.new(0.35, 1.8, 0.35), CFrame.new(1.35, 2.6, -0.1) * CFrame.Angles(0, 0, deg(18)), S)
	b:Ball("Hand", 0.5, Vector3.new(-1.63, 1.74, -0.1), A)
	b:Ball("Hand", 0.5, Vector3.new(1.63, 1.74, -0.1), A)
end

-- Quadrúpede: corpo comprido, 4 pernas, cabeça na frente.
function Archetypes.Quadruped(b)
	local P, S, A = b.Primary, b.Secondary, b.Accent
	for _, x in ipairs({ -0.7, 0.7 }) do
		for _, z in ipairs({ -1.1, 1.2 }) do
			b:VCylinder("Leg", 0.55, 1.8, Vector3.new(x, 0.9, z), S)
		end
	end
	b:ZCylinder("Body", 2.0, 2.6, Vector3.new(0, 2.6, 0.1), P)
	b:Ball("BodyFront", 2.0, Vector3.new(0, 2.6, -1.2), P)
	b:Ball("BodyBack", 2.0, Vector3.new(0, 2.6, 1.4), P)
	b:Ball("Head", 1.7, Vector3.new(0, 3.9, -2.2), P)
	b:Ball("Snout", 0.95, Vector3.new(0, 3.55, -2.95), A)
	b:Eyes(Vector3.new(0, 4.15, -2.85), 0.7, 0.45)
	b:Block("Ear", Vector3.new(0.25, 0.55, 0.4), CFrame.new(-0.65, 4.65, -2.1) * CFrame.Angles(0, 0, deg(25)), S)
	b:Block("Ear", Vector3.new(0.25, 0.55, 0.4), CFrame.new(0.65, 4.65, -2.1) * CFrame.Angles(0, 0, deg(-25)), S)
	b:Block("Tail", Vector3.new(0.2, 0.2, 1.1), CFrame.new(0, 3.0, 2.75) * CFrame.Angles(deg(30), 0, 0), S)
end

-- Voador: fuselagem + asas + perninhas de pouso (ex.: Bombardiro Crocodilo).
function Archetypes.Flyer(b)
	local P, S, A = b.Primary, b.Secondary, b.Accent
	b:VCylinder("Leg", 0.3, 1.9, Vector3.new(-0.55, 0.95, 0.1), S)
	b:VCylinder("Leg", 0.3, 1.9, Vector3.new(0.55, 0.95, 0.1), S)
	b:Block("Foot", Vector3.new(0.55, 0.2, 0.8), Vector3.new(-0.55, 0.1, -0.1), A)
	b:Block("Foot", Vector3.new(0.55, 0.2, 0.8), Vector3.new(0.55, 0.1, -0.1), A)
	b:ZCylinder("Body", 1.8, 3.0, Vector3.new(0, 2.8, 0.2), P)
	b:Ball("Head", 1.8, Vector3.new(0, 2.8, -1.3), P)
	b:Ball("BodyBack", 1.8, Vector3.new(0, 2.8, 1.7), P)
	-- Asas levemente levantadas nas pontas.
	b:Block("Wing", Vector3.new(2.6, 0.22, 1.5), CFrame.new(-1.95, 2.95, 0.2) * CFrame.Angles(0, 0, deg(-8)), S)
	b:Block("Wing", Vector3.new(2.6, 0.22, 1.5), CFrame.new(1.95, 2.95, 0.2) * CFrame.Angles(0, 0, deg(8)), S)
	b:Block("TailFin", Vector3.new(0.2, 1.3, 0.9), Vector3.new(0, 3.95, 2.1), S)
	b:Block("TailWing", Vector3.new(1.9, 0.18, 0.7), Vector3.new(0, 2.95, 2.35), S)
	b:Eyes(Vector3.new(0, 3.2, -1.95), 0.8, 0.5)
end

-- Peixe/tubarão com pernas e tênis (ex.: Tralalero Tralala).
function Archetypes.Fish(b)
	local P, S, A = b.Primary, b.Secondary, b.Accent
	for _, x in ipairs({ -0.55, 0.55 }) do
		b:VCylinder("Leg", 0.45, 1.7, Vector3.new(x, 1.15, 0.3), P)
		b:Block("Shoe", Vector3.new(0.6, 0.35, 1.0), Vector3.new(x, 0.175, 0.15), A)
		b:Block("Sole", Vector3.new(0.62, 0.1, 1.02), Vector3.new(x, 0.05, 0.15), WHITE)
	end
	b:ZCylinder("Body", 2.2, 2.6, Vector3.new(0, 3.1, 0.3), P)
	b:Ball("Head", 2.2, Vector3.new(0, 3.1, -1.0), P)
	b:Ball("BodyBack", 2.0, Vector3.new(0, 3.1, 1.65), P)
	b:Ball("Belly", 1.9, Vector3.new(0, 2.55, -0.9), S)
	b:Wedge("DorsalFin", Vector3.new(0.25, 1.1, 1.3), Vector3.new(0, 4.6, 0.5), P)
	-- Cauda em "V" (a ponta de cima para trás e para cima, a de baixo para trás e para baixo).
	b:Block("TailFin", Vector3.new(0.22, 1.3, 0.6), CFrame.new(0, 3.63, 3.02) * CFrame.Angles(deg(35), 0, 0), P)
	b:Block("TailFin", Vector3.new(0.22, 1.1, 0.55), CFrame.new(0, 2.65, 2.96) * CFrame.Angles(deg(-35), 0, 0), P)
	b:Block("Fin", Vector3.new(0.9, 0.15, 0.6), CFrame.new(-1.3, 2.7, -0.3) * CFrame.Angles(0, 0, deg(25)), P)
	b:Block("Fin", Vector3.new(0.9, 0.15, 0.6), CFrame.new(1.3, 2.7, -0.3) * CFrame.Angles(0, 0, deg(-25)), P)
	b:Eyes(Vector3.new(0, 3.55, -1.85), 1.1, 0.55)
	b:Mouth(Vector3.new(0, 2.75, -2.02), 0.9)
end

-- Bolota: esfera grande com olhos (ex.: Pinguino Congelino).
function Archetypes.Blob(b)
	local P, S, A = b.Primary, b.Secondary, b.Accent
	b:Block("Foot", Vector3.new(0.9, 0.4, 1.1), Vector3.new(-0.75, 0.2, -0.35), S)
	b:Block("Foot", Vector3.new(0.9, 0.4, 1.1), Vector3.new(0.75, 0.2, -0.35), S)
	b:Ball("Body", 4.2, Vector3.new(0, 2.4, 0), P)
	b:Ball("Arm", 0.8, Vector3.new(-2.1, 2.2, -0.2), S)
	b:Ball("Arm", 0.8, Vector3.new(2.1, 2.2, -0.2), S)
	b:Eyes(Vector3.new(0, 3.05, -1.85), 1.3, 0.8)
	b:Mouth(Vector3.new(0, 2.15, -2.08), 1.1, 0.22)
	b:VCylinder("Antenna", 0.15, 0.5, Vector3.new(0, 4.7, 0), S)
	b:Ball("AntennaTip", 0.4, Vector3.new(0, 5.0, 0), A)
end

-- Bípede: humanoide simples (ex.: Ballerina Cappuccina).
function Archetypes.Biped(b)
	local P, S, A = b.Primary, b.Secondary, b.Accent
	local shoeColor = S:Lerp(BLACK, 0.4)
	for _, x in ipairs({ -0.42, 0.42 }) do
		b:Block("Leg", Vector3.new(0.55, 2.0, 0.6), Vector3.new(x, 1.15, 0), S)
		b:Block("Shoe", Vector3.new(0.65, 0.3, 0.9), Vector3.new(x, 0.15, -0.12), shoeColor)
	end
	b:Block("Body", Vector3.new(1.7, 1.6, 1.0), Vector3.new(0, 2.95, 0), P)
	b:Block("Arm", Vector3.new(0.45, 1.5, 0.5), CFrame.new(-1.15, 2.95, 0) * CFrame.Angles(0, 0, deg(-10)), P)
	b:Block("Arm", Vector3.new(0.45, 1.5, 0.5), CFrame.new(1.15, 2.95, 0) * CFrame.Angles(0, 0, deg(10)), P)
	b:Ball("Hand", 0.5, Vector3.new(-1.3, 2.1, 0), A)
	b:Ball("Hand", 0.5, Vector3.new(1.3, 2.1, 0), A)
	b:Ball("Head", 1.5, Vector3.new(0, 4.3, 0), P)
	b:Eyes(Vector3.new(0, 4.45, -0.62), 0.55, 0.4)
	b:Mouth(Vector3.new(0, 4.0, -0.7), 0.5, 0.12)
end

-- Árvore: tronco + copa com rosto e pezões (ex.: Brr Brr Patapim).
function Archetypes.Tree(b)
	local P, S, A = b.Primary, b.Secondary, b.Accent
	for _, x in ipairs({ -0.5, 0.5 }) do
		b:Block("Foot", Vector3.new(0.95, 0.45, 1.4), Vector3.new(x * 1.1, 0.225, -0.3), A)
		b:VCylinder("Leg", 0.45, 0.6, Vector3.new(x * 0.9, 0.7, 0), A)
	end
	b:VCylinder("Body", 1.3, 2.3, Vector3.new(0, 2.05, 0), S)
	b:Block("Branch", Vector3.new(1.4, 0.3, 0.3), CFrame.new(-1.05, 2.4, 0) * CFrame.Angles(0, 0, deg(-30)), S)
	b:Block("Branch", Vector3.new(1.4, 0.3, 0.3), CFrame.new(1.05, 2.4, 0) * CFrame.Angles(0, 0, deg(30)), S)
	b:Ball("Canopy", 2.9, Vector3.new(0, 3.75, 0.1), P)
	b:Ball("Canopy", 1.8, Vector3.new(-1.35, 3.45, 0.3), P)
	b:Ball("Canopy", 1.8, Vector3.new(1.35, 3.45, 0.3), P)
	b:Ball("Face", 1.7, Vector3.new(0, 3.6, -0.75), A)
	b:Eyes(Vector3.new(0, 3.85, -1.45), 0.6, 0.45)
	b:Ball("Nose", 0.35, Vector3.new(0, 3.5, -1.62), S)
	b:Mouth(Vector3.new(0, 3.2, -1.5), 0.5, 0.12)
end

-- Cacto: tronco com braços em "L", espinhos e florzinha (ex.: Lirilì Larilà).
function Archetypes.Cactus(b)
	local P, A = b.Primary, b.Accent
	local spikeColor = P:Lerp(WHITE, 0.6)
	for _, x in ipairs({ -0.45, 0.45 }) do
		b:Block("Sandal", Vector3.new(0.7, 0.2, 1.0), Vector3.new(x, 0.1, -0.15), A)
		b:VCylinder("Leg", 0.5, 0.5, Vector3.new(x, 0.45, 0), P)
	end
	b:VCylinder("Body", 1.9, 3.6, Vector3.new(0, 2.4, 0), P)
	b:Ball("Top", 1.9, Vector3.new(0, 4.2, 0), P)
	-- Braço esquerdo (mais alto) e direito (mais baixo).
	b:XCylinder("Arm", 0.7, 0.9, Vector3.new(-1.25, 2.7, 0), P)
	b:VCylinder("Arm", 0.7, 1.2, Vector3.new(-1.7, 3.2, 0), P)
	b:Ball("ArmTip", 0.7, Vector3.new(-1.7, 3.8, 0), P)
	b:XCylinder("Arm", 0.7, 0.9, Vector3.new(1.25, 2.2, 0), P)
	b:VCylinder("Arm", 0.7, 1.1, Vector3.new(1.7, 2.65, 0), P)
	b:Ball("ArmTip", 0.7, Vector3.new(1.7, 3.2, 0), P)
	-- Espinhos em volta do tronco (abaixo do rosto).
	for _, y in ipairs({ 1.3, 2.3 }) do
		for i = 0, 7 do
			local angle = deg(22.5 + i * 45)
			local outward = Vector3.new(math.sin(angle), 0, -math.cos(angle))
			local position = Vector3.new(0, y, 0) + outward * 1.02
			b:Block("Spike", Vector3.new(0.08, 0.08, 0.35), CFrame.lookAt(position, position + outward), spikeColor)
		end
	end
	b:Eyes(Vector3.new(0, 3.85, -0.9), 0.75, 0.5)
	b:Mouth(Vector3.new(0, 3.3, -0.97), 0.6, 0.14)
	b:Ball("Flower", 0.55, Vector3.new(0.35, 5.05, -0.2), A:Lerp(WHITE, 0.3))
end

-------------------------------------------------------------------------------
-- Detalhes de cada personagem (em cima do arquétipo)
-------------------------------------------------------------------------------

-- Taco de madeira na mão (os Sahurs).
local function addBat(b, handPosition, color)
	local tilt = CFrame.Angles(deg(-20), 0, deg(-10))
	local up = tilt:VectorToWorldSpace(Vector3.yAxis)
	local length = 1.8
	b:VCylinder("Bat", 0.3, length, handPosition + up * (length / 2 - 0.2), color, nil, tilt)
	b:Ball("BatTip", 0.5, handPosition + up * (length - 0.2), color)
end

-- Dentes em forma de losango (bloquinhos girados 45°).
local function addTeeth(b, from, to, count, size)
	for i = 0, count - 1 do
		local alpha = if count > 1 then i / (count - 1) else 0.5
		local position = from:Lerp(to, alpha)
		b:Block("Tooth", Vector3.new(size, size, 0.1), CFrame.new(position) * CFrame.Angles(0, 0, deg(45)), WHITE)
	end
end

local Details = {}

-- PRADO ----------------------------------------------------------------------

Details.TungTungSahur = function(b)
	addBat(b, Vector3.new(1.63, 1.74, -0.1), b.Secondary:Lerp(BLACK, 0.2))
end

Details.BrrBrrPatapim = function(b)
	-- Orelhas de macaco e nariz grande.
	b:Ball("Ear", 0.6, Vector3.new(-0.95, 3.75, -0.85), b.Accent)
	b:Ball("Ear", 0.6, Vector3.new(0.95, 3.75, -0.85), b.Accent)
	b:Paint("Nose", b.Accent:Lerp(BLACK, 0.3))
end

Details.TrippiTroppi = function(b)
	-- Cabeça de gato (cinza) com orelhas e bigodes; corpo de camarão com listras.
	b:Paint("Head", b.Secondary)
	b:Block("Ear", Vector3.new(0.55, 0.55, 0.2), CFrame.new(-0.6, 4.15, -1.2) * CFrame.Angles(0, 0, deg(45)), b.Secondary)
	b:Block("Ear", Vector3.new(0.55, 0.55, 0.2), CFrame.new(0.6, 4.15, -1.2) * CFrame.Angles(0, 0, deg(45)), b.Secondary)
	b:Block("Whisker", Vector3.new(0.9, 0.05, 0.05), CFrame.new(-0.75, 2.95, -1.95) * CFrame.Angles(0, 0, deg(12)), BLACK)
	b:Block("Whisker", Vector3.new(0.9, 0.05, 0.05), CFrame.new(0.75, 2.95, -1.95) * CFrame.Angles(0, 0, deg(-12)), BLACK)
	b:ZCylinder("Stripe", 2.26, 0.15, Vector3.new(0, 3.1, 0.3), b.Accent)
	b:ZCylinder("Stripe", 2.26, 0.15, Vector3.new(0, 3.1, 1.0), b.Accent)
end

Details.ChimpanziniBananini = function(b)
	-- Casca de banana aberta no topo e o macaquinho aparecendo na frente.
	b:Paint("TopRing", b.Accent)
	b:Paint("BottomRing", b.Accent)
	for i = 0, 3 do
		local angle = deg(45 + i * 90)
		local outward = Vector3.new(math.sin(angle), 0, -math.cos(angle))
		local position = Vector3.new(0, 5.2, 0) + outward * 0.85
		b:Block(
			"Peel",
			Vector3.new(0.9, 1.3, 0.15),
			CFrame.lookAt(position, position + outward) * CFrame.Angles(deg(-25), 0, 0),
			b.Primary
		)
	end
	b:Ball("MonkeyFace", 1.5, Vector3.new(0, 3.6, -0.4), b.Secondary)
end

Details.BonecaAmbalabu = function(b)
	-- Corpo de pneu (escuro, com calota), pernas humanas e cabeça de sapo.
	b:Paint("Body", b.Secondary)
	b:Paint("BodyFront", b.Secondary)
	b:Paint("BodyBack", b.Secondary)
	b:XCylinder("Hub", 1.1, 2.08, Vector3.new(0, 2.6, 0.1), METAL_GRAY, Enum.Material.Metal)
	b:Paint("Leg", b.Accent)
	b:Paint("Snout", b.Primary:Lerp(WHITE, 0.2))
	b:Mouth(Vector3.new(0, 3.4, -3.35), 0.7, 0.08)
end

Details.BallerinaCappuccina = function(b)
	-- Saia de bailarina e uma xícara de cappuccino no lugar da cabeça.
	local tights = b.Primary:Lerp(WHITE, 0.3)
	b:VCylinder("Tutu", 2.5, 0.3, Vector3.new(0, 2.2, 0), b.Primary:Lerp(WHITE, 0.35))
	b:Paint("Leg", tights)
	b:Paint("Shoe", b.Primary)
	b:Paint("Head", b.Accent)
	b:VCylinder("CupRim", 1.3, 0.25, Vector3.new(0, 4.95, 0), b.Accent)
	b:VCylinder("Coffee", 1.15, 0.12, Vector3.new(0, 5.1, 0), b.Secondary)
	b:Block("CupHandle", Vector3.new(0.15, 0.5, 0.35), Vector3.new(0.85, 4.45, 0), b.Accent)
end

Details.TralaleroTralala = function(b)
	-- O "risquinho" branco nos tênis.
	for _, x in ipairs({ -0.86, 0.86 }) do
		b:Block("Swoosh", Vector3.new(0.05, 0.12, 0.6), CFrame.new(x, 0.2, 0.15) * CFrame.Angles(deg(15), 0, 0), WHITE)
	end
end

Details.CappuccinoAssassino = function(b)
	-- Roupa de ninja preta, cabeça de xícara com café, faixa na testa e duas katanas nas costas.
	b:Paint("Body", b.Secondary)
	b:Paint("Arm", b.Secondary)
	b:Paint("Head", Color3.fromRGB(245, 240, 230))
	b:VCylinder("Coffee", 1.15, 0.12, Vector3.new(0, 5.02, 0), b.Primary)
	b:VCylinder("Headband", 1.56, 0.22, Vector3.new(0, 4.62, 0), b.Secondary)
	b:Block("Belt", Vector3.new(1.72, 0.25, 1.02), Vector3.new(0, 2.3, 0), b.Primary)
	for _, side in ipairs({ -1, 1 }) do
		local swordCFrame = CFrame.new(0, 3.3, 0.62) * CFrame.Angles(0, 0, deg(35 * side))
		b:Block("Katana", Vector3.new(0.12, 2.6, 0.25), swordCFrame, b.Accent, Enum.Material.Metal)
		b:Block("KatanaHandle", Vector3.new(0.16, 0.6, 0.28), swordCFrame * CFrame.new(0, 1.5, 0), BLACK)
	end
end

Details.BombardiroCrocodilo = function(b)
	-- Focinho de crocodilo com dentes e bombas debaixo das asas.
	b:Block("Snout", Vector3.new(1.1, 0.55, 1.5), Vector3.new(0, 2.65, -2.5), b.Primary)
	for _, x in ipairs({ -0.5, 0.5 }) do
		addTeeth(b, Vector3.new(x, 2.4, -1.95), Vector3.new(x, 2.4, -3.05), 3, 0.16)
	end
	for _, x in ipairs({ -1.6, 1.6 }) do
		b:VCylinder("BombHook", 0.08, 0.3, Vector3.new(x, 2.7, 0.3), BLACK)
		b:Ball("Bomb", 0.6, Vector3.new(x, 2.3, 0.3), b.Accent)
	end
end

-- INVERNO --------------------------------------------------------------------

Details.FrigoCamelo = function(b)
	-- Camelo cor de areia carregando uma geladeira nas costas.
	for _, name in ipairs({ "Body", "BodyFront", "BodyBack", "Head", "Leg", "Ear", "Tail" }) do
		b:Paint(name, b.Secondary)
	end
	b:Paint("Snout", b.Secondary:Lerp(WHITE, 0.25))
	b:Block("Fridge", Vector3.new(1.5, 1.8, 1.3), Vector3.new(0, 4.4, 0.4), b.Primary)
	b:Block("FridgeLine", Vector3.new(1.52, 0.06, 1.32), Vector3.new(0, 4.75, 0.4), b.Accent)
	b:Block("FridgeHandle", Vector3.new(0.12, 0.6, 0.12), Vector3.new(0.55, 4.3, -0.32), b.Accent)
end

Details.PinguinoCongelino = function(b)
	-- Barriga branca, bico laranja, pés laranja e nadadeiras escuras.
	b:Ball("BellyPatch", 2.6, Vector3.new(0, 1.8, -0.75), b.Secondary)
	b:Block("Beak", Vector3.new(0.5, 0.25, 0.5), Vector3.new(0, 2.65, -2.1), b.Accent)
	b:Paint("Foot", b.Accent)
	b:Paint("Arm", b.Primary)
	b:Paint("AntennaTip", b.Secondary)
end

Details.TaTaTaSahur = function(b)
	-- Primo congelado do Tung Tung: gorro de neve, pingentes de gelo e taco.
	b:VCylinder("SnowCap", 2.35, 0.3, Vector3.new(0, 4.9, 0), WHITE, Enum.Material.Snow)
	for i = 0, 5 do
		local angle = deg(i * 60 + 30)
		local position = Vector3.new(math.sin(angle) * 1.1, 4.3, -math.cos(angle) * 1.1)
		b:Block("Icicle", Vector3.new(0.15, 0.5, 0.15), position, b.Accent, Enum.Material.Ice)
	end
	addBat(b, Vector3.new(1.63, 1.74, -0.1), b.Secondary)
end

Details.GlorboGelatino = function(b)
	-- Crocodilo de gelatina: corpo translúcido, focinho com dentes e uma cereja no topo.
	for _, name in ipairs({ "Body", "Head", "BodyBack", "DorsalFin", "TailFin", "Fin" }) do
		for _, child in ipairs(b.Model:GetChildren()) do
			if child.Name == name and child:IsA("BasePart") then
				child.Transparency = 0.25
				child.Reflectance = 0.15
			end
		end
	end
	local snout = b:Block("Snout", Vector3.new(1.3, 0.6, 1.4), Vector3.new(0, 2.85, -2.3), b.Primary)
	snout.Transparency = 0.25
	for _, x in ipairs({ -0.55, 0.55 }) do
		addTeeth(b, Vector3.new(x, 2.55, -1.8), Vector3.new(x, 2.55, -2.9), 3, 0.15)
	end
	b:VCylinder("CherryStem", 0.08, 0.4, Vector3.new(0, 4.6, -0.4), Color3.fromRGB(70, 120, 50))
	b:Ball("Cherry", 0.55, Vector3.new(0, 4.35, -0.4), b.Accent)
end

Details.OrsettoGhiacciolo = function(b)
	-- Ursinho-picolé: orelhas, narizinho, cobertura escorrendo e o palito embaixo.
	b:Ball("Ear", 0.7, Vector3.new(-0.75, 4.95, 0.1), b.Primary)
	b:Ball("Ear", 0.7, Vector3.new(0.75, 4.95, 0.1), b.Primary)
	b:Ball("Nose", 0.25, Vector3.new(0, 3.45, -1.15), BLACK)
	for i = 0, 2 do
		local angle = deg(-40 + i * 40)
		b:Ball("Drip", 0.35, Vector3.new(math.sin(angle) * 1.1, 4.35, -math.cos(angle) * 1.1), b.Secondary)
	end
	b:Block("Stick", Vector3.new(0.5, 0.5, 0.25), Vector3.new(0, 0.25, 0), b.Accent, Enum.Material.Wood)
end

Details.BombombiniGusini = function(b)
	-- Ganso-caça: bico laranja e duas turbinas com fogo na saída.
	b:Block("Beak", Vector3.new(0.7, 0.3, 0.8), Vector3.new(0, 2.9, -2.3), b.Accent)
	for _, x in ipairs({ -1.5, 1.5 }) do
		b:ZCylinder("Engine", 0.6, 1.4, Vector3.new(x, 2.55, 0.35), b.Secondary, Enum.Material.Metal)
		b:Ball("Exhaust", 0.45, Vector3.new(x, 2.55, 1.1), b.Accent, Enum.Material.Neon)
	end
end

Details.TricTracBaraboom = function(b)
	-- Bombinha: faixa branca de dinamite, pavio e faísca acesa.
	b:Block("Label", Vector3.new(1.72, 0.3, 1.02), Vector3.new(0, 2.95, 0), b.Secondary)
	b:VCylinder("Fuse", 0.12, 0.6, Vector3.new(0, 5.25, 0), b.Secondary)
	local spark = b:Ball("Spark", 0.35, Vector3.new(0, 5.6, 0), b.Accent, Enum.Material.Neon)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "SparkParticles"
	emitter.Texture = SPARKLE_TEXTURE
	emitter.Color = ColorSequence.new(b.Accent)
	emitter.LightEmission = 1
	emitter.Rate = 12
	emitter.Lifetime = NumberRange.new(0.3, 0.6)
	emitter.Speed = NumberRange.new(2, 4)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.3, 0)
	emitter.Parent = spark
end

Details.TigrrulliniWatermellini = function(b)
	-- Melancia com listras de tigre, orelhas e boca vermelha.
	b:VCylinder("Stripe", 3.32, 0.25, Vector3.new(0, 1.05, 0), b.Secondary)
	b:VCylinder("Stripe", 3.32, 0.25, Vector3.new(0, 3.75, 0), b.Secondary)
	b:Block("Ear", Vector3.new(0.6, 0.6, 0.2), CFrame.new(-0.9, 4.35, -0.3) * CFrame.Angles(0, 0, deg(45)), b.Secondary)
	b:Block("Ear", Vector3.new(0.6, 0.6, 0.2), CFrame.new(0.9, 4.35, -0.3) * CFrame.Angles(0, 0, deg(45)), b.Secondary)
	b:Paint("Mouth", b.Accent)
end

Details.LaVacaSaturnoSaturnita = function(b)
	-- Vaca malhada com o anel de Saturno em volta e chifrinhos.
	for _, spot in ipairs({
		{ -1.0, 2.8, 0.3 },
		{ 1.0, 2.8, 0.3 },
		{ -0.98, 2.35, -0.7 },
		{ 0.98, 2.4, 1.2 },
	}) do
		b:Block("Spot", Vector3.new(0.12, 0.6, 0.7), Vector3.new(spot[1], spot[2], spot[3]), b.Secondary)
	end
	b:Block("Spot", Vector3.new(0.7, 0.1, 0.6), Vector3.new(0.2, 3.6, 0.8), b.Secondary)
	local ring = b:VCylinder("Ring", 4.4, 0.12, Vector3.new(0, 2.7, 0.1), b.Accent, nil, CFrame.Angles(0, 0, deg(12)))
	ring.Transparency = 0.15
	b:Block("Horn", Vector3.new(0.15, 0.45, 0.15), Vector3.new(-0.45, 4.8, -2.15), b.Accent)
	b:Block("Horn", Vector3.new(0.15, 0.45, 0.15), Vector3.new(0.45, 4.8, -2.15), b.Accent)
end

-- DESERTO --------------------------------------------------------------------

Details.LiriliLarila = function(b)
	-- Elefante-cacto: tromba, orelhas grandes e presas (as sandálias já vêm do arquétipo).
	b:Remove("Mouth")
	b:VCylinder("Trunk", 0.45, 1.3, Vector3.new(0, 3.1, -1.05), b.Secondary, nil, CFrame.Angles(deg(12), 0, 0))
	b:Block("Ear", Vector3.new(0.18, 1.1, 0.9), CFrame.new(-1.05, 3.85, -0.2) * CFrame.Angles(0, deg(20), 0), b.Secondary)
	b:Block("Ear", Vector3.new(0.18, 1.1, 0.9), CFrame.new(1.05, 3.85, -0.2) * CFrame.Angles(0, deg(-20), 0), b.Secondary)
	b:Block("Tusk", Vector3.new(0.1, 0.1, 0.4), Vector3.new(-0.3, 3.25, -1.05), WHITE)
	b:Block("Tusk", Vector3.new(0.1, 0.1, 0.4), Vector3.new(0.3, 3.25, -1.05), WHITE)
end

Details.CactusinoBandito = function(b)
	-- Cacto bandido: corpo verde, sombreiro e bandana vermelha.
	for _, name in ipairs({ "Body", "Arm", "Head", "Leg", "Hand" }) do
		b:Paint(name, b.Primary)
	end
	b:VCylinder("SombreroBrim", 2.6, 0.15, Vector3.new(0, 4.95, 0), b.Secondary)
	b:VCylinder("SombreroTop", 1.0, 0.7, Vector3.new(0, 5.3, 0), b.Secondary)
	b:VCylinder("SombreroBand", 1.04, 0.15, Vector3.new(0, 5.05, 0), b.Accent)
	b:Block("Bandana", Vector3.new(1.2, 0.35, 0.3), Vector3.new(0, 4.02, -0.58), b.Accent)
	for _, spikePosition in ipairs({ Vector3.new(-0.87, 3.3, -0.51), Vector3.new(0.87, 2.6, -0.51) }) do
		b:Block("Spike", Vector3.new(0.08, 0.08, 0.3), spikePosition, b.Primary:Lerp(WHITE, 0.6))
	end
end

Details.SahurDelDeserto = function(b)
	-- Tronco queimado de sol com seu tamborzinho e uma baqueta.
	b:VCylinder("Drum", 1.1, 0.9, Vector3.new(0, 1.9, -1.35), b.Accent)
	b:VCylinder("DrumBand", 1.15, 0.15, Vector3.new(0, 2.3, -1.35), b.Secondary)
	b:VCylinder("DrumBand", 1.15, 0.15, Vector3.new(0, 1.5, -1.35), b.Secondary)
	b:VCylinder("Drumstick", 0.12, 1.1, Vector3.new(1.45, 2.2, -0.5), b.Secondary, nil, CFrame.Angles(deg(-40), 0, 0))
end

Details.CamelloTostato = function(b)
	-- Camelo tostado: duas corcovas e marcas de grelha.
	b:Ball("Hump", 1.3, Vector3.new(0, 3.55, -0.3), b.Primary)
	b:Ball("Hump", 1.3, Vector3.new(0, 3.55, 0.9), b.Primary)
	for _, x in ipairs({ -1.0, 1.0 }) do
		b:Block("GrillMark", Vector3.new(0.1, 0.12, 1.6), Vector3.new(x, 2.9, 0.1), b.Accent)
		b:Block("GrillMark", Vector3.new(0.1, 0.12, 1.6), Vector3.new(x, 2.5, 0.1), b.Accent)
	end
	b:Paint("Snout", b.Secondary)
end

Details.Garamararam = function(b)
	-- Urubu gritão: bico curvo, boca aberta, gola de penas e topete.
	b:Block("Beak", Vector3.new(0.45, 0.4, 0.7), Vector3.new(0, 3.0, -2.3), b.Accent)
	b:Block("BeakTip", Vector3.new(0.45, 0.35, 0.25), CFrame.new(0, 2.8, -2.6) * CFrame.Angles(deg(-30), 0, 0), b.Accent)
	b:Mouth(Vector3.new(0, 2.6, -2.2), 0.5, 0.3)
	b:ZCylinder("Ruff", 2.0, 0.4, Vector3.new(0, 2.8, -0.55), b.Secondary)
	for i = -1, 1 do
		b:Block(
			"Tuft",
			Vector3.new(0.12, 0.5, 0.12),
			CFrame.new(i * 0.2, 3.8, -1.3) * CFrame.Angles(0, 0, deg(-i * 20)),
			b.Secondary
		)
	end
end

Details.BananitaDolfinita = function(b)
	-- Golfinho azul vestido de banana: rosto e focinho azuis, barriga branca, cabinho da banana.
	b:Paint("Head", b.Secondary)
	b:Paint("Belly", b.Accent)
	b:Paint("DorsalFin", b.Secondary)
	b:ZCylinder("Snout", 0.7, 0.9, Vector3.new(0, 2.85, -2.25), b.Secondary)
	b:VCylinder("Stem", 0.35, 0.6, Vector3.new(0, 4.3, 1.6), b.Primary:Lerp(BLACK, 0.5))
end

Details.BurbaloniLuliloli = function(b)
	-- Capivara morando dentro de um coco: corpo de coco com borda branca, capivara na frente.
	for _, name in ipairs({ "Head", "Snout", "Leg", "Ear", "Tail" }) do
		b:Paint(name, b.Secondary)
	end
	b:ZCylinder("CoconutRim", 2.1, 0.15, Vector3.new(0, 2.6, -1.2), b.Accent)
	for _, fiber in ipairs({ { -0.5, 3.55, 0.2 }, { 0.4, 3.58, 0.9 }, { 0.1, 3.6, -0.5 } }) do
		b:Block("Fiber", Vector3.new(0.4, 0.08, 0.1), Vector3.new(fiber[1], fiber[2], fiber[3]), b.Primary:Lerp(BLACK, 0.4))
	end
end

Details.GraipussiMedussi = function(b)
	-- Água-viva de uvas: cacho de uvas no topo, folhinha e tentáculos.
	b:Remove("Foot")
	b:Remove("Antenna")
	b:Remove("AntennaTip")
	for i = 0, 5 do
		local angle = deg(i * 60)
		local color = if i % 2 == 0 then b.Primary else b.Secondary
		b:Ball("Grape", 0.8, Vector3.new(math.sin(angle) * 0.7, 4.3, math.cos(angle) * 0.7), color)
	end
	b:Ball("Grape", 0.8, Vector3.new(0, 4.7, 0), b.Primary)
	b:Block("Leaf", Vector3.new(0.7, 0.1, 0.4), CFrame.new(0.25, 5.1, 0.2) * CFrame.Angles(0, deg(30), deg(15)), b.Accent)
	for i = 0, 5 do
		local angle = deg(i * 60 + 30)
		b:VCylinder("Tentacle", 0.2, 1.0, Vector3.new(math.sin(angle) * 1.4, 0.5, math.cos(angle) * 1.4), b.Secondary)
	end
end

Details.TralaleroFaraone = function(b)
	-- Tubarão faraó: coroa dourada e o lenço listrado (nemes) dos lados da cabeça.
	b:VCylinder("Crown", 1.1, 0.8, Vector3.new(0, 4.5, -0.9), b.Secondary, Enum.Material.Metal)
	b:Ball("CrownJewel", 0.35, Vector3.new(0, 5.0, -0.9), b.Accent, Enum.Material.Neon)
	for _, x in ipairs({ -1.12, 1.12 }) do
		b:Block("Nemes", Vector3.new(0.2, 1.3, 0.9), Vector3.new(x, 3.2, -1.0), b.Secondary)
		b:Block("NemesStripe", Vector3.new(0.22, 0.12, 0.92), Vector3.new(x, 3.5, -1.0), b.Accent)
		b:Block("NemesStripe", Vector3.new(0.22, 0.12, 0.92), Vector3.new(x, 2.9, -1.0), b.Accent)
	end
end

-------------------------------------------------------------------------------
-- Modelo provisório de um brainrot comum
-------------------------------------------------------------------------------

local function buildPlaceholder(def)
	local b = newBuilder(def, true)
	local archetype = Archetypes[def.Archetype]
	if not archetype then
		warn("[BrainrotFactory] Archetype desconhecido '" .. tostring(def.Archetype) .. "' em " .. tostring(def.Id) .. "; usando Blob.")
		archetype = Archetypes.Blob
	end
	archetype(b)

	local details = Details[def.Id]
	if details then
		local ok, err = pcall(details, b)
		if not ok then
			warn("[BrainrotFactory] Erro nos detalhes de " .. tostring(def.Id) .. ": " .. tostring(err))
		end
	end
	return b:Finish()
end

-------------------------------------------------------------------------------
-- Modelo provisório do Brainrot Supremo (tubarão real com coroa e manto)
-------------------------------------------------------------------------------

local function buildSupremePlaceholder(def)
	-- O Supremo não bloqueia tiros (CanQuery = false): quando ficar gigante ele cobre
	-- boa parte do mapa e não pode virar uma "parede" invisível para as balas.
	local b = newBuilder(def, false)
	local P, S, A = b.Primary, b.Secondary, b.Accent

	-- Pernas com meias brancas e tênis dourados.
	for _, x in ipairs({ -0.6, 0.6 }) do
		b:VCylinder("Leg", 0.5, 1.5, Vector3.new(x, 1.05, 0.4), P)
		b:VCylinder("Sock", 0.54, 0.35, Vector3.new(x, 0.55, 0.4), S)
		b:Block("Shoe", Vector3.new(0.7, 0.4, 1.1), Vector3.new(x, 0.2, 0.25), S)
		b:Block("Swoosh", Vector3.new(0.05, 0.14, 0.7), CFrame.new(x * 1.6, 0.22, 0.25) * CFrame.Angles(deg(15), 0, 0), A)
	end

	-- Corpo de tubarão (cápsula), barriga branca.
	b:ZCylinder("Body", 2.4, 2.6, Vector3.new(0, 2.9, 0.4), P)
	b:Ball("Head", 2.4, Vector3.new(0, 2.9, -0.9), P)
	b:Ball("BodyBack", 2.2, Vector3.new(0, 2.9, 1.7), P)
	b:Ball("Belly", 2.0, Vector3.new(0, 2.4, -0.75), S)

	-- Guelras dos dois lados.
	for _, x in ipairs({ -1.18, 1.18 }) do
		for i = -1, 1 do
			b:Block("Gill", Vector3.new(0.06, 0.7, 0.08), Vector3.new(x, 2.9, 0.1 + i * 0.25), P:Lerp(BLACK, 0.5))
		end
	end

	-- Boca com dentes, olhos bravos com sobrancelhas.
	b:Mouth(Vector3.new(0, 2.45, -2.05), 1.3, 0.35)
	addTeeth(b, Vector3.new(-0.5, 2.62, -2.12), Vector3.new(0.5, 2.62, -2.12), 5, 0.18)
	b:Eyes(Vector3.new(0, 3.45, -1.9), 1.1, 0.6)
	b:Block("Brow", Vector3.new(0.6, 0.12, 0.12), CFrame.new(-0.55, 3.85, -1.95) * CFrame.Angles(0, 0, deg(-15)), BLACK)
	b:Block("Brow", Vector3.new(0.6, 0.12, 0.12), CFrame.new(0.55, 3.85, -1.95) * CFrame.Angles(0, 0, deg(15)), BLACK)

	-- Barbatanas e cauda.
	b:Wedge("DorsalFin", Vector3.new(0.3, 1.4, 1.5), Vector3.new(0, 4.6, 0.6), P)
	b:Block("TailFin", Vector3.new(0.25, 1.5, 0.7), CFrame.new(0, 3.55, 3.1) * CFrame.Angles(deg(35), 0, 0), P)
	b:Block("TailFin", Vector3.new(0.25, 1.2, 0.6), CFrame.new(0, 2.35, 3.05) * CFrame.Angles(deg(-35), 0, 0), P)
	b:Block("Fin", Vector3.new(1.0, 0.18, 0.7), CFrame.new(-1.4, 2.6, -0.4) * CFrame.Angles(0, 0, deg(25)), P)
	b:Block("Fin", Vector3.new(1.0, 0.18, 0.7), CFrame.new(1.4, 2.6, -0.4) * CFrame.Angles(0, 0, deg(-25)), P)

	-- Gola de arminho (branca com pintinhas pretas).
	b:ZCylinder("Collar", 2.6, 0.35, Vector3.new(0, 2.9, -0.05), S)
	for i = 0, 5 do
		local angle = deg(i * 60)
		b:Ball("CollarDot", 0.14, Vector3.new(math.cos(angle) * 1.3, 2.9 + math.sin(angle) * 1.3, -0.05), BLACK)
	end

	-- Manto real caindo das costas, com barra dourada.
	local capeCFrame = CFrame.new(0, 2.3, 1.6) * CFrame.Angles(deg(-50), 0, 0)
	b:Block("Cape", Vector3.new(2.9, 3.6, 0.15), capeCFrame, ROYAL_RED, Enum.Material.Fabric)
	b:Block("CapeTrim", Vector3.new(2.95, 0.2, 0.18), capeCFrame * CFrame.new(0, -1.75, 0), GOLD, Enum.Material.Metal)

	-- Coroa com pontas e joias.
	b:VCylinder("Crown", 1.3, 0.5, Vector3.new(0, 4.3, -0.9), A, Enum.Material.Metal)
	for i = 0, 4 do
		local angle = deg(i * 72)
		local tip = Vector3.new(math.sin(angle) * 0.55, 4.72, -0.9 - math.cos(angle) * 0.55)
		b:Block("CrownSpike", Vector3.new(0.22, 0.4, 0.22), CFrame.new(tip) * CFrame.Angles(0, angle, deg(45)), A, Enum.Material.Metal)
		local jewelColor = if i % 2 == 0 then Color3.fromRGB(230, 40, 60) else Color3.fromRGB(60, 120, 255)
		b:Ball("Jewel", 0.16, tip + Vector3.new(0, 0.28, 0), jewelColor, Enum.Material.Neon)
	end
	b:Ball("Jewel", 0.28, Vector3.new(0, 4.3, -1.58), Color3.fromRGB(230, 40, 60), Enum.Material.Neon)

	-- Cetro na barbatana direita.
	b:VCylinder("Scepter", 0.15, 2.2, Vector3.new(1.8, 2.8, -0.65), A, Enum.Material.Metal)
	b:Ball("ScepterOrb", 0.4, Vector3.new(1.8, 3.95, -0.65), Color3.fromRGB(230, 40, 60), Enum.Material.Neon)
	b:VCylinder("ScepterRing", 0.3, 0.1, Vector3.new(1.8, 3.72, -0.65), A, Enum.Material.Metal)

	return b:Finish()
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- BrainrotFactory.Build(def) -> Model (escala 1, sem pai)
function BrainrotFactory.Build(def)
	assert(type(def) == "table", "[BrainrotFactory] Build precisa da definição do brainrot")

	local template = findCustomTemplate(def.ModelName)
	if template then
		local model = buildFromTemplate(template, tostring(def.Id or def.ModelName), TARGET_HEIGHT, true)
		if model then
			return model
		end
	end
	return buildPlaceholder(def)
end

-- BrainrotFactory.BuildSupreme(def) -> Model (escala 1 = ~5 studs, sem pai)
function BrainrotFactory.BuildSupreme(def)
	def = if type(def) == "table" then def else {}

	local template = findCustomTemplate(def.ModelName)
	if template then
		local model = buildFromTemplate(template, tostring(def.Id or def.ModelName), TARGET_HEIGHT, false)
		if model then
			return model
		end
	end
	return buildSupremePlaceholder(def)
end

-- BrainrotFactory.AttachBillboard(model, displayName, tierColor, enchantName?, enchantColor?) -> {Gui, Fill}
-- Cria o BillboardGui com (de cima para baixo): tag do encantamento, nome e barra de vida.
-- "Fill" é o Frame da barra: Size.X.Scale = fração de vida.
-- Também devolve NameLabel e EnchantLabel (útil para trocar a cor do arco-íris).
function BrainrotFactory.AttachBillboard(model, displayName, tierColor, enchantName, enchantColor)
	local body = getBody(model)
	assert(body, "[BrainrotFactory] AttachBillboard: modelo sem partes")

	-- Ponto de apoio: o attachment no topo da cabeça (sobe junto quando o modelo cresce).
	local anchor = model:FindFirstChild("BillboardAttachment", true)
	if not anchor then
		local minV, maxV = worldBounds(model, FX_PARTS)
		local top = if minV then Vector3.new((minV.X + maxV.X) / 2, maxV.Y, (minV.Z + maxV.Z) / 2) else body.Position
		anchor = attachmentAt(body, "BillboardAttachment", top)
	end

	-- Remove um billboard antigo, se houver.
	local old = body:FindFirstChild("Billboard")
	if old then
		old:Destroy()
	end

	local hasEnchant = type(enchantName) == "string" and enchantName ~= ""

	local gui = Instance.new("BillboardGui")
	gui.Name = "Billboard"
	gui.Adornee = anchor
	gui.AlwaysOnTop = false
	gui.MaxDistance = BILLBOARD_MAX_DISTANCE
	gui.LightInfluence = 0
	gui.StudsOffsetWorldSpace = BILLBOARD_OFFSET
	gui.Size = UDim2.fromOffset(BILLBOARD_WIDTH, if hasEnchant then 62 else 42)
	gui.ResetOnSpawn = false

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = gui

	-- Cria um texto com contorno preto (legível em qualquer fundo).
	local function makeLabel(name, text, color, height, maxSize, order)
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, 0, 0, height)
		label.Font = Enum.Font.FredokaOne
		label.Text = text
		label.TextColor3 = color
		label.TextScaled = true
		label.TextStrokeTransparency = 0.25
		label.TextStrokeColor3 = BLACK
		label.LayoutOrder = order
		local constraint = Instance.new("UITextSizeConstraint")
		constraint.MaxTextSize = maxSize
		constraint.MinTextSize = 8
		constraint.Parent = label
		label.Parent = gui
		return label
	end

	local enchantLabel = nil
	if hasEnchant then
		enchantLabel = makeLabel("Enchant", enchantName, enchantColor or WHITE, 16, 16, 1)
	end
	local nameLabel = makeLabel("Name", tostring(displayName or ""), tierColor or WHITE, 20, 18, 2)

	-- Barra de vida: fundo escuro + preenchimento.
	local barBack = Instance.new("Frame")
	barBack.Name = "HealthBar"
	barBack.BackgroundColor3 = BAR_BACK_COLOR
	barBack.BorderSizePixel = 0
	barBack.Size = UDim2.new(0.8, 0, 0, 8)
	barBack.LayoutOrder = 3
	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(0, 4)
	backCorner.Parent = barBack
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1
	stroke.Color = BLACK
	stroke.Parent = barBack
	barBack.Parent = gui

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = HEALTH_COLOR
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill
	fill.Parent = barBack

	gui.Parent = body

	return {
		Gui = gui,
		Fill = fill,
		NameLabel = nameLabel,
		EnchantLabel = enchantLabel,
	}
end

-- Estilo visual de cada encantamento (só aparência).
--   Tint        quanto misturar a cor do encantamento nas partes (0 = nada, 1 = tudo)
--   Texture     textura das partículas
--   Rate        partículas por segundo
--   Rise        partículas sobem (fogo)
--   Aura        esfera brilhante (material ForceField) em volta do brainrot
--   Crystals    cristais de gelo em cima do brainrot
--   Reflectance brilho metálico (dourado)
local ENCHANT_STYLES = {
	Golden = { Tint = 0.55, Texture = SPARKLE_TEXTURE, Rate = 8, Reflectance = 0.25 },
	Ice = { Tint = 0.3, Texture = SPARKLE_TEXTURE, Rate = 6, Crystals = true },
	Fire = { Tint = 0.15, Texture = FIRE_TEXTURE, Rate = 14, Rise = true },
	Rainbow = { Tint = 0, Texture = SPARKLE_TEXTURE, Rate = 10, Aura = true },
	Radioactive = { Tint = 0.3, Texture = SPARKLE_TEXTURE, Rate = 10 },
	Galactic = { Tint = 0.45, Texture = SPARKLE_TEXTURE, Rate = 18, Aura = true, Stars = true },
}
local DEFAULT_ENCHANT_STYLE = { Tint = 0.2, Texture = SPARKLE_TEXTURE, Rate = 8 }

-- BrainrotFactory.ApplyEnchantVisual(model, enchantDef) -> {Particles, Light, Aura?}
-- Partículas + luz na cor do encantamento (sem Highlight, que tem limite de 31 por cliente).
-- Chame ANTES de escalar/posicionar ou depois, tanto faz: tudo é medido no tamanho atual.
function BrainrotFactory.ApplyEnchantVisual(model, enchantDef)
	if typeof(model) ~= "Instance" or type(enchantDef) ~= "table" then
		return nil
	end
	local style = ENCHANT_STYLES[enchantDef.Id] or DEFAULT_ENCHANT_STYLE
	local color = if typeof(enchantDef.Color) == "Color3" then enchantDef.Color else WHITE
	local scale = model:GetScale()

	-- Limpa um visual anterior (caso a função seja chamada duas vezes).
	for _, name in ipairs({ "EnchantAura", "IceCrystal" }) do
		for _, child in ipairs(model:GetChildren()) do
			if child.Name == name then
				child:Destroy()
			end
		end
	end

	local fx = model:FindFirstChild("FxVolume") or getBody(model)
	for _, name in ipairs({ "EnchantParticles", "EnchantLight" }) do
		local old = fx:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end

	-- 1. "Tinta": mistura a cor do encantamento nas partes (menos olhos e boca).
	if style.Tint > 0 or style.Reflectance then
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") and not NO_TINT[descendant.Name] and descendant.Transparency < 1 then
				if style.Tint > 0 then
					descendant.Color = descendant.Color:Lerp(color, style.Tint)
				end
				if style.Reflectance then
					descendant.Reflectance = style.Reflectance
				end
			end
		end
	end

	-- 2. Partículas saindo do corpo inteiro.
	local particles = Instance.new("ParticleEmitter")
	particles.Name = "EnchantParticles"
	particles.Texture = style.Texture
	particles.LightEmission = 1
	particles.LightInfluence = 0
	particles.Rate = style.Rate
	particles.Lifetime = NumberRange.new(0.8, 1.5)
	particles.SpreadAngle = Vector2.new(180, 180)
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	if style.Rise then
		-- Fogo: labaredas maiores subindo.
		particles.EmissionDirection = Enum.NormalId.Top
		particles.SpreadAngle = Vector2.new(15, 15)
		particles.Speed = NumberRange.new(2 * scale, 4 * scale)
		particles.Acceleration = Vector3.new(0, 3 * scale, 0)
		particles.Lifetime = NumberRange.new(0.5, 0.9)
		particles.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.0 * scale),
			NumberSequenceKeypoint.new(1, 0.2 * scale),
		})
		particles.Color = ColorSequence.new(color, Color3.fromRGB(255, 60, 20))
	else
		particles.Speed = NumberRange.new(0.5 * scale, 2 * scale)
		particles.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.45 * scale),
			NumberSequenceKeypoint.new(1, 0),
		})
		if style.Stars then
			-- Galáctico: estrelinhas brancas e roxas.
			particles.Color = ColorSequence.new(WHITE, color)
		else
			particles.Color = ColorSequence.new(color)
		end
	end
	particles.Parent = fx

	-- 3. Luz na cor do encantamento.
	local light = Instance.new("PointLight")
	light.Name = "EnchantLight"
	light.Color = color
	light.Brightness = 1.5
	light.Range = math.clamp(10 * scale, 4, 60)
	light.Shadows = false
	light.Parent = fx

	-- 4. Aura (Arco-íris e Galáctico): esfera ForceField em volta do brainrot.
	local aura = nil
	local minV, maxV = worldBounds(model, FX_PARTS)
	if style.Aura and minV then
		local size = maxV - minV
		local diameter = math.max(size.X, size.Y, size.Z) * 1.02
		aura = Instance.new("Part")
		aura.Name = "EnchantAura"
		aura.Shape = Enum.PartType.Ball
		aura.Size = Vector3.one * diameter
		aura.CFrame = CFrame.new((minV + maxV) / 2)
		aura.Material = Enum.Material.ForceField
		aura.Color = color
		aura.CastShadow = false
		configurePart(aura, false) -- não atrapalha os tiros
		aura.Parent = model
	end

	-- 5. Gelo: cristais azuis no topo e nos ombros.
	if style.Crystals and minV then
		local size = maxV - minV
		local top = Vector3.new((minV.X + maxV.X) / 2, maxV.Y, (minV.Z + maxV.Z) / 2)
		local crystalSize = math.max(size.Y * 0.14, 0.3)
		local offsets = {
			Vector3.new(0, 0, 0),
			Vector3.new(-0.3, -0.15, 0.1),
			Vector3.new(0.3, -0.12, -0.1),
			Vector3.new(-0.45, -0.35, -0.15),
			Vector3.new(0.45, -0.38, 0.15),
		}
		for index, offset in ipairs(offsets) do
			local position = top + Vector3.new(offset.X * size.X, offset.Y * size.Y, offset.Z * size.Z)
			local crystal = Instance.new("Part")
			crystal.Name = "IceCrystal"
			crystal.Size = Vector3.new(crystalSize * 0.45, crystalSize * (if index == 1 then 1.4 else 1), crystalSize * 0.45)
			crystal.CFrame = CFrame.new(position) * CFrame.Angles(deg(15 * index), deg(40 * index), deg(-12 * index))
			crystal.Color = ICE_COLOR
			crystal.Material = Enum.Material.Ice
			crystal.Transparency = 0.15
			crystal.CastShadow = false
			configurePart(crystal, true)
			crystal.Parent = model
		end
	end

	return {
		Particles = particles,
		Light = light,
		Aura = aura,
	}
end

-- BrainrotFactory.AddIceBlock(model) -> Part
-- Bloco de gelo translúcido em volta do brainrot (os congelados do Inverno).
-- Fica dentro do modelo (cresce e anda junto) e pode ser atingido pelos tiros.
function BrainrotFactory.AddIceBlock(model)
	assert(typeof(model) == "Instance", "[BrainrotFactory] AddIceBlock precisa de um modelo")

	local old = model:FindFirstChild("IceBlock")
	if old then
		old:Destroy()
	end

	local minV, maxV = worldBounds(model, FX_PARTS)
	if not minV then
		local pivot = model:GetPivot()
		minV = pivot.Position - Vector3.new(1.5, 0, 1.5)
		maxV = pivot.Position + Vector3.new(1.5, TARGET_HEIGHT, 1.5)
	end
	local padding = ICE_PADDING * model:GetScale()

	local block = Instance.new("Part")
	block.Name = "IceBlock"
	block.Size = (maxV - minV) + Vector3.one * padding * 2
	-- Centro da caixa, com a mesma rotação (em Y) do modelo.
	local rotation = model:GetPivot().Rotation
	block.CFrame = CFrame.new((minV + maxV) / 2) * rotation
	block.Color = ICE_COLOR
	block.Material = Enum.Material.Ice
	block.Transparency = 0.35
	block.Reflectance = 0.1
	block.CastShadow = false
	configurePart(block, true)
	block.Parent = model
	return block
end

return BrainrotFactory
