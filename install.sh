#!/bin/bash

# ==============================================================================
#  ARIADNY MASTER PANEL v4.1 ULTRA - CYBER-OPS TUI & VPS INFRASTRUCTURE SUITE
#  Autor: Yelsin Machado
# ==============================================================================

VERSION="v4.1 ULTRA"
BASE_URL="https://raw.githubusercontent.com/Yelsinml10/AriadnyHn/main"
CONFIG_DIR="/etc/ariadny"
CORE_PANEL_PATH="$CONFIG_DIR/menu.sh"
THEME_FILE="$CONFIG_DIR/theme.conf"
NET_CACHE_FILE="/tmp/.ariadny_net_meta"
BACKUP_DIR="/root/ariadny-backups"
LOG_FILE="/var/log/ariadny-panel.log"

mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" 2>/dev/null

# Restaurar cursor, eco de terminal y colores siempre al salir
cleanup() {
    stty echo 2>/dev/null
    printf "\033[?25h\033[0m"
}
trap cleanup EXIT INT TERM

# ==================== UTILIDADES & MOTOR DE ANIMACIÓN ====================

command_exists() { command -v "$1" >/dev/null 2>&1; }

log_event() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null
}

get_active_theme() {
    if [[ -f "$THEME_FILE" ]]; then
        cat "$THEME_FILE"
    else
        echo "cyberpunk"
    fi
}

clear_screen() { printf "\033[2J\033[H"; }

pause_screen() {
    printf "\n  \033[38;2;120;130;150mPresiona \033[1;38;2;0;245;212m[ENTER]\033[0m\033[38;2;120;130;150m para continuar...\033[0m"
    read -r
}

info() { printf "  \033[1;38;2;0;245;160m✔\033[0m \033[38;2;230;240;250m%s\033[0m\n" "$1"; }
warn() { printf "  \033[1;38;2;255;209;102m⚠\033[0m \033[38;2;255;230;160m%s\033[0m\n" "$1"; }
error_msg() {
    printf "  \033[1;38;2;255;77;109m✖\033[0m \033[38;2;255;180;190m%s\033[0m\n" "$1" >&2
    log_event "ERROR: $1"
}

run_with_spinner() {
    local msg="$1"
    shift
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    local start_ts
    start_ts=$(date +%s)

    printf "\033[?25l"
    "$@" >/dev/null 2>&1 &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( $(date +%s) - start_ts ))
        printf "\r  \033[1;38;2;0;245;212m%s\033[0m \033[38;2;205;220;240m%s\033[0m \033[38;2;110;125;145m[%ss]\033[0m\033[K" \
            "${frames[$i]}" "$msg" "$elapsed"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.08
    done

    wait "$pid"
    local exit_code=$?
    printf "\r\033[K\033[?25h"

    if (( exit_code == 0 )); then
        info "$msg"
    else
        error_msg "Error en: $msg"
    fi
    return "$exit_code"
}

boot_sequence() {
    clear_screen
    printf "\033[?25l\n\n"
    local arch virt bbr_st
    arch=$(uname -m)
    virt=$(systemd-detect-virt 2>/dev/null || echo "KVM/Cloud")
    bbr_st=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")

    printf "  \033[1;38;2;0;245;212m◈ ARIADNY CYBER-OPS ENGINE %s\033[0m  \033[38;2;110;120;140m[%s • %s • TCP:%s]\033[0m\n" \
        "$VERSION" "$arch" "${virt^^}" "${bbr_st^^}"
    printf "  \033[38;2;50;65;85m────────────────────────────────────────────────────────────────\033[0m\n"

    local stages=(
        "Verificando integridad del núcleo y permisos root..."
        "Auditando sockets TCP/UDP y servicios activos..."
        "Cargando telemetría de red y motor gráfico TrueColor..."
    )
    local bars=(
        "▰▰▰▰▱▱▱▱▱▱▱▱  33%"
        "▰▰▰▰▰▰▰▰▱▱▱▱  68%"
        "▰▰▰▰▰▰▰▰▰▰▰▰ 100%"
    )
    for idx in 0 1 2; do
        printf "\r  \033[1;38;2;0;187;249m▸\033[0m \033[38;2;210;225;240m%-44s\033[0m \033[1;38;2;0;245;160m%s\033[0m" \
            "${stages[$idx]}" "${bars[$idx]}"
        sleep 0.15
    done
    printf "\n\033[?25h"
    sleep 0.06
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        error_msg "Ejecuta el panel como root: sudo bash $0"
        exit 1
    fi
}

