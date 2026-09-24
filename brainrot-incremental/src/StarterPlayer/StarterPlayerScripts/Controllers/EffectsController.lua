-- EffectsController (só na partida): todos os efeitos visuais locais.
--
-- Escuta os eventos do servidor:
--   Effect(kind, data)      "Death", "Explosion", "Spawn", "IceBreak", "Ingredient", "Purchase", "Portal"
--   RemoteShot(...)         tiros dos outros jogadores (tracers)
--   TurretShots(shots)      tiros das torretas (tracers)
--   CoinPopup(amount, pos)  número "+1,2K" subindo quando você pega moedas
--
-- Tudo fica na pasta local workspace.ClientEffects (criada por este script; o servidor
-- nem sabe que ela existe). Para não pesar, TODAS as peças são recicladas (pool) e há um
-- limite de efeitos ao mesmo tempo: quando passa do limite, o mais antigo some na hora.
--
-- API pública:
--   EffectsController.Tracer(from, to, color, width?, speed?, impact?)   bala desenhada voando
--   EffectsController.DamageNumber(position, amount, crit)             número de dano flutuante
--   EffectsController.Burst(position, color, size)                     explosão de partículas
--   EffectsController.Spark(position, color?)                          faísca pequena (impacto)
--   EffectsController.CoinPopup(amount, position)                      "+1,2K" dourado subindo
--   EffectsController.Play(kind, data)                                 roda um efeito do tipo "Effect"

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")
local Enchants = require(Config:WaitForChild("Enchants"))
local Net = require(Util:WaitForChild("Net"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))
local Trove = require(Util:WaitForChild("Trove"))

local Controllers = script.Parent
local UIKit = require(Controllers.Parent:WaitForChild("UI"):WaitForChild("UIKit"))

local EffectsController = {}

-------------------------------------------------------------------------------
-- Constantes técnicas (limites de desempenho e aparência)
-------------------------------------------------------------------------------
local FOLDER_NAME = "ClientEffects"
local HIDDEN_CFRAME = CFrame.new(0, -10000, 0) -- onde as peças "guardadas" ficam escondidas

-- Limites de efeitos ao mesmo tempo.
local MAX_TRACERS = 140
local MAX_DEBRIS = 180
local MAX_SHAPES = 32
local MAX_DAMAGE_NUMBERS = 40
local MAX_COIN_POPUPS = 14
local PART_POOL_LIMIT = 400 -- peças guardadas para reciclar
local SPARKLE_EMITTERS = 16
local SMOKE_EMITTERS = 8
local MAX_ENDPOINTS_PER_SHOT = 20 -- RemoteShot: no máximo 20 tracers por tiro
local MAX_TURRET_SHOTS_PER_BATCH = 40

-- Distâncias (studs) a partir da câmera.
local MAX_EFFECT_DISTANCE = 500 -- mais longe que isso, nem desenha
local SOUND_DISTANCE = 160 -- sons só de coisas perto

-- Balas desenhadas.
local DEFAULT_TRACER_SPEED = 650
local DEFAULT_TRACER_WIDTH = 0.12
local TRACER_MAX_LENGTH = 10 -- comprimento do "risco" da bala
local TRACER_FADE_TIME = 0.08

-- Pedaços que voam (física simples feita por nós).
local DEBRIS_GRAVITY = Vector3.new(0, -70, 0)
local FLOOR_RAY_LENGTH = 80

-- Textos flutuantes.
local TEXT_POP_TIME = 0.12
local COIN_MERGE_WINDOW = 0.35 -- segundos: popups de moeda seguidos se juntam num só
local COIN_MERGE_DISTANCE = 14

-- Cores fixas dos efeitos.
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local EXPLOSION_ORANGE = Color3.fromRGB(255, 140, 40)
local EXPLOSION_YELLOW = Color3.fromRGB(255, 225, 90)
local SMOKE_GREY = Color3.fromRGB(90, 85, 80)
local DUST_BROWN = Color3.fromRGB(160, 125, 85)
local GRASS_GREEN = Color3.fromRGB(110, 190, 80)
local ICE_BLUE = Color3.fromRGB(170, 225, 255)
local PORTAL_PURPLE = Color3.fromRGB(170, 80, 255)
local PORTAL_PINK = Color3.fromRGB(255, 110, 220)
local TURRET_TRACER_COLOR = Color3.fromRGB(120, 235, 255)
local COIN_GOLD = Color3.fromRGB(255, 214, 60)
local DAMAGE_COLOR = Color3.fromRGB(255, 248, 215)
local CRIT_COLOR = Color3.fromRGB(255, 85, 60)
local CONFETTI_COLORS = {
	Color3.fromRGB(255, 80, 150),
	Color3.fromRGB(255, 210, 60),
	Color3.fromRGB(90, 220, 120),
	Color3.fromRGB(80, 170, 255),
	Color3.fromRGB(190, 110, 255),
	Color3.fromRGB(255, 140, 60),
}

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------
local player = Players.LocalPlayer
local rng = Random.new()
local folder = nil
local mainTrove = Trove.new()
local started = false

