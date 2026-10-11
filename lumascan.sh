#!/usr/bin/env bash
# ============================================================================
#  LumaCloud  -  Server Threat & Abuse Scanner  (Pterodactyl / Wings nodes)
#
#  • Finds servers with backdoored / nulled / corrupted plugins
#  • Finds abusive servers: crypto-miners, DDoS tools, sustained high CPU
#  • Live telemetry, highest-load diagnostics, suspended-server checker
#
#  bash <(curl -fsSL https://raw.githubusercontent.com/ashmelanvarp964/iconic-stuffs/main/lumascan.sh)
#
#  Optional args:  scan (default) | telemetry | load | suspended
#  Optional env :  LUMA_VOLUMES, LUMA_CPU (default 85), LUMA_JOBS,
#                  LUMA_PANEL_URL, LUMA_PANEL_KEY
# ============================================================================
 
VERSION="1.0.0"
AUTHOR="LumaCloud Studios By Ashmel"
VOL_ROOT="${LUMA_VOLUMES:-/var/lib/pterodactyl/volumes}"
CPU_LIMIT="${LUMA_CPU:-85}"
CONF_FILE="/etc/lumacloud.conf"
QUARANTINE_ROOT="/var/lib/lumacloud/quarantine"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 
locale -a 2>/dev/null | grep -qi 'c\.utf-\?8' && export LC_ALL=C.UTF-8
JOBS="${LUMA_JOBS:-$(nproc 2>/dev/null || echo 2)}"; [ "$JOBS" -gt 8 ] && JOBS=8
COLS=$(tput cols 2>/dev/null || echo 80); [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
 
# ------------------------------------------------------------------ colors ----
R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
RED=$'\e[38;5;203m'; GRN=$'\e[38;5;84m'; YLW=$'\e[38;5;221m'
CYN=$'\e[38;5;87m'; PUR=$'\e[38;5;141m'; PNK=$'\e[38;5;211m'
GRY=$'\e[38;5;245m'; WHT=$'\e[38;5;255m'; TEAL=$'\e[38;5;43m'; ORG=$'\e[38;5;209m'
 
# -------------------------------------------------------------- signatures ----
BACKDOOR_RE='/dev/tcp/|bash -i >&|nc -e /bin|reverse.?shell|b4ckd00r|hackerman'
NULLED_RE='nulled by|nulled\.to|nulledbb|nulledmc|nulled-?forums|cracked by|crackedby|leaked by|leakedby|blackspigot|leakforums|mc-market-leak'
MINER_CONTENT_RE='stratum\+(tcp|ssl)://|pool\.(supportxmr|minexmr|hashvault|nanopool)|xmrig|cryptonight|randomx'
DDOS_CONTENT_RE='udp.?flood|syn.?flood|slowloris|http.?flood|hping3|ddos.?attack'
PROC_RE='xmrig|minerd|cpuminer|kinsing|kdevtmpfsi|nbminer|t-rex|ethminer|lolminer|stratum\+|hping3|slowloris|masscan|zmap|mhddos|udpflood'
MINER_NAME_ARGS=( -iname 'xmrig*' -o -iname 'minerd*' -o -iname 'cpuminer*' -o -iname 'kinsing*' -o -iname 'kdevtmpfsi*' -o -iname 'nbminer*' -o -iname 't-rex*' -o -iname 'ethminer*' -o -iname 'lolminer*' -o -iname 'phoenixminer*' )
DDOS_NAME_ARGS=( -iname 'hping*' -o -iname 'slowloris*' -o -iname 'loic*' -o -iname 'goldeneye*' -o -iname 'mhddos*' -o -iname 'udpflood*' -o -iname 'synflood*' )
PRUNE_ARGS=( '(' -type d '(' -name 'world*' -o -name logs -o -name libraries -o -name cache -o -name node_modules -o -name backups -o -name versions -o -name .git -o -name '.paper-remapped' -o -name 'paper-remapped' ')' -prune ')' -o )
 
# ----------------------------------------------------------------- temp/cleanup ----
TMP=$(mktemp -d /tmp/lumacloud.XXXXXX)
RES="$TMP/results"; PRG="$TMP/progress"; IDX="$TMP/index"
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
box_row() { # content [extra visual width of wide glyphs]
  local c="$1" x="${2:-0}" n pad
  n=$(vlen "$c"); pad=$((BW-1-n-x)); [ "$pad" -lt 0 ] && pad=0
  printf '  %s│%s %s%*s%s│%s\n' "$GRY" "$R" "$c" "$pad" "" "$GRY" "$R"
}
center() { local n pad; n=$(vlen "$1"); pad=$(( (78-n)/2 )); [ $pad -lt 0 ] && pad=0; printf '%*s%s\n' "$pad" "" "$1"; }
trunc() { local s="$1" n="$2"; if [ ${#s} -gt "$n" ]; then printf '…%s' "${s: -$((n-1))}"; else printf '%s' "$s"; fi; }
 
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
  else
    printf '  \e[1;38;5;51mL\e[38;5;45mU\e[38;5;39mM\e[38;5;75mA\e[38;5;141mC\e[38;5;177mL\e[38;5;141mO\e[38;5;99mU\e[38;5;93mD\e[0m\n'
  fi
  echo
  center "${YLW}⚡${R} ${CYN}${B}NEXT-GEN CLOUD INFRASTRUCTURE${R} ${GRY}•${R} ${PUR}AUTOMATION PLATFORM${R}"
  center "${GRY}Made with Love ♥ & Brain 🧠 by ${R}${B}${WHT}${AUTHOR}${R}"
  center "${GRY}LumaCloud v${VERSION}${R}"
  echo
}
 
header_box() { # title
  local os ip node l1 l2
  os=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"); os=${os:-Linux}
  ip=$(hostname -I 2>/dev/null | awk '{print $1}'); node=$(hostname | tr '[:lower:]' '[:upper:]')
  printf -v l1 '%-42s' "▶ $1"; printf -v l2 '%-42s' "$os"
  box_top
  box_row "${WHT}${B}${l1}${R} ${GRY}Node:${R} ${CYN}${node:0:22}${R}"
  box_row "${GRY}OS:${R} ${B}${l2:0:38}${R}   ${GRY}IP:${R}   ${PNK}${B}${ip}${R}"
  box_bot
  echo
}
 
# ---------------------------------------------------------------- helpers ----
HAVE_DOCKER=0
ensure_pkg() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf '  %sInstalling dependency: %s ...%s\n' "$YLW" "$2" "$R"
  if   command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q "$2" >/dev/null 2>&1
  elif command -v yum     >/dev/null 2>&1; then yum install -y -q "$2" >/dev/null 2>&1; fi
  command -v "$1" >/dev/null 2>&1
}
pause() { echo; read -rp "  ${GRY}Press Enter to continue...${R}" _; }
 
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
spin_wait() { # pid message
  local pid=$1 msg=$2 i=0 t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r\033[K  %s%s%s %s %s(%ds)%s' "$CYN" "${SPIN[i%10]}" "$R" "$msg" "$GRY" $((SECONDS-t0)) "$R"
    i=$((i+1)); sleep 0.1
  done
  printf '\r\033[K'; wait "$pid" 2>/dev/null
}
 
cpu_color() { local v=${1%%.*}; v=${v//[^0-9]/}; v=${v:-0}
  if [ "$v" -ge 70 ]; then printf '%s' "$RED"; elif [ "$v" -ge 30 ]; then printf '%s' "$YLW"; else printf '%s' "$GRN"; fi; }
 
motd_of() {
  local p="$VOL_ROOT/$1/server.properties"
  [ -f "$p" ] && grep -m1 '^motd=' "$p" | cut -d= -f2- | sed -E 's/§.//g; s/\\u00[aA]7.//g; s/&[0-9a-fk-or]//g; s/\\n.*//'
}
srv_label() { # uuid cid
  local m image; m=$(motd_of "$1")
  if [ -f "$VOL_ROOT/$1/server.properties" ]; then echo "MC: ${m:-Minecraft}"; return; fi
  image=$(docker inspect -f '{{.Config.Image}}' "$2" 2>/dev/null)
  case "$image" in
    *java*|*minecraft*|*paper*|*spigot*) echo "MC: Minecraft" ;;
    *node*)   echo "Node: $(basename "${image%%:*}")" ;;
    *python*) echo "Python" ;;
    *)        echo "GameServer" ;;
  esac
}
 
