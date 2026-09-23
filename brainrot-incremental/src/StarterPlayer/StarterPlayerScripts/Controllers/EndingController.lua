-- EndingController (partida): a cena final do jogo (Ato 3).
--
-- Quando o servidor manda Net "Ending" ({Names, Duration, SupremeName}):
--   1. Desliga a câmera do jogador (CameraController.SetEnabled(false)), trava o movimento
--      e esconde o HUD.
--   2. Toca a música "Ending" (MusicController.Play("Ending")).
--   3. A câmera sobe mostrando o Brainrot Supremo e termina olhando para o sol POR TRÁS dele
--      (o Supremo fica bem na frente do sol: o eclipse!).
--   4. Tudo escurece, aparece "ECLIPSE BRAINROT", a tela fica preta e os créditos sobem com
--      os nomes do time. No fim: "Obrigado por jogar!".
--   Dura "Duration" segundos. Depois disso o servidor manda todo mundo para o lobby; se por
--   algum motivo ninguém for teleportado (ex.: no Studio), devolvemos o controle ao jogador.
--
-- API pública:
--   EndingController.IsPlaying() -> boolean

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")
local Brainrots = require(Config:WaitForChild("Brainrots"))
local GameConfig = require(Config:WaitForChild("Game"))
local Maps = require(Config:WaitForChild("Maps"))
local Net = require(Util:WaitForChild("Net"))
local Trove = require(Util:WaitForChild("Trove"))

local Controllers = script.Parent
local UIKit = require(Controllers.Parent:WaitForChild("UI"):WaitForChild("UIKit"))
local StateController = require(Controllers:WaitForChild("StateController"))

local EndingController = {}

-------------------------------------------------------------------------------
-- Constantes técnicas
-------------------------------------------------------------------------------
local RENDER_STEP_NAME = "BrainrotEndingCamera"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 10 -- depois de tudo que mexe na câmera
local SCREEN_NAME = "EndingCinematic"
local SCREEN_ORDER = 200 -- acima de todas as outras telas

local DEFAULT_DURATION = 30
local MIN_DURATION = 12
local MAX_DURATION = 120
local RESTORE_GRACE = 10 -- segundos depois do fim para devolver o controle (se não teleportou)
local MAX_NAMES = 50

-- Momentos da cena, em fração da duração total (0 = começo, 1 = fim).
local T_FLIGHT_END = 0.36 -- a câmera chega na posição do eclipse
local T_TITLE = 0.3 -- aparece "ECLIPSE BRAINROT"
local T_DARKEN_START = 0.3 -- começa a escurecer
local T_DARKEN_END = 0.5
local T_FADE_START = 0.52 -- tela vai ficando preta
local T_FADE_END = 0.6
local T_CREDITS_START = 0.6 -- créditos sobem
local T_CREDITS_END = 0.92
local T_THANKS = 0.9 -- "Obrigado por jogar!"
local T_RETURNING = 0.97 -- "Voltando ao lobby..."

-- Cores.
local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local GOLD = Color3.fromRGB(255, 205, 70)
local PINK = Color3.fromRGB(255, 110, 200)
local LILAC = Color3.fromRGB(200, 170, 255)
local STROKE_COLOR = Color3.fromRGB(35, 15, 45)

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------
local player = Players.LocalPlayer
local mainTrove = Trove.new()
local session = nil -- Trove da cena atual (limpa tudo ao terminar)
local playing = false
local restoreState = nil -- o que precisamos devolver no fim
local restoreThread = nil -- espera para devolver o controle se não houver teleporte

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
	warn("[EndingController] Não foi possível carregar " .. name .. ": " .. tostring(result))
	return nil
end

local function callController(name, fnName, ...)
	local controller = Ctrl(name)
	local fn = controller and controller[fnName]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warn("[EndingController] Erro em " .. name .. "." .. fnName .. ": " .. tostring(result))
		return nil
	end
	return result
end

-------------------------------------------------------------------------------
-- Utilidades
-------------------------------------------------------------------------------
local function smoothstep(x)
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Curva de Bézier quadrática (caminho suave passando "perto" do ponto de controle).
local function bezier(a, control, b, t)
	local u = 1 - t
	return a * (u * u) + control * (2 * u * t) + b * (t * t)
end

