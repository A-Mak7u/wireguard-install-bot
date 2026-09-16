#!/bin/bash

# Установщик WireGuard-сервера с Telegram-ботом для управления ключами.
# https://github.com/A-Mak7u/wireguard-install-bot
#
# Основан на https://github.com/angristan/wireguard-install (MIT, © 2019 angristan).
#
# Без аргументов — установка, а если WireGuard уже стоит, меню управления.
# Команды (WireGuard уже должен быть установлен):
#   wireguard-install.sh add <имя>      добавить клиента, печатает путь к конфигу
#   wireguard-install.sh list           список клиентов, по одному в строке
#   wireguard-install.sh revoke <имя>   удалить клиента
#   wireguard-install.sh bot            установить или перенастроить Telegram-бота
#
# Установка без вопросов: AUTO_INSTALL=y, ответы — переменными окружения
# (SERVER_PUB_IP, SERVER_PORT, CLIENT_NAME, INSTALL_BOT, BOT_TOKEN, BOT_ADMIN_IDS и т. д.).

REPO_URL="https://github.com/A-Mak7u/wireguard-install-bot"
REPO_RAW_URL="https://raw.githubusercontent.com/A-Mak7u/wireguard-install-bot/main"
TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"
BOT_DIR="/opt/wg-bot"
BOT_ENV_FILE="/etc/wg-bot/bot.env"
BOT_SERVICE="wg-bot"

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# Какие вопросы уже задавали в режиме AUTO_INSTALL — чтобы не зациклиться на неверном значении
declare -A ASKED

function installPackages() {
	if ! "$@"; then
		echo -e "${RED}Не удалось установить пакеты.${NC}"
		echo "Проверь подключение к интернету и источники пакетов."
		exit 1
	fi
}

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "Скрипт нужно запускать от root (например, через sudo)"
		exit 1
	fi
}

function checkVirt() {
	if command -v virt-what &>/dev/null; then
		VIRT=$(virt-what)
	else
		VIRT=$(systemd-detect-virt)
	fi
	if [[ ${VIRT} == "openvz" ]]; then
		echo "OpenVZ не поддерживается"
		exit 1
	fi
	if [[ ${VIRT} == "lxc" ]]; then
		echo "LXC пока не поддерживается."
		echo "Технически WireGuard может работать в LXC-контейнере,"
		echo "но модуль ядра нужно ставить на хост, контейнер запускать"
		echo "с особыми параметрами, а внутрь ставить только утилиты."
		exit 1
	fi
}

function checkOS() {
	source /etc/os-release
	OS="${ID}"
	if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
		if [[ ${VERSION_ID} -lt 10 ]]; then
			echo "Debian ${VERSION_ID} не поддерживается. Нужен Debian 10 Buster или новее"
			exit 1
		fi
		OS=debian # raspbian считаем debian
	elif [[ ${OS} == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 18 ]]; then
			echo "Ubuntu ${VERSION_ID} не поддерживается. Нужна Ubuntu 18.04 или новее"
			exit 1
		fi
	elif [[ ${OS} == "fedora" ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			echo "Fedora ${VERSION_ID} не поддерживается. Нужна Fedora 32 или новее"
			exit 1
		fi
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 7* ]]; then
			echo "CentOS ${VERSION_ID} не поддерживается. Нужен CentOS 8 или новее"
			exit 1
		fi
	elif [[ -e /etc/oracle-release ]]; then
		source /etc/os-release
		OS=oracle
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	elif [[ -e /etc/alpine-release ]]; then
		OS=alpine
		if ! command -v virt-what &>/dev/null; then
			if ! (apk update && apk add virt-what); then
				echo -e "${RED}Не удалось поставить virt-what. Продолжаю без проверки виртуализации.${NC}"
			fi
		fi
	else
		echo "Похоже, это не Debian, Ubuntu, Fedora, CentOS, AlmaLinux, Oracle, Arch или Alpine Linux — такие системы не поддерживаются"
		exit 1
	fi
}

function getHomeDirForClient() {
	local CLIENT_NAME=$1

	if [ -z "${CLIENT_NAME}" ]; then
		echo "Ошибка: getHomeDirForClient() нужно передать имя клиента"
		exit 1
	fi

	# Домашняя папка, куда запишем конфиг клиента
	if [ -e "/home/${CLIENT_NAME}" ]; then
		# если имя клиента совпадает с именем пользователя
		HOME_DIR="/home/${CLIENT_NAME}"
	elif [ "${SUDO_USER}" ]; then
		# иначе — папка того, кто запустил sudo
		if [ "${SUDO_USER}" == "root" ]; then
			HOME_DIR="/root"
		else
			HOME_DIR="/home/${SUDO_USER}"
		fi
	else
		# без sudo — /root
		HOME_DIR="/root"
	fi

	echo "$HOME_DIR"
}

function initialCheck() {
	isRoot
	checkOS
	checkVirt
}

