-- Net: toda a comunicação entre servidor e cliente passa por aqui.
--
-- O servidor cria a pasta ReplicatedStorage.Remotes com todos os RemoteEvents
-- e o RemoteFunction "Request". O cliente só espera eles aparecerem.
--
-- Servidor:
--   Net.Init()                         cria a pasta e os remotes (pode chamar mais de uma vez)
--   Net.OnEvent(name, fn(player, ...)) escuta um evento vindo do cliente
--   Net.Handle(action, fn, opts?)      responde a um Request do cliente (com limite de frequência)
--   Net.FireClient(player, name, ...)  manda um evento para um jogador
--   Net.FireAll(name, ...)             manda para todos
--   Net.FireAllExcept(player, name, ...) manda para todos menos um
-- Cliente:
--   Net.On(name, fn(...)) -> conexão   escuta um evento vindo do servidor
--   Net.Fire(name, ...)                manda um evento para o servidor
--   Net.Request(action, ...) -> ok, result   pede algo ao servidor e espera a resposta

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

-- true no servidor, false no cliente (o mesmo módulo roda nos dois lados).
local IS_SERVER = RunService:IsServer()

-- Nome da pasta e do RemoteFunction.
local FOLDER_NAME = "Remotes"
local REQUEST_NAME = "Request"

-- Lista fechada de RemoteEvents (seção 2.1 da especificação).
local EVENT_NAMES = {
	"State", -- S→C (key, value)
	"Notify", -- S→C (payload)
	"Fire", -- C→S (origin, directions, shotId)
	"HitConfirm", -- S→C (hits)
	"RemoteShot", -- S→C (userId, origin, endpoints, tracerColor)
	"Effect", -- S→C (kind, data)
	"CoinPopup", -- S→C (amount, position)
	"TurretShots", -- S→C (shots)
	"OpenUI", -- S→C (action, arg?)
	"Ending", -- S→C (data)
	"PartyState", -- S→C (state)
	"Announcement", -- S→C ({Text (já filtrado), From (nome de exibição do admin), Duration (s)})
}

-- Mesmo conjunto em forma de dicionário, para checar nomes rapidinho.
local EVENT_SET = {}
for _, name in ipairs(EVENT_NAMES) do
	EVENT_SET[name] = true
end

-- Limite padrão de Request por jogador e por action (token bucket).
local DEFAULT_RATE = 8 -- fichas recarregadas por segundo
local DEFAULT_BURST = 16 -- máximo de fichas guardadas (rajada permitida)

-- Proteção extra contra "flood" de RemoteEvents vindos do cliente (ex.: "Fire").
-- Constante técnica bem folgada: jogador normal nunca chega perto disso.
-- Cada serviço ainda faz a sua própria validação (o CombatService limita pela cadência).
local EVENT_FLOOD_RATE = 120
local EVENT_FLOOD_BURST = 240

-- Nos primeiros segundos do servidor, um Request pode chegar antes do serviço
-- registrar o handler. Nesse período, esperamos um pouco em vez de negar.
local STARTUP_GRACE_SECONDS = 20
local STARTUP_POLL_INTERVAL = 0.2

-- Chave de balde usada para actions que (ainda) não têm handler.
local UNKNOWN_BUCKET_KEY = "\0Unknown"

-- Mensagens mostradas ao jogador (português do Brasil).
local MSG_RATE_LIMIT = "Calma! Muitas ações seguidas."
local MSG_INTERNAL_ERROR = "Erro interno"
local MSG_UNKNOWN_ACTION = "Ação desconhecida"
local MSG_CONNECTION_ERROR = "Erro de conexão"
local MSG_GENERIC_FAIL = "Não foi possível fazer isso agora."

-- Estado interno.
local folder = nil -- a pasta Remotes
local remotes = {} -- [nome] = RemoteEvent
local requestFunction = nil -- o RemoteFunction "Request"
local handlers = {} -- [action] = {Fn, Rate, Burst}  (só servidor)
local buckets = {} -- [player] = {[chave] = {Tokens, Last}}  (só servidor)
local serverStartTime = nil -- quando Net.Init rodou (só servidor)
local warnedNames = {} -- nomes errados já avisados (para não repetir o aviso)

-- Uma "conexão falsa" devolvida quando algo dá errado, para quem chamou poder
-- chamar :Disconnect() sem quebrar.
local function dummyConnection()
	local connection = { Connected = false }
	function connection.Disconnect() end
	return connection
end

-- Avisa uma vez só sobre um nome de remote errado.
local function warnUnknownRemote(name)
	local key = tostring(name)
	if not warnedNames[key] then
		warnedNames[key] = true
		warn("[Net] Remote desconhecido: " .. key .. " (confira a lista na seção 2.1 da especificação)")
	end
end

-- Tempo compartilhado entre servidor e cliente.
local function now()
	return workspace:GetServerTimeNow()
