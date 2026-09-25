--!nonstrict
-- CoinService: as moedas físicas que caem no chão quando um brainrot morre.
--
--   CoinService.SpawnCoins(totalValue, position, opts?)
--       Divide o valor em peças (tiers do Config/Coins), cria as moedas em workspace.Coins
--       e joga elas para cima. Com DropMode = "Crate" elas caem perto do caixote
--       (ctx.CoinDropPoint); com "OnDeath", onde o brainrot morreu.
--       opts = {AtPosition = true, Scatter = studs?}: cai em "position" mesmo no modo
--       "Crate" (usado pela chuva de moedas do admin, ":coinrain").
--
-- Um laço de 10 Hz cuida de:
--   * ancorar as moedas depois que param de quicar (SettleTime);
--   * coletar quando um personagem vivo passa perto (PickupRadius);
--   * ímã: moedas perto de um jogador (MagnetRadius do time, ou o raio do game pass
--     "AutoCollect") deslizam até ele;
--   * coleta automática (stat AutoCollect >= 1): depois de AutoCollectDelay s a moeda
--     vai para o jogador vivo mais perto;
--   * sumir com moedas velhas (DespawnTime), menos quando a coleta automática está ligada;
--   * fundir a moeda mais velha na vizinha mais próxima quando passa de MaxCoinsOnGround.
--
-- Os créditos de um mesmo tique são somados por jogador: uma chamada de
-- MatchService.AddCoins(player, total, "Pickup") e um CoinPopup por jogador a cada 0,1 s.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local GameConfig = require(ConfigFolder:WaitForChild("Game"))
local CoinsConfig = require(ConfigFolder:WaitForChild("Coins"))
local Net = require(UtilFolder:WaitForChild("Net"))
local Trove = require(UtilFolder:WaitForChild("Trove"))

-- Outros serviços: só dentro de funções (regra anti-require-circular).
-- Guardamos o módulo depois do primeiro require para não repetir o WaitForChild no laço.
local Services = script.Parent
local serviceCache = {}
local function Svc(name)
	local service = serviceCache[name]
	if not service then
		service = require(Services:WaitForChild(name))
		serviceCache[name] = service
	end
	return service
end

-------------------------------------------------------------------------------
-- Constantes técnicas (não são balanceamento; os números de jogo ficam no Config/Coins)
-------------------------------------------------------------------------------

local TICK_INTERVAL = 0.1 -- laço de 10 Hz
local COIN_THICKNESS_RATIO = 0.22 -- espessura da moeda em relação ao diâmetro
local NEON_TIER_INDEX = 4 -- a partir da Esmeralda, a moeda brilha (Neon)
local MAX_EXTRA_SIZE = 1.6 -- moedas acima do maior tier crescem até 60% a mais
local SPAWN_HEIGHT = 2.5 -- altura (acima do ponto de queda) onde as moedas aparecem
local LAUNCH_UP_MIN, LAUNCH_UP_MAX = 26, 36 -- velocidade para cima (studs/s)
local ON_DEATH_SCATTER = 3 -- espalhamento no modo "OnDeath" (studs)
local START_SPREAD_FRACTION = 0.3 -- as moedas nascem numa roda menor e voam até a área final
local SPIN_SPEED = 8 -- giro aleatório (rad/s) ao cair
local PICKUP_VERTICAL_RANGE = 6 -- diferença de altura aceita entre o jogador e a moeda
local FALL_LIMIT = 25 -- abaixo do chão mais que isso = caiu do mapa; volta para o ponto de queda
local POPUP_HEIGHT = 2 -- altura do número flutuante acima do jogador (coleta automática)
local SETTLE_SPEED = 1.5 -- abaixo desta velocidade (studs/s) a moeda "parou" e pode ser ancorada
local SETTLE_MAX_EXTRA = 2 -- se ainda estiver rolando/caindo, espera no máximo mais 2 s e ancora
-- O "corpo" do personagem, medido a partir do HumanoidRootPart: dos pés até a cabeça.
-- Usado para medir o alcance do ímã até o jogador (e não até o centro do tronco).
local BODY_BELOW_ROOT = 3.5
local BODY_ABOVE_ROOT = 2

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local CoinService = {}

