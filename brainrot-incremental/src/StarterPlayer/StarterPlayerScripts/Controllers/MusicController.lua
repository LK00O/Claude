-- MusicController: toca a música de fundo de cada lugar, em loop.
--
-- Lobby -> Config.Game.Music.Lobby; na partida -> Config.Game.Music[mapId]
-- (ex.: Music.Meadow). Id 0 = sem música. O volume segue Settings.MusicVolume
-- e muda na hora quando o jogador mexe nas Configurações.
-- A troca de música é suave (uma some enquanto a outra aparece).
--
-- API (seção 10.3 da especificação):
--   MusicController.Play(key)  -> toca Config.Game.Music[key] (ex.: "Ending" no final).
--                                 Play(nil) volta para a música normal do lugar.
-- Extra:
--   MusicController.Stop()     -> silêncio até o próximo Play.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("Config"):WaitForChild("Game"))

local StateController = require(script.Parent:WaitForChild("StateController"))

local MusicController = {}

-------------------------------------------------------------------------------
-- Constantes e estado
-------------------------------------------------------------------------------

local MUSIC_GAIN = 0.8 -- volume máximo da música (com MusicVolume = 1)
local FADE_IN_TIME = 1.5
local FADE_OUT_TIME = 1.2
local VOLUME_CHANGE_TIME = 0.25

local current = nil -- {Key, SoundId, Sound} da música tocando agora
local overrideKey = nil -- chave pedida com Play(key) (nil = música do lugar)
local silenced = false -- true depois de Stop()
local started = false
local appliedVolume = nil -- último volume aplicado (evita animar à toa)

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Converte o id do Config em "rbxassetid://..." (0/vazio = sem música).
local function resolveSoundId(key)
	if type(key) ~= "string" or type(GameConfig.Music) ~= "table" then
		return nil
	end
	local value = GameConfig.Music[key]
	if type(value) == "number" then
		if value > 0 and value == value and value < math.huge then
			return "rbxassetid://" .. string.format("%d", math.floor(value))
		end
		return nil
	elseif type(value) == "string" and value ~= "" then
		if string.match(value, "^%d+$") then
			if tonumber(value) == 0 then
				return nil
			end
			return "rbxassetid://" .. value
		end
		if string.find(value, "://", 1, true) then
			return value
		end
	end
	return nil
end

-- Volume desejado conforme as Configurações do jogador.
local function targetVolume()
	local volume = StateController.GetSettings().MusicVolume
	if type(volume) ~= "number" or volume ~= volume then
		volume = 0.5
	end
	return math.clamp(volume, 0, 1) * MUSIC_GAIN
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

-- Some com uma música aos poucos e depois apaga o Sound.
local function fadeOutAndDestroy(sound)
	local tween = TweenService:Create(sound, TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad), { Volume = 0 })
	tween.Completed:Connect(function()
		sound:Destroy()
	end)
	tween:Play()
end

-- Troca para a música da chave (nil = silêncio), com transição suave.
local function switchTo(key)
	local soundId = resolveSoundId(key)

	-- Já está tocando essa mesma música: nada a fazer.
	if current and current.SoundId == soundId and current.Sound.Parent then
		current.Key = key
		if not current.Sound.IsPlaying then
			current.Sound:Play()
		end
		return
	end

	if current then
		fadeOutAndDestroy(current.Sound)
		current = nil
	end
	if not soundId then
		return
	end

	local sound = Instance.new("Sound")
	sound.Name = "Music_" .. tostring(key)
	sound.SoundId = soundId
	sound.Looped = true
	sound.Volume = 0
	sound.Parent = SoundService
	sound:Play()
	appliedVolume = targetVolume()
	TweenService:Create(sound, TweenInfo.new(FADE_IN_TIME, Enum.EasingStyle.Quad), { Volume = appliedVolume }):Play()

	current = { Key = key, SoundId = soundId, Sound = sound }
end

-- Decide o que deve tocar agora e aplica.
local function refresh()
	if not started then
		return
	end
	if silenced then
		switchTo(nil)
	elseif overrideKey then
		switchTo(overrideKey)
	else
		switchTo(defaultKey())
	end
end

-- O jogador mudou o volume nas Configurações: ajusta a música atual.
-- (O perfil muda muitas vezes por outros motivos; só mexemos se o volume mudou.)
local function applyVolume()
	local target = targetVolume()
	if target == appliedVolume then
		return
	end
	appliedVolume = target
	if current and current.Sound.Parent then
		TweenService:Create(current.Sound, TweenInfo.new(VOLUME_CHANGE_TIME), { Volume = target }):Play()
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Toca Config.Game.Music[key] em loop. Play(nil) volta para a música normal do lugar.
function MusicController.Play(key)
	silenced = false
	if type(key) == "string" and key ~= "" then
		overrideKey = key
	else
		overrideKey = nil
	end
	started = true
	refresh()
end

-- Para a música (até o próximo Play).
function MusicController.Stop()
	silenced = true
	overrideKey = nil
	started = true
	refresh()
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

	-- Volume muda quando as Configurações mudam.
	StateController.OnChanged("Profile", applyVolume)

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
