-- UIKit: o "kit de peças" de toda a interface do jogo (versão 2.0).
--
-- Todas as telas são montadas por código usando estas funções, para o jogo
-- inteiro ter o mesmo visual (escuro, limpo, com toques de rosa e roxo) e
-- funcionar no PC, no celular (toque), no tablet e no controle (gamepad).
--
-- API (seção 10.2 da especificação):
--   UIKit.Theme                                   cores, fontes, tamanhos e "tokens" (ver abaixo)
--   UIKit.New(className, props, children?)        cria uma Instance com propriedades
--   UIKit.GetScreen(name, displayOrder?)          ScreenGui em PlayerGui (UIScale automático e área segura)
--   UIKit.Window(name, title, size)               janela com título, botão X e conteúdo
--   UIKit.Button(props, onClick)                  botão com animação e som (Variant, Loading...)
--   UIKit.Label(props)                            texto
--   UIKit.ProgressBar(parent, props)              barra de progresso {Frame, Set(fração, texto?)}
--   UIKit.Corner / Stroke / Padding / List / Grid atalhos para UICorner, UIStroke etc.
--   UIKit.Tween(inst, props, time?)               animação com TweenService
--   UIKit.Pop(inst)                               efeito de "pulo"
--   UIKit.OpenModal / CloseModal / IsAnyModalOpen / ModalChanged
--   UIKit.PlaySound(key, opts?)                   toca uma "vaga" de som (Config/Audio) no grupo certo
-- Novos na 2.0:
--   UIKit.TextStyle(label, estilo)                aplica um estilo de texto do Theme.Type
--   UIKit.Shadow(frame, nível)                    sombra (nível 1 ou 2) atrás de um frame solto
--   UIKit.Panel(props)                            cartão/painel com cantos, brilho e sombra opcionais
--   UIKit.Chip(props)                             etiqueta pequena em forma de pílula
--   UIKit.IconButton(props, onClick)              botão quadrado com ícone (imagem ou símbolo)
--   UIKit.Tabs(parent, abas, onSelect)            barra de abas -> {Select(id), Selected, Frame, Buttons}
--   UIKit.Tooltip(alvo, texto)                    dica que aparece ao passar o mouse / segurar
--   UIKit.Banner(props)                           faixa de comemoração -> {Dismiss(), Dismissed...}
--   UIKit.GetLayout()                             {Class, Scale, SafeInsets, TopbarHeight, IsTouch, ...}
--   UIKit.LayoutChanged                           Signal(layout) quando o tipo de tela muda
--   UIKit.IsReducedMotion()                       true se o jogador pediu "menos movimento"
--   UIKit.ResolveSound(key)                       -> (soundId?, volume, velocidade, grupo)
--   UIKit.GetSoundGroup(nome)                     SoundGroup "Master"/"Music"/"SFX"/"UI"/"Ambient"
-- Extras: UIKit.GetScale(), UIKit.Darken(cor, t), UIKit.Lighten(cor, t),
--   UIKit.CloseAllWindows() (fecha todas as janelas abertas, como o Esc).

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local ConfigFolder = Shared:WaitForChild("Config")
local Signal = require(Util:WaitForChild("Signal"))
local Trove = require(Util:WaitForChild("Trove"))
local GameConfig = require(ConfigFolder:WaitForChild("Game"))

local StateController = require(script.Parent.Parent:WaitForChild("Controllers"):WaitForChild("StateController"))

-- Carrega um Config opcional sem derrubar a interface se ele faltar ou tiver erro.
local function requireConfig(name)
	local module = ConfigFolder:FindFirstChild(name) or ConfigFolder:WaitForChild(name, 5)
	if not module then
		warn("[UIKit] Config/" .. name .. " não encontrado; usando valores padrão.")
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	warn("[UIKit] Erro ao carregar Config/" .. name .. ": " .. tostring(result))
	return nil
end

local AudioConfig = requireConfig("Audio") or {}
local BrainrotsConfig = requireConfig("Brainrots")
local EnchantsConfig = requireConfig("Enchants")

local UIKit = {}

-------------------------------------------------------------------------------
-- Tema v2 (cores, fontes, tamanhos, espaços, cantos, sombras, movimento)
-------------------------------------------------------------------------------

local rgb = Color3.fromRGB

local Theme = {
	-- Fundos (do mais fundo para o mais "alto"): roxo bem escuro.
	Bg = rgb(18, 12, 34), -- fundo geral
	Surface = rgb(29, 21, 53), -- janelas e painéis
	SurfaceRaised = rgb(40, 29, 72), -- cartões dentro das janelas
	SurfaceHover = rgb(51, 38, 91), -- cartão/botão com o mouse em cima
	SurfaceSunken = rgb(12, 8, 23), -- "buracos": fundo de barras, campos de texto
	Backdrop = rgb(6, 3, 12), -- véu escuro atrás das janelas
	BackdropTransparency = 0.4,

	-- Destaques "brainrot": rosa chiclete e roxo. Só em botões principais,
	-- foco e faixinhas de destaque (nunca num cabeçalho inteiro).
	Accent = rgb(255, 84, 178),
	Accent2 = rgb(146, 94, 255),

	-- Texto.
	Text = rgb(255, 255, 255),
	TextDim = rgb(201, 191, 227), -- texto secundário
	TextMuted = rgb(142, 132, 173), -- texto bem apagado (dicas, rodapés)
	TextDark = rgb(28, 18, 48), -- texto em cima de cores claras
	Stroke = rgb(7, 4, 14), -- contorno escuro de textos e bordas

	-- Cores de estado.
	Success = rgb(63, 210, 122), -- verde: "pode comprar"
	Danger = rgb(240, 72, 90), -- vermelho: "sem moedas"
	Warning = rgb(255, 181, 46),
	Info = rgb(74, 168, 255),
	Coin = rgb(255, 204, 51),
	CoinDeep = rgb(199, 133, 26), -- dourado escuro (parte de baixo da moeda)
	Rare = rgb(255, 216, 74), -- dourado
	Disabled = rgb(96, 88, 118),

	-- Brilho de 1 px no topo dos painéis.
	Highlight = rgb(255, 255, 255),
	HighlightTransparency = 0.85,
}

-- Nomes da versão 1 (continuam valendo; agora vêm da paleta nova).
Theme.Background = Theme.Bg
Theme.BackgroundTransparency = 0.08
Theme.Panel = Theme.Surface
Theme.PanelLight = Theme.SurfaceRaised
Theme.PanelDark = Theme.SurfaceSunken
Theme.PanelTransparency = 0.05
Theme.AccentDark = Theme.Accent:Lerp(Color3.new(0, 0, 0), 0.34)

-- Fontes: FredokaOne (fofinha) nos títulos e botões; BuilderSans (a fonte do
-- Roblox, muito legível e já instalada no aparelho) no resto.
Theme.TitleFont = Enum.Font.FredokaOne
Theme.Font = Enum.Font.BuilderSansBold
Theme.ButtonFont = Enum.Font.FredokaOne
Theme.NumberFont = Enum.Font.BuilderSansExtraBold

-- Estilos de texto (UIKit.TextStyle). Size = tamanho no PC; PhoneBoost = quanto
-- cresce no celular. Nunca fica menor que 12 pt de verdade na tela (celular/tablet).
Theme.Type = {
	Display = { Font = Enum.Font.FredokaOne, Size = 36 },
	Title = { Font = Enum.Font.FredokaOne, Size = 26 },
	Heading = { Font = Enum.Font.FredokaOne, Size = 20 },
	Button = { Font = Enum.Font.FredokaOne, Size = 20 },
	Body = { Font = Enum.Font.BuilderSansMedium, Size = 16, PhoneBoost = 2 },
	BodyStrong = { Font = Enum.Font.BuilderSansBold, Size = 16, PhoneBoost = 2 },
	Caption = { Font = Enum.Font.BuilderSansMedium, Size = 13, PhoneBoost = 2 },
	Number = { Font = Enum.Font.BuilderSansExtraBold, Size = 18 },
}

-- Espaços padrão (em pixels da interface).
Theme.Space = {
	XS = 4,
	S = 8,
	M = 12,
	L = 16,
	XL = 24,
	XXL = 32,
	ButtonX = 12, -- respiro lateral do texto dos botões
	ButtonY = 6,
	Card = 12, -- respiro dentro dos cartões
	Window = 16, -- margem do conteúdo das janelas
	Hud = 16, -- margem do HUD no PC
	HudPhone = 12, -- margem do HUD no celular (mais a área segura)
}

-- Cantos arredondados.
Theme.Radius = {
	S = UDim.new(0, 6),
	M = UDim.new(0, 10), -- botões
	L = UDim.new(0, 14), -- cartões
	XL = UDim.new(0, 18), -- janelas
	Pill = UDim.new(1, 0), -- pílula (lados totalmente redondos)
}

-- Sombras (UIKit.Shadow): cada camada é um frame preto deslocado para baixo.
Theme.Elevation = {
	[1] = { { Offset = Vector2.new(0, 3), Transparency = 0.7 } },
	[2] = {
		{ Offset = Vector2.new(0, 6), Transparency = 0.72 },
		{ Offset = Vector2.new(0, 14), Transparency = 0.88 },
	},
}
Theme.Elevation.E1 = Theme.Elevation[1]
Theme.Elevation.E2 = Theme.Elevation[2]

-- Tempos das animações (segundos). Com "menos movimento" ligado no Roblox,
-- animações de escala/deslize ficam instantâneas e só os "fades" continuam.
Theme.Motion = {
	Press = 0.08, -- apertar um botão
	Hover = 0.14, -- mouse em cima
	Base = 0.18, -- trocas simples
	Enter = 0.24, -- algo entrando (janela abrindo)
	Exit = 0.14, -- algo saindo (janela fechando)
	Pop = 0.3, -- "pulo"
	Roll = 0.6, -- máximo para números "correndo"
	EnterStyle = Enum.EasingStyle.Back,
	EnterDirection = Enum.EasingDirection.Out,
	ExitStyle = Enum.EasingStyle.Quad,
	ExitDirection = Enum.EasingDirection.In,
	PopStyle = Enum.EasingStyle.Back,
}

-- Tamanhos da versão 1 (derivados dos tokens novos).
Theme.TextSize = 18
Theme.TitleSize = 28
Theme.SmallTextSize = 14
Theme.Corner = Theme.Radius.M
Theme.CornerRadius = Theme.Radius.M

-- Nomes alternativos (apelidos), para facilitar a vida de quem usa o tema.
-- Um apelido nunca substitui uma cor que já existe (ex.: TextMuted e Surface são cores próprias).
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
	if rawget(Theme, alias) == nil then
		Theme[alias] = Theme[original]
	end
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
	Number = Theme.NumberFont,
	Display = Theme.Type.Display.Font,
	Caption = Theme.Type.Caption.Font,
}

-- Cores de raridade: tiers dos brainrots (Config/Brainrots), encantamentos
-- (Config/Enchants) e o Supremo (dourado). Ex.: Theme.Rarity.High, Theme.Rarity.Galactic.
Theme.Rarity = {}
if BrainrotsConfig and type(BrainrotsConfig.Tiers) == "table" then
	for tierId, tier in pairs(BrainrotsConfig.Tiers) do
		if type(tier) == "table" and typeof(tier.Color) == "Color3" then
			Theme.Rarity[tierId] = tier.Color
		end
	end
end
if EnchantsConfig and type(EnchantsConfig.List) == "table" then
	for _, enchant in ipairs(EnchantsConfig.List) do
		if type(enchant) == "table" and type(enchant.Id) == "string" and typeof(enchant.Color) == "Color3" then
			Theme.Rarity[enchant.Id] = enchant.Color
		end
	end
end
Theme.Rarity.Supreme = Theme.Rare

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
			return rawget(Theme, "Font")
		elseif string.find(name, "transparency", 1, true) then
			return 0.1
		elseif string.find(name, "textsize", 1, true) or string.find(name, "fontsize", 1, true) then
			return 18
		elseif string.find(name, "corner", 1, true) or string.find(name, "radius", 1, true) then
			return rawget(Theme, "Corner")
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
-- Tablet: referência um pouco menor, para os textos não ficarem pequenos.
local TOUCH_REF_WIDTH, TOUCH_REF_HEIGHT, TOUCH_MIN_SCALE = 1100, 620, 0.55
-- Celular: a escala segue a ALTURA da tela (a parte curta no modo deitado), para o
-- texto do corpo ficar com 12 pt ou mais. A largura "virtual" nunca fica menor que 800.
local PHONE_REF_HEIGHT, PHONE_MIN_CANVAS_WIDTH, PHONE_MIN_SCALE = 480, 800, 0.62
-- Tela de toque com o lado curto menor que isso = celular (senão, tablet).
local PHONE_SHORT_SIDE = 500
-- Área mínima de toque (pixels reais) e texto mínimo (pt) no celular/tablet.
local MIN_TOUCH_TARGET = 44
local MIN_TEXT_PT = 12
-- Quanto a área de toque de um botão pode "vazar" para cada lado (pixels reais).
local TOUCH_TARGET_MAX_EXTRA = 6
-- +0/+2/+4/+6 no texto conforme o "Tamanho do texto" escolhido no menu do Roblox.
local TEXT_SIZE_OFFSETS = { Medium = 0, Large = 2, Larger = 4, Largest = 6 }

local DEFAULT_SCREEN_ORDER = 10
-- Telas antigas que se posicionam sozinhas em relação à barra do Roblox (somam
-- GuiService:GetGuiInset() ou ficam de propósito dentro da faixa da barra). Elas mantêm
-- o comportamento de antes da 2.0 (IgnoreGuiInset = true, que é DeviceSafeInsets); com
-- CoreUISafeInsets a barra seria descontada duas vezes. O argumento insets do
-- GetScreen continua valendo por cima disto.
local LEGACY_SCREEN_INSETS = {
	TopBanners = Enum.ScreenInsets.DeviceSafeInsets, -- AnnouncementController (computeTop)
	-- NotifyController: TOP_OFFSET já pula a barra, e o SetTopOffset recebe distâncias
	-- medidas na tela TopBanners (as duas precisam do mesmo referencial).
	Notifications = Enum.ScreenInsets.DeviceSafeInsets,
	AdminButton = Enum.ScreenInsets.DeviceSafeInsets, -- botão ADMIN no meio da barra
	DebugButton = Enum.ScreenInsets.DeviceSafeInsets, -- botão DEBUG no meio da barra
}
local WINDOW_DISPLAY_ORDER = 30
local BANNER_DISPLAY_ORDER = 50
local TOOLTIP_DISPLAY_ORDER = 80
local HEADER_HEIGHT = 56
local CONTENT_MARGIN = Theme.Space.Window
local DEFAULT_WINDOW_SIZE = UDim2.fromOffset(620, 460)
-- Quanto da tela uma janela pode ocupar no máximo (o resto fica de respiro).
local WINDOW_MAX_WIDTH_FRACTION = 0.96
local WINDOW_MAX_HEIGHT_FRACTION = 0.9
-- No celular, janela que ocuparia mais que isso da tela vira "folha" de tela cheia.
local SHEET_FRACTION = 0.8
local SHEET_SIZE = UDim2.fromScale(1, 1)
-- O véu escuro passa das bordas da área segura (cobre a barra do Roblox e o notch).
local BACKDROP_OVERSCAN = 400
-- Desfoque do mundo atrás de uma janela aberta.
local BLUR_NAME = "UIKitBlur"
local BLUR_SIZE = 12
-- Limite de frames de sombra visíveis ao mesmo tempo (desempenho).
local MAX_SHADOW_FRAMES = 12

