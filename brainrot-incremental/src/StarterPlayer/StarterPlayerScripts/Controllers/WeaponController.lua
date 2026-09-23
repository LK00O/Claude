-- WeaponController (só na partida): a arma do jogador.
--
-- O que ele faz:
--   * Atira segurando o botão: mouse esquerdo, R2 do controle ou o botão "Atirar" do celular.
--     Não atira com janela aberta, mouse solto (Alt), colocando torreta, superaquecido ou na cena final.
--   * Cadência: um tiro a cada 1 / stats.FireRate segundos.
--   * Leque: stats.Projectiles balas espalhadas na horizontal (abertura total
--     min(Spread × (n - 1), 40) graus) + um desvio aleatório pequeno.
--   * Manda ao servidor Net.Fire("Fire", origem = câmera, direções, shotId). O SERVIDOR é quem
--     decide se acertou e quanto de dano deu; aqui é só o visual imediato.
--   * Visual local: arma na câmera (viewmodel feito de Parts, na cor da skin), coice,
--     clarão no cano, som, tracer até onde a bala bateu (raycast local) e CameraController.Kick.
--   * Calor (Deserto): prevê o calor localmente para travar na hora, e respeita Heat.Overheated
--     do servidor. O cano vai ficando vermelho e solta fumaça quando superaquece.
--   * HitConfirm do servidor: hitmarker (HUDController.ShowHitmarker) e números de dano
--     (se a configuração DamageNumbers estiver ligada) via EffectsController.
--
-- API pública:
--   WeaponController.IsFiring() -> boolean
--   WeaponController.GetMuzzlePosition() -> Vector3?

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")
local Cosmetics = require(Config:WaitForChild("Cosmetics"))
local GameConfig = require(Config:WaitForChild("Game"))
local Maps = require(Config:WaitForChild("Maps"))
local Weapons = require(Config:WaitForChild("Weapons"))
local Formulas = require(Util:WaitForChild("Formulas"))
local Net = require(Util:WaitForChild("Net"))
local Trove = require(Util:WaitForChild("Trove"))

local Controllers = script.Parent
local UIKit = require(Controllers.Parent:WaitForChild("UI"):WaitForChild("UIKit"))
local StateController = require(Controllers:WaitForChild("StateController"))

local WeaponController = {}

-------------------------------------------------------------------------------
-- Constantes técnicas
-------------------------------------------------------------------------------
local RENDER_STEP_NAME = "BrainrotWeapon"
-- Roda depois da câmera (Camera + 1), para a arma "grudar" certinho nela.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2

local MAX_FAN_DEGREES = 40 -- abertura máxima do leque
local RANDOM_DEVIATION_DEGREES = 0.6 -- desvio aleatório de cada bala
local MAX_SHOTS_PER_FRAME = 3 -- se o jogo engasgar, no máximo 3 tiros de uma vez
local HEAT_RESUME_FRACTION = 0.3 -- superaquecida volta a atirar quando esfria para 30%
local FLASH_DURATION = 0.05
local HIT_SOUND_INTERVAL = 0.06
local SHOOT_SOUND_INTERVAL = 0.045
local SHOOT_SOUND_POOL_SIZE = 4

-- Posição da arma em relação à câmera (direita, embaixo, na frente).
local VIEWMODEL_OFFSET = CFrame.new(0.85, -0.78, -1.45)
local ROTATE_Y_90 = CFrame.Angles(0, math.rad(90), 0) -- deita o cilindro no eixo Z (cano)

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local HOT_COLOR = Color3.fromRGB(255, 90, 30)
local DEFAULT_SKIN_COLOR = Color3.fromRGB(255, 204, 153)
local FLASH_COLOR = Color3.fromRGB(255, 236, 160)

-- "Sensação" de cada arma: coice da câmera, recuo da arma, largura do tracer e clarão.
local WEAPON_FEEL = {
	SpaghettiPistol = { Kick = 1.2, Recoil = 0.18, RecoilRotation = 0.12, TracerWidth = 0.12, FlashSize = 0.5 },
	GelatoCannon = { Kick = 3.2, Recoil = 0.35, RecoilRotation = 0.3, TracerWidth = 0.55, FlashSize = 0.9 },
	TralaleroMinigun = { Kick = 0.35, Recoil = 0.06, RecoilRotation = 0.035, TracerWidth = 0.1, FlashSize = 0.45 },
}
local DEFAULT_FEEL = { Kick = 1, Recoil = 0.15, RecoilRotation = 0.1, TracerWidth = 0.12, FlashSize = 0.5 }

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------
local player = Players.LocalPlayer
local rng = Random.new()
local mainTrove = Trove.new()
local characterTrove = Trove.new()
local started = false

local weaponId = nil
local weaponDef = nil
local feel = DEFAULT_FEEL
local cachedStats = nil
local fallbackStats = nil
local fallbackMapId = nil

local humanoid = nil
local rootPart = nil
local armColor = DEFAULT_SKIN_COLOR

