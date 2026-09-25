--!nonstrict
-- AchievementService: conquistas salvas no perfil (seção 8.13 da especificação).
-- Roda no lobby e na partida.
--
-- Dois tipos de conquista (Config/Achievements):
--   * Stat + Threshold: quando uma estatística do perfil chega no valor.
--     Checada sempre que uma estatística muda (DataService.StatChanged) e também quando
--     o perfil carrega (DataService.ProfileLoaded), para dar conquistas "atrasadas"
--     (ex.: uma conquista nova adicionada depois que o jogador já tinha o número).
--   * Event: quando outro serviço chama AchievementService.FireEvent(player, evento, dados):
--       "CompleteMap"     data.Map   = mapa concluído (tem que bater com o Map da conquista)
--       "PlayWithFriends" data.Count = nº de amigos na partida (>= Count da conquista)
--
-- AchievementService.Award(player, id): se o jogador ainda não tem a conquista, grava a data
-- (os.time()), soma os Tokens, dá a badge do Roblox (se BadgeId > 0), mostra um aviso "rare"
-- e manda o perfil atualizado para o cliente.

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Módulos compartilhados.
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local Achievements = require(ConfigFolder:WaitForChild("Achievements"))
local NumberFormat = require(UtilFolder:WaitForChild("NumberFormat"))

-- Serviços-folha (podem ser usados no topo, regra 1.2).
local Services = script.Parent
local DataService = require(Services:WaitForChild("DataService"))
local StateService = require(Services:WaitForChild("StateService"))

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------
local NOTIFY_DURATION = 6 -- segundos que o aviso de conquista fica na tela
local BADGE_ATTEMPTS = 3 -- tentativas de dar a badge (chamada web pode falhar)
local BADGE_RETRY_DELAY = 2 -- segundos entre as tentativas

-------------------------------------------------------------------------------
-- Estado do módulo
-------------------------------------------------------------------------------
local AchievementService = {}

-- Índices montados uma vez só, para achar as conquistas rapidinho:
local byStat = {} -- [caminho do stat] = {conquista}
local byEvent = {} -- [nome do evento] = {conquista}

for _, def in ipairs(Achievements.List) do
	if type(def.Stat) == "string" and def.Stat ~= "" then
		byStat[def.Stat] = byStat[def.Stat] or {}
		table.insert(byStat[def.Stat], def)
	end
	if type(def.Event) == "string" and def.Event ~= "" then
		byEvent[def.Event] = byEvent[def.Event] or {}
		table.insert(byEvent[def.Event], def)
	end
end

local initialized = false

-------------------------------------------------------------------------------
-- Pequenos ajudantes
-------------------------------------------------------------------------------

