-- Config/Maps: os três mapas (atos) da partida.
-- Custos, valores e vidas em outros arquivos são escritos em "unidades do Ato 1"
-- e multiplicados aqui por CostScale, ValueScale e HealthScale do mapa.
-- O Lobby não está aqui: ele tem iluminação própria no builder dele.

local Maps = {
	-- Ordem dos mapas (usada no lobby para listar e no portal para achar o próximo).
	Order = { "Meadow", "Winter", "Desert" },

	---------------------------------------------------------------------------
	-- ATO 1: Prado
	---------------------------------------------------------------------------
	Meadow = {
		Id = "Meadow",
		Act = 1,
		DisplayName = "Prado Brainrot",
		Description = "Ato 1. Um prado ensolarado onde os brainrots brotam da grama. Atire, junte moedas perto do caixote e maxe todas as barracas para abrir o portal!",
		Image = "", -- id da imagem (rbxassetid://...) mostrada no lobby; o dono preenche

		Weapon = "SpaghettiPistol", -- id em Config/Weapons
		Next = "Winter", -- mapa liberado ao concluir este

		-- Multiplicadores de custo, moedas e vida (Ato 1 = base).
		CostScale = 1,
		ValueScale = 1,
		HealthScale = 1,

		-- Prateleiras das barracas: começa na 1; custo para liberar a 2 e a 3 (unidades do Ato 1).
		-- (Valores pensados para a renda de quem acabou de maxar a prateleira anterior.)
		MaxShelf = 3,
		ShelfCosts = { [2] = 4e4, [3] = 1e6 },

		TokensReward = 10, -- Brainrot Tokens ganhos ao concluir o ato
		FrozenChance = 0, -- chance de um brainrot nascer congelado

		-- Barracas que existem neste mapa (ids de Upgrades.Stalls).
		Stalls = { "Weapon", "Brainrot", "Quest" },

		HasTurrets = false,
		HasRecipes = false,
		HasSupreme = false,

		-- Stats que este mapa troca antes dos upgrades (nenhum aqui).
		StatOverrides = {},

		-- Iluminação aplicada pelo MapBuilder: tarde ensolarada, sol alto e visível.
		Lighting = {
			ClockTime = 14,
			Brightness = 2.2,
			Ambient = Color3.fromRGB(120, 125, 135),
			OutdoorAmbient = Color3.fromRGB(150, 160, 150),
			Atmosphere = {
				Density = 0.25,
				Offset = 0.1,
				Color = Color3.fromRGB(199, 222, 255), -- azul claro do céu
				Decay = Color3.fromRGB(120, 160, 205), -- horizonte azulado
				Glare = 0,
				Haze = 1,
			},
		},
	},

	---------------------------------------------------------------------------
	-- ATO 2: Inverno
	---------------------------------------------------------------------------
	Winter = {
		Id = "Winter",
		Act = 2,
		DisplayName = "Tundra Congelini",
		Description = "Ato 2. Um vale congelado no meio da nevasca. Defenda a plataforma de madeira, posicione torretas e quebre o gelo dos brainrots congelados!",
		Image = "",

		Weapon = "GelatoCannon",
		Next = "Desert",

		-- Tudo 25× mais caro e mais valioso; brainrots 30× mais resistentes.
		CostScale = 25,
		ValueScale = 25,
		HealthScale = 30,

		MaxShelf = 3,
		ShelfCosts = { [2] = 4e4, [3] = 1e6 },

		TokensReward = 20,
		FrozenChance = 0.2, -- 20% dos brainrots nascem dentro de um bloco de gelo

		Stalls = { "Weapon", "Brainrot", "Quest", "Turret" },

		HasTurrets = true,
		HasRecipes = false,
		HasSupreme = false,

		-- Torretas começam com 20 de dano neste mapa.
		StatOverrides = { TurretDamage = 20 },

		-- Nevasca: densidade da Atmosphere = AtmosphereDensity * VisibilityFactor ^ stats.Visibility
		-- (cada nível do upgrade "Farol da Nevasca" deixa a neblina 25% mais fraca).
		AtmosphereDensity = 0.45,
		VisibilityFactor = 0.75,

		-- Céu branco-azulado de nevasca, luz fria e difusa.
		Lighting = {
			ClockTime = 12.5,
			Brightness = 1.6,
			Ambient = Color3.fromRGB(125, 135, 160),
			OutdoorAmbient = Color3.fromRGB(170, 185, 210),
			Atmosphere = {
				Density = 0.45, -- igual a AtmosphereDensity (visibilidade 0)
				Offset = 0.25,
				Color = Color3.fromRGB(215, 226, 242), -- branco gelado
				Decay = Color3.fromRGB(165, 182, 210), -- cinza-azulado da neblina
				Glare = 0,
				Haze = 2.5,
			},
		},
	},

	---------------------------------------------------------------------------
	-- ATO 3: Deserto
	---------------------------------------------------------------------------
	Desert = {
		Id = "Desert",
		Act = 3,
		DisplayName = "Deserto Sahur",
		Description = "Ato 3. Um deserto escaldante em volta de um oásis. Cozinhe receitas no caldeirão e faça o Tralalero Supremo crescer até tampar o sol!",
		Image = "",

		Weapon = "TralaleroMinigun",
		Next = nil, -- último ato: ao concluir, o jogo termina e todos voltam ao lobby

		-- 625× o Ato 1 (25 × 25) em custo e moedas; 900× em vida.
		CostScale = 625,
		ValueScale = 625,
		HealthScale = 900,

		MaxShelf = 3,
		ShelfCosts = { [2] = 4e4, [3] = 1e6 },

		TokensReward = 50,
		FrozenChance = 0,

		Stalls = { "Weapon", "Brainrot", "Quest", "Turret", "Growth" },

		HasTurrets = true,
		HasRecipes = true,
		HasSupreme = true,

		-- Torretas começam com 600 de dano neste mapa.
		StatOverrides = { TurretDamage = 600 },

		-- Brainrot Supremo que nasce na Grande Cova.
		Supreme = {
			BrainrotId = "TralaleroSupremo", -- id em Config/Brainrots.Supreme
			-- Moedas (unidades do Ato 1) para encher tudo alimentando do zero.
			-- 1e6 × CostScale 625 = 6,25e8 moedas: alto, mas ao alcance da renda do deserto,
			-- então "Alimentar" faz diferença de verdade (antes, com 2e7, quase não fazia).
			BaseFullCost = 1e6,
			MinHeight = 8, -- altura inicial (studs)
			MaxHeight = 500, -- altura ao tampar o sol (studs)
		},

		-- Fim de tarde quente: sol mais baixo (para o Supremo conseguir tampá-lo)
		-- e ar alaranjado com um pouco de brilho.
		Lighting = {
			ClockTime = 16.5,
			Brightness = 3,
			Ambient = Color3.fromRGB(150, 118, 88),
			OutdoorAmbient = Color3.fromRGB(200, 160, 115),
			Atmosphere = {
				Density = 0.3,
				Offset = 0.2,
				Color = Color3.fromRGB(255, 214, 160), -- areia dourada
				Decay = Color3.fromRGB(235, 150, 90), -- laranja do horizonte
				Glare = 0.4,
				Haze = 1.8,
			},
		},
	},
}

return Maps
