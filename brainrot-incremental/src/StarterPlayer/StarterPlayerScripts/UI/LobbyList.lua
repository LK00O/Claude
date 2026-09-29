-- LobbyList (lobby): a janela "Partidas Abertas".
--
-- Lista os grupos que o jogador pode ver (PartyState.Parties): públicos, "Só amigos" de
-- donos amigos dele e grupos para os quais ele foi convidado. Cada linha mostra a foto e o
-- nome do dono, o mapa, a privacidade, as vagas e o estado, com o botão "Entrar" ou o
-- motivo de não poder entrar (JoinBlockReason, calculado pelo servidor).
-- O grupo do próprio jogador aparece primeiro, com o botão "Abrir".
-- Atualiza sozinha a cada PartyState. As linhas são reaproveitadas (não recriadas),
-- para a seleção do controle não "pular".
--
-- Aberta pelo LobbyUI (botão lateral e prompt "PartyList"). Recebe o LobbyUI no Init.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Trove = require(Util:WaitForChild("Trove"))

local UIFolder = script.Parent
local ControllersFolder = UIFolder.Parent:WaitForChild("Controllers")
local UIKit = require(UIFolder:WaitForChild("UIKit"))
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme

local LobbyList = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

local WINDOW_NAME = "LobbyList"
local WINDOW_SIZE = UDim2.fromOffset(780, 580)
local ROW_HEIGHT = 92
local RIGHT_AREA_WIDTH = 190 -- largura da área do botão / motivo

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local Lobby = nil -- o módulo LobbyUI (recebido no Init)
local window = nil
local ui = nil
local listenTrove = Trove.new()
local rows = {} -- [partyId] = linha

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Pega o LobbyUI mesmo se o Init não tiver recebido (require dentro de função).
local function getLobby()
	if Lobby == nil then
		local module = UIFolder:FindFirstChild("LobbyUI")
		if module then
			local ok, result = pcall(require, module)
			if ok and type(result) == "table" then
				Lobby = result
			end
		end
	end
	return Lobby
end

-- Lista na ordem de exibição: meu grupo, depois os que dá para entrar, depois o resto.
local function sortedParties()
	local state = Lobby.GetPartyState()
	local mine = state.MyParty
	local list = {}
	local foundMine = false
	for index, party in ipairs(state.Parties) do
		local isMine = mine ~= nil and party.Id == mine.Id
		foundMine = foundMine or isMine
		table.insert(list, { Party = party, IsMine = isMine, Index = index })
	end
	-- Meu grupo sempre aparece (mesmo que o servidor não mande na lista).
	if mine and not foundMine then
		table.insert(list, { Party = mine, IsMine = true, Index = 0 })
	end

	local function rank(entry)
		if entry.IsMine then
			return 0
		elseif entry.Party.CanJoin == true then
			return 1
		end
		return 2
	end
	table.sort(list, function(a, b)
		local rankA, rankB = rank(a), rank(b)
		if rankA ~= rankB then
			return rankA < rankB
		end
		return a.Index < b.Index
	end)
	return list
end

-------------------------------------------------------------------------------
-- Ações
-------------------------------------------------------------------------------

local function onRowButton(partyId)
	local mine = Lobby.GetMyParty()
	if mine and mine.Id == partyId then
		Lobby.Open("Party")
		return
	end
	local party = Lobby.FindParty(partyId)
	if not party then
		NotifyController.Show("Esse grupo não existe mais.", "warning", 3)
		return
	end
	if party.CanJoin ~= true then
		NotifyController.Show(party.JoinBlockReason or "Você não pode entrar nesse grupo agora.", "warning", 3)
		UIKit.PlaySound("Error")
		return
	end
	Lobby.JoinParty(partyId)
end

-------------------------------------------------------------------------------
-- Linhas
-------------------------------------------------------------------------------

