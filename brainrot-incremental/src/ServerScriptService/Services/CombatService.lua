--!nonstrict
-- CombatService: tudo sobre os tiros dos jogadores (seção 8.6 da especificação).
--
-- Como um tiro funciona:
--   1. O cliente (WeaponController) atira na tela dele na hora e manda o evento
--      "Fire"(origin, directions, shotId) para o servidor.
--   2. O servidor NÃO confia no cliente: confere se o personagem está vivo, se a origem
--      está perto da cabeça (com folga pela velocidade e pelo ping, no máximo 24 studs),
--      se o número de direções bate com os projéteis, se o LEQUE tem o formato certo
--      (Config.Stats.Fan: sem isso dava para mandar direções iguais e empilhar todos os
--      projéteis num alvo só), a cadência (token bucket) e o calor da arma.
--   3. Brainrots "colados" na origem (tiro à queima-roupa ou de dentro de um Gigante) são
--      achados uma vez por tiro com GetPartBoundsInRadius, porque o Spherecast não enxerga
--      peças que já começam encostadas na esfera. Depois, para cada direção, o servidor faz
--      um raio fino contra o mundo (até onde a bala vai) e um Spherecast (um "raio grosso")
--      que só enxerga os brainrots, e aplica o dano nos brainrots atingidos (com perfuração,
--      crítico, respingo e lentidão).
--   4. Manda "HitConfirm" para o atirador (hitmarker e números de dano; cada linha leva o
--      Id do brainrot) e "RemoteShot" para os outros jogadores (eles desenham o rastro da
--      bala). O RemoteShot só vai para quem está a até 400 studs, e no máximo 1 a cada
--      0,1 s por atirador para cada jogador (o resto dos tiros não é desenhado lá).
--
-- Também:
--   * resfria a arma a cada Heartbeat e manda o estado "Heat" (no máximo 10 vezes por segundo);
--   * solda um modelo simples de arma na mão direita de cada personagem (cor da skin equipada),
--     para os outros jogadores verem a arma.
--
-- API pública:
--   CombatService.Crit: Signal(player, count)  -> disparado quando um tiro teve críticos

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Módulos compartilhados (Config e Util).
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local GameConfig = require(ConfigFolder:WaitForChild("Game"))
local Weapons = require(ConfigFolder:WaitForChild("Weapons"))
local Cosmetics = require(ConfigFolder:WaitForChild("Cosmetics"))
local StatsConfig = require(ConfigFolder:WaitForChild("Stats"))

local Signal = require(UtilFolder:WaitForChild("Signal"))
local Trove = require(UtilFolder:WaitForChild("Trove"))
local Net = require(UtilFolder:WaitForChild("Net"))

-- Serviços-folha (podem ser usados no topo, regra 1.2).
local Services = script.Parent
local DataService = require(Services:WaitForChild("DataService"))
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções (regra anti-require-circular).
-- Guardamos o módulo depois do primeiro require para não repetir WaitForChild a cada quadro.
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
-- Constantes (valores da seção 8.6 e constantes técnicas)
-------------------------------------------------------------------------------
-- Origem do tiro perto da cabeça: 8 studs + o quanto a cabeça anda durante o atraso da
-- rede (velocidade × ping × 2, com o atraso entre 0,1 e 0,5 s), e nunca mais que 24 studs.
local MAX_ORIGIN_DISTANCE = 8
local MAX_ORIGIN_DISTANCE_CAP = 24
local ORIGIN_PING_FACTOR = 2
local ORIGIN_LAG_MIN = 0.1
local ORIGIN_LAG_MAX = 0.5
local FIRE_BUCKET_CAPACITY = 3 -- tiros "guardados" no token bucket da cadência
local FIRE_RATE_TOLERANCE = 1.25 -- recarga do bucket = FireRate × 1,25 (folga para o ping)
local OVERHEAT_RECOVER_FRACTION = 0.3 -- superaquecida até esfriar para 30% da capacidade
local SPLASH_DAMAGE_FRACTION = 0.5 -- respingo = 50% do dano do tiro
local HEAT_SEND_INTERVAL = 0.1 -- estado "Heat" no máximo a 10 Hz
local MIN_DIRECTION_MAGNITUDE = 1e-3 -- direção menor que isso é considerada "zero"
local MAX_COORDINATE = 1e6 -- coordenada absurda = dado inválido
local MAX_CASTS_PER_PROJECTILE = 32 -- trava de segurança do laço de perfuração
local MODEL_HEIGHT_PER_SCALE = 5 -- brainrot de escala 1 tem ~5 studs de altura
local BODY_RADIUS_FRACTION = 0.3 -- raio aproximado do corpo = 30% da altura
local MUZZLE_MAX_OFFSET = 10 -- distância máxima entre o cano (visual) e a origem real do tiro
local HAND_WAIT_TIMEOUT = 10 -- quanto esperar a mão do personagem aparecer
local PROFILE_WAIT_TIMEOUT = 30 -- quanto esperar o perfil (para saber a skin)
local RAINBOW_INTERVAL = 0.2 -- armas arco-íris mudam de cor a 5 Hz
local RAINBOW_CYCLE_SECONDS = 4 -- uma volta completa no arco-íris a cada 4 s
local GUN_MODEL_NAME = "HeldGun" -- nome do modelo da arma dentro do personagem

-- Leque (Config.Stats.Fan): abertura máxima e folga da conferência, em graus.
local FanConfig = type(StatsConfig.Fan) == "table" and StatsConfig.Fan or {}
local FAN_MAX_DEGREES = tonumber(FanConfig.MaxDegrees) or 40
local FAN_TOLERANCE_DEGREES = tonumber(FanConfig.ToleranceDegrees) or 1.5
local FAN_REJECT_PRINT_INTERVAL = 60 -- no Studio, avisa os leques recusados no máximo 1× por minuto

-- Brainrots encostados na origem do tiro (GetPartBoundsInRadius): limite de peças lidas.
local NEAR_MAX_PARTS = 100

-- RemoteShot (rastro para os outros jogadores).
local REMOTE_SHOT_MAX_DISTANCE = 400 -- quem está mais longe que isso da origem não recebe
local REMOTE_SHOT_MIN_INTERVAL = 0.1 -- no máximo 1 RemoteShot por atirador a cada 0,1 s, por jogador

-- Quanto esperar para montar de novo a lista do raio fino quando faltava alguma pasta.
local WORLD_EXCLUDE_RETRY = 2

-- Cores de reserva caso algum Config esteja sem cor.
local FALLBACK_GUN_COLOR = Color3.fromRGB(70, 70, 78)
local FALLBACK_TRACER_COLOR = Color3.fromRGB(255, 225, 120)
local FALLBACK_ACCENT_COLOR = Color3.fromRGB(240, 205, 110)

-------------------------------------------------------------------------------
-- Estado do módulo
-------------------------------------------------------------------------------
local CombatService = {}

-- Sinal público: (player, count) quantos críticos o tiro teve.
CombatService.Crit = Signal.new()

