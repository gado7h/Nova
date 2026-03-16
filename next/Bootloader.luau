--!optimize 2
--!native
--[[
    Bootloader (2-Stage)
    ====================
    Stage 1: Minimal 512-byte MBR equivalent — reads boot.cfg, 
             loads Stage 2 into RAM.
    Stage 2: Reads /boot/kernel.bin from VCFS, decompresses it,
             sets up memory map, initializes paging, hands off to kernel.

    In our hybrid model:
        • Stage 1/2 assembly stubs exist in RAM for authenticity
        • The native Luau layer actually performs the HDD reads + kernel setup
        • CPU jumps to kernel entry point in RAM
        • Kernel then takes over the syscall table
]]

local ISA = require(script.Parent["ISA"])
local MMAP = ISA.MMAP
local OP = ISA.OP
local REG = ISA.REG

local Bootloader = {}

-- Memory map for boot process
local MBR_ADDR = MMAP.RAM_BASE + 0x0000 -- Stage 1 at RAM start
local STAGE2_ADDR = MMAP.RAM_BASE + 0x0200 -- Stage 2 at RAM+512
local KERNEL_ADDR = MMAP.RAM_BASE + 0x4000 -- Kernel at RAM+16KB
local INITRD_ADDR = MMAP.RAM_BASE + 0x400000 -- initrd at RAM+4MB
local KSTACK_ADDR = MMAP.RAM_BASE + 0x3F00 -- kernel stack below kernel

