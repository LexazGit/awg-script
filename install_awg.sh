#!/bin/bash
# =============================================================================
# AWG Server Auto-Install Script
# wg-easy v15 + AmneziaWG kernel module on Ubuntu 22.04
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[!]${NC} $1"; exit 1; }

# --- Проверка root ---
if [ "$EUID" -ne 0 ]; then
  error "Запустите скрипт от root: sudo bash install_awg.sh"
fi

# --- Проверка необходимости перезагрузки ---
if [ -f /var/run/reboot-required ]; then
  error "Система требует перезагрузки после обновления ядра. Выполните reboot и запустите скрипт повторно."
fi

# --- Проверка версии Ubuntu ---
. /etc/os-release
if [ "$VERSION_ID" == "22.04" ]; then
  : # всё хорошо, продолжаем
elif [ "$(echo "$VERSION_ID >= 22.04" | awk '{print ($1 >= $3)}')" == "1" ]; then
  warn "Скрипт тестировался только на Ubuntu 22.04. Ubuntu 24.04 официально поддерживается Amnezia, но скриптом не проверялось."
  read -p "Продолжить? (y/n): " -n 1 -r; echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
else
  echo -e "${RED}[!]${NC} ВНИМАНИЕ: Ubuntu $VERSION_ID скорее всего не поддерживается — AWG kernel module может не собраться. Рекомендуется Ubuntu 22.04."
  read -p "Всё равно продолжить? (y/n): " -n 1 -r; echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# --- Параметры ---
SERVER_IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
read -p "IP сервера [$SERVER_IP]: " input_ip
SERVER_IP="${input_ip:-$SERVER_IP}"

read -p "Порт AWG клиентов [8443]: " AWG_PORT
AWG_PORT="${AWG_PORT:-8443}"

read -p "Порт веб-панели [5000]: " UI_PORT
UI_PORT="${UI_PORT:-5000}"

echo ""
log "Настройки: IP=$SERVER_IP, AWG_PORT=$AWG_PORT, UI_PORT=$UI_PORT"
echo ""

# --- Обновление системы ---
log "Обновление системы..."
DEBIAN_FRONTEND=noninteractive apt update -q
DEBIAN_FRONTEND=noninteractive apt upgrade -y -q \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

# --- AWG kernel module ---
log "Установка AWG kernel module..."
apt install -y software-properties-common python3-launchpadlib gnupg2 linux-headers-$(uname -r)
add-apt-repository -y ppa:amnezia/ppa
apt install -y amneziawg

log "Загрузка модуля..."
modprobe amneziawg
if ! grep -q "amneziawg" /etc/modules; then
  echo "amneziawg" >> /etc/modules
fi

# Проверка модуля
if ! lsmod | grep -q amneziawg; then
  error "Модуль amneziawg не загружен. Проверьте совместимость ядра: $(uname -r)"
fi
log "Модуль amneziawg загружен успешно"

# --- Docker ---
log "Установка Docker..."
curl -fsSL https://get.docker.com | sh
log "Docker $(docker --version) установлен"

# --- Сетевые настройки ---
log "Настройка IP forwarding и отключение IPv6..."
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
sysctl -p > /dev/null

# --- Создание директории ---
log "Создание директории /opt/awg-easy..."
mkdir -p /opt/awg-easy
cd /opt/awg-easy

# --- docker-compose.yml ---
log "Создание docker-compose.yml..."
cat > docker-compose.yml << EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    environment:
      - INSECURE=true
      - WG_HOST=${SERVER_IP}
      - WG_IPV6_ENABLED=false
      - EXPERIMENTAL_AWG=true
      - OVERRIDE_AUTO_AWG=awg
    volumes:
      - ./data:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "${AWG_PORT}:8443/udp"
      - "${UI_PORT}:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - /dev/net/tun:/dev/net/tun
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
EOF

# --- Запуск контейнера ---
log "Запуск wg-easy..."
docker compose up -d

# Ждём запуска
sleep 5
if ! docker ps | grep -q wg-easy; then
  error "Контейнер не запустился. Проверьте: docker logs wg-easy"
fi

# --- Фаервол ---
log "Настройка iptables (открываем порты)..."

iptables -I INPUT -p udp --dport ${AWG_PORT} -j ACCEPT
iptables -I INPUT -p tcp --dport ${UI_PORT} -j ACCEPT

# Сохранение правил
apt install -y iptables-persistent
iptables-save > /etc/iptables/rules.v4
log "Правила iptables сохранены"

# --- Готово ---
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  AWG сервер установлен успешно!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  Веб-панель: ${YELLOW}http://${SERVER_IP}:${UI_PORT}${NC}"
echo -e "  AWG порт:   ${YELLOW}${AWG_PORT}/udp${NC}"
echo ""
echo -e "  При первом входе выберите 'Начать с нуля'"
echo -e "  и задайте пароль администратора."
echo ""
echo -e "  В панели настрой хуки (Админ-панель → Хуки):"
echo -e "  ${YELLOW}PostUp:${NC}"
echo -e "  iptables -t nat -A POSTROUTING -s {{ipv4Cidr}} -o {{device}} -j MASQUERADE; iptables -A INPUT -p udp -m udp --dport {{port}} -j ACCEPT; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT;"
echo ""
echo -e "  ${YELLOW}PostDown:${NC}"
echo -e "  iptables -t nat -D POSTROUTING -s {{ipv4Cidr}} -o {{device}} -j MASQUERADE; iptables -D INPUT -p udp -m udp --dport {{port}} -j ACCEPT; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT;"
echo ""
warn "Не забудьте настроить параметры обфускации AWG в панели!"
echo ""
