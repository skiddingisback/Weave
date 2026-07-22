# Migrating from Knit to Weave

Weave keeps Knit's philosophy - structure without ceremony, networking without hand-rolled remotes - and replaces every mechanism. Migration is mechanical per service and can be done incrementally: nothing forces a big-bang rewrite, because a Weave App and a legacy Knit runtime can coexist in the same place during transition (they share no global state - Weave has none).

## Concept mapping

| Knit | Weave | Why it changed |
|---|---|---|
| `Knit.CreateService{Name="X"}` | definition module + `Weave.service{token = ...}` | Typed identity; autocomplete; rename safety; no name collisions |
| `Knit.CreateController` | `Weave.service` registered in the client App | One abstraction; half the API surface |
| `Knit.GetService("X")` (returns `any`) | `ctx:use(XDef.Token)` (returns `X.API`) | Compile-time types; declared graph edges |
| `KnitInit` | body of `create(ctx)` | Runs in deterministic topological order |
| `KnitStart` | `ctx:onStart(fn)` | Fail-fast: errors abort startup instead of being swallowed by `task.spawn` |
| long-running loops in `KnitStart` | `ctx:spawn(fn)` | Managed thread, cancelled at shutdown |
| `Knit.OnStart():await()` | usually delete it; else `app:onReady(fn)` | Ordering is the framework's job now, not await-choreography |
| `service.Client:Method(player, ...)` | `Net.rpc` in a schema + `net:handle` | Validated, rate-limited, typed, versioned |
| `Knit.CreateSignal()` | `Net.event` in a schema | Same, plus batching and optional unreliable channel |
| `Knit.CreateUnreliableSignal()` | `Net.event(v, { unreliable = true })` | - |
| `Knit.CreateProperty(v)` | rpc getter + change event (pattern below) | Explicit and validated; RemoteProperty's full-value sync was a footgun |
| Comm middleware `(player, args) -> (bool, ...)` | `Pipeline` middleware `(ctx, next)` | Typed context, post-processing, real error channel |
| Promises everywhere | plain calls + `Weave.Future` at async edges | Zero deps; honest stack traces; `await(timeout)` |
| `Knit.AddServices(folder)` | explicit registry module | Deterministic, reviewable, lazy-capable |
| - (none) | `ctx:onShutdown` + `app:bindToClose()` | Shutdown is half a lifecycle Knit didn't have |

## Worked example

Knit:

```lua
local MoneyService = Knit.CreateService({ Name = "MoneyService", Client = {} })

function MoneyService:KnitInit()
	self._data = Knit.GetService("DataService") -- any-typed, implicit edge
end

function MoneyService:GetMoney(player) return self._data:Read(player, "money") end

function MoneyService.Client:GetMoney(player)
	return self.Server:GetMoney(player) -- unvalidated, unthrottled, untyped
end
```

Weave - definition:

```lua
export type API = { getMoney: (self: API, player: Player) -> number }
return { Token = Weave.token("MoneyService") :: Weave.Token<API> }
```

Weave - implementation + schema:

```lua
-- Shared schema
local MoneyNet = Net.namespace("Money", {
	getMoney = Net.rpc(Check.shape({}), Check.shape({ amount = Check.number }), { rate = 2 }),
})

-- Implementation
return Weave.service({
	token = Def.Token,
	dependencies = { DataDef.Token },
	create = function(ctx): Def.API
		local data = ctx:use(DataDef.Token)
		local self = {} :: Def.API
		function self.getMoney(_, player) return data:read(player, "money") end
		ctx:onStart(function()
			net:handle(MoneyNet.getMoney, function(player, _req)
				return { amount = self:getMoney(player) }
			end)
		end)
		return self
	end,
})
```

Client side, Knit's `MoneyService:GetMoney():andThen(print)` becomes:

```lua
local ok, res = net:call(MoneyNet.getMoney, {})
if ok then print((res :: any).amount) end
```

## RemoteProperty replacement pattern

```lua
-- schema
balance = Net.event(Check.shape({ value = Check.number })),
getBalance = Net.rpc(Check.shape({}), Check.shape({ value = Check.number })),
-- server: net:fire(Money.balance, player, { value = v }) on change
-- client: seed with net:call(getBalance), subscribe with net:on(balance)
```

More code than `CreateProperty`, but every sync is now typed, validated, batched with all other traffic, and visible in `net:stats()`.

## Incremental migration plan

1. Drop `Weave` into the place alongside Knit. Create the server/client Apps and start them; both frameworks boot independently.
2. Migrate leaf services first (no dependents). Bridge direction matters: Weave services must not call `Knit.GetService` (it reintroduces `any` and hidden edges); instead let remaining Knit services reach *into* Weave via `app:get(Token)` after `app:onReady`.
3. Migrate each service's `Client` table into a schema namespace at the same time you migrate the service - this is where the security payoff lands, so don't defer it.
4. Convert Promise chains: `:andThen(f):catch(g)` around a network call becomes `local ok, res = net:call(...)` with an `if`; genuinely concurrent flows use `Weave.Future`.
5. When the last Knit service is gone, delete `Knit.Start` and the Wally deps.

## Behavior changes to expect (all intentional)

Startup errors now stop the server loudly instead of booting half-alive - fix the error, don't suppress it. Boot order will differ from whatever accidental order Knit gave you; anything that only worked by luck will surface immediately as an `E_MISSING_DEPENDENCY` / cycle error with a printed chain, which is the bug being found, not created. Unvalidated client payloads that "worked" under Knit (extra fields, wrong types) are now rejected with `E_INVALID_ARGUMENT` - check `net:stats()` invalid counts during rollout to catch schema mismatches early.
