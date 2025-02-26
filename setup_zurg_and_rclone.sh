#!/bin/bash

# setup_zurg_and_rclone.sh

# Include common functions
if [ ! -f "./common_functions.sh" ]; then
    echo "Error: common_functions.sh not found in the current directory."
    exit 1
fi
source ./common_functions.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to detect the operating system
detect_os() {
    if [[ -e /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

# Detect OS
OS_NAME=$(detect_os)

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run with administrative privileges. Please run with sudo.${NC}"
    exit 1
fi

# Ensure SUDO_USER is set
if [ -z "$SUDO_USER" ]; then
    echo -e "${RED}Error: SUDO_USER is not set. Please run the script using sudo.${NC}"
    exit 1
fi

echo -e "${GREEN}Running setup_zurg_and_rclone.sh...${NC}"

echo -e "${GREEN}Setting up Zurg and Rclone...${NC}"

# Get PUID and PGID from the user who invoked sudo
PUID=$(id -u "$SUDO_USER")
PGID=$(id -g "$SUDO_USER")

# Export PUID, PGID, and TZ to be used in docker-compose.yml
export PUID PGID
export TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")

# Check if Zurg container is already running
zurg_running=$(docker ps --filter "name=zurg" --filter "status=running" -q)
if [[ -n "$zurg_running" ]]; then
    echo -e "${YELLOW}Zurg is already running. Skipping container setup.${NC}"
else
    # Prompt for Real-Debrid API Key directly
    read -p "Enter your Real-Debrid API Key: " REAL_DEBRID_API_KEY
    if [ -z "$REAL_DEBRID_API_KEY" ]; then
        echo -e "${RED}Error: Real-Debrid API Key cannot be empty.${NC}"
        exit 1
    fi

    # Clone zurg-testing repository if 'zurg' directory doesn't exist
    if [ ! -d "zurg" ]; then
        git clone https://github.com/debridmediamanager/zurg-testing.git zurg
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to clone zurg-testing repository.${NC}"
            exit 1
        fi
    fi

    # Correct Docker image
    ZURG_IMAGE="ghcr.io/debridmediamanager/zurg-testing:latest"

    # Navigate to the zurg directory
    cd zurg
    mkdir -p data

    # Remove existing docker-compose.yml if it exists to avoid conflicts
    if [ -f "docker-compose.yml" ]; then
        echo -e "${YELLOW}Removing existing docker-compose.yml...${NC}"
        rm docker-compose.yml
    fi

    # Create the docker-compose.yml file (only Zurg) with direct API key substitution
    echo "services:" > docker-compose.yml
    echo "  zurg:" >> docker-compose.yml
    echo "    image: ${ZURG_IMAGE}" >> docker-compose.yml
    echo "    container_name: zurg" >> docker-compose.yml
    echo "    restart: unless-stopped" >> docker-compose.yml
    echo "    environment:" >> docker-compose.yml
    echo "      - PUID=${PUID}" >> docker-compose.yml
    echo "      - PGID=${PGID}" >> docker-compose.yml
    echo "      - TZ=${TZ}" >> docker-compose.yml
    echo "      - RD_API_KEY=${REAL_DEBRID_API_KEY}" >> docker-compose.yml
    echo "    volumes:" >> docker-compose.yml
    echo "      - ./plex_update.sh:/app/plex_update.sh" >> docker-compose.yml
    echo "      - ./config.yml:/app/config.yml" >> docker-compose.yml
    echo "      - ./data:/app/data" >> docker-compose.yml
    echo "    networks:" >> docker-compose.yml
    echo "      - zurg_network" >> docker-compose.yml
    echo "" >> docker-compose.yml
    echo "networks:" >> docker-compose.yml
    echo "  zurg_network:" >> docker-compose.yml
    echo "    driver: bridge" >> docker-compose.yml

    if [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}Error: Failed to create docker-compose.yml.${NC}"
        exit 1
    fi
    echo -e "${GREEN}docker-compose.yml created successfully for Zurg.${NC}"

    # Update config.yml with the Real-Debrid API key
    CONFIG_FILE="./config.yml"
    if [ -f "$CONFIG_FILE" ]; then
        sed -i "s|token: yourtoken|token: ${REAL_DEBRID_API_KEY}|g" "$CONFIG_FILE"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to update $CONFIG_FILE with API key.${NC}"
            exit 1
        fi
        echo -e "${GREEN}Updated $CONFIG_FILE with Real-Debrid API key.${NC}"
    else
        echo -e "${RED}Error: $CONFIG_FILE does not exist.${NC}"
        exit 1
    fi

    # Bring up the Zurg container
    docker compose up -d
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to start Zurg container.${NC}"
        exit 1
    fi

    echo -e "${GREEN}Zurg container is up and running.${NC}"
    cd ..
fi

# Setup rclone as a bare-metal systemd service
echo -e "${GREEN}Setting up rclone as a systemd service...${NC}"

# Install rclone if not present with retry logic for APT lock
if ! command -v rclone &> /dev/null; then
    echo -e "${YELLOW}Installing rclone...${NC}"
    case "$OS_NAME" in
        ubuntu|debian)
            # Wait for APT lock to free up and ensure rclone installs
            retries=5
            delay=10
            for ((i=1; i<=retries; i++)); do
                apt-get update && apt-get install -y rclone fuse
                if command -v rclone &> /dev/null; then
                    break
                fi
                if [ $i -eq $retries ]; then
                    echo -e "${RED}Error: Failed to install rclone after $retries attempts. Please install manually with 'sudo apt install rclone fuse'.${NC}"
                    exit 1
                fi
                echo -e "${YELLOW}Failed to install rclone (APT lock or install issue). Retrying in $delay seconds (attempt $i/$retries)...${NC}"
                sleep $delay
            done
            # Ensure rclone is executable
            chmod +x /usr/bin/rclone 2>/dev/null || echo -e "${YELLOW}rclone not at /usr/bin/rclone, checking elsewhere...${NC}"
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm rclone fuse
            ;;
        centos|fedora|rhel)
            yum install -y rclone fuse
            ;;
        *)
            echo -e "${RED}Unsupported OS for automatic rclone install. Please install rclone and fuse manually.${NC}"
            exit 1
            ;;
    esac
