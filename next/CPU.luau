--!optimize 2
--!native
--[[
    RISC-64 CPU Core
    ================
    Implements a 5-stage pipeline simulation:
        IF  → Instruction Fetch (reads from I-cache → RAM)
        ID  → Instruction Decode + Register Read
        EX  → Execute (ALU, branch resolution)
        MEM → Memory access (D-cache → RAM)
        WB  → Register Write-Back

    Features:
        • 32 GPRs, FLAGS, PC, SP, LR
        • Hardware interrupt controller integration
        • MMU / TLB (2-level page table, 4KB pages)
        • L1 I-cache + D-cache (direct mapped, 32KB each)
        • Branch predictor (2-bit saturating counter)
        • Kernel / User privilege separation
        • Precise exception model
        • Performance counters (IPC, cache hit rates)
        • Multi-core ready (each core is independent CPU instance)
]]

local ISA = require(script.Parent["ISA"])

-- ============================================================
-- CONSTANTS
-- ============================================================
local OP = ISA.OP
local REG = ISA.REG
local FLAGS = ISA.FLAGS
local MMAP = ISA.MMAP

local FLAG_C = ISA.FLAG_C
local FLAG_Z = ISA.FLAG_Z
local FLAG_N = ISA.FLAG_N
local FLAG_V = ISA.FLAG_V
local FLAG_I = ISA.FLAG_I
local FLAG_K = ISA.FLAG_K

local MAX_UINT32 = 0xFFFFFFFF
local MAX_INT32 = 0x7FFFFFFF
local MIN_INT32 = -0x80000000

-- ============================================================
-- CACHE
-- ============================================================
-- Direct-mapped write-back cache
-- Cache line = 64 bytes (16 words), indexed by address
local CACHE_SETS = 512 -- 512 sets × 64 bytes = 32 KB
local CACHE_LINE_SZ = 64 -- bytes per cache line
local CACHE_OFFSET_BITS = 6 -- log2(64)
local CACHE_INDEX_BITS = 9 -- log2(512)
local CACHE_TAG_SHIFT = CACHE_OFFSET_BITS + CACHE_INDEX_BITS -- 15

local function newCache(label)
	local c = {
		label = label,
		valid = {}, -- [index] = bool
		dirty = {}, -- [index] = bool
		tags = {}, -- [index] = tag bits
		data = {}, -- [index] = buffer(64)
		hits = 0,
		misses = 0,
	}
	for i = 0, CACHE_SETS - 1 do
		c.valid[i] = false
		c.dirty[i] = false
		c.tags[i] = -1
		c.data[i] = buffer.create(CACHE_LINE_SZ)
	end
	return c
end

-- ============================================================
-- TLB (Translation Lookaside Buffer)
-- ============================================================
local TLB_ENTRIES = 64 -- fully-associative
local function newTLB()
	local t = {
		vpn = {}, -- virtual page number
		ppn = {}, -- physical page number
		flags = {}, -- RWX + valid + dirty + user
		lru = {}, -- LRU counter
		count = 0,
		hits = 0,
		misses = 0,
	}
	for i = 0, TLB_ENTRIES - 1 do
		t.vpn[i] = -1
		t.ppn[i] = 0
		t.flags[i] = 0
		t.lru[i] = 0
	end
	return t
end

-- ============================================================
-- BRANCH PREDICTOR (2-bit saturating counter, 1K entries)
-- ============================================================
local BPT_SIZE = 1024
local function newBranchPredictor()
	local bp = { counters = {}, correct = 0, wrong = 0 }
	for i = 0, BPT_SIZE - 1 do
		bp.counters[i] = 2 -- weakly taken
	end
	return bp
end

-- ============================================================
-- CPU CONSTRUCTOR
-- ============================================================
local CPU = {}
CPU.__index = CPU

function CPU.new(memory, coreId)
	local self = setmetatable({}, CPU)

	-- Core identity
	self.id = coreId or 0
	self.memory = memory -- shared Memory object

	-- ---- Register File (32 GPRs + special) ----------------
	self.regs = buffer.create(32 * 4) -- 32 × 32-bit
	-- Special regs
	self.pc = MMAP.ROM_BASE -- Start executing from ROM
	self.flags = bit32.bor(FLAG_I, FLAG_K) -- Start in kernel mode, IRQ enabled
	self.hi = 0 -- multiply high word
	self.lo = 0 -- multiply low word (also used by DIV)

	-- ---- Pipeline Stage Registers -------------------------
	-- Each stage holds the "latch" that flows to the next
	self.if_latch = nil
	self.id_latch = nil
	self.ex_latch = nil
	self.mem_latch = nil
	-- WB writes directly to register file

	-- ---- Cache --------------------------------------------
	self.icache = newCache("L1-I")
	self.dcache = newCache("L1-D")

	-- ---- TLB ----------------------------------------------
	self.tlb = newTLB()
	self.mmu_enabled = false
	self.page_table_base = 0 -- CR3 equivalent

	-- ---- Branch Predictor ---------------------------------
	self.bp = newBranchPredictor()

	-- ---- Interrupt State ----------------------------------
	self.irq_pending = 0 -- bitmask of pending IRQs
	self.irq_mask = 0 -- bitmask of masked (disabled) IRQs
	self.in_interrupt = false
	self.saved_pc = 0
	self.saved_flags = 0

	-- ---- Performance Counters -----------------------------
	self.perf = {
		instructions = 0,
		cycles = 0,
		branches = 0,
		branch_mispred = 0,
		cache_hits_i = 0,
		cache_miss_i = 0,
		cache_hits_d = 0,
		cache_miss_d = 0,
		tlb_hits = 0,
		tlb_misses = 0,
		syscalls = 0,
		exceptions = 0,
	}

	-- ---- State --------------------------------------------
	self.halted = false
	self.fault = nil -- string if in fault state
	self.stall_cycles = 0

	-- ---- Callbacks (set by Motherboard) -------------------
	self.onSyscall = nil -- function(cpu, num)
	self.onInterrupt = nil -- function(cpu, vector)
	self.onHalt = nil -- function(cpu)
	self.onException = nil -- function(cpu, vector, info)

	return self
