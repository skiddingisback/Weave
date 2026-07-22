--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local TransportTypes = require(script.Parent.Transport)

type Packet = TransportTypes.Packet
type Codec = TransportTypes.Codec

local FOLDER_NAME = "WeaveNet"
local RELIABLE_NAME = "Reliable"
local UNRELIABLE_NAME = "Unreliable"
local FINGERPRINT_ATTR = "SchemaFingerprint"

local RobloxTransport = {}

local ServerTransport = {}
ServerTransport.__index = ServerTransport

export type ServerOptions = {
	fingerprint: string,
	codec: Codec?,
	folderName: string?,
}

-- sets up server remotes and queues outbound packets
function RobloxTransport.createServer(options: ServerOptions): TransportTypes.ServerTransport
	local codec = options.codec or TransportTypes.IdentityCodec

	local folder = Instance.new("Folder")
	folder.Name = options.folderName or FOLDER_NAME
	folder:SetAttribute(FINGERPRINT_ATTR, options.fingerprint)

	local reliable = Instance.new("RemoteEvent")
	reliable.Name = RELIABLE_NAME
	reliable.Parent = folder

	local unreliable = Instance.new("UnreliableRemoteEvent")
	unreliable.Name = UNRELIABLE_NAME
	unreliable.Parent = folder

	folder.Parent = ReplicatedStorage

	local self = setmetatable({
		_folder = folder,
		_reliable = reliable,
		_unreliable = unreliable,
		_codec = codec,
		_receiveHandler = nil :: ((peer: any, packet: Packet) -> ())?,
		_peerRemovingHandlers = {} :: { (peer: any) -> () },
		_queues = {} :: { [Player]: { reliable: { Packet }, unreliable: { Packet } } },
		_broadcastReliable = {} :: { Packet },
		_broadcastUnreliable = {} :: { Packet },
		_connections = {} :: { RBXScriptConnection },
	}, ServerTransport)

	table.insert(self._connections, reliable.OnServerEvent:Connect(function(player: Player, wire: unknown)
		self:_dispatch(player, wire)
	end))
	table.insert(self._connections, unreliable.OnServerEvent:Connect(function(player: Player, wire: unknown)
		self:_dispatch(player, wire)
	end))
	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player: Player)
		self._queues[player] = nil
		for _, handler in self._peerRemovingHandlers do
			task.spawn(handler, player)
		end
	end))
	table.insert(self._connections, RunService.Heartbeat:Connect(function()
		self:_flush()
	end))

	return (self :: any) :: TransportTypes.ServerTransport
end

function ServerTransport:_dispatch(player: Player, wire: unknown)
	local decodeOk, decoded = pcall(self._codec.decode, wire)
	if not decodeOk then
		return
	end
	local batch = TransportTypes.validateBatch(decoded)
	if batch == nil then
		return
	end
	local handler = self._receiveHandler
	if handler == nil then
		return
	end
	for _, packet in batch do
		task.spawn(handler, player, packet)
	end
end

function ServerTransport:_queueFor(player: Player)
	local queue = self._queues[player]
	if queue == nil then
		queue = { reliable = {}, unreliable = {} }
		self._queues[player] = queue
	end
	return queue
end

-- queues a packet to send to one player
function ServerTransport:send(peer: any, packet: Packet, unreliable: boolean?)
	local player = peer :: Player
	if player.Parent == nil then
		return
	end
	local queue = self:_queueFor(player)
	if unreliable then
		table.insert(queue.unreliable, packet)
	else
		table.insert(queue.reliable, packet)
	end
end

-- queues a packet to send to all players
function ServerTransport:broadcast(packet: Packet, unreliable: boolean?)
	if unreliable then
		table.insert(self._broadcastUnreliable, packet)
	else
		table.insert(self._broadcastReliable, packet)
	end
end

