-- AnnouncementController (lobby e partida): faixas grandes no topo da tela, para todos os jogadores.
--
-- 1. Aviso de admin (RemoteEvent "Announcement"):
--    o servidor manda {Text (já filtrado pelo Roblox), From (nome de quem avisou),
--    Duration (segundos)} e aparece "📢 Aviso de <From>: <Text>" por Duration segundos.
--    Se chegarem vários avisos juntos, eles entram numa fila e aparecem um de cada vez.
--    Tocar/clicar no aviso fecha ele antes da hora.
-- 2. Evento global (estado "GlobalEvent", enviado pelo servidor para todo mundo):
--    nil (sem evento) ou {Key, Name, EndsAt, Effects}. Mostra uma faixa dourada com o
--    nome do evento, o que ele faz e a contagem regressiva até EndsAt
--    (EndsAt usa o relógio do servidor: workspace:GetServerTimeNow()).
--
-- As faixas ficam no meio do topo, logo abaixo da barra do Roblox (as colunas do HUD
-- ficam nos cantos), e empurram os avisos pequenos (NotifyController) para baixo.
-- Com uma janela aberta, a faixa do evento se esconde (para não cobrir a janela).
--
-- API pública:
--   AnnouncementController.GetActiveEvent() -> {Key, Name, EndsAt, Effects}?  (evento valendo agora)
--   AnnouncementController.GetBottomOffset() -> número?  onde as faixas terminam (nil = sem faixa)
--   AnnouncementController.DescribeEffects(effects) -> {string}  textos curtos dos efeitos
--       (ex.: {"Moedas ×2"}), usados aqui e no painel de bônus do HUD.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")
local Net = require(Util:WaitForChild("Net"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))
local Trove = require(Util:WaitForChild("Trove"))
local StatsConfig = require(Config:WaitForChild("Stats"))

local Controllers = script.Parent
local UIKit = require(Controllers.Parent:WaitForChild("UI"):WaitForChild("UIKit"))
local StateController = require(Controllers:WaitForChild("StateController"))
local NotifyController = require(Controllers:WaitForChild("NotifyController"))

local Theme = UIKit.Theme

local AnnouncementController = {}

-------------------------------------------------------------------------------
-- Constantes (layout e tempo)
-------------------------------------------------------------------------------

local SCREEN_NAME = "TopBanners"
local DISPLAY_ORDER = 55 -- acima das janelas (30), abaixo dos avisos pequenos (60)

local TOP_GAP = 6 -- espaço abaixo da barra do Roblox
local STACK_GAP = 6 -- espaço entre as faixas
local NOTIFY_GAP = 8 -- espaço entre as faixas e os avisos pequenos
local MAX_WIDTH = 640 -- largura máxima das faixas (pixels da interface)
local EVENT_WIDTH = 420 -- largura da faixa do evento
local SCREEN_WIDTH_FRACTION = 0.92 -- no celular, no máximo 92% da largura da tela

local DEFAULT_DURATION = 8 -- segundos, se o servidor não mandar Duration
local MIN_DURATION, MAX_DURATION = 3, 30
local MAX_QUEUE = 10 -- avisos esperando a vez (os mais velhos saem se passar disso)
local MAX_TEXT_LENGTH = 300 -- corte de segurança, em letras (o servidor já limita a 200)
local TIMER_INTERVAL = 0.25 -- atualização da contagem regressiva do evento

local ANNOUNCE_COLOR = Theme.Accent
local EVENT_COLOR = Theme.Rare

