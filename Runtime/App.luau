--!strict

local ContainerModule = require(script.Parent.Parent.Container.Container)
local TokenModule = require(script.Parent.Parent.Container.Token)
local Graph = require(script.Parent.Parent.Container.Graph)
local Definition = require(script.Parent.Definition)
local BinModule = require(script.Parent.Parent.Util.Bin)
local SignalModule = require(script.Parent.Parent.Util.Signal)
local Timeline = require(script.Parent.Parent.Diagnostics.Timeline)
local GraphExport = require(script.Parent.Parent.Diagnostics.GraphExport)
local Error = require(script.Parent.Parent.Error)
local Log = require(script.Parent.Parent.Log)
local PluginHost = require(script.Parent.Parent.Plugins.PluginHost)

type AnyToken = TokenModule.AnyToken
type ServiceRegistration = Definition.ServiceRegistration
type ServiceContext = Definition.ServiceContext
type ConfigureContext = Definition.ConfigureContext

export type Phase = "idle" | "starting" | "ready" | "shutdown" | "destroyed"

export type AppOptions = {
	name: string?,
	config: { [string]: unknown }?,
	-- Testing mode: allows resolving before start and overriding after seal.
	testing: boolean?,
	-- Escalate undeclared dependency use from warning to error.
	strictDependencies: boolean?,
}

export type StartOptions = {
	-- Seconds a single service may yield in one phase step before the
	-- watchdog warns. NOTE: Luau is cooperatively scheduled — a watchdog can
	-- flag a *yielding* service but cannot preempt a synchronous busy-loop.
	phaseTimeout: number?,
	-- Timeline entries at or above this duration are marked "slow".
	slowThresholdMs: number?,
}

export type StartReport = {
	timelineText: string,
	warnings: { string },
	graphMermaid: string,
	graphDot: string,
	totalMs: number,
}

type ServiceRecord = {
	reg: ServiceRegistration,
	index: number,
	disabled: boolean,
	-- Overridden via app:override — the container answers for the token, so
	-- the service build is skipped but dependents remain satisfied.
	overridden: boolean,
	built: boolean,
	started: boolean,
	instance: any,
	bin: BinModule.Bin?,
	startCbs: { () -> () },
	readyCbs: { () -> () },
	shutdownCbs: { () -> () },
	destroyCbs: { () -> () },
	usedTokenIds: { [number]: boolean },
	metadata: { [string]: unknown },
}

local App = {}
App.__index = App

export type App = typeof(setmetatable(
	{} :: {
		_name: string,
		_config: { [string]: unknown },
		_container: ContainerModule.Container,
		_records: { ServiceRecord },
		_recordsByTokenId: { [number]: ServiceRecord },
		_recordsByName: { [string]: ServiceRecord },
		_phase: Phase,
		_timeline: Timeline.Timeline,
		_log: Log.Logger,
		_readySignal: SignalModule.Signal<>,
		_warnings: { string },
		_bootOrder: { ServiceRecord },
		_lifecycleHooks: { (phase: string) -> () },
		_contributions: { [string]: { any } },
		_commands: { [string]: (...any) -> ...any },
		_testing: boolean,
		_phaseTimeout: number,
	},
	App
))

function App.new(options: AppOptions?): App
	local opts: AppOptions = options or {}
	local name = opts.name or "App"
	local container = ContainerModule.new(name)
	if opts.strictDependencies then
		container:setStrictDependencies(true)
	end
	local self = setmetatable({
		_name = name,
		_config = opts.config or {},
		_container = container,
		_records = {},
		_recordsByTokenId = {},
		_recordsByName = {},
		_phase = "idle" :: Phase,
		_timeline = Timeline.new(),
		_log = Log.child(name),
		_readySignal = SignalModule.new(),
		_warnings = {},
		_bootOrder = {},
		_lifecycleHooks = {},
		_contributions = {},
		_commands = {},
		_testing = opts.testing == true,
		_phaseTimeout = 10,
	}, App)
	return self :: App
