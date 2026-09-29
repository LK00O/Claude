--!nonstrict
-- TurretService: as torretas que os jogadores posicionam no campo (Atos 2 e 3).
--
-- Só funciona em mapas com MapDef.HasTurrets. Nos outros mapas, Init/Start não fazem
-- nada e todos os pedidos respondem false, "Não há torretas neste mapa".
--
-- Requests (seção 2.5):
--   PlaceTurret(position: Vector3, rotY: number) -> turretId
--   PickupTurret(turretId: string)              -> true   (só o dono ou o dono da partida)
--   RecallTurrets()                             -> true   (todas voltam para os pads da base)
--   SetTurretMode(turretId, "Valuable"|"Nearest") -> true   (só o dono ou o dono da partida)
--
-- Torreta (tabela interna):
--   { Id, OwnerUserId, Model, Position (Vector3 no chão), RotY, Mode, NextShot,
--     Head, Muzzle, Trove }
--
-- Confiabilidade (o original tinha torretas que "sumiam" ou travavam):
--   * tudo é ancorado e colocado com raycast no chão (nunca cai);
--   * a posição só é aceita dentro de uma TurretZone, perto do jogador e longe de outras torretas;
--   * um "vigia" a cada 2 s confere se o modelo de cada torreta ainda existe e está no lugar
--     (se não estiver, reconstrói);
--   * a lista do time (Team.Turrets) é atualizada a cada mudança e salva junto com a partida.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local UtilFolder = Shared:WaitForChild("Util")

local GameConfig = require(ConfigFolder:WaitForChild("Game"))
local Net = require(UtilFolder:WaitForChild("Net"))
local Trove = require(UtilFolder:WaitForChild("Trove"))
local Formulas = require(UtilFolder:WaitForChild("Formulas"))

-- Módulo de mundo (permitido no topo, regra 1.2).
local TurretFactory = require(ServerScriptService:WaitForChild("World"):WaitForChild("TurretFactory"))

-- Serviços-folha (permitidos no topo).
local Services = script.Parent
local StateService = require(Services:WaitForChild("StateService"))

-- Outros serviços: só dentro de funções (evita require circular).
local function Svc(name)
	return require(Services:WaitForChild(name))
end

-------------------------------------------------------------------------------
-- Constantes técnicas (não são balanceamento)
-------------------------------------------------------------------------------
local TICK_INTERVAL = 0.1 -- loop de tiro a 10 Hz
local WATCHDOG_INTERVAL = 2 -- vigia das torretas a cada 2 s
local MAX_PLACE_DISTANCE = 60 -- seção 8.10: até 60 studs do jogador
local PLACE_DISTANCE_SLACK = 6 -- folga para o atraso de rede (o jogador andou um pouco)
local MIN_TURRET_SPACING = 5 -- seção 8.10: pelo menos 5 studs de outras torretas
local GROUND_PROBE_UP = 4 -- o raio para achar o chão começa 4 studs acima do ponto pedido
local GROUND_PROBE_DEPTH = 60 -- e desce até 60 studs
local MIN_GROUND_NORMAL_Y = 0.5 -- chão mais inclinado que ~60° não serve
local HARD_TURRET_CAP = 40 -- trava de segurança de desempenho (nunca deve ser atingida)
local MAX_SHOTS_PER_TURRET_TICK = 4 -- cadências muito altas atiram várias vezes por tick
local LOS_CANDIDATES = 3 -- quantos alvos testar com linha de visão antes de desistir no tick
local AIM_HEIGHT_PER_SCALE = 2.5 -- metade da altura de um brainrot de escala 1 (~5 studs)
local HEAD_HEIGHT_FALLBACK = 3.5 -- altura aproximada da cabeça, se ela sumir
local MISS_MIN, MISS_MAX = 1.5, 4 -- quanto um tiro errado passa longe do alvo
local MISS_OVERSHOOT = 8 -- o traçado do tiro errado continua um pouco depois do alvo
local RECALL_COOLDOWN = 2 -- segundos entre dois "chamar de volta"
local RECALL_RING_SPACING = 6 -- se houver mais torretas que pads, elas fazem um anel em volta
local FALLBACK_RECALL_RADIUS = 10 -- sem pads: torretas em círculo em volta do spawn
local LOST_BELOW_GROUND = 50 -- abaixo de GroundY - 50 a torreta é considerada perdida
local POSITION_TOLERANCE = 0.5 -- modelo fora do lugar por mais que isso é recolocado
local MAX_ID_LENGTH = 32

local NO_TURRETS_MESSAGE = "Não há torretas neste mapa"

-- Textos de cada modo de mira (prompt e plaquinha).
local MODE_TEXTS = {
	Valuable = { Action = "Mirar: mais valioso", Label = "Alvo: mais valioso", Name = "mais valioso" },
	Nearest = { Action = "Mirar: mais perto", Label = "Alvo: mais perto", Name = "mais perto" },
}

-- Cor principal da torreta de cada dono (sorteada pelo userId), para ver de quem é de longe.
local OWNER_PALETTE = {
	Color3.fromRGB(70, 150, 230), -- azul
	Color3.fromRGB(230, 85, 85), -- vermelho
	Color3.fromRGB(95, 200, 110), -- verde
	Color3.fromRGB(190, 100, 230), -- roxo
	Color3.fromRGB(245, 150, 55), -- laranja
	Color3.fromRGB(70, 205, 205), -- ciano
	Color3.fromRGB(240, 115, 185), -- rosa
	Color3.fromRGB(150, 110, 75), -- marrom
}

