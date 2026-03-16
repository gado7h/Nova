--!optimize 2
--!native
--[[
    Virtual Hard Disk (HDD) + VCFS Filesystem
    ==========================================
    • 256 MB virtual disk, 512-byte sectors, 4KB blocks
    • VCFS (Virtual Computer FileSystem) — ext2-inspired inode FS
    • Roblox DataStore persistence (chunked base64 encoding)
    • On player join: DataStore → sector buffers (lazy loaded)
    • On save: dirty sectors → DataStore chunks
    • Full inode-based VFS: open/read/write/mkdir/readdir
    • Hard links, symlinks, permissions, timestamps
]]

local ISA = require(script.Parent["ISA"])
local MMAP = ISA.MMAP

-- ============================================================
-- CONSTANTS
-- ============================================================
local SECTOR_SIZE = 512
local BLOCK_SIZE = 4096
local SECTORS_PER_BLOCK = BLOCK_SIZE / SECTOR_SIZE -- 8

local DISK_SIZE_MB = 256
local TOTAL_SECTORS = DISK_SIZE_MB * 1024 * 1024 / SECTOR_SIZE -- 524288
local TOTAL_BLOCKS = DISK_SIZE_MB * 1024 * 1024 / BLOCK_SIZE -- 65536

-- DataStore: save 12 sectors (~6 KB) per key (base64 overhead fits 4MB limit)
local DS_SECTORS_PER_KEY = 12
local DS_KEY_PREFIX = "VCFS1_"

-- Filesystem layout (block numbers)
local BLK_BOOT = 0 -- reserved boot sector
local BLK_SUPER = 1 -- superblock
local BLK_GDT = 2 -- group descriptor table (2 blocks)
local BLK_BMAP = 4 -- block bitmap  (1 block = 32768 bits → 32768 blocks covered)
local BLK_IMAP = 5 -- inode bitmap
local BLK_ITABLE = 6 -- inode table start (128-byte inodes, 32 per block)
local INODE_TABLE_BLOCKS = 256 -- 256 × 32 = 8192 inodes max
local BLK_DATA = BLK_ITABLE + INODE_TABLE_BLOCKS -- first data block

local INODE_SIZE = 128
local INODES_PER_BLK = BLOCK_SIZE / INODE_SIZE -- 32
local MAX_INODES = INODE_TABLE_BLOCKS * INODES_PER_BLK -- 8192

-- Reserved inodes
local INO_INVALID = 0
local INO_ROOT = 1 -- root directory "/"
local INO_LOST = 2 -- lost+found

-- Inode field offsets (bytes within 128-byte inode)
local I_MODE = 0 -- u16 file type + permissions
local I_UID = 2 -- u16 owner uid
local I_SZ_LO = 4 -- u32 file size low
local I_ATIME = 8 -- u32 last access
local I_CTIME = 12 -- u32 creation time
local I_MTIME = 16 -- u32 last modification
local I_DTIME = 20 -- u32 deletion time
local I_GID = 24 -- u16 group id
local I_LINKS = 26 -- u16 hard link count
local I_BLOCKS = 28 -- u32 blocks allocated (512-byte units)
local I_FLAGS = 32 -- u32 flags
local I_DIRECT = 40 -- u32[12] direct block pointers (40..88)
local I_SIND = 88 -- u32 single indirect
local I_DIND = 92 -- u32 double indirect
local I_TIND = 96 -- u32 triple indirect
-- total = 100 bytes; rest padding to 128

-- File mode bits
local S_IFMT = 0xF000
local S_IFREG = 0x8000 -- regular file
local S_IFDIR = 0x4000 -- directory
local S_IFLNK = 0xA000 -- symbolic link
local S_IFIFO = 0x1000 -- FIFO
local S_IFCHR = 0x2000 -- char device
local S_IFBLK = 0x6000 -- block device

-- Dir entry constants
local DE_INO = 0 -- u32 inode
local DE_REC = 4 -- u16 record length
local DE_NLEN = 6 -- u8  name length
local DE_TYPE = 7 -- u8  file type
local DE_NAME = 8 -- char[] name (padded to 4-byte boundary)

local FT_UNKNOWN = 0
local FT_REG = 1
local FT_DIR = 2
local FT_LNK = 7

-- Superblock offsets
local SB_SIZE = 1024 -- 2 sectors
local SB = {
	INO_COUNT = 0, -- u32 total inodes
	BLK_COUNT = 4, -- u32 total blocks
	FREE_BLKS = 12, -- u32 free block count
	FREE_INOS = 16, -- u32 free inode count
	FIRST_DATA = 20, -- u32 first data block
	LOG_BLK_SZ = 24, -- u32 log2(block_size) - 10
	MAGIC = 56, -- u16 0xEF53
	STATE = 58, -- u16 1=clean 2=errors
	VOL_NAME = 120, -- char[16]
	LAST_MNT = 136, -- u32 last mount time
	MNT_COUNT = 148, -- u16 mount count
}

-- ============================================================
-- HDD OBJECT
-- ============================================================
local HDD = {}
HDD.__index = HDD