-- ============================================================
-- STAGE 1 (MBR stub, 512 bytes)
-- ============================================================
local function buildStage1(mb)
	local rom = {}
	local function emit(i)
		rom[#rom + 1] = i
	end

	-- Stage 1: Signal "load stage2", then jump to stage2
	emit(ISA.encI(OP.MOVI, REG.SP, 0, 0)) -- SP = stack during boot
	emit(ISA.encU(OP.LUI, REG.SP, bit32.rshift(KSTACK_ADDR, 12)))

	-- Print "Stage 1 OK" via UART
	emit(ISA.encU(OP.LUI, REG.A0, bit32.rshift(MMAP.UART_BASE, 12)))
	emit(ISA.encI(OP.MOVI, REG.A7, 0, ISA.SYS.WRITE))
	emit(ISA.encI(OP.SYSCALL, 0, 0, 0))

	-- Jump to stage 2
	emit(ISA.encU(OP.LUI, REG.A0, bit32.rshift(STAGE2_ADDR, 12)))
	emit(ISA.encI(OP.CALLR, 0, REG.A0, 0))

	-- Pad to 128 instructions (512 bytes)
	while #rom < 128 do
		emit(0)
	end

	return rom
end

-- ============================================================
-- STAGE 2 (reads kernel, sets up page tables)
-- ============================================================
local function buildStage2(mb)
	local rom = {}
	local function emit(i)
		rom[#rom + 1] = i
	end

	-- Signal kernel load
	emit(ISA.encI(OP.MOVI, REG.A7, 0, ISA.SYS.EXEC))
	emit(ISA.encI(OP.MOVI, REG.A0, 0, 1)) -- subcommand = "load kernel"
	emit(ISA.encI(OP.SYSCALL, 0, 0, 0))

	-- A0 now contains kernel entry point address
	-- Set up arguments: A0=memmap_addr, A1=initrd_addr, A2=cmdline_addr
	emit(ISA.encU(OP.LUI, REG.A1, bit32.rshift(INITRD_ADDR, 12)))
	emit(ISA.encI(OP.MOVI, REG.A7, 0, 0)) -- clear A7

	-- Jump to kernel
	emit(ISA.encI(OP.LDW, REG.A2, REG.A0, 0)) -- A2 = kernel entry
	emit(ISA.encI(OP.CALLR, 0, REG.A2, 0))

	-- If kernel returns, hang
	emit(ISA.encI(OP.HALT, 0, 0, 0))

	return rom
end

-- ============================================================
-- BOOT.CFG PARSER
-- ============================================================
local function parseBootCfg(text)
	local config = { entries = {}, default = nil, timeout = 3 }
	local current = nil

	for line in text:gmatch("[^\n]+") do
		line = line:match("^%s*(.-)%s*$") -- trim
		if line:sub(1, 1) ~= "#" and #line > 0 then
			local key, val = line:match("^(%w+)=(.+)$")
			if key and val then
				val = val:match("^%s*(.-)%s*$")
				if key == "DEFAULT" then
					config.default = val
				elseif key == "TIMEOUT" then
					config.timeout = tonumber(val) or 3
				elseif current then
					current[key:lower()] = val
				end
			elseif line:match("^%[(.+)%]$") then
				local name = line:match("^%[(.+)%]$")
				current = { name = name, cmdline = "" }
				config.entries[name] = current
				table.insert(config.entries, current)
			end
		end
	end
	return config
end

-- ============================================================
-- Bootloader.install() — called by BIOS
-- ============================================================
function Bootloader.install(mb)
	local mem = mb.memory
	local hdd = mb.hdd
	local cpu = mb.boot_cpu

	mb:log("[Boot] Stage 1 loading...")

	-- Write stage 1 stub into RAM
	local s1 = buildStage1(mb)
	mem:writeRAMInstructions(MBR_ADDR, s1)

	mb:log("[Boot] Stage 2 loading...")

	-- Write stage 2 stub into RAM
	local s2 = buildStage2(mb)
	mem:writeRAMInstructions(STAGE2_ADDR, s2)

	-- Read boot.cfg from HDD
	local cfgIno, err = hdd:resolvePath("/etc/boot.cfg")
	local bootConfig

	if cfgIno then
		local cfgText = hdd:readFile(cfgIno, 0, 65536)
		bootConfig = parseBootCfg(cfgText)
		mb:log("[Boot] boot.cfg loaded, default=" .. (bootConfig.default or "none"))
	else
		mb:log("[Boot] /etc/boot.cfg not found, using defaults")
		bootConfig = { entries = {}, default = "virtualos", timeout = 1 }
	end

	-- Hook EXEC syscall for stage2 kernel load
	local _old = cpu.onSyscall
	cpu.onSyscall = function(c, num)
		if num == ISA.SYS.EXEC then
			local subcmd = c:readReg(REG.A0)
			if subcmd == 1 then
				-- Load kernel
				local entry = Bootloader.loadKernel(mb, bootConfig)
				c:writeReg(REG.A0, entry)
				return
			end
		end
		if _old then
			_old(c, num)
		end
	end

	-- Skip the slow assembly path: directly install kernel and run
	local kernelEntry = Bootloader.loadKernel(mb, bootConfig)
	cpu:setPC(kernelEntry)

	mb:log(string.format("[Boot] Kernel at 0x%08X, jumping...", kernelEntry))
end

-- ============================================================
-- KERNEL LOAD
-- ============================================================
function Bootloader.loadKernel(mb, bootConfig)
	local mem = mb.memory
	local hdd = mb.hdd

	mb:log("[Boot] Loading kernel...")

	-- Find kernel path from config
	local kernelPath = "/boot/kernel.bin"
	if bootConfig and bootConfig.default then
		local entry = bootConfig.entries[bootConfig.default]
		if entry and entry.kernel then
			kernelPath = entry.kernel
		end
	end

	-- Try to read kernel from HDD
	local kernelIno = hdd:resolvePath(kernelPath)
	if kernelIno then
		local kernelData = hdd:readFile(kernelIno, 0, 2 * 1024 * 1024) -- 2MB max
		if #kernelData > 0 then
			mem:loadRAM(KERNEL_ADDR, kernelData)
			mb:log(string.format("[Boot] Kernel loaded: %d bytes", #kernelData))
		end
	end

	-- Install native Luau kernel (the real implementation)
	-- This overlays the assembly kernel with our full Luau kernel
	local Kernel = require(script.Parent.Kernel)
	local kernel = Kernel.new(mb)
	kernel:install() -- takes over syscall table, starts init

	mb:log("[Boot] Kernel installed")
	return KERNEL_ADDR
end

return Bootloader
