-- LobbyService: monta o mapa do lobby, cuida do placar de líderes e do botão "Reconectar".
--
-- Seção 9.1 da especificação:
--   Init:  ctx = MapBuilder.Build("Lobby")
--          placar = OrderedDataStore Config.Lobby.LeaderboardStoreName
--          pontuação = floor(log10(TotalCoins + 1) * 1e6)
--            (as moedas podem passar de 2^63, o limite do OrderedDataStore; guardando o
--             log10 multiplicado por 1 milhão, a ordem continua certa e o número cabe)
--          grava na entrada, ao sair e a cada LeaderboardRefresh segundos
--          lê o top LeaderboardSize e escreve no SurfaceGui "Board" (Frame "List") do
--          ctx.Leaderboard: nome + moedas (Abbrev(10^(score/1e6) - 1)), com cache de nomes
--   Request "Reconnect" -> TravelService.Reconnect(player)
--
-- No Studio sem acesso às APIs, o OrderedDataStore falha: nesse caso o placar mostra
-- só os jogadores que passaram por este servidor (guardados em memória).

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig = require(Shared.Config.Lobby)
local Net = require(Shared.Util.Net)
local NumberFormat = require(Shared.Util.NumberFormat)
local Trove = require(Shared.Util.Trove)

local DataService = require(script.Parent:WaitForChild("DataService"))

-- Outros serviços só são pegos dentro de funções (regra anti-require-circular).
local Services = script.Parent
local function Svc(name)
	return require(Services:WaitForChild(name))
end

local LobbyService = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- A pontuação guarda log10(moedas + 1) com 6 casas "decimais" (× 1 milhão).
local SCORE_SCALE = 1e6

-- Constantes técnicas do placar.
local NAME_FETCH_TIMEOUT = 8 -- tempo máximo esperando os nomes (s)
local NAME_RETRY_AFTER = 120 -- nome que falhou: tenta buscar de novo depois disso (s)
local SOON_REFRESH_DELAY = 5 -- depois que alguém entra, atualiza o quadro em ~5 s
local MIN_READ_SPACING = 15 -- intervalo mínimo entre duas leituras do placar (s)
local ROW_GAP = 4 -- espaço entre as linhas do quadro (pixels)
local ROW_ATTRIBUTE = "LeaderboardRow" -- marca as linhas criadas por este serviço
local MODULE_WAIT_TIMEOUT = 10 -- espera máxima pelo módulo MapBuilder (s)

-- Limite do Request "Reconnect" (teleporte é pesado: 1 a cada 2 s, rajada de 2).
local RECONNECT_RATE = { Rate = 0.5, Burst = 2 }

-- Cores do quadro.
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_COINS = Color3.fromRGB(255, 220, 90)
local COLOR_ROW_A = Color3.fromRGB(40, 24, 60)
local COLOR_ROW_B = Color3.fromRGB(58, 34, 84)
local RANK_COLORS = {
	[1] = Color3.fromRGB(255, 205, 50), -- ouro
	[2] = Color3.fromRGB(210, 215, 225), -- prata
	[3] = Color3.fromRGB(215, 140, 80), -- bronze
}

-- Mensagens (português do Brasil).
local MSG_EMPTY_BOARD = "Ninguém no placar ainda. Seja o primeiro!"
local MSG_UNAVAILABLE = "Placar indisponível no momento."
local MSG_UNKNOWN_PLAYER = "Jogador %d"

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local trove = Trove.new() -- conexões do serviço
local ctx = nil -- contexto do mapa do lobby (MapBuilder.Build("Lobby"))
local orderedStore = nil -- OrderedDataStore do placar (nil = indisponível)
local storeWarned = false -- já avisamos no Output que o placar falhou?