function HDD.new(memory, base64, dataStore, playerId)
	local self = setmetatable({}, HDD)
	self.memory = memory
	self.base64 = base64
	self.dataStore = dataStore -- DataStoreService datastore object
	self.playerId = tostring(playerId or "global")

	-- Sector storage: sparse table — only loaded sectors live here
	self.sectors = {} -- [lba] = buffer(512)
	self.dirtySet = {} -- [lba] = true
	self.loadedSet = {} -- [lba] = true

	-- MMIO registers
	self.reg_lba = 0
	self.reg_count = 1
	self.reg_buf = 0
	self.reg_cmd = 0
	self.reg_status = 0 -- 0=ready 1=busy 2=error 4=done
	self.reg_error = 0
	self.reg_irqen = 0

	-- DMA completion callback (set by Motherboard)
	self.onDMADone = nil

	-- Stats
	self.stats = { reads = 0, writes = 0, dmaOps = 0 }

	-- Register MMIO
	memory:registerMMIO(MMAP.STOR_BASE, MMAP.STOR_SIZE, function(a)
		return self:mmioRead(a)
	end, function(a, v)
		self:mmioWrite(a, v)
	end, "HDD")
	return self
end

-- ============================================================
-- SECTOR PRIMITIVES
-- ============================================================
function HDD:_ensureSector(lba)
	if not self.sectors[lba] then
		self.sectors[lba] = buffer.create(SECTOR_SIZE)
		self.loadedSet[lba] = true
	end
	return self.sectors[lba]
end

function HDD:readSectorRaw(lba)
	self.stats.reads += 1
	return self:_ensureSector(lba)
end

function HDD:writeSectorRaw(lba, src, srcOff, len)
	self.stats.writes += 1
	srcOff = srcOff or 0
	len = len or SECTOR_SIZE
	local sec = self:_ensureSector(lba)
	buffer.copy(sec, 0, src, srcOff, math.min(len, SECTOR_SIZE))
	self.dirtySet[lba] = true
end

-- ============================================================
-- BLOCK PRIMITIVES (filesystem layer uses blocks)
-- ============================================================
function HDD:readBlock(blkNo, dstBuf, dstOff)
	dstOff = dstOff or 0
	dstBuf = dstBuf or buffer.create(BLOCK_SIZE)
	local lba = blkNo * SECTORS_PER_BLOCK
	for i = 0, SECTORS_PER_BLOCK - 1 do
		local sec = self:readSectorRaw(lba + i)
		buffer.copy(dstBuf, dstOff + i * SECTOR_SIZE, sec, 0, SECTOR_SIZE)
	end
	return dstBuf
end

function HDD:writeBlock(blkNo, srcBuf, srcOff)
	srcOff = srcOff or 0
	local lba = blkNo * SECTORS_PER_BLOCK
	for i = 0, SECTORS_PER_BLOCK - 1 do
		local sec = self:_ensureSector(lba + i)
		buffer.copy(sec, 0, srcBuf, srcOff + i * SECTOR_SIZE, SECTOR_SIZE)
		self.dirtySet[lba + i] = true
	end
end

function HDD:readBlockWord(blkNo, byteOff)
	local lba = blkNo * SECTORS_PER_BLOCK + math.floor(byteOff / SECTOR_SIZE)
	local sec = self:readSectorRaw(lba)
	local secOff = byteOff % SECTOR_SIZE
	if secOff + 4 <= SECTOR_SIZE then
		return buffer.readu32(sec, secOff)
	end
	-- Cross-sector word (rare)
	local lo = buffer.readu8(sec, secOff)
	local sec2 = self:readSectorRaw(lba + 1)
	return bit32.bor(
		lo,
		bit32.lshift(buffer.readu8(sec2, 0), 8),
		bit32.lshift(buffer.readu8(sec2, 1), 16),
		bit32.lshift(buffer.readu8(sec2, 2), 24)
	)
end

function HDD:writeBlockWord(blkNo, byteOff, val)
	local lba = blkNo * SECTORS_PER_BLOCK + math.floor(byteOff / SECTOR_SIZE)
	local sec = self:_ensureSector(lba)
	local secOff = byteOff % SECTOR_SIZE
	if secOff + 4 <= SECTOR_SIZE then
		buffer.writeu32(sec, secOff, val)
		self.dirtySet[lba] = true
		return
	end
	buffer.writeu8(sec, secOff, bit32.band(val, 0xFF))
	self.dirtySet[lba] = true
	local sec2 = self:_ensureSector(lba + 1)
	buffer.writeu8(sec2, 0, bit32.band(bit32.rshift(val, 8), 0xFF))
	buffer.writeu8(sec2, 1, bit32.band(bit32.rshift(val, 16), 0xFF))
	buffer.writeu8(sec2, 2, bit32.band(bit32.rshift(val, 24), 0xFF))
	self.dirtySet[lba + 1] = true
end

function HDD:readBlockByte(blkNo, byteOff)
	local lba = blkNo * SECTORS_PER_BLOCK + math.floor(byteOff / SECTOR_SIZE)
	return buffer.readu8(self:readSectorRaw(lba), byteOff % SECTOR_SIZE)
end

function HDD:writeBlockByte(blkNo, byteOff, val)
	local lba = blkNo * SECTORS_PER_BLOCK + math.floor(byteOff / SECTOR_SIZE)
	local sec = self:_ensureSector(lba)
	buffer.writeu8(sec, byteOff % SECTOR_SIZE, bit32.band(val, 0xFF))
	self.dirtySet[lba] = true
end

-- ============================================================
-- SUPERBLOCK
-- ============================================================
function HDD:readSuperblock()
	-- Superblock at byte offset 1024 (block 1, sector 2, byte 0)
	local lba = BLK_SUPER * SECTORS_PER_BLOCK
	local sec0 = self:readSectorRaw(lba)
	local sec1 = self:readSectorRaw(lba + 1)
	local sb = buffer.create(SB_SIZE)
	buffer.copy(sb, 0, sec0, 0, SECTOR_SIZE)
	buffer.copy(sb, SECTOR_SIZE, sec1, 0, SECTOR_SIZE)
	return sb
end