install_dependencies() {
    local missing=()
    command_exists curl || missing+=("curl")
    command_exists python3 || missing+=("python3")

    if (( ${#missing[@]} > 0 )); then
        if command_exists apt-get; then
            run_with_spinner "Instalando paquetes base (${missing[*]})" bash -c "apt-get update -qq && apt-get install -y ${missing[*]} -qq"
        elif command_exists yum; then
            run_with_spinner "Instalando paquetes base (${missing[*]})" yum install -y "${missing[@]}" -qq
        fi
    fi
}

get_network_metadata() {
    local now
    now=$(date +%s)
    if [[ -f "$NET_CACHE_FILE" ]]; then
        local age=$(( now - $(stat -c %Y "$NET_CACHE_FILE" 2>/dev/null || echo 0) ))
        if (( age < 7200 )) && [[ -s "$NET_CACHE_FILE" ]]; then
            cat "$NET_CACHE_FILE"
            return 0
        fi
    fi

    python3 - "$NET_CACHE_FILE" << 'PYNET'
import sys, json, urllib.request, subprocess
cache_file = sys.argv[1]
ip = ""
isp = "VPS Cloud"
country = ""
try:
    req = urllib.request.Request("http://ip-api.com/json/?fields=status,countryCode,isp,org,query", headers={"User-Agent": "AriadnyPanel/4.1"})
    with urllib.request.urlopen(req, timeout=2.5) as r:
        data = json.loads(r.read().decode())
        if data.get("status") == "success":
            ip = data.get("query", "")
            country = data.get("countryCode", "")
            raw_isp = data.get("isp") or data.get("org") or "Cloud"
            isp = raw_isp.split(",")[0][:16]
except Exception:
    pass

if not ip:
    try:
        ip = urllib.request.urlopen("https://api.ipify.org", timeout=2).read().decode().strip()
    except Exception:
        try:
            ip = subprocess.check_output("hostname -I | awk '{print $1}'", shell=True).decode().strip()
        except Exception:
            ip = "127.0.0.1"

res = f"{ip}|{isp}|{country}"
try:
    with open(cache_file, "w") as f:
        f.write(res)
except Exception:
    pass
print(res)
PYNET
}

# ==================== INSTALACIÓN DE ATAJOS & BANNER SSH ====================

setup_terminal_banner() {
    cat << 'EOF' > /etc/profile.d/99-ariadny-banner.sh
# Banner de Bienvenida Ariadny ULTRA
if [[ $- == *i* ]]; then
    META=$(cat /tmp/.ariadny_net_meta 2>/dev/null)
    IP_ADDR=$(echo "$META" | cut -d'|' -f1)
    ISP_NAME=$(echo "$META" | cut -d'|' -f2)
    CC_CODE=$(echo "$META" | cut -d'|' -f3)
    [[ -z "$IP_ADDR" ]] && IP_ADDR=$(curl -s --connect-timeout 2 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$IP_ADDR" ]] && IP_ADDR="127.0.0.1"

    RAM_INFO=$(free -h 2>/dev/null | awk 'NR==2 {print $3 "/" $2}')
    DISK_INFO=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')
    OS_INFO=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null | cut -d' ' -f1,2)
    BBR_INFO=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    ARCH_INFO=$(uname -m)

    echo -e "\033[1;38;2;0;187;249m╔══════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;38;2;0;245;212m  █████╗ ██████╗ ██╗ █████╗ ██████╗ ███╗   ██╗██╗   ██╗\033[0m"
    echo -e "\033[1;38;2;0;216;230m ██╔══██╗██╔══██╗██║██╔══██╗██╔══██╗████╗  ██║╚██╗ ██╔╝\033[0m"
    echo -e "\033[1;38;2;0;187;249m ███████║██████╔╝██║███████║██║  ██║██╔██╗ ██║ ╚████╔╝ \033[0m"
    echo -e "\033[1;38;2;75;140;245m ██╔══██║██╔══██╗██║██╔══██║██║  ██║██║╚██╗██║  ╚██╔╝  \033[0m"
    echo -e "\033[1;38;2;155;93;229m ██║  ██║██║  ██║██║██║  ██║██████╔╝██║ ╚████║   ██║   \033[0m"
    echo -e "\033[1;38;2;190;110;255m ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═══╝   ╚═╝   \033[0m"
    echo -e "\033[1;38;2;0;187;249m╠══════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;38;2;0;245;212m  ◈ IP VPS  :\033[1;37m $IP_ADDR \033[38;2;130;145;165m(${ISP_NAME:-Cloud} ${CC_CODE})\033[0m"
    echo -e "\033[1;38;2;0;245;160m  ◈ SISTEMA :\033[1;37m ${OS_INFO:-Linux} ($ARCH_INFO) • TCP: ${BBR_INFO^^}\033[0m"
    echo -e "\033[1;38;2;255;209;102m  ◈ RAM     :\033[1;37m $RAM_INFO   \033[1;38;2;180;130;255m◈ DISCO:\033[1;37m $DISK_INFO\033[0m"
    echo -e "\033[1;38;2;0;187;249m╠══════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;38;2;255;209;102m  ▸ Ejecuta \033[1;38;2;0;245;160mmenu\033[1;38;2;255;209;102m para ingresar a Ariadny Master Panel\033[0m"
    echo -e "\033[1;38;2;0;187;249m╚══════════════════════════════════════════════════════════╝\033[0m"
fi
EOF
    chmod +x /etc/profile.d/99-ariadny-banner.sh 2>/dev/null
}

setup_menu_shortcut() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    local current_script
    current_script="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

    # Copiar script físico a /etc/ariadny/menu.sh si se ejecutó desde otra ruta
    if [[ -f "$current_script" && "$current_script" != /dev/fd/* && "$current_script" != /proc/* \
       && "$(basename "$current_script")" != "bash" && "$(basename "$current_script")" != "sh" \
       && "$current_script" != "$CORE_PANEL_PATH" ]]; then
        if head -n 1 "$current_script" | grep -q "^#!"; then
            cp -f "$current_script" "$CORE_PANEL_PATH" 2>/dev/null
        fi
    fi

    # Si /etc/ariadny/menu.sh no existe o está incompleto, descargarlo desde GitHub
    if [[ ! -s "$CORE_PANEL_PATH" ]] || ! head -n 1 "$CORE_PANEL_PATH" | grep -q "^#!"; then
        local tmp_core="/tmp/ariadny_core.$$"
        if curl -fsSL --connect-timeout 10 "$BASE_URL/menu.sh" -o "$tmp_core" 2>/dev/null \
           && [[ -s "$tmp_core" ]] && head -n 1 "$tmp_core" | grep -q "^#!"; then
            mv -f "$tmp_core" "$CORE_PANEL_PATH"
        else
            rm -f "$tmp_core"
        fi
    fi
    chmod 755 "$CORE_PANEL_PATH" 2>/dev/null

    # Instalar ejecutable directo 'menu' en el PATH del sistema
    for bindir in /usr/local/bin /usr/bin; do
        if [[ -d "$bindir" ]]; then
            cat << 'EOF' > "$bindir/menu"
#!/bin/bash
PANEL="/etc/ariadny/menu.sh"
URL="https://raw.githubusercontent.com/Yelsinml10/AriadnyHn/main/menu.sh"
if [[ -s "$PANEL" ]] && head -n 1 "$PANEL" | grep -q "^#!"; then
    exec bash "$PANEL" "$@"
else
    mkdir -p /etc/ariadny
    TMP="/tmp/ariadny_menu.$$"
    if curl -fsSL --connect-timeout 10 "$URL" -o "$TMP" && [[ -s "$TMP" ]] && head -n 1 "$TMP" | grep -q "^#!"; then
        mv -f "$TMP" "$PANEL"
        chmod 755 "$PANEL"
        exec bash "$PANEL" "$@"
    else
        rm -f "$TMP"
        echo -e "\033[1;31m[✖] No se encontró /etc/ariadny/menu.sh y no se pudo descargar desde GitHub.\033[0m"
        exit 1
    fi
fi
EOF
            chmod 755 "$bindir/menu" 2>/dev/null
        fi
    done

    # Limpiar alias antiguos que puedan interferir con /usr/local/bin/menu
    rm -f /etc/profile.d/00-ariadny-menu.sh 2>/dev/null
    for rc in /root/.bashrc /etc/bash.bashrc /etc/profile; do
        [[ -f "$rc" ]] && sed -i '/alias menu=/d' "$rc" 2>/dev/null
    done
    hash -r 2>/dev/null

    setup_terminal_banner
}

# ==================== MOTOR TUI CENTRAL EN PYTHON (24-BIT TRUECOLOR) ====================

ariadny_tui_engine() {
    local mode="${1:-full}"
    local net_meta active_theme
    net_meta=$(get_network_metadata)
    active_theme=$(get_active_theme)

    python3 - "$VERSION" "$net_meta" "$mode" "$active_theme" << 'PYEOF'
import sys, os, re, json, time, shutil, socket, select, termios, tty, subprocess, unicodedata

VERSION  = sys.argv[1]
NET_META = sys.argv[2]
MODE     = sys.argv[3] if len(sys.argv) > 3 else "full"
THEME    = sys.argv[4] if len(sys.argv) > 4 else "cyberpunk"

meta_parts = (NET_META + "||").split("|")
IP_ADDR  = meta_parts[0] or "127.0.0.1"
ISP_NAME = meta_parts[1] or "VPS Cloud"
CC_CODE  = meta_parts[2] or ""

RST  = "\033[0m"
BOLD = "\033[1m"

THEMES = {
    "cyberpunk": {
        "primary": "\033[1;38;2;0;245;212m",
        "accent":  "\033[1;38;2;0;187;249m",
        "border":  "\033[38;2;45;115;195m",
        "sec":     "\033[1;38;2;155;93;229m",
        "grad": [
            "\033[1;38;2;0;245;212m", "\033[1;38;2;0;216;230m", "\033[1;38;2;0;187;249m",
            "\033[1;38;2;75;140;245m", "\033[1;38;2;130;110;238m", "\033[1;38;2;175;95;235m"
        ]
    },
    "matrix": {
        "primary": "\033[1;38;2;0;255;136m",
        "accent":  "\033[1;38;2;57;211;83m",
        "border":  "\033[38;2;35;135;80m",
        "sec":     "\033[1;38;2;0;210;190m",
        "grad": [
            "\033[1;38;2;180;255;190m", "\033[1;38;2;80;255;140m", "\033[1;38;2;0;245;120m",
            "\033[1;38;2;0;210;105m", "\033[1;38;2;0;175;90m", "\033[1;38;2;0;145;75m"
        ]
    },
    "crimson": {
        "primary": "\033[1;38;2;255;85;115m",
        "accent":  "\033[1;38;2;255;159;28m",
        "border":  "\033[38;2;185;55;80m",
        "sec":     "\033[1;38;2;255;209;102m",
        "grad": [
            "\033[1;38;2;255;209;102m", "\033[1;38;2;255;159;28m", "\033[1;38;2;255;107;53m",
            "\033[1;38;2;255;77;109m", "\033[1;38;2;220;47;90m", "\033[1;38;2;180;35;75m"
        ]
    },
    "gold": {
        "primary": "\033[1;38;2;255;215;0m",
        "accent":  "\033[1;38;2;245;180;65m",
        "border":  "\033[38;2;170;135;55m",
        "sec":     "\033[1;38;2;120;200;255m",
        "grad": [
            "\033[1;38;2;255;250;205m", "\033[1;38;2;255;230;128m", "\033[1;38;2;255;215;0m",
            "\033[1;38;2;238;185;20m", "\033[1;38;2;210;155;30m", "\033[1;38;2;180;125;35m"
        ]
    }
}

T = THEMES.get(THEME, THEMES["cyberpunk"])
C_PRI     = T["primary"]
C_ACC     = T["accent"]
C_BDR     = T["border"]
C_SEC     = T["sec"]
GRAD_LOGO = T["grad"]

C_GREEN   = "\033[1;38;2;0;245;160m"
C_YELLOW  = "\033[1;38;2;255;209;102m"
C_ORANGE  = "\033[1;38;2;255;140;66m"
C_RED     = "\033[1;38;2;255;77;109m"
C_WHITE   = "\033[1;38;2;242;246;252m"
C_TEXT    = "\033[38;2;201;209;217m"
C_MUTED   = "\033[38;2;125;135;150m"
C_DIV     = "\033[38;2;75;90;115m"
C_BAR_OFF = "\033[38;2;85;100;125m"

def get_width():
    try:
        cols = shutil.get_terminal_size().columns
    except Exception:
        cols = 80
    return max(44, min(cols - 1 if cols > 44 else cols, 106))

W = get_width()
TWO_COL = W >= 68

def vis_len(text):
    clean = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", text)
    l = 0
    for ch in clean:
        if unicodedata.combining(ch) or ord(ch) in (0xFE0F, 0xFE0E):
            continue
        l += 2 if unicodedata.east_asian_width(ch) in ("F", "W") else 1
    return l

def fit_text(text, max_w):
    if vis_len(text) <= max_w:
        return text
    out, cur, i = [], 0, 0
    limit = max(1, max_w - 2)
    while i < len(text):
        if text[i] == "\x1b":
            m = re.match(r"\x1b\[[0-9;]*[a-zA-Z]", text[i:])
            if m:
                out.append(m.group(0))
                i += len(m.group(0))
                continue
        ch = text[i]
        i += 1
        if unicodedata.combining(ch) or ord(ch) in (0xFE0F, 0xFE0E):
            continue
        w_ch = 2 if unicodedata.east_asian_width(ch) in ("F", "W") else 1
        if cur + w_ch > limit:
            break
        out.append(ch)
        cur += w_ch
    return "".join(out) + RST + C_MUTED + ".." + RST

def trunc(text, max_len=16):
    return text if len(text) <= max_len else text[:max_len - 2] + ".."

def make_bar(pct, width=8):
    pct = max(0, min(100, int(round(pct))))
    filled = int(round((pct / 100.0) * width))
    if pct > 0 and filled == 0:
        filled = 1
    empty = width - filled
    col = C_GREEN if pct < 65 else (C_YELLOW if pct < 85 else C_RED)
    return f"{col}{'▰' * filled}{C_BAR_OFF}{'▱' * empty}{RST} {C_WHITE}{pct:>2}%{RST}"

def run_cmd(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL).decode("utf-8", errors="ignore")
    except Exception:
        return ""

# ==================== TELEMETRÍA & ESCÁNER DE SERVICIOS ====================

def get_telemetry():
    os_name = "Linux"
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    os_name = " ".join(line.split("=", 1)[1].strip().strip('"').split()[:2])
                    break
    except Exception:
        pass

    arch = os.uname().machine
    bbr = run_cmd("sysctl -n net.ipv4.tcp_congestion_control").strip().upper() or "CUBIC"

    ram_used, ram_total, ram_pct = "N/A", "N/A", 0
    for line in run_cmd("free -m").splitlines():
        if line.startswith("Mem:"):
            p = line.split()
            tot, used = int(p[1]), int(p[2])
            ram_pct = (used / tot * 100) if tot > 0 else 0
            ram_used = f"{used/1024:.1f}G" if tot >= 1024 else f"{used}M"
            ram_total = f"{tot/1024:.1f}G" if tot >= 1024 else f"{tot}M"
            break

    disk_used, disk_total, disk_pct = "N/A", "N/A", 0
    df_lines = run_cmd("df -h /").splitlines()
    if len(df_lines) >= 2:
        p = df_lines[1].split()
        disk_total, disk_used = p[1], p[2]
        disk_pct = int(p[4].replace("%", "")) if "%" in p[4] else 0

    load_avg = "0.00"
    try:
        with open("/proc/loadavg") as f:
            load_avg = f.read().split()[0]
    except Exception:
        pass

    uptime_str = run_cmd("uptime -p").strip().replace("up ", "") or "N/A"
    if len(uptime_str) > 18:
        uptime_str = uptime_str[:16] + ".."

    est_out = run_cmd("ss -tun state established | tail -n +2 | wc -l").strip()
    est_conns = est_out if est_out.isdigit() else "0"

    return {
        "os": os_name, "arch": arch, "bbr": bbr,
        "ram_str": f"{ram_used}/{ram_total}", "ram_pct": ram_pct,
        "disk_str": f"{disk_used}/{disk_total}", "disk_pct": disk_pct,
        "load": load_avg, "uptime": uptime_str, "conns": est_conns
    }

def scan_services():
    ss_all = run_cmd("ss -tulpn")
    ps_all = run_cmd("ps -eo pid,rss,args")
    sysd_out = run_cmd("systemctl list-units --type=service --state=running --no-pager --no-legend")

    listening_all = set()
    for line in ss_all.splitlines():
        if not any(k in line.lower() for k in ["sshd", "caddy", "nginx", "xray", "v2ray"]):
            for m in re.findall(r":(\d+)\s", line):
                listening_all.add(int(m))

    def read_json_ports(paths, keys=("port", "ports", "server_port", "local_port")):
        found = set()
        for path in paths:
            try:
                with open(path) as f:
                    data = json.load(f)
                if "inbounds" in data or "inbound" in data:
                    inbs = list(data.get("inbounds", []))
                    if "inbound" in data:
                        inbs.append(data["inbound"])
                    for inb in inbs:
                        p = inb.get("port")
                        if str(p).isdigit():
                            found.add(int(p))
                for k in keys:
                    v = data.get(k)
                    if isinstance(v, int):
                        found.add(v)
                    elif isinstance(v, str) and v.isdigit():
                        found.add(int(v))
                    elif isinstance(v, list):
                        found.update(int(x) for x in v if str(x).isdigit())
            except Exception:
                pass
        return found

    def find_proc(patterns):
        pids, rss_kb = [], 0
        for line in ps_all.splitlines()[1:]:
            parts = line.strip().split(None, 2)
            if len(parts) < 3:
                continue
            pid, rss, cmd = parts
            low = cmd.lower()
            if "grep" in low or "ariadny" in low:
                continue
            if any(p in low for p in patterns):
                pids.append(pid)
                if rss.isdigit():
                    rss_kb += int(rss)
        return pids, f"{rss_kb/1024:.1f} MB" if rss_kb > 0 else "0.0 MB"

    def sysd_active(names):
        low = sysd_out.lower()
        return any(f"{n}.service" in low for n in names)

    def ss_ports(include_keys, exclude_keys=(), ignore_ports=()):
        p_set = set()
        for line in ss_all.splitlines():
            low = line.lower()
            if any(k in low for k in include_keys) and not any(e in low for e in exclude_keys):
                for m in re.findall(r":(\d+)\s", line):
                    val = int(m)
                    if val not in ignore_ports:
                        p_set.add(val)
        return p_set

    services_spec = [
        {"key": "caddy",   "svc": "caddy",        "name": "Caddy",   "full": "Caddy Web/Mux",         "sysd": ["caddy"], "proc": ["caddy"], "ports": lambda: ss_ports(["caddy"], ignore_ports=[2019]), "default": ""},
        {"key": "nginx",   "svc": "nginx",        "name": "Nginx",   "full": "Nginx Reverse Proxy",   "sysd": ["nginx"], "proc": ["nginx"], "ports": lambda: ss_ports(["nginx"]), "default": ""},
        {"key": "v2ray",   "svc": "v2ray",        "name": "V2Ray",   "full": "V2Ray Core",            "sysd": ["v2ray"], "proc": ["v2ray"], "ports": lambda: ss_ports(["v2ray"]) or read_json_ports(["/usr/local/v2ray/config.json", "/usr/local/etc/v2ray/config.json", "/etc/v2ray/config.json"]), "default": ""},
        {"key": "xray",    "svc": "xray",         "name": "XRay",    "full": "XRay Core",             "sysd": ["xray"],  "proc": ["xray"],  "ports": lambda: ss_ports(["xray"]) or read_json_ports(["/usr/local/etc/xray/config.json", "/etc/xray/config.json"]), "default": ""},
        {"key": "sshgo",   "svc": "vpn-proxy",    "name": "SSH-Go",  "full": "SSH-Go Proxy",          "sysd": ["vpn-proxy", "ssh-go"], "proc": ["vpn-proxy", "ssh-go"], "ports": lambda: ss_ports(["vpn-proxy", "ssh-go"]) or read_json_ports(["/opt/vpn-proxy/config.json", "/etc/vpn-proxy/config.json", "/etc/ssh-go/config.json"]), "default": ""},
        {"key": "udp",     "svc": "udp-custom",   "name": "UDP",     "full": "UDP Custom / Hysteria", "sysd": ["udp-custom", "udp-hysteria", "zivpn"], "proc": ["udp-custom", "zivpn", "hysteria"], "ports": lambda: ss_ports(["udp-custom", "hysteria", "zivpn"], ignore_ports=[68, 123]), "default": ""},
        {"key": "badvpn",  "svc": "badvpn",       "name": "BadVPN",  "full": "BadVPN UDPGW",          "sysd": ["badvpn"], "proc": ["badvpn-udpgw"], "ports": lambda: {int(m) for m in re.findall(r"--listen-addr\s+(?:127\.0\.0\.1:)?(\d+)", ps_all)}, "default": ""},
        {"key": "rust",    "svc": "socks-rust",   "name": "Rust",    "full": "SOCKS Proxy Rust",      "sysd": ["rust-proxy", "socks-rust", "rust"], "proc": ["socks-rust", "rust-proxy", "socks_rust", "ssservice"], "ports": lambda: ss_ports(["socks-rust", "rust-proxy", "socks_rust", "rust-socks", "ssservice"]) or (read_json_ports(["/root/socks_config.json", "/etc/socks-rust/config.json", "/etc/rust-proxy/config.json", "/etc/rust/config.json"]) & listening_all), "default": "ON"},
        {"key": "python",  "svc": "python-proxy", "name": "Python",  "full": "SOCKS Proxy Python",    "sysd": ["python-proxy"], "proc": ["proxy.py", "python-proxy", "p-proxy"], "ports": lambda: ss_ports(["proxy.py"], exclude_keys=["rust", "caddy", "nginx", "sshd", "xray", "v2ray"]) or (read_json_ports(["/root/socks_config.json", "/etc/socks-python/config.json", "/etc/python-proxy/config.json"]) & listening_all), "default": ""},
        {"key": "slowdns", "svc": "slowdns",      "name": "SlowDNS", "full": "SlowDNS / DNSTT",       "sysd": ["slowdns", "dns-server"], "proc": ["dns-server", "slowdns", "dnstt"], "ports": lambda: ss_ports(["dns-server", "slowdns", "dnstt", "server-dns"]), "default": "53"},
        {"key": "ssl",     "svc": "stunnel4",     "name": "SSL/TLS", "full": "Stunnel SSL/TLS",       "sysd": ["stunnel4", "stunnel"], "proc": ["stunnel"], "ports": lambda: ss_ports(["stunnel", "stunnel4"]), "default": "ON"},
        {"key": "ssh",     "svc": "ssh",          "name": "SSH",     "full": "OpenSSH Server",        "sysd": ["sshd", "ssh"], "proc": ["sshd"], "ports": lambda: ss_ports(["sshd"], exclude_keys=["python", "vpn-proxy", "ssh-go", "socks", "rust"]), "default": "22"},
    ]

    results = []
    for s in services_spec:
        pids, mem = find_proc(s["proc"])
        is_up = sysd_active(s["sysd"]) or len(pids) > 0
        p_set = s["ports"]()
        if s["key"] == "rust" and p_set:
            is_up = True
        p_str = ",".join(map(str, sorted(p_set))) if p_set else s["default"]
        if s["key"] in ("caddy", "nginx", "v2ray", "xray", "sshgo", "udp", "badvpn", "python") and not p_str:
            is_up = False
        results.append({
            "key": s["key"], "svc": s["svc"], "name": s["name"], "full": s["full"],
            "active": is_up, "ports": p_str if p_str else "-",
            "pid": pids[0] if pids else "-", "mem": mem if is_up else "-"
        })
    return results

# ==================== PRIMITIVAS DE DIBUJO EXACTAS ====================

def box_top(title="", color=C_BDR):
    if not title:
        print(f"{color}╔{'═' * (W - 2)}╗{RST}")
    else:
        vt = vis_len(title)
        rem = max(0, W - 6 - vt)
        print(f"{color}┌── {BOLD}{title}{RST}{color} {'─' * rem}┐{RST}")

def box_mid(title="", color=C_BDR, double=False):
    if double:
        print(f"{color}╠{'═' * (W - 2)}╣{RST}")
    elif title:
        vt = vis_len(title)
        rem = max(0, W - 6 - vt)
        print(f"{color}├── {BOLD}{title}{RST}{color} {'─' * rem}┤{RST}")
    else:
        print(f"{color}├{'─' * (W - 2)}┤{RST}")

def box_bot(color=C_BDR, double=False):
    if double:
        print(f"{color}╚{'═' * (W - 2)}╝{RST}")
    else:
        print(f"{color}└{'─' * (W - 2)}┘{RST}")

def print_center(text, color=C_BDR, double=True):
    b = "║" if double else "│"
    t_fit = fit_text(text, W - 2)
    vt = vis_len(t_fit)
    pt = max(0, (W - 2 - vt) // 2)
    ptr = max(0, W - 2 - vt - pt)
    print(f"{color}{b}{RST}{' ' * pt}{t_fit}{' ' * ptr}{color}{b}{RST}")

def print_row_1col(text, color=C_BDR, double=True):
    b = "║" if double else "│"
    t_fit = fit_text(text, W - 2)
    vt = vis_len(t_fit)
    pad = max(0, W - 2 - vt)
    print(f"{color}{b}{RST}{t_fit}{' ' * pad}{color}{b}{RST}")

def print_row_2col(left, right, color=C_BDR, double=True, sep=True):
    b = "║" if double else "│"
    if not TWO_COL:
        print_row_1col(left, color, double)
        if right.strip():
            print_row_1col(right, color, double)
        return
    inner = W - 2
    if sep:
        c1 = (inner - 1) // 2
        c2 = inner - 1 - c1
        l_fit = fit_text(left, c1 - 1)
        r_fit = fit_text(right, c2 - 1)
        s1 = l_fit + (" " * max(0, c1 - vis_len(l_fit)))
        s2 = r_fit + (" " * max(0, c2 - vis_len(r_fit)))
        print(f"{color}{b}{RST}{s1}{C_DIV}│{RST}{s2}{color}{b}{RST}")
    else:
        c1 = inner // 2
        c2 = inner - c1
        l_fit = fit_text(left, c1 - 1)
        r_fit = fit_text(right, c2 - 1)
        s1 = l_fit + (" " * max(0, c1 - vis_len(l_fit)))
        s2 = r_fit + (" " * max(0, c2 - vis_len(r_fit)))
        print(f"{color}{b}{RST}{s1}{s2}{color}{b}{RST}")

def draw_header(tele):
    box_top(color=C_ACC)
    logo = [
        " █████╗ ██████╗ ██╗ █████╗ ██████╗ ███╗   ██╗██╗   ██╗",
        "██╔══██╗██╔══██╗██║██╔══██╗██╔══██╗████╗  ██║╚██╗ ██╔╝",
        "███████║██████╔╝██║███████║██║  ██║██╔██╗ ██║ ╚████╔╝ ",
        "██╔══██║██╔══██╗██║██╔══██║██║  ██║██║╚██╗██║  ╚██╔╝  ",
        "██║  ██║██║  ██║██║██║  ██║██████╔╝██║ ╚████║   ██║   ",
        "╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═══╝   ╚═╝   "
    ]
    if W >= 60:
        for idx, line in enumerate(logo):
            print_center(f"{GRAD_LOGO[idx]}{line}{RST}", color=C_ACC)
    else:
        print_center(f"{C_PRI}◈ ARIADNY MASTER PANEL ◈{RST}", color=C_ACC)

    bbr_badge = f"{C_GREEN}BBR:ON{RST}" if tele["bbr"] == "BBR" else f"{C_YELLOW}{tele['bbr']}{RST}"
    subtitle = f"{C_PRI}◈{RST} {C_WHITE}ARIADNY MASTER PANEL {C_PRI}{VERSION}{RST}  {C_DIV}•{RST}  {C_YELLOW}✦ Yelsin Machado{RST}  {C_DIV}•{RST}  {bbr_badge}"
    print_center(subtitle, color=C_ACC)
    box_mid(color=C_ACC, double=True)

    loc_tag = f" ({CC_CODE})" if CC_CODE else ""
    r1_l = f"  {C_PRI}◈{RST} {C_PRI}IP VPS :{RST} {C_WHITE}{IP_ADDR}{RST} {C_MUTED}{trunc(ISP_NAME, 10)}{loc_tag}{RST}"
    r1_r = f"  {C_GREEN}◈{RST} {C_GREEN}SISTEMA:{RST} {C_WHITE}{tele['os']}{RST} {C_MUTED}[{tele['arch']}]{RST}"
    r2_l = f"  {C_YELLOW}◈{RST} {C_YELLOW}RAM    :{RST} {make_bar(tele['ram_pct'], 8)} {C_MUTED}({tele['ram_str']}){RST}"
    r2_r = f"  {C_SEC}◈{RST} {C_SEC}DISCO  :{RST} {make_bar(tele['disk_pct'], 8)} {C_MUTED}({tele['disk_str']}){RST}"
    r3_l = f"  {C_ACC}◈{RST} {C_ACC}UPTIME :{RST} {C_TEXT}{tele['uptime']}{RST}"
    r3_r = f"  {C_PRI}◈{RST} {C_PRI}CONEX. :{RST} {C_WHITE}{tele['conns']} activas{RST} {C_MUTED}(Load {tele['load']}){RST}"

    print_row_2col(r1_l, r1_r, color=C_ACC, double=True, sep=True)
    print_row_2col(r2_l, r2_r, color=C_ACC, double=True, sep=True)
    print_row_2col(r3_l, r3_r, color=C_ACC, double=True, sep=True)
    box_bot(color=C_ACC, double=True)

# ==================== MODO 1: MONITOR EN VIVO TIPO HTOP ====================

if MODE == "live_monitor":
    def read_cpu_stat():
        with open("/proc/stat") as f:
            vals = list(map(int, f.readline().split()[1:8]))
        return vals[3] + vals[4], sum(vals)

    def read_net_bytes():
        rx = tx = 0
        with open("/proc/net/dev") as f:
            for line in f.readlines()[2:]:
                if ":" in line and not line.strip().startswith("lo:"):
                    parts = line.split(":", 1)[1].split()
                    rx += int(parts[0])
                    tx += int(parts[8])
        return rx, tx

    def fmt_speed(bps):
        if bps >= 1048576:
            return f"{bps / 1048576:.2f} MB/s"
        return f"{bps / 1024:.1f} KB/s"

    cpu_hist = [0] * 18
    prev_idle, prev_tot = read_cpu_stat()
    prev_rx, prev_tx = read_net_bytes()
    prev_t = time.time()

    tty_file, old_term = None, None
    try:
        tty_file = open("/dev/tty", "rb", buffering=0)
        old_term = termios.tcgetattr(tty_file.fileno())
        tty.setcbreak(tty_file.fileno())
    except Exception:
        tty_file = None

    try:
        sys.stdout.write("\033[?25l\033[2J")
        while True:
            sys.stdout.write("\033[H")
            W = get_width()
            TWO_COL = W >= 68
            tele = get_telemetry()
            draw_header(tele)

            now = time.time()
            dt = max(0.1, now - prev_t)
            cur_idle, cur_tot = read_cpu_stat()
            cur_rx, cur_tx = read_net_bytes()

            d_tot = max(1, cur_tot - prev_tot)
            cpu_pct = max(0.0, min(100.0, (1.0 - (cur_idle - prev_idle) / d_tot) * 100.0))
            rx_spd = fmt_speed((cur_rx - prev_rx) / dt)
            tx_spd = fmt_speed((cur_tx - prev_tx) / dt)
            prev_idle, prev_tot = cur_idle, cur_tot
            prev_rx, prev_tx = cur_rx, cur_tx
            prev_t = now

            cpu_hist.pop(0)
            cpu_hist.append(int(cpu_pct))
            sparks = "▁▂▃▄▅▆▇█"
            spark_str = "".join(sparks[min(7, v * 8 // 101)] for v in cpu_hist)
            cores = run_cmd("nproc").strip() or "1"
            tot_gb = f"{cur_rx / 1073741824:.2f} GB ↓ / {cur_tx / 1073741824:.2f} GB ↑"

            box_top(f"{C_PRI}MONITOR EN TIEMPO REAL (LIVE TELEMETRY){RST}", color=C_PRI)
            print_row_1col(f"  {C_ACC}◈ CPU ({cores} vCPU) :{RST} {make_bar(cpu_pct, 14)}   {C_PRI}{spark_str}{RST}", color=C_PRI, double=False)
            print_row_1col(f"  {C_YELLOW}◈ Memoria RAM :{RST} {make_bar(tele['ram_pct'], 14)}   {C_WHITE}{tele['ram_str']}{RST}", color=C_PRI, double=False)
            print_row_1col(f"  {C_SEC}◈ Disco Raíz  :{RST} {make_bar(tele['disk_pct'], 14)}   {C_WHITE}{tele['disk_str']}{RST}", color=C_PRI, double=False)
            box_mid(f"{C_GREEN}TRÁFICO DE RED EN VIVO{RST}", color=C_PRI, double=False)
            print_row_1col(f"  {C_GREEN}▼ Descarga    :{RST} {C_WHITE}{rx_spd:<14}{RST}  {C_ORANGE}▲ Subida:{RST} {C_WHITE}{tx_spd}{RST}", color=C_PRI, double=False)
            print_row_1col(f"  {C_TEXT}▣ Acumulado   :{RST} {C_MUTED}{tot_gb}{RST}", color=C_PRI, double=False)

            est_ports = run_cmd("ss -tn state established | awk 'NR>1 {print $4}' | awk -F: '{print $NF}' | sort | uniq -c | sort -nr | head -n 4")
            top_list = []
            for line in est_ports.splitlines():
                parts = line.strip().split()
                if len(parts) == 2:
                    top_list.append(f"{C_PRI}:{parts[1]}{RST}({C_WHITE}{parts[0]}{RST})")
            top_str = "  ".join(top_list) if top_list else f"{C_MUTED}Sin tráfico activo{RST}"
            print_row_1col(f"  {C_YELLOW}✦ Top Puertos :{RST} {top_str}", color=C_PRI, double=False)
            box_bot(color=C_PRI, double=False)

            print(f"\n  {C_MUTED}Actualizando cada 1.2s • Presiona {C_PRI}[Q]{C_MUTED} o {C_PRI}[ENTER]{C_MUTED} para volver...{RST}\033[J")
            sys.stdout.flush()

            if tty_file:
                rlist, _, _ = select.select([tty_file], [], [], 1.2)
                if rlist:
                    ch = tty_file.read(1)
                    if ch in (b"q", b"Q", b"\n", b"\r", b"\x1b"):
                        break
            else:
                time.sleep(1.2)
                break
    finally:
        if tty_file and old_term:
            termios.tcsetattr(tty_file.fileno(), termios.TCSADRAIN, old_term)
        if tty_file:
            tty_file.close()
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()
    sys.exit(0)

# ==================== MODO 2: SPEEDTEST & LATENCIA NATIVO ====================

if MODE == "speedtest":
    import urllib.request
    tele = get_telemetry()
    draw_header(tele)
    box_top(f"{C_PRI}BENCHMARK DE RED & LATENCIA CLOUDFLARE{RST}", color=C_PRI)

    pings = []
    for host in ("1.1.1.1", "8.8.8.8"):
        for _ in range(3):
            t0 = time.perf_counter()
            try:
                s = socket.create_connection((host, 443), timeout=2.0)
                s.close()
                pings.append((time.perf_counter() - t0) * 1000.0)
            except Exception:
                pass

    avg_ping = sum(pings) / len(pings) if pings else 0.0
    jitter = (max(pings) - min(pings)) if len(pings) > 1 else 0.0
    print_row_1col(f"  {C_GREEN}✔ Latencia DNS :{RST} {C_WHITE}{avg_ping:.1f} ms{RST}  {C_MUTED}(Jitter: {jitter:.1f} ms){RST}", color=C_PRI, double=False)
    sys.stdout.flush()

    dl_mbps = 0.0
    try:
        url = "https://speed.cloudflare.com/__down?bytes=15000000"
        req = urllib.request.Request(url, headers={"User-Agent": "AriadnySpeedtest/4.1"})
        t0 = time.perf_counter()
        total_bytes = 0
        with urllib.request.urlopen(req, timeout=8) as resp:
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                total_bytes += len(chunk)
                if time.perf_counter() - t0 > 5.0:
                    break
        elapsed = max(0.05, time.perf_counter() - t0)
        dl_mbps = (total_bytes * 8) / (elapsed * 1_000_000)
    except Exception:
        dl_mbps = 0.0

    bar_pct = min(100, int(dl_mbps / 10))
    print_row_1col(f"  {C_ACC}▼ Descarga     :{RST} {make_bar(bar_pct, 12)}  {C_WHITE}{dl_mbps:.2f} Mbps{RST}", color=C_PRI, double=False)
    box_bot(color=C_PRI, double=False)
    sys.exit(0)

# ==================== VISTAS ESTÁNDAR DEL PANEL ====================

tele = get_telemetry()
services = scan_services()
draw_header(tele)

if MODE in ("full", "sub_multiplexacion", "sub_mas_opciones"):
    active_list = [s for s in services if s["active"]]
    box_top(f"{C_SEC}PUERTOS Y SERVICIOS ACTIVOS ({len(active_list)}/{len(services)}){RST}", color=C_SEC)
    if active_list:
        for i in range(0, len(active_list), 2):
            s1 = active_list[i]
            col1 = f"  {C_GREEN}●{RST} {C_WHITE}{s1['name']:<8}{RST} {C_DIV}▸{RST} {C_PRI}{trunc(s1['ports'], 16)}{RST}"
            col2 = ""
            if i + 1 < len(active_list):
                s2 = active_list[i + 1]
                col2 = f"  {C_GREEN}●{RST} {C_WHITE}{s2['name']:<8}{RST} {C_DIV}▸{RST} {C_PRI}{trunc(s2['ports'], 16)}{RST}"
            print_row_2col(col1, col2, color=C_SEC, double=False, sep=True)
    else:
        print_row_1col(f"  {C_YELLOW}⚠ Ningún servicio proxy/túnel activo detectado.{RST}", color=C_SEC, double=False)
    box_bot(color=C_SEC, double=False)

if MODE == "full":
    box_top(f"{C_PRI}PROTOCOLOS & TÚNELES{RST}", color=C_BDR)
    menu_proto = [
        (f"  {C_PRI}[01]{RST} {C_PRI}◈{RST} {C_WHITE}Multiplexores{RST}",       f"  {C_YELLOW}[02]{RST} {C_YELLOW}◈{RST} {C_WHITE}V2Ray / VMess{RST}"),
        (f"  {C_GREEN}[03]{RST} {C_GREEN}◈{RST} {C_WHITE}SSH-Go Proxy{RST}",       f"  {C_SEC}[04]{RST} {C_SEC}◈{RST} {C_WHITE}XRay Panel{RST}"),
        (f"  {C_RED}[05]{RST} {C_RED}◈{RST} {C_WHITE}UDP Panel{RST}",           f"  {C_ORANGE}[06]{RST} {C_ORANGE}◈{RST} {C_WHITE}SOCKS Proxy Rust{RST}"),
        (f"  {C_GREEN}[07]{RST} {C_GREEN}◈{RST} {C_WHITE}SOCKS Proxy Python{RST}", f"  {C_PRI}[08]{RST} {C_PRI}◈{RST} {C_WHITE}SSH Panel / Usuarios{RST}"),
        (f"  {C_SEC}[09]{RST} {C_SEC}◈{RST} {C_WHITE}BadVPN UDPGW{RST}",      f"  {C_YELLOW}[10]{RST} {C_YELLOW}◈{RST} {C_WHITE}SlowDNS Panel{RST}"),
        (f"  {C_ACC}[11]{RST} {C_ACC}◈{RST} {C_WHITE}SSL / TLS Manager{RST}",    f"  {C_ORANGE}[12]{RST} {C_ORANGE}❖{RST} {C_WHITE}Herramientas Pro...{RST}"),
    ]
    for l, r in menu_proto:
        print_row_2col(l, r, color=C_BDR, double=False, sep=True)

    box_mid(f"{C_YELLOW}SEGURIDAD & TELEMETRÍA{RST}", color=C_BDR, double=False)
    menu_admin = [
        (f"  {C_RED}[13]{RST} {C_RED}❖{RST} {C_WHITE}Firewall UFW/IPTables{RST}", f"  {C_GREEN}[14]{RST} {C_GREEN}❖{RST} {C_WHITE}Configurar SSH{RST}"),
        (f"  {C_PRI}[15]{RST} {C_PRI}▣{RST} {C_WHITE}Monitor en Vivo (htop){RST}",f"  {C_SEC}[16]{RST} {C_SEC}▣{RST} {C_WHITE}Diagnóstico & Servicios{RST}"),
        (f"  {C_RED}[00]{RST} {C_RED}✖ Salir del Panel{RST}",                   ""),
    ]
    for l, r in menu_admin:
        print_row_2col(l, r, color=C_BDR, double=False, sep=True)
    box_bot(color=C_BDR, double=False)

elif MODE == "sub_multiplexacion":
    box_top(f"{C_PRI}MULTIPLEXACIÓN & REVERSE PROXY{RST}", color=C_BDR)
    items = [
        f"  {C_PRI}[01]{RST} {C_PRI}◈{RST} {C_WHITE}Caddy Server{RST} {C_MUTED}(Auto-SSL & Multiplexor){RST}",
        f"  {C_GREEN}[02]{RST} {C_GREEN}◈{RST} {C_WHITE}Nginx Proxy{RST}  {C_MUTED}(WebSocket & Balanceo){RST}",
        f"  {C_RED}[00]{RST} {C_RED}◂ Volver al Menú Principal{RST}"
    ]
    for it in items:
        print_row_1col(it, color=C_BDR, double=False)
    box_bot(color=C_BDR, double=False)

elif MODE == "sub_mas_opciones":
    box_top(f"{C_ORANGE}CENTRO DE INGENIERÍA & HERRAMIENTAS PRO{RST}", color=C_BDR)
    items = [
        f"  {C_PRI}[01]{RST} {C_PRI}◈{RST} {C_WHITE}Activar TCP BBR + Optimización Kernel Red{RST}",
        f"  {C_GREEN}[02]{RST} {C_GREEN}◈{RST} {C_WHITE}Test de Velocidad & Latencia (Cloudflare){RST}",
        f"  {C_YELLOW}[03]{RST} {C_YELLOW}◈{RST} {C_WHITE}Crear Respaldo Completo de Configuraciones{RST}",
        f"  {C_SEC}[04]{RST} {C_SEC}◈{RST} {C_WHITE}Cambiar Tema Visual del Panel{RST} {C_MUTED}(Actual: {THEME.upper()}){RST}",
        f"  {C_ACC}[05]{RST} {C_ACC}◈{RST} {C_WHITE}Actualizar Ariadny Panel desde GitHub{RST}",
        f"  {C_GREEN}[06]{RST} {C_GREEN}◈{RST} {C_WHITE}Liberar Caché RAM & Limpiar Logs{RST}",
        f"  {C_RED}[00]{RST} {C_RED}◂ Volver al Menú Principal{RST}"
    ]
    for it in items:
        print_row_1col(it, color=C_BDR, double=False)
    box_bot(color=C_BDR, double=False)

elif MODE == "status_table":
    box_top(f"{C_SEC}DIAGNÓSTICO DETALLADO DE SERVICIOS{RST}", color=C_SEC)
    for idx, s in enumerate(services, 1):
        num = f"{C_MUTED}[{idx:02d}]{RST}"
        badge = f"{C_GREEN}● ACTIVO  {RST}" if s["active"] else f"{C_RED}○ INACTIVO{RST}"
        p_info = f"{C_PRI}Puertos: {s['ports']:<13}{RST}" if s["active"] else f"{C_MUTED}Puertos: -            {RST}"
        m_info = f"{C_YELLOW}RAM: {s['mem']:<8}{RST} {C_MUTED}(PID:{s['pid']}){RST}" if s["active"] else ""
        if TWO_COL:
            line = f"  {num} {C_WHITE}{s['full']:<21}{RST} {badge} {C_DIV}│{RST} {p_info} {m_info}"
        else:
            line = f"  {num} {C_WHITE}{s['name']:<8}{RST} {badge} {C_PRI}{s['ports']}{RST}"
        print_row_1col(line, color=C_SEC, double=False)
    box_bot(color=C_SEC, double=False)
PYEOF
}

render_ui() {
    local mode="${1:-full}"
    clear_screen
    ariadny_tui_engine "$mode"
}

prepare_for_external_script() {
    clear_screen
}

panel_header() {
    local title="$1"
    local icon="${2:-◆}"
    render_ui "header"
    printf "\n  \033[1;38;2;0;245;212m%s %s\033[0m\n" "$icon" "$title"
    printf "  \033[38;2;55;65;85m────────────────────────────────────────────────────────\033[0m\n\n"
}

# ==================== DESCARGA SEGURA ANTI-404 ====================

is_valid_script() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    if head -n 3 "$file" | grep -qiE "<!DOCTYPE html|<html|404: Not Found"; then
        return 1
    fi
    return 0
}

download_to_path() {
    local destination="$1"
    shift
    local names=("$@")

    for script_name in "${names[@]}"; do
        if run_with_spinner "Descargando módulo $script_name..." curl -fsSL --connect-timeout 15 --max-time 300 "$BASE_URL/$script_name" -o "$destination"; then
            if is_valid_script "$destination"; then
                chmod 700 "$destination"
                info "Módulo instalado en $destination"
                return 0
            fi
        fi
        rm -f "$destination"
    done

    error_msg "No se pudo descargar ningún módulo válido (${names[*]})."
    return 1
}

download_and_execute() {
    local script_name="$1"
    local temporary="/tmp/${script_name##*/}.$$"

    if ! run_with_spinner "Obteniendo $script_name desde GitHub..." curl -fsSL --connect-timeout 15 --max-time 300 "$BASE_URL/$script_name" -o "$temporary"; then
        rm -f "$temporary"
        return 1
    fi

    if ! is_valid_script "$temporary"; then
        rm -f "$temporary"
        return 1
    fi

    chmod 700 "$temporary"
    printf "\n  \033[1;38;2;0;245;160m▶ Ejecutando %s...\033[0m\n\n" "$script_name"
    bash "$temporary"
    local result=$?
    rm -f "$temporary"

    printf "\n"
    if (( result == 0 )); then
        info "$script_name finalizó correctamente."
    else
        error_msg "$script_name terminó con código de error ($result)."
    fi
    return "$result"
}

execute_script() {
    local primary="$1"
    local secondary="$2"
    local tertiary="$3"

    if download_and_execute "$primary"; then
        return 0
    elif [[ -n "$secondary" ]] && download_and_execute "$secondary"; then
        return 0
    elif [[ -n "$tertiary" ]] && download_and_execute "$tertiary"; then
        return 0
    else
        error_msg "No se encontró el script en el repositorio ($primary)."
        return 1
    fi
}

# ==================== HERRAMIENTAS DE INGENIERÍA PRO ====================

optimize_network_bbr() {
    prepare_for_external_script
    panel_header "OPTIMIZADOR TCP BBR & KERNEL DE RED" "◈"
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    info "Control de congestión actual: ${current_cc^^}"

    cat << 'EOF' > /etc/sysctl.d/99-ariadny-turbo.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 8192
EOF

    if run_with_spinner "Aplicando parámetros sysctl de alto rendimiento..." sysctl --system; then
        local new_cc
        new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        if [[ "$new_cc" == "bbr" ]]; then
            info "TCP BBR activado y persistente tras reinicios."
        else
            warn "El kernel actual ($new_cc) no soporta el módulo tcp_bbr, buffers aplicados."
        fi
    fi
    pause_screen
}

create_config_backup() {
    prepare_for_external_script
    panel_header "BÓVEDA DE RESPALDOS DE CONFIGURACIÓN" "◈"
    local ts archive
    ts=$(date '+%Y%m%d_%H%M%S')
    archive="$BACKUP_DIR/ariadny_backup_${ts}.tar.gz"
    local targets=()
    for dir in /etc/ariadny /etc/caddy /etc/nginx /etc/xray /usr/local/etc/xray /etc/v2ray /usr/local/etc/v2ray /etc/stunnel /etc/udp /etc/udp-custom /etc/hysteria /etc/zivpn /opt/vpn-proxy /etc/ssh/sshd_config /root/socks_config.json; do
        [[ -e "$dir" ]] && targets+=("$dir")
    done

    if (( ${#targets[@]} == 0 )); then
        warn "No se encontraron directorios de configuración para respaldar."
        pause_screen
        return
    fi

    if run_with_spinner "Empaquetando ${#targets[@]} rutas críticas..." tar -czf "$archive" "${targets[@]}"; then
        local size
        size=$(du -h "$archive" | awk '{print $1}')
        info "Respaldo creado exitosamente ($size):"
        printf "     \033[1;38;2;0;245;212m%s\033[0m\n" "$archive"
    fi
    pause_screen
}

theme_selector_menu() {
    while true; do
        prepare_for_external_script
        panel_header "SELECTOR DE TEMA VISUAL TRUECOLOR" "◈"
        printf "  \033[1;38;2;0;245;212m[01]\033[0m ◈ Cyberpunk Neon  \033[38;2;120;130;150m(Cian Eléctrico + Violeta)\033[0m\n"
        printf "  \033[1;38;2;0;255;136m[02]\033[0m ◈ Emerald Matrix  \033[38;2;120;130;150m(Verde Neón + Esmeralda)\033[0m\n"
        printf "  \033[1;38;2;255;85;115m[03]\033[0m ◈ Crimson Ops     \033[38;2;120;130;150m(Rubí + Ámbar Táctico)\033[0m\n"
        printf "  \033[1;38;2;255;215;0m[04]\033[0m ◈ Royal Gold      \033[38;2;120;130;150m(Oro Imperial + Platino)\033[0m\n"
        printf "  \033[1;38;2;255;77;109m[00]\033[0m ◂ Volver\n\n"
        printf "  \033[1;38;2;0;245;212m❯\033[0m \033[1;37mElige un tema [0-4]: \033[0m"
        local t_opt
        read -r t_opt
        t_opt=$(echo "$t_opt" | tr -d '\r\n\t ')
        case "$t_opt" in
            1|01) echo "cyberpunk" > "$THEME_FILE"; info "Tema Cyberpunk Neon aplicado."; sleep 0.6; break ;;
            2|02) echo "matrix" > "$THEME_FILE"; info "Tema Emerald Matrix aplicado."; sleep 0.6; break ;;
            3|03) echo "crimson" > "$THEME_FILE"; info "Tema Crimson Ops aplicado."; sleep 0.6; break ;;
            4|04) echo "gold" > "$THEME_FILE"; info "Tema Royal Gold aplicado."; sleep 0.6; break ;;
            0|00) break ;;
            *) warn "Opción inválida."; sleep 0.7 ;;
        esac
    done
}

