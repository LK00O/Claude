-- Config/Game: configurações gerais do jogo (vale para o lobby e para a partida).
-- Todos os números de balanceamento "globais" ficam aqui. Os serviços leem
-- estes valores com require(Shared.Config.Game) e nunca escrevem neles.

local Game = {
	-- Nome mostrado em placas e telas.
	GameName = "Brainrot Incremental But With Guns",

	-- IDs dos dois places da experiência. O dono preenche depois de publicar
	-- (Asset Manager > Places). Com 0, o jogo decide o papel pelo Studio (ver PlaceRole).
	LobbyPlaceId = 0,
	MatchPlaceId = 0,

	-- Ao testar no Studio: qual papel o servidor assume ("Lobby" ou "Match")
	-- e qual mapa é carregado quando o papel é "Match".
	StudioRole = "Match",
	StudioMapId = "Meadow",

	-- true = libera os comandos de teste também fora do Studio (cuidado!).
	DebugMode = false,

	-- Nomes dos DataStores (trocar o "_v1" apaga o progresso de todo mundo).
	DataStoreName = "BrainrotIncremental_Player_v1",
	RunStoreName = "BrainrotIncremental_Runs_v1",

	-- Salvamento automático (segundos) e tempo para considerar uma trava de sessão abandonada.
	AutosaveInterval = 60,
	SessionLockTimeout = 90,

	-- true = todas as moedas vão para um cofre único do time.
	SharedWallet = false,

	-- Moedas dos abates feitos por torretas:
	-- "Owner" = vão para quem posicionou a torreta; "Team" = divididas igualmente
	-- entre os jogadores da partida que estão no servidor.
	TurretCoinSplit = "Owner",

	-- Regra dos upgrades de arma (escopo "Player") para concluir o ato:
	-- "AnyPlayer" = basta um jogador ter maxado; "AllPlayers" = todos os presentes.
	WeaponMaxRule = "AnyPlayer",

	-- Quem decide entrar no portal: "Host" (só o dono) ou "Majority" (votação).
	PortalDecision = "Majority",

	-- Vida extra dos brainrots por jogador a mais na partida (+35% cada).
	HealthScalePerExtraPlayer = 0.35,

	-- Limite de brainrots vivos ao mesmo tempo (desempenho).
	MaxBrainrotsAlive = 60,

	-- Recarga do quadro "Plantar brainrots" (segundos).
	BoardCooldown = 3,

	-- Respawn automático acontece quando os vivos ficam abaixo de 30% da leva.
	AutoRespawnThreshold = 0.3,

	-- Regras de onde os brainrots podem nascer:
	PlayerExclusionRadius = 12, -- distância mínima de qualquer jogador (studs)
	MinBrainrotSpacing = 6, -- distância mínima entre brainrots (studs)
	SpawnAttempts = 30, -- tentativas de achar um lugar válido

	-- Raio do spherecast das balas (multiplicado pelo Caliber da arma).
	BulletHitRadius = 1.2,

	-- Explosão de brainrot: dano = 40% da vida máxima dele, raio base de 6 studs.
	ExplosionDamageFraction = 0.4,
	ExplosionBaseRadius = 6,

	-- Encantamento de Fogo: queima os vizinhos com 10% da vida máx./s por 3 s num raio de 10 studs.
	IgniteDpsFraction = 0.1,
	IgniteDuration = 3,
	IgniteRadius = 10,

	-- Duração da lentidão causada por tiros (segundos).
	SlowDuration = 2,

	-- Brainrot lento fica frágil: dano × (1 + lentidão × este valor). 20% mais lento = +10% de dano.
	SlowDamageBonus = 0.5,

	-- Upgrade "Atrair Brainrots Valiosos": velocidade (studs/s) e distância onde param.
	AttractSpeed = 3,
	AttractStopDistance = 18,

	-- Brainrots congelados (Inverno): escudo de gelo = 50% da vida máxima.
	FrozenShieldFraction = 0.5,

	-- Velocidades do personagem (andar e correr).
	WalkSpeed = 16,
	SprintSpeed = 26,

	-- Calor do deserto: depois de 20 s longe da sombra, velocidade × 0,85.
	DesertHeat = { SafeTime = 20, SlowMultiplier = 0.85 },

	-- Game passes (desligados por padrão). Os números são os IDs dos passes (0 = não existe).
	-- Para vender: crie o pass no Creator Hub, cole o id aqui e mude Enabled para true
	-- (passo a passo no README). A lista com nome e descrição fica em Shared/Util/Gamepasses.
	-- O PREÇO não fica aqui: é o que você escolhe no Creator Hub, e as lojas leem de lá.
	--   DoubleCoins = Moedas em Dobro      AutoCollect = Coleta Automática
	--   ExtraTurret = Torreta Extra        VIP = VIP (+moedas, etiqueta e [VIP] no chat)
	--   DoubleDamage = Dano em Dobro (só a arma do dono; torretas não mudam)
	--
	-- REGRA: NUNCA venda moedas do jogo por Robux (nem pacote de moedas, nem produto que dê
	-- moedas). As moedas compram upgrades de sorte (Sorte de Tier, chance de encantamento), e
	-- aí esses upgrades virariam "itens aleatórios pagos" pelas regras do Roblox: precisaria
	-- mostrar as chances e, no Brasil, eles ficam bloqueados para menores de idade. Pelo mesmo
	-- motivo não existe pass de sorte: os passes só dão bônus fixos (sem sorteio).
	Gamepasses = { Enabled = false, DoubleCoins = 0, AutoCollect = 0, ExtraTurret = 0, VIP = 0, DoubleDamage = 0 },

	-- Raio do ímã para quem tem o game pass de coleta automática (studs).
	GamepassAutoCollectRadius = 30,

	-- Pass VIP: multiplica as moedas do dono (1.25 = +25%). Vale nas mesmas moedas que o
	-- Moedas em Dobro e junta com ele: quem tem os dois ganha ×2 × 1,25 = ×2,5.
	GamepassVipCoinMult = 1.25,

	-- IDs de música por mapa (0 = sem música).
	Music = { Lobby = 0, Meadow = 0, Winter = 0, Desert = 0, Ending = 0 },

	-- IDs dos efeitos sonoros (0 = sem som).
	Sounds = {
		Shoot = 0,
		Hit = 0,
		Crit = 0,
		Coin = 0,
		Death = 0,
		Explosion = 0,
		Purchase = 0,
		Error = 0,
		Notify = 0,
		Turret = 0,
		Portal = 0,
		Craft = 0,
	},
}

return Game
