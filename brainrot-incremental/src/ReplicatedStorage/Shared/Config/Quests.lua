-- Config/Quests: os modelos de missão da Barraca de Missões.
-- Ao pegar uma missão, o servidor sorteia um modelo (respeitando "Requires")
-- e calcula o alvo e a recompensa.
--
-- Campos de cada modelo:
--   Id        nome interno
--   Type      o que conta progresso: "Kill", "KillTier", "Collect", "Chain",
--             "KillGiant", "Crit" ou "KillEnchanted"
--   Tier      (só KillTier) qual tier conta
--   Text      texto mostrado ao jogador; o %s vira o alvo (ex.: "Destrua 45 brainrots")
--   Base      alvo base (cresce com a soma dos níveis de upgrade)
--   BaseSeconds (só Collect) alvo = renda por segundo × esses segundos
--   Requires  só aparece se o stat do time for >= Min (ex.: precisa ter chance de explosão)
--
-- Fórmulas (feitas no QuestService / Formulas):
--   Alvo       = ceil(Base * (1 + somaDeNíveis * ScalePerUpgradeLevel))
--   Alvo Collect = max(RewardFloor * CostScale, Renda * BaseSeconds)
--   Recompensa = max(RewardFloor * CostScale, Renda * RewardSeconds) * stats.QuestReward

local Quests = {
	Templates = {
		{ Id = "Kill", Type = "Kill", Text = "Destrua %s brainrots", Base = 40 },
		{ Id = "KillHigh", Type = "KillTier", Tier = "High", Text = "Destrua %s brainrots de tier Alto", Base = 5 },
		{ Id = "Collect", Type = "Collect", Text = "Colete %s moedas", BaseSeconds = 60 },
		{
			Id = "Chain",
			Type = "Chain",
			Text = "Cause %s explosões de brainrot",
			Base = 3,
			Requires = { Stat = "ExplodeChance", Min = 0.01 },
		},
		{
			Id = "Giant",
			Type = "KillGiant",
			Text = "Destrua %s brainrot(s) gigante(s)",
			Base = 1,
			Requires = { Stat = "GiantChance", Min = 0.01 },
		},
		{ Id = "Crit", Type = "Crit", Text = "Acerte %s críticos", Base = 20 },
		{
			Id = "Enchanted",
			Type = "KillEnchanted",
			Text = "Destrua %s brainrots encantados",
			Base = 3,
			Requires = { Stat = "EnchantChance", Min = 0.01 },
		},
	},

	-- A recompensa vale ~45 segundos da sua renda média (×2 com a Recompensa de Missão no máximo).
	-- Com mais que isso, as missões rendiam mais moedas do que atirar nos brainrots.
	RewardSeconds = 45,
	RewardFloor = 50, -- recompensa mínima (em unidades do Ato 1)
	ScalePerUpgradeLevel = 1 / 40, -- cada nível de upgrade aumenta o alvo em 2,5%
}

return Quests
