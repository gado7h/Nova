--!optimize 2
--!native
--[[
    GPU - Graphics Processing Unit
    ================================
    Features:
        • 1024×576 @ 32bpp RGBA framebuffer (double-buffered)
        • EditableImage Roblox backend (updates ImageLabel/ImageButton)
        • Hardware-accelerated 2D draw commands (FIFO queue)
        • Text rendering with 8×8 bitmap font
        • Sprite/blit support
        • Clipping / scissor rectangle
        • VBlank interrupt to CPU
        • 60 FPS target via Heartbeat
        
    MMIO Interface (CPU writes to GPU_CTRL region):
        0xC0800000 + GPU_REG.CTRL    → enable/flip
        0xC0800000 + GPU_REG.CMD_FIFO → draw command FIFO
        
    Framebuffer format: RGBA8 flat array, row-major
        pixel(x,y) = GPU_FB0 + (y * WIDTH + x) * 4
]]

local ISA = require(script.Parent["ISA"])
local MMAP = ISA.MMAP

-- ============================================================
-- CONSTANTS
-- ============================================================
local GPU_WIDTH = 1024
local GPU_HEIGHT = 576
local GPU_PIXELS = GPU_WIDTH * GPU_HEIGHT
local GPU_BPP = 4 -- bytes per pixel (RGBA)
local GPU_FB_SZ = GPU_PIXELS * GPU_BPP

