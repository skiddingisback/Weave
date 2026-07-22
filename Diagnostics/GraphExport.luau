--!strict

export type GraphEdge = {
	from: string,
	to: string,
	optional: boolean,
}

export type GraphSpec = {
	nodes: { { name: string, lazy: boolean, disabled: boolean } },
	edges: { GraphEdge },
}

local GraphExport = {}

local function sanitizeId(name: string): string
	return (string.gsub(name, "[^%w_]", "_"))
end

-- turns the dependency tree into mermaid chart text for docs or prs
function GraphExport.toMermaid(spec: GraphSpec): string
	local lines = { "graph TD" }
	for _, node in spec.nodes do
		local id = sanitizeId(node.name)
		local label = node.name
		if node.lazy then
			label ..= " (lazy)"
		end
		if node.disabled then
			label ..= " (disabled)"
		end
		table.insert(lines, string.format('    %s["%s"]', id, label))
	end
	for _, edge in spec.edges do
		local arrow = if edge.optional then "-.->" else "-->"
		table.insert(lines, string.format("    %s %s %s", sanitizeId(edge.from), arrow, sanitizeId(edge.to)))
	end
	return table.concat(lines, "\n")
end

-- exports as graphviz dot format
function GraphExport.toDot(spec: GraphSpec): string
	local lines = { "digraph Weave {", "    rankdir=TB;" }
	for _, node in spec.nodes do
		local attrs = {}
		if node.lazy then
			table.insert(attrs, "style=dotted")
		end
		if node.disabled then
			table.insert(attrs, "color=gray")
		end
		table.insert(lines, string.format(
			'    "%s"%s;',
			node.name,
			if #attrs > 0 then " [" .. table.concat(attrs, ",") .. "]" else ""
		))
	end
	for _, edge in spec.edges do
		table.insert(lines, string.format(
			'    "%s" -> "%s"%s;',
			edge.from,
			edge.to,
			if edge.optional then " [style=dashed]" else ""
		))
	end
	table.insert(lines, "}")
	return table.concat(lines, "\n")
end

return GraphExport