-- Entrada.
local mouseHeld = false
local gamepadHeld = false
local firing = false -- atirou neste frame (ou está segurando e pode atirar)
local blockedFeedbackGiven = false -- já avisou "superaquecida" neste aperto?

-- Tiros.
local nextShotTime = 0
local shotId = 0

-- Calor previsto no cliente (o servidor manda o valor "oficial" em Heat).
local localHeat = 0
local localOverheated = false
local serverHeat = nil -- {Value, Capacity, Overheated}

-- Configurações.
local showDamageNumbers = true
local sfxVolume = 0.7
local skinDef = Cosmetics.ById.Classic

-- Viewmodel.
local viewmodel = nil
local viewmodelVisible = false
local lastCameraRotation = CFrame.new()
local sway = Vector2.zero
local bobTime = 0
local bobAmount = 0
local recoilZ = 0
local recoilRotation = 0
local lowerAlpha = 0
local spinSpeed = 0
local spinAngle = 0
local flashTimeLeft = 0
local muzzleWorld = nil -- CFrame do cano no mundo (atualizado todo frame)
local lastColorKey = ""

-- Sons.
local shootSounds = {}
local shootSoundIndex = 0
local lastShootSound = 0
local lastHitSound = 0

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
	warn("[WeaponController] Não foi possível carregar " .. name .. ": " .. tostring(result))
	return nil
end

-- Chama controller.fn(...) com proteção; devolve o resultado (ou nil se não deu).
local function callController(name, fnName, ...)
	local controller = Ctrl(name)
	local fn = controller and controller[fnName]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result = pcall(fn, ...)
	if ok then
		return result
	end
	return nil
end

local function isModalOpen()
	local ok, result = pcall(UIKit.IsAnyModalOpen)
	return ok and result == true
end

-------------------------------------------------------------------------------
-- Stats e arma atual
-------------------------------------------------------------------------------
local function getMapId()
	local match = StateController.Get("Match")
	return if type(match) == "table" then match.MapId else nil
end

-- Stats do jogador (do StateController); se ainda não chegaram, calcula os de base do mapa.
local function getStats()
	if type(cachedStats) == "table" then
		return cachedStats
	end
	local ok, stats = pcall(StateController.GetStats)
	if ok and type(stats) == "table" then
		cachedStats = stats
		return stats
	end
	local mapId = getMapId()
	if not mapId or not Maps[mapId] then
		return nil
	end
	if fallbackMapId ~= mapId then
		fallbackStats = Formulas.ComputeStats(mapId, {}, {}, {}, {})
		fallbackMapId = mapId
	end
	return fallbackStats
end

-------------------------------------------------------------------------------
-- Cores (skin equipada + tema da arma)
-------------------------------------------------------------------------------
local function refreshProfile()
	local profile = StateController.Get("Profile")
	if type(profile) ~= "table" then
		return
	end
	local saved = profile.Settings
	if type(saved) == "table" then
		showDamageNumbers = saved.DamageNumbers ~= false
		sfxVolume = math.clamp(tonumber(saved.SfxVolume) or 0.7, 0, 1)
	end
	local equipped = type(profile.Cosmetics) == "table" and profile.Cosmetics.Equipped or nil
	skinDef = Cosmetics.ById[equipped] or Cosmetics.ById.Classic
	lastColorKey = "" -- força repintar a arma
	for _, sound in ipairs(shootSounds) do
		sound.Volume = sfxVolume
	end
end

-- Cor de arco-íris que muda com o tempo (skin "Arco-íris").
local function rainbowColor(offset)
	return Color3.fromHSV((os.clock() * 0.25 + (offset or 0)) % 1, 0.75, 1)
end

-- Cores atuais: corpo (skin), detalhe (tema da arma ou skin clareada) e tracer.
local function getColors()
	local skin = skinDef or Cosmetics.ById.Classic
	local isClassic = skin == nil or skin.Id == "Classic"
	local body = if skin then skin.GunColor else Color3.fromRGB(70, 70, 78)
	local accent
	local tracer
	if isClassic and weaponDef then
		-- Skin clássica: detalhes e tracer com o "tema" da arma do ato.
		accent = weaponDef.GunColor
		tracer = weaponDef.TracerColor
	else
		accent = body:Lerp(WHITE, 0.35)
		tracer = if skin then skin.TracerColor else Color3.fromRGB(255, 225, 120)
	end
	if skin and skin.Rainbow then
		body = rainbowColor(0)
		accent = rainbowColor(0.33)
		tracer = rainbowColor(0.66)
	end
	return body, accent, tracer
end

-------------------------------------------------------------------------------
-- Viewmodel (a arma que aparece na tela), feita de Parts presas à câmera
-------------------------------------------------------------------------------
local function destroyViewmodel()
	if viewmodel then
		viewmodel.Model:Destroy()
		viewmodel = nil
	end
	viewmodelVisible = false
end

