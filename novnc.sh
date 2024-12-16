#!/bin/bash

# Check for root or sudo rights
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root or with sudo privileges."
  exit 1
fi

# Prompt user for required variables
echo "Enter the VNC password (at least 6 characters):"
read -s VNC_PASSWORD
echo "Enter the noVNC port (default 6080):"
read NOVNC_PORT
NOVNC_PORT=${NOVNC_PORT:-6080}

echo "Enter the VNC display number (default :1):"
read VNC_DISPLAY
VNC_DISPLAY=${VNC_DISPLAY:-:1}
VNC_PORT=$((5900 + ${VNC_DISPLAY#:}))

# Get public IP address
PUBLIC_IP=$(curl -s https://ifconfig.me)

# Update system packages
echo "Updating system packages..."
apt update && apt upgrade -y

# Install necessary tools and VNC server
echo "Installing TigerVNC server and necessary tools..."
apt install -y tigervnc-standalone-server tigervnc-common git xfce4 xfce4-goodies

# Set up VNC password
echo "Setting up VNC password..."
mkdir -p ~/.vnc
echo "$VNC_PASSWORD" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Create VNC startup script
echo "Creating VNC startup script..."
cat << EOF > ~/.vnc/xstartup
#!/bin/bash
xrdb $HOME/.Xresources
startxfce4 &
EOF
chmod +x ~/.vnc/xstartup

# Start and stop VNC to initialize configuration
echo "Initializing VNC server..."
vncserver $VNC_DISPLAY
vncserver -kill $VNC_DISPLAY

# Install noVNC
echo "Installing noVNC..."
cd ~
git clone https://github.com/novnc/noVNC.git
cd noVNC
git clone https://github.com/novnc/websockify.git

# Create a systemd service for noVNC
echo "Creating noVNC systemd service..."
bash -c "cat << EOF > /etc/systemd/system/novnc.service
[Unit]
Description=noVNC Server
After=network.target

[Service]
Type=simple
ExecStart=/root/noVNC/utils/novnc_proxy --vnc localhost:$VNC_PORT --listen $NOVNC_PORT
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF"

# Reload systemd and enable the service
echo "Enabling noVNC service..."
systemctl daemon-reload
systemctl enable novnc
systemctl start novnc

# Configure firewall (AWS Security Groups must also allow the specified ports)
echo "Configuring firewall rules..."
ufw allow $NOVNC_PORT
ufw allow $VNC_PORT
ufw enable


echo ""
echo "To allow external access to the necessary ports (noVNC and VNC) in AWS CloudShell or using AWS CLI, you can use the following commands (only if using the default security group):"
echo ""
echo "vpc_id=\$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
echo "security_group_id=\$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=\$vpc_id --query 'SecurityGroups[?GroupName==\`default\`].GroupId' --output text)"
echo ""
echo "aws ec2 authorize-security-group-ingress --group-id \$security_group_id --protocol tcp --port $NOVNC_PORT --cidr 0.0.0.0/0"
echo "aws ec2 authorize-security-group-ingress --group-id \$security_group_id --protocol tcp --port $VNC_PORT --cidr 0.0.0.0/0"

echo "Installation complete!"
echo "Access your Kali Linux desktop through noVNC by visiting:"
echo "http://$PUBLIC_IP:$NOVNC_PORT/vnc.html"