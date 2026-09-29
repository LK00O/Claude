-- Config/Recipes: ingredientes e receitas do Caldeirão (só no Deserto).
-- Brainrots do deserto às vezes soltam ingredientes. No Caldeirão, o jogador
-- junta 2 ou 3 ingredientes + moedas para fazer uma receita com bônus forte.
--
-- Ingredientes:
--   Id, Name    nome interno e nome em português
--   Color       cor do ícone e do efeito quando cai
--   DropChance  chance de cair por tier do brainrot (multiplicada por IngredientLuck)
--
-- Receitas:
--   Id, Name     nome interno e nome em português
--   Hint         dica mostrada no Livro de Receitas enquanto a receita é "???"
--   Description  o que a receita faz (texto para o jogador)
--   Ingredients  { [ingredienteId] = quantidade } (total de 2 ou 3 peças)
--   CoinCost     custo em moedas, em unidades do Ato 1 (× CostScale do Deserto)
--   Kind         "Permanent" (bônus até o fim da partida, só uma vez),
--                "Timed" (dura Duration segundos) ou "Instant" (acontece na hora)
--   Effects      lista de { Stat, Mode, Value } aplicada como upgrade de nível 1
--                (Mode "Mult": valor × (1 + Value); "Pow": valor × Value; "Add": valor + Value)
--   Special      efeito especial: "EnchantAll", "NextWaveGiant" ou "SupremeBoost"
--   Duration     (Timed) segundos que o efeito dura
--   Amount       (SupremeBoost) quanto de progresso o Supremo ganha (0.05 = 5%)

-- Atalho para criar cores a partir de R, G, B (0 a 255).
local rgb = Color3.fromRGB

local Recipes = {}

Recipes.Ingredients = {
	{
		Id = "MysticSand",
		Name = "Areia Mística",
		Color = rgb(235, 200, 120),
		DropChance = { Low = 0.03, Medium = 0.06, High = 0.12 },
	},
	{
		Id = "AssassinEspresso",
		Name = "Espresso Assassino",
		Color = rgb(95, 55, 30),
		DropChance = { Low = 0.02, Medium = 0.05, High = 0.1 },
	},
	{
		Id = "CosmicBanana",
		Name = "Banana Cósmica",
		Color = rgb(250, 225, 60),
		DropChance = { Low = 0.015, Medium = 0.04, High = 0.09 },
	},
	{
		Id = "SahurDrum",
		Name = "Tamborim de Sahur",
		Color = rgb(190, 110, 60),
		DropChance = { Low = 0.025, Medium = 0.05, High = 0.1 },
	},
	{
		Id = "EternalIce",
		Name = "Gelo Eterno",
		Color = rgb(150, 225, 255),
		DropChance = { Low = 0.01, Medium = 0.03, High = 0.08 },
	},
}

