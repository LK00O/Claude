--!nonstrict
-- AmbientController: a "vida" do mapa, feita só no cliente (nada disso passa pelo servidor).
--
-- O servidor (os builders do mapa) só coloca TAGS nas coisas. Este módulo acha essas tags
-- com o CollectionService e anima tudo localmente, em cada jogador:
--   * AmbientSpin  {Axis: Vector3, Speed: rad/s}     gira (portal, catavento, estátua...)
--   * AmbientBob   {Amplitude, Period}               sobe e desce (balões, cristais...)
--   * AmbientSway  {Angle: graus, Period, SwayAxis?} balança (bandeirinhas, placas...)
--   * AmbientFlicker                                  luz que treme de leve (lanternas, fogueira)
--   * AmbientEmitter {MaxDistance?}                   partículas ligadas só perto da câmera
--   * AmbientCritter {Kind, Radius, Count?}           bichinhos (borboletas, pássaros, peixes...)
--   * AmbientAurora                                   aurora (Beams) quando a neblina some
--   * AmbientSound {SoundKey}                         som 3D em loop perto do ponto
-- Além disso, o "clima" que segue a câmera: neve (Inverno), areia (Deserto), pólen (Prado)
-- e vaga-lumes (Lobby).
--
-- Opcional: o atributo "MaxDistance" (studs) numa peça/modelo com Spin/Bob/Sway muda a
-- distância em que ele se mexe (padrão 150). Útil para marcos grandes vistos de longe.
--
-- API:
--   AmbientController.Init()        prepara o estado (não espera nada)
--   AmbientController.Start()       liga tudo (tags, clima e UM RenderStepped)
--   AmbientController.GetMapType()  "Lobby" | "Meadow" | "Winter" | "Desert" | nil
--
-- Custo: um único RenderStepped. O movimento roda 30 vezes por segundo (só perto da câmera)
-- e a parte "lenta" (quem está perto, liga/desliga partículas, sons e clima) 4 vezes por
-- segundo. Qualidade de efeitos 1 (baixa): metade das partículas, sem bichinhos e sons só
-- bem perto. Nada aqui dá recompensa: é tudo enfeite.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Trove = require(Shared:WaitForChild("Util"):WaitForChild("Trove"))

local StateController = require(script.Parent:WaitForChild("StateController"))
local UIKit = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("UIKit"))

local AmbientController = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Tags (os mesmos nomes que World/Builders/Common.lua usa no servidor).
local TAG_SPIN = "AmbientSpin"
local TAG_BOB = "AmbientBob"
local TAG_SWAY = "AmbientSway"
local TAG_FLICKER = "AmbientFlicker"
local TAG_EMITTER = "AmbientEmitter"
local TAG_CRITTER = "AmbientCritter"
local TAG_AURORA = "AmbientAurora"
local TAG_SOUND = "AmbientSound"
local MOVER_TAGS = { TAG_SPIN, TAG_BOB, TAG_SWAY }

-- Ritmo do trabalho.
local FAST_STEP = 1 / 30 -- movimento (girar, balançar, bichinhos, luzes)
local SLOW_STEP = 0.25 -- quem está perto, partículas, sons e clima
local MAX_FAST_GAP = 0.2 -- depois de uma travada, não tenta "compensar" o tempo perdido

-- Distâncias (studs, medidas a partir da câmera).
local MOVER_DISTANCE = 150
local FLICKER_DISTANCE = 150
local EMITTER_DISTANCE = 150
local CRITTER_DISTANCE = 150
local SKY_CRITTER_DISTANCE = 400 -- pássaros e urubus aparecem de longe
local FIREFLY_DISTANCE = 100
local SOUND_CREATE_DISTANCE = 120
local SOUND_CREATE_DISTANCE_LOW = 60
local SOUND_DESTROY_DISTANCE = 150
local SOUND_DESTROY_DISTANCE_LOW = 75

-- Limites (seção 5.2 do plano).
local MAX_ACTIVE_EMITTERS = 8 -- + 1 do clima = no máximo 9 emissores de ambiente ligados
local MAX_CRITTER_PARTS = 30
local MAX_CRITTER_COUNT = 12 -- bichos por âncora (Count)

-- Sons de lugar.
local SOUND_RETRY = 5 -- sem áudio para a vaga ainda? tenta de novo depois de 5 s
local SOUND_ROLLOFF_MIN = 8
local SOUND_ROLLOFF_MAX = 80
local SOUND_GROUP = "Ambient"

-- Aurora: aparece quando a neblina (Atmosphere.Density) fica fraca.
local AURORA_DENSITY = 0.12
local AURORA_FADE_TIME = 3
local AURORA_CLOUD_COVER = 0.35 -- céu mais aberto enquanto a aurora aparece

-- Luz tremendo: brilho = base × (0,88 + 0,12 × ruído).
local FLICKER_SPEED = 2.3
local FLICKER_BASE = 0.88
local FLICKER_AMOUNT = 0.12

local TWO_PI = math.pi * 2
local FOLDER_NAME = "ClientAmbient"
local MAP_NAME = "Map"
local SNOW_PART_NAME = "SnowEmitter"

-- Texturas que já vêm no Roblox.
local TEXTURE_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEXTURE_DOT = "rbxasset://textures/whiteCircle.png"

local function keypoint(time, value, envelope)
	return NumberSequenceKeypoint.new(time, value, envelope or 0)
end

-- Clima que segue a câmera: UMA peça invisível re-centralizada 4 vezes por segundo.
--   Box: caixa onde as partículas nascem. Height: altura em relação ao ponto de referência.
--   FromCamera: true = em relação à câmera (neve cai de cima); false = ao personagem (Focus).
--   Wind: quanto o vento (workspace.GlobalWind) empurra as partículas (vira Acceleration).
--   Gusts: rajadas (±60% a cada 8-15 s), só na neve.
--   NeedsClientSnow: só aparece se a peça "SnowEmitter" do mapa tiver ClientSnow = true.
local WEATHER = {
	Winter = {
		Name = "Snow",
		Box = Vector3.new(140, 1, 140),
		Height = 45,
		FromCamera = true,
		Rate = 180,
		LowRate = 70,
		Wind = 0.3,
		Gusts = true,
		NeedsClientSnow = true,
		Props = {
			Texture = TEXTURE_DOT,
			Lifetime = NumberRange.new(6, 8),
			Size = NumberSequence.new({ keypoint(0, 0.22, 0.07), keypoint(1, 0.22, 0.07) }), -- 0,15 a 0,3
			Transparency = NumberSequence.new({ keypoint(0, 0.2), keypoint(0.8, 0.35), keypoint(1, 1) }),
			Color = ColorSequence.new(Color3.fromRGB(255, 255, 255)),
			LightEmission = 0,
			LightInfluence = 1,
			Speed = NumberRange.new(5.5, 7.5),
			SpreadAngle = Vector2.new(12, 12),
			EmissionDirection = Enum.NormalId.Bottom,
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-40, 40),
		},
	},
	Desert = {
		Name = "SandDrift",
		Box = Vector3.new(120, 3, 120),
		Height = -3,
		FromCamera = false,
		Rate = 25,
		Wind = 0.6,
		Props = {
			Texture = TEXTURE_SMOKE,
			Lifetime = NumberRange.new(3, 4),
			Size = NumberSequence.new({ keypoint(0, 3, 1), keypoint(1, 3, 1) }), -- 2 a 4
			Transparency = NumberSequence.new({ keypoint(0, 1), keypoint(0.25, 0.85), keypoint(0.75, 0.85), keypoint(1, 1) }),
			Color = ColorSequence.new(Color3.fromRGB(230, 200, 150)),
			LightEmission = 0,
			LightInfluence = 1,
			Speed = NumberRange.new(0.5, 1.5),
			SpreadAngle = Vector2.new(180, 20),
			EmissionDirection = Enum.NormalId.Top,
			Rotation = NumberRange.new(0, 360),
			RotSpeed = NumberRange.new(-20, 20),
		},
	},
	Meadow = {
		Name = "Pollen",
		Box = Vector3.new(80, 24, 80),
		Height = 4,
		FromCamera = false,
		Rate = 12,
		Wind = 0.04,
		Props = {
			Texture = TEXTURE_DOT,
			Lifetime = NumberRange.new(8),
			Size = NumberSequence.new({ keypoint(0, 0.115, 0.035), keypoint(1, 0.115, 0.035) }), -- 0,08 a 0,15
			Transparency = NumberSequence.new({ keypoint(0, 1), keypoint(0.15, 0.25), keypoint(0.85, 0.25), keypoint(1, 1) }),
			Color = ColorSequence.new(Color3.fromRGB(255, 246, 200)),
			LightEmission = 0.4,
			LightInfluence = 1,
			Speed = NumberRange.new(0.2, 0.6),
			SpreadAngle = Vector2.new(180, 180),
			EmissionDirection = Enum.NormalId.Top,
		},
	},
	Lobby = {
		Name = "Fireflies",
		Box = Vector3.new(70, 8, 70),
		Height = 1,
		FromCamera = false,
		Rate = 4,
		Wind = 0,
		Props = {
			Texture = TEXTURE_DOT,
			Lifetime = NumberRange.new(6),
			Size = NumberSequence.new({ keypoint(0, 0), keypoint(0.2, 0.12), keypoint(0.8, 0.12), keypoint(1, 0) }),
			Transparency = NumberSequence.new({ keypoint(0, 1), keypoint(0.2, 0.1), keypoint(0.8, 0.1), keypoint(1, 1) }),
			Color = ColorSequence.new(Color3.fromRGB(220, 255, 120)),
			LightEmission = 1,
			LightInfluence = 0,
			Speed = NumberRange.new(0.3, 0.9),
			SpreadAngle = Vector2.new(180, 180),
			EmissionDirection = Enum.NormalId.Top,
		},
	},
}

