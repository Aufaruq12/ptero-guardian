#!/usr/bin/env python3
"""Ptero Guardian - pengatur VPS + booster install Pterodactyl.
Jalan sebagai service systemd selama VPS hidup. Config: /etc/ptero-guardian/config.ini"""
import configparser, glob, json, os, re, shutil, signal, socket, subprocess, threading, time
import urllib.request
from datetime import datetime, date, timezone

CONF_PATH = "/etc/ptero-guardian/config.ini"
STATE_PATH = "/var/lib/ptero-guardian/state.json"
MAINT_FLAG = "/etc/ptero-guardian/maintenance"   # buat file ini = guardian jangan restart service
HOST = socket.gethostname()

cfg = configparser.ConfigParser()
cfg.read(CONF_PATH)


def c(sec, key, default=""):
    return cfg.get(sec, key, fallback=default).strip()


def ci(sec, key, default):
    try:
        return int(float(c(sec, key, str(default))))
    except ValueError:
        return default


def cf(sec, key, default):
    try:
        return float(c(sec, key, str(default)))
    except ValueError:
        return default


BRAND = c("general", "brand", "MizuutSkii Store")
DISK_PATH = "/var/lib/pterodactyl" if os.path.isdir("/var/lib/pterodactyl") else "/"
running = True


def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def sh(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True,
                           text=True, timeout=timeout)
        return r.returncode, (r.stdout or "").strip()
    except Exception as e:
        return 1, str(e)


# ---------- notifikasi Discord ----------
def notify(title, msg, color=0x3498DB):
    log(f"{title} | {msg}")
    url = c("general", "webhook")
    if not url:
        return
    body = {"username": BRAND, "embeds": [{
        "title": title, "description": msg[:1800], "color": color,
        "footer": {"text": f"{BRAND} • {HOST}"},
        "timestamp": datetime.now(timezone.utc).isoformat()}]}
    try:
        req = urllib.request.Request(
            url, json.dumps(body).encode(),
            {"Content-Type": "application/json", "User-Agent": "ptero-guardian/1.0"})
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:
        log(f"webhook gagal: {e}")


_last_alert = {}


def alert(key, title, msg, color=0xE74C3C, cooldown=1800):
    now = time.time()
    if now - _last_alert.get(key, 0) < cooldown:
        return
    _last_alert[key] = now
    notify(title, msg, color)


