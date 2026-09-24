-- LobbyUI (lobby): toda a interface do lobby.
--
-- O que fica neste módulo:
--   * botões laterais: Criar Partida (vira "Meu Grupo" quando você está num grupo),
--     Partidas Abertas, Loja, Conquistas, Configurações e Reconectar (só aparece quando a
--     sua última partida ainda existe, Profile.CanReconnect);
--   * popup de convite recebido (Entrar / Recusar);
--   * contagem regressiva grande na tela quando o seu grupo vai começar;
--   * tela de carregamento do teleporte (TeleportService:SetTeleportGui) com o nome e a cor do mapa.
-- As janelas grandes ficam em módulos separados, todos com o prefixo "Lobby":
--   LobbyCreate (Criar Partida), LobbyParty (Meu Grupo), LobbyList (Partidas Abertas),
--   LobbyShop (Loja: skins e, se houver game passes à venda, a aba "Vantagens")
--   e LobbyAchievements (Conquistas e Estatísticas).
-- Eles recebem este módulo no Init e usam as funções de ajuda daqui.
--
-- O cliente só PEDE as coisas (Net.Request). Quem decide é o servidor (PartyService,
-- ShopService, LobbyService), que manda o estado dos grupos pelo evento "PartyState":
--   {MyParty = PartyView?, Parties = {PartyView}, Invites = {partyId}}
--   PartyView = {Id, HostUserId, HostName, MapId, MaxPlayers, Privacy, Resume, State,
--                CountdownEnd, Members = {{UserId, Name, DisplayName, Ready}}, CanJoin, JoinBlockReason}
--
-- API usada pelas janelas do lobby:
--   LobbyUI.PartyChanged                     Signal(state, previousState)
--   LobbyUI.GetPartyState() / GetMyParty() / FindParty(id) / IsHost(party?) / GetMember(party, userId)
--   LobbyUI.AreAllReady(party) -> (todosProntos, quantosFaltam)
--   LobbyUI.CountdownSeconds(party) -> segundos que faltam (ou nil sem contagem)
--   LobbyUI.Open(key, arg?) / IsOpen(key) / CloseAll()   key = "Create" | "Party" | "List" | "Shop" | "Achievements"
--                                                       (ex.: LobbyUI.Open("Shop", "Passes") abre a aba Vantagens)
--   LobbyUI.Request(action, ...) -> ok, result          Net.Request que mostra o erro num aviso
--   LobbyUI.JoinParty(partyId) -> ok                    entra num grupo (sai do atual antes, se precisar)
--   LobbyUI.GetProfile(), GetTokens(), IsMapUnlocked(id), IsMapCompleted(id), GetRunSave(id)
--   LobbyUI.GetMapDef/GetMapName/GetMapColor/GetMapRequirement(mapId)
--   LobbyUI.GetPrivacyName/GetPrivacyColor/GetPrivacyHint(privacy), LobbyUI.PrivacyOrder
--   LobbyUI.GetStateText/GetStateColor(state), LobbyUI.FormatDate(unix), LobbyUI.MemberName(member)
--   Visuais: PrepareContent, Section, Row, Tag, SetTag, Avatar, LoadThumbnail, LockIcon,
--            SetSelected, ConfirmButton, SetButtonText, FixSelection, IsUsingGamepad

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local TeleportService = game:GetService("TeleportService")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maps = require(Config:WaitForChild("Maps"))
local LobbyConfig = require(Config:WaitForChild("Lobby"))
local Net = require(Util:WaitForChild("Net"))
local Signal = require(Util:WaitForChild("Signal"))
local Trove = require(Util:WaitForChild("Trove"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))

local UIFolder = script.Parent
local ControllersFolder = UIFolder.Parent:WaitForChild("Controllers")
local UIKit = require(UIFolder:WaitForChild("UIKit"))
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme
local LocalPlayer = Players.LocalPlayer

local LobbyUI = {}

-- Dispara (state, previousState) sempre que chega um PartyState novo do servidor.
LobbyUI.PartyChanged = Signal.new()

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Telas (ScreenGui) e a ordem de desenho delas.
local HUD_SCREEN_NAME = "LobbyHUD"
local HUD_DISPLAY_ORDER = 12 -- acima do mundo, abaixo das janelas (30)
local POPUP_SCREEN_NAME = "LobbyPopup"
local POPUP_DISPLAY_ORDER = 40 -- o convite aparece por cima das janelas, abaixo dos avisos (60)
local LOADING_DISPLAY_ORDER = 100 -- tela de carregamento cobre tudo

-- Botões laterais.
local SIDE_WIDTH = 200
local SIDE_BUTTON_HEIGHT = 50
local SIDE_BUTTON_HEIGHT_TOUCH = 44 -- no celular os botões ficam mais baixos
local SIDE_GAP = 8
local SETTINGS_COLOR = Color3.fromRGB(52, 190, 178) -- verde-água do botão Configurações

-- Tempos (segundos).
local CONFIRM_SECONDS = 3 -- tempo para o segundo clique dos botões "Certeza?"
local INVITE_POPUP_SECONDS = 25 -- quanto tempo o popup de convite fica na tela
local LOADING_CHECK_SECONDS = 25 -- se o teleporte não acontecer nesse tempo, a tela de carregamento some

-- Popup de convite (entra deslizando pela direita).
local INVITE_POPUP_SIZE = UDim2.fromOffset(430, 164)
local POPUP_SHOWN_POSITION = UDim2.new(1, -16, 0.42, 0)
local POPUP_HIDDEN_POSITION = UDim2.new(1, 470, 0.42, 0)

-- Fotos dos jogadores.
local THUMB_TYPE = Enum.ThumbnailType.HeadShot
local THUMB_SIZE = Enum.ThumbnailSize.Size150x150

-- Controle: o direcional esquerdo leva a seleção para os botões laterais.
local GAMEPAD_MENU_ACTION = "LobbyUIGamepadMenu"
local GAMEPAD_MENU_KEY = Enum.KeyCode.DPadLeft

-- Janelas do lobby (módulos irmãos deste).
local SUBMODULES = {
	{ Key = "Create", Module = "LobbyCreate" },
	{ Key = "Party", Module = "LobbyParty" },
	{ Key = "List", Module = "LobbyList" },
	{ Key = "Shop", Module = "LobbyShop" },
	{ Key = "Achievements", Module = "LobbyAchievements" },
}

-- Cor de cada mapa na interface (o Config.Maps não tem cor; isto é só visual).
local MAP_COLORS = {
	Meadow = Color3.fromRGB(104, 204, 88), -- verde do prado
	Winter = Color3.fromRGB(112, 192, 255), -- azul gelo
	Desert = Color3.fromRGB(245, 168, 64), -- laranja areia
}

-- Privacidade: ordem dos botões, cor e explicação.
local PRIVACY_ORDER = { "Public", "Friends", "Invite" }
local PRIVACY_COLORS = {
	Public = Theme.Success,
	Friends = Theme.Info,
	Invite = Theme.Accent2,
}
local PRIVACY_HINTS = {
	Public = "Qualquer jogador do servidor pode ver e entrar no grupo.",
	Friends = "Só os amigos do dono no Roblox (ou convidados) podem entrar.",
	Invite = "Só quem o dono convidar pode ver e entrar no grupo.",
}

-- Estado do grupo: texto e cor.
local STATE_TEXTS = {
	Waiting = "Esperando",
	Countdown = "Começando!",
	Teleporting = "Teleportando",
}
local STATE_COLORS = {
	Waiting = Theme.Info,
	Countdown = Theme.Warning,
	Teleporting = Theme.Accent,
}

