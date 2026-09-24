--!nonstrict
-- QuestService: as missões da Barraca de Missões (seção 8.9 da especificação).
--
-- Como funciona:
--   * Request "TakeQuest"(): se o jogador não tem missão e já passou a espera, sorteia um
--     modelo de Config.Quests (só os que o time pode cumprir, ver "Requires"), calcula o alvo
--     e a recompensa e guarda em run.Quest.
--   * O progresso vem de sinais de outros serviços:
--       BrainrotService.Killed   -> "Kill", "KillTier", "KillGiant", "KillEnchanted"
--       MatchService.CoinsAdded  -> "Collect"
--       BrainrotService.Exploded -> "Chain"
--       CombatService.Crit       -> "Crit"
--   * Ao completar: dá as moedas (fonte "Quest"), soma Stats.QuestsCompleted, avisa o jogador
--     e começa a espera (stats.QuestCooldown segundos).
--   * Request "AbandonQuest"(): joga a missão fora e aplica metade da espera.
--
-- O estado vai para o cliente na chave "Quest":
--   {Active = nil | {Id, Type, Text, Target, Progress, Reward}, CooldownEnd = número}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Módulos compartilhados (Config e Util).
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local Quests = require(ConfigFolder:WaitForChild("Quests"))
local Maps = require(ConfigFolder:WaitForChild("Maps"))

local Net = require(UtilFolder:WaitForChild("Net"))
local Formulas = require(UtilFolder:WaitForChild("Formulas"))
local NumberFormat = require(UtilFolder:WaitForChild("NumberFormat"))

-- Serviços-folha (podem ser usados no topo, regra 1.2).
local Services = script.Parent
local DataService = require(Services:WaitForChild("DataService"))
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções (regra anti-require-circular).
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------
local ABANDON_COOLDOWN_FRACTION = 0.5 -- abandonar = metade da espera normal
local COMPLETE_NOTIFY_DURATION = 5 -- segundos que o aviso de missão concluída fica na tela

-- Fontes de moedas que NÃO contam para missões "Collect":
--   Quest  = a própria recompensa de missão (spec 8.9)
--   Refund = devolução de moedas não é "coletar"
local IGNORED_COIN_SOURCES = { Quest = true, Refund = true }

-- Mensagens para o jogador (português do Brasil).
local MSG_NOT_READY = "Sua partida ainda está carregando. Tente de novo em instantes."
local MSG_NO_QUEST_STALL = "Não há missões neste mapa."
local MSG_ALREADY_ACTIVE = "Você já tem uma missão ativa."
local MSG_COOLDOWN = "Nova missão disponível em %s."
local MSG_NO_TEMPLATE = "Nenhuma missão disponível agora."
local MSG_NO_ACTIVE = "Você não tem uma missão ativa."
local MSG_TAKEN = "Nova missão: %s"
local MSG_ABANDONED = "Missão abandonada. Próxima em %s."
local MSG_COMPLETED = "Missão concluída! +%s moedas"

-------------------------------------------------------------------------------
-- Estado do módulo
-------------------------------------------------------------------------------
local QuestService = {}

local templatesById = {} -- [templateId] = modelo do Config.Quests
local lastTemplateByUser = {} -- [userId] = id do último modelo sorteado (evita repetir em seguida)
local rng = Random.new()
local initialized = false
local started = false

for _, template in ipairs(Quests.Templates) do
	templatesById[template.Id] = template
end

-------------------------------------------------------------------------------
-- Pequenos ajudantes
-------------------------------------------------------------------------------

-- Hora compartilhada entre servidor e cliente.
local function now()
	return workspace:GetServerTimeNow()
end

