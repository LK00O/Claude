--!nonstrict
-- MapBuilder: monta o mapa (lobby ou partida) e cuida das partes "vivas" dele (seção 7.1).
--
--   MapBuilder.Build(mapId) -> ctx
--       mapId ∈ "Lobby", "Meadow", "Winter", "Desert".
--       Apaga o workspace.Map antigo (e o Baseplate padrão do Studio), limpa o terreno
--       (voxels, nuvens) e os efeitos do mapa anterior, aplica a iluminação do mapa
--       (Config.Maps[mapId].Lighting; o Lobby usa Config.Lobby.Lighting), chama
--       Builders[mapId].Build(pasta) e coloca a pasta pronta em workspace.Map.
--       Devolve o contexto (ctx) com as peças importantes do mapa (seção 7.2).
--
--   MapBuilder.SetShelfLevel(ctx, level)
--       Mostra as prateleiras de nível <= level em todas as barracas; as outras ficam
--       invisíveis e sem colisão.
--
--   MapBuilder.OpenPortal(ctx, targetDisplayName) -> ProximityPrompt
--       Cria (uma vez só) um portal em ctx.PortalSpot, com um prompt ServerAction = "Portal",
--       e devolve esse prompt. Tudo é ancorado (sem física): o anel tem a tag "AmbientSpin"
--       e quem gira é o cliente (AmbientController), sem custo para o servidor.
--
-- A iluminação é aplicada ANTES do builder: assim o Deserto consegue calcular a direção
-- do sol (Lighting:GetSunDirection) para posicionar a Grande Cova. Depois do builder ela é
-- aplicada DE NOVO: a config sempre vence (um builder não deve mexer na luz; se algum ainda
-- mexer, o valor da config volta no fim da montagem).
--
-- Módulo de World: NÃO dá require em nenhum serviço (regra 1.2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ConfigFolder = Shared:WaitForChild("Config")
local Maps = require(ConfigFolder:WaitForChild("Maps"))
local LobbyConfig = require(ConfigFolder:WaitForChild("Lobby"))

local BuildersFolder = script.Parent:WaitForChild("Builders")
local Common = require(BuildersFolder:WaitForChild("Common"))

local MapBuilder = {}

-------------------------------------------------------------------------------
-- Constantes técnicas (visual do portal), não são balanceamento
-------------------------------------------------------------------------------

local VALID_MAPS = { Lobby = true, Meadow = true, Winter = true, Desert = true }

local PORTAL_RADIUS = 6 -- raio do anel do portal (studs)
local PORTAL_SEGMENTS = 20 -- quantas peças formam o anel
local PORTAL_SPIN_SPEED = 1.2 -- velocidade de giro do anel (radianos por segundo; o cliente gira)
local PORTAL_SWIRL_SPEED = -0.8 -- o segundo redemoinho do miolo gira ao contrário
local PORTAL_HEIGHT = PORTAL_RADIUS + 1.5 -- altura do centro do anel acima do chão
local PORTAL_COLOR_A = Color3.fromRGB(190, 90, 255)
local PORTAL_COLOR_B = Color3.fromRGB(255, 110, 200)
local PORTAL_CORE_COLOR = Color3.fromRGB(150, 70, 235)
local ORB_ON_COLOR = Color3.fromRGB(220, 140, 255)
-- Textura do miolo (arquivo que já vem com o Roblox; não precisa de upload).
local PORTAL_BEAM_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local PORTAL_BEAM_TEXTURE_SPEED = 0.5

-- Atributo que marca coisas criadas pelo mapa (nuvens no Terrain, efeitos no Lighting).
local MAP_EFFECT_ATTRIBUTE = "MapEffect"
local SPIN_TAG = "AmbientSpin"

-- Portais já abertos (chave = ctx). Tabela "fraca": some junto com o ctx.
local openPortals = setmetatable({}, { __mode = "k" })

-------------------------------------------------------------------------------
-- Ajudantes
-------------------------------------------------------------------------------

-- Apaga o mapa anterior, o terreno dele, o Baseplate padrão e SpawnLocations soltas no
-- Workspace (senão o jogador poderia nascer no spawn padrão do template em vez do nosso).
local function clearOldWorld()
	local oldMap = workspace:FindFirstChild("Map")
	while oldMap do
		oldMap:Destroy()
		oldMap = workspace:FindFirstChild("Map")
	end

	-- Terreno: os mapas geram o terreno na hora (nada feito à mão no Studio fica). Na troca
	-- lobby -> partida do Studio, sem isso a grama, os morros e o lago do lobby sobrariam.
	local terrain = workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local ok, err = pcall(function()
			terrain:Clear()
		end)
		if not ok then
			warn("[MapBuilder] Não deu para limpar o terreno: " .. tostring(err))
		end
		-- Nuvens e outras coisas do mapa presas no Terrain.
		for _, child in ipairs(terrain:GetChildren()) do
			if child:GetAttribute(MAP_EFFECT_ATTRIBUTE) == true then
				child:Destroy()
			end
		end
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

-- Tabela de iluminação do mapa: Config.Lobby.Lighting para o lobby (ele não está em
-- Config.Maps) ou Config.Maps[mapId].Lighting para as partidas. nil se não tiver.
local function getLightingConfig(mapId)
	if mapId == "Lobby" then
		return if type(LobbyConfig.Lighting) == "table" then LobbyConfig.Lighting else nil
	end
	local mapDef = Maps[mapId]
	if type(mapDef) == "table" and type(mapDef.Lighting) == "table" then
		return mapDef.Lighting
	end
	return nil
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

	-- 1. Limpa o mundo antigo (mapa, terreno) e os efeitos do mapa anterior
	--    (pós-processamento, céu, nuvens, vento e cores do terreno).
	clearOldWorld()
	Common.ClearLightingEffects()

	-- 2. Iluminação do mapa (antes do builder, por causa do sol do Deserto).
	--    Sem config de luz, aplica só a BASE (nada do mapa anterior sobra).
	local lightingConfig = getLightingConfig(mapId) or {}
	Common.ApplyLighting(lightingConfig)

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

	-- 3b. A luz da config de novo: se o builder mexeu na luz (builders antigos chamavam
	--     SetSun/LightingEffect), a config volta a valer. Tudo no mesmo frame: não pisca.
	Common.ApplyLighting(lightingConfig)

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

-- Peça invisível e ancorada que segura coisas do portal (anexos dos feixes, prompt, luz...).
local function portalHelperPart(name, cframe, parent)
	return Common.Part({
		Name = name,
		Size = Vector3.new(1, 1, 1),
		CFrame = cframe,
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Parent = parent,
	})
end

-- Um feixe (Beam) de fumaça brilhante atravessando o anel de cima a baixo, com a largura do
-- anel: a textura redonda e macia vira um "disco" de energia. roll gira o feixe no plano do
-- portal (dois feixes cruzados ficam mais cheios).
-- Os Attachments ficam com o eixo X na direção do feixe e o eixo Y atravessando o portal,
-- assim o feixe fica deitado no plano do anel (FaceCamera = false).
local function addCoreBeam(hub, name, roll, colorA, colorB, textureSpeed)
	local radius = PORTAL_RADIUS - 0.6
	local rollFrame = CFrame.Angles(0, 0, roll)
	local down, through = Vector3.new(0, -1, 0), Vector3.new(0, 0, 1)

	local top = Instance.new("Attachment")
	top.Name = name .. "Top"
	top.CFrame = rollFrame * CFrame.fromMatrix(Vector3.new(0, radius, 0), down, through)
	top.Parent = hub

	local bottom = Instance.new("Attachment")
	bottom.Name = name .. "Bottom"
	bottom.CFrame = rollFrame * CFrame.fromMatrix(Vector3.new(0, -radius, 0), down, through)
	bottom.Parent = hub

	local beam = Instance.new("Beam")
	beam.Name = name
	beam.Attachment0 = top
	beam.Attachment1 = bottom
	beam.FaceCamera = false
	beam.Width0 = radius * 2
	beam.Width1 = radius * 2
	beam.Segments = 1
	beam.Texture = PORTAL_BEAM_TEXTURE
	beam.TextureMode = Enum.TextureMode.Stretch
	beam.TextureLength = 1
	beam.TextureSpeed = textureSpeed
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new(colorA, colorB)
	-- Mais transparente nas pontas (0,8) e mais forte no meio (0,3).
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.5, 0.3),
		NumberSequenceKeypoint.new(1, 0.8),
	})
	beam.Parent = hub
	return beam
