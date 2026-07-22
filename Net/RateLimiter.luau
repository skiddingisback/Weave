--!strict

export type RateLimiter = {
	allow: (self: RateLimiter, peerKey: any, endpointId: string, rate: number, burst: number) -> boolean,
	clearPeer: (self: RateLimiter, peerKey: any) -> (),
}

type Bucket = {
	tokens: number,
	lastRefill: number,
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

function RateLimiter.new(): RateLimiter
	local self = setmetatable({
		_peers = {} :: { [any]: { [string]: Bucket } },
	}, RateLimiter)
	return (self :: any) :: RateLimiter
end

-- limits incoming requests per player and endpoint
function RateLimiter:allow(peerKey: any, endpointId: string, rate: number, burst: number): boolean
	local now = os.clock()
	local peerBuckets = self._peers[peerKey]
	if peerBuckets == nil then
		peerBuckets = {}
		self._peers[peerKey] = peerBuckets
	end
	local bucket = peerBuckets[endpointId]
	if bucket == nil then
		bucket = { tokens = burst, lastRefill = now }
		peerBuckets[endpointId] = bucket
	else
		local elapsed = now - bucket.lastRefill
		if elapsed > 0 then
			bucket.tokens = math.min(burst, bucket.tokens + elapsed * rate)
			bucket.lastRefill = now
		end
	end
	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end
	return false
end

-- removes limit tracking when a player leaves
function RateLimiter:clearPeer(peerKey: any)
	self._peers[peerKey] = nil
end

return RateLimiter