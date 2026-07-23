--!strict

export type Future<T> = {
	isDone: (self: Future<T>) -> boolean,
	isPending: (self: Future<T>) -> boolean,
	-- Yields until settled (or timeout). Returns (true, value) on success,
	-- (false, errorMessage) on failure/cancel/timeout.
	await: (self: Future<T>, timeout: number?) -> (boolean, T | string),
	-- Non-yielding observer; called immediately if already settled.
	andThen: (self: Future<T>, fn: (ok: boolean, value: T | string) -> ()) -> (),
	complete: (self: Future<T>, value: T) -> (),
	fail: (self: Future<T>, message: string) -> (),
	cancel: (self: Future<T>) -> (),
	onCancel: (self: Future<T>, fn: () -> ()) -> (),
}

type Waiter = {
	thread: thread,
	resumed: boolean,
	timeoutThread: thread?,
}

local Future = {}
Future.__index = Future

function Future.new<T>(): Future<T>
	local self = setmetatable({
		_status = "pending" :: "pending" | "done" | "failed" | "cancelled",
		_value = nil :: any,
		_error = nil :: string?,
		_waiters = {} :: { Waiter },
		_observers = {} :: { (boolean, any) -> () },
		_cancelHooks = {} :: { () -> () },
	}, Future)
	return (self :: any) :: Future<T>
end

-- Convenience: already-settled futures.
function Future.completed<T>(value: T): Future<T>
	local f = Future.new() :: any
	f._status = "done"
	f._value = value
	return f :: Future<T>
end

function Future.failed<T>(message: string): Future<T>
	local f = Future.new() :: any
	f._status = "failed"
	f._error = message
	return f :: Future<T>
end

function Future:isDone(): boolean
	return self._status ~= "pending"
end

function Future:isPending(): boolean
	return self._status == "pending"
end

function Future:_result(): (boolean, any)
	if self._status == "done" then
		return true, self._value
	elseif self._status == "cancelled" then
		return false, "cancelled"
	else
		return false, self._error or "failed"
	end
end

function Future:_settle()
	local ok, value = self:_result()
	local waiters = self._waiters
	self._waiters = {}
	for _, waiter in waiters do
		if not waiter.resumed then
			waiter.resumed = true
			if waiter.timeoutThread ~= nil then
				pcall(task.cancel, waiter.timeoutThread)
			end
			task.spawn(waiter.thread, ok, value)
		end
	end
	local observers = self._observers
	self._observers = {}
	for _, observer in observers do
		task.spawn(observer, ok, value)
	end
end

function Future:complete(value: any)
	if self._status ~= "pending" then
		return
	end
	self._status = "done"
	self._value = value
	self:_settle()
end

function Future:fail(message: string)
	if self._status ~= "pending" then
		return
	end
	self._status = "failed"
	self._error = message
	self:_settle()
end

function Future:cancel()
	if self._status ~= "pending" then
		return
	end
	self._status = "cancelled"
	local hooks = self._cancelHooks
	self._cancelHooks = {}
	for _, hook in hooks do
		task.spawn(hook)
	end
	self:_settle()
end

function Future:onCancel(fn: () -> ())
	if self._status == "cancelled" then
		task.spawn(fn)
		return
	end
	if self._status == "pending" then
		table.insert(self._cancelHooks, fn)
	end
end

function Future:andThen(fn: (boolean, any) -> ())
	if self._status ~= "pending" then
		local ok, value = self:_result()
		task.spawn(fn, ok, value)
		return
	end
	table.insert(self._observers, fn)
end

function Future:await(timeout: number?): (boolean, any)
	if self._status ~= "pending" then
		return self:_result()
	end
	local waiter: Waiter = {
		thread = coroutine.running(),
		resumed = false,
		timeoutThread = nil,
	}
	if timeout ~= nil then
		waiter.timeoutThread = task.delay(timeout, function()
			if not waiter.resumed then
				waiter.resumed = true
				local idx = table.find(self._waiters, waiter)
				if idx ~= nil then
					table.remove(self._waiters, idx)
				end
				task.spawn(waiter.thread, false, "timeout")
			end
		end)
	end
	table.insert(self._waiters, waiter)
	return coroutine.yield()
end

return Future
