#!/usr/bin/env bash
# vpslink.sh — configure a reusable SSH host alias for a VPS.
#
# Bash + OpenSSH client only. No root privileges, no third-party packages.
#
# Security model:
#   * Passwords are never accepted as arguments, stored, or logged.
#   * Host-key verification is never disabled (StrictHostKeyChecking is left
#     at the OpenSSH default so the first connection records the host key
#     through the normal trust-on-first-use prompt).
#   * The private key never leaves the local machine; only the public key is
#     offered for installation on the remote host.
#   * All changes to ~/.ssh/config are preceded by a timestamped backup and
#     are written atomically via a temp file in the same directory.
#   * No remote-side configuration, firewall, or service changes are made.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# NOTE: do not name this variable "VERSION" -- /etc/os-release exports a
# "VERSION" key and sourcing that file (or even parsing it into the current
# shell) would collide with a readonly variable of the same name.
readonly SCRIPT_VERSION='1.1.0'
readonly SCRIPT_NAME="${0##*/}"

# Markers delimiting the block this tool owns in ~/.ssh/config. The legacy
# prefix is still recognised so a config written by an older release is
# updated in place instead of being reported as a foreign alias.
readonly MARKER_PREFIX='vpslink'
readonly LEGACY_MARKER_PREFIX='vps-login-setup'

# ---------------------------------------------------------------------------
# Presentation helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

info()    { printf '%s[INFO]%s %s\n' "$CYAN" "$RESET" "$*"; }
success() { printf '%s[ OK ]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
error()   { printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2; }
step()    { printf '\n%s==>%s %s\n' "$BOLD" "$RESET" "$*"; }
die()     { error "$*"; exit 1; }

usage() {
  cat <<'USAGE'
vpslink - configure a reusable SSH alias for a VPS

Usage:
  ./vpslink.sh
  ./vpslink.sh --alias vps --host srv.example.com --user hemayet \
      --port 999 --auth key --key ~/.ssh/id_ed25519 --yes

Options:
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
  --yes               Skip the interactive confirmation
  --version           Print the script version
  --help, -h          Show this help

Safety:
  * Passwords are never accepted as arguments and are never stored.
  * Host-key checking is never disabled.
  * The existing ~/.ssh/config is backed up before any modification.
  * Re-running the script updates the managed block instead of duplicating it.
USAGE
}

# ---------------------------------------------------------------------------
# Cleanup / interrupt handling
# ---------------------------------------------------------------------------
TMP_FILES=()

cleanup() {
  local f
  for f in ${TMP_FILES+"${TMP_FILES[@]}"}; do
    [[ -n "$f" && -e "$f" ]] && rm -f -- "$f"
  done
  return 0
}

on_interrupt() {
  printf '\n'
  warn 'Interrupted by user. No changes were applied beyond completed steps.'
  cleanup
  exit 130
}

track_tmp() { TMP_FILES+=("$1"); }

# ---------------------------------------------------------------------------
# OS / environment detection
# ---------------------------------------------------------------------------

# Read a single key from an os-release style file.
# The file is parsed rather than sourced: sourcing executes the file's content
# and would overwrite (or collide with) variables in the current shell.
os_release_get() {
  local key=$1 file=${2:-/etc/os-release} line value='' quoted
  [[ -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ $line == "$key="* ]] || continue
    value=${line#*=}
    # Strip one layer of matching surrounding quotes.
    if [[ ${#value} -ge 2 ]]; then
      quoted=${value:0:1}
      if [[ ( "$quoted" == '"' && "${value: -1}" == '"' ) ||
            ( "$quoted" == "'" && "${value: -1}" == "'" ) ]]; then
        value=${value:1:${#value}-2}
      fi
    fi
    printf '%s' "$value"
    return 0
  done < "$file"
  return 1
}

detect_os() {
  local os='' distro='' version='' codename='' family='' arch kernel login_shell

  arch=$(uname -m 2>/dev/null || printf 'unknown')
  kernel=$(uname -r 2>/dev/null || printf 'unknown')
  login_shell=${SHELL##*/}
  [[ -n "$login_shell" ]] || login_shell='unknown'

  if [[ -r /etc/os-release ]]; then
    os=$(os_release_get ID /etc/os-release || printf 'Linux')
    distro=$(os_release_get PRETTY_NAME /etc/os-release || printf 'Linux')
    version=$(os_release_get VERSION_ID /etc/os-release || printf 'unknown')
    codename=$(os_release_get VERSION_CODENAME /etc/os-release || printf '')
    family=$(os_release_get ID_LIKE /etc/os-release || printf '')
  elif [[ "$(uname -s 2>/dev/null || printf '')" == 'Darwin' ]]; then
    os='macOS'; distro='macOS'
    version=$(sw_vers -productVersion 2>/dev/null || printf 'unknown')
  else
    os=$(uname -s 2>/dev/null || printf 'unknown')
    distro=$os
    version=$kernel
  fi

  printf '  OS:            %s\n' "$os"
  printf '  Distribution:  %s\n' "$distro"
  printf '  Version:       %s%s\n' "$version" "${codename:+ ($codename)}"
  [[ -z "$family" ]] || printf '  Family:        %s\n' "$family"
  printf '  Architecture:  %s\n' "$arch"
  printf '  Kernel:        %s\n' "$kernel"
  printf '  Login shell:   %s\n' "$login_shell"
  if command -v ssh >/dev/null 2>&1; then
    printf '  OpenSSH:       %s\n' "$(ssh -V 2>&1 | head -n1)"
  else
    printf '  OpenSSH:       not installed\n'
  fi

  OS_ID=$os
  OS_FAMILY=$family
  OS_DISTRO=$distro
}

# Map the detected distribution family to a package-manager hint and decide
# whether the platform is fully supported or only partially supported.
classify_platform() {
  OS_SUPPORTED='yes'
  OS_PKG_HINT='Install the OpenSSH client with your package manager.'

  case "$OS_FAMILY" in
    debian*|ubuntu*)
      OS_PKG_HINT='Debian/Ubuntu : sudo apt install openssh-client' ;;
    fedora*|rhel*|centos*)
      OS_PKG_HINT='Fedora/RHEL   : sudo dnf install openssh-clients' ;;
    arch*|manjaro*|endeavouros*)
      OS_PKG_HINT='Arch          : sudo pacman -S openssh' ;;
    suse*)
      OS_PKG_HINT='openSUSE      : sudo zypper install openssh' ;;
    alpine*)
      OS_PKG_HINT='Alpine       : sudo apk add openssh-client' ;;
    darwin*)
      OS_PKG_HINT='macOS         : xcode-select --install' ;;
    *)
      case "$OS_ID" in
        debian|ubuntu|linuxmint|raspbian|kali|fedora|rhel|centos|rocky|alma|arch|manjaro|opensuse*|alpine)
          OS_SUPPORTED='yes' ;;
        *)
          OS_SUPPORTED='partial'
          OS_PKG_HINT='Install the OpenSSH client with your package manager.' ;;
      esac
      ;;
  esac

  # Compare case-insensitively: detect_os reports "macOS", but the value may
  # also arrive as "macos" or "darwin" from a caller. ${var,,} needs bash 4,
  # so tr is used instead to stay compatible with bash 3.2 on macOS.
  local os_lc family_lc
  os_lc=$(printf '%s' "$OS_ID" | tr '[:upper:]' '[:lower:]')
  family_lc=$(printf '%s' "$OS_FAMILY" | tr '[:upper:]' '[:lower:]')
  if [[ "$os_lc" == 'macos' || "$os_lc" == 'darwin' ||
        "$family_lc" == *darwin* || "$family_lc" == *macos* ]]; then
    OS_SUPPORTED='yes'
    OS_PKG_HINT='macOS         : xcode-select --install'
  fi
}