local lastWritten = {} -- [userId] = última pontuação gravada por este servidor
local memoryScores = {} -- [userId] = pontuação (reserva em memória quando o DataStore falha)
local nameCache = {} -- [userId] = nome do jogador
local nameFailedAt = {} -- [userId] = os.clock() da última falha ao buscar o nome
local hasRendered = false -- já desenhamos o quadro pelo menos uma vez com dados reais?
local lastReadAt = -math.huge -- os.clock() da última leitura do placar
local refreshRunning = false -- evita duas atualizações do quadro ao mesmo tempo
local soonScheduled = false -- já tem uma atualização "em breve" marcada?

-------------------------------------------------------------------------------
-- Ajudantes gerais
-------------------------------------------------------------------------------

-- Número "de verdade": não é NaN nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Avisa no Output uma vez só que o placar deu problema.
local function warnStoreOnce(err)
	if storeWarned then
		return
	end
	storeWarned = true
	warn("[LobbyService] Placar de líderes indisponível (usando só os jogadores deste servidor): " .. tostring(err))
end

-- Pontuação a partir das moedas totais: floor(log10(moedas + 1) * 1e6).
local function scoreFromCoins(totalCoins)
	if not isFiniteNumber(totalCoins) or totalCoins <= 0 then
		return 0
	end
	return math.max(0, math.floor(math.log10(totalCoins + 1) * SCORE_SCALE))
end

-- Moedas a partir da pontuação (o inverso): 10^(score/1e6) - 1.
local function coinsFromScore(score)
	if not isFiniteNumber(score) or score <= 0 then
		return 0
	end
	return math.max(0, 10 ^ (score / SCORE_SCALE) - 1)
end

-- Pontuação atual de um jogador, lida do perfil (nil se o perfil não carregou).
local function getPlayerScore(player)
	local profile = DataService.GetProfile(player)
	if type(profile) ~= "table" or type(profile.Stats) ~= "table" then
		return nil
	end
	return scoreFromCoins(profile.Stats.TotalCoins)
end

-------------------------------------------------------------------------------
-- Mapa do lobby
-------------------------------------------------------------------------------

-- Constrói o lobby com o MapBuilder. Protegido: se falhar, o resto do serviço
-- (placar gravando, Reconectar) continua funcionando.
local function buildLobby()
	local ok, result = pcall(function()
		-- Espera no máximo alguns segundos: se o módulo não existir, não trava o Main.
		local world = ServerScriptService:WaitForChild("World", MODULE_WAIT_TIMEOUT)
		local module = world and world:WaitForChild("MapBuilder", MODULE_WAIT_TIMEOUT)
		if not module then
			error("World/MapBuilder não encontrado")
		end
		local MapBuilder = require(module)
		return MapBuilder.Build("Lobby")
	end)
	if not ok then
		warn("[LobbyService] Erro ao construir o lobby: " .. tostring(result))
		return nil
	end
	if type(result) ~= "table" then
		warn("[LobbyService] MapBuilder.Build(\"Lobby\") não devolveu um contexto.")
		return nil
	end
	return result
end

-- Leva um personagem que já existia (nasceu antes do mapa) para o spawn do lobby.
local function moveCharacterToSpawn(character)
	if not ctx or typeof(ctx.SpawnLocation) ~= "Instance" or not ctx.SpawnLocation:IsA("BasePart") then
		return
	end
	if typeof(character) ~= "Instance" or not character:IsA("Model") or not character.Parent then
		return
	end
	local spawnPart = ctx.SpawnLocation
	local offset = Vector3.new(0, spawnPart.Size.Y / 2 + 4, 0)
	pcall(function()
		character:PivotTo(CFrame.new(spawnPart.Position + offset))
	end)
end

-------------------------------------------------------------------------------
-- Quadro (SurfaceGui) do placar
-------------------------------------------------------------------------------

-- Acha o Frame "List" dentro do SurfaceGui "Board" do ctx.Leaderboard.
local function getListFrame()
	if not ctx or typeof(ctx.Leaderboard) ~= "Instance" then
		return nil
	end
	local board = ctx.Leaderboard:FindFirstChild("Board") or ctx.Leaderboard:FindFirstChild("Board", true)
	if not board then
		return nil
	end
	local list = board:FindFirstChild("List") or board:FindFirstChild("List", true)
	if list and list:IsA("GuiObject") then
		return list
	end
	return nil
