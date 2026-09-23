-- CameraController (só na partida): câmera de primeira pessoa feita por nós.
--
-- O que ela faz:
--   * Deixa a câmera "Scriptable" (nós mesmos posicionamos ela todo frame, na altura dos olhos).
--   * Gira com o mouse (travado no centro), com o analógico direito do controle (Thumbstick2)
--     e arrastando o dedo na metade direita da tela (toques que NÃO começaram num botão).
--   * Usa Sensibilidade, Inverter Y e FOV das configurações do jogador (Profile.Settings).
--   * Gira o personagem junto com a câmera (Humanoid.AutoRotate = false).
--   * Esconde o próprio corpo (LocalTransparencyModifier = 1) para não tampar a visão.
--   * Quando uma janela (modal) está aberta: solta o mouse e para de girar.
--   * No PC, segurar Alt também solta o mouse (para clicar nos botões do HUD).
--   * Balanço leve ao andar, "coice" nos tiros (Kick) e tremida em explosões (Shake).
--
-- API pública:
--   CameraController.GetAimCFrame() -> CFrame   para onde a mira (centro da tela) aponta
--   CameraController.SetEnabled(bool)           liga/desliga a câmera (o final desliga)
--   CameraController.IsEnabled() -> boolean
--   CameraController.IsCursorFree() -> boolean  true enquanto o jogador segura Alt (mouse solto)
--   CameraController.Kick(amount)               coice para cima (em graus, aproximadamente)
--   CameraController.Shake(intensity)           tremida (0 a 1), usada pelos efeitos

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Trove = require(Util:WaitForChild("Trove"))

local Controllers = script.Parent
local UIKit = require(Controllers.Parent:WaitForChild("UI"):WaitForChild("UIKit"))
local StateController = require(Controllers:WaitForChild("StateController"))

local CameraController = {}

-------------------------------------------------------------------------------
-- Constantes técnicas (não são balanceamento, então ficam aqui)
-------------------------------------------------------------------------------
local RENDER_STEP_NAME = "BrainrotFirstPersonCamera"
-- Roda logo depois da câmera padrão do Roblox (que está desligada, mas por garantia).
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local MAX_PITCH = math.rad(80) -- olhar no máximo 80° para cima/baixo
local MOUSE_DEGREES_PER_PIXEL = 0.6 -- × sensibilidade (0,5 padrão = 0,3° por pixel)
local TOUCH_DEGREES_PER_PIXEL = 0.5 -- × sensibilidade
local GAMEPAD_DEGREES_PER_SECOND = 360 -- × sensibilidade, com o analógico no máximo
local GAMEPAD_DEADZONE = 0.15 -- ignora movimentos pequenos do analógico (folga)
local GAMEPAD_CURVE = 1.6 -- curva de resposta: movimentos pequenos ficam mais precisos

-- Teclas que, seguradas, soltam o mouse (para clicar nos botões do HUD no PC).
local FREE_CURSOR_KEYS = {
	[Enum.KeyCode.LeftAlt] = true,
	[Enum.KeyCode.RightAlt] = true,
}

local DEFAULT_EYE_OFFSET = 1.5 -- altura dos olhos acima do HumanoidRootPart (se não achar a cabeça)
local SPRINT_FOV_BONUS = 6 -- FOV aumenta um pouco ao correr (sensação de velocidade)

local KICK_MAX = 10 -- coice máximo acumulado (graus)
local KICK_RECOVER = 9 -- velocidade com que o coice volta ao centro
local KICK_SNAP = 28 -- velocidade com que a câmera "sobe" no coice

local SHAKE_DECAY = 1.5 -- quanto da tremida some por segundo
local SHAKE_MAX_ANGLE = math.rad(2.2)

-- Valores padrão das configurações (iguais ao template do perfil).
local DEFAULT_SENSITIVITY = 0.5
local DEFAULT_FOV = 80

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------
local player = Players.LocalPlayer
local rng = Random.new()

local enabled = true -- a câmera está sob nosso controle?
local started = false -- Start já rodou?
local yaw = 0 -- rotação horizontal (radianos)
local pitch = 0 -- rotação vertical (radianos)

local settings = {
	Sensitivity = DEFAULT_SENSITIVITY,
	InvertY = false,
	FOV = DEFAULT_FOV,
}

