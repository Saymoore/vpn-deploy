#!/bin/bash
set -uo pipefail

# ================= ЦВЕТА =================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# ================= РЕЖИМ ВЫВОДА =================
echo -e "${CYAN}Выберите режим вывода:${NC}"
echo -e "  1) Краткий (только ключевые сообщения)"
echo -e "  2) Полный (весь вывод команд, для отладки)"
read -rp "Ваш выбор [1]: " OUTPUT_MODE
OUTPUT_MODE=${OUTPUT_MODE:-1}

if [[ "$OUTPUT_MODE" == "2" ]]; then
    VERBOSE=true
    info "Включён полный режим вывода."
else
    VERBOSE=false
    info "Включён краткий режим вывода."
fi

run() {
    if [[ "$VERBOSE" == "true" ]]; then
        "$@"
    else
        "$@" >/dev/null 2>&1 || {
            err "Команда завершилась с ошибкой: $*"
            "$@" 2>&1 | tail -20
        }
    fi
}

CONF="/etc/deploy-vpn.conf"

# ================= НАСТРОЙКИ =================
if [[ -f "$CONF" ]]; then
    source "$CONF"
    info "Загружены сохранённые настройки из $CONF"
else
    echo -e "${MAGENTA}==================================================${NC}"
    echo -e "${MAGENTA}   Скрипт развертывания VPN-сервера (AmneziaWG)    ${NC}"
    echo -e "${MAGENTA}==================================================${NC}"

    read -rp "Введите имя нового пользователя: " NEW_USER
    if [[ -z "$NEW_USER" ]]; then err "Имя не может быть пустым."; exit 1; fi

    read -rp "Введите SSH-порт [2222]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-2222}

    read -rp "Введите имя сервера в приложении Amnezia: " SERVER_NAME
    if [[ -z "$SERVER_NAME" ]]; then err "Имя сервера не может быть пустым."; exit 1; fi

    read -rp "Введите UDP-порт для AmneziaWG [443]: " AWG_PORT
    AWG_PORT=${AWG_PORT:-443}

    read -rp "Введите ваш IP для белого списка Fail2Ban (или оставьте пустым): " WHITELIST_IP

    cat > "$CONF" <<EOF
NEW_USER="$NEW_USER"
SSH_PORT="$SSH_PORT"
SERVER_NAME="$SERVER_NAME"
AWG_PORT="$AWG_PORT"
WHITELIST_IP="$WHITELIST_IP"
EOF
    chmod 600 "$CONF"
    ok "Настройки сохранены в $CONF"
fi

NET_IFACE=$(ip -4 route show default | awk '{print $5}' | head -n1)
if [[ -z "$NET_IFACE" ]]; then
    read -rp "Не удалось определить сетевой интерфейс. Введите вручную (например, eth0): " NET_IFACE
fi
info "Сетевой интерфейс: $NET_IFACE"

echo -e "${MAGENTA}==================================================${NC}"
info "Пользователь: $NEW_USER | SSH: $SSH_PORT | AWG: $AWG_PORT | Имя: $SERVER_NAME"
echo -e "${MAGENTA}==================================================${NC}"

# ================= 1. ПОЛЬЗОВАТЕЛЬ =================
step "1. Пользователь"
if ! id "$NEW_USER" &>/dev/null; then
    # adduser всегда виден (интерактивный)
    adduser --gecos "" "$NEW_USER"
    run usermod -aG sudo "$NEW_USER"
    ok "Пользователь $NEW_USER создан."
else
    info "Пользователь $NEW_USER уже существует."
fi

# ================= 2. БАЗОВАЯ СИСТЕМА =================
step "2. Базовая система"
export DEBIAN_FRONTEND=noninteractive
info "Обновление пакетов (может занять время)..."
run apt update
run apt install -y gpg acl curl wget
ok "Базовые пакеты установлены."

info "Настройка IPv6 и форвардинга..."
grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.lo.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

info "Создание swap (1G)..."
if [ ! -f /swapfile ]; then
    run fallocate -l 1G /swapfile
    run chmod 600 /swapfile
    run mkswap /swapfile
    run swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    grep -q 'vm.swappiness=10' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    ok "Swap создан."
else
    info "Swap уже существует."
fi