end

-- Cria um TextLabel simples para uma coluna da linha.
local function makeCell(parent, name, text, color, xScale, widthScale, alignment)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(xScale, 4, 0, 0)
	label.Size = UDim2.new(widthScale, -8, 1, 0)
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextXAlignment = alignment
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = parent
	return label
end

-- Apaga as linhas antigas e garante o UIListLayout.
local function clearRows(list)
	for _, child in ipairs(list:GetChildren()) do
		if child:GetAttribute(ROW_ATTRIBUTE) then
			child:Destroy()
		end
	end
	if not list:FindFirstChildWhichIsA("UIListLayout") then
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, ROW_GAP)
		layout.Parent = list
	end
end

-- Altura de cada linha: o quadro é dividido em LeaderboardSize linhas iguais.
local function rowSize()
	local count = math.max(1, LobbyConfig.LeaderboardSize)
	return UDim2.new(1, 0, 1 / count, -ROW_GAP)
end

-- Mostra uma mensagem única no quadro (vazio ou indisponível).
local function renderMessage(text)
	local list = getListFrame()
	if not list then
		return
	end
	clearRows(list)

	local row = Instance.new("Frame")
	row.Name = "Row_Message"
	row:SetAttribute(ROW_ATTRIBUTE, true)
	row.BackgroundTransparency = 1
	row.LayoutOrder = 1
	row.Size = rowSize()
	row.Parent = list

	makeCell(row, "Message", text, COLOR_TEXT, 0, 1, Enum.TextXAlignment.Center)
end

-- Desenha as linhas: {{UserId, Score}} já em ordem (maior primeiro).
local function renderEntries(entries)
	local list = getListFrame()
	if not list then
		return
	end
	if #entries == 0 then
		renderMessage(MSG_EMPTY_BOARD)
		return
	end

	clearRows(list)
	for index, entry in ipairs(entries) do
		local row = Instance.new("Frame")
		row.Name = "Row_" .. index
		row:SetAttribute(ROW_ATTRIBUTE, true)
		row.LayoutOrder = index
		row.Size = rowSize()
		row.BorderSizePixel = 0
		row.BackgroundColor3 = if index % 2 == 1 then COLOR_ROW_A else COLOR_ROW_B
		row.BackgroundTransparency = 0.25

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = row

		local rankColor = RANK_COLORS[index] or COLOR_TEXT
		local name = nameCache[entry.UserId] or MSG_UNKNOWN_PLAYER:format(entry.UserId)
		local coinsText = NumberFormat.Abbrev(coinsFromScore(entry.Score))

		-- Colunas: posição (15%), nome (55%), moedas (30%).
		makeCell(row, "Rank", "#" .. index, rankColor, 0, 0.15, Enum.TextXAlignment.Center)
		makeCell(row, "PlayerName", name, rankColor, 0.15, 0.55, Enum.TextXAlignment.Left)
		makeCell(row, "Coins", coinsText, COLOR_COINS, 0.7, 0.3, Enum.TextXAlignment.Right)

		row.Parent = list
	end
end

-------------------------------------------------------------------------------
-- Nomes (com cache)
-------------------------------------------------------------------------------

-- Guarda o nome de quem está no servidor (não precisa pedir à Roblox).
local function cachePlayerName(player)
	nameCache[player.UserId] = player.Name
	nameFailedAt[player.UserId] = nil
end

