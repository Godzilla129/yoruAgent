#!/bin/bash
# install.sh - the Yoru installer
#
# Usage:
#   sudo bash install.sh                     install everything
#   sudo bash install.sh --pemilik budi      install, naming the server owner
#   sudo bash install.sh --tanpa-tanya       install without any questions
#   sudo bash install.sh --tanpa-dashboard   install without the web dashboard
#   sudo bash install.sh --host 0.0.0.0      open the dashboard to the network
#   sudo bash install.sh --port 8080         change the dashboard port
#   sudo bash install.sh --copot             uninstall
#
# One run installs all of it: dispatcher, catalog, agent, the daily watch
# timer, and the dashboard.
#
# This script is deliberately NOT designed for "curl ... | sudo bash". We are a
# security product; telling people to pipe a script from the internet straight
# into sudo bash is the exact habit we are trying to end. Download it, read it,
# then run it.
#
# Safe to run repeatedly - every step checks the current state first.

set -uo pipefail
umask 022
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

SRC="$(dirname "$(readlink -f "$0")")"

# Read from the dispatcher, not repeated here - the two numbers drifted apart.
VERSION="$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$SRC/bin/yoructl" 2>/dev/null)"
[ -n "$VERSION" ] || VERSION="tidak-terbaca"

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

RESET=$'\033[0m'; GREEN=$'\033[32m'; RED=$'\033[31m'; AMBER=$'\033[33m'; BOLD=$'\033[1m'
step() { printf '\n%s==> %s%s\n' "$BOLD" "$1" "$RESET"; }
ok()   { printf '    %sok%s   %s\n' "$GREEN" "$RESET" "$1"; }
skip() { printf '    %s--%s   %s\n' "$AMBER" "$RESET" "$1"; }
die()  { printf '\n    %sberhenti%s  %s\n\n' "$RED" "$RESET" "$1"; exit 1; }

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
    read -r -s -p "    $label: " answer < /dev/tty; printf '\n'
  else
    read -r -p "    $label: " answer < /dev/tty
  fi
  printf -v "$__var" '%s' "$answer"
}

# --------------------------------------------------------------------- checks
check_environment() {
  step "Memeriksa lingkungan"
  [ "$(id -u)" -eq 0 ] || die "jalankan dengan sudo"

  local os="tidak dikenal"
  [ -r /etc/os-release ] && os=$(. /etc/os-release; printf '%s %s' "$NAME" "$VERSION_ID")
  case "$os" in
    Ubuntu\ 24.04*) ok "sistem operasi: $os" ;;
    Ubuntu*|Debian*) skip "sistem operasi: $os - diuji di Ubuntu 24.04, lanjut dengan hati-hati" ;;
    *) die "sistem operasi $os belum didukung. Yoru diuji di Ubuntu 24.04." ;;
  esac

  # Without flock yoructl still runs, just unlocked - better to know it now.
  local missing=()
  local cmd
  for cmd in sshd systemctl sudo visudo install stat flock python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [ ${#missing[@]} -eq 0 ] || die "perintah yang dibutuhkan tidak ada: ${missing[*]}"
  ok "semua perintah yang dibutuhkan tersedia"

  # "sshd exists" is not "sshd -T can be read", and K01-K05 all rest on sshd -T.
  # /run/sshd is often missing on a freshly booted Ubuntu 24.04: ssh.service
  # creates it, and it only starts once something connects through ssh.socket.
  [ -d /run/sshd ] || { mkdir -p /run/sshd 2>/dev/null && chmod 0755 /run/sshd 2>/dev/null; }
  if sshd -T >/dev/null 2>&1; then
    ok "sshd -T bisa dibaca - K01 sampai K05 punya sumber data"
  else
    skip "sshd -T tidak bisa dibaca: $(sshd -T 2>&1 >/dev/null | head -1)"
    skip "K01 sampai K05 akan berstatus ERROR sampai ini beres"
  fi

  local f
  for f in bin/yoructl bin/yoru.sudoers bin/yoru-watch \
           systemd/yoru-watch.service systemd/yoru-watch.timer \
           examples/yoru.conf.example; do
    [ -f "$SRC/$f" ] || die "berkas $f tidak ada - jalankan skrip ini dari dalam folder repo"
  done
  [ -d "$SRC/catalog" ] || die "folder katalog tidak ada - jalankan skrip ini dari dalam folder repo"
  ok "berkas sumber lengkap"
}

resolve_owner() {
  step "Menentukan pemilik server"
  [ -n "$OWNER" ] || OWNER="${SUDO_USER:-}"
  [ -n "$OWNER" ] || die "tidak bisa menebak pemilik server - pakai: --pemilik <nama-user>"
  getent passwd "$OWNER" >/dev/null || die "pengguna '$OWNER' tidak ada di server ini"
  [ "$OWNER" != "root" ] || die "pemilik tidak boleh root - Yoru butuh akun manusia biasa"
  ok "pemilik server: $OWNER"

  local home; home=$(getent passwd "$OWNER" | cut -d: -f6)
  install_ssh_key "$home"
}

# Accepts a public key, never generates a private one: a private key born on
# the server has already been on the server.
install_ssh_key() {  # install_ssh_key <home-dir>
  local home="$1" file="$1/.ssh/authorized_keys"

  if [ -s "$file" ]; then
    ok "kunci SSH $OWNER ditemukan"
    return 0
  fi

  skip "kunci SSH $OWNER belum ada"
  if [ "$INTERACTIVE" != "ya" ] || [ ! -r /dev/tty ]; then
    skip "K02 akan menolak berjalan sampai kuncinya terpasang"
    return 0
  fi

  cat <<'PETUNJUK'

    K02 mematikan login pakai password. Tanpa kunci SSH yang bekerja, itu
    sama saja menutup satu-satunya pintu masuk Anda sendiri - jadi K02 akan
    menolak berjalan sampai kuncinya ada.

    Kalau belum punya, buat di KOMPUTER ANDA - bukan di server ini:

        ssh-keygen -t ed25519

    Lalu tampilkan bagian publiknya, dan tempel barisnya di bawah:

        Windows  type %USERPROFILE%\.ssh\id_ed25519.pub
        Linux    cat ~/.ssh/id_ed25519.pub
        macOS    cat ~/.ssh/id_ed25519.pub

    Yang ditempel harus yang berakhiran .pub. Isinya satu baris, diawali
    "ssh-ed25519" atau "ssh-rsa". Kami tidak pernah minta kunci privat.

PETUNJUK

  local key
  ask "Tempel kunci publik (kosongkan buat lewati)" key
  printf '\n'

  if [ -z "$key" ]; then
    skip "dilewati - K02 akan menolak berjalan sampai kuncinya terpasang"
    return 0
  fi

  # A key that has crossed a screen and a shell history is no longer secret.
  case "$key" in
    *PRIVATE\ KEY*|*BEGIN\ OPENSSH*|*BEGIN\ RSA*)
      printf '    %sBERHENTI%s  itu kunci PRIVAT, bukan publik.\n\n' "$RED" "$RESET"
      printf '              Kunci itu sekarang sudah lewat layar dan riwayat shell,\n'
      printf '              jadi sudah tidak bisa dianggap rahasia. Buat yang baru di\n'
      printf '              komputer Anda, dan tempel yang berakhiran .pub saja.\n\n'
      die "tidak ada yang ditulis" ;;
  esac

  local tmp; tmp=$(mktemp) || { skip "gagal menyiapkan berkas sementara"; return 0; }
  printf '%s\n' "$key" > "$tmp"

  # ssh-keygen, not a pattern of our own: a key missing one character still
  # looks right, and would only fail at the next login - after K02 is on.
  local fingerprint=""
  if command -v ssh-keygen >/dev/null 2>&1; then
    fingerprint=$(ssh-keygen -l -f "$tmp" 2>/dev/null) || {
      rm -f "$tmp"
      skip "itu bukan kunci publik yang sah - tidak ada yang ditulis"
      skip "pastikan yang ditempel isi berkas .pub, utuh satu baris"
      return 0
    }
  else
    case "$key" in
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-*\ *) : ;;
      *) rm -f "$tmp"; skip "itu bukan kunci publik yang sah - tidak ada yang ditulis"; return 0 ;;
    esac
  fi
  rm -f "$tmp"

  local group; group=$(id -gn "$OWNER")
  install -d -o "$OWNER" -g "$group" -m 700 "$home/.ssh" \
    || { skip "gagal membuat $home/.ssh"; return 0; }

  # Appended, never overwritten - the file may hold someone else's key.
  printf '%s\n' "$key" >> "$file" || { skip "gagal menulis $file"; return 0; }
  chown "$OWNER":"$group" "$file"; chmod 600 "$file"

  ok "kunci ditulis ke $file ($OWNER:$group 600)"
  [ -n "$fingerprint" ] && ok "sidik jari: $fingerprint"

  local addr; addr=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$addr" ] || addr="<alamat-server>"

  printf '\n    %sTES DULU SEBELUM LANJUT.%s Buka terminal BARU - jangan tutup yang ini -\n' "$AMBER" "$RESET"
  printf '    lalu coba masuk pakai kunci itu:\n\n'
  printf '        ssh %s@%s\n\n' "$OWNER" "$addr"
  printf '    Kalau masuk tanpa ditanya password, kuncinya bekerja. Kalau masih\n'
  printf '    ditanya, sesi ini masih hidup untuk membetulkannya.\n\n'

  # A deliberate pause - the lines above would otherwise scroll away.
  local cont
  ask "Tekan Enter kalau sudah dites" cont
}

