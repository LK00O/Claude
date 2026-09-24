--!nonstrict
-- BrainrotService: os brainrots do campo (nascer, crescer, levar dano, morrer).
--
--   BrainrotService.SpawnWave(triggeredBy?) -> ok, msg     planta uma leva (quadro, debug, respawn automático)
--   BrainrotService.GetEntity(id)                          entidade viva pelo id (ou nil)
--   BrainrotService.GetEntityFromPart(part)                entidade dona de uma parte (sobe até o Model com "BrainrotId")
--   BrainrotService.GetAlive() -> {entity}                 cópia da lista dos vivos
--   BrainrotService.GetFolder() -> Folder                  workspace.Brainrots
--   BrainrotService.Damage(entity, amount, attacker?, info) -> dealt, killed
--   BrainrotService.ApplySlow(entity, factor, duration)
--   BrainrotService.Ignite(entity, dps, duration)
--   BrainrotService.Kill(entity, killer?, info)
--   Sinais: Killed(killer?, entity, info), Exploded(player?), Spawned(entity)
--
-- Entidade (tabela) de cada brainrot vivo:
--   { Id, Def, Model, Position (no chão), SizeFactor, TargetSize, StartSize, GrowStart, GrowDuration,
--     HealthFrac, MaxHealth, IceShield, IceShieldMax, IceBlock, Enchant, Giant,
--     SlowUntil, SlowFactor, BurnUntil, BurnDps, LastHitBy, SpawnTime, Dead, Billboard,
--     CoinValue (moedas que ele daria agora; atualizado a 5 Hz) }
--
-- Um laço de 5 Hz cuida de: crescimento, vida máxima, barra de vida, queimadura,
-- lentidão, atração dos valiosos, cores do arco-íris, respawn automático e "Alive".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local GameConfig = require(ConfigFolder:WaitForChild("Game"))
local Brainrots = require(ConfigFolder:WaitForChild("Brainrots"))
local Enchants = require(ConfigFolder:WaitForChild("Enchants"))
local Signal = require(UtilFolder:WaitForChild("Signal"))
local Trove = require(UtilFolder:WaitForChild("Trove"))
local Net = require(UtilFolder:WaitForChild("Net"))
local Tables = require(UtilFolder:WaitForChild("Tables"))
local Formulas = require(UtilFolder:WaitForChild("Formulas"))

-- Módulo de mundo (permitido no topo).
local BrainrotFactory = require(ServerScriptService:WaitForChild("World"):WaitForChild("BrainrotFactory"))

-- Serviços-folha (permitidos no topo).
local Services = script.Parent
local DataService = require(Services:WaitForChild("DataService"))
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções (regra anti-require-circular).
-- Guardamos o módulo depois do primeiro require para não repetir o WaitForChild no laço.
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
-- Constantes técnicas (não são balanceamento; os números de jogo ficam no Config)
-------------------------------------------------------------------------------

local TICK_INTERVAL = 0.2 -- laço de 5 Hz
local START_SIZE_FRACTION = 0.25 -- nasce com 25% do tamanho alvo (especificação 8.5)
local GIANT_SIZE_MULT = 3 -- gigante = 3× maior (especificação 8.5)
local EXPLOSION_RADIUS_PER_SIZE = 3 -- raio da explosão = base + 3 × SizeFactor (especificação 8.5)

-- Peso extra por tier com o stat TierLuck: Low ×1, Medium ×(1+luck), High ×(1+2·luck).
local TIER_LUCK_STEPS = { Low = 0, Medium = 1, High = 2 }

-- Zonas onde não se nasce (especificação 7.5).
local PLATFORM_MARGIN = 6 -- Inverno: plataforma expandida em 6 studs
local OASIS_MARGIN = 6 -- Deserto: raio do oásis + 6
local PIT_EXCLUSION_RADIUS = 40 -- Deserto: 40 studs em volta da Grande Cova

local FIELD_EDGE_MARGIN = 2 -- não nascer colado na borda do campo
local FOOTPRINT_RADIUS = 1.6 -- "raio" aproximado de um brainrot em escala 1 (studs)
-- Raio máximo (studs) usado SÓ para escolher onde nascer (espaço entre brainrots e
-- distância dos jogadores). Com muito Adubo um brainrot passa de 20 studs de raio e um
-- gigante de 60: sem este limite o campo "enchia" com uns 10 deles e quase toda leva
-- falhava ("Não achei espaço livre"). Acima disso eles podem se sobrepor um pouco,
-- o que não tem problema (brainrots não colidem com nada).
local SPAWN_FOOTPRINT_CAP = 8

-- Raycast para achar o chão.
local GROUND_RAY_ABOVE = 30 -- começa 30 studs acima do topo do campo
local GROUND_RAY_EXTRA = 80 -- e desce mais 80 abaixo dele
local GROUND_MAX_ABOVE_FIELD = 20 -- ignora "chão" muito alto (copa de árvore, telhado)
local GROUND_MAX_ABOVE_BASE = 10 -- e também o que fica mais de 10 studs acima de ctx.GroundY
local MIN_GROUND_NORMAL_Y = 0.6 -- ignora superfícies íngremes demais
local WALK_RAY_UP = 6 -- brainrot andando: procura o chão perto dos pés
local WALK_RAY_DOWN = 20

local MIN_MODEL_SCALE = 0.05 -- ScaleTo não aceita zero
local SCALE_EPSILON = 0.004 -- só reescala quando muda mais de 0,4%
local CHAIN_DELAY = 0.12 -- atraso entre explosões em cadeia (fica bonito de ver)
local RAINBOW_SPEED = 0.35 -- voltas no círculo de cores por segundo
local FACE_JITTER = 40 -- graus de variação ao virar para a praça
local AUTO_RESPAWN_RETRY = 1 -- segundos até tentar de novo se o respawn automático falhar
local BOARD_MAX_DISTANCE = 25 -- distância máxima (studs) do jogador ao quadro
local DEATH_EPSILON = 1e-6
local DEFAULT_MODEL_HEIGHT = 5

local HEALTH_BAR_COLOR = Color3.fromRGB(95, 225, 95)
local SHIELD_BAR_COLOR = Color3.fromRGB(150, 215, 255)
local WHITE = Color3.new(1, 1, 1)
local SLOW_COLOR = Color3.fromRGB(170, 225, 255)
local BURN_COLOR = Color3.fromRGB(255, 120, 30)

local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local FIRE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"

-------------------------------------------------------------------------------
-- Estado
-------------------------------------------------------------------------------

local BrainrotService = {}
BrainrotService.Killed = Signal.new() -- (killer: Player?, entity, info)
BrainrotService.Exploded = Signal.new() -- (player: Player?)
BrainrotService.Spawned = Signal.new() -- (entity)

