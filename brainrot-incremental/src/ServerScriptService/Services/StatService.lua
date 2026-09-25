--!nonstrict
-- StatService: calcula os "stats" (dano, cadência, chance de gigante...) de cada jogador
-- e do time, com cache. Os outros serviços pedem aqui em vez de recalcular toda hora.
--
--   StatService.Get(player)        -> stats do jogador (upgrades dele + do time + receitas + game passes
--                                     + evento global)
--   StatService.GetTeam()          -> stats do time (sem upgrades de jogador e sem game passes, com o
--                                     evento global; usado para regras do campo)
--   StatService.Invalidate(player?) -> joga o cache fora (nil = todos os jogadores + time)
--   StatService.Changed: Signal(player?)  -> dispara depois de cada Invalidate
--
-- IMPORTANTE: as tabelas devolvidas são do cache. Quem recebe só deve LER, nunca alterar.
--
-- Também cuida dos efeitos de ambiente que dependem do time: no Inverno, a neblina
-- fica mais fraca com o upgrade "Farol da Nevasca" (stat Visibility).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local UtilFolder = Shared:WaitForChild("Util")

local Signal = require(UtilFolder:WaitForChild("Signal"))
local Formulas = require(UtilFolder:WaitForChild("Formulas"))

-- Outros serviços: só dentro de funções (regra anti-require-circular).
local Services = script.Parent
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-- Duração da transição suave da neblina (constante visual, não é balanceamento).
local FOG_TWEEN_TIME = 1.5

local StatService = {}
StatService.Changed = Signal.new() -- (player?) nil = mudou para todos (stats do time)

local playerCache = {} -- [player] = stats
local teamCache = nil -- stats do time
local fogTween = nil -- tween atual da neblina (para cancelar se vier outro)

-- Número "de verdade" (nem NaN nem infinito).
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Efeitos do evento global ligado por um admin (":event"), ou nil sem evento.
-- Se o AdminService der erro, calcula sem evento (melhor do que quebrar os stats).
local function getEventEffects()
	local ok, effects = pcall(function()
		return Svc("AdminService").GetEventEffects()
	end)
	if ok and type(effects) == "table" then
		return effects
	end
	return nil
end

-- "extras" do jogador para o Formulas.ComputeStats:
--   DoubleCoins / VIP -> moedas;  DoubleDamage -> dano da arma dele (game passes);
--   Event -> efeitos do evento global (moedas, sorte, gigantes), iguais para todos.
-- Se o MonetizationService der erro, calcula sem passes (melhor do que quebrar os stats).
local function getPassExtras(player)
	local ok, extras = pcall(function()
		local MonetizationService = Svc("MonetizationService")
		return {
			DoubleCoins = MonetizationService.HasPass(player, "DoubleCoins") == true,
			VIP = MonetizationService.HasPass(player, "VIP") == true,
			DoubleDamage = MonetizationService.HasPass(player, "DoubleDamage") == true,
		}
	end)
	if not ok or type(extras) ~= "table" then
		extras = {}
	end
	extras.Event = getEventEffects()
	return extras
end

-- Calcula os stats de um jogador. Devolve (stats, temRun).
local function computeForPlayer(player)
	local MatchService = Svc("MatchService")
	local team = MatchService.GetTeam()
	local run = MatchService.GetRun(player)
	local stats = Formulas.ComputeStats(
		MatchService.GetMapId(),
		run and run.Upgrades or {},
		team.Upgrades,
		team.Recipes,
		getPassExtras(player)
	)
	return stats, run ~= nil
end

-- Efeitos de ambiente ligados aos stats do time (hoje: neblina do Inverno).
-- Densidade = AtmosphereDensity × VisibilityFactor ^ Visibility.
local function applyEnvironment()
	local mapDef = Svc("MatchService").GetMapDef()
	if not mapDef or not isFiniteNumber(mapDef.AtmosphereDensity) or not isFiniteNumber(mapDef.VisibilityFactor) then
		return -- este mapa não tem neblina controlada por upgrade
	end

	local teamStats = StatService.GetTeam()
	local visibility = isFiniteNumber(teamStats.Visibility) and teamStats.Visibility or 0
	local density = math.clamp(mapDef.AtmosphereDensity * mapDef.VisibilityFactor ^ visibility, 0, 1)

	-- O MapBuilder cria a Atmosphere; se por acaso não existir, criamos uma.
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = density
		atmosphere.Parent = Lighting
		return
	end
	if math.abs(atmosphere.Density - density) < 1e-4 then
		return
	end

	-- Transição suave (cancela a anterior, se ainda estiver rodando).
	if fogTween then
		fogTween:Cancel()
	end
	fogTween = TweenService:Create(
		atmosphere,
		TweenInfo.new(FOG_TWEEN_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Density = density }
	)
	fogTween:Play()
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Stats do jogador (com cache). Enquanto o run dele não existe, calcula sem guardar.
function StatService.Get(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return StatService.GetTeam()
	end
	local cached = playerCache[player]
	if cached then
		return cached
	end
	local stats, hasRun = computeForPlayer(player)
	if hasRun and player.Parent == Players then
		playerCache[player] = stats
	end
	return stats
end

-- Stats do time: upgrades do time + receitas + evento global, sem upgrades de jogador e
-- sem game passes (todo pass vale só para o dono: Moedas em Dobro, VIP, Dano em Dobro...).
-- "Team = true": o bônus de moedas do evento fica de fora do CoinMult do time, porque o
-- MatchService.AddCoins já aplica ele em cada jogador (senão contaria duas vezes).
function StatService.GetTeam()
	if teamCache then
		return teamCache
	end
	local MatchService = Svc("MatchService")
	local team = MatchService.GetTeam()
	teamCache = Formulas.ComputeStats(
		MatchService.GetMapId(),
		{},
		team.Upgrades,
		team.Recipes,
		{ Team = true, Event = getEventEffects() }
	)
	return teamCache
end

-- Joga o cache fora. player = nil -> todos os jogadores + time (e reaplica o ambiente).
function StatService.Invalidate(player)
	if player == nil then
		table.clear(playerCache)
		teamCache = nil
		local ok, err = pcall(applyEnvironment)
		if not ok then
			warn("[StatService] Erro ao aplicar efeitos de ambiente: " .. tostring(err))
		end
	else
		playerCache[player] = nil
	end
	StatService.Changed:Fire(player)
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function StatService.Init()
	-- Jogador saiu: libera o cache dele.
	Players.PlayerRemoving:Connect(function(player)
		playerCache[player] = nil
	end)
end

function StatService.Start()
	-- Quando o run de um jogador fica pronto (novo ou restaurado), os stats dele mudam.
	Svc("MatchService").RunReady:Connect(function(player)
		StatService.Invalidate(player)
	end)

	-- Aplica o ambiente inicial (ex.: partida continuada com o Farol da Nevasca já comprado).
	local ok, err = pcall(applyEnvironment)
	if not ok then
		warn("[StatService] Erro ao aplicar efeitos de ambiente: " .. tostring(err))
	end
end

return StatService
