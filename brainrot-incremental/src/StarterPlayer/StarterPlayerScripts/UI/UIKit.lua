-- UIKit: o "kit de peças" de toda a interface do jogo.
--
-- Todas as telas são montadas por código usando estas funções, para o jogo
-- inteiro ter o mesmo visual (estilo cartunesco, colorido, "brainrot") e
-- funcionar no PC, no celular (toque) e no controle (gamepad).
--
-- API (seção 10.2 da especificação):
--   UIKit.Theme                                   cores, fontes e tamanhos
--   UIKit.New(className, props, children?)        cria uma Instance com propriedades
--   UIKit.GetScreen(name, displayOrder?)          ScreenGui em PlayerGui (com UIScale automático)
--   UIKit.Window(name, title, size)               janela com título, botão X e conteúdo
--   UIKit.Button(props, onClick)                  botão bonito com animação e som
--   UIKit.Label(props)                            texto
--   UIKit.ProgressBar(parent, props)              barra de progresso {Frame, Set(fração, texto?)}
--   UIKit.Corner / Stroke / Padding / List / Grid atalhos para UICorner, UIStroke etc.
--   UIKit.Tween(inst, props, time?)               animação com TweenService
--   UIKit.Pop(inst)                               efeito de "pulo"
--   UIKit.OpenModal / CloseModal / IsAnyModalOpen / ModalChanged
--   UIKit.PlaySound(key)                          som de Config.Game.Sounds com o volume do jogador
-- Extras: UIKit.GetScale(), UIKit.Darken(cor, t), UIKit.Lighten(cor, t),
--   UIKit.CloseAllWindows() (fecha todas as janelas abertas, como o Esc).

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Signal = require(Util:WaitForChild("Signal"))
local Trove = require(Util:WaitForChild("Trove"))
local GameConfig = require(Shared:WaitForChild("Config"):WaitForChild("Game"))

local StateController = require(script.Parent.Parent:WaitForChild("Controllers"):WaitForChild("StateController"))

local UIKit = {}

-------------------------------------------------------------------------------
-- Tema (cores, fontes e tamanhos)
-------------------------------------------------------------------------------

local Theme = {
	-- Fundos: roxo bem escuro e levemente translúcido.
	Background = Color3.fromRGB(24, 16, 44),
	BackgroundTransparency = 0.08,
	Panel = Color3.fromRGB(42, 28, 74),
	PanelLight = Color3.fromRGB(64, 44, 106),
	PanelDark = Color3.fromRGB(20, 13, 36),
	PanelTransparency = 0.05,
	Backdrop = Color3.fromRGB(8, 4, 16), -- véu escuro atrás das janelas
	BackdropTransparency = 0.45,

	-- Destaques "brainrot": rosa chiclete e roxo.
	Accent = Color3.fromRGB(255, 84, 178),
	Accent2 = Color3.fromRGB(146, 94, 255),
	AccentDark = Color3.fromRGB(168, 40, 118),

	-- Cores de estado.
	Success = Color3.fromRGB(70, 215, 115), -- verde: "pode comprar"
	Danger = Color3.fromRGB(242, 72, 88), -- vermelho: "sem moedas"
	Warning = Color3.fromRGB(255, 184, 46),
	Info = Color3.fromRGB(70, 172, 255),
	Rare = Color3.fromRGB(255, 214, 64), -- dourado
	Coin = Color3.fromRGB(255, 206, 58),
	Disabled = Color3.fromRGB(96, 88, 118),

	-- Texto.
	Text = Color3.fromRGB(255, 255, 255),
	TextDim = Color3.fromRGB(205, 192, 235),
	TextDark = Color3.fromRGB(34, 22, 52),
	Stroke = Color3.fromRGB(14, 6, 26), -- contorno escuro de textos e bordas

	-- Fontes (FredokaOne = títulos fofinhos; GothamBold = texto legível).
	TitleFont = Enum.Font.FredokaOne,
	Font = Enum.Font.GothamBold,
	ButtonFont = Enum.Font.FredokaOne,

	-- Tamanhos padrão.
	TextSize = 18,
	TitleSize = 28,
	SmallTextSize = 14,
	Corner = UDim.new(0, 12),
	CornerRadius = UDim.new(0, 12),
}

-- Nomes alternativos (apelidos), para facilitar a vida de quem usa o tema.
local THEME_ALIASES = {
	Primary = "Accent",
	Pink = "Accent",
	Secondary = "Accent2",
	Purple = "Accent2",
	Green = "Success",
	Positive = "Success",
	Good = "Success",
	CanBuy = "Success",
	CanAfford = "Success",
	Afford = "Success",
	Red = "Danger",
	Error = "Danger",
	Negative = "Danger",
	Bad = "Danger",
	CantBuy = "Danger",
	CantAfford = "Danger",
	NoCoins = "Danger",
	Yellow = "Warning",
	Orange = "Warning",
	Blue = "Info",
	Gold = "Rare",
	Coins = "Coin",
	Locked = "Disabled",
	Gray = "Disabled",
	Grey = "Disabled",
	White = "Text",
	SubText = "TextDim",
	TextMuted = "TextDim",
	TextSecondary = "TextDim",
	Muted = "TextDim",
	Dark = "PanelDark",
	Surface = "Panel",
	Card = "PanelLight",
	Item = "PanelLight",
	Row = "PanelLight",
	Section = "PanelLight",
	Header = "Accent2",
	Outline = "Stroke",
	Border = "Stroke",
	Shadow = "Backdrop",
	TextFont = "Font",
	BodyFont = "Font",
	NumberFont = "Font",
	HeaderFont = "TitleFont",
	FontTitle = "TitleFont",
	FontBold = "Font",
}
for alias, original in pairs(THEME_ALIASES) do
	Theme[alias] = Theme[original]
end

-- Cores por tipo de notificação (usadas no NotifyController e em outros lugares).
Theme.Kinds = {
	info = Theme.Info,
	success = Theme.Success,
	warning = Theme.Warning,
	error = Theme.Danger,
	rare = Theme.Rare,
}
Theme.Fonts = {
	Title = Theme.TitleFont,
	Text = Theme.Font,
	Body = Theme.Font,
	Button = Theme.ButtonFont,
}
-- Theme.Colors.X funciona igual a Theme.X.
Theme.Colors = Theme