# ask <переменная> <вопрос> [значение по умолчанию]
# При AUTO_INSTALL=y не спрашивает: оставляет заданное значение или берёт умолчание.
function ask() {
	local var=$1 prompt=$2 default=$3

	if [[ ${AUTO_INSTALL} != "y" ]]; then
		# shellcheck disable=SC2229 # читаем в переменную, чьё имя передали
		read -rp "${prompt}" -e -i "${default}" "${var}"
		return
	fi

	if [[ -n ${ASKED[${var}]} ]]; then
		echo -e "${RED}Некорректное значение ${var}=${!var}${NC}" >&2
		exit 1
	fi
	ASKED[${var}]=1
	if [[ -z ${!var} ]]; then
		printf -v "${var}" '%s' "${default}"
	fi
	echo "${prompt}${!var}"
}

function detectPublicIP() {
	local ip external

	ip=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	# На интерфейсе нет адреса или он серый (сервер за NAT) — спрашиваем внешний адрес
	if [[ -z ${ip} || ${ip} =~ ^10\. || ${ip} =~ ^172\.(1[6-9]|2[0-9]|3[01])\. || ${ip} =~ ^192\.168\. ]]; then
		external=$(curl -4 -fsS -m 5 https://api.ipify.org 2>/dev/null)
		if [[ ${external} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
			ip=${external}
		fi
	fi
	if [[ -z ${ip} ]]; then
		ip=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	fi
	echo "${ip}"
}

function installQuestions() {
	echo "Установщик WireGuard"
	echo "Репозиторий: ${REPO_URL}"
	echo ""
	echo "Сначала несколько вопросов."
	echo "Если не уверен — просто жми Enter, значения по умолчанию подходят."
	echo ""

	ask SERVER_PUB_IP "Публичный IPv4 или IPv6 адрес сервера: " "$(detectPublicIP)"

	SERVER_NIC="$(ip -4 route ls | grep default | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1)"
	until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_.-]+$ ]]; do
		ask SERVER_PUB_NIC "Внешний сетевой интерфейс: " "${SERVER_NIC}"
	done

	until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
		ask SERVER_WG_NIC "Имя интерфейса WireGuard: " wg0
	done

	until [[ ${SERVER_WG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
		ask SERVER_WG_IPV4 "IPv4 сервера внутри VPN: " 10.66.66.1
	done

	until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
		ask SERVER_WG_IPV6 "IPv6 сервера внутри VPN: " fd42:42:42::1
	done

	# Случайный порт из диапазона динамических портов
	RANDOM_PORT=$(shuf -i49152-65535 -n1)
	until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
		ask SERVER_PORT "Порт WireGuard [1-65535]: " "${RANDOM_PORT}"
	done

	# По умолчанию DNS Cloudflare
	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		ask CLIENT_DNS_1 "Первый DNS-сервер для клиентов: " 1.1.1.1
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		ask CLIENT_DNS_2 "Второй DNS-сервер для клиентов (можно оставить пустым): " 1.0.0.1
		if [[ ${CLIENT_DNS_2} == "" ]]; then
			CLIENT_DNS_2="${CLIENT_DNS_1}"
		fi
	done

	until [[ ${ALLOWED_IPS} =~ ^.+$ ]]; do
		echo -e "\nПараметр AllowedIPs определяет, какой трафик клиента пойдёт через VPN."
		ask ALLOWED_IPS "AllowedIPs для новых клиентов (по умолчанию — весь трафик): " '0.0.0.0/0,::/0'
		if [[ ${ALLOWED_IPS} == "" ]]; then
			ALLOWED_IPS="0.0.0.0/0,::/0"
		fi
	done

	echo ""
	echo "Вопросы закончились, можно ставить WireGuard."
	echo "В конце установки создадим первого клиента."
	if [[ ${AUTO_INSTALL} != "y" ]]; then
		read -n1 -r -p "Нажми любую клавишу, чтобы продолжить..."
	fi
}

function installWireGuard() {
	# Сначала вопросы
	installQuestions

	# Ставим утилиты и модуль WireGuard
	if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' && ${VERSION_ID} -gt 10 ]]; then
		apt-get update
		installPackages apt-get install -y wireguard iptables resolvconf qrencode
	elif [[ ${OS} == 'debian' ]]; then
		if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
			echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
			apt-get update
		fi
		apt-get update
		installPackages apt-get install -y iptables resolvconf qrencode
		installPackages apt-get install -y -t buster-backports wireguard
	elif [[ ${OS} == 'fedora' ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			installPackages dnf install -y dnf-plugins-core
			dnf copr enable -y jdoss/wireguard
			installPackages dnf install -y wireguard-dkms
		fi
		installPackages dnf install -y wireguard-tools iptables qrencode
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 8* ]]; then
			installPackages yum install -y epel-release elrepo-release
			installPackages yum install -y kmod-wireguard
			yum install -y qrencode || true # в 9-й версии qrencode нет
		fi
		installPackages yum install -y wireguard-tools iptables
	elif [[ ${OS} == 'oracle' ]]; then
		installPackages dnf install -y oraclelinux-developer-release-el8
		dnf config-manager --disable -y ol8_developer
		dnf config-manager --enable -y ol8_developer_UEKR6
		dnf config-manager --save -y --setopt=ol8_developer_UEKR6.includepkgs='wireguard-tools*'
		installPackages dnf install -y wireguard-tools qrencode iptables
	elif [[ ${OS} == 'arch' ]]; then
		installPackages pacman -S --needed --noconfirm wireguard-tools qrencode
	elif [[ ${OS} == 'alpine' ]]; then
		apk update
		installPackages apk add wireguard-tools iptables libqrencode-tools
	fi

	# Проверяем, что WireGuard встал
	if ! command -v wg &>/dev/null; then
		echo -e "${RED}WireGuard не установился: команда wg не найдена.${NC}"
		echo "Посмотри ошибки установки выше."
		exit 1
	fi

	# Папки может не быть (например, на Fedora)
	mkdir /etc/wireguard >/dev/null 2>&1

	chmod 600 -R /etc/wireguard/

	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	# Сохраняем настройки
	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}" >/etc/wireguard/params

	# Интерфейс сервера
	echo "[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}" >"/etc/wireguard/${SERVER_WG_NIC}.conf"

	if pgrep firewalld; then
		FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_WG_IPV4}" | cut -d"." -f1-3)".0"
		FIREWALLD_IPV6_ADDRESS=$(echo "${SERVER_WG_IPV6}" | sed 's/:[^:]*$/:0/')
		echo "PostUp = firewall-cmd --zone=public --add-interface=${SERVER_WG_NIC} && firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --add-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --zone=public --remove-interface=${SERVER_WG_NIC} && firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --remove-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	else
		echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostUp = ip6tables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	fi

	# Включаем маршрутизацию
	echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/wg.conf

	if [[ ${OS} == 'alpine' ]]; then
		sysctl -p /etc/sysctl.d/wg.conf
		rc-update add sysctl
		ln -s /etc/init.d/wg-quick "/etc/init.d/wg-quick.${SERVER_WG_NIC}"
		rc-service "wg-quick.${SERVER_WG_NIC}" start
		rc-update add "wg-quick.${SERVER_WG_NIC}"
	else
		sysctl --system

		systemctl start "wg-quick@${SERVER_WG_NIC}"
		systemctl enable "wg-quick@${SERVER_WG_NIC}"
	fi

	newClient
	echo -e "${GREEN}Чтобы добавить ещё клиентов, просто запусти скрипт ещё раз.${NC}"

	# Работает ли WireGuard
	if [[ ${OS} == 'alpine' ]]; then
		rc-service --quiet "wg-quick.${SERVER_WG_NIC}" status
	else
		systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
	fi
	WG_RUNNING=$?

	# После обновления ядра WireGuard может не подняться до перезагрузки
	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}ВНИМАНИЕ: похоже, WireGuard не запущен.${NC}"
		if [[ ${OS} == 'alpine' ]]; then
			echo -e "${ORANGE}Проверить можно командой: rc-service wg-quick.${SERVER_WG_NIC} status${NC}"
		else
			echo -e "${ORANGE}Проверить можно командой: systemctl status wg-quick@${SERVER_WG_NIC}${NC}"
		fi
		echo -e "${ORANGE}Если там что-то вроде \"Cannot find device ${SERVER_WG_NIC}\" — перезагрузи сервер!${NC}"
	else # WireGuard работает
		echo -e "\n${GREEN}WireGuard работает.${NC}"
		if [[ ${OS} == 'alpine' ]]; then
			echo -e "${GREEN}Статус: rc-service wg-quick.${SERVER_WG_NIC} status\n\n${NC}"
		else
			echo -e "${GREEN}Статус: systemctl status wg-quick@${SERVER_WG_NIC}\n\n${NC}"
		fi
		echo -e "${ORANGE}Если у клиента нет интернета через VPN, попробуй перезагрузить сервер.${NC}"
	fi

	if [[ ${OS} == 'alpine' ]]; then
		return
	fi
	echo ""
	until [[ ${INSTALL_BOT,,} =~ ^[yn]$ ]]; do
		ask INSTALL_BOT "Установить Telegram-бота, чтобы выдавать и удалять ключи прямо из Telegram? [y/n]: " y
	done
	if [[ ${INSTALL_BOT,,} == "y" ]]; then
		installBot
	fi
}