# -------------------------------------------------------------------- install
create_agent_user() {
  step "Menyiapkan pengguna agent"
  if id "$AGENT" >/dev/null 2>&1; then
    skip "pengguna $AGENT sudah ada"
  else
    useradd --system --shell /usr/sbin/nologin --no-create-home "$AGENT" \
      || die "gagal membuat pengguna $AGENT"
    ok "pengguna $AGENT dibuat"
  fi
  # In the sudo group it would inherit full rights and the sudoers restriction
  # would mean nothing. No pipe, on purpose: under pipefail "id -nG | tr | grep
  # -qx sudo" reads as failure when grep matches and closes the pipe, so the
  # check would PASS exactly when the agent really is in the sudo group.
  local groups=" $(id -nG "$AGENT" 2>/dev/null) "
  case "$groups" in
    *" sudo "*) die "$AGENT ada di grup sudo - itu membatalkan seluruh pembatasan. Keluarkan dulu: gpasswd -d $AGENT sudo" ;;
  esac
  ok "$AGENT bukan anggota grup sudo"
}

create_dirs() {
  step "Menyiapkan folder"
  install -d -o root -g root -m 755 "$BIN_DIR" "$CATALOG_DIR" "$ETC_DIR" \
    || die "gagal membuat folder"
  ok "$BIN_DIR"
  ok "$CATALOG_DIR"
  ok "$ETC_DIR"

  # 2750: setgid, so logs root writes here inherit the yoru-agent group and the
  # dashboard - which runs as the agent - can READ the trail. No group write
  # bit, so the agent still cannot edit or delete its own record.
  install -d -o root -g "$AGENT" -m 2750 "$LOG_DIR" || die "gagal membuat $LOG_DIR"
  # Older installs wrote root:root, and setgid does not apply retroactively.
  chgrp "$AGENT" "$LOG_DIR"/*.log 2>/dev/null
  ok "$LOG_DIR (root:$AGENT 2750 - agent boleh baca, tidak boleh menulis)"

  # The only directory the agent may write; $LOG_DIR stays root's.
  install -d -o "$AGENT" -g "$AGENT" -m 750 "$DATA_DIR" "$DATA_DIR/riwayat" \
    || die "gagal membuat $DATA_DIR"
  # If the agent was ever run under sudo, laporan-terakhir.json is root-owned
  # and the daily cycle silently cannot overwrite it.
  chown -R "$AGENT":"$AGENT" "$DATA_DIR" 2>/dev/null
  ok "$DATA_DIR dan $DATA_DIR/riwayat ($AGENT:$AGENT 750)"

  # The agent may change the server, but not the record of how it looked before.
  install -d -o root -g root -m 700 "$BASELINE_DIR" || die "gagal membuat $BASELINE_DIR"
  ok "$BASELINE_DIR (root:root 700 - agent tidak bisa menyentuh)"
}

# Before 0.1.3 the action log was free text, now one JSON object per line. Mixed
# in one file the dashboard's parser breaks, so old lines are moved aside.
migrate_old_log() {
  local file="$LOG_DIR/tindakan.log" dest tmp text_lines json_lines
  [ -s "$file" ] || return 0

  # Sorted per line, not moved wholesale: moving the whole file carries off the
  # JSON lines too, leaving the combined log shorter than the per-control logs.
  text_lines=$(grep -cv '^{' "$file" 2>/dev/null) || text_lines=0
  [ "${text_lines:-0}" -gt 0 ] || return 0

  dest="$file.teks-lama.$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp) || return 0

  grep -v '^{' "$file" > "$dest" 2>/dev/null
  grep    '^{' "$file" > "$tmp"  2>/dev/null
  json_lines=$(wc -l < "$tmp" 2>/dev/null) || json_lines=0

  cat "$tmp" > "$file"
  rm -f "$tmp"
  chmod 640 "$file" "$dest" 2>/dev/null

  skip "$text_lines baris format teks lama dipindah ke $(basename "$dest")"
  skip "$json_lines baris JSON tetap di tindakan.log"
}

install_dispatcher() {
  step "Memasang dispatcher"
  migrate_old_log
  install -o root -g root -m 755 "$SRC/bin/yoructl" "$BIN_DIR/yoructl" \
    || die "gagal menyalin dispatcher"

  if [ -f "$SRC/bin/yoru-agent" ]; then
    python3 -c 'import yaml' 2>/dev/null || {
      skip "python3-yaml belum ada, memasang (dipakai agent buat baca katalog)"
      DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=60 \
        install python3-yaml >/dev/null 2>&1 \
        || skip "gagal memasang python3-yaml - agent tidak akan bisa baca katalog"
    }
    install -o root -g root -m 755 "$SRC/bin/yoru-agent" "$BIN_DIR/yoru-agent" \
      || die "gagal menyalin agent"
    ok "$BIN_DIR/yoru-agent (root:root 755)"
  fi
  ok "$BIN_DIR/yoructl (root:root 755)"

  printf '%s\n' "$OWNER" > "$ETC_DIR/pemilik"
  chown root:root "$ETC_DIR/pemilik"; chmod 644 "$ETC_DIR/pemilik"
  ok "$ETC_DIR/pemilik berisi '$OWNER'"
}

install_catalog() {
  step "Memasang katalog"
  local n=0 f
  for f in "$SRC"/catalog/*.yaml; do
    [ -f "$f" ] || continue
    install -o root -g root -m 644 "$f" "$CATALOG_DIR/" || die "gagal menyalin $(basename "$f")"
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || die "tidak ada berkas katalog yang tersalin"
  # root-owned: a catalog the agent could edit is the agent rewriting its rules.
  ok "$n berkas katalog terpasang, hanya bisa dibaca agent"
}

install_sudoers() {
  step "Memasang aturan sudoers"
  local tmp=/tmp/yoru-sudoers.$$
  cp "$SRC/bin/yoru.sudoers" "$tmp" || die "gagal menyiapkan berkas sudoers"
  # Checked first - a broken sudoers file kills sudo until recovery mode.
  if ! visudo -c -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"; die "berkas sudoers tidak lolos pemeriksaan - tidak ada yang dipasang"
  fi
  ok "berkas sudoers lolos pemeriksaan visudo"
  install -o root -g root -m 0440 "$tmp" "$SUDOERS" || { rm -f "$tmp"; die "gagal memasang sudoers"; }
  rm -f "$tmp"
  sudo -n -l >/dev/null 2>&1 || true
  visudo -c >/dev/null 2>&1 || die "sudoers keseluruhan jadi tidak valid - hapus $SUDOERS sekarang juga"
  ok "$SUDOERS terpasang (root:root 0440)"
}

write_config() {
  step "Menyiapkan konfigurasi"

  # Re-running the installer is normal; losing an API key to it is not.
  if [ -f "$CONFIG_FILE" ]; then
    chown root:"$AGENT" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
    skip "$CONFIG_FILE sudah ada - tidak ditimpa, isinya dibiarkan"
    ok "izin dipastikan (root:$AGENT 640)"
    return 0
  fi

  install -o root -g "$AGENT" -m 640 "$SRC/examples/yoru.conf.example" "$CONFIG_FILE" \
    || die "gagal membuat $CONFIG_FILE"
  ok "$CONFIG_FILE dibuat (root:$AGENT 640 - agent boleh baca, pengguna lain tidak)"

  if [ "$INTERACTIVE" != "ya" ] || [ ! -r /dev/tty ]; then
    skip "tanpa tanya jawab - isi $CONFIG_FILE sendiri sebelum Yoru dipakai"
    return 0
  fi

  # No model API key here: Hermes holds it, so yoru.conf - the one file the
  # agent can read - never holds a spendable credential.
  printf '\n    Dua pertanyaan, boleh dikosongkan dan diisi belakangan -\n'
  printf '    lewat dashboard, atau dengan menyunting %s\n\n' "$CONFIG_FILE"

  local token url
  ask "Token bot Telegram (kosongkan kalau tidak pakai)" token secret
  ask "Alamat dashboard   (kosongkan kalau belum ada)  " url

  [ -n "$token" ]  && config_set "$CONFIG_FILE" TELEGRAM_TOKEN "$token"
  [ -n "$url" ]    && config_set "$CONFIG_FILE" DASHBOARD_URL  "$url"

  chown root:"$AGENT" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
  printf '\n'

  if [ -n "$token" ]; then ok "bot Telegram disetel"
  else skip "Telegram tidak dipakai"; fi
  if [ -n "$url" ]; then ok "dashboard: $url"
  else skip "dashboard tidak dipakai - laporan hanya ditulis ke $DATA_DIR"; fi
}

# ------------------------------------------------------------------- model AI
# Yoru bicara ke server model lewat bentuk OpenAI di 127.0.0.1. Kunci API tidak
# pernah masuk ke yoru.conf - berkas itu satu-satunya yang boleh dibaca agent.
MODEL_USER="yoru-model"
MODEL_ENV="/etc/yoru/model.env"
MODEL_BIN="$BIN_DIR/yoru-model-proxy"
MODEL_UNIT="/etc/systemd/system/yoru-model.service"

hermes_upstreams() {
  command -v hermes >/dev/null 2>&1 || return 1
  hermes proxy providers 2>/dev/null \
    | sed -n 's/^ *\([a-z][a-z0-9-]*\) *—.*/\1/p' | tr '\n' ' ' | sed 's/ *$//'
}

