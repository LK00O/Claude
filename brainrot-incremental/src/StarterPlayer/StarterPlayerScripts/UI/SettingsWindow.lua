-- SettingsWindow (lobby e partida): a janela de Configurações.
--
-- Abre pela ação "Settings" (botão do HUD, botão do lobby ou um prompt com
-- ClientAction "Settings"). O jogador pode mudar:
--   * Sensibilidade da câmera, Inverter Y e Campo de visão (FOV);
--   * Correr alternando (apertar uma vez) ou segurando;
--   * Volume da música e dos efeitos;
--   * Números de dano ligados/desligados;
--   * Teclas (teclado): clica no botão da ação e aperta a tecla nova.
--     Se a tecla já era de outra ação, as duas trocam. "Restaurar padrão" volta tudo.
--
-- Salvar: cada mudança espera 1 segundo sem novas mudanças e então manda com
-- Request "SaveSettings" (debounce). O servidor confere, grava no perfil e devolve
-- o perfil atualizado; os outros módulos (câmera, música, movimento...) leem de
-- Profile.Settings e se atualizam sozinhos.
--
-- Só vai para o servidor o que o jogador MEXEU (o conjunto "dirty"): assim uma mudança
-- nunca apaga uma configuração salva que o jogador nem tocou. As teclas só vão quando
-- alguma ação de tecla foi trocada. Enquanto o perfil não chega do servidor, a janela
-- mostra "Carregando suas configurações..." e não deixa mexer em nada.
--
-- No lobby, as linhas que só valem dentro da partida (câmera, FOV e números de dano)
-- ganham o aviso " (vale na partida)".
--
-- Como usar em cada aparelho:
--   * PC: clique e arraste as barrinhas, ou use os botões - e +.
--   * Celular: arraste as barrinhas com o dedo ou toque em - e +.
--   * Controle: navegue com o direcional e aperte A nos botões - e +.
--
-- API:
--   PromptController.Register("Settings", fn) é feito no Init.
--   SettingsWindow.Open() / SettingsWindow.Close() / SettingsWindow.IsOpen()  (extras)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Keybinds = require(Config:WaitForChild("Keybinds"))
local Net = require(Util:WaitForChild("Net"))
local Trove = require(Util:WaitForChild("Trove"))

local UIKit = require(script.Parent:WaitForChild("UIKit"))
local ControllersFolder = script.Parent.Parent:WaitForChild("Controllers")
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme

local SettingsWindow = {}

-- Outros controllers só dentro de funções (regra anti-require-circular).
local function getController(name)
	local module = ControllersFolder:FindFirstChild(name)
	if not module then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

-------------------------------------------------------------------------------
-- Constantes (layout, tempo e faixas de validação)
-------------------------------------------------------------------------------

local WINDOW_NAME = "Settings"
local WINDOW_SIZE = UDim2.fromOffset(780, 600)

local ROW_HEIGHT = 78
local CONTROL_WIDTH = 340 -- área dos controles, à direita de cada linha
local STEP_BUTTON_SIZE = 42 -- botões - e +
local VALUE_WIDTH = 74 -- texto do valor ("0,50", "80°", "70%")
local KNOB_SIZE = 26

local SAVE_DEBOUNCE = 1 -- segundos sem mudanças antes de salvar (pedido na especificação)
local SAVE_RETRY_DELAY = 3 -- espera para tentar salvar de novo depois de um erro
local MAX_SAVE_RETRIES = 3
-- Depois que o servidor confirma um salvamento, o perfil novo leva um instante para
-- chegar. Até lá (no máximo este tempo), o valor confirmado vale mais que um perfil
-- "velho" que ainda esteja a caminho.
local CONFIRM_WAIT = 10