end

-- Cria (ou devolve, se já existe) o portal em ctx.PortalSpot.
-- Tudo ancorado: o servidor não roda física nenhuma. O anel e o redemoinho do miolo têm a
-- tag "AmbientSpin" (eixo = Z do portal) e cada cliente gira os dois localmente.
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

	-- Âncora fixa: segura o prompt, a luz, as partículas e o texto (não gira).
	local anchor = portalHelperPart("PortalAnchor", center, model)

	-- Anel: segmentos Neon em volta do centro, no plano de frente para quem chega.
	-- Fica num modelo próprio com a peça "PortalHub" no centro (PrimaryPart = pivô do giro).
	local ring = Common.Model("PortalRing", model)
	local hub = portalHelperPart("PortalHub", center, ring)
	ring.PrimaryPart = hub
	local segmentLength = 2 * math.pi * PORTAL_RADIUS / PORTAL_SEGMENTS * 1.12
	for index = 1, PORTAL_SEGMENTS do
		local angle = (index / PORTAL_SEGMENTS) * math.pi * 2
		local offset = CFrame.new(math.cos(angle) * PORTAL_RADIUS, math.sin(angle) * PORTAL_RADIUS, 0)
			* CFrame.Angles(0, 0, angle + math.pi / 2)
		Common.Part({
			Name = "PortalRing",
			Size = Vector3.new(segmentLength, 1.1, 1.1),
			CFrame = center * offset,
			Color = if index % 2 == 0 then PORTAL_COLOR_A else PORTAL_COLOR_B,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
			Parent = ring,
		})
	end
	-- Primeiro feixe do miolo: gira junto com o anel.
	addCoreBeam(hub, "PortalCoreA", 0, PORTAL_CORE_COLOR, PORTAL_COLOR_B, PORTAL_BEAM_TEXTURE_SPEED)
	Common.Tag(ring, SPIN_TAG, { Axis = Vector3.zAxis, Speed = PORTAL_SPIN_SPEED })

	-- Segundo feixe: num modelo à parte que gira para o outro lado (efeito de redemoinho).
	local swirl = Common.Model("PortalSwirl", model)
	local swirlHub = portalHelperPart("PortalSwirlHub", center, swirl)
	swirl.PrimaryPart = swirlHub
	addCoreBeam(swirlHub, "PortalCoreB", math.pi / 2, PORTAL_COLOR_A, PORTAL_CORE_COLOR, -PORTAL_BEAM_TEXTURE_SPEED)
	Common.Tag(swirl, SPIN_TAG, { Axis = Vector3.zAxis, Speed = PORTAL_SWIRL_SPEED })

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
	-- (Common.Prompt já põe a tag "GamePrompt".)
	local prompt = Common.Prompt(anchor, "Entrar no portal", objectText, { ServerAction = "Portal" })

	-- Orbes da base acesos.
	lightPortalOrbs(ctx.Folder)

	openPortals[ctx] = { Model = model, Prompt = prompt, Label = label or { Text = "" } }
	return prompt
end

return MapBuilder
