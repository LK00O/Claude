-- Config/Weapons: a arma de cada mapa (cada ato troca a arma).
-- Stats: valores base da arma. Formulas.ComputeStats copia Config/Stats.Defaults
-- e depois sobrescreve com estes valores; stat que não aparecer aqui fica com o padrão.
-- GunColor: cor do modelo da arma. TracerColor: cor do rastro da bala.
-- BulletVisualSpeed: velocidade (studs/s) da bala desenhada no cliente (só visual).
-- SoundId: id do som do tiro desta arma (0 = sem som próprio).

local Weapons = {
	-- Ato 1: tiro único, cadência média.
	SpaghettiPistol = {
		Id = "SpaghettiPistol",
		DisplayName = "Pistola de Espaguete",
		Map = "Meadow",
		Stats = {
			Damage = 5,
			FireRate = 3,
			Projectiles = 1,
			Pierce = 0,
			CritChance = 0.02,
			CritMult = 2,
			Caliber = 1,
			Spread = 6,
			Range = 350,
			SplashRadius = 0,
			SlowPower = 0,
			HeatPerShot = 0,
			HeatCapacity = 0,
			HeatCooling = 0,
		},
		GunColor = Color3.fromRGB(240, 205, 110), -- amarelo de macarrão
		TracerColor = Color3.fromRGB(225, 60, 40), -- vermelho de molho de tomate
		BulletVisualSpeed = 700,
		SoundId = 0,
	},

	-- Ato 2: tiro lento e forte, com dano em área e lentidão.
	GelatoCannon = {
		Id = "GelatoCannon",
		DisplayName = "Canhão de Gelato",
		Map = "Winter",
		Stats = {
			-- 300 × 1,5 tiros/s = 450 de dano por segundo, 30× a pistola do Ato 1 (15/s),
			-- igual ao HealthScale 30 do Inverno: no começo, matar leva o mesmo tempo que no Prado.
			Damage = 300,
			FireRate = 1.5,
			Projectiles = 1,
			Pierce = 0,
			CritChance = 0.02,
			CritMult = 2,
			Caliber = 1.5,
			Spread = 4,
			Range = 350,
			SplashRadius = 6,
			SlowPower = 0.2,
			HeatPerShot = 0,
			HeatCapacity = 0,
			HeatCooling = 0,
		},
		GunColor = Color3.fromRGB(170, 225, 255), -- azul gelo
		TracerColor = Color3.fromRGB(255, 170, 215), -- rosa de gelato de morango
		BulletVisualSpeed = 380, -- bola de gelato mais lenta
		SoundId = 0,
	},

	-- Ato 3: cadência altíssima, mas esquenta (barra de calor).
	TralaleroMinigun = {
		Id = "TralaleroMinigun",
		DisplayName = "Metralhadora de Tralalero",
		Map = "Desert",
		Stats = {
			Damage = 450,
			FireRate = 10,
			Projectiles = 1,
			Pierce = 1,
			CritChance = 0.03,
			CritMult = 2,
			Caliber = 1,
			Spread = 8,
			Range = 300,
			SplashRadius = 0,
			SlowPower = 0,
			-- Calor: 10 tiros/s × 1 = +10 de calor por segundo, mas só esfria 6/s,
			-- então atirando sem parar a barra enche em ~10 s e superaquece.
			-- (Se o resfriamento fosse 10/s, igual ao calor gerado, ela nunca encheria.)
			HeatPerShot = 1,
			HeatCapacity = 40,
			HeatCooling = 6,
		},
		GunColor = Color3.fromRGB(70, 130, 200), -- azul de tubarão
		TracerColor = Color3.fromRGB(255, 215, 110), -- amarelo quente
		BulletVisualSpeed = 900,
		SoundId = 0,
	},
}

return Weapons