-- Linhas da janela, por seção. As faixas são as mesmas que o SettingsService aceita
-- (seção 8.15 da especificação): são limites de validação, não de balanceamento.
local SECTIONS = {
	{
		Title = "Câmera e mira",
		Color = Theme.Accent2,
		Items = {
			{
				Kind = "Slider",
				Key = "Sensitivity",
				MatchOnly = true, -- só vale na partida (no lobby a descrição ganha um aviso)
				Name = "Sensibilidade",
				Description = "Quão rápido a câmera gira com o mouse, o controle ou o dedo.",
				Min = 0.05,
				Max = 2,
				Step = 0.05,
				Format = "Decimal",
			},
			{
				Kind = "Toggle",
				Key = "InvertY",
				MatchOnly = true, -- só vale na partida (no lobby a descrição ganha um aviso)
				Name = "Inverter eixo Y",
				Description = "Mover para cima faz olhar para baixo (como em simulador de avião).",
			},
			{
				Kind = "Slider",
				Key = "FOV",
				MatchOnly = true, -- só vale na partida (no lobby a descrição ganha um aviso)
				Name = "Campo de visão",
				Description = "Quanto do mundo cabe na tela. Maior = visão mais aberta.",
				Min = 60,
				Max = 110,
				Step = 1,
				Format = "Degrees",
			},
		},
	},
	{
		Title = "Movimento",
		Color = Theme.Info,
		Items = {
			{
				Kind = "Toggle",
				Key = "ToggleSprint",
				Name = "Correr alternando",
				Description = "Ligado: aperte uma vez para correr e de novo para parar. Desligado: segure para correr.",
			},
		},
	},
	{
		Title = "Som",
		Color = Theme.Success,
		Items = {
			{
				Kind = "Slider",
				Key = "MusicVolume",
				Name = "Volume da música",
				Description = "Música de fundo do lobby e dos mapas.",
				Min = 0,
				Max = 1,
				Step = 0.05,
				Format = "Percent",
			},
			{
				Kind = "Slider",
				Key = "SfxVolume",
				Name = "Volume dos efeitos",
				Description = "Tiros, moedas, explosões, botões e avisos.",
				Min = 0,
				Max = 1,
				Step = 0.05,
				Format = "Percent",
			},
		},
	},
	{
		Title = "Jogo",
		Color = Theme.Warning,
		Items = {
			{
				Kind = "Toggle",
				Key = "DamageNumbers",
				MatchOnly = true, -- só vale na partida (no lobby a descrição ganha um aviso)
				Name = "Números de dano",
				Description = "Mostra quanto dano cada tiro causou, pulando do brainrot.",
			},
		},
	},
}

-- Teclas que não podem ser escolhidas (usadas pelo Roblox ou por outras partes do jogo).
local RESERVED_KEYS = {
	[Enum.KeyCode.Escape] = true, -- menu do Roblox (e fecha janelas)
	[Enum.KeyCode.Slash] = true, -- abre o chat
	[Enum.KeyCode.Tab] = true, -- lista de jogadores do Roblox
	[Enum.KeyCode.LeftAlt] = true, -- HUD: soltar o mouse para clicar nos botões
	[Enum.KeyCode.RightAlt] = true,
	-- Modo da torreta (o "ModePrompt" de cada torreta usa sempre o F). Se o Interagir
	-- fosse F, os dois prompts da torreta disputariam a mesma tecla e só um apareceria;
	-- qualquer outra ação no F também dispararia junto com o prompt perto da torreta.
	[Enum.KeyCode.F] = true,
	[Enum.KeyCode.F2] = true, -- painel de testes (DebugPanel)
	[Enum.KeyCode.F3] = true, -- painel de admin (AdminPanel)
	[Enum.KeyCode.F9] = true, -- console do desenvolvedor
	[Enum.KeyCode.F11] = true, -- tela cheia
	[Enum.KeyCode.LeftSuper] = true, -- tecla do Windows / Command
	[Enum.KeyCode.RightSuper] = true,
	[Enum.KeyCode.Menu] = true,
	[Enum.KeyCode.Print] = true,
}

-- Nomes amigáveis das teclas (as letras e F1..F12 já ficam bonitas com o nome do Enum).
local KEY_NAMES = {
	Space = "Espaço",
	LeftShift = "Shift esq.",
	RightShift = "Shift dir.",
	LeftControl = "Ctrl esq.",
	RightControl = "Ctrl dir.",
	Return = "Enter",
	Backspace = "Apagar",
	CapsLock = "Caps Lock",
	Up = "Seta p/ cima",
	Down = "Seta p/ baixo",
	Left = "Seta esq.",
	Right = "Seta dir.",
	PageUp = "Page Up",
	PageDown = "Page Down",
	Zero = "0",
	One = "1",
	Two = "2",
	Three = "3",
	Four = "4",
	Five = "5",
	Six = "6",
	Seven = "7",
	Eight = "8",
	Nine = "9",
	Minus = "-",
	Equals = "=",
	Plus = "+",
	LeftBracket = "[",
	RightBracket = "]",
	Semicolon = ";",
	Quote = "'",
	Comma = ",",
	Period = ".",
	BackSlash = "\\",
	Backquote = "`",
	KeypadPeriod = "Num .",
	KeypadDivide = "Num /",
	KeypadMultiply = "Num *",
	KeypadMinus = "Num -",
	KeypadPlus = "Num +",
	KeypadEnter = "Num Enter",
	KeypadEquals = "Num =",
}

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local window = nil
local windowTrove = Trove.new() -- conexões da janela (vivem enquanto ela existe)
local lifeTrove = Trove.new() -- conexões do módulo

local draft = nil -- cópia local das configurações (o que aparece na janela)
local controls = {} -- [chave] = {Set = fn(valor)} (barrinhas e interruptores)
local keyRows = {} -- [actionId] = {Button, Default, Action}
local descriptionLabels = {} -- {Item, Label} das linhas com descrição (para o aviso do lobby)
local ui = {} -- outras peças (status, botão de restaurar, capa de "carregando")

