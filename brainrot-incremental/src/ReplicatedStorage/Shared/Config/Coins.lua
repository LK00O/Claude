-- Config/Coins: as moedas físicas que caem no chão.
-- Cada "tier" de moeda vale uma quantia; o servidor divide o valor de uma morte
-- na menor quantidade de peças possível (usando o tier mais alto que caiba).

-- Atalho para criar cores a partir de R, G, B (0 a 255).
local rgb = Color3.fromRGB

local Coins = {
	-- Tiers em ordem crescente de valor.
	-- Name = nome em português, Value = quanto vale, Color = cor, Size = tamanho (studs).
	Tiers = {
		{ Name = "Bronze", Value = 1, Color = rgb(205, 127, 50), Size = 0.8 },
		{ Name = "Prata", Value = 10, Color = rgb(200, 205, 215), Size = 0.95 },
		{ Name = "Ouro", Value = 100, Color = rgb(255, 205, 40), Size = 1.1 },
		{ Name = "Esmeralda", Value = 1e3, Color = rgb(40, 200, 110), Size = 1.3 },
		{ Name = "Diamante", Value = 1e4, Color = rgb(120, 220, 255), Size = 1.5 },
		{ Name = "Rubi", Value = 1e5, Color = rgb(225, 30, 70), Size = 1.8 },
		{ Name = "Brainrot Dourado", Value = 1e6, Color = rgb(255, 170, 0), Size = 2.2 },
	},

	MaxPiecesPerDeath = 8, -- no máximo 8 moedas por brainrot destruído
	MaxCoinsOnGround = 250, -- acima disso, moedas velhas se fundem com as vizinhas
	DespawnTime = 120, -- segundos até uma moeda sumir (sem coleta automática)
	PickupRadius = 4, -- distância (studs) para pegar uma moeda andando por cima
	SettleTime = 1.2, -- segundos até a moeda parar e ficar ancorada
	CrateScatter = 7, -- espalhamento (studs) em volta do caixote
	AutoCollectDelay = 0.6, -- espera antes da coleta automática puxar a moeda
	MagnetPullSpeed = 60, -- velocidade (studs/s) das moedas puxadas pelo ímã

	-- "Crate": moedas caem perto do caixote (como no jogo original).
	-- "OnDeath": moedas caem onde o brainrot morreu.
	DropMode = "Crate",
}

return Coins
