--!strict
--[[
	weave/container/container.luau

	holds and gives out items based on tokens.
]]

local TokenModule = require(script.Parent.Token)
local Graph = require(script.Parent.Graph)
local Error = require(script.Parent.Parent.Error)
local Log = require(script.Parent.Parent.Log)

type AnyToken = TokenModule.AnyToken

export type Lifetime = "singleton" | "scoped" | "transient"

export type Resolver = {
	resolve: <T>(self: Resolver, token: TokenModule.Token<T>) -> T,
	tryResolve: <T>(self: Resolver, token: TokenModule.Token<T>) -> T?,
}

export type FactoryOptions = {
	lifetime: Lifetime?,
	deps: { AnyToken }?,
}

type Registration = {
	token: AnyToken,
	lifetime: Lifetime,
	deps: { AnyToken },
	create: ((Resolver) -> any)?,
	value: any,
	hasValue: boolean,
	aliasOf: AnyToken?,
	source: string,
	resolveCount: number,
	order: number,
}

type Frame = {
	name: string,
	allowed: { [number]: boolean }?,
}

export type Container = {
	registerValue: <T>(self: Container, token: TokenModule.Token<T>, value: T) -> (),
	registerFactory: <T>(
		self: Container,
		token: TokenModule.Token<T>,
		create: (Resolver) -> T,
		options: FactoryOptions?
	) -> (),
	alias: (self: Container, aliasToken: AnyToken, targetToken: AnyToken) -> (),
	override: <T>(
		self: Container,
		token: TokenModule.Token<T>,
		create: (Resolver) -> T,
		options: FactoryOptions?
	) -> (),
	overrideValue: <T>(self: Container, token: TokenModule.Token<T>, value: T) -> (),
	resolve: <T>(self: Container, token: TokenModule.Token<T>) -> T,
	tryResolve: <T>(self: Container, token: TokenModule.Token<T>) -> T?,
	isRegistered: (self: Container, token: AnyToken) -> boolean,
	createScope: (self: Container, name: string) -> Container,
	seal: (self: Container) -> (),
	setStrictDependencies: (self: Container, strict: boolean) -> (),
	validate: (self: Container) -> { Error.WeaveError },
	onDispose: (self: Container, fn: () -> ()) -> (),
	dispose: (self: Container) -> (),
	evict: (self: Container, token: AnyToken) -> (),
	snapshot: (self: Container) -> { RegistrationInfo },
}

export type RegistrationInfo = {
	name: string,
	lifetime: Lifetime,
	deps: { string },
	resolveCount: number,
	isAlias: boolean,
	source: string,
}

local ContainerClass = {}
ContainerClass.__index = ContainerClass

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

function ContainerClass.new(parent: any?, name: string?): Container
	local self = setmetatable({
		_name = name or "root",
		_parent = parent,
		_registrations = {} :: { [number]: Registration },
		_registrationOrder = {} :: { Registration },
		_singletons = {} :: { [number]: any },
		_scopedCache = {} :: { [number]: any },
		_resolvingStack = {} :: { AnyToken },
		_frames = {} :: { Frame },
		_disposers = {} :: { () -> () },
		_sealed = false,
		_strictDeps = false,
		_nextOrder = if parent ~= nil then parent._nextOrder else 1,
	}, ContainerClass)
	return (self :: any) :: Container
end

function ContainerClass:setStrictDependencies(strict: boolean)
	self._strictDeps = strict
end

function ContainerClass:_findRegistration(token: AnyToken): (Registration?, any?)
	local node: any = self
	while node ~= nil do
		local reg = node._registrations[token.id]
		if reg ~= nil then
			return reg, node
		end
		node = node._parent
	end
	return nil, nil
end

function ContainerClass:_register(reg: Registration, allowOverride: boolean)
	local existing = self._registrations[reg.token.id]
	if existing ~= nil and not allowOverride then
		Error.throw("E_DUPLICATE_REGISTRATION", string.format(
			'token "%s" is already registered in container "%s"',
			reg.token.name,
			self._name
		), {
			fixes = {
				"If this is intentional replacement, use container:override(...) before seal()",
				"If two modules define the same token, they are both requiring/copying the definition module incorrectly — a token must be created exactly once",
			},
			related = { "existing registration at " .. existing.source },
			level = 3,
		})
	end
	if self._sealed and not allowOverride then
		Error.throw("E_CONTAINER_SEALED", string.format(
			'cannot register "%s": container "%s" is sealed (app already started)',
			reg.token.name,
			self._name
		), {
			fixes = { "Register all services/values before app:start()", "For tests, create a fresh App/Container per test" },
			level = 3,
		})
	end
	if existing ~= nil then
		reg.order = existing.order
		local idx = table.find(self._registrationOrder, existing)
		if idx ~= nil then
			self._registrationOrder[idx] = reg
		end
		self._singletons[reg.token.id] = nil
		self._scopedCache[reg.token.id] = nil
	else
		reg.order = self._nextOrder
		self._nextOrder += 1
		table.insert(self._registrationOrder, reg)
	end
	self._registrations[reg.token.id] = reg
