-- Formulas: todas as contas de balanceamento num lugar só.
-- Servidor e cliente usam as MESMAS funções, então o preço que aparece na tela
-- é exatamente o preço que o servidor cobra.

local Config = script.Parent.Parent:WaitForChild("Config")
local GameConfig = require(Config:WaitForChild("Game"))
local Maps = require(Config:WaitForChild("Maps"))
local StatsConfig = require(Config:WaitForChild("Stats"))
local Weapons = require(Config:WaitForChild("Weapons"))
local Upgrades = require(Config:WaitForChild("Upgrades"))
local Recipes = require(Config:WaitForChild("Recipes"))
local Quests = require(Config:WaitForChild("Quests"))
-- Bônus dos game passes (VIP e Dano em Dobro) lidos do Config.Game, com proteção.
local Gamepasses = require(script.Parent:WaitForChild("Gamepasses"))

local Formulas = {}

-- Lembra quais avisos já foram mostrados, para não lotar o Output.
local warned = {}
local function warnOnce(message)
	if not warned[message] then
		warned[message] = true
		warn(message)
	end
end

-- Devolve a definição do mapa (ou nil, com aviso, se o id não existe).
local function getMap(mapId)
	local mapDef = Maps[mapId]
	if type(mapDef) ~= "table" or mapDef.Act == nil then
		warnOnce("[Formulas] Mapa desconhecido: " .. tostring(mapId))
		return nil
	end
	return mapDef
end

-- Lê um número de um campo do mapa, com valor padrão se faltar.
local function mapNumber(mapId, field, default)
	local mapDef = getMap(mapId)
	if mapDef and type(mapDef[field]) == "number" then
		return mapDef[field]
	end
	return default
end

-- Garante que um nível é um número inteiro >= 0.
local function sanitizeLevel(level)
	if type(level) ~= "number" or level ~= level then
		return 0
	end
	return math.max(0, math.floor(level))
end

-------------------------------------------------------------------------------
-- Efeitos e custos de upgrades
-------------------------------------------------------------------------------

-- Formulas.ApplyEffect(value, mode, perLevel, level) -> novo valor
--   "Add"  -> value + perLevel * level        (soma fixa por nível)
--   "Mult" -> value * (1 + perLevel * level)  (porcentagem por nível, somada)
--   "Pow"  -> value * perLevel ^ level        (porcentagem por nível, composta)
function Formulas.ApplyEffect(value, mode, perLevel, level)
	value = value or 0
	level = level or 0
	if mode == "Add" then
		return value + perLevel * level
	elseif mode == "Mult" then
		return value * (1 + perLevel * level)
	elseif mode == "Pow" then
		return value * perLevel ^ level
	end
	warnOnce("[Formulas] Mode de efeito desconhecido: " .. tostring(mode))
	return value
end

-- Formulas.UpgradeCost(def, currentLevel) -> custo do PRÓXIMO nível.
-- custo = BaseCost × CostScale do mapa × CostMult ^ nível atual
function Formulas.UpgradeCost(def, currentLevel)
	local costScale = mapNumber(def.Map, "CostScale", 1)
	return def.BaseCost * costScale * def.CostMult ^ sanitizeLevel(currentLevel)
end

-- Formulas.CostForLevels(def, currentLevel, count) -> totalCost, levels
-- Quanto custa comprar "count" níveis a partir do nível atual.
-- Nunca passa do MaxLevel: "levels" diz quantos níveis dá para comprar de fato.
function Formulas.CostForLevels(def, currentLevel, count)
	currentLevel = sanitizeLevel(currentLevel)
	count = sanitizeLevel(count)
	local maxLevel = def.MaxLevel or math.huge
	local levels = math.max(0, math.min(count, maxLevel - currentLevel))

	local total = 0
	for i = 0, levels - 1 do
		total += Formulas.UpgradeCost(def, currentLevel + i)
	end
	return total, levels
end

