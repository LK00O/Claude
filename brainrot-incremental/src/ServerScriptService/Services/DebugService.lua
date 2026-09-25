-- DebugService: comandos de teste para desenvolver mais rápido
-- (moedas infinitas, maxar upgrades, pular ato...).
--
-- Fica ligado quando:
--   * o jogo roda no Roblox Studio, ou
--   * Config.Game.DebugMode = true, ou
--   * o Workspace tem o atributo DebugMode = true.
--
-- Dá para usar de dois jeitos:
--   * Request "Debug"(command, arg) — usado pelo painel DEBUG do cliente;
--   * chat: digite "/coins 1000", "/maxall", "/wave" etc.
--
-- O AdminService (comandos de administrador, que valem também fora do Studio) reaproveita
-- estes comandos com DebugService.RunCommand(player, nome, arg, adminCaller). Só com um
-- adminCaller que o AdminService confirma ser admin a trava do modo de teste é pulada.
--
-- Comandos que só fazem sentido na partida (coins, maxall, wave, nextact, supreme,
-- ingredients, reset) respondem com um aviso quando usados no lobby.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Util.Net)
local NumberFormat = require(Shared.Util.NumberFormat)
local PlaceRole = require(Shared.Util.PlaceRole)
local GameConfig = require(Shared.Config.Game)
local MapsConfig = require(Shared.Config.Maps)
local UpgradesConfig = require(Shared.Config.Upgrades)
local RecipesConfig = require(Shared.Config.Recipes)

local DataService = require(script.Parent:WaitForChild("DataService"))
local StateService = require(script.Parent:WaitForChild("StateService"))

-- Outros serviços só dentro de funções (regra anti-require-circular).
local Services = script.Parent
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-- Módulos do mundo (MapBuilder) também são pegos só quando precisa.
local function World(name)
	return require(ServerScriptService:WaitForChild("World"):WaitForChild(name))
end

local DebugService = {}

-------------------------------------------------------------------------------
-- Constantes
-------------------------------------------------------------------------------

-- Valores padrão quando o comando vem sem número (constantes de teste, não de balanceamento).
local DEFAULT_COINS = 1e6 -- multiplicado pelo CostScale do mapa atual
local DEFAULT_TOKENS = 100
local INGREDIENTS_PER_COMMAND = 5

-- Limites de segurança dos argumentos.
local MAX_COINS = 1e300
local MAX_TOKENS_DELTA = 1e9
local MAX_COMMAND_LENGTH = 32
local MAX_ARG_LENGTH = 64

-- Mesmo texto repetido pelo mesmo jogador em menos disso (s) é ignorado
-- (o chat novo e o antigo podem avisar a mesma mensagem duas vezes).
local CHAT_DEDUPE_WINDOW = 1

-- Mensagens.
local MSG_DISABLED = "Os comandos de teste estão desligados."
local MSG_UNKNOWN = "Comando desconhecido. Use /help para ver a lista."
local MSG_MATCH_ONLY = "O comando '%s' só funciona dentro de uma partida (você está no lobby)."
local MSG_NOT_READY = "A partida ainda está carregando. Tente de novo em instantes."
local MSG_NO_PROFILE = "Seus dados ainda estão carregando."

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Os comandos estão liberados agora?
local function isEnabled()
	return RunService:IsStudio() or GameConfig.DebugMode == true or workspace:GetAttribute("DebugMode") == true
end

-- Papel deste servidor ("Lobby" ou "Match"). O Main grava no atributo "Role".
local function getRole()
	local role = workspace:GetAttribute("Role")
	if role == "Lobby" or role == "Match" then
		return role
	end
	return PlaceRole.Get()
end

-- Lê um número do argumento: aceita número ou texto ("1000", "2,5", "1e6", "10k", "3m", "2b", "1t").
local SUFFIX_MULT = { k = 1e3, m = 1e6, b = 1e9, t = 1e12 }
local function parseNumber(arg)
	local value
	if type(arg) == "number" then
		value = arg
	elseif type(arg) == "string" and #arg <= MAX_ARG_LENGTH then
		-- (string.gsub devolve 2 valores; os parênteses pegam só o texto)
		local text = string.lower((string.gsub(arg, "%s", "")))
		text = (string.gsub(text, ",", "."))
		local numberPart, suffix = string.match(text, "^([%d%.eE%+%-]+)([kmbt]?)$")
		if numberPart then
			value = tonumber(numberPart)
			if value and suffix ~= "" then
				value *= SUFFIX_MULT[suffix]
			end
		end
	end
	-- Rejeita NaN e infinito.
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