-- sends queued packets out every frame
function ServerTransport:_flush()
	if #self._broadcastReliable > 0 then
		local batch = self._broadcastReliable
		self._broadcastReliable = {}
		self._reliable:FireAllClients(self._codec.encode(batch))
	end
	if #self._broadcastUnreliable > 0 then
		local batch = self._broadcastUnreliable
		self._broadcastUnreliable = {}
		self._unreliable:FireAllClients(self._codec.encode(batch))
	end
	for player, queue in self._queues do
		if #queue.reliable > 0 then
			local batch = queue.reliable
			queue.reliable = {}
			self._reliable:FireClient(player, self._codec.encode(batch))
		end
		if #queue.unreliable > 0 then
			local batch = queue.unreliable
			queue.unreliable = {}
			self._unreliable:FireClient(player, self._codec.encode(batch))
		end
	end
end

function ServerTransport:onReceive(handler: (peer: any, packet: Packet) -> ())
	self._receiveHandler = handler
end

function ServerTransport:onPeerRemoving(handler: (peer: any) -> ())
	table.insert(self._peerRemovingHandlers, handler)
end

function ServerTransport:destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self._folder:Destroy()
	table.clear(self._queues)
end

local ClientTransport = {}
ClientTransport.__index = ClientTransport

export type ClientOptions = {
	codec: Codec?,
	folderName: string?,
	handshakeTimeout: number?,
}

-- connects to server remotes and sets up packet batching
function RobloxTransport.createClient(options: ClientOptions?): TransportTypes.ClientTransport
	local opts: ClientOptions = options or {}
	local codec = opts.codec or TransportTypes.IdentityCodec

	local folder = ReplicatedStorage:WaitForChild(opts.folderName or FOLDER_NAME, opts.handshakeTimeout or 15)
	if folder == nil then
		error("[Weave] E_NET_HANDSHAKE: WeaveNet folder not found in ReplicatedStorage — is a Weave NetServer running with a RobloxTransport?", 2)
	end
	local reliable = folder:WaitForChild(RELIABLE_NAME, 5) :: RemoteEvent
	local unreliable = folder:WaitForChild(UNRELIABLE_NAME, 5) :: UnreliableRemoteEvent

	local self = setmetatable({
		_codec = codec,
		_reliable = reliable,
		_unreliable = unreliable,
		_fingerprint = folder:GetAttribute("SchemaFingerprint") :: string?,
		_receiveHandler = nil :: ((packet: Packet) -> ())?,
		_reliableQueue = {} :: { Packet },
		_unreliableQueue = {} :: { Packet },
		_connections = {} :: { RBXScriptConnection },
	}, ClientTransport)

	local function dispatch(wire: unknown)
		local decodeOk, decoded = pcall(self._codec.decode, wire)
		if not decodeOk then
			return
		end
		local batch = TransportTypes.validateBatch(decoded)
		if batch == nil then
			return
		end
		local handler = self._receiveHandler
		if handler == nil then
			return
		end
		for _, packet in batch do
			task.spawn(handler, packet)
		end
	end

	table.insert(self._connections, reliable.OnClientEvent:Connect(dispatch))
	table.insert(self._connections, unreliable.OnClientEvent:Connect(dispatch))
	table.insert(self._connections, RunService.Heartbeat:Connect(function()
		if #self._reliableQueue > 0 then
			local batch = self._reliableQueue
			self._reliableQueue = {}
			self._reliable:FireServer(self._codec.encode(batch))
		end
		if #self._unreliableQueue > 0 then
			local batch = self._unreliableQueue
			self._unreliableQueue = {}
			self._unreliable:FireServer(self._codec.encode(batch))
		end
	end))

	return (self :: any) :: TransportTypes.ClientTransport
end

-- queues a packet to send to the server
function ClientTransport:send(packet: Packet, unreliable: boolean?)
	if unreliable then
		table.insert(self._unreliableQueue, packet)
	else
		table.insert(self._reliableQueue, packet)
	end
end

function ClientTransport:onReceive(handler: (packet: Packet) -> ())
	self._receiveHandler = handler
end

function ClientTransport:serverFingerprint(): string?
	return self._fingerprint
end

function ClientTransport:destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
end

return RobloxTransport