install_gemini_connector() {  # install_gemini_connector <key> <model>
  local key="$1" model="$2" port=8080 busy

  busy="$(ss -tlnH "sport = :8080" 2>/dev/null || true)"
  [ -n "$busy" ] && port=8090

  id "$MODEL_USER" >/dev/null 2>&1 \
    || useradd --system --no-create-home --shell /usr/sbin/nologin "$MODEL_USER" \
    || { skip "gagal membuat pengguna $MODEL_USER"; return 1; }

  umask 077
  printf 'GEMINI_API_KEY=%s\nGEMINI_MODEL=%s\n' "$key" "$model" > "$MODEL_ENV"
  umask 022
  chown root:"$MODEL_USER" "$MODEL_ENV"; chmod 0640 "$MODEL_ENV"
  ok "kunci di $MODEL_ENV (root:$MODEL_USER 640)"

  if sudo -u "$AGENT" test -r "$MODEL_ENV" 2>/dev/null; then
    skip "$AGENT masih bisa membaca kunci - dibatalkan"
    rm -f "$MODEL_ENV"; return 1
  fi
  ok "$AGENT tidak bisa membaca kunci"

  install -o root -g root -m 755 "$SRC/bin/yoru-model-proxy" "$MODEL_BIN" \
    || { skip "gagal menyalin yoru-model-proxy"; return 1; }

  # Diuji sebelum layanannya dinyalakan. Nama model bisa basi tanpa
  # pemberitahuan, jadi penghubungnya juga yang memilih model yang masih hidup.
  local report way picked
  report="$(GEMINI_API_KEY="$key" GEMINI_MODEL="$model" python3 "$MODEL_BIN" --diagnose 2>&1)"
  way="$(printf '%s' "$report" | sed -n 's/.*GEMINI_WAY=\([a-z-]*\).*/\1/p' | head -1)"
  picked="$(printf '%s' "$report" | sed -n 's/.*GEMINI_MODEL=\([A-Za-z0-9._-]*\).*/\1/p' | head -1)"

  if [ -z "$way" ]; then
    skip "Gemini menolak. Ini jawabannya apa adanya:"
    printf '%s\n' "$report" | sed 's/^/      /'
    return 1
  fi

  [ -n "$picked" ] && [ "$picked" != "$model" ] \
    && skip "\"$model\" ditolak Google - dipakai \"$picked\"" \
    && model="$picked" \
    && sed -i "s|^GEMINI_MODEL=.*|GEMINI_MODEL=$model|" "$MODEL_ENV"

  ok "cara yang dipakai: $way, model: $model"
  printf 'GEMINI_WAY=%s\n' "$way" >> "$MODEL_ENV"

  cat > "$MODEL_UNIT" <<EOF
[Unit]
Description=Penghubung Yoru ke model Gemini
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
  systemctl daemon-reload
  systemctl enable --now yoru-model.service >/dev/null 2>&1 || true
  sleep 2
  systemctl is-active --quiet yoru-model.service \
    || { skip "layanan yoru-model tidak hidup - lihat: journalctl -u yoru-model -n 20"; return 1; }
  ok "penghubung hidup di 127.0.0.1:$port"

  local answer
  answer="$(model_probe "http://127.0.0.1:$port" "" "$model")"
  case "$answer" in
    ERROR*|"")
      skip "penghubung hidup tapi belum menjawab: $answer"
      skip "  lihat: journalctl -u yoru-model -n 20 --no-pager"
      return 1 ;;
    *) ok "model menjawab: $answer" ;;
  esac

  config_set "$CONFIG_FILE" HERMES_URL "http://127.0.0.1:$port"
  ok "HERMES_URL = http://127.0.0.1:$port"
}