-- Pega o MatchService pronto para uso (ou nil se a partida ainda não carregou).
local function getMatch()
	local ok, MatchService = pcall(Svc, "MatchService")
	if not ok or type(MatchService) ~= "table" then
		return nil
	end
	if type(MatchService.GetMapId) ~= "function" or MatchService.GetMapId() == nil then
		return nil
	end
	return MatchService
end

-- Pega o run do jogador na partida (ou nil).
local function getRun(MatchService, player)
	local run = MatchService.GetRun(player)
	if type(run) ~= "table" then
		return nil
	end
	return run
end

-------------------------------------------------------------------------------
-- Comandos
-------------------------------------------------------------------------------
-- Cada comando: {MatchOnly = boolean, Usage = texto, Description = texto, Run = fn(player, arg) -> ok, msg}

local Commands = {}

Commands.coins = {
	MatchOnly = true,
	Usage = "coins <n>",
	Description = "Ganha n moedas",
	Run = function(player, arg)
		local MatchService = getMatch()
		if not MatchService then
			return false, MSG_NOT_READY
		end
		local amount = parseNumber(arg)
		if arg == nil then
			local mapDef = MatchService.GetMapDef()
			amount = DEFAULT_COINS * ((mapDef and mapDef.CostScale) or 1)
		end
		if not amount or amount <= 0 or amount > MAX_COINS then
			return false, "Use: coins <número maior que 0>"
		end
		MatchService.AddCoins(player, amount, "Debug")
		return true, "Você ganhou " .. NumberFormat.Abbrev(amount) .. " moedas."
	end,
}

Commands.maxall = {
	MatchOnly = true,
	Usage = "maxall",
	Description = "Maxa todos os upgrades e prateleiras do mapa",
	Run = function(player)
		local MatchService = getMatch()
		if not MatchService then
			return false, MSG_NOT_READY
		end
		local mapId = MatchService.GetMapId()
		local mapDef = MatchService.GetMapDef()
		local team = MatchService.GetTeam()
		if not mapDef or type(team) ~= "table" then
			return false, MSG_NOT_READY
		end
		team.Upgrades = team.Upgrades or {}

		-- Runs de todos os jogadores presentes (para a regra "AllPlayers" também valer).
		local runs = {}
		for _, other in ipairs(Players:GetPlayers()) do
			local run = getRun(MatchService, other)
			if run then
				run.Upgrades = run.Upgrades or {}
				runs[other] = run
			end
		end

		-- Coloca cada upgrade do mapa no nível máximo, no escopo certo.
		for _, def in ipairs(UpgradesConfig.ByMap[mapId] or {}) do
			if def.Scope == "Team" then
				team.Upgrades[def.Id] = def.MaxLevel
			else
				for _, run in pairs(runs) do
					run.Upgrades[def.Id] = def.MaxLevel
				end
			end
		end

		-- Libera todas as prateleiras.
		team.ShelfLevel = mapDef.MaxShelf or team.ShelfLevel
		local ctx = MatchService.GetContext()
		if ctx then
			World("MapBuilder").SetShelfLevel(ctx, team.ShelfLevel)
		end

		-- Recalcula stats e manda tudo para os clientes.
		Svc("StatService").Invalidate()
		for other, run in pairs(runs) do
			StateService.Set(other, "PlayerUpgrades", run.Upgrades)
		end
		StateService.SetAll("TeamUpgrades", team.Upgrades)
		StateService.SetAll("ShelfLevel", team.ShelfLevel)

		Svc("ProgressionService").CheckCompletion()
		return true, "Todos os upgrades e prateleiras foram maxados."
	end,
}

Commands.wave = {
	MatchOnly = true,
	Usage = "wave",
	Description = "Planta uma leva de brainrots",
	Run = function(player)
		if not getMatch() then
			return false, MSG_NOT_READY
		end
		local ok, msg = Svc("BrainrotService").SpawnWave(player)
		if ok then
			return true, if type(msg) == "string" and msg ~= "" then msg else "Leva de brainrots plantada!"
		end
		return false, if type(msg) == "string" and msg ~= "" then msg else "Não foi possível plantar agora."
	end,
}

