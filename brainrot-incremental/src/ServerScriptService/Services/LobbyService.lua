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
-- O prompt original (seção 4.1) pede TRÊS rankings: maior dinheiro total, mais brainrots
-- destruídos e atos concluídos. Então há três placares (tabela BOARDS), cada um com o seu
-- OrderedDataStore e o seu painel no lobby (ctx.Leaderboards[Id], com o mesmo formato
-- "Board" > "List"). O de moedas é o da especificação; os outros dois guardam o número
-- inteiro direto (Stats.KillsTotal e Stats.ActsCompleted cabem no OrderedDataStore).
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
-- Intervalo mínimo entre duas leituras do placar (s). Cada leitura lê os 3 placares
-- (3 GetSortedAsync), e o limite da Roblox é 5 + 2 por jogador por minuto.
local MIN_READ_SPACING = 30
local ROW_GAP = 4 -- espaço entre as linhas do quadro (pixels)
local ROW_ATTRIBUTE = "LeaderboardRow" -- marca as linhas criadas por este serviço
local MODULE_WAIT_TIMEOUT = 10 -- espera máxima pelo módulo MapBuilder (s)

-- Limite do Request "Reconnect" (teleporte é pesado: 1 a cada 2 s, rajada de 2).
local RECONNECT_RATE = { Rate = 0.5, Burst = 2 }

-- Cores do quadro.
local COLOR_TEXT = Color3.fromRGB(255, 255, 255)
local COLOR_COINS = Color3.fromRGB(255, 220, 90)
local COLOR_KILLS = Color3.fromRGB(255, 140, 140)
local COLOR_ACTS = Color3.fromRGB(140, 220, 255)
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
local storeWarned = false -- já avisamos no Output que o placar falhou?

local nameCache = {} -- [userId] = nome do jogador
local nameFailedAt = {} -- [userId] = os.clock() da última falha ao buscar o nome
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

-- Pontuação de uma contagem simples (brainrots destruídos, atos concluídos): o inteiro.
local function scoreFromCount(count)
	if not isFiniteNumber(count) or count <= 0 then
		return 0
	end
	return math.floor(count)
end

-- Os três placares. Cada um guarda também o seu estado (preenchido por newBoard):
--   Store       = OrderedDataStore (nil = ainda não pegou ou indisponível)
--   LastWritten = [userId] = última pontuação gravada por este servidor
--   Memory      = [userId] = pontuação (reserva em memória quando o DataStore falha)
--   HasRendered = já desenhamos o painel pelo menos uma vez com dados reais?
-- Id é a chave do painel em ctx.Leaderboards (o builder do lobby usa os mesmos ids).
local function newBoard(id, storeName, getScore, formatScore, scoreColor)
	return {
		Id = id,
		StoreName = storeName,
		GetScore = getScore, -- (profile.Stats) -> pontuação inteira >= 0
		FormatScore = formatScore, -- (pontuação) -> texto da coluna da direita
		ScoreColor = scoreColor,
		Store = nil,
		LastWritten = {},
		Memory = {},
		HasRendered = false,
	}
end

local BOARDS = {
	-- Maior dinheiro total (o placar da especificação, com a pontuação em log10).
	newBoard("Coins", LobbyConfig.LeaderboardStoreName, function(stats)
		return scoreFromCoins(stats.TotalCoins)
	end, function(score)
		return NumberFormat.Abbrev(coinsFromScore(score))
	end, COLOR_COINS),
	-- Mais brainrots destruídos.
	newBoard("Kills", LobbyConfig.LeaderboardStoreName .. "_Kills", function(stats)
		return scoreFromCount(stats.KillsTotal)
	end, function(score)
		return NumberFormat.Abbrev(score)
	end, COLOR_KILLS),
	-- Mais atos concluídos.
	newBoard("Acts", LobbyConfig.LeaderboardStoreName .. "_Acts", function(stats)
		return scoreFromCount(stats.ActsCompleted)
	end, function(score)
		return NumberFormat.Commas(score)
	end, COLOR_ACTS),
}

-- Estatísticas atuais de um jogador, lidas do perfil (nil se o perfil não carregou).
local function getPlayerStats(player)
	local profile = DataService.GetProfile(player)
	if type(profile) ~= "table" or type(profile.Stats) ~= "table" then
		return nil
	end
	return profile.Stats
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

-- Acha a Part do painel de um placar: ctx.Leaderboards[Id]; o de moedas também
-- pode vir de ctx.Leaderboard (o campo da especificação).
local function getBoardPart(board)
	if not ctx then
		return nil
	end
	local part = type(ctx.Leaderboards) == "table" and ctx.Leaderboards[board.Id] or nil
	if part == nil and board.Id == "Coins" then
		part = ctx.Leaderboard
	end
	if typeof(part) ~= "Instance" then
		return nil
	end
	return part
end

-- Acha o Frame "List" dentro do SurfaceGui "Board" do painel de um placar.
local function getListFrame(boardDef)
	local part = getBoardPart(boardDef)
	if not part then
		return nil
	end
	local board = part:FindFirstChild("Board") or part:FindFirstChild("Board", true)
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

