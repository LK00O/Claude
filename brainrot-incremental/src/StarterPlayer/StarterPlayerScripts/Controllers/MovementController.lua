-- MovementController (lobby e partida): corrida, teclas de movimento remapeadas e calor do deserto.
--
-- O que ele faz:
--   * Correr: segurar ou alternar (configuração "Alternar corrida"), com a tecla do keybind
--     "Sprint", o L3 do controle (apertar o analógico esquerdo) ou o botão "Correr" do celular.
--     Velocidades: Config.Game.WalkSpeed e Config.Game.SprintSpeed.
--   * Se o jogador trocou alguma tecla de movimento (Forward/Back/Left/Right/Jump), desliga os
--     controles padrão de teclado do Roblox e move o personagem com Humanoid:Move usando as
--     teclas novas (só enquanto ele usa teclado; controle e toque continuam com o padrão).
--   * Calor do deserto: longe da sombra do oásis por mais de DesertHeat.SafeTime segundos (e sem
--     o upgrade "Chapéu de Palha", stat HeatImmunity) o jogador fica mais lento e a tela fica
--     alaranjada. O centro e o raio do oásis vêm dos atributos OasisCenter/OasisRadius de workspace.Map.
--   * Velocidade de admin: o comando ":speed" (AdminService, no servidor) grava o atributo
--     "AdminWalkSpeed" no jogador enquanto a velocidade está mudada. Como este módulo escreve
--     o WalkSpeed todo quadro, ele usa esse valor como velocidade base (correr continua mais
--     rápido na mesma proporção). Sem o atributo, vale Config.Game.WalkSpeed.
--
-- API pública (usada pelo botão "Correr" do celular, pela câmera e pelo final):
--   MovementController.SetSprint(on)         liga (true) / desliga (false) a corrida (botão "Correr" do celular)
--   MovementController.SetSprintHeld(held)   igual a apertar (true) / soltar (false) a tecla de correr
--   MovementController.ToggleSprint()        liga/desliga a corrida (botão de alternar)
--   MovementController.IsSprinting() -> boolean   está correndo agora (andando + corrida ligada)
--   MovementController.SprintChanged: Signal(isSprinting)
--   MovementController.SetLocked(bool)       trava o movimento (usado na cena final)
--   MovementController.IsHeatActive() -> boolean
--   MovementController.GetBaseWalkSpeed() -> number  velocidade de andar atual (a do admin, se houver)

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")
local GameConfig = require(Config:WaitForChild("Game"))
local Keybinds = require(Config:WaitForChild("Keybinds"))
local Signal = require(Util:WaitForChild("Signal"))
local Trove = require(Util:WaitForChild("Trove"))

local Controllers = script.Parent
local StateController = require(Controllers:WaitForChild("StateController"))
local NotifyController = require(Controllers:WaitForChild("NotifyController"))

local MovementController = {}
MovementController.SprintChanged = Signal.new()

-------------------------------------------------------------------------------
-- Constantes técnicas
-------------------------------------------------------------------------------
local RENDER_STEP_NAME = "BrainrotCustomMovement"
-- Roda logo DEPOIS do controle padrão do Roblox (prioridade Input), então a nossa
-- chamada de Humanoid:Move é a que vale no frame.
local RENDER_PRIORITY = Enum.RenderPriority.Input.Value + 1

local MOVEMENT_ACTIONS = { "Forward", "Back", "Left", "Right", "Jump" }
local GAMEPAD_SPRINT_KEY = Enum.KeyCode.ButtonL3

local HEAT_CHECK_INTERVAL = 0.2 -- checa o calor 5 vezes por segundo
local HEAT_RECOVER_SECONDS = 3 -- na sombra, o "contador de sol" zera em 3 segundos
local HEAT_WARNING_BEFORE = 5 -- avisa 5 s antes de o calor começar
local HEAT_TWEEN_TIME = 1.2

-- Aparência da tela com calor (ColorCorrection local, só este jogador vê).
local HEAT_TINT = Color3.fromRGB(255, 212, 165)
local NEUTRAL_TINT = Color3.new(1, 1, 1)

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------
local player = Players.LocalPlayer
-- Papel do servidor ("Lobby" ou "Match"), lido do atributo "Role" do workspace. Ele é
-- atualizado quando o atributo muda: no Studio o lobby vira partida no mesmo servidor.
local role = "Lobby"

