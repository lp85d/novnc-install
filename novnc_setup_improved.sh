#!/bin/bash

# Установка noVNC + TigerVNC + XFCE4 на Debian/Ubuntu
# Дополнительно: настройка обратного прокси Nginx и SSL Let's Encrypt
# https://github.com/lp85d/novnc-install
# novnc_setup.sh v0.9 by lp85d
# Модифицированная версия с проверкой портов и дополнительными опциями Nginx

# Проверка прав root или sudo
if [ "$EUID" -ne 0 ]; then
  echo "Этот скрипт должен быть запущен от имени root или с правами sudo."
  exit 1
fi

# Глобальные переменные для обмена между функциями
VNC_DISPLAY=""
NOVNC_PORT=""

# Функция для поиска первого свободного VNC дисплея
function find_free_vnc_display() {
    local display_num=1
    while true; do
        if ss -ltn | grep -q ":$((5900 + display_num))" || [ -f "/tmp/.X11-unix/X$display_num" ]; then
            echo "Дисплей :$display_num (порт $((5900 + display_num))) занят."
            ((display_num++))
        else
            echo ":$display_num"
            return
        fi
    done
}

function install_vnc_novnc() {
  # Запрос переменных у пользователя
  echo "Введите имя пользователя для VNC (по умолчанию: vncuser):"
  read VNC_USER
  VNC_USER=${VNC_USER:-vncuser}

  if ! id -u "$VNC_USER" &>/dev/null; then
    echo "Пользователь $VNC_USER не существует. Создаём..."
    useradd -m -s /bin/bash "$VNC_USER"
    echo "Установите пароль для системного пользователя $VNC_USER:"
    passwd "$VNC_USER"
  fi

  echo "Введите пароль VNC (не менее 6 символов, будет использоваться для прямого подключения):"
  read -s VNC_PASSWORD
  echo ""

  # Проверка, установлен ли noVNC, и получение порта
  if systemctl is-active --quiet novnc; then
    echo "noVNC уже установлен."
    NOVNC_PORT=$(systemctl show -p ExecStart --value novnc | awk -F'--listen ' '{print $2}' | awk '{print $1}')
    echo "Используется существующий порт noVNC: $NOVNC_PORT"
  else
    echo "Введите порт для noVNC (по умолчанию 6080):"
    read NOVNC_PORT
    NOVNC_PORT=${NOVNC_PORT:-6080}
  fi
  
  echo "Поиск свободного VNC дисплея..."
  local default_display=$(find_free_vnc_display)
  echo "Рекомендуемый свободный дисплей: $default_display"
  echo "Введите номер дисплея VNC (например, :1, :2):"
  read VNC_DISPLAY
  VNC_DISPLAY=${VNC_DISPLAY:-$default_display}
  
  local display_num_only=${VNC_DISPLAY#:}
  VNC_PORT=$((5900 + display_num_only))

  # Получение публичного IP-адреса
  PUBLIC_IP=$(curl -s4 https://ifconfig.me)

  # Обновление системных пакетов
  echo "Обновление системных пакетов..."
  apt update && apt upgrade -y

  echo "Установка сервера TigerVNC, XFCE4 и необходимых инструментов..."
  apt install -y tigervnc-standalone-server tigervnc-common git xfce4 xfce4-goodies dbus-x11 xfce4-terminal websockify

  # Настройка пароля VNC
  echo "Настройка пароля VNC..."
  su - "$VNC_USER" -c "mkdir -p ~/.vnc"
  echo "$VNC_PASSWORD" | su - "$VNC_USER" -c "vncpasswd -f > ~/.vnc/passwd"
  su - "$VNC_USER" -c "chmod 600 ~/.vnc/passwd"

  # Создание скрипта запуска VNC
  echo "Создание скрипта запуска VNC..."
  su - "$VNC_USER" -c "cat << EOF > ~/.vnc/xstartup
#!/bin/bash
[ -f \"\$HOME/.Xresources\" ] && xrdb \"\$HOME/.Xresources\"
export XKL_XMODMAP_DISABLE=1
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
startxfce4
EOF"
  su - "$VNC_USER" -c "chmod +x ~/.vnc/xstartup"

  # Инициализация и активация VNC-сервера для создания начальных файлов
  echo "Первичный запуск VNC-сервера для инициализации..."
  su - "$VNC_USER" -c "vncserver $VNC_DISPLAY"
  su - "$VNC_USER" -c "vncserver -kill $VNC_DISPLAY"
  sleep 1

  echo "Создание службы systemd для TigerVNC..."
  # Файл службы будет назван с номером дисплея для уникальности
  cat << EOF > /etc/systemd/system/tigervncserver@${display_num_only}.service
[Unit]
Description=Сервер TigerVNC для дисплея ${VNC_DISPLAY}
After=syslog.target network.target

[Service]
Type=forking
User=$VNC_USER
Group=$VNC_USER
WorkingDirectory=/home/$VNC_USER

PIDFile=/home/$VNC_USER/.vnc/%H${VNC_DISPLAY}.pid
ExecStartPre=-/usr/bin/vncserver -kill ${VNC_DISPLAY} > /dev/null 2>&1
ExecStart=/usr/bin/vncserver -depth 24 -geometry 1280x800 ${VNC_DISPLAY} -localhost no
ExecStop=/usr/bin/vncserver -kill ${VNC_DISPLAY}

[Install]
WantedBy=multi-user.target
EOF

  # Перезагрузка systemd, активация и запуск службы tigervnc
  echo "Активация и запуск службы TigerVNC..."
  systemctl daemon-reload
  systemctl enable tigervncserver@${display_num_only}.service
  systemctl start tigervncserver@${display_num_only}.service

  # Установка noVNC (только если не установлен)
  if ! systemctl is-active --quiet novnc; then
    echo "Установка noVNC..."
    # noVNC и websockify лучше ставить централизованно
    git clone https://github.com/novnc/noVNC.git /opt/noVNC
    
    # Создание службы systemd для noVNC
    echo "Создание службы systemd для noVNC..."
    cat << EOF > /etc/systemd/system/novnc.service
[Unit]
Description=Сервер noVNC (Websockify)
After=network.target

[Service]
Type=simple
ExecStart=/opt/noVNC/utils/novnc_proxy --vnc localhost:$VNC_PORT --listen $NOVNC_PORT
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    echo "Активация службы noVNC..."
    systemctl daemon-reload
    systemctl enable novnc
    systemctl start novnc

    echo "Создание символической ссылки с vnc.html на index.html..."
    ln -s /opt/noVNC/vnc.html /opt/noVNC/index.html
  fi

  echo "Настройка правил брандмауэра..."
  ufw allow $NOVNC_PORT/tcp
  ufw allow $VNC_PORT/tcp

  echo "-----------------------------------------------------------------------------------------"
  echo "Установка завершена!"
  echo "Доступ к вашему рабочему столу Linux через noVNC по адресу:"
  echo "http://$PUBLIC_IP:$NOVNC_PORT"
  echo "Или через любой VNC клиент (например, RealVNC Viewer) по адресу:"
  echo "$PUBLIC_IP:$VNC_PORT"
  echo "-----------------------------------------------------------------------------------------"
}

function configure_nginx_reverse_proxy() {
  if systemctl is-active --quiet novnc; then
    NOVNC_PORT=$(systemctl show -p ExecStart --value novnc | awk -F'--listen ' '{print $2}' | awk '{print $1}')
    echo "Используется существующий порт noVNC: $NOVNC_PORT"
  else
    echo "Ошибка: служба noVNC не запущена. Сначала установите noVNC (опция 1)."
    return 1
  fi
  
  # Находим активный VNC дисплей
  VNC_SERVICE=$(systemctl list-units "tigervncserver@*.service" --state=running --no-legend | awk '{print $1}')
  if [ -z "$VNC_SERVICE" ]; then
    echo "Ошибка: не найден активный сервис TigerVNC. Сначала установите его (опция 1)."
    return 1
  fi
  local display_num_only=$(echo $VNC_SERVICE | sed -n 's/tigervncserver@\([0-9]*\).service/\1/p')
  VNC_DISPLAY=":$display_num_only"
  echo "Найден активный VNC дисплей: $VNC_DISPLAY"


  echo "Установка Nginx..."
  apt install -y nginx

  echo "Введите доменное имя для обратного прокси (например, vnc.example.com):"
  read HOSTNAME

  echo "Хотите включить базовую HTTP-аутентификацию (Basic Auth)? (Y/n):"
  read ENABLE_BASIC_AUTH
  ENABLE_BASIC_AUTH=${ENABLE_BASIC_AUTH:-y}

  local AUTH_CONFIG=""
  local AUTOCONNECT_CONFIG=""
  if [[ "$ENABLE_BASIC_AUTH" == "y" || "$ENABLE_BASIC_AUTH" == "Y" ]]; then
    echo "Введите имя пользователя для Basic Auth:"
    read AUTH_USER
    echo "Введите пароль для Basic Auth:"
    read -s AUTH_PASSWORD
    echo ""

    echo "Установка apache2-utils для htpasswd..."
    apt install -y apache2-utils

    htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASSWORD"
    
    AUTH_CONFIG="
        auth_basic \"Restricted Access\";
        auth_basic_user_file /etc/nginx/.htpasswd;"
        
    echo "Хотите отключить пароль VNC при входе через браузер (останется только Basic Auth)? (Y/n)"
    read DISABLE_VNC_PASS
    DISABLE_VNC_PASS=${DISABLE_VNC_PASS:-y}
    
    if [[ "$DISABLE_VNC_PASS" == "y" || "$DISABLE_VNC_PASS" == "Y" ]]; then
        echo "Модификация сервиса TigerVNC для отключения пароля при доступе с localhost..."
        sed -i "s/ExecStart=\/usr\/bin\/vncserver .*/ExecStart=\/usr\/bin\/vncserver -depth 24 -geometry 1280x800 ${VNC_DISPLAY} -localhost -securitytypes=none/" "/etc/systemd/system/tigervncserver@${display_num_only}.service"
        systemctl daemon-reload
        systemctl restart "tigervncserver@${display_num_only}.service"
        echo "Сервис TigerVNC перезапущен с новыми параметрами."
    fi

    echo "Хотите автоматически подключаться к рабочему столу после ввода логина/пароля? (Y/n)"
    read ENABLE_AUTOCONNECT
    ENABLE_AUTOCONNECT=${ENABLE_AUTOCONNECT:-y}
    if [[ "$ENABLE_AUTOCONNECT" == "y" || "$ENABLE_AUTOCONNECT" == "Y" ]]; then
        AUTOCONNECT_CONFIG="
    location = / {
        return 302 /index.html?autoconnect=true;
    }"
    fi
  fi

  echo "Установка Certbot для Let's Encrypt..."
  apt install -y certbot python3-certbot-nginx

  echo "Получение SSL-сертификата..."
  systemctl stop nginx
  certbot certonly --standalone -d $HOSTNAME --non-interactive --agree-tos -m admin@$HOSTNAME --cert-name $HOSTNAME
  local cert_status=$?
  systemctl start nginx
  
  if [ $cert_status -ne 0 ]; then
    echo "Ошибка получения SSL-сертификата. Проверьте, что домен $HOSTNAME указывает на IP этого сервера."
    return 1
  fi

  # Создание конфигурационного файла Nginx
  echo "Настройка Nginx..."
  cat << EOF > /etc/nginx/sites-available/$HOSTNAME
server {
    listen 80;
    server_name $HOSTNAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $HOSTNAME;

    ssl_certificate /etc/letsencrypt/live/$HOSTNAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$HOSTNAME/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    
    access_log /var/log/nginx/novnc.access.log;
    error_log /var/log/nginx/novnc.error.log;

    $AUTOCONNECT_CONFIG

    location / {
        $AUTH_CONFIG
        root /opt/noVNC/;
        
        # Websocket proxy
        location /websockify {
            proxy_pass http://localhost:$NOVNC_PORT;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "Upgrade";
            proxy_set_header Host \$host;
            proxy_read_timeout 600s;
        }
    }
}
EOF

  # Активация сайта
  ln -s /etc/nginx/sites-available/$HOSTNAME /etc/nginx/sites-enabled/
  # Удаляем default конфиг, если он есть, чтобы избежать конфликтов
  rm -f /etc/nginx/sites-enabled/default

  # Проверка конфигурации и перезагрузка Nginx
  if nginx -t; then
    systemctl reload nginx
    echo "Конфигурация Nginx успешно перезагружена."
  else
    echo "Ошибка в конфигурации Nginx. Проверьте с помощью 'nginx -t' для получения подробностей."
    return 1
  fi

  systemctl enable nginx

  echo "Настройка автоматического обновления сертификатов..."
  if ! systemctl list-timers | grep -q "certbot.timer"; then
      systemctl start certbot.timer
      systemctl enable certbot.timer
  fi
  
  echo "Настройка обратного прокси завершена!"
  echo "Доступ к вашему рабочему столу Linux по защищённому адресу: https://$HOSTNAME"
}

function main_menu() {
  while true; do
    echo ""
    echo "------------------ МЕНЮ ------------------"
    echo "1) Установить noVNC с TigerVNC и XFCE4"
    echo "2) Настроить обратный прокси Nginx с SSL"
    echo "3) Выход"
    echo "------------------------------------------"
    read -p "Введите ваш выбор: " choice

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
      echo "Неверный выбор, попробуйте снова."
      ;;
    esac
  done
}

main_menu
