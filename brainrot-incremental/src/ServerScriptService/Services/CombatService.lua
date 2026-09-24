--!nonstrict
-- CombatService: tudo sobre os tiros dos jogadores (seção 8.6 da especificação).
--
-- Como um tiro funciona:
--   1. O cliente (WeaponController) atira na tela dele na hora e manda o evento
--      "Fire"(origin, directions, shotId) para o servidor.
--   2. O servidor NÃO confia no cliente: confere se o personagem está vivo, se a origem
--      está perto da cabeça, se o número de direções bate com os projéteis, a cadência
--      (token bucket) e o calor da arma.
--   3. Para cada direção, o servidor faz um raio fino contra o mundo (até onde a bala vai) e
--      um Spherecast (um "raio grosso") que só enxerga os brainrots, e aplica o dano
--      nos brainrots atingidos (com perfuração, crítico, respingo e lentidão).
--   4. Manda "HitConfirm" para o atirador (hitmarker e números de dano) e "RemoteShot"
--      para os outros jogadores (eles desenham o rastro da bala).
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
local MAX_ORIGIN_DISTANCE = 8 -- a origem do tiro pode estar a no máximo 8 studs da cabeça
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
local rng = Random.new()
local initialized = false
local started = false

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

-- Lê e normaliza as direções mandadas pelo cliente.
-- Devolve a lista de vetores unitários, ou nil se algo estiver errado (tiro inteiro rejeitado).
local function readDirections(directions, maxProjectiles)
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
	return result
end

-------------------------------------------------------------------------------
-- Simulação do tiro no servidor
-------------------------------------------------------------------------------

-- Tira da lista "candidates" o modelo (filho da pasta Brainrots) que contém a peça atingida.
-- Assim o próximo Spherecast desse projétil "atravessa" esse brainrot (perfuração).
-- Devolve false se a peça não é de nenhum candidato (trava de segurança do laço).
local function removeCandidate(candidates, part)
	local current = part
	while current and current ~= workspace do
		local position = table.find(candidates, current)
		if position then
			table.remove(candidates, position)
			return true
		end
		current = current.Parent
	end
	return false
end

-- Filtro do raio FINO (obstáculos do mundo): personagens, moedas, torretas e os brainrots
-- nunca param a bala nesse raio (os brainrots são tratados pela esfera, em simulateShot).
local function buildWorldExclude(brainrotFolder)
	local list = {}
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
		end
	end
	if brainrotFolder then
		table.insert(list, brainrotFolder)
	end
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

	return { Position = position, Damage = shownDamage, Crit = crit, Killed = killed }
end

-- Simula cada projétil, com perfuração. Devolve (hits, endpoints, critCount).
--   hits      = linhas do HitConfirm
--   endpoints = onde cada projétil terminou (para o rastro dos outros jogadores)
--
-- A bala é "gorda" (BulletHitRadius × Caliber) SÓ para acertar brainrots. Por isso são
-- dois testes por projétil:
--   1. Raio FINO contra o mundo (chão, pedras, paredes, piso da plataforma...): diz até
--      onde a bala vai. Antes era a própria esfera grossa que batia no mundo, e no Inverno
--      ela raspava no piso da plataforma elevada muito antes da borda: o time lá em cima
--      não acertava os brainrots do vale, mesmo com eles bem na mira (e o upgrade de
--      Calibre piorava isso em vez de ajudar).
--   2. Spherecast que só enxerga os brainrots (FilterType Include), até o ponto onde o
--      raio fino parou. Cada brainrot atingido sai da lista do projétil (perfuração).
local function simulateShot(player, origin, directions, stats)
	local BrainrotService = Svc("BrainrotService")

	local radius = math.clamp(GameConfig.BulletHitRadius * math.max(0.05, statNumber(stats, "Caliber", 1)), 0.05, 50)
	local range = math.clamp(statNumber(stats, "Range", 350), 1, 1000)
	local maxTargets = 1 + math.max(0, math.floor(statNumber(stats, "Pierce", 0)))

	local brainrotFolder = BrainrotService.GetFolder()

	-- Filtro do raio fino (mundo): ignora personagens, moedas, torretas e brainrots.
	local worldParams = RaycastParams.new()
	worldParams.FilterType = Enum.RaycastFilterType.Exclude
	worldParams.FilterDescendantsInstances = buildWorldExclude(brainrotFolder)
	worldParams.IgnoreWater = true

	-- Filtro da esfera: "Include" = só acerta o que está na lista (os modelos dos brainrots).
	local brainrotParams = RaycastParams.new()
	brainrotParams.FilterType = Enum.RaycastFilterType.Include
	brainrotParams.IgnoreWater = true
	local brainrotModels = if brainrotFolder then brainrotFolder:GetChildren() else {}

	local hits = {}
	local endpoints = table.create(#directions)
	local critCount = 0

	for index, direction in ipairs(directions) do
		-- 1. Raio fino: até onde a bala vai antes de bater em algo do mundo.
		local travel = range
		local endpoint = origin + direction * range -- não bateu em nada: vai até o alcance
		local wall = workspace:Raycast(origin, direction * range, worldParams)
		if wall then
			travel = wall.Distance
			endpoint = wall.Position -- chão, pedra, parede...: a bala para aqui
		end

		-- 2. Esfera só contra os brainrots, do cano até esse ponto.
		-- Cada projétil tem sua própria lista de candidatos (cópia da lista do tiro).
		local candidates = if travel > MIN_DIRECTION_MAGNITUDE then table.clone(brainrotModels) else {}
		local displacement = direction * travel
		local targets = 0
		local casts = 0

		while targets < maxTargets and casts < MAX_CASTS_PER_PROJECTILE and #candidates > 0 do
			casts += 1
			brainrotParams.FilterDescendantsInstances = candidates
			local result = workspace:Spherecast(origin, radius, displacement, brainrotParams)
			-- Sem acerto (ou peça estranha): a bala segue até o ponto do raio fino.
			if not result or not removeCandidate(candidates, result.Instance) then
				break
			end

			local entity = BrainrotService.GetEntityFromPart(result.Instance)
			if entity and not entity.Dead then
				targets += 1
				local hit = applyHit(player, entity, result.Position, stats)
				table.insert(hits, hit)
				if hit.Crit then
					critCount += 1
				end
				if targets >= maxTargets then
					endpoint = result.Position -- a perfuração acabou: a bala para neste brainrot
				end
			end
			-- Brainrot que acabou de morrer (sem entidade viva): já saiu da lista, só atravessa.
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
	if (origin - head.Position).Magnitude > MAX_ORIGIN_DISTANCE then
		return
	end

	-- 4. Direções: de 1 até stats.Projectiles, todas válidas.
	local stats = getStats(player)
	local maxProjectiles = math.max(1, math.floor(statNumber(stats, "Projectiles", 1)))
	local unitDirections = readDirections(directions, maxProjectiles)
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
	DataService.IncrementStat(player, "Shots", 1)
	if critCount > 0 then
		DataService.IncrementStat(player, "Crits", critCount)
		CombatService.Crit:Fire(player, critCount)
	end

	-- 10. Rede: confirmação para o atirador e rastro para os outros.
	if #hits > 0 then
		Net.FireClient(player, "HitConfirm", hits)
	end
	Net.FireAllExcept(
		player,
		"RemoteShot",
		player.UserId,
		getVisualOrigin(player, origin),
		endpoints,
		getTracerColor(player)
	)
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
	trove:Connect(player.CharacterRemoving, function(character)
		local characterTrove = characterTroves[player]
		if characterTrove then
			characterTrove:Clean()
			characterTroves[player] = nil
		end
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