function HDD:writeSuperblock(sb)
	local lba = BLK_SUPER * SECTORS_PER_BLOCK
	local sec0 = self:_ensureSector(lba)
	local sec1 = self:_ensureSector(lba + 1)
	buffer.copy(sec0, 0, sb, 0, SECTOR_SIZE)
	buffer.copy(sec1, 0, sb, SECTOR_SIZE, SECTOR_SIZE)
	self.dirtySet[lba] = true
	self.dirtySet[lba + 1] = true
end

function HDD:getSBField(sb, field)
	return buffer.readu32(sb, field)
end

function HDD:setSBField(sb, field, val)
	buffer.writeu32(sb, field, val)
end

-- ============================================================
-- BITMAP OPERATIONS
-- ============================================================
function HDD:bitmapGet(bitmapBlk, bitIndex)
	local byteOff = math.floor(bitIndex / 8)
	local bitPos = bitIndex % 8
	local b = self:readBlockByte(bitmapBlk, byteOff)
	return bit32.band(bit32.rshift(b, bitPos), 1) == 1
end

function HDD:bitmapSet(bitmapBlk, bitIndex, val)
	local byteOff = math.floor(bitIndex / 8)
	local bitPos = bitIndex % 8
	local lba = bitmapBlk * SECTORS_PER_BLOCK + math.floor(byteOff / SECTOR_SIZE)
	local sec = self:_ensureSector(lba)
	local secOff = byteOff % SECTOR_SIZE
	local b = buffer.readu8(sec, secOff)
	if val then
		b = bit32.bor(b, bit32.lshift(1, bitPos))
	else
		b = bit32.band(b, bit32.bnot(bit32.lshift(1, bitPos)))
	end
	buffer.writeu8(sec, secOff, b)
	self.dirtySet[lba] = true
end

function HDD:bitmapFindFree(bitmapBlk, maxBits)
	for i = 0, maxBits - 1 do
		if not self:bitmapGet(bitmapBlk, i) then
			return i
		end
	end
	return nil
end

-- ============================================================
-- BLOCK ALLOCATOR
-- ============================================================
function HDD:allocBlock()
	local freeBlk = self:bitmapFindFree(BLK_BMAP, TOTAL_BLOCKS)
	if not freeBlk then
		return nil
	end
	self:bitmapSet(BLK_BMAP, freeBlk, true)
	-- Update superblock free count
	local sb = self:readSuperblock()
	local fc = self:getSBField(sb, SB.FREE_BLKS)
	self:setSBField(sb, SB.FREE_BLKS, fc - 1)
	self:writeSuperblock(sb)
	-- Zero the new block
	local zeroBuf = buffer.create(BLOCK_SIZE)
	self:writeBlock(freeBlk, zeroBuf)
	return freeBlk
end

function HDD:freeBlock(blkNo)
	self:bitmapSet(BLK_BMAP, blkNo, false)
	local sb = self:readSuperblock()
	local fc = self:getSBField(sb, SB.FREE_BLKS)
	self:setSBField(sb, SB.FREE_BLKS, fc + 1)
	self:writeSuperblock(sb)
end

-- ============================================================
-- INODE OPERATIONS
-- ============================================================
function HDD:_inodeLocation(ino)
	-- ino is 1-based
	local idx = ino - 1
	local blkNo = BLK_ITABLE + math.floor(idx / INODES_PER_BLK)
	local byteOff = (idx % INODES_PER_BLK) * INODE_SIZE
	return blkNo, byteOff
end

function HDD:readInode(ino)
	local blk, off = self:_inodeLocation(ino)
	local buf = buffer.create(INODE_SIZE)
	-- Read 128 bytes from block
	for i = 0, INODE_SIZE - 1 do
		buffer.writeu8(buf, i, self:readBlockByte(blk, off + i))
	end
	return buf
end

function HDD:writeInode(ino, buf)
	local blk, off = self:_inodeLocation(ino)
	for i = 0, INODE_SIZE - 1 do
		self:writeBlockByte(blk, off + i, buffer.readu8(buf, i))
	end
end

function HDD:allocInode()
	local freeIno = self:bitmapFindFree(BLK_IMAP, MAX_INODES)
	if not freeIno then
		return nil
	end
	local ino = freeIno + 1 -- 1-based
	self:bitmapSet(BLK_IMAP, freeIno, true)
	local sb = self:readSuperblock()
	local fi = self:getSBField(sb, SB.FREE_INOS)
	self:setSBField(sb, SB.FREE_INOS, fi - 1)
	self:writeSuperblock(sb)
	-- Zero inode
	local buf = buffer.create(INODE_SIZE)
	self:writeInode(ino, buf)
	return ino
end

function HDD:freeInode(ino)
	self:bitmapSet(BLK_IMAP, ino - 1, false)
	local sb = self:readSuperblock()
	local fi = self:getSBField(sb, SB.FREE_INOS)
	self:setSBField(sb, SB.FREE_INOS, fi + 1)
	self:writeSuperblock(sb)
end

-- Inode field helpers
function HDD:inoGet(buf, field)
	return buffer.readu32(buf, field)
end
function HDD:inoSet(buf, field, val)
	buffer.writeu32(buf, field, val)
end
function HDD:inoGetU16(buf, field)
	return buffer.readu16(buf, field)
end
function HDD:inoSetU16(buf, field, val)
	buffer.writeu16(buf, field, val)
end

function HDD:inoGetDirect(buf, idx)
	return buffer.readu32(buf, I_DIRECT + idx * 4)
end
function HDD:inoSetDirect(buf, idx, blk)
	buffer.writeu32(buf, I_DIRECT + idx * 4, blk)
