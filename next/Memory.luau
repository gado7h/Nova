--!optimize 2
--!native
--[[
    Memory Subsystem
    ================
    Unified memory controller providing:
        • ROM (read-only, pre-loaded firmware)
        • RAM (read/write, buffer-backed, 128 MB default)
        • MMIO dispatch to device controllers
        • Block read/write for cache line fills
        • Memory protection / access validation
        
    Physical memory map enforced here (see ISA.MMAP).
    MMIO writes/reads are forwarded to registered device handlers.
]]

local ISA = require(script.Parent["ISA"])
local MMAP = ISA.MMAP

-- ============================================================
-- MEMORY OBJECT
-- ============================================================
local Memory = {}
Memory.__index = Memory

function Memory.new(ramSizeMB)
	local self = setmetatable({}, Memory)

	ramSizeMB = ramSizeMB or 128
	local ramBytes = ramSizeMB * 1024 * 1024

	-- Main RAM buffer
	self.ram = buffer.create(ramBytes)
	self.ramSize = ramBytes
	self.ramBase = MMAP.RAM_BASE

	-- ROM buffer (1 MB) — written by BIOS loader at init
	self.rom = buffer.create(MMAP.ROM_SIZE)
	self.romSize = MMAP.ROM_SIZE
	self.romBase = MMAP.ROM_BASE
	self.romLocked = false -- set true after BIOS init

	-- BIOS Data Area (small scratch RAM at ROM_BASE + 1MB)
	self.bda = buffer.create(MMAP.BDA_SIZE)
	self.bdaBase = MMAP.BDA_BASE
	self.bdaSize = MMAP.BDA_SIZE

	-- MMIO handlers: [base_addr] = { read=fn, write=fn, size=n }
	self.mmioHandlers = {}

	-- Statistics
	self.stats = {
		reads = 0,
		writes = 0,
		mmio_reads = 0,
		mmio_writes = 0,
		rom_reads = 0,
		rom_write_attempts = 0,
		out_of_range = 0,
	}

	return self
end

-- ============================================================
-- MMIO REGISTRATION
-- ============================================================
function Memory:registerMMIO(base, size, readFn, writeFn, label)
	self.mmioHandlers[base] = {
		base = base,
		size = size,
		read = readFn,
		write = writeFn,
		label = label or ("MMIO_" .. string.format("%08X", base)),
	}
end

function Memory:findMMIO(addr)
	for base, handler in pairs(self.mmioHandlers) do
		if addr >= base and addr < base + handler.size then
			return handler
		end
	end
	return nil
end

-- ============================================================
-- CORE PRIMITIVES
-- ============================================================
function Memory:readByte(addr)
	self.stats.reads += 1
	-- ROM region
	if addr >= self.romBase and addr < self.romBase + self.romSize then
		self.stats.rom_reads += 1
		return buffer.readu8(self.rom, addr - self.romBase)
	end
	-- BDA region
	if addr >= self.bdaBase and addr < self.bdaBase + self.bdaSize then
		return buffer.readu8(self.bda, addr - self.bdaBase)
	end
	-- RAM region
	if addr >= self.ramBase and addr < self.ramBase + self.ramSize then
		return buffer.readu8(self.ram, addr - self.ramBase)
	end
	-- MMIO
	if addr >= MMAP.MMIO_BASE then
		local handler = self:findMMIO(addr)
		if handler and handler.read then
			self.stats.mmio_reads += 1
			return bit32.band(handler.read(addr), 0xFF)
		end
		return 0xFF
	end
	self.stats.out_of_range += 1
	return 0xFF
end

function Memory:writeByte(addr, val)
	self.stats.writes += 1
	val = bit32.band(val, 0xFF)
	-- ROM (read-only guard)
	if addr >= self.romBase and addr < self.romBase + self.romSize then
		if self.romLocked then
			self.stats.rom_write_attempts += 1
			return -- silently discard
		end
		buffer.writeu8(self.rom, addr - self.romBase, val)
		return
	end
	if addr >= self.bdaBase and addr < self.bdaBase + self.bdaSize then
		buffer.writeu8(self.bda, addr - self.bdaBase, val)
		return
	end
	if addr >= self.ramBase and addr < self.ramBase + self.ramSize then
		buffer.writeu8(self.ram, addr - self.ramBase, val)
		return
	end
	if addr >= MMAP.MMIO_BASE then
		local handler = self:findMMIO(addr)
		if handler and handler.write then
			self.stats.mmio_writes += 1
			handler.write(addr, val)
		end
		return
	end
	self.stats.out_of_range += 1
