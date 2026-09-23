--!nonstrict
-- SupremeService: o Brainrot Supremo da Grande Cova (só no Deserto, MapDef.HasSupreme).
--
-- Nos mapas sem Supremo, Init/Start não fazem nada, AddProgress/OnKill são ignorados e
-- o pedido "FeedSupreme" responde false, "Não há Brainrot Supremo neste mapa.".
--
-- Progresso (0 a 1, salvo em Team.SupremeProgress):
--   * sozinho, a cada segundo: + SupremePassive (upgrade "Irrigação");
--   * a cada brainrot destruído: + SupremeKill (upgrade "Raiz Profunda") -> OnKill(entity);
--   * alimentando com moedas: Request "FeedSupreme"(0.1 | 0.5 | 1);
--   * receitas (Sopa Suprema) e comandos de teste: AddProgress(x).
--
-- Visual: o modelo nasce em ctx.Pit, de frente para o oásis, com altura
--   MinHeight + (MaxHeight - MinHeight) × Progress^1,5
-- e a iluminação do mapa vai escurecendo conforme ele cresce (a sombra dele cobre o sol).
--
-- Final: quando o progresso chega a 1 (uma vez só), manda "Ending" para todos, espera a
-- cena final (30 s) e chama MatchService.CompleteAct() (o grupo volta ao lobby).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local Brainrots = require(ConfigFolder:WaitForChild("Brainrots"))
local Net = require(UtilFolder:WaitForChild("Net"))
local NumberFormat = require(UtilFolder:WaitForChild("NumberFormat"))

-- Módulo de mundo (permitido no topo, regra 1.2).
local BrainrotFactory = require(ServerScriptService:WaitForChild("World"):WaitForChild("BrainrotFactory"))

-- Serviços-folha (permitidos no topo).
local Services = script.Parent
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções (evita require circular).
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-------------------------------------------------------------------------------
-- Constantes (técnicas e da cena final; o balanceamento fica em Config/Maps e Config/Upgrades)
-------------------------------------------------------------------------------
local PASSIVE_INTERVAL = 1 -- loop de 1 Hz do crescimento sozinho
local PUBLISH_INTERVAL = 0.5 -- estado "Supreme", modelo e luz no máximo 2 vezes por segundo
local HEIGHT_EXPONENT = 1.5 -- altura = Min + (Max - Min) × Progress ^ 1,5 (seção 8.12)
local FEED_PROGRESS_COST_FACTOR = 3 -- custo cresce: BaseFullCost × CostScale × (1 + 3 × Progress)
local ENDING_DURATION = 30 -- duração da cena final (seção 8.12)
local VALID_FRACTIONS = { 0.1, 0.5, 1 } -- botões "Alimentar 10% / 50% / 100%"
local FRACTION_TOLERANCE = 1e-6
local MIN_MODEL_SCALE = 0.01
local RESCALE_MIN_STUDS = 0.1 -- só reescala o modelo se a altura mudou pelo menos isso...
local RESCALE_MIN_RELATIVE = 0.001 -- ...ou 0,1% da altura (o que for maior)
local COMPLETE_RETRY_DELAY = 10 -- se a viagem falhar, tenta de novo depois de 10 s
local COMPLETE_MAX_ATTEMPTS = 3
local MILESTONES = { 0.25, 0.5, 0.75, 0.9 } -- avisos "o Supremo já cobre X% do céu"

-- Escurecimento da iluminação (visual): com progresso 1, o brilho cai para 15%,
-- a luz ambiente vai 85% do caminho até um roxo-escuro e a exposição cai 1,6.
local DARKEN_EXPONENT = 1.3
local MIN_BRIGHTNESS_FACTOR = 0.15
local DARK_OUTDOOR_AMBIENT = Color3.fromRGB(30, 24, 42)
local MAX_OUTDOOR_DARKEN = 0.85
local EXPOSURE_DROP = 1.6
local LIGHT_MIN_CHANGE = 0.0005 -- mudança mínima no fator de escuridão para mexer na luz
local LIGHT_TWEEN_THRESHOLD = 0.02 -- saltos maiores que isso usam transição suave
local LIGHT_TWEEN_TIME = 1.5