-- Dicas mostradas na tela de carregamento.
local LOADING_TIPS = {
	"Dica: brainrots gigantes valem muito mais moedas!",
	"Dica: upgrades de time valem para todo mundo do grupo.",
	"Dica: um brainrot Galáctico vale 50 vezes mais moedas!",
	"Dica: pegue missões na barraca amarela para ganhar moedas extras.",
	"Dica: no Deserto, fique na sombra do oásis para não esquentar.",
	"Dica: se cair da partida, use o botão Reconectar no lobby.",
	"Dica: explosões em cadeia destroem vários brainrots de uma vez!",
}

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local partyState = { MyParty = nil, Parties = {}, Invites = {} }
local modules = {} -- [key] = módulo da janela (LobbyCreate, LobbyParty...)
local busyActions = {} -- [action] = true enquanto o pedido está "no ar"
local thumbCache = {} -- [userId] = imagem pronta
local thumbWaiting = {} -- [userId] = {ImageLabel} esperando a imagem chegar

local hud = nil -- referências dos botões laterais e da contagem
local popup = nil -- referências do popup de convite
local inviteQueue = {} -- convites esperando a vez de aparecer (partyId)
local inviteSeen = {} -- [partyId] = true (já mostrado ou recusado)
local currentInvite = nil -- partyId do convite que está na tela
local inviteSerial = 0 -- muda a cada popup (para cancelar temporizadores velhos)

local loading = { Gui = nil, Serial = 0, Reason = nil } -- tela de carregamento do teleporte
local countdownTrove = Trove.new() -- conexão do relógio da contagem
local countdownActive = false
local lastCountdownSecond = nil
local reconnecting = false

local initialized = false
local started = false

-------------------------------------------------------------------------------
-- Ajudantes gerais
-------------------------------------------------------------------------------

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

-- true se o último tipo de entrada foi um controle (gamepad).
local function isUsingGamepad()
	return string.match(UserInputService:GetLastInputType().Name, "^Gamepad") ~= nil
end

-- true em aparelhos só de toque (celular/tablet sem teclado).
local function isTouchOnly()
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- Tempo compartilhado entre servidor e cliente.
local function serverNow()
	return workspace:GetServerTimeNow()
end

-- Copia as chaves de "extra" para "base" (usado para juntar propriedades).
local function merge(base, extra)
	if type(extra) == "table" then
		for key, value in pairs(extra) do
			base[key] = value
		end
	end
	return base
end

-- Confere se um objeto e todos os pais (até "stopAt") estão visíveis.
local function isShown(gui, stopAt)
	local current = gui
	while current and current ~= stopAt do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		if current:IsA("LayerCollector") and not current.Enabled then
			return false
		end
		current = current.Parent
	end
	return current ~= nil
end

-------------------------------------------------------------------------------
-- Estado dos grupos (PartyState)
-------------------------------------------------------------------------------

-- Confere e arruma um PartyView vindo do servidor (nil se for inválido).
local function normalizeParty(party)
	if type(party) ~= "table" or party.Id == nil then
		return nil
	end
	local members = {}
	if type(party.Members) == "table" then
		for _, member in ipairs(party.Members) do
			if type(member) == "table" and tonumber(member.UserId) then
				table.insert(members, member)
			end
		end
	end
	party.Members = members
	party.MaxPlayers = tonumber(party.MaxPlayers) or LobbyConfig.DefaultMaxPlayers
	return party
end

-- Confere e arruma o PartyStatePayload inteiro.
local function normalizeState(raw)
	local state = { MyParty = nil, Parties = {}, Invites = {} }
	if type(raw) ~= "table" then
		return state
	end
	state.MyParty = normalizeParty(raw.MyParty)
	if type(raw.Parties) == "table" then
		for _, party in ipairs(raw.Parties) do
			local normalized = normalizeParty(party)
			if normalized then
				-- O meu grupo também vem na lista: usamos a mesma tabela nos dois lugares.
				if state.MyParty and normalized.Id == state.MyParty.Id then
					normalized = state.MyParty
				end
				table.insert(state.Parties, normalized)
			end
		end
	end
	if type(raw.Invites) == "table" then
		for _, partyId in ipairs(raw.Invites) do
			if partyId ~= nil then
				table.insert(state.Invites, partyId)
			end
		end
	end
	return state
end

-- Estado atual: {MyParty = PartyView?, Parties = {PartyView}, Invites = {partyId}}.
function LobbyUI.GetPartyState()
	return partyState
end

-- O grupo do jogador local (ou nil).
function LobbyUI.GetMyParty()
	return partyState.MyParty
end

-- Acha um grupo pelo id (no meu grupo ou na lista de grupos visíveis).
function LobbyUI.FindParty(partyId)
	if partyId == nil then
		return nil
	end
	local mine = partyState.MyParty
	if mine and mine.Id == partyId then
		return mine
	end
	for _, party in ipairs(partyState.Parties) do
		if party.Id == partyId then
			return party
		end
	end
	return nil
end

-- true se o jogador local é o dono do grupo (padrão: o grupo dele).
function LobbyUI.IsHost(party)
	party = party or partyState.MyParty
	return type(party) == "table" and tonumber(party.HostUserId) == LocalPlayer.UserId
end

-- Membro do grupo com esse userId (ou nil).
function LobbyUI.GetMember(party, userId)
	if type(party) ~= "table" or type(party.Members) ~= "table" then
		return nil
	end
	userId = tonumber(userId)
	for _, member in ipairs(party.Members) do
		if tonumber(member.UserId) == userId then
			return member
		end
	end
	return nil
end

-- Nome para mostrar de um membro.
function LobbyUI.MemberName(member)
	if type(member) ~= "table" then
		return "Jogador"
	end
	local name = member.DisplayName or member.Name
	if type(name) == "string" and name ~= "" then
		return name
	end
	return "Jogador"
end

-- Todos prontos? (o dono conta como pronto). Devolve (todosProntos, quantosFaltam).
function LobbyUI.AreAllReady(party)
	if type(party) ~= "table" then
		return false, 0
	end
	local hostId = tonumber(party.HostUserId)
	local waiting = 0
	for _, member in ipairs(party.Members) do
		if tonumber(member.UserId) ~= hostId and member.Ready ~= true then
			waiting += 1
		end
	end
	return waiting == 0, waiting
end

-- Segundos que faltam na contagem regressiva do grupo (nil se não há contagem).
function LobbyUI.CountdownSeconds(party)
	if type(party) ~= "table" or party.State ~= "Countdown" or type(party.CountdownEnd) ~= "number" then
		return nil
	end
	return math.max(0, party.CountdownEnd - serverNow())
end

-------------------------------------------------------------------------------
-- Perfil e mapas
-------------------------------------------------------------------------------

-- Visão do perfil (seção 4.3) ou tabela vazia enquanto não chegou.
function LobbyUI.GetProfile()
	local profile = StateController.Get("Profile")
	if type(profile) == "table" then
		return profile
	end
	return {}
end

-- Brainrot Tokens do jogador.
function LobbyUI.GetTokens()
	return math.max(0, math.floor(tonumber(LobbyUI.GetProfile().Tokens) or 0))
end

-- Definição do mapa em Config.Maps (nil se não for um mapa de verdade).
function LobbyUI.GetMapDef(mapId)
	if type(mapId) ~= "string" then
		return nil
	end
	local def = Maps[mapId]
	-- "Order" também é uma chave de Maps; por isso conferimos o campo Act.
	if type(def) == "table" and def.Act ~= nil then
		return def
	end
	return nil
end

function LobbyUI.GetMapName(mapId)
	local def = LobbyUI.GetMapDef(mapId)
	return def and def.DisplayName or tostring(mapId or "?")
end

function LobbyUI.GetMapColor(mapId)
	return MAP_COLORS[mapId] or Theme.Accent
end

