--!strict

local typeOf: (value: any) -> string = (typeof :: any) or type

local Check = {}

export type Validator<T> = (value: unknown) -> (boolean, T | string)

local function fail(message: string): (boolean, any)
	return false, message
end

-- basic type checks

Check.string = function(value: unknown): (boolean, string)
	if type(value) == "string" then
		return true, value
	end
	return fail("expected string, got " .. typeOf(value))
end :: Validator<string>

Check.number = function(value: unknown): (boolean, any)
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return true, value
	end
	return fail("expected finite number, got " .. typeOf(value))
end :: Validator<number>

Check.integer = function(value: unknown): (boolean, any)
	if type(value) == "number" and value % 1 == 0 and value == value then
		return true, value
	end
	return fail("expected integer, got " .. typeOf(value))
end :: Validator<number>

Check.boolean = function(value: unknown): (boolean, any)
	if type(value) == "boolean" then
		return true, value
	end
	return fail("expected boolean, got " .. typeOf(value))
end :: Validator<boolean>

Check.none = function(value: unknown): (boolean, any)
	if value == nil then
		return true, nil
	end
	return fail("expected nil, got " .. typeOf(value))
end :: Validator<nil>

Check.unknown = function(value: unknown): (boolean, any)
	return true, value
end :: Validator<unknown>

-- checks roblox types like vector3 or instance
function Check.robloxType<T>(typeName: string): Validator<T>
	return function(value: unknown): (boolean, any)
		if typeOf(value) == typeName then
			return true, value
		end
		return fail("expected " .. typeName .. ", got " .. typeOf(value))
	end
end

-- extra limits and rules

function Check.literal<T>(expected: T): Validator<T>
	return function(value: unknown): (boolean, any)
		if value == expected then
			return true, value
		end
		return fail("expected literal " .. tostring(expected) .. ", got " .. tostring(value))
	end
end

function Check.stringMaxLen(maxLen: number): Validator<string>
	return function(value: unknown): (boolean, any)
		if type(value) ~= "string" then
			return fail("expected string, got " .. typeOf(value))
		end
		if #value > maxLen then
			return fail(string.format("string length %d exceeds max %d", #value, maxLen))
		end
		return true, value
	end
end

function Check.numberRange(min: number, max: number): Validator<number>
	return function(value: unknown): (boolean, any)
		if type(value) ~= "number" or value ~= value then
			return fail("expected number, got " .. typeOf(value))
		end
		if value < min or value > max then
			return fail(string.format("number %g outside [%g, %g]", value, min, max))
		end
		return true, value
	end
end

-- combining checks

function Check.optional<T>(inner: Validator<T>): Validator<T?>
	return function(value: unknown): (boolean, any)
		if value == nil then
			return true, nil
		end
		return inner(value)
	end
end

function Check.union<T>(...: Validator<T>): Validator<T>
	local validators = { ... }
	return function(value: unknown): (boolean, any)
		local reasons = {}
		for _, validator in validators do
			local ok, result = validator(value)
			if ok then
				return true, result
			end
			table.insert(reasons, result :: string)
		end
		return fail("no union member matched: " .. table.concat(reasons, " | "))
	end
end

function Check.array<T>(item: Validator<T>, maxItems: number?): Validator<{ T }>
	local cap = maxItems or 1000
	return function(value: unknown): (boolean, any)
		if type(value) ~= "table" then
			return fail("expected array, got " .. typeOf(value))
		end
		local valueTable = value :: { unknown }
		local count = #valueTable
		if count > cap then
			return fail(string.format("array length %d exceeds max %d", count, cap))
		end
		-- blocks mixed key tables
		local total = 0
		for _ in pairs(valueTable) do
			total += 1
		end
		if total ~= count then
			return fail("expected a dense array (found non-sequential keys)")
		end
		local out = table.create(count)
		for i = 1, count do
			local ok, result = item(valueTable[i])
			if not ok then
				return fail(string.format("[%d]: %s", i, result :: string))
			end
			out[i] = result
		end
		return true, out
	end
end

function Check.map<K, V>(keyValidator: Validator<K>, valueValidator: Validator<V>, maxEntries: number?): Validator<{ [K]: V }>
	local cap = maxEntries or 1000
	return function(value: unknown): (boolean, any)
		if type(value) ~= "table" then
			return fail("expected map, got " .. typeOf(value))
		end
		local out = {}
		local count = 0
		for k, v in pairs(value :: { [unknown]: unknown }) do
			count += 1
			if count > cap then
				return fail(string.format("map exceeds max %d entries", cap))
			end
			local okKey, keyResult = keyValidator(k)
			if not okKey then
				return fail(string.format("key %s: %s", tostring(k), keyResult :: string))
			end
			local okValue, valueResult = valueValidator(v)
			if not okValue then
				return fail(string.format("[%s]: %s", tostring(k), valueResult :: string))
			end
			out[keyResult] = valueResult
		end
		return true, out
	end
end

export type ShapeOptions = {
	open: boolean?,
}

-- checks table layout and rejects unknown keys unless open is true
function Check.shape<T>(fields: { [string]: Validator<any> }, options: ShapeOptions?): Validator<T>
	local open = options ~= nil and options.open == true
	return function(value: unknown): (boolean, any)
		if type(value) ~= "table" then
			return fail("expected table, got " .. typeOf(value))
		end
		local valueTable = value :: { [unknown]: unknown }
		local out = {}
		for fieldName, validator in fields do
			local ok, result = validator(valueTable[fieldName])
			if not ok then
				return fail(fieldName .. ": " .. (result :: string))
			end
			out[fieldName] = result
		end
		if not open then
			for key in pairs(valueTable) do
				if type(key) ~= "string" or fields[key] == nil then
					return fail("unexpected key: " .. tostring(key))
				end
			end
		end
		return true, out
	end
end

return Check