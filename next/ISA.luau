local ISA = {}

-- ============================================================
-- KEYBOARD SCANCODE MAPPING (Set 2)
-- ============================================================
ISA.KEY_MAP = {
	A = 0x1C,
	B = 0x32,
	C = 0x21,
	D = 0x23,
	E = 0x24,
	F = 0x2B,
	G = 0x34,
	H = 0x33,
	I = 0x43,
	J = 0x3B,
	K = 0x42,
	L = 0x4B,
	M = 0x3A,
	N = 0x31,
	O = 0x44,
	P = 0x4D,
	Q = 0x15,
	R = 0x2D,
	S = 0x1B,
	T = 0x2C,
	U = 0x3C,
	V = 0x2A,
	W = 0x1D,
	X = 0x22,
	Y = 0x35,
	Z = 0x1A,
	One = 0x16,
	Two = 0x1E,
	Three = 0x26,
	Four = 0x25,
	Five = 0x2E,
	Six = 0x36,
	Seven = 0x3D,
	Eight = 0x3E,
	Nine = 0x46,
	Zero = 0x45,
	Return = 0x5A,
	Escape = 0x76,
	BackSpace = 0x66,
	Tab = 0x0D,
	Space = 0x29,
	LeftShift = 0x12,
	RightShift = 0x59,
	LeftControl = 0x14,
	LeftAlt = 0x11,
	Up = 0x75,
	Down = 0x72,
	Left = 0x6B,
	Right = 0x74,
	F1 = 0x05,
	F2 = 0x06,
	F3 = 0x04,
	F4 = 0x0C,
	F5 = 0x03,
	F6 = 0x0B,
	F7 = 0x83,
	F8 = 0x0A,
	F9 = 0x01,
	F10 = 0x09,
	F11 = 0x78,
	F12 = 0x07,
	Period = 0x49,
	Comma = 0x41,
	Semicolon = 0x4C,
	Quote = 0x52,
	Minus = 0x4E,
	Equals = 0x55,
	Slash = 0x4A,
	Backslash = 0x5D,
}

-- ============================================================
-- REGISTER DEFINITIONS
-- ============================================================
ISA.REG = {
	R0 = 0, -- Hardware zero register (reads always return 0)
	R1 = 1, -- A0 / Return value / Arg 0
	R2 = 2, -- A1 / Arg 1
	R3 = 3, -- A2 / Arg 2
	R4 = 4, -- A3 / Arg 3
	R5 = 5, -- A4 / Arg 4
	R6 = 6, -- A5 / Arg 5
	R7 = 7, -- A6 / Arg 6
	R8 = 8, -- A7 / Syscall number
	R9 = 9, -- S0 (callee-saved)
	R10 = 10, -- S1
	R11 = 11, -- S2
	R12 = 12, -- S3
	R13 = 13, -- S4
	R14 = 14, -- S5
	R15 = 15, -- S6
	R16 = 16, -- S7
	R17 = 17, -- T0 (caller-saved temporaries)
	R18 = 18, -- T1
	R19 = 19, -- T2
	R20 = 20, -- T3
	R21 = 21, -- T4
	R22 = 22, -- T5
	R23 = 23, -- T6
	R24 = 24, -- K0 (kernel reserved)
	R25 = 25, -- K1 (kernel reserved)
	R26 = 26, -- GP (global pointer)
	R27 = 27, -- TP (thread pointer)
	R28 = 28, -- AT (assembler temporary)
	R29 = 29, -- FP (frame pointer)
	R30 = 30, -- LR (link register / return address)
	R31 = 31, -- SP (stack pointer)
}

-- Aliases for convenience
ISA.REG.ZERO = ISA.REG.R0
ISA.REG.A0 = ISA.REG.R1
ISA.REG.A1 = ISA.REG.R2
ISA.REG.A2 = ISA.REG.R3
ISA.REG.A3 = ISA.REG.R4
ISA.REG.A4 = ISA.REG.R5
ISA.REG.A5 = ISA.REG.R6
ISA.REG.A6 = ISA.REG.R7
ISA.REG.A7 = ISA.REG.R8
ISA.REG.S0 = ISA.REG.R9
ISA.REG.S1 = ISA.REG.R10
ISA.REG.S2 = ISA.REG.R11
ISA.REG.S3 = ISA.REG.R12
ISA.REG.GP = ISA.REG.R26
ISA.REG.TP = ISA.REG.R27
ISA.REG.AT = ISA.REG.R28
ISA.REG.FP = ISA.REG.R29
ISA.REG.LR = ISA.REG.R30
ISA.REG.SP = ISA.REG.R31

