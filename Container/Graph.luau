--!strict
--[[
	weave/container/graph.luau

	sorts graph nodes and finds cycles.
]]

local Graph = {}

export type GraphNode = {
	id: string,
	order: number,
	deps: { string },
}

export type SortResult = {
	ok: boolean,
	sorted: { string }?,
	cycle: { string }?,
	missing: { [string]: { string } }?,
}

function Graph.sort(nodes: { GraphNode }): SortResult
	local byId: { [string]: GraphNode } = {}
	for _, node in nodes do
		byId[node.id] = node
	end

	-- check for missing nodes first
	local missing: { [string]: { string } } = {}
	local anyMissing = false
	for _, node in nodes do
		for _, dep in node.deps do
			if byId[dep] == nil then
				anyMissing = true
				local list = missing[dep]
				if list == nil then
					list = {}
					missing[dep] = list
				end
				table.insert(list, node.id)
			end
		end
	end
	if anyMissing then
		return { ok = false, missing = missing }
	end

	-- count incoming edges
	local indegree: { [string]: number } = {}
	local dependents: { [string]: { string } } = {}
	for _, node in nodes do
		indegree[node.id] = 0
	end
	for _, node in nodes do
		for _, dep in node.deps do
			indegree[node.id] += 1
			local list = dependents[dep]
			if list == nil then
				list = {}
				dependents[dep] = list
			end
			table.insert(list, node.id)
		end
	end

	local ready: { GraphNode } = {}
	for _, node in nodes do
		if indegree[node.id] == 0 then
			table.insert(ready, node)
		end
	end

	local sorted: { string } = {}
	while #ready > 0 do
		local bestIdx = 1
		for i = 2, #ready do
			if ready[i].order < ready[bestIdx].order then
				bestIdx = i
			end
		end
		local node = table.remove(ready, bestIdx) :: GraphNode
		table.insert(sorted, node.id)
		local deps = dependents[node.id]
		if deps ~= nil then
			for _, dependentId in deps do
				indegree[dependentId] -= 1
				if indegree[dependentId] == 0 then
					table.insert(ready, byId[dependentId])
				end
			end
		end
	end

	if #sorted == #nodes then
		return { ok = true, sorted = sorted }
	end

	-- find cycle in what is left
	local remaining: { [string]: boolean } = {}
	for _, node in nodes do
		if indegree[node.id] > 0 then
			remaining[node.id] = true
		end
	end

	local visitedIndex: { [string]: number } = {}
	local path: { string } = {}

	local function dfs(id: string): { string }?
		local seenAt = visitedIndex[id]
		if seenAt ~= nil then
			local cycle: { string } = {}
			for i = seenAt, #path do
				table.insert(cycle, path[i])
			end
			table.insert(cycle, id)
			return cycle
		end
		table.insert(path, id)
		visitedIndex[id] = #path
		for _, dep in byId[id].deps do
			if remaining[dep] then
				local found = dfs(dep)
				if found ~= nil then
					return found
				end
			end
		end
		visitedIndex[id] = nil
		table.remove(path)
		return nil
	end

	for id in remaining do
		local cycle = dfs(id)
		if cycle ~= nil then
			return { ok = false, cycle = cycle }
		end
	end

	return { ok = false, cycle = {} }
end

return Graph