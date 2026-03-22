local Assembler8086 = require(script.Parent.Assembler8086)
local BiosRom = require(script.Parent.BiosRom)

local BootImageCatalog = {}

local function sectorCountForBytes(bytes)
	return math.max(1, math.ceil(#bytes / 512))
end

local function writeChunk(sectors, startLba, bytes)
	local count = sectorCountForBytes(bytes)
	for sectorIndex = 0, count - 1 do
		local sector = {}
		for index = 1, 512 do
			sector[index] = bytes[sectorIndex * 512 + index] or 0
		end
		sectors[startLba + sectorIndex] = sector
	end
	return count
end

local function sectorToCHS(x86, sectorNumber)
	local spt = x86.SECTORS_PER_TRACK or 18
	local heads = x86.HEADS or 1
	local index = math.max(0, (tonumber(sectorNumber) or 1) - 1)
	local trackSize = math.max(1, spt * heads)
	local cylinder = math.floor(index / trackSize)
	local head = math.floor(index / spt) % heads
	local sector = (index % spt) + 1
	return cylinder, head, sector
end

local function encodeCHSWord(x86, sectorNumber)
	local cylinder, _, sector = sectorToCHS(x86, sectorNumber)
	return bit32.bor(
		bit32.lshift(bit32.band(cylinder, 0xFF), 8),
		bit32.lshift(bit32.band(bit32.rshift(cylinder, 8), 0x03), 6),
		bit32.band(sector, 0x3F)
	)
end

local function hex16(value)
	return string.format("0x%04X", (tonumber(value) or 0) % 0x10000)
end

local function descriptorWords(base, access, limit, flags)
	local linear = (tonumber(base) or 0) % 0x100000000
	local segmentLimit = (tonumber(limit) or 0x000FFFFF) % 0x100000
	local baseLow = linear % 0x10000
	local baseMid = math.floor(linear / 0x10000) % 0x100
	local baseHigh = math.floor(linear / 0x1000000) % 0x100
	local limitLow = segmentLimit % 0x10000
	local limitHigh = math.floor(segmentLimit / 0x10000) % 0x10
	local flagsByte = bit32.bor(bit32.lshift((tonumber(flags) or 0x0C) % 0x10, 4), limitHigh)
	return {
		limitLow = limitLow,
		baseLow = baseLow,
		accessBaseMid = (access % 0x100) * 0x100 + baseMid,
		flagsBaseHigh = baseHigh * 0x100 + flagsByte,
	}
end

local function buildProtectedModeMonitorSource()
	return table.concat({
		"PM_ENTRY:",
		"  MOV AX, 0x0010",
		"  MOV DS, AX",
		"  MOV SS, AX",
		"  MOV ESP, 0x00007B00",
		"  MOV AX, 0x0018",
		"  MOV ES, AX",
		"  CALL MONITOR_INIT",
		"PM_LOOP:",
		"  IN AL, 0x60",
		"  CMP AL, 0",
		"  JE PM_LOOP",
		"  CMP AL, 0x80",
		"  JNC PM_LOOP",
		"  CALL TRANSLATE_SCAN",
		"  CMP AL, 0",
		"  JE PM_LOOP",
		"  CALL HANDLE_CHAR",
		"  JMP PM_LOOP",
		"MONITOR_INIT:",
		"  CALL CLEAR_SCREEN",
		"  MOV DWORD [BOOT_READY_FLAG], 1",
		"  MOV ESI, PM_READY_MSG",
		"  CALL PRINT_STRING_PM",
		"  CALL SHOW_PROMPT",
		"  RET",
		"SHOW_PROMPT:",
		"  MOV ESI, PROMPT",
		"  CALL PRINT_STRING_PM",
		"  MOV ESI, COMMAND_BUFFER",
		"  MOV DWORD [COMMAND_LEN], 0",
		"  MOV BYTE [SI], 0",
		"  RET",
		"HANDLE_CHAR:",
		"  CMP AL, 0x08",
		"  JE HANDLE_BACKSPACE",
		"  CMP AL, 0x0A",
		"  JE HANDLE_ENTER",
		"  MOV [INPUT_CHAR], AL",
		"  MOV EAX, [COMMAND_LEN]",
		"  CMP EAX, 63",
		"  JNC HANDLE_CHAR_DONE",
		"  MOV AL, [INPUT_CHAR]",
		"  CALL PUTC",
		"  MOV AL, [INPUT_CHAR]",
		"  MOV [SI], AL",
		"  INC SI",
		"  MOV BYTE [SI], 0",
		"  MOV EAX, [COMMAND_LEN]",
		"  INC EAX",
		"  MOV [COMMAND_LEN], EAX",
		"HANDLE_CHAR_DONE:",
		"  RET",
		"HANDLE_BACKSPACE:",
		"  MOV EAX, [COMMAND_LEN]",
		"  CMP EAX, 0",
		"  JE HANDLE_CHAR_DONE",
		"  DEC SI",
		"  DEC EAX",
		"  MOV [COMMAND_LEN], EAX",
		"  MOV BYTE [SI], 0",
		"  MOV AL, 0x08",
		"  CALL PUTC",
		"  RET",
		"HANDLE_ENTER:",
		"  MOV BYTE [SI], 0",
		"  MOV AL, 0x0A",
		"  CALL PUTC",
		"  CALL EXECUTE_COMMAND",
		"  CALL SHOW_PROMPT",
		"  RET",
		"EXECUTE_COMMAND:",
		"  CMP BYTE [COMMAND_BUFFER], 0",
		"  JE EXECUTE_DONE",
		"CHECK_HELP:",
		"  CMP BYTE [COMMAND_BUFFER], 'h'",
		"  JNE CHECK_CLEAR",
		"  CMP BYTE [COMMAND_BUFFER+1], 'e'",
		"  JNE CHECK_CLEAR",
		"  CMP BYTE [COMMAND_BUFFER+2], 'l'",
		"  JNE CHECK_CLEAR",
		"  CMP BYTE [COMMAND_BUFFER+3], 'p'",
		"  JNE CHECK_CLEAR",
		"  CMP BYTE [COMMAND_BUFFER+4], 0",
		"  JNE CHECK_CLEAR",
		"  CALL CMD_HELP",
		"  RET",
		"CHECK_CLEAR:",
		"  CMP BYTE [COMMAND_BUFFER], 'c'",
		"  JNE CHECK_CLS",
		"  CMP BYTE [COMMAND_BUFFER+1], 'l'",
		"  JNE CHECK_CLS",
		"  CMP BYTE [COMMAND_BUFFER+2], 'e'",
		"  JNE CHECK_CLS",
		"  CMP BYTE [COMMAND_BUFFER+3], 'a'",
		"  JNE CHECK_CLS",
		"  CMP BYTE [COMMAND_BUFFER+4], 'r'",
		"  JNE CHECK_CLS",
		"  CMP BYTE [COMMAND_BUFFER+5], 0",
		"  JNE CHECK_CLS",
		"  CALL CLEAR_SCREEN",
		"  RET",
		"CHECK_CLS:",
		"  CMP BYTE [COMMAND_BUFFER], 'c'",
		"  JNE CHECK_ECHO",
		"  CMP BYTE [COMMAND_BUFFER+1], 'l'",
		"  JNE CHECK_ECHO",
		"  CMP BYTE [COMMAND_BUFFER+2], 's'",
		"  JNE CHECK_ECHO",
		"  CMP BYTE [COMMAND_BUFFER+3], 0",
		"  JNE CHECK_ECHO",
		"  CALL CLEAR_SCREEN",
		"  RET",
		"CHECK_ECHO:",
		"  CMP BYTE [COMMAND_BUFFER], 'e'",
		"  JNE CHECK_UNAME",
		"  CMP BYTE [COMMAND_BUFFER+1], 'c'",
		"  JNE CHECK_UNAME",
		"  CMP BYTE [COMMAND_BUFFER+2], 'h'",
		"  JNE CHECK_UNAME",
		"  CMP BYTE [COMMAND_BUFFER+3], 'o'",
		"  JNE CHECK_UNAME",
		"  CMP BYTE [COMMAND_BUFFER+4], 0",
		"  JE CMD_ECHO_EMPTY",
		"  CMP BYTE [COMMAND_BUFFER+4], ' '",
		"  JNE CHECK_UNAME",
		"  MOV ESI, COMMAND_BUFFER+5",
		"  CALL PRINT_STRING_PM",
		"  MOV ESI, NEWLINE",
		"  CALL PRINT_STRING_PM",
		"  RET",
		"CMD_ECHO_EMPTY:",
		"  MOV ESI, NEWLINE",
		"  CALL PRINT_STRING_PM",
		"  RET",
		"CHECK_UNAME:",
		"  CMP BYTE [COMMAND_BUFFER], 'u'",
		"  JNE CHECK_REBOOT",
		"  CMP BYTE [COMMAND_BUFFER+1], 'n'",
		"  JNE CHECK_REBOOT",
		"  CMP BYTE [COMMAND_BUFFER+2], 'a'",
		"  JNE CHECK_REBOOT",
		"  CMP BYTE [COMMAND_BUFFER+3], 'm'",
		"  JNE CHECK_REBOOT",
		"  CMP BYTE [COMMAND_BUFFER+4], 'e'",
		"  JNE CHECK_REBOOT",
		"  CMP BYTE [COMMAND_BUFFER+5], 0",
		"  JNE CHECK_REBOOT",
		"  MOV ESI, UNAME_MSG",
		"  CALL PRINT_STRING_PM",
		"  RET",
		"CHECK_REBOOT:",
		"  CMP BYTE [COMMAND_BUFFER], 'r'",
		"  JNE CHECK_UNKNOWN",
		"  CMP BYTE [COMMAND_BUFFER+1], 'e'",
		"  JNE CHECK_UNKNOWN",
		"  CMP BYTE [COMMAND_BUFFER+2], 'b'",
		"  JNE CHECK_UNKNOWN",
		"  CMP BYTE [COMMAND_BUFFER+3], 'o'",
		"  JNE CHECK_UNKNOWN",
		"  CMP BYTE [COMMAND_BUFFER+4], 'o'",
		"  JNE CHECK_UNKNOWN",
		"  CMP BYTE [COMMAND_BUFFER+5], 't'",
		"  JNE CHECK_UNKNOWN",
		"  CMP BYTE [COMMAND_BUFFER+6], 0",
		"  JNE CHECK_UNKNOWN",
		"  JMP SOFT_RESET",
		"CHECK_UNKNOWN:",
		"  MOV ESI, UNKNOWN_PREFIX",
		"  CALL PRINT_STRING_PM",
		"  MOV ESI, COMMAND_BUFFER",
		"  CALL PRINT_STRING_PM",
		"  MOV ESI, UNKNOWN_SUFFIX",
		"  CALL PRINT_STRING_PM",
		"EXECUTE_DONE:",
		"  RET",
		"CMD_HELP:",
		"  MOV ESI, HELP_MSG",
		"  CALL PRINT_STRING_PM",
		"  RET",
		"SOFT_RESET:",
		"  CALL MONITOR_INIT",
		"  JMP PM_LOOP",
		"TRANSLATE_SCAN:",
		"  CMP AL, 0x02",
		"  JE SCAN_1",
		"  CMP AL, 0x03",
		"  JE SCAN_2",
		"  CMP AL, 0x04",
		"  JE SCAN_3",
		"  CMP AL, 0x05",
		"  JE SCAN_4",
		"  CMP AL, 0x06",
		"  JE SCAN_5",
		"  CMP AL, 0x07",
		"  JE SCAN_6",
		"  CMP AL, 0x08",
		"  JE SCAN_7",
		"  CMP AL, 0x09",
		"  JE SCAN_8",
		"  CMP AL, 0x0A",
		"  JE SCAN_9",
		"  CMP AL, 0x0B",
		"  JE SCAN_0",
		"  CMP AL, 0x0E",
		"  JE SCAN_BACKSPACE",
		"  CMP AL, 0x10",
		"  JE SCAN_Q",
		"  CMP AL, 0x11",
		"  JE SCAN_W",
		"  CMP AL, 0x12",
		"  JE SCAN_E",
		"  CMP AL, 0x13",
		"  JE SCAN_R",
		"  CMP AL, 0x14",
		"  JE SCAN_T",
		"  CMP AL, 0x15",
		"  JE SCAN_Y",
		"  CMP AL, 0x16",
		"  JE SCAN_U",
		"  CMP AL, 0x17",
		"  JE SCAN_I",
		"  CMP AL, 0x18",
		"  JE SCAN_O",
		"  CMP AL, 0x19",
		"  JE SCAN_P",
		"  CMP AL, 0x1C",
		"  JE SCAN_ENTER",
		"  CMP AL, 0x1E",
		"  JE SCAN_A",
		"  CMP AL, 0x1F",
		"  JE SCAN_S",
		"  CMP AL, 0x20",
		"  JE SCAN_D",
		"  CMP AL, 0x21",
		"  JE SCAN_F",
		"  CMP AL, 0x22",
		"  JE SCAN_G",
		"  CMP AL, 0x23",
		"  JE SCAN_H",
		"  CMP AL, 0x24",
		"  JE SCAN_J",
		"  CMP AL, 0x25",
		"  JE SCAN_K",
		"  CMP AL, 0x26",
		"  JE SCAN_L",
		"  CMP AL, 0x2C",
		"  JE SCAN_Z",
		"  CMP AL, 0x2D",
		"  JE SCAN_X",
		"  CMP AL, 0x2E",
		"  JE SCAN_C",
		"  CMP AL, 0x2F",
		"  JE SCAN_V",
		"  CMP AL, 0x30",
		"  JE SCAN_B",
		"  CMP AL, 0x31",
		"  JE SCAN_N",
		"  CMP AL, 0x32",
		"  JE SCAN_M",
		"  CMP AL, 0x39",
		"  JE SCAN_SPACE",
		"  XOR AX, AX",
		"  RET",
		"SCAN_1: MOV AL, '1'",
		"  RET",
		"SCAN_2: MOV AL, '2'",
		"  RET",
		"SCAN_3: MOV AL, '3'",
		"  RET",
		"SCAN_4: MOV AL, '4'",
		"  RET",
		"SCAN_5: MOV AL, '5'",
		"  RET",
		"SCAN_6: MOV AL, '6'",
		"  RET",
		"SCAN_7: MOV AL, '7'",
		"  RET",
		"SCAN_8: MOV AL, '8'",
		"  RET",
		"SCAN_9: MOV AL, '9'",
		"  RET",
		"SCAN_0: MOV AL, '0'",
		"  RET",
		"SCAN_Q: MOV AL, 'q'",
		"  RET",
		"SCAN_W: MOV AL, 'w'",
		"  RET",
		"SCAN_E: MOV AL, 'e'",
		"  RET",
		"SCAN_R: MOV AL, 'r'",
		"  RET",
		"SCAN_T: MOV AL, 't'",
		"  RET",
		"SCAN_Y: MOV AL, 'y'",
		"  RET",
		"SCAN_U: MOV AL, 'u'",
		"  RET",
		"SCAN_I: MOV AL, 'i'",
		"  RET",
		"SCAN_O: MOV AL, 'o'",
		"  RET",
		"SCAN_P: MOV AL, 'p'",
		"  RET",
		"SCAN_A: MOV AL, 'a'",
		"  RET",
		"SCAN_S: MOV AL, 's'",
		"  RET",
		"SCAN_D: MOV AL, 'd'",
		"  RET",
		"SCAN_F: MOV AL, 'f'",
		"  RET",
		"SCAN_G: MOV AL, 'g'",
		"  RET",
		"SCAN_H: MOV AL, 'h'",
		"  RET",
		"SCAN_J: MOV AL, 'j'",
		"  RET",
		"SCAN_K: MOV AL, 'k'",
		"  RET",
		"SCAN_L: MOV AL, 'l'",
		"  RET",
		"SCAN_Z: MOV AL, 'z'",
		"  RET",
		"SCAN_X: MOV AL, 'x'",
		"  RET",
		"SCAN_C: MOV AL, 'c'",
		"  RET",
		"SCAN_V: MOV AL, 'v'",
		"  RET",
		"SCAN_B: MOV AL, 'b'",
		"  RET",
		"SCAN_N: MOV AL, 'n'",
		"  RET",
		"SCAN_M: MOV AL, 'm'",
		"  RET",
		"SCAN_SPACE: MOV AL, ' '",
		"  RET",
		"SCAN_BACKSPACE: MOV AL, 0x08",
		"  RET",
		"SCAN_ENTER: MOV AL, 0x0A",
		"  RET",
		"PRINT_STRING_PM:",
		"  MOV AL, [SI]",
		"  CMP AL, 0",
		"  JE PRINT_STRING_PM_DONE",
		"  CALL PUTC",
		"  INC SI",
		"  JMP PRINT_STRING_PM",
		"PRINT_STRING_PM_DONE:",
		"  RET",
		"PUTC:",
		"  CMP AL, 0x0D",
		"  JE PUTC_NEWLINE",
		"  CMP AL, 0x0A",
		"  JE PUTC_NEWLINE",
		"  CMP AL, 0x08",
		"  JE PUTC_BACKSPACE",
		"  CMP ECX, 80",
		"  JE PUTC_NEWLINE",
		"  MOV DX, DS",
		"  PUSH EAX",
		"  MOV AX, 0x0018",
		"  MOV DS, AX",
		"  POP EAX",
		"  MOV [DI], AL",
		"  INC DI",
		"  MOV BYTE [DI], 0x07",
		"  INC DI",
		"  MOV DS, DX",
		"  INC EBX",
		"  INC ECX",
		"  CMP DI, 0x0FA0",
		"  JC PUTC_DONE",
		"  CALL SCROLL_SCREEN",
		"PUTC_DONE:",
		"  CALL UPDATE_CURSOR",
		"  RET",
		"PUTC_BACKSPACE:",
		"  CMP ECX, 0",
		"  JE PUTC_DONE",
		"  SUB DI, 2",
		"  DEC EBX",
		"  DEC ECX",
		"  MOV DX, DS",
		"  MOV AX, 0x0018",
		"  MOV DS, AX",
		"  MOV BYTE [DI], ' '",
		"  INC DI",
		"  MOV BYTE [DI], 0x07",
		"  DEC DI",
		"  MOV DS, DX",
		"  RET",
		"PUTC_NEWLINE:",
		"PUTC_NEWLINE_ADVANCE:",
		"  ADD DI, 2",
		"  INC EBX",
		"  INC ECX",
		"  CMP ECX, 80",
		"  JNE PUTC_NEWLINE_ADVANCE",
		"PUTC_NEWLINE_RESET:",
		"  XOR ECX, ECX",
		"  CMP DI, 0x0FA0",
		"  JC PUTC_DONE",
		"  CALL SCROLL_SCREEN",
		"  RET",
		"SCROLL_SCREEN:",
		"  PUSH EAX",
		"  PUSH EDX",
		"  PUSH ESI",
		"  PUSH EDI",
		"  MOV DX, DS",
		"  MOV AX, 0x0018",
		"  MOV DS, AX",
		"  XOR SI, SI",
		"  MOV DI, 0x00A0",
		"SCROLL_COPY_LOOP:",
		"  MOV AL, [DI]",
		"  MOV [SI], AL",
		"  INC DI",
		"  INC SI",
		"  CMP SI, 0x0F00",
		"  JNE SCROLL_COPY_LOOP",
		"  MOV DI, 0x0F00",
		"SCROLL_CLEAR_LAST_LINE:",
		"  MOV BYTE [DI], ' '",
		"  INC DI",
		"  MOV BYTE [DI], 0x07",
		"  INC DI",
		"  CMP DI, 0x0FA0",
		"  JNE SCROLL_CLEAR_LAST_LINE",
		"  MOV DS, DX",
		"  POP EDI",
		"  POP ESI",
		"  POP EDX",
		"  POP EAX",
		"  MOV DI, 0x0F00",
		"  MOV EBX, 0x00000780",
		"  XOR ECX, ECX",
		"  RET",
		"CLEAR_SCREEN:",
		"  MOV DX, DS",
		"  MOV AX, 0x0018",
		"  MOV DS, AX",
		"  XOR DI, DI",
		"CLEAR_SCREEN_LOOP:",
		"  MOV BYTE [DI], ' '",
		"  INC DI",
		"  MOV BYTE [DI], 0x07",
		"  INC DI",
		"  CMP DI, 0x0FA0",
		"  JNE CLEAR_SCREEN_LOOP",
		"  MOV DS, DX",
		"  XOR DI, DI",
		"  XOR EBX, EBX",
		"  XOR ECX, ECX",
		"  RET",
		"UPDATE_CURSOR:",
		"  MOV DX, 0x03D4",
		"  MOV AL, 0x0E",
		"  OUT DX, AL",
		"  INC DX",
		"  MOV AL, BH",
		"  OUT DX, AL",
		"  DEC DX",
		"  MOV AL, 0x0F",
		"  OUT DX, AL",
		"  INC DX",
		"  MOV AL, BL",
		"  OUT DX, AL",
		"  RET",
		"PM_READY_MSG:",
		'  DB "machina protected-mode monitor", 13, 10, "type help for commands", 13, 10, 0',
		"PROMPT:",
		'  DB "root@machina:~# ", 0',
		"NEWLINE:",
		"  DB 13, 10, 0",
		"HELP_MSG:",
		'  DB "help    show available commands", 13, 10, "clear   clear the screen", 13, 10, "cls     alias for clear", 13, 10, "echo    print arguments", 13, 10, "uname   show system identity", 13, 10, "reboot  reset the monitor", 13, 10, 0',
		"UNAME_MSG:",
		'  DB "Linux machina 0.1 i386 bring-up", 13, 10, 0',
		"UNKNOWN_PREFIX:",
		'  DB "pmsh: ", 0',
		"UNKNOWN_SUFFIX:",
		'  DB ": command not found", 13, 10, 0',
		"INPUT_CHAR:",
		"  DB 0",
		"COMMAND_LEN:",
		"  DD 0",
		"COMMAND_BUFFER:",
		"  DB 0",
		"  DB 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0",
		"  DB 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0",
		"  DB 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0",
		"  DB 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0",
		"BOOT_READY_FLAG:",
		"  DD 0",
	}, "\n")
end

local function buildProtectedModeStubSource(config, pmOffset, kernelBaseLinear, gdtLinear)
	local x86 = config.X86 or {}
	local codeDesc = descriptorWords(kernelBaseLinear, 0x9A, 0x000FFFFF, 0x0C)
	local dataDesc = descriptorWords(kernelBaseLinear, 0x92, 0x000FFFFF, 0x0C)
	local videoDesc =
		descriptorWords(x86.TEXT_BUFFER_BASE or 0xB8000, 0x92, math.max(0, (x86.TEXT_BUFFER_SIZE or 0x8000) - 1), 0x04)
	return table.concat({
		"ORG 0x0000",
		"START:",
		"  CLI",
		"  MOV AX, " .. hex16(x86.KERNEL_LOAD_SEG or 0x1000),
		"  MOV DS, AX",
		"  MOV ES, AX",
		"  MOV SS, AX",
		"  MOV SP, 0x7B00",
		"  MOV SI, REALMODE_MSG",
		"  CALL PRINT_STRING",
		"  LGDT [GDT_DESC]",
		"  MOV AX, 1",
		"  LMSW AX",
		"  DB 0xEA",
		"  DW " .. hex16(pmOffset),
		"  DW 0x0008",
		"PRINT_STRING:",
		"  MOV AL, [SI]",
		"  CMP AL, 0",
		"  JE PRINT_DONE",
		"  MOV AH, 0x0E",
		"  INT 0x10",
		"  INC SI",
		"  JMP PRINT_STRING",
		"PRINT_DONE:",
		"  RET",
		"REALMODE_MSG:",
		'  DB "IA-32 protected-mode bring-up", 13, 10, 0',
		"GDT:",
		"  DW 0x0000, 0x0000, 0x0000, 0x0000",
		"  DW "
			.. hex16(codeDesc.limitLow)
			.. ", "
			.. hex16(codeDesc.baseLow)
			.. ", "
			.. hex16(codeDesc.accessBaseMid)
			.. ", "
			.. hex16(codeDesc.flagsBaseHigh),
		"  DW "
			.. hex16(dataDesc.limitLow)
			.. ", "
			.. hex16(dataDesc.baseLow)
			.. ", "
			.. hex16(dataDesc.accessBaseMid)
			.. ", "
			.. hex16(dataDesc.flagsBaseHigh),
		"  DW " .. hex16(videoDesc.limitLow) .. ", " .. hex16(videoDesc.baseLow) .. ", " .. hex16(
			videoDesc.accessBaseMid
		) .. ", " .. hex16(videoDesc.flagsBaseHigh),
		"GDT_DESC:",
		"  DW GDT_END - GDT - 1",
		"  DW " .. hex16(gdtLinear % 0x10000),
		"  DW " .. hex16(math.floor(gdtLinear / 0x10000) % 0x10000),
		"GDT_END:",
	}, "\n")
end

local function concatBytes(first, second)
	local out = {}
	for _, byte in ipairs(first or {}) do
		out[#out + 1] = byte
	end
	for _, byte in ipairs(second or {}) do
		out[#out + 1] = byte
	end
	return out
end

local function buildStandaloneBootImage(config, name, bootSource)
	local biosArtifact = BiosRom.buildArtifact(config)
	local bootArtifact = Assembler8086.compile(bootSource)
	assert(#bootArtifact.bytes <= 512, name .. " boot sector exceeds 512 bytes")

	local sectors = {}
	local bootSector = {}
	for index = 1, 512 do
		bootSector[index] = bootArtifact.bytes[index] or 0
	end
	sectors[0] = bootSector

	return {
		name = name,
		romBytes = BiosRom.buildROMBytes(config, biosArtifact),
		sectors = sectors,
		layout = {
			kernelSectorStart = 0,
			kernelSectorCount = 0,
			fsSuperSector = 0,
			rootDirSector = 0,
			rootDirSectorCount = 0,
			dataStartSector = 0,
			fileCount = 0,
		},
		files = {},
		symbols = {
			bios = biosArtifact.symbols,
			bootSector = bootArtifact.symbols,
			kernel = {},
		},
	}
end

local function buildTextValidationBootSource(passText)
	return table.concat({
		"ORG 0x7C00",
		"START:",
		"  MOV AX, 0x0003",
		"  INT 0x10",
		"  MOV SI, PASS_MSG",
		"  CALL PRINT_STRING",
		"HANG:",
		"  HLT",
		"  JMP HANG",
		"PRINT_STRING:",
		"  MOV AL, [SI]",
		"  CMP AL, 0",
		"  JE PRINT_DONE",
		"  MOV AH, 0x0E",
		"  INT 0x10",
		"  INC SI",
		"  JMP PRINT_STRING",
		"PRINT_DONE:",
		"  RET",
		"PASS_MSG:",
		string.format('  DB "%s", 13, 10, 0', passText),
		"PADTO 0x7DFE, 0",
		"DW 0xAA55",
	}, "\n")
end

local function buildLoadedBootImage(config, name, kernelSource, options)
	options = options or {}
	local kernelOrigin = options.kernelOrigin or 0x0500
	local kernelAssemblerOptions = {
		origin = kernelOrigin,
		defaultOperand32 = options.defaultOperand32 == true,
	}
	local kernelArtifact = Assembler8086.compile(kernelSource, kernelAssemblerOptions)
	local kernelSectorCount = sectorCountForBytes(kernelArtifact.bytes)
	local bootMessage = options.bootMessage

	local bootLines = {
		"ORG 0x7C00",
		"START:",
		"  CLI",
		"  XOR AX, AX",
		"  MOV DS, AX",
		"  MOV ES, AX",
		"  MOV SS, AX",
		"  MOV SP, 0x7C00",
		"  MOV [BOOT_DRIVE], DL",
	}
	if bootMessage then
		bootLines[#bootLines + 1] = "  MOV SI, BOOT_MSG"
		bootLines[#bootLines + 1] = "  CALL PRINT_STRING"
	end
	bootLines[#bootLines + 1] = "  MOV AX, " .. hex16(bit32.bor(0x0200, kernelSectorCount))
	bootLines[#bootLines + 1] = "  MOV BX, " .. hex16(kernelOrigin)
	bootLines[#bootLines + 1] = "  MOV CX, 0x0002"
	bootLines[#bootLines + 1] = "  MOV DL, [BOOT_DRIVE]"
	bootLines[#bootLines + 1] = "  INT 0x13"
	bootLines[#bootLines + 1] = "  JC LOAD_FAIL"
	bootLines[#bootLines + 1] = "  PUSH 0x0000"
	bootLines[#bootLines + 1] = "  PUSH " .. hex16(kernelOrigin)
	bootLines[#bootLines + 1] = "  RETF"
	bootLines[#bootLines + 1] = "LOAD_FAIL:"
	bootLines[#bootLines + 1] = "  MOV SI, FAIL_MSG"
	bootLines[#bootLines + 1] = "  CALL PRINT_STRING"
	bootLines[#bootLines + 1] = "  HLT"
	bootLines[#bootLines + 1] = "  JMP LOAD_FAIL"
	bootLines[#bootLines + 1] = "PRINT_STRING:"
	bootLines[#bootLines + 1] = "  MOV AL, [SI]"
	bootLines[#bootLines + 1] = "  CMP AL, 0"
	bootLines[#bootLines + 1] = "  JE PRINT_DONE"
	bootLines[#bootLines + 1] = "  MOV AH, 0x0E"
	bootLines[#bootLines + 1] = "  INT 0x10"
	bootLines[#bootLines + 1] = "  INC SI"
	bootLines[#bootLines + 1] = "  JMP PRINT_STRING"
	bootLines[#bootLines + 1] = "PRINT_DONE:"
	bootLines[#bootLines + 1] = "  RET"
	bootLines[#bootLines + 1] = "BOOT_DRIVE:"
	bootLines[#bootLines + 1] = "  DB 0"
	if bootMessage then
		bootLines[#bootLines + 1] = "BOOT_MSG:"
		bootLines[#bootLines + 1] = string.format('  DB "%s", 13, 10, 0', bootMessage)
	end
	bootLines[#bootLines + 1] = "FAIL_MSG:"
	bootLines[#bootLines + 1] = '  DB "FAIL boot loader", 13, 10, 0'
	bootLines[#bootLines + 1] = "PADTO 0x7DFE, 0"
	bootLines[#bootLines + 1] = "DW 0xAA55"

	local bootSource = table.concat(bootLines, "\n")
	local biosArtifact = BiosRom.buildArtifact(config)
	local bootArtifact = Assembler8086.compile(bootSource)
	assert(#bootArtifact.bytes <= 512, name .. " boot sector exceeds 512 bytes")

	local sectors = {}
	local bootSector = {}
	for index = 1, 512 do
		bootSector[index] = bootArtifact.bytes[index] or 0
	end
	sectors[0] = bootSector
	writeChunk(sectors, 1, kernelArtifact.bytes or {})

	return {
		name = name,
		romBytes = BiosRom.buildROMBytes(config, biosArtifact),
		sectors = sectors,
		layout = {
			kernelSectorStart = 1,
			kernelSectorCount = kernelSectorCount,
			fsSuperSector = 0,
			rootDirSector = 0,
			rootDirSectorCount = 0,
			dataStartSector = 0,
			fileCount = 0,
		},
		files = {},
		symbols = {
			bios = biosArtifact.symbols,
			bootSector = bootArtifact.symbols,
			kernel = kernelArtifact.symbols,
		},
	}
end

local function buildProtectedModeKernelRoutines(passText)
	return {
		"PRINT_STRING_PM:",
		"  MOV AL, [ESI]",
		"  CMP AL, 0",
		"  JE PRINT_STRING_PM_DONE",
		"  CALL PUTC",
		"  INC ESI",
		"  JMP PRINT_STRING_PM",
		"PRINT_STRING_PM_DONE:",
		"  RET",
		"PUTC:",
		"  MOV DX, DS",
		"  PUSH EAX",
		"  MOV AX, 0x0018",
		"  MOV DS, AX",
		"  POP EAX",
		"  MOV [EDI], AL",
		"  INC EDI",
		"  MOV BYTE [EDI], 0x07",
		"  INC EDI",
		"  MOV DS, DX",
		"  RET",
		"PASS_MSG:",
		string.format('  DB "%s", 13, 10, 0', passText),
		"FAIL_MSG:",
		string.format('  DB "FAIL %s", 13, 10, 0', passText),
	}
end

local function buildIdtEntries(maxVector, entries)
	local lines = {}
	for vector = 0, maxVector do
		local entry = entries[vector]
		if entry then
			lines[#lines + 1] =
				"  DW " .. entry.offset .. ", " .. entry.selector .. ", 0x0000, " .. entry.typeWord .. ", 0x0000"
		else
			lines[#lines + 1] = "  DW 0x0000, 0x0000, 0x0000, 0x0000, 0x0000"
		end
	end
	return lines
end

local function buildProtectedModeValidationKernel(config, passText, options)
	options = options or {}
	local x86 = config.X86 or {}
	local interruptVector = options.interruptVector
	local interruptHandler = options.interruptHandler
	local interruptGateType = options.interruptGateType or "0x8E00"
	local bodyLines = options.bodyLines or {}
	local handlerLines = options.handlerLines or {}
	local maxVector = math.max(interruptVector or 0, options.exceptionVector or 0)
	local idtEntries = {}
	if interruptVector and interruptHandler then
		idtEntries[interruptVector] = {
			offset = interruptHandler,
			selector = "0x0008",
			typeWord = interruptGateType,
		}
	end
	if options.exceptionVector and options.exceptionHandler then
		idtEntries[options.exceptionVector] = {
			offset = options.exceptionHandler,
			selector = "0x0008",
			typeWord = options.exceptionGateType or "0x8E00",
		}
	end

	local lines = {
		"ORG 0x0500",
		"START:",
		"  CLI",
		"  LGDT [GDT_DESC]",
		"  LIDT [IDT_DESC]",
		"  MOV AX, 1",
		"  LMSW AX",
		"  DB 0xEA",
		"  DW PM_ENTRY",
		"  DW 0x0008",
		"PM_ENTRY:",
		"  MOV AX, 0x0010",
		"  MOV DS, AX",
		"  MOV SS, AX",
		"  MOV ESP, 0x00007B00",
		"  MOV AX, 0x0018",
		"  MOV ES, AX",
		"  XOR EDI, EDI",
		"  XOR ESI, ESI",
	}
	for _, line in ipairs(bodyLines) do
		lines[#lines + 1] = line
	end
	lines[#lines + 1] = "  MOV ESI, PASS_MSG"
	lines[#lines + 1] = "  CALL PRINT_STRING_PM"
	lines[#lines + 1] = "  HLT"
	lines[#lines + 1] = "  JMP PM_DONE"
	lines[#lines + 1] = "PM_DONE:"
	lines[#lines + 1] = "  JMP PM_DONE"

	for _, line in ipairs(handlerLines) do
		lines[#lines + 1] = line
	end

	for _, line in ipairs(buildProtectedModeKernelRoutines(passText)) do
		lines[#lines + 1] = line
	end

	lines[#lines + 1] = "PM_FLAG:"
	lines[#lines + 1] = "  DB 0"
	lines[#lines + 1] = "EX_FLAG:"
	lines[#lines + 1] = "  DB 0"
	lines[#lines + 1] = "PRIV_FLAG:"
	lines[#lines + 1] = "  DB 0"

	lines[#lines + 1] = "GDT:"
	lines[#lines + 1] = "  DW 0x0000, 0x0000, 0x0000, 0x0000"
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(0, 0x9A, 0x000FFFFF, 0x0C).limitLow)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(0, 0x9A, 0x000FFFFF, 0x0C).baseLow)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(0, 0x9A, 0x000FFFFF, 0x0C).accessBaseMid)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(0, 0x9A, 0x000FFFFF, 0x0C).flagsBaseHigh)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(0, 0x92, 0x000FFFFF, 0x0C).limitLow)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(0, 0x92, 0x000FFFFF, 0x0C).baseLow)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(0, 0x92, 0x000FFFFF, 0x0C).accessBaseMid)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(0, 0x92, 0x000FFFFF, 0x0C).flagsBaseHigh)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(x86.TEXT_BUFFER_BASE or 0xB8000, 0x92, math.max(0, (x86.TEXT_BUFFER_SIZE or 0x8000) - 1), 0x04).limitLow)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(x86.TEXT_BUFFER_BASE or 0xB8000, 0x92, math.max(0, (x86.TEXT_BUFFER_SIZE or 0x8000) - 1), 0x04).baseLow)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(x86.TEXT_BUFFER_BASE or 0xB8000, 0x92, math.max(0, (x86.TEXT_BUFFER_SIZE or 0x8000) - 1), 0x04).accessBaseMid)
	lines[#lines + 1] = "  DW " .. hex16(descriptorWords(x86.TEXT_BUFFER_BASE or 0xB8000, 0x92, math.max(0, (x86.TEXT_BUFFER_SIZE or 0x8000) - 1), 0x04).flagsBaseHigh)
	lines[#lines + 1] = "GDT_DESC:"
	lines[#lines + 1] = "  DW GDT_END - GDT - 1"
	lines[#lines + 1] = "  DW GDT"
	lines[#lines + 1] = "  DW 0x0000"
	lines[#lines + 1] = "GDT_END:"

	lines[#lines + 1] = "IDT:"
	for _, line in ipairs(buildIdtEntries(maxVector, idtEntries)) do
		lines[#lines + 1] = line
	end
	lines[#lines + 1] = "IDT_DESC:"
	lines[#lines + 1] = "  DW IDT_END - IDT - 1"
	lines[#lines + 1] = "  DW IDT"
	lines[#lines + 1] = "  DW 0x0000"
	lines[#lines + 1] = "IDT_END:"

	return table.concat(lines, "\n")
end

local function buildCpuProtectedModeValidation(config)
	local kernelSource = buildProtectedModeValidationKernel(config, "cpu pm validation PASS", {
		interruptVector = 0x30,
		interruptHandler = "PM_INT_HANDLER",
		interruptGateType = "0x8E00",
		bodyLines = {
			"  CALL PM_NEAR_CHECK",
			"  INT 0x30",
			"  CMP BYTE [PM_FLAG], 1",
			"  JNE PM_FAIL",
		},
		handlerLines = {
			"PM_NEAR_CHECK:",
			"  RET",
			"PM_INT_HANDLER:",
			"  MOV BYTE [PM_FLAG], 1",
			"  IRET",
			"PM_FAIL:",
			"  MOV ESI, FAIL_MSG",
			"  CALL PRINT_STRING_PM",
			"  HLT",
			"  JMP PM_FAIL",
		},
	})
	return buildLoadedBootImage(config, "CpuProtectedModeValidation", kernelSource, {
		kernelOrigin = 0x0500,
		defaultOperand32 = true,
		bootMessage = "cpu pm validation",
	})
end

local function buildCpuExceptionValidation(config)
	local kernelSource = buildProtectedModeValidationKernel(config, "cpu exception validation PASS", {
		exceptionVector = 6,
		exceptionHandler = "PM_EXCEPTION_HANDLER",
		exceptionGateType = "0x8E00",
		bodyLines = {
			"  DB 0x0F, 0x0B",
			"  CMP BYTE [EX_FLAG], 1",
			"  JNE PM_FAIL",
		},
		handlerLines = {
			"PM_EXCEPTION_HANDLER:",
			"  MOV BYTE [EX_FLAG], 1",
			"  IRET",
			"PM_FAIL:",
			"  MOV ESI, FAIL_MSG",
			"  CALL PRINT_STRING_PM",
			"  HLT",
			"  JMP PM_FAIL",
		},
	})
	return buildLoadedBootImage(config, "CpuExceptionValidation", kernelSource, {
		kernelOrigin = 0x0500,
		defaultOperand32 = true,
		bootMessage = "cpu exception validation",
	})
end

local function buildPrivilegeTransitionKernelSource(config, tssBase)
	local x86 = config.X86 or {}
	local kernelCode = descriptorWords(0, 0x9A, 0x000FFFFF, 0x0C)
	local kernelData = descriptorWords(0, 0x92, 0x000FFFFF, 0x0C)
	local userCode = descriptorWords(0, 0xFA, 0x000FFFFF, 0x0C)
	local userData = descriptorWords(0, 0xF2, 0x000FFFFF, 0x0C)
	local videoData = descriptorWords(
		x86.TEXT_BUFFER_BASE or 0xB8000,
		0x92,
		math.max(0, (x86.TEXT_BUFFER_SIZE or 0x8000) - 1),
		0x04
	)
	local tssDescriptor = descriptorWords(tssBase or 0, 0x89, 0x0067, 0x00)

	local lines = {
		"ORG 0x0500",
		"START:",
		"  CLI",
		"  LGDT [GDT_DESC]",
		"  LIDT [IDT_DESC]",
		"  MOV AX, 0x0030",
		"  DB 0x0F, 0x00, 0xD8",
		"  MOV AX, 1",
		"  LMSW AX",
		"  DB 0xEA",
		"  DD PM_ENTRY",
		"  DW 0x0008",
		"PM_ENTRY:",
		"  MOV AX, 0x0010",
		"  MOV DS, AX",
		"  MOV SS, AX",
		"  MOV ESP, 0x00007B00",
		"  MOV AX, 0x0018",
		"  MOV ES, AX",
		"  XOR EDI, EDI",
		"  PUSH 0x0000002B",
		"  PUSH 0x00007900",
		"  PUSH 0x00000202",
		"  PUSH 0x00000023",
		"  PUSH USER_ENTRY",
		"  IRET",
		"PM_FAIL:",
		"  MOV ESI, FAIL_MSG",
		"  CALL PRINT_STRING_PM",
		"PM_FAIL_HANG:",
		"  HLT",
		"  JMP PM_FAIL_HANG",
		"USER_ENTRY:",
		"  MOV AX, 0x002B",
		"  MOV DS, AX",
		"  MOV BYTE [USER_FLAG], 1",
		"  INT 0x31",
		"  CMP BYTE [PRIV_FLAG], 1",
		"  JNE PM_FAIL",
		"  MOV AX, SS",
		"  CMP AX, 0x002B",
		"  JNE PM_FAIL",
		"  MOV ESI, PASS_MSG",
		"  CALL PRINT_STRING_PM",
		"USER_HANG:",
		"  HLT",
		"  JMP USER_HANG",
		"PM_PRIV_HANDLER:",
		"  MOV AX, SS",
		"  CMP AX, 0x0010",
		"  JNE PM_FAIL",
		"  CMP BYTE [USER_FLAG], 1",
		"  JNE PM_FAIL",
		"  MOV BYTE [PRIV_FLAG], 1",
		"  IRET",
	}

	for _, line in ipairs(buildProtectedModeKernelRoutines("privilege transition validation PASS")) do
		lines[#lines + 1] = line
	end

	lines[#lines + 1] = "USER_FLAG:"
	lines[#lines + 1] = "  DB 0"
	lines[#lines + 1] = "PRIV_FLAG:"
	lines[#lines + 1] = "  DB 0"

	lines[#lines + 1] = "GDT:"
	lines[#lines + 1] = "  DW 0x0000, 0x0000, 0x0000, 0x0000"
	lines[#lines + 1] = "  DW " .. hex16(kernelCode.limitLow)
	lines[#lines + 1] = "  DW " .. hex16(kernelCode.baseLow)
	lines[#lines + 1] = "  DW " .. hex16(kernelCode.accessBaseMid)
	lines[#lines + 1] = "  DW " .. hex16(kernelCode.flagsBaseHigh)
	lines[#lines + 1] = "  DW " .. hex16(kernelData.limitLow)
	lines[#lines + 1] = "  DW " .. hex16(kernelData.baseLow)
	lines[#lines + 1] = "  DW " .. hex16(kernelData.accessBaseMid)
	lines[#lines + 1] = "  DW " .. hex16(kernelData.flagsBaseHigh)
	lines[#lines + 1] = "  DW " .. hex16(videoData.limitLow)
	lines[#lines + 1] = "  DW " .. hex16(videoData.baseLow)
	lines[#lines + 1] = "  DW " .. hex16(videoData.accessBaseMid)
	lines[#lines + 1] = "  DW " .. hex16(videoData.flagsBaseHigh)
	lines[#lines + 1] = "  DW " .. hex16(userCode.limitLow)
	lines[#lines + 1] = "  DW " .. hex16(userCode.baseLow)
	lines[#lines + 1] = "  DW " .. hex16(userCode.accessBaseMid)
	lines[#lines + 1] = "  DW " .. hex16(userCode.flagsBaseHigh)
	lines[#lines + 1] = "  DW " .. hex16(userData.limitLow)
	lines[#lines + 1] = "  DW " .. hex16(userData.baseLow)
	lines[#lines + 1] = "  DW " .. hex16(userData.accessBaseMid)
	lines[#lines + 1] = "  DW " .. hex16(userData.flagsBaseHigh)
	lines[#lines + 1] = "  DW " .. hex16(tssDescriptor.limitLow)
	lines[#lines + 1] = "  DW " .. hex16(tssDescriptor.baseLow)
	lines[#lines + 1] = "  DW " .. hex16(tssDescriptor.accessBaseMid)
	lines[#lines + 1] = "  DW " .. hex16(tssDescriptor.flagsBaseHigh)
	lines[#lines + 1] = "GDT_DESC:"
	lines[#lines + 1] = "  DW GDT_END - GDT - 1"
	lines[#lines + 1] = "  DW GDT"
	lines[#lines + 1] = "  DW 0x0000"
	lines[#lines + 1] = "GDT_END:"

	lines[#lines + 1] = "IDT:"
	for vector = 0, 0x31 do
		if vector == 0x31 then
			lines[#lines + 1] = "  DW PM_PRIV_HANDLER, 0x0008, 0x0000, 0xEE00, 0x0000"
		else
			lines[#lines + 1] = "  DW 0x0000, 0x0000, 0x0000, 0x0000, 0x0000"
		end
	end
	lines[#lines + 1] = "IDT_DESC:"
	lines[#lines + 1] = "  DW IDT_END - IDT - 1"
	lines[#lines + 1] = "  DW IDT"
	lines[#lines + 1] = "  DW 0x0000"
	lines[#lines + 1] = "IDT_END:"

	lines[#lines + 1] = "TSS:"
	lines[#lines + 1] = "  DW 0x0000, 0x0000"
	lines[#lines + 1] = "  DD 0x00007B00"
	lines[#lines + 1] = "  DW 0x0010, 0x0000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DW 0x0000, 0x0000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DW 0x0000, 0x0000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000000"
	lines[#lines + 1] = "  DD 0x00000068"
	lines[#lines + 1] = "  PADTO TSS + 0x68, 0"

	return table.concat(lines, "\n")
end

local function buildPrivilegeTransitionValidation(config)
	local kernelSource = buildPrivilegeTransitionKernelSource(config, 0)
	local artifact = Assembler8086.compile(kernelSource, {
		origin = 0x0500,
		defaultOperand32 = true,
	})
	kernelSource = buildPrivilegeTransitionKernelSource(config, artifact.symbols and artifact.symbols.TSS or 0)
	return buildLoadedBootImage(config, "PrivilegeTransitionValidation", kernelSource, {
		kernelOrigin = 0x0500,
		defaultOperand32 = true,
		bootMessage = "privilege transition validation",
	})
end

local function buildBiosBootValidation(config)
	local kernelSource = buildTextValidationBootSource("bios boot validation PASS")
	return buildLoadedBootImage(config, "BiosBootValidation", kernelSource, {
		kernelOrigin = 0x0500,
		bootMessage = "bios boot validation",
	})
end

local function buildInterruptIntegrationValidation(config)
	local kernelSource = table.concat({
		"ORG 0x0500",
		"START:",
		"  CLI",
		"  XOR AX, AX",
		"  MOV DS, AX",
		"  MOV ES, AX",
		"  MOV SS, AX",
		"  MOV SP, 0x7B00",
		"  MOV AX, IRQ0_HANDLER",
		"  MOV [IRQ0_VECTOR], AX",
		"  MOV AX, 0x0000",
		"  MOV [IRQ0_VECTOR + 2], AX",
		"  XOR AL, AL",
		"  OUT 0x21, AL",
		"  OUT 0xA1, AL",
		"  MOV AL, 0x34",
		"  OUT 0x43, AL",
		"  MOV AL, 0x02",
		"  OUT 0x40, AL",
		"  XOR AL, AL",
		"  OUT 0x40, AL",
		"  STI",
		"WAIT_IRQ:",
		"  CMP BYTE [IRQ_FLAG], 1",
		"  JNE WAIT_IRQ",
		"  MOV SI, PASS_MSG",
		"  CALL PRINT_STRING",
		"HANG:",
		"  HLT",
		"  JMP HANG",
		"IRQ0_HANDLER:",
		"  MOV BYTE [IRQ_FLAG], 1",
		"  MOV AL, 0x20",
		"  OUT 0x20, AL",
		"  IRET",
		"PRINT_STRING:",
		"  MOV AL, [SI]",
		"  CMP AL, 0",
		"  JE PRINT_DONE",
		"  MOV AH, 0x0E",
		"  INT 0x10",
		"  INC SI",
		"  JMP PRINT_STRING",
		"PRINT_DONE:",
		"  RET",
		"IRQ0_VECTOR:",
		"  DW 0x0000, 0x0000",
		"IRQ_FLAG:",
		"  DB 0",
		"PASS_MSG:",
		'  DB "interrupt integration validation PASS", 13, 10, 0',
	}, "\n")
	return buildLoadedBootImage(config, "InterruptIntegrationValidation", kernelSource, {
		kernelOrigin = 0x0500,
		bootMessage = "interrupt integration validation",
	})
end

local function buildResetVectorValidation(config)
	local bootSource = buildTextValidationBootSource("reset vector validation PASS")
	return buildStandaloneBootImage(config, "ResetVectorValidation", bootSource)
end

local function buildVgaTextValidation(config)
	local source = table.concat({
		"ORG 0x7C00",
		"START:",
		"  MOV AX, 0x0003",
		"  INT 0x10",
		"  MOV AX, 0xB800",
		"  MOV DS, AX",
		"  XOR DI, DI",
		"  MOV SI, TEXT_MSG",
		"TEXT_LOOP:",
		"  MOV AL, [SI]",
		"  CMP AL, 0",
		"  JE HANG",
		"  MOV [DI], AL",
		"  INC DI",
		"  MOV BYTE [DI], 0x1E",
		"  INC DI",
		"  INC SI",
		"  JMP TEXT_LOOP",
		"HANG:",
		"  HLT",
		"  JMP HANG",
		"TEXT_MSG:",
		'  DB "VGA 03h TEXT VALIDATION", 0',
		"PADTO 0x7DFE, 0",
		"DW 0xAA55",
	}, "\n")
	return buildStandaloneBootImage(config, "VgaTextValidation", source)
end

local function buildVgaMode13Validation(config)
	local source = table.concat({
		"ORG 0x7C00",
		"START:",
		"  MOV AX, 0x0013",
		"  INT 0x10",
		"  MOV AX, 0xA000",
		"  MOV DS, AX",
		"  XOR DI, DI",
		"  XOR BX, BX",
		"FILL_LOOP:",
		"  MOV AL, BL",
		"  MOV [DI], AL",
		"  INC DI",
		"  INC BL",
		"  CMP DI, 0xFA00",
		"  JNE FILL_LOOP",
		"HANG:",
		"  HLT",
		"  JMP HANG",
		"PADTO 0x7DFE, 0",
		"DW 0xAA55",
	}, "\n")
	return buildStandaloneBootImage(config, "VgaMode13Validation", source)
end

local function buildVgaPlanarValidation(config)
	local source = table.concat({
		"ORG 0x7C00",
		"START:",
		"  MOV AX, 0x000D",
		"  INT 0x10",
		"  MOV DX, 0x03C4",
		"  MOV AL, 0x02",
		"  OUT DX, AL",
		"  INC DX",
		"  MOV AL, 0x0F",
		"  OUT DX, AL",
		"  MOV DX, 0x03CE",
		"  MOV AL, 0x08",
		"  OUT DX, AL",
		"  INC DX",
		"  MOV AL, 0xFF",
		"  OUT DX, AL",
		"  MOV AX, 0xA000",
		"  MOV DS, AX",
		"  XOR DI, DI",
		"  MOV CX, 8000",
		"  MOV AL, 0xAA",
		"PLANAR_LOOP:",
		"  MOV [DI], AL",
		"  INC DI",
		"  LOOP PLANAR_LOOP",
		"HANG:",
		"  HLT",
		"  JMP HANG",
		"PADTO 0x7DFE, 0",
		"DW 0xAA55",
	}, "\n")
	return buildStandaloneBootImage(config, "VgaPlanarValidation", source)
end

local function buildVgaFontValidation(config)
	local source = table.concat({
		"ORG 0x7C00",
		"START:",
		"  MOV AX, 0x0003",
		"  INT 0x10",
		"  MOV DX, 0x03C4",
		"  MOV AL, 0x02",
		"  OUT DX, AL",
		"  INC DX",
		"  MOV AL, 0x04",
		"  OUT DX, AL",
		"  MOV DX, 0x03CE",
		"  MOV AL, 0x04",
		"  OUT DX, AL",
		"  INC DX",
		"  MOV AL, 0x02",
		"  OUT DX, AL",
		"  DEC DX",
		"  MOV AL, 0x06",
		"  OUT DX, AL",
		"  INC DX",
		"  MOV AL, 0x00",
		"  OUT DX, AL",
		"  MOV AX, 0xA000",
		"  MOV DS, AX",
		"  MOV DI, 0x0820",
		"  MOV CX, 16",
		"FONT_LOOP:",
		"  MOV AL, 0x18",
		"  MOV [DI], AL",
		"  INC DI",
		"  LOOP FONT_LOOP",
		"  MOV AX, 0x0003",
		"  INT 0x10",
		"  MOV AX, 0xB800",
		"  MOV DS, AX",
		"  MOV BYTE [0], 'A'",
		"  MOV BYTE [1], 0x1F",
		"HANG:",
		"  HLT",
		"  JMP HANG",
		"PADTO 0x7DFE, 0",
		"DW 0xAA55",
	}, "\n")
	return buildStandaloneBootImage(config, "VgaFontValidation", source)
end

local function buildVgaPaletteValidation(config)
	local source = table.concat({
		"ORG 0x7C00",
		"START:",
		"  MOV AX, 0x0013",
		"  INT 0x10",
		"  MOV DX, 0x03C8",
		"  XOR AL, AL",
		"  OUT DX, AL",
		"  INC DX",
		"  MOV AL, 0x3F",
		"  OUT DX, AL",
		"  XOR AL, AL",
		"  OUT DX, AL",
		"  XOR AL, AL",
		"  OUT DX, AL",
		"  MOV AX, 0xA000",
		"  MOV DS, AX",
		"  XOR DI, DI",
		"  MOV CX, 0xFA00",
		"  XOR AL, AL",
		"PALETTE_LOOP:",
		"  MOV [DI], AL",
		"  INC DI",
		"  LOOP PALETTE_LOOP",
		"HANG:",
		"  HLT",
		"  JMP HANG",
		"PADTO 0x7DFE, 0",
		"DW 0xAA55",
	}, "\n")
	return buildStandaloneBootImage(config, "VgaPaletteValidation", source)
end

local function mergeSymbols(...)
	local out = {}
	for _, symbolTable in ipairs({ ... }) do
		for name, value in pairs(symbolTable or {}) do
			out[name] = value
		end
	end
	return out
end

local function buildProtectedModeBringUp(config)
	local x86 = config.X86 or {}
	local layout = {
		kernelSectorStart = 2,
		kernelSectorCount = 1,
		fsSuperSector = 0,
		rootDirSector = 0,
		rootDirSectorCount = 0,
		dataStartSector = 0,
		fileCount = 0,
	}

	local stubArtifact
	local monitorArtifact
	local kernelBytes
	local kernelSymbols
	local bootSource
	local kernelLoadLinear = (x86.KERNEL_LOAD_SEG or 0x1000) * 16
	for _ = 1, 4 do
		local placeholderStub =
			Assembler8086.compile(buildProtectedModeStubSource(config, 0, kernelLoadLinear, kernelLoadLinear))
		local pmOffset = #placeholderStub.bytes
		local provisionalStub =
			Assembler8086.compile(buildProtectedModeStubSource(config, pmOffset, kernelLoadLinear, kernelLoadLinear))
		local gdtOffset = provisionalStub.symbols and provisionalStub.symbols.GDT or 0
		local gdtLinear = kernelLoadLinear + gdtOffset
		stubArtifact =
			Assembler8086.compile(buildProtectedModeStubSource(config, pmOffset, kernelLoadLinear, gdtLinear))
		pmOffset = #stubArtifact.bytes
		if pmOffset ~= #placeholderStub.bytes then
			stubArtifact = Assembler8086.compile(
				buildProtectedModeStubSource(
					config,
					pmOffset,
					kernelLoadLinear,
					kernelLoadLinear + (stubArtifact.symbols and stubArtifact.symbols.GDT or 0)
				)
			)
			pmOffset = #stubArtifact.bytes
		end
		monitorArtifact = Assembler8086.compile(buildProtectedModeMonitorSource(), {
			origin = pmOffset,
			defaultOperand32 = true,
		})
		kernelBytes = concatBytes(stubArtifact.bytes, monitorArtifact.bytes)
		kernelSymbols = mergeSymbols(stubArtifact.symbols, monitorArtifact.symbols)
		layout.kernelSectorCount = sectorCountForBytes(kernelBytes)

		local kernelCHS = encodeCHSWord(x86, layout.kernelSectorStart)
		local _, kernelHead = sectorToCHS(x86, layout.kernelSectorStart)
		bootSource = table.concat({
			"ORG 0x7C00",
			"START:",
			"  CLI",
			"  XOR AX, AX",
			"  MOV DS, AX",
			"  MOV SS, AX",
			"  MOV SP, 0x7C00",
			"  MOV [BOOT_DRIVE], DL",
			"  MOV SI, BOOT_MSG",
			"  CALL PRINT_STRING",
			"  MOV AX, " .. hex16(x86.KERNEL_LOAD_SEG or 0x1000),
			"  MOV ES, AX",
			"  MOV BX, 0x0000",
			"  MOV AX, " .. hex16(bit32.bor(0x0200, layout.kernelSectorCount)),
			"  MOV CX, " .. hex16(kernelCHS),
			"  MOV DX, " .. hex16(bit32.bor((x86.BOOT_DRIVE or 0x80), bit32.lshift(kernelHead, 8))),
			"  MOV DL, [BOOT_DRIVE]",
			"  INT 0x13",
			"  JC LOAD_FAIL",
			"  PUSH " .. hex16(x86.KERNEL_LOAD_SEG or 0x1000),
			"  PUSH 0x0000",
			"  RETF",
			"LOAD_FAIL:",
			"  MOV SI, LOAD_FAIL_MSG",
			"  CALL PRINT_STRING",
			"BOOT_HANG:",
			"  HLT",
			"  JMP BOOT_HANG",
			"PRINT_STRING:",
			"  MOV AL, [SI]",
			"  CMP AL, 0",
			"  JE PRINT_DONE",
			"  MOV AH, 0x0E",
			"  INT 0x10",
			"  INC SI",
			"  JMP PRINT_STRING",
			"PRINT_DONE:",
			"  RET",
			"BOOT_DRIVE:",
			"  DB 0",
			"BOOT_MSG:",
			'  DB "Loading boot image...", 13, 10, 0',
			"LOAD_FAIL_MSG:",
			'  DB "Boot image read failure", 13, 10, 0',
			"PADTO 0x7DFE, 0",
			"DW 0xAA55",
		}, "\n")
		local bootArtifact = Assembler8086.compile(bootSource)
		if #bootArtifact.bytes <= 512 then
			break
		end
	end

	local biosArtifact = BiosRom.buildArtifact(config)
	assert(type(bootSource) == "string", "external boot sector source was not generated")
	assert(type(kernelBytes) == "table", "external kernel image was not generated")
	local bootArtifact = Assembler8086.compile(bootSource)
	assert(#bootArtifact.bytes <= 512, "external boot sector exceeds 512 bytes")

	local sectors = {}
	local bootSector = {}
	for index = 1, 512 do
		bootSector[index] = bootArtifact.bytes[index] or 0
	end
	sectors[0] = bootSector
	writeChunk(sectors, layout.kernelSectorStart - 1, kernelBytes or {})

	return {
		name = "ProtectedModeBringUp",
		romBytes = BiosRom.buildROMBytes(config, biosArtifact),
		sectors = sectors,
		layout = layout,
		files = {},
		symbols = {
			bios = biosArtifact.symbols,
			bootSector = bootArtifact.symbols,
			stub = stubArtifact and stubArtifact.symbols or {},
			monitor = monitorArtifact and monitorArtifact.symbols or {},
			kernel = kernelSymbols or {},
		},
	}
end

BootImageCatalog.ProtectedModeBringUp = {
	name = "ProtectedModeBringUp",
	build = buildProtectedModeBringUp,
}

BootImageCatalog.ResetVectorValidation = {
	name = "ResetVectorValidation",
	build = buildResetVectorValidation,
}

BootImageCatalog.BiosBootValidation = {
	name = "BiosBootValidation",
	build = buildBiosBootValidation,
}

BootImageCatalog.InterruptIntegrationValidation = {
	name = "InterruptIntegrationValidation",
	build = buildInterruptIntegrationValidation,
}

BootImageCatalog.CpuProtectedModeValidation = {
	name = "CpuProtectedModeValidation",
	build = buildCpuProtectedModeValidation,
}

BootImageCatalog.CpuExceptionValidation = {
	name = "CpuExceptionValidation",
	build = buildCpuExceptionValidation,
}

BootImageCatalog.PrivilegeTransitionValidation = {
	name = "PrivilegeTransitionValidation",
	build = buildPrivilegeTransitionValidation,
}

BootImageCatalog.VgaTextValidation = {
	name = "VgaTextValidation",
	build = buildVgaTextValidation,
}

BootImageCatalog.VgaMode13Validation = {
	name = "VgaMode13Validation",
	build = buildVgaMode13Validation,
}

BootImageCatalog.VgaPlanarValidation = {
	name = "VgaPlanarValidation",
	build = buildVgaPlanarValidation,
}

BootImageCatalog.VgaFontValidation = {
	name = "VgaFontValidation",
	build = buildVgaFontValidation,
}

BootImageCatalog.VgaPaletteValidation = {
	name = "VgaPaletteValidation",
	build = buildVgaPaletteValidation,
}

return BootImageCatalog
