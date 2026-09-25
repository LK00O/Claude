-- ChatTagController (lobby e partida): coloca etiquetas coloridas antes do nome no chat.
--
-- Etiquetas (só UMA por mensagem, na ordem de prioridade):
--   1. [DONO]  vermelha — admin com o papel "Owner" (o dono do jogo).
--   2. [ADMIN] azul     — os outros admins (papel "Admin").
--   3. [VIP]   dourada  — quem tem o game pass VIP.
-- Admin tem prioridade: um admin que também é VIP mostra só [DONO] ou [ADMIN].
--
-- Como funciona:
--   * O servidor grava atributos no jogador, e atributos de Player são copiados para
--     todos os clientes:
--       - "IsAdmin" (true/false) e "AdminRole" ("Owner" ou "Admin") — AdminService;
--       - "VIP" (true/false) — MonetizationService (game pass VIP).
--   * O chat novo do Roblox (TextChatService) chama TextChatService.OnIncomingMessage
--     para CADA mensagem que vai aparecer na tela deste jogador. Ali a gente confere
--     quem mandou a mensagem e põe a etiqueta antes do nome (PrefixText).
--
-- Não mexe nos comandos de teste do chat (/coins, /wave...): eles são TextChatCommand
-- do DebugService e são tratados antes de virar mensagem. Os comandos de admin (":fly")
-- são lidos pelo servidor.
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

-- Nomes dos atributos que o servidor grava no jogador.
local VIP_ATTRIBUTE = "VIP"
local ADMIN_ATTRIBUTE = "IsAdmin"
local ROLE_ATTRIBUTE = "AdminRole"

-- Texto que vai antes do nome no chat. O chat aceita "rich text": a tag <font color>
-- pinta só a etiqueta, e o nome continua com a cor normal.
local OWNER_PREFIX = '<font color="#FF5A5A">[DONO]</font> '
local ADMIN_PREFIX = '<font color="#4DC3FF">[ADMIN]</font> '
local VIP_PREFIX = '<font color="#FFCD3C">[VIP]</font> '

-------------------------------------------------------------------------------
-- Chat
-------------------------------------------------------------------------------

-- Etiqueta de quem mandou a mensagem (ou nil se não tem nenhuma).
local function getSenderPrefix(message)
	local source = message.TextSource
	if not source then
		return nil -- mensagem do sistema (sem jogador)
	end
	local player = Players:GetPlayerByUserId(source.UserId)
	if not player then
		return nil
	end
	-- Admin primeiro (tem prioridade sobre o VIP).
	if player:GetAttribute(ADMIN_ATTRIBUTE) == true then
		if player:GetAttribute(ROLE_ATTRIBUTE) == "Owner" then
			return OWNER_PREFIX
		end
		return ADMIN_PREFIX
	end
	if player:GetAttribute(VIP_ATTRIBUTE) == true then
		return VIP_PREFIX
	end
	return nil
end

-- Chamada pelo Roblox para cada mensagem que chega (não pode esperar/yield aqui dentro).
-- Devolve as propriedades que mudam na exibição da mensagem.
local function onIncomingMessage(message)
	local properties = Instance.new("TextChatMessageProperties")
	local ok, prefix = pcall(getSenderPrefix, message)
	if ok and prefix then
		-- message.PrefixText é o nome de quem falou (ex.: "Fulano:"); só colocamos a etiqueta antes.
		properties.PrefixText = prefix .. message.PrefixText
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
		warn("[ChatTagController] Não foi possível ligar as etiquetas do chat: " .. tostring(err))
	end
end

function ChatTagController.Start() end

return ChatTagController