local partPool = {} -- peças livres para reciclar
local tracers = {} -- balas voando
local debris = {} -- pedaços com física simples
local shapes = {} -- esferas/discos/orbes que crescem e somem
local texts = {} -- números flutuantes (dano e moedas)
local anchorPool = {} -- âncoras com BillboardGui livres
local sparkleEmitters = {}
local smokeEmitters = {}
local soundLastPlayed = {} -- [chave do som] = último horário
local floorParams = RaycastParams.new()
floorParams.FilterType = Enum.RaycastFilterType.Exclude
floorParams.IgnoreWater = false

-------------------------------------------------------------------------------
-- Acesso preguiçoso a outros controllers (regra anti-require-circular)
-------------------------------------------------------------------------------
local loadedControllers = {}
local function Ctrl(name)
	local cached = loadedControllers[name]
	if cached ~= nil then
		return cached or nil
	end
	local module = Controllers:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		loadedControllers[name] = result
		return result
	end
	loadedControllers[name] = false
	return nil
end

-------------------------------------------------------------------------------
-- Utilidades
-------------------------------------------------------------------------------
local function getFolder()
	if folder and folder.Parent == workspace then
		return folder
	end
	folder = workspace:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = workspace
	end
	return folder
end

local function cameraPosition()
	local camera = workspace.CurrentCamera
	return if camera then camera.CFrame.Position else Vector3.zero
end

-- true se a posição é válida e está perto o bastante para valer a pena desenhar.
local function isNear(position, maxDistance)
	if typeof(position) ~= "Vector3" or position ~= position then
		return false
	end
	return (position - cameraPosition()).Magnitude <= (maxDistance or MAX_EFFECT_DISTANCE)
end

local function asColor(value, default)
	return if typeof(value) == "Color3" then value else default
end

local function asNumber(value, default)
	local number = tonumber(value)
	if number == nil or number ~= number then
		return default
	end
	return number
end

-- "Size" dos efeitos "Death", "Spawn" e "IceBreak" = ALTURA em studs (o servidor manda a
-- altura do modelo ou o maior lado do bloco de gelo; NÃO é a escala do modelo).
-- Antes tratávamos o valor como escala (× 2,5) e tudo ficava ~5× grande demais.
-- O raio é metade da altura (brainrot normal de 5 studs -> raio 2,5), com limites
-- para nada ficar absurdo nem sumir.
local function sizeToRadius(size)
	return math.clamp(asNumber(size, 5) * 0.5, 0.6, 30)
end

-- Direção aleatória, puxada para cima (bom para coisas "explodindo" do chão).
local function randomUpwardDirection(minY)
	local angle = rng:NextNumber(0, math.pi * 2)
	local y = rng:NextNumber(minY or -0.2, 1)
	local flat = math.sqrt(math.max(0, 1 - y * y))
	return Vector3.new(flat * math.cos(angle), y, flat * math.sin(angle))
end

-- Toca um som de Config.Game.Sounds se estiver perto e não tocou há pouco.
local function playSound(key, position, minInterval)
	if position and not isNear(position, SOUND_DISTANCE) then
		return
	end
	local t = os.clock()
	if soundLastPlayed[key] and t - soundLastPlayed[key] < (minInterval or 0.05) then
		return
	end
	soundLastPlayed[key] = t
	pcall(UIKit.PlaySound, key)
end

-- Tremida de câmera proporcional à distância.
local function shakeByDistance(position, strength, radius)
	local distance = (position - cameraPosition()).Magnitude
	if distance > radius then
		return
	end
	local camera = Ctrl("CameraController")
	if camera and type(camera.Shake) == "function" then
		pcall(camera.Shake, strength * (1 - distance / radius))
	end
end

-- Acha a altura do chão embaixo de uma posição (para pedaços quicarem e discos ficarem no chão).
local function findFloorY(position)
	local exclude = { getFolder() }
	for _, name in ipairs({ "Brainrots", "Coins", "Turrets" }) do
		local child = workspace:FindFirstChild(name)
		if child then
			table.insert(exclude, child)
		end
	end
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Character then
			table.insert(exclude, other.Character)
		end
	end
	local camera = workspace.CurrentCamera
	if camera then
		table.insert(exclude, camera)
	end
	floorParams.FilterDescendantsInstances = exclude
	local result = workspace:Raycast(position + Vector3.new(0, 3, 0), Vector3.new(0, -FLOOR_RAY_LENGTH, 0), floorParams)
	return if result then result.Position.Y else position.Y - 3
end

-------------------------------------------------------------------------------
-- Pool de peças (reciclagem)
-------------------------------------------------------------------------------
local function makePart()
	local part = Instance.new("Part")
	part.Name = "Fx"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Transparency = 1
	part.CFrame = HIDDEN_CFRAME
	part.Parent = getFolder()
	return part
end

-- Pega uma peça livre (ou cria) já configurada.
local function acquirePart(shape, material, color, size, transparency)
	local part = table.remove(partPool)
	while part and part.Parent == nil do
		part = table.remove(partPool)
	end
	part = part or makePart()
	part.Shape = shape or Enum.PartType.Block
	part.Material = material or Enum.Material.Neon
	part.Color = color or WHITE
	part.Size = size or Vector3.one
	part.Transparency = transparency or 0
	return part
end

-- Devolve a peça para o pool (escondida).
local function releasePart(part)
	if not part or part.Parent == nil then
		return
	end
	part.Transparency = 1
	part.CFrame = HIDDEN_CFRAME
	if #partPool < PART_POOL_LIMIT then
		table.insert(partPool, part)
	else
		part:Destroy()
	end