-- Busca os nomes que faltam, em paralelo, e espera todos (ou o tempo acabar).
local function resolveNames(entries)
	local missing = {}
	for _, entry in ipairs(entries) do
		local userId = entry.UserId
		if not nameCache[userId] then
			local present = Players:GetPlayerByUserId(userId)
			if present then
				cachePlayerName(present)
			elseif userId > 0 then
				-- Só tenta de novo quem falhou há bastante tempo.
				local failedAt = nameFailedAt[userId]
				if not failedAt or os.clock() - failedAt >= NAME_RETRY_AFTER then
					table.insert(missing, userId)
				end
			end
		end
	end
	if #missing == 0 then
		return
	end

	local remaining = #missing
	for _, userId in ipairs(missing) do
		task.spawn(function()
			local ok, name = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			if ok and type(name) == "string" and name ~= "" then
				nameCache[userId] = name
				nameFailedAt[userId] = nil
			else
				nameFailedAt[userId] = os.clock()
			end
			remaining -= 1
		end)
	end

	local deadline = os.clock() + NAME_FETCH_TIMEOUT
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

-------------------------------------------------------------------------------
-- OrderedDataStore (gravar e ler)
-------------------------------------------------------------------------------

-- Pega o OrderedDataStore (uma vez). Devolve nil se o serviço não está disponível.
local function getStore()
	if orderedStore then
		return orderedStore
	end
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(LobbyConfig.LeaderboardStoreName)
	end)
	if ok and result then
		orderedStore = result
		return orderedStore
	end
	warnStoreOnce(result)
	return nil
end

-- Grava a pontuação de um jogador (se mudou desde a última gravação, ou se "force").
local function writeScore(userId, score, force)
	if type(userId) ~= "number" or not isFiniteNumber(score) then
		return
	end
	score = math.max(0, math.floor(score))
	memoryScores[userId] = score

	if not force and lastWritten[userId] == score then
		return -- nada mudou: economiza o limite de requisições do DataStore
	end

	-- Jogadores de teste do Studio têm UserId negativo: ficam só na memória.
	if userId <= 0 then
		lastWritten[userId] = score
		return
	end

	local store = getStore()
	if not store then
		return
	end
	local ok, err = pcall(function()
		store:SetAsync(tostring(userId), score)
	end)
	if ok then
		lastWritten[userId] = score
	else
		warnStoreOnce(err)
	end
end

-- Grava a pontuação atual de um jogador presente (lida do perfil).
local function writePlayerScore(player, force)
	local score = getPlayerScore(player)
	if score then
		writeScore(player.UserId, score, force)
	end
end

-- Top da reserva em memória (jogadores que passaram por este servidor).
local function readMemoryTop()
	local entries = {}
	for userId, score in pairs(memoryScores) do
		if score > 0 then
			table.insert(entries, { UserId = userId, Score = score })
		end
	end
	table.sort(entries, function(a, b)
		if a.Score ~= b.Score then
			return a.Score > b.Score
		end
		return a.UserId < b.UserId
	end)
	local size = math.max(1, LobbyConfig.LeaderboardSize)
	while #entries > size do
		table.remove(entries)
	end
	return entries
end

-- Lê o top do OrderedDataStore. Devolve a lista {{UserId, Score}} ou nil se falhou.
local function readStoreTop()
	local store = getStore()
	if not store then
		return nil
	end
	local size = math.clamp(math.floor(LobbyConfig.LeaderboardSize), 1, 100)
	local ok, result = pcall(function()
		local pages = store:GetSortedAsync(false, size)
		return pages:GetCurrentPage()
	end)
	if not ok or type(result) ~= "table" then
		warnStoreOnce(result)
		return nil
	end

	local entries = {}
	for _, item in ipairs(result) do
		local userId = tonumber(item.key)
		local score = tonumber(item.value)
		if userId and score and isFiniteNumber(score) then
			table.insert(entries, { UserId = userId, Score = score })
		end
	end
	return entries
end

