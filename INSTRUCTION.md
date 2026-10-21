# vpslink — Usage Instructions

Complete operating manual for `vpslink`, the VPS SSH login setup tool.

- **What it does:** creates a short SSH alias (`ssh vps`) for a VPS and
  verifies the alias works.
- **What it never does:** store passwords, disable host-key checking, transmit
  your private key, modify the remote server, or need root.

---

## Table of contents

1. [Quick start](#1-quick-start)
2. [Installation](#2-installation)
3. [Running it](#3-running-it)
4. [The interactive walkthrough](#4-the-interactive-walkthrough)
5. [Command-line reference](#5-command-line-reference)
6. [Non-interactive and scripted use](#6-non-interactive-and-scripted-use)
7. [Authentication methods](#7-authentication-methods)
8. [The generated SSH configuration](#8-the-generated-ssh-configuration)
9. [Connecting to your VPS](#9-connecting-to-your-vps)
10. [Managing aliases afterwards](#10-managing-aliases-afterwards)
11. [Backups, undo and recovery](#11-backups-undo-and-recovery)
12. [Exit codes](#12-exit-codes)
13. [What the script writes and where](#13-what-the-script-writes-and-where)
14. [Testing](#14-testing)
15. [Troubleshooting](#15-troubleshooting)
16. [Security notes](#16-security-notes)

---

## 1. Quick start

```bash
./vpslink.sh
```

Answer the prompts (alias, hostname, username, port, authentication method),
review the summary, and confirm. Then:

```bash
ssh vps
```

---

## 2. Installation

### Option A — run from the project directory (no install)

```bash
chmod +x vpslink.sh
./vpslink.sh
```

`run.sh` is an identical entry point that forwards every argument:

```bash
./run.sh
./run.sh --help
./run.sh --alias prod --host srv.example.com --user deploy --port 999 --auth key --yes
```

### Option B — install as a command (any shell)

```bash
./vpslink.sh --install
```

This does the whole job in one step:

1. Detects your login shell from `$SHELL` (falling back to the parent
   process).
2. Copies the tool to `~/.local/bin/vpslink` (mode `755`).
3. Writes the correct `PATH` line for that shell into its startup file.
4. Prints the line you need to activate it in the current terminal.

The startup file is edited between markers, so running `--install` again
replaces the block instead of adding a second one, and any other content in
the file is left untouched:

```bash
# >>> vpslink >>>
export PATH="/home/you/.local/bin:$PATH"
# <<< vpslink <<<
```

It shows you exactly what it will change and asks for confirmation first.
Pass `--yes` to skip the prompt.

To install somewhere else:

```bash
./vpslink.sh --install --install-dir ~/bin
```

To remove it again:

```bash
vpslink --uninstall
```

This deletes the installed copy and removes the marked block from your
startup file. Your other `PATH` entries are untouched.

### Shell support

| Shell | Startup file | `PATH` line added |
|---|---|---|
| Bash | `~/.bashrc` | `export PATH="<dir>:$PATH"` |
| Zsh | `~/.zshrc` | `export PATH="<dir>:$PATH"` |
| Fish | `~/.config/fish/config.fish` | `fish_add_path "<dir>"` |
| csh / tcsh | `~/.cshrc` | `setenv PATH "<dir>":$PATH` |
| Ksh (ksh93, mksh) | `~/.kshrc` | `export PATH="<dir>:$PATH"` |
| sh / dash / ash | `~/.profile` | `export PATH="<dir>:$PATH"` |
| PowerShell | `~/.config/powershell/Microsoft.PowerShell_profile.ps1` | `$env:PATH = "<dir>" + [System.IO.Path]::PathSeparator + $env:PATH` |
| Elvish | `~/.elvish/rc.elv` | `set-env E:PATH (put $E:PATH \| append <dir>)` |
| Nushell | `~/.config/nushell/config.nu` | `$env.PATH = ($env.PATH \| prepend "<dir>")` |
| Xonsh | `~/.xonshrc` | `import os; os.environ['PATH'] = '<dir>' + os.pathsep + os.environ['PATH']` |

Any other shell falls back to the POSIX `~/.profile` with a plain `export`.

If you use a non-standard startup file (for example `~/.zshenv`, or a
`ZDOTDIR` override), run the tool from that shell so `$SHELL` matches, or
add the line by hand — the tool prints the exact line for your shell.

### Option C — install by hand

```bash
# 1. Copy the script somewhere permanent, under the name you want to type
install -m 0755 vpslink.sh ~/.local/bin/vpslink

# 2. Add the directory to your PATH using the line from the table above

# 3. Run it from anywhere
vpslink
```

### Requirements

| Requirement | Notes |
|---|---|
| Bash | Works on bash 3.2 (macOS default) and 4+/5+ |
| OpenSSH client | `ssh` and `ssh-keygen` must be present |
| Coreutils | `awk`, `sed`, `grep`, `mktemp`, `date`, `chmod`, `cp`, `mv` |
| `nc` or `timeout` | Optional — used for the TCP port probe |
| `ssh-copy-id` | Optional — used for the guided public-key install |
| Root | **Not** required. The script never calls `sudo` |

Check your environment:

```bash
vpslink --version
```

---

## 3. Running it

```bash
vpslink                  # full interactive setup
vpslink --help           # option reference
vpslink --version        # version string
```

The script always follows the same five phases:

```
1. Detect environment   -> reports OS, distro, architecture, shell, OpenSSH version
2. Collect configuration-> prompts (or reads your command-line arguments)
3. Review & confirm     -> shows every setting; nothing is written until you approve
4. Apply                -> key management, then the SSH config write
5. Verify & report      -> validates the config, probes the port, tries to authenticate
```

Phase 3 is the safety gate. Answering anything other than `y`/`Y` aborts with
`Cancelled; no SSH configuration was changed.` and nothing on disk is touched.

---

## 4. The interactive walkthrough

Every prompt shows its default in square brackets. Pressing Enter accepts it.

### 4.1 SSH alias

```
SSH alias [vps]: 
```

The name you type to connect: `ssh vps`. Rules: 1–64 characters, starting
with a letter or digit, then letters, digits, dots, underscores or hyphens.
No spaces, no leading dash, no glob characters.

### 4.2 Host

```
VPS FQDN or IP address: 
```

Required. Accepts a fully qualified domain name (`srv.example.com`), an IPv4
address (`192.0.2.10`), or an IPv6 address (`2001:db8::1`). A trailing dot is
allowed. The value is validated before use; shell metacharacters are rejected.

### 4.3 Username

```
SSH username [your-local-user]: 
```

The remote account to log in as. Press Enter to use your local username.

### 4.4 Port

```
SSH port [22]: 
```

`22` by default. Custom ports such as `999` are fully supported. Range
1–65535.

### 4.5 Authentication method

```
Authentication method
  1) Existing private key
  2) Generate a new key pair (Ed25519)
  3) Password authentication (native OpenSSH prompt)
Choose [1]: 
```

See [section 7](#7-authentication-methods).

### 4.6 Key path

```
Private key path [/home/you/.ssh/id_ed25519]: 
```

Only shown for methods 1 and 2. Accepts `~` and relative paths. The path may
not contain spaces, double quotes, backslashes or percent signs.

### 4.7 Key type

```
Key type (ed25519 or rsa) [ed25519]: 
```

Only shown for method 2. `ed25519` is preferred; `rsa` (4096-bit) is the
fallback for very old OpenSSH builds.

### 4.8 Keepalive

```
ServerAliveInterval seconds (0 disables) [60]: 
```

How often the client sends a keepalive to keep the connection alive through
NAT/firewalls. `0` disables keepalives and omits both `ServerAliveInterval`
and `ServerAliveCountMax` from the config.

### 4.9 Timeout

```
Connection timeout seconds [10]: 
```

How long to wait for the TCP connection before giving up. Range 1–86400.

### 4.10 Identities only

```
Offer only the configured key to the server? [Y/n]: 
```

`yes` writes `IdentitiesOnly yes`, so the server is offered only the key you
configured. Answer `n` if you want your SSH agent to offer other identities
too. Not asked for password authentication.

### 4.11 Wrapper command

```
Also install a 'vps' wrapper command in ~/.local/bin? [y/N]: 
```

Optional convenience shortcut. Answer `n` (the default) to rely on the
standard `ssh vps` alias, which always works with no PATH changes.

### 4.12 Review and confirm

```
==> Review configuration
  Alias:          vps
  Host:           srv.example.com
  Username:       hemayet
  Port:           999
  Authentication: existing private key
  Private key:    /home/you/.ssh/id_ed25519
  Keepalive:      60 seconds
  Timeout:        10 seconds
  IdentitiesOnly: yes
Apply this configuration? [y/N]: 
```

Answer `y` to apply. Nothing has been written at this point.

### 4.13 Key passphrase (method 2 only)

```
Protect the private key with a passphrase? [Y/n]: 
```

The passphrase is typed into `ssh-keygen`'s own secure prompt. It is never
passed as a command-line argument (where it would be visible to `ps`), never
stored, and the script never sees it.

### 4.14 Public key install (method 2 only)

```
Install the public key on the VPS now? (you will be asked for the VPS password) [y/N]: 
```

Answer `y` to run `ssh-copy-id` for you. See
[section 7.2](#72-method-2--generate-a-new-key-pair).

---

## 5. Command-line reference

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
--wrapper           Always install the ~/.local/bin wrapper
--yes               Skip the interactive confirmation
--install           Install vpslink on the PATH for your shell and exit
--install-dir DIR   Target directory for --install (default ~/.local/bin)
--uninstall         Remove vpslink and its PATH entry, then exit
--version           Print the script version
--help, -h          Show this help
```

### Argument rules

- Passing **any** of `--alias`, `--host`, `--user`, `--port`, `--auth`,
  `--key`, `--key-type`, `--keepalive` or `--timeout` switches the script into
  **non-interactive mode**.
- Non-interactive mode **requires `--yes`**. Without it the script refuses to
  run, so an automated job can never silently rewrite your SSH config.
- `--yes` alone (with no other arguments) still runs interactively but skips
  the final confirmation.
- There is deliberately **no** `--password` option. Passwords are never
  accepted as arguments.

### Common invocations

```bash
# Custom port, existing key
vpslink --alias vps --host srv.example.com --user hemayet --port 999 \
        --auth key --key ~/.ssh/id_ed25519 --yes

# IP address, no keepalive, 30s timeout
vpslink --alias box --host 192.0.2.10 --user root --port 22 \
        --auth key --keepalive 0 --timeout 30 --yes

# Password authentication (no key)
vpslink --alias legacy --host old.example.com --user admin \
        --auth password --yes

# Configure only, do not touch the network
vpslink --alias vps --host srv.example.com --user hemayet \
        --auth key --no-test --yes

# Let the agent offer several keys
vpslink --alias vps --host srv.example.com --user hemayet \
        --auth key --no-identities-only --yes
```

---

## 6. Non-interactive and scripted use

For CI, provisioning, or batch setup of many servers:

```bash
vpslink \
  --alias vps \
  --host srv.example.com \
  --user hemayet \
  --port 999 \
  --auth key \
  --key ~/.ssh/id_ed25519 \
  --yes
```

Rules for scripted use:

- `--yes` is mandatory.
- `--auth generate` is **not** available non-interactively: `ssh-keygen` needs
  a terminal for the passphrase prompt, and silently creating an unencrypted
  key would be a security downgrade. The script fails loudly with an
  explanation. Create the key first with `ssh-keygen`, then use `--auth key`.
- `--auth password` is accepted, but the authentication **test** is skipped
  (it would need an interactive prompt). The alias is still written.
- Use `--no-test` in a network-isolated environment.

### Adding many servers

```bash
while read -r alias host user port; do
  vpslink --alias "$alias" --host "$host" --user "$user" --port "$port" \
          --auth key --key ~/.ssh/id_ed25519 --yes
done <<'EOF'
web   web.example.com    deploy  22
db    db.example.com     dba     999
cache cache.example.com  ops     22
EOF
```

Each run updates only its own alias block; the others are untouched.

---

## 7. Authentication methods

### 7.1 Method 1 — existing private key

1. You give the path to a key that already exists.
2. The script verifies the file exists and is readable.
3. The path becomes `IdentityFile`, and `IdentitiesOnly yes` is set so the
   server is offered only that key.

The key is never modified, moved or copied.

### 7.2 Method 2 — generate a new key pair

1. `ssh-keygen -t ed25519 -a 64` is used (`--key-type rsa` selects RSA-4096).
2. You choose whether to protect it with a passphrase. The passphrase is typed
   into `ssh-keygen`'s prompt — never on a command line, never stored.
3. **An existing key at that path is never overwritten silently.** The script
   refuses and asks for explicit confirmation; if you confirm, a timestamped
   backup is taken first.
4. The private key is written mode `600`; the public key mode `644`.
5. The script offers the guided install:

   ```
   Install the public key on the VPS now? (you will be asked for the VPS password) [y/N]: 
   ```

   Answering `y` runs:

   ```bash
   ssh-copy-id -i ~/.ssh/id_ed25519.pub -p 999 hemayet@srv.example.com
   ```

   If `ssh-copy-id` is unavailable, the script prints manual instructions:

   ```bash
   cat ~/.ssh/id_ed25519.pub
   # paste that into ~/.ssh/authorized_keys on the VPS, as the target user, then:
   chmod 700 ~/.ssh
   chmod 600 ~/.ssh/authorized_keys
   ```

**Only the public key is transmitted.** The private key never leaves your
machine.

### 7.3 Method 3 — password authentication

1. No key is created or referenced. The `IdentityFile` line is omitted.
2. OpenSSH prompts for the password at connection time using its native
   prompt. The script never asks for it, never accepts it as an argument, and
   never writes it to disk.
3. The summary explains that password authentication needs no private key, and
   that key authentication is generally preferable (it resists credential
   stuffing and enables automation).

To switch later, re-run the tool with `--auth generate`.

### 7.4 What is never done to the remote server

The script does not, under any option:

- disable password authentication
- enable root login
- edit `sshd_config`
- change firewall or security-group rules
- restart or reload `sshd`
- install packages
- write anything outside `~/.ssh` and `~/.local/bin`

Remote hardening is a deliberate, manual operation on the VPS.

---

## 8. The generated SSH configuration

```sshconfig
# BEGIN vpslink: vps
Host vps
    HostName srv.example.com
    User hemayet
    Port 999
    IdentityFile "/home/you/.ssh/id_ed25519"
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ConnectTimeout 10
# END vpslink: vps
```

| Directive | Meaning |
|---|---|
| `HostName` | The real address the alias resolves to |
| `User` | The remote account |
| `Port` | The SSH port |
| `IdentityFile` | The private key to offer (absent for password auth) |
| `IdentitiesOnly` | Offer only that key, not everything in the agent |
| `ServerAliveInterval` | Seconds between keepalives (`0` omits it) |
| `ServerAliveCountMax` | Missed keepalives before disconnecting |
| `ConnectTimeout` | Seconds to wait for the TCP connection |

### Guarantees

- **Idempotent.** The `# BEGIN` / `# END` markers let the tool find and
  replace exactly its own block. Re-running never creates a duplicate.
- **Non-destructive.** Unrelated `Host` blocks, `Host *` wildcards and
  `Match` conditions are preserved byte-for-byte.
- **Secret-free.** No password, token or key material is ever written.
- **Validated first.** The candidate file is checked with `ssh -G -F` and must
  be accepted by OpenSSH before it replaces your real config.
- **Atomic.** The install is a same-directory rename, so the config is never
  observed half-written.
- **Backed up.** A timestamped copy is created before any modification.

### Inspecting what OpenSSH will actually do

```bash
ssh -G vps
```

This prints the fully resolved configuration, including anything inherited
from `Host *` wildcards or `Match` blocks.

---

## 9. Connecting to your VPS

### Using the alias (recommended)

```bash
ssh vps
```

### Connecting directly, without the alias

```bash
ssh -p 999 hemayet@srv.example.com
```

### Using the optional wrapper

If you answered `y` to the wrapper prompt, `~/.local/bin/vps` is created:

```sh
#!/bin/sh
exec ssh vps "$@"
```

It forwards every argument, so `vps -p 2222` works. An existing file at that
path is never overwritten. The wrapper is optional — `ssh vps` always works
without it.

### First connection

OpenSSH performs its normal trust-on-first-use flow. **Compare the
fingerprint** shown against the one published by your VPS provider before
accepting it. The script never disables host-key checking.

If the key later changes because the VPS was reinstalled:

```bash
ssh-keygen -R srv.example.com
```

---

## 10. Managing aliases afterwards

### Adding another server

Run the tool again and use a different alias:

```bash
vpslink
# SSH alias [vps]: production
```

### Updating an existing alias

Re-run the tool with the **same** alias. If the block was created by
`vpslink`, it is replaced in place — no prompt, no duplicate.

### When the alias exists but was not created by vpslink

```
[ WARN ] Alias 'vps' already exists in /home/you/.ssh/config and was not created by this script.
  1) Replace the existing definition of this alias
  2) Use a different alias name
  3) Cancel without changes
```

- **1 — Replace.** The old block is removed and the new one written. If the
  old `Host` line also defined other names (`Host vps prod`), you are warned
  first, because replacing it removes those too.
- **2 — Use a different alias name.** You are asked for the new name.
- **3 — Cancel.** Nothing changes.

In `--yes` mode an unmanaged duplicate is refused rather than silently
overwritten.

### Removing an alias

Delete the block from `~/.ssh/config` by hand, including its two marker
lines. The tool does not provide a delete option, so removal is always
explicit.

### Listing the aliases you have

```bash
grep -E '^Host ' ~/.ssh/config
```

---

## 11. Backups, undo and recovery

Every run that modifies an existing config creates a timestamped backup
first:

```
~/.ssh/config.bak.20261021143055
```

### Restore a backup

```bash
ls -lt ~/.ssh/config.bak.*          # find the one you want
cp ~/.ssh/config.bak.20261021143055 ~/.ssh/config
chmod 600 ~/.ssh/config
```

### Inspect before restoring

```bash
diff ~/.ssh/config.bak.20261021143055 ~/.ssh/config
```

### Key backups

If you ever confirm overwriting an existing key pair, the old files are kept
as:

```
~/.ssh/id_ed25519.bak.20261021143055
~/.ssh/id_ed25519.pub.bak.20261021143055
```

---

## 12. Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — the alias was written and (if tested) verified |
| `1` | Failure — invalid input, missing dependency, unwritable config, rejected configuration, or a failed test |
| `2` | Not used (reserved by the shell) |
| `130` | Interrupted with `Ctrl+C`; temporary files are removed and the config is left unchanged |

A failed *test* still exits `0` when the alias itself was written successfully
— check the output, not just the exit code, when scripting. The script states
plainly which case it is in:

```
[ OK ] Setup complete and verified. Connect with: ssh vps
[WARN] The alias is saved, but connectivity/authentication was not fully verified.
[WARN] The tests were skipped, so connectivity and authentication were NOT verified.
```

---

## 13. What the script writes and where

| Path | Change |
|---|---|
| `~/.ssh/` | Created if missing, mode `700` |
| `~/.ssh/config` | The managed block is added or replaced, mode `600` |
| `~/.ssh/config.bak.<timestamp>` | Backup, created before any change |
| `~/.ssh/<key>` | New private key, mode `600` (method 2 only) |
| `~/.ssh/<key>.pub` | New public key, mode `644` (method 2 only) |
| `~/.ssh/<key>.bak.<timestamp>` | Backup of an overwritten key |
| `~/.ssh/known_hosts` | Written by OpenSSH on first connect, not by this tool |
| `~/.local/bin/<alias>` | Optional wrapper, mode `755` |

Nothing else is modified. No system files, no `sudo`, no other users' files.

---

## 14. Testing

```bash
# Static analysis
bash -n vpslink.sh
shellcheck -S style vpslink.sh run.sh test-vpslink.sh

# Automated regression suite (uses a throw-away HOME; your real config is
# never touched)
./test-vpslink.sh
```

The suite exits `0` on success and `1` on any failure, and prints a summary
plus the list of failed checks. It has two layers: end-to-end runs of the
tool against a throw-away `HOME`, and unit tests that source the script and
exercise individual functions (`classify_platform`, the input validators,
`os_release_get`).

### Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request to `main`:

| Job | What it does |
|---|---|
| `lint` | ShellCheck at `-S style` plus `bash -n` on all three scripts |
| `test` | Full regression suite on `ubuntu-latest` and `ubuntu-22.04` |
| `macos` | ShellCheck plus the full regression suite on `macos-latest` |

The workflow uses only `actions/checkout` and the runners' own package
managers — no third-party lint actions. It requests `contents: read` and
nothing more.

---

## 15. Troubleshooting

### Quick diagnosis

```bash
ssh -G vps                    # effective configuration OpenSSH will use
ssh -vvv vps                  # full connection log
nc -vz srv.example.com 999   # is the SSH port reachable?
getent ahosts srv.example.com # does DNS resolve?
```

| Symptom | Fix |
|---|---|
| `ssh: Could not resolve hostname vps` | The alias is missing from the config OpenSSH reads. `ls -l ~/.ssh/config`; confirm you use the same account; `ssh -G vps` |
| `Permission denied (publickey)` | The public key is not installed on the VPS, or the username is wrong. `ssh-copy-id -i ~/.ssh/id_ed25519.pub -p PORT USER@HOST` |
| `Host key verification failed` | The stored key does not match. Only if you know the VPS was reinstalled: `ssh-keygen -R HOST` |
| `Connection timed out` | Unreachable host — check DNS, firewall, security groups, and the port |
| `Connection refused` | Nothing is listening on that port — confirm the `sshd` port |
| `Agent refused the key` / `no identities` | Passphrase-protected key not loaded: `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519` |
| `Bad configuration option` | Typo in your config — `ssh -G vps` shows the parse error |
| `Alias 'vps' exists and is unmanaged` | The alias is not one of the tool's blocks; re-run interactively to choose replace/rename/cancel |
| Script stops at the passphrase prompt | `ssh-keygen` needs a terminal — use `--auth key` with a pre-made key, or run interactively |

### Diagnosing a failed test

| Message | Meaning |
|---|---|
| `DNS lookup failed` | The hostname did not resolve — check the spelling and that the domain is published |
| `Cannot reach HOST:PORT` | The TCP connection failed — firewall, wrong port, or the server is down |
| `Host-key verification failed` | The server key changed or is not yet trusted |
| `Authentication failed` | The key or password was rejected — the public key is probably not installed yet |
| `The SSH agent has no loaded identity` | Unlock the key with `ssh-add` |

---

## 16. Security notes

### What is guaranteed

- **Passwords are never accepted** as arguments, read from stdin, stored in a
  file, or written to a log. Password authentication is delegated entirely to
  OpenSSH's native prompt.
- **Host-key verification is never disabled.** `StrictHostKeyChecking` and
  `UserKnownHostsFile` are never written to the config, so your existing
  global setting is respected.
- **The private key never leaves the machine.** Only `ssh-copy-id` — and only
  when you say yes — sends the public key.
- **The generated block contains no secrets.**
- **Permissions are enforced**: `~/.ssh` is `700`, the config is `600`,
  private keys `600`, public keys `644`.
- **Every input is validated** before use. No `eval`, no `sudo`, no
  command construction from user input.
- **Writes are atomic and preceded by a backup.** The real config is only
  replaced after OpenSSH accepts the candidate.
- **Host-key trust is yours to establish.** The script reminds you to verify
  the fingerprint on first connect.

### Limitations

- The script trusts the hostname you type; it does not verify fingerprints
  out-of-band.
- The remote `sshd` must already permit key authentication for the chosen
  user — the script does not change remote daemon configuration.
- `Match` blocks are detected and flagged, because conditional semantics can
  make a global alias behave unexpectedly.
- A passphrase-protected key needs an unlocked agent for the automated
  authentication test. The test uses `BatchMode=yes` so it never hangs
  waiting for a passphrase.
- The tool configures the **current user's** `~/.ssh`. Running it as root
  configures root's SSH, not yours.
- Key rotation is manual: use the timestamped backups and `ssh-keygen`.

---

## See also

- [`README.md`](README.md) — overview, architecture, test plan, security model
- [`LICENSE`](LICENSE) — BSD 3-Clause
- [`test-vpslink.sh`](test-vpslink.sh) — the regression suite
