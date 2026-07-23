--!strict

export type PacketType = number

export type Packet = { any }

export type Codec = {
	name: string,
	encode: (batch: { Packet }) -> any,
	decode: (wire: any) -> { Packet },
}

export type ServerTransport = {
	send: (self: ServerTransport, peer: any, packet: Packet, unreliable: boolean?) -> (),
	broadcast: (self: ServerTransport, packet: Packet, unreliable: boolean?) -> (),
	onReceive: (self: ServerTransport, handler: (peer: any, packet: Packet) -> ()) -> (),
	onPeerRemoving: (self: ServerTransport, handler: (peer: any) -> ()) -> (),
	destroy: (self: ServerTransport) -> (),
}

export type ClientTransport = {
	send: (self: ClientTransport, packet: Packet, unreliable: boolean?) -> (),
	onReceive: (self: ClientTransport, handler: (packet: Packet) -> ()) -> (),
	serverFingerprint: (self: ClientTransport) -> string?,
	destroy: (self: ClientTransport) -> (),
}

local Transport = {}

Transport.PACKET_EVENT = 1 :: PacketType
Transport.PACKET_REQUEST = 2 :: PacketType
Transport.PACKET_RESPONSE = 3 :: PacketType

Transport.IdentityCodec = {
	name = "identity",
	encode = function(batch: { Packet }): any
		return batch
	end,
	decode = function(wire: any): { Packet }
		return wire
	end,
} :: Codec

-- drops malformed packet arrays sent from a client
function Transport.validateBatch(wire: unknown): { Packet }?
	if type(wire) ~= "table" then
		return nil
	end
	local batch = wire :: { unknown }
	for i = 1, #batch do
		local packet = batch[i]
		if type(packet) ~= "table" then
			return nil
		end
		local p = packet :: { unknown }
		local packetType = p[1]
		if packetType ~= 1 and packetType ~= 2 and packetType ~= 3 then
			return nil
		end
		if type(p[2]) ~= "string" then
			return nil
		end
		if p[3] ~= nil and type(p[3]) ~= "number" then
			return nil
		end
	end
	return batch :: { Packet }
end

return Transport