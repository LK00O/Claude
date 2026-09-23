-- Config/Upgrades: todos os upgrades das barracas dos três mapas.
--
-- Cada upgrade vira uma tabela assim:
--   { Id = "M_Damage", Map = "Meadow", Stall = "Weapon", Shelf = 1, Scope = "Player",
--     Name = "Dano", Description = "+25% de dano por nível",
--     MaxLevel = 25, BaseCost = 10, CostMult = 1.55,
--     Stat = "Damage", Mode = "Pow", Value = 1.25 }
--
-- Campos:
--   Stall  : barraca onde aparece ("Weapon", "Brainrot", "Quest", "Turret", "Growth").
--   Shelf  : prateleira da barraca (1, 2 ou 3). Só dá para comprar com a prateleira liberada.
--   Scope  : "Player" = cada jogador tem o seu nível e paga o seu;
--            "Team"   = nível do time; qualquer um paga e vale para todos.
--   Custo do próximo nível = BaseCost * CostScale do mapa * CostMult ^ nívelAtual.
--   Mode   : como o Value mexe no Stat a cada nível:
--            "Add"  -> stat + Value * nível
--            "Mult" -> stat * (1 + Value * nível)
--            "Pow"  -> stat * Value ^ nível

local List = {}

-- Cria uma função que adiciona upgrades de um mapa, na mesma ordem das colunas
-- da tabela da especificação (mais a descrição logo depois do nome).
local function Adder(mapId)
	return function(id, stall, shelf, scope, name, description, maxLevel, baseCost, costMult, stat, mode, value)
		table.insert(List, {
			Id = id,
			Map = mapId,
			Stall = stall,
			Shelf = shelf,
			Scope = scope,
			Name = name,
			Description = description,
			MaxLevel = maxLevel,
			BaseCost = baseCost,
			CostMult = costMult,
			Stat = stat,
			Mode = mode,
			Value = value,
		})
	end
end

-- Ordem dos argumentos:
-- (Id, Barraca, Prateleira, Escopo, Nome, Descrição, Máx, Custo base, Mult, Stat, Mode, Value)

-------------------------------------------------------------------------------
-- ATO 1: Prado (Meadow)
-------------------------------------------------------------------------------
local M = Adder("Meadow")

-- Prateleira 1: Barraca de Arma
M("M_Damage", "Weapon", 1, "Player", "Dano", "+25% de dano por nível", 25, 10, 1.55, "Damage", "Pow", 1.25)
M("M_FireRate", "Weapon", 1, "Player", "Cadência", "+8% de tiros por segundo por nível", 20, 15, 1.6, "FireRate", "Mult", 0.08)
M("M_Projectiles", "Weapon", 1, "Player", "Projéteis", "+1 projétil por tiro, em leque", 8, 250, 3.2, "Projectiles", "Add", 1)
M("M_Pierce", "Weapon", 1, "Player", "Perfuração", "A bala atravessa +1 brainrot por nível", 6, 500, 3.5, "Pierce", "Add", 1)
M("M_Crit", "Weapon", 1, "Player", "Chance de Crítico", "+3% de chance de acerto crítico por nível", 15, 100, 1.9, "CritChance", "Add", 0.03)
M("M_Caliber", "Weapon", 1, "Player", "Calibre", "Balas +10% maiores por nível: fica mais fácil acertar", 10, 60, 1.8, "Caliber", "Mult", 0.1)

-- Prateleira 1: Barraca de Brainrots
M("M_Spawn", "Brainrot", 1, "Team", "Mais Brainrots", "+1 brainrot em cada leva", 20, 20, 1.65, "SpawnCount", "Add", 1)
M("M_Explode", "Brainrot", 1, "Team", "Brainrot Explosivo", "+2% de chance do brainrot explodir ao morrer e ferir os vizinhos", 15, 150, 1.9, "ExplodeChance", "Add", 0.02)
M("M_Giant", "Brainrot", 1, "Team", "Brainrot Gigante", "+2% de chance de nascer um brainrot 3× maior (muito mais moedas)", 15, 200, 1.95, "GiantChance", "Add", 0.02)
M("M_Growth", "Brainrot", 1, "Team", "Adubo Brainrot", "Brainrots crescem +10% maiores por nível: mais vida e mais moedas", 20, 40, 1.7, "GrowthMult", "Pow", 1.1)

