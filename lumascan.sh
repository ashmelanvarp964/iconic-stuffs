#!/usr/bin/env bash
# ============================================================================
#  LumaCloud  -  DDoS Shield  (attack detector • attacker IP list • geo • mitigation)
#
#  • Samples live traffic and tells you if the node / a VPS / a game server is under attack
#  • Lists attacking IPs with country, city, ISP/ASN and attack share
#  • Shows WHICH server (container port) or destination IP is being targeted
#  • One-key mitigation: block IPs / countries, rate-limit floods, harden kernel,
#    drop reflection traffic, null-route an attacked port
#
#  bash <(curl -fsSL https://raw.githubusercontent.com/ashmelanvarp964/iconic-stuffs/main/lumaguard.sh)
#
#  Modes:  (none)=interactive scan | status=scan only, no menu | watch=live monitor
#          flush=remove every LumaCloud rule/set/sysctl
#  Env  :  LUMA_SECS=8        capture window (seconds)
#          LUMA_IFACE=eth0    uplink interface (auto-detected)
#          LUMA_LINK=1000     link speed in Mbps if the NIC does not report it
#          LUMA_PPS_BASE=15000  inbound packets/s that is "busy" for this node
#          LUMA_WHITELIST="1.2.3.4 5.6.7.8"  never block these
#          LUMA_BLOCK_TTL=21600  seconds an IP stays blocked (default 6h)
#          LUMA_AUTO=1        (watch mode) auto-block attackers during an attack
#          LUMA_DRYRUN=1      print firewall commands instead of running them
# ============================================================================
 
VERSION="1.0.2"
AUTHOR="LumaCloud Studios"
SECS="${LUMA_SECS:-8}"; TOPN="${LUMA_TOP:-12}"
PPS_BASE="${LUMA_PPS_BASE:-15000}"
IP_PPS="${LUMA_IP_PPS:-500}"; IP_SYN="${LUMA_IP_SYN:-30}"; IP_CONNS="${LUMA_IP_CONNS:-100}"; IP_SYNRECV="${LUMA_IP_SYNRECV:-20}"
BLOCK_TTL="${LUMA_BLOCK_TTL:-21600}"
RL_SYN="${LUMA_RL_SYN:-60}"; RL_UDP="${LUMA_RL_UDP:-3000}"; RL_ICMP="${LUMA_RL_ICMP:-20}"
VOL_ROOT="${LUMA_VOLUMES:-/var/lib/pterodactyl/volumes}"
STATE_DIR="/var/lib/lumaguard"; LOG="/var/log/lumaguard.log"; GEO_CACHE="$STATE_DIR/geo.tsv"
DRYRUN="${LUMA_DRYRUN:-}"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
AMP_PORTS="19 53 111 123 137 161 389 1900 3702 5353 11211"
 
