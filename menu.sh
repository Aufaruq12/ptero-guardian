#!/usr/bin/env bash
# =====================================================
#  Ptero Guardian - Menu (Install / Update / Uninstall)
#  by MizuutSkii Store
# =====================================================

# >>> GANTI baris ini sebelum upload ke GitHub <<<
GH_REPO="${GH_REPO:-Aufaruq12/ptero-guardian}"
GH_BRANCH="${GH_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${GH_REPO}/${GH_BRANCH}}"

APP_DIR="/opt/ptero-guardian"
CONF_DIR="/etc/ptero-guardian"
STATE_DIR="/var/lib/ptero-guardian"
SERVICE="/etc/systemd/system/ptero-guardian.service"
CMD_BIN="/usr/local/bin/ptero-guardian"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; N=$'\e[0m'
ok()   { echo "${G}✔${N} $*"; }
warn() { echo "${Y}!${N} $*"; }
err()  { echo "${R}✘${N} $*" >&2; }

# input dibaca dari /dev/tty supaya tetap jalan saat dipanggil lewat: curl ... | bash
ask() {
  local ans=""
  { printf '%s' "$1" >/dev/tty; read -r ans </dev/tty; } 2>/dev/null || true
  echo "${ans:-${2:-}}"
}

need_root() { [ "$(id -u)" -eq 0 ] || { err "Jalankan sebagai root (sudo)."; exit 1; }; }

is_installed() { [ -f "$SERVICE" ] && [ -f "$APP_DIR/guardian.py" ]; }

status_line() {
  if is_installed; then
    if systemctl is-active --quiet ptero-guardian; then echo "${G}● terpasang & berjalan${N}"
    else echo "${Y}● terpasang tapi TIDAK berjalan${N}"; fi
  else
    echo "${R}○ belum terpasang${N}"
  fi
}

check_repo() {
  if [[ "$RAW_BASE" == *GANTI_USERNAME* ]]; then
    err "GH_REPO belum diganti. Edit baris GH_REPO di menu.sh dengan username/repo GitHub kamu."
    return 1
  fi
}

fetch() { # fetch <nama-file-di-repo> <tujuan>
  curl -fsSL --retry 3 --connect-timeout 10 "$RAW_BASE/$1" -o "$2"
}

download_guardian() {
  local tmp; tmp="$(mktemp)"
  if ! fetch guardian.py "$tmp"; then
    err "Gagal download guardian.py dari $RAW_BASE"; rm -f "$tmp"; return 1
  fi
  if ! python3 -m py_compile "$tmp" 2>/dev/null; then
    err "guardian.py hasil download rusak (syntax error), dibatalkan."; rm -f "$tmp"; return 1
  fi
  mkdir -p "$APP_DIR"
  install -m 755 "$tmp" "$APP_DIR/guardian.py"
  rm -f "$tmp" "${tmp}c"
  rm -rf "$APP_DIR/__pycache__"
  return 0
}

install_shortcut() {
  local tmp; tmp="$(mktemp)"
  if fetch menu.sh "$tmp" 2>/dev/null; then
    install -m 755 "$tmp" "$CMD_BIN"
  fi
  rm -f "$tmp"
}

