#!/bin/bash

# Пошаговый запуск MTProto proxy с Fake TLS, принудительной IPv4 в ссылке и опцией кастомного MTU

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONFIG_FILE="${HOME}/mtproto_config.txt"
CONTAINER_NAME="mtproto-proxy"

echo "🚀 MTProto (fake TLS)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# helper: prompt with default
prompt_default() {
  local prompt_text="$1"
  local default="$2"
  read -p "${prompt_text} [${default}]: " input
  if [ -z "$input" ]; then
    echo "$default"
  else
    echo "$input"
  fi
}

# Загружаем существующую конфигурацию, если есть
OLD_SECRET=""
OLD_DOMAIN=""
OLD_PORT=""
OLD_MTU=""
if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}" 2>/dev/null || true
  OLD_SECRET="${SECRET:-}"
  OLD_DOMAIN="${DOMAIN:-}"
  OLD_PORT="${PORT:-}"
  OLD_MTU="${MTU:-}"
  echo -e "Найдена сохранённая конфигурация: ${YELLOW}${CONFIG_FILE}${NC}"
fi

# 1) Порт
DEFAULT_PORT="${OLD_PORT:-443}"
PORT=$(prompt_default "Введите порт для прокси (443, 8443 и т.д.)" "${DEFAULT_PORT}")

# 2) Fake domain
DEFAULT_DOMAIN="${OLD_DOMAIN:-ya.ru}"
FAKE_DOMAIN=$(prompt_default "Введите Fake TLS домен (под который маскируем трафик)" "${DEFAULT_DOMAIN}")

# 3) Использовать старый секрет?
USE_OLD="n"
if [ -n "${OLD_SECRET}" ]; then
  read -p "Использовать сохранённый секрет из ${CONFIG_FILE}? (y/N): " yn
  USE_OLD=$(echo "${yn:-n}" | tr '[:upper:]' '[:lower:]')
fi

# 4) Если не использовать старый, спросим сохранять ли новый
SAVE_CONF_DEFAULT="y"
if [ "${USE_OLD}" = "y" ]; then
  SECRET="${OLD_SECRET}"
  echo -e "Использую сохранённый секрет: ${YELLOW}${SECRET}${NC}"