-- Entrada acumulada entre frames.
local gamepadStick = Vector2.zero -- posição atual do analógico direito
local touchDelta = Vector2.zero -- quanto o dedo andou desde o último frame
local lookTouch = nil -- InputObject do toque que está girando a câmera
local lookTouchLast = nil -- última posição desse toque
local skipMouseFrames = 2 -- ignora o mouse por alguns frames (evita "pulo" ao travar)
local cursorFreeHeld = false -- segurando Alt?

-- Personagem atual.
local humanoid = nil
local rootPart = nil
local head = nil
local bodyParts = {} -- [BasePart ou Decal] = true (tudo que escondemos)
local eyeOffset = DEFAULT_EYE_OFFSET

-- Efeitos de câmera.
local bobTime = 0
local bobAmount = 0
local kickTarget = 0 -- coice vertical desejado (graus)
local kickCurrent = 0 -- coice vertical aplicado agora (graus)
local kickYawTarget = 0
local kickYawCurrent = 0
local trauma = 0 -- intensidade da tremida (0 a 1)
local shakeClock = 0
local currentFov = DEFAULT_FOV

-- Último CFrame calculado (é o que GetAimCFrame devolve).
local aimCFrame = CFrame.new()
local mouseState = nil -- "locked" ou "free": evita trocar propriedades à toa

local characterTrove = Trove.new()
local mainTrove = Trove.new()

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
	warn("[CameraController] Não foi possível carregar " .. name .. ": " .. tostring(result))
	return nil
end

-- true se alguma janela (modal) está aberta. Protegido caso o UIKit falhe.
local function isModalOpen()
	local ok, result = pcall(UIKit.IsAnyModalOpen)
	return ok and result == true
end

-------------------------------------------------------------------------------
-- Configurações do jogador
-------------------------------------------------------------------------------
local function refreshSettings()
	local profile = StateController.Get("Profile")
	local saved = type(profile) == "table" and profile.Settings or nil
	if type(saved) ~= "table" then
		return
	end
	settings.Sensitivity = math.clamp(tonumber(saved.Sensitivity) or DEFAULT_SENSITIVITY, 0.05, 2)
	settings.InvertY = saved.InvertY == true
	settings.FOV = math.clamp(tonumber(saved.FOV) or DEFAULT_FOV, 60, 110)
end

-------------------------------------------------------------------------------
-- Corpo do personagem (esconder / mostrar)
-------------------------------------------------------------------------------
local function trackBodyPart(instance)
	if instance:IsA("BasePart") or instance:IsA("Decal") then
		bodyParts[instance] = true
	end
end

local function untrackBodyPart(instance)
	bodyParts[instance] = nil
end

-- Deixa o corpo visível de novo (usado quando a câmera é desligada).
local function showBody()
	for part in pairs(bodyParts) do
		if part.Parent then
			part.LocalTransparencyModifier = 0
		end
	end
end

-- Esconde o corpo (roda todo frame porque acessórios podem mudar a transparência).
local function hideBody()
	for part in pairs(bodyParts) do
		if part.LocalTransparencyModifier ~= 1 then
			part.LocalTransparencyModifier = 1
		end
	end
end

-- Prepara um personagem novo (nasceu ou renasceu).
local function onCharacterAdded(character)
	characterTrove:Clean()
	table.clear(bodyParts)
	humanoid, rootPart, head = nil, nil, nil

	local newHumanoid = character:WaitForChild("Humanoid", 10)
	local newRoot = character:WaitForChild("HumanoidRootPart", 10)
	if not newHumanoid or not newRoot or player.Character ~= character then
		return
	end

	humanoid = newHumanoid
	rootPart = newRoot
	head = character:FindFirstChild("Head")
	humanoid.AutoRotate = not enabled

	-- Começa olhando para onde o personagem nasceu virado.
	-- Para CFrame.Angles(0, yaw, 0), LookVector = (-sin(yaw), 0, -cos(yaw)).
	local look = newRoot.CFrame.LookVector
	if Vector2.new(look.X, look.Z).Magnitude > 0.01 then
		yaw = math.atan2(-look.X, -look.Z)
	end
	pitch = 0
	kickTarget, kickCurrent, kickYawTarget, kickYawCurrent = 0, 0, 0, 0

	for _, descendant in ipairs(character:GetDescendants()) do
		trackBodyPart(descendant)
	end
	characterTrove:Connect(character.DescendantAdded, function(descendant)
		trackBodyPart(descendant)
		if descendant.Name == "Head" and descendant:IsA("BasePart") and descendant.Parent == character then
			head = descendant
		end
	end)
	characterTrove:Connect(character.DescendantRemoving, untrackBodyPart)
	characterTrove:Add(function()
		table.clear(bodyParts)
	end)
