-- MusicController: toca a música de fundo de cada lugar (em loop) e o "fundo" de
-- ambiente (vento, pássaros, multidão...), também em loop.
--
-- Lobby -> vaga "Music_Lobby"; na partida -> "Music_<MapId>" (ex.: Music_Meadow).
-- O som de cada vaga vem do UIKit.ResolveSound (seção 4.4 da especificação):
--   Config.Game.Music[<chave>] > 0 = id fixo; -1 = sem música; 0 = automático
--   (Config.Audio.Pinned, depois o que a busca do servidor achou, senão silêncio).
-- O volume segue Settings.MusicVolume / Settings.AmbientVolume pelos grupos de som do
-- UIKit (UIKit.GetSoundGroup("Music") e ("Ambient")), que mudam na hora quando o
-- jogador mexe nas Configurações.
-- As trocas são suaves (uma some enquanto a outra aparece).
--
-- API (seção 10.3 da especificação):
--   MusicController.Play(key)   -> toca a música da chave: "Ending" ou "Music_Ending".
--                                  Play(nil) volta para a música normal do lugar.
--   MusicController.Stop()      -> silêncio na música até o próximo Play (o fundo continua).
--   MusicController.PlayAmbient(key) -> troca o fundo de ambiente em loop: "Lobby" ou
--                                  "Amb_Lobby". PlayAmbient(nil) desliga o fundo.
--   MusicController.Duck(amount, duration, target?) -> abaixa a música por um tempo.
--        amount de 0 a 1 (0.3 = 30% mais baixo); duration em segundos.
--        Vários ao mesmo tempo se acumulam (multiplicam) e, no fim, o volume volta
--        devagar ao normal. target: "Music" (padrão), "Ambient" (só o fundo) ou "All".
--        Devolve uma função que encerra esse abaixamento antes da hora.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Controllers = script.Parent
local StateController = require(Controllers:WaitForChild("StateController"))
local UIKit = require(Controllers.Parent:WaitForChild("UI"):WaitForChild("UIKit"))

local MusicController = {}

-------------------------------------------------------------------------------
-- Constantes e estado
-------------------------------------------------------------------------------

local MUSIC_PREFIX = "Music_"
local AMBIENT_PREFIX = "Amb_"

local FADE_IN_TIME = 1.5 -- música nova aparecendo
local FADE_OUT_TIME = 1.2 -- música velha sumindo
local AMBIENT_FADE_IN_TIME = 2.5 -- fundo de ambiente aparece mais devagar
local AMBIENT_FADE_OUT_TIME = 2
local VOLUME_CHANGE_TIME = 0.25 -- ajuste de volume da mesma música (Config mudou)

local DUCK_ATTACK_TIME = 0.15 -- tempo para abaixar
local DUCK_RELEASE_TIME = 0.8 -- tempo para voltar ao normal
local DUCK_MAX_DURATION = 3600 -- um abaixamento dura no máximo 1 hora
local DUCK_EPSILON = 0.02 -- folga (s) para considerar um abaixamento terminado

-- Espera um pouco antes de reler a biblioteca de áudio (os atributos chegam em lote).
local LIBRARY_REFRESH_DELAY = 0.5

-- Os dois "canais" em loop. Cada um tem:
--   Group     = grupo de som do UIKit onde os Sounds ficam
--   DuckGroup = SoundGroup filho que faz o abaixamento (Duck) sem brigar com as trocas
--   Loop      = {Key, SoundId, Sound, Volume} do que está tocando agora (ou nil)
local channels = {
	Music = {
		Name = "Music",
		Group = "Music",
		FadeIn = FADE_IN_TIME,
		FadeOut = FADE_OUT_TIME,
		DuckGroup = nil,
		Loop = nil,
	},
	Ambient = {
		Name = "Ambient",
		Group = "Ambient",
		FadeIn = AMBIENT_FADE_IN_TIME,
		FadeOut = AMBIENT_FADE_OUT_TIME,
		DuckGroup = nil,
		Loop = nil,
	},
}

local overrideKey = nil -- vaga pedida com Play(key) (nil = música do lugar)
local silenced = false -- true depois de Stop()
local started = false
local ambientKey = nil -- vaga do fundo pedida com PlayAmbient (nil = sem fundo)

-- Abaixamentos ativos: lista de {Amount, Until, Music = bool, Ambient = bool}.
local ducks = {}