def load_state():
    try:
        with open(STATE_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(st):
    try:
        os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
        with open(STATE_PATH, "w") as f:
            json.dump(st, f)
    except Exception as e:
        log(f"gagal simpan state: {e}")


# ---------- monitor service ----------
def detect_services():
    wanted = [s.strip() for s in c("services", "list",
              "wings,docker,mariadb,mysql,nginx,redis-server,redis,pteroq").split(",") if s.strip()]
    _, out = sh("systemctl list-unit-files --type=service --no-legend")
    units = {l.split()[0] for l in out.splitlines() if l.strip()}
    found = [s for s in wanted if f"{s}.service" in units]
    if "mariadb" in found and "mysql" in found:
        found.remove("mysql")
    if "redis-server" in found and "redis" in found:
        found.remove("redis")
    found += sorted(u[:-8] for u in units if re.match(r"php[\d.]+-fpm\.service$", u))
    return found


_restarts = {}


def check_services(services):
    if os.path.exists(MAINT_FLAG):
        return
    for s in services:
        rc, _ = sh(["systemctl", "is-active", "--quiet", s])
        if rc == 0:
            continue
        hist = [t for t in _restarts.get(s, []) if time.time() - t < 600]
        if len(hist) >= 3:
            alert(f"svc-{s}", f"❌ {s} gagal pulih",
                  f"`{s}` mati lagi, sudah 3x di-restart dalam 10 menit.\nCek: `journalctl -u {s} -n 50`")
            _restarts[s] = hist
            continue
        sh(["systemctl", "restart", s], timeout=120)
        hist.append(time.time())
        _restarts[s] = hist
        ok = sh(["systemctl", "is-active", "--quiet", s])[0] == 0
        notify(("✅ " if ok else "⚠️ ") + f"{s} di-restart otomatis",
               f"`{s}` sempat mati, guardian {'berhasil menyalakan lagi' if ok else 'GAGAL menyalakan lagi'}.",
               0x2ECC71 if ok else 0xE67E22)


# ---------- monitor resource + cleanup ----------
def meminfo():
    d = {}
    with open("/proc/meminfo") as f:
        for l in f:
            k, v = l.split(":")
            d[k] = int(v.split()[0])
    return d


def disk_pct():
    du = shutil.disk_usage(DISK_PATH)
    return du.used / du.total * 100


def cleanup(reason):
    before = shutil.disk_usage(DISK_PATH).free
    sh("journalctl --vacuum-size=200M", 120)
    sh("docker image prune -f", 300)          # hanya image dangling, container server aman
    sh("apt-get clean", 60)
    sh("find /var/log/pterodactyl/install -type f -mtime +7 -delete 2>/dev/null", 60)
    sh("find /var/log -type f -name '*.gz' -mtime +14 -delete 2>/dev/null", 60)
    freed = (shutil.disk_usage(DISK_PATH).free - before) / 1024 / 1024
    log(f"cleanup ({reason}): bebas {freed:.0f} MB")
    return freed


def check_resources():
    m = meminfo()
    free_pct = m["MemAvailable"] / m["MemTotal"] * 100
    if free_pct < cf("thresholds", "ram_min_free_pct", 8):
        alert("ram", "⚠️ RAM VPS hampir habis",
              f"RAM tersedia tinggal {free_pct:.1f}%. Ada server customer yang boros atau VPS perlu upgrade.")
    load = os.getloadavg()[1] / (os.cpu_count() or 1)
    if load > cf("thresholds", "load_per_core", 1.5):
        alert("load", "⚠️ CPU VPS tinggi",
              f"Load rata-rata 5 menit {load:.2f} per core. Node mulai berat, server bisa delay.")
    pct = disk_pct()
    if pct >= ci("thresholds", "disk_clean_pct", 90):
        freed = cleanup("disk penuh")
        alert("disk", "💾 Disk hampir penuh",
              f"Disk {pct:.0f}% → auto-clean membebaskan {freed:.0f} MB. "
              "Kalau masih tinggi, cek backup & server customer di /var/lib/pterodactyl.")
    elif pct >= ci("thresholds", "disk_warn_pct", 85):
        alert("diskwarn", "💾 Disk mulai penuh", f"Pemakaian disk {pct:.0f}%.", 0xF1C40F, 6 * 3600)


# ---------- masa aktif VPS ----------
def check_expiry():
    d = c("general", "vps_expiry")
    if not d:
        return
    try:
        exp = datetime.strptime(d, "%Y-%m-%d").date()
    except ValueError:
        return
    left = (exp - date.today()).days
    if not (left in (7, 3, 1, 0) or left < 0):
        return
    key = f"{d}:{left}"
    st = load_state()
    if st.get("expiry_key") == key:
        return
    st["expiry_key"] = key
    save_state(st)
    if left >= 0:
        notify("📅 Masa aktif VPS", f"VPS habis {d} ({left} hari lagi). Perpanjang sebelum server customer mati.", 0xF1C40F)
    else:
        notify("🚨 VPS sudah lewat masa aktif", f"Expired {-left} hari lalu ({d}).", 0xE74C3C)


# ---------- BOOSTER install Pterodactyl ----------
_installs = {}          # container_id -> {"name","start","stuck"}
_saved_governor = None


def get_governor():
    try:
        with open("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor") as f:
            return f.read().strip()
    except Exception:
        return None


def set_governor(g):
    for p in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor"):
        try:
            with open(p, "w") as f:
                f.write(g)
        except Exception:
            pass


def installer_containers():
    rc, out = sh(["docker", "ps", "--format", "{{.ID}}|{{.Image}}|{{.Names}}"])
    res = {}
    if rc != 0:
        return res
    for l in out.splitlines():
        p = l.split("|")
        if len(p) == 3 and (p[2].endswith("_installer") or "installers" in p[1]):
            res[p[0]] = p[2]
    return res


def pid_tree(pid):
    pids = [pid]
    _, s = sh(["pgrep", "-P", str(pid)])
    for ch in s.split():
        if ch.isdigit():
            pids += pid_tree(int(ch))
    return pids


def boost(cid):
    _, pid = sh(["docker", "inspect", "-f", "{{.State.Pid}}", cid])
    if not pid.isdigit() or int(pid) == 0:
        return
    for p in pid_tree(int(pid)):
        sh(["renice", "-n", "-10", "-p", str(p)])
        sh(["ionice", "-c2", "-n0", "-p", str(p)])


def booster_tick():
    global _saved_governor
    now = time.time()
    active = installer_containers()
    for cid, name in active.items():
        if cid not in _installs:
            _installs[cid] = {"name": name, "start": now, "stuck": False}
            sh(["docker", "update", "--cpu-shares", str(ci("booster", "install_cpu_shares", 8192)), cid])
            sh(["docker", "update", "--blkio-weight", "1000", cid])   # diabaikan kalau kernel tidak support
            if _saved_governor is None:
                _saved_governor = get_governor()
                if _saved_governor:
                    set_governor("performance")
            notify("🚀 Booster install aktif", f"Install server `{name.replace('_installer', '')[:8]}` mulai, prioritas CPU/IO dinaikkan.", 0x9B59B6)
        boost(cid)  # proses anak (apt/npm/wget) muncul belakangan, jadi terapkan ulang tiap tick
        info = _installs[cid]
        if not info["stuck"] and now - info["start"] > ci("thresholds", "install_stuck_min", 30) * 60:
            info["stuck"] = True
            notify("⚠️ Install kelamaan", f"Install `{name[:8]}` sudah >{ci('thresholds', 'install_stuck_min', 30)} menit. Cek log install di panel.", 0xE67E22)
    for cid in list(_installs):
        if cid not in active:
            info = _installs.pop(cid)
            dur = now - info["start"]
            notify("✅ Install selesai", f"Server `{info['name'].replace('_installer', '')[:8]}` selesai install dalam {dur:.0f} detik.", 0x2ECC71)
    if not _installs and _saved_governor:
        set_governor(_saved_governor)
        _saved_governor = None


def warm_images():
    """Pre-pull image installer/yolks supaya create hosting tidak nunggu download."""
    default = ("ghcr.io/pterodactyl/installers:alpine,ghcr.io/parkervcp/installers:debian,"
               "ghcr.io/parkervcp/yolks:debian,ghcr.io/parkervcp/yolks:nodejs_20")
    for img in [i.strip() for i in c("booster", "warm_images", default).split(",") if i.strip()]:
        if disk_pct() > 80 or not running:
            return
        sh(["nice", "-n", "19", "docker", "pull", "-q", img], timeout=900)
    log("warm images selesai")


# ---------- main ----------
def safe(fn, *a):
    try:
        fn(*a)
    except Exception as e:
        log(f"error di {fn.__name__}: {e}")


def stop(*_):
    global running
    running = False


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    services = detect_services()
    notify("🟢 Ptero Guardian aktif", f"Memantau: {', '.join(services) or '-'}\nBooster install + auto-clean berjalan.", 0x2ECC71)
    fast, health = ci("intervals", "fast", 5), ci("intervals", "health", 30)
    now = time.time()
    nxt_health, nxt_clean, nxt_warm = 0, now + 6 * 3600, now + 90
    while running:
        now = time.time()
        safe(booster_tick)
        if now >= nxt_health:
            safe(check_services, services)
            safe(check_resources)
            safe(check_expiry)
            nxt_health = now + health
        if now >= nxt_clean:
            safe(cleanup, "terjadwal")
            nxt_clean = now + 6 * 3600
        if now >= nxt_warm:
            threading.Thread(target=safe, args=(warm_images,), daemon=True).start()
            nxt_warm = now + 86400
        time.sleep(fast)
    log("guardian berhenti")


if __name__ == "__main__":
    main()
