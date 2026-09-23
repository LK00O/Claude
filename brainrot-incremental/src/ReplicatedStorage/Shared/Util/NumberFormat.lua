-- NumberFormat: transforma números em texto bonito para o jogador (padrão pt-BR).
-- Vírgula é o separador decimal ("1,5") e ponto separa os milhares ("1.234.567").
--
-- Exemplos:
--   NumberFormat.Abbrev(999)        -> "999"
--   NumberFormat.Abbrev(1234)       -> "1,23K"
--   NumberFormat.Abbrev(12.5)       -> "12,5"
--   NumberFormat.Abbrev(4.56e7)     -> "45,6M"
--   NumberFormat.Commas(1234567)    -> "1.234.567"
--   NumberFormat.Percent(0.153)     -> "15,3%"
--   NumberFormat.Time(65)           -> "1:05"
--   NumberFormat.Stat(1.5, "multiplier") -> "×1,5"

local NumberFormat = {}

-- Sufixos de cada grupo de 3 zeros: K = mil (1e3), M = milhão (1e6), B = bilhão (1e9)...
-- O último, "Td", vale 1e42. Acima disso usamos notação científica ("1,23e45").
local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd", "Td" }

-- Maior quantidade de casas decimais aceita (evita textos gigantes).
local MAX_DECIMALS = 10

