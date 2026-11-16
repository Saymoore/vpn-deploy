#!/bin/bash
set -uo pipefail

# ================= ПРОВЕРКА ROOT =================
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[0;31m[ERROR]\033[0m Этот скрипт нужно запускать от имени root или через sudo. (This script must be run as root or via sudo.)"
  echo -e "  Попробуй (Try): \033[0;32msudo bash $0\033[0m"
  exit 1
fi

# ================= ЦВЕТА (COLORS) =================
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

# ================= РЕЖИМ ВЫВОДА (OUTPUT MODE) =================
echo -e "${CYAN}Выберите режим вывода (Select output mode):${NC}"
echo -e "  1) Краткий (Brief - only key messages)"
echo -e "  2) Полный (Full - all command output, for debugging)"
read -rp "Ваш выбор (Your choice) [1]: " OUTPUT_MODE
OUTPUT_MODE=${OUTPUT_MODE:-1}

if [[ "$OUTPUT_MODE" == "2" ]]; then
    VERBOSE=true
    info "Включён полный режим вывода. (Full output mode enabled.)"
else
    VERBOSE=false
    info "Включён краткий режим вывода. (Brief output mode enabled.)"
fi

run() {
    if [[ "$VERBOSE" == "true" ]]; then
        "$@"
    else
        "$@" >/dev/null 2>&1 || {
            err "Команда завершилась с ошибкой (Command failed): $*"
            "$@" 2>&1 | tail -20
        }
    fi
}

CONF="/etc/deploy-vpn.conf"
RUN_CMD="sudo bash -c 'curl -sL https://raw.githubusercontent.com/Saymoore/vpn-deploy/main/vpn-deploy.sh -o /tmp/d.sh && bash /tmp/d.sh'"

# ================= НАСТРОЙКИ (SETTINGS) =================
if [[ -f "$CONF" ]]; then
    source "$CONF"
    info "Загружены сохранённые настройки из $CONF (Loaded saved settings from $CONF)"
else
    echo -e "${MAGENTA}==================================================${NC}"
    echo -e "${MAGENTA}   Скрипт развертывания VPN-сервера (AmneziaWG)    ${NC}"
    echo -e "${MAGENTA}   VPN Server Deployment Script (AmneziaWG)        ${NC}"
    echo -e "${MAGENTA}==================================================${NC}"

    read -rp "Введите имя нового пользователя (Enter new username): " NEW_USER
    if [[ -z "$NEW_USER" ]]; then err "Имя не может быть пустым. (Username cannot be empty.)"; exit 1; fi

    read -rp "Введите SSH-порт (Enter SSH port) [2222]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-2222}

    read -rp "Введите имя сервера в приложении Amnezia (Enter server name in Amnezia app): " SERVER_NAME
    if [[ -z "$SERVER_NAME" ]]; then err "Имя сервера не может быть пустым. (Server name cannot be empty.)"; exit 1; fi

    read -rp "Введите UDP-порт для AmneziaWG (Enter UDP port for AmneziaWG) [443]: " AWG_PORT
    AWG_PORT=${AWG_PORT:-443}

    # Автоопределение IP пользователя (Auto-detect user IP)
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        CUR_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    else
        CUR_IP=""
    fi
    
    read -rp "Введите дополнительный IP для белого списка Fail2Ban (Enter extra IP for Fail2Ban whitelist, current: ${CUR_IP:-unknown}, leave empty if not needed): " EXTRA_IP
    
    WHITELIST_IP="$CUR_IP"
    if [[ -n "$EXTRA_IP" ]]; then
        if [[ -n "$WHITELIST_IP" ]]; then
            WHITELIST_IP="$WHITELIST_IP $EXTRA_IP"
        else
            WHITELIST_IP="$EXTRA_IP"
        fi
    fi

    cat > "$CONF" <<EOF
NEW_USER="$NEW_USER"
SSH_PORT="$SSH_PORT"
SERVER_NAME="$SERVER_NAME"
AWG_PORT="$AWG_PORT"
WHITELIST_IP="$WHITELIST_IP"
EOF
    chmod 600 "$CONF"
    ok "Настройки сохранены в $CONF (Settings saved to $CONF)"
    info "IP для whitelist Fail2Ban (IP for Fail2Ban whitelist): $WHITELIST_IP"
fi

NET_IFACE=$(ip -4 route show default | awk '{print $5}' | head -n1)
if [[ -z "$NET_IFACE" ]]; then
    read -rp "Не удалось определить сетевой интерфейс. Введите вручную (Could not determine network interface. Enter manually, e.g. eth0): " NET_IFACE
fi
info "Сетевой интерфейс (Network interface): $NET_IFACE"

echo -e "${MAGENTA}==================================================${NC}"
info "Пользователь (User): $NEW_USER | SSH: $SSH_PORT | AWG: $AWG_PORT | Имя (Name): $SERVER_NAME"
echo -e "${MAGENTA}==================================================${NC}"

# ================= 1. ПОЛЬЗОВАТЕЛЬ (USER) =================
step "1. Пользователь (User)"
if ! id "$NEW_USER" &>/dev/null; then
    adduser --gecos "" "$NEW_USER"
    run usermod -aG sudo "$NEW_USER"
    ok "Пользователь создан (User created): $NEW_USER"
else
    info "Пользователь уже существует (User already exists): $NEW_USER"
fi

# ================= 2. БАЗОВАЯ СИСТЕМА (BASE SYSTEM) =================
step "2. Базовая система (Base system)"
export DEBIAN_FRONTEND=noninteractive
info "Обновление пакетов (Updating packages, may take time)..."
run apt update
run apt install -y gpg acl curl wget qrencode
ok "Базовые пакеты установлены (Base packages installed)."

info "Настройка IPv6 и форвардинга (Configuring IPv6 and forwarding)..."
grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.lo.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1

info "Создание swap (Creating swap, 1G)..."
if [ ! -f /swapfile ]; then
    run fallocate -l 1G /swapfile
    run chmod 600 /swapfile
    run mkswap /swapfile
    run swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    grep -q 'vm.swappiness=10' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    ok "Swap создан (Swap created)."
else
    info "Swap уже существует (Swap already exists)."
fi

info "Отключение systemd-resolved (Disabling systemd-resolved)..."
if [ -L /etc/resolv.conf ]; then
    rm /etc/resolv.conf
    printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf
    run systemctl disable --now systemd-resolved
    run systemctl mask systemd-resolved
    ok "DNS настроен (DNS configured)."
fi

info "Обновление системы (Updating system, may take time)..."
run apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
run apt install -y linux-generic
ok "Система обновлена (System updated)."

CURRENT_KERNEL=$(uname -r)
INSTALLED_KERNEL=$(dpkg -l | grep -oP 'linux-image-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic' | sort -V | tail -n1)
if [[ "$CURRENT_KERNEL" != "$INSTALLED_KERNEL" ]]; then
    echo -e "\n${YELLOW}==================================================${NC}"
    warn "Сервер загружен в старое ядро, а установлено новое (Server booted into old kernel, new one installed)."
    warn "Текущее ядро (Current kernel): $CURRENT_KERNEL, Установлено (Installed): $INSTALLED_KERNEL"
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "${CYAN}Что делать (What to do):${NC}"
    echo -e "  1. Перезагрузи сервер (Reboot server):"
    echo -e "     ${GREEN}sudo reboot${NC}"
    echo -e "  2. После перезагрузки зайди снова, порт пока 22 (After reboot, log in again, port is still 22):"
    echo -e "     ${GREEN}ssh root@$(hostname -I | awk '{print $1}')${NC}"
    echo -e "  3. Запусти скрипт снова (Run the script again):"
    echo -e "     ${GREEN}$RUN_CMD${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    exit 1
fi

info "Удаление старых ядер (Removing old kernels)..."
for old_kernel in $(dpkg -l | grep -oP 'linux-image-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic' | sort -u); do
    if [[ "$old_kernel" != "$CURRENT_KERNEL" ]]; then
        run apt purge -y linux-image-$old_kernel linux-headers-$old_kernel linux-modules-$old_kernel
    fi
done
run apt autoremove -y

echo 'kernel.unprivileged_userns_clone = 0' | tee /etc/sysctl.d/99-userns.conf >/dev/null
sysctl -w kernel.unprivileged_userns_clone=0 >/dev/null
ok "Базовая система готова (Base system ready)."

# ================= 3. SSH (настройка порта) =================
step "3. SSH (настройка порта / SSH port setup)"
info "Настройка SSH (Configuring SSH, port $SSH_PORT)..."
sed -i "s/^#*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
run systemctl disable --now ssh.socket
run systemctl enable --now ssh.service
run systemctl restart ssh
ok "SSH порт изменён на $SSH_PORT (SSH port changed to $SSH_PORT)."

# ================= 4. FAIL2BAN =================
step "4. Fail2Ban"
info "Установка Fail2Ban (Installing Fail2Ban)..."
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
fail2ban-client status sshd && ok "Fail2Ban настроен (Fail2Ban configured)." || warn "Fail2Ban не запустился (Fail2Ban failed to start)."

# ================= 5. NAT =================
step "5. NAT для VPN (NAT for VPN)"
info "Добавление NAT-правила (Adding NAT rule)..."
iptables -t nat -A POSTROUTING -s 10.9.9.0/24 -o "$NET_IFACE" -j MASQUERADE
run apt install -y iptables-persistent <<< "yes
yes"
ok "NAT настроен (NAT configured)."

# ================= 6. LOGROTATE =================
step "6. Logrotate"
info "Настройка Logrotate (Configuring Logrotate)..."
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
ok "Logrotate настроен (Logrotate configured)."

# ================= 7. AMNEZIAWG =================
step "7. AmneziaWG"
if ! systemctl is-active --quiet awg-quick@awg0; then
    info "Скачивание установщика AmneziaWG (Downloading AmneziaWG installer)..."
    run wget -qO /tmp/install_amneziawg.sh https://github.com/bivlked/amneziawg-installer/releases/latest/download/install_amneziawg.sh
    chmod +x /tmp/install_amneziawg.sh
    info "Запуск установщика AmneziaWG (Running AmneziaWG installer)..."
    bash /tmp/install_amneziawg.sh \
        --port="$AWG_PORT" \
        --subnet="10.9.9.1/24" \
        --disallow-ipv6 \
        --route-amnezia \
        --isolation=on \
        --server-name="$SERVER_NAME" || true

    if systemctl is-active --quiet awg-quick@awg0; then
        ok "AmneziaWG установлен и работает (AmneziaWG installed and running)."
    else
        echo -e "\n${YELLOW}==================================================${NC}"
        warn "AmneziaWG установлен, но требует перезагрузку (AmneziaWG installed, but requires reboot)."
        echo -e "${YELLOW}==================================================${NC}"
        echo -e "${CYAN}Что делать (What to do):${NC}"
        echo -e "  1. Перезагрузи сервер (Reboot server):"
        echo -e "     ${GREEN}sudo reboot${NC}"
        echo -e "  2. После перезагрузки зайди под $NEW_USER, порт $SSH_PORT (After reboot, log in as $NEW_USER, port $SSH_PORT):"
        echo -e "     ${GREEN}ssh -p $SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')${NC}"
        echo -e "  3. Запусти скрипт снова (Run the script again):"
        echo -e "     ${GREEN}$RUN_CMD${NC}"
        echo -e "${YELLOW}==================================================${NC}"
        exit 0
    fi
else
    info "AmneziaWG уже установлен (AmneziaWG already installed)."
fi

# ================= 8. AWGRAM =================
step "8. awgram"
if ! command -v awgram &> /dev/null; then
    info "Устанавливаем awgram (Installing awgram - interactive: language, mode, token, ID, path)..."
    curl -fsSL https://github.com/ekuraev/awgram/releases/latest/download/install.sh | bash || true
fi

info "Останавливаем сервис для выдачи прав (Stopping service to set permissions)..."
run systemctl stop awgram

info "Выдаём права awgram на /root/awg (Setting ACL for awgram on /root/awg)..."
setfacl -m u:awgram:x /root 2>/dev/null || true
setfacl -m u:awgram:x /root/awg 2>/dev/null || true
setfacl -m u:awgram:rx /root/awg/manage_amneziawg.sh 2>/dev/null || true

if ! sudo -u awgram ls /root/awg/manage_amneziawg.sh &>/dev/null; then
    warn "awgram не видит файл. Пробуем ещё раз... (awgram cannot see the file. Trying again...)"
    setfacl -m u:awgram:x /root 2>/dev/null || true
    setfacl -m u:awgram:x /root/awg 2>/dev/null || true
    setfacl -m u:awgram:rx /root/awg/manage_amneziawg.sh 2>/dev/null || true
fi

info "Запускаем awgram (Starting awgram)..."
run systemctl start awgram
sleep 2
if systemctl is-active --quiet awgram; then
    ok "awgram запущен (awgram is running)."
else
    warn "awgram не запустился (awgram failed to start). Проверь (Check): systemctl status awgram"
fi

# ================= 9. CRON ДЛЯ ACL =================
step "9. Cron для ACL (Cron for ACL)"
info "Настройка cron для автоматической выдачи прав (Setting up cron for automatic ACL)..."
echo "*/1 * * * * root bash -c 'for f in /root/awg/*.conf /root/awg/*.png /root/awg/*.vpnuri; do setfacl -m u:awgram:rx \"\$f\" 2>/dev/null; done'" > /etc/cron.d/awgram-acl
bash -c 'for f in /root/awg/*.conf /root/awg/*.png /root/awg/*.vpnuri; do setfacl -m u:awgram:rx "$f"; done' 2>/dev/null || true
ok "Cron настроен (Cron configured)."

# ================= 10. WHITEVPN =================
step "10. WhiteVPN"
if [ ! -d /opt/block-traffic ]; then
    info "Установка WhiteVPN без бота (Installing WhiteVPN without bot)..."
    run curl -fsSL https://raw.githubusercontent.com/anten-ka/whitevpn/main/install.sh -o /tmp/whitevpn-install.sh
    bash /tmp/whitevpn-install.sh <<< "n"
    ok "WhiteVPN установлен (WhiteVPN installed)."
else
    info "WhiteVPN уже установлен (WhiteVPN already installed)."
fi

# Принудительный запуск whitevpn-firewall после установки
info "Запуск whitevpn-firewall (Starting whitevpn-firewall)..."
systemctl start whitevpn-firewall 2>/dev/null || true
systemctl status whitevpn-firewall --no-pager | head -5

# ================= 11. ПРОВЕРКА =================
step "11. Проверка (Verification)"
info "Статус AmneziaWG (AmneziaWG status):"
systemctl status awg-quick@awg0 --no-pager | head -5
info "Статус awgram (awgram status):"
systemctl status awgram --no-pager | head -5
info "Проверка NAT (NAT check):"
iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE || warn "NAT не найден (NAT not found)!"
info "Проверка whitevpn (whitevpn check):"
sudo ipset list blocked_ips 2>/dev/null | grep "Number of entries" || warn "ipset blocked_ips пуст или не создан (empty or not created)"

# ================= 12. ОТКЛЮЧЕНИЕ ROOT (В САМОМ КОНЦЕ) =================
step "12. Отключение root по SSH (Disabling root via SSH)"
info "Проверка, что пользователь $NEW_USER может зайти по SSH (Checking that $NEW_USER can log in via SSH)..."

if id "$NEW_USER" &>/dev/null && [ -d "/home/$NEW_USER" ]; then
    if ss -tulpn | grep -q ":$SSH_PORT"; then
        info "Порт $SSH_PORT слушается. Отключаем root... (Port $SSH_PORT is listening. Disabling root...)"
        sed -i "s/^#*PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
        run systemctl restart ssh
        ok "Root по SSH отключён (Root via SSH disabled)."
    else
        warn "Порт $SSH_PORT не слушается. Root оставлен включённым для безопасности. (Port $SSH_PORT is not listening. Root left enabled for safety.)"
    fi
else
    warn "Пользователь $NEW_USER не найден или его домашняя папка отсутствует. Root оставлен включённым. (User $NEW_USER not found or home directory missing. Root left enabled.)"
fi

# ================= 13. ВЫВОД QR-КОДА ПЕРВОГО КЛИЕНТА =================
step "13. Первый клиент (First client, QR code)"
# Ищем первый .conf файл в /root/awg/
FIRST_CONF=$(ls /root/awg/*.conf 2>/dev/null | head -n 1)
if [[ -n "$FIRST_CONF" ]]; then
    CLIENT_NAME=$(basename "$FIRST_CONF" .conf)
    info "Найден конфиг первого клиента (Found first client config): $CLIENT_NAME"
    info "Отсканируй QR-код в приложении Amnezia (Scan QR code in Amnezia app):"
    echo ""
    # Генерируем QR-код из .conf файла
    qrencode -t ansiutf8 -m 1 -s 1 < "$FIRST_CONF" || warn "Не удалось сгенерировать QR-код (Failed to generate QR code)"
    echo ""
    info "Файл конфига (Config file): $FIRST_CONF"
    info "Путь на сервере (Path on server): /root/awg/$CLIENT_NAME.conf"
else
    warn "Не найдено ни одного .conf файла в /root/awg/. Создай клиента через бота или manage_amneziawg.sh add <имя> (No .conf file found. Create a client via bot or manage_amneziawg.sh add <name>)"
fi

echo -e "\n${GREEN}==================================================${NC}"
echo -e "${GREEN}   ✅ РАЗВЕРТЫВАНИЕ ЗАВЕРШЕНО! (DEPLOYMENT COMPLETE!) ${NC}"
echo -e "${GREEN}==================================================${NC}"
echo -e "Сервер готов к работе (Server is ready)."
echo -e ""
echo -e "Для входа по SSH используй (For SSH login use):"
echo -e "  ${CYAN}ssh -p $SSH_PORT $NEW_USER@$(hostname -I | awk '{print $1}')${NC}"
echo -e ""
echo -e "Root по SSH отключён (Root via SSH disabled)."
echo -e "${GREEN}==================================================${NC}"
