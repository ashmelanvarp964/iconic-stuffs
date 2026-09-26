#!/usr/bin/env bash
#
#   RealFetch — a tiny, hackable system-info fetch tool
#   (neofetch / fastfetch style, pure bash, no deps beyond coreutils)
#   made by Iconic. Asnorith Development
#
#   Usage:
#     realfetch                run with defaults
#     realfetch --no-logo       skip the OS ASCII logo
#     realfetch --no-banner     skip the RealFetch wordmark banner
#     realfetch --no-virt       skip the virtualization/authenticity check
#     realfetch --config PATH   use a custom config file
#     realfetch --help          show usage
#
#   Config file (~/.config/realfetch/config or ~/.realfetchrc), all optional:
#     REALFETCH_ACCENT=36        # any ANSI color code
#     REALFETCH_SHOW_LOGO=1
#     REALFETCH_SHOW_BANNER=1
#     REALFETCH_SHOW_VIRT=1
#
set -o pipefail

VERSION="2.2.0"

# ---------- defaults (overridable via config / flags) ----------
SHOW_LOGO=1
SHOW_BANNER=1
SHOW_VIRT=1
ACCENT=36     # cyan
CONFIG_FILE=""

for f in "$HOME/.config/realfetch/config" "$HOME/.realfetchrc"; do
    [ -r "$f" ] && CONFIG_FILE="$f"
done

# ---------- arg parsing ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --no-logo)    SHOW_LOGO=0 ;;
        --no-banner)  SHOW_BANNER=0 ;;
        --no-virt)    SHOW_VIRT=0 ;;
        --config)     CONFIG_FILE="$2"; shift ;;
        --version)    echo "RealFetch v$VERSION"; exit 0 ;;
        --help|-h)
            sed -n '2,19p' "$0" | sed 's/^#//'
            exit 0
            ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
    shift
done

[ -n "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] && source "$CONFIG_FILE"

# ---------- colors ----------
RESET="\e[0m"
BOLD="\e[1m"
C1="\e[1;${ACCENT}m"    # accent (labels)
C2="\e[0;37m"            # values
LOGO_COLOR="\e[1;35m"
WARN="\e[1;33m"
GOOD="\e[1;32m"
BAD="\e[1;31m"

# ---------- helpers ----------
has() { command -v "$1" &>/dev/null; }

get_os() {
    if [ -f /etc/os-release ]; then
        # subshell so we don't pollute the parent shell with os-release vars
        (
            . /etc/os-release
            if [ -n "${PRETTY_NAME:-}" ]; then
                echo "$PRETTY_NAME"
            elif [ -n "${NAME:-}" ]; then
                echo "${NAME}${VERSION_ID:+ $VERSION_ID}"
            else
                echo "Linux"
            fi
        )
    elif [ "$(uname)" = "Darwin" ]; then
        echo "macOS $(sw_vers -productVersion 2>/dev/null || true)"
    else
        uname -s
    fi
}

get_distro_id() {
    if [ -f /etc/os-release ]; then
        ( . /etc/os-release; echo "${ID:-linux}" )
    else
        echo "linux"
    fi
}

get_kernel() { uname -sr; }
get_arch()   { uname -m; }
get_host()   { hostname 2>/dev/null || cat /etc/hostname 2>/dev/null; }

get_uptime() {
    if [ -r /proc/uptime ]; then
        local secs; secs=$(cut -d. -f1 /proc/uptime)
        local d=$((secs/86400)) h=$(( (secs%86400)/3600 )) m=$(( (secs%3600)/60 ))
        local out=""
        [ "$d" -gt 0 ] && out+="${d}d "
        [ "$h" -gt 0 ] && out+="${h}h "
        out+="${m}m"
        echo "$out"
    else
        uptime -p 2>/dev/null | sed 's/up //'
    fi
}

get_shell() { basename "${SHELL:-unknown}"; }

get_terminal() {
    echo "${TERM_PROGRAM:-${TERM:-unknown}}"
}

get_wm() {
    echo "${XDG_CURRENT_DESKTOP:-${DESKTOP_SESSION:-N/A}}"
}

get_pkgs() {
    if has dpkg; then echo "$(dpkg -l 2>/dev/null | grep -c '^ii') (dpkg)"
    elif has rpm; then echo "$(rpm -qa 2>/dev/null | wc -l) (rpm)"
    elif has pacman; then echo "$(pacman -Qq 2>/dev/null | wc -l) (pacman)"
    elif has brew; then echo "$(brew list 2>/dev/null | wc -l) (brew)"
    elif has apk; then echo "$(apk info 2>/dev/null | wc -l) (apk)"
    else echo "unknown"; fi
}

get_cpu() {
    if [ -r /proc/cpuinfo ]; then
        grep -m1 'model name' /proc/cpuinfo | sed 's/model name\s*: //'
    elif [ "$(uname)" = "Darwin" ]; then
        sysctl -n machdep.cpu.brand_string
    else
        uname -p
    fi
}

get_cpu_cores() {
    if has nproc; then
        echo "$(nproc) threads"
    elif [ -r /proc/cpuinfo ]; then
        echo "$(grep -c ^processor /proc/cpuinfo) threads"
    fi
}

get_gpu() {
    if has lspci; then
        lspci 2>/dev/null | grep -Ei 'vga|3d|display' | head -1 | sed 's/^.*: //'
    elif [ "$(uname)" = "Darwin" ] && has system_profiler; then
        system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2; exit}'
    else
        echo "N/A"
    fi
}