-- Cria uma peça da arma. role decide a cor: "Body", "Dark", "Accent", "Barrel", "Hand" ou "Fixed".
local function addPiece(vm, role, className, shape, size, offset, color, spin, material)
	local part = Instance.new(className)
	part.Name = role
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = material or Enum.Material.SmoothPlastic
	if shape and part:IsA("Part") then
		part.Shape = shape
	end
	part.Size = size
	part.Color = color or WHITE
	part.Parent = vm.Model
	table.insert(vm.Pieces, { Part = part, Offset = offset, Role = role, Spin = spin == true })
	return part
end

-- Mão e antebraço do personagem segurando a arma.
local function addHand(vm, gripOffset)
	addPiece(vm, "Hand", "Part", Enum.PartType.Block, Vector3.new(0.3, 0.3, 0.36), gripOffset * CFrame.new(0.02, -0.06, 0.06))
	addPiece(
		vm,
		"Hand",
		"Part",
		Enum.PartType.Block,
		Vector3.new(0.26, 0.26, 1.1),
		gripOffset * CFrame.new(0.1, -0.2, 0.6) * CFrame.Angles(math.rad(22), math.rad(8), 0)
	)
end

-- Pistola de Espaguete: pistolinha com cano de macarrão, almôndega de mira e fios pendurados.
local function buildSpaghettiPistol(vm)
	local grip = CFrame.new(0, -0.36, 0.08) * CFrame.Angles(math.rad(-14), 0, 0)
	addPiece(vm, "Body", "Part", Enum.PartType.Block, Vector3.new(0.3, 0.34, 1.05), CFrame.new(0, 0, -0.35))
	addPiece(vm, "Accent", "Part", Enum.PartType.Block, Vector3.new(0.26, 0.1, 0.95), CFrame.new(0, 0.21, -0.38))
	addPiece(vm, "Dark", "Part", Enum.PartType.Block, Vector3.new(0.26, 0.6, 0.32), grip)
	addPiece(vm, "Dark", "Part", Enum.PartType.Block, Vector3.new(0.06, 0.18, 0.24), CFrame.new(0, -0.22, -0.3))
	addPiece(vm, "Barrel", "Part", Enum.PartType.Cylinder, Vector3.new(0.45, 0.19, 0.19), CFrame.new(0, 0.04, -1.02) * ROTATE_Y_90)
	addPiece(vm, "Fixed", "Part", Enum.PartType.Ball, Vector3.new(0.24, 0.24, 0.24), CFrame.new(0, 0.33, -0.08), Color3.fromRGB(150, 80, 50))
	local pasta = Color3.fromRGB(240, 205, 110)
	addPiece(
		vm,
		"Fixed",
		"Part",
		Enum.PartType.Cylinder,
		Vector3.new(0.42, 0.05, 0.05),
		CFrame.new(0.07, -0.14, -0.95) * CFrame.Angles(0, 0, math.rad(80)),
		pasta
	)
	addPiece(
		vm,
		"Fixed",
		"Part",
		Enum.PartType.Cylinder,
		Vector3.new(0.34, 0.05, 0.05),
		CFrame.new(-0.06, -0.1, -0.82) * CFrame.Angles(0, 0.3, math.rad(70)),
		pasta
	)
	addHand(vm, grip)
	vm.MuzzleOffset = CFrame.new(0, 0.04, -1.3)
end

-- Canhão de Gelato: tubo largo com casquinha e bolas de sorvete em cima.
local function buildGelatoCannon(vm)
	local grip = CFrame.new(0, -0.4, -0.1) * CFrame.Angles(math.rad(-10), 0, 0)
	addPiece(vm, "Body", "Part", Enum.PartType.Cylinder, Vector3.new(1.25, 0.55, 0.55), CFrame.new(0, 0.05, -0.55) * ROTATE_Y_90)
	addPiece(vm, "Barrel", "Part", Enum.PartType.Cylinder, Vector3.new(0.14, 0.7, 0.7), CFrame.new(0, 0.05, -1.18) * ROTATE_Y_90)
	addPiece(vm, "Accent", "Part", Enum.PartType.Cylinder, Vector3.new(0.12, 0.6, 0.6), CFrame.new(0, 0.05, 0.08) * ROTATE_Y_90)
	addPiece(
		vm,
		"Fixed",
		"Part",
		Enum.PartType.Block,
		Vector3.new(0.34, 0.34, 0.34),
		CFrame.new(0, 0.42, -0.35) * CFrame.Angles(0, math.rad(45), math.rad(45)),
		Color3.fromRGB(215, 160, 90)
	)
	addPiece(vm, "Fixed", "Part", Enum.PartType.Ball, Vector3.new(0.5, 0.5, 0.5), CFrame.new(0, 0.68, -0.35), Color3.fromRGB(255, 170, 215))
	addPiece(vm, "Fixed", "Part", Enum.PartType.Ball, Vector3.new(0.36, 0.36, 0.36), CFrame.new(0.12, 0.88, -0.3), Color3.fromRGB(160, 240, 200))
	addPiece(vm, "Fixed", "Part", Enum.PartType.Ball, Vector3.new(0.13, 0.13, 0.13), CFrame.new(-0.02, 1.02, -0.37), Color3.fromRGB(230, 30, 60))
	addPiece(vm, "Dark", "Part", Enum.PartType.Block, Vector3.new(0.24, 0.55, 0.3), grip)
	addHand(vm, grip)
	vm.MuzzleOffset = CFrame.new(0, 0.05, -1.32)