local activeDrag = nil -- barrinha sendo arrastada: {SetFromX, Input}
local capturingAction = nil -- ação esperando o jogador apertar a tecla nova

-- O que o jogador mexeu e o servidor ainda não confirmou:
local dirty = {} -- [chave da configuração] = true (ex.: dirty.FOV = true)
local dirtyKeys = {} -- [actionId] = true (teclas trocadas; o valor fica em draft.Keybinds)
-- O que o servidor já confirmou, mas o perfil com o valor novo ainda não chegou:
local confirmed = {} -- [chave] = {Value = valor, At = os.clock()}
local confirmedKeys = {} -- [actionId] = {Value = "NomeDaTecla" ou false (padrão), At = os.clock()}

local saving = false -- um pedido de salvar está a caminho
local saveFailed = false
local failures = 0
local saveTimer = nil

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Número com vírgula decimal (padrão brasileiro): 0.5 -> "0,50".
local function decimalText(value, places)
	local text = string.format("%." .. places .. "f", value)
	return (string.gsub(text, "%.", ","))
end

-- Texto do valor de uma barrinha.
local function formatValue(item, value)
	if item.Format == "Percent" then
		return ("%d%%"):format(math.floor(value * 100 + 0.5))
	elseif item.Format == "Degrees" then
		return ("%d°"):format(math.floor(value + 0.5))
	end
	return decimalText(value, 2)
end

-- Arredonda para o "passo" da barrinha e limita à faixa.
local function snap(item, value)
	local steps = math.floor((value - item.Min) / item.Step + 0.5)
	local snapped = math.clamp(item.Min + steps * item.Step, item.Min, item.Max)
	-- Tira o "lixo" de ponto flutuante (0.30000000000000004 -> 0.3).
	return tonumber(string.format("%.4f", snapped)) or snapped
end

-- Nome bonito de uma tecla.
local function keyDisplayName(keyCode)
	if typeof(keyCode) ~= "EnumItem" then
		return "?"
	end
	local name = keyCode.Name
	if KEY_NAMES[name] then
		return KEY_NAMES[name]
	end
	local keypad = string.match(name, "^Keypad(.+)$")
	if keypad then
		return "Num " .. (KEY_NAMES[keypad] or keypad)
	end
	return name
end

-- Tecla atual de uma ação no rascunho (a escolhida ou a padrão).
local function getKey(actionId)
	local action = Keybinds.ById[actionId]
	local custom = draft and draft.Keybinds and draft.Keybinds[actionId]
	if type(custom) == "string" and custom ~= "" then
		-- Enum.KeyCode["NomeErrado"] dá erro, por isso o pcall.
		local ok, keyCode = pcall(function()
			return Enum.KeyCode[custom]
		end)
		if ok and typeof(keyCode) == "EnumItem" then
			return keyCode
		end
	end
	return action and action.Default or Enum.KeyCode.Unknown
end

-- Guarda a tecla de uma ação no rascunho (o perfil guarda só as diferentes do padrão)
-- e marca a ação como "mexida" (vai no próximo salvamento).
local function setKey(actionId, keyCode)
	local action = Keybinds.ById[actionId]
	if action and action.Default == keyCode then
		draft.Keybinds[actionId] = nil
	else
		draft.Keybinds[actionId] = keyCode.Name
	end
	dirtyKeys[actionId] = true
end

-- true se alguma tecla foi trocada.
local function hasCustomKeys()
	for _, action in ipairs(Keybinds.Actions) do
		if getKey(action.Id) ~= action.Default then
			return true
		end
	end
	return false
end

-- true quando o perfil já chegou do servidor. Antes disso, GetSettings() só tem os
-- valores padrão, e salvar poderia apagar o que o jogador tinha salvo.
local function isProfileReady()
	return type(StateController.Get("Profile")) == "table"
end

-- true se o jogador mexeu em algo que o servidor ainda não confirmou.
local function hasDirty()
	return next(dirty) ~= nil or next(dirtyKeys) ~= nil
end

-- true se há mudanças que o servidor ainda não confirmou.
local function hasPendingChanges()
	return saving or hasDirty()
end

-- Recarrega o rascunho a partir do perfil (Profile.Settings com valores padrão) e
-- põe por cima o que o jogador mexeu e ainda não foi confirmado (dirty). Assim o
-- perfil novo nunca apaga uma mudança em andamento, e a mudança nunca apaga o resto.
local function loadDraft()
	local fresh = StateController.GetSettings()
	if type(fresh.Keybinds) ~= "table" then
		fresh.Keybinds = {}
	end

	-- Valores já confirmados pelo servidor: se o perfil ainda não mostra o valor novo
	-- (chegou um perfil "velho"), o confirmado vale. Quando o perfil alcança (ou o tempo
	-- passa), esquecemos a confirmação.
	local now = os.clock()
	for key, entry in pairs(confirmed) do
		if fresh[key] == entry.Value or now - entry.At > CONFIRM_WAIT then
			confirmed[key] = nil
		else
			fresh[key] = entry.Value
		end
	end
	for actionId, entry in pairs(confirmedKeys) do
		if (fresh.Keybinds[actionId] or false) == entry.Value or now - entry.At > CONFIRM_WAIT then
			confirmedKeys[actionId] = nil
		else
			fresh.Keybinds[actionId] = entry.Value or nil
		end
	end

	-- Por cima de tudo, o que o jogador mexeu e ainda não foi confirmado.
	if draft then
		for key in pairs(dirty) do
			fresh[key] = draft[key]
		end
		for actionId in pairs(dirtyKeys) do
			-- nil no rascunho = tecla padrão (fica nil também no novo).
			fresh.Keybinds[actionId] = draft.Keybinds[actionId]
		end
	end
	draft = fresh
