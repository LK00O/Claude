-- Primeiros passos em Lua
-- Rode com: lua ola.lua

-- Variáveis (use `local` sempre que puder)
local nome = "Mundo"
local idade = 30
local ativo = true

print("Olá, " .. nome .. "!")  -- `..` junta strings

-- Condicional
if idade >= 18 then
  print("Maior de idade")
else
  print("Menor de idade")
end

-- Laço numérico
for i = 1, 3 do
  print("Contando: " .. i)
end

-- Funções
local function soma(a, b)
  return a + b
end
print("2 + 3 = " .. soma(2, 3))

-- Tabelas: a única estrutura de dados do Lua
-- Como lista (os índices começam em 1!)
local frutas = { "maçã", "banana", "uva" }
for i, fruta in ipairs(frutas) do
  print(i, fruta)
end
print("Total de frutas: " .. #frutas)

-- Como dicionário
local pessoa = { nome = "Ana", idade = 25 }
pessoa.cidade = "São Paulo"
for chave, valor in pairs(pessoa) do
  print(chave, valor)
end
