#!/usr/bin/env bash
# test-vpslink.sh - isolated regression tests for vpslink.sh
#
# Every test runs against a throw-away HOME, so the real ~/.ssh/config is
# never modified. No root, no network dependency, no live VPS required.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SUT="$SCRIPT_DIR/vpslink.sh"
ORIG_HOME=$HOME
PASS=0
FAIL=0
FAILED_TESTS=()

# --- test helpers -----------------------------------------------------------

setup_home() {
  TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/vps-setup-test.XXXXXX")
  export HOME="$TEST_HOME"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
}

teardown_home() {
  if [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]]; then
    rm -rf -- "$TEST_HOME"
  fi
  TEST_HOME=''
  export HOME="$ORIG_HOME"
}

ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() {
  FAIL=$((FAIL+1))
  FAILED_TESTS+=("$1")
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '       %s\n' "$2"; fi
}

assert_eq() { # assert_eq <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

assert_ne() { # assert_ne <desc> <not-expected> <actual>
  if [[ "$2" != "$3" ]]; then ok "$1"; else bad "$1" "did not expect '$3'"; fi
}

assert_contains() { # assert_contains <desc> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "expected to find: $3"; fi
}

assert_not_contains() { # assert_not_contains <desc> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "did not expect: $3"; fi
}

# Print a file's permission bits as three octal digits, whatever the
# platform's stat reports: Linux "600", macOS/BSD "0600" or "100600".
file_mode() {
  local m
  m=$(stat -c '%a' "$1" 2>/dev/null) || m=$(stat -f '%Lp' "$1" 2>/dev/null) || m=''
  case "$m" in
    ''|*[!0-7]*) printf '?' ;;
    *) printf '%o' $(( 0$m & 0777 )) ;;
  esac
}

assert_file_mode() { # assert_file_mode <desc> <file> <expected-octal>
  local actual
  actual=$(file_mode "$2")
  if [[ "$actual" == "$3" ]]; then ok "$1"; else bad "$1" "expected mode $3, got $actual"; fi
}

assert_file_absent() { # assert_file_absent <desc> <file>
  if [[ ! -e "$2" ]]; then ok "$1"; else bad "$1" "file should not exist: $2"; fi
}

assert_file_exists() { # assert_file_exists <desc> <file>
  if [[ -e "$2" ]]; then ok "$1"; else bad "$1" "file should exist: $2"; fi
}

# Portable file checksum: sha256sum on Linux, shasum on macOS.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ===========================================================================
section '1. CLI surface: --help / --version / unknown option'
# ===========================================================================
out=$("$SUT" --help 2>&1); rc=$?
assert_eq '--help exits 0' 0 "$rc"
assert_contains '--help shows usage' "$out" 'Usage:'
assert_contains '--help documents --alias' "$out" '--alias NAME'

out=$("$SUT" --version 2>&1); rc=$?
assert_eq '--version exits 0' 0 "$rc"
assert_contains '--version prints a version string' "$out" '1.1.0'

out=$("$SUT" --definitely-not-an-option 2>&1); rc=$?
if ((rc != 0)); then ok 'unknown option exits non-zero'; else bad 'unknown option exits non-zero'; fi
assert_contains 'unknown option is reported' "$out" 'Unknown option'

# The original bug: a readonly "VERSION" in the parent shell must not break
# os-release parsing inside the script.
out=$(bash -c 'readonly VERSION=1.0.0; exec "$1" --help' _ "$SUT" 2>&1); rc=$?
assert_eq 'readonly VERSION in parent shell does not break the script' 0 "$rc"

# ===========================================================================
section '2. OS detection (regression: /etc/os-release collision)'
# ===========================================================================
setup_home
out=$("$SUT" --alias t1 --host 127.0.0.1 --user u --port 22 --auth password --yes --no-test 2>&1)
assert_not_contains 'no readonly-variable error from /etc/os-release' "$out" 'readonly variable'
assert_contains 'detects the OS' "$out" 'Distribution:'
assert_contains 'detects the architecture' "$out" 'Architecture:'
assert_contains 'detects the login shell' "$out" 'Login shell:'
assert_contains 'reports the OpenSSH version' "$out" 'OpenSSH:'
teardown_home