end

-- Metralhadora de Tralalero: 6 canos girando, barbatana de tubarão e um tênis (claro).
local function buildTralaleroMinigun(vm)
	local grip = CFrame.new(0, -0.4, 0.05) * CFrame.Angles(math.rad(-8), 0, 0)
	addPiece(vm, "Body", "Part", Enum.PartType.Block, Vector3.new(0.5, 0.45, 0.85), CFrame.new(0, 0, -0.3))
	addPiece(vm, "Accent", "WedgePart", nil, Vector3.new(0.1, 0.36, 0.5), CFrame.new(0, 0.4, -0.3))
	local barrelCenterY = 0.02
	for index = 1, 6 do
		local angle = (index - 1) / 6 * math.pi * 2
		addPiece(
			vm,
			"Barrel",
			"Part",
			Enum.PartType.Cylinder,
			Vector3.new(1.05, 0.1, 0.1),
			CFrame.new(math.cos(angle) * 0.14, barrelCenterY + math.sin(angle) * 0.14, -1.2) * ROTATE_Y_90,
			nil,
			true
		)
	end
	addPiece(vm, "Dark", "Part", Enum.PartType.Cylinder, Vector3.new(0.08, 0.42, 0.42), CFrame.new(0, barrelCenterY, -1.62) * ROTATE_Y_90, nil, true)
	addPiece(vm, "Dark", "Part", Enum.PartType.Cylinder, Vector3.new(0.1, 0.4, 0.4), CFrame.new(0, barrelCenterY, -0.78) * ROTATE_Y_90, nil, true)
	addPiece(vm, "Fixed", "Part", Enum.PartType.Block, Vector3.new(0.22, 0.12, 0.34), CFrame.new(0, -0.28, -0.55), WHITE)
	addPiece(vm, "Dark", "Part", Enum.PartType.Block, Vector3.new(0.22, 0.5, 0.28), grip)
	addHand(vm, grip)
	vm.SpinCenter = CFrame.new(0, barrelCenterY, 0)
	vm.MuzzleOffset = CFrame.new(0, barrelCenterY, -1.75)
end

local BUILDERS = {
	SpaghettiPistol = buildSpaghettiPistol,
	GelatoCannon = buildGelatoCannon,
	TralaleroMinigun = buildTralaleroMinigun,
}

local function buildViewmodel()
	destroyViewmodel()
	if not weaponId then
		return
	end

	local model = Instance.new("Model")
	model.Name = "BrainrotViewmodel"
	local vm = {
		Model = model,
		Pieces = {},
		MuzzleOffset = CFrame.new(0, 0, -1.3),
		SpinCenter = nil,
	}
	local builder = BUILDERS[weaponId] or buildSpaghettiPistol
	builder(vm)

	-- Clarão do cano: bolinha neon + luz (invisíveis até atirar) e fumaça (superaquecida).
	local flash = Instance.new("Part")
	flash.Name = "Flash"
	flash.Shape = Enum.PartType.Ball
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Material = Enum.Material.Neon
	flash.Color = FLASH_COLOR
	flash.Size = Vector3.one * feel.FlashSize
	flash.Transparency = 1
	flash.Parent = model

	local light = Instance.new("PointLight")
	light.Color = FLASH_COLOR
	light.Range = 10
	light.Brightness = 0
	light.Shadows = false
	light.Parent = flash

	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Rate = 18
	smoke.Enabled = false
	smoke.Lifetime = NumberRange.new(0.5, 0.9)
	smoke.Speed = NumberRange.new(1, 2)
	smoke.SpreadAngle = Vector2.new(20, 20)
	smoke.Acceleration = Vector3.new(0, 3, 0)
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.7) })
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	smoke.Color = ColorSequence.new(Color3.fromRGB(200, 200, 200))
	smoke.LightInfluence = 0
	smoke.Parent = flash

	vm.Flash = flash
	vm.Light = light
	vm.Smoke = smoke
	viewmodel = vm
	lastColorKey = ""
end

-- Pinta as peças da arma (só quando algo mudou: skin, arco-íris ou calor).
local function paintViewmodel(heatFraction)
	if not viewmodel then
		return
	end
	local body, accent = getColors()
	local key = string.format("%s|%s|%.2f|%s", body:ToHex(), accent:ToHex(), heatFraction, armColor:ToHex())
	if key == lastColorKey then
		return
	end
	lastColorKey = key

	local dark = body:Lerp(BLACK, 0.35)
	local barrel = accent:Lerp(HOT_COLOR, heatFraction)
	for _, piece in ipairs(viewmodel.Pieces) do
		local part = piece.Part
		if piece.Role == "Body" then
			part.Color = body
		elseif piece.Role == "Dark" then
			part.Color = dark
		elseif piece.Role == "Accent" then
			part.Color = accent
		elseif piece.Role == "Barrel" then
			part.Color = barrel
			part.Material = if heatFraction >= 0.8 then Enum.Material.Neon else Enum.Material.SmoothPlastic
		elseif piece.Role == "Hand" then
			part.Color = armColor
		end
	end
