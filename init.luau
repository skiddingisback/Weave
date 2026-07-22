--!strict
--[[
	Quickstart:

		-- ShopService/definition.luau  (the typed contract)
		local Weave = require(ReplicatedStorage.Weave)
		export type API = { getBalance: (self: API, player: Player) -> number }
		return { Token = Weave.token("ShopService") :: Weave.Token<API> }

		-- ShopService/init.luau  (the implementation)
		local Def = require(script.definition)
		local DataDef = require(Services.DataService.definition)
		return Weave.service({
			token = Def.Token,
			dependencies = { DataDef.Token },
			create = function(ctx): Def.API
				local data = ctx:use(DataDef.Token) -- fully typed
				local self = {} :: Def.API
				function self.getBalance(_, player)
					return data:read(player, "balance")
				end
				ctx:onStart(function() ctx.log:info("shop open") end)
				return self
			end,
		})

		-- Server bootstrap
		local app = Weave.App.new({ name = "Server" })
		app:registerMany(require(ServerScriptService.Registry))
		app:start()
		app:bindToClose()
]]

local TokenModule = require(script.Container.Token)
local ContainerModule = require(script.Container.Container)
local Definition = require(script.Runtime.Definition)
local AppModule = require(script.Runtime.App)
local PipelineModule = require(script.Middleware.Pipeline)
local PluginHostModule = require(script.Plugins.PluginHost)

local SignalModule = require(script.Util.Signal)
local FutureModule = require(script.Util.Future)
local BinModule = require(script.Util.Bin)

local ErrorModule = require(script.Error)
local LogModule = require(script.Log)

local CheckModule = require(script.Net.Check)
local SchemaModule = require(script.Net.Schema)
local TransportModule = require(script.Net.Transport)
local NetServerModule = require(script.Net.NetServer)
local NetClientModule = require(script.Net.NetClient)
local RobloxTransportModule = require(script.Net.RobloxTransport)
local LoopbackTransportModule = require(script.Net.LoopbackTransport)

local TimelineModule = require(script.Diagnostics.Timeline)
local GraphExportModule = require(script.Diagnostics.GraphExport)

local Weave = {}

Weave.version = "0.1.0"

-- ------------------------------------------------------------------- core

-- Typed identity. Cast against your definition module's API type:
--     Weave.token("ShopService") :: Weave.Token<API>
Weave.token = TokenModule.new
export type Token<T> = TokenModule.Token<T>
export type AnyToken = TokenModule.AnyToken

-- Service/controller definition (one abstraction for both sides).
Weave.service = Definition.service
export type ServiceContext = Definition.ServiceContext
export type ConfigureContext = Definition.ConfigureContext
export type ServiceRegistration = Definition.ServiceRegistration

-- Application lifecycle.
Weave.App = AppModule
export type App = AppModule.App
export type StartReport = AppModule.StartReport

-- DI container (Apps embed one; standalone use is supported for tests
-- and non-service composition).
Weave.Container = ContainerModule
export type Container = ContainerModule.Container
export type Resolver = ContainerModule.Resolver

-- ------------------------------------------------------------------- net

Weave.Net = {
	rpc = SchemaModule.rpc,
	event = SchemaModule.event,
	namespace = SchemaModule.namespace,
	fingerprint = SchemaModule.fingerprint,
	Server = NetServerModule,
	Client = NetClientModule,
	RobloxTransport = RobloxTransportModule,
	LoopbackTransport = LoopbackTransportModule,
	IdentityCodec = TransportModule.IdentityCodec,
}
Weave.Check = CheckModule
export type Validator<T> = CheckModule.Validator<T>
export type Rpc<Req, Res> = SchemaModule.Rpc<Req, Res>
export type Event<T> = SchemaModule.Event<T>
export type NetServer = NetServerModule.NetServer
export type NetClient = NetClientModule.NetClient
export type Codec = TransportModule.Codec
export type ServerNetContext = NetServerModule.ServerNetContext

-- ------------------------------------------------------------------- shared

Weave.Pipeline = PipelineModule
export type Middleware<Ctx> = PipelineModule.Middleware<Ctx>

export type Plugin = PluginHostModule.Plugin
export type PluginApi = PluginHostModule.PluginApi

Weave.Signal = SignalModule
export type Signal<T...> = SignalModule.Signal<T...>
export type Connection = SignalModule.Connection

Weave.Future = FutureModule
export type Future<T> = FutureModule.Future<T>

Weave.Bin = BinModule
export type Bin = BinModule.Bin

Weave.Error = ErrorModule
export type WeaveError = ErrorModule.WeaveError

Weave.Log = LogModule
export type Logger = LogModule.Logger

Weave.Timeline = TimelineModule
Weave.GraphExport = GraphExportModule

return Weave