end

function Memory:readHalf(addr)
	-- Little-endian 16-bit
	local lo = self:readByte(addr)
	local hi = self:readByte(addr + 1)
	return bit32.bor(lo, bit32.lshift(hi, 8))
end

function Memory:writeHalf(addr, val)
	self:writeByte(addr, bit32.band(val, 0xFF))
	self:writeByte(addr + 1, bit32.band(bit32.rshift(val, 8), 0xFF))
end

function Memory:readWord(addr)
	-- Optimised path for aligned RAM reads
	if addr >= self.ramBase and addr < self.ramBase + self.ramSize and bit32.band(addr, 3) == 0 then
		return buffer.readu32(self.ram, addr - self.ramBase)
	end
	if addr >= self.romBase and addr < self.romBase + self.romSize and bit32.band(addr, 3) == 0 then
		return buffer.readu32(self.rom, addr - self.romBase)
	end
	-- MMIO or unaligned
	if addr >= MMAP.MMIO_BASE then
		local handler = self:findMMIO(addr)
		if handler and handler.read then
			self.stats.mmio_reads += 1
			return bit32.band(handler.read(addr), 0xFFFFFFFF)
		end
		return 0xFFFFFFFF
	end
	-- Unaligned fallback
	local b0 = self:readByte(addr)
	local b1 = self:readByte(addr + 1)
	local b2 = self:readByte(addr + 2)
	local b3 = self:readByte(addr + 3)
	return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
end

function Memory:writeWord(addr, val)
	val = bit32.band(val, 0xFFFFFFFF)
	-- Optimised path for aligned RAM writes
	if addr >= self.ramBase and addr < self.ramBase + self.ramSize and bit32.band(addr, 3) == 0 then
		buffer.writeu32(self.ram, addr - self.ramBase, val)
		return
	end
	if addr >= MMAP.MMIO_BASE then
		local handler = self:findMMIO(addr)
		if handler and handler.write then
			self.stats.mmio_writes += 1
			handler.write(addr, val)
			return
		end
		return
	end
	-- Unaligned fallback
	self:writeByte(addr, bit32.band(val, 0xFF))
	self:writeByte(addr + 1, bit32.band(bit32.rshift(val, 8), 0xFF))
	self:writeByte(addr + 2, bit32.band(bit32.rshift(val, 16), 0xFF))
	self:writeByte(addr + 3, bit32.band(bit32.rshift(val, 24), 0xFF))
end

-- ============================================================
-- BLOCK OPERATIONS (for cache line fill/evict)
-- ============================================================
function Memory:readBlock(addr, size)
	local blk = buffer.create(size)
	-- Aligned RAM fast path
	if addr >= self.ramBase and addr + size <= self.ramBase + self.ramSize then
		local offset = addr - self.ramBase
		buffer.copy(blk, 0, self.ram, offset, size)
		return blk
	end
	if addr >= self.romBase and addr + size <= self.romBase + self.romSize then
		local offset = addr - self.romBase
		buffer.copy(blk, 0, self.rom, offset, size)
		return blk
	end
	-- Slow path
	for i = 0, size - 1 do
		buffer.writeu8(blk, i, self:readByte(addr + i))
	end
	return blk
end

function Memory:writeBlock(addr, blk)
	local size = buffer.len(blk)
	if addr >= self.ramBase and addr + size <= self.ramBase + self.ramSize then
		local offset = addr - self.ramBase
		buffer.copy(self.ram, offset, blk, 0, size)
		return
	end
	for i = 0, size - 1 do
		self:writeByte(addr + i, buffer.readu8(blk, i))
	end
end

-- ============================================================
-- BULK LOAD (used by BIOS/bootloader to install binary code)
-- ============================================================
-- Load a string of bytes into ROM at offset
function Memory:loadROM(data, offset)
	offset = offset or 0
	for i = 1, #data do
		local b = string.byte(data, i)
		if offset + (i - 1) < self.romSize then
			buffer.writeu8(self.rom, offset + (i - 1), b)
		end
	end
end

