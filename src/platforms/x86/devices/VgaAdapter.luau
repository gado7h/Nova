local VgaAdapter = {}
VgaAdapter.__index = VgaAdapter

local EGA_PALETTE = {
	[0] = 0xFF000000,
	[1] = 0xFF0000AA,
	[2] = 0xFF00AA00,
	[3] = 0xFF00AAAA,
	[4] = 0xFFAA0000,
	[5] = 0xFFAA00AA,
	[6] = 0xFFAA5500,
	[7] = 0xFFAAAAAA,
	[8] = 0xFF555555,
	[9] = 0xFF5555FF,
	[10] = 0xFF55FF55,
	[11] = 0xFF55FFFF,
	[12] = 0xFFFF5555,
	[13] = 0xFFFF55FF,
	[14] = 0xFFFFFF55,
	[15] = 0xFFFFFFFF,
}

local function F(...)
	return { ... }
end

local FONT = {
	[32] = F(0, 0, 0, 0, 0, 0, 0, 0),
	[33] = F(4, 4, 4, 4, 0, 4, 0, 0),
	[35] = F(10, 10, 15, 10, 15, 10, 10, 0),
	[40] = F(2, 4, 8, 8, 8, 4, 2, 0),
	[41] = F(8, 4, 2, 2, 2, 4, 8, 0),
	[43] = F(0, 4, 4, 15, 4, 4, 0, 0),
	[44] = F(0, 0, 0, 0, 4, 4, 8, 0),
	[45] = F(0, 0, 0, 15, 0, 0, 0, 0),
	[46] = F(0, 0, 0, 0, 0, 6, 6, 0),
	[47] = F(1, 1, 2, 4, 8, 8, 0, 0),
	[48] = F(6, 9, 11, 13, 9, 6, 0, 0),
	[49] = F(4, 6, 4, 4, 4, 14, 0, 0),
	[50] = F(6, 9, 1, 2, 4, 15, 0, 0),
	[51] = F(6, 9, 2, 1, 9, 6, 0, 0),
	[52] = F(2, 6, 10, 15, 2, 2, 0, 0),
	[53] = F(15, 8, 14, 1, 9, 6, 0, 0),
	[54] = F(3, 4, 14, 9, 9, 6, 0, 0),
	[55] = F(15, 1, 2, 4, 4, 4, 0, 0),
	[56] = F(6, 9, 6, 9, 9, 6, 0, 0),
	[57] = F(6, 9, 7, 1, 2, 12, 0, 0),
	[58] = F(0, 6, 6, 0, 6, 6, 0, 0),
	[59] = F(0, 6, 6, 0, 6, 6, 4, 0),
	[60] = F(2, 4, 8, 4, 2, 0, 0, 0),
	[61] = F(0, 15, 0, 15, 0, 0, 0, 0),
	[62] = F(8, 4, 2, 4, 8, 0, 0, 0),
	[63] = F(6, 9, 1, 2, 0, 2, 0, 0),
	[64] = F(6, 9, 11, 13, 8, 6, 0, 0),
	[65] = F(6, 9, 15, 9, 9, 9, 0, 0),
	[66] = F(14, 9, 14, 9, 9, 14, 0, 0),
	[67] = F(6, 9, 8, 8, 9, 6, 0, 0),
	[68] = F(14, 9, 9, 9, 9, 14, 0, 0),
	[69] = F(15, 8, 14, 8, 8, 15, 0, 0),
	[70] = F(15, 8, 14, 8, 8, 8, 0, 0),
	[71] = F(6, 9, 8, 11, 9, 7, 0, 0),
	[72] = F(9, 9, 15, 9, 9, 9, 0, 0),
	[73] = F(14, 4, 4, 4, 4, 14, 0, 0),
	[74] = F(7, 2, 2, 2, 10, 4, 0, 0),
	[75] = F(9, 10, 12, 10, 9, 9, 0, 0),
	[76] = F(8, 8, 8, 8, 8, 15, 0, 0),
	[77] = F(9, 15, 15, 9, 9, 9, 0, 0),
	[78] = F(9, 13, 11, 9, 9, 9, 0, 0),
	[79] = F(6, 9, 9, 9, 9, 6, 0, 0),
	[80] = F(14, 9, 14, 8, 8, 8, 0, 0),
	[81] = F(6, 9, 9, 11, 9, 7, 0, 0),
	[82] = F(14, 9, 14, 10, 9, 9, 0, 0),
	[83] = F(7, 8, 6, 1, 9, 6, 0, 0),
	[84] = F(15, 4, 4, 4, 4, 4, 0, 0),
	[85] = F(9, 9, 9, 9, 9, 6, 0, 0),
	[86] = F(9, 9, 9, 9, 6, 4, 0, 0),
	[87] = F(9, 9, 9, 15, 15, 9, 0, 0),
	[88] = F(9, 9, 6, 6, 9, 9, 0, 0),
	[89] = F(9, 9, 6, 4, 4, 4, 0, 0),
	[90] = F(15, 1, 2, 4, 8, 15, 0, 0),
	[91] = F(6, 4, 4, 4, 4, 6, 0, 0),
	[92] = F(8, 8, 4, 2, 1, 1, 0, 0),
	[93] = F(6, 2, 2, 2, 2, 6, 0, 0),
	[95] = F(0, 0, 0, 0, 0, 0, 15, 0),
	[97] = F(0, 0, 6, 1, 7, 7, 0, 0),
	[98] = F(8, 8, 14, 9, 9, 14, 0, 0),
	[99] = F(0, 0, 6, 8, 8, 6, 0, 0),
	[100] = F(1, 1, 7, 9, 9, 7, 0, 0),
	[101] = F(0, 0, 6, 15, 8, 6, 0, 0),
	[102] = F(3, 4, 14, 4, 4, 4, 0, 0),
	[103] = F(0, 0, 7, 9, 7, 1, 6, 0),
	[104] = F(8, 8, 14, 9, 9, 9, 0, 0),
	[105] = F(4, 0, 4, 4, 4, 6, 0, 0),
	[106] = F(2, 0, 2, 2, 10, 4, 0, 0),
	[107] = F(8, 8, 9, 14, 9, 9, 0, 0),
	[108] = F(6, 4, 4, 4, 4, 6, 0, 0),
	[109] = F(0, 0, 15, 15, 9, 9, 0, 0),
	[110] = F(0, 0, 14, 9, 9, 9, 0, 0),
	[111] = F(0, 0, 6, 9, 9, 6, 0, 0),
	[112] = F(0, 0, 14, 9, 14, 8, 8, 0),
	[113] = F(0, 0, 7, 9, 7, 1, 1, 0),
	[114] = F(0, 0, 11, 12, 8, 8, 0, 0),
	[115] = F(0, 0, 6, 4, 2, 14, 0, 0),
	[116] = F(4, 4, 14, 4, 4, 3, 0, 0),
	[117] = F(0, 0, 9, 9, 9, 7, 0, 0),
	[118] = F(0, 0, 9, 9, 6, 4, 0, 0),
	[119] = F(0, 0, 9, 15, 15, 6, 0, 0),
	[120] = F(0, 0, 9, 6, 6, 9, 0, 0),
	[121] = F(0, 0, 9, 7, 1, 6, 0, 0),
	[122] = F(0, 0, 15, 2, 4, 15, 0, 0),
	[123] = F(3, 4, 4, 8, 4, 4, 3, 0),
	[124] = F(4, 4, 4, 4, 4, 4, 0, 0),
	[125] = F(12, 2, 2, 1, 2, 2, 12, 0),
	[126] = F(0, 0, 5, 10, 0, 0, 0, 0),
}

