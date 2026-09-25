-- Tables: funções pequenas e úteis para trabalhar com tabelas.
-- Usado no servidor e no cliente.

local Tables = {}

-- Gerador de números aleatórios próprio deste módulo (melhor que math.random,
-- porque não é afetado por outros scripts que mexem na semente).
local rng = Random.new()

-- Copia recursiva: a nova tabela (e todas as tabelas dentro dela) são novas,
-- então mexer na cópia não altera a original.
-- "seen" lembra tabelas já copiadas, para não travar se uma tabela aponta para si mesma.
local function deepCopy(value, seen)
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end

	local copy = {}
	seen[value] = copy
	for key, inner in pairs(value) do
		copy[deepCopy(key, seen)] = deepCopy(inner, seen)
	end
	return copy
end

-- Tables.DeepCopy(t) -> cópia completa de t (valores que não são tabela voltam iguais).
function Tables.DeepCopy(t)
	return deepCopy(t, {})
end

-- Tables.Reconcile(target, template) -> target
-- Adiciona em "target" as chaves que existem em "template" e faltam em "target",
-- entrando em subtabelas. Nunca apaga nem sobrescreve o que já existe.
-- Usado para dar as chaves novas do template do perfil a perfis antigos.
function Tables.Reconcile(target, template)
	if type(target) ~= "table" or type(template) ~= "table" then
		return target
	end
	for key, templateValue in pairs(template) do
		local current = target[key]
		if current == nil then
			-- Chave faltando: copia do template (cópia, para não compartilhar tabelas).
			target[key] = Tables.DeepCopy(templateValue)
		elseif type(current) == "table" and type(templateValue) == "table" then
			-- As duas são tabelas: completa por dentro também.
			Tables.Reconcile(current, templateValue)
		end
	end
	return target
end

-- Tables.Count(t) -> quantas chaves a tabela tem (funciona com dicionários, não só listas).
function Tables.Count(t)
	if type(t) ~= "table" then
		return 0
	end
	local count = 0
	for _ in pairs(t) do
		count += 1
	end
	return count
end

-- Tables.Keys(t) -> lista com todas as chaves de t (ordem não garantida).
function Tables.Keys(t)
	local keys = {}
	if type(t) ~= "table" then
		return keys
	end
	for key in pairs(t) do
		table.insert(keys, key)
	end
	return keys
end

-- Tables.Shuffle(t) -> t
-- Embaralha a lista NO LUGAR (altera a própria tabela) e a devolve.
-- Algoritmo de Fisher-Yates: cada ordem possível tem a mesma chance.
function Tables.Shuffle(t)
	if type(t) ~= "table" then
		return t
	end
	for i = #t, 2, -1 do
		local j = rng:NextInteger(1, i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

-- Lê o peso de um item: número válido e positivo, senão 0.
local function readWeight(item, index, weightFn)
	local weight
	if weightFn then
		weight = weightFn(item, index)
	elseif type(item) == "table" then
		-- Sem função: usa o campo "Weight" do item, se existir.
		weight = item.Weight
	end
	-- Ignora pesos inválidos (não número, NaN, infinito ou <= 0).
	if type(weight) ~= "number" or weight ~= weight or weight == math.huge or weight <= 0 then
		return 0
	end
	return weight
end

-- Tables.WeightedPick(list, weightFn) -> item, index
-- Sorteia um item da lista; quanto maior o peso, maior a chance.
-- weightFn(item, index) devolve o peso do item. Se não for passada, usa item.Weight.
-- Devolve nil se a lista estiver vazia ou todos os pesos forem 0.
function Tables.WeightedPick(list, weightFn)
	if type(list) ~= "table" then
		return nil
	end

	-- Primeiro soma todos os pesos (guardando cada um para não chamar weightFn duas vezes).
	local weights = {}
	local total = 0
	for index, item in ipairs(list) do
		local weight = readWeight(item, index, weightFn)
		weights[index] = weight
		total += weight
	end
	if total <= 0 then
		return nil
	end

	-- Sorteia um ponto entre 0 e o total e acha em qual "fatia" ele caiu.
	local roll = rng:NextNumber() * total
	local lastValid = nil
	for index, item in ipairs(list) do
		local weight = weights[index]
		if weight > 0 then
			lastValid = index
			if roll < weight then
				return item, index
			end
			roll -= weight
		end
	end

	-- Por arredondamento o sorteio pode passar um tiquinho do fim: fica com o último válido.
	if lastValid then
		return list[lastValid], lastValid
	end
	return nil
end

return Tables