fi

# Verify rclone is installed and get its path
RCLONE_PATH=$(which rclone)
if [ -z "$RCLONE_PATH" ]; then
    echo -e "${RED}Error: rclone installation failed or rclone not found in PATH. Please install manually with 'sudo apt install rclone fuse'.${NC}"
    exit 1
fi
echo -e "${GREEN}rclone found at: $RCLONE_PATH${NC}"

# Ensure rclone is executable
chmod +x "$RCLONE_PATH" 2>/dev/null

# Ensure /etc/fuse.conf allows user_allow_other
if [ -f "/etc/fuse.conf" ]; then
    if grep -q "^#user_allow_other" /etc/fuse.conf; then
        echo -e "${YELLOW}Uncommenting user_allow_other in /etc/fuse.conf...${NC}"
        sed -i 's|^#user_allow_other|user_allow_other|' /etc/fuse.conf
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to update /etc/fuse.conf.${NC}"
            exit 1
        fi
    elif ! grep -q "^user_allow_other" /etc/fuse.conf; then
        echo -e "${YELLOW}Adding user_allow_other to /etc/fuse.conf...${NC}"
        echo "user_allow_other" >> /etc/fuse.conf
        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to update /etc/fuse.conf.${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}/etc/fuse.conf updated to allow user_allow_other.${NC}"
else
    echo -e "${RED}Error: /etc/fuse.conf does not exist. Please ensure FUSE is installed.${NC}"
    exit 1
fi

# Ensure /mnt/zurg exists and has correct permissions
mkdir -p /mnt/zurg
chown -R "$PUID:$PGID" /mnt/zurg
chmod -R 755 /mnt/zurg

# Get Zurg's container IP address
ZURG_CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' zurg)
if [ -z "$ZURG_CONTAINER_IP" ]; then
    echo -e "${RED}Error: Failed to retrieve Zurg container IP address. Is the Zurg container running?${NC}"
    exit 1
fi
ZURG_WEBDAV_URL="http://${ZURG_CONTAINER_IP}:9999/dav"
echo -e "${GREEN}Using Zurg WebDAV URL: $ZURG_WEBDAV_URL${NC}"

# Create rclone config with dynamic container IP
RCLONE_CONF_DIR="/home/$SUDO_USER/.config/rclone"
RCLONE_CONF="$RCLONE_CONF_DIR/rclone.conf"
mkdir -p "$RCLONE_CONF_DIR"
cat > "$RCLONE_CONF" << EOF
[zurg]
type = webdav
url = $ZURG_WEBDAV_URL
vendor = other
pacer_min_sleep = 0
EOF
chown "$PUID:$PGID" "$RCLONE_CONF_DIR" -R
chmod 600 "$RCLONE_CONF"

# Create systemd service file with dynamic rclone path and Restart=always
cat > /etc/systemd/system/rclone-mount.service << EOF
[Unit]
Description=rclone mount for zurg remote
After=network-online.target docker.service
Wants=network-online.target docker.service
ExecStartPre=/bin/sleep 10

[Service]
Type=simple
ExecStart=$RCLONE_PATH mount zurg: /mnt/zurg --allow-other --allow-non-empty --dir-cache-time 10s --vfs-cache-mode full
ExecStop=/bin/fusermount -u /mnt/zurg
Restart=always
User=$SUDO_USER
Group=$(id -gn "$SUDO_USER")

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable, and start the service
systemctl daemon-reload
systemctl enable rclone-mount.service
systemctl start rclone-mount.service

# Verify the service is running
if systemctl is-active --quiet rclone-mount.service; then
    echo -e "${GREEN}rclone systemd service is active and running.${NC}"
else
    echo -e "${RED}Error: rclone systemd service failed to start. Check 'systemctl status rclone-mount.service'.${NC}"
    exit 1
fi

# Verify the mount
if ls /mnt/zurg &> /dev/null; then
    echo -e "${GREEN}rclone mount at /mnt/zurg is successful.${NC}"
else
    echo -e "${RED}Error: Failed to mount /mnt/zurg. Check rclone configuration and Zurg container status.${NC}"
    exit 1
fi

echo -e "${GREEN}Zurg and rclone setup complete!${NC}"