-- Como mostrar cada efeito de evento (as chaves de Effects em Config/Admins.lua):
--   Kind "mult"    -> "Moedas ×2"
--   Kind "add"     -> "Sorte de tier +1"
--   Kind "percent" -> "Chance de gigante +30%"
--   Kind "time"    -> "Recarga do quadro: 50% do tempo"
-- Efeitos novos que não estão aqui aparecem pelo nome do stat (Config.Stats.Display),
-- com "×" se a chave terminar em "Mult" e "+" se terminar em "Add".
-- Order = posição na lista (os desconhecidos vão para o fim, em ordem alfabética).
local EFFECT_FORMATS = {
	CoinMult = { Name = "Moedas", Kind = "mult", Order = 1 },
	TierLuckAdd = { Name = "Sorte de tier", Kind = "add", Order = 2 },
	EnchantChanceMult = { Name = "Chance de encantamento", Kind = "mult", Order = 3 },
	GiantChanceAdd = { Name = "Chance de gigante", Kind = "percent", Order = 4 },
	BoardCooldownMult = { Name = "Recarga do quadro", Kind = "time", Order = 5 },
}

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local trove = Trove.new()
local ui = {} -- peças da interface
local queue = {} -- avisos esperando: {Text, From, Duration}
local showing = false -- um aviso está na tela agora
local announceSerial = 0 -- muda a cada aviso (cancela temporizadores velhos)
local eventVisible = false
local lastTimerText = ""
local started = false
local bottomOffset = nil -- onde as faixas terminam (pixels da interface), ou nil sem faixa na tela

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Número seguro (nil, texto ou NaN viram o padrão).
local function num(value, default)
	value = tonumber(value)
	if value == nil or value ~= value then
		return default or 0
	end
	return value
end

-- Protege um texto para usar dentro de RichText (<, >, & e aspas viram códigos).
local function escapeRichText(text)
	text = string.gsub(text, "&", "&amp;")
	text = string.gsub(text, "<", "&lt;")
	text = string.gsub(text, ">", "&gt;")
	text = string.gsub(text, '"', "&quot;")
	text = string.gsub(text, "'", "&apos;")
	return text
end

-- Cor em "#RRGGBB" para o RichText.
local function toHex(color)
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

-- Largura das faixas em pixels da interface (celular estreito = mais estreita).
local function computeWidth(maxWidth)
	local camera = workspace.CurrentCamera
	local scale = UIKit.GetScale()
	if not camera or scale <= 0 then
		return maxWidth
	end
	local available = camera.ViewportSize.X / scale * SCREEN_WIDTH_FRACTION
	return math.floor(math.clamp(available, 220, maxWidth))
end

-- Distância do topo: logo abaixo da barra do Roblox (a altura dela muda por aparelho).
local function computeTop()
	local scale = UIKit.GetScale()
	if scale <= 0 then
		scale = 1
	end
	local ok, inset = pcall(function()
		return GuiService:GetGuiInset()
	end)
	local insetY = if ok and typeof(inset) == "Vector2" then inset.Y else 36
	return math.ceil(insetY / scale) + TOP_GAP
end

-- Configuração dos eventos (Config/Admins.lua). Carregada só quando precisa, e
-- protegida: se o arquivo faltar, as faixas continuam funcionando com o que o servidor mandou.
local adminsConfig = nil
local function getAdminsConfig()
	if adminsConfig ~= nil then
		return adminsConfig or nil
	end
	local module = Config:FindFirstChild("Admins")
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	adminsConfig = if ok and type(result) == "table" then result else false
	return adminsConfig or nil
end

-------------------------------------------------------------------------------
-- Efeitos do evento em texto
-------------------------------------------------------------------------------

-- Nome de um stat pelo Config.Stats.Display (ex.: "TierLuck" -> "Sorte de Tier").
local function statName(key)
	local display = StatsConfig.Display and StatsConfig.Display[key]
	if type(display) == "table" and type(display.Name) == "string" then
		return display.Name, display.Format
	end
	return key, nil
end

-- Descobre nome e tipo de um efeito (os conhecidos primeiro, depois pelo fim da chave).
local function effectFormat(key)
	local known = EFFECT_FORMATS[key]
	if known then
		return known.Name, known.Kind
	end
	local base = string.match(key, "^(.-)Mult$")
	if base and base ~= "" then
		return (statName(base)), "mult"
	end
	base = string.match(key, "^(.-)Add$")
	if base and base ~= "" then
		local name, format = statName(base)
		return name, if format == "percent" then "percent" else "add"
	end
	return (statName(key)), "add"
end

-- Um efeito em texto (ou nil se ele não muda nada, como ×1 ou +0).
local function effectText(key, value)
	if type(value) ~= "number" or value ~= value then
		return nil
	end
	local name, kind = effectFormat(key)
	if kind == "mult" then
		if math.abs(value - 1) < 1e-6 then
			return nil
		end
		return name .. " ×" .. NumberFormat.Abbrev(value, 2)
	elseif kind == "time" then
		if math.abs(value - 1) < 1e-6 then
			return nil
		end
		return name .. ": " .. NumberFormat.Percent(value, 0) .. " do tempo"
	elseif kind == "percent" then
		if value == 0 then
			return nil
		end
		return name .. " " .. (if value > 0 then "+" else "") .. NumberFormat.Percent(value, 0)
	end
	if value == 0 then
		return nil
	end
	return name .. " " .. (if value > 0 then "+" else "") .. NumberFormat.Abbrev(value, 2)
