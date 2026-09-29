-- Config/Admins: quem é administrador do jogo, os comandos de admin e os eventos globais.
--
-- Este arquivo é lido pelo servidor (AdminService, que confere TUDO) e pelo cliente
-- (painel de admin e lista de comandos). O cliente só usa estas tabelas para desenhar
-- a tela: quem decide se alguém é admin é sempre o servidor.
--
-- ============================================================================
-- COMO ADICIONAR UM ADMIN (passo a passo)
-- ============================================================================
--   1. Abra o perfil da pessoa no site do Roblox. O endereço tem este formato:
--          https://www.roblox.com/users/NUMERO/profile
--      O NÚMERO no meio do endereço é o UserId dela.
--      Exemplo: https://www.roblox.com/users/1179661787/profile -> UserId 1179661787
--   2. Coloque esse número na lista "UserIds" lá embaixo, separado por vírgula:
--          UserIds = { 1179661787, 123456789 },
--   3. Salve, publique de novo NOS DOIS PLACES (Lobby e Partida) e use "Restart Servers"
--      no Creator Hub. Os servidores que já estavam abertos continuam com a lista antiga.
--
-- COMO TIRAR UM ADMIN: apague o número dele da lista "UserIds" e publique de novo.
--
-- ATENÇÃO: NUNCA dê admin para quem você não conhece de verdade. Um admin pode
-- expulsar e banir jogadores, dar moedas, mandar avisos para todos os servidores e
-- ligar eventos. Admin só para você e amigos de muita confiança.
--
-- Use o UserId (número), nunca o nome: o nome de usuário pode ser trocado no Roblox,
-- o UserId nunca muda.
-- ============================================================================