end

-------------------------------------------------------------------------------
-- Calor
-------------------------------------------------------------------------------
local function heatCapacity(stats)
	return if stats then tonumber(stats.HeatCapacity) or 0 else 0
end

local function isOverheated()
	if localOverheated then
		return true
	end
	return type(serverHeat) == "table" and serverHeat.Overheated == true
end

-- Fração de calor (0 a 1) para pintar o cano.
local function heatFraction(stats)
	local capacity = heatCapacity(stats)
	if capacity <= 0 then
		return 0
	end
	local value = localHeat
	if type(serverHeat) == "table" and type(serverHeat.Value) == "number" then
		value = math.max(value, serverHeat.Value)
	end
	return math.clamp(value / capacity, 0, 1)
end

local function onHeatChanged(value)
	if type(value) ~= "table" then
		return
	end
	serverHeat = value
	local serverValue = tonumber(value.Value) or 0
	-- O servidor está mais quente que a nossa previsão: acompanha ele.
	if serverValue > localHeat then
		localHeat = serverValue
	end
	if value.Overheated == true then
		localOverheated = true
	end
end

local function coolDown(dt, stats)
	local capacity = heatCapacity(stats)
	if capacity <= 0 then
		localHeat = 0
		localOverheated = false
		return
	end
	local cooling = tonumber(stats.HeatCooling) or 0
	localHeat = math.max(0, localHeat - cooling * dt)
	if localOverheated and localHeat <= capacity * HEAT_RESUME_FRACTION then
		localOverheated = false
	end
end

-------------------------------------------------------------------------------
-- Sons
-------------------------------------------------------------------------------
local function clearShootSounds()
	for _, sound in ipairs(shootSounds) do
		sound:Destroy()
	end
	table.clear(shootSounds)
end

-- Se a arma tem um som próprio (Weapons[x].SoundId), cria alguns Sounds para revezar.
local function buildShootSounds()
	clearShootSounds()
	local soundId = weaponDef and tonumber(weaponDef.SoundId) or 0
	if soundId <= 0 then
		return
	end
	for index = 1, SHOOT_SOUND_POOL_SIZE do
		local sound = Instance.new("Sound")
		sound.Name = "WeaponShot" .. index
		sound.SoundId = "rbxassetid://" .. soundId
		sound.Volume = sfxVolume
		sound.Parent = SoundService
		table.insert(shootSounds, sound)
	end
end

local function playShootSound()
	local t = os.clock()
	if t - lastShootSound < SHOOT_SOUND_INTERVAL then
		return
	end
	lastShootSound = t
	if #shootSounds > 0 then
		shootSoundIndex = shootSoundIndex % #shootSounds + 1
		local sound = shootSounds[shootSoundIndex]
		sound.PlaybackSpeed = rng:NextNumber(0.94, 1.06)
		sound.TimePosition = 0
		sound:Play()
	else
		pcall(UIKit.PlaySound, "Shoot")
	end
end

-------------------------------------------------------------------------------
-- Tiro
-------------------------------------------------------------------------------

-- Sobe na hierarquia até achar o Model de um brainrot (atributo "BrainrotId").
local function findBrainrotModel(instance)
	local current = instance
	while current and current ~= workspace do
		if current:IsA("Model") and current:GetAttribute("BrainrotId") ~= nil then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- O que as balas ignoram (igual ao servidor): personagens, moedas, torretas, efeitos e a arma.
local function buildExcludeList()
	local list = {}
	local camera = workspace.CurrentCamera
	if camera then
		table.insert(list, camera)
	end
	for _, name in ipairs({ "ClientEffects", "Coins", "Turrets" }) do
		local child = workspace:FindFirstChild(name)
		if child then
			table.insert(list, child)
		end
	end
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Character then
			table.insert(list, other.Character)
		end
	end
	return list
end

-- Descobre onde a bala para (só para desenhar o tracer). Imita o servidor: spherecast,
-- atravessa até 1 + Pierce brainrots e para no primeiro obstáculo que não é brainrot.
local function traceShot(origin, direction, stats, excludeList)
	local range = math.max(tonumber(stats.Range) or 350, 1)
	local radius = math.clamp(GameConfig.BulletHitRadius * (tonumber(stats.Caliber) or 1), 0.05, 50)
	local maxTargets = 1 + math.max(0, math.floor(tonumber(stats.Pierce) or 0))

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = table.clone(excludeList)
	params.FilterDescendantsInstances = filter

	local hits = 0
	while true do
		local result = workspace:Spherecast(origin, radius, direction * range, params)
		if not result then
			return origin + direction * range, false
		end
		local brainrot = findBrainrotModel(result.Instance)
		if not brainrot then
			return result.Position, true
		end
		hits += 1
		if hits >= maxTargets then
			return result.Position, true
		end
		table.insert(filter, brainrot)
		params.FilterDescendantsInstances = filter
	end