-- Texto do que falta para liberar o mapa (ex.: "Termine o Ato 1 (Prado Brainrot)").
function LobbyUI.GetMapRequirement(mapId)
	for _, otherId in ipairs(Maps.Order) do
		local def = LobbyUI.GetMapDef(otherId)
		if def and def.Next == mapId then
			return ("Termine o Ato %d (%s)"):format(def.Act, def.DisplayName)
		end
	end
	return "Mapa trancado"
end

-- O jogador já liberou o mapa?
function LobbyUI.IsMapUnlocked(mapId)
	local unlocked = LobbyUI.GetProfile().UnlockedMaps
	if type(unlocked) == "table" then
		return unlocked[mapId] == true
	end
	-- Perfil ainda não chegou: o template começa só com o primeiro mapa liberado.
	return mapId == Maps.Order[1]
end

-- O jogador já concluiu o mapa?
function LobbyUI.IsMapCompleted(mapId)
	local completed = LobbyUI.GetProfile().CompletedMaps
	return type(completed) == "table" and completed[mapId] == true
end

-- Partida salva do jogador nesse mapa: o os.time() de quando salvou (ou true), ou nil.
function LobbyUI.GetRunSave(mapId)
	local saves = LobbyUI.GetProfile().RunSaves
	if type(saves) == "table" and mapId ~= nil then
		local value = saves[mapId]
		if value then
			return value
		end
	end
	return nil
end

-- Privacidade.
LobbyUI.PrivacyOrder = PRIVACY_ORDER

function LobbyUI.GetPrivacyName(privacy)
	return LobbyConfig.Privacy[privacy] or tostring(privacy or "?")
end

function LobbyUI.GetPrivacyColor(privacy)
	return PRIVACY_COLORS[privacy] or Theme.Accent2
end

function LobbyUI.GetPrivacyHint(privacy)
	return PRIVACY_HINTS[privacy] or ""
end

-- Estado do grupo.
function LobbyUI.GetStateText(state)
	return STATE_TEXTS[state] or tostring(state or "?")
end

function LobbyUI.GetStateColor(state)
	return STATE_COLORS[state] or Theme.Info
end

-- os.time() -> "12/05/2026 14:30" no horário do jogador.
function LobbyUI.FormatDate(unixTime)
	if type(unixTime) ~= "number" then
		return "?"
	end
	local ok, text = pcall(function()
		return DateTime.fromUnixTimestamp(math.floor(unixTime)):FormatLocalTime("DD/MM/YYYY HH:mm", "pt-br")
	end)
	if ok and type(text) == "string" then
		return text
	end
	return "?"
end

-------------------------------------------------------------------------------
-- Pedidos ao servidor
-------------------------------------------------------------------------------

-- Mostra um erro num aviso vermelho (com som).
function LobbyUI.ShowError(message)
	if type(message) ~= "string" or message == "" then
		message = "Não foi possível fazer isso agora."
	end
	NotifyController.Show(message, "error", 3.5)
	UIKit.PlaySound("Error")
end

-- LobbyUI.Request(action, ...) -> ok, result
-- Igual ao Net.Request, mas não deixa repetir a mesma action enquanto a anterior
-- não voltou (clique duplo) e mostra a mensagem de erro do servidor num aviso.
function LobbyUI.Request(action, ...)
	if busyActions[action] then
		return false, nil
	end
	busyActions[action] = true
	local ok, result = Net.Request(action, ...)
	busyActions[action] = nil
	if not ok then
		LobbyUI.ShowError(result)
	end
	return ok, result
end

-- Entra num grupo. Se o jogador já está em outro, sai dele antes (o servidor não
-- deixa estar em dois grupos). Abre a janela "Meu Grupo" quando dá certo.
function LobbyUI.JoinParty(partyId)
	if partyId == nil then
		return false
	end
	local mine = partyState.MyParty
	if mine and mine.Id == partyId then
		LobbyUI.Open("Party")
		return true
	end
	if mine then
		-- Avisa a janela do grupo que a saída foi de propósito (para ela não estranhar).
		local partyModule = modules.Party
		if partyModule and type(partyModule.ExpectLeave) == "function" then
			partyModule.ExpectLeave()
		end
		local left = LobbyUI.Request("PartyLeave")
		if not left then
			return false
		end
	end
	local ok = LobbyUI.Request("PartyJoin", partyId)
	if ok then
		LobbyUI.Open("Party", "Joining")
	end
	return ok
end

-------------------------------------------------------------------------------
-- Fotos dos jogadores
-------------------------------------------------------------------------------

-- Endereço de foto que o Roblox monta sozinho (usado se a busca falhar).
local function fallbackThumbnail(userId)
	return ("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150"):format(userId)
end

-- Coloca a foto do jogador no ImageLabel (busca uma vez e guarda no cache).
function LobbyUI.LoadThumbnail(userId, image)
	userId = tonumber(userId)
	if not userId or typeof(image) ~= "Instance" then
		return
	end
	image:SetAttribute("ThumbUserId", userId)

	local cached = thumbCache[userId]
	if cached then
		image.Image = cached
		return
	end
	image.Image = ""

	-- Já tem uma busca em andamento: só entra na fila.
	local waiting = thumbWaiting[userId]
	if waiting then
		table.insert(waiting, image)
		return
	end
	waiting = { image }
	thumbWaiting[userId] = waiting

	task.spawn(function()
		-- GetUserThumbnailAsync é uma chamada web: sempre dentro de pcall.
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, THUMB_TYPE, THUMB_SIZE)
		end)
		local final = (ok and type(content) == "string" and content ~= "") and content or fallbackThumbnail(userId)
		thumbCache[userId] = final
		thumbWaiting[userId] = nil
		for _, label in ipairs(waiting) do
			-- Só troca se a imagem ainda existe e ainda é deste jogador.
			if label.Parent and label:GetAttribute("ThumbUserId") == userId then
				label.Image = final
			end
		end
	end)
end

-------------------------------------------------------------------------------
-- Ajudantes visuais (usados por todas as janelas do lobby)
-------------------------------------------------------------------------------

function LobbyUI.IsUsingGamepad()
	return isUsingGamepad()
end

-- Prepara o Content de uma janela: lista vertical com espaço entre os blocos.
function LobbyUI.PrepareContent(content, padding)
	local layout = UIKit.List(content, padding or 10)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	UIKit.Padding(content, { Top = 4, Bottom = 12, Left = 4, Right = 4 })
	return layout
end

-- Um "cartão" que cresce com o conteúdo, com título opcional em cima.
function LobbyUI.Section(parent, title, order, props)
	local section = UIKit.New(
		"Frame",
		merge({
			Name = "Section",
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Theme.Panel,
			BackgroundTransparency = 0.1,
			LayoutOrder = order or 0,
		}, props)
	)
	UIKit.Corner(section, 14)
	UIKit.Stroke(section, 2, Theme.PanelDark)
	UIKit.Padding(section, 12)
	local layout = UIKit.List(section, 8)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	if title then
		UIKit.Label({
			Name = "Title",
			Text = title,
			Title = true,
			TextSize = 22,
			Size = UDim2.new(1, 0, 0, 28),
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 0,
			Parent = section,
		})
	end
	section.Parent = parent
	return section
end

-- Uma linha horizontal (para botões lado a lado).
function LobbyUI.Row(parent, height, order, padding, align)
	local row = UIKit.New("Frame", {
		Name = "Row",
		Size = UDim2.new(1, 0, 0, height or 44),
		BackgroundTransparency = 1,
		LayoutOrder = order or 0,
		Parent = parent,
	})
	local layout = UIKit.List(row, padding or 8, "Horizontal")
	layout.HorizontalAlignment = align or Enum.HorizontalAlignment.Left
	return row, layout