# ==================== CONTROLADORES DE MENÚ ====================

caddy_menu() {
    prepare_for_external_script
    if command_exists caddy && (systemctl is-active --quiet caddy 2>/dev/null || pgrep -x caddy >/dev/null 2>&1); then
        if [[ -x /usr/local/bin/cadmin ]]; then
            /usr/local/bin/cadmin
        elif [[ -x /usr/bin/cadmin ]]; then
            /usr/bin/cadmin
        else
            panel_header "GESTIÓN DE CADDY PROXY" "◈"
            execute_script "install-caddy.sh" "caddy.sh" "Caddy.sh"
            pause_screen
        fi
    else
        panel_header "INSTALANDO CADDY PROXY DESDE GITHUB" "◈"
        execute_script "install-caddy.sh" "caddy.sh" "Caddy.sh"
        pause_screen
    fi
}

nginx_menu() {
    prepare_for_external_script
    if command_exists nginx && (systemctl is-active --quiet nginx 2>/dev/null || pgrep -x nginx >/dev/null 2>&1); then
        if [[ -x /usr/local/bin/MenuN ]]; then
            /usr/local/bin/MenuN
        elif [[ -x /usr/local/bin/menun ]]; then
            /usr/local/bin/menun
        else
            panel_header "GESTIÓN DE NGINX PROXY" "◈"
            execute_script "nginx.sh" "Nginx.sh"
            pause_screen
        fi
    else
        panel_header "INSTALANDO NGINX PROXY DESDE GITHUB" "◈"
        execute_script "nginx.sh" "Nginx.sh"
        pause_screen
    fi
}

