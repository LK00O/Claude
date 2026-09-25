-- FlyController (lobby e partida): faz o personagem do admin voar.
--
-- Quem decide se o jogador pode voar é o SERVIDOR (AdminService): ele liga o atributo
-- "AdminFly" no jogador (comando ":fly" ou o botão "Voar" do painel de admin).
-- Este módulo só obedece: enquanto LocalPlayer:GetAttribute("AdminFly") == true, o
-- personagem voa; quando o atributo desliga, tudo volta ao normal.
--
-- Como o voo funciona (restrições de física atuais do Roblox, sem BodyVelocity/BodyGyro):
--   * Humanoid.PlatformStand = true: o Humanoid para de andar/cair sozinho.
--   * LinearVelocity no HumanoidRootPart: empurra o personagem na velocidade que queremos.
--   * AlignOrientation: deixa o personagem em pé, virado para onde a câmera olha.
--   O personagem é "do cliente" (network owner), então a física feita aqui aparece
--   para todo mundo sem precisar mandar nada ao servidor.
--
-- Controles:
--   * PC: WASD (ou as teclas escolhidas nas Configurações) movem para onde a câmera
--     olha (olhar para cima e ir para a frente = subir). Espaço sobe, Ctrl ou Q descem,
--     Shift (tecla de correr) acelera.
--   * Controle: analógico esquerdo move, A sobe, L2 desce, L3 acelera.
--   * Celular: o analógico da tela move para onde a câmera olha (olhe para cima ou para
--     baixo para subir/descer); o botão de pulo sobe; o botão "Correr" acelera.
-- Funciona com a câmera de primeira pessoa da partida (CameraController) e com a
-- câmera padrão do lobby. Depois de renascer, o voo volta sozinho se ainda estiver ligado.
--
-- API pública:
--   FlyController.IsFlying() -> boolean

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")
local GameConfig = require(Config:WaitForChild("Game"))
local Trove = require(Util:WaitForChild("Trove"))

local Controllers = script.Parent
local StateController = require(Controllers:WaitForChild("StateController"))
local NotifyController = require(Controllers:WaitForChild("NotifyController"))

local FlyController = {}

-------------------------------------------------------------------------------
-- Acesso preguiçoso a outros controllers (regra anti-require-circular)
-------------------------------------------------------------------------------
-- Guardamos o resultado porque isto roda todo quadro e NUNCA pode ficar esperando.
local controllerCache = {} -- [nome] = módulo, ou false se deu erro
local function Ctrl(name)
	local cached = controllerCache[name]
	if cached ~= nil then
		return cached or nil
	end
	local module = Controllers:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		controllerCache[name] = result
		return result
	end
	controllerCache[name] = false
	return nil
end

-------------------------------------------------------------------------------
-- Constantes técnicas (ferramenta de admin: não são balanceamento do jogo)
-------------------------------------------------------------------------------
local FLY_ATTRIBUTE = "AdminFly"

local RENDER_STEP_NAME = "BrainrotAdminFly"
-- Roda depois da entrada (Input = 100) e da câmera (Camera = 200): assim lemos a
-- direção da câmera JÁ atualizada neste quadro.
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value

local BASE_FLY_SPEED = 60 -- studs por segundo com a velocidade normal de andar
local BOOST_MULTIPLIER = 2.2 -- segurando "correr"
local MIN_FLY_SPEED = 10
local MAX_FLY_SPEED = 500
local ACCELERATION = 8 -- quão rápido a velocidade chega na desejada (maior = mais "seco")
local FORCE_PER_WEIGHT = 40 -- força máxima = peso do personagem × isto (sobra força)
local MIN_MASS = 1

-- Teclas de descer (Q só conta se não for tecla de andar do jogador, ex.: teclado AZERTY).
local DOWN_KEYS = { Enum.KeyCode.LeftControl, Enum.KeyCode.RightControl, Enum.KeyCode.Q }
local MOVE_ACTIONS = { "Forward", "Back", "Left", "Right", "Jump" }

-- Controle (gamepad).
local GAMEPAD = Enum.UserInputType.Gamepad1
local GAMEPAD_UP = Enum.KeyCode.ButtonA
local GAMEPAD_DOWN = Enum.KeyCode.ButtonL2
local GAMEPAD_BOOST = Enum.KeyCode.ButtonL3

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------
local player = Players.LocalPlayer