-- Biblioteca de áudio que já estamos acompanhando (ReplicatedStorage.AudioLibrary).
local watchedLibrary = nil
local libraryRefreshPending = false

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- "Meadow" -> "Music_Meadow"; "Music_Meadow" fica igual. Sem texto -> nil.
local function toSlotKey(prefix, key)
	if type(key) ~= "string" or key == "" then
		return nil
	end
	if string.sub(key, 1, #prefix) == prefix then
		return key
	end
	return prefix .. key
end

-- Descobre o som de uma vaga ("Music_<X>" ou "Amb_<X>") pelo UIKit.
-- Devolve (soundId ou nil, volume, velocidade). nil = silêncio (mudo ou sem som ainda).
-- Para a música, mantém o sentido do Config.Game.Music (> 0 fixo, 0 automático, -1 mudo).
local function resolveSlot(slotKey)
	if not slotKey then
		return nil, 1, 1
	end
	local ok, soundId, volume, speed = pcall(UIKit.ResolveSound, slotKey)
	if not ok or type(soundId) ~= "string" or soundId == "" then
		return nil, 1, 1
	end
	return soundId, tonumber(volume) or 1, tonumber(speed) or 1
end

-- Qual música tocar "normalmente": a do lobby ou a do mapa da partida.
local function defaultKey()
	if workspace:GetAttribute("Role") == "Match" then
		local match = StateController.Get("Match")
		if type(match) == "table" and type(match.MapId) == "string" then
			return match.MapId
		end
		return nil -- partida ainda sem mapa: espera o estado "Match" chegar
	end
	return "Lobby"
end

-- Um abaixamento ainda está valendo?
local function isDuckActive(duck, now)
	return duck.Until - now > DUCK_EPSILON
end

-- Quanto o canal está abaixado agora (1 = normal, 0 = mudo).
local function duckFactor(channelName)
	local now = os.clock()
	local factor = 1
	for _, duck in ipairs(ducks) do
		if duck[channelName] and isDuckActive(duck, now) then
			factor *= 1 - duck.Amount
		end
	end
	return math.clamp(factor, 0, 1)
end

-- Tira da lista os abaixamentos que já acabaram.
local function pruneDucks()
	local now = os.clock()
	for index = #ducks, 1, -1 do
		if not isDuckActive(ducks[index], now) then
			table.remove(ducks, index)
		end
	end
end

-- SoundGroup do abaixamento de um canal (fica dentro do grupo do UIKit, então o volume
-- das Configurações e o abaixamento se multiplicam). Devolve (grupoDoDuck, grupoDoCanal).
local function getDuckGroup(channel)
	local parentGroup = UIKit.GetSoundGroup(channel.Group)
	local duckGroup = channel.DuckGroup
	if duckGroup and duckGroup.Parent == parentGroup then
		return duckGroup, parentGroup
	end
	if duckGroup then
		duckGroup:Destroy()
	end
	duckGroup = Instance.new("SoundGroup")
	duckGroup.Name = channel.Name .. "Duck"
	duckGroup.Volume = duckFactor(channel.Name)
	duckGroup.Parent = parentGroup
	channel.DuckGroup = duckGroup
	return duckGroup, parentGroup
end

-- Leva o volume de cada canal ao abaixamento certo (rápido para baixo, devagar para cima).
local function applyDucks()
	pruneDucks()
	for name, channel in pairs(channels) do
		local duckGroup = channel.DuckGroup
		if duckGroup and duckGroup.Parent then
			local target = duckFactor(name)
			local currentVolume = duckGroup.Volume
			if math.abs(currentVolume - target) > 0.001 then
				local time = if target < currentVolume then DUCK_ATTACK_TIME else DUCK_RELEASE_TIME
				TweenService:Create(duckGroup, TweenInfo.new(time, Enum.EasingStyle.Quad), { Volume = target }):Play()
			end
		end
	end
end

-- Some com um Sound aos poucos e depois apaga.
local function fadeOutAndDestroy(sound, time)
	if not sound.Parent then
		return
	end
	local tween = TweenService:Create(sound, TweenInfo.new(time, Enum.EasingStyle.Quad), { Volume = 0 })
	tween.Completed:Connect(function()
		sound:Destroy()
	end)
	tween:Play()
end

-- Troca o loop de um canal para a vaga slotKey (nil = silêncio), com transição suave.
local function setLoop(channel, slotKey)
	local soundId, volume, speed = resolveSlot(slotKey)
	local loop = channel.Loop

	-- Já está tocando esse mesmo som: só confere volume e velocidade.
	if loop and soundId and loop.SoundId == soundId and loop.Sound.Parent then
		loop.Key = slotKey
		local sound = loop.Sound
		if math.abs(loop.Volume - volume) > 0.001 then
			loop.Volume = volume
			TweenService:Create(sound, TweenInfo.new(VOLUME_CHANGE_TIME), { Volume = volume }):Play()
		end
		if sound.PlaybackSpeed ~= speed then
			sound.PlaybackSpeed = speed
		end
		if not sound.IsPlaying then
			sound:Play()
		end
		return
	end

	if loop then
		fadeOutAndDestroy(loop.Sound, channel.FadeOut)
		channel.Loop = nil
	end
	if not soundId then
		return
	end

	local duckGroup, parentGroup = getDuckGroup(channel)
	local sound = Instance.new("Sound")
	sound.Name = slotKey
	sound.SoundId = soundId
	sound.Looped = true
	sound.Volume = 0
	sound.PlaybackSpeed = speed
	sound.SoundGroup = duckGroup
	sound.Parent = parentGroup
	sound:Play()
	TweenService:Create(sound, TweenInfo.new(channel.FadeIn, Enum.EasingStyle.Quad), { Volume = volume }):Play()

	channel.Loop = { Key = slotKey, SoundId = soundId, Sound = sound, Volume = volume }
end

-- Qual vaga de música deve tocar agora (nil = silêncio).
local function desiredMusicKey()
	if silenced then
		return nil
	end
	if overrideKey then
		return overrideKey
	end
	return toSlotKey(MUSIC_PREFIX, defaultKey())
end

-- Decide o que deve tocar agora e aplica.
local function refresh()
	if not started then
		return
	end
	setLoop(channels.Music, desiredMusicKey())
end

-- A biblioteca de áudio ganhou/mudou ids: relê as vagas da música e do fundo.
local function scheduleLibraryRefresh()
	if libraryRefreshPending then
		return
	end
	libraryRefreshPending = true
	task.delay(LIBRARY_REFRESH_DELAY, function()
		libraryRefreshPending = false
		refresh()
		if ambientKey then
			setLoop(channels.Ambient, ambientKey)
		end
	end)
end

-- Passa a acompanhar ReplicatedStorage.AudioLibrary (atributos "Slot_<vaga>").
local function watchLibrary(library)
	if watchedLibrary == library then
		return
	end
	watchedLibrary = library
	library.AttributeChanged:Connect(function(attribute)
		if string.sub(attribute, 1, 11) == "Slot_Music_" or string.sub(attribute, 1, 9) == "Slot_Amb_" then
			scheduleLibraryRefresh()
		end
	end)
	scheduleLibraryRefresh()
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Toca a música da chave em loop ("Ending" ou "Music_Ending").
-- Play(nil) volta para a música normal do lugar.
function MusicController.Play(key)
	silenced = false
	overrideKey = toSlotKey(MUSIC_PREFIX, key)
	started = true
	refresh()
end

-- Para a música (até o próximo Play). O fundo de ambiente continua.
function MusicController.Stop()
	silenced = true
	overrideKey = nil
	started = true
	refresh()
end

-- Troca o fundo de ambiente em loop ("Lobby" ou "Amb_Lobby"), com transição suave.
-- PlayAmbient(nil) desliga o fundo.
function MusicController.PlayAmbient(key)
	ambientKey = toSlotKey(AMBIENT_PREFIX, key)
	setLoop(channels.Ambient, ambientKey)
end

-- Abaixa a música (ou o fundo) por um tempo e depois volta devagar.
-- amount: 0 a 1 (0.3 = 30% mais baixo, 1 = mudo). duration: segundos.
-- target: "Music" (padrão), "Ambient" ou "All".
-- Devolve uma função que encerra esse abaixamento antes da hora.
function MusicController.Duck(amount, duration, target)
	amount = tonumber(amount)
	duration = tonumber(duration)
	if not amount or not duration or amount ~= amount or duration ~= duration then
		return function() end
	end
	amount = math.clamp(amount, 0, 1)
	duration = math.min(duration, DUCK_MAX_DURATION)
	if amount <= 0 or duration <= 0 then
		return function() end
	end

	local duck = {
		Amount = amount,
		Until = os.clock() + duration,
		Music = target ~= "Ambient",
		Ambient = target == "Ambient" or target == "All",
	}
	table.insert(ducks, duck)

	-- Garante o grupo de abaixamento mesmo sem nada tocando ainda
	-- (a próxima música já começa abaixada).
	if duck.Music then
		getDuckGroup(channels.Music)
	end
	if duck.Ambient then
		getDuckGroup(channels.Ambient)
	end
	applyDucks()
	task.delay(duration, applyDucks)

	return function()
		if duck.Until > 0 then
			duck.Until = 0
			applyDucks()
		end
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function MusicController.Init() end

function MusicController.Start()
	started = true

	-- Música do lugar muda quando a partida (mapa) muda.
	StateController.OnChanged("Match", function()
		if not overrideKey and not silenced then
			refresh()
		end
	end)

	-- Teste no Studio: o servidor pode virar partida depois de ligar (Role muda).
	workspace:GetAttributeChangedSignal("Role"):Connect(function()
		if not overrideKey and not silenced then
			refresh()
		end
	end)

	-- Ids achados pelo servidor depois do começo (biblioteca de áudio, onda 7).
	local library = ReplicatedStorage:FindFirstChild("AudioLibrary")
	if library then
		watchLibrary(library)
	end
	ReplicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == "AudioLibrary" then
			watchLibrary(child)
		end
	end)

	refresh()
end

-- Deixa as funções do módulo funcionarem com "." e também com ":"
-- (ex.: MusicController.Algo(x) e MusicController:Algo(x) fazem a mesma coisa).
for name, fn in pairs(MusicController) do
	if type(fn) == "function" then
		MusicController[name] = function(first, ...)
			if first == MusicController then
				return fn(...)
			end
			return fn(first, ...)
		end
	end
end

return MusicController
