-- LobbyParty (lobby): a janela "Meu Grupo".
--
-- Mostra o grupo do jogador (PartyState.MyParty):
--   * cabeçalho com mapa, dono, privacidade, vagas e a contagem regressiva grande;
--   * barra de ações: "Estou pronto!" (membros), "Iniciar partida!", "Forçar início",
--     "Cancelar contagem" (dono) e "Sair do grupo";
--   * lista de membros com foto (Players:GetUserThumbnailAsync), status de pronto e,
--     para o dono, os botões "Passar liderança" e "Expulsar" (com confirmação);
--   * controles do dono: trocar mapa, máximo de jogadores, privacidade e partida salva;
--   * convites: jogadores do servidor (PartyInvite) e convite do Roblox
--     (SocialService:PromptGameInvite).
-- As linhas de membros e de convite são reaproveitadas (não recriadas) a cada atualização,
-- para a seleção do controle não "pular".
--
-- Aberta pelo LobbyUI. Recebe o LobbyUI no Init.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maps = require(Config:WaitForChild("Maps"))
local LobbyConfig = require(Config:WaitForChild("Lobby"))
local Trove = require(Util:WaitForChild("Trove"))

local UIFolder = script.Parent
local ControllersFolder = UIFolder.Parent:WaitForChild("Controllers")
local UIKit = require(UIFolder:WaitForChild("UIKit"))
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme
local LocalPlayer = Players.LocalPlayer

local LobbyParty = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

local WINDOW_NAME = "LobbyParty"
local WINDOW_SIZE = UDim2.fromOffset(800, 630)
local HEADER_HEIGHT = 132
local MEMBER_ROW_HEIGHT = 72
local INVITE_ROW_HEIGHT = 56
local ACTION_BUTTON_HEIGHT = 50
local JOINING_GRACE_SECONDS = 5 -- tempo mostrando "Entrando no grupo..." antes do estado chegar

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local Lobby = nil -- o módulo LobbyUI (recebido no Init)
local window = nil
local ui = nil
local listenTrove = Trove.new() -- conexões enquanto a janela está aberta
local memberRows = {} -- [userId] = linha do membro
local inviteRows = {} -- [userId] = linha de "convidar jogador"
local invitedLocal = {} -- [userId] = partyId para o qual já convidamos (nesta sessão)
local showInviteList = false
local hadParty = false -- a janela estava mostrando um grupo?
local switchingParty = false -- saindo do grupo para entrar em outro (convite aceito)?
local joiningUntil = 0 -- os.clock() até quando mostramos "Entrando no grupo..."
local lastCountdownSecond = nil

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

-- Texto pequeno à esquerda.
local function smallLabel(parent, text, order, color)
	return UIKit.Label({
		Name = "Label",
		Text = text,
		TextSize = 15,
		Color = color or Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = order,
		Parent = parent,
	})
end

-- Em qual grupo (visível) está esse jogador? (nil se nenhum)
local function findPartyOfUser(userId)
	for _, party in ipairs(Lobby.GetPartyState().Parties) do
		if Lobby.GetMember(party, userId) then
			return party
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Ações (pedidos ao servidor)
-------------------------------------------------------------------------------

local function toggleReady()
	local party = Lobby.GetMyParty()
	if not party then
		return
	end
	local me = Lobby.GetMember(party, LocalPlayer.UserId)
	local newReady = not (me and me.Ready == true)
	Lobby.Request("PartyReady", newReady)
end

local function startParty(force)
	local party = Lobby.GetMyParty()
	if not party or not Lobby.IsHost(party) then
		return
	end
	if not force and not Lobby.AreAllReady(party) then
		NotifyController.Show("Nem todo mundo está pronto. Espere ou use Forçar início.", "warning", 3)
		UIKit.PlaySound("Error")
		return
	end
	Lobby.Request("PartyStart", force == true)
end

local function cancelCountdown()
	Lobby.Request("PartyCancelCountdown")
end

local function leaveParty()
	local ok = Lobby.Request("PartyLeave")
	if ok then
		NotifyController.Show("Você saiu do grupo.", "info", 3)
		if window then
			window.Close()
		end
	end
end

local function kickMember(userId)
	Lobby.Request("PartyKick", userId)
end

local function transferHost(userId)
	local ok = Lobby.Request("PartyTransfer", userId)
	if ok then
		local member = Lobby.GetMember(Lobby.GetMyParty(), userId)
		NotifyController.Show(("Agora %s é o dono do grupo."):format(Lobby.MemberName(member)), "success", 3)
	end
end

-- As opções do grupo só mudam com o grupo esperando (o servidor recusa durante a contagem).
local function canEditSettings(party)
	if not party or not Lobby.IsHost(party) then
		return false
	end
	if party.State == "Countdown" then
		NotifyController.Show("Cancele a contagem regressiva antes de mudar o grupo.", "warning", 3)
		UIKit.PlaySound("Error")
		return false
	end
	return party.State == "Waiting"
