--!strict

local Error = {}

export type WeaveError = {
	kind: "WeaveError",
	code: string,
	message: string,
	chain: { string }?, -- e.g. dependency chain that led here
	fixes: { string }?, -- concrete suggested fixes
	related: { string }?, -- related services/endpoints
	source: string?, -- script source path
	line: number?,
}

export type ErrorOptions = {
	chain: { string }?,
	fixes: { string }?,
	related: { string }?,
	level: number?, -- stack level to capture source from (default: caller of new)
}

local errorMeta = {}

local function formatList(label: string, items: { string }?, joiner: string?): string
	if items == nil or #items == 0 then
		return ""
	end
	if joiner ~= nil then
		return string.format("\n  %-8s%s", label .. ":", table.concat(items, joiner))
	end
	local out = string.format("\n  %s:", label)
	for _, item in items do
		out ..= "\n    - " .. item
	end
	return out
end

function Error.format(err: WeaveError): string
	local out = string.format("[Weave] %s: %s", err.code, err.message)
	out ..= formatList("chain", err.chain, " -> ")
	out ..= formatList("fix", err.fixes)
	out ..= formatList("related", err.related, ", ")
	if err.source ~= nil then
		out ..= string.format("\n  at:     %s:%d", err.source, err.line or 0)
	end
	return out
end

errorMeta.__tostring = function(self: WeaveError): string
	return Error.format(self)
end

function Error.new(code: string, message: string, options: ErrorOptions?): WeaveError
	local opts: ErrorOptions = options or {}
	local level = (opts.level or 1) + 1
	local source: string?, line: number? = nil, nil
	-- debug.info is available in Roblox and Lune; guard for bare Luau.
	local dbg = (debug :: any)
	if dbg ~= nil and dbg.info ~= nil then
		local ok, s, l = pcall(dbg.info, level + 1, "sl")
		if ok and type(s) == "string" then
			source = s
			line = l
		end
	end
	local err: WeaveError = {
		kind = "WeaveError",
		code = code,
		message = message,
		chain = opts.chain,
		fixes = opts.fixes,
		related = opts.related,
		source = source,
		line = line,
	}
	return setmetatable(err :: any, errorMeta) :: any
end

function Error.throw(code: string, message: string, options: ErrorOptions?): never
	local opts: ErrorOptions = options or {}
	opts.level = (opts.level or 1) + 1
	local err = Error.new(code, message, opts)
	error(Error.format(err), 0)
end

function Error.is(value: unknown): boolean
	return type(value) == "table" and (value :: any).kind == "WeaveError"
end

-- Wrap an arbitrary caught error value into a WeaveError.
function Error.wrap(code: string, caught: unknown, options: ErrorOptions?): WeaveError
	local message: string
	if Error.is(caught) then
		return caught :: any
	elseif type(caught) == "string" then
		message = caught
	else
		message = tostring(caught)
	end
	local opts: ErrorOptions = options or {}
	opts.level = (opts.level or 1) + 1
	return Error.new(code, message, opts)
end

return Error
