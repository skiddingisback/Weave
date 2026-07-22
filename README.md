# Weave

A modern application framework for Roblox. Strict Luau, zero runtime dependencies, deterministic startup, schema-first validated networking. Weave is a from-first-principles redesign of the space Knit occupied, built for large production games: hundreds of modules, dozens of services, multiple developers, Rojo, CI, automated tests, and hot reload.

## Installation

Sync the `Weave` folder anywhere shared — `ReplicatedStorage/Weave` is conventional. There are no dependencies to install; Weave has none.

```json
{ "ReplicatedStorage": { "Weave": { "$path": "Weave" } } }
```

## Core concepts

**Tokens are typed identity.** Every service has a small *definition module* that exports its API type and a token cast against it. This is the module both implementations and consumers require — implementations never require each other, which is what keeps big graphs cycle-free at the `require` level and gives you full autocomplete on every service everywhere.

```lua
-- DataService/definition.luau
local Weave = require(game.ReplicatedStorage.Weave)
export type API = {
	read: (self: API, player: Player, key: string) -> number,
	write: (self: API, player: Player, key: string, value: number) -> (),
}
return { Token = Weave.token("DataService") :: Weave.Token<API> }
```

**Services declare their world.** The implementation module returns `Weave.service{...}`. Dependencies are declared (that's what makes ordering, cycle detection, and the graph tooling possible) and resolved with full types via `ctx:use`. Lifecycle callbacks are registered on the context.

```lua
-- ShopService/init.luau
local Weave = require(game.ReplicatedStorage.Weave)
local Def = require(script.definition)
local DataDef = require(script.Parent.DataService.definition)

return Weave.service({
	token = Def.Token,
	dependencies = { DataDef.Token },
	metadata = { version = "2.1.0", tags = { "economy" } },
	create = function(ctx): Def.API
		local data = ctx:use(DataDef.Token)          -- typed as DataDef.API
		local self = {} :: Def.API

		function self.buy(_, player, itemId)
			local balance = data:read(player, "balance")
			-- ...
		end

		ctx:onStart(function()                        -- fail-fast, topo order
			ctx.log:info("shop open")
		end)
		ctx:spawn(function()                          -- managed loop, cancelled at shutdown
			while true do task.wait(60) end
		end)
		ctx:onShutdown(function() --[[ flush ]] end)
		return self
	end,
})
```

The context in full: `ctx:use(token)` / `ctx:useOptional(token)` (typed dependency resolution — only declared tokens allowed), `ctx:own(x)` (connections/instances/threads released automatically at shutdown), `ctx:spawn(fn)`, `ctx:onStart / onReady / onShutdown / onDestroy`, `ctx.log`, `ctx:getConfig(key)`, `ctx:getMetadata(key)`.

**Apps are isolated worlds.** Nothing in Weave is global. A server has one App, a client has one App, and every test can have its own.

```lua
-- Server bootstrap script
local Weave = require(game.ReplicatedStorage.Weave)
local app = Weave.App.new({ name = "Server", config = { maxPets = 3 } })
app:registerMany(require(game.ServerScriptService.Registry)) -- an explicit list
local report = app:start({ phaseTimeout = 10 })
print(report.timelineText)   -- per-service, per-phase timings + allocation
print(report.graphMermaid)   -- paste into any Mermaid renderer
app:bindToClose()            -- graceful shutdown on server close
```

The registry is an explicit list module (`return { require(a), require(b), ... }`) rather than a folder scan. Explicit registries are deterministic, reviewable in diffs, feature-gateable, and free of the require-everything-at-boot cost; if you want folder loading, a ten-line helper over `GetChildren` composes fine on top.

**Controllers are services.** On the client, register the same shape into a client-side App. Feature controllers use `lazy = true` and activate on demand:

```lua
app:activate(TradingUIDef.Token)    -- constructs, runs onStart/onReady
app:deactivate(TradingUIDef.Token)  -- onShutdown/onDestroy + Bin cleanup
```

**Configure phase gates features.** A `configure` hook runs before the graph is built and may `ctx:disable()` the service (platform gating, feature flags). Disabling something another enabled service hard-depends on is a startup error that names the dependents.

## Networking

Schemas are shared modules; validators are the types.

```lua
-- Shared/Schemas/Shop.luau
local Weave = require(game.ReplicatedStorage.Weave)
local Net, Check = Weave.Net, Weave.Check

return Net.namespace("Shop", {
	buy = Net.rpc(
		Check.shape({ itemId = Check.stringMaxLen(64) }),
		Check.shape({ ok = Check.boolean, balance = Check.number }),
		{ rate = 5, burst = 10, timeout = 8 }
	),
	granted = Net.event(Check.shape({ itemId = Check.string })),
	move = Net.event(Check.shape({ position = Check.robloxType("Vector3") }), { unreliable = true }),
})
```

```lua
-- Server
local Shop = require(game.ReplicatedStorage.Shared.Schemas.Shop)
local net = Weave.Net.Server.new({
	transport = Weave.Net.RobloxTransport.createServer({
		fingerprint = Weave.Net.fingerprint({ Shop }),
	}),
	namespaces = { Shop },
	middleware = app:contributions("net.middleware"), -- plugin seam
	validateOutbound = game:GetService("RunService"):IsStudio(),
})
net:handle(Shop.buy, function(player, req)   -- req: { itemId: string }, validated
	return { ok = true, balance = 120 }       -- return type checked against schema
end)
net:broadcast(Shop.granted, { itemId = "sword" })
print(net:renderStats())                      -- per-endpoint network inspector

-- Client
local net = Weave.Net.Client.new({
	transport = Weave.Net.RobloxTransport.createClient(),
	namespaces = { Shop },
	versionPolicy = "warn",                   -- fingerprint handshake policy
})
local ok, res = net:call(Shop.buy, { itemId = "sword" })     -- (false, "timeout") after 8s
local future = net:callFuture(Shop.buy, { itemId = "bow" })  -- :cancel() supported
net:on(Shop.granted, function(payload) ... end)
```

Guarantees: every inbound payload is validated before any handler runs; every endpoint is rate-limited (defaults 30/s, burst 60, per player) before anything else runs; RPC never uses RemoteFunction, so timeouts and cancellation always work; all traffic multiplexes over two remotes with per-frame batching; the schema fingerprint turns client/server version skew into an explicit policy event. Handler errors reach the caller as structured `"CODE: message"` strings — internals are logged server-side, never leaked to clients.

Middleware uses the shared pipeline model — `(ctx, next)` with a typed context — and covers auth, logging, metrics, and denial:

```lua
local function requireAdmin(ctx, next)
	if not Admins[ctx.player.UserId] then
		ctx.denyCode, ctx.denyMessage = "E_FORBIDDEN", "admin only"
		return -- not calling next() denies; rpc callers get the structured error
	end
	next()
end
```

## Testing

The container, lifecycle, and the full networking protocol run without a DataModel (Lune-compatible). Two patterns cover most needs:

```lua
-- Unit: isolated app, mocked dependency
local app = Weave.App.new({ name = "test", testing = true })
app:register(ShopService)
app:override(DataDef.Token, fakeData)   -- ShopService now sees the fake
app:register(...)                        -- register the rest, or just the slice under test
app:start()
local shop = app:get(ShopDef.Token)

-- Integration: full net stack in memory
local loop = Weave.Net.LoopbackTransport.create("test")
local server = Weave.Net.Server.new({ transport = loop.server, namespaces = { Shop } })
local clientTransport, fakePlayer = loop:connectClient("Alice")
local client = Weave.Net.Client.new({ transport = clientTransport, namespaces = { Shop }, versionPolicy = "ignore" })
```

## Plugins

```lua
return {
	name = "Analytics",
	version = "1.0.0",
	install = function(api)
		api.registerService(AnalyticsService)
		api.contribute("net.middleware", metricsMiddleware)
		api.addCommand("analytics.flush", function() ... end)
		api.onLifecycle(function(phase) ... end)
	end,
}
-- app:use(plugin) before app:start()
```

Plugins receive a capability object, not the App: they can add, but they flow through the same duplicate/cycle/type validation as first-party code and cannot reach into internals.

## Diagnostics

`app:start()` and `app:report()` return: the startup timeline (per phase, per service, wall time + heap-delta, slow/error flags), warnings (undeclared dependency use, declared-but-unused edges, non-fatal ready failures), and the dependency graph as Mermaid and DOT. `net:stats()` / `net:renderStats()` give per-endpoint inbound/outbound/error/rate-limited/invalid counts and cumulative handler time. Every framework error is structured: code, message, dependency chain, suggested fixes, source location.

## Error codes (selection)

`E_CIRCULAR_DEPENDENCY` (prints the full cycle path), `E_MISSING_DEPENDENCY` (names every dependent), `E_DUPLICATE_REGISTRATION` (both source locations), `E_UNDECLARED_DEPENDENCY` (warn by default; `strictDependencies = true` escalates), `E_DISABLED_DEPENDENCY`, `E_RATE_LIMITED`, `E_INVALID_ARGUMENT`, `E_HANDLER_ERROR`, `E_NET_VERSION_MISMATCH`, `E_NET_SCHEMA_DRIFT`.

## Design notes & deliberate seams

Serialization/compression is a `Codec` on the transport (encode/decode whole batches); the default is identity because Roblox's engine already compresses remote traffic — custom packing is a codec plugin, not core. Streaming large payloads is a documented non-goal of v0.1: chunk at the application level over events, or contribute a streaming codec. There is no visual in-game inspector UI in core; every inspector data source (timeline entries, graph spec, net stats) is exposed as plain data precisely so tooling can be built on top without framework changes.