multiplexacion_menu() {
    while true; do
        render_ui "sub_multiplexacion"
        printf "\n  \033[1;38;2;0;245;212m❯\033[0m \033[1;37mSelecciona una opción \033[38;2;120;130;150m[0-2]\033[1;37m: \033[0m"
        local sub_m
        read -r sub_m
        sub_m=$(echo "$sub_m" | tr -d '\r\n\t ')
        case "$sub_m" in
            1|01) caddy_menu ;;
            2|02) nginx_menu ;;
            0|00) break ;;
            *) warn "Opción inválida."; sleep 0.8 ;;
        esac
    done
}

v2ray_menu() {
    prepare_for_external_script
    panel_header "V2RAY / VMESS MANAGER" "◈"
    if [[ -x /usr/local/bin/menuv2ray ]]; then
        /usr/local/bin/menuv2ray
    elif [[ -x /usr/local/bin/v2ray-panel ]]; then
        /usr/local/bin/v2ray-panel
    else
        execute_script "install-v2ray.sh" "v2ray.sh" "V2ray.sh"
        pause_screen
    fi
}

xray_menu() {
    prepare_for_external_script
    if [[ -x /usr/local/bin/xray-panel ]]; then
        /usr/local/bin/xray-panel
    elif command_exists menuV2; then
        menuV2
    else
        panel_header "INSTALANDO XRAY PANEL DESDE GITHUB" "◈"
        execute_script "install-xray.sh" "xray.sh" "Xray.sh"
        pause_screen
    fi
}

