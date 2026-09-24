-- StateController: guarda no cliente uma cópia do estado que o servidor manda.
--
-- O servidor (StateService) envia mudanças pelo RemoteEvent "State" (key, value).
-- Aqui guardamos cada chave numa tabela e avisamos quem estiver interessado.
-- O cliente NUNCA decide o estado do jogo: ele só lê o que o servidor mandou.
--
-- API (seção 3.2 da especificação):
--   StateController.Get(key)                  -> valor atual da chave (ou nil)
--   StateController.OnChanged(key, fn(value)) -> conexão (fn roda quando a chave muda)
--   StateController.Changed                   -> Signal(key, value) para qualquer chave
--   StateController.GetStats()                -> stats calculados da partida (nil no lobby)
--   StateController.StatsChanged              -> Signal(stats)
--   StateController.WaitFor(key, timeout?)    -> espera até a chave existir e devolve o valor
-- Extras (ajudantes usados pelos módulos do cliente):
--   StateController.GetSettings()             -> configurações do jogador com valores padrão
--   StateController.GetKeybind(actionId)      -> Enum.KeyCode da ação (Config.Keybinds)
--   StateController.GetStatExtras()           -> "extras" dos game passes para Formulas.ComputeStats
--
-- IMPORTANTE: as tabelas devolvidas por Get/GetStats são as mesmas guardadas aqui.
-- Leia à vontade, mas não altere (a próxima mensagem do servidor sobrescreve tudo).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = Shared:WaitForChild("Util")
local Config = Shared:WaitForChild("Config")

local Signal = require(Util:WaitForChild("Signal"))
local Net = require(Util:WaitForChild("Net"))
local Formulas = require(Util:WaitForChild("Formulas"))
local Maps = require(Config:WaitForChild("Maps"))
local Keybinds = require(Config:WaitForChild("Keybinds"))

local StateController = {}

-- Dispara (key, value) sempre que qualquer chave muda.
StateController.Changed = Signal.new()
-- Dispara (stats) quando os stats calculados da partida mudam.
StateController.StatsChanged = Signal.new()

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Quantas vezes tentamos pedir o estado completo antes de desistir
-- (o estado ainda chega aos poucos pelo evento "State").
local FULL_STATE_ATTEMPTS = 6

-- Chaves que mudam os stats da partida (quando uma delas muda, recalculamos).
local STATS_KEYS = {
	Match = true,
	PlayerUpgrades = true,
	TeamUpgrades = true,
	Recipes = true,
	Gamepasses = true,
}

-- Configurações padrão (as mesmas do template do perfil, seção 4.2).
-- Usadas enquanto o perfil ainda não chegou ou se faltar algum campo.
local DEFAULT_SETTINGS = {
	Sensitivity = 0.5,
	InvertY = false,
	FOV = 80,
	ToggleSprint = false,
	MusicVolume = 0.5,
	SfxVolume = 0.7,
	DamageNumbers = true,
	Keybinds = {},
}

-------------------------------------------------------------------------------
-- Estado interno
-------------------------------------------------------------------------------

local values = {} -- [key] = valor atual
local keySignals = {} -- [key] = Signal(value) só daquela chave

local initialized = false
local fetching = false -- true enquanto esperamos a resposta do "GetFullState"
local touchedWhileFetching = {} -- chaves que chegaram pelo evento durante o pedido

local statsDirty = true -- true = precisa recalcular os stats
local cachedStats = nil -- último resultado de Formulas.ComputeStats
local statsFirePending = false -- true = já tem um StatsChanged agendado

-------------------------------------------------------------------------------
-- Funções internas
-------------------------------------------------------------------------------

-- Pega (ou cria) o Signal de uma chave específica.
local function getKeySignal(key)
	local signal = keySignals[key]
	if not signal then
		signal = Signal.new()
		keySignals[key] = signal
	end
	return signal
end

-- Devolve a tabela, ou uma tabela vazia se o valor não for tabela.
local function tableOrEmpty(value)
	if type(value) == "table" then
		return value
	end
	return {}