end

-- ------------------------------------------------------------------ register

function App.register(self: App, registration: ServiceRegistration)
	if self._phase ~= "idle" then
		Error.throw("E_LIFECYCLE", string.format(
			'cannot register "%s": app "%s" has already started (phase: %s)',
			registration.token.name, self._name, self._phase
		), {
			fixes = { "Register everything before app:start()", "For runtime-optional features, register eagerly with lazy = true and app:activate later" },
		})
	end
	if not Definition.isRegistration(registration) then
		Error.throw("E_BAD_REGISTRATION", "app:register expects the return value of Weave.service{...}", {
			fixes = { "Make sure the module returns Weave.service{ token = ..., create = ... }" },
		})
	end
	local existing = self._recordsByTokenId[registration.token.id]
	if existing ~= nil then
		Error.throw("E_DUPLICATE_REGISTRATION", string.format(
			'service "%s" registered twice', registration.token.name
		), {
			related = { "first: " .. existing.reg.source, "second: " .. registration.source },
			fixes = { "A registry module listing a service twice, or two registry modules overlapping, is the usual cause" },
		})
	end
	local byName = self._recordsByName[registration.token.name]
	if byName ~= nil then
		Error.throw("E_NAME_COLLISION", string.format(
			'two different tokens share the name "%s"', registration.token.name
		), {
			related = { byName.reg.source, registration.source },
			fixes = { "Service names must be unique within an app (they identify nodes in diagnostics and the network schema)" },
		})
	end
	local record: ServiceRecord = {
		reg = registration,
		index = #self._records + 1,
		disabled = false,
		built = false,
		started = false,
		instance = nil,
		bin = nil,
		startCbs = {},
		readyCbs = {},
		shutdownCbs = {},
		destroyCbs = {},
		usedTokenIds = {},
		metadata = table.clone(registration.metadata),
	}
	table.insert(self._records, record)
	self._recordsByTokenId[registration.token.id] = record
	self._recordsByName[registration.token.name] = record
end

function App.registerMany(self: App, registrations: { ServiceRegistration })
	for _, registration in registrations do
		self:register(registration)
	end
end

-- Register a plain value (config objects, adapters, Roblox service handles).
function App.provide<T>(self: App, token: TokenModule.Token<T>, value: T)
	self._container:registerValue(token, value)
end

-- Test override: replaces a provider even after seal (testing mode intent).
function App.override<T>(self: App, token: TokenModule.Token<T>, value: T)
	self._container:overrideValue(token, value)
	local record = self._recordsByTokenId[(token :: AnyToken).id]
	if record ~= nil then
		-- The container now answers for this token; skip the service build.
		record.disabled = true
	end
end

function App.use(self: App, plugin: PluginHost.Plugin)
	PluginHost.install(plugin, {
		appName = self._name,
		registerService = function(registration: ServiceRegistration)
			self:register(registration)
		end,
		provideValue = function(token: AnyToken, value: any)
			self._container:registerValue(token, value)
		end,
		alias = function(aliasToken: AnyToken, target: AnyToken)
			self._container:alias(aliasToken, target)
		end,
		contribute = function(key: string, value: any)
			local list = self._contributions[key]
			if list == nil then
				list = {}
				self._contributions[key] = list
			end
			table.insert(list, value)
		end,
		addCommand = function(commandName: string, fn: (...any) -> ...any)
			if self._commands[commandName] ~= nil then
				Error.throw("E_DUPLICATE_COMMAND", string.format('command "%s" already registered', commandName))
			end
			self._commands[commandName] = fn
		end,
		onLifecycle = function(fn: (phase: string) -> ())
			table.insert(self._lifecycleHooks, fn)
		end,
	})
end

-- Extension seam: plugins contribute values under a key (e.g. net middleware
-- via "net.middleware"); consuming code collects them here.
function App.contributions(self: App, key: string): { any }
	local list = self._contributions[key]
	return if list ~= nil then table.clone(list) else {}
