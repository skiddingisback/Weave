--!strict

local TransportTypes = require(script.Parent.Transport)

type Packet = TransportTypes.Packet

export type FakePlayer = {
	Name: string,
	UserId: number,
	Parent: any,
}

export type Loopback = {
	server: TransportTypes.ServerTransport,
	connectClient: (self: Loopback, name: string) -> (TransportTypes.ClientTransport, FakePlayer),
	disconnectClient: (self: Loopback, player: FakePlayer) -> (),
	fingerprint: string?,
}

local LoopbackTransport = {}

-- mock network transport for testing without a datamodel
function LoopbackTransport.create(fingerprint: string?): Loopback
	local serverReceive: ((peer: any, packet: Packet) -> ())? = nil
	local peerRemovingHandlers: { (peer: any) -> () } = {}
	local clientReceivers: { [FakePlayer]: (packet: Packet) -> () } = {}
	local nextUserId = 0

	local server = {} :: TransportTypes.ServerTransport
	function server.send(_, peer: any, packet: Packet, _unreliable: boolean?)
		local receiver = clientReceivers[peer :: FakePlayer]
		if receiver ~= nil then
			task.defer(receiver, packet)
		end
	end
	function server.broadcast(_, packet: Packet, _unreliable: boolean?)
		for _, receiver in clientReceivers do
			task.defer(receiver, packet)
		end
	end
	function server.onReceive(_, handler: (peer: any, packet: Packet) -> ())
		serverReceive = handler
	end
	function server.onPeerRemoving(_, handler: (peer: any) -> ())
		table.insert(peerRemovingHandlers, handler)
	end
	function server.destroy(_)
		serverReceive = nil
		table.clear(clientReceivers)
	end

	local loopback = {
		server = server,
		fingerprint = fingerprint,
	} :: Loopback

	-- creates a mock player and connects them to the server
	function loopback.connectClient(_, name: string): (TransportTypes.ClientTransport, FakePlayer)
		nextUserId += 1
		local player: FakePlayer = { Name = name, UserId = nextUserId, Parent = {} }
		local client = {} :: TransportTypes.ClientTransport
		function client.send(_, packet: Packet, _unreliable: boolean?)
			local handler = serverReceive
			if handler ~= nil then
				task.defer(handler, player, packet)
			end
		end
		function client.onReceive(_, handler: (packet: Packet) -> ())
			clientReceivers[player] = handler
		end
		function client.serverFingerprint(_): string?
			return fingerprint
		end
		function client.destroy(_)
			clientReceivers[player] = nil
		end
		return client, player
	end

	-- drops a player and triggers leave events
	function loopback.disconnectClient(_, player: FakePlayer)
		clientReceivers[player] = nil
		player.Parent = nil
		for _, handler in peerRemovingHandlers do
			task.spawn(handler, player)
		end
	end

	return loopback
end

return LoopbackTransport