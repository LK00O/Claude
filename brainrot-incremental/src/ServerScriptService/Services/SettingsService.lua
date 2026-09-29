-- SettingsService: recebe as configurações do jogador (sensibilidade, FOV, volumes,
-- teclas...) e grava no perfil. Funciona no lobby e na partida.
--
-- O cliente manda uma tabela com os campos que quer mudar. O servidor NUNCA confia
-- no que chega: confere o tipo de cada campo, limita os números às faixas permitidas
-- e ignora qualquer coisa desconhecida.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Util.Net)
local KeybindsConfig = require(Shared.Config.Keybinds)

local DataService = require(script.Parent:WaitForChild("DataService"))

local SettingsService = {}

-- Faixas permitidas para cada configuração numérica (seção 8.15 da especificação).
local NUMBER_RANGES = {
	Sensitivity = { 0.05, 2 },
	FOV = { 60, 110 },
	MusicVolume = { 0, 1 },
	SfxVolume = { 0, 1 },
	-- Força do tremor da câmera (0 = desligado, 1 = normal).
	CameraShake = { 0, 1 },
	-- Qualidade dos efeitos: 0 = automática (segue o gráfico do Roblox), 1 = baixa,
	-- 2 = média, 3 = alta. Só aceita número inteiro (ver INTEGER_FIELDS).
	EffectsQuality = { 0, 3 },
	-- Tamanho da interface (0,85 = menor, 1 = normal, 1,25 = maior).
	UIScale = { 0.85, 1.25 },
	-- Volume dos sons de ambiente (vento, pássaros...).
	AmbientVolume = { 0, 1 },
}

-- Configurações numéricas que precisam ser inteiras (arredondadas antes de limitar).
local INTEGER_FIELDS = {
	EffectsQuality = true,
}

-- Configurações que são verdadeiro/falso.
local BOOLEAN_FIELDS = {
	InvertY = true,
	ToggleSprint = true,
	DamageNumbers = true,
	-- Balanço da câmera ao andar.
	ViewBob = true,
	-- Mira assistida (só toque e controle; nunca no mouse).
	AimAssist = true,
	-- Tiro automático no celular: atira sozinho enquanto a mira estiver num brainrot.
	AutoFire = true,
}

-- Limites técnicos contra pedidos exagerados (o cliente pode mandar qualquer coisa).
local MAX_KEYBIND_ENTRIES = 64
local MAX_NAME_LENGTH = 64

-- Nomes válidos de Enum.KeyCode (montado uma vez só). "Unknown" não conta como tecla.
local VALID_KEY_NAMES = {}
for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
	if item ~= Enum.KeyCode.Unknown then
		VALID_KEY_NAMES[item.Name] = true
	end
end

-- Número "de verdade": não é NaN nem infinito.
local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Valida o mapa de teclas: {actionId = "NomeDaTecla"}.
-- Só aceita ações que existem em Config.Keybinds e teclas que existem em Enum.KeyCode.
-- Guarda só as teclas diferentes do padrão (o perfil guarda "só os alterados").
-- Devolve a tabela limpa ou nil se o formato for inválido.
local function sanitizeKeybinds(input)
	if type(input) ~= "table" then
		return nil
	end

	local result = {}
	local count = 0
	for actionId, keyName in pairs(input) do
		count += 1
		if count > MAX_KEYBIND_ENTRIES then
			break
		end

		if
			type(actionId) == "string"
			and #actionId <= MAX_NAME_LENGTH
			and type(keyName) == "string"
			and #keyName <= MAX_NAME_LENGTH
		then
			local action = KeybindsConfig.ById[actionId]
			if action and VALID_KEY_NAMES[keyName] then
				-- Igual ao padrão? Não precisa guardar.
				if not (action.Default and action.Default.Name == keyName) then
					result[actionId] = keyName
				end
			end
		end
	end
	return result
end

-- Aplica no perfil os campos válidos que vieram do cliente. Devolve quantos campos mudaram.
local function applySettings(settings, input)
	local changed = 0

	-- Números: só se forem números finitos; depois limita à faixa.
	for field, range in pairs(NUMBER_RANGES) do
		local value = input[field]
		if isFiniteNumber(value) then
			-- Campos inteiros: arredonda para o inteiro mais próximo (2,6 vira 3).
			if INTEGER_FIELDS[field] then
				value = math.floor(value + 0.5)
			end
			settings[field] = math.clamp(value, range[1], range[2])
			changed += 1
		end
	end

	-- Verdadeiro/falso: só aceita boolean de verdade.
	for field in pairs(BOOLEAN_FIELDS) do
		local value = input[field]
		if type(value) == "boolean" then
			settings[field] = value
			changed += 1
		end
	end

	-- Teclas: se veio, substitui o mapa inteiro (uma tabela vazia = "Restaurar padrão").
	if input.Keybinds ~= nil then
		local keybinds = sanitizeKeybinds(input.Keybinds)
		if keybinds then
			settings.Keybinds = keybinds
			changed += 1
		end
	end

	return changed
end

-- Handler do Request "SaveSettings".
local function handleSaveSettings(player, input)
	if type(input) ~= "table" then
		return false, "Configurações inválidas."
	end

	local profile = DataService.GetProfile(player)
	if not profile then
		return false, "Seus dados ainda estão carregando. Tente de novo em instantes."
	end

	-- Garante que a subtabela existe (perfis muito antigos ou corrompidos).
	if type(profile.Settings) ~= "table" then
		profile.Settings = {}
	end

	applySettings(profile.Settings, input)
	DataService.SyncProfile(player)
	return true, true
end

function SettingsService.Init()
	-- O cliente já espera 1 s entre salvamentos; o limite aqui é só proteção.
	Net.Handle("SaveSettings", handleSaveSettings, { Rate = 2, Burst = 5 })
end

function SettingsService.Start() end

return SettingsService