-- Plaquinha em cima do Supremo.
local BILLBOARD_EXTRA_HEIGHT = 8
local BILLBOARD_MAX_DISTANCE = 3000

local NO_SUPREME_MESSAGE = "Não há Brainrot Supremo neste mapa."

-------------------------------------------------------------------------------
-- Estado do módulo
-------------------------------------------------------------------------------
local SupremeService = {}

local initialized = false
local started = false
local enabled = false -- este mapa tem o Supremo?
local supremeConfig = nil -- MapDef.Supreme {BrainrotId, BaseFullCost, MinHeight, MaxHeight}
local supremeDef = Brainrots.Supreme -- {Id, DisplayName, Archetype, Colors, ModelName...}

local dirty = true -- algo mudou desde a última publicação
local lastMilestone = 0

-- Modelo
local model = nil
local modelRotation = CFrame.identity -- só a rotação (de frente para o oásis)
local pitPosition = nil
local baseScale = 1 -- Model:GetScale() quando foi criado
local baseHeight = 5 -- altura (studs) do modelo na escala base
local pivotAboveBottom = 0 -- quanto o pivô fica acima do "pé" do modelo, na escala base
local shownHeight = nil -- altura mostrada agora

-- Plaquinha
local billboard = nil
local percentLabel = nil

-- Iluminação
local lightingBase = nil -- {Brightness, OutdoorAmbient, ExposureCompensation}
local shownDarkness = nil
local lightTween = nil

-- Final
local endingTriggered = false
local endingPending = false -- chegou a 1 sem ninguém no servidor: dispara quando alguém entrar
local endingStartedAt = 0
local endingPayload = nil

-------------------------------------------------------------------------------
-- Pequenos ajudantes
-------------------------------------------------------------------------------

-- Tempo compartilhado entre servidor e cliente.
local function now()
	return workspace:GetServerTimeNow()
end