end

-------------------------------------------------------------------------------
-- Partículas (emissores reciclados)
-------------------------------------------------------------------------------
local function makeEmitter(kind)
	local holder = makePart()
	holder.Name = "FxEmitter"
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0 -- só solta partículas quando chamamos :Emit()
	emitter.Enabled = true
	emitter.LockedToPart = false
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.LightInfluence = 0
	if kind == "Smoke" then
		emitter.Texture = SMOKE_TEXTURE
		emitter.LightEmission = 0
		emitter.Lifetime = NumberRange.new(0.6, 1.2)
		emitter.Drag = 3
		emitter.Acceleration = Vector3.new(0, 4, 0)
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
	else
		emitter.Texture = SPARKLE_TEXTURE
		emitter.LightEmission = 0.8
		emitter.Lifetime = NumberRange.new(0.35, 0.75)
		emitter.Drag = 5
		emitter.Acceleration = Vector3.new(0, -14, 0)
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.7, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
	end
	emitter.Parent = holder
	return { Part = holder, Emitter = emitter, LastUsed = 0 }
end

-- Escolhe o emissor usado há mais tempo (trocar a cor de um emissor muda as
-- partículas vivas dele, então usamos o que já "terminou" há mais tempo).
local function pickEmitter(pool, kind, maxCount)
	local best = nil
	for _, entry in ipairs(pool) do
		if entry.Part.Parent and (best == nil or entry.LastUsed < best.LastUsed) then
			best = entry
		end
	end
	if (best == nil or os.clock() - best.LastUsed < 1.3) and #pool < maxCount then
		best = makeEmitter(kind)
		table.insert(pool, best)
	end
	return best
end

local function emitSparkles(position, color, size, count)
	if not isNear(position) then
		return
	end
	local entry = pickEmitter(sparkleEmitters, "Sparkle", SPARKLE_EMITTERS)
	if not entry then
		return
	end
	entry.LastUsed = os.clock()
	local particleSize = math.clamp(0.35 + size * 0.22, 0.3, 3)
	local emitter = entry.Emitter
	entry.Part.CFrame = CFrame.new(position)
	emitter.Color = ColorSequence.new(color, color:Lerp(WHITE, 0.5))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, particleSize),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Speed = NumberRange.new(4 + size * 4, 10 + size * 10)
	emitter:Emit(count)
end

local function emitSmoke(position, color, size, count)
	if not isNear(position) then
		return
	end
	local entry = pickEmitter(smokeEmitters, "Smoke", SMOKE_EMITTERS)
	if not entry then
		return
	end
	entry.LastUsed = os.clock()
	local particleSize = math.clamp(0.8 + size * 0.5, 0.8, 8)
	local emitter = entry.Emitter
	entry.Part.CFrame = CFrame.new(position)
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, particleSize * 0.6),
		NumberSequenceKeypoint.new(1, particleSize * 1.6),
	})
	emitter.Speed = NumberRange.new(2 + size, 5 + size * 3)
	emitter:Emit(count)
end

-------------------------------------------------------------------------------
-- Tracers (balas voando)
-------------------------------------------------------------------------------
local function finishTracer(tracer)
	releasePart(tracer.Part)
end

-- Desenha uma bala saindo de "from" e indo até "to".
function EffectsController.Tracer(from, to, color, width, speed, impact)
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" then
		return
	end
	if not isNear(from) and not isNear(to) then
		return
	end
	local offset = to - from
	local distance = offset.Magnitude
	if distance < 0.05 or distance ~= distance then
		return
	end

	-- Limite: recicla a bala mais antiga.
	if #tracers >= MAX_TRACERS then
		finishTracer(table.remove(tracers, 1))
	end

	width = math.clamp(asNumber(width, DEFAULT_TRACER_WIDTH), 0.03, 3)
	speed = math.max(asNumber(speed, DEFAULT_TRACER_SPEED), 20)
	color = asColor(color, EXPLOSION_YELLOW)

	local direction = offset / distance
	local isBall = width >= 0.4 -- balas grossas (ex.: bola de gelato) viram esferas
	local length = if isBall then width else math.min(TRACER_MAX_LENGTH, distance, math.max(2, speed * 0.015))
	local size = if isBall then Vector3.new(width, width, width) else Vector3.new(width, width, length)
	local part = acquirePart(
		if isBall then Enum.PartType.Ball else Enum.PartType.Block,
		Enum.Material.Neon,
		color,
		size,
		0.05
	)

	-- O centro do risco vai de "from + L/2" até "to - L/2".
	local startCenter = from + direction * (length / 2)
	local endCenter = to - direction * (length / 2)
	local travel = math.max(0, distance - length)
	local rotation = CFrame.lookAt(Vector3.zero, direction)

	table.insert(tracers, {
		Part = part,
		Start = startCenter,
		Finish = endCenter,
		Rotation = rotation,
		Duration = math.max(travel / speed, 0.03),
		Elapsed = 0,
		Arrived = false,
		FadeLeft = TRACER_FADE_TIME,
		Impact = impact == true,
		Color = color,
		To = to,
	})
	part.CFrame = CFrame.new(startCenter) * rotation