-- Transforma qualquer coisa em número (texto "12" vira 12; o resto vira 0).
local function toNumber(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "boolean" then
		return value and 1 or 0
	end
	return tonumber(value) or 0
end

-- Arredonda "n" para "decimals" casas (usando o mesmo arredondamento do texto).
local function roundTo(n, decimals)
	return tonumber(string.format("%." .. decimals .. "f", n)) or n
end

-- Escreve "n" com até "decimals" casas decimais, tira zeros inúteis do fim
-- ("1,50" vira "1,5"; "2,00" vira "2") e troca o ponto pela vírgula.
local function fixed(n, decimals)
	decimals = math.clamp(math.floor(decimals), 0, MAX_DECIMALS)
	local text = string.format("%." .. decimals .. "f", n)
	if decimals > 0 then
		text = text:gsub("0+$", ""):gsub("%.$", "")
	end
	-- Evita mostrar "-0" quando um número negativo minúsculo arredonda para zero.
	if text == "-0" then
		text = "0"
	end
	return (text:gsub("%.", ","))
end

-- Casas decimais automáticas para mostrar ~3 algarismos significativos:
-- 1,23 / 12,3 / 123. Números entre 0 e 1 ganham mais casas (0,5 / 0,0002).
local function autoDecimals(mantissa)
	if mantissa >= 100 then
		return 0
	elseif mantissa >= 10 then
		return 1
	elseif mantissa >= 1 or mantissa <= 0 then
		return 2
	end
	-- Entre 0 e 1: casas suficientes para 3 algarismos significativos (no máximo 6).
	return math.min(6, -math.floor(math.log10(mantissa)) + 2)
end

-- Notação científica com vírgula: 1,23e45.
local function scientific(abs, decimals)
	local exponent = math.floor(math.log10(abs))
	local mantissa = abs / 10 ^ exponent
	local places = decimals or 2
	local rounded = roundTo(mantissa, places)
	-- Arredondar pode virar 10 (ex.: 9,999 -> 10,00): sobe o expoente.
	if rounded >= 10 then
		exponent += 1
		rounded = roundTo(abs / 10 ^ exponent, places)
	end
	return fixed(rounded, places) .. "e" .. exponent
end

-- Formata um número positivo (ou zero) com sufixo.
local function abbrevPositive(abs, decimals)
	-- Descobre o grupo (tier): 0 = sem sufixo, 1 = K, 2 = M...
	local tier = 0
	if abs >= 1000 then
		tier = math.floor(math.log10(abs) / 3)
		-- Corrige possíveis erros de arredondamento do log10.
		while tier > 0 and abs / 1000 ^ tier < 1 do
			tier -= 1
		end
		while abs / 1000 ^ tier >= 1000 do
			tier += 1
		end
	end

	-- O laço só repete quando o arredondamento "vira" o grupo (ex.: 999,9K -> 1M).
	while true do
		if tier > #SUFFIXES then
			return scientific(abs, decimals)
		end
		local mantissa = abs / 1000 ^ tier
		local places = decimals or autoDecimals(mantissa)
		local rounded = roundTo(mantissa, places)
		if rounded < 1000 then
			return fixed(rounded, places) .. (SUFFIXES[tier] or "")
		end
		tier += 1
	end
end

-- NumberFormat.Abbrev(n, decimals?) -> texto curto com sufixo.
-- "decimals" é o máximo de casas decimais; sem ele, mostra ~3 algarismos significativos.
function NumberFormat.Abbrev(n, decimals)
	n = toNumber(n)
	if decimals ~= nil then
		decimals = math.clamp(math.floor(toNumber(decimals)), 0, MAX_DECIMALS)
	end

	-- Casos especiais: "não é número" e infinito.
	if n ~= n then
		return "?"
	elseif n == math.huge then
		return "∞"
	elseif n == -math.huge then
		return "-∞"
	end

	local text = abbrevPositive(math.abs(n), decimals)
	if n < 0 and text ~= "0" then
		return "-" .. text
	end
	return text
end

-- NumberFormat.Commas(n) -> número inteiro com ponto nos milhares: "1.234.567".
-- Casas decimais são arredondadas.
function NumberFormat.Commas(n)
	n = toNumber(n)
	if n ~= n then
		return "?"
	elseif n == math.huge then
		return "∞"
	elseif n == -math.huge then
		return "-∞"
	end

	local rounded = math.floor(math.abs(n) + 0.5)
	local digits = string.format("%.0f", rounded)
	-- Inverte o texto, põe um ponto a cada 3 dígitos e desinverte.
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1."):reverse()
	-- Se o número de dígitos era múltiplo de 3, sobra um ponto no começo.
	if grouped:sub(1, 1) == "." then
		grouped = grouped:sub(2)
	end

	if n < 0 and rounded > 0 then
		return "-" .. grouped
	end
	return grouped
end

-- NumberFormat.Percent(x, decimals?) -> 0.153 vira "15,3%".
-- Sem "decimals": 1 casa decimal, ou mais casas para valores bem pequenos (0,02%).
function NumberFormat.Percent(x, decimals)
	x = toNumber(x)
	if x ~= x then
		return "?%"
	end
	local percent = x * 100
	if math.abs(percent) == math.huge then
		return (percent > 0 and "∞" or "-∞") .. "%"
	end

	local places
	if decimals ~= nil then
		places = math.clamp(math.floor(toNumber(decimals)), 0, MAX_DECIMALS)
	else
		places = 1
		local abs = math.abs(percent)
		-- Porcentagens menores que 1% ganham casas extras para não virar "0%".
		if abs > 0 and abs < 1 then
			places = math.min(4, -math.floor(math.log10(abs)) + 1)
		end
	end
	return fixed(percent, places) .. "%"
end

-- NumberFormat.Time(seconds) -> "1:05" (minutos:segundos) ou "1:02:03" (horas:min:seg).
-- Arredonda para cima, bom para contagens regressivas (0,4 s restantes mostra "0:01").
function NumberFormat.Time(seconds)
	seconds = toNumber(seconds)
	if seconds ~= seconds or seconds == math.huge then
		return "--:--"
	end

	-- O "- 1e-6" evita que erros minúsculos de conta (60,0000001) virem um segundo a mais.
	local total = math.max(0, math.ceil(seconds - 1e-6))
	local hours = math.floor(total / 3600)
	local minutes = math.floor((total % 3600) / 60)
	local secs = total % 60

	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%d:%02d", minutes, secs)
end

-- Formatadores de cada "Format" de Config.Stats.Display.
local STAT_FORMATTERS = {
	-- Número comum com sufixo: "1,23K"
	number = function(value)
		return NumberFormat.Abbrev(value)
	end,
	-- Fração vira porcentagem: 0.05 -> "5%"
	percent = function(value)
		return NumberFormat.Percent(value)
	end,
	-- Multiplicador: 1.5 -> "×1,5"
	multiplier = function(value)
		return "×" .. NumberFormat.Abbrev(value)
	end,
	-- Por segundo: 3 -> "3/s"
	rate = function(value)
		return NumberFormat.Abbrev(value) .. "/s"
	end,
	-- Distância: 12 -> "12 studs"
	studs = function(value)
		return NumberFormat.Abbrev(value) .. " studs"
	end,
	-- Tempo em segundos: 60 -> "60 s"
	seconds = function(value)
		return NumberFormat.Abbrev(value) .. " s"
	end,
	-- Liga/desliga: >= 1 (ou true) é "Sim"
	bool = function(value)
		if value == true or (type(value) == "number" and value >= 1) then
			return "Sim"
		end
		return "Não"
	end,
	-- Inteiro (arredonda para baixo): 4.7 -> "4"
	integer = function(value)
		-- O "+ 1e-9" evita que 4,9999999 (erro de conta) vire 4.
		return NumberFormat.Abbrev(math.floor(toNumber(value) + 1e-9))
	end,
}

-- NumberFormat.Stat(value, format) -> texto do valor de um stat.
-- "format" é o campo Format de Config.Stats.Display[statKey]
-- ("number", "percent", "multiplier", "rate", "studs", "seconds", "bool", "integer").
-- Por conveniência, também aceita o próprio nome do stat (ex.: "Damage").
function NumberFormat.Stat(value, format)
	if value == nil then
		return "-"
	end

	local formatter = STAT_FORMATTERS[format]
	if not formatter and type(format) == "string" then
		-- Talvez tenham passado o nome do stat: procura o formato no Config.Stats.
		local ok, StatsConfig = pcall(function()
			return require(script.Parent.Parent:WaitForChild("Config"):WaitForChild("Stats"))
		end)
		local display = ok and StatsConfig.Display and StatsConfig.Display[format]
		if display then
			formatter = STAT_FORMATTERS[display.Format]
		end
	end

	if formatter then
		return formatter(value)
	end
	-- Formato desconhecido (ou nenhum): mostra o número abreviado.
	if type(value) == "boolean" then
		return STAT_FORMATTERS.bool(value)
	end
	return NumberFormat.Abbrev(value)
end

return NumberFormat
