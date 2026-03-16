--!optimize 2
--!native
--[[
    Motherboard - System Bus Controller
    =====================================
    Connects CPU cores, Memory, GPU, HDD, Keyboard, Timer, RNG.
    Handles:
        • Component instantiation and wiring
        • Programmable Interrupt Controller (PIC/INTC)
        • Programmable Interval Timer (PIT)
        • Keyboard MMIO controller
        • RNG MMIO
        • UART debug console
        • Power-on reset sequence
        • Per-frame tick dispatch (Roblox RunService.Heartbeat)
]]

local ISA = require(script.Parent["ISA"])
local CPU = require(script.Parent["CPU"])
local Memory = require(script.Parent["Memory"])
local GPU = require(script.Parent["GPU"])
local HDD = require(script.Parent["HDD"])

local MMAP = ISA.MMAP
local IRQ = ISA.IRQ

-- ============================================================
-- INTERRUPT CONTROLLER
-- ============================================================
local PIC = {}
PIC.__index = PIC

function PIC.new(memory)
	local self = setmetatable({}, PIC)
	self.mask = 0xFFFFFFFF -- all masked by default
	self.pending = 0
	self.inService = 0
	self.cpus = {} -- registered CPU cores

	memory:registerMMIO(MMAP.INTC_BASE, MMAP.INTC_SIZE, function(a)
		return self:read(a)
	end, function(a, v)
		return self:write(a, v)
	end, "PIC")
	return self
end

function PIC:registerCPU(core)
	table.insert(self.cpus, core)
end

function PIC:assertIRQ(irqLine)
	if bit32.band(self.mask, bit32.lshift(1, irqLine)) ~= 0 then
		return
	end
	self.pending = bit32.bor(self.pending, bit32.lshift(1, irqLine))
	for _, core in ipairs(self.cpus) do
		core:assertIRQ(irqLine)
	end
end

function PIC:eoi(irqLine)
	self.inService = bit32.band(self.inService, bit32.bnot(bit32.lshift(1, irqLine)))
end

function PIC:read(addr)
	local off = addr - MMAP.INTC_BASE
	if off == 0x00 then
		return self.mask
	elseif off == 0x04 then
		return self.pending
	elseif off == 0x08 then
		return self.inService
	end
	return 0
end

function PIC:write(addr, val)
	local off = addr - MMAP.INTC_BASE
	if off == 0x00 then
		self.mask = val
	elseif off == 0x0C then
		self:eoi(bit32.band(val, 31))
	end
end

-- ============================================================
-- TIMER (PIT)
-- ============================================================
local Timer = {}
Timer.__index = Timer

function Timer.new(memory, pic)
	local self = setmetatable({}, Timer)
	self.pic = pic
	self.divider = 1000 -- ticks between IRQ
	self.counter = 0
	self.enabled = true
	self.accumMs = 0
	self.tickRateHz = 60
	-- MMIO
	memory:registerMMIO(MMAP.TIMER_BASE, MMAP.TIMER_SIZE, function(a)
		return self:read(a)
	end, function(a, v)
		return self:write(a, v)
	end, "PIT")
	return self
end

function Timer:tick(dt)
	if not self.enabled then
		return
	end
	self.accumMs += dt * 1000
	local interval = 1000 / self.tickRateHz
	while self.accumMs >= interval do
		self.accumMs -= interval
		self.counter += 1
		self.pic:assertIRQ(IRQ.TIMER)
	end
end

function Timer:read(addr)
	local off = addr - MMAP.TIMER_BASE
	if off == 0x00 then
		return self.counter
	elseif off == 0x04 then
		return self.divider
	elseif off == 0x08 then
		return self.enabled and 1 or 0
	elseif off == 0x0C then
		return self.tickRateHz
	end
	return 0
end

function Timer:write(addr, val)
	local off = addr - MMAP.TIMER_BASE
	if off == 0x04 then
		self.divider = math.max(1, val)
	elseif off == 0x08 then
		self.enabled = (val ~= 0)
	elseif off == 0x0C then
		self.tickRateHz = math.clamp(val, 1, 1000)
	end