local entities = {} -- [id] = entidade viva
local aliveList = {} -- lista das entidades vivas (ordem não importa)
local folder = nil -- workspace.Brainrots
local nextId = 0
local boardCooldownEnd = 0
local autoRespawnRetryAt = 0
local lastAliveSent = -1
local lastTeamStats = nil
local started = false

local rng = Random.new()
local trove = Trove.new()

-- Raycast do chão: ignora brainrots, moedas, torretas e personagens.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

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

-- Devolve o jogador se "value" é um Player que ainda está no servidor; senão nil.
local function asPlayer(value)
	if typeof(value) == "Instance" and value:IsA("Player") and value.Parent == Players then
		return value
	end
	return nil
end

-- Formata segundos com vírgula decimal (pt-BR): 2.35 -> "2,4".
local function formatSeconds(seconds)
	local text = string.format("%.1f", math.max(0, seconds))
	return (text:gsub("%.", ","))
end

-- Distância no plano XZ (ignora a altura).
local function flatDistance(a, b)
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Pega (ou cria) a pasta workspace.Brainrots (o MatchService normalmente já criou).
local function ensureFolder()
	if folder and folder.Parent then
		return folder
	end
	local existing = workspace:FindFirstChild("Brainrots")
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		folder = Instance.new("Folder")
		folder.Name = "Brainrots"
		folder.Parent = workspace
	end
	return folder
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
	if lastTeamStats then
		return lastTeamStats
	end
	-- Último recurso: stats padrão do mapa, sem upgrades.
	local okMap, mapId = pcall(function()
		return Svc("MatchService").GetMapId()
	end)
	lastTeamStats = Formulas.ComputeStats(if okMap then mapId else nil, {}, {}, {}, {})
	return lastTeamStats
end

-- A FieldArea do contexto (ou nil se o mapa não tem campo).
local function getField(ctx)
	local field = ctx and ctx.FieldArea
	if typeof(field) == "Instance" and field:IsA("BasePart") then
		return field
	end
	return nil
end

-- Posição (no chão) dos personagens vivos: {{Player, Position}}.
local function getAliveRoots()
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				table.insert(list, { Player = player, Position = root.Position })
			end
		end
	end
	return list
end

-- Atualiza a lista de coisas que o raycast do chão ignora.
local function refreshGroundFilter()
	local ignore = { ensureFolder() }
	for _, name in ipairs({ "Coins", "Turrets" }) do
		local child = workspace:FindFirstChild(name)
		if child then
			table.insert(ignore, child)
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	groundParams.FilterDescendantsInstances = ignore
end

-- Topo da FieldArea (altura Y).
local function fieldTop(field)
	return field.Position.Y + field.Size.Y / 2
end

-- Ponto aleatório dentro da FieldArea (na altura do centro dela).
local function randomFieldPoint(field)
	local halfX = math.max(0, field.Size.X / 2 - FIELD_EDGE_MARGIN)
	local halfZ = math.max(0, field.Size.Z / 2 - FIELD_EDGE_MARGIN)
	local localPoint = Vector3.new(rng:NextNumber(-halfX, halfX), 0, rng:NextNumber(-halfZ, halfZ))
	return field.CFrame:PointToWorldSpace(localPoint)
end

-- Prende um ponto dentro da FieldArea (no plano X/Z da parte), mantendo a altura.
local function clampToField(field, position)
	local localPoint = field.CFrame:PointToObjectSpace(position)
	local halfX = math.max(0, field.Size.X / 2 - FIELD_EDGE_MARGIN)
	local halfZ = math.max(0, field.Size.Z / 2 - FIELD_EDGE_MARGIN)
	local clamped = Vector3.new(math.clamp(localPoint.X, -halfX, halfX), localPoint.Y, math.clamp(localPoint.Z, -halfZ, halfZ))
	return field.CFrame:PointToWorldSpace(clamped)
end

-- true se a posição está numa zona proibida do mapa (ver especificação 7.5).
local function isInExcludedZone(ctx, position)
	if not ctx then
		return false
	end
	-- Inverno: plataforma elevada (expandida em PLATFORM_MARGIN).
	local platform = ctx.Platform
	if typeof(platform) == "Instance" and platform:IsA("BasePart") then
		local localPoint = platform.CFrame:PointToObjectSpace(position)
		if
			math.abs(localPoint.X) <= platform.Size.X / 2 + PLATFORM_MARGIN
			and math.abs(localPoint.Z) <= platform.Size.Z / 2 + PLATFORM_MARGIN
		then
			return true
		end
	end
	-- Deserto: oásis e Grande Cova.
	if typeof(ctx.OasisCenter) == "Vector3" and isFiniteNumber(ctx.OasisRadius) then
		if flatDistance(position, ctx.OasisCenter) < ctx.OasisRadius + OASIS_MARGIN then
			return true
		end
	end
	if typeof(ctx.Pit) == "Vector3" then
		if flatDistance(position, ctx.Pit) < PIT_EXCLUSION_RADIUS then
			return true
		end
	end
	return false
end

-- Acha o chão para um brainrot nascer em "point" (X/Z). Devolve a posição ou nil.
local function findSpawnGround(ctx, field, point)
	local top = fieldTop(field)
	local origin = Vector3.new(point.X, top + GROUND_RAY_ABOVE, point.Z)
	local direction = Vector3.new(0, -(GROUND_RAY_ABOVE + field.Size.Y + GROUND_RAY_EXTRA), 0)
	local hasGroundY = ctx ~= nil and isFiniteNumber(ctx.GroundY)
	local result = workspace:Raycast(origin, direction, groundParams)
	if result then
		if result.Normal.Y < MIN_GROUND_NORMAL_Y or result.Position.Y > top + GROUND_MAX_ABOVE_FIELD then
			return nil -- parede, telhado, copa de árvore...
		end
		-- Muito acima do chão do mapa (galho de pinheiro, topo de pedra alta): tenta outro lugar.
		if hasGroundY and result.Position.Y > ctx.GroundY + GROUND_MAX_ABOVE_BASE then
			return nil
		end
		return result.Position
	end
	-- Nada embaixo: usa a altura do chão do mapa (ou a base da FieldArea).
	local groundY = if hasGroundY then ctx.GroundY else field.Position.Y - field.Size.Y / 2
	return Vector3.new(point.X, groundY, point.Z)
end

-- Chão logo abaixo de um brainrot que está andando (segue o relevo).
local function findWalkGround(position)
	local origin = position + Vector3.new(0, WALK_RAY_UP, 0)
	local result = workspace:Raycast(origin, Vector3.new(0, -(WALK_RAY_UP + WALK_RAY_DOWN), 0), groundParams)
	if result and result.Normal.Y >= MIN_GROUND_NORMAL_Y then
		return result.Position
	end
	return position
