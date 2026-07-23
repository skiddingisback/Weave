--!strict

export type TimelineEntry = {
	phase: string,
	name: string,
	startedAt: number,
	durationMs: number,
	allocKb: number,
	status: "ok" | "error" | "slow" | "skipped",
	note: string?,
}

export type Timeline = {
	record: (
		self: Timeline,
		phase: string,
		name: string,
		fn: () -> ()
	) -> (boolean, string?),
	mark: (self: Timeline, phase: string, name: string, status: "ok" | "skipped", note: string?) -> (),
	entries: (self: Timeline) -> { TimelineEntry },
	totalMs: (self: Timeline) -> number,
	render: (self: Timeline) -> string,
	setSlowThresholdMs: (self: Timeline, ms: number) -> (),
}

local TimelineClass = {}
TimelineClass.__index = TimelineClass

-- checks memory use
local gcKb: () -> number = function()
	local g = (gcinfo :: any)
	if g ~= nil then
		return g()
	end
	return 0
end

function TimelineClass.new(): Timeline
	local self = setmetatable({
		_origin = os.clock(),
		_entries = {} :: { TimelineEntry },
		_slowMs = 100,
	}, TimelineClass)
	return (self :: any) :: Timeline
end

function TimelineClass:setSlowThresholdMs(ms: number)
	self._slowMs = ms
end

-- runs a function and tracks time plus ram used
function TimelineClass:record(phase: string, name: string, fn: () -> ()): (boolean, string?)
	local startClock = os.clock()
	local startKb = gcKb()
	local ok, err = pcall(fn)
	local durationMs = (os.clock() - startClock) * 1000
	local status: "ok" | "error" | "slow" | "skipped"
	if not ok then
		status = "error"
	elseif durationMs >= self._slowMs then
		status = "slow"
	else
		status = "ok"
	end
	table.insert(self._entries, {
		phase = phase,
		name = name,
		startedAt = startClock - self._origin,
		durationMs = durationMs,
		allocKb = math.max(0, gcKb() - startKb),
		status = status,
		note = if ok then nil else tostring(err),
	})
	return ok, if ok then nil else tostring(err)
end

-- adds a quick event without timing a function
function TimelineClass:mark(phase: string, name: string, status: "ok" | "skipped", note: string?)
	table.insert(self._entries, {
		phase = phase,
		name = name,
		startedAt = os.clock() - self._origin,
		durationMs = 0,
		allocKb = 0,
		status = status,
		note = note,
	})
end

function TimelineClass:entries(): { TimelineEntry }
	return table.clone(self._entries)
end

function TimelineClass:totalMs(): number
	local total = 0
	for _, entry in self._entries do
		total += entry.durationMs
	end
	return total
end

-- prints the results as a clean list
function TimelineClass:render(): string
	local lines = { "Startup timeline:" }
	table.insert(lines, string.format("    %-10s %-32s %10s %10s  %s", "PHASE", "SERVICE", "TIME", "ALLOC", "STATUS"))
	for _, entry in self._entries do
		table.insert(lines, string.format(
			"    %-10s %-32s %8.2fms %8.0fkb  %s%s",
			entry.phase,
			entry.name,
			entry.durationMs,
			entry.allocKb,
			entry.status,
			if entry.note ~= nil then " (" .. entry.note .. ")" else ""
		))
	end
	table.insert(lines, string.format("    total: %.2fms", self:totalMs()))
	return table.concat(lines, "\n")
end

local Timeline = {}

function Timeline.new(): Timeline
	return TimelineClass.new()
end

return Timeline