-- Formulas.MaxAffordable(def, currentLevel, coins) -> levels, totalCost
-- Quantos níveis seguidos dá para comprar com "coins" moedas (botão "Máx").
function Formulas.MaxAffordable(def, currentLevel, coins)
	currentLevel = sanitizeLevel(currentLevel)
	coins = tonumber(coins) or 0
	local maxLevel = def.MaxLevel or math.huge

	local levels = 0
	local total = 0
	-- Vai somando o preço de cada nível enquanto couber no bolso.
	-- (O limite de 10000 é só uma trava de segurança contra laço infinito.)
	while currentLevel + levels < maxLevel and levels < 10000 do
		local cost = Formulas.UpgradeCost(def, currentLevel + levels)
		if total + cost > coins then
			break
		end
		total += cost
		levels += 1
	end
	return levels, total
end

-- Formulas.IsUpgradeMaxed(def, level) -> true se o upgrade já está no nível máximo.
function Formulas.IsUpgradeMaxed(def, level)
	return sanitizeLevel(level) >= (def.MaxLevel or math.huge)
end

-- Formulas.ShelfCost(mapId, nextShelf) -> custo para liberar a prateleira "nextShelf".
-- = ShelfCosts[nextShelf] × CostScale. Se a prateleira não existe, devolve math.huge
-- (assim qualquer comparação "moedas >= custo" dá falso).
function Formulas.ShelfCost(mapId, nextShelf)
	local mapDef = getMap(mapId)
	local shelfCosts = mapDef and mapDef.ShelfCosts
	local baseCost = shelfCosts and shelfCosts[nextShelf]
	if type(baseCost) ~= "number" then
		return math.huge
	end
	return baseCost * (mapDef.CostScale or 1)
end

-------------------------------------------------------------------------------
-- Evento global (comando de admin ":event", Config.Admins.Events)
-------------------------------------------------------------------------------
-- extras.Event = tabela Effects do evento ativo (ou nil sem evento). Campos opcionais:
--   CoinMult          -> moedas × isto (entra no PassCoinMult, junto com os game passes)
--   TierLuckAdd       -> TierLuck + isto
--   EnchantChanceMult -> EnchantChance × isto
--   GiantChanceAdd    -> GiantChance + isto
--   BoardCooldownMult -> recarga do quadro × isto (o BrainrotService lê com EventBoardCooldownMult)
-- Os eventos são GRÁTIS (um admin liga para todo mundo; ninguém paga Robux), então não
-- são "sorte paga" e não precisam mostrar chances.

-- Limites de segurança dos efeitos (constantes técnicas, não são balanceamento): um número
-- errado no Config nunca vira moedas ×1000 nem uma recarga zero.
local EVENT_MAX_COIN_MULT = 10
local EVENT_MAX_LUCK_ADD = 10
local EVENT_MAX_ENCHANT_MULT = 10
local EVENT_MIN_COOLDOWN_MULT = 0.1

-- Lê um número dos efeitos do evento, com valor padrão e limites.
local function eventNumber(effects, field, default, minValue, maxValue)
	if type(effects) ~= "table" then
		return default
	end
	local value = effects[field]
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return default
	end
	return math.clamp(value, minValue, maxValue)
end

-- Formulas.EventCoinMult(effects) -> multiplicador de moedas do evento (1 sem evento).
function Formulas.EventCoinMult(effects)
	return eventNumber(effects, "CoinMult", 1, 1, EVENT_MAX_COIN_MULT)
end

-- Formulas.EventBoardCooldownMult(effects) -> multiplicador da recarga do quadro (1 sem evento).
function Formulas.EventBoardCooldownMult(effects)
	return eventNumber(effects, "BoardCooldownMult", 1, EVENT_MIN_COOLDOWN_MULT, 1)
end

-- Formulas.ApplyEventEffects(stats, effects) — aplica a sorte e os gigantes do evento
-- nos stats (muda a própria tabela). O ComputeStats chama isto depois dos upgrades e
-- ANTES dos limites (Clamps), então a chance de gigante e a de encantamento continuam
-- com o teto do Config.Stats.
function Formulas.ApplyEventEffects(stats, effects)
	if type(stats) ~= "table" or type(effects) ~= "table" then
		return
	end
	stats.TierLuck = (stats.TierLuck or 0) + eventNumber(effects, "TierLuckAdd", 0, 0, EVENT_MAX_LUCK_ADD)
	stats.EnchantChance = (stats.EnchantChance or 0) * eventNumber(effects, "EnchantChanceMult", 1, 1, EVENT_MAX_ENCHANT_MULT)
	stats.GiantChance = (stats.GiantChance or 0) + eventNumber(effects, "GiantChanceAdd", 0, 0, 1)
