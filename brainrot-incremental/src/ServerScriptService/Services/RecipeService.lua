--!nonstrict
-- RecipeService: ingredientes e receitas do Caldeirão (só no Deserto, MapDef.HasRecipes).
--
-- Nos mapas sem receitas, Init/Start não fazem nada, RollIngredient é ignorado e o
-- pedido "Craft" responde false, "Não há receitas neste mapa.".
--
--   RecipeService.RollIngredient(killer, entity)
--       Chamado pelo BrainrotService quando um brainrot morre. Para cada ingrediente,
--       chance = DropChance[tier] × IngredientLuck do time. Cai no máximo 1 por morte.
--
--   Request "Craft"(ingredientIds: {string}) -> {RecipeId, Name, NewDiscovery}
--       1 a 3 ingredientes (pode repetir). Procura a receita com EXATAMENTE os mesmos
--       ingredientes e quantidades. Se achar: paga CoinCost × CostScale, gasta os
--       ingredientes e aplica o efeito para o time inteiro.
--
-- Tipos de receita (Config/Recipes):
--   "Permanent" -> bônus de stats até o fim da partida (só uma vez por partida);
--   "Timed"     -> EnchantAll: todo brainrot nasce encantado por Duration segundos;
--   "Instant"   -> NextWaveGiant (próxima leva só de gigantes) ou SupremeBoost (Supremo cresce).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local RecipesConfig = require(ConfigFolder:WaitForChild("Recipes"))
local Net = require(UtilFolder:WaitForChild("Net"))
local NumberFormat = require(UtilFolder:WaitForChild("NumberFormat"))

-- Serviços-folha (permitidos no topo, regra 1.2).
local Services = script.Parent
local DataService = require(Services:WaitForChild("DataService"))
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções (evita require circular).
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-------------------------------------------------------------------------------
-- Constantes técnicas (não são balanceamento)
-------------------------------------------------------------------------------
local MAX_SLOTS = 3 -- o caldeirão tem 3 espaços
local MAX_ID_LENGTH = 64
local DROP_TOAST_COOLDOWN = 1.5 -- no máximo um aviso de "ingrediente encontrado" a cada 1,5 s
local EFFECT_HEIGHT = 2 -- o brilho do ingrediente aparece um pouco acima do chão

local NO_RECIPES_MESSAGE = "Não há receitas neste mapa."
local MSG_NO_MATCH = "Nada aconteceu... essa combinação não é uma receita."
local MSG_ALREADY_ACTIVE = "Essa receita já está ativa nesta partida."
local MSG_BAD_SELECTION = "Escolha de 1 a 3 ingredientes."

-------------------------------------------------------------------------------
-- Estado do módulo
-------------------------------------------------------------------------------
local RecipeService = {}

local initialized = false
local enabled = false -- este mapa tem receitas?
local rng = Random.new()
local lastDropToast = {} -- [player] = os.clock() do último aviso de ingrediente

-------------------------------------------------------------------------------
-- Receitas indexadas pela combinação de ingredientes
-------------------------------------------------------------------------------

-- Monta uma chave única para um "multiconjunto" de ingredientes, em ordem alfabética.
-- Ex.: { MysticSand = 1, AssassinEspresso = 2 } -> "AssassinEspresso=2|MysticSand=1".
-- Duas combinações têm a mesma chave só se tiverem os mesmos ingredientes nas mesmas quantidades.
local function comboKey(counts)
	local parts = {}
	for ingredientId, count in pairs(counts) do
		if type(count) == "number" and count > 0 then
			table.insert(parts, ingredientId .. "=" .. tostring(math.floor(count)))
		end
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

-- [chave da combinação] = receita
local recipeByKey = {}
for _, recipe in ipairs(RecipesConfig.Recipes) do
	if type(recipe.Ingredients) == "table" then
		recipeByKey[comboKey(recipe.Ingredients)] = recipe
	end