# ---------------- tuning sistem ----------------
apply_tuning() {
  local swap_gb="$1"
  modprobe tcp_bbr 2>/dev/null || true
  {
    echo "# Ptero Guardian tuning"
    echo "fs.file-max = 2097152"
    echo "fs.inotify.max_user_watches = 524288"
    echo "fs.inotify.max_user_instances = 1024"
    echo "vm.swappiness = 10"
    echo "vm.vfs_cache_pressure = 50"
    echo "net.core.somaxconn = 4096"
    echo "net.core.netdev_max_backlog = 16384"
    echo "net.core.rmem_max = 16777216"
    echo "net.core.wmem_max = 16777216"
    echo "net.core.rmem_default = 262144"
    echo "net.core.wmem_default = 262144"
    echo "net.ipv4.udp_rmem_min = 16384"
    echo "net.ipv4.udp_wmem_min = 16384"
    echo "net.ipv4.tcp_fastopen = 3"
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    fi
  } > /etc/sysctl.d/99-ptero-guardian.conf
  sysctl --system >/dev/null 2>&1 || true

  cat > /etc/security/limits.d/99-ptero-guardian.conf << 'LIM'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIM
  ok "Tuning kernel & limit file terpasang"

  if [ "$swap_gb" -gt 0 ] 2>/dev/null && [ "$(swapon --show --noheadings | wc -l)" -eq 0 ]; then
    local avail_gb; avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
    if [ "${avail_gb:-0}" -gt $((swap_gb + 5)) ]; then
      fallocate -l "${swap_gb}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((swap_gb * 1024)) status=none
      chmod 600 /swapfile && mkswap /swapfile >/dev/null
      if swapon /swapfile 2>/dev/null; then
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap ${swap_gb}G aktif"
      else
        rm -f /swapfile; warn "Swap tidak didukung VPS ini, dilewati"
      fi
    else
      warn "Disk kurang, swap dilewati"
    fi
  fi

  if [ -f /etc/systemd/system/wings.service ]; then
    mkdir -p /etc/systemd/system/wings.service.d
    cat > /etc/systemd/system/wings.service.d/override.conf << 'WOV'
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity
WOV
    systemctl daemon-reload
    ok "Limit Wings diset (berlaku saat Wings restart berikutnya)"
  fi
}

write_config() { # brand webhook expiry
  mkdir -p "$CONF_DIR" "$STATE_DIR"
  [ -f "$CONF_DIR/config.ini" ] && cp "$CONF_DIR/config.ini" "$CONF_DIR/config.ini.bak"
  cat > "$CONF_DIR/config.ini" << CFG
[general]
brand = $1
webhook = $2
; format YYYY-MM-DD, kosongkan kalau tidak mau pengingat
vps_expiry = $3

[intervals]
fast = 5
health = 30

[thresholds]
disk_warn_pct = 85
disk_clean_pct = 90
ram_min_free_pct = 8
load_per_core = 1.5
install_stuck_min = 30

[services]
list = wings,docker,mariadb,mysql,nginx,redis-server,redis,pteroq

[booster]
install_cpu_shares = 8192
; image yang di-pull duluan biar create hosting tidak nunggu download. Samakan dengan egg kamu.
warm_images = ghcr.io/pterodactyl/installers:alpine,ghcr.io/parkervcp/installers:debian,ghcr.io/parkervcp/yolks:debian,ghcr.io/parkervcp/yolks:nodejs_20
CFG
  chmod 600 "$CONF_DIR/config.ini"
}

write_service() {
  cat > "$SERVICE" << 'SVC'
[Unit]
Description=Ptero Guardian - VPS manager & Pterodactyl booster
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /opt/ptero-guardian/guardian.py
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=multi-user.target
SVC
  systemctl daemon-reload
}

# ---------------- 1) INSTALL ----------------
do_install() {
  need_root; check_repo || return 1
  echo; echo "${B}=== INSTALL ===${N}"
  command -v docker >/dev/null || { err "Docker belum ada. Pasang Pterodactyl Wings dulu."; return 1; }
  if is_installed; then
    local yn; yn="$(ask 'Sudah terpasang. Install ulang (config lama di-backup)? [y/N]: ' n)"
    [[ "$yn" =~ ^[Yy]$ ]] || { warn "Dibatalkan. Pakai menu Update untuk memperbarui."; return 0; }
  fi

  local brand webhook expiry swap
  brand="$(ask 'Nama toko/brand [MizuutSkii Store]: ' 'MizuutSkii Store')"
  webhook="$(ask 'Discord webhook URL (kosongkan kalau tidak pakai): ')"
  expiry="$(ask 'Masa aktif VPS YYYY-MM-DD (kosongkan kalau tidak pakai): ')"
  swap="$(ask 'Ukuran swap GB, 0 = lewati [2]: ' 2)"
  [[ "$expiry" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})?$ ]] || { err "Format tanggal salah, contoh: 2026-12-31"; return 1; }
  [[ "$swap" =~ ^[0-9]+$ ]] || swap=2

  echo
  if ! command -v python3 >/dev/null; then apt-get update -y >/dev/null && apt-get install -y python3 >/dev/null; fi
  command -v pgrep >/dev/null || apt-get install -y procps >/dev/null
  command -v curl >/dev/null || apt-get install -y curl >/dev/null

  apply_tuning "$swap"
  download_guardian || return 1
  ok "guardian.py terpasang"
  write_config "$brand" "$webhook" "$expiry"
  write_service
  install_shortcut
  systemctl enable --now ptero-guardian >/dev/null 2>&1
  sleep 2
  if systemctl is-active --quiet ptero-guardian; then
    ok "Ptero Guardian berjalan. Buka menu lagi kapan saja dengan perintah: ${B}ptero-guardian${N}"
    echo "   Log: journalctl -u ptero-guardian -f"
    echo "   Config: $CONF_DIR/config.ini"
  else
    err "Service gagal start. Cek: journalctl -u ptero-guardian -n 50"
  fi
}

