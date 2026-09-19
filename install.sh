#!/bin/bash
# install.sh - the Yoru installer
#
# It runs in five parts: check this server, ask what is needed, install,
# verify, report. Every question comes before anything is written, so once
# the install starts it runs to the end without stopping to ask.
#
# This script is deliberately NOT designed for "curl ... | sudo bash". We are a
# security product; telling people to pipe a script from the internet straight
# into sudo bash is the exact habit we are trying to end. Download it, read it,
# then run it.
#
# Safe to run again - every step looks at the current state first.

set -uo pipefail
umask 022
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

SRC="$(dirname "$(readlink -f "$0")")"

# Read from the dispatcher, not repeated here - the two numbers drifted apart.
VERSION="$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$SRC/bin/yoructl" 2>/dev/null)"
[ -n "$VERSION" ] || VERSION="unknown"

AGENT=yoru-agent
BIN_DIR=/opt/yoru/bin
CATALOG_DIR=/usr/share/yoru/catalog
ETC_DIR=/etc/yoru
LOG_DIR=/var/log/yoru
DATA_DIR=/var/lib/yoru
SYSTEMD_DIR=/etc/systemd/system
BASELINE_DIR=/var/backups/yoru
WEB_DIR=/opt/yoru/web
CONFIG_FILE="$ETC_DIR/yoru.conf"
WEB_ENV="$ETC_DIR/web.env"
SUDOERS=/etc/sudoers.d/yoru
LOGFILE=/var/log/yoru-install.log

MODEL_USER="yoru-model"
MODEL_ENV="$ETC_DIR/model.env"
MODEL_BIN="$BIN_DIR/yoru-model-proxy"
MODEL_UNIT="$SYSTEMD_DIR/yoru-model.service"

# ------------------------------------------------------------------- printing
# Four markers, nothing else: ok, !, x, and .. for something in progress. They
# read the same with colour stripped, because half of these runs end up in a
# pipe or a support ticket.
if [ -t 1 ]; then
  RESET=$'\033[0m'; GREEN=$'\033[32m'; RED=$'\033[31m'
  AMBER=$'\033[33m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
else
  RESET=""; GREEN=""; RED=""; AMBER=""; BOLD=""; DIM=""
fi

BLOCKERS=()
PENDING=()

note() { printf '%s\n' "$*" >> "$LOGFILE" 2>/dev/null || true; }
mark() { printf '  %s%-2s%s  %s\n' "$2" "$1" "$RESET" "$3"; }

ok()      { mark "ok" "$GREEN" "$1"; note "ok    $1"; }
warn()    { mark "!"  "$AMBER" "$1"; note "warn  $1"; }
busy()    { mark ".." "$DIM"   "$1"; note "work  $1"; }
stop()    { mark "x"  "$RED"   "$1"; note "BLOCK $1"; BLOCKERS+=("$1"); }
pending() { PENDING+=("$1"); note "todo  $1"; }

phase() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; note ""; note "== $1"; }
item()  { printf '  %-13s %s\n' "$1" "$2"; note "      $1 $2"; }

die() {
  printf '\n  %sstopped%s  %s\n' "$RED" "$RESET" "$1"
  printf '  full log: %s\n\n' "$LOGFILE"
  note "STOP  $1"
  exit 1
}

# What the system itself said, never our guess about it. "No disk space" and
# "no network" look identical from out here and only one is worth waiting on.
last_words() {
  tail -n "${1:-6}" "$LOGFILE" 2>/dev/null | sed 's/^/        /'
}

# Everything noisy goes here, so the screen stays readable.
run() { "$@" >>"$LOGFILE" 2>&1; }

open_log() {
  if ! : >>"$LOGFILE" 2>/dev/null; then
    LOGFILE="$(mktemp)" || LOGFILE=/dev/null
  fi
  chmod 640 "$LOGFILE" 2>/dev/null || true
  note "--- yoru $VERSION $(date -Is 2>/dev/null) ---"
}

# ------------------------------------------------------------ read/write config
# Never `source`: a value containing $(...) would run. Do not use -F= and then
# edit $1 either - awk rebuilds $0 with spaces and every "=" on the line goes.
config_get() {  # config_get <file> <key>
  [ -r "$1" ] || return 0
  awk -v k="$2" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/ || line == "") next
      p = index(line, "=")
      if (p == 0) next
      key = substr(line, 1, p - 1)
      val = substr(line, p + 1)
      sub(/[[:space:]]+$/, "", key)
      sub(/^[[:space:]]+/, "", val); sub(/[[:space:]]+$/, "", val)
      gsub(/^"|"$/, "", val)
      if (key == k) { print val; exit }
    }' "$1"
}

# Replaces one value in place, leaving the comments around it alone.
config_set() {  # config_set <file> <key> <value>
  local file="$1" key="$2" val="$3" tmp
  tmp=$(mktemp) || return 1
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    {
      copy = $0
      sub(/^[[:space:]]+/, "", copy)
      if (copy ~ /^#/ || copy == "") { print; next }
      p = index(copy, "=")
      if (p == 0) { print; next }
      name = substr(copy, 1, p - 1)
      sub(/[[:space:]]+$/, "", name)
      if (name == k) { print k "=\"" v "\""; done = 1; next }
      print
    }
    END { if (!done) print k "=\"" v "\"" }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  # Content copied, file not moved, so the original owner and mode stay.
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# From /dev/tty, not stdin: a redirected install would swallow its own answers.
ask() {  # ask <label> <variable-name> [secret]
  local label="$1" __var="$2" mode="${3-}" answer=""
  if [ "$mode" = "secret" ]; then
    read -r -s -p "  $label: " answer < /dev/tty; printf '\n'
  else
    read -r -p "  $label: " answer < /dev/tty
  fi
  printf -v "$__var" '%s' "$answer"
}

# =========================================================== 1. check the server
# Nothing here writes. This whole section is what --check-only runs.

lock_holder() {  # who is holding apt right now, by name, or nothing
  local p
  for p in unattended-upgrade apt.systemd.daily apt-get dpkg aptitude packagekitd; do
    if pgrep -x "$p" >/dev/null 2>&1; then printf '%s' "$p"; return 0; fi
  done
  if pgrep -f unattended-upgrade >/dev/null 2>&1; then printf 'unattended-upgrades'; return 0; fi
  return 1
}

# Answers with the program's name, "?" when it cannot look, or nothing when
# the port is free. Never silence: "free" has to mean we actually checked.
port_owner() {  # port_owner <port>
  command -v ss >/dev/null 2>&1 || { printf '?'; return 0; }
  local out
  out="$(ss -tlnpH "sport = :$1" 2>/dev/null)"
  [ -n "$out" ] || return 0
  printf '%s' "$out" | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p' | head -1
}

installed_version() {
  awk -F'"' '/^VERSION=/ {print $2; exit}' "$BIN_DIR/yoructl" 2>/dev/null
}

check_root() {
  [ "$(id -u)" -eq 0 ] || die "run this with sudo"
}

check_os() {
  local name="" id="" ver=""
  if [ -r /etc/os-release ]; then
    # One subshell, three values - sourcing it three times is three forks.
    read -r id ver name <<< "$(. /etc/os-release; printf '%s %s %s' "${ID:-?}" "${VERSION_ID:-?}" "${NAME:-?}")"
  fi
  case "$id:$ver" in
    ubuntu:24.04|ubuntu:22.04) ok "$name $ver" ;;
    ubuntu:*|debian:*)         warn "$name $ver - not tested yet, continuing carefully" ;;
    *)                         stop "$name $ver is not supported - Yoru needs Debian or Ubuntu" ;;
  esac
}