local flying = false
local humanoid = nil
local rootPart = nil
local controls = nil -- controles padrão do Roblox (PlayerModule), para ler o analógico
local velocity = Vector3.zero -- velocidade aplicada agora (suavizada)
local linearVelocity = nil
local alignOrientation = nil

local mainTrove = Trove.new() -- vive o jogo todo
local characterTrove = Trove.new() -- vive enquanto o personagem atual existe
local flightTrove = Trove.new() -- vive enquanto está voando

-------------------------------------------------------------------------------
-- Ajudantes de entrada
-------------------------------------------------------------------------------

-- true se o jogador está digitando (chat, caixa de texto): aí as teclas não voam.
local function isTyping()
	return UserInputService:GetFocusedTextBox() ~= nil
end

local function isKeyDown(keyCode)
	return keyCode ~= nil and UserInputService:IsKeyDown(keyCode)
end

local function isGamepadDown(keyCode)
	local ok, result = pcall(function()
		return UserInputService:IsGamepadButtonDown(GAMEPAD, keyCode)
	end)
	return ok and result == true
end

-- true se a tecla é usada para andar/pular nas Configurações do jogador.
local function isMovementKey(keyCode)
	for _, actionId in ipairs(MOVE_ACTIONS) do
		if StateController.GetKeybind(actionId) == keyCode then
			return true
		end
	end
	return false
end

-- Frente/lado pelo teclado, usando as teclas escolhidas pelo jogador.
-- Devolve (frente, direita), cada um de -1 a 1.
local function readKeyboardMove()
	if not UserInputService.KeyboardEnabled then
		return 0, 0
	end
	local forward = (if isKeyDown(StateController.GetKeybind("Forward")) then 1 else 0)
		- (if isKeyDown(StateController.GetKeybind("Back")) then 1 else 0)
	local right = (if isKeyDown(StateController.GetKeybind("Right")) then 1 else 0)
		- (if isKeyDown(StateController.GetKeybind("Left")) then 1 else 0)
	return forward, right
end

-- Frente/lado pelos controles padrão do Roblox (analógico do controle e da tela do celular).
-- GetMoveVector devolve um Vector3 relativo à câmera: X = direita, -Z = frente.
local function readControlsMove()
	if not controls then
		return 0, 0
	end
	local ok, moveVector = pcall(function()
		return controls:GetMoveVector()
	end)
	if not ok or typeof(moveVector) ~= "Vector3" then
		return 0, 0
	end
	return -moveVector.Z, moveVector.X
end

-- Junta teclado + controles. O teclado ganha quando está sendo usado.
local function readMoveInput()
	if isTyping() then
		return 0, 0
	end
	local forward, right = readKeyboardMove()
	if forward == 0 and right == 0 then
		forward, right = readControlsMove()
	end
	return math.clamp(forward, -1, 1), math.clamp(right, -1, 1)
end

-- Subir (+1), descer (-1) ou nada (0).
local function readVerticalInput()
	local up = false
	local down = false

	-- O botão de pulo (Espaço, A do controle, botão da tela) liga Humanoid.Jump.
	-- Lemos e desligamos em seguida: parado no ar o Humanoid não "gasta" o pulo sozinho.
	if humanoid and humanoid.Jump then
		up = true
		humanoid.Jump = false
	end

	if not isTyping() then
		if isKeyDown(StateController.GetKeybind("Jump")) or isGamepadDown(GAMEPAD_UP) then
			up = true
		end
		for _, keyCode in ipairs(DOWN_KEYS) do
			if isKeyDown(keyCode) and not isMovementKey(keyCode) then
				down = true
				break
			end
		end
		if isGamepadDown(GAMEPAD_DOWN) then
			down = true
		end
	end

	return (if up then 1 else 0) - (if down then 1 else 0)
end

-- true enquanto o jogador segura "correr" (Shift, L3 ou o botão "Correr" do celular).
local function isBoostHeld()
	if not isTyping() and isKeyDown(StateController.GetKeybind("Sprint")) then
		return true
	end
	if isGamepadDown(GAMEPAD_BOOST) then
		return true
	end
	local mobile = Ctrl("MobileController")
	if mobile and type(mobile.IsSprintHeld) == "function" then
		local ok, held = pcall(mobile.IsSprintHeld)
		return ok and held == true
	end
	return false