local function tween(instance, time, goal, style, direction)
	local info = TweenInfo.new(time, style or Enum.EasingStyle.Sine, direction or Enum.EasingDirection.InOut)
	local created = TweenService:Create(instance, info, goal)
	created:Play()
	return created
end

-- Lista de nomes limpa (só textos, sem exagero de tamanho). Sem lista: jogadores do servidor.
local function sanitizeNames(names)
	local result = {}
	if type(names) == "table" then
		for _, name in ipairs(names) do
			if type(name) == "string" and name ~= "" then
				table.insert(result, string.sub(name, 1, 40))
				if #result >= MAX_NAMES then
					break
				end
			end
		end
	end
	if #result == 0 then
		for _, other in ipairs(Players:GetPlayers()) do
			table.insert(result, other.DisplayName)
		end
	end
	return result
end

-------------------------------------------------------------------------------
-- Onde está o Supremo?
-------------------------------------------------------------------------------
local function findSupremeInstance(supremeName)
	local supremeDef = Brainrots.Supreme or {}
	for _, name in ipairs({ supremeDef.ModelName, supremeDef.Id, "Supreme", "BrainrotSupremo", supremeName }) do
		if type(name) == "string" and name ~= "" then
			local found = workspace:FindFirstChild(name, true)
			if found and (found:IsA("Model") or found:IsA("BasePart")) then
				return found
			end
		end
	end
	-- Plano B: um modelo marcado com atributos.
	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("Model") then
			if descendant:GetAttribute("Supreme") == true or descendant:GetAttribute("BrainrotId") == supremeDef.Id then
				return descendant
			end
		end
	end
	return nil
end

-- Devolve o centro e o tamanho do Supremo (ou uma estimativa, se não achar o modelo).
local function getSupremeBounds(supremeName, sunDirection)
	local instance = findSupremeInstance(supremeName)
	if instance then
		if instance:IsA("Model") then
			local cframe, size = instance:GetBoundingBox()
			return cframe.Position, size
		end
		return instance.Position, instance.Size
	end

	-- Estimativa: ~150 studs na direção do sol a partir do jogador, com a altura do estado "Supreme".
	local camera = workspace.CurrentCamera
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local base = if root then root.Position elseif camera then camera.CFrame.Position else Vector3.zero
	local flatSun = Vector3.new(sunDirection.X, 0, sunDirection.Z)
	flatSun = if flatSun.Magnitude > 0.01 then flatSun.Unit else Vector3.new(0, 0, -1)
	local supremeState = StateController.Get("Supreme")
	local desertSupreme = Maps.Desert and Maps.Desert.Supreme
	local height = (type(supremeState) == "table" and tonumber(supremeState.Height))
		or (desertSupreme and desertSupreme.MaxHeight)
		or 300
	local center = base + flatSun * 150 + Vector3.new(0, height / 2, 0)
	return center, Vector3.new(height * 0.5, height, height * 0.5)
end

-------------------------------------------------------------------------------
-- Esconder e devolver o resto da interface
-------------------------------------------------------------------------------
local HIDDEN_CORE_GUIS = {
	Enum.CoreGuiType.PlayerList,
	Enum.CoreGuiType.Backpack,
	Enum.CoreGuiType.Health,
	Enum.CoreGuiType.EmotesMenu,
}

local function hideInterface(state)
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	state.DisabledGuis = {}
	if playerGui then
		for _, gui in ipairs(playerGui:GetChildren()) do
			-- Mantém os avisos (toasts) visíveis: a conquista secreta aparece durante o final!
			if gui:IsA("ScreenGui") and gui.Enabled and gui.Name ~= SCREEN_NAME and not gui.Name:lower():find("notif") then
				gui.Enabled = false
				table.insert(state.DisabledGuis, gui)
			end
		end
	end
	state.CoreGuis = {}
	for _, coreType in ipairs(HIDDEN_CORE_GUIS) do
		local ok, wasEnabled = pcall(StarterGui.GetCoreGuiEnabled, StarterGui, coreType)
		if ok then
			state.CoreGuis[coreType] = wasEnabled
			pcall(StarterGui.SetCoreGuiEnabled, StarterGui, coreType, false)
		end
	end
end

