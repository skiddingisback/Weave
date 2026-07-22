--!strict

local typeOf: (value: any) -> string = (typeof :: any) or type

export type Bin = {
	own: <T>(self: Bin, item: T) -> T,
	empty: (self: Bin) -> (),
	destroy: (self: Bin) -> (),
}

local Bin = {}
Bin.__index = Bin

function Bin.new(): Bin
	local self = setmetatable({
		_items = {} :: { any },
		_destroyed = false,
	}, Bin)
	return (self :: any) :: Bin
end

local function cleanupItem(item: any)
	local kind = typeOf(item)
	if kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "thread" then
		pcall(task.cancel, item)
	elseif kind == "function" then
		item()
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.destroy) == "function" then
			item:destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		end
	end
end

function Bin:own<T>(item: T): T
	if self._destroyed then
		-- Owning into a dead bin cleans up immediately rather than leaking.
		cleanupItem(item)
		return item
	end
	table.insert(self._items, item)
	return item
end

function Bin:empty()
	local items = self._items
	self._items = {}
	-- Reverse order: resources acquired later are released first.
	for i = #items, 1, -1 do
		local ok, err = pcall(cleanupItem, items[i])
		if not ok then
			warn("[Weave] Bin cleanup error: " .. tostring(err))
		end
	end
end

function Bin:destroy()
	if self._destroyed then
		return
	end
	self:empty()
	self._destroyed = true
end

return Bin