local function createRow(partyId)
	local row = UIKit.New("Frame", {
		Name = "Party_" .. tostring(partyId),
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.05,
		Parent = ui.List,
	})
	UIKit.Corner(row, 14)
	local stroke = UIKit.Stroke(row, 2.5, Theme.PanelDark)
	local stripe = UIKit.New("Frame", {
		Name = "Stripe",
		Size = UDim2.new(0, 10, 1, 0),
		BackgroundColor3 = Theme.Accent,
		Parent = row,
	})
	UIKit.Corner(stripe, 14)

	local avatar = Lobby.Avatar(row, nil, 58, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 20, 0.5, 0),
	})
	local title = UIKit.Label({
		Name = "Title",
		Text = "",
		Title = true,
		TextSize = 21,
		Position = UDim2.fromOffset(90, 8),
		Size = UDim2.new(1, -(90 + RIGHT_AREA_WIDTH + 16), 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = row,
	})
	local subtitle = UIKit.Label({
		Name = "Subtitle",
		Text = "",
		TextSize = 14,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(90, 36),
		Size = UDim2.new(1, -(90 + RIGHT_AREA_WIDTH + 16), 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = row,
	})
	local tags = UIKit.New("Frame", {
		Name = "Tags",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(90, 60),
		Size = UDim2.new(1, -(90 + RIGHT_AREA_WIDTH + 16), 0, 24),
		Parent = row,
	})
	UIKit.List(tags, 6, "Horizontal")
	local privacyTag = Lobby.Tag({ Name = "Privacy", Height = 22, TextSize = 13, LayoutOrder = 1, Parent = tags })
	local slotsTag = Lobby.Tag({
		Name = "Slots",
		Height = 22,
		TextSize = 13,
		Color = Theme.PanelDark,
		LayoutOrder = 2,
		Parent = tags,
	})
	local stateTag = Lobby.Tag({ Name = "State", Height = 22, TextSize = 13, LayoutOrder = 3, Parent = tags })
	local resumeTag = Lobby.Tag({
		Name = "Resume",
		Text = "Partida salva",
		Height = 22,
		TextSize = 13,
		Color = Theme.Info,
		LayoutOrder = 4,
		Parent = tags,
	})

	-- Área da direita: botão (Entrar / Abrir) ou o motivo de não poder entrar.
	local right = UIKit.New("Frame", {
		Name = "Right",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.new(0, RIGHT_AREA_WIDTH, 1, -16),
		BackgroundTransparency = 1,
		Parent = row,
	})
	local button = UIKit.Button({
		Name = "Join",
		Text = "Entrar",
		Color = Theme.Success,
		Size = UDim2.new(1, 0, 0, 50),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		TextSize = 22,
		Parent = right,
	}, function()
		onRowButton(partyId)
	end)
	local reason = UIKit.Label({
		Name = "Reason",
		Text = "",
		TextSize = 14,
		Color = Theme.TextDim,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = right,
	})

	return {
		Frame = row,
		Stroke = stroke,
		Stripe = stripe,
		Avatar = avatar,
		Title = title,
		Subtitle = subtitle,
		Privacy = privacyTag,
		Slots = slotsTag,
		State = stateTag,
		Resume = resumeTag,
		Button = button,
		Reason = reason,
		HostUserId = nil,
	}
end

local function updateRow(row, party, isMine)
	local color = Lobby.GetMapColor(party.MapId)
	local def = Lobby.GetMapDef(party.MapId)
	row.Stripe.BackgroundColor3 = color
	row.Stroke.Color = isMine and Theme.Accent or Theme.PanelDark
	row.Stroke.Thickness = isMine and 3.5 or 2.5

	-- Foto do dono (recarrega se a liderança mudou).
	local hostId = tonumber(party.HostUserId)
	if hostId and row.HostUserId ~= hostId then
		row.HostUserId = hostId
		Lobby.LoadThumbnail(hostId, row.Avatar)
	end

	local hostName = party.HostName
	if type(hostName) ~= "string" or hostName == "" then
		hostName = "?"
	end
	row.Title.Text = isMine and ("Seu grupo (dono: %s)"):format(hostName) or ("Grupo de %s"):format(hostName)
	row.Subtitle.Text = ("%s  •  Ato %s"):format(Lobby.GetMapName(party.MapId), def and tostring(def.Act) or "?")

	Lobby.SetTag(row.Privacy, Lobby.GetPrivacyName(party.Privacy), Lobby.GetPrivacyColor(party.Privacy))
	local count, max = #party.Members, party.MaxPlayers
	Lobby.SetTag(row.Slots, ("%d/%d jogadores"):format(count, max), count >= max and Theme.Danger or Theme.PanelDark)
	Lobby.SetTag(row.State, Lobby.GetStateText(party.State), Lobby.GetStateColor(party.State))
	row.Resume.Visible = party.Resume == true

	-- Botão ou motivo.
	if isMine then
		row.Button.Visible = true
		row.Reason.Visible = false
		row.Button.Text = "Abrir"
		row.Button.BackgroundColor3 = Theme.Accent2
	elseif party.CanJoin == true then
		row.Button.Visible = true
		row.Reason.Visible = false
		row.Button.Text = "Entrar"
		row.Button.BackgroundColor3 = Theme.Success
	else
		row.Button.Visible = false
		row.Reason.Visible = true
		local reason = party.JoinBlockReason
		if type(reason) ~= "string" or reason == "" then
			reason = "Não dá para entrar agora."
		end
		row.Reason.Text = reason
	end
end

-------------------------------------------------------------------------------
-- Atualização da janela
-------------------------------------------------------------------------------

local function refresh()
	if not ui then
		return
	end
	local list = sortedParties()
	local mine = Lobby.GetMyParty()
	local seen = {}
	local joinable = 0

	for order, entry in ipairs(list) do
		local party = entry.Party
		if not seen[party.Id] then
			seen[party.Id] = true
			local row = rows[party.Id]
			if not row then
				row = createRow(party.Id)
				rows[party.Id] = row
			end
			row.Frame.LayoutOrder = order
			updateRow(row, party, entry.IsMine)
			if not entry.IsMine and party.CanJoin == true then
				joinable += 1
			end
		end
	end

	-- Grupos que sumiram perdem a linha.
	for partyId, row in pairs(rows) do
		if not seen[partyId] then
			row.Frame:Destroy()
			rows[partyId] = nil
		end
	end

	-- Topo: contagem e botão de criar / abrir meu grupo.
	local others = #list - (mine and 1 or 0)
	local countText
	if others <= 0 then
		countText = "Nenhum outro grupo esperando"
	elseif others == 1 then
		countText = "1 grupo esperando"
	else
		countText = ("%d grupos esperando"):format(others)
	end
	if joinable > 0 then
		countText ..= ("  •  %d com vaga para você"):format(joinable)
	end
	ui.Count.Text = countText
	ui.TopButton.Text = mine and "Meu grupo" or "Criar grupo"
	ui.TopButton.BackgroundColor3 = mine and Theme.Success or Theme.Accent

	ui.Empty.Visible = #list == 0
	task.defer(Lobby.FixSelection, window)
end

-------------------------------------------------------------------------------
-- Montagem da janela
-------------------------------------------------------------------------------

local function build()
	window = UIKit.Window(WINDOW_NAME, "Partidas Abertas", WINDOW_SIZE)
	local content = window.Content
	Lobby.PrepareContent(content)
	ui = {}

	-- Topo: quantos grupos + botão.
	local top = Lobby.Section(content, nil, 1)
	local topRow = UIKit.New("Frame", {
		Name = "Top",
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = top,
	})
	ui.Count = UIKit.Label({
		Name = "Count",
		Text = "",
		Title = true,
		TextSize = 22,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, -230, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = topRow,
	})
	ui.TopButton = UIKit.Button({
		Name = "Create",
		Text = "Criar grupo",
		Color = Theme.Accent,
		Size = UDim2.fromOffset(210, 48),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		TextSize = 20,
		Parent = topRow,
	}, function()
		if Lobby.GetMyParty() then
			Lobby.Open("Party")
		else
			Lobby.Open("Create")
		end
	end)
	UIKit.Label({
		Name = "Hint",
		Text = "Aparecem os grupos públicos, os de amigos seus e os que convidaram você.",
		TextSize = 14,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = top,
	})

	-- Lista de grupos.
	ui.List = UIKit.New("Frame", {
		Name = "List",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = content,
	})
	UIKit.List(ui.List, 8)

	-- Nenhum grupo.
	ui.Empty = Lobby.Section(content, nil, 3)
	UIKit.Label({
		Name = "Text",
		Text = "Nenhum grupo aberto agora. Que tal criar o seu e chamar a galera?",
		Title = true,
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 70),
		LayoutOrder = 1,
		Parent = ui.Empty,
	})
end

-- Escuta mudanças enquanto a janela está aberta.
local function startListening()
	listenTrove:Clean()
	listenTrove:Add(Lobby.PartyChanged:Connect(function()
		refresh()
	end))
	listenTrove:Add(StateController.OnChanged("Profile", function()
		refresh()
	end))
end

local function ensureWindow()
	if window then
		return
	end
	build()
	window.OnOpen:Connect(startListening)
	window.OnClose:Connect(function()
		listenTrove:Clean()
	end)
end

-------------------------------------------------------------------------------
-- API
-------------------------------------------------------------------------------

function LobbyList.Open()
	if not getLobby() then
		return
	end
	ensureWindow()
	refresh()
	if not window.IsOpen() then
		window.Content.CanvasPosition = Vector2.zero
		window.Open()
	end
end

function LobbyList.Close()
	if window then
		window.Close()
	end
end

function LobbyList.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function LobbyList.Init(lobby)
	if type(lobby) == "table" and lobby.GetPartyState then
		Lobby = lobby
	else
		getLobby()
	end
end

function LobbyList.Start() end

return LobbyList