end

-- Calcula os stats da partida a partir das chaves de estado.
-- Sem partida (lobby) ou com mapa desconhecido, devolve nil.
local function computeStats()
	local match = values.Match
	if type(match) ~= "table" then
		return nil
	end

	local mapId = match.MapId
	local mapDef = type(mapId) == "string" and Maps[mapId] or nil
	-- "Order" também é uma chave de Maps, por isso conferimos o campo Act.
	if type(mapDef) ~= "table" or mapDef.Act == nil then
		return nil
	end

	local extras = StateController.GetStatExtras()

	local ok, result = pcall(
		Formulas.ComputeStats,
		mapId,
		tableOrEmpty(values.PlayerUpgrades),
		tableOrEmpty(values.TeamUpgrades),
		tableOrEmpty(values.Recipes),
		extras
	)
	if not ok then
		warn("[StateController] Erro ao calcular os stats:", result)
		return nil
	end
	return result
end

-- Marca os stats como "sujos" e agenda UM aviso StatsChanged.
-- Se várias chaves mudarem no mesmo quadro, o aviso sai uma vez só.
local function markStatsDirty()
	statsDirty = true
	if statsFirePending then
		return
	end
	statsFirePending = true
	task.defer(function()
		statsFirePending = false
		local stats = StateController.GetStats()
		-- No lobby (sem partida) não há stats: não avisamos ninguém.
		if stats then
			StateController.StatsChanged:Fire(stats)
		end
	end)
end

-- Guarda um valor e avisa todo mundo que a chave mudou.
local function setValue(key, value)
	values[key] = value

	if STATS_KEYS[key] then
		markStatsDirty()
	end

	StateController.Changed:Fire(key, value)
	local signal = keySignals[key]
	if signal then
		signal:Fire(value)
	end
end

-- Chamado quando o servidor manda uma chave pelo evento "State".
local function onStateEvent(key, value)
	if type(key) ~= "string" then
		return
	end
	-- Durante o pedido do estado completo, lembramos quais chaves já chegaram
	-- pelo evento: elas são mais novas que a "foto" do estado completo.
	if fetching then
		touchedWhileFetching[key] = true
	end
	setValue(key, value)
end

-- Pede o estado completo ao servidor (com algumas tentativas).
local function fetchFullState()
	for attempt = 1, FULL_STATE_ATTEMPTS do
		local ok, result = Net.Request("GetFullState")
		if ok and type(result) == "table" then
			return result
		end
		warn(
			("[StateController] Não consegui pegar o estado completo (tentativa %d/%d): %s"):format(
				attempt,
				FULL_STATE_ATTEMPTS,
				tostring(result)
			)
		)
		task.wait(math.min(attempt, 3))
	end
	return nil
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Valor atual de uma chave (ou nil se ainda não chegou).
function StateController.Get(key)
	return values[key]
end

-- Conecta fn(value), chamada toda vez que a chave muda. Devolve a conexão
-- (use conexao:Disconnect() para parar). NÃO chama fn na hora com o valor atual:
-- para isso, use StateController.Get(key) logo depois de conectar.
function StateController.OnChanged(key, fn)
	assert(type(fn) == "function", "[StateController] OnChanged precisa de uma função")
	return getKeySignal(key):Connect(fn)
end

-- Stats da partida (Formulas.ComputeStats), com cache.
-- O cache é refeito quando Match, PlayerUpgrades, TeamUpgrades, Recipes ou Gamepasses mudam.
-- No lobby (sem Match) devolve nil.
function StateController.GetStats()
	if statsDirty then
		statsDirty = false
		cachedStats = computeStats()
	end
	return cachedStats
end

-- "extras" dos game passes para o Formulas.ComputeStats, lidos da chave "Gamepasses"
-- (passes deste jogador, igual ao StatService do servidor):
--   DoubleCoins / VIP -> multiplicam as moedas;  DoubleDamage -> dano da arma × 2
-- Devolve uma tabela NOVA a cada chamada. A StallWindow usa isto para mostrar o "depois".
function StateController.GetStatExtras()
	local gamepasses = values.Gamepasses
	local passes = type(gamepasses) == "table" and gamepasses or {}
	return {
		DoubleCoins = passes.DoubleCoins == true,
		VIP = passes.VIP == true,
		DoubleDamage = passes.DoubleDamage == true,
	}
