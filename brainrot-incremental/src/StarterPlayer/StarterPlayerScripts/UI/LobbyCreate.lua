-- LobbyCreate (lobby): a janela "Criar Partida".
--
-- O jogador escolhe:
--   1. o mapa (Config.Maps.Order): mapas ainda não liberados aparecem com cadeado e o
--      requisito ("Termine o Ato 1 (Prado Brainrot)"); cada cartão mostra imagem,
--      descrição e o recorde do jogador naquele mapa (Profile.MapRecords);
--   2. o máximo de jogadores (Config.Lobby.MinMaxPlayers até MaxPlayersLimit);
--   3. a privacidade (Público, Só amigos, Só convidados);
--   4. "Continuar partida salva" ou "Começar do zero" (só aparece se Profile.RunSaves[mapa]).
-- O botão "Criar grupo!" pede PartyCreate ao servidor e abre a janela "Meu Grupo".
-- Quem já está num grupo abre direto a janela "Meu Grupo".
--
-- Aberta pelo LobbyUI (botão lateral e prompt "CreateParty"). Recebe o LobbyUI no Init.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local Util = Shared:WaitForChild("Util")

local Maps = require(Config:WaitForChild("Maps"))
local LobbyConfig = require(Config:WaitForChild("Lobby"))
local NumberFormat = require(Util:WaitForChild("NumberFormat"))
local Trove = require(Util:WaitForChild("Trove"))

local UIFolder = script.Parent
local ControllersFolder = UIFolder.Parent:WaitForChild("Controllers")
local UIKit = require(UIFolder:WaitForChild("UIKit"))
local StateController = require(ControllersFolder:WaitForChild("StateController"))
local NotifyController = require(ControllersFolder:WaitForChild("NotifyController"))

local Theme = UIKit.Theme

local LobbyCreate = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

local WINDOW_NAME = "LobbyCreate"
local WINDOW_SIZE = UDim2.fromOffset(780, 620)
local MAP_CARD_WIDTH = 222
local MAP_CARD_HEIGHT = 212
local RECORD_HEIGHT = 16 -- linha do recorde, logo acima da etiqueta de situação
local PLAYER_BUTTON_SIZE = UDim2.fromOffset(54, 46)
local PRIVACY_BUTTON_SIZE = UDim2.fromOffset(200, 46)

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local Lobby = nil -- o módulo LobbyUI (recebido no Init)
local window = nil
local ui = nil -- referências dos pedaços da janela
local listenTrove = Trove.new() -- conexões enquanto a janela está aberta
local creating = false

-- Escolhas atuais (ficam guardadas entre uma abertura e outra).
local selection = {
	MapId = nil,
	MaxPlayers = LobbyConfig.DefaultMaxPlayers,
	Privacy = "Public",
	Resume = true,
}

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

-- Mapa padrão: o mais avançado que o jogador já liberou.
local function defaultMapId()
	local best = nil
	for _, mapId in ipairs(Maps.Order) do
		if Lobby.GetMapDef(mapId) and Lobby.IsMapUnlocked(mapId) then
			best = mapId
		end
	end
	return best or Maps.Order[1]
end

-- Texto do recorde do jogador num mapa: o máximo de moedas que ele ganhou numa partida
-- nesse mapa (Profile.MapRecords[mapId].BestCoins, gravado pelo servidor da partida).
local function recordText(mapId)
	local records = Lobby.GetProfile().MapRecords
	local record = type(records) == "table" and records[mapId] or nil
	local best = type(record) == "table" and tonumber(record.BestCoins) or nil
	if best and best > 0 then
		return "Recorde: " .. NumberFormat.Abbrev(best) .. " moedas"
	end
	return "Recorde: nenhum ainda"
end

-- Texto do "salvo em ..." de uma partida salva.
local function savedAtText(saveValue)
	if type(saveValue) == "number" then
		return " (salva em " .. Lobby.FormatDate(saveValue) .. ")"
	end
	return ""
end

-------------------------------------------------------------------------------
-- Atualização da janela
-------------------------------------------------------------------------------

