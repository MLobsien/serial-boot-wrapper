# NixOS module for serial-boot-wrapper
# Adds the serial-boot EFI wrapper to systemd-boot
#
# All UART and loader parameters map to the package's build-time
# configuration (see nix/serial-boot.nix). Changing any option rebuilds
# the wrapper with different firmware-side line settings.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.boot.loader.systemd-boot.serialBoot;

  serialBootPackage = let
    args = {
      inherit (cfg) uartBase baudRate uartClock dataBits parity stopBits loaderPath bootTitle;
    };
    # Filter out null values so unspecified options use package defaults
    filtered = filterAttrs (_: v: v != null) args;
  in
    pkgs.callPackage ./nix/serial-boot.nix filtered;

  entryFile = cfg.entryName;
in {
  options.boot.loader.systemd-boot.serialBoot = {
    enable = mkEnableOption "serial-boot wrapper for systemd-boot";

    uartBase = mkOption {
      type = types.int;
      default = 1016; # 0x3F8 = COM1
      description = ''
        Base I/O port of the 16550-compatible UART.
        Common values: 0x3F8 (1016, COM1), 0x2F8 (760, COM2),
        0x3E8 (1000, COM3), 0x2E8 (744, COM4).
      '';
    };

    baudRate = mkOption {
      type = types.int;
      default = 115200;
      description = ''
        UART baud rate. Must divide uartClock divisibly by 16
        (validated at evaluation time).
      '';
    };

    uartClock = mkOption {
      type = types.int;
      default = 1843200;
      description = ''
        Input clock of the UART in Hz. Standard PC UARTs use 1843200.
      '';
    };

    dataBits = mkOption {
      type = types.int;
      default = 8;
      description = "Data bits: 5 to 8.";
    };

    parity = mkOption {
      type = types.enum ["none" "odd" "even"];
      default = "none";
      description = "Parity mode.";
    };

    stopBits = mkOption {
      type = types.int;
      default = 1;
      description = "Stop bits: 1 or 2.";
    };

    loaderPath = mkOption {
      type = types.str;
      default = "\\EFI\\systemd\\systemd-bootx64.efi";
      description = ''
        Windows-style (backslash separated) path of the real loader ELF
        binary on the ESP relative to the volume root. The wrapper chain-
        loads this file from the volume the wrapper itself was launched from.
      '';
    };

    bootTitle = mkOption {
      type = types.str;
      default = "Serial console (systemd-boot)";
      description = "Title used for the systemd-boot entry created by this module.";
    };

    entryName = mkOption {
      type = types.str;
      default = "serial-boot.conf";
      description = "File name of the created systemd-boot entry.";
    };

    createTestEntry = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the module should add a systemd-boot entry for the wrapper.
      '';
    };

    setDefault = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Make the wrapper entry the default systemd-boot boot target.

        The upstream builder hardcodes "default <newest NixOS generation>"
        into loader.conf on every switch and offers no option to change
        it, so this installs an extra install command that swaps that
        single known line for the wrapper entry, preserving all other
        loader.conf settings. It only ever matches the exact
        builder-generated line and aborts if it is absent.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Add the serial-boot wrapper to systemd-boot extra files
    boot.loader.systemd-boot.extraFiles."EFI/serial-boot/serial-bootx64.efi" = "${serialBootPackage}/EFI/serial-boot/serial-bootx64.efi";

    # Create a boot entry for the wrapper
    boot.loader.systemd-boot.extraEntries = mkIf cfg.createTestEntry {
      ${entryFile} = ''
        title ${cfg.bootTitle}
        efi /EFI/serial-boot/serial-bootx64.efi
      '';
    };
    # The upstream builder (systemd-boot-builder.py) writes exactly one
    # default line of the form "default nixos-generation-<N>.conf"
    # (optionally with a specialisation suffix) on every switch. Make the
    # wrapper entry the default by replacing that line with the wrapper
    # entry, leaving all other loader.conf lines untouched.
    #
    # The generation number is only known at switch time, so the script
    # reads the exact current default line (anchored to the builder's
    # known "default nixos-generation-" prefix), splits it from the rest
    # of the file, and rewrites the file as:
    #   default ${entryFile} \n <everything else>
    # using only exact literals, no regex substitution.
    boot.loader.systemd-boot.extraInstallCommands = mkIf cfg.setDefault ''
      ${pkgs.gnused}/bin/sed -i "s|^default nixos-generation-.*|default ${entryFile}|" "${config.boot.loader.efi.efiSysMountPoint}/loader/loader.conf"
    '';
  };
}
