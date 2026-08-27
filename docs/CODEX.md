# Build this repository with Codex

Codex automatically reads the repository-root `AGENTS.md` when it starts from
this Git workspace. The instructions describe the architecture, supported
hardware, safe build order, signing choices, privacy rules and required checks.

## Quick start

1. Clone the repository on Windows 10 or Windows 11.
2. Open PowerShell in the cloned repository.
3. Start Codex from that directory.
4. Enter:

```text
Make it work for local testing. Check all prerequisites, build and test-sign
the drivers with a new local non-exportable certificate, build the installer,
verify every signature, and do not install or reboot anything.
```

Codex should:

- read `AGENTS.md` and the linked project documentation;
- inspect Visual Studio, SDK and WDK availability;
- explain any missing prerequisite;
- run the repository privacy audit;
- create a local, non-exportable test-signing key;
- build and sign both drivers and the installer;
- return the final EXE path, size and SHA-256;
- leave generated files only in ignored build/artifact directories.

Installing the resulting kernel drivers, enabling Test Mode and restarting the
computer are separate actions. Ask Codex explicitly only after reviewing the
build result:

```text
This is a supported MacBookPro16,1 and I have a backup and wired input device.
Inspect compatibility first, then ask me once more before launching the
installer or changing Test Mode.
```

## Other useful prompts

Unsigned build only:

```text
Audit the repository and make a clean unsigned Release x64 build. Do not create
a certificate and do not install anything.
```

Use an existing local certificate:

```text
Build and sign the Release packages with certificate thumbprint <THUMBPRINT>.
Verify that it has a private key and Code Signing EKU. Do not expose or export
the private key and do not install anything.
```

To check that Codex loaded the workspace instructions, enter this in the active
Codex session:

```text
Summarize the active repository instructions before doing any work.
```

Codex reads project instructions from the Git root toward the current working
directory at the start of a session. Restart the session after changing
`AGENTS.md`.
