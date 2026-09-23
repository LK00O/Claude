-- Config/Achievements: as conquistas salvas no perfil do jogador.
-- Existem dois jeitos de ganhar uma conquista:
--   1) Stat + Threshold: quando a estatística do perfil (Stats) chega no valor.
--      O caminho usa ponto, ex.: "Kills.Low" = Stats.Kills.Low.
--   2) Event: quando o servidor dispara um evento
--      ("CompleteMap" com Map = mapa concluído; "PlayWithFriends" com Count = nº de amigos).
--
-- Outros campos:
--   Tokens   quantos Brainrot Tokens a conquista dá (moeda do lobby)
--   BadgeId  id da badge do Roblox (0 = sem badge; o dono preenche depois)
--   Secret   true = aparece como "???" até ser desbloqueada

local Achievements = {}

Achievements.List = {
	{
		Id = "FirstBlood",
		Name = "Primeiro Brainrot",
		Description = "Destrua 1 brainrot",
		Stat = "KillsTotal",
		Threshold = 1,
		Tokens = 1,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "LowHarvest",
		Name = "Colheita de Sahur",
		Description = "Destrua 1.000 brainrots de tier Baixo",
		Stat = "Kills.Low",
		Threshold = 1000,
		Tokens = 5,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "MediumCollection",
		Name = "Coleção Média",
		Description = "Destrua 500 brainrots de tier Médio",
		Stat = "Kills.Medium",
		Threshold = 500,
		Tokens = 5,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "LegendHunter",
		Name = "Caçador de Lendas",
		Description = "Destrua 100 brainrots de tier Alto",
		Stat = "Kills.High",
		Threshold = 100,
		Tokens = 5,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "CompleteMeadow",
		Name = "Adeus, Prado",
		Description = "Complete o Prado Brainrot",
		Event = "CompleteMap",
		Map = "Meadow",
		Tokens = 5,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "CompleteWinter",
		Name = "Degelo Total",
		Description = "Complete a Tundra Congelini",
		Event = "CompleteMap",
		Map = "Winter",
		Tokens = 10,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "EclipseBrainrot",
		Name = "Eclipse Brainrot",
		Description = "Complete o Deserto Sahur e tampe o sol com o Brainrot Supremo",
		Secret = true,
		Event = "CompleteMap",
		Map = "Desert",
		Tokens = 25,
		BadgeId = 0,
	},
	{
		Id = "FirstGalactic",
		Name = "Poeira de Estrelas",
		Description = "Destrua um brainrot Galáctico",
		Stat = "Galactic",
		Threshold = 1,
		Tokens = 5,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "ChainMaster",
		Name = "Mestre das Explosões",
		Description = "Cause 100 explosões de brainrot",
		Stat = "Chains",
		Threshold = 100,
		Tokens = 5,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "Billionaire",
		Name = "Bilionário Brainrot",
		Description = "Colete 1 bilhão de moedas no total",
		Stat = "TotalCoins",
		Threshold = 1e9,
		Tokens = 10,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "SquadGoals",
		Name = "Esquadrão Brainrot",
		Description = "Jogue uma partida com 4 amigos",
		Event = "PlayWithFriends",
		Count = 4,
		Tokens = 5,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "MasterChef",
		Name = "Chef Supremo",
		Description = "Descubra as 8 receitas do Caldeirão",
		Stat = "RecipesDiscovered",
		Threshold = 8,
		Tokens = 10,
		BadgeId = 0,
		Secret = false,
	},
	{
		Id = "QuestLover",
		Name = "Viciado em Missões",
		Description = "Complete 50 missões",
		Stat = "QuestsCompleted",
		Threshold = 50,
		Tokens = 5,
		BadgeId = 0,
		Secret = false,
	},
}

-- ById[id] -> definição da conquista (montado por código).
Achievements.ById = {}

for _, def in ipairs(Achievements.List) do
	Achievements.ById[def.Id] = def
end

return Achievements
