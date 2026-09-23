-- NotifyController: mostra avisos ("toasts") empilhados no topo da tela.
--
-- O servidor manda avisos pelo RemoteEvent "Notify" com
--   {Text = "...", Kind = "info"|"success"|"warning"|"error"|"rare", Duration = segundos?}
-- e qualquer módulo do cliente pode mostrar um aviso com
--   NotifyController.Show("Sem moedas suficientes!", "error")
--
-- Cada tipo tem uma cor e um ícone. O tipo "rare" (conquistas, Galáctico, portal)
-- tem borda arco-íris girando, brilho pulsando e som.
-- Avisos iguais repetidos não empilham: o aviso que já está na tela ganha um "x2", "x3"...
-- Tocar/clicar num aviso fecha ele na hora.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Net = require(Util:WaitForChild("Net"))
local Trove = require(Util:WaitForChild("Trove"))

local UIKit = require(script.Parent.Parent:WaitForChild("UI"):WaitForChild("UIKit"))
local Theme = UIKit.Theme

local NotifyController = {}

-------------------------------------------------------------------------------
-- Constantes de layout e tempo
-------------------------------------------------------------------------------

local DISPLAY_ORDER = 60 -- acima das janelas (30) e do HUD
local MAX_TOASTS = 5 -- quantos avisos aparecem ao mesmo tempo
local MAX_WIDTH = 470 -- largura máxima de um aviso (pixels da interface)
local SCREEN_WIDTH_FRACTION = 0.92 -- no celular, no máximo 92% da largura da tela
local TOP_OFFSET = 62 -- distância do topo (abaixo da barra do Roblox)
local STACK_GAP = 8 -- espaço entre avisos
local PAD_X, PAD_Y = 12, 10 -- espaço interno
local ICON_SIZE = 32 -- bolinha do ícone
local ICON_GAP = 10 -- espaço entre ícone e texto
local COUNT_WIDTH = 36 -- espaço reservado para o "x2"
local TEXT_SIZE = 18
local RARE_TEXT_SIZE = 21
local MIN_DURATION, MAX_DURATION = 1, 30

-- Visual de cada tipo de aviso.
local KINDS = {
	info = {
		Color = Theme.Info,
		Background = Color3.fromRGB(26, 34, 70),
		Icon = "i",
		Duration = 4,
	},
	success = {
		Color = Theme.Success,
		Background = Color3.fromRGB(20, 54, 42),
		Icon = "✓",
		Duration = 4,
	},
	warning = {
		Color = Theme.Warning,
		Background = Color3.fromRGB(66, 46, 16),
		Icon = "!",
		Duration = 5,
	},
	error = {
		Color = Theme.Danger,
		Background = Color3.fromRGB(70, 20, 32),
		Icon = "✕",
		Duration = 5,
		Sound = "Error",
	},
	rare = {
		Color = Theme.Rare,
		Background = Color3.fromRGB(64, 30, 88),
		Icon = "★",
		Duration = 7,
		Sound = "Notify",
	},
}

-- Arco-íris da borda dos avisos raros.
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 84, 178)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 214, 64)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(70, 215, 115)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(70, 172, 255)),
	ColorSequenceKeypoint.new(0.8, Color3.fromRGB(146, 94, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 84, 178)),
})

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local container = nil -- Frame que empilha os avisos
local active = {} -- avisos na tela (mais antigo primeiro)
local orderCounter = 0 -- para o mais novo ficar em cima
local initialized = false

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Largura dos avisos em "pixels da interface" (já descontando o UIScale).
local function computeWidth()
	local camera = workspace.CurrentCamera
	local scale = UIKit.GetScale()
	if not camera or scale <= 0 then
		return MAX_WIDTH
	end
	local available = camera.ViewportSize.X / scale * SCREEN_WIDTH_FRACTION
	return math.floor(math.clamp(available, 200, MAX_WIDTH))
end

-- Cria (se preciso) a tela e a "pilha" de avisos.
local function ensureContainer()
	if container and container.Parent then
		return container
	end
	local screen = UIKit.GetScreen("Notifications", DISPLAY_ORDER)
	container = UIKit.New("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, TOP_OFFSET),
		Size = UDim2.new(0, MAX_WIDTH, 1, -TOP_OFFSET),
		BackgroundTransparency = 1,
		Parent = screen,
	})
	local layout = UIKit.List(container, STACK_GAP, Enum.FillDirection.Vertical)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	return container
