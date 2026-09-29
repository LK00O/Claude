--!nonstrict
-- MonetizationService: game passes. Roda nos DOIS places (lobby e partida).
--
-- Os passes (nome, descrição e a regra "está à venda?" ficam em Shared/Util/Gamepasses):
--   DoubleCoins  Moedas em Dobro     moedas × 2 (MatchService.AddCoins)
--   AutoCollect  Coleta Automática   ímã de moedas desde o começo (CoinService)
--   ExtraTurret  Torreta Extra       +1 torreta no limite do dono (TurretService)
--   VIP          VIP                 moedas × 1,25 (AddCoins, mesma conta do Moedas em Dobro),
--                                    etiqueta dourada "VIP" em cima da cabeça e [VIP] no chat
--   DoubleDamage Dano em Dobro       dano da arma do dono × 2 (StatService/Formulas; torretas não)
--
-- Todos dão bônus FIXOS (nada de sorte/sorteio pago) e só para o dono.
--
-- O que este serviço faz:
--   * Na entrada, confere quais passes o jogador tem (UserOwnsGamePassAsync). Se a chamada
--     web falhar, tenta de novo algumas vezes na hora e, se o site do Roblox continuar fora
--     do ar, confere mais tarde de novo.
--   * Compra feita dentro do jogo ativa na hora (PromptGamePassPurchaseFinished).
--   * Request "BuyGamepass"(key) abre a janela de compra do Roblox (no lobby e na partida),
--     depois de conferir no Roblox se o pass ainda está à venda (GetProductInfoAsync, guardado
--     por SALE_INFO_MAX_AGE segundos).
--   * Envia a chave de estado "Gamepasses" = {DoubleCoins, AutoCollect, ExtraTurret, VIP, DoubleDamage}
--     (true = o jogador tem o pass).
--   * VIP: player:SetAttribute("VIP", true) (o cliente lê esse atributo para pôr [VIP] no
--     chat) e uma etiqueta BillboardGui na cabeça, recriada a cada vez que o personagem nasce.
--
-- No LOBBY só a compra, o estado "Gamepasses" e o VIP funcionam. O que depende da
-- partida (StatService) simplesmente não faz nada lá.
--
-- API pública:
--   MonetizationService.HasPass(player, key) -> boolean   (StatService, CoinService, TurretService...)
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
local Trove = require(UtilFolder:WaitForChild("Trove"))
local Gamepasses = require(UtilFolder:WaitForChild("Gamepasses"))

-- Serviços-folha (permitidos no topo).
local Services = script.Parent
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções (regra anti-require-circular).
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-------------------------------------------------------------------------------
-- Constantes (técnicas e visuais; os bônus dos passes ficam no Config.Game)
-------------------------------------------------------------------------------

-- Conferir posse: tentativas seguidas na entrada e a espera entre elas (segundos).
local OWNERSHIP_ATTEMPTS = 3
local OWNERSHIP_RETRY_DELAY = 1
-- Se o site do Roblox continuar falhando, confere de novo mais tarde:
-- até 4 rodadas extras, uma a cada 30 s.
local OWNERSHIP_RECHECK_ROUNDS = 4
local OWNERSHIP_RECHECK_DELAY = 30
-- "Está à venda?" (GetProductInfoAsync) fica guardado por este tempo (segundos) antes
-- de perguntar ao Roblox de novo.
local SALE_INFO_MAX_AGE = 60

-- Etiqueta VIP em cima da cabeça.
local VIP_TAG_NAME = "VipTag"
local VIP_TAG_SIZE = UDim2.fromOffset(58, 22) -- em pixels: fica pequena de qualquer distância
local VIP_TAG_OFFSET = Vector3.new(0, 3.2, 0) -- studs acima do centro da cabeça (acima do nome)
local VIP_TAG_MAX_DISTANCE = 80 -- de longe some, para não poluir a tela
local VIP_GOLD = Color3.fromRGB(255, 205, 60)
local VIP_GOLD_DARK = Color3.fromRGB(170, 115, 10)
local VIP_TEXT = Color3.fromRGB(70, 42, 0)
local HEAD_WAIT_TIMEOUT = 10 -- segundos esperando a cabeça do personagem carregar

local MonetizationService = {}

local owned = {} -- [player] = {DoubleCoins = bool, AutoCollect = bool, ExtraTurret = bool, VIP = bool, DoubleDamage = bool}
local playerTroves = {} -- [player] = Trove com as conexões do jogador (CharacterAdded)

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- true se este servidor é uma partida. O Main grava o papel no workspace antes de
-- iniciar qualquer serviço, então aqui ele já existe.
local function isMatch()
	return workspace:GetAttribute("Role") == "Match"
end