local GLYPH_DEFAULT = F(15, 9, 9, 9, 9, 15, 0, 0)

local function getGlyph(code)
	return FONT[code] or GLYPH_DEFAULT
end

local function clamp(value, low, high)
	if value < low then
		return low
	elseif value > high then
		return high
	end
	return value
end

local function unpackARGB(color)
	local a = math.floor(color / 16777216) % 256
	local r = math.floor(color / 65536) % 256
	local g = math.floor(color / 256) % 256
	local b = color % 256
	return a, r, g, b
end

local function packARGB(a, r, g, b)
	return ((a % 256) * 16777216) + ((r % 256) * 65536) + ((g % 256) * 256) + (b % 256)
end

local function scale6To8(value)
	return math.floor(((tonumber(value) or 0) % 64) * 255 / 63 + 0.5)
end

local function rotateRight8(value, count)
	local byteValue = (tonumber(value) or 0) % 256
	local shift = (tonumber(count) or 0) % 8
	if shift == 0 then
		return byteValue
	end
	return bit32.band(bit32.bor(bit32.rshift(byteValue, shift), bit32.lshift(byteValue, 8 - shift)), 0xFF)
end

local function bitFill(bitValue)
	return bitValue ~= 0 and 0xFF or 0x00
end

local function applyLogic(func, source, latch)
	if func == 1 then
		return bit32.band(source, latch)
	elseif func == 2 then
		return bit32.bor(source, latch)
	elseif func == 3 then
		return bit32.bxor(source, latch)
	end
	return source
end

local function makeBytePlane(size)
	local out = {}
	for index = 0, size - 1 do
		out[index] = 0
	end
	return out
end

local function defaultDacEntry(index)
	local egaColor = EGA_PALETTE[index]
	if egaColor ~= nil then
		local _, r, g, b = unpackARGB(egaColor)
		return {
			r = math.floor(r * 63 / 255 + 0.5),
			g = math.floor(g * 63 / 255 + 0.5),
			b = math.floor(b * 63 / 255 + 0.5),
		}
	end

	local cubeIndex = math.max(0, index - 16)
	if cubeIndex < 216 then
		local red = math.floor(cubeIndex / 36) % 6
		local green = math.floor(cubeIndex / 6) % 6
		local blue = cubeIndex % 6
		return {
			r = math.floor(red * 63 / 5 + 0.5),
			g = math.floor(green * 63 / 5 + 0.5),
			b = math.floor(blue * 63 / 5 + 0.5),
		}
	end

	local gray = math.floor(((cubeIndex - 216) % 24) * 63 / 23 + 0.5)
	return { r = gray, g = gray, b = gray }
end

local function clearCells(cells, count, attr)
	for index = 0, count - 1 do
		cells[index] = { char = 32, attr = attr or 0x07 }
	end
end

