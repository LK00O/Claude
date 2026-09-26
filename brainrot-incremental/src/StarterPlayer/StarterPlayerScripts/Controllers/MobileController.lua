-- MobileController: botões grandes na tela para quem joga no celular/tablet.
--
-- Cria (só em aparelhos com toque):
--   "Atirar"  — segure para atirar (na partida). Dá para arrastar o dedo em cima
--               dele para mirar ao mesmo tempo (o toque não é "engolido" pela interface).
--   "Correr"  — liga/desliga a corrida.
--   "Torreta" — entra no modo de colocar torreta (na partida, em mapas com torretas).
-- Os botões ficam ao lado do botão de pulo do Roblox e somem quando uma janela
-- está aberta ou quando o jogador passa a usar teclado/mouse ou controle.
--
-- API (seção 10.3 da especificação):
--   MobileController.IsFireHeld() -> boolean
--   MobileController.FireChanged  -> Signal(isHeld)
-- Extras:
--   MobileController.IsSprintHeld() -> boolean (corrida ligada pelo botão)
--   MobileController.SprintChanged  -> Signal(isOn)
--   MobileController.SetSuppressed(reason, suppressed)  esconde os botões enquanto houver
--       algum motivo ativo (ex.: "Ending" durante a cena final). Quem liga/desliga a tela
--       dos botões é só este módulo: os outros pedem por aqui.
-- O papel ("Lobby"/"Match") é lido do atributo "Role" do workspace e acompanhado ao vivo
-- (no Studio o lobby vira partida no mesmo servidor e o "Atirar" precisa aparecer).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Util"):WaitForChild("Signal"))
local Config = Shared:WaitForChild("Config")
local GameConfig = require(Config:WaitForChild("Game"))
local Maps = require(Config:WaitForChild("Maps"))

local UIKit = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("UIKit"))
local StateController = require(script.Parent:WaitForChild("StateController"))

-- Outros controllers são carregados só quando precisamos (evita require circular).
-- Guardamos o resultado para não procurar de novo (isto também roda no Heartbeat,
-- então NUNCA pode ficar esperando).
local Controllers = script.Parent
local controllerCache = {} -- [nome] = módulo, ou false se deu erro ao carregar
local function Ctrl(name)
	local cached = controllerCache[name]
	if cached ~= nil then
		return cached or nil
	end
	local module = Controllers:FindFirstChild(name)
	if not module then
		return nil -- ainda não existe: tenta de novo na próxima vez
	end
	local ok, result = pcall(require, module)
	if ok then
		controllerCache[name] = result
		return result
	end
	controllerCache[name] = false
	warn(("[MobileController] Não consegui carregar %s: %s"):format(name, tostring(result)))
	return nil
end

local LocalPlayer = Players.LocalPlayer
local Theme = UIKit.Theme

local MobileController = {}
MobileController.FireChanged = Signal.new()
MobileController.SprintChanged = Signal.new()

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

local DISPLAY_ORDER = 5 -- abaixo das janelas e dos avisos
local POLL_INTERVAL = 0.2 -- de quanto em quanto tempo conferimos o modo de torreta
local LAYOUT_INTERVAL = 1 -- de quanto em quanto tempo reposicionamos os botões

-- Tipos de entrada que mostram que o jogador largou o toque (teclado, mouse, controle).
local NON_TOUCH_INPUTS = {
	[Enum.UserInputType.Keyboard] = true,
	[Enum.UserInputType.MouseButton1] = true,
	[Enum.UserInputType.MouseButton2] = true,
	[Enum.UserInputType.MouseButton3] = true,
	[Enum.UserInputType.MouseWheel] = true,
}

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local role = nil
local built = false
local screen, fireButton, fireLabel, fireScale, sprintButton, turretButton
local fireTouches = {} -- [InputObject] = true (dedos segurando o "Atirar")
local fireHeld = false
local sprintOn = false
local touchMode = false -- true = o jogador está usando a tela de toque
local modalOpen = false
local suppressReasons = {} -- [motivo] = true (qualquer motivo esconde os botões)
local placementActive = false
local mapHasTurrets = false
local pollTimer = 0
local layoutTimer = 0

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

