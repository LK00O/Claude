-- PlacementController (partida, Inverno e Deserto): modo de colocar torreta.
--
-- Como funciona:
--   PlacementController.Enter() mostra um "fantasma" da torreta onde a mira aponta no chão
--   (até 60 studs). Verde = parece válido, vermelho = inválido. Também mostra o alcance.
--   * Girar: tecla "Rotate" (R), R1/L1 no controle ou botão "Girar" no celular (45° por vez).
--   * Confirmar: clique esquerdo, R2 no controle ou botão "Confirmar" no celular.
--   * Cancelar: tecla "Cancel" (Q), B no controle ou botão "Cancelar" no celular.
--   Ao confirmar, pede ao servidor Net.Request("PlaceTurret", posição, rotY). O SERVIDOR confere
--   tudo de novo (zona de torretas, distância, limite); aqui é só uma prévia aproximada.
--   rotY é enviado em RADIANOS (0 a 2π).
--
-- API pública:
--   PlacementController.Enter()     entra no modo (não faz nada se já está nele)
--   PlacementController.IsActive() -> boolean
--   PlacementController.Cancel()    sai do modo sem colocar
--   PlacementController.Confirm()   tenta colocar onde está o fantasma
--   PlacementController.Rotate(steps?)  gira 45° × steps (padrão 1)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")
local Keybinds = require(Config:WaitForChild("Keybinds"))
local Maps = require(Config:WaitForChild("Maps"))
local Net = require(Util:WaitForChild("Net"))
local Trove = require(Util:WaitForChild("Trove"))

local Controllers = script.Parent
local UIKit = require(Controllers.Parent:WaitForChild("UI"):WaitForChild("UIKit"))
local StateController = require(Controllers:WaitForChild("StateController"))
local NotifyController = require(Controllers:WaitForChild("NotifyController"))

local PlacementController = {}

-------------------------------------------------------------------------------
-- Constantes técnicas
-------------------------------------------------------------------------------
local RENDER_STEP_NAME = "BrainrotTurretPlacement"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3 -- depois da câmera

local MAX_PLACE_DISTANCE = 60 -- mesma regra do servidor (a ≤ 60 studs do jogador)
local MIN_TURRET_SPACING = 5 -- mesma regra do servidor (≥ 5 studs de outras torretas)
local MIN_GROUND_NORMAL_Y = 0.7 -- superfície precisa ser "chão" (pouco inclinada)
local ROTATION_STEP = math.rad(45)
local ENTER_GRACE_SECONDS = 0.2 -- ignora o clique que abriu o modo
local DEFAULT_RANGE = 45

local VALID_COLOR = Color3.fromRGB(90, 235, 120)
local INVALID_COLOR = Color3.fromRGB(255, 80, 80)
local GHOST_TRANSPARENCY = 0.45
local RANGE_TRANSPARENCY = 0.85

-- Textos mostrados na dica (português do Brasil).
local REASON_TEXT = {
	NoGround = "Aponte para o chão",
	TooFar = "Longe demais (máx. 60 studs)",
	TooClose = "Muito perto de outra torreta",
	OutsideZone = "Fora da área de torretas",
	Steep = "Chão inclinado demais",
	Limit = "Limite de torretas atingido",
}

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------
local player = Players.LocalPlayer
local mainTrove = Trove.new()
local sessionTrove = Trove.new() -- tudo que existe só enquanto o modo está ativo

local active = false
local busy = false -- esperando a resposta do servidor
local enteredAt = 0
local rotationY = 0
local candidatePosition = nil
local candidateValid = false
local invalidReason = nil

local ghost = nil -- {Model, Pieces = {{Part, Offset}}, Range = Part}
local ui = nil -- {Screen, Hint, Buttons}
local keys = {} -- [actionId] = Enum.KeyCode

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

local function isModalOpen()
	local ok, result = pcall(UIKit.IsAnyModalOpen)
	return ok and result == true
end

-- Esconde/mostra os ProximityPrompts enquanto o modo está ativo (para o "E" não atrapalhar).
local function setPromptsHidden(hidden)
	local prompts = Ctrl("PromptController")
	if prompts and type(prompts.SetHidden) == "function" then
		pcall(prompts.SetHidden, "TurretPlacement", hidden)
	end
end

-------------------------------------------------------------------------------
-- Utilidades
-------------------------------------------------------------------------------
local function getEffectsFolder()
	local folder = workspace:FindFirstChild("ClientEffects")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "ClientEffects"
		folder.Parent = workspace
	end
	return folder
end

local function getMapDef()
	local match = StateController.Get("Match")
	local mapId = type(match) == "table" and match.MapId or nil
	return if mapId then Maps[mapId] else nil