-- Mostra uma mensagem única no painel (vazio ou indisponível).
local function renderMessage(board, text)
	local list = getListFrame(board)
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

-- Desenha as linhas de um placar: {{UserId, Score}} já em ordem (maior primeiro).
local function renderEntries(board, entries)
	local list = getListFrame(board)
	if not list then
		return
	end
	if #entries == 0 then
		renderMessage(board, MSG_EMPTY_BOARD)
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
		local scoreText = board.FormatScore(entry.Score)

		-- Colunas: posição (15%), nome (55%), valor (30%: moedas, brainrots ou atos).
		makeCell(row, "Rank", "#" .. index, rankColor, 0, 0.15, Enum.TextXAlignment.Center)
		makeCell(row, "PlayerName", name, rankColor, 0.15, 0.55, Enum.TextXAlignment.Left)
		makeCell(row, "Score", scoreText, board.ScoreColor, 0.7, 0.3, Enum.TextXAlignment.Right)

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

-- Pega o OrderedDataStore de um placar (uma vez). Devolve nil se não está disponível.
local function getStore(board)
	if board.Store then
		return board.Store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(board.StoreName)
	end)
	if ok and result then
		board.Store = result
		return result
	end
	warnStoreOnce(result)
	return nil
end

-- Grava a pontuação de um jogador num placar (se mudou desde a última gravação, ou se "force").
local function writeScore(board, userId, score, force)
	if type(userId) ~= "number" or not isFiniteNumber(score) then
		return
	end
	score = math.max(0, math.floor(score))
	board.Memory[userId] = score

	if not force and board.LastWritten[userId] == score then
		return -- nada mudou: economiza o limite de requisições do DataStore
	end

	-- Jogadores de teste do Studio têm UserId negativo: ficam só na memória.
	-- Pontuação zero também não vai para o DataStore: ela nunca aparece no placar
	-- (e as estatísticas só crescem, então não há um valor antigo maior para apagar).
	if userId <= 0 or score <= 0 then
		board.LastWritten[userId] = score
		return
	end

	local store = getStore(board)
	if not store then
		return
	end
	local ok, err = pcall(function()
		store:SetAsync(tostring(userId), score)
	end)
	if ok then
		board.LastWritten[userId] = score
	else
		warnStoreOnce(err)
	end
end

-- Grava as pontuações de um jogador nos três placares (a partir das estatísticas).
local function writeStatsScores(userId, stats, force)
	for _, board in ipairs(BOARDS) do
		writeScore(board, userId, board.GetScore(stats), force)
	end
end

-- Grava as pontuações atuais de um jogador presente (lidas do perfil).
local function writePlayerScore(player, force)
	local stats = getPlayerStats(player)
	if stats then
		writeStatsScores(player.UserId, stats, force)
	end
end

-- Top da reserva em memória de um placar (jogadores que passaram por este servidor).
local function readMemoryTop(board)
	local entries = {}
	for userId, score in pairs(board.Memory) do
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

-- Lê o top do OrderedDataStore de um placar. Devolve a lista {{UserId, Score}} ou nil se falhou.
local function readStoreTop(board)
	local store = getStore(board)
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
		-- Pontuação zero não entra (ex.: "0 atos" não é um recorde para mostrar).
		if userId and score and isFiniteNumber(score) and score > 0 then
			table.insert(entries, { UserId = userId, Score = score })
		end
	end
	return entries
end

-- Lê um placar e redesenha o painel dele.
local function refreshOneBoard(board)
	local entries = readStoreTop(board)
	if entries then
		resolveNames(entries)
		renderEntries(board, entries)
		board.HasRendered = true
		return
	end

	-- Falhou a leitura. Se já temos um painel com dados reais, deixamos como está
	-- (melhor mostrar o placar de um minuto atrás do que um incompleto).
	if board.HasRendered then
		return
	end

	-- Sem DataStore (ex.: Studio sem acesso às APIs): mostra os jogadores deste servidor.
	local memoryEntries = readMemoryTop(board)
	if #memoryEntries > 0 then
		resolveNames(memoryEntries)
		renderEntries(board, memoryEntries)
	else
		renderMessage(board, MSG_UNAVAILABLE)
	end
end

-- Lê os três placares e redesenha os painéis (um erro num placar não para os outros).
local function refreshBoard()
	if refreshRunning then
		return
	end
	refreshRunning = true
	lastReadAt = os.clock()

	for _, board in ipairs(BOARDS) do
		local ok, err = pcall(refreshOneBoard, board)
		if not ok then
			warn("[LobbyService] Erro ao atualizar o placar " .. board.Id .. ": " .. tostring(err))
		end
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

-- Saída: grava as pontuações finais (lidas agora, antes do perfil ser liberado).
local function onPlayerRemoving(player)
	cachePlayerName(player)
	local stats = getPlayerStats(player)
	if stats then
		-- Copia só os números agora: depois o perfil pode ser liberado ou mudar.
		local snapshot = {
			TotalCoins = stats.TotalCoins,
			KillsTotal = stats.KillsTotal,
			ActsCompleted = stats.ActsCompleted,
		}
		task.spawn(writeStatsScores, player.UserId, snapshot, false)
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