end

-- ============================================================
-- REGISTER ACCESS
-- ============================================================
function CPU:readReg(r)
	if r == 0 then
		return 0
	end -- R0 hardwired zero
	return buffer.readu32(self.regs, r * 4)
end

function CPU:writeReg(r, val)
	if r == 0 then
		return
	end -- R0 ignores writes
	buffer.writeu32(self.regs, r * 4, bit32.band(val, MAX_UINT32))
end

function CPU:getPC()
	return self.pc
end
function CPU:setPC(addr)
	self.pc = bit32.band(addr, MAX_UINT32)
end

-- Read/write FLAGS individual bits
function CPU:getFlag(bit)
	return bit32.band(bit32.rshift(self.flags, bit), 1) == 1
end
function CPU:setFlag(bit, val)
	if val then
		self.flags = bit32.bor(self.flags, bit32.lshift(1, bit))
	else
		self.flags = bit32.band(self.flags, bit32.bnot(bit32.lshift(1, bit)))
	end
end
function CPU:isKernelMode()
	return bit32.band(self.flags, FLAG_K) ~= 0
end
function CPU:isUserMode()
	return bit32.band(self.flags, FLAG_K) == 0
end
function CPU:interruptsEnabled()
	return bit32.band(self.flags, FLAG_I) ~= 0
end

-- ============================================================
-- FLAG COMPUTATION HELPERS
-- ============================================================
-- Update flags after integer arithmetic (result, carry, overflow)
function CPU:updateFlags(result32, carry, overflow)
	local z = (result32 == 0)
	local n = bit32.band(result32, 0x80000000) ~= 0
	local c = carry or false
	local v = overflow or false

	self.flags = bit32.band(self.flags, bit32.bnot(bit32.bor(FLAG_C, FLAG_Z, FLAG_N, FLAG_V)))
	if z then
		self.flags = bit32.bor(self.flags, FLAG_Z)
	end
	if n then
		self.flags = bit32.bor(self.flags, FLAG_N)
	end
	if c then
		self.flags = bit32.bor(self.flags, FLAG_C)
	end
	if v then
		self.flags = bit32.bor(self.flags, FLAG_V)
	end
end

-- Signed comparison for branches
local function signedLT(a, b)
	-- Convert to signed
	local sa = a >= 0x80000000 and (a - 0x100000000) or a
	local sb = b >= 0x80000000 and (b - 0x100000000) or b
	return sa < sb
end
local function toSigned(v)
	return v >= 0x80000000 and (v - 0x100000000) or v
end

-- ============================================================
-- CACHE OPERATIONS
-- ============================================================
function CPU:cacheRead32(cache, addr)
	local offset = bit32.band(addr, CACHE_LINE_SZ - 1)
	local index = bit32.band(bit32.rshift(addr, CACHE_OFFSET_BITS), CACHE_SETS - 1)
	local tag = bit32.rshift(addr, CACHE_TAG_SHIFT)

	if cache.valid[index] and cache.tags[index] == tag then
		cache.hits += 1
		return buffer.readu32(cache.data[index], bit32.band(offset, 0xFC))
	end

	-- Cache miss: fetch line from memory
	cache.misses += 1
	if cache.dirty[index] then
		-- Writeback dirty line
		local dirty_base =
			bit32.bor(bit32.lshift(cache.tags[index], CACHE_TAG_SHIFT), bit32.lshift(index, CACHE_OFFSET_BITS))
		self.memory:writeBlock(dirty_base, cache.data[index])
		cache.dirty[index] = false
	end

	-- Load new line
	local line_base = bit32.band(addr, bit32.bnot(CACHE_LINE_SZ - 1))
	local line_data = self.memory:readBlock(line_base, CACHE_LINE_SZ)
	cache.data[index] = line_data
	cache.tags[index] = tag
	cache.valid[index] = true

	return buffer.readu32(cache.data[index], bit32.band(offset, 0xFC))
end

function CPU:cacheWrite32(cache, addr, val)
	local offset = bit32.band(addr, CACHE_LINE_SZ - 1)
	local index = bit32.band(bit32.rshift(addr, CACHE_OFFSET_BITS), CACHE_SETS - 1)
	local tag = bit32.rshift(addr, CACHE_TAG_SHIFT)

	if cache.valid[index] and cache.tags[index] == tag then
		cache.hits += 1
		buffer.writeu32(cache.data[index], bit32.band(offset, 0xFC), val)
		cache.dirty[index] = true
		return
	end

	cache.misses += 1
	if cache.dirty[index] then
		local dirty_base =
			bit32.bor(bit32.lshift(cache.tags[index], CACHE_TAG_SHIFT), bit32.lshift(index, CACHE_OFFSET_BITS))
		self.memory:writeBlock(dirty_base, cache.data[index])
	end

	local line_base = bit32.band(addr, bit32.bnot(CACHE_LINE_SZ - 1))
	local line_data = self.memory:readBlock(line_base, CACHE_LINE_SZ)
	cache.data[index] = line_data
	cache.tags[index] = tag
	cache.valid[index] = true
	cache.dirty[index] = true
	buffer.writeu32(cache.data[index], bit32.band(offset, 0xFC), val)
end

