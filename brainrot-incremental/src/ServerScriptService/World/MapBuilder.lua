--!nonstrict
-- MapBuilder: monta o mapa (lobby ou partida) e cuida das partes "vivas" dele (seção 7.1).
--
--   MapBuilder.Build(mapId) -> ctx
--       mapId ∈ "Lobby", "Meadow", "Winter", "Desert".
--       Apaga o workspace.Map antigo (e o Baseplate padrão do Studio), aplica a iluminação
--       do mapa (Config.Maps[mapId].Lighting; o Lobby tem iluminação própria no builder dele),
--       chama Builders[mapId].Build(pasta) e coloca a pasta pronta em workspace.Map.
--       Devolve o contexto (ctx) com as peças importantes do mapa (seção 7.2).
--
--   MapBuilder.SetShelfLevel(ctx, level)
--       Mostra as prateleiras de nível <= level em todas as barracas; as outras ficam
--       invisíveis e sem colisão.
--
--   MapBuilder.OpenPortal(ctx, targetDisplayName) -> ProximityPrompt
--       Cria (uma vez só) um portal girando em ctx.PortalSpot, com um prompt
--       ServerAction = "Portal", e devolve esse prompt.
--
-- A iluminação é aplicada ANTES do builder: assim o Deserto consegue calcular a direção
-- do sol (Lighting:GetSunDirection) para posicionar a Grande Cova.
--
-- Módulo de World: NÃO dá require em nenhum serviço (regra 1.2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Maps = require(Shared:WaitForChild("Config"):WaitForChild("Maps"))

local BuildersFolder = script.Parent:WaitForChild("Builders")
local Common = require(BuildersFolder:WaitForChild("Common"))

local MapBuilder = {}

-------------------------------------------------------------------------------
-- Constantes técnicas (visual do portal), não são balanceamento
-------------------------------------------------------------------------------

local VALID_MAPS = { Lobby = true, Meadow = true, Winter = true, Desert = true }

local PORTAL_RADIUS = 6 -- raio do anel do portal (studs)
local PORTAL_SEGMENTS = 20 -- quantas peças formam o anel
local PORTAL_SPIN_SPEED = 1.2 -- velocidade de giro (radianos por segundo)
local PORTAL_HEIGHT = PORTAL_RADIUS + 1.5 -- altura do centro do anel acima do chão
local PORTAL_COLOR_A = Color3.fromRGB(190, 90, 255)
local PORTAL_COLOR_B = Color3.fromRGB(255, 110, 200)
local PORTAL_CORE_COLOR = Color3.fromRGB(150, 70, 235)
local ORB_ON_COLOR = Color3.fromRGB(220, 140, 255)

-- Portais já abertos (chave = ctx). Tabela "fraca": some junto com o ctx.
local openPortals = setmetatable({}, { __mode = "k" })

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Apaga o mapa anterior, o Baseplate padrão e SpawnLocations soltas no Workspace
-- (senão o jogador poderia nascer no spawn padrão do template em vez do nosso).
local function clearOldWorld()
	local oldMap = workspace:FindFirstChild("Map")
	while oldMap do
		oldMap:Destroy()
		oldMap = workspace:FindFirstChild("Map")
	end

	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate then
		baseplate:Destroy()
	end

	for _, child in ipairs(workspace:GetChildren()) do
		if child:IsA("SpawnLocation") then
			child:Destroy()
		end
	end
end

-- Confere se o ctx de uma partida tem tudo que os serviços usam (só avisa no Output).
local function validateMatchContext(mapId, ctx)
	local missing = {}
	local function need(condition, name)
		if not condition then
			table.insert(missing, name)
		end
	end

	local function isPart(value)
		return typeof(value) == "Instance" and value:IsA("BasePart")
	end
	local function isPrompt(value)
		return typeof(value) == "Instance" and value:IsA("ProximityPrompt")
	end

	need(typeof(ctx.SpawnLocation) == "Instance" and ctx.SpawnLocation:IsA("SpawnLocation"), "SpawnLocation")
	need(type(ctx.GroundY) == "number", "GroundY")
	need(isPart(ctx.FieldArea), "FieldArea")
	need(isPart(ctx.Board), "Board")
	need(isPrompt(ctx.BoardPrompt), "BoardPrompt")
	need(isPart(ctx.Crate), "Crate")
	need(typeof(ctx.CoinDropPoint) == "Vector3", "CoinDropPoint")
	need(typeof(ctx.PortalSpot) == "CFrame", "PortalSpot")
	need(type(ctx.Stalls) == "table", "Stalls")

	local mapDef = Maps[mapId]
	if mapDef then
		for _, stallId in ipairs(mapDef.Stalls or {}) do
			need(type(ctx.Stalls) == "table" and ctx.Stalls[stallId] ~= nil, "Stalls." .. tostring(stallId))
		end
		if mapDef.HasTurrets then
			need(type(ctx.TurretZones) == "table" and #ctx.TurretZones > 0, "TurretZones")
			need(type(ctx.TurretBase) == "table" and #ctx.TurretBase >= 10, "TurretBase (>= 10)")
			need(isPrompt(ctx.RecallPrompt), "RecallPrompt")
		end
		if mapDef.HasRecipes then
			need(isPart(ctx.Cauldron), "Cauldron")
		end
		if mapDef.HasSupreme then
			need(typeof(ctx.Pit) == "Vector3", "Pit")
			need(isPrompt(ctx.PitPrompt), "PitPrompt")
			need(typeof(ctx.OasisCenter) == "Vector3", "OasisCenter")
			need(type(ctx.OasisRadius) == "number", "OasisRadius")
		end
	end
	if mapId == "Winter" then
		need(isPart(ctx.Platform), "Platform")
		need(isPart(ctx.SnowEmitterPart), "SnowEmitterPart")
	end

	if #missing > 0 then
		warn(("[MapBuilder] O mapa %s está sem: %s"):format(mapId, table.concat(missing, ", ")))
	end
end

-- Confere o ctx do lobby (seção 7.2).
local function validateLobbyContext(ctx)
	local missing = {}
	for _, key in ipairs({ "SpawnLocation", "CreateTerminal", "PartyBoard", "Leaderboard", "ShopStand", "AchievementsStand" }) do
		if typeof(ctx[key]) ~= "Instance" then
			table.insert(missing, key)
		end
	end
	local leaderboard = ctx.Leaderboard
	local gui = typeof(leaderboard) == "Instance" and leaderboard:FindFirstChild("Board")
	if not (gui and gui:FindFirstChild("List")) then
		table.insert(missing, "Leaderboard.Board.List")
	end
	if #missing > 0 then
		warn("[MapBuilder] O lobby está sem: " .. table.concat(missing, ", "))
	end
end

-------------------------------------------------------------------------------
-- API pública
-------------------------------------------------------------------------------

-- Monta o mapa pedido e devolve o contexto dele.
function MapBuilder.Build(mapId)
	if type(mapId) ~= "string" or not VALID_MAPS[mapId] then
		error(("[MapBuilder] Mapa desconhecido: %s"):format(tostring(mapId)), 2)
	end
	local builderModule = BuildersFolder:FindFirstChild(mapId)
	if not builderModule or not builderModule:IsA("ModuleScript") then
		error(("[MapBuilder] Não achei o builder World/Builders/%s"):format(mapId), 2)
	end
	local builder = require(builderModule)

	-- 1. Limpa o mundo antigo e os efeitos de iluminação do mapa anterior.
	clearOldWorld()
	Common.ClearLightingEffects()

	-- 2. Iluminação do mapa (antes do builder, por causa do sol do Deserto).
	local mapDef = Maps[mapId]
	if type(mapDef) == "table" and type(mapDef.Lighting) == "table" then
		Common.ApplyLighting(mapDef.Lighting)
	end

	-- 3. Monta tudo dentro de uma pasta ainda fora do Workspace (bem mais rápido:
	--    o Roblox replica a pasta inteira de uma vez quando ela entra no mundo).
	local folder = Instance.new("Folder")
	folder.Name = "Map"
	folder:SetAttribute("MapId", mapId)

	local ok, result = pcall(builder.Build, folder)
	if not ok then
		folder:Destroy()
		error(("[MapBuilder] Erro ao montar o mapa %s: %s"):format(mapId, tostring(result)), 0)
	end
	if type(result) ~= "table" then
		folder:Destroy()
		error(("[MapBuilder] O builder de %s não devolveu um contexto."):format(mapId), 0)
	end

	local ctx = result
	ctx.MapId = mapId
	ctx.Folder = folder

	-- 4. Coloca o mapa no mundo.
	folder.Parent = workspace

	-- 5. Confere o contexto e deixa só a prateleira 1 visível nas partidas.
	if mapId == "Lobby" then
		validateLobbyContext(ctx)
	else
		validateMatchContext(mapId, ctx)
		MapBuilder.SetShelfLevel(ctx, 1)
	end

	return ctx
end

-- Mostra as prateleiras de nível <= level em todas as barracas.
function MapBuilder.SetShelfLevel(ctx, level)
	if type(ctx) ~= "table" or type(ctx.Stalls) ~= "table" then
		return
	end
	local shelfLevel = tonumber(level)
	if shelfLevel == nil or shelfLevel ~= shelfLevel or shelfLevel == math.huge or shelfLevel == -math.huge then
		shelfLevel = 1 -- valor inválido (nil, NaN, infinito): volta ao começo
	end
	shelfLevel = math.floor(shelfLevel)

	for _, stall in pairs(ctx.Stalls) do
		if type(stall) == "table" and type(stall.Shelves) == "table" then
			for shelf, parts in pairs(stall.Shelves) do
				if type(shelf) == "number" and type(parts) == "table" then
					Common.SetVisible(parts, shelf <= shelfLevel)
				end
			end
		end
	end
end

-- Acende os orbes da base do portal (peças "PortalOrb" criadas pelo Common.PortalPad).
local function lightPortalOrbs(folder)
	if typeof(folder) ~= "Instance" then
		return
	end
	for _, descendant in ipairs(folder:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.Name == "PortalOrb" then
			descendant.Material = Enum.Material.Neon
			descendant.Color = ORB_ON_COLOR
			if not descendant:FindFirstChildOfClass("PointLight") then
				local light = Instance.new("PointLight")
				light.Color = ORB_ON_COLOR
				light.Range = 12
				light.Brightness = 1.5
				light.Shadows = false
				light.Parent = descendant
			end
		end
	end
end

-- Onde o portal aparece: ctx.PortalSpot, ou (se faltar) perto do spawn.
local function resolvePortalSpot(ctx)
	if typeof(ctx.PortalSpot) == "CFrame" then
		return ctx.PortalSpot
	end
	local spawnPart = ctx.SpawnLocation
	if typeof(spawnPart) == "Instance" and spawnPart:IsA("BasePart") then
		warn("[MapBuilder] ctx.PortalSpot não existe; o portal vai aparecer perto do spawn.")
		local base = spawnPart.Position - Vector3.new(0, spawnPart.Size.Y / 2, 0)
		return CFrame.new(base + Vector3.new(0, 0, 16))
	end
	warn("[MapBuilder] ctx.PortalSpot não existe; o portal vai aparecer na origem.")
	return CFrame.new(0, 0, 0)
end

-- Cria (ou devolve, se já existe) o portal girando em ctx.PortalSpot.
function MapBuilder.OpenPortal(ctx, targetDisplayName)
	if type(ctx) ~= "table" then
		error("[MapBuilder] OpenPortal precisa do contexto do mapa.", 2)
	end
	local targetName = if type(targetDisplayName) == "string" and targetDisplayName ~= "" then targetDisplayName else "o próximo mapa"
	local objectText = "Portal para " .. targetName

	-- Já aberto: só atualiza o texto e devolve o mesmo prompt.
	local existing = openPortals[ctx]
	if existing and existing.Prompt and existing.Prompt.Parent then
		existing.Prompt.ObjectText = objectText
		existing.Label.Text = objectText
		return existing.Prompt
	end

	local parent = ctx.Folder
	if typeof(parent) ~= "Instance" or not parent:IsDescendantOf(workspace) then
		parent = workspace
	end

	local spot = resolvePortalSpot(ctx)
	local center = spot * CFrame.new(0, PORTAL_HEIGHT, 0)

	local model = Common.Model("Portal", parent)

	-- Âncora fixa (ancorada): segura o anel, o prompt, a luz e as partículas.
	local anchor = Common.Part({
		Name = "PortalAnchor",
		Size = Vector3.new(1, 1, 1),
		CFrame = center,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
		Parent = model,
	})

	-- Cubo do anel (solto): todas as peças do anel são soldadas nele e ele gira
	-- preso à âncora por uma dobradiça com motor. A física do Roblox replica o giro
	-- suavemente para todos os jogadores (bem melhor que mudar o CFrame a cada frame).
	local hub = Common.Part({
		Name = "PortalHub",
		Size = Vector3.new(1, 1, 1),
		CFrame = center,
		Transparency = 1,
		Anchored = false,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
		Parent = model,
	})

	-- Função que prende uma peça no cubo (solda) para girar junto.
	local function attachToHub(part)
		part.Anchored = false
		part.Massless = true
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hub
		weld.Part1 = part
		weld.Parent = part
	end

	-- Anel: segmentos em volta do centro, no plano de frente para quem chega.
	local segmentLength = 2 * math.pi * PORTAL_RADIUS / PORTAL_SEGMENTS * 1.12
	for index = 1, PORTAL_SEGMENTS do
		local angle = (index / PORTAL_SEGMENTS) * math.pi * 2
		local offset = CFrame.new(math.cos(angle) * PORTAL_RADIUS, math.sin(angle) * PORTAL_RADIUS, 0)
			* CFrame.Angles(0, 0, angle + math.pi / 2)
		local segment = Common.Part({
			Name = "PortalRing",
			Size = Vector3.new(segmentLength, 1.1, 1.1),
			CFrame = center * offset,
			Color = if index % 2 == 0 then PORTAL_COLOR_A else PORTAL_COLOR_B,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
			Parent = model,
		})
		attachToHub(segment)
	end

	-- Miolo do portal: disco brilhante meio transparente (gira junto com o anel).
	local core = Common.Part({
		Name = "PortalCore",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, PORTAL_RADIUS * 2 - 1.2, PORTAL_RADIUS * 2 - 1.2),
		-- O eixo do cilindro é o X; girar 90° no Y deixa o disco de frente (normal = LookVector).
		CFrame = center * CFrame.Angles(0, math.pi / 2, 0),
		Color = PORTAL_CORE_COLOR,
		Material = Enum.Material.ForceField,
		Transparency = 0.1,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
		Parent = model,
	})
	attachToHub(core)

	-- Dobradiça com motor: gira em volta do eixo que atravessa o portal (Z local do centro).
	-- O eixo de uma dobradiça é o X do Attachment, então montamos o Attachment com X = Z local.
	local axisFrame = CFrame.fromMatrix(Vector3.zero, Vector3.zAxis, Vector3.yAxis)
	local anchorAttachment = Instance.new("Attachment")
	anchorAttachment.Name = "SpinAxis"
	anchorAttachment.CFrame = axisFrame
	anchorAttachment.Parent = anchor
	local hubAttachment = Instance.new("Attachment")
	hubAttachment.Name = "SpinAxis"
	hubAttachment.CFrame = axisFrame
	hubAttachment.Parent = hub

	local hinge = Instance.new("HingeConstraint")
	hinge.Name = "Spin"
	hinge.Attachment0 = anchorAttachment
	hinge.Attachment1 = hubAttachment
	hinge.ActuatorType = Enum.ActuatorType.Motor
	hinge.AngularVelocity = PORTAL_SPIN_SPEED
	hinge.MotorMaxTorque = 1e8
	hinge.MotorMaxAcceleration = 50
	hinge.Parent = anchor

	-- Partículas brilhantes saindo do portal e uma luz roxa.
	local particles = Instance.new("ParticleEmitter")
	particles.Name = "PortalSparkles"
	particles.Color = ColorSequence.new(PORTAL_COLOR_A, PORTAL_COLOR_B)
	particles.LightEmission = 1
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.Lifetime = NumberRange.new(1, 1.8)
	particles.Rate = 25
	particles.Speed = NumberRange.new(2, 5)
	particles.SpreadAngle = Vector2.new(180, 180)
	particles.RotSpeed = NumberRange.new(-90, 90)
	particles.Parent = anchor

	local light = Instance.new("PointLight")
	light.Color = PORTAL_COLOR_A
	light.Range = 22
	light.Brightness = 2
	light.Shadows = false
	light.Parent = anchor

	-- Texto flutuante acima do portal.
	local billboard = Common.Billboard(anchor, objectText, Vector3.new(0, PORTAL_RADIUS + 3, 0))
	local label = billboard:FindFirstChild("Text")
	if label then
		label.TextColor3 = Color3.fromRGB(240, 200, 255)
	end

	-- Prompt na âncora (parada, fácil de mirar). Quem trata é o ProgressionService.
	local prompt = Common.Prompt(anchor, "Entrar no portal", objectText, { ServerAction = "Portal" })

	-- Orbes da base acesos.
	lightPortalOrbs(ctx.Folder)

	-- A física do anel fica no servidor (nenhum jogador "puxa" o portal para si).
	pcall(function()
		hub:SetNetworkOwner(nil)
	end)

	openPortals[ctx] = { Model = model, Prompt = prompt, Label = label or { Text = "" } }
	return prompt
end

return MapBuilder
