--!strict
--[[
	weave/container/token.luau

	typed keys for looking up things in the container.
]]

local Token = {}

export type Token<T> = {
	kind: "Token",
	name: string,
	id: number,
	_phantom: T?,
}

export type AnyToken = Token<any>

local nextId = 0

function Token.new<T>(name: string): Token<T>
	if type(name) ~= "string" or #name == 0 then
		error("[Weave] E_BAD_TOKEN_NAME: Token.new requires a non-empty string name", 2)
	end
	nextId += 1
	local self = {
		kind = "Token" :: "Token",
		name = name,
		id = nextId,
	}
	return (self :: any) :: Token<T>
end

function Token.is(value: unknown): boolean
	return type(value) == "table" and (value :: any).kind == "Token"
end

function Token.nameOf(token: AnyToken): string
	return token.name
end

return Token