-------------------------------------------------------------------------------
-- Estado do módulo
-------------------------------------------------------------------------------
local TurretService = {}

local initialized = false
local started = false
local enabled = false -- este mapa tem torretas?

local turrets = {} -- [turretId] = torreta
local order = {} -- {turretId} na ordem em que foram colocadas
local nextIdNumber = 0
local lastRecallAt = -math.huge
local ownerNames = {} -- [userId] = nome (cache)
local failedNames = {} -- [userId] = true (a busca do nome falhou; não tenta de novo)
local pendingNames = {} -- [userId] = true (busca em andamento)
local overridePlayers = {} -- [player] = true (tem valor próprio de "Turrets" por causa do pass)
local rng = Random.new()

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

-- Vector3 com as três coordenadas finitas.
local function isFiniteVector(value)
	return typeof(value) == "Vector3" and isFiniteNumber(value.X) and isFiniteNumber(value.Y) and isFiniteNumber(value.Z)
end

-- Confere se é um Player que ainda está no jogo.
local function isPlayerInGame(player)
	return typeof(player) == "Instance" and player:IsA("Player") and player.Parent == Players
end

-- Lê um número de uma tabela de stats (com valor padrão se faltar ou for inválido).
local function statNumber(stats, key, default)
	local value = type(stats) == "table" and stats[key] or nil
	if isFiniteNumber(value) then
		return value
	end
	return default
end

-- Distância só no plano XZ (ignora a altura).
local function flatDistance(a, b)
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Ângulo Y (em radianos) de um CFrame, a partir da direção para onde ele olha.
local function yawOf(cframe)
	local look = cframe.LookVector
	if math.abs(look.X) < 1e-6 and math.abs(look.Z) < 1e-6 then
		return 0
	end
	return math.atan2(-look.X, -look.Z)
end

local function getMatch()
	return Svc("MatchService")
end

local function getContext()
	local ok, ctx = pcall(function()
		return getMatch().GetContext()
	end)
	return ok and ctx or nil
end

-- Stats do time (torretas usam só upgrades do time + receitas).
local function getTeamStats()
	local ok, stats = pcall(function()
		return Svc("StatService").GetTeam()
	end)
	if ok and type(stats) == "table" then
		return stats
	end
	return nil
end

-- O jogador tem o game pass? (false se o serviço der erro)
local function hasPass(player, key)
	local ok, result = pcall(function()
		return Svc("MonetizationService").HasPass(player, key)
	end)
	return ok and result == true
end

-- Pasta workspace.Turrets (o MatchService cria; recriamos se alguém apagar).
local function getTurretsFolder()
	local folder = workspace:FindFirstChild("Turrets")
	if folder and folder:IsA("Folder") then
		return folder
	end
	if folder then
		folder:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "Turrets"
	folder.Parent = workspace
	return folder
end

-- Partes auxiliares invisíveis do mapa (zonas de torreta e área do campo).
local function getHelperParts()
	local ctx = getContext()
	local list = {}
	if not ctx then
		return list
	end
	if type(ctx.TurretZones) == "table" then
		for _, zone in ipairs(ctx.TurretZones) do
			if typeof(zone) == "Instance" and zone:IsA("BasePart") then
				table.insert(list, zone)
			end
		end
	end
	if typeof(ctx.FieldArea) == "Instance" and ctx.FieldArea:IsA("BasePart") then
		table.insert(list, ctx.FieldArea)
	end
	return list
end

-- Lista de coisas que os raios (chão e linha de visão) devem ignorar.
local function buildExcludeList()
	local list = { getTurretsFolder() }
	for _, name in ipairs({ "Brainrots", "Coins", "ClientEffects" }) do
		local folder = workspace:FindFirstChild(name)
		if folder then
			table.insert(list, folder)
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	return list
end

-- Raio do CHÃO: só bate em coisas sólidas (CanCollide = true: chão, pedras, paredes).
-- As zonas invisíveis e a área do campo são ignoradas mesmo se alguém ligar a colisão delas.
local function buildRaycastParams()
	local list = buildExcludeList()
	for _, part in ipairs(getHelperParts()) do
		table.insert(list, part)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = list
	params.RespectCanCollide = true
	params.IgnoreWater = true
	return params
end

-- Raio da LINHA DE VISÃO: usa CanQuery, igual às balas dos jogadores (seção 7.3).
-- Assim cercas e decoração baixa (CanQuery = false) não atrapalham a mira das torretas.
local function buildSightParams()
	local list = buildExcludeList()
	-- Inverno: o piso da plataforma elevada (ctx.Platform) também é ignorado. Os pads da
	-- base ficam EM CIMA dele, a poucos studs da borda; sem isso, o raio da cabeça até um
	-- brainrot no vale batia no próprio piso e as torretas dos pads quase nunca atiravam
	-- (a fileira de trás, nunca). Isso não cria "tiro através da plataforma": os brainrots
	-- nunca ficam em cima dela e uma torreta no vale mira por baixo do piso (onde os
	-- pilares continuam bloqueando normalmente).
	-- Pelo mesmo motivo ignoramos a pasta "TurretPads" ao lado do piso: os pads são discos
	-- baixinhos, e o raio da fileira de trás (que desce em diagonal) raspava no pad da
	-- fileira da frente.
	local ctx = getContext()
	if ctx and typeof(ctx.Platform) == "Instance" and ctx.Platform:IsA("BasePart") then
		table.insert(list, ctx.Platform)
		local structure = ctx.Platform.Parent
		local pads = structure and structure:FindFirstChild("TurretPads")
		if pads then
			table.insert(list, pads)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = list
	params.RespectCanCollide = false
	params.IgnoreWater = true
	return params