locale -a 2>/dev/null | grep -qi 'c\.utf-\?8' && export LC_ALL=C.UTF-8
COLS=$(tput cols 2>/dev/null || echo 80); [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
 
# ------------------------------------------------------------------ colors ----
R=$'\e[0m'; B=$'\e[1m'
RED=$'\e[38;5;203m'; GRN=$'\e[38;5;84m'; YLW=$'\e[38;5;221m'
CYN=$'\e[38;5;87m'; PUR=$'\e[38;5;141m'; PNK=$'\e[38;5;211m'
GRY=$'\e[38;5;245m'; WHT=$'\e[38;5;255m'; TEAL=$'\e[38;5;43m'; ORG=$'\e[38;5;209m'
 
TMP=$(mktemp -d /tmp/lumaguard.XXXXXX)
cleanup() { printf '\e[?25h'; rm -rf "$TMP"; }
trap cleanup EXIT
trap 'cleanup; echo; exit 130' INT
 
# ------------------------------------------------------------- box drawing ----
BW=76
rep() { local i out=""; for ((i=0;i<$2;i++)); do out+="$1"; done; printf '%s' "$out"; }
HR=$(rep '─' $BW)
vlen() { local s; s=$(printf '%s' "$1" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'); echo "${#s}"; }
box_top() { printf '  %s╭%s╮%s\n' "$GRY" "$HR" "$R"; }
box_sep() { printf '  %s├%s┤%s\n' "$GRY" "$HR" "$R"; }
box_bot() { printf '  %s╰%s╯%s\n' "$GRY" "$HR" "$R"; }
box_row() { local c="$1" x="${2:-0}" n pad; n=$(vlen "$c"); pad=$((BW-1-n-x)); [ "$pad" -lt 0 ] && pad=0
  printf '  %s│%s %s%*s%s│%s\n' "$GRY" "$R" "$c" "$pad" "" "$GRY" "$R"; }
center() { local n pad; n=$(vlen "$1"); pad=$(( (78-n)/2 )); [ $pad -lt 0 ] && pad=0; printf '%*s%s\n' "$pad" "" "$1"; }
fmt() { printf '%s' "${1:-0}" | sed -E ':a;s/^([0-9]+)([0-9]{3})/\1,\2/;ta'; }
gauge() { # pct width
  local p=${1%%.*} w=${2:-12} f e k fill="" empty="" col; p=${p:-0}; [ "$p" -gt 100 ] && p=100
  f=$(( p*w/100 )); e=$(( w-f )); for ((k=0;k<f;k++)); do fill+="█"; done; for ((k=0;k<e;k++)); do empty+="░"; done
  if [ "$p" -ge 70 ]; then col=$RED; elif [ "$p" -ge 40 ]; then col=$YLW; else col=$GRN; fi
  printf '%s%s%s%s%s' "$col" "$fill" "$GRY" "$empty" "$R"
}
flag() { local cc="${1^^}" o="" c i
  [[ "$cc" =~ ^[A-Z]{2}$ ]] || { printf '🏳'; return; }
  for ((i=0;i<2;i++)); do c=$(printf '%d' "'${cc:i:1}"); printf -v o '%s\\U%08x' "$o" $((0x1F1E6 + c - 65)); done
  printf "$o"
}
 
# ------------------------------------------------------------------ banner ----
LOGO=(
"██╗     ██╗   ██╗███╗   ███╗ █████╗  ██████╗██╗      ██████╗ ██╗   ██╗██████╗ "
"██║     ██║   ██║████╗ ████║██╔══██╗██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗"
"██║     ██║   ██║██╔████╔██║███████║██║     ██║     ██║   ██║██║   ██║██║  ██║"
"██║     ██║   ██║██║╚██╔╝██║██╔══██║██║     ██║     ██║   ██║██║   ██║██║  ██║"
"███████╗╚██████╔╝██║ ╚═╝ ██║██║  ██║╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝"
"╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝ ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝ "
)
LOGO_COLS=(51 45 39 75 141 177)
banner() {
  clear; echo
  if [ "$COLS" -ge 80 ]; then
    local i; for i in 0 1 2 3 4 5; do printf ' \e[1;38;5;%sm%s\e[0m\n' "${LOGO_COLS[$i]}" "${LOGO[$i]}"; done
  else printf '  \e[1;38;5;51mL\e[38;5;45mU\e[38;5;39mM\e[38;5;75mA\e[38;5;141mC\e[38;5;177mL\e[38;5;141mO\e[38;5;99mU\e[38;5;93mD\e[0m\n'; fi
  echo
  center "${YLW}⚡${R} ${CYN}${B}NEXT-GEN CLOUD INFRASTRUCTURE${R} ${GRY}•${R} ${PUR}DDOS SHIELD${R}"
  center "${GRY}Made with Love ♥ & Brain 🧠 by ${R}${B}${WHT}${AUTHOR}${R}"
  center "${GRY}LumaGuard v${VERSION}${R}"
  echo
}
header_box() {
  local os node l1; os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"); os=${os:-Linux}
  node=$(hostname | tr '[:lower:]' '[:upper:]'); printf -v l1 '%-42s' "▶ $1"
  box_top
  box_row "${WHT}${B}${l1}${R} ${GRY}Node:${R} ${CYN}${node:0:22}${R}"
  box_row "${GRY}OS:${R} ${B}$(printf '%-38s' "${os:0:38}")${R}   ${GRY}IP:${R}   ${PNK}${B}${LOCAL_IP:-?}${R}"
  box_bot; echo
}
 
# ---------------------------------------------------------------- helpers ----
HAVE_DOCKER=0
X() { if [ -n "$DRYRUN" ]; then printf '  %s[dry-run]%s %s\n' "$GRY" "$R" "$*"; return 0; else "$@"; fi; }
log() { mkdir -p "$STATE_DIR" 2>/dev/null; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }
pause() { echo; read -rp "  ${GRY}Press Enter to continue...${R}" _; }
ensure_pkg() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf '  %sInstalling dependency: %s ...%s\n' "$YLW" "$2" "$R"
  if   command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1; }
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q "$2" >/dev/null 2>&1
  elif command -v yum     >/dev/null 2>&1; then yum install -y -q "$2" >/dev/null 2>&1; fi
  command -v "$1" >/dev/null 2>&1
}
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
spin_wait() { local pid=$1 msg=$2 i=0 t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[K  %s%s%s %s %s(%ds)%s' "$CYN" "${SPIN[i%10]}" "$R" "$msg" "$GRY" $((SECONDS-t0)) "$R"; i=$((i+1)); sleep 0.1
  done; printf '\r\033[K'; wait "$pid" 2>/dev/null; }
 
is_private() { [[ "$1" =~ ^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|0\.) ]] || [[ "$1" =~ ^(::1$|fe80:|fc|fd) ]]; }
 
# --------------------------------------------------------------- environment ----
detect_env() {
  IFACE="${LUMA_IFACE:-$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')}"
  [ -z "$IFACE" ] && IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
  LOCAL_IP=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
  LINK_MBPS=$(cat "/sys/class/net/$IFACE/speed" 2>/dev/null); { [[ "$LINK_MBPS" =~ ^[0-9]+$ ]] && [ "$LINK_MBPS" -gt 0 ]; } || LINK_MBPS="${LUMA_LINK:-1000}"
  command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1 && HAVE_DOCKER=1
}
 
declare -A WL
build_whitelist() { # admin SSH peers, panel host, own IPs, env
  local ip host
  for ip in $LUMA_WHITELIST $(hostname -I 2>/dev/null) $LOCAL_IP; do WL[$ip]=1; done
  while read -r ip; do [ -n "$ip" ] && WL[$ip]=1; done < <(ss -Htn state established '( sport = :22 )' 2>/dev/null | awk "$PEER_AWK")
  # DNS resolvers: in a reflection attack these show up as "attackers" — blocking them would break the node's own DNS
  for ip in 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 149.112.112.112 208.67.222.222 208.67.220.220 \
            $(awk '/^nameserver/{print $2}' /etc/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null); do WL[$ip]=1; done
  if [ -r /etc/pterodactyl/config.yml ]; then
    host=$(awk -F'[/:]+' '/^remote:/{print $3; exit}' /etc/pterodactyl/config.yml 2>/dev/null)
    [ -n "$host" ] && for ip in $(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u); do WL[$ip]=1; done
  fi
}
PEER_AWK='{p=$4; gsub(/[\[\]]/,"",p); sub(/:[0-9]+$/,"",p); sub(/^::ffff:/,"",p); if(p!="") print p}'
is_protected() { [ -n "${WL[$1]:-}" ] || is_private "$1"; }
 
# --------------------------------------------------------------- geolocation ----
declare -A GEO
geo_load() { [ -f "$GEO_CACHE" ] || return; local ip cc co ci isp asn h p
  while IFS=$'\t' read -r ip cc co ci isp asn h p; do GEO[$ip]="$cc|$co|$ci|$isp|$asn|$h|$p"; done < "$GEO_CACHE"; }
geo_lookup() { # ips...
  local need=() ip i chunk json resp q cc co ci isp asn h p
  for ip in "$@"; do [ -z "${GEO[$ip]:-}" ] && ! is_private "$ip" && need+=("$ip"); done
  [ ${#need[@]} -eq 0 ] && return 0
  command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null
  for ((i=0;i<${#need[@]};i+=100)); do
    chunk=("${need[@]:i:100}")
    json=$(printf '%s\n' "${chunk[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')
    resp=$(curl -fsS -m 15 -H 'Content-Type: application/json' -d "$json" \
      'http://ip-api.com/batch?fields=status,country,countryCode,city,isp,as,hosting,proxy,query' 2>/dev/null) || continue
    while IFS=$'\t' read -r q cc co ci isp asn h p; do
      GEO[$q]="$cc|$co|$ci|$isp|$asn|$h|$p"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$q" "$cc" "$co" "$ci" "$isp" "$asn" "$h" "$p" >> "$GEO_CACHE" 2>/dev/null
    done < <(jq -r 'def n: if .==null or .=="" then "-" else . end; .[]|select(.status=="success")|[.query,(.countryCode|n),(.country|n),(.city|n),(.isp|n),(.as|n),(.hosting|tostring),(.proxy|tostring)]|@tsv' <<< "$resp")
  done
}
geo_row() { local g="${GEO[$1]:-}"; [ -z "$g" ] && g="--|Unknown|-|-|-|false|false"
  IFS='|' read -r G_CC G_CO G_CITY G_ISP G_ASN G_H G_P <<< "$g"; }
 
# ------------------------------------------------------------------ sampling ----
net_sample() { sed 's/:/ /' /proc/net/dev | awk -v i="$IFACE" '$1==i {print $2,$3,$10,$11}'; }
read -r -d '' CAP_AWK <<'EOF'
function addr(a,   n,arr) {
  PORT=""
  if (index(a,":")==0) {
    n=split(a,arr,".")
    if (n==5) { PORT=arr[5]; return arr[1] "." arr[2] "." arr[3] "." arr[4] }
    return a
  }
  if (match(a, /\.[0-9]+$/)) {
    if (index(substr(a,1,RSTART-1),".")==0) { PORT=substr(a,RSTART+1); return substr(a,1,RSTART-1) }
  }
  return a
}
{
  if ($2!="IP" && $2!="IP6") next
  dst=$5; dst=substr(dst,1,length(dst)-1)
  p6=$6
  if (p6=="Flags") proto="tcp"; else if (p6=="UDP,") proto="udp"; else if (substr(p6,1,4)=="ICMP") proto="icmp"; else proto="other"
  src=addr($3); sp=PORT; dst=addr(dst); dp=PORT
  tot++; P[proto]++; S[src]++; DI[dst]++
  if (proto=="tcp") { if ($7=="[S],") { SYN[src]++; synt++ } }
  else if (proto=="udp") { U[src]++; UP[sp]++ }
  else if (proto=="icmp") IC[src]++
  if (dp!="" && (proto=="tcp" || proto=="udp")) D[dp " " proto]++
}
END {
  f=out "/cap_src";   for (k in S)  printf "%s %d %d %d %d\n", k, S[k], SYN[k]+0, U[k]+0, IC[k]+0 > f; close(f)
  f=out "/cap_dst";   for (k in D)  { split(k,z," "); printf "%s %s %d\n", z[1], z[2], D[k] > f }; close(f)
  f=out "/cap_dstip"; for (k in DI) printf "%s %d\n", k, DI[k] > f; close(f)
  f=out "/cap_udpsp"; for (k in UP) printf "%s %d\n", k, UP[k] > f; close(f)
  f=out "/cap_tot";   printf "%d %d %d %d %d %d\n", tot, P["tcp"], P["udp"], P["icmp"], P["other"], synt > f; close(f)
}
EOF
 
capture_job() {
  : > "$TMP/cap_src"; : > "$TMP/cap_dst"; : > "$TMP/cap_dstip"; : > "$TMP/cap_udpsp"; echo "0 0 0 0 0 0" > "$TMP/cap_tot"
  net_sample > "$TMP/net0"; local t0 t1; t0=$(date +%s.%N)
  if [ -n "${LUMA_FAKE_CAPTURE:-}" ]; then cat "$LUMA_FAKE_CAPTURE"; sleep 1
  else timeout "$SECS" tcpdump -nn -l -Q in -i "$IFACE" -c 500000 'not port 22' 2>/dev/null; fi | awk -v out="$TMP" "$CAP_AWK"
  t1=$(date +%s.%N); net_sample > "$TMP/net1"
  awk -v a="$t0" -v b="$t1" 'BEGIN{d=b-a; if(d<0.5)d=0.5; printf "%.2f\n", d}' > "$TMP/elapsed"
  # connection table
  ss -Htan 2>/dev/null | awk '{c[$1]++} END{for(k in c) print k, c[k]}' > "$TMP/ss_states"
  ss -Htn state established 2>/dev/null | awk "$PEER_AWK" | sort | uniq -c | awk '{print $2, $1}' > "$TMP/conn_est"
  ss -Htn state syn-recv 2>/dev/null | awk "$PEER_AWK" | sort | uniq -c | awk '{print $2, $1}' > "$TMP/conn_syn"
}
 
# ------------------------------------------------------------------ analysis ----
declare -A ATT_PPS ATT_SYN ATT_CONN ATT_SR ATT_SUS
ATT_ORDER=(); SUSPECTS=()
LEVEL=0; SCORE=0; REASONS=(); ATTACK_TYPES=()
load_ranked() { # file: sus score ip pps syn conn synrecv
  ATT_ORDER=(); SUSPECTS=(); ATT_PPS=(); ATT_SYN=(); ATT_CONN=(); ATT_SR=(); ATT_SUS=()
  local sus sc ip pps syn cn sr
  while read -r sus sc ip pps syn cn sr; do
    [ -z "$ip" ] && continue; is_protected "$ip" && continue
    ATT_ORDER+=("$ip"); ATT_PPS[$ip]=$pps; ATT_SYN[$ip]=$syn; ATT_CONN[$ip]=$cn; ATT_SR[$ip]=$sr; ATT_SUS[$ip]=$sus
    [ "$sus" -eq 1 ] && SUSPECTS+=("$ip")
  done < "$1"
}
amp_name() { case "$1" in 53) echo DNS;; 123) echo NTP;; 11211) echo Memcached;; 1900) echo SSDP;; 161) echo SNMP;; 389) echo CLDAP;; 19) echo CHARGEN;; 111) echo Portmap;; 137) echo NetBIOS;; 3702) echo WS-Discovery;; 5353) echo mDNS;; *) echo "$1";; esac; }
 
