#!/bin/sh

############################################################
#                                                          #
#                 ICONICOP PROOT SYSTEM                    #
#                   Ubuntu 22.04 LTS VM                    #
#                                                          #
#            Fast • Stable • Optimized • Modern            #
#                                                          #
############################################################

############################
# ROOTFS DIRECTORY
############################

ROOTFS_DIR="$(pwd)"

export PATH="$PATH:$HOME/.local/usr/bin"

############################
# SETTINGS
############################

MAX_RETRIES=50
TIMEOUT=10

############################
# COLORS
############################

RESET='\033[0m'

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'

############################
# ARCH DETECTION
############################

ARCH="$(uname -m)"

case "$ARCH" in
    x86_64)
        ARCH_ALT="amd64"
        ;;
    aarch64|arm64)
        ARCH_ALT="arm64"
        ;;
    *)
        echo -e "${RED}[ERROR] Unsupported architecture: $ARCH${RESET}"
        exit 1
        ;;
esac

############################
# ASCII LOGO
############################

show_logo() {

clear

echo -e "${MAGENTA}"

cat << "EOF"

██╗  ██╗ ██████╗ ██████╗ ██╗███╗   ██╗ ██████╗ 
██║  ██║██╔═══██╗██╔══██╗██║████╗  ██║██╔════╝ 
███████║██║   ██║██████╔╝██║██╔██╗ ██║██║  ███╗
██╔══██║██║   ██║██╔═══╝ ██║██║╚██╗██║██║   ██║
██║  ██║╚██████╔╝██║     ██║██║ ╚████║╚██████╔╝
╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═══╝ ╚═════╝ 

██████╗  ██████╗ ██╗   ██╗███████╗
██╔══██╗██╔═══██╗╚██╗ ██╔╝╚══███╔╝
██████╔╝██║   ██║ ╚████╔╝   ███╔╝ 
██╔══██╗██║   ██║  ╚██╔╝   ███╔╝  
██████╔╝╚██████╔╝   ██║   ███████╗
╚═════╝  ╚═════╝    ╚═╝   ╚══════╝

EOF

echo -e "${RESET}"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}          Ubuntu 22.04 LTS Proot VM${RESET}"
echo -e "${YELLOW}             Powered By ICONICOP${RESET}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

echo ""
}

############################
# INSTALL DEPENDENCIES
############################

install_dependencies() {

echo -e "${CYAN}[*] Checking dependencies...${RESET}"

if ! command -v wget >/dev/null 2>&1; then

    echo -e "${YELLOW}[*] Installing required packages...${RESET}"

    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install wget curl tar xz-utils proot git -y

    elif command -v apk >/dev/null 2>&1; then
        apk add wget curl tar xz proot git

    elif command -v yum >/dev/null 2>&1; then
        yum install wget curl tar xz proot git -y

    else
        echo -e "${RED}[ERROR] Unsupported package manager.${RESET}"
        exit 1
    fi
fi
}

############################
# INSTALL UBUNTU ROOTFS
############################

install_ubuntu() {

UBUNTU_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04.5-base-${ARCH_ALT}.tar.gz"

echo -e "${CYAN}[*] Downloading Ubuntu 22.04 RootFS...${RESET}"

wget \
--tries="$MAX_RETRIES" \
--timeout="$TIMEOUT" \
--show-progress \
--no-hsts \
-O /tmp/rootfs.tar.gz \
"$UBUNTU_URL"

if [ ! -f /tmp/rootfs.tar.gz ]; then
    echo -e "${RED}[ERROR] Failed to download Ubuntu RootFS.${RESET}"
    exit 1
fi

echo -e "${GREEN}[*] Extracting Ubuntu filesystem...${RESET}"

tar -xpf /tmp/rootfs.tar.gz -C "$ROOTFS_DIR"

if [ $? -ne 0 ]; then
    echo -e "${RED}[ERROR] Extraction failed.${RESET}"
    exit 1
fi

rm -f /tmp/rootfs.tar.gz
}

############################
# DOWNLOAD PROOT
############################

download_proot() {

mkdir -p "$ROOTFS_DIR/usr/local/bin"

echo -e "${CYAN}[*] Downloading PRoot binary...${RESET}"

wget \
--tries="$MAX_RETRIES" \
--timeout="$TIMEOUT" \
--show-progress \
--no-hsts \
-O "$ROOTFS_DIR/usr/local/bin/proot" \
"https://proot.gitlab.io/proot/bin/proot"

chmod +x "$ROOTFS_DIR/usr/local/bin/proot"
}

############################
# CONFIGURE SYSTEM
############################

