--!nonstrict
-- ProgressionService: conclusão do ato e o portal para o próximo mapa.
--
--   ProgressionService.CheckCompletion()
--       Se todas as barracas estão no máximo (UpgradeService.IsActComplete) e isso ainda
--       não foi marcado: marca "Completed" e abre o portal (ou, no Deserto, avisa que o
--       foco agora é o Supremo).
--   Portal (prompt no mapa ou Request "VotePortal"):
--       Config.Game.PortalDecision == "Host"     -> só o dono ativa;
--       Config.Game.PortalDecision == "Majority" -> cada jogador vota; com votos >= metade
--                                                   (arredondada para cima) -> MatchService.CompleteAct().
--       Votos de quem sai do servidor são removidos.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local GameConfig = require(ConfigFolder:WaitForChild("Game"))
local Maps = require(ConfigFolder:WaitForChild("Maps"))
local Brainrots = require(ConfigFolder:WaitForChild("Brainrots"))
local Net = require(UtilFolder:WaitForChild("Net"))
local Trove = require(UtilFolder:WaitForChild("Trove"))

-- Módulo de mundo (permitido no topo).
local MapBuilder = require(ServerScriptService:WaitForChild("World"):WaitForChild("MapBuilder"))

-- Serviços-folha (permitidos no topo).
local Services = script.Parent
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções.
local function Svc(name)
	return require(Services:WaitForChild(name))
end

local ProgressionService = {}

local completed = false -- o ato já foi marcado como concluído
local portalOpen = false -- o portal está aberto
local traveling = false -- a viagem já começou (não aceita mais votos)
local votes = {} -- [userId] = true
local trove = Trove.new() -- conexões do portal

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- "Host" ou "Majority" (qualquer outro valor no Config vira "Majority").
local function getDecision()
	return GameConfig.PortalDecision == "Host" and "Host" or "Majority"
end

-- Jogadores presentes que fazem parte da partida (têm run). "exclude" = jogador saindo.
local function getParticipants(exclude)
	local MatchService = Svc("MatchService")
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= exclude and MatchService.GetRun(player) then
			table.insert(list, player)
		end
	end
	return list
end

-- Quem decide no modo "Host": o dono, se estiver aqui; senão o jogador mais antigo presente.
local function getEffectiveHostUserId(exclude)
	local MatchService = Svc("MatchService")
	local hostUserId = MatchService.GetHostUserId()
	local participants = getParticipants(exclude)
	for _, player in ipairs(participants) do
		if player.UserId == hostUserId then
			return hostUserId
		end
	end
	local first = participants[1]
	return first and first.UserId or nil
end

-- Votos de jogadores que ainda estão aqui.
local function countVotes(exclude)
	local count = 0
	for _, player in ipairs(getParticipants(exclude)) do
		if votes[player.UserId] then
			count += 1
		end
	end
	return count
end