-- Dica (tooltip): espera antes de aparecer (mouse) e tempo segurando (toque).
local TOOLTIP_DELAY = 0.4
local TOOLTIP_TOUCH_HOLD = 0.45

-- Sons: vozes (Sounds) por vaga e no total; distância dos sons 3D.
local MAX_VOICES_PER_KEY = 4
local MAX_VOICES_TOTAL = 24
local SOUND_3D_MIN_DISTANCE = 8
local SOUND_3D_MAX_DISTANCE = 150
-- Mesmo efeito repetido em menos de 0,3 s ganha uma variação de ±5% no tom.
local REPEAT_JITTER_WINDOW = 0.3
local PITCH_JITTER = 0.05
-- Mixagem: volume de cada grupo = MIX × configuração do jogador.
local MIX = { Master = 1, Music = 0.5, SFX = 0.7, UI = 0.6, Ambient = 0.6 }
local GROUP_SETTING = { Music = "MusicVolume", SFX = "SfxVolume", UI = "SfxVolume", Ambient = "AmbientVolume" }
local GROUP_NAMES = { Master = true, Music = true, SFX = true, UI = true, Ambient = true }
local VOLUME_DEFAULTS = { MusicVolume = 0.5, SfxVolume = 0.7, AmbientVolume = 0.6 }
-- Reserva, caso o Config/Audio não carregue: o clique usa um som que já vem no Roblox.
local UI_DEFAULT_SOUNDS = {
	Click = { Id = "rbxasset://sounds/volume_slider.ogg", Volume = 0.35, Speed = 1.1 },
}

-- Brilho do botão (UIGradient multiplica a cor do botão): {topo, base} em cinza.
local BUTTON_SHADES = {
	Rest = { 1, 0.86 },
	Hover = { 1, 0.95 },
	Pressed = { 0.8, 0.72 },
	Disabled = { 0.55, 0.45 },
}

-- Estilos de botão (props.Variant). Sem Variant = botão clássico na cor props.Color.
local BUTTON_VARIANTS = {
	-- Ação principal: rosa que puxa para o roxo embaixo.
	Primary = { Color = Theme.Accent, BottomTint = rgb(214, 200, 255) },
	-- Ação secundária: superfície com borda clarinha.
	Secondary = { Color = Theme.SurfaceHover, StrokeColor = Theme.SurfaceHover:Lerp(Color3.new(1, 1, 1), 0.16) },
	-- "Fantasma": só o texto; o fundo aparece com o mouse em cima (ou selecionado).
	Ghost = {
		Color = Theme.SurfaceHover,
		TextColor = Theme.TextDim,
		HoverTextColor = Theme.Text,
		RestTransparency = 1,
		HoverTransparency = 0.45,
		PressedTransparency = 0.25,
		NoStroke = true,
	},
	-- Ação perigosa (abandonar, apagar).
	Danger = { Color = Theme.Danger },
}

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
local setupDone = false
local cameraConnection = nil
local warnedMessages = {}
local rng = Random.new()

-- Layout atual (tipo de tela, escala, áreas seguras...). Ver UIKit.GetLayout().
local layout = {
	Class = "Desktop",
	Scale = 1,
	SafeInsets = { Top = 0, Left = 0, Right = 0, Bottom = 0 },
	TopbarHeight = 0,
	IsTouch = false,
	TextOffset = 0,
	ReducedMotion = false,
}
local layoutSignature = ""
local reducedMotion = false
local textOffset = 0
-- Textos com estilo (UIKit.TextStyle), reaplicados quando o layout muda. Chaves fracas:
-- quando o texto é destruído ele some daqui sozinho.
local styledLabels = setmetatable({}, { __mode = "k" })

-- Desfoque atrás das janelas.
local blurEffect = nil

-- Sombras: [frame alvo] = registro {Frames, Enabled...}.
local shadowRecords = setmetatable({}, { __mode = "k" })

-- Áudio.
local audioReady = false
local soundGroups = {} -- [nome] = SoundGroup
local volumeCache = table.clone(VOLUME_DEFAULTS) -- volumes do jogador (0..1), lidos do perfil
local voicePools = {} -- [vaga] = {Sound, ...}
local voiceInfo = {} -- [Sound] = {Key, StartedAt, Attachment}
local voiceCount = 0
local lastPlayedAt = {} -- [vaga] = os.clock() do último toque
local soundAnchor = nil -- Part invisível (na câmera) que segura os sons 3D
local blockedIds = nil -- conjunto de ids bloqueados (Config/Audio.Blocked)

-- Vibração ao tocar num botão (celular); false = o aparelho/cliente não suporta.
local clickHaptic = nil

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

-- Multiplica duas cores (como o UIGradient faz com a cor do fundo).
local function multiplyColor(a, b)
	return Color3.new(a.R * b.R, a.G * b.G, a.B * b.B)
end

-- Converte número (pixels) ou UDim em UDim.
local function toUDim(value, default)
	if typeof(value) == "UDim" then
		return value
	elseif type(value) == "number" then
		return UDim.new(0, value)
	end
	if typeof(default) == "UDim" then
		return default
	end
	return UDim.new(0, default or 0)
end

-- true se o número é "de verdade" (não NaN nem infinito).
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
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

-- true se o objeto aparece na tela agora (tela ligada e tudo visível até ela).
local function isOnScreen(gui)
	local layer = gui:FindFirstAncestorWhichIsA("LayerCollector")
	if not layer or not layer.Enabled then
		return false
	end
	return isReallyVisible(gui, layer)
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

-- Menor tamanho de texto que ainda fica legível (≥ 12 pt) no celular/tablet.
-- No PC/console devolve 0 (sem mínimo: a janela do Roblox pode ser redimensionada).
local function readableTextFloor()
	if layout.IsTouch and currentScale > 0 then
		return math.ceil(MIN_TEXT_PT / currentScale)
	end
	return 0
end

-------------------------------------------------------------------------------
-- Movimento (animações) e "menos movimento"
-------------------------------------------------------------------------------

-- Lê a opção "menos movimento" do Roblox (propriedade escondida: lida com pcall).
local function readReducedMotion()
	local ok, value = pcall(function()
		return GuiService.ReducedMotionEnabled
	end)
	return ok and value == true
end

-- TweenInfo de um movimento do tema (Theme.Motion). moving = true para escala/deslize,
-- que ficam instantâneos com "menos movimento"; fades (moving = false) continuam.
local function motionInfo(name, moving)
	local motion = Theme.Motion
	local time = motion[name]
	if type(time) ~= "number" then
		time = motion.Base
	end
	local style, direction = Enum.EasingStyle.Quad, Enum.EasingDirection.Out
	if name == "Enter" then
		style, direction = motion.EnterStyle, motion.EnterDirection
	elseif name == "Exit" then
		style, direction = motion.ExitStyle, motion.ExitDirection
	elseif name == "Pop" then
		style = motion.PopStyle
	end
	if moving and reducedMotion then
		time = 0
	end
	return TweenInfo.new(time, style, direction)
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
		inst.ScrollBarImageColor3 = Theme.TextMuted
		inst.ScrollBarImageTransparency = 0.3
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

-- UIKit.Corner(inst, radius?) -> UICorner (radius em pixels ou UDim; padrão Theme.Corner).
function UIKit.Corner(inst, radius)
	local corner = inst:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.Parent = inst
	end
	corner.CornerRadius = toUDim(radius, Theme.Corner)
	return corner
end

-- UIKit.Stroke(inst, thickness?, color?) -> UIStroke
-- Em botões e painéis o contorno vai na borda; em textos sem fundo, no texto.
function UIKit.Stroke(inst, thickness, color)
	local mode = Enum.ApplyStrokeMode.Border
	if inst:IsA("TextLabel") and inst.BackgroundTransparency >= 1 then
		mode = Enum.ApplyStrokeMode.Contextual
	end

	-- Reaproveita um contorno que já existe no mesmo modo (menos o brilho "Highlight").
	local stroke = nil
	for _, child in ipairs(inst:GetChildren()) do
		if child:IsA("UIStroke") and child.ApplyStrokeMode == mode and child.Name ~= "Highlight" then
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

-- Brilho de 1 px no topo de um painel (um UIStroke clarinho que some para baixo).
-- É um UIStroke (e não um Frame) para não atrapalhar listas (UIListLayout) do painel.
local function addHighlight(inst)
	local existing = inst:FindFirstChild("Highlight")
	if existing and existing:IsA("UIStroke") then
		return existing
	end
	local stroke = Instance.new("UIStroke")
	stroke.Name = "Highlight"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Thickness = 1
	stroke.Color = Theme.Highlight
	stroke.Transparency = 0
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, Theme.HighlightTransparency),
		NumberSequenceKeypoint.new(0.14, 1),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = stroke
	stroke.Parent = inst
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
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = toUDim(padding, 8)
	listLayout.FillDirection = toFillDirection(direction)
	if listLayout.FillDirection == Enum.FillDirection.Vertical then
		listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	else
		listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	end
	listLayout.Parent = parent
	return listLayout
end

-- UIKit.Grid(parent, cellSize, padding?) -> UIGridLayout
-- cellSize pode ser UDim2 ou Vector2 (pixels).
function UIKit.Grid(parent, cellSize, padding)
	removeOldLayouts(parent)
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	if typeof(cellSize) == "UDim2" then
		gridLayout.CellSize = cellSize
	elseif typeof(cellSize) == "Vector2" then
		gridLayout.CellSize = UDim2.fromOffset(cellSize.X, cellSize.Y)
	else
		gridLayout.CellSize = UDim2.fromOffset(110, 110)
	end
	if typeof(padding) == "UDim2" then
		gridLayout.CellPadding = padding
	else
		local px = tonumber(padding) or 8
		gridLayout.CellPadding = UDim2.fromOffset(px, px)
	end
	gridLayout.Parent = parent
	return gridLayout
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
-- Com "menos movimento" ligado, não pula (devolve nil).
function UIKit.Pop(inst, amount)
	if typeof(inst) ~= "Instance" or not inst:IsA("GuiObject") then
		return nil
	end
	if reducedMotion then
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
	local tween = UIKit.Tween(scale, { Scale = rest }, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
	tween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed and popRest[scale] == rest then
			popRest[scale] = nil
		end
	end)
	return tween
end

-- Balança um objeto (usado quando clica num botão desativado).
local function shake(gui)
	if reducedMotion then
		return
	end
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
-- Áudio: resolução das vagas (seção 4.4), grupos de volume e vozes
-------------------------------------------------------------------------------

-- Interpreta um valor de som do Config:
--   número > 0 ou "123" -> ("id", "rbxassetid://123");  texto com "://" -> ("id", texto)
--   número < 0 (ex.: -1) -> ("mute");  0, nil ou vazio -> ("auto")
local function parseSoundValue(value)
	if type(value) == "number" then
		if not isFiniteNumber(value) or value == 0 then
			return "auto", nil
		end
		if value < 0 then
			return "mute", nil
		end
		return "id", "rbxassetid://" .. string.format("%d", math.floor(value))
	elseif type(value) == "string" and value ~= "" then
		if string.find(value, "://", 1, true) then
			return "id", value
		end
		local number = tonumber(value)
		if number then
			return parseSoundValue(number)
		end
	end
	return "auto", nil
end

-- true se o id está em Config/Audio.Blocked (a busca automática nunca usa esses).
local function isBlockedId(soundId)
	if not blockedIds then
		blockedIds = {}
		if type(AudioConfig.Blocked) == "table" then
			for key, value in pairs(AudioConfig.Blocked) do
				-- Aceita lista {123, 456} e também conjunto {[123] = true}.
				local id = if type(key) == "number" and value == true then key else tonumber(value)
				if id then
					blockedIds[math.floor(id)] = true
				end
			end
		end
	end
	local id = tonumber(string.match(tostring(soundId), "(%d+)$"))
	return id ~= nil and blockedIds[id] == true
end

-- Grupo padrão de uma vaga que não está no Config/Audio.
local function defaultGroupFor(key)
	if string.sub(key, 1, 6) == "Music_" then
		return "Music"
	elseif string.sub(key, 1, 4) == "Amb_" or string.sub(key, 1, 5) == "Spot_" then
		return "Ambient"
	end
	return "SFX"
end

-- UIKit.ResolveSound(key) -> (soundId: string?, volume: number, speed: number, group: string)
-- Descobre qual áudio uma vaga usa agora, nesta ordem (seção 4.4):
--   1. Config.Game.Sounds[key] (ou Config.Game.Music[<Mapa>] para "Music_<Mapa>"):
--      > 0 = id fixo; -1 = mudo (devolve nil); 0 = automático (continua)
--   2. Config.Audio.Pinned[key] > 0
--   3. ReplicatedStorage.AudioLibrary, atributo "Slot_<key>" (achado pelo servidor)
--   4. Config.Audio.Slots[key].Fallback (som que já vem no Roblox) ou nil (silêncio)
-- Também aceita um número (id) ou um endereço pronto ("rbxassetid://...").
-- Não guarda nada em cache: quando a biblioteca de áudio muda, o próximo toque já usa o novo.
function UIKit.ResolveSound(key)
	if type(key) == "number" then
		local kind, soundId = parseSoundValue(key)
		return if kind == "id" then soundId else nil, 1, 1, "SFX"
	end
	if type(key) ~= "string" or key == "" then
		return nil, 1, 1, "SFX"
	end

	local slots = type(AudioConfig.Slots) == "table" and AudioConfig.Slots or {}
	local slot = slots[key]
	if type(slot) ~= "table" then
		slot = nil
	end
	local legacy = UI_DEFAULT_SOUNDS[key]

	-- A chave já é um endereço de som (ex.: "rbxassetid://123").
	if not slot and not legacy and string.find(key, "://", 1, true) then
		return key, 1, 1, "SFX"
	end

	local volume = (slot and tonumber(slot.Volume)) or (legacy and legacy.Volume) or 1
	local speed = (slot and tonumber(slot.Speed)) or (legacy and legacy.Speed) or 1
	local group = if slot and GROUP_NAMES[slot.Group] then slot.Group else defaultGroupFor(key)

	-- 1. Config/Game (o dono manda primeiro).
	local configured = nil
	local mapKey = string.match(key, "^Music_(.+)$")
	if mapKey then
		configured = type(GameConfig.Music) == "table" and GameConfig.Music[mapKey] or nil
	else
		configured = type(GameConfig.Sounds) == "table" and GameConfig.Sounds[key] or nil
	end
	local kind, soundId = parseSoundValue(configured)
	if kind == "mute" then
		return nil, volume, speed, group
	elseif kind == "id" then
		return soundId, volume, speed, group
	end

	-- 2. Id fixado no Config/Audio.
	local pinned = type(AudioConfig.Pinned) == "table" and AudioConfig.Pinned[key] or nil
	kind, soundId = parseSoundValue(pinned)
	if kind == "id" then
		return soundId, volume, speed, group
	end

	-- 3. O que a busca automática do servidor achou.
	local library = ReplicatedStorage:FindFirstChild("AudioLibrary")
	if library then
		kind, soundId = parseSoundValue(library:GetAttribute("Slot_" .. key))
		if kind == "id" and not isBlockedId(soundId) then
			return soundId, volume, speed, group
		end
	end

	-- 4. Som embutido do Roblox (ou silêncio).
	local fallback = (slot and type(slot.Fallback) == "table" and slot.Fallback) or legacy
	if fallback and type(fallback.Id) == "string" and fallback.Id ~= "" then
		return fallback.Id, tonumber(fallback.Volume) or volume, tonumber(fallback.Speed) or speed, group
	end
	return nil, volume, speed, group
end

-- Pasta local (só deste jogador) onde ficam os sons "sem lugar" (2D) da interface.
local function getSoundFolder()
	if soundFolder and soundFolder.Parent then
		return soundFolder
	end
	soundFolder = Instance.new("Folder")
	soundFolder.Name = "UIKitSounds"
	soundFolder.Parent = SoundService
	return soundFolder