-- ============================================================
-- 8×8 BITMAP FONT (ASCII 32–126)
-- Encoded as 8 bytes per character, each byte = 1 row
-- ============================================================
-- This is a compact but readable font definition
local FONT8 = {}
-- Space
FONT8[32] = { 0, 0, 0, 0, 0, 0, 0, 0 }
-- !
FONT8[33] = { 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 }
-- "
FONT8[34] = { 0x6C, 0x6C, 0x48, 0x00, 0x00, 0x00, 0x00, 0x00 }
-- #
FONT8[35] = { 0x36, 0x36, 0x7F, 0x36, 0x7F, 0x36, 0x36, 0x00 }
-- $
FONT8[36] = { 0x0C, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x06, 0x00 }
-- %
FONT8[37] = { 0x63, 0x33, 0x18, 0x0C, 0x06, 0x33, 0x31, 0x00 }
-- &
FONT8[38] = { 0x1C, 0x36, 0x1C, 0x6E, 0x3B, 0x33, 0x6E, 0x00 }
-- '
FONT8[39] = { 0x18, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00 }
-- (
FONT8[40] = { 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 }
-- )
FONT8[41] = { 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 }
-- *
FONT8[42] = { 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00 }
-- +
FONT8[43] = { 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 }
-- ,
FONT8[44] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x0C }
-- -
FONT8[45] = { 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 }
-- .
FONT8[46] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 }
-- /
FONT8[47] = { 0x60, 0x30, 0x18, 0x0C, 0x06, 0x03, 0x01, 0x00 }
-- 0-9
FONT8[48] = { 0x3E, 0x63, 0x73, 0x7B, 0x6F, 0x67, 0x3E, 0x00 }
FONT8[49] = { 0x0C, 0x0E, 0x0C, 0x0C, 0x0C, 0x0C, 0x3F, 0x00 }
FONT8[50] = { 0x1E, 0x33, 0x30, 0x1C, 0x06, 0x33, 0x3F, 0x00 }
FONT8[51] = { 0x1E, 0x33, 0x30, 0x1C, 0x30, 0x33, 0x1E, 0x00 }
FONT8[52] = { 0x38, 0x3C, 0x36, 0x33, 0x7F, 0x30, 0x78, 0x00 }
FONT8[53] = { 0x3F, 0x03, 0x1F, 0x30, 0x30, 0x33, 0x1E, 0x00 }
FONT8[54] = { 0x1C, 0x06, 0x03, 0x1F, 0x33, 0x33, 0x1E, 0x00 }
FONT8[55] = { 0x3F, 0x33, 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x00 }
FONT8[56] = { 0x1E, 0x33, 0x33, 0x1E, 0x33, 0x33, 0x1E, 0x00 }
FONT8[57] = { 0x1E, 0x33, 0x33, 0x3E, 0x30, 0x18, 0x0E, 0x00 }
-- :
FONT8[58] = { 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00 }
-- ; < = > ? @
FONT8[59] = { 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x0C, 0x00 }
FONT8[60] = { 0x30, 0x18, 0x0C, 0x06, 0x0C, 0x18, 0x30, 0x00 }
FONT8[61] = { 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 }
FONT8[62] = { 0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00 }
FONT8[63] = { 0x1E, 0x33, 0x30, 0x18, 0x0C, 0x00, 0x0C, 0x00 }
FONT8[64] = { 0x3E, 0x63, 0x7B, 0x7B, 0x7B, 0x03, 0x1E, 0x00 }
-- A-Z
for i, rows in ipairs({
	{ 0x0C, 0x1E, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x00 }, -- A
	{ 0x3F, 0x66, 0x66, 0x3E, 0x66, 0x66, 0x3F, 0x00 }, -- B
	{ 0x3C, 0x66, 0x03, 0x03, 0x03, 0x66, 0x3C, 0x00 }, -- C
	{ 0x1F, 0x36, 0x66, 0x66, 0x66, 0x36, 0x1F, 0x00 }, -- D
	{ 0x7F, 0x46, 0x16, 0x1E, 0x16, 0x46, 0x7F, 0x00 }, -- E
	{ 0x7F, 0x46, 0x16, 0x1E, 0x16, 0x06, 0x0F, 0x00 }, -- F
	{ 0x3C, 0x66, 0x03, 0x03, 0x73, 0x66, 0x7C, 0x00 }, -- G
	{ 0x33, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x33, 0x00 }, -- H
	{ 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00 }, -- I
	{ 0x78, 0x30, 0x30, 0x30, 0x33, 0x33, 0x1E, 0x00 }, -- J
	{ 0x67, 0x66, 0x36, 0x1E, 0x36, 0x66, 0x67, 0x00 }, -- K
	{ 0x0F, 0x06, 0x06, 0x06, 0x46, 0x66, 0x7F, 0x00 }, -- L
	{ 0x63, 0x77, 0x7F, 0x7F, 0x6B, 0x63, 0x63, 0x00 }, -- M
	{ 0x63, 0x67, 0x6F, 0x7B, 0x73, 0x63, 0x63, 0x00 }, -- N
	{ 0x1C, 0x36, 0x63, 0x63, 0x63, 0x36, 0x1C, 0x00 }, -- O
	{ 0x3F, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x0F, 0x00 }, -- P
	{ 0x1E, 0x33, 0x33, 0x33, 0x3B, 0x1E, 0x38, 0x00 }, -- Q
	{ 0x3F, 0x66, 0x66, 0x3E, 0x36, 0x66, 0x67, 0x00 }, -- R
	{ 0x1E, 0x33, 0x07, 0x0E, 0x38, 0x33, 0x1E, 0x00 }, -- S
	{ 0x3F, 0x2D, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00 }, -- T
	{ 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x3F, 0x00 }, -- U
	{ 0x33, 0x33, 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x00 }, -- V
	{ 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00 }, -- W
	{ 0x63, 0x63, 0x36, 0x1C, 0x1C, 0x36, 0x63, 0x00 }, -- X
	{ 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x0C, 0x1E, 0x00 }, -- Y
	{ 0x7F, 0x63, 0x31, 0x18, 0x4C, 0x66, 0x7F, 0x00 }, -- Z
}) do
	FONT8[64 + i] = rows -- 65 = A