end

-- ============================================================
-- KEYBOARD CONTROLLER
-- ============================================================
local Keyboard = {}
Keyboard.__index = Keyboard

-- Scancode set 2 (simplified) mappings
local KEY_MAP = ISA.KEY_MAP

-- ASCII → scancode for common printable chars
local ASCII_SCAN = {}
for k, v in pairs(KEY_MAP) do
	ASCII_SCAN[k] = v
end

function Keyboard.new(memory, pic)
	local self = setmetatable({}, Keyboard)
	self.pic = pic
	self.buf = {} -- queue of scancodes
	self.shift = false
	self.ctrl = false
	self.alt = false
	self.capslock = false
	-- MMIO
	memory:registerMMIO(MMAP.KBD_BASE, MMAP.KBD_SIZE, function(a)
		return self:read(a)
	end, function(a, v)
		return self:write(a, v)
	end, "Keyboard")
	return self
end

function Keyboard:pushScancode(code)
	table.insert(self.buf, code)
	if #self.buf > 256 then
		table.remove(self.buf, 1)
	end
	self.pic:assertIRQ(IRQ.KEYBOARD)
end

-- Map Roblox KeyCode enum to our scancode + push to buffer
function Keyboard:onKeyDown(keyCode)
	local name = keyCode.Name
	local sc = KEY_MAP[name]
	if sc then
		self:pushScancode(sc) -- make code
		if name == "LeftShift" or name == "RightShift" then
			self.shift = true
		end
		if name == "LeftControl" then
			self.ctrl = true
		end
		if name == "LeftAlt" then
			self.alt = true
		end
	end
end

function Keyboard:onKeyUp(keyCode)
	local name = keyCode.Name
	local sc = KEY_MAP[name]
	if sc then
		self:pushScancode(0xF0) -- break prefix
		self:pushScancode(sc)
		if name == "LeftShift" or name == "RightShift" then
			self.shift = false
		end
		if name == "LeftControl" then
			self.ctrl = false
		end
		if name == "LeftAlt" then
			self.alt = false
		end
	end
end

-- Convert scancode to ASCII char (basic)
local SCAN_ASCII_LO = {
	[0x15] = "q",
	[0x1D] = "w",
	[0x24] = "e",
	[0x2D] = "r",
	[0x2C] = "t",
	[0x35] = "y",
	[0x3C] = "u",
	[0x43] = "i",
	[0x44] = "o",
	[0x4D] = "p",
	[0x1C] = "a",
	[0x1B] = "s",
	[0x23] = "d",
	[0x2B] = "f",
	[0x34] = "g",
	[0x33] = "h",
	[0x3B] = "j",
	[0x42] = "k",
	[0x4B] = "l",
	[0x1A] = "z",
	[0x22] = "x",
	[0x21] = "c",
	[0x2A] = "v",
	[0x32] = "b",
	[0x31] = "n",
	[0x3A] = "m",
	[0x16] = "1",
	[0x1E] = "2",
	[0x26] = "3",
	[0x25] = "4",
	[0x2E] = "5",
	[0x36] = "6",
	[0x3D] = "7",
	[0x3E] = "8",
	[0x46] = "9",
	[0x45] = "0",
	[0x29] = " ",
	[0x5A] = "\n",
	[0x66] = "\8",
	[0x0D] = "\t",
	[0x49] = ".",
	[0x41] = ",",
	[0x4E] = "-",
	[0x55] = "=",
	[0x4A] = "/",
	[0x4C] = ";",
	[0x52] = "'",
}
local SCAN_ASCII_HI = {
	[0x15] = "Q",
	[0x1D] = "W",
	[0x24] = "E",
	[0x2D] = "R",
	[0x2C] = "T",
	[0x35] = "Y",
	[0x3C] = "U",
	[0x43] = "I",
	[0x44] = "O",
	[0x4D] = "P",
	[0x1C] = "A",
	[0x1B] = "S",
	[0x23] = "D",
	[0x2B] = "F",
	[0x34] = "G",
	[0x33] = "H",
	[0x3B] = "J",
	[0x42] = "K",
	[0x4B] = "L",
	[0x1A] = "Z",
	[0x22] = "X",
	[0x21] = "C",
	[0x2A] = "V",
	[0x32] = "B",
	[0x31] = "N",
	[0x3A] = "M",
	[0x16] = "!",
	[0x1E] = "@",
	[0x26] = "#",
	[0x25] = "$",
	[0x2E] = "%",
	[0x36] = "^",
	[0x3D] = "&",
	[0x3E] = "*",
	[0x46] = "(",
	[0x45] = ")",
	[0x29] = " ",
	[0x5A] = "\n",
	[0x49] = ">",
	[0x41] = "<",
	[0x4E] = "_",
	[0x55] = "+",
	[0x4A] = "?",
	[0x4C] = ":",
	[0x52] = '"',
}