end

-------------------------------------------------------------------------------
-- Entrada (controle e toque). O mouse é lido direto com GetMouseDelta.
-------------------------------------------------------------------------------
local function onInputBegan(input, gameProcessed)
	if FREE_CURSOR_KEYS[input.KeyCode] then
		if not UserInputService:GetFocusedTextBox() then
			cursorFreeHeld = true
		end
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		-- Toques que começaram em GUI (botões, analógico virtual) não giram a câmera.
		if gameProcessed or lookTouch ~= nil then
			return
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		-- Só a metade direita da tela gira a câmera (a esquerda é do analógico de andar).
		if input.Position.X < camera.ViewportSize.X * 0.5 then
			return
		end
		lookTouch = input
		lookTouchLast = Vector2.new(input.Position.X, input.Position.Y)
	end
end

local function onInputChanged(input)
	if input.KeyCode == Enum.KeyCode.Thumbstick2 then
		gamepadStick = Vector2.new(input.Position.X, input.Position.Y)
	elseif input == lookTouch and lookTouchLast then
		local position = Vector2.new(input.Position.X, input.Position.Y)
		touchDelta += position - lookTouchLast
		lookTouchLast = position
	end
end

local function onInputEnded(input)
	if FREE_CURSOR_KEYS[input.KeyCode] then
		cursorFreeHeld = false
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		gamepadStick = Vector2.zero
	elseif input == lookTouch then
		lookTouch = nil
		lookTouchLast = nil
	end
end

-- Aplica mouse + controle + toque na rotação da câmera.
local function applyLookInput(dt)
	local sensitivity = settings.Sensitivity
	local invert = if settings.InvertY then -1 else 1
	local deltaYaw = 0 -- graus
	local deltaPitch = 0 -- graus

	-- Mouse (só funciona com o mouse travado no centro).
	local mouseDelta = UserInputService:GetMouseDelta()
	if skipMouseFrames > 0 then
		skipMouseFrames -= 1
		mouseDelta = Vector2.zero
	end
	deltaYaw -= mouseDelta.X * MOUSE_DEGREES_PER_PIXEL * sensitivity
	deltaPitch -= mouseDelta.Y * MOUSE_DEGREES_PER_PIXEL * sensitivity * invert

	-- Controle: analógico direito, com zona morta e curva de resposta.
	local magnitude = gamepadStick.Magnitude
	if magnitude > GAMEPAD_DEADZONE then
		local direction = gamepadStick / magnitude
		local strength = ((math.min(magnitude, 1) - GAMEPAD_DEADZONE) / (1 - GAMEPAD_DEADZONE)) ^ GAMEPAD_CURVE
		local speed = GAMEPAD_DEGREES_PER_SECOND * sensitivity * strength * dt
		deltaYaw -= direction.X * speed
		deltaPitch += direction.Y * speed * 0.75 * invert
	end

	-- Toque: o quanto o dedo arrastou desde o último frame.
	deltaYaw -= touchDelta.X * TOUCH_DEGREES_PER_PIXEL * sensitivity
	deltaPitch -= touchDelta.Y * TOUCH_DEGREES_PER_PIXEL * sensitivity * invert
	touchDelta = Vector2.zero

	yaw = (yaw + math.rad(deltaYaw)) % (math.pi * 2)
	pitch = math.clamp(pitch + math.rad(deltaPitch), -MAX_PITCH, MAX_PITCH)
end

-- Trava ou solta o mouse (só mexe nas propriedades quando o estado muda).
local function setMouseLocked(locked)
	local wanted = if locked then "locked" else "free"
	if locked then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
		if UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = false
		end
	else
		if mouseState ~= wanted then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
	end
	if mouseState ~= wanted then
		mouseState = wanted
		skipMouseFrames = 2
	end
