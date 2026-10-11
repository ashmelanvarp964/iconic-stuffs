#!/usr/bin/env bash
# ============================================================================
#  LumaCloud  -  Server Threat & Abuse Scanner (Pterodactyl / Wings nodes)
#
#  Finds game servers with: backdoored / nulled / corrupted plugins,
#  crypto-miners, DDoS tools and sustained high-CPU abuse.
#  Then lets you quarantine files, stop containers or suspend on the panel.
#
#  Usage:
#    bash <(curl -fsSL https://raw.githubusercontent.com/ashmelanvarp964/iconic-stuffs/main/lumascan.sh)
#
#  Optional env vars:
#    LUMA_VOLUMES   volumes path        (default /var/lib/pterodactyl/volumes)
#    LUMA_CPU       high-CPU threshold  (default 85, avg of 3 samples)
#    LUMA_PANEL_URL / LUMA_PANEL_KEY    panel Application API (owner lookup + suspend)
# ============================================================================
 
VERSION="1.0.0"
AUTHOR="LumaCloud Studios"
VOL_ROOT="${LUMA_VOLUMES:-/var/lib/pterodactyl/volumes}"
CPU_LIMIT="${LUMA_CPU:-85}"
CONF_FILE="/etc/lumacloud.conf"
QUARANTINE_ROOT="/var/lib/lumacloud/quarantine"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 
R=$'\e[0m'; B=$'\e[1m'
RED=$'\e[38;5;196m'; GRN=$'\e[38;5;46m'; YLW=$'\e[38;5;220m'
CYN=$'\e[38;5;51m'; PUR=$'\e[38;5;141m'; PNK=$'\e[38;5;205m'; GRY=$'\e[38;5;244m'; WHT=$'\e[97m'
 
# --------------------------------------------------------------- signatures ----
BACKDOOR_RE='backdoor|b4ckd00r|forceop|force-op|hackerman|reverse.?shell|/dev/tcp/|bash -i >&|nc -e |skidded.?by'
NULLED_RE='nulled|blackspigot|leakforums|cracked.?by|%%__USER__%%|%%__RESOURCE__%%|%%__NONCE__%%|leaked.?by|mc-market-leak'
MINER_NAMES='-iname xmrig* -o -iname minerd* -o -iname cpuminer* -o -iname kinsing* -o -iname kdevtmpfsi* -o -iname nbminer* -o -iname t-rex* -o -iname ethminer* -o -iname lolminer* -o -iname phoenixminer*'
DDOS_NAMES='-iname hping* -o -iname slowloris* -o -iname loic* -o -iname goldeneye* -o -iname mhddos* -o -iname udpflood* -o -iname *ddos* -o -iname synflood*'
MINER_CONTENT_RE='stratum\+(tcp|ssl)://|pool\.(supportxmr|minexmr|hashvault|nanopool)|xmrig|cryptonight|randomx'
DDOS_CONTENT_RE='udp.?flood|syn.?flood|slowloris|http.?flood|hping3|ddos.?attack'
PROC_RE='xmrig|minerd|cpuminer|kinsing|kdevtmpfsi|nbminer|t-rex|ethminer|lolminer|stratum\+|hping3|slowloris|masscan|zmap|mhddos|udpflood'
 
# ------------------------------------------------------------------ banner ----
declare -A G
G[L]="█    |█    |█    |█    |█████"; G[U]="█   █|█   █|█   █|█   █| ███ "
G[M]="█   █|██ ██|█ █ █|█   █|█   █"; G[A]=" ███ |█   █|█████|█   █|█   █"
G[C]=" ████|█    |█    |█    | ████"; G[O]=" ███ |█   █|█   █|█   █| ███ "
G[D]="████ |█   █|█   █|█   █|████ "
 
