--!strict

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

local ConnectionClass = {}
ConnectionClass.__index = ConnectionClass

function ConnectionClass.new(signal: any, fn: (...any) -> ()): any
	return setmetatable({
		Connected = true,
		_signal = signal,
		_fn = fn,
	}, ConnectionClass)
end

function ConnectionClass:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local handlers = self._signal._handlers :: { any }
	local idx = table.find(handlers, self)
	if idx ~= nil then
		table.remove(handlers, idx)
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({
		_handlers = {},
		_destroyed = false,
	}, Signal)
	return (self :: any) :: Signal<T...>
end

function Signal:Connect(fn: (...any) -> ()): Connection
	if self._destroyed then
		error("[Weave] E_SIGNAL_DESTROYED: cannot Connect to a destroyed signal", 2)
	end
	local connection = ConnectionClass.new(self, fn)
	table.insert(self._handlers, connection)
	return connection
end

function Signal:Once(fn: (...any) -> ()): Connection
	local connection: Connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Wait(): ...any
	local thread = coroutine.running()
	local connection: Connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Fire(...: any)
	-- Snapshot so handlers may connect/disconnect during dispatch.
	local snapshot = table.clone(self._handlers)
	for _, connection in snapshot do
		if connection.Connected then
			task.spawn(connection._fn, ...)
		end
	end
end

function Signal:Destroy()
	self._destroyed = true
	for _, connection in self._handlers do
		connection.Connected = false
	end
	table.clear(self._handlers)
end

return Signal