check_init() {
  # The binary can be present in a container with no systemd behind it, and
  # then every systemctl call fails halfway through the install.
  if [ -d /run/systemd/system ]; then
    ok "systemd is running"
  else
    stop "systemd is not running here - Yoru's services and daily timer need it"
  fi
}

check_container() {
  local kind=""
  command -v systemd-detect-virt >/dev/null 2>&1 && kind="$(systemd-detect-virt --container 2>/dev/null)"
  case "${kind:-none}" in
    none) : ;;
    *) warn "this is a $kind container - kernel settings (K07) may be read-only here" ;;
  esac
}

check_apt() {
  command -v apt-get >/dev/null 2>&1 \
    || { stop "apt-get not found - this installer is for Debian and Ubuntu"; return 0; }

  # A package database left half-finished makes every later apt command fail
  # with a message about something else entirely.
  if run apt-get check; then
    ok "package database is healthy"
  else
    stop "package database is broken - run 'sudo dpkg --configure -a' first, then try again"
  fi

  local holder
  if holder="$(lock_holder)"; then
    warn "apt is busy right now ($holder) - the installer will wait for it to finish"
  fi
}

check_python() {
  command -v python3 >/dev/null 2>&1 \
    || { stop "python3 not found - Yoru cannot install without it"; return 0; }
  PY_VER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  local major="${PY_VER%%.*}" minor="${PY_VER##*.}"
  if [ "${major:-0}" -lt 3 ] || { [ "$major" = 3 ] && [ "${minor:-0}" -lt 8 ]; }; then
    stop "python ${PY_VER:-?} is too old - Yoru needs 3.8 or newer"
  else
    ok "python $PY_VER"
  fi
}

check_disk() {
  local mb
  mb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print int($4/1024)}')"
  [ -n "$mb" ] || return 0
  if   [ "$mb" -lt 300 ]; then stop "only ${mb}MB free on / - Yoru needs about 400MB"
  elif [ "$mb" -lt 800 ]; then warn "${mb}MB free on / - enough, but tight"
  else ok "disk ${mb}MB free"
  fi
}

check_memory() {
  local mb
  mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
  [ -n "$mb" ] || return 0
  if [ "$mb" -lt 480 ] && [ "$WITH_DASHBOARD" = yes ]; then
    warn "${mb}MB RAM - building the dashboard may run out of memory"
  else
    ok "RAM ${mb}MB"
  fi
}

check_network() {
  # A warning, never a blocker: plenty of servers reach the world through a
  # proxy, and a cached apt index can carry an install through without this.
  if python3 - <<'PY' >>"$LOGFILE" 2>&1
import socket, sys
for host in ("archive.ubuntu.com", "deb.debian.org", "pypi.org"):
    try:
        socket.create_connection((host, 443), timeout=4).close()
        print("reached", host); sys.exit(0)
    except OSError as e:
        print("no", host, e)
sys.exit(1)
PY
  then ok "network reachable"
  else warn "cannot reach the internet - apt and pip will fail if anything is missing"
  fi
}

check_security_modules() {
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    warn "SELinux is enforcing - Yoru's files may install and then be denied at runtime"
  fi
}

check_ssh() {
  if ! command -v sshd >/dev/null 2>&1; then
    warn "sshd is not installed - K01 to K05 have nothing to read"
    return 0
  fi

  # /run/sshd is often absent on a fresh Ubuntu: ssh.service creates it, and
  # that only happens once something connects through ssh.socket.
  if [ "$DRY" != yes ] && [ ! -d /run/sshd ]; then
    mkdir -p /run/sshd 2>/dev/null && chmod 0755 /run/sshd 2>/dev/null
  fi

  if run sshd -T; then
    ok "sshd settings readable"
  else
    warn "cannot read sshd settings: $(sshd -T 2>&1 >/dev/null | head -1)"
    pending "K01 to K05 will report an error until 'sudo sshd -T' works"
  fi

  # Without this line our drop-in file is written and then ignored, which is
  # the worst kind of failure: it looks like it worked.
  if grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' \
       /etc/ssh/sshd_config 2>/dev/null; then
    ok "sshd reads /etc/ssh/sshd_config.d"
  else
    warn "sshd does not read /etc/ssh/sshd_config.d - K01 to K05 cannot change anything"
    pending "add 'Include /etc/ssh/sshd_config.d/*.conf' to /etc/ssh/sshd_config"
  fi
}

check_ports() {
  [ "$WITH_DASHBOARD" = yes ] || return 0
  local who
  who="$(port_owner "$WEB_PORT")"
  if [ -z "$who" ]; then
    ok "port $WEB_PORT is free"
  elif [ "$who" = "?" ]; then
    warn "cannot check port $WEB_PORT yet - ss is not installed"
  elif systemctl is-active yoru-web.service >/dev/null 2>&1; then
    ok "port $WEB_PORT is Yoru's own dashboard, already running"
  else
    stop "port $WEB_PORT is taken by '$who' - choose another with --port <number>"
  fi

  who="$(port_owner 8080)"
  case "$who" in ""|"?") : ;; *) note "port 8080 taken by $who - the model connector will use 8090" ;; esac
  return 0
}

check_existing() {
  local old
  old="$(installed_version)"
  if [ -n "$old" ]; then
    warn "Yoru $old is already here - this run upgrades it in place"
  elif [ -e "$SUDOERS" ] || [ -d /opt/yoru ]; then
    warn "leftovers from an earlier install found - they will be replaced"
  fi
}

check_sources() {
  local f
  for f in bin/yoructl bin/yoru.sudoers bin/yoru-watch \
           systemd/yoru-watch.service systemd/yoru-watch.timer \
           examples/yoru.conf.example; do
    [ -f "$SRC/$f" ] || { stop "$f is missing - run this script from inside the repo folder"; return 0; }
  done
  [ -d "$SRC/catalog" ] || { stop "the catalog folder is missing - run this from inside the repo folder"; return 0; }
  ok "installer files complete"
}

# What Yoru needs is a list of capabilities, not a list of package names.
have() {  # have cmd:<name> | py:<module>
  case "$1" in
    cmd:*) command -v "${1#cmd:}" >/dev/null 2>&1 ;;
    py:*)  python3 -c "import ${1#py:}" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

dep_table() {  # level|probe|candidate packages|what it is for
  printf '%s\n' \
    "need|cmd:systemctl|systemd|services and the daily timer" \
    "need|cmd:sudo|sudo|the agent's permission boundary" \
    "need|cmd:visudo|sudo|checking the sudoers file before installing it" \
    "need|cmd:install|coreutils|copying files with the right permissions" \
    "need|cmd:stat|coreutils|reading file permissions" \
    "need|cmd:flock|util-linux|locking when two actions overlap" \
    "need|cmd:ss|iproute2|K05 and K06 read open ports" \
    "need|cmd:sshd|openssh-server|K01 to K05 read sshd settings" \
    "need|py:yaml|python3-yaml|the agent reads the catalog" \
    "opt|cmd:ufw|ufw|K05 turns the firewall on" \
    "opt|cmd:auditctl|auditd|K08 records who changed what"
  [ "$WITH_DASHBOARD" = yes ] && printf '%s\n' \
    "need|py:ensurepip|python${PY_VER:-3}-venv python3-venv|the dashboard runs in its own venv" \
    "need|py:sqlite3|python3|the dashboard stores reports"
  return 0
}