# ------------------------------------------------------- findings storage ----
declare -A SCORE DETAIL PATHS PNAME POWNER PID_ TYPECNT
TOTAL=0
declare -A W=( [BACKDOOR]=10 [MINER]=10 [MINER-PROC]=10 [DDOS]=8 [DDOS-PROC]=8 [NULLED]=3 [CORRUPT]=1 [HIGH-CPU]=2 )
 
uuid_of_path() { local p="${1#$VOL_ROOT/}"; echo "${p%%/*}"; }
add_finding() { # uuid type path evidence
  local u="$1" t="$2" p="$3" e="$4"
  TYPECNT[$u|$t]=$(( ${TYPECNT[$u|$t]:-0} + 1 ))
  [ "${TYPECNT[$u|$t]}" -le 3 ] && SCORE[$u]=$(( ${SCORE[$u]:-0} + ${W[$t]:-1} )) || SCORE[$u]=${SCORE[$u]:-0}
  DETAIL[$u]+="${t}|${p}|${e}"$'\n'
  [ -n "$p" ] && PATHS[$u]+="${p}"$'\n'
  TOTAL=$((TOTAL+1))
}
 
# ------------------------------------------------------ parallel jar workers ----
jar_ok_size() { [ "$(stat -c %s "$1" 2>/dev/null || echo 0)" -le 104857600 ]; }
evidence()    { head -n1 | head -c 40 | tr -cd '[:print:]'; }
chk_backdoor() {
  jar_ok_size "$1" || return
  local m; m=$(unzip -Z1 "$1" 2>/dev/null | grep -aEi -m1 '(^|/)(backdoor|b4ckd00r|hackerman)[^/]*\.class$' | evidence)
  if [ -n "$m" ]; then echo "class: $m"; return; fi
  unzip -p "$1" 2>/dev/null | grep -aEiom1 "$BACKDOOR_RE" | evidence
}
chk_nulled()   { jar_ok_size "$1" && unzip -p "$1" 2>/dev/null | grep -aEiom1 "$NULLED_RE"   | evidence; }
chk_corrupt()  {
  if [ ! -s "$1" ]; then echo "empty file"; return; fi
  unzip -tqq "$1" >/dev/null 2>&1; local rc=$?
  [ "$rc" -lt 2 ] && return                      # 0 = ok, 1 = harmless warnings
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import zipfile,sys; sys.exit(1 if zipfile.ZipFile(sys.argv[1]).testzip() else 0)' "$1" 2>/dev/null; then return; fi
  echo "bad zip structure"
}
worker() { # mode files...
  local mode="$1" f m t; shift
  for f in "$@"; do
    case "$mode" in
      backdoor) t=BACKDOOR; m=$(chk_backdoor "$f") ;;
      nulled)   t=NULLED;   m=$(chk_nulled "$f") ;;
      corrupt)  t=CORRUPT;  m=$(chk_corrupt "$f") ;;
    esac
    [ -n "$m" ] && printf '%s|%s|%s\n' "$t" "$f" "$m" >> "$RES"
    printf '%s\n' "$f" >> "$PRG"
  done
}
export -f worker chk_backdoor chk_nulled chk_corrupt jar_ok_size evidence
export BACKDOOR_RE NULLED_RE RES PRG
 