-- ============================================================
-- OPCODES (7 bits → 128 max)
-- ============================================================
local OP = {}
ISA.OP = OP

-- System / Privileged
OP.NOP = 0x00 -- No operation
OP.HALT = 0x01 -- Halt processor
OP.SYSCALL = 0x02 -- Trap to kernel (INT 0x80)
OP.SYSRET = 0x03 -- Return from syscall
OP.INT = 0x04 -- Software interrupt: INT vector#
OP.IRET = 0x05 -- Return from interrupt, restore flags
OP.CLI = 0x06 -- Disable interrupts
OP.STI = 0x07 -- Enable interrupts
OP.CPUID = 0x08 -- Read CPU info into R1-R4
OP.RDTSC = 0x09 -- Read Time Stamp Counter → R1:R2

-- Data Movement
OP.MOV = 0x0A -- rd = rs1                         R-type
OP.MOVI = 0x0B -- rd = sign_ext(imm16)             I-type
OP.MOVZ = 0x0C -- rd = imm16 << (shift*16), rest=0 I-type [15:14]=shift
OP.MOVK = 0x0D -- rd[(shift*16)+15:shift*16] = imm16 I-type
OP.LUI = 0x0E -- rd = imm20 << 12                 U-type
OP.AUIPC = 0x0F -- rd = PC + (imm20 << 12)          U-type

-- Integer Arithmetic (R-type and I-type pairs)
OP.ADD = 0x10 -- rd = rs1 + rs2                   R
OP.ADDI = 0x11 -- rd = rs1 + simm16                I
OP.SUB = 0x12 -- rd = rs1 - rs2                   R
OP.SUBI = 0x13 -- rd = rs1 - simm16                I
OP.MUL = 0x14 -- rd = (rs1 * rs2)[31:0]           R
OP.MULH = 0x15 -- rd = (rs1 * rs2) >> 32 (signed)  R
OP.MULI = 0x16 -- rd = rs1 * simm16                I
OP.DIV = 0x17 -- rd = rs1 / rs2 (signed)          R
OP.DIVU = 0x18 -- rd = rs1 / rs2 (unsigned)        R
OP.MOD = 0x19 -- rd = rs1 % rs2 (signed)          R
OP.MODU = 0x1A -- rd = rs1 % rs2 (unsigned)        R
OP.NEG = 0x1B -- rd = -rs1                        R
OP.ABS = 0x1C -- rd = |rs1|                       R

-- Bitwise Logic
OP.AND = 0x20 -- rd = rs1 & rs2                   R
OP.ANDI = 0x21 -- rd = rs1 & uimm16                I
OP.OR = 0x22 -- rd = rs1 | rs2                   R
OP.ORI = 0x23 -- rd = rs1 | uimm16                I
OP.XOR = 0x24 -- rd = rs1 ^ rs2                   R
OP.XORI = 0x25 -- rd = rs1 ^ uimm16                I
OP.NOT = 0x26 -- rd = ~rs1                        R
OP.ANDN = 0x27 -- rd = rs1 & ~rs2                  R

-- Shift & Rotate
OP.SHL = 0x28 -- rd = rs1 << rs2[4:0]             R
OP.SHLI = 0x29 -- rd = rs1 << imm5                 I
OP.SHR = 0x2A -- rd = rs1 >> rs2[4:0] (logical)   R
OP.SHRI = 0x2B -- rd = rs1 >> imm5 (logical)       I
OP.SAR = 0x2C -- rd = rs1 >> rs2[4:0] (arith)     R
OP.SARI = 0x2D -- rd = rs1 >> imm5 (arith)         I
OP.ROL = 0x2E -- rd = rotl32(rs1, rs2[4:0])       R
OP.ROR = 0x2F -- rd = rotr32(rs1, rs2[4:0])       R