local fireBuckets = {} -- [player] = {Tokens, Last}  (token bucket da cadência)
local hotPlayers = {} -- [player] = true  (arma com calor > 0 ou superaquecida: precisa esfriar)
local heatDirty = {} -- [player] = true  (estado "Heat" mudou e precisa ser enviado)
local heatLastSent = {} -- [player] = hora do último envio do "Heat"
local heatCapacitySent = {} -- [player] = capacidade enviada por último
local playerTroves = {} -- [player] = Trove (conexões do jogador)
local characterTroves = {} -- [player] = Trove (arma e conexões do personagem atual)
local gunMuzzles = {} -- [player] = Attachment na ponta do cano da arma do personagem
local rainbowGuns = {} -- [model] = {BasePart} partes que ficam trocando de cor
local remoteShotLastSent = {} -- [jogador que recebe] = {[UserId do atirador] = os.clock() do último RemoteShot}
local rng = Random.new()
local initialized = false
local started = false
local isStudio = RunService:IsStudio()

-- Contador de leques recusados (só para depuração; no Studio aparece no Output).
local fanRejectCount = 0
local fanRejectLastPrint = -math.huge

-- Filtro do raio FINO (mundo), criado uma vez e reaproveitado em todos os tiros.
-- A lista (personagens, moedas, torretas, brainrots) só é montada de novo quando muda:
-- personagem novo entra com AddToFilter; alguém saiu = lista marcada como "suja".
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.IgnoreWater = true
local worldExcludeDirty = true -- precisa montar a lista de novo antes do próximo tiro
local worldExcludeFolder = nil -- pasta de brainrots usada na última montagem
local worldExcludeMissingAt = nil -- os.clock() da montagem em que faltou alguma pasta

-- Busca dos brainrots encostados na origem do tiro (só a pasta Brainrots).
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include
overlapParams.MaxParts = NEAR_MAX_PARTS
local overlapFolder = nil -- pasta que está no filtro agora

-- O Roblox novo aceita IncludeInstances + ExcludeInstances no mesmo RaycastParams
-- ("só a pasta Brainrots, menos estes modelos"). Conferimos uma vez; se o servidor
-- ainda não tiver isso, usamos o jeito antigo (lista de candidatos por projétil).
-- Se um dia a esfera acertar algo que o filtro misto devia ter barrado, desligamos ele
-- (disableMixedFilter) e os próximos tiros usam o jeito antigo.
local useMixedFilter = pcall(function()
	local probe = RaycastParams.new()
	probe.IncludeInstances = {}
	probe.ExcludeInstances = {}
end)

-------------------------------------------------------------------------------
-- Pequenos ajudantes
-------------------------------------------------------------------------------

-- Hora compartilhada entre servidor e cliente.
local function now()
	return workspace:GetServerTimeNow()
end

-- Número "de verdade": nem NaN, nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Vector3 com as 3 coordenadas finitas e dentro de um limite razoável.
local function isFiniteVector(value)
	if typeof(value) ~= "Vector3" then
		return false
	end
	local x, y, z = value.X, value.Y, value.Z
	return isFiniteNumber(x)
		and isFiniteNumber(y)
		and isFiniteNumber(z)
		and math.abs(x) < MAX_COORDINATE
		and math.abs(y) < MAX_COORDINATE
		and math.abs(z) < MAX_COORDINATE
end

-- Lê um stat numérico com valor padrão (caso venha faltando ou inválido).
local function statNumber(stats, key, default)
	local value = stats and stats[key]
	if isFiniteNumber(value) then
		return value
	end
	return default
end

