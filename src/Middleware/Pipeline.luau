--!strict

export type Middleware<Ctx> = (ctx: Ctx, next: () -> ()) -> ()

local Pipeline = {}

-- combines all steps so they run in order and call terminal at the end
function Pipeline.compile<Ctx>(steps: { Middleware<Ctx> }, terminal: (Ctx) -> ()): (Ctx) -> ()
	if #steps == 0 then
		return terminal
	end
	local stepCount = #steps
	return function(ctx: Ctx)
		local index = 0
		local advance: () -> ()
		advance = function()
			index += 1
			if index <= stepCount then
				steps[index](ctx, advance)
			else
				terminal(ctx)
			end
		end
		advance()
	end
end

return Pipeline