-- Se alguém pedir uma chave que não existe, em vez de nil (que quebraria a tela)
-- devolvemos um valor razoável pelo nome e avisamos uma vez no Output.
local warnedThemeKeys = {}
setmetatable(Theme, {
	__index = function(_, key)
		local name = string.lower(tostring(key))
		if not warnedThemeKeys[name] then
			warnedThemeKeys[name] = true
			warn("[UIKit] UIKit.Theme." .. tostring(key) .. " não existe; usando um valor padrão.")
		end
		if string.find(name, "font", 1, true) then
			return Enum.Font.GothamBold
		elseif string.find(name, "transparency", 1, true) then
			return 0.1
		elseif string.find(name, "textsize", 1, true) or string.find(name, "fontsize", 1, true) then
			return 18
		elseif string.find(name, "corner", 1, true) or string.find(name, "radius", 1, true) then
			return UDim.new(0, 12)
		end
		return rawget(Theme, "Accent")
	end,
})

UIKit.Theme = Theme

-------------------------------------------------------------------------------
-- Constantes técnicas
-------------------------------------------------------------------------------

-- Resolução de referência: telas menores que isso encolhem a interface (UIScale).
local REF_WIDTH, REF_HEIGHT, MIN_SCALE = 1280, 720, 0.5
-- No celular a referência é menor, para os textos não ficarem minúsculos.
local TOUCH_REF_WIDTH, TOUCH_REF_HEIGHT, TOUCH_MIN_SCALE = 1100, 620, 0.55

local DEFAULT_SCREEN_ORDER = 10
local WINDOW_DISPLAY_ORDER = 30
local HEADER_HEIGHT = 56
local CONTENT_MARGIN = 14
local DEFAULT_WINDOW_SIZE = UDim2.fromOffset(620, 460)
-- Quanto da tela uma janela pode ocupar no máximo (o resto fica de respiro).
local WINDOW_MAX_WIDTH_FRACTION = 0.96
local WINDOW_MAX_HEIGHT_FRACTION = 0.9

-- Sons: volume base e quantos sons iguais podem tocar ao mesmo tempo.
local SFX_BASE_VOLUME = 0.8
local SOUND_POOL_SIZE = 4
-- Sons só de interface que não estão no Config.Game.Sounds (arquivos que já vêm no Roblox).
local UI_DEFAULT_SOUNDS = {
	Click = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.22, Speed = 1.6 },
}

-- Brilho do botão (UIGradient multiplica a cor do botão).
local GRADIENT_REST = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(212, 212, 212))
local GRADIENT_HOVER = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(240, 240, 240))
local GRADIENT_PRESSED = ColorSequence.new(Color3.fromRGB(205, 205, 205), Color3.fromRGB(178, 178, 178))
local GRADIENT_DISABLED = ColorSequence.new(Color3.fromRGB(135, 135, 135), Color3.fromRGB(108, 108, 108))

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local screens = {} -- [nome] = ScreenGui
local scaleObjects = {} -- [ScreenGui] = UIScale automático dela
local currentScale = 1 -- escala atual da interface
local windows = {} -- [nome] = janela
local openModals = {} -- [nome] = true (janelas/popups abertos)
local anyModalOpen = false
local soundFolder = nil
local soundPools = {} -- [soundId] = {Sound, Sound, ...}
local setupDone = false
local cameraConnection = nil
local warnedMessages = {}

-------------------------------------------------------------------------------
-- Ajudantes internos
-------------------------------------------------------------------------------

local function warnOnce(message)
	if not warnedMessages[message] then
		warnedMessages[message] = true
		warn(message)
	end
end

-- Escurece uma cor (amount = 0..1).
local function darken(color, amount)
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

-- Clareia uma cor (amount = 0..1).
local function lighten(color, amount)
	return color:Lerp(Color3.new(1, 1, 1), amount)
end

UIKit.Darken = darken
UIKit.Lighten = lighten

-- Converte número (pixels) ou UDim em UDim.
local function toUDim(value, default)
	if typeof(value) == "UDim" then
		return value
	elseif type(value) == "number" then
		return UDim.new(0, value)
	end
	return UDim.new(0, default or 0)
end

-- Aplica uma tabela de propriedades numa Instance.
-- Funções viram conexões de eventos (ex.: Activated = function() ... end).
-- "Parent" é devolvido para ser aplicado por último (mais rápido e seguro).
local function applyProps(inst, props, skip)
	local parent = nil
	for key, value in pairs(props) do
		if key == "Parent" then
			parent = value
		elseif type(key) == "string" and not (skip and skip[key]) then
			local ok, err = pcall(function()
				local current = inst[key]
				if typeof(current) == "RBXScriptSignal" and type(value) == "function" then
					current:Connect(value)
				else
					inst[key] = value
				end
			end)
			if not ok then
				warnOnce(("[UIKit] Não deu para aplicar '%s' em %s: %s"):format(key, inst.ClassName, tostring(err)))
			end
		end
	end
	return parent
end

-- Coloca os filhos (lista ou dicionário nome = Instance) dentro de "inst".
local function addChildren(inst, children)
	if type(children) ~= "table" then
		return
	end
	for key, child in pairs(children) do
		if typeof(child) == "Instance" then
			if type(key) == "string" then
				child.Name = key
			end
			child.Parent = inst
		end
	end
end

-- Confere se um objeto e todos os pais (até "stopAt") estão visíveis.
local function isReallyVisible(gui, stopAt)
	local current = gui
	while current and current ~= stopAt do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		current = current.Parent
	end
	return true
end

-- true se o último tipo de entrada foi um controle (gamepad).
local function isUsingGamepad()
	local inputType = UserInputService:GetLastInputType()
	return string.match(inputType.Name, "^Gamepad") ~= nil
end

-- true se o último tipo de entrada foi toque na tela.
local function isUsingTouch()
	return UserInputService:GetLastInputType() == Enum.UserInputType.Touch
end

-------------------------------------------------------------------------------
-- Criação de instâncias
-------------------------------------------------------------------------------

-- UIKit.New(className, props, children?) -> Instance
-- Cria a Instance, aplica as propriedades e coloca os filhos.
-- Objetos de GUI já vêm sem a borda feia padrão, e textos já vêm com a fonte do tema.
function UIKit.New(className, props, children)
	local inst = Instance.new(className)
	props = props or {}

	-- Valores padrão melhores que os do Roblox (as props abaixo podem trocar).
	if inst:IsA("GuiObject") then
		inst.BorderSizePixel = 0
	end
	if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
		inst.Font = Theme.Font
		inst.TextColor3 = Theme.Text
		inst.TextSize = Theme.TextSize
	end
	if inst:IsA("ScrollingFrame") then
		inst.ScrollBarThickness = 6
		inst.ScrollBarImageColor3 = Theme.Accent
	end
	if inst:IsA("TextButton") or inst:IsA("ImageButton") then
		inst.AutoButtonColor = false
	end

	local parent = applyProps(inst, props, { Children = true })
	addChildren(inst, props.Children)
	addChildren(inst, children)
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- UIKit.Corner(inst, radius?) -> UICorner (radius em pixels ou UDim; padrão 12).
function UIKit.Corner(inst, radius)
	local corner = inst:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.Parent = inst
	end
	corner.CornerRadius = toUDim(radius, 12)
	return corner