model_probe() {  # model_probe <url> <token> <model>
  python3 - "$1" "$2" "$3" <<'EOF'
import json, sys, urllib.request
url, token, model = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3] or "hermes"
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
EOF
}

setup_model() {
  step "Model AI"

  local existing; existing="$(config_get "$CONFIG_FILE" HERMES_URL)"
  if [ -n "$existing" ]; then
    ok "sudah disetel sebelumnya: $existing"
    return 0
  fi

  local upstreams=""
  if command -v hermes >/dev/null 2>&1; then
    upstreams="$(hermes_upstreams || true)"
    ok "Hermes terpasang di server ini"
    [ -n "$upstreams" ] && skip "penyedia yang dilayani hermes proxy: $upstreams"
  else
    skip "Hermes tidak terpasang - tidak masalah"
  fi

  if [ "$INTERACTIVE" != "ya" ] || [ ! -r /dev/tty ]; then
    skip "tanpa tanya jawab - setel belakangan lewat dashboard"
    return 0
  fi

  printf '\n    Yoru bisa jalan tanpa model. Kalimat laporannya diambil dari\n'
  printf '    katalog - lebih kaku, tapi tetap benar.\n\n'
  printf '      1) Google Gemini - tempel kunci API\n'
  if [ -n "$upstreams" ]; then
    printf '      2) Lewat hermes proxy (%s) - perlu login dulu\n' "$upstreams"
  fi
  printf '      3) Lewati\n\n'

  local pick; ask "Pilih 1/2/3 (kosong = lewati)" pick
  case "$pick" in
    1)
      local key model
      # Dua bentuk beredar: AIza... yang lama dan AQ... yang baru. Keduanya sah.
      ask "Kunci API Gemini (AIza... atau AQ...)" key secret
      key="${key#GEMINI_API_KEY=}"
      key="$(printf '%s' "$key" | tr -d '\r\n "')"
      [ -n "$key" ] || { skip "kunci kosong - dilewati"; return 0; }
      case "$key" in
        AIza*|AQ.*) ;;
        *) skip "bentuk kunci tidak dikenal - kalau salah, ketahuan pas dites" ;;
      esac
      printf '    Kosongkan saja; penghubungnya memilih model yang masih hidup.\n'
      ask "Nama model (ENTER saja = gemini-flash-latest)" model
      model="$(printf '%s' "$model" | tr -d '\r\n ')"
      [ -n "$model" ] || model="gemini-flash-latest"
      install_gemini_connector "$key" "$model" || skip "model tidak jadi disetel"
      ;;
    2)
      [ -n "$upstreams" ] || { skip "hermes proxy tidak tersedia"; return 0; }
      local prov port token
      ask "Penyedia ($upstreams)" prov
      [ -n "$prov" ] || prov="nous"
      ask "Port hermes proxy (kosong = 8645)" port
      [ -n "$port" ] || port=8645
      token="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' )"
      config_set "$CONFIG_FILE" HERMES_URL   "http://127.0.0.1:$port"
      config_set "$CONFIG_FILE" HERMES_TOKEN "$token"
      ok "HERMES_URL = http://127.0.0.1:$port"
      skip "hermes proxy perlu login dulu, lalu jalankan:"
      skip "  hermes proxy start --provider $prov --port $port"
      ;;
    *)
      skip "tanpa model - laporan tetap lengkap, kalimatnya dari katalog"
      ;;
  esac

  chown root:"$AGENT" "$CONFIG_FILE"; chmod 640 "$CONFIG_FILE"
}