end
-- a-z (simple lowercase, mirrors many from uppercase for brevity)
for i, rows in ipairs({
	{ 0x00, 0x00, 0x1E, 0x30, 0x3E, 0x33, 0x6E, 0x00 }, -- a
	{ 0x07, 0x06, 0x06, 0x3E, 0x66, 0x66, 0x3B, 0x00 }, -- b
	{ 0x00, 0x00, 0x1E, 0x33, 0x03, 0x33, 0x1E, 0x00 }, -- c
	{ 0x38, 0x30, 0x30, 0x3e, 0x33, 0x33, 0x6E, 0x00 }, -- d
	{ 0x00, 0x00, 0x1E, 0x33, 0x3f, 0x03, 0x1E, 0x00 }, -- e
	{ 0x1C, 0x36, 0x06, 0x0f, 0x06, 0x06, 0x0F, 0x00 }, -- f
	{ 0x00, 0x00, 0x6E, 0x33, 0x33, 0x3E, 0x30, 0x1F }, -- g
	{ 0x07, 0x06, 0x36, 0x6E, 0x66, 0x66, 0x67, 0x00 }, -- h
	{ 0x0C, 0x00, 0x0E, 0x0C, 0x0C, 0x0C, 0x1E, 0x00 }, -- i
	{ 0x30, 0x00, 0x30, 0x30, 0x30, 0x33, 0x33, 0x1E }, -- j
	{ 0x07, 0x06, 0x66, 0x36, 0x1E, 0x36, 0x67, 0x00 }, -- k
	{ 0x0E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00 }, -- l
	{ 0x00, 0x00, 0x33, 0x7F, 0x7F, 0x6B, 0x63, 0x00 }, -- m
	{ 0x00, 0x00, 0x1F, 0x33, 0x33, 0x33, 0x33, 0x00 }, -- n
	{ 0x00, 0x00, 0x1E, 0x33, 0x33, 0x33, 0x1E, 0x00 }, -- o
	{ 0x00, 0x00, 0x3B, 0x66, 0x66, 0x3E, 0x06, 0x0F }, -- p
	{ 0x00, 0x00, 0x6E, 0x33, 0x33, 0x3E, 0x30, 0x78 }, -- q
	{ 0x00, 0x00, 0x3B, 0x6E, 0x66, 0x06, 0x0F, 0x00 }, -- r
	{ 0x00, 0x00, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x00 }, -- s
	{ 0x08, 0x0C, 0x3E, 0x0C, 0x0C, 0x2C, 0x18, 0x00 }, -- t
	{ 0x00, 0x00, 0x33, 0x33, 0x33, 0x33, 0x6E, 0x00 }, -- u
	{ 0x00, 0x00, 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x00 }, -- v
	{ 0x00, 0x00, 0x63, 0x6B, 0x7F, 0x7F, 0x36, 0x00 }, -- w
	{ 0x00, 0x00, 0x63, 0x36, 0x1C, 0x36, 0x63, 0x00 }, -- x
	{ 0x00, 0x00, 0x33, 0x33, 0x33, 0x3E, 0x30, 0x1F }, -- y
	{ 0x00, 0x00, 0x3F, 0x19, 0x0C, 0x26, 0x3F, 0x00 }, -- z
}) do
	FONT8[96 + i] = rows -- 97 = a
end
-- Fill remaining printable chars with placeholder
for i = 91, 126 do
	if not FONT8[i] then
		FONT8[i] = { 0x3C, 0x42, 0x81, 0x81, 0x81, 0x42, 0x3C, 0x00 }
	end
end

-- ============================================================
-- GPU OBJECT
-- ============================================================
local GPU = {}
GPU.__index = GPU