end

-- UIKit.Stroke(inst, thickness?, color?) -> UIStroke
-- Em botões e painéis o contorno vai na borda; em textos sem fundo, no texto.
function UIKit.Stroke(inst, thickness, color)
	local mode = Enum.ApplyStrokeMode.Border
	if inst:IsA("TextLabel") and inst.BackgroundTransparency >= 1 then
		mode = Enum.ApplyStrokeMode.Contextual
	end

	-- Reaproveita um contorno que já existe no mesmo modo.
	local stroke = nil
	for _, child in ipairs(inst:GetChildren()) do
		if child:IsA("UIStroke") and child.ApplyStrokeMode == mode then
			stroke = child
			break
		end
	end
	if not stroke then
		stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = mode
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Parent = inst
	end
	stroke.Thickness = tonumber(thickness) or 2
	stroke.Color = typeof(color) == "Color3" and color or Theme.Stroke
	return stroke
end

-- UIKit.Padding(inst, px) -> UIPadding (mesmo espaço nos 4 lados).
-- px pode ser número, UDim ou tabela {Top, Bottom, Left, Right}.
function UIKit.Padding(inst, px)
	local padding = inst:FindFirstChildOfClass("UIPadding")
	if not padding then
		padding = Instance.new("UIPadding")
		padding.Parent = inst
	end
	if type(px) == "table" then
		padding.PaddingTop = toUDim(px.Top or px.Y or px[1], 0)
		padding.PaddingBottom = toUDim(px.Bottom or px.Y or px[1], 0)
		padding.PaddingLeft = toUDim(px.Left or px.X or px[2] or px[1], 0)
		padding.PaddingRight = toUDim(px.Right or px.X or px[2] or px[1], 0)
	else
		local value = toUDim(px, 8)
		padding.PaddingTop = value
		padding.PaddingBottom = value
		padding.PaddingLeft = value
		padding.PaddingRight = value
	end
	return padding
end

-- Remove layouts antigos (dois layouts no mesmo pai brigam entre si).
local function removeOldLayouts(parent)
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA("UIListLayout") or child:IsA("UIGridLayout") then
			child:Destroy()
		end
	end
end

-- Converte "Horizontal"/"Vertical" (texto ou Enum) em Enum.FillDirection.
local function toFillDirection(direction)
	if typeof(direction) == "EnumItem" then
		return direction
	elseif direction == "Horizontal" then
		return Enum.FillDirection.Horizontal
	end
	return Enum.FillDirection.Vertical
end

-- UIKit.List(parent, padding?, direction?) -> UIListLayout
-- Organiza os filhos em lista (vertical por padrão), na ordem de LayoutOrder.
function UIKit.List(parent, padding, direction)
	removeOldLayouts(parent)
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = toUDim(padding, 8)
	layout.FillDirection = toFillDirection(direction)
	if layout.FillDirection == Enum.FillDirection.Vertical then
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	else
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
	end
	layout.Parent = parent
	return layout
end