end

local function updateTracers(dt, moveParts, moveCFrames)
	local keep = 0
	for index = 1, #tracers do
		local tracer = tracers[index]
		local alive = true
		tracer.Elapsed += dt
		if not tracer.Arrived then
			local alpha = math.min(1, tracer.Elapsed / tracer.Duration)
			local center = tracer.Start:Lerp(tracer.Finish, alpha)
			table.insert(moveParts, tracer.Part)
			table.insert(moveCFrames, CFrame.new(center) * tracer.Rotation)
			if alpha >= 1 then
				tracer.Arrived = true
				if tracer.Impact then
					EffectsController.Spark(tracer.To, tracer.Color)
				end
			end
		else
			-- Chegou: some rapidinho.
			tracer.FadeLeft -= dt
			if tracer.FadeLeft <= 0 then
				alive = false
			else
				tracer.Part.Transparency = 1 - (tracer.FadeLeft / TRACER_FADE_TIME) * 0.95
			end
		end

		if alive then
			keep += 1
			tracers[keep] = tracer
		else
			finishTracer(tracer)
		end
	end
	for index = #tracers, keep + 1, -1 do
		tracers[index] = nil
	end
end

-------------------------------------------------------------------------------
-- Pedaços com física simples (sem usar a física do Roblox, que seria mais pesada)
-------------------------------------------------------------------------------
-- options: Count, Colors, Size, Speed, Upward, GravityScale, Drag, Life, Material,
--          Transparency, Flat (confete achatado), MinY (direção mínima para cima)
local function spawnDebris(position, options)
	if not isNear(position) then
		return
	end
	local count = options.Count or 8
	local colors = options.Colors or { WHITE }
	local baseSize = options.Size or 0.5
	local speed = options.Speed or 20
	local floorY = findFloorY(position)

	for _ = 1, count do
		if #debris >= MAX_DEBRIS then
			local oldest = table.remove(debris, 1)
			releasePart(oldest.Part)
		end
		local pieceSize = baseSize * rng:NextNumber(0.6, 1.3)
		local height = if options.Flat then pieceSize * 0.12 else pieceSize * rng:NextNumber(0.6, 1.1)
		local size = Vector3.new(pieceSize, height, if options.Flat then pieceSize * 0.6 else pieceSize)
		local part = acquirePart(
			Enum.PartType.Block,
			options.Material or Enum.Material.SmoothPlastic,
			colors[rng:NextInteger(1, #colors)],
			size,
			options.Transparency or 0
		)
		local velocity = randomUpwardDirection(options.MinY) * speed * rng:NextNumber(0.5, 1)
			+ Vector3.new(0, options.Upward or 8, 0)
		local life = (options.Life or 1.4) * rng:NextNumber(0.8, 1.2)
		table.insert(debris, {
			Part = part,
			Position = position + randomUpwardDirection(-1) * (baseSize * 0.5),
			Velocity = velocity,
			Rotation = CFrame.Angles(
				rng:NextNumber(0, math.pi * 2),
				rng:NextNumber(0, math.pi * 2),
				rng:NextNumber(0, math.pi * 2)
			),
			Spin = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12)),
			Life = life,
			MaxLife = life,
			FloorY = floorY + height / 2,
			GravityScale = options.GravityScale or 1,
			Drag = options.Drag or 0.4,
			BaseTransparency = options.Transparency or 0,
		})
	end
end

local function updateDebris(dt, moveParts, moveCFrames)
	local keep = 0
	for index = 1, #debris do
		local piece = debris[index]
		piece.Life -= dt
		if piece.Life <= 0 then
			releasePart(piece.Part)
		else
			-- Gravidade + resistência do ar.
			local velocity = piece.Velocity + DEBRIS_GRAVITY * piece.GravityScale * dt
			velocity *= math.max(0, 1 - piece.Drag * dt)
			local position = piece.Position + velocity * dt
			-- Quica no chão perdendo força.
			if position.Y < piece.FloorY then
				position = Vector3.new(position.X, piece.FloorY, position.Z)
				velocity = Vector3.new(velocity.X * 0.55, math.abs(velocity.Y) * 0.3, velocity.Z * 0.55)
				piece.Spin *= 0.5
			end
			piece.Velocity = velocity
			piece.Position = position
			local spin = piece.Spin * dt
			piece.Rotation = piece.Rotation * CFrame.Angles(spin.X, spin.Y, spin.Z)

			-- Nos últimos 30% da vida vai ficando transparente.
			local fadeStart = piece.MaxLife * 0.3
			if piece.Life < fadeStart then
				local alpha = 1 - piece.Life / fadeStart
				piece.Part.Transparency = piece.BaseTransparency + (1 - piece.BaseTransparency) * alpha
			end

			table.insert(moveParts, piece.Part)
			table.insert(moveCFrames, CFrame.new(position) * piece.Rotation)
			keep += 1
			debris[keep] = piece
		end
	end
	for index = #debris, keep + 1, -1 do
		debris[index] = nil
	end
end