end

-------------------------------------------------------------------------------
-- Salvar (com debounce de 1 s)
-------------------------------------------------------------------------------

-- Texto do canto "Salvando..." / "Tudo salvo".
local function refreshStatus()
	if not ui.Status then
		return
	end
	if not isProfileReady() then
		ui.Status.Text = "Carregando..."
		ui.Status.TextColor3 = Theme.Warning
	elseif saveFailed and not saving then
		ui.Status.Text = "Não deu para salvar"
		ui.Status.TextColor3 = Theme.Danger
	elseif hasPendingChanges() then
		ui.Status.Text = "Salvando..."
		ui.Status.TextColor3 = Theme.Warning
	else
		ui.Status.Text = "✓ Tudo salvo"
		ui.Status.TextColor3 = Theme.Success
	end
end

local function cancelSaveTimer()
	if saveTimer then
		pcall(task.cancel, saveTimer)
		saveTimer = nil
	end
end

-- O que vai para o servidor: SÓ as configurações que o jogador mexeu (dirty).
-- As teclas vão só se alguma ação de tecla foi trocada; nesse caso vai o mapa inteiro
-- (o servidor troca o mapa todo), montado a partir do perfil + as trocas do jogador.
-- Devolve (payload, sentKeys): sentKeys guarda o valor enviado de cada ação de tecla
-- (false = padrão), para conferir depois o que o servidor confirmou.
local function buildPayload()
	local payload = {}
	for key in pairs(dirty) do
		payload[key] = draft[key]
	end

	local sentKeys = nil
	if next(dirtyKeys) ~= nil then
		payload.Keybinds = table.clone(draft.Keybinds)
		sentKeys = {}
		for actionId in pairs(dirtyKeys) do
			sentKeys[actionId] = draft.Keybinds[actionId] or false
		end
	end
	return payload, sentKeys
end

local scheduleSave -- declarada aqui, definida logo abaixo

-- Manda as configurações agora (se houver algo novo).
-- Nunca salva antes de o perfil chegar (o rascunho ainda teria só os valores padrão).
local function saveNow()
	if saving or not draft or not hasDirty() or not isProfileReady() then
		return
	end
	saving = true
	refreshStatus()

	local payload, sentKeys = buildPayload()
	local ok, result = Net.Request("SaveSettings", payload)
	saving = false
	if ok then
		-- O servidor confirmou: tira do "dirty" o que foi enviado, MENOS o que o jogador
		-- mudou de novo enquanto o pedido viajava (esse vai no próximo salvamento).
		-- O que saiu do "dirty" fica em "confirmed" até o perfil novo chegar.
		local now = os.clock()
		for key, sentValue in pairs(payload) do
			if key ~= "Keybinds" and draft[key] == sentValue then
				dirty[key] = nil
				confirmed[key] = { Value = sentValue, At = now }
			end
		end
		if sentKeys then
			for actionId, sentValue in pairs(sentKeys) do
				if (draft.Keybinds[actionId] or false) == sentValue then
					dirtyKeys[actionId] = nil
					confirmedKeys[actionId] = { Value = sentValue, At = now }
				end
			end
		end
		saveFailed = false
		failures = 0
	else
		failures += 1
		if not saveFailed then
			NotifyController.Show(tostring(result or "Não deu para salvar as configurações."), "error", 4)
		end
		saveFailed = true
	end

	-- Mudou algo enquanto salvava (ou deu erro): agenda outro salvamento.
	if hasDirty() then
		if ok then
			scheduleSave(SAVE_DEBOUNCE)
		elseif failures <= MAX_SAVE_RETRIES then
			scheduleSave(SAVE_RETRY_DELAY)
		end
	end
	refreshStatus()
end

-- Agenda um salvamento para daqui a "delay" segundos (reagendar cancela o anterior).
function scheduleSave(delay)
	cancelSaveTimer()
	saveTimer = task.delay(delay, function()
		saveTimer = nil
		saveNow()
	end)
end

-- Salva já (usado ao fechar a janela).
local function flushSave()
	cancelSaveTimer()
	task.spawn(saveNow)
end