info "Отключение systemd-resolved..."
if [ -L /etc/resolv.conf ]; then
    rm /etc/resolv.conf
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    run systemctl disable --now systemd-resolved
    run systemctl mask systemd-resolved
    ok "DNS настроен."
fi

info "Обновление системы (может занять время)..."
run apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
run apt install -y linux-generic
ok "Система обновлена."

CURRENT_KERNEL=$(uname -r)
INSTALLED_KERNEL=$(dpkg -l | grep -oP 'linux-image-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic' | sort -V | tail -n1)
if [[ "$CURRENT_KERNEL" != "$INSTALLED_KERNEL" ]]; then
    echo -e "\n${YELLOW}==================================================${NC}"
    warn "Сервер загружен в старое ядро ($CURRENT_KERNEL), а установлено новое ($INSTALLED_KERNEL)."
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "${CYAN}Что делать:${NC}"
    echo -e "  1. Перезагрузи сервер:"
    echo -e "     ${GREEN}sudo reboot${NC}"
    echo -e "  2. После перезагрузки зайди снова (порт пока 22):"
    echo -e "     ${GREEN}ssh root@$(hostname -I | awk '{print $1}')${NC}"
    echo -e "  3. Скачай скрипт и запусти снова:"
    echo -e "     ${GREEN}curl -sL https://raw.githubusercontent.com/Saymoore/vpn-deploy/main/vpn-deploy.sh -o /tmp/deploy-vpn.sh${NC}"
    echo -e "     ${GREEN}sudo bash /tmp/deploy-vpn.sh${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    exit 1
fi

info "Удаление старых ядер..."
for old_kernel in $(dpkg -l | grep -oP 'linux-image-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic' | sort -u); do
    if [[ "$old_kernel" != "$CURRENT_KERNEL" ]]; then
        run apt purge -y linux-image-$old_kernel linux-headers-$old_kernel linux-modules-$old_kernel
    fi
done
run apt autoremove -y

echo 'kernel.unprivileged_userns_clone = 0' | tee /etc/sysctl.d/99-userns.conf >/dev/null
sysctl -w kernel.unprivileged_userns_clone=0 >/dev/null
ok "Базовая система готова."

# ================= 3. SSH =================
step "3. SSH"
info "Настройка SSH (порт $SSH_PORT, root отключён, пароль включён)..."
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
run systemctl disable --now ssh.socket
run systemctl enable --now ssh.service
run systemctl restart ssh
ok "SSH настроен."

# ================= 4. FAIL2BAN =================
step "4. Fail2Ban"
info "Установка Fail2Ban..."
run apt install -y fail2ban
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
run systemctl restart fail2ban
sleep 1
fail2ban-client status sshd && ok "Fail2Ban настроен." || warn "Fail2Ban не запустился."

# ================= 5. NAT =================
step "5. NAT для VPN"
info "Добавление NAT-правила..."
iptables -t nat -A POSTROUTING -s 10.9.9.0/24 -o "$NET_IFACE" -j MASQUERADE
run apt install -y iptables-persistent <<< "yes
yes"
ok "NAT настроен."

# ================= 6. LOGROTATE =================
step "6. Logrotate"
info "Настройка Logrotate..."
run apt install -y logrotate
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
ok "Logrotate настроен."

# ================= 7. AMNEZIAWG =================
step "7. AmneziaWG"
if ! systemctl is-active --quiet awg-quick@awg0; then
    info "Скачивание установщика AmneziaWG..."
    run wget -qO /tmp/install_amneziawg.sh https://github.com/bivlked/amneziawg-installer/releases/latest/download/install_amneziawg.sh
    chmod +x /tmp/install_amneziawg.sh
    info "Запуск установщика AmneziaWG..."
    info "ВАЖНО: когда установщик спросит 'Перезагрузить сейчас? [y/N]', ответь N (нет)."
    info "Скрипт покажет, что делать дальше."
    bash /tmp/install_amneziawg.sh --port="$AWG_PORT" --subnet="10.9.9.1/24" --route-amnezia || true

    if systemctl is-active --quiet awg-quick@awg0; then
        ok "AmneziaWG установлен и работает."
    else
        echo -e "\n${YELLOW}==================================================${NC}"
        warn "AmneziaWG установлен, но требует перезагрузку."
        echo -e "${YELLOW}==================================================${NC}"
        echo -e "${CYAN}Что делать:${NC}"
        echo -e "  1. Перезагрузи сервер:"
        echo -e "     ${GREEN}sudo reboot${NC}"
        echo -e "  2. После перезагрузки зайди под ${CYAN}$NEW_USER${NC} (порт ${CYAN}$SSH_PORT${NC}):"
        echo -e "     ${GREEN}ssh -p $SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')${NC}"
        echo -e "  3. Скачай скрипт и запусти снова:"
        echo -e "     ${GREEN}curl -sL https://raw.githubusercontent.com/Saymoore/vpn-deploy/main/vpn-deploy.sh -o /tmp/deploy-vpn.sh${NC}"
        echo -e "     ${GREEN}sudo bash /tmp/deploy-vpn.sh${NC}"
        echo -e "${YELLOW}==================================================${NC}"
        exit 0
    fi
