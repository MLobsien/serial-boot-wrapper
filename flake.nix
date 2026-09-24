{
  description = "EFI wrapper to mirror systemd-boot output to serial console";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        serialBoot = pkgs.callPackage ./nix/serial-boot.nix {};
        gnuEfiMs = pkgs.callPackage ./nix/gnu-efi-ms.nix {};
      in
      {
        packages = {
          default = serialBoot;
          serial-boot = serialBoot;
          gnu-efi-msabi = gnuEfiMs;
        };

        checks = {
          default = serialBoot;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            gnu-efi
            gcc
            binutils
          ];
        };
      }
    ) // {
      nixosModules.default = ./module.nix;
      nixosModules.serial-boot = ./module.nix;
    };
}
