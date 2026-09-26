-- Config/Audio: a "biblioteca de áudio" do jogo (seção 4.4 do plano / 5.x da especificação).
--
-- Cada som do jogo tem um nome curto, a "vaga" (slot): "Click", "Coin", "Music_Meadow",
-- "Amb_Winter"... Quem toca um som pede pela vaga (UIKit.PlaySound("Coin")) e o jogo
-- descobre QUAL áudio usar nesta ordem (UIKit.ResolveSound):
--   1. Config/Game: Sounds[vaga] (efeitos) ou Music[mapa] (vagas "Music_<Mapa>"):
--        maior que 0 = id fixo (usa esse áudio), 0 = automático (segue para o passo 2),
--        -1 = mudo (nunca toca).
--   2. Pinned[vaga] aqui embaixo, se for maior que 0 (id "fixado" por você).
--   3. O que o servidor achou sozinho na loja de áudios do Roblox (atributo "Slot_<vaga>"
--      da pasta ReplicatedStorage.AudioLibrary, criada pelo AudioService).
--   4. Fallback: um som que já vem instalado no Roblox (rbxasset://sounds/...), ou silêncio.
--
-- Campos de cada vaga (Slots):
--   Group        grupo de volume: "SFX" (efeitos do mundo), "UI" (interface),
--                "Music" (música) ou "Ambient" (sons de ambiente). Cada grupo segue um
--                volume das Configurações do jogador (SfxVolume, MusicVolume, AmbientVolume).
--   Volume       volume base (0 a 1) quando o áudio vem do id fixo ou da busca automática
--   Speed        velocidade/tom (1 = normal; opcional)
--   Looped       true = toca em loop (ambientes e sons de lugar)
--   Query        palavras (em inglês, como na loja do Roblox) que o servidor usa na busca
--   SubType      "SoundEffect" ou "Music" (os únicos tipos que a busca do Roblox aceita)
--   MinDuration  duração mínima em segundos (opcional; ambientes precisam de 20 s ou mais)
--   MaxDuration  duração máxima em segundos (opcional; efeitos curtinhos)
--   Fallback     {Id, Volume, Speed}: arquivo que já vem no Roblox, usado quando nada
--                mais foi escolhido (opcional; música não tem: silêncio é melhor que
--                uma música errada)
--
-- Para fixar um áudio que você gostou: copie o número dele (Creator Hub ou a linha
-- "Pinned.<vaga> = <id>" que o Studio mostra no Output) para Pinned abaixo.

-- Atalho: arquivos de som que já vêm com o Roblox (existem em todo aparelho).
local BUILTIN = "rbxasset://sounds/"

local Audio = {}

-- Nome do DataStore onde o servidor guarda o que a busca automática achou
-- (assim cada servidor novo não precisa buscar tudo de novo).
Audio.CacheStoreName = "BrainrotIncremental_AudioCache_v1"

-- Segundos entre uma busca e outra (a busca de áudio do Roblox tem limite baixo).
Audio.SearchSpacing = 3

-- Máximo de buscas que um servidor faz na vida dele (o resto fica para o próximo).
Audio.MaxSearchesPerServer = 40

-- Ids fixados por você: Pinned.Coin = 1234567890 faz a vaga "Coin" usar esse áudio
-- (a menos que Config.Game.Sounds.Coin tenha outro id ou -1). Vazio = tudo automático.
Audio.Pinned = {}

-- Ids que NUNCA devem ser usados (ex.: a busca achou um áudio ruim). Lista de números:
-- Audio.Blocked = { 1234567890, 987654321 }
Audio.Blocked = {}

Audio.Slots = {
	---------------------------------------------------------------------------
	-- Efeitos do Config.Game.Sounds (os nomes antigos continuam valendo)
	---------------------------------------------------------------------------
	Shoot = { Group = "SFX", Volume = 0.6, Query = "cartoon gun shot", SubType = "SoundEffect", MaxDuration = 2 },
	Hit = { Group = "SFX", Volume = 0.55, Query = "cartoon hit impact", SubType = "SoundEffect", MaxDuration = 1.5 },
	Crit = { Group = "SFX", Volume = 0.7, Query = "critical hit punch", SubType = "SoundEffect", MaxDuration = 2 },
	Coin = { Group = "SFX", Volume = 0.5, Query = "coin pickup", SubType = "SoundEffect", MaxDuration = 1.5 },
	Death = {
		Group = "SFX",
		Volume = 0.6,
		Query = "cartoon pop",
		SubType = "SoundEffect",
		MaxDuration = 2,
		Fallback = { Id = BUILTIN .. "action_jump_land.mp3", Volume = 0.45, Speed = 1.4 },
	},
	Explosion = {
		Group = "SFX",
		Volume = 0.7,
		Query = "cartoon explosion",
		SubType = "SoundEffect",
		MaxDuration = 3,
		Fallback = { Id = BUILTIN .. "impact_explosion_03.mp3", Volume = 0.55, Speed = 1 },
	},
	Purchase = {
		Group = "UI",
		Volume = 0.6,
		Query = "cash register purchase",
		SubType = "SoundEffect",
		MaxDuration = 2,
	},
	Error = {
		Group = "UI",
		Volume = 0.5,
		Query = "ui error buzz",
		SubType = "SoundEffect",
		MaxDuration = 1.5,
		-- Só se nada melhor existir, e bem baixinho.
		Fallback = { Id = BUILTIN .. "ouch.ogg", Volume = 0.18, Speed = 1.15 },
	},
	Notify = { Group = "UI", Volume = 0.5, Query = "notification ding", SubType = "SoundEffect", MaxDuration = 2 },
	Turret = { Group = "SFX", Volume = 0.5, Query = "laser turret shot", SubType = "SoundEffect", MaxDuration = 1.5 },
	Portal = { Group = "SFX", Volume = 0.7, Query = "magic portal open", SubType = "SoundEffect", MaxDuration = 5 },
	Craft = { Group = "SFX", Volume = 0.6, Query = "magic potion bubble", SubType = "SoundEffect", MaxDuration = 3 },

	---------------------------------------------------------------------------
	-- Interface (suaves e curtinhos, nunca estridentes)
	---------------------------------------------------------------------------
	Click = {
		Group = "UI",
		Volume = 0.35,
		Speed = 1.1,
		Query = "ui click soft",
		SubType = "SoundEffect",
		MaxDuration = 0.6,
		Fallback = { Id = BUILTIN .. "volume_slider.ogg", Volume = 0.35, Speed = 1.1 },
	},
	Hover = {
		Group = "UI",
		Volume = 0.12,
		Query = "ui hover tick",
		SubType = "SoundEffect",
		MaxDuration = 0.4,
		Fallback = { Id = BUILTIN .. "volume_slider.ogg", Volume = 0.1, Speed = 2 },
	},
	Open = { Group = "UI", Volume = 0.35, Query = "ui whoosh open", SubType = "SoundEffect", MaxDuration = 1 },
	Close = { Group = "UI", Volume = 0.3, Query = "ui whoosh close", SubType = "SoundEffect", MaxDuration = 1 },
	Tick = {
		Group = "UI",
		Volume = 0.35,
		Query = "clock tick",
		SubType = "SoundEffect",
		MaxDuration = 0.6,
		Fallback = { Id = BUILTIN .. "volume_slider.ogg", Volume = 0.3, Speed = 1.6 },
	},
	Reward = { Group = "UI", Volume = 0.55, Query = "coin reward chime", SubType = "SoundEffect", MaxDuration = 3 },
	Rare = { Group = "UI", Volume = 0.6, Query = "rare item reveal sting", SubType = "SoundEffect", MaxDuration = 4 },
	Fanfare = { Group = "UI", Volume = 0.7, Query = "victory fanfare", SubType = "SoundEffect", MaxDuration = 8 },

	---------------------------------------------------------------------------
	-- Combate (armas e brainrots)
	---------------------------------------------------------------------------
	Pistol_Fire = { Group = "SFX", Volume = 0.6, Query = "pistol shot", SubType = "SoundEffect", MaxDuration = 1.5 },
	Pistol_Mech = { Group = "SFX", Volume = 0.4, Query = "gun slide click", SubType = "SoundEffect", MaxDuration = 1 },
	Gelato_Fire = {
		Group = "SFX",
		Volume = 0.55,
		Query = "cartoon squirt shot",
		SubType = "SoundEffect",
		MaxDuration = 1.5,
	},
	Gelato_Layer = {
		Group = "SFX",
		Volume = 0.45,
		Query = "ice cream scoop",
		SubType = "SoundEffect",
		MaxDuration = 1.5,
	},
	Minigun_Fire = { Group = "SFX", Volume = 0.5, Query = "minigun shot", SubType = "SoundEffect", MaxDuration = 1 },
	Minigun_Spin = {
		Group = "SFX",
		Volume = 0.4,
		Query = "minigun spin up",
		SubType = "SoundEffect",
		MaxDuration = 4,
	},
	Minigun_Tail = {
		Group = "SFX",
		Volume = 0.45,
		Query = "gunshot tail echo",
		SubType = "SoundEffect",
		MaxDuration = 3,
	},
	Overheat = { Group = "SFX", Volume = 0.5, Query = "steam hiss overheat", SubType = "SoundEffect", MaxDuration = 3 },
	Ready = { Group = "SFX", Volume = 0.45, Query = "weapon ready click", SubType = "SoundEffect", MaxDuration = 1.5 },
	Whoosh = { Group = "SFX", Volume = 0.45, Query = "whoosh swipe", SubType = "SoundEffect", MaxDuration = 1.5 },
	Splat = {
		Group = "SFX",
		Volume = 0.55,
		Query = "slime splat",
		SubType = "SoundEffect",
		MaxDuration = 1.5,
		Fallback = { Id = BUILTIN .. "impact_water.mp3", Volume = 0.4, Speed = 1.25 },
	},
	Tinkle = { Group = "SFX", Volume = 0.45, Query = "magic sparkle tinkle", SubType = "SoundEffect", MaxDuration = 2 },
	Hit_Squish = { Group = "SFX", Volume = 0.5, Query = "squish impact", SubType = "SoundEffect", MaxDuration = 1 },
	Kill_Pop = {
		Group = "SFX",
		Volume = 0.6,
		Query = "cartoon pop burst",
		SubType = "SoundEffect",
		MaxDuration = 1.5,
		Fallback = { Id = BUILTIN .. "action_jump_land.mp3", Volume = 0.45, Speed = 1.4 },
	},
	Casing = {
		Group = "SFX",
		Volume = 0.3,
		Query = "bullet shell casing drop",
		SubType = "SoundEffect",
		MaxDuration = 1.5,
	},

	---------------------------------------------------------------------------
	-- Momentos especiais (seção 3.10)
	---------------------------------------------------------------------------
	Sting = { Group = "UI", Volume = 0.6, Query = "magic reveal sting", SubType = "SoundEffect", MaxDuration = 4 },
	Chime = { Group = "UI", Volume = 0.5, Query = "magic chime", SubType = "SoundEffect", MaxDuration = 3 },

	---------------------------------------------------------------------------
	-- Músicas (vaga "Music_<Mapa>"; Config.Game.Music[<Mapa>] vem primeiro)
	---------------------------------------------------------------------------
	Music_Lobby = {
		Group = "Music",
		Volume = 1,
		Looped = true,
		Query = "upbeat ukulele marimba",
		SubType = "Music",
		MinDuration = 60,
	},
	Music_Meadow = {
		Group = "Music",
		Volume = 1,
		Looped = true,
		Query = "playful pizzicato whistle",
		SubType = "Music",
		MinDuration = 60,
	},
	Music_Winter = {
		Group = "Music",
		Volume = 1,
		Looped = true,
		Query = "calm winter bells celesta",
		SubType = "Music",
		MinDuration = 60,
	},
	Music_Desert = {
		Group = "Music",
		Volume = 1,
		Looped = true,
		Query = "desert adventure hand drums",
		SubType = "Music",
		MinDuration = 60,
	},
	Music_Ending = {
		Group = "Music",
		Volume = 1,
		Looped = true,
		Query = "epic orchestral victory",
		SubType = "Music",
		MinDuration = 45,
	},

	---------------------------------------------------------------------------
	-- Ambientes (um "fundo" em loop por lugar; MusicController.PlayAmbient)
	---------------------------------------------------------------------------
	Amb_Lobby = {
		Group = "Ambient",
		Volume = 0.8,
		Looped = true,
		Query = "park crowd murmur birds ambience",
		SubType = "SoundEffect",
		MinDuration = 20,
	},
	Amb_Meadow = {
		Group = "Ambient",
		Volume = 0.8,
		Looped = true,
		Query = "meadow wind birds ambience",
		SubType = "SoundEffect",
		MinDuration = 20,
	},
	Amb_Winter = {
		Group = "Ambient",
		Volume = 0.8,
		Looped = true,
		Query = "winter wind howl ambience",
		SubType = "SoundEffect",
		MinDuration = 20,
	},
	Amb_Desert = {
		Group = "Ambient",
		Volume = 0.8,
		Looped = true,
		Query = "desert wind ambience",
		SubType = "SoundEffect",
		MinDuration = 20,
	},

	---------------------------------------------------------------------------
	-- Sons de lugar (3D, em loop, perto de fontes, fogueiras... tag AmbientSound)
	---------------------------------------------------------------------------
	Spot_Birds = {
		Group = "Ambient",
		Volume = 0.6,
		Looped = true,
		Query = "birds chirping loop",
		SubType = "SoundEffect",
		MinDuration = 10,
	},
	Spot_Water = {
		Group = "Ambient",
		Volume = 0.6,
		Looped = true,
		Query = "fountain water loop",
		SubType = "SoundEffect",
		MinDuration = 10,
	},
	Spot_Wind = {
		Group = "Ambient",
		Volume = 0.5,
		Looped = true,
		Query = "wind loop",
		SubType = "SoundEffect",
		MinDuration = 10,
	},
	Spot_Fire = {
		Group = "Ambient",
		Volume = 0.6,
		Looped = true,
		Query = "campfire crackle loop",
		SubType = "SoundEffect",
		MinDuration = 10,
	},
	Spot_Crowd = {
		Group = "Ambient",
		Volume = 0.5,
		Looped = true,
		Query = "distant crowd fair ambience",
		SubType = "SoundEffect",
		MinDuration = 10,
	},
}

return Audio