function VgaAdapter.new(config, editableImage)
	local self = setmetatable({}, VgaAdapter)
	self.config = config
	self.editableImage = editableImage
	self.W = config.SCREEN_W
	self.H = config.SCREEN_H
	self.CW = config.CHAR_W
	self.CH = config.CHAR_H
	self._frameInterval = 1 / math.max(1, config.DISPLAY_REFRESH_HZ or 60)
	self._nextFrameTime = 0
	self._dirty = true
	self._blinkVisible = true
	self._biosMode = 0x03

	local x86 = config.X86 or {}
	self._apertureBase = x86.VIDEO_BASE or config.VRAM_BASE or 0xA0000
	self._apertureSize = x86.VIDEO_SIZE or config.VRAM_SIZE or 0x20000
	self._textBaseOffset = ((x86.TEXT_BUFFER_BASE or 0xB8000) - self._apertureBase) % self._apertureSize
	self._textByteCount = x86.TEXT_BUFFER_SIZE or 0x8000
	self._textCellCount = math.floor(self._textByteCount / 2)
	self._planeSize = 0x10000

	self._planes = {
		[0] = makeBytePlane(self._planeSize),
		[1] = makeBytePlane(self._planeSize),
		[2] = makeBytePlane(self._planeSize),
		[3] = makeBytePlane(self._planeSize),
	}
	self._latch = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }

	self._framebuf = {}
	for index = 0, self.W * self.H - 1 do
		self._framebuf[index] = 0xFF000000
	end
	self._pixelBuffer = buffer.create(self.W * self.H * 4)

	self._miscOutput = 0x67
	self._featureControl = 0x00
	self._status1 = 0x00
	self._attrFlipFlop = false
	self._attrIndex = 0
	self._seqIndex = 0
	self._gcIndex = 0
	self._crtcIndex = 0
	self._dacMask = 0xFF
	self._dacReadIndex = 0
	self._dacWriteIndex = 0
	self._dacReadComponent = 0
	self._dacWriteComponent = 0

	self._sequencer = {}
	for index = 0, 4 do
		self._sequencer[index] = 0
	end

	self._graphics = {}
	for index = 0, 8 do
		self._graphics[index] = 0
	end

	self._attribute = {}
	for index = 0, 0x14 do
		self._attribute[index] = 0
	end
	for index = 0, 0x0F do
		self._attribute[index] = index
	end

	self._crtc = {}
	for index = 0, 0x18 do
		self._crtc[index] = 0
	end

	self._dac = {}
	for index = 0, 255 do
		self._dac[index] = defaultDacEntry(index)
	end

	self._hostOverlay = {
		active = false,
		cells = {},
		cursorCol = 0,
		cursorRow = 0,
		defaultAttr = 0x0C,
	}
	clearCells(self._hostOverlay.cells, config.TEXT_COLS * config.TEXT_ROWS, self._hostOverlay.defaultAttr)

	self.stats = {
		flushes = 0,
		vramReads = 0,
		vramWrites = 0,
		registerWrites = 0,
		paletteWrites = 0,
		modeChanges = 0,
		hostWrites = 0,
	}

	self:biosSetVideoMode(0x03)
	self:clearHostOverlay()
	return self
end

function VgaAdapter:_textStartCell()
	return (((self._crtc[0x0C] or 0) * 256) + (self._crtc[0x0D] or 0)) % math.max(1, self._textCellCount)
end

function VgaAdapter:_cursorCell()
	return (((self._crtc[0x0E] or 0) * 256) + (self._crtc[0x0F] or 0)) % math.max(1, self._textCellCount)
end

function VgaAdapter:_setCursorCell(cellIndex)
	local cell = (tonumber(cellIndex) or 0) % math.max(1, self._textCellCount)
	self._crtc[0x0E] = math.floor(cell / 256) % 256
	self._crtc[0x0F] = cell % 256
	self._dirty = true
end

function VgaAdapter:_windowInfo()
	local mapSelect = bit32.rshift(bit32.band(self._graphics[0x06] or 0, 0x0C), 2)
	if mapSelect == 0 then
		return 0x00000, 0x20000
	elseif mapSelect == 1 then
		return 0x00000, 0x10000
	elseif mapSelect == 2 then
		return 0x10000, 0x08000
	end
	return 0x18000, 0x08000
end

function VgaAdapter:_decodeCpuOffset(offset)
	local cpuOffset = tonumber(offset) or -1
	local windowBase, windowSize = self:_windowInfo()
	if cpuOffset < windowBase or cpuOffset >= windowBase + windowSize then
		return nil
	end
	return cpuOffset - windowBase
end

function VgaAdapter:_isTextMode()
	return bit32.band(self._attribute[0x10] or 0, 0x01) == 0 and bit32.band(self._graphics[0x06] or 0, 0x01) == 0
end

function VgaAdapter:_isChain4()
	return bit32.band(self._sequencer[0x04] or 0, 0x04) ~= 0
end

function VgaAdapter:_isShift256()
	return bit32.band(self._graphics[0x05] or 0, 0x40) ~= 0
end

function VgaAdapter:_textPlaneOffset(cpuOffset)
	if cpuOffset < self._textBaseOffset or cpuOffset >= self._textBaseOffset + self._textByteCount then
		return nil
	end
	local byteOffset = cpuOffset - self._textBaseOffset
	local plane = byteOffset % 2
	local planeOffset = math.floor(byteOffset / 2) % self._planeSize
	return plane, planeOffset
end

function VgaAdapter:_loadLatches(planeOffset)
	local offset = (tonumber(planeOffset) or 0) % self._planeSize
	for plane = 0, 3 do
		self._latch[plane] = self._planes[plane][offset] or 0
	end
	return offset
end

function VgaAdapter:_readChain4Byte(apertureOffset)
	local plane = apertureOffset % 4
	local planeOffset = math.floor(apertureOffset / 4) % self._planeSize
	self:_loadLatches(planeOffset)
	return self._planes[plane][planeOffset] or 0
end

function VgaAdapter:_writeChain4Byte(apertureOffset, value)
	local plane = apertureOffset % 4
	local planeOffset = math.floor(apertureOffset / 4) % self._planeSize
	self:_loadLatches(planeOffset)
	if bit32.band(self._sequencer[0x02] or 0x0F, bit32.lshift(1, plane)) ~= 0 then
		self._planes[plane][planeOffset] = (tonumber(value) or 0) % 256
	end