end

-------------------------------------------------------------------------------
-- Token bucket (limite de frequência)
-------------------------------------------------------------------------------
-- Cada jogador tem um "balde" de fichas por action. Cada pedido gasta 1 ficha.
-- As fichas voltam aos poucos (rate por segundo) até o máximo (burst).
-- Sem fichas = pedido recusado.
local function consumeToken(player, key, rate, burst)
	local playerBuckets = buckets[player]
	if not playerBuckets then
		playerBuckets = {}
		buckets[player] = playerBuckets
	end

	local t = now()
	local bucket = playerBuckets[key]
	if not bucket then
		-- Balde novo começa cheio.
		bucket = { Tokens = burst, Last = t }
		playerBuckets[key] = bucket
	else
		-- Recarrega conforme o tempo que passou desde o último pedido.
		local elapsed = math.max(0, t - bucket.Last)
		bucket.Tokens = math.min(burst, bucket.Tokens + elapsed * rate)
		bucket.Last = t
	end

	if bucket.Tokens < 1 then
		return false
	end
	bucket.Tokens -= 1
	return true
end

-------------------------------------------------------------------------------
-- SERVIDOR
-------------------------------------------------------------------------------

-- Pega (ou cria) um filho da pasta Remotes com a classe certa.
local function ensureRemote(className, name)
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing
	end
	if existing then
		-- Tinha algo com o mesmo nome e classe errada: remove para não confundir o cliente.
		existing:Destroy()
	end
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = folder
	return remote
end

-- Recebe todos os Requests dos clientes e manda para o handler certo.
local function dispatchRequest(player, action, ...)
	-- A action precisa ser um texto (o cliente pode mandar qualquer coisa).
	if type(action) ~= "string" then
		return false, MSG_UNKNOWN_ACTION
	end

	local handler = handlers[action]

	-- Limite de frequência: por jogador e por action. Actions sem handler
	-- dividem um único balde, para ninguém encher a memória com nomes inventados.
	local bucketKey = if handler then action else UNKNOWN_BUCKET_KEY
	local rate = if handler then handler.Rate else DEFAULT_RATE
	local burst = if handler then handler.Burst else DEFAULT_BURST
	if not consumeToken(player, bucketKey, rate, burst) then
		return false, MSG_RATE_LIMIT
	end

	-- Logo que o servidor abre, os serviços podem ainda estar registrando handlers.
	if not handler and serverStartTime then
		while not handlers[action] and (now() - serverStartTime) < STARTUP_GRACE_SECONDS do
			task.wait(STARTUP_POLL_INTERVAL)
		end
		handler = handlers[action]
	end

	if not handler then
		return false, MSG_UNKNOWN_ACTION
	end

	-- Roda o handler protegido: se ele der erro, o jogador recebe "Erro interno"
	-- e o erro aparece no Output com o nome da action.
	local results = table.pack(pcall(handler.Fn, player, ...))
	if not results[1] then
		warn(("[Net] Erro no handler da action '%s': %s"):format(action, tostring(results[2])))
		return false, MSG_INTERNAL_ERROR
	end

	local ok = results[2] == true
	local result = results[3]
	-- Em erro, o resultado deve ser uma mensagem; se o handler não mandou nenhuma, usamos uma genérica.
	if not ok and result == nil then
		result = MSG_GENERIC_FAIL
	end
	return ok, result
end

-- Net.Init() — cria ReplicatedStorage.Remotes e todos os remotes. Só no servidor.
-- Pode ser chamado várias vezes: da segunda em diante não faz nada.
function Net.Init()
	if not IS_SERVER then
		warn("[Net] Net.Init() só deve ser chamado no servidor.")
		return
	end
	if folder then
		return
	end

	-- Pasta Remotes (reaproveita se já existir).
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		folder = existing
	else
		if existing then
			existing:Destroy()
		end
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end

	-- Todos os RemoteEvents da lista.
	for _, name in ipairs(EVENT_NAMES) do
		remotes[name] = ensureRemote("RemoteEvent", name)
	end

	-- O RemoteFunction "Request", com um único despachante para todas as actions.
	requestFunction = ensureRemote("RemoteFunction", REQUEST_NAME)
	requestFunction.OnServerInvoke = dispatchRequest

	serverStartTime = now()

	-- Quando o jogador sai, joga fora os baldes dele (libera memória).
	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)
end

-- Garante que estamos no servidor e que os remotes existem.
local function requireServer(functionName)
	if not IS_SERVER then
		error("[Net] " .. functionName .. " só pode ser usado no servidor.", 3)
	end
	Net.Init()
end

-- Pega um RemoteEvent no servidor (ou nil, com aviso, se o nome não existe).
local function getServerRemote(name)
	local remote = remotes[name]
	if not remote then
		warnUnknownRemote(name)
	end
	return remote
