--!strict

local TokenModule = require(script.Parent.Parent.Container.Token)
local ContainerModule = require(script.Parent.Parent.Container.Container)
local BinModule = require(script.Parent.Parent.Util.Bin)
local LogModule = require(script.Parent.Parent.Log)

type AnyToken = TokenModule.AnyToken

export type ConfigureContext = {
	name: string,
	-- Read-only app config (from App.new{config = ...}).
	getConfig: (self: ConfigureContext, key: string) -> unknown,
	-- Exclude this service from the app entirely (feature flags, platform
	-- gating). Erroring instead: disabling a service that a non-disabled
	-- service hard-depends on is a startup error listing the dependents.
	disable: (self: ConfigureContext) -> (),
	setMetadata: (self: ConfigureContext, key: string, value: unknown) -> (),
}

export type ServiceContext = {
	name: string,
	log: LogModule.Logger,
	-- Typed dependency resolution. Only declared tokens may be used here
	-- (enforced by the container's declared-dependency check).
	use: <T>(self: ServiceContext, token: TokenModule.Token<T>) -> T,
	useOptional: <T>(self: ServiceContext, token: TokenModule.Token<T>) -> T?,
	getConfig: (self: ServiceContext, key: string) -> unknown,
	getMetadata: (self: ServiceContext, key: string) -> unknown,
	-- Resource ownership: everything owned is released at shutdown/deactivate.
	own: <T>(self: ServiceContext, item: T) -> T,
	-- Managed long-running thread (cancelled at shutdown). Long loops belong
	-- here, NOT in onStart bodies — onStart is fail-fast and sequential.
	spawn: (self: ServiceContext, fn: () -> ()) -> (),
	onStart: (self: ServiceContext, fn: () -> ()) -> (),
	onReady: (self: ServiceContext, fn: () -> ()) -> (),
	onShutdown: (self: ServiceContext, fn: () -> ()) -> (),
	onDestroy: (self: ServiceContext, fn: () -> ()) -> (),
}

export type ServiceDefinition<T> = {
	token: TokenModule.Token<T>,
	dependencies: { AnyToken }?,
	optionalDependencies: { AnyToken }?,
	-- Lazy services are cycle-checked and registered but not constructed at
	-- boot; they build on first resolve or app:activate(token).
	lazy: boolean?,
	metadata: { [string]: unknown }?,
	configure: ((ctx: ConfigureContext) -> ())?,
	create: (ctx: ServiceContext) -> T,
}

-- Type-erased registration record consumed by the App. (See Token.luau for
-- why heterogeneous collections erase through AnyToken.)
export type ServiceRegistration = {
	kind: "ServiceRegistration",
	token: AnyToken,
	dependencies: { AnyToken },
	optionalDependencies: { AnyToken },
	lazy: boolean,
	metadata: { [string]: unknown },
	configure: ((ctx: ConfigureContext) -> ())?,
	create: (ctx: ServiceContext) -> any,
	source: string,
}

local Definition = {}

local function captureSource(level: number): string
	local dbg = (debug :: any)
	if dbg ~= nil and dbg.info ~= nil then
		local ok, s, l = pcall(dbg.info, level + 1, "sl")
		if ok and type(s) == "string" then
			return string.format("%s:%d", s, l or 0)
		end
	end
	return "<unknown>"
end

function Definition.service<T>(def: ServiceDefinition<T>): ServiceRegistration
	if def == nil or type(def) ~= "table" then
		error("[Weave] E_BAD_DEFINITION: Weave.service expects a definition table", 2)
	end
	if not TokenModule.is(def.token) then
		error("[Weave] E_BAD_DEFINITION: definition.token must be a Weave token (Weave.token(name) :: Weave.Token<API>)", 2)
	end
	if type(def.create) ~= "function" then
		error(string.format('[Weave] E_BAD_DEFINITION: service "%s" is missing a create function', def.token.name), 2)
	end
	for _, listName in { "dependencies", "optionalDependencies" } do
		local list = (def :: any)[listName]
		if list ~= nil then
			for i, tok in ipairs(list) do
				if not TokenModule.is(tok) then
					error(string.format(
						'[Weave] E_BAD_DEFINITION: service "%s": %s[%d] is not a token (did you require the implementation module instead of the definition module?)',
						def.token.name, listName, i
					), 2)
				end
			end
		end
	end
	return {
		kind = "ServiceRegistration" :: "ServiceRegistration",
		token = def.token :: AnyToken,
		dependencies = def.dependencies or {},
		optionalDependencies = def.optionalDependencies or {},
		lazy = def.lazy == true,
		metadata = def.metadata or {},
		configure = def.configure,
		create = def.create :: (ServiceContext) -> any,
		source = captureSource(2),
	}
end

function Definition.isRegistration(value: unknown): boolean
	return type(value) == "table" and (value :: any).kind == "ServiceRegistration"
end

-- Re-export leaf types so init.luau can surface them from one place.
export type Bin = BinModule.Bin
export type Resolver = ContainerModule.Resolver

return Definition