end

-- Muda a transparência de todas as partes de um aviso.
-- alpha = 0 (totalmente visível) até 1 (invisível).
local function fadeParts(parts, alpha, time)
	for _, part in ipairs(parts) do
		local inst, property, visibleValue = part[1], part[2], part[3]
		local value = visibleValue + (1 - visibleValue) * alpha
		if time and time > 0 then
			UIKit.Tween(inst, { [property] = value }, time)
		else
			inst[property] = value
		end
	end
end

-- Tira o aviso da lista de ativos.
local function removeFromActive(toast)
	local index = table.find(active, toast)
	if index then
		table.remove(active, index)
	end
end

-- Fecha um aviso com animação e depois destrói tudo dele.
local function dismiss(toast)
	if toast.Closing then
		return
	end
	toast.Closing = true
	removeFromActive(toast)

	fadeParts(toast.Parts, 1, 0.2)
	UIKit.Tween(toast.Scale, { Scale = 0.85 }, 0.2)
	-- A "caixa" encolhe, e os avisos de baixo sobem suavemente.
	UIKit.Tween(toast.Holder, { Size = UDim2.new(1, 0, 0, 0) }, 0.25)
	task.delay(0.3, function()
		toast.Trove:Clean()
	end)
end

-- Agenda o fechamento automático (reagendar cancela o anterior).
local function scheduleDismiss(toast, duration)
	toast.Serial += 1
	local serial = toast.Serial
	task.delay(duration, function()
		if toast.Serial == serial then
			dismiss(toast)
		end
	end)
end

