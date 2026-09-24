-- Config/Stats: todos os "stats" (atributos numéricos) que a partida usa.
-- Formulas.ComputeStats começa com uma cópia de Defaults, aplica a arma do mapa,
-- os StatOverrides do mapa, os upgrades, as receitas e, por fim, os Clamps.

local Stats = {
	-- Valor inicial de cada stat.
	Defaults = {
		-- Arma (a arma de cada mapa sobrescreve com Weapons[x].Stats)
		Damage = 5, -- dano por projétil
		FireRate = 3, -- tiros por segundo
		Projectiles = 1, -- projéteis por tiro (em leque)
		Pierce = 0, -- quantos brainrots extras a bala atravessa
		CritChance = 0.02, -- chance de crítico (0 a 1)
		CritMult = 2, -- multiplicador de dano do crítico
		Caliber = 1, -- tamanho da "hitbox" da bala (multiplica BulletHitRadius)
		Spread = 6, -- graus entre projéteis do leque
		Range = 350, -- alcance do tiro (studs)
		SplashRadius = 0, -- raio do dano em área (0 = sem área)
		SlowPower = 0, -- quanto o tiro desacelera (0,2 = 20% mais lento)
		HeatPerShot = 0, -- calor gerado por tiro
		HeatCapacity = 0, -- calor máximo antes de superaquecer (0 = arma não esquenta)
		HeatCooling = 0, -- calor que esfria por segundo

		-- Campo / time
		SpawnCount = 5, -- brainrots por leva
		ExplodeChance = 0, -- chance de explodir ao morrer
		GiantChance = 0, -- chance de nascer gigante (3× maior)
		GrowthMult = 1, -- multiplicador do tamanho alvo
		MagnetRadius = 0, -- raio do ímã de moedas (studs)
		AutoCollect = 0, -- >= 1 liga a coleta automática
		AttractValuable = 0, -- >= 1 faz brainrots valiosos andarem até os jogadores
		AutoRespawn = 0, -- >= 1 liga o respawn automático do quadro
		TierLuck = 0, -- peso extra para tiers Médio e Alto
		EnchantChance = 0, -- chance de nascer encantado
		EnchantPower = 1, -- força do bônus de moedas dos encantamentos
		CoinMult = 1, -- multiplicador geral de moedas
		QuestReward = 1, -- multiplicador da recompensa das missões
		QuestCooldown = 60, -- espera entre missões (segundos)
		Visibility = 0, -- níveis de visibilidade na nevasca
		HeatImmunity = 0, -- >= 1 anula o calor do deserto
		IngredientLuck = 1, -- multiplicador da chance de ingredientes

		-- Torretas
		TurretCount = 0, -- máximo de torretas do time
		TurretDamage = 0, -- dano por tiro de torreta
		TurretFireRate = 1, -- tiros por segundo de cada torreta
		TurretRange = 45, -- alcance das torretas (studs)
		TurretAccuracy = 0.6, -- chance de acertar (0 a 1)
		TurretSlow = 0, -- quanto o tiro da torreta desacelera
		TurretCoinMult = 1, -- multiplicador das moedas de abates de torreta

		-- Supremo
		SupremeFeed = 1, -- eficiência de alimentar o Supremo com moedas
		-- Progresso ganho sozinho por segundo (fração de 0 a 1). 0,00005/s = 100% em ~5,5 h
		-- sem fazer nada: o Supremo cresce mais por abates, alimentação e Irrigação.
		SupremePassive = 0.00005,
		SupremeKill = 0, -- progresso ganho por brainrot destruído
	},

	-- Limites {mínimo, máximo} aplicados no fim do cálculo.
	Clamps = {
		CritChance = { 0, 1 },
		ExplodeChance = { 0, 0.9 },
		GiantChance = { 0, 0.9 },
		EnchantChance = { 0, 0.95 },
		TurretAccuracy = { 0, 0.99 },
		SlowPower = { 0, 0.8 },
		TurretSlow = { 0, 0.8 },
		Projectiles = { 1, 20 },
		QuestCooldown = { 5, 600 },
		SpawnCount = { 1, 60 },
	},

	-- Como mostrar cada stat para o jogador (nome em português e formato do número).
	-- Formatos: "number" (1,23K), "percent" (15,3%), "multiplier" (×1,5), "rate" (3/s),
	-- "studs" (12 studs), "seconds" (60 s), "bool" (Sim/Não), "integer" (5).
	Display = {
		-- Arma
		Damage = { Name = "Dano", Format = "number" },
		FireRate = { Name = "Cadência", Format = "rate" },
		Projectiles = { Name = "Projéteis", Format = "integer" },
		Pierce = { Name = "Perfuração", Format = "integer" },
		CritChance = { Name = "Chance de Crítico", Format = "percent" },
		CritMult = { Name = "Multiplicador de Crítico", Format = "multiplier" },
		Caliber = { Name = "Calibre", Format = "multiplier" },
		Spread = { Name = "Abertura do Leque", Format = "number" },
		Range = { Name = "Alcance", Format = "studs" },
		SplashRadius = { Name = "Raio da Explosão", Format = "studs" },
		SlowPower = { Name = "Congelamento", Format = "percent" },
		HeatPerShot = { Name = "Calor por Tiro", Format = "number" },
		HeatCapacity = { Name = "Tanque de Calor", Format = "number" },
		HeatCooling = { Name = "Resfriamento", Format = "rate" },

		-- Campo / time
		SpawnCount = { Name = "Brainrots por Leva", Format = "integer" },
		ExplodeChance = { Name = "Chance de Explosão", Format = "percent" },
		GiantChance = { Name = "Chance de Gigante", Format = "percent" },
		GrowthMult = { Name = "Tamanho dos Brainrots", Format = "multiplier" },
		MagnetRadius = { Name = "Raio do Ímã", Format = "studs" },
		AutoCollect = { Name = "Coleta Automática", Format = "bool" },
		AttractValuable = { Name = "Atrair Brainrots Valiosos", Format = "bool" },
		AutoRespawn = { Name = "Respawn Automático", Format = "bool" },
		TierLuck = { Name = "Sorte de Tier", Format = "percent" },
		EnchantChance = { Name = "Chance de Encantamento", Format = "percent" },
		EnchantPower = { Name = "Poder de Encantamento", Format = "multiplier" },
		CoinMult = { Name = "Multiplicador de Moedas", Format = "multiplier" },
		QuestReward = { Name = "Recompensa de Missão", Format = "multiplier" },
		QuestCooldown = { Name = "Espera de Missão", Format = "seconds" },
		Visibility = { Name = "Visibilidade na Nevasca", Format = "integer" },
		HeatImmunity = { Name = "Imunidade ao Calor", Format = "bool" },
		IngredientLuck = { Name = "Sorte de Ingredientes", Format = "multiplier" },

		-- Torretas
		TurretCount = { Name = "Máximo de Torretas", Format = "integer" },
		TurretDamage = { Name = "Dano das Torretas", Format = "number" },
		TurretFireRate = { Name = "Cadência das Torretas", Format = "rate" },
		TurretRange = { Name = "Alcance das Torretas", Format = "studs" },
		TurretAccuracy = { Name = "Mira das Torretas", Format = "percent" },
		TurretSlow = { Name = "Congelamento das Torretas", Format = "percent" },
		TurretCoinMult = { Name = "Moedas de Torreta", Format = "multiplier" },

		-- Supremo
		SupremeFeed = { Name = "Rendimento da Alimentação", Format = "multiplier" },
		SupremePassive = { Name = "Crescimento Passivo do Supremo", Format = "percent" },
		SupremeKill = { Name = "Crescimento por Abate", Format = "percent" },
	},
}

return Stats