end

local function getRootPart()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
end

-- Nome da tecla de uma ação para mostrar na dica (ex.: Enum.KeyCode.R -> "R").
local function keyName(actionId)
	local keyCode = keys[actionId]
	return if keyCode then keyCode.Name else "?"
end

local function refreshKeys()
	local profile = StateController.Get("Profile")
	local custom = type(profile) == "table" and type(profile.Settings) == "table" and profile.Settings.Keybinds or nil
	for _, action in ipairs(Keybinds.Actions) do
		local keyCode = action.Default
		local name = type(custom) == "table" and custom[action.Id] or nil
		if type(name) == "string" then
			local ok, found = pcall(function()
				return Enum.KeyCode[name]
			end)
			if ok and found then
				keyCode = found
			end
		end
		keys[action.Id] = keyCode
	end
end

local function turretCounts()
	local turrets = StateController.Get("Turrets")
	if type(turrets) ~= "table" then
		return 0, 0
	end
	return math.floor(tonumber(turrets.Placed) or 0), math.floor(tonumber(turrets.Max) or 0)
end

local function turretRange()
	local ok, stats = pcall(StateController.GetStats)
	if ok and type(stats) == "table" and type(stats.TurretRange) == "number" then
		return stats.TurretRange
	end
	return DEFAULT_RANGE
end

-------------------------------------------------------------------------------
-- Fantasma da torreta (só visual, local)
-------------------------------------------------------------------------------
local function ghostPart(model, shape, size, offset, pieces)
	local part = Instance.new("Part")
	part.Name = "GhostPiece"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Shape = shape
	part.Size = size
	part.Transparency = GHOST_TRANSPARENCY
	part.Color = VALID_COLOR
	part.Parent = model
	table.insert(pieces, { Part = part, Offset = offset })
	return part
end

-- Monta um fantasma parecido com a torreta de verdade (base, pescoço, cabeça e cano para -Z).
local function buildGhost()
	local model = Instance.new("Model")
	model.Name = "TurretGhost"
	local pieces = {}
	local vertical = CFrame.Angles(0, 0, math.rad(90)) -- cilindro "em pé"
	local alongZ = CFrame.Angles(0, math.rad(90), 0) -- cilindro deitado no eixo Z
	ghostPart(model, Enum.PartType.Cylinder, Vector3.new(0.8, 3.2, 3.2), CFrame.new(0, 0.4, 0) * vertical, pieces)
	ghostPart(model, Enum.PartType.Cylinder, Vector3.new(1.6, 0.9, 0.9), CFrame.new(0, 1.6, 0) * vertical, pieces)
	ghostPart(model, Enum.PartType.Block, Vector3.new(1.8, 1.2, 1.8), CFrame.new(0, 2.8, 0), pieces)
	ghostPart(model, Enum.PartType.Cylinder, Vector3.new(1.8, 0.45, 0.45), CFrame.new(0, 2.85, -1.6) * alongZ, pieces)
	-- Setinha no chão mostrando para onde a torreta vai olhar.
	ghostPart(model, Enum.PartType.Block, Vector3.new(0.3, 0.1, 1.6), CFrame.new(0, 0.1, -2.6), pieces)

	-- Círculo do alcance (disco bem transparente no chão).
	local range = Instance.new("Part")
	range.Name = "RangePreview"
	range.Shape = Enum.PartType.Cylinder
	range.Anchored = true
	range.CanCollide = false
	range.CanQuery = false
	range.CanTouch = false
	range.CastShadow = false
	range.Material = Enum.Material.Neon
	range.Transparency = RANGE_TRANSPARENCY
	range.Color = VALID_COLOR
	range.Size = Vector3.new(0.15, DEFAULT_RANGE * 2, DEFAULT_RANGE * 2)
	range.Parent = model

	model.Parent = getEffectsFolder()
	return { Model = model, Pieces = pieces, Range = range, LastColor = nil }
end

local function destroyGhost()
	if ghost then
		ghost.Model:Destroy()
		ghost = nil
	end
end

local function paintGhost(valid)
	if not ghost or ghost.LastColor == valid then
		return
	end
	ghost.LastColor = valid
	local color = if valid then VALID_COLOR else INVALID_COLOR
	for _, piece in ipairs(ghost.Pieces) do
		piece.Part.Color = color
	end
	ghost.Range.Color = color
end