end

function VgaAdapter:_readTextByte(cpuOffset)
	local plane, planeOffset = self:_textPlaneOffset(cpuOffset)
	if plane == nil then
		return 0xFF
	end
	return self._planes[plane][planeOffset] or 0
end

function VgaAdapter:_writeTextByte(cpuOffset, value)
	local plane, planeOffset = self:_textPlaneOffset(cpuOffset)
	if plane == nil then
		return
	end
	if bit32.band(self._sequencer[0x02] or 0x0F, bit32.lshift(1, plane)) ~= 0 then
		self._planes[plane][planeOffset] = (tonumber(value) or 0) % 256
	end
end

function VgaAdapter:_planarRead(apertureOffset)
	local offset = self:_loadLatches(apertureOffset)
	local readMode = bit32.band(bit32.rshift(self._graphics[0x05] or 0, 3), 0x01)
	if readMode == 0 then
		local selectedPlane = bit32.band(self._graphics[0x04] or 0, 0x03)
		return self._planes[selectedPlane][offset] or 0
	end

	local colorCompare = self._graphics[0x02] or 0
	local colorDontCare = self._graphics[0x07] or 0x0F
	local result = 0
	for bitIndex = 0, 7 do
		local pixelColor = 0
		for plane = 0, 3 do
			local planeBit = bit32.band(bit32.rshift(self._latch[plane], 7 - bitIndex), 0x01)
			pixelColor = bit32.bor(pixelColor, bit32.lshift(planeBit, plane))
		end
		if bit32.band(pixelColor, colorDontCare) == bit32.band(colorCompare, colorDontCare) then
			result = bit32.bor(result, bit32.lshift(1, 7 - bitIndex))
		end
	end
	return result
end

function VgaAdapter:_planarWrite(apertureOffset, value)
	local offset = self:_loadLatches(apertureOffset)
	local mapMask = self._sequencer[0x02] or 0x0F
	local writeMode = bit32.band(self._graphics[0x05] or 0, 0x03)
	local rotateCount = bit32.band(self._graphics[0x03] or 0, 0x07)
	local logicalOp = bit32.band(bit32.rshift(self._graphics[0x03] or 0, 3), 0x03)
	local bitMask = self._graphics[0x08] or 0xFF
	local setReset = self._graphics[0x00] or 0
	local enableSetReset = self._graphics[0x01] or 0
	local rotated = rotateRight8(value, rotateCount)

	for plane = 0, 3 do
		local planeMask = bit32.lshift(1, plane)
		if bit32.band(mapMask, planeMask) ~= 0 then
			local latch = self._latch[plane]
			local source = rotated
			local writeMask = bitMask

			if writeMode == 0 then
				if bit32.band(enableSetReset, planeMask) ~= 0 then
					source = bitFill(bit32.band(bit32.rshift(setReset, plane), 0x01))
				end
				source = applyLogic(logicalOp, source, latch)
			elseif writeMode == 1 then
				source = latch
				writeMask = 0xFF
			elseif writeMode == 2 then
				source = bitFill(bit32.band(bit32.rshift(value, plane), 0x01))
				source = applyLogic(logicalOp, source, latch)
			else
				source = bitFill(bit32.band(bit32.rshift(setReset, plane), 0x01))
				writeMask = bit32.band(rotated, bitMask)
				source = applyLogic(logicalOp, source, latch)
			end

			self._planes[plane][offset] = bit32.bor(
				bit32.band(source, writeMask),
				bit32.band(latch, bit32.band(bit32.bnot(writeMask), 0xFF))
			)
		end
	end
end

function VgaAdapter:_clearTextMemory(attr)
	local cellAttr = (tonumber(attr) or 0x07) % 256
	for cell = 0, self._textCellCount - 1 do
		self._planes[0][cell] = 32
		self._planes[1][cell] = cellAttr
	end
	for cell = self._textCellCount, self._planeSize - 1 do
		self._planes[0][cell] = 0
		self._planes[1][cell] = 0
	end
	self._dirty = true
end

function VgaAdapter:_clearAllPlanes()
	for plane = 0, 3 do
		for offset = 0, self._planeSize - 1 do
			self._planes[plane][offset] = 0
		end
	end
end

function VgaAdapter:_resetAttributePalette()
	for index = 0, 0x0F do
		self._attribute[index] = index
	end
	self._attribute[0x10] = 0x08
	self._attribute[0x11] = 0x00
	self._attribute[0x12] = 0x0F
	self._attribute[0x13] = 0x08
	self._attribute[0x14] = 0x00
end