-- Tabela nova com todos os passes desligados.
local function emptyPasses()
	local passes = {}
	for _, pass in ipairs(Gamepasses.List) do
		passes[pass.Key] = false
	end
	return passes
end

-- Envia a chave de estado "Gamepasses" do jogador (os passes que ele tem).
local function sendState(player)
	local passes = owned[player]
	if not passes then
		return
	end
	StateService.Set(player, "Gamepasses", table.clone(passes))
end

-- Os stats do jogador dependem dos passes (moedas, dano): pede para recalcular.
-- No lobby não há stats: não faz nada.
local function invalidateStats(player)
	if not isMatch() then
		return
	end
	local ok, err = pcall(function()
		Svc("StatService").Invalidate(player)
	end)
	if not ok then
		warn("[MonetizationService] Erro ao atualizar stats: " .. tostring(err))
	end
end

-------------------------------------------------------------------------------
-- Etiqueta VIP
-------------------------------------------------------------------------------

-- Monta a etiqueta dourada "VIP" (BillboardGui) presa na cabeça.
local function buildVipTag(player, head)
	local gui = Instance.new("BillboardGui")
	gui.Name = VIP_TAG_NAME
	gui.Adornee = head
	gui.Size = VIP_TAG_SIZE
	gui.StudsOffsetWorldSpace = VIP_TAG_OFFSET
	gui.MaxDistance = VIP_TAG_MAX_DISTANCE
	gui.AlwaysOnTop = false -- paredes e árvores escondem a etiqueta normalmente
	gui.LightInfluence = 0 -- mesma cor de dia e de noite
	gui.Active = false -- não pega cliques nem toques
	if isMatch() then
		-- Na partida a câmera é em primeira pessoa: o próprio dono não vê a etiqueta
		-- (senão ela ficaria na frente da mira quando ele olha para cima).
		gui.PlayerToHideFrom = player
	end

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = VIP_GOLD
	label.BorderSizePixel = 0
	label.Text = "VIP"
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = VIP_TEXT
	label.Active = false
	label.Parent = gui

	-- Formato de pílula com borda dourada escura.
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = VIP_GOLD_DARK
	stroke.Thickness = 2
	stroke.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 2)
	padding.PaddingBottom = UDim.new(0, 2)
	padding.Parent = label

	gui.Parent = head
	return gui
end

-- Coloca a etiqueta VIP no personagem (se o jogador tem o VIP). Pode esperar a cabeça
-- carregar, por isso é chamada com task.spawn.
local function attachVipTag(player, character)
	if not character or not MonetizationService.HasPass(player, "VIP") then
		return
	end
	local head = character:FindFirstChild("Head") or character:WaitForChild("Head", HEAD_WAIT_TIMEOUT)
	-- Confere de novo depois da espera: o jogador pode ter saído ou renascido.
	if not head or not head:IsA("BasePart") or player.Character ~= character or player.Parent ~= Players then
		return
	end
	if head:FindFirstChild(VIP_TAG_NAME) then
		return -- já tem (ex.: comprou o VIP no mesmo instante em que renasceu)
	end
	buildVipTag(player, head)
end

-------------------------------------------------------------------------------
-- Ativar passes
-------------------------------------------------------------------------------

-- Liga um pass para o jogador e aplica o efeito dele na hora.
-- announce = true mostra o "Obrigado!" (compra feita agora, dentro do jogo).
local function grantPass(player, key, announce)
	local passes = owned[player]
	if not passes or passes[key] then
		return
	end
	passes[key] = true

	if key == "VIP" then
		-- O atributo replica para todos os clientes: é ele que liga o [VIP] no chat.
		player:SetAttribute("VIP", true)
		task.spawn(attachVipTag, player, player.Character)
	end

	sendState(player)
	invalidateStats(player)

	if announce then
		local name = Gamepasses.ByKey[key].Name
		if isMatch() then
			StateService.Notify(player, "Obrigado! Vantagem ativada: " .. name, "success", 6)
		else
			StateService.Notify(player, "Obrigado! Vantagem ativada: " .. name .. " (vale em todas as partidas).", "success", 6)
		end
	end
end

-- Pergunta ao Roblox se o jogador tem o pass (tenta algumas vezes seguidas).
-- Devolve (tem, conseguiuPerguntar). conseguiuPerguntar = false quando todas as
-- tentativas deram erro na web (aí vale a pena perguntar de novo mais tarde).
local function checkOwnership(player, passId)
	for attempt = 1, OWNERSHIP_ATTEMPTS do
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if ok then
			return result == true, true
		end
		warn(("[MonetizationService] Falha ao conferir o pass %d (tentativa %d): %s"):format(passId, attempt, tostring(result)))
		if player.Parent ~= Players then
			return false, true -- saiu: não precisa perguntar de novo
		end
		if attempt < OWNERSHIP_ATTEMPTS then
			task.wait(OWNERSHIP_RETRY_DELAY)
		end
	end
	return false, false