MISSING=()
check_deps() {
  local level probe pkgs why names=""
  while IFS='|' read -r level probe pkgs why; do
    [ -n "${level:-}" ] || continue
    have "$probe" && continue
    MISSING+=("$level|$probe|$pkgs|$why")
    names="$names ${pkgs%% *}"
  done <<< "$(dep_table)"

  if [ ${#MISSING[@]} -eq 0 ]; then
    ok "everything Yoru needs is already installed"
  else
    warn "${#MISSING[@]} to install:${names}"
  fi
}

check_all() {
  phase "Checking this server"
  check_root
  check_os
  check_init
  check_container
  check_apt
  check_python
  check_disk
  check_memory
  check_network
  check_security_modules
  check_ssh
  check_ports
  check_existing
  check_sources
  check_deps
}

verdict() {
  if [ ${#BLOCKERS[@]} -eq 0 ]; then
    return 0
  fi
  printf '\n%sCannot install yet%s\n\n' "$BOLD" "$RESET"
  local b
  for b in "${BLOCKERS[@]}"; do printf '  %sx%s   %s\n' "$RED" "$RESET" "$b"; done
  printf '\n  Fix these, then run the installer again.\n'
  printf '  Full log: %s\n\n' "$LOGFILE"
  exit 1
}

# ================================================================== 2. setup
# Every question lives here, before a single byte is written. After this the
# install runs to the end on its own.

MODEL_CHOICE="skip"
MODEL_KEY=""
MODEL_NAME="gemini-flash-latest"
MODEL_URL=""
MODEL_TOKEN=""
TG_TOKEN=""
SSHKEY=""
OWNER_HOME=""

model_hosts() {
  local found=""
  command -v hermes   >/dev/null 2>&1 && found="$found hermes"
  command -v openclaw >/dev/null 2>&1 && found="$found openclaw"
  command -v ollama   >/dev/null 2>&1 && found="$found ollama"
  printf '%s' "${found# }"
}

resolve_owner() {
  [ -n "$OWNER" ] || OWNER="${SUDO_USER:-}"
  [ -n "$OWNER" ] || die "cannot tell who owns this server - use: --owner <username>"
  getent passwd "$OWNER" >/dev/null || die "user '$OWNER' does not exist on this server"
  [ "$OWNER" != "root" ] || die "the owner cannot be root - Yoru needs a normal human account"
  OWNER_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
}

ask_sshkey() {
  local file="$OWNER_HOME/.ssh/authorized_keys"
  [ -s "$file" ] && return 0

  cat <<TEXT

  $OWNER has no SSH key yet. K02 turns password login off, so without a key
  that works it would close your own only door - K02 refuses to run until
  there is one.

  Make it on YOUR computer, not on this server:

      ssh-keygen -t ed25519

  Then show the public half and paste the line below:

      Windows   type %USERPROFILE%\\.ssh\\id_ed25519.pub
      Linux     cat ~/.ssh/id_ed25519.pub
      macOS     cat ~/.ssh/id_ed25519.pub

  It must be the .pub one: a single line starting with ssh-ed25519 or
  ssh-rsa. We never ask for a private key.

TEXT

  local key
  ask "Public key (empty to skip)" key
  [ -n "$key" ] || { pending "no SSH key for $OWNER yet - K02 stays blocked until there is one"; return 0; }

  # A key that has crossed a screen and a shell history is no longer secret.
  case "$key" in
    *PRIVATE\ KEY*|*BEGIN\ OPENSSH*|*BEGIN\ RSA*)
      printf '\n  %sThat is a PRIVATE key, not a public one.%s\n' "$RED" "$RESET"
      printf '  It has now been through a screen and a shell history, so it can no\n'
      printf '  longer be treated as secret. Make a new pair on your computer and\n'
      printf '  paste only the .pub line.\n\n'
      die "nothing was written" ;;
  esac

  # ssh-keygen, not a pattern of our own: a key missing one character still
  # looks right, and would only fail at the next login - after K02 is on.
  if command -v ssh-keygen >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp)" || return 0
    printf '%s\n' "$key" > "$tmp"
    if ! ssh-keygen -l -f "$tmp" >>"$LOGFILE" 2>&1; then
      rm -f "$tmp"
      printf '  %sThat is not a valid public key - nothing was written.%s\n' "$AMBER" "$RESET"
      pending "no SSH key for $OWNER yet - K02 stays blocked until there is one"
      return 0
    fi
    rm -f "$tmp"
  fi
  SSHKEY="$key"
}

ask_telegram() {
  printf '\n  Telegram is optional. With a bot token you get alerts on your phone\n'
  printf '  and approve buttons there. You can also add it later in Settings.\n\n'
  ask "Telegram bot token (empty to skip)" TG_TOKEN secret
}

ask_model() {
  local hosts; hosts="$(model_hosts)"

  printf '\n  Yoru works without an AI model - reports are still complete, the\n'
  printf '  wording just comes from the catalog instead.\n\n'
  printf '    1   Google Gemini - paste an API key\n'
  printf '    2   Any OpenAI-compatible address you already run\n'
  [ -n "$hosts" ] && printf '        (found on this server: %s)\n' "$hosts"
  printf '    3   Skip\n\n'

  local pick; ask "Choose 1, 2 or 3 [3]" pick
  case "$pick" in
    1)
      # Two key shapes are in circulation, AIza... and AQ... - both are valid.
      ask "Gemini API key" MODEL_KEY secret
      MODEL_KEY="${MODEL_KEY#GEMINI_API_KEY=}"
      MODEL_KEY="$(printf '%s' "$MODEL_KEY" | tr -d '\r\n "')"
      [ -n "$MODEL_KEY" ] || { printf '  Empty key - skipping.\n'; return 0; }
      ask "Model name (empty = gemini-flash-latest)" MODEL_NAME
      MODEL_NAME="$(printf '%s' "$MODEL_NAME" | tr -d '\r\n ')"
      [ -n "$MODEL_NAME" ] || MODEL_NAME="gemini-flash-latest"
      MODEL_CHOICE="gemini"
      ;;
    2)
      printf '  Anything that answers POST /v1/chat/completions works here -\n'
      printf '  Ollama, an OpenAI-shaped gateway, or your own server.\n'
      case " $hosts " in
        *" ollama "*) printf '  Ollama is installed, so try: http://127.0.0.1:11434/v1\n' ;;
      esac
      ask "Address" MODEL_URL
      MODEL_URL="$(printf '%s' "$MODEL_URL" | tr -d '\r\n ')"
      [ -n "$MODEL_URL" ] || { printf '  Empty address - skipping.\n'; return 0; }
      ask "Token, if it needs one (empty to skip)" MODEL_TOKEN secret
      ask "Model name (empty = default)" MODEL_NAME
      MODEL_NAME="$(printf '%s' "$MODEL_NAME" | tr -d '\r\n ')"
      MODEL_CHOICE="url"
      ;;
    *) MODEL_CHOICE="skip" ;;
  esac
}

