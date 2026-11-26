# Ptero Guardian

Pengatur VPS + booster install Pterodactyl untuk hosting game SA-MP & bot hosting.
By MizuutSkii Store.

## Fitur
- Monitor & auto-restart: wings, docker, mariadb, nginx, redis, pteroq, php-fpm
- Booster saat create hosting / installing (prioritas CPU & IO + pre-pull image)
- Auto-clean disk, alert RAM/CPU/disk ke Discord webhook
- Pengingat masa aktif VPS (H-7, H-3, H-1, H-0)
- Jalan sebagai service systemd, otomatis aktif selama VPS hidup

## Pasang (1 baris, jalankan sebagai root di VPS node)
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/USERNAME/ptero-guardian/main/menu.sh)
```
Menu: `1) Install  2) Update  3) Uninstall`

Setelah terpasang, menu bisa dibuka lagi dengan perintah:
```bash
ptero-guardian
```
Atau langsung tanpa menu: `ptero-guardian install|update|uninstall`

## Isi repo
| File | Fungsi |
|------|--------|
| `menu.sh` | Menu Install / Update / Uninstall |
| `guardian.py` | Program utama (service) |

## Catatan
- Edit baris `GH_REPO` di `menu.sh` menjadi `username/nama-repo` sebelum upload.
- Repo harus **public** agar `curl` bisa download tanpa token.
- Maintenance: buat file `/etc/ptero-guardian/maintenance` agar guardian tidak me-restart service, hapus setelah selesai.
- Config: `/etc/ptero-guardian/config.ini` | Log: `journalctl -u ptero-guardian -f`
