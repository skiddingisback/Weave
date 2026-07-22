--!strict

local Log = {}

export type Level = "debug" | "info" | "warn" | "error"

export type Sink = (level: Level, message: string) -> ()

export type Logger = {
	debug: (self: Logger, message: string) -> (),
	info: (self: Logger, message: string) -> (),
	warn: (self: Logger, message: string) -> (),
	error: (self: Logger, message: string) -> (),
	child: (self: Logger, scope: string) -> Logger,
}

local LEVEL_ORDER: { [Level]: number } = {
	debug = 1,
	info = 2,
	warn = 3,
	error = 4,
}

local currentLevel: Level = "info"

local defaultSink: Sink = function(level: Level, message: string)
	if level == "warn" or level == "error" then
		warn(message)
	else
		print(message)
	end
end

local currentSink: Sink = defaultSink

function Log.setLevel(level: Level)
	currentLevel = level
end

function Log.setSink(sink: Sink?)
	currentSink = sink or defaultSink
end

local function emit(scope: string, level: Level, message: string)
	if LEVEL_ORDER[level] < LEVEL_ORDER[currentLevel] then
		return
	end
	currentSink(level, string.format("[Weave]%s %s", scope, message))
end

local function makeLogger(scope: string): Logger
	local self = {} :: Logger
	function self.debug(_, message: string)
		emit(scope, "debug", message)
	end
	function self.info(_, message: string)
		emit(scope, "info", message)
	end
	function self.warn(_, message: string)
		emit(scope, "warn", message)
	end
	function self.error(_, message: string)
		emit(scope, "error", message)
	end
	function self.child(_, childScope: string): Logger
		return makeLogger(scope .. "[" .. childScope .. "]")
	end
	return self
end

Log.root = makeLogger("")

function Log.child(scope: string): Logger
	return Log.root:child(scope)
end

return Log
