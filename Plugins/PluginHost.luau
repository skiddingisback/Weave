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

local installed: { [string]: boolean } = {}

-- runs the plugin's install function with a sandboxed api object
function PluginHost.install(plugin: Plugin, api: PluginApi)
	if type(plugin) ~= "table" or type(plugin.name) ~= "string" or type(plugin.install) ~= "function" then
		Error.throw("E_BAD_PLUGIN", "a plugin must be a table with a string `name` and an `install(api)` function", {
			fixes = { "return { name = ..., version = ..., install = function(api) ... end }" },
		})
	end
	local key = api.appName .. "/" .. plugin.name
	if installed[key] then
		Error.throw("E_DUPLICATE_PLUGIN", string.format('plugin "%s" installed twice into app "%s"', plugin.name, api.appName))
	end
	installed[key] = true
	local ok, err = pcall(plugin.install, api)
	if not ok then
		installed[key] = nil
		Error.throw("E_PLUGIN_INSTALL_FAILED", string.format(
			'plugin "%s"%s failed to install: %s',
			plugin.name,
			if plugin.version ~= nil then " v" .. plugin.version else "",
			tostring(err)
		))
	end
end

return PluginHost