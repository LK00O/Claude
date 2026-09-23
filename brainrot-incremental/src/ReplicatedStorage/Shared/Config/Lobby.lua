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
	HandoffExpiration = 86400, -- 1 dia (segundos)

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
}

return Lobby