-- Monta o visual de um aviso novo.
local function createToast(text, kind, style)
	local parent = ensureContainer()
	local width = computeWidth()
	parent.Size = UDim2.new(0, width, 1, -TOP_OFFSET)

	local isRare = kind == "rare"
	local font = isRare and Theme.TitleFont or Theme.Font
	local textSize = isRare and RARE_TEXT_SIZE or TEXT_SIZE

	-- Mede a altura do texto para saber o tamanho do aviso.
	local labelWidth = width - PAD_X * 2 - ICON_SIZE - ICON_GAP - COUNT_WIDTH
	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, textSize, font, Vector2.new(labelWidth, 10000))
	end)
	local textHeight = ok and bounds.Y or textSize * 2
	local height = math.max(ICON_SIZE, textHeight) + PAD_Y * 2

	local trove = Trove.new()
	orderCounter += 1

	-- "Caixa" que reserva o espaço na pilha (cresce de 0 até a altura do aviso).
	local holder = trove:Add(UIKit.New("Frame", {
		Name = "Toast",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = -orderCounter,
		Parent = parent,
	}))

	-- O cartão do aviso (é um botão: tocar fecha).
	local card = UIKit.New("TextButton", {
		Name = "Card",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = style.Background,
		Size = UDim2.new(1, 0, 0, height),
		Selectable = false,
		Parent = holder,
	})
	UIKit.Corner(card, 14)
	local stroke = UIKit.Stroke(card, isRare and 3.5 or 2.5, style.Color)
	local scale = UIKit.New("UIScale", { Name = "UIKitScale", Parent = card })
	scale:SetAttribute("Rest", 1)

	-- Bolinha colorida com o ícone.
	local badge = UIKit.New("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, PAD_X, 0.5, 0),
		Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE),
		BackgroundColor3 = style.Color,
		Parent = card,
	})
	UIKit.Corner(badge, UDim.new(1, 0))
	local icon = UIKit.New("TextLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.TitleFont,
		Text = style.Icon,
		TextColor3 = Theme.TextDark,
		TextSize = 20,
		Parent = badge,
	})

	-- O texto do aviso.
	local label = UIKit.New("TextLabel", {
		Name = "Message",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(PAD_X + ICON_SIZE + ICON_GAP, PAD_Y),
		Size = UDim2.new(0, labelWidth, 1, -PAD_Y * 2),
		Font = font,
		Text = text,
		TextColor3 = isRare and Theme.Rare or Theme.Text,
		TextSize = textSize,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextStrokeColor3 = Theme.Stroke,
		TextStrokeTransparency = 0.6,
		Parent = card,
	})

	-- Contador "x2" para avisos repetidos.
	local countLabel = UIKit.New("TextLabel", {
		Name = "Count",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -PAD_X + 4, 0.5, 0),
		Size = UDim2.fromOffset(COUNT_WIDTH, 24),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = style.Color,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = card,
	})

	-- Partes que aparecem/somem juntas (objeto, propriedade, valor quando visível).
	local parts = {
		{ card, "BackgroundTransparency", 0.04 },
		{ stroke, "Transparency", 0 },
		{ badge, "BackgroundTransparency", 0 },
		{ icon, "TextTransparency", 0 },
		{ label, "TextTransparency", 0 },
		{ label, "TextStrokeTransparency", 0.6 },
		{ countLabel, "TextTransparency", 0 },
	}

	local toast = {
		Key = kind .. "|" .. text,
		Holder = holder,
		Card = card,
		Scale = scale,
		CountLabel = countLabel,
		Count = 1,
		Parts = parts,
		Trove = trove,
		Serial = 0,
		Closing = false,
	}

	-- Efeitos especiais dos avisos raros: borda arco-íris girando e brilho pulsando.
	if isRare then
		local rainbow = UIKit.New("UIGradient", { Color = RAINBOW, Parent = stroke })
		local spin = UIKit.Tween(
			rainbow,
			{ Rotation = 360 },
			TweenInfo.new(2.5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1)
		)
		local glow = UIKit.Tween(
			card,
			{ BackgroundColor3 = UIKit.Lighten(style.Background, 0.18) },
			TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		)
		local wobble = UIKit.Tween(
			badge,
			{ Rotation = 12 },
			TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		)
		trove:Add(function()
			spin:Cancel()
			glow:Cancel()
			wobble:Cancel()
		end)
	end

	-- Tocar/clicar fecha o aviso.
	trove:Connect(card.Activated, function()
		dismiss(toast)
	end)

	-- Animação de entrada: a caixa abre espaço e o cartão aparece com um "pulo".
	fadeParts(parts, 1, 0)
	scale.Scale = 0.7
	UIKit.Tween(holder, { Size = UDim2.new(1, 0, 0, height) }, 0.2)
	UIKit.Tween(scale, { Scale = 1 }, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
	fadeParts(parts, 0, 0.2)

	return toast
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- NotifyController.Show(text, kind?, duration?)
-- kind: "info" (padrão), "success", "warning", "error" ou "rare".
-- duration: segundos na tela (padrão depende do tipo).
function NotifyController.Show(text, kind, duration)
	if text == nil then
		return
	end
	text = tostring(text)
	if text == "" then
		return
	end
	if type(kind) ~= "string" or not KINDS[kind] then
		kind = "info"
	end
	local style = KINDS[kind]

	duration = tonumber(duration)
	if not duration or duration ~= duration then
		duration = style.Duration
	end
	duration = math.clamp(duration, MIN_DURATION, MAX_DURATION)

	-- Mesmo aviso já na tela: só aumenta o contador e reinicia o tempo.
	local key = kind .. "|" .. text
	for _, toast in ipairs(active) do
		if toast.Key == key and not toast.Closing then
			toast.Count += 1
			toast.CountLabel.Text = "x" .. toast.Count
			toast.CountLabel.Visible = true
			UIKit.Pop(toast.Card, 0.08)
			scheduleDismiss(toast, duration)
			return
		end
	end

	-- Tela cheia: fecha os mais antigos.
	while #active >= MAX_TOASTS do
		dismiss(active[1])
	end

	local toast = createToast(text, kind, style)
	table.insert(active, toast)
	scheduleDismiss(toast, duration)

	if style.Sound then
		UIKit.PlaySound(style.Sound)
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function NotifyController.Init()
	if initialized then
		return
	end
	initialized = true

	-- Avisos vindos do servidor.
	Net.On("Notify", function(payload)
		if type(payload) == "table" then
			NotifyController.Show(payload.Text, payload.Kind, payload.Duration)
		elseif type(payload) == "string" then
			NotifyController.Show(payload, "info")
		end
	end)
end

function NotifyController.Start() end

-- Deixa as funções do módulo funcionarem com "." e também com ":"
-- (ex.: NotifyController.Algo(x) e NotifyController:Algo(x) fazem a mesma coisa).
for name, fn in pairs(NotifyController) do
	if type(fn) == "function" then
		NotifyController[name] = function(first, ...)
			if first == NotifyController then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return NotifyController