-- Prateleira 1: Barraca de Missões
M("M_QuestReward", "Quest", 1, "Player", "Recompensa de Missão", "+20% de moedas nas recompensas de missão por nível", 10, 300, 2.2, "QuestReward", "Mult", 0.2)
M("M_QuestCooldown", "Quest", 1, "Player", "Espera de Missão", "-8% de espera entre missões por nível", 8, 300, 2.3, "QuestCooldown", "Pow", 0.92)

-- Prateleira 2: Arma
M("M_CritMult", "Weapon", 2, "Player", "Multiplicador de Crítico", "+0,25× de dano nos acertos críticos por nível", 10, 5e3, 1.9, "CritMult", "Add", 0.25)
M("M_Damage2", "Weapon", 2, "Player", "Dano+", "+20% de dano por nível, somando com o Dano", 15, 1e4, 1.6, "Damage", "Pow", 1.2)
M("M_FireRate2", "Weapon", 2, "Player", "Cadência+", "+6% de tiros por segundo por nível, somando com a Cadência", 10, 1e4, 1.7, "FireRate", "Mult", 0.06)

-- Prateleira 2: Brainrots
M("M_Magnet", "Brainrot", 2, "Team", "Ímã de Moedas", "Puxa as moedas próximas até você: +4 studs de raio por nível", 10, 3e3, 1.8, "MagnetRadius", "Add", 4)
M("M_AutoCollect", "Brainrot", 2, "Team", "Coleta Automática", "Toda moeda vai sozinha para o jogador mais perto", 1, 5e5, 1, "AutoCollect", "Add", 1)
M("M_Attract", "Brainrot", 2, "Team", "Atrair Brainrots Valiosos", "Brainrots de tier Alto e Gigantes andam devagar até o jogador mais perto", 1, 1e5, 1, "AttractValuable", "Add", 1)
M("M_AutoRespawn", "Brainrot", 2, "Team", "Respawn Automático", "O quadro planta uma nova leva sozinho quando o campo fica quase vazio", 1, 5e4, 1, "AutoRespawn", "Add", 1)
M("M_TierLuck", "Brainrot", 2, "Team", "Sorte de Tier", "Brainrots de tier Médio e Alto aparecem mais: +15% de sorte por nível", 10, 8e3, 1.9, "TierLuck", "Add", 0.15)
M("M_Enchant", "Brainrot", 2, "Team", "Chance de Encantamento", "+2% de chance de nascer brainrot encantado por nível", 10, 2e4, 1.9, "EnchantChance", "Add", 0.02)

-- Prateleira 3: Brainrots (níveis extras e multiplicadores)
M("M_Spawn2", "Brainrot", 3, "Team", "Mais Brainrots+", "+1 brainrot em cada leva (níveis extras)", 10, 2e5, 1.45, "SpawnCount", "Add", 1)
M("M_Explode2", "Brainrot", 3, "Team", "Explosivo+", "+2% de chance de explosão por nível (níveis extras)", 10, 2e5, 1.45, "ExplodeChance", "Add", 0.02)
M("M_Giant2", "Brainrot", 3, "Team", "Gigante+", "+2% de chance de Gigante por nível (níveis extras)", 10, 2e5, 1.45, "GiantChance", "Add", 0.02)
M("M_Growth2", "Brainrot", 3, "Team", "Adubo+", "Brainrots crescem +8% maiores por nível (níveis extras)", 10, 2e5, 1.45, "GrowthMult", "Pow", 1.08)
M("M_CoinMult", "Brainrot", 3, "Team", "Multiplicador de Moedas", "+10% de moedas de todos os brainrots por nível", 10, 4e5, 1.45, "CoinMult", "Mult", 0.1)
M("M_EnchantPower", "Brainrot", 3, "Team", "Poder de Encantamento", "Bônus de moedas dos encantamentos +15% mais forte por nível", 10, 4e5, 1.45, "EnchantPower", "Mult", 0.15)