end

-------------------------------------------------------------------------------
-- Atualização por frame
-------------------------------------------------------------------------------
local function isSprinting()
	local movement = Ctrl("MovementController")
	if movement and type(movement.IsSprinting) == "function" then
		local ok, result = pcall(movement.IsSprinting)
		return ok and result == true
	end
	return false
end

local function onRenderStep(dt)
	if not enabled then
		return
	end
	dt = math.min(dt, 0.1)

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	-- Janela aberta (ou Alt segurado): solta o mouse e não gira. Senão: trava no centro e lê a entrada.
	if cursorFreeHeld or isModalOpen() then
		setMouseLocked(false)
		touchDelta = Vector2.zero
		lookTouch = nil
		lookTouchLast = nil
	else
		setMouseLocked(true)
		applyLookInput(dt)
	end

	-- Sem personagem: mantém a câmera onde estava.
	if not rootPart or not rootPart.Parent or not humanoid then
		camera.CFrame = aimCFrame
		return
	end

	-- Altura dos olhos: mede pela cabeça (funciona com R6, R15 e escalas diferentes), suavizado.
	local targetEye = DEFAULT_EYE_OFFSET
	if head and head.Parent then
		targetEye = math.clamp(head.Position.Y - rootPart.Position.Y + 0.2, 0.5, 4)
	end
	eyeOffset += (targetEye - eyeOffset) * math.min(1, dt * 10)

	-- Balanço ao andar: cresce com a velocidade e só no chão.
	local flatVelocity = rootPart.AssemblyLinearVelocity * Vector3.new(1, 0, 1)
	local speed = flatVelocity.Magnitude
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	local targetBob = if grounded and speed > 1 then math.clamp(speed / 16, 0, 1.6) else 0
	bobAmount += (targetBob - bobAmount) * math.min(1, dt * 8)
	bobTime += dt * (6 + speed * 0.35)
	local bobX = math.sin(bobTime) * 0.05 * bobAmount
	local bobY = (math.abs(math.cos(bobTime)) - 0.5) * 0.08 * bobAmount
	local bobRoll = math.sin(bobTime) * math.rad(0.3) * bobAmount

	-- Coice: o alvo volta ao centro e a câmera persegue o alvo rapidinho.
	local recover = math.exp(-KICK_RECOVER * dt)
	kickTarget *= recover
	kickYawTarget *= recover
	local snap = math.min(1, dt * KICK_SNAP)
	kickCurrent += (kickTarget - kickCurrent) * snap
	kickYawCurrent += (kickYawTarget - kickYawCurrent) * snap

	-- Tremida (explosões): ruído suave, forte no começo e sumindo.
	trauma = math.max(0, trauma - SHAKE_DECAY * dt)
	local shakePitch, shakeYaw, shakeRoll = 0, 0, 0
	if trauma > 0 then
		shakeClock += dt * 22
		local power = trauma * trauma
		shakePitch = SHAKE_MAX_ANGLE * power * math.noise(shakeClock, 0.3, 1.7)
		shakeYaw = SHAKE_MAX_ANGLE * power * math.noise(0.9, shakeClock, 3.1)
		shakeRoll = SHAKE_MAX_ANGLE * power * math.noise(shakeClock, shakeClock, 5.3)
	end

	local eyePosition = rootPart.Position + Vector3.new(0, eyeOffset, 0)
	local rotation = CFrame.fromOrientation(
		pitch + math.rad(kickCurrent) + shakePitch,
		yaw + math.rad(kickYawCurrent) + shakeYaw,
		bobRoll + shakeRoll
	)
	local cameraCFrame = CFrame.new(eyePosition) * rotation * CFrame.new(bobX, bobY, 0)

	-- FOV das configurações (+ um pouquinho ao correr), com transição suave.
	local targetFov = settings.FOV + (if isSprinting() then SPRINT_FOV_BONUS else 0)
	currentFov += (targetFov - currentFov) * math.min(1, dt * 8)

	camera.CFrame = cameraCFrame
	camera.Focus = CFrame.new(eyePosition)
	camera.FieldOfView = currentFov
	aimCFrame = cameraCFrame

	-- Gira o personagem para onde a câmera olha (só no eixo Y).
	if humanoid.Health > 0 and not humanoid.Sit and not humanoid.PlatformStand then
		local _, currentYaw = rootPart.CFrame:ToOrientation()
		local difference = math.abs((currentYaw - yaw + math.pi) % (math.pi * 2) - math.pi)
		if difference > 1e-3 then
			rootPart.CFrame = CFrame.new(rootPart.Position) * CFrame.Angles(0, yaw, 0)
		end
	end

	hideBody()
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Para onde a mira aponta (o centro da tela). Quando a câmera está desligada
-- (ex.: no final), devolve o CFrame atual da câmera.
function CameraController.GetAimCFrame()
	if not enabled then
		local camera = workspace.CurrentCamera
		return if camera then camera.CFrame else aimCFrame
	end
	return aimCFrame