end

function ContainerClass:registerValue(token: AnyToken, value: any)
	self:_register({
		token = token,
		lifetime = "singleton",
		deps = {},
		create = nil,
		value = value,
		hasValue = true,
		aliasOf = nil,
		source = captureSource(2),
		resolveCount = 0,
		order = 0,
	}, false)
end

function ContainerClass:registerFactory(token: AnyToken, create: (Resolver) -> any, options: FactoryOptions?)
	local opts: FactoryOptions = options or {}
	self:_register({
		token = token,
		lifetime = opts.lifetime or "singleton",
		deps = opts.deps or {},
		create = create,
		value = nil,
		hasValue = false,
		aliasOf = nil,
		source = captureSource(2),
		resolveCount = 0,
		order = 0,
	}, false)
end

function ContainerClass:alias(aliasToken: AnyToken, targetToken: AnyToken)
	self:_register({
		token = aliasToken,
		lifetime = "singleton",
		deps = { targetToken },
		create = nil,
		value = nil,
		hasValue = false,
		aliasOf = targetToken,
		source = captureSource(2),
		resolveCount = 0,
		order = 0,
	}, false)
end

function ContainerClass:override(token: AnyToken, create: (Resolver) -> any, options: FactoryOptions?)
	local opts: FactoryOptions = options or {}
	self:_register({
		token = token,
		lifetime = opts.lifetime or "singleton",
		deps = opts.deps or {},
		create = create,
		value = nil,
		hasValue = false,
		aliasOf = nil,
		source = captureSource(2),
		resolveCount = 0,
		order = 0,
	}, true)
end

function ContainerClass:overrideValue(token: AnyToken, value: any)
	self:_register({
		token = token,
		lifetime = "singleton",
		deps = {},
		create = nil,
		value = value,
		hasValue = true,
		aliasOf = nil,
		source = captureSource(2),
		resolveCount = 0,
		order = 0,
	}, true)
end

function ContainerClass:isRegistered(token: AnyToken): boolean
	local reg = self:_findRegistration(token)
	return reg ~= nil
end

function ContainerClass:_chainNames(extra: AnyToken?): { string }
	local names: { string } = {}
	for _, t in self._resolvingStack do
		table.insert(names, t.name)
	end
	if extra ~= nil then
		table.insert(names, extra.name)
	end
	return names
end