end

-- Raio ocupado por um brainrot (cresce com o tamanho alvo).
local function footprintRadius(def, targetSize)
	return FOOTPRINT_RADIUS * (def.BaseScale or 1) * targetSize
end

-- true se tem algum jogador perto demais de "position".
local function isNearPlayer(position, roots, radius)
	for _, root in ipairs(roots) do
		if flatDistance(position, root.Position) < radius then
			return true
		end
	end
	return false
end

-- true se tem algum brainrot vivo perto demais de "position".
-- O raio de cada um entra limitado a SPAWN_FOOTPRINT_CAP (ver a constante lá em cima).
local function isNearBrainrot(position, radius)
	local spacing = GameConfig.MinBrainrotSpacing
	radius = math.min(radius, SPAWN_FOOTPRINT_CAP)
	for _, other in ipairs(aliveList) do
		local otherRadius = math.min(other.FootprintRadius or 0, SPAWN_FOOTPRINT_CAP)
		local required = math.max(spacing, radius + otherRadius)
		if flatDistance(position, other.Position) < required then
			return true
		end
	end
	return false
end

-- O encantamento pode aparecer neste mapa? (Maps = nil -> todos)
local function enchantAllowedOnMap(enchantDef, mapId)
	local maps = enchantDef.Maps
	if maps == nil then
		return true
	end
	if type(maps) ~= "table" then
		return false
	end
	return maps[mapId] == true or table.find(maps, mapId) ~= nil
end

-- Sorteia um encantamento pelo peso (com MapOverrides[mapa].WeightMult).
local function pickEnchant(mapId)
	return Tables.WeightedPick(Enchants.List, function(enchantDef)
		if not enchantAllowedOnMap(enchantDef, mapId) then
			return 0
		end
		local weight = enchantDef.Weight or 0
		local overrides = enchantDef.MapOverrides and enchantDef.MapOverrides[mapId]
		if overrides and isFiniteNumber(overrides.WeightMult) then
			weight *= overrides.WeightMult
		end
		return weight
	end)
end

-- Sorteia qual brainrot nasce: SpawnWeight × bônus do tier pela sorte (TierLuck).
local function pickBrainrotDef(pool, tierLuck)
	return Tables.WeightedPick(pool, function(def)
		local steps = TIER_LUCK_STEPS[def.Tier] or 0
		return (def.SpawnWeight or 1) * (1 + steps * tierLuck)
	end)
end

