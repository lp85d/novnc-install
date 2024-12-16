#!/bin/bash

# Kali Linux noVNC + TigerVNC + XFCE4 installation script
# optional Nginx reverse proxy and Let's Encrypt setup
# https://github.com/vtstv/Install_Novnc_Kali
# Install_Novnc_Kali v0.2 by Murr

# Check for root or sudo rights
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root or with sudo privileges."
  exit 1
fi

function install_vnc_novnc() {
  # Prompt user for required variables
  echo "Enter the username for VNC (default: kali):"
  read VNC_USER
  VNC_USER=${VNC_USER:-kali}

  if ! id -u "$VNC_USER" &>/dev/null; then
    echo "User $VNC_USER does not exist. Creating..."
    useradd -m -s /bin/bash "$VNC_USER"
    echo "Set a password for $VNC_USER:"
    passwd "$VNC_USER"
  fi

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
  PUBLIC_IP=$(curl -s4 https://ifconfig.me)

  # Update system packages
  echo "Updating system packages..."
  apt update && apt upgrade -y

  # Install necessary tools and VNC server
  echo "Installing TigerVNC server and necessary tools..."
  apt install -y tigervnc-standalone-server tigervnc-common git xfce4 xfce4-goodies dbus-x11 xfce4-terminal

  # Set up VNC password
  echo "Setting up VNC password..."
  su - "$VNC_USER" -c "mkdir -p ~/.vnc"
  echo "$VNC_PASSWORD" | su - "$VNC_USER" -c "vncpasswd -f > ~/.vnc/passwd"
  su - "$VNC_USER" -c "chmod 600 ~/.vnc/passwd"

  # Create VNC startup script
  echo "Creating VNC startup script..."
  su - "$VNC_USER" -c "cat << EOF > ~/.vnc/xstartup
#!/bin/bash
xrdb $HOME/.Xresources
export XKL_XMODMAP_DISABLE=1
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
dbus-launch --exit-with-session startxfce4 &
EOF"
  su - "$VNC_USER" -c "chmod +x ~/.vnc/xstartup"

  # Start and stop VNC to initialize configuration
  echo "Initializing VNC server..."
  su - "$VNC_USER" -c "vncserver $VNC_DISPLAY"
  su - "$VNC_USER" -c "vncserver -kill $VNC_DISPLAY"
  su - "$VNC_USER" -c "vncserver $VNC_DISPLAY"

  # Install noVNC
  echo "Installing noVNC..."
  su - "$VNC_USER" -c "cd ~ && git clone https://github.com/novnc/noVNC.git"
  su - "$VNC_USER" -c "cd ~/noVNC && git clone https://github.com/novnc/websockify.git"

  # Create a systemd service for noVNC
  echo "Creating noVNC systemd service..."
  cat << EOF > /etc/systemd/system/novnc.service
[Unit]
Description=noVNC Server
After=network.target

[Service]
Type=simple
ExecStart=/home/$VNC_USER/noVNC/utils/novnc_proxy --vnc localhost:$VNC_PORT --listen $NOVNC_PORT
Restart=always
User=$VNC_USER

[Install]
WantedBy=multi-user.target
EOF

  # Reload systemd and enable the service
  echo "Enabling noVNC service..."
  systemctl daemon-reload
  systemctl enable novnc
  systemctl start novnc

  # Configure firewall
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

echo "Type sudo apt install kali-linux-large to install clasic Kali tools"

echo "Installation complete!"
echo "Access your Kali Linux desktop through noVNC by visiting:"
echo "http://$PUBLIC_IP:$NOVNC_PORT/vnc.html"
}

function configure_nginx_reverse_proxy() {
  echo "Installing Nginx..."
  apt install -y nginx

  echo "Enter the hostname for the reverse proxy (e.g., vnc.example.com):"
  read HOSTNAME

  echo "Configuring Nginx..."
  cat << EOF > /etc/nginx/sites-available/novnc
server {
    listen 80;
    server_name $HOSTNAME;

    location / {
        proxy_pass http://localhost:$NOVNC_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

  ln -s /etc/nginx/sites-available/novnc /etc/nginx/sites-enabled/
  nginx -t && systemctl reload nginx

  echo "Installing Certbot for Let's Encrypt..."
  apt install -y certbot python3-certbot-nginx

  echo "Obtaining SSL certificate..."
  certbot --nginx -d $HOSTNAME --non-interactive --agree-tos -m admin@$HOSTNAME

  echo "Setting up auto-renewal..."
  echo "0 3 * * * certbot renew --quiet" >> /etc/crontab

  echo "Reverse proxy configuration complete!"
  echo "Access your Kali Linux desktop securely at: https://$HOSTNAME"
}

function main_menu() {
  while true; do
    echo "Choose an option:"
    echo "1) Install noVNC with TigerVNC and XFCE4"
    echo "2) Configure Nginx reverse proxy with Let's Encrypt"
    echo "3) Exit"
    read -p "Enter your choice: " choice

    case $choice in
      1)
        install_vnc_novnc
        ;;
      2)
        configure_nginx_reverse_proxy
        ;;
      3)
        exit 0
        ;;
      *)
        echo "Invalid choice, please try again."
        ;;
    esac
  done
}

main_menu