end

-- Uma "etiqueta" colorida em forma de pílula (ex.: "Público", "3/4").
-- props: Text, Color, TextColor, Height, TextSize, Position, AnchorPoint, LayoutOrder, Visible, Name, Parent.
function LobbyUI.Tag(props)
	props = props or {}
	local color = typeof(props.Color) == "Color3" and props.Color or Theme.Accent2
	local tag = UIKit.New("TextLabel", {
		Name = props.Name or "Tag",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, props.Height or 24),
		Position = props.Position or UDim2.new(),
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		BackgroundColor3 = color,
		Text = tostring(props.Text or ""),
		Font = Theme.ButtonFont,
		TextSize = props.TextSize or 15,
		TextColor3 = props.TextColor or Theme.Text,
		TextStrokeColor3 = Theme.Stroke,
		TextStrokeTransparency = 0.6,
		LayoutOrder = props.LayoutOrder or 0,
		Visible = props.Visible ~= false,
	})
	UIKit.Corner(tag, UDim.new(1, 0))
	UIKit.Padding(tag, { Top = 0, Bottom = 0, Left = 10, Right = 10 })
	UIKit.Stroke(tag, 1.5, UIKit.Darken(color, 0.45))
	tag.Parent = props.Parent
	return tag
end

-- Troca o texto (e a cor, se passar) de uma etiqueta feita com LobbyUI.Tag.
function LobbyUI.SetTag(tag, text, color)
	tag.Text = tostring(text or "")
	if typeof(color) == "Color3" then
		tag.BackgroundColor3 = color
		local stroke = tag:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = UIKit.Darken(color, 0.45)
		end
	end
end

-- Foto redonda de um jogador. props: Position, AnchorPoint, LayoutOrder, Name.
function LobbyUI.Avatar(parent, userId, size, props)
	size = size or 56
	local image = UIKit.New(
		"ImageLabel",
		merge({
			Name = "Avatar",
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = Theme.PanelDark,
			Image = "",
			ScaleType = Enum.ScaleType.Crop,
		}, props)
	)
	UIKit.Corner(image, UDim.new(1, 0))
	UIKit.Stroke(image, 2.5, Theme.Accent)
	image.Parent = parent
	if userId then
		LobbyUI.LoadThumbnail(userId, image)
	end
	return image
end

-- Desenha um cadeado com Frames (sem imagens). props: Position, AnchorPoint, ZIndex.
function LobbyUI.LockIcon(parent, size, color, props)
	size = size or 32
	color = color or Theme.TextDim
	local holder = UIKit.New(
		"Frame",
		merge({
			Name = "Lock",
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 1,
		}, props)
	)
	-- Alça (um anel; a parte de baixo fica escondida atrás do corpo).
	local shackle = UIKit.New("Frame", {
		Name = "Shackle",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.02),
		Size = UDim2.fromScale(0.56, 0.56),
		BackgroundTransparency = 1,
		ZIndex = holder.ZIndex,
		Parent = holder,
	})
	UIKit.Corner(shackle, UDim.new(1, 0))
	UIKit.Stroke(shackle, math.max(2, size * 0.09), color)
	-- Corpo do cadeado com o buraco da chave.
	local body = UIKit.New("Frame", {
		Name = "Body",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromScale(0.84, 0.58),
		BackgroundColor3 = color,
		ZIndex = holder.ZIndex + 1,
		Parent = holder,
	})
	UIKit.Corner(body, UDim.new(0.22, 0))
	local hole = UIKit.New("Frame", {
		Name = "Hole",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.48),
		Size = UDim2.fromScale(0.16, 0.36),
		BackgroundColor3 = Theme.PanelDark,
		ZIndex = holder.ZIndex + 2,
		Parent = body,
	})
	UIKit.Corner(hole, UDim.new(1, 0))
	holder.Parent = parent
	return holder
end

-- Deixa um botão com cara de "escolhido" (colorido) ou "não escolhido" (apagado).
function LobbyUI.SetSelected(button, selected, color)
	local target = selected and (color or Theme.Accent) or Theme.PanelLight
	if button.BackgroundColor3 ~= target then
		button.BackgroundColor3 = target
	end
	button.TextColor3 = selected and Theme.Text or Theme.TextDim
	local stroke = button:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = selected and 4 or 2.5
	end
end

-- Botão que pede confirmação: o 1º clique troca o texto por "confirmText" e só o
-- 2º clique (em até CONFIRM_SECONDS) roda a ação. needsConfirm() (opcional) diz se
-- precisa confirmar agora; sem ela, sempre precisa.
function LobbyUI.ConfirmButton(props, confirmText, action, needsConfirm)
	local button
	local token = 0

	local function reset()
		button:SetAttribute("ConfirmUntil", nil)
		local normal = button:GetAttribute("NormalText")
		if type(normal) == "string" then
			button.Text = normal
		end
	end

	button = UIKit.Button(props, function()
		local armedUntil = button:GetAttribute("ConfirmUntil")
		local mustConfirm = needsConfirm == nil or needsConfirm() == true
		if not mustConfirm or (type(armedUntil) == "number" and os.clock() < armedUntil) then
			if type(armedUntil) == "number" then
				reset()
			end
			action(button)
			return
		end

		-- Primeiro clique: pede confirmação.
		button:SetAttribute("NormalText", button.Text)
		button:SetAttribute("ConfirmUntil", os.clock() + CONFIRM_SECONDS)
		button.Text = confirmText
		token += 1
		local myToken = token
		task.delay(CONFIRM_SECONDS, function()
			if myToken == token and button.Parent and button:GetAttribute("ConfirmUntil") then
				reset()
			end
		end)
	end)
	return button
end

-- Troca o texto de um botão respeitando o "Certeza?" de um ConfirmButton armado.
function LobbyUI.SetButtonText(button, text)
	if button:GetAttribute("ConfirmUntil") then
		button:SetAttribute("NormalText", text)
	elseif button.Text ~= text then
		button.Text = text
	end
end

-- Desarma um ConfirmButton (volta o texto normal).
function LobbyUI.ResetConfirm(button)
	if button:GetAttribute("ConfirmUntil") then
		button:SetAttribute("ConfirmUntil", nil)
		local normal = button:GetAttribute("NormalText")
		if type(normal) == "string" then
			button.Text = normal
		end
	end
end

-- No controle: se o botão selecionado sumiu (ou não há seleção), seleciona o
-- primeiro botão visível da janela. Chame depois de atualizar a janela.
function LobbyUI.FixSelection(window)
	if not (window and window.IsOpen() and isUsingGamepad()) then
		return
	end
	local selected = GuiService.SelectedObject
	if selected and selected.Parent and selected:IsDescendantOf(window.Gui) and isShown(selected, window.Gui) then
		return
	end

	local best, bestY, bestX = nil, 0, 0
	for _, descendant in ipairs(window.Content:GetDescendants()) do
		if
			descendant:IsA("GuiButton")
			and descendant.Selectable
			and descendant.Active
			and isShown(descendant, window.Gui)
		then
			local position = descendant.AbsolutePosition
			if not best or position.Y < bestY - 1 or (math.abs(position.Y - bestY) <= 1 and position.X < bestX) then
				best, bestY, bestX = descendant, position.Y, position.X
			end
		end
	end
	local target = best or window.CloseButton
	pcall(function()
		GuiService.SelectedObject = target
	end)
end

-------------------------------------------------------------------------------
-- Janelas do lobby
-------------------------------------------------------------------------------