local function restoreInterface(state)
	for _, gui in ipairs(state.DisabledGuis or {}) do
		if gui.Parent then
			gui.Enabled = true
		end
	end
	for coreType, wasEnabled in pairs(state.CoreGuis or {}) do
		pcall(StarterGui.SetCoreGuiEnabled, StarterGui, coreType, wasEnabled)
	end
end

-------------------------------------------------------------------------------
-- Iluminação do eclipse (efeitos locais, só este jogador vê)
-------------------------------------------------------------------------------
local function prepareLighting(state, sessionTrove)
	state.Lighting = {
		Brightness = Lighting.Brightness,
		ExposureCompensation = Lighting.ExposureCompensation,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		Ambient = Lighting.Ambient,
	}

	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "EndingGrade"
	grade.Parent = Lighting
	sessionTrove:Add(grade)

	local rays = Instance.new("SunRaysEffect")
	rays.Name = "EndingSunRays"
	rays.Intensity = 0.05
	rays.Spread = 0.6
	rays.Parent = Lighting
	sessionTrove:Add(rays)

	local bloom = Instance.new("BloomEffect")
	bloom.Name = "EndingBloom"
	bloom.Intensity = 0.4
	bloom.Size = 30
	bloom.Threshold = 1.2
	bloom.Parent = Lighting
	sessionTrove:Add(bloom)

	return grade, rays, bloom
end

local function darkenLighting(time, grade, rays, bloom)
	tween(Lighting, time, {
		Brightness = 0.25,
		ExposureCompensation = -1.2,
		OutdoorAmbient = Color3.fromRGB(45, 30, 55),
		Ambient = Color3.fromRGB(30, 22, 40),
	})
	tween(grade, time, {
		TintColor = Color3.fromRGB(255, 205, 175),
		Contrast = 0.25,
		Saturation = -0.1,
	})
	-- A "coroa" do sol aparecendo em volta do Supremo.
	tween(rays, time, { Intensity = 0.4, Spread = 0.9 })
	tween(bloom, time, { Intensity = 1.2, Threshold = 0.85 })
end

local function restoreLighting(state)
	local saved = state.Lighting
	if saved then
		tween(Lighting, 1, saved)
	end
end

-------------------------------------------------------------------------------
-- Interface da cena (tela própria, sem UIScale, para cobrir a tela inteira)
-------------------------------------------------------------------------------
local function makeLabel(props)
	local label = UIKit.New("TextLabel", {
		Name = props.Name or "Line",
		BackgroundTransparency = 1,
		AnchorPoint = props.AnchorPoint or Vector2.new(0.5, 0.5),
		Position = props.Position or UDim2.fromScale(0.5, 0.5),
		Size = props.Size or UDim2.new(1, 0, 0, 0),
		AutomaticSize = props.AutomaticSize or Enum.AutomaticSize.None,
		Font = props.Font or Enum.Font.GothamBold,
		TextSize = props.TextSize or 24,
		TextScaled = props.TextScaled == true,
		TextWrapped = true,
		TextColor3 = props.Color or WHITE,
		TextTransparency = props.TextTransparency or 0,
		Text = props.Text or "",
		LayoutOrder = props.LayoutOrder or 0,
		ZIndex = props.ZIndex or 1,
		Parent = props.Parent,
	})
	UIKit.New("UIStroke", {
		Thickness = props.StrokeThickness or 2,
		Color = STROKE_COLOR,
		Transparency = props.TextTransparency or 0,
		Parent = label,
	})
	return label
end

-- Mostra/esconde um texto (e o contorno dele) suavemente.
local function fadeLabel(label, time, visible)
	local target = if visible then 0 else 1
	tween(label, time, { TextTransparency = target })
	local stroke = label:FindFirstChildOfClass("UIStroke")
	if stroke then
		tween(stroke, time, { Transparency = if visible then 0.1 else 1 })
	end
end