function GPU.new(memory, imageLabel)
	local self = setmetatable({}, GPU)

	self.memory = memory
	self.width = GPU_WIDTH
	self.height = GPU_HEIGHT
	self.pixels = GPU_PIXELS
	self.fbSize = GPU_FB_SZ

	-- EditableImage backend
	self.editableImage = nil
	self.imageLabel = imageLabel

	-- Internal pixel buffer (flat table of RGBA, 0-1 range for EditableImage)
	-- We maintain a buffer of 32-bit ABGR values internally and convert on flush
	self.frontBuf = buffer.create(GPU_FB_SZ) -- displayed
	self.backBuf = buffer.create(GPU_FB_SZ) -- drawn to
	self.dirty = true
	self.dirtyRect = { x = 0, y = 0, w = GPU_WIDTH, h = GPU_HEIGHT }

	-- GPU state
	self.enabled = true
	self.vsyncEnabled = true
	self.clearColor = { r = 0, g = 0, b = 0, a = 255 }
	self.scissor = { x = 0, y = 0, w = GPU_WIDTH, h = GPU_HEIGHT, enabled = false }
	self.drawColor = 0xFFFFFFFF -- default: white RGBA
	self.bgColor = 0xFF000000 -- default bg: black

	-- Control registers (MMIO)
	self.ctrl_regs = buffer.create(0x200)

	-- Draw command FIFO
	self.cmdFifo = {}
	self.cmdProcessing = false

	-- Performance
	self.framesRendered = 0
	self.commandsExecuted = 0
	self.vblankCallback = nil -- called when VBlank fires

	-- Initialize EditableImage
	self:initEditableImage()

	-- Register MMIO handlers with memory
	memory:registerMMIO(MMAP.GPU_CTRL, MMAP.GPU_SIZE, function(addr)
		return self:mmioRead(addr)
	end, function(addr, val)
		self:mmioWrite(addr, val)
	end, "GPU")

	return self
end

function GPU:initEditableImage()
	-- Create Roblox EditableImage
	local AssetService = game:GetService("AssetService")
	local ok, err = pcall(function()
		self.editableImage = AssetService:CreateEditableImage({
			Size = Vector2.new(self.width, self.height)
		})

		if self.imageLabel then
			-- Use ImageContent binding
			local content = Content.fromObject(self.editableImage)
			if self.imageLabel:IsA("ImageLabel") or self.imageLabel:IsA("ImageButton") then
				self.imageLabel.ImageContent = content
				self.imageLabel.ScaleType = Enum.ScaleType.Stretch
			end
		end
	end)
	if not ok then
		warn("[GPU] EditableImage init failed:", err)
	end
end

-- ============================================================
-- FRAMEBUFFER PIXEL ACCESS
-- ============================================================
-- Write RGBA (0-255 each) to back buffer
function GPU:setPixel(x, y, r, g, b, a)
	if x < 0 or x >= self.width or y < 0 or y >= self.height then
		return
	end
	if self.scissor.enabled then
		local s = self.scissor
		if x < s.x or x >= s.x + s.w or y < s.y or y >= s.y + s.h then
			return
		end
	end
	local idx = (y * self.width + x) * GPU_BPP
	buffer.writeu8(self.backBuf, idx, r)
	buffer.writeu8(self.backBuf, idx + 1, g)
	buffer.writeu8(self.backBuf, idx + 2, b)
	buffer.writeu8(self.backBuf, idx + 3, a or 255)
	self.dirty = true
end

-- Set pixel from packed 0xRRGGBBAA
function GPU:setPixelPacked(x, y, rgba)
	local r = bit32.rshift(rgba, 24)
	local g = bit32.band(bit32.rshift(rgba, 16), 0xFF)
	local b = bit32.band(bit32.rshift(rgba, 8), 0xFF)
	local a = bit32.band(rgba, 0xFF)
	self:setPixel(x, y, r, g, b, a)
end

function GPU:getPixel(x, y)
	if x < 0 or x >= self.width or y < 0 or y >= self.height then
		return 0
	end
	local idx = (y * self.width + x) * GPU_BPP
	local r = buffer.readu8(self.backBuf, idx)
	local g = buffer.readu8(self.backBuf, idx + 1)
	local b = buffer.readu8(self.backBuf, idx + 2)
	local a = buffer.readu8(self.backBuf, idx + 3)
	return bit32.bor(bit32.lshift(r, 24), bit32.lshift(g, 16), bit32.lshift(b, 8), a)
end