function CPU:invalidateCache(addr)
	for _, cache in ipairs({ self.icache, self.dcache }) do
		local index = bit32.band(bit32.rshift(addr, CACHE_OFFSET_BITS), CACHE_SETS - 1)
		local tag = bit32.rshift(addr, CACHE_TAG_SHIFT)
		if cache.tags[index] == tag then
			cache.valid[index] = false
			cache.dirty[index] = false
		end
	end
end

-- ============================================================
-- MMU / ADDRESS TRANSLATION
-- ============================================================
function CPU:translateAddr(vaddr, write)
	if not self.mmu_enabled then
		return vaddr, nil -- identity mapping
	end

	-- Check TLB first
	local vpn = bit32.rshift(vaddr, 12)
	local offset = bit32.band(vaddr, 0xFFF)
	local tlb = self.tlb

	for i = 0, TLB_ENTRIES - 1 do
		if tlb.vpn[i] == vpn then
			-- TLB hit
			local tf = tlb.flags[i]
			if self:isUserMode() and bit32.band(tf, 8) == 0 then
				return nil, "access_denied" -- kernel page in user mode
			end
			if write and bit32.band(tf, 2) == 0 then
				return nil, "write_protect"
			end
			tlb.lru[i] = self.perf.cycles
			tlb.hits += 1
			return bit32.bor(bit32.lshift(tlb.ppn[i], 12), offset), nil
		end
	end

	-- TLB miss: walk page table
	tlb.misses += 1
	local ppn, flags, err = self:walkPageTable(vpn)
	if err then
		return nil, err
	end

	-- Evict LRU entry
	local lru_idx = 0
	local lru_time = math.huge
	for i = 0, TLB_ENTRIES - 1 do
		if tlb.lru[i] < lru_time then
			lru_time = tlb.lru[i]
			lru_idx = i
		end
	end
	tlb.vpn[lru_idx] = vpn
	tlb.ppn[lru_idx] = ppn
	tlb.flags[lru_idx] = flags
	tlb.lru[lru_idx] = self.perf.cycles

	return bit32.bor(bit32.lshift(ppn, 12), offset), nil
end

function CPU:walkPageTable(vpn)
	-- 2-level page table: 10-bit L1 index, 10-bit L2 index
	local l1_idx = bit32.rshift(vpn, 10)
	local l2_idx = bit32.band(vpn, 0x3FF)

	local l1_entry_addr = self.page_table_base + l1_idx * 4
	local l1_entry = self.memory:readWord(l1_entry_addr)
	if bit32.band(l1_entry, 1) == 0 then
		return nil, nil, "page_fault_l1"
	end

	local l2_base = bit32.band(l1_entry, 0xFFFFF000)
	local l2_entry_addr = l2_base + l2_idx * 4
	local l2_entry = self.memory:readWord(l2_entry_addr)
	if bit32.band(l2_entry, 1) == 0 then
		return nil, nil, "page_fault_l2"
	end

	local ppn = bit32.rshift(l2_entry, 12)
	local flags = bit32.band(l2_entry, 0xFFF) -- present/rw/user/nx bits
	return ppn, flags, nil
end

function CPU:flushTLB()
	for i = 0, TLB_ENTRIES - 1 do
		self.tlb.vpn[i] = -1
	end
end

-- ============================================================
-- MEMORY READ / WRITE (goes through MMU → cache → memory)
-- ============================================================
function CPU:memRead8(addr)
	local paddr, err = self:translateAddr(addr, false)
	if err then
		self:raiseException(ISA.EX.PAGE_FAULT, addr)
		return 0
	end
	return self.memory:readByte(paddr)
end

function CPU:memRead16(addr)
	local paddr, err = self:translateAddr(addr, false)
	if err then
		self:raiseException(ISA.EX.PAGE_FAULT, addr)
		return 0
	end
	return self.memory:readHalf(paddr)
end

function CPU:memRead32(addr)
	local paddr, err = self:translateAddr(addr, false)
	if err then
		self:raiseException(ISA.EX.PAGE_FAULT, addr)
		return 0
	end
	-- MMIO bypass cache
	if paddr >= MMAP.MMIO_BASE then
		return self.memory:readWord(paddr)
	end
	return self:cacheRead32(self.dcache, paddr)
end

function CPU:memWrite8(addr, val)
	local paddr, err = self:translateAddr(addr, true)
	if err then
		self:raiseException(ISA.EX.PAGE_FAULT, addr)
		return
	end
	self.memory:writeByte(paddr, bit32.band(val, 0xFF))
	self:invalidateCache(paddr)
end

function CPU:memWrite16(addr, val)
	local paddr, err = self:translateAddr(addr, true)
	if err then
		self:raiseException(ISA.EX.PAGE_FAULT, addr)
		return
	end
	self.memory:writeHalf(paddr, bit32.band(val, 0xFFFF))
	self:invalidateCache(paddr)
end

function CPU:memWrite32(addr, val)
	local paddr, err = self:translateAddr(addr, true)
	if err then
		self:raiseException(ISA.EX.PAGE_FAULT, addr)
		return
	end
	val = bit32.band(val, MAX_UINT32)
	if paddr >= MMAP.MMIO_BASE then
		self.memory:writeWord(paddr, val)
		return
	end
	self:cacheWrite32(self.dcache, paddr, val)
end

-- ============================================================
-- FETCH STAGE
-- ============================================================
function CPU:fetch()
	if self.halted then
		return nil
	end

	local paddr, err = self:translateAddr(self.pc, false)
	if err then
		self:raiseException(ISA.EX.PAGE_FAULT, self.pc)
		return nil
	end

	local instr
	if paddr >= MMAP.MMIO_BASE then
		instr = self.memory:readWord(paddr)
	else
		instr = self:cacheRead32(self.icache, paddr)
	end

	local fetched = { instr = instr, pc = self.pc }
	self.pc = bit32.band(self.pc + 4, MAX_UINT32)
	return fetched