local function refresh()
	if not ui then
		return
	end

	-- O mapa escolhido precisa estar liberado.
	if not selection.MapId or not Lobby.IsMapUnlocked(selection.MapId) then
		selection.MapId = defaultMapId()
	end
	selection.MaxPlayers =
		math.clamp(math.floor(selection.MaxPlayers), LobbyConfig.MinMaxPlayers, LobbyConfig.MaxPlayersLimit)

	-- Cartões dos mapas.
	for mapId, card in pairs(ui.MapCards) do
		local unlocked = Lobby.IsMapUnlocked(mapId)
		local selected = mapId == selection.MapId
		card.LockOverlay.Visible = not unlocked
		card.Button.BackgroundColor3 = unlocked and UIKit.Darken(card.Color, 0.3) or Theme.PanelDark
		card.Check.Visible = selected

		local stroke = card.Button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Thickness = selected and 5 or 2.5
		end

		-- Recorde do dono neste mapa (a seção 4.2 do prompt pede no cartão).
		card.Record.Text = recordText(mapId)

		if not unlocked then
			Lobby.SetTag(card.Status, "Trancado", Theme.Disabled)
			card.Status.TextColor3 = Theme.Text
		elseif Lobby.IsMapCompleted(mapId) then
			Lobby.SetTag(card.Status, "Concluído!", Theme.Rare)
			card.Status.TextColor3 = Theme.TextDark
		elseif Lobby.GetRunSave(mapId) then
			Lobby.SetTag(card.Status, "Partida salva", Theme.Info)
			card.Status.TextColor3 = Theme.Text
		else
			Lobby.SetTag(card.Status, "Liberado", Theme.Success)
			card.Status.TextColor3 = Theme.Text
		end
	end

	-- Máximo de jogadores.
	for n, button in pairs(ui.PlayerButtons) do
		Lobby.SetSelected(button, n == selection.MaxPlayers, Theme.Accent)
	end
	if selection.MaxPlayers == 1 then
		ui.PlayersHint.Text = "Só você: uma partida solo."
	else
		ui.PlayersHint.Text = ("Até %d jogadores no grupo."):format(selection.MaxPlayers)
	end

	-- Privacidade.
	for privacy, button in pairs(ui.PrivacyButtons) do
		Lobby.SetSelected(button, privacy == selection.Privacy, Lobby.GetPrivacyColor(privacy))
	end
	ui.PrivacyHint.Text = Lobby.GetPrivacyHint(selection.Privacy)

	-- Partida salva (só aparece se existe save neste mapa).
	local save = Lobby.GetRunSave(selection.MapId)
	ui.ResumeSection.Visible = save ~= nil
	if save then
		ui.ResumeText.Text = ("Você tem uma partida salva no %s%s. Quer continuar de onde parou?"):format(
			Lobby.GetMapName(selection.MapId),
			savedAtText(save)
		)
		Lobby.SetSelected(ui.ResumeYes, selection.Resume, Theme.Success)
		Lobby.SetSelected(ui.ResumeNo, not selection.Resume, Theme.Warning)
	end

	-- Resumo e botão de criar.
	local resumeText = (save and selection.Resume) and "  •  continuando o save" or ""
	ui.Summary.Text = ("%s  •  até %d jogador%s  •  %s%s"):format(
		Lobby.GetMapName(selection.MapId),
		selection.MaxPlayers,
		selection.MaxPlayers == 1 and "" or "es",
		Lobby.GetPrivacyName(selection.Privacy),
		resumeText
	)
	ui.CreateButton.Text = creating and "Criando..." or "Criar grupo!"
	ui.CreateButton:SetAttribute("Disabled", creating)
end

-------------------------------------------------------------------------------
-- Ações
-------------------------------------------------------------------------------

local function onMapClicked(mapId)
	if not Lobby.IsMapUnlocked(mapId) then
		NotifyController.Show(Lobby.GetMapRequirement(mapId) .. " para liberar este mapa.", "warning", 3)
		UIKit.PlaySound("Error")
		return
	end
	selection.MapId = mapId
	refresh()
end

-- Pede ao servidor para criar o grupo.
local function create()
	if creating then
		return
	end
	if Lobby.GetMyParty() then
		Lobby.Open("Party")
		return
	end
	local mapId = selection.MapId
	if not (mapId and Lobby.IsMapUnlocked(mapId)) then
		NotifyController.Show("Escolha um mapa liberado.", "warning", 3)
		return
	end

	local resume = Lobby.GetRunSave(mapId) ~= nil and selection.Resume == true
	creating = true
	refresh()
	local ok = Lobby.Request("PartyCreate", {
		MapId = mapId,
		MaxPlayers = selection.MaxPlayers,
		Privacy = selection.Privacy,
		Resume = resume,
	})
	creating = false
	refresh()

	if ok then
		NotifyController.Show("Grupo criado! Chame a galera e aperte Iniciar.", "success", 4)
		Lobby.Open("Party", "Joining")
	end
end

-------------------------------------------------------------------------------
-- Montagem da janela
-------------------------------------------------------------------------------

