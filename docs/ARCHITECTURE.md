# Machina Architecture

## Boot Pipeline

1. `src/Host.client.luau` creates the display surface and instantiates the PC system (PcSystem).
2. `src/platforms/x86/PcSystem.luau` wires physical devices and builds the board configuration.
3. `src/platforms/x86/BootController.luau` drives BIOS -> bootloader -> kernel transitions (via BootImageCatalog artifacts).
4. `kernel/*` (guest code) initializes core subsystems once the kernel image is loaded.
5. `userland/*` starts shell and user workflows inside the guest.

## Layers

### Hardware Layer

`src/platforms/x86/*` emulates machine devices and data transport:

- `Bus` coordinates memory-mapped/port I/O and IRQ flow (implemented in the platform device bus modules).
- `CPU` executes machine instructions and timing (see `Cpu80386` in `platforms/x86`).
- `RAM` and `ROM` provide volatile/non-volatile memory (PhysicalMemory / FirmwareRom).
- `HDD` stores disk sectors and filesystem data (AtaController/HDD integration).
- `GPU` manages pixel/text output to the Roblox screen surface (VgaAdapter + editable image integration).
- `Keyboard` converts Roblox input to scancodes (I8042Controller).


### Software Runtime Layer

Platform-specific runtime modules own bring-up and runtime concerns:

- `BootController` advances boot stages (BIOS -> BOOT -> KERNEL -> RUNNING) and instantiates BIOS/boot artifacts.
- Boot images are produced/loaded via `BootImageCatalog` and related assembler/ROM helpers.


### Firmware + Boot

- `BiosInterrupts` and BIOS ROMs handle startup diagnostics and interrupt hooks.
- Bootloader artifacts (boot sector + protected-mode bring-up) are generated and loaded from disk sectors.


### Kernel Layer

- Kernel subsystems run once a kernel image is loaded into guest memory. The repository contains boot/runtime scaffolding in `platforms/x86` to load and hand off control to guest code.


### Userland + Packages

- Userland shells and managed runtimes are guest components launched by the kernel once the kernel has initialized drivers and the VFS.


### LuauVM

- Some workflows in the project surface a managed Luau runtime for higher-level guest programs; the VM/runtime glue may live in separate modules when present.

## Data Flow Summary

- Input: Roblox keyboard events -> keyboard device -> IRQ/syscall path into guest firmware/kernel.
- Compute: CPU executes guest instructions; scheduler (guest) selects runnable processes.
- Storage: VFS operations -> HDD sector/block updates (host-side code persists sectors into AtaController/hdd image).
- Output: kernel/userland text/video writes -> GPU framebuffer -> editable image updated on the Roblox GUI.

## Server Services

- `src/net_bridge/Main.server.luau` initializes server-only runtime services.
- Network service provisions remotes for machine state and HDD save/load.
- Datastore service persists HDD snapshots per player key (`src/net_bridge/datastore/HDDStore.luau`).