end

-- Velocidade do voo: acompanha a velocidade de andar do admin (comando ":speed").
local function getFlySpeed()
	local baseWalk = GameConfig.WalkSpeed
	local movement = Ctrl("MovementController")
	if movement and type(movement.GetBaseWalkSpeed) == "function" then
		local ok, value = pcall(movement.GetBaseWalkSpeed)
		if ok and type(value) == "number" and value > 0 then
			baseWalk = value
		end
	end
	local factor = if GameConfig.WalkSpeed > 0 then baseWalk / GameConfig.WalkSpeed else 1
	local speed = BASE_FLY_SPEED * factor
	if isBoostHeld() then
		speed *= BOOST_MULTIPLIER
	end
	return math.clamp(speed, MIN_FLY_SPEED, MAX_FLY_SPEED)
end

-------------------------------------------------------------------------------
-- Voo
-------------------------------------------------------------------------------

-- Direção "para a frente" da câmera no chão (sem inclinação), para virar o personagem.
local function flatLook(cameraCFrame)
	local look = Vector3.new(cameraCFrame.LookVector.X, 0, cameraCFrame.LookVector.Z)
	if look.Magnitude < 0.01 then
		-- Olhando reto para cima/baixo: o "UpVector" aponta para a frente.
		look = Vector3.new(cameraCFrame.UpVector.X, 0, cameraCFrame.UpVector.Z)
	end
	if look.Magnitude < 0.01 then
		return nil
	end
	return look.Unit
end

-- Roda todo quadro enquanto voa: lê a entrada e ajusta a velocidade e a rotação.
local function onRenderStep(dt)
	if not flying then
		return
	end
	if not humanoid or not rootPart or not rootPart.Parent or humanoid.Health <= 0 then
		return
	end
	dt = math.min(dt, 0.1)

	-- Algo pode ter tirado o Humanoid do "parado no ar" (ex.: sentar num banco).
	if humanoid.Sit then
		return
	end
	if not humanoid.PlatformStand then
		humanoid.PlatformStand = true
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraCFrame = camera.CFrame

	-- Direção: frente da câmera (com inclinação: olhar para cima e andar = subir),
	-- lado da câmera (sempre na horizontal) e subir/descer em linha reta.
	local forward, right = readMoveInput()
	local vertical = readVerticalInput()
	local rightVector = Vector3.new(cameraCFrame.RightVector.X, 0, cameraCFrame.RightVector.Z)
	if rightVector.Magnitude > 0.01 then
		rightVector = rightVector.Unit
	end
	local direction = cameraCFrame.LookVector * forward + rightVector * right + Vector3.yAxis * vertical
	if direction.Magnitude > 1 then
		direction = direction.Unit
	end

	-- Suaviza: a velocidade "corre atrás" da desejada (parar e arrancar ficam macios).
	local target = direction * getFlySpeed()
	local blend = 1 - math.exp(-ACCELERATION * dt)
	velocity = velocity:Lerp(target, blend)
	if velocity.Magnitude < 0.05 and target.Magnitude == 0 then
		velocity = Vector3.zero
	end
	if linearVelocity then
		linearVelocity.VectorVelocity = velocity
	end

	-- Personagem em pé, virado para onde a câmera olha.
	local look = flatLook(cameraCFrame)
	if look and alignOrientation then
		alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, look)
	end
end

-- Desliga o voo e devolve o personagem ao normal.
local function stopFlight()
	if not flying then
		return
	end
	flying = false
	flightTrove:Clean()
	linearVelocity = nil
	alignOrientation = nil
	velocity = Vector3.zero
	if humanoid and humanoid.Parent then
		humanoid.PlatformStand = false
	end
end