function isValidClientName() {
	[[ $1 =~ ^[a-zA-Z0-9_-]+$ && ${#1} -lt 16 ]]
}

function clientExists() {
	grep -qxF "### Client $1" "/etc/wireguard/${SERVER_WG_NIC}.conf"
}

# ipTaken <адрес/маска> — есть ли в конфиге ровно такой адрес (а не, скажем, .25 при поиске .2)
function ipTaken() {
	grep -qE "(^|[[:space:]=,])${1//./\\.}([[:space:],]|$)" "/etc/wireguard/${SERVER_WG_NIC}.conf"
}

function newClient() {
	# IPv6-адрес в Endpoint берём в квадратные скобки
	if [[ ${SERVER_PUB_IP} =~ .*:.* ]]; then
		if [[ ${SERVER_PUB_IP} != *"["* ]] || [[ ${SERVER_PUB_IP} != *"]"* ]]; then
			SERVER_PUB_IP="[${SERVER_PUB_IP}]"
		fi
	fi
	ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

	if [[ -n ${NONINTERACTIVE} ]]; then
		if ! isValidClientName "${CLIENT_NAME}"; then
			echo "Некорректное имя «${CLIENT_NAME}»: только латиница, цифры, _ и -, не длиннее 15 символов." >&2
			exit 1
		fi
		if clientExists "${CLIENT_NAME}"; then
			echo "Клиент «${CLIENT_NAME}» уже существует." >&2
			exit 1
		fi
	else
		echo ""
		echo "Новый клиент"
		echo ""
		echo "Имя клиента: латиница, цифры, _ и -, не длиннее 15 символов."

		local default_name=""
		if [[ ${AUTO_INSTALL} == "y" ]]; then
			default_name="client"
		fi
		until isValidClientName "${CLIENT_NAME}" && ! clientExists "${CLIENT_NAME}"; do
			if [[ -n ${CLIENT_NAME} ]] && clientExists "${CLIENT_NAME}"; then
				echo ""
				echo -e "${ORANGE}Клиент «${CLIENT_NAME}» уже есть, выбери другое имя.${NC}"
				echo ""
			fi
			ask CLIENT_NAME "Имя клиента: " "${default_name}"
		done
	fi

	# Первый свободный адрес в подсети
	BASE_IP=$(echo "$SERVER_WG_IPV4" | awk -F '.' '{ print $1"."$2"."$3 }')
	BASE_IPV6=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
	DOT_IP=""
	for i in {2..254}; do
		if [[ "${BASE_IP}.${i}" != "${SERVER_WG_IPV4}" ]] && ! ipTaken "${BASE_IP}.${i}/32"; then
			DOT_IP=${i}
			break
		fi
	done

	if [[ -z ${DOT_IP} ]]; then
		echo ""
		echo "В подсети закончились адреса: в ней помещается только 253 клиента." >&2
		exit 1
	fi

	if [[ -n ${NONINTERACTIVE} ]]; then
		CLIENT_WG_IPV4="${BASE_IP}.${DOT_IP}"
		CLIENT_WG_IPV6="${BASE_IPV6}::${DOT_IP}"
		if ipTaken "${CLIENT_WG_IPV6}/128"; then
			echo "IPv6-адрес ${CLIENT_WG_IPV6} уже занят другим клиентом." >&2
			exit 1
		fi
	else
		local ipv4_ok="" ipv6_ok=""
		CLIENT_DOT_IPV4=""
		until [[ -n ${ipv4_ok} ]]; do
			ask CLIENT_DOT_IPV4 "IPv4 клиента внутри VPN: ${BASE_IP}." "${DOT_IP}"
			CLIENT_WG_IPV4="${BASE_IP}.${CLIENT_DOT_IPV4}"
			if [[ ${CLIENT_DOT_IPV4} =~ ^[0-9]+$ ]] && ((CLIENT_DOT_IPV4 >= 1 && CLIENT_DOT_IPV4 <= 254)) &&
				[[ ${CLIENT_WG_IPV4} != "${SERVER_WG_IPV4}" ]] && ! ipTaken "${CLIENT_WG_IPV4}/32"; then
				ipv4_ok=1
			else
				echo ""
				echo -e "${ORANGE}Адрес ${CLIENT_WG_IPV4} занят или некорректен, выбери другой.${NC}"
				echo ""
			fi
		done

		CLIENT_DOT_IPV6=""
		until [[ -n ${ipv6_ok} ]]; do
			ask CLIENT_DOT_IPV6 "IPv6 клиента внутри VPN: ${BASE_IPV6}::" "${CLIENT_DOT_IPV4}"
			CLIENT_WG_IPV6="${BASE_IPV6}::${CLIENT_DOT_IPV6}"
			if [[ ${CLIENT_DOT_IPV6} =~ ^[0-9a-fA-F]{1,4}$ ]] && [[ ${CLIENT_WG_IPV6} != "${SERVER_WG_IPV6}" ]] &&
				! ipTaken "${CLIENT_WG_IPV6}/128"; then
				ipv6_ok=1
			else
				echo ""
				echo -e "${ORANGE}Адрес ${CLIENT_WG_IPV6} занят или некорректен, выбери другой.${NC}"
				echo ""
			fi
		done
	fi

	# Ключи клиента
	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	CLIENT_CONF="${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	# Конфиг клиента с сервером в роли пира. В нём приватный ключ — читать может только владелец
	(
		umask 077
		echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

# Раскомментируй строку ниже, чтобы задать свой MTU.
# Это может повлиять на скорость — меняй, только если понимаешь зачем.
# Подобрать MTU поможет https://github.com/nitred/nr-wg-mtu-finder
# MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" >"${CLIENT_CONF}"
	)

	# Клиент — пир на сервере
	echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

	if ! wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}"); then
		echo "Клиент записан в конфиг, но применить его на лету не вышло — перезапусти wg-quick@${SERVER_WG_NIC}." >&2
	fi

	if [[ -n ${NONINTERACTIVE} ]]; then
		echo "${CLIENT_CONF}"
		return
	fi

	# QR-код, если есть qrencode
	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nКонфиг клиента в виде QR-кода:\n${NC}"
		qrencode -t ansiutf8 -l L <"${CLIENT_CONF}"
		echo ""
	fi

	echo -e "${GREEN}Конфиг клиента: ${CLIENT_CONF}${NC}"
}

function listClients() {
	local conf="/etc/wireguard/${SERVER_WG_NIC}.conf"

	if [[ -n ${NONINTERACTIVE} ]]; then
		grep -E "^### Client " "${conf}" | cut -d ' ' -f 3
		return 0
	fi

	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${conf}")
	if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
		echo ""
		echo "Клиентов пока нет."
		exit 1
	fi

	grep -E "^### Client" "${conf}" | cut -d ' ' -f 3 | nl -s ') '
}

# Вырезает из конфига блок клиента: строку «### Client имя», его [Peer] и параметры —
# до пустой строки, следующего «### Client» или чужого [Peer], если пустую строку
# потеряли при ручной правке
function removeClientFromConf() {
	local conf="/etc/wireguard/${SERVER_WG_NIC}.conf" tmp

	tmp=$(mktemp "/etc/wireguard/.${SERVER_WG_NIC}.conf.XXXXXX") || exit 1
	awk -v name="$1" '
		$0 == "### Client " name { skip = 1; peer = 0; next }
		skip && /^[[:space:]]*$/ { skip = 0; next }
		skip && (/^### Client / || (/^\[Peer\]/ && peer)) { skip = 0 }
		skip { if (/^\[Peer\]/) peer = 1; next }
		{ print }
	' "${conf}" >"${tmp}" && cat "${tmp}" >"${conf}"
	rm -f "${tmp}"
}

function revokeClient() {
	local conf="/etc/wireguard/${SERVER_WG_NIC}.conf"

	if [[ -n ${NONINTERACTIVE} ]]; then
		if [[ -z ${CLIENT_NAME} ]] || ! clientExists "${CLIENT_NAME}"; then
			echo "Клиент «${CLIENT_NAME}» не найден." >&2
			exit 1
		fi
	else
		NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${conf}")
		if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
			echo ""
			echo "Клиентов пока нет."
			exit 1
		fi

		echo ""
		echo "Какого клиента удалить?"
		grep -E "^### Client" "${conf}" | cut -d ' ' -f 3 | nl -s ') '
		until [[ ${CLIENT_NUMBER} =~ ^[0-9]+$ ]] && [[ ${CLIENT_NUMBER} -ge 1 && ${CLIENT_NUMBER} -le ${NUMBER_OF_CLIENTS} ]]; do
			if [[ ${NUMBER_OF_CLIENTS} == '1' ]]; then
				read -rp "Выбери клиента [1]: " CLIENT_NUMBER
			else
				read -rp "Выбери клиента [1-${NUMBER_OF_CLIENTS}]: " CLIENT_NUMBER
			fi
		done

		# номер из списка -> имя клиента
		CLIENT_NAME=$(grep -E "^### Client" "${conf}" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)
	fi

	removeClientFromConf "${CLIENT_NAME}"

	# удаляем файл конфига клиента
	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	# применяем без перезапуска интерфейса
	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

	if [[ -z ${NONINTERACTIVE} ]]; then
		echo -e "${GREEN}Клиент ${CLIENT_NAME} удалён.${NC}"
	fi
}

function uninstallWg() {
	echo ""
	echo -e "\n${RED}ВНИМАНИЕ: WireGuard будет удалён вместе со всеми настройками и ключами!${NC}"
	echo -e "${ORANGE}Если они нужны — сначала сохрани папку /etc/wireguard.\n${NC}"
	read -rp "Точно удалить WireGuard? [y/n]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ $REMOVE == 'y' ]]; then
		checkOS

		if botInstalled; then
			uninstallBot
		fi

		if [[ ${OS} == 'alpine' ]]; then
			rc-service "wg-quick.${SERVER_WG_NIC}" stop
			rc-update del "wg-quick.${SERVER_WG_NIC}"
			unlink "/etc/init.d/wg-quick.${SERVER_WG_NIC}"
			rc-update del sysctl
		else
			systemctl stop "wg-quick@${SERVER_WG_NIC}"
			systemctl disable "wg-quick@${SERVER_WG_NIC}"
		fi

		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
			apt-get remove -y wireguard wireguard-tools qrencode
		elif [[ ${OS} == 'fedora' ]]; then
			dnf remove -y --noautoremove wireguard-tools qrencode
			if [[ ${VERSION_ID} -lt 32 ]]; then
				dnf remove -y --noautoremove wireguard-dkms
				dnf copr disable -y jdoss/wireguard
			fi
		elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
			yum remove -y --noautoremove wireguard-tools
			if [[ ${VERSION_ID} == 8* ]]; then
				yum remove --noautoremove kmod-wireguard qrencode
			fi
		elif [[ ${OS} == 'oracle' ]]; then
			yum remove --noautoremove wireguard-tools qrencode
		elif [[ ${OS} == 'arch' ]]; then
			pacman -Rs --noconfirm wireguard-tools qrencode
		elif [[ ${OS} == 'alpine' ]]; then
			(cd qrencode-4.1.1 || exit && make uninstall)
			rm -rf qrencode-* || exit
			apk del wireguard-tools libqrencode libqrencode-tools
		fi

		rm -rf /etc/wireguard
		rm -f /etc/sysctl.d/wg.conf

		if [[ ${OS} == 'alpine' ]]; then
			rc-service --quiet "wg-quick.${SERVER_WG_NIC}" status &>/dev/null
		else
			# Перечитываем sysctl
			sysctl --system

			# Проверяем, что WireGuard остановлен
			systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
		fi
		WG_RUNNING=$?

		if [[ ${WG_RUNNING} -eq 0 ]]; then
			echo "WireGuard удалился не полностью."
			exit 1
		else
			echo "WireGuard удалён."
			exit 0
		fi
	else
		echo ""
		echo "Удаление отменено."
	fi
}

# ========= Telegram-бот =========

function botInstalled() {
	[[ -f "/etc/systemd/system/${BOT_SERVICE}.service" ]]
}

# telegramApi <метод> — запрос к Bot API. Адрес с токеном отдаём curl через stdin,
# чтобы токен не светился в списке процессов
function telegramApi() {
	printf 'url = "%s/bot%s/%s"\n' "${TELEGRAM_API_URL}" "${BOT_TOKEN}" "$1" | curl -sS -m 15 -K - 2>/dev/null
}

# fetchRepoFile <путь в репозитории> <куда> — берёт файл рядом со скриптом (если репозиторий
# склонирован), иначе качает с GitHub. Кладёт через временный файл: скрипт может обновлять сам себя
function fetchRepoFile() {
	local path=$1 dest=$2 src_dir

	# При запуске через «bash <(curl ...)» рядом со скриптом ничего нет
	if [[ -f ${BASH_SOURCE[0]} ]]; then
		src_dir=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
	fi
	if [[ -n ${src_dir} && -f "${src_dir}/${path}" ]]; then
		if [[ $(readlink -f "${src_dir}/${path}") == $(readlink -f "${dest}") ]]; then
			return 0
		fi
		cp "${src_dir}/${path}" "${dest}.tmp"
	elif ! curl -fsSL "${REPO_RAW_URL}/${path}" -o "${dest}.tmp"; then
		rm -f "${dest}.tmp"
		echo -e "${RED}Не удалось скачать ${REPO_RAW_URL}/${path}${NC}"
		return 1
	fi
	mv -f "${dest}.tmp" "${dest}"
}

# Находит ID тех, кто написал боту. Печатает строки «ID<TAB>имя» или «error<TAB>описание»
function fetchBotUsers() {
	telegramApi getUpdates | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except ValueError:
    print("error\tнет связи с Telegram")
    sys.exit()
if not data.get("ok"):
    print("error\t" + str(data.get("description", "неизвестная ошибка")))
    sys.exit()
users = {}
for update in data["result"]:
    for key in ("message", "edited_message", "callback_query", "my_chat_member"):
        sender = (update.get(key) or {}).get("from")
        if sender and not sender.get("is_bot"):
            name = " ".join(filter(None, [sender.get("first_name"), sender.get("last_name")]))
            if sender.get("username"):
                name += " (@" + sender["username"] + ")"
            users[sender["id"]] = name
for user_id, name in users.items():
    print(str(user_id) + "\t" + name)
'
}

function detectAdminId() {
	local users count answer

	if [[ -z ${BOT_USERNAME} ]]; then
		echo -e "${ORANGE}Без связи с Telegram ID не определить — введи его вручную (узнать можно у @userinfobot).${NC}"
		return
	fi

	echo ""
	echo "Открой в Telegram бота @${BOT_USERNAME} и нажми «Старт» (или отправь ему любое сообщение)."
	read -rp "Как отправишь — вернись сюда и нажми Enter..."

	users=$(fetchBotUsers)
	if [[ ${users} == error* ]]; then
		echo -e "${ORANGE}Telegram ответил ошибкой: ${users#error$'\t'}${NC}"
		return
	fi
	count=$(grep -c . <<<"${users}")
	if [[ ${count} -eq 0 ]]; then
		echo -e "${ORANGE}Сообщений боту пока не видно. Попробуй ещё раз или введи ID вручную (узнать можно у @userinfobot).${NC}"
	elif [[ ${count} -eq 1 ]]; then
		answer=""
		until [[ ${answer,,} =~ ^[yn]$ ]]; do
			read -rp "Нашёл: ${users#*$'\t'}, ID ${users%%$'\t'*}. Это ты? [y/n]: " -e -i y answer
		done
		if [[ ${answer,,} == "y" ]]; then
			BOT_ADMIN_IDS=${users%%$'\t'*}
		fi
	else
		echo "Боту писали несколько человек:"
		while IFS=$'\t' read -r id name; do
			echo "   ${id} — ${name}"
		done <<<"${users}"
		echo "Введи свой ID (можно несколько через запятую)."
	fi
}

function installBot() {
	local old_token="" old_admins="" check

	if ! command -v systemctl &>/dev/null || [[ ${OS} == 'alpine' ]]; then
		echo -e "${RED}Бота можно поставить только на систему с systemd.${NC}"
		return 1
	fi

	echo ""
	echo "Telegram-бот для WireGuard"
	echo ""
	echo "Бот выдаёт новые ключи (файл и QR-код), удаляет их и показывает, кто сейчас"
	echo "подключён. Слушается только тех, чьи Telegram ID ты укажешь."
	echo ""

	echo "Ставлю Python..."
	if [[ ${OS} == 'ubuntu' || ${OS} == 'debian' ]]; then
		apt-get update
		installPackages apt-get install -y python3 python3-venv curl
	elif [[ ${OS} == 'fedora' || ${OS} == 'oracle' ]]; then
		installPackages dnf install -y python3
	elif [[ ${OS} == 'centos' || ${OS} == 'almalinux' || ${OS} == 'rocky' ]]; then
		installPackages yum install -y python3
	elif [[ ${OS} == 'arch' ]]; then
		installPackages pacman -S --needed --noconfirm python curl
	fi
	if ! command -v curl &>/dev/null; then
		echo -e "${RED}Нужен curl, а поставить его не вышло.${NC}"
		return 1
	fi
	if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null; then
		echo -e "${RED}Боту нужен Python 3.9 или новее, а в системе: $(python3 --version 2>&1).${NC}"
		return 1
	fi

	# При переустановке предлагаем прежние токен и ID, а старого бота останавливаем,
	# иначе он перехватит сообщения, по которым мы ищем ID
	if [[ -f ${BOT_ENV_FILE} ]]; then
		old_token=$(sed -n 's/^TELEGRAM_TOKEN=//p' "${BOT_ENV_FILE}")
		old_admins=$(sed -n 's/^ADMIN_IDS=//p' "${BOT_ENV_FILE}")
	fi
	systemctl stop "${BOT_SERVICE}" 2>/dev/null

	echo ""
	echo "1. Открой в Telegram @BotFather, отправь ему /newbot и придумай боту имя."
	echo "2. BotFather пришлёт токен вида 123456789:AAH... — вставь его сюда."
	echo ""
	BOT_USERNAME=""
	until [[ -n ${BOT_TOKEN_DONE} ]]; do
		if [[ ${AUTO_INSTALL} != "y" ]]; then
			read -rp "Токен бота: " -e -i "${old_token}" BOT_TOKEN
		fi
		BOT_TOKEN=$(tr -d '[:space:]' <<<"${BOT_TOKEN}")
		if ! [[ ${BOT_TOKEN} =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; then
			echo -e "${ORANGE}Это не похоже на токен — он выглядит как 123456789:AAH...${NC}"
			[[ ${AUTO_INSTALL} == "y" ]] && exit 1
			continue
		fi

		check=$(telegramApi getMe)
		if [[ -z ${check} ]]; then
			echo -e "${ORANGE}Не удалось связаться с api.telegram.org — проверить токен сейчас нельзя.${NC}"
			BOT_TOKEN_DONE=1
		else
			BOT_USERNAME=$(python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["result"]["username"] if d.get("ok") else "")' <<<"${check}" 2>/dev/null)
			if [[ -n ${BOT_USERNAME} ]]; then
				echo -e "${GREEN}Токен подошёл, бот: @${BOT_USERNAME}${NC}"
				BOT_TOKEN_DONE=1
			else
				echo -e "${ORANGE}Telegram не принял этот токен. Проверь, что скопировал его целиком.${NC}"
				[[ ${AUTO_INSTALL} == "y" ]] && exit 1
			fi
		fi
	done

	echo ""
	echo "Теперь твой Telegram ID — бот будет слушаться только его."
	echo "Можно несколько ID через запятую. Если не знаешь свой — оставь пустым, определю сам."
	until [[ ${BOT_ADMIN_IDS} =~ ^[0-9]+(,[0-9]+)*$ ]]; do
		if [[ ${AUTO_INSTALL} == "y" ]]; then
			echo -e "${RED}Некорректное значение BOT_ADMIN_IDS=${BOT_ADMIN_IDS}${NC}" >&2
			exit 1
		fi
		read -rp "Telegram ID: " -e -i "${old_admins}" BOT_ADMIN_IDS
		BOT_ADMIN_IDS=$(tr -d '[:space:]' <<<"${BOT_ADMIN_IDS}")
		old_admins=""
		if [[ -z ${BOT_ADMIN_IDS} ]]; then
			detectAdminId
		elif ! [[ ${BOT_ADMIN_IDS} =~ ^[0-9]+(,[0-9]+)*$ ]]; then
			echo -e "${ORANGE}ID — это только цифры, например 123456789.${NC}"
		fi
	done

	echo ""
	echo "Ставлю бота в ${BOT_DIR}..."
	mkdir -p "${BOT_DIR}/bot" /etc/wg-bot
	chmod 700 /etc/wg-bot
	fetchRepoFile wireguard-install.sh "${BOT_DIR}/wireguard-install.sh" || return 1
	fetchRepoFile bot/wg_bot.py "${BOT_DIR}/bot/wg_bot.py" || return 1
	fetchRepoFile bot/requirements.txt "${BOT_DIR}/bot/requirements.txt" || return 1
	chmod 700 "${BOT_DIR}/wireguard-install.sh"

	if [[ ! -x "${BOT_DIR}/venv/bin/python" ]] && ! python3 -m venv "${BOT_DIR}/venv"; then
		echo -e "${RED}Не удалось создать окружение Python в ${BOT_DIR}/venv${NC}"
		return 1
	fi
	if ! "${BOT_DIR}/venv/bin/pip" install -q --disable-pip-version-check -r "${BOT_DIR}/bot/requirements.txt"; then
		echo -e "${RED}Не удалось установить библиотеки для бота.${NC}"
		return 1
	fi

	(
		umask 077
		echo "TELEGRAM_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${BOT_ADMIN_IDS}
WG_SCRIPT=${BOT_DIR}/wireguard-install.sh" >"${BOT_ENV_FILE}"
		if [[ ${TELEGRAM_API_URL} != "https://api.telegram.org" ]]; then
			echo "TELEGRAM_API_URL=${TELEGRAM_API_URL}" >>"${BOT_ENV_FILE}"
		fi
	)

	echo "[Unit]
Description=WireGuard Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${BOT_ENV_FILE}
ExecStart=${BOT_DIR}/venv/bin/python ${BOT_DIR}/bot/wg_bot.py
Restart=always
RestartSec=5
# Код 2 — ошибка в настройках (например, неверный токен): перезапуск не поможет
RestartPreventExitStatus=2

[Install]
WantedBy=multi-user.target" >"/etc/systemd/system/${BOT_SERVICE}.service"

	systemctl daemon-reload
	systemctl enable "${BOT_SERVICE}" &>/dev/null
	systemctl restart "${BOT_SERVICE}"
	sleep 5

	if systemctl is-active --quiet "${BOT_SERVICE}"; then
		echo -e "${GREEN}Бот запущен.${NC}"
		if [[ -n ${BOT_USERNAME} ]]; then
			echo -e "${GREEN}Открой @${BOT_USERNAME} в Telegram и отправь /start.${NC}"
		fi
	else
		echo -e "${RED}Бот не запустился. Что случилось, покажет команда: journalctl -u ${BOT_SERVICE} -n 50${NC}"
		return 1
	fi
}

function uninstallBot() {
	systemctl disable --now "${BOT_SERVICE}" &>/dev/null
	rm -f "/etc/systemd/system/${BOT_SERVICE}.service"
	systemctl daemon-reload
	rm -rf "${BOT_DIR}" /etc/wg-bot
	echo "Telegram-бот удалён."
}

function botMenu() {
	if ! botInstalled; then
		installBot
		return
	fi

	echo "Telegram-бот уже установлен (сейчас: $(systemctl is-active "${BOT_SERVICE}"))."
	echo ""
	echo "   1) Переустановить или сменить токен и ID"
	echo "   2) Удалить бота"
	echo "   3) Выход"
	until [[ ${BOT_OPTION} =~ ^[1-3]$ ]]; do
		read -rp "Выбери пункт [1-3]: " BOT_OPTION
	done
	case "${BOT_OPTION}" in
	1)
		installBot
		;;
	2)
		uninstallBot
		;;
	3)
		exit 0
		;;
	esac
}

function manageMenu() {
	echo "Установщик WireGuard"
	echo "Репозиторий: ${REPO_URL}"
	echo ""
	echo "WireGuard уже установлен."
	echo ""
	echo "Что делаем?"
	echo "   1) Добавить клиента"
	echo "   2) Список клиентов"
	echo "   3) Удалить клиента"
	echo "   4) Telegram-бот: установить, перенастроить или удалить"
	echo "   5) Удалить WireGuard"
	echo "   6) Выход"
	until [[ ${MENU_OPTION} =~ ^[1-6]$ ]]; do
		read -rp "Выбери пункт [1-6]: " MENU_OPTION
	done
	case "${MENU_OPTION}" in
	1)
		newClient
		;;
	2)
		listClients
		;;
	3)
		revokeClient
		;;
	4)
		botMenu
		;;
	5)
		uninstallWg
		;;
	6)
		exit 0
		;;
	esac
}