end

-- Resolve block number for file offset (handles indirect blocks)
function HDD:resolveFileBlock(inoBuf, fileBlkIdx)
	if fileBlkIdx < 12 then
		return self:inoGetDirect(inoBuf, fileBlkIdx)
	end
	-- Single indirect
	local single = buffer.readu32(inoBuf, I_SIND)
	if single == 0 then
		return 0
	end
	local idx1 = fileBlkIdx - 12
	local ptrs = BLOCK_SIZE / 4 -- 1024 pointers per block
	if idx1 < ptrs then
		return self:readBlockWord(single, idx1 * 4)
	end
	-- Double indirect
	local dbl = buffer.readu32(inoBuf, I_DIND)
	if dbl == 0 then
		return 0
	end
	local idx2 = idx1 - ptrs
	local l1Blk = self:readBlockWord(dbl, math.floor(idx2 / ptrs) * 4)
	if l1Blk == 0 then
		return 0
	end
	return self:readBlockWord(l1Blk, (idx2 % ptrs) * 4)
end

-- Allocate and map a new block for file block index
function HDD:allocFileBlock(ino, inoBuf, fileBlkIdx)
	local newBlk = self:allocBlock()
	if not newBlk then
		return nil
	end

	if fileBlkIdx < 12 then
		self:inoSetDirect(inoBuf, fileBlkIdx, newBlk)
	else
		local ptrs = BLOCK_SIZE / 4
		local idx1 = fileBlkIdx - 12
		if idx1 < ptrs then
			local single = buffer.readu32(inoBuf, I_SIND)
			if single == 0 then
				single = self:allocBlock()
				buffer.writeu32(inoBuf, I_SIND, single)
			end
			self:writeBlockWord(single, idx1 * 4, newBlk)
		else
			local dbl = buffer.readu32(inoBuf, I_DIND)
			if dbl == 0 then
				dbl = self:allocBlock()
				buffer.writeu32(inoBuf, I_DIND, dbl)
			end
			local idx2 = idx1 - ptrs
			local l1Idx = math.floor(idx2 / ptrs)
			local l1Blk = self:readBlockWord(dbl, l1Idx * 4)
			if l1Blk == 0 then
				l1Blk = self:allocBlock()
				self:writeBlockWord(dbl, l1Idx * 4, l1Blk)
			end
			self:writeBlockWord(l1Blk, (idx2 % ptrs) * 4, newBlk)
		end
	end

	-- Update block count in inode (512-byte units)
	local bc = self:inoGet(inoBuf, I_BLOCKS)
	self:inoSet(inoBuf, I_BLOCKS, bc + SECTORS_PER_BLOCK)
	self:writeInode(ino, inoBuf)
	return newBlk
end

-- ============================================================
-- FILE I/O
-- ============================================================
function HDD:readFile(ino, offset, length)
	local inoBuf = self:readInode(ino)
	local fileSize = self:inoGet(inoBuf, I_SZ_LO)
	if offset >= fileSize then
		return ""
	end
	length = math.min(length, fileSize - offset)

	local out = buffer.create(length)
	local outOff = 0
	local remaining = length

	while remaining > 0 do
		local fileBlkIdx = math.floor(offset / BLOCK_SIZE)
		local blkOff = offset % BLOCK_SIZE
		local blkNo = self:resolveFileBlock(inoBuf, fileBlkIdx)
		local canRead = math.min(remaining, BLOCK_SIZE - blkOff)

		if blkNo ~= 0 then
			for i = 0, canRead - 1 do
				buffer.writeu8(out, outOff + i, self:readBlockByte(blkNo, blkOff + i))
			end
		end
		-- else: sparse block, remains zero

		outOff += canRead
		offset += canRead
		remaining -= canRead
	end

	return buffer.tostring(out)
end

function HDD:writeFile(ino, offset, data)
	local inoBuf = self:readInode(ino)
	local len = #data
	local written = 0

	while written < len do
		local fileBlkIdx = math.floor(offset / BLOCK_SIZE)
		local blkOff = offset % BLOCK_SIZE
		local blkNo = self:resolveFileBlock(inoBuf, fileBlkIdx)
		if blkNo == 0 then
			blkNo = self:allocFileBlock(ino, inoBuf, fileBlkIdx)
			if not blkNo then
				break
			end
		end
		local canWrite = math.min(len - written, BLOCK_SIZE - blkOff)
		for i = 0, canWrite - 1 do
			self:writeBlockByte(blkNo, blkOff + i, data:byte(written + i + 1))
		end
		written += canWrite
		offset += canWrite
	end

	-- Update size if needed
	local newSize = self:inoGet(inoBuf, I_SZ_LO)
	if offset > newSize then
		self:inoSet(inoBuf, I_SZ_LO, offset)
		self:writeInode(ino, inoBuf)
	end
	return written
end

-- Write a string to a file, truncating first
function HDD:writeFileStr(ino, data)
	local inoBuf = self:readInode(ino)
	self:inoSet(inoBuf, I_SZ_LO, 0)
	self:inoSet(inoBuf, I_BLOCKS, 0)
	for i = 0, 11 do
		self:inoSetDirect(inoBuf, i, 0)
	end
	buffer.writeu32(inoBuf, I_SIND, 0)
	buffer.writeu32(inoBuf, I_DIND, 0)
	self:writeInode(ino, inoBuf)
	return self:writeFile(ino, 0, data)
end