configure_system() {

echo -e "${CYAN}[*] Configuring Ubuntu environment...${RESET}"

echo "nameserver 1.1.1.1" > "$ROOTFS_DIR/etc/resolv.conf"
echo "nameserver 8.8.8.8" >> "$ROOTFS_DIR/etc/resolv.conf"

cat > "$ROOTFS_DIR/root/setup.sh" << 'EOF'
#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

apt update -y

apt install -y \
sudo \
curl \
wget \
nano \
vim \
git \
htop \
neofetch \
net-tools \
openssh-server \
ca-certificates \
software-properties-common \
zip \
unzip \
screen \
tmux \
python3 \
python3-pip

echo "root:root" | chpasswd

mkdir -p /var/run/sshd

echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

clear

echo ""
echo "======================================"
echo "      ICONICOP UBUNTU READY"
echo "======================================"
echo ""

neofetch

EOF

chmod +x "$ROOTFS_DIR/root/setup.sh"

touch "$ROOTFS_DIR/.installed"
}

############################
# SAFE VARIABLE DISPLAY
############################

safe_var() {

VALUE="$1"

if [ -z "$VALUE" ]; then
    echo "Not Available"
else
    echo "$VALUE"
fi
}

############################
# SYSTEM INFORMATION
############################

show_system_info() {

# RAM INFO
RAM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
RAM_USED=$(free -m | awk '/Mem:/ {print $3}')
RAM_FREE=$(free -m | awk '/Mem:/ {print $4}')

# CPU INFO
CPU_MODEL=$(grep -m 1 "model name" /proc/cpuinfo | cut -d ':' -f2 | sed 's/^[ \t]*//')
CPU_CORES=$(nproc)

# DISK INFO
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_FREE=$(df -h / | awk 'NR==2 {print $4}')

# NETWORK INFO
IP_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')

# HOSTNAME
HOST_NAME=$(hostname)

# KERNEL
KERNEL_VER=$(uname -r)

# UPTIME
UPTIME_INFO=$(uptime -p)

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

echo -e "${GREEN}SYSTEM INFORMATION${RESET}"

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

echo ""

echo -e "${YELLOW}OS:${RESET} Ubuntu 22.04 LTS"
echo -e "${YELLOW}Architecture:${RESET} $ARCH"
echo -e "${YELLOW}Kernel:${RESET} $KERNEL_VER"
echo -e "${YELLOW}Hostname:${RESET} $HOST_NAME"

echo ""

echo -e "${GREEN}CPU Information${RESET}"
echo -e "CPU Model : ${WHITE}$CPU_MODEL${RESET}"
echo -e "CPU Cores : ${WHITE}$CPU_CORES${RESET}"

echo ""

echo -e "${GREEN}RAM Information${RESET}"
echo -e "Total RAM : ${WHITE}${RAM_TOTAL} MB${RESET}"
echo -e "Used RAM  : ${WHITE}${RAM_USED} MB${RESET}"
echo -e "Free RAM  : ${WHITE}${RAM_FREE} MB${RESET}"

echo ""

echo -e "${GREEN}Disk Information${RESET}"
echo -e "Disk Total : ${WHITE}$DISK_TOTAL${RESET}"
echo -e "Disk Used  : ${WHITE}$DISK_USED${RESET}"
echo -e "Disk Free  : ${WHITE}$DISK_FREE${RESET}"

echo ""

echo -e "${GREEN}Network Information${RESET}"
echo -e "IP Address : ${WHITE}${IP_ADDRESS:-Not Available}${RESET}"

echo ""

echo -e "${GREEN}Container Information${RESET}"
echo -e "RootFS Path : ${WHITE}$ROOTFS_DIR${RESET}"
echo -e "Uptime      : ${WHITE}$UPTIME_INFO${RESET}"

echo ""

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

echo ""
echo -e "${MAGENTA}[*] Launching ICONICOP Ubuntu VM...${RESET}"
echo ""
}

############################
# MAIN EXECUTION
############################

show_logo

install_dependencies

if [ ! -f "$ROOTFS_DIR/.installed" ]; then

    echo -e "${YELLOW}[*] First launch detected.${RESET}"

    install_ubuntu

    download_proot

    configure_system

    echo -e "${GREEN}[*] Ubuntu installation completed successfully.${RESET}"

fi

show_system_info

############################
# START PROOT
############################

exec "$ROOTFS_DIR/usr/local/bin/proot" \
--rootfs="$ROOTFS_DIR" \
-0 \
-w /root \
-b /dev \
-b /sys \
-b /proc \
-b /tmp \
-b /etc/resolv.conf \
--kill-on-exit \
/usr/bin/env -i \
HOME=/root \
TERM="$TERM" \
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
/bin/bash --login