recap() {
  phase "Setup"
  item "Owner"     "$OWNER"
  if [ "$WITH_DASHBOARD" = yes ]
    then item "Dashboard" "http://$WEB_HOST:$WEB_PORT"
    else item "Dashboard" "off (--no-dashboard)"
  fi
  if [ -n "$TG_TOKEN" ]
    then item "Telegram" "on"
    else item "Telegram" "off"
  fi
  case "$MODEL_CHOICE" in
    gemini) item "AI model" "Google Gemini" ;;
    url)    item "AI model" "$MODEL_URL" ;;
    *)      item "AI model" "off - wording comes from the catalog" ;;
  esac
  item "Install log" "$LOGFILE"
}

setup() {
  resolve_owner
  if [ "$INTERACTIVE" = yes ] && [ -r /dev/tty ]; then
    # Existing settings are never re-asked; re-running the installer must not
    # be a way to lose an API key.
    local existing; existing="$(config_get "$CONFIG_FILE" HERMES_URL)"
    ask_sshkey
    [ -n "$(config_get "$CONFIG_FILE" TELEGRAM_TOKEN)" ] || ask_telegram
    [ -n "$existing" ] || ask_model
  fi
  recap
}

# ================================================================= 3. install

wait_for_apt() {
  local holder waited=0
  holder="$(lock_holder)" || return 0
  busy "apt is busy ($holder) - waiting, up to 5 minutes"
  while [ "$waited" -lt 300 ]; do
    sleep 10; waited=$((waited + 10))
    if ! lock_holder >/dev/null; then
      ok "apt is free again after ${waited}s"
      return 0
    fi
    [ $((waited % 60)) -eq 0 ] && note "still waiting for apt, ${waited}s"
  done
  warn "apt is still busy after 5 minutes - going ahead anyway"
  return 0
}

APT_REFRESHED=no
apt_refresh() {
  [ "$APT_REFRESHED" = yes ] && return 0
  APT_REFRESHED=yes
  # An index that was never refreshed answers "Unable to locate package" for
  # names that do exist. A third-party repo can make this fail while our own
  # packages are perfectly reachable, so a failure here is only recorded.
  run apt-get -o DPkg::Lock::Timeout=120 update || note "apt-get update reported errors"
}

# Each package goes in on its own: "apt-get install A B C" installs NOTHING
# when one name in the list is unknown.
supply() {  # supply <probe> <package...>
  local probe="$1"; shift
  apt_refresh
  local pkg
  for pkg in "$@"; do
    run env DEBIAN_FRONTEND=noninteractive apt-get -y \
      -o DPkg::Lock::Timeout=120 install "$pkg"
    have "$probe" && { printf '%s' "$pkg"; return 0; }
  done
  return 1
}