-- ============================================================
-- DIRECTORY OPERATIONS
-- ============================================================
-- Read all directory entries from dir inode
function HDD:readDir(dirIno)
	local inoBuf = self:readInode(dirIno)
	local mode = self:inoGetU16(inoBuf, I_MODE)
	if bit32.band(mode, S_IFMT) ~= S_IFDIR then
		return nil, "not_dir"
	end

	local size = self:inoGet(inoBuf, I_SZ_LO)
	local data = self:readFile(dirIno, 0, size)
	local entries = {}
	local pos = 1

	while pos <= #data do
		if pos + 7 > #data then
			break
		end
		local ino = string.unpack("<I4", data, pos)
		local recLen = string.unpack("<I2", data, pos + 4)
		local nLen = data:byte(pos + 6)
		local fType = data:byte(pos + 7)
		if recLen < 8 then
			break
		end
		if ino ~= 0 then
			local name = data:sub(pos + 8, pos + 8 + nLen - 1)
			entries[#entries + 1] = {
				ino = ino,
				name = name,
				type = fType,
				recLen = recLen,
			}
		end
		pos += recLen
	end
	return entries
end

function HDD:lookupDir(dirIno, name)
	local entries, err = self:readDir(dirIno)
	if not entries then
		return nil, err
	end
	for _, e in ipairs(entries) do
		if e.name == name then
			return e.ino, e.type
		end
	end
	return nil, "not_found"
end

-- Append a directory entry
function HDD:addDirEntry(dirIno, childIno, name, ftype)
	local inoBuf = self:readInode(dirIno)
	local size = self:inoGet(inoBuf, I_SZ_LO)
	local nLen = #name
	-- Pad record to 4-byte boundary
	local recLen = math.ceil((8 + nLen) / 4) * 4

	local de = buffer.create(recLen)
	buffer.writeu32(de, DE_INO, childIno)
	buffer.writeu16(de, DE_REC, recLen)
	buffer.writeu8(de, DE_NLEN, nLen)
	buffer.writeu8(de, DE_TYPE, ftype or FT_UNKNOWN)
	for i = 0, nLen - 1 do
		buffer.writeu8(de, DE_NAME + i, name:byte(i + 1))
	end
	self:writeFile(dirIno, size, buffer.tostring(de))
end

-- Remove a directory entry (mark inode = 0)
function HDD:removeDirEntry(dirIno, name)
	local inoBuf = self:readInode(dirIno)
	local size = self:inoGet(inoBuf, I_SZ_LO)
	local data = self:readFile(dirIno, 0, size)
	local pos = 1
	while pos <= #data do
		if pos + 7 > #data then
			break
		end
		local ino = string.unpack("<I4", data, pos)
		local recLen = string.unpack("<I2", data, pos + 4)
		local nLen = data:byte(pos + 6)
		if recLen < 8 then
			break
		end
		local entName = data:sub(pos + 8, pos + 8 + nLen - 1)
		if entName == name then
			-- Zero the inode field to mark as deleted
			self:writeFile(dirIno, pos - 1, string.pack("<I4", 0))
			return true
		end
		pos += recLen
	end
	return false, "not_found"
end

-- Resolve an absolute path to inode number
function HDD:resolvePath(path, baseIno)
	baseIno = baseIno or INO_ROOT
	if path == "/" then
		return INO_ROOT
	end
	if path:sub(1, 1) == "/" then
		baseIno = INO_ROOT
		path = path:sub(2)
	end

	local curIno = baseIno
	for part in path:gmatch("[^/]+") do
		if part == "." then
			-- stay
		elseif part == ".." then
			local ino = self:lookupDir(curIno, "..")
			if ino then
				curIno = ino
			end
		else
			local ino, err = self:lookupDir(curIno, part)
			if not ino then
				return nil, "not_found: " .. part
			end
			curIno = ino
		end
	end
	return curIno
end

-- ============================================================
-- HIGH-LEVEL FS API (used by kernel VFS layer)
-- ============================================================
-- Create a new file; returns inode number
function HDD:createFile(dirIno, name, mode, uid, gid)
	local ino = self:allocInode()
	if not ino then
		return nil, "no_inodes"
	end

	local buf = buffer.create(INODE_SIZE)
	self:inoSetU16(buf, I_MODE, bit32.bor(S_IFREG, mode or ISA.FS.PERM_644))
	self:inoSetU16(buf, I_UID, uid or 0)
	self:inoSetU16(buf, I_GID, gid or 0)
	self:inoSetU16(buf, I_LINKS, 1)
	local t = os.time()
	self:inoSet(buf, I_CTIME, t)
	self:inoSet(buf, I_MTIME, t)
	self:inoSet(buf, I_ATIME, t)
	self:writeInode(ino, buf)
	self:addDirEntry(dirIno, ino, name, FT_REG)
	return ino
end

-- Create a directory
function HDD:createDir(parentIno, name, mode, uid, gid)
	local ino = self:allocInode()
	if not ino then
		return nil, "no_inodes"
	end

	local buf = buffer.create(INODE_SIZE)
	self:inoSetU16(buf, I_MODE, bit32.bor(S_IFDIR, mode or ISA.FS.PERM_755))
	self:inoSetU16(buf, I_UID, uid or 0)
	self:inoSetU16(buf, I_GID, gid or 0)
	self:inoSetU16(buf, I_LINKS, 2)
	local t = os.time()
	self:inoSet(buf, I_CTIME, t)
	self:inoSet(buf, I_MTIME, t)
	self:inoSet(buf, I_ATIME, t)
	self:writeInode(ino, buf)

	-- Create . and ..
	self:addDirEntry(ino, ino, ".", FT_DIR)
	self:addDirEntry(ino, parentIno, "..", FT_DIR)

	-- Add to parent
	self:addDirEntry(parentIno, ino, name, FT_DIR)
	return ino
