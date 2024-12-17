#!/bin/bash

# Kali Linux noVNC + TigerVNC + XFCE4 installation script
# optional Nginx reverse proxy and Let's Encrypt setup
# https://github.com/vtstv/novnc-install
# novnc_setup.sh v0.8 by Murr

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
  echo ""  # Newline for cleaner output

  # Check if noVNC is already installed and get the port
  if systemctl is-active --quiet novnc; then
    echo "noVNC is already installed."
    NOVNC_PORT=$(systemctl show -p ExecStart --value novnc | awk -F'--listen ' '{print $2}' | awk '{print $1}')
    echo "Using existing noVNC port: $NOVNC_PORT"
  else
    echo "Enter the noVNC port (default 6080):"
    read NOVNC_PORT
    NOVNC_PORT=${NOVNC_PORT:-6080}
  fi

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

  # Start and stop VNC to initialize configuration, then enable it to start on boot
  echo "Initializing and enabling VNC server..."
  su - "$VNC_USER" -c "vncserver $VNC_DISPLAY"
  su - "$VNC_USER" -c "vncserver -kill $VNC_DISPLAY"
  
  # Create a systemd service for TigerVNC
  echo "Creating TigerVNC systemd service..."
  cat << EOF > /etc/systemd/system/tigervncserver@.service
[Unit]
Description=TigerVNC Server
After=syslog.target network.target

[Service]
Type=forking
User=$VNC_USER
Group=$VNC_USER
WorkingDirectory=/home/$VNC_USER

PIDFile=/home/$VNC_USER/.vnc/%H%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :%i > /dev/null 2>&1
ExecStart=/usr/bin/vncserver -depth 24 -geometry 1280x800 :%i
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

  # Reload systemd, enable and start the tigervnc service
  echo "Enabling and starting TigerVNC service..."
  systemctl daemon-reload
  systemctl enable tigervncserver@$VNC_DISPLAY
  systemctl start tigervncserver@$VNC_DISPLAY

  # Install noVNC (only if not already installed)
  if ! systemctl is-active --quiet novnc; then
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

    # Create symbolic link from vnc.html to index.html
    echo "Creating symbolic link from vnc.html to index.html..."
    ln -s /home/$VNC_USER/noVNC/vnc.html /home/$VNC_USER/noVNC/index.html

  fi

  # Configure firewall
  echo "Configuring firewall rules..."
  ufw allow $NOVNC_PORT
  ufw allow $VNC_PORT
  ufw enable
  echo "-----------------------------------------------------------------------------------------"
  echo ""
  echo "To allow external access to the necessary ports (noVNC and VNC) in AWS CloudShell or using AWS CLI,"
  echo "you can use the following commands (only if using the default security group):"
  echo ""
  echo "vpc_id=\$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  echo "security_group_id=\$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=\$vpc_id --query 'SecurityGroups[?GroupName==\`default\`].GroupId' --output text)"
  echo ""
  echo "aws ec2 authorize-security-group-ingress --group-id \$security_group_id --protocol tcp --port $NOVNC_PORT --cidr 0.0.0.0/0"
  echo "aws ec2 authorize-security-group-ingress --group-id \$security_group_id --protocol tcp --port $VNC_PORT --cidr 0.0.0.0/0"
  echo "-----------------------------------------------------------------------------------------"
  echo "Type sudo apt install kali-linux-large to install classic Kali tools"
  echo "-----------------------------------------------------------------------------------------"
  echo "Installation complete!"
  echo "Access your Kali Linux desktop through noVNC by visiting:"
  echo "http://$PUBLIC_IP:$NOVNC_PORT/vnc.html"
}