install_timer() {
  step "Memasang siklus penjagaan harian"

  install -o root -g root -m 755 "$SRC/bin/yoru-watch" "$BIN_DIR/yoru-watch" \
    || die "gagal menyalin yoru-watch"
  ok "$BIN_DIR/yoru-watch (root:root 755)"

  local at tz
  at="$(config_get "$CONFIG_FILE" JAM_PENJAGAAN)"
  tz="$(config_get "$CONFIG_FILE" ZONA_WAKTU)"
  [ -n "$at" ] || at="03:17"
  [ -n "$tz" ] || tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
  [ -n "$tz" ] || tz="UTC"

  # A timer that fails to load does not shout - it simply never runs.
  case "$at" in
    [0-2][0-9]:[0-5][0-9]) : ;;
    *) die "JAM_PENJAGAAN di $CONFIG_FILE harus berbentuk HH:MM, isinya sekarang '$at'" ;;
  esac

  install -o root -g root -m 644 "$SRC/systemd/yoru-watch.service" \
    "$SYSTEMD_DIR/yoru-watch.service" || die "gagal memasang unit service"

  sed -e "s|@JAM@|$at|" -e "s|@ZONA@|$tz|" \
      "$SRC/systemd/yoru-watch.timer" > "$SYSTEMD_DIR/yoru-watch.timer" \
    || die "gagal memasang unit timer"
  chown root:root "$SYSTEMD_DIR/yoru-watch.timer"
  chmod 644 "$SYSTEMD_DIR/yoru-watch.timer"

  # One typo in "Asia/Jakarta" and systemd rejects the timer silently.
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "*-*-* $at:00 $tz" >/dev/null 2>&1 \
      || die "jadwal '*-*-* $at:00 $tz' ditolak systemd - periksa ZONA_WAKTU di $CONFIG_FILE"
    ok "jadwal diterima systemd: setiap hari $at $tz"
  else
    skip "systemd-analyze tidak ada - jadwal '$at $tz' dipasang tanpa diperiksa dulu"
  fi

  systemctl daemon-reload || die "systemctl daemon-reload gagal"
  systemctl enable --now yoru-watch.timer >/dev/null 2>&1 \
    || die "gagal menyalakan timer penjagaan"

  systemctl is-active yoru-watch.timer >/dev/null 2>&1 \
    || die "timer terpasang tapi tidak aktif - periksa: systemctl status yoru-watch.timer"
  ok "timer aktif"
}

# ------------------------------------------------------------------ dashboard
# The dashboard runs as yoru-agent: its buttons go through the same sudo door.
# A venv is only usable once pip is inside it. Checking bin/python is not
# enough: a failed "python3 -m venv" still leaves the directory behind with a
# python symlink and no pip, and the next run then reports a missing file
# instead of the missing package.
venv_ready() {
  [ -x "$WEB_DIR/venv/bin/python" ] || return 1
  # pip must be the venv's own. A half-built venv can still reach the system
  # pip, which would then install into /usr and look like it worked.
  "$WEB_DIR/venv/bin/python" -m pip --version 2>/dev/null \
    | grep -q "$WEB_DIR/venv"
}

