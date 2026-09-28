#!/bin/bash
# install.sh - the Yoru installer
#
# Five parts: check, ask, install, verify, report. Every question comes before
# anything is written. Safe to run again: each step looks at the current state.
#
# Not meant for "curl ... | sudo bash". Download it, read it, then run it.

set -uo pipefail
umask 022
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

SRC="$(dirname "$(readlink -f "$0")")"

# Read from the dispatcher, so the two version numbers cannot drift apart.
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

# Hermes Agent (Nous Research) gets its own user, and its API key lives in that
# user's home, which yoru-agent cannot open. Pinned to the commit this installer
# was tested with, so an upstream push cannot change what gets installed.
HERMES_USER="yoru-hermes"
HERMES_HOME_DIR="/var/lib/yoru-hermes"
HERMES_DIR="$HERMES_HOME_DIR/.hermes"
HERMES_UNIT="$SYSTEMD_DIR/yoru-hermes.service"
HERMES_REPO="https://github.com/NousResearch/hermes-agent.git"
HERMES_COMMIT="7dbbb0f4a6ebeec9a8714ec37fa41340fe9e4e00"

# Four markers only - ok, !, x, and .. for work in progress - so the output still
# reads with the colour stripped, in a pipe or a support ticket.
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

# Questions come as whiptail boxes when the terminal can draw them, plain prompts
# otherwise. Everything after them stays plain text, so errors can be copied out.
dialog_ready() {
  [ "$INTERACTIVE" = yes ] || return 1
  [ -r /dev/tty ] || return 1
  [ -t 0 ] && [ -t 2 ] || return 1
  case "${TERM:-dumb}" in dumb|"") return 1 ;; esac
  command -v whiptail >/dev/null 2>&1
}

# whiptail answers on stderr, hence the 3>&1 1>&2 2>&3 dance.
box_input() {  # box_input <title> <text> [default]
  whiptail --backtitle "Yoru $VERSION" --title "$1" \
           --inputbox "$2" 15 74 "${3-}" 3>&1 1>&2 2>&3
}
box_pass() {   # box_pass <title> <text>
  whiptail --backtitle "Yoru $VERSION" --title "$1" \
           --passwordbox "$2" 15 74 3>&1 1>&2 2>&3
}
box_msg() {    # box_msg <title> <text>
  whiptail --backtitle "Yoru $VERSION" --title "$1" --msgbox "$2" 20 74
}
box_menu() {   # box_menu <title> <text> <tag> <label> ...
  local title="$1" text="$2" rows; shift 2
  rows=$(( $# / 2 ))
  whiptail --backtitle "Yoru $VERSION" --title "$title" \
           --menu "$text" $(( 14 + rows )) 74 "$rows" "$@" 3>&1 1>&2 2>&3
}
box_yesno() {  # box_yesno <title> <text>
  whiptail --backtitle "Yoru $VERSION" --title "$1" --yesno "$2" 20 74
}

# whiptail is Priority: important, so it is on almost every Ubuntu already.
# When it is not, one quiet install - and if that fails, plain prompts.
ensure_dialog() {
  [ "$INTERACTIVE" = yes ] || return 0
  command -v whiptail >/dev/null 2>&1 && return 0
  supply cmd:whiptail whiptail >/dev/null 2>&1 || true
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

# 1. Check the server. Nothing here writes; this is all --check-only runs.

# Asked of the lock itself (fcntl, as apt and dpkg use), not the process list:
# Ubuntu keeps an unattended-upgrade-shutdown process alive at all times.
apt_locked() {
  python3 - <<'PY'
import fcntl, os, sys
for path in ("/var/lib/dpkg/lock-frontend", "/var/lib/dpkg/lock",
             "/var/cache/apt/archives/lock", "/var/lib/apt/lists/lock"):
    try:
        fd = os.open(path, os.O_RDWR)        # never created, only opened
    except OSError:
        continue
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.lockf(fd, fcntl.LOCK_UN)
    except OSError:
        sys.exit(0)                          # somebody holds it
    finally:
        os.close(fd)
sys.exit(1)                                  # free
PY
}

# Only for the wording. The decision is apt_locked's.
lock_holder() {
  local line
  line="$(pgrep -a -f 'unattended-upgrade|apt-get|aptitude|packagekitd|/usr/bin/dpkg' 2>/dev/null \
          | grep -v -e shutdown -e pgrep | head -1)"
  case "$line" in
    *unattended-upgrade*) printf 'unattended-upgrades' ;;
    *apt-get*)            printf 'apt-get' ;;
    *aptitude*)           printf 'aptitude' ;;
    *dpkg*)               printf 'dpkg' ;;
    *packagekit*)         printf 'PackageKit' ;;
    *)                    printf 'another package manager' ;;
  esac
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
    *) warn "this is a $kind container - kernel settings (K10) may be read-only here" ;;
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

  if apt_locked; then
    warn "apt is busy right now ($(lock_holder)) - the installer will wait for it to finish"
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
  case "$who" in ""|"?") : ;; *) note "port 8080 taken by $who - the model connector will take the next free port" ;; esac
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
have() {  # have cmd:<name> | py:<module> | lib:<shared library>
  case "$1" in
    cmd:*) command -v "${1#cmd:}" >/dev/null 2>&1 ;;
    py:*)  python3 -c "import ${1#py:}" >/dev/null 2>&1 ;;
    lib:*) ldconfig -p 2>/dev/null | grep -qF "${1#lib:} " ;;
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

# 2. Setup. Every question lives here, before a single byte is written.