analyze() {
  local rx0 rxp0 tx0 txp0 rx1 rxp1 tx1 txp1 ELAP
  read -r rx0 rxp0 tx0 txp0 < "$TMP/net0"; read -r rx1 rxp1 tx1 txp1 < "$TMP/net1"; read -r ELAP < "$TMP/elapsed"
  rx0=${rx0:-0}; rx1=${rx1:-0}; rxp0=${rxp0:-0}; rxp1=${rxp1:-0}; tx0=${tx0:-0}; tx1=${tx1:-0}; txp0=${txp0:-0}; txp1=${txp1:-0}
  RX_MBPS=$(awk -v a="$rx0" -v b="$rx1" -v t="$ELAP" 'BEGIN{printf "%.1f",(b-a)*8/1e6/t}')
  TX_MBPS=$(awk -v a="$tx0" -v b="$tx1" -v t="$ELAP" 'BEGIN{printf "%.1f",(b-a)*8/1e6/t}')
  RX_PPS=$(awk -v a="$rxp0" -v b="$rxp1" -v t="$ELAP" 'BEGIN{printf "%d",(b-a)/t}')
  TX_PPS=$(awk -v a="$txp0" -v b="$txp1" -v t="$ELAP" 'BEGIN{printf "%d",(b-a)/t}')
  LINK_PCT=$(awk -v m="$RX_MBPS" -v l="$LINK_MBPS" 'BEGIN{printf "%d", m*100/l}')
  read -r CAP_TOT CAP_TCP CAP_UDP CAP_ICMP CAP_OTH CAP_SYN < "$TMP/cap_tot"
  CAP_TOT=${CAP_TOT:-0}; CAP_TCP=${CAP_TCP:-0}; CAP_UDP=${CAP_UDP:-0}; CAP_ICMP=${CAP_ICMP:-0}; CAP_SYN=${CAP_SYN:-0}
  local t=$CAP_TOT; [ "$t" -eq 0 ] && t=1
  TCP_SH=$((CAP_TCP*100/t)); UDP_SH=$((CAP_UDP*100/t)); ICMP_SH=$((CAP_ICMP*100/t)); SYN_SH=$((CAP_SYN*100/t))
  CAP_PPS=$(( CAP_TOT / ${ELAP%.*} )); [ "${ELAP%.*}" -eq 0 ] && CAP_PPS=$CAP_TOT
  [ "$CAP_PPS" -gt "$RX_PPS" ] && RX_PPS=$CAP_PPS
  SYNRECV=$(awk '$1=="SYN-RECV"{print $2}' "$TMP/ss_states"); SYNRECV=${SYNRECV:-0}
  ESTAB=$(awk '$1=="ESTAB"{print $2}' "$TMP/ss_states"); ESTAB=${ESTAB:-0}
  TW=$(awk '$1=="TIME-WAIT"{print $2}' "$TMP/ss_states"); TW=${TW:-0}
  CT_PCT=0; if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
    CT_PCT=$(awk -v c="$(cat /proc/sys/net/netfilter/nf_conntrack_count)" -v m="$(cat /proc/sys/net/netfilter/nf_conntrack_max)" 'BEGIN{printf "%d", (m>0)?c*100/m:0}'); fi
  # reflection / amplification share
  AMP_PK=0; AMP_TOPPORT=""; local port pk best=0
  while read -r port pk; do
    case " $AMP_PORTS " in *" $port "*) AMP_PK=$((AMP_PK+pk)); [ "$pk" -gt "$best" ] && { best=$pk; AMP_TOPPORT=$port; } ;; esac
  done < "$TMP/cap_udpsp"
  AMP_SH=0; [ "$CAP_UDP" -gt 0 ] && AMP_SH=$((AMP_PK*100/CAP_UDP))
  AMP_OF_TOT=$((AMP_PK*100/t))
 
  # per-IP ranking
  awk -v secs="${ELAP%.*}" -v ipp="$IP_PPS" -v isyn="$IP_SYN" -v icon="$IP_CONNS" -v isr="$IP_SYNRECV" '
    BEGIN{ if (secs<1) secs=1 }
    FILENAME==ARGV[1]{pk[$1]=$2; sy[$1]=$3; u[$1]=$4; ips[$1]=1; next}
    FILENAME==ARGV[2]{cn[$1]=$2; ips[$1]=1; next}
    FILENAME==ARGV[3]{sr[$1]=$2; ips[$1]=1; next}
    END{ for (ip in ips){ pps=pk[ip]/secs; sc=pps+sy[ip]*5+cn[ip]*10+sr[ip]*20
      sus=(pps>=ipp||sy[ip]/secs>=isyn||cn[ip]>=icon||sr[ip]>=isr)?1:0
      printf "%d %d %s %.0f %d %d %d\n", sus, sc, ip, pps, sy[ip], cn[ip], sr[ip] } }' \
    "$TMP/cap_src" "$TMP/conn_est" "$TMP/conn_syn" 2>/dev/null | sort -k1,1nr -k2,2nr | head -n 400 > "$TMP/ranked"
  load_ranked "$TMP/ranked"
  UNIQ_SRC=$(wc -l < "$TMP/cap_src" 2>/dev/null || echo 0)
 
  # verdict
  SCORE=0; REASONS=(); ATTACK_TYPES=(); SPOOFED=0
  local m=$(( RX_PPS / PPS_BASE ))
  if   [ "$m" -ge 7 ]; then SCORE=$((SCORE+3)); elif [ "$m" -ge 3 ]; then SCORE=$((SCORE+2)); elif [ "$m" -ge 1 ]; then SCORE=$((SCORE+1)); fi
  if   [ "$LINK_PCT" -ge 70 ]; then SCORE=$((SCORE+3)); elif [ "$LINK_PCT" -ge 40 ]; then SCORE=$((SCORE+2)); elif [ "$LINK_PCT" -ge 20 ]; then SCORE=$((SCORE+1)); fi
  if   [ "$SYNRECV" -ge 500 ]; then SCORE=$((SCORE+3)); elif [ "$SYNRECV" -ge 100 ]; then SCORE=$((SCORE+2)); elif [ "$SYNRECV" -ge 30 ]; then SCORE=$((SCORE+1)); fi
  if   [ "$CT_PCT" -ge 90 ]; then SCORE=$((SCORE+3)); elif [ "$CT_PCT" -ge 75 ]; then SCORE=$((SCORE+2)); fi
  if   [ "${#SUSPECTS[@]}" -ge 20 ]; then SCORE=$((SCORE+2)); elif [ "${#SUSPECTS[@]}" -ge 5 ]; then SCORE=$((SCORE+1)); fi
  [ "$AMP_OF_TOT" -ge 25 ] && SCORE=$((SCORE+3))
  [ "$ICMP_SH" -ge 25 ] && [ "$RX_PPS" -ge $((PPS_BASE/3)) ] && SCORE=$((SCORE+2))
  [ "$SYN_SH" -ge 30 ] && [ "$RX_PPS" -ge $((PPS_BASE/3)) ] && SCORE=$((SCORE+2))
  if [ "$SYNRECV" -ge 100 ] || { [ "$SYN_SH" -ge 30 ] && [ "$RX_PPS" -ge $((PPS_BASE/3)) ]; }; then
    ATTACK_TYPES+=("SYN flood"); REASONS+=("SYN FLOOD|${SYNRECV} half-open (SYN-RECV) connections, ${SYN_SH}% of packets are SYNs"); fi
  if [ "$UDP_SH" -ge 70 ] && [ "$RX_PPS" -ge "$PPS_BASE" ]; then
    ATTACK_TYPES+=("UDP flood"); REASONS+=("UDP FLOOD|${UDP_SH}% of inbound packets are UDP at $(fmt "$RX_PPS") pps"); fi
  if [ "$AMP_OF_TOT" -ge 25 ]; then
    ATTACK_TYPES+=("Reflection/amplification"); REASONS+=("AMPLIFICATION|${AMP_OF_TOT}% of packets come from $(amp_name "$AMP_TOPPORT") (src port ${AMP_TOPPORT}) — reflected traffic"); fi
  if [ "$ICMP_SH" -ge 25 ] && [ "$RX_PPS" -ge $((PPS_BASE/3)) ]; then
    ATTACK_TYPES+=("ICMP flood"); REASONS+=("ICMP FLOOD|${ICMP_SH}% of packets are ICMP"); fi
  local top_conn=0; for ip in "${ATT_ORDER[@]}"; do [ "${ATT_CONN[$ip]}" -gt "$top_conn" ] && top_conn=${ATT_CONN[$ip]}; done
  if [ "$top_conn" -ge "$IP_CONNS" ]; then ATTACK_TYPES+=("Connection flood"); REASONS+=("CONNECTION FLOOD|one IP holds ${top_conn} concurrent connections"); fi
  [ "$LINK_PCT" -ge 70 ] && { ATTACK_TYPES+=("Volumetric"); REASONS+=("VOLUMETRIC|inbound ${RX_MBPS} Mbps = ${LINK_PCT}% of the ${LINK_MBPS} Mbps link"); }
  [ "$CT_PCT" -ge 85 ] && { ATTACK_TYPES+=("Conntrack exhaustion"); REASONS+=("CONNTRACK|connection-tracking table ${CT_PCT}% full — new connections will be dropped"); }
  [ "$UNIQ_SRC" -ge 3000 ] && SPOOFED=1; REASONS+=("SPOOFED/BOTNET|$(fmt "$UNIQ_SRC") unique sources — spoofed IPs or botnet")
  if [ "$SCORE" -ge 6 ]; then LEVEL=2; elif [ "$SCORE" -ge 3 ]; then LEVEL=1; else LEVEL=0; fi
  # no attack: show plain top talkers by packet rate instead of "suspect first"
  if [ "$LEVEL" -eq 0 ]; then sort -k4,4nr "$TMP/ranked" > "$TMP/ranked2"; load_ranked "$TMP/ranked2"; fi
}
 
