-- Config/Keybinds: as ações que o jogador pode remapear nas Configurações.
-- "Default" é a tecla padrão. Se o jogador trocar, o perfil guarda só as
-- alteradas em Settings.Keybinds[Id] = "NomeDaTecla" (ex.: "F").

local Keybinds = {}

Keybinds.Actions = {
	{ Id = "Forward", Name = "Andar para frente", Default = Enum.KeyCode.W },
	{ Id = "Back", Name = "Andar para trás", Default = Enum.KeyCode.S },
	{ Id = "Left", Name = "Andar para a esquerda", Default = Enum.KeyCode.A },
	{ Id = "Right", Name = "Andar para a direita", Default = Enum.KeyCode.D },
	{ Id = "Jump", Name = "Pular", Default = Enum.KeyCode.Space },
	{ Id = "Sprint", Name = "Correr", Default = Enum.KeyCode.LeftShift },
	{ Id = "Interact", Name = "Interagir", Default = Enum.KeyCode.E },
	{ Id = "Rotate", Name = "Girar torreta", Default = Enum.KeyCode.R },
	{ Id = "Cancel", Name = "Cancelar", Default = Enum.KeyCode.Q },
}

-- ById[id] -> definição da ação (montado por código).
Keybinds.ById = {}

for _, action in ipairs(Keybinds.Actions) do
	Keybinds.ById[action.Id] = action
end

return Keybinds