local function isGamepadInput(inputType)
	return string.match(inputType.Name, "^Gamepad") ~= nil
end

-- Lê o botão de pulo do Roblox para posicionar os nossos ao lado dele.
-- Devolve: tamanho, distância da borda direita, distância da borda de baixo (pixels).
local function measureJumpButton(viewport)
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
	local controlFrame = touchGui and touchGui:FindFirstChild("TouchControlFrame")
	local jumpButton = controlFrame and controlFrame:FindFirstChild("JumpButton")

	if jumpButton and jumpButton:IsA("GuiObject") and jumpButton.AbsoluteSize.X > 10 then
		local size = jumpButton.AbsoluteSize.X
		local frameRight = controlFrame.AbsolutePosition.X + controlFrame.AbsoluteSize.X
		local frameBottom = controlFrame.AbsolutePosition.Y + controlFrame.AbsoluteSize.Y
		local right = frameRight - (jumpButton.AbsolutePosition.X + jumpButton.AbsoluteSize.X)
		local bottom = frameBottom - (jumpButton.AbsolutePosition.Y + jumpButton.AbsoluteSize.Y)
		if right >= 0 and bottom >= 0 then
			return size, right, bottom
		end
	end

	-- Sem o botão real: usa a mesma conta do PlayerModule do Roblox.
	local isSmallScreen = math.min(viewport.X, viewport.Y) <= 500
	local size = isSmallScreen and 70 or 120
	local right = size * 1.5 - 10 - size
	local bottom = isSmallScreen and 20 or size * 0.75
	return size, right, bottom
end

-- Coloca um botão redondo com o centro a (fromRight, fromBottom) pixels do canto.
local function place(gui, size, fromRight, fromBottom)
	gui.AnchorPoint = Vector2.new(0.5, 0.5)
	gui.Size = UDim2.fromOffset(math.floor(size), math.floor(size))
	gui.Position = UDim2.new(1, -math.floor(fromRight), 1, -math.floor(fromBottom))
end

-- Posiciona os três botões em volta do botão de pulo.
local function layout()
	if not built then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local jumpSize, rightMargin, bottomMargin = measureJumpButton(camera.ViewportSize)
	local gap = jumpSize * 0.22
	local jumpCenterX = rightMargin + jumpSize / 2
	local jumpCenterY = bottomMargin + jumpSize / 2

	-- "Atirar": maior, à esquerda do pulo, um pouco mais alto.
	local fireSize = jumpSize * 1.3
	local fireX = jumpCenterX + jumpSize / 2 + gap + fireSize / 2
	local fireY = jumpCenterY + jumpSize * 0.3
	place(fireButton, fireSize, fireX, fireY)

	-- "Correr": em cima do pulo.
	local smallSize = jumpSize * 0.8
	place(sprintButton, smallSize, jumpCenterX, jumpCenterY + jumpSize / 2 + gap + smallSize / 2)

	-- "Torreta": em cima do "Atirar".
	place(turretButton, smallSize, fireX, fireY + fireSize / 2 + gap + smallSize / 2)
end

-- Confere se um ponto da tela está dentro do botão redondo (com uma folguinha).
local function isInsideCircle(gui, position)
	local absolutePosition = gui.AbsolutePosition
	local absoluteSize = gui.AbsoluteSize
	local center = absolutePosition + absoluteSize / 2
	local radius = math.max(absoluteSize.X, absoluteSize.Y) / 2 * 1.08
	return (Vector2.new(position.X, position.Y) - center).Magnitude <= radius
end

-------------------------------------------------------------------------------
-- Tiro
-------------------------------------------------------------------------------

-- Atualiza "segurando o tiro" e avisa quem escuta FireChanged.
local function refreshFire()
	local held = next(fireTouches) ~= nil
	if held == fireHeld then
		return
	end
	fireHeld = held
	MobileController.FireChanged:Fire(held)

	if fireButton then
		-- Visual: afunda e fica mais forte enquanto segura.
		UIKit.Tween(fireScale, { Scale = held and 0.9 or 1 }, 0.08)
		UIKit.Tween(fireButton, { BackgroundTransparency = held and 0.05 or 0.25 }, 0.08)
	end