-- Comparison / Set
OP.CMP = 0x30 -- flags ← rs1 - rs2 (discard result) R
OP.CMPI = 0x31 -- flags ← rs1 - simm16              I
OP.TEST = 0x32 -- flags ← rs1 & rs2 (discard)       R
OP.SLT = 0x33 -- rd = (rs1 < rs2) signed           R
OP.SLTU = 0x34 -- rd = (rs1 < rs2) unsigned         R
OP.SLTI = 0x35 -- rd = (rs1 < simm16) signed        I
OP.SLTIU = 0x36 -- rd = (rs1 < uimm16) unsigned      I
OP.SEQ = 0x37 -- rd = (rs1 == rs2)                 R
OP.SNE = 0x38 -- rd = (rs1 != rs2)                 R

-- Memory Load (M-type: [op|rd|rs1|imm16])
OP.LDB = 0x40 -- rd = sign_ext8(mem[rs1+simm16])
OP.LDBU = 0x41 -- rd = zero_ext8(mem[rs1+simm16])
OP.LDH = 0x42 -- rd = sign_ext16(mem16[rs1+simm16])
OP.LDHU = 0x43 -- rd = zero_ext16(mem16[rs1+simm16])
OP.LDW = 0x44 -- rd = mem32[rs1+simm16]
OP.LDD = 0x45 -- rd = mem64[rs1+simm16] (hi in rd, lo impl.)
OP.LEA = 0x46 -- rd = rs1 + simm16 (no memory access)

-- Memory Store (S-type: [op|rs2|rs1|imm16])
OP.STB = 0x47 -- mem[rs1+simm16] = rs2[7:0]
OP.STH = 0x48 -- mem16[rs1+simm16] = rs2[15:0]
OP.STW = 0x49 -- mem32[rs1+simm16] = rs2
OP.STD = 0x4A -- mem64[rs1+simm16] = rs2

-- Atomic Memory
OP.XCHG = 0x4B -- atomic: tmp=mem[rs1], mem[rs1]=rs2, rd=tmp
OP.CAS = 0x4C -- atomic: if mem[rs1]==rs2 then mem[rs1]=rs3, rd=1 else rd=0

-- Stack Operations
OP.PUSH = 0x4D -- sp -= 4; mem32[sp] = rs1
OP.POP = 0x4E -- rd = mem32[sp]; sp += 4
OP.PUSHA = 0x4F -- push all registers
OP.POPA = 0x50 -- pop all registers

-- Control Flow
OP.JMP = 0x51 -- pc = (pc & 0xFC000000) | (imm26 << 2)  J-type absolute
OP.JMPR = 0x52 -- pc = rs1 + simm16                      I-type
OP.BEQ = 0x53 -- if rs1==rs2: pc += simm16*4            B-type
OP.BNE = 0x54 -- if rs1!=rs2: pc += simm16*4
OP.BLT = 0x55 -- if rs1<rs2 signed: pc += simm16*4
OP.BLTU = 0x56 -- unsigned
OP.BGE = 0x57 -- if rs1>=rs2 signed
OP.BGEU = 0x58 -- unsigned
OP.BGT = 0x59 -- if rs1>rs2
OP.BLE = 0x5A -- if rs1<=rs2
OP.BEQZ = 0x5B -- if rs1==0: pc += simm21              U-type
OP.BNEZ = 0x5C
OP.BLTZ = 0x5D
OP.BGEZ = 0x5E
OP.CALL = 0x5F -- lr=pc+4; pc = target                  J-type
OP.CALLR = 0x60 -- lr=pc+4; pc = rs1                     R-type
OP.RET = 0x61 -- pc = lr

-- Floating Point (IEEE 754 single-precision, stored in GPRs)
OP.FADD = 0x68 -- frd = frs1 + frs2
OP.FSUB = 0x69
OP.FMUL = 0x6A
OP.FDIV = 0x6B
OP.FMOD = 0x6C
OP.FNEG = 0x6D -- frd = -frs1
OP.FABS = 0x6E
OP.FSQRT = 0x6F
OP.FCMP = 0x70 -- set float flags: rs1 vs rs2
OP.ITOF = 0x71 -- frd = float(rs1)  (int → float)
OP.FTOI = 0x72 -- rd  = trunc(frs1) (float → int)
OP.FTOIR = 0x73 -- rd  = round(frs1)
OP.FMOV = 0x74
OP.FSIN = 0x75
OP.FCOS = 0x76
OP.FTAN = 0x77
OP.FLOG = 0x78
OP.FEXP = 0x79
OP.FPOW = 0x7A
OP.FMIN = 0x7B
OP.FMAX = 0x7C