-- Número "de verdade": nem NaN, nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Confere se é um Player que ainda está no servidor.
local function isPlayerInGame(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Lê um valor de profile.Stats por um caminho com ponto ("Kills.Low" = Stats.Kills.Low).
local function readStat(stats, path)
	local node = stats
	for _, part in ipairs(string.split(path, ".")) do
		if type(node) ~= "table" then
			return nil
		end
		node = node[part]
	end
	return node
end

-- O jogador já tem essa conquista?
local function hasAchievement(profile, id)
	return type(profile.Achievements) == "table" and profile.Achievements[id] ~= nil
end

-- Id de badge válido (> 0) ou nil.
local function getBadgeId(def)
	local badgeId = tonumber(def.BadgeId)
	if badgeId and isFiniteNumber(badgeId) and badgeId > 0 then
		return math.floor(badgeId)
	end
	return nil
end

-- Dá a badge do Roblox (numa thread separada: é uma chamada web que pode demorar ou falhar).
local function awardBadgeAsync(player, badgeId)
	task.spawn(function()
		for attempt = 1, BADGE_ATTEMPTS do
			if not isPlayerInGame(player) then
				return -- a badge precisa que o jogador esteja no servidor
			end
			local ok, result = pcall(function()
				return BadgeService:AwardBadgeAsync(player.UserId, badgeId) -- versão Async (AwardBadge foi descontinuada)
			end)
			if ok then
				return -- deu certo (ou o jogador já tinha a badge)
			end
			warn(("[AchievementService] Falha ao dar a badge %d (tentativa %d/%d): %s"):format(
				badgeId,
				attempt,
				BADGE_ATTEMPTS,
				tostring(result)
			))
			if attempt < BADGE_ATTEMPTS then
				task.wait(BADGE_RETRY_DELAY)
			end
		end
	end)
end

-- Badges "atrasadas": conquistas que o jogador já tem, mas cuja badge foi criada depois
-- (o dono preencheu o BadgeId mais tarde). Confere e dá a badge que falta.
local function syncOwnedBadgesAsync(player, profile)
	task.spawn(function()
		for _, def in ipairs(Achievements.List) do
			local badgeId = getBadgeId(def)
			if badgeId and hasAchievement(profile, def.Id) then
				if not isPlayerInGame(player) then
					return
				end
				local ok, owns = pcall(function()
					return BadgeService:UserHasBadgeAsync(player.UserId, badgeId)
				end)
				if ok and owns == false then
					awardBadgeAsync(player, badgeId)
				end
			end
		end
	end)
end

-- Uma conquista de evento aceita estes dados? (Map e Count só são conferidos se a conquista tiver.)
local function eventMatches(def, data)
	if def.Map ~= nil and data.Map ~= def.Map then
		return false
	end
	if def.Count ~= nil then
		local count = tonumber(data.Count)
		if not count or not isFiniteNumber(count) or count < (tonumber(def.Count) or 0) then
			return false
		end
	end
	return true
end

-- Confere todas as conquistas de Stat do perfil (usado quando o perfil carrega).
local function checkAllStats(player, profile)
	if type(profile) ~= "table" or type(profile.Stats) ~= "table" then
		return
	end
	for path, defs in pairs(byStat) do
		local value = readStat(profile.Stats, path)
		if isFiniteNumber(value) then
			for _, def in ipairs(defs) do
				if value >= (tonumber(def.Threshold) or math.huge) then
					AchievementService.Award(player, def.Id)
				end
			end
		end
	end
end

-- Conquistas de "concluir mapa" que já estão no perfil (CompletedMaps), para quem
-- completou antes da conquista existir.
local function checkCompletedMaps(player, profile)
	local completed = profile.CompletedMaps
	if type(completed) ~= "table" then
		return
	end
	for _, def in ipairs(byEvent.CompleteMap or {}) do
		if type(def.Map) == "string" and completed[def.Map] == true then
			AchievementService.Award(player, def.Id)
		end
	end
end

-- Perfil carregou: checagem retroativa + badges atrasadas.
local function onProfileLoaded(player, profile)
	if not isPlayerInGame(player) or type(profile) ~= "table" then
		return
	end
	checkAllStats(player, profile)
	checkCompletedMaps(player, profile)
	syncOwnedBadgesAsync(player, profile)
end

-- Uma estatística mudou: só olha as conquistas daquele caminho.
local function onStatChanged(player, path, newValue)
	local defs = byStat[path]
	if not defs or not isFiniteNumber(newValue) then
		return
	end
	for _, def in ipairs(defs) do
		if newValue >= (tonumber(def.Threshold) or math.huge) then
			AchievementService.Award(player, def.Id)
		end
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- AchievementService.Award(player, id) -> true se deu agora, false se já tinha / não deu.
-- Tudo que mexe no perfil acontece sem esperar nada (a badge vai numa thread separada),
-- então funciona mesmo se o jogador for teleportado logo em seguida.
function AchievementService.Award(player, id)
	if not isPlayerInGame(player) or type(id) ~= "string" then
		return false
	end
	local def = Achievements.ById[id]
	if not def then
		warn("[AchievementService] Conquista desconhecida: " .. tostring(id))
		return false
	end
	local profile = DataService.GetProfile(player)
	if not profile then
		return false
	end
	if type(profile.Achievements) ~= "table" then
		profile.Achievements = {}
	end
	if profile.Achievements[id] ~= nil then
		return false -- já tinha
	end

	-- Grava a data e dá os tokens.
	profile.Achievements[id] = os.time()
	local tokens = tonumber(def.Tokens) or 0
	if not isFiniteNumber(tokens) or tokens < 0 then
		tokens = 0
	end
	tokens = math.floor(tokens)
	local current = tonumber(profile.Tokens) or 0
	if not isFiniteNumber(current) then
		current = 0
	end
	profile.Tokens = current + tokens

	-- Badge do Roblox (se configurada).
	local badgeId = getBadgeId(def)
	if badgeId then
		awardBadgeAsync(player, badgeId)
	end

	-- Aviso na tela.
	local text = "Conquista desbloqueada: " .. tostring(def.Name or id)
	if tokens > 0 then
		local unit = if tokens == 1 then "token" else "tokens"
		text ..= (" (+%s %s)"):format(NumberFormat.Commas(tokens), unit)
	end
	StateService.Notify(player, text, "rare", NOTIFY_DURATION)

	DataService.SyncProfile(player)
	return true
end

-- AchievementService.FireEvent(player, eventName, data) — dá as conquistas daquele evento
-- cujos requisitos batem com os dados.
function AchievementService.FireEvent(player, eventName, data)
	if not isPlayerInGame(player) or type(eventName) ~= "string" then
		return
	end
	local defs = byEvent[eventName]
	if not defs then
		return
	end
	if type(data) ~= "table" then
		data = {}
	end
	for _, def in ipairs(defs) do
		if eventMatches(def, data) then
			AchievementService.Award(player, def.Id)
		end
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function AchievementService.Init()
	if initialized then
		return
	end
	initialized = true

	DataService.StatChanged:Connect(onStatChanged)
	DataService.ProfileLoaded:Connect(onProfileLoaded)

	-- Perfis que já carregaram antes deste Init (checagem retroativa também para eles).
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = DataService.GetProfile(player)
		if profile then
			task.spawn(onProfileLoaded, player, profile)
		end
	end
end

function AchievementService.Start() end

return AchievementService