-- ============================================================
-- DRAW PRIMITIVES
-- ============================================================
function GPU:clear(r, g, b, a)
	r = r or self.clearColor.r
	g = g or self.clearColor.g
	b = b or self.clearColor.b
	a = a or self.clearColor.a
	-- Fill entire back buffer
	for i = 0, self.pixels - 1 do
		local idx = i * GPU_BPP
		buffer.writeu8(self.backBuf, idx, r)
		buffer.writeu8(self.backBuf, idx + 1, g)
		buffer.writeu8(self.backBuf, idx + 2, b)
		buffer.writeu8(self.backBuf, idx + 3, a)
	end
	self.dirty = true
	self.dirtyRect = { x = 0, y = 0, w = self.width, h = self.height }
end

-- Fast horizontal line
function GPU:hline(x, y, len, r, g, b, a)
	a = a or 255
	local x2 = math.min(x + len, self.width) - 1
	x = math.max(x, 0)
	if y < 0 or y >= self.height then
		return
	end
	for xi = x, x2 do
		local idx = (y * self.width + xi) * GPU_BPP
		buffer.writeu8(self.backBuf, idx, r)
		buffer.writeu8(self.backBuf, idx + 1, g)
		buffer.writeu8(self.backBuf, idx + 2, b)
		buffer.writeu8(self.backBuf, idx + 3, a)
	end
	self.dirty = true
end

-- Fast vertical line
function GPU:vline(x, y, len, r, g, b, a)
	a = a or 255
	if x < 0 or x >= self.width then
		return
	end
	local y2 = math.min(y + len, self.height) - 1
	y = math.max(y, 0)
	for yi = y, y2 do
		local idx = (yi * self.width + x) * GPU_BPP
		buffer.writeu8(self.backBuf, idx, r)
		buffer.writeu8(self.backBuf, idx + 1, g)
		buffer.writeu8(self.backBuf, idx + 2, b)
		buffer.writeu8(self.backBuf, idx + 3, a)
	end
	self.dirty = true
end

-- Filled rectangle
function GPU:fillRect(x, y, w, h, r, g, b, a)
	a = a or 255
	local x1 = math.max(x, 0)
	local y1 = math.max(y, 0)
	local x2 = math.min(x + w - 1, self.width - 1)
	local y2 = math.min(y + h - 1, self.height - 1)
	for yi = y1, y2 do
		for xi = x1, x2 do
			local idx = (yi * self.width + xi) * GPU_BPP
			buffer.writeu8(self.backBuf, idx, r)
			buffer.writeu8(self.backBuf, idx + 1, g)
			buffer.writeu8(self.backBuf, idx + 2, b)
			buffer.writeu8(self.backBuf, idx + 3, a)
		end
	end
	self.dirty = true
end

-- Outline rectangle
function GPU:drawRect(x, y, w, h, r, g, b, a)
	self:hline(x, y, w, r, g, b, a)
	self:hline(x, y + h - 1, w, r, g, b, a)
	self:vline(x, y, h, r, g, b, a)
	self:vline(x + w - 1, y, h, r, g, b, a)
end

-- Bresenham line
function GPU:drawLine(x0, y0, x1, y1, r, g, b, a)
	a = a or 255
	local dx = math.abs(x1 - x0)
	local dy = math.abs(y1 - y0)
	local sx = x0 < x1 and 1 or -1
	local sy = y0 < y1 and 1 or -1
	local err = dx - dy

	while true do
		self:setPixel(x0, y0, r, g, b, a)
		if x0 == x1 and y0 == y1 then
			break
		end
		local e2 = err * 2
		if e2 > -dy then
			err -= dy
			x0 += sx
		end
		if e2 < dx then
			err += dx
			y0 += sy
		end
	end
end

-- Midpoint circle algorithm
function GPU:drawCircle(cx, cy, radius, r, g, b, a, filled)
	a = a or 255
	local x = radius
	local y = 0
	local err = 0
	while x >= y do
		if filled then
			self:hline(cx - x, cy + y, x * 2 + 1, r, g, b, a)
			self:hline(cx - x, cy - y, x * 2 + 1, r, g, b, a)
			self:hline(cx - y, cy + x, y * 2 + 1, r, g, b, a)
			self:hline(cx - y, cy - x, y * 2 + 1, r, g, b, a)
		else
			self:setPixel(cx + x, cy + y, r, g, b, a)
			self:setPixel(cx + y, cy + x, r, g, b, a)
			self:setPixel(cx - y, cy + x, r, g, b, a)
			self:setPixel(cx - x, cy + y, r, g, b, a)
			self:setPixel(cx - x, cy - y, r, g, b, a)
			self:setPixel(cx - y, cy - x, r, g, b, a)
			self:setPixel(cx + y, cy - x, r, g, b, a)
			self:setPixel(cx + x, cy - y, r, g, b, a)
		end
		y += 1
		if err <= 0 then
			err += 2 * y + 1
		else
			x -= 1
			err += 2 * (y - x) + 1
		end
	end