banner() {
  local word="LUMACLOUD" cols=(51 45 39 75 141) row ch line parts i
  clear; echo
  for row in 0 1 2 3 4; do
    line=""
    for ((i=0; i<${#word}; i++)); do
      ch="${word:i:1}"; IFS='|' read -ra parts <<< "${G[$ch]}"; line+="${parts[$row]}  "
    done
    printf '  \e[1;38;5;%sm%s\e[0m\n' "${cols[$row]}" "$line"
  done
  echo
  echo "   ${YLW}⚡${R} ${CYN}${B}NEXT-GEN CLOUD INFRASTRUCTURE${R} ${GRY}•${R} ${PUR}AUTOMATION PLATFORM${R}"
  echo "   ${GRY}Made with Love ♥ & Brain by ${R}${B}${AUTHOR}${R}"
  echo "   ${GRY}LumaCloud v${VERSION}${R}"
  echo
  local os ip node
  os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"); os=${os:-Linux}
  ip=$(hostname -I 2>/dev/null | awk '{print $1}'); node=$(hostname | tr '[:lower:]' '[:upper:]')
  echo "  ${GRY}╭──────────────────────────────────────────────────────────────────╮${R}"
  echo "  ${GRY}│${R} ${WHT}${B}▶ PTERODACTYL SERVER THREAT & ABUSE SCANNER${R}"
  echo "  ${GRY}│${R} ${GRY}Node:${R} ${CYN}${node}${R}   ${GRY}OS:${R} ${B}${os}${R}   ${GRY}IP:${R} ${PNK}${B}${ip}${R}"
  echo "  ${GRY}╰──────────────────────────────────────────────────────────────────╯${R}"
  echo
}
 
# ---------------------------------------------------------------- helpers ----
HAVE_DOCKER=0
ensure_pkg() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "  ${YLW}Installing missing dependency: $2 ...${R}"
  if   command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q "$2" >/dev/null 2>&1
  elif command -v yum     >/dev/null 2>&1; then yum install -y -q "$2" >/dev/null 2>&1; fi
  command -v "$1" >/dev/null 2>&1
}
 
declare -A SCORE DETAIL PATHS
TOTAL_THREATS=0
declare -A W=( [BACKDOOR]=10 [MINER]=10 [MINER-PROC]=10 [DDOS]=8 [DDOS-PROC]=8 [NULLED]=3 [CORRUPT]=1 [HIGH-CPU]=2 )
 
add_finding() { # uuid type detail [path]
  local uuid="$1" type="$2" detail="$3" path="${4:-}"
  SCORE[$uuid]=$(( ${SCORE[$uuid]:-0} + ${W[$type]:-1} ))
  DETAIL[$uuid]+="${type}|${detail}"$'\n'
  [ -n "$path" ] && PATHS[$uuid]+="${path}"$'\n'
  TOTAL_THREATS=$((TOTAL_THREATS+1))
}
 
uuid_of_path() { local p="${1#$VOL_ROOT/}"; echo "${p%%/*}"; }
 
draw_progress() { # idx label total cur file
  local idx="$1" label="$2" tot="$3" cur="$4" file="$5" w=24 pct=0 f e fill empty
  [ "$tot" -gt 0 ] && pct=$(( cur * 100 / tot ))
  f=$(( pct * w / 100 )); e=$(( w - f ))
  fill=""; empty=""
  for ((k=0; k<f; k++)); do fill+="█"; done
  for ((k=0; k<e; k++)); do empty+="░"; done
  printf '\r\033[K  %s⋮%s %s[%s/4 %s]%s [%s%s%s%s%s] %s%3d%%%s  %sFiles:%s %s%d%s  %sThreats:%s %s%d%s  %s…%s%s' \
    "$CYN" "$R" "$B" "$idx" "$label" "$R" "$PUR" "$fill" "$GRY" "$empty" "$R" "$GRN" "$pct" "$R" \
    "$GRY" "$R" "$B" "$cur" "$R" "$GRY" "$R" "$RED" "$TOTAL_THREATS" "$R" "$GRY" "${file: -24}" "$R"
}
 
jar_ok_size() { [ "$(stat -c %s "$1" 2>/dev/null || echo 0)" -le 157286400 ]; }
evidence() { head -c 40 | tr -cd '[:print:]'; }
chk_backdoor() { jar_ok_size "$1" && unzip -p "$1" 2>/dev/null | grep -aEiom1 "$BACKDOOR_RE" | evidence; }
chk_nulled()   { jar_ok_size "$1" && unzip -p "$1" 2>/dev/null | grep -aEiom1 "$NULLED_RE"   | evidence; }
chk_corrupt()  { if [ ! -s "$1" ]; then echo "empty file"; elif ! unzip -tqq "$1" >/dev/null 2>&1; then echo "jar integrity test failed"; fi; }
 
phase_jars() { # idx label fn type
  local idx="$1" label="$2" fn="$3" type="$4" n=${#FILES[@]} i=0 f m
  for f in "${FILES[@]}"; do
    i=$((i+1))
    m=$("$fn" "$f")
    [ -n "$m" ] && add_finding "$(uuid_of_path "$f")" "$type" "${f#$VOL_ROOT/*/} ${GRY}(${m})${R}" "$f"
    (( i % 3 == 0 || i == n )) && draw_progress "$idx" "$label" "$n" "$i" "$f"
  done
  echo
}
 
# --------------------------------------------------------------- abuse scan ----
phase_abuse() {
  local f u m n
  echo "  ${CYN}⋮${R} ${B}[4/4 Abuse]${R} ${GRY}miner / DDoS files...${R}"
  # known miner & DDoS tool filenames
  while IFS= read -r f; do
    [ -n "$f" ] && add_finding "$(uuid_of_path "$f")" MINER "${f#$VOL_ROOT/*/} ${GRY}(known miner filename)${R}" "$f"
  done < <(eval "find \"\$VOL_ROOT\" -type f \\( $MINER_NAMES \\) 2>/dev/null")
  while IFS= read -r f; do
    [ -n "$f" ] && add_finding "$(uuid_of_path "$f")" DDOS "${f#$VOL_ROOT/*/} ${GRY}(known DDoS tool filename)${R}" "$f"
  done < <(eval "find \"\$VOL_ROOT\" -type f \\( $DDOS_NAMES \\) 2>/dev/null")
 
  # mining pools / flood strings inside scripts and configs
  echo "  ${CYN}⋮${R} ${GRY}scanning scripts & configs for pool/flood strings...${R}"
  while IFS= read -r -d '' f; do
    m=$(grep -aEiom1 "$MINER_CONTENT_RE" "$f" 2>/dev/null | evidence)
    if [ -n "$m" ]; then add_finding "$(uuid_of_path "$f")" MINER "${f#$VOL_ROOT/*/} ${GRY}(${m})${R}" "$f"; continue; fi
    m=$(grep -aEiom1 "$DDOS_CONTENT_RE" "$f" 2>/dev/null | evidence)
    [ -n "$m" ] && add_finding "$(uuid_of_path "$f")" DDOS "${f#$VOL_ROOT/*/} ${GRY}(${m})${R}" "$f"
  done < <(find "$VOL_ROOT" -type f -size -2M \
      \( -name '*.sh' -o -name '*.py' -o -name '*.js' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' -o -name '*.cfg' -o -name '*.txt' \) \
      -not -path '*/node_modules/*' -not -path '*/world*/*' -not -path '*/logs/*' -not -name 'usercache.json' \
      -print0 2>/dev/null)
 
  [ "$HAVE_DOCKER" -eq 1 ] || { echo "  ${YLW}Docker not found - skipping live process & CPU checks.${R}"; return; }
 
  # live processes inside running containers
  echo "  ${CYN}⋮${R} ${GRY}checking running processes in containers...${R}"
  local cid name line
  while IFS='|' read -r cid name; do
    [[ "$name" =~ $UUID_RE ]] || continue
    line=$(docker top "$cid" -eo pid,pcpu,args 2>/dev/null | tail -n +2 | grep -aEi "$PROC_RE" | head -1)
    if [ -n "$line" ]; then
      m=$(grep -aEiom1 "$PROC_RE" <<< "$line")
      case "$m" in hping3|slowloris|masscan|zmap|mhddos|udpflood) n=DDOS-PROC ;; *) n=MINER-PROC ;; esac
      add_finding "$name" "$n" "running process: $(cut -c1-70 <<< "$(awk '{ $1=$2=""; print }' <<< "$line")")"
    fi
  done < <(docker ps --format '{{.ID}}|{{.Names}}' 2>/dev/null)
 
  # sustained CPU (3 samples)
  echo "  ${CYN}⋮${R} ${GRY}sampling CPU (3x) for sustained abuse...${R}"
  local s
  declare -A SUM
  for s in 1 2 3; do
    while IFS='|' read -r name cpu; do
      [[ "$name" =~ $UUID_RE ]] || continue
      cpu=${cpu%\%}; cpu=${cpu%.*}
      SUM[$name]=$(( ${SUM[$name]:-0} + ${cpu:-0} ))
    done < <(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}' 2>/dev/null)
    [ "$s" -lt 3 ] && sleep 2
  done
  for name in "${!SUM[@]}"; do
    n=$(( ${SUM[$name]} / 3 ))
    [ "$n" -ge "$CPU_LIMIT" ] && add_finding "$name" HIGH-CPU "sustained CPU ${n}% (limit ${CPU_LIMIT}%)"
  done
}
 
# ---------------------------------------------------------- server info ----
CID_OF() { [ "$HAVE_DOCKER" -eq 1 ] && docker ps -aq --filter "name=$1" 2>/dev/null | head -1; }
STATE_OF() { [ "$HAVE_DOCKER" -eq 1 ] && docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null; }
motd_of() {
  local p="$VOL_ROOT/$1/server.properties"
  [ -f "$p" ] && grep -m1 '^motd=' "$p" | cut -d= -f2- | sed -E 's/§.//g; s/\\u00[aA]7.//g; s/&[0-9a-fk-or]//g; s/\\n.*//' | cut -c1-30
}
 
PANEL_OK=0
panel_init() {
  [ -f "$CONF_FILE" ] && . "$CONF_FILE"
  PANEL_URL="${LUMA_PANEL_URL:-${PANEL_URL:-}}"; PANEL_KEY="${LUMA_PANEL_KEY:-${PANEL_KEY:-}}"
  PANEL_URL="${PANEL_URL%/}"
  [ -n "$PANEL_URL" ] && [ -n "$PANEL_KEY" ] && ensure_pkg curl curl && ensure_pkg jq jq && PANEL_OK=1
}
declare -A PNAME POWNER PID
panel_lookup() { # uuid
  [ "$PANEL_OK" -eq 1 ] || return
  local r
  r=$(curl -fsS -m 20 -H "Authorization: Bearer $PANEL_KEY" -H "Accept: application/json" \
      "$PANEL_URL/api/application/servers?filter%5Buuid%5D=$1&include=user" 2>/dev/null) || return
  PNAME[$1]=$(jq -r '.data[0].attributes.name // empty' <<< "$r")
  PID[$1]=$(jq -r '.data[0].attributes.id // empty' <<< "$r")
  POWNER[$1]=$(jq -r '.data[0].attributes.relationships.user.attributes.email // empty' <<< "$r")
}
 
risk_label() {
  local s=$1
  if   [ "$s" -ge 10 ]; then printf '%sHIGH%s'   "$RED$B" "$R"
  elif [ "$s" -ge 3  ]; then printf '%sMEDIUM%s' "$YLW$B" "$R"
  else printf '%sLOW%s' "$GRN" "$R"; fi
}
type_color() {
  case "$1" in
    BACKDOOR|MINER|MINER-PROC) printf '%s' "$RED$B" ;;
    DDOS|DDOS-PROC)            printf '%s' "$PNK$B" ;;
    NULLED)                    printf '%s' "$YLW$B" ;;
    *)                         printf '%s' "$PUR$B" ;;
  esac
}
 
sorted_uuids() { for u in "${!SCORE[@]}"; do echo "${SCORE[$u]} $u"; done | sort -rn | awk '{print $2}'; }
 
print_report() {
  local u line type det cid state label
  echo "  ${GRY}──────────────────────────────────────────────────────────────────────${R}"
  echo "  ${B}SCAN COMPLETE${R}  Jars: ${B}${#FILES[@]}${R}  Flagged servers: ${RED}${B}${#SCORE[@]}${R}  Findings: ${RED}${B}${TOTAL_THREATS}${R}"
  echo "  ${GRY}──────────────────────────────────────────────────────────────────────${R}"
  if [ ${#SCORE[@]} -eq 0 ]; then echo; echo "  ${GRN}✔ No corrupted / abusive servers found. All clear.${R}"; return; fi
  for u in $(sorted_uuids); do
    cid=$(CID_OF "$u"); state=$(STATE_OF "${cid:-x}"); label=$(motd_of "$u")
    echo
    echo "  ${RED}${B}● SERVER ${u}${R}   Risk: $(risk_label "${SCORE[$u]}") ${GRY}(score ${SCORE[$u]})${R}"
    [ -n "$label" ]        && echo "    ${GRY}Name/MOTD :${R} ${label}"
    [ -n "${PNAME[$u]:-}" ] && echo "    ${GRY}Panel name:${R} ${PNAME[$u]}   ${GRY}Owner:${R} ${B}${POWNER[$u]:-?}${R}"
    [ -n "$cid" ]          && echo "    ${GRY}Container :${R} ${cid} ${GRY}(${state:-unknown})${R}"
    while IFS='|' read -r type det; do
      [ -z "$type" ] && continue
      printf '    %s[%-10s]%s %s\n' "$(type_color "$type")" "$type" "$R" "$det"
    done <<< "${DETAIL[$u]}"
  done
  echo
  echo "  ${GRY}Note: matches are signature-based heuristics - review before taking action.${R}"
}
 
# ---------------------------------------------------------------- actions ----
high_uuids() { for u in $(sorted_uuids); do [ "${SCORE[$u]}" -ge 10 ] && echo "$u"; done; }
 
do_quarantine() {
  local qdir u p dest cnt=0
  qdir="$QUARANTINE_ROOT/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$qdir"
  for u in "${!PATHS[@]}"; do
    while IFS= read -r p; do
      [ -f "$p" ] || continue
      dest="$qdir/$(sed "s|^$VOL_ROOT/||; s|/|__|g" <<< "$p")"
      mv -f "$p" "$dest" 2>/dev/null && chmod 000 "$dest" && cnt=$((cnt+1))
    done <<< "${PATHS[$u]}"
  done
  echo "  ${GRN}✔ Quarantined ${cnt} file(s) to ${qdir}${R}"
}
 
do_stop() {
  [ "$HAVE_DOCKER" -eq 1 ] || { echo "  ${RED}✖ Docker not available.${R}"; return; }
  local u cid
  for u in $(high_uuids); do
    cid=$(docker ps -q --filter "name=$u" | head -1)
    [ -n "$cid" ] && docker stop "$cid" >/dev/null 2>&1 && echo "  ${GRN}✔ Stopped ${u:0:8}…${R}"
  done
}
 
do_suspend() {
  if [ "$PANEL_OK" -ne 1 ]; then
    echo "  ${YLW}Panel API not configured.${R}"
    read -rp "  ${CYN}Panel URL (https://panel.example.com): ${R}" PANEL_URL
    read -rsp "  ${CYN}Application API key (needs Servers read/write): ${R}" PANEL_KEY; echo
    PANEL_URL="${PANEL_URL%/}"; ensure_pkg curl curl && ensure_pkg jq jq || return
    PANEL_OK=1
    read -rp "  ${CYN}Save to ${CONF_FILE}? (y/N): ${R}" yn
    [[ "$yn" =~ ^[Yy]$ ]] && { printf 'PANEL_URL=%q\nPANEL_KEY=%q\n' "$PANEL_URL" "$PANEL_KEY" > "$CONF_FILE"; chmod 600 "$CONF_FILE"; }
  fi
  local u code
  for u in $(high_uuids); do
    [ -z "${PID[$u]:-}" ] && panel_lookup "$u"
    if [ -z "${PID[$u]:-}" ]; then echo "  ${RED}✖ ${u:0:8}… not found on panel${R}"; continue; fi
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST \
      -H "Authorization: Bearer $PANEL_KEY" -H "Accept: application/json" \
      "$PANEL_URL/api/application/servers/${PID[$u]}/suspend")
    [ "$code" = "204" ] && echo "  ${GRN}✔ Suspended ${PNAME[$u]:-$u}${R}" || echo "  ${RED}✖ ${u:0:8}… suspend failed (HTTP $code)${R}"
  done
}
 
do_export() {
  local out="/root/lumacloud-report-$(date +%Y%m%d-%H%M%S).txt"
  print_report | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' > "$out"
  echo "  ${GRN}✔ Report saved: ${out}${R}"
}
 
actions_menu() {
  [ ${#SCORE[@]} -eq 0 ] && return
  local ch hi; hi=$(high_uuids | wc -l)
  while true; do
    echo
    echo "  ${B}Actions:${R}  ${GRY}(HIGH-risk servers: ${hi})${R}"
    echo "    ${B}[1]${R} ${YLW}Quarantine all flagged files${R} ${GRY}(moved, not deleted)${R}"
    echo "    ${B}[2]${R} ${RED}Stop containers of HIGH-risk servers${R}"
    echo "    ${B}[3]${R} ${RED}Suspend HIGH-risk servers on the panel${R}"
    echo "    ${B}[4]${R} ${CYN}Save report to file${R}"
    echo "    ${GRY}[0] Exit${R}"
    read -rp "  ${CYN}Select ➜ ${R}" ch
    case "$ch" in
      1) read -rp "  ${YLW}Quarantine ALL flagged files? (y/N): ${R}" yn; [[ "$yn" =~ ^[Yy]$ ]] && do_quarantine ;;
      2) read -rp "  ${RED}Stop ${hi} HIGH-risk container(s)? (y/N): ${R}" yn; [[ "$yn" =~ ^[Yy]$ ]] && do_stop ;;
      3) read -rp "  ${RED}Suspend ${hi} HIGH-risk server(s) on panel? (y/N): ${R}" yn; [[ "$yn" =~ ^[Yy]$ ]] && do_suspend ;;
      4) do_export ;;
      0|q|Q|"") echo "  ${GRY}Bye from LumaCloud 👋${R}"; return ;;
    esac
  done
}
 