MODEL_CHOICE="skip"
MODEL_KEY=""
MODEL_NAME="gemini-flash-latest"
MODEL_URL=""
MODEL_TOKEN=""
HERMES_PROVIDER=""
HERMES_KEY=""
HERMES_MODEL=""
HERMES_BASE=""
HERMES_FALLBACKS=()
TG_TOKEN=""
PAIR_CODE=""
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

  local explain="$OWNER has no SSH key yet.

K02 turns password login off. Without a working key that
would close your only door, so K02 stays blocked until
there is one.

Make the key on YOUR computer, not here:

    ssh-keygen -t ed25519

Then copy the public half and paste it in the next box:

    Linux, macOS  cat ~/.ssh/id_ed25519.pub
    Windows       type %USERPROFILE%\\.ssh\\id_ed25519.pub

We never ask for a private key."

  local key
  if dialog_ready; then
    box_msg "SSH key" "$explain"
    key="$(box_input "SSH key" "Paste the public key line. Leave empty to skip." "")" || key=""
  else
    printf '\n%s\n\n' "$explain"
    ask "Public key (empty to skip)" key
  fi
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
  local explain="Telegram is optional.

With a bot token you get alerts on your phone and approve buttons there.
Make the bot with @BotFather, then paste the token it gives you.

You can also add this later, in the dashboard's Settings page.

Token (leave empty to skip):"

  if dialog_ready; then
    TG_TOKEN="$(box_pass "Telegram" "$explain")" || TG_TOKEN=""
  else
    printf '\n  Telegram is optional. With a bot token you get alerts on your phone\n'
    printf '  and approve buttons there. You can also add it later in Settings.\n\n'
    ask "Telegram bot token (empty to skip)" TG_TOKEN secret
  fi
}

ask_model() {
  local hosts; hosts="$(model_hosts)"

  local intro="Yoru works without an AI model - reports are still complete, the
wording just comes from the catalog instead.

With one, Yoru explains findings in plain language, and the Telegram bot
answers ordinary questions instead of only /status and /help."
  [ -n "$hosts" ] && intro="$intro

Found on this server: $hosts"

  local pick
  if dialog_ready; then
    pick="$(box_menu "AI model" "$intro" \
      "1" "Hermes Agent - installed here, you bring the API key" \
      "2" "Google Gemini - a small bridge, no agent" \
      "3" "An OpenAI-compatible address you run" \
      "4" "Skip - use the catalog wording")" || pick=4
  else
    printf '\n  %s\n\n' "$intro"
    printf '    1   Hermes Agent - installed here, you bring the API key\n'
    printf '    2   Google Gemini - a small bridge, no agent\n'
    printf '    3   Any OpenAI-compatible address you already run\n'
    printf '    4   Skip\n\n'
    ask "Choose 1, 2, 3 or 4 [1]" pick
  fi
  case "${pick:-1}" in
    1)
      ask_hermes && MODEL_CHOICE="hermes"
      ;;
    2)
      # Two key shapes are in circulation, AIza... and AQ... - both are valid.
      if dialog_ready; then
        MODEL_KEY="$(box_pass "Google Gemini" "Paste the API key from Google AI Studio.

It starts with AIza... or AQ... - both are valid.

The key is stored where only root can read it, never in the file
the agent is allowed to open.")" || MODEL_KEY=""
      else
        ask "Gemini API key" MODEL_KEY secret
      fi
      MODEL_KEY="${MODEL_KEY#GEMINI_API_KEY=}"
      MODEL_KEY="$(printf '%s' "$MODEL_KEY" | tr -d '\r\n "')"
      [ -n "$MODEL_KEY" ] || { printf '  Empty key - skipping.\n'; return 0; }
      if dialog_ready; then
        MODEL_NAME="$(box_input "Google Gemini" "Model name. Leave it as it is unless you know you want another - the connector picks a live one if this is refused." "gemini-flash-latest")" || MODEL_NAME=""
      else
        ask "Model name (empty = gemini-flash-latest)" MODEL_NAME
      fi
      MODEL_NAME="$(printf '%s' "$MODEL_NAME" | tr -d '\r\n ')"
      [ -n "$MODEL_NAME" ] || MODEL_NAME="gemini-flash-latest"
      MODEL_CHOICE="gemini"
      ;;
    3)
      local suggest=""
      case " $hosts " in *" ollama "*) suggest="http://127.0.0.1:11434" ;; esac
      local where="Anything that answers POST /v1/chat/completions works here -
Ollama, an OpenAI-shaped gateway, or your own server. Give the base
address only; Yoru adds /v1/chat/completions itself.

Address:"
      if dialog_ready; then
        MODEL_URL="$(box_input "AI model" "$where" "$suggest")" || MODEL_URL=""
      else
        printf '  %s\n' "$where"
        [ -n "$suggest" ] && printf '  Ollama is installed, so try: %s\n' "$suggest"
        ask "Address" MODEL_URL
      fi
      MODEL_URL="$(printf '%s' "$MODEL_URL" | tr -d '\r\n ')"
      MODEL_URL="${MODEL_URL%/}"; MODEL_URL="${MODEL_URL%/v1}"
      [ -n "$MODEL_URL" ] || { printf '  No address given - skipping.\n'; return 0; }
      if dialog_ready; then
        MODEL_TOKEN="$(box_pass "AI model" "Token, if that address needs one. Leave empty if it does not.")" || MODEL_TOKEN=""
        MODEL_NAME="$(box_input "AI model" "Model name, if that address needs one." "")" || MODEL_NAME=""
      else
        ask "Token, if it needs one (empty to skip)" MODEL_TOKEN secret
        ask "Model name (empty = default)" MODEL_NAME
      fi
      MODEL_NAME="$(printf '%s' "$MODEL_NAME" | tr -d '\r\n ')"
      MODEL_CHOICE="url"
      ;;
    *) MODEL_CHOICE="skip" ;;
  esac
}