-------------------------------------------------------------------------------
-- ATO 2: Inverno (Winter)
-------------------------------------------------------------------------------
local W = Adder("Winter")

-- Prateleira 1: Barraca de Arma (Canhão de Gelato)
W("W_Damage", "Weapon", 1, "Player", "Dano", "+25% de dano por nível", 25, 10, 1.55, "Damage", "Pow", 1.25)
W("W_FireRate", "Weapon", 1, "Player", "Cadência", "+8% de tiros por segundo por nível", 20, 15, 1.6, "FireRate", "Mult", 0.08)
W("W_Splash", "Weapon", 1, "Player", "Raio da Explosão", "+1,5 stud no raio da explosão de gelato por nível", 10, 200, 2.4, "SplashRadius", "Add", 1.5)
W("W_Slow", "Weapon", 1, "Player", "Congelamento", "Os tiros deixam os brainrots +5% mais lentos por nível", 10, 150, 2.2, "SlowPower", "Add", 0.05)
W("W_Crit", "Weapon", 1, "Player", "Chance de Crítico", "+3% de chance de acerto crítico por nível", 15, 100, 1.9, "CritChance", "Add", 0.03)
W("W_Caliber", "Weapon", 1, "Player", "Calibre", "Bolas de gelato +10% maiores por nível: fica mais fácil acertar", 10, 60, 1.8, "Caliber", "Mult", 0.1)

-- Prateleira 1: Barraca de Brainrots (iguais aos do Prado)
W("W_Spawn", "Brainrot", 1, "Team", "Mais Brainrots", "+1 brainrot em cada leva", 20, 20, 1.65, "SpawnCount", "Add", 1)
W("W_Explode", "Brainrot", 1, "Team", "Brainrot Explosivo", "+2% de chance do brainrot explodir ao morrer e ferir os vizinhos", 15, 150, 1.9, "ExplodeChance", "Add", 0.02)
W("W_Giant", "Brainrot", 1, "Team", "Brainrot Gigante", "+2% de chance de nascer um brainrot 3× maior (muito mais moedas)", 15, 200, 1.95, "GiantChance", "Add", 0.02)
W("W_Growth", "Brainrot", 1, "Team", "Adubo Brainrot", "Brainrots crescem +10% maiores por nível: mais vida e mais moedas", 20, 40, 1.7, "GrowthMult", "Pow", 1.1)

-- Prateleira 1: Barraca de Missões (iguais aos do Prado)
W("W_QuestReward", "Quest", 1, "Player", "Recompensa de Missão", "+20% de moedas nas recompensas de missão por nível", 10, 300, 2.2, "QuestReward", "Mult", 0.2)
W("W_QuestCooldown", "Quest", 1, "Player", "Espera de Missão", "-8% de espera entre missões por nível", 8, 300, 2.3, "QuestCooldown", "Pow", 0.92)

-- Prateleira 1: Barraca de Torretas
W("W_TurretCount", "Turret", 1, "Team", "Mais Torretas", "+1 torreta que o time pode posicionar no campo", 8, 100, 2.6, "TurretCount", "Add", 1)
W("W_TurretDamage", "Turret", 1, "Team", "Dano das Torretas", "+25% de dano das torretas por nível", 20, 50, 1.7, "TurretDamage", "Pow", 1.25)
W("W_TurretRate", "Turret", 1, "Team", "Cadência das Torretas", "+10% de tiros por segundo das torretas por nível", 15, 80, 1.75, "TurretFireRate", "Mult", 0.1)
W("W_TurretRange", "Turret", 1, "Team", "Alcance das Torretas", "+5 studs de alcance das torretas por nível", 10, 60, 1.8, "TurretRange", "Add", 5)
W("W_TurretAim", "Turret", 1, "Team", "Mira das Torretas", "+4% de precisão das torretas por nível (treino de mira)", 9, 70, 1.9, "TurretAccuracy", "Add", 0.04)