-- Depois de marcar o que mudou (dirty/dirtyKeys): salva 1 s depois da ÚLTIMA mudança.
local function markChanged()
	failures = 0
	scheduleSave(SAVE_DEBOUNCE)
	refreshStatus()
end

-------------------------------------------------------------------------------
-- Atualização dos controles
-------------------------------------------------------------------------------

-- Atualiza os botões das teclas (texto, cor e "Padrão: X").
local function refreshKeyRows()
	for actionId, entry in pairs(keyRows) do
		local key = getKey(actionId)
		local custom = key ~= entry.Action.Default
		if capturingAction == actionId then
			entry.Button.Text = "Aperte uma tecla..."
			entry.Button.BackgroundColor3 = Theme.Warning
		else
			entry.Button.Text = keyDisplayName(key)
			entry.Button.BackgroundColor3 = if custom then Theme.Accent else Theme.Accent2
		end
		if custom then
			entry.Default.Text = "Trocada (padrão: " .. keyDisplayName(entry.Action.Default) .. ")"
			entry.Default.TextColor3 = Theme.Warning
		else
			entry.Default.Text = "Padrão: " .. keyDisplayName(entry.Action.Default)
			entry.Default.TextColor3 = Theme.TextDim
		end
	end
	if ui.RestoreButton then
		ui.RestoreButton:SetAttribute("Disabled", not hasCustomKeys())
	end
end

-- Mostra ou esconde a capa "Carregando suas configurações..." (fica por cima da
-- lista e não deixa mexer em nada até o perfil chegar).
local function refreshLoading()
	if ui.LoadingCover then
		ui.LoadingCover.Visible = not isProfileReady()
	end
end

-- Descrição de uma linha. No lobby, as linhas que só valem na partida ganham um aviso.
local function describe(item)
	local text = item.Description or ""
	if item.MatchOnly and workspace:GetAttribute("Role") == "Lobby" then
		text ..= " (vale na partida)"
	end
	return text
end

-- Atualiza as descrições (o papel do servidor pode mudar: lobby <-> partida).
local function refreshDescriptions()
	for _, entry in ipairs(descriptionLabels) do
		entry.Label.Text = describe(entry.Item)
	end
end

-- Atualiza todos os controles com o rascunho.
local function refreshAllControls()
	refreshLoading()
	if not draft then
		return
	end
	for key, control in pairs(controls) do
		control.Set(draft[key])
	end
	refreshKeyRows()
	refreshStatus()
end

-- Muda uma configuração (vinda de uma barrinha ou de um interruptor).
local function changeSetting(key, value)
	if not draft or not isProfileReady() or draft[key] == value then
		return
	end
	draft[key] = value
	dirty[key] = true
	local control = controls[key]
	if control then
		control.Set(value)
	end
	markChanged()
end

-------------------------------------------------------------------------------
-- Troca de teclas
-------------------------------------------------------------------------------

-- Começa (ou cancela) a espera pela tecla nova de uma ação.
local function toggleCapture(actionId)
	if not isProfileReady() then
		return
	end
	if capturingAction == actionId then
		capturingAction = nil
	else
		capturingAction = actionId
		local entry = keyRows[actionId]
		if entry then
			UIKit.Pop(entry.Button, 0.1)
		end
	end
	refreshKeyRows()
end

-- Dá a tecla nova para a ação. Se outra ação usava essa tecla, as duas trocam.
local function assignKey(actionId, keyCode)
	local action = Keybinds.ById[actionId]
	capturingAction = nil
	if not action or not draft or not isProfileReady() then
		refreshKeyRows()
		return
	end

	local oldKey = getKey(actionId)
	if keyCode ~= oldKey then
		for _, other in ipairs(Keybinds.Actions) do
			if other.Id ~= actionId and getKey(other.Id) == keyCode then
				setKey(other.Id, oldKey)
				NotifyController.Show(
					('"%s" trocou de tecla com "%s" e agora usa %s.'):format(other.Name, action.Name, keyDisplayName(oldKey)),
					"info",
					4
				)
			end
		end
		setKey(actionId, keyCode) -- setKey marca a ação (e a trocada) em dirtyKeys
		markChanged()
	end

	refreshKeyRows()
	local entry = keyRows[actionId]
	if entry then
		UIKit.Pop(entry.Button, 0.15)
	end
end

-- Recebe as teclas apertadas enquanto uma ação espera a tecla nova.
local function onCaptureInput(input)
	if not capturingAction or not (window and window.IsOpen()) then
		return
	end
	-- Digitando numa caixa de texto (chat, painel de testes...): não é troca de tecla.
	if UserInputService:GetFocusedTextBox() then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local keyCode = input.KeyCode
	-- Esc: o UIKit fecha a janela, e fechar cancela a troca.
	if keyCode == Enum.KeyCode.Unknown or keyCode == Enum.KeyCode.Escape then
		return
	end
	if RESERVED_KEYS[keyCode] then
		NotifyController.Show(
			("A tecla %s é usada pelo Roblox ou pelo jogo. Escolha outra."):format(keyDisplayName(keyCode)),
			"warning",
			3
		)
		return
	end
	assignKey(capturingAction, keyCode)