get_mem() {
    if [ -r /proc/meminfo ]; then
        local total avail used
        total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        used=$((total - avail))
        printf "%dMiB / %dMiB (%d%%)\n" $((used/1024)) $((total/1024)) $(( used*100/total ))
    elif [ "$(uname)" = "Darwin" ]; then
        printf "%d MiB total\n" $(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
    else
        echo "unknown"
    fi
}

get_swap() {
    if [ -r /proc/meminfo ]; then
        local total free used
        total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
        free=$(awk '/SwapFree/ {print $2}' /proc/meminfo)
        [ "$total" -eq 0 ] && { echo "none"; return; }
        used=$((total - free))
        printf "%dMiB / %dMiB\n" $((used/1024)) $((total/1024))
    else
        echo "N/A"
    fi
}

get_disk() {
    df -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}'
}

get_load() {
    if [ -r /proc/loadavg ]; then
        awk '{print $1", "$2", "$3" (1m, 5m, 15m)"}' /proc/loadavg
    fi
}

get_procs() {
    if has ps; then ps -e --no-headers 2>/dev/null | wc -l; fi
}

get_resolution() {
    if has xrandr && [ -n "$DISPLAY" ]; then
        xrandr --current 2>/dev/null | grep '\*' | awk '{print $1}' | paste -sd ', '
    else
        echo "N/A"
    fi
}

get_battery() {
    local bat="/sys/class/power_supply/BAT0"
    [ -d "$bat" ] || bat="/sys/class/power_supply/BAT1"
    if [ -d "$bat" ]; then
        local cap status
        cap=$(cat "$bat/capacity" 2>/dev/null)
        status=$(cat "$bat/status" 2>/dev/null)
        [ -n "$cap" ] && echo "${cap}% [${status}]"
    fi
}

get_local_ip() {
    if has ip; then
        ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'
    elif has ifconfig; then
        ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '127.0.0.1' | head -1
    fi
}

get_user_host() { echo "${USER:-$(whoami)}@$(get_host)"; }

