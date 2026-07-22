--!strict

local Schema = require(script.Parent.Schema)
local TransportTypes = require(script.Parent.Transport)
local RateLimiterModule = require(script.Parent.RateLimiter)
local Pipeline = require(script.Parent.Parent.Middleware.Pipeline)
local Error = require(script.Parent.Parent.Error)
local Log = require(script.Parent.Parent.Log)

type Packet = TransportTypes.Packet

export type ServerNetContext = {
	player: any,
	endpointId: string,
	kind: "rpc" | "event",
	payload: any,
	meta: { [string]: any },
	denyCode: string?,
	denyMessage: string?,
}

export type ServerMiddleware = Pipeline.Middleware<ServerNetContext>

export type EndpointStats = {
	inbound: number,
	outbound: number,
	errors: number,
	rateLimited: number,
	invalid: number,
	handlerMs: number,
}

export type NetServerOptions = {
	transport: TransportTypes.ServerTransport,
	namespaces: { any },
	middleware: { ServerMiddleware }?,
	outbound: { (ctx: { player: any?, endpointId: string, payload: any }) -> () }?,
	defaultRate: number?,
	defaultBurst: number?,
	validateOutbound: boolean?,
	onRateLimited: ((player: any, endpointId: string) -> ())?,
	onInvalid: ((player: any, endpointId: string, reason: string) -> ())?,
}

local NetServer = {}
NetServer.__index = NetServer

export type NetServer = typeof(setmetatable({} :: {
	_transport: TransportTypes.ServerTransport,
	_routes: { [string]: Schema.AnyEndpoint },
	_fingerprint: string,
	_handlers: { [string]: (player: any, payload: any) -> any },
	_eventHandlers: { [string]: { (player: any, payload: any) -> () } },
	_pipelines: { [string]: (ServerNetContext) -> () },
	_globalMiddleware: { ServerMiddleware },
	_outbound: { (ctx: { player: any?, endpointId: string, payload: any }) -> () },
	_rateLimiter: RateLimiterModule.RateLimiter,
	_defaultRate: number,
	_defaultBurst: number,
	_validateOutbound: boolean,
	_onRateLimited: ((player: any, endpointId: string) -> ())?,
	_onInvalid: ((player: any, endpointId: string, reason: string) -> ())?,
	_stats: { [string]: EndpointStats },
	_log: Log.Logger,
}, NetServer))

function NetServer.new(options: NetServerOptions): NetServer
	local self = setmetatable({
		_transport = options.transport,
		_routes = Schema.buildRoutes(options.namespaces),
		_fingerprint = Schema.fingerprint(options.namespaces),
		_handlers = {},
		_eventHandlers = {},
		_pipelines = {},
		_globalMiddleware = options.middleware or {},
		_outbound = options.outbound or {},
		_rateLimiter = RateLimiterModule.new(),
		_defaultRate = options.defaultRate or 30,
		_defaultBurst = options.defaultBurst or 60,
		_validateOutbound = options.validateOutbound == true,
		_onRateLimited = options.onRateLimited,
		_onInvalid = options.onInvalid,
		_stats = {},
		_log = Log.child("NetServer"),
	}, NetServer)

	options.transport:onReceive(function(peer, packet)
		self:_onPacket(peer, packet)
	end)
	options.transport:onPeerRemoving(function(peer)
		self._rateLimiter:clearPeer(peer)
	end)

	return self :: NetServer
end

function NetServer.fingerprint(self: NetServer): string
	return self._fingerprint
end

local function statsFor(self: NetServer, endpointId: string): EndpointStats
	local stats = self._stats[endpointId]
	if stats == nil then
		stats = { inbound = 0, outbound = 0, errors = 0, rateLimited = 0, invalid = 0, handlerMs = 0 }
		self._stats[endpointId] = stats
	end
	return stats
end

-- registers a callback for server rpc calls
function NetServer.handle<Req, Res>(self: NetServer, rpc: Schema.Rpc<Req, Res>, handler: (player: Player, request: Req) -> Res)
	if rpc.kind ~= "rpc" then
		Error.throw("E_NET_BAD_HANDLER", "net:handle expects an rpc endpoint; use net:on for events")
	end
	if self._routes[rpc.id] == nil then
		Error.throw("E_NET_UNKNOWN_ENDPOINT", string.format('"%s" is not in this NetServer\'s namespaces', rpc.id), {
			fixes = { "Pass the endpoint's namespace in NetServer.new{ namespaces = { ... } }" },
		})
	end
	if self._handlers[rpc.id] ~= nil then
		Error.throw("E_NET_DUPLICATE_HANDLER", string.format('rpc "%s" already has a handler', rpc.id))
	end
	self._handlers[rpc.id] = handler :: (any, any) -> any
end