end

-- Solta o tiro (todos os dedos).
local function releaseAllFire()
	if next(fireTouches) ~= nil then
		table.clear(fireTouches)
		refreshFire()
	end
end

-- Começa a segurar o tiro com este toque.
local function beginFireTouch(input)
	if not fireButton or not fireButton.Visible or not (screen and screen.Enabled) then
		return
	end
	if fireTouches[input] then
		return
	end
	fireTouches[input] = true
	refreshFire()
end

-------------------------------------------------------------------------------
-- Corrida
-------------------------------------------------------------------------------

-- Se ninguém cuidar da corrida, mudamos a velocidade do personagem direto.
local function applySprintFallback()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = sprintOn and GameConfig.SprintSpeed or GameConfig.WalkSpeed
	end
end

local function refreshSprintLook()
	if not sprintButton then
		return
	end
	sprintButton.BackgroundColor3 = sprintOn and Theme.Success or Theme.Info
	sprintButton.Text = sprintOn and "Correndo!" or "Correr"
end

-- Liga/desliga a corrida pelo botão.
local function setSprint(on)
	on = on == true
	if sprintOn == on then
		return
	end
	sprintOn = on
	refreshSprintLook()
	MobileController.SprintChanged:Fire(on)

	-- O MovementController cuida da velocidade; se ele não tiver como receber
	-- o pedido, usamos o plano B (mudar a WalkSpeed direto).
	local movement = Ctrl("MovementController")
	if movement and type(movement.SetSprint) == "function" then
		local ok, err = pcall(movement.SetSprint, on)
		if ok then
			return
		end
		warn("[MobileController] Erro ao ligar a corrida:", err)
	end
	applySprintFallback()
end

-------------------------------------------------------------------------------
-- Visibilidade
-------------------------------------------------------------------------------

local function updateVisibility()
	if not built then
		return
	end
	-- Aparece só no modo de toque, sem janela aberta e sem nenhum motivo para esconder.
	local show = touchMode and not modalOpen and next(suppressReasons) == nil
	local inMatch = role == "Match"

	screen.Enabled = show
	fireButton.Visible = show and inMatch and not placementActive
	turretButton.Visible = show and inMatch and mapHasTurrets and not placementActive
	sprintButton.Visible = show

	if not fireButton.Visible then
		releaseAllFire()
	end
end

-- Relê o mapa atual para saber se ele tem torretas.
local function refreshMap()
	local match = StateController.Get("Match")
	local mapId = type(match) == "table" and match.MapId or nil
	local mapDef = type(mapId) == "string" and Maps[mapId] or nil
	mapHasTurrets = type(mapDef) == "table" and mapDef.HasTurrets == true
	updateVisibility()
end

-- Pergunta ao PlacementController se o modo de torreta está ativo.
local function pollPlacement()
	if role ~= "Match" or not mapHasTurrets then
		if placementActive then
			placementActive = false
			updateVisibility()
		end
		return
	end
	local placement = Ctrl("PlacementController")
	local active = false
	if placement and type(placement.IsActive) == "function" then
		local ok, result = pcall(placement.IsActive)
		active = ok and result == true
	end
	if active ~= placementActive then
		placementActive = active
		updateVisibility()
	end
end

-------------------------------------------------------------------------------
-- Construção dos botões
-------------------------------------------------------------------------------