end

-- Espera até a chave ter um valor (não nil) e devolve esse valor.
-- timeout (opcional, em segundos): se passar do tempo, devolve nil.
function StateController.WaitFor(key, timeout)
	local current = values[key]
	if current ~= nil then
		return current
	end

	local thread = coroutine.running()
	local finished = false
	local connection

	connection = getKeySignal(key):Connect(function(value)
		if finished or value == nil then
			return
		end
		finished = true
		connection.Disconnect()
		task.spawn(thread, value)
	end)

	if type(timeout) == "number" and timeout >= 0 then
		task.delay(timeout, function()
			if finished then
				return
			end
			finished = true
			connection.Disconnect()
			task.spawn(thread, nil)
		end)
	end

	return coroutine.yield()
end

-- Configurações do jogador (Profile.Settings) completadas com os valores padrão.
-- Devolve uma tabela NOVA a cada chamada (pode guardar sem medo).
function StateController.GetSettings()
	local merged = table.clone(DEFAULT_SETTINGS)
	merged.Keybinds = {}

	local profile = values.Profile
	local settings = type(profile) == "table" and profile.Settings or nil
	if type(settings) == "table" then
		for name, default in pairs(DEFAULT_SETTINGS) do
			local value = settings[name]
			-- Só aceita valores do mesmo tipo do padrão (protege contra dados estranhos).
			if value ~= nil and type(value) == type(default) then
				merged[name] = value
			end
		end
		if type(settings.Keybinds) == "table" then
			merged.Keybinds = table.clone(settings.Keybinds)
		end
	end
	return merged
end

-- Tecla atual de uma ação de Config.Keybinds (ex.: "Interact" -> Enum.KeyCode.E).
-- Usa a tecla escolhida pelo jogador, se for válida; senão, a padrão.
function StateController.GetKeybind(actionId)
	local action = Keybinds.ById[actionId]
	local default = action and action.Default or nil

	local profile = values.Profile
	local settings = type(profile) == "table" and profile.Settings or nil
	local custom = type(settings) == "table" and type(settings.Keybinds) == "table" and settings.Keybinds[actionId]
		or nil

	if type(custom) == "string" and custom ~= "" then
		-- Enum.KeyCode["NomeErrado"] dá erro, por isso o pcall.
		local ok, keyCode = pcall(function()
			return Enum.KeyCode[custom]
		end)
		if ok and typeof(keyCode) == "EnumItem" then
			return keyCode
		end
	end
	return default
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

-- Init: escuta o evento "State" e depois pede o estado completo ao servidor.
-- (Espera a resposta do servidor, para os outros módulos já acharem o estado pronto.)
function StateController.Init()
	if initialized then
		return
	end
	initialized = true

	-- 1. Primeiro escutamos as mudanças, para não perder nada.
	Net.On("State", onStateEvent)

	-- 2. Depois pedimos a "foto" completa do estado.
	fetching = true
	local fullState = fetchFullState()
	fetching = false

	if fullState then
		for key, value in pairs(fullState) do
			-- Chaves que chegaram pelo evento durante o pedido já estão mais novas.
			if type(key) == "string" and not touchedWhileFetching[key] then
				setValue(key, value)
			end
		end
	else
		warn("[StateController] Seguindo sem o estado completo; ele vai chegando pelo evento State.")
	end
	table.clear(touchedWhileFetching)
end

function StateController.Start() end

-- Deixa as funções do módulo funcionarem com "." e também com ":"
-- (ex.: StateController.Algo(x) e StateController:Algo(x) fazem a mesma coisa).
for name, fn in pairs(StateController) do
	if type(fn) == "function" then
		StateController[name] = function(first, ...)
			if first == StateController then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return StateController
