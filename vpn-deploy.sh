#!/bin/bash
set -euo pipefail

CONF="/root/deploy-vpn.conf"
TOKEN_FILE="/root/.awgram_token"

# ================= НАСТРОЙКИ =================
if [[ -f "$CONF" ]]; then
    source "$CONF"
    echo "Загружены сохранённые настройки из $CONF"
else
    echo "=================================================="
    echo "   Скрипт развертывания VPN-сервера (AmneziaWG)    "
    echo "=================================================="

    read -rp "Введите имя нового пользователя: " NEW_USER
    if [[ -z "$NEW_USER" ]]; then echo "Имя не может быть пустым."; exit 1; fi

    read -rp "Введите SSH-порт [2222]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-2222}

    read -rp "Введите имя сервера в приложении Amnezia: " SERVER_NAME
    if [[ -z "$SERVER_NAME" ]]; then echo "Имя сервера не может быть пустым."; exit 1; fi

    read -rp "Введите UDP-порт для AmneziaWG [443]: " AWG_PORT
    AWG_PORT=${AWG_PORT:-443}

    read -rp "Введите ваш Telegram ID (только цифры): " ADMIN_ID
    if [[ ! "$ADMIN_ID" =~ ^[0-9]+$ ]]; then echo "ID должен быть числом."; exit 1; fi

    read -rp "Введите ваш IP для белого списка Fail2Ban (или оставьте пустым): " WHITELIST_IP

    cat > "$CONF" <<EOF
NEW_USER="$NEW_USER"
SSH_PORT="$SSH_PORT"
SERVER_NAME="$SERVER_NAME"
AWG_PORT="$AWG_PORT"
ADMIN_ID="$ADMIN_ID"
WHITELIST_IP="$WHITELIST_IP"
EOF
    chmod 600 "$CONF"
    echo "Настройки сохранены в $CONF"
fi

# Токен: из файла или спросить
if [[ -f "$TOKEN_FILE" ]]; then
    BOT_TOKEN=$(cat "$TOKEN_FILE")
    echo "Токен загружен из $TOKEN_FILE"
else
    while true; do
        read -rp "Введите токен Telegram-бота (от @BotFather): " BOT_TOKEN
        if [[ -n "$BOT_TOKEN" ]]; then break; else echo "Ошибка: токен не может быть пустым."; fi
    done
fi

NET_IFACE=$(ip -4 route show default | awk '{print $5}' | head -n1)
if [[ -z "$NET_IFACE" ]]; then
    read -rp "Не удалось определить сетевой интерфейс. Введите вручную (например, eth0): " NET_IFACE
fi
echo "Сетевой интерфейс: $NET_IFACE"

echo "=================================================="
echo "Начинаем развертывание..."
echo "Пользователь: $NEW_USER | SSH: $SSH_PORT | AWG: $AWG_PORT | Имя: $SERVER_NAME"
echo "=================================================="

# ================= 1. ПОЛЬЗОВАТЕЛЬ =================
echo "=== 1. Пользователь ==="
if ! id "$NEW_USER" &>/dev/null; then
    adduser --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
fi

# ================= 2. БАЗОВАЯ СИСТЕМА =================
echo "=== 2. Базовая система ==="
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y gpg acl curl wget

grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.lo.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