end

-- Lê os volumes das Configurações (uma vez por mudança de perfil, não a cada som).
local function readVolumeSettings()
	local ok, settings = pcall(StateController.GetSettings)
	if not ok or type(settings) ~= "table" then
		return
	end
	for name, default in pairs(VOLUME_DEFAULTS) do
		local value = settings[name]
		volumeCache[name] = if isFiniteNumber(value) then math.clamp(value, 0, 1) else default
	end
end

-- Volume que um grupo deve ter agora (mixagem × configuração do jogador).
local function groupTargetVolume(name)
	local setting = GROUP_SETTING[name]
	local playerVolume = if setting then volumeCache[setting] or 1 else 1
	return (MIX[name] or 1) * playerVolume
end

-- Ajusta o volume de todos os grupos (suave quando animate = true).
local function applyGroupVolumes(animate)
	for name, group in pairs(soundGroups) do
		if group.Parent then
			local target = groupTargetVolume(name)
			if math.abs(group.Volume - target) > 0.001 then
				if animate then
					UIKit.Tween(group, { Volume = target }, 0.25)
				else
					group.Volume = target
				end
			end
		end
	end
end

-- Liga o áudio uma vez: lê os volumes e passa a acompanhar as Configurações.
local function ensureAudio()
	if audioReady then
		return
	end
	audioReady = true
	readVolumeSettings()
	StateController.OnChanged("Profile", function()
		readVolumeSettings()
		applyGroupVolumes(true)
	end)
end

-- UIKit.GetSoundGroup(name) -> SoundGroup
-- Grupos de volume (criados no cliente, dentro do SoundService):
--   Master (tudo) > Music (0,5 × MusicVolume), SFX (0,7 × SfxVolume),
--                   UI (0,6 × SfxVolume), Ambient (0,6 × AmbientVolume).
-- O volume acompanha as Configurações do jogador na hora. Nome desconhecido = "SFX".
function UIKit.GetSoundGroup(name)
	ensureAudio()
	if not GROUP_NAMES[name] then
		if name ~= nil then
			warnOnce("[UIKit] Grupo de som '" .. tostring(name) .. "' não existe; usando SFX.")
		end
		name = "SFX"
	end

	local master = soundGroups.Master
	if not (master and master.Parent) then
		master = Instance.new("SoundGroup")
		master.Name = "Master"
		master.Volume = MIX.Master
		master.Parent = SoundService
		soundGroups.Master = master
	end
	if name == "Master" then
		return master
	end

	local group = soundGroups[name]
	if group and group.Parent then
		return group
	end
	group = Instance.new("SoundGroup")
	group.Name = name
	group.Volume = groupTargetVolume(name)
	group.Parent = master -- grupo dentro do Master: o volume dos dois se multiplica
	soundGroups[name] = group
	return group
end

-- Part invisível na câmera que segura os Attachments dos sons 3D (só neste cliente).
local function getSoundAnchor()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	if soundAnchor and soundAnchor.Parent == camera then
		return soundAnchor
	end
	if not (soundAnchor and soundAnchor.Parent ~= nil) then
		soundAnchor = Instance.new("Part")
		soundAnchor.Name = "UIKitSound3D"
		soundAnchor.Anchored = true
		soundAnchor.CanCollide = false
		soundAnchor.CanQuery = false
		soundAnchor.CanTouch = false
		soundAnchor.CastShadow = false
		soundAnchor.Transparency = 1
		soundAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
		soundAnchor.CFrame = CFrame.identity -- na origem: posição do Attachment = posição no mundo
	end
	soundAnchor.Parent = camera
	return soundAnchor
end

-- Tira uma voz das listas e apaga o Sound.
local function destroyVoice(sound)
	local info = voiceInfo[sound]
	if info then
		local pool = voicePools[info.Key]
		local index = pool and table.find(pool, sound)
		if index then
			table.remove(pool, index)
		end
		if info.Attachment then
			info.Attachment:Destroy()
		end
		voiceInfo[sound] = nil
		voiceCount -= 1
	end
	sound:Destroy()
end

-- Move uma voz de outra vaga para esta (usado quando o limite total é atingido).
local function moveVoice(sound, poolKey, pool)
	local info = voiceInfo[sound]
	local oldPool = voicePools[info.Key]
	local index = oldPool and table.find(oldPool, sound)
	if index then
		table.remove(oldPool, index)
	end
	info.Key = poolKey
	sound:Stop()
	table.insert(pool, sound)
	return sound
end

-- Pega uma voz (Sound) para tocar a vaga: reaproveita uma parada, cria uma nova
-- (até 4 por vaga e 24 no total) ou reinicia a mais antiga.
local function acquireVoice(poolKey)
	local pool = voicePools[poolKey]
	if not pool then
		pool = {}
		voicePools[poolKey] = pool
	end

	-- Joga fora vozes que foram destruídas (ex.: a câmera antiga sumiu com os sons 3D).
	for index = #pool, 1, -1 do
		local sound = pool[index]
		if sound.Parent == nil then
			destroyVoice(sound)
		end
	end

	-- Uma voz parada desta vaga pode ser reusada.
	for _, sound in ipairs(pool) do
		if not sound.IsPlaying then
			return sound
		end
	end

	if #pool < MAX_VOICES_PER_KEY then
		if voiceCount < MAX_VOICES_TOTAL then
			local sound = Instance.new("Sound")
			sound.Name = "Sfx_" .. tostring(poolKey)
			sound.Parent = getSoundFolder()
			voiceInfo[sound] = { Key = poolKey, StartedAt = 0, Attachment = nil }
			voiceCount += 1
			table.insert(pool, sound)
			return sound
		end
		-- Limite total: pega uma voz parada de outra vaga, ou a que começou há mais tempo.
		local idle, oldest, oldestTime = nil, nil, math.huge
		for sound, info in pairs(voiceInfo) do
			if sound.Parent ~= nil then
				if not sound.IsPlaying then
					idle = sound
					break
				elseif info.StartedAt < oldestTime then
					oldest, oldestTime = sound, info.StartedAt
				end
			end
		end
		local victim = idle or oldest
		if victim then
			return moveVoice(victim, poolKey, pool)
		end
	end

	-- Todas as vozes desta vaga tocando: reinicia a mais antiga.
	local oldest, oldestTime = pool[1], math.huge
	for _, sound in ipairs(pool) do
		local info = voiceInfo[sound]
		if info and info.StartedAt < oldestTime then
			oldest, oldestTime = sound, info.StartedAt
		end
	end
	if oldest then
		oldest:Stop()
	end
	return oldest
end

-- UIKit.PlaySound(key, opts?) -> Sound | nil
-- key = vaga do Config/Audio ou do Config.Game.Sounds (ex.: "Purchase", "Click").
-- Mudo (-1), sem áudio ou com o volume do grupo em 0 = não toca nada (devolve nil).
-- opts (opcional):
--   Volume = multiplicador (1 = normal)
--   PlaybackSpeed ou Pitch = velocidade/tom exato (senão usa o da vaga, com ±5% se repetir)
--   Position = Vector3 -> som 3D naquele ponto do mundo (some com a distância)
--   MinDistance / MaxDistance = alcance do som 3D (padrão 8 e 150 studs)
--   Group = "SFX"/"UI"/"Music"/"Ambient" para trocar o grupo da vaga
function UIKit.PlaySound(key, opts)
	ensureAudio()
	local soundId, baseVolume, speed, groupName = UIKit.ResolveSound(key)
	if not soundId then
		return nil
	end

	opts = type(opts) == "table" and opts or {}
	if type(opts.Group) == "string" and GROUP_NAMES[opts.Group] then
		groupName = opts.Group
	end
	-- Jogador com o volume desse grupo em 0: nem gasta uma voz.
	local setting = GROUP_SETTING[groupName]
	if setting and (volumeCache[setting] or 0) <= 0 then
		return nil
	end

	local poolKey = if type(key) == "string" then key else soundId
	local sound = acquireVoice(poolKey)
	if not sound then
		return nil
	end
	local info = voiceInfo[sound]

	if sound.SoundId ~= soundId then
		sound.SoundId = soundId
	end
	sound.SoundGroup = UIKit.GetSoundGroup(groupName)
	sound.Looped = false
	sound.Volume = math.clamp(baseVolume * (tonumber(opts.Volume) or 1), 0, 10)

	-- Velocidade: a pedida, ou a da vaga com uma variação pequena se o efeito repetir rápido.
	local now = os.clock()
	local explicit = tonumber(opts.PlaybackSpeed or opts.Pitch)
	local finalSpeed = if explicit and explicit > 0 then explicit else speed
	if not explicit and groupName == "SFX" then
		local last = lastPlayedAt[poolKey]
		if last and now - last < REPEAT_JITTER_WINDOW then
			finalSpeed *= 1 + rng:NextNumber(-PITCH_JITTER, PITCH_JITTER)
		end
	end
	lastPlayedAt[poolKey] = now
	sound.PlaybackSpeed = math.clamp(finalSpeed, 0.05, 20)

	-- 3D (num ponto do mundo) ou 2D (na cabeça do jogador).
	local position = opts.Position
	local anchor = typeof(position) == "Vector3"
			and isFiniteNumber(position.X)
			and isFiniteNumber(position.Y)
			and isFiniteNumber(position.Z)
			and getSoundAnchor()
		or nil
	if anchor then
		local attachment = info.Attachment
		if not (attachment and attachment.Parent == anchor) then
			attachment = Instance.new("Attachment")
			attachment.Name = "SoundSpot"
			attachment.Parent = anchor
			info.Attachment = attachment
		end
		attachment.Position = position
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = tonumber(opts.MinDistance) or SOUND_3D_MIN_DISTANCE
		sound.RollOffMaxDistance = tonumber(opts.MaxDistance) or SOUND_3D_MAX_DISTANCE
		if sound.Parent ~= attachment then
			sound.Parent = attachment
		end
	else
		local folder = getSoundFolder()
		if sound.Parent ~= folder then
			sound.Parent = folder
		end
	end

	sound.TimePosition = 0
	sound:Play()
	info.StartedAt = now
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
-- Layout: tipo de tela (celular, tablet, PC, console), escala e áreas seguras
-------------------------------------------------------------------------------

-- Dispara (layout) quando o tipo de tela, a escala, as áreas seguras, o tamanho de
-- texto preferido ou o "menos movimento" mudam. layout = cópia de UIKit.GetLayout().
UIKit.LayoutChanged = Signal.new()

-- Tipo de entrada preferido do jogador (teclado/mouse, toque, controle). nil se não der para ler.
local function readPreferredInput()
	local ok, value = pcall(function()
		return UserInputService.PreferredInput
	end)
	if ok and typeof(value) == "EnumItem" then
		return value
	end
	return nil
end

-- Classifica a tela: "Phone", "Tablet", "Desktop" ou "Console".
local function computeLayoutClass(viewport)
	local tenFootOk, tenFoot = pcall(function()
		return GuiService:IsTenFootInterface()
	end)
	local preferred = readPreferredInput()
	if
		(tenFootOk and tenFoot == true)
		or preferred == Enum.PreferredInput.Gamepad
		or preferred == Enum.PreferredInput.MicroGamepad
	then
		return "Console"
	end

	local touch
	if preferred then
		touch = preferred == Enum.PreferredInput.Touch
	else
		touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	end
	if touch then
		if math.min(viewport.X, viewport.Y) < PHONE_SHORT_SIDE then
			return "Phone"
		end
		return "Tablet"
	end
	return "Desktop"
end

-- Calcula a escala da interface pelo tamanho da tela (só encolhe, nunca aumenta).
local function computeScaleFor(viewport, class)
	if viewport.X < 2 or viewport.Y < 2 then
		return 1
	end
	local scale
	if class == "Phone" then
		-- Pela altura: o texto do corpo (16 + 2) fica com 12 pt ou mais.
		scale = math.min(viewport.Y / PHONE_REF_HEIGHT, viewport.X / PHONE_MIN_CANVAS_WIDTH)
		scale = math.clamp(scale, PHONE_MIN_SCALE, 1)
	elseif class == "Tablet" then
		scale = math.clamp(math.min(viewport.X / TOUCH_REF_WIDTH, viewport.Y / TOUCH_REF_HEIGHT), TOUCH_MIN_SCALE, 1)
	else
		scale = math.clamp(math.min(viewport.X / REF_WIDTH, viewport.Y / REF_HEIGHT), MIN_SCALE, 1)
	end
	-- Arredonda para 2 casas (evita mexer na tela por diferenças mínimas).
	return math.floor(scale * 100 + 0.5) / 100
end

-- +0/+2/+4/+6 conforme o "Tamanho do texto" do menu do Roblox.
local function readTextOffset()
	local ok, value = pcall(function()
		return GuiService.PreferredTextSize
	end)
	if ok and typeof(value) == "EnumItem" then
		return TEXT_SIZE_OFFSETS[value.Name] or 0
	end
	return 0
end

-- Espaço (pixels) ocupado pela barra do Roblox em cada borda, e a altura da barra.
local function readInsets()
	local insets = { Top = 0, Left = 0, Right = 0, Bottom = 0 }
	local ok, topLeft, bottomRight = pcall(function()
		return GuiService:GetGuiInset()
	end)
	if ok and typeof(topLeft) == "Vector2" and typeof(bottomRight) == "Vector2" then
		insets.Top, insets.Left = topLeft.Y, topLeft.X
		insets.Bottom, insets.Right = bottomRight.Y, bottomRight.X
	end
	local topbarHeight = insets.Top
	local rectOk, rect = pcall(function()
		return GuiService.TopbarInset
	end)
	if rectOk and typeof(rect) == "Rect" and rect.Height > 0 then
		topbarHeight = rect.Height
	end
	return insets, topbarHeight
end

-- Cópia do layout (quem recebe pode guardar sem medo).
local function copyLayout()
	local insets = layout.SafeInsets
	return {
		Class = layout.Class,
		Scale = layout.Scale,
		SafeInsets = { Top = insets.Top, Left = insets.Left, Right = insets.Right, Bottom = insets.Bottom },
		TopbarHeight = layout.TopbarHeight,
		IsTouch = layout.IsTouch,
		TextOffset = layout.TextOffset,
		ReducedMotion = layout.ReducedMotion,
	}
end

-- Tamanho de texto de um estilo do Theme.Type no layout atual.
local function styleTextSize(styleName)
	local style = Theme.Type[styleName] or Theme.Type.Body
	local size = style.Size
	if layout.Class == "Phone" and type(style.PhoneBoost) == "number" then
		size += style.PhoneBoost
	end
	size += textOffset
	return math.max(size, readableTextFloor())
end

-- Aplica o tamanho do estilo num texto (TextScaled usa o limite do UITextSizeConstraint).
local function applyStyleSize(label, styleName)
	local size = styleTextSize(styleName)
	if label.TextScaled then
		local constraint = label:FindFirstChildOfClass("UITextSizeConstraint")
		if not constraint then
			constraint = Instance.new("UITextSizeConstraint")
			constraint.Parent = label
		end
		constraint.MaxTextSize = size
		constraint.MinTextSize = math.clamp(readableTextFloor(), 1, size)
	else
		label.TextSize = size
	end
end

-- Reaplica os estilos de texto (depois de uma mudança de layout).
local function restyleTexts()
	for label, styleName in pairs(styledLabels) do
		if label.Parent then
			applyStyleSize(label, styleName)
		end
	end
end