-------------------------------------------------------------------------------
-- Formas que crescem e somem (esferas de explosão, anéis no chão, orbes)
-------------------------------------------------------------------------------
-- kind: "Sphere" (esfera crescendo), "Disc" (anel/disco no chão), "Orb" (bolinha que sobe)
local function addShape(kind, position, color, startSize, endSize, duration, startTransparency, extra)
	if not isNear(position) then
		return
	end
	if #shapes >= MAX_SHAPES then
		local oldest = table.remove(shapes, 1)
		releasePart(oldest.Part)
	end
	local shapeType = if kind == "Disc" then Enum.PartType.Cylinder else Enum.PartType.Ball
	local part = acquirePart(shapeType, Enum.Material.Neon, color, Vector3.one * startSize, startTransparency or 0.2)
	local shape = {
		Kind = kind,
		Part = part,
		Position = position,
		StartSize = startSize,
		EndSize = endSize,
		Duration = math.max(duration, 0.05),
		Elapsed = 0,
		StartTransparency = startTransparency or 0.2,
		Color = color,
		Rise = extra and extra.Rise or 0,
		BurstAtEnd = extra and extra.BurstAtEnd or false,
	}
	table.insert(shapes, shape)
end

local function updateShapes(dt)
	local keep = 0
	for index = 1, #shapes do
		local shape = shapes[index]
		shape.Elapsed += dt
		local alpha = math.min(1, shape.Elapsed / shape.Duration)
		local part = shape.Part
		if alpha >= 1 then
			if shape.BurstAtEnd then
				local position = shape.Position + Vector3.new(0, shape.Rise, 0)
				emitSparkles(position, shape.Color, 1.2, 14)
			end
			releasePart(part)
		else
			-- "Ease out": começa rápido e desacelera.
			local eased = 1 - (1 - alpha) ^ 3
			if shape.Kind == "Disc" then
				local diameter = shape.StartSize + (shape.EndSize - shape.StartSize) * eased
				part.Size = Vector3.new(0.25, diameter, diameter)
				-- O cilindro do Roblox deita no eixo X: giramos 90° para ele ficar "no chão".
				part.CFrame = CFrame.new(shape.Position) * CFrame.Angles(0, 0, math.pi / 2)
				part.Transparency = shape.StartTransparency + (1 - shape.StartTransparency) * alpha
			elseif shape.Kind == "Orb" then
				local pulse = 1 + math.sin(shape.Elapsed * 14) * 0.12
				part.Size = Vector3.one * shape.StartSize * pulse
				part.CFrame = CFrame.new(shape.Position + Vector3.new(0, shape.Rise * eased, 0))
				part.Transparency = if alpha > 0.8 then (alpha - 0.8) / 0.2 else shape.StartTransparency
			else
				local diameter = shape.StartSize + (shape.EndSize - shape.StartSize) * eased
				part.Size = Vector3.one * diameter
				part.CFrame = CFrame.new(shape.Position)
				part.Transparency = shape.StartTransparency + (1 - shape.StartTransparency) * alpha
			end
			keep += 1
			shapes[keep] = shape
		end
	end
	for index = #shapes, keep + 1, -1 do
		shapes[index] = nil
	end
end

-------------------------------------------------------------------------------
-- Textos flutuantes (BillboardGui em peças ancoradas recicladas)
-------------------------------------------------------------------------------
local function makeAnchor()
	local anchor = makePart()
	anchor.Name = "FxText"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Transparency = 1

	local gui = Instance.new("BillboardGui")
	gui.Name = "Text"
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 300
	gui.Size = UDim2.fromOffset(160, 48)
	gui.Enabled = false
	gui.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = WHITE
	label.Text = ""
	label.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2.5
	stroke.Color = Color3.fromRGB(40, 20, 50)
	stroke.Parent = label

	return { Part = anchor, Gui = gui, Label = label, Stroke = stroke }
end

local function acquireAnchor()
	local anchor = table.remove(anchorPool)
	while anchor and anchor.Part.Parent == nil do
		anchor = table.remove(anchorPool)
	end
	return anchor or makeAnchor()
end

local function releaseAnchor(anchor)
	anchor.Gui.Enabled = false
	anchor.Part.CFrame = HIDDEN_CFRAME
	if anchor.Part.Parent then
		table.insert(anchorPool, anchor)
	end
end

-- Conta quantos textos de um tipo estão na tela e recicla o mais antigo se passou do limite.
local function enforceTextLimit(kind, limit)
	local count = 0
	local oldestIndex = nil
	for index, entry in ipairs(texts) do
		if entry.Kind == kind then
			count += 1
			oldestIndex = oldestIndex or index
		end
	end
	if count >= limit and oldestIndex then
		local oldest = table.remove(texts, oldestIndex)
		releaseAnchor(oldest.Anchor)
	end
end

local function spawnText(kind, position, text, color, pixelSize, velocity, life)
	local anchor = acquireAnchor()
	anchor.Label.Text = text
	anchor.Label.TextColor3 = color
	anchor.Label.Size = UDim2.fromScale(1.45, 1.45)
	anchor.Label.TextTransparency = 0
	anchor.Stroke.Transparency = 0
	anchor.Gui.Size = UDim2.fromOffset(pixelSize.X, pixelSize.Y)
	anchor.Gui.Enabled = true
	anchor.Part.CFrame = CFrame.new(position)
	local entry = {
		Kind = kind,
		Anchor = anchor,
		Position = position,
		Velocity = velocity,
		Life = life,
		MaxLife = life,
		Age = 0,
		Created = os.clock(),
		PopScale = 1.45,
	}
	table.insert(texts, entry)
	return entry
