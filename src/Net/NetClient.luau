--!strict

local Schema = require(script.Parent.Schema)
local TransportTypes = require(script.Parent.Transport)
local FutureModule = require(script.Parent.Parent.Util.Future)
local Error = require(script.Parent.Parent.Error)
local Log = require(script.Parent.Parent.Log)

type Packet = TransportTypes.Packet

export type NetClientOptions = {
	transport: TransportTypes.ClientTransport,
	namespaces: { any },
	defaultTimeout: number?,
	versionPolicy: ("error" | "warn" | "ignore")?,
	outbound: { (ctx: { endpointId: string, payload: any }) -> () }?,
}

type Pending = {
	future: any,
	endpointId: string,
	timeoutThread: thread?,
}

local NetClient = {}
NetClient.__index = NetClient

export type NetClient = typeof(setmetatable({} :: {
	_transport: TransportTypes.ClientTransport,
	_routes: { [string]: Schema.AnyEndpoint },
	_fingerprint: string,
	_defaultTimeout: number,
	_outbound: { (ctx: { endpointId: string, payload: any }) -> () },
	_pending: { [number]: Pending },
	_nextCorrelation: number,
	_eventHandlers: { [string]: { (payload: any) -> () } },
	_log: Log.Logger,
}, NetClient))

function NetClient.new(options: NetClientOptions): NetClient
	local fingerprint = Schema.fingerprint(options.namespaces)
	local policy = options.versionPolicy or "warn"
	local serverFingerprint = options.transport:serverFingerprint()
	if serverFingerprint ~= nil and serverFingerprint ~= fingerprint and policy ~= "ignore" then
		local message = string.format(
			"schema fingerprint mismatch: client %s vs server %s — client and server were built from different schema versions (rolling deploy skew?)",
			fingerprint, serverFingerprint
		)
		if policy == "error" then
			Error.throw("E_NET_VERSION_MISMATCH", message, {
				fixes = {
					"Redeploy so both sides share the schema modules",
					'Use versionPolicy = "warn" if the game must tolerate skew during rollouts',
				},
			})
		else
			Log.child("NetClient"):warn("E_NET_VERSION_MISMATCH: " .. message)
		end
	end

	local self = setmetatable({
		_transport = options.transport,
		_routes = Schema.buildRoutes(options.namespaces),
		_fingerprint = fingerprint,
		_defaultTimeout = options.defaultTimeout or 10,
		_outbound = options.outbound or {},
		_pending = {},
		_nextCorrelation = 0,
		_eventHandlers = {},
		_log = Log.child("NetClient"),
	}, NetClient)

	options.transport:onReceive(function(packet)
		self:_onPacket(packet)
	end)

	return self :: NetClient
end

local function runOutbound(self: NetClient, endpointId: string, payload: any): any
	if #self._outbound == 0 then
		return payload
	end
	local ctx = { endpointId = endpointId, payload = payload }
	for _, interceptor in self._outbound do
		interceptor(ctx)
	end
	return ctx.payload
end

-- calls a server function and returns a future
function NetClient.callFuture<Req, Res>(self: NetClient, rpc: Schema.Rpc<Req, Res>, request: Req): FutureModule.Future<Res>
	local future = FutureModule.new() :: FutureModule.Future<Res>

	if rpc.kind ~= "rpc" then
		future:fail("E_NET_BAD_CALL: call expects an rpc endpoint; use net:fire for events")
		return future
	end
	if self._routes[rpc.id] == nil then
		future:fail(string.format('E_NET_UNKNOWN_ENDPOINT: "%s" is not in this NetClient\'s namespaces', rpc.id))
		return future
	end

	-- checks payload before sending to catch client bugs early
	local validOk, validated = rpc.requestValidator(request)
	if not validOk then
		future:fail("E_INVALID_ARGUMENT: " .. tostring(validated))
		return future
	end

	self._nextCorrelation += 1
	local correlation = self._nextCorrelation
	local pending: Pending = { future = future, endpointId = rpc.id, timeoutThread = nil }
	self._pending[correlation] = pending

	local timeout = rpc.options.timeout or self._defaultTimeout
	pending.timeoutThread = task.delay(timeout, function()
		if self._pending[correlation] ~= nil then
			self._pending[correlation] = nil
			future:fail("timeout")
		end
	end)

	future:onCancel(function()
		local entry = self._pending[correlation]
		if entry ~= nil then
			self._pending[correlation] = nil
			if entry.timeoutThread ~= nil then
				pcall(task.cancel, entry.timeoutThread)
			end
		end
	end)

	local payload = runOutbound(self, rpc.id, validated)
	self._transport:send({ TransportTypes.PACKET_REQUEST, rpc.id, correlation, payload })
	return future