-- Número "de verdade": nem NaN, nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Confere se é um Player que ainda está no jogo.
local function isPlayerInGame(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Lê um número de uma tabela de stats (com valor padrão).
local function statNumber(stats, key, default)
	local value = type(stats) == "table" and stats[key] or nil
	if isFiniteNumber(value) then
		return value
	end
	return default
end

local function getMatch()
	return Svc("MatchService")
end

-- Stats do time (os upgrades do Supremo são todos do time).
local function getTeamStats()
	local ok, stats = pcall(function()
		return Svc("StatService").GetTeam()
	end)
	return ok and stats or nil
end

-- Nome do Supremo para os textos.
local function supremeName()
	return (supremeDef and supremeDef.DisplayName) or "Brainrot Supremo"
end

-- Progresso atual (a "fonte da verdade" é Team.SupremeProgress, que é salvo).
local function getProgress()
	local team = getMatch().GetTeam()
	local value = team and team.SupremeProgress
	if not isFiniteNumber(value) then
		return 0
	end
	return math.clamp(value, 0, 1)
end

-- Altura (studs) para um progresso.
local function heightFor(progress)
	local minHeight = statNumber(supremeConfig, "MinHeight", 8)
	local maxHeight = statNumber(supremeConfig, "MaxHeight", 500)
	return minHeight + (maxHeight - minHeight) * math.clamp(progress, 0, 1) ^ HEIGHT_EXPONENT
end

-------------------------------------------------------------------------------
-- Modelo e plaquinha
-------------------------------------------------------------------------------

-- Ajusta a escala do modelo para a altura pedida, com o "pé" no fundo da cova.
local function applyModelHeight(height, force)
	if not model or not model.Parent or not pitPosition then
		return
	end
	if not force and shownHeight then
		local threshold = math.max(RESCALE_MIN_STUDS, shownHeight * RESCALE_MIN_RELATIVE)
		if math.abs(height - shownHeight) < threshold then
			return
		end
	end

	local scale = math.max(MIN_MODEL_SCALE, baseScale * height / baseHeight)
	model:ScaleTo(scale)
	-- ScaleTo cresce em volta do pivô; reposiciona para o pé continuar no chão.
	local pivotHeight = pivotAboveBottom * (scale / baseScale)
	model:PivotTo(CFrame.new(pitPosition + Vector3.new(0, pivotHeight, 0)) * modelRotation)
	shownHeight = height
end

-- Deixa todas as partes do Supremo "fantasma": ancoradas, sem colisão e sem bloquear
-- tiros (ele cresce até 500 studs e não pode prender jogadores dentro dele).
local function normalizeModel(target)
	for _, descendant in ipairs(target:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

-- Parte invisível na cova que segura a plaquinha (fora do modelo, para não ser escalada).
local function buildBillboard(parent)
	local anchor = Instance.new("Part")
	anchor.Name = "SupremeAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(pitPosition)
	anchor.Parent = parent

	local gui = Instance.new("BillboardGui")
	gui.Name = "SupremeTag"
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(280, 70)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = BILLBOARD_MAX_DISTANCE
	gui.StudsOffsetWorldSpace = Vector3.new(0, heightFor(getProgress()) + BILLBOARD_EXTRA_HEIGHT, 0)
	gui.Parent = anchor

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "SupremeName"
	nameLabel.BackgroundTransparency = 1
	nameLabel.Size = UDim2.fromScale(1, 0.6)
	nameLabel.Font = Enum.Font.FredokaOne
	nameLabel.Text = supremeName()
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = Color3.fromRGB(255, 215, 70)
	nameLabel.TextStrokeTransparency = 0.2
	nameLabel.TextStrokeColor3 = Color3.fromRGB(40, 20, 10)
	nameLabel.Parent = gui

	local label = Instance.new("TextLabel")
	label.Name = "Percent"
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0, 0.6)
	label.Size = UDim2.fromScale(1, 0.4)
	label.Font = Enum.Font.GothamBold
	label.Text = ""
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.Parent = gui

	billboard = gui
	percentLabel = label
end

-- Atualiza a plaquinha (altura e "X% do céu").
local function updateBillboard(progress, height)
	if billboard then
		billboard.StudsOffsetWorldSpace = Vector3.new(0, height + BILLBOARD_EXTRA_HEIGHT, 0)
	end
	if percentLabel then
		percentLabel.Text = NumberFormat.Percent(progress, 1) .. " do céu"
	end
end

-- Cria o Supremo na Grande Cova (ctx.Pit), de frente para o oásis.
local function buildSupremeModel()
	local ctx = getMatch().GetContext()
	local pit = ctx and ctx.Pit
	if typeof(pit) ~= "Vector3" then
		warn("[SupremeService] O mapa não tem a Grande Cova (ctx.Pit); o Supremo não será mostrado.")
		return
	end
	pitPosition = pit

	local ok, built = pcall(BrainrotFactory.BuildSupreme, supremeDef)
	if not ok or typeof(built) ~= "Instance" or not built:IsA("Model") then
		warn("[SupremeService] Não foi possível montar o Supremo: " .. tostring(built))
		return
	end
	model = built
	model.Name = "Supreme"
	model:SetAttribute("Supreme", true)
	model:SetAttribute("DisplayName", supremeName())
	normalizeModel(model)

	-- De frente para o oásis (a frente do modelo é o -Z, padrão do Roblox).
	local oasis = ctx.OasisCenter
	modelRotation = CFrame.identity
	if typeof(oasis) == "Vector3" then
		local flatTarget = Vector3.new(oasis.X, pit.Y, oasis.Z)
		if (flatTarget - pit).Magnitude > 0.1 then
			modelRotation = CFrame.lookAt(pit, flatTarget).Rotation
		end
	end
	model:PivotTo(CFrame.new(pit) * modelRotation)

	-- Mede o modelo na escala base: altura e distância do pivô até o pé.
	baseScale = model:GetScale()
	local boxCFrame, boxSize = model:GetBoundingBox()
	baseHeight = math.max(0.1, boxSize.Y)
	local bottomY = boxCFrame.Position.Y - boxSize.Y / 2
	pivotAboveBottom = model:GetPivot().Position.Y - bottomY

	local parent = (ctx.Folder and ctx.Folder.Parent) and ctx.Folder or workspace
	model.Parent = parent
	buildBillboard(parent)

	shownHeight = nil
	applyModelHeight(heightFor(getProgress()), true)
end

-------------------------------------------------------------------------------
-- Iluminação
-------------------------------------------------------------------------------

-- Guarda a iluminação "normal" do mapa (sem o Supremo).
local function captureLightingBase()
	local mapDef = getMatch().GetMapDef()
	local config = type(mapDef) == "table" and type(mapDef.Lighting) == "table" and mapDef.Lighting or {}
	lightingBase = {
		Brightness = isFiniteNumber(config.Brightness) and config.Brightness or Lighting.Brightness,
		OutdoorAmbient = typeof(config.OutdoorAmbient) == "Color3" and config.OutdoorAmbient or Lighting.OutdoorAmbient,
		ExposureCompensation = Lighting.ExposureCompensation,
	}
end

-- Escurece o mapa conforme o progresso.
local function applyLighting(progress)
	if not lightingBase then
		return
	end
	local darkness = math.clamp(progress, 0, 1) ^ DARKEN_EXPONENT
	if shownDarkness and math.abs(darkness - shownDarkness) < LIGHT_MIN_CHANGE then
		return
	end

	local goal = {
		Brightness = lightingBase.Brightness * (1 - (1 - MIN_BRIGHTNESS_FACTOR) * darkness),
		OutdoorAmbient = lightingBase.OutdoorAmbient:Lerp(DARK_OUTDOOR_AMBIENT, MAX_OUTDOOR_DARKEN * darkness),
		ExposureCompensation = lightingBase.ExposureCompensation - EXPOSURE_DROP * darkness,
	}

	if lightTween then
		lightTween:Cancel()
		lightTween = nil
	end
	local bigJump = shownDarkness == nil or math.abs(darkness - shownDarkness) >= LIGHT_TWEEN_THRESHOLD
	if bigJump then
		-- Mudança grande (ex.: receita, comando de teste): transição suave.
		lightTween = TweenService:Create(
			Lighting,
			TweenInfo.new(LIGHT_TWEEN_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			goal
		)
		lightTween:Play()
	else
		-- Mudança pequena (crescimento contínuo): aplica direto, sem replicar um tween.
		for property, value in pairs(goal) do
			Lighting[property] = value
		end
	end
	shownDarkness = darkness
end

-------------------------------------------------------------------------------
-- Publicação (2 Hz)
-------------------------------------------------------------------------------

local function publish()
	local progress = getProgress()
	local height = heightFor(progress)
	StateService.SetAll("Supreme", { Progress = progress, Height = height })

	local okModel, modelErr = pcall(applyModelHeight, height, false)
	if not okModel then
		warn("[SupremeService] Erro ao escalar o Supremo: " .. tostring(modelErr))
	end
	updateBillboard(progress, height)
	local okLight, lightErr = pcall(applyLighting, progress)
	if not okLight then
		warn("[SupremeService] Erro ao ajustar a iluminação: " .. tostring(lightErr))
	end
end

-------------------------------------------------------------------------------
-- Final
-------------------------------------------------------------------------------

-- Nomes para os créditos: quem está aqui primeiro, depois quem ajudou e já saiu.
local function creditNames()
	local names = {}
	local seen = {}
	local MatchService = getMatch()
	for _, player in ipairs(Players:GetPlayers()) do
		if MatchService.GetRun(player) then
			table.insert(names, player.DisplayName)
			seen[player.UserId] = true
		end
	end
	if type(MatchService.Runs) == "table" then
		for userId, run in pairs(MatchService.Runs) do
			if not seen[userId] and type(run) == "table" and type(run.Name) == "string" then
				table.insert(names, run.Name)
				seen[userId] = true
			end
		end
	end
	return names
end

-- Quantos jogadores com run estão no servidor.
local function countPresentRuns()
	local MatchService = getMatch()
	local count = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if MatchService.GetRun(player) then
			count += 1
		end
	end
	return count
end

-- Conclui o ato (volta ao lobby). Se a viagem falhar, tenta mais algumas vezes.
local function completeAct(attempt)
	local ok, result, message = pcall(function()
		return getMatch().CompleteAct()
	end)
	if ok and result ~= false then
		return
	end
	warn(
		("[SupremeService] CompleteAct falhou (tentativa %d): %s"):format(
			attempt,
			tostring(ok and message or result)
		)
	)
	if attempt < COMPLETE_MAX_ATTEMPTS then
		task.delay(COMPLETE_RETRY_DELAY, completeAct, attempt + 1)
	else
		-- Desistiu de levar todos juntos: cada um ainda pode voltar pelo botão do HUD.
		StateService.NotifyAll(
			"Não foi possível voltar ao lobby automaticamente. Use o botão \"Voltar ao lobby\".",
			"error",
			10
		)
	end
end

-- Dispara a cena final (uma vez só).
local function triggerEnding()
	if endingTriggered then
		return
	end
	if countPresentRuns() == 0 then
		-- Ninguém para assistir (ex.: partida continuada que já estava em 100%).
		endingPending = true
		return
	end
	endingTriggered = true
	endingPending = false
	endingStartedAt = now()
	endingPayload = {
		Names = creditNames(),
		Duration = ENDING_DURATION,
		SupremeName = supremeName(),
	}

	Net.FireAll("Ending", endingPayload)
	StateService.NotifyAll(("O %s tampou o sol! Obrigado por jogar!"):format(supremeName()), "rare", 10)

	-- Depois da cena final, conclui o ato (Deserto: todos voltam ao lobby).
	task.delay(ENDING_DURATION, completeAct, 1)
end

-- Avisa quando o Supremo passa de 25%, 50%, 75% e 90% do céu.
local function checkMilestones(progress)
	for _, milestone in ipairs(MILESTONES) do
		if progress >= milestone and lastMilestone < milestone then
			lastMilestone = milestone
			StateService.NotifyAll(
				("O %s já cobre %s do céu!"):format(supremeName(), NumberFormat.Percent(milestone, 0)),
				"rare",
				5
			)
		end
	end
end

-- Muda o progresso (sempre entre 0 e 1) e marca para publicar.
local function setProgress(value)
	if not isFiniteNumber(value) then
		return
	end
	local team = getMatch().GetTeam()
	if not team then
		return
	end
	local clamped = math.clamp(value, 0, 1)
	if clamped == getProgress() then
		return
	end
	team.SupremeProgress = clamped
	dirty = true

	if started then
		checkMilestones(clamped)
		if clamped >= 1 then
			triggerEnding()
		end
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Soma (ou tira, com número negativo) progresso do Supremo. Usado por receitas e testes.
function SupremeService.AddProgress(amount)
	if not enabled or not isFiniteNumber(amount) or amount == 0 then
		return
	end
	setProgress(getProgress() + amount)
end

-- Chamado pelo BrainrotService quando um brainrot morre: + SupremeKill.
function SupremeService.OnKill(entity)
	if not enabled or endingTriggered then
		return
	end
	local perKill = statNumber(getTeamStats(), "SupremeKill", 0)
	if perKill > 0 then
		setProgress(getProgress() + perKill)
	end
end

-- Request "FeedSupreme"(fraction): gasta uma parte das moedas para o Supremo crescer.
local function feedSupreme(player, fraction)
	if not enabled then
		return false, NO_SUPREME_MESSAGE
	end
	if not isPlayerInGame(player) then
		return false, "Jogador inválido."
	end
	if not isFiniteNumber(fraction) then
		return false, "Quantidade inválida."
	end
	local chosen = nil
	for _, valid in ipairs(VALID_FRACTIONS) do
		if math.abs(fraction - valid) < FRACTION_TOLERANCE then
			chosen = valid
			break
		end
	end
	if not chosen then
		return false, "Quantidade inválida."
	end

	local MatchService = getMatch()
	if not MatchService.GetRun(player) then
		return false, "Você ainda não entrou na partida."
	end
	local progress = getProgress()
	if progress >= 1 or endingTriggered then
		return false, "O Supremo já tampou o sol!"
	end

	local coins = MatchService.GetCoins(player)
	if not isFiniteNumber(coins) or coins < 1 then
		return false, "Você não tem moedas para alimentar o Supremo."
	end

	local feedPower = statNumber(getTeamStats(), "SupremeFeed", 1)
	local mapDef = MatchService.GetMapDef()
	local costScale = (type(mapDef) == "table" and isFiniteNumber(mapDef.CostScale)) and mapDef.CostScale or 1
	-- Moedas para encher 100% com o progresso atual (fica mais caro quanto maior ele está).
	local fullCost = statNumber(supremeConfig, "BaseFullCost", 1) * costScale * (1 + FEED_PROGRESS_COST_FACTOR * progress)
	if feedPower <= 0 or fullCost <= 0 then
		return false, "O Supremo não pode ser alimentado agora."
	end

	-- Gasta floor(moedas × fração), no mínimo 1, e nunca mais do que falta para chegar a 100%.
	local spend = math.max(1, math.floor(coins * chosen))
	local neededForFull = math.max(1, math.ceil((1 - progress) * fullCost / feedPower))
	spend = math.min(spend, neededForFull)
	if not MatchService.SpendCoins(player, spend) then
		return false, "Moedas insuficientes."
	end

	setProgress(progress + spend / fullCost * feedPower)
	return true, { Spent = spend, Progress = getProgress() }
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function SupremeService.Init()
	if initialized then
		return
	end
	initialized = true

	-- Este mapa tem o Supremo?
	local okDef, mapDef = pcall(function()
		return getMatch().GetMapDef()
	end)
	enabled = okDef
		and type(mapDef) == "table"
		and mapDef.HasSupreme == true
		and type(mapDef.Supreme) == "table"
		and type(supremeDef) == "table"
	if enabled then
		supremeConfig = mapDef.Supreme
	end

	-- Request "FeedSupreme" (registrado sempre: nos outros mapas responde com a mensagem).
	Net.Handle("FeedSupreme", function(player, fraction)
		return feedSupreme(player, fraction)
	end, { Rate = 3, Burst = 6 })
end

function SupremeService.Start()
	if started or not enabled then
		return
	end
	started = true

	-- Não repete avisos de marcos que a partida salva já tinha passado.
	local progress = getProgress()
	for _, milestone in ipairs(MILESTONES) do
		if progress >= milestone then
			lastMilestone = milestone
		end
	end

	captureLightingBase()
	local okBuild, buildErr = pcall(buildSupremeModel)
	if not okBuild then
		warn("[SupremeService] Erro ao criar o Supremo: " .. tostring(buildErr))
	end
	dirty = false
	publish()

	-- Partida continuada que já estava em 100%: o final acontece quando alguém entrar.
	if progress >= 1 then
		triggerEnding()
	end

	-- Jogador pronto: final pendente, ou quem chegou no meio da cena final também a vê.
	local okRun, runErr = pcall(function()
		getMatch().RunReady:Connect(function(player)
			if endingPending and not endingTriggered then
				triggerEnding()
			elseif endingTriggered and endingPayload and isPlayerInGame(player) then
				local remaining = ENDING_DURATION - (now() - endingStartedAt)
				if remaining > 1 then
					Net.FireClient(player, "Ending", {
						Names = endingPayload.Names,
						Duration = remaining,
						SupremeName = endingPayload.SupremeName,
					})
				end
			end
		end)
	end)
	if not okRun then
		warn("[SupremeService] Não foi possível escutar MatchService.RunReady: " .. tostring(runErr))
	end

	-- Loop de 1 Hz: crescimento sozinho (+ SupremePassive por segundo).
	task.spawn(function()
		local dt = PASSIVE_INTERVAL
		while true do
			if not endingTriggered then
				local ok, err = pcall(function()
					local passive = statNumber(getTeamStats(), "SupremePassive", 0)
					if passive > 0 then
						setProgress(getProgress() + passive * math.clamp(dt, 0, PASSIVE_INTERVAL * 5))
					end
				end)
				if not ok then
					warn("[SupremeService] Erro no crescimento passivo: " .. tostring(err))
				end
			end
			dt = task.wait(PASSIVE_INTERVAL)
		end
	end)

	-- Loop de 2 Hz: publica o estado e atualiza modelo/luz quando algo mudou.
	task.spawn(function()
		while true do
			task.wait(PUBLISH_INTERVAL)
			if dirty then
				dirty = false
				local ok, err = pcall(publish)
				if not ok then
					warn("[SupremeService] Erro ao publicar o Supremo: " .. tostring(err))
				end
			end
		end
	end)
end

return SupremeService
