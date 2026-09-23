--!nonstrict
-- UpgradeService: compras nas barracas.
--
--   Request "BuyUpgrade"(upgradeId, amount)  amount = inteiro 1..1000 ou "max"
--       -> compra níveis de um upgrade (do jogador ou do time) com as moedas do jogador.
--          x1/x10: compra ATÉ "amount" níveis, só os que couberem no bolso (mínimo 1).
--          "max": compra todos os níveis que couberem.
--   Request "BuyShelf"()
--       -> libera a próxima prateleira de todas as barracas (quando tudo abaixo está no máximo).
--
--   UpgradeService.IsShelfMaxed(shelf)  -> todos os upgrades até essa prateleira estão no máximo?
--   UpgradeService.IsActComplete()      -> última prateleira liberada e tudo no máximo?
--   UpgradeService.GetLevel(player, def) -> nível atual (do jogador ou do time, conforme o escopo)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local GameConfig = require(ConfigFolder:WaitForChild("Game"))
local Upgrades = require(ConfigFolder:WaitForChild("Upgrades"))
local Net = require(UtilFolder:WaitForChild("Net"))
local Formulas = require(UtilFolder:WaitForChild("Formulas"))
local NumberFormat = require(UtilFolder:WaitForChild("NumberFormat"))

-- Módulo de mundo (permitido no topo).
local MapBuilder = require(ServerScriptService:WaitForChild("World"):WaitForChild("MapBuilder"))

-- Serviços-folha (permitidos no topo).
local Services = script.Parent
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções.
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-- Limites do argumento "amount" (constantes de validação).
local MIN_AMOUNT = 1
local MAX_AMOUNT = 1000
local MAX_ID_LENGTH = 64

local UpgradeService = {}

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Número "de verdade" (nem NaN nem infinito).
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- A barraca existe neste mapa?
local function mapHasStall(mapDef, stallId)
	return type(mapDef) == "table" and type(mapDef.Stalls) == "table" and table.find(mapDef.Stalls, stallId) ~= nil
end

-- Posição da barraca no mapa (para o efeito de confete), ou nil.
local function getStallPosition(stallId)
	local ctx = Svc("MatchService").GetContext()
	local stall = ctx and ctx.Stalls and ctx.Stalls[stallId]
	if not stall then
		return nil
	end
	if typeof(stall.Position) == "Vector3" then
		return stall.Position
	end
	if stall.Counter and stall.Counter:IsA("BasePart") then
		return stall.Counter.Position
	end
	return nil
end

-- Efeito "Purchase" (confete) na barraca.
local function firePurchaseEffect(stallId)
	local position = getStallPosition(stallId)
	if position then
		Net.FireAll("Effect", "Purchase", { Position = position })
	end
end

-- Pede ao ProgressionService para conferir se o ato terminou (protegido).
local function checkCompletion()
	local ok, err = pcall(function()
		Svc("ProgressionService").CheckCompletion()
	end)
	if not ok then
		warn("[UpgradeService] Erro ao conferir a conclusão do ato: " .. tostring(err))
	end
end

-- Recalcula os stats (protegido). player = nil -> todos + time.
local function invalidateStats(player)
	local ok, err = pcall(function()
		Svc("StatService").Invalidate(player)
	end)
	if not ok then
		warn("[UpgradeService] Erro ao recalcular stats: " .. tostring(err))
	end
end