Commands.nextact = {
	MatchOnly = true,
	Usage = "nextact",
	Description = "Conclui o ato atual",
	Run = function(player)
		local MatchService = getMatch()
		if not MatchService then
			return false, MSG_NOT_READY
		end
		-- CompleteAct pode demorar (salva e teleporta): roda em outra thread.
		task.spawn(function()
			local ok, err = pcall(MatchService.CompleteAct)
			if not ok then
				warn("[DebugService] Erro no CompleteAct: " .. tostring(err))
			end
		end)
		return true, "Concluindo o ato..."
	end,
}

Commands.supreme = {
	MatchOnly = true,
	Usage = "supreme <0..1>",
	Description = "Define o progresso do Brainrot Supremo",
	Run = function(player, arg)
		local MatchService = getMatch()
		if not MatchService then
			return false, MSG_NOT_READY
		end
		local mapDef = MatchService.GetMapDef()
		if not mapDef or not mapDef.HasSupreme then
			return false, "Este mapa não tem o Brainrot Supremo."
		end
		local target = parseNumber(arg)
		if not target or target < 0 or target > 1 then
			return false, "Use: supreme <número de 0 a 1>"
		end
		local team = MatchService.GetTeam()
		local current = tonumber(team and team.SupremeProgress) or 0
		Svc("SupremeService").AddProgress(target - current)
		return true, "Progresso do Supremo: " .. NumberFormat.Percent(target)
	end,
}

Commands.ingredients = {
	MatchOnly = true,
	Usage = "ingredients",
	Description = "Ganha 5 de cada ingrediente",
	Run = function(player)
		local MatchService = getMatch()
		if not MatchService then
			return false, MSG_NOT_READY
		end
		local mapDef = MatchService.GetMapDef()
		if not mapDef or not mapDef.HasRecipes then
			return false, "Este mapa não tem receitas."
		end
		local run = getRun(MatchService, player)
		if not run then
			return false, MSG_NOT_READY
		end
		run.Ingredients = run.Ingredients or {}
		for _, ingredient in ipairs(RecipesConfig.Ingredients) do
			run.Ingredients[ingredient.Id] = (tonumber(run.Ingredients[ingredient.Id]) or 0) + INGREDIENTS_PER_COMMAND
		end
		StateService.Set(player, "Ingredients", run.Ingredients)
		return true, ("Você ganhou %d de cada ingrediente."):format(INGREDIENTS_PER_COMMAND)
	end,
}

Commands.unlockall = {
	MatchOnly = false,
	Usage = "unlockall",
	Description = "Libera todos os mapas no seu perfil",
	Run = function(player)
		local profile = DataService.GetProfile(player)
		if not profile then
			return false, MSG_NO_PROFILE
		end
		profile.UnlockedMaps = profile.UnlockedMaps or {}
		for _, mapId in ipairs(MapsConfig.Order) do
			profile.UnlockedMaps[mapId] = true
		end
		DataService.SyncProfile(player)
		return true, "Todos os mapas foram liberados."
	end,
}

Commands.tokens = {
	MatchOnly = false,
	Usage = "tokens <n>",
	Description = "Ganha (ou perde) n Brainrot Tokens",
	Run = function(player, arg)
		local profile = DataService.GetProfile(player)
		if not profile then
			return false, MSG_NO_PROFILE
		end
		local amount = if arg == nil then DEFAULT_TOKENS else parseNumber(arg)
		if not amount or math.abs(amount) > MAX_TOKENS_DELTA then
			return false, "Use: tokens <número inteiro>"
		end
		amount = math.floor(amount)
		profile.Tokens = math.max(0, (tonumber(profile.Tokens) or 0) + amount)
		DataService.SyncProfile(player)
		return true, "Agora você tem " .. NumberFormat.Commas(profile.Tokens) .. " tokens."
	end,
}