end

-- Draw 8x8 bitmap character
function GPU:drawChar(x, y, ch, r, g, b, a, bgR, bgG, bgB, bgA)
	local code = type(ch) == "string" and ch:byte(1) or ch
	local glyph = FONT8[code] or FONT8[63] -- default '?'
	for row = 0, 7 do
		local rowBits = glyph[row + 1] or 0
		for col = 0, 7 do
			if bit32.band(bit32.rshift(rowBits, col), 1) == 1 then
				self:setPixel(x + col, y + row, r, g, b, a or 255)
			elseif bgR then
				self:setPixel(x + col, y + row, bgR, bgG, bgB, bgA or 255)
			end
		end
	end
end

-- Draw a string at (x,y), returns width drawn
function GPU:drawText(x, y, text, r, g, b, a, bgR, bgG, bgB, bgA)
	r = r or 255
	g = g or 255
	b = b or 255
	a = a or 255
	local ox = x
	for i = 1, #text do
		local c = text:byte(i)
		if c == 10 then -- newline
			x = ox
			y += 9 -- 8px font + 1px gap
		else
			self:drawChar(x, y, c, r, g, b, a, bgR, bgG, bgB, bgA)
			x += 8
		end
	end
	return x - ox
end

-- Blit a raw RGBA buffer (memory address) to screen
function GPU:blit(dstX, dstY, srcAddr, srcW, srcH)
	for row = 0, srcH - 1 do
		for col = 0, srcW - 1 do
			local memAddr = srcAddr + (row * srcW + col) * 4
			local pr = self.memory:readByte(memAddr)
			local pg = self.memory:readByte(memAddr + 1)
			local pb = self.memory:readByte(memAddr + 2)
			local pa = self.memory:readByte(memAddr + 3)
			if pa > 0 then
				self:setPixel(dstX + col, dstY + row, pr, pg, pb, pa)
			end
		end
	end
end

-- Scroll the screen up by N pixels (for terminal)
function GPU:scrollUp(lines)
	local lineBytes = self.width * GPU_BPP * lines
	local totalBytes = self.pixels * GPU_BPP
	-- Shift buffer up
	buffer.copy(self.backBuf, 0, self.backBuf, lineBytes, totalBytes - lineBytes)
	-- Clear bottom
	local clearStart = totalBytes - lineBytes
	for i = 0, lineBytes - 1 do
		buffer.writeu8(self.backBuf, clearStart + i, 0)
	end
	self.dirty = true
end

-- ============================================================
-- COMMAND FIFO (hardware-accelerated drawing)
-- ============================================================
function GPU:submitCommand(cmd)
	table.insert(self.cmdFifo, cmd)
end

function GPU:processCommands()
	while #self.cmdFifo > 0 do
		local cmd = table.remove(self.cmdFifo, 1)
		self:executeCommand(cmd)
		self.commandsExecuted += 1
	end
end