-- Recalcula o layout e aplica a escala em todas as telas e janelas.
local function refreshLayout()
	local camera = workspace.CurrentCamera
	local viewport = if camera then camera.ViewportSize else Vector2.new(REF_WIDTH, REF_HEIGHT)
	local class = computeLayoutClass(viewport)
	local scale = computeScaleFor(viewport, class)
	local insets, topbarHeight = readInsets()
	textOffset = readTextOffset()
	reducedMotion = readReducedMotion()
	currentScale = scale

	layout = {
		Class = class,
		Scale = scale,
		SafeInsets = insets,
		TopbarHeight = topbarHeight,
		IsTouch = class == "Phone" or class == "Tablet",
		TextOffset = textOffset,
		ReducedMotion = reducedMotion,
	}

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
	restyleTexts()

	local signature = table.concat({
		class,
		tostring(scale),
		tostring(insets.Top),
		tostring(insets.Left),
		tostring(insets.Right),
		tostring(insets.Bottom),
		tostring(topbarHeight),
		tostring(textOffset),
		tostring(reducedMotion),
	}, "|")
	if signature ~= layoutSignature then
		local isFirst = layoutSignature == ""
		layoutSignature = signature
		if not isFirst then
			UIKit.LayoutChanged:Fire(copyLayout())
		end
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
		cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshLayout)
	end
	refreshLayout()
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

-- Conecta "quando a propriedade X mudar" com pcall (propriedades novas ou escondidas).
local function connectPropertyChanged(instance, property, fn)
	local ok, signal = pcall(function()
		return instance:GetPropertyChangedSignal(property)
	end)
	if ok and signal then
		signal:Connect(fn)
	end
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

	-- O jogador trocou de teclado para toque/controle, a barra do Roblox mudou, ou
	-- mudou "Tamanho do texto"/"Menos movimento" no menu do Roblox.
	connectPropertyChanged(UserInputService, "PreferredInput", refreshLayout)
	connectPropertyChanged(GuiService, "TopbarInset", refreshLayout)
	connectPropertyChanged(GuiService, "PreferredTextSize", refreshLayout)
	connectPropertyChanged(GuiService, "ReducedMotionEnabled", refreshLayout)

	UserInputService.InputBegan:Connect(onInputBegan)
	-- O Esc também abre o menu do Roblox; quando o menu abre, fechamos a janela.
	GuiService.MenuOpened:Connect(function()
		closeAllWindows(nil)
	end)
end

-- UIKit.GetLayout() -> {Class, Scale, SafeInsets, TopbarHeight, IsTouch, TextOffset, ReducedMotion}
--   Class        "Phone" (toque, lado curto < 500 px), "Tablet" (outro toque),
--                "Desktop" (teclado e mouse) ou "Console" (controle / TV)
--   Scale        escala da interface (igual a UIKit.GetScale())
--   SafeInsets   {Top, Left, Right, Bottom}: pixels ocupados pela barra do Roblox
--                (as telas padrão do GetScreen já ficam fora dessa área sozinhas)
--   TopbarHeight altura da barra do Roblox em pixels
--   IsTouch      true no celular e no tablet
--   TextOffset   +0/+2/+4/+6 do "Tamanho do texto" do Roblox
--   ReducedMotion true com "menos movimento" ligado
-- Devolve uma cópia nova a cada chamada.
function UIKit.GetLayout()
	ensureSetup()
	return copyLayout()
end

-- true se o jogador ligou "menos movimento" no Roblox: sem escalas/deslizes, só fades.
function UIKit.IsReducedMotion()
	ensureSetup()
	return reducedMotion
end

-- PlayerGui do jogador local.
local function getPlayerGui()
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- UIKit.GetScreen(name, displayOrder?, insets?) -> ScreenGui
-- Cria (ou reaproveita) uma ScreenGui em PlayerGui, que não some ao renascer e tem
-- UIScale automático. O conteúdo fica dentro da área segura (fora da barra do Roblox
-- e do "notch" do celular): ScreenInsets = CoreUISafeInsets. insets (opcional) troca isso
-- por outro Enum.ScreenInsets (ex.: None para um fundo que cobre a tela toda). Quem faz a
-- própria conta com GetGuiInset (ou quer ficar dentro da barra) deve pedir DeviceSafeInsets.
function UIKit.GetScreen(name, displayOrder, insets)
	ensureSetup()
	name = tostring(name or "UIKitScreen")
	local wantedInsets = if typeof(insets) == "EnumItem"
		then insets
		else LEGACY_SCREEN_INSETS[name] or Enum.ScreenInsets.CoreUISafeInsets

	local gui = screens[name]
	if gui and gui.Parent then
		if type(displayOrder) == "number" then
			gui.DisplayOrder = displayOrder
		end
		if typeof(insets) == "EnumItem" then
			gui.ScreenInsets = insets
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
	gui.ScreenInsets = wantedInsets
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

-- UIKit.TextStyle(label, styleName, over3D?) -> label
-- Aplica um estilo do Theme.Type: "Display", "Title", "Heading", "Button", "Body",
-- "BodyStrong", "Caption" ou "Number" (fonte e tamanho). No celular o corpo cresce +2,
-- o "Tamanho do texto" do Roblox soma +0 a +6 e nunca fica menor que 12 pt.
-- over3D = true coloca um contorno escuro (só para texto em cima do mundo 3D).
-- O tamanho é refeito sozinho quando o layout muda.
function UIKit.TextStyle(label, styleName, over3D)
	if
		typeof(label) ~= "Instance"
		or not (label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox"))
	then
		return label
	end
	ensureSetup()
	if type(styleName) ~= "string" or not rawget(Theme.Type, styleName) then
		styleName = "Body"
	end
	label.Font = Theme.Type[styleName].Font
	applyStyleSize(label, styleName)
	if over3D == true then
		label.TextStrokeColor3 = Theme.Stroke
		label.TextStrokeTransparency = 0.35
	end
	styledLabels[label] = styleName
	return label
end

local LABEL_SPECIAL = { Color = true, Title = true, Text = true, Children = true, Style = true }

-- UIKit.Label(props) -> TextLabel
-- props: qualquer propriedade de TextLabel, mais Color (cor do texto), Title = true
-- (fonte de título) e Style = nome de um estilo do Theme.Type (ver UIKit.TextStyle).
-- No celular/tablet o texto nunca fica menor que 12 pt de verdade.
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

	if type(props.Style) == "string" then
		UIKit.TextStyle(label, props.Style)
	elseif layout.IsTouch and not label.TextScaled then
		-- Texto pequeno demais no celular: sobe até o mínimo legível.
		local floor = readableTextFloor()
		if label.TextSize < floor then
			label.TextSize = floor
		end
	end

	if parent then
		label.Parent = parent
	end
	return label
end

-------------------------------------------------------------------------------
-- Toque (área mínima) e vibração
-------------------------------------------------------------------------------

-- HapticEffect de "clique" (um só para todos os botões). nil se o aparelho não suportar.
local function getClickHaptic()
	if clickHaptic == false then
		return nil
	end
	if clickHaptic and clickHaptic.Parent then
		return clickHaptic
	end
	local ok, effect = pcall(function()
		local haptic = Instance.new("HapticEffect")
		haptic.Name = "UIKitClickHaptic"
		haptic.Type = Enum.HapticEffectType.UIClick
		haptic.Parent = workspace
		return haptic
	end)
	clickHaptic = if ok then effect else false
	return if ok then effect else nil
end

-- Vibração leve ao apertar o botão (só no toque, onde o Roblox suportar).
local function applyPressHaptic(button)
	if not layout.IsTouch then
		return
	end
	local effect = getClickHaptic()
	if effect then
		pcall(function()
			button.PressHapticEffect = effect
		end)
	end
end

-- Aumenta a área de toque de um botão pequeno até ~44 px reais, com faixas invisíveis
-- em volta dele (até 6 px para cada lado, para não invadir os vizinhos). As faixas
-- chamam "activate" (o mesmo clique do botão) e "setPressed" (visual de apertado).
-- Só é usado em telas de toque e em botões criados com onClick.
local function attachTouchTarget(button, activate, setPressed)
	-- Frame "sonda" do tamanho da área interna (descontando o UIPadding do botão).
	local probe = Instance.new("Frame")
	probe.Name = "TouchProbe"
	probe.BackgroundTransparency = 1
	probe.Size = UDim2.fromScale(1, 1)
	probe.Active = false
	probe.Selectable = false
	probe.Parent = button

	local strips = {}
	for _, stripName in ipairs({ "TouchTop", "TouchBottom", "TouchLeft", "TouchRight" }) do
		local strip = Instance.new("TextButton")
		strip.Name = stripName
		strip.Text = ""
		strip.BackgroundTransparency = 1
		strip.BorderSizePixel = 0
		strip.AutoButtonColor = false
		strip.Selectable = false
		strip.Visible = false
		strip.Activated:Connect(activate)
		strip.MouseButton1Down:Connect(function()
			setPressed(true)
		end)
		strip.MouseButton1Up:Connect(function()
			setPressed(false)
		end)
		strip.MouseLeave:Connect(function()
			setPressed(false)
		end)
		applyPressHaptic(strip)
		strip.Parent = button
		strips[stripName] = strip
	end

	local lastExtraX, lastExtraY = -1, -1
	local function update()
		local outer = button.AbsoluteSize
		local inner = probe.AbsoluteSize
		if outer.X < 1 or outer.Y < 1 or inner.X < 1 or inner.Y < 1 then
			return
		end
		local extraX = math.clamp((MIN_TOUCH_TARGET - outer.X) / 2, 0, TOUCH_TARGET_MAX_EXTRA)
		local extraY = math.clamp((MIN_TOUCH_TARGET - outer.Y) / 2, 0, TOUCH_TARGET_MAX_EXTRA)
		if math.abs(extraX - lastExtraX) < 0.5 and math.abs(extraY - lastExtraY) < 0.5 then
			return
		end
		lastExtraX, lastExtraY = extraX, extraY

		-- Tudo em "escala" da área interna, para ficar certo em qualquer UIScale.
		local padX = (outer.X - inner.X) / 2
		local padY = (outer.Y - inner.Y) / 2
		local left = -(padX + extraX) / inner.X
		local top = -(padY + extraY) / inner.Y
		local fullWidth = (outer.X + extraX * 2) / inner.X
		local fullHeight = outer.Y / inner.Y

		strips.TouchTop.Visible = extraY > 0
		strips.TouchTop.Position = UDim2.fromScale(left, top)
		strips.TouchTop.Size = UDim2.fromScale(fullWidth, extraY / inner.Y)
		strips.TouchBottom.Visible = extraY > 0
		strips.TouchBottom.Position = UDim2.fromScale(left, 1 + padY / inner.Y)
		strips.TouchBottom.Size = UDim2.fromScale(fullWidth, extraY / inner.Y)
		strips.TouchLeft.Visible = extraX > 0
		strips.TouchLeft.Position = UDim2.fromScale(left, -padY / inner.Y)
		strips.TouchLeft.Size = UDim2.fromScale(extraX / inner.X, fullHeight)
		strips.TouchRight.Visible = extraX > 0
		strips.TouchRight.Position = UDim2.fromScale(1 + padX / inner.X, -padY / inner.Y)
		strips.TouchRight.Size = UDim2.fromScale(extraX / inner.X, fullHeight)
	end

	button:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)
	probe:GetPropertyChangedSignal("AbsoluteSize"):Connect(update)
	task.defer(update)
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
	Variant = true,
	Loading = true,
	HoverColor = true,
	SelectedColor = true,
	Selected = true,
}

-- Monta a sequência de brilho do botão (topo e base em cinza, base tingida opcional).
local function buttonSequence(shade, tint)
	local top = Color3.new(shade[1], shade[1], shade[1])
	local bottom = Color3.new(shade[2], shade[2], shade[2])
	if tint then
		bottom = multiplyColor(bottom, tint)
	end
	return ColorSequence.new(top, bottom)
end

-- Cria (uma vez) o "girador" do estado Loading: um anel com um pedaço apagado.
local function createSpinner(button)
	local spinner = Instance.new("Frame")
	spinner.Name = "Spinner"
	spinner.AnchorPoint = Vector2.new(0.5, 0.5)
	spinner.Position = UDim2.fromScale(0.5, 0.5)
	spinner.Size = UDim2.fromScale(0.5, 0.5)
	spinner.SizeConstraint = Enum.SizeConstraint.RelativeYY
	spinner.BackgroundTransparency = 1
	spinner.Visible = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = spinner
	local ring = Instance.new("UIStroke")
	ring.Thickness = 3
	ring.Color = button.TextColor3
	ring.Parent = spinner
	local gradient = Instance.new("UIGradient")
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.65, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = ring
	spinner.Parent = button
	return spinner
end