# ----------------------------------------------------------------- rendering ----
verdict_badge() { case "$LEVEL" in
  2) printf '%s 🔥 UNDER ATTACK %s' $'\e[1;97;48;5;196m' "$R" ;;
  1) printf '%s ▲ SUSPICIOUS TRAFFIC %s' $'\e[1;30;48;5;221m' "$R" ;;
  *) printf '%s ✔ NORMAL %s' $'\e[1;30;48;5;84m' "$R" ;; esac; }
 
declare -A PORT2SRV
build_port_map() { PORT2SRV=(); [ "$HAVE_DOCKER" -eq 1 ] || return
  local name ports p lbl
  while IFS='|' read -r name ports; do
    [[ "$name" =~ $UUID_RE ]] || continue
    lbl=$(grep -m1 '^motd=' "$VOL_ROOT/$name/server.properties" 2>/dev/null | cut -d= -f2- | sed -E 's/§.//g; s/\\u00[aA]7.//g; s/&[0-9a-fk-or]//g')
    for p in $(grep -oE ':[0-9]+->' <<< "$ports" | tr -cd '0-9\n' | sort -u); do PORT2SRV[$p]="${name:0:8} ${lbl:0:20}"; done
  done < <(docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null)
}
svc_name() { case "$1" in 25565) echo "Minecraft";; 19132) echo "Bedrock";; 30120) echo "FiveM";; 27015) echo "Source";; 80) echo "HTTP";; 443) echo "HTTPS";; 8080) echo "Wings API";; 2022) echo "Wings SFTP";; 22) echo SSH;; *) echo "";; esac; }
 