sshgo_menu() {
    prepare_for_external_script
    panel_header "SSH-GO PROXY" "◈"
    execute_script "install-sshgo.sh" "sshgo.sh" "Sshgo.sh"
    pause_screen
}

badvpn_menu() {
    prepare_for_external_script
    panel_header "BADVPN UDPGW" "◈"
    execute_script "badvpn-udpgw.sh" "badvpn.sh" "Badvpn.sh"
    pause_screen
}

slowdns_menu() {
    prepare_for_external_script
    panel_header "SLOWDNS / DNSTT PANEL" "◈"
    execute_script "slowdns.sh" "Slowdns.sh"
    pause_screen
}

ssl_menu() {
    prepare_for_external_script
    panel_header "CERTIFICADO SSL / STUNNEL" "◈"
    execute_script "ssl.sh" "Ssl.sh"
    pause_screen
}

mas_opciones_menu() {
    while true; do
        render_ui "sub_mas_opciones"
        printf "\n  \033[1;38;2;0;245;212m❯\033[0m \033[1;37mSelecciona una opción \033[38;2;120;130;150m[0-6]\033[1;37m: \033[0m"
        local sub_op
        read -r sub_op
        sub_op=$(echo "$sub_op" | tr -d '\r\n\t ')
        case "$sub_op" in
            1|01) optimize_network_bbr ;;
            2|02) render_ui "speedtest"; pause_screen ;;
            3|03) create_config_backup ;;
            4|04) theme_selector_menu ;;
            5|05)
                prepare_for_external_script
                panel_header "ACTUALIZACIÓN DE ARIADNY PANEL" "◈"
                if download_to_path "$CORE_PANEL_PATH" "menu.sh"; then
                    info "Panel actualizado. Reiniciando..."
                    sleep 1
                    exec bash "$CORE_PANEL_PATH" --no-anim
                fi
                pause_screen
                ;;
            6|06)
                prepare_for_external_script
                panel_header "LIMPIEZA DE MEMORIA Y LOGS" "◈"
                run_with_spinner "Sincronizando discos y liberando caché RAM..." bash -c "sync && echo 3 > /proc/sys/vm/drop_caches"
                rm -f "$NET_CACHE_FILE"
                : > "$LOG_FILE" 2>/dev/null
                info "Caché RAM liberada, IP refrescada y logs limpios."
                pause_screen
                ;;
            0|00) break ;;
            *) warn "Opción inválida."; sleep 0.8 ;;
        esac
    done
}