-- Build reverse name table
ISA.OP_NAMES = {}
for name, code in pairs(OP) do
	ISA.OP_NAMES[code] = name
end

-- ============================================================
-- INSTRUCTION TYPES
-- ============================================================
ISA.INSTR_TYPE = {}
local IT = ISA.INSTR_TYPE
-- Maps opcode → format type
local function setRange(t, lo, hi, typ)
	for i = lo, hi do
		t[i] = typ
	end
end
setRange(IT, 0x00, 0x09, "SYS")
setRange(IT, 0x0A, 0x0F, "DATA")
setRange(IT, 0x10, 0x1C, "ALU_R")
setRange(IT, 0x20, 0x38, "ALU_R")
for _, i in ipairs({ 0x11, 0x13, 0x16, 0x21, 0x23, 0x25, 0x29, 0x2B, 0x2D, 0x31, 0x35, 0x36 }) do
	IT[i] = "ALU_I"
end
setRange(IT, 0x40, 0x46, "LOAD")
setRange(IT, 0x47, 0x4C, "STORE")
setRange(IT, 0x4D, 0x50, "STACK")
setRange(IT, 0x51, 0x61, "BRANCH")
setRange(IT, 0x68, 0x7C, "FLOAT")

-- ============================================================
-- FLAGS REGISTER BIT POSITIONS
-- ============================================================
ISA.FLAGS = {
	CARRY = 0, -- bit 0: carry out / borrow
	ZERO = 1, -- bit 1: result was zero
	NEGATIVE = 2, -- bit 2: result was negative (sign bit)
	OVERFLOW = 3, -- bit 3: signed arithmetic overflow
	PARITY = 4, -- bit 4: even parity
	INTERRUPT = 5, -- bit 5: interrupts enabled
	KERNEL = 6, -- bit 6: 1=kernel mode, 0=user mode
	FLOAT_EX = 7, -- bit 7: float exception pending
}
-- Masks
ISA.FLAG_C = bit32.lshift(1, 0)
ISA.FLAG_Z = bit32.lshift(1, 1)
ISA.FLAG_N = bit32.lshift(1, 2)
ISA.FLAG_V = bit32.lshift(1, 3)
ISA.FLAG_P = bit32.lshift(1, 4)
ISA.FLAG_I = bit32.lshift(1, 5)
ISA.FLAG_K = bit32.lshift(1, 6)
ISA.FLAG_F = bit32.lshift(1, 7)

-- ============================================================
-- PHYSICAL MEMORY MAP
-- ============================================================
ISA.MMAP = {
	-- ROM: BIOS firmware (read-only, 1 MB)
	ROM_BASE = 0x00000000,
	ROM_SIZE = 0x00100000,

	-- BIOS Data Area (CMOS, POST data, 64 KB)
	BDA_BASE = 0x00100000,
	BDA_SIZE = 0x00010000,

	-- Main RAM (128 MB default)
	RAM_BASE = 0x00200000,
	RAM_SIZE = 0x08000000, -- 128 MB
	RAM_END = 0x081FFFFF,

	-- Kernel reserved (first 4MB of RAM)
	KERNEL_BASE = 0x00200000,
	KERNEL_SIZE = 0x00400000,

	-- User space begins here
	USER_BASE = 0x00600000,

	-- ---- MMIO Region ----------------------------------------
	MMIO_BASE = 0xC0000000,

	-- GPU framebuffer: 1024×576 × 4 bytes × 2 (double-buffer)
	GPU_FB0 = 0xC0000000, -- front buffer
	GPU_FB1 = 0xC0600000, -- back buffer
	GPU_CTRL = 0xC0C00000, -- GPU control registers
	GPU_SIZE = 0x00C01000,

	-- Keyboard MMIO
	KBD_BASE = 0xC1000000,
	KBD_SIZE = 0x00001000,

	-- Storage controller MMIO
	STOR_BASE = 0xC2000000,
	STOR_SIZE = 0x00010000,

	-- PIT/Timer
	TIMER_BASE = 0xC3000000,
	TIMER_SIZE = 0x00001000,

	-- UART/Serial debug console
	UART_BASE = 0xC4000000,
	UART_SIZE = 0x00001000,

	-- Interrupt controller
	INTC_BASE = 0xC5000000,
	INTC_SIZE = 0x00001000,

	-- RNG
	RNG_BASE = 0xC6000000,
	RNG_SIZE = 0x00001000,

	-- Interrupt Vector Table (at top of 32-bit space)
	IVT_BASE = 0xFFFF0000,
	IVT_SIZE = 0x00010000, -- 256 vectors × 256 bytes each
	IVT_ENTRY_SZ = 0x00000100,
}