end

local function updateTexts(dt)
	local keep = 0
	for index = 1, #texts do
		local entry = texts[index]
		entry.Life -= dt
		entry.Age += dt
		if entry.Life <= 0 then
			releaseAnchor(entry.Anchor)
		else
			-- Sobe desacelerando.
			entry.Velocity *= math.max(0, 1 - 2.5 * dt)
			entry.Position += entry.Velocity * dt
			entry.Anchor.Part.CFrame = CFrame.new(entry.Position)

			-- "Pulo" de tamanho no começo.
			local label = entry.Anchor.Label
			local popAlpha = math.min(1, entry.Age / TEXT_POP_TIME)
			local scale = entry.PopScale + (1 - entry.PopScale) * popAlpha
			label.Size = UDim2.fromScale(scale, scale)

			-- Some nos últimos 35% da vida.
			local fadeStart = entry.MaxLife * 0.35
			if entry.Life < fadeStart then
				local transparency = 1 - entry.Life / fadeStart
				label.TextTransparency = transparency
				entry.Anchor.Stroke.Transparency = transparency
			end
			keep += 1
			texts[keep] = entry
		end
	end
	for index = #texts, keep + 1, -1 do
		texts[index] = nil
	end
end

-------------------------------------------------------------------------------
-- API pública: números, partículas e faíscas
-------------------------------------------------------------------------------

-- Número de dano flutuante. Crítico: maior, vermelho-alaranjado e com "!".
function EffectsController.DamageNumber(position, amount, crit)
	if not isNear(position, 250) then
		return
	end
	amount = asNumber(amount, 0)
	crit = crit == true
	enforceTextLimit("Damage", MAX_DAMAGE_NUMBERS)
	local jitter = Vector3.new(rng:NextNumber(-1.2, 1.2), rng:NextNumber(0.5, 1.5), rng:NextNumber(-1.2, 1.2))
	local velocity = Vector3.new(rng:NextNumber(-2, 2), rng:NextNumber(6, 9), rng:NextNumber(-2, 2))
	local text = NumberFormat.Abbrev(amount) .. (if crit then "!" else "")
	local pixelSize = if crit then Vector2.new(200, 60) else Vector2.new(150, 44)
	local entry = spawnText(
		"Damage",
		position + jitter,
		text,
		if crit then CRIT_COLOR else DAMAGE_COLOR,
		pixelSize,
		velocity,
		if crit then 1.2 else 0.9
	)
	if crit then
		entry.PopScale = 1.8
	end
end

-- "+1,2K" dourado subindo. Várias moedas seguidas juntam num número só.
function EffectsController.CoinPopup(amount, position)
	amount = asNumber(amount, 0)
	if amount <= 0 or typeof(position) ~= "Vector3" then
		return
	end
	playSound("Coin", nil, 0.06)
	if not isNear(position, 300) then
		return
	end

	local t = os.clock()
	for index = #texts, 1, -1 do
		local entry = texts[index]
		if
			entry.Kind == "Coin"
			and t - entry.Created < COIN_MERGE_WINDOW
			and (entry.Position - position).Magnitude < COIN_MERGE_DISTANCE
		then
			entry.Amount += amount
			entry.Anchor.Label.Text = "+" .. NumberFormat.Abbrev(entry.Amount)
			entry.Created = t
			entry.Age = 0
			entry.PopScale = 1.3
			entry.Life = math.max(entry.Life, entry.MaxLife * 0.8)
			entry.Anchor.Label.TextTransparency = 0
			entry.Anchor.Stroke.Transparency = 0
			return
		end
	end

	enforceTextLimit("Coin", MAX_COIN_POPUPS)
	local entry = spawnText(
		"Coin",
		position + Vector3.new(rng:NextNumber(-0.6, 0.6), 2.5, rng:NextNumber(-0.6, 0.6)),
		"+" .. NumberFormat.Abbrev(amount),
		COIN_GOLD,
		Vector2.new(180, 52),
		Vector3.new(0, 4, 0),
		1.3
	)
	entry.Amount = amount
end

-- Explosão de partículas brilhantes. size ≈ raio do efeito em studs.
function EffectsController.Burst(position, color, size)
	if typeof(position) ~= "Vector3" then
		return
	end
	size = math.clamp(asNumber(size, 1), 0.2, 40)
	color = asColor(color, WHITE)
	local count = math.clamp(math.floor(10 + size * 5), 8, 45)
	emitSparkles(position, color, size, count)
end

-- Faísca pequena de impacto (bala acertando algo).
function EffectsController.Spark(position, color)
	if typeof(position) ~= "Vector3" or not isNear(position, 250) then
		return
	end
	color = asColor(color, EXPLOSION_YELLOW)
	emitSparkles(position, color, 0.4, 5)
	addShape("Sphere", position, color:Lerp(WHITE, 0.5), 0.3, 1.1, 0.1, 0.1)
end

-------------------------------------------------------------------------------
-- Efeitos do evento "Effect" (seção 2.4 da especificação)
-------------------------------------------------------------------------------
local handlers = {}