-- Um upgrade de jogador está "maxado" para fins de concluir a prateleira/ato?
-- Depende de Config.Game.WeaponMaxRule:
--   "AnyPlayer"  -> algum run (inclusive de quem já saiu) tem o nível máximo;
--   "AllPlayers" -> todos os jogadores presentes (com run) têm o nível máximo.
local function isPlayerUpgradeMaxed(def, MatchService)
	if GameConfig.WeaponMaxRule == "AllPlayers" then
		local anyPresent = false
		for _, player in ipairs(Players:GetPlayers()) do
			local run = MatchService.GetRun(player)
			if run then
				anyPresent = true
				if not Formulas.IsUpgradeMaxed(def, run.Upgrades[def.Id] or 0) then
					return false
				end
			end
		end
		return anyPresent
	end

	for _, run in pairs(MatchService.Runs) do
		if Formulas.IsUpgradeMaxed(def, run.Upgrades[def.Id] or 0) then
			return true
		end
	end
	return false
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Nível atual de um upgrade para este jogador (escopo "Team" usa o nível do time).
function UpgradeService.GetLevel(player, def)
	if type(def) ~= "table" then
		return 0
	end
	local MatchService = Svc("MatchService")
	if def.Scope == "Team" then
		return MatchService.GetTeam().Upgrades[def.Id] or 0
	end
	local run = MatchService.GetRun(player)
	return run and run.Upgrades[def.Id] or 0
end

-- Todos os upgrades do mapa com Shelf <= shelf estão no máximo?
function UpgradeService.IsShelfMaxed(shelf)
	if not isFiniteNumber(shelf) then
		return false
	end
	local MatchService = Svc("MatchService")
	local mapId = MatchService.GetMapId()
	local mapDef = MatchService.GetMapDef()
	if not mapDef then
		return false
	end
	local team = MatchService.GetTeam()

	for _, def in ipairs(Upgrades.ByMap[mapId] or {}) do
		-- Upgrades de barracas que não existem no mapa não contam (não dá para comprá-los).
		if def.Shelf <= shelf and mapHasStall(mapDef, def.Stall) then
			if def.Scope == "Team" then
				if not Formulas.IsUpgradeMaxed(def, team.Upgrades[def.Id] or 0) then
					return false
				end
			elseif not isPlayerUpgradeMaxed(def, MatchService) then
				return false
			end
		end
	end
	return true
end

-- O ato está completo: última prateleira liberada e tudo no máximo.
function UpgradeService.IsActComplete()
	local MatchService = Svc("MatchService")
	local mapDef = MatchService.GetMapDef()
	if not mapDef then
		return false
	end
	local maxShelf = mapDef.MaxShelf or 1
	return MatchService.GetTeam().ShelfLevel >= maxShelf and UpgradeService.IsShelfMaxed(maxShelf)
end

-- Compra níveis de um upgrade. Devolve (true, {Level, Spent}) ou (false, mensagem).
function UpgradeService.BuyUpgrade(player, upgradeId, amount)
	-- Validação do id.
	if type(upgradeId) ~= "string" or #upgradeId == 0 or #upgradeId > MAX_ID_LENGTH then
		return false, "Upgrade inválido."
	end
	-- Validação da quantidade: "max" ou inteiro de 1 a 1000.
	local isMax = amount == "max"
	if not isMax then
		if not isFiniteNumber(amount) or amount % 1 ~= 0 or amount < MIN_AMOUNT or amount > MAX_AMOUNT then
			return false, "Quantidade inválida."
		end
	end

	local MatchService = Svc("MatchService")
	local mapId = MatchService.GetMapId()
	local mapDef = MatchService.GetMapDef()
	local def = Upgrades.ById[upgradeId]

	-- O upgrade precisa existir, ser deste mapa e estar numa barraca deste mapa.
	if not def or def.Map ~= mapId or not mapHasStall(mapDef, def.Stall) then
		return false, "Esse upgrade não existe neste mapa."
	end

	local team = MatchService.GetTeam()
	-- A prateleira do upgrade precisa estar liberada.
	if def.Shelf > team.ShelfLevel then
		return false, "Essa prateleira ainda está trancada. Melhore a barraca primeiro!"
	end

	local run = MatchService.GetRun(player)
	if not run then
		return false, "Seus dados ainda estão carregando. Tente de novo em instantes."
	end

	local currentLevel = UpgradeService.GetLevel(player, def)
	if Formulas.IsUpgradeMaxed(def, currentLevel) then
		return false, "Esse upgrade já está no nível máximo."
	end

	-- Quantos níveis cabem no bolso (nunca passa do MaxLevel).
	local coins = MatchService.GetCoins(player)
	local affordable, affordableCost = Formulas.MaxAffordable(def, currentLevel, coins)
	local levels, cost
	if isMax then
		levels, cost = affordable, affordableCost
	else
		-- x1 / x10: até "amount" níveis, só os que dá para pagar (compra parcial é permitida).
		levels = math.min(affordable, amount)
		cost = Formulas.CostForLevels(def, currentLevel, levels)
	end

	if levels < 1 then
		local nextCost = Formulas.UpgradeCost(def, currentLevel)
		return false, "Moedas insuficientes! Precisa de " .. NumberFormat.Abbrev(nextCost) .. "."
	end

	-- Paga (confere de novo dentro do SpendCoins).
	if not MatchService.SpendCoins(player, cost) then
		return false, "Moedas insuficientes!"
	end

	local newLevel = currentLevel + levels
	if def.Scope == "Team" then
		team.Upgrades[def.Id] = newLevel
		invalidateStats(nil)
		StateService.SetAll("TeamUpgrades", table.clone(team.Upgrades))
		StateService.NotifyAll(("%s comprou %s (nv. %d)"):format(player.DisplayName, def.Name, newLevel), "info")
	else
		run.Upgrades[def.Id] = newLevel
		invalidateStats(player)
		StateService.Set(player, "PlayerUpgrades", table.clone(run.Upgrades))
	end

	firePurchaseEffect(def.Stall)
	checkCompletion()

	return true, { Level = newLevel, Spent = cost }