-- UIKit.Grid(parent, cellSize, padding?) -> UIGridLayout
-- cellSize pode ser UDim2 ou Vector2 (pixels).
function UIKit.Grid(parent, cellSize, padding)
	removeOldLayouts(parent)
	local layout = Instance.new("UIGridLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	if typeof(cellSize) == "UDim2" then
		layout.CellSize = cellSize
	elseif typeof(cellSize) == "Vector2" then
		layout.CellSize = UDim2.fromOffset(cellSize.X, cellSize.Y)
	else
		layout.CellSize = UDim2.fromOffset(110, 110)
	end
	if typeof(padding) == "UDim2" then
		layout.CellPadding = padding
	else
		local px = tonumber(padding) or 8
		layout.CellPadding = UDim2.fromOffset(px, px)
	end
	layout.Parent = parent
	return layout
end

-------------------------------------------------------------------------------
-- Animações
-------------------------------------------------------------------------------

-- UIKit.Tween(inst, props, time?, style?, direction?) -> Tween (já tocando)
-- time pode ser um número (segundos, padrão 0,2) ou um TweenInfo pronto.
function UIKit.Tween(inst, props, time, style, direction)
	local info
	if typeof(time) == "TweenInfo" then
		info = time
	else
		info = TweenInfo.new(
			tonumber(time) or 0.2,
			style or Enum.EasingStyle.Quad,
			direction or Enum.EasingDirection.Out
		)
	end
	local tween = TweenService:Create(inst, info, props)
	tween:Play()
	return tween
end

-- Escala de repouso de UIScales que não são nossas (durante um "pulo").
local popRest = setmetatable({}, { __mode = "k" })

-- Pega o UIScale do objeto (ou cria um). Só um UIScale por objeto funciona.
local function getScaleObject(inst)
	local scale = inst:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "UIKitScale"
		scale.Parent = inst
	end
	return scale
end

-- UIKit.Pop(inst, amount?) — efeito de "pulo": cresce rapidinho e volta com um quique.
function UIKit.Pop(inst, amount)
	if typeof(inst) ~= "Instance" or not inst:IsA("GuiObject") then
		return nil
	end
	local scale = getScaleObject(inst)

	-- Escala de repouso: a guardada no atributo "Rest" (nossas UIScales) ou a atual.
	local rest = scale:GetAttribute("Rest")
	if type(rest) ~= "number" then
		rest = popRest[scale] or scale.Scale
	end
	popRest[scale] = rest

	scale.Scale = rest * (1 + (tonumber(amount) or 0.15))
	local tween =
		UIKit.Tween(scale, { Scale = rest }, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
	tween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed and popRest[scale] == rest then
			popRest[scale] = nil
		end
	end)
	return tween
end

-- Balança um objeto (usado quando clica num botão desativado).
local function shake(gui)
	local tween = UIKit.Tween(
		gui,
		{ Rotation = 4 },
		TweenInfo.new(0.05, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 3, true)
	)
	tween.Completed:Connect(function()
		gui.Rotation = 0
	end)
end

-------------------------------------------------------------------------------
-- Sons
-------------------------------------------------------------------------------

-- Converte um id (número ou texto) em "rbxassetid://..."; 0/vazio = sem som.
local function toSoundId(value)
	if type(value) == "number" then
		if value > 0 and value == value and value < math.huge then
			return "rbxassetid://" .. string.format("%d", math.floor(value))
		end
		return nil
	elseif type(value) == "string" and value ~= "" then
		if string.match(value, "^%d+$") then
			if tonumber(value) == 0 then
				return nil
			end
			return "rbxassetid://" .. value
		end
		if string.find(value, "://", 1, true) then
			return value
		end
	end
	return nil
end

-- Descobre o id, o volume base e a velocidade de um som pela chave.
local function resolveSound(key)
	if type(key) == "number" then
		return toSoundId(key), 1, 1
	end
	if type(key) ~= "string" or key == "" then
		return nil, 1, 1
	end

	local configured = GameConfig.Sounds and GameConfig.Sounds[key]
	if configured ~= nil then
		-- Está no Config: 0 significa "sem som" (o dono ainda não escolheu).
		return toSoundId(configured), 1, 1
	end

	local default = UI_DEFAULT_SOUNDS[key]
	if default then
		return default.Id, default.Volume, default.Speed
	end

	-- A chave já é um endereço de som (ex.: "rbxassetid://123").
	if string.find(key, "://", 1, true) then
		return key, 1, 1
	end
	return nil, 1, 1
end

-- Pasta local (só deste jogador) onde ficam os sons da interface.
local function getSoundFolder()
	if soundFolder and soundFolder.Parent then
		return soundFolder
	end
	soundFolder = Instance.new("Folder")
	soundFolder.Name = "UIKitSounds"
	soundFolder.Parent = SoundService
	return soundFolder
end

-- Pega um Sound livre do "pool" daquele id (reaproveita em vez de criar sempre).
local function nextPooledSound(soundId)
	local pool = soundPools[soundId]
	if not pool then
		pool = {}
		soundPools[soundId] = pool
	end

	-- Joga fora sons que foram destruídos.
	for index = #pool, 1, -1 do
		if not pool[index].Parent then
			table.remove(pool, index)
		end
	end

	-- Um som parado pode ser reusado.
	for _, sound in ipairs(pool) do
		if not sound.IsPlaying then
			return sound
		end
	end

	-- Ainda cabe mais um no pool.
	if #pool < SOUND_POOL_SIZE then
		local sound = Instance.new("Sound")
		sound.Name = "Sfx"
		sound.SoundId = soundId
		sound.Parent = getSoundFolder()
		table.insert(pool, sound)
		return sound
	end

	-- Todos tocando: reinicia o que começou há mais tempo (o primeiro da fila vai pro fim).
	local oldest = table.remove(pool, 1)
	table.insert(pool, oldest)
	return oldest
end

-- UIKit.PlaySound(key, opts?) -> Sound | nil
-- key = nome em Config.Game.Sounds (ex.: "Purchase"). Se o id for 0, não toca nada.
-- Volume = volume base × Settings.SfxVolume do jogador.
-- opts (opcional) = {Volume = multiplicador, PlaybackSpeed = velocidade}
function UIKit.PlaySound(key, opts)
	local soundId, baseVolume, speed = resolveSound(key)
	if not soundId then
		return nil
	end

	local sfxVolume = StateController.GetSettings().SfxVolume
	if type(sfxVolume) ~= "number" or sfxVolume <= 0 then
		return nil
	end

	opts = type(opts) == "table" and opts or {}
	local sound = nextPooledSound(soundId)
	sound.Volume = SFX_BASE_VOLUME * baseVolume * math.clamp(sfxVolume, 0, 1) * (tonumber(opts.Volume) or 1)
	sound.PlaybackSpeed = tonumber(opts.PlaybackSpeed or opts.Pitch) or speed
	sound.TimePosition = 0
	sound:Play()
	return sound
end

-------------------------------------------------------------------------------
-- Modais (janelas e popups que "prendem" a atenção do jogador)
-------------------------------------------------------------------------------

-- Dispara (isAnyOpen) quando passa de "nenhum aberto" para "algum aberto" e vice-versa.
UIKit.ModalChanged = Signal.new()

local function refreshModalState()
	local isAnyOpen = next(openModals) ~= nil
	if isAnyOpen ~= anyModalOpen then
		anyModalOpen = isAnyOpen
		UIKit.ModalChanged:Fire(isAnyOpen)
	end
end

-- Marca um modal como aberto (a câmera solta o mouse, os prompts somem etc.).
function UIKit.OpenModal(name)
	openModals[tostring(name or "Modal")] = true
	refreshModalState()
end

-- Marca um modal como fechado.
function UIKit.CloseModal(name)
	openModals[tostring(name or "Modal")] = nil
	refreshModalState()
end

-- true se alguma janela/popup está aberta.
function UIKit.IsAnyModalOpen()
	return anyModalOpen
end

-------------------------------------------------------------------------------
-- Telas (ScreenGui) e escala automática
-------------------------------------------------------------------------------

-- Calcula a escala da interface pelo tamanho da tela (só encolhe, nunca aumenta).
local function computeScale()
	local camera = workspace.CurrentCamera
	if not camera then
		return 1
	end
	local viewport = camera.ViewportSize
	if viewport.X < 2 or viewport.Y < 2 then
		return 1
	end

	local refWidth, refHeight, minScale = REF_WIDTH, REF_HEIGHT, MIN_SCALE
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		refWidth, refHeight, minScale = TOUCH_REF_WIDTH, TOUCH_REF_HEIGHT, TOUCH_MIN_SCALE
	end

	local scale = math.clamp(math.min(viewport.X / refWidth, viewport.Y / refHeight), minScale, 1)
	-- Arredonda para 2 casas (evita mexer na tela por diferenças mínimas).
	return math.floor(scale * 100 + 0.5) / 100
end

-- Recalcula a escala e aplica em todas as telas e janelas.
local function applyScaleToAll()
	currentScale = computeScale()
	for gui, uiScale in pairs(scaleObjects) do
		if gui.Parent and uiScale.Parent then
			uiScale.Scale = currentScale
		else
			scaleObjects[gui] = nil
		end
	end
	for _, window in pairs(windows) do
		window._Refit()
	end
end

-- Escuta mudanças de tamanho da tela (girar o celular, redimensionar a janela do PC).
local function watchCamera()
	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScaleToAll)
	end
	applyScaleToAll()
end