-- ============================================================
-- GPU CONTROL REGISTER OFFSETS (relative to GPU_CTRL)
-- ============================================================
ISA.GPU_REG = {
	CTRL = 0x000, -- Control: [0]=enable [1]=vsync [2]=buf_select
	STATUS = 0x004, -- Status:  [0]=vblank [1]=hblank [2]=busy
	WIDTH = 0x008, -- Framebuffer width in pixels
	HEIGHT = 0x00C, -- Framebuffer height
	BPP = 0x010, -- Bits per pixel (32 = RGBA)
	FB_ADDR = 0x014, -- Current framebuffer base address
	FLIP = 0x018, -- Write 1 to flip buffers
	CLEAR_R = 0x01C, -- Clear color R (0-255)
	CLEAR_G = 0x020,
	CLEAR_B = 0x024,
	CLEAR_A = 0x028,
	CMD_FIFO = 0x100, -- Draw command FIFO (hardware-accelerated primitives)
}

-- GPU draw commands (written to CMD_FIFO)
ISA.GPU_CMD = {
	CLEAR = 0x01, -- clear framebuffer with clear color
	RECT = 0x02, -- draw_rect(x,y,w,h,color)
	LINE = 0x03, -- draw_line(x0,y0,x1,y1,color)
	CIRCLE = 0x04, -- draw_circle(cx,cy,r,color)
	BLIT = 0x05, -- blit texture (addr,dx,dy,w,h)
	TEXT = 0x06, -- draw_text(x,y,addr,len,color,bg)
	FLIP_BUFFER = 0x07, -- flip front/back buffer
	SET_SCISSOR = 0x08, -- set scissor rectangle
	FILL_POLY = 0x09, -- fill polygon
}

-- ============================================================
-- INTERRUPT VECTORS
-- ============================================================
ISA.IRQ = {
	TIMER = 0x00, -- Programmable Interval Timer
	KEYBOARD = 0x01, -- Keyboard controller
	STORAGE = 0x02, -- Storage DMA complete
	GPU = 0x03, -- GPU VBlank / command done
	UART = 0x04, -- UART data ready
	RTC = 0x05, -- Real-time clock
}
ISA.EX = { -- CPU Exception vectors (0x10+)
	DIV_ZERO = 0x10,
	INVALID_OP = 0x11,
	PAGE_FAULT = 0x12,
	STACK_FAULT = 0x13,
	GP_FAULT = 0x14,
	ALIGNMENT = 0x15,
	FLOAT_EX = 0x16,
	BREAKPOINT = 0x17,
	OVERFLOW = 0x18,
	DOUBLE_FAULT = 0x19,
}
ISA.SOFT_INT = {
	SYSCALL = 0x80,
	DEBUG = 0x81,
	LUAU_VM = 0x82, -- Enter LuauVM co-processor mode
}