end

-- Calcula as direções do leque a partir da mira.
local function buildDirections(aimCFrame, stats)
	local count = math.max(1, math.floor(tonumber(stats.Projectiles) or 1))
	local spread = math.max(0, tonumber(stats.Spread) or 0)
	local totalAngle = math.min(spread * (count - 1), MAX_FAN_DEGREES)
	local rotation = aimCFrame.Rotation
	local directions = {}
	for index = 1, count do
		local fanAngle = 0
		if count > 1 then
			fanAngle = -totalAngle / 2 + totalAngle * (index - 1) / (count - 1)
		end
		local jitterYaw = rng:NextNumber(-1, 1) * RANDOM_DEVIATION_DEGREES
		local jitterPitch = rng:NextNumber(-1, 1) * RANDOM_DEVIATION_DEGREES
		local shotRotation = rotation
			* CFrame.Angles(0, math.rad(fanAngle + jitterYaw), 0)
			* CFrame.Angles(math.rad(jitterPitch), 0, 0)
		directions[index] = shotRotation.LookVector
	end
	return directions
end

local function fireOnce(stats)
	local aimCFrame = callController("CameraController", "GetAimCFrame")
	if typeof(aimCFrame) ~= "CFrame" then
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		aimCFrame = camera.CFrame
	end

	shotId += 1
	local origin = aimCFrame.Position
	local directions = buildDirections(aimCFrame, stats)

	-- 1) Avisa o servidor (ele valida tudo e aplica o dano).
	Net.Fire("Fire", origin, directions, shotId)

	-- 2) Visual imediato: tracers do cano até onde cada bala bateu.
	local _, _, tracerColor = getColors()
	local excludeList = buildExcludeList()
	local from = if muzzleWorld then muzzleWorld.Position else origin + aimCFrame.LookVector * 1.5
	local caliberScale = math.clamp((tonumber(stats.Caliber) or 1) / ((weaponDef and weaponDef.Stats.Caliber) or 1), 1, 2.5)
	local width = feel.TracerWidth * caliberScale
	local speed = (weaponDef and weaponDef.BulletVisualSpeed) or 700
	for _, direction in ipairs(directions) do
		local endpoint, hitSomething = traceShot(origin, direction, stats, excludeList)
		callController("EffectsController", "Tracer", from, endpoint, tracerColor, width, speed, hitSomething)
	end

	-- 3) Clarão, coice, recuo da arma e som.
	flashTimeLeft = FLASH_DURATION
	recoilZ = math.min(recoilZ + feel.Recoil, 0.6)
	recoilRotation = math.min(recoilRotation + feel.RecoilRotation, 0.5)
	callController("CameraController", "Kick", feel.Kick)
	playShootSound()

	-- 4) Calor previsto (a arma trava na hora, sem esperar o servidor).
	local capacity = heatCapacity(stats)
	if capacity > 0 then
		localHeat += tonumber(stats.HeatPerShot) or 0
		if localHeat >= capacity then
			localOverheated = true
		end
	end
end

-- O gatilho está apertado (mouse, controle ou botão do celular)?
local function isTriggerHeld()
	if mouseHeld or gamepadHeld then
		return true
	end
	return callController("MobileController", "IsFireHeld") == true
end

-- Motivo que impede atirar agora (nil = pode atirar).
local function getBlockReason()
	if not humanoid or humanoid.Health <= 0 then
		return "Dead"
	end
	if callController("CameraController", "IsEnabled") == false then
		return "Cinematic"
	end
	if isModalOpen() or callController("CameraController", "IsCursorFree") == true then
		return "Modal"
	end
	if callController("PlacementController", "IsActive") == true then
		return "Placement"
	end
	if isOverheated() then
		return "Overheated"
	end
	return nil
end

local function updateFiring(stats)
	firing = false
	if not stats or not weaponId then
		return
	end
	if not isTriggerHeld() then
		blockedFeedbackGiven = false
		return
	end

	local reason = getBlockReason()
	if reason then
		-- Superaquecida: um aviso (som de erro) por aperto.
		if reason == "Overheated" and not blockedFeedbackGiven then
			blockedFeedbackGiven = true
			pcall(UIKit.PlaySound, "Error")
		end
		return
	end

	firing = true
	local t = workspace:GetServerTimeNow()
	local interval = 1 / math.max(tonumber(stats.FireRate) or 1, 0.05)
	-- Não acumula tiros "atrasados" de quando o jogador não estava atirando.
	if nextShotTime < t - interval then
		nextShotTime = t
	end
	local shots = 0
	while t >= nextShotTime and shots < MAX_SHOTS_PER_FRAME do
		fireOnce(stats)
		nextShotTime += interval
		shots += 1
		if isOverheated() then
			break
		end
	end
end

