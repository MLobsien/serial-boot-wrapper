# gnu-efi built with -DGNU_EFI_USE_MS_ABI so that all EFI-facing code paths
# use the Microsoft x64 calling convention consistently. The prebuilt gnu-efi
# libraries use the System V calling convention internally, which is fine for
# self-contained library code, but the wrapper we build must call firmware
# entry points (gBS->HandleProtocol, LoadImage, ...) with MS ABI argument
# registers. With the stock lib this works only if the application is built
# without the define; with the define (required for correct EFIAPI-typed
# function-pointer calls produced by the headers) the stock libfe's crt0 +
# _entry pass args through rdi/rsi while our efi_main expects rcx/rdx.
#
# Building gnu-efi itself with -DGNU_EFI_USE_MS_ABI keeps everything
# consistent: crt0 remains SysV and hands firmware (rcx, rdx) to _entry via
# rdi/rsi (SysV), _entry stays plain SysV, and efi_main is EFIAPI (ms_abi) -
# GCC converts automatically. Firmware-facing calls are direct MS-ABI calls.
{
  lib ? (import <nixpkgs> {}).lib,
  stdenv,
  gnu-efi,
}:
# Rebuild the same gnu-efi source from nixpkgs (identical code, known-good) but
# with the MS ABI define forced on so every firmware-facing call site is built
# with Microsoft x64 calling convention. See the long comment above.
stdenv.mkDerivation {
  pname = "gnu-efi-msabi";
  version = "4.0.2";

  src = gnu-efi.src;

  strictDeps = true;

  # Nix hardening flags (notably zerocallusedregs, which makes every
  # function zero caller-saved GPRs on return, and stack-protector) do not
  # belong in a freestanding UEFI library and change codegen vs. a plain
  # bare-metal build. Disable all of them.
  hardeningDisable = ["all"];

  # Force MS ABI on x86_64. The stock Makefile already sets this when the
  # host GCC is new enough; making it explicit is what our wrapper build
  # relies on (it passes -DGNU_EFI_USE_MS_ABI itself as well).
  postPatch = ''
    grep -n "GNU_EFI_USE_MS_ABI" Make.defaults
    # nixpkgs' gnu-efi source has efi_main declared without EFIAPI, so
    # _entry would call it with the SysV argument registers (rdi/rsi) while
    # our application's efi_main is EFIAPI (ms_abi, expecting rcx/rdx).
    # Restore the EFIAPI marker so GCC emits the calling-convention adapter.
    sed -i 's/extern EFI_STATUS efi_main(/extern EFI_STATUS EFIAPI efi_main(/' lib/entry.c
    grep -n "extern EFI_STATUS" lib/entry.c
  '';

  makeFlags = ["ARCH=x86_64"];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/include
    cp -r inc/* $out/include/
    cp x86_64/gnuefi/crt0-efi-x86_64.o $out/lib/
    cp gnuefi/elf_x86_64_efi.lds $out/lib/
    cp x86_64/gnuefi/libgnuefi.a $out/lib/
    cp x86_64/lib/libefi.a $out/lib/
    runHook postInstall
  '';

  meta = with lib; {
    description = "gnu-efi 4.0.2 built with GNU_EFI_USE_MS_ABI (MS x64 ABI throughout)";
    license = licenses.gpl3Plus;
    platforms = ["x86_64-linux"];
  };
}