function ContainerClass:_checkDeclared(token: AnyToken)
	local top = self._frames[#self._frames]
	if top == nil or top.allowed == nil then
		return
	end
	if top.allowed[token.id] then
		return
	end
	local message = string.format(
		'"%s" resolved "%s" without declaring it as a dependency',
		top.name,
		token.name
	)
	if self._strictDeps then
		Error.throw("E_UNDECLARED_DEPENDENCY", message, {
			chain = self:_chainNames(token),
			fixes = {
				string.format('Add the token to dependencies/optionalDependencies of "%s"', top.name),
				"Undeclared edges are invisible to startup ordering and cycle detection",
			},
			level = 4,
		})
	else
		Log.root:warn(string.format("E_UNDECLARED_DEPENDENCY: %s (add it to its dependencies list)", message))
	end
end

function ContainerClass:_resolveInternal(token: AnyToken, optional: boolean): any
	local reg, owner = self:_findRegistration(token)
	if reg == nil then
		if optional then
			return nil
		end
		Error.throw("E_MISSING_DEPENDENCY", string.format(
			'no provider registered for token "%s"',
			token.name
		), {
			chain = self:_chainNames(token),
			fixes = {
				string.format('Register "%s" (Weave.service{...} + app:register, or container:registerFactory/registerValue)', token.name),
				"If the dependency is genuinely optional, use ctx:useOptional / tryResolve",
				"Check that server-only services are not being resolved from a client App (and vice versa)",
			},
			level = 4,
		})
	end
	assert(reg ~= nil and owner ~= nil)

	self:_checkDeclared(token)

	if reg.aliasOf ~= nil then
		reg.resolveCount += 1
		return self:_resolveInternal(reg.aliasOf, optional)
	end

	if reg.hasValue then
		reg.resolveCount += 1
		return reg.value
	end

	if reg.lifetime == "singleton" then
		local cached = owner._singletons[token.id]
		if cached ~= nil then
			reg.resolveCount += 1
			return cached
		end
	elseif reg.lifetime == "scoped" then
		local cached = self._scopedCache[token.id]
		if cached ~= nil then
			reg.resolveCount += 1
			return cached
		end
	end

	for _, active in self._resolvingStack do
		if active.id == token.id then
			Error.throw("E_CIRCULAR_DEPENDENCY", string.format(
				'circular dependency detected while resolving "%s"',
				token.name
			), {
				chain = self:_chainNames(token),
				fixes = {
					"Break the cycle: extract the shared piece into a third service both depend on",
					"Or make one edge lazy: resolve it inside onStart/handlers instead of create, and mark it optionalDependencies",
				},
				level = 4,
			})
		end
	end

	local create = reg.create
	if create == nil then
		Error.throw("E_INVALID_REGISTRATION", string.format('token "%s" has no provider function', token.name), { level = 4 })
	end
	assert(create ~= nil)

	table.insert(self._resolvingStack, token)
	local allowed: { [number]: boolean }? = nil
	if #reg.deps > 0 then
		allowed = {}
		for _, dep in reg.deps do
			(allowed :: { [number]: boolean })[dep.id] = true
		end
	end
	table.insert(self._frames, { name = token.name, allowed = allowed })

	local ok, result = pcall(create, (self :: any) :: Resolver)

	table.remove(self._frames)
	table.remove(self._resolvingStack)

	if not ok then
		local wrapped = Error.wrap("E_PROVIDER_FAILED", result, {
			chain = self:_chainNames(token),
		})
		error(Error.format(wrapped), 0)
	end

	if reg.lifetime == "singleton" then
		owner._singletons[token.id] = result
	elseif reg.lifetime == "scoped" then
		self._scopedCache[token.id] = result
	end
	reg.resolveCount += 1
	return result
end

function ContainerClass:resolve(token: AnyToken): any
	return self:_resolveInternal(token, false)
end

function ContainerClass:tryResolve(token: AnyToken): any
	return self:_resolveInternal(token, true)
end

function ContainerClass:evict(token: AnyToken)
	local reg, owner = self:_findRegistration(token)
	if reg ~= nil and owner ~= nil then
		owner._singletons[token.id] = nil
	end
	self._scopedCache[token.id] = nil
end

function ContainerClass:createScope(name: string): Container
	local scope = ContainerClass.new(self, name)
	self:onDispose(function()
		scope:dispose()
	end)
	return scope
end

function ContainerClass:seal()
	self._sealed = true
end

--[[
	checks declared dependencies for missing tokens or cycles before setup.
]]
function ContainerClass:validate(): { Error.WeaveError }
	local errors: { Error.WeaveError } = {}
	local nodes: { Graph.GraphNode } = {}
	local node: any = self
	local seen: { [number]: boolean } = {}
	while node ~= nil do
		for _, reg in node._registrationOrder do
			if not seen[reg.token.id] then
				seen[reg.token.id] = true
				local deps: { string } = {}
				for _, dep in reg.deps do
					table.insert(deps, dep.name)
				end
				table.insert(nodes, { id = reg.token.name, order = reg.order, deps = deps })
			end
		end
		node = node._parent
	end
	local result = Graph.sort(nodes)
	if result.ok then
		return errors
	end
	if result.missing ~= nil then
		for depName, dependents in result.missing do
			table.insert(errors, Error.new("E_MISSING_DEPENDENCY", string.format('"%s" is not registered', depName), {
				related = dependents,
				fixes = { string.format('Register "%s" before start, or mark it optional in its dependents', depName) },
			}))
		end
	end
	if result.cycle ~= nil and #result.cycle > 0 then
		table.insert(errors, Error.new("E_CIRCULAR_DEPENDENCY", "declared dependencies form a cycle", {
			chain = result.cycle,
			fixes = { "Break the cycle by extracting shared state, or make one edge optional and resolve it after init" },
		}))
	end
	return errors
end

function ContainerClass:onDispose(fn: () -> ())
	table.insert(self._disposers, fn)
end

function ContainerClass:dispose()
	local disposers = self._disposers
	self._disposers = {}
	for i = #disposers, 1, -1 do
		local ok, err = pcall(disposers[i])
		if not ok then
			Log.root:warn("dispose hook failed: " .. tostring(err))
		end
	end
	table.clear(self._singletons)
	table.clear(self._scopedCache)
end

function ContainerClass:snapshot(): { RegistrationInfo }
	local out: { RegistrationInfo } = {}
	for _, reg in self._registrationOrder do
		local deps: { string } = {}
		for _, dep in reg.deps do
			table.insert(deps, dep.name)
		end
		table.insert(out, {
			name = reg.token.name,
			lifetime = reg.lifetime,
			deps = deps,
			resolveCount = reg.resolveCount,
			isAlias = reg.aliasOf ~= nil,
			source = reg.source,
		})
	end
	return out
end

local Container = {}

function Container.new(name: string?): Container
	return ContainerClass.new(nil, name)
end

return Container