local function placeGhost(position, visible)
	if not ghost then
		return
	end
	if not visible or not position then
		-- Sem lugar válido na mira: esconde o fantasma bem longe.
		ghost.Model:PivotTo(CFrame.new(0, -10000, 0))
		return
	end
	local base = CFrame.new(position) * CFrame.Angles(0, rotationY, 0)
	local parts = {}
	local cframes = {}
	for _, piece in ipairs(ghost.Pieces) do
		table.insert(parts, piece.Part)
		table.insert(cframes, base * piece.Offset)
	end
	local range = turretRange()
	local diameter = math.clamp(range * 2, 2, 1000)
	if math.abs(ghost.Range.Size.Y - diameter) > 0.01 then
		ghost.Range.Size = Vector3.new(0.15, diameter, diameter)
	end
	table.insert(parts, ghost.Range)
	table.insert(cframes, CFrame.new(position + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90)))
	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

-------------------------------------------------------------------------------
-- Validação local (aproximada; o servidor tem a palavra final)
-------------------------------------------------------------------------------
local function buildRaycastParams()
	local exclude = { getEffectsFolder() }
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
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	return params
end

-- Zonas de torreta que o cliente conseguir achar (partes chamadas "TurretZone" ou com o
-- atributo TurretZone = true dentro de workspace.Map). Se não achar nenhuma, não checa.
local function findTurretZones()
	local zones = {}
	local mapFolder = workspace:FindFirstChild("Map")
	if not mapFolder then
		return zones
	end
	for _, descendant in ipairs(mapFolder:GetDescendants()) do
		if
			descendant:IsA("BasePart")
			and (descendant.Name == "TurretZone" or descendant:GetAttribute("TurretZone") == true)
		then
			table.insert(zones, descendant)
		end
	end
	return zones
end

-- Mesmo teste do servidor: dentro da parte no espaço do objeto, só X/Z.
local function isInsideZones(position, zones)
	if #zones == 0 then
		return true
	end
	for _, zone in ipairs(zones) do
		local localPosition = zone.CFrame:PointToObjectSpace(position)
		if math.abs(localPosition.X) <= zone.Size.X / 2 and math.abs(localPosition.Z) <= zone.Size.Z / 2 then
			return true
		end
	end
	return false
end

local function isTooCloseToTurret(position)
	local folder = workspace:FindFirstChild("Turrets")
	if not folder then
		return false
	end
	for _, turret in ipairs(folder:GetChildren()) do
		local pivot = nil
		if turret:IsA("Model") then
			pivot = turret:GetPivot().Position
		elseif turret:IsA("BasePart") then
			pivot = turret.Position
		end
		if pivot then
			local offset = pivot - position
			if Vector2.new(offset.X, offset.Z).Magnitude < MIN_TURRET_SPACING then
				return true
			end
		end
	end
	return false
end

-- Acha o ponto do chão para onde a mira aponta e diz se parece válido.
local cachedZones = {}
local function computeCandidate()
	local root = getRootPart()
	if not root then
		return nil, false, "NoGround"
	end

	local camera = Ctrl("CameraController")
	local aim = nil
	if camera and type(camera.GetAimCFrame) == "function" then
		local ok, result = pcall(camera.GetAimCFrame)
		if ok and typeof(result) == "CFrame" then
			aim = result
		end
	end
	if not aim then
		local currentCamera = workspace.CurrentCamera
		if not currentCamera then
			return nil, false, "NoGround"
		end
		aim = currentCamera.CFrame
	end

	local params = buildRaycastParams()
	local result = workspace:Raycast(aim.Position, aim.LookVector * MAX_PLACE_DISTANCE, params)
	local hitPosition, hitNormal
	if result then
		hitPosition, hitNormal = result.Position, result.Normal
	else
		-- Olhando para o horizonte: desce do ponto mais longe da mira até o chão.
		local farPoint = aim.Position + aim.LookVector * MAX_PLACE_DISTANCE
		local down = workspace:Raycast(farPoint + Vector3.new(0, 20, 0), Vector3.new(0, -200, 0), params)
		if not down then
			return nil, false, "NoGround"
		end
		hitPosition, hitNormal = down.Position, down.Normal
	end

	if hitNormal.Y < MIN_GROUND_NORMAL_Y then
		return hitPosition, false, "Steep"
	end
	local offset = hitPosition - root.Position
	if Vector2.new(offset.X, offset.Z).Magnitude > MAX_PLACE_DISTANCE then
		return hitPosition, false, "TooFar"
	end
	local placed, max = turretCounts()
	if placed >= max then
		return hitPosition, false, "Limit"
	end
	if isTooCloseToTurret(hitPosition) then
		return hitPosition, false, "TooClose"
	end
	if not isInsideZones(hitPosition, cachedZones) then
		return hitPosition, false, "OutsideZone"
	end
	return hitPosition, true, nil