end

function App.command(self: App, commandName: string): ((...any) -> ...any)?
	return self._commands[commandName]
end

-- ------------------------------------------------------------------ contexts

local function makeConfigureContext(self: App, record: ServiceRecord): ConfigureContext
	local ctx = {} :: ConfigureContext
	ctx.name = record.reg.token.name
	function ctx.getConfig(_, key: string): unknown
		return self._config[key]
	end
	function ctx.disable(_)
		record.disabled = true
	end
	function ctx.setMetadata(_, key: string, value: unknown)
		record.metadata[key] = value
	end
	return ctx
end

local function makeServiceContext(self: App, record: ServiceRecord, resolver: ContainerModule.Resolver): ServiceContext
	local bin = BinModule.new()
	record.bin = bin
	local ctx = {} :: ServiceContext
	ctx.name = record.reg.token.name
	ctx.log = self._log:child(record.reg.token.name)
	function ctx.use(_, token: AnyToken): any
		record.usedTokenIds[token.id] = true
		return resolver:resolve(token)
	end
	function ctx.useOptional(_, token: AnyToken): any
		record.usedTokenIds[token.id] = true
		return resolver:tryResolve(token)
	end
	function ctx.getConfig(_, key: string): unknown
		return self._config[key]
	end
	function ctx.getMetadata(_, key: string): unknown
		return record.metadata[key]
	end
	function ctx.own(_, item: any): any
		return bin:own(item)
	end
	function ctx.spawn(_, fn: () -> ())
		bin:own(task.spawn(fn))
	end
	function ctx.onStart(_, fn: () -> ())
		table.insert(record.startCbs, fn)
	end
	function ctx.onReady(_, fn: () -> ())
		table.insert(record.readyCbs, fn)
	end
	function ctx.onShutdown(_, fn: () -> ())
		table.insert(record.shutdownCbs, fn)
	end
	function ctx.onDestroy(_, fn: () -> ())
		table.insert(record.destroyCbs, fn)
	end
	return ctx
end

local function buildInstance(self: App, record: ServiceRecord, resolver: ContainerModule.Resolver): any
	-- Reset per-build state so lazy re-activation gets a clean slate.
	record.startCbs = {}
	record.readyCbs = {}
	record.shutdownCbs = {}
	record.destroyCbs = {}
	record.usedTokenIds = {}
	local ctx = makeServiceContext(self, record, resolver)
	local instance = record.reg.create(ctx)
	record.instance = instance
	record.built = true
	table.insert(self._bootOrder, record)
	return instance
end

-- ------------------------------------------------------------------ helpers

local function runHooks(self: App, phase: string)
	for _, hook in self._lifecycleHooks do
		local ok, err = pcall(hook, phase)
		if not ok then
			self._log:warn(string.format("lifecycle hook failed during %s: %s", phase, tostring(err)))
		end
	end
end

-- Watchdog: flags a step still yielding past its budget. Cooperative
-- scheduling means we can observe yields, not preempt busy-loops.
local function withWatchdog(self: App, label: string, fn: () -> ())
	local done = false
	local watcher = task.delay(self._phaseTimeout, function()
		if not done then
			self._log:warn(string.format(
				"%s has been yielding for over %ds — likely a WaitForChild/network wait that never resolves, or a missed ctx:spawn",
				label, self._phaseTimeout
			))
		end
	end)
	local ok, err = pcall(fn)
	done = true
	pcall(task.cancel, watcher)
	if not ok then
		error(err, 0)
	end
end

local function emergencyUnwind(self: App)
	self._log:error("startup failed — unwinding already-started services in reverse order")
	for i = #self._bootOrder, 1, -1 do
		local record = self._bootOrder[i]
		for j = #record.shutdownCbs, 1, -1 do
			pcall(record.shutdownCbs[j])
		end
		for j = #record.destroyCbs, 1, -1 do
			pcall(record.destroyCbs[j])
		end
		if record.bin ~= nil then
			record.bin:destroy()
		end
	end
	self._phase = "destroyed"