-- UIKit.Button(props, onClick) -> TextButton
-- props: {Text, Color, Size, Position, LayoutOrder, Parent} e também
--        TextColor, TextSize (tamanho máximo), Font, AnchorPoint, Name,
--        CornerRadius, Disabled, Sound (chave do som; false = sem som),
--        Variant = "Primary" | "Secondary" | "Ghost" | "Danger" (estilo pronto),
--        Loading = true (mostra um girador e ignora cliques),
--        HoverColor (cor com o mouse em cima), SelectedColor / Selected (abas).
-- onClick(button) roda numa thread própria (pode chamar Net.Request sem travar).
-- Para desativar depois: button.Active = false ou button:SetAttribute("Disabled", true).
-- Para "carregando" depois: button:SetAttribute("Loading", true/false).
-- Para marcar como selecionado (abas): button:SetAttribute("Selected", true/false).
-- Pode trocar a cor depois com button.BackgroundColor3 (a borda acompanha).
function UIKit.Button(props, onClick)
	if type(props) == "string" then
		props = { Text = props }
	end
	props = props or {}
	if type(onClick) ~= "function" then
		onClick = nil
	end
	ensureSetup()

	local variantName = if type(props.Variant) == "string" and BUTTON_VARIANTS[props.Variant]
		then props.Variant
		else nil
	local variant = if variantName then BUTTON_VARIANTS[variantName] else nil
	local isGhost = variantName == "Ghost"

	local color = (typeof(props.Color) == "Color3" and props.Color) or (variant and variant.Color) or Theme.Accent
	local hoverColor = if typeof(props.HoverColor) == "Color3" then props.HoverColor else nil
	local selectedColor = if typeof(props.SelectedColor) == "Color3" then props.SelectedColor else Theme.Accent
	local restTextColor = (typeof(props.TextColor) == "Color3" and props.TextColor)
		or (typeof(props.TextColor3) == "Color3" and props.TextColor3)
		or (variant and variant.TextColor)
		or Theme.Text
	local hoverTextColor = (variant and variant.HoverTextColor) or restTextColor
	local tint = variant and variant.BottomTint or nil
	-- Só botões com cor "gerenciada" (hover/seleção) mexem no BackgroundColor3 sozinhos.
	local managesColor = hoverColor ~= nil or isGhost

	local button = Instance.new("TextButton")
	button.Name = props.Name or "Button"
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = color
	button.BackgroundTransparency = if variant and variant.RestTransparency then variant.RestTransparency else 0
	button.Size = typeof(props.Size) == "UDim2" and props.Size or UDim2.fromOffset(160, 46)
	button.Position = typeof(props.Position) == "UDim2" and props.Position or UDim2.new()
	button.AnchorPoint = typeof(props.AnchorPoint) == "Vector2" and props.AnchorPoint or Vector2.zero
	button.LayoutOrder = tonumber(props.LayoutOrder) or 0
	button.Text = props.Text ~= nil and tostring(props.Text) or ""
	button.Font = typeof(props.Font) == "EnumItem" and props.Font or Theme.ButtonFont
	button.TextColor3 = restTextColor
	button.TextScaled = true
	button.TextWrapped = true
	button.TextStrokeColor3 = Theme.Stroke
	button.TextStrokeTransparency = if isGhost then 1 else 0.6
	button.Selectable = true

	-- O texto se ajusta ao botão, mas sem passar do tamanho máximo (e, no toque,
	-- sem ficar menor que o mínimo legível).
	local textConstraint = Instance.new("UITextSizeConstraint")
	textConstraint.MaxTextSize = tonumber(props.TextSize) or (if variant then Theme.Type.Button.Size + 2 else 22)
	textConstraint.MinTextSize = math.clamp(math.max(8, readableTextFloor()), 1, textConstraint.MaxTextSize)
	textConstraint.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.Parent = button

	UIKit.Corner(button, props.CornerRadius or Theme.Radius.M)

	-- Borda um pouco mais escura que o botão (ou a cor própria do estilo).
	local function strokeColorFor(background)
		if variant and variant.StrokeColor then
			return variant.StrokeColor
		end
		return darken(background, 0.5)
	end
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Thickness = if variant and variant.StrokeColor then 1.5 else 2
	stroke.Color = strokeColorFor(color)
	stroke.Transparency = if variant and variant.NoStroke then 1 else 0
	stroke.Parent = button

	-- Brilho de cima para baixo (efeito "gomoso").
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Color = buttonSequence(BUTTON_SHADES.Rest, tint)
	gradient.Parent = button

	-- Escala usada nas animações de passar o mouse e de clique.
	local scale = Instance.new("UIScale")
	scale.Name = "UIKitScale"
	scale:SetAttribute("Rest", 1)
	scale.Parent = button

	if props.Disabled then
		button:SetAttribute("Disabled", true)
	end
	if props.Loading then
		button:SetAttribute("Loading", true)
	end
	if props.Selected then
		button:SetAttribute("Selected", true)
	end

	local hovered = false
	local pressed = false
	local lastClick = 0
	local baseColor = color
	local spinner = nil
	local spinTween = nil

	local function isEnabled()
		return button.Active and button:GetAttribute("Disabled") ~= true
	end
	local function isLoading()
		return button:GetAttribute("Loading") == true
	end
	local function isSelected()
		return button:GetAttribute("Selected") == true
	end

	-- Liga/desliga o girador do "carregando".
	local function refreshLoading()
		local loading = isLoading()
		if loading then
			spinner = spinner or createSpinner(button)
			spinner.Visible = true
			if not spinTween then
				spinner.Rotation = 0
				spinTween = TweenService:Create(
					spinner,
					TweenInfo.new(0.9, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1),
					{ Rotation = 360 }
				)
				spinTween:Play()
			end
		elseif spinner then
			spinner.Visible = false
			if spinTween then
				spinTween:Cancel()
				spinTween = nil
			end
		end
	end

	-- Atualiza a aparência conforme o estado (normal, mouse em cima, apertado, desativado).
	local function refreshLook()
		local enabled = isEnabled()
		local selected = isSelected()
		local loading = isLoading()
		if not enabled then
			gradient.Color = buttonSequence(BUTTON_SHADES.Disabled, tint)
		elseif pressed then
			gradient.Color = buttonSequence(BUTTON_SHADES.Pressed, tint)
		elseif hovered then
			gradient.Color = buttonSequence(BUTTON_SHADES.Hover, tint)
		else
			gradient.Color = buttonSequence(BUTTON_SHADES.Rest, tint)
		end

		-- Cor e transparência do fundo (só nos botões que "gerenciam" a cor).
		if managesColor then
			local wanted = baseColor
			if isGhost and selected then
				wanted = selectedColor
			elseif hovered and enabled and hoverColor then
				wanted = hoverColor
			end
			if button.BackgroundColor3 ~= wanted then
				button.BackgroundColor3 = wanted
			end
		end
		if isGhost then
			local transparency = variant.RestTransparency
			if selected then
				transparency = 0
			elseif enabled and pressed then
				transparency = variant.PressedTransparency
			elseif enabled and hovered then
				transparency = if hoverColor then 0.2 else variant.HoverTransparency
			end
			button.BackgroundTransparency = transparency
			button.TextColor3 = if selected or (hovered and enabled) then hoverTextColor else restTextColor
		elseif selected then
			-- Selecionado (fora do Ghost): anel claro em volta.
			stroke.Color = Theme.Text
		end

		button.TextTransparency = if loading then 1 elseif enabled then 0 else 0.3
		if spinner then
			local ring = spinner:FindFirstChildOfClass("UIStroke")
			if ring then
				ring.Color = button.TextColor3
			end
		end

		local target = 1
		if not reducedMotion then
			if enabled and pressed then
				target = 0.96
			elseif enabled and hovered then
				target = 1.03
			end
		end
		UIKit.Tween(scale, { Scale = target }, if pressed then Theme.Motion.Press else Theme.Motion.Hover)
	end

	local function setHovered(value)
		hovered = value
		if not value then
			pressed = false
		end
		refreshLook()
	end

	local function setPressed(value)
		pressed = value
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
		setPressed(true)
	end)
	button.MouseButton1Up:Connect(function()
		setPressed(false)
	end)

	button:GetPropertyChangedSignal("Active"):Connect(refreshLook)
	button:GetAttributeChangedSignal("Disabled"):Connect(refreshLook)
	button:GetAttributeChangedSignal("Selected"):Connect(function()
		if not isSelected() then
			stroke.Color = strokeColorFor(button.BackgroundColor3)
		end
		refreshLook()
	end)
	button:GetAttributeChangedSignal("Loading"):Connect(function()
		refreshLoading()
		refreshLook()
	end)
	-- Se o dono trocar a cor do botão, a borda acompanha (e vira a nova cor "base").
	button:GetPropertyChangedSignal("BackgroundColor3"):Connect(function()
		local value = button.BackgroundColor3
		if not isSelected() then
			stroke.Color = strokeColorFor(value)
		end
		-- Quando o botão cuida da própria cor (hover/selecionado), só uma cor "de fora" vira a base.
		local isOwnColor = managesColor and (value == baseColor or value == hoverColor or value == selectedColor)
		if not isOwnColor then
			baseColor = value
		end
	end)

	-- O clique de verdade (mouse, toque, botão A do controle e as faixas de toque).
	local function activate()
		if isLoading() then
			return
		end
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
		if not reducedMotion then
			scale.Scale = 0.92
			UIKit.Tween(scale, { Scale = hovered and 1.03 or 1 }, motionInfo("Pop", true))
		end

		-- No toque não existe "mouse em cima": depois do toque volta ao normal.
		if isUsingTouch() then
			hovered = false
			pressed = false
			refreshLook()
		end

		if onClick then
			task.spawn(onClick, button)
		end
	end

	-- Activated funciona com clique, toque e botão A do controle.
	button.Activated:Connect(activate)

	-- Celular/tablet: vibração leve e área de toque de pelo menos ~44 px.
	applyPressHaptic(button)
	if onClick and layout.IsTouch then
		attachTouchTarget(button, activate, setPressed)
	end

	local parent = applyProps(button, props, BUTTON_SPECIAL)
	addChildren(button, props.Children)
	refreshLoading()
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
	Style = true,
}

-- Estilos de barra: Default (normal), Coin (dourada), Tier (cor do tier com brilho),
-- Thin (fininha, sem texto).
local PROGRESS_STYLES = {
	Default = { Height = 26, ShowLabel = true, StrokeThickness = 1.5 },
	Coin = { Height = 26, ShowLabel = true, StrokeThickness = 1.5, FillColor = Theme.Coin },
	Tier = { Height = 26, ShowLabel = true, StrokeThickness = 1.5, Glow = true },
	Thin = { Height = 6, ShowLabel = false, BackgroundTransparency = 0.2 },
}

-- Base da moeda: multiplica o dourado claro até virar o dourado escuro (CoinDeep).
local COIN_BOTTOM_TINT = Color3.new(
	Theme.CoinDeep.R / math.max(Theme.Coin.R, 0.001),
	Theme.CoinDeep.G / math.max(Theme.Coin.G, 0.001),
	Theme.CoinDeep.B / math.max(Theme.Coin.B, 0.001)
)

-- UIKit.ProgressBar(parent, props?) -> {Frame, Fill, Label, Set(fração, texto?), SetColor(cor)}
-- props: Size, Position, AnchorPoint, LayoutOrder, Name, Color (preenchimento),
--        BackgroundColor, Text, TextSize, CornerRadius, Fraction (valor inicial 0..1),
--        Style = "Default" | "Coin" | "Tier" | "Thin".
function UIKit.ProgressBar(parent, props)
	-- Aceita também UIKit.ProgressBar(props) com props.Parent.
	if type(parent) == "table" and props == nil then
		props = parent
		parent = props.Parent
	end
	props = props or {}

	local styleName = if type(props.Style) == "string" and PROGRESS_STYLES[props.Style] then props.Style else "Default"
	local style = PROGRESS_STYLES[styleName]
	local fillColor = (typeof(props.Color) == "Color3" and props.Color) or style.FillColor or Theme.Accent

	local frame = Instance.new("Frame")
	frame.Name = props.Name or "ProgressBar"
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = typeof(props.BackgroundColor) == "Color3" and props.BackgroundColor or Theme.SurfaceSunken
	frame.BackgroundTransparency = style.BackgroundTransparency or 0
	frame.Size = typeof(props.Size) == "UDim2" and props.Size or UDim2.new(1, 0, 0, style.Height)
	frame.Position = typeof(props.Position) == "UDim2" and props.Position or UDim2.new()
	frame.AnchorPoint = typeof(props.AnchorPoint) == "Vector2" and props.AnchorPoint or Vector2.zero
	frame.LayoutOrder = tonumber(props.LayoutOrder) or 0

	local corner = UIKit.Corner(frame, props.CornerRadius or Theme.Radius.Pill)
	local frameStroke = nil
	if style.StrokeThickness then
		frameStroke = UIKit.Stroke(frame, style.StrokeThickness, Theme.Stroke)
	end

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
	if styleName == "Coin" then
		fillGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), COIN_BOTTOM_TINT)
	elseif styleName == "Tier" then
		fillGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 170))
	else
		fillGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 200))
	end
	fillGradient.Parent = fill

	-- Tier: contorno na cor do preenchimento (um "brilho" discreto).
	local function refreshGlow()
		if style.Glow and frameStroke then
			frameStroke.Color = fill.BackgroundColor3
			frameStroke.Transparency = 0.35
		end
	end
	refreshGlow()

	-- Texto por cima da barra (ex.: "45%" ou "12/40").
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -12, 1, 0)
	label.Position = UDim2.fromOffset(6, 0)
	label.Font = Theme.NumberFont
	label.TextColor3 = Theme.Text
	label.TextScaled = true
	label.TextStrokeColor3 = Theme.Stroke
	label.TextStrokeTransparency = 0.35
	label.Text = props.Text ~= nil and tostring(props.Text) or ""
	label.Visible = style.ShowLabel
	label.ZIndex = 2
	label.Parent = frame

	local labelConstraint = Instance.new("UITextSizeConstraint")
	labelConstraint.MaxTextSize = tonumber(props.TextSize) or 16
	labelConstraint.MinTextSize = math.clamp(math.max(8, readableTextFloor()), 1, labelConstraint.MaxTextSize)
	labelConstraint.Parent = label

	local bar = { Frame = frame, Fill = fill, Label = label, Fraction = 0, Style = styleName }

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
			refreshGlow()
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
-- Sombras (Theme.Elevation)
-------------------------------------------------------------------------------

-- Quantos frames de sombra estão aparecendo na tela agora.
local function countVisibleShadowFrames()
	local count = 0
	for target, record in pairs(shadowRecords) do
		if target.Parent and record.Enabled then
			for _, shadowFrame in ipairs(record.Frames) do
				if shadowFrame.Parent and shadowFrame.Visible and isOnScreen(shadowFrame) then
					count += 1
				end
			end
		end
	end
	return count
end

-- UIKit.Shadow(frame, level) -> {Frames, SetEnabled(bool), Destroy()} | nil
-- Sombra suave atrás de um frame "solto" (janela, faixa, dica): nível 1 = uma camada,
-- nível 2 = duas camadas. Os frames de sombra ficam ao lado do alvo (mesmo pai) e
-- seguem posição, tamanho, visibilidade e UIScale dele. Não funciona dentro de listas
-- (UIListLayout/UIGridLayout: a sombra viraria um item) e respeita o limite de
-- 12 frames de sombra na tela (acima disso devolve nil).
function UIKit.Shadow(frame, level)
	if typeof(frame) ~= "Instance" or not frame:IsA("GuiObject") then
		return nil
	end
	local existing = shadowRecords[frame]
	if existing then
		return existing.Handle
	end
	if level == "E1" then
		level = 1
	elseif level == "E2" then
		level = 2
	end
	level = math.clamp(math.floor(tonumber(level) or 1), 1, 2)
	local layers = Theme.Elevation[level]

	local parent = frame.Parent
	if not parent then
		warnOnce("[UIKit] Shadow: coloque o frame num pai antes de criar a sombra.")
		return nil
	end
	if parent:FindFirstChildWhichIsA("UIGridStyleLayout") then
		warnOnce("[UIKit] Shadow ignorada: o pai usa UIListLayout/UIGridLayout.")
		return nil
	end
	if countVisibleShadowFrames() + #layers > MAX_SHADOW_FRAMES then
		warnOnce("[UIKit] Shadow ignorada: limite de 12 sombras na tela.")
		return nil
	end

	local record = { Frames = {}, Enabled = true }
	local trove = Trove.new()
	local targetCorner = frame:FindFirstChildOfClass("UICorner")
	local targetScale = frame:FindFirstChildOfClass("UIScale")

	for index, layer in ipairs(layers) do
		local shadowFrame = Instance.new("Frame")
		shadowFrame.Name = frame.Name .. "Shadow" .. index
		shadowFrame.BackgroundColor3 = Color3.new(0, 0, 0)
		shadowFrame.BackgroundTransparency = layer.Transparency
		shadowFrame.BorderSizePixel = 0
		shadowFrame.Active = false
		shadowFrame.Selectable = false
		local corner = Instance.new("UICorner")
		corner.Name = "ShadowCorner"
		corner.Parent = shadowFrame
		if targetScale then
			local mirror = Instance.new("UIScale")
			mirror.Name = "ShadowScale"
			mirror.Scale = targetScale.Scale
			mirror.Parent = shadowFrame
		end
		trove:Add(shadowFrame)
		record.Frames[index] = shadowFrame
	end

	local function sync()
		local currentParent = frame.Parent
		for index, shadowFrame in ipairs(record.Frames) do
			local offset = layers[index].Offset
			shadowFrame.AnchorPoint = frame.AnchorPoint
			shadowFrame.Size = frame.Size
			shadowFrame.Position = frame.Position + UDim2.fromOffset(offset.X, offset.Y)
			shadowFrame.Rotation = frame.Rotation
			shadowFrame.ZIndex = math.max(frame.ZIndex - 1, 0)
			shadowFrame.Visible = record.Enabled and frame.Visible
			local corner = shadowFrame:FindFirstChild("ShadowCorner")
			if corner then
				corner.CornerRadius = if targetCorner then targetCorner.CornerRadius else UDim.new(0, 0)
			end
			if shadowFrame.Parent ~= currentParent then
				shadowFrame.Parent = currentParent
			end
		end
	end

	for _, property in ipairs({ "Position", "Size", "AnchorPoint", "Visible", "ZIndex", "Rotation" }) do
		trove:Connect(frame:GetPropertyChangedSignal(property), sync)
	end
	trove:Connect(frame.AncestryChanged, sync)
	if targetCorner then
		trove:Connect(targetCorner:GetPropertyChangedSignal("CornerRadius"), sync)
	end
	if targetScale then
		trove:Connect(targetScale:GetPropertyChangedSignal("Scale"), function()
			for _, shadowFrame in ipairs(record.Frames) do
				local mirror = shadowFrame:FindFirstChild("ShadowScale")
				if mirror then
					mirror.Scale = targetScale.Scale
				end
			end
		end)
	end

	local handle = { Frames = record.Frames }
	-- Liga/desliga a sombra sem destruir (ex.: janela virou folha de tela cheia).
	function handle.SetEnabled(...)
		local args = table.pack(...)
		local value = if args[1] == handle then args[2] else args[1]
		record.Enabled = value ~= false
		sync()
	end
	-- Apaga a sombra de vez.
	function handle.Destroy()
		if shadowRecords[frame] == record then
			shadowRecords[frame] = nil
		end
		trove:Clean()
	end
	trove:Connect(frame.Destroying, handle.Destroy)

	record.Handle = handle
	shadowRecords[frame] = record
	sync()
	return handle