install_deps() {
  if [ ${#MISSING[@]} -eq 0 ]; then
    ok "dependencies - nothing to add"
    return 0
  fi

  wait_for_apt
  busy "installing ${#MISSING[@]} package(s)"
  local line level probe pkgs why pkg added=0 lost=()
  for line in "${MISSING[@]}"; do
    IFS='|' read -r level probe pkgs why <<< "$line"
    # shellcheck disable=SC2086
    if pkg="$(supply "$probe" $pkgs)"; then
      added=$((added + 1)); note "added $pkg for ${probe#*:}"
    else
      lost+=("$level|${probe#*:}|${pkgs%% *}|$why")
    fi
  done

  local blocked=0
  for line in "${lost[@]}"; do
    IFS='|' read -r level probe pkgs why <<< "$line"
    if [ "$level" = need ]; then
      blocked=$((blocked + 1))
      warn "$probe could not be installed - $why"
    else
      warn "$probe not installed - $why. That control is skipped, the rest runs"
      pending "install $pkgs later to use $probe"
    fi
  done

  if [ "$blocked" -gt 0 ]; then
    printf '\n      apt said:\n'
    grep -iE "^(E:|W:)|Unable to locate|Temporary failure|not signed" "$LOGFILE" \
      | tail -n 5 | sed 's/^/        /'
    printf '\n'
    die "$blocked required package(s) could not be installed"
  fi
  ok "dependencies - $added added"
}

create_agent_user() {
  if ! id "$AGENT" >/dev/null 2>&1; then
    useradd --system --shell /usr/sbin/nologin --no-create-home "$AGENT" \
      || die "could not create the $AGENT user"
  fi
  # In the sudo group it would inherit full rights and the sudoers restriction
  # would mean nothing. No pipe, on purpose: under pipefail "id -nG | grep -qx
  # sudo" reads as failure when grep matches and closes the pipe, so the check
  # would PASS exactly when the agent really is in the sudo group.
  local groups
  groups=" $(id -nG "$AGENT" 2>/dev/null) "
  case "$groups" in
    *" sudo "*) die "$AGENT is in the sudo group, which cancels every restriction. Remove it: gpasswd -d $AGENT sudo" ;;
  esac
  ok "user $AGENT - no shell, not in sudo"
}

create_dirs() {
  install -d -o root -g root -m 755 "$BIN_DIR" "$CATALOG_DIR" "$ETC_DIR" \
    || die "could not create the program folders"

  # 2750: setgid, so logs root writes here inherit the yoru-agent group and the
  # dashboard - which runs as the agent - can READ the trail. No group write
  # bit, so the agent still cannot edit or delete its own record.
  install -d -o root -g "$AGENT" -m 2750 "$LOG_DIR" || die "could not create $LOG_DIR"
  # Older installs wrote root:root, and setgid does not apply retroactively.
  chgrp "$AGENT" "$LOG_DIR"/*.log 2>/dev/null || true

  # The only directory the agent may write; $LOG_DIR stays root's.
  install -d -o "$AGENT" -g "$AGENT" -m 750 "$DATA_DIR" "$DATA_DIR/riwayat" \
    || die "could not create $DATA_DIR"
  # If the agent was ever run under sudo, the last report is root-owned and the
  # daily cycle silently cannot overwrite it.
  chown -R "$AGENT":"$AGENT" "$DATA_DIR" 2>/dev/null || true

  # The agent may change the server, but not the record of how it looked before.
  install -d -o root -g root -m 700 "$BASELINE_DIR" || die "could not create $BASELINE_DIR"

  note "dirs: $BIN_DIR $CATALOG_DIR $ETC_DIR"
  note "      $LOG_DIR root:$AGENT 2750 (agent reads, cannot write)"
  note "      $DATA_DIR $AGENT:$AGENT 750"
  note "      $BASELINE_DIR root:root 700 (agent cannot touch)"
  ok "folders and permissions"
}

# Before 0.1.3 the action log was free text, now one JSON object per line. Mixed
# in one file the dashboard's parser breaks, so old lines are moved aside.
migrate_old_log() {
  local file="$LOG_DIR/tindakan.log" dest tmp text_lines
  [ -s "$file" ] || return 0
  text_lines=$(grep -cv '^{' "$file" 2>/dev/null) || text_lines=0
  [ "${text_lines:-0}" -gt 0 ] || return 0

  # Sorted per line, not moved wholesale: moving the whole file carries off the
  # JSON lines too, leaving the combined log shorter than the per-control logs.
  dest="$file.old-text.$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp) || return 0
  grep -v '^{' "$file" > "$dest" 2>/dev/null
  grep    '^{' "$file" > "$tmp"  2>/dev/null
  cat "$tmp" > "$file"
  rm -f "$tmp"
  chmod 640 "$file" "$dest" 2>/dev/null || true
  note "moved $text_lines old free-text log lines to $(basename "$dest")"
}

install_files() {
  migrate_old_log
  install -o root -g root -m 755 "$SRC/bin/yoructl" "$BIN_DIR/yoructl" \
    || die "could not copy the dispatcher"
  [ -f "$SRC/bin/yoru-agent" ] && {
    install -o root -g root -m 755 "$SRC/bin/yoru-agent" "$BIN_DIR/yoru-agent" \
      || die "could not copy the agent"
  }
  printf '%s\n' "$OWNER" > "$ETC_DIR/pemilik"
  chown root:root "$ETC_DIR/pemilik"; chmod 644 "$ETC_DIR/pemilik"

  local n=0 f
  for f in "$SRC"/catalog/*.yaml; do
    [ -f "$f" ] || continue
    install -o root -g root -m 644 "$f" "$CATALOG_DIR/" || die "could not copy $(basename "$f")"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || die "no catalog files were copied"

  # root-owned: a catalog the agent could edit is the agent rewriting its rules.
  ok "program files and $n catalog files - agent can read, not change"
}

install_sudoers() {
  local tmp=/tmp/yoru-sudoers.$$
  cp "$SRC/bin/yoru.sudoers" "$tmp" || die "could not prepare the sudoers file"
  # Checked first - a broken sudoers file kills sudo until recovery mode.
  if ! run visudo -c -f "$tmp"; then
    rm -f "$tmp"; die "the sudoers file did not pass visudo - nothing was installed"
  fi
  install -o root -g root -m 0440 "$tmp" "$SUDOERS" || { rm -f "$tmp"; die "could not install the sudoers file"; }
  rm -f "$tmp"
  run visudo -c || die "sudoers as a whole is now invalid - delete $SUDOERS right now"
  ok "sudoers rule - checked with visudo before and after"
}

apply_sshkey() {
  [ -n "$SSHKEY" ] || return 0
  local group file="$OWNER_HOME/.ssh/authorized_keys"
  group="$(id -gn "$OWNER")"
  install -d -o "$OWNER" -g "$group" -m 700 "$OWNER_HOME/.ssh" \
    || { warn "could not create $OWNER_HOME/.ssh"; return 0; }
  # Appended, never overwritten - the file may hold someone else's key.
  printf '%s\n' "$SSHKEY" >> "$file" || { warn "could not write $file"; return 0; }
  chown "$OWNER":"$group" "$file"; chmod 600 "$file"
  ok "SSH key added for $OWNER"
  pending "test that key from another terminal BEFORE approving K02"
}

write_config() {
  if [ -f "$CONFIG_FILE" ]; then
    chown root:"$AGENT" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
    ok "config kept as it is - $CONFIG_FILE"
  else
    install -o root -g "$AGENT" -m 640 "$SRC/examples/yoru.conf.example" "$CONFIG_FILE" \
      || die "could not create $CONFIG_FILE"
    ok "config $CONFIG_FILE - agent can read it, nobody else can"
  fi

  [ -n "$TG_TOKEN" ] && config_set "$CONFIG_FILE" TELEGRAM_TOKEN "$TG_TOKEN"
  chown root:"$AGENT" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"

  # Nobody was asked anything, so say what is still empty rather than assume.
  if [ "$INTERACTIVE" != yes ] && [ -z "$(config_get "$CONFIG_FILE" TELEGRAM_TOKEN)" ]; then
    pending "no Telegram token yet - add one in Settings for alerts on your phone"
  fi
  return 0
}

# ------------------------------------------------------------------- AI model
# Yoru speaks one shape: POST /v1/chat/completions on 127.0.0.1. The API key
# never reaches yoru.conf - that is the one file the agent is allowed to read.
model_probe() {  # model_probe <url> <token> <model>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys, urllib.request
url, token, model = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3] or "yoru"
body = json.dumps({"model": model, "max_tokens": 60, "messages": [
    {"role": "user", "content": "Balas satu kalimat pendek bahasa Indonesia: kamu siap."}]}).encode()
req = urllib.request.Request(url + "/v1/chat/completions", data=body, method="POST")
req.add_header("Content-Type", "application/json")
if token:
    req.add_header("Authorization", "Bearer " + token)
try:
    with urllib.request.urlopen(req, timeout=45) as r:
        print(json.load(r)["choices"][0]["message"]["content"].strip()[:160])
except Exception as e:
    print("ERROR", e)
PY
}

install_gemini() {
  local port=8080 busy
  busy="$(port_owner 8080)"
  case "$busy" in ""|"?") : ;; *) port=8090 ;; esac

  id "$MODEL_USER" >/dev/null 2>&1 \
    || useradd --system --no-create-home --shell /usr/sbin/nologin "$MODEL_USER" \
    || { warn "could not create the $MODEL_USER user"; return 1; }

  umask 077
  printf 'GEMINI_API_KEY=%s\nGEMINI_MODEL=%s\n' "$MODEL_KEY" "$MODEL_NAME" > "$MODEL_ENV"
  umask 022
  chown root:"$MODEL_USER" "$MODEL_ENV"; chmod 0640 "$MODEL_ENV"

  # Proven, not assumed: if the agent can read the key, the split is decoration.
  if sudo -u "$AGENT" test -r "$MODEL_ENV" 2>/dev/null; then
    rm -f "$MODEL_ENV"
    warn "$AGENT can still read the key - the model was not set up"
    return 1
  fi

  install -o root -g root -m 755 "$SRC/bin/yoru-model-proxy" "$MODEL_BIN" \
    || { warn "could not copy yoru-model-proxy"; return 1; }

  # Tested before the service is switched on. Model names go stale without
  # notice, so the connector also picks one that is still alive.
  local report way picked
  report="$(GEMINI_API_KEY="$MODEL_KEY" GEMINI_MODEL="$MODEL_NAME" \
            python3 "$MODEL_BIN" --diagnose 2>&1)"
  note "$report"
  way="$(printf '%s' "$report" | sed -n 's/.*GEMINI_WAY=\([a-z-]*\).*/\1/p' | head -1)"
  picked="$(printf '%s' "$report" | sed -n 's/.*GEMINI_MODEL=\([A-Za-z0-9._-]*\).*/\1/p' | head -1)"

  if [ -z "$way" ]; then
    warn "Google refused the key. Its own words:"
    printf '%s\n' "$report" | tail -n 6 | sed 's/^/        /'
    rm -f "$MODEL_ENV"
    return 1
  fi

  if [ -n "$picked" ] && [ "$picked" != "$MODEL_NAME" ]; then
    note "Google refused $MODEL_NAME, using $picked"
    MODEL_NAME="$picked"
    sed -i "s|^GEMINI_MODEL=.*|GEMINI_MODEL=$MODEL_NAME|" "$MODEL_ENV"
  fi
  printf 'GEMINI_WAY=%s\n' "$way" >> "$MODEL_ENV"

  cat > "$MODEL_UNIT" <<EOF
[Unit]
Description=Yoru bridge to the Gemini API
After=network-online.target
Wants=network-online.target

[Service]
User=$MODEL_USER
Group=$MODEL_USER
EnvironmentFile=$MODEL_ENV
Environment=LISTEN_HOST=127.0.0.1
Environment=LISTEN_PORT=$port
ExecStart=$MODEL_BIN
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now yoru-model.service
  sleep 2
  systemctl is-active --quiet yoru-model.service \
    || { warn "the model service did not start - see: journalctl -u yoru-model -n 20"; return 1; }

  local answer; answer="$(model_probe "http://127.0.0.1:$port" "" "$MODEL_NAME")"
  note "model replied: $answer"
  case "$answer" in
    ERROR*|"")
      warn "the model service is up but not answering yet"
      pending "check the model with: journalctl -u yoru-model -n 20 --no-pager"
      return 1 ;;
  esac

  config_set "$CONFIG_FILE" HERMES_URL "http://127.0.0.1:$port"
  ok "AI model - Gemini ($MODEL_NAME)"
}