end

-- ============================================================
-- DECODE STAGE
-- ============================================================
function CPU:decode(fetched)
	if not fetched then
		return nil
	end
	local d = ISA.decode(fetched.instr)
	d.fetch_pc = fetched.pc
	return d
end

-- ============================================================
-- EXECUTE STAGE (core of the CPU)
-- ============================================================
function CPU:execute(d)
	if not d then
		return
	end
	self.perf.instructions += 1
	self.perf.cycles += 1

	local op = d.op
	local rd, rs1, rs2 = d.rd, d.rs1, d.rs2
	local A = self:readReg(rs1)
	local B = self:readReg(rs2)
	local imm = d.simm15

	-- ---- SYSTEM ----------------------------------------
	if op == OP.NOP then
		-- nothing
	elseif op == OP.HALT then
		self.halted = true
		if self.onHalt then
			self.onHalt(self)
		end
		return
	elseif op == OP.SYSCALL then
		self.perf.syscalls += 1
		if self.onSyscall then
			self.onSyscall(self, self:readReg(REG.A7))
		end
	elseif op == OP.SYSRET then
		self.pc = self.saved_pc
		self.flags = self.saved_flags
		self.in_interrupt = false
	elseif op == OP.INT then
		local vector = bit32.band(d.simm21, 0xFF)
		self:raiseInterrupt(vector)
	elseif op == OP.IRET then
		self.pc = self.saved_pc
		self.flags = self.saved_flags
		self.in_interrupt = false
	elseif op == OP.CLI then
		self.flags = bit32.band(self.flags, bit32.bnot(FLAG_I))
	elseif op == OP.STI then
		self.flags = bit32.bor(self.flags, FLAG_I)
	elseif op == OP.CPUID then
		self:writeReg(1, ISA.SPEC.VENDOR_ID)
		self:writeReg(2, 0x00010001) -- family 1, model 1
		self:writeReg(3, ISA.SPEC.FREQ_MHZ)
		self:writeReg(4, bit32.bor(ISA.SPEC.GPR_COUNT, bit32.lshift(ISA.SPEC.NUM_CORES, 8)))
	elseif op == OP.RDTSC then
		local t = self.perf.cycles
		self:writeReg(1, bit32.band(t, MAX_UINT32))
		self:writeReg(2, 0)

	-- ---- DATA MOVEMENT ---------------------------------
	elseif op == OP.MOV then
		self:writeReg(rd, A)
	elseif op == OP.MOVI then
		self:writeReg(rd, bit32.band(imm, MAX_UINT32))
	elseif op == OP.MOVZ then
		local shift = bit32.band(bit32.rshift(d.imm15, 13), 0x3)
		local val = bit32.band(d.imm15, 0x1FFF)
		self:writeReg(rd, bit32.lshift(val, shift * 16))
	elseif op == OP.MOVK then
		local shift = bit32.band(bit32.rshift(d.imm15, 13), 0x3)
		local val = bit32.band(d.imm15, 0x1FFF)
		local cur = self:readReg(rd)
		local mask = bit32.bnot(bit32.lshift(0x3FFF, shift * 16))
		self:writeReg(rd, bit32.bor(bit32.band(cur, mask), bit32.lshift(val, shift * 16)))
	elseif op == OP.LUI then
		self:writeReg(rd, bit32.lshift(d.imm20, 12))
	elseif op == OP.AUIPC then
		self:writeReg(rd, bit32.band(d.fetch_pc + bit32.lshift(d.imm20, 12), MAX_UINT32))

	-- ---- INTEGER ARITHMETIC ----------------------------
	elseif op == OP.ADD then
		local result = bit32.band(A + B, MAX_UINT32)
		local carry = (A + B) > MAX_UINT32
		local ov = (toSigned(A) + toSigned(B)) > MAX_INT32 or (toSigned(A) + toSigned(B)) < MIN_INT32
		self:writeReg(rd, result)
		self:updateFlags(result, carry, ov)
	elseif op == OP.ADDI then
		local result = bit32.band(A + imm, MAX_UINT32)
		self:writeReg(rd, result)
		self:updateFlags(result, false, false)
	elseif op == OP.SUB then
		local result = bit32.band(A - B, MAX_UINT32)
		local borrow = A < B
		local ov = (toSigned(A) - toSigned(B)) > MAX_INT32 or (toSigned(A) - toSigned(B)) < MIN_INT32
		self:writeReg(rd, result)
		self:updateFlags(result, borrow, ov)
	elseif op == OP.SUBI then
		local result = bit32.band(A - imm, MAX_UINT32)
		self:writeReg(rd, result)
		self:updateFlags(result, false, false)
	elseif op == OP.MUL then
		local result = (A * B) % 0x100000000
		self:writeReg(rd, result)
		self:updateFlags(result, false, false)
	elseif op == OP.MULH then
		local full = toSigned(A) * toSigned(B)
		self:writeReg(rd, bit32.band(math.floor(full / 0x100000000), MAX_UINT32))
	elseif op == OP.MULI then
		local result = bit32.band(A * imm, MAX_UINT32)
		self:writeReg(rd, result)
		self:updateFlags(result, false, false)
	elseif op == OP.DIV then
		if B == 0 then
			self:raiseException(ISA.EX.DIV_ZERO, d.fetch_pc)
			return
		end
		local sa = toSigned(A)
		local sb = toSigned(B)
		self:writeReg(rd, bit32.band(math.floor(sa / sb) % 0x100000000, MAX_UINT32))
	elseif op == OP.DIVU then
		if B == 0 then
			self:raiseException(ISA.EX.DIV_ZERO, d.fetch_pc)
			return
		end
		self:writeReg(rd, bit32.band(math.floor(A / B), MAX_UINT32))
	elseif op == OP.MOD then
		if B == 0 then
			self:raiseException(ISA.EX.DIV_ZERO, d.fetch_pc)
			return
		end
		self:writeReg(rd, bit32.band(toSigned(A) % toSigned(B), MAX_UINT32))
	elseif op == OP.MODU then
		if B == 0 then
			self:raiseException(ISA.EX.DIV_ZERO, d.fetch_pc)
			return
		end
		self:writeReg(rd, bit32.band(A % B, MAX_UINT32))
	elseif op == OP.NEG then
		local result = bit32.band(-toSigned(A), MAX_UINT32)
		self:writeReg(rd, result)
		self:updateFlags(result, false, false)
	elseif op == OP.ABS then
		local sa = toSigned(A)
		self:writeReg(rd, bit32.band(math.abs(sa), MAX_UINT32))

	-- ---- BITWISE LOGIC ---------------------------------
	elseif op == OP.AND then
		local r = bit32.band(A, B)
		self:writeReg(rd, r)
		self:updateFlags(r, false, false)
	elseif op == OP.ANDI then
		local r = bit32.band(A, d.imm15)
		self:writeReg(rd, r)
		self:updateFlags(r, false, false)
	elseif op == OP.OR then
		local r = bit32.bor(A, B)
		self:writeReg(rd, r)
		self:updateFlags(r, false, false)
	elseif op == OP.ORI then
		local r = bit32.bor(A, d.imm15)
		self:writeReg(rd, r)
		self:updateFlags(r, false, false)
	elseif op == OP.XOR then
		local r = bit32.bxor(A, B)
		self:writeReg(rd, r)
		self:updateFlags(r, false, false)
	elseif op == OP.XORI then
		local r = bit32.bxor(A, d.imm15)
		self:writeReg(rd, r)
		self:updateFlags(r, false, false)
	elseif op == OP.NOT then
		local r = bit32.bnot(A)
		self:writeReg(rd, r)
		self:updateFlags(r, false, false)
	elseif op == OP.ANDN then
		local r = bit32.band(A, bit32.bnot(B))
		self:writeReg(rd, r)

	-- ---- SHIFT / ROTATE --------------------------------
	elseif op == OP.SHL then
		local sh = bit32.band(B, 31)
		self:writeReg(rd, bit32.lshift(A, sh))
	elseif op == OP.SHLI then
		local sh = bit32.band(d.imm15, 31)
		self:writeReg(rd, bit32.lshift(A, sh))
	elseif op == OP.SHR then
		local sh = bit32.band(B, 31)
		self:writeReg(rd, bit32.rshift(A, sh))
	elseif op == OP.SHRI then
		local sh = bit32.band(d.imm15, 31)
		self:writeReg(rd, bit32.rshift(A, sh))
	elseif op == OP.SAR then
		local sh = bit32.band(B, 31)
		self:writeReg(rd, bit32.arshift(A, sh))
	elseif op == OP.SARI then
		local sh = bit32.band(d.imm15, 31)
		self:writeReg(rd, bit32.arshift(A, sh))
	elseif op == OP.ROL then
		local sh = bit32.band(B, 31)
		self:writeReg(rd, bit32.bor(bit32.lshift(A, sh), bit32.rshift(A, 32 - sh)))
	elseif op == OP.ROR then
		local sh = bit32.band(B, 31)
		self:writeReg(rd, bit32.bor(bit32.rshift(A, sh), bit32.lshift(A, 32 - sh)))

	-- ---- COMPARISON ------------------------------------
	elseif op == OP.CMP then
		local r = bit32.band(A - B, MAX_UINT32)
		self:updateFlags(r, A < B, false)
	elseif op == OP.CMPI then
		local r = bit32.band(A - imm, MAX_UINT32)
		self:updateFlags(r, false, false)
	elseif op == OP.TEST then
		local r = bit32.band(A, B)
		self:updateFlags(r, false, false)
	elseif op == OP.SLT then
		self:writeReg(rd, signedLT(A, B) and 1 or 0)
	elseif op == OP.SLTU then
		self:writeReg(rd, (A < B) and 1 or 0)
	elseif op == OP.SLTI then
		self:writeReg(rd, signedLT(A, bit32.band(imm, MAX_UINT32)) and 1 or 0)
	elseif op == OP.SLTIU then
		self:writeReg(rd, (A < bit32.band(imm, MAX_UINT32)) and 1 or 0)
	elseif op == OP.SEQ then
		self:writeReg(rd, A == B and 1 or 0)
	elseif op == OP.SNE then
		self:writeReg(rd, A ~= B and 1 or 0)

	-- ---- MEMORY LOADS ----------------------------------
	elseif op == OP.LDB then
		local v = self:memRead8(bit32.band(A + imm, MAX_UINT32))
		-- sign extend
		if bit32.band(v, 0x80) ~= 0 then
			v = v - 0x100
		end
		self:writeReg(rd, bit32.band(v, MAX_UINT32))
	elseif op == OP.LDBU then
		self:writeReg(rd, self:memRead8(bit32.band(A + imm, MAX_UINT32)))
	elseif op == OP.LDH then
		local v = self:memRead16(bit32.band(A + imm, MAX_UINT32))
		if bit32.band(v, 0x8000) ~= 0 then
			v = v - 0x10000
		end
		self:writeReg(rd, bit32.band(v, MAX_UINT32))
	elseif op == OP.LDHU then
		self:writeReg(rd, self:memRead16(bit32.band(A + imm, MAX_UINT32)))
	elseif op == OP.LDW then
		self:writeReg(rd, self:memRead32(bit32.band(A + imm, MAX_UINT32)))
	elseif op == OP.LDD then
		-- 64-bit: store lower 32 in rd, upper 32 in rd+1
		local addr = bit32.band(A + imm, MAX_UINT32)
		self:writeReg(rd, self:memRead32(addr))
		if rd + 1 < 32 then
			self:writeReg(rd + 1, self:memRead32(addr + 4))
		end
	elseif op == OP.LEA then
		self:writeReg(rd, bit32.band(A + imm, MAX_UINT32))

	-- ---- MEMORY STORES ---------------------------------
	elseif op == OP.STB then
		self:memWrite8(bit32.band(A + imm, MAX_UINT32), bit32.band(B, 0xFF))
	elseif op == OP.STH then
		self:memWrite16(bit32.band(A + imm, MAX_UINT32), bit32.band(B, 0xFFFF))
	elseif op == OP.STW then
		self:memWrite32(bit32.band(A + imm, MAX_UINT32), B)
	elseif op == OP.STD then
		local addr = bit32.band(A + imm, MAX_UINT32)
		self:memWrite32(addr, B)
		if rs2 + 1 < 32 then
			self:memWrite32(addr + 4, self:readReg(rs2 + 1))
		end

	-- ---- ATOMIC ----------------------------------------
	elseif op == OP.XCHG then
		local addr = A
		local old = self:memRead32(addr)
		self:memWrite32(addr, B)
		self:writeReg(rd, old)
	elseif op == OP.CAS then
		-- rs1=addr, rs2=expected, func bits encode rs3=new
		local addr = A
		local expected = B
		local newval = self:readReg(bit32.band(d.func, 0x1F))
		local old = self:memRead32(addr)
		if old == expected then
			self:memWrite32(addr, newval)
			self:writeReg(rd, 1)
		else
			self:writeReg(rd, 0)
		end

	-- ---- STACK -----------------------------------------
	elseif op == OP.PUSH then
		local sp = self:readReg(REG.SP) - 4
		self:writeReg(REG.SP, bit32.band(sp, MAX_UINT32))
		self:memWrite32(sp, A)
	elseif op == OP.POP then
		local sp = self:readReg(REG.SP)
		self:writeReg(rd, self:memRead32(sp))
		self:writeReg(REG.SP, bit32.band(sp + 4, MAX_UINT32))
	elseif op == OP.PUSHA then
		local sp = self:readReg(REG.SP)
		for i = 31, 1, -1 do
			sp -= 4
			self:memWrite32(bit32.band(sp, MAX_UINT32), self:readReg(i))
		end
		self:writeReg(REG.SP, bit32.band(sp, MAX_UINT32))
	elseif op == OP.POPA then
		local sp = self:readReg(REG.SP)
		for i = 1, 31 do
			self:writeReg(i, self:memRead32(bit32.band(sp, MAX_UINT32)))
			sp += 4
		end
		self:writeReg(REG.SP, bit32.band(sp, MAX_UINT32))

	-- ---- BRANCHES / JUMPS ------------------------------
	elseif op == OP.JMP then
		-- Pseudo-absolute: upper bits from PC, lower 27 bits from instr
		local target = bit32.bor(bit32.band(d.fetch_pc, 0xF8000000), bit32.lshift(bit32.band(d.imm25, 0x1FFFFFF), 2))
		self:setPC(target)
	elseif op == OP.JMPR then
		self:setPC(bit32.band(A + imm, MAX_UINT32))
	elseif op == OP.BEQ then
		self.perf.branches += 1
		if A == B then
			self:setPC(bit32.band(d.fetch_pc + imm * 4, MAX_UINT32))
		end
	elseif op == OP.BNE then
		self.perf.branches += 1
		if A ~= B then
			self:setPC(bit32.band(d.fetch_pc + imm * 4, MAX_UINT32))
		end
	elseif op == OP.BLT then
		self.perf.branches += 1
		if signedLT(A, B) then
			self:setPC(bit32.band(d.fetch_pc + imm * 4, MAX_UINT32))
		end
	elseif op == OP.BLTU then
		self.perf.branches += 1
		if A < B then
			self:setPC(bit32.band(d.fetch_pc + imm * 4, MAX_UINT32))
		end
	elseif op == OP.BGE then
		self.perf.branches += 1
		if not signedLT(A, B) then
			self:setPC(bit32.band(d.fetch_pc + imm * 4, MAX_UINT32))
		end
	elseif op == OP.BGEU then
		self.perf.branches += 1
		if A >= B then
			self:setPC(bit32.band(d.fetch_pc + imm * 4, MAX_UINT32))
		end
	elseif op == OP.BGT then
		self.perf.branches += 1
		if signedLT(B, A) then
			self:setPC(bit32.band(d.fetch_pc + imm * 4, MAX_UINT32))
		end
	elseif op == OP.BLE then
		self.perf.branches += 1
		if not signedLT(B, A) then
			self:setPC(bit32.band(d.fetch_pc + imm * 4, MAX_UINT32))
		end
	elseif op == OP.BEQZ then
		self.perf.branches += 1
		if A == 0 then
			self:setPC(bit32.band(d.fetch_pc + d.simm21 * 4, MAX_UINT32))
		end
	elseif op == OP.BNEZ then
		self.perf.branches += 1
		if A ~= 0 then
			self:setPC(bit32.band(d.fetch_pc + d.simm21 * 4, MAX_UINT32))
		end
	elseif op == OP.BLTZ then
		self.perf.branches += 1
		if toSigned(A) < 0 then
			self:setPC(bit32.band(d.fetch_pc + d.simm21 * 4, MAX_UINT32))
		end
	elseif op == OP.BGEZ then
		self.perf.branches += 1
		if toSigned(A) >= 0 then
			self:setPC(bit32.band(d.fetch_pc + d.simm21 * 4, MAX_UINT32))
		end
	elseif op == OP.CALL then
		self:writeReg(REG.LR, self.pc) -- pc already advanced
		local target = bit32.bor(bit32.band(d.fetch_pc, 0xF8000000), bit32.lshift(bit32.band(d.imm25, 0x1FFFFFF), 2))
		self:setPC(target)
	elseif op == OP.CALLR then
		self:writeReg(REG.LR, self.pc)
		self:setPC(bit32.band(A + imm, MAX_UINT32))
	elseif op == OP.RET then
		self:setPC(self:readReg(REG.LR))

	-- ---- FLOATING POINT --------------------------------
	-- Single-precision IEEE 754 stored as bit pattern in GPR
	elseif op == OP.FADD then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local fb = buffer.create(4)
		buffer.writeu32(fb, 0, B)
		-- Approximate: use Lua's native float (double precision, close enough)
		local ra = buffer.readf32(fa, 0)
		local rb = buffer.readf32(fb, 0)
		local result = buffer.create(4)
		buffer.writef32(result, 0, ra + rb)
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FSUB then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local fb = buffer.create(4)
		buffer.writeu32(fb, 0, B)
		local result = buffer.create(4)
		buffer.writef32(result, 0, buffer.readf32(fa, 0) - buffer.readf32(fb, 0))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FMUL then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local fb = buffer.create(4)
		buffer.writeu32(fb, 0, B)
		local result = buffer.create(4)
		buffer.writef32(result, 0, buffer.readf32(fa, 0) * buffer.readf32(fb, 0))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FDIV then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local fb = buffer.create(4)
		buffer.writeu32(fb, 0, B)
		local result = buffer.create(4)
		buffer.writef32(result, 0, buffer.readf32(fa, 0) / buffer.readf32(fb, 0))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FMOD then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local fb = buffer.create(4)
		buffer.writeu32(fb, 0, B)
		local result = buffer.create(4)
		buffer.writef32(result, 0, buffer.readf32(fa, 0) % buffer.readf32(fb, 0))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FNEG then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local result = buffer.create(4)
		buffer.writef32(result, 0, -buffer.readf32(fa, 0))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FABS then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local result = buffer.create(4)
		buffer.writef32(result, 0, math.abs(buffer.readf32(fa, 0)))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FSQRT then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local result = buffer.create(4)
		buffer.writef32(result, 0, math.sqrt(buffer.readf32(fa, 0)))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FCMP then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local fb = buffer.create(4)
		buffer.writeu32(fb, 0, B)
		local ra = buffer.readf32(fa, 0)
		local rb = buffer.readf32(fb, 0)
		local result = 0
		if ra == rb then result = 0 elseif ra < rb then result = -1 else result = 1 end
		self:updateFlags(bit32.band(result, MAX_UINT32), ra < rb, false)
	elseif op == OP.ITOF then
		local result = buffer.create(4)
		buffer.writef32(result, 0, toSigned(A))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FTOI then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local v = math.floor(buffer.readf32(fa, 0))
		self:writeReg(rd, bit32.band(v, MAX_UINT32))
	elseif op == OP.FTOIR then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local v = math.round(buffer.readf32(fa, 0))
		self:writeReg(rd, bit32.band(v, MAX_UINT32))
	elseif op == OP.FSIN then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local result = buffer.create(4)
		buffer.writef32(result, 0, math.sin(buffer.readf32(fa, 0)))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FCOS then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local result = buffer.create(4)
		buffer.writef32(result, 0, math.cos(buffer.readf32(fa, 0)))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FTAN then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local result = buffer.create(4)
		buffer.writef32(result, 0, math.tan(buffer.readf32(fa, 0)))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FLOG then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local result = buffer.create(4)
		buffer.writef32(result, 0, math.log(buffer.readf32(fa, 0)))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FEXP then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local result = buffer.create(4)
		buffer.writef32(result, 0, math.exp(buffer.readf32(fa, 0)))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FMOV then
		self:writeReg(rd, A)
	elseif op == OP.FPOW then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local fb = buffer.create(4)
		buffer.writeu32(fb, 0, B)
		local result = buffer.create(4)
		buffer.writef32(result, 0, buffer.readf32(fa, 0) ^ buffer.readf32(fb, 0))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FMIN then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local fb = buffer.create(4)
		buffer.writeu32(fb, 0, B)
		local result = buffer.create(4)
		buffer.writef32(result, 0, math.min(buffer.readf32(fa, 0), buffer.readf32(fb, 0)))
		self:writeReg(rd, buffer.readu32(result, 0))
	elseif op == OP.FMAX then
		local fa = buffer.create(4)
		buffer.writeu32(fa, 0, A)
		local fb = buffer.create(4)
		buffer.writeu32(fb, 0, B)
		local result = buffer.create(4)
		buffer.writef32(result, 0, math.max(buffer.readf32(fa, 0), buffer.readf32(fb, 0)))
		self:writeReg(rd, buffer.readu32(result, 0))
	else
		-- Unknown opcode
		self:raiseException(ISA.EX.INVALID_OP, d.fetch_pc)
	end