end

-------------------------------------------------------------------------------
-- Painel, etiqueta (chip) e botão de ícone
-------------------------------------------------------------------------------

local PANEL_SPECIAL = {
	Color = true,
	Transparency = true,
	Glass = true,
	Radius = true,
	Padding = true,
	Elevation = true,
	Stroke = true,
	Highlight = true,
	List = true,
	Children = true,
}

-- UIKit.Panel(props) -> Frame
-- Cartão/painel pronto. props (todas opcionais, além de qualquer propriedade de Frame):
--   Color        cor do fundo (padrão Theme.SurfaceRaised; Glass = Theme.Bg)
--   Transparency transparência do fundo (padrão 0; Glass = 0,22)
--   Glass = true "vidro" do HUD: translúcido, com contorno escuro (fica sobre o mundo 3D)
--   Radius       canto (padrão Theme.Radius.L)
--   Padding      respiro interno (padrão Theme.Space.Card; false = nenhum)
--   Stroke       true = contorno escuro de 2 px; uma cor = contorno fino dessa cor
--   Highlight    false = sem o brilho de 1 px no topo
--   Elevation    1 ou 2 = sombra (só funciona fora de listas; ver UIKit.Shadow)
--   List         número = já cria uma lista vertical com esse espaço entre os itens
function UIKit.Panel(props)
	props = props or {}
	ensureSetup()
	local glass = props.Glass == true

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.BorderSizePixel = 0
	panel.BackgroundColor3 = (typeof(props.Color) == "Color3" and props.Color)
		or (if glass then Theme.Bg else Theme.SurfaceRaised)
	panel.BackgroundTransparency = tonumber(props.Transparency) or (if glass then 0.22 else 0)
	panel.Size = UDim2.new(1, 0, 0, 80)

	UIKit.Corner(panel, props.Radius or Theme.Radius.L)
	if glass then
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = 90
		gradient.Transparency = NumberSequence.new(0, 0.12)
		gradient.Parent = panel
	end
	if props.Padding ~= false then
		UIKit.Padding(panel, props.Padding or Theme.Space.Card)
	end
	if props.Stroke == true or (glass and props.Stroke ~= false and typeof(props.Stroke) ~= "Color3") then
		UIKit.Stroke(panel, 2, Theme.Stroke)
	elseif typeof(props.Stroke) == "Color3" then
		UIKit.Stroke(panel, 1.5, props.Stroke)
	end
	if props.Highlight ~= false then
		addHighlight(panel)
	end
	if type(props.List) == "number" then
		UIKit.List(panel, props.List)
	end

	local parent = applyProps(panel, props, PANEL_SPECIAL)
	addChildren(panel, props.Children)
	if parent then
		panel.Parent = parent
	end
	if props.Elevation and panel.Parent then
		UIKit.Shadow(panel, props.Elevation)
	end
	return panel
end

local CHIP_SPECIAL = {
	Text = true,
	Color = true,
	TextColor = true,
	TextSize = true,
	Icon = true,
	Filled = true,
	OnClick = true,
	Transparency = true,
	Size = true,
	Name = true,
	Sound = true,
	Children = true,
}

-- UIKit.Chip(props) -> Frame (ou TextButton se tiver OnClick)
-- Etiqueta pequena em forma de pílula (ex.: "x2 moedas", "Raro", "Nv. 3").
-- props: Text, Color (cor da etiqueta; padrão Theme.TextDim), Filled = true (fundo
--        cheio com texto escuro), Icon (símbolo curto ou imagem "rbxasset..."),
--        TextSize (padrão 14), OnClick = função (vira um botão), Size (padrão: largura
--        automática), Name, Parent, Position, AnchorPoint, LayoutOrder...
-- O texto fica em chip.Label (mude chip.Label.Text para trocar).
function UIKit.Chip(props)
	if type(props) == "string" then
		props = { Text = props }
	end
	props = props or {}
	ensureSetup()

	local color = typeof(props.Color) == "Color3" and props.Color or Theme.TextDim
	local filled = props.Filled == true
	local onClick = if type(props.OnClick) == "function" then props.OnClick else nil
	local touchHeight = if layout.IsTouch then math.max(28, math.ceil(MIN_TOUCH_TARGET / math.max(currentScale, 0.1)))
		else 28

	local chip
	if onClick then
		chip = Instance.new("TextButton")
		chip.Text = ""
		chip.AutoButtonColor = false
		chip.Selectable = true
	else
		chip = Instance.new("Frame")
	end
	chip.Name = props.Name or "Chip"
	chip.BorderSizePixel = 0
	chip.BackgroundColor3 = if filled then color else color:Lerp(Theme.Bg, 0.78)
	chip.BackgroundTransparency = tonumber(props.Transparency) or 0
	if typeof(props.Size) == "UDim2" then
		chip.Size = props.Size
	else
		chip.Size = UDim2.fromOffset(0, if onClick then touchHeight else 26)
		chip.AutomaticSize = Enum.AutomaticSize.X
	end

	UIKit.Corner(chip, Theme.Radius.Pill)
	if not filled then
		local stroke = UIKit.Stroke(chip, 1, color)
		stroke.Transparency = 0.55
	end
	UIKit.Padding(chip, { Left = 10, Right = 10, Top = 0, Bottom = 0 })
	local listLayout = UIKit.List(chip, 5, Enum.FillDirection.Horizontal)
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	local textColor = (typeof(props.TextColor) == "Color3" and props.TextColor)
		or (if filled then Theme.TextDark else lighten(color, 0.35))
	local textSize = math.max(tonumber(props.TextSize) or 14, readableTextFloor())

	if type(props.Icon) == "string" and props.Icon ~= "" then
		if string.find(props.Icon, "://", 1, true) then
			local icon = Instance.new("ImageLabel")
			icon.Name = "Icon"
			icon.BackgroundTransparency = 1
			icon.Image = props.Icon
			icon.ImageColor3 = textColor
			icon.Size = UDim2.fromOffset(textSize + 2, textSize + 2)
			icon.LayoutOrder = 1
			icon.Parent = chip
		else
			local glyph = Instance.new("TextLabel")
			glyph.Name = "Icon"
			glyph.BackgroundTransparency = 1
			glyph.Font = Theme.Font
			glyph.Text = props.Icon
			glyph.TextColor3 = textColor
			glyph.TextSize = textSize
			glyph.Size = UDim2.fromScale(0, 1)
			glyph.AutomaticSize = Enum.AutomaticSize.X
			glyph.LayoutOrder = 1
			glyph.Parent = chip
		end
	end

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Font = Theme.Font
	label.Text = props.Text ~= nil and tostring(props.Text) or ""
	label.TextColor3 = textColor
	label.TextSize = textSize
	label.Size = UDim2.fromScale(0, 1)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.LayoutOrder = 2
	label.Parent = chip

	if onClick then
		local lastClick = 0
		chip.Activated:Connect(function()
			local now = os.clock()
			if now - lastClick < 0.08 then
				return
			end
			lastClick = now
			if props.Sound ~= false then
				UIKit.PlaySound(type(props.Sound) == "string" and props.Sound or "Click")
			end
			UIKit.Pop(chip, 0.06)
			task.spawn(onClick, chip)
		end)
		chip.MouseEnter:Connect(function()
			chip.BackgroundColor3 = if filled then lighten(color, 0.12) else color:Lerp(Theme.Bg, 0.65)
		end)
		chip.MouseLeave:Connect(function()
			chip.BackgroundColor3 = if filled then color else color:Lerp(Theme.Bg, 0.78)
		end)
		applyPressHaptic(chip)
	end

	local parent = applyProps(chip, props, CHIP_SPECIAL)
	addChildren(chip, props.Children)
	if parent then
		chip.Parent = parent
	end
	return chip
end

-- UIKit.IconButton(props, onClick) -> TextButton
-- Botão quadrado com um ícone. props:
--   Icon = imagem ("rbxassetid://..." ou "rbxasset://...") ou Text = símbolo curto ("X", "?")
--   Size = número (lado em pixels) ou UDim2 (padrão 44; no toque cresce até ~44 px reais)
--   Variant (padrão "Secondary"), Color, IconColor, Tooltip = texto da dica,
--   Badge = número/texto numa bolinha vermelha no canto (mude button.Badge.Text depois),
--   e as mesmas props do UIKit.Button (Name, Parent, Position, AnchorPoint, LayoutOrder...).
function UIKit.IconButton(props, onClick)
	if type(props) == "string" then
		props = { Icon = props }
	end
	props = props or {}
	ensureSetup()

	local size = props.Size
	if typeof(size) ~= "UDim2" then
		local side = tonumber(size) or 44
		if layout.IsTouch then
			side = math.max(side, math.ceil(MIN_TOUCH_TARGET / math.max(currentScale, 0.1)))
		end
		size = UDim2.fromOffset(side, side)
	end

	local image = if type(props.Icon) == "string" and string.find(props.Icon, "://", 1, true) then props.Icon else nil
	local buttonProps = {}
	for key, value in pairs(props) do
		if key ~= "Icon" and key ~= "IconColor" and key ~= "Tooltip" and key ~= "Badge" then
			buttonProps[key] = value
		end
	end
	buttonProps.Name = props.Name or "IconButton"
	buttonProps.Size = size
	buttonProps.Text = if image then "" else tostring(props.Text or props.Icon or "")
	buttonProps.Variant = props.Variant or (if typeof(props.Color) == "Color3" then nil else "Secondary")
	buttonProps.CornerRadius = props.CornerRadius or Theme.Radius.M
	buttonProps.TextSize = props.TextSize or 24
	buttonProps.Parent = nil

	local button = UIKit.Button(buttonProps, onClick)

	if image then
		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Size = UDim2.fromScale(0.78, 0.78)
		icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
		icon.ScaleType = Enum.ScaleType.Fit
		icon.Image = image
		icon.ImageColor3 = typeof(props.IconColor) == "Color3" and props.IconColor or Theme.Text
		icon.Parent = button
	end

	if props.Badge ~= nil then
		local badge = Instance.new("TextLabel")
		badge.Name = "Badge"
		badge.AnchorPoint = Vector2.new(0.5, 0.5)
		badge.Position = UDim2.new(1, -6, 0, 6)
		badge.Size = UDim2.fromOffset(20, 20)
		badge.AutomaticSize = Enum.AutomaticSize.X
		badge.BackgroundColor3 = Theme.Danger
		badge.Font = Theme.NumberFont
		badge.Text = tostring(props.Badge)
		badge.TextColor3 = Theme.Text
		badge.TextSize = math.max(13, readableTextFloor())
		badge.ZIndex = button.ZIndex + 2
		UIKit.Corner(badge, Theme.Radius.Pill)
		UIKit.Padding(badge, { Left = 5, Right = 5, Top = 0, Bottom = 0 })
		UIKit.Stroke(badge, 2, Theme.Stroke)
		badge.Parent = button
		badge.Visible = tostring(props.Badge) ~= "" and tostring(props.Badge) ~= "0"
	end

	if type(props.Tooltip) == "string" and props.Tooltip ~= "" then
		UIKit.Tooltip(button, props.Tooltip)
	end

	if typeof(props.Parent) == "Instance" then
		button.Parent = props.Parent
	end
	return button
end

-------------------------------------------------------------------------------
-- Abas
-------------------------------------------------------------------------------

-- UIKit.Tabs(parent, tabs, onSelect) -> {Select(id), Selected, Frame, Buttons}
-- tabs = lista de {Id = "Loja", Text = "Loja"} (ou só textos: {"Loja", "Passes"}).
-- Cria uma barra de abas (pílula) dentro de "parent", já com a primeira aba marcada.
-- onSelect(id) é chamada quando o jogador troca de aba ou quando Select(id) troca a aba
-- (Select(id, true) troca sem chamar). Ajuste a posição/tamanho em tabs.Frame.
function UIKit.Tabs(parent, tabs, onSelect)
	ensureSetup()
	tabs = type(tabs) == "table" and tabs or {}
	local count = math.max(#tabs, 1)
	local height = if layout.IsTouch then 52 else 44

	local bar = UIKit.New("Frame", {
		Name = "Tabs",
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = Theme.SurfaceSunken,
		BackgroundTransparency = 0.2,
	})
	UIKit.Corner(bar, Theme.Radius.L)
	UIKit.Padding(bar, 4)
	local listLayout = UIKit.List(bar, 4, Enum.FillDirection.Horizontal)
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	local object = { Frame = bar, Buttons = {}, Selected = nil, Order = {} }

	-- Marca a aba "id". silent = true não chama onSelect.
	function object.Select(...)
		local args = table.pack(...)
		local first = if args[1] == object then 2 else 1
		local id, silent = args[first], args[first + 1]
		if object.Buttons[id] == nil then
			return
		end
		local changed = object.Selected ~= id
		object.Selected = id
		for tabId, button in pairs(object.Buttons) do
			button:SetAttribute("Selected", tabId == id)
		end
		if changed and silent ~= true and type(onSelect) == "function" then
			onSelect(id)
		end
	end

	for index, tab in ipairs(tabs) do
		local id, text
		if type(tab) == "table" then
			id = if tab.Id ~= nil then tab.Id else tostring(index)
			text = tab.Text or tostring(id)
		else
			id = tab
			text = tostring(tab)
		end
		local button = UIKit.Button({
			Name = "Tab_" .. tostring(id),
			Text = text,
			Variant = "Ghost",
			Size = UDim2.new(1 / count, -4 * (count - 1) / count, 1, 0),
			CornerRadius = Theme.Radius.M,
			TextSize = 18,
			LayoutOrder = index,
			Parent = bar,
		}, function()
			object.Select(id)
		end)
		object.Buttons[id] = button
		table.insert(object.Order, id)
	end

	if object.Order[1] ~= nil then
		object.Select(object.Order[1], true)
	end
	if typeof(parent) == "Instance" then
		bar.Parent = parent
	end
	return object
end

-------------------------------------------------------------------------------
-- Dica (tooltip)
-------------------------------------------------------------------------------

local tooltipUi = nil -- {Root, Frame, Label}
local tooltipOwner = nil -- objeto que está mostrando a dica agora

-- Cria (uma vez) a dica compartilhada numa tela própria, acima de tudo.
local function ensureTooltip()
	if tooltipUi and tooltipUi.Root.Parent and tooltipUi.Root.Parent.Parent then
		return tooltipUi
	end
	local screen = UIKit.GetScreen("UIKitTooltips", TOOLTIP_DISPLAY_ORDER)
	local root = UIKit.New("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = screen,
	})
	local frame = UIKit.New("Frame", {
		Name = "Tooltip",
		AnchorPoint = Vector2.new(0.5, 1),
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		BackgroundColor3 = Theme.SurfaceRaised,
		BackgroundTransparency = 0.04,
		Visible = false,
		ZIndex = 5,
		Parent = root,
	})
	UIKit.Corner(frame, Theme.Radius.S)
	UIKit.Stroke(frame, 1.5, Theme.Stroke)
	UIKit.Padding(frame, { Left = 10, Right = 10, Top = 5, Bottom = 5 })
	local label = UIKit.New("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		TextColor3 = Theme.Text,
		ZIndex = 6,
		Parent = frame,
	})
	UIKit.TextStyle(label, "Caption")
	UIKit.Shadow(frame, 1)
	tooltipUi = { Root = root, Frame = frame, Label = label }
	return tooltipUi
