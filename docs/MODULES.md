# Module Documentation

## Entry Points

- `src/Host.client.luau`
  - Creates the GUI surface and editable image used for rendering the guest screen.
  - Instantiates `platforms/x86/PcSystem.luau` which builds the emulated board and devices.
  - Starts or reboots machine lifecycle via the PcSystem API.
- `src/net_bridge/Main.server.luau`
  - Server bootstrap and remote/datastore orchestration for saving/loading HDD snapshots and syncing machine state.

## Core Machine (platforms/x86)

- `src/platforms/x86/PcSystem.luau`
  - Central PC system wrapper: builds hardware devices, configures board parameters, and manages power/heartbeat/boot stages.
  - Exposes runtime controls (powerOn, shutdown, reboot, bindInput) and statistics (getStats, getBootStage).

- `src/platforms/x86/BootController.luau`
  - Drives BIOS -> boot sector -> protected-mode bring-up sequencing and loads boot artifacts into HDD/ROM.

- `src/platforms/x86/BootImageCatalog.luau`
  - Generates boot sector, protected-mode stub/monitor and BIOS ROM bytes used by the BootController.

- `src/platforms/x86/ProtectedModeSelfTest.luau`
  - Utility to validate protected-mode entry sequences against the CPU/memory implementation.

## Hardware / Devices (examples)

- `src/platforms/x86/devices/SystemBus.luau` – bus and device registration/dispatch.
- `src/platforms/x86/devices/PhysicalMemory.luau` – physical RAM abstraction.
- `src/platforms/x86/devices/FirmwareRom.luau` – BIOS ROM image flashing/reading.
- `src/platforms/x86/devices/VgaAdapter.luau` – text framebuffer and editable image integration.
- `src/platforms/x86/devices/AtaController.luau` – HDD sector interface.
- `src/platforms/x86/devices/I8042Controller.luau` – keyboard scancode handling.

## Server Services

- `src/net_bridge/network/NetworkService.luau`
  - Creates MachinaNet remotes for save/load/sync operations between client and server.
- `src/net_bridge/datastore/HDDStore.luau`
  - Persists virtual HDD snapshots in Roblox DataStore keyed by player.

## Notes

Files and module paths have been reorganized around `src/platforms/x86` and `src/net_bridge` (client GUI/host integration is now `Host.client.luau`). This document focuses on the modules currently present under `src/platforms/x86` and the `net_bridge` server adapter.