else
    info "AmneziaWG уже установлен."
fi

# ================= 8. AWGRAM =================
step "8. awgram"
if ! command -v awgram &> /dev/null; then
    info "Устанавливаем awgram (интерактивно: язык, режим, токен, ID, путь)..."
    curl -fsSL https://github.com/ekuraev/awgram/releases/latest/download/install.sh | bash || true
fi

info "Останавливаем сервис для выдачи прав..."
run systemctl stop awgram

info "Выдаём права awgram на /root/awg..."
setfacl -m u:awgram:x /root 2>/dev/null || true
setfacl -m u:awgram:x /root/awg 2>/dev/null || true
setfacl -m u:awgram:rx /root/awg/manage_amneziawg.sh 2>/dev/null || true

if ! sudo -u awgram ls /root/awg/manage_amneziawg.sh &>/dev/null; then
    warn "awgram не видит файл. Пробуем ещё раз..."
    setfacl -m u:awgram:x /root 2>/dev/null || true
    setfacl -m u:awgram:x /root/awg 2>/dev/null || true
    setfacl -m u:awgram:rx /root/awg/manage_amneziawg.sh 2>/dev/null || true
fi

info "Запускаем awgram..."
run systemctl start awgram
sleep 2
if systemctl is-active --quiet awgram; then
    ok "awgram запущен."
else
    warn "awgram не запустился. Проверь: systemctl status awgram"
fi

# ================= 9. CRON ДЛЯ ACL =================
step "9. Cron для ACL"
info "Настройка cron для автоматической выдачи прав..."
echo "*/1 * * * * root bash -c 'for f in /root/awg/*.conf /root/awg/*.png /root/awg/*.vpnuri; do setfacl -m u:awgram:rx \"\$f\" 2>/dev/null; done'" > /etc/cron.d/awgram-acl
bash -c 'for f in /root/awg/*.conf /root/awg/*.png /root/awg/*.vpnuri; do setfacl -m u:awgram:rx "$f"; done' 2>/dev/null || true
ok "Cron настроен."

# ================= 10. WHITEVPN =================
step "10. WhiteVPN"
if [ ! -d /opt/block-traffic ]; then
    info "Установка WhiteVPN (без бота)..."
    run curl -fsSL https://raw.githubusercontent.com/anten-ka/whitevpn/main/install.sh -o /tmp/whitevpn-install.sh
    bash /tmp/whitevpn-install.sh <<< "n"
    ok "WhiteVPN установлен."
else
    info "WhiteVPN уже установлен."
fi

# ================= 11. ПРОВЕРКА =================
step "11. Проверка"
info "Статус AmneziaWG:"
systemctl status awg-quick@awg0 --no-pager | head -5
info "Статус awgram:"
systemctl status awgram --no-pager | head -5
info "Проверка NAT:"
iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE || warn "NAT не найден!"

echo -e "\n${GREEN}==================================================${NC}"
echo -e "${GREEN}   ✅ РАЗВЕРТЫВАНИЕ ЗАВЕРШЕНО!                    ${NC}"
echo -e "${GREEN}==================================================${NC}"
echo -e "Сервер готов к работе."
echo -e ""
echo -e "Для входа по SSH используй:"
echo -e "  ${CYAN}ssh -p $SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')${NC}"
echo -e ""
echo -e "Root по SSH отключён (безопасность)."
echo -e "${GREEN}==================================================${NC}"
