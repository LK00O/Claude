-- Signal: um "evento" simples feito em Lua puro.
-- Serve para um módulo avisar outros que algo aconteceu (ex.: "um brainrot morreu")
-- sem que um precise conhecer o outro.

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

-- Conecta uma função. Retorna um objeto com :Disconnect().
function Signal:Connect(fn)
	local handler = { fn = fn, connected = true }
	table.insert(self._handlers, handler)
	return {
		Disconnect = function()
			handler.connected = false
			local index = table.find(self._handlers, handler)
			if index then
				table.remove(self._handlers, index)
			end
		end,
	}
end

-- Dispara o evento chamando todas as funções conectadas.
-- Cada função roda em sua própria thread para um erro não travar as outras.
function Signal:Fire(...)
	for _, handler in ipairs(table.clone(self._handlers)) do
		if handler.connected then
			task.spawn(handler.fn, ...)
		end
	end
end

-- Espera o próximo disparo e devolve os argumentos.
function Signal:Wait()
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection.Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	table.clear(self._handlers)
end

return Signal