draw_progress() { # idx label total cur file
  local idx="$1" label="$2" tot="$3" cur="$4" file="$5" w=20 pct=0 f e k fill="" empty="" thr room path=""
  [ "$tot" -gt 0 ] && pct=$(( cur * 100 / tot ))
  f=$(( pct * w / 100 )); e=$(( w - f ))
  for ((k=0;k<f;k++)); do fill+="█"; done; for ((k=0;k<e;k++)); do empty+="░"; done
  thr=$(wc -l < "$RES" 2>/dev/null || echo 0)
  room=$(( COLS - 78 )); [ $room -ge 10 ] && path=" ${GRY}│${R} ${GRY}$(trunc "$file" "$room")${R}"
  printf '\r\033[K  %s⋮%s %s[%s/4 %s]%s %s[%s%s%s%s%s]%s %s%3d%%%s %s│%s Files: %s%d%s %s│%s Threats: %s%d%s%s' \
    "$CYN" "$R" "$B$WHT" "$idx" "$label" "$R" "$GRY" "$PUR" "$fill" "$GRY" "$empty" "$GRY" "$R" "$GRN$B" "$pct" "$R" \
    "$GRY" "$R" "$B" "$tot" "$R" "$GRY" "$R" "$RED$B" "$thr" "$R" "$path"
}
 
run_phase() { # idx label mode
  local idx=$1 label=$2 mode=$3 n=${#FILES[@]} cur last="" pid
  : > "$PRG"
  printf '%s\0' "${FILES[@]}" | xargs -0 -r -P "$JOBS" -n 4 bash -c "worker $mode \"\$@\"" _ &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    cur=$(wc -l < "$PRG"); last=$(tail -n1 "$PRG" 2>/dev/null)
    draw_progress "$idx" "$label" "$n" "$cur" "${last#$VOL_ROOT/}"; sleep 0.15
  done
  wait "$pid" 2>/dev/null
  draw_progress "$idx" "$label" "$n" "$n" "${last#$VOL_ROOT/}"; echo
}
 
# ------------------------------------------------------------- abuse scan ----
abuse_files_job() {
  find "$VOL_ROOT" -maxdepth 6 "${PRUNE_ARGS[@]}" -type f '(' "${MINER_NAME_ARGS[@]}" ')' -print0 2>/dev/null > "$TMP/miner_names"
  find "$VOL_ROOT" -maxdepth 6 "${PRUNE_ARGS[@]}" -type f '(' "${DDOS_NAME_ARGS[@]}" ')' -print0 2>/dev/null > "$TMP/ddos_names"
  find "$VOL_ROOT" -maxdepth 6 "${PRUNE_ARGS[@]}" -type f -size -2M \
    '(' -name '*.sh' -o -name '*.py' -o -name '*.js' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' -o -name '*.cfg' -o -name '*.txt' ')' \
    -not -name 'usercache.json' -print0 2>/dev/null > "$TMP/text_files"
  xargs -0 -r -P "$JOBS" -n 50 grep -IEil "$MINER_CONTENT_RE" < "$TMP/text_files" > "$TMP/miner_hits" 2>/dev/null
  xargs -0 -r -P "$JOBS" -n 50 grep -IEil "$DDOS_CONTENT_RE"  < "$TMP/text_files" > "$TMP/ddos_hits"  2>/dev/null
}
 
phase_abuse() {
  local f m n s name cid line
  : > "$TMP/miner_names"; : > "$TMP/ddos_names"; : > "$TMP/miner_hits"; : > "$TMP/ddos_hits"
  abuse_files_job & spin_wait $! "${B}[4/4 Abuse]${R} ${GRY}hunting miners, DDoS tools & flood scripts...${R}"
  while IFS= read -r -d '' f; do add_finding "$(uuid_of_path "$f")" MINER "$f" "known miner filename"; done < "$TMP/miner_names"
  while IFS= read -r -d '' f; do add_finding "$(uuid_of_path "$f")" DDOS  "$f" "known DDoS tool filename"; done < "$TMP/ddos_names"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    m=$(grep -aEiom1 "$MINER_CONTENT_RE" "$f" 2>/dev/null | evidence)
    add_finding "$(uuid_of_path "$f")" MINER "$f" "${m:-mining pool string}"
  done < "$TMP/miner_hits"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    m=$(grep -aEiom1 "$DDOS_CONTENT_RE" "$f" 2>/dev/null | evidence)
    add_finding "$(uuid_of_path "$f")" DDOS "$f" "${m:-flood string}"
  done < "$TMP/ddos_hits"
 
  if [ "$HAVE_DOCKER" -ne 1 ]; then
    printf '  %sDocker not found — skipping live process & CPU checks.%s\n' "$YLW" "$R"; return
  fi
  printf '  %s⋮%s %sinspecting running processes in containers...%s\n' "$CYN" "$R" "$GRY" "$R"
  while IFS='|' read -r cid name; do
    [[ "$name" =~ $UUID_RE ]] || continue
    line=$(docker top "$cid" -eo pid,pcpu,args 2>/dev/null | tail -n +2 | grep -aEi "$PROC_RE" | head -1)
    if [ -n "$line" ]; then
      m=$(grep -aEiom1 "$PROC_RE" <<< "$line")
      case "$m" in hping3|slowloris|masscan|zmap|mhddos|udpflood) n=DDOS-PROC ;; *) n=MINER-PROC ;; esac
      add_finding "$name" "$n" "" "process: $(awk '{ $1=$2=""; print }' <<< "$line" | cut -c1-60)"
    fi
  done < <(docker ps --format '{{.ID}}|{{.Names}}' 2>/dev/null)
 
  printf '  %s⋮%s %ssampling CPU 3× for sustained abuse...%s\n' "$CYN" "$R" "$GRY" "$R"
  declare -A SUM
  for s in 1 2 3; do
    while IFS='|' read -r name cpu; do
      [[ "$name" =~ $UUID_RE ]] || continue
      cpu=${cpu%\%}; cpu=${cpu%.*}; SUM[$name]=$(( ${SUM[$name]:-0} + ${cpu:-0} ))
    done < <(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}' 2>/dev/null)
    [ "$s" -lt 3 ] && sleep 1
  done
  for name in "${!SUM[@]}"; do
    n=$(( ${SUM[$name]} / 3 ))
    [ "$n" -ge "$CPU_LIMIT" ] && add_finding "$name" HIGH-CPU "" "sustained CPU ${n}% (limit ${CPU_LIMIT}%)"
  done
}
 