-- Abre uma janela: "Create", "Party", "List", "Shop" ou "Achievements".
function LobbyUI.Open(key, arg)
	local module = modules[key]
	if not module or type(module.Open) ~= "function" then
		warn(("[LobbyUI] A janela '%s' não está disponível."):format(tostring(key)))
		return
	end
	local ok, err = pcall(module.Open, arg)
	if not ok then
		warn(("[LobbyUI] Erro ao abrir a janela '%s': %s"):format(tostring(key), tostring(err)))
	end
end

-- true se a janela está aberta.
function LobbyUI.IsOpen(key)
	local module = modules[key]
	if not module or type(module.IsOpen) ~= "function" then
		return false
	end
	local ok, result = pcall(module.IsOpen)
	return ok and result == true
end

-- Fecha todas as janelas do lobby.
function LobbyUI.CloseAll()
	for _, module in pairs(modules) do
		if type(module.Close) == "function" then
			pcall(module.Close)
		end
	end
end

-- Abre as Configurações (a SettingsWindow registra a ação "Settings").
local function openSettings()
	local PromptController = getController("PromptController")
	if PromptController and PromptController.Dispatch then
		PromptController.Dispatch("Settings")
	else
		NotifyController.Show("As configurações não estão disponíveis agora.", "warning", 3)
	end
end

-------------------------------------------------------------------------------
-- Tela de carregamento do teleporte
-------------------------------------------------------------------------------