end

-------------------------------------------------------------------------------
-- Interface (dica na tela + botões no celular)
-------------------------------------------------------------------------------
-- true se o jogador está jogando pelo toque (último toque na tela ou aparelho só de toque).
local function isTouchPrimary()
	return UserInputService:GetLastInputType() == Enum.UserInputType.Touch
		or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
end

local function isGamepadInput()
	local inputType = UserInputService:GetLastInputType()
	return inputType.Name:find("Gamepad") ~= nil
end

local function buildUI()
	if ui then
		return ui
	end
	local screen = UIKit.GetScreen("TurretPlacement", 15)

	local container = UIKit.New("Frame", {
		Name = "PlacementBar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(560, 150),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = screen,
	})

	local hint = UIKit.New("TextLabel", {
		Name = "Hint",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, 0, 0, 58),
		BackgroundColor3 = Color3.fromRGB(30, 20, 45),
		BackgroundTransparency = 0.2,
		Font = Enum.Font.GothamBold,
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = true,
		Text = "",
		Parent = container,
	})
	UIKit.New("UICorner", { CornerRadius = UDim.new(0, 14), Parent = hint })
	UIKit.New("UIStroke", { Thickness = 2, Color = Color3.fromRGB(190, 110, 255), Parent = hint })
	UIKit.New("UIPadding", {
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 6),
		Parent = hint,
	})

	-- Botões grandes para o celular (também funcionam com o mouse solto).
	local buttonsRow = UIKit.New("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0, 72),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = container,
	})
	UIKit.New("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 14),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = buttonsRow,
	})

	UIKit.Button({
		Text = "Cancelar",
		Color = Color3.fromRGB(235, 75, 95),
		Size = UDim2.fromOffset(160, 66),
		LayoutOrder = 1,
		Parent = buttonsRow,
	}, function()
		PlacementController.Cancel()
	end)
	UIKit.Button({
		Text = "Girar",
		Color = Color3.fromRGB(150, 100, 255),
		Size = UDim2.fromOffset(140, 66),
		LayoutOrder = 2,
		Parent = buttonsRow,
	}, function()
		PlacementController.Rotate(1)
	end)
	UIKit.Button({
		Text = "Confirmar",
		Color = Color3.fromRGB(70, 200, 110),
		Size = UDim2.fromOffset(180, 66),
		LayoutOrder = 3,
		Parent = buttonsRow,
	}, function()
		PlacementController.Confirm()
	end)

	ui = { Screen = screen, Container = container, Hint = hint, Buttons = buttonsRow }
	return ui
end

local function setUIVisible(visible)
	local current = buildUI()
	current.Container.Visible = visible
	current.Buttons.Visible = visible and isTouchPrimary()
end

local function updateHint()
	if not ui then
		return
	end
	local placed, max = turretCounts()
	local header = string.format("Torretas: %d/%d", placed, max)
	local controlsText
	if isTouchPrimary() then
		controlsText = "Mire no chão e toque em Confirmar"
	elseif isGamepadInput() then
		controlsText = "R2: colocar • R1/L1: girar • B: cancelar"
	else
		controlsText = string.format("Clique: colocar • %s: girar • %s: cancelar", keyName("Rotate"), keyName("Cancel"))
	end
	local status = if busy then "Colocando..." elseif candidateValid then "Lugar livre!" else (REASON_TEXT[invalidReason] or "Aponte para o chão")
	ui.Hint.Text = string.format("%s  •  %s\n%s", header, status, controlsText)
	ui.Hint.TextColor3 = if candidateValid or busy then Color3.new(1, 1, 1) else Color3.fromRGB(255, 190, 190)
end

-------------------------------------------------------------------------------
-- Frame
-------------------------------------------------------------------------------
local function onRenderStep()
	if not active then
		return
	end
	-- Morreu ou a câmera foi desligada (cena final): cancela.
	if not getRootPart() then
		PlacementController.Cancel()
		return
	end
	local camera = Ctrl("CameraController")
	if camera and type(camera.IsEnabled) == "function" and camera.IsEnabled() == false then
		PlacementController.Cancel()
		return
	end
	-- Janela aberta: pausa (esconde o fantasma e a dica) até a janela fechar.
	if isModalOpen() then
		candidatePosition = nil
		candidateValid = false
		placeGhost(nil, false)
		if ui and ui.Container.Visible then
			ui.Container.Visible = false
		end
		return
	end
	if ui and not ui.Container.Visible then
		setUIVisible(true)
	end

	local position, valid, reason = computeCandidate()
	candidatePosition = position
	candidateValid = valid
	invalidReason = reason
	paintGhost(valid)
	placeGhost(position, position ~= nil)
	updateHint()