end

-- "Restaurar padrão": todas as teclas voltam para as de Config.Keybinds.
local function restoreDefaultKeys()
	if not draft or not isProfileReady() then
		return
	end
	capturingAction = nil
	if hasCustomKeys() then
		draft.Keybinds = {}
		-- Todas as ações contam como mexidas (todas voltam ao padrão no servidor).
		for _, action in ipairs(Keybinds.Actions) do
			dirtyKeys[action.Id] = true
		end
		markChanged()
		NotifyController.Show("As teclas voltaram ao padrão.", "success", 3)
	end
	refreshKeyRows()
end

-------------------------------------------------------------------------------
-- Peças visuais
-------------------------------------------------------------------------------

-- Título de seção com uma linha colorida embaixo.
local function makeSectionHeader(parent, title, color, layoutOrder)
	local bar = UIKit.New("Frame", {
		Name = "Section_" .. title,
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
		Parent = parent,
	})
	UIKit.Label({
		Name = "Title",
		Text = title,
		Title = true,
		TextSize = 24,
		Position = UDim2.fromOffset(6, 0),
		Size = UDim2.new(1, -12, 1, -6),
		Color = UIKit.Lighten(color, 0.2),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = bar,
	})
	local line = UIKit.New("Frame", {
		Name = "Line",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 3),
		BackgroundColor3 = color,
		Parent = bar,
	})
	UIKit.Corner(line, UDim.new(1, 0))
	return bar
end

-- Linha de configuração: nome e descrição à esquerda, controle à direita.
-- Devolve (linha, área do controle, texto da descrição).
local function makeRow(parent, name, description, layoutOrder)
	local row = UIKit.New("Frame", {
		Name = "Row_" .. name,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.1,
		LayoutOrder = layoutOrder,
		Parent = parent,
	})
	UIKit.Corner(row, 14)
	UIKit.Stroke(row, 2, Theme.Stroke)

	UIKit.Label({
		Name = "Name",
		Text = name,
		Title = true,
		TextSize = 20,
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -(CONTROL_WIDTH + 40), 0, 26),
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	local descriptionLabel = UIKit.Label({
		Name = "Description",
		Text = description or "",
		TextSize = 13,
		Position = UDim2.fromOffset(16, 36),
		Size = UDim2.new(1, -(CONTROL_WIDTH + 40), 0, ROW_HEIGHT - 42),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = row,
	})
	local control = UIKit.New("Frame", {
		Name = "Control",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.new(0, CONTROL_WIDTH, 0, 48),
		BackgroundTransparency = 1,
		Parent = row,
	})
	return row, control, descriptionLabel
end

-- Barrinha (slider) com botões - e +. Arrastar funciona com mouse e dedo;
-- no controle, os botões - e + fazem o trabalho.
local function buildSlider(control, item, color)
	local minus = UIKit.Button({
		Name = "Minus",
		Text = "-",
		Color = color,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(STEP_BUTTON_SIZE, STEP_BUTTON_SIZE),
		TextSize = 28,
		Parent = control,
	}, function()
		if draft then
			changeSetting(item.Key, snap(item, draft[item.Key] - item.Step))
		end
	end)

	local valueLabel = UIKit.Label({
		Name = "Value",
		Text = "",
		Title = true,
		TextSize = 22,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.new(0, VALUE_WIDTH, 1, 0),
		TextWrapped = false,
		Parent = control,
	})

	local plus = UIKit.Button({
		Name = "Plus",
		Text = "+",
		Color = color,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -(VALUE_WIDTH + 6), 0.5, 0),
		Size = UDim2.fromOffset(STEP_BUTTON_SIZE, STEP_BUTTON_SIZE),
		TextSize = 28,
		Parent = control,
	}, function()
		if draft then
			changeSetting(item.Key, snap(item, draft[item.Key] + item.Step))
		end
	end)

	-- Área de toque grande (invisível) com a barrinha fina no meio.
	local trackLeft = STEP_BUTTON_SIZE + 14
	local trackRight = STEP_BUTTON_SIZE + VALUE_WIDTH + 6 + 14
	local hitArea = UIKit.New("TextButton", {
		Name = "Track",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(trackLeft, 0),
		Size = UDim2.new(1, -(trackLeft + trackRight), 1, 0),
		Parent = control,
	})
	local bar = UIKit.New("Frame", {
		Name = "Bar",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, 12),
		BackgroundColor3 = Theme.PanelDark,
		Parent = hitArea,
	})
	UIKit.Corner(bar, UDim.new(1, 0))
	UIKit.Stroke(bar, 2, Theme.Stroke)
	local fill = UIKit.New("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = color,
		Parent = bar,
	})
	UIKit.Corner(fill, UDim.new(1, 0))
	local knob = UIKit.New("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(KNOB_SIZE, KNOB_SIZE),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 2,
		Parent = bar,
	})
	UIKit.Corner(knob, UDim.new(1, 0))
	UIKit.Stroke(knob, 3, color)

	-- Converte a posição X do mouse/dedo num valor da barrinha.
	local function setFromX(x)
		local left = bar.AbsolutePosition.X
		local width = bar.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local fraction = math.clamp((x - left) / width, 0, 1)
		changeSetting(item.Key, snap(item, item.Min + fraction * (item.Max - item.Min)))
	end

	-- Começou a arrastar (clique ou toque na barrinha).
	windowTrove:Connect(hitArea.InputBegan, function(input)
		local inputType = input.UserInputType
		if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
			return
		end
		if not isProfileReady() then
			return
		end
		activeDrag = { SetFromX = setFromX, Input = input }
		-- Enquanto arrasta, a lista não rola junto (importante no celular).
		if window then
			window.Content.ScrollingEnabled = false
		end
		setFromX(input.Position.X)
	end)

	controls[item.Key] = {
		Set = function(value)
			value = tonumber(value) or item.Min
			local fraction = math.clamp((value - item.Min) / (item.Max - item.Min), 0, 1)
			fill.Size = UDim2.fromScale(fraction, 1)
			fill.Visible = fraction > 0.001
			knob.Position = UDim2.fromScale(fraction, 0.5)
			valueLabel.Text = formatValue(item, value)
			minus:SetAttribute("Disabled", value <= item.Min + 1e-6)
			plus:SetAttribute("Disabled", value >= item.Max - 1e-6)
		end,
	}
