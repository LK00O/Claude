-- Config/Enchants: os encantamentos que um brainrot pode ter ao nascer.
-- A chance de nascer encantado vem do stat EnchantChance (upgrades).
-- Depois, qual encantamento sai é sorteado pelo "Weight" (peso) de cada um.
--
-- Campos:
--   Id, Name     nome interno e nome em português
--   Color        cor das partículas/brilho e da etiqueta no BillboardGui
--   CoinMult     multiplicador de moedas (o efetivo é 1 + (CoinMult - 1) * EnchantPower)
--   SizeMult     multiplicador de tamanho (padrão 1)
--   GrowthMult   multiplicador de velocidade de crescimento (padrão 1)
--   Weight       peso no sorteio (maior = mais comum)
--   Maps         lista de mapas onde pode aparecer (nil = todos os mapas)
--   MapOverrides troca valores num mapa específico (CoinMult, WeightMult = multiplica o peso)
--   Special      efeito especial ("Ignite" = ao morrer, incendeia os vizinhos)
--   Rainbow      true = a cor fica alternando entre as cores do arco-íris
--   Announce     true = avisa o servidor inteiro quando alguém destrói um

-- Atalho para criar cores a partir de R, G, B (0 a 255).
local rgb = Color3.fromRGB

local Enchants = {}

Enchants.List = {
	{
		Id = "Golden",
		Name = "Dourado",
		Color = rgb(255, 200, 40),
		CoinMult = 3,
		SizeMult = 1,
		GrowthMult = 1,
		Weight = 50,
	},
	{
		Id = "Ice",
		Name = "Gelo",
		Color = rgb(140, 210, 255),
		CoinMult = 2,
		SizeMult = 2,
		GrowthMult = 1,
		Weight = 30,
		-- No Inverno o Gelo é muito mais forte e aparece 3 vezes mais.
		MapOverrides = { Winter = { CoinMult = 6, WeightMult = 3 } },
	},
	{
		Id = "Fire",
		Name = "Fogo",
		Color = rgb(255, 100, 30),
		CoinMult = 2,
		SizeMult = 1,
		GrowthMult = 1,
		Weight = 25,
		Special = "Ignite",
	},
	{
		Id = "Rainbow",
		Name = "Arco-íris",
		Color = rgb(255, 90, 200),
		CoinMult = 10,
		SizeMult = 1,
		GrowthMult = 1,
		Weight = 8,
		Rainbow = true,
	},
	{
		Id = "Radioactive",
		Name = "Radioativo",
		Color = rgb(120, 255, 60),
		CoinMult = 2,
		SizeMult = 1,
		GrowthMult = 3,
		Weight = 15,
	},
	{
		Id = "Galactic",
		Name = "Galáctico",
		Color = rgb(130, 80, 255),
		CoinMult = 50,
		SizeMult = 1,
		GrowthMult = 1,
		Weight = 1,
		Announce = true,
	},
}

-- ById[id] -> definição do encantamento (montado por código).
Enchants.ById = {}

for _, def in ipairs(Enchants.List) do
	-- Garante os valores padrão caso alguém apague um campo no futuro.
	if def.SizeMult == nil then
		def.SizeMult = 1
	end
	if def.GrowthMult == nil then
		def.GrowthMult = 1
	end
	Enchants.ById[def.Id] = def
end

return Enchants