-- Prateleira 2
W("W_Visibility", "Brainrot", 2, "Team", "Farol da Nevasca", "A neblina da nevasca fica 25% mais fraca por nível", 5, 2e3, 2.5, "Visibility", "Add", 1)
W("W_Magnet", "Brainrot", 2, "Team", "Ímã de Moedas", "Puxa as moedas próximas até você: +4 studs de raio por nível", 10, 3e3, 1.8, "MagnetRadius", "Add", 4)
W("W_AutoCollect", "Brainrot", 2, "Team", "Coleta Automática", "Toda moeda vai sozinha para o jogador mais perto", 1, 5e5, 1, "AutoCollect", "Add", 1)
W("W_TurretFreeze", "Turret", 2, "Team", "Torreta Congelante", "Os tiros das torretas deixam os brainrots +10% mais lentos por nível", 5, 5e3, 2.2, "TurretSlow", "Add", 0.1)
W("W_IceAura", "Brainrot", 2, "Team", "Aura de Gelo", "+3% de chance de nascer brainrot encantado por nível (o Gelo vale muito mais aqui!)", 10, 3e3, 1.9, "EnchantChance", "Add", 0.03)
W("W_TierLuck", "Brainrot", 2, "Team", "Sorte de Tier", "Brainrots de tier Médio e Alto aparecem mais: +15% de sorte por nível", 10, 8e3, 1.9, "TierLuck", "Add", 0.15)
W("W_CritMult", "Weapon", 2, "Player", "Multiplicador de Crítico", "+0,25× de dano nos acertos críticos por nível", 10, 5e3, 1.9, "CritMult", "Add", 0.25)

-- Prateleira 3
W("W_Spawn2", "Brainrot", 3, "Team", "Mais Brainrots+", "+1 brainrot em cada leva (níveis extras)", 10, 2e5, 1.45, "SpawnCount", "Add", 1)
W("W_Growth2", "Brainrot", 3, "Team", "Adubo+", "Brainrots crescem +8% maiores por nível (níveis extras)", 10, 2e5, 1.45, "GrowthMult", "Pow", 1.08)
W("W_CoinMult", "Brainrot", 3, "Team", "Multiplicador de Moedas", "+10% de moedas de todos os brainrots por nível", 10, 4e5, 1.45, "CoinMult", "Mult", 0.1)
W("W_EnchantPower", "Brainrot", 3, "Team", "Poder de Encantamento", "Bônus de moedas dos encantamentos +15% mais forte por nível", 10, 4e5, 1.45, "EnchantPower", "Mult", 0.15)
W("W_TurretCoins", "Turret", 3, "Team", "Moedas de Torreta", "+20% de moedas nos brainrots destruídos por torretas por nível", 10, 2e5, 1.45, "TurretCoinMult", "Mult", 0.2)
W("W_Damage2", "Weapon", 3, "Player", "Dano+", "+20% de dano por nível, somando com o Dano", 15, 1e4, 1.6, "Damage", "Pow", 1.2)

-------------------------------------------------------------------------------
-- ATO 3: Deserto (Desert)
-------------------------------------------------------------------------------
local D = Adder("Desert")

-- Prateleira 1: Barraca de Arma (Metralhadora de Tralalero)
D("D_Damage", "Weapon", 1, "Player", "Dano", "+25% de dano por nível", 25, 10, 1.55, "Damage", "Pow", 1.25)
D("D_FireRate", "Weapon", 1, "Player", "Cadência", "+8% de tiros por segundo por nível", 20, 15, 1.6, "FireRate", "Mult", 0.08)
D("D_Projectiles", "Weapon", 1, "Player", "Projéteis", "+1 projétil por tiro, em leque", 5, 300, 3.4, "Projectiles", "Add", 1)
D("D_Pierce", "Weapon", 1, "Player", "Perfuração", "A bala atravessa +1 brainrot por nível", 6, 500, 3.5, "Pierce", "Add", 1)
D("D_Crit", "Weapon", 1, "Player", "Chance de Crítico", "+3% de chance de acerto crítico por nível", 15, 100, 1.9, "CritChance", "Add", 0.03)
D("D_Cooling", "Weapon", 1, "Player", "Resfriamento", "A arma esfria +15% mais rápido por nível", 15, 80, 1.8, "HeatCooling", "Mult", 0.15)
D("D_HeatCap", "Weapon", 1, "Player", "Tanque de Calor", "A arma aguenta +15% de calor antes de superaquecer por nível", 15, 80, 1.8, "HeatCapacity", "Mult", 0.15)

