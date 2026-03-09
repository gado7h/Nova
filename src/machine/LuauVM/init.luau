--!nolint DeprecatedApi
local FiU = require("@self/Fiu")
local Compiler = require("@self/Compiler")
local Base64 = require("@self/Base64")

local LuauVM = {}

function LuauVM.compile(source: string): string
	local clock = os.clock()
	local bytecode, bytecodeSize = Compiler.luau_compile(source)
	return Base64.Encode(bytecode)
end

local load = function(_, source: string, isPureBytecode: boolean?): () -> ()
	local func, closure
	if isPureBytecode then
		local bytecode = Base64.Decode(source)
		func, closure = FiU.luau_load(bytecode, getfenv(1))
	else
		local bytecode, bytecodeSize = Compiler.luau_compile(source)
		func, closure = FiU.luau_load(bytecode, getfenv(1))
	end
	return func, closure
end

local ReturnTable = setmetatable({}, {
	__index = function(table, index)
		return LuauVM[index]
	end,
	__call = load,
})

return ReturnTable :: typeof(setmetatable({}, {
	__index = function(table, index)
		return Compiler[index]
	end,
	__call = load,
})) & {
	compile: typeof(function(
		src: string,
		optLevel: number?,
		dbgLevel: number?,
		typInfLevel: number?,
		covLevel: number?
	)
		return "string", 1
	end),
}
