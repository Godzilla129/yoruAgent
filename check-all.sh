#!/bin/bash
# check-all.sh - check all ten Yoru controls at once
# Run: sudo bash check-all.sh
# This is the first version of Yoru's periksa() functions, still by hand.

if [ "$EUID" -ne 0 ]; then echo "Harus dijalankan dengan sudo."; exit 1; fi

passed=0; failed=0

check() {  # check "<name>" "<actual>" "<expected>"
  if [ "$2" = "$3" ]; then
    printf '  \033[32mLULUS\033[0m  %-46s %s\n' "$1" "$2"
    passed=$((passed+1))
  else
    printf '  \033[31mGAGAL\033[0m  %-46s %s (harusnya: %s)\n' "$1" "$2" "$3"
    failed=$((failed+1))
  fi
}

echo
echo "=== KONTROL YORU - $(hostname) - $(date '+%Y-%m-%d %H:%M:%S') ==="
echo

check "K01 root tidak bisa login SSH" \
    "$(sshd -T 2>/dev/null | awk '/^permitrootlogin/ {print $2}')" "no"

check "K02 login password dimatikan" \
    "$(sshd -T 2>/dev/null | awk '/^passwordauthentication/ {print $2}')" "no"

check "K03 batas percobaan login" \
    "$(sshd -T 2>/dev/null | awk '/^maxauthtries/ {print $2}')" "3"

check "K03 batas waktu login" \
    "$(sshd -T 2>/dev/null | awk '/^logingracetime/ {print $2}')" "30"

check "K04 tidak ada MAC sha1" \
    "$(sshd -T 2>/dev/null | grep -E '^macs ' | grep -c 'sha1')" "0"

check "K05 firewall aktif" \
    "$(ufw status 2>/dev/null | awk '/^Status:/ {print $2}')" "active"

check "K05 default tolak masuk" \
    "$(ufw status verbose 2>/dev/null | grep -c 'deny (incoming)')" "1"

check "K06 mariadb hanya localhost" \
    "$(ss -tulpn 2>/dev/null | grep -c '127.0.0.1:3306')" "1"

check "K06 mariadb tidak di 0.0.0.0" \
    "$(ss -tulpn 2>/dev/null | grep -c '0.0.0.0:3306')" "0"

check "K07 update otomatis aktif" \
    "$(systemctl is-enabled unattended-upgrades 2>/dev/null)" "enabled"

check "K08 aturan audit termuat (min 12)" \
    "$(n=$(auditctl -l 2>/dev/null | grep -c '^-w'); [ "${n:-0}" -ge 12 ] && echo ya || echo "tidak ($n)")" "ya"

check "K08 auditd berjalan" \
    "$(systemctl is-active auditd 2>/dev/null)" "active"

check "K09 log permanen" \
    "$(test -d /var/log/journal && echo ada || echo tidak)" "ada"

check "K09 pagu log 500M" \
    "$(journalctl -b -t systemd-journald --no-pager 2>/dev/null | grep -oE 'max [0-9.]+[KMGT]' | tail -1)" "max 500.0M"

check "K10 log_martians" \
    "$(sysctl -n net.ipv4.conf.all.log_martians 2>/dev/null)" "1"

check "K10 secure_redirects" \
    "$(sysctl -n net.ipv4.conf.all.secure_redirects 2>/dev/null)" "0"

check "K10 ipv6 accept_ra (0, atau na kalau tanpa IPv6)" \
    "$(v=$(sysctl -n net.ipv6.conf.all.accept_ra 2>/dev/null); case "${v:-na}" in 0|na) echo ya ;; *) echo "tidak ($v)" ;; esac)" "ya"

check "K10 jumlah setelan terbaca (min 12)" \
    "$(n=$(sysctl -a 2>/dev/null | grep -cE 'conf\.(all|default)\.(accept_redirects|secure_redirects|accept_source_route|log_martians|accept_ra) |^net\.ipv4\.(icmp_echo_ignore_broadcasts|icmp_ignore_bogus_error_responses|tcp_syncookies|ip_forward) '); [ "${n:-0}" -ge 12 ] && echo ya || echo "tidak ($n)")" "ya"

echo
echo "  ------------------------------------------------------------"
printf '  LULUS %d   GAGAL %d\n' "$passed" "$failed"
echo

# Bonus drift signal: did the server die unexpectedly?
#
# No pipe into grep -q, on purpose. This script does not use pipefail yet, but
# if anyone ever adds it, "command | grep -q" would read as a failure exactly
# when the thing it looks for is found. yoructl already got bitten by that.
last_boot=$(journalctl -b -1 -n 30 --no-pager 2>/dev/null)
case "$last_boot" in
  *Stopping*|*"Shutting down"*|*"Reached target"*Shutdown*|*"Reached target"*Power*)
  echo "  Boot sebelumnya: dimatikan dengan rapi." ;;
  *)
  echo "  PERINGATAN  Boot sebelumnya berhenti tanpa baris shutdown."
  echo "              Server kemungkinan mati tidak wajar. Periksa penyebabnya." ;;
esac
echo

[ "$failed" -eq 0 ]