local function buildOverlay(sessionTrove)
	local playerGui = player:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild(SCREEN_NAME)
	if old then
		old:Destroy()
	end

	local screen = UIKit.New("ScreenGui", {
		Name = SCREEN_NAME,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = SCREEN_ORDER,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,
	})
	sessionTrove:Add(screen)

	-- Tamanho do texto proporcional à altura da tela (funciona no celular e no PC).
	local camera = workspace.CurrentCamera
	local viewportHeight = if camera then camera.ViewportSize.Y else 720
	local textScale = math.clamp(viewportHeight / 900, 0.55, 1.4)

	-- Faixas pretas de cinema (em cima e embaixo).
	local topBar = UIKit.New("Frame", {
		Name = "TopBar",
		BackgroundColor3 = BLACK,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0),
		ZIndex = 5,
		Parent = screen,
	})
	local bottomBar = UIKit.New("Frame", {
		Name = "BottomBar",
		BackgroundColor3 = BLACK,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0),
		ZIndex = 5,
		Parent = screen,
	})

	-- Título do eclipse.
	local title = makeLabel({
		Name = "Title",
		Parent = screen,
		Position = UDim2.fromScale(0.5, 0.2),
		Size = UDim2.fromScale(0.9, 0.12),
		TextScaled = true,
		Font = Enum.Font.FredokaOne,
		Color = GOLD,
		Text = "ECLIPSE BRAINROT",
		TextTransparency = 1,
		StrokeThickness = 4,
		ZIndex = 6,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 110, Parent = title })
	local subtitle = makeLabel({
		Name = "Subtitle",
		Parent = screen,
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.fromScale(0.85, 0.06),
		TextScaled = true,
		Color = WHITE,
		Text = "",
		TextTransparency = 1,
		ZIndex = 6,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 44, Parent = subtitle })

	-- Tela preta que cobre tudo.
	local fade = UIKit.New("Frame", {
		Name = "Fade",
		BackgroundColor3 = BLACK,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 10,
		Parent = screen,
	})

	-- Créditos (começam abaixo da tela e sobem).
	local credits = UIKit.New("Frame", {
		Name = "Credits",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(0.8, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 11,
		Visible = false,
		Parent = screen,
	})
	UIKit.New("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, math.floor(14 * textScale)),
		Parent = credits,
	})

	local thanks = makeLabel({
		Name = "Thanks",
		Parent = screen,
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromScale(0.9, 0.14),
		TextScaled = true,
		Font = Enum.Font.FredokaOne,
		Color = PINK,
		Text = "Obrigado por jogar!",
		TextTransparency = 1,
		StrokeThickness = 4,
		ZIndex = 12,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 120, Parent = thanks })

	local returning = makeLabel({
		Name = "Returning",
		Parent = screen,
		Position = UDim2.fromScale(0.5, 0.6),
		Size = UDim2.fromScale(0.8, 0.05),
		TextScaled = true,
		Color = LILAC,
		Text = "Voltando ao lobby...",
		TextTransparency = 1,
		ZIndex = 12,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 36, Parent = returning })

	return {
		Screen = screen,
		TopBar = topBar,
		BottomBar = bottomBar,
		Title = title,
		Subtitle = subtitle,
		Fade = fade,
		Credits = credits,
		Thanks = thanks,
		Returning = returning,
		TextScale = textScale,
	}
end

-- Preenche os créditos: nome do jogo, time, estrela e o elenco de brainrots.
local function fillCredits(overlay, names, supremeName)
	local credits = overlay.Credits
	local scale = overlay.TextScale
	local order = 0
	local function line(text, font, size, color)
		order += 1
		return makeLabel({
			Parent = credits,
			AnchorPoint = Vector2.zero,
			Position = UDim2.fromScale(0, 0),
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Font = font,
			TextSize = math.floor(size * scale),
			Color = color,
			Text = text,
			LayoutOrder = order,
			ZIndex = 11,
		})
	end
	local function spacer(height)
		order += 1
		UIKit.New("Frame", {
			Name = "Spacer",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, math.floor(height * scale)),
			LayoutOrder = order,
			Parent = credits,
		})
	end

	line(GameConfig.GameName, Enum.Font.FredokaOne, 58, PINK)
	line("Vocês alimentaram o " .. supremeName .. " até ele tampar o sol!", Enum.Font.GothamBold, 26, WHITE)
	spacer(50)

	line("Heróis do Eclipse", Enum.Font.FredokaOne, 40, GOLD)
	for _, name in ipairs(names) do
		line(name, Enum.Font.GothamBold, 30, WHITE)
	end
	spacer(50)

	line("Estrela do show", Enum.Font.FredokaOne, 40, GOLD)
	line(supremeName, Enum.Font.GothamBold, 30, WHITE)
	spacer(50)

	line("Elenco Brainrot", Enum.Font.FredokaOne, 40, GOLD)
	for _, mapId in ipairs(Maps.Order or {}) do
		local mapDef = Maps[mapId]
		local list = Brainrots.ByMap and Brainrots.ByMap[mapId]
		if mapDef and list and #list > 0 then
			spacer(14)
			line(mapDef.DisplayName, Enum.Font.FredokaOne, 30, LILAC)
			for _, def in ipairs(list) do
				line(def.DisplayName, Enum.Font.GothamBold, 24, WHITE)
			end
		end
	end
	spacer(50)

	line("Feito com Luau, carinho e muito brainrot", Enum.Font.GothamBold, 24, LILAC)