check_dependencies() {
  local missing=()
  command -v ssh >/dev/null 2>&1 || missing+=('ssh (OpenSSH client)')
  command -v awk >/dev/null 2>&1 || missing+=('awk')
  command -v mktemp >/dev/null 2>&1 || missing+=('mktemp')
  command -v chmod >/dev/null 2>&1 || missing+=('chmod')
  command -v cp >/dev/null 2>&1 || missing+=('cp')
  command -v date >/dev/null 2>&1 || missing+=('date')
  command -v grep >/dev/null 2>&1 || missing+=('grep')

  if ((${#missing[@]} > 0)); then
    error "Missing required utilities: ${missing[*]}"
    printf '  Install them with your package manager, e.g.:\n'
    printf '    %s\n' "$OS_PKG_HINT"
    printf '    macOS         : xcode-select --install\n'
    exit 1
  fi

  if [[ $OS_SUPPORTED == 'partial' ]]; then
    warn "Distribution '$OS_DISTRO' is not in the tested support list."
    warn 'The script still works: it only writes a standard OpenSSH host alias to'
    # shellcheck disable=SC2088  # literal path text shown to the user
    warn '~/.ssh/config. Expect to adjust the package-manager hint if something is missing.'
  fi

  case "$(uname -s 2>/dev/null || printf '')" in
    Linux|Darwin) ;;
    *)
      warn "Uncommon platform detected ($(uname -s 2>/dev/null || printf unknown))."
      warn 'The standard OpenSSH configuration format is still used.'
      ;;
  esac

  if [[ ! -d "$HOME" ]]; then
    die "HOME is not set or does not exist; cannot locate ~/.ssh"
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    warn 'Running as root. SSH keys will be installed for the root account.'
  fi
}

# ---------------------------------------------------------------------------
# Input helpers
# ---------------------------------------------------------------------------

# Read a single value from stdin. Returns non-zero on EOF so callers can
# distinguish "user typed nothing" from "input stream closed".
prompt_value() {
  local prompt=$1 default_value=$2 answer=''
  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " answer || { printf '\n'; return 1; }
  else
    read -r -p "$prompt: " answer || { printf '\n'; return 1; }
  fi
  printf '%s' "${answer:-$default_value}"
}

is_valid_alias() {
  # No leading dash (would be read as an ssh option), no glob characters.
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

is_valid_user() {
  [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*\$?$ ]]
}

is_valid_port() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

is_valid_interval() {
  [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 <= 86400))
}