-- Load bytes into RAM at physical address
function Memory:loadRAM(addr, data)
	local ramOffset = addr - self.ramBase
	for i = 1, #data do
		local b = string.byte(data, i)
		if ramOffset + (i - 1) < self.ramSize then
			buffer.writeu8(self.ram, ramOffset + (i - 1), b)
		end
	end
end

-- Load a buffer into RAM
function Memory:loadBufferRAM(addr, buf, srcOff, len)
	srcOff = srcOff or 0
	len = len or buffer.len(buf)
	local ramOffset = addr - self.ramBase
	if ramOffset >= 0 and ramOffset + len <= self.ramSize then
		buffer.copy(self.ram, ramOffset, buf, srcOff, len)
	end
end

-- Write a 32-bit instruction array into ROM (for bootloader)
function Memory:writeROMInstructions(instrTable, offset)
	offset = offset or 0
	for i, instr in ipairs(instrTable) do
		local pos = offset + (i - 1) * 4
		if pos + 3 < self.romSize then
			buffer.writeu32(self.rom, pos, instr)
		end
	end
end

-- Write instruction array into RAM
function Memory:writeRAMInstructions(addr, instrTable)
	local ramOffset = addr - self.ramBase
	for i, instr in ipairs(instrTable) do
		local pos = ramOffset + (i - 1) * 4
		if pos + 3 < self.ramSize then
			buffer.writeu32(self.ram, pos, instr)
		end
	end
end

-- ============================================================
-- UTILITY
-- ============================================================
-- Fill a region with a byte value
function Memory:fill(addr, size, val)
	val = bit32.band(val or 0, 0xFF)
	if addr >= self.ramBase and addr + size <= self.ramBase + self.ramSize then
		local off = addr - self.ramBase
		for i = 0, size - 1 do
			buffer.writeu8(self.ram, off + i, val)
		end
		return
	end
	for i = 0, size - 1 do
		self:writeByte(addr + i, val)
	end
end

-- Zero out a region
function Memory:zero(addr, size)
	self:fill(addr, size, 0)
end

-- Copy a region within memory
function Memory:copy(dst, src, size)
	for i = 0, size - 1 do
		self:writeByte(dst + i, self:readByte(src + i))
	end
end

-- Dump hex for debugging
function Memory:hexDump(addr, size)
	local lines = {}
	for row = 0, math.ceil(size / 16) - 1 do
		local base = addr + row * 16
		local hex = {}
		local asc = {}
		for col = 0, 15 do
			local b = self:readByte(base + col)
			hex[#hex + 1] = string.format("%02X", b)
			asc[#asc + 1] = (b >= 0x20 and b < 0x7F) and string.char(b) or "."
		end
		lines[#lines + 1] = string.format("%08X  %-47s  %s", base, table.concat(hex, " "), table.concat(asc))
	end
	return table.concat(lines, "\n")
end

-- Read a null-terminated C string from memory
function Memory:readCString(addr, maxLen)
	maxLen = maxLen or 4096
	local chars = {}
	for i = 0, maxLen - 1 do
		local b = self:readByte(addr + i)
		if b == 0 then
			break
		end
		chars[#chars + 1] = string.char(b)
	end
	return table.concat(chars)
end

-- Write a null-terminated C string to memory
function Memory:writeCString(addr, str)
	for i = 1, #str do
		self:writeByte(addr + i - 1, string.byte(str, i))
	end
	self:writeByte(addr + #str, 0) -- null terminator
	return #str + 1
end

-- Compute a simple checksum (for integrity checking)
function Memory:checksum(addr, size)
	local sum = 0
	for i = 0, size - 1 do
		sum = bit32.bxor(sum, bit32.lshift(self:readByte(addr + i), bit32.band(i, 3) * 8))
	end
	return sum
end

function Memory:stats()
	return self.stats
end

-- Lock ROM after BIOS finishes loading
function Memory:lockROM()
	self.romLocked = true
end

-- Get available RAM info
function Memory:info()
	return {
		romBase = self.romBase,
		romSize = self.romSize,
		ramBase = self.ramBase,
		ramSize = self.ramSize,
		mmioBase = MMAP.MMIO_BASE,
		totalBytes = self.romSize + self.ramSize,
		totalMB = (self.romSize + self.ramSize) / (1024 * 1024),
	}
end

return Memory
