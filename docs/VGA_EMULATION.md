# VGA Emulation Status

## Scope

`src/platforms/x86/devices/VgaAdapter.luau` now models VGA as a register-driven device instead of a direct Luau drawing surface.

The active implementation covers:

- VGA aperture mapping across `0xA0000-0xBFFFF`
- sequencer, graphics controller, attribute controller, CRTC, misc-output, and DAC port surfaces
- text mode memory at `0xB8000`
- chain-4 `320x200x256` graphics for mode `13h`
- planar `320x200x16` graphics rendering
- DAC palette read/write behavior
- attribute-palette selection
- hardware cursor rendering from CRTC registers
- text blinking vs. background-intensity semantics
- input-status register behavior that resets the attribute-controller flip-flop

## Guest-Visible Modes

The BIOS-facing path is currently set up for these video modes:

- `03h`: `80x25` text mode
- `0Dh`, `0Eh`, `10h`: planar `320x200x16` graphics class
- `13h`: chain-4 `320x200x256`

The host display surface is `640x400`.

- text mode is rasterized as `80x25` cells with `8x16` output cells
- `320x200` graphics modes are scan-doubled to `640x400`

## Host Integration

Host-side fault and diagnostics text no longer use guest VRAM writes directly.

Instead, the VGA device exposes a narrow host-only overlay path:

- `hostClear`
- `hostWrite`
- `hostWriteLine`
- `clearHostOverlay`

This overlay is intentionally out-of-band from the guest hardware state so emulator faults can still be shown even when guest VGA state is invalid.

## Current Limitations

The device is much closer to real VGA semantics, but it is not yet a full cycle-accurate VGA.

Known limitations:

- The character ROM is still an approximated built-in font, not a dumped IBM VGA font ROM.
- Only the core VGA register banks used by text mode, planar graphics, and mode `13h` are modeled today.
- Full CRTC timing is not yet simulated beyond scanout pacing and the input-status retrace bit.
- No light pen, feature connector, or analog-monitor timing model is present.
- Font upload behavior through plane `2` is not modeled yet.
- Chain-4 graphics and planar write modes are implemented for practical guest compatibility, but not every edge-case interaction has been validated against hardware references yet.
- No VGA IRQ is generated, which is acceptable for baseline VGA behavior in the current machine model.

## Recommended Validation

The current diagnostics should verify:

- text memory writes at `0xB8000`
- cursor register behavior
- DAC read/write sequencing
- mode `13h` linear byte access

Future validation should add:

- planar write-mode compliance tests
- attribute-controller palette tests
- font-plane upload tests
- CRTC start-address and panning tests
- external VGA compatibility ROM or demo test cases