-- Confere se é um jogador que ainda está no servidor.
local function isPlayerInGame(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Stats do jogador (cache do StatService). Nunca devolve nil.
-- (Chamado a cada quadro para quem está com a arma quente: sem criar funções novas.)
local function getStats(player)
	local ok, stats = pcall(Svc("StatService").Get, player)
	if ok and type(stats) == "table" then
		return stats
	end
	return {}
end

-- Run (progresso na partida) do jogador, ou nil se ainda não existe.
local function getRun(player)
	local ok, run = pcall(Svc("MatchService").GetRun, player)
	if ok and type(run) == "table" then
		return run
	end
	return nil
end

-- Cor do arco-íris agora (todas as armas arco-íris ficam sincronizadas).
local function rainbowColor(saturation)
	local hue = (now() / RAINBOW_CYCLE_SECONDS) % 1
	return Color3.fromHSV(hue, saturation, 1)
end

-- Skin equipada pelo jogador (tabela do Config.Cosmetics). Se não tiver perfil,
-- ou a skin não existir / não for dele, usa a "Classic".
local function getSkin(player)
	local fallback = Cosmetics.ById.Classic or Cosmetics.Skins[1]
	local profile = DataService.GetProfile(player)
	local cosmetics = profile and profile.Cosmetics
	if type(cosmetics) ~= "table" then
		return fallback
	end
	local equipped = cosmetics.Equipped
	local skin = type(equipped) == "string" and Cosmetics.ById[equipped] or nil
	if not skin then
		return fallback
	end
	-- Skin paga precisa estar na lista de compradas.
	local owned = type(cosmetics.Owned) == "table" and cosmetics.Owned[equipped] == true
	if (tonumber(skin.Price) or 0) > 0 and not owned then
		return fallback
	end
	return skin
end

-- Cor do rastro da bala para os outros jogadores (cor da skin; arco-íris muda com o tempo).
local function getTracerColor(player)
	local skin = getSkin(player)
	if skin and skin.Rainbow then
		return rainbowColor(0.6)
	end
	if skin and typeof(skin.TracerColor) == "Color3" then
		return skin.TracerColor
	end
	return FALLBACK_TRACER_COLOR
end

-- Definição da arma do mapa atual (Config.Weapons), ou nil.
local function getMapWeapon()
	local ok, mapDef = pcall(function()
		return Svc("MatchService").GetMapDef()
	end)
	if ok and type(mapDef) == "table" and type(mapDef.Weapon) == "string" then
		return Weapons[mapDef.Weapon]
	end
	return nil
end

-------------------------------------------------------------------------------
-- Calor da arma (Deserto)
-------------------------------------------------------------------------------

-- Capacidade de calor do jogador (0 = a arma não esquenta).
local function getHeatCapacity(stats)
	return math.max(0, statNumber(stats, "HeatCapacity", 0))
end

-- Manda o estado "Heat" para o cliente (barra de calor no HUD).
local function sendHeat(player, run, capacity)
	local value = isFiniteNumber(run.Heat) and run.Heat or 0
	StateService.Set(player, "Heat", {
		Value = value,
		Capacity = capacity,
		Overheated = run.Overheated == true,
	})
	heatLastSent[player] = now()
	heatCapacitySent[player] = capacity
end

-- Roda a cada quadro: esfria as armas quentes e envia o estado (no máximo 10 Hz por jogador).
-- Só percorre quem está quente, então quase não custa nada fora do Deserto.
local function onHeartbeat(dt)
	-- 1. Esfria.
	for player in pairs(hotPlayers) do
		local run = if player.Parent == Players then getRun(player) else nil
		if not run then
			hotPlayers[player] = nil
			continue
		end

		local stats = getStats(player)
		local capacity = getHeatCapacity(stats)
		local cooling = math.max(0, statNumber(stats, "HeatCooling", 0))
		local heat = isFiniteNumber(run.Heat) and run.Heat or 0

		if capacity <= 0 then
			-- Arma sem calor (ex.: stats mudaram): zera tudo.
			if heat ~= 0 or run.Overheated then
				run.Heat = 0
				run.Overheated = false
				heatDirty[player] = true
			end
			hotPlayers[player] = nil
			continue
		end

		if heat > 0 and cooling > 0 then
			heat = math.max(0, heat - cooling * dt)
			run.Heat = heat
			heatDirty[player] = true
		end

		-- Histerese: depois de superaquecer, só volta a atirar quando esfria até 30%.
		if run.Overheated and heat <= capacity * OVERHEAT_RECOVER_FRACTION then
			run.Overheated = false
			heatDirty[player] = true
		end

		if heat <= 0 and not run.Overheated then
			hotPlayers[player] = nil
		end
	end

	-- 2. Envia o que mudou, respeitando o limite de 10 Hz por jogador.
	local t = now()
	for player in pairs(heatDirty) do
		if player.Parent ~= Players then
			heatDirty[player] = nil
		elseif t - (heatLastSent[player] or -math.huge) >= HEAT_SEND_INTERVAL then
			heatDirty[player] = nil
			local run = getRun(player)
			if run then
				sendHeat(player, run, getHeatCapacity(getStats(player)))
			end
		end
	end
end

-- Stats mudaram (upgrade de "Tanque de Calor", receita, etc.): atualiza a capacidade no HUD.
local function onStatsChanged(player)
	local list = if player ~= nil then { player } else Players:GetPlayers()
	for _, target in ipairs(list) do
		if isPlayerInGame(target) then
			local run = getRun(target)
			if run then
				local capacity = getHeatCapacity(getStats(target))
				if capacity ~= heatCapacitySent[target] then
					-- Capacidade menor que o calor atual: corta no máximo.
					if capacity > 0 and isFiniteNumber(run.Heat) and run.Heat > capacity then
						run.Heat = capacity
					end
					heatDirty[target] = true
					if (isFiniteNumber(run.Heat) and run.Heat > 0) or run.Overheated then
						hotPlayers[target] = true
					end
				end
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Validação do tiro
-------------------------------------------------------------------------------

-- Token bucket da cadência: cada tiro gasta 1 ficha; as fichas voltam a
-- FireRate × 1,25 por segundo, até no máximo 3. Sem ficha = tiro ignorado.
local function consumeFireToken(player, fireRate)
	local rate = math.max(0.1, fireRate * FIRE_RATE_TOLERANCE)
	local t = now()
	local bucket = fireBuckets[player]
	if not bucket then
		bucket = { Tokens = FIRE_BUCKET_CAPACITY, Last = t }
		fireBuckets[player] = bucket
	else
		local elapsed = math.max(0, t - bucket.Last)
		bucket.Tokens = math.min(FIRE_BUCKET_CAPACITY, bucket.Tokens + elapsed * rate)
		bucket.Last = t
	end
	if bucket.Tokens < 1 then
		return false
	end
	bucket.Tokens -= 1
	return true
end

-- Ângulo em graus entre dois vetores unitários.
-- (math.clamp: por erro de arredondamento o produto escalar pode sair 1,0000001, e o
-- math.acos de um número maior que 1 dá NaN.)
local function angleBetween(a, b)
	return math.deg(math.acos(math.clamp(a:Dot(b), -1, 1)))
end

-- Conta um leque recusado. No Studio, mostra o total no Output no máximo 1 vez por minuto.
local function countFanReject()
	fanRejectCount += 1
	if not isStudio then
		return
	end
	local t = os.clock()
	if t - fanRejectLastPrint >= FAN_REJECT_PRINT_INTERVAL then
		fanRejectLastPrint = t
		print(
			string.format(
				"[CombatService] Tiros recusados por leque inválido: %d (desde o início do servidor)",
				fanRejectCount
			)
		)
	end
end

-- Confere se as direções (já unitárias) formam o leque que o WeaponController monta:
--   * abertura total = min(Spread × (n - 1), Fan.MaxDegrees); passo = total / (n - 1);
--   * nenhum projétil pode estar a mais de total/2 + tolerância graus da direção média;
--   * (se o passo for maior que a tolerância) nenhum par de projéteis pode estar mais
--     perto que passo - tolerância graus. É isto que barra o truque de mandar n direções
--     IGUAIS para empilhar todos os projéteis num alvo só.
-- O desvio aleatório do cliente (Fan.JitterDegrees, até 0,6° para cada lado) cabe na
-- tolerância (1,5°): dois projéteis vizinhos se aproximam no máximo 1,2°.
local function isFanValid(unitDirections, spread)
	local count = #unitDirections
	if count <= 1 then
		return true -- um projétil só não tem leque para conferir
	end

	-- Direção média = soma dos vetores, normalizada.
	local sum = Vector3.zero
	for _, direction in ipairs(unitDirections) do
		sum += direction
	end
	if sum.Magnitude < MIN_DIRECTION_MAGNITUDE then
		return false -- direções opostas se anulando: isso não é um leque
	end
	local mean = sum.Unit

	local total = math.min(math.max(0, spread) * (count - 1), FAN_MAX_DEGREES)
	local step = total / (count - 1)
	local tolerance = FAN_TOLERANCE_DEGREES

	-- 1. Todos perto da média (ninguém fora do leque).
	local maxFromMean = total / 2 + tolerance
	for _, direction in ipairs(unitDirections) do
		if angleBetween(direction, mean) > maxFromMean then
			return false
		end
	end

	-- 2. Nenhum par "grudado" (projéteis empilhados).
	if step > tolerance then
		local minPairAngle = step - tolerance
		for first = 1, count - 1 do
			local a = unitDirections[first]
			for second = first + 1, count do
				if angleBetween(a, unitDirections[second]) < minPairAngle then
					return false
				end
			end
		end
	end
	return true
end

-- Lê e normaliza as direções mandadas pelo cliente e confere o leque.
-- Devolve a lista de vetores unitários, ou nil se algo estiver errado (tiro inteiro rejeitado).
local function readDirections(directions, maxProjectiles, spread)
	if type(directions) ~= "table" then
		return nil
	end
	local count = #directions
	if count < 1 or count > maxProjectiles then
		return nil
	end
	local result = table.create(count)
	for index = 1, count do
		local direction = directions[index]
		if not isFiniteVector(direction) then
			return nil -- NaN, infinito ou nem é Vector3
		end
		local magnitude = direction.Magnitude
		if magnitude < MIN_DIRECTION_MAGNITUDE then
			return nil -- vetor zero não tem direção
		end
		result[index] = direction / magnitude
	end
	if not isFanValid(result, spread) then
		countFanReject()
		return nil
	end
	return result
end

-------------------------------------------------------------------------------
-- Simulação do tiro no servidor
-------------------------------------------------------------------------------

-- Sobe pelos pais de "instance" até achar o filho direto de "folder" (o modelo do brainrot).
-- Devolve nil se a peça não está dentro da pasta.
local function topLevelChild(folder, instance)
	local current = instance
	while current ~= nil and current.Parent ~= folder do
		current = current.Parent
	end
	return current
end

-- Filtro do raio FINO (obstáculos do mundo): personagens, moedas, torretas e os brainrots
-- nunca param a bala nesse raio (os brainrots são tratados pela esfera, em simulateShot).
-- Devolve a lista e true se faltou alguma pasta (para tentar de novo daqui a pouco).
local function buildWorldExclude(brainrotFolder)
	local list = {}
	local missing = false
	for _, other in ipairs(Players:GetPlayers()) do
		local character = other.Character
		if character then
			table.insert(list, character)
		end
	end
	for _, name in ipairs({ "Coins", "Turrets" }) do
		local child = workspace:FindFirstChild(name)
		if child then
			table.insert(list, child)
		else
			missing = true
		end
	end
	if brainrotFolder then
		table.insert(list, brainrotFolder)
	else
		missing = true
	end
	return list, missing
end

-- Deixa o filtro do raio fino em dia (só monta a lista de novo quando algo mudou).
local function refreshWorldParams(brainrotFolder)
	local retry = worldExcludeMissingAt ~= nil and os.clock() - worldExcludeMissingAt >= WORLD_EXCLUDE_RETRY
	if not worldExcludeDirty and worldExcludeFolder == brainrotFolder and not retry then
		return
	end
	local list, missing = buildWorldExclude(brainrotFolder)
	worldParams.FilterDescendantsInstances = list
	worldExcludeDirty = false
	worldExcludeFolder = brainrotFolder
	worldExcludeMissingAt = if missing then os.clock() else nil
end

-- Filtro da esfera grossa de UM tiro: só enxerga a pasta Brainrots, menos os modelos que
-- o projétil atual já atravessou (perfuração). Um RaycastParams por tiro: a lista de
-- excluídos cresce a cada brainrot atingido e volta a ficar vazia no projétil seguinte.
-- (É por tiro, e não do módulo, porque o dano pode rodar código de outros serviços.)
local function newSphereFilter(brainrotFolder)
	local params = RaycastParams.new()
	params.IgnoreWater = true
	local filter = {
		Params = params,
		Mixed = useMixedFilter, -- true = filtro misto; false = jeito antigo (fixo neste tiro)
		Excluded = {}, -- modelos que este projétil já atravessou
		Candidates = nil, -- (jeito antigo) modelos que a esfera ainda pode acertar
		Models = nil, -- (jeito antigo) todos os modelos da pasta, lidos uma vez por tiro
		Dirty = true, -- a lista mudou e ainda não foi passada ao RaycastParams
	}
	if filter.Mixed then
		params.IncludeInstances = { brainrotFolder }
	else
		params.FilterType = Enum.RaycastFilterType.Include
		filter.Models = brainrotFolder:GetChildren()
	end
	return filter
end

-- Começa um projétil novo: nenhum brainrot atravessado ainda.
local function resetSphereFilter(filter)
	table.clear(filter.Excluded)
	if not filter.Mixed then
		filter.Candidates = table.clone(filter.Models)
	end
	filter.Dirty = true
end

-- Este projétil já atravessou "model": a esfera não enxerga mais esse modelo.
local function excludeFromSphere(filter, model)
	if not model or table.find(filter.Excluded, model) then
		return
	end
	table.insert(filter.Excluded, model)
	if not filter.Mixed then
		local index = table.find(filter.Candidates, model)
		if index then
			table.remove(filter.Candidates, index)
		end
	end
	filter.Dirty = true
end

-- Passa a lista atual para o RaycastParams (só se mudou). Devolve false se não sobrou
-- nenhum brainrot para a esfera testar (jeito antigo).
local function applySphereFilter(filter)
	if filter.Mixed then
		if filter.Dirty then
			filter.Params.ExcludeInstances = filter.Excluded
			filter.Dirty = false
		end
		return true
	end
	if filter.Dirty then
		filter.Params.FilterDescendantsInstances = filter.Candidates
		filter.Dirty = false
	end
	return #filter.Candidates > 0
end

-- O filtro misto deixou passar algo que devia barrar: desliga (com um aviso só) e os
-- próximos tiros usam o jeito antigo.
local function disableMixedFilter(reason)
	if useMixedFilter then
		useMixedFilter = false
		warn("[CombatService] Filtro misto (IncludeInstances + ExcludeInstances) falhou (" .. reason .. "); usando o filtro antigo.")
	end
end

-- Centro do brainrot (meio da caixa que envolve o modelo). Se o modelo sumiu, usa a
-- "coluna" do corpo: base (entity.Position) + metade da altura aproximada.
local function entityCenter(entity)
	local model = entity.Model
	if model and model.Parent then
		local ok, boxCFrame = pcall(model.GetBoundingBox, model)
		if ok and typeof(boxCFrame) == "CFrame" then
			return boxCFrame.Position
		end
	end
	local base = entity.Position
	if typeof(base) ~= "Vector3" then
		return nil
	end
	local def = entity.Def
	local baseScale = def and tonumber(def.BaseScale) or 1
	local sizeFactor = tonumber(entity.SizeFactor) or 1
	return base + Vector3.new(0, MODEL_HEIGHT_PER_SCALE * baseScale * sizeFactor / 2, 0)
end

-- O ponto está dentro da caixa da peça? (a origem do tiro dentro do corpo do brainrot)
local function isPointInsidePart(part, point)
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local half = part.Size * 0.5
	return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
end

-- Brainrots vivos que já encostam na esfera da bala logo na origem do tiro (tiro à
-- queima-roupa ou de dentro de um Gigante). O Spherecast não acha essas peças (elas já
-- começam dentro da esfera), então fazemos UMA busca por tiro e tratamos à parte.
-- Devolve a lista {Entity, Model, Center, Distance, Inside} do mais perto para o mais
-- longe, ou nil. Inside = a origem está dentro de uma peça dele (o jogador está "dentro"
-- do brainrot): aí a bala acerta em qualquer direção, mesmo mirando para longe do centro.
local function findNearEntities(BrainrotService, origin, radius, brainrotFolder)
	if overlapFolder ~= brainrotFolder then
		overlapFolder = brainrotFolder
		overlapParams.FilterDescendantsInstances = { brainrotFolder }
	end
	local parts = workspace:GetPartBoundsInRadius(origin, radius, overlapParams)
	if #parts == 0 then
		return nil
	end

	local seen = {}
	local list = {}
	for _, part in ipairs(parts) do
		local entity = BrainrotService.GetEntityFromPart(part)
		if entity and not entity.Dead then
			local item = seen[entity]
			if item == nil then
				local center = entityCenter(entity)
				if center then
					item = {
						Entity = entity,
						Model = topLevelChild(brainrotFolder, part) or entity.Model,
						Center = center,
						Distance = (center - origin).Magnitude,
						Inside = false,
					}
					table.insert(list, item)
				else
					item = false
				end
				seen[entity] = item
			end
			if item and not item.Inside and isPointInsidePart(part, origin) then
				item.Inside = true
			end
		end
	end
	if #list == 0 then
		return nil
	end
	table.sort(list, function(a, b)
		return a.Distance < b.Distance
	end)
	return list
end

-- Distância de um ponto até um brainrot. O brainrot é tratado como uma "coluna"
-- que vai do chão (entity.Position) até a altura do modelo, com um raio de corpo.
local function distanceToEntity(point, entity)
	local base = entity.Position
	if typeof(base) ~= "Vector3" then
		local model = entity.Model
		if not model or not model.Parent then
			return math.huge
		end
		base = model:GetPivot().Position
	end
	local def = entity.Def
	local baseScale = def and tonumber(def.BaseScale) or 1
	local sizeFactor = tonumber(entity.SizeFactor) or 1
	local height = MODEL_HEIGHT_PER_SCALE * baseScale * sizeFactor
	local y = math.clamp(point.Y, base.Y, base.Y + height)
	local distance = (Vector3.new(base.X, y, base.Z) - point).Magnitude
	return math.max(0, distance - height * BODY_RADIUS_FRACTION)
end

-- Respingo (Canhão de Gelato): 50% do dano nos OUTROS brainrots dentro do raio.
local function applySplash(player, primary, center, damage, radius)
	local BrainrotService = Svc("BrainrotService")
	local alive = BrainrotService.GetAlive()
	if type(alive) ~= "table" then
		return
	end

	-- Primeiro junta os alvos, depois aplica o dano (o dano pode matar e mudar a lista).
	local targets = {}
	for _, other in ipairs(alive) do
		if other ~= primary and not other.Dead and distanceToEntity(center, other) <= radius then
			table.insert(targets, other)
		end
	end
	for _, other in ipairs(targets) do
		if not other.Dead then
			BrainrotService.Damage(other, damage, player, { Crit = false, Source = "Splash" })
		end
	end
end

-- Aplica um acerto direto num brainrot e devolve a linha do HitConfirm.
local function applyHit(player, entity, position, stats)
	local BrainrotService = Svc("BrainrotService")

	-- Crítico: sorteio com CritChance; dano × CritMult.
	local crit = rng:NextNumber() < statNumber(stats, "CritChance", 0)
	local damage = math.max(0, statNumber(stats, "Damage", 0))
	if crit then
		damage *= math.max(1, statNumber(stats, "CritMult", 1))
	end

	-- Lê o bônus de "frágil" ANTES do dano (o brainrot pode morrer neste tiro), para o
	-- número na tela mostrar o dano que realmente entrou.
	local shownDamage = damage * BrainrotService.GetDamageMult(entity)
	local _, killed = BrainrotService.Damage(entity, damage, player, { Crit = crit, Source = "Gun" })
	killed = killed == true

	-- Respingo em volta do ponto atingido.
	local splashRadius = statNumber(stats, "SplashRadius", 0)
	if splashRadius > 0 then
		applySplash(player, entity, position, damage * SPLASH_DAMAGE_FRACTION, splashRadius)
	end

	-- Lentidão (só se o brainrot sobreviveu).
	local slowPower = statNumber(stats, "SlowPower", 0)
	if slowPower > 0 and not killed and not entity.Dead then
		BrainrotService.ApplySlow(entity, 1 - slowPower, GameConfig.SlowDuration)
	end

	-- Id = o mesmo "BrainrotId" do modelo: o cliente junta os números de dano do mesmo alvo.
	return { Position = position, Damage = shownDamage, Crit = crit, Killed = killed, Id = entity.Id }
end

-- Simula cada projétil, com perfuração. Devolve (hits, endpoints, critCount).
--   hits      = linhas do HitConfirm
--   endpoints = onde cada projétil terminou (para o rastro dos outros jogadores)
--
-- A bala é "gorda" (BulletHitRadius × Caliber) SÓ para acertar brainrots. Por isso são
-- três etapas por projétil:
--   0. (uma vez por tiro) GetPartBoundsInRadius na origem: brainrots que JÁ encostam na
--      esfera da bala (queima-roupa, ou o jogador dentro de um Gigante). O Spherecast não
--      enxerga peças que começam dentro da esfera, então antes esses tiros não davam dano.
--      Cada projétil acerta primeiro esses brainrots (do mais perto para o mais longe, só
--      os que não estão atrás: produto escalar > -raio; se a origem está DENTRO de uma
--      peça do brainrot, acerta em qualquer direção), gastando uma vaga da perfuração
--      por brainrot.
--   1. Raio FINO contra o mundo (chão, pedras, paredes, piso da plataforma...): diz até
--      onde a bala vai. Antes era a própria esfera grossa que batia no mundo, e no Inverno
--      ela raspava no piso da plataforma elevada muito antes da borda: o time lá em cima
--      não acertava os brainrots do vale, mesmo com eles bem na mira (e o upgrade de
--      Calibre piorava isso em vez de ajudar).
--   2. Spherecast que só enxerga os brainrots, até o ponto onde o raio fino parou, com a
--      perfuração que sobrou. Cada brainrot atingido entra na lista de excluídos desse
--      projétil (a esfera "atravessa" ele no teste seguinte).
local function simulateShot(player, origin, directions, stats)
	local BrainrotService = Svc("BrainrotService")

	local radius = math.clamp(GameConfig.BulletHitRadius * math.max(0.05, statNumber(stats, "Caliber", 1)), 0.05, 50)
	local range = math.clamp(statNumber(stats, "Range", 350), 1, 1000)
	local maxTargets = 1 + math.max(0, math.floor(statNumber(stats, "Pierce", 0)))

	local brainrotFolder = BrainrotService.GetFolder()

	-- Filtro do raio fino (mundo): ignora personagens, moedas, torretas e brainrots.
	refreshWorldParams(brainrotFolder)

	-- Filtro da esfera (um por tiro) e os brainrots encostados na origem (uma busca por tiro).
	local sphere = nil
	local nearEntities = nil
	if brainrotFolder then
		sphere = newSphereFilter(brainrotFolder)
		nearEntities = findNearEntities(BrainrotService, origin, radius, brainrotFolder)
	end

	local hits = {}
	local endpoints = table.create(#directions)
	local critCount = 0

	-- Registra um acerto direto (linha do HitConfirm + contagem de críticos).
	local function hitEntity(entity, position)
		local hit = applyHit(player, entity, position, stats)
		table.insert(hits, hit)
		if hit.Crit then
			critCount += 1
		end
	end

	for index, direction in ipairs(directions) do
		-- 1. Raio fino: até onde a bala vai antes de bater em algo do mundo.
		local travel = range
		local endpoint = origin + direction * range -- não bateu em nada: vai até o alcance
		local wall = workspace:Raycast(origin, direction * range, worldParams)
		if wall then
			travel = wall.Distance
			endpoint = wall.Position -- chão, pedra, parede...: a bala para aqui
		end

		local targets = 0
		if sphere then
			resetSphereFilter(sphere)
		end

		-- 0. Brainrots encostados na origem (já achados antes do laço).
		if nearEntities then
			for _, near in ipairs(nearEntities) do
				if targets >= maxTargets then
					break
				end
				local ahead = direction:Dot(near.Center - origin)
				if near.Inside or ahead > -radius then
					if near.Entity.Dead then
						-- Morreu com um projétil anterior deste tiro: a bala só atravessa.
						excludeFromSphere(sphere, near.Model)
					else
						targets += 1
						-- Ponto do número de dano: onde a bala passa pelo centro do brainrot (de
						-- dentro dele, pelo menos um raio à frente, para não nascer na câmera).
						local nearest = if near.Inside then math.min(radius, travel) else 0
						local position = origin + direction * math.clamp(ahead, nearest, travel)
						hitEntity(near.Entity, position)
						excludeFromSphere(sphere, near.Model)
						if targets >= maxTargets then
							endpoint = position -- a perfuração acabou: a bala para neste brainrot
						end
					end
				end
			end
		end

		-- 2. Esfera só contra os brainrots, do cano até o ponto do raio fino.
		if sphere and targets < maxTargets and travel > MIN_DIRECTION_MAGNITUDE then
			local displacement = direction * travel
			local casts = 0
			while targets < maxTargets and casts < MAX_CASTS_PER_PROJECTILE and applySphereFilter(sphere) do
				casts += 1
				local result = workspace:Spherecast(origin, radius, displacement, sphere.Params)
				if not result then
					break -- sem acerto: a bala segue até o ponto do raio fino
				end
				-- Peça estranha (fora da pasta) ou modelo já atravessado: trava de segurança.
				-- (No filtro misto isso nunca devia acontecer: se acontecer, ele é desligado.)
				local model = topLevelChild(brainrotFolder, result.Instance)
				if not model or table.find(sphere.Excluded, model) then
					if sphere.Mixed then
						disableMixedFilter(if model then "acertou um modelo excluído" else "acertou fora da pasta")
					end
					break
				end
				excludeFromSphere(sphere, model)

				local entity = BrainrotService.GetEntityFromPart(result.Instance)
				if entity and not entity.Dead then
					targets += 1
					hitEntity(entity, result.Position)
					if targets >= maxTargets then
						endpoint = result.Position -- a perfuração acabou: a bala para neste brainrot
					end
				end
				-- Brainrot que acabou de morrer (sem entidade viva): já foi excluído, só atravessa.
			end
		end

		endpoints[index] = endpoint
	end

	return hits, endpoints, critCount
end
-- Posição da ponta do cano da arma (para os outros verem o rastro saindo da arma).
-- Se a arma não existir ou estiver longe da origem real, usa a própria origem.
local function getVisualOrigin(player, origin)
	local muzzle = gunMuzzles[player]
	if muzzle and muzzle.Parent and muzzle:IsDescendantOf(workspace) then
		local position = muzzle.WorldPosition
		if (position - origin).Magnitude <= MUZZLE_MAX_OFFSET then
			return position
		end
	end
	return origin
end

-- Quanto a origem do tiro pode estar longe da cabeça: 8 studs + o quanto a cabeça anda
-- durante o atraso da rede (velocidade × ping × 2, com o atraso entre 0,1 e 0,5 s).
-- Nunca passa de 24 studs (trava contra "atirar de longe").
local function getOriginTolerance(player, head)
	local ok, ping = pcall(player.GetNetworkPing, player)
	if not ok or not isFiniteNumber(ping) then
		ping = 0
	end
	local lag = math.clamp(ping * ORIGIN_PING_FACTOR, ORIGIN_LAG_MIN, ORIGIN_LAG_MAX)
	local speed = head.AssemblyLinearVelocity.Magnitude
	if not isFiniteNumber(speed) then
		speed = 0
	end
	return math.min(MAX_ORIGIN_DISTANCE + speed * lag, MAX_ORIGIN_DISTANCE_CAP)
end

-- O jogador "recipient" está perto o bastante da origem para ver o rastro?
-- Sem personagem (morto, renascendo) não dá para medir: manda mesmo assim.
local function isInRemoteShotRange(recipient, origin)
	local character = recipient.Character
	if not character then
		return true
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not root or not root:IsA("BasePart") then
		return true
	end
	return (root.Position - origin).Magnitude <= REMOTE_SHOT_MAX_DISTANCE
end

-- Manda o rastro do tiro para os outros jogadores, um por um:
--   * pula quem está a mais de 400 studs da origem;
--   * no máximo 1 RemoteShot deste atirador a cada 0,1 s para cada jogador (a metralhadora
--     atira até 30 vezes por segundo; o resto dos tiros simplesmente não é desenhado lá).
local function sendRemoteShot(player, origin, endpoints)
	local t = os.clock()
	local shooterId = player.UserId
	local visualOrigin = nil
	local tracerColor = nil
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local sent = remoteShotLastSent[other]
			if not sent then
				sent = {}
				remoteShotLastSent[other] = sent
			end
			local last = sent[shooterId]
			if (last == nil or t - last >= REMOTE_SHOT_MIN_INTERVAL) and isInRemoteShotRange(other, origin) then
				sent[shooterId] = t
				-- Cano e cor só são calculados se alguém for mesmo receber.
				if not visualOrigin then
					visualOrigin = getVisualOrigin(player, origin)
					tracerColor = getTracerColor(player)
				end
				Net.FireClient(other, "RemoteShot", shooterId, visualOrigin, endpoints, tracerColor)
			end
		end
	end
end

-- Evento "Fire"(origin, directions, shotId) vindo do cliente.
local function onFire(player, origin, directions, shotId)
	-- 1. Tipos básicos dos argumentos.
	if not isFiniteVector(origin) or type(directions) ~= "table" or not isFiniteNumber(shotId) then
		return
	end

	-- 2. O jogador precisa estar na partida (run pronto).
	local run = getRun(player)
	if not run then
		return
	end

	-- 3. Personagem vivo, e a origem perto da cabeça.
	local character = player.Character
	if not character or not character.Parent then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	if (origin - head.Position).Magnitude > getOriginTolerance(player, head) then
		return
	end

	-- 4. Direções: de 1 até stats.Projectiles, todas válidas e em leque de verdade.
	local stats = getStats(player)
	local maxProjectiles = math.max(1, math.floor(statNumber(stats, "Projectiles", 1)))
	local unitDirections = readDirections(directions, maxProjectiles, statNumber(stats, "Spread", 0))
	if not unitDirections then
		return
	end

	-- 5. Arma superaquecida: tiro ignorado (sem gastar ficha).
	local capacity = getHeatCapacity(stats)
	if capacity > 0 and run.Overheated then
		return
	end

	-- 6. Cadência (token bucket).
	if not consumeFireToken(player, math.max(0.1, statNumber(stats, "FireRate", 1))) then
		return
	end

	-- 7. Calor: cada tiro soma HeatPerShot; chegou na capacidade = superaquecida.
	if capacity > 0 then
		local perShot = math.max(0, statNumber(stats, "HeatPerShot", 0))
		if perShot > 0 then
			local heat = (isFiniteNumber(run.Heat) and run.Heat or 0) + perShot
			run.Heat = math.min(capacity, heat)
			if heat >= capacity then
				run.Overheated = true
			end
			hotPlayers[player] = true
			heatDirty[player] = true
		end
	end

	-- 8. Simula o tiro (dano, perfuração, crítico, respingo, lentidão).
	local hits, endpoints, critCount = simulateShot(player, origin, unitDirections, stats)

	-- 9. Estatísticas permanentes e sinal de crítico (missões).
	--    "quiet" (4º argumento = true): muda o valor e avisa as conquistas, mas não manda o
	--    perfil inteiro para o cliente a cada tiro (o DataService junta e manda depois).
	DataService.IncrementStat(player, "Shots", 1, true)
	if critCount > 0 then
		DataService.IncrementStat(player, "Crits", critCount, true)
		CombatService.Crit:Fire(player, critCount)
	end

	-- 10. Rede: confirmação para o atirador (todo tiro com acerto) e rastro para os outros.
	if #hits > 0 then
		Net.FireClient(player, "HitConfirm", hits)
	end
	sendRemoteShot(player, origin, endpoints)
end

-------------------------------------------------------------------------------
-- Modelo da arma na mão do personagem (para os outros jogadores verem)
-------------------------------------------------------------------------------

-- Cilindros do Roblox ficam deitados no eixo X; esta rotação deixa o eixo apontando
-- para a frente da arma (-Z).
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0)

-- Monta o modelo da arma do mapa (ainda sem posição no mundo).
-- Devolve uma tabela:
--   Model      o Model da arma (PrimaryPart = "Grip", o cabo)
--   Layout     [peça] = CFrame da peça dentro da arma (origem = ponto onde a mão segura)
--   SkinParts  peças pintadas com a cor da skin (as que mudam na skin arco-íris)
--   Muzzle     CFrame da ponta do cano dentro da arma
local function buildGunModel(weaponId, gunColor, accentColor, tipColor)
	local model = Instance.new("Model")
	model.Name = GUN_MODEL_NAME

	local layout = {}
	local skinParts = {}

	-- Cria uma peça. Todas são leves e não atrapalham nada: sem colisão, sem toque,
	-- sem raycast (não bloqueiam tiros) e sem massa (não mudam a física do personagem).
	local function piece(name, size, localCFrame, color, shape, material)
		local part = Instance.new("Part")
		part.Name = name
		part.Shape = shape or Enum.PartType.Block
		part.Size = size
		part.Color = color
		part.Material = material or Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = true
		part.CastShadow = false
		part.Parent = model
		layout[part] = localCFrame
		return part
	end

	-- Peça pintada com a cor da skin.
	local function skinPiece(...)
		local part = piece(...)
		table.insert(skinParts, part)
		return part
	end

	-- Cabo (fica dentro da mão). É a peça principal: tudo é soldado nele.
	local gripColor = gunColor:Lerp(Color3.new(0, 0, 0), 0.45)
	local grip = piece(
		"Grip",
		Vector3.new(0.25, 0.6, 0.35),
		CFrame.new(0, -0.1, 0.05) * CFrame.Angles(math.rad(-12), 0, 0),
		gripColor
	)
	model.PrimaryPart = grip

	local muzzle
	if weaponId == "GelatoCannon" then
		-- Canhão: cano largo, anel na boca e uma "bola de gelato" em cima.
		skinPiece("Barrel", Vector3.new(1.8, 0.7, 0.7), CFrame.new(0, 0.4, -0.6) * ALONG_Z, gunColor, Enum.PartType.Cylinder)
		piece("Ring", Vector3.new(0.2, 0.85, 0.85), CFrame.new(0, 0.4, -1.45) * ALONG_Z, accentColor, Enum.PartType.Cylinder)
		piece("Scoop", Vector3.new(0.55, 0.55, 0.55), CFrame.new(0, 0.85, -0.2), accentColor, Enum.PartType.Ball)
		skinPiece(
			"Tip",
			Vector3.new(0.08, 0.5, 0.5),
			CFrame.new(0, 0.4, -1.58) * ALONG_Z,
			tipColor,
			Enum.PartType.Cylinder,
			Enum.Material.Neon
		)
		muzzle = CFrame.new(0, 0.4, -1.7)
	elseif weaponId == "TralaleroMinigun" then
		-- Metralhadora: caixa, três canos, uma "barbatana" e um anel na frente.
		skinPiece("Housing", Vector3.new(0.6, 0.6, 1.0), CFrame.new(0, 0.4, -0.3), gunColor)
		local barrelOffsets = { Vector2.new(0.15, 0.08), Vector2.new(-0.15, 0.08), Vector2.new(0, -0.17) }
		for index, offset in ipairs(barrelOffsets) do
			skinPiece(
				"Barrel" .. index,
				Vector3.new(1.6, 0.16, 0.16),
				CFrame.new(offset.X, 0.4 + offset.Y, -1.5) * ALONG_Z,
				gunColor,
				Enum.PartType.Cylinder
			)
		end
		piece("Ring", Vector3.new(0.12, 0.6, 0.6), CFrame.new(0, 0.4, -2.0) * ALONG_Z, accentColor, Enum.PartType.Cylinder)
		piece("Fin", Vector3.new(0.08, 0.35, 0.7), CFrame.new(0, 0.85, -0.35), accentColor)
		skinPiece(
			"Tip",
			Vector3.new(0.06, 0.45, 0.45),
			CFrame.new(0, 0.4, -2.33) * ALONG_Z,
			tipColor,
			Enum.PartType.Cylinder,
			Enum.Material.Neon
		)
		muzzle = CFrame.new(0, 0.4, -2.4)
	else
		-- Pistola (padrão): corpo, cano fino e uma faixa em cima.
		skinPiece("Body", Vector3.new(0.3, 0.35, 1.3), CFrame.new(0, 0.3, -0.4), gunColor)
		skinPiece("Barrel", Vector3.new(0.6, 0.2, 0.2), CFrame.new(0, 0.33, -1.3) * ALONG_Z, gunColor, Enum.PartType.Cylinder)
		piece("Stripe", Vector3.new(0.32, 0.1, 0.9), CFrame.new(0, 0.5, -0.4), accentColor)
		skinPiece(
			"Tip",
			Vector3.new(0.05, 0.22, 0.22),
			CFrame.new(0, 0.33, -1.6) * ALONG_Z,
			tipColor,
			Enum.PartType.Cylinder,
			Enum.Material.Neon
		)
		muzzle = CFrame.new(0, 0.33, -1.7)
	end

	return { Model = model, Layout = layout, SkinParts = skinParts, Muzzle = muzzle }
end

-- Solda a arma na mão. Cada peça já vai para a posição certa no mundo (sem "piscar"
-- no centro do mapa), ganha um Weld com o cabo, e o cabo ganha um Weld com a mão.
local function attachGunToHand(gun, hand, gripOffset)
	local model = gun.Model
	local grip = model.PrimaryPart
	local base = hand.CFrame * gripOffset

	-- 1. Posiciona todas as peças.
	for part, localCFrame in pairs(gun.Layout) do
		part.CFrame = base * localCFrame
	end

	-- 2. Solda cada peça no cabo, guardando a posição relativa.
	for part in pairs(gun.Layout) do
		if part ~= grip then
			local weld = Instance.new("Weld")
			weld.Name = "GunWeld"
			weld.Part0 = grip
			weld.Part1 = part
			weld.C0 = grip.CFrame:ToObjectSpace(part.CFrame)
			weld.C1 = CFrame.identity
			weld.Parent = part
		end
	end

	-- 3. Cabo -> mão.
	local handWeld = Instance.new("Weld")
	handWeld.Name = "HandWeld"
	handWeld.Part0 = hand
	handWeld.Part1 = grip
	handWeld.C0 = hand.CFrame:ToObjectSpace(grip.CFrame)
	handWeld.C1 = CFrame.identity
	handWeld.Parent = grip

	-- 4. Ponto de saída do tiro (ponta do cano), relativo ao cabo.
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.CFrame = gun.Layout[grip]:Inverse() * gun.Muzzle
	muzzle.Parent = grip
	return muzzle
end

-- Acha a mão direita: R15 "RightHand", R6 "Right Arm". Espera até HAND_WAIT_TIMEOUT.
local function waitForHand(character)
	local deadline = os.clock() + HAND_WAIT_TIMEOUT
	repeat
		local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
		if hand and hand:IsA("BasePart") then
			return hand
		end
		task.wait(0.1)
	until os.clock() >= deadline
	return nil
end

-- Deslocamento do ponto onde a mão segura: usa o RightGripAttachment (existe em R15 e R6)
-- só pela posição; a arma aponta para a frente da mão (-Z).
local function getGripOffset(hand)
	local attachment = hand:FindFirstChild("RightGripAttachment")
	if attachment and attachment:IsA("Attachment") then
		return CFrame.new(attachment.Position)
	end
	return CFrame.new(0, -hand.Size.Y / 2, 0)
end

-- Cria a arma para um personagem (roda numa thread separada: pode esperar a mão e o perfil).
local function equipCharacterGun(player, character, trove)
	local hand = waitForHand(character)
	if not hand or player.Character ~= character then
		return
	end

	-- A skin vem do perfil: espera ele carregar (na primeira vez pode levar uns segundos).
	DataService.WaitForProfile(player, PROFILE_WAIT_TIMEOUT)
	if player.Parent ~= Players or player.Character ~= character or not hand.Parent then
		return
	end

	-- Remove uma arma antiga (se por acaso já existir).
	local old = character:FindFirstChild(GUN_MODEL_NAME)
	if old then
		old:Destroy()
	end

	-- Cores: corpo = skin equipada; detalhes = cor da arma do mapa; ponta = rastro da skin.
	local skin = getSkin(player)
	local weapon = getMapWeapon()
	local gunColor = skin and typeof(skin.GunColor) == "Color3" and skin.GunColor or FALLBACK_GUN_COLOR
	local tipColor = skin and typeof(skin.TracerColor) == "Color3" and skin.TracerColor or FALLBACK_TRACER_COLOR
	local accentColor = weapon and typeof(weapon.GunColor) == "Color3" and weapon.GunColor or FALLBACK_ACCENT_COLOR

	local gun = buildGunModel(weapon and weapon.Id or "", gunColor, accentColor, tipColor)
	local model = gun.Model
	model:SetAttribute("SkinId", skin and skin.Id or "Classic")
	local muzzle = attachGunToHand(gun, hand, getGripOffset(hand))

	model.Parent = character
	trove:Add(model)
	gunMuzzles[player] = muzzle
	trove:Add(function()
		if gunMuzzles[player] == muzzle then
			gunMuzzles[player] = nil
		end
	end)

	-- Skin arco-íris: registra as peças para o laço de cores.
	if skin and skin.Rainbow then
		rainbowGuns[model] = gun.SkinParts
		trove:Add(function()
			rainbowGuns[model] = nil
		end)
	end
end

-- Chamado a cada (re)nascimento do personagem.
local function onCharacterAdded(player, character)
	if characterTroves[player] then
		characterTroves[player]:Clean()
	end

	-- O raio fino dos tiros atravessa personagens: entra no filtro na hora (sem montar
	-- a lista toda de novo). Se a lista já vai ser montada de novo, ele entra lá.
	if not worldExcludeDirty then
		worldParams:AddToFilter(character)
	end
	local trove = Trove.new()
	characterTroves[player] = trove

	trove:Add(task.spawn(function()
		local ok, err = pcall(equipCharacterGun, player, character, trove)
		if not ok then
			warn("[CombatService] Erro ao criar a arma do personagem: " .. tostring(err))
		end
	end))
end

-- Laço das armas arco-íris (5 Hz, só mexe nas armas registradas).
local function rainbowLoop()
	while true do
		task.wait(RAINBOW_INTERVAL)
		if next(rainbowGuns) ~= nil then
			local color = rainbowColor(0.85)
			for model, parts in pairs(rainbowGuns) do
				if model.Parent == nil then
					rainbowGuns[model] = nil
				else
					for _, part in ipairs(parts) do
						part.Color = color
					end
				end
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Entrada e saída de jogadores
-------------------------------------------------------------------------------

local function onPlayerAdded(player)
	if playerTroves[player] then
		return -- já tratado (PlayerAdded + lista inicial)
	end
	local trove = Trove.new()
	playerTroves[player] = trove

	trove:Connect(player.CharacterAdded, function(character)
		onCharacterAdded(player, character)
	end)
	trove:Connect(player.CharacterRemoving, function(_character)
		local characterTrove = characterTroves[player]
		if characterTrove then
			characterTrove:Clean()
			characterTroves[player] = nil
		end
		worldExcludeDirty = true -- o personagem velho sai do filtro do raio fino
	end)
	if player.Character then
		onCharacterAdded(player, player.Character)
	end
end

local function onPlayerRemoving(player)
	fireBuckets[player] = nil
	hotPlayers[player] = nil
	heatDirty[player] = nil
	heatLastSent[player] = nil
	heatCapacitySent[player] = nil
	gunMuzzles[player] = nil
	worldExcludeDirty = true

	-- Limite de RemoteShot: tira o jogador como quem recebe e como atirador.
	remoteShotLastSent[player] = nil
	local userId = player.UserId
	for _, sent in pairs(remoteShotLastSent) do
		sent[userId] = nil
	end

	if characterTroves[player] then
		characterTroves[player]:Clean()
		characterTroves[player] = nil
	end
	if playerTroves[player] then
		playerTroves[player]:Clean()
		playerTroves[player] = nil
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function CombatService.Init()
	if initialized then
		return
	end
	initialized = true

	-- Escuta os tiros vindos dos clientes (o Net já protege contra "flood" e erros).
	Net.OnEvent("Fire", onFire)
end

function CombatService.Start()
	if started then
		return
	end
	started = true

	-- Jogadores: arma na mão de cada personagem.
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	-- Resfriamento da arma a cada quadro (só percorre quem está quente).
	RunService.Heartbeat:Connect(onHeartbeat)

	-- Quando os stats mudam, a capacidade de calor pode ter mudado.
	local ok, err = pcall(function()
		Svc("StatService").Changed:Connect(onStatsChanged)
	end)
	if not ok then
		warn("[CombatService] Não foi possível escutar StatService.Changed: " .. tostring(err))
	end

	-- Cores das armas arco-íris.
	task.spawn(rainbowLoop)
end

return CombatService