Commands.reset = {
	MatchOnly = true,
	Usage = "reset",
	Description = "Zera o seu progresso nesta partida",
	Run = function(player)
		local MatchService = getMatch()
		if not MatchService then
			return false, MSG_NOT_READY
		end
		local run = getRun(MatchService, player)
		if not run then
			return false, MSG_NOT_READY
		end

		-- Zera o run (limpa as tabelas no lugar, para quem guardou referência a elas).
		run.Coins = 0
		if type(run.Upgrades) == "table" then
			table.clear(run.Upgrades)
		else
			run.Upgrades = {}
		end
		if type(run.Ingredients) == "table" then
			table.clear(run.Ingredients)
		else
			run.Ingredients = {}
		end
		run.Quest = nil
		run.QuestCooldownEnd = 0
		run.IncomeEMA = 0
		run.IncomeSlow = 0 -- média lenta usada pelas missões também volta a zero
		run.Heat = 0
		run.Overheated = false

		-- Stats mudaram (sem upgrades do jogador).
		local StatService = Svc("StatService")
		StatService.Invalidate(player)
		local stats = StatService.Get(player)

		-- Manda o estado novo para o cliente.
		-- Com a carteira do time (SharedWallet), "Coins" é um valor GLOBAL (SetAll), igual ao
		-- MatchService faz. Um valor só deste jogador (Set) esconderia o global para sempre:
		-- o StateService prefere o valor do jogador, e a HUD dele pararia de acompanhar o cofre.
		if GameConfig.SharedWallet then
			StateService.SetAll("Coins", MatchService.GetCoins(player))
		else
			StateService.Set(player, "Coins", MatchService.GetCoins(player))
		end
		StateService.Set(player, "Income", 0)
		StateService.Set(player, "PlayerUpgrades", run.Upgrades)
		StateService.Set(player, "Ingredients", run.Ingredients)
		StateService.Set(player, "Quest", { CooldownEnd = 0 })
		StateService.Set(player, "Heat", {
			Value = 0,
			Capacity = (type(stats) == "table" and tonumber(stats.HeatCapacity)) or 0,
			Overheated = false,
		})
		return true, "Seu progresso nesta partida foi zerado."
	end,
}

-- Ordem de exibição na ajuda.
local COMMAND_ORDER = { "coins", "maxall", "wave", "nextact", "supreme", "ingredients", "unlockall", "tokens", "reset" }

Commands.help = {
	MatchOnly = false,
	Usage = "help",
	Description = "Mostra a lista de comandos",
	Run = function()
		local lines = {}
		for _, name in ipairs(COMMAND_ORDER) do
			local command = Commands[name]
			table.insert(lines, "/" .. command.Usage .. " — " .. command.Description)
		end
		return true, table.concat(lines, "\n")
	end,
}

-------------------------------------------------------------------------------
-- Execução
-------------------------------------------------------------------------------

-- Roda um comando e devolve ok, mensagem (sempre um texto em português).
-- bypassGate = true pula a trava do modo de teste (só quando um admin pediu; veja RunCommand).
local function execute(player, commandName, arg, bypassGate)
	if not bypassGate and not isEnabled() then
		return false, MSG_DISABLED
	end
	if type(commandName) ~= "string" or commandName == "" or #commandName > MAX_COMMAND_LENGTH then
		return false, MSG_UNKNOWN
	end
	-- Aceita "/coins" ou "coins", em qualquer caixa.
	local name = string.lower((string.gsub(commandName, "^/", "")))
	local command = Commands[name]
	if not command then
		return false, MSG_UNKNOWN
	end

	-- Argumento: só número, texto curto ou nada.
	if arg ~= nil then
		local argType = type(arg)
		if argType == "string" then
			if #arg > MAX_ARG_LENGTH then
				return false, "Argumento grande demais."
			end
			if arg == "" then
				arg = nil
			end
		elseif argType ~= "number" then
			return false, "Argumento inválido."
		end
	end

	if command.MatchOnly and getRole() ~= "Match" then
		return false, MSG_MATCH_ONLY:format(name)
	end

	local ok, success, message = pcall(command.Run, player, arg)
	if not ok then
		warn("[DebugService] Erro no comando '" .. name .. "': " .. tostring(success))
		return false, "Erro ao rodar o comando (veja o Output)."
	end
	return success == true, tostring(message or "")
end

-- Últimas mensagens de chat de cada jogador, para não rodar a mesma duas vezes.
local lastChat = {} -- [player] = {Text, Time}