end

-------------------------------------------------------------------------------
-- Cálculo de todos os stats
-------------------------------------------------------------------------------

-- Formulas.PassCoinMult(extras) -> multiplicador de moedas que o MatchService.AddCoins aplica.
--   extras.DoubleCoins -> ×2;  extras.VIP -> × Config.Game.GamepassVipCoinMult (1,25);
--   extras.Event (evento global, ex.: "moedas2x") -> × Effects.CoinMult.
--   Tudo junto multiplica: 2 × 1,25 × 2 = 5.
-- O MatchService.AddCoins usa esta função nas moedas de verdade e o ComputeStats usa
-- para mostrar o "Multiplicador de Moedas" na tela: as duas contas são sempre iguais.
-- (A missão divide a renda por este mesmo número para o bônus não contar duas vezes.)
function Formulas.PassCoinMult(extras)
	local mult = 1
	if type(extras) ~= "table" then
		return mult
	end
	if extras.DoubleCoins == true then
		mult *= 2
	end
	if extras.VIP == true then
		mult *= Gamepasses.VipCoinMult()
	end
	mult *= Formulas.EventCoinMult(extras.Event)
	return mult
end

-- Formulas.ComputeStats(mapId, playerLevels, teamLevels, recipesApplied, extras) -> stats
--   playerLevels   = {[upgradeId] = nível} do jogador (upgrades de escopo "Player")
--   teamLevels     = {[upgradeId] = nível} do time (upgrades de escopo "Team")
--   recipesApplied = {[recipeId] = true} receitas permanentes feitas nesta partida
--   extras         = {DoubleCoins = boolean, VIP = boolean, DoubleDamage = boolean,
--                     Event = Effects do evento global?, Team = boolean?}
--                    (game passes do PRÓPRIO jogador; nos stats do time vai {Team = true, Event = ...}:
--                     com Team = true o bônus de moedas NÃO entra no CoinMult, porque o
--                     MatchService.AddCoins já aplica ele em cada jogador)
-- Devolve uma tabela NOVA {[statKey] = número}.
function Formulas.ComputeStats(mapId, playerLevels, teamLevels, recipesApplied, extras)
	playerLevels = playerLevels or {}
	teamLevels = teamLevels or {}
	recipesApplied = recipesApplied or {}
	extras = extras or {}

	-- 1. Começa com uma cópia dos valores padrão.
	local stats = table.clone(StatsConfig.Defaults)

	local mapDef = getMap(mapId)
	if mapDef then
		-- 2. Aplica os stats da arma do mapa (substituem os padrões).
		local weapon = Weapons[mapDef.Weapon]
		if weapon and weapon.Stats then
			for statKey, value in pairs(weapon.Stats) do
				stats[statKey] = value
			end
		elseif mapDef.Weapon ~= nil then
			warnOnce("[Formulas] Arma desconhecida no mapa " .. tostring(mapId) .. ": " .. tostring(mapDef.Weapon))
		end

		-- 3. Aplica as trocas específicas do mapa (ex.: TurretDamage no Inverno).
		if mapDef.StatOverrides then
			for statKey, value in pairs(mapDef.StatOverrides) do
				stats[statKey] = value
			end
		end

		-- 4. Aplica os upgrades do mapa, NA ORDEM da lista (a ordem importa:
		--    somar e depois multiplicar dá resultado diferente de multiplicar e depois somar).
		local mapUpgrades = Upgrades.ByMap[mapId] or {}
		for _, def in ipairs(mapUpgrades) do
			-- Cada upgrade lê o nível no escopo certo: do time ou do jogador.
			local levels = if def.Scope == "Team" then teamLevels else playerLevels
			local level = sanitizeLevel(levels[def.Id])
			if def.MaxLevel then
				level = math.min(level, def.MaxLevel)
			end
			if level > 0 then
				stats[def.Stat] = Formulas.ApplyEffect(stats[def.Stat] or 0, def.Mode, def.Value, level)
			end
		end
	end

	-- 5. Aplica as receitas permanentes já feitas (cada efeito como um upgrade de nível 1).
	--    Percorre a lista do Config para a ordem ser sempre a mesma.
	for _, recipe in ipairs(Recipes.Recipes or {}) do
		if recipesApplied[recipe.Id] and recipe.Kind == "Permanent" and recipe.Effects then
			for _, effect in ipairs(recipe.Effects) do
				stats[effect.Stat] = Formulas.ApplyEffect(stats[effect.Stat] or 0, effect.Mode, effect.Value, 1)
			end
		end
	end

	-- 6. Game passes e evento global (depois dos upgrades e receitas, antes dos limites).
	--    Moedas em Dobro, VIP e o evento "moedas" multiplicam o CoinMult (a mesma conta do
	--    MatchService.AddCoins). Nos stats do time (extras.Team) não: o valor dos brainrots
	--    usa o CoinMult do time e o AddCoins aplica o bônus depois, em cada jogador.
	if extras.Team ~= true then
		stats.CoinMult *= Formulas.PassCoinMult(extras)
	end
	--    Dano em Dobro: só o dano da arma do jogador (TurretDamage, das torretas, não muda).
	if extras.DoubleDamage == true then
		stats.Damage = (stats.Damage or 0) * Gamepasses.DAMAGE_MULT
	end
	--    Evento global: sorte de tier, chance de encantamento e de gigante (para todos).
	Formulas.ApplyEventEffects(stats, extras.Event)

	-- 7. Limites mínimo/máximo de cada stat.
	for statKey, range in pairs(StatsConfig.Clamps) do
		if type(stats[statKey]) == "number" then
			stats[statKey] = math.clamp(stats[statKey], range[1], range[2])
		end
	end

	-- Projéteis e perfuração são contagens: sempre inteiros (arredonda para baixo).
	-- O "+ 1e-9" evita que 2,9999999 (erro de conta) vire 2.
	stats.Projectiles = math.floor(stats.Projectiles + 1e-9)
	stats.Pierce = math.floor(stats.Pierce + 1e-9)

	return stats