end

-- AnnouncementController.DescribeEffects(effects) -> {string}
-- Aceita um dicionário {CoinMult = 2, ...} ou uma lista {{Stat/Key, Value/Mult}, ...}.
function AnnouncementController.DescribeEffects(effects)
	local lines = {}
	if type(effects) ~= "table" then
		return lines
	end
	if #effects > 0 then
		for _, effect in ipairs(effects) do
			if type(effect) == "table" then
				local key = effect.Key or effect.Stat or effect.Name
				local value = effect.Value or effect.Mult or effect.Amount
				if type(key) == "string" then
					local text = effectText(key, value)
					if text then
						table.insert(lines, text)
					end
				end
			elseif type(effect) == "string" then
				table.insert(lines, effect)
			end
		end
		return lines
	end
	-- Dicionário: numa ordem fixa, para a lista não "pular" de lugar.
	local keys = {}
	for key in pairs(effects) do
		if type(key) == "string" then
			table.insert(keys, key)
		end
	end
	table.sort(keys, function(a, b)
		local orderA = EFFECT_FORMATS[a] and EFFECT_FORMATS[a].Order or math.huge
		local orderB = EFFECT_FORMATS[b] and EFFECT_FORMATS[b].Order or math.huge
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a < b
	end)
	for _, key in ipairs(keys) do
		local text = effectText(key, effects[key])
		if text then
			table.insert(lines, text)
		end
	end
	return lines
end

-- AnnouncementController.GetBottomOffset() -> número ou nil
-- Onde as faixas do topo terminam (pixels da interface, já com um espaço embaixo), ou nil
-- quando nenhuma faixa está na tela. A contagem do lobby (LobbyUI) usa isto para descer.
function AnnouncementController.GetBottomOffset()
	return bottomOffset
end

-- Evento global valendo agora (ou nil).
function AnnouncementController.GetActiveEvent()
	local event = StateController.Get("GlobalEvent")
	if type(event) ~= "table" then
		return nil
	end
	if num(event.EndsAt, 0) <= workspace:GetServerTimeNow() then
		return nil
	end
	return event
end

-------------------------------------------------------------------------------
-- Montagem da tela
-------------------------------------------------------------------------------