end

local function hideTooltip(target)
	if tooltipUi and (target == nil or tooltipOwner == target) then
		tooltipUi.Frame.Visible = false
		tooltipOwner = nil
	end
end

local function showTooltip(target, text)
	if not target.Parent or not isOnScreen(target) then
		return
	end
	local ui = ensureTooltip()
	ui.Label.Text = text
	local scale = if currentScale > 0 then currentScale else 1
	local relative = target.AbsolutePosition - ui.Root.AbsolutePosition
	local targetSize = target.AbsoluteSize
	local rootSize = ui.Root.AbsoluteSize / scale

	local x = (relative.X + targetSize.X / 2) / scale
	local y = relative.Y / scale - 6
	local anchorY = 1
	if y < 40 then
		-- Sem espaço em cima: mostra embaixo do objeto.
		y = (relative.Y + targetSize.Y) / scale + 6
		anchorY = 0
	end
	-- Não deixa a dica sair pelas laterais (largura estimada pelo texto).
	local halfWidth = ui.Label.TextBounds.X / 2 + 12
	if rootSize.X > halfWidth * 2 then
		x = math.clamp(x, halfWidth + 4, rootSize.X - halfWidth - 4)
	end

	ui.Frame.AnchorPoint = Vector2.new(0.5, anchorY)
	ui.Frame.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	ui.Frame.Visible = true
	ui.Label.TextTransparency = 1
	UIKit.Tween(ui.Label, { TextTransparency = 0 }, Theme.Motion.Base)
	tooltipOwner = target
end

-- UIKit.Tooltip(target, text) -> {SetText(texto), Destroy()} | nil
-- Mostra "text" perto de "target" depois de 0,4 s com o mouse em cima (PC), quando o
-- controle seleciona o objeto, ou segurando o dedo nele (toque). Some ao sair.
function UIKit.Tooltip(target, text)
	if typeof(target) ~= "Instance" or not target:IsA("GuiObject") then
		return nil
	end
	ensureSetup()
	local handle = { Text = tostring(text or "") }
	local trove = Trove.new()
	local serial = 0
	local active = false

	local function schedule(delay)
		serial += 1
		local mySerial = serial
		task.delay(delay, function()
			if mySerial == serial and active and handle.Text ~= "" and target.Parent then
				showTooltip(target, handle.Text)
			end
		end)
	end
	local function stop()
		active = false
		serial += 1
		hideTooltip(target)
	end

	trove:Connect(target.MouseEnter, function()
		if layout.IsTouch then
			return
		end
		active = true
		schedule(TOOLTIP_DELAY)
	end)
	trove:Connect(target.MouseLeave, stop)
	trove:Connect(target.SelectionGained, function()
		active = true
		schedule(TOOLTIP_DELAY)
	end)
	trove:Connect(target.SelectionLost, stop)
	trove:Connect(target.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			active = true
			schedule(TOOLTIP_TOUCH_HOLD)
		end
	end)
	trove:Connect(target.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			stop()
		end
	end)
	trove:Connect(target:GetPropertyChangedSignal("Visible"), function()
		if not target.Visible then
			stop()
		end
	end)

	-- Troca o texto da dica (também handle:SetText(texto)).
	function handle.SetText(...)
		local args = table.pack(...)
		local value = if args[1] == handle then args[2] else args[1]
		handle.Text = tostring(value or "")
		if tooltipOwner == target and tooltipUi then
			if handle.Text == "" then
				hideTooltip(target)
			else
				tooltipUi.Label.Text = handle.Text
			end
		end
	end
	-- Tira a dica do objeto.
	function handle.Destroy()
		stop()
		trove:Clean()
	end
	trove:Connect(target.Destroying, handle.Destroy)
	return handle
end

-------------------------------------------------------------------------------
-- Faixa de comemoração (Banner)
-------------------------------------------------------------------------------

-- Junta os elementos de uma faixa e as transparências "de repouso" deles, para dar
-- fade in/out em tudo de uma vez (fade não é movimento: vale com "menos movimento").
local function collectFadeTargets(root)
	local targets = {}
	local function add(inst, property)
		table.insert(targets, { Inst = inst, Property = property, Rest = inst[property] })
	end
	for _, inst in ipairs(root:GetDescendants()) do
		if inst:IsA("TextLabel") then
			add(inst, "TextTransparency")
			if inst.TextStrokeTransparency < 1 then
				add(inst, "TextStrokeTransparency")
			end
			if inst.BackgroundTransparency < 1 then
				add(inst, "BackgroundTransparency")
			end
		elseif inst:IsA("ImageLabel") then
			add(inst, "ImageTransparency")
		elseif inst:IsA("Frame") and inst.BackgroundTransparency < 1 then
			add(inst, "BackgroundTransparency")
		elseif inst:IsA("UIStroke") then
			add(inst, "Transparency")
		end
	end
	if root.BackgroundTransparency < 1 then
		add(root, "BackgroundTransparency")
	end
	return targets
end

local function fadeTargets(targets, visible, info)
	for _, target in ipairs(targets) do
		if target.Inst.Parent or target.Inst:IsA("GuiObject") then
			local goal = if visible then target.Rest else 1
			TweenService:Create(target.Inst, info, { [target.Property] = goal }):Play()
		end
	end
end

local function setTargetsHidden(targets)
	for _, target in ipairs(targets) do
		target.Inst[target.Property] = 1
	end
end

-- UIKit.Banner(props) -> {Frame, Level, Dismiss(), IsShowing(), Dismissed: Signal}
-- Faixa de comemoração (seção 3.10). props:
--   Title (texto grande), Subtitle (opcional), Color (padrão Theme.Rare),
--   Level = 3 (faixa central de ~3 s) ou 4 (faixa épica de lado a lado, ~7 s),
--   Duration (segundos; 0 = só some com Dismiss), Sound (vaga de som opcional).
-- Aparece na hora (quem organiza a FILA é quem chama): guarde o "handle" e espere
-- handle.Dismissed (dispara uma vez, quando a faixa sumiu de vez) para mostrar a próxima.
function UIKit.Banner(props)
	if type(props) == "string" then
		props = { Title = props }
	end
	props = props or {}
	ensureSetup()

	local level = if (tonumber(props.Level) or 3) >= 4 then 4 else 3
	local color = typeof(props.Color) == "Color3" and props.Color or Theme.Rare
	local duration = tonumber(props.Duration) or (if level == 4 then 7 else 3)
	local screen = UIKit.GetScreen("UIKitBanners", BANNER_DISPLAY_ORDER)

	local handle = { Level = level, Dismissed = Signal.new() }
	local showing = true
	local trove = Trove.new()
	local frame, scaleObject

	if level == 3 then
		-- Faixa central: cartão escuro com borda brilhante que "passeia".
		frame = UIKit.New("Frame", {
			Name = "Banner",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.22),
			Size = UDim2.fromOffset(560, 96),
			BackgroundColor3 = Theme.Bg,
			BackgroundTransparency = 0.06,
			ZIndex = 2,
		})
		local canvasWidth = screen.AbsoluteSize.X / math.max(currentScale, 0.1)
		if canvasWidth > 0 and canvasWidth < 600 then
			frame.Size = UDim2.fromOffset(math.max(canvasWidth - 32, 240), 96)
		end
		UIKit.Corner(frame, Theme.Radius.L)
		local border = UIKit.Stroke(frame, 2.5, Color3.new(1, 1, 1))
		local shine = UIKit.New("UIGradient", {
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, color),
				ColorSequenceKeypoint.new(0.5, lighten(color, 0.7)),
				ColorSequenceKeypoint.new(1, color),
			}),
			Parent = border,
		})
		-- Faixinha colorida na esquerda (igual às janelas).
		local strip = UIKit.New("Frame", {
			Name = "AccentBar",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 14, 0.5, 0),
			Size = UDim2.new(0, 6, 1, -28),
			BackgroundColor3 = color,
			ZIndex = 3,
			Parent = frame,
		})
		UIKit.Corner(strip, Theme.Radius.Pill)

		local hasSubtitle = type(props.Subtitle) == "string" and props.Subtitle ~= ""
		local title = UIKit.New("TextLabel", {
			Name = "Title",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(34, if hasSubtitle then 10 else 0),
			Size = UDim2.new(1, -50, if hasSubtitle then 0 else 1, if hasSubtitle then 46 else 0),
			Font = Theme.Type.Display.Font,
			Text = tostring(props.Title or ""),
			TextColor3 = lighten(color, 0.55),
			TextScaled = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextStrokeColor3 = Theme.Stroke,
			TextStrokeTransparency = 0.4,
			ZIndex = 3,
			Parent = frame,
		})
		UIKit.New("UITextSizeConstraint", { MaxTextSize = 36, MinTextSize = 14, Parent = title })
		if hasSubtitle then
			local subtitle = UIKit.New("TextLabel", {
				Name = "Subtitle",
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(34, 56),
				Size = UDim2.new(1, -50, 0, 28),
				Text = props.Subtitle,
				TextColor3 = Theme.TextDim,
				TextScaled = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 3,
				Parent = frame,
			})
			UIKit.New("UITextSizeConstraint", {
				MaxTextSize = 18,
				MinTextSize = math.clamp(math.max(12, readableTextFloor()), 1, 18),
				Parent = subtitle,
			})
		end
		scaleObject = UIKit.New("UIScale", { Name = "UIKitScale", Parent = frame })
		frame.Parent = screen
		UIKit.Shadow(frame, 2)

		-- Brilho passeando pela borda (só enquanto a faixa aparece).
		if not reducedMotion then
			shine.Offset = Vector2.new(-1, 0)
			local sweep = TweenService:Create(
				shine,
				TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Offset = Vector2.new(1, 0) }
			)
			sweep:Play()
			trove:Add(function()
				sweep:Cancel()
			end)
		end
	else
		-- Faixa épica: de lado a lado, título enorme e linhas que se abrem do centro.
		frame = UIKit.New("Frame", {
			Name = "EpicBanner",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.34),
			Size = UDim2.new(1, 0, 0, 176),
			BackgroundColor3 = Theme.Bg,
			BackgroundTransparency = 0.12,
			ZIndex = 2,
		})
		UIKit.New("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.18, 0),
				NumberSequenceKeypoint.new(0.82, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = frame,
		})
		local lines = {}
		for index, y in ipairs({ 0, 1 }) do
			local line = UIKit.New("Frame", {
				Name = if index == 1 then "LineTop" else "LineBottom",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, y),
				Size = UDim2.new(0.8, 0, 0, 3),
				BackgroundColor3 = color,
				ZIndex = 3,
				Parent = frame,
			})
			UIKit.New("UIGradient", {
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 1),
					NumberSequenceKeypoint.new(0.5, 0),
					NumberSequenceKeypoint.new(1, 1),
				}),
				Parent = line,
			})
			lines[index] = line
		end
		local hasSubtitle = type(props.Subtitle) == "string" and props.Subtitle ~= ""
		local title = UIKit.New("TextLabel", {
			Name = "Title",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, if hasSubtitle then 18 else 30),
			Size = UDim2.new(0.9, 0, 0, 96),
			Font = Theme.Type.Display.Font,
			Text = tostring(props.Title or ""),
			TextColor3 = Color3.new(1, 1, 1),
			TextScaled = true,
			TextStrokeColor3 = Theme.Stroke,
			TextStrokeTransparency = 0.3,
			ZIndex = 4,
			Parent = frame,
		})
		UIKit.New("UITextSizeConstraint", { MaxTextSize = 60, MinTextSize = 20, Parent = title })
		UIKit.New("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(lighten(color, 0.6), color),
			Parent = title,
		})
		if hasSubtitle then
			local subtitle = UIKit.New("TextLabel", {
				Name = "Subtitle",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 118),
				Size = UDim2.new(0.8, 0, 0, 34),
				Text = props.Subtitle,
				TextColor3 = Theme.TextDim,
				TextScaled = true,
				TextStrokeColor3 = Theme.Stroke,
				TextStrokeTransparency = 0.5,
				ZIndex = 4,
				Parent = frame,
			})
			UIKit.New("UITextSizeConstraint", {
				MaxTextSize = 24,
				MinTextSize = math.clamp(math.max(12, readableTextFloor()), 1, 24),
				Parent = subtitle,
			})
		end
		scaleObject = UIKit.New("UIScale", { Name = "UIKitScale", Parent = title })
		frame.Parent = screen

		-- Linhas se abrindo do centro.
		if not reducedMotion then
			for _, line in ipairs(lines) do
				line.Size = UDim2.new(0, 0, 0, 3)
				TweenService:Create(line, motionInfo("Enter", true), { Size = UDim2.new(0.8, 0, 0, 3) }):Play()
			end
		end
	end

	local targets = collectFadeTargets(frame)
	setTargetsHidden(targets)
	fadeTargets(targets, true, motionInfo("Base", false))
	if not reducedMotion then
		scaleObject.Scale = if level == 4 then 1.25 else 0.7
		TweenService:Create(scaleObject, motionInfo("Pop", true), { Scale = 1 }):Play()
	end
	if type(props.Sound) == "string" and props.Sound ~= "" then
		UIKit.PlaySound(props.Sound)
	end

	handle.Frame = frame

	-- Tira a faixa (com fade). Pode chamar mais de uma vez; só a primeira vale.
	function handle.Dismiss()
		if not showing then
			return
		end
		showing = false
		trove:Clean()
		local info = motionInfo("Exit", false)
		fadeTargets(targets, false, TweenInfo.new(math.max(info.Time, 0.2), info.EasingStyle, info.EasingDirection))
		if not reducedMotion then
			TweenService:Create(scaleObject, motionInfo("Exit", true), { Scale = 0.94 }):Play()
		end
		task.delay(math.max(info.Time, 0.2) + 0.05, function()
			frame:Destroy()
			handle.Dismissed:Fire()
		end)
	end

	-- true enquanto a faixa está na tela (antes do Dismiss).
	function handle.IsShowing()
		return showing
	end

	if duration > 0 then
		task.delay(duration, handle.Dismiss)
	end
	return handle
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

-- Cor do cabeçalho: superfície levantada no topo, indo para a superfície da janela.
local HEADER_TOP = Theme.SurfaceRaised
local HEADER_BOTTOM = Theme.SurfaceRaised:Lerp(Theme.Surface, 0.55)

-- Degradê do cabeçalho e do pedaço que tampa os cantos de baixo (HeaderFill).
local function headerSequences(radius)
	local fillStart = math.clamp((HEADER_HEIGHT - radius) / HEADER_HEIGHT, 0, 1)
	local header = ColorSequence.new(HEADER_TOP, HEADER_BOTTOM)
	local fill = ColorSequence.new(HEADER_TOP:Lerp(HEADER_BOTTOM, fillStart), HEADER_BOTTOM)
	return header, fill
end

-- Degradê de destaque (faixinha da esquerda e linha embaixo do cabeçalho).
local function accentSequence(color)
	if typeof(color) == "Color3" then
		return ColorSequence.new(color, color:Lerp(Theme.Accent2, 0.35))
	end
	return ColorSequence.new(Theme.Accent, Theme.Accent2)
end

