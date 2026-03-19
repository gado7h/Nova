# ⚙️ Machina

[![Language](https://img.shields.io/badge/language-Luau-00A2FF?style=flat-square)](https://luau-lang.org/)
[![Platform](https://img.shields.io/badge/platform-Roblox-E2231A?style=flat-square)](https://www.roblox.com/)
[![Status](https://img.shields.io/badge/status-active-brightgreen?style=flat-square)]()

Machina is an IBM PC–compatible computer emulator implemented in Luau and running inside Roblox.

The project models a complete system at the hardware level, including CPU execution, memory mapping, system bus communication, and common PC peripherals. It is designed for experimentation, education, and low-level systems exploration within the constraints of the Roblox engine.

The CPU implementation begins with an 8086-compatible core and extends toward 80386 features, including 32-bit registers, descriptor tables, and protected mode support. The current runtime profile targets a BIOS-driven boot process starting from the reset vector (`F000:FFF0`) in real mode.

System components are connected through a simulated bus and include RAM, ROM, VGA, disk controllers, interrupt controllers, timers, and input devices. Memory-mapped I/O and port-mapped I/O are both supported, following conventional PC layouts.

A runtime-assembled BIOS initializes the system, provides interrupt services (video, disk, keyboard, clock), and loads a boot sector into memory. Disk images can be constructed or imported and are used to drive the boot process and kernel loading.

Rendering is handled through a virtual VGA device with text and pixel modes, displayed via Roblox UI primitives. Input is translated into hardware-level keyboard signals, and system state can be observed through a live interface.

MachinaOS is the default environment, providing a minimal operating system layer for interacting with the emulated hardware and experimenting with low-level software.
