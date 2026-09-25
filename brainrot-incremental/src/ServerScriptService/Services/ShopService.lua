-- ShopService: loja de skins de arma do lobby, paga com Brainrot Tokens.
--
-- Requests (seção 2.5 e 9.3 da especificação):
--   BuyCosmetic(id)   -> true   compra a skin: ela precisa existir, o jogador não pode
--                               já ter e precisa ter Tokens >= Price.
--   EquipCosmetic(id) -> true   equipa uma skin que o jogador já tem.
--
-- O servidor é quem manda: o cliente só pede. Conferimos o tipo e o tamanho do id,
-- se a skin existe em Config.Cosmetics e se o perfil tem saldo, antes de mexer em nada.
-- Depois de qualquer mudança chamamos DataService.SyncProfile para o cliente ver o
-- saldo novo e a skin equipada (chave de estado "Profile").

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticsConfig = require(Shared.Config.Cosmetics)
local Net = require(Shared.Util.Net)
local NumberFormat = require(Shared.Util.NumberFormat)

local DataService = require(script.Parent:WaitForChild("DataService"))

local ShopService = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Tamanho máximo aceito para um id vindo do cliente (proteção contra textos gigantes).
local MAX_ID_LENGTH = 64

-- Limite de frequência dos pedidos da loja (por jogador): 2 por segundo, rajada de 5.
local SHOP_RATE = { Rate = 2, Burst = 5 }

-- Skin padrão, que todo mundo tem (usada para consertar perfis estranhos).
local DEFAULT_SKIN = "Classic"

-- Mensagens mostradas ao jogador (português do Brasil).
local MSG_NO_PROFILE = "Seus dados ainda estão carregando. Tente de novo em instantes."
local MSG_INVALID_SKIN = "Essa skin não existe."
local MSG_ALREADY_OWNED = "Você já tem essa skin."
local MSG_NOT_OWNED = "Você ainda não tem essa skin. Compre na loja primeiro."
local MSG_NOT_ENOUGH = "Tokens insuficientes: faltam %s."

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Número "de verdade": não é NaN nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Confere o id mandado pelo cliente e devolve a definição da skin (ou nil).
local function getSkinDef(id)
	if type(id) ~= "string" or #id == 0 or #id > MAX_ID_LENGTH then
		return nil
	end
	local def = CosmeticsConfig.ById[id]
	if type(def) ~= "table" then
		return nil
	end
	return def
end

-- Garante que profile.Cosmetics tem o formato certo: {Owned = {...}, Equipped = "..."}.
-- Devolve a tabela Cosmetics já consertada.
local function ensureCosmetics(profile)
	if type(profile.Cosmetics) ~= "table" then
		profile.Cosmetics = {}
	end
	local cosmetics = profile.Cosmetics
	if type(cosmetics.Owned) ~= "table" then
		cosmetics.Owned = {}
	end
	-- A skin padrão é de todo mundo.
	cosmetics.Owned[DEFAULT_SKIN] = true
	if type(cosmetics.Equipped) ~= "string" or not CosmeticsConfig.ById[cosmetics.Equipped] then
		cosmetics.Equipped = DEFAULT_SKIN
	end
	return cosmetics
end

-- Saldo de tokens do perfil (conserta valores inválidos para 0).
local function getTokens(profile)
	local tokens = profile.Tokens
	if not isFiniteNumber(tokens) or tokens < 0 then
		tokens = 0
		profile.Tokens = 0
	end
	return tokens
end

-------------------------------------------------------------------------------
-- Handlers dos Requests
-------------------------------------------------------------------------------

-- BuyCosmetic(id): compra a skin se existe, se o jogador não tem e se tem tokens.
local function onBuyCosmetic(player, id)
	local def = getSkinDef(id)
	if not def then
		return false, MSG_INVALID_SKIN
	end

	local profile = DataService.GetProfile(player)
	if not profile then
		return false, MSG_NO_PROFILE
	end

	local cosmetics = ensureCosmetics(profile)
	if cosmetics.Owned[def.Id] then
		return false, MSG_ALREADY_OWNED
	end

	-- Preço: número inteiro >= 0 (um preço inválido no Config vira 0).
	local price = def.Price
	if not isFiniteNumber(price) or price < 0 then
		price = 0
	end

	local tokens = getTokens(profile)
	if tokens < price then
		return false, MSG_NOT_ENOUGH:format(NumberFormat.Commas(price - tokens))
	end

	-- Tudo certo: desconta e adiciona a skin à coleção.
	profile.Tokens = tokens - price
	cosmetics.Owned[def.Id] = true
	DataService.SyncProfile(player)
	return true, true
end

-- EquipCosmetic(id): equipa uma skin que o jogador já tem.
local function onEquipCosmetic(player, id)
	local def = getSkinDef(id)
	if not def then
		return false, MSG_INVALID_SKIN
	end

	local profile = DataService.GetProfile(player)
	if not profile then
		return false, MSG_NO_PROFILE
	end

	local cosmetics = ensureCosmetics(profile)
	if not cosmetics.Owned[def.Id] then
		return false, MSG_NOT_OWNED
	end

	cosmetics.Equipped = def.Id
	DataService.SyncProfile(player)
	return true, true
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

-- Init: registra os Requests da loja.
function ShopService.Init()
	Net.Handle("BuyCosmetic", onBuyCosmetic, SHOP_RATE)
	Net.Handle("EquipCosmetic", onEquipCosmetic, SHOP_RATE)
end

-- Start: nada a fazer (a loja só responde a pedidos).
function ShopService.Start() end

return ShopService