end

-- Confere se "player" é um jogador que ainda está no servidor.
local function isPlayerInGame(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Net.OnEvent(name, fn(player, ...)) — escuta um RemoteEvent vindo do cliente.
-- Retorna a conexão. Erros dentro de fn aparecem no Output com o nome do evento.
function Net.OnEvent(name, fn)
	requireServer("Net.OnEvent")
	local remote = getServerRemote(name)
	if not remote then
		return dummyConnection()
	end

	-- Chave do balde anti-flood deste evento (separada das actions de Request).
	local floodKey = "\0Event:" .. name
	return remote.OnServerEvent:Connect(function(player, ...)
		if not consumeToken(player, floodKey, EVENT_FLOOD_RATE, EVENT_FLOOD_BURST) then
			return -- flood: ignora em silêncio
		end
		local ok, err = pcall(fn, player, ...)
		if not ok then
			warn(("[Net] Erro no evento '%s': %s"):format(name, tostring(err)))
		end
	end)
end

-- Net.Handle(action, fn(player, ...) -> (ok, result), opts?) — registra a resposta a um Request.
-- opts = {Rate = pedidos por segundo (padrão 8), Burst = rajada máxima (padrão 16)}
function Net.Handle(action, fn, opts)
	requireServer("Net.Handle")
	assert(type(action) == "string", "[Net] Net.Handle: action precisa ser um texto")
	assert(type(fn) == "function", "[Net] Net.Handle: fn precisa ser uma função")

	if handlers[action] then
		warn("[Net] A action '" .. action .. "' já tinha handler; o novo substitui o antigo.")
	end

	opts = opts or {}
	local rate = tonumber(opts.Rate) or DEFAULT_RATE
	local burst = tonumber(opts.Burst) or DEFAULT_BURST
	handlers[action] = {
		Fn = fn,
		Rate = math.max(0, rate),
		Burst = math.max(1, burst),
	}
end

-- Net.FireClient(player, name, ...) — manda um evento para um jogador.
function Net.FireClient(player, name, ...)
	requireServer("Net.FireClient")
	local remote = getServerRemote(name)
	-- Ignora jogadores que já saíram (FireClient daria erro).
	if remote and isPlayerInGame(player) then
		remote:FireClient(player, ...)
	end
end

-- Net.FireAll(name, ...) — manda um evento para todos os jogadores.
function Net.FireAll(name, ...)
	requireServer("Net.FireAll")
	local remote = getServerRemote(name)
	if remote then
		remote:FireAllClients(...)
	end
end

-- Net.FireAllExcept(player, name, ...) — manda para todos, menos "player".
function Net.FireAllExcept(player, name, ...)
	requireServer("Net.FireAllExcept")
	local remote = getServerRemote(name)
	if not remote then
		return
	end
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			remote:FireClient(other, ...)
		end
	end
end

-------------------------------------------------------------------------------
-- CLIENTE
-------------------------------------------------------------------------------

-- Espera a pasta Remotes (criada pelo servidor) aparecer.
local function getClientFolder()
	if not folder then
		folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	end
	return folder
end

-- Pega um RemoteEvent no cliente, esperando ele replicar (ou nil se o nome não existe).
local function getClientRemote(name)
	if not EVENT_SET[name] then
		warnUnknownRemote(name)
		return nil
	end
	local remote = remotes[name]
	if not remote then
		remote = getClientFolder():WaitForChild(name)
		remotes[name] = remote
	end
	return remote
end

-- Garante que estamos no cliente.
local function requireClient(functionName)
	if IS_SERVER then
		error("[Net] " .. functionName .. " só pode ser usado no cliente.", 3)
	end
end

-- Net.On(name, fn(...)) -> conexão — escuta um evento vindo do servidor.
function Net.On(name, fn)
	requireClient("Net.On")
	local remote = getClientRemote(name)
	if not remote then
		return dummyConnection()
	end
	return remote.OnClientEvent:Connect(fn)
end

-- Net.Fire(name, ...) — manda um evento para o servidor.
function Net.Fire(name, ...)
	requireClient("Net.Fire")
	local remote = getClientRemote(name)
	if remote then
		remote:FireServer(...)
	end
end

-- Net.Request(action, ...) -> ok, result — pede algo ao servidor e espera a resposta.
-- Se a chamada falhar (conexão, servidor), devolve false, "Erro de conexão".
function Net.Request(action, ...)
	requireClient("Net.Request")
	if not requestFunction then
		requestFunction = getClientFolder():WaitForChild(REQUEST_NAME)
	end

	local args = table.pack(...)
	local success, ok, result = pcall(function()
		return requestFunction:InvokeServer(action, table.unpack(args, 1, args.n))
	end)
	if not success or type(ok) ~= "boolean" then
		return false, MSG_CONNECTION_ERROR
	end
	return ok, result
end

return Net