# ---------- virtualization / CPU authenticity check ----------
# Answers: is this bare metal, or a VM/container? Is the CPU info consistent
# with what it claims to be, or does something look spoofed/inconsistent?
check_virtualization() {
    local method="" virt_type="" verdict="" detail=""

    if has systemd-detect-virt; then
        virt_type=$(systemd-detect-virt 2>/dev/null)
        method="systemd-detect-virt"
    fi

    # Cross-check against lscpu's hypervisor field
    local lscpu_hv=""
    if has lscpu; then
        lscpu_hv=$(lscpu 2>/dev/null | awk -F': *' '/^Hypervisor vendor/{print $2}')
    fi

    # Cross-check against the CPU 'hypervisor' flag bit (set by real hardware
    # virtualization; a genuine bare-metal CPU normally won't have this)
    local flag_present=0
    if [ -r /proc/cpuinfo ] && grep -qw hypervisor /proc/cpuinfo; then
        flag_present=1
    fi

    # DMI/BIOS strings often reveal the hypervisor too (needs root for some fields)
    local dmi_vendor=""
    if has dmidecode; then
        dmi_vendor=$(dmidecode -s system-manufacturer 2>/dev/null)
    elif [ -r /sys/class/dmi/id/sys_vendor ]; then
        dmi_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
    fi

    # ---- decide verdict ----
    if [ "$virt_type" = "none" ] && [ "$flag_present" -eq 0 ] && [ -z "$lscpu_hv" ]; then
        verdict="${GOOD}Bare metal${RESET}"
        detail="no hypervisor signals found — consistent with physical hardware"
    elif [ -n "$virt_type" ] && [ "$virt_type" != "none" ]; then
        verdict="${WARN}Virtual Machine${RESET} (${virt_type})"
        detail="reported by ${method:-kernel}"
        [ -n "$lscpu_hv" ] && detail+="; lscpu hypervisor vendor: ${lscpu_hv}"
    elif [ "$flag_present" -eq 1 ] || [ -n "$lscpu_hv" ]; then
        verdict="${WARN}Virtual Machine${RESET}"
        detail="CPU hypervisor flag / lscpu vendor present (${lscpu_hv:-flag only})"
    else
        verdict="${GOOD}Bare metal${RESET}"
        detail="no hypervisor signals found"
    fi

    # Consistency check: does the reported CPU model look plausible?
    # (a common spoof/mismatch signal: cpuinfo model name doesn't match lscpu's)
    local cpuinfo_model lscpu_model consistency="${GOOD}consistent${RESET}"
    cpuinfo_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/model name\s*: //')
    lscpu_model=$(lscpu 2>/dev/null | awk -F': *' '/^Model name/{print $2}')
    if [ -n "$cpuinfo_model" ] && [ -n "$lscpu_model" ] && [ "$cpuinfo_model" != "$lscpu_model" ]; then
        consistency="${BAD}mismatch between /proc/cpuinfo and lscpu — possibly spoofed${RESET}"
    fi

    echo -e "  ${BOLD}${C1}Environment:${RESET}   $verdict"
    echo -e "  ${BOLD}${C1}Detail:${RESET}        $detail"
    [ -n "$dmi_vendor" ] && echo -e "  ${BOLD}${C1}DMI vendor:${RESET}    $dmi_vendor"
    echo -e "  ${BOLD}${C1}CPU consistency:${RESET} $consistency"
}