end

-------------------------------------------------------------------------------
-- Entrada
-------------------------------------------------------------------------------
local function onInputBegan(input, gameProcessed)
	if not active or UserInputService:GetFocusedTextBox() or isModalOpen() then
		return
	end
	local keyCode = input.KeyCode
	if keyCode == keys.Rotate or keyCode == Enum.KeyCode.ButtonR1 then
		PlacementController.Rotate(1)
	elseif keyCode == Enum.KeyCode.ButtonL1 then
		PlacementController.Rotate(-1)
	elseif keyCode == keys.Cancel or keyCode == Enum.KeyCode.ButtonB then
		PlacementController.Cancel()
	elseif not gameProcessed then
		if input.UserInputType == Enum.UserInputType.MouseButton1 or keyCode == Enum.KeyCode.ButtonR2 then
			PlacementController.Confirm()
		end
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------
function PlacementController.IsActive()
	return active
end

function PlacementController.Enter()
	if active then
		return
	end
	local mapDef = getMapDef()
	if not mapDef or not mapDef.HasTurrets then
		NotifyController.Show("Não há torretas neste mapa.", "warning", 3)
		return
	end
	local placed, max = turretCounts()
	if max <= 0 then
		NotifyController.Show("Compre torretas na Barraca de Torretas primeiro!", "warning", 3)
		return
	end
	if placed >= max then
		NotifyController.Show(string.format("Limite de torretas atingido (%d/%d).", placed, max), "warning", 3)
		return
	end
	if not getRootPart() then
		return
	end

	active = true
	busy = false
	enteredAt = os.clock()
	candidatePosition = nil
	candidateValid = false
	invalidReason = nil
	cachedZones = findTurretZones()
	refreshKeys()

	ghost = buildGhost()
	sessionTrove:Add(destroyGhost)
	setPromptsHidden(true)
	sessionTrove:Add(function()
		setPromptsHidden(false)
	end)
	setUIVisible(true)
	sessionTrove:Add(function()
		setUIVisible(false)
	end)
	sessionTrove:Connect(UserInputService.LastInputTypeChanged, function()
		if ui then
			ui.Buttons.Visible = isTouchPrimary()
		end
	end)

	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, onRenderStep)
	sessionTrove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)
	onRenderStep()
end

function PlacementController.Cancel()
	if not active then
		return
	end
	active = false
	busy = false
	sessionTrove:Clean()
end

function PlacementController.Rotate(steps)
	if not active then
		return
	end
	steps = tonumber(steps) or 1
	rotationY = (rotationY + ROTATION_STEP * steps) % (math.pi * 2)
	if candidatePosition then
		placeGhost(candidatePosition, true)
	end
end

function PlacementController.Confirm()
	if not active or busy then
		return
	end
	-- Ignora o clique que acabou de abrir o modo.
	if os.clock() - enteredAt < ENTER_GRACE_SECONDS then
		return
	end
	if not candidatePosition or not candidateValid then
		pcall(UIKit.PlaySound, "Error")
		if invalidReason and REASON_TEXT[invalidReason] then
			NotifyController.Show(REASON_TEXT[invalidReason], "error", 2)
		end
		return
	end

	busy = true
	updateHint()
	local position = candidatePosition
	local rotation = rotationY
	task.spawn(function()
		local ok, result = Net.Request("PlaceTurret", position, rotation)
		busy = false
		if ok then
			NotifyController.Show("Torreta posicionada!", "success", 2)
			local effects = Ctrl("EffectsController")
			if effects and type(effects.Burst) == "function" then
				pcall(effects.Burst, position + Vector3.new(0, 1.5, 0), VALID_COLOR, 2)
			end
			PlacementController.Cancel()
		else
			pcall(UIKit.PlaySound, "Error")
			NotifyController.Show(tostring(result or "Não foi possível colocar a torreta."), "error", 3)
		end
	end)
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------
function PlacementController.Init()
	refreshKeys()
	mainTrove:Connect(UserInputService.InputBegan, onInputBegan)
end

function PlacementController.Start()
	refreshKeys()
	mainTrove:Add(StateController.OnChanged("Profile", refreshKeys))
	-- Mapa trocou (ou não tem torretas): garante que o modo não fique preso.
	mainTrove:Add(StateController.OnChanged("Match", function()
		local mapDef = getMapDef()
		if active and (not mapDef or not mapDef.HasTurrets) then
			PlacementController.Cancel()
		end
	end))
	mainTrove:Connect(player.CharacterRemoving, function()
		PlacementController.Cancel()
	end)
end

return PlacementController