function Keyboard:scanToAscii(sc)
	if self.shift or self.capslock then
		return SCAN_ASCII_HI[sc]
	end
	return SCAN_ASCII_LO[sc]
end

function Keyboard:read(addr)
	local off = addr - MMAP.KBD_BASE
	if off == 0x00 then
		-- Status: bit0=data ready, bit1=shift, bit2=ctrl, bit3=alt
		return bit32.bor(
			(#self.buf > 0 and 1 or 0),
			(self.shift and 2 or 0),
			(self.ctrl and 4 or 0),
			(self.alt and 8 or 0)
		)
	elseif off == 0x04 then
		-- Read next scancode from buffer
		return table.remove(self.buf, 1) or 0
	elseif off == 0x08 then
		-- Peek next char as ASCII (keyboard.h style)
		if #self.buf > 0 then
			local sc = self.buf[1]
			local ch = self:scanToAscii(sc)
			return ch and ch:byte(1) or 0
		end
		return 0
	end
	return 0
end

function Keyboard:write(addr, val)
	local off = addr - MMAP.KBD_BASE
	if off == 0x0C then
		-- LED control (capslock etc)
		self.capslock = bit32.band(val, 4) ~= 0
	end
end

-- ============================================================
-- RNG CONTROLLER
-- ============================================================
local function newRNG(memory)
	local seed = os.clock()
	memory:registerMMIO(MMAP.RNG_BASE, MMAP.RNG_SIZE, function()
		-- xorshift32
		seed = bit32.bxor(seed, bit32.lshift(seed, 13))
		seed = bit32.bxor(seed, bit32.rshift(seed, 17))
		seed = bit32.bxor(seed, bit32.lshift(seed, 5))
		if seed == 0 then
			seed = 0xDEAD1234
		end
		return seed
	end, function(_, v)
		seed = v
	end, "RNG")
end

-- ============================================================
-- UART DEBUG CONSOLE
-- ============================================================
local UART = {}
UART.__index = UART

function UART.new(memory)
	local self = setmetatable({}, UART)
	self.outBuf = {}
	self.inBuf = {}
	self.onOutput = nil -- function(line)
	memory:registerMMIO(MMAP.UART_BASE, MMAP.UART_SIZE, function(a)
		return self:read(a)
	end, function(a, v)
		return self:write(a, v)
	end, "UART")
	return self
end

function UART:read(addr)
	local off = addr - MMAP.UART_BASE
	if off == 0x00 then
		return (#self.inBuf > 0 and 1 or 0) + 2 -- TX always ready (bit1)
	elseif off == 0x04 then
		return table.remove(self.inBuf, 1) or 0
	end
	return 0
end

function UART:write(addr, val)
	local off = addr - MMAP.UART_BASE
	if off == 0x04 then
		local ch = string.char(bit32.band(val, 0xFF))
		table.insert(self.outBuf, ch)
		if ch == "\n" or #self.outBuf > 128 then
			local line = table.concat(self.outBuf)
			self.outBuf = {}
			if self.onOutput then
				self.onOutput(line)
			end
		end
	end
end

function UART:inject(text)
	for i = 1, #text do
		table.insert(self.inBuf, text:byte(i))
	end
end

-- ============================================================
-- MOTHERBOARD
-- ============================================================
local Motherboard = {}
Motherboard.__index = Motherboard

function Motherboard.new(config)
	local self = setmetatable({}, Motherboard)
	config = config or {}

	-- Config
	self.ramMB = config.ramMB or 128
	self.numCores = config.numCores or 4
	self.imageLabel = config.imageLabel -- Roblox ImageLabel for GPU
	self.dataStore = config.dataStore -- Roblox DataStore
	self.base64 = config.base64
	self.playerId = config.playerId or "0"

	-- ---- Instantiate hardware -----
	self.memory = Memory.new(self.ramMB)
	self.pic = PIC.new(self.memory)
	self.timer = Timer.new(self.memory, self.pic)
	self.keyboard = Keyboard.new(self.memory, self.pic)
	self.uart = UART.new(self.memory)
	newRNG(self.memory)

	self.gpu = GPU.new(self.memory, self.imageLabel)
	self.hdd = HDD.new(self.memory, self.base64, self.dataStore, self.playerId)

	-- ---- CPU Cores -----
	self.cpus = {}
	for i = 0, self.numCores - 1 do
		local core = CPU.new(self.memory, i)
		self.cpus[i] = core
		self.pic:registerCPU(core)

		-- Wire up syscall handler
		core.onSyscall = function(c, num)
			self:handleSyscall(c, num)
		end
		core.onHalt = function(c)
			self:onCoreHalt(c)
		end
		core.onException = function(c, v, a)
			self:handleException(c, v, a)
		end
	end
	self.boot_cpu = self.cpus[0]

	-- ---- IVT (Interrupt Vector Table) in RAM -----
	self.ivtBase = MMAP.IVT_BASE
	-- Will be populated by BIOS

	-- State
	self.powered = false
	self.halted = false
	self.paused = false
	self._ticks = 0
	self._uptime = 0
	self.insPerTick = config.insPerTick or 50000 -- instructions per Heartbeat

	-- HDD DMA → CPU IRQ
	self.hdd.onDMADone = function()
		self.pic:assertIRQ(ISA.IRQ.STORAGE)
	end

	-- GPU VBlank → CPU IRQ
	self.gpu.vblankCallback = function()
		self.pic:assertIRQ(ISA.IRQ.GPU)
	end

	-- Callbacks for host
	self.onPrint = nil -- function(text)
	self.onPanic = nil -- function(msg)

	return self
end

-- ============================================================
-- POWER ON
-- ============================================================
function Motherboard:powerOn()
	if self.powered then
		return
	end
	self.powered = true

	-- Reset all cores
	print("[MB] Resetting cores...")
	for _, core in pairs(self.cpus) do
		core:reset()
	end

	-- Load HDD from DataStore
	self:log("[MB] Loading HDD from DataStore...")
	local loaded = self.hdd:loadFromDataStore()
	if not loaded then
		self:log("[MB] Fresh disk detected - formatted VCFS")
	else
		self:log("[MB] HDD loaded successfully")
	end

	-- Load BIOS firmware into ROM and execute it
	print("[MB] Installing BIOS...")
	local BIOS = require(script.Parent.BIOS)
	BIOS.install(self)
	print("[MB] BIOS installed.")

	self:log("[MB] Power-on complete. CPU0 at PC=0x" .. string.format("%08X", self.boot_cpu.pc))
end

-- ============================================================
-- TICK (called from RunService.Heartbeat)
-- ============================================================
function Motherboard:tick(dt)
	if not self.powered or self.halted or self.paused then
		return
	end
	self._uptime += dt
	self._ticks += 1

	-- Timer tick
	self.timer:tick(dt)

	-- HDD autosave
	self.hdd:tick(dt)

	-- GPU command processing
	self.gpu:processCommands()

	-- Run CPU instructions (distribute across cores)
	local insPerCore = math.floor(self.insPerTick / self.numCores)
	for _, core in pairs(self.cpus) do
		if not core.halted then
			core:run(insPerCore)
		end
	end

	-- Flush GPU to EditableImage at ~60fps
	if self._ticks % 1 == 0 and self.gpu.dirty then
		self.gpu:flip()
	end

	-- Tick Kernel scheduler
	if self.kernel then
		self.kernel:tick(dt)
	end
end

-- ============================================================
-- IVT MANAGEMENT
-- ============================================================
function Motherboard:setIVT(vector, handler_addr)
	-- Each IVT entry is IVT_ENTRY_SZ bytes; word 0 is handler address
	local entry = MMAP.IVT_BASE + vector * MMAP.IVT_ENTRY_SZ
	self.memory:writeWord(entry, handler_addr)
end

-- ============================================================
-- EXCEPTION HANDLER
-- ============================================================
function Motherboard:handleException(cpu, vector, faultAddr)
	local names = {
		[ISA.EX.DIV_ZERO] = "Division by Zero",
		[ISA.EX.INVALID_OP] = "Invalid Opcode",
		[ISA.EX.PAGE_FAULT] = "Page Fault",
		[ISA.EX.STACK_FAULT] = "Stack Fault",
		[ISA.EX.GP_FAULT] = "General Protection Fault",
	}
	local name = names[vector] or string.format("Exception 0x%02X", vector)
	self:log(string.format("[CPU%d] %s at PC=0x%08X fault=0x%08X", cpu.id, name, cpu.saved_pc, faultAddr or 0))
end

function Motherboard:onCoreHalt(cpu)
	self:log(string.format("[CPU%d] HALT", cpu.id))
	local allHalted = true
	for _, c in pairs(self.cpus) do
		if not c.halted then
			allHalted = false
			break
		end
	end
	if allHalted then
		self.halted = true
		self:log("[MB] All cores halted.")
	end
end

-- ============================================================
-- SYSCALL DISPATCH (called from CPU on SYSCALL instruction)
-- ============================================================
-- This is defined here at motherboard level; the full implementation
-- is in Kernel which will override this after boot.
function Motherboard:handleSyscall(cpu, num)
	-- Minimal pre-kernel syscalls (used during boot)
	local SYS = ISA.SYS
	if num == SYS.WRITE then
		local fd = cpu:readReg(ISA.REG.A0)
		local buf = cpu:readReg(ISA.REG.A1)
		local len = cpu:readReg(ISA.REG.A2)
		if fd == 1 or fd == 2 then -- stdout/stderr
			local str = self.memory:readCString(buf, len)
			if self.onPrint then
				self.onPrint(str)
			end
			self.uart:write(MMAP.UART_BASE + 4, 0) -- signal
		end
		cpu:writeReg(ISA.REG.A0, len)
	elseif num == SYS.EXIT then
		cpu.halted = true
	else
		-- Will be overridden by Kernel
		cpu:writeReg(ISA.REG.A0, 0xFFFFFFFF) -- ENOSYS
	end
end

-- ============================================================
-- UTILITIES
-- ============================================================
function Motherboard:log(msg)
	if self.onPrint then
		self.onPrint(msg)
	end
	-- Use UART:write to handle buffering and flushing correctly
	if self.uart then
		-- Use a small loop to write char by char if needed, 
		-- but UART:write expects a word? No, UART:write takes (addr, val).
		-- Let's just manually append to outBuf but with a limit check like UART:write
		for i = 1, #msg do
			local ch = msg:sub(i, i)
			table.insert(self.uart.outBuf, ch)
			if ch == "\n" or #self.uart.outBuf > 1024 then
				local line = table.concat(self.uart.outBuf)
				self.uart.outBuf = {}
				if self.uart.onOutput then
					self.uart.onOutput(line)
				end
			end
		end
		-- Ensure newline for logs and flush
		if #self.uart.outBuf > 0 then
			local line = table.concat(self.uart.outBuf)
			self.uart.outBuf = {}
			if self.uart.onOutput then
				self.uart.onOutput(line)
			end
		end
	end
end

function Motherboard:getUptime()
	return self._uptime
end

function Motherboard:dumpState()
	return self.boot_cpu:dumpRegisters() .. "\n" .. self.boot_cpu:dumpPerf()
end

-- Expose constants for firmware/kernel use
Motherboard.ISA = ISA
Motherboard.MMAP = MMAP

return Motherboard