if [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
grep -q 'vm.swappiness=10' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
sysctl -p

if [ -L /etc/resolv.conf ]; then
    rm /etc/resolv.conf
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    systemctl disable --now systemd-resolved 2>/dev/null || true
    systemctl mask systemd-resolved 2>/dev/null || true
fi

apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
apt install -y linux-generic

CURRENT_KERNEL=$(uname -r)
echo "Текущее ядро: $CURRENT_KERNEL"
INSTALLED_KERNEL=$(dpkg -l | grep -oP 'linux-image-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic' | sort -V | tail -n1)
if [[ "$CURRENT_KERNEL" != "$INSTALLED_KERNEL" ]]; then
    echo "⚠️ Сервер загружен в старое ядро ($CURRENT_KERNEL), а установлено новое ($INSTALLED_KERNEL)."
    echo "Перезагрузи сервер и запусти скрипт снова — он продолжит с этого места."
    exit 1
fi

for old_kernel in $(dpkg -l | grep -oP 'linux-image-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic' | sort -u); do
    if [[ "$old_kernel" != "$CURRENT_KERNEL" ]]; then
        echo "Удаляем старое ядро: $old_kernel"
        apt purge -y linux-image-$old_kernel linux-headers-$old_kernel linux-modules-$old_kernel 2>/dev/null || true
    fi
done
apt autoremove -y

echo 'kernel.unprivileged_userns_clone = 0' | tee /etc/sysctl.d/99-userns.conf
sysctl -w kernel.unprivileged_userns_clone=0

# ================= 3. SSH =================
echo "=== 3. SSH ==="
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
systemctl disable --now ssh.socket 2>/dev/null || true
systemctl enable --now ssh.service
systemctl restart ssh

# ================= 4. FAIL2BAN =================
echo "=== 4. Fail2Ban ==="
apt install -y fail2ban
sed -i 's|fail2ban-client flushlogs 1>/dev/null|fail2ban-client flushlogs 1>/dev/null \|\| true|' /etc/logrotate.d/fail2ban 2>/dev/null || true

IGNORE_IP="127.0.0.1/8"
if [[ -n "$WHITELIST_IP" ]]; then IGNORE_IP="$IGNORE_IP $WHITELIST_IP"; fi

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 86400
findtime = 3600
maxretry = 2
ignoreip = $IGNORE_IP

[sshd]
enabled = true
port = $SSH_PORT
EOF
systemctl restart fail2ban
sleep 2
fail2ban-client status sshd || true

# ================= 5. NAT =================
echo "=== 5. NAT для VPN ==="
iptables -t nat -A POSTROUTING -s 10.9.9.0/24 -o "$NET_IFACE" -j MASQUERADE
apt install -y iptables-persistent <<< "yes
yes"

# ================= 6. LOGROTATE =================
echo "=== 6. Logrotate ==="
apt install -y logrotate
cat > /etc/logrotate.d/rsyslog <<EOF
/var/log/syslog
/var/log/mail.log
/var/log/kern.log
/var/log/auth.log
/var/log/user.log
/var/log/cron.log
{
    su root adm
    rotate 7
    maxsize 100M
    daily
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

# ================= 7. AMNEZIAWG =================
echo "=== 7. AmneziaWG ==="
if ! systemctl is-active --quiet awg-quick@awg0; then
    wget -O /tmp/install_amneziawg.sh https://github.com/bivlked/amneziawg-installer/releases/latest/download/install_amneziawg.sh
    chmod +x /tmp/install_amneziawg.sh
    bash /tmp/install_amneziawg.sh --port="$AWG_PORT" --subnet="10.9.9.1/24" --route-amnezia --yes || {
        echo "!!! AmneziaWG запросил перезагрузку. Перезагрузи сервер и запусти скрипт снова."
        exit 0
    }
fi

# ================= 8. AWGRAM =================
echo "=== 8. awgram ==="
if ! command -v awgram &> /dev/null; then
    curl -fsSL https://github.com/ekuraev/awgram/releases/latest/download/install.sh \
      | bash -s -- install --lang ru --mode hardened --token "$BOT_TOKEN" --admins "$ADMIN_ID" || {
        echo "Установщик awgram запросил данные. Введите их вручную:"
        curl -fsSL https://github.com/ekuraev/awgram/releases/latest/download/install.sh | bash
      }
    echo "$BOT_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
fi

echo "=== 9. Права для awgram ==="
setfacl -m u:awgram:x /root
setfacl -m u:awgram:x /root/awg
setfacl -m u:awgram:rx /root/awg/manage_amneziawg.sh
echo "*/1 * * * * root bash -c 'for f in /root/awg/*.conf /root/awg/*.png /root/awg/*.vpnuri; do setfacl -m u:awgram:rx \"\$f\" 2>/dev/null; done'" > /etc/cron.d/awgram-acl
bash -c 'for f in /root/awg/*.conf /root/awg/*.png /root/awg/*.vpnuri; do setfacl -m u:awgram:rx "$f"; done' 2>/dev/null || true
systemctl restart awgram

# ================= 10. WHITEVPN =================
echo "=== 10. WhiteVPN (без бота) ==="
if [ ! -d /opt/block-traffic ]; then
    curl -fsSL https://raw.githubusercontent.com/anten-ka/whitevpn/main/install.sh -o /tmp/whitevpn-install.sh
    bash /tmp/whitevpn-install.sh <<< "n"
fi

# ================= 11. ПРОВЕРКА =================
echo "=== 11. Проверка ==="
systemctl status awg-quick@awg0 --no-pager | head -5
systemctl status awgram --no-pager | head -5
iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE || echo "NAT не найден!"

echo "=== ГОТОВО ==="