end

-- Libera a próxima prateleira. Devolve (true, {ShelfLevel}) ou (false, mensagem).
function UpgradeService.BuyShelf(player)
	local MatchService = Svc("MatchService")
	local mapId = MatchService.GetMapId()
	local mapDef = MatchService.GetMapDef()
	if not mapDef then
		return false, "A partida ainda está carregando."
	end
	if not MatchService.GetRun(player) then
		return false, "Seus dados ainda estão carregando. Tente de novo em instantes."
	end

	local team = MatchService.GetTeam()
	local maxShelf = mapDef.MaxShelf or 1
	if team.ShelfLevel >= maxShelf then
		return false, "As barracas já estão no nível máximo."
	end
	if not UpgradeService.IsShelfMaxed(team.ShelfLevel) then
		return false, "Deixe todos os upgrades liberados no máximo primeiro."
	end

	local nextShelf = team.ShelfLevel + 1
	local cost = Formulas.ShelfCost(mapId, nextShelf)
	if not isFiniteNumber(cost) then
		return false, "Essa prateleira não está disponível."
	end
	if not MatchService.SpendCoins(player, cost) then
		return false, "Moedas insuficientes! Precisa de " .. NumberFormat.Abbrev(cost) .. "."
	end

	team.ShelfLevel = nextShelf

	-- Mostra as prateleiras novas no mapa.
	local ctx = MatchService.GetContext()
	if ctx then
		local ok, err = pcall(MapBuilder.SetShelfLevel, ctx, nextShelf)
		if not ok then
			warn("[UpgradeService] Erro ao mostrar as prateleiras: " .. tostring(err))
		end
	end

	StateService.SetAll("ShelfLevel", nextShelf)
	StateService.NotifyAll(
		("%s melhorou as barracas! Prateleira %d liberada."):format(player.DisplayName, nextShelf),
		"success",
		6
	)

	-- Confete em todas as barracas do mapa.
	for _, stallId in ipairs(mapDef.Stalls or {}) do
		firePurchaseEffect(stallId)
	end

	checkCompletion()
	return true, { ShelfLevel = nextShelf }
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function UpgradeService.Init()
	Net.Handle("BuyUpgrade", function(player, upgradeId, amount)
		return UpgradeService.BuyUpgrade(player, upgradeId, amount)
	end, { Rate = 10, Burst = 20 })

	Net.Handle("BuyShelf", function(player)
		return UpgradeService.BuyShelf(player)
	end, { Rate = 2, Burst = 4 })
end

function UpgradeService.Start() end

return UpgradeService