# ------------------------------------------------------------------- main ----
main() {
  if [ "$(id -u)" -ne 0 ]; then echo "${RED}✖ Run as root (sudo -i).${R}"; exit 1; fi
  command -v docker >/dev/null 2>&1 && HAVE_DOCKER=1
  ensure_pkg unzip unzip || { echo "${RED}✖ unzip is required.${R}"; exit 1; }
  [ -d "$VOL_ROOT" ] || { echo "${RED}✖ Volumes path not found: $VOL_ROOT${R}"; exit 1; }
  panel_init
 
  banner
  echo "  ${PUR}⚙ Scanning Pterodactyl Game Server volumes for Corrupted, Nulled & Abusive content...${R}"
  echo "  ${GRY}Target Root :${R} ${B}${VOL_ROOT}${R}"
  echo
  mapfile -t FILES < <(find "$VOL_ROOT" -type f -name '*.jar' 2>/dev/null)
 
  if [ ${#FILES[@]} -gt 0 ]; then
    phase_jars 1 "Backdoors" chk_backdoor BACKDOOR
    phase_jars 2 "Nulled   " chk_nulled   NULLED
    phase_jars 3 "Corrupted" chk_corrupt  CORRUPT
  else
    echo "  ${YLW}No .jar files found - skipping plugin phases.${R}"
  fi
  phase_abuse
 
  # enrich with panel info (owner/name) for flagged servers
  if [ "$PANEL_OK" -eq 1 ]; then
    echo "  ${CYN}⋮${R} ${GRY}looking up owners on the panel...${R}"
    for u in "${!SCORE[@]}"; do panel_lookup "$u"; done
  fi
 
  echo
  print_report
  actions_menu
}
 
main
 
