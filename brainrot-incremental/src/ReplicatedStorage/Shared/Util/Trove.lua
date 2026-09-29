-- Trove: guarda conexões, instâncias e funções de limpeza num lugar só.
-- Quando você chama :Clean(), tudo que foi guardado é desconectado/destruído.
-- Isso evita "vazamento de memória" quando um jogador sai ou um brainrot morre.

local Trove = {}
Trove.__index = Trove

function Trove.new()
	return setmetatable({ _items = {} }, Trove)
end

-- Adiciona algo para ser limpo depois. Retorna o próprio item.
function Trove:Add(item)
	table.insert(self._items, item)
	return item
end

-- Atalho para conectar um evento do Roblox e guardar a conexão.
function Trove:Connect(signal, fn)
	return self:Add(signal:Connect(fn))
end

local function cleanItem(item)
	local kind = typeof(item)
	if kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "function" then
		item()
	elseif kind == "thread" then
		pcall(task.cancel, item)
	elseif kind == "table" then
		if type(item.Disconnect) == "function" then
			item.Disconnect()
		elseif type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Clean) == "function" then
			item:Clean()
		end
	end
end

function Trove:Clean()
	local items = self._items
	self._items = {}
	for index = #items, 1, -1 do
		local ok, err = pcall(cleanItem, items[index])
		if not ok then
			warn("[Trove] erro ao limpar:", err)
		end
	end
end

Trove.Destroy = Trove.Clean

return Trove