-- Liga/desliga o desfoque do mundo atrás das janelas (desfoque real só no cliente).
local function updateBlur()
	local wanted = false
	for _, window in pairs(windows) do
		if window.IsOpen() then
			wanted = true
			break
		end
	end
	-- Efeitos no "baixo": sem desfoque (economiza no celular fraco).
	if wanted then
		local ok, quality = pcall(StateController.GetEffectsQuality)
		if ok and quality == 1 then
			wanted = false
		end
	end

	if wanted then
		if not (blurEffect and blurEffect.Parent == Lighting) then
			blurEffect = Instance.new("BlurEffect")
			blurEffect.Name = BLUR_NAME
			blurEffect.Size = 0
			blurEffect.Parent = Lighting
		end
		blurEffect.Enabled = true
		UIKit.Tween(blurEffect, { Size = BLUR_SIZE }, motionInfo("Base", false))
	elseif blurEffect and blurEffect.Parent then
		local effect = blurEffect
		local tween = UIKit.Tween(effect, { Size = 0 }, motionInfo("Exit", false))
		tween.Completed:Connect(function(state)
			if state ~= Enum.PlaybackState.Completed or effect ~= blurEffect then
				return
			end
			for _, window in pairs(windows) do
				if window.IsOpen() then
					return
				end
			end
			effect.Enabled = false
		end)
	end
end

-- UIKit.Window(name, title, size) -> window
-- window = {
--   Gui (ScreenGui), Frame (a janela), Content (ScrollingFrame onde vai o conteúdo),
--   Open(), Close(), IsOpen(), Toggle(), SetTitle(texto), Destroy(),
--   OnClose: Signal, OnOpen: Signal, TitleLabel, CloseButton,
--   Header (cabeçalho), HeaderHeight (altura dele em pixels),
--   SetAccent(cor) (cor da faixinha de destaque; nil = rosa/roxo padrão),
--   SetFooter(frame) (rodapé fixo embaixo, fora da rolagem; nil tira),
--   IsSheet() (true quando a janela virou folha de tela cheia no celular)
-- }
-- Só uma janela fica aberta por vez. Esc / B do controle / botão X fecham.
-- Open/Close/IsOpen funcionam com ponto ou dois-pontos (window.Open() ou window:Open()).
-- O Content rola sozinho quando o conteúdo passa da altura (AutomaticCanvasSize).
-- No celular, janelas grandes viram "folhas" de tela cheia (dentro da área segura).
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
		HeaderHeight = HEADER_HEIGHT,
	}
	local isOpen = false
	local destroyed = false
	local animationSerial = 0
	local fitScale = 1
	local designSize = size -- tamanho pedido (a folha do celular usa a tela toda)
	local sheet = false
	local accentColor = nil
	local footerHolder = nil
	local footerFrame = nil
	local shadow = nil

	-- Tela própria da janela (desligada enquanto fechada).
	local screenName = "Window_" .. name
	local gui = UIKit.GetScreen(screenName, WINDOW_DISPLAY_ORDER)
	gui.Enabled = false
	pcall(function()
		-- O véu pode cobrir o "notch" também (a janela fica dentro da área segura).
		gui.ClipToDeviceSafeArea = false
	end)
	for _, child in ipairs(gui:GetChildren()) do
		if child ~= scaleObjects[gui] then
			child:Destroy()
		end
	end

	-- Véu escuro atrás da janela (também impede cliques no jogo por trás).
	-- Passa das bordas da área segura para cobrir a tela inteira.
	local backdrop = UIKit.New("Frame", {
		Name = "Backdrop",
		Position = UDim2.fromOffset(-BACKDROP_OVERSCAN, -BACKDROP_OVERSCAN),
		Size = UDim2.new(1, BACKDROP_OVERSCAN * 2, 1, BACKDROP_OVERSCAN * 2),
		BackgroundColor3 = Theme.Backdrop,
		BackgroundTransparency = Theme.BackdropTransparency,
		Active = true,
		ZIndex = 1,
		Parent = gui,
	})

	-- A janela em si: superfície escura, contorno escuro e brilho de 1 px no topo.
	local frame = UIKit.New("Frame", {
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = size,
		BackgroundColor3 = Theme.Surface,
		Active = true,
		ZIndex = 3,
		Parent = gui,
	})
	local frameCorner = UIKit.Corner(frame, Theme.Radius.XL)
	UIKit.New("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(205, 205, 216)),
		Parent = frame,
	})
	UIKit.Stroke(frame, 2, Theme.Stroke)
	addHighlight(frame)

	-- Escala da janela: encolhe se ela não couber na tela e anima ao abrir/fechar.
	local windowScale = UIKit.New("UIScale", { Name = "UIKitScale", Parent = frame })
	windowScale:SetAttribute("Rest", 1)

	-- Cabeçalho discreto com o título, uma faixinha de destaque e uma linha embaixo.
	-- (Os nomes "Header" e "HeaderFill" e o UIGradient do Header continuam existindo:
	-- telas antigas pintam o cabeçalho por eles; a cor pintada vira o destaque.)
	local radius = Theme.Radius.XL.Offset
	local headerSeq, fillSeq = headerSequences(radius)
	local header = UIKit.New("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = frame,
	})
	local headerCorner = UIKit.Corner(header, Theme.Radius.XL)
	local headerGradient = UIKit.New("UIGradient", { Rotation = 90, Color = headerSeq, Parent = header })
	-- Tampa os cantos arredondados de baixo do cabeçalho (só os de cima ficam redondos).
	local headerFill = UIKit.New("Frame", {
		Name = "HeaderFill",
		Size = UDim2.new(1, 0, 0, radius),
		Position = UDim2.new(0, 0, 1, -radius),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = header,
	})
	local headerFillGradient = UIKit.New("UIGradient", { Rotation = 90, Color = fillSeq, Parent = headerFill })

	local divider = UIKit.New("Frame", {
		Name = "Divider",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, -32, 0, 2),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 2,
		Parent = header,
	})
	local dividerGradient = UIKit.New("UIGradient", {
		Color = accentSequence(nil),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.6, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = divider,
	})

	local accentBar = UIKit.New("Frame", {
		Name = "AccentBar",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 18, 0.5, 0),
		Size = UDim2.fromOffset(5, 26),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 2,
		Parent = header,
	})
	UIKit.Corner(accentBar, Theme.Radius.Pill)
	local accentBarGradient = UIKit.New("UIGradient", { Rotation = 90, Color = accentSequence(nil), Parent = accentBar })

	local titleLabel = UIKit.New("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(34, 6),
		Size = UDim2.new(1, -96, 1, -12),
		Font = Theme.TitleFont,
		Text = tostring(title or ""),
		TextColor3 = Theme.Text,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
		Parent = header,
	})
	UIKit.New("UITextSizeConstraint", {
		MaxTextSize = Theme.Type.Title.Size,
		MinTextSize = math.clamp(math.max(12, readableTextFloor()), 1, Theme.Type.Title.Size),
		Parent = titleLabel,
	})

	local closeButton = UIKit.Button({
		Name = "CloseButton",
		Text = "X",
		Variant = "Ghost",
		HoverColor = Theme.Danger,
		Size = UDim2.fromOffset(40, 40),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		TextSize = 22,
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
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.Accent,
		ScrollBarImageTransparency = 0.3,
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
	window.Header = header

	-- Troca a cor de destaque (também window:SetAccent(cor)). nil = rosa/roxo padrão.
	function window.SetAccent(...)
		local args = table.pack(...)
		local color = if args[1] == window then args[2] else args[1]
		accentColor = if typeof(color) == "Color3" then color else nil
		local sequence = accentSequence(accentColor)
		accentBarGradient.Color = sequence
		dividerGradient.Color = sequence
		content.ScrollBarImageColor3 = accentColor or Theme.Accent
	end

	-- Compatibilidade: telas antigas (ex.: a Barraca) pintam o UIGradient do Header e do
	-- HeaderFill com a cor delas. Em vez de pintar o cabeçalho inteiro (visual antigo),
	-- a cor pintada vira o destaque da janela e o cabeçalho volta ao normal.
	local function onHeaderPainted(gradient, sequence)
		local keypoints = gradient.Color.Keypoints
		local painted = keypoints[1] and keypoints[1].Value
		if painted == nil or painted == sequence.Keypoints[1].Value then
			return
		end
		window.SetAccent(painted)
		gradient.Color = sequence
	end
	trove:Connect(headerGradient:GetPropertyChangedSignal("Color"), function()
		onHeaderPainted(headerGradient, headerSeq)
	end)
	trove:Connect(headerFillGradient:GetPropertyChangedSignal("Color"), function()
		onHeaderPainted(headerFillGradient, fillSeq)
	end)

	-- Calcula a escala para a janela caber na tela (nunca aumenta além de 1).
	local function computeFit()
		if sheet then
			return 1
		end
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

	-- No celular, a janela vira folha de tela cheia se o tamanho pedido não couber bem.
	local function shouldBeSheet()
		if layout.Class ~= "Phone" then
			return false
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return false
		end
		local viewport = camera.ViewportSize
		local pixelWidth = designSize.X.Scale * viewport.X + designSize.X.Offset * currentScale
		local pixelHeight = designSize.Y.Scale * viewport.Y + designSize.Y.Offset * currentScale
		return pixelWidth > viewport.X * SHEET_FRACTION or pixelHeight > viewport.Y * SHEET_FRACTION
	end

	-- Aplica o modo (folha de tela cheia ou janela normal).
	local function applyMode()
		sheet = shouldBeSheet()
		local wantedSize = if sheet then SHEET_SIZE else designSize
		if frame.Size ~= wantedSize then
			frame.Size = wantedSize
		end
		local corner = if sheet then UDim.new(0, 0) else Theme.Radius.XL
		frameCorner.CornerRadius = corner
		headerCorner.CornerRadius = corner
		if shadow then
			shadow.SetEnabled(not sheet)
		end
	end

	-- Reaplica o modo e a escala de "caber na tela" (chamado quando a tela ou o tamanho mudam).
	function window._Refit()
		if destroyed then
			return
		end
		applyMode()
		fitScale = computeFit()
		windowScale:SetAttribute("Rest", fitScale)
		if isOpen then
			windowScale.Scale = fitScale
			frame.Position = UDim2.fromScale(0.5, 0.5)
		end
	end
	-- Alguém mudou o tamanho da janela: esse vira o tamanho pedido (a folha continua cheia).
	trove:Connect(frame:GetPropertyChangedSignal("Size"), function()
		if frame.Size ~= SHEET_SIZE or not sheet then
			if frame.Size ~= SHEET_SIZE then
				designSize = frame.Size
			end
		end
		window._Refit()
	end)

	-- Folha no celular: a janela cheia sem sombra. No resto: sombra suave.
	shadow = UIKit.Shadow(frame, 2)

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

		applyMode()
		fitScale = computeFit()
		windowScale:SetAttribute("Rest", fitScale)
		gui.Enabled = true

		-- Animação de entrada: véu aparece; a janela cresce (ou a folha sobe de baixo).
		backdrop.BackgroundTransparency = 1
		UIKit.Tween(backdrop, { BackgroundTransparency = Theme.BackdropTransparency }, motionInfo("Base", false))
		if sheet then
			windowScale.Scale = 1
			if reducedMotion then
				frame.Position = UDim2.fromScale(0.5, 0.5)
			else
				frame.Position = UDim2.fromScale(0.5, 1.5)
				UIKit.Tween(
					frame,
					{ Position = UDim2.fromScale(0.5, 0.5) },
					TweenInfo.new(Theme.Motion.Enter, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
				)
			end
		else
			frame.Position = UDim2.fromScale(0.5, 0.5)
			windowScale.Scale = if reducedMotion then fitScale else fitScale * 0.92
			UIKit.Tween(windowScale, { Scale = fitScale }, motionInfo("Enter", true))
		end
		updateBlur()

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
		UIKit.Tween(backdrop, { BackgroundTransparency = 1 }, motionInfo("Exit", false))
		local tween
		if sheet then
			tween = UIKit.Tween(frame, { Position = UDim2.fromScale(0.5, 1.5) }, motionInfo("Exit", true))
		else
			tween = UIKit.Tween(windowScale, { Scale = fitScale * 0.94 }, motionInfo("Exit", true))
		end
		tween.Completed:Connect(function()
			if serial == animationSerial and not isOpen and not destroyed then
				gui.Enabled = false
				frame.Position = UDim2.fromScale(0.5, 0.5)
			end
		end)
		updateBlur()

		window.OnClose:Fire()
	end

	-- true se a janela está aberta.
	function window.IsOpen()
		return isOpen
	end

	-- true se a janela está em modo "folha de tela cheia" (celular).
	function window.IsSheet()
		return sheet
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

	-- Rodapé fixo (também window:SetFooter(frame)): o frame vai para baixo da janela,
	-- fora da rolagem, com uma linha em cima. A altura vem do Size.Y.Offset do frame
	-- (padrão 56) e ele ocupa a largura toda. SetFooter(nil) tira o rodapé (o frame
	-- antigo sai da janela, mas não é destruído).
	function window.SetFooter(...)
		local args = table.pack(...)
		local newFooter = if args[1] == window then args[2] else args[1]
		if footerFrame and footerFrame ~= newFooter and footerFrame.Parent == footerHolder then
			footerFrame.Parent = nil
		end
		footerFrame = nil
		if footerHolder then
			footerHolder:Destroy()
			footerHolder = nil
		end

		local top = content.Position.Y.Offset
		if typeof(newFooter) ~= "Instance" or not newFooter:IsA("GuiObject") then
			content.Size = UDim2.new(1, -CONTENT_MARGIN * 2, 1, -(top + CONTENT_MARGIN))
			return
		end

		local height = newFooter.Size.Y.Offset
		if newFooter.Size.Y.Scale ~= 0 or height <= 0 then
			height = 56
		end
		footerHolder = UIKit.New("Frame", {
			Name = "Footer",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, CONTENT_MARGIN, 1, -CONTENT_MARGIN),
			Size = UDim2.new(1, -CONTENT_MARGIN * 2, 0, height),
			BackgroundTransparency = 1,
			ZIndex = 2,
			Parent = frame,
		})
		UIKit.New("Frame", {
			Name = "FooterLine",
			Position = UDim2.fromOffset(0, -9),
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = Theme.Highlight,
			BackgroundTransparency = 0.88,
			ZIndex = 2,
			Parent = footerHolder,
		})
		newFooter.AnchorPoint = Vector2.zero
		newFooter.Position = UDim2.new()
		newFooter.Size = UDim2.fromScale(1, 1)
		newFooter.Parent = footerHolder
		footerFrame = newFooter
		content.Size = UDim2.new(1, -CONTENT_MARGIN * 2, 1, -(top + height + 18 + CONTENT_MARGIN))
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
		if shadow then
			shadow.Destroy()
		end
		scaleObjects[gui] = nil
		if screens[screenName] == gui then
			screens[screenName] = nil
		end
		gui:Destroy()
		updateBlur()
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
	ensureAudio()
	-- Celular: o jogo é todo pensado deitado (paisagem), girando para os dois lados.
	pcall(function()
		getPlayerGui().ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	end)
end

function UIKit.Start()
	-- Cria os grupos de som já no começo (a música e os ambientes usam).
	for groupName in pairs(GROUP_NAMES) do
		UIKit.GetSoundGroup(groupName)
	end
	-- Pré-carrega o som de clique, para o primeiro clique já ter som.
	task.spawn(function()
		local soundId = UIKit.ResolveSound("Click")
		if not soundId then
			return
		end
		local sound = acquireVoice("Click")
		if not sound then
			return
		end
		if sound.SoundId ~= soundId then
			sound.SoundId = soundId
		end
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