-- Monta a tela de carregamento. Ela vai para o TeleportService (que mostra durante
-- o teleporte), por isso usa tamanhos em escala (sem o UIScale do UIKit).
local function buildLoadingGui(mapId)
	local def = LobbyUI.GetMapDef(mapId)
	local color = LobbyUI.GetMapColor(mapId)

	local gui = Instance.new("ScreenGui")
	gui.Name = "BrainrotTeleportLoading"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = LOADING_DISPLAY_ORDER
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Fundo em degradê na cor do mapa.
	local background = UIKit.New("Frame", {
		Name = "Background",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Active = true,
		Parent = gui,
	})
	UIKit.New("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(UIKit.Darken(color, 0.2), UIKit.Darken(Theme.Background, 0.25)),
		Parent = background,
	})

	-- Faixas diagonais de "doce" para enfeitar.
	for index = 1, 7 do
		UIKit.New("Frame", {
			Name = "Stripe",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale((index - 1) / 6, 0.5),
			Size = UDim2.new(0.05, 0, 2, 0),
			Rotation = 24,
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.92,
			Parent = background,
		})
	end

	local center = UIKit.New("Frame", {
		Name = "Center",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.47),
		Size = UDim2.fromScale(0.84, 0.66),
		BackgroundTransparency = 1,
		Parent = background,
	})
	local layout = UIKit.List(center, UDim.new(0.02, 0))
	layout.VerticalAlignment = Enum.VerticalAlignment.Center

	-- Texto que se ajusta ao tamanho da tela (com tamanho máximo).
	local function text(name, value, heightScale, font, textColor, maxSize, order)
		local label = UIKit.New("TextLabel", {
			Name = name,
			Size = UDim2.fromScale(1, heightScale),
			BackgroundTransparency = 1,
			Text = value,
			Font = font,
			TextScaled = true,
			TextColor3 = textColor,
			LayoutOrder = order,
			Parent = center,
		})
		UIKit.New("UITextSizeConstraint", { MaxTextSize = maxSize, MinTextSize = 10, Parent = label })
		UIKit.Stroke(label, 3, Theme.Stroke)
		return label
	end

	text("Going", "Indo para...", 0.08, Theme.Font, Theme.TextDim, 30, 1)
	text("MapName", def and def.DisplayName or "a partida", 0.2, Theme.TitleFont, Theme.Text, 96, 2)
	if def then
		text("Act", ("Ato %d"):format(def.Act), 0.08, Theme.TitleFont, UIKit.Lighten(color, 0.35), 34, 3)
	end

	-- Barrinha de carregamento (o pedaço colorido vai e volta).
	local bar = UIKit.New("Frame", {
		Name = "Bar",
		Size = UDim2.fromScale(0.5, 0.045),
		BackgroundColor3 = Theme.PanelDark,
		ClipsDescendants = true,
		LayoutOrder = 4,
		Parent = center,
	})
	UIKit.Corner(bar, UDim.new(1, 0))
	UIKit.Stroke(bar, 3, Theme.Stroke)
	local fill = UIKit.New("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0.35, 1),
		BackgroundColor3 = color,
		Parent = bar,
	})
	UIKit.Corner(fill, UDim.new(1, 0))

	local status = text("Status", "Carregando", 0.07, Theme.Font, Theme.Text, 26, 5)
	text("Tip", LOADING_TIPS[math.random(1, #LOADING_TIPS)], 0.07, Theme.Font, Theme.TextDim, 22, 6)

	return gui, fill, status
end

-- Esconde a tela de carregamento (o teleporte falhou ou foi cancelado).
local function hideLoading()
	if loading.Gui then
		loading.Gui:Destroy()
		loading.Gui = nil
	end
	loading.Reason = nil
	loading.Serial += 1
end

-- Confere, depois de um tempo, se o teleporte aconteceu. Se não, some a tela.
local refreshSideMenu -- declarada mais abaixo
local refreshCountdown -- declarada mais abaixo
local function scheduleLoadingCheck(serial)
	task.delay(LOADING_CHECK_SECONDS, function()
		if loading.Serial ~= serial or not loading.Gui then
			return
		end
		local mine = partyState.MyParty
		if loading.Reason == "Party" and mine and mine.State == "Teleporting" then
			-- O servidor ainda está tentando: espera mais um pouco.
			scheduleLoadingCheck(serial)
			return
		end
		hideLoading()
		refreshSideMenu()
		NotifyController.Show("O teleporte não aconteceu. Tente de novo!", "warning", 4)
	end)
end

-- Mostra a tela de carregamento e entrega ela ao TeleportService.
-- reason = "Party" (o grupo vai para a partida) ou "Reconnect".
local function showLoading(mapId, reason)
	hideLoading()
	loading.Serial += 1
	local serial = loading.Serial

	local gui, fill, status = buildLoadingGui(mapId)
	loading.Gui = gui
	loading.Reason = reason

	-- Fecha as janelas e o convite: a partida vai começar.
	LobbyUI.CloseAll()
	if popup and popup.Frame.Visible then
		popup.Frame.Visible = false
		currentInvite = nil
		inviteSerial += 1
	end

	-- A tela aparece durante o teleporte (e já aparece aqui, na hora).
	local ok, err = pcall(function()
		TeleportService:SetTeleportGui(gui)
	end)
	if not ok then
		warn("[LobbyUI] SetTeleportGui falhou: " .. tostring(err))
	end
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

	-- Animações enquanto ainda estamos no lobby.
	UIKit.Tween(
		fill,
		{ Position = UDim2.fromScale(0.65, 0) },
		TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	)
	task.spawn(function()
		local dots = 0
		while loading.Serial == serial and gui.Parent do
			dots = dots % 3 + 1
			status.Text = "Carregando" .. string.rep(".", dots)
			task.wait(0.4)
		end
	end)

	if refreshSideMenu then
		refreshSideMenu()
	end
	if refreshCountdown then
		refreshCountdown()
	end
	scheduleLoadingCheck(serial)
end

-------------------------------------------------------------------------------
-- Botões laterais
-------------------------------------------------------------------------------

-- Bolinha vermelha com um número no canto do botão.
local function addBadge(button)
	local badge = UIKit.New("TextLabel", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		-- O botão tem espaço interno (UIPadding de 10 px), por isso o +6.
		Position = UDim2.new(1, 6, 0, 0),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = Theme.Danger,
		Text = "0",
		Font = Theme.ButtonFont,
		TextSize = 15,
		TextColor3 = Theme.Text,
		Visible = false,
		ZIndex = 3,
		Parent = button,
	})
	UIKit.Corner(badge, UDim.new(1, 0))
	UIKit.Stroke(badge, 2, Theme.Stroke)
	return badge
end

-- Botão "Reconectar": volta para a última partida (LobbyService / TravelService).
local function reconnect()
	if reconnecting or loading.Gui then
		return
	end
	local profile = LobbyUI.GetProfile()
	if profile.CanReconnect ~= true then
		NotifyController.Show("Não há nenhuma partida para voltar.", "warning", 3)
		return
	end
	reconnecting = true
	refreshSideMenu()
	showLoading(profile.LastMatchMap, "Reconnect")
	local ok = LobbyUI.Request("Reconnect")
	reconnecting = false
	if not ok then
		hideLoading()
	end
	refreshSideMenu()
end

-- Monta os botões da esquerda.
local function buildSideMenu(screen)
	local touch = isTouchOnly()
	local buttonHeight = touch and SIDE_BUTTON_HEIGHT_TOUCH or SIDE_BUTTON_HEIGHT

	local menu = UIKit.New("Frame", {
		Name = "SideMenu",
		-- No celular fica mais para cima, longe do analógico da tela.
		AnchorPoint = touch and Vector2.new(0, 0) or Vector2.new(0, 0.5),
		Position = touch and UDim2.fromOffset(12, 64) or UDim2.new(0, 14, 0.5, 0),
		Size = UDim2.fromOffset(SIDE_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = screen,
	})
	local layout = UIKit.List(menu, SIDE_GAP)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	-- Contador de Brainrot Tokens.
	local tokens = UIKit.New("Frame", {
		Name = "Tokens",
		Size = UDim2.fromOffset(SIDE_WIDTH, 40),
		BackgroundColor3 = Theme.PanelDark,
		BackgroundTransparency = 0.1,
		LayoutOrder = 1,
		Parent = menu,
	})
	UIKit.Corner(tokens, UDim.new(1, 0))
	UIKit.Stroke(tokens, 2.5, Theme.Rare)
	local coin = UIKit.New("TextLabel", {
		Name = "Coin",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 6, 0.5, 0),
		Size = UDim2.fromOffset(30, 30),
		BackgroundColor3 = Theme.Rare,
		Text = "T",
		Font = Theme.TitleFont,
		TextSize = 18,
		TextColor3 = Theme.TextDark,
		Parent = tokens,
	})
	UIKit.Corner(coin, UDim.new(1, 0))
	UIKit.Stroke(coin, 2, UIKit.Darken(Theme.Rare, 0.4))
	local tokensLabel = UIKit.New("TextLabel", {
		Name = "Amount",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(44, 0),
		Size = UDim2.new(1, -52, 1, 0),
		Font = Theme.TitleFont,
		TextSize = 20,
		TextColor3 = Theme.Rare,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "0 Tokens",
		Parent = tokens,
	})
	UIKit.Stroke(tokensLabel, 1.5, Theme.Stroke)

	local function sideButton(order, name, text, color, onClick)
		return UIKit.Button({
			Name = name,
			Text = text,
			Color = color,
			Size = UDim2.fromOffset(SIDE_WIDTH, buttonHeight),
			LayoutOrder = order,
			TextSize = 22,
			Parent = menu,
		}, onClick)
	end

	local createButton = sideButton(2, "CreateParty", "Criar Partida", Theme.Accent, function()
		LobbyUI.Open("Create")
	end)
	local listButton = sideButton(3, "PartyList", "Partidas Abertas", Theme.Accent2, function()
		LobbyUI.Open("List")
	end)
	local listBadge = addBadge(listButton)
	sideButton(4, "Shop", "Loja", Theme.Warning, function()
		LobbyUI.Open("Shop")
	end)
	sideButton(5, "Achievements", "Conquistas", Theme.Info, function()
		LobbyUI.Open("Achievements")
	end)
	sideButton(6, "Settings", "Configurações", SETTINGS_COLOR, openSettings)

	-- "Reconectar" com um brilho pulsando atrás (chama a atenção).
	local reconnectHolder = UIKit.New("Frame", {
		Name = "ReconnectHolder",
		Size = UDim2.fromOffset(SIDE_WIDTH, buttonHeight),
		BackgroundTransparency = 1,
		LayoutOrder = 7,
		Visible = false,
		Parent = menu,
	})
	local glow = UIKit.New("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 6, 1, 6),
		BackgroundColor3 = Theme.Success,
		BackgroundTransparency = 0.45,
		ZIndex = 1,
		Parent = reconnectHolder,
	})
	UIKit.Corner(glow, 16)
	UIKit.Tween(
		glow,
		{ BackgroundTransparency = 0.9, Size = UDim2.new(1, 18, 1, 18) },
		TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	)
	local reconnectButton = UIKit.Button({
		Name = "Reconnect",
		Text = "Reconectar",
		Color = Theme.Success,
		Size = UDim2.fromScale(1, 1),
		TextSize = 20,
		ZIndex = 2,
		Parent = reconnectHolder,
	}, reconnect)

	-- Dica para quem joga no controle.
	local gamepadHint = UIKit.Label({
		Name = "GamepadHint",
		Text = "Direcional esquerdo: menu",
		TextSize = 14,
		Color = Theme.TextDim,
		Size = UDim2.fromOffset(SIDE_WIDTH, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 8,
		Visible = false,
		Parent = menu,
	})

	return {
		Menu = menu,
		TokensLabel = tokensLabel,
		CreateButton = createButton,
		ListButton = listButton,
		ListBadge = listBadge,
		ReconnectHolder = reconnectHolder,
		ReconnectButton = reconnectButton,
		GamepadHint = gamepadHint,
	}
end

-- Atualiza tokens, "Criar/Meu Grupo", contador de grupos e o "Reconectar".
refreshSideMenu = function()
	if not hud then
		return
	end
	local profile = LobbyUI.GetProfile()
	local tokens = LobbyUI.GetTokens()
	hud.TokensLabel.Text = NumberFormat.Commas(tokens) .. (tokens == 1 and " Token" or " Tokens")

	local mine = partyState.MyParty
	if mine then
		hud.CreateButton.Text = "Meu Grupo"
		hud.CreateButton.BackgroundColor3 = Theme.Success
	else
		hud.CreateButton.Text = "Criar Partida"
		hud.CreateButton.BackgroundColor3 = Theme.Accent
	end

	-- Quantos grupos (fora o meu) dá para entrar agora.
	local joinable = 0
	for _, party in ipairs(partyState.Parties) do
		if party.CanJoin == true and not (mine and mine.Id == party.Id) then
			joinable += 1
		end
	end
	hud.ListBadge.Visible = joinable > 0
	hud.ListBadge.Text = joinable > 9 and "9+" or tostring(joinable)

	local canReconnect = profile.CanReconnect == true
	hud.ReconnectHolder.Visible = canReconnect
	if canReconnect then
		local mapDef = LobbyUI.GetMapDef(profile.LastMatchMap)
		if reconnecting then
			hud.ReconnectButton.Text = "Reconectando..."
		elseif mapDef then
			hud.ReconnectButton.Text = "Reconectar: " .. mapDef.DisplayName
		else
			hud.ReconnectButton.Text = "Reconectar"
		end
	end

	-- Durante o teleporte o menu some.
	hud.Menu.Visible = loading.Gui == nil
end

-- Mostra a dica do controle só para quem está usando controle.
local function refreshGamepadHint()
	if hud then
		hud.GamepadHint.Visible = isUsingGamepad()
	end
end

-- Direcional esquerdo: leva a seleção do controle para os botões laterais (ou tira).
local function onGamepadMenu(_, inputState)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not hud or not hud.Menu.Visible or UIKit.IsAnyModalOpen() then
		return Enum.ContextActionResult.Pass
	end
	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(hud.Menu) then
		GuiService.SelectedObject = nil
	else
		GuiService.SelectedObject = hud.CreateButton
	end
	return Enum.ContextActionResult.Sink
end

-------------------------------------------------------------------------------
-- Contagem regressiva grande na tela
-------------------------------------------------------------------------------

local function buildCountdown(screen)
	local frame = UIKit.New("Frame", {
		Name = "Countdown",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.14, 0),
		Size = UDim2.fromOffset(380, 232),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = screen,
	})
	UIKit.Label({
		Name = "Title",
		Text = "A partida começa em",
		Title = true,
		TextSize = 28,
		Size = UDim2.new(1, 0, 0, 34),
		Parent = frame,
	})
	local number = UIKit.New("TextLabel", {
		Name = "Number",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 120),
		Font = Theme.TitleFont,
		TextSize = 120,
		Text = "",
		TextColor3 = Theme.Rare,
		Parent = frame,
	})
	UIKit.Stroke(number, 5, Theme.Stroke)
	local mapLabel = UIKit.Label({
		Name = "Map",
		Text = "",
		TextSize = 20,
		Position = UDim2.fromOffset(0, 156),
		Size = UDim2.new(1, 0, 0, 26),
		Parent = frame,
	})
	-- Só o dono vê o "Cancelar".
	local cancel = UIKit.Button({
		Name = "Cancel",
		Text = "Cancelar",
		Color = Theme.Danger,
		Size = UDim2.fromOffset(170, 42),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 188),
		TextSize = 20,
		Visible = false,
		Parent = frame,
	}, function()
		LobbyUI.Request("PartyCancelCountdown")
	end)
	return { Frame = frame, Number = number, Map = mapLabel, Cancel = cancel }