local settings = {
	ToggleSprint = false,
	Keybinds = {},
}

local keys = {} -- [actionId] = Enum.KeyCode atual (padrão ou remapeada)
local customMovement = false -- o jogador trocou alguma tecla de movimento?
local usingKeyboard = true -- última entrada foi teclado/mouse?
local controls = nil -- controles padrão do PlayerModule (se existirem)
local controlsDisabledByUs = false

local heldSources = {} -- [fonte] = true enquanto a tecla/botão de correr está apertado
local sprintToggled = false -- corrida ligada no modo alternar (ou pelo ToggleSprint)
local sprintForced = false -- corrida ligada "de fora" (botão "Correr" do celular, via SetSprint)
local sprinting = false -- resultado final (usado pela câmera e pelo SprintChanged)
local locked = false

local humanoid = nil
local rootPart = nil

-- Atributo que o servidor grava no jogador enquanto o ":speed" do admin está valendo.
local ADMIN_SPEED_ATTRIBUTE = "AdminWalkSpeed"

-- Calor do deserto.
local heatTimer = 0 -- segundos seguidos no sol
local heatActive = false
local heatWarned = false
local heatAccumulator = 0
local heatImmune = false
local colorCorrection = nil
local heatTween = nil

local mainTrove = Trove.new()
local characterTrove = Trove.new()

-------------------------------------------------------------------------------
-- Teclas e configurações
-------------------------------------------------------------------------------

-- Tecla atual de uma ação: a remapeada (se for um nome válido de Enum.KeyCode) ou a padrão.
local function resolveKey(actionId)
	local action = Keybinds.ById[actionId]
	local default = action and action.Default or nil
	local custom = settings.Keybinds[actionId]
	if type(custom) == "string" then
		local ok, keyCode = pcall(function()
			return Enum.KeyCode[custom]
		end)
		if ok and keyCode then
			return keyCode
		end
	end
	return default
end

local function refreshKeys()
	customMovement = false
	for _, action in ipairs(Keybinds.Actions) do
		keys[action.Id] = resolveKey(action.Id)
	end
	for _, actionId in ipairs(MOVEMENT_ACTIONS) do
		local action = Keybinds.ById[actionId]
		if action and keys[actionId] ~= action.Default then
			customMovement = true
		end
	end
end

local function refreshSettings()
	local profile = StateController.Get("Profile")
	local saved = type(profile) == "table" and profile.Settings or nil
	local wasToggle = settings.ToggleSprint
	if type(saved) == "table" then
		settings.ToggleSprint = saved.ToggleSprint == true
		settings.Keybinds = if type(saved.Keybinds) == "table" then saved.Keybinds else {}
	end
	-- Trocou de "alternar" para "segurar": desliga a corrida que estava ligada.
	if wasToggle and not settings.ToggleSprint then
		sprintToggled = false
	end
	refreshKeys()
end

-- true se o jogador está digitando num campo de texto (chat, caixas de texto).
local function isTyping()
	return UserInputService:GetFocusedTextBox() ~= nil
end

-- A última entrada foi teclado ou mouse?
local function isKeyboardInput(inputType)
	return inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseButton3
		or inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.MouseWheel
end

-------------------------------------------------------------------------------
-- Controles padrão do Roblox (PlayerModule)
-------------------------------------------------------------------------------
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

-- Deve usar o nosso movimento (teclas remapeadas) agora?
local function shouldUseCustomMovement()
	if locked then
		return true -- travado: nós mandamos "ficar parado"
	end
	return customMovement and usingKeyboard and UserInputService.KeyboardEnabled
end

-- Liga/desliga os controles padrão conforme o modo atual.
local function syncDefaultControls()
	if not controls then
		return
	end
	local wantDisabled = shouldUseCustomMovement()
	if wantDisabled and not controlsDisabledByUs then
		controlsDisabledByUs = true
		pcall(function()
			controls:Disable()
		end)
	elseif not wantDisabled and controlsDisabledByUs then
		controlsDisabledByUs = false
		pcall(function()
			controls:Enable()
		end)
	end
end

-------------------------------------------------------------------------------
-- Corrida
-------------------------------------------------------------------------------
local function anyHeld()
	for _, held in pairs(heldSources) do
		if held then
			return true
		end
	end
	return false
end

