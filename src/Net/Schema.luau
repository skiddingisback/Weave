--!strict

local Check = require(script.Parent.Check)

export type EndpointOptions = {
	rate: number?,
	burst: number?,
	timeout: number?,
	unreliable: boolean?,
}

export type Rpc<Req, Res> = {
	kind: "rpc",
	id: string,
	key: string,
	requestValidator: Check.Validator<Req>,
	responseValidator: Check.Validator<Res>,
	options: EndpointOptions,
}

export type Event<T> = {
	kind: "event",
	id: string,
	key: string,
	payloadValidator: Check.Validator<T>,
	options: EndpointOptions,
}

export type AnyEndpoint = Rpc<any, any> | Event<any>

local Schema = {}

-- defines a network rpc endpoint with request and response checks
function Schema.rpc<Req, Res>(
	requestValidator: Check.Validator<Req>,
	responseValidator: Check.Validator<Res>,
	options: EndpointOptions?
): Rpc<Req, Res>
	return {
		kind = "rpc" :: "rpc",
		id = "",
		key = "",
		requestValidator = requestValidator,
		responseValidator = responseValidator,
		options = options or {},
	}
end

-- defines a network event endpoint with a payload check
function Schema.event<T>(payloadValidator: Check.Validator<T>, options: EndpointOptions?): Event<T>
	return {
		kind = "event" :: "event",
		id = "",
		key = "",
		payloadValidator = payloadValidator,
		options = options or {},
	}
end

-- group endpoints under a prefix and assign unique ids
function Schema.namespace<E>(name: string, endpoints: E): E
	if type(name) ~= "string" or #name == 0 or string.find(name, "/") ~= nil then
		error('[Weave] E_BAD_NAMESPACE: namespace name must be a non-empty string without "/"', 2)
	end
	local endpointMap = endpoints :: any
	for key, endpoint in pairs(endpointMap) do
		if type(endpoint) ~= "table" or (endpoint.kind ~= "rpc" and endpoint.kind ~= "event") then
			error(string.format(
				'[Weave] E_BAD_ENDPOINT: "%s.%s" is not Net.rpc(...) or Net.event(...)', name, tostring(key)
			), 2)
		end
		if endpoint.id ~= "" then
			error(string.format(
				'[Weave] E_ENDPOINT_REUSED: "%s" already belongs to namespace "%s" — endpoint definitions cannot be shared across namespaces',
				tostring(key), tostring(endpoint.id)
			), 2)
		end
		endpoint.key = key
		endpoint.id = name .. "/" .. key
	end
	return endpoints
end

-- fnv-1a hash function.
-- The multiply is split into 16-bit halves: `hash * 16777619` can reach ~7.2e16,
-- past 2^53, so a direct product would silently drop low bits before the mask.
-- (a*b) mod 2^32 = (((aHi*b) mod 2^16) * 2^16 + aLo*b) mod 2^32, and each partial
-- product here stays well under 2^53, so it is exact.
local FNV_PRIME = 16777619
local function fnv1a(text: string): number
	local hash = 2166136261
	for i = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, i))
		local lo = bit32.band(hash, 0xFFFF)
		local hi = bit32.rshift(hash, 16)
		local low = lo * FNV_PRIME
		local high = bit32.lshift(bit32.band(hi * FNV_PRIME, 0xFFFF), 16)
		hash = bit32.band(low + high, 0xFFFFFFFF)
	end
	return hash
end

-- creates a short hash string to check for API version mismatches
function Schema.fingerprint(namespaces: { any }): string
	local lines: { string } = {}
	for _, namespaceTable in namespaces do
		for _, endpoint in pairs(namespaceTable :: { [string]: AnyEndpoint }) do
			table.insert(lines, endpoint.id .. ":" .. endpoint.kind)
		end
	end
	table.sort(lines)
	return string.format("%08x", fnv1a(table.concat(lines, "\n")))
end

-- maps all endpoint ids to their definitions for fast lookup
function Schema.buildRoutes(namespaces: { any }): { [string]: AnyEndpoint }
	local routes: { [string]: AnyEndpoint } = {}
	for _, namespaceTable in namespaces do
		for _, endpoint in pairs(namespaceTable :: { [string]: AnyEndpoint }) do
			if endpoint.id == "" then
				error("[Weave] E_UNNAMED_ENDPOINT: endpoint was not registered through Net.namespace", 2)
			end
			if routes[endpoint.id] ~= nil then
				error(string.format('[Weave] E_DUPLICATE_ENDPOINT: "%s" defined twice (duplicate namespace name?)', endpoint.id), 2)
			end
			routes[endpoint.id] = endpoint
		end
	end
	return routes
end

return Schema