end

local function setMap(mapId)
	local party = Lobby.GetMyParty()
	if not canEditSettings(party) then
		return
	end
	if not Lobby.IsMapUnlocked(mapId) then
		NotifyController.Show(Lobby.GetMapRequirement(mapId) .. " para liberar este mapa.", "warning", 3)
		UIKit.PlaySound("Error")
		return
	end
	if party.MapId ~= mapId then
		Lobby.Request("PartySetMap", mapId)
	end
end

local function setMaxPlayers(n)
	local party = Lobby.GetMyParty()
	if not canEditSettings(party) then
		return
	end
	if n < #party.Members then
		NotifyController.Show(
			("O grupo já tem %d jogadores; o máximo não pode ser menor."):format(#party.Members),
			"warning",
			3
		)
		UIKit.PlaySound("Error")
		return
	end
	if party.MaxPlayers ~= n then
		Lobby.Request("PartySetMaxPlayers", n)
	end
end

local function setPrivacy(privacy)
	local party = Lobby.GetMyParty()
	if canEditSettings(party) and party.Privacy ~= privacy then
		Lobby.Request("PartySetPrivacy", privacy)
	end
end

local function setResume(resume)
	local party = Lobby.GetMyParty()
	if canEditSettings(party) and (party.Resume == true) ~= resume then
		Lobby.Request("PartySetResume", resume)
	end
end

-- Convida um jogador que está neste servidor.
local function invitePlayer(player)
	local party = Lobby.GetMyParty()
	if not party or not Lobby.IsHost(party) then
		return
	end
	if invitedLocal[player.UserId] == party.Id then
		NotifyController.Show(("Você já convidou %s."):format(player.DisplayName), "info", 3)
		return
	end
	local ok = Lobby.Request("PartyInvite", player.UserId)
	if ok then
		invitedLocal[player.UserId] = party.Id
		NotifyController.Show(("Convite enviado para %s!"):format(player.DisplayName), "success", 3)
		UIKit.PlaySound("Notify")
	end
end

-- Abre o convite do próprio Roblox (chama amigos para este servidor).
local function promptRobloxInvite()
	local okCan, canInvite = pcall(function()
		return SocialService:CanSendGameInviteAsync(LocalPlayer)
	end)
	if not okCan or not canInvite then
		NotifyController.Show(
			"O convite do Roblox não está disponível agora (no Studio ele não funciona).",
			"warning",
			4
		)
		return
	end
	local okPrompt, err = pcall(function()
		SocialService:PromptGameInvite(LocalPlayer)
	end)
	if not okPrompt then
		warn("[LobbyParty] PromptGameInvite falhou: " .. tostring(err))
		Lobby.ShowError("Não deu para abrir o convite do Roblox.")
	end
end

-------------------------------------------------------------------------------
-- Linhas de membros
-------------------------------------------------------------------------------

local function createMemberRow(userId)
	local row = UIKit.New("Frame", {
		Name = "Member_" .. tostring(userId),
		Size = UDim2.new(1, 0, 0, MEMBER_ROW_HEIGHT),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.1,
		Parent = ui.MembersList,
	})
	UIKit.Corner(row, 12)
	local stroke = UIKit.Stroke(row, 2, Theme.PanelDark)

	local avatar = Lobby.Avatar(row, userId, 56, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
	})
	local nameLabel = UIKit.Label({
		Name = "DisplayName",
		Text = "",
		Title = true,
		TextSize = 21,
		Position = UDim2.fromOffset(76, 8),
		Size = UDim2.new(1, -470, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = row,
	})
	local userLabel = UIKit.Label({
		Name = "UserName",
		Text = "",
		TextSize = 14,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(76, 38),
		Size = UDim2.new(1, -470, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = row,
	})
	local status = Lobby.Tag({
		Name = "Status",
		Text = "",
		Height = 30,
		TextSize = 16,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -262, 0.5, 0),
		Parent = row,
	})

	-- Botões do dono (passar liderança e expulsar).
	local buttons = UIKit.New("Frame", {
		Name = "HostButtons",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.new(0, 244, 0, 44),
		BackgroundTransparency = 1,
		Parent = row,
	})
	local buttonsLayout = UIKit.List(buttons, 8, "Horizontal")
	buttonsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	local transfer = Lobby.ConfirmButton({
		Name = "Transfer",
		Text = "Passar liderança",
		Color = Theme.Accent2,
		Size = UDim2.fromOffset(136, 42),
		TextSize = 16,
		LayoutOrder = 1,
		Parent = buttons,
	}, "Certeza?", function()
		transferHost(userId)
	end)
	local kick = Lobby.ConfirmButton({
		Name = "Kick",
		Text = "Expulsar",
		Color = Theme.Danger,
		Size = UDim2.fromOffset(100, 42),
		TextSize = 16,
		LayoutOrder = 2,
		Parent = buttons,
	}, "Certeza?", function()
		kickMember(userId)
	end)

	return {
		Frame = row,
		Stroke = stroke,
		Avatar = avatar,
		Name = nameLabel,
		User = userLabel,
		Status = status,
		Buttons = buttons,
		Transfer = transfer,
		Kick = kick,
	}
end

local function clearMemberRows()
	for userId, row in pairs(memberRows) do
		row.Frame:Destroy()
		memberRows[userId] = nil
	end
end

local function refreshMembers(party)
	local isHost = Lobby.IsHost(party)
	local hostId = tonumber(party.HostUserId)
	local myId = LocalPlayer.UserId
	local seen = {}

	for index, member in ipairs(party.Members) do
		local userId = tonumber(member.UserId)
		if userId and not seen[userId] then
			seen[userId] = true
			local row = memberRows[userId]
			if not row then
				row = createMemberRow(userId)
				memberRows[userId] = row
			end
			row.Frame.LayoutOrder = index

			local isMe = userId == myId
			local memberIsHost = userId == hostId
			row.Name.Text = Lobby.MemberName(member) .. (isMe and " (você)" or "")
			row.User.Text = "@" .. tostring(member.Name or "?")
			row.Stroke.Color = isMe and Theme.Accent or Theme.PanelDark
			row.Stroke.Thickness = isMe and 3 or 2

			if memberIsHost then
				Lobby.SetTag(row.Status, "Dono", Theme.Rare)
				row.Status.TextColor3 = Theme.TextDark
			elseif member.Ready == true then
				Lobby.SetTag(row.Status, "Pronto!", Theme.Success)
				row.Status.TextColor3 = Theme.Text
			else
				Lobby.SetTag(row.Status, "Não pronto", Theme.Disabled)
				row.Status.TextColor3 = Theme.Text
			end

			-- Só o dono vê os botões, e nunca na própria linha.
			local showButtons = isHost and not isMe and party.State ~= "Teleporting"
			row.Buttons.Visible = showButtons
			row.Status.Position = showButtons and UDim2.new(1, -262, 0.5, 0) or UDim2.new(1, -12, 0.5, 0)
		end
	end

	-- Quem saiu do grupo perde a linha.
	for userId, row in pairs(memberRows) do
		if not seen[userId] then
			row.Frame:Destroy()
			memberRows[userId] = nil
		end
	end

	local count = #party.Members
	ui.MembersTitle.Text = ("Jogadores (%d/%d)"):format(count, party.MaxPlayers)
	local free = math.max(0, party.MaxPlayers - count)
	if free == 0 then
		ui.FreeSlots.Text = "Grupo cheio!"
	elseif free == 1 then
		ui.FreeSlots.Text = "1 vaga livre."
	else
		ui.FreeSlots.Text = ("%d vagas livres."):format(free)
	end
end

-------------------------------------------------------------------------------
-- Linhas de convite (jogadores do servidor)
-------------------------------------------------------------------------------

local function createInviteRow(player)
	local row = UIKit.New("Frame", {
		Name = "Invite_" .. tostring(player.UserId),
		Size = UDim2.new(1, 0, 0, INVITE_ROW_HEIGHT),
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.2,
		Parent = ui.InviteList,
	})
	UIKit.Corner(row, 12)
	Lobby.Avatar(row, player.UserId, 42, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
	})
	UIKit.Label({
		Name = "PlayerName",
		Text = ("%s (@%s)"):format(player.DisplayName, player.Name),
		TextSize = 17,
		Position = UDim2.fromOffset(60, 6),
		Size = UDim2.new(1, -240, 0, 24),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Parent = row,
	})
	local note = UIKit.Label({
		Name = "Note",
		Text = "",
		TextSize = 13,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(60, 30),
		Size = UDim2.new(1, -240, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	local button = UIKit.Button({
		Name = "Invite",
		Text = "Convidar",
		Color = Theme.Accent2,
		Size = UDim2.fromOffset(150, 42),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		TextSize = 18,
		Parent = row,
	}, function()
		invitePlayer(player)
	end)
	return { Frame = row, Note = note, Button = button }
end

local function clearInviteRows()
	for userId, row in pairs(inviteRows) do
		row.Frame:Destroy()
		inviteRows[userId] = nil
	end
end

local function refreshInvites(party)
	local isHost = Lobby.IsHost(party)
	local teleporting = party.State == "Teleporting"
	ui.ServerInviteButton.Visible = isHost
	ui.ServerInviteButton.Text = showInviteList and "Esconder lista" or "Convidar jogador do servidor"
	ui.RobloxInviteButton.Visible = not teleporting
	if isHost then
		ui.InviteHint.Text =
			"Convide quem está neste servidor, ou chame amigos pelo Roblox. Quando o amigo chegar, convide ele pela lista."
	else
		ui.InviteHint.Text = "Chame amigos pelo Roblox para este servidor! O dono do grupo convida quem chegar."
	end

	local visible = isHost and showInviteList and not teleporting
	ui.InviteList.Visible = visible
	if not visible then
		ui.InviteEmpty.Visible = false
		clearInviteRows()
		return
	end

	local seen = {}
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and player.Parent == Players and not Lobby.GetMember(party, player.UserId) then
			count += 1
			seen[player.UserId] = true
			local row = inviteRows[player.UserId]
			if not row then
				row = createInviteRow(player)
				inviteRows[player.UserId] = row
			end
			row.Frame.LayoutOrder = count

			local invited = invitedLocal[player.UserId] == party.Id
			row.Button.Text = invited and "Convidado!" or "Convidar"
			row.Button.BackgroundColor3 = invited and Theme.Disabled or Theme.Accent2

			local otherParty = findPartyOfUser(player.UserId)
			if otherParty then
				row.Note.Text = "Já está em outro grupo"
			else
				row.Note.Text = "Livre para jogar"
			end
		end
	end
	for userId, row in pairs(inviteRows) do
		if not seen[userId] then
			row.Frame:Destroy()
			inviteRows[userId] = nil
		end
	end
	ui.InviteEmpty.Visible = count == 0
end

local function toggleInviteList()
	showInviteList = not showInviteList
	local party = Lobby.GetMyParty()
	if party then
		refreshInvites(party)
		task.defer(Lobby.FixSelection, window)
	end
end

-------------------------------------------------------------------------------
-- Atualização da janela
-------------------------------------------------------------------------------

-- Número grande do cabeçalho: contagem, teleporte ou vagas.
local function updateBig(party)
	local big = ui.Header
	local remaining = Lobby.CountdownSeconds(party)
	if remaining then
		local seconds = math.ceil(remaining)
		big.Number.Text = seconds > 0 and tostring(seconds) or "Já!"
		big.Number.TextColor3 = Theme.Rare
		big.Caption.Text = "Começando!"
		if seconds ~= lastCountdownSecond then
			lastCountdownSecond = seconds
			UIKit.Pop(big.Number, 0.2)
		end
	elseif party.State == "Teleporting" then
		lastCountdownSecond = nil
		big.Number.Text = "Já!"
		big.Number.TextColor3 = Theme.Accent
		big.Caption.Text = "Teleportando..."
	else
		lastCountdownSecond = nil
		big.Number.Text = ("%d/%d"):format(#party.Members, party.MaxPlayers)
		big.Number.TextColor3 = Theme.Text
		big.Caption.Text = "jogadores"
	end
end

local function refreshHeader(party)
	local header = ui.Header
	local color = Lobby.GetMapColor(party.MapId)
	local def = Lobby.GetMapDef(party.MapId)
	header.Stripe.BackgroundColor3 = color
	header.Stroke.Color = color
	header.MapName.Text = Lobby.GetMapName(party.MapId)

	local hostName = party.HostName
	if type(hostName) ~= "string" or hostName == "" then
		hostName = Lobby.MemberName(Lobby.GetMember(party, party.HostUserId))
	end
	header.Subtitle.Text = ("Ato %s  •  Dono: %s"):format(def and tostring(def.Act) or "?", hostName)

	Lobby.SetTag(header.Privacy, Lobby.GetPrivacyName(party.Privacy), Lobby.GetPrivacyColor(party.Privacy))
	header.Resume.Visible = party.Resume == true
	Lobby.SetTag(header.State, Lobby.GetStateText(party.State), Lobby.GetStateColor(party.State))
	updateBig(party)
end

local function refreshActions(party)
	local isHost = Lobby.IsHost(party)
	local state = party.State
	local teleporting = state == "Teleporting"
	local counting = state == "Countdown"
	local waitingState = state == "Waiting"
	local me = Lobby.GetMember(party, LocalPlayer.UserId)
	local ready = me ~= nil and me.Ready == true
	local allReady, waitingCount = Lobby.AreAllReady(party)

	-- Pronto (só membros; o dono conta como pronto).
	ui.ReadyButton.Visible = not isHost and not teleporting
	if not isHost then
		ui.ReadyButton.Text = ready and "Não estou pronto" or "Estou pronto!"
		ui.ReadyButton.BackgroundColor3 = ready and Theme.Warning or Theme.Success
	end

	-- Botões do dono.
	ui.StartButton.Visible = isHost and waitingState
	ui.StartButton.BackgroundColor3 = allReady and Theme.Success or Theme.Disabled
	ui.ForceButton.Visible = isHost and waitingState and not allReady
	ui.CancelButton.Visible = isHost and counting
	ui.LeaveButton.Visible = not teleporting

	-- Dica embaixo dos botões.
	local hint
	if teleporting then
		hint = "Teleportando para a partida... segura aí!"
	elseif isHost and counting then
		hint = "A contagem começou! Aperte Cancelar se precisar esperar alguém."
	elseif isHost and allReady then
		if #party.Members <= 1 then
			hint = "Você está sozinho: pode iniciar uma partida solo (ou esperar a galera)."
		else
			hint = "Todo mundo pronto! Aperte Iniciar partida."
		end
	elseif isHost then
		if waitingCount == 1 then
			hint = "Esperando 1 jogador ficar pronto... ou force o início."
		else
			hint = ("Esperando %d jogadores ficarem prontos... ou force o início."):format(waitingCount)
		end
	elseif counting then
		hint = "A partida vai começar! Desmarcar o pronto cancela a contagem."
	elseif ready then
		hint = "Você está pronto! Agora é só esperar o dono iniciar."
	else
		hint = "Marque que está pronto quando quiser jogar."
	end
	ui.ActionsHint.Text = hint
end

local function refreshHostControls(party)
	local isHost = Lobby.IsHost(party)
	ui.HostSection.Visible = isHost
	ui.GuestSection.Visible = not isHost

	if isHost then
		local editable = party.State == "Waiting"
		local memberCount = #party.Members

		for mapId, button in pairs(ui.MapButtons) do
			local unlocked = Lobby.IsMapUnlocked(mapId)
			Lobby.SetSelected(button, mapId == party.MapId, Lobby.GetMapColor(mapId))
			if not unlocked then
				button.BackgroundColor3 = Theme.PanelDark
			end
			button:SetAttribute("Disabled", not editable and mapId ~= party.MapId)
		end
		for n, button in pairs(ui.MaxButtons) do
			Lobby.SetSelected(button, n == party.MaxPlayers, Theme.Accent)
			if n < memberCount then
				button.BackgroundColor3 = Theme.PanelDark
			end
			button:SetAttribute("Disabled", not editable and n ~= party.MaxPlayers)
		end
		for privacy, button in pairs(ui.PrivacyButtons) do
			Lobby.SetSelected(button, privacy == party.Privacy, Lobby.GetPrivacyColor(privacy))
			button:SetAttribute("Disabled", not editable and privacy ~= party.Privacy)
		end
		ui.PrivacyHint.Text = Lobby.GetPrivacyHint(party.Privacy)

		-- Partida salva: só se o dono (eu) tem save neste mapa.
		local save = Lobby.GetRunSave(party.MapId)
		ui.ResumeFrame.Visible = save ~= nil
		if save then
			local savedAt = type(save) == "number" and (" (salva em " .. Lobby.FormatDate(save) .. ")") or ""
			ui.ResumeText.Text = ("Você tem uma partida salva neste mapa%s."):format(savedAt)
			Lobby.SetSelected(ui.ResumeYes, party.Resume == true, Theme.Success)
			Lobby.SetSelected(ui.ResumeNo, party.Resume ~= true, Theme.Warning)
		end

		ui.HostNote.Text = editable and "Só você, o dono, vê estes controles."
			or "Cancele a contagem regressiva para mudar as opções."
	else
		local def = Lobby.GetMapDef(party.MapId)
		ui.GuestText.Text = table.concat({
			("Mapa: %s (Ato %s)"):format(Lobby.GetMapName(party.MapId), def and tostring(def.Act) or "?"),
			"Privacidade: " .. Lobby.GetPrivacyName(party.Privacy),
			("Vagas: %d/%d"):format(#party.Members, party.MaxPlayers),
			"Partida salva: "
				.. (party.Resume == true and "sim, vamos continuar de onde o dono parou" or "não, começa do zero"),
			"",
			"Só o dono do grupo pode mudar essas opções e iniciar a partida.",
		}, "\n")
	end
end

-- Atualiza a janela inteira com o estado atual.
local function refresh()
	if not ui then
		return
	end
	local party = Lobby.GetMyParty()
	local hasParty = party ~= nil

	ui.Empty.Visible = not hasParty
	ui.Header.Card.Visible = hasParty
	ui.ActionsSection.Visible = hasParty
	ui.MembersSection.Visible = hasParty
	ui.HostSection.Visible = hasParty
	ui.GuestSection.Visible = hasParty
	ui.InviteSection.Visible = hasParty

	if not hasParty then
		if os.clock() < joiningUntil then
			ui.EmptyText.Text = "Entrando no grupo..."
		else
			ui.EmptyText.Text = "Você não está em nenhum grupo agora."
		end
		clearMemberRows()
		clearInviteRows()
		task.defer(Lobby.FixSelection, window)
		return
	end

	hadParty = true
	joiningUntil = 0
	refreshHeader(party)
	refreshActions(party)
	refreshMembers(party)
	refreshHostControls(party)
	refreshInvites(party)
	task.defer(Lobby.FixSelection, window)
end

-- Chegou um PartyState novo.
local function onPartyChanged()
	if not window or not window.IsOpen() then
		return
	end
	local party = Lobby.GetMyParty()
	if not party and hadParty then
		hadParty = false
		if switchingParty then
			-- Trocando de grupo: a janela fica aberta esperando o grupo novo.
			switchingParty = false
			joiningUntil = os.clock() + JOINING_GRACE_SECONDS
			refresh()
			return
		end
		-- Saí do grupo (ou fui expulso, ou o grupo acabou): fecha a janela.
		-- O servidor já avisa quando é expulsão; aqui só fechamos.
		window.Close()
		return
	end
	refresh()
end

-------------------------------------------------------------------------------
-- Montagem da janela
-------------------------------------------------------------------------------

local function buildHeader(content)
	local card = UIKit.New("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		BackgroundColor3 = Theme.Panel,
		LayoutOrder = 1,
		Parent = content,
	})
	UIKit.Corner(card, 16)
	local stroke = UIKit.Stroke(card, 3, Theme.Accent)
	local stripe = UIKit.New("Frame", {
		Name = "Stripe",
		Size = UDim2.new(0, 14, 1, 0),
		BackgroundColor3 = Theme.Accent,
		Parent = card,
	})
	UIKit.Corner(stripe, 16)

	local mapName = UIKit.Label({
		Name = "MapName",
		Text = "",
		Title = true,
		TextSize = 30,
		Position = UDim2.fromOffset(28, 10),
		Size = UDim2.new(1, -250, 0, 38),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	local subtitle = UIKit.Label({
		Name = "Subtitle",
		Text = "",
		TextSize = 15,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(28, 50),
		Size = UDim2.new(1, -250, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	local tags = UIKit.New("Frame", {
		Name = "Tags",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(28, 84),
		Size = UDim2.new(1, -250, 0, 28),
		Parent = card,
	})
	UIKit.List(tags, 6, "Horizontal")
	local privacyTag = Lobby.Tag({ Name = "Privacy", Height = 26, LayoutOrder = 1, Parent = tags })
	local resumeTag = Lobby.Tag({
		Name = "Resume",
		Text = "Partida salva",
		Color = Theme.Info,
		Height = 26,
		LayoutOrder = 2,
		Parent = tags,
	})
	local stateTag = Lobby.Tag({ Name = "State", Height = 26, LayoutOrder = 3, Parent = tags })

	-- Caixa da direita: número grande (vagas ou contagem).
	local box = UIKit.New("Frame", {
		Name = "Big",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(200, HEADER_HEIGHT - 24),
		BackgroundColor3 = Theme.PanelDark,
		Parent = card,
	})
	UIKit.Corner(box, 14)
	local number = UIKit.New("TextLabel", {
		Name = "Number",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 74),
		Font = Theme.TitleFont,
		TextSize = 64,
		Text = "",
		TextColor3 = Theme.Text,
		Parent = box,
	})
	UIKit.Stroke(number, 3, Theme.Stroke)
	local caption = UIKit.Label({
		Name = "Caption",
		Text = "",
		TextSize = 16,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(0, 74),
		Size = UDim2.new(1, 0, 0, 26),
		Parent = box,
	})

	return {
		Card = card,
		Stroke = stroke,
		Stripe = stripe,
		MapName = mapName,
		Subtitle = subtitle,
		Privacy = privacyTag,
		Resume = resumeTag,
		State = stateTag,
		Number = number,
		Caption = caption,
	}
end

local function buildActions(content)
	local section = Lobby.Section(content, nil, 2)
	local row = Lobby.Row(section, ACTION_BUTTON_HEIGHT + 4, 1, 10, Enum.HorizontalAlignment.Center)

	ui.ReadyButton = UIKit.Button({
		Name = "Ready",
		Text = "Estou pronto!",
		Color = Theme.Success,
		Size = UDim2.fromOffset(220, ACTION_BUTTON_HEIGHT),
		LayoutOrder = 1,
		TextSize = 22,
		Parent = row,
	}, toggleReady)
	ui.StartButton = UIKit.Button({
		Name = "Start",
		Text = "Iniciar partida!",
		Color = Theme.Success,
		Size = UDim2.fromOffset(220, ACTION_BUTTON_HEIGHT),
		LayoutOrder = 2,
		TextSize = 22,
		Parent = row,
	}, function()
		startParty(false)
	end)
	ui.ForceButton = Lobby.ConfirmButton({
		Name = "Force",
		Text = "Forçar início",
		Color = Theme.Warning,
		Size = UDim2.fromOffset(180, ACTION_BUTTON_HEIGHT),
		LayoutOrder = 3,
		TextSize = 20,
		Parent = row,
	}, "Forçar mesmo?", function()
		startParty(true)
	end)
	ui.CancelButton = UIKit.Button({
		Name = "Cancel",
		Text = "Cancelar contagem",
		Color = Theme.Danger,
		Size = UDim2.fromOffset(230, ACTION_BUTTON_HEIGHT),
		LayoutOrder = 4,
		TextSize = 20,
		Parent = row,
	}, cancelCountdown)
	ui.LeaveButton = Lobby.ConfirmButton({
		Name = "Leave",
		Text = "Sair do grupo",
		Color = UIKit.Darken(Theme.Danger, 0.15),
		Size = UDim2.fromOffset(170, ACTION_BUTTON_HEIGHT),
		LayoutOrder = 5,
		TextSize = 20,
		Parent = row,
	}, "Sair mesmo?", leaveParty)

	ui.ActionsHint = UIKit.Label({
		Name = "Hint",
		Text = "",
		TextSize = 15,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 2,
		Parent = section,
	})
	return section
end

local function buildMembers(content)
	local section = Lobby.Section(content, "Jogadores", 3)
	ui.MembersTitle = section:FindFirstChild("Title")
	ui.MembersList = UIKit.New("Frame", {
		Name = "List",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = section,
	})
	UIKit.List(ui.MembersList, 6)
	ui.FreeSlots = smallLabel(section, "", 2)
	return section
end

local function buildHostControls(content)
	local section = Lobby.Section(content, "Controles do dono", 4)

	smallLabel(section, "Mapa", 1, Theme.Text)
	local mapRow = Lobby.Row(section, 48, 2, 8)
	ui.MapButtons = {}
	for index, mapId in ipairs(Maps.Order) do
		local def = Lobby.GetMapDef(mapId)
		if def then
			ui.MapButtons[mapId] = UIKit.Button({
				Name = mapId,
				Text = def.DisplayName,
				Size = UDim2.fromOffset(206, 46),
				LayoutOrder = index,
				TextSize = 19,
				Parent = mapRow,
			}, function()
				setMap(mapId)
			end)
		end
	end

	smallLabel(section, "Máximo de jogadores", 3, Theme.Text)
	local maxRow = Lobby.Row(section, 46, 4, 6)
	ui.MaxButtons = {}
	for n = LobbyConfig.MinMaxPlayers, LobbyConfig.MaxPlayersLimit do
		ui.MaxButtons[n] = UIKit.Button({
			Name = "Max" .. n,
			Text = tostring(n),
			Size = UDim2.fromOffset(52, 44),
			LayoutOrder = n,
			TextSize = 22,
			Parent = maxRow,
		}, function()
			setMaxPlayers(n)
		end)
	end

	smallLabel(section, "Privacidade", 5, Theme.Text)
	local privacyRow = Lobby.Row(section, 46, 6, 8)
	ui.PrivacyButtons = {}
	for index, privacy in ipairs(Lobby.PrivacyOrder) do
		ui.PrivacyButtons[privacy] = UIKit.Button({
			Name = privacy,
			Text = Lobby.GetPrivacyName(privacy),
			Size = UDim2.fromOffset(190, 44),
			LayoutOrder = index,
			TextSize = 19,
			Parent = privacyRow,
		}, function()
			setPrivacy(privacy)
		end)
	end
	ui.PrivacyHint = smallLabel(section, "", 7)

	-- Partida salva (continuar ou do zero).
	ui.ResumeFrame = UIKit.New("Frame", {
		Name = "Resume",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 8,
		Parent = section,
	})
	local resumeLayout = UIKit.List(ui.ResumeFrame, 6)
	resumeLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	ui.ResumeText = smallLabel(ui.ResumeFrame, "", 1, Theme.Text)
	local resumeRow = Lobby.Row(ui.ResumeFrame, 46, 2, 8)
	ui.ResumeYes = UIKit.Button({
		Name = "Resume",
		Text = "Continuar partida salva",
		Size = UDim2.fromOffset(260, 44),
		LayoutOrder = 1,
		TextSize = 18,
		Parent = resumeRow,
	}, function()
		setResume(true)
	end)
	ui.ResumeNo = UIKit.Button({
		Name = "Fresh",
		Text = "Começar do zero",
		Size = UDim2.fromOffset(210, 44),
		LayoutOrder = 2,
		TextSize = 18,
		Parent = resumeRow,
	}, function()
		setResume(false)
	end)

	ui.HostNote = smallLabel(section, "", 9)
	return section
end

local function buildGuestInfo(content)
	local section = Lobby.Section(content, "Regras do grupo", 4)
	ui.GuestText = UIKit.Label({
		Name = "Text",
		Text = "",
		TextSize = 16,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 1,
		Parent = section,
	})
	return section
end

local function buildInvites(content)
	local section = Lobby.Section(content, "Convidar amigos", 5)
	local row = Lobby.Row(section, 50, 1, 10)
	ui.ServerInviteButton = UIKit.Button({
		Name = "ServerInvite",
		Text = "Convidar jogador do servidor",
		Color = Theme.Accent2,
		Size = UDim2.fromOffset(310, 46),
		LayoutOrder = 1,
		TextSize = 18,
		Parent = row,
	}, toggleInviteList)
	ui.RobloxInviteButton = UIKit.Button({
		Name = "RobloxInvite",
		Text = "Convidar amigos (Roblox)",
		Color = Theme.Info,
		Size = UDim2.fromOffset(280, 46),
		LayoutOrder = 2,
		TextSize = 18,
		Parent = row,
	}, promptRobloxInvite)
	ui.InviteHint = UIKit.Label({
		Name = "Hint",
		Text = "",
		TextSize = 14,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = section,
	})
	ui.InviteList = UIKit.New("Frame", {
		Name = "List",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Visible = false,
		Parent = section,
	})
	UIKit.List(ui.InviteList, 6)
	ui.InviteEmpty = smallLabel(section, "Não há outros jogadores livres neste servidor agora.", 4)
	ui.InviteEmpty.Visible = false
	return section
end

local function buildEmpty(content)
	local section = Lobby.Section(content, nil, 0)
	ui.EmptyText = UIKit.Label({
		Name = "Text",
		Text = "",
		Title = true,
		TextSize = 24,
		Size = UDim2.new(1, 0, 0, 60),
		LayoutOrder = 1,
		Parent = section,
	})
	local row = Lobby.Row(section, 52, 2, 12, Enum.HorizontalAlignment.Center)
	UIKit.Button({
		Name = "Create",
		Text = "Criar grupo",
		Color = Theme.Accent,
		Size = UDim2.fromOffset(210, 48),
		LayoutOrder = 1,
		TextSize = 20,
		Parent = row,
	}, function()
		Lobby.Open("Create")
	end)
	UIKit.Button({
		Name = "List",
		Text = "Partidas abertas",
		Color = Theme.Accent2,
		Size = UDim2.fromOffset(210, 48),
		LayoutOrder = 2,
		TextSize = 20,
		Parent = row,
	}, function()
		Lobby.Open("List")
	end)
	return section
end

local function build()
	window = UIKit.Window(WINDOW_NAME, "Meu Grupo", WINDOW_SIZE)
	local content = window.Content
	Lobby.PrepareContent(content)
	ui = {}

	ui.Empty = buildEmpty(content)
	ui.Header = buildHeader(content)
	ui.ActionsSection = buildActions(content)
	ui.MembersSection = buildMembers(content)
	ui.HostSection = buildHostControls(content)
	ui.GuestSection = buildGuestInfo(content)
	ui.InviteSection = buildInvites(content)
end

-- Escuta mudanças enquanto a janela está aberta.
local function startListening()
	listenTrove:Clean()
	listenTrove:Add(Lobby.PartyChanged:Connect(onPartyChanged))
	listenTrove:Add(StateController.OnChanged("Profile", function()
		refresh()
	end))
	listenTrove:Connect(Players.PlayerAdded, function()
		refresh()
	end)
	listenTrove:Connect(Players.PlayerRemoving, function(player)
		invitedLocal[player.UserId] = nil
		-- Durante o PlayerRemoving o jogador ainda aparece na lista: espera um pouco.
		task.delay(0.2, refresh)
	end)
	-- Número grande da contagem (a cada quadro).
	listenTrove:Connect(RunService.Heartbeat, function()
		local party = Lobby.GetMyParty()
		if party and ui then
			updateBig(party)
		end
	end)
end

local function ensureWindow()
	if window then
		return
	end
	build()
	window.OnOpen:Connect(startListening)
	window.OnClose:Connect(function()
		listenTrove:Clean()
		showInviteList = false
		hadParty = false
		switchingParty = false
	end)
end

-------------------------------------------------------------------------------
-- API
-------------------------------------------------------------------------------

-- Abre a janela. arg = "Joining" logo depois de criar/entrar (o estado ainda vai chegar).
function LobbyParty.Open(arg)
	if not getLobby() then
		return
	end
	ensureWindow()
	if arg == "Joining" then
		joiningUntil = os.clock() + JOINING_GRACE_SECONDS
		task.delay(JOINING_GRACE_SECONDS + 0.1, function()
			if window and window.IsOpen() then
				refresh()
			end
		end)
	end
	hadParty = Lobby.GetMyParty() ~= nil
	refresh()
	if not window.IsOpen() then
		window.Content.CanvasPosition = Vector2.zero
		window.Open()
	end
end

function LobbyParty.Close()
	if window then
		window.Close()
	end
end

function LobbyParty.IsOpen()
	return window ~= nil and window.IsOpen()
end

-- O LobbyUI avisa antes de sair do grupo para entrar em outro (troca de grupo).
function LobbyParty.ExpectLeave()
	switchingParty = true
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function LobbyParty.Init(lobby)
	if type(lobby) == "table" and lobby.GetPartyState then
		Lobby = lobby
	else
		getLobby()
	end
end

function LobbyParty.Start() end

return LobbyParty