local function build()
	local screen = UIKit.GetScreen(SCREEN_NAME, DISPLAY_ORDER)

	-- Pilha no meio do topo: faixa do evento em cima, aviso de admin embaixo.
	local stack = UIKit.New("Frame", {
		Name = "Stack",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, computeTop()),
		Size = UDim2.fromOffset(MAX_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = screen,
	})
	local layout = UIKit.List(stack, STACK_GAP)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	ui.Stack = stack
	ui.Layout = layout
	trove:Add(stack)

	-- Faixa do evento global.
	local event = UIKit.New("Frame", {
		Name = "GlobalEvent",
		Size = UDim2.fromOffset(EVENT_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(58, 34, 16),
		BackgroundTransparency = 0.08,
		LayoutOrder = 1,
		Visible = false,
		Parent = stack,
	})
	UIKit.Corner(event, 14)
	local eventStroke = UIKit.Stroke(event, 3, Color3.new(1, 1, 1))
	ui.EventGlow = UIKit.New("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, EVENT_COLOR),
			ColorSequenceKeypoint.new(0.5, Theme.Accent),
			ColorSequenceKeypoint.new(1, EVENT_COLOR),
		}),
		Parent = eventStroke,
	})
	UIKit.Padding(event, { Top = 6, Bottom = 8, Left = 12, Right = 12 })
	local eventLayout = UIKit.List(event, 2)
	eventLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	UIKit.New("UIScale", { Name = "UIKitScale", Parent = event }):SetAttribute("Rest", 1)

	local titleRow = UIKit.New("Frame", {
		Name = "TitleRow",
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = event,
	})
	ui.EventTitle = UIKit.New("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -90, 1, 0),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = EVENT_COLOR,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = titleRow,
	})
	UIKit.New("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 12, Parent = ui.EventTitle })
	UIKit.Stroke(ui.EventTitle, 1.5, Theme.Stroke)
	ui.EventTimer = UIKit.New("TextLabel", {
		Name = "Timer",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 86, 1, 0),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Theme.Text,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = titleRow,
	})
	UIKit.Stroke(ui.EventTimer, 1.5, Theme.Stroke)
	ui.EventInfo = UIKit.New("TextLabel", {
		Name = "Info",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Theme.Font,
		Text = "",
		TextColor3 = Theme.TextDim,
		TextSize = 14,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = event,
	})
	ui.Event = event

	-- Faixa do aviso de admin (é um botão: tocar/clicar fecha).
	local announce = UIKit.New("TextButton", {
		Name = "Announcement",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		Size = UDim2.fromOffset(MAX_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(40, 16, 58),
		BackgroundTransparency = 0.04,
		LayoutOrder = 2,
		Visible = false,
		Parent = stack,
	})
	UIKit.Corner(announce, 16)
	ui.AnnounceStroke = UIKit.Stroke(announce, 4, Color3.new(1, 1, 1))
	ui.AnnounceGlow = UIKit.New("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, ANNOUNCE_COLOR),
			ColorSequenceKeypoint.new(0.5, Theme.Accent2),
			ColorSequenceKeypoint.new(1, ANNOUNCE_COLOR),
		}),
		Parent = ui.AnnounceStroke,
	})
	UIKit.Padding(announce, { Top = 12, Bottom = 10, Left = 16, Right = 16 })
	local announceLayout = UIKit.List(announce, 8)
	announceLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	ui.AnnounceScale = UIKit.New("UIScale", { Name = "UIKitScale", Parent = announce })
	ui.AnnounceScale:SetAttribute("Rest", 1)
	ui.AnnounceText = UIKit.New("TextLabel", {
		Name = "Message",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = Theme.TitleFont,
		RichText = true,
		Text = "",
		TextColor3 = Theme.Text,
		TextSize = 24,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		LayoutOrder = 1,
		Parent = announce,
	})
	UIKit.Stroke(ui.AnnounceText, 2, Theme.Stroke)
	-- Barrinha que mostra quanto tempo falta para o aviso sumir.
	local barHolder = UIKit.New("Frame", {
		Name = "TimeBar",
		Size = UDim2.new(1, 0, 0, 4),
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.3,
		LayoutOrder = 2,
		Parent = announce,
	})
	UIKit.Corner(barHolder, UDim.new(1, 0))
	ui.AnnounceBar = UIKit.New("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = ANNOUNCE_COLOR,
		Parent = barHolder,
	})
	UIKit.Corner(ui.AnnounceBar, UDim.new(1, 0))
	ui.Announce = announce
end

-- Reposiciona a pilha e avisa o NotifyController de quanto espaço ela ocupa.
local function relayout()
	if not ui.Stack then
		return
	end
	local top = computeTop()
	ui.Stack.Position = UDim2.new(0.5, 0, 0, top)
	local width = computeWidth(MAX_WIDTH)
	ui.Stack.Size = UDim2.fromOffset(width, 0)
	ui.Announce.Size = UDim2.fromOffset(width, 0)
	ui.Event.Size = UDim2.fromOffset(math.min(width, EVENT_WIDTH), 0)

	local anyVisible = ui.Event.Visible or ui.Announce.Visible
	if anyVisible then
		local scale = UIKit.GetScale()
		if scale <= 0 then
			scale = 1
		end
		local height = ui.Layout.AbsoluteContentSize.Y / scale
		bottomOffset = top + height + NOTIFY_GAP
		NotifyController.SetTopOffset(bottomOffset)
	else
		bottomOffset = nil
		NotifyController.SetTopOffset(nil)
	end
end

-- A faixa do evento fica na tela o evento inteiro (até 2 horas). Com uma janela aberta
-- (loja, barraca, painel...) ela some, para não cobrir o título e as abas da janela
-- (as janelas ficam numa tela de DisplayOrder menor). Os avisos de admin duram poucos
-- segundos e continuam por cima.
local function isEventBannerShown()
	return eventVisible and not UIKit.IsAnyModalOpen()