-- Tira a entidade das listas (não destrói nada).
local function removeFromLists(entity)
	if entities[entity.Id] == entity then
		entities[entity.Id] = nil
	end
	local index = table.find(aliveList, entity)
	if index then
		-- Troca com o último e remove (mais rápido; a ordem não importa).
		aliveList[index] = aliveList[#aliveList]
		aliveList[#aliveList] = nil
	end
end

-- Descarta uma entidade sem recompensa (ex.: o modelo foi apagado por fora).
local function discardEntity(entity)
	entity.Dead = true
	removeFromLists(entity)
	entity.Trove:Clean()
end

-- Publica "Alive" só quando o número muda.
local function publishAlive()
	local count = #aliveList
	if count ~= lastAliveSent then
		lastAliveSent = count
		StateService.SetAll("Alive", count)
	end
end

-- Centro e altura do modelo (para efeitos).
local function getModelCenter(entity)
	local model = entity.Model
	if model and model.Parent then
		local ok, cframe, size = pcall(function()
			return model:GetBoundingBox()
		end)
		if ok then
			return cframe.Position, size.Y
		end
	end
	local height = DEFAULT_MODEL_HEIGHT * (entity.Def.BaseScale or 1) * entity.SizeFactor
	return entity.Position + Vector3.new(0, height / 2, 0), height
end

-- Brainrots vivos (menos "except") a até "radius" studs de "position".
local function getNeighbours(position, radius, except)
	local list = {}
	for _, other in ipairs(aliveList) do
		if other ~= except and not other.Dead then
			if flatDistance(position, other.Position) <= radius + (other.FootprintRadius or 0) then
				table.insert(list, other)
			end
		end
	end
	return list
end

-------------------------------------------------------------------------------
-- Visual (escala, barra de vida, partículas de estado)
-------------------------------------------------------------------------------

-- Aplica Model:ScaleTo(BaseScale × SizeFactor) quando o tamanho mudou o bastante.
local function applyScale(entity)
	local scale = math.max(MIN_MODEL_SCALE, (entity.Def.BaseScale or 1) * entity.SizeFactor)
	local applied = entity.AppliedScale
	if applied and math.abs(scale - applied) <= applied * SCALE_EPSILON then
		return false
	end
	entity.AppliedScale = scale
	local ok, err = pcall(function()
		entity.Model:ScaleTo(scale)
	end)
	if not ok then
		warn("[BrainrotService] ScaleTo falhou em " .. tostring(entity.Def.Id) .. ": " .. tostring(err))
	end
	return true
end

-- Atualiza a barra: azul-gelo enquanto há escudo; verde (vida) depois.
local function updateBillboard(entity)
	local billboard = entity.Billboard
	local fill = billboard and billboard.Fill
	if not fill then
		return
	end
	local fraction, color
	if entity.IceShield > 0 and entity.IceShieldMax > 0 then
		fraction = entity.IceShield / entity.IceShieldMax
		color = SHIELD_BAR_COLOR
	else
		fraction = entity.HealthFrac
		color = HEALTH_BAR_COLOR
	end
	fraction = math.clamp(fraction, 0, 1)
	-- Só mexe nas propriedades quando mudou (cada mudança vai pela rede).
	if entity.ShownFraction == nil or math.abs(entity.ShownFraction - fraction) > 0.002 then
		entity.ShownFraction = fraction
		fill.Size = UDim2.fromScale(fraction, 1)
	end
	if entity.ShownBarColor ~= color then
		entity.ShownBarColor = color
		fill.BackgroundColor3 = color
	end
end

-- Parte invisível que emite as partículas do brainrot (criada pelo BrainrotFactory).
local function getFxPart(entity)
	local model = entity.Model
	return model:FindFirstChild("FxVolume") or model.PrimaryPart
end

-- Liga/desliga um emissor de partículas de estado (fogo ou lentidão), criando na primeira vez.
local function setStatusEmitter(entity, key, enabled, texture, color, rising)
	local emitter = entity[key]
	if enabled and not emitter then
		local part = getFxPart(entity)
		if not part then
			return
		end
		local scale = entity.AppliedScale or 1
		emitter = Instance.new("ParticleEmitter")
		emitter.Name = key
		emitter.Texture = texture
		emitter.Color = ColorSequence.new(color)
		emitter.LightEmission = 0.8
		emitter.LightInfluence = 0
		emitter.Rate = if rising then 18 else 8
		emitter.Lifetime = NumberRange.new(0.5, 1)
		emitter.Speed = NumberRange.new(1 * scale, 3 * scale)
		emitter.SpreadAngle = if rising then Vector2.new(20, 20) else Vector2.new(180, 180)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, (if rising then 0.9 else 0.4) * scale),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter.Transparency = NumberSequence.new(0.15, 1)
		emitter.Parent = part
		entity[key] = emitter
		entity.Trove:Add(emitter)
	end
	if emitter and emitter.Enabled ~= enabled then
		emitter.Enabled = enabled
	end
end

-- Troca a cor do visual de encantamento (usado pelo arco-íris).
local function setEnchantColor(entity, color)
	local visual = entity.EnchantVisual
	if visual then
		if visual.Particles then
			visual.Particles.Color = ColorSequence.new(color)
		end
		if visual.Light then
			visual.Light.Color = color
		end
		if visual.Aura then
			visual.Aura.Color = color
		end
	end
	local billboard = entity.Billboard
	if billboard and billboard.EnchantLabel then
		billboard.EnchantLabel.TextColor3 = color
	end
end

-- Quebra o escudo de gelo: remove o bloco e manda o efeito "IceBreak".
local function breakIce(entity)
	entity.IceShield = 0
	entity.IceShieldMax = 0
	local block = entity.IceBlock
	entity.IceBlock = nil
	if block then
		local position, size = block.Position, math.max(block.Size.X, block.Size.Y, block.Size.Z)
		block:Destroy()
		Net.FireAll("Effect", "IceBreak", { Position = position, Size = size })
	end
end

-------------------------------------------------------------------------------
-- Criação
-------------------------------------------------------------------------------

-- Vida máxima de acordo com o tamanho atual; mantém a fração de vida e do escudo.
local function refreshMaxHealth(entity, mapId, playerCount)
	local newMax = Formulas.BrainrotMaxHealth(entity.Def, mapId, entity.SizeFactor, playerCount)
	if not isFiniteNumber(newMax) or newMax <= 0 then
		return
	end
	if entity.IceShieldMax > 0 then
		local shieldFraction = entity.IceShield / entity.IceShieldMax
		entity.IceShieldMax = GameConfig.FrozenShieldFraction * newMax
		entity.IceShield = shieldFraction * entity.IceShieldMax
	end
	entity.MaxHealth = newMax
end

-- Direção (no plano) para o brainrot olhar: para o quadro da praça, com variação.
local function pickFacing(ctx, position)
	local board = ctx and ctx.Board
	local direction
	if typeof(board) == "Instance" and board:IsA("BasePart") then
		local delta = board.Position - position
		direction = Vector3.new(delta.X, 0, delta.Z)
	end
	if not direction or direction.Magnitude < 0.01 then
		local angle = rng:NextNumber(0, math.pi * 2)
		return Vector3.new(math.sin(angle), 0, math.cos(angle))
	end
	local jitter = math.rad(rng:NextNumber(-FACE_JITTER, FACE_JITTER))
	return CFrame.Angles(0, jitter, 0):VectorToWorldSpace(direction.Unit)
end

-- Toca o bordão do brainrot (se tiver SoundId).
local function playCatchphrase(entity)
	local soundId = entity.Def.SoundId
	if not isFiniteNumber(soundId) or soundId <= 0 then
		return
	end
	local body = entity.Model.PrimaryPart
	if not body then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "Catchphrase"
	sound.SoundId = "rbxassetid://" .. tostring(math.floor(soundId))
	sound.Volume = 0.6
	sound.RollOffMaxDistance = 90
	sound.Parent = body
	task.delay(rng:NextNumber(0.1, 0.8), function()
		if sound.Parent then
			sound:Play()
		end
	end)
end

-- Cria um brainrot (modelo + entidade) e coloca no campo.
-- options = {Position, Facing, TargetSize, Giant, Enchant, Frozen}
-- env = {Now, MapId, PlayerCount}
local function createEntity(def, options, env)
	local okBuild, model = pcall(BrainrotFactory.Build, def)
	if not okBuild or typeof(model) ~= "Instance" then
		warn("[BrainrotService] Falha ao montar o modelo de " .. tostring(def.Id) .. ": " .. tostring(model))
		return nil
	end

	nextId += 1
	local id = "B" .. nextId
	local enchant = options.Enchant
	local growthMult = if enchant and isFiniteNumber(enchant.GrowthMult) and enchant.GrowthMult > 0
		then enchant.GrowthMult
		else 1
	local startSize = options.TargetSize * START_SIZE_FRACTION

	local entity = {
		Id = id,
		Def = def,
		Model = model,
		Position = options.Position,
		SizeFactor = startSize,
		TargetSize = options.TargetSize,
		StartSize = startSize,
		GrowStart = env.Now,
		GrowDuration = math.max(0.1, (def.GrowTime or 5) / growthMult),
		HealthFrac = 1,
		MaxHealth = 1,
		IceShield = 0,
		IceShieldMax = 0,
		IceBlock = nil,
		Enchant = enchant,
		Giant = options.Giant == true,
		SlowUntil = 0,
		SlowFactor = 1,
		BurnUntil = 0,
		BurnDps = 0,
		LastHitBy = nil,
		SpawnTime = env.Now,
		Dead = false,
		Billboard = nil,
		CoinValue = 0,
		-- Campos internos deste serviço:
		BurnTickAt = env.Now, -- até quando a queimadura já foi cobrada
		Facing = options.Facing,
		FootprintRadius = footprintRadius(def, options.TargetSize),
		HueOffset = rng:NextNumber(),
		Trove = Trove.new(),
	}
	entity.Trove:Add(model)

	-- Atributos no modelo (o cliente e os outros serviços leem daqui).
	model.Name = def.Id
	model:SetAttribute("BrainrotId", id)
	model:SetAttribute("DefId", def.Id)
	model:SetAttribute("Tier", def.Tier)
	model:SetAttribute("Giant", entity.Giant)
	if enchant then
		model:SetAttribute("Enchant", enchant.Id)
	end

	-- Visuais montados em escala 1 (o ScaleTo abaixo encolhe tudo junto).
	if options.Frozen then
		entity.IceBlock = BrainrotFactory.AddIceBlock(model)
	end
	if enchant then
		entity.EnchantVisual = BrainrotFactory.ApplyEnchantVisual(model, enchant)
	end
	local tier = Brainrots.Tiers[def.Tier]
	local displayName = def.DisplayName or def.Id
	if entity.Giant then
		displayName = displayName .. " GIGANTE"
	end
	entity.Billboard = BrainrotFactory.AttachBillboard(
		model,
		displayName,
		if tier then tier.Color else WHITE,
		if enchant then enchant.Name else nil,
		if enchant then enchant.Color else nil
	)

	-- Vida (e escudo de gelo) no tamanho inicial.
	refreshMaxHealth(entity, env.MapId, env.PlayerCount)
	if options.Frozen then
		entity.IceShieldMax = GameConfig.FrozenShieldFraction * entity.MaxHealth
		entity.IceShield = entity.IceShieldMax
	end
	updateBillboard(entity)

	-- Streaming: o modelo chega inteiro no cliente; os gigantes ficam sempre carregados.
	pcall(function()
		model.ModelStreamingMode = if entity.Giant then Enum.ModelStreamingMode.Persistent else Enum.ModelStreamingMode.Atomic
	end)

	-- Tamanho inicial e posição (o pivô do modelo é o centro da base = pés no chão).
	applyScale(entity)
	model:PivotTo(CFrame.lookAt(entity.Position, entity.Position + entity.Facing))
	model.Parent = ensureFolder()

	entities[id] = entity
	table.insert(aliveList, entity)

	playCatchphrase(entity)

	-- Efeito de brotar do chão, com o tamanho final aproximado.
	local baseHeight = model:GetAttribute("BaseHeight")
	if not isFiniteNumber(baseHeight) then
		baseHeight = DEFAULT_MODEL_HEIGHT
	end
	Net.FireAll("Effect", "Spawn", {
		Position = entity.Position,
		Size = baseHeight * (def.BaseScale or 1) * entity.TargetSize,
	})

	if enchant and enchant.Announce then
		StateService.NotifyAll(("Um brainrot %s nasceu: %s!"):format(enchant.Name, def.DisplayName or def.Id), "rare")
	end

	BrainrotService.Spawned:Fire(entity)
	return entity
end

-------------------------------------------------------------------------------
-- Leva de brainrots
-------------------------------------------------------------------------------

-- BrainrotService.SpawnWave(triggeredBy?) -> ok, msg
function BrainrotService.SpawnWave(triggeredBy)
	local t = now()
	if t < boardCooldownEnd then
		return false, ("O quadro está recarregando! Espere %s s."):format(formatSeconds(boardCooldownEnd - t))
	end

	local MatchService = Svc("MatchService")
	local ctx = MatchService.GetContext()
	local mapId = MatchService.GetMapId()
	local mapDef = MatchService.GetMapDef()
	local field = getField(ctx)
	if not field or not mapDef then
		return false, "O campo ainda não está pronto."
	end
	local pool = Brainrots.ByMap[mapId]
	if not pool or #pool == 0 then
		return false, "Não há brainrots para este mapa."
	end

	-- Limite de vivos (desempenho).
	local room = GameConfig.MaxBrainrotsAlive - #aliveList
	if room <= 0 then
		return false, "O campo está lotado! Destrua alguns brainrots antes de plantar mais."
	end

	local teamStats = getTeamStats()
	local count = math.min(math.max(1, math.floor(stat(teamStats, "SpawnCount", 1))), room)
	local tierLuck = math.max(0, stat(teamStats, "TierLuck", 0))
	local giantChance = stat(teamStats, "GiantChance", 0)
	local enchantChance = stat(teamStats, "EnchantChance", 0)
	local growthMult = math.max(0.01, stat(teamStats, "GrowthMult", 1))
	local frozenChance = if isFiniteNumber(mapDef.FrozenChance) then mapDef.FrozenChance else 0

	-- Buffs das receitas: próxima leva gigante / tudo encantado por um tempo.
	local team = MatchService.GetTeam()
	local buffs = team and team.Buffs
	local allGiant = buffs ~= nil and buffs.NextWaveGiant == true
	local allEnchanted = buffs ~= nil and isFiniteNumber(buffs.TimedEnchantUntil) and t < buffs.TimedEnchantUntil

	local env = {
		Now = t,
		MapId = mapId,
		PlayerCount = math.max(1, tonumber(MatchService.GetPlayerCount()) or 1),
	}
	local roots = getAliveRoots()
	refreshGroundFilter()

	local spawned = 0
	for _ = 1, count do
		local def = pickBrainrotDef(pool, tierLuck)
		if not def then
			break
		end
		local giant = allGiant or rng:NextNumber() < giantChance
		local enchant = nil
		if allEnchanted or rng:NextNumber() < enchantChance then
			enchant = pickEnchant(mapId)
		end
		local frozen = frozenChance > 0 and rng:NextNumber() < frozenChance

		-- Tamanho alvo = GrowthMult × (gigante 3 ou 1) × SizeMult do encantamento.
		local targetSize = growthMult * (if giant then GIANT_SIZE_MULT else 1) * (if enchant then enchant.SizeMult or 1 else 1)

		-- Procura um lugar livre (até SpawnAttempts tentativas). O raio usado aqui é o
		-- real, mas no máximo SPAWN_FOOTPRINT_CAP: assim brainrots enormes (muito Adubo,
		-- gigantes) ainda cabem no campo e os upgrades de quantidade/gigante continuam valendo.
		local radius = math.min(footprintRadius(def, targetSize), SPAWN_FOOTPRINT_CAP)
		local position = nil
		for _ = 1, math.max(1, math.floor(GameConfig.SpawnAttempts)) do
			local candidate = randomFieldPoint(field)
			if
				not isInExcludedZone(ctx, candidate)
				and not isNearPlayer(candidate, roots, GameConfig.PlayerExclusionRadius + radius)
				and not isNearBrainrot(candidate, radius)
			then
				position = findSpawnGround(ctx, field, candidate)
				if position then
					break
				end
			end
		end

		if position then
			local entity = createEntity(def, {
				Position = position,
				Facing = pickFacing(ctx, position),
				TargetSize = targetSize,
				Giant = giant,
				Enchant = enchant,
				Frozen = frozen,
			}, env)
			if entity then
				spawned += 1
			end
		end
	end

	if spawned == 0 then
		return false, "Não achei espaço livre no campo. Afaste-se um pouco e tente de novo."
	end

	-- Recarga do quadro.
	boardCooldownEnd = t + GameConfig.BoardCooldown
	StateService.SetAll("Board", { CooldownEnd = boardCooldownEnd })

	-- O buff "próxima leva gigante" vale para uma leva só.
	if allGiant then
		buffs.NextWaveGiant = false
		StateService.SetAll("Buffs", table.clone(buffs))
	end

	publishAlive()

	if spawned == 1 then
		return true, "1 brainrot plantado!"
	end
	return true, ("%d brainrots plantados!"):format(spawned)
end

-------------------------------------------------------------------------------
-- Dano, lentidão, fogo e morte
-------------------------------------------------------------------------------

-- A entidade ainda está viva e registrada?
local function isLive(entity)
	return type(entity) == "table" and not entity.Dead and entities[entity.Id] == entity
end

-- BrainrotService.Damage(entity, amount, attacker?, info) -> dealt, killed
-- O escudo de gelo absorve primeiro; o que sobra vai para a vida.
function BrainrotService.Damage(entity, amount, attacker, info)
	if not isLive(entity) then
		return 0, false
	end
	if not isFiniteNumber(amount) or amount <= 0 then
		return 0, false
	end
	info = if type(info) == "table" then info else {}

	local player = asPlayer(attacker)
	if player then
		entity.LastHitBy = player
	end

	-- Brainrot lento (congelado pelo Canhão de Gelato ou pela Torreta Congelante) fica frágil:
	-- leva mais dano enquanto a lentidão dura. Ex.: 20% mais lento com bônus 0,5 = +10% de dano.
	local slowBonus = tonumber(GameConfig.SlowDamageBonus) or 0
	if slowBonus > 0 and entity.SlowFactor < 1 and entity.SlowUntil > now() then
		amount *= 1 + (1 - entity.SlowFactor) * slowBonus
	end

	local remaining = amount
	local dealt = 0

	-- 1. Escudo de gelo.
	if entity.IceShield > 0 then
		local absorbed = math.min(entity.IceShield, remaining)
		entity.IceShield -= absorbed
		remaining -= absorbed
		dealt += absorbed
		if entity.IceShield <= DEATH_EPSILON then
			breakIce(entity)
		end
	end

	-- 2. Vida.
	if remaining > 0 then
		local health = entity.HealthFrac * entity.MaxHealth
		local applied = math.min(health, remaining)
		health -= applied
		dealt += applied
		entity.HealthFrac = if entity.MaxHealth > 0 then math.max(0, health / entity.MaxHealth) else 0
	end

	if entity.HealthFrac <= DEATH_EPSILON then
		-- Quem matou: o atacante (se for jogador) ou quem bateu por último.
		local killer = player or asPlayer(entity.LastHitBy)
		BrainrotService.Kill(entity, killer, info)
		return dealt, true
	end

	-- Atualiza a barra na hora (sem esperar o próximo tique do laço de 5 Hz).
	updateBillboard(entity)
	return dealt, false
end

-- BrainrotService.ApplySlow(entity, factor, duration)
-- factor = multiplicador de velocidade (0,8 = 20% mais lento). O mais forte vale enquanto durar.
function BrainrotService.ApplySlow(entity, factor, duration)
	if not isLive(entity) or not isFiniteNumber(factor) or not isFiniteNumber(duration) or duration <= 0 then
		return
	end
	factor = math.clamp(factor, 0.05, 1)
	local t = now()
	if entity.SlowUntil > t then
		entity.SlowFactor = math.min(entity.SlowFactor, factor)
	else
		entity.SlowFactor = factor
	end
	entity.SlowUntil = math.max(entity.SlowUntil, t + duration)
	setStatusEmitter(entity, "SlowParticles", true, SPARKLE_TEXTURE, SLOW_COLOR, false)
end

-- BrainrotService.Ignite(entity, dps, duration) — queima por "duration" s tirando "dps" por segundo.
function BrainrotService.Ignite(entity, dps, duration)
	if not isLive(entity) or not isFiniteNumber(dps) or dps <= 0 or not isFiniteNumber(duration) or duration <= 0 then
		return
	end
	local t = now()
	if entity.BurnUntil > t and entity.BurnDps > 0 then
		-- Já está queimando: fica com a queimadura mais forte (a cobrança continua de onde parou).
		entity.BurnDps = math.max(entity.BurnDps, dps)
	else
		-- Começa a queimar agora: a cobrança do laço conta a partir deste instante.
		entity.BurnDps = dps
		entity.BurnTickAt = t
	end
	entity.BurnUntil = math.max(entity.BurnUntil, t + duration)
	setStatusEmitter(entity, "BurnParticles", true, FIRE_TEXTURE, BURN_COLOR, true)
end

-- Soma um stat no perfil do jogador (protegido).
local function addStat(player, path)
	local ok, err = pcall(DataService.IncrementStat, player, path, 1)
	if not ok then
		warn("[BrainrotService] Erro ao somar o stat " .. path .. ": " .. tostring(err))
	end
end

-- Chama uma função de outro serviço protegida (um erro lá não quebra a morte do brainrot).
local function safeCall(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[BrainrotService] Erro em " .. label .. ": " .. tostring(err))
	end
end

-- BrainrotService.Kill(entity, killer?, info)
function BrainrotService.Kill(entity, killer, info)
	if type(entity) ~= "table" or entity.Dead then
		return
	end
	info = if type(info) == "table" then info else {}
	killer = asPlayer(killer)

	-- Marca como morto e tira da lista ANTES de tudo (evita morrer duas vezes numa cadeia).
	entity.Dead = true
	entity.HealthFrac = 0
	removeFromLists(entity)

	local MatchService = Svc("MatchService")
	local mapId = MatchService.GetMapId()
	local mapDef = MatchService.GetMapDef() or {}
	local teamStats = getTeamStats()
	local def = entity.Def
	local enchant = entity.Enchant
	local center, height = getModelCenter(entity)
	local basePosition = entity.Position

	-- 1. Moedas: valor × encantamento × multiplicador de moedas do time.
	local value = Formulas.BrainrotCoinValue(def, mapId, entity.SizeFactor)
		* Formulas.EnchantCoinMult(enchant, mapId, stat(teamStats, "EnchantPower", 1))
		* stat(teamStats, "CoinMult", 1)
	if isFiniteNumber(value) and value > 0 then
		local isTurretKill = info.Source == "Turret" and isFiniteNumber(info.TurretOwnerUserId)
		local owner = nil
		if isTurretKill then
			owner = Players:GetPlayerByUserId(info.TurretOwnerUserId)
		end
		-- Config.Game.TurretCoinSplit = "Team": as moedas da torreta são divididas entre
		-- os jogadores presentes que fazem parte da partida (quem tem run).
		local members = {}
		if isTurretKill and GameConfig.TurretCoinSplit == "Team" then
			for _, present in ipairs(Players:GetPlayers()) do
				if MatchService.GetRun(present) then
					table.insert(members, present)
				end
			end
		end
		local turretValue = value * stat(teamStats, "TurretCoinMult", 1)
		if #members > 0 then
			-- Divide em partes iguais (cada um recebe direto na carteira).
			local share = turretValue / #members
			for _, member in ipairs(members) do
				safeCall("MatchService.AddCoins", MatchService.AddCoins, member, share, "Turret")
			end
		elseif owner then
			-- Abate de torreta com o dono no servidor: moedas direto na carteira dele.
			safeCall("MatchService.AddCoins", MatchService.AddCoins, owner, turretValue, "Turret")
		else
			safeCall("CoinService.SpawnCoins", function()
				Svc("CoinService").SpawnCoins(value, center)
			end)
		end
	end

	-- 2. Explosão (chance ExplodeChance): dano em área nos vizinhos, pode virar reação em cadeia.
	if rng:NextNumber() < stat(teamStats, "ExplodeChance", 0) then
		local radius = GameConfig.ExplosionBaseRadius + EXPLOSION_RADIUS_PER_SIZE * entity.SizeFactor
		local damage = GameConfig.ExplosionDamageFraction * entity.MaxHealth
		local targets = getNeighbours(basePosition, radius, entity)
		Net.FireAll("Effect", "Explosion", { Position = center, Radius = radius })
		if killer then
			addStat(killer, "Chains")
		end
		BrainrotService.Exploded:Fire(killer)
		if #targets > 0 then
			-- Um pequeno atraso deixa a reação em cadeia visível (um estouro depois do outro).
			task.delay(CHAIN_DELAY, function()
				for _, other in ipairs(targets) do
					if isLive(other) then
						BrainrotService.Damage(other, damage, killer, { Crit = false, Source = "Explosion" })
					end
				end
			end)
		end
	end

	-- 3. Encantamento de Fogo: incendeia os vizinhos (10% da vida máx. deste brainrot por segundo).
	if enchant and enchant.Special == "Ignite" then
		local dps = GameConfig.IgniteDpsFraction * entity.MaxHealth
		for _, other in ipairs(getNeighbours(basePosition, GameConfig.IgniteRadius, entity)) do
			BrainrotService.Ignite(other, dps, GameConfig.IgniteDuration)
			if killer then
				other.BurnSource = killer
			end
		end
	end

	-- 4. Receitas (ingredientes) e Brainrot Supremo (só nos mapas que têm).
	if mapDef.HasRecipes and killer then
		safeCall("RecipeService.RollIngredient", function()
			Svc("RecipeService").RollIngredient(killer, entity)
		end)
	end
	if mapDef.HasSupreme then
		safeCall("SupremeService.OnKill", function()
			Svc("SupremeService").OnKill(entity)
		end)
	end

	-- 5. Encantamento raro (Galáctico): aviso para o servidor inteiro.
	if enchant and enchant.Announce then
		local text
		if killer then
			text = ("%s destruiu um brainrot %s: %s!"):format(killer.DisplayName, enchant.Name, def.DisplayName or def.Id)
		else
			text = ("Um brainrot %s foi destruído: %s!"):format(enchant.Name, def.DisplayName or def.Id)
		end
		StateService.NotifyAll(text, "rare")
	end

	-- 6. Efeito de morte para todos.
	Net.FireAll("Effect", "Death", {
		Position = center,
		Size = height,
		Color = if def.Colors and def.Colors.Primary then def.Colors.Primary else WHITE,
		Enchant = if enchant then enchant.Id else nil,
		Giant = entity.Giant,
	})

	-- 7. Estatísticas permanentes de quem matou.
	if killer then
		if type(def.Tier) == "string" then
			addStat(killer, "Kills." .. def.Tier)
		end
		addStat(killer, "KillsTotal")
		if entity.Giant then
			addStat(killer, "Giants")
		end
		if enchant then
			addStat(killer, "Enchanted")
			if enchant.Id == "Galactic" then
				addStat(killer, "Galactic")
			end
		end
	end

	-- 8. Some com o modelo e limpa tudo que era dele.
	entity.Trove:Clean()
	entity.LastHitBy = nil
	entity.BurnSource = nil

	publishAlive()
	BrainrotService.Killed:Fire(killer, entity, info)
end

-------------------------------------------------------------------------------
-- Consultas
-------------------------------------------------------------------------------

function BrainrotService.GetEntity(id)
	if id == nil then
		return nil
	end
	local entity = entities[id] or entities[tostring(id)]
	if entity and not entity.Dead then
		return entity
	end
	return nil
end

-- Sobe pelos pais da parte até achar o Model com o atributo "BrainrotId".
function BrainrotService.GetEntityFromPart(part)
	if typeof(part) ~= "Instance" then
		return nil
	end
	local current = part
	while current and current ~= workspace and current ~= folder do
		if current:IsA("Model") then
			local id = current:GetAttribute("BrainrotId")
			if id ~= nil then
				return BrainrotService.GetEntity(id)
			end
		end
		current = current.Parent
	end
	return nil
end

-- Cópia da lista (quem recebe pode percorrer à vontade, mesmo se alguém morrer no meio).
function BrainrotService.GetAlive()
	return table.clone(aliveList)
end

function BrainrotService.GetFolder()
	return ensureFolder()
end

-------------------------------------------------------------------------------
-- Laço de 5 Hz
-------------------------------------------------------------------------------

-- Atualiza um brainrot. "env" traz o que é igual para todos neste tique.
local function updateEntity(entity, env)
	local t = env.Now
	local model = entity.Model

	-- 1. Crescimento (ease-out: rápido no começo, devagar no fim).
	-- "needsPivot" = o modelo precisa ser recolocado na posição (depois de escalar ou andar).
	local needsPivot = false
	if entity.SizeFactor ~= entity.TargetSize then
		local progress = math.clamp((t - entity.GrowStart) / entity.GrowDuration, 0, 1)
		local eased = 1 - (1 - progress) ^ 3
		entity.SizeFactor = if progress >= 1
			then entity.TargetSize
			else entity.StartSize + (entity.TargetSize - entity.StartSize) * eased
		-- ScaleTo cresce em volta do pivô (centro da base); o PivotTo logo abaixo
		-- garante que os pés continuam exatamente em entity.Position (no chão).
		needsPivot = applyScale(entity)
	end

	-- 2. Vida máxima acompanha o tamanho (e o número de jogadores), mantendo a fração.
	refreshMaxHealth(entity, env.MapId, env.PlayerCount)

	-- Valor atual em moedas (útil para torretas escolherem o "mais valioso").
	entity.CoinValue = Formulas.BrainrotCoinValue(entity.Def, env.MapId, entity.SizeFactor)
		* Formulas.EnchantCoinMult(entity.Enchant, env.MapId, env.EnchantPower)
		* env.CoinMult

	-- 3. Queimadura: cobra só o tempo que realmente pegou fogo desde a última cobrança
	--    (BurnTickAt), sem passar do fim da queimadura (BurnUntil).
	if entity.BurnDps > 0 then
		local burnEnd = math.min(t, entity.BurnUntil)
		local burnSeconds = math.max(0, burnEnd - (entity.BurnTickAt or burnEnd))
		entity.BurnTickAt = burnEnd
		if burnSeconds > 0 then
			local _, killed = BrainrotService.Damage(
				entity,
				entity.BurnDps * burnSeconds,
				asPlayer(entity.BurnSource) or asPlayer(entity.LastHitBy),
				{ Crit = false, Source = "Burn" }
			)
			if killed then
				return
			end
		end
		if t >= entity.BurnUntil then
			entity.BurnDps = 0
			entity.BurnSource = nil
			setStatusEmitter(entity, "BurnParticles", false)
		end
	end

	-- 4. Fim da lentidão.
	if entity.SlowFactor ~= 1 and t >= entity.SlowUntil then
		entity.SlowFactor = 1
		setStatusEmitter(entity, "SlowParticles", false)
	end

	-- 5. Atração: Alto ou Gigante anda até o jogador mais perto, sem sair do campo.
	if env.AttractOn and env.Field and (entity.Def.Tier == "High" or entity.Giant) and #env.Roots > 0 then
		local nearest, bestDistance = nil, math.huge
		for _, root in ipairs(env.Roots) do
			local distance = flatDistance(entity.Position, root.Position)
			if distance < bestDistance then
				nearest, bestDistance = root, distance
			end
		end
		if nearest and bestDistance > GameConfig.AttractStopDistance then
			local step = math.min(
				GameConfig.AttractSpeed * entity.SlowFactor * env.Dt,
				bestDistance - GameConfig.AttractStopDistance
			)
			local delta = nearest.Position - entity.Position
			local direction = Vector3.new(delta.X, 0, delta.Z).Unit
			local candidate = clampToField(env.Field, entity.Position + direction * step)
			if
				step > 0
				and flatDistance(candidate, entity.Position) > 1e-3
				and not isInExcludedZone(env.Context, candidate)
			then
				entity.Position = findWalkGround(candidate)
				entity.Facing = direction
				needsPivot = true
			end
		end
	end
	-- Pivô = centro da base: colocar o pivô em Position deixa o brainrot em pé no chão,
	-- virado para "Facing".
	if needsPivot then
		model:PivotTo(CFrame.lookAt(entity.Position, entity.Position + entity.Facing))
	end

	-- 6. Arco-íris: cor girando pelo círculo de cores.
	if entity.Enchant and entity.Enchant.Rainbow then
		local hue = (t * RAINBOW_SPEED + entity.HueOffset) % 1
		setEnchantColor(entity, Color3.fromHSV(hue, 0.8, 1))
	end

	-- 7. Barra de vida.
	updateBillboard(entity)
end

local function tick(dt)
	local t = now()
	local MatchService = Svc("MatchService")
	local ctx = MatchService.GetContext()
	local teamStats = getTeamStats()

	if #aliveList > 0 then
		local attractOn = stat(teamStats, "AttractValuable", 0) >= 1
		local env = {
			Now = t,
			Dt = dt,
			MapId = MatchService.GetMapId(),
			Context = ctx,
			Field = getField(ctx),
			PlayerCount = math.max(1, tonumber(MatchService.GetPlayerCount()) or 1),
			EnchantPower = stat(teamStats, "EnchantPower", 1),
			CoinMult = stat(teamStats, "CoinMult", 1),
			AttractOn = attractOn,
			Roots = if attractOn then getAliveRoots() else {},
		}
		if attractOn then
			refreshGroundFilter()
		end

		-- Percorre uma cópia: brainrots podem morrer (queimadura) no meio do laço.
		for _, entity in ipairs(table.clone(aliveList)) do
			if entity.Dead then
				continue
			end
			if not entity.Model or not entity.Model.Parent then
				discardEntity(entity) -- o modelo sumiu por fora: tira da lista sem recompensa
				continue
			end
			local ok, err = pcall(updateEntity, entity, env)
			if not ok then
				warn("[BrainrotService] Erro ao atualizar " .. tostring(entity.Def.Id) .. ": " .. tostring(err))
			end
		end
	end

	-- Respawn automático: vivos abaixo de 30% da leva e quadro fora da recarga.
	if stat(teamStats, "AutoRespawn", 0) >= 1 and t >= boardCooldownEnd and t >= autoRespawnRetryAt then
		local spawnCount = stat(teamStats, "SpawnCount", 1)
		if #aliveList < GameConfig.AutoRespawnThreshold * spawnCount then
			local ok = BrainrotService.SpawnWave(nil)
			if not ok then
				autoRespawnRetryAt = t + AUTO_RESPAWN_RETRY
			end
		end
	end

	publishAlive()
end

-------------------------------------------------------------------------------
-- Quadro "Plantar brainrots"
-------------------------------------------------------------------------------

local function onBoardTriggered(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end

	-- Confere que o jogador está mesmo perto do quadro (o servidor é a autoridade).
	local ctx = Svc("MatchService").GetContext()
	local board = ctx and ctx.Board
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if typeof(board) == "Instance" and board:IsA("BasePart") then
		if not root or (root.Position - board.Position).Magnitude > BOARD_MAX_DISTANCE then
			return
		end
	end

	local ok, msg = BrainrotService.SpawnWave(player)
	if not ok then
		StateService.Notify(player, msg, "warning", 2)
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function BrainrotService.Init()
	ensureFolder()
	StateService.SetAll("Alive", 0)
	StateService.SetAll("Board", { CooldownEnd = 0 })
	lastAliveSent = 0

	-- Quem sai do servidor não fica "preso" como último atacante.
	trove:Connect(Players.PlayerRemoving, function(player)
		for _, entity in ipairs(aliveList) do
			if entity.LastHitBy == player then
				entity.LastHitBy = nil
			end
			if entity.BurnSource == player then
				entity.BurnSource = nil
			end
		end
	end)
end

function BrainrotService.Start()
	if started then
		return
	end
	started = true

	-- Quadro da praça.
	local ctx = Svc("MatchService").GetContext()
	local prompt = ctx and ctx.BoardPrompt
	if typeof(prompt) == "Instance" and prompt:IsA("ProximityPrompt") then
		trove:Connect(prompt.Triggered, function(player)
			local ok, err = pcall(onBoardTriggered, player)
			if not ok then
				warn("[BrainrotService] Erro no quadro: " .. tostring(err))
			end
		end)
	else
		warn("[BrainrotService] O mapa não tem BoardPrompt; o quadro não vai funcionar.")
	end

	-- Laço de 5 Hz.
	trove:Add(task.spawn(function()
		local dt = TICK_INTERVAL
		while true do
			local ok, err = pcall(tick, math.clamp(dt, 0.01, 1))
			if not ok then
				warn("[BrainrotService] Erro no laço: " .. tostring(err))
			end
			dt = task.wait(TICK_INTERVAL)
		end
	end))
end

return BrainrotService