end

-------------------------------------------------------------------------------
-- Limite de torretas e estado "Turrets"
-------------------------------------------------------------------------------

-- Máximo do time pelos upgrades: floor(TurretCount).
local function getBaseMax()
	local stats = getTeamStats()
	return math.max(0, math.floor(statNumber(stats, "TurretCount", 0) + 1e-9))
end

-- Máximo para um jogador: o do time + 1 se ele tem o game pass "Torreta extra".
local function getMaxFor(player)
	local max = getBaseMax()
	if player and hasPass(player, "ExtraTurret") then
		max += 1
	end
	return max
end

-- Publica {Placed, Max}. Quem tem o pass "Torreta extra" recebe um valor próprio
-- (com Max + 1), que tem prioridade sobre o global para aquele jogador.
local function publishState()
	if not enabled then
		return
	end
	local placed = #order
	local baseMax = getBaseMax()
	StateService.SetAll("Turrets", { Placed = placed, Max = baseMax })

	for _, player in ipairs(Players:GetPlayers()) do
		local extra = hasPass(player, "ExtraTurret")
		if extra or overridePlayers[player] then
			overridePlayers[player] = true
			StateService.Set(player, "Turrets", { Placed = placed, Max = baseMax + (extra and 1 or 0) })
		end
	end
end

-- Copia as torretas atuais para Team.Turrets (formato salvo: seção 8.2).
local function saveTeamTurrets()
	local list = {}
	for _, turretId in ipairs(order) do
		local turret = turrets[turretId]
		if turret then
			table.insert(list, {
				OwnerUserId = turret.OwnerUserId,
				Position = { turret.Position.X, turret.Position.Y, turret.Position.Z },
				RotY = turret.RotY,
				Mode = turret.Mode,
			})
		end
	end
	local ok, err = pcall(function()
		getMatch().GetTeam().Turrets = list
	end)
	if not ok then
		warn("[TurretService] Não foi possível salvar as torretas no time: " .. tostring(err))
	end
end

-- Mudou alguma torreta: salva no time e avisa os clientes.
local function onTurretsChanged()
	saveTeamTurrets()
	publishState()
end

-------------------------------------------------------------------------------
-- Nomes e cores dos donos
-------------------------------------------------------------------------------

-- Atualiza o texto "Torreta de <nome>" de todas as torretas de um dono.
local function refreshOwnerTags(userId, name)
	for _, turretId in ipairs(order) do
		local turret = turrets[turretId]
		if turret and turret.OwnerUserId == userId and turret.Model then
			local tag = turret.Model:FindFirstChild("OwnerTag", true)
			local label = tag and tag:FindFirstChild("OwnerName")
			if label and label:IsA("TextLabel") then
				label.Text = "Torreta de " .. name
			end
		end
	end
end

-- Busca o nome de quem não está no servidor (chamada web: em outra thread e com pcall).
local function requestOwnerName(userId)
	if pendingNames[userId] or failedNames[userId] or ownerNames[userId] then
		return
	end
	pendingNames[userId] = true
	task.spawn(function()
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		pendingNames[userId] = nil
		if ok and type(name) == "string" and name ~= "" then
			-- Se o dono entrou enquanto isso, o nome de exibição dele já está no cache.
			if not ownerNames[userId] then
				ownerNames[userId] = name
				refreshOwnerTags(userId, name)
			end
		else
			failedNames[userId] = true
		end
	end)
end

-- Nome do dono para a plaquinha.
local function getOwnerName(userId)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		ownerNames[userId] = player.DisplayName
		return player.DisplayName
	end
	if ownerNames[userId] then
		return ownerNames[userId]
	end
	local okRun, run = pcall(function()
		return getMatch().GetRunByUserId(userId)
	end)
	if okRun and type(run) == "table" and type(run.Name) == "string" and run.Name ~= "" then
		return run.Name
	end
	requestOwnerName(userId)
	return "Jogador"
end