end

-------------------------------------------------------------------------------
-- Evento global
-------------------------------------------------------------------------------

-- Atualiza a faixa do evento (nome, efeitos e tempo).
local function refreshEvent()
	if not ui.Event then
		return
	end
	local event = AnnouncementController.GetActiveEvent()
	local wasVisible = eventVisible
	eventVisible = event ~= nil
	ui.Event.Visible = isEventBannerShown()
	if not event then
		if wasVisible then
			relayout()
		end
		return
	end

	local name = tostring(event.Name or event.Key or "Evento")
	ui.EventTitle.Text = "🎉 Evento: " .. name

	-- Linha de baixo: a descrição do Config (se tiver) e os efeitos.
	local parts = {}
	local admins = getAdminsConfig()
	local def = admins and type(admins.Events) == "table" and admins.Events[event.Key] or nil
	if type(def) == "table" and type(def.Description) == "string" and def.Description ~= "" then
		table.insert(parts, def.Description)
	end
	local effects = AnnouncementController.DescribeEffects(event.Effects)
	if #effects > 0 then
		table.insert(parts, table.concat(effects, " • "))
	end
	ui.EventInfo.Text = table.concat(parts, "\n")
	ui.EventInfo.Visible = #parts > 0

	if not wasVisible then
		UIKit.Pop(ui.Event, 0.15)
		UIKit.PlaySound("Notify")
		relayout()
	end
end

-- Contagem regressiva (roda algumas vezes por segundo).
local function updateEventTimer()
	if not ui.Event then
		return
	end
	local event = StateController.Get("GlobalEvent")
	local active = type(event) == "table" and num(event.EndsAt, 0) > workspace:GetServerTimeNow()
	if active ~= eventVisible then
		refreshEvent() -- o tempo acabou (ou o evento começou) sem mensagem nova do servidor
	end
	if not eventVisible then
		return
	end
	local remaining = num(event.EndsAt, 0) - workspace:GetServerTimeNow()
	local text = NumberFormat.Time(math.max(0, math.ceil(remaining)))
	if text ~= lastTimerText then
		lastTimerText = text
		ui.EventTimer.Text = text
	end
end

-------------------------------------------------------------------------------
-- Avisos de admin (fila)
-------------------------------------------------------------------------------

local showNext -- declarada aqui, definida logo abaixo

-- Esconde o aviso atual e chama o próximo da fila.
local function hideAnnouncement(serial)
	if serial ~= announceSerial or not showing then
		return
	end
	announceSerial += 1
	local mySerial = announceSerial
	local tween = UIKit.Tween(ui.AnnounceScale, { Scale = 0.85 }, 0.18)
	UIKit.Tween(ui.Announce, { BackgroundTransparency = 1 }, 0.18)
	UIKit.Tween(ui.AnnounceStroke, { Transparency = 1 }, 0.18)
	UIKit.Tween(ui.AnnounceText, { TextTransparency = 1, TextStrokeTransparency = 1 }, 0.18)
	tween.Completed:Connect(function()
		if mySerial ~= announceSerial then
			return
		end
		ui.Announce.Visible = false
		showing = false
		relayout()
		-- Um respiro entre um aviso e o próximo.
		task.delay(0.3, showNext)
	end)
end