-- Fecha todas as janelas abertas (menos "except", se for passada).
local function closeAllWindows(except)
	-- Copia a lista antes: fechar uma janela pode criar/destruir outras.
	local toClose = {}
	for _, window in pairs(windows) do
		if window ~= except and window.IsOpen() then
			table.insert(toClose, window)
		end
	end
	for _, window in ipairs(toClose) do
		window.Close()
	end
end

-- UIKit.CloseAllWindows() — fecha todas as janelas abertas (o mesmo que o Esc faz).
-- Usado, por exemplo, pela cena final: cada janela fecha com a própria animação e
-- desliga a própria tela no fim, então ninguém de fora precisa mexer nessas telas.
function UIKit.CloseAllWindows()
	closeAllWindows(nil)
end

-- Esc (teclado) ou B (controle) fecham a janela aberta.
local function onInputBegan(input)
	local keyCode = input.KeyCode
	if keyCode ~= Enum.KeyCode.Escape and keyCode ~= Enum.KeyCode.ButtonB then
		return
	end
	-- Digitando numa caixa de texto: o Esc só tira o foco dela.
	if UserInputService:GetFocusedTextBox() then
		return
	end
	closeAllWindows(nil)
end

-- Liga os "ouvintes" globais (uma vez só). Roda sozinho no primeiro uso,
-- porque outros módulos podem usar o UIKit antes do UIKit.Init().
local function ensureSetup()
	if setupDone then
		return
	end
	setupDone = true

	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()

	UserInputService.InputBegan:Connect(onInputBegan)
	-- O Esc também abre o menu do Roblox; quando o menu abre, fechamos a janela.
	GuiService.MenuOpened:Connect(function()
		closeAllWindows(nil)
	end)
end

-- PlayerGui do jogador local.
local function getPlayerGui()
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- UIKit.GetScreen(name, displayOrder?) -> ScreenGui
-- Cria (ou reaproveita) uma ScreenGui em PlayerGui, que não some ao renascer,
-- ocupa a tela toda (inclusive atrás da barra do Roblox) e tem UIScale automático.
function UIKit.GetScreen(name, displayOrder)
	ensureSetup()
	name = tostring(name or "UIKitScreen")

	local gui = screens[name]
	if gui and gui.Parent then
		if type(displayOrder) == "number" then
			gui.DisplayOrder = displayOrder
		end
		return gui
	end

	local playerGui = getPlayerGui()
	local existing = playerGui:FindFirstChild(name)
	if existing and existing:IsA("ScreenGui") then
		gui = existing
	else
		gui = Instance.new("ScreenGui")
		gui.Name = name
	end
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = type(displayOrder) == "number" and displayOrder or DEFAULT_SCREEN_ORDER

	local uiScale = gui:FindFirstChild("UIKitScale")
	if not (uiScale and uiScale:IsA("UIScale")) then
		uiScale = Instance.new("UIScale")
		uiScale.Name = "UIKitScale"
		uiScale.Parent = gui
	end
	uiScale.Scale = currentScale
	scaleObjects[gui] = uiScale

	gui.Parent = playerGui
	screens[name] = gui
	return gui
end

-- Escala atual da interface (1 = tamanho normal; menor em telas pequenas).
function UIKit.GetScale()
	ensureSetup()
	return currentScale
end

-------------------------------------------------------------------------------
-- Texto
-------------------------------------------------------------------------------

local LABEL_SPECIAL = { Color = true, Title = true, Text = true, Children = true }

-- UIKit.Label(props) -> TextLabel
-- props: qualquer propriedade de TextLabel, mais Color (cor do texto) e Title = true (fonte de título).
function UIKit.Label(props)
	if type(props) == "string" then
		props = { Text = props }
	end
	props = props or {}

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = UDim2.new(1, 0, 0, 26)
	label.Font = props.Title and Theme.TitleFont or Theme.Font
	label.TextSize = props.Title and Theme.TitleSize or Theme.TextSize
	label.TextColor3 = typeof(props.Color) == "Color3" and props.Color or Theme.Text
	label.TextWrapped = true
	label.TextStrokeColor3 = Theme.Stroke
	label.TextStrokeTransparency = props.Title and 0.4 or 0.75
	label.Text = props.Text ~= nil and tostring(props.Text) or ""

	local parent = applyProps(label, props, LABEL_SPECIAL)
	addChildren(label, props.Children)
	if parent then
		label.Parent = parent
	end
	return label
end

-------------------------------------------------------------------------------
-- Botão
-------------------------------------------------------------------------------

local BUTTON_SPECIAL = {
	Text = true,
	Color = true,
	Size = true,
	Position = true,
	LayoutOrder = true,
	TextColor = true,
	TextColor3 = true,
	TextSize = true,
	Font = true,
	AnchorPoint = true,
	Name = true,
	Disabled = true,
	Sound = true,
	CornerRadius = true,
	Children = true,
}

