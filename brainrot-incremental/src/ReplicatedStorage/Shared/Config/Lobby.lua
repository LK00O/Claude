-- Config/Lobby: regras do lobby (grupos, teleporte, reconexão e placar de líderes).

local Lobby = {
	-- Limites do "máximo de jogadores" que o dono do grupo pode escolher.
	MinMaxPlayers = 1,
	MaxPlayersLimit = 8,
	DefaultMaxPlayers = 4,

	-- Contagem regressiva antes do teleporte (segundos).
	CountdownSeconds = 5,

	-- Quantas vezes tentar o teleporte antes de desistir.
	TeleportRetries = 3,

	-- Por quanto tempo o botão "Reconectar" fica disponível depois de sair de uma partida (2 horas).
	ReconnectWindowSeconds = 7200,

	-- MemoryStore onde o lobby deixa os dados do grupo para o servidor da partida ler.
	HandoffMapName = "BrainrotMatchHandoff",
	-- Validade dos dados do grupo na MemoryStore: 3 horas (10800 segundos). O salvamento
	-- automático da partida renova esse prazo enquanto houver jogadores nela, então uma
	-- partida longa não perde os dados. Um prazo curto evita lotar a cota da MemoryStore.
	HandoffExpiration = 10800,

	-- Placar de líderes (OrderedDataStore com as moedas totais).
	LeaderboardStoreName = "BrainrotIncremental_TopCoins_v1",
	LeaderboardRefresh = 60, -- atualiza a cada 60 s
	LeaderboardSize = 10, -- mostra os 10 primeiros

	-- Nome visível de cada tipo de privacidade do grupo.
	Privacy = {
		Public = "Público",
		Friends = "Só amigos",
		Invite = "Só convidados",
	},

	-- Iluminação do lobby: pôr do sol de festival (céu laranja-rosado, luzes quentes).
	-- Aplicada pelo MapBuilder com Common.ApplyLighting (mesmo formato de Config.Maps[x].Lighting).
	-- O DepthOfField desfoca de leve o fundo bem distante, para o lobby parecer uma maquete.
	Lighting = {
		ClockTime = 17.6, -- quase 18h: sol baixo e dourado
		GeographicLatitude = 30,
		Brightness = 2.1,
		Ambient = Color3.fromRGB(84, 70, 80),
		OutdoorAmbient = Color3.fromRGB(160, 130, 124),
		ColorShift_Top = Color3.fromRGB(255, 196, 150), -- luz do sol alaranjada
		EnvironmentSpecularScale = 0.8,
		ShadowSoftness = 0.3,
		Atmosphere = {
			Density = 0.3,
			Offset = 0.22,
			Color = Color3.fromRGB(255, 204, 172), -- pêssego
			Decay = Color3.fromRGB(196, 112, 124), -- rosa do horizonte
			Glare = 0.45,
			Haze = 1.6,
		},
		Sky = { SunAngularSize = 21 },
		Clouds = { Cover = 0.5, Density = 0.5, Color = Color3.fromRGB(255, 226, 212) },
		PostFX = {
			Bloom = { Intensity = 0.42, Size = 26, Threshold = 1.25 },
			ColorCorrection = {
				Contrast = 0.06,
				Saturation = 0.12,
				TintColor = Color3.fromRGB(255, 240, 228),
			},
			SunRays = { Intensity = 0.07, Spread = 0.7 },
			DepthOfField = {
				FarIntensity = 0.12,
				FocusDistance = 55,
				InFocusRadius = 80,
				NearIntensity = 0,
			},
		},
		Wind = Vector3.new(4, 0, 2), -- brisa bem leve (bandeirinhas e grama)
		Water = {
			Color = Color3.fromRGB(70, 150, 160),
			Transparency = 0.5,
			WaveSize = 0.05,
			WaveSpeed = 5,
		},
	},
}

return Lobby