end

-- Roda a cada quadro durante a contagem: número grande + "tique" a cada segundo.
local function updateCountdownDisplay()
	if not hud then
		return
	end
	local party = partyState.MyParty
	local remaining = LobbyUI.CountdownSeconds(party)
	if not remaining then
		return
	end
	local overlay = hud.Countdown
	-- A janela "Meu Grupo" já tem a contagem dela; aqui só aparece com ela fechada.
	overlay.Frame.Visible = loading.Gui == nil and not LobbyUI.IsOpen("Party")

	local seconds = math.ceil(remaining)
	if seconds ~= lastCountdownSecond then
		lastCountdownSecond = seconds
		overlay.Number.Text = seconds > 0 and tostring(seconds) or "Já!"
		if overlay.Frame.Visible then
			UIKit.Pop(overlay.Number, 0.25)
		end
		if seconds > 0 then
			UIKit.PlaySound("Click", { PlaybackSpeed = 1.25 })
		end
	end
end

-- Liga/desliga o relógio da contagem conforme o estado do meu grupo.
refreshCountdown = function()
	if not hud then
		return
	end
	local party = partyState.MyParty
	local active = LobbyUI.CountdownSeconds(party) ~= nil
	if active then
		hud.Countdown.Map.Text = LobbyUI.GetMapName(party.MapId)
		hud.Countdown.Cancel.Visible = LobbyUI.IsHost(party)
		if not countdownActive then
			countdownActive = true
			lastCountdownSecond = nil
			countdownTrove:Connect(RunService.Heartbeat, updateCountdownDisplay)
		end
		updateCountdownDisplay()
	elseif countdownActive then
		countdownActive = false
		countdownTrove:Clean()
		hud.Countdown.Frame.Visible = false
	end
end

-------------------------------------------------------------------------------
-- Popup de convite
-------------------------------------------------------------------------------

local showNextInvite -- declarada mais abaixo

-- Some com o popup (deslizando para fora).
local function hideInvitePopup()
	currentInvite = nil
	inviteSerial += 1
	if not popup then
		return
	end
	local frame = popup.Frame
	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(frame) then
		GuiService.SelectedObject = nil
	end
	local serial = inviteSerial
	local tween = UIKit.Tween(frame, { Position = POPUP_HIDDEN_POSITION }, 0.25)
	tween.Completed:Connect(function()
		if serial == inviteSerial and currentInvite == nil then
			frame.Visible = false
		end
	end)
end

-- "Entrar": entra no grupo que convidou (saindo do atual, se precisar).
local function acceptInvite()
	local partyId = currentInvite
	if partyId == nil then
		return
	end
	hideInvitePopup()
	LobbyUI.JoinParty(partyId)
	task.delay(0.4, showNextInvite)
end

-- "Recusar": só esconde (o convite some do servidor quando o grupo acaba).
local function declineInvite()
	if currentInvite == nil then
		return
	end
	hideInvitePopup()
	task.delay(0.4, showNextInvite)
end

