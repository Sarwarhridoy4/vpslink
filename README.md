# vpslink

[![CI](https://github.com/Sarwarhridoy4/vpslink/actions/workflows/ci.yml/badge.svg)](https://github.com/Sarwarhridoy4/vpslink/actions/workflows/ci.yml)
[![License: BSD 3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](LICENSE)

A production-quality Bash tool that turns a tedious SSH command into one word.

```bash
vpslink            # one-time setup
ssh vps            # every time after that
```

The script detects your OS, collects the VPS connection details, writes a
managed SSH host alias into `~/.ssh/config`, and verifies that the alias
actually works before it reports success.

**Naming:** the tool is `vpslink`; the SSH alias it creates is separate and
yours to choose (`vps`, `production`, `staging`, …). Renaming the tool never
affects the aliases it has already written.

> **Full operating manual:** see **[INSTRUCTION.md](INSTRUCTION.md)** for the
> complete walkthrough of every prompt, every command-line option, the exit
> codes, backup and recovery procedures, and the scripted/CI usage patterns.

---

## Contents

1. [Requirements](#1-requirements)
2. [Installation](#2-installation)
3. [Usage](#3-usage)
4. [Example session](#4-example-session)
5. [Generated SSH configuration](#5-generated-ssh-configuration)
6. [Authentication and key-management workflow](#6-authentication-and-key-management-workflow)
7. [Adding more VPS aliases later](#7-adding-more-vps-aliases-later)
8. [Testing](#8-testing)
9. [Troubleshooting guide](#9-troubleshooting-guide)
10. [Security limitations and assumptions](#10-security-limitations-and-assumptions)
11. [License](#11-license)
12. [File layout](#12-file-layout)

---

## 1. Requirements

| Requirement | Notes |
|---|---|
| Bash | The script uses only bash 3.2-compatible features (arrays, `[[ =~ ]]`, `${var: -1}`); bash 4+ is recommended but not required. macOS ships bash 3.2, which should work |
| OpenSSH client | `ssh`, `ssh-keygen` (and optionally `ssh-copy-id`) |
| Coreutils | `awk`, `sed`, `mktemp`, `date`, `grep`, `chmod`, `cp` |
| No root | The script never calls `sudo` and never writes outside `$HOME` |
| No third-party packages | Nothing is installed automatically |

**Supported platforms:** Ubuntu, Debian, Linux Mint and other Debian derivatives;
Fedora, RHEL, Rocky Linux, AlmaLinux, CentOS; Arch Linux and derivatives;
openSUSE; Alpine; macOS (via `xcode-select --install`); and any other Linux
distribution that has Bash and OpenSSH. On an unrecognised distribution the
script prints a warning and continues — it only writes a standard OpenSSH
alias, so the core function still works.

---

## 2. Installation

```bash
# 1. Copy the script somewhere permanent, under the name you want to type
install -m 0755 vpslink.sh ~/.local/bin/vpslink

# 2. Run it
vpslink
```

Or run it in place from the project directory:

```bash
chmod +x vpslink.sh
./vpslink.sh
```

`run.sh` is a thin wrapper that `exec`s `vpslink.sh` and forwards all
arguments, so `./run.sh --help` and `./vpslink.sh --help` behave
identically.

---

## 3. Usage

### Interactive (recommended)

```bash
./vpslink.sh
```

The script asks for:

| Prompt | Default | Notes |
|---|---|---|
| SSH alias | `vps` | Letters, digits, dot, underscore, hyphen |
| VPS FQDN or IP | — | Required. IPv4, IPv6 and hostnames are validated |
| SSH username | current user | |
| SSH port | `22` | Custom ports such as `999` are supported |
| Authentication | existing key | 1 = existing key, 2 = generate new, 3 = password |
| Private key path | `~/.ssh/id_ed25519` | Shown for method 1 and 2 |
| Key type | `ed25519` | Shown for method 2; `rsa` is the fallback |
| ServerAliveInterval | `60` | `0` disables keepalives |
| ConnectTimeout | `10` | |
| IdentitiesOnly | `yes` | Set to `no` to let the agent offer other keys |
| Wrapper command | `no` | Optional `~/.local/bin/<alias>` shortcut |

A review screen is shown before anything is written, and the run aborts if you
decline.

### Non-interactive

```bash
./vpslink.sh \
  --alias vps \
  --host srv.example.com \
  --user hemayet \
  --port 999 \
  --auth key \
  --key ~/.ssh/id_ed25519 \
  --yes
```

`--yes` is **required** in non-interactive mode, so an automated run can never
silently rewrite your SSH configuration.

### All options

```
--alias NAME        SSH alias (letters, digits, dot, underscore, hyphen)
--host HOST         VPS DNS hostname or IP address
--user USER         Remote SSH username
--port PORT         SSH port (1-65535; default 22)
--auth METHOD       key | generate | password   (default: key)
--key PATH          Private-key path for key/generate authentication
--key-type TYPE     ed25519 | rsa                (default: ed25519)
--keepalive SEC     ServerAliveInterval seconds (default 60; 0 disables)
--timeout SEC       ConnectTimeout seconds       (default 10)
--no-identities-only  Allow the SSH agent to offer other identities
--no-test           Skip connectivity and authentication tests
--no-wrapper        Do not offer the optional ~/.local/bin wrapper
--wrapper           Always offer/install the ~/.local/bin wrapper
--yes               Skip the interactive confirmation
--version           Print the script version
--help, -h          Show this help
```

---

## 4. Example session

```
$ ./vpslink.sh
====================================================
  vpslink v1.1.0 - VPS SSH login setup
====================================================

Detected environment:
  OS:            ubuntu
  Distribution:  Ubuntu 26.04.1 LTS
  Version:       26.04 (resolute)
  Family:        debian
  Architecture:  x86_64
  Kernel:        7.0.0-38-generic
  Login shell:   bash
  OpenSSH:       OpenSSH_10.2p1 Ubuntu-2ubuntu3.8, OpenSSL 3.5.5 27 Jan 2026

==> Configuration
SSH alias [vps]: vps
VPS FQDN or IP address: srv.example.com
SSH username [hemayet]: hemayet
SSH port [22]: 999

Authentication method
  1) Existing private key
  2) Generate a new key pair (Ed25519)
  3) Password authentication (native OpenSSH prompt)
Choose [1]: 1
Private key path [/home/hemayet/.ssh/id_ed25519]: /home/hemayet/.ssh/id_ed25519
ServerAliveInterval seconds (0 disables) [60]: 60
Connection timeout seconds [10]: 10
Offer only the configured key to the server? [Y/n]: y
Also install a 'vps' wrapper command in ~/.local/bin? [y/N]: n

==> Review configuration
  Alias:          vps
  Host:           srv.example.com
  Username:       hemayet
  Port:           999
  Authentication: existing private key
  Private key:    /home/hemayet/.ssh/id_ed25519
  Keepalive:      60 seconds
  Timeout:        10 seconds
  IdentitiesOnly: yes
Apply this configuration? [y/N]: y

==> SSH configuration
[INFO] No existing SSH config found; /home/hemayet/.ssh/config will be created.
[ OK ] SSH alias 'vps' saved to /home/hemayet/.ssh/config

==> Configuration validation
[ OK ] OpenSSH accepted the configuration (host=srv.example.com port=999 user=hemayet)

==> Connectivity test
[ OK ] DNS resolved: srv.example.com
[ OK ] TCP port 999 is reachable on srv.example.com

==> SSH authentication test
Verifying the host key on first use - compare the fingerprint with the one
published by your VPS provider before accepting it.

[ OK ] SSH authentication succeeded and a remote command ran successfully.

==> Setup summary
  Alias:          vps
  Host:           srv.example.com
  Username:       hemayet
  Port:           999
  Authentication: existing private key
  Private key:    /home/hemayet/.ssh/id_ed25519
  Keepalive:      60 seconds
  Timeout:        10 seconds
  Config file:    /home/hemayet/.ssh/config

Login command
  ssh vps

Direct connection (no alias)
  ssh -p 999 hemayet@srv.example.com
```

---

## 4a. How the script reports the outcome

The final line is only ever one of three things, and the script never claims
more than it actually tested:

| Situation | Output |
|---|---|
| DNS, TCP and authentication all succeeded | `[ OK ] Setup complete and verified. Connect with: ssh vps` |
| A test ran and failed | `[WARN] The alias is saved, but connectivity/authentication was not fully verified.` |
| Tests were skipped (`--no-test`) | `[WARN] The tests were skipped, so connectivity and authentication were NOT verified.` |

---

## 5. Generated SSH configuration

The script appends a delimited, self-identifying block to `~/.ssh/config`:

```sshconfig
# BEGIN vpslink: vps
Host vps
    HostName srv.example.com
    User hemayet
    Port 999
    IdentityFile "/home/hemayet/.ssh/id_ed25519"
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ConnectTimeout 10
# END vpslink: vps
```

Properties of this design:

- **The markers make it idempotent.** Re-running the script replaces the
  block between the markers instead of appending a second `Host vps` entry.
- **Unrelated entries are never touched.** Existing `Host` blocks, `Host *`
  wildcards and `Match` conditions are preserved byte-for-byte.
- **No secrets.** The block contains only host, user, port, key path and
  timeouts. No password, no API key, no private key material.
- **Validated before install.** The candidate file is written to a temp file
  and checked with `ssh -G -F <tmp> <alias>`. OpenSSH must accept it before it
  replaces the real config.
- **Installed atomically.** The final `mv` is a same-directory rename, so the
  config is never observed half-written.
- **Always backed up.** A timestamped copy (`config.bak.YYYYMMDDHHMMSS`) is
  created before any modification.

---

## 6. Authentication and key-management workflow

### Option 1 — existing private key

1. You give the path to a key that already exists (default
   `~/.ssh/id_ed25519`).
2. The script verifies the file exists and is readable, and that it is not
   world-readable.
3. The path is written to `IdentityFile` and `IdentitiesOnly yes` is set so
   the server is only offered that one key.

### Option 2 — generate a new key pair

1. `ssh-keygen -t ed25519 -a 64` is used (Ed25519 is preferred; `--key-type
   rsa` selects RSA-4096 for older OpenSSH builds that lack Ed25519).
2. You are asked whether to protect the private key with a passphrase. The
   passphrase is typed into `ssh-keygen`'s own secure prompt — it is never
   passed as a command-line argument (where it would be visible in `ps` and
   the shell history), and the script never sees it.
3. If a key already exists at that path, the script **refuses to overwrite it**
   unless you explicitly confirm, and even then it takes a timestamped backup
   first.
4. The private key is written with mode `600` and the public key with `644`.
5. The script then **offers a guided `ssh-copy-id` run**:

   ```
   Install the public key on the VPS now? (you will be asked for the VPS password) [y/N]:
   ```

   Answering `y` runs the real command (only the **public** key is
   transmitted):

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 999 hemayet@srv.example.com
   ```

   Answering `n` — or having no `ssh-copy-id` installed — prints manual
   instructions instead: copy the contents of `~/.ssh/id_ed25519.pub` into
   `~/.ssh/authorized_keys` on the VPS, then run
   `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`.

**Only the public key is ever transmitted.** The private key never leaves the
local machine — the script copies nothing to the server itself.

### Option 3 — password authentication

1. No key is created or referenced; the `IdentityFile` line is omitted
   entirely.
2. OpenSSH prompts for the password at connection time using its native
   prompt. The script never asks for the password, never accepts it as an
   argument, and never writes it anywhere.
3. The summary explains that password authentication does not require a
   private key and that key authentication is generally preferable (it resists
   credential stuffing and enables automation).

### What the script deliberately does **not** do

- It does not disable password authentication on the remote host.
- It does not enable root login on the remote host.
- It does not modify the remote `sshd_config` or firewall rules.
- It does not restart or reload any remote SSH service.
- It does not install `sshpass` or any other password-handling utility.

All remote-side hardening is left to you, performed deliberately, on the VPS.

### Host-key verification

The script never sets `StrictHostKeyChecking no` or `UserKnownHostsFile
/dev/null`. On the first connection, OpenSSH performs its normal trust-on-
first-use flow and records the host key in `~/.ssh/known_hosts` after you
accept the fingerprint. The script reminds you to compare the fingerprint
against the one published by your VPS provider.

---

## 7. Adding more VPS aliases later

Run the script again — it never overwrites an existing alias without asking.

```bash
./vpslink.sh
# SSH alias [vps]: production
# ...
```

If you pick a name that already exists in `~/.ssh/config`, the script detects
it and offers three choices:

```
[ WARN ] Alias 'vps' already exists in /home/hemayet/.ssh/config and was not created by this script.
  1) Replace the existing definition of this alias
  2) Use a different alias name
  3) Cancel without changes
```

- **Option 1** replaces the existing block. If that `Host` line also defines
  other names (`Host vps prod`), the script warns you first, because replacing
  it would remove those definitions too.
- **Option 2** lets you rename immediately.
- **Option 3** leaves the config untouched.

If the alias was created by this script (the markers are present), the script
silently updates that block — that is the normal "edit my server" path.

You can also add an alias entirely by hand; the script will detect and report
it as unmanaged, then offer the same choice list.

**Directly editing the config** also works and is safe:

```sshconfig
Host staging
    HostName staging.example.com
    User deploy
    Port 22
    IdentityFile "~/.ssh/id_ed25519"
```

Remember to close the entry with a blank line before the next `Host` block.

---

## 8. Testing

### Static analysis

```bash
# Syntax check
bash -n vpslink.sh

# ShellCheck (recommended: install with apt install shellcheck,
# snap install shellcheck, or brew install shellcheck)
shellcheck -S style vpslink.sh
shellcheck -S style test-vpslink.sh
```

The script is **ShellCheck-clean at `-S style`** and passes `bash -n`.

### Automated test suite

```bash
chmod +x test-vpslink.sh
./test-vpslink.sh
```

The suite creates a throw-away `HOME` for every test, so **your real
`~/.ssh/config` is never modified**. It needs no network, no root and no
live VPS. It exits `0` on success and `1` on any failure.

Latest result on this machine: **137 passed, 0 failed**.

```bash
$ ./test-vpslink.sh
...
[1mResult: 137 passed, 0 failed[0m
```

### Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request to `main`:

| Job | Runs on | What it does |
|---|---|---|
| `lint` | `ubuntu-latest` | ShellCheck at `-S style` plus `bash -n` on all three scripts |
| `test` | `ubuntu-latest`, `ubuntu-22.04` | The full regression suite |
| `macos` | `macos-latest` | ShellCheck plus the full regression suite |

The workflow depends on nothing beyond `actions/checkout` and the runners'
own package managers — no third-party lint actions. It requests
`contents: read` and no other permissions, and cancels superseded runs on the
same branch.

### Manual test procedure

| # | Scenario | How to exercise it | Expected result |
|---|---|---|---|
| 1 | Fresh setup on Ubuntu/Debian | `./vpslink.sh` in a clean `HOME` | Config created, mode 600, `.ssh` mode 700 |
| 2 | Existing SSH configuration | Add a `Host bastion` block, re-run | `Host bastion` survives untouched |
| 3 | Existing SSH alias | Add `Host vps` by hand, re-run | Duplicate detected, choice list shown |
| 4 | Duplicate alias (managed) | Run twice | One block, no duplicate `Host vps` |
| 5 | Custom port 999 | `--port 999` | `Port 999` in the config, `ssh -G` confirms |
| 6 | Existing key | `--auth key` with a real key | Used as `IdentityFile` |
| 7 | Missing key | `--auth key --key /nonexistent` | Fails with "Private key not found" |
| 8 | Incorrect hostname | `--host 'bad host'` | Rejected before anything is written |
| 9 | Invalid port | `--port 99999` | Rejected |
| 10 | DNS failure | `--host no-such-host.invalid` | "DNS lookup failed" warning |
| 11 | Connection refused | `--host 127.0.0.1 --port 1` | "Cannot reach" with causes |
| 12 | Authentication failure | Wrong key for a reachable host | "Authentication failed" + install hint |
| 13 | Host-key mismatch | Reinstall a test VPS | "Host-key verification failed" + `ssh-keygen -R` |
| 14 | Missing OpenSSH | Run with `PATH` stripped of `ssh` | Clear "not installed" message |
| 15 | Interrupted execution | Press `Ctrl+C` at a prompt | Temp files removed, config untouched |
| 16 | Read-only config | `chmod 400 ~/.ssh/config` | "not writable", nothing changed |
| 17 | Re-run without duplicates | Run 3 times | Exactly one managed block |
| 18 | OS variation | Run on Fedora/Arch/macOS | Detected environment printed correctly |

### Testing on other platforms

The OS-detection logic is easy to exercise anywhere by pointing the script at
a different `os-release` file:

```bash
sudo mkdir -p /tmp/fakeos/etc
sudo cp /tmp/fedora-os-release /tmp/fakeos/etc/os-release
# (patch os_release_get's default path, or bind-mount) then run:
./vpslink.sh --alias t --host h.example.com --user u --auth password --yes --no-test
```

---

## 9. Troubleshooting guide

| Symptom | Cause | Fix |
|---|---|---|
| `ssh: Could not resolve hostname vps` | The alias is not in the config OpenSSH reads | `ls -l ~/.ssh/config`; confirm you are using the same account; `ssh -G vps` shows what OpenSSH resolved |
| `Permission denied (publickey)` | The public key is not installed on the VPS, or the remote user is wrong | `ssh-copy-id -i ~/.ssh/id_ed25519.pub -p PORT USER@HOST`; confirm the username |
| `Host key verification failed` | The stored key does not match the server | Only if you know the VPS was reinstalled: `ssh-keygen -R HOST` |
| `Connection timed out` | Host unreachable / firewall or security group blocking the port | Check DNS, cloud firewall, `nc -vz HOST PORT` |
| `Connection refused` | Nothing is listening on that port | Confirm the `sshd` port on the VPS |
| `Agent refused the key` / `no identities` | Passphrase-protected key not loaded | `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519` |
| `Bad configuration option` after editing | Typo in `~/.ssh/config` | `ssh -G vps` to see the parse error |
| Script exits with "unmanaged" | The alias exists but was not created by this script | Pick option 1 (replace) or 2 (rename) when prompted |
| Nothing happens on Ctrl+C | — | The script removes its temp file and leaves the config unchanged; re-run it |

### Diagnostic commands

```bash
ssh -G vps          # show the effective configuration OpenSSH will use
ssh -vvv vps       # full connection log
nc -vz srv.example.com 999   # is the SSH port reachable?
getent ahosts srv.example.com   # does DNS resolve?
```

---

## 10. Security limitations and assumptions

### What the script guarantees

- Passwords are **never** accepted as command-line arguments, read from stdin,
  stored in a file, or written to a log. Password authentication is delegated
  entirely to OpenSSH's native prompt.
- Host-key verification is **never** disabled. `StrictHostKeyChecking` is not
  written to the config at all, so your existing global setting is respected.
- The private key is **never** transmitted. Only `ssh-copy-id` (run by you, on
  demand) sends the public key.
- `StrictHostKeyChecking` and `UserKnownHostsFile` are never set to
  `accept-new`/`no` by the generated block.
- The generated block contains **no secrets** — no password, token, or key
  material.
- Filesystem permissions are enforced: `~/.ssh` is `700`, the config is `600`,
  private keys are `600`, public keys are `644`.
- Every input is validated before use (alias, hostname, IPv4/IPv6 literal,
  username, port, timeouts, key path). No `eval` is used anywhere.
- `set -Eeuo pipefail` is active, and every expected failure is handled
  explicitly rather than allowed to abort the script.
- Writes are atomic (temp file + `mv`) and preceded by a timestamped backup.
- The script never needs root and never calls `sudo`.

### Assumptions and limitations

- **You own the machine and the VPS.** The script trusts the hostname you
  type for the host key; it does not verify fingerprints out-of-band. Verify
  the fingerprint against your provider's published value on first connect.
- **The remote `sshd` must already allow key authentication** for the chosen
  user. The script does not change remote daemon configuration.
- **First connection prompts for host-key acceptance.** In a fully automated
  context, use your own `known_hosts` seeding (e.g. `ssh-keyscan` verified by
  hand) — the script deliberately does not do this for you.
- **`~/.ssh/config` is assumed to be a plain user config.** `Match` blocks are
  detected and a warning is printed, because their conditional semantics can
  make a global alias behave unexpectedly.
- **A passphrase-protected key needs an unlocked agent** for the automated
  authentication test. The test uses `BatchMode=yes` so it never hangs
  waiting for a passphrase; if the agent is empty the script tells you to run
  `ssh-add`.
- **Bash 4+ is assumed** (associative-array-free but uses `${var//}`-style
  and `[[ =~ ]]` features present in bash 3.2 as well; bash 4 is recommended
  because macOS ships 3.2).
- **`~/.ssh/config` is only valid if OpenSSH can parse it.** The script
  validates the candidate with `ssh -G` before installing it, but it cannot
  validate a pre-existing `Match`-heavy file.
- **Single-user scope.** The script configures the current user's `~/.ssh`.
  Running it as root configures root's SSH, not your account.
- **No key rotation automation.** Use the backup files and `ssh-keygen` to
  rotate keys manually.

---

## 11. License

Released under the **BSD 3-Clause License** — see [`LICENSE`](LICENSE).

Copyright (c) 2026 Sarwarhridoy4.

In short: you may use, modify and redistribute it, including commercially,
provided you keep the copyright notice, the conditions and the disclaimer,
and do not use the author's name to endorse your own product. There is no
copyleft obligation, and the licence includes an explicit patent grant from
the contributors.

---

## 12. File layout

```
.
├── vpslink.sh              # the tool (single source of truth)
├── run.sh                  # thin wrapper: exec vpslink.sh "$@"
├── test-vpslink.sh         # isolated regression suite (137 checks)
├── INSTRUCTION.md          # full operating manual
├── LICENSE                 # BSD 3-Clause
├── .github/workflows/ci.yml
└── README.md
```

### Function map

| Function | Responsibility |
|---|---|
| `detect_os` | Parse `/etc/os-release` (never source it) and report the environment |
| `classify_platform` | Map the distribution family to a package-manager hint |
| `check_dependencies` | Verify `ssh`, `awk`, `mktemp`, … are present |
| `collect_configuration` | Interactive prompts (no side effects) |
| `validate_inputs` | Validate alias, host, user, port, timeouts, key path |
| `manage_ssh_keys` | Generate an Ed25519/RSA key pair, refuse to clobber |
| `offer_copy_id` | Offer the guided `ssh-copy-id` install of the public key |
| `backup_ssh_config` | Timestamped copy of the existing config |
| `configure_ssh_alias` | Idempotently write the managed block, atomically |
| `validate_ssh_config` | `ssh -G` check of the installed config |
| `test_connectivity` | DNS resolution + TCP probe of the SSH port |
| `test_ssh_authentication` | Real SSH auth attempt with classified errors |
| `install_wrapper` | Optional `~/.local/bin/<alias>` helper |
| `print_summary` | Final configuration summary (never prints secrets) |
| `show_troubleshooting` | Contextual help output |
