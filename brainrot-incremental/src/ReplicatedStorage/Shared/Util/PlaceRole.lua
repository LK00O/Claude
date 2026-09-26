-- PlaceRole: decide se este servidor é o "Lobby" ou a "Match" (partida).
-- O mesmo arquivo .rbxl é publicado nos dois places da experiência, então o
-- código precisa descobrir sozinho qual papel assumir.
--
-- IMPORTANTE: só o SERVIDOR chama PlaceRole.Get() (no Main.server.lua) e grava o
-- resultado em workspace:SetAttribute("Role", role). O cliente lê esse atributo,
-- nunca calcula o papel por conta própria.
--
-- Travas contra configuração errada (um erro aqui faria os jogadores ficarem
-- teleportando sem parar entre lobby e partida):
--   * o atributo "ForceRole" só vale no Studio (num jogo publicado ele é ignorado);
--   * se LobbyPlaceId e MatchPlaceId forem o MESMO número (e não 0), o servidor
--     vira "Lobby" e avisa uma vez no Output.
--
-- Troca no Studio (lobby -> partida no mesmo servidor, ver Main.server.lua):
--   PlaceRole.SetRuntimeRole("Match") guarda um papel "da sessão" que o Get() devolve
--   antes de tudo. Só funciona no Studio; num jogo publicado a chamada é ignorada.

local RunService = game:GetService("RunService")

local Config = script.Parent.Parent:WaitForChild("Config")
local GameConfig = require(Config:WaitForChild("Game"))

local PlaceRole = {}

-- Papéis válidos. Qualquer outro texto é ignorado.
local VALID_ROLES = {
	Lobby = true,
	Match = true,
}

-- Devolve true se o texto é um papel válido ("Lobby" ou "Match").
local function isValidRole(role)
	return type(role) == "string" and VALID_ROLES[role] == true
end

-- Papel trocado durante a sessão do Studio (SetRuntimeRole). nil = nenhum.
local runtimeRole = nil

-- Já avisamos que os dois PlaceIds do Config são iguais? (o aviso sai uma vez só,
-- mesmo que PlaceRole.Get() seja chamado por vários serviços)
local warnedSamePlaceIds = false

-- Os dois places do Config.Game apontam para o mesmo número? (0 = ainda não configurado)
local function hasSamePlaceIds()
	local lobbyId = GameConfig.LobbyPlaceId
	return type(lobbyId) == "number" and lobbyId ~= 0 and lobbyId == GameConfig.MatchPlaceId
end

-- Devolve "Lobby" ou "Match", seguindo a ordem de prioridade da especificação.
function PlaceRole.Get()
	local isStudio = RunService:IsStudio()

	-- 0. Papel trocado durante o teste no Studio (SetRuntimeRole): vale antes de tudo,
	--    porque o servidor de teste virou outra coisa depois de ligar.
	if isStudio and runtimeRole ~= nil then
		return runtimeRole
	end

	-- 1. Atributo "ForceRole" no workspace força o papel (útil para testes).
	--    Só no Studio: se o atributo ficar salvo no place publicado, ele é ignorado
	--    (senão um servidor de lobby poderia virar partida e mandar todos de volta
	--    ao lobby, sem fim).
	if isStudio then
		local forced = workspace:GetAttribute("ForceRole")
		if isValidRole(forced) then
			return forced
		end
	end

	-- 2. Config errado: lobby e partida com o mesmo PlaceId. Não dá para saber qual
	--    papel é o certo, então ficamos no lobby (que nunca teleporta sozinho).
	if hasSamePlaceIds() then
		if not warnedSamePlaceIds then
			warnedSamePlaceIds = true
			warn("[PlaceRole] LobbyPlaceId e MatchPlaceId iguais: usando Lobby")
		end
		return "Lobby"
	end

	local placeId = game.PlaceId

	-- 3. Estamos no place da partida (PlaceId preenchido no Config.Game).
	if placeId ~= 0 and placeId == GameConfig.MatchPlaceId then
		return "Match"
	end

	-- 4. Estamos no place do lobby.
	if placeId ~= 0 and placeId == GameConfig.LobbyPlaceId then
		return "Lobby"
	end

	-- 5. Testando no Studio: usa o papel escolhido no Config.Game.StudioRole.
	if isStudio then
		if isValidRole(GameConfig.StudioRole) then
			return GameConfig.StudioRole
		end
		-- Se alguém escreveu errado no Config, avisa e cai no padrão abaixo.
		warn(
			'[PlaceRole] Config.Game.StudioRole inválido: "'
				.. tostring(GameConfig.StudioRole)
				.. '". Use "Lobby" ou "Match". Usando "Lobby".'
		)
	end

	-- 6. Qualquer outro caso: lobby.
	return "Lobby"
end

-- PlaceRole.SetRuntimeRole(role) -> boolean
-- Só no Studio: troca o papel que o Get() devolve pelo resto da sessão de teste.
-- Usado pelo Main quando o lobby de teste vira a partida no mesmo servidor.
--   role = "Lobby" ou "Match" (qualquer outro texto é recusado); nil apaga a troca.
-- Devolve true se aceitou. Fora do Studio não faz nada (e devolve false): num jogo
-- publicado o papel vem só dos PlaceIds, para nunca criar um loop de teleporte.
-- Lembrete: isto muda só o que o Get() responde. Quem troca o atributo "Role" do
-- Workspace (o que o cliente lê) é o Main.
function PlaceRole.SetRuntimeRole(role)
	if not RunService:IsStudio() then
		warn("[PlaceRole] SetRuntimeRole só funciona no Studio; pedido ignorado.")
		return false
	end
	if role == nil then
		runtimeRole = nil
		return true
	end
	if not isValidRole(role) then
		warn('[PlaceRole] SetRuntimeRole: papel inválido "' .. tostring(role) .. '". Use "Lobby" ou "Match".')
		return false
	end
	runtimeRole = role
	return true
end

-- Atalho: true quando o jogo está rodando dentro do Roblox Studio.
function PlaceRole.IsStudio()
	return RunService:IsStudio()
end

return PlaceRole
