# VGA Emulation Status

## Scope

`src/platforms/x86/devices/VgaAdapter.luau` models the active x86 display as a guest-visible VGA device instead of only a direct Luau drawing surface.

The current implementation covers:

- VGA aperture mapping across `0xA0000-0xBFFFF`
- text memory at `0xB8000`
- attribute controller, sequencer, graphics controller, CRTC, misc-output, and DAC port surfaces
- BIOS-facing mode switching for `03h`, planar graphics modes, and `13h`
- DAC palette read/write sequencing
- hardware cursor state from CRTC registers
- host-side overlay rendering for emulator faults and diagnostics

## Guest-Visible Modes

The active BIOS path is currently wired for:

- `03h`: `80x25` text mode
- `0Dh`, `0Eh`, `10h`: planar graphics class
- `13h`: `320x200x256`

The host surface is `640x400`:

- text mode is rasterized as `80x25` cells with `8x16` output cells
- `320x200` graphics modes are scan-doubled to `640x400`

## Host Integration

Host-side emulator messages do not directly mutate guest VGA state.

Instead, the device exposes a narrow host-only overlay API:

- `hostClear`
- `hostWrite`
- `hostWriteLine`
- `clearHostOverlay`

This keeps emulator faults visible even when guest VGA state is invalid.

## Current Limitations

The adapter is much closer to a hardware-facing VGA path than the older pseudo-console version, but it is not yet a full cycle-accurate VGA.

Known limitations:

- The glyph ROM is still an approximated built-in font rather than a dumped IBM VGA font ROM.
- Register coverage is focused on the mode/control surfaces needed by the current x86 boot path.
- Full CRTC timing is not cycle-accurate beyond frame pacing and a simple retrace bit.
- Planar write behavior is simplified compared with full VGA write-mode edge cases.
- Font upload through plane `2` is not implemented yet.
- No VGA IRQ is generated in the current machine model.

## Recommended Validation

Useful validation for the current implementation:

- text writes at `0xB8000`
- CRTC cursor register behavior
- DAC read/write sequencing
- mode `13h` byte access through the VGA aperture

Future validation should add:

- planar write-mode compliance tests
- attribute-controller palette tests
- font-plane upload tests
- CRTC start-address and panning tests
