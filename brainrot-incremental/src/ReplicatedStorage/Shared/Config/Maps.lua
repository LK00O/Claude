-- Config/Maps: os três mapas (atos) da partida.
-- Custos, valores e vidas em outros arquivos são escritos em "unidades do Ato 1"
-- e multiplicados aqui por CostScale, ValueScale e HealthScale do mapa.
-- O Lobby não está aqui: a iluminação dele fica em Config.Lobby.Lighting.
--
-- Lighting (de cada mapa) é aplicada pelo MapBuilder com Common.ApplyLighting, sempre a
-- partir de uma BASE limpa (nada do mapa anterior sobra). Chaves aceitas:
--   ClockTime, GeographicLatitude, Brightness, Ambient, OutdoorAmbient, ColorShift_Top,
--   EnvironmentSpecularScale, ShadowSoftness (e outras do Lighting),
--   Atmosphere = { Density, Offset, Color, Decay, Glare, Haze },
--   Sky = { SunAngularSize },                  (tamanho do sol no céu)
--   Clouds = { Cover, Density, Color },        (nuvens dinâmicas do Terrain)
--   PostFX = { Bloom, ColorCorrection, SunRays, DepthOfField },
--   Wind = Vector3,                            (vento global: grama, nuvens, partículas)
--   Water = { Color, Transparency, WaveSize, WaveSpeed, Reflectance }.  (água do terreno)

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

		-- Iluminação aplicada pelo MapBuilder: tarde ensolarada de verão, sol alto e quente,
		-- céu azul com nuvens fofas e um brilho suave nas partes claras.
		Lighting = {
			ClockTime = 14.6,
			GeographicLatitude = 35,
			Brightness = 2.4,
			Ambient = Color3.fromRGB(70, 72, 80), -- sombra (luz que não vem do sol)
			OutdoorAmbient = Color3.fromRGB(132, 138, 130),
			ColorShift_Top = Color3.fromRGB(255, 238, 210), -- sol levemente dourado
			EnvironmentSpecularScale = 0.7,
			ShadowSoftness = 0.2,
			Atmosphere = {
				Density = 0.27,
				Offset = 0.2,
				Color = Color3.fromRGB(199, 220, 242), -- azul claro do céu
				Decay = Color3.fromRGB(110, 145, 185), -- horizonte azulado
				Glare = 0.12,
				Haze = 1.1,
			},
			Sky = { SunAngularSize = 14 },
			Clouds = { Cover = 0.55, Density = 0.5, Color = Color3.fromRGB(255, 255, 255) },
			PostFX = {
				Bloom = { Intensity = 0.3, Size = 24, Threshold = 1.3 },
				ColorCorrection = {
					Brightness = 0.01,
					Contrast = 0.08,
					Saturation = 0.12, -- cores um pouco mais vivas
					TintColor = Color3.fromRGB(255, 251, 242),
				},
				SunRays = { Intensity = 0.06, Spread = 0.55 },
			},
			Wind = Vector3.new(6, 0, 3), -- brisa leve
			Water = {
				Color = Color3.fromRGB(58, 128, 140),
				Transparency = 0.55,
				WaveSize = 0.08,
				WaveSpeed = 6,
				Reflectance = 0.6,
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

		-- Céu branco-azulado de nevasca, luz fria e difusa (sombras bem macias).
		Lighting = {
			ClockTime = 12.5,
			GeographicLatitude = 64, -- bem ao norte: sol mais baixo
			Brightness = 1.7,
			Ambient = Color3.fromRGB(86, 96, 116),
			OutdoorAmbient = Color3.fromRGB(150, 164, 190),
			ColorShift_Top = Color3.fromRGB(214, 228, 255), -- luz fria
			EnvironmentSpecularScale = 1, -- gelo brilha
			ShadowSoftness = 0.55,
			Atmosphere = {
				Density = 0.45, -- igual a AtmosphereDensity (visibilidade 0)
				Offset = 0.3,
				Color = Color3.fromRGB(214, 226, 242), -- branco gelado
				Decay = Color3.fromRGB(148, 168, 200), -- cinza-azulado da neblina
				Glare = 0,
				Haze = 2.4,
			},
			Sky = { SunAngularSize = 9 },
			Clouds = { Cover = 0.86, Density = 0.42, Color = Color3.fromRGB(222, 230, 242) },
			PostFX = {
				Bloom = { Intensity = 0.22, Size = 28, Threshold = 1.7 },
				ColorCorrection = {
					Contrast = 0.06,
					Saturation = -0.12, -- cores mais apagadas (frio)
					TintColor = Color3.fromRGB(232, 242, 255),
				},
				SunRays = { Intensity = 0.02, Spread = 0.4 },
			},
			Wind = Vector3.new(16, 0, 7), -- vento forte da nevasca
			Water = {
				Color = Color3.fromRGB(120, 170, 200),
				Transparency = 0.4,
				WaveSize = 0.02,
				WaveSpeed = 4,
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
		-- (O SupremeService lê Brightness e OutdoorAmbient daqui para escurecer o dia.)
		Lighting = {
			ClockTime = 16.5,
			GeographicLatitude = 41.733,
			Brightness = 2.8,
			Ambient = Color3.fromRGB(96, 78, 62),
			OutdoorAmbient = Color3.fromRGB(172, 136, 100),
			ColorShift_Top = Color3.fromRGB(255, 208, 150), -- sol alaranjado
			EnvironmentSpecularScale = 0.5,
			ShadowSoftness = 0.12, -- sombras bem marcadas
			Atmosphere = {
				Density = 0.3,
				Offset = 0.24,
				Color = Color3.fromRGB(255, 214, 162), -- areia dourada
				Decay = Color3.fromRGB(226, 142, 86), -- laranja do horizonte
				Glare = 0.55,
				Haze = 2.1,
			},
			Sky = { SunAngularSize = 28 }, -- sol grande no fim de tarde
			Clouds = { Cover = 0.22, Density = 0.28, Color = Color3.fromRGB(255, 236, 214) },
			PostFX = {
				Bloom = { Intensity = 0.38, Size = 30, Threshold = 1.35 },
				ColorCorrection = {
					Contrast = 0.1,
					Saturation = 0.08,
					TintColor = Color3.fromRGB(255, 244, 226),
				},
				SunRays = { Intensity = 0.11, Spread = 0.8 },
			},
			Wind = Vector3.new(11, 0, -4), -- vento que arrasta areia
			Water = {
				Color = Color3.fromRGB(40, 150, 160), -- água de oásis
				Transparency = 0.7,
				WaveSize = 0.05,
				WaveSpeed = 5,
			},
		},
	},
}

return Maps