-- Morte de um brainrot: "pop" branco, partículas e pedaços na cor dele.
function handlers.Death(data)
	local position = data.Position
	local radius = sizeToRadius(data.Size)
	local color = asColor(data.Color, Color3.fromRGB(255, 120, 200))
	local giant = data.Giant == true

	addShape("Sphere", position, color:Lerp(WHITE, 0.6), radius * 0.4, radius * 1.4, 0.25, 0.25)
	EffectsController.Burst(position, color, radius)
	spawnDebris(position, {
		Count = math.clamp(math.floor(6 + radius * 1.5), 6, if giant then 30 else 18),
		Colors = { color, color:Lerp(WHITE, 0.35), color:Lerp(BLACK, 0.25) },
		Size = math.clamp(radius * 0.18, 0.25, 2.5),
		Speed = 12 + radius * 2,
		Upward = 10,
		Life = 1.4,
	})

	-- Encantamento: brilho extra na cor do encantamento.
	local enchant = type(data.Enchant) == "string" and Enchants.ById[data.Enchant] or nil
	if enchant then
		local enchantColor = asColor(enchant.Color, WHITE)
		emitSparkles(position, enchantColor, radius * 1.3, 30)
		addShape("Disc", Vector3.new(position.X, findFloorY(position) + 0.2, position.Z), enchantColor, radius, radius * 3.5, 0.6, 0.3)
		if enchant.Rainbow or enchant.Announce then
			spawnDebris(position, {
				Count = 24,
				Colors = CONFETTI_COLORS,
				Size = 0.5,
				Speed = 26,
				Upward = 18,
				GravityScale = 0.35,
				Drag = 1.6,
				Life = 2.4,
				Flat = true,
				Material = Enum.Material.Neon,
			})
		end
	end

	if giant then
		addShape("Disc", Vector3.new(position.X, findFloorY(position) + 0.2, position.Z), color, radius, radius * 4, 0.7, 0.35)
		shakeByDistance(position, 0.45, 90)
	end
	playSound("Death", position, 0.05)
end

-- Explosão (brainrot explosivo): bola de fogo, anel no chão, fumaça e tremida.
function handlers.Explosion(data)
	local position = data.Position
	local radius = math.clamp(asNumber(data.Radius, 6), 2, 60)
	addShape("Sphere", position, EXPLOSION_ORANGE, radius * 0.3, radius * 2, 0.35, 0.15)
	addShape("Sphere", position, EXPLOSION_YELLOW, radius * 0.2, radius * 1.2, 0.2, 0)
	addShape(
		"Disc",
		Vector3.new(position.X, findFloorY(position) + 0.2, position.Z),
		EXPLOSION_YELLOW,
		radius * 0.5,
		radius * 2.6,
		0.45,
		0.3
	)
	emitSparkles(position, EXPLOSION_ORANGE, radius * 0.6, 35)
	emitSmoke(position, SMOKE_GREY, radius * 0.5, 10)
	spawnDebris(position, {
		Count = 8,
		Colors = { Color3.fromRGB(60, 50, 45), EXPLOSION_ORANGE },
		Size = 0.4 + radius * 0.05,
		Speed = 22 + radius * 2,
		Upward = 12,
		Life = 1.2,
	})
	shakeByDistance(position, 0.55, 70)
	playSound("Explosion", position, 0.08)
end

-- Brainrot nascendo: poeira e torrões de terra saindo do chão.
function handlers.Spawn(data)
	local position = data.Position
	local radius = sizeToRadius(data.Size)
	local floorY = findFloorY(position)
	local ground = Vector3.new(position.X, floorY + 0.2, position.Z)
	addShape("Disc", ground, DUST_BROWN, radius * 0.5, radius * 2.5, 0.5, 0.45)
	emitSmoke(ground + Vector3.new(0, 0.5, 0), DUST_BROWN, radius * 0.4, 6)
	spawnDebris(ground + Vector3.new(0, 0.3, 0), {
		Count = 6,
		Colors = { DUST_BROWN, GRASS_GREEN, Color3.fromRGB(120, 90, 60) },
		Size = 0.35,
		Speed = 10,
		Upward = 8,
		Life = 0.9,
		MinY = 0.3,
	})
end

-- Gelo quebrando: cacos azuis voando e brilho branco.
function handlers.IceBreak(data)
	local position = data.Position
	local radius = sizeToRadius(data.Size)
	addShape("Sphere", position, WHITE, radius * 0.6, radius * 1.6, 0.2, 0.3)
	emitSparkles(position, ICE_BLUE, radius, 25)
	spawnDebris(position, {
		Count = math.clamp(math.floor(10 + radius), 10, 24),
		Colors = { ICE_BLUE, WHITE, Color3.fromRGB(120, 190, 255) },
		Size = math.clamp(radius * 0.2, 0.3, 2),
		Speed = 18 + radius,
		Upward = 10,
		Life = 1.3,
		Material = Enum.Material.Glass,
		Transparency = 0.25,
	})
	playSound("Hit", position, 0.1)
end

-- Ingrediente caiu: uma bolinha colorida sobe girando e estoura em brilho.
function handlers.Ingredient(data)
	local position = data.Position
	local color = asColor(data.Color, Color3.fromRGB(255, 220, 120))
	addShape("Orb", position + Vector3.new(0, 1, 0), color, 1.1, 1.1, 1.1, 0.05, { Rise = 6, BurstAtEnd = true })
	emitSparkles(position, color, 1.5, 18)
	addShape("Disc", Vector3.new(position.X, findFloorY(position) + 0.2, position.Z), color, 1, 7, 0.6, 0.35)