# -------------------------------------------------------------- panel API ----
PANEL_OK=0
panel_init() {
  [ -f "$CONF_FILE" ] && . "$CONF_FILE"
  PANEL_URL="${LUMA_PANEL_URL:-${PANEL_URL:-}}"; PANEL_KEY="${LUMA_PANEL_KEY:-${PANEL_KEY:-}}"; PANEL_URL="${PANEL_URL%/}"
  [ -n "$PANEL_URL" ] && [ -n "$PANEL_KEY" ] && ensure_pkg curl curl && ensure_pkg jq jq && PANEL_OK=1
}
panel_configure() {
  [ "$PANEL_OK" -eq 1 ] && return 0
  printf '  %sNeeds your panel URL + an Application API key (Admin ➜ Application API).%s\n' "$GRY" "$R"
  read -rp "  ${CYN}Panel URL (https://panel.example.com): ${R}" PANEL_URL
  read -rsp "  ${CYN}Application API key: ${R}" PANEL_KEY; echo
  PANEL_URL="${PANEL_URL%/}"
  ensure_pkg curl curl && ensure_pkg jq jq || return 1
  PANEL_OK=1
  read -rp "  ${CYN}Save to ${CONF_FILE}? (y/N): ${R}" yn
  [[ "$yn" =~ ^[Yy]$ ]] && { printf 'PANEL_URL=%q\nPANEL_KEY=%q\n' "$PANEL_URL" "$PANEL_KEY" > "$CONF_FILE"; chmod 600 "$CONF_FILE"; }
  return 0
}
panel_lookup() { # uuid
  [ "$PANEL_OK" -eq 1 ] || return
  local r
  r=$(curl -fsS -m 20 -H "Authorization: Bearer $PANEL_KEY" -H "Accept: application/json" \
      "$PANEL_URL/api/application/servers?filter%5Buuid%5D=$1&include=user" 2>/dev/null) || return
  PNAME[$1]=$(jq -r '.data[0].attributes.name // empty' <<< "$r")
  PID_[$1]=$(jq -r '.data[0].attributes.id // empty' <<< "$r")
  POWNER[$1]=$(jq -r '.data[0].attributes.relationships.user.attributes.email // empty' <<< "$r")
}
 
# ------------------------------------------------------------------ report ----
risk_of() { if [ "$1" -ge 10 ]; then echo HIGH; elif [ "$1" -ge 3 ]; then echo MEDIUM; else echo LOW; fi; }
risk_badge() { case "$(risk_of "$1")" in
  HIGH)   printf '%s HIGH %s'   $'\e[1;97;48;5;196m' "$R" ;;
  MEDIUM) printf '%s MEDIUM %s' $'\e[1;30;48;5;221m' "$R" ;;
  *)      printf '%s LOW %s'    $'\e[1;30;48;5;84m'  "$R" ;; esac; }
type_color() { case "$1" in
  BACKDOOR|MINER|MINER-PROC) printf '%s' "$RED$B" ;; DDOS|DDOS-PROC) printf '%s' "$PNK$B" ;;
  NULLED) printf '%s' "$YLW$B" ;; *) printf '%s' "$PUR$B" ;; esac; }
sorted_uuids() { local u; for u in "${!SCORE[@]}"; do echo "${SCORE[$u]} $u"; done | sort -rn | awk '{print $2}'; }
high_uuids()   { local u; for u in $(sorted_uuids); do [ "${SCORE[$u]}" -ge 10 ] && echo "$u"; done; }
 