install_model() {
  local existing; existing="$(config_get "$CONFIG_FILE" HERMES_URL)"
  if [ -n "$existing" ]; then
    ok "AI model - already set to $existing"
    return 0
  fi

  case "$MODEL_CHOICE" in
    gemini)
      install_gemini || pending "no AI model yet - add one in Settings when you want it"
      ;;
    url)
      local answer; answer="$(model_probe "$MODEL_URL" "$MODEL_TOKEN" "$MODEL_NAME")"
      note "model replied: $answer"
      case "$answer" in
        ERROR*|"")
          warn "no answer from $MODEL_URL"
          printf '        %s\n' "$answer"
          pending "no AI model yet - add one in Settings when you want it"
          return 0 ;;
      esac
      config_set "$CONFIG_FILE" HERMES_URL "$MODEL_URL"
      [ -n "$MODEL_TOKEN" ] && config_set "$CONFIG_FILE" HERMES_TOKEN "$MODEL_TOKEN"
      [ -n "$MODEL_NAME" ]  && config_set "$CONFIG_FILE" AI_MODEL "$MODEL_NAME"
      ok "AI model - $MODEL_URL"
      ;;
    *)
      ok "AI model - off, wording comes from the catalog"
      [ "$INTERACTIVE" = yes ] \
        || pending "no AI model yet - add one in Settings to get plain-language reports"
      ;;
  esac
  chown root:"$AGENT" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
  return 0
}

install_timer() {
  install -o root -g root -m 755 "$SRC/bin/yoru-watch" "$BIN_DIR/yoru-watch" \
    || die "could not copy yoru-watch"

  local at tz
  at="$(config_get "$CONFIG_FILE" JAM_PENJAGAAN)"; [ -n "$at" ] || at="03:17"
  tz="$(config_get "$CONFIG_FILE" ZONA_WAKTU)"
  [ -n "$tz" ] || tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
  [ -n "$tz" ] || tz="UTC"

  # A timer that fails to load does not shout - it simply never runs.
  case "$at" in
    [0-2][0-9]:[0-5][0-9]) : ;;
    *) die "JAM_PENJAGAAN in $CONFIG_FILE must look like HH:MM, it currently says '$at'" ;;
  esac

  install -o root -g root -m 644 "$SRC/systemd/yoru-watch.service" \
    "$SYSTEMD_DIR/yoru-watch.service" || die "could not install the watch service"
  sed -e "s|@JAM@|$at|" -e "s|@ZONA@|$tz|" \
      "$SRC/systemd/yoru-watch.timer" > "$SYSTEMD_DIR/yoru-watch.timer" \
    || die "could not install the watch timer"
  chown root:root "$SYSTEMD_DIR/yoru-watch.timer"; chmod 644 "$SYSTEMD_DIR/yoru-watch.timer"

  # One typo in "Asia/Jakarta" and systemd rejects the timer silently.
  if command -v systemd-analyze >/dev/null 2>&1; then
    run systemd-analyze calendar "*-*-* $at:00 $tz" \
      || die "systemd rejected the schedule '$at $tz' - check ZONA_WAKTU in $CONFIG_FILE"
  fi

  run systemctl daemon-reload || die "systemctl daemon-reload failed"
  run systemctl enable --now yoru-watch.timer || die "could not start the watch timer"
  systemctl is-active yoru-watch.timer >/dev/null 2>&1 \
    || die "the timer is installed but not active - check: systemctl status yoru-watch.timer"
  ok "daily check at $at $tz"
  WATCH_AT="$at"; WATCH_TZ="$tz"
}

# ----------------------------------------------------------------- dashboard
# A venv is only usable once pip is inside it. Checking bin/python is not
# enough: a failed "python3 -m venv" still leaves the directory behind with a
# python symlink and no pip, and the next run then reports a missing file
# instead of the missing package.
venv_ready() {
  [ -x "$WEB_DIR/venv/bin/python" ] || return 1
  local out
  out="$("$WEB_DIR/venv/bin/python" -m pip --version 2>/dev/null)" || return 1
  # pip must be the venv's own. A half-built venv can still reach the system
  # pip, which would then install into /usr and look like it worked.
  case "$out" in *"$WEB_DIR/venv"*) return 0 ;; *) return 1 ;; esac
}

build_venv() {
  venv_ready && return 0
  rm -rf "$WEB_DIR/venv"
  run python3 -m venv "$WEB_DIR/venv"
  venv_ready && return 0

  # preflight already made sure ensurepip is importable, so a failure here is
  # something else - try the manual route before giving up.
  run python3 -m venv --without-pip "$WEB_DIR/venv"
  run "$WEB_DIR/venv/bin/python" -m ensurepip --upgrade
  venv_ready && return 0

  warn "could not build the dashboard's venv. The system said:"
  last_words 6
  pending "try: sudo apt-get install -y python${PY_VER:-3}-venv python3-pip, then run the installer again"
  return 1
}