function VgaAdapter:biosSetVideoMode(mode)
	local newMode = (tonumber(mode) or 0) % 256
	self._biosMode = newMode
	self._miscOutput = 0x67
	self:_resetAttributePalette()
	self._crtc[0x0A] = 0x0D
	self._crtc[0x0B] = 0x0E
	self._crtc[0x0C] = 0x00
	self._crtc[0x0D] = 0x00
	self._crtc[0x0E] = 0x00
	self._crtc[0x0F] = 0x00

	if newMode == 0x13 then
		self._sequencer[0x00] = 0x03
		self._sequencer[0x01] = 0x01
		self._sequencer[0x02] = 0x0F
		self._sequencer[0x03] = 0x00
		self._sequencer[0x04] = 0x07
		self._graphics[0x00] = 0x00
		self._graphics[0x01] = 0x00
		self._graphics[0x02] = 0x00
		self._graphics[0x03] = 0x00
		self._graphics[0x04] = 0x00
		self._graphics[0x05] = 0x40
		self._graphics[0x06] = 0x05
		self._graphics[0x07] = 0x0F
		self._graphics[0x08] = 0xFF
		self._attribute[0x10] = 0x41
		self:_clearAllPlanes()
	elseif newMode == 0x0D or newMode == 0x0E or newMode == 0x10 then
		self._sequencer[0x00] = 0x03
		self._sequencer[0x01] = 0x01
		self._sequencer[0x02] = 0x0F
		self._sequencer[0x03] = 0x00
		self._sequencer[0x04] = 0x03
		self._graphics[0x00] = 0x00
		self._graphics[0x01] = 0x00
		self._graphics[0x02] = 0x00
		self._graphics[0x03] = 0x00
		self._graphics[0x04] = 0x00
		self._graphics[0x05] = 0x00
		self._graphics[0x06] = 0x05
		self._graphics[0x07] = 0x0F
		self._graphics[0x08] = 0xFF
		self._attribute[0x10] = 0x01
		self:_clearAllPlanes()
	else
		self._sequencer[0x00] = 0x03
		self._sequencer[0x01] = 0x00
		self._sequencer[0x02] = 0x03
		self._sequencer[0x03] = 0x00
		self._sequencer[0x04] = 0x01
		self._graphics[0x00] = 0x00
		self._graphics[0x01] = 0x00
		self._graphics[0x02] = 0x00
		self._graphics[0x03] = 0x00
		self._graphics[0x04] = 0x00
		self._graphics[0x05] = 0x10
		self._graphics[0x06] = 0x0C
		self._graphics[0x07] = 0x0F
		self._graphics[0x08] = 0xFF
		self._attribute[0x10] = 0x08
		self:_clearTextMemory(0x07)
	end

	self.stats.modeChanges = self.stats.modeChanges + 1
	self._dirty = true
end

function VgaAdapter:biosTeletype(ch, attr)
	if not self:_isTextMode() then
		return
	end

	local value = (tonumber(ch) or 32) % 256
	local cellAttr = (tonumber(attr) or 0x07) % 256
	local cols = self.config.TEXT_COLS
	local rows = self.config.TEXT_ROWS
	local relativeCell = self:_cursorCell()
	local startCell = self:_textStartCell()

	if value == 13 then
		relativeCell = math.floor(relativeCell / cols) * cols
	elseif value == 10 then
		relativeCell = (math.floor(relativeCell / cols) + 1) * cols
	elseif value == 8 then
		if relativeCell > 0 then
			relativeCell = relativeCell - 1
			local eraseCell = (startCell + relativeCell) % self._textCellCount
			self._planes[0][eraseCell] = 32
			self._planes[1][eraseCell] = cellAttr
		end
	else
		local target = (startCell + relativeCell) % self._textCellCount
		self._planes[0][target] = value
		self._planes[1][target] = cellAttr
		relativeCell = relativeCell + 1
	end

	if relativeCell >= cols * rows then
		for row = 0, rows - 2 do
			for col = 0, cols - 1 do
				local dst = (startCell + row * cols + col) % self._textCellCount
				local src = (startCell + (row + 1) * cols + col) % self._textCellCount
				self._planes[0][dst] = self._planes[0][src] or 32
				self._planes[1][dst] = self._planes[1][src] or 0x07
			end
		end
		for col = 0, cols - 1 do
			local lastRowCell = (startCell + (rows - 1) * cols + col) % self._textCellCount
			self._planes[0][lastRowCell] = 32
			self._planes[1][lastRowCell] = cellAttr
		end
		relativeCell = (rows - 1) * cols
	end

	self:_setCursorCell(relativeCell)
	self._dirty = true
end