local function buildPopup()
	local screen = UIKit.GetScreen(POPUP_SCREEN_NAME, POPUP_DISPLAY_ORDER)
	local frame = UIKit.New("Frame", {
		Name = "InvitePopup",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = POPUP_HIDDEN_POSITION,
		Size = INVITE_POPUP_SIZE,
		BackgroundColor3 = Color3.new(1, 1, 1),
		Active = true,
		Visible = false,
		Parent = screen,
	})
	UIKit.Corner(frame, 18)
	UIKit.New("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.PanelLight, Theme.PanelDark),
		Parent = frame,
	})
	local stroke = UIKit.Stroke(frame, 3.5, Color3.new(1, 1, 1))
	UIKit.New("UIGradient", { Rotation = 45, Color = ColorSequence.new(Theme.Accent, Theme.Rare), Parent = stroke })

	local avatar = LobbyUI.Avatar(frame, nil, 64, { Position = UDim2.fromOffset(14, 14) })
	UIKit.Label({
		Name = "Title",
		Text = "Convite para jogar!",
		Title = true,
		TextSize = 24,
		Color = Theme.Rare,
		Position = UDim2.fromOffset(90, 12),
		Size = UDim2.new(1, -104, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	local body = UIKit.Label({
		Name = "Body",
		Text = "",
		TextSize = 16,
		Position = UDim2.fromOffset(90, 44),
		Size = UDim2.new(1, -104, 0, 44),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})
	-- Se eu já estou em outro grupo, "Entrar" pede confirmação (vou sair do meu).
	local accept = LobbyUI.ConfirmButton({
		Name = "Accept",
		Text = "Entrar",
		Color = Theme.Success,
		Size = UDim2.fromOffset(190, 46),
		Position = UDim2.fromOffset(14, 96),
		TextSize = 22,
		Parent = frame,
	}, "Trocar de grupo?", acceptInvite, function()
		local mine = partyState.MyParty
		return mine ~= nil and mine.Id ~= currentInvite
	end)
	UIKit.Button({
		Name = "Decline",
		Text = "Recusar",
		Color = Theme.Danger,
		Size = UDim2.fromOffset(190, 46),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 96),
		TextSize = 22,
		Parent = frame,
	}, declineInvite)
	local timer = UIKit.ProgressBar(frame, {
		Name = "Timer",
		Size = UDim2.new(1, -28, 0, 8),
		Position = UDim2.new(0, 14, 1, -14),
		Color = Theme.Rare,
	})

	popup = { Frame = frame, Avatar = avatar, Body = body, Accept = accept, Timer = timer }
end

-- Mostra o próximo convite da fila (um de cada vez).
showNextInvite = function()
	if not popup or currentInvite ~= nil or loading.Gui then
		return
	end
	local mine = partyState.MyParty
	local partyId = table.remove(inviteQueue, 1)
	-- Pula convites do grupo em que eu já estou.
	while partyId ~= nil and mine and mine.Id == partyId do
		partyId = table.remove(inviteQueue, 1)
	end
	if partyId == nil then
		return
	end

	currentInvite = partyId
	inviteSerial += 1
	local serial = inviteSerial

	local party = LobbyUI.FindParty(partyId)
	if party then
		local hostName = type(party.HostName) == "string" and party.HostName or "Alguém"
		popup.Body.Text = ("%s chamou você para jogar no %s (%d/%d jogadores)."):format(
			hostName,
			LobbyUI.GetMapName(party.MapId),
			#party.Members,
			party.MaxPlayers
		)
		LobbyUI.LoadThumbnail(party.HostUserId, popup.Avatar)
	else
		popup.Body.Text = "Você recebeu um convite para entrar num grupo!"
		popup.Avatar.Image = ""
	end
	LobbyUI.ResetConfirm(popup.Accept)

	-- Entra deslizando e toca o som de aviso.
	local frame = popup.Frame
	frame.Position = POPUP_HIDDEN_POSITION
	frame.Visible = true
	UIKit.Tween(frame, { Position = POPUP_SHOWN_POSITION }, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
	UIKit.PlaySound("Notify")

	-- Barrinha do tempo que o convite fica na tela.
	popup.Timer.Set(1, nil, true)
	UIKit.Tween(
		popup.Timer.Fill,
		{ Size = UDim2.fromScale(0, 1) },
		TweenInfo.new(INVITE_POPUP_SECONDS, Enum.EasingStyle.Linear)
	)
	task.delay(INVITE_POPUP_SECONDS, function()
		if inviteSerial == serial and currentInvite == partyId then
			hideInvitePopup()
			task.delay(0.4, showNextInvite)
		end
	end)

	-- No controle, já seleciona o "Entrar" (se nada mais estiver selecionado).
	if isUsingGamepad() and not UIKit.IsAnyModalOpen() and GuiService.SelectedObject == nil then
		pcall(function()
			GuiService.SelectedObject = popup.Accept
		end)
	end
end

-- Confere a lista de convites do PartyState e coloca os novos na fila.
local function handleInvites()
	local current = {}
	local mine = partyState.MyParty
	for _, partyId in ipairs(partyState.Invites) do
		current[partyId] = true
		if not inviteSeen[partyId] then
			inviteSeen[partyId] = true
			if not (mine and mine.Id == partyId) then
				table.insert(inviteQueue, partyId)
			end
		end
	end

	-- Convites que não existem mais saem da fila (e podem voltar se o dono convidar de novo).
	for index = #inviteQueue, 1, -1 do
		if not current[inviteQueue[index]] then
			table.remove(inviteQueue, index)
		end
	end
	for partyId in pairs(inviteSeen) do
		if not current[partyId] then
			inviteSeen[partyId] = nil
		end
	end

	-- O convite da tela não vale mais (grupo sumiu ou já entrei nele).
	if currentInvite ~= nil and (not current[currentInvite] or (mine and mine.Id == currentInvite)) then
		hideInvitePopup()
	end
	showNextInvite()
end

-------------------------------------------------------------------------------
-- Chegada do PartyState
-------------------------------------------------------------------------------

local function onPartyState(raw)
	local previous = partyState
	partyState = normalizeState(raw)
	local oldParty, newParty = previous.MyParty, partyState.MyParty

	-- O meu grupo está sendo teleportado: tela de carregamento com o mapa.
	if newParty and newParty.State == "Teleporting" then
		if not (loading.Gui and loading.Reason == "Party") then
			showLoading(newParty.MapId, "Party")
		end
	elseif newParty and loading.Gui and loading.Reason == "Party" then
		-- O teleporte falhou e o grupo voltou a esperar: some a tela.
		hideLoading()
	end
	-- (Sem grupo durante o teleporte: a checagem com tempo cuida disso.)

	-- Som quando a contagem do meu grupo começa.
	if
		newParty
		and newParty.State == "Countdown"
		and not (oldParty and oldParty.Id == newParty.Id and oldParty.State == "Countdown")
	then
		UIKit.PlaySound("Notify")
	end

	handleInvites()
	refreshSideMenu()
	refreshCountdown()
	LobbyUI.PartyChanged:Fire(partyState, previous)
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

-- Carrega as janelas do lobby (require dentro de função: regra anti-require-circular).
local function loadSubmodules()
	for _, entry in ipairs(SUBMODULES) do
		local moduleScript = UIFolder:FindFirstChild(entry.Module) or UIFolder:WaitForChild(entry.Module, 5)
		if moduleScript then
			local ok, result = pcall(require, moduleScript)
			if ok and type(result) == "table" then
				modules[entry.Key] = result
			else
				warn(("[LobbyUI] Erro ao carregar %s: %s"):format(entry.Module, tostring(result)))
			end
		else
			warn(("[LobbyUI] Módulo %s não encontrado."):format(entry.Module))
		end
	end
end

-- Chama Init/Start de cada janela, protegido (uma janela quebrada não derruba as outras).
local function runSubmodules(methodName)
	for _, entry in ipairs(SUBMODULES) do
		local module = modules[entry.Key]
		local fn = module and module[methodName]
		if type(fn) == "function" then
			local ok, err = pcall(fn, LobbyUI)
			if not ok then
				warn(("[LobbyUI] Erro em %s.%s(): %s"):format(entry.Module, methodName, tostring(err)))
			end
		end
	end
end

-- Liga os prompts do mundo do lobby às janelas.
local function registerPrompts()
	local PromptController = getController("PromptController")
	if not (PromptController and PromptController.Register) then
		warn("[LobbyUI] PromptController não encontrado; os prompts do lobby não vão abrir janelas.")
		return
	end
	PromptController.Register("CreateParty", function()
		-- Quem já está num grupo abre o "Meu Grupo" (o LobbyCreate cuida disso).
		LobbyUI.Open("Create")
	end)
	PromptController.Register("PartyList", function()
		LobbyUI.Open("List")
	end)
	PromptController.Register("Shop", function()
		LobbyUI.Open("Shop")
	end)
	PromptController.Register("Achievements", function()
		LobbyUI.Open("Achievements")
	end)
end

function LobbyUI.Init()
	if initialized then
		return
	end
	initialized = true

	-- Estado dos grupos (o servidor manda sempre que algo muda).
	Net.On("PartyState", onPartyState)

	loadSubmodules()
	runSubmodules("Init")
	registerPrompts()
end

function LobbyUI.Start()
	if started then
		return
	end
	started = true

	-- Monta a tela do lobby: botões laterais, contagem e popup de convite.
	local screen = UIKit.GetScreen(HUD_SCREEN_NAME, HUD_DISPLAY_ORDER)
	hud = buildSideMenu(screen)
	hud.Countdown = buildCountdown(screen)
	buildPopup()

	runSubmodules("Start")

	StateController.OnChanged("Profile", function()
		refreshSideMenu()
	end)
	UserInputService.LastInputTypeChanged:Connect(refreshGamepadHint)
	ContextActionService:BindAction(GAMEPAD_MENU_ACTION, onGamepadMenu, false, GAMEPAD_MENU_KEY)

	refreshSideMenu()
	refreshCountdown()
	refreshGamepadHint()
	showNextInvite()

	-- Lembra o jogador que a última partida ainda existe.
	if LobbyUI.GetProfile().CanReconnect == true then
		NotifyController.Show("Sua última partida ainda está rolando! Use o botão Reconectar para voltar.", "info", 6)
	end
end

-- Deixa as funções do módulo funcionarem com "." e também com ":"
-- (ex.: LobbyUI.Algo(x) e LobbyUI:Algo(x) fazem a mesma coisa).
for name, fn in pairs(LobbyUI) do
	if type(fn) == "function" then
		LobbyUI[name] = function(first, ...)
			if first == LobbyUI then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return LobbyUI