-- Recalcula se está correndo e avisa quem estiver ouvindo quando muda.
local function updateSprinting()
	local wants = sprintToggled or sprintForced or (not settings.ToggleSprint and anyHeld())
	local moving = humanoid ~= nil and humanoid.MoveDirection.Magnitude > 0.1
	local now = wants and moving and not locked and humanoid ~= nil and humanoid.Health > 0
	if now ~= sprinting then
		sprinting = now
		MovementController.SprintChanged:Fire(sprinting)
	end
end

-- Aperta/solta a corrida vindo de uma fonte (teclado, controle, celular...).
local function setHeld(source, held)
	held = held == true
	local before = heldSources[source] == true
	heldSources[source] = held or nil
	-- No modo "alternar", cada aperto (borda de subida) liga/desliga.
	if settings.ToggleSprint and held and not before then
		sprintToggled = not sprintToggled
	end
	updateSprinting()
end

-------------------------------------------------------------------------------
-- Movimento com teclas remapeadas
-------------------------------------------------------------------------------
local function isDown(actionId)
	local keyCode = keys[actionId]
	return keyCode ~= nil and UserInputService:IsKeyDown(keyCode)
end

local function onRenderStep()
	syncDefaultControls()
	if not humanoid or not shouldUseCustomMovement() then
		return
	end

	-- Travado (cena final) ou digitando: fica parado.
	if locked or isTyping() then
		humanoid:Move(Vector3.zero, false)
		humanoid.Jump = false
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local forwardAmount = (if isDown("Forward") then 1 else 0) - (if isDown("Back") then 1 else 0)
	local rightAmount = (if isDown("Right") then 1 else 0) - (if isDown("Left") then 1 else 0)

	-- Direções da câmera "achatadas" no chão (sem inclinação para cima/baixo).
	local cameraCFrame = camera.CFrame
	local look = Vector3.new(cameraCFrame.LookVector.X, 0, cameraCFrame.LookVector.Z)
	if look.Magnitude < 0.01 then
		-- Olhando reto para baixo/cima: o "UpVector" aponta para a frente.
		look = Vector3.new(cameraCFrame.UpVector.X, 0, cameraCFrame.UpVector.Z)
	end
	local right = Vector3.new(cameraCFrame.RightVector.X, 0, cameraCFrame.RightVector.Z)

	local direction = Vector3.zero
	if look.Magnitude > 0.001 then
		direction += look.Unit * forwardAmount
	end
	if right.Magnitude > 0.001 then
		direction += right.Unit * rightAmount
	end
	if direction.Magnitude > 1 then
		direction = direction.Unit
	end

	humanoid:Move(direction, false)
	humanoid.Jump = isDown("Jump")
end

-------------------------------------------------------------------------------
-- Calor do deserto
-------------------------------------------------------------------------------
local function getColorCorrection()
	if colorCorrection and colorCorrection.Parent then
		return colorCorrection
	end
	colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "DesertHeatLocal"
	colorCorrection.TintColor = NEUTRAL_TINT
	colorCorrection.Saturation = 0
	colorCorrection.Contrast = 0
	colorCorrection.Brightness = 0
	colorCorrection.Parent = Lighting
	return colorCorrection
end

local function setHeatActive(active)
	if active == heatActive then
		return
	end
	heatActive = active

	local effect = getColorCorrection()
	if heatTween then
		heatTween:Cancel()
	end
	local goal = if active
		then { TintColor = HEAT_TINT, Saturation = 0.15, Contrast = 0.06, Brightness = 0.03 }
		else { TintColor = NEUTRAL_TINT, Saturation = 0, Contrast = 0, Brightness = 0 }
	heatTween = TweenService:Create(effect, TweenInfo.new(HEAT_TWEEN_TIME, Enum.EasingStyle.Sine), goal)
	heatTween:Play()

	if active then
		NotifyController.Show("Que calor! Você ficou mais lento. Volte para a sombra do oásis.", "warning", 4)
	end
end