end

-- calls a server function and waits for the response
function NetClient.call<Req, Res>(self: NetClient, rpc: Schema.Rpc<Req, Res>, request: Req): (boolean, Res | string)
	return self:callFuture(rpc, request):await()
end

-- sends an event to the server
function NetClient.fire<T>(self: NetClient, event: Schema.Event<T>, payload: T)
	if event.kind ~= "event" then
		Error.throw("E_NET_BAD_SEND", "net:fire expects an event endpoint; use net:call for rpcs")
	end
	local validOk, validated = event.payloadValidator(payload)
	if not validOk then
		Error.throw("E_INVALID_ARGUMENT", string.format('outbound payload for "%s": %s', event.id, tostring(validated)))
	end
	local finalPayload = runOutbound(self, event.id, validated)
	self._transport:send({ TransportTypes.PACKET_EVENT, event.id, nil, finalPayload }, event.options.unreliable)
end

-- listens for an event from the server
function NetClient.on<T>(self: NetClient, event: Schema.Event<T>, handler: (payload: T) -> ()): () -> ()
	if event.kind ~= "event" then
		Error.throw("E_NET_BAD_HANDLER", "net:on expects an event endpoint")
	end
	local handlers = self._eventHandlers[event.id]
	if handlers == nil then
		handlers = {}
		self._eventHandlers[event.id] = handlers
	end
	local wrapped = handler :: (any) -> ()
	table.insert(handlers, wrapped)
	return function()
		local idx = table.find(handlers, wrapped)
		if idx ~= nil then
			table.remove(handlers, idx)
		end
	end
end

-- handles incoming network packets
function NetClient._onPacket(self: NetClient, packet: Packet)
	local packetType = packet[1] :: number
	if packetType == TransportTypes.PACKET_RESPONSE then
		local correlation = packet[3] :: number
		local pending = self._pending[correlation]
		if pending == nil then
			return
		end
		self._pending[correlation] = nil
		if pending.timeoutThread ~= nil then
			pcall(task.cancel, pending.timeoutThread)
		end
		local body = packet[4]
		if type(body) ~= "table" then
			pending.future:fail("E_NET_MALFORMED: malformed response body")
			return
		end
		local bodyTable = body :: { any }
		if bodyTable[1] == true then
			local endpoint = self._routes[pending.endpointId]
			if endpoint ~= nil and endpoint.kind == "rpc" then
				local rpc = endpoint :: Schema.Rpc<any, any>
				local validOk, validated = rpc.responseValidator(bodyTable[2])
				if not validOk then
					pending.future:fail("E_NET_SCHEMA_DRIFT: server response failed local schema: " .. tostring(validated))
					return
				end
				pending.future:complete(validated)
			else
				pending.future:complete(bodyTable[2])
			end
		else
			pending.future:fail(tostring(bodyTable[2]) .. ": " .. tostring(bodyTable[3]))
		end
	elseif packetType == TransportTypes.PACKET_EVENT then
		local endpointId = packet[2] :: string
		local endpoint = self._routes[endpointId]
		if endpoint == nil or endpoint.kind ~= "event" then
			return
		end
		local event = endpoint :: Schema.Event<any>
		local validOk, validated = event.payloadValidator(packet[4])
		if not validOk then
			self._log:warn(string.format('inbound event "%s" failed local schema (deploy skew?): %s', endpointId, tostring(validated)))
			return
		end
		local handlers = self._eventHandlers[endpointId]
		if handlers == nil then
			return
		end
		for _, handler in table.clone(handlers) do
			task.spawn(handler, validated)
		end
	end
end

function NetClient.pendingCount(self: NetClient): number
	local count = 0
	for _ in self._pending do
		count += 1
	end
	return count
end

function NetClient.destroy(self: NetClient)
	for correlation, pending in self._pending do
		pending.future:fail("cancelled")
		if pending.timeoutThread ~= nil then
			pcall(task.cancel, pending.timeoutThread)
		end
	end
	table.clear(self._pending)
	self._transport:destroy()
end

return NetClient