local function build()
	if built then
		return
	end
	built = true

	-- Tela própria, SEM o UIScale do UIKit: aqui tudo é medido em pixels reais,
	-- igual ao botão de pulo do Roblox. IgnoreGuiInset = false para as posições
	-- baterem com as posições dos toques (InputObject.Position).
	screen = UIKit.New("ScreenGui", {
		Name = "MobileControls",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = DISPLAY_ORDER,
		Enabled = false,
		Parent = LocalPlayer:WaitForChild("PlayerGui"),
	})

	-- "Atirar": um Frame (não um botão) com Active = false, para o toque também
	-- chegar na câmera e o jogador conseguir mirar arrastando o dedo.
	fireButton = UIKit.New("Frame", {
		Name = "FireButton",
		Active = false,
		BackgroundColor3 = Theme.Danger,
		BackgroundTransparency = 0.25,
		Size = UDim2.fromOffset(100, 100),
		Parent = screen,
	})
	UIKit.Corner(fireButton, UDim.new(1, 0))
	UIKit.Stroke(fireButton, 3, Color3.new(1, 1, 1))
	fireScale = UIKit.New("UIScale", { Name = "UIKitScale", Parent = fireButton })
	-- Anel interno (parece uma mira).
	local ring = UIKit.New("Frame", {
		Name = "Ring",
		Active = false,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.72, 0.72),
		BackgroundTransparency = 1,
		Parent = fireButton,
	})
	UIKit.Corner(ring, UDim.new(1, 0))
	local ringStroke = UIKit.Stroke(ring, 2, Color3.new(1, 1, 1))
	ringStroke.Transparency = 0.4
	fireLabel = UIKit.New("TextLabel", {
		Name = "Label",
		Active = false,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.4),
		Font = Theme.TitleFont,
		Text = "Atirar",
		TextScaled = true,
		TextStrokeColor3 = Theme.Stroke,
		TextStrokeTransparency = 0.3,
		Parent = fireButton,
	})

	-- "Correr": liga/desliga.
	sprintButton = UIKit.Button({
		Name = "SprintButton",
		Text = "Correr",
		Color = Theme.Info,
		CornerRadius = UDim.new(1, 0),
		TextSize = 20,
		Size = UDim2.fromOffset(60, 60),
		Parent = screen,
	}, function()
		setSprint(not sprintOn)
	end)
	sprintButton.BackgroundTransparency = 0.15

	-- "Torreta": entra no modo de colocar torreta.
	turretButton = UIKit.Button({
		Name = "TurretButton",
		Text = "Torreta",
		Color = Theme.Accent2,
		CornerRadius = UDim.new(1, 0),
		TextSize = 20,
		Size = UDim2.fromOffset(60, 60),
		Parent = screen,
	}, function()
		local placement = Ctrl("PlacementController")
		if not placement or type(placement.Enter) ~= "function" then
			return
		end
		if type(placement.IsActive) == "function" then
			local ok, active = pcall(placement.IsActive)
			if ok and active then
				return
			end
		end
		local ok, err = pcall(placement.Enter)
		if not ok then
			warn("[MobileController] Erro ao entrar no modo de torreta:", err)
			return
		end
		-- Esconde já os botões; o próximo "poll" confirma o estado real.
		pollPlacement()
	end)
	turretButton.BackgroundTransparency = 0.15

	-- Toque começando em cima do "Atirar" (caminho principal: o próprio botão).
	fireButton.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and input.UserInputState == Enum.UserInputState.Begin then
			beginFireTouch(input)
		end
	end)

	refreshSprintLook()
	layout()
	updateVisibility()
end

-------------------------------------------------------------------------------
-- Entrada (toques e troca de dispositivo)
-------------------------------------------------------------------------------

-- Segundo caminho para detectar o toque no "Atirar" (pela posição na tela).
local function onInputBegan(input, gameProcessed)
	if input.UserInputType ~= Enum.UserInputType.Touch then
		return
	end
	-- Toque que começou em outro botão/janela não conta.
	if gameProcessed or not built then
		return
	end
	if fireButton.Visible and screen.Enabled and isInsideCircle(fireButton, input.Position) then
		beginFireTouch(input)
	end
end

-- Dedo saiu da tela: se era um dedo do "Atirar", solta.
local function onInputEnded(input)
	if fireTouches[input] then
		fireTouches[input] = nil
		refreshFire()
	end
end