-- Número "de verdade": nem NaN, nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Confere se é um jogador que ainda está no servidor.
local function isPlayerInGame(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Run (progresso na partida) do jogador, ou nil.
local function getRun(player)
	if not isPlayerInGame(player) then
		return nil
	end
	local run = Svc("MatchService").GetRun(player)
	if type(run) == "table" then
		return run
	end
	return nil
end

-- Lê um stat numérico com valor padrão.
local function statNumber(stats, key, default)
	local value = type(stats) == "table" and stats[key] or nil
	if isFiniteNumber(value) then
		return value
	end
	return default
end

-- Espera normal entre missões (stat do jogador, já limitado pelo Config.Stats.Clamps).
local function getCooldownSeconds(player)
	local stats = Svc("StatService").Get(player)
	return math.max(0, statNumber(stats, "QuestCooldown", 60))
end

-- Soma de todos os níveis de upgrade (do jogador e do time) neste mapa.
-- Quanto mais upgrades, maior o alvo das missões.
local function sumUpgradeLevels(run, team)
	local total = 0
	for _, levels in ipairs({ run and run.Upgrades, team and team.Upgrades }) do
		if type(levels) == "table" then
			for _, level in pairs(levels) do
				if isFiniteNumber(level) and level > 0 then
					total += math.floor(level)
				end
			end
		end
	end
	return total
end

-- Manda o estado "Quest" para o cliente (sempre uma cópia nova).
local function publishQuest(player, run)
	local active = nil
	if type(run.Quest) == "table" then
		active = table.clone(run.Quest)
	end
	StateService.Set(player, "Quest", {
		Active = active,
		CooldownEnd = isFiniteNumber(run.QuestCooldownEnd) and run.QuestCooldownEnd or 0,
	})
end

-- Texto da missão: troca o %s do modelo pelo alvo já formatado.
local function formatQuestText(template, targetText)
	local ok, text = pcall(string.format, template.Text, targetText)
	if ok and type(text) == "string" then
		return text
	end
	return tostring(template.Text) .. " (" .. targetText .. ")"
end

-- O time cumpre o "Requires" do modelo? (ex.: missão de explosão só com chance de explosão)
local function meetsRequirements(template, teamStats)
	local requires = template.Requires
	if type(requires) ~= "table" then
		return true
	end
	local value = statNumber(teamStats, requires.Stat, 0)
	return value >= (tonumber(requires.Min) or 0)
end

-- Sorteia um modelo entre os que o time pode cumprir. Evita repetir o último, se houver outro.
local function pickTemplate(teamStats, lastId)
	local eligible = {}
	for _, template in ipairs(Quests.Templates) do
		if meetsRequirements(template, teamStats) then
			table.insert(eligible, template)
		end
	end
	if #eligible == 0 then
		return nil
	end
	if #eligible > 1 and lastId ~= nil then
		local withoutLast = {}
		for _, template in ipairs(eligible) do
			if template.Id ~= lastId then
				table.insert(withoutLast, template)
			end
		end
		if #withoutLast > 0 then
			eligible = withoutLast
		end
	end
	return eligible[rng:NextInteger(1, #eligible)]
end

-- Renda por segundo usada nas missões: a média LENTA (~120 s, run.IncomeSlow, feita pelo
-- MatchService), e não a de 10 s (run.IncomeEMA, a da HUD). A de 10 s dá um salto enorme
-- quando o jogador pega de uma vez as moedas acumuladas no caixote: pegar a missão logo
-- depois disso dava uma recompensa 6 a 12 vezes maior do que os ~90 s de renda prometidos.
local function questIncome(run)
	return isFiniteNumber(run.IncomeSlow) and math.max(0, run.IncomeSlow) or 0
end

-- Multiplicador dos game passes de moedas do jogador (Moedas em Dobro, VIP). A renda
-- (run.IncomeSlow) já vem com ele, e o MatchService.AddCoins aplica de novo quando paga a
-- missão: a recompensa usa a renda SEM os passes, senão o bônus contaria duas vezes
-- (×2 virava ×4 e o VIP ×1,25 virava ×1,56).
local function passCoinMult(player)
	local ok, mult = pcall(function()
		local MonetizationService = Svc("MonetizationService")
		return Formulas.PassCoinMult({
			DoubleCoins = MonetizationService.HasPass(player, "DoubleCoins") == true,
			VIP = MonetizationService.HasPass(player, "VIP") == true,
		})
	end)
	if ok and isFiniteNumber(mult) and mult > 0 then
		return mult
	end
	return 1
end

-- Calcula o alvo da missão (seção 5.10):
--   Collect: max(RewardFloor × CostScale, Renda × BaseSeconds)
--   outras:  ceil(Base × (1 + somaDeNíveis × ScalePerUpgradeLevel))
local function computeTarget(template, run, team, mapDef)
	if template.Type == "Collect" then
		local costScale = mapDef and tonumber(mapDef.CostScale) or 1
		local income = questIncome(run)
		local seconds = tonumber(template.BaseSeconds) or 60
		return math.max(1, math.ceil(math.max(Quests.RewardFloor * costScale, income * seconds)))
	end
	local base = tonumber(template.Base) or 1
	local levels = sumUpgradeLevels(run, team)
	return math.max(1, math.ceil(base * (1 + levels * Quests.ScalePerUpgradeLevel)))
end

-- Alvo formatado para o texto (moedas abreviadas; contagens com separador de milhar).
local function formatTarget(template, target)
	if template.Type == "Collect" then
		return NumberFormat.Abbrev(target)
	end
	return NumberFormat.Commas(target)
end

-------------------------------------------------------------------------------
-- Conclusão e progresso
-------------------------------------------------------------------------------

-- Missão cumprida: paga, soma estatística, avisa e começa a espera.
local function completeQuest(player, run)
	local quest = run.Quest
	if type(quest) ~= "table" then
		return
	end
	-- Tira a missão ANTES de pagar (evita pagar duas vezes se outro sinal chegar junto).
	run.Quest = nil
	run.QuestCooldownEnd = now() + getCooldownSeconds(player)

	local reward = isFiniteNumber(quest.Reward) and math.max(0, quest.Reward) or 0
	if reward > 0 then
		Svc("MatchService").AddCoins(player, reward, "Quest")
	end
	DataService.IncrementStat(player, "QuestsCompleted", 1)

	StateService.Notify(player, MSG_COMPLETED:format(NumberFormat.Abbrev(reward)), "success", COMPLETE_NOTIFY_DURATION)
	publishQuest(player, run)
end

-- Soma progresso na missão ativa do jogador, se ela for de um dos tipos aceitos.
-- "matches(quest, template)" pode filtrar mais (ex.: só tier Alto).
local function addProgress(player, questTypes, amount, matches)
	if not isFiniteNumber(amount) or amount <= 0 then
		return
	end
	local run = getRun(player)
	local quest = run and run.Quest
	if type(quest) ~= "table" or not questTypes[quest.Type] then
		return
	end
	local template = templatesById[quest.Id]
	if matches and not matches(quest, template) then
		return
	end

	local target = isFiniteNumber(quest.Target) and quest.Target or 1
	local progress = (isFiniteNumber(quest.Progress) and quest.Progress or 0) + amount
	quest.Progress = math.min(target, progress)

	if quest.Progress >= target then
		completeQuest(player, run)
	else
		publishQuest(player, run)
	end
end

-- Tipos aceitos por cada sinal (conjuntos para checar rápido).
local KILL_TYPES = { Kill = true, KillTier = true, KillGiant = true, KillEnchanted = true }
local COLLECT_TYPES = { Collect = true }
local CHAIN_TYPES = { Chain = true }
local CRIT_TYPES = { Crit = true }

-- Um brainrot morreu: conta para quem matou (só se o matador é um jogador).
local function onBrainrotKilled(killer, entity, info)
	if not isPlayerInGame(killer) or type(entity) ~= "table" then
		return
	end
	addProgress(killer, KILL_TYPES, 1, function(quest, template)
		if quest.Type == "Kill" then
			return true
		elseif quest.Type == "KillTier" then
			local def = entity.Def
			return template ~= nil and type(def) == "table" and def.Tier == template.Tier
		elseif quest.Type == "KillGiant" then
			return entity.Giant == true
		elseif quest.Type == "KillEnchanted" then
			return entity.Enchant ~= nil
		end
		return false
	end)
end

-- Moedas entraram na carteira do jogador.
local function onCoinsAdded(player, amount, source)
	if IGNORED_COIN_SOURCES[source] then
		return
	end
	addProgress(player, COLLECT_TYPES, amount)
end

-- Um brainrot explodiu (explosão em cadeia) por causa de um jogador.
local function onExploded(player)
	if not isPlayerInGame(player) then
		return
	end
	addProgress(player, CHAIN_TYPES, 1)
end

-- Um tiro teve "count" críticos.
local function onCrit(player, count)
	if not isPlayerInGame(player) then
		return
	end
	addProgress(player, CRIT_TYPES, tonumber(count) or 0)
end

-------------------------------------------------------------------------------
-- Requests
-------------------------------------------------------------------------------

-- Request "TakeQuest"() -> true, quest | false, mensagem
local function handleTakeQuest(player)
	local run = getRun(player)
	if not run then
		return false, MSG_NOT_READY
	end

	local MatchService = Svc("MatchService")
	local mapDef = MatchService.GetMapDef() or Maps[MatchService.GetMapId()]
	if type(mapDef) == "table" and type(mapDef.Stalls) == "table" and not table.find(mapDef.Stalls, "Quest") then
		return false, MSG_NO_QUEST_STALL
	end

	if type(run.Quest) == "table" then
		return false, MSG_ALREADY_ACTIVE
	end

	local cooldownEnd = isFiniteNumber(run.QuestCooldownEnd) and run.QuestCooldownEnd or 0
	local remaining = cooldownEnd - now()
	if remaining > 0 then
		return false, MSG_COOLDOWN:format(NumberFormat.Time(math.ceil(remaining)))
	end

	-- Modelo: só os que o time consegue cumprir (Requires usa os stats do time).
	local teamStats = Svc("StatService").GetTeam()
	local template = pickTemplate(teamStats, lastTemplateByUser[player.UserId])
	if not template then
		return false, MSG_NO_TEMPLATE
	end

	-- Alvo e recompensa (seção 5.10). A recompensa usa o stat QuestReward do jogador.
	local team = MatchService.GetTeam()
	local target = computeTarget(template, run, team, mapDef)
	local stats = Svc("StatService").Get(player)
	local income = questIncome(run) / passCoinMult(player) -- média lenta, sem os passes (ver acima)
	local reward = Formulas.QuestReward(MatchService.GetMapId(), income, statNumber(stats, "QuestReward", 1))
	reward = isFiniteNumber(reward) and math.max(1, math.floor(reward)) or 1

	local quest = {
		Id = template.Id,
		Type = template.Type,
		Text = formatQuestText(template, formatTarget(template, target)),
		Target = target,
		Progress = 0,
		Reward = reward,
	}
	run.Quest = quest
	lastTemplateByUser[player.UserId] = template.Id

	publishQuest(player, run)
	StateService.Notify(player, MSG_TAKEN:format(quest.Text), "info")
	return true, table.clone(quest)
end

-- Request "AbandonQuest"() -> true | false, mensagem
local function handleAbandonQuest(player)
	local run = getRun(player)
	if not run then
		return false, MSG_NOT_READY
	end
	if type(run.Quest) ~= "table" then
		return false, MSG_NO_ACTIVE
	end

	local cooldown = getCooldownSeconds(player) * ABANDON_COOLDOWN_FRACTION
	run.Quest = nil
	run.QuestCooldownEnd = now() + cooldown

	publishQuest(player, run)
	StateService.Notify(player, MSG_ABANDONED:format(NumberFormat.Time(math.ceil(cooldown))), "info")
	return true, true
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

-- Conecta um sinal de outro serviço, protegido (se o serviço não existir, só avisa).
local function connectSignal(serviceName, signalName, handler)
	local ok, err = pcall(function()
		local service = Svc(serviceName)
		local signal = service[signalName]
		if type(signal) ~= "table" or type(signal.Connect) ~= "function" then
			error(serviceName .. "." .. signalName .. " não é um Signal")
		end
		signal:Connect(handler)
	end)
	if not ok then
		warn(("[QuestService] Não foi possível escutar %s.%s: %s"):format(serviceName, signalName, tostring(err)))
	end
end

function QuestService.Init()
	if initialized then
		return
	end
	initialized = true

	-- Requests do cliente (sem argumentos: qualquer argumento extra é ignorado).
	Net.Handle("TakeQuest", function(player)
		return handleTakeQuest(player)
	end)
	Net.Handle("AbandonQuest", function(player)
		return handleAbandonQuest(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastTemplateByUser[player.UserId] = nil
	end)
end

function QuestService.Start()
	if started then
		return
	end
	started = true

	-- Fontes de progresso.
	connectSignal("BrainrotService", "Killed", onBrainrotKilled)
	connectSignal("BrainrotService", "Exploded", onExploded)
	connectSignal("MatchService", "CoinsAdded", onCoinsAdded)
	connectSignal("CombatService", "Crit", onCrit)
end

return QuestService