local function updateHeat(dt)
	local match = StateController.Get("Match")
	local isDesert = role == "Match" and type(match) == "table" and match.MapId == "Desert"
	if not isDesert or heatImmune or locked then
		heatTimer = 0
		heatWarned = false
		setHeatActive(false)
		return
	end

	local mapFolder = workspace:FindFirstChild("Map")
	local center = mapFolder and mapFolder:GetAttribute("OasisCenter")
	local radius = mapFolder and mapFolder:GetAttribute("OasisRadius")
	if typeof(center) ~= "Vector3" or type(radius) ~= "number" then
		setHeatActive(false)
		return
	end
	if not rootPart or not humanoid or humanoid.Health <= 0 then
		return
	end

	local safeTime = GameConfig.DesertHeat.SafeTime
	local offset = rootPart.Position - center
	local distance = Vector2.new(offset.X, offset.Z).Magnitude
	if distance <= radius then
		-- Na sombra: o contador desce rápido (zera em HEAT_RECOVER_SECONDS).
		heatTimer = math.max(0, heatTimer - dt * safeTime / HEAT_RECOVER_SECONDS)
		if heatTimer <= 0 then
			heatWarned = false
		end
	else
		heatTimer += dt
	end

	-- Aviso antes de começar a esquentar (uma vez por "exposição").
	if not heatWarned and not heatActive and heatTimer >= safeTime - HEAT_WARNING_BEFORE then
		heatWarned = true
		NotifyController.Show("Está esquentando... procure a sombra do oásis!", "info", 3)
	end

	setHeatActive(heatTimer >= safeTime)
end

local function refreshHeatImmunity()
	local ok, stats = pcall(StateController.GetStats)
	heatImmune = ok and type(stats) == "table" and (tonumber(stats.HeatImmunity) or 0) >= 1
end

-------------------------------------------------------------------------------
-- Velocidade (andar / correr / calor)
-------------------------------------------------------------------------------

-- Velocidade de andar "base": a do admin (atributo do servidor) ou a do Config.
local function getBaseWalkSpeed()
	local adminSpeed = player:GetAttribute(ADMIN_SPEED_ATTRIBUTE)
	if type(adminSpeed) == "number" and adminSpeed > 0 and adminSpeed == adminSpeed then
		return adminSpeed
	end
	return GameConfig.WalkSpeed
end

local function onHeartbeat(dt)
	updateSprinting()

	heatAccumulator += dt
	if heatAccumulator >= HEAT_CHECK_INTERVAL then
		updateHeat(heatAccumulator)
		heatAccumulator = 0
	end

	if not humanoid or humanoid.Health <= 0 then
		return
	end
	-- Correr multiplica a velocidade base na mesma proporção do Config (26/16 = 1,625).
	local base = getBaseWalkSpeed()
	local speed = base
	if sprinting and GameConfig.WalkSpeed > 0 then
		speed = base * GameConfig.SprintSpeed / GameConfig.WalkSpeed
	end
	if heatActive then
		speed *= GameConfig.DesertHeat.SlowMultiplier
	end
	if math.abs(humanoid.WalkSpeed - speed) > 0.01 then
		humanoid.WalkSpeed = speed
	end
end

-------------------------------------------------------------------------------
-- Entrada
-------------------------------------------------------------------------------
local function onInputBegan(input, gameProcessed)
	if isTyping() then
		return
	end
	-- Obs.: não ignoramos gameProcessed para a tecla de correr, porque o "shift lock" do
	-- Roblox pode marcar o Shift como processado mesmo sem ninguém digitando.
	if input.KeyCode == keys.Sprint and input.UserInputType == Enum.UserInputType.Keyboard then
		setHeld("Keyboard", true)
	elseif input.KeyCode == GAMEPAD_SPRINT_KEY and not gameProcessed then
		setHeld("Gamepad", true)
	end
end

local function onInputEnded(input)
	if input.KeyCode == keys.Sprint and input.UserInputType == Enum.UserInputType.Keyboard then
		setHeld("Keyboard", false)
	elseif input.KeyCode == GAMEPAD_SPRINT_KEY then
		setHeld("Gamepad", false)
	end
end

-------------------------------------------------------------------------------
-- Personagem
-------------------------------------------------------------------------------
local function onCharacterAdded(character)
	characterTrove:Clean()
	humanoid, rootPart = nil, nil
	sprintToggled = false
	sprintForced = false
	table.clear(heldSources)

	local newHumanoid = character:WaitForChild("Humanoid", 10)
	local newRoot = character:WaitForChild("HumanoidRootPart", 10)
	if not newHumanoid or not newRoot or player.Character ~= character then
		return
	end
	humanoid = newHumanoid
	rootPart = newRoot
	humanoid.WalkSpeed = getBaseWalkSpeed()

	characterTrove:Connect(humanoid.Died, function()
		sprintToggled = false
		sprintForced = false
		table.clear(heldSources)
		updateSprinting()
	end)
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Liga (true) ou desliga (false) a corrida direto. O botão "Correr" do celular
-- (MobileController) usa isto: ele mesmo já funciona como "alternar".
function MovementController.SetSprint(on)
	sprintForced = on == true
	updateSprinting()
