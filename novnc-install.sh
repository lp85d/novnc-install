#!/bin/bash

# Установка noVNC + TigerVNC + XFCE4 на Debian/Ubuntu
# Дополнительно: настройка обратного прокси Nginx и SSL Let's Encrypt
# https://github.com/lp85d/novnc-install
# novnc_setup.sh v0.9.1 by lp85d

# Проверка прав root или sudo
if [ "$EUID" -ne 0 ]; then
  echo "Этот скрипт должен быть запущен от имени root или с правами sudo."
  exit 1
fi

function install_vnc_novnc() {
  # Запрос переменных у пользователя
  echo "Введите имя пользователя для VNC (по умолчанию: vncuser):"
  read VNC_USER
  VNC_USER=${VNC_USER:-vncuser}

  if ! id -u "$VNC_USER" &>/dev/null; then
    echo "Пользователь $VNC_USER не существует. Создаём..."
    useradd -m -s /bin/bash "$VNC_USER"
    echo "Установите пароль для $VNC_USER:"
    passwd "$VNC_USER"
  fi

  echo "Введите пароль VNC (не менее 6 символов):"
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

  echo "Введите номер дисплея VNC (по умолчанию :1):"
  read VNC_DISPLAY
  VNC_DISPLAY=${VNC_DISPLAY:-:1}
  VNC_PORT=$((5900 + ${VNC_DISPLAY#:}))

  # Получение публичного IP-адреса
  PUBLIC_IP=$(curl -s4 https://ifconfig.me)

  # Обновление системных пакетов
  echo "Обновление системных пакетов..."
  apt update && apt upgrade -y

  echo "Установка сервера TigerVNC и необходимых инструментов..."
  apt install -y tigervnc-standalone-server tigervnc-common git xfce4 xfce4-goodies dbus-x11 xfce4-terminal

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

  # Инициализация и активация VNC-сервера
  echo "Инициализация и активация VNC-сервера..."
  su - "$VNC_USER" -c "vncserver $VNC_DISPLAY"
  su - "$VNC_USER" -c "vncserver -kill $VNC_DISPLAY"

  echo "Создание службы systemd для TigerVNC..."
  cat << EOF > /etc/systemd/system/tigervncserver@.service
[Unit]
Description=Сервер TigerVNC
After=syslog.target network.target

[Service]
Type=forking
User=$VNC_USER
Group=$VNC_USER
WorkingDirectory=/home/$VNC_USER

PIDFile=/home/$VNC_USER/.vnc/%H%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :1 > /dev/null 2>&1
ExecStart=/usr/bin/vncserver -depth 24 -geometry 1280x800 :1
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
EOF

  # Перезагрузка systemd, активация и запуск службы tigervnc
  echo "Активация и запуск службы TigerVNC..."
  systemctl daemon-reload
  systemctl enable tigervncserver@$VNC_DISPLAY
  systemctl start tigervncserver@$VNC_DISPLAY

  # Установка noVNC (только если не установлен)
  if ! systemctl is-active --quiet novnc; then
    echo "Установка noVNC..."
    su - "$VNC_USER" -c "cd ~ && git clone https://github.com/novnc/noVNC.git"
    su - "$VNC_USER" -c "cd ~/noVNC && git clone https://github.com/novnc/websockify.git"

    # Создание службы systemd для noVNC
    echo "Создание службы systemd для noVNC..."
    cat << EOF > /etc/systemd/system/novnc.service
[Unit]
Description=Сервер noVNC
After=network.target

[Service]
Type=simple
ExecStart=/home/$VNC_USER/noVNC/utils/novnc_proxy --vnc localhost:$VNC_PORT --listen $NOVNC_PORT
Restart=always
User=$VNC_USER

[Install]
WantedBy=multi-user.target
EOF

    echo "Активация службы noVNC..."
    systemctl daemon-reload
    systemctl enable novnc
    systemctl start novnc

    echo "Создание символической ссылки с vnc.html на index.html..."
    ln -s /home/$VNC_USER/noVNC/vnc.html /home/$VNC_USER/noVNC/index.html
  fi

  echo "Настройка правил брандмауэра..."
  ufw allow $NOVNC_PORT
  ufw allow $VNC_PORT

  echo "-----------------------------------------------------------------------------------------"
  echo ""
  echo "Для разрешения внешнего доступа к необходимым портам (noVNC и VNC) в AWS CloudShell или с помощью AWS CLI,"
  echo "вы можете использовать следующие команды (только если используется группа безопасности по умолчанию):"
  echo ""
  echo "vpc_id=\$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
  echo "security_group_id=\$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=\$vpc_id --query 'SecurityGroups[?GroupName==\`default\`].GroupId' --output text)"
  echo ""
  echo "aws ec2 authorize-security-group-ingress --group-id \$security_group_id --protocol tcp --port $NOVNC_PORT --cidr 0.0.0.0/0"
  echo "aws ec2 authorize-security-group-ingress --group-id \$security_group_id --protocol tcp --port $VNC_PORT --cidr 0.0.0.0/0"
  echo "-----------------------------------------------------------------------------------------"

  echo "-----------------------------------------------------------------------------------------"
  echo "Установка завершена!"
  echo "Доступ к вашему рабочему столу Linux через noVNC по адресу:"
  echo "http://$PUBLIC_IP:$NOVNC_PORT"
}

function configure_nginx_reverse_proxy() {
  if [ -z "$NOVNC_PORT" ]; then
    if systemctl is-active --quiet novnc; then
      NOVNC_PORT=$(systemctl show -p ExecStart --value novnc | awk -F'--listen ' '{print $2}' | awk '{print $1}')
      echo "Используется существующий порт noVNC: $NOVNC_PORT"
    else
      echo "Ошибка: порт noVNC не определён. Сначала установите noVNC или задайте NOVNC_PORT вручную."
      return 1
    fi
  fi

  echo "Установка Nginx..."
  apt install -y nginx

  echo "Введите имя хоста для обратного прокси (например, vnc.example.com):"
  read HOSTNAME

  echo "Хотите включить базовую HTTP-аутентификацию? (y/N):"
  read ENABLE_BASIC_AUTH
  ENABLE_BASIC_AUTH=${ENABLE_BASIC_AUTH:-n}

  AUTH_CONFIG=""
  if [[ "$ENABLE_BASIC_AUTH" == "y" ]]; then
    echo "Введите имя пользователя для базовой аутентификации:"
    read AUTH_USER
    echo "Введите пароль для базовой аутентификации:"
    read -s AUTH_PASSWORD
    echo ""

    echo "Установка apache2-utils для htpasswd..."
    apt install -y apache2-utils

    htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASSWORD"
    chmod 640 /etc/nginx/.htpasswd
    chown root:www-data /etc/nginx/.htpasswd
    chmod 750 /etc/nginx

    AUTH_CONFIG="
        auth_basic \"Ограниченный доступ\";
        auth_basic_user_file /etc/nginx/.htpasswd;"
  fi

  # Временное отключение потенциально проблемной конфигурации сайта
  if [ -L /etc/nginx/sites-enabled/novnc ]; then
    echo "Временное отключение существующего сайта novnc..."
    mv /etc/nginx/sites-enabled/novnc /etc/nginx/sites-enabled/novnc.bak
  fi

  # Настройка сертификата с использованием плагина standalone
  if ! certbot certificates | grep -q "$HOSTNAME"; then
    echo "Установка Certbot для Let's Encrypt..."
    apt install -y certbot python3-certbot-nginx

    if [ ! -d "/etc/letsencrypt/live" ]; then
      echo "Создание директории /etc/letsencrypt/live..."
      mkdir -p /etc/letsencrypt/live
      if [ $? -ne 0 ]; then
        echo "Ошибка: не удалось создать директорию /etc/letsencrypt/live. Проверьте права доступа."
        return 1
      fi
    fi

    if [ ! -d "/etc/letsencrypt/live/$HOSTNAME" ]; then
      echo "Создание директории /etc/letsencrypt/live/$HOSTNAME..."
      mkdir -p /etc/letsencrypt/live/$HOSTNAME
      if [ $? -ne 0 ]; then
        echo "Ошибка: не удалось создать директорию /etc/letsencrypt/live/$HOSTNAME. Проверьте права доступа."
        return 1
      fi
    fi

    echo "Получение SSL-сертификата (используется плагин standalone)..."
    systemctl stop nginx
    if ! certbot certonly --standalone -d $HOSTNAME --non-interactive --agree-tos -m admin@$HOSTNAME --cert-name $HOSTNAME; then
      echo "Ошибка: не удалось получить SSL-сертификат."
      echo "Хотите автоматически повторить попытку создания сертификата? (y/n)"
      read RETRY_CERT
      RETRY_CERT=${RETRY_CERT:-n}

      if [[ "$RETRY_CERT" == "y" ]]; then
        echo "Повторная попытка создания сертификата..."
        if ! certbot certonly --standalone -d $HOSTNAME --non-interactive --agree-tos -m admin@$HOSTNAME --cert-name $HOSTNAME; then
          echo "Ошибка: повторная попытка не удалась. Проверьте сообщения об ошибках и попробуйте вручную."
          return 1
        else
          echo "SSL-сертификат успешно получен при повторной попытке."
        fi
      else
        echo "Пропуск повторной попытки. Исправьте проблему и попробуйте снова вручную."
        return 1
      fi
    fi
    systemctl start nginx
  else
    echo "SSL-сертификат для $HOSTNAME уже существует. Пропуск установки Certbot."
  fi

  # Создание конфигурационного файла Nginx
  echo "Настройка Nginx..."
  cat << EOF > /etc/nginx/sites-available/novnc
server {
    listen 80;
    server_name $HOSTNAME;

    # Перенаправление HTTP на HTTPS
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

  # Активация сайта
  if [ -L /etc/nginx/sites-enabled/novnc.bak ]; then
    echo "Замена старой конфигурации сайта novnc..."
    rm /etc/nginx/sites-enabled/novnc.bak
  fi
  if ! [ -L /etc/nginx/sites-enabled/novnc ]; then
    ln -s /etc/nginx/sites-available/novnc /etc/nginx/sites-enabled/
  fi

  # Установка правильных прав и владельца для Nginx
  chown -R www-data:www-data /var/lib/nginx
  find /etc/nginx -type d -exec chmod 750 {} \;
  find /etc/nginx -type f -exec chmod 640 {} \;

  # Проверка конфигурации и перезагрузка Nginx
  if nginx -t; then
    systemctl reload nginx
    echo "Конфигурация Nginx успешно перезагружена."
  else
    echo "Ошибка в конфигурации Nginx. Проверьте с помощью 'nginx -t' для получения подробностей."
    return 1
  fi

  # Активация Nginx при загрузке
  systemctl enable nginx

  echo "Настройка автоматического обновления сертификатов..."
  if ! grep -q "certbot renew" /etc/crontab; then
    echo "0 3 * * * certbot renew --quiet" >> /etc/crontab
  else
    echo "Автоматическое обновление Certbot уже настроено. Пропуск настройки crontab."
  fi

  echo "Настройка обратного прокси завершена!"
  echo "Доступ к вашему рабочему столу Linux по защищённому адресу: https://$HOSTNAME"
}

function fix_nginx_config() {
  echo "Попытка исправить распространённые проблемы конфигурации Nginx..."

  # Проверка активации сайта novnc
  if [ ! -L /etc/nginx/sites-enabled/novnc ]; then
    echo "Активация сайта novnc в Nginx..."
    ln -s /etc/nginx/sites-available/novnc /etc/nginx/sites-enabled/
  else
    echo "Сайт novnc уже активирован."
  fi

  # Проверка отключения сайта по умолчанию
  if [ -f /etc/nginx/sites-enabled/default ]; then
    echo "Отключение сайта Nginx по умолчанию..."
    rm /etc/nginx/sites-enabled/default
  fi

  # Проверка перенаправления HTTP на HTTPS
  if ! grep -q "return 301 https" /etc/nginx/sites-available/novnc; then
    echo "Добавление перенаправления HTTP на HTTPS в конфигурацию novnc..."
    sed -i '/listen 80;/a \    return 301 https://$HOSTNAME$request_uri;' /etc/nginx/sites-available/novnc
  fi

  # Проверка путей SSL-сертификатов
  if ! grep -q "ssl_certificate " /etc/nginx/sites-available/novnc; then
    echo "Пути SSL-сертификатов отсутствуют в конфигурации novnc. Убедитесь, что они правильно настроены."
  fi

  # Проверка конфигурации Nginx
  echo "Проверка конфигурации Nginx..."
  if nginx -t; then
    echo "Проверка конфигурации Nginx успешна. Перезагрузка Nginx..."
    systemctl reload nginx
  else
    echo "Проверка конфигурации Nginx не удалась. Проверьте конфигурацию вручную."
  fi

  echo "Попытка исправления завершена. Проверьте конфигурацию."
}

function reinstall_nginx_reverse_proxy() {
  echo "Переустановка настройки обратного прокси Nginx..."

  # Остановка Nginx и отключение сайта novnc
  echo "Остановка Nginx и отключение сайта novnc..."
  systemctl stop nginx
  if [ -L /etc/nginx/sites-enabled/novnc ]; then
    rm /etc/nginx/sites-enabled/novnc
  fi

  echo "Удаление существующей конфигурации Nginx и сертификатов Certbot..."
  rm -f /etc/nginx/sites-available/novnc
  certbot delete --cert-name "$HOSTNAME" --non-interactive

  echo "Повторная настройка обратного прокси Nginx..."
  configure_nginx_reverse_proxy
}

function restore_novnc_user() {
  # Проверка, установлен ли noVNC
  if [ -d "/home/$VNC_USER/noVNC" ] || systemctl is-active --quiet novnc; then
    echo "Обнаружена установка noVNC."
  else
    echo "noVNC не установлен. Сначала установите noVNC (опция 1)."
    return 1
  fi

  # Проверка существования пользователя
  echo "Введите имя пользователя для восстановления (по умолчанию: vncuser):"
  read VNC_USER
  VNC_USER=${VNC_USER:-vncuser}

  if id -u "$VNC_USER" &>/dev/null; then
    echo "Пользователь $VNC_USER уже существует."
    return 1
  fi

  # Создание нового пользователя
  echo "Создание пользователя $VNC_USER..."
  useradd -m -s /bin/bash "$VNC_USER"
  echo "Установите пароль для $VNC_USER:"
  passwd "$VNC_USER"

  # Восстановление конфигурации VNC
  echo "Введите пароль VNC (не менее 6 символов):"
  read -s VNC_PASSWORD
  echo ""

  echo "Настройка пароля VNC..."
  su - "$VNC_USER" -c "mkdir -p ~/.vnc"
  echo "$VNC_PASSWORD" | su - "$VNC_USER" -c "vncpasswd -f > ~/.vnc/passwd"
  su - "$VNC_USER" -c "chmod 600 ~/.vnc/passwd"

  # Восстановление скрипта запуска VNC
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

  # Обновление службы systemd для TigerVNC
  echo "Обновление службы systemd для TigerVNC..."
  VNC_DISPLAY=$(systemctl list-units --full -all | grep tigervncserver | awk '{print $1}' | grep -oP ':[\d]+')
  VNC_DISPLAY=${VNC_DISPLAY:-:1}
  VNC_PORT=$((5900 + ${VNC_DISPLAY#:}))

  cat << EOF > /etc/systemd/system/tigervncserver@.service
[Unit]
Description=Сервер TigerVNC
After=syslog.target network.target

[Service]
Type=forking
User=$VNC_USER
Group=$VNC_USER
WorkingDirectory=/home/$VNC_USER

PIDFile=/home/$VNC_USER/.vnc/%H%i.pid
ExecStartPre=-/usr/bin/vncserver -kill :1 > /dev/null 2>&1
ExecStart=/usr/bin/vncserver -depth 24 -geometry 1280x800 :1
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
EOF

  # Перезагрузка systemd и запуск службы
  systemctl daemon-reload
  systemctl enable tigervncserver@$VNC_DISPLAY
  systemctl start tigervncserver@$VNC_DISPLAY

  # Проверка и восстановление конфигурации Nginx
  if [ -f /etc/nginx/sites-available/novnc ]; then
    echo "Обнаружена конфигурация Nginx. Проверка..."
    if nginx -t; then
      systemctl reload nginx
      echo "Nginx перезагружен, доступ к сайту восстановлен."
    else
      echo "Ошибка в конфигурации Nginx. Запустите исправление конфигурации (опция 3)."
    fi
  else
    echo "Конфигурация Nginx не найдена. Настройте обратный прокси (опция 2)."
  fi

  # Проверка порта noVNC
  NOVNC_PORT=$(systemctl show -p ExecStart --value novnc | awk -F'--listen ' '{print $2}' | awk '{print $1}')
  NOVNC_PORT=${NOVNC_PORT:-6080}

  echo "Восстановление завершено!"
  echo "Доступ к рабочему столу через noVNC: http://$(curl -s4 https://ifconfig.me):$NOVNC_PORT"
  if [ -f /etc/nginx/sites-available/novnc ]; then
    HOSTNAME=$(grep server_name /etc/nginx/sites-available/novnc | awk '{print $2}' | tr -d ';')
    echo "Доступ через Nginx: https://$HOSTNAME"
  fi
}

function main_menu() {
  while true; do
    echo "Выберите опцию:"
    echo "1) Установить noVNC с TigerVNC и XFCE4"
    echo "2) Настроить обратный прокси Nginx с Let's Encrypt"
    echo "3) Исправить конфигурацию Nginx"
    echo "4) Переустановить настройку обратного прокси Nginx"
    echo "5) Восстановить удалённого пользователя noVNC"
    echo "6) Выход"
    read -p "Введите ваш выбор: " choice

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
      restore_novnc_user
      ;;
    6)
      exit 0
      ;;
    *)
      echo "Неверный выбор, попробуйте снова."
      ;;
    esac
  done
}

main_menu