# Which model Hermes runs on is the owner's choice and their bill. The key goes
# to Hermes only; Yoru keeps the local service token, never the provider key.
ask_hermes() {
  local pick text="Hermes Agent needs a model provider and its API key.
The key stays in Hermes' own folder, which the Yoru agent cannot read.

Where does the key come from?"
  if dialog_ready; then
    pick="$(box_menu "Hermes Agent" "$text" \
      "1" "Google AI Studio (Gemini key, AIza... or AQ...)" \
      "2" "OpenRouter (sk-or-...)" \
      "3" "Another OpenAI-compatible provider")" || return 1
  else
    printf '\n  %s\n\n' "$text"
    printf '    1   Google AI Studio (Gemini key, AIza... or AQ...)\n'
    printf '    2   OpenRouter (sk-or-...)\n'
    printf '    3   Another OpenAI-compatible provider\n\n'
    ask "Choose 1, 2 or 3 [1]" pick
  fi
  local suggest
  case "${pick:-1}" in
    2) HERMES_PROVIDER="openrouter"; suggest="google/gemini-3.8-flash" ;;
    3) HERMES_PROVIDER="custom";     suggest="" ;;
    *) HERMES_PROVIDER="gemini";     suggest="" ;;
  esac

  if [ "$HERMES_PROVIDER" = custom ]; then
    local where="Base address of the provider, ending in /v1.
For example: https://api.openai.com/v1"
    if dialog_ready; then
      HERMES_BASE="$(box_input "Hermes Agent" "$where" "")" || HERMES_BASE=""
    else
      printf '  %s\n' "$where"
      ask "Address" HERMES_BASE
    fi
    HERMES_BASE="$(printf '%s' "$HERMES_BASE" | tr -d '\r\n ')"; HERMES_BASE="${HERMES_BASE%/}"
    [ -n "$HERMES_BASE" ] || { printf '  No address given - skipping.\n'; return 1; }
  fi

  if dialog_ready; then
    HERMES_KEY="$(box_pass "Hermes Agent" "Paste the API key.")" || HERMES_KEY=""
  else
    ask "API key" HERMES_KEY secret
  fi
  HERMES_KEY="$(printf '%s' "$HERMES_KEY" | tr -d '\r\n "')"
  HERMES_KEY="${HERMES_KEY#*_API_KEY=}"
  [ -n "$HERMES_KEY" ] || { printf '  Empty key - skipping.\n'; return 1; }

  if [ "$HERMES_PROVIDER" = gemini ]; then
    ask_gemini_model
  else
    if dialog_ready; then
      HERMES_MODEL="$(box_input "Hermes Agent" "Model name. Leave it as it is if unsure." "$suggest")" || HERMES_MODEL=""
    else
      ask "Model name (empty = ${suggest:-required})" HERMES_MODEL
    fi
    HERMES_MODEL="$(printf '%s' "$HERMES_MODEL" | tr -d '\r\n ')"
    [ -n "$HERMES_MODEL" ] || HERMES_MODEL="$suggest"
  fi
  [ -n "$HERMES_MODEL" ] || { printf '  No model name - skipping.\n'; return 1; }
  return 0
}

# The text models Google lets this key call, one per line. The key goes in
# through the environment, so it never shows up in the process list.
gemini_models() {
  GEMINI_KEY="$HERMES_KEY" python3 - <<'PY'
import json, os, urllib.request
req = urllib.request.Request(
    "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200",
    headers={"x-goog-api-key": os.environ["GEMINI_KEY"]})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        models = json.load(r).get("models", [])
except Exception:
    raise SystemExit(1)
for m in models:
    if "generateContent" in m.get("supportedGenerationMethods", []):
        print(m["name"].split("/", 1)[-1])
PY
}