firewall_menu() {
    prepare_for_external_script
    panel_header "FIREWALL SYSTEM" "❖"
    execute_script "firewall.sh" "Firewall.sh"
    pause_screen
}

udp_menu() {
    prepare_for_external_script
    panel_header "UDP PANEL" "◈"
    execute_script "Udp.sh" "udp.sh" "install-udp.sh"
    pause_screen
}

rust_menu() {
    prepare_for_external_script
    panel_header "SOCKS PROXY RUST" "◈"
    execute_script "rust.sh" "Rust.sh"
    pause_screen
}

python_menu() {
    prepare_for_external_script
    panel_header "SOCKS PROXY PYTHON" "◈"
    if [[ -x /usr/local/bin/P-Proxy ]]; then
        /usr/local/bin/P-Proxy
    elif [[ -x /usr/local/bin/python-proxy ]]; then
        /usr/local/bin/python-proxy
    else
        execute_script "Python.sh" "python.sh" "proxy.sh"
    fi
    pause_screen
}

ssh_panel_menu() {
    prepare_for_external_script
    local ssh_panel="/usr/local/bin/sshpanel.sh"
    panel_header "SSH PANEL MANAGER" "◈"
    if download_to_path "$ssh_panel" "sshpanel.sh" "Sshpanel.sh" "ssh-panel.sh"; then
        bash "$ssh_panel"
    fi
    pause_screen
}