print_report() {
  local u cid state lbl type p e hi=0 me=0 lo=0 tag rel
  for u in "${!SCORE[@]}"; do case "$(risk_of "${SCORE[$u]}")" in HIGH) hi=$((hi+1));; MEDIUM) me=$((me+1));; *) lo=$((lo+1));; esac; done
  box_top
  box_row "${WHT}${B}SCAN COMPLETE${R}   ${GRY}finished in ${SCAN_SECS}s${R}"
  box_sep
  box_row "${GRY}Servers scanned:${R} ${B}${N_SERVERS}${R}   ${GRY}Jars scanned:${R} ${B}${#FILES[@]}${R}   ${GRY}Findings:${R} ${RED}${B}${TOTAL}${R}"
  box_row "${GRY}Flagged servers:${R} ${RED}${B}${#SCORE[@]}${R}   ${RED}HIGH ${hi}${R}  ${YLW}MEDIUM ${me}${R}  ${GRN}LOW ${lo}${R}"
  box_bot
  if [ ${#SCORE[@]} -eq 0 ]; then echo; printf '  %s✔ No corrupted or abusive servers found. All clear.%s\n' "$GRN$B" "$R"; return; fi
  for u in $(sorted_uuids); do
    cid=""; state=""
    if [ "$HAVE_DOCKER" -eq 1 ]; then cid=$(docker ps -aq --filter "name=$u" 2>/dev/null | head -1); [ -n "$cid" ] && state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null); fi
    lbl=$(motd_of "$u")
    echo
    box_top
    box_row "${RED}${B}● SERVER${R} ${B}${WHT}${u}${R}"
    box_row "${GRY}Risk:${R} $(risk_badge "${SCORE[$u]}") ${GRY}score ${SCORE[$u]}${R}${cid:+   ${GRY}Container:${R} ${B}${cid}${R} ${GRY}(${state:-?})${R}}"
    [ -n "$lbl" ] && box_row "${GRY}MOTD :${R} ${lbl:0:60}"
    [ -n "${PNAME[$u]:-}" ] && box_row "${GRY}Panel:${R} ${PNAME[$u]:0:28}  ${GRY}Owner:${R} ${B}${POWNER[$u]:-?}${R}"
    box_sep
    declare -A SHOWN=(); declare -A TCOUNT=()
    while IFS='|' read -r type p e; do [ -n "$type" ] && TCOUNT[$type]=$(( ${TCOUNT[$type]:-0} + 1 )); done <<< "${DETAIL[$u]}"
    while IFS='|' read -r type p e; do
      [ -z "$type" ] && continue
      SHOWN[$type]=$(( ${SHOWN[$type]:-0} + 1 ))
      if [ "${SHOWN[$type]}" -gt 5 ]; then
        [ "${SHOWN[$type]}" -eq 6 ] && box_row "$(type_color "$type")[$(printf '%-10s' "$type")]${R} ${GRY}… +$(( ${TCOUNT[$type]} - 5 )) more (see saved report)${R}"
        continue
      fi
      printf -v tag '%-10s' "$type"
      if [ -n "$p" ]; then rel=${p#$VOL_ROOT/*/}; box_row "$(type_color "$type")[${tag}]${R} $(trunc "$rel" 32) ${GRY}(${e:0:22})${R}"
      else box_row "$(type_color "$type")[${tag}]${R} ${GRY}${e:0:56}${R}"; fi
    done <<< "${DETAIL[$u]}"
    box_bot
  done
  echo; printf '  %sSignature-based heuristics — review findings before taking action.%s\n' "$GRY" "$R"
}
 
# ------------------------------------------------------------ telemetry views ----
collect_telemetry() { # cid|uuid|label|cpu|mem|pct sorted by cpu desc
  docker stats --no-stream --format '{{.ID}}|{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' 2>/dev/null \
  | while IFS='|' read -r cid name cpu mem pct; do
      [[ "$name" =~ $UUID_RE ]] || continue
      printf '%s|%s|%s|%s|%s|%s\n' "$cid" "$name" "$(srv_label "$name" "$cid")" "${cpu%\%}" "$mem" "${pct%\%}"
    done | sort -t'|' -k4 -rn
}
 
show_telemetry() {
  banner; header_box "LUMACLOUD LIVE TELEMETRY"
  printf '  %s◎ Sampling real-time resource telemetry across active game servers...%s\n\n' "$RED" "$R"
  local data; data=$(collect_telemetry)
  [ -z "$data" ] && { printf '  %sNo running Pterodactyl containers found.%s\n' "$YLW" "$R"; return; }
  local cid uuid lbl cpu mem pct first=1 flame a b c d
  box_top
  printf -v a '%-13s' "CONTAINER ID"; printf -v b '%-23s' "SERVER UUID / TYPE"; printf -v c '%-8s' "CPU LOAD"
  box_row "${WHT}${B}${a}${R}${RED}${b}${R}${WHT}${B}${c}${R}   ${RED}RAM USAGE (MEM %)${R}"
  box_sep
  while IFS='|' read -r cid uuid lbl cpu mem pct; do
    printf -v a '%-13s' "$cid"
    printf -v b '%-9s' "${uuid:0:8}"
    printf -v c '%-14s' "[${lbl:0:12}"
    printf -v d '%-8s' "${cpu}%"
    if [ $first -eq 1 ]; then flame="🔥"; box_row "${B}${a}${R}${RED}${b}${c}${R}$(cpu_color "$cpu")${B}${d}${R}${flame} ${GRY}${mem} (${pct}%)${R}" 1
    else flame="  "; box_row "${B}${a}${R}${RED}${b}${c}${R}$(cpu_color "$cpu")${B}${d}${R}${flame} ${GRY}${mem} (${pct}%)${R}"; fi
    first=0
  done <<< "$data"
  box_bot
}
 
view_server() { # container id
  local cid="$1" uuid stats cpu mem pct lbl top pid pcpu pmem ptime pargs comm a b c d
  uuid=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')
  [ -z "$uuid" ] && { printf '  %s✖ Container not found: %s%s\n' "$RED" "$cid" "$R"; return 1; }
  stats=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}' "$cid" 2>/dev/null)
  IFS='|' read -r cpu mem pct <<< "$stats"; lbl=$(srv_label "$uuid" "$cid")
  top=$(docker top "$cid" -eo pid,pcpu,pmem,time,args 2>/dev/null | tail -n +2 | sort -k2 -rn | head -1)
  pid=$(awk '{print $1}' <<< "$top"); pcpu=$(awk '{print $2}' <<< "$top"); pmem=$(awk '{print $3}' <<< "$top"); ptime=$(awk '{print $4}' <<< "$top")
  pargs=$(awk '{ $1=$2=$3=$4=""; sub(/^ +/,""); print }' <<< "$top"); comm=$(basename "$(awk '{print $1}' <<< "$pargs")" 2>/dev/null)
  printf -v a '%-14s' "$cid"; printf -v b '%-14s' "$cpu"
  box_top
  box_row "${YLW}${B}Server UUID ${R}  ${GRY}:${R} ${RED}${uuid}${R}"
  box_row "${YLW}${B}Container ID${R}  ${GRY}:${R} ${B}${a}${R}${B}Game/Tag:${R} ${RED}[${lbl:0:24}]${R}"
  box_row "${YLW}${B}Current CPU${R}   ${GRY}:${R} $(cpu_color "$cpu")${B}${b}${R}${B}RAM Usage:${R} ${RED}${mem} (${pct})${R}"
  box_sep
  box_row "${YLW}${B}WHAT IS CONSUMING THE HIGHEST LOAD ON THIS SERVER:${R}"
  box_row ""
  printf -v a '%-9s' "PID"; printf -v b '%-9s' "CPU %"; printf -v c '%-9s' "MEM %"; printf -v d '%-11s' "TIME"
  box_row "${GRY}${a}${R}${RED}${B}${b}${R}${WHT}${B}${c}${R}${GRY}${d}${R}${RED}PROCESS / THREAD${R}"
  printf -v a '%-9s' "${pid:--}"; printf -v b '%-9s' "${pcpu:-0}%"; printf -v c '%-9s' "${pmem:-0}%"; printf -v d '%-11s' "${ptime:--}"
  box_row "${GRY}${a}${R}${RED}${b}${R}${RED}${c}${R}${GRY}${d}${R}${B}${WHT}${comm:-unknown}${R}"
  box_sep
  if [[ "$pargs" == *java* ]]; then
    local jar xmx xms cause cv
    jar=$(grep -oE '[^ ]+\.jar' <<< "$pargs" | head -1); jar=$(basename "${jar:-N/A}")
    xmx=$(grep -oE '\-Xmx[0-9]+[kKmMgG]' <<< "$pargs" | head -1); xmx=${xmx:-N/A}
    xms=$(grep -oE '\-Xms[0-9]+[kKmMgG]' <<< "$pargs" | head -1); xms=${xms:-N/A}
    cv=${cpu%%.*}; cv=${cv//[^0-9]/}; cv=${cv:-0}
    if   [ "$cv" -ge 80 ]; then cause="High tick load on entity physics, plugins or world chunk generation"
    elif [ "$cv" -ge 40 ]; then cause="Elevated load — check plugins, redstone and loaded chunks"
    else cause="Load looks normal"; fi
    printf -v a '%-26s' "$jar"
    box_row "${GRN}⚡ JAVA / MINECRAFT DIAGNOSTICS:${R}"
    box_row "${GRY}Server Jar:${R} ${B}${a}${R}${GRY}Max Memory (Xmx):${R} ${xmx}"
    box_row "${GRY}Init Heap (Xms):${R} ${B}${xms}${R}"
    box_row "${GRY}Load Cause:${R} ${YLW}${cause:0:60}${R}"
  else
    box_row "${GRN}⚡ PROCESS DIAGNOSTICS:${R}"
    box_row "${GRY}Command:${R} ${B}${pargs:0:62}${R}"
  fi
  box_bot
}
 
highest_load_menu() {
  local top_cid="" ch cid yn
  while true; do
    banner
    printf '  %s🔥 HIGHEST LOAD SERVER IDENTIFIED:%s\n\n' "$ORG$B" "$R"
    [ -z "$top_cid" ] && top_cid=$(collect_telemetry | head -1 | cut -d'|' -f1)
    [ -z "$top_cid" ] && { printf '  %sNo running game servers found.%s\n' "$YLW" "$R"; pause; return; }
    view_server "$top_cid"
    echo
    printf '  Actions:\n'
    printf '    %s[1]%s %sRefresh Telemetry & Live Loads%s\n' "$B" "$R" "$RED" "$R"
    printf '    %s[2]%s %sInspect Real-Time Logs of Highest Load Server%s %s(docker logs)%s\n' "$B" "$R" "$RED" "$R" "$GRY" "$R"
    printf '    %s[3]%s %sInspect Specific Server by Container ID / Number%s\n' "$B" "$R" "$YLW" "$R"
    printf '    %s[4]%s %sRestart Highest Load Server Container%s\n' "$B" "$R" "$RED" "$R"
    printf '    %s[0] Return to Main Menu%s\n\n' "$GRY" "$R"
    read -rp "  ${CYN}Select ➜ ${R}" ch
    case "$ch" in
      1) top_cid="" ;;
      2) printf '  %sStreaming logs — Ctrl+C to return.%s\n' "$GRY" "$R"; sleep 1
         trap ':' INT; docker logs --tail 100 -f "$top_cid"; trap 'cleanup; echo; exit 130' INT ;;
      3) read -rp "  ${CYN}Container ID or list number: ${R}" cid
         [[ "$cid" =~ ^[0-9]{1,3}$ ]] && cid=$(collect_telemetry | sed -n "${cid}p" | cut -d'|' -f1)
         [ -n "$cid" ] && { banner; view_server "$cid"; pause; } ;;
      4) read -rp "  ${RED}Restart container ${top_cid}? (y/N): ${R}" yn
         [[ "$yn" =~ ^[Yy]$ ]] && { docker restart "$top_cid" >/dev/null 2>&1 && printf '  %s✔ Restarted.%s\n' "$GRN" "$R" || printf '  %s✖ Failed.%s\n' "$RED" "$R"; sleep 2; top_cid=""; } ;;
      0|"") return ;;
    esac
  done
}
 