end

-- Igual a apertar (true) ou soltar (false) a tecla de correr.
-- Respeita a configuração "Alternar corrida".
function MovementController.SetSprintHeld(held)
	setHeld("External", held)
end

-- Liga/desliga a corrida (para um botão de alternar, como o do celular).
function MovementController.ToggleSprint()
	sprintToggled = not sprintToggled
	updateSprinting()
end

function MovementController.IsSprinting()
	return sprinting
end

-- Trava/destrava o movimento do jogador (a cena final usa isto).
function MovementController.SetLocked(value)
	locked = value == true
	if locked then
		sprintToggled = false
		table.clear(heldSources)
		if humanoid then
			humanoid:Move(Vector3.zero, false)
			humanoid.Jump = false
		end
	end
	syncDefaultControls()
	updateSprinting()
end

function MovementController.IsHeatActive()
	return heatActive
end

-- Velocidade de andar atual sem correr (a do admin, se o servidor mudou; senão a do Config).
-- O FlyController usa isto para o voo ficar mais rápido junto com o ":speed".
function MovementController.GetBaseWalkSpeed()
	return getBaseWalkSpeed()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------
function MovementController.Init()
	refreshKeys()
	usingKeyboard = isKeyboardInput(UserInputService:GetLastInputType())
		or (UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled)

	mainTrove:Connect(UserInputService.InputBegan, onInputBegan)
	mainTrove:Connect(UserInputService.InputEnded, onInputEnded)
	mainTrove:Connect(UserInputService.WindowFocusReleased, function()
		-- Janela perdeu o foco: a tecla pode ter sido solta sem o jogo saber.
		heldSources.Keyboard = nil
		heldSources.Gamepad = nil
		updateSprinting()
	end)
	mainTrove:Connect(UserInputService.LastInputTypeChanged, function(inputType)
		if isKeyboardInput(inputType) then
			usingKeyboard = true
		elseif inputType == Enum.UserInputType.Touch or inputType.Name:find("Gamepad") then
			usingKeyboard = false
		end
		-- Espera o controle padrão reagir à troca e então reaplica o nosso modo.
		task.defer(function()
			if controls and controlsDisabledByUs and shouldUseCustomMovement() then
				pcall(function()
					controls:Disable()
				end)
			end
			syncDefaultControls()
		end)
	end)
end

-- Relê o papel do servidor (o atributo "Role" pode mudar de "Lobby" para "Match" no Studio).
local function refreshRole()
	local current = workspace:GetAttribute("Role")
	if current == "Lobby" or current == "Match" then
		role = current
	end
	-- O calor do deserto só vale na partida (o updateHeat confere o papel a cada 0,2 s).
	refreshHeatImmunity()
end

function MovementController.Start()
	refreshRole()
	mainTrove:Connect(workspace:GetAttributeChangedSignal("Role"), refreshRole)

	refreshSettings()
	mainTrove:Add(StateController.OnChanged("Profile", refreshSettings))

	refreshHeatImmunity()
	if type(StateController.StatsChanged) == "table" then
		mainTrove:Add(StateController.StatsChanged:Connect(refreshHeatImmunity))
	end
	mainTrove:Add(StateController.OnChanged("Match", refreshHeatImmunity))

	mainTrove:Connect(player.CharacterAdded, onCharacterAdded)
	mainTrove:Connect(player.CharacterRemoving, function()
		characterTrove:Clean()
		humanoid, rootPart = nil, nil
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end

	-- Os controles padrão podem demorar a existir: carrega sem travar o Start.
	task.spawn(function()
		loadControls()
		syncDefaultControls()
	end)

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, onRenderStep)
	mainTrove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
	mainTrove:Connect(RunService.Heartbeat, onHeartbeat)
	mainTrove:Add(function()
		if colorCorrection then
			colorCorrection:Destroy()
			colorCorrection = nil
		end
	end)
end

return MovementController