build_venv() {
  venv_ready && return 0

  local log; log="$(mktemp)"
  rm -rf "$WEB_DIR/venv"
  python3 -m venv "$WEB_DIR/venv" >"$log" 2>&1
  venv_ready && { rm -f "$log"; ok "venv siap di $WEB_DIR/venv"; return 0; }

  # Ubuntu ships venv and ensurepip in separate packages, and the versioned
  # name is the one that actually exists on 24.04.
  skip "venv belum lengkap, memasang paketnya"
  local ver; ver="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=60 \
    install "python${ver}-venv" python3-venv python3-pip >>"$log" 2>&1

  rm -rf "$WEB_DIR/venv"
  python3 -m venv "$WEB_DIR/venv" >>"$log" 2>&1
  venv_ready && { rm -f "$log"; ok "venv siap di $WEB_DIR/venv"; return 0; }

  # Last resort: a venv without pip, then pip put in by hand.
  python3 -m venv --without-pip "$WEB_DIR/venv" >>"$log" 2>&1
  "$WEB_DIR/venv/bin/python" -m ensurepip --upgrade >>"$log" 2>&1
  venv_ready && { rm -f "$log"; ok "venv siap di $WEB_DIR/venv (lewat ensurepip)"; return 0; }

  skip "venv tidak bisa dibuat. Kata sistem:"
  tail -n 8 "$log" | sed 's/^/          /'
  rm -f "$log"
  skip "dashboard tidak dipasang, sisanya tetap jalan"
  skip "biasanya beres dengan: sudo apt-get install -y python${ver}-venv python3-pip"
  return 1
}

install_dashboard() {
  step "Memasang dashboard"

  if [ "$WITH_DASHBOARD" != "ya" ]; then
    skip "dilewati atas permintaan (--tanpa-dashboard)"
    return 0
  fi
  local f
  for f in web/api.py web/dashboard.html systemd/yoru-web.service; do
    [ -f "$SRC/$f" ] || { skip "$f tidak ada - dashboard dilewati"; return 0; }
  done

  install -d -o root -g root -m 755 "$WEB_DIR" || die "gagal membuat $WEB_DIR"
  install -o root -g root -m 644 "$SRC/web/api.py" "$WEB_DIR/api.py" \
    || die "gagal menyalin api.py"
  install -o root -g root -m 644 "$SRC/web/dashboard.html" "$WEB_DIR/dashboard.html" \
    || die "gagal menyalin dashboard.html"
  ok "$WEB_DIR (root:root - agent menjalankannya, tapi tidak bisa mengubahnya)"

  # A venv, not pip into the system - other tools share those packages.
  build_venv || return 0

  # pip's own last words, not our guess about them: "no internet" and "no disk
  # space" look identical from out here, and only one of them is worth waiting on.
  local pip_log=""
  if ! "$WEB_DIR/venv/bin/python" -c 'import fastapi, uvicorn' 2>/dev/null; then
    printf '    ..   mengunduh fastapi dan uvicorn, ini yang paling lama\n'
    pip_log="$(mktemp)"
    "$WEB_DIR/venv/bin/python" -m pip install --disable-pip-version-check \
      fastapi uvicorn >"$pip_log" 2>&1
  fi
  if ! "$WEB_DIR/venv/bin/python" -c 'import fastapi, uvicorn' 2>/dev/null; then
    skip "fastapi/uvicorn gagal dipasang. Kata pip:"
    [ -s "$pip_log" ] && tail -n 8 "$pip_log" | sed 's/^/          /'
    rm -f "$pip_log"
    skip "sisanya tetap terpasang. Ulangi installer setelah itu beres."
    return 0
  fi
  rm -f "$pip_log"
  ok "fastapi dan uvicorn siap di $WEB_DIR/venv"

  # No token from 127.0.0.1 - whoever reaches it already has the server. Opened
  # to the network the buttons are anyone's, so the token is generated here.
  local token; token="$(config_get "$CONFIG_FILE" DASHBOARD_TOKEN)"
  case "$WEB_HOST" in
    127.0.0.1|localhost|::1) : ;;
    *) if [ -z "$token" ]; then
         token="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
         config_set "$CONFIG_FILE" DASHBOARD_TOKEN "$token"
         skip "dashboard dibuka ke $WEB_HOST - token dibuatkan otomatis"
       fi ;;
  esac

  if [ -n "$token" ]; then
    printf 'YORU_TOKEN=%s\n' "$token" > "$WEB_ENV"
    chown root:"$AGENT" "$WEB_ENV"; chmod 640 "$WEB_ENV"
    ok "$WEB_ENV (root:$AGENT 640 - token tidak ikut muncul di 'ps')"
  else
    rm -f "$WEB_ENV"
  fi

  sed -e "s|@HOST@|$WEB_HOST|" -e "s|@PORT@|$WEB_PORT|" \
      "$SRC/systemd/yoru-web.service" > "$SYSTEMD_DIR/yoru-web.service" \
    || die "gagal memasang unit dashboard"
  chown root:root "$SYSTEMD_DIR/yoru-web.service"
  chmod 644 "$SYSTEMD_DIR/yoru-web.service"

  systemctl daemon-reload || die "systemctl daemon-reload gagal"
  systemctl enable yoru-web.service >/dev/null 2>&1
  systemctl restart yoru-web.service >/dev/null 2>&1 \
    || die "dashboard gagal dinyalakan - lihat: journalctl -u yoru-web -n 30"

  # Waited on until it really answers, not just until systemd says "active": a
  # process that dies a second after starting counts as active for that second.
  if python3 - "$WEB_PORT" <<'PY'
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
  then :
  else die "dashboard tidak menjawab dalam 30 detik - lihat: journalctl -u yoru-web -n 30"
  fi

  # Something answering on the port is not proof WE answered: if the port was
  # already taken, our unit dies while the other program keeps replying.
  systemctl is-active yoru-web.service >/dev/null 2>&1 \
    || die "port $WEB_PORT sudah dipakai program lain, bukan Yoru. Pilih port lain: --port <angka>"
  ok "dashboard menjawab di http://$WEB_HOST:$WEB_PORT"

  # The agent uses 127.0.0.1 even when the dashboard is open to the network.
  local url; url="$(config_get "$CONFIG_FILE" DASHBOARD_URL)"
  if [ -z "$url" ]; then
    config_set "$CONFIG_FILE" DASHBOARD_URL "http://127.0.0.1:$WEB_PORT"
    ok "agent diarahkan ke http://127.0.0.1:$WEB_PORT"
  elif [ "${url%/}" = "http://127.0.0.1:$WEB_PORT" ]; then
    ok "agent sudah diarahkan ke http://127.0.0.1:$WEB_PORT"
  else
    # Not overwritten - it may point at another dashboard on purpose.
    skip "DASHBOARD_URL di $CONFIG_FILE masih '$url', bukan port yang baru dipasang"
    skip "laporan tidak akan masuk ke dashboard ini sampai barisnya diganti jadi"
    skip "  DASHBOARD_URL=\"http://127.0.0.1:$WEB_PORT\""
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
  [ "$WITH_DASHBOARD" = "ya" ] || return 0
  [ -x "$BIN_DIR/yoru-agent" ] || return 0
  systemctl is-active yoru-web.service >/dev/null 2>&1 || return 0

  step "Memeriksa server sekali, biar dashboard tidak kosong"
  printf '    ..   memeriksa 10 kontrol, tidak ada yang diubah\n'

  local before; before="$(count_reports)"
  timeout 300 sudo -u "$AGENT" env HOME="$DATA_DIR" "$BIN_DIR/yoru-agent" \
    --siklus penjagaan --kering --konfigurasi "$CONFIG_FILE" >/dev/null 2>&1

  # Counted before and after: a reinstall always finds older reports, and the
  # exit code proves nothing either - the agent exits 0 even when the dashboard
  # is unreachable.
  if [ "$(count_reports)" -gt "$before" ]
    then ok "laporan pertama sudah masuk ke dashboard"
  else skip "dashboard masih kosong - laporannya belum sampai"
       skip "jalankan manual dan baca pesannya:"
       skip "  sudo -u $AGENT $BIN_DIR/yoru-agent --siklus penjagaan --kering"
  fi
}