-- Mostra o próximo aviso da fila (se não tiver nenhum na tela).
function showNext()
	if showing or #queue == 0 or not ui.Announce then
		return
	end
	showing = true
	local item = table.remove(queue, 1)
	announceSerial += 1
	local serial = announceSerial

	ui.AnnounceText.Text = ('<font color="%s">📢 Aviso de %s:</font> %s'):format(
		toHex(Theme.Rare),
		escapeRichText(item.From),
		escapeRichText(item.Text)
	)
	ui.Announce.BackgroundTransparency = 0.04
	ui.AnnounceStroke.Transparency = 0
	ui.AnnounceText.TextTransparency = 0
	ui.AnnounceText.TextStrokeTransparency = 0.4
	ui.AnnounceBar.Size = UDim2.fromScale(1, 1)
	ui.Announce.Visible = true
	relayout()

	-- Entrada com um "pulo" e som.
	ui.AnnounceScale.Scale = 0.7
	UIKit.Tween(ui.AnnounceScale, { Scale = 1 }, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
	UIKit.PlaySound("Notify")

	-- A barrinha esvazia até o aviso sumir.
	UIKit.Tween(ui.AnnounceBar, { Size = UDim2.fromScale(0, 1) }, TweenInfo.new(item.Duration, Enum.EasingStyle.Linear))
	task.delay(item.Duration, function()
		hideAnnouncement(serial)
	end)
end

-- Chegou um aviso do servidor: valida e põe na fila.
local function onAnnouncement(payload)
	if type(payload) ~= "table" then
		return
	end
	local text = type(payload.Text) == "string" and payload.Text or ""
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	if text == "" then
		return
	end
	-- Corta em LETRAS, não em bytes: "é" ou um emoji ocupam mais de 1 byte, e cortar no
	-- meio de uma letra deixaria um símbolo quebrado na tela.
	if not utf8.len(text) then
		return -- texto com bytes inválidos: ignora
	end
	local cut = utf8.offset(text, MAX_TEXT_LENGTH + 1)
	if cut then
		text = string.sub(text, 1, cut - 1) .. "..."
	end
	local from = type(payload.From) == "string" and payload.From ~= "" and payload.From or "Admin"
	local duration = math.clamp(num(payload.Duration, DEFAULT_DURATION), MIN_DURATION, MAX_DURATION)

	table.insert(queue, { Text = text, From = from, Duration = duration })
	while #queue > MAX_QUEUE do
		table.remove(queue, 1)
	end
	showNext()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function AnnouncementController.Init()
	-- Escuta os avisos numa thread separada: se o remote demorar a aparecer, o Init
	-- dos outros módulos não fica esperando.
	task.spawn(function()
		trove:Add(Net.On("Announcement", onAnnouncement))
	end)
end

function AnnouncementController.Start()
	if started then
		return
	end
	started = true
	build()

	-- Tocar/clicar no aviso fecha ele.
	trove:Connect(ui.Announce.Activated, function()
		hideAnnouncement(announceSerial)
	end)

	-- A pilha mudou de altura: os avisos pequenos descem/sobem junto.
	trove:Connect(ui.Layout:GetPropertyChangedSignal("AbsoluteContentSize"), relayout)

	-- Tela mudou de tamanho (girar o celular, redimensionar a janela).
	local cameraConnection = nil
	local function watchCamera()
		if cameraConnection then
			cameraConnection:Disconnect()
			cameraConnection = nil
		end
		local camera = workspace.CurrentCamera
		if camera then
			cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				task.defer(relayout) -- espera o UIKit recalcular a escala
			end)
		end
	end
	watchCamera()
	trove:Connect(workspace:GetPropertyChangedSignal("CurrentCamera"), function()
		watchCamera()
		task.defer(relayout)
	end)
	trove:Add(function()
		if cameraConnection then
			cameraConnection:Disconnect()
		end
	end)

	-- Evento global: muda quando o servidor manda, e o relógio conta sozinho.
	trove:Add(StateController.OnChanged("GlobalEvent", refreshEvent))
	-- Abriu/fechou uma janela: a faixa do evento some/volta (veja isEventBannerShown).
	trove:Add(UIKit.ModalChanged:Connect(function()
		local shown = isEventBannerShown()
		if ui.Event and ui.Event.Visible ~= shown then
			ui.Event.Visible = shown
			relayout()
		end
	end))
	local accumulator = 0
	trove:Connect(RunService.Heartbeat, function(dt)
		if eventVisible and ui.EventGlow then
			ui.EventGlow.Rotation = (ui.EventGlow.Rotation + dt * 90) % 360
		end
		if showing and ui.AnnounceGlow then
			ui.AnnounceGlow.Rotation = (ui.AnnounceGlow.Rotation + dt * 120) % 360
		end
		accumulator += dt
		if accumulator >= TIMER_INTERVAL then
			accumulator = 0
			updateEventTimer()
		end
	end)

	refreshEvent()
	updateEventTimer()
	relayout()
end

-- Deixa as funções do módulo funcionarem com "." e também com ":".
for name, fn in pairs(AnnouncementController) do
	if type(fn) == "function" then
		AnnouncementController[name] = function(first, ...)
			if first == AnnouncementController then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return AnnouncementController