-- Cor principal da torreta pelo userId do dono (sempre a mesma para a mesma pessoa).
local function ownerColors(userId)
	local index = (math.abs(math.floor(userId)) % #OWNER_PALETTE) + 1
	return { Primary = OWNER_PALETTE[index] }
end

-------------------------------------------------------------------------------
-- Posição: zonas, chão e distância
-------------------------------------------------------------------------------

-- Partes onde se pode pôr torreta (ctx.TurretZones; sem zonas, usa a FieldArea).
local function getZones()
	local ctx = getContext()
	local list = {}
	if ctx and type(ctx.TurretZones) == "table" then
		for _, zone in ipairs(ctx.TurretZones) do
			if typeof(zone) == "Instance" and zone:IsA("BasePart") then
				table.insert(list, zone)
			end
		end
	end
	if #list == 0 and ctx and typeof(ctx.FieldArea) == "Instance" and ctx.FieldArea:IsA("BasePart") then
		table.insert(list, ctx.FieldArea)
	end
	return list
end

-- O ponto está dentro de alguma zona? Teste no espaço da parte, só X/Z (seção 8.10).
local function isInsideZones(position)
	local zones = getZones()
	if #zones == 0 then
		return true -- mapa sem zonas definidas: não restringe
	end
	for _, zone in ipairs(zones) do
		local localPoint = zone.CFrame:PointToObjectSpace(position)
		if math.abs(localPoint.X) <= zone.Size.X / 2 and math.abs(localPoint.Z) <= zone.Size.Z / 2 then
			return true
		end
	end
	return false
end

-- Acha o chão embaixo de um ponto (raio para baixo). Devolve posição, normal ou nil.
local function findGround(position, params)
	params = params or buildRaycastParams()
	local origin = position + Vector3.new(0, GROUND_PROBE_UP, 0)
	local result = workspace:Raycast(origin, Vector3.new(0, -GROUND_PROBE_DEPTH, 0), params)
	if not result then
		return nil
	end
	return result.Position, result.Normal
end

-- Menor distância (XZ) até outra torreta. ignoreId = torreta que não conta (ela mesma).
local function isTooCloseToOthers(position, ignoreId)
	for _, turretId in ipairs(order) do
		local turret = turrets[turretId]
		if turret and turretId ~= ignoreId and flatDistance(turret.Position, position) < MIN_TURRET_SPACING then
			return true
		end
	end
	return false
end

-- Onde a torreta de índice "index" fica quando é chamada de volta (pads de ctx.TurretBase).
-- Devolve (posição no chão, rotY).
local function getRecallSpot(index, params)
	local ctx = getContext()
	local pads = {}
	if ctx and type(ctx.TurretBase) == "table" then
		for _, pad in ipairs(ctx.TurretBase) do
			if typeof(pad) == "CFrame" then
				table.insert(pads, pad)
			end
		end
	end

	local position, rotY
	if #pads > 0 then
		-- Cada torreta vai para um pad; se houver mais torretas que pads, as extras
		-- ficam num anel em volta dos pads (nunca uma dentro da outra).
		local pad = pads[((index - 1) % #pads) + 1]
		local ring = math.floor((index - 1) / #pads)
		rotY = yawOf(pad)
		position = pad.Position
		if ring > 0 then
			local angle = ring * 2.39996 -- "ângulo de ouro": espalha bem os anéis
			position += Vector3.new(math.cos(angle), 0, math.sin(angle)) * (RECALL_RING_SPACING * ring)
		end
	else
		-- Mapa sem pads: círculo em volta do ponto de nascimento.
		local center = Vector3.zero
		local spawn = ctx and ctx.SpawnLocation
		if typeof(spawn) == "Instance" and spawn:IsA("BasePart") then
			center = spawn.Position
		end
		local angle = (index - 1) * (2 * math.pi / 10)
		position = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * FALLBACK_RECALL_RADIUS
		rotY = angle
	end

	-- Assenta no chão (o pad pode ser só um CFrame no ar ou dentro do chão).
	local ground = findGround(position + Vector3.new(0, 4, 0), params)
	if ground then
		position = ground
	end
	return position, rotY
end

-------------------------------------------------------------------------------
-- Modelo da torreta
-------------------------------------------------------------------------------

-- Atualiza o texto do prompt de modo e da plaquinha.
local function applyModeVisual(turret)
	local texts = MODE_TEXTS[turret.Mode] or MODE_TEXTS.Valuable
	if turret.ModePrompt then
		turret.ModePrompt.ActionText = texts.Action
	end
	local model = turret.Model
	local tag = model and model:FindFirstChild("OwnerTag", true)
	local label = tag and tag:FindFirstChild("Mode")
	if label and label:IsA("TextLabel") then
		label.Text = texts.Label
	end
end

-- Coloca o modelo exatamente na posição/rotação guardada na torreta.
local function pivotModel(turret)
	if turret.Model then
		turret.Model:PivotTo(CFrame.new(turret.Position) * CFrame.Angles(0, turret.RotY, 0))
	end
end

-- Posição do centro da cabeça (de onde a torreta "enxerga").
local function getHeadPosition(turret)
	local head = turret.Head
	if head and head.Parent then
		return head.Position
	end
	return turret.Position + Vector3.new(0, HEAD_HEIGHT_FALLBACK, 0)
end

-- (declaradas antes porque os prompts chamam estas funções)
local pickupTurret
local toggleMode

-- Cria (ou recria) o modelo 3D de uma torreta e conecta os prompts.
local function buildModel(turret)
	if turret.Trove then
		turret.Trove:Clean()
	end
	local trove = Trove.new()
	turret.Trove = trove

	local model = TurretFactory.Build(getOwnerName(turret.OwnerUserId), ownerColors(turret.OwnerUserId))
	model.Name = "Turret_" .. turret.Id
	model:SetAttribute("TurretId", turret.Id)
	model:SetAttribute("OwnerUserId", turret.OwnerUserId)
	trove:Add(model)

	turret.Model = model
	turret.Head = model:FindFirstChild("Head")
	turret.Muzzle = turret.Head and turret.Head:FindFirstChild("Muzzle") or nil
	turret.PickupPrompt = nil
	turret.ModePrompt = nil

	-- Acha os prompts pelo atributo ServerAction (seção 7.3) e conecta.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			local action = descendant:GetAttribute("ServerAction")
			if action == "PickupTurret" then
				turret.PickupPrompt = descendant
				trove:Connect(descendant.Triggered, function(player)
					local ok, message = pickupTurret(player, turret.Id)
					if ok then
						StateService.Notify(player, "Torreta recolhida.", "success", 2)
					else
						StateService.Notify(player, message, "error", 3)
					end
				end)
			elseif action == "TurretMode" then
				turret.ModePrompt = descendant
				trove:Connect(descendant.Triggered, function(player)
					local newMode = turret.Mode == "Valuable" and "Nearest" or "Valuable"
					local ok, message = toggleMode(player, turret.Id, newMode)
					if ok then
						StateService.Notify(player, "Torreta mirando no " .. MODE_TEXTS[newMode].Name .. ".", "info", 2)
					else
						StateService.Notify(player, message, "error", 3)
					end
				end)
			end
		end
	end

	pivotModel(turret)
	applyModeVisual(turret)
	model.Parent = getTurretsFolder()
end

-- Cria uma torreta nova (modelo + registro). Devolve a torreta.
local function spawnTurret(ownerUserId, position, rotY, mode)
	nextIdNumber += 1
	local turret = {
		Id = "T" .. nextIdNumber,
		OwnerUserId = ownerUserId,
		Model = nil,
		Position = position,
		RotY = rotY,
		Mode = (mode == "Nearest") and "Nearest" or "Valuable",
		NextShot = now(),
		Head = nil,
		Muzzle = nil,
		Trove = nil,
	}
	turrets[turret.Id] = turret
	table.insert(order, turret.Id)
	buildModel(turret)
	return turret
end

-- Remove uma torreta (modelo e registro).
local function removeTurret(turretId)
	local turret = turrets[turretId]
	if not turret then
		return
	end
	turrets[turretId] = nil
	local index = table.find(order, turretId)
	if index then
		table.remove(order, index)
	end
	if turret.Trove then
		turret.Trove:Clean()
	end
	turret.Model = nil
end

-- Muda a torreta de lugar.
local function moveTurret(turret, position, rotY)
	turret.Position = position
	turret.RotY = rotY
	pivotModel(turret)
end

-------------------------------------------------------------------------------
-- Ações (usadas pelos Requests e pelos prompts)
-------------------------------------------------------------------------------

-- Checa se o jogador está na partida (tem run).
local function hasRun(player)
	local ok, run = pcall(function()
		return getMatch().GetRun(player)
	end)
	return ok and run ~= nil
end

local function placeTurret(player, position, rotY)
	if not enabled then
		return false, NO_TURRETS_MESSAGE
	end
	if not isFiniteVector(position) or not isFiniteNumber(rotY) then
		return false, "Posição inválida."
	end
	if not hasRun(player) then
		return false, "Você ainda não entrou na partida."
	end

	-- Personagem vivo (a distância é medida a partir dele).
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return false, "Você precisa estar vivo para colocar uma torreta."
	end

	-- Limite: total do time < floor(TurretCount) + (pass "Torreta extra" ? 1 : 0).
	local max = math.min(getMaxFor(player), HARD_TURRET_CAP)
	if max <= 0 then
		return false, "Compre torretas na Barraca de Torretas primeiro!"
	end
	if #order >= max then
		return false, ("Limite de torretas atingido (%d/%d)."):format(#order, max)
	end

	-- Perto do jogador (no plano XZ, como no modo de colocação do cliente).
	if flatDistance(root.Position, position) > MAX_PLACE_DISTANCE + PLACE_DISTANCE_SLACK then
		return false, ("Muito longe! Coloque a torreta a até %d studs de você."):format(MAX_PLACE_DISTANCE)
	end

	-- Dentro de uma zona permitida.
	if not isInsideZones(position) then
		return false, "Não dá para colocar torreta aqui."
	end

	-- Assenta no chão com um raio para baixo.
	local groundPosition, normal = findGround(position)
	if not groundPosition then
		return false, "Não há chão firme aqui."
	end
	if normal.Y < MIN_GROUND_NORMAL_Y then
		return false, "O chão aqui é inclinado demais."
	end

	-- Longe das outras torretas.
	if isTooCloseToOthers(groundPosition, nil) then
		return false, "Muito perto de outra torreta."
	end

	-- Normaliza o ângulo para 0..2π.
	local cleanRotY = rotY % (2 * math.pi)
	local turret = spawnTurret(player.UserId, groundPosition, cleanRotY, "Valuable")
	onTurretsChanged()
	return true, turret.Id
end

-- Recolhe uma torreta (só o dono ou o dono da partida).
function pickupTurret(player, turretId)
	if not enabled then
		return false, NO_TURRETS_MESSAGE
	end
	if not isPlayerInGame(player) then
		return false, "Jogador inválido."
	end
	if type(turretId) ~= "string" or #turretId == 0 or #turretId > MAX_ID_LENGTH then
		return false, "Torreta inválida."
	end
	local turret = turrets[turretId]
	if not turret then
		return false, "Essa torreta não existe mais."
	end

	local hostUserId = getMatch().GetHostUserId()
	if player.UserId ~= turret.OwnerUserId and player.UserId ~= hostUserId then
		return false, "Só quem colocou a torreta (ou o dono da partida) pode recolher."
	end

	removeTurret(turretId)
	onTurretsChanged()
	return true, true
end

-- Troca o modo de mira ("Valuable" = mais valioso, "Nearest" = mais perto).
function toggleMode(player, turretId, mode)
	if not enabled then
		return false, NO_TURRETS_MESSAGE
	end
	if not isPlayerInGame(player) then
		return false, "Jogador inválido."
	end
	if type(turretId) ~= "string" or #turretId == 0 or #turretId > MAX_ID_LENGTH then
		return false, "Torreta inválida."
	end
	if mode ~= "Valuable" and mode ~= "Nearest" then
		return false, "Modo inválido."
	end
	if not hasRun(player) then
		return false, "Você ainda não entrou na partida."
	end
	local turret = turrets[turretId]
	if not turret then
		return false, "Essa torreta não existe mais."
	end

	-- Só quem colocou a torreta (ou o dono da partida) muda a mira dela: mesma regra do
	-- PickupTurret. Antes qualquer jogador trocava o modo da torreta dos outros.
	local hostUserId = getMatch().GetHostUserId()
	if player.UserId ~= turret.OwnerUserId and player.UserId ~= hostUserId then
		return false, "Essa torreta não é sua."
	end

	if turret.Mode ~= mode then
		turret.Mode = mode
		applyModeVisual(turret)
		saveTeamTurrets()
	end
	return true, true
end

-- Chama todas as torretas de volta para os pads da base.
local function recallTurrets(player)
	if not enabled then
		return false, NO_TURRETS_MESSAGE
	end
	if player ~= nil and not hasRun(player) then
		return false, "Você ainda não entrou na partida."
	end
	if #order == 0 then
		return false, "Não há torretas para chamar de volta."
	end
	local t = now()
	if t - lastRecallAt < RECALL_COOLDOWN then
		return false, "Espere um instante para chamar as torretas de novo."
	end
	lastRecallAt = t

	local params = buildRaycastParams()
	for index, turretId in ipairs(order) do
		local turret = turrets[turretId]
		if turret then
			local position, rotY = getRecallSpot(index, params)
			moveTurret(turret, position, rotY)
		end
	end
	onTurretsChanged()

	if player then
		StateService.NotifyAll(("%s chamou as torretas de volta para a base."):format(player.DisplayName), "info", 3)
	end
	return true, true
end

-------------------------------------------------------------------------------
-- Tiro (loop de 10 Hz)
-------------------------------------------------------------------------------

-- Monta a lista de alvos possíveis deste tick: {Entity, Point (centro do corpo), Value}.
local function collectCandidates(mapId, enchantPower)
	local okAlive, alive = pcall(function()
		return Svc("BrainrotService").GetAlive()
	end)
	if not okAlive or type(alive) ~= "table" then
		return {}
	end

	local list = {}
	for _, entity in ipairs(alive) do
		local def = type(entity) == "table" and entity.Def or nil
		if def and not entity.Dead and isFiniteVector(entity.Position) then
			local sizeFactor = isFiniteNumber(entity.SizeFactor) and entity.SizeFactor or 1
			local scale = (isFiniteNumber(def.BaseScale) and def.BaseScale or 1) * sizeFactor
			-- Mira no meio do corpo (Position é o ponto no chão).
			local point = entity.Position + Vector3.new(0, math.max(0.5, AIM_HEIGHT_PER_SCALE * scale), 0)
			-- Valor em moedas (para o modo "mais valioso").
			local value = 0
			if isFiniteNumber(def.BaseCoinValue) then
				value = Formulas.BrainrotCoinValue(def, mapId, sizeFactor)
					* Formulas.EnchantCoinMult(entity.Enchant, mapId, enchantPower)
			end
			table.insert(list, {
				Entity = entity,
				Point = point,
				Value = isFiniteNumber(value) and value or 0,
				Radius = math.max(1, AIM_HEIGHT_PER_SCALE * scale),
			})
		end
	end
	return list
end

-- A torreta enxerga o alvo? (raio da cabeça até o centro do alvo, só coisas sólidas bloqueiam)
local function hasLineOfSight(origin, candidate, params)
	local offset = candidate.Point - origin
	if offset.Magnitude < 0.1 then
		return true
	end
	local result = workspace:Raycast(origin, offset, params)
	if not result then
		return true
	end
	-- Bateu em algo pertinho do alvo (ex.: o chão embaixo dele): conta como visível.
	return (result.Position - candidate.Point).Magnitude <= candidate.Radius + 1
end

-- Escolhe o alvo de uma torreta: dentro do alcance, vivo, visível; o mais valioso ou o mais perto.
local function pickTarget(turret, candidates, range, params)
	local origin = getHeadPosition(turret)
	local inRange = {}
	for _, candidate in ipairs(candidates) do
		if not candidate.Entity.Dead then
			local distance = (candidate.Point - origin).Magnitude
			if distance <= range then
				table.insert(inRange, { Candidate = candidate, Distance = distance })
			end
		end
	end
	if #inRange == 0 then
		return nil
	end

	-- Ordena pela prioridade do modo.
	if turret.Mode == "Nearest" then
		table.sort(inRange, function(a, b)
			return a.Distance < b.Distance
		end)
	else
		table.sort(inRange, function(a, b)
			if a.Candidate.Value ~= b.Candidate.Value then
				return a.Candidate.Value > b.Candidate.Value
			end
			return a.Distance < b.Distance
		end)
	end

	-- Testa a linha de visão dos melhores (até LOS_CANDIDATES por tiro).
	for index = 1, math.min(LOS_CANDIDATES, #inRange) do
		local candidate = inRange[index].Candidate
		if hasLineOfSight(origin, candidate, params) then
			return candidate
		end
	end
	return nil
end

-- Ponto para onde vai um tiro errado: perto do alvo, passando um pouco dele.
local function missPoint(from, target, radius)
	local direction = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-0.3, 0.7), rng:NextNumber(-1, 1))
	if direction.Magnitude < 0.01 then
		direction = Vector3.new(1, 0, 0)
	end
	local nearTarget = target + direction.Unit * (radius * 0.5 + rng:NextNumber(MISS_MIN, MISS_MAX))
	local offset = nearTarget - from
	if offset.Magnitude < 0.1 then
		return nearTarget
	end
	return from + offset.Unit * (offset.Magnitude + MISS_OVERSHOOT)
end

-- Faz uma torreta atirar (quantas vezes a cadência mandar neste tick).
local function fireTurret(turret, shared, shots)
	local t = shared.Now
	-- Se ficou muito tempo sem atirar (sem alvo), não "acumula" tiros atrasados.
	if turret.NextShot < t - 2 * TICK_INTERVAL then
		turret.NextShot = t
	end

	local BrainrotService = shared.BrainrotService
	local shotsThisTick = 0
	while turret.NextShot <= t and shotsThisTick < MAX_SHOTS_PER_TURRET_TICK do
		local target = pickTarget(turret, shared.Candidates, shared.Range, shared.Params)
		if not target then
			return -- sem alvo: fica pronta para o próximo tick
		end

		-- Vira a cabeça para o alvo e pega a ponta do cano.
		TurretFactory.AimHead(turret.Model, target.Point)
		local from = (turret.Muzzle and turret.Muzzle.Parent) and turret.Muzzle.WorldPosition or getHeadPosition(turret)

		if rng:NextNumber() < shared.Accuracy then
			-- Acertou: dano (as moedas do abate vão para o dono, se ele estiver aqui).
			local entity = target.Entity
			local owner = Players:GetPlayerByUserId(turret.OwnerUserId)
			local ok, err = pcall(BrainrotService.Damage, entity, shared.Damage, owner, {
				Crit = false,
				Source = "Turret",
				TurretOwnerUserId = turret.OwnerUserId,
			})
			if not ok then
				warn("[TurretService] Erro ao causar dano: " .. tostring(err))
			elseif shared.Slow > 0 and not entity.Dead then
				-- Torreta Congelante: deixa o brainrot mais lento.
				pcall(BrainrotService.ApplySlow, entity, 1 - shared.Slow, GameConfig.SlowDuration)
			end
			table.insert(shots, { From = from, To = target.Point, Hit = true })
		else
			table.insert(shots, { From = from, To = missPoint(from, target.Point, target.Radius), Hit = false })
		end

		turret.NextShot += shared.Interval
		shotsThisTick += 1
	end
end

-- Um tick do loop de tiro.
local function fireTick()
	if #order == 0 then
		return
	end
	local t = now()

	-- Alguma torreta está pronta? Se nenhuma, nem calcula alvos.
	local anyReady = false
	for _, turretId in ipairs(order) do
		local turret = turrets[turretId]
		if turret and turret.NextShot <= t then
			anyReady = true
			break
		end
	end
	if not anyReady then
		return
	end

	local stats = getTeamStats()
	local damage = statNumber(stats, "TurretDamage", 0)
	local fireRate = statNumber(stats, "TurretFireRate", 0)
	local range = statNumber(stats, "TurretRange", 0)
	if damage <= 0 or fireRate <= 0 or range <= 0 then
		return
	end

	local mapId = getMatch().GetMapId()
	local candidates = collectCandidates(mapId, statNumber(stats, "EnchantPower", 1))
	if #candidates == 0 then
		return
	end

	local shared = {
		Now = t,
		Candidates = candidates,
		Damage = damage,
		Range = range,
		Interval = 1 / fireRate,
		Accuracy = math.clamp(statNumber(stats, "TurretAccuracy", 0), 0, 1),
		Slow = math.clamp(statNumber(stats, "TurretSlow", 0), 0, 0.95),
		Params = buildSightParams(),
		BrainrotService = Svc("BrainrotService"),
	}

	-- Todos os tiros deste tick vão juntos numa mensagem só.
	local shots = {}
	for _, turretId in ipairs(table.clone(order)) do
		local turret = turrets[turretId]
		if turret and turret.Model and turret.NextShot <= t then
			local ok, err = pcall(fireTurret, turret, shared, shots)
			if not ok then
				warn("[TurretService] Erro no tiro da torreta " .. turretId .. ": " .. tostring(err))
				turret.NextShot = t + shared.Interval -- evita repetir o erro a cada tick
			end
		end
	end

	if #shots > 0 then
		Net.FireAll("TurretShots", shots)
	end
end

-------------------------------------------------------------------------------
-- Vigia: garante que nenhuma torreta "some"
-------------------------------------------------------------------------------

-- O modelo da torreta está inteiro, no lugar certo e ancorado?
local function isModelHealthy(turret, folder)
	local model = turret.Model
	if not model or model.Parent ~= folder then
		return false
	end
	local base = model.PrimaryPart
	local head = turret.Head
	if not base or base.Parent ~= model or not base.Anchored then
		return false
	end
	if not head or head.Parent ~= model or not head.Anchored then
		return false
	end
	return true
end

local function watchdogTick()
	local folder = getTurretsFolder()
	local ctx = getContext()
	local groundY = (ctx and isFiniteNumber(ctx.GroundY)) and ctx.GroundY or 0
	local params = nil
	local changed = false

	for index, turretId in ipairs(table.clone(order)) do
		local turret = turrets[turretId]
		if turret then
			-- Posição perdida (muito abaixo do mapa): volta para a base.
			if turret.Position.Y < groundY - LOST_BELOW_GROUND then
				params = params or buildRaycastParams()
				local position, rotY = getRecallSpot(index, params)
				turret.Position = position
				turret.RotY = rotY
				changed = true
			end

			if not isModelHealthy(turret, folder) then
				-- Modelo apagado/quebrado: reconstrói no mesmo lugar.
				warn("[TurretService] Torreta " .. turretId .. " estava quebrada; reconstruindo.")
				buildModel(turret)
			else
				-- Alguém moveu o modelo: coloca de volta no lugar guardado.
				local pivot = turret.Model:GetPivot().Position
				if (pivot - turret.Position).Magnitude > POSITION_TOLERANCE then
					pivotModel(turret)
				end
			end
		end
	end

	if changed then
		onTurretsChanged()
	end
end

-------------------------------------------------------------------------------
-- Torretas salvas (partida continuada)
-------------------------------------------------------------------------------

local function restoreSavedTurrets()
	local okTeam, team = pcall(function()
		return getMatch().GetTeam()
	end)
	if not okTeam or type(team) ~= "table" or type(team.Turrets) ~= "table" then
		return
	end

	local params = buildRaycastParams()
	for _, saved in ipairs(table.clone(team.Turrets)) do
		if #order >= HARD_TURRET_CAP then
			break
		end
		local raw = type(saved) == "table" and saved.Position or nil
		if type(saved) == "table" and isFiniteNumber(saved.OwnerUserId) and type(raw) == "table" then
			local position = Vector3.new(tonumber(raw[1]) or 0, tonumber(raw[2]) or 0, tonumber(raw[3]) or 0)
			local rotY = isFiniteNumber(saved.RotY) and saved.RotY or 0

			-- Reassenta no chão; se o lugar não vale mais, vai para um pad da base.
			local ground = isFiniteVector(position) and findGround(position, params) or nil
			if not ground or not isInsideZones(ground) then
				ground, rotY = getRecallSpot(#order + 1, params)
			end
			spawnTurret(saved.OwnerUserId, ground, rotY, saved.Mode)
		end
	end
end

-------------------------------------------------------------------------------
-- Ciclo de vida
-------------------------------------------------------------------------------

function TurretService.Init()
	if initialized then
		return
	end
	initialized = true

	-- Este mapa tem torretas?
	local okDef, mapDef = pcall(function()
		return getMatch().GetMapDef()
	end)
	enabled = okDef and type(mapDef) == "table" and mapDef.HasTurrets == true

	-- Requests (registrados sempre: nos mapas sem torretas respondem com a mensagem).
	Net.Handle("PlaceTurret", function(player, position, rotY)
		return placeTurret(player, position, rotY)
	end, { Rate = 2, Burst = 4 })

	Net.Handle("PickupTurret", function(player, turretId)
		return pickupTurret(player, turretId)
	end, { Rate = 4, Burst = 8 })

	Net.Handle("RecallTurrets", function(player)
		return recallTurrets(player)
	end, { Rate = 1, Burst = 3 })

	Net.Handle("SetTurretMode", function(player, turretId, mode)
		return toggleMode(player, turretId, mode)
	end, { Rate = 4, Burst = 8 })

	if not enabled then
		return
	end

	getTurretsFolder()

	Players.PlayerRemoving:Connect(function(player)
		overridePlayers[player] = nil
	end)
end

function TurretService.Start()
	if started or not enabled then
		return
	end
	started = true

	-- Botão da Estação de Respawn de Torretas (ServerAction = "RecallTurrets").
	local ctx = getContext()
	local recallPrompt = ctx and ctx.RecallPrompt
	if typeof(recallPrompt) == "Instance" and recallPrompt:IsA("ProximityPrompt") then
		recallPrompt.Triggered:Connect(function(player)
			local ok, message = recallTurrets(player)
			if not ok then
				StateService.Notify(player, message, "warning", 3)
			end
		end)
	end

	-- Torretas da partida salva.
	local okRestore, restoreErr = pcall(restoreSavedTurrets)
	if not okRestore then
		warn("[TurretService] Erro ao recriar as torretas salvas: " .. tostring(restoreErr))
	end
	saveTeamTurrets()
	publishState()

	-- Stats mudaram (upgrade "Mais Torretas", game pass...): recalcula o Max.
	local okStats, statErr = pcall(function()
		Svc("StatService").Changed:Connect(function()
			publishState()
		end)
	end)
	if not okStats then
		warn("[TurretService] Não foi possível escutar StatService.Changed: " .. tostring(statErr))
	end

	-- Jogador entrou (ou voltou): estado dele e o nome certo nas torretas dele.
	local okRun, runErr = pcall(function()
		getMatch().RunReady:Connect(function(player)
			if isPlayerInGame(player) then
				ownerNames[player.UserId] = player.DisplayName
				refreshOwnerTags(player.UserId, player.DisplayName)
			end
			publishState()
		end)
	end)
	if not okRun then
		warn("[TurretService] Não foi possível escutar MatchService.RunReady: " .. tostring(runErr))
	end

	-- Loop de tiro (10 Hz).
	task.spawn(function()
		while true do
			local ok, err = pcall(fireTick)
			if not ok then
				warn("[TurretService] Erro no loop das torretas: " .. tostring(err))
			end
			task.wait(TICK_INTERVAL)
		end
	end)

	-- Vigia das torretas.
	task.spawn(function()
		while true do
			task.wait(WATCHDOG_INTERVAL)
			local ok, err = pcall(watchdogTick)
			if not ok then
				warn("[TurretService] Erro no vigia das torretas: " .. tostring(err))
			end
		end
	end)
end

return TurretService
