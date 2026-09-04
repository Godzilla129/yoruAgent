#!/bin/bash
# check-all.sh - periksa 10 kontrol Yoru sekaligus
# Jalankan: sudo bash check-all.sh
# Ini versi pertama fungsi periksa() milik Yoru, masih ditulis tangan.

if [ "$EUID" -ne 0 ]; then echo "Harus dijalankan dengan sudo."; exit 1; fi

lulus=0; gagal=0

cek() {  # cek "<nama>" "<hasil>" "<harapan>"
  if [ "$2" = "$3" ]; then
    printf '  \033[32mLULUS\033[0m  %-46s %s\n' "$1" "$2"
    lulus=$((lulus+1))
  else
    printf '  \033[31mGAGAL\033[0m  %-46s %s (harusnya: %s)\n' "$1" "$2" "$3"
    gagal=$((gagal+1))
  fi
}

echo
echo "=== KONTROL YORU - $(hostname) - $(date '+%Y-%m-%d %H:%M:%S') ==="
echo

cek "K01 root tidak bisa login SSH" \
    "$(sshd -T 2>/dev/null | awk '/^permitrootlogin/ {print $2}')" "no"

cek "K02 login password dimatikan" \
    "$(sshd -T 2>/dev/null | awk '/^passwordauthentication/ {print $2}')" "no"

cek "K03 batas percobaan login" \
    "$(sshd -T 2>/dev/null | awk '/^maxauthtries/ {print $2}')" "3"

cek "K03 batas waktu login" \
    "$(sshd -T 2>/dev/null | awk '/^logingracetime/ {print $2}')" "30"

cek "K04 tidak ada MAC sha1" \
    "$(sshd -T 2>/dev/null | grep -E '^macs ' | grep -c 'sha1')" "0"

cek "K05 firewall aktif" \
    "$(ufw status 2>/dev/null | awk '/^Status:/ {print $2}')" "active"

cek "K05 default tolak masuk" \
    "$(ufw status verbose 2>/dev/null | grep -c 'deny (incoming)')" "1"

cek "K06 mariadb hanya localhost" \
    "$(ss -tulpn 2>/dev/null | grep -c '127.0.0.1:3306')" "1"

cek "K06 mariadb tidak di 0.0.0.0" \
    "$(ss -tulpn 2>/dev/null | grep -c '0.0.0.0:3306')" "0"

cek "K07 update otomatis aktif" \
    "$(systemctl is-enabled unattended-upgrades 2>/dev/null)" "enabled"

cek "K08 aturan audit termuat" \
    "$(auditctl -l 2>/dev/null | grep -c '^-w')" "12"

cek "K08 auditd berjalan" \
    "$(systemctl is-active auditd 2>/dev/null)" "active"

cek "K09 log permanen" \
    "$(test -d /var/log/journal && echo ada || echo tidak)" "ada"

cek "K09 pagu log 500M" \
    "$(journalctl -b -t systemd-journald --no-pager 2>/dev/null | grep -o 'max [0-9.]*M' | tail -1)" "max 500.0M"

cek "K10 log_martians" \
    "$(sysctl -n net.ipv4.conf.all.log_martians 2>/dev/null)" "1"

cek "K10 secure_redirects" \
    "$(sysctl -n net.ipv4.conf.all.secure_redirects 2>/dev/null)" "0"

cek "K10 ipv6 accept_ra" \
    "$(sysctl -n net.ipv6.conf.all.accept_ra 2>/dev/null)" "0"

cek "K10 jumlah setelan terbaca" \
    "$(sysctl -a 2>/dev/null | grep -cE 'conf\.(all|default)\.(accept_redirects|secure_redirects|accept_source_route|log_martians|accept_ra) |^net\.ipv4\.(icmp_echo_ignore_broadcasts|icmp_ignore_bogus_error_responses|tcp_syncookies|ip_forward) ')" "18"

echo
echo "  ------------------------------------------------------------"
printf '  LULUS %d   GAGAL %d\n' "$lulus" "$gagal"
echo

# Sinyal drift bonus: server mati tidak wajar?
if journalctl -b -1 -n 30 --no-pager 2>/dev/null | grep -qE 'Stopping|Shutting down|Reached target.*(Shutdown|Power)'; then
  echo "  Boot sebelumnya: dimatikan dengan rapi."
else
  echo "  PERINGATAN  Boot sebelumnya berhenti tanpa baris shutdown."
  echo "              Server kemungkinan mati tidak wajar. Periksa penyebabnya."
fi
echo

[ "$gagal" -eq 0 ]
