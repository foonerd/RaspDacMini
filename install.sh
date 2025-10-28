#!/bin/sh

# RaspDacMini LCD Plugin Installation Script
# For Volumio 4.x (Debian Bookworm)
# POSIX sh compatible

echo "Installing RaspDacMini LCD plugin..."

# Plugin directory - Volumio executes from plugin directory
PLUGIN_DIR="/data/plugins/system_hardware/raspdac_mini_lcd"
COMPOSITOR_DIR="$PLUGIN_DIR/compositor"
NATIVE_DIR="$PLUGIN_DIR/native/rgb565"

# Architecture check - Raspberry Pi only
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" != "armhf" ] && [ "$ARCH" != "arm64" ]; then
    echo "Error: This plugin requires ARM architecture (Raspberry Pi)"
    echo "Detected architecture: $ARCH"
    echo "Supported architectures: armhf, arm64"
    echo "plugininstallend"
    exit 1
fi

echo "Architecture check passed: $ARCH"

# Create installation lock file
INSTALLING="/home/volumio/raspdac_mini_lcd.installing"
if [ -f "$INSTALLING" ]; then
    echo "Error: Installation already in progress"
    echo "If you're sure no installation is running, remove $INSTALLING and try again"
    echo "plugininstallend"
    exit 1
fi
touch "$INSTALLING"

# Function to cleanup on error
cleanup_on_error() {
    echo "Installation failed. Cleaning up..."
    rm -f "$INSTALLING"
    echo "plugininstallend"
    exit 1
}

echo "Installing system dependencies..."
# Update package list
apt-get update
if [ $? -ne 0 ]; then
    echo "Error: Failed to update package list"
    cleanup_on_error
fi

# Install required system packages
apt-get install -y build-essential libcairo2-dev libpango1.0-dev libjpeg-dev libgif-dev librsvg2-dev fbset jq
if [ $? -ne 0 ]; then
    echo "Error: Failed to install system dependencies"
    cleanup_on_error
fi

echo "System dependencies installed successfully"

# Detect architecture and Node version for prebuilt check
ARCH=$(uname -m)
NODE_MAJOR=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
PREBUILT_FILE="$PLUGIN_DIR/assets/compositor-${ARCH}-node${NODE_MAJOR}.tar.gz"

# Check if prebuilt compositor exists
if [ -f "$PREBUILT_FILE" ]; then
    echo "Found prebuilt compositor for ${ARCH} Node ${NODE_MAJOR}"
    echo "Using prebuilt version (fast installation, no compilation needed)..."
    
    # Extract prebuilt to compositor directory
    cd "$COMPOSITOR_DIR"
    tar -xzf "$PREBUILT_FILE"
    if [ $? -eq 0 ]; then
        echo "Prebuilt compositor installed successfully"
        USING_PREBUILT=1
    else
        echo "Warning: Failed to extract prebuilt, will compile from source"
    fi
fi

# If no prebuilt or extraction failed, compile from source
if [ -z "$USING_PREBUILT" ]; then
    echo "No prebuilt available for ${ARCH} Node ${NODE_MAJOR}"
    echo "Installing build dependencies for compilation..."
    apt-get install -y build-essential
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install build dependencies"
        cleanup_on_error
    fi
    
    echo "Compiling compositor from source (this may take 15+ minutes on slower systems)..."
    cd "$COMPOSITOR_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to change to compositor directory"
        cleanup_on_error
    fi
    
    # Install compositor dependencies (this will also compile native module via preinstall)
    npm install --omit=dev
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install compositor packages or compile native module"
        cd "$PLUGIN_DIR"
        cleanup_on_error
    fi
    
    echo "Compositor packages installed successfully"
    
    # Verify native module was compiled
    if [ ! -f "$COMPOSITOR_DIR/utils/rgb565.node" ]; then
        echo "Warning: Native module not found at expected location"
        echo "Attempting manual compilation..."
        cd "$NATIVE_DIR"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to change to native module directory"
            cd "$PLUGIN_DIR"
            cleanup_on_error
        fi
        
        npm run install_rdmlcd
        if [ $? -ne 0 ]; then
            echo "Error: Native module compilation failed"
            cd "$PLUGIN_DIR"
            cleanup_on_error
        fi
    fi
    
    echo "Native module compiled successfully"
fi

cd "$PLUGIN_DIR"

echo "Installing device tree overlay..."

# Check if dtoverlay file exists in assets
if [ ! -f "$PLUGIN_DIR/assets/raspdac-mini-lcd.dtbo" ]; then
    echo "Error: Device tree overlay not found in assets/"
    echo "Please add raspdac-mini-lcd.dtbo to the assets/ folder"
    cleanup_on_error
fi