# ---------- ASCII logos (auto-picked by distro, override with LOGO array) ----------
pick_logo() {
    local id; id=$(get_distro_id)

    # Color helpers (real classic colors)
    local o="\e[1;38;5;202m"   # Ubuntu orange
    local r="\e[1;31m"         # red
    local c="\e[1;36m"         # cyan
    local b="\e[1;34m"         # blue
    local w="\e[1;37m"         # white
    local y="\e[1;33m"         # yellow
    local g="\e[1;32m"         # green
    local m="\e[1;35m"         # magenta
    local x="\e[0m"            # reset

    # Default: no forced single color (logos carry their own colors)
    LOGO_COLOR=""

    case "$id" in
        ubuntu|pop|elementary|zorin|neon|kubuntu|xubuntu|lubuntu|ubuntu-mate|ubuntu-budgie|linuxmint|mint)
            # Classic multi-color Ubuntu logo (real neofetch style)
            LOGO=(
"${o}             .-/+oossssoo+/-.${x}"
"${o}         \`:+ssssssssssssssssss+:\`${x}"
"${o}       -+ssssssssssssssssssyyssss+-${x}"
"${o}     .ossssssssssssssssssdMMMNysssso.${x}"
"${o}    /ssssssssssshdmmNNmmyNMMMMhssssss/${x}"
"${o}   +ssssssssshmydMMMMMMMNddddyssssssss+${x}"
"${o}  /sssssssshNMMMyhhyyyyhmNMMMNhssssssss/${x}"
"${o} .ssssssssdMMMNhsssssssssshNMMMdssssssss.${x}"
"${o} +sssshhhyNMMNyssssssssssssyNMMMysssssss+${x}"
"${o} ossyNMMMNyMMhsssssssssssssshmmmhssssssso${x}"
"${o} ossyNMMMNyMMhsssssssssssssshmmmhssssssso${x}"
"${o} +sssshhhyNMMNyssssssssssssyNMMMysssssss+${x}"
"${o} .ssssssssdMMMNhsssssssssshNMMMdssssssss.${x}"
"${o}  /sssssssshNMMMyhhyyyyhdNMMMNhssssssss/${x}"
"${o}   +sssssssssdmydMMMMMMMMddddyssssssss+${x}"
"${o}    /ssssssssssshdmNNNNmyNMMMMhssssss/${x}"
"${o}     .ossssssssssssssssssdMMMNysssso.${x}"
"${o}       -+sssssssssssssssssyyyssss+-${x}"
"${o}         \`:+ssssssssssssssssss+:\`${x}"
"${o}             .-/+oossssoo+/-.${x}"
            ) ;;
        debian|raspbian|kali|parrot|devuan)
            # Classic red Debian swirl
            LOGO=(
"${r}       _,met\$\$\$\$\$gg.${x}"
"${r}    ,g\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$P.${x}"
"${r}  ,g\$\$P\"\"       \"\"\"Y\$\$.\".${x}"
"${r} ,\$\$P'              \`\$\$\$.${x}"
"${r}',\$\$P       ,ggs.     \`\$\$b:${x}"
"${r}'d\$\$'     ,\$P\"'   .    \$\$\$${x}"
"${r} \$\$P      d\$'     ,    \$\$P${x}"
"${r} \$\$:      \$\$.   -    ,d\$\$'${x}"
"${r} \$\$;      Y\$b._   _,d\$P'${x}"
"${r} Y\$\$.    \`.\"\`\"Y\$\$\$\$P\"'${x}"
"${r} \`\$\$b      \"-.__${x}"
"${r}  \`Y\$\$${x}"
"${r}   \`Y\$\$.${x}"
"${r}     \`\$\$b.${x}"
"${r}       \`Y\$\$b.${x}"
"${r}          \`\"Y\$b._${x}"
"${r}              \`\"\"\"\"${x}"
            ) ;;
        arch)
            # Classic cyan Arch logo
            LOGO=(
"${c}                   -\`${x}"
"${c}                  .o+\`${x}"
"${c}                 \`ooo/${x}"
"${c}                \`+oooo:${x}"
"${c}               \`+oooooo:${x}"
"${c}               -+oooooo+:${x}"
"${c}             \`/:-:++oooo+:${x}"
"${c}            \`/++++/+++++++:${x}"
"${c}           \`/++++++++++++++:${x}"
"${c}          \`/+++ooooooooooooo/\`${x}"
"${c}         ./ooosssso++osssssso+\`${x}"
"${c}        .oossssso-\`\`\`\`/ossssss+\`${x}"
"${c}       -osssssso.      :ssssssso.${x}"
"${c}      :osssssss/        osssso+++.${x}"
"${c}     /ossssssss/        +ssssooo/-${x}"
"${c}   \`/ossssso+/:-        -:/+osssso+-${x}"
"${c}  \`+sso+:-\`                 \`.-/+oso:${x}"
"${c} \`++:.                           \`-/+/${x}"
"${c} .\`                                 \`/${x}"
            ) ;;
        fedora)
            # Classic blue Fedora logo
            LOGO=(
"${b}          /:-------------:\\${x}"
"${b}       :-------------------::${x}"
"${b}     :-----------/shhOHbmp---:\\${x}"
"${b}   /-----------omMMMNNNMMD  ---:${x}"
"${b}  :-----------sMMMMNM++++-\`    .---:${x}"
"${b} :-----------:MMMdP-------\`\-\    -/${x}"
"${b}|-----------:dMM+-----------------:${x}"
"${b}:-----------:MM+:-------------------\\${x}"
"${b}:-----------:NMM+-----.+----------:\\${x}"
"${b}:-----------:++NMMd/-------------:\\${x}"
"${b}:----------:ohNMMd/:-------------:\\${x}"
"${b}:----------:sNMMMMMho:-------------\\${x}"
"${b}:----------:sNMMMMMMMN/------------:\\${x}"
"${b}:----------:sNMMMMMMMN/------------:\\${x}"
"${b}:----------:sNMMMMMho:-------------:\\${x}"
"${b}:----------:ohNMMd/:---------------:\\${x}"
"${b}:----------:++NMMd/-----------------\\${x}"
"${b}:-----------:NM+:-------------------\\${x}"
"${b}|-----------:dMM+-------------------/${x}"
"${b} :-----------:MMMdP-------\`\-\    -/${x}"
"${b}  :-----------sMMMMNM++++-\`    .---:${x}"
"${b}   /-----------omMMMNNNMMD  ---:${x}"
"${b}     :-----------/shhOHbmp---:\\${x}"
"${b}       :-------------------::${x}"
"${b}          \\:-------------:/${x}"
            ) ;;
        *)
            # Generic fallback
            LOGO_COLOR="$y"
            LOGO=(
"               .-\"\"\"\"\"-."
"             .'         '."
"            /   .-\"-.    \\"
"           |   /  o  \\    |"
"           |   \\     /    |"
"            \\   '---'    /"
"             '.         .'"
"           .--'\"\"\"\"\"'--."
"          /    #  #      \\"
"         |   #      #     |"
"         |  #   ##   #    |"
"         |   #      #     |"
"          \\    #  #      /"
"           '-._______.-'"
            ) ;;
    esac
}