end

-------------------------------------------------------------------------------
-- Devolver tudo ao normal
-------------------------------------------------------------------------------
local function finish()
	if not playing then
		return
	end
	playing = false

	-- Cancela a espera de "devolver o controle" (a não ser que seja ela mesma rodando agora).
	if restoreThread and restoreThread ~= coroutine.running() then
		pcall(task.cancel, restoreThread)
	end
	restoreThread = nil

	local state = restoreState or {}
	restoreState = nil
	restoreLighting(state)
	restoreInterface(state)

	if session then
		session:Clean()
		session = nil
	end

	local camera = workspace.CurrentCamera
	if camera and state.FieldOfView then
		camera.FieldOfView = state.FieldOfView
	end
	callController("MovementController", "SetLocked", false)
	callController("CameraController", "SetEnabled", true)
	callController("PromptController", "SetHidden", "Ending", false)

	local match = StateController.Get("Match")
	local mapId = if type(match) == "table" and type(match.MapId) == "string" then match.MapId else "Desert"
	callController("MusicController", "Play", mapId)
end

-------------------------------------------------------------------------------
-- A cena
-------------------------------------------------------------------------------
local function playEnding(data)
	if playing then
		return
	end
	playing = true
	data = if type(data) == "table" then data else {}

	local duration = math.clamp(tonumber(data.Duration) or DEFAULT_DURATION, MIN_DURATION, MAX_DURATION)
	local names = sanitizeNames(data.Names)
	local supremeDef = Brainrots.Supreme or {}
	local supremeName = if type(data.SupremeName) == "string" and data.SupremeName ~= ""
		then string.sub(data.SupremeName, 1, 60)
		else (supremeDef.DisplayName or "Brainrot Supremo")

	session = Trove.new()
	local state = {}
	restoreState = state

	-- 1) Tira o controle do jogador.
	callController("PlacementController", "Cancel")
	callController("CameraController", "SetEnabled", false)
	callController("MovementController", "SetLocked", true)
	callController("MusicController", "Play", "Ending")
	callController("PromptController", "SetHidden", "Ending", true)
	hideInterface(state)

	local camera = workspace.CurrentCamera
	if not camera then
		finish()
		return
	end
	state.FieldOfView = camera.FieldOfView
	camera.CameraType = Enum.CameraType.Scriptable

	-- 2) Calcula o caminho da câmera.
	local sunDirection = Lighting:GetSunDirection()
	if sunDirection.Y < 0.05 then
		-- Sol quase no horizonte (ou abaixo): força um pouquinho para cima.
		sunDirection = Vector3.new(sunDirection.X, 0.05, sunDirection.Z).Unit
	end
	local center, size = getSupremeBounds(supremeName, sunDirection)
	local height = math.max(size.Y, 8)
	local groundY = center.Y - height / 2

	-- Posição do eclipse: atrás do Supremo em relação ao sol, olhando para o sol.
	-- Assim a linha câmera → centro do Supremo aponta exatamente para o sol.
	local maxDistanceByGround = (center.Y - (groundY + 12)) / sunDirection.Y
	local eclipseDistance = math.max(math.min(height * 1.3, maxDistanceByGround), 20)
	local eclipsePosition = center - sunDirection * eclipseDistance

	local startCFrame = camera.CFrame
	local startPosition = startCFrame.Position
	local startLook = startPosition + startCFrame.LookVector * 50
	local middle = startPosition:Lerp(eclipsePosition, 0.5)
	local control = Vector3.new(middle.X, math.max(startPosition.Y, eclipsePosition.Y) + height * 0.55, middle.Z)
	local upperTarget = center + Vector3.new(0, height * 0.35, 0)
	local startFov = camera.FieldOfView

	-- 3) Interface e iluminação.
	local overlay = buildOverlay(session)
	overlay.Subtitle.Text = supremeName .. " tampou o sol!"
	fillCredits(overlay, names, supremeName)
	local grade, rays, bloom = prepareLighting(state, session)

	-- 4) Câmera: voa pelo caminho e depois se aproxima devagar do eclipse.
	local startClock = os.clock()
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, function()
		local currentCamera = workspace.CurrentCamera
		if not currentCamera then
			return
		end
		if currentCamera.CameraType ~= Enum.CameraType.Scriptable then
			currentCamera.CameraType = Enum.CameraType.Scriptable
		end
		local t = (os.clock() - startClock) / duration
		local position, target, fov
		if t <= T_FLIGHT_END then
			local alpha = smoothstep(t / T_FLIGHT_END)
			position = bezier(startPosition, control, eclipsePosition, alpha)
			if alpha < 0.45 then
				target = startLook:Lerp(upperTarget, smoothstep(alpha / 0.45))
			else
				target = upperTarget:Lerp(center, smoothstep((alpha - 0.45) / 0.55))
			end
			fov = startFov + (70 - startFov) * alpha
		else
			local hold = math.clamp((t - T_FLIGHT_END) / (1 - T_FLIGHT_END), 0, 1)
			position = eclipsePosition + sunDirection * (eclipseDistance * 0.08 * smoothstep(hold))
			target = center
			fov = 70 - 22 * smoothstep(math.min(1, hold * 2))
		end
		currentCamera.CFrame = CFrame.lookAt(position, target)
		currentCamera.FieldOfView = fov
	end)
	session:Add(function()
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	end)

	-- 5) Linha do tempo da interface.
	local function at(fraction, fn)
		session:Add(task.delay(duration * fraction, fn))
	end

	tween(overlay.TopBar, 1.2, { Size = UDim2.fromScale(1, 0.11) })
	tween(overlay.BottomBar, 1.2, { Size = UDim2.fromScale(1, 0.11) })

	at(T_TITLE, function()
		fadeLabel(overlay.Title, 1.5, true)
		fadeLabel(overlay.Subtitle, 2, true)
	end)
	at(T_DARKEN_START, function()
		darkenLighting(duration * (T_DARKEN_END - T_DARKEN_START), grade, rays, bloom)
	end)
	at(T_FADE_START - 0.02, function()
		fadeLabel(overlay.Title, 1, false)
		fadeLabel(overlay.Subtitle, 1, false)
	end)
	at(T_FADE_START, function()
		tween(overlay.Fade, duration * (T_FADE_END - T_FADE_START), { BackgroundTransparency = 0 })
	end)
	at(T_CREDITS_START, function()
		local credits = overlay.Credits
		credits.Visible = true
		-- Espera um frame para o AutomaticSize calcular a altura dos créditos.
		task.wait()
		local screenHeight = math.max(overlay.Screen.AbsoluteSize.Y, 1)
		local creditsHeight = credits.AbsoluteSize.Y
		local rollTime = duration * (T_CREDITS_END - T_CREDITS_START)
		tween(
			credits,
			rollTime,
			{ Position = UDim2.new(0.5, 0, -(creditsHeight / screenHeight), 0) },
			Enum.EasingStyle.Linear,
			Enum.EasingDirection.InOut
		)
	end)
	at(T_THANKS, function()
		fadeLabel(overlay.Thanks, 1.2, true)
	end)
	at(T_RETURNING, function()
		fadeLabel(overlay.Returning, 0.8, true)
	end)

	-- 6) Se ninguém teleportou a gente, devolve o controle.
	restoreThread = task.delay(duration + RESTORE_GRACE, finish)
end

-------------------------------------------------------------------------------
-- API pública e ciclo de vida
-------------------------------------------------------------------------------
function EndingController.IsPlaying()
	return playing
end

function EndingController.Init()
	mainTrove:Add(Net.On("Ending", function(data)
		task.spawn(function()
			local ok, err = pcall(playEnding, data)
			if not ok then
				warn("[EndingController] Erro na cena final: " .. tostring(err))
				finish()
			end
		end)
	end))
end

function EndingController.Start() end

return EndingController