function VgaAdapter:attachBus(bus)
	bus:registerPort(self.config.PORT.VGA_ATTR_INDEX, function()
		return self._attrIndex
	end, function(v)
		local value = bit32.band(tonumber(v) or 0, 0x3F)
		if not self._attrFlipFlop then
			self._attrIndex = bit32.band(value, 0x1F)
			self._attrFlipFlop = true
		else
			self._attribute[self._attrIndex] = value
			self._attrFlipFlop = false
			self.stats.registerWrites = self.stats.registerWrites + 1
			self._dirty = true
		end
	end, "VGA Attribute")
	bus:registerPort(self.config.PORT.VGA_ATTR_DATA_READ, function()
		return self._attribute[self._attrIndex] or 0
	end, nil, "VGA Attribute Read")
	bus:registerPort(self.config.PORT.VGA_MISC_WRITE, function()
		return self._miscOutput
	end, function(v)
		self._miscOutput = bit32.band(tonumber(v) or 0, 0xFF)
		self.stats.registerWrites = self.stats.registerWrites + 1
		self._dirty = true
	end, "VGA Misc")
	bus:registerPort(self.config.PORT.VGA_SEQ_INDEX, function()
		return self._seqIndex
	end, function(v)
		self._seqIndex = bit32.band(tonumber(v) or 0, 0x07)
	end, "VGA Sequencer Index")
	bus:registerPort(self.config.PORT.VGA_SEQ_DATA, function()
		return self._sequencer[self._seqIndex] or 0
	end, function(v)
		self._sequencer[self._seqIndex] = bit32.band(tonumber(v) or 0, 0xFF)
		self.stats.registerWrites = self.stats.registerWrites + 1
		self._dirty = true
	end, "VGA Sequencer Data")
	bus:registerPort(self.config.PORT.VGA_DAC_MASK, function()
		return self._dacMask
	end, function(v)
		self._dacMask = bit32.band(tonumber(v) or 0, 0xFF)
		self._dirty = true
	end, "VGA DAC Mask")
	bus:registerPort(self.config.PORT.VGA_DAC_READ_INDEX, function()
		return self._dacReadIndex
	end, function(v)
		self._dacReadIndex = bit32.band(tonumber(v) or 0, 0xFF)
		self._dacReadComponent = 0
	end, "VGA DAC Read Index")
	bus:registerPort(self.config.PORT.VGA_DAC_WRITE_INDEX, function()
		return self._dacWriteIndex
	end, function(v)
		self._dacWriteIndex = bit32.band(tonumber(v) or 0, 0xFF)
		self._dacWriteComponent = 0
	end, "VGA DAC Write Index")
	bus:registerPort(self.config.PORT.VGA_DAC_DATA, function()
		local entry = self._dac[self._dacReadIndex] or { r = 0, g = 0, b = 0 }
		local component = entry.r
		if self._dacReadComponent == 1 then
			component = entry.g
		elseif self._dacReadComponent == 2 then
			component = entry.b
		end
		self._dacReadComponent = (self._dacReadComponent + 1) % 3
		if self._dacReadComponent == 0 then
			self._dacReadIndex = (self._dacReadIndex + 1) % 256
		end
		return component
	end, function(v)
		local entry = self._dac[self._dacWriteIndex] or { r = 0, g = 0, b = 0 }
		local value = bit32.band(tonumber(v) or 0, 0x3F)
		if self._dacWriteComponent == 0 then
			entry.r = value
		elseif self._dacWriteComponent == 1 then
			entry.g = value
		else
			entry.b = value
		end
		self._dac[self._dacWriteIndex] = entry
		self._dacWriteComponent = (self._dacWriteComponent + 1) % 3
		if self._dacWriteComponent == 0 then
			self._dacWriteIndex = (self._dacWriteIndex + 1) % 256
		end
		self.stats.paletteWrites = self.stats.paletteWrites + 1
		self._dirty = true
	end, "VGA DAC Data")
	bus:registerPort(self.config.PORT.VGA_MISC_READ, function()
		return self._miscOutput
	end, nil, "VGA Misc Read")
	bus:registerPort(self.config.PORT.VGA_GC_INDEX, function()
		return self._gcIndex
	end, function(v)
		self._gcIndex = bit32.band(tonumber(v) or 0, 0x0F)
	end, "VGA Graphics Index")
	bus:registerPort(self.config.PORT.VGA_GC_DATA, function()
		return self._graphics[self._gcIndex] or 0
	end, function(v)
		self._graphics[self._gcIndex] = bit32.band(tonumber(v) or 0, 0xFF)
		self.stats.registerWrites = self.stats.registerWrites + 1
		self._dirty = true
	end, "VGA Graphics Data")
	bus:registerPort(self.config.PORT.VGA_CRTC_INDEX, function()
		return self._crtcIndex
	end, function(v)
		self._crtcIndex = bit32.band(tonumber(v) or 0, 0x1F)
	end, "VGA CRTC Index")
	bus:registerPort(self.config.PORT.VGA_CRTC_DATA, function()
		return self._crtc[self._crtcIndex] or 0
	end, function(v)
		self._crtc[self._crtcIndex] = bit32.band(tonumber(v) or 0, 0xFF)
		self.stats.registerWrites = self.stats.registerWrites + 1
		self._dirty = true
	end, "VGA CRTC Data")
	bus:registerPort(self.config.PORT.VGA_INPUT_STATUS1, function()
		self._attrFlipFlop = false
		local framePhase = (os.clock() % self._frameInterval) / self._frameInterval
		self._status1 = framePhase >= 0.92 and 0x08 or 0x01
		return self._status1
	end, nil, "VGA Input Status 1")
end

function VgaAdapter:memRead(offset)
	self.stats.vramReads = self.stats.vramReads + 1
	local apertureOffset = self:_decodeCpuOffset(offset)
	if apertureOffset == nil then
		return 0xFF
	end
	if self:_isChain4() then
		return self:_readChain4Byte(apertureOffset)
	end
	if self:_isTextMode() then
		return self:_readTextByte(apertureOffset)
	end
	return self:_planarRead(apertureOffset)
end

function VgaAdapter:memWrite(offset, value)
	self.stats.vramWrites = self.stats.vramWrites + 1
	local apertureOffset = self:_decodeCpuOffset(offset)
	if apertureOffset == nil then
		return
	end
	local byteValue = (tonumber(value) or 0) % 256
	if self:_isChain4() then
		self:_writeChain4Byte(apertureOffset, byteValue)
	elseif self:_isTextMode() then
		self:_writeTextByte(apertureOffset, byteValue)
	else
		self:_planarWrite(apertureOffset, byteValue)
	end
	self._dirty = true
end

function VgaAdapter:getCursor()
	local relativeCell = (self:_cursorCell() - self:_textStartCell()) % math.max(1, self._textCellCount)
	return relativeCell % self.config.TEXT_COLS, math.floor(relativeCell / self.config.TEXT_COLS)
end

function VgaAdapter:toggleCursor()
	self._blinkVisible = not self._blinkVisible
	self._dirty = true
end

function VgaAdapter:_dacColor(index)
	local entry = self._dac[bit32.band(index or 0, self._dacMask)] or { r = 0, g = 0, b = 0 }
	return packARGB(255, scale6To8(entry.r), scale6To8(entry.g), scale6To8(entry.b))
end

