-- Config/Brainrots: a lista de todos os brainrots que nascem no campo.
-- Cada mapa tem 9 brainrots: 3 de tier Baixo, 3 de tier Médio e 3 de tier Alto.
-- Os valores (vida, moedas) estão em "unidades do Ato 1": o jogo multiplica
-- pela HealthScale/ValueScale do mapa (Config/Maps) na hora de usar.
--
-- Campos de cada brainrot:
--   Id            nome interno (sem espaços); também é o nome do modelo
--   DisplayName   nome que o jogador vê
--   Map           em qual mapa ele nasce ("Meadow", "Winter" ou "Desert")
--   Tier          "Low", "Medium" ou "High"
--   BaseHealth    vida no tamanho base (sizeFactor = 1)
--   BaseCoinValue moedas que solta no tamanho base
--   BaseScale     tamanho do modelo (1 = ~5 studs de altura)
--   GrowTime      segundos para crescer de 25% até 100% do tamanho
--   SpawnWeight   peso no sorteio (maior = aparece mais)
--   Archetype     forma do modelo provisório (ver BrainrotFactory)
--   Colors        3 cores do modelo provisório (Primary, Secondary, Accent)
--   ModelName     nome do modelo em ServerStorage/BrainrotModels (se existir)
--   SoundId       id do som/bordão (0 = sem som)
--   Catchphrase   bordão curto (texto)

-- Atalho para criar cores a partir de R, G, B (0 a 255).
local rgb = Color3.fromRGB

local Brainrots = {}

-- Tiers: nome em português e a cor usada na barra de vida / nome.
Brainrots.Tiers = {
	Low = { Name = "Baixo", Color = rgb(120, 205, 95) },
	Medium = { Name = "Médio", Color = rgb(80, 155, 255) },
	High = { Name = "Alto", Color = rgb(255, 165, 40) },
}

