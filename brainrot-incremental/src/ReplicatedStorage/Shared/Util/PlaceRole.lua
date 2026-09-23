-- PlaceRole: decide se este servidor é o "Lobby" ou a "Match" (partida).
-- O mesmo arquivo .rbxl é publicado nos dois places da experiência, então o
-- código precisa descobrir sozinho qual papel assumir.
--
-- IMPORTANTE: só o SERVIDOR chama PlaceRole.Get() (no Main.server.lua) e grava o
-- resultado em workspace:SetAttribute("Role", role). O cliente lê esse atributo,
-- nunca calcula o papel por conta própria.

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

-- Devolve "Lobby" ou "Match", seguindo a ordem de prioridade da especificação.
function PlaceRole.Get()
	-- 1. Atributo "ForceRole" no workspace força o papel (útil para testes).
	local forced = workspace:GetAttribute("ForceRole")
	if isValidRole(forced) then
		return forced
	end

	local placeId = game.PlaceId

	-- 2. Estamos no place da partida (PlaceId preenchido no Config.Game).
	if placeId ~= 0 and placeId == GameConfig.MatchPlaceId then
		return "Match"
	end

	-- 3. Estamos no place do lobby.
	if placeId ~= 0 and placeId == GameConfig.LobbyPlaceId then
		return "Lobby"
	end

	-- 4. Testando no Studio: usa o papel escolhido no Config.Game.StudioRole.
	if RunService:IsStudio() then
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

	-- 5. Qualquer outro caso: lobby.
	return "Lobby"
end

-- Atalho: true quando o jogo está rodando dentro do Roblox Studio.
function PlaceRole.IsStudio()
	return RunService:IsStudio()
end

return PlaceRole