function VgaAdapter:_attributeColor(colorIndex)
	local paletteIndex = self._attribute[(tonumber(colorIndex) or 0) % 16] or 0
	local colorSelect = self._attribute[0x14] or 0
	paletteIndex = bit32.band(paletteIndex, 0x3F)
	paletteIndex = bit32.bor(paletteIndex, bit32.lshift(bit32.band(colorSelect, 0x0C), 4))
	return self:_dacColor(paletteIndex)
end

function VgaAdapter:_clearFrame(argb)
	for index = 0, self.W * self.H - 1 do
		self._framebuf[index] = argb
	end
end

function VgaAdapter:_blitScaledPixel(x, y, argb)
	local px = x * 2
	local py = y * 2
	self._framebuf[py * self.W + px] = argb
	self._framebuf[py * self.W + px + 1] = argb
	self._framebuf[(py + 1) * self.W + px] = argb
	self._framebuf[(py + 1) * self.W + px + 1] = argb
end

function VgaAdapter:_renderGlyphCell(x, y, charCode, fgARGB, bgARGB, suppressGlyph, cursorStart, cursorEnd, drawCursor)
	local glyph = getGlyph(charCode)
	for glyphRow = 0, 7 do
		for pixelY = 0, 1 do
			local py = y + glyphRow * 2 + pixelY
			local base = py * self.W
			for glyphCol = 0, 3 do
				local mask = bit32.lshift(1, 3 - glyphCol)
				local on = bit32.band(glyph[glyphRow + 1] or 0, mask) ~= 0
				local color = (not suppressGlyph and on) and fgARGB or bgARGB
				local px = x + glyphCol * 2
				self._framebuf[base + px] = color
				self._framebuf[base + px + 1] = color
			end
		end
	end

	if drawCursor then
		local startLine = clamp(cursorStart or 13, 0, self.CH - 1)
		local endLine = clamp(cursorEnd or 14, startLine, self.CH - 1)
		for scanline = startLine, endLine do
			local base = (y + scanline) * self.W + x
			for pixel = 0, self.CW - 1 do
				self._framebuf[base + pixel] = fgARGB
			end
		end
	end
end

function VgaAdapter:_renderTextBuffer(cells, cursorCol, cursorRow, showCursor)
	local blinkEnabled = bit32.band(self._attribute[0x10] or 0, 0x08) == 0
	local cursorDisabled = bit32.band(self._crtc[0x0A] or 0, 0x20) ~= 0
	local cursorStart = bit32.band(self._crtc[0x0A] or 0, 0x1F)
	local cursorEnd = bit32.band(self._crtc[0x0B] or 0, 0x1F)
	local startCell = self:_textStartCell()

	for row = 0, self.config.TEXT_ROWS - 1 do
		for col = 0, self.config.TEXT_COLS - 1 do
			local cell
			if cells then
				cell = cells[row * self.config.TEXT_COLS + col] or { char = 32, attr = 0x07 }
			else
				local absoluteCell = (startCell + row * self.config.TEXT_COLS + col) % self._textCellCount
				cell = {
					char = self._planes[0][absoluteCell] or 32,
					attr = self._planes[1][absoluteCell] or 0x07,
				}
			end

			local attr = cell.attr or 0x07
			local fgIndex = bit32.band(attr, 0x0F)
			local bgIndex = bit32.band(bit32.rshift(attr, 4), 0x07)
			local suppressGlyph = false
			if bit32.band(attr, 0x80) ~= 0 then
				if blinkEnabled then
					suppressGlyph = not self._blinkVisible
				else
					bgIndex = bit32.bor(bgIndex, 0x08)
				end
			end

			local fgARGB = self:_attributeColor(fgIndex)
			local bgARGB = self:_attributeColor(bgIndex)
			local drawCursor = showCursor
				and not cursorDisabled
				and self._blinkVisible
				and cursorCol == col
				and cursorRow == row
			self:_renderGlyphCell(
				col * self.CW,
				row * self.CH,
				cell.char or 32,
				fgARGB,
				bgARGB,
				suppressGlyph,
				cursorStart,
				cursorEnd,
				drawCursor
			)
		end
	end
end

function VgaAdapter:_renderMode13()
	self:_clearFrame(0xFF000000)
	for y = 0, 199 do
		local rowOffset = y * 320
		for x = 0, 319 do
			local linearOffset = rowOffset + x
			local plane = linearOffset % 4
			local planeOffset = math.floor(linearOffset / 4)
			local colorIndex = self._planes[plane][planeOffset] or 0
			self:_blitScaledPixel(x, y, self:_dacColor(colorIndex))
		end
	end
end

function VgaAdapter:_renderPlanarGraphics()
	self:_clearFrame(0xFF000000)
	for y = 0, 199 do
		local scanOffset = y * 40
		for byteIndex = 0, 39 do
			local offset = scanOffset + byteIndex
			local p0 = self._planes[0][offset] or 0
			local p1 = self._planes[1][offset] or 0
			local p2 = self._planes[2][offset] or 0
			local p3 = self._planes[3][offset] or 0
			for bitIndex = 0, 7 do
				local shift = 7 - bitIndex
				local colorIndex = bit32.band(bit32.rshift(p0, shift), 0x01)
				colorIndex = bit32.bor(colorIndex, bit32.lshift(bit32.band(bit32.rshift(p1, shift), 0x01), 1))
				colorIndex = bit32.bor(colorIndex, bit32.lshift(bit32.band(bit32.rshift(p2, shift), 0x01), 2))
				colorIndex = bit32.bor(colorIndex, bit32.lshift(bit32.band(bit32.rshift(p3, shift), 0x01), 3))
				self:_blitScaledPixel(byteIndex * 8 + bitIndex, y, self:_attributeColor(colorIndex))
			end
		end
	end
end