render() {
  banner; header_box "DDOS ATTACK DETECTOR & MITIGATION"
  # ---- verdict + traffic
  box_top
  box_row "${WHT}${B}VERDICT${R}   $(verdict_badge)   ${GRY}score ${SCORE}/20  •  window ${SECS}s on ${IFACE}${R}" $([ "$LEVEL" -eq 2 ] && echo 1 || echo 0)
  box_sep
  box_row "${GRY}Inbound ${R}${B}$(printf '%8s' "$RX_MBPS") Mbps${R} $(gauge "$LINK_PCT" 14) ${GRY}${LINK_PCT}% of ${LINK_MBPS}M${R}   ${GRY}Out${R} ${B}${TX_MBPS}${R}${GRY}M${R}"
  box_row "${GRY}Packets ${R}${B}$(printf '%8s' "$(fmt "$RX_PPS")") pps${R}  $(gauge $((RX_PPS*100/(PPS_BASE*7))) 14) ${GRY}busy-level ${PPS_BASE} pps${R}   ${GRY}Out${R} ${B}$(fmt "$TX_PPS")${R}"
  box_row "${GRY}Mix     ${R}TCP ${B}${TCP_SH}%${R}  UDP ${B}${UDP_SH}%${R}  ICMP ${B}${ICMP_SH}%${R}  ${GRY}│${R} ${GRY}unique sources${R} ${B}$(fmt "$UNIQ_SRC")${R}"
  box_row "${GRY}Conns   ${R}ESTAB ${B}$(fmt "$ESTAB")${R}  SYN-RECV ${YLW}${B}$(fmt "$SYNRECV")${R}  TIME-WAIT ${B}$(fmt "$TW")${R}  ${GRY}│${R} conntrack ${B}${CT_PCT}%${R}"
  if [ ${#REASONS[@]} -gt 0 ]; then
    box_sep; box_row "${RED}${B}ATTACK INDICATORS${R}"
    local r t d; for r in "${REASONS[@]}"; do t=${r%%|*}; d=${r#*|}; box_row "${RED}●${R} ${B}$(printf '%-15s' "$t")${R} ${GRY}${d:0:54}${R}"; done
  fi
  box_bot; echo
  # ---- attackers
  local n=0 ip tag
  geo_load; geo_lookup "${SUSPECTS[@]:0:100}" "${ATT_ORDER[@]:0:100}"
  box_top
  if [ "$LEVEL" -ge 1 ] && [ ${#SUSPECTS[@]} -gt 0 ]; then box_row "${RED}${B}TOP ATTACKING IPs${R}   ${GRY}${#SUSPECTS[@]} suspect IP(s) • red = over threshold${R}"
  elif [ "$LEVEL" -ge 1 ]; then box_row "${YLW}${B}TOP SOURCES${R}   ${GRY}no single IP stands out — distributed / spoofed attack${R}"
  else box_row "${CYN}${B}TOP TALKERS${R}   ${GRY}no attack detected — normal visitors & scans${R}"; fi
  box_sep
  box_row "${GRY}$(printf '%-3s %-16s %7s %5s %-5s %-10s %-19s' '#' 'IP ADDRESS' 'PPS' 'CONN' 'LOC' 'CITY' 'ISP / NETWORK')${R}"
  if [ ${#ATT_ORDER[@]} -eq 0 ]; then box_row "${GRN}No external sources stand out.${R}"; fi
  for ip in "${ATT_ORDER[@]}"; do
    n=$((n+1)); [ "$n" -gt "$TOPN" ] && break
    geo_row "$ip"; local col=$GRY; [ "${ATT_SUS[$ip]}" -eq 1 ] && col=$RED
    box_row "${col}$(printf '%-3s' "$n")${R}${B}${col}$(printf '%-17s' "${ip:0:16}")${R}$(printf '%7s' "$(fmt "${ATT_PPS[$ip]}")") $(printf '%5s' "$((ATT_CONN[$ip]+ATT_SR[$ip]))") $(flag "$G_CC") ${G_CC}  ${GRY}$(printf '%-10s' "${G_CITY:0:10}")${R} ${CYN}${G_ISP:0:19}${R}"
  done
  box_bot; echo
  # ---- countries
  declare -A CN_N CN_P CN_NAME; local cc
  local SRC_LIST=("${ATT_ORDER[@]:0:40}"); local ORIGIN_TITLE="TRAFFIC ORIGIN BY COUNTRY"
  if [ "$LEVEL" -ge 1 ] && [ ${#SUSPECTS[@]} -gt 0 ]; then SRC_LIST=("${SUSPECTS[@]:0:100}"); ORIGIN_TITLE="ATTACK ORIGIN BY COUNTRY"; fi
  for ip in "${SRC_LIST[@]}"; do geo_row "$ip"; cc=$G_CC; CN_N[$cc]=$(( ${CN_N[$cc]:-0}+1 )); CN_P[$cc]=$(( ${CN_P[$cc]:-0}+${ATT_PPS[$ip]} )); CN_NAME[$cc]=$G_CO; done
  if [ ${#CN_N[@]} -gt 0 ]; then
    local tot=0 k; for k in "${!CN_P[@]}"; do tot=$((tot+${CN_P[$k]})); done; [ "$tot" -eq 0 ] && tot=1
    box_top; box_row "${ORG}${B}${ORIGIN_TITLE}${R}"; box_sep
    COUNTRY_LIST=(); local i=0
    while read -r pp k; do
      i=$((i+1)); [ "$i" -gt 6 ] && break; COUNTRY_LIST+=("$k")
      box_row "$(flag "$k") ${B}$(printf '%-3s' "$k")${R}$(printf '%-17s' "${CN_NAME[$k]:0:16}") ${GRY}$(printf '%3s IPs' "${CN_N[$k]}")${R} $(printf '%8s' "$(fmt "$pp")") pps $(gauge $((pp*100/tot)) 10) ${GRY}$((pp*100/tot))%${R}"
    done < <(for k in "${!CN_P[@]}"; do echo "${CN_P[$k]} $k"; done | sort -rn)
    box_bot; echo
  else COUNTRY_LIST=(); fi
  # ---- targets
  build_port_map
  box_top; box_row "${TEAL}${B}WHO IS BEING TARGETED${R}"; box_sep
  local port proto pk srv any=0
  while read -r port proto pk; do
    any=1; srv="${PORT2SRV[$port]:-$(svc_name "$port")}"
    box_row "${GRY}port${R} ${B}$(printf '%-6s' "$port")${R}${GRY}$(printf '%-4s' "$proto")${R} $(printf '%9s' "$(fmt $((pk/${ELAP_INT:-1})))") pps  ${CYN}${srv}${R}"
    TOP_PORT=${TOP_PORT:-$port}
  done < <(awk '$2=="tcp"||$2=="udp"{p[$1]+=$3; pr[$1]=$2} END{for(k in p) print k, pr[k], p[k]}' "$TMP/cap_dst" | sort -k3 -rn | head -5)
  [ $any -eq 0 ] && box_row "${GRY}no TCP/UDP destination data captured${R}"
  local dip dpk; while read -r dip dpk; do box_row "${GRY}dest IP${R} ${B}$(printf '%-18s' "$dip")${R} $(printf '%9s' "$(fmt $((dpk/${ELAP_INT:-1})))") pps"
  done < <(grep -vE '^(255\.|22[4-9]\.|23[0-9]\.|ff[0-9a-f]{2}:|0\.)' "$TMP/cap_dstip" | sort -k2 -rn | head -3)
  if [ ${#PORT2SRV[@]} -gt 0 ]; then
    declare -A SRV_PK=(); local pp key
    while read -r port pp; do key="${PORT2SRV[$port]:-}"; [ -z "$key" ] && continue; SRV_PK[$key]=$(( ${SRV_PK[$key]:-0} + pp )); done \
      < <(awk '$2=="tcp"||$2=="udp"{print $1, $3}' "$TMP/cap_dst")
    if [ ${#SRV_PK[@]} -gt 0 ]; then
      box_sep; box_row "${GRY}Inbound per game server (from captured packets):${R}"
      local mx=0 spps share lbl8 rest ct=$CAP_TOT; [ "$ct" -lt 1 ] && ct=1
      while read -r pp key; do [ -z "$key" ] && continue; [ "$mx" -eq 0 ] && mx=$pp; spps=$((pp/${ELAP_INT:-1})); share=$((pp*100/ct))
        lbl8=${key%% *}; rest=${key#* }; [ "$rest" = "$key" ] && rest=""
        box_row "${B}${lbl8}${R} ${GRY}$(printf '%-21s' "${rest:0:21}")${R}$(printf '%8s' "$(fmt "$spps")") pps $(gauge $((pp*100/mx)) 10) ${GRY}${share}% of traffic${R}"
      done < <(for key in "${!SRV_PK[@]}"; do echo "${SRV_PK[$key]} $key"; done | sort -rn | head -4)
    fi
  fi
  box_bot
  if [ "$SPOOFED" -eq 1 ]; then
    echo; printf '  %s▲ Source addresses look spoofed/botnet.%s Blocking single IPs will not stop this —\n    use [4] rate limits, [6] kernel hardening, and ask your provider for upstream filtering.\n' "$YLW$B" "$R"
  fi
  if [ "$LINK_PCT" -ge 70 ]; then
    echo; printf '  %s▲ Traffic is saturating your link.%s Filtering on this node cannot fix a saturated uplink —\n    ask your provider for upstream DDoS mitigation / a null-route of the attacked IP,\n    or put game ports behind a DDoS-protected proxy/tunnel.\n' "$YLW$B" "$R"
  fi
  [ "$LEVEL" -eq 0 ] && { echo; printf '  %s✔ No DDoS pattern detected in this %ss window.%s %sIf players still lag, raise LUMA_SECS or run "watch".%s\n' "$GRN" "$SECS" "$R" "$GRY" "$R"; }
}
 
# ------------------------------------------------------------------ firewall ----
FW_READY=0; FWT=raw
ensure_fw() {
  [ "$FW_READY" -eq 1 ] && return 0
  ensure_pkg ipset ipset || { printf '  %s✖ ipset is required for blocking.%s\n' "$RED" "$R"; return 1; }
  command -v iptables >/dev/null 2>&1 || { printf '  %s✖ iptables not found.%s\n' "$RED" "$R"; return 1; }
  X ipset create luma_allow  hash:net -exist
  X ipset create luma_block  hash:net timeout "$BLOCK_TTL" -exist
  X ipset create luma_block_net hash:net maxelem 262144 -exist
  X ipset create luma_allow6 hash:net family inet6 -exist
  X ipset create luma_block6 hash:net family inet6 timeout "$BLOCK_TTL" -exist
  [ -z "$DRYRUN" ] && ! iptables -t raw -S >/dev/null 2>&1 && FWT=mangle
  fw_family iptables luma_allow luma_block luma_block_net
  fw_family ip6tables luma_allow6 luma_block6 ""
  local n; for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16; do X ipset add luma_allow "$n" -exist; done
  local ip; for ip in "${!WL[@]}"; do [[ "$ip" == *:* ]] && X ipset add luma_allow6 "$ip" -exist || X ipset add luma_allow "$ip" -exist; done
  FW_READY=1
}
fw_family() { local bin=$1 allow=$2 block=$3 extra=$4
  command -v "$bin" >/dev/null 2>&1 || return 0
  X "$bin" -t "$FWT" -N LUMA_GUARD 2>/dev/null; X "$bin" -t "$FWT" -N LUMA_RATE 2>/dev/null
  if ! "$bin" -t "$FWT" -C LUMA_GUARD -m set --match-set "$allow" src -j RETURN 2>/dev/null; then
    X "$bin" -t "$FWT" -A LUMA_GUARD -m set --match-set "$allow" src -j RETURN
    X "$bin" -t "$FWT" -A LUMA_GUARD -m set --match-set "$block" src -j DROP
    [ -n "$extra" ] && X "$bin" -t "$FWT" -A LUMA_GUARD -m set --match-set "$extra" src -j DROP
    X "$bin" -t "$FWT" -A LUMA_GUARD -j LUMA_RATE
  fi
  "$bin" -t "$FWT" -C PREROUTING -j LUMA_GUARD 2>/dev/null || X "$bin" -t "$FWT" -I PREROUTING 1 -j LUMA_GUARD
}
block_ip() { local t="$1" ttl="${2:-$BLOCK_TTL}" set=luma_block; [[ "$t" == *:* ]] && set=luma_block6
  X ipset add "$set" "$t" timeout "$ttl" -exist && log "BLOCK $t ttl=$ttl"; }
 
do_block_suspects() {
  [ ${#SUSPECTS[@]} -eq 0 ] && { printf '  %sNo suspect IPs to block.%s\n' "$YLW" "$R"; return; }
  printf '  %sBlock %d suspect IP(s) for %s hours? Admin/panel/private IPs are always protected. (y/N): %s' "$YLW" "${#SUSPECTS[@]}" "$((BLOCK_TTL/3600))" "$R"
  read -r yn; [[ "$yn" =~ ^[Yy]$ ]] || return
  ensure_fw || return; local ip c=0; for ip in "${SUSPECTS[@]}"; do block_ip "$ip" && c=$((c+1)); done
  printf '  %s✔ Blocked %d IP(s) at the firewall (raw table — drops before conntrack, also covers Docker traffic).%s\n' "$GRN" "$c" "$R"
}
do_block_custom() {
  read -rp "  ${CYN}IP(s) or CIDR(s) to block (space separated): ${R}" list; ensure_fw || return
  local t; for t in $list; do
    [[ "$t" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || { printf '  %s✖ invalid: %s%s\n' "$RED" "$t" "$R"; continue; }
    is_protected "${t%%/*}" && { printf '  %s✖ %s is protected (private/admin/own IP) — skipped%s\n' "$RED" "$t" "$R"; continue; }
    block_ip "$t" && printf '  %s✔ blocked %s%s\n' "$GRN" "$t" "$R"
  done
}
do_block_country() {
  local cc="${1:-}"
  if [ -z "$cc" ]; then
    [ ${#COUNTRY_LIST[@]} -gt 0 ] && { printf '  %sTop attacking countries:%s ' "$GRY" "$R"; local k; for k in "${COUNTRY_LIST[@]}"; do printf '%s %s  ' "$(flag "$k")" "$k"; done; echo; }
    read -rp "  ${CYN}2-letter country code to block (e.g. CN): ${R}" cc
  fi
  cc="${cc,,}"; [[ "$cc" =~ ^[a-z]{2}$ ]] || { printf '  %s✖ invalid code%s\n' "$RED" "$R"; return; }
  printf '  %s⚠ This blocks EVERY IP from %s${cc^^} — real players from there cannot connect either. Continue? (y/N): %s' "$YLW" "$(flag "$cc")" "$R"
  read -r yn; [[ "$yn" =~ ^[Yy]$ ]] || return
  ensure_fw || return
  local zone; zone=$(curl -fsS -m 30 "https://www.ipdeny.com/ipblocks/data/aggregated/${cc}-aggregated.zone" 2>/dev/null)
  [ -z "$zone" ] && { printf '  %s✖ could not download the %s IP list (ipdeny.com).%s\n' "$RED" "${cc^^}" "$R"; return; }
  local cnt; cnt=$(wc -l <<< "$zone")
  if [ -n "$DRYRUN" ]; then printf '  %s[dry-run]%s would add %s networks of %s to luma_block_net\n' "$GRY" "$R" "$cnt" "${cc^^}"
  else printf '%s\n' "$zone" | awk '{print "add luma_block_net "$1" -exist"}' | ipset restore 2>/dev/null; fi
  log "BLOCK-COUNTRY ${cc^^} nets=$cnt"; printf '  %s✔ Blocked %s network ranges for %s%s\n' "$GRN" "$cnt" "${cc^^}" "$R"
}
do_ratelimit() {
  printf '  %sApply per-IP rate limits?%s\n    SYN %s/s • UDP %s pkt/s • ICMP %s/s per source IP (tune with LUMA_RL_SYN / LUMA_RL_UDP / LUMA_RL_ICMP)\n  %s(y/N): %s' "$YLW" "$R" "$RL_SYN" "$RL_UDP" "$RL_ICMP" "$YLW" "$R"
  read -r yn; [[ "$yn" =~ ^[Yy]$ ]] || return; ensure_fw || return
  X iptables -t "$FWT" -F LUMA_RATE
  X iptables -t "$FWT" -A LUMA_RATE -p icmp -m hashlimit --hashlimit-name luma_icmp --hashlimit-mode srcip --hashlimit-above "${RL_ICMP}/sec" --hashlimit-burst $((RL_ICMP*2)) -j DROP
  X iptables -t "$FWT" -A LUMA_RATE -p tcp --syn -m hashlimit --hashlimit-name luma_syn --hashlimit-mode srcip --hashlimit-above "${RL_SYN}/sec" --hashlimit-burst $((RL_SYN*2)) -j DROP
  X iptables -t "$FWT" -A LUMA_RATE -p udp -m hashlimit --hashlimit-name luma_udp --hashlimit-mode srcip --hashlimit-above "${RL_UDP}/sec" --hashlimit-burst $((RL_UDP*2)) -j DROP
  log "RATELIMIT syn=$RL_SYN udp=$RL_UDP icmp=$RL_ICMP"; printf '  %s✔ Rate limits active (remove them from Manage ➜ Remove rate limits).%s\n' "$GRN" "$R"
}
do_amp() {
  printf '  %sDrop UNSOLICITED UDP from reflection ports (%s)?%s\n  %sReplies to your own DNS/NTP queries are unaffected. (y/N): %s' "$YLW" "$AMP_PORTS" "$R" "$GRY" "$R"
  read -r yn; [[ "$yn" =~ ^[Yy]$ ]] || return
  X iptables -t mangle -N LUMA_AMP 2>/dev/null; X iptables -t mangle -F LUMA_AMP
  X iptables -t mangle -A LUMA_AMP -p udp -m multiport --sports "${AMP_PORTS// /,}" -m conntrack --ctstate NEW -j DROP
  iptables -t mangle -C PREROUTING -j LUMA_AMP 2>/dev/null || X iptables -t mangle -I PREROUTING 1 -j LUMA_AMP
  log "AMP-FILTER on"; printf '  %s✔ Reflection filter active.%s\n' "$GRN" "$R"
}
SYSCTLS=( "net.ipv4.tcp_syncookies=1" "net.ipv4.tcp_max_syn_backlog=8192" "net.ipv4.tcp_synack_retries=2" "net.core.somaxconn=4096"
  "net.core.netdev_max_backlog=16384" "net.ipv4.conf.all.rp_filter=2" "net.ipv4.conf.default.rp_filter=2" "net.ipv4.icmp_echo_ignore_broadcasts=1"
  "net.ipv4.conf.all.accept_source_route=0" "net.ipv4.tcp_fin_timeout=15" "net.netfilter.nf_conntrack_max=524288"
  "net.netfilter.nf_conntrack_udp_timeout=20" "net.netfilter.nf_conntrack_tcp_timeout_syn_recv=30" )
do_harden() {
  mkdir -p "$STATE_DIR"; local kv k v cur lines=""
  printf '  %sKernel hardening (SYN cookies, bigger backlog/conntrack, loose rp_filter):%s\n' "$B" "$R"
  for kv in "${SYSCTLS[@]}"; do k=${kv%%=*}; v=${kv#*=}; cur=$(sysctl -n "$k" 2>/dev/null) || continue
    printf '    %-48s %s%s%s ➜ %s%s%s\n' "$k" "$GRY" "$cur" "$R" "$GRN" "$v" "$R"
    [ -f "$STATE_DIR/sysctl.backup" ] && grep -q "^$k=" "$STATE_DIR/sysctl.backup" || echo "$k=$cur" >> "$STATE_DIR/sysctl.backup"
    lines+="$kv"$'\n'; done
  printf '  %sApply? (y/N): %s' "$YLW" "$R"; read -r yn; [[ "$yn" =~ ^[Yy]$ ]] || return
  if [ -n "$DRYRUN" ]; then printf '  %s[dry-run]%s write /etc/sysctl.d/99-lumaguard.conf and sysctl -p\n' "$GRY" "$R"; return; fi
  printf '%s' "$lines" > /etc/sysctl.d/99-lumaguard.conf; sysctl -p /etc/sysctl.d/99-lumaguard.conf >/dev/null 2>&1
  log "SYSCTL applied"; printf '  %s✔ Applied (backup of old values kept — revert from Manage).%s\n' "$GRN" "$R"
}
do_revert_sysctl() { [ -f "$STATE_DIR/sysctl.backup" ] || { printf '  %sNothing to revert.%s\n' "$YLW" "$R"; return; }
  local kv; while read -r kv; do X sysctl -w "$kv" >/dev/null 2>&1; done < "$STATE_DIR/sysctl.backup"
  X rm -f /etc/sysctl.d/99-lumaguard.conf "$STATE_DIR/sysctl.backup"; printf '  %s✔ Kernel settings restored.%s\n' "$GRN" "$R"; }
do_block_port() {
  read -rp "  ${CYN}Port to drop for everyone (protects the node, that server goes offline) [${TOP_PORT:-}]: ${R}" p; p=${p:-${TOP_PORT:-}}
  [[ "$p" =~ ^[0-9]{1,5}$ ]] || { printf '  %s✖ invalid port%s\n' "$RED" "$R"; return; }
  ensure_fw || return; local pr; for pr in tcp udp; do X iptables -t "$FWT" -I LUMA_GUARD 2 -p "$pr" --dport "$p" -m comment --comment "luma-port-$p" -j DROP; done
  log "PORT-DROP $p"; printf '  %s✔ Port %s dropped (TCP+UDP). Undo from Manage ➜ Remove port blocks.%s\n' "$GRN" "$p" "$R"
}
manage_menu() {
  local ch ip
  while true; do
    echo; printf '  %sManage LumaGuard rules%s\n' "$B" "$R"
    printf '    [1] List blocked IPs   [2] Unblock an IP   [3] Flush ALL blocked IPs/countries\n    [4] Show firewall rules [5] Remove rate limits [6] Remove reflection filter\n    [7] Remove port blocks  [8] Revert kernel settings [9] Whitelist an IP   [0] Back\n'
    read -rp "  ${CYN}Select ➜ ${R}" ch
    case "$ch" in
      1) printf '  %sIPv4 blocks (with time left):%s\n' "$GRY" "$R"; ipset list luma_block 2>/dev/null | sed -n '/Members:/,$p' | tail -n +2 | head -40; ipset list luma_block6 2>/dev/null | sed -n '/Members:/,$p' | tail -n +2 | head -10
         printf '  %sCountry ranges blocked:%s %s\n' "$GRY" "$R" "$(ipset list luma_block_net 2>/dev/null | awk '/Number of entries/{print $4}')" ;;
      2) read -rp "  IP to unblock: " ip; X ipset del luma_block "$ip" 2>/dev/null; X ipset del luma_block6 "$ip" 2>/dev/null; X ipset del luma_block_net "$ip" 2>/dev/null; printf '  %s✔ done%s\n' "$GRN" "$R" ;;
      3) X ipset flush luma_block; X ipset flush luma_block6; X ipset flush luma_block_net; printf '  %s✔ all blocks cleared%s\n' "$GRN" "$R" ;;
      4) iptables -t "$FWT" -S LUMA_GUARD 2>/dev/null; iptables -t "$FWT" -S LUMA_RATE 2>/dev/null; iptables -t mangle -S LUMA_AMP 2>/dev/null ;;
      5) X iptables -t "$FWT" -F LUMA_RATE; printf '  %s✔ rate limits removed%s\n' "$GRN" "$R" ;;
      6) X iptables -t mangle -F LUMA_AMP; printf '  %s✔ reflection filter removed%s\n' "$GRN" "$R" ;;
      7) iptables -t "$FWT" -S LUMA_GUARD 2>/dev/null | grep 'luma-port' | sed 's/^-A /-D /' | while read -r rule; do X iptables -t "$FWT" $rule 2>/dev/null; done; printf '  %s✔ port blocks removed%s\n' "$GRN" "$R" ;;
      8) do_revert_sysctl ;;
      9) read -rp "  IP/CIDR to whitelist: " ip; ensure_fw && { [[ "$ip" == *:* ]] && X ipset add luma_allow6 "$ip" -exist || X ipset add luma_allow "$ip" -exist; printf '  %s✔ whitelisted%s\n' "$GRN" "$R"; } ;;
      0|"") return ;;
    esac
  done
}
do_flush_all() {
  for bin in iptables ip6tables; do command -v $bin >/dev/null 2>&1 || continue
    for t in raw mangle; do $bin -t $t -D PREROUTING -j LUMA_GUARD 2>/dev/null; $bin -t $t -D PREROUTING -j LUMA_AMP 2>/dev/null
      for c in LUMA_GUARD LUMA_RATE LUMA_AMP; do $bin -t $t -F $c 2>/dev/null; $bin -t $t -X $c 2>/dev/null; done; done; done
  for s in luma_allow luma_block luma_block_net luma_allow6 luma_block6; do ipset destroy $s 2>/dev/null; done
  rm -f /etc/sysctl.d/99-lumaguard.conf; printf '  %s✔ Every LumaGuard rule and set removed. (Kernel settings: use Manage ➜ revert.)%s\n' "$GRN" "$R"
}
 
# -------------------------------------------------------------------- export ----
do_export() {
  local ts out csv ip; ts=$(date +%Y%m%d-%H%M%S); out="/root/lumaguard-report-$ts.txt"; csv="/root/lumaguard-attackers-$ts.csv"
  { echo "LumaGuard report  $(date)"; echo "Node: $(hostname)  IP: $LOCAL_IP  Interface: $IFACE"
    echo "Verdict: $([ $LEVEL -eq 2 ] && echo 'UNDER ATTACK' || { [ $LEVEL -eq 1 ] && echo SUSPICIOUS || echo NORMAL; })  score=$SCORE"
    echo "Inbound: ${RX_MBPS} Mbps / $RX_PPS pps | SYN-RECV $SYNRECV | conntrack ${CT_PCT}% | unique sources $UNIQ_SRC"
    printf 'Indicators:\n'; local r; for r in "${REASONS[@]}"; do echo "  - ${r%%|*}: ${r#*|}"; done
    echo; echo "Suspect IPs (${#SUSPECTS[@]}):"; for ip in "${SUSPECTS[@]}"; do geo_row "$ip"; printf '  %-40s %7s pps  %s %s, %s  %s %s\n' "$ip" "${ATT_PPS[$ip]}" "$G_CC" "$G_CITY" "$G_CO" "$G_ASN" "$G_ISP"; done
  } > "$out"
  { echo "ip,country_code,country,city,isp,asn,hosting,proxy,pps,syn,connections,syn_recv,suspect"
    for ip in "${ATT_ORDER[@]}"; do geo_row "$ip"; echo "$ip,$G_CC,\"$G_CO\",\"$G_CITY\",\"$G_ISP\",\"$G_ASN\",$G_H,$G_P,${ATT_PPS[$ip]},${ATT_SYN[$ip]},${ATT_CONN[$ip]},${ATT_SR[$ip]},${ATT_SUS[$ip]}"; done; } > "$csv"
  printf '  %s✔ Report: %s%s\n  %s✔ IP list (CSV, send to your provider / abuse desk): %s%s\n' "$GRN" "$out" "$R" "$GRN" "$csv" "$R"
}
 
# ---------------------------------------------------------------------- flow ----
run_scan() {
  banner; header_box "DDOS ATTACK DETECTOR & MITIGATION"
  printf '  %s⚙ Sampling live traffic on %s%s%s for %ss, then analysing connections...%s\n\n' "$PUR" "$B" "$IFACE" "$R$PUR" "$SECS" "$R"
  capture_job & spin_wait $! "${GRY}capturing packets & reading connection table...${R}"
  ELAP_INT=$(awk '{printf "%d", ($1<1)?1:$1}' "$TMP/elapsed"); analyze
}
actions_menu() {
  local ch yn
  while true; do
    echo
    [ "$LEVEL" -eq 0 ] && printf '  %sNo attack detected — everything below is optional.%s\n' "$GRN" "$R"
    printf '  %sMitigation:%s  %s(suspects: %d • blocks last %sh • admin/panel/private IPs are never blocked)%s\n' "$B" "$R" "$GRY" "${#SUSPECTS[@]}" "$((BLOCK_TTL/3600))" "$R"
    printf '    %s[1]%s %sBlock all suspect IPs%s\n' "$B" "$R" "$RED" "$R"
    printf '    %s[2]%s %sBlock specific IP / CIDR%s\n' "$B" "$R" "$YLW" "$R"
    printf '    %s[3]%s %sBlock a country%s %s(uses the origin list above)%s\n' "$B" "$R" "$ORG" "$R" "$GRY" "$R"
    printf '    %s[4]%s %sRate-limit SYN / UDP / ICMP floods per IP%s\n' "$B" "$R" "$CYN" "$R"
    printf '    %s[5]%s %sDrop reflection / amplification traffic%s\n' "$B" "$R" "$PUR" "$R"
    printf '    %s[6]%s %sKernel hardening (SYN cookies, conntrack, backlog)%s\n' "$B" "$R" "$TEAL" "$R"
    printf '    %s[7]%s %sDrop an attacked port%s %s(saves the node, that server goes offline)%s\n' "$B" "$R" "$RED" "$R" "$GRY" "$R"
    printf '    %s[8]%s %sManage / undo rules%s   %s[9]%s %sExport IP list + report%s   %s[r]%s %sRe-scan%s\n' "$B" "$R" "$WHT" "$R" "$B" "$R" "$WHT" "$R" "$B" "$R" "$WHT" "$R"
    printf '    %s[0] Exit%s\n\n' "$GRY" "$R"
    [ -n "$DRYRUN" ] && printf '  %sDRY-RUN: firewall commands are printed, not executed.%s\n' "$YLW" "$R"
    read -rp "  ${CYN}Select ➜ ${R}" ch
    case "$ch" in
      1) do_block_suspects ;; 2) do_block_custom ;; 3) do_block_country ;; 4) do_ratelimit ;; 5) do_amp ;; 6) do_harden ;;
      7) do_block_port ;; 8) manage_menu ;; 9) do_export ;;
      r|R) run_scan; render ;;
      0|q|Q|"") printf '\n  %sStay safe — LumaCloud 👋%s\n\n' "$GRY" "$R"; return ;;
    esac
  done
}
 
watch_mode() {
  local interval="${LUMA_INTERVAL:-5}"; printf '\e[?25l'
  while true; do
    capture_job; ELAP_INT=$(awk '{printf "%d", ($1<1)?1:$1}' "$TMP/elapsed"); analyze; geo_load; geo_lookup "${ATT_ORDER[@]:0:5}"
    clear; echo; printf '  %s%sLumaGuard LIVE%s  %s%s  •  Ctrl+C to stop  •  auto-block: %s%s\n\n' "$CYN" "$B" "$R" "$GRY" "$(date '+%F %T')" "$([ -n "$LUMA_AUTO" ] && echo ON || echo off)" "$R"
    printf '  %s   %s%s Mbps%s  %s pps  SYN-RECV %s  conntrack %s%%  suspects %s\n\n' "$(verdict_badge)" "$B" "$RX_MBPS" "$R" "$(fmt "$RX_PPS")" "$SYNRECV" "$CT_PCT" "${#SUSPECTS[@]}"
    local n=0 ip; for ip in "${ATT_ORDER[@]}"; do n=$((n+1)); [ "$n" -gt 6 ] && break; geo_row "$ip"
      printf '   %-18s %7s pps  %s %s  %s%s%s\n' "$ip" "$(fmt "${ATT_PPS[$ip]}")" "$(flag "$G_CC")" "$G_CC" "$GRY" "${G_ISP:0:28}" "$R"; done
    if [ "$LEVEL" -eq 2 ] && [ -n "$LUMA_AUTO" ] && [ ${#SUSPECTS[@]} -gt 0 ]; then
      ensure_fw >/dev/null 2>&1; local c=0; for ip in "${SUSPECTS[@]:0:200}"; do block_ip "$ip" >/dev/null 2>&1 && c=$((c+1)); done
      printf '\n  %s✔ auto-blocked %d IP(s)%s\n' "$GRN" "$c" "$R"; log "AUTO-BLOCK $c ips verdict=attack rx=${RX_MBPS}Mbps"
    fi
    sleep "$interval"
  done
}
 
main() {
  [ "$(id -u)" -eq 0 ] || { printf '%s✖ Run as root (sudo -i).%s\n' "$RED" "$R"; exit 1; }
  mkdir -p "$STATE_DIR" 2>/dev/null
  if [ "${1:-scan}" = "flush" ]; then do_flush_all; exit 0; fi
  [ -n "${LUMA_FAKE_CAPTURE:-}" ] || ensure_pkg tcpdump tcpdump || { printf '%s✖ tcpdump is required.%s\n' "$RED" "$R"; exit 1; }
  ensure_pkg ss iproute2 >/dev/null 2>&1; ensure_pkg jq jq >/dev/null 2>&1; ensure_pkg curl curl >/dev/null 2>&1
  detect_env; [ -z "$IFACE" ] && { printf '%s✖ Could not detect the network interface (set LUMA_IFACE).%s\n' "$RED" "$R"; exit 1; }
  build_whitelist
  case "${1:-scan}" in
    watch)  watch_mode ;;
    status) run_scan; render ;;
    *)      run_scan; render; actions_menu ;;
  esac
}
main "$@"
 