-------------------------------------------------------------------------------
-- Atualização da arma na tela
-------------------------------------------------------------------------------
local function shouldShowViewmodel()
	if not viewmodel or not humanoid or humanoid.Health <= 0 then
		return false
	end
	return callController("CameraController", "IsEnabled") ~= false
end

local function updateViewmodel(dt, stats)
	local camera = workspace.CurrentCamera
	local visible = camera ~= nil and shouldShowViewmodel()
	if visible ~= viewmodelVisible then
		viewmodelVisible = visible
		if viewmodel then
			viewmodel.Model.Parent = if visible then camera else nil
		end
		if visible and camera then
			lastCameraRotation = camera.CFrame.Rotation
		end
	end
	if not visible or not camera or not viewmodel then
		muzzleWorld = nil
		return
	end
	if viewmodel.Model.Parent ~= camera then
		viewmodel.Model.Parent = camera
	end

	local cameraCFrame = camera.CFrame

	-- Balanço de "atraso" quando a câmera gira (a arma fica um pouquinho para trás).
	local relative = lastCameraRotation:ToObjectSpace(cameraCFrame.Rotation)
	local deltaPitch, deltaYaw = relative:ToOrientation()
	lastCameraRotation = cameraCFrame.Rotation
	local swayTarget = Vector2.new(math.clamp(-deltaYaw * 2.5, -0.12, 0.12), math.clamp(-deltaPitch * 2.5, -0.12, 0.12))
	sway = sway:Lerp(swayTarget, math.min(1, dt * 10))

	-- Balanço ao andar.
	local speed = 0
	local grounded = false
	if rootPart then
		speed = (rootPart.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
		grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	end
	local targetBob = if grounded and speed > 1 then math.clamp(speed / 16, 0, 1.6) else 0
	bobAmount += (targetBob - bobAmount) * math.min(1, dt * 8)
	bobTime += dt * (5 + speed * 0.3)
	local bobX = math.sin(bobTime) * 0.035 * bobAmount
	local bobY = -math.abs(math.cos(bobTime)) * 0.03 * bobAmount

	-- Recuo volta ao normal rapidinho.
	recoilZ *= math.exp(-14 * dt)
	recoilRotation *= math.exp(-12 * dt)

	-- Arma abaixada: correndo, colocando torreta, com janela aberta ou superaquecida.
	local sprinting = callController("MovementController", "IsSprinting") == true
	local placing = callController("PlacementController", "IsActive") == true
	local wantLower = (sprinting and not firing) or placing or isModalOpen() or isOverheated()
	lowerAlpha += ((if wantLower then 1 else 0) - lowerAlpha) * math.min(1, dt * 8)

	local base = cameraCFrame
		* VIEWMODEL_OFFSET
		* CFrame.new(bobX, bobY, recoilZ)
		* CFrame.Angles(recoilRotation + sway.Y, sway.X, sway.X * 0.5)
		* CFrame.new(0.05 * lowerAlpha, -0.3 * lowerAlpha, 0.15 * lowerAlpha)
		* CFrame.Angles(-0.45 * lowerAlpha, 0.35 * lowerAlpha, 0.2 * lowerAlpha)

	-- Canos da metralhadora giram enquanto atira.
	local targetSpin = if firing then 28 else 0
	spinSpeed += (targetSpin - spinSpeed) * math.min(1, dt * (if firing then 6 else 2))
	spinAngle = (spinAngle + spinSpeed * dt) % (math.pi * 2)
	local spinTransform = nil
	if viewmodel.SpinCenter then
		spinTransform = viewmodel.SpinCenter * CFrame.Angles(0, 0, spinAngle) * viewmodel.SpinCenter:Inverse()
	end

	local parts = {}
	local cframes = {}
	for _, piece in ipairs(viewmodel.Pieces) do
		table.insert(parts, piece.Part)
		if piece.Spin and spinTransform then
			table.insert(cframes, base * spinTransform * piece.Offset)
		else
			table.insert(cframes, base * piece.Offset)
		end
	end

	muzzleWorld = base * viewmodel.MuzzleOffset

	-- Clarão do cano (aparece por um instante a cada tiro).
	flashTimeLeft = math.max(0, flashTimeLeft - dt)
	local flash = viewmodel.Flash
	if flashTimeLeft > 0 then
		local size = feel.FlashSize * rng:NextNumber(0.8, 1.25)
		flash.Size = Vector3.one * size
		flash.Transparency = 0.1
		viewmodel.Light.Brightness = 4
		table.insert(parts, flash)
		table.insert(cframes, muzzleWorld * CFrame.Angles(0, 0, rng:NextNumber(0, math.pi * 2)))
	else
		if flash.Transparency ~= 1 then
			flash.Transparency = 1
			viewmodel.Light.Brightness = 0
		end
		table.insert(parts, flash)
		table.insert(cframes, muzzleWorld)
	end
	viewmodel.Smoke.Enabled = isOverheated()

	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)

	paintViewmodel(math.floor(heatFraction(stats) * 20 + 0.5) / 20)
end