end

-- Compra na barraca: confete colorido.
function handlers.Purchase(data)
	local position = data.Position
	spawnDebris(position + Vector3.new(0, 2, 0), {
		Count = 34,
		Colors = CONFETTI_COLORS,
		Size = 0.45,
		Speed = 24,
		Upward = 20,
		GravityScale = 0.3,
		Drag = 1.8,
		Life = 2.6,
		Flat = true,
		MinY = 0.2,
	})
	emitSparkles(position + Vector3.new(0, 2, 0), CONFETTI_COLORS[rng:NextInteger(1, #CONFETTI_COLORS)], 1.5, 20)
	playSound("Purchase", position, 0.15)
end

-- Portal abrindo: anéis roxos, esfera e muito brilho.
function handlers.Portal(data)
	local position = data.Position
	addShape("Sphere", position, PORTAL_PURPLE, 2, 26, 0.9, 0.2)
	addShape("Disc", Vector3.new(position.X, findFloorY(position) + 0.2, position.Z), PORTAL_PINK, 4, 40, 1.2, 0.2)
	emitSparkles(position, PORTAL_PURPLE, 6, 45)
	emitSparkles(position + Vector3.new(0, 3, 0), PORTAL_PINK, 4, 30)
	shakeByDistance(position, 0.3, 120)
	playSound("Portal", nil, 0.5)
end

-- Roda um efeito do tipo "Effect" (também pode ser chamado localmente).
function EffectsController.Play(kind, data)
	local handler = handlers[kind]
	if not handler or type(data) ~= "table" or typeof(data.Position) ~= "Vector3" then
		return
	end
	-- Portal é grande e importante: aparece de longe. O resto só perto.
	if kind ~= "Portal" and not isNear(data.Position) then
		return
	end
	local ok, err = pcall(handler, data)
	if not ok then
		warn("[EffectsController] Erro no efeito " .. tostring(kind) .. ": " .. tostring(err))
	end
end

-------------------------------------------------------------------------------
-- Tiros dos outros jogadores e das torretas
-------------------------------------------------------------------------------
local function onRemoteShot(userId, origin, endpoints, tracerColor)
	if userId == player.UserId or typeof(origin) ~= "Vector3" or type(endpoints) ~= "table" then
		return
	end
	local color = asColor(tracerColor, EXPLOSION_YELLOW)
	for index, endpoint in ipairs(endpoints) do
		if index > MAX_ENDPOINTS_PER_SHOT then
			break
		end
		if typeof(endpoint) == "Vector3" then
			EffectsController.Tracer(origin, endpoint, color, 0.1, DEFAULT_TRACER_SPEED, true)
		end
	end
end

local function onTurretShots(shots)
	if type(shots) ~= "table" then
		return
	end
	local closest = math.huge
	for index, shot in ipairs(shots) do
		if index > MAX_TURRET_SHOTS_PER_BATCH then
			break
		end
		if type(shot) == "table" and typeof(shot.From) == "Vector3" and typeof(shot.To) == "Vector3" then
			EffectsController.Tracer(shot.From, shot.To, TURRET_TRACER_COLOR, 0.14, 520, shot.Hit == true)
			emitSparkles(shot.From, TURRET_TRACER_COLOR, 0.3, 3)
			closest = math.min(closest, (shot.From - cameraPosition()).Magnitude)
		end
	end
	if closest <= SOUND_DISTANCE * 0.75 then
		playSound("Turret", nil, 0.12)
	end
end

-------------------------------------------------------------------------------
-- Atualização por frame (tudo junto, movendo as peças de uma vez com BulkMoveTo)
-------------------------------------------------------------------------------
local moveParts = {}
local moveCFrames = {}

local function onRenderStepped(dt)
	dt = math.min(dt, 0.1)
	table.clear(moveParts)
	table.clear(moveCFrames)

	updateTracers(dt, moveParts, moveCFrames)
	updateDebris(dt, moveParts, moveCFrames)
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	updateShapes(dt)
	updateTexts(dt)
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------
function EffectsController.Init()
	getFolder()

	mainTrove:Add(Net.On("Effect", function(kind, data)
		EffectsController.Play(kind, data)
	end))
	mainTrove:Add(Net.On("RemoteShot", onRemoteShot))
	mainTrove:Add(Net.On("TurretShots", onTurretShots))
	mainTrove:Add(Net.On("CoinPopup", function(amount, position)
		EffectsController.CoinPopup(amount, position)
	end))
end

function EffectsController.Start()
	if started then
		return
	end
	started = true
	mainTrove:Connect(RunService.RenderStepped, onRenderStepped)
	mainTrove:Add(function()
		-- Limpeza total (se um dia o controller for desligado).
		for _, list in ipairs({ tracers, debris, shapes }) do
			for _, entry in ipairs(list) do
				releasePart(entry.Part)
			end
			table.clear(list)
		end
		for _, entry in ipairs(texts) do
			releaseAnchor(entry.Anchor)
		end
		table.clear(texts)
	end)
end

return EffectsController