is_valid_host() {
  local host=$1 label octet
  [[ -n $host && $host != -* && $host != *[[:space:]]* && $host != */* && $host != *\** ]] || return 1

  if [[ $host =~ ^[0-9.]+$ ]]; then
    [[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local old_ifs=$IFS
    IFS='.'
    local -a octets=()
    read -r -a octets <<< "$host"
    IFS=$old_ifs
    for octet in "${octets[@]}"; do
      [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
      ((10#$octet <= 255)) || return 1
    done
    return 0
  fi

  if [[ $host == *:* ]]; then
    # IPv6: hex groups, colons and an optional zone identifier.
    [[ $host =~ ^[0-9A-Fa-f:]+(%[0-9A-Za-z._-]+)?$ ]] || return 1
    if [[ $host == *:::* ]]; then
      return 1
    fi
    return 0
  fi

  [[ ${#host} -le 253 ]] || return 1
  [[ $host != *..* ]] || return 1
  local old_ifs=$IFS
  IFS='.'
  local -a labels=()
  read -r -a labels <<< "${host%.}"
  IFS=$old_ifs
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 ]] || return 1
    [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

expand_path() {
  # shellcheck disable=SC2088  # "'~/'*" is a literal pattern match, not a tilde expansion
  case "$1" in
    '~')   printf '%s' "$HOME" ;;
    '~/'*) printf '%s/%s' "$HOME" "${1#~/}" ;;
    /*)    printf '%s' "$1" ;;
    *)     printf '%s/%s' "$PWD" "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Configuration collection
# ---------------------------------------------------------------------------
collect_configuration() {
  local choice

  if ((NONINTERACTIVE == 0)); then
    step 'Configuration'
    ALIAS=$(prompt_value 'SSH alias' 'vps') || die 'Input stream closed.'
    HOST=$(prompt_value 'VPS FQDN or IP address' '') || die 'Input stream closed.'
    [[ -n $HOST ]] || die 'A hostname or IP address is required.'
    REMOTE_USER=$(prompt_value 'SSH username' "${USER:-$(id -un)}") || die 'Input stream closed.'
    PORT=$(prompt_value 'SSH port' '22') || die 'Input stream closed.'

    printf '\n%sAuthentication method%s\n' "$BOLD" "$RESET"
    printf '  1) Existing private key\n'
    printf '  2) Generate a new key pair (Ed25519)\n'
    printf '  3) Password authentication (native OpenSSH prompt)\n'
    read -r -p 'Choose [1]: ' choice || { printf '\n'; die 'Input stream closed.'; }
    case "${choice:-1}" in
      1) AUTH='key'
         KEY_PATH=$(prompt_value 'Private key path' "$HOME/.ssh/id_ed25519") || die 'Input stream closed.'
         ;;
      2) AUTH='generate'
         KEY_PATH=$(prompt_value 'New private key path' "$HOME/.ssh/id_ed25519") || die 'Input stream closed.'
         ;;
      3) AUTH='password'
         KEY_PATH=''
         ;;
      *) die 'Choose 1, 2, or 3.' ;;
    esac

    if [[ $AUTH == 'generate' ]]; then
      KEY_TYPE=$(prompt_value 'Key type (ed25519 or rsa)' 'ed25519') || die 'Input stream closed.'
    fi

    KEEPALIVE=$(prompt_value 'ServerAliveInterval seconds (0 disables)' '60') || die 'Input stream closed.'
    TIMEOUT=$(prompt_value 'Connection timeout seconds' '10') || die 'Input stream closed.'

    if [[ $AUTH != 'password' ]]; then
      read -r -p 'Offer only the configured key to the server? [Y/n]: ' choice || { printf '\n'; die 'Input stream closed.'; }
      if [[ ${choice:-Y} =~ ^[Nn]$ ]]; then IDENTITIES_ONLY='no'; else IDENTITIES_ONLY='yes'; fi
    fi

    read -r -p "Also install a '$ALIAS' wrapper command in ~/.local/bin? [y/N]: " choice || { printf '\n'; die 'Input stream closed.'; }
    if [[ ${choice:-N} =~ ^[Yy]$ ]]; then INSTALL_WRAPPER=1; fi
  else
    [[ -n $AUTH ]] || AUTH='key'
    [[ -n $ALIAS && -n $HOST && -n $REMOTE_USER ]] ||
      die 'Non-interactive mode requires --alias, --host and --user.'
    ((ASSUME_YES == 1)) || die 'Non-interactive mode requires --yes.'
    if [[ $AUTH != 'password' && -z $KEY_PATH ]]; then
      KEY_PATH="$HOME/.ssh/id_ed25519"
    fi
  fi
}

validate_inputs() {
  is_valid_alias "$ALIAS" || die "Invalid alias '$ALIAS'. Use 1-64 letters, digits, dots, underscores or hyphens."
  is_valid_host "$HOST" || die "Invalid hostname or IP address: $HOST"
  is_valid_user "$REMOTE_USER" || die "Invalid SSH username: $REMOTE_USER"
  is_valid_port "$PORT" || die "Invalid SSH port: $PORT (expected 1-65535)."
  is_valid_interval "$KEEPALIVE" || die 'Keepalive must be an integer from 0 to 86400.'
  is_valid_interval "$TIMEOUT" || die 'Timeout must be an integer from 1 to 86400.'
  ((10#$TIMEOUT >= 1)) || die 'Timeout must be at least 1 second.'

  case "$AUTH" in
    key|generate|password) ;;
    *) die "Invalid authentication method: $AUTH (expected key, generate or password)." ;;
  esac

  case "$KEY_TYPE" in
    ed25519|rsa) ;;
    *) die "Invalid key type: $KEY_TYPE (expected ed25519 or rsa)." ;;
  esac

  if [[ $AUTH == 'key' || $AUTH == 'generate' ]]; then
    [[ -n $KEY_PATH ]] || die 'A private key path is required for this authentication method.'
    KEY_PATH=$(expand_path "$KEY_PATH")
    [[ $KEY_PATH != *$'\n'* && $KEY_PATH != *$'\r'* ]] || die 'Newlines are not allowed in paths.'
    [[ $KEY_PATH != *' '* ]] || die 'Spaces are not supported in the key path (ssh_config quoting is ambiguous).'
    # A double quote or backslash would break the quoted IdentityFile value, and
    # "%" is a token in ssh_config (%%, %h, %r, ...), so it must not appear raw.
    if [[ $KEY_PATH == *[\"\\%]* ]]; then
      die 'The key path may not contain double quotes, backslashes or percent signs.'
    fi
  else
    KEY_PATH=''
  fi

  if [[ $AUTH == 'key' ]]; then
    [[ -f $KEY_PATH ]] || die "Private key not found: $KEY_PATH"
    [[ -r $KEY_PATH ]] || die "Private key is not readable: $KEY_PATH"
  fi
}

# ---------------------------------------------------------------------------
# Key management
# ---------------------------------------------------------------------------
manage_ssh_keys() {
  [[ $AUTH == 'generate' ]] || return 0

  step 'SSH key generation'

  command -v ssh-keygen >/dev/null 2>&1 || die 'ssh-keygen is required to generate a key (install openssh-client).'

  if ((NONINTERACTIVE == 1)); then
    # ssh-keygen reads the passphrase from the terminal, and an unencrypted
    # key is a silent security downgrade. Fail loudly instead of guessing.
    die 'Key generation needs an interactive terminal for the passphrase prompt. Run this script without --alias/--host/--user, or create the key manually with ssh-keygen first.'
  fi

  local key_dir
  key_dir=$(dirname -- "$KEY_PATH")
  mkdir -p -- "$key_dir"
  chmod -- 700 "$key_dir"

  if [[ -e $KEY_PATH || -e $KEY_PATH.pub ]]; then
    warn "A key already exists at $KEY_PATH"
    if ((ASSUME_YES == 1)); then
      die 'Refusing to overwrite an existing key in --yes mode. Use a different --key path.'
    fi
    local answer stamp
    read -r -p 'Back up and overwrite the existing key pair? [y/N]: ' answer || { printf '\n'; die 'Input stream closed.'; }
    [[ $answer =~ ^[Yy]$ ]] || die 'Key generation cancelled; no key was overwritten.'
    stamp=$(date +%Y%m%d%H%M%S)
    [[ ! -e $KEY_PATH ]] || { cp -p -- "$KEY_PATH" "$KEY_PATH.bak.$stamp"; info "Backed up $KEY_PATH"; }
    [[ ! -e $KEY_PATH.pub ]] || { cp -p -- "$KEY_PATH.pub" "$KEY_PATH.pub.bak.$stamp"; info "Backed up $KEY_PATH.pub"; }
  fi

  local -a keygen_args=(-t "$KEY_TYPE" -C "${REMOTE_USER}@${HOST}" -f "$KEY_PATH")
  if [[ $KEY_TYPE == 'rsa' ]]; then
    keygen_args+=(-b 4096)
  else
    keygen_args+=(-a 64)
  fi

  if ((NONINTERACTIVE == 0)); then
    local pass_choice
    read -r -p 'Protect the private key with a passphrase? [Y/n]: ' pass_choice || { printf '\n'; die 'Input stream closed.'; }
    if [[ ${pass_choice:-Y} =~ ^[Nn]$ ]]; then
      # No passphrase: -N '' is supplied to ssh-keygen, never stored anywhere.
      ssh-keygen "${keygen_args[@]}" -N '' </dev/null
    else
      # ssh-keygen prompts for the passphrase itself; it is never echoed,
      # never passed on the command line, and never written to disk by us.
      ssh-keygen "${keygen_args[@]}"
    fi
  else
    # Non-interactive: let ssh-keygen prompt for the passphrase on the terminal.
    # A passphrase is never accepted via a command-line argument.
    ssh-keygen "${keygen_args[@]}"
  fi

  chmod -- 600 "$KEY_PATH"
  [[ ! -f $KEY_PATH.pub ]] || chmod -- 644 "$KEY_PATH.pub"

  success "SSH key pair created: $KEY_PATH"
}

# Offer a guided ssh-copy-id run. Only the public key is transmitted.
# ssh-copy-id needs the VPS password, which OpenSSH prompts for natively.
offer_copy_id() {
  [[ $AUTH == 'generate' ]] || return 0
  [[ -f $KEY_PATH.pub ]] || return 0
  command -v ssh-copy-id >/dev/null 2>&1 || return 0
  ((NONINTERACTIVE == 0)) || return 0

  local answer
  printf '\n'
  read -r -p 'Install the public key on the VPS now? (you will be asked for the VPS password) [y/N]: ' answer \
    || { printf '\n'; return 0; }
  [[ $answer =~ ^[Yy]$ ]] || return 0

  info "Running: ssh-copy-id -i $KEY_PATH.pub -p $PORT $REMOTE_USER@$HOST"
  local rc=0
  ssh-copy-id -i "$KEY_PATH.pub" -p "$PORT" "$REMOTE_USER@$HOST" || rc=$?
  if ((rc == 0)); then
    success 'Public key installed on the VPS.'
  else
    warn "ssh-copy-id failed (exit $rc). Install the public key manually."
    printf '  cat "%s.pub"   # copy this output into ~/.ssh/authorized_keys on the VPS\n' "$KEY_PATH"
  fi
}

# ---------------------------------------------------------------------------
# SSH config management
# ---------------------------------------------------------------------------
backup_ssh_config() {
  local config=$1 backup
  [[ -e $config ]] || return 0
  backup="${config}.bak.$(date +%Y%m%d%H%M%S)"
  cp -p -- "$config" "$backup" || die "Could not back up $config"
  chmod -- 600 "$backup" 2>/dev/null || true
  info "Backup created: $backup"
}

# Print the alias names defined in an ssh_config file (one per line).
ssh_config_aliases() {
  local file=$1
  [[ -f $file ]] || return 0
  awk '
    /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]/ {
      for (i = 2; i <= NF; i++) {
        name = $i
        gsub(/^[*?!]/, "", name)
        if (name != "") print name
      }
    }
  ' "$file"
}

# Does the config define the given alias?
config_has_alias() {
  local file=$1 alias=$2
  [[ -f $file ]] || return 1
  ssh_config_aliases "$file" | grep -Fxqi -- "$alias"
}

# Remove the block that defines an alias: the "Host" line that mentions it
# plus every option line that follows it, up to the next "Host" keyword.
remove_alias_block() {
  local file=$1 alias=$2
  awk -v target="$alias" '
    BEGIN { IGNORECASE = 1; skip = 0 }
    /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]/ {
      skip = 0
      for (i = 2; i <= NF; i++) {
        name = $i
        gsub(/^[*?!]/, "", name)
        if (name == target) skip = 1
      }
      if (skip) next
    }
    skip { next }
    { print }
  ' "$file"
}

# Strip a previously written managed block (markers) from the config.
remove_managed_block() {
  local file=$1 marker_start=$2 marker_end=$3
  awk -v start="$marker_start" -v end="$marker_end" '
    $0 == start { skip = 1; next }
    $0 == end   { skip = 0; next }
    !skip       { print }
  ' "$file"
}

configure_ssh_alias() {
  step 'SSH configuration'

  local ssh_dir="$HOME/.ssh"
  local config="$HOME/.ssh/config"
  local tmp marker_start marker_end existing=0 managed=0 choice
  local marker_prefix=$MARKER_PREFIX

  mkdir -p -- "$ssh_dir"
  chmod -- 700 "$ssh_dir"
  [[ -w $ssh_dir ]] || die "SSH directory is not writable: $ssh_dir"

  if [[ -e $config ]]; then
    [[ -w $config ]] || die "SSH config is not writable: $config"
    chmod -- 600 "$config" 2>/dev/null || true
    if config_has_alias "$config" "$ALIAS"; then
      existing=1
      if grep -Fqx -- "# BEGIN $MARKER_PREFIX: $ALIAS" "$config"; then
        managed=1
      elif grep -Fqx -- "# BEGIN $LEGACY_MARKER_PREFIX: $ALIAS" "$config"; then
        # Written by an older version of this tool. Treat it as managed so the
        # block is replaced instead of being reported as a foreign alias.
        managed=1
        marker_prefix=$LEGACY_MARKER_PREFIX
      fi
    fi
    if grep -qi '^[[:space:]]*Match[[:space:]]' "$config"; then
      warn 'The config contains "Match" blocks; review the result carefully after the change.'
    fi
  else
    info "No existing SSH config found; $config will be created."
  fi

  if ((existing)) && ((managed == 0)); then
    warn "Alias '$ALIAS' already exists in $config and was not created by this script."
    # A "Host a b" line defines several aliases at once; removing it would
    # silently drop the others, so the user is told before that happens.
    local shared
    shared=$(awk -v target="$ALIAS" '
      BEGIN { IGNORECASE = 1 }
      /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]/ {
        n = 0
        for (i = 2; i <= NF; i++) {
          name = $i
          gsub(/^[*?!]/, "", name)
          if (name == target) found = 1
          if (name != "") n++
        }
        if (found && n > 1) { print; exit }
        found = 0
      }
    ' "$config" 2>/dev/null || true)
    if [[ -n $shared ]]; then
      warn "That entry also defines other hosts: ${shared#*[[:space:]]}"
      warn 'Replacing it will remove those definitions as well.'
    fi
    if ((ASSUME_YES == 1)); then
      die "Alias '$ALIAS' exists and is unmanaged; rerun interactively to choose how to proceed."
    fi
    printf '  1) Replace the existing definition of this alias\n'
    printf '  2) Use a different alias name\n'
    printf '  3) Cancel without changes\n'
    read -r -p 'Choose [3]: ' choice || { printf '\n'; die 'Input stream closed.'; }
    case "${choice:-3}" in
      1) managed=1 ;;
      2)
        local new_alias
        read -r -p 'New alias: ' new_alias || { printf '\n'; die 'Input stream closed.'; }
        is_valid_alias "$new_alias" || die "Invalid alias: $new_alias"
        if config_has_alias "$config" "$new_alias"; then
          die "Alias '$new_alias' already exists in $config."
        fi
        ALIAS=$new_alias
        marker_prefix=$MARKER_PREFIX
        existing=0
        ;;
      *) die 'Cancelled; the SSH configuration was not modified.' ;;
    esac
  fi

  # The markers are derived from the final alias, right before writing.
  local remove_start="# BEGIN $marker_prefix: $ALIAS"
  local remove_end="# END $marker_prefix: $ALIAS"
  local write_start="# BEGIN $MARKER_PREFIX: $ALIAS"
  local write_end="# END $MARKER_PREFIX: $ALIAS"

  backup_ssh_config "$config"

  tmp=$(mktemp "${config}.tmp.XXXXXX")
  track_tmp "$tmp"

  if [[ -f $config ]]; then
    if ((managed)) && grep -Fqx -- "$remove_start" "$config"; then
      remove_managed_block "$config" "$remove_start" "$remove_end" > "$tmp"
    elif ((existing)); then
      remove_alias_block "$config" "$ALIAS" > "$tmp"
    else
      cat -- "$config" > "$tmp"
    fi
  else
    : > "$tmp"
  fi

  {
    printf '\n%s\nHost %s\n' "$write_start" "$ALIAS"
    printf '    HostName %s\n' "$HOST"
    printf '    User %s\n' "$REMOTE_USER"
    printf '    Port %s\n' "$PORT"
    if [[ $AUTH == 'key' || $AUTH == 'generate' ]]; then
      printf '    IdentityFile "%s"\n' "$KEY_PATH"
      printf '    IdentitiesOnly %s\n' "$IDENTITIES_ONLY"
    fi
    if ((10#$KEEPALIVE > 0)); then
      printf '    ServerAliveInterval %s\n' "$KEEPALIVE"
      printf '    ServerAliveCountMax 3\n'
    fi
    printf '    ConnectTimeout %s\n' "$TIMEOUT"
    printf '%s\n' "$write_end"
  } >> "$tmp"

  chmod -- 600 "$tmp"

  # Validate the staged file with OpenSSH before it replaces the real config.
  if ! ssh -G -F "$tmp" "$ALIAS" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    die 'OpenSSH rejected the staged configuration; the original config is unchanged.'
  fi

  mv -f -- "$tmp" "$config"
  chmod -- 600 "$config"
  cleanup
  TMP_FILES=()

  success "SSH alias '$ALIAS' saved to $config"
}

# ---------------------------------------------------------------------------
# Validation and connectivity testing
# ---------------------------------------------------------------------------
validate_ssh_config() {
  step 'Configuration validation'

  local config="$HOME/.ssh/config" output
  # -F is used explicitly: OpenSSH expands "~" through the passwd database, so
  # "ssh -G" without -F would read a different file whenever HOME differs.
  if output=$(ssh -G -F "$config" "$ALIAS" 2>&1); then
    local effective_host effective_port effective_user
    # "ssh -G" prints "host <name-as-given>" first; the resolved destination is
    # in the "hostname" field.
    effective_host=$(printf '%s\n' "$output" | awk '$1=="hostname"{print $2; exit}')
    effective_port=$(printf '%s\n' "$output" | awk '$1=="port"{print $2; exit}')
    effective_user=$(printf '%s\n' "$output" | awk '$1=="user"{print $2; exit}')
    success "OpenSSH accepted the configuration (host=$effective_host port=$effective_port user=$effective_user)"
    if [[ $effective_host != "$HOST" ]]; then
      warn "Effective hostname is '$effective_host' but '$HOST' was requested. An earlier 'Host' wildcard may override this entry."
    fi
  else
    error "OpenSSH reported a problem with the configuration:"
    printf '%s\n' "$output" | sed -n '1,10p' >&2
    return 1
  fi
}

# Probe TCP connectivity to the SSH port.
# The host is strictly validated beforehand (no shell metacharacters), so the
# value can be interpolated safely.
test_connectivity() {
  step 'Connectivity test'

  if ((NO_TEST)); then
    warn 'Connectivity test skipped (--no-test).'
    return 0
  fi

  # 1. DNS resolution (best effort, skipped for IP literals).
  if [[ $HOST == *:* || $HOST =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    info 'IP literal supplied; DNS lookup not required.'
  elif command -v getent >/dev/null 2>&1; then
    if getent ahosts "$HOST" >/dev/null 2>&1; then
      success "DNS resolved: $HOST"
    else
      warn "DNS lookup failed for '$HOST'. The host may be unreachable, mistyped, or not yet published."
    fi
  elif command -v dscacheutil >/dev/null 2>&1; then
    if dscacheutil -q host -a name "$HOST" 2>/dev/null | grep -q 'ip_address'; then
      success "DNS resolved: $HOST"
    else
      warn "DNS lookup failed for '$HOST'."
    fi
  else
    warn 'No supported DNS utility found; skipping the resolution check.'
  fi

  # 2. TCP reachability of the SSH port.
  local probe='' display="$HOST:$PORT"
  [[ $HOST == *:* ]] && display="[$HOST]:$PORT"
  if command -v nc >/dev/null 2>&1; then
    if nc -z -w "$TIMEOUT" "$HOST" "$PORT" >/dev/null 2>&1; then
      success "TCP port $PORT is reachable on $HOST"
      return 0
    fi
    probe='nc reported the port as closed or unreachable'
  elif command -v timeout >/dev/null 2>&1; then
    # bash's /dev/tcp needs a bracketed IPv6 literal. The host is strictly
    # validated beforehand, so no shell metacharacters can reach this string.
    local tcp_target=$HOST
    [[ $HOST == *:* ]] && tcp_target="[$HOST]"
    if timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/${tcp_target}/${PORT}" >/dev/null 2>&1; then
      success "TCP port $PORT is reachable on $HOST"
      return 0
    fi
    probe='the TCP connection attempt failed or timed out'
  else
    warn 'Neither nc nor timeout is available; skipping the TCP port probe.'
    return 0
  fi

  error "Cannot reach $display ($probe)."
  printf '  Possible causes: the server is down, a firewall or security group blocks the\n'
  printf '  port, the port number is wrong, or the hostname does not resolve to this host.\n'
  return 1
}

test_ssh_authentication() {
  step 'SSH authentication test'

  if ((NO_TEST)); then
    warn 'Authentication test skipped (--no-test).'
    return 0
  fi

  if ((NONINTERACTIVE == 1)) && [[ $AUTH == 'password' ]]; then
    warn 'Skipping the authentication test: password authentication needs an interactive prompt.'
    return 0
  fi

  local -a args=(-o "ConnectTimeout=$TIMEOUT")
  if [[ $AUTH != 'password' ]]; then
    # BatchMode prevents an interactive passphrase prompt from hanging the
    # script. A passphrased key must be unlocked in the agent first.
    args+=(-o BatchMode=yes)
  fi

  printf 'Verifying the host key on first use - compare the fingerprint with the one\n'
  printf 'published by your VPS provider before accepting it.\n\n'

  local rc=0 output
  output=$(ssh "${args[@]}" "$ALIAS" 'true' 2>&1) || rc=$?

  if ((rc == 0)); then
    success 'SSH authentication succeeded and a remote command ran successfully.'
    return 0
  fi

  warn "SSH authentication test failed (exit code $rc)."
  printf '%s\n' "$output" | sed -n '1,12p' >&2

  if printf '%s\n' "$output" | grep -qi 'host key verification failed'; then
    error 'Host-key verification failed. The server key changed or is not yet trusted.'
    printf '  If you have just reinstalled the VPS, remove the stale key with:\n'
    printf '    ssh-keygen -R %s\n' "$HOST"
    printf '  Never disable StrictHostKeyChecking to work around this.\n'
  elif printf '%s\n' "$output" | grep -qiE 'permission denied|authentication failed'; then
    error 'Authentication failed: the key or password was rejected by the server.'
    if [[ $AUTH == 'generate' ]]; then
      printf '  The public key probably is not installed on the VPS yet. Install it with:\n'
      printf '    ssh-copy-id -i "%s.pub" -p %s %s@%s\n' "$KEY_PATH" "$PORT" "$REMOTE_USER" "$HOST"
    fi
    if [[ $AUTH == 'key' || $AUTH == 'generate' ]]; then
      if command -v ssh-add >/dev/null 2>&1 && ! ssh-add -l >/dev/null 2>&1; then
        printf '  The SSH agent has no loaded identity. Unlock the key first:\n'
        # shellcheck disable=SC2016  # literal command text for the user to copy
        printf '    eval "$(ssh-agent -s)" && ssh-add "%s"\n' "$KEY_PATH"
      fi
    fi
  else
    error 'The SSH test did not complete. Run the verbose command below for details.'
  fi

  printf '  Full diagnostics: ssh -vvv %s\n' "$ALIAS"
  return 1
}

# ---------------------------------------------------------------------------
# Optional wrapper
# ---------------------------------------------------------------------------
install_wrapper() {
  if ((NO_WRAPPER)) || ((INSTALL_WRAPPER == 0)); then
    return 0
  fi

  step 'Optional command wrapper'

  local bindir="$HOME/.local/bin"
  local wrapper="$bindir/$ALIAS"

  if command -v "$ALIAS" >/dev/null 2>&1 && [[ $(command -v "$ALIAS") != "$wrapper" ]]; then
    warn "A command named '$ALIAS' already exists at $(command -v "$ALIAS"). Not installing a wrapper."
    return 0
  fi
  if [[ -e $wrapper ]]; then
    warn "Wrapper already exists: $wrapper (left untouched)."
    return 0
  fi

  mkdir -p -- "$bindir"
  chmod -- 700 "$bindir"

  {
    printf '#!/bin/sh\n'
    printf '# Auto-generated by vpslink.sh - convenience wrapper for "ssh %s".\n' "$ALIAS"
    printf 'exec ssh %s "$@"\n' "$ALIAS"
  } > "$wrapper"

  chmod -- 755 "$wrapper"
  success "Wrapper installed: $wrapper"

  case ":$PATH:" in
    *":$bindir:"*) success "'$bindir' is already in PATH; you can run: $ALIAS" ;;
    *) warn "'$bindir' is not in PATH. Add this to your shell profile:"
       # shellcheck disable=SC2016  # literal command text for the user to copy
       printf '    export PATH="$HOME/.local/bin:$PATH"\n'
       ;;
  esac
  printf '  The standard SSH alias always works without any PATH changes: ssh %s\n' "$ALIAS"
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
print_summary() {
  step 'Setup summary'
  printf '  Alias:          %s\n' "$ALIAS"
  printf '  Host:           %s\n' "$HOST"
  printf '  Username:       %s\n' "$REMOTE_USER"
  printf '  Port:           %s\n' "$PORT"
  case "$AUTH" in
    key)      printf '  Authentication: existing private key\n' ;;
    generate) printf '  Authentication: generated key pair\n' ;;
    password) printf '  Authentication: password (prompted by OpenSSH)\n' ;;
  esac
  if [[ $AUTH == 'key' || $AUTH == 'generate' ]]; then
    printf '  Private key:    %s\n' "$KEY_PATH"
  else
    printf '  Private key:    (not used)\n'
  fi
  printf '  Keepalive:      %s seconds\n' "$KEEPALIVE"
  printf '  Timeout:        %s seconds\n' "$TIMEOUT"
  printf '  Config file:    %s\n' "$HOME/.ssh/config"

  printf '\n%sLogin command%s\n' "$BOLD" "$RESET"
  printf '  ssh %s\n' "$ALIAS"

  printf '\n%sDirect connection (no alias)%s\n' "$BOLD" "$RESET"
  printf '  ssh -p %s %s@%s\n' "$PORT" "$REMOTE_USER" "$HOST"

  if [[ $AUTH == 'generate' && -f $KEY_PATH.pub ]]; then
    printf '\n%sInstall the public key on the VPS%s\n' "$BOLD" "$RESET"
    printf '  Only the public key is transferred; the private key never leaves this machine.\n'
    if command -v ssh-copy-id >/dev/null 2>&1; then
      printf '  Recommended:\n'
      printf '    ssh-copy-id -i "%s.pub" -p %s %s@%s\n' "$KEY_PATH" "$PORT" "$REMOTE_USER" "$HOST"
    else
      printf '  ssh-copy-id is not installed. Copy the contents of this file to the VPS:\n'
      printf '    cat "%s.pub"\n' "$KEY_PATH"
      printf '  On the VPS, append that line to ~/.ssh/authorized_keys for %s, then run:\n' "$REMOTE_USER"
      printf '    chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys\n'
    fi
  fi

  if [[ $AUTH == 'password' ]]; then
    printf '\n%sNote%s\n' "$BOLD" "$RESET"
    printf '  Password authentication does not use a private key. OpenSSH prompts for the\n'
    printf '  password at connection time; nothing was stored. SSH key authentication is\n'
    printf '  generally preferable because it resists credential stuffing and enables\n'
    printf '  automation. You can switch later by re-running this script with --auth generate.\n'
  fi
}

show_troubleshooting() {
  step 'Troubleshooting'
  cat <<'TROUBLE'
  Alias not found (ssh: Could not resolve hostname vps)
      The alias lives in ~/.ssh/config. Check it exists and that you are using the
      same user account: ls -l ~/.ssh/config

  Permission denied (publickey)
      The public key is not installed on the VPS, or the remote user is wrong.
      Install it: ssh-copy-id -i ~/.ssh/id_ed25519.pub -p PORT USER@HOST

  Host key verification failed
      The stored key does not match the server. Only remove it if you know the VPS
      was reinstalled: ssh-keygen -R HOST

  Connection timed out
      The host is unreachable: check DNS, firewall/security groups, and that the
      SSH port is correct: nc -vz HOST PORT

  Connection refused
      Nothing is listening on that port. Confirm the sshd port on the VPS.

  Agent refused the key / no identities
      The key is passphrase-protected and not loaded. Unlock it:
          eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519

  Diagnostics
      ssh -vvv ALIAS        verbose connection log
      ssh -G ALIAS          show the effective configuration OpenSSH will use
TROUBLE
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
ALIAS='' HOST='' REMOTE_USER='' PORT='22' AUTH='' KEY_PATH='' KEY_TYPE='ed25519'
KEEPALIVE='60' TIMEOUT='10' IDENTITIES_ONLY='yes'
ASSUME_YES=0 NO_TEST=0 NO_WRAPPER=0 NONINTERACTIVE=0 INSTALL_WRAPPER=0
OS_ID='' OS_FAMILY='' OS_DISTRO='' OS_SUPPORTED='yes' OS_PKG_HINT=''

parse_arguments() {
  local opt val
  while (($#)); do
    case "$1" in
      --alias|--host|--user|--port|--auth|--key|--key-type|--keepalive|--timeout)
        (($# >= 2)) || die "Missing value for $1"
        opt=$1; val=$2; shift 2
        NONINTERACTIVE=1
        case "$opt" in
          --alias)    ALIAS=$val ;;
          --host)     HOST=$val ;;
          --user)     REMOTE_USER=$val ;;
          --port)     PORT=$val ;;
          --auth)     AUTH=$val ;;
          --key)      KEY_PATH=$val ;;
          --key-type) KEY_TYPE=$val ;;
          --keepalive) KEEPALIVE=$val ;;
          --timeout)  TIMEOUT=$val ;;
        esac
        ;;
      --no-identities-only) IDENTITIES_ONLY='no'; shift ;;
      --no-test)     NO_TEST=1; shift ;;
      --no-wrapper)  NO_WRAPPER=1; INSTALL_WRAPPER=0; shift ;;
      --wrapper)     INSTALL_WRAPPER=1; shift ;;
      --yes)         ASSUME_YES=1; shift ;;
      --version)     printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h)     usage; exit 0 ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
  done
}

main() {
  trap on_interrupt INT TERM
  trap cleanup EXIT

  printf '====================================================\n'
  printf '  vpslink v%s - VPS SSH login setup\n' "$SCRIPT_VERSION"
  printf '====================================================\n'

  printf '\nDetected environment:\n'
  detect_os
  classify_platform
  check_dependencies

  collect_configuration
  validate_inputs

  step 'Review configuration'
  printf '  Alias:          %s\n' "$ALIAS"
  printf '  Host:           %s\n' "$HOST"
  printf '  Username:       %s\n' "$REMOTE_USER"
  printf '  Port:           %s\n' "$PORT"
  case "$AUTH" in
    key)      printf '  Authentication: existing private key\n' ;;
    generate) printf '  Authentication: generate new key pair (%s)\n' "$KEY_TYPE" ;;
    password) printf '  Authentication: password (prompted by OpenSSH)\n' ;;
  esac
  if [[ $AUTH == 'key' || $AUTH == 'generate' ]]; then
    printf '  Private key:    %s\n' "$KEY_PATH"
  fi
  printf '  Keepalive:      %s seconds\n' "$KEEPALIVE"
  printf '  Timeout:        %s seconds\n' "$TIMEOUT"
  printf '  IdentitiesOnly: %s\n' "$IDENTITIES_ONLY"
  if ((INSTALL_WRAPPER)); then
    printf '  Wrapper:        %s/.local/bin/%s\n' "$HOME" "$ALIAS"
  fi

  if ((ASSUME_YES == 0)); then
    local confirm
    read -r -p 'Apply this configuration? [y/N]: ' confirm || { printf '\n'; die 'Input stream closed.'; }
    [[ $confirm =~ ^[Yy]$ ]] || die 'Cancelled; no SSH configuration was changed.'
  fi

  manage_ssh_keys
  configure_ssh_alias
  validate_ssh_config || warn 'The OpenSSH configuration check reported a problem; review it manually.'

  local conn_ok=0 auth_ok=0 tested=0
  if ((NO_TEST == 0)); then
    tested=1
  fi

  if test_connectivity; then
    conn_ok=1
  else
    warn 'The TCP connectivity check did not succeed.'
  fi

  if ((conn_ok == 1)); then
    offer_copy_id
  elif [[ $AUTH == 'generate' ]]; then
    info 'Skipping the ssh-copy-id offer because the host was not reachable.'
  fi

  if test_ssh_authentication; then
    auth_ok=1
  else
    warn 'The SSH authentication test did not succeed.'
  fi

  install_wrapper
  print_summary
  show_troubleshooting

  printf '\n'
  if ((tested == 0)); then
    warn 'The tests were skipped, so connectivity and authentication were NOT verified.'
    printf '  The alias is saved. Verify it yourself with: ssh %s\n' "$ALIAS"
  elif ((conn_ok == 1 && auth_ok == 1)); then
    success 'Setup complete and verified. Connect with: ssh '"$ALIAS"
  else
    warn 'The alias is saved, but connectivity/authentication was not fully verified.'
    printf '  The configuration is usable once the remaining problem is resolved.\n'
  fi
}

# Running this file executes the tool. Sourcing it (BASH_SOURCE[0] != $0)
# only defines the functions, which is what the unit tests rely on.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_arguments "$@"
  main
fi