function GPU:executeCommand(cmd)
	local t = cmd.type or cmd[1]
	local ISA_CMD = ISA.GPU_CMD

	if t == ISA_CMD.CLEAR then
		self:clear(cmd.r, cmd.g, cmd.b, cmd.a)
	elseif t == ISA_CMD.RECT then
		if cmd.filled then
			self:fillRect(cmd.x, cmd.y, cmd.w, cmd.h, cmd.r, cmd.g, cmd.b, cmd.a)
		else
			self:drawRect(cmd.x, cmd.y, cmd.w, cmd.h, cmd.r, cmd.g, cmd.b, cmd.a)
		end
	elseif t == ISA_CMD.LINE then
		self:drawLine(cmd.x0, cmd.y0, cmd.x1, cmd.y1, cmd.r, cmd.g, cmd.b, cmd.a)
	elseif t == ISA_CMD.CIRCLE then
		self:drawCircle(cmd.cx, cmd.cy, cmd.radius, cmd.r, cmd.g, cmd.b, cmd.a, cmd.filled)
	elseif t == ISA_CMD.BLIT then
		self:blit(cmd.dx, cmd.dy, cmd.addr, cmd.w, cmd.h)
	elseif t == ISA_CMD.TEXT then
		self:drawText(cmd.x, cmd.y, cmd.text, cmd.r, cmd.g, cmd.b, cmd.a, cmd.bgR, cmd.bgG, cmd.bgB)
	elseif t == ISA_CMD.FLIP_BUFFER then
		self:flip()
	elseif t == ISA_CMD.SET_SCISSOR then
		if cmd.enabled then
			self.scissor = { x = cmd.x, y = cmd.y, w = cmd.w, h = cmd.h, enabled = true }
		else
			self.scissor.enabled = false
		end
	end
end

-- ============================================================
-- MMIO REGISTER INTERFACE
-- ============================================================
function GPU:mmioRead(addr)
	local reg = addr - MMAP.GPU_CTRL
	if reg == ISA.GPU_REG.CTRL then
		return self.enabled and 1 or 0
	elseif reg == ISA.GPU_REG.STATUS then
		-- bit 0 = vblank, bit 1 = ready
		return bit32.bor(0x02, self.dirty and 0 or 0x01)
	elseif reg == ISA.GPU_REG.WIDTH then
		return self.width
	elseif reg == ISA.GPU_REG.HEIGHT then
		return self.height
	elseif reg == ISA.GPU_REG.BPP then
		return 32
	end
	return 0
end

function GPU:mmioWrite(addr, val)
	local reg = addr - MMAP.GPU_CTRL
	if reg == ISA.GPU_REG.CTRL then
		self.enabled = bit32.band(val, 1) ~= 0
	elseif reg == ISA.GPU_REG.FLIP then
		self:flip()
	elseif reg == ISA.GPU_REG.CLEAR_R then
		self.clearColor.r = bit32.band(val, 0xFF)
	elseif reg == ISA.GPU_REG.CLEAR_G then
		self.clearColor.g = bit32.band(val, 0xFF)
	elseif reg == ISA.GPU_REG.CLEAR_B then
		self.clearColor.b = bit32.band(val, 0xFF)
	elseif reg == ISA.GPU_REG.CLEAR_A then
		self.clearColor.a = bit32.band(val, 0xFF)
	elseif reg == ISA.GPU_REG.CMD_FIFO then
		-- val encodes command type in high byte, data in lower 24
		local cmdType = bit32.rshift(val, 24)
		local data = bit32.band(val, 0xFFFFFF)
		self:submitCommand({ type = cmdType, raw = data })
	end
end

-- ============================================================
-- FLIP / PRESENT
-- ============================================================
function GPU:flip()
	-- Swap buffers
	self.frontBuf, self.backBuf = self.backBuf, self.frontBuf
	self:present()
	self.framesRendered += 1
	self.dirty = false

	-- Trigger VBlank interrupt
	if self.vblankCallback then
		self.vblankCallback()
	end
end

-- Upload frontBuf to EditableImage
function GPU:present()
	if not self.editableImage then
		return
	end

	local ok = pcall(function()
		self.editableImage:WritePixelsBuffer(Vector2.zero, Vector2.new(self.width, self.height), self.frontBuf)
	end)
	if not ok then
		-- Fallback or handle error
	end
end

