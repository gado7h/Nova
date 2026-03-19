# Machina

Machina is a Roblox-based virtual machine project written in Luau. It emulates a small computer stack including firmware, bootloader, kernel, virtual filesystem, and userland shell.

## Features

- Simulated hardware: CPU, RAM, ROM, bus, HDD, keyboard, and GPU.
- Firmware POST and staged boot flow.
- Kernel subsystems for memory, process management, syscalls, and VFS (guest-side modules if present).
- Basic userland init/shell and package-management modules (guest).
- Tools for generating boot artifacts (assembler + BIOS ROM builders) and protected-mode bring-up stubs.

## Project Layout (relevant files)

- `src/Host.client.luau` – client entry point and GUI boot surface that instantiates PcSystem.
- `src/platforms/x86/` – platform-specific PC implementation and device modules (PcSystem, BootController, Cpu80386, devices/*).
- `src/net_bridge/` – server/client bridging code for network remotes and datastore persistence (Main.server.luau, network, datastore).

## Development

### Requirements

- [Rokit](https://github.com/rojo-rbx/rokit)
- [Rojo](https://rojo.space/) for Roblox syncing

### Common workflow

1. Install toolchain dependencies (via `rokit` and your local setup).
2. Open the project in Roblox Studio.
3. Sync source with Rojo.
4. Run the game and observe the Machina boot sequence (the client GUI is created by `src/Host.client.luau`).

## Style

Luau files are aligned to Lua style-guide conventions:

- clear naming and short, relevant comments
- minimal header comments
- consistent spacing and table/function formatting

References:

- https://roblox.github.io/lua-style-guide/
- https://github.com/Olivine-Labs/lua-style-guide

## Documentation

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/MODULES.md`](docs/MODULES.md) for architecture and module-level documentation.