end

function App.graphSpec(self: App): GraphExport.GraphSpec
	local nodes = {}
	local edges: { GraphExport.GraphEdge } = {}
	for _, record in self._records do
		table.insert(nodes, {
			name = record.reg.token.name,
			lazy = record.reg.lazy,
			disabled = record.disabled,
		})
		for _, dep in record.reg.dependencies do
			if self._recordsByTokenId[dep.id] ~= nil then
				table.insert(edges, { from = record.reg.token.name, to = dep.name, optional = false })
			end
		end
		for _, dep in record.reg.optionalDependencies do
			if self._recordsByTokenId[dep.id] ~= nil then
				table.insert(edges, { from = record.reg.token.name, to = dep.name, optional = true })
			end
		end
	end
	return { nodes = nodes, edges = edges }
end

-- ------------------------------------------------------------------ start

function App.start(self: App, options: StartOptions?): StartReport
	local opts: StartOptions = options or {}
	if self._phase ~= "idle" then
		Error.throw("E_LIFECYCLE", string.format('app "%s" already started (phase: %s)', self._name, self._phase))
	end
	self._phase = "starting"
	self._phaseTimeout = opts.phaseTimeout or 10
	if opts.slowThresholdMs ~= nil then
		self._timeline:setSlowThresholdMs(opts.slowThresholdMs)
	end

	-- Phase: configure --------------------------------------------------
	runHooks(self, "configure")
	for _, record in self._records do
		local configure = record.reg.configure
		if configure ~= nil then
			local ctx = makeConfigureContext(self, record)
			local ok, err = self._timeline:record("configure", record.reg.token.name, function()
				configure(ctx)
			end)
			if not ok then
				self._phase = "destroyed"
				Error.throw("E_CONFIGURE_FAILED", string.format(
					'configure of "%s" failed: %s', record.reg.token.name, tostring(err)
				), { related = { record.reg.source } })
			end
		end
	end

	-- Disabled services must not be hard dependencies of enabled ones.
	for _, record in self._records do
		if record.disabled then
			continue
		end
		for _, dep in record.reg.dependencies do
			local depRecord = self._recordsByTokenId[dep.id]
			if depRecord ~= nil and depRecord.disabled then
				self._phase = "destroyed"
				Error.throw("E_DISABLED_DEPENDENCY", string.format(
					'"%s" depends on "%s", which was disabled during configure',
					record.reg.token.name, dep.name
				), {
					fixes = {
						string.format('Disable "%s" as well, or move the edge to optionalDependencies and handle nil', record.reg.token.name),
					},
				})
			end
		end
	end

	-- Register factories for enabled services.
	for _, record in self._records do
		if record.disabled then
			continue
		end
		local frameDeps: { AnyToken } = {}
		for _, dep in record.reg.dependencies do
			table.insert(frameDeps, dep)
		end
		for _, dep in record.reg.optionalDependencies do
			table.insert(frameDeps, dep)
		end
		local capturedRecord = record
		self._container:registerFactory(record.reg.token, function(resolver)
			return buildInstance(self, capturedRecord, resolver)
		end, { lifetime = "singleton", deps = frameDeps })
	end

	-- Phase: resolve ----------------------------------------------------
	runHooks(self, "resolve")
	local nodes: { Graph.GraphNode } = {}
	for _, record in self._records do
		if record.disabled then
			continue
		end
		local deps: { string } = {}
		for _, dep in record.reg.dependencies do
			local depRecord = self._recordsByTokenId[dep.id]
			if depRecord ~= nil then
				table.insert(deps, dep.name)
			elseif not self._container:isRegistered(dep) then
				self._phase = "destroyed"
				Error.throw("E_MISSING_DEPENDENCY", string.format(
					'"%s" depends on "%s", which is neither a registered service nor a provided value',
					record.reg.token.name, dep.name
				), {
					related = { record.reg.source },
					fixes = {
						string.format('Register "%s" in this app, or app:provide(%s.Token, value)', dep.name, dep.name),
						"If it is genuinely optional, move it to optionalDependencies",
					},
				})
			end
			-- Non-service registered values impose no ordering: always ready.
		end
		for _, dep in record.reg.optionalDependencies do
			local depRecord = self._recordsByTokenId[dep.id]
			if depRecord ~= nil and not depRecord.disabled then
				table.insert(deps, dep.name)
			end
		end
		table.insert(nodes, { id = record.reg.token.name, order = record.index, deps = deps })
	end

	local sortResult = Graph.sort(nodes)
	if not sortResult.ok then
		self._phase = "destroyed"
		if sortResult.cycle ~= nil then
			Error.throw("E_CIRCULAR_DEPENDENCY", "service dependencies form a cycle", {
				chain = sortResult.cycle,
				fixes = {
					"Extract the shared piece into a third service both sides depend on",
					"Or make one edge optional and resolve it lazily inside onStart/handlers",
				},
			})
		end
		Error.throw("E_GRAPH", "dependency graph could not be ordered")
	end
	local sorted = sortResult.sorted :: { string }
	self._timeline:mark("resolve", string.format("%d services ordered", #sorted), "ok", nil)
	self._container:seal()

	-- Phase: init -------------------------------------------------------
	runHooks(self, "init")
	for _, name in sorted do
		local record = self._recordsByName[name]
		if record.reg.lazy then
			self._timeline:mark("init", name, "skipped", "lazy")
			continue
		end
		local ok, err = self._timeline:record("init", name, function()
			withWatchdog(self, name .. ".init", function()
				self._container:resolve(record.reg.token)
			end)
		end)
		if not ok then
			emergencyUnwind(self)
			error(err, 0)
		end
	end

	-- Phase: start (fail-fast) ------------------------------------------
	runHooks(self, "start")
	for _, record in table.clone(self._bootOrder) do
		for _, cb in record.startCbs do
			local ok, err = self._timeline:record("start", record.reg.token.name, function()
				withWatchdog(self, record.reg.token.name .. ".onStart", cb)
			end)
			if not ok then
				emergencyUnwind(self)
				error(err, 0)
			end
		end
		record.started = true
	end

	-- Phase: ready (errors reported, not fatal) -------------------------
	runHooks(self, "ready")
	for _, record in table.clone(self._bootOrder) do
		for _, cb in record.readyCbs do
			local ok, err = self._timeline:record("ready", record.reg.token.name, cb)
			if not ok then
				local message = string.format('%s.onReady failed: %s', record.reg.token.name, tostring(err))
				self._log:error(message)
				table.insert(self._warnings, message)
			end
		end
	end

	-- Unused declared dependencies: real graph edges the code never walked.
	for _, record in self._bootOrder do
		for _, dep in record.reg.dependencies do
			if not record.usedTokenIds[dep.id] then
				table.insert(self._warnings, string.format(
					'"%s" declares dependency "%s" but never resolved it during boot (stale edge, or only used later at runtime)',
					record.reg.token.name, dep.name
				))
			end
		end
	end

	self._phase = "ready"
	self._readySignal:Fire()

	local spec = self:graphSpec()
	return {
		timelineText = self._timeline:render(),
		warnings = table.clone(self._warnings),
		graphMermaid = GraphExport.toMermaid(spec),
		graphDot = GraphExport.toDot(spec),
		totalMs = self._timeline:totalMs(),
	}
end

-- ------------------------------------------------------------------ access

function App.get<T>(self: App, token: TokenModule.Token<T>): T
	if self._phase == "idle" and not self._testing then
		Error.throw("E_LIFECYCLE", string.format(
			'app:get("%s") called before app:start()', (token :: AnyToken).name
		), {
			fixes = { "Call app:start() first, or use app:onReady(fn)", "In tests, pass { testing = true } to App.new" },
		})
	end
	return self._container:resolve(token)
end

function App.tryGet<T>(self: App, token: TokenModule.Token<T>): T?
	return self._container:tryResolve(token)
end

function App.phase(self: App): Phase
	return self._phase
end

function App.onReady(self: App, fn: () -> ())
	if self._phase == "ready" then
		task.spawn(fn)
	else
		self._readySignal:Once(fn)
	end
end

-- ---------------------------------------------------------- lazy activation

-- Feature controllers: registered lazy, activated on demand. The service is
-- constructed, its onStart callbacks run fail-fast, and it joins the boot
-- order so shutdown unwinds it like any other service.
function App.activate<T>(self: App, token: TokenModule.Token<T>): T
	local record = self._recordsByTokenId[(token :: AnyToken).id]
	if record == nil then
		Error.throw("E_MISSING_DEPENDENCY", string.format('cannot activate unregistered service "%s"', (token :: AnyToken).name))
	end
	assert(record ~= nil)
	if record.built and record.started then
		return record.instance
	end
	local instance = self._container:resolve(token)
	for _, cb in record.startCbs do
		local ok, err = self._timeline:record("start", record.reg.token.name, function()
			withWatchdog(self, record.reg.token.name .. ".onStart", cb)
		end)
		if not ok then
			self:deactivate(token)
			error(err, 0)
		end
	end
	record.started = true
	for _, cb in record.readyCbs do
		local ok, err = self._timeline:record("ready", record.reg.token.name, cb)
		if not ok then
			self._log:error(string.format('%s.onReady failed: %s', record.reg.token.name, tostring(err)))
		end
	end
	return instance
end

function App.deactivate(self: App, token: AnyToken)
	local record = self._recordsByTokenId[token.id]
	if record == nil or not record.built then
		return
	end
	for i = #record.shutdownCbs, 1, -1 do
		pcall(record.shutdownCbs[i])
	end
	for i = #record.destroyCbs, 1, -1 do
		pcall(record.destroyCbs[i])
	end
	if record.bin ~= nil then
		record.bin:destroy()
	end
	self._container:evict(token)
	local idx = table.find(self._bootOrder, record)
	if idx ~= nil then
		table.remove(self._bootOrder, idx)
	end
	record.built = false
	record.started = false
	record.instance = nil
end

-- ------------------------------------------------------------------ shutdown

function App.shutdown(self: App)
	if self._phase ~= "ready" and self._phase ~= "starting" then
		return
	end
	self._phase = "shutdown"
	runHooks(self, "shutdown")
	for i = #self._bootOrder, 1, -1 do
		local record = self._bootOrder[i]
		for j = #record.shutdownCbs, 1, -1 do
			local ok, err = pcall(record.shutdownCbs[j])
			if not ok then
				self._log:warn(string.format('%s.onShutdown failed: %s', record.reg.token.name, tostring(err)))
			end
		end
	end
	runHooks(self, "destroy")
	for i = #self._bootOrder, 1, -1 do
		local record = self._bootOrder[i]
		for j = #record.destroyCbs, 1, -1 do
			pcall(record.destroyCbs[j])
		end
		if record.bin ~= nil then
			record.bin:destroy()
		end
		record.built = false
		record.started = false
		record.instance = nil
	end
	self._container:dispose()
	self._phase = "destroyed"
end

-- Wire graceful shutdown to server close. Server-side only.
function App.bindToClose(self: App)
	local ok = pcall(function()
		game:BindToClose(function()
			self:shutdown()
		end)
	end)
	if not ok then
		self._log:warn("bindToClose is only available in a Roblox server context")
	end
end

-- ------------------------------------------------------------------ reports

function App.report(self: App): StartReport
	local spec = self:graphSpec()
	return {
		timelineText = self._timeline:render(),
		warnings = table.clone(self._warnings),
		graphMermaid = GraphExport.toMermaid(spec),
		graphDot = GraphExport.toDot(spec),
		totalMs = self._timeline:totalMs(),
	}
end

return App