install_dashboard() {
  if [ "$WITH_DASHBOARD" != yes ]; then
    ok "dashboard - skipped (--no-dashboard)"
    pending "without the dashboard there are no Telegram buttons either"
    return 0
  fi
  local f
  for f in web/api.py web/dashboard.html systemd/yoru-web.service; do
    [ -f "$SRC/$f" ] || { warn "$f is missing - dashboard skipped"; return 0; }
  done

  install -d -o root -g root -m 755 "$WEB_DIR" || die "could not create $WEB_DIR"
  install -o root -g root -m 644 "$SRC/web/api.py" "$WEB_DIR/api.py" || die "could not copy api.py"
  install -o root -g root -m 644 "$SRC/web/dashboard.html" "$WEB_DIR/dashboard.html" \
    || die "could not copy dashboard.html"

  # A venv, not pip into the system - other tools share those packages.
  build_venv || return 0

  if ! "$WEB_DIR/venv/bin/python" -c 'import fastapi, uvicorn' 2>/dev/null; then
    busy "downloading fastapi and uvicorn - the slowest step"
    run "$WEB_DIR/venv/bin/python" -m pip install --disable-pip-version-check fastapi uvicorn
  fi
  if ! "$WEB_DIR/venv/bin/python" -c 'import fastapi, uvicorn' 2>/dev/null; then
    # pip's own last words, not our guess about them.
    warn "fastapi and uvicorn could not be installed. pip said:"
    last_words 8
    pending "fix that, then run the installer again - everything else is in place"
    return 0
  fi

  # No token from 127.0.0.1 - whoever reaches it already has the server. Opened
  # to the network the buttons are anyone's, so a token is generated here.
  local token; token="$(config_get "$CONFIG_FILE" DASHBOARD_TOKEN)"
  case "$WEB_HOST" in
    127.0.0.1|localhost|::1) : ;;
    *) if [ -z "$token" ]; then
         token="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
         config_set "$CONFIG_FILE" DASHBOARD_TOKEN "$token"
       fi ;;
  esac
  if [ -n "$token" ]; then
    printf 'YORU_TOKEN=%s\n' "$token" > "$WEB_ENV"
    chown root:"$AGENT" "$WEB_ENV"; chmod 640 "$WEB_ENV"
    note "$WEB_ENV written - the token stays out of 'ps'"
  else
    rm -f "$WEB_ENV"
  fi

  sed -e "s|@HOST@|$WEB_HOST|" -e "s|@PORT@|$WEB_PORT|" \
      "$SRC/systemd/yoru-web.service" > "$SYSTEMD_DIR/yoru-web.service" \
    || die "could not install the dashboard service"
  chown root:root "$SYSTEMD_DIR/yoru-web.service"; chmod 644 "$SYSTEMD_DIR/yoru-web.service"

  run systemctl daemon-reload || die "systemctl daemon-reload failed"
  run systemctl enable yoru-web.service
  run systemctl restart yoru-web.service \
    || die "the dashboard would not start - see: journalctl -u yoru-web -n 30"

  # Waited on until it really answers, not just until systemd says "active": a
  # process that dies a second after starting counts as active for that second.
  if ! python3 - "$WEB_PORT" <<'PY'
import sys, time, urllib.request
url = "http://127.0.0.1:%s/health" % sys.argv[1]
for _ in range(30):
    try:
        if urllib.request.urlopen(url, timeout=2).status == 200:
            sys.exit(0)
    except Exception:
        time.sleep(1)
sys.exit(1)
PY
  then die "the dashboard did not answer within 30 seconds - see: journalctl -u yoru-web -n 30"
  fi

  # Something answering on the port is not proof WE answered: if the port was
  # already taken, our unit dies while the other program keeps replying.
  systemctl is-active yoru-web.service >/dev/null 2>&1 \
    || die "port $WEB_PORT belongs to another program, not Yoru. Pick another: --port <number>"
  ok "dashboard at http://$WEB_HOST:$WEB_PORT"

  # The agent uses 127.0.0.1 even when the dashboard is open to the network.
  local url; url="$(config_get "$CONFIG_FILE" DASHBOARD_URL)"
  if [ -z "$url" ]; then
    config_set "$CONFIG_FILE" DASHBOARD_URL "http://127.0.0.1:$WEB_PORT"
  elif [ "${url%/}" != "http://127.0.0.1:$WEB_PORT" ]; then
    # Not overwritten - it may point at another dashboard on purpose.
    warn "DASHBOARD_URL in the config still says '$url'"
    pending "reports will not reach this dashboard until DASHBOARD_URL is http://127.0.0.1:$WEB_PORT"
  fi
  chown root:"$AGENT" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
}

count_reports() {
  python3 - "$WEB_PORT" <<'PY' 2>/dev/null || printf '0\n'
import sys, json, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:%s/api/servers" % sys.argv[1], timeout=5) as r:
        print(sum(int(s.get("reports") or 0) for s in json.load(r).get("servers", [])))
except Exception:
    print(0)
PY
}

# An empty dashboard on first open looks like a failed install. --kering checks
# the controls and sends the report without touching one setting on the server.
seed_dashboard() {
  [ "$WITH_DASHBOARD" = yes ] || return 0
  [ -x "$BIN_DIR/yoru-agent" ] || return 0
  systemctl is-active yoru-web.service >/dev/null 2>&1 || return 0

  busy "reading the 10 controls once, changing nothing"
  local before; before="$(count_reports)"
  run timeout 300 sudo -u "$AGENT" env HOME="$DATA_DIR" "$BIN_DIR/yoru-agent" \
    --siklus penjagaan --kering --konfigurasi "$CONFIG_FILE"

  # Counted before and after: a reinstall always finds older reports, and the
  # exit code proves nothing either - the agent exits 0 even when the dashboard
  # is unreachable.
  if [ "$(count_reports)" -gt "$before" ]; then
    ok "first report is in the dashboard"
  else
    warn "the first report did not arrive"
    pending "run it by hand and read the message: sudo -u $AGENT $BIN_DIR/yoru-agent --siklus penjagaan --kering"
  fi
}

install_all() {
  phase "Installing"
  install_deps
  create_agent_user
  create_dirs
  install_files
  install_sudoers
  apply_sshkey
  write_config
  install_model
  install_timer
  install_dashboard
  seed_dashboard
}

# ================================================================== 4. verify

verify() {
  phase "Verifying"
  local out

  out=$(sudo -u "$AGENT" sudo -n "$BIN_DIR/yoructl" K01 periksa 2>&1)
  note "$out"
  case "$out" in
    *'"id":"K01"'*) ok "the agent can run an allowed action" ;;
    *) die "the agent cannot reach the dispatcher - see $LOGFILE" ;;
  esac

  if sudo -u "$AGENT" sudo -n id >/dev/null 2>&1
    then die "DANGER: the agent can run other commands. The sudoers restriction is not working."
    else ok "the agent is blocked from anything else"
  fi

  chmod 777 "$BIN_DIR/yoructl"
  out=$(sudo -u "$AGENT" sudo -n "$BIN_DIR/yoructl" K01 periksa 2>&1)
  chmod 755 "$BIN_DIR/yoructl"
  case "$out" in
    *DITOLAK*) ok "the dispatcher refuses to run while it is writable" ;;
    *) die "the dispatcher ran with loose permissions - its self-check is not working" ;;
  esac

  out=$(sudo -u "$AGENT" sudo -n "$BIN_DIR/yoructl" K01 periksa 2>&1)
  case "$out" in
    *'"id":"K01"'*) : ;;
    *) die "the dispatcher did not recover after chmod 755" ;;
  esac

  # If yoru-watch ran as root the sudoers restriction would be decorative.
  out=$("$BIN_DIR/yoru-watch" 2>&1)
  case "$out" in
    *"harus berjalan sebagai yoru-agent"*) ok "the watch refuses to run as root" ;;
    *) die "the watch did not refuse to run as root" ;;
  esac

  local timers; timers=$(systemctl list-timers --all --no-pager 2>/dev/null)
  case "$timers" in
    *yoru-watch*) ok "the daily timer is registered with systemd" ;;
    *) die "the timer does not appear in systemd's list" ;;
  esac
}

# ================================================================= 5. finished