-- Prateleira 1: Barraca de Brainrots (iguais aos do Prado + Chapéu de Palha)
D("D_Spawn", "Brainrot", 1, "Team", "Mais Brainrots", "+1 brainrot em cada leva", 20, 20, 1.65, "SpawnCount", "Add", 1)
D("D_Explode", "Brainrot", 1, "Team", "Brainrot Explosivo", "+2% de chance do brainrot explodir ao morrer e ferir os vizinhos", 15, 150, 1.9, "ExplodeChance", "Add", 0.02)
D("D_Giant", "Brainrot", 1, "Team", "Brainrot Gigante", "+2% de chance de nascer um brainrot 3× maior (muito mais moedas)", 15, 200, 1.95, "GiantChance", "Add", 0.02)
D("D_Growth", "Brainrot", 1, "Team", "Adubo Brainrot", "Brainrots crescem +10% maiores por nível: mais vida e mais moedas", 20, 40, 1.7, "GrowthMult", "Pow", 1.1)
D("D_Straw", "Brainrot", 1, "Team", "Chapéu de Palha", "O time fica imune ao calor do deserto longe da sombra do oásis", 1, 500, 1, "HeatImmunity", "Add", 1)

-- Prateleira 1: Barraca de Missões (iguais aos do Prado)
D("D_QuestReward", "Quest", 1, "Player", "Recompensa de Missão", "+20% de moedas nas recompensas de missão por nível", 10, 300, 2.2, "QuestReward", "Mult", 0.2)
D("D_QuestCooldown", "Quest", 1, "Player", "Espera de Missão", "-8% de espera entre missões por nível", 8, 300, 2.3, "QuestCooldown", "Pow", 0.92)

-- Prateleira 1: Barraca de Torretas
D("D_TurretCount", "Turret", 1, "Team", "Mais Torretas", "+1 torreta que o time pode posicionar no campo", 6, 150, 2.8, "TurretCount", "Add", 1)
D("D_TurretDamage", "Turret", 1, "Team", "Dano das Torretas", "+25% de dano das torretas por nível", 20, 50, 1.7, "TurretDamage", "Pow", 1.25)
D("D_TurretRate", "Turret", 1, "Team", "Cadência das Torretas", "+10% de tiros por segundo das torretas por nível", 15, 80, 1.75, "TurretFireRate", "Mult", 0.1)

-- Prateleira 1: Barraca de Crescimento (Brainrot Supremo)
D("D_Fertilizer", "Growth", 1, "Team", "Fertilizante Supremo", "Alimentar o Supremo com moedas rende +25% por nível", 20, 200, 1.7, "SupremeFeed", "Mult", 0.25)
D("D_Irrigation", "Growth", 1, "Team", "Irrigação", "O Supremo cresce sozinho +15% mais rápido por nível", 15, 300, 1.9, "SupremePassive", "Pow", 1.15)
D("D_Roots", "Growth", 1, "Team", "Raiz Profunda", "Cada brainrot destruído faz o Supremo crescer mais um pouco", 10, 400, 2, "SupremeKill", "Add", 0.00002)

