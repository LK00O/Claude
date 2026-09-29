-- Config/Cosmetics: skins de arma compradas na loja do lobby com Brainrot Tokens.
-- A skin muda a cor da arma (GunColor) e do rastro da bala (TracerColor).
--
-- Campos:
--   Id, Name     nome interno e nome em português
--   Price        preço em Brainrot Tokens (0 = grátis, todo mundo já tem)
--   GunColor     cor do corpo da arma
--   TracerColor  cor do rastro das balas
--   Rainbow      true = as cores ficam alternando entre as cores do arco-íris

-- Atalho para criar cores a partir de R, G, B (0 a 255).
local rgb = Color3.fromRGB

local Cosmetics = {}

Cosmetics.Skins = {
	{
		Id = "Classic",
		Name = "Clássica",
		Price = 0,
		GunColor = rgb(70, 70, 78),
		TracerColor = rgb(255, 225, 120),
		Rainbow = false,
	},
	{
		Id = "NeonPink",
		Name = "Rosa Neon",
		Price = 10,
		GunColor = rgb(255, 60, 180),
		TracerColor = rgb(255, 130, 220),
		Rainbow = false,
	},
	{
		Id = "ToxicGreen",
		Name = "Verde Tóxico",
		Price = 15,
		GunColor = rgb(90, 220, 40),
		TracerColor = rgb(170, 255, 80),
		Rainbow = false,
	},
	{
		Id = "IceBlue",
		Name = "Azul Gelo",
		Price = 20,
		GunColor = rgb(120, 200, 255),
		TracerColor = rgb(200, 240, 255),
		Rainbow = false,
	},
	{
		Id = "Golden",
		Name = "Dourada",
		Price = 40,
		GunColor = rgb(240, 190, 40),
		TracerColor = rgb(255, 235, 120),
		Rainbow = false,
	},
	{
		Id = "Rainbow",
		Name = "Arco-íris",
		Price = 60,
		-- Cores de partida; como Rainbow = true, o jogo vai trocando a cor sozinho.
		GunColor = rgb(255, 80, 80),
		TracerColor = rgb(120, 180, 255),
		Rainbow = true,
	},
}

-- ById[id] -> definição da skin (montado por código).
Cosmetics.ById = {}

for _, skin in ipairs(Cosmetics.Skins) do
	Cosmetics.ById[skin.Id] = skin
end

return Cosmetics
