# Bluetooth Mic Mac repository instructions

## Mission

Help the user build, inspect and safely test the experimental Bluetooth HFP
drivers and installer in this repository. A short request such as "make it
work", "build it" or "prepare it for local testing" means: inspect the local
toolchain, build the Release x64 drivers, create or select a local test-signing
certificate, sign the packages, build the single-file installer and report the
result with verification evidence.

Do not interpret "make it work" as permission to install kernel drivers,
change boot configuration, disable Secure Boot or reboot the computer. Those
actions require explicit user intent.

This file is intended for users working in a public, read-only clone. Do not
create commits, tags, branches, remotes or releases. Do not push, upload,
publish or rewrite repository history. Leave source edits uncommitted for the
user to inspect. Locally generated files in ignored build directories are
allowed.

## Read first

Before changing or building anything, read:

1. `README.md`
2. `docs/ARCHITECTURE.md`
3. `THIRD_PARTY_NOTICES.md`

## Supported target

- Mac model: `MacBookPro16,1`
- UART hardware ID: `PCI\VEN_8086&DEV_A328&SUBSYS_72708086`
- Windows 10 version 1903 (build 18362) or later, x64; Windows 11 is included
- Original Apple Boot Camp/Broadcom Bluetooth devices must already exist and
  be healthy.

Never broaden an INF hardware match or bypass the installer's model and device
checks merely to make installation succeed. New hardware requires a separate,
explicit validation task.

## Standard build workflow

Run commands from the Git repository root in PowerShell.

1. `./scripts/Test-PublicTree.ps1`
2. `./scripts/Get-BuildTools.ps1`
3. If the required Visual Studio/SDK/WDK components are missing, name the exact
   missing prerequisite. Ask before installing system-wide tools.
4. For an unsigned build, run:
   `./scripts/Build-Drivers.ps1 -Configuration Release`
5. For the default local test build, create a new non-exportable certificate
   only when no suitable user-selected test certificate exists:
   `$cert = ./scripts/New-TestCertificate.ps1 -Subject 'Bluetooth Mic Mac Local Test'`
6. Build and sign everything:
   `./build-all.ps1 -Configuration Release -CertificateThumbprint $cert.Thumbprint -BuildInstaller`
7. Confirm that the two SYS files, two CAT files and installer have the expected
   signer thumbprint. Report the installer path, byte size and SHA-256.
8. Run `./scripts/Test-PublicTree.ps1` again.

Generated files belong only under ignored `artifacts`, `build`, `obj`, `x64`,
`Debug`, `Release` or `dist` directories. Do not move them into the source
tree or publish them automatically.

## Signing modes

- Default to local self-signed Test Mode only when the user asks for a locally
  usable build and has not requested production signing.
- Explain that Secure Boot must be disabled and Test Mode must remain active
  while locally signed kernel drivers are loaded.
- A commercial Authenticode signature alone is not a Microsoft production
  kernel signature.

## Installation safety

Building and signing are allowed as ordinary repository work. Before running
the generated installer or any command that changes drivers, certificates,
BCD/Test Mode, scheduled tasks or reboot state:

- identify the exact target machine and confirm it is supported;
- explain the expected restarts and Bluetooth-input risk;
- obtain explicit confirmation from the user;
- recommend a backup and a wired keyboard or mouse;
- keep the bounded recovery guard intact.

Do not install a newly modified kernel build merely to test whether it compiles.
Use static checks and build verification first.

## Privacy and repository hygiene

Never place in the source tree or expose:

- private keys, PFX/P12/PVK files or secret-store exports;
- generated CER/SYS/CAT/PDB/EXE/CAB files;
- crash dumps, ETL traces, event logs or audio recordings;
- local account names, email addresses, machine names, Bluetooth addresses;
- complete machine-specific PnP instance paths;
- certificate thumbprints copied from a local machine;
- absolute local user-profile paths.

Run `scripts/Test-PublicTree.ps1` before and after source edits. Treat a failure
as a stop condition, not as a check to bypass. Do not add exceptions for real
private data.

## Source ownership

Project-specific code is MIT-licensed. Files under
`vendor/windows-driver-samples` are a modified subset of Microsoft SysVAD and
remain under the included Microsoft Public License. Preserve notices and avoid
mechanically replacing vendor files with a different upstream revision.

## Verification after changes

- PowerShell changes: parse every `.ps1` and run the affected script in its
  non-installing mode.
- Driver/INF/project changes: perform a clean Release x64 build, run InfVerif,
  regenerate catalogs and verify signatures when signing was requested.
- Installer changes: build the embedded EXE and verify its Authenticode signer,
  file size and SHA-256. Do not launch installation without permission.
- Documentation/repository changes: run the public-tree audit.

## Code review rules

- Flag any change that broadens device targeting, removes bounded ring limits,
  forwards siphoned SCO bytes into the original parser, adds parallel internal
  UART writes or weakens teardown synchronization.
- Flag fixed local paths, certificate identities or machine-specific instance
  IDs in source and scripts.
- Flag build scripts that create or export PFX/private-key files.
- Flag install paths that can remove unrelated OEM packages or disable security
  settings without explicit consent.
- Require transparent forwarding of ordinary HCI command, event and ACL data.