-- Cartão de um mapa (botão grande com nome, ato, descrição, recorde e situação).
local function buildMapCard(parent, mapId, order)
	local def = Lobby.GetMapDef(mapId)
	local color = Lobby.GetMapColor(mapId)

	local button = UIKit.Button({
		Name = mapId,
		Text = "",
		Color = UIKit.Darken(color, 0.3),
		Size = UDim2.fromOffset(MAP_CARD_WIDTH, MAP_CARD_HEIGHT),
		LayoutOrder = order,
		CornerRadius = 16,
		Parent = parent,
	}, function()
		onMapClicked(mapId)
	end)

	-- Imagem do mapa (se o dono colocou uma em Config.Maps).
	if type(def.Image) == "string" and def.Image ~= "" then
		local image = UIKit.New("ImageLabel", {
			Name = "Image",
			Size = UDim2.new(1, 0, 0, 70),
			Position = UDim2.fromOffset(0, 32),
			BackgroundTransparency = 1,
			Image = def.Image,
			ImageTransparency = 0.15,
			ScaleType = Enum.ScaleType.Crop,
			Parent = button,
		})
		UIKit.Corner(image, 10)
	end

	Lobby.Tag({
		Name = "Act",
		Text = "ATO " .. tostring(def.Act),
		Color = UIKit.Darken(color, 0.55),
		Height = 24,
		TextSize = 14,
		Position = UDim2.fromOffset(0, 6),
		Parent = button,
	})
	local check = Lobby.Tag({
		Name = "Check",
		Text = "Escolhido",
		Color = Theme.Rare,
		TextColor = Theme.TextDark,
		Height = 24,
		TextSize = 14,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 6),
		Visible = false,
		Parent = button,
	})

	local hasImage = type(def.Image) == "string" and def.Image ~= ""
	local textTop = hasImage and 104 or 36
	UIKit.Label({
		Name = "MapName",
		Text = def.DisplayName,
		Title = true,
		TextSize = 22,
		Position = UDim2.fromOffset(0, textTop),
		Size = UDim2.new(1, 0, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = button,
	})
	UIKit.Label({
		Name = "Description",
		Text = def.Description or "",
		TextSize = 12,
		Color = Theme.TextDim,
		Position = UDim2.fromOffset(0, textTop + 30),
		-- Termina antes da linha do recorde e da etiqueta de situação.
		Size = UDim2.new(1, 0, 1, -(textTop + 30 + 36 + RECORD_HEIGHT)),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = button,
	})
	local record = UIKit.Label({
		Name = "Record",
		Text = "",
		TextSize = 13,
		Color = Theme.Coin,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -34),
		Size = UDim2.new(1, 0, 0, RECORD_HEIGHT),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = button,
	})
	local status = Lobby.Tag({
		Name = "Status",
		Text = "",
		Height = 26,
		TextSize = 14,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -4),
		Parent = button,
	})

	-- Véu escuro com cadeado e o requisito (mapa trancado).
	local overlay = UIKit.New("Frame", {
		Name = "LockOverlay",
		Size = UDim2.new(1, 20, 1, 8),
		Position = UDim2.fromOffset(-10, -4),
		BackgroundColor3 = Theme.Backdrop,
		BackgroundTransparency = 0.25,
		ZIndex = 5,
		Visible = false,
		Parent = button,
	})
	UIKit.Corner(overlay, 16)
	Lobby.LockIcon(overlay, 46, Theme.TextDim, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		ZIndex = 6,
	})
	UIKit.Label({
		Name = "Requirement",
		Text = Lobby.GetMapRequirement(mapId),
		TextSize = 15,
		Color = Theme.Text,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.56),
		Size = UDim2.new(1, -20, 0, 44),
		ZIndex = 6,
		Parent = overlay,
	})

	return { Button = button, Check = check, Status = status, Record = record, LockOverlay = overlay, Color = color }
end

