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

# Colour is used only on a terminal. Piped or captured output (CI logs, for
# example) stays plain text so it can be grepped and parsed.
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != 'dumb' ]]; then
  C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_PASS=''; C_FAIL=''; C_BOLD=''; C_OFF=''
fi

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

ok()  { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$C_PASS" "$C_OFF" "$1"; }
info() { printf '  %sSKIP%s %s\n' "$C_BOLD" "$C_OFF" "$1"; }
bad() {
  FAIL=$((FAIL+1))
  FAILED_TESTS+=("$1")
  printf '  %sFAIL%s %s\n' "$C_FAIL" "$C_OFF" "$1"
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

# Snapshot the real SSH config so the suite can prove it did not touch it.
# The user may legitimately be using vpslink on their own machine, so the
# check is "unchanged by this run", not "contains no vpslink block".
REAL_CONFIG="$ORIG_HOME/.ssh/config"
if [[ -f $REAL_CONFIG ]]; then
  REAL_CONFIG_BEFORE=$(file_sha256 "$REAL_CONFIG")
else
  REAL_CONFIG_BEFORE='absent'
fi

# Portability lint for the "option after an operand" hazard.
#
# BSD and macOS use getopt, which stops at the first non-option argument.
# GNU coreutils permute the arguments and accept both orders, so a command
# such as "chmod 700 -- path" works on Linux but fails on macOS with
# "chmod: --: No such file or directory". On the tool that aborts the run
# under "set -e". Every "--" must therefore precede all operands.
find_option_after_operand() {
  awk '
    {
      line = $0
      sub(/#.*$/, "", line)
      gsub(/\[\[[^]]*\]\]/, " ", line)      # drop [[ ... ]] conditionals
      gsub(/\(\([^)]*\)\)/, " ", line)       # drop (( ... )) arithmetic
      n = split(line, tok, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        if (tok[i] != "--") continue
        # Only the tokens of the same simple command matter: a pipeline or
        # a list separator starts a new command.
        start = 2
        for (k = i - 1; k >= 2; k--) {
          if (tok[k] ~ /^[|;&]+$/ || tok[k] ~ /^\($/ || tok[k] ~ /^\{$/ ||
              tok[k] == "do" || tok[k] == "then" || tok[k] == "else") {
            start = k + 1
            break
          }
        }
        for (j = start; j < i; j++) {
          t = tok[j]
          if (t ~ /^-/) continue                    # a flag: fine
          if (t ~ /^[a-z_][a-zA-Z0-9_]*$/) continue # a command name: fine
          if (t ~ /\$\(/) continue                  # inside a substitution
          if (t ~ /^[&|;{}()!]+$/) continue         # a shell metacharacter
          printf "%s:%d: %s\n", FILENAME, FNR, $0
          found = 1
          break
        }
        break
      }
    }
    END { exit(found ? 1 : 0) }
  ' "$1"
}

section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }

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
backup=$(find "$HOME/.ssh" -name 'config.bak.*' -type f 2>/dev/null | head -n1)
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
assert_contains 'closed port is reported' "$out" 'Nothing is listening on'
assert_contains 'a closed port is distinguished from a filtered one' "$out" 'refused the connection'
# The final verdict must name the actual reason.
assert_contains 'the verdict names the connectivity reason' "$out" 'Connectivity: port 1 is closed'

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
leftovers=$(find "$HOME/.ssh" -name 'config.tmp.*' -type f 2>/dev/null | wc -l | tr -d '[:space:]')
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

# The TCP probe must distinguish a closed port from a filtered one: they have
# completely different causes and different fixes.
probe_tcp_port 127.0.0.1 1 3
assert_eq 'a closed port is classified as refused' 'refused' "$TCP_RESULT"

# An open local port must be classified as reachable.
LOCAL_PORT=45678
listener_started=0
if command -v python3 >/dev/null 2>&1; then
  python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $LOCAL_PORT))
s.listen(1)
time.sleep(20)
" >/dev/null 2>&1 &
  listener_pid=$!
  sleep 1
  listener_started=1
elif command -v nc >/dev/null 2>&1; then
  nc -l 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1 &
  listener_pid=$!
  sleep 1
  listener_started=1
fi

if ((listener_started)); then
  probe_tcp_port 127.0.0.1 "$LOCAL_PORT" 3
  assert_eq 'an open port is classified as reachable' 'reachable' "$TCP_RESULT"
  kill "$listener_pid" 2>/dev/null
  wait "$listener_pid" 2>/dev/null
else
  info 'No local listener available; skipping the reachable-port check.'
fi

# Portability lint: "--" must never follow an operand (BSD getopt hazard).
for f in "$SCRIPT_DIR/vpslink.sh" "$SCRIPT_DIR/run.sh" "$SCRIPT_DIR/test-vpslink.sh"; do
  out=$(find_option_after_operand "$f" 2>&1); rc=$?
  if ((rc == 0)); then
    ok "no option-after-operand in $(basename "$f")"
  else
    bad "no option-after-operand in $(basename "$f")" "$out"
  fi
done

# ===========================================================================
section '20. Installation and PATH setup'
# ===========================================================================
setup_home
out=$(env SHELL=/bin/bash "$SUT" --install --yes --install-dir "$HOME/bin" 2>&1); rc=$?
assert_eq '--install succeeds' 0 "$rc"
assert_file_exists 'the command is installed' "$HOME/bin/vpslink"
assert_file_mode 'the installed command is executable' "$HOME/bin/vpslink" '755'
assert_contains 'the PATH block marker is written' "$(cat "$HOME/.bashrc")" '# >>> vpslink >>>'
assert_contains 'the PATH export is written' "$(cat "$HOME/.bashrc")" 'export PATH='
assert_contains 'the closing marker is written' "$(cat "$HOME/.bashrc")" '# <<< vpslink <<<'
assert_file_mode 'a newly created rc file is readable' "$HOME/.bashrc" '644'

# Re-running must not duplicate the block.
env SHELL=/bin/bash "$SUT" --install --yes --install-dir "$HOME/bin" >/dev/null 2>&1
assert_eq 'the PATH block is not duplicated' 1 "$(grep -c '^# >>> vpslink >>>$' "$HOME/.bashrc")"

# An existing startup file keeps its content and permissions.
setup_home
printf '# my bashrc\nexport EDITOR=vim\n' > "$HOME/.bashrc"
chmod 600 "$HOME/.bashrc"
env SHELL=/bin/bash "$SUT" --install --yes --install-dir "$HOME/bin" >/dev/null 2>&1
assert_contains 'existing rc content is preserved' "$(cat "$HOME/.bashrc")" 'export EDITOR=vim'
assert_file_mode 'an existing rc file keeps its mode' "$HOME/.bashrc" '600'

# Uninstall removes both the command and the PATH block.
env SHELL=/bin/bash "$SUT" --uninstall --install-dir "$HOME/bin" >/dev/null 2>&1
assert_file_absent 'the installed command is removed' "$HOME/bin/vpslink"
assert_eq 'the PATH block is removed' 0 "$(grep -c 'vpslink' "$HOME/.bashrc")"
assert_contains 'the original rc content survives uninstall' "$(cat "$HOME/.bashrc")" 'export EDITOR=vim'
teardown_home

# The startup file and PATH syntax must match the detected shell.
SHELL_NAME='bash';      assert_eq 'bash uses .bashrc' "$HOME/.bashrc" "$(shell_rc_file)"
SHELL_NAME='zsh';       assert_eq 'zsh uses .zshrc' "$HOME/.zshrc" "$(shell_rc_file)"
SHELL_NAME='fish';      assert_eq 'fish uses config.fish' "$HOME/.config/fish/config.fish" "$(shell_rc_file)"
SHELL_NAME='csh';       assert_eq 'csh uses .cshrc' "$HOME/.cshrc" "$(shell_rc_file)"
SHELL_NAME='ksh';       assert_eq 'ksh uses .kshrc' "$HOME/.kshrc" "$(shell_rc_file)"
SHELL_NAME='sh';        assert_eq 'sh uses .profile' "$HOME/.profile" "$(shell_rc_file)"
SHELL_NAME='powershell'; assert_eq 'powershell uses a profile' "$HOME/.config/powershell/Microsoft.PowerShell_profile.ps1" "$(shell_rc_file)"
SHELL_NAME='elvish';    assert_eq 'elvish uses rc.elv' "$HOME/.elvish/rc.elv" "$(shell_rc_file)"
SHELL_NAME='nushell';   assert_eq 'nushell uses config.nu' "$HOME/.config/nushell/config.nu" "$(shell_rc_file)"
SHELL_NAME='xonsh';     assert_eq 'xonsh uses .xonshrc' "$HOME/.xonshrc" "$(shell_rc_file)"

SHELL_NAME='bash';      assert_contains 'bash uses an export' "$(shell_path_line /opt/bin)" 'export PATH='
SHELL_NAME='fish';      assert_contains 'fish uses fish_add_path' "$(shell_path_line /opt/bin)" 'fish_add_path'
SHELL_NAME='csh';       assert_contains 'csh uses setenv' "$(shell_path_line /opt/bin)" 'setenv PATH'
SHELL_NAME='powershell'; assert_contains 'powershell uses PathSeparator' "$(shell_path_line /opt/bin)" 'PathSeparator'
SHELL_NAME='elvish';    assert_contains 'elvish uses set-env' "$(shell_path_line /opt/bin)" 'set-env E:PATH'
SHELL_NAME='nushell';   assert_contains 'nushell uses prepend' "$(shell_path_line /opt/bin)" 'prepend'
SHELL_NAME='xonsh';     assert_contains 'xonsh uses os.environ' "$(shell_path_line /opt/bin)" 'os.environ'
SHELL_NAME='ksh';       assert_contains 'ksh uses an export' "$(shell_path_line /opt/bin)" 'export PATH='
SHELL_NAME='sh';        assert_contains 'sh uses an export' "$(shell_path_line /opt/bin)" 'export PATH='
assert_eq 'the shell name is left set for the caller' 'sh' "$SHELL_NAME"

# Shell name normalisation.
assert_eq 'bash is normalised' 'bash' "$(normalise_shell /bin/bash)"
assert_eq 'tcsh is normalised to csh' 'csh' "$(normalise_shell /usr/bin/tcsh)"
assert_eq 'dash is normalised to sh' 'sh' "$(normalise_shell /bin/dash)"
assert_eq 'an unknown shell falls back to sh' 'sh' "$(normalise_shell /weird/thing)"
assert_eq 'pwsh is normalised to powershell' 'powershell' "$(normalise_shell /usr/local/bin/pwsh)"
assert_eq 'nu is normalised to nushell' 'nushell' "$(normalise_shell /opt/homebrew/bin/nu)"

# ===========================================================================
section '21. The real user SSH config was not touched'
# ===========================================================================
if [[ -f $REAL_CONFIG ]]; then
  REAL_CONFIG_AFTER=$(file_sha256 "$REAL_CONFIG")
else
  REAL_CONFIG_AFTER='absent'
fi
assert_eq 'the real ~/.ssh/config is unchanged by the suite' "$REAL_CONFIG_BEFORE" "$REAL_CONFIG_AFTER"

# ===========================================================================
printf '\n%sResult: %d passed, %d failed%s\n' "$C_BOLD" "$PASS" "$FAIL" "$C_OFF"
if ((FAIL > 0)); then
  printf 'Failed tests:\n'
  for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
  exit 1
fi
exit 0