-- Bichinhos: quantas peças cada um usa, quantos por âncora e o raio padrão.
--   Sky = true: voa alto e é visto de longe (400 studs).
local CRITTERS = {
	Butterfly = { Parts = 2, Count = 1, Radius = 6 },
	Bird = { Parts = 2, Count = 4, Radius = 30, Sky = true },
	Vulture = { Parts = 2, Count = 2, Radius = 60, Sky = true },
	Fish = { Parts = 1, Count = 1, Radius = 5 },
	Koi = { Parts = 1, Count = 3, Radius = 6 },
	Tumbleweed = { Parts = 1, Count = 1, Radius = 60 },
	Firefly = { Parts = 0, Count = 1, Radius = 8 },
	Pet = { Parts = 0, Count = 1, Radius = 10 },
}

local BUTTERFLY_COLORS = {
	Color3.fromRGB(255, 170, 60),
	Color3.fromRGB(120, 190, 255),
	Color3.fromRGB(255, 120, 200),
	Color3.fromRGB(255, 235, 110),
	Color3.fromRGB(190, 140, 255),
}
local KOI_COLORS = {
	Color3.fromRGB(255, 140, 40),
	Color3.fromRGB(250, 245, 235),
	Color3.fromRGB(255, 200, 60),
}
local BIRD_COLOR = Color3.fromRGB(60, 62, 70)
local VULTURE_COLOR = Color3.fromRGB(70, 52, 40)
local FISH_COLOR = Color3.fromRGB(150, 170, 190)
local TUMBLEWEED_COLOR = Color3.fromRGB(170, 128, 78)
local FIREFLY_COLOR = Color3.fromRGB(220, 255, 120)

local BUTTERFLY_WING = Vector3.new(0.55, 0.05, 0.45)
local BIRD_WING = Vector3.new(1.3, 0.1, 0.55)
local VULTURE_WING = Vector3.new(3.2, 0.14, 1.1)
local FISH_SIZE = Vector3.new(0.45, 0.35, 1.2)
local KOI_SIZE = Vector3.new(0.6, 0.35, 1.6)
local TUMBLEWEED_SIZE = 2.4
local BIRD_BANK = -0.3 -- inclinação para dentro da curva (radianos)
local FISH_JUMP_TIME = 1.1
local FISH_JUMP_HEIGHT = 2.2
local PET_SPEED = 4 -- studs por segundo
local PET_TURN_SPEED = 5 -- radianos por segundo

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local started = false
local lifeTrove = nil -- tudo que vive enquanto o controller está ligado
local mapTrove = nil -- coisas do mapa atual (clima, vigias do SnowEmitter...)
local ambientFolder = nil -- pasta "ClientAmbient" com as peças criadas aqui
local quality = 2 -- 1 baixa, 2 média, 3 alta
local mapType = nil
local currentMap = nil
local rebindQueued = false
local clockOrigin = os.clock()
local rng = Random.new()

local movers = {} -- [Instance] = mover (Spin/Bob/Sway)
local activeMovers, activeMoverCount = {}, 0

local flickers = {} -- [Instance] = {Lights, Bases, Written, Seed, Active}
local activeFlickers, activeFlickerCount = {}, 0

local emitterEntries = {} -- [ParticleEmitter] = {Emitter, Owner, BaseRate, BaseEnabled, MaxDistance, Local...}
local emitterCandidates = {}

local critterEntries = {} -- [Instance] = entry
local critterOrder = {} -- mesma lista, na ordem em que chegaram (para dividir o limite de peças)
local activeCritters, activeCritterCount = {}, 0
local critterPartsUsed = 0

local auroras = {} -- [Model] = { {Beam, Transparency, Enabled}, ... }
local auroraAlpha, auroraTarget = 0, 0
local cloudState = nil -- {Clouds, Cover} enquanto a aurora mexe nas nuvens

local soundSpots = {} -- [Instance] = {Anchor, Sound, NextTry}

local weather = nil -- {Part, Emitter, Preset, Gust, GustTarget, NextGust, AppliedAcceleration}
local windDirection = Vector3.xAxis -- direção do vento no chão (para os rolos de feno)
local windFlat = Vector3.zero

-- Listas reaproveitadas para o BulkMoveTo (sem criar tabelas novas a cada passo).
local bulkParts, bulkCFrames = {}, {}
local bulkCount, lastBulkCount = 0, 0

local fastAccumulator, slowAccumulator = 0, 0
local stepErrors = 0

-------------------------------------------------------------------------------
-- Ajudantes gerais
-------------------------------------------------------------------------------

-- Número de verdade (não NaN, não infinito); senão, o padrão.
local function finiteNumber(value, default)
	if type(value) == "number" and value == value and value > -math.huge and value < math.huge then
		return value
	end
	return default
end

local function positiveNumber(value, default)
	local number = finiteNumber(value, nil)
	if number and number > 0 then
		return number
	end
	return default
end

-- Eixo (Vector3) do atributo, já com tamanho 1; senão, o padrão.
local function unitAxis(value, default)
	if typeof(value) == "Vector3" and value.Magnitude > 1e-3 then
		return value.Unit
	end
	return default
end

-- Posição no mundo de uma peça, modelo, attachment ou de algo dentro deles (luz, partícula...).
local function positionOf(instance)
	if instance == nil then
		return nil
	elseif instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	elseif instance:IsA("Attachment") then
		return instance.WorldPosition
	elseif instance:IsA("Light") or instance:IsA("ParticleEmitter") or instance:IsA("Sound") then
		return positionOf(instance.Parent)
	end
	return nil
end

-- Peças ancoradas da instância (ela mesma, se for peça, e as de dentro).
-- As peças soltas e soldadas acompanham a peça ancorada em que estão presas.
local function collectAnchoredParts(instance)
	local parts = {}
	if instance:IsA("BasePart") and instance.Anchored then
		table.insert(parts, instance)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Anchored then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- Guarda uma peça e o CFrame novo dela para o próximo BulkMoveTo.
local function push(part, cframe)
	bulkCount += 1
	bulkParts[bulkCount] = part
	bulkCFrames[bulkCount] = cframe
end