function usage() {
	echo "Использование:"
	echo "  $0                  установка или меню управления"
	echo "  $0 add <имя>        добавить клиента"
	echo "  $0 list             список клиентов"
	echo "  $0 revoke <имя>     удалить клиента"
	echo "  $0 bot              установить или перенастроить Telegram-бота"
}

if [[ $1 == "-h" || $1 == "--help" ]]; then
	usage
	exit 0
fi

# Root, виртуализация, ОС...
initialCheck

if [[ -n $1 ]]; then
	if [[ ! -e /etc/wireguard/params ]]; then
		echo "WireGuard ещё не установлен — сначала запусти скрипт без аргументов." >&2
		exit 1
	fi
	source /etc/wireguard/params

	NONINTERACTIVE=1
	case "$1" in
	add)
		CLIENT_NAME=$2
		newClient
		;;
	list)
		listClients
		;;
	revoke)
		CLIENT_NAME=$2
		revokeClient
		;;
	bot)
		unset NONINTERACTIVE
		botMenu
		;;
	*)
		usage >&2
		exit 1
		;;
	esac
	exit
fi

# Если WireGuard уже стоит — читаем настройки и открываем меню
if [[ -e /etc/wireguard/params ]]; then
	source /etc/wireguard/params
	manageMenu
else
	installWireGuard
fi