-------------------------------------------------------------------------------
-- Frame
-------------------------------------------------------------------------------
local function onRenderStep(dt)
	dt = math.min(dt, 0.1)
	local stats = getStats()
	if stats then
		coolDown(dt, stats)
	end
	-- Primeiro a arma (para saber onde está o cano), depois os tiros.
	updateViewmodel(dt, stats)
	updateFiring(stats)
end

-------------------------------------------------------------------------------
-- Troca de mapa/arma
-------------------------------------------------------------------------------
local function refreshWeapon()
	local mapId = getMapId()
	local mapDef = mapId and Maps[mapId] or nil
	local newWeaponId = if type(mapDef) == "table" then mapDef.Weapon else nil
	if newWeaponId == weaponId then
		return
	end
	weaponId = newWeaponId
	weaponDef = if newWeaponId then Weapons[newWeaponId] else nil
	feel = WEAPON_FEEL[newWeaponId] or DEFAULT_FEEL
	cachedStats = nil
	localHeat = 0
	localOverheated = false
	buildViewmodel()
	buildShootSounds()
end

-------------------------------------------------------------------------------
-- Acertos confirmados pelo servidor
-------------------------------------------------------------------------------
local function onHitConfirm(hits)
	if type(hits) ~= "table" or #hits == 0 then
		return
	end
	local anyCrit = false
	for _, hit in ipairs(hits) do
		if type(hit) == "table" then
			if hit.Crit == true then
				anyCrit = true
			end
			if showDamageNumbers and typeof(hit.Position) == "Vector3" then
				callController("EffectsController", "DamageNumber", hit.Position, tonumber(hit.Damage) or 0, hit.Crit == true)
			end
		end
	end

	callController("HUDController", "ShowHitmarker", anyCrit)

	local t = os.clock()
	if t - lastHitSound >= HIT_SOUND_INTERVAL then
		lastHitSound = t
		pcall(UIKit.PlaySound, if anyCrit then "Crit" else "Hit")
	end
end

-------------------------------------------------------------------------------
-- Entrada
-------------------------------------------------------------------------------
local function onInputBegan(input, gameProcessed)
	if gameProcessed then
		return
	end
	-- Um clique que começou colocando torreta não vira tiro depois.
	if callController("PlacementController", "IsActive") == true then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseHeld = true
	elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
		gamepadHeld = true
	end
end

local function onInputEnded(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseHeld = false
	elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
		gamepadHeld = false
	end
end

-------------------------------------------------------------------------------
-- Personagem
-------------------------------------------------------------------------------
local function onCharacterAdded(character)
	characterTrove:Clean()
	humanoid, rootPart = nil, nil
	mouseHeld, gamepadHeld = false, false

	local newHumanoid = character:WaitForChild("Humanoid", 10)
	local newRoot = character:WaitForChild("HumanoidRootPart", 10)
	if not newHumanoid or not newRoot or player.Character ~= character then
		return
	end
	humanoid = newHumanoid
	rootPart = newRoot

	-- Cor da mão = cor do braço direito do personagem.
	local arm = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if arm and arm:IsA("BasePart") then
		armColor = arm.Color
	else
		local bodyColors = character:FindFirstChildOfClass("BodyColors")
		armColor = if bodyColors then bodyColors.RightArmColor3 else DEFAULT_SKIN_COLOR
	end
	lastColorKey = ""

	characterTrove:Connect(humanoid.Died, function()
		mouseHeld, gamepadHeld = false, false
	end)
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------
function WeaponController.IsFiring()
	return firing
end

function WeaponController.GetMuzzlePosition()
	return if muzzleWorld then muzzleWorld.Position else nil
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------
function WeaponController.Init()
	mainTrove:Add(Net.On("HitConfirm", onHitConfirm))
	mainTrove:Connect(UserInputService.InputBegan, onInputBegan)
	mainTrove:Connect(UserInputService.InputEnded, onInputEnded)
	mainTrove:Connect(UserInputService.WindowFocusReleased, function()
		mouseHeld, gamepadHeld = false, false
	end)
end

function WeaponController.Start()
	if started then
		return
	end
	started = true

	refreshProfile()
	mainTrove:Add(StateController.OnChanged("Profile", refreshProfile))

	refreshWeapon()
	mainTrove:Add(StateController.OnChanged("Match", function()
		refreshWeapon()
	end))

	if type(StateController.StatsChanged) == "table" then
		mainTrove:Add(StateController.StatsChanged:Connect(function(stats)
			if type(stats) == "table" then
				cachedStats = stats
			end
		end))
	end

	onHeatChanged(StateController.Get("Heat"))
	mainTrove:Add(StateController.OnChanged("Heat", onHeatChanged))

	mainTrove:Connect(player.CharacterAdded, onCharacterAdded)
	mainTrove:Connect(player.CharacterRemoving, function()
		characterTrove:Clean()
		humanoid, rootPart = nil, nil
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, onRenderStep)
	mainTrove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		destroyViewmodel()
		clearShootSounds()
	end)
end

return WeaponController