-- Lê o placar e redesenha o quadro.
local function refreshBoard()
	if refreshRunning then
		return
	end
	refreshRunning = true
	lastReadAt = os.clock()

	local ok, err = pcall(function()
		local entries = readStoreTop()
		if entries then
			resolveNames(entries)
			renderEntries(entries)
			hasRendered = true
			return
		end

		-- Falhou a leitura. Se já temos um quadro com dados reais, deixamos como está
		-- (melhor mostrar o placar de um minuto atrás do que um incompleto).
		if hasRendered then
			return
		end

		-- Sem DataStore (ex.: Studio sem acesso às APIs): mostra os jogadores deste servidor.
		local memoryEntries = readMemoryTop()
		if #memoryEntries > 0 then
			resolveNames(memoryEntries)
			renderEntries(memoryEntries)
		else
			renderMessage(MSG_UNAVAILABLE)
		end
	end)
	if not ok then
		warn("[LobbyService] Erro ao atualizar o placar: " .. tostring(err))
	end

	refreshRunning = false
end

-- Marca uma atualização do quadro para daqui a pouco (junta várias entradas seguidas).
local function scheduleSoonRefresh()
	if soonScheduled then
		return
	end
	soonScheduled = true
	-- Respeita o intervalo mínimo entre leituras (limite do DataStore).
	local waitTime = math.max(SOON_REFRESH_DELAY, MIN_READ_SPACING - (os.clock() - lastReadAt))
	task.delay(waitTime, function()
		soonScheduled = false
		refreshBoard()
	end)
end

-- Ciclo periódico: grava a pontuação de quem está no servidor (se mudou) e redesenha.
local function refreshLoop()
	while true do
		task.wait(math.max(5, LobbyConfig.LeaderboardRefresh))
		for _, player in ipairs(Players:GetPlayers()) do
			local ok, err = pcall(writePlayerScore, player, false)
			if not ok then
				warn("[LobbyService] Erro ao gravar a pontuação: " .. tostring(err))
			end
		end
		refreshBoard()
	end
end

-------------------------------------------------------------------------------
-- Entrada e saída de jogadores
-------------------------------------------------------------------------------

-- Perfil carregado: grava a pontuação (sempre, na entrada) e atualiza o quadro em breve.
local function onProfileLoaded(player, _profile)
	if typeof(player) ~= "Instance" or player.Parent ~= Players then
		return
	end
	cachePlayerName(player)
	writePlayerScore(player, true)
	scheduleSoonRefresh()
end

-- Saída: grava a pontuação final (lida agora, antes do perfil ser liberado).
local function onPlayerRemoving(player)
	cachePlayerName(player)
	local score = getPlayerScore(player)
	if score then
		task.spawn(writeScore, player.UserId, score, false)
	end
end

-------------------------------------------------------------------------------
-- Request "Reconnect"
-------------------------------------------------------------------------------

-- Reconnect() -> true: volta para a última partida (TravelService cuida de tudo).
local function onReconnect(player)
	local ok, err = Svc("TravelService").Reconnect(player)
	if not ok then
		return false, if type(err) == "string" then err else "Não foi possível reconectar."
	end
	return true, true
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function LobbyService.Init()
	-- Request primeiro: mesmo que o mapa falhe, o botão "Reconectar" funciona.
	Net.Handle("Reconnect", onReconnect, RECONNECT_RATE)

	-- Monta o mapa do lobby.
	ctx = buildLobby()

	-- Quem já nasceu antes do mapa existir vai para o spawn (senão poderia cair no vazio).
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			moveCharacterToSpawn(player.Character)
		end
	end

	trove:Connect(Players.PlayerAdded, cachePlayerName)
	trove:Connect(Players.PlayerRemoving, onPlayerRemoving)
	trove:Add(DataService.ProfileLoaded:Connect(onProfileLoaded))
end

function LobbyService.Start()
	-- Jogadores que já tinham o perfil carregado antes do Start.
	for _, player in ipairs(Players:GetPlayers()) do
		cachePlayerName(player)
		if DataService.GetProfile(player) then
			task.spawn(writePlayerScore, player, true)
		end
	end

	-- Primeira leitura do quadro e ciclo periódico.
	task.spawn(refreshBoard)
	trove:Add(task.spawn(refreshLoop))
end

return LobbyService