# Copy dtoverlay to /boot/overlays/
cp "$PLUGIN_DIR/assets/raspdac-mini-lcd.dtbo" /boot/overlays/
if [ $? -ne 0 ]; then
    echo "Error: Failed to copy device tree overlay"
    cleanup_on_error
fi

echo "Device tree overlay installed successfully"

echo "Configuring boot parameters..."

# Add dtoverlay to /boot/userconfig.txt if not already present
if ! grep -q "dtoverlay=raspdac-mini-lcd" /boot/userconfig.txt 2>/dev/null; then
    echo "" >> /boot/userconfig.txt
    echo "# RaspDacMini LCD Display" >> /boot/userconfig.txt
    echo "dtoverlay=raspdac-mini-lcd" >> /boot/userconfig.txt
    echo "Boot configuration updated"
else
    echo "Boot configuration already contains dtoverlay"
fi

# Optional: Add GPIO IR overlay if remote control desired (commented by default)
# if ! grep -q "dtoverlay=gpio-ir" /boot/userconfig.txt 2>/dev/null; then
#     echo "dtoverlay=gpio-ir,gpio_pin=4" >> /boot/userconfig.txt
# fi

echo "Creating systemd service file..."

# Create service file
cat > /etc/systemd/system/rdmlcd.service << 'EOF'
[Unit]
Description=RaspDacMini LCD Display Service
After=volumio.service
Requires=volumio.service

[Service]
Type=simple
User=root
WorkingDirectory=/data/plugins/system_hardware/raspdac_mini_lcd/compositor
Environment="SLEEP_AFTER=900"
ExecStart=/usr/bin/node index.js volumio /dev/fb1
StandardOutput=journal
StandardError=journal
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
StartLimitInterval=200
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

if [ $? -ne 0 ]; then
    echo "Error: Failed to create service file"
    cleanup_on_error
fi

echo "Service file created successfully"

echo "Creating service environment override..."

# Create override directory
mkdir -p /etc/systemd/system/rdmlcd.service.d

# Read sleep_after from config.json
SLEEP_AFTER=900
if [ -f "$PLUGIN_DIR/config.json" ]; then
    SLEEP_AFTER=$(jq -r '.sleep_after.value' "$PLUGIN_DIR/config.json" 2>/dev/null)
    if [ -z "$SLEEP_AFTER" ] || [ "$SLEEP_AFTER" = "null" ]; then
        SLEEP_AFTER=900
    fi
fi

# Create override file with current config
cat > /etc/systemd/system/rdmlcd.service.d/override.conf << EOF
[Service]
Environment="SLEEP_AFTER=$SLEEP_AFTER"
EOF

echo "Service environment configured: SLEEP_AFTER=$SLEEP_AFTER"

echo "Enabling and starting service..."

# Reload systemd to pick up new service
systemctl daemon-reload
if [ $? -ne 0 ]; then
    echo "Error: Failed to reload systemd"
    cleanup_on_error
fi

# Enable service to start on boot
systemctl enable rdmlcd.service
if [ $? -ne 0 ]; then
    echo "Error: Failed to enable service"
    cleanup_on_error
fi

# Check if LCD is enabled in config
LCD_ACTIVE=$(jq -r '.lcd_active.value' "$PLUGIN_DIR/config.json" 2>/dev/null)
if [ -z "$LCD_ACTIVE" ] || [ "$LCD_ACTIVE" = "null" ]; then
    LCD_ACTIVE="true"
fi

if [ "$LCD_ACTIVE" = "true" ]; then
    echo "Starting LCD service..."
    systemctl start rdmlcd.service
    
    if [ $? -ne 0 ]; then
        echo "Warning: Failed to start service (may require reboot for dtoverlay)"
    else
        echo "Service started successfully"
    fi
else
    echo "LCD is disabled in configuration, service not started"
fi

# Remove lock file
rm -f "$INSTALLING"

# Fix ownership of all plugin files (install runs as root)
echo "Setting correct file ownership..."
chown -R volumio:volumio "$PLUGIN_DIR"
if [ $? -ne 0 ]; then
    echo "Warning: Failed to set ownership, but plugin should still work"
fi

echo ""
echo "=========================================="
echo "RaspDacMini LCD Plugin Installation Complete"
echo "=========================================="
echo ""
echo "IMPORTANT: A reboot is required for the device tree overlay to load."
echo "After reboot, the LCD display should be active at /dev/fb1"
echo ""
echo "To verify after reboot:"
echo "  - Check framebuffer: ls -la /dev/fb1"
echo "  - Check service: systemctl status rdmlcd.service"
echo "  - View logs: journalctl -u rdmlcd.service -f"
echo ""

echo "plugininstallend"


