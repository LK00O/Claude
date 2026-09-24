-- ChatTagController (lobby e partida): coloca a etiqueta dourada [VIP] no chat.
--
-- Como funciona:
--   * O servidor (MonetizationService) grava player:SetAttribute("VIP", true) em quem
--     tem o game pass VIP. Atributos de Player são copiados para todos os clientes.
--   * O chat novo do Roblox (TextChatService) chama TextChatService.OnIncomingMessage
--     para CADA mensagem que vai aparecer na tela deste jogador. Ali a gente confere
--     quem mandou a mensagem e, se for VIP, põe "[VIP]" antes do nome (PrefixText).
--
-- Não mexe nos comandos de teste do chat (/coins, /wave...): eles são TextChatCommand
-- do DebugService e são tratados antes de virar mensagem.
-- No chat antigo (LegacyChatService) o OnIncomingMessage nunca é chamado: nada acontece.
--
-- ATENÇÃO: o OnIncomingMessage é um "callback" (só existe UM por cliente). Se outro
-- script também precisar dele, junte os dois aqui em vez de criar outro.

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local ChatTagController = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Nome do atributo que o servidor grava no jogador VIP.
local VIP_ATTRIBUTE = "VIP"

-- Texto que vai antes do nome no chat. O chat aceita "rich text": a tag <font color>
-- pinta só o [VIP] de dourado, e o nome continua com a cor normal.
local VIP_PREFIX = '<font color="#FFCD3C">[VIP]</font> '

-------------------------------------------------------------------------------
-- Chat
-------------------------------------------------------------------------------

-- true se quem mandou a mensagem é um jogador VIP.
local function isVipSender(message)
	local source = message.TextSource
	if not source then
		return false -- mensagem do sistema (sem jogador)
	end
	local player = Players:GetPlayerByUserId(source.UserId)
	return player ~= nil and player:GetAttribute(VIP_ATTRIBUTE) == true
end

-- Chamada pelo Roblox para cada mensagem que chega (não pode esperar/yield aqui dentro).
-- Devolve as propriedades que mudam na exibição da mensagem.
local function onIncomingMessage(message)
	local properties = Instance.new("TextChatMessageProperties")
	local ok, isVip = pcall(isVipSender, message)
	if ok and isVip then
		-- message.PrefixText é o nome de quem falou (ex.: "Fulano:"); só colocamos o [VIP] antes.
		properties.PrefixText = VIP_PREFIX .. message.PrefixText
	end
	return properties
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function ChatTagController.Init()
	local ok, err = pcall(function()
		TextChatService.OnIncomingMessage = onIncomingMessage
	end)
	if not ok then
		warn("[ChatTagController] Não foi possível ligar a etiqueta [VIP] do chat: " .. tostring(err))
	end
end

function ChatTagController.Start() end

return ChatTagController