-- ============================================================
-- SYSCALL TABLE
-- ============================================================
ISA.SYS = {
	-- Process management
	EXIT = 0, -- exit(int status)
	FORK = 1, -- fork() → pid_t
	EXEC = 2, -- execve(path, argv[], envp[])
	WAIT = 3, -- waitpid(pid, *status, flags)
	GETPID = 4,
	GETPPID = 5,
	KILL = 6, -- kill(pid, sig)
	SLEEP = 7, -- sleep(ms)
	YIELD = 8, -- yield scheduler
	NICE = 9, -- nice(increment) – adjust priority
	GETUID = 10,
	SETUID = 11,

	-- File I/O
	READ = 20, -- read(fd, buf, len)
	WRITE = 21, -- write(fd, buf, len)
	OPEN = 22, -- open(path, flags, mode)
	CLOSE = 23,
	SEEK = 24, -- lseek(fd, offset, whence)
	IOCTL = 25,
	DUP = 26,
	DUP2 = 27,
	PIPE = 28,
	SELECT = 29,
	POLL = 30,
	FSYNC = 31,
	TRUNCATE = 32,

	-- Filesystem
	MKDIR = 40,
	RMDIR = 41,
	UNLINK = 42,
	RENAME = 43,
	LINK = 44,
	SYMLINK = 45,
	STAT = 46,
	FSTAT = 47,
	READDIR = 48,
	GETCWD = 49,
	CHDIR = 50,
	CHMOD = 51,
	CHOWN = 52,

	-- Memory
	MMAP = 60,
	MUNMAP = 61,
	MPROTECT = 62,
	BRK = 63,

	-- Time
	TIME = 70,
	CLOCK = 71,

	-- System info
	UNAME = 80,
	SYSINFO = 81,

	-- IPC
	PIPE2 = 90,
	MSGGET = 91,
	MSGSND = 92,
	MSGRCV = 93,
	SHMGET = 94,
	SHMAT = 95,
	SHMDT = 96,
	SEMGET = 97,
	SEMOP = 98,

	-- Networking (future)
	SOCKET = 100,
	CONNECT = 101,
	SEND = 102,
	RECV = 103,
	BIND = 104,
	LISTEN = 105,
	ACCEPT = 106,

	-- LuauVM co-processor
	LUAU_EXEC = 200, -- Run luau bytecode (buf, len) in LuauVM
	LUAU_COMPILE = 201, -- Compile source string → bytecode
	LUAU_LOAD = 202, -- Load module from VFS path
}

-- Open flags
ISA.O_FLAGS = {
	RDONLY = 0x000,
	WRONLY = 0x001,
	RDWR = 0x002,
	CREAT = 0x040,
	EXCL = 0x080,
	TRUNC = 0x200,
	APPEND = 0x400,
	NONBLOCK = 0x800,
}

-- MMAP prot flags
ISA.PROT = { NONE = 0, READ = 1, WRITE = 2, EXEC = 4 }
ISA.MAP = { PRIVATE = 0x02, SHARED = 0x01, ANON = 0x20 }

-- ============================================================
-- INSTRUCTION ENCODING HELPERS
-- ============================================================

-- R-type: [op:7][rd:5][rs1:5][rs2:5][func:10]
function ISA.encR(op, rd, rs1, rs2, func)
	return bit32.bor(
		bit32.lshift(bit32.band(op, 0x7F), 25),
		bit32.lshift(bit32.band(rd, 0x1F), 20),
		bit32.lshift(bit32.band(rs1, 0x1F), 15),
		bit32.lshift(bit32.band(rs2, 0x1F), 10),
		bit32.band(func or 0, 0x3FF)
	)
end

-- I-type: [op:7][rd:5][rs1:5][imm15:15]  (imm may be negative)
function ISA.encI(op, rd, rs1, imm)
	local uimm = bit32.band(imm, 0x7FFF)
	return bit32.bor(
		bit32.lshift(bit32.band(op, 0x7F), 25),
		bit32.lshift(bit32.band(rd, 0x1F), 20),
		bit32.lshift(bit32.band(rs1, 0x1F), 15),
		uimm
	)
end

-- S-type (store): [op:7][rs2:5][rs1:5][imm15:15]
function ISA.encS(op, rs2, rs1, imm)
	local uimm = bit32.band(imm, 0x7FFF)
	return bit32.bor(
		bit32.lshift(bit32.band(op, 0x7F), 25),
		bit32.lshift(bit32.band(rs2, 0x1F), 20),
		bit32.lshift(bit32.band(rs1, 0x1F), 15),
		uimm
	)
end

-- B-type (branch): [op:7][rs1:5][rs2:5][imm15:15]
function ISA.encB(op, rs1, rs2, imm)
	local uimm = bit32.band(imm, 0x7FFF)
	return bit32.bor(
		bit32.lshift(bit32.band(op, 0x7F), 25),
		bit32.lshift(bit32.band(rs1, 0x1F), 20),
		bit32.lshift(bit32.band(rs2, 0x1F), 15),
		uimm
	)
end

-- J-type: [op:7][imm25:25]
function ISA.encJ(op, imm)
	local uimm = bit32.band(imm, 0x1FFFFFF)
	return bit32.bor(bit32.lshift(bit32.band(op, 0x7F), 25), uimm)