-- UIKit.Button(props, onClick) -> TextButton
-- props: {Text, Color, Size, Position, LayoutOrder, Parent} e também
--        TextColor, TextSize (tamanho máximo), Font, AnchorPoint, Name,
--        CornerRadius, Disabled, Sound (chave do som; false = sem som).
-- onClick(button) roda numa thread própria (pode chamar Net.Request sem travar).
-- Para desativar depois: button.Active = false ou button:SetAttribute("Disabled", true).
-- Pode trocar a cor depois com button.BackgroundColor3 (a borda acompanha).
function UIKit.Button(props, onClick)
	if type(props) == "string" then
		props = { Text = props }
	end
	props = props or {}
	if type(onClick) ~= "function" then
		onClick = nil
	end

	local color = typeof(props.Color) == "Color3" and props.Color or Theme.Accent

	local button = Instance.new("TextButton")
	button.Name = props.Name or "Button"
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = color
	button.Size = typeof(props.Size) == "UDim2" and props.Size or UDim2.fromOffset(160, 46)
	button.Position = typeof(props.Position) == "UDim2" and props.Position or UDim2.new()
	button.AnchorPoint = typeof(props.AnchorPoint) == "Vector2" and props.AnchorPoint or Vector2.zero
	button.LayoutOrder = tonumber(props.LayoutOrder) or 0
	button.Text = props.Text ~= nil and tostring(props.Text) or ""
	button.Font = typeof(props.Font) == "EnumItem" and props.Font or Theme.ButtonFont
	button.TextColor3 = (typeof(props.TextColor) == "Color3" and props.TextColor)
		or (typeof(props.TextColor3) == "Color3" and props.TextColor3)
		or Theme.Text
	button.TextScaled = true
	button.TextWrapped = true
	button.TextStrokeColor3 = Theme.Stroke
	button.TextStrokeTransparency = 0.55
	button.Selectable = true

	-- O texto se ajusta ao botão, mas sem passar do tamanho máximo.
	local textConstraint = Instance.new("UITextSizeConstraint")
	textConstraint.MaxTextSize = tonumber(props.TextSize) or 22
	textConstraint.MinTextSize = 8
	textConstraint.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.Parent = button

	UIKit.Corner(button, props.CornerRadius or 12)

	-- Borda um pouco mais escura que o botão.
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Thickness = 2.5
	stroke.Color = darken(color, 0.45)
	stroke.Parent = button

	-- Brilho de cima para baixo (efeito "gomoso").
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = GRADIENT_REST
	gradient.Parent = button

	-- Escala usada nas animações de passar o mouse e de clique.
	local scale = Instance.new("UIScale")
	scale.Name = "UIKitScale"
	scale:SetAttribute("Rest", 1)
	scale.Parent = button

	if props.Disabled then
		button:SetAttribute("Disabled", true)
	end

	local hovered = false
	local pressed = false
	local lastClick = 0

	local function isEnabled()
		return button.Active and button:GetAttribute("Disabled") ~= true
	end

	-- Atualiza a aparência conforme o estado (normal, mouse em cima, apertado, desativado).
	local function refreshLook()
		local enabled = isEnabled()
		if not enabled then
			gradient.Color = GRADIENT_DISABLED
		elseif pressed then
			gradient.Color = GRADIENT_PRESSED
		elseif hovered then
			gradient.Color = GRADIENT_HOVER
		else
			gradient.Color = GRADIENT_REST
		end
		button.TextTransparency = enabled and 0 or 0.3

		local target = 1
		if enabled and pressed then
			target = 0.93
		elseif enabled and hovered then
			target = 1.05
		end
		UIKit.Tween(scale, { Scale = target }, 0.12)
	end

	local function setHovered(value)
		hovered = value
		if not value then
			pressed = false
		end
		refreshLook()
	end

	button.MouseEnter:Connect(function()
		setHovered(true)
	end)
	button.MouseLeave:Connect(function()
		setHovered(false)
	end)
	-- No controle, "selecionado" é o mesmo que "mouse em cima".
	button.SelectionGained:Connect(function()
		setHovered(true)
	end)
	button.SelectionLost:Connect(function()
		setHovered(false)
	end)
	button.MouseButton1Down:Connect(function()
		pressed = true
		refreshLook()
	end)
	button.MouseButton1Up:Connect(function()
		pressed = false
		refreshLook()
	end)

	button:GetPropertyChangedSignal("Active"):Connect(refreshLook)
	button:GetAttributeChangedSignal("Disabled"):Connect(refreshLook)
	-- Se o dono trocar a cor do botão, a borda acompanha.
	button:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
		stroke.Color = darken(button.BackgroundColor3, 0.45)
	end)

	-- Activated funciona com clique, toque e botão A do controle.
	button.Activated:Connect(function()
		if not isEnabled() then
			shake(button)
			return
		end
		-- Evita clique duplo acidental.
		local now = os.clock()
		if now - lastClick < 0.08 then
			return
		end
		lastClick = now

		if props.Sound ~= false then
			UIKit.PlaySound(type(props.Sound) == "string" and props.Sound or "Click")
		end

		-- Animação de clique: afunda e volta com um quique.
		scale.Scale = 0.88
		UIKit.Tween(
			scale,
			{ Scale = hovered and 1.05 or 1 },
			TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		)

		-- No toque não existe "mouse em cima": depois do toque volta ao normal.
		if isUsingTouch() then
			hovered = false
			pressed = false
			gradient.Color = GRADIENT_REST
		end

		if onClick then
			task.spawn(onClick, button)
		end
	end)

	local parent = applyProps(button, props, BUTTON_SPECIAL)
	addChildren(button, props.Children)
	refreshLook()
	if parent then
		button.Parent = parent
	end
	return button
end

-------------------------------------------------------------------------------
-- Barra de progresso
-------------------------------------------------------------------------------

local PROGRESS_SPECIAL = {
	Size = true,
	Position = true,
	AnchorPoint = true,
	LayoutOrder = true,
	Name = true,
	Color = true,
	BackgroundColor = true,
	Text = true,
	TextSize = true,
	CornerRadius = true,
	Fraction = true,
	Value = true,
	Children = true,
}