-- Votos necessários: metade dos jogadores (para cima), no mínimo 1. No modo "Host", 1.
local function getNeeded(exclude)
	if getDecision() == "Host" then
		return 1
	end
	return math.max(1, math.ceil(#getParticipants(exclude) / 2))
end

-- Publica a chave global "Portal".
local function publishPortal(exclude)
	local mapDef = Svc("MatchService").GetMapDef()
	StateService.SetAll("Portal", {
		Open = portalOpen,
		Target = (portalOpen and mapDef) and mapDef.Next or nil,
		Votes = countVotes(exclude),
		Needed = getNeeded(exclude),
		Decision = getDecision(),
	})
end

-- Nome bonito do próximo mapa.
local function getNextDisplayName()
	local mapDef = Svc("MatchService").GetMapDef()
	local nextDef = mapDef and mapDef.Next and Maps[mapDef.Next]
	return nextDef and nextDef.DisplayName or "o próximo ato"
end

-- Começa a viagem (MatchService.CompleteAct). Se falhar, reabre a votação.
local function startTravel()
	if traveling then
		return
	end
	traveling = true
	StateService.NotifyAll("O portal está levando o time para " .. getNextDisplayName() .. "!", "success", 6)

	task.spawn(function()
		local okCall, ok, err = pcall(function()
			return Svc("MatchService").CompleteAct()
		end)
		if not okCall then
			warn("[ProgressionService] Erro em CompleteAct: " .. tostring(ok))
		end
		if not okCall or ok == false then
			-- A viagem falhou (o MatchService já avisou o motivo): zera os votos para tentar de novo.
			traveling = false
			table.clear(votes)
			publishPortal()
			if okCall and type(err) == "string" then
				warn("[ProgressionService] Viagem falhou: " .. err)
			end
		end
	end)
end

-- Confere se os votos bastam (modo "Majority").
local function checkVotes(exclude)
	if portalOpen and not traveling and getDecision() == "Majority" then
		local current = countVotes(exclude)
		if current > 0 and current >= getNeeded(exclude) then
			startTravel()
		end
	end
end

-- Alguém ativou o portal (prompt no mapa ou botão do HUD).
-- fromPrompt = true: erros viram aviso na tela (o prompt não tem resposta).
local function activatePortal(player, fromPrompt)
	local function fail(message)
		if fromPrompt then
			StateService.Notify(player, message, "warning")
		end
		return false, message
	end

	if not portalOpen then
		return fail("O portal ainda não está aberto.")
	end
	if traveling then
		return fail("O portal já está levando o time!")
	end
	if not Svc("MatchService").GetRun(player) then
		return fail("Seus dados ainda estão carregando.")
	end

	-- Modo "Host": só o dono (ou quem ficou no lugar dele) decide.
	if getDecision() == "Host" then
		if player.UserId ~= getEffectiveHostUserId() then
			return fail("Só o dono da partida pode ativar o portal.")
		end
		startTravel()
		return true, true
	end

	-- Modo "Majority": registra o voto.
	if not votes[player.UserId] then
		votes[player.UserId] = true
		StateService.NotifyAll(
			("%s votou para entrar no portal (%d/%d)"):format(player.DisplayName, countVotes(), getNeeded()),
			"info"
		)
	end
	publishPortal()
	checkVotes()
	return true, true
end

-- Abre o portal para o próximo mapa.
local function openPortal()
	local MatchService = Svc("MatchService")
	local ctx = MatchService.GetContext()
	local nextName = getNextDisplayName()

	portalOpen = true

	if ctx then
		local ok, prompt = pcall(MapBuilder.OpenPortal, ctx, nextName)
		if ok and typeof(prompt) == "Instance" and prompt:IsA("ProximityPrompt") then
			trove:Connect(prompt.Triggered, function(player)
				activatePortal(player, true)
			end)
		elseif not ok then
			warn("[ProgressionService] Erro ao abrir o portal no mapa: " .. tostring(prompt))
		end

		if typeof(ctx.PortalSpot) == "CFrame" then
			Net.FireAll("Effect", "Portal", { Position = ctx.PortalSpot.Position })
		end
	end

	StateService.NotifyAll("Portal para " .. nextName .. " aberto!", "rare", 8)
	publishPortal()
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Confere se o ato terminou; na primeira vez, marca e abre o portal. Devolve true se concluído.
function ProgressionService.CheckCompletion()
	if completed then
		return true
	end
	local ok, isComplete = pcall(function()
		return Svc("UpgradeService").IsActComplete()
	end)
	if not ok then
		warn("[ProgressionService] Erro ao conferir a conclusão: " .. tostring(isComplete))
		return false
	end
	if not isComplete then
		return false
	end

	completed = true
	StateService.SetAll("Completed", true)

	local mapDef = Svc("MatchService").GetMapDef()
	if mapDef and mapDef.Next and Maps[mapDef.Next] then
		openPortal()
	elseif mapDef and mapDef.HasSupreme then
		-- Deserto: não há portal; o final vem do Brainrot Supremo.
		local supremeName = Brainrots.Supreme and Brainrots.Supreme.DisplayName or "Brainrot Supremo"
		StateService.NotifyAll(
			("Todas as barracas no máximo! Agora o foco é alimentar o %s até ele tampar o sol!"):format(supremeName),
			"rare",
			10
		)
	else
		StateService.NotifyAll("Todas as barracas no máximo! Ato concluído!", "rare", 8)
	end
	return true
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function ProgressionService.Init()
	-- Request "VotePortal": mesmo efeito de usar o prompt do portal.
	Net.Handle("VotePortal", function(player)
		return activatePortal(player, false)
	end, { Rate = 2, Burst = 4 })
end

function ProgressionService.Start()
	local MatchService = Svc("MatchService")

	-- Estado inicial do portal (fechado).
	publishPortal()

	-- Jogador pronto: muda o total de votos necessários e pode completar a regra
	-- "AnyPlayer" (upgrades de arma de um run restaurado).
	MatchService.RunReady:Connect(function()
		publishPortal()
		ProgressionService.CheckCompletion()
	end)

	-- Jogador saiu: tira o voto dele e reconfere (menos gente = menos votos necessários).
	-- (task.defer: espera os outros serviços terminarem de tratar a saída, assim o
	-- MatchService já não conta esse jogador se a viagem começar agora.)
	Players.PlayerRemoving:Connect(function(player)
		votes[player.UserId] = nil
		task.defer(function()
			publishPortal(player)
			checkVotes(player)
		end)
	end)

	-- Partida continuada que já estava completa (só com upgrades do time).
	ProgressionService.CheckCompletion()
end

return ProgressionService