end

-- Liga/desliga a câmera de primeira pessoa. Desligada, ela não mexe mais na
-- câmera (quem desligou controla), solta o mouse e mostra o corpo de novo.
function CameraController.SetEnabled(value)
	value = value == true
	if value == enabled then
		return
	end
	enabled = value

	if enabled then
		skipMouseFrames = 2
		mouseState = nil
		if humanoid then
			humanoid.AutoRotate = false
		end
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		mouseState = "free"
		if humanoid then
			humanoid.AutoRotate = true
		end
		showBody()
		touchDelta = Vector2.zero
		lookTouch = nil
		lookTouchLast = nil
		kickTarget, kickCurrent, kickYawTarget, kickYawCurrent = 0, 0, 0, 0
		trauma = 0
	end
end

function CameraController.IsEnabled()
	return enabled
end

-- true enquanto o jogador segura Alt para usar o mouse no HUD (a arma não atira).
function CameraController.IsCursorFree()
	return enabled and cursorFreeHeld
end

-- Coice do tiro: empurra a visão para cima (e um pouquinho para o lado).
function CameraController.Kick(amount)
	amount = tonumber(amount) or 0
	if amount <= 0 or not enabled then
		return
	end
	kickTarget = math.min(kickTarget + amount, KICK_MAX)
	kickYawTarget = math.clamp(kickYawTarget + (rng:NextNumber() - 0.5) * amount * 0.5, -KICK_MAX, KICK_MAX)
end

-- Tremida de câmera (explosões, gigantes morrendo). intensity de 0 a 1.
function CameraController.Shake(intensity)
	intensity = tonumber(intensity) or 0
	if intensity <= 0 or not enabled then
		return
	end
	trauma = math.min(1, trauma + intensity)
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------
function CameraController.Init()
	-- Entrada de controle e toque (o mouse é lido direto no frame).
	mainTrove:Connect(UserInputService.InputBegan, onInputBegan)
	mainTrove:Connect(UserInputService.InputChanged, onInputChanged)
	mainTrove:Connect(UserInputService.InputEnded, onInputEnded)
	mainTrove:Connect(UserInputService.WindowFocusReleased, function()
		gamepadStick = Vector2.zero
		lookTouch = nil
		lookTouchLast = nil
		cursorFreeHeld = false
	end)
	mainTrove:Connect(UserInputService.GamepadDisconnected, function()
		gamepadStick = Vector2.zero
	end)
end

function CameraController.Start()
	if started then
		return
	end
	started = true

	refreshSettings()
	mainTrove:Add(StateController.OnChanged("Profile", refreshSettings))

	-- Ao fechar uma janela, ignora o "pulo" do mouse voltando ao centro.
	if type(UIKit.ModalChanged) == "table" and type(UIKit.ModalChanged.Connect) == "function" then
		mainTrove:Add(UIKit.ModalChanged:Connect(function()
			skipMouseFrames = 2
		end))
	end

	-- Personagem atual e os próximos.
	mainTrove:Connect(player.CharacterAdded, onCharacterAdded)
	mainTrove:Connect(player.CharacterRemoving, function()
		characterTrove:Clean()
		humanoid, rootPart, head = nil, nil, nil
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end

	local camera = workspace.CurrentCamera
	if camera then
		currentFov = camera.FieldOfView
		aimCFrame = camera.CFrame
	end

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, onRenderStep)
	mainTrove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
end

return CameraController