end

-- Create a symlink
function HDD:createSymlink(dirIno, name, target)
	local ino = self:allocInode()
	if not ino then
		return nil, "no_inodes"
	end
	local buf = buffer.create(INODE_SIZE)
	self:inoSetU16(buf, I_MODE, bit32.bor(S_IFLNK, 0x1FF))
	self:inoSetU16(buf, I_LINKS, 1)
	local t = os.time()
	self:inoSet(buf, I_CTIME, t)
	self:inoSet(buf, I_MTIME, t)
	self:writeInode(ino, buf)
	self:writeFile(ino, 0, target)
	self:addDirEntry(dirIno, ino, name, FT_LNK)
	return ino
end

-- Delete a file (unlink)
function HDD:unlink(dirIno, name)
	local ino, err = self:lookupDir(dirIno, name)
	if not ino then
		return false, err
	end
	self:removeDirEntry(dirIno, name)
	local buf = self:readInode(ino)
	local links = self:inoGetU16(buf, I_LINKS)
	if links <= 1 then
		-- Free all data blocks and inode
		self:inoSetU16(buf, I_LINKS, 0)
		self:inoSet(buf, I_DTIME, os.time())
		self:writeInode(ino, buf)
		self:freeInode(ino)
	else
		self:inoSetU16(buf, I_LINKS, links - 1)
		self:writeInode(ino, buf)
	end
	return true
end

-- Get file info (stat)
function HDD:stat(ino)
	local buf = self:readInode(ino)
	return {
		ino = ino,
		mode = self:inoGetU16(buf, I_MODE),
		uid = self:inoGetU16(buf, I_UID),
		gid = self:inoGetU16(buf, I_GID),
		size = self:inoGet(buf, I_SZ_LO),
		atime = self:inoGet(buf, I_ATIME),
		ctime = self:inoGet(buf, I_CTIME),
		mtime = self:inoGet(buf, I_MTIME),
		links = self:inoGetU16(buf, I_LINKS),
		blocks = self:inoGet(buf, I_BLOCKS),
	}
end