else
  read -p "Создать новый секрет? (Y/n): " create_new
  create_new=$(echo "${create_new:-y}" | tr '[:upper:]' '[:lower:]')
  if [ "${create_new}" = "n" ]; then
    # позволим ввести вручную, проверка длины/формата не строгая
    read -p "Введите секрет вручную (hex, префикс 'ee' для fake tls): " SECRET
  else
    # Генерация секрета: ee + hex(domain) + random hex до длины 30 (как в оригинале)
    DOMAIN_HEX=$(echo -n "${FAKE_DOMAIN}" | xxd -ps | tr -d '\n')
    DOMAIN_LEN=${#DOMAIN_HEX}
    NEEDED=$((30 - DOMAIN_LEN))
    if [ "${NEEDED}" -le 0 ]; then
      RANDOM_HEX=""
    else
      # Генерируем достаточно случайных hex символов
      RANDOM_HEX=$(openssl rand -hex $(((NEEDED+1)/2)) 2>/dev/null | cut -c1-${NEEDED})
    fi
    SECRET="ee${DOMAIN_HEX}${RANDOM_HEX}"
    echo -e "Сгенерирован секрет: ${YELLOW}${SECRET}${NC}"
  fi

  read -p "Сохранить эту конфигурацию в ${CONFIG_FILE}? (Y/n): " save_ans
  save_ans=$(echo "${save_ans:-y}" | tr '[:upper:]' '[:lower:]')
  if [ "${save_ans}" = "y" ]; then
    SAVE_CONF_DEFAULT="y"
  else
    SAVE_CONF_DEFAULT="n"
  fi
fi

# 5) Поддержка изменяемых размеров пакетов (MTU)
echo ""
echo "Опция: изменить MTU (влияет на размер пакетов/фрагментацию) для контейнера."
echo "Если Docker на вашей системе поддерживает опцию --opt com.docker.network.driver.mtu, скрипт создаст отдельную сеть с заданным MTU."
read -p "Хотите создать Docker-сеть с кастомным MTU? (y/N): " mtu_ans
mtu_ans=$(echo "${mtu_ans:-n}" | tr '[:upper:]' '[:lower:]')

USE_CUSTOM_MTU="n"
NET_NAME=""
MTU=""

if [ "${mtu_ans}" = "y" ]; then
  DEFAULT_MTU="${OLD_MTU:-1500}"
  MTU=$(prompt_default "Введите значение MTU (обычно 1400-1500)" "${DEFAULT_MTU}")
  # Простейшая валидация числа
  if ! [[ "${MTU}" =~ ^[0-9]+$ ]]; then
    echo -e "${YELLOW}Неверное значение MTU. Пропускаю создание сети с кастомным MTU.${NC}"
    MTU=""
  else
    NET_NAME="mtproto-net-${PORT}"
    echo "Создаём Docker bridge сеть ${NET_NAME} с MTU=${MTU} (если уже есть — пропустим создание)..."
    if sudo docker network inspect "${NET_NAME}" >/dev/null 2>&1; then
      echo "Сеть ${NET_NAME} уже существует — пропускаем создание."
    else
      if sudo docker network create --driver bridge --opt com.docker.network.driver.mtu="${MTU}" "${NET_NAME}"; then
        echo -e "${GREEN}Сеть создана: ${NET_NAME}${NC}"
        USE_CUSTOM_MTU="y"
      else
        echo -e "${YELLOW}Не удалось создать сеть с опцией MTU. Ваша версия Docker может не поддерживать эту опцию.${NC}"
        echo "Продолжим без кастомной сети (контейнер будет запущен в стандартной сети Docker)."
        NET_NAME=""
      fi
    fi
  fi
fi

# Проверка занят ли порт (IPv4)
echo -n "🔍 Проверка порта ${PORT} (только IPv4)... "
if ss -4 -tuln 2>/dev/null | grep -q ":${PORT} "; then
  echo -e "${YELLOW}порт занят${NC}"
  # Предложим альтернативы
  for alt_port in 8443 8444 8445 4430; do
    if ! ss -4 -tuln 2>/dev/null | grep -q ":${alt_port} "; then
      echo "Найден свободный порт: ${alt_port}"
      read -p "Использовать ${alt_port} вместо ${PORT}? (Y/n): " use_alt
      use_alt=$(echo "${use_alt:-y}" | tr '[:upper:]' '[:lower:]')
      if [ "${use_alt}" = "y" ]; then
        PORT="${alt_port}"
      fi
      break
    fi
  done
else
  echo -e "${GREEN}свободен${NC}"
fi

# Остановим и удалим старый контейнер (если есть)
echo -n "🛑 Остановка старого контейнера (${CONTAINER_NAME})... "
sudo docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
sudo docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
echo -e "${GREEN}готово${NC}"

# Запуск контейнера
echo -n "📦 Запуск контейнера telegrammessenger/proxy... "

DOCKER_RUN_CMD=(sudo docker run -d --name "${CONTAINER_NAME}" --restart unless-stopped)

# Если создали сеть с MTU, подключаем её
if [ -n "${NET_NAME}" ]; then
  DOCKER_RUN_CMD+=(--network "${NET_NAME}")
fi

# Проброс порта (host:${PORT} -> container:443)
DOCKER_RUN_CMD+=(-p "${PORT}":443 -e "SECRET=${SECRET}" telegrammessenger/proxy)

# Выполняем команду
if "${DOCKER_RUN_CMD[@]}" >/dev/null 2>&1; then
  sleep 2
  if sudo docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" --format '{{.Names}}' | grep -q "${CONTAINER_NAME}"; then
    # Принудительно получаем внешний IPv4 адрес (curl -4)
    SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s ipinfo.io/ip || true)
    if [ -z "${SERVER_IP}" ]; then
      echo -e "\n${YELLOW}Не удалось определить внешний IPv4 адрес автоматически.${NC}"
      read -p "Введите IPv4 адрес/домен, который будет в tg:// ссылке (например 1.2.3.4): " SERVER_IP
    fi

    echo -e "\n${GREEN}✅ УСПЕШНО${NC}"
    echo ""
    echo "📊 ИНФОРМАЦИЯ ДЛЯ ПОДКЛЮЧЕНИЯ:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🌐 Сервер (IPv4): ${SERVER_IP}"
    echo "🔌 Порт: ${PORT}"
    echo "🔑 Секрет: ${SECRET}"
    echo "🌐 Fake TLS домен: ${FAKE_DOMAIN}"
    if [ -n "${MTU}" ]; then
      echo "⚙️ MTU (Docker сеть): ${MTU} (сеть: ${NET_NAME})"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔗 Ссылка для Telegram:"
    echo -e "${GREEN}tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Сохраняем конфигурацию по желанию
    if [ "${SAVE_CONF_DEFAULT}" = "y" ] || [ "${USE_OLD}" = "y" ]; then
      cat > "${CONFIG_FILE}" <<EOF
SERVER=${SERVER_IP}
PORT=${PORT}
SECRET=${SECRET}
DOMAIN=${FAKE_DOMAIN}
LINK=tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}
MTU=${MTU}
EOF
      echo "✅ Конфигурация сохранена в ${CONFIG_FILE}"
    fi

    echo ""
    echo "📋 Последние логи контейнера (5 строк):"
    sudo docker logs --tail 5 "${CONTAINER_NAME}" || true
  else
    echo -e "\n${RED}❌ Контейнер не запущен, проверьте логи.${NC}"
    sudo docker logs "${CONTAINER_NAME}" || true
  fi
else
  echo -e "\n${RED}❌ Ошибка при запуске контейнера.${NC}"
  echo "Попробуйте запустить вручную команду, которую скрипт пытался выполнить."
fi