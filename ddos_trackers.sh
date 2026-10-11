#!/usr/bin/env bash
# ============================================================
#  LUMACLOUD  •  ADVANCED DDoS & HIGH-LOAD DETECTOR v2.2
#  Fixed menu reliability + better error handling
# ============================================================

set -uo pipefail   # removed -e so menu doesn't die on missing tools

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

print_logo() {
  clear
  echo -e "${CYAN}${BOLD}"
  cat << 'EOF'
 ██╗     ██╗   ██╗███╗   ███╗ █████╗  ██████╗██╗      ██████╗ ██╗   ██╗██████╗ 
 ██║     ██║   ██║████╗ ████║██╔══██╗██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗
 ██║     ██║   ██║██╔████╔██║███████║██║     ██║     ██║   ██║██║   ██║██║  ██║
 ██║     ██║   ██║██║╚██╔╝██║██╔══██║██║     ██║     ██║   ██║██║   ██║██║  ██║
 ███████╗╚██████╔╝██║ ╚═╝ ██║██║  ██║╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝
 ╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝ 
EOF
  echo -e "${PURPLE}     ⚡  ADVANCED DDoS • LOAD • TELEMETRY ENGINE  v2.2  ⚡${NC}"
  echo -e "${GRAY}              LumaCloud Security Scanner  •  Real-time Analysis${NC}"
  echo
}

check_and_offer_install() {
  local missing=()
  for cmd in ss iftop nload btop awk grep ip; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    echo -e "${YELLOW}[!] Missing tools: ${missing[*]}${NC}"
    read -rp "Auto-install missing packages? (y/N): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      if command -v apt >/dev/null; then
        sudo apt update -qq && sudo apt install -y iftop nload btop iproute2 procps
      elif command -v yum >/dev/null || command -v dnf >/dev/null; then
        sudo yum install -y iftop nload btop iproute || true
      else
        echo -e "${RED}Unsupported package manager. Install manually.${NC}"
      fi
    fi
  fi
}

get_default_iface() {
  ip route 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0"
}

format_bytes() {
  local b=${1:-0}
  if ((b >= 1073741824)); then awk -v b="$b" 'BEGIN{printf "%.2f GB/s", b/1073741824}'
  elif ((b >= 1048576)); then awk -v b="$b" 'BEGIN{printf "%.1f MB/s", b/1048576}'
  elif ((b >= 1024)); then awk -v b="$b" 'BEGIN{printf "%.1f KB/s", b/1024}'
  else echo "${b} B/s"; fi
}

safe_num() { echo "${1:-0}" | grep -E '^[0-9]+$' || echo 0; }

collect_stats() {
  local iface
  iface=$(get_default_iface)

  local rx1 tx1 rx2 tx2
  read -r _ rx1 _ _ _ _ _ _ _ tx1 _ < <(grep -w "$iface" /proc/net/dev 2>/dev/null | awk '{print $2,$10}' || echo "0 0")
  sleep 2
  read -r _ rx2 _ _ _ _ _ _ _ tx2 _ < <(grep -w "$iface" /proc/net/dev 2>/dev/null | awk '{print $2,$10}' || echo "0 0")

  rx1=$(safe_num "$rx1"); tx1=$(safe_num "$tx1")
  rx2=$(safe_num "$rx2"); tx2=$(safe_num "$tx2")
  local rx_bps=$(( (rx2 - rx1) / 2 ))
  local tx_bps=$(( (tx2 - tx1) / 2 ))
  ((rx_bps < 0)) && rx_bps=0
  ((tx_bps < 0)) && tx_bps=0

  local estab syn_recv time_wait close_wait unique_ips
  estab=$(ss -ant 2>/dev/null | grep -c ESTAB || echo 0)
  syn_recv=$(ss -ant 2>/dev/null | grep -c SYN-RECV || echo 0)
  time_wait=$(ss -ant 2>/dev/null | grep -c TIME-WAIT || echo 0)
  close_wait=$(ss -ant 2>/dev/null | grep -c CLOSE-WAIT || echo 0)
  unique_ips=$(ss -tn 2>/dev/null | awk 'NR>1 {print $5}' | cut -d: -f1 | sort -u | wc -l || echo 0)

  estab=$(safe_num "$estab")
  syn_recv=$(safe_num "$syn_recv")
  time_wait=$(safe_num "$time_wait")
  close_wait=$(safe_num "$close_wait")
  unique_ips=$(safe_num "$unique_ips")

  local load1 cpus
  read -r load1 _ _ < /proc/loadavg 2>/dev/null || load1=0
  cpus=$(nproc 2>/dev/null || echo 1)
  cpus=$(safe_num "$cpus")
  ((cpus == 0)) && cpus=1

  echo "$iface|$rx_bps|$tx_bps|$estab|$syn_recv|$time_wait|$close_wait|$unique_ips|$load1|$cpus"
}