function configure_nginx_reverse_proxy() {
  if [ -z "$NOVNC_PORT" ]; then
    if systemctl is-active --quiet novnc; then
      NOVNC_PORT=$(systemctl show -p ExecStart --value novnc | awk -F'--listen ' '{print $2}' | awk '{print $1}')
      echo "Using existing noVNC port: $NOVNC_PORT"
    else
      echo "Error: noVNC port is not defined. Please install noVNC first or set NOVNC_PORT manually."
      return 1
    fi
  fi

  echo "Installing Nginx..."
  apt install -y nginx

  echo "Enter the hostname for the reverse proxy (e.g., vnc.example.com):"
  read HOSTNAME

  echo "Do you want to enable HTTP Basic Authentication? (y/n):"
  read ENABLE_BASIC_AUTH
  ENABLE_BASIC_AUTH=${ENABLE_BASIC_AUTH:-n}

  AUTH_CONFIG=""
  if [[ "$ENABLE_BASIC_AUTH" == "y" ]]; then
    echo "Enter the username for Basic Authentication:"
    read AUTH_USER
    echo "Enter the password for Basic Authentication:"
    read -s AUTH_PASSWORD
    echo ""  # Newline for cleaner output

    echo "Installing apache2-utils for htpasswd..."
    apt install -y apache2-utils

    htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASSWORD"
    # Ensure correct permissions for the .htpasswd file
    chmod 640 /etc/nginx/.htpasswd
    chown root:www-data /etc/nginx/.htpasswd

    AUTH_CONFIG="
        auth_basic \"Restricted\";
        auth_basic_user_file /etc/nginx/.htpasswd;"
  fi

  # Temporarily disable the potentially problematic site config
  if [ -L /etc/nginx/sites-enabled/novnc ]; then
    echo "Temporarily disabling existing novnc site..."
    mv /etc/nginx/sites-enabled/novnc /etc/nginx/sites-enabled/novnc.bak
  fi

  # Certificate setup with standalone plugin
  if ! certbot certificates | grep -q "$HOSTNAME"; then
    echo "Installing Certbot for Let's Encrypt..."
    apt install -y certbot python3-certbot-nginx

    # Check for /etc/letsencrypt/live directory and create if missing
    if [ ! -d "/etc/letsencrypt/live" ]; then
      echo "Creating /etc/letsencrypt/live directory..."
      mkdir -p /etc/letsencrypt/live
      if [ $? -ne 0 ]; then
        echo "Error: Could not create /etc/letsencrypt/live directory. Please check permissions."
        return 1
      fi
    fi

    # Check for /etc/letsencrypt/live/$HOSTNAME directory and create if missing
    if [ ! -d "/etc/letsencrypt/live/$HOSTNAME" ]; then
      echo "Creating /etc/letsencrypt/live/$HOSTNAME directory..."
      mkdir -p /etc/letsencrypt/live/$HOSTNAME
      if [ $? -ne 0 ]; then
        echo "Error: Could not create /etc/letsencrypt/live/$HOSTNAME directory. Please check permissions."
        return 1
      fi
    fi

    echo "Obtaining SSL certificate (using standalone plugin)..."
    systemctl stop nginx # Stop nginx to free up port 80 for standalone
    if ! certbot certonly --standalone -d $HOSTNAME --non-interactive --agree-tos -m admin@$HOSTNAME --cert-name $HOSTNAME; then
      echo "Error: Initial attempt to obtain SSL certificate failed."
      echo "Do you want to automatically retry certificate generation? (y/n)"
      read RETRY_CERT
      RETRY_CERT=${RETRY_CERT:-n}

      if [[ "$RETRY_CERT" == "y" ]]; then
        echo "Retrying certificate generation..."
        if ! certbot certonly --standalone -d $HOSTNAME --non-interactive --agree-tos -m admin@$HOSTNAME --cert-name $HOSTNAME; then
          echo "Error: Retry attempt failed. Please check the error messages above and try again manually."
          return 1
        else
          echo "SSL certificate successfully obtained on retry."
        fi
      else
        echo "Skipping certificate retry. Please fix the issue and try again manually."
        return 1
      fi
    fi
    systemctl start nginx # Restart Nginx after obtaining the certificate
  else
    echo "SSL certificate for $HOSTNAME already exists. Skipping Certbot installation."
  fi

  # Create Nginx configuration file
  echo "Configuring Nginx..."
  cat << EOF > /etc/nginx/sites-available/novnc
server {
    listen 80;
    server_name $HOSTNAME;

    # Redirect HTTP to HTTPS
    return 301 https://$HOSTNAME\$request_uri;
}

server {
    listen 443 ssl;
    server_name $HOSTNAME;

    ssl_certificate /etc/letsencrypt/live/$HOSTNAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$HOSTNAME/privkey.pem;

    location / {
        $AUTH_CONFIG
        proxy_pass http://localhost:$NOVNC_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  # Enable the site
  if [ -L /etc/nginx/sites-enabled/novnc.bak ]; then
    echo "Replacing old novnc site configuration..."
    rm /etc/nginx/sites-enabled/novnc.bak
  fi
  if ! [ -L /etc/nginx/sites-enabled/novnc ]; then
    ln -s /etc/nginx/sites-available/novnc /etc/nginx/sites-enabled/
  fi

  # Ensure Nginx has correct permissions and ownership
  chown -R www-data:www-data /var/lib/nginx
  find /etc/nginx -type d -exec chmod 750 {} \;
  find /etc/nginx -type f -exec chmod 640 {} \;

  # Test configuration and reload Nginx
  if nginx -t; then
    systemctl reload nginx
    echo "Nginx configuration reloaded successfully."
  else
    echo "Error in Nginx configuration. Check with 'nginx -t' for details."
    return 1
  fi

  # Enable Nginx to start on boot
  systemctl enable nginx

  echo "Setting up auto-renewal..."
  if ! grep -q "certbot renew" /etc/crontab; then
    echo "0 3 * * * certbot renew --quiet" >> /etc/crontab
  else
    echo "Certbot auto-renewal already configured. Skipping crontab setup."
  fi

  echo "Reverse proxy configuration complete!"
  echo "Access your Kali Linux desktop securely at: https://$HOSTNAME"
}

function fix_nginx_config() {
  echo "Attempting to fix common Nginx configuration issues..."

  # Check if novnc site is enabled
  if [ ! -L /etc/nginx/sites-enabled/novnc ]; then
    echo "Enabling novnc site in Nginx..."
    ln -s /etc/nginx/sites-available/novnc /etc/nginx/sites-enabled/
  else
    echo "novnc site is already enabled."
  fi

  # Check if the default site is disabled
  if [ -f /etc/nginx/sites-enabled/default ]; then
    echo "Disabling default Nginx site..."
    rm /etc/nginx/sites-enabled/default
  fi

  # Check if HTTP to HTTPS redirect is in place
  if ! grep -q "return 301 https" /etc/nginx/sites-available/novnc; then
    echo "Adding HTTP to HTTPS redirect to novnc configuration..."
    sed -i '/listen 80;/a \    return 301 https://$HOSTNAME$request_uri;' /etc/nginx/sites-available/novnc
  fi

  # Check for SSL certificate paths
  if ! grep -q "ssl_certificate " /etc/nginx/sites-available/novnc; then
    echo "SSL certificate paths are missing in novnc configuration. Please ensure they are correctly set."
  fi

  # Test Nginx configuration
  echo "Testing Nginx configuration..."
  if nginx -t; then
    echo "Nginx configuration test successful. Reloading Nginx..."
    systemctl reload nginx
  else
    echo "Nginx configuration test failed. Please check the configuration manually."
  fi

  echo "Fix attempt completed. Please verify the configuration."
}

function reinstall_nginx_reverse_proxy() {
  echo "Reinstalling Nginx reverse proxy setup..."

  # Stop Nginx and disable novnc site
  echo "Stopping Nginx and disabling novnc site..."
  systemctl stop nginx
  if [ -L /etc/nginx/sites-enabled/novnc ]; then
    rm /etc/nginx/sites-enabled/novnc
  fi

  # Remove existing Nginx configuration and Certbot certificates
  echo "Removing existing Nginx configuration and Certbot certificates..."
  rm -f /etc/nginx/sites-available/novnc
  certbot delete --cert-name "$HOSTNAME" --non-interactive

  # Reconfigure Nginx reverse proxy (calls the configure_nginx_reverse_proxy function)
  echo "Reconfiguring Nginx reverse proxy..."
  configure_nginx_reverse_proxy
}

function main_menu() {
  while true; do
    echo "Choose an option:"
    echo "1) Install noVNC with TigerVNC and XFCE4"
    echo "2) Configure Nginx reverse proxy with Let's Encrypt"
    echo "3) Fix Nginx Configuration"
    echo "4) Reinstall Nginx Reverse Proxy Setup"
    echo "5) Exit"
    read -p "Enter your choice: " choice

    case $choice in
    1)
      install_vnc_novnc
      ;;
    2)
      configure_nginx_reverse_proxy
      ;;
    3)
      fix_nginx_config
      ;;
    4)
      reinstall_nginx_reverse_proxy
      ;;
    5)
      exit 0
      ;;
    *)
      echo "Invalid choice, please try again."
      ;;
    esac
  done
}

main_menu