-- Cada moeda: {Part, Value, SpawnTime, SettleAt, Anchored}
-- A lista fica em ordem de criação (a primeira é a mais velha).
local coins = {}
local folder = nil
local started = false
local lastTeamStats = nil

local rng = Random.new()
local trove = Trove.new()

-- Tiers em ordem crescente de valor (cópia ordenada, por segurança).
local tiers = table.clone(CoinsConfig.Tiers)
table.sort(tiers, function(a, b)
	return a.Value < b.Value
end)
local lowestTier = tiers[1]
local highestTier = tiers[#tiers]

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

local function now()
	return workspace:GetServerTimeNow()
end

-- Número "de verdade" (nem NaN nem infinito).
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Lê um stat numérico com valor padrão.
local function stat(stats, key, default)
	local value = stats and stats[key]
	if isFiniteNumber(value) then
		return value
	end
	return default
end

-- Pega (ou cria) a pasta workspace.Coins (o MatchService normalmente já criou).
local function ensureFolder()
	if folder and folder.Parent then
		return folder
	end
	local existing = workspace:FindFirstChild("Coins")
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		folder = Instance.new("Folder")
		folder.Name = "Coins"
		folder.Parent = workspace
	end
	return folder
end

-- Contexto do mapa (ou nil se ainda não existe).
local function getContext()
	local ok, ctx = pcall(function()
		return Svc("MatchService").GetContext()
	end)
	if ok and type(ctx) == "table" then
		return ctx
	end
	return nil
end

-- Stats do time (com proteção: se o StatService falhar, usa o último valor bom).
local function getTeamStats()
	local ok, stats = pcall(function()
		return Svc("StatService").GetTeam()
	end)
	if ok and type(stats) == "table" then
		lastTeamStats = stats
		return stats
	end
	return lastTeamStats or {}
end

-- O jogador tem o game pass de coleta automática?
local function hasAutoCollectPass(player)
	local ok, result = pcall(function()
		return Svc("MonetizationService").HasPass(player, "AutoCollect")
	end)
	return ok and result == true
end

-- Ponto aleatório dentro de um círculo de raio "radius" (distribuição uniforme).
local function randomInDisc(radius)
	local angle = rng:NextNumber(0, math.pi * 2)
	local distance = math.sqrt(rng:NextNumber()) * radius
	return Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

-------------------------------------------------------------------------------
-- Tiers e aparência
-------------------------------------------------------------------------------

-- Índice do maior tier cujo valor cabe em "value" (no mínimo o primeiro).
local function tierIndexForValue(value)
	local index = 1
	for i, tier in ipairs(tiers) do
		if value >= tier.Value then
			index = i
		else
			break
		end
	end
	return index
end

-- Divide o valor total em peças:
--   * acima do maior tier: UMA moeda do maior tier leva o valor inteiro;
--   * senão, sempre o maior tier que cabe, até MaxPiecesPerDeath peças;
--   * a última peça leva o resto (e sobrinhas menores que 1 moeda vão para a última peça).
local function splitValue(total)
	if total >= highestTier.Value then
		return { total }
	end
	local maxPieces = math.max(1, math.floor(CoinsConfig.MaxPiecesPerDeath))
	local pieces = {}
	local remaining = total
	while #pieces < maxPieces - 1 and remaining >= lowestTier.Value do
		local tier = tiers[tierIndexForValue(remaining)]
		table.insert(pieces, tier.Value)
		remaining -= tier.Value
	end
	if remaining > 1e-9 then
		if #pieces > 0 and remaining < lowestTier.Value then
			pieces[#pieces] += remaining
		else
			table.insert(pieces, remaining)
		end
	end
	return pieces
end

-- Pinta e dimensiona a moeda de acordo com o valor dela (tier).
local function styleCoin(part, value)
	local index = tierIndexForValue(value)
	local tier = tiers[index]

	-- Moedas acima do maior tier ficam um pouco maiores conforme o valor cresce.
	local extra = 1
	if index == #tiers and value > tier.Value then
		extra = math.min(MAX_EXTRA_SIZE, 1 + 0.12 * math.log10(value / tier.Value))
	end
	local diameter = tier.Size * extra

	-- Cilindro deitado: o eixo X é a espessura; Y e Z são o diâmetro.
	part.Size = Vector3.new(diameter * COIN_THICKNESS_RATIO, diameter, diameter)
	part.Color = tier.Color
	if index >= NEON_TIER_INDEX then
		part.Material = Enum.Material.Neon
		part.Reflectance = 0
	else
		part.Material = Enum.Material.Metal
		part.Reflectance = 0.3
	end
	part:SetAttribute("Value", value)
	part:SetAttribute("Tier", tier.Name)
end

-- Cria a Part de uma moeda (ainda sem pai).
local function createCoinPart(value)
	local part = Instance.new("Part")
	part.Name = "Coin"
	part.Shape = Enum.PartType.Cylinder
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CastShadow = false
	part.Anchored = false
	part.CanCollide = true -- precisa colidir com o chão para quicar e parar
	part.CanTouch = false -- a coleta é por distância, não por Touched
	part.CanQuery = false -- balas e raycasts atravessam
	part.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.9, 0.25, 1, 1)
	part.CollisionGroup = "Coins"
	styleCoin(part, value)
	return part
end

-- Ponto de queda das moedas (caixote ou onde o brainrot morreu) e o espalhamento.
local function getDropArea(position)
	local ctx = getContext()
	local cratePoint = ctx and ctx.CoinDropPoint
	local hasCrate = typeof(cratePoint) == "Vector3"
	if CoinsConfig.DropMode == "Crate" and hasCrate then
		return cratePoint, CoinsConfig.CrateScatter
	end
	if typeof(position) == "Vector3" and isFiniteNumber(position.X) and isFiniteNumber(position.Y) and isFiniteNumber(position.Z) then
		return position, ON_DEATH_SCATTER
	end
	if hasCrate then
		return cratePoint, CoinsConfig.CrateScatter
	end
	return nil, 0
end

-- Para a moeda e ancora (depois de assentar, ou quando o ímã assume o controle).
local function anchorCoin(coin)
	local part = coin.Part
	coin.Anchored = true
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part.Anchored = true
	part.CanCollide = false

	-- Caiu do mapa (atravessou o chão)? Volta para perto do ponto de queda.
	local ctx = getContext()
	if ctx and isFiniteNumber(ctx.GroundY) and part.Position.Y < ctx.GroundY - FALL_LIMIT then
		local center = getDropArea(nil)
		if center then
			part.CFrame = CFrame.new(center + randomInDisc(2) + Vector3.new(0, 1, 0)) * part.CFrame.Rotation
		end
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- CoinService.SpawnCoins(totalValue, position, opts?)
--   opts.AtPosition = true -> solta em "position" (ignora o caixote do modo "Crate")
--   opts.Scatter = número  -> raio do espalhamento em studs (padrão: o do modo "OnDeath")
function CoinService.SpawnCoins(totalValue, position, opts)
	if not isFiniteNumber(totalValue) or totalValue <= 0 then
		return
	end
	local center, scatter
	local validPosition = typeof(position) == "Vector3"
		and isFiniteNumber(position.X)
		and isFiniteNumber(position.Y)
		and isFiniteNumber(position.Z)
	if type(opts) == "table" and opts.AtPosition == true and validPosition then
		center = position
		scatter = if isFiniteNumber(opts.Scatter) then math.max(0, opts.Scatter) else ON_DEATH_SCATTER
	else
		center, scatter = getDropArea(position)
	end
	if not center then
		warn("[CoinService] Sem lugar para soltar as moedas (sem CoinDropPoint e sem posição).")
		return
	end

	local parent = ensureFolder()
	local t = now()
	local gravity = math.max(1, workspace.Gravity)

	for _, value in ipairs(splitValue(totalValue)) do
		local part = createCoinPart(value)

		-- Sorteia onde a moeda vai cair (dentro do espalhamento) e nasce mais perto do centro.
		local landing = randomInDisc(scatter)
		local start = landing * START_SPREAD_FRACTION
		part.CFrame = CFrame.new(center + start + Vector3.new(0, SPAWN_HEIGHT, 0))
			* CFrame.Angles(rng:NextNumber(0, math.pi * 2), rng:NextNumber(0, math.pi * 2), 0)
		part.Parent = parent

		-- Física no servidor (o cliente não pode "puxar" moedas para si).
		pcall(function()
			part:SetNetworkOwner(nil)
		end)

		-- Velocidade para cima + para o lado, calculada para chegar perto do ponto sorteado.
		local upSpeed = rng:NextNumber(LAUNCH_UP_MIN, LAUNCH_UP_MAX)
		local flightTime = 2 * upSpeed / gravity
		local horizontal = (landing - start) / flightTime
		part.AssemblyLinearVelocity = Vector3.new(horizontal.X, upSpeed, horizontal.Z)
		part.AssemblyAngularVelocity = Vector3.new(
			rng:NextNumber(-SPIN_SPEED, SPIN_SPEED),
			rng:NextNumber(-SPIN_SPEED, SPIN_SPEED),
			rng:NextNumber(-SPIN_SPEED, SPIN_SPEED)
		)

		table.insert(coins, {
			Part = part,
			Value = value,
			SpawnTime = t,
			SettleAt = t + CoinsConfig.SettleTime,
			Anchored = false,
		})
	end
end

-------------------------------------------------------------------------------
-- Laço de 10 Hz
-------------------------------------------------------------------------------

-- Jogadores que podem pegar moedas agora: vivos, com personagem e com run carregado.
-- {Player, Position, Magnet (raio do ímã), Gained (moedas deste tique), PopupPosition}
local function getCollectors(teamStats)
	local list = {}
	local MatchService = Svc("MatchService")
	local teamMagnet = math.max(0, stat(teamStats, "MagnetRadius", 0))
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character and MatchService.GetRun(player) then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				local magnet = teamMagnet
				if hasAutoCollectPass(player) then
					magnet = math.max(magnet, GameConfig.GamepassAutoCollectRadius)
				end
				table.insert(list, {
					Player = player,
					Position = root.Position,
					Magnet = magnet,
					Gained = 0,
					PopupPosition = nil,
				})
			end
		end
	end
	return list
end

-- O jogador (posição da raiz do personagem) alcança a moeda?
local function isInPickupRange(rootPosition, coinPosition, radius)
	local dx = rootPosition.X - coinPosition.X
	local dz = rootPosition.Z - coinPosition.Z
	return dx * dx + dz * dz <= radius * radius and math.abs(rootPosition.Y - coinPosition.Y) <= PICKUP_VERTICAL_RANGE
end

-- Distância da moeda até o corpo do jogador (um segmento vertical dos pés até a cabeça).
-- Assim uma moeda no chão, bem ao lado do jogador, conta pela distância no plano.
local function distanceToBody(rootPosition, position)
	local dx = rootPosition.X - position.X
	local dz = rootPosition.Z - position.Z
	local dy = 0
	if position.Y < rootPosition.Y - BODY_BELOW_ROOT then
		dy = rootPosition.Y - BODY_BELOW_ROOT - position.Y
	elseif position.Y > rootPosition.Y + BODY_ABOVE_ROOT then
		dy = position.Y - rootPosition.Y - BODY_ABOVE_ROOT
	end
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Jogador mais perto da posição. "withinMagnet" = só quem tem ímã alcançando a moeda.
local function nearestCollector(collectors, position, withinMagnet)
	local best, bestDistance = nil, math.huge
	for _, collector in ipairs(collectors) do
		local distance = distanceToBody(collector.Position, position)
		if distance < bestDistance and (not withinMagnet or (collector.Magnet > 0 and distance <= collector.Magnet)) then
			best, bestDistance = collector, distance
		end
	end
	return best
end

-- Guarda o valor da moeda para o jogador (o crédito é feito no fim do tique).
local function credit(collector, coin, popupPosition)
	collector.Gained += coin.Value
	collector.PopupPosition = popupPosition
end

-- Funde as moedas mais velhas nas vizinhas mais próximas até caber no limite.
local function mergeOverflow()
	local maxCoins = math.max(1, math.floor(CoinsConfig.MaxCoinsOnGround))
	while #coins > maxCoins and #coins >= 2 do
		local oldest = table.remove(coins, 1)
		local oldPosition = oldest.Part.Position
		local best, bestDistance = nil, math.huge
		for _, other in ipairs(coins) do
			local distance = (other.Part.Position - oldPosition).Magnitude
			if distance < bestDistance then
				best, bestDistance = other, distance
			end
		end
		if best then
			best.Value += oldest.Value
			styleCoin(best.Part, best.Value)
		end
		oldest.Part:Destroy()
	end
end

local function tick(dt)
	if #coins == 0 then
		return
	end
	local t = now()
	local teamStats = getTeamStats()
	local autoCollect = stat(teamStats, "AutoCollect", 0) >= 1
	local collectors = getCollectors(teamStats)
	local pickupRadius = CoinsConfig.PickupRadius
	local pullStep = CoinsConfig.MagnetPullSpeed * dt

	-- Monta a nova lista só com as moedas que continuam no chão (mantém a ordem de idade).
	local kept = {}
	for _, coin in ipairs(coins) do
		local part = coin.Part
		local remove = false

		if not part.Parent then
			remove = true -- foi destruída por fora (ex.: caiu abaixo do FallenPartsDestroyHeight)
		else
			-- 1. Assentou: ancora (economiza física). Depois de SettleTime, ancora assim que
			--    a moeda parar; se ainda estiver caindo/rolando, espera no máximo SETTLE_MAX_EXTRA
			--    (evita congelar a moeda no ar se ela caiu de um lugar alto).
			if not coin.Anchored and t >= coin.SettleAt then
				local speed = part.AssemblyLinearVelocity.Magnitude
				if speed <= SETTLE_SPEED or t >= coin.SettleAt + SETTLE_MAX_EXTRA then
					anchorCoin(coin)
				end
			end
			local position = part.Position

			-- 2. Alguém passou por cima?
			local picker = nil
			for _, collector in ipairs(collectors) do
				if isInPickupRange(collector.Position, position, pickupRadius) then
					picker = collector
					break
				end
			end

			if picker then
				credit(picker, coin, position)
				remove = true
			elseif autoCollect and #collectors > 0 and t - coin.SpawnTime >= CoinsConfig.AutoCollectDelay then
				-- 3. Coleta automática: vai para o jogador vivo mais perto.
				local target = nearestCollector(collectors, position, false)
				credit(target, coin, target.Position + Vector3.new(0, POPUP_HEIGHT, 0))
				remove = true
			else
				-- 4. Ímã: desliza até o jogador (se ele tiver ímã alcançando a moeda).
				local target = nearestCollector(collectors, position, true)
				if target then
					if not coin.Anchored then
						anchorCoin(coin)
					end
					local delta = target.Position - position
					local distance = delta.Magnitude
					local newPosition = if distance <= pullStep then target.Position else position + delta.Unit * pullStep
					part.CFrame = CFrame.new(newPosition) * part.CFrame.Rotation
					if isInPickupRange(target.Position, newPosition, pickupRadius) then
						credit(target, coin, newPosition)
						remove = true
					end
				elseif not autoCollect and t - coin.SpawnTime >= CoinsConfig.DespawnTime then
					-- 5. Velha demais e ninguém pegou: some.
					remove = true
				end
			end
		end

		if remove then
			if part.Parent then
				part:Destroy()
			end
		else
			table.insert(kept, coin)
		end
	end
	coins = kept

	-- Credita tudo que cada jogador pegou neste tique (uma vez por jogador).
	if #collectors > 0 then
		local MatchService = Svc("MatchService")
		for _, collector in ipairs(collectors) do
			if collector.Gained > 0 then
				local ok, credited = pcall(MatchService.AddCoins, collector.Player, collector.Gained, "Pickup")
				if ok then
					-- Mostra o valor realmente creditado (ex.: com 2× moedas), se o MatchService devolver.
					local shown = if isFiniteNumber(credited) and credited > 0 then credited else collector.Gained
					Net.FireClient(collector.Player, "CoinPopup", shown, collector.PopupPosition or collector.Position)
				else
					warn("[CoinService] Erro ao creditar moedas: " .. tostring(credited))
				end
			end
		end
	end

	-- Muitas moedas no chão: funde as mais velhas.
	mergeOverflow()
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function CoinService.Init()
	ensureFolder()
end

function CoinService.Start()
	if started then
		return
	end
	started = true

	trove:Add(task.spawn(function()
		local dt = TICK_INTERVAL
		while true do
			local ok, err = pcall(tick, math.clamp(dt, 0.01, 1))
			if not ok then
				warn("[CoinService] Erro no laço: " .. tostring(err))
			end
			dt = task.wait(TICK_INTERVAL)
		end
	end))
end

return CoinService