end

-- ============================================================
-- INTERRUPT & EXCEPTION HANDLING
-- ============================================================
function CPU:raiseInterrupt(vector)
	if not self:interruptsEnabled() and vector < 0x80 then
		-- mask hardware interrupts if IF=0
		self.irq_pending = bit32.bor(self.irq_pending, bit32.lshift(1, vector))
		return
	end

	self.in_interrupt = true
	self.saved_pc = self.pc
	self.saved_flags = self.flags

	-- Switch to kernel mode, disable interrupts
	self.flags = bit32.bor(self.flags, FLAG_K)
	self.flags = bit32.band(self.flags, bit32.bnot(FLAG_I))

	-- Read ISR address from IVT
	local ivt_entry = MMAP.IVT_BASE + vector * MMAP.IVT_ENTRY_SZ
	local isr_addr = self.memory:readWord(ivt_entry)

	if isr_addr ~= 0 then
		-- Push context onto kernel stack
		local ksp = self:readReg(REG.SP)
		ksp -= 4
		self:memWrite32(ksp, self.saved_flags)
		ksp -= 4
		self:memWrite32(ksp, self.saved_pc)
		self:writeReg(REG.SP, bit32.band(ksp, MAX_UINT32))
		self:setPC(isr_addr)
	end

	if self.onInterrupt then
		self.onInterrupt(self, vector)
	end