summary() {
  local addr web
  addr="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -n "$addr" ] || addr="<server-ip>"
  if systemctl is-active yoru-web.service >/dev/null 2>&1; then
    web="http://$WEB_HOST:$WEB_PORT"
  elif [ "$WITH_DASHBOARD" != yes ]; then
    web="off (--no-dashboard)"
  else
    web="not installed"
  fi

  printf '\n%sDone. Yoru %s is watching this server.%s\n\n' "$BOLD" "$VERSION" "$RESET"
  item "Dashboard"   "$web"
  item "Daily check" "${WATCH_AT:-03:17} ${WATCH_TZ:-UTC}"
  item "Owner"       "$OWNER"
  item "Config"      "$CONFIG_FILE"
  item "Install log" "$LOGFILE"

  if [ "$web" != "not installed" ] && [ "$WITH_DASHBOARD" = yes ]; then
    case "$WEB_HOST" in
      127.0.0.1|localhost|::1)
        printf '\n  Open the dashboard from your laptop:\n'
        printf '      ssh -L %s:127.0.0.1:%s %s@%s\n' "$WEB_PORT" "$WEB_PORT" "$OWNER" "$addr"
        printf '      then open http://127.0.0.1:%s in your browser\n' "$WEB_PORT" ;;
      *)
        printf '\n  The dashboard is open to the network. Token for the buttons:\n'
        printf '      %s\n' "$(config_get "$CONFIG_FILE" DASHBOARD_TOKEN)"
        pending "port $WEB_PORT is not in PORT_DIIZINKAN yet, so K05 will not turn the firewall on" ;;
    esac
  fi

  printf '\n  Check the server now\n'
  printf '      sudo -u %s %s/yoru-agent --siklus penjagaan\n' "$AGENT" "$BIN_DIR"
  printf '  Remove Yoru\n'
  printf '      sudo bash install.sh --uninstall\n'

  if [ ! -x "$BIN_DIR/yoru-agent" ]; then
    pending "the agent itself is not installed - the daily cycle will do nothing"
  fi

  if [ ${#PENDING[@]} -gt 0 ]; then
    printf '\n%sStill open%s\n' "$BOLD" "$RESET"
    local p
    for p in "${PENDING[@]}"; do printf '  %s!%s   %s\n' "$AMBER" "$RESET" "$p"; done
  fi
  printf '\n'
}

# ================================================================= uninstall

uninstall() {
  phase "Removing Yoru"
  run systemctl disable --now yoru-watch.timer
  run systemctl disable --now yoru-web.service
  run systemctl disable --now yoru-model.service
  rm -f "$SYSTEMD_DIR/yoru-watch.timer" "$SYSTEMD_DIR/yoru-watch.service" \
        "$SYSTEMD_DIR/yoru-web.service" "$MODEL_UNIT"
  run systemctl daemon-reload
  ok "timer, dashboard and model bridge stopped"

  gone() {  # gone <path> <sentence> - only says so when there was something
    [ -e "$1" ] || return 0
    rm -rf "$1" && ok "$2"
  }
  gone "$MODEL_ENV" "model key removed"
  id "$MODEL_USER" >/dev/null 2>&1 && userdel "$MODEL_USER" 2>/dev/null \
    && ok "user $MODEL_USER removed"
  rm -f "$WEB_ENV"
  gone "$SUDOERS"       "sudoers rule removed"
  gone /opt/yoru        "/opt/yoru removed"
  gone /usr/share/yoru  "/usr/share/yoru removed"

  if id "$AGENT" >/dev/null 2>&1; then
    if userdel "$AGENT" 2>/dev/null
      then ok "user $AGENT removed"
      else warn "user $AGENT could not be removed - usually a process is still running"
           # uninstall exits before the summary, so this is said here, not queued
           printf '        look first: pgrep -u %s -a\n' "$AGENT"
           printf '        then:       sudo userdel %s\n' "$AGENT"
    fi
  fi
  warn "$LOG_DIR, $ETC_DIR, $DATA_DIR and $BASELINE_DIR were left on purpose"

  # Not ours to delete uncalled for, but not ours to stay quiet about either.
  if [ -f "$CONFIG_FILE" ]; then
    printf '\n  %s%s still holds your API key and bot token.%s\n' "$AMBER" "$CONFIG_FILE" "$RESET"
    printf '  If this server is being sold, handed back or retired, delete it:\n'
    printf '      sudo rm %s\n' "$CONFIG_FILE"
  fi
  printf '\n  Controls that were already applied are NOT rolled back.\n'
  printf '  To undo them, run "kembalikan" per control before uninstalling.\n\n'
  exit 0
}

usage() {
  cat <<TEXT
Yoru $VERSION - installer

  sudo bash install.sh                  install everything
  sudo bash install.sh --check-only     look at this server, change nothing
  sudo bash install.sh --owner budi     install, naming the server owner
  sudo bash install.sh --no-questions   install without asking anything
  sudo bash install.sh --no-dashboard   install without the web dashboard
  sudo bash install.sh --host 0.0.0.0   open the dashboard to the network
  sudo bash install.sh --port 8080      change the dashboard port
  sudo bash install.sh --uninstall      remove Yoru

Run --check-only first if you want to see what would happen. It reads the
server and writes nothing.
TEXT
}

# ====================================================================== main

OWNER=""
INTERACTIVE="yes"
WITH_DASHBOARD="yes"
WEB_HOST="127.0.0.1"
WEB_PORT="8000"
DRY="no"
PY_VER=""
WATCH_AT=""
WATCH_TZ=""

while [ $# -gt 0 ]; do
  case "$1" in
    --owner|--pemilik)              OWNER="${2-}"; shift 2 ;;
    --no-questions|--tanpa-tanya)   INTERACTIVE="no"; shift ;;
    --no-dashboard|--tanpa-dashboard) WITH_DASHBOARD="no"; shift ;;
    --check-only|--periksa-saja)    DRY="yes"; shift ;;
    --host)                         WEB_HOST="${2-}"; shift 2 ;;
    --port)                         WEB_PORT="${2-}"; shift 2 ;;
    --uninstall|--copot)            check_root; open_log; uninstall ;;
    -h|--help)                      usage; exit 0 ;;
    *) printf 'unknown option: %s\n\n' "$1"; usage; exit 1 ;;
  esac
done

[ -n "$WEB_HOST" ] || { printf '--host cannot be empty\n'; exit 1; }
case "$WEB_PORT" in
  ''|*[!0-9]*) printf -- '--port must be a number, got "%s"\n' "$WEB_PORT"; exit 1 ;;
esac
[ "$WEB_PORT" -ge 1 ] && [ "$WEB_PORT" -le 65535 ] \
  || { printf -- '--port is out of range: %s\n' "$WEB_PORT"; exit 1; }

check_root
open_log

printf '\n%sYoru %s%s  installer\n' "$BOLD" "$VERSION" "$RESET"

check_all

if [ "$DRY" = yes ]; then
  verdict
  printf '\n%sReady to install.%s Nothing was changed.\n' "$BOLD" "$RESET"
  if [ ${#PENDING[@]} -gt 0 ]; then
    printf '\n%sWorth knowing first%s\n' "$BOLD" "$RESET"
    for p in "${PENDING[@]}"; do printf '  %s!%s   %s\n' "$AMBER" "$RESET" "$p"; done
  fi
  printf '\n  Run it for real:  sudo bash install.sh\n'
  printf '  Full log:         %s\n\n' "$LOGFILE"
  exit 0
fi

verdict
setup
install_all
verify
summary