-- listens for events sent from a client
function NetServer.on<T>(self: NetServer, event: Schema.Event<T>, handler: (player: Player, payload: T) -> ())
	if event.kind ~= "event" then
		Error.throw("E_NET_BAD_HANDLER", "net:on expects an event endpoint; use net:handle for rpcs")
	end
	if self._routes[event.id] == nil then
		Error.throw("E_NET_UNKNOWN_ENDPOINT", string.format('"%s" is not in this NetServer\'s namespaces', event.id))
	end
	local handlers = self._eventHandlers[event.id]
	if handlers == nil then
		handlers = {}
		self._eventHandlers[event.id] = handlers
	end
	table.insert(handlers, handler :: (any, any) -> ())
end

local function runOutbound(self: NetServer, player: any?, endpointId: string, payload: any): any
	if #self._outbound == 0 then
		return payload
	end
	local ctx = { player = player, endpointId = endpointId, payload = payload }
	for _, interceptor in self._outbound do
		interceptor(ctx)
	end
	return ctx.payload
end

-- sends an event to a single player
function NetServer.fire<T>(self: NetServer, event: Schema.Event<T>, player: Player, payload: T)
	self:_sendEvent(event, player, payload)
end

-- sends an event to all connected players
function NetServer.broadcast<T>(self: NetServer, event: Schema.Event<T>, payload: T)
	self:_sendEvent(event, nil, payload)
end

function NetServer._sendEvent<T>(self: NetServer, event: Schema.Event<T>, player: Player?, payload: T)
	if event.kind ~= "event" then
		Error.throw("E_NET_BAD_SEND", "fire/broadcast expects an event endpoint")
	end
	if self._validateOutbound then
		local ok, result = event.payloadValidator(payload)
		if not ok then
			Error.throw("E_NET_OUTBOUND_INVALID", string.format('outbound payload for "%s" failed its own schema: %s', event.id, tostring(result)), {
				fixes = { "The server is producing data that violates its declared schema — fix the producer or the schema" },
			})
		end
	end
	local finalPayload = runOutbound(self, player, event.id, payload)
	local packet: Packet = { TransportTypes.PACKET_EVENT, event.id, nil, finalPayload }
	statsFor(self, event.id).outbound += 1
	if player ~= nil then
		self._transport:send(player, packet, event.options.unreliable)
	else
		self._transport:broadcast(packet, event.options.unreliable)
	end
end

local function replyError(self: NetServer, peer: any, endpointId: string, correlation: number, code: string, message: string)
	statsFor(self, endpointId).errors += 1
	local packet: Packet = { TransportTypes.PACKET_RESPONSE, endpointId, correlation, { false, code, message } }
	self._transport:send(peer, packet)
end

-- gets or creates the compiled middleware chain for an endpoint
function NetServer._pipelineFor(self: NetServer, endpoint: Schema.AnyEndpoint): (ServerNetContext) -> ()
	local cached = self._pipelines[endpoint.id]
	if cached ~= nil then
		return cached
	end
	local terminal: (ServerNetContext) -> ()
	if endpoint.kind == "rpc" then
		local rpc = endpoint :: Schema.Rpc<any, any>
		terminal = function(ctx: ServerNetContext)
			(ctx.meta :: any).__reachedTerminal = true
		end
		local _ = rpc
	else
		terminal = function(ctx: ServerNetContext)
			(ctx.meta :: any).__reachedTerminal = true
		end
	end
	local compiled = Pipeline.compile(self._globalMiddleware, terminal)
	self._pipelines[endpoint.id] = compiled
	return compiled
end

-- processes all incoming network packets from clients
function NetServer._onPacket(self: NetServer, peer: any, packet: Packet)
	local packetType = packet[1] :: number
	local endpointId = packet[2] :: string
	local endpoint = self._routes[endpointId]
	if endpoint == nil then
		statsFor(self, "<unknown>").invalid += 1
		return
	end
	local stats = statsFor(self, endpointId)
	stats.inbound += 1

	-- drops packets early if client exceeds request speed
	local rate = endpoint.options.rate or self._defaultRate
	local burst = endpoint.options.burst or (endpoint.options.rate ~= nil and endpoint.options.rate * 2) or self._defaultBurst
	if not self._rateLimiter:allow(peer, endpointId, rate, burst) then
		stats.rateLimited += 1
		if self._onRateLimited ~= nil then
			task.spawn(self._onRateLimited :: any, peer, endpointId)
		end
		if packetType == TransportTypes.PACKET_REQUEST then
			replyError(self, peer, endpointId, packet[3] :: number, "E_RATE_LIMITED", "too many requests")
		end
		return
	end

	local ctx: ServerNetContext = {
		player = peer,
		endpointId = endpointId,
		kind = if endpoint.kind == "rpc" then "rpc" else "event",
		payload = packet[4],
		meta = {},
		denyCode = nil,
		denyMessage = nil,
	}

	local pipeline = self:_pipelineFor(endpoint)
	local middlewareOk, middlewareErr = pcall(pipeline, ctx)

	local denied = not middlewareOk or not (ctx.meta :: any).__reachedTerminal
	if denied then
		local code = ctx.denyCode or "E_DENIED"
		local message = ctx.denyMessage or (if middlewareOk then "request denied by middleware" else "middleware error")
		if not middlewareOk then
			self._log:warn(string.format('middleware error on "%s": %s', endpointId, tostring(middlewareErr)))
		end
		if packetType == TransportTypes.PACKET_REQUEST then
			replyError(self, peer, endpointId, packet[3] :: number, code, message)
		else
			stats.errors += 1
		end
		return
	end

	if packetType == TransportTypes.PACKET_REQUEST then
		if endpoint.kind ~= "rpc" then
			replyError(self, peer, endpointId, packet[3] :: number, "E_NET_KIND_MISMATCH", "endpoint is not an rpc")
			return
		end
		self:_handleRequest(peer, endpoint :: Schema.Rpc<any, any>, packet[3] :: number, ctx, stats)
	elseif packetType == TransportTypes.PACKET_EVENT then
		if endpoint.kind ~= "event" then
			stats.invalid += 1
			return
		end
		self:_handleEvent(peer, endpoint :: Schema.Event<any>, ctx, stats)
	end