-- Move de uma vez tudo que foi guardado com push (um único BulkMoveTo por passo).
local function flushBulk()
	for index = bulkCount + 1, lastBulkCount do
		bulkParts[index] = nil
		bulkCFrames[index] = nil
	end
	lastBulkCount = bulkCount
	if bulkCount > 0 then
		local ok = pcall(workspace.BulkMoveTo, workspace, bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		if not ok then
			-- Alguma peça sumiu no meio do caminho: remonta as listas no próximo passo.
			for _, mover in pairs(movers) do
				mover.Dirty = true
			end
		end
	end
	bulkCount = 0
end

-- Peça invisível e "fantasma" criada aqui no cliente (não colide, não é achada por raios).
local function makeClientPart(name, size, color, material, shape)
	local part = Instance.new("Part")
	part.Name = name
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.Color = color or Color3.new(1, 1, 1)
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- Multiplicador das partículas pela qualidade (baixa = metade).
local function rateScale()
	return if quality <= 1 then 0.5 else 1
end

-------------------------------------------------------------------------------
-- Tipo do mapa
-------------------------------------------------------------------------------

local function computeMapType(map)
	local mapId = map and map:GetAttribute("MapId")
	if type(mapId) == "string" and mapId ~= "" then
		return mapId
	end
	if workspace:GetAttribute("Role") == "Lobby" then
		return "Lobby"
	end
	return nil
end

-- A peça "SnowEmitter" do mapa atual (ou nil).
local function findSnowPart()
	if not currentMap or currentMap.Parent ~= workspace then
		return nil
	end
	local part = currentMap:FindFirstChild(SNOW_PART_NAME, true)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

-------------------------------------------------------------------------------
-- Movimento: AmbientSpin / AmbientBob / AmbientSway
-------------------------------------------------------------------------------

local function hasMoverTag(instance)
	for _, tag in ipairs(MOVER_TAGS) do
		if instance:HasTag(tag) then
			return true
		end
	end
	return false
end

-- Lê os atributos do movimento (chamado ao registrar e quando um atributo muda).
local function readMoverSettings(mover)
	local instance = mover.Instance
	mover.MaxDistance = positiveNumber(instance:GetAttribute("MaxDistance"), MOVER_DISTANCE)

	if instance:HasTag(TAG_SPIN) then
		mover.Spin = {
			Axis = unitAxis(instance:GetAttribute("Axis"), Vector3.yAxis),
			Speed = finiteNumber(instance:GetAttribute("Speed"), 1),
		}
	else
		mover.Spin = nil
	end

	if instance:HasTag(TAG_BOB) then
		mover.Bob = {
			Amplitude = finiteNumber(instance:GetAttribute("Amplitude"), 0.5),
			Period = positiveNumber(instance:GetAttribute("Period"), 3),
		}
	else
		mover.Bob = nil
	end

	if instance:HasTag(TAG_SWAY) then
		-- O eixo do balanço é "SwayAxis"; sem giro junto, "Axis" também serve. Padrão: Z.
		local axisValue = instance:GetAttribute("SwayAxis")
		if axisValue == nil and not instance:HasTag(TAG_SPIN) then
			axisValue = instance:GetAttribute("Axis")
		end
		mover.Sway = {
			Axis = unitAxis(axisValue, Vector3.zAxis),
			Angle = math.rad(finiteNumber(instance:GetAttribute("Angle"), 5)),
			Period = positiveNumber(instance:GetAttribute("Period"), 3),
		}
	else
		mover.Sway = nil
	end
end

-- Remonta a lista de peças (quando algo entrou ou saiu do modelo).
-- Peça já conhecida mantém o CFrame relativo; peça nova é medida na posição original.
local function rebuildMoverParts(mover)
	mover.Dirty = false
	local parts = collectAnchoredParts(mover.Instance)
	local offsets = table.create(#parts)
	local known = mover.OffsetByPart
	local fresh = {}
	for index, part in ipairs(parts) do
		local offset = known[part] or mover.Base:ToObjectSpace(part.CFrame)
		fresh[part] = offset
		offsets[index] = offset
	end
	mover.OffsetByPart = fresh
	mover.Parts = parts
	mover.Offsets = offsets
end

local function createMover(instance)
	local base
	if instance:IsA("BasePart") then
		base = instance.CFrame
	elseif instance:IsA("Model") then
		-- PrimaryPart é o pivô confiável no cliente (Model.WorldPivot não é replicado).
		local primary = instance.PrimaryPart
		base = if primary then primary.CFrame else instance:GetPivot()
	else
		return nil
	end

	local mover = {
		Instance = instance,
		Base = base,
		OffsetByPart = {},
		Parts = {},
		Offsets = {},
		Dirty = true,
		Active = false,
		Removed = false,
		-- Fase tirada da posição: dois balões lado a lado não sobem juntos.
		Phase = (base.Position.X * 0.37 + base.Position.Z * 0.23) % TWO_PI,
		Trove = Trove.new(),
	}
	local function markDirty(descendant)
		if descendant:IsA("BasePart") then
			mover.Dirty = true
		end
	end
	mover.Trove:Connect(instance.DescendantAdded, markDirty)
	mover.Trove:Connect(instance.DescendantRemoving, markDirty)
	mover.Trove:Connect(instance.AttributeChanged, function()
		readMoverSettings(mover)
	end)
	rebuildMoverParts(mover)
	return mover
end

-- Para de mexer e (se a instância ainda existe) devolve tudo à posição original.
local function removeMover(mover, restore)
	mover.Removed = true
	mover.Trove:Clean()
	movers[mover.Instance] = nil
	if restore then
		local parts, cframes = {}, {}
		for index, part in ipairs(mover.Parts) do
			if part.Parent then
				table.insert(parts, part)
				table.insert(cframes, mover.Base * mover.Offsets[index])
			end
		end
		if #parts > 0 then
			pcall(workspace.BulkMoveTo, workspace, parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
		end
	end
end

-- Cria, atualiza ou remove o movimento de uma instância conforme as tags que ela tem.
local function refreshMover(instance)
	local mover = movers[instance]
	local wanted = instance:IsDescendantOf(workspace)
		and hasMoverTag(instance)
		and (instance:IsA("BasePart") or instance:IsA("Model"))
	if not wanted then
		if mover then
			removeMover(mover, instance.Parent ~= nil)
		end
		return
	end
	if not mover then
		mover = createMover(instance)
		if not mover then
			return
		end
		movers[instance] = mover
	end
	readMoverSettings(mover)
end

-- CFrame do pivô no tempo t: sobe/desce (Bob), balança (Sway) e gira (Spin).
local function moverPivot(mover, t)
	local cframe = mover.Base
	local bob = mover.Bob
	if bob then
		cframe = cframe + Vector3.new(0, bob.Amplitude * math.sin(TWO_PI * t / bob.Period + mover.Phase), 0)
	end
	local sway = mover.Sway
	if sway then
		cframe = cframe * CFrame.fromAxisAngle(sway.Axis, sway.Angle * math.sin(TWO_PI * t / sway.Period + mover.Phase))
	end
	local spin = mover.Spin
	if spin then
		cframe = cframe * CFrame.fromAxisAngle(spin.Axis, (spin.Speed * t) % TWO_PI)
	end
	return cframe
end

-------------------------------------------------------------------------------
-- Luzes que tremem: AmbientFlicker
-------------------------------------------------------------------------------

local function addFlicker(instance)
	if flickers[instance] then
		return
	end
	local lights = {}
	if instance:IsA("Light") then
		table.insert(lights, instance)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Light") then
			table.insert(lights, descendant)
		end
	end
	if #lights == 0 then
		return
	end
	local bases = table.create(#lights)
	for index, light in ipairs(lights) do
		bases[index] = light.Brightness
	end
	flickers[instance] = {
		Instance = instance,
		Lights = lights,
		Bases = bases,
		Written = {},
		Seed = rng:NextNumber(0, 500) + 0.37, -- cada luz treme de um jeito
		Active = false,
	}
end

-- Volta o brilho original das luzes.
local function restoreFlicker(flicker)
	for index, light in ipairs(flicker.Lights) do
		if light.Parent and flicker.Written[index] then
			light.Brightness = flicker.Bases[index]
		end
	end
	table.clear(flicker.Written)
end

local function removeFlicker(instance)
	local flicker = flickers[instance]
	if not flicker then
		return
	end
	flickers[instance] = nil
	flicker.Removed = true
	restoreFlicker(flicker)
end

local function stepFlicker(flicker, t)
	local noise = math.clamp(math.noise(t * FLICKER_SPEED, flicker.Seed, 0.5) * 2, -1, 1)
	local factor = FLICKER_BASE + FLICKER_AMOUNT * noise
	local written = flicker.Written
	for index, light in ipairs(flicker.Lights) do
		-- O servidor mudou o brilho? Então esse passa a ser o brilho base.
		local last = written[index]
		if last and math.abs(light.Brightness - last) > 1e-3 then
			flicker.Bases[index] = light.Brightness
		end
		local value = flicker.Bases[index] * factor
		light.Brightness = value
		written[index] = value
	end
end

-------------------------------------------------------------------------------
-- Partículas perto da câmera: AmbientEmitter (e os vaga-lumes dos bichinhos)
-------------------------------------------------------------------------------

local function registerEmitter(emitter, owner, maxDistance, isLocal)
	if emitterEntries[emitter] then
		return
	end
	emitterEntries[emitter] = {
		Emitter = emitter,
		Owner = owner,
		BaseRate = emitter.Rate,
		BaseEnabled = emitter.Enabled,
		MaxDistance = maxDistance,
		Local = isLocal == true,
		Active = nil, -- nil = ainda não mexemos
		AppliedRate = nil,
		Distance = 0,
	}
	-- Começa desligado; a passada lenta liga os mais perto.
	emitter.Enabled = false
	emitterEntries[emitter].Active = false
end

local function addEmitterOwner(instance)
	local ownerDistance = positiveNumber(instance:GetAttribute("MaxDistance"), EMITTER_DISTANCE)
	local list = {}
	if instance:IsA("ParticleEmitter") then
		table.insert(list, instance)
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			table.insert(list, descendant)
		end
	end
	for _, emitter in ipairs(list) do
		local maxDistance = positiveNumber(emitter:GetAttribute("MaxDistance"), ownerDistance)
		registerEmitter(emitter, instance, maxDistance, false)
	end
end

-- Esquece um emissor. Os do servidor voltam ao normal; os criados aqui são apagados.
local function dropEmitter(entry)
	emitterEntries[entry.Emitter] = nil
	local emitter = entry.Emitter
	if entry.Local then
		emitter:Destroy()
	elseif emitter.Parent then
		emitter.Rate = entry.BaseRate
		emitter.Enabled = entry.BaseEnabled
	end
end

local function removeEmitterOwner(instance)
	local toDrop = {}
	for _, entry in pairs(emitterEntries) do
		if entry.Owner == instance and not entry.Local then
			table.insert(toDrop, entry)
		end
	end
	for _, entry in ipairs(toDrop) do
		dropEmitter(entry)
	end
end

-- Liga/desliga um emissor (só escreve quando algo muda).
local function setEmitterActive(entry, active)
	local emitter = entry.Emitter
	-- O servidor mexeu no emissor por conta própria? Então isso vira o "normal" dele.
	if entry.Active ~= nil and emitter.Enabled ~= entry.Active then
		entry.BaseEnabled = emitter.Enabled
	end
	if entry.AppliedRate ~= nil and math.abs(emitter.Rate - entry.AppliedRate) > 1e-4 then
		entry.BaseRate = emitter.Rate
	end
	local rate = entry.BaseRate * rateScale()
	if entry.AppliedRate == nil or math.abs(rate - entry.AppliedRate) > 1e-4 then
		emitter.Rate = rate
		entry.AppliedRate = emitter.Rate
	end
	if entry.Active ~= active then
		emitter.Enabled = active
		entry.Active = active
	end
end

local function sortByDistance(a, b)
	return a.Distance < b.Distance
end

-- 4x por segundo: liga só os emissores mais perto (no máximo MAX_ACTIVE_EMITTERS).
local function cullEmitters(cameraPosition)
	local count = 0
	local dead = nil
	for emitter, entry in pairs(emitterEntries) do
		if emitter.Parent == nil then
			dead = dead or {}
			table.insert(dead, emitter)
		else
			-- Atualiza o "normal" do emissor antes de decidir (mudanças vindas do servidor).
			if entry.Active ~= nil and emitter.Enabled ~= entry.Active then
				entry.BaseEnabled = emitter.Enabled
				entry.Active = emitter.Enabled
			end
			local position = entry.BaseEnabled and positionOf(emitter.Parent) or nil
			local distance = position and (position - cameraPosition).Magnitude or math.huge
			if distance <= entry.MaxDistance then
				entry.Distance = distance
				count += 1
				emitterCandidates[count] = entry
			else
				setEmitterActive(entry, false)
			end
		end
	end
	if dead then
		for _, emitter in ipairs(dead) do
			emitterEntries[emitter] = nil
		end
	end
	for index = #emitterCandidates, count + 1, -1 do
		emitterCandidates[index] = nil
	end
	if count > MAX_ACTIVE_EMITTERS then
		table.sort(emitterCandidates, sortByDistance)
	end
	for index = 1, count do
		setEmitterActive(emitterCandidates[index], index <= MAX_ACTIVE_EMITTERS)
	end
end

-------------------------------------------------------------------------------
-- Bichinhos: AmbientCritter
-------------------------------------------------------------------------------

-- Duas asas presas no corpo (body = CFrame do corpo, olhando para a frente).
-- flap > 0 levanta as pontas das asas.
local function pushWings(creature, body, flap)
	local halfWidth = creature.Left.Size.X / 2
	push(creature.Left, body * CFrame.Angles(0, 0, -flap) * CFrame.new(-halfWidth, 0, 0))
	push(creature.Right, body * CFrame.Angles(0, 0, flap) * CFrame.new(halfWidth, 0, 0))
end

local function makeWingPair(entry, name, size, color)
	local left = makeClientPart(name .. "WingL", size, color, Enum.Material.SmoothPlastic)
	local right = makeClientPart(name .. "WingR", size, color, Enum.Material.SmoothPlastic)
	left.Parent = ambientFolder
	right.Parent = ambientFolder
	entry.Trove:Add(left)
	entry.Trove:Add(right)
	return left, right
end

local CRITTER_BUILDERS = {}
local CRITTER_UPDATERS = {}

-- Borboleta: voo em "oito" (curva de Lissajous) em volta das flores, batendo as asas rápido.
CRITTER_BUILDERS.Butterfly = function(entry, count)
	entry.Center = entry.Anchor.Position + Vector3.new(0, 2.5, 0)
	for index = 1, count do
		local color = BUTTERFLY_COLORS[rng:NextInteger(1, #BUTTERFLY_COLORS)]
		local left, right = makeWingPair(entry, "Butterfly", BUTTERFLY_WING, color)
		table.insert(entry.Creatures, { Left = left, Right = right, Phase = rng:NextNumber(0, TWO_PI) + index })
	end
end

CRITTER_UPDATERS.Butterfly = function(entry, t)
	local radius = entry.Radius
	for _, creature in ipairs(entry.Creatures) do
		local phase = creature.Phase
		local a, b = t * 0.43 + phase, t * 0.61 + phase * 1.7
		local position = entry.Center
			+ Vector3.new(math.sin(a) * radius, math.sin(t * 1.3 + phase) * 1.1, math.sin(b) * radius * 0.8)
		-- Direção do voo = derivada da curva (para onde ela vai agora).
		local direction = Vector3.new(math.cos(a) * 0.43 * radius, 0, math.cos(b) * 0.61 * radius * 0.8)
		local body = if direction.Magnitude > 1e-3
			then CFrame.lookAt(position, position + direction)
			else CFrame.new(position)
		pushWings(creature, body, 0.2 + math.sin(t * 16 + phase) * 0.9)
	end
end

-- Pássaros (bando em círculo, inclinando na curva) e urubus (planando devagar, bem abertos).
local function buildFlyers(entry, count, name, wingSize, color)
	entry.Center = entry.Anchor.Position
	local groupPhase = rng:NextNumber(0, TWO_PI)
	for index = 1, count do
		local left, right = makeWingPair(entry, name, wingSize, color)
		table.insert(entry.Creatures, {
			Left = left,
			Right = right,
			Offset = groupPhase + (index - 1) * 0.28, -- um pouco atrás do outro
			RadiusOffset = (index % 2 == 0) and 1.5 * index or -1.2 * index,
			Height = (index % 3) * 1.2,
			Phase = rng:NextNumber(0, TWO_PI),
		})
	end
end

local function updateFlyers(entry, t, speed, flapBase, flapAmount, flapSpeed)
	local center = entry.Center
	for _, creature in ipairs(entry.Creatures) do
		local angle = t * speed + creature.Offset
		local radius = math.max(2, entry.Radius + creature.RadiusOffset)
		local position = center
			+ Vector3.new(
				math.cos(angle) * radius,
				creature.Height + math.sin(t * 0.7 + creature.Phase) * 1.5,
				math.sin(angle) * radius
			)
		local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
		local body = CFrame.lookAt(position, position + tangent) * CFrame.Angles(0, 0, BIRD_BANK)
		pushWings(creature, body, flapBase + math.sin(t * flapSpeed + creature.Phase) * flapAmount)
	end
end

CRITTER_BUILDERS.Bird = function(entry, count)
	buildFlyers(entry, count, "Bird", BIRD_WING, BIRD_COLOR)
end
CRITTER_UPDATERS.Bird = function(entry, t)
	updateFlyers(entry, t, 0.35, 0.25, 0.45, 7)
end

CRITTER_BUILDERS.Vulture = function(entry, count)
	buildFlyers(entry, count, "Vulture", VULTURE_WING, VULTURE_COLOR)
end
CRITTER_UPDATERS.Vulture = function(entry, t)
	updateFlyers(entry, t, 0.12, 0.12, 0.08, 1.1)
end

-- Peixes (pulam de vez em quando) e carpas koi (nadam devagar, mais perto da superfície).
local function buildSwimmers(entry, count, isKoi)
	entry.Center = entry.Anchor.Position
	for index = 1, count do
		local color = if isKoi then KOI_COLORS[(index - 1) % #KOI_COLORS + 1] else FISH_COLOR
		local body = makeClientPart(if isKoi then "Koi" else "Fish", if isKoi then KOI_SIZE else FISH_SIZE, color)
		body.Parent = ambientFolder
		entry.Trove:Add(body)
		table.insert(entry.Creatures, {
			Body = body,
			Offset = rng:NextNumber(0, TWO_PI),
			Direction = if rng:NextNumber() < 0.5 then -1 else 1,
			RadiusScale = rng:NextNumber(0.55, 1),
			Phase = rng:NextNumber(0, TWO_PI),
			NextJump = if isKoi then nil else rng:NextNumber(6, 12),
		})
	end
end

local function updateSwimmers(entry, t, speed, depth)
	for _, creature in ipairs(entry.Creatures) do
		local angle = t * speed * creature.Direction + creature.Offset
		local radius = entry.Radius * creature.RadiusScale
		local height, pitch = depth, 0
		local jumpAt = creature.NextJump
		if jumpAt and t >= jumpAt then
			local progress = (t - jumpAt) / FISH_JUMP_TIME
			if progress >= 1 then
				creature.NextJump = t + rng:NextNumber(6, 12)
			else
				height = depth + (FISH_JUMP_HEIGHT - depth) * math.sin(progress * math.pi)
				pitch = (0.5 - progress) * 1.4 -- nariz para cima na subida, para baixo na descida
			end
		end
		local position = entry.Center + Vector3.new(math.cos(angle) * radius, height, math.sin(angle) * radius)
		local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle)) * creature.Direction
		local wiggle = math.sin(t * 8 + creature.Phase) * 0.15
		push(creature.Body, CFrame.lookAt(position, position + tangent) * CFrame.Angles(pitch, wiggle, 0))
	end
end

CRITTER_BUILDERS.Fish = function(entry, count)
	buildSwimmers(entry, count, false)
end
CRITTER_UPDATERS.Fish = function(entry, t)
	updateSwimmers(entry, t, 0.6, -1.6)
end

CRITTER_BUILDERS.Koi = function(entry, count)
	buildSwimmers(entry, count, true)
end
CRITTER_UPDATERS.Koi = function(entry, t)
	updateSwimmers(entry, t, 0.35, -0.7)
end

-- Rolo de feno: rola a favor do vento atravessando o raio, some na ponta e volta do começo.
CRITTER_BUILDERS.Tumbleweed = function(entry, count)
	entry.Center = entry.Anchor.Position
	for _ = 1, count do
		local ball = makeClientPart(
			"Tumbleweed",
			Vector3.new(TUMBLEWEED_SIZE, TUMBLEWEED_SIZE, TUMBLEWEED_SIZE),
			TUMBLEWEED_COLOR,
			Enum.Material.Fabric,
			Enum.PartType.Ball
		)
		ball.Parent = ambientFolder
		entry.Trove:Add(ball)
		table.insert(entry.Creatures, {
			Body = ball,
			Offset = rng:NextNumber(0, 200),
			Speed = rng:NextNumber(6, 9),
			Lane = rng:NextNumber(-0.5, 0.5) * entry.Radius,
			Phase = rng:NextNumber(0, TWO_PI),
			Transparency = 0,
		})
	end
end

CRITTER_UPDATERS.Tumbleweed = function(entry, t)
	local direction = windDirection
	local side = Vector3.new(-direction.Z, 0, direction.X)
	local rollAxis = Vector3.yAxis:Cross(direction)
	local span = entry.Radius * 2
	local ballRadius = TUMBLEWEED_SIZE / 2
	for _, creature in ipairs(entry.Creatures) do
		local travel = (t * creature.Speed + creature.Offset) % span
		local bounce = math.abs(math.sin(t * 2.6 + creature.Phase)) * 0.9
		local position = entry.Center
			+ direction * (travel - entry.Radius)
			+ side * creature.Lane
			+ Vector3.new(0, ballRadius + bounce, 0)
		push(creature.Body, CFrame.new(position) * CFrame.fromAxisAngle(rollAxis, travel / ballRadius))
		-- Some aos poucos nas pontas (assim a volta para o começo não aparece).
		local edge = math.min(travel, span - travel)
		local transparency = 1 - math.clamp(edge / 8, 0, 1)
		if math.abs(transparency - creature.Transparency) > 0.02 then
			creature.Transparency = transparency
			creature.Body.Transparency = transparency
		end
	end
end

-- Vaga-lumes: um emissor local de pontinhos brilhantes em volta da âncora.
CRITTER_BUILDERS.Firefly = function(entry)
	local width = math.min(entry.Radius * 2, 40)
	local host = makeClientPart("FireflyArea", Vector3.new(width, 3, width))
	host.Transparency = 1
	host.CFrame = CFrame.new(entry.Anchor.Position + Vector3.new(0, 1.5, 0))
	host.Parent = ambientFolder
	entry.Trove:Add(host)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Fireflies"
	emitter.Texture = TEXTURE_DOT
	emitter.Rate = 4
	emitter.Lifetime = NumberRange.new(6)
	emitter.Size = NumberSequence.new({ keypoint(0, 0), keypoint(0.2, 0.12), keypoint(0.8, 0.12), keypoint(1, 0) })
	emitter.Transparency = NumberSequence.new({ keypoint(0, 1), keypoint(0.2, 0.1), keypoint(0.8, 0.1), keypoint(1, 1) })
	emitter.Color = ColorSequence.new(FIREFLY_COLOR)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Speed = NumberRange.new(0.3, 0.9)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Parent = host
	registerEmitter(emitter, entry.Anchor, FIREFLY_DISTANCE, true)
	entry.Trove:Add(function()
		local emitterEntry = emitterEntries[emitter]
		if emitterEntry then
			dropEmitter(emitterEntry)
		end
	end)
end

-- Bichinho de estimação: o modelo do servidor passeia perto de casa (só neste cliente).
local function turnToward(current, target, maxStep)
	local difference = (target - current + math.pi) % TWO_PI - math.pi
	if math.abs(difference) <= maxStep then
		return target
	end
	return current + math.sign(difference) * maxStep
end

CRITTER_BUILDERS.Pet = function(entry)
	local model = entry.Anchor
	local pivot = if model:IsA("Model")
		then (if model.PrimaryPart then model.PrimaryPart.CFrame else model:GetPivot())
		elseif model:IsA("BasePart") then model.CFrame
		else nil
	if not pivot then
		return
	end
	local look = pivot.LookVector
	local yaw = if Vector3.new(look.X, 0, look.Z).Magnitude > 1e-3 then math.atan2(-look.X, -look.Z) else 0
	local home = CFrame.new(pivot.Position) * CFrame.Angles(0, yaw, 0)
	local parts = collectAnchoredParts(model)
	local offsets = table.create(#parts)
	for index, part in ipairs(parts) do
		offsets[index] = home:ToObjectSpace(part.CFrame)
	end
	entry.Pet = {
		Parts = parts,
		Offsets = offsets,
		Home = home,
		Position = pivot.Position,
		Yaw = yaw,
		Target = nil,
		IdleUntil = rng:NextNumber(1, 4),
		Moved = false,
	}
end

CRITTER_UPDATERS.Pet = function(entry, t, dt)
	local pet = entry.Pet
	if not pet then
		return
	end
	if pet.Target then
		local delta = pet.Target - pet.Position
		local distance = delta.Magnitude
		if distance < 0.3 then
			pet.Target = nil
			pet.IdleUntil = t + rng:NextNumber(2, 5)
		else
			local direction = delta / distance
			pet.Position += direction * math.min(distance, PET_SPEED * dt)
			pet.Yaw = turnToward(pet.Yaw, math.atan2(-direction.X, -direction.Z), PET_TURN_SPEED * dt)
		end
	elseif t >= pet.IdleUntil then
		local angle = rng:NextNumber(0, TWO_PI)
		local radius = entry.Radius * math.sqrt(rng:NextNumber(0.05, 1))
		pet.Target = pet.Home.Position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
	else
		return -- parado: não precisa mover nada
	end
	-- Pulinhos enquanto anda.
	local hop = if pet.Target then math.abs(math.sin(t * 9 + entry.Phase)) * 0.3 else 0
	local pivot = CFrame.new(pet.Position + Vector3.new(0, hop, 0)) * CFrame.Angles(0, pet.Yaw, 0)
	for index, part in ipairs(pet.Parts) do
		push(part, pivot * pet.Offsets[index])
	end
	pet.Moved = true
end

-- Devolve o bichinho de estimação para casa.
local function restorePet(entry)
	local pet = entry.Pet
	entry.Pet = nil
	if not (pet and pet.Moved) then
		return
	end
	local parts, cframes = {}, {}
	for index, part in ipairs(pet.Parts) do
		if part.Parent then
			table.insert(parts, part)
			table.insert(cframes, pet.Home * pet.Offsets[index])
		end
	end
	if #parts > 0 then
		pcall(workspace.BulkMoveTo, workspace, parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local function destroyCritterVisual(entry)
	if not entry.Built then
		return
	end
	entry.Built = false
	entry.Active = false
	critterPartsUsed -= entry.PartCount
	entry.PartCount = 0
	if entry.Pet then
		restorePet(entry)
	end
	entry.Trove:Clean()
	entry.Creatures = {}
end

-- Monta as peças do bichinho, respeitando o limite total de peças (MAX_CRITTER_PARTS).
local function buildCritterVisual(entry)
	if entry.Built or quality <= 1 or not ambientFolder or not entry.Anchor:IsDescendantOf(workspace) then
		return
	end
	local spec = CRITTERS[entry.Kind]
	local builder = CRITTER_BUILDERS[entry.Kind]
	if not spec or not builder then
		return
	end
	local count = entry.Count
	if spec.Parts > 0 then
		local fit = math.floor((MAX_CRITTER_PARTS - critterPartsUsed) / spec.Parts)
		count = math.min(count, fit)
		if count < 1 then
			return -- sem espaço agora (tenta de novo quando outro bichinho sumir)
		end
	end
	entry.Creatures = {}
	local ok, err = pcall(builder, entry, count)
	if not ok then
		warn("[AmbientController] Não deu para criar o bichinho " .. entry.Kind .. ": " .. tostring(err))
		entry.Trove:Clean()
		entry.Creatures = {}
		return
	end
	entry.Built = true
	entry.PartCount = spec.Parts * count
	critterPartsUsed += entry.PartCount
end

-- Cria o que falta (dentro do limite) ou apaga tudo na qualidade baixa.
local function refreshCritters()
	for _, entry in ipairs(critterOrder) do
		if quality <= 1 then
			destroyCritterVisual(entry)
		else
			buildCritterVisual(entry)
		end
	end
end

local function addCritter(instance)
	if critterEntries[instance] then
		return
	end
	local kind = instance:GetAttribute("Kind")
	local spec = type(kind) == "string" and CRITTERS[kind] or nil
	if not spec then
		return
	end
	if kind ~= "Pet" and not instance:IsA("BasePart") then
		return -- a âncora dos bichinhos é uma peça
	end
	local count = math.floor(finiteNumber(instance:GetAttribute("Count"), spec.Count))
	local entry = {
		Anchor = instance,
		Kind = kind,
		Radius = positiveNumber(instance:GetAttribute("Radius"), spec.Radius),
		Count = math.clamp(count, 1, MAX_CRITTER_COUNT),
		Range = if spec.Sky then SKY_CRITTER_DISTANCE else CRITTER_DISTANCE,
		Phase = rng:NextNumber(0, TWO_PI),
		Creatures = {},
		Trove = Trove.new(),
		Built = false,
		Active = false,
		PartCount = 0,
		Removed = false,
	}
	critterEntries[instance] = entry
	table.insert(critterOrder, entry)
	buildCritterVisual(entry)
end

local function removeCritter(instance)
	local entry = critterEntries[instance]
	if not entry then
		return
	end
	critterEntries[instance] = nil
	local index = table.find(critterOrder, entry)
	if index then
		table.remove(critterOrder, index)
	end
	entry.Removed = true
	destroyCritterVisual(entry)
	-- Sobrou espaço no limite de peças: outros bichinhos que ficaram de fora podem aparecer.
	refreshCritters()
end

-------------------------------------------------------------------------------
-- Aurora: AmbientAurora
-------------------------------------------------------------------------------

-- Transparência da aurora com "alpha" (0 = invisível, 1 = como o builder fez).
local function fadeSequence(original, alpha)
	local points = {}
	for _, point in ipairs(original.Keypoints) do
		local value = 1 - (1 - point.Value) * alpha
		table.insert(points, NumberSequenceKeypoint.new(point.Time, math.clamp(value, 0, 1), point.Envelope * alpha))
	end
	return NumberSequence.new(points)
end

local function applyAuroraBeams(beams, alpha)
	for _, info in ipairs(beams) do
		local beam = info.Beam
		if beam.Parent then
			if alpha > 0 then
				beam.Transparency = fadeSequence(info.Transparency, alpha)
				beam.Enabled = true
			else
				beam.Transparency = info.Transparency
				beam.Enabled = info.Enabled
			end
		end
	end
end

-- Nuvens mais abertas enquanto a aurora aparece (só neste cliente).
local function applyAuroraClouds(alpha)
	if alpha > 0 and not cloudState then
		local terrain = workspace:FindFirstChildOfClass("Terrain")
		local clouds = terrain and terrain:FindFirstChildOfClass("Clouds")
		if clouds then
			cloudState = { Clouds = clouds, Cover = clouds.Cover }
		end
	end
	if cloudState then
		local clouds = cloudState.Clouds
		if clouds.Parent then
			local cover = cloudState.Cover
			clouds.Cover = cover + (math.min(cover, AURORA_CLOUD_COVER) - cover) * alpha
		end
		if alpha <= 0 then
			cloudState = nil
		end
	end
end

local function addAurora(instance)
	if auroras[instance] then
		return
	end
	local beams = {}
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("Beam") then
			table.insert(beams, { Beam = descendant, Transparency = descendant.Transparency, Enabled = descendant.Enabled })
		end
	end
	if instance:IsA("Beam") then
		table.insert(beams, { Beam = instance, Transparency = instance.Transparency, Enabled = instance.Enabled })
	end
	auroras[instance] = beams
	if auroraAlpha > 0 then
		applyAuroraBeams(beams, auroraAlpha)
	end
end

local function removeAurora(instance)
	local beams = auroras[instance]
	if not beams then
		return
	end
	auroras[instance] = nil
	applyAuroraBeams(beams, 0)
end

local function stepAurora(dt)
	if auroraAlpha == auroraTarget then
		return
	end
	local stepSize = dt / AURORA_FADE_TIME
	if auroraTarget > auroraAlpha then
		auroraAlpha = math.min(auroraTarget, auroraAlpha + stepSize)
	else
		auroraAlpha = math.max(auroraTarget, auroraAlpha - stepSize)
	end
	for _, beams in pairs(auroras) do
		applyAuroraBeams(beams, auroraAlpha)
	end
	applyAuroraClouds(auroraAlpha)
end

-------------------------------------------------------------------------------
-- Sons de lugar: AmbientSound
-------------------------------------------------------------------------------

-- Pergunta ao UIKit qual áudio a vaga usa (id, volume, velocidade). nil = sem áudio ainda.
local function resolveSpotSound(key)
	local resolver = UIKit.ResolveSound
	if type(resolver) ~= "function" then
		return nil
	end
	local ok, soundId, volume, speed = pcall(resolver, key)
	if not ok or type(soundId) ~= "string" or soundId == "" then
		return nil
	end
	return soundId, finiteNumber(volume, 0.5), positiveNumber(speed, 1)
end

-- Grupo de volume "Ambient" (segue o volume de ambiente das Configurações).
local function getAmbientGroup()
	local getter = UIKit.GetSoundGroup
	if type(getter) ~= "function" then
		return nil
	end
	local ok, group = pcall(getter, SOUND_GROUP)
	if ok and typeof(group) == "Instance" and group:IsA("SoundGroup") then
		return group
	end
	return nil
end

local function createSpotSound(spot)
	local anchor = spot.Anchor
	local key = anchor:GetAttribute("SoundKey")
	if type(key) ~= "string" or key == "" then
		return nil
	end
	local soundId, volume, speed = resolveSpotSound(key)
	if not soundId then
		return nil
	end
	local parent = anchor
	if parent:IsA("Model") then
		parent = parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart", true)
	end
	if not parent or not (parent:IsA("BasePart") or parent:IsA("Attachment")) then
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = "AmbientSpot_" .. key
	sound.SoundId = soundId
	sound.Looped = true
	sound.PlaybackSpeed = speed
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = SOUND_ROLLOFF_MIN
	sound.RollOffMaxDistance = SOUND_ROLLOFF_MAX
	local group = getAmbientGroup()
	if group then
		sound.SoundGroup = group
		sound.Volume = volume
	else
		-- Sem grupo de volume: usa direto o volume de ambiente das Configurações.
		local ok, settings = pcall(StateController.GetSettings)
		local ambientVolume = ok and type(settings) == "table" and finiteNumber(settings.AmbientVolume, 0.6) or 0.6
		sound.Volume = volume * math.clamp(ambientVolume, 0, 1)
	end
	sound.Parent = parent
	sound:Play()
	return sound
end

local function destroySpotSound(spot)
	local sound = spot.Sound
	spot.Sound = nil
	if sound then
		sound:Destroy()
	end
end

local function addSoundSpot(instance)
	if soundSpots[instance] then
		return
	end
	soundSpots[instance] = { Anchor = instance, Sound = nil, NextTry = 0 }
end

local function removeSoundSpot(instance)
	local spot = soundSpots[instance]
	if not spot then
		return
	end
	soundSpots[instance] = nil
	destroySpotSound(spot)
end

-- 4x por segundo: cria o som perto, apaga longe (e tenta de novo a cada 5 s sem áudio).
local function updateSoundSpots(cameraPosition, now)
	local createDistance = if quality <= 1 then SOUND_CREATE_DISTANCE_LOW else SOUND_CREATE_DISTANCE
	local destroyDistance = if quality <= 1 then SOUND_DESTROY_DISTANCE_LOW else SOUND_DESTROY_DISTANCE
	for instance, spot in pairs(soundSpots) do
		local position = positionOf(instance)
		local distance = position and (position - cameraPosition).Magnitude or math.huge
		if spot.Sound then
			if distance > destroyDistance or spot.Sound.Parent == nil then
				destroySpotSound(spot)
			end
		elseif distance <= createDistance and now >= spot.NextTry then
			spot.NextTry = now + SOUND_RETRY
			local ok, sound = pcall(createSpotSound, spot)
			if ok and sound then
				spot.Sound = sound
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Clima que segue a câmera
-------------------------------------------------------------------------------

local function weatherRate(preset)
	if quality <= 1 then
		return preset.LowRate or preset.Rate * 0.5
	end
	return preset.Rate
end

local function destroyWeather()
	local current = weather
	weather = nil
	if current then
		current.Part:Destroy()
	end
end

local function recenterWeather(camera)
	local preset = weather.Preset
	local reference = if preset.FromCamera then camera.CFrame.Position else camera.Focus.Position
	weather.Part.CFrame = CFrame.new(reference + Vector3.new(0, preset.Height, 0))
end

-- Vento (+ rajadas) empurrando as partículas do clima.
local function updateWeatherWind(dt, now)
	local preset = weather.Preset
	if preset.Gusts then
		if now >= weather.NextGust then
			weather.GustTarget = 1 + rng:NextNumber(-0.6, 0.6)
			weather.NextGust = now + rng:NextNumber(8, 15)
		end
		weather.Gust += (weather.GustTarget - weather.Gust) * math.min(1, dt * 0.9)
	end
	local acceleration = windFlat * preset.Wind * weather.Gust
	local applied = weather.AppliedAcceleration
	if not applied or (applied - acceleration).Magnitude > 0.02 then
		weather.Emitter.Acceleration = acceleration
		weather.AppliedAcceleration = acceleration
	end
end

local function buildWeather()
	destroyWeather()
	local preset = mapType and WEATHER[mapType] or nil
	if not preset or not ambientFolder then
		return
	end
	if preset.NeedsClientSnow then
		local snowPart = findSnowPart()
		if not (snowPart and snowPart:GetAttribute("ClientSnow") == true) then
			return -- o servidor ainda cuida da neve (ou o mapa não tem neve)
		end
	end

	local part = makeClientPart("Weather_" .. preset.Name, preset.Box)
	part.Transparency = 1
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = preset.Name
	for key, value in pairs(preset.Props) do
		emitter[key] = value
	end
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Rate = weatherRate(preset)

	weather = {
		Part = part,
		Emitter = emitter,
		Preset = preset,
		Gust = 1,
		GustTarget = 1,
		NextGust = 0,
		AppliedAcceleration = nil,
	}
	local camera = workspace.CurrentCamera
	if camera then
		recenterWeather(camera)
	end
	updateWeatherWind(0, os.clock())
	emitter.Parent = part
	part.Parent = ambientFolder
end

-------------------------------------------------------------------------------
-- Mapa atual
-------------------------------------------------------------------------------

local queueRebind -- definida logo abaixo (rebindMap e queueRebind usam uma à outra)

local function rebindMap()
	if not started then
		return
	end
	mapTrove:Clean()
	destroyWeather()

	local map = workspace:FindFirstChild(MAP_NAME)
	currentMap = map
	mapType = computeMapType(map)

	if map then
		mapTrove:Connect(map:GetAttributeChangedSignal("MapId"), queueRebind)
		if mapType == "Winter" then
			local snowPart = findSnowPart()
			if snowPart then
				mapTrove:Connect(snowPart:GetAttributeChangedSignal("ClientSnow"), queueRebind)
			else
				mapTrove:Connect(map.DescendantAdded, function(descendant)
					if descendant.Name == SNOW_PART_NAME then
						queueRebind()
					end
				end)
			end
		end
	end
	buildWeather()
end

-- Junta vários pedidos de "remontar" num só (no fim do quadro).
queueRebind = function()
	if rebindQueued or not started then
		return
	end
	rebindQueued = true
	task.defer(function()
		rebindQueued = false
		local ok, err = pcall(rebindMap)
		if not ok then
			warn("[AmbientController] Erro ao trocar o ambiente do mapa: " .. tostring(err))
		end
	end)
end

-------------------------------------------------------------------------------
-- Passadas (rápida: 30 Hz; lenta: 4 Hz)
-------------------------------------------------------------------------------

local function fastPass(dt)
	local t = os.clock() - clockOrigin

	for index = 1, activeMoverCount do
		local mover = activeMovers[index]
		if not mover.Removed then
			if mover.Dirty then
				rebuildMoverParts(mover)
			end
			local pivot = moverPivot(mover, t)
			local offsets = mover.Offsets
			for partIndex, part in ipairs(mover.Parts) do
				push(part, pivot * offsets[partIndex])
			end
		end
	end

	for index = 1, activeCritterCount do
		local entry = activeCritters[index]
		if entry.Built and not entry.Removed then
			local updater = CRITTER_UPDATERS[entry.Kind]
			if updater then
				updater(entry, t, dt)
			end
		end
	end

	flushBulk()

	for index = 1, activeFlickerCount do
		local flicker = activeFlickers[index]
		if not flicker.Removed then
			stepFlicker(flicker, t)
		end
	end

	stepAurora(dt)
end

local function slowPass(dt, camera)
	local now = os.clock()
	local cameraPosition = camera.CFrame.Position

	-- Vento atual (replicado do servidor).
	local wind = workspace.GlobalWind
	windFlat = Vector3.new(wind.X, 0, wind.Z)
	windDirection = if windFlat.Magnitude > 0.1 then windFlat.Unit else Vector3.xAxis

	-- Quem se mexe (só perto da câmera).
	local count = 0
	for _, mover in pairs(movers) do
		local active = (mover.Base.Position - cameraPosition).Magnitude <= mover.MaxDistance
		mover.Active = active
		if active then
			count += 1
			activeMovers[count] = mover
		end
	end
	for index = count + 1, activeMoverCount do
		activeMovers[index] = nil
	end
	activeMoverCount = count

	-- Luzes que tremem (longe: volta ao brilho original).
	count = 0
	for instance, flicker in pairs(flickers) do
		local position = positionOf(instance)
		local active = position ~= nil and (position - cameraPosition).Magnitude <= FLICKER_DISTANCE
		if active then
			count += 1
			activeFlickers[count] = flicker
		elseif flicker.Active then
			restoreFlicker(flicker)
		end
		flicker.Active = active
	end
	for index = count + 1, activeFlickerCount do
		activeFlickers[index] = nil
	end
	activeFlickerCount = count

	-- Bichinhos perto.
	count = 0
	for _, entry in ipairs(critterOrder) do
		local center = entry.Center or positionOf(entry.Anchor)
		local active = entry.Built and center ~= nil and (center - cameraPosition).Magnitude <= entry.Range
		entry.Active = active
		if active then
			count += 1
			activeCritters[count] = entry
		end
	end
	for index = count + 1, activeCritterCount do
		activeCritters[index] = nil
	end
	activeCritterCount = count

	cullEmitters(cameraPosition)
	updateSoundSpots(cameraPosition, now)

	-- Aurora: aparece quando a neblina está fraca.
	if next(auroras) ~= nil then
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		auroraTarget = if atmosphere and atmosphere.Density <= AURORA_DENSITY then 1 else 0
	else
		auroraTarget = 0
	end

	-- Clima segue a câmera.
	if weather then
		if weather.Part.Parent == nil then
			weather = nil
		else
			recenterWeather(camera)
			updateWeatherWind(dt, now)
		end
	end
end

local function onRenderStep(dt)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	fastAccumulator += dt
	slowAccumulator += dt
	if slowAccumulator >= SLOW_STEP then
		local elapsed = slowAccumulator
		slowAccumulator = 0
		slowPass(elapsed, camera)
	end
	if fastAccumulator >= FAST_STEP then
		local elapsed = math.min(fastAccumulator, MAX_FAST_GAP)
		fastAccumulator = 0
		fastPass(elapsed)
	end
end

-------------------------------------------------------------------------------
-- Tags (CollectionService)
-------------------------------------------------------------------------------

-- Liga uma tag: chama onAdded para cada instância com a tag DENTRO do workspace
-- (as que estão fora, como moldes no ReplicatedStorage, esperam entrar no workspace)
-- e onRemoved quando a tag sai ou a instância é apagada.
local function watchTag(tag, onAdded, onRemoved)
	local pending = {} -- [Instance] = conexão esperando a instância entrar no workspace

	local function safeCall(fn, instance)
		local ok, err = pcall(fn, instance)
		if not ok then
			warn(("[AmbientController] Erro na tag %s (%s): %s"):format(tag, instance:GetFullName(), tostring(err)))
		end
	end

	local function add(instance)
		if instance:IsDescendantOf(workspace) then
			safeCall(onAdded, instance)
		elseif not pending[instance] then
			pending[instance] = instance.AncestryChanged:Connect(function()
				if instance:IsDescendantOf(workspace) then
					local connection = pending[instance]
					pending[instance] = nil
					if connection then
						connection:Disconnect()
					end
					if instance:HasTag(tag) then
						safeCall(onAdded, instance)
					end
				end
			end)
		end
	end

	local function remove(instance)
		local connection = pending[instance]
		if connection then
			pending[instance] = nil
			connection:Disconnect()
		end
		safeCall(onRemoved, instance)
	end

	lifeTrove:Connect(CollectionService:GetInstanceAddedSignal(tag), add)
	lifeTrove:Connect(CollectionService:GetInstanceRemovedSignal(tag), remove)
	lifeTrove:Add(function()
		for _, connection in pairs(pending) do
			connection:Disconnect()
		end
		table.clear(pending)
	end)
	for _, instance in ipairs(CollectionService:GetTagged(tag)) do
		add(instance)
	end
end

-------------------------------------------------------------------------------
-- Qualidade dos efeitos
-------------------------------------------------------------------------------

local function readQuality()
	local ok, level = pcall(StateController.GetEffectsQuality)
	return if ok then math.clamp(math.floor(finiteNumber(level, 2)), 1, 3) else 2
end

local function onQualityChanged()
	quality = readQuality()
	-- Partículas: a passada lenta reaplica a taxa certa.
	for _, entry in pairs(emitterEntries) do
		if entry.Emitter.Parent and entry.AppliedRate ~= nil then
			entry.Emitter.Rate = entry.BaseRate * rateScale()
			entry.AppliedRate = entry.Emitter.Rate
		end
	end
	refreshCritters()
	if weather then
		weather.Emitter.Rate = weatherRate(weather.Preset)
	end
end

-------------------------------------------------------------------------------
-- API
-------------------------------------------------------------------------------

function AmbientController.Init()
	-- Nada que espere: só zera o estado.
	quality = 2
	mapType = nil
	clockOrigin = os.clock()
end

function AmbientController.Start()
	if started then
		return
	end
	started = true
	lifeTrove = Trove.new()
	mapTrove = Trove.new()
	lifeTrove:Add(mapTrove)
	quality = readQuality()

	ambientFolder = Instance.new("Folder")
	ambientFolder.Name = FOLDER_NAME
	ambientFolder.Parent = workspace
	lifeTrove:Add(ambientFolder)

	-- Movimento: as três tags vão para o mesmo "refreshMover" (uma coisa pode ter várias).
	for _, tag in ipairs(MOVER_TAGS) do
		watchTag(tag, refreshMover, refreshMover)
	end
	watchTag(TAG_FLICKER, addFlicker, removeFlicker)
	watchTag(TAG_EMITTER, addEmitterOwner, removeEmitterOwner)
	watchTag(TAG_CRITTER, addCritter, removeCritter)
	watchTag(TAG_AURORA, addAurora, removeAurora)
	watchTag(TAG_SOUND, addSoundSpot, removeSoundSpot)

	-- Qualidade dos efeitos mudou (Configurações ou gráfico do Roblox).
	local qualitySignal = StateController.QualityChanged
	if type(qualitySignal) == "table" and type(qualitySignal.Connect) == "function" then
		lifeTrove:Add(qualitySignal:Connect(function()
			local ok, err = pcall(onQualityChanged)
			if not ok then
				warn("[AmbientController] Erro ao mudar a qualidade: " .. tostring(err))
			end
		end))
	end

	-- O mapa troca (Lobby -> partida no Studio, ou outro mapa): remonta clima e vigias.
	lifeTrove:Connect(workspace.ChildAdded, function(child)
		if child.Name == MAP_NAME then
			queueRebind()
		end
	end)
	lifeTrove:Connect(workspace.ChildRemoved, function(child)
		if child.Name == MAP_NAME then
			queueRebind()
		end
	end)
	lifeTrove:Connect(workspace:GetAttributeChangedSignal("Role"), function()
		queueRebind()
	end)

	-- Um único RenderStepped para tudo (erros aparecem no máximo 3 vezes no Output).
	lifeTrove:Connect(RunService.RenderStepped, function(dt)
		local ok, err = pcall(onRenderStep, dt)
		if not ok then
			stepErrors += 1
			if stepErrors <= 3 then
				warn("[AmbientController] Erro no quadro: " .. tostring(err))
			end
		end
	end)

	rebindMap()
end

-- "Lobby", "Meadow", "Winter", "Desert" ou nil (ainda sem mapa).
function AmbientController.GetMapType()
	return mapType
end

return AmbientController