-- Prateleira 2
D("D_Magnet", "Brainrot", 2, "Team", "Ímã de Moedas", "Puxa as moedas próximas até você: +4 studs de raio por nível", 10, 3e3, 1.8, "MagnetRadius", "Add", 4)
D("D_AutoCollect", "Brainrot", 2, "Team", "Coleta Automática", "Toda moeda vai sozinha para o jogador mais perto", 1, 5e5, 1, "AutoCollect", "Add", 1)
D("D_Attract", "Brainrot", 2, "Team", "Atrair Brainrots Valiosos", "Brainrots de tier Alto e Gigantes andam devagar até o jogador mais perto", 1, 1e5, 1, "AttractValuable", "Add", 1)
D("D_AutoRespawn", "Brainrot", 2, "Team", "Respawn Automático", "O quadro planta uma nova leva sozinho quando o campo fica quase vazio", 1, 5e4, 1, "AutoRespawn", "Add", 1)
D("D_Enchant", "Brainrot", 2, "Team", "Chance de Encantamento", "+2% de chance de nascer brainrot encantado por nível", 10, 2e4, 1.9, "EnchantChance", "Add", 0.02)
D("D_CritMult", "Weapon", 2, "Player", "Multiplicador de Crítico", "+0,25× de dano nos acertos críticos por nível", 10, 5e3, 1.9, "CritMult", "Add", 0.25)
D("D_Ingredients", "Brainrot", 2, "Team", "Sorte de Ingredientes", "+20% de chance de brainrots soltarem ingredientes por nível", 10, 3e3, 1.9, "IngredientLuck", "Mult", 0.2)

-- Prateleira 3
D("D_CoinMult", "Brainrot", 3, "Team", "Multiplicador de Moedas", "+10% de moedas de todos os brainrots por nível", 10, 4e5, 1.45, "CoinMult", "Mult", 0.1)
D("D_EnchantPower", "Brainrot", 3, "Team", "Poder de Encantamento", "Bônus de moedas dos encantamentos +15% mais forte por nível", 10, 4e5, 1.45, "EnchantPower", "Mult", 0.15)
D("D_Damage2", "Weapon", 3, "Player", "Dano+", "+20% de dano por nível, somando com o Dano", 15, 1e4, 1.6, "Damage", "Pow", 1.2)
D("D_Spawn2", "Brainrot", 3, "Team", "Mais Brainrots+", "+1 brainrot em cada leva (níveis extras)", 10, 2e5, 1.45, "SpawnCount", "Add", 1)

-------------------------------------------------------------------------------
-- Barracas: nome visível e cor de cada uma (usadas no mapa e na interface).
-------------------------------------------------------------------------------
local Stalls = {
	Weapon = { Name = "Barraca de Arma", Color = Color3.fromRGB(220, 75, 70) }, -- vermelho
	Brainrot = { Name = "Barraca de Brainrots", Color = Color3.fromRGB(190, 95, 225) }, -- roxo brainrot
	Quest = { Name = "Barraca de Missões", Color = Color3.fromRGB(245, 185, 55) }, -- amarelo
	Turret = { Name = "Barraca de Torretas", Color = Color3.fromRGB(70, 150, 230) }, -- azul
	Growth = { Name = "Barraca de Crescimento", Color = Color3.fromRGB(85, 190, 95) }, -- verde
}

-------------------------------------------------------------------------------
-- Índices montados por código:
--   ById[id]     -> a tabela do upgrade
--   ByMap[mapId] -> lista dos upgrades daquele mapa, na mesma ordem de List
-------------------------------------------------------------------------------
local ById = {}
local ByMap = {}

for _, def in ipairs(List) do
	-- Avisa no Output se alguém repetir um Id por engano (o segundo seria ignorado no ById).
	if ById[def.Id] then
		warn("[Config.Upgrades] Id de upgrade repetido: " .. def.Id)
	else
		ById[def.Id] = def
	end

	-- Avisa se um upgrade aponta para uma barraca que não existe.
	if not Stalls[def.Stall] then
		warn("[Config.Upgrades] Barraca desconhecida '" .. tostring(def.Stall) .. "' no upgrade " .. def.Id)
	end

	-- Cria a lista do mapa na primeira vez e adiciona o upgrade nela.
	if not ByMap[def.Map] then
		ByMap[def.Map] = {}
	end
	table.insert(ByMap[def.Map], def)
end

return {
	List = List,
	ById = ById,
	ByMap = ByMap,
	Stalls = Stalls,
}