-- Trata uma mensagem de chat "/comando arg". Mensagens que não são comandos são ignoradas.
local function handleChat(player, message)
	if type(message) ~= "string" or not isEnabled() then
		return
	end
	local commandName, rest = string.match(message, "^%s*/(%S+)%s*(.-)%s*$")
	if not commandName then
		return
	end
	commandName = string.lower(commandName)
	if not Commands[commandName] then
		return -- outro comando de chat qualquer (ex.: /e dance): não é conosco
	end

	-- Evita rodar duas vezes a mesma mensagem (chat novo + chat antigo).
	local nowClock = os.clock()
	local last = lastChat[player]
	if last and last.Text == message and nowClock - last.Time < CHAT_DEDUPE_WINDOW then
		return
	end
	lastChat[player] = { Text = message, Time = nowClock }

	local ok, result = execute(player, commandName, if rest ~= "" then rest else nil)
	StateService.Notify(player, result, if ok then "success" else "error", if ok then nil else 5)
end

-- Cria os comandos no chat novo (TextChatService), um TextChatCommand para cada.
local chatCommandsCreated = false
local function ensureChatCommands()
	if chatCommandsCreated then
		return
	end
	chatCommandsCreated = true

	local ok, err = pcall(function()
		local folder = Instance.new("Folder")
		folder.Name = "DebugCommands"
		for name in pairs(Commands) do
			local command = Instance.new("TextChatCommand")
			command.Name = "Debug_" .. name
			command.PrimaryAlias = "/" .. name
			command.Triggered:Connect(function(textSource, unfilteredText)
				local player = Players:GetPlayerByUserId(textSource.UserId)
				if player then
					handleChat(player, unfilteredText)
				end
			end)
			command.Parent = folder
		end
		folder.Parent = TextChatService
	end)
	if not ok then
		warn("[DebugService] Não foi possível criar os comandos de chat: " .. tostring(err))
	end
end

-- Chat antigo (e fallback): Player.Chatted.
local function connectChatted(player)
	player.Chatted:Connect(function(message)
		handleChat(player, message)
	end)
end

-------------------------------------------------------------------------------
-- API usada pelo AdminService
-------------------------------------------------------------------------------

-- DebugService.RunCommand(player, commandName, arg, adminCaller?) -> ok, mensagem
--   Roda um comando de teste em "player" (quem recebe as moedas, os tokens...).
--   adminCaller = o jogador ADMIN que pediu o comando. Quando ele é mesmo admin (o
--   AdminService confere, sem confiar em nada que venha do cliente), a trava do modo de
--   teste é pulada e o comando funciona também nos servidores de verdade.
--   Sem adminCaller, vale a regra normal (só com o modo de teste ligado).
--   As regras "só na partida" continuam valendo nos dois casos.
function DebugService.RunCommand(player, commandName, arg, adminCaller)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "Jogador inválido."
	end
	local bypassGate = false
	if adminCaller ~= nil then
		local ok, isAdmin = pcall(function()
			return Svc("AdminService").IsAdmin(adminCaller)
		end)
		if not ok or isAdmin ~= true then
			return false, "Você não tem permissão para usar comandos de administrador."
		end
		bypassGate = true
	end
	return execute(player, commandName, arg, bypassGate)
end

-- DebugService.ParseNumber(arg) -> number | nil
--   Mesmo leitor de números dos comandos ("1000", "2,5", "1e6", "10k", "3m", "2b", "1t").
DebugService.ParseNumber = parseNumber

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function DebugService.Init()
	-- Request "Debug"(command, arg) -> ok, texto
	Net.Handle("Debug", function(player, commandName, arg)
		return execute(player, commandName, arg)
	end, { Rate = 4, Burst = 8 })

	-- Comandos pelo chat.
	Players.PlayerAdded:Connect(connectChatted)
	for _, player in ipairs(Players:GetPlayers()) do
		connectChatted(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastChat[player] = nil
	end)
	if isEnabled() then
		ensureChatCommands()
	end

	-- Se alguém ligar/desligar o atributo DebugMode com o jogo rodando, atualiza o
	-- atributo DebugEnabled (lido pelo cliente para mostrar o botão DEBUG).
	workspace:GetAttributeChangedSignal("DebugMode"):Connect(function()
		local enabled = isEnabled()
		workspace:SetAttribute("DebugEnabled", if enabled then true else nil)
		if enabled then
			ensureChatCommands()
		end
	end)
end

function DebugService.Start() end

return DebugService