-- ============================================================
-- TERMINAL RENDERING (for shell/console output)
-- ============================================================
function GPU.newTerminal(gpu, cols, rows, x, y, fgR, fgG, fgB, bgR, bgG, bgB)
	local t = {
		gpu = gpu,
		cols = cols or 80,
		rows = rows or 25,
		ox = x or 0,
		oy = y or 0,
		cx = 0, -- cursor column
		cy = 0, -- cursor row
		fgR = fgR or 200,
		fgG = fgG or 200,
		fgB = fgB or 200,
		bgR = bgR or 0,
		bgG = bgG or 0,
		bgB = bgB or 0,
		-- Screen buffer: 2D array of chars
		buf = {},
		dirty_cells = {},
	}
	for r = 0, rows - 1 do
		t.buf[r] = {}
		for c = 0, cols - 1 do
			t.buf[r][c] = { char = " ", fgR = 200, fgG = 200, fgB = 200, bgR = 0, bgG = 0, bgB = 0 }
		end
	end
	return setmetatable(t, { __index = GPU.Terminal })
end

GPU.Terminal = {}
GPU.Terminal.__index = GPU.Terminal

function GPU.Terminal:write(text)
	for i = 1, #text do
		local c = text:byte(i)
		if c == 10 then -- \n
			self.cx = 0
			self.cy += 1
		elseif c == 13 then -- \r
			self.cx = 0
		elseif c == 8 then -- backspace
			if self.cx > 0 then
				self.cx -= 1
				self:_setCell(self.cx, self.cy, " ")
			end
		elseif c == 9 then -- tab
			local nextTab = math.floor(self.cx / 8) * 8 + 8
			self.cx = math.min(nextTab, self.cols - 1)
		else
			self:_setCell(self.cx, self.cy, string.char(c))
			self.cx += 1
		end

		if self.cx >= self.cols then
			self.cx = 0
			self.cy += 1
		end
		if self.cy >= self.rows then
			self:_scroll()
			self.cy = self.rows - 1
		end
	end
	self:_flush()
end

function GPU.Terminal:_setCell(c, r, ch)
	if r < 0 or r >= self.rows or c < 0 or c >= self.cols then
		return
	end
	self.buf[r][c] = {
		char = ch,
		fgR = self.fgR,
		fgG = self.fgG,
		fgB = self.fgB,
		bgR = self.bgR,
		bgG = self.bgG,
		bgB = self.bgB,
	}
	table.insert(self.dirty_cells, { c = c, r = r })
end

function GPU.Terminal:_scroll()
	for r = 0, self.rows - 2 do
		self.buf[r] = self.buf[r + 1]
	end
	self.buf[self.rows - 1] = {}
	for c = 0, self.cols - 1 do
		self.buf[self.rows - 1][c] = { char = " ", fgR = 200, fgG = 200, fgB = 200, bgR = 0, bgG = 0, bgB = 0 }
	end
	-- Mark all dirty
	for r = 0, self.rows - 1 do
		for c = 0, self.cols - 1 do
			table.insert(self.dirty_cells, { c = c, r = r })
		end
	end
end

function GPU.Terminal:_flush()
	local g = self.gpu
	for _, pos in ipairs(self.dirty_cells) do
		local cell = self.buf[pos.r][pos.c]
		if cell then
			local px = self.ox + pos.c * 8
			local py = self.oy + pos.r * 9
			g:drawChar(px, py, cell.char, cell.fgR, cell.fgG, cell.fgB, 255, cell.bgR, cell.bgG, cell.bgB, 255)
		end
	end
	self.dirty_cells = {}
end

function GPU.Terminal:drawCursor()
	local g = self.gpu
	local px = self.ox + self.cx * 8
	local py = self.oy + self.cy * 9 + 7
	g:hline(px, py, 8, 200, 200, 200, 255)
end

function GPU.Terminal:clear()
	for r = 0, self.rows - 1 do
		for c = 0, self.cols - 1 do
			self.buf[r][c] = { char = " ", fgR = 200, fgG = 200, fgB = 200, bgR = 0, bgG = 0, bgB = 0 }
		end
	end
	self.cx = 0
	self.cy = 0
	self.gpu:fillRect(self.ox, self.oy, self.cols * 8, self.rows * 9, 0, 0, 0, 255)
end

return GPU