configure_ssh() {
    prepare_for_external_script
    panel_header "CONFIGURACIÓN DE SSH" "❖"
    execute_script "ssh.sh" "Ssh.sh"
    pause_screen
}

monitor_menu() {
    render_ui "live_monitor"
}

status_menu() {
    while true; do
        render_ui "status_table"
        printf "\n  \033[38;2;120;130;150mEscribe el número de servicio para \033[1;38;2;0;245;212mreiniciarlo\033[0m\033[38;2;120;130;150m o \033[1;37m[ENTER]\033[38;2;120;130;150m para volver: \033[0m"
        local svc_opt
        read -r svc_opt
        svc_opt=$(echo "$svc_opt" | tr -d '\r\n\t ')
        [[ -z "$svc_opt" || "$svc_opt" == "0" || "$svc_opt" == "00" ]] && break

        local svc_map=("" "caddy" "nginx" "v2ray" "xray" "vpn-proxy" "udp-custom" "badvpn" "socks-rust" "python-proxy" "slowdns" "stunnel4" "ssh")
        if [[ "$svc_opt" =~ ^[0-9]+$ ]]; then
            local idx=$((10#$svc_opt))
            if (( idx >= 1 && idx <= 12 )); then
                local target="${svc_map[$idx]}"
                printf "\n"
                run_with_spinner "Reiniciando servicio $target..." systemctl restart "$target"
                sleep 0.8
                continue
            fi
        fi
        warn "Número de servicio inválido."
        sleep 0.7
    done
}

# ==================== SOPORTE DE ARGUMENTOS CLI ====================

handle_cli_args() {
    case "${1:-}" in
        --status|-s)
            render_ui "status_table"
            exit 0
            ;;
        --monitor|-m)
            render_ui "live_monitor"
            exit 0
            ;;
        --speedtest|-t)
            render_ui "speedtest"
            exit 0
            ;;
        --backup|-b)
            create_config_backup
            exit 0
            ;;
        --update|-u)
            download_to_path "$CORE_PANEL_PATH" "menu.sh"
            exit $?
            ;;
        --help|-h)
            printf "\n\033[1;38;2;0;245;212mARIADNY MASTER PANEL %s - Comandos CLI:\033[0m\n" "$VERSION"
            printf "  menu             Abre la interfaz interactiva completa\n"
            printf "  menu --status    Muestra la tabla de diagnóstico de servicios\n"
            printf "  menu --monitor   Abre el monitor de red y CPU en tiempo real\n"
            printf "  menu --speedtest Ejecuta test de velocidad y latencia Cloudflare\n"
            printf "  menu --backup    Crea un respaldo comprimido de configuraciones\n"
            printf "  menu --update    Actualiza el panel desde GitHub\n\n"
            exit 0
            ;;
    esac
}

