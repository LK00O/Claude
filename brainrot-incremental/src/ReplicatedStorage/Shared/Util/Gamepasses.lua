-- Gamepasses: a lista dos game passes do jogo e a regra de "está à venda?".
--
-- O servidor (MonetizationService) e o cliente (janela "Vantagens" da partida e aba
-- "Vantagens" da loja do lobby) usam este MESMO módulo. Assim o nome, a descrição e a
-- regra de venda nunca ficam diferentes entre um lado e o outro.
--
-- Os IDs ficam em Config.Game.Gamepasses (o dono cola lá o id de cada pass).
-- Um pass só está "à venda" quando Config.Game.Gamepasses.Enabled = true E o id dele é > 0.
--
-- API:
--   Gamepasses.List                 passes na ordem da loja: {Key, Name, Description, BuffText, Color}
--   Gamepasses.ByKey[key]           o mesmo item, achado pela chave ("DoubleCoins", "VIP"...)
--   Gamepasses.IsValidKey(key)      true se a chave existe na lista (lista fechada de passes)
--   Gamepasses.GetId(key)           id do pass se ele está à venda; nil se não está
--   Gamepasses.IsForSale(key)       true se o pass está ligado AQUI (Enabled e id > 0); se ele está
--                                   à venda no Roblox quem diz é o FetchSaleInfo
--   Gamepasses.AnyForSale()         true se pelo menos um pass está à venda
--   Gamepasses.KeyFromId(passId)    chave do pass que tem esse id (ou nil)
--   Gamepasses.VipCoinMult()        multiplicador de moedas do VIP (Config.Game.GamepassVipCoinMult)
--   Gamepasses.DAMAGE_MULT          multiplicador do dano da arma do Dano em Dobro (2)
--   Gamepasses.FetchSaleInfo(key, maxAge?) -> {IsForSale, Price} ou nil
--                                   pergunta ao Roblox se o pass está à venda e o preço (PODE ESPERAR)
--
-- Preços: NUNCA ficam no código. O preço é o que o dono escolhe no Creator Hub; as lojas
-- leem com FetchSaleInfo (MarketplaceService:GetProductInfoAsync).

local MarketplaceService = game:GetService("MarketplaceService")

local Config = script.Parent.Parent:WaitForChild("Config")
local GameConfig = require(Config:WaitForChild("Game"))
local NumberFormat = require(script.Parent:WaitForChild("NumberFormat"))

local Gamepasses = {}

-------------------------------------------------------------------------------
-- Valores do Config (com proteção contra valores errados)
-------------------------------------------------------------------------------

-- Número "de verdade" (nem NaN nem infinito).
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Multiplicador de moedas do pass VIP (1.25 = +25%). Valor errado no Config = sem bônus.
function Gamepasses.VipCoinMult()
	local mult = GameConfig.GamepassVipCoinMult
	if isFiniteNumber(mult) and mult > 0 then
		return mult
	end
	return 1
end

-- Dano em Dobro: o dano da arma do dono é multiplicado por isto (o nome do pass diz "dobro").
Gamepasses.DAMAGE_MULT = 2

-------------------------------------------------------------------------------
-- A lista (ordem = ordem em que aparecem nas lojas)
-------------------------------------------------------------------------------

-- Textos que usam os números do Config (se o dono mudar o número, o texto acompanha).
local vipPercent = NumberFormat.Percent(Gamepasses.VipCoinMult() - 1)
local vipWithDoubleText = NumberFormat.Stat(2 * Gamepasses.VipCoinMult(), "multiplier")

-- Cada pass:
--   Key          mesma chave de Config.Game.Gamepasses e do estado "Gamepasses"
--   Name         nome mostrado ao jogador
--   Description  o que o pass faz (texto das lojas)
--   BuffText     linha curta no painel de bônus do HUD quando está valendo
--   Color        cor de destaque do cartão na loja
Gamepasses.List = {
	{
		Key = "DoubleCoins",
		Name = "Moedas em Dobro",
		Description = "Toda moeda que você ganha vale o dobro: brainrots, torretas e missões.",
		BuffText = "Passe: moedas ×2",
		Color = Color3.fromRGB(255, 206, 58),
	},
	{
		Key = "AutoCollect",
		Name = "Coleta Automática",
		Description = "Ímã de moedas desde o começo: as moedas perto de você vêm sozinhas.",
		BuffText = "Passe: ímã de moedas",
		Color = Color3.fromRGB(70, 172, 255),
	},
	{
		Key = "ExtraTurret",
		Name = "Torreta Extra",
		Description = "+1 torreta no seu limite (nos mapas com torretas).",
		BuffText = "Passe: +1 torreta",
		Color = Color3.fromRGB(255, 150, 60),
	},
	{
		Key = "VIP",
		Name = "VIP",
		Description = ("+%s em todas as moedas que você ganha (junto com o Moedas em Dobro fica %s), etiqueta dourada de VIP em cima da cabeça e [VIP] no chat."):format(
			vipPercent,
			vipWithDoubleText
		),
		BuffText = "Passe VIP: moedas +" .. vipPercent,
		Color = Color3.fromRGB(255, 214, 64),
	},
	{
		Key = "DoubleDamage",
		Name = "Dano em Dobro",
		Description = "Sua arma causa o dobro de dano em todos os mapas. Vale só para a sua arma: as torretas continuam iguais.",
		BuffText = "Passe: dano da arma ×2",
		Color = Color3.fromRGB(255, 104, 96),
	},
}

