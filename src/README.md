# Machine Layout

This tree contains only the active x86 emulator.

- `Config.luau`: top-level machine and x86 board configuration
- `Main.client.luau`: Roblox client entry point and display wiring
- `platforms/x86/`: x86 platform code
  `PcSystem`, `Cpu8086`, `Cpu80386`, `Assembler8086`, `BiosRom`, `BiosInterrupts`, `BootController`, `BootImageCatalog`, `BootImageLoader`, `ImportedImageCatalog`, `RawImageCatalog`, `HardwareDiagnostics`, and `ProtectedModeSelfTest`
- `platforms/x86/devices/`: x86 devices and buses
  `SystemBus`, `PhysicalMemory`, `FirmwareRom`, `VgaAdapter`, `AtaController`, `Pic8259`, `Pit8254`, `I8042Controller`, `CmosRtc`, and `Uart8250`

The intended read order is:

1. `Main.client.luau`
2. `platforms/x86/PcSystem.luau`
3. `platforms/x86/BootController.luau`
4. `platforms/x86/Cpu80386.luau`
5. `platforms/x86/devices/`