# ---------------- 2) UPDATE ----------------
do_update() {
  need_root; check_repo || return 1
  echo; echo "${B}=== UPDATE ===${N}"
  is_installed || { err "Belum terpasang. Pilih Install dulu."; return 1; }
  download_guardian || return 1
  ok "guardian.py diperbarui (config kamu tidak diubah)"
  install_shortcut
  systemctl restart ptero-guardian
  sleep 2
  systemctl is-active --quiet ptero-guardian && ok "Service berjalan dengan versi terbaru" || err "Service gagal start, cek: journalctl -u ptero-guardian -n 50"
}

# ---------------- 3) UNINSTALL ----------------
do_uninstall() {
  need_root
  echo; echo "${B}=== UNINSTALL ===${N}"
  is_installed || warn "Guardian tidak terdeteksi terpasang, tetap bersihkan sisa file."
  local yn; yn="$(ask 'Yakin hapus Ptero Guardian? Server customer TIDAK ikut terhapus. [y/N]: ' n)"
  [[ "$yn" =~ ^[Yy]$ ]] || { warn "Dibatalkan."; return 0; }

  systemctl disable --now ptero-guardian >/dev/null 2>&1 || true
  rm -f "$SERVICE"
  rm -rf "$APP_DIR"
  ok "Service & program dihapus"

  yn="$(ask 'Hapus juga tuning kernel & limit Wings yang dipasang guardian? [y/N]: ' n)"
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    rm -f /etc/sysctl.d/99-ptero-guardian.conf /etc/security/limits.d/99-ptero-guardian.conf
    rm -rf /etc/systemd/system/wings.service.d/override.conf
    rmdir /etc/systemd/system/wings.service.d 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    ok "Tuning dihapus (nilai lama kembali penuh setelah reboot / restart Wings)"
  fi

  yn="$(ask 'Hapus config & state ($CONF_DIR)? [y/N]: ' n)"
  if [[ "$yn" =~ ^[Yy]$ ]]; then rm -rf "$CONF_DIR" "$STATE_DIR"; ok "Config dihapus"; else warn "Config disimpan di $CONF_DIR"; fi

  rm -f "$CMD_BIN"
  systemctl daemon-reload
  ok "Selesai. (Swap /swapfile tidak dihapus; hapus manual kalau tidak dipakai.)"
}

# ---------------- MENU ----------------
show_menu() {
  clear 2>/dev/null || true
  echo "${B}╔═══════════════════════════════════════╗${N}"
  echo "${B}║   PTERO GUARDIAN  •  MizuutSkii Store ║${N}"
  echo "${B}╚═══════════════════════════════════════╝${N}"
  echo "Status: $(status_line)"
  echo
  echo "  1) Install"
  echo "  2) Update"
  echo "  3) Uninstall"
  echo "  0) Keluar"
  echo
}

main() {
  case "${1:-}" in
    install)   do_install; return ;;
    update)    do_update; return ;;
    uninstall) do_uninstall; return ;;
  esac
  while true; do
    show_menu
    local pick; pick="$(ask 'Pilih menu [0-3]: ' 0)"
    case "$pick" in
      1) do_install ;;
      2) do_update ;;
      3) do_uninstall ;;
      0) echo "Bye!"; exit 0 ;;
      *) warn "Pilihan tidak valid" ;;
    esac
    echo; ask 'Tekan Enter untuk kembali ke menu... ' >/dev/null
  done
}

[ "${GUARDIAN_SOURCE_ONLY:-0}" = "1" ] || main "$@"