# ------------------------------------------------------------------ self test
self_test() {
  step "Menguji hasil pemasangan"
  local out

  out=$(sudo -u "$AGENT" sudo -n "$BIN_DIR/yoructl" K01 periksa 2>&1)
  case "$out" in
    *'"id":"K01"'*) ok "agent bisa meminta tindakan yang sah" ;;
    *) die "agent tidak bisa memanggil dispatcher. Keluaran: $out" ;;
  esac

  if sudo -u "$AGENT" sudo -n id >/dev/null 2>&1
    then die "BAHAYA: agent bisa menjalankan perintah lain. Pembatasan sudoers tidak bekerja."
    else ok "agent ditolak saat mencoba perintah lain"
  fi

  chmod 777 "$BIN_DIR/yoructl"
  out=$(sudo -u "$AGENT" sudo -n "$BIN_DIR/yoructl" K01 periksa 2>&1)
  chmod 755 "$BIN_DIR/yoructl"
  case "$out" in
    *DITOLAK*) ok "dispatcher menolak jalan saat dirinya sendiri bisa ditulis" ;;
    *) die "dispatcher tetap jalan padahal izinnya longgar - pemeriksaan diri tidak bekerja" ;;
  esac

  out=$(sudo -u "$AGENT" sudo -n "$BIN_DIR/yoructl" K01 periksa 2>&1)
  case "$out" in
    *'"id":"K01"'*) ok "dispatcher kembali normal setelah izin dipulihkan" ;;
    *) die "dispatcher tidak pulih setelah chmod 755" ;;
  esac

  # If yoru-watch ran as root the sudoers restriction would be decorative.
  out=$("$BIN_DIR/yoru-watch" 2>&1)
  case "$out" in
    *"harus berjalan sebagai yoru-agent"*) ok "penjagaan menolak berjalan sebagai root" ;;
    *) die "penjagaan tidak menolak saat dijalankan root. Keluaran: $out" ;;
  esac

  local timers; timers=$(systemctl list-timers --all --no-pager 2>/dev/null)
  case "$timers" in
    *yoru-watch*) ok "timer penjagaan terdaftar di systemd" ;;
    *) die "timer tidak muncul di daftar systemd" ;;
  esac
}

# ------------------------------------------------------------------ uninstall
uninstall() {
  step "Mencopot Yoru"

  systemctl disable --now yoru-watch.timer >/dev/null 2>&1
  systemctl disable --now yoru-web.service >/dev/null 2>&1
  systemctl disable --now yoru-model.service >/dev/null 2>&1
  rm -f "$SYSTEMD_DIR/yoru-watch.timer" "$SYSTEMD_DIR/yoru-watch.service" \
        "$SYSTEMD_DIR/yoru-web.service" "$SYSTEMD_DIR/yoru-model.service"
  systemctl daemon-reload >/dev/null 2>&1
  ok "timer penjagaan, dashboard, dan penghubung model dihentikan"

  if [ -f "$MODEL_ENV" ]; then
    rm -f "$MODEL_ENV" && ok "$MODEL_ENV dihapus - kunci model ikut hilang"
  fi
  id "$MODEL_USER" >/dev/null 2>&1 && userdel "$MODEL_USER" 2>/dev/null \
    && ok "pengguna $MODEL_USER dihapus"

  rm -f "$WEB_ENV"          && ok "$WEB_ENV dihapus"
  rm -f "$SUDOERS"          && ok "aturan sudoers dihapus"
  rm -rf /opt/yoru          && ok "/opt/yoru dihapus"
  rm -rf /usr/share/yoru    && ok "/usr/share/yoru dihapus"
  if id "$AGENT" >/dev/null 2>&1; then
    if userdel "$AGENT" 2>/dev/null
      then ok "pengguna $AGENT dihapus"
      else skip "pengguna $AGENT tidak bisa dihapus - biasanya masih ada prosesnya"
           skip "lihat dulu: pgrep -u $AGENT -a   lalu: sudo userdel $AGENT"
    fi
  fi
  skip "$LOG_DIR, $ETC_DIR, $DATA_DIR dan $BASELINE_DIR sengaja DIBIARKAN - itu catatan, laporan, dan rekaman keadaan asal"

  # Not ours to delete uncalled for, but not ours to stay quiet about either.
  if [ -f "$CONFIG_FILE" ]; then
    printf '\n    %sPERHATIAN%s  %s masih ada, dan di dalamnya ada kunci API\n' "$AMBER" "$RESET" "$CONFIG_FILE"
    printf '              serta token bot. Sengaja tidak dihapus - itu berkas Anda.\n'
    printf '              Kalau server ini mau dilepas, dijual, atau dikembalikan ke\n'
    printf '              penyedia, hapus sendiri:  sudo rm %s\n' "$CONFIG_FILE"
  fi

  printf '\n    Kontrol yang sudah diterapkan TIDAK dikembalikan.\n'
  printf '    Untuk mengembalikan, jalankan "kembalikan" per kontrol sebelum mencopot.\n\n'
  exit 0
}