pick_logo

# ---------- RealFetch wordmark banner ----------
print_banner() {
    local B="\e[1;${ACCENT}m"
    echo -e "${B}"
    cat <<'EOF'
 ____             _ _____    _       _
|  _ \ ___  __ _ | |  ___|__| |_ ___| |__
| |_) / _ \/ _` || | |_ / _ \ __/ __| '_ \
|  _ <  __/ (_| || |  _|  __/ || (__| | | |
|_| \_\___|\__,_||_|_|  \___|\__\___|_| |_|
EOF
    echo -e "${RESET}"
    echo -e "  ${C2}made by Iconic. Asnorith Development${RESET}"
}

# ---------- build info lines ----------
declare -a LABELS=() VALUES=()
add() { LABELS+=("$1"); VALUES+=("$2"); }

add "OS"          "$(get_os)"
add "Kernel"      "$(get_kernel)"
add "Arch"        "$(get_arch)"
add "Host"        "$(get_host)"
add "Uptime"      "$(get_uptime)"
add "Shell"       "$(get_shell)"
add "Terminal"    "$(get_terminal)"
add "WM/DE"       "$(get_wm)"
add "Packages"    "$(get_pkgs)"
add "Resolution"  "$(get_resolution)"
add "CPU"         "$(get_cpu) ($(get_cpu_cores))"
add "GPU"         "$(get_gpu)"
add "Memory"      "$(get_mem)"
add "Swap"        "$(get_swap)"
add "Disk (/)"    "$(get_disk)"
add "Load Avg"    "$(get_load)"
add "Processes"   "$(get_procs)"
BATTERY="$(get_battery)"
[ -n "$BATTERY" ] && add "Battery" "$BATTERY"
IP="$(get_local_ip)"
[ -n "$IP" ] && add "Local IP" "$IP"

# ---------- render ----------
title="$(get_user_host)"
sep=$(printf '%*s' "${#title}" '' | tr ' ' '-')

# compute widest logo line (strip ANSI color codes for correct width)
logo_width=0
if [ "$SHOW_LOGO" -eq 1 ] && [ ${#LOGO[@]} -gt 0 ]; then
    for _line in "${LOGO[@]}"; do
        # remove ANSI escapes to measure visible width
        clean=$(printf '%s' "$_line" | sed 's/\x1b\[[0-9;]*m//g')
        [ ${#clean} -gt "$logo_width" ] && logo_width=${#clean}
    done
fi
[ "$logo_width" -lt 30 ] && logo_width=30
logo_pad=$((logo_width + 2))

echo
[ "$SHOW_BANNER" -eq 1 ] && print_banner
if [ "$SHOW_LOGO" -eq 1 ]; then
    max_lines=$(( ${#LOGO[@]} > ${#LABELS[@]}+2 ? ${#LOGO[@]} : ${#LABELS[@]}+2 ))
    for ((i=0; i<max_lines; i++)); do
        logo_line="${LOGO[$i]:-}"
        if [ "$i" -eq 0 ]; then info_line="${BOLD}${C1}${title}${RESET}"
        elif [ "$i" -eq 1 ]; then info_line="${C2}${sep}${RESET}"
        else
            idx=$((i-2))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#LABELS[@]}" ]; then
                info_line="${BOLD}${C1}${LABELS[$idx]}:${RESET} ${C2}${VALUES[$idx]}${RESET}"
            else
                info_line=""
            fi
        fi
        # If logo already has color codes, print as-is; otherwise apply LOGO_COLOR
        if [ -n "$LOGO_COLOR" ]; then
            printf "${LOGO_COLOR}%-${logo_pad}s${RESET}  %b\n" "$logo_line" "$info_line"
        else
            # pad manually for multi-color logos
            clean=$(printf '%s' "$logo_line" | sed 's/\x1b\[[0-9;]*m//g')
            pad=$((logo_pad - ${#clean}))
            [ $pad -lt 0 ] && pad=0
            printf "%b%*s  %b\n" "$logo_line" "$pad" "" "$info_line"
        fi
    done
else
    echo -e "${BOLD}${C1}${title}${RESET}"
    echo -e "${C2}${sep}${RESET}"
    for i in "${!LABELS[@]}"; do
        echo -e "${BOLD}${C1}${LABELS[$i]}:${RESET} ${C2}${VALUES[$i]}${RESET}"
    done
fi
echo

# color palette row
printf "  "
for c in 0 1 2 3 4 5 6 7; do printf "\e[4%sm   \e[0m" "$c"; done
echo
printf "  "
for c in 0 1 2 3 4 5 6 7; do printf "\e[10%sm   \e[0m" "$c"; done
echo
echo

# virtualization / authenticity report
if [ "$SHOW_VIRT" -eq 1 ]; then
    echo -e "${BOLD}${C1}── System Authenticity Check ──${RESET}"
    check_virtualization
    echo
fi

# branding (shown when banner was skipped)
if [ "$SHOW_BANNER" -eq 0 ]; then
    echo -e "  ${C2}made by Iconic. Asnorith Development${RESET}"
    echo
fi