function VgaAdapter:_renderGuestFrame()
	if self:_isTextMode() then
		self:_clearFrame(0xFF000000)
		local cursorCol, cursorRow = self:getCursor()
		self:_renderTextBuffer(nil, cursorCol, cursorRow, true)
	elseif self:_isShift256() then
		self:_renderMode13()
	else
		self:_renderPlanarGraphics()
	end
end

function VgaAdapter:_hostWriteChar(ch, attr)
	local overlay = self._hostOverlay
	local charValue = (type(ch) == "string" and string.byte(ch, 1)) or ((tonumber(ch) or 32) % 256)

	if charValue == 13 then
		overlay.cursorCol = 0
		return
	elseif charValue == 10 then
		overlay.cursorCol = 0
		overlay.cursorRow = overlay.cursorRow + 1
	elseif charValue == 8 then
		if overlay.cursorCol > 0 then
			overlay.cursorCol = overlay.cursorCol - 1
			local idx = overlay.cursorRow * self.config.TEXT_COLS + overlay.cursorCol
			overlay.cells[idx] = { char = 32, attr = attr }
		end
		return
	else
		local idx = overlay.cursorRow * self.config.TEXT_COLS + overlay.cursorCol
		overlay.cells[idx] = { char = charValue, attr = attr }
		overlay.cursorCol = overlay.cursorCol + 1
		if overlay.cursorCol >= self.config.TEXT_COLS then
			overlay.cursorCol = 0
			overlay.cursorRow = overlay.cursorRow + 1
		end
	end

	if overlay.cursorRow >= self.config.TEXT_ROWS then
		for row = 0, self.config.TEXT_ROWS - 2 do
			for col = 0, self.config.TEXT_COLS - 1 do
				local dst = row * self.config.TEXT_COLS + col
				local src = (row + 1) * self.config.TEXT_COLS + col
				overlay.cells[dst] = overlay.cells[src] or { char = 32, attr = overlay.defaultAttr }
			end
		end
		for col = 0, self.config.TEXT_COLS - 1 do
			overlay.cells[(self.config.TEXT_ROWS - 1) * self.config.TEXT_COLS + col] = {
				char = 32,
				attr = overlay.defaultAttr,
			}
		end
		overlay.cursorRow = self.config.TEXT_ROWS - 1
	end
end

function VgaAdapter:hostClear(attr)
	local overlayAttr = (tonumber(attr) or self._hostOverlay.defaultAttr or 0x0C) % 256
	self._hostOverlay.active = true
	self._hostOverlay.defaultAttr = overlayAttr
	self._hostOverlay.cursorCol = 0
	self._hostOverlay.cursorRow = 0
	clearCells(self._hostOverlay.cells, self.config.TEXT_COLS * self.config.TEXT_ROWS, overlayAttr)
	self._dirty = true
end

function VgaAdapter:hostWrite(text, attr)
	local overlayAttr = (tonumber(attr) or self._hostOverlay.defaultAttr or 0x0C) % 256
	if not self._hostOverlay.active then
		self:hostClear(overlayAttr)
	end
	local rendered = tostring(text or "")
	for index = 1, #rendered do
		self:_hostWriteChar(string.byte(rendered, index), overlayAttr)
	end
	self.stats.hostWrites = self.stats.hostWrites + #rendered
	self._dirty = true
end

function VgaAdapter:hostWriteLine(text, attr)
	self:hostWrite(tostring(text or ""), attr)
	self:_hostWriteChar(10, (tonumber(attr) or self._hostOverlay.defaultAttr or 0x0C) % 256)
	self._dirty = true
end

function VgaAdapter:clearHostOverlay()
	self._hostOverlay.active = false
	self._hostOverlay.cursorCol = 0
	self._hostOverlay.cursorRow = 0
	clearCells(self._hostOverlay.cells, self.config.TEXT_COLS * self.config.TEXT_ROWS, self._hostOverlay.defaultAttr)
	self._dirty = true
end

function VgaAdapter:flush()
	if not self._dirty then
		return
	end

	local now = os.clock()
	if self._nextFrameTime ~= 0 and now < self._nextFrameTime then
		return
	end

	self:_renderGuestFrame()
	if self._hostOverlay.active then
		self:_renderTextBuffer(self._hostOverlay.cells, self._hostOverlay.cursorCol, self._hostOverlay.cursorRow, false)
	end

	if self.editableImage then
		local needed = self.W * self.H * 4
		if buffer.len(self._pixelBuffer) ~= needed then
			self._pixelBuffer = buffer.create(needed)
		end

		for index = 0, self.W * self.H - 1 do
			local argb = self._framebuf[index] or 0xFF000000
			local base = index * 4
			local a = math.floor(argb / 16777216) % 256
			local r = math.floor(argb / 65536) % 256
			local g = math.floor(argb / 256) % 256
			local b = argb % 256
			buffer.writeu8(self._pixelBuffer, base, r)
			buffer.writeu8(self._pixelBuffer, base + 1, g)
			buffer.writeu8(self._pixelBuffer, base + 2, b)
			buffer.writeu8(self._pixelBuffer, base + 3, a)
		end

		local ok, err = pcall(function()
			self.editableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(self.W, self.H), self._pixelBuffer)
		end)
		if not ok then
			warn("VgaAdapter:flush WritePixelsBuffer failed:", err)
		end
	end

	self.stats.flushes = self.stats.flushes + 1
	self._dirty = false
	self._nextFrameTime = now + self._frameInterval
end

function VgaAdapter:getStats()
	return self.stats
end

VgaAdapter.PALETTE = EGA_PALETTE

return VgaAdapter