-- O jogador trocou de dispositivo (tocou na tela, apertou tecla, mexeu no controle).
local function onLastInputTypeChanged(inputType)
	if inputType == Enum.UserInputType.Touch then
		if not touchMode then
			touchMode = true
			build()
			layout()
			updateVisibility()
		end
	elseif NON_TOUCH_INPUTS[inputType] or isGamepadInput(inputType) then
		if touchMode then
			touchMode = false
			updateVisibility()
		end
	end
end

-- Roda todo quadro (bem leve): limpa toques perdidos, confere o modo de torreta
-- e reposiciona os botões de vez em quando.
local function onHeartbeat(deltaTime)
	if not built then
		return
	end

	-- Toques que terminaram sem avisar (segurança).
	for input in pairs(fireTouches) do
		local state = input.UserInputState
		if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			fireTouches[input] = nil
		end
	end
	refreshFire()

	pollTimer += deltaTime
	if pollTimer >= POLL_INTERVAL then
		pollTimer = 0
		pollPlacement()
	end

	layoutTimer += deltaTime
	if layoutTimer >= LAYOUT_INTERVAL then
		layoutTimer = 0
		layout()
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- true enquanto o jogador segura o botão "Atirar".
function MobileController.IsFireHeld()
	return fireHeld
end

-- true enquanto a corrida está ligada pelo botão "Correr".
function MobileController.IsSprintHeld()
	return sprintOn
end

-- MobileController.SetSuppressed(reason, suppressed) — esconde (true) ou libera (false)
-- os botões por um motivo. Os botões só voltam quando TODOS os motivos forem liberados.
-- Ex.: a cena final chama SetSuppressed("Ending", true) no começo e ("Ending", false) no fim.
function MobileController.SetSuppressed(reason, suppressed)
	reason = tostring(reason or "Other")
	local value = if suppressed then true else nil
	if suppressReasons[reason] == value then
		return
	end
	suppressReasons[reason] = value
	updateVisibility()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

-- Relê o papel do servidor (o atributo "Role" pode mudar de "Lobby" para "Match" no Studio).
local function refreshRole()
	local current = workspace:GetAttribute("Role")
	if current == role then
		return
	end
	role = current
	refreshMap() -- também chama o updateVisibility (o "Atirar" aparece na partida)
end

function MobileController.Init()
	role = workspace:GetAttribute("Role")
end

function MobileController.Start()
	role = workspace:GetAttribute("Role") or role
	workspace:GetAttributeChangedSignal("Role"):Connect(refreshRole)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.LastInputTypeChanged:Connect(onLastInputTypeChanged)
	RunService.Heartbeat:Connect(onHeartbeat)

	-- Janela aberta: esconde os botões (e solta o tiro).
	UIKit.ModalChanged:Connect(function(isAnyOpen)
		modalOpen = isAnyOpen
		updateVisibility()
	end)
	modalOpen = UIKit.IsAnyModalOpen()

	-- Mapa atual (para o botão de torreta).
	StateController.OnChanged("Match", refreshMap)

	-- Ao renascer, a corrida volta a desligada e o tiro é solto.
	LocalPlayer.CharacterAdded:Connect(function()
		releaseAllFire()
		if sprintOn then
			setSprint(false)
		end
		task.delay(1, layout)
	end)

	-- Reposiciona quando o controle de toque do Roblox aparece.
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	playerGui.ChildAdded:Connect(function(child)
		if child.Name == "TouchGui" then
			task.delay(0.5, layout)
		end
	end)

	-- Aparelho com toque: já começa no modo de toque (a não ser que o último
	-- uso tenha sido teclado/mouse/controle, como num notebook com tela de toque).
	if UserInputService.TouchEnabled then
		local lastInput = UserInputService:GetLastInputType()
		touchMode = not (NON_TOUCH_INPUTS[lastInput] or isGamepadInput(lastInput))
		build()
	end
	refreshMap()
end

-- Deixa as funções do módulo funcionarem com "." e também com ":"
-- (ex.: MobileController.Algo(x) e MobileController:Algo(x) fazem a mesma coisa).
for name, fn in pairs(MobileController) do
	if type(fn) == "function" then
		MobileController[name] = function(first, ...)
			if first == MobileController then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return MobileController
