--!nonstrict
-- MonetizationService: game passes da partida (Moedas em Dobro, Coleta Automática, Torreta Extra).
--
--   * Na entrada, confere quais passes o jogador tem (UserOwnsGamePassAsync).
--   * Quando ele compra um pass dentro do jogo, ativa na hora (PromptGamePassPurchaseFinished).
--   * MonetizationService.HasPass(player, key) -> boolean  (usado por StatService, CoinService etc.)
--   * Envia a chave de estado "Gamepasses" = {DoubleCoins, AutoCollect, ExtraTurret}.
--   * Request "BuyGamepass"(key) abre a janela de compra do Roblox.
--
-- Tudo só funciona se Config.Game.Gamepasses.Enabled = true e o id do pass for > 0.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local GameConfig = require(ConfigFolder:WaitForChild("Game"))
local Net = require(UtilFolder:WaitForChild("Net"))

-- Serviços-folha (permitidos no topo).
local Services = script.Parent
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções.
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-- Lista fechada de passes (mesmas chaves da chave de estado "Gamepasses").
local PASS_KEYS = { "DoubleCoins", "AutoCollect", "ExtraTurret" }

-- Nome de cada pass em português (para avisos).
local PASS_NAMES = {
	DoubleCoins = "Moedas em Dobro",
	AutoCollect = "Coleta Automática",
	ExtraTurret = "Torreta Extra",
}

-- Tentativas da chamada web de conferir posse (constante técnica).
local OWNERSHIP_ATTEMPTS = 3
local OWNERSHIP_RETRY_DELAY = 1

local MonetizationService = {}

local owned = {} -- [player] = {DoubleCoins = bool, AutoCollect = bool, ExtraTurret = bool}

-- Id do pass no Config, ou nil se os passes estão desligados / id não preenchido.
local function getPassId(key)
	local config = GameConfig.Gamepasses
	if type(config) ~= "table" or config.Enabled ~= true then
		return nil
	end
	local id = config[key]
	if type(id) == "number" and id > 0 then
		return id
	end
	return nil
end

-- Descobre a chave ("DoubleCoins"...) a partir do id do pass.
local function getKeyFromId(passId)
	for _, key in ipairs(PASS_KEYS) do
		if getPassId(key) == passId then
			return key
		end
	end
	return nil
end

-- Tabela nova com todos os passes desligados.
local function emptyPasses()
	local passes = {}
	for _, key in ipairs(PASS_KEYS) do
		passes[key] = false
	end
	return passes
end

-- Envia a chave de estado "Gamepasses" do jogador.
local function sendState(player)
	local passes = owned[player]
	if not passes then
		return
	end
	StateService.Set(player, "Gamepasses", table.clone(passes))
end

-- Os stats do jogador dependem dos passes (ex.: moedas em dobro): recalcula.
local function invalidateStats(player)
	local ok, err = pcall(function()
		Svc("StatService").Invalidate(player)
	end)
	if not ok then
		warn("[MonetizationService] Erro ao atualizar stats: " .. tostring(err))
	end
end

-- Pergunta ao Roblox se o jogador tem o pass (com algumas tentativas).
local function checkOwnership(player, passId)
	for attempt = 1, OWNERSHIP_ATTEMPTS do
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if ok then
			return result == true
		end
		warn(("[MonetizationService] Falha ao conferir o pass %d (tentativa %d): %s"):format(passId, attempt, tostring(result)))
		if attempt < OWNERSHIP_ATTEMPTS then
			task.wait(OWNERSHIP_RETRY_DELAY)
		end
		if player.Parent ~= Players then
			return false
		end
	end
	return false
end

-- Liga um pass para o jogador e avisa todo mundo que precisa saber.
local function grantPass(player, key, announce)
	local passes = owned[player]
	if not passes or passes[key] then
		return
	end
	passes[key] = true
	sendState(player)
	invalidateStats(player)
	if announce then
		StateService.Notify(player, "Obrigado! Vantagem ativada: " .. PASS_NAMES[key], "success", 6)
	end
end

local function onPlayerAdded(player)
	if owned[player] then
		return
	end
	owned[player] = emptyPasses()
	sendState(player)

	-- Confere cada pass configurado (chamada web: pode demorar).
	for _, key in ipairs(PASS_KEYS) do
		local passId = getPassId(key)
		if passId and checkOwnership(player, passId) then
			if player.Parent ~= Players or not owned[player] then
				return -- saiu enquanto conferíamos
			end
			grantPass(player, key, false)
		end
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- true se o jogador tem o pass "key" ("DoubleCoins", "AutoCollect" ou "ExtraTurret").
function MonetizationService.HasPass(player, key)
	local passes = owned[player]
	return passes ~= nil and passes[key] == true
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function MonetizationService.Init()
	-- Request "BuyGamepass"(key): abre a janela de compra do Roblox.
	Net.Handle("BuyGamepass", function(player, key)
		if type(key) ~= "string" or PASS_NAMES[key] == nil then
			return false, "Vantagem desconhecida."
		end
		if type(GameConfig.Gamepasses) ~= "table" or GameConfig.Gamepasses.Enabled ~= true then
			return false, "A loja de vantagens está desativada."
		end
		local passId = getPassId(key)
		if not passId then
			return false, "Esta vantagem ainda não está à venda."
		end
		if MonetizationService.HasPass(player, key) then
			return false, "Você já tem esta vantagem."
		end

		local ok, err = pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, passId)
		end)
		if not ok then
			warn("[MonetizationService] Falha ao abrir a compra: " .. tostring(err))
			return false, "Não foi possível abrir a compra agora."
		end
		return true, true
	end, { Rate = 1, Burst = 3 })

	-- Compra feita dentro do jogo: ativa na hora.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
		if not wasPurchased or typeof(player) ~= "Instance" or not player:IsA("Player") then
			return
		end
		local key = getKeyFromId(passId)
		if key then
			grantPass(player, key, true)
		end
	end)
end

function MonetizationService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		owned[player] = nil
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end
end

return MonetizationService