-- Valores de referência de cada tier (cada brainrot varia até ±20% disso):
--   Low    = vida 10,  moedas 2,  escala 1.0, cresce em 5 s,  peso 20
--   Medium = vida 40,  moedas 10, escala 1.3, cresce em 8 s,  peso 10
--   High   = vida 150, moedas 45, escala 1.7, cresce em 11 s, peso 3.3
Brainrots.List = {
	---------------------------------------------------------------------------
	-- PRADO (Meadow)
	---------------------------------------------------------------------------
	-- Baixo
	{
		Id = "TungTungSahur",
		DisplayName = "Tung Tung Tung Sahur",
		Map = "Meadow",
		Tier = "Low",
		BaseHealth = 10,
		BaseCoinValue = 2,
		BaseScale = 1.0,
		GrowTime = 5,
		SpawnWeight = 20,
		Archetype = "Totem", -- tronco de madeira em pé segurando um taco
		Colors = { Primary = rgb(176, 124, 74), Secondary = rgb(112, 74, 42), Accent = rgb(245, 230, 200) },
		ModelName = "TungTungSahur",
		SoundId = 0,
		Catchphrase = "tung tung tung!",
	},
	{
		Id = "BrrBrrPatapim",
		DisplayName = "Brr Brr Patapim",
		Map = "Meadow",
		Tier = "Low",
		BaseHealth = 12,
		BaseCoinValue = 2.4,
		BaseScale = 1.1,
		GrowTime = 5.5,
		SpawnWeight = 18,
		Archetype = "Tree", -- árvore com cara de macaco e pezões
		Colors = { Primary = rgb(86, 160, 64), Secondary = rgb(125, 88, 52), Accent = rgb(240, 190, 160) },
		ModelName = "BrrBrrPatapim",
		SoundId = 0,
		Catchphrase = "brr brr patapim!",
	},
	{
		Id = "TrippiTroppi",
		DisplayName = "Trippi Troppi",
		Map = "Meadow",
		Tier = "Low",
		BaseHealth = 8,
		BaseCoinValue = 1.6,
		BaseScale = 0.9,
		GrowTime = 4.5,
		SpawnWeight = 22,
		Archetype = "Fish", -- camarão com cabeça de gato
		Colors = { Primary = rgb(255, 140, 105), Secondary = rgb(165, 165, 172), Accent = rgb(255, 225, 205) },
		ModelName = "TrippiTroppi",
		SoundId = 0,
		Catchphrase = "trippi troppi, troppa trippa!",
	},
	-- Médio
	{
		Id = "ChimpanziniBananini",
		DisplayName = "Chimpanzini Bananini",
		Map = "Meadow",
		Tier = "Medium",
		BaseHealth = 36,
		BaseCoinValue = 9,
		BaseScale = 1.2,
		GrowTime = 7,
		SpawnWeight = 11,
		Archetype = "Totem", -- banana em pé com um macaquinho dentro
		Colors = { Primary = rgb(250, 222, 70), Secondary = rgb(118, 78, 44), Accent = rgb(120, 175, 60) },
		ModelName = "ChimpanziniBananini",
		SoundId = 0,
		Catchphrase = "bananini, wa-wa-wa!",
	},
	{
		Id = "BonecaAmbalabu",
		DisplayName = "Boneca Ambalabu",
		Map = "Meadow",
		Tier = "Medium",
		BaseHealth = 44,
		BaseCoinValue = 11,
		BaseScale = 1.35,
		GrowTime = 8.5,
		SpawnWeight = 9,
		Archetype = "Quadruped", -- sapo com corpo de pneu e pernas humanas
		Colors = { Primary = rgb(96, 176, 72), Secondary = rgb(38, 38, 44), Accent = rgb(232, 190, 160) },
		ModelName = "BonecaAmbalabu",
		SoundId = 0,
		Catchphrase = "ambalabu, bu-bu!",
	},
	{
		Id = "BallerinaCappuccina",
		DisplayName = "Ballerina Cappuccina",
		Map = "Meadow",
		Tier = "Medium",
		BaseHealth = 40,
		BaseCoinValue = 10,
		BaseScale = 1.3,
		GrowTime = 8,
		SpawnWeight = 10,
		Archetype = "Biped", -- bailarina com uma xícara de cappuccino na cabeça
		Colors = { Primary = rgb(250, 180, 200), Secondary = rgb(150, 100, 60), Accent = rgb(250, 245, 235) },
		ModelName = "BallerinaCappuccina",
		SoundId = 0,
		Catchphrase = "cappuccina, pirueta!",
	},
	-- Alto
	{
		Id = "TralaleroTralala",
		DisplayName = "Tralalero Tralala",
		Map = "Meadow",
		Tier = "High",
		BaseHealth = 150,
		BaseCoinValue = 45,
		BaseScale = 1.7,
		GrowTime = 11,
		SpawnWeight = 3.3,
		Archetype = "Fish", -- tubarão azul de tênis
		Colors = { Primary = rgb(80, 140, 205), Secondary = rgb(245, 245, 250), Accent = rgb(40, 90, 200) },
		ModelName = "TralaleroTralala",
		SoundId = 0,
		Catchphrase = "tralalero tralalà!",
	},
	{
		Id = "CappuccinoAssassino",
		DisplayName = "Cappuccino Assassino",
		Map = "Meadow",
		Tier = "High",
		BaseHealth = 130,
		BaseCoinValue = 40,
		BaseScale = 1.5,
		GrowTime = 10,
		SpawnWeight = 3.6,
		Archetype = "Biped", -- xícara de café ninja com katanas
		Colors = { Primary = rgb(120, 78, 48), Secondary = rgb(35, 35, 40), Accent = rgb(200, 200, 210) },
		ModelName = "CappuccinoAssassino",
		SoundId = 0,
		Catchphrase = "espresso... silenzioso!",
	},
	{
		Id = "BombardiroCrocodilo",
		DisplayName = "Bombardiro Crocodilo",
		Map = "Meadow",
		Tier = "High",
		BaseHealth = 175,
		BaseCoinValue = 52,
		BaseScale = 1.9,
		GrowTime = 12.5,
		SpawnWeight = 2.9,
		Archetype = "Flyer", -- crocodilo que é um avião bombardeiro
		Colors = { Primary = rgb(70, 120, 60), Secondary = rgb(110, 120, 90), Accent = rgb(220, 60, 50) },
		ModelName = "BombardiroCrocodilo",
		SoundId = 0,
		Catchphrase = "bombardiro, bum bum!",
	},

	---------------------------------------------------------------------------
	-- INVERNO (Winter)
	---------------------------------------------------------------------------
	-- Baixo
	{
		Id = "FrigoCamelo",
		DisplayName = "Frigo Camelo",
		Map = "Winter",
		Tier = "Low",
		BaseHealth = 11,
		BaseCoinValue = 2.2,
		BaseScale = 1.1,
		GrowTime = 5.5,
		SpawnWeight = 19,
		Archetype = "Quadruped", -- camelo com uma geladeira nas costas
		Colors = { Primary = rgb(225, 235, 245), Secondary = rgb(200, 160, 105), Accent = rgb(120, 190, 240) },
		ModelName = "FrigoCamelo",
		SoundId = 0,
		Catchphrase = "frigo, frigo, brrr!",
	},
	{
		Id = "PinguinoCongelino",
		DisplayName = "Pinguino Congelino",
		Map = "Winter",
		Tier = "Low",
		BaseHealth = 9,
		BaseCoinValue = 1.8,
		BaseScale = 0.9,
		GrowTime = 4.5,
		SpawnWeight = 21,
		Archetype = "Blob", -- pinguim redondinho
		Colors = { Primary = rgb(30, 35, 50), Secondary = rgb(240, 245, 255), Accent = rgb(255, 160, 40) },
		ModelName = "PinguinoCongelino",
		SoundId = 0,
		Catchphrase = "congelino, que friozino!",
	},
	{
		Id = "TaTaTaSahur",
		DisplayName = "Ta Ta Ta Sahur",
		Map = "Winter",
		Tier = "Low",
		BaseHealth = 10,
		BaseCoinValue = 2,
		BaseScale = 1.0,
		GrowTime = 5,
		SpawnWeight = 20,
		Archetype = "Totem", -- primo congelado do Tung Tung Sahur
		Colors = { Primary = rgb(190, 215, 235), Secondary = rgb(120, 95, 70), Accent = rgb(170, 230, 255) },
		ModelName = "TaTaTaSahur",
		SoundId = 0,
		Catchphrase = "ta ta ta sahur!",
	},
	-- Médio
	{
		Id = "GlorboGelatino",
		DisplayName = "Glorbo Gelatino",
		Map = "Winter",
		Tier = "Medium",
		BaseHealth = 42,
		BaseCoinValue = 10.5,
		BaseScale = 1.3,
		GrowTime = 8,
		SpawnWeight = 10,
		Archetype = "Fish", -- crocodilo de gelatina com perninhas
		Colors = { Primary = rgb(120, 220, 200), Secondary = rgb(70, 160, 140), Accent = rgb(255, 120, 170) },
		ModelName = "GlorboGelatino",
		SoundId = 0,
		Catchphrase = "glorbo, blub blub!",
	},
	{
		Id = "OrsettoGhiacciolo",
		DisplayName = "Orsetto Ghiacciolo",
		Map = "Winter",
		Tier = "Medium",
		BaseHealth = 34,
		BaseCoinValue = 8.5,
		BaseScale = 1.2,
		GrowTime = 7,
		SpawnWeight = 11.5,
		Archetype = "Totem", -- ursinho-picolé espetado num palito
		Colors = { Primary = rgb(245, 245, 240), Secondary = rgb(140, 200, 255), Accent = rgb(200, 160, 110) },
		ModelName = "OrsettoGhiacciolo",
		SoundId = 0,
		Catchphrase = "ghiacciolo gelatissimo!",
	},
	{
		Id = "BombombiniGusini",
		DisplayName = "Bombombini Gusini",
		Map = "Winter",
		Tier = "Medium",
		BaseHealth = 46,
		BaseCoinValue = 11.5,
		BaseScale = 1.4,
		GrowTime = 9,
		SpawnWeight = 8.5,
		Archetype = "Flyer", -- ganso que é um caça a jato
		Colors = { Primary = rgb(235, 235, 230), Secondary = rgb(130, 140, 155), Accent = rgb(255, 150, 40) },
		ModelName = "BombombiniGusini",
		SoundId = 0,
		Catchphrase = "gusini in picchiata!",
	},
	-- Alto
	{
		Id = "TricTracBaraboom",
		DisplayName = "Tric Trac Baraboom",
		Map = "Winter",
		Tier = "High",
		BaseHealth = 140,
		BaseCoinValue = 42,
		BaseScale = 1.6,
		GrowTime = 10.5,
		SpawnWeight = 3.5,
		Archetype = "Biped", -- bonequinho-bombinha com pavio aceso
		Colors = { Primary = rgb(200, 50, 55), Secondary = rgb(240, 240, 245), Accent = rgb(255, 210, 60) },
		ModelName = "TricTracBaraboom",
		SoundId = 0,
		Catchphrase = "tric trac... baraboom!",
	},
	{
		Id = "TigrrulliniWatermellini",
		DisplayName = "Tigrrullini Watermellini",
		Map = "Winter",
		Tier = "High",
		BaseHealth = 160,
		BaseCoinValue = 48,
		BaseScale = 1.75,
		GrowTime = 11.5,
		SpawnWeight = 3.1,
		Archetype = "Blob", -- melancia redonda com cara e listras de tigre
		Colors = { Primary = rgb(60, 150, 60), Secondary = rgb(255, 140, 40), Accent = rgb(235, 70, 80) },
		ModelName = "TigrrulliniWatermellini",
		SoundId = 0,
		Catchphrase = "grrr, watermellini!",
	},
	{
		Id = "LaVacaSaturnoSaturnita",
		DisplayName = "La Vaca Saturno Saturnita",
		Map = "Winter",
		Tier = "High",
		BaseHealth = 178,
		BaseCoinValue = 53,
		BaseScale = 2.0,
		GrowTime = 13,
		SpawnWeight = 2.7,
		Archetype = "Quadruped", -- vaca com o anel de Saturno em volta
		Colors = { Primary = rgb(245, 240, 230), Secondary = rgb(40, 40, 45), Accent = rgb(230, 190, 120) },
		ModelName = "LaVacaSaturnoSaturnita",
		SoundId = 0,
		Catchphrase = "muuu, saturnita!",
	},

	---------------------------------------------------------------------------
	-- DESERTO (Desert)
	---------------------------------------------------------------------------
	-- Baixo
	{
		Id = "LiriliLarila",
		DisplayName = "Lirilì Larilà",
		Map = "Desert",
		Tier = "Low",
		BaseHealth = 12,
		BaseCoinValue = 2.3,
		BaseScale = 1.15,
		GrowTime = 6,
		SpawnWeight = 17,
		Archetype = "Cactus", -- elefante-cacto de sandálias
		Colors = { Primary = rgb(90, 160, 80), Secondary = rgb(150, 150, 160), Accent = rgb(200, 140, 80) },
		ModelName = "LiriliLarila",
		SoundId = 0,
		Catchphrase = "lirilì larilà!",
	},
	{
		Id = "CactusinoBandito",
		DisplayName = "Cactusino Bandito",
		Map = "Desert",
		Tier = "Low",
		BaseHealth = 9,
		BaseCoinValue = 1.9,
		BaseScale = 0.95,
		GrowTime = 4.5,
		SpawnWeight = 22,
		Archetype = "Biped", -- cacto bandido de sombreiro e bandana
		Colors = { Primary = rgb(70, 150, 70), Secondary = rgb(190, 140, 70), Accent = rgb(200, 40, 40) },
		ModelName = "CactusinoBandito",
		SoundId = 0,
		Catchphrase = "mãos ao alto, amigo!",
	},
	{
		Id = "SahurDelDeserto",
		DisplayName = "Sahur del Deserto",
		Map = "Desert",
		Tier = "Low",
		BaseHealth = 10,
		BaseCoinValue = 2,
		BaseScale = 1.0,
		GrowTime = 5,
		SpawnWeight = 21,
		Archetype = "Totem", -- tronco queimado de sol com seu tamborzinho
		Colors = { Primary = rgb(215, 180, 120), Secondary = rgb(140, 95, 55), Accent = rgb(250, 240, 220) },
		ModelName = "SahurDelDeserto",
		SoundId = 0,
		Catchphrase = "sahur, sahur, areia!",
	},
	-- Médio
	{
		Id = "CamelloTostato",
		DisplayName = "Camello Tostato",
		Map = "Desert",
		Tier = "Medium",
		BaseHealth = 45,
		BaseCoinValue = 11,
		BaseScale = 1.4,
		GrowTime = 9,
		SpawnWeight = 9,
		Archetype = "Quadruped", -- camelo tostadinho feito pão na chapa
		Colors = { Primary = rgb(170, 105, 55), Secondary = rgb(225, 185, 120), Accent = rgb(90, 55, 30) },
		ModelName = "CamelloTostato",
		SoundId = 0,
		Catchphrase = "tostato al punto!",
	},
	{
		Id = "Garamararam",
		DisplayName = "Garamararam",
		Map = "Desert",
		Tier = "Medium",
		BaseHealth = 38,
		BaseCoinValue = 9.5,
		BaseScale = 1.25,
		GrowTime = 7.5,
		SpawnWeight = 10.5,
		Archetype = "Flyer", -- urubu roxo do deserto que não para de gritar
		Colors = { Primary = rgb(160, 90, 190), Secondary = rgb(230, 200, 120), Accent = rgb(255, 230, 90) },
		ModelName = "Garamararam",
		SoundId = 0,
		Catchphrase = "garamararam-ram-ram!",
	},
	{
		Id = "BananitaDolfinita",
		DisplayName = "Bananita Dolfinita",
		Map = "Desert",
		Tier = "Medium",
		BaseHealth = 40,
		BaseCoinValue = 10,
		BaseScale = 1.3,
		GrowTime = 8,
		SpawnWeight = 10,
		Archetype = "Fish", -- golfinho vestido de banana
		Colors = { Primary = rgb(250, 220, 70), Secondary = rgb(110, 170, 220), Accent = rgb(245, 245, 245) },
		ModelName = "BananitaDolfinita",
		SoundId = 0,
		Catchphrase = "dolfinita, splash!",
	},
	-- Alto
	{
		Id = "BurbaloniLuliloli",
		DisplayName = "Burbaloni Luliloli",
		Map = "Desert",
		Tier = "High",
		BaseHealth = 165,
		BaseCoinValue = 49,
		BaseScale = 1.8,
		GrowTime = 12,
		SpawnWeight = 3,
		Archetype = "Quadruped", -- capivara morando dentro de um coco
		Colors = { Primary = rgb(120, 80, 50), Secondary = rgb(175, 125, 85), Accent = rgb(245, 240, 225) },
		ModelName = "BurbaloniLuliloli",
		SoundId = 0,
		Catchphrase = "luliloli, coco!",
	},
	{
		Id = "GraipussiMedussi",
		DisplayName = "Graipussi Medussi",
		Map = "Desert",
		Tier = "High",
		BaseHealth = 125,
		BaseCoinValue = 38,
		BaseScale = 1.5,
		GrowTime = 9.5,
		SpawnWeight = 3.8,
		Archetype = "Blob", -- água-viva feita de uvas
		Colors = { Primary = rgb(130, 60, 160), Secondary = rgb(190, 140, 230), Accent = rgb(110, 180, 80) },
		ModelName = "GraipussiMedussi",
		SoundId = 0,
		Catchphrase = "medussi, zap zap!",
	},
	{
		Id = "TralaleroFaraone",
		DisplayName = "Tralalero Faraone",
		Map = "Desert",
		Tier = "High",
		BaseHealth = 180,
		BaseCoinValue = 54,
		BaseScale = 2.0,
		GrowTime = 13,
		SpawnWeight = 2.7,
		Archetype = "Fish", -- tubarão faraó com coroa de ouro
		Colors = { Primary = rgb(80, 140, 205), Secondary = rgb(240, 200, 60), Accent = rgb(40, 70, 160) },
		ModelName = "TralaleroFaraone",
		SoundId = 0,
		Catchphrase = "o faraó do tralalà!",
	},
}