end

-- Interruptor liga/desliga (um botão que troca de cor e texto).
local function buildToggle(control, item)
	local button = UIKit.Button({
		Name = "Toggle",
		Text = "",
		Color = Theme.Success,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(180, 46),
		TextSize = 21,
		Parent = control,
	}, function()
		if draft then
			changeSetting(item.Key, not draft[item.Key])
		end
	end)

	controls[item.Key] = {
		Set = function(value)
			local on = value == true
			button.Text = if on then "✓ Ligado" else "✕ Desligado"
			button.BackgroundColor3 = if on then Theme.Success else Theme.Danger
		end,
	}
end

-- Seção "Teclado": uma linha por ação de Config.Keybinds e o botão "Restaurar padrão".
local function buildKeybindSection(holder, nextOrder)
	local color = Theme.Accent
	makeSectionHeader(holder, "Teclado", color, nextOrder())

	local _, restoreControl = makeRow(
		holder,
		"Trocar teclas",
		"Clique no botão de uma ação e aperte a tecla nova. Se ela já era de outra ação, as duas trocam.",
		nextOrder()
	)
	ui.RestoreButton = UIKit.Button({
		Name = "Restore",
		Text = "Restaurar padrão",
		Color = Theme.Warning,
		TextColor = Theme.TextDark,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(220, 46),
		TextSize = 20,
		Parent = restoreControl,
	}, function(self)
		if self:GetAttribute("Disabled") == true then
			return
		end
		restoreDefaultKeys()
	end)

	for _, action in ipairs(Keybinds.Actions) do
		local _, control, description = makeRow(holder, action.Name, "", nextOrder())
		local button = UIKit.Button({
			Name = "Key",
			Text = "",
			Color = Theme.Accent2,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.fromOffset(220, 46),
			TextSize = 20,
			Parent = control,
		}, function()
			toggleCapture(action.Id)
		end)
		keyRows[action.Id] = { Button = button, Default = description, Action = action }
	end
end

-------------------------------------------------------------------------------
-- Montagem da janela
-------------------------------------------------------------------------------

-- Para de arrastar a barrinha (soltou o mouse/dedo ou fechou a janela).
local function stopDrag()
	if not activeDrag then
		return
	end
	activeDrag = nil
	if window then
		window.Content.ScrollingEnabled = true
	end
end

