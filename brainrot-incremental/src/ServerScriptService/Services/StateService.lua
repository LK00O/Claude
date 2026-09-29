-- StateService: guarda o "estado replicado" do jogo e manda para os clientes.
--
-- Pense nele como um quadro de avisos:
--   * cada jogador tem os seus próprios valores (ex.: "Coins", "Quest");
--   * existem valores globais que valem para todos (ex.: "Match", "Alive").
-- Quando alguém muda um valor, ele fica marcado como "sujo". Um laço de 10 Hz
-- manda só as chaves sujas para os clientes: uma mensagem State(key, value)
-- por chave, por jogador. Assim, mudar a mesma chave 50 vezes num décimo de
-- segundo gera só UMA mensagem na rede.
--
-- É um serviço-folha: não dá require em nenhum outro serviço.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Util.Net)

local StateService = {}

-- Intervalo do envio das mudanças (constante técnica: 10 Hz = a cada 0,1 s).
local FLUSH_INTERVAL = 0.1

-- Tipos aceitos em Notify (qualquer outro vira "info").
local NOTIFY_KINDS = {
	info = true,
	success = true,
	warning = true,
	error = true,
	rare = true,
}

-- Valores globais: [key] = value (valem para todos, inclusive quem entrar depois).
local globalValues = {}
-- Chaves globais mudadas desde o último envio: [key] = true.
local globalDirty = {}

-- Valores de cada jogador: [player] = {[key] = value}.
local playerValues = {}
-- Chaves de cada jogador mudadas desde o último envio: [player] = {[key] = true}.
local playerDirty = {}

-- Evita iniciar o laço duas vezes se Init for chamado de novo.
local initialized = false

-- true se "player" é um jogador que ainda está no servidor.
local function isActivePlayer(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Garante que a chave é um texto válido (evita erro silencioso de digitação).
local function isValidKey(key)
	return type(key) == "string" and key ~= ""
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- StateService.Set(player, key, value): guarda o valor do jogador e marca como sujo.
function StateService.Set(player, key, value)
	if not isValidKey(key) then
		warn("[StateService] Set com chave inválida: " .. tostring(key))
		return
	end
	-- Jogador que já saiu: ignora (não queremos recriar as tabelas dele).
	if not isActivePlayer(player) then
		return
	end

	local values = playerValues[player]
	if not values then
		values = {}
		playerValues[player] = values
	end
	values[key] = value

	local dirty = playerDirty[player]
	if not dirty then
		dirty = {}
		playerDirty[player] = dirty
	end
	dirty[key] = true
end

-- StateService.SetAll(key, value): guarda como valor global e marca sujo para todos.
function StateService.SetAll(key, value)
	if not isValidKey(key) then
		warn("[StateService] SetAll com chave inválida: " .. tostring(key))
		return
	end
	globalValues[key] = value
	globalDirty[key] = true
end

-- StateService.Get(player, key): valor do jogador; se ele não tiver, o global.
function StateService.Get(player, key)
	local values = playerValues[player]
	if values then
		local value = values[key]
		if value ~= nil then
			return value
		end
	end
	return globalValues[key]
end

-- StateService.GetAll(player): tabela nova com os globais + os do jogador
-- (os do jogador ganham quando a mesma chave existe nos dois).
function StateService.GetAll(player)
	local result = table.clone(globalValues)
	local values = playerValues[player]
	if values then
		for key, value in pairs(values) do
			result[key] = value
		end
	end
	return result
end

-- StateService.Clear(player): apaga tudo do jogador (chamado quando ele sai).
function StateService.Clear(player)
	playerValues[player] = nil
	playerDirty[player] = nil
end

-- Monta o pacote do evento "Notify".
-- Sem "extra", o pacote é exatamente o de sempre: {Text, Kind, Duration}.
-- "extra" (opcional) é uma tabela com campos a mais; hoje só "Achievement" é copiado
-- (o id da conquista, texto de até MAX_ACHIEVEMENT_ID caracteres), para o cliente
-- mostrar o ícone/cartão da conquista. Qualquer outro campo de "extra" é ignorado.
local MAX_ACHIEVEMENT_ID = 64

local function buildNotifyPayload(text, kind, duration, extra)
	local payload = {
		Text = tostring(text),
		Kind = if NOTIFY_KINDS[kind] then kind else "info",
		Duration = if type(duration) == "number" and duration > 0 then duration else nil,
	}
	if type(extra) == "table" then
		local achievement = extra.Achievement
		if type(achievement) == "string" and achievement ~= "" and #achievement <= MAX_ACHIEVEMENT_ID then
			payload.Achievement = achievement
		end
	end
	return payload
end

-- StateService.Notify(player, text, kind?, duration?, extra?): mostra um aviso na tela de um jogador.
-- extra (opcional): {Achievement = id da conquista} (ver buildNotifyPayload).
function StateService.Notify(player, text, kind, duration, extra)
	if not isActivePlayer(player) then
		return
	end
	Net.FireClient(player, "Notify", buildNotifyPayload(text, kind, duration, extra))
end

-- StateService.NotifyAll(text, kind?, duration?, extra?): mostra um aviso para todos os jogadores.
function StateService.NotifyAll(text, kind, duration, extra)
	Net.FireAll("Notify", buildNotifyPayload(text, kind, duration, extra))
end

-------------------------------------------------------------------------------
-- Envio das mudanças (10 Hz)
-------------------------------------------------------------------------------

-- Manda para cada jogador as chaves sujas dele + as globais sujas.
local function flush()
	-- Pega as globais sujas e já limpa a lista (mudanças durante o envio ficam para o próximo ciclo).
	local globalsToSend = globalDirty
	local hasGlobals = next(globalsToSend) ~= nil
	if hasGlobals then
		globalDirty = {}
	end

	for _, player in ipairs(Players:GetPlayers()) do
		local ownDirty = playerDirty[player]
		if ownDirty then
			playerDirty[player] = nil
		end

		if hasGlobals or ownDirty then
			-- Junta as duas listas para não mandar a mesma chave duas vezes.
			local keys = {}
			if hasGlobals then
				for key in pairs(globalsToSend) do
					keys[key] = true
				end
			end
			if ownDirty then
				for key in pairs(ownDirty) do
					keys[key] = true
				end
			end

			for key in pairs(keys) do
				Net.FireClient(player, "State", key, StateService.Get(player, key))
			end
		end
	end

	-- Limpeza de segurança: se sobrou dado de alguém que já saiu, apaga.
	for player in pairs(playerValues) do
		if not isActivePlayer(player) then
			StateService.Clear(player)
		end
	end
	for player in pairs(playerDirty) do
		if not isActivePlayer(player) then
			playerDirty[player] = nil
		end
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function StateService.Init()
	if initialized then
		return
	end
	initialized = true

	-- Request "GetFullState": o cliente pede tudo de uma vez quando abre o jogo.
	Net.Handle("GetFullState", function(player)
		return true, StateService.GetAll(player)
	end, { Rate = 2, Burst = 6 })

	-- Quando o jogador sai, apaga os valores dele.
	Players.PlayerRemoving:Connect(function(player)
		StateService.Clear(player)
	end)

	-- Laço de envio das mudanças.
	task.spawn(function()
		while true do
			task.wait(FLUSH_INTERVAL)
			local ok, err = pcall(flush)
			if not ok then
				warn("[StateService] Erro ao enviar estado: " .. tostring(err))
			end
		end
	end)
end

function StateService.Start() end

return StateService