top_source_ips() {
  echo -e "\n${CYAN}${BOLD}TOP SOURCE IPs (by connection count)${NC}"
  ss -tn 2>/dev/null | awk 'NR>1 {print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr | head -15 | \
  while read -r count ip; do
    count=$(safe_num "$count")
    local color="$GREEN"
    ((count > 100)) && color="$YELLOW"
    ((count > 500)) && color="$RED"
    printf "  ${color}%-8s${NC} %s\n" "$count" "$ip"
  done || echo -e "  ${GRAY}No data${NC}"
}

top_dest_ports() {
  echo -e "\n${CYAN}${BOLD}TOP DESTINATION PORTS${NC}"
  ss -tn 2>/dev/null | awk 'NR>1 {print $4}' | cut -d: -f2 | sort | uniq -c | sort -nr | head -10 | \
  while read -r count port; do
    printf "  ${YELLOW}%-6s${NC} connections → port %s\n" "$count" "$port"
  done || echo -e "  ${GRAY}No data${NC}"
}

analyze() {
  local data
  data=$(collect_stats)
  IFS='|' read -r iface rx_bps tx_bps estab syn_recv time_wait close_wait unique_ips load1 cpus <<< "$data"

  local score=0
  local reasons=()
  local severity="LOW"

  ((estab > 15000)) && { reasons+=("CRITICAL: Extremely high ESTABLISHED ($estab)"); score=$((score+5)); }
  ((estab > 8000))  && { reasons+=("Very high ESTABLISHED connections ($estab)"); score=$((score+3)); }
  ((estab > 4000))  && { reasons+=("Elevated ESTABLISHED ($estab)"); score=$((score+1)); }

  ((syn_recv > 500)) && { reasons+=("CRITICAL SYN-RECV flood: $syn_recv"); score=$((score+6)); }
  ((syn_recv > 150)) && { reasons+=("High SYN-RECV (possible SYN flood): $syn_recv"); score=$((score+3)); }

  ((time_wait > 10000)) && { reasons+=("Massive TIME-WAIT ($time_wait)"); score=$((score+2)); }
  ((unique_ips > 5000)) && { reasons+=("Very high unique remote IPs: $unique_ips"); score=$((score+4)); }
  ((unique_ips > 2000)) && { reasons+=("High unique IPs: $unique_ips"); score=$((score+2)); }

  ((rx_bps > 200000000)) && { reasons+=("CRITICAL inbound bandwidth"); score=$((score+5)); }
  ((rx_bps > 80000000))  && { reasons+=("Very high inbound traffic"); score=$((score+3)); }
  ((rx_bps > 30000000))  && { reasons+=("Elevated inbound traffic"); score=$((score+1)); }

  local load_ratio="0.00"
  if ((cpus > 0)); then
    load_ratio=$(awk -v l="$load1" -v c="$cpus" 'BEGIN{printf "%.2f", (l+0)/(c+0)}' 2>/dev/null || echo "0.00")
  fi
  awk -v r="$load_ratio" 'BEGIN{exit !(r+0 > 2.0)}' 2>/dev/null && {
    reasons+=("System overloaded (load/core = $load_ratio)")
    score=$((score+2))
  } || true

  if ((score >= 10)); then severity="CRITICAL"
  elif ((score >= 6)); then severity="HIGH"
  elif ((score >= 3)); then severity="MEDIUM"
  else severity="LOW"; fi

  echo -e "\n${BOLD}${CYAN}┌─ DEEP ANALYSIS RESULT ───────────────────────────────────┐${NC}"
  case "$severity" in
    CRITICAL) echo -e "${RED}│  🚨  CRITICAL — Strong DDoS / Attack indicators          │${NC}" ;;
    HIGH)     echo -e "${RED}│  ⚠   HIGH RISK — Likely under attack or extreme load    │${NC}" ;;
    MEDIUM)   echo -e "${YELLOW}│  ⚡  MEDIUM — Elevated activity (monitor closely)       │${NC}" ;;
    *)        echo -e "${GREEN}│  ✓   LOW — No significant DDoS indicators               │${NC}" ;;
  esac
  echo -e "${CYAN}└──────────────────────────────────────────────────────────┘${NC}"
  echo -e "${GRAY}Score: $score   |   Severity: $severity${NC}"

  if ((${#reasons[@]})); then
    echo -e "\n${YELLOW}${BOLD}Detected Indicators:${NC}"
    for r in "${reasons[@]}"; do echo -e "  ${RED}•${NC} $r"; done
  fi

  echo -e "\n${CYAN}${BOLD}Current Telemetry${NC}"
  printf "  Interface     : %s\n" "$iface"
  printf "  Inbound       : %s\n" "$(format_bytes "$rx_bps")"
  printf "  Outbound      : %s\n" "$(format_bytes "$tx_bps")"
  printf "  ESTABLISHED   : %s\n" "$estab"
  printf "  SYN-RECV      : %s\n" "$syn_recv"
  printf "  TIME-WAIT     : %s\n" "$time_wait"
  printf "  Unique IPs    : %s\n" "$unique_ips"
  printf "  Load (1m)     : %s  (cores: %s)\n" "$load1" "$cpus"

  top_source_ips
  top_dest_ports
}

show_mitigation() {
  echo -e "\n${PURPLE}${BOLD}Quick Mitigation Suggestions${NC}"
  echo -e "${GRAY}──────────────────────────────────────────────────────────────${NC}"
  echo -e "  ${YELLOW}1.${NC} Enable SYN cookies:  ${CYAN}sysctl -w net.ipv4.tcp_syncookies=1${NC}"
  echo -e "  ${YELLOW}2.${NC} Rate-limit SYN:      ${CYAN}iptables -A INPUT -p tcp --syn -m limit --limit 1/s -j ACCEPT${NC}"
  echo -e "  ${YELLOW}3.${NC} Drop excessive:      Use fail2ban / crowdsec / cloud firewall"
  echo -e "  ${YELLOW}4.${NC} Cloud provider:      Enable DDoS protection (AWS Shield, Cloudflare, etc.)"
  echo -e "  ${YELLOW}5.${NC} Monitor live:        Use the tools below"
  echo
}

run_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    echo -e "${GREEN}Launching $tool... (exit to return to menu)${NC}"
    sleep 1
    "$tool" || echo -e "${YELLOW}$tool exited with error${NC}"
  else
    echo -e "${RED}$tool is not installed.${NC}"
    echo -e "${GRAY}Install with: apt install $tool${NC}"
    read -rp "Press Enter to continue..."
  fi
}

show_menu() {
  echo -e "\n${CYAN}${BOLD}Actions:${NC}"
  echo -e "  ${GREEN}[1]${NC} Full Deep Scan"
  echo -e "  ${GREEN}[2]${NC} nload (bandwidth graph)"
  echo -e "  ${GREEN}[3]${NC} iftop (live top talkers)"
  echo -e "  ${GREEN}[4]${NC} btop (full system monitor)"
  echo -e "  ${GREEN}[5]${NC} Show mitigation tips"
  echo -e "  ${GREEN}[6]${NC} Connection states summary"
  echo -e "  ${RED}[0]${NC} Exit"
  echo
  read -rp "Select: " choice
  case "$choice" in
    1) print_logo; analyze; show_mitigation ;;
    2) run_tool nload ;;
    3) run_tool iftop ;;
    4) run_tool btop ;;
    5) show_mitigation; read -rp "Press Enter..." ;;
    6) echo; ss -s 2>/dev/null || echo "ss failed"; echo; count_states_pretty; read -rp "Press Enter..." ;;
    0|q|Q) echo -e "${GREEN}Exiting...${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
  esac
}

count_states_pretty() {
  echo -e "${CYAN}Connection States:${NC}"
  ss -ant 2>/dev/null | awk 'NR>1 {print $1}' | sort | uniq -c | sort -nr | \
  while read -r c s; do
    local col="$GREEN"
    [[ "$s" =~ SYN|TIME|CLOSE ]] && col="$YELLOW"
    ((c > 2000)) && col="$RED"
    printf "  ${col}%-12s${NC} %6s\n" "$s" "$c"
  done || true
}

main() {
  print_logo
  check_and_offer_install
  analyze
  show_mitigation
  while true; do
    show_menu
  done
}

main