end

function NetServer._handleRequest(
	self: NetServer,
	peer: any,
	rpc: Schema.Rpc<any, any>,
	correlation: number,
	ctx: ServerNetContext,
	stats: EndpointStats
)
	local validOk, validated = rpc.requestValidator(ctx.payload)
	if not validOk then
		stats.invalid += 1
		if self._onInvalid ~= nil then
			task.spawn(self._onInvalid :: any, peer, rpc.id, validated :: string)
		end
		replyError(self, peer, rpc.id, correlation, "E_INVALID_ARGUMENT", validated :: string)
		return
	end

	local handler = self._handlers[rpc.id]
	if handler == nil then
		replyError(self, peer, rpc.id, correlation, "E_NO_HANDLER", string.format('no handler registered for "%s"', rpc.id))
		return
	end

	local startedAt = os.clock()
	local handlerOk, result = pcall(handler, peer, validated)
	stats.handlerMs += (os.clock() - startedAt) * 1000

	if not handlerOk then
		self._log:error(string.format('handler error on "%s": %s', rpc.id, tostring(result)))
		replyError(self, peer, rpc.id, correlation, "E_HANDLER_ERROR", "internal error")
		return
	end

	local responseOk, responseValidated = rpc.responseValidator(result)
	if not responseOk then
		self._log:error(string.format('response for "%s" failed its own schema: %s', rpc.id, tostring(responseValidated)))
		replyError(self, peer, rpc.id, correlation, "E_HANDLER_ERROR", "internal error")
		return
	end

	local finalPayload = runOutbound(self, peer, rpc.id, responseValidated)
	stats.outbound += 1
	self._transport:send(peer, { TransportTypes.PACKET_RESPONSE, rpc.id, correlation, { true, finalPayload } })
end

function NetServer._handleEvent(self: NetServer, peer: any, event: Schema.Event<any>, ctx: ServerNetContext, stats: EndpointStats)
	local validOk, validated = event.payloadValidator(ctx.payload)
	if not validOk then
		stats.invalid += 1
		if self._onInvalid ~= nil then
			task.spawn(self._onInvalid :: any, peer, event.id, validated :: string)
		end
		return
	end
	local handlers = self._eventHandlers[event.id]
	if handlers == nil then
		return
	end
	for _, handler in handlers do
		task.spawn(handler, peer, validated)
	end
end

-- returns raw usage stats for all endpoints
function NetServer.stats(self: NetServer): { [string]: EndpointStats }
	local out = {}
	for endpointId, stats in self._stats do
		out[endpointId] = table.clone(stats)
	end
	return out
end

-- builds a plain text table showing network traffic and errors
function NetServer.renderStats(self: NetServer): string
	local lines = { "Network endpoints:" }
	table.insert(lines, string.format("    %-32s %8s %8s %6s %6s %8s %10s", "ENDPOINT", "IN", "OUT", "ERR", "LIMIT", "INVALID", "HANDLER"))
	local ids = {}
	for endpointId in self._stats do
		table.insert(ids, endpointId)
	end
	table.sort(ids)
	for _, endpointId in ids do
		local s = self._stats[endpointId]
		table.insert(lines, string.format(
			"    %-32s %8d %8d %6d %6d %8d %8.1fms",
			endpointId, s.inbound, s.outbound, s.errors, s.rateLimited, s.invalid, s.handlerMs
		))
	end
	return table.concat(lines, "\n")
end

function NetServer.destroy(self: NetServer)
	self._transport:destroy()
end

return NetServer