-- Liga o voo no personagem atual (se ele existir e estiver vivo).
local function startFlight()
	if flying then
		return
	end
	if not humanoid or not rootPart or not rootPart.Parent or humanoid.Health <= 0 then
		return
	end
	flying = true
	velocity = Vector3.zero

	-- Um "ponto de apoio" só nosso dentro do HumanoidRootPart.
	local attachment = Instance.new("Attachment")
	attachment.Name = "AdminFlyAttachment"
	attachment.Parent = rootPart
	flightTrove:Add(attachment)

	-- Força que mantém a velocidade desejada (em coordenadas do mundo).
	local mass = math.max(rootPart.AssemblyMass, MIN_MASS)
	linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "AdminFlyVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	linearVelocity.ForceLimitsEnabled = true
	linearVelocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	linearVelocity.MaxForce = mass * workspace.Gravity * FORCE_PER_WEIGHT
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.Parent = rootPart
	flightTrove:Add(linearVelocity)

	-- Mantém o personagem em pé e virado para a câmera (um só attachment = alvo pelo CFrame).
	alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "AdminFlyOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.RigidityEnabled = true
	local look = rootPart.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	alignOrientation.CFrame = if flat.Magnitude > 0.01 then CFrame.lookAt(Vector3.zero, flat.Unit) else CFrame.new()
	alignOrientation.Parent = rootPart
	flightTrove:Add(alignOrientation)

	-- Para o personagem não sair girando do jeito que estava.
	rootPart.AssemblyAngularVelocity = Vector3.zero
	humanoid.PlatformStand = true

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, onRenderStep)
	flightTrove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)

	-- Morreu voando: desliga (o voo volta no próximo personagem se o atributo continuar ligado).
	flightTrove:Connect(humanoid.Died, stopFlight)
end

-- Texto de ajuda com os controles do aparelho que o jogador está usando.
local function controlsHint()
	local inputType = UserInputService:GetLastInputType()
	if string.match(inputType.Name, "^Gamepad") then
		return "Voo ligado! Analógico move, A sobe, L2 desce, L3 acelera."
	end
	if inputType == Enum.UserInputType.Touch or not UserInputService.KeyboardEnabled then
		return "Voo ligado! Use o analógico e olhe para cima ou para baixo. O pulo sobe."
	end
	return "Voo ligado! WASD move, Espaço sobe, Ctrl ou Q desce, Shift acelera."
end

-- Confere o atributo do servidor e liga/desliga o voo.
local function refresh(showHint)
	local wanted = player:GetAttribute(FLY_ATTRIBUTE) == true
	if wanted and not flying then
		startFlight()
		if flying and showHint then
			NotifyController.Show(controlsHint(), "info", 6)
		end
	elseif not wanted and flying then
		stopFlight()
	end
end

-------------------------------------------------------------------------------
-- Personagem
-------------------------------------------------------------------------------
local function onCharacterAdded(character)
	stopFlight()
	characterTrove:Clean()
	humanoid, rootPart = nil, nil

	local newHumanoid = character:WaitForChild("Humanoid", 10)
	local newRoot = character:WaitForChild("HumanoidRootPart", 10)
	if not newHumanoid or not newRoot or player.Character ~= character then
		return
	end
	humanoid = newHumanoid
	rootPart = newRoot

	-- Renasceu com o voo ainda ligado: volta a voar (sem repetir a dica).
	refresh(false)
end

local function onCharacterRemoving()
	stopFlight()
	characterTrove:Clean()
	humanoid, rootPart = nil, nil
end

-- Carrega os controles padrão do Roblox (PlayerModule) para ler o analógico.
local function loadControls()
	local playerScripts = player:WaitForChild("PlayerScripts", 10)
	local playerModule = playerScripts and playerScripts:WaitForChild("PlayerModule", 10)
	if not playerModule then
		return
	end
	local ok, result = pcall(function()
		return require(playerModule):GetControls()
	end)
	if ok and result then
		controls = result
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

function FlyController.IsFlying()
	return flying
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function FlyController.Init()
	-- Nada a preparar: o voo começa no Start (depois dos outros controllers).
end

function FlyController.Start()
	-- O servidor liga/desliga o voo com o atributo "AdminFly".
	mainTrove:Connect(player:GetAttributeChangedSignal(FLY_ATTRIBUTE), function()
		refresh(true)
	end)

	mainTrove:Connect(player.CharacterAdded, onCharacterAdded)
	mainTrove:Connect(player.CharacterRemoving, onCharacterRemoving)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end

	-- Os controles padrão podem demorar a existir: carrega sem travar o Start.
	task.spawn(loadControls)

	mainTrove:Add(stopFlight)
end

return FlyController