end

-------------------------------------------------------------------------------
-- Pequenos ajudantes
-------------------------------------------------------------------------------

-- Tempo compartilhado entre servidor e cliente.
local function now()
	return workspace:GetServerTimeNow()
end

-- Número "de verdade": nem NaN, nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Confere se é um Player que ainda está no jogo.
local function isPlayerInGame(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Lê um número de uma tabela de stats (com valor padrão).
local function statNumber(stats, key, default)
	local value = type(stats) == "table" and stats[key] or nil
	if isFiniteNumber(value) then
		return value
	end
	return default
end

-- Stats do time (IngredientLuck é um upgrade do time).
local function getTeamStats()
	local ok, stats = pcall(function()
		return Svc("StatService").GetTeam()
	end)
	return ok and stats or nil
end

-- Garante que o time tem a tabela de buffs no formato da seção 8.2.
local function ensureBuffs(team)
	if type(team.Buffs) ~= "table" then
		team.Buffs = { TimedEnchantUntil = 0, NextWaveGiant = false }
	end
	if not isFiniteNumber(team.Buffs.TimedEnchantUntil) then
		team.Buffs.TimedEnchantUntil = 0
	end
	team.Buffs.NextWaveGiant = team.Buffs.NextWaveGiant == true
	return team.Buffs
end

-- Onde o brainrot estava (para o efeito do ingrediente).
local function entityPosition(entity)
	if typeof(entity.Position) == "Vector3" then
		return entity.Position
	end
	local model = entity.Model
	if typeof(model) == "Instance" and model:IsA("Model") then
		return model:GetPivot().Position
	end
	return nil
end

-------------------------------------------------------------------------------
-- Ingredientes
-------------------------------------------------------------------------------

function RecipeService.RollIngredient(killer, entity)
	if not enabled then
		return nil
	end
	-- Só jogadores ganham ingredientes (mortes por queimadura sem dono etc. não contam).
	if not isPlayerInGame(killer) or type(entity) ~= "table" then
		return nil
	end
	local def = entity.Def
	local tier = type(def) == "table" and def.Tier or nil
	if type(tier) ~= "string" then
		return nil
	end

	local run = Svc("MatchService").GetRun(killer)
	if not run then
		return nil
	end

	-- Sorteia cada ingrediente separadamente e, se mais de um "caiu", fica com um só.
	local luck = math.max(0, statNumber(getTeamStats(), "IngredientLuck", 1))
	local dropped = {}
	for _, ingredient in ipairs(RecipesConfig.Ingredients) do
		local baseChance = type(ingredient.DropChance) == "table" and ingredient.DropChance[tier] or nil
		if isFiniteNumber(baseChance) and baseChance > 0 then
			local chance = math.clamp(baseChance * luck, 0, 1)
			if rng:NextNumber() < chance then
				table.insert(dropped, ingredient)
			end
		end
	end
	if #dropped == 0 then
		return nil
	end
	local ingredient = dropped[rng:NextInteger(1, #dropped)]

	-- Guarda no inventário do jogador (run.Ingredients) e avisa o cliente.
	if type(run.Ingredients) ~= "table" then
		run.Ingredients = {}
	end
	run.Ingredients[ingredient.Id] = (tonumber(run.Ingredients[ingredient.Id]) or 0) + 1
	StateService.Set(killer, "Ingredients", table.clone(run.Ingredients))

	-- Brilho na cor do ingrediente onde o brainrot morreu.
	local position = entityPosition(entity)
	if position then
		Net.FireAll("Effect", "Ingredient", {
			Position = position + Vector3.new(0, EFFECT_HEIGHT, 0),
			Color = ingredient.Color,
		})
	end

	-- Aviso curto (com limite, para não lotar a tela com a metralhadora).
	local clock = os.clock()
	if clock - (lastDropToast[killer] or -math.huge) >= DROP_TOAST_COOLDOWN then
		lastDropToast[killer] = clock
		StateService.Notify(killer, "+1 " .. ingredient.Name, "success", 2)
	end

	return ingredient.Id
end

-------------------------------------------------------------------------------
-- Craft
-------------------------------------------------------------------------------

-- Lê e valida a lista enviada pelo cliente. Devolve {[id] = quantidade} ou nil, mensagem.
local function readSelection(ids)
	if type(ids) ~= "table" then
		return nil, MSG_BAD_SELECTION
	end
	local count = #ids
	if count < 1 or count > MAX_SLOTS then
		return nil, MSG_BAD_SELECTION
	end
	-- A tabela precisa ser uma lista "limpa" (sem chaves extras escondidas).
	local keys = 0
	for _ in pairs(ids) do
		keys += 1
		if keys > MAX_SLOTS then
			break
		end
	end
	if keys ~= count then
		return nil, MSG_BAD_SELECTION
	end

	local counts = {}
	for index = 1, count do
		local id = ids[index]
		if type(id) ~= "string" or #id == 0 or #id > MAX_ID_LENGTH or not RecipesConfig.IngredientsById[id] then
			return nil, "Ingrediente inválido."
		end
		counts[id] = (counts[id] or 0) + 1
	end
	return counts
end

-- Aplica o efeito da receita no time.
local function applyRecipe(recipe, team)
	if recipe.Kind == "Permanent" then
		-- Bônus de stats até o fim da partida (Formulas.ComputeStats lê Team.Recipes).
		if type(team.Recipes) ~= "table" then
			team.Recipes = {}
		end
		team.Recipes[recipe.Id] = true
		local ok, err = pcall(function()
			Svc("StatService").Invalidate()
		end)
		if not ok then
			warn("[RecipeService] Erro ao recalcular stats: " .. tostring(err))
		end
		StateService.SetAll("Recipes", table.clone(team.Recipes))
	end

	local buffs = ensureBuffs(team)
	if recipe.Special == "EnchantAll" then
		-- Se já estava ativo, o tempo novo soma ao que faltava.
		local duration = isFiniteNumber(recipe.Duration) and recipe.Duration or 0
		buffs.TimedEnchantUntil = math.max(buffs.TimedEnchantUntil, now()) + duration
	elseif recipe.Special == "NextWaveGiant" then
		buffs.NextWaveGiant = true
	elseif recipe.Special == "SupremeBoost" then
		local amount = isFiniteNumber(recipe.Amount) and recipe.Amount or 0
		local ok, err = pcall(function()
			Svc("SupremeService").AddProgress(amount)
		end)
		if not ok then
			warn("[RecipeService] Erro ao fazer o Supremo crescer: " .. tostring(err))
		end
	end
	StateService.SetAll("Buffs", table.clone(buffs))
end

local function craft(player, ids)
	if not enabled then
		return false, NO_RECIPES_MESSAGE
	end
	if not isPlayerInGame(player) then
		return false, "Jogador inválido."
	end

	local counts, selectionError = readSelection(ids)
	if not counts then
		return false, selectionError
	end

	local MatchService = Svc("MatchService")
	local run = MatchService.GetRun(player)
	if not run then
		return false, "Você ainda não entrou na partida."
	end

	-- O jogador precisa TER os ingredientes (também impede "testar" combinações de graça).
	local inventory = type(run.Ingredients) == "table" and run.Ingredients or {}
	for ingredientId, needed in pairs(counts) do
		if (tonumber(inventory[ingredientId]) or 0) < needed then
			local name = RecipesConfig.IngredientsById[ingredientId].Name
			return false, ("Você não tem %s suficiente."):format(name)
		end
	end

	-- Procura a receita com exatamente esses ingredientes e quantidades.
	local recipe = recipeByKey[comboKey(counts)]
	if not recipe then
		return false, MSG_NO_MATCH
	end

	local team = MatchService.GetTeam()
	local mapDef = MatchService.GetMapDef()
	local buffs = ensureBuffs(team)

	-- Regras de cada tipo (conferidas ANTES de cobrar).
	if recipe.Kind == "Permanent" and type(team.Recipes) == "table" and team.Recipes[recipe.Id] then
		return false, MSG_ALREADY_ACTIVE
	end
	if recipe.Special == "NextWaveGiant" and buffs.NextWaveGiant then
		return false, "A próxima leva já vai nascer gigante!"
	end
	if recipe.Special == "SupremeBoost" then
		if not (type(mapDef) == "table" and mapDef.HasSupreme) then
			return false, "Não há Brainrot Supremo neste mapa."
		end
		if (tonumber(team.SupremeProgress) or 0) >= 1 then
			return false, "O Supremo já tampou o sol!"
		end
	end

	-- Paga: CoinCost (unidades do Ato 1) × CostScale do mapa.
	local costScale = (type(mapDef) == "table" and isFiniteNumber(mapDef.CostScale)) and mapDef.CostScale or 1
	local cost = math.max(0, (isFiniteNumber(recipe.CoinCost) and recipe.CoinCost or 0) * costScale)
	if not MatchService.SpendCoins(player, cost) then
		return false, ("Moedas insuficientes! Essa receita custa %s."):format(NumberFormat.Abbrev(cost))
	end

	-- Gasta os ingredientes (quem chega a 0 sai da tabela).
	for ingredientId, used in pairs(counts) do
		local left = (tonumber(inventory[ingredientId]) or 0) - used
		inventory[ingredientId] = if left > 0 then left else nil
	end
	run.Ingredients = inventory
	StateService.Set(player, "Ingredients", table.clone(inventory))

	-- Efeito para o time.
	applyRecipe(recipe, team)

	-- Livro de Receitas (perfil): primeira vez = descoberta nova.
	local newDiscovery = false
	local profile = DataService.GetProfile(player)
	if profile then
		if type(profile.RecipesKnown) ~= "table" then
			profile.RecipesKnown = {}
		end
		if not profile.RecipesKnown[recipe.Id] then
			profile.RecipesKnown[recipe.Id] = true
			newDiscovery = true
			-- IncrementStat também sincroniza o perfil com o cliente.
			DataService.IncrementStat(player, "RecipesDiscovered", 1)
		end
	end

	-- Avisos e confete no caldeirão.
	local description = type(recipe.Description) == "string" and (" " .. recipe.Description) or ""
	if newDiscovery then
		StateService.NotifyAll(
			("%s descobriu a receita %s!%s"):format(player.DisplayName, recipe.Name, description),
			"rare",
			6
		)
	else
		StateService.NotifyAll(("%s preparou %s!%s"):format(player.DisplayName, recipe.Name, description), "success", 5)
	end
	local ctx = MatchService.GetContext()
	local cauldron = ctx and ctx.Cauldron
	if typeof(cauldron) == "Instance" and cauldron:IsA("BasePart") then
		Net.FireAll("Effect", "Purchase", { Position = cauldron.Position })
	end

	return true, { RecipeId = recipe.Id, Name = recipe.Name, NewDiscovery = newDiscovery }
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function RecipeService.Init()
	if initialized then
		return
	end
	initialized = true

	-- Este mapa tem receitas?
	local okDef, mapDef = pcall(function()
		return Svc("MatchService").GetMapDef()
	end)
	enabled = okDef and type(mapDef) == "table" and mapDef.HasRecipes == true

	-- Request "Craft" (registrado sempre: nos outros mapas responde com a mensagem).
	Net.Handle("Craft", function(player, ids)
		return craft(player, ids)
	end, { Rate = 2, Burst = 4 })

	if not enabled then
		return
	end

	Players.PlayerRemoving:Connect(function(player)
		lastDropToast[player] = nil
	end)
end

function RecipeService.Start() end

return RecipeService
