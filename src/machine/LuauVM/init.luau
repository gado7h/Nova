local Compiler = require("@self/Compiler")
local Base64 = require("@self/Base64")

local LuauVM = {}

-- "Compilation" stage now stores canonical source payload in base64.
-- This keeps distribution format deterministic and removes dependency on
-- bytecode loader shims.
function LuauVM.compile(source: string): string
	return Base64.Encode(source)
end

local function buildChunk(source: string, env: { [string]: any }?)
	env = env or getfenv(1)
	local fn, err = loadstring(source)
	if not fn then
		error(err)
	end
	setfenv(fn, env)
	return fn
end

local load = function(_, source: string, isPureBytecode: boolean?, env: { [string]: any }?): () -> ()
	if isPureBytecode then
		local decoded = Base64.Decode(source)
		return buildChunk(decoded, env)
	end

	-- Keep compiler module in dependency path for tooling parity.
	-- If compilation fails, this raises an error before execution.
	Compiler.luau_compile(source)
	return buildChunk(source, env)
end

local ReturnTable = setmetatable({}, {
	__index = function(_, index)
		return LuauVM[index]
	end,
	__call = load,
})

return ReturnTable