local function ensureWindow()
	if window then
		return window
	end
	if not draft then
		loadDraft()
	end
	window = UIKit.Window(WINDOW_NAME, "Configurações", WINDOW_SIZE)

	local holder = UIKit.New("Frame", {
		Name = "SettingsContent",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = window.Content,
	})
	UIKit.Padding(holder, { Top = 4, Bottom = 14, Left = 2, Right = 6 })
	UIKit.List(holder, 8)

	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	-- Barra do topo: explicação e status do salvamento.
	local top = UIKit.New("Frame", {
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, 42),
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.1,
		LayoutOrder = nextOrder(),
		Parent = holder,
	})
	UIKit.Corner(top, UDim.new(1, 0))
	UIKit.Stroke(top, 2, UIKit.Darken(Theme.Accent2, 0.3))
	UIKit.Label({
		Name = "Hint",
		Text = "As mudanças são salvas sozinhas.",
		TextSize = 15,
		Position = UDim2.fromOffset(18, 0),
		Size = UDim2.new(0.6, -18, 1, 0),
		Color = Theme.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = top,
	})
	ui.Status = UIKit.Label({
		Name = "Status",
		Text = "",
		Title = true,
		TextSize = 18,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 0),
		Size = UDim2.new(0.4, -18, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = top,
	})

	-- Seções de configurações.
	for _, section in ipairs(SECTIONS) do
		makeSectionHeader(holder, section.Title, section.Color, nextOrder())
		for _, item in ipairs(section.Items) do
			local _, control, descriptionLabel = makeRow(holder, item.Name, describe(item), nextOrder())
			table.insert(descriptionLabels, { Item = item, Label = descriptionLabel })
			if item.Kind == "Slider" then
				buildSlider(control, item, section.Color)
			else
				buildToggle(control, item)
			end
		end
	end

	-- Teclas só fazem sentido com teclado (no celular e no console a seção some).
	if UserInputService.KeyboardEnabled then
		buildKeybindSection(holder, nextOrder)
	end

	-- Capa "Carregando suas configurações...": cobre a lista (mesma posição e tamanho do
	-- Content) até o perfil chegar. É um botão sem texto, para "engolir" cliques e toques.
	local cover = UIKit.New("TextButton", {
		Name = "LoadingCover",
		Text = "",
		AutoButtonColor = false,
		Selectable = false,
		Position = window.Content.Position,
		Size = window.Content.Size,
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.15,
		ZIndex = 5,
		Visible = false,
		Parent = window.Frame,
	})
	UIKit.Corner(cover, 14)
	UIKit.Label({
		Name = "Text",
		Text = "Carregando suas configurações...",
		Title = true,
		TextSize = 24,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -40, 0, 40),
		Color = Theme.Text,
		Parent = cover,
	})
	ui.LoadingCover = cover

	-- O papel do servidor (lobby/partida) pode mudar: atualiza o aviso "(vale na partida)".
	windowTrove:Connect(workspace:GetAttributeChangedSignal("Role"), refreshDescriptions)

	-- Arrastar a barrinha: acompanha o mouse/dedo até soltar.
	windowTrove:Connect(UserInputService.InputChanged, function(input)
		if not activeDrag then
			return
		end
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.MouseMovement then
			if activeDrag.Input.UserInputType == Enum.UserInputType.MouseButton1 then
				activeDrag.SetFromX(input.Position.X)
			end
		elseif inputType == Enum.UserInputType.Touch and input == activeDrag.Input then
			activeDrag.SetFromX(input.Position.X)
		end
	end)
	windowTrove:Connect(UserInputService.InputEnded, function(input)
		if not activeDrag then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input == activeDrag.Input then
			stopDrag()
		end
	end)

	-- Tecla nova para a ação que está esperando.
	windowTrove:Connect(UserInputService.InputBegan, onCaptureInput)

	-- Fechar: para de arrastar, cancela a troca de tecla e salva o que faltar.
	windowTrove:Add(window.OnClose:Connect(function()
		stopDrag()
		capturingAction = nil
		refreshKeyRows()
		flushSave()
	end))

	return window
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

function SettingsWindow.Open()
	ensureWindow()
	-- Mostra o que está salvo no perfil, com as mudanças ainda não confirmadas por cima.
	loadDraft()
	capturingAction = nil
	refreshAllControls()
	window.Content.CanvasPosition = Vector2.zero
	window.Open()
end

function SettingsWindow.Close()
	if window then
		window.Close()
	end
end

function SettingsWindow.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function SettingsWindow.Init()
	-- Botão do HUD, botão do lobby e prompts com ClientAction "Settings".
	local PromptController = getController("PromptController")
	if PromptController and PromptController.Register then
		lifeTrove:Add(PromptController.Register("Settings", function()
			SettingsWindow.Open()
		end))
	else
		warn("[SettingsWindow] PromptController não encontrado; as Configurações não vão abrir pelos botões.")
	end
end

function SettingsWindow.Start()
	loadDraft()

	-- O perfil chegou ou mudou (por exemplo, depois de salvar): o rascunho vira
	-- "o que está salvo" + "o que o jogador mexeu e ainda não foi confirmado".
	-- Assim nada que o jogador mudou se perde, e nada salvo é apagado.
	lifeTrove:Add(StateController.OnChanged("Profile", function()
		loadDraft()
		if window then
			refreshAllControls()
		end
		-- Sobrou mudança sem salvar (e nada agendado): agenda agora que o perfil existe.
		if hasDirty() and not saving and not saveTimer then
			scheduleSave(SAVE_DEBOUNCE)
		end
	end))
end

-- Deixa as funções do módulo funcionarem com "." e também com ":".
for name, fn in pairs(SettingsWindow) do
	if type(fn) == "function" then
		SettingsWindow[name] = function(first, ...)
			if first == SettingsWindow then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return SettingsWindow