# -------------------------------------------------------- suspended checker ----
suspended_check() {
  banner; header_box "SUSPENDED SERVER CHECKER"
  ensure_pkg curl curl && ensure_pkg jq jq || { pause; return; }
  panel_configure || { pause; return; }
  local page=1 pages=1 total=0 checked=0 susp=0 resp name uuid sflag sp='|/-\' first=1 a yn
  local LIST=()
  draw_block() {
    [ $first -eq 0 ] && printf '\033[6A'; first=0
    printf '\033[K%s%sChecking %s Servers%s\n' "$B" "$WHT" "$total" "$R"
    printf '\033[K%sRemaining:%s %s%d%s\n' "$GRY" "$R" "$YLW$B" $((total-checked)) "$R"
    printf '\033[K%sChecked:%s   %s%d%s\n'  "$GRY" "$R" "$GRN$B" "$checked" "$R"
    printf '\033[K%sSuspended:%s %s%d%s\n'  "$GRY" "$R" "$RED$B" "$susp" "$R"
    printf '\033[K\n'
    printf '\033[K%sChecking Servers...%s %s%s%s\n' "$CYN" "$R" "$PUR$B" "${sp:checked%4:1}" "$R"
  }
  while [ "$page" -le "$pages" ]; do
    resp=$(curl -fsS -m 30 -H "Authorization: Bearer $PANEL_KEY" -H "Accept: application/json" \
      "$PANEL_URL/api/application/servers?per_page=100&page=$page" 2>/dev/null)
    if ! jq -e '.data' >/dev/null 2>&1 <<< "$resp"; then
      printf '\n  %s✖ API request failed — check panel URL / API key (needs Servers: read).%s\n' "$RED" "$R"; pause; return
    fi
    total=$(jq -r '.meta.pagination.total' <<< "$resp"); pages=$(jq -r '.meta.pagination.total_pages' <<< "$resp")
    while IFS='|' read -r name uuid sflag; do
      checked=$((checked+1))
      [ "$sflag" = "true" ] && { susp=$((susp+1)); LIST+=("$name|$uuid"); }
      draw_block
    done < <(jq -r '.data[].attributes | "\(.name)|\(.uuid)|\(.suspended)"' <<< "$resp")
    page=$((page+1))
  done
  echo
  if [ "$susp" -eq 0 ]; then printf '  %s✔ No suspended servers.%s\n' "$GRN$B" "$R"; pause; return; fi
  box_top; box_row "${RED}${B}SUSPENDED SERVERS (${susp})${R}"; box_sep
  local s run
  for s in "${LIST[@]}"; do
    name=${s%%|*}; uuid=${s#*|}; run=""
    [ "$HAVE_DOCKER" -eq 1 ] && [ -n "$(docker ps -q --filter "name=$uuid" 2>/dev/null)" ] && run="${YLW}still running here${R}"
    printf -v a '%-30s' "${name:0:28}"
    box_row "${RED}•${R} ${a}${GRY}${uuid:0:8}${R}  ${run}"
  done
  box_bot; echo
  if [ "$HAVE_DOCKER" -eq 1 ]; then
    read -rp "  ${YLW}Stop suspended servers' containers running on THIS node? (y/N): ${R}" yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      for s in "${LIST[@]}"; do uuid=${s#*|}
        docker ps -q --filter "name=$uuid" | xargs -r docker stop >/dev/null 2>&1 && printf '  %s✔ stopped %s…%s\n' "$GRN" "${uuid:0:8}" "$R"
      done
    fi
  fi
  pause
}
 
# ------------------------------------------------------------------ actions ----
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
  printf '  %s✔ Quarantined %d file(s) → %s%s\n' "$GRN" "$cnt" "$qdir" "$R"
}
do_stop() {
  [ "$HAVE_DOCKER" -eq 1 ] || { printf '  %s✖ Docker not available.%s\n' "$RED" "$R"; return; }
  local u cid
  for u in $(high_uuids); do
    cid=$(docker ps -q --filter "name=$u" | head -1)
    [ -n "$cid" ] && docker stop "$cid" >/dev/null 2>&1 && printf '  %s✔ Stopped %s…%s\n' "$GRN" "${u:0:8}" "$R"
  done
}
do_suspend() {
  panel_configure || return
  local u code
  for u in $(high_uuids); do
    [ -z "${PID_[$u]:-}" ] && panel_lookup "$u"
    [ -z "${PID_[$u]:-}" ] && { printf '  %s✖ %s… not found on panel%s\n' "$RED" "${u:0:8}" "$R"; continue; }
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST -H "Authorization: Bearer $PANEL_KEY" -H "Accept: application/json" \
      "$PANEL_URL/api/application/servers/${PID_[$u]}/suspend")
    [ "$code" = "204" ] && printf '  %s✔ Suspended %s%s\n' "$GRN" "${PNAME[$u]:-$u}" "$R" || printf '  %s✖ %s… suspend failed (HTTP %s)%s\n' "$RED" "${u:0:8}" "$code" "$R"
  done
}
do_export() {
  local out="/root/lumacloud-report-$(date +%Y%m%d-%H%M%S).txt"
  print_report | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' > "$out"
  printf '  %s✔ Report saved: %s%s\n' "$GRN" "$out" "$R"
}
 