# One tiny call to one model: prints Google's HTTP status, 000 if no answer.
gemini_try() {  # gemini_try <model>
  GEMINI_KEY="$HERMES_KEY" python3 - "$1" <<'PY'
import json, os, sys, urllib.error, urllib.request
body = json.dumps({"contents": [{"parts": [{"text": "ok"}]}],
                   "generationConfig": {"maxOutputTokens": 16}}).encode()
req = urllib.request.Request(
    "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % sys.argv[1],
    data=body, headers={"x-goog-api-key": os.environ["GEMINI_KEY"], "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print("000")
PY
}

# Every message costs the owner a call, so the cheap Lite models come first,
# and among them the ones that answer right now: Google turns models away
# when they are busy (503) or the key's quota is used up (429). Only names
# Google lists for this key are offered; the owner may still type another,
# and it is checked against the same list. The other candidates become
# Hermes' backups, which it switches to when a message is turned away.
ask_gemini_model() {
  local models m pick i code
  local names=() notes=()
  models="$(gemini_models)" || models=""
  if [ -z "$models" ]; then
    printf '  Google did not list the models for this key (wrong key, or no internet).\n'
  fi
  if grep -qx gemini-flash-lite-latest <<<"$models"; then
    names+=(gemini-flash-lite-latest); notes+=("cheapest, follows Google's newest Lite")
  fi
  while read -r m; do
    [ -n "$m" ] && { names+=("$m"); notes+=("cheapest"); }
  done < <(grep -E '^gemini-[0-9.]+-flash-lite$' <<<"$models" | sort -rV | head -n 2)
  if grep -qx gemini-flash-latest <<<"$models"; then
    names+=(gemini-flash-latest); notes+=("smarter, costs more per message")
  fi

  if [ ${#names[@]} -gt 0 ]; then
    # One test call per model, then the ones that answered move to the top.
    printf '  Trying %s models with one short message each...\n' "${#names[@]}"
    local ready=() ready_notes=() rest=() rest_notes=()
    for i in "${!names[@]}"; do
      code="$(gemini_try "${names[$i]}")"
      note "gemini model ${names[$i]}: HTTP $code"
      case "$code" in
        200) ready+=("${names[$i]}"); ready_notes+=("${notes[$i]%%,*}, answering now") ;;
        429) rest+=("${names[$i]}");  rest_notes+=("${notes[$i]%%,*}, quota used up now") ;;
        503) rest+=("${names[$i]}");  rest_notes+=("${notes[$i]%%,*}, busy at Google now") ;;
        *)   rest+=("${names[$i]}");  rest_notes+=("${notes[$i]%%,*}, no answer (HTTP $code)") ;;
      esac
    done
    names=("${ready[@]}" "${rest[@]}"); notes=("${ready_notes[@]}" "${rest_notes[@]}")
    [ ${#ready[@]} -gt 0 ] || printf '  None answered right now. Pick one anyway; Hermes keeps the others as backups.\n'

    local text="Which model answers in Telegram? Each message costs one call on
this key, so a Lite model keeps the bill (or the free quota) small."
    if dialog_ready; then
      local items=()
      for i in "${!names[@]}"; do items+=("$((i + 1))" "${names[$i]} - ${notes[$i]}"); done
      items+=("t" "Type another model name")
      pick="$(box_menu "Hermes Agent" "$text" "${items[@]}")" || pick=1
    else
      printf '\n  %s\n\n' "$text"
      for i in "${!names[@]}"; do printf '    %s   %s - %s\n' "$((i + 1))" "${names[$i]}" "${notes[$i]}"; done
      printf '    t   Type another model name\n\n'
      ask "Choose [1]" pick
    fi
    pick="${pick:-1}"
    case "$pick" in
      [1-9]) if [ "$pick" -le ${#names[@]} ]; then
               HERMES_MODEL="${names[$((pick - 1))]}"
               hermes_backups "${names[@]}"
               return 0
             fi ;;
    esac
  fi

  # Typed by hand. With a list from Google, a name not on it is asked again.
  local default="${names[0]:-gemini-flash-lite-latest}"
  for i in 1 2 3; do
    if dialog_ready; then
      HERMES_MODEL="$(box_input "Hermes Agent" "Model name, exactly as Google writes it." "$default")" || HERMES_MODEL=""
    else
      ask "Model name (empty = $default)" HERMES_MODEL
    fi
    HERMES_MODEL="$(printf '%s' "$HERMES_MODEL" | tr -d '\r\n ')"
    HERMES_MODEL="${HERMES_MODEL#models/}"
    [ -n "$HERMES_MODEL" ] || HERMES_MODEL="$default"
    if [ -z "$models" ] || grep -qx -- "$HERMES_MODEL" <<<"$models"; then
      hermes_backups "${names[@]}"
      return 0
    fi
    printf '  Google does not offer %s to this key. Try again.\n' "$HERMES_MODEL"
  done
  HERMES_MODEL="$default"
  hermes_backups "${names[@]}"
  printf '  Using %s.\n' "$HERMES_MODEL"
}

# The candidates other than the chosen model, best first. Hermes switches to
# the first of them for a message the main model could not answer.
hermes_backups() {  # hermes_backups <candidate...>
  HERMES_FALLBACKS=()
  local m
  for m in "$@"; do
    [ "$m" = "$HERMES_MODEL" ] || HERMES_FALLBACKS+=("$m")
  done
}

recap() {
  phase "Setup"
  item "Owner"     "$OWNER"
  if [ "$WITH_DASHBOARD" = yes ]
    then item "Dashboard" "http://$WEB_HOST:$WEB_PORT"
    else item "Dashboard" "off (--no-dashboard)"
  fi
  if [ -n "$TG_TOKEN" ] || [ -n "$(config_get "$CONFIG_FILE" TELEGRAM_TOKEN)" ]
    then item "Telegram" "on"
    else item "Telegram" "off"
  fi
  case "$MODEL_CHOICE" in
    hermes) item "AI model" "Hermes Agent ($HERMES_PROVIDER, $HERMES_MODEL)" ;;
    gemini) item "AI model" "Google Gemini" ;;
    url)    item "AI model" "$MODEL_URL" ;;
    *)      item "AI model" "off - wording comes from the catalog" ;;
  esac
  item "Install log" "$LOGFILE"
}

# Shown in the confirm box and printed plainly afterwards, so it survives
# when the box disappears.
setup_summary() {
  local tg="off" model="off - wording comes from the catalog" web
  [ -n "$TG_TOKEN" ] || [ -n "$(config_get "$CONFIG_FILE" TELEGRAM_TOKEN)" ] && tg="on"
  case "$MODEL_CHOICE" in
    hermes) model="Hermes Agent ($HERMES_PROVIDER, $HERMES_MODEL)" ;;
    gemini) model="Google Gemini" ;;
    url)    model="$MODEL_URL" ;;
  esac
  if [ "$WITH_DASHBOARD" = yes ]
    then web="http://$WEB_HOST:$WEB_PORT"
    else web="off (--no-dashboard)"
  fi
  printf 'Owner       %s\nDashboard   %s\nTelegram    %s\nAI model    %s\n' \
         "$OWNER" "$web" "$tg" "$model"
}