-- ============================================================
-- FORMAT (mkfs)
-- ============================================================
function HDD:format(volLabel)
	volLabel = volLabel or "VirtualDisk"
	-- Write superblock
	local sb = buffer.create(SB_SIZE)
	buffer.writeu32(sb, SB.INO_COUNT, MAX_INODES)
	buffer.writeu32(sb, SB.BLK_COUNT, TOTAL_BLOCKS)
	buffer.writeu32(sb, SB.FREE_BLKS, TOTAL_BLOCKS - BLK_DATA)
	buffer.writeu32(sb, SB.FREE_INOS, MAX_INODES - 2)
	buffer.writeu32(sb, SB.FIRST_DATA, BLK_DATA)
	buffer.writeu32(sb, SB.LOG_BLK_SZ, 2) -- 2^(2+10) = 4096
	buffer.writeu16(sb, SB.MAGIC, 0xEF53)
	buffer.writeu16(sb, SB.STATE, 1)
	-- Volume name
	for i = 0, math.min(#volLabel, 15) do
		local b = i < #volLabel and volLabel:byte(i + 1) or 0
		buffer.writeu8(sb, SB.VOL_NAME + i, b)
	end
	self:writeSuperblock(sb)

	-- Mark reserved blocks as used in block bitmap
	for i = 0, BLK_DATA - 1 do
		self:bitmapSet(BLK_BMAP, i, true)
	end
	-- Mark reserved inodes
	self:bitmapSet(BLK_IMAP, INO_INVALID, true)
	self:bitmapSet(BLK_IMAP, INO_ROOT - 1, true)
	self:bitmapSet(BLK_IMAP, INO_LOST - 1, true)

	-- Create root inode (ino=1)
	local rootBuf = buffer.create(INODE_SIZE)
	self:inoSetU16(rootBuf, I_MODE, bit32.bor(S_IFDIR, 0x1FF)) -- drwxrwxrwx
	self:inoSetU16(rootBuf, I_LINKS, 3)
	local t = os.time()
	self:inoSet(rootBuf, I_CTIME, t)
	self:inoSet(rootBuf, I_MTIME, t)
	self:writeInode(INO_ROOT, rootBuf)
	-- Root's self/parent entries
	self:addDirEntry(INO_ROOT, INO_ROOT, ".", FT_DIR)
	self:addDirEntry(INO_ROOT, INO_ROOT, "..", FT_DIR)

	-- Create standard directory tree
	local function mkdir(parent, name, perm)
		return self:createDir(parent, name, perm or ISA.FS.PERM_755, 0, 0)
	end

	local bin = mkdir(INO_ROOT, "bin")
	local sbin = mkdir(INO_ROOT, "sbin")
	local etc = mkdir(INO_ROOT, "etc")
	local usr = mkdir(INO_ROOT, "usr")
	local usrbin = mkdir(usr, "bin")
	local var = mkdir(INO_ROOT, "var")
	local tmp = mkdir(INO_ROOT, "tmp", ISA.FS.PERM_777)
	local home = mkdir(INO_ROOT, "home")
	local root = mkdir(home, "root")
	local boot = mkdir(INO_ROOT, "boot")
	local dev = mkdir(INO_ROOT, "dev")
	local proc = mkdir(INO_ROOT, "proc")
	local sys = mkdir(INO_ROOT, "sys")
	local mnt = mkdir(INO_ROOT, "mnt")
	local opt = mkdir(INO_ROOT, "opt")
	local games = mkdir(opt, "games")
	local apps = mkdir(opt, "apps")
	local pkgs = mkdir(var, "packages")

	-- /etc config files
	local function writeConfig(dirIno, name, content)
		local ino = self:createFile(dirIno, name, ISA.FS.PERM_644, 0, 0)
		self:writeFile(ino, 0, content)
		return ino
	end

	writeConfig(etc, "hostname", "virtualpc\n")
	writeConfig(
		etc,
		"os-release",
		'NAME="VirtualOS"\nVERSION="1.0"\nID=virtualos\nVERSION_ID=1.0\n' .. 'PRETTY_NAME="VirtualOS 1.0 (RISC-64)"\n'
	)
	writeConfig(etc, "passwd", "root:x:0:0:root:/home/root:/bin/sh\nuser:x:1000:1000:user:/home/user:/bin/sh\n")
	writeConfig(
		etc,
		"fstab",
		"# <device> <mount> <type> <options> <dump> <pass>\n"
			.. "/dev/hda0  /       vcfs   defaults   0      1\n"
			.. "tmpfs      /tmp    tmpfs  defaults   0      0\n"
	)
	writeConfig(
		etc,
		"motd",
		"\n  ██╗   ██╗██╗██████╗ ████████╗██╗   ██╗ █████╗ ██╗\n"
			.. "  ██║   ██║██║██╔══██╗╚══██╔══╝██║   ██║██╔══██╗██║\n"
			.. "  ██║   ██║██║██████╔╝   ██║   ██║   ██║███████║██║\n"
			.. "  ╚██╗ ██╔╝██║██╔══██╗   ██║   ██║   ██║██╔══██║██║\n"
			.. "   ╚████╔╝ ██║██║  ██║   ██║   ╚██████╔╝██║  ██║███████╗\n"
			.. "    ╚═══╝  ╚═╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝\n"
			.. "                VirtualOS 1.0  RISC-64 Architecture\n"
			.. "  Type 'help' for commands.  'desktop' to launch GUI.\n\n"
	)

	writeConfig(
		etc,
		"boot.cfg",
		"# VirtualOS Boot Configuration\n"
			.. "DEFAULT=virtualos\n"
			.. "TIMEOUT=3\n"
			.. "\n"
			.. "[virtualos]\n"
			.. "KERNEL=/boot/kernel.bin\n"
			.. "INITRD=/boot/initrd.img\n"
			.. "CMDLINE=root=/dev/hda0 quiet splash\n"
			.. "LABEL=VirtualOS 1.0\n"
			.. "\n"
			.. "[debug]\n"
			.. "KERNEL=/boot/kernel.bin\n"
			.. "CMDLINE=root=/dev/hda0 debug loglevel=7\n"
			.. "LABEL=VirtualOS (debug)\n"
	)

	writeConfig(
		etc,
		"inittab",
		"# /etc/inittab\n"
			.. "::sysinit:/sbin/init\n"
			.. "tty1::respawn:/bin/getty -n -l /bin/sh\n"
			.. "tty2::respawn:/bin/sh\n"
	)

	-- /etc/pkg (package database)
	local etcpkg = mkdir(etc, "pkg")
	writeConfig(etcpkg, "installed.db", "# pkg name version arch\n")

	-- /boot
	writeConfig(
		boot,
		"grub.cfg",
		"# GRUB-style boot config (read-only, internal use)\n"
			.. "set default=0\n"
			.. "set timeout=3\n"
			.. "menuentry 'VirtualOS' { kernel /boot/kernel.bin }\n"
	)

	-- /home/root
	writeConfig(
		root,
		".profile",
		"# Root profile\nexport PATH=/bin:/sbin:/usr/bin\nexport HOME=/home/root\n"
			.. "export TERM=vterm\nexport USER=root\n"
	)
	writeConfig(root, ".vimrc", "set number\nset tabstop=4\nset autoindent\n")

	-- /dev device nodes (stubs)
	local devNull = self:createFile(dev, "null", ISA.FS.PERM_644)
	local devZero = self:createFile(dev, "zero", ISA.FS.PERM_644)
	self:createFile(dev, "hda", ISA.FS.PERM_644)
	self:createFile(dev, "hda0", ISA.FS.PERM_644)
	self:createFile(dev, "tty0", ISA.FS.PERM_644)
	self:createFile(dev, "tty1", ISA.FS.PERM_644)
	self:createFile(dev, "urandom", ISA.FS.PERM_644)
	self:createFile(dev, "fb0", ISA.FS.PERM_644)

	-- /proc (kernel virtual files)
	writeConfig(proc, "version", "VirtualOS 1.0 (RISC-64)\n")
	writeConfig(proc, "cpuinfo", "processor\t: 0\nmodel name\t: RISC-64 4GHz\ncores\t: 4\n")
	writeConfig(proc, "meminfo", "MemTotal:\t131072 kB\nMemFree:\t131072 kB\n")
	writeConfig(proc, "uptime", "0.00 0.00\n")

	return true
end

-- ============================================================
-- MMIO
-- ============================================================
function HDD:mmioRead(addr)
	local off = addr - MMAP.STOR_BASE
	if off == 0x00 then
		return self.reg_status
	elseif off == 0x04 then
		return bit32.band(self.reg_lba, 0xFFFFFFFF)
	elseif off == 0x0C then
		return self.reg_count
	elseif off == 0x10 then
		return self.reg_buf
	elseif off == 0x14 then
		return self.reg_status
	elseif off == 0x18 then
		return self.reg_error
	elseif off == 0x20 then
		return TOTAL_SECTORS
	elseif off == 0x24 then
		return SECTOR_SIZE
	end
	return 0
end

function HDD:mmioWrite(addr, val)
	local off = addr - MMAP.STOR_BASE
	if off == 0x04 then
		self.reg_lba = val
	elseif off == 0x0C then
		self.reg_count = bit32.band(val, 0xFFFF)
	elseif off == 0x10 then
		self.reg_buf = val
	elseif off == 0x1C then
		self.reg_irqen = val
	elseif off == 0x00 then
		self:execCmd(bit32.band(val, 0xFF))
	end
end

function HDD:execCmd(cmd)
	self.reg_status = 1 -- busy
	if cmd == 0x20 then -- READ
		self:dmaRead(self.reg_lba, self.reg_count, self.reg_buf)
	elseif cmd == 0x30 then -- WRITE
		self:dmaWrite(self.reg_lba, self.reg_count, self.reg_buf)
	elseif cmd == 0xE7 then -- FLUSH
		self:saveAllDirty()
	end
	self.reg_status = 4
	if self.onDMADone then
		self.onDMADone()
	end
end

function HDD:dmaRead(lba, count, ramAddr)
	local mem = self.memory
	for i = 0, count - 1 do
		local sec = self:readSectorRaw(lba + i)
		local dest = ramAddr + i * SECTOR_SIZE - MMAP.RAM_BASE
		if dest >= 0 and dest + SECTOR_SIZE <= mem.ramSize then
			buffer.copy(mem.ram, dest, sec, 0, SECTOR_SIZE)
		end
	end
	self.stats.dmaOps += 1
end

function HDD:dmaWrite(lba, count, ramAddr)
	local mem = self.memory
	for i = 0, count - 1 do
		local src = ramAddr + i * SECTOR_SIZE - MMAP.RAM_BASE
		if src >= 0 and src + SECTOR_SIZE <= mem.ramSize then
			local sec = self:_ensureSector(lba + i)
			buffer.copy(sec, 0, mem.ram, src, SECTOR_SIZE)
			self.dirtySet[lba + i] = true
		end
	end
	self.stats.dmaOps += 1
end

-- ============================================================
-- DATASTORE PERSISTENCE
-- ============================================================
function HDD:loadFromDataStore()
	if not self.dataStore then
		self:format()
		return false
	end
	local ok, meta = pcall(function()
		return self.dataStore:GetAsync(DS_KEY_PREFIX .. self.playerId .. "_meta")
	end)
	if not ok or not meta then
		self:format()
		return false
	end

	local chunkCount = meta.chunks or 0
	for ci = 0, chunkCount - 1 do
		local ok2, encoded = pcall(function()
			return self.dataStore:GetAsync(DS_KEY_PREFIX .. self.playerId .. "_" .. ci)
		end)
		if ok2 and encoded then
			local raw = self.base64.Decode(encoded)
			local baseLBA = ci * DS_SECTORS_PER_KEY
			for i = 0, DS_SECTORS_PER_KEY - 1 do
				local off = i * SECTOR_SIZE + 1
				if off + SECTOR_SIZE - 1 <= #raw then
					local sec = self:_ensureSector(baseLBA + i)
					for j = 0, SECTOR_SIZE - 1 do
						buffer.writeu8(sec, j, raw:byte(off + j))
					end
				end
			end
		end
	end
	return true
end

function HDD:saveAllDirty()
	if not self.dataStore then
		return
	end
	if not next(self.dirtySet) then
		return
	end

	-- Group dirty LBAs into chunks
	local dirtyChunks = {}
	for lba in pairs(self.dirtySet) do
		local ci = math.floor(lba / DS_SECTORS_PER_KEY)
		dirtyChunks[ci] = true
	end

	local maxChunk = 0
	for ci in pairs(dirtyChunks) do
		if ci > maxChunk then
			maxChunk = ci
		end
	end

	for ci in pairs(dirtyChunks) do
		local raw = {}
		local baseLBA = ci * DS_SECTORS_PER_KEY
		for i = 0, DS_SECTORS_PER_KEY - 1 do
			local sec = self:readSectorRaw(baseLBA + i)
			for j = 0, SECTOR_SIZE - 1 do
				raw[#raw + 1] = string.char(buffer.readu8(sec, j))
			end
		end
		local encoded = self.base64.Encode(table.concat(raw))
		pcall(function()
			self.dataStore:SetAsync(DS_KEY_PREFIX .. self.playerId .. "_" .. ci, encoded)
		end)
		for i = 0, DS_SECTORS_PER_KEY - 1 do
			self.dirtySet[baseLBA + i] = nil
		end
	end

	-- Update meta
	pcall(function()
		self.dataStore:SetAsync(DS_KEY_PREFIX .. self.playerId .. "_meta", {
			chunks = maxChunk + 1,
			saved_at = os.time(),
			version = 1,
		})
	end)
end

-- Autosave hook (call from Heartbeat)
function HDD:tick(dt)
	self._saveTimer = (self._saveTimer or 0) + dt
	if self._saveTimer >= 30 then
		self._saveTimer = 0
		self:saveAllDirty()
	end
end

-- Force save on disconnect
function HDD:onPlayerLeave()
	self:saveAllDirty()
end

-- Constants exposed for kernel
HDD.INO_ROOT = INO_ROOT
HDD.S_IFMT = S_IFMT
HDD.S_IFREG = S_IFREG
HDD.S_IFDIR = S_IFDIR
HDD.S_IFLNK = S_IFLNK
HDD.FT_REG = FT_REG
HDD.FT_DIR = FT_DIR
HDD.FT_LNK = FT_LNK
HDD.BLOCK_SIZE = BLOCK_SIZE
HDD.SECTOR_SIZE = SECTOR_SIZE

return HDD