actions_menu() {
  local ch yn hi
  while true; do
    hi=$(high_uuids | wc -l)
    echo
    printf '  %sActions:%s  %s(HIGH-risk servers: %s)%s\n' "$B" "$R" "$GRY" "$hi" "$R"
    printf '    %s[1]%s %sQuarantine all flagged files%s %s(moved, never deleted)%s\n' "$B" "$R" "$YLW" "$R" "$GRY" "$R"
    printf '    %s[2]%s %sStop containers of HIGH-risk servers%s\n' "$B" "$R" "$RED" "$R"
    printf '    %s[3]%s %sSuspend HIGH-risk servers on the panel%s\n' "$B" "$R" "$RED" "$R"
    printf '    %s[4]%s %sLive Resource Telemetry%s\n' "$B" "$R" "$CYN" "$R"
    printf '    %s[5]%s %sHighest Load Server Diagnostics%s\n' "$B" "$R" "$ORG" "$R"
    printf '    %s[6]%s %sSuspended Server Checker%s\n' "$B" "$R" "$PUR" "$R"
    printf '    %s[7]%s %sSave report to file%s\n' "$B" "$R" "$TEAL" "$R"
    printf '    %s[0] Exit%s\n\n' "$GRY" "$R"
    read -rp "  ${CYN}Select ➜ ${R}" ch
    case "$ch" in
      1) read -rp "  ${YLW}Quarantine ALL flagged files? (y/N): ${R}" yn; [[ "$yn" =~ ^[Yy]$ ]] && do_quarantine ;;
      2) read -rp "  ${RED}Stop ${hi} HIGH-risk container(s)? (y/N): ${R}" yn; [[ "$yn" =~ ^[Yy]$ ]] && do_stop ;;
      3) read -rp "  ${RED}Suspend ${hi} HIGH-risk server(s) on panel? (y/N): ${R}" yn; [[ "$yn" =~ ^[Yy]$ ]] && do_suspend ;;
      4) show_telemetry; pause ;;
      5) highest_load_menu ;;
      6) suspended_check ;;
      7) do_export ;;
      0|q|Q|"") printf '\n  %sBye from LumaCloud 👋%s\n\n' "$GRY" "$R"; return ;;
    esac
  done
}
 
