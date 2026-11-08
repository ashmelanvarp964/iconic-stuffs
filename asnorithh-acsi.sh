#!/bin/bash
# ==========================================
# Asnorith Technologies Premium MOTD Installer
# FULL CLEAN + ONLY CUSTOM MOTD
# ==========================================

set -e

echo "🔧 Installing Asnorith Technologies Premium MOTD..."

# ================================
# REMOVE ALL OLD MOTD SYSTEM
# ================================
echo "🧹 Removing old MOTD completely..."

chmod -x /etc/update-motd.d/* 2>/dev/null || true
rm -f /etc/motd
rm -f /var/run/motd
rm -f /run/motd.dynamic

if [ -f /etc/default/motd-news ]; then
    sed -i 's/ENABLED=1/ENABLED=0/g' /etc/default/motd-news
fi

# ================================
# FORCE ONLY OUR MOTD (PAM FIX)
# ================================
echo "⚙ Configuring PAM..."

cp /etc/pam.d/sshd /etc/pam.d/sshd.bak 2>/dev/null || true
cp /etc/pam.d/login /etc/pam.d/login.bak 2>/dev/null || true

sed -i '/pam_motd.so/d' /etc/pam.d/sshd
sed -i '/pam_motd.so/d' /etc/pam.d/login

echo "session optional pam_exec.so stdout /etc/update-motd.d/00-asnorith" >> /etc/pam.d/sshd
echo "session optional pam_exec.so stdout /etc/update-motd.d/00-asnorith" >> /etc/pam.d/login

# ================================
# CREATE PREMIUM MOTD SCRIPT
# ================================
echo "✨ Creating Asnorith Technologies MOTD..."

cat << 'EOF' > /etc/update-motd.d/00-asnorith
#!/bin/bash

# ===== Colors =====
GREEN="\e[38;5;82m"
CYAN="\e[38;5;51m"
BLUE="\e[38;5;39m"
MAGENTA="\e[38;5;213m"
YELLOW="\e[38;5;220m"
GRAY="\e[38;5;245m"
RESET="\e[0m"

# ===== System Info =====
HOSTNAME=$(hostname)
OS=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
UPTIME=$(uptime -p | sed 's/up //')
CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8"%"}')

MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
MEM_PERC=$((MEM_USED * 100 / MEM_TOTAL))

DISK=$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')

IP=$(hostname -I | awk '{print $1}')
USERS=$(who | wc -l)
PROCS=$(ps -e --no-headers | wc -l)

echo ""

# ===== LOGO =====
echo -e "${CYAN}"
cat << "LOGO"
 █████   ███████  ██   ██   █████   ██████   ███████  ███████  ██   ██
██   ██  ██       ███  ██  ██   ██  ██   ██     ██       ██    ██   ██
██   ██  ██       ████ ██  ██   ██  ██   ██     ██       ██    ███████
███████  ███████  ██ ████  ██   ██  ██████      ██       ██    ██   ██
██   ██       ██  ██  ███  ██   ██  ██ ██       ██       ██    ██   ██
██   ██       ██  ██   ██  ██   ██  ██  ██      ██       ██    ██   ██
██   ██  ███████  ██   ██   █████   ██   ██  ███████     ██    ██   ██
LOGO
echo -e "${RESET}"

# ===== HEADER =====
echo -e "${GREEN}🚀 Welcome to Asnorith Technologies${RESET}"
echo -e "${BLUE}High Performance • Secure • Reliable Infrastructure${RESET}"
echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# ===== STATS =====
printf "${CYAN}%-18s${RESET} %s\n" "Hostname:" "$HOSTNAME"
printf "${CYAN}%-18s${RESET} %s\n" "OS:" "$OS"
printf "${CYAN}%-18s${RESET} %s\n" "Kernel:" "$KERNEL"
printf "${CYAN}%-18s${RESET} %s\n" "Uptime:" "$UPTIME"
printf "${CYAN}%-18s${RESET} %s\n" "CPU Usage:" "$CPU"
printf "${CYAN}%-18s${RESET} %sMB / %sMB (${YELLOW}%s%%${RESET})\n" "Memory:" "$MEM_USED" "$MEM_TOTAL" "$MEM_PERC"
printf "${CYAN}%-18s${RESET} %s\n" "Disk:" "$DISK"
printf "${CYAN}%-18s${RESET} %s\n" "Processes:" "$PROCS"
printf "${CYAN}%-18s${RESET} %s\n" "Users:" "$USERS"
printf "${CYAN}%-18s${RESET} %s\n" "IP:" "$IP"

echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# ===== FOOTER =====
echo -e "${GREEN}Support:${RESET}  support@asnorith.info"
echo -e "${GREEN}Discord:${RESET}  https://discord.gg/PdYZunufY"
echo -e "${GREEN}Website:${RESET}  https://asnorith.info"
echo -e "${MAGENTA}Asnorith Technologies — Premium Hosting Experience 💎${RESET}"
echo ""
EOF

chmod +x /etc/update-motd.d/00-asnorith

# ================================
# RESTART SERVICES
# ================================
systemctl restart ssh 2>/dev/null || true

echo ""
echo "✅ Asnorith Technologies MOTD Installed (ONLY MODE ENABLED)"
echo "🚫 All default MOTD fully removed"
echo "🔥 Only your custom MOTD will show"
echo "➡ Reconnect SSH to see changes"
