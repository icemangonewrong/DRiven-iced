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
    # Get Real-Debrid API Key using the common function
    REAL_DEBRID_API_KEY=$(get_real_debrid_api_key)
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to get Real-Debrid API Key.${NC}"
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

    # Create the docker-compose.yml file (only Zurg)
    cat > docker-compose.yml << 'EOF'
services:
  zurg:
    image: ${ZURG_IMAGE}
    container_name: zurg
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - RD_API_KEY=${REAL_DEBRID_API_KEY}
    volumes:
      - ./plex_update.sh:/app/plex_update.sh
      - ./config.yml:/app/config.yml
      - ./data:/app/data
    networks:
      - zurg_network

networks:
  zurg_network:
    driver: bridge
EOF

    # Replace variables in the docker-compose.yml file
    sed -i "s|\${ZURG_IMAGE}|$ZURG_IMAGE|g" docker-compose.yml
    sed -i "s|\${PUID}|$PUID|g" docker-compose.yml
    sed -i "s|\${PGID}|$PGID|g" docker-compose.yml
    sed -i "s|\${TZ}|$TZ|g" docker-compose.yml
    sed -i "s|\${REAL_DEBRID_API_KEY}|$REAL_DEBRID_API_KEY|g" docker-compose.yml

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to create docker-compose.yml.${NC}"
        exit 1
    fi

    echo -e "${GREEN}docker-compose.yml created successfully for Zurg.${NC}"

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

# Install rclone if not present
if ! command -v rclone &> /dev/null; then
    echo -e "${YELLOW}Installing rclone...${NC}"
    case "$OS_NAME" in
        ubuntu|debian)
            apt-get update && apt-get install -y rclone fuse
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

# Ensure /mnt/zurg exists and has correct permissions
mkdir -p /mnt/zurg
chown -R "$PUID:$PGID" /mnt/zurg
chmod -R 755 /mnt/zurg

# Get the local IP address for Zurg's WebDAV URL
LOCAL_IP=$(retrieve_saved_ip)
if [ -z "$LOCAL_IP" ]; then
    echo -e "${YELLOW}Local IP not found in local_ip.txt. Retrieving from Zurg container...${NC}"
    LOCAL_IP=$(get_zurg_container_ip)  # Updated to get the container's IP directly
    if [ -z "$LOCAL_IP" ]; then
        echo -e "${RED}Error: Failed to retrieve Zurg container IP address.${NC}"
        exit 1
    fi
fi
ZURG_WEBDAV_URL="http://$LOCAL_IP:9999/dav"
echo -e "${GREEN}Using Zurg WebDAV URL: $ZURG_WEBDAV_URL${NC}"

# Create rclone config with dynamic IP
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

# Create systemd service file
cat > /etc/systemd/system/rclone-mount.service << EOF
[Unit]
Description=rclone mount for zurg remote
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
ExecStart=/usr/bin/rclone mount zurg: /mnt/zurg --allow-other --allow-non-empty --dir-cache-time 10s --vfs-cache-mode full
ExecStop=/bin/fusermount -u /mnt/zurg
Restart=on-failure
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