# --------------------------------------------------------------------- scan ----
run_scan() {
  local t0=$SECONDS u t p m
  banner; header_box "PTERODACTYL THREAT & ABUSE SCANNER"
  printf '  %s⚙ Scanning Pterodactyl Game Server volumes for Nulled, Corrupted & Abusive content...%s\n' "$PUR" "$R"
  printf '  %sTarget Root :%s %s%s%s   %sThreads:%s %s%s%s\n\n' "$GRY" "$R" "$B" "$VOL_ROOT" "$R" "$GRY" "$R" "$B" "$JOBS" "$R"
  : > "$RES"; : > "$IDX"
  ( find "$VOL_ROOT" -maxdepth 5 "${PRUNE_ARGS[@]}" -type f -name '*.jar' -print0 2>/dev/null > "$IDX" ) &
  spin_wait $! "${GRY}indexing server volumes...${R}"
  mapfile -d '' -t FILES < "$IDX"
  N_SERVERS=$(find "$VOL_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  if [ ${#FILES[@]} -gt 0 ]; then
    run_phase 1 "Backdoors" backdoor
    run_phase 2 "Nulled   " nulled
    run_phase 3 "Corrupted" corrupt
    while IFS='|' read -r t p m; do
      [ -z "$t" ] && continue
      add_finding "$(uuid_of_path "$p")" "$t" "$p" "$m"
    done < "$RES"
  else
    printf '  %sNo .jar files found — skipping plugin phases.%s\n' "$YLW" "$R"
  fi
  phase_abuse
  if [ "$PANEL_OK" -eq 1 ] && [ ${#SCORE[@]} -gt 0 ]; then
    printf '  %s⋮%s %slooking up owners on the panel...%s\n' "$CYN" "$R" "$GRY" "$R"
    for u in "${!SCORE[@]}"; do panel_lookup "$u"; done
  fi
  SCAN_SECS=$((SECONDS-t0))
  echo; print_report
}
 
# --------------------------------------------------------------------- main ----
main() {
  [ "$(id -u)" -eq 0 ] || { printf '%s✖ Run as root (sudo -i).%s\n' "$RED" "$R"; exit 1; }
  command -v docker >/dev/null 2>&1 && HAVE_DOCKER=1
  ensure_pkg unzip unzip || { printf '%s✖ unzip is required.%s\n' "$RED" "$R"; exit 1; }
  panel_init
  case "${1:-scan}" in
    telemetry) [ $HAVE_DOCKER -eq 1 ] || { echo "Docker required."; exit 1; }; show_telemetry; exit 0 ;;
    load)      [ $HAVE_DOCKER -eq 1 ] || { echo "Docker required."; exit 1; }; highest_load_menu; exit 0 ;;
    suspended) suspended_check; exit 0 ;;
  esac
  [ -d "$VOL_ROOT" ] || { printf '%s✖ Volumes path not found: %s%s\n' "$RED" "$VOL_ROOT" "$R"; exit 1; }
  run_scan
  actions_menu
}
main "$@"
 
