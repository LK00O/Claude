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
--   StateController.GetStatExtras()           -> "extras" (game passes + evento global) para Formulas.ComputeStats
--   StateController.GetEffectsQuality()       -> 1 (baixa), 2 (média) ou 3 (alta): quanto efeito visual mostrar
--   StateController.QualityChanged            -> Signal(level) quando a qualidade dos efeitos muda
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
-- Dispara (level) quando a qualidade dos efeitos (1, 2 ou 3) muda: o jogador trocou a
-- opção "Qualidade dos efeitos" ou, no modo automático, o gráfico do Roblox.
StateController.QualityChanged = Signal.new()

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
	GlobalEvent = true, -- evento global de admin (moedas, sorte, gigantes)
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
	-- Novas na 2.0 (os módulos que usam cada uma chegam nas próximas etapas):
	CameraShake = 1, -- força do tremor da câmera (0 a 1)
	ViewBob = true, -- balanço da câmera ao andar
	EffectsQuality = 0, -- 0 = automática, 1 = baixa, 2 = média, 3 = alta
	UIScale = 1, -- tamanho da interface (0,85 a 1,25)
	AmbientVolume = 0.6, -- volume dos sons de ambiente (0 a 1)
	AimAssist = true, -- mira assistida (toque e controle)
	AutoFire = true, -- tiro automático no celular
}

-- De quanto em quanto tempo (segundos) conferimos o gráfico escolhido no menu do Roblox
-- (usado quando a qualidade dos efeitos está no automático).
local QUALITY_POLL_INTERVAL = 2

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

local userGameSettings = nil -- UserGameSettings (configurações do Roblox do jogador), pego uma vez
local autoQuality = nil -- qualidade (1-3) calculada do gráfico do Roblox; nil = ainda não lida
local lastQuality = nil -- última qualidade avisada pelo QualityChanged
local qualityWatchStarted = false
local refreshQuality -- função definida mais abaixo (declarada aqui para o setValue poder chamar)

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

	-- O perfil traz a opção "Qualidade dos efeitos": confere se o nível mudou.
	if key == "Profile" then
		refreshQuality()
	end
end

-- Lê o gráfico escolhido no menu do Roblox e converte para a nossa escala 1-3:
--   Automático -> 2 (média);  níveis 1-3 -> 1 (baixa);  4-7 -> 2 (média);  8-10 -> 3 (alta).
-- Tudo dentro de pcall: se o Roblox não deixar ler, ficamos na média.
local function readAutoQuality()
	local ok, level = pcall(function()
		if not userGameSettings then
			userGameSettings = UserSettings():GetService("UserGameSettings")
		end
		return userGameSettings.SavedQualityLevel
	end)
	if not ok or typeof(level) ~= "EnumItem" then
		return 2
	end
	local number = level.Value -- Automatic = 0, QualityLevel1 = 1 ... QualityLevel10 = 10
	if number <= 0 then
		return 2
	elseif number <= 3 then
		return 1
	elseif number <= 7 then
		return 2
	end
	return 3
end

-- Começa a acompanhar o gráfico do Roblox: um evento (quando o Roblox avisa) e uma
-- conferência a cada QUALITY_POLL_INTERVAL segundos (por garantia; ler uma
-- propriedade a cada 2 s não pesa nada).
local function startQualityWatch()
	if qualityWatchStarted then
		return
	end
	qualityWatchStarted = true

	local function recheck()
		autoQuality = readAutoQuality()
		refreshQuality()
	end

	pcall(function()
		if not userGameSettings then
			userGameSettings = UserSettings():GetService("UserGameSettings")
		end
		userGameSettings:GetPropertyChangedSignal("SavedQualityLevel"):Connect(recheck)
	end)

	task.spawn(function()
		while true do
			task.wait(QUALITY_POLL_INTERVAL)
			recheck()
		end
	end)
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
-- O cache é refeito quando Match, PlayerUpgrades, TeamUpgrades, Recipes, Gamepasses ou GlobalEvent mudam.
-- No lobby (sem Match) devolve nil.
function StateController.GetStats()
	if statsDirty then
		statsDirty = false
		cachedStats = computeStats()
	end
	return cachedStats
end

-- "extras" para o Formulas.ComputeStats, iguais aos do StatService do servidor:
--   DoubleCoins / VIP -> multiplicam as moedas;  DoubleDamage -> dano da arma × 2
--   (game passes deste jogador, da chave "Gamepasses");
--   Event -> efeitos do evento global ligado por um admin (chave "GlobalEvent"), para a
--   tela mostrar as moedas, a sorte e a recompensa da missão que o servidor usa de verdade.
-- Devolve uma tabela NOVA a cada chamada. A StallWindow usa isto para mostrar o "depois".
function StateController.GetStatExtras()
	local gamepasses = values.Gamepasses
	local passes = type(gamepasses) == "table" and gamepasses or {}
	local globalEvent = values.GlobalEvent
	local effects = type(globalEvent) == "table" and globalEvent.Effects or nil
	return {
		DoubleCoins = passes.DoubleCoins == true,
		VIP = passes.VIP == true,
		DoubleDamage = passes.DoubleDamage == true,
		Event = if type(effects) == "table" then effects else nil,
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

-- Qualidade dos efeitos visuais que o jogador quer: 1 (baixa), 2 (média) ou 3 (alta).
-- Vem da configuração "EffectsQuality" do perfil (1 a 3). Com 0 (automático, o padrão),
-- segue o gráfico escolhido no menu do Roblox. Barato: pode chamar sempre que for criar
-- um efeito (não cria tabelas).
function StateController.GetEffectsQuality()
	local profile = values.Profile
	local settings = type(profile) == "table" and profile.Settings or nil
	local chosen = type(settings) == "table" and settings.EffectsQuality or nil
	-- Número de verdade (não NaN): arredonda e usa se for 1, 2 ou 3.
	if type(chosen) == "number" and chosen == chosen then
		local rounded = math.floor(chosen + 0.5)
		if rounded >= 1 then
			return math.min(rounded, 3)
		end
	end
	if autoQuality == nil then
		autoQuality = readAutoQuality()
	end
	return autoQuality
end

-- Recalcula a qualidade dos efeitos e dispara QualityChanged se ela mudou.
-- (Uso interno: chamada quando o perfil muda e quando o gráfico do Roblox muda.)
refreshQuality = function()
	local level = StateController.GetEffectsQuality()
	if lastQuality == nil then
		-- Primeira leitura: só guarda (ninguém precisa ser avisado do valor inicial;
		-- quem se importa chama GetEffectsQuality() ao iniciar).
		lastQuality = level
		return
	end
	if level ~= lastQuality then
		lastQuality = level
		StateController.QualityChanged:Fire(level)
	end
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

	-- 3. Qualidade dos efeitos: guarda o nível inicial e passa a acompanhar o gráfico do Roblox.
	refreshQuality()
	startQualityWatch()
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