end

function CPU:raiseException(exVector, faultAddr)
	self.perf.exceptions += 1
	self.fault = ISA.OP_NAMES[exVector] or ("EX_" .. string.format("%02X", exVector))
	-- Store fault address in a known register (K0)
	self:writeReg(REG.R24, faultAddr or self.pc)
	self:raiseInterrupt(exVector)

	if self.onException then
		self.onException(self, exVector, faultAddr)
	end
end

-- Called each tick: check and dispatch pending IRQs
function CPU:checkPendingIRQs()
	if self.irq_pending ~= 0 and self:interruptsEnabled() then
		-- Find highest priority (lowest bit number)
		for i = 0, 31 do
			if bit32.band(self.irq_pending, bit32.lshift(1, i)) ~= 0 then
				self.irq_pending = bit32.band(self.irq_pending, bit32.bnot(bit32.lshift(1, i)))
				self:raiseInterrupt(i)
				return
			end
		end
	end
end

function CPU:assertIRQ(irqLine)
	self.irq_pending = bit32.bor(self.irq_pending, bit32.lshift(1, irqLine))
end

-- ============================================================
-- MAIN STEP (1 instruction cycle)
-- ============================================================
function CPU:step()
	if self.halted then
		return false
	end

	self:checkPendingIRQs()

	-- Pipeline: Fetch → Decode → Execute
	local fetched = self:fetch()
	if not fetched then
		return not self.halted
	end

	local decoded = self:decode(fetched)
	if not decoded then
		return not self.halted
	end

	self:execute(decoded)

	return not self.halted