local function build()
	window = UIKit.Window(WINDOW_NAME, "Criar Partida", WINDOW_SIZE)
	local content = window.Content
	Lobby.PrepareContent(content)
	ui = { MapCards = {}, PlayerButtons = {}, PrivacyButtons = {} }

	-- 1. Mapa.
	local mapSection = Lobby.Section(content, "1. Escolha o mapa", 1)
	local cardsRow = UIKit.New("Frame", {
		Name = "Maps",
		Size = UDim2.new(1, 0, 0, MAP_CARD_HEIGHT + 8),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = mapSection,
	})
	local cardsLayout = UIKit.List(cardsRow, 10, "Horizontal")
	cardsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	for index, mapId in ipairs(Maps.Order) do
		if Lobby.GetMapDef(mapId) then
			ui.MapCards[mapId] = buildMapCard(cardsRow, mapId, index)
		end
	end

	-- 2. Máximo de jogadores.
	local playersSection = Lobby.Section(content, "2. Máximo de jogadores", 2)
	local playersRow = Lobby.Row(playersSection, PLAYER_BUTTON_SIZE.Y.Offset + 4, 1, 8)
	for n = LobbyConfig.MinMaxPlayers, LobbyConfig.MaxPlayersLimit do
		ui.PlayerButtons[n] = UIKit.Button({
			Name = "Players" .. n,
			Text = tostring(n),
			Size = PLAYER_BUTTON_SIZE,
			LayoutOrder = n,
			TextSize = 24,
			Parent = playersRow,
		}, function()
			selection.MaxPlayers = n
			refresh()
		end)
	end
	ui.PlayersHint = UIKit.Label({
		Name = "Hint",
		Text = "",
		TextSize = 15,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = playersSection,
	})

	-- 3. Privacidade.
	local privacySection = Lobby.Section(content, "3. Privacidade", 3)
	local privacyRow = Lobby.Row(privacySection, PRIVACY_BUTTON_SIZE.Y.Offset + 4, 1, 10)
	for index, privacy in ipairs(Lobby.PrivacyOrder) do
		ui.PrivacyButtons[privacy] = UIKit.Button({
			Name = privacy,
			Text = Lobby.GetPrivacyName(privacy),
			Size = PRIVACY_BUTTON_SIZE,
			LayoutOrder = index,
			TextSize = 20,
			Parent = privacyRow,
		}, function()
			selection.Privacy = privacy
			refresh()
		end)
	end
	ui.PrivacyHint = UIKit.Label({
		Name = "Hint",
		Text = "",
		TextSize = 15,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 2,
		Parent = privacySection,
	})

	-- 4. Partida salva.
	ui.ResumeSection = Lobby.Section(content, "Partida salva", 4)
	ui.ResumeText = UIKit.Label({
		Name = "Text",
		Text = "",
		TextSize = 15,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		Parent = ui.ResumeSection,
	})
	local resumeRow = Lobby.Row(ui.ResumeSection, 50, 2, 10)
	ui.ResumeYes = UIKit.Button({
		Name = "Resume",
		Text = "Continuar partida salva",
		Size = UDim2.fromOffset(270, 46),
		LayoutOrder = 1,
		TextSize = 19,
		Parent = resumeRow,
	}, function()
		selection.Resume = true
		refresh()
	end)
	ui.ResumeNo = UIKit.Button({
		Name = "Fresh",
		Text = "Começar do zero",
		Size = UDim2.fromOffset(220, 46),
		LayoutOrder = 2,
		TextSize = 19,
		Parent = resumeRow,
	}, function()
		selection.Resume = false
		refresh()
	end)

	-- Resumo + botão grande de criar.
	ui.Summary = UIKit.Label({
		Name = "Summary",
		Text = "",
		TextSize = 16,
		Color = Theme.TextDim,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 9,
		Parent = content,
	})
	ui.CreateButton = UIKit.Button({
		Name = "Create",
		Text = "Criar grupo!",
		Color = Theme.Success,
		Size = UDim2.fromOffset(320, 60),
		LayoutOrder = 10,
		TextSize = 30,
		Parent = content,
	}, create)
end

-- Escuta mudanças enquanto a janela está aberta.
local function startListening()
	listenTrove:Clean()
	listenTrove:Add(StateController.OnChanged("Profile", function()
		refresh()
	end))
	listenTrove:Add(Lobby.PartyChanged:Connect(function()
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

-- Abre a janela (ou a do grupo, se o jogador já está num grupo).
function LobbyCreate.Open()
	if not getLobby() then
		return
	end
	if Lobby.GetMyParty() then
		Lobby.Open("Party")
		return
	end
	ensureWindow()
	refresh()
	if not window.IsOpen() then
		window.Content.CanvasPosition = Vector2.zero
		window.Open()
	end
end

function LobbyCreate.Close()
	if window then
		window.Close()
	end
end

function LobbyCreate.IsOpen()
	return window ~= nil and window.IsOpen()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function LobbyCreate.Init(lobby)
	if type(lobby) == "table" and lobby.GetPartyState then
		Lobby = lobby
	else
		getLobby()
	end
end

function LobbyCreate.Start() end

return LobbyCreate