-- UIKit.ProgressBar(parent, props?) -> {Frame, Fill, Label, Set(fração, texto?), SetColor(cor)}
-- props: Size, Position, AnchorPoint, LayoutOrder, Name, Color (preenchimento),
--        BackgroundColor, Text, TextSize, CornerRadius, Fraction (valor inicial 0..1).
function UIKit.ProgressBar(parent, props)
	-- Aceita também UIKit.ProgressBar(props) com props.Parent.
	if type(parent) == "table" and props == nil then
		props = parent
		parent = props.Parent
	end
	props = props or {}

	local fillColor = typeof(props.Color) == "Color3" and props.Color or Theme.Accent

	local frame = Instance.new("Frame")
	frame.Name = props.Name or "ProgressBar"
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = typeof(props.BackgroundColor) == "Color3" and props.BackgroundColor or Theme.PanelDark
	frame.Size = typeof(props.Size) == "UDim2" and props.Size or UDim2.new(1, 0, 0, 26)
	frame.Position = typeof(props.Position) == "UDim2" and props.Position or UDim2.new()
	frame.AnchorPoint = typeof(props.AnchorPoint) == "Vector2" and props.AnchorPoint or Vector2.zero
	frame.LayoutOrder = tonumber(props.LayoutOrder) or 0

	local corner = UIKit.Corner(frame, props.CornerRadius or UDim.new(1, 0))
	UIKit.Stroke(frame, 2, Theme.Stroke)

	-- A parte colorida que "enche".
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = fillColor
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.Visible = false
	fill.ZIndex = 1
	fill.Parent = frame
	UIKit.Corner(fill, corner.CornerRadius)

	local fillGradient = Instance.new("UIGradient")
	fillGradient.Rotation = 90
	fillGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(196, 196, 196))
	fillGradient.Parent = fill

	-- Texto por cima da barra (ex.: "45%" ou "12/40").
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -12, 1, 0)
	label.Position = UDim2.fromOffset(6, 0)
	label.Font = Theme.Font
	label.TextColor3 = Theme.Text
	label.TextScaled = true
	label.TextStrokeColor3 = Theme.Stroke
	label.TextStrokeTransparency = 0.35
	label.Text = props.Text ~= nil and tostring(props.Text) or ""
	label.ZIndex = 2
	label.Parent = frame

	local labelConstraint = Instance.new("UITextSizeConstraint")
	labelConstraint.MaxTextSize = tonumber(props.TextSize) or 16
	labelConstraint.MinTextSize = 8
	labelConstraint.Parent = label

	local bar = { Frame = frame, Fill = fill, Label = label, Fraction = 0 }

	-- bar.Set(fração 0..1, texto?, instantâneo?) — também funciona como bar:Set(...).
	function bar.Set(...)
		local args = table.pack(...)
		local first = (args[1] == bar) and 2 or 1
		local fraction, text, instant = args[first], args[first + 1], args[first + 2]

		fraction = tonumber(fraction) or 0
		if fraction ~= fraction then -- NaN
			fraction = 0
		end
		fraction = math.clamp(fraction, 0, 1)
		bar.Fraction = fraction

		local target = UDim2.new(fraction, 0, 1, 0)
		if fraction > 0.001 then
			fill.Visible = true
		end
		if instant or not frame.Parent then
			fill.Size = target
			fill.Visible = fraction > 0.001
		else
			local tween = UIKit.Tween(fill, { Size = target }, 0.25)
			if fraction <= 0.001 then
				tween.Completed:Connect(function(state)
					if state == Enum.PlaybackState.Completed and bar.Fraction <= 0.001 then
						fill.Visible = false
					end
				end)
			end
		end

		if text ~= nil then
			label.Text = tostring(text)
		end
	end

	-- bar.SetColor(cor) — troca a cor do preenchimento (também bar:SetColor(cor)).
	function bar.SetColor(...)
		local args = table.pack(...)
		local color = (args[1] == bar) and args[2] or args[1]
		if typeof(color) == "Color3" then
			fill.BackgroundColor3 = color
		end
	end

	-- Outras propriedades (ZIndex, Visible...) vão direto no Frame.
	local extraParent = applyProps(frame, props, PROGRESS_SPECIAL)
	addChildren(frame, props.Children)

	local initial = tonumber(props.Fraction or props.Value)
	if initial then
		bar.Set(initial, nil, true)
	end

	local finalParent = parent or extraParent
	if typeof(finalParent) == "Instance" then
		frame.Parent = finalParent
	end
	return bar
end

-------------------------------------------------------------------------------
-- Janelas
-------------------------------------------------------------------------------

-- Acha o primeiro botão visível (de cima para baixo) para o controle selecionar.
local function findFirstSelectable(container)
	local best, bestY, bestX = nil, 0, 0
	for _, descendant in ipairs(container:GetDescendants()) do
		if
			descendant:IsA("GuiButton")
			and descendant.Selectable
			and descendant.Active
			and isReallyVisible(descendant, container)
		then
			local position = descendant.AbsolutePosition
			if not best or position.Y < bestY - 1 or (math.abs(position.Y - bestY) <= 1 and position.X < bestX) then
				best, bestY, bestX = descendant, position.Y, position.X
			end
		end
	end
	return best
end

-- Degradê usado no cabeçalho e na borda das janelas (rosa -> roxo).
local function accentSequence()
	return ColorSequence.new(Theme.Accent, Theme.Accent2)
end