-- O Brainrot Supremo: o gigante que nasce na Grande Cova do Deserto e,
-- quando chega a 100%, tampa o sol. Ele não entra no sorteio normal.
Brainrots.Supreme = {
	Id = "TralaleroSupremo",
	DisplayName = "Tralalero Supremo",
	Map = "Desert",
	Archetype = "Fish", -- tubarão real gigante, com coroa e manto
	Colors = { Primary = rgb(70, 125, 200), Secondary = rgb(240, 240, 255), Accent = rgb(255, 200, 40) },
	ModelName = "TralaleroSupremo",
	SoundId = 0,
	Catchphrase = "TRALALERO SUPREMO!!",
}

-- Tabelas de busca rápida, montadas por código a partir da lista:
--   ById[id]     -> definição do brainrot
--   ByMap[mapId] -> lista (em ordem) dos brainrots daquele mapa
Brainrots.ById = {}
Brainrots.ByMap = {}

for _, def in ipairs(Brainrots.List) do
	Brainrots.ById[def.Id] = def

	-- Cria a lista do mapa na primeira vez que aparece um brainrot dele.
	if Brainrots.ByMap[def.Map] == nil then
		Brainrots.ByMap[def.Map] = {}
	end
	table.insert(Brainrots.ByMap[def.Map], def)
end

return Brainrots