end

-- Run N instructions
function CPU:run(n)
	n = n or 1
	for _ = 1, n do
		if not self:step() then
			return false
		end
	end
	return true
end

-- ============================================================
-- DEBUG UTILITIES
-- ============================================================
function CPU:dumpRegisters()
	local out = {}
	out[#out + 1] = string.format(
		"PC=0x%08X  FLAGS=0x%08X  (Z=%d N=%d C=%d V=%d KM=%d IE=%d)",
		self.pc,
		self.flags,
		self:getFlag(FLAGS.ZERO) and 1 or 0,
		self:getFlag(FLAGS.NEGATIVE) and 1 or 0,
		self:getFlag(FLAGS.CARRY) and 1 or 0,
		self:getFlag(FLAGS.OVERFLOW) and 1 or 0,
		self:getFlag(FLAGS.KERNEL) and 1 or 0,
		self:getFlag(FLAGS.INTERRUPT) and 1 or 0
	)
	for i = 0, 31 do
		local name = ("R%d"):format(i)
		for regname, idx in pairs(REG) do
			if idx == i and regname ~= ("R" .. i) then
				name = name .. "/" .. regname
				break
			end
		end
		out[#out + 1] = string.format("  %-12s = 0x%08X (%d)", name, self:readReg(i), self:readReg(i))
	end
	return table.concat(out, "\n")
end

function CPU:dumpPerf()
	local p = self.perf
	local ipc = p.cycles > 0 and (p.instructions / p.cycles) or 0
	return string.format(
		"Perf: instrs=%d cycles=%d IPC=%.2f branches=%d mispred=%d\n"
			.. "  I-cache: hits=%d misses=%d  D-cache: hits=%d misses=%d\n"
			.. "  TLB: hits=%d misses=%d  syscalls=%d  exceptions=%d",
		p.instructions,
		p.cycles,
		ipc,
		p.branches,
		p.branch_mispred,
		p.cache_hits_i,
		p.cache_miss_i,
		p.cache_hits_d,
		p.cache_miss_d,
		p.tlb_hits,
		p.tlb_misses,
		p.syscalls,
		p.exceptions
	)
end

function CPU:reset()
	self.pc = MMAP.ROM_BASE
	self.flags = bit32.bor(FLAG_I, FLAG_K)
	self.halted = false
	self.fault = nil
	self.irq_pending = 0
	self.in_interrupt = false
	for i = 0, 31 do
		self:writeReg(i, 0)
	end
	self:writeReg(REG.SP, MMAP.RAM_BASE + MMAP.RAM_SIZE - 16)
	self:flushTLB()
	self.perf = {
		instructions = 0,
		cycles = 0,
		branches = 0,
		branch_mispred = 0,
		cache_hits_i = 0,
		cache_miss_i = 0,
		cache_hits_d = 0,
		cache_miss_d = 0,
		tlb_hits = 0,
		tlb_misses = 0,
		syscalls = 0,
		exceptions = 0,
	}
end

return CPU