-- UIKit.Window(name, title, size) -> window
-- window = {
--   Gui (ScreenGui), Frame (a janela), Content (ScrollingFrame onde vai o conteúdo),
--   Open(), Close(), IsOpen(), Toggle(), SetTitle(texto), Destroy(),
--   OnClose: Signal, OnOpen: Signal, TitleLabel, CloseButton
-- }
-- Só uma janela fica aberta por vez. Esc / B do controle / botão X fecham.
-- Open/Close/IsOpen funcionam com ponto ou dois-pontos (window.Open() ou window:Open()).
-- O Content rola sozinho quando o conteúdo passa da altura (AutomaticCanvasSize).
function UIKit.Window(name, title, size)
	ensureSetup()
	name = tostring(name or "Window")
	if typeof(size) == "Vector2" then
		size = UDim2.fromOffset(size.X, size.Y)
	end
	if typeof(size) ~= "UDim2" then
		size = DEFAULT_WINDOW_SIZE
	end

	-- Uma janela nova com o mesmo nome substitui a antiga.
	local previous = windows[name]
	if previous then
		previous.Destroy()
	end

	local trove = Trove.new()
	local window = {
		Name = name,
		OnClose = Signal.new(),
		OnOpen = Signal.new(),
	}
	local isOpen = false
	local destroyed = false
	local animationSerial = 0
	local fitScale = 1

	-- Tela própria da janela (desligada enquanto fechada).
	local screenName = "Window_" .. name
	local gui = UIKit.GetScreen(screenName, WINDOW_DISPLAY_ORDER)
	gui.Enabled = false
	for _, child in ipairs(gui:GetChildren()) do
		if child ~= scaleObjects[gui] then
			child:Destroy()
		end
	end

	-- Véu escuro atrás da janela (também impede cliques no jogo por trás).
	local backdrop = UIKit.New("Frame", {
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Backdrop,
		BackgroundTransparency = Theme.BackdropTransparency,
		Active = true,
		ZIndex = 1,
		Parent = gui,
	})

	-- A janela em si.
	local frame = UIKit.New("Frame", {
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = size,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Active = true,
		ZIndex = 2,
		Parent = gui,
	})
	UIKit.Corner(frame, 20)
	UIKit.New("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.PanelLight, Theme.PanelDark),
		Parent = frame,
	})
	local frameStroke = UIKit.Stroke(frame, 4, Color3.new(1, 1, 1))
	UIKit.New("UIGradient", { Rotation = 45, Color = accentSequence(), Parent = frameStroke })

	-- Escala da janela: encolhe se ela não couber na tela e anima ao abrir/fechar.
	local windowScale = UIKit.New("UIScale", { Name = "UIKitScale", Parent = frame })
	windowScale:SetAttribute("Rest", 1)

	-- Cabeçalho colorido com o título.
	local header = UIKit.New("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = frame,
	})
	UIKit.Corner(header, 20)
	UIKit.New("UIGradient", { Color = accentSequence(), Parent = header })
	-- Tampa os cantos arredondados de baixo do cabeçalho (só os de cima ficam redondos).
	local headerFill = UIKit.New("Frame", {
		Name = "HeaderFill",
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.new(0, 0, 1, -20),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = header,
	})
	UIKit.New("UIGradient", { Color = accentSequence(), Parent = headerFill })

	local titleLabel = UIKit.New("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(18, 4),
		Size = UDim2.new(1, -86, 1, -8),
		Font = Theme.TitleFont,
		Text = tostring(title or ""),
		TextColor3 = Theme.Text,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
		Parent = header,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 30, MinTextSize = 12, Parent = titleLabel })
	UIKit.Stroke(titleLabel, 2, Theme.Stroke)

	local closeButton = UIKit.Button({
		Name = "CloseButton",
		Text = "X",
		Color = Theme.Danger,
		Size = UDim2.fromOffset(42, 42),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		TextSize = 24,
		ZIndex = 3,
		Parent = header,
	}, function()
		window.Close()
	end)

	-- Área de conteúdo (rola quando o conteúdo é maior que a janela).
	local content = UIKit.New("ScrollingFrame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(CONTENT_MARGIN, HEADER_HEIGHT + 10),
		Size = UDim2.new(1, -CONTENT_MARGIN * 2, 1, -(HEADER_HEIGHT + 10 + CONTENT_MARGIN)),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Accent,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Selectable = false,
		ZIndex = 2,
		Parent = frame,
	})

	window.Gui = gui
	window.Frame = frame
	window.Content = content
	window.Backdrop = backdrop
	window.TitleLabel = titleLabel
	window.CloseButton = closeButton

	-- Calcula a escala para a janela caber na tela (nunca aumenta além de 1).
	local function computeFit()
		local camera = workspace.CurrentCamera
		if not camera then
			return 1
		end
		local viewport = camera.ViewportSize
		local frameSize = frame.Size
		-- Tamanho real em pixels: parte em escala (da tela) + parte em pixels (× escala da interface).
		local pixelWidth = frameSize.X.Scale * viewport.X + frameSize.X.Offset * currentScale
		local pixelHeight = frameSize.Y.Scale * viewport.Y + frameSize.Y.Offset * currentScale
		if pixelWidth <= 0 or pixelHeight <= 0 or viewport.X < 2 or viewport.Y < 2 then
			return 1
		end
		local fit = math.min(
			1,
			viewport.X * WINDOW_MAX_WIDTH_FRACTION / pixelWidth,
			viewport.Y * WINDOW_MAX_HEIGHT_FRACTION / pixelHeight
		)
		return math.max(fit, 0.3)
	end

	-- Reaplica a escala de "caber na tela" (chamado quando a tela ou o tamanho mudam).
	function window._Refit()
		if destroyed then
			return
		end
		fitScale = computeFit()
		windowScale:SetAttribute("Rest", fitScale)
		if isOpen then
			windowScale.Scale = fitScale
		end
	end
	trove:Connect(frame:GetPropertyChangedSignal("Size"), window._Refit)

	-- No controle: seleciona o primeiro botão da janela para navegar com o direcional.
	local function selectForGamepad()
		if not isUsingGamepad() then
			return
		end
		task.delay(0.1, function()
			if not isOpen or destroyed then
				return
			end
			local target = findFirstSelectable(content) or closeButton
			pcall(function()
				GuiService.SelectedObject = target
			end)
		end)
	end

	-- Abre a janela (fecha as outras).
	function window.Open()
		if isOpen or destroyed then
			return
		end
		isOpen = true
		animationSerial += 1

		-- Primeiro marca o modal desta janela, depois fecha as outras:
		-- assim o "algum modal aberto" não pisca para false no meio.
		UIKit.OpenModal(name)
		closeAllWindows(window)

		fitScale = computeFit()
		windowScale:SetAttribute("Rest", fitScale)
		gui.Enabled = true

		-- Animação de entrada: véu aparece e a janela "pula" para o tamanho certo.
		backdrop.BackgroundTransparency = 1
		UIKit.Tween(backdrop, { BackgroundTransparency = Theme.BackdropTransparency }, 0.2)
		windowScale.Scale = fitScale * 0.82
		UIKit.Tween(
			windowScale,
			{ Scale = fitScale },
			TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		)

		window.OnOpen:Fire()
		selectForGamepad()
	end

	-- Fecha a janela.
	function window.Close()
		if not isOpen then
			return
		end
		isOpen = false
		animationSerial += 1
		local serial = animationSerial

		-- Tira a seleção do controle se ela estava dentro desta janela.
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(gui) then
			GuiService.SelectedObject = nil
		end

		UIKit.CloseModal(name)

		-- Animação de saída; no fim desliga a tela (se ninguém abriu de novo no meio).
		UIKit.Tween(backdrop, { BackgroundTransparency = 1 }, 0.15)
		local tween = UIKit.Tween(
			windowScale,
			{ Scale = fitScale * 0.86 },
			TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		)
		tween.Completed:Connect(function()
			if serial == animationSerial and not isOpen and not destroyed then
				gui.Enabled = false
			end
		end)

		window.OnClose:Fire()
	end

	-- true se a janela está aberta.
	function window.IsOpen()
		return isOpen
	end

	-- Abre se estiver fechada, fecha se estiver aberta.
	function window.Toggle()
		if isOpen then
			window.Close()
		else
			window.Open()
		end
	end

	-- Troca o título (também window:SetTitle(texto)).
	function window.SetTitle(...)
		local args = table.pack(...)
		local text = (args[1] == window) and args[2] or args[1]
		titleLabel.Text = tostring(text or "")
	end

	-- Destrói a janela de vez.
	function window.Destroy()
		if destroyed then
			return
		end
		if isOpen then
			window.Close()
		end
		destroyed = true
		if windows[name] == window then
			windows[name] = nil
		end
		trove:Clean()
		scaleObjects[gui] = nil
		if screens[screenName] == gui then
			screens[screenName] = nil
		end
		gui:Destroy()
	end

	windows[name] = window
	window._Refit()
	return window
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function UIKit.Init()
	ensureSetup()
end

function UIKit.Start()
	-- Pré-carrega o som de clique, para o primeiro clique já ter som.
	task.spawn(function()
		local soundId = resolveSound("Click")
		if not soundId then
			return
		end
		local sound = nextPooledSound(soundId)
		pcall(function()
			ContentProvider:PreloadAsync({ sound })
		end)
	end)
end

-- Deixa as funções do módulo funcionarem com "." e também com ":"
-- (ex.: UIKit.Algo(x) e UIKit:Algo(x) fazem a mesma coisa).
for name, fn in pairs(UIKit) do
	if type(fn) == "function" then
		UIKit[name] = function(first, ...)
			if first == UIKit then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return UIKit