# ==================== BUCLE PRINCIPAL ====================

main_menu() {
    while true; do
        render_ui "full"
        printf "\n  \033[1;38;2;0;245;212m❯\033[0m \033[1;37mSelecciona una opción \033[38;2;120;130;150m[0-16]\033[1;37m: \033[0m"
        local option
        read -r option
        option=$(echo "$option" | tr -d '\r\n\t ')

        case "$option" in
            1|01) multiplexacion_menu ;;
            2|02) v2ray_menu ;;
            3|03) sshgo_menu ;;
            4|04) xray_menu ;;
            5|05) udp_menu ;;
            6|06) rust_menu ;;
            7|07) python_menu ;;
            8|08) ssh_panel_menu ;;
            9|09) badvpn_menu ;;
            10)   slowdns_menu ;;
            11)   ssl_menu ;;
            12)   mas_opciones_menu ;;
            13)   firewall_menu ;;
            14)   configure_ssh ;;
            15)   monitor_menu ;;
            16)   status_menu ;;
            0|00)
                clear_screen
                printf "\n  \033[1;38;2;0;245;212m◈ Ariadny Master Panel %s\033[0m \033[38;2;200;210;225m— Sesión finalizada.\033[0m\n\n" "$VERSION"
                exit 0
                ;;
            *)
                warn "Opción inválida. Elige un número entre 0 y 16."
                sleep 0.8
                ;;
        esac
    done
}

# ==================== PUNTO DE ENTRADA ====================

require_root
install_dependencies
setup_menu_shortcut
handle_cli_args "$@"

if [[ "${1:-}" != "--no-anim" ]]; then
    boot_sequence
fi

main_menu "$@"