end

-- Confere uma lista de passes (chaves). Devolve as chaves que NÃO deu para conferir.
local function checkPasses(player, keys)
	local failed = {}
	for _, key in ipairs(keys) do
		local passes = owned[player]
		if not passes or player.Parent ~= Players then
			return {} -- saiu enquanto conferíamos
		end
		local passId = Gamepasses.GetId(key)
		if passId and not passes[key] then
			local has, answered = checkOwnership(player, passId)
			if player.Parent ~= Players or owned[player] == nil then
				return {}
			end
			if has then
				grantPass(player, key, false)
			elseif not answered then
				table.insert(failed, key)
			end
		end
	end
	return failed
end

-- Confere todos os passes à venda. O que falhar por erro na web é conferido de novo
-- depois de OWNERSHIP_RECHECK_DELAY segundos (até OWNERSHIP_RECHECK_ROUNDS vezes).
local function verifyOwnership(player)
	local keys = {}
	for _, pass in ipairs(Gamepasses.List) do
		table.insert(keys, pass.Key)
	end
	local pending = checkPasses(player, keys)

	local round = 0
	while #pending > 0 and round < OWNERSHIP_RECHECK_ROUNDS do
		round += 1
		task.wait(OWNERSHIP_RECHECK_DELAY)
		if player.Parent ~= Players or owned[player] == nil then
			return
		end
		pending = checkPasses(player, pending)
	end
	if #pending > 0 then
		warn(
			("[MonetizationService] Não deu para conferir os passes de %s: %s"):format(
				player.Name,
				table.concat(pending, ", ")
			)
		)
	end
end

-------------------------------------------------------------------------------
-- Entrada e saída de jogadores
-------------------------------------------------------------------------------

local function onPlayerAdded(player)
	if owned[player] then
		return -- já tratado (PlayerAdded + lista inicial)
	end
	owned[player] = emptyPasses()
	local trove = Trove.new()
	playerTroves[player] = trove
	sendState(player)

	-- A cada vez que o personagem nasce, põe a etiqueta VIP de novo (se ele tem o VIP).
	-- Se a cabeça for trocada depois (ex.: a aparência do avatar termina de carregar),
	-- a etiqueta antiga some junto com ela: põe de novo na cabeça nova. Só uma conexão
	-- dessas por jogador: a do personagem anterior é desligada quando ele renasce ou sai.
	local headConnection = nil
	local function disconnectHead()
		if headConnection then
			headConnection:Disconnect()
			headConnection = nil
		end
	end
	trove:Add(disconnectHead)
	trove:Connect(player.CharacterAdded, function(character)
		disconnectHead()
		task.spawn(attachVipTag, player, character)
		headConnection = character.ChildAdded:Connect(function(child)
			if child.Name == "Head" then
				task.spawn(attachVipTag, player, character)
			end
		end)
	end)

	-- Confere cada pass configurado (chamada web: pode demorar).
	verifyOwnership(player)
end

local function onPlayerRemoving(player)
	owned[player] = nil
	local trove = playerTroves[player]
	playerTroves[player] = nil
	if trove then
		trove:Clean()
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- true se o jogador tem o pass "key" ("DoubleCoins", "AutoCollect", "ExtraTurret", "VIP" ou "DoubleDamage").
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
		-- Lista fechada: só as chaves de Shared/Util/Gamepasses são aceitas.
		if not Gamepasses.IsValidKey(key) then
			return false, "Vantagem desconhecida."
		end
		if type(GameConfig.Gamepasses) ~= "table" or GameConfig.Gamepasses.Enabled ~= true then
			return false, "A loja de vantagens está desativada."
		end
		local passId = Gamepasses.GetId(key)
		if not passId then
			return false, "Esta vantagem ainda não está à venda."
		end
		if MonetizationService.HasPass(player, key) then
			return false, "Você já tem esta vantagem."
		end
		-- O dono pode ter tirado o pass de venda no Creator Hub. Se o Roblox não responder
		-- (info = nil), segue: a própria janela de compra do Roblox recusa o que não está à venda.
		local saleInfo = Gamepasses.FetchSaleInfo(key, SALE_INFO_MAX_AGE)
		if saleInfo and not saleInfo.IsForSale then
			return false, "Esta vantagem não está à venda no momento."
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
		local key = Gamepasses.KeyFromId(passId)
		if key then
			grantPass(player, key, true)
		end
	end)
end

function MonetizationService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end
end

return MonetizationService