end

-- U-type: [op:7][rd:5][imm20:20]
function ISA.encU(op, rd, imm20)
	local uimm = bit32.band(imm20, 0xFFFFF)
	return bit32.bor(bit32.lshift(bit32.band(op, 0x7F), 25), bit32.lshift(bit32.band(rd, 0x1F), 20), uimm)
end

-- Decode any 32-bit instruction into fields
function ISA.decode(instr)
	local op = bit32.rshift(instr, 25)
	local rd = bit32.band(bit32.rshift(instr, 20), 0x1F)
	local rs1 = bit32.band(bit32.rshift(instr, 15), 0x1F)
	local rs2 = bit32.band(bit32.rshift(instr, 10), 0x1F)
	local func = bit32.band(instr, 0x3FF)

	local imm15 = bit32.band(instr, 0x7FFF)
	local imm16 = bit32.band(instr, 0xFFFF)
	local imm20 = bit32.band(instr, 0xFFFFF)
	local imm21 = bit32.band(instr, 0x1FFFFF)
	local imm25 = bit32.band(instr, 0x1FFFFFF)

	-- Sign-extend helpers
	local function sext(val, bits)
		local msb = bit32.lshift(1, bits - 1)
		if bit32.band(val, msb) ~= 0 then
			return val - bit32.lshift(1, bits)
		end
		return val
	end

	return {
		op = op,
		opname = ISA.OP_NAMES[op] or ("UNK_" .. string.format("%02X", op)),
		rd = rd,
		rs1 = rs1,
		rs2 = rs2,
		func = func,
		imm15 = imm15,
		simm15 = sext(imm15, 15),
		imm16 = imm16, -- unsigned
		simm16 = sext(imm16, 16),
		imm20 = imm20,
		simm20 = sext(imm20, 20),
		imm21 = imm21,
		simm21 = sext(imm21, 21),
		imm25 = imm25,
		simm25 = sext(imm25, 25),
		raw = instr,
	}
end

-- ============================================================
-- CPU SPECIFICATIONS
-- ============================================================
ISA.SPEC = {
	NAME = "RISC-64",
	REVISION = "1.2",
	WORD_BITS = 32, -- native word (Luau bit32 limit)
	ADDR_BITS = 32, -- physical address width
	GPR_COUNT = 32,
	CACHE_L1_I_KB = 32,
	CACHE_L1_D_KB = 32,
	CACHE_L2_KB = 256,
	CACHE_L3_MB = 4,
	FREQ_MHZ = 4000, -- 4 GHz simulated
	PIPELINE_DEPTH = 5,
	BRANCH_PREDICTOR = "2bit-sat", -- 2-bit saturating counter
	OUT_OF_ORDER = false,
	SUPERSCALAR = false,
	SIMD_WIDTH = 128, -- planned
	NUM_CORES = 4,
	VENDOR_ID = 0xABCD1234,
}

-- ============================================================
-- FILESYSTEM CONSTANTS
-- ============================================================
ISA.FS = {
	SECTOR_SIZE = 512,
	CLUSTER_SIZE = 4096, -- 8 sectors per cluster
	MAX_FILENAME = 255,
	MAX_PATH = 4096,

	-- inode types
	TYPE_FILE = 0x1,
	TYPE_DIR = 0x2,
	TYPE_LINK = 0x3,
	TYPE_DEVICE = 0x4,
	TYPE_PIPE = 0x5,
	TYPE_SOCKET = 0x6,

	-- permissions
	PERM_EXEC = 0x001,
	PERM_WRITE = 0x002,
	PERM_READ = 0x004,
	-- owner / group / other
	PERM_OEXEC = 0x001,
	PERM_OWRITE = 0x002,
	PERM_OREAD = 0x004,
	PERM_GEXEC = 0x008,
	PERM_GWRITE = 0x010,
	PERM_GREAD = 0x020,
	PERM_UEXEC = 0x040,
	PERM_UWRITE = 0x080,
	PERM_UREAD = 0x100,
	PERM_SETUID = 0x800,
	PERM_SETGID = 0x400,
	PERM_STICKY = 0x200,

	-- Standard permissions shorthand
	PERM_755 = 0x1ED,
	PERM_644 = 0x1A4,
	PERM_777 = 0x1FF,
}

return ISA