# ----------------------------------------------------------------------- main
OWNER=""
INTERACTIVE="ya"
WITH_DASHBOARD="ya"
WEB_HOST="127.0.0.1"
WEB_PORT="8000"
while [ $# -gt 0 ]; do
  case "$1" in
    --pemilik)         OWNER="${2-}"; shift 2 ;;
    --tanpa-tanya)     INTERACTIVE="tidak"; shift ;;
    --tanpa-dashboard) WITH_DASHBOARD="tidak"; shift ;;
    --host)            WEB_HOST="${2-}"; shift 2 ;;
    --port)            WEB_PORT="${2-}"; shift 2 ;;
    --copot)           [ "$(id -u)" -eq 0 ] || die "jalankan dengan sudo"; uninstall ;;
    -h|--help)         sed -n '2,21p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "argumen tidak dikenal: $1" ;;
  esac
done

[ -n "$WEB_HOST" ] || die "--host tidak boleh kosong"
case "$WEB_PORT" in
  ''|*[!0-9]*) die "--port harus angka, isinya '$WEB_PORT'" ;;
esac
[ "$WEB_PORT" -ge 1 ] && [ "$WEB_PORT" -le 65535 ] || die "--port di luar jangkauan: $WEB_PORT"

printf '\n%sYoru %s%s  -  pemasangan\n' "$BOLD" "$VERSION" "$RESET"

check_environment
resolve_owner
create_agent_user
create_dirs
install_dispatcher
install_catalog
install_sudoers
write_config
setup_model
install_timer
install_dashboard
self_test
seed_dashboard

INSTALLED_AT="$(config_get "$CONFIG_FILE" JAM_PENJAGAAN)"; [ -n "$INSTALLED_AT" ] || INSTALLED_AT="03:17"
INSTALLED_TZ="$(config_get "$CONFIG_FILE" ZONA_WAKTU)";    [ -n "$INSTALLED_TZ" ] || INSTALLED_TZ="UTC"

if systemctl is-active yoru-web.service >/dev/null 2>&1
  then WEB_ADDR="http://$WEB_HOST:$WEB_PORT"
  else WEB_ADDR="tidak dipasang"
fi

cat <<SELESAI

${BOLD}Selesai.${RESET}

  Dispatcher   $BIN_DIR/yoructl
  Agent        $BIN_DIR/yoru-agent
  Katalog      $CATALOG_DIR
  Konfigurasi  $CONFIG_FILE   (root:$AGENT 640)
  Pemilik      $OWNER
  Penjagaan    setiap hari $INSTALLED_AT $INSTALLED_TZ
  Dashboard    $WEB_ADDR
  Catatan      $LOG_DIR/tindakan.log   (root, agent tidak bisa menulis)
  Laporan      $DATA_DIR/laporan-terakhir.json   (ditulis agent)
  Keadaan asal $BASELINE_DIR/<kontrol>/   (direkam sebelum terapkan pertama)

  Coba sendiri:
    sudo -u $AGENT sudo -n $BIN_DIR/yoructl K05 periksa

  Jalankan siklus perbaikan sekarang:
    sudo -u $AGENT $BIN_DIR/yoru-agent --siklus perbaikan

  Lihat jadwal berikutnya:
    systemctl list-timers yoru-watch.timer

  Kalau dashboard bermasalah:
    journalctl -u yoru-web -n 30

  Mencopot:
    sudo bash install.sh --copot

SELESAI

case "$WEB_HOST" in
  127.0.0.1|localhost|::1) : ;;
  *)
    if systemctl is-active yoru-web.service >/dev/null 2>&1; then
      INSTALLED_TOKEN="$(config_get "$CONFIG_FILE" DASHBOARD_TOKEN)"
      printf '  %sDashboard terbuka ke jaringan.%s\n' "$AMBER" "$RESET"
      printf '  Token untuk menekan tombolnya dari komputer lain:\n\n'
      printf '      %s\n\n' "${INSTALLED_TOKEN:-(kosong - isi DASHBOARD_TOKEN di $CONFIG_FILE)}"
      printf '  Dan port %s belum ada di PORT_DIIZINKAN. K05 memang tidak akan\n' "$WEB_PORT"
      printf '  menyalakan firewall selama masih ada port terbuka yang belum dijawab -\n'
      printf '  tambahkan sendiri kalau port ini memang mau dibiarkan terbuka:\n\n'
      printf '      PORT_DIIZINKAN="%s"   di %s\n\n' "$WEB_PORT" "$CONFIG_FILE"
    fi ;;
esac

if [ ! -x "$BIN_DIR/yoru-agent" ]; then
  printf '  %sBelum selesai betul.%s Agent Hermes belum terpasang di %s/yoru-agent.\n' "$AMBER" "$RESET" "$BIN_DIR"
  printf '  Dispatcher, katalog, dan timer sudah siap, tapi belum ada yang memakainya:\n'
  printf '  siklus penjagaan akan berhenti tiap hari sampai agentnya ada.\n\n'
fi