-- Índice por chave: Gamepasses.ByKey.VIP -> item do VIP.
Gamepasses.ByKey = {}
for _, pass in ipairs(Gamepasses.List) do
	Gamepasses.ByKey[pass.Key] = pass
end

-------------------------------------------------------------------------------
-- Regras
-------------------------------------------------------------------------------

-- true se "key" é um dos passes da lista (qualquer outro texto é recusado).
function Gamepasses.IsValidKey(key)
	return type(key) == "string" and Gamepasses.ByKey[key] ~= nil
end

-- true se a loja de passes está ligada no Config.
local function isEnabled()
	local config = GameConfig.Gamepasses
	return type(config) == "table" and config.Enabled == true
end

-- Id do pass "key" se ele está à venda; nil se os passes estão desligados,
-- a chave não existe ou o id ainda não foi preenchido (0).
function Gamepasses.GetId(key)
	if not isEnabled() or not Gamepasses.IsValidKey(key) then
		return nil
	end
	local id = GameConfig.Gamepasses[key]
	if isFiniteNumber(id) and id > 0 then
		return id
	end
	return nil
end

-- true se o pass "key" pode ser comprado agora.
function Gamepasses.IsForSale(key)
	return Gamepasses.GetId(key) ~= nil
end

-- true se pelo menos um pass está à venda (se nenhum está, as lojas nem mostram a seção).
function Gamepasses.AnyForSale()
	for _, pass in ipairs(Gamepasses.List) do
		if Gamepasses.IsForSale(pass.Key) then
			return true
		end
	end
	return false
end

-- Descobre a chave ("DoubleCoins"...) a partir do id do pass (nil se nenhum pass tem esse id).
function Gamepasses.KeyFromId(passId)
	if not isFiniteNumber(passId) then
		return nil
	end
	for _, pass in ipairs(Gamepasses.List) do
		if Gamepasses.GetId(pass.Key) == passId then
			return pass.Key
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Preço e "está à venda no Roblox?" (chamada web)
-------------------------------------------------------------------------------

-- [passId] = {Info = {IsForSale, Price}, Time = os.clock() de quando chegou}
local saleInfoCache = {}

-- Gamepasses.FetchSaleInfo(key, maxAge?) -> info ou nil
--   Pergunta ao Roblox (MarketplaceService:GetProductInfoAsync) como o pass está no
--   Creator Hub: info = {IsForSale = boolean, Price = Robux (número) ou nil}.
--   * PODE ESPERAR (chamada web): no cliente, chame dentro de task.spawn.
--   * nil = o pass não está configurado aqui (GetId) ou a chamada falhou. Falha não
--     fica guardada: a próxima chamada tenta de novo.
--   * O resultado fica guardado por id: por "maxAge" segundos, ou a sessão toda sem maxAge.
--   * No cliente o Price já é o preço para ESTE jogador (o Roblox pode ter preço regional).
--   A tabela devolvida é do cache: só leia, não altere.
function Gamepasses.FetchSaleInfo(key, maxAge)
	local passId = Gamepasses.GetId(key)
	if not passId then
		return nil
	end
	local cached = saleInfoCache[passId]
	if cached and (maxAge == nil or os.clock() - cached.Time < maxAge) then
		return cached.Info
	end

	local ok, result = pcall(function()
		return MarketplaceService:GetProductInfoAsync(passId, Enum.InfoType.GamePass)
	end)
	if not ok or type(result) ~= "table" then
		warn(("[Gamepasses] Não deu para ler o preço do pass %s (%s): %s"):format(key, tostring(passId), tostring(result)))
		return nil
	end

	local price = result.PriceInRobux
	local info = {
		IsForSale = result.IsForSale == true,
		Price = if isFiniteNumber(price) and price >= 0 then price else nil,
	}
	saleInfoCache[passId] = { Info = info, Time = os.clock() }
	return info
end

return Gamepasses