Recipes.Recipes = {
	{
		Id = "DoubleDamage",
		Name = "Molho de Tralalero",
		Hint = "Algo arenoso com algo muito forte...",
		Description = "Dano ×2 para o time inteiro até o fim da partida.",
		Ingredients = { MysticSand = 1, AssassinEspresso = 2 },
		CoinCost = 5e4,
		Kind = "Permanent",
		Effects = { { Stat = "Damage", Mode = "Mult", Value = 1 } }, -- Mult 1 → ×2
	},
	{
		Id = "TripleCoins",
		Name = "Risoto Dourado do Bananini",
		Hint = "Duas frutas caídas do espaço e um punhado de chão do deserto...",
		Description = "Moedas ×3 para o time inteiro até o fim da partida.",
		Ingredients = { CosmicBanana = 2, MysticSand = 1 },
		CoinCost = 1.5e5,
		Kind = "Permanent",
		Effects = { { Stat = "CoinMult", Mode = "Mult", Value = 2 } }, -- Mult 2 → ×3
	},
	{
		Id = "GrowthBoost",
		Name = "Adubo de Patapim",
		Hint = "Um ritmo que acorda qualquer um e algo que brilha lá no céu...",
		Description = "Brainrots crescem 50% mais (tamanho alvo ×1,5) até o fim da partida.",
		Ingredients = { SahurDrum = 1, CosmicBanana = 1 },
		CoinCost = 8e4,
		Kind = "Permanent",
		Effects = { { Stat = "GrowthMult", Mode = "Pow", Value = 1.5 } }, -- Pow 1.5 (nível 1) → ×1,5
	},
	{
		Id = "TurretFrenzy",
		Name = "Café Metralhado",
		Hint = "Muito batuque e uma dose de cafeína...",
		Description = "Torretas atiram 2× mais rápido até o fim da partida.",
		Ingredients = { AssassinEspresso = 1, SahurDrum = 2 },
		CoinCost = 1e5,
		Kind = "Permanent",
		Effects = { { Stat = "TurretFireRate", Mode = "Mult", Value = 1 } }, -- Mult 1 → ×2
	},
	{
		Id = "EnchantStorm",
		Name = "Poção Arco-íris",
		Hint = "Um pouco de cada canto do mundo: céu, gelo e areia...",
		Description = "Todo brainrot nasce encantado por 60 segundos.",
		Ingredients = { CosmicBanana = 1, EternalIce = 1, MysticSand = 1 },
		CoinCost = 6e4,
		Kind = "Timed",
		Special = "EnchantAll",
		Duration = 60,
		Effects = {},
	},
	{
		Id = "GiantWave",
		Name = "Fermento Gigantesco",
		Hint = "Batuque na areia faz tudo crescer...",
		Description = "A próxima leva de brainrots nasce inteira de Gigantes.",
		Ingredients = { SahurDrum = 1, MysticSand = 1 },
		CoinCost = 2e4,
		Kind = "Instant",
		Special = "NextWaveGiant",
		Effects = {},
	},
	{
		Id = "SupremeSoup",
		Name = "Sopa Suprema",
		Hint = "Gelo, ritmo e café: o café da manhã de um rei...",
		Description = "O Brainrot Supremo cresce 5% na hora.",
		Ingredients = { EternalIce = 1, SahurDrum = 1, AssassinEspresso = 1 },
		CoinCost = 2e5,
		Kind = "Instant",
		Special = "SupremeBoost",
		Amount = 0.05,
		Effects = {},
	},
	{
		Id = "HeatSink",
		Name = "Granita Eterna",
		Hint = "Muito frio que nunca derrete, com um toque do deserto...",
		Description = "Tanque de calor da arma ×2 para o time até o fim da partida.",
		Ingredients = { EternalIce = 2, MysticSand = 1 },
		CoinCost = 7e4,
		Kind = "Permanent",
		Effects = { { Stat = "HeatCapacity", Mode = "Mult", Value = 1 } }, -- Mult 1 → ×2
	},
}

-- Tabelas de busca rápida (montadas por código):
--   ById[recipeId]            -> definição da receita
--   IngredientsById[ingredId] -> definição do ingrediente
Recipes.ById = {}
Recipes.IngredientsById = {}

for _, ingredient in ipairs(Recipes.Ingredients) do
	Recipes.IngredientsById[ingredient.Id] = ingredient
end

-- Monta uma "chave" única para uma combinação de ingredientes, em ordem
-- alfabética (ex.: "AssassinEspresso=2|MysticSand=1"). Serve só para
-- conferir abaixo se duas receitas têm a mesma combinação.
local function comboKey(ingredients)
	local parts = {}
	for id, count in pairs(ingredients) do
		table.insert(parts, id .. "=" .. tostring(count))
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

-- Confere a configuração e avisa no Output se algo estiver errado
-- (útil quando você editar as receitas no futuro).
local seenCombos = {}
for _, recipe in ipairs(Recipes.Recipes) do
	Recipes.ById[recipe.Id] = recipe

	local total = 0
	for id, count in pairs(recipe.Ingredients) do
		if Recipes.IngredientsById[id] == nil then
			warn("[Config.Recipes] Receita " .. recipe.Id .. " usa ingrediente desconhecido: " .. tostring(id))
		end
		total += count
	end
	if total < 2 or total > 3 then
		warn("[Config.Recipes] Receita " .. recipe.Id .. " deve usar 2 ou 3 ingredientes (usa " .. total .. ")")
	end

	local key = comboKey(recipe.Ingredients)
	if seenCombos[key] then
		warn("[Config.Recipes] Receitas " .. seenCombos[key] .. " e " .. recipe.Id .. " têm a mesma combinação")
	else
		seenCombos[key] = recipe.Id
	end
end

return Recipes