# ===========================================================================
section '3. Fresh setup writes a correct ssh_config block'
# ===========================================================================
setup_home
out=$("$SUT" --alias vps --host srv.example.com --user hemayet --port 999 \
        --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'missing private key is rejected'; else bad 'missing private key is rejected'; fi
assert_contains 'missing key error names the path' "$out" 'Private key not found'

# Create a real key and retry.
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C 'test' </dev/null
out=$("$SUT" --alias vps --host srv.example.com --user hemayet --port 999 \
        --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test 2>&1); rc=$?
assert_eq 'fresh setup succeeds' 0 "$rc"
cfg=$(cat "$HOME/.ssh/config")
assert_contains 'config contains Host vps' "$cfg" 'Host vps'
assert_contains 'config contains the HostName' "$cfg" 'HostName srv.example.com'
assert_contains 'config contains the User' "$cfg" 'User hemayet'
assert_contains 'config contains the custom Port' "$cfg" 'Port 999'
assert_contains 'config contains IdentityFile' "$cfg" 'IdentityFile'
assert_contains 'config contains IdentitiesOnly' "$cfg" 'IdentitiesOnly yes'
assert_contains 'config contains ServerAliveInterval' "$cfg" 'ServerAliveInterval 60'
assert_contains 'config contains ServerAliveCountMax' "$cfg" 'ServerAliveCountMax 3'
assert_contains 'config contains ConnectTimeout' "$cfg" 'ConnectTimeout 10'
assert_not_contains 'config has no password field' "$cfg" 'Password'
assert_not_contains 'config has no secret-looking key' "$cfg" 'PRIVATE KEY'
assert_file_mode 'ssh config mode is 600' "$HOME/.ssh/config" '600'
assert_file_mode '.ssh dir mode is 700' "$HOME/.ssh" '700'
teardown_home

# ===========================================================================
section '4. Idempotency: re-running must not duplicate the alias'
# ===========================================================================
setup_home
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C 'test' </dev/null
"$SUT" --alias vps --host srv.example.com --user hemayet --port 999 \
       --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test >/dev/null 2>&1
first_count=$(grep -c '^Host vps$' "$HOME/.ssh/config")
out=$("$SUT" --alias vps --host srv2.example.com --user hemayet --port 2222 \
        --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test 2>&1); rc=$?
second_count=$(grep -c '^Host vps$' "$HOME/.ssh/config")
assert_eq 'second run succeeds' 0 "$rc"
assert_eq 'exactly one Host vps block after re-run' 1 "$second_count"
assert_eq 'the first run also produced one block' 1 "$first_count"
cfg=$(cat "$HOME/.ssh/config")
assert_contains 're-run updated the hostname' "$cfg" 'HostName srv2.example.com'
assert_contains 're-run updated the port' "$cfg" 'Port 2222'
assert_not_contains 'old hostname is gone' "$cfg" 'srv.example.com'
marker_count=$(grep -c '^# BEGIN vpslink: vps$' "$HOME/.ssh/config")
assert_eq 'exactly one managed block marker' 1 "$marker_count"
teardown_home

# ===========================================================================
section '5. Existing unrelated config entries are preserved'
# ===========================================================================
setup_home
cat > "$HOME/.ssh/config" <<'EOF'
Host bastion
    HostName bastion.internal
    User admin
    Port 2222

Host *
    ServerAliveInterval 30
EOF
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C 'test' </dev/null
"$SUT" --alias vps --host srv.example.com --user hemayet --port 22 \
       --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test >/dev/null 2>&1
cfg=$(cat "$HOME/.ssh/config")
assert_contains 'unrelated Host bastion is preserved' "$cfg" 'Host bastion'
assert_contains 'unrelated bastion HostName is preserved' "$cfg" 'HostName bastion.internal'
assert_contains 'unrelated Host * block is preserved' "$cfg" 'Host *'
assert_contains 'unrelated ServerAliveInterval is preserved' "$cfg" 'ServerAliveInterval 30'
assert_contains 'new alias was added' "$cfg" 'Host vps'

# A config using the 2-space style of a hand-written file must survive too.
setup_home
cat > "$HOME/.ssh/config" <<'EOF'
Host github
  HostName github.com
  User git
  IdentityFile "/home/user/.ssh/id_ed25519_work"
  IdentitiesOnly yes
EOF
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C 'test' </dev/null
"$SUT" --alias vps --host srv.example.com --user hemayet \
       --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test >/dev/null 2>&1
cfg=$(cat "$HOME/.ssh/config")
assert_contains '2-space-indented entry is preserved' "$cfg" 'HostName github.com'
assert_contains 'quoted IdentityFile is preserved' "$cfg" 'id_ed25519_work'
teardown_home

# ===========================================================================
section '6. Backup of the original config'
# ===========================================================================
setup_home
printf 'Host old\n    HostName old.example.com\n' > "$HOME/.ssh/config"
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C 'test' </dev/null
"$SUT" --alias vps --host srv.example.com --user hemayet \
       --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test >/dev/null 2>&1
backup=$(find "$HOME/.ssh" -maxdepth 1 -name 'config.bak.*' -type f | head -n1)
if [[ -n "$backup" ]]; then
  ok 'a timestamped backup was created'
  assert_contains 'backup holds the original content' "$(cat "$backup")" 'Host old'
else
  bad 'a timestamped backup was created'
fi
teardown_home

# ===========================================================================
section '7. Input validation'
# ===========================================================================
setup_home
out=$("$SUT" --alias vps --host srv.example.com --user u --port 99999 --auth password --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'out-of-range port is rejected'; else bad 'out-of-range port is rejected'; fi
assert_contains 'invalid port message is shown' "$out" 'Invalid SSH port'

out=$("$SUT" --alias vps --host 'bad host!' --user u --port 22 --auth password --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'hostname with a space is rejected'; else bad 'hostname with a space is rejected'; fi

out=$("$SUT" --alias vps --host 'srv.example.com; rm -rf /' --user u --port 22 --auth password --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'hostname with shell metacharacters is rejected'; else bad 'hostname with shell metacharacters is rejected'; fi

out=$("$SUT" --alias '-oProxyCommand=evil' --host srv.example.com --user u --port 22 --auth password --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'alias starting with a dash is rejected'; else bad 'alias starting with a dash is rejected'; fi

out=$("$SUT" --alias vps --host 999.999.999.999 --user u --port 22 --auth password --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'out-of-range IPv4 octet is rejected'; else bad 'out-of-range IPv4 octet is rejected'; fi

out=$("$SUT" --alias vps --host 192.168.1.1 --user u --port 22 --auth password --yes --no-test 2>&1); rc=$?
assert_eq 'valid IPv4 address is accepted' 0 "$rc"

out=$("$SUT" --alias vps --host 2001:db8::1 --user u --port 22 --auth password --yes --no-test 2>&1); rc=$?
assert_eq 'valid IPv6 address is accepted' 0 "$rc"

out=$("$SUT" --alias vps --host srv.example.com --user u --port 22 --auth bogus --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'invalid auth method is rejected'; else bad 'invalid auth method is rejected'; fi

out=$("$SUT" --alias vps --host srv.example.com --user u --port 22 --auth password 2>&1); rc=$?
if ((rc != 0)); then ok 'non-interactive without --yes is rejected'; else bad 'non-interactive without --yes is rejected'; fi
assert_contains 'non-interactive without --yes explains why' "$out" 'requires --yes'

out=$("$SUT" --alias vps --host srv.example.com --user u --port 22 --auth password --yes --no-test 2>&1)
assert_not_contains 'non-interactive mode never asks a question' "$out" 'Apply this configuration?'

out=$("$SUT" --alias vps --host srv.example.com --user u --port 22 --auth key --key '/tmp/we"ird%key' --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'key path with quote or percent is rejected'; else bad 'key path with quote or percent is rejected'; fi
teardown_home

# ===========================================================================
section '8. Unmanaged duplicate alias handling'
# ===========================================================================
setup_home
printf 'Host vps\n    HostName manually-set.example.com\n    User someone\n' > "$HOME/.ssh/config"
out=$("$SUT" --alias vps --host srv.example.com --user hemayet --auth password --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'unmanaged duplicate alias is refused in --yes mode'; else bad 'unmanaged duplicate alias is refused in --yes mode'; fi
assert_contains 'unmanaged duplicate is explained' "$out" 'unmanaged'
assert_contains 'original unmanaged entry is untouched' "$(cat "$HOME/.ssh/config")" 'HostName manually-set.example.com'

# A shared "Host a b" line must be reported before it is replaced.
# Fully interactive: alias, host, user, port, auth=3(password), keepalive,
# timeout, wrapper, confirm, then "1" at the duplicate-alias menu.
setup_home
printf 'Host vps other\n    HostName shared.example.com\n' > "$HOME/.ssh/config"
out=$(printf 'vps\nsrv.example.com\nhemayet\n22\n3\n60\n10\nn\ny\n1\n' \
  | "$SUT" --no-test 2>&1)
assert_contains 'a shared Host line is reported' "$out" 'also defines other hosts'
teardown_home

# ===========================================================================
section '8b. A block written by the legacy marker prefix is still managed'
# ===========================================================================
setup_home
cat > "$HOME/.ssh/config" <<'EOF'
# BEGIN vps-login-setup: vps
Host vps
    HostName legacy.example.com
    User hemayet
    Port 22
# END vps-login-setup: vps
EOF
out=$("$SUT" --alias vps --host srv.example.com --user hemayet --port 999 \
        --auth password --yes --no-test 2>&1); rc=$?
assert_eq 'a legacy managed block is updated, not rejected' 0 "$rc"
cfg=$(cat "$HOME/.ssh/config")
assert_contains 'the legacy block was replaced' "$cfg" 'HostName srv.example.com'
assert_contains 'the new marker prefix is used' "$cfg" '# BEGIN vpslink: vps'
assert_not_contains 'the legacy marker is gone' "$cfg" '# BEGIN vps-login-setup: vps'
assert_eq 'still exactly one Host vps block' 1 "$(grep -c '^Host vps$' "$HOME/.ssh/config")"
teardown_home

# ===========================================================================
section '9. Idempotency of the interactive path (managed block replacement)'
# ===========================================================================
setup_home
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C 'test' </dev/null
"$SUT" --alias vps --host srv.example.com --user hemayet \
       --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test >/dev/null 2>&1
before=$(grep -c 'BEGIN vpslink' "$HOME/.ssh/config")
# Drive the fully interactive flow. Answer order:
#   alias, host, user, port, auth, key, keepalive, timeout, identities, wrapper, apply
printf 'vps\nnew.example.com\nhemayet\n22\n1\n%s\n60\n10\ny\nn\ny\n' "$HOME/.ssh/id_ed25519" \
  | "$SUT" --no-test >/dev/null 2>&1
after=$(grep -c 'BEGIN vpslink' "$HOME/.ssh/config")
assert_eq 'managed block is replaced, not duplicated' "$before" "$after"
assert_contains 'interactive re-run updated the hostname' "$(cat "$HOME/.ssh/config")" 'new.example.com'
teardown_home

# ===========================================================================
section '10. OpenSSH accepts the generated configuration'
# ===========================================================================
setup_home
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C 'test' </dev/null
"$SUT" --alias vps --host srv.example.com --user hemayet --port 999 \
       --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test >/dev/null 2>&1
if ssh -G -F "$HOME/.ssh/config" vps >/dev/null 2>&1; then
  ok 'ssh -G validates the generated config'
else
  bad 'ssh -G validates the generated config'
fi
eff=$(ssh -G -F "$HOME/.ssh/config" vps 2>/dev/null | awk '$1=="port"{print $2}')
assert_eq 'ssh -G resolves the custom port 999' '999' "$eff"
eff=$(ssh -G -F "$HOME/.ssh/config" vps 2>/dev/null | awk '$1=="user"{print $2}')
assert_eq 'ssh -G resolves the remote user' 'hemayet' "$eff"
eff=$(ssh -G -F "$HOME/.ssh/config" vps 2>/dev/null | awk '$1=="hostname"{print $2}')
assert_eq 'ssh -G resolves the hostname' 'srv.example.com' "$eff"

# Regression: "ssh -G" prints "host <alias>" as its first line. The script must
# read the "hostname" field, otherwise it reports a false override warning.
out=$("$SUT" --alias vps --host srv.example.com --user hemayet --port 999 \
        --auth key --key "$HOME/.ssh/id_ed25519" --yes --no-test 2>&1)
assert_not_contains 'no false hostname-override warning' "$out" 'wildcard may override'
assert_contains 'effective host is reported correctly' "$out" 'host=srv.example.com'
teardown_home

# ===========================================================================
section '11. Connectivity failure is reported honestly'
# ===========================================================================
setup_home
# Port 1 on localhost is closed -> "connection refused".
out=$("$SUT" --alias vps --host 127.0.0.1 --user u --port 1 --auth password --yes 2>&1)
assert_contains 'closed port is reported' "$out" 'Cannot reach'
# The exact wording depends on which probe tool is available (nc on most
# systems, /dev/tcp+timeout otherwise, neither on a bare macOS).
if [[ "$out" == *'closed or unreachable'* || "$out" == *'failed or timed out'* ]]; then
  ok 'the probe failure is described'
else
  bad 'the probe failure is described' "$out"
fi

# A non-resolving name -> DNS warning.
out=$("$SUT" --alias vps --host no-such-host.invalid --user u --port 22 --auth password --yes 2>&1)
assert_contains 'DNS failure is reported' "$out" 'DNS lookup failed'
assert_contains 'authentication failure is reported' "$out" 'did not succeed'
teardown_home

# ===========================================================================
section '12. Password authentication never stores a secret'
# ===========================================================================
setup_home
out=$("$SUT" --alias vps --host 127.0.0.1 --user u --port 1 --auth password --yes --no-test 2>&1)
cfg=$(cat "$HOME/.ssh/config" 2>/dev/null || echo '')
assert_not_contains 'no password line in the config' "$cfg" 'Password'
assert_not_contains 'no IdentityFile for password auth' "$cfg" 'IdentityFile'
assert_contains 'the summary explains the password prompt' "$out" 'OpenSSH prompts for the'
teardown_home

# ===========================================================================
section '12b. The final verdict must not claim verification that never happened'
# ===========================================================================
setup_home
out=$("$SUT" --alias vps --host 127.0.0.1 --user u --port 1 --auth password --yes --no-test 2>&1)
assert_not_contains 'skipped tests are not reported as verified' "$out" 'Setup complete and verified'
assert_contains 'skipped tests are disclosed' "$out" 'were NOT verified'

out=$("$SUT" --alias vps --host 127.0.0.1 --user u --port 1 --auth password --yes 2>&1)
assert_not_contains 'a failed test is not reported as verified' "$out" 'Setup complete and verified'
assert_contains 'a failed test is disclosed' "$out" 'not fully verified'
teardown_home

# ===========================================================================
section '13. Key generation is refused non-interactively and works interactively'
# ===========================================================================
setup_home
out=$("$SUT" --alias vps --host srv.example.com --user u --auth generate --key "$HOME/.ssh/newkey" --yes --no-test 2>&1); rc=$?
if ((rc != 0)); then ok 'non-interactive key generation is refused'; else bad 'non-interactive key generation is refused'; fi
assert_contains 'non-interactive key generation explains why' "$out" 'interactive terminal'

# Interactive generation with no passphrase (ssh-keygen must not need a tty).
# Answer order: alias, host, user, port, auth=2, key path, key type, keepalive,
#               timeout, identities, wrapper, confirm, passphrase(no)
printf 'vps\nsrv.example.com\nu\n22\n2\n%s\ned25519\n60\n10\ny\nn\ny\nn\n' "$HOME/.ssh/newkey" \
  | "$SUT" --no-test >/dev/null 2>&1
assert_file_exists 'interactive key generation creates the private key' "$HOME/.ssh/newkey"
assert_file_exists 'interactive key generation creates the public key' "$HOME/.ssh/newkey.pub"
if [[ -f "$HOME/.ssh/newkey" && -f "$HOME/.ssh/newkey.pub" ]]; then
  assert_file_mode 'new private key mode is 600' "$HOME/.ssh/newkey" '600'
  assert_file_mode 'new public key mode is 644' "$HOME/.ssh/newkey.pub" '644'
  keytype=$(ssh-keygen -l -f "$HOME/.ssh/newkey.pub" 2>/dev/null | awk '{print $NF}' | tr -d '()')
  assert_eq 'the generated key is ED25519' 'ED25519' "$keytype"
fi
teardown_home

# ===========================================================================
section '14. Existing keys are never overwritten silently'
# ===========================================================================
setup_home
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/keepme" -C 'original' </dev/null
before_sum=$(file_sha256 "$HOME/.ssh/keepme")
# Answer order: alias, host, user, port, auth=2, key path, key type, keepalive,
#               timeout, identities, wrapper, confirm, then "n" at the
#               overwrite-existing-key prompt.
printf 'vps\nsrv.example.com\nu\n22\n2\n%s\ned25519\n60\n10\ny\nn\ny\nn\n' "$HOME/.ssh/keepme" \
  | "$SUT" --no-test >/dev/null 2>&1
after_sum=$(file_sha256 "$HOME/.ssh/keepme")
assert_eq 'declining the overwrite leaves the key intact' "$before_sum" "$after_sum"
teardown_home

# ===========================================================================
section '15. Read-only / non-writable config is handled gracefully'
# ===========================================================================
setup_home
printf 'Host keep\n    HostName k.example.com\n' > "$HOME/.ssh/config"
chmod 400 "$HOME/.ssh/config"
out=$("$SUT" --alias vps --host srv.example.com --user u --auth password --yes --no-test 2>&1); rc=$?
if [[ "$(id -u)" -eq 0 ]]; then
  ok 'read-only config check skipped (running as root)'
else
  if ((rc != 0)); then ok 'read-only config is refused'; else bad 'read-only config is refused'; fi
  assert_contains 'read-only config is explained' "$out" 'not writable'
fi
chmod 600 "$HOME/.ssh/config"
teardown_home

# ===========================================================================
section '16. Interrupted execution leaves no partial state'
# ===========================================================================
setup_home
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -C 'test' </dev/null
# Fully interactive run, answer "n" at the final confirmation.
out=$(printf 'vps\nsrv.example.com\nu\n22\n1\n%s\n60\n10\ny\nn\nn\n' "$HOME/.ssh/id_ed25519" \
  | "$SUT" --no-test 2>&1)
assert_contains 'declining confirmation aborts cleanly' "$out" 'Cancelled'
assert_file_absent 'no config file is created when the user declines' "$HOME/.ssh/config"
leftovers=$(find "$HOME/.ssh" -maxdepth 1 -name 'config.tmp.*' -type f | wc -l)
assert_eq 'no temp files are left behind' 0 "$leftovers"
teardown_home

# ===========================================================================
section '17. Wrapper installation'
# ===========================================================================
setup_home
out=$("$SUT" --alias vps --host srv.example.com --user u --auth password --yes --no-test --wrapper 2>&1)
assert_file_exists 'wrapper is installed when requested' "$HOME/.local/bin/vps"
if [[ -x "$HOME/.local/bin/vps" ]]; then
  content=$(cat "$HOME/.local/bin/vps")
  assert_contains 'wrapper execs ssh with the alias' "$content" 'exec ssh vps'
  assert_contains 'wrapper forwards arguments' "$content" '"$@"'
fi
# Second run must not clobber the wrapper.
printf '#!/bin/sh\n# hand edited\n' > "$HOME/.local/bin/vps"
chmod 755 "$HOME/.local/bin/vps"
"$SUT" --alias vps --host srv2.example.com --user u --auth password --yes --no-test --wrapper >/dev/null 2>&1
assert_contains 'existing wrapper is not overwritten' "$(cat "$HOME/.local/bin/vps")" 'hand edited'
teardown_home

# ===========================================================================
section '19. Unit tests of the sourced functions'
# ===========================================================================
# The tool only runs when executed, so sourcing it exposes the functions
# for direct testing. Sourcing also applies the tool's strict mode, IFS and
# umask to this shell, so the harness settings are restored afterwards.
_saved_umask=$(umask)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/vpslink.sh"
set +e
IFS=$' \t\n'
umask "$_saved_umask"

# classify_platform must recognise macOS regardless of the capitalisation
# used by detect_os ("macOS" vs "macos" vs "darwin").
for id in 'macOS' 'macos' 'darwin' 'Darwin' 'MACOS'; do
  OS_ID=$id
  OS_FAMILY=''
  OS_SUPPORTED=''
  OS_PKG_HINT=''
  classify_platform
  if [[ $OS_SUPPORTED == 'yes' ]]; then
    ok "classify_platform recognises '$id' as supported"
  else
    bad "classify_platform recognises '$id' as supported" "got '$OS_SUPPORTED'"
  fi
done

# A recognised Linux family must be supported too.
OS_ID='ubuntu'; OS_FAMILY='debian'; OS_SUPPORTED=''; OS_PKG_HINT=''
classify_platform
assert_eq 'classify_platform recognises ubuntu/debian' 'yes' "$OS_SUPPORTED"
assert_contains 'a package manager hint is provided' "$OS_PKG_HINT" 'apt'

# An unknown distribution is flagged as partial but must not be fatal.
OS_ID='plan9'; OS_FAMILY=''
OS_SUPPORTED=''; OS_PKG_HINT=''
classify_platform
assert_eq 'an unknown distribution is reported as partial' 'partial' "$OS_SUPPORTED"
assert_eq 'classify_platform does not alter the OS id' 'plan9' "$OS_ID"
assert_eq 'classify_platform does not alter the OS family' '' "$OS_FAMILY"

# Input validators.
if is_valid_alias 'vps'; then ok 'is_valid_alias accepts "vps"'; else bad 'is_valid_alias accepts "vps"'; fi
if is_valid_alias '-bad'; then bad 'is_valid_alias rejects a leading dash'; else ok 'is_valid_alias rejects a leading dash'; fi
if is_valid_alias 'a b'; then bad 'is_valid_alias rejects spaces'; else ok 'is_valid_alias rejects spaces'; fi
if is_valid_alias 'a*b'; then bad 'is_valid_alias rejects glob characters'; else ok 'is_valid_alias rejects glob characters'; fi
if is_valid_port 22; then ok 'is_valid_port accepts 22'; else bad 'is_valid_port accepts 22'; fi
if is_valid_port 0; then bad 'is_valid_port rejects 0'; else ok 'is_valid_port rejects 0'; fi
if is_valid_port 65536; then bad 'is_valid_port rejects 65536'; else ok 'is_valid_port rejects 65536'; fi
if is_valid_port '999abc'; then bad 'is_valid_port rejects non-numeric input'; else ok 'is_valid_port rejects non-numeric input'; fi
if is_valid_user 'hemayet'; then ok 'is_valid_user accepts "hemayet"'; else bad 'is_valid_user accepts "hemayet"'; fi
if is_valid_user 'bad user'; then bad 'is_valid_user rejects spaces'; else ok 'is_valid_user rejects spaces'; fi
if is_valid_host 'srv.example.com'; then ok 'is_valid_host accepts a FQDN'; else bad 'is_valid_host accepts a FQDN'; fi
if is_valid_host '192.0.2.10'; then ok 'is_valid_host accepts an IPv4 literal'; else bad 'is_valid_host accepts an IPv4 literal'; fi
if is_valid_host '2001:db8::1'; then ok 'is_valid_host accepts an IPv6 literal'; else bad 'is_valid_host accepts an IPv6 literal'; fi
if is_valid_host '256.1.1.1'; then bad 'is_valid_host rejects an out-of-range octet'; else ok 'is_valid_host rejects an out-of-range octet'; fi
if is_valid_host 'srv..example.com'; then bad 'is_valid_host rejects an empty label'; else ok 'is_valid_host rejects an empty label'; fi
if is_valid_host '-srv.example.com'; then bad 'is_valid_host rejects a leading dash'; else ok 'is_valid_host rejects a leading dash'; fi
if is_valid_host 'srv.example.com;rm'; then bad 'is_valid_host rejects a semicolon'; else ok 'is_valid_host rejects a semicolon'; fi

# os_release_get must parse rather than execute the file.
os_release_get ID /etc/os-release >/dev/null 2>&1
assert_ne 'os_release_get finds an ID in /etc/os-release' 'not-found' "$?"

# The marker constants must be the ones written into the config.
assert_eq 'the managed-block prefix is "vpslink"' 'vpslink' "$MARKER_PREFIX"
assert_eq 'the legacy prefix is still recognised' 'vps-login-setup' "$LEGACY_MARKER_PREFIX"

# ===========================================================================
section '20. The real user SSH config was not touched'
# ===========================================================================
real_config="$ORIG_HOME/.ssh/config"
if [[ -f "$real_config" ]]; then
  if grep -q 'vpslink' "$real_config" 2>/dev/null; then
    bad 'the real ~/.ssh/config has no vpslink block'
  else
    ok 'the real ~/.ssh/config has no vpslink block'
  fi
else
  ok 'the real ~/.ssh/config does not exist (untouched)'
fi

# ===========================================================================
printf '\n\033[1mResult: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if ((FAIL > 0)); then
  printf 'Failed tests:\n'
  for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
  exit 1
fi
exit 0