local Admins = {
	-- O dono da experiência vira admin sozinho, com o cargo "Owner" (Dono):
	--   * experiência de uma pessoa: o UserId de quem criou (game.CreatorId);
	--   * experiência de um grupo (comunidade): o dono do grupo (cargo 255).
	OwnerIsAdmin = true,

	-- Sempre "Owner", mesmo se um dia o jogo for passado para um grupo (comunidade).
	OwnerUserIds = {
		335101108, -- Henrique (roblox.com/users/335101108/profile)
	},

	-- Admins com o cargo "Admin". Para adicionar alguém, veja o passo a passo lá em cima.
	UserIds = {
		1179661787, -- amigo do Henrique (roblox.com/users/1179661787/profile)
	},

	-- Só vale se o jogo pertencer a um grupo (comunidade): membros com cargo (rank) maior
	-- ou igual a este número viram admin. 0 = desligado (ninguém vira admin pelo grupo).
	GroupMinRank = 0,

	-- No Roblox Studio, todo jogador de teste é admin (para testar os comandos à vontade).
	-- Nos servidores de verdade isto não vale.
	StudioEveryoneAdmin = true,

	-- Começo dos comandos no chat: ":fly", ":coins all 1000", ":kick Fulano bagunça".
	-- (Os comandos de TESTE do DebugService continuam usando "/", só no Studio.)
	ChatPrefix = ":",

	-- Duração máxima de um evento global (minutos), usada no comando ":event".
	MaxMinutes = 120,

	-- Avisos (":announce"): tamanho máximo do texto e quantos segundos a faixa fica na tela.
	AnnounceMaxLength = 200,
	AnnounceDuration = 8,

	-- ":coinrain": moedas soltas em volta de CADA jogador quando o comando vem sem número.
	-- Em unidades do Ato 1 (multiplicado pelo CostScale do mapa, como os preços).
	CoinRainDefault = 1000,
	-- Em quantos montinhos as moedas de cada jogador são divididas.
	CoinRainPiles = 4,

	-- Lista de comandos: a ÚNICA fonte de verdade para o painel de admin, para a ajuda
	-- (":cmds") e para o servidor (que confere os argumentos por aqui).
	--   Name        = nome do comando (o que vem depois do ":")
	--   Args        = argumentos em ordem: {Name = nome mostrado, Type = tipo, Optional = true?}
	--                 Tipos: "player"   = nome (ou começo do nome), nome de exibição, UserId,
	--                                     "me" (eu), "all" (todos) ou "others" (os outros).
	--                                     No ":kick" e no ":ban" só vale o nome COMPLETO (ou o
	--                                     UserId), para um erro de digitação não pegar outra pessoa.
	--                        "number"   = número (aceita 1000, 2,5, 10k, 3m, 1b, 1t); Min/Max = limites
	--                        "text"     = o resto da frase
	--                        "duration" = "30m", "2h", "1d", "7d" ou "perm" (para sempre)
	--                        "event"    = um dos eventos da tabela Events (lá embaixo)
	--   Scope       = "Any" (lobby e partida) ou "Match" (só dentro de uma partida)
	--   Category    = grupo no painel
	--   Description = o que o comando faz (aparece no painel e no ":cmds")
	Commands = {
		-- Movimento (vale no lobby e na partida)
		{
			Name = "fly",
			Args = {},
			Scope = "Any",
			Category = "Movimento",
			Description = "Liga ou desliga o seu voo.",
		},
		{
			Name = "speed",
			Args = { { Name = "velocidade", Type = "number", Min = 1, Max = 200 } },
			Scope = "Any",
			Category = "Movimento",
			Description = "Muda a sua velocidade de andar (normal = 16).",
		},
		{
			Name = "jump",
			Args = { { Name = "força", Type = "number", Min = 0, Max = 300 } },
			Scope = "Any",
			Category = "Movimento",
			Description = "Muda a força do seu pulo (normal = 50).",
		},
		{
			Name = "tp",
			Args = { { Name = "jogador", Type = "player" } },
			Scope = "Any",
			Category = "Movimento",
			Description = "Teleporta você até um jogador.",
		},
		{
			Name = "bring",
			Args = { { Name = "jogador", Type = "player" } },
			Scope = "Any",
			Category = "Movimento",
			Description = "Traz um jogador (ou todos) até você.",
		},
		{
			Name = "respawn",
			Args = { { Name = "jogador", Type = "player", Optional = true } },
			Scope = "Any",
			Category = "Movimento",
			Description = "Faz o personagem renascer (sem jogador = você).",
		},

		-- Partida (só funcionam dentro de uma partida)
		{
			Name = "coins",
			Args = {
				{ Name = "jogador", Type = "player" },
				{ Name = "quantia", Type = "number", Min = 1, Max = 1e300 },
			},
			Scope = "Match",
			Category = "Partida",
			Description = "Dá moedas a um jogador (ou a todos).",
		},
		{
			Name = "wave",
			Args = {},
			Scope = "Match",
			Category = "Partida",
			Description = "Planta uma leva de brainrots.",
		},
		{
			Name = "giant",
			Args = {},
			Scope = "Match",
			Category = "Partida",
			Description = "Planta agora uma leva só de brainrots gigantes.",
		},
		{
			Name = "coinrain",
			-- Max menor que o do ":coins": as moedas da chuva são pegas do chão e contam para
			-- sempre nas moedas totais do placar (um "1e300" digitado sem querer estragaria o
			-- placar de todo mundo do servidor). 1B já é mais que o item mais caro do jogo.
			Args = { { Name = "quantia", Type = "number", Optional = true, Min = 1, Max = 1e9 } },
			Scope = "Match",
			Category = "Partida",
			Description = "Faz chover montes de moedas em volta de cada jogador.",
		},
		{
			Name = "maxall",
			Args = {},
			Scope = "Match",
			Category = "Partida",
			Description = "Maxa todos os upgrades e prateleiras do mapa.",
		},
		{
			Name = "nextact",
			Args = {},
			Scope = "Match",
			Category = "Partida",
			Description = "Conclui o ato atual.",
		},
		{
			Name = "supreme",
			Args = { { Name = "progresso", Type = "number", Min = 0, Max = 1 } },
			Scope = "Match",
			Category = "Partida",
			Description = "Define o progresso do Brainrot Supremo (0 a 1).",
		},
		{
			Name = "ingredients",
			Args = { { Name = "jogador", Type = "player", Optional = true } },
			Scope = "Match",
			Category = "Partida",
			Description = "Dá 5 de cada ingrediente (sem jogador = você).",
		},

		-- Perfil (salvo para sempre; vale no lobby e na partida)
		{
			Name = "tokens",
			Args = {
				{ Name = "jogador", Type = "player" },
				{ Name = "quantia", Type = "number", Min = -1e9, Max = 1e9, Integer = true },
			},
			Scope = "Any",
			Category = "Perfil",
			Description = "Dá (ou tira, com número negativo) Brainrot Tokens.",
		},
		{
			Name = "unlockall",
			Args = { { Name = "jogador", Type = "player" } },
			Scope = "Any",
			Category = "Perfil",
			Description = "Libera todos os mapas no perfil do jogador.",
		},

		-- Eventos e avisos (valem em todos os servidores do jogo)
		{
			Name = "announce",
			Args = { { Name = "texto", Type = "text" } },
			Scope = "Any",
			Category = "Eventos",
			Description = "Mostra um aviso em todos os servidores do jogo.",
		},
		{
			Name = "event",
			Args = {
				{ Name = "evento", Type = "event" },
				{ Name = "minutos", Type = "number", Min = 1 }, -- o Max vem de MaxMinutes (lá embaixo)
			},
			Scope = "Any",
			Category = "Eventos",
			Description = "Liga um evento global em todos os servidores por alguns minutos.",
		},
		{
			Name = "endevent",
			Args = {},
			Scope = "Any",
			Category = "Eventos",
			Description = "Encerra o evento global em todos os servidores.",
		},

		-- Moderação
		{
			Name = "kick",
			Args = {
				{ Name = "jogador", Type = "player" },
				{ Name = "motivo", Type = "text", Optional = true },
			},
			Scope = "Any",
			Category = "Moderação",
			Description = "Expulsa um jogador deste servidor.",
		},
		{
			Name = "ban",
			Args = {
				{ Name = "jogador", Type = "player" },
				{ Name = "duração", Type = "duration" },
				{ Name = "motivo", Type = "text", Optional = true },
			},
			Scope = "Any",
			Category = "Moderação",
			Description = "Bane um jogador do jogo todo (30m, 2h, 1d, 7d ou perm).",
		},
		{
			Name = "unban",
			Args = { { Name = "userId", Type = "number", Min = 1, Max = 1e15, Integer = true } },
			Scope = "Any",
			Category = "Moderação",
			Description = "Tira o banimento de um UserId.",
		},

		-- Ajuda
		{
			Name = "cmds",
			Args = {},
			Scope = "Any",
			Category = "Ajuda",
			Description = "Mostra a lista de comandos.",
		},
	},

	-- Eventos globais (comando ":event"). São GRÁTIS: um admin liga para todo mundo,
	-- ninguém paga Robux por eles. Por isso não são "sorte paga" e não precisam mostrar
	-- chances (as regras de itens aleatórios pagos do Roblox não se aplicam aqui).
	-- Effects (todos opcionais; ausente = sem efeito):
	--   CoinMult          = moedas × isto para todo mundo (junto com os game passes)
	--   TierLuckAdd       = + isto na Sorte de Tier do time
	--   EnchantChanceMult = chance de encantamento × isto (depois dos upgrades; com limite)
	--   GiantChanceAdd    = + isto na chance de gigante (0.3 = +30%; com limite)
	--   BoardCooldownMult = recarga do quadro "Plantar brainrots" × isto (0.5 = metade)
	Events = {
		moedas2x = {
			Name = "Moedas x2",
			Description = "Todo mundo ganha o dobro de moedas!",
			Effects = { CoinMult = 2 },
		},
		sorte = {
			Name = "Sorte Brainrot",
			Description = "+1 de Sorte de Tier e o dobro de chance de encantamento!",
			Effects = { TierLuckAdd = 1, EnchantChanceMult = 2 },
		},
		gigantes = {
			Name = "Invasão de Gigantes",
			Description = "+30% de chance de brainrot gigante!",
			Effects = { GiantChanceAdd = 0.3 },
		},
		abuse = {
			Name = "Admin Abuse",
			Description = "Tudo junto: moedas x2, sorte, gigantes e quadro recarregando na metade do tempo!",
			Effects = { CoinMult = 2, TierLuckAdd = 1, EnchantChanceMult = 2, GiantChanceAdd = 0.3, BoardCooldownMult = 0.5 },
		},
	},

	-- Ordem em que os eventos aparecem no painel e na ajuda.
	EventOrder = { "moedas2x", "sorte", "gigantes", "abuse" },
}

-- Índice por nome, montado por código (não precisa mexer): Admins.CommandsByName["fly"].
Admins.CommandsByName = {}
for _, command in ipairs(Admins.Commands) do
	Admins.CommandsByName[command.Name] = command
end

-- O limite de minutos do ":event" é o MaxMinutes (assim só existe um número para mudar).
Admins.CommandsByName.event.Args[2].Max = Admins.MaxMinutes

return Admins