confirm_start() {
  dialog_ready || return 0
  box_yesno "Ready to install" "$(setup_summary)

Nothing has been changed yet. From here it runs to the end on its own,
in plain text, so anything that goes wrong can be copied out.

Start?" || die "cancelled - nothing was changed"
}

setup() {
  resolve_owner
  ensure_dialog
  if [ "$INTERACTIVE" = yes ] && [ -r /dev/tty ]; then
    # Existing settings are never re-asked; re-running the installer must not
    # be a way to lose an API key.
    local existing; existing="$(config_get "$CONFIG_FILE" HERMES_URL)"
    ask_sshkey
    [ -n "$(config_get "$CONFIG_FILE" TELEGRAM_TOKEN)" ] || ask_telegram
    [ -n "$existing" ] || ask_model
  fi
  confirm_start
  recap
}

# 3. Install

wait_for_apt() {
  apt_locked || return 0
  local waited=0
  busy "apt is busy ($(lock_holder)) - waiting, up to 5 minutes"
  while [ "$waited" -lt 300 ]; do
    sleep 5; waited=$((waited + 5))
    if ! apt_locked; then
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
  # A never-refreshed index answers "Unable to locate package" for real names. A
  # broken third-party repo can fail this while ours is fine, so it is only logged.
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
  # In the sudo group the sudoers restriction means nothing. No pipe: under pipefail
  # "id -nG | grep -qx sudo" reads as failure exactly when grep matches.
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

  # 2750: setgid, so root's logs here get the yoru-agent group and the dashboard
  # (running as the agent) can read them; no group write, so it cannot edit them.
  install -d -o root -g "$AGENT" -m 2750 "$LOG_DIR" || die "could not create $LOG_DIR"
  # Older installs wrote root:root, and setgid does not apply retroactively.
  chgrp "$AGENT" "$LOG_DIR"/*.log 2>/dev/null || true

  # The only directory the agent may write; $LOG_DIR stays root's.
  install -d -o "$AGENT" -g "$AGENT" -m 750 "$DATA_DIR" "$DATA_DIR/history" \
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

# Very old installs logged free text; mixed with JSON lines it breaks the
# dashboard's parser, so those lines are moved aside.
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

  if [ -n "$(config_get "$CONFIG_FILE" TELEGRAM_TOKEN)" ] \
     && [ -z "$(config_get "$CONFIG_FILE" TELEGRAM_CHAT_ID)" ]; then
    PAIR_CODE="$(config_get "$CONFIG_FILE" TELEGRAM_PAIR_CODE)"
    if [ -z "$PAIR_CODE" ]; then
      PAIR_CODE="$(python3 -c 'import secrets; print("".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(6)))')"
      config_set "$CONFIG_FILE" TELEGRAM_PAIR_CODE "$PAIR_CODE"
    fi
    ok "Telegram - waiting to be paired"
    pending "open your bot and send:  /start $PAIR_CODE"
  fi

  chown root:"$AGENT" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"

  # Nobody was asked anything, so say what is still empty rather than assume.
  if [ "$INTERACTIVE" != yes ] && [ -z "$(config_get "$CONFIG_FILE" TELEGRAM_TOKEN)" ]; then
    pending "no Telegram token yet - add one in Settings for alerts on your phone"
  fi
  return 0
}

# AI model. Yoru speaks one shape, POST /v1/chat/completions. The API key never
# reaches yoru.conf, the one file the agent is allowed to read.
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
        answer = json.load(r)
    # Hermes reports a failed turn (wrong model name, used-up quota) as
    # HTTP 200 with its error text as the content, so check its own flags;
    # completed false with no error means every backup model failed too.
    run = answer.get("hermes") or {}
    gave_up = run.get("completed") is False and not run.get("partial")
    if answer["choices"][0].get("finish_reason") == "error" or run.get("failed") or gave_up:
        print("ERROR", str(run.get("error") or "the model and its backups all refused")[:200])
    else:
        print(answer["choices"][0]["message"]["content"].strip()[:160])
except Exception as e:
    print("ERROR", e)
PY
}

# The bridge is installed before the dashboard, so the dashboard's port still
# looks free at this point. It has to be skipped by name, not by probing.
model_port() {
  local p who
  for p in 8080 8090 8091 8092; do
    [ "$WITH_DASHBOARD" = yes ] && [ "$p" = "$WEB_PORT" ] && continue
    who="$(port_owner "$p")"
    case "$who" in ""|"?") printf '%s' "$p"; return 0 ;; esac
  done
  return 1
}

install_gemini() {
  local port
  port="$(model_port)" || { warn "no free port for the model bridge (tried 8080, 8090 to 8092)"; return 1; }

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
    warn "no model answered. What came back:"
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

hermes_bin() {
  local b
  for b in "$HERMES_DIR/hermes-agent/.hermes/bin/hermes" "$HERMES_HOME_DIR/.local/bin/hermes"; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

# A clean environment, so root's variables (and root's CA paths) do not leak
# into a process that runs as another user. Proxy settings are kept.
hermes_as() {
  local envs=("HOME=$HERMES_HOME_DIR" "HERMES_HOME=$HERMES_DIR" "LANG=C.UTF-8"
              "PATH=/usr/local/bin:/usr/bin:/bin")
  local v
  for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    [ -n "${!v:-}" ] && envs+=("$v=${!v}")
  done
  (cd "$HERMES_HOME_DIR" && sudo -u "$HERMES_USER" env -i "${envs[@]}" "$@")
}

# That one commit only, about 80 MB. Hermes' own installer clones the whole
# history (45,000+ commits) and fetches the files afterwards; on a slow link
# that second fetch died every time. A stalled transfer is dropped after a
# minute and tried again instead of hanging.
hermes_fetch() {
  local dir="$HERMES_DIR/hermes-agent" try
  if [ -d "$dir/.git" ] \
     && [ "$(hermes_as git -C "$dir" rev-parse HEAD 2>/dev/null)" = "$HERMES_COMMIT" ]; then
    return 0
  fi
  hermes_as rm -rf "$dir"
  hermes_as mkdir -p "$HERMES_DIR"
  run hermes_as git init -q "$dir" || return 1
  run hermes_as git -C "$dir" remote add origin "$HERMES_REPO" || return 1
  for try in 1 2 3; do
    note "fetching Hermes $HERMES_COMMIT, try $try of 3"
    if run hermes_as git -C "$dir" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
           fetch --depth 1 origin "$HERMES_COMMIT"; then
      run hermes_as git -C "$dir" checkout -q FETCH_HEAD && return 0
    fi
    [ "$try" = 3 ] || sleep $((try * 10))
  done
  return 1
}

hermes_port() {
  local p who
  for p in 8642 8643 8644 8645; do
    [ "$WITH_DASHBOARD" = yes ] && [ "$p" = "$WEB_PORT" ] && continue
    who="$(port_owner "$p")"
    case "$who" in ""|"?") printf '%s' "$p"; return 0 ;; esac
  done
  return 1
}

# Both files are rewritten whole: Yoru owns them, and a half-edited YAML is
# worse than a fresh one. The empty api_server list is what keeps every tool
# (terminal, files, code, browser) away from anything that talks to the API
# server; disabled_toolsets is the second lock on the dangerous ones.
hermes_write_settings() {  # hermes_write_settings <port> <service-token>
  local env="$HERMES_DIR/.env" conf="$HERMES_DIR/config.yaml" keyvar=""
  case "$HERMES_PROVIDER" in
    gemini)     keyvar="GEMINI_API_KEY" ;;
    openrouter) keyvar="OPENROUTER_API_KEY" ;;
  esac
  mkdir -p "$HERMES_DIR"
  umask 077
  {
    printf '# Written by the Yoru installer. Change the key with: sudo bash install.sh --hermes\n'
    printf 'API_SERVER_ENABLED=true\nAPI_SERVER_HOST=127.0.0.1\n'
    printf 'API_SERVER_PORT=%s\nAPI_SERVER_KEY=%s\n' "$1" "$2"
    [ -n "$keyvar" ] && printf '%s=%s\n' "$keyvar" "$HERMES_KEY"
  } > "$env"
  {
    printf '# Written by the Yoru installer. Hermes only talks for Yoru: tools are off.\n'
    printf 'model:\n  default: "%s"\n  provider: "%s"\n' "$HERMES_MODEL" "$HERMES_PROVIDER"
    case "$HERMES_PROVIDER" in
      openrouter) printf '  base_url: "https://openrouter.ai/api/v1"\n' ;;
      custom)     printf '  base_url: "%s"\n  api_key: "%s"\n' "$HERMES_BASE" "$HERMES_KEY" ;;
    esac
    if [ ${#HERMES_FALLBACKS[@]} -gt 0 ]; then
      printf 'fallback_providers:\n'
      local m
      for m in "${HERMES_FALLBACKS[@]}"; do
        printf '  - provider: "%s"\n    model: "%s"\n' "$HERMES_PROVIDER" "$m"
      done
    fi
    printf 'platform_toolsets:\n  api_server: []\n'
    printf 'agent:\n  disabled_toolsets: [terminal, file, code_execution, browser, delegation, cronjob]\n'
    # A turned-away message goes to the backup model at once. Hermes' default
    # is to keep retrying and then wait up to five rounds of 15 to 60 seconds,
    # longer than the bot (90 s) or the installer check (45 s) waits.
    printf '  api_max_retries: 1\n  auto_recovery_cycles: 0\n'
    # Hermes' side jobs (naming the chat, reviewing it for memory) each cost
    # a model call; a free-tier key only allows a few calls a minute.
    printf 'auxiliary:\n  title_generation:\n    enabled: false\n  background_review:\n    enabled: false\n'
  } > "$conf"
  umask 022
  chown -R "$HERMES_USER": "$HERMES_DIR"
  chmod 600 "$env" "$conf"
}

install_hermes() {
  local bin port token
  have cmd:git  || supply cmd:git git   >/dev/null || { warn "Hermes needs git, and it could not be installed"; return 1; }
  have cmd:curl || supply cmd:curl curl >/dev/null || { warn "Hermes needs curl, and it could not be installed"; return 1; }
  # The node that Hermes downloads links against libatomic, which a minimal
  # Ubuntu does not always have.
  have lib:libatomic.so.1 || supply lib:libatomic.so.1 libatomic1 >/dev/null \
    || { warn "Hermes needs libatomic1, and it could not be installed"; return 1; }

  id "$HERMES_USER" >/dev/null 2>&1 \
    || useradd --system --create-home --home-dir "$HERMES_HOME_DIR" --shell /usr/sbin/nologin "$HERMES_USER" \
    || { warn "could not create the $HERMES_USER user"; return 1; }
  mkdir -p "$HERMES_HOME_DIR"
  chown "$HERMES_USER": "$HERMES_HOME_DIR"; chmod 700 "$HERMES_HOME_DIR"

  # Hermes writes its launcher halfway through its own installer, so the
  # launcher alone does not prove the install finished. This file does.
  local done_file="$HERMES_DIR/yoru-installed"
  if [ "$(cat "$done_file" 2>/dev/null)" != "$HERMES_COMMIT" ] || ! bin="$(hermes_bin)"; then
    busy "downloading Hermes Agent ${HERMES_COMMIT:0:7} - about 80 MB, then its own Python"
    printf '        on a slow link this takes a while; to watch it: sudo tail -f %s\n' "$LOGFILE"
    hermes_fetch || { warn "could not download Hermes from GitHub - see $LOGFILE"; return 1; }
    ok "Hermes Agent ${HERMES_COMMIT:0:7} downloaded"

    # Hermes' own installer, run from the checkout one stage at a time, minus
    # its clone stage. setup and gateway are skipped: they ask questions, and
    # Yoru writes the settings and the service itself.
    busy "letting Hermes install its Python and dependencies"
    local stage
    for stage in prerequisites venv python-deps config products complete; do
      run hermes_as bash "$HERMES_DIR/hermes-agent/scripts/install.sh" --stage "$stage" \
          --commit "$HERMES_COMMIT" --non-interactive --skip-browser --skip-computer-use \
        || { warn "Hermes' installer stopped at '$stage' - see $LOGFILE"; return 1; }
    done
    bin="$(hermes_bin)" || { warn "the Hermes installer did not finish - see $LOGFILE"; return 1; }
    printf '%s\n' "$HERMES_COMMIT" >"$done_file"
  fi
  ok "Hermes Agent ${HERMES_COMMIT:0:7} is on disk"

  # A second run keeps the port and the service token the dashboard already holds.
  port="$(config_get "$HERMES_DIR/.env" API_SERVER_PORT)"
  token="$(config_get "$HERMES_DIR/.env" API_SERVER_KEY)"
  [ -n "$port" ] || port="$(hermes_port)" \
    || { warn "no free port for Hermes (tried 8642 to 8645)"; return 1; }
  [ -n "$token" ] || token="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
  hermes_write_settings "$port" "$token"

  # Proven, not assumed: if the agent can read the key, the split is decoration.
  if sudo -u "$AGENT" test -r "$HERMES_DIR/.env" 2>/dev/null; then
    warn "$AGENT can read Hermes' key file - Hermes was not switched on"
    return 1
  fi

  cat > "$HERMES_UNIT" <<EOF
[Unit]
Description=Hermes Agent for Yoru (API on 127.0.0.1, tools off)
After=network-online.target
Wants=network-online.target

[Service]
User=$HERMES_USER
Group=$HERMES_USER
Environment=HOME=$HERMES_HOME_DIR
Environment=HERMES_HOME=$HERMES_DIR
WorkingDirectory=$HERMES_HOME_DIR
ExecStart=$bin gateway
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$HERMES_HOME_DIR

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable yoru-hermes.service
  run systemctl restart yoru-hermes.service

  local waited=0
  until curl -fsS -m 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1; do
    sleep 3; waited=$((waited + 3))
    [ "$waited" -lt 90 ] && continue
    warn "Hermes did not open port $port - see: journalctl -u yoru-hermes -n 30"
    return 1
  done

  # One real question through Hermes to the provider, so a wrong key shows now.
  local log="$HERMES_DIR/logs/agent.log" seen answer reasons
  seen="$(wc -l < "$log" 2>/dev/null || echo 0)"
  answer="$(model_probe "http://127.0.0.1:$port" "$token" "hermes-agent")"
  note "hermes replied: $answer"
  case "$answer" in
    ERROR*|"")
      # Hermes' reply hides why each model refused; its log says it.
      reasons="$(hermes_reasons "$log" "$seen")"
      [ -n "$reasons" ] || reasons="$answer"
      note "hermes reasons: $reasons"
      if hermes_only_busy "$reasons"; then
        # 503 (busy) and 429 (quota) mean the key and the model name were
        # accepted, so the settings are kept and the bot answers on its own
        # once the provider has room again.
        warn "the key and model are right, but the provider is busy or out of quota right now"
        printf '%s\n' "$reasons" | sed 's/^/        /'
        pending "the Telegram bot answers once the provider has room again - nothing to change"
      else
        warn "Hermes is running but the provider did not answer"
        printf '%s\n' "$reasons" | sed 's/^/        /'
        pending "fix the key or model with: sudo bash install.sh --hermes"
        return 1
      fi ;;
  esac

  config_set "$CONFIG_FILE" HERMES_URL "http://127.0.0.1:$port"
  config_set "$CONFIG_FILE" HERMES_TOKEN "$token"
  config_set "$CONFIG_FILE" AI_MODEL "hermes-agent"
  ok "AI model - Hermes Agent ($HERMES_PROVIDER, $HERMES_MODEL)"
}

# Why each model refused during the check: the last "API call failed" line per
# model that Hermes logged after line <from>, as "model: reason".
hermes_reasons() {  # hermes_reasons <agent.log> <from>
  [ -r "$1" ] || return 0
  tail -n +"$(( $2 + 1 ))" "$1" | grep "API call failed" \
    | sed -n 's/.* model=\([^ ]*\) summary=\(.*\)/\1: \2/p' \
    | awk -F': ' '{last[$1] = substr($0, 1, 110); if (!($1 in seen)) {seen[$1] = 1; order[++n] = $1}}
                  END {for (i = 1; i <= n; i++) print last[order[i]]}'
}

# True when every reason is a 503 (busy) or a 429 (quota used up).
hermes_only_busy() {  # hermes_only_busy <reasons>
  grep -q . <<<"$1" || return 1
  ! grep -v -E 'HTTP (429|503)' <<<"$1" | grep -q .
}

# --hermes: add Hermes to a server that already runs Yoru, or change its key,
# provider or model. Nothing else is touched.
hermes_only() {
  [ -f "$CONFIG_FILE" ] || die "Yoru is not installed here yet - run: sudo bash install.sh"
  [ -r /dev/tty ] || die "--hermes asks for an API key, so it needs a terminal"
  INTERACTIVE=yes
  ensure_dialog
  ask_hermes || die "nothing was changed"
  phase "Hermes Agent"
  install_hermes || die "Hermes is not answering yet - the full story is in $LOGFILE"
  chown root:"$AGENT" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
  if [ ${#PENDING[@]} -gt 0 ]; then
    printf '\n  Settings saved. The Telegram bot answers through Hermes once the provider has room again.\n\n'
  else
    printf '\n  The Telegram bot now answers through Hermes. Ask it anything in your chat.\n\n'
  fi
  exit 0
}

install_model() {
  local existing; existing="$(config_get "$CONFIG_FILE" HERMES_URL)"
  if [ -n "$existing" ]; then
    ok "AI model - already set to $existing"
    return 0
  fi

  case "$MODEL_CHOICE" in
    hermes)
      install_hermes || pending "no AI model yet - retry Hermes with: sudo bash install.sh --hermes"
      ;;
    gemini)
      install_gemini || pending "no AI model yet - run the installer again to retry Gemini"
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
        || pending "no AI model yet - Yoru works without one, add it later in Settings"
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

# A venv counts as ready only with its own pip inside: a failed "python3 -m venv"
# still leaves a python symlink behind, and then pip errors look like missing files.
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
  for f in web/api.py web/dashboard.html web/dashboard.css web/dashboard.js systemd/yoru-web.service; do
    [ -f "$SRC/$f" ] || { warn "$f is missing - dashboard skipped"; return 0; }
  done

  install -d -o root -g root -m 755 "$WEB_DIR" || die "could not create $WEB_DIR"
  install -o root -g root -m 644 "$SRC/web/api.py" "$WEB_DIR/api.py" || die "could not copy api.py"
  for f in dashboard.html dashboard.css dashboard.js; do
    install -o root -g root -m 644 "$SRC/web/$f" "$WEB_DIR/$f" || die "could not copy $f"
  done

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
  # agent exits 0 even when the dashboard is unreachable.
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

# 4. Verify

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

# 5. Report

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
        case " $(config_get "$CONFIG_FILE" PORT_DIIZINKAN) " in
          *" $WEB_PORT "*) : ;;
          *) pending "port $WEB_PORT is not in PORT_DIIZINKAN yet, so K05 will not turn the firewall on" ;;
        esac ;;
    esac
  fi

  if [ -n "$PAIR_CODE" ]; then
    printf '\n  %sConnect Telegram%s - open your bot and send this, once:\n' "$BOLD" "$RESET"
    printf '      /start %s\n' "$PAIR_CODE"
  fi

  printf '\n  Run the daily cycle now (safe controls get applied)\n'
  printf '      sudo -u %s %s/yoru-agent --siklus penjagaan\n' "$AGENT" "$BIN_DIR"
  if [ -f "$HERMES_UNIT" ]; then
    printf '  Change the Hermes API key, provider or model\n'
    printf '      sudo bash install.sh --hermes\n'
  fi
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

# uninstall

uninstall() {
  phase "Removing Yoru"
  run systemctl disable --now yoru-watch.timer
  run systemctl disable --now yoru-web.service
  run systemctl disable --now yoru-model.service
  run systemctl disable --now yoru-hermes.service
  rm -f "$SYSTEMD_DIR/yoru-watch.timer" "$SYSTEMD_DIR/yoru-watch.service" \
        "$SYSTEMD_DIR/yoru-web.service" "$MODEL_UNIT" "$HERMES_UNIT"
  run systemctl daemon-reload
  ok "timer, dashboard, model bridge and Hermes stopped"

  gone() {  # gone <path> <sentence> - only says so when there was something
    [ -e "$1" ] || return 0
    rm -rf "$1" && ok "$2"
  }
  gone "$MODEL_ENV" "model key removed"
  id "$MODEL_USER" >/dev/null 2>&1 && userdel "$MODEL_USER" 2>/dev/null \
    && ok "user $MODEL_USER removed"
  gone "$HERMES_HOME_DIR" "Hermes Agent and its API key removed"
  id "$HERMES_USER" >/dev/null 2>&1 && userdel "$HERMES_USER" 2>/dev/null \
    && ok "user $HERMES_USER removed"
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
    printf '\n  %s%s still holds your tokens (Telegram, dashboard, model).%s\n' "$AMBER" "$CONFIG_FILE" "$RESET"
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
  sudo bash install.sh --hermes         add Hermes Agent, or change its API key
  sudo bash install.sh --uninstall      remove Yoru

Run --check-only first if you want to see what would happen. It reads the
server and writes nothing.
TEXT
}

# main

OWNER=""
INTERACTIVE="yes"
WITH_DASHBOARD="yes"
WEB_HOST="127.0.0.1"
WEB_PORT="8000"
DRY="no"
HERMES_ONLY="no"
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
    --hermes)                       HERMES_ONLY="yes"; shift ;;
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

[ "$HERMES_ONLY" = yes ] && hermes_only

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
