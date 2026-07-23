--!strict

local Error = require(script.Parent.Parent.Error)

export type PluginApi = {
	appName: string,
	registerService: (registration: any) -> (),
	provideValue: (token: any, value: any) -> (),
	alias: (aliasToken: any, target: any) -> (),
	contribute: (key: string, value: any) -> (),
	addCommand: (name: string, fn: (...any) -> ...any) -> (),
	onLifecycle: (fn: (phase: string) -> ()) -> (),
}

export type Plugin = {
	name: string,
	version: string?,
	install: (api: PluginApi) -> (),
}

local PluginHost = {}

-- runs the plugin's install function with a sandboxed api object.
-- Duplicate detection is the caller's responsibility (see App:use): dedup
-- must be scoped to a single app, not global, or two apps sharing a name
-- (common in tests) would wrongly reject the same plugin.
function PluginHost.install(plugin: Plugin, api: PluginApi)
	if type(plugin) ~= "table" or type(plugin.name) ~= "string" or type(plugin.install) ~= "function" then
		Error.throw("E_BAD_PLUGIN", "a plugin must be a table with a string `name` and an `install(api)` function", {
			fixes = { "return { name = ..., version = ..., install = function(api) ... end }" },
		})
	end
	local ok, err = pcall(plugin.install, api)
	if not ok then
		Error.throw("E_PLUGIN_INSTALL_FAILED", string.format(
			'plugin "%s"%s failed to install: %s',
			plugin.name,
			if plugin.version ~= nil then " v" .. plugin.version else "",
			tostring(err)
		))
	end
end

return PluginHost