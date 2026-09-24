# serial-boot-wrapper

EFI wrapper to mirror systemd-boot output to a serial console.

## What this does

This application initializes a 16550-compatible UART at I/O port `0x3F8` (115200 8N1) and proxies all EFI console output to both the screen and the serial port. It then chain-loads the existing systemd-boot binary.

## What it does not do

- It does not make the ASUS BIOS/UEFI POST output appear on serial
- It does not configure Linux `ttyS0`
- It does not replace the kernel serial-console configuration

## Target Hardware

- **Motherboard**: ASUS TUF Gaming Z690-PLUS
- **BIOS**: AMI 5.27, BIOS version 2204
- **Firmware**: UEFI 2.80
- **Architecture**: x86_64
- **Secure Boot**: disabled
- **OS**: NixOS
- **Current bootloader**: systemd-boot 260.2
- **ESP**: mounted at `/boot`

## Why normal `loader.conf` cannot configure the legacy UART

The ASUS firmware exposes the COM port as a legacy UART/Super-I/O resource, but does not expose it as a UEFI `ConOut` serial console. The `ConOut` EFI variable does not exist, and `loader.conf` has no option to configure a legacy UART.

This wrapper bridges the gap by:
1. Directly programming the 16550 UART via x86 `inb`/`outb` instructions
2. Installing a proxy `EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL` that mirrors output to the serial port
3. Chain-loading the existing systemd-boot binary

## Building

### Prerequisites

- Nix with flakes enabled
- For cross-compilation: `pkgsCross.x86_64-unknown-uefi`

### Build command

```bash
nix build
```

The output will be at `result/EFI/serial-boot/serial-bootx64.efi`.

### Configuration

All UART and loader parameters are Nix arguments of the package and are
compiled into the EFI binary through a generated `config.h`. Build a
variant with `nix repl`, a callPackage-style expression, or directly:

```bash
nix build --impure --expr 'let
  flake = builtins.getFlake "github:MLobsien/serial-boot-wrapper";
in flake.packages.x86_64-linux.serial-boot.override {
  uartBase = 760;        # 0x2F8 = COM2 (760). COM1 = 1016 = 0x3F8
  baudRate = 9600;
  uartClock = 1843200;   # standard UART clock; must be divisible by 16*baudRate
  dataBits = 8;          # 5..8
  parity = "even";       # "none", "odd", "even"
  stopBits = 1;          # 1 or 2
  loaderPath = "\\EFI\\systemd\\systemd-bootx64.efi";
  bootTitle = "Serial console";
}'
```

All options have sensible defaults (COM1, 115200 8N1, systemd-boot path).
Misconfigurations (indivisible baud, bad data bits, unknown parity) are
rejected at evaluation time, before a binary is ever built. Different
terminal wiring therefore only needs a different package override, not a
source change.

### Validate the binary

```bash
file result/EFI/serial-boot/serial-bootx64.efi
```

Expected output: `result/EFI/serial-boot/serial-bootx64.efi: PE32+ executable (EFI application) x86-64 (for MS Windows)`

## Installation

### NixOS Configuration

Add the serial-boot module to your NixOS configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    serial-boot.url = "github:your-username/serial-boot-wrapper";
  };

  outputs = { self, nixpkgs, serial-boot, ... }: {
    nixosConfigurations.your-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        serial-boot.nixosModules.default
        {
          boot.loader.systemd-boot.serialBoot = {
            enable = true;
            # All options are optional; wire them to your hardware:
            # uartBase = 1016;    # 0x3F8 COM1 (default)
            # baudRate = 115200;
            # parity = "none";
            # dataBits = 8;
            # stopBits = 1;
            # createTestEntry = true;  # adds a boot entry for the wrapper
          };
        }
      ];
    };
  };
}
```

Module options: `uartBase`, `baudRate`, `uartClock`, `dataBits`, `parity`,
`stopBits` (all map directly to the package build parameters above), plus
`loaderPath`, `bootTitle`, `entryName` and `createTestEntry` for the
systemd-boot integration.

### Manual Installation

1. Build the wrapper:
   ```bash
   nix build
   ```

2. Copy to ESP:
   ```bash
   sudo mkdir -p /boot/EFI/serial-boot
   sudo cp result/EFI/serial-boot/serial-bootx64.efi /boot/EFI/serial-boot/
   ```

3. Create boot entry:
   ```bash
   sudo tee /boot/loader/entries/serial-boot.conf << EOF
   title Serial console (systemd-boot)
   efi /EFI/serial-boot/serial-bootx64.efi
   EOF
   ```

   (This is the same entry the NixOS module creates by default; the name
   matches the module's `entryName` default.)

## Testing

**Status: verified end-to-end in QEMU/OVMF; not yet tested on target
hardware.** The QEMU/OVMF harness boots the wrapper, which init's the UART,
chainloads systemd-boot via `LoadImage` with an explicit device path, and the
systemd-boot menu text appears on the serial console. Hardware behavior
(screen + serial mirroring on a real GPU/UART setup) still needs testing.
Keep the normal boot entry available until then.

### Hardware Test Procedure

1. Connect a serial terminal at the configured line parameters (default
   115200 8N1):
   ```bash
   picocom -b 115200 /dev/ttyUSB0
   ```

2. Reboot the machine

3. Select the "Serial console (systemd-boot)" entry from the boot menu

4. Expected serial output (default build):
   ```
   [serial-boot] wrapper started
   [serial-boot] UART initialized at 1016 (115200 baud)
   [serial-boot] loading loader...
   [serial-boot] starting loader...
   ```

   (The UART base is printed as a decimal number: 1016 = 0x3F8 = COM1.)

5. The serial terminal should then receive actual systemd-boot output/menu text

6. The screen should continue to show the normal systemd-boot interface

### Safety / Rollback

The test must not overwrite:
- `/EFI/BOOT/BOOTX64.EFI`
- `/EFI/systemd/systemd-bootx64.efi`

The existing boot entry must remain usable. If the wrapper crashes or fails, the user can select the existing NixOS/systemd-boot entry normally.

To remove the test configuration:
```bash
sudo rm /boot/loader/entries/serial-boot.conf
sudo rm -rf /boot/EFI/serial-boot
```

## Known Limitations

- The wrapper only mirrors EFI console output, not BIOS POST output
- Non-ASCII characters are replaced with `?` on the serial output
- The wrapper does not handle keyboard input from the serial port

## Technical Details

### UART Initialization

The 16550 UART is initialized with the line settings configured at build
time (see Configuration above). Defaults:
- Base I/O: 0x3F8
- Baud rate: 115200
- Data bits: 8
- Parity: none
- Stop bits: 1
- FIFO: enabled and cleared

A bounded poll on the transmitter-empty bit ensures a dead UART cannot
hang the boot.

### ConOut Proxy

The wrapper installs a proxy `EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL` that:
- Sends all output to both the serial port and the original console
- Handles CR/LF conversion for serial terminals
- Sends ANSI escape sequences for cursor positioning and screen clearing
- Preserves all other console operations

### Chain-loading

The wrapper:
1. Locates the ESP containing itself using `EFI_LOADED_IMAGE_PROTOCOL`
2. Builds an explicit device path for `\EFI\systemd\systemd-bootx64.efi`
   with `FileDevicePath()` (a memory-buffer `LoadImage` call would leave the
   new image without a `DeviceHandle`, which systemd-boot needs to open its
   volume and find menu entries)
3. Loads the image via `gBS->LoadImage()` with that device path
4. Installs the ConOut proxy
5. Starts the image using `gBS->StartImage()`

### gnu-efi MS-ABI build

The wrapper is compiled with `-DGNU_EFI_USE_MS_ABI` so every firmware-facing
call uses the Microsoft x64 calling convention. `nix/gnu-efi-ms.nix` rebuilds
gnu-efi from the nixpkgs source with that define forced on, stdenv hardening
disabled, and the `EFIAPI` marker restored on `efi_main` in `lib/entry.c`
(this keeps `_entry` a plain SysV function that hands firmware-provided
`rcx`/`rdx` arguments through a GCC-emitted calling-convention adapter into
`efi_main`). Using the stock nixpkgs gnu-efi with these flags produces a
wrapper that fails during `InitializeLib`.

## License

MIT