end

-------------------------------------------------------------------------------
-- Brainrots, encantamentos e missões
-------------------------------------------------------------------------------

-- Formulas.BrainrotMaxHealth(def, mapId, sizeFactor, playerCount) -> vida máxima.
-- Maior = mais vida (cresce com o quadrado do tamanho); mais jogadores = mais vida.
function Formulas.BrainrotMaxHealth(def, mapId, sizeFactor, playerCount)
	local healthScale = mapNumber(mapId, "HealthScale", 1)
	sizeFactor = sizeFactor or 1
	playerCount = math.max(1, playerCount or 1)
	local playerScale = 1 + GameConfig.HealthScalePerExtraPlayer * (playerCount - 1)
	return def.BaseHealth * healthScale * sizeFactor ^ 2 * playerScale
end

-- Formulas.BrainrotCoinValue(def, mapId, sizeFactor) -> moedas que o brainrot vale.
function Formulas.BrainrotCoinValue(def, mapId, sizeFactor)
	local valueScale = mapNumber(mapId, "ValueScale", 1)
	sizeFactor = sizeFactor or 1
	return def.BaseCoinValue * valueScale * sizeFactor ^ 2
end

-- Formulas.EnchantCoinMult(enchantDef, mapId, enchantPower) -> multiplicador de moedas.
-- = 1 + (CoinMult - 1) × EnchantPower. Usa MapOverrides[mapId].CoinMult se existir
-- (ex.: Gelo vale ×6 no Inverno). Sem encantamento -> 1.
function Formulas.EnchantCoinMult(enchantDef, mapId, enchantPower)
	if not enchantDef then
		return 1
	end
	local coinMult = enchantDef.CoinMult or 1
	local overrides = enchantDef.MapOverrides and enchantDef.MapOverrides[mapId]
	if overrides and type(overrides.CoinMult) == "number" then
		coinMult = overrides.CoinMult
	end
	return 1 + (coinMult - 1) * (enchantPower or 1)
end

-- Formulas.QuestReward(mapId, income, questRewardStat) -> moedas da recompensa.
-- = max(RewardFloor × CostScale, renda/s × RewardSeconds) × stats.QuestReward
function Formulas.QuestReward(mapId, income, questRewardStat)
	local costScale = mapNumber(mapId, "CostScale", 1)
	local floorReward = Quests.RewardFloor * costScale
	local incomeReward = math.max(0, tonumber(income) or 0) * Quests.RewardSeconds
	return math.max(floorReward, incomeReward) * (questRewardStat or 1)
end

return Formulas
