#!/bin/bash
# =============================================================================
# Установщик AmneziaWG / WireGuard сервера с Telegram-ботом для управления ключами
# https://github.com/A-Mak7u/wireguard-install-bot
#
# Поддерживает обфускацию трафика (Anti-DPI: Jc, Jmin, Jmax, S1, S2, H1..H4),
# TCP MSS Clamping, BBR v1 + FQ, автоподгонку MTU и Telegram-бота.
#
# Команды:
#   wireguard-install.sh add <имя>      добавить клиента, печатает путь к конфигу
#   wireguard-install.sh list           список клиентов, по одному в строке
#   wireguard-install.sh revoke <имя>   удалить клиента
#   wireguard-install.sh bot            установить или перенастроить Telegram-бота
# =============================================================================

set -e

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

if ((BASH_VERSINFO[0] >= 4)); then
	declare -A ASKED
fi

function getConfigFile() {
	local nic="${1:-${SERVER_WG_NIC:-awg0}}"
	if [[ -f "/etc/amnezia/amneziawg/${nic}.conf" ]]; then
		echo "/etc/amnezia/amneziawg/${nic}.conf"
	else
		echo "/etc/wireguard/${nic}.conf"
	fi
}

function getParamsFile() {
	if [[ -f "/etc/amnezia/amneziawg/params" ]]; then
		echo "/etc/amnezia/amneziawg/params"
	else
		echo "/etc/wireguard/params"
	fi
}

function detectTools() {
	if command -v awg &>/dev/null; then
		AWG_CMD="awg"
		AWG_QUICK_CMD="awg-quick"
		IS_AWG=1
	else
		AWG_CMD="wg"
		AWG_QUICK_CMD="wg-quick"
		IS_AWG=0
	fi
}

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
		echo "LXC пока не поддерживается напрямую."
		echo "Модуль ядра должен быть установлен на хосте."
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
		OS=debian
	elif [[ ${OS} == "ubuntu" ]]; then
		MAJOR_UBUNTU_VERSION=$(cut -d. -f1 <<<"${VERSION_ID}")
		if [[ ${MAJOR_UBUNTU_VERSION} -lt 18 ]]; then
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
		echo "Операционная система не поддерживается."
		exit 1
	fi
}

function getHomeDirForClient() {
	local CLIENT_NAME=$1
	if [ -z "${CLIENT_NAME}" ]; then
		echo "Ошибка: getHomeDirForClient() нужно передать имя клиента" >&2
		exit 1
	fi

	if [ -e "/home/${CLIENT_NAME}" ]; then
		HOME_DIR="/home/${CLIENT_NAME}"
	elif [ "${SUDO_USER}" ]; then
		if [ "${SUDO_USER}" == "root" ]; then
			HOME_DIR="/root"
		else
			HOME_DIR="/home/${SUDO_USER}"
		fi
	else
		HOME_DIR="/root"
	fi
	echo "$HOME_DIR"
}

function initialCheck() {
	isRoot
	checkOS
	checkVirt
	detectTools
}

function ask() {
	local var=$1 prompt=$2 default=$3

	if [[ ${AUTO_INSTALL} != "y" ]]; then
		read -rp "${prompt}" -e -i "${default}" "${var}"
		return
	fi

	if ((BASH_VERSINFO[0] >= 4)); then
		if [[ -n ${ASKED[${var}]} ]]; then
			echo -e "${RED}Некорректное значение ${var}=${!var}${NC}" >&2
			exit 1
		fi
		ASKED[${var}]=1
	fi
	if [[ -z ${!var} ]]; then
		printf -v "${var}" '%s' "${default}"
	fi
	echo "${prompt}${!var}"
}

function detectPublicIP() {
	local ip external
	ip=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	if [[ -z ${ip} || ${ip} =~ ^10\. || ${ip} =~ ^172\.(1[6-9]|2[0-9]|3[01])\. || ${ip} =~ ^192\.168\. ]]; then
		external=$(curl -4 -fsS -m 5 https://api.ipify.org 2>/dev/null || curl -4 -fsS -m 5 https://icanhazip.com 2>/dev/null || true)
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
	echo "=========================================================="
	echo "  Установщик AmneziaWG / WireGuard с Telegram-ботом"
	echo "  Репозиторий: ${REPO_URL}"
	echo "=========================================================="
	echo ""
	echo "Сначала несколько вопросов про параметры сети."
	echo "Если не уверен — просто жми Enter, значения по умолчанию подходят."
	echo ""

	ask SERVER_PUB_IP "Публичный IPv4 или IPv6 адрес сервера: " "$(detectPublicIP)"

	SERVER_NIC="$(ip -4 route ls | grep default | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1)"
	until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_.-]+$ ]]; do
		ask SERVER_PUB_NIC "Внешний сетевой интерфейс: " "${SERVER_NIC}"
	done

	until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
		ask SERVER_WG_NIC "Имя интерфейса VPN: " "awg0"
	done

	until [[ ${SERVER_WG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
		ask SERVER_WG_IPV4 "IPv4 сервера внутри VPN: " "10.66.66.1"
	done

	until [[ ${SERVER_WG_IPV6} =~ ^([a-f0-9]{1,4}:){3,4}: ]]; do
		ask SERVER_WG_IPV6 "IPv6 сервера внутри VPN: " "fd42:42:42::1"
	done

	RANDOM_PORT=$(shuf -i49152-65535 -n1)
	until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
		ask SERVER_PORT "Порт VPN [1-65535]: " "${RANDOM_PORT}"
	done

	until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		ask CLIENT_DNS_1 "Первый DNS-сервер для клиентов: " "1.1.1.1"
	done
	until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
		ask CLIENT_DNS_2 "Второй DNS-сервер для клиентов: " "1.0.0.1"
	done

	ask ALLOWED_IPS "Разрешённые подсети для клиентов: " "0.0.0.0/0, ::/0"

	# Параметры обфускации AmneziaWG (Anti-DPI)
	SERVER_AWG_JC=${SERVER_AWG_JC:-4}
	SERVER_AWG_JMIN=${SERVER_AWG_JMIN:-40}
	SERVER_AWG_JMAX=${SERVER_AWG_JMAX:-70}
	SERVER_AWG_S1=${SERVER_AWG_S1:-56}
	SERVER_AWG_S2=${SERVER_AWG_S2:-84}
	SERVER_AWG_H1=${SERVER_AWG_H1:-$(shuf -i 100000000-2000000000 -n 1)}
	SERVER_AWG_H2=${SERVER_AWG_H2:-$(shuf -i 100000000-2000000000 -n 1)}
	SERVER_AWG_H3=${SERVER_AWG_H3:-$(shuf -i 100000000-2000000000 -n 1)}
	SERVER_AWG_H4=${SERVER_AWG_H4:-$(shuf -i 100000000-2000000000 -n 1)}
}

function installPackagesForAmnezia() {
	if [[ ${OS} == 'ubuntu' ]]; then
		installPackages apt-get update
		installPackages apt-get install -y software-properties-common iptables resolvconf qrencode curl
		if ! grep -rqs "amnezia" /etc/apt/sources.list*; then
			echo "Подключаю PPA AmneziaWG..."
			add-apt-repository -y ppa:amnezia/ppa || true
			apt-get update || true
		fi
		if ! apt-get install -y amneziawg amneziawg-tools amneziawg-dkms; then
			echo -e "${ORANGE}Пакеты AmneziaWG недоступны, устанавливаю wireguard...${NC}"
			installPackages apt-get install -y wireguard wireguard-tools
		fi
	elif [[ ${OS} == 'debian' ]]; then
		apt-get update
		installPackages apt-get install -y iptables resolvconf qrencode curl gnupg
		if ! apt-get install -y amneziawg amneziawg-tools amneziawg-dkms 2>/dev/null; then
			if [[ ${VERSION_ID} -gt 10 ]]; then
				installPackages apt-get install -y wireguard wireguard-tools
			else
				if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
					echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
					apt-get update
				fi
				installPackages apt-get install -y -t buster-backports wireguard
			fi
		fi
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
			yum install -y qrencode || true
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

	detectTools
	if ! command -v "${AWG_CMD}" &>/dev/null; then
		echo -e "${RED}Утилита ${AWG_CMD} не найдена после установки пакетов.${NC}"
		exit 1
	fi

	# Симлинки совместимости wg -> awg при необходимости
	if [[ "${AWG_CMD}" == "awg" ]] && ! command -v wg &>/dev/null; then
		ln -sf "$(command -v awg)" /usr/local/bin/wg 2>/dev/null || true
	fi
	if [[ "${AWG_QUICK_CMD}" == "awg-quick" ]] && ! command -v wg-quick &>/dev/null; then
		ln -sf "$(command -v awg-quick)" /usr/local/bin/wg-quick 2>/dev/null || true
	fi
}

function installWireGuard() {
	installQuestions
	installPackagesForAmnezia

	mkdir -p /etc/wireguard /etc/amnezia/amneziawg
	chmod 700 /etc/wireguard /etc/amnezia/amneziawg 2>/dev/null || true

	# Генерация ключей сервера
	SERVER_PRIV_KEY=$(${AWG_CMD} genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | ${AWG_CMD} pubkey)

	# Сохраняем параметры
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
ALLOWED_IPS=${ALLOWED_IPS}
IS_AWG=${IS_AWG}
SERVER_AWG_JC=${SERVER_AWG_JC}
SERVER_AWG_JMIN=${SERVER_AWG_JMIN}
SERVER_AWG_JMAX=${SERVER_AWG_JMAX}
SERVER_AWG_S1=${SERVER_AWG_S1}
SERVER_AWG_S2=${SERVER_AWG_S2}
SERVER_AWG_H1=${SERVER_AWG_H1}
SERVER_AWG_H2=${SERVER_AWG_H2}
SERVER_AWG_H3=${SERVER_AWG_H3}
SERVER_AWG_H4=${SERVER_AWG_H4}" >/etc/wireguard/params

	cp /etc/wireguard/params /etc/amnezia/amneziawg/params 2>/dev/null || true
	chmod 600 /etc/wireguard/params /etc/amnezia/amneziawg/params 2>/dev/null || true

	local CONF_DEST="/etc/wireguard/${SERVER_WG_NIC}.conf"
	if [[ ${IS_AWG} -eq 1 ]]; then
		CONF_DEST="/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf"
	fi

	# Сборка серверного конфига
	{
		echo "[Interface]"
		echo "Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64"
		echo "ListenPort = ${SERVER_PORT}"
		echo "PrivateKey = ${SERVER_PRIV_KEY}"
		if [[ ${IS_AWG} -eq 1 ]]; then
			echo "Jc = ${SERVER_AWG_JC}"
			echo "Jmin = ${SERVER_AWG_JMIN}"
			echo "Jmax = ${SERVER_AWG_JMAX}"
			echo "S1 = ${SERVER_AWG_S1}"
			echo "S2 = ${SERVER_AWG_S2}"
			echo "H1 = ${SERVER_AWG_H1}"
			echo "H2 = ${SERVER_AWG_H2}"
			echo "H3 = ${SERVER_AWG_H3}"
			echo "H4 = ${SERVER_AWG_H4}"
		fi

		# Сетевые хуки с TCP MSS Clamping
		echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT"
		echo "PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT"
		echo "PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT"
		echo "PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE"
		echo "PostUp = iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
		echo "PostUp = ip6tables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT"
		echo "PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE"
		echo "PostUp = ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"

		echo "PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT"
		echo "PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT"
		echo "PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT"
		echo "PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE"
		echo "PostDown = iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
		echo "PostDown = ip6tables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT"
		echo "PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE"
		echo "PostDown = ip6tables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
	} >"${CONF_DEST}"

	chmod 600 "${CONF_DEST}"
	if [[ ${IS_AWG} -eq 1 ]]; then
		ln -sf "${CONF_DEST}" "/etc/wireguard/${SERVER_WG_NIC}.conf" 2>/dev/null || true
	fi

	# Оптимизация сетевого стека ядра (BBR + FQ + MSS clamping + forwarding)
	cat >/etc/sysctl.d/99-vpn-tuning.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
EOF

	if [[ ${OS} == 'alpine' ]]; then
		sysctl -p /etc/sysctl.d/99-vpn-tuning.conf 2>/dev/null || sysctl -p /etc/sysctl.d/wg.conf
		rc-update add sysctl
		ln -sf "/etc/init.d/${AWG_QUICK_CMD}" "/etc/init.d/${AWG_QUICK_CMD}.${SERVER_WG_NIC}"
		rc-service "${AWG_QUICK_CMD}.${SERVER_WG_NIC}" start
		rc-update add "${AWG_QUICK_CMD}.${SERVER_WG_NIC}"
	else
		sysctl --system 2>/dev/null || sysctl -p /etc/sysctl.d/99-vpn-tuning.conf 2>/dev/null || true
		systemctl daemon-reload 2>/dev/null || true
		systemctl start "${AWG_QUICK_CMD}@${SERVER_WG_NIC}"
		systemctl enable "${AWG_QUICK_CMD}@${SERVER_WG_NIC}"
	fi

	newClient
	echo -e "${GREEN}Чтобы добавить ещё клиентов, просто запусти скрипт ещё раз.${NC}"

	if [[ ${OS} == 'alpine' ]]; then
		rc-service --quiet "${AWG_QUICK_CMD}.${SERVER_WG_NIC}" status
	else
		systemctl is-active --quiet "${AWG_QUICK_CMD}@${SERVER_WG_NIC}"
	fi
	WG_RUNNING=$?

	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}ВНИМАНИЕ: служба VPN не запустилась.${NC}"
		echo -e "${ORANGE}Проверить статус: systemctl status ${AWG_QUICK_CMD}@${SERVER_WG_NIC}${NC}"
	else
		echo -e "\n${GREEN}VPN сервис (${AWG_QUICK_CMD}@${SERVER_WG_NIC}) успешно запущен!${NC}"
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
	grep -qxF "### Client $1" "$(getConfigFile "${SERVER_WG_NIC}")" 2>/dev/null
}

function ipTaken() {
	grep -qE "(^|[[:space:]=,])${1//./\\.}([[:space:],]|$)" "$(getConfigFile "${SERVER_WG_NIC}")" 2>/dev/null
}

function newClient() {
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

	CLIENT_PRIV_KEY=$(${AWG_CMD} genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | ${AWG_CMD} pubkey)
	CLIENT_PRE_SHARED_KEY=$(${AWG_CMD} genpsk)

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	CLIENT_CONF="${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

	# Калиброванный MTU
	CLIENT_MTU=1360
	if [[ "${CLIENT_NAME,,}" == *"mac"* ]]; then
		CLIENT_MTU=1376
	fi

	# Извлекаем параметры обфускации сервера, если они есть
	OBF_PARAMS=""
	local server_conf
	server_conf="$(getConfigFile "${SERVER_WG_NIC}")"
	if [[ -f "${server_conf}" ]]; then
		for param in Jc Jmin Jmax S1 S2 H1 H2 H3 H4; do
			val=$(grep -E "^${param}[[:space:]]*=" "${server_conf}" | head -n1)
			if [[ -n "$val" ]]; then
				OBF_PARAMS+="$val"$'\n'
			fi
		done
	fi

	(
		umask 077
		{
			echo "[Interface]"
			echo "PrivateKey = ${CLIENT_PRIV_KEY}"
			echo "Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
			echo "DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}"
			echo "MTU = ${CLIENT_MTU}"
			if [[ -n "${OBF_PARAMS}" ]]; then
				printf '%s' "${OBF_PARAMS}"
			fi
			echo ""
			echo "[Peer]"
			echo "PublicKey = ${SERVER_PUB_KEY}"
			echo "PresharedKey = ${CLIENT_PRE_SHARED_KEY}"
			echo "Endpoint = ${ENDPOINT}"
			echo "AllowedIPs = ${ALLOWED_IPS}"
			echo "PersistentKeepalive = 25"
		} >"${CLIENT_CONF}"
	)

	# Симлинк для обратной совместимости wg0-client-...
	if [[ "${SERVER_WG_NIC}" != "wg0" ]]; then
		ln -sf "${CLIENT_CONF}" "${HOME_DIR}/wg0-client-${CLIENT_NAME}.conf" 2>/dev/null || true
	fi

	# Добавляем клиента в серверный конфиг
	echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"$(getConfigFile "${SERVER_WG_NIC}")"

	if ! ${AWG_CMD} syncconf "${SERVER_WG_NIC}" <(${AWG_QUICK_CMD} strip "${SERVER_WG_NIC}") 2>/dev/null; then
		${AWG_CMD} syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}") 2>/dev/null || true
	fi

	if [[ -n ${NONINTERACTIVE} ]]; then
		echo "${CLIENT_CONF}"
		return
	fi

	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nКонфиг клиента в виде QR-кода:\n${NC}"
		qrencode -t ansiutf8 -l L <"${CLIENT_CONF}"
		echo ""
	fi

	echo -e "${GREEN}Конфиг клиента сохранён: ${CLIENT_CONF}${NC}"
}

function listClients() {
	local conf
	conf="$(getConfigFile "${SERVER_WG_NIC}")"

	if [[ -n ${NONINTERACTIVE} ]]; then
		grep -E "^### Client " "${conf}" 2>/dev/null | cut -d ' ' -f 3
		return 0
	fi

	NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${conf}" 2>/dev/null || echo 0)
	if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
		echo ""
		echo "Клиентов пока нет."
		exit 1
	fi

	grep -E "^### Client" "${conf}" | cut -d ' ' -f 3 | nl -s ') '
}

function removeClientFromConf() {
	local conf tmp
	conf="$(getConfigFile "${SERVER_WG_NIC}")"

	tmp=$(mktemp "/tmp/.${SERVER_WG_NIC}.conf.XXXXXX") || exit 1
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
	local conf
	conf="$(getConfigFile "${SERVER_WG_NIC}")"

	if [[ -n ${NONINTERACTIVE} ]]; then
		if [[ -z ${CLIENT_NAME} ]] || ! clientExists "${CLIENT_NAME}"; then
			echo "Клиент «${CLIENT_NAME}» не найден." >&2
			exit 1
		fi
	else
		NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "${conf}" 2>/dev/null || echo 0)
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

		CLIENT_NAME=$(grep -E "^### Client" "${conf}" | cut -d ' ' -f 3 | sed -n "${CLIENT_NUMBER}"p)
	fi

	removeClientFromConf "${CLIENT_NAME}"

	HOME_DIR=$(getHomeDirForClient "${CLIENT_NAME}")
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
	rm -f "${HOME_DIR}/wg0-client-${CLIENT_NAME}.conf"
	rm -f "${HOME_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.png"

	if ! ${AWG_CMD} syncconf "${SERVER_WG_NIC}" <(${AWG_QUICK_CMD} strip "${SERVER_WG_NIC}") 2>/dev/null; then
		${AWG_CMD} syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}") 2>/dev/null || true
	fi

	if [[ -z ${NONINTERACTIVE} ]]; then
		echo -e "${GREEN}Клиент ${CLIENT_NAME} удалён.${NC}"
	fi
}

function uninstallWg() {
	echo ""
	echo -e "\n${RED}ВНИМАНИЕ: VPN будет удалён вместе со всеми настройками и ключами!${NC}"
	read -rp "Точно удалить VPN? [y/n]: " -e REMOVE
	REMOVE=${REMOVE:-n}
	if [[ $REMOVE == 'y' ]]; then
		checkOS

		if botInstalled; then
			uninstallBot
		fi

		if [[ ${OS} == 'alpine' ]]; then
			rc-service "${AWG_QUICK_CMD}.${SERVER_WG_NIC}" stop 2>/dev/null || true
			rc-update del "${AWG_QUICK_CMD}.${SERVER_WG_NIC}" 2>/dev/null || true
		else
			systemctl stop "${AWG_QUICK_CMD}@${SERVER_WG_NIC}" 2>/dev/null || true
			systemctl disable "${AWG_QUICK_CMD}@${SERVER_WG_NIC}" 2>/dev/null || true
		fi

		if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' ]]; then
			apt-get remove -y amneziawg amneziawg-tools amneziawg-dkms wireguard wireguard-tools qrencode 2>/dev/null || true
		elif [[ ${OS} == 'fedora' ]]; then
			dnf remove -y --noautoremove wireguard-tools qrencode 2>/dev/null || true
		elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
			yum remove -y --noautoremove wireguard-tools kmod-wireguard qrencode 2>/dev/null || true
		fi

		rm -rf /etc/wireguard /etc/amnezia/amneziawg
		rm -f /etc/sysctl.d/99-vpn-tuning.conf /etc/sysctl.d/wg.conf

		sysctl --system 2>/dev/null || true
		echo "VPN полностью удалён."
		exit 0
	else
		echo ""
		echo "Удаление отменено."
	fi
}

# ========= Telegram-бот =========

function botInstalled() {
	[[ -f "/etc/systemd/system/${BOT_SERVICE}.service" ]]
}

function telegramApi() {
	printf 'url = "%s/bot%s/%s"\n' "${TELEGRAM_API_URL}" "${BOT_TOKEN}" "$1" | curl -sS -m 15 -K - 2>/dev/null
}

function fetchRepoFile() {
	local path=$1 dest=$2 src_dir

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
	count=$(grep -c . <<<"${users}" || echo 0)
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
	echo "Telegram-бот для AmneziaWG / WireGuard"
	echo ""
	echo "Бот выдаёт новые ключи (файл и QR-код), удаляет их и показывает статус."
	echo "Слушается только тех, чьи Telegram ID ты укажешь."
	echo ""

	echo "Ставлю Python..."
	if [[ ${OS} == 'ubuntu' || ${OS} == 'debian' ]]; then
		apt-get update
		installPackages apt-get install -y python3 python3-venv curl
	elif [[ ${OS} == 'fedora' || ${OS} == 'oracle' ]]; then
		installPackages dnf install -y python3
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
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

	if [[ -f ${BOT_ENV_FILE} ]]; then
		old_token=$(sed -n 's/^TELEGRAM_TOKEN=//p' "${BOT_ENV_FILE}")
		old_admins=$(sed -n 's/^ADMIN_IDS=//p' "${BOT_ENV_FILE}")
	fi
	systemctl stop "${BOT_SERVICE}" 2>/dev/null || true

	echo ""
	echo "1. Открой в Telegram @BotFather, отправь /newbot и придумай боту имя."
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

	cat >"/etc/systemd/system/${BOT_SERVICE}.service" <<EOF
[Unit]
Description=AmneziaWG / WireGuard Telegram Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${BOT_ENV_FILE}
ExecStart=${BOT_DIR}/venv/bin/python ${BOT_DIR}/bot/wg_bot.py
Restart=always
RestartSec=5
RestartPreventExitStatus=2

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable "${BOT_SERVICE}" &>/dev/null || true
	systemctl restart "${BOT_SERVICE}"
	sleep 3

	if systemctl is-active --quiet "${BOT_SERVICE}"; then
		echo -e "${GREEN}Бот запущен.${NC}"
		if [[ -n ${BOT_USERNAME} ]]; then
			echo -e "${GREEN}Открой @${BOT_USERNAME} в Telegram и отправь /start.${NC}"
		fi
	else
		echo -e "${RED}Бот не запустился. Логи: journalctl -u ${BOT_SERVICE} -n 50${NC}"
		return 1
	fi
}

function uninstallBot() {
	systemctl disable --now "${BOT_SERVICE}" &>/dev/null || true
	rm -f "/etc/systemd/system/${BOT_SERVICE}.service"
	systemctl daemon-reload 2>/dev/null || true
	rm -rf "${BOT_DIR}" /etc/wg-bot
	echo "Telegram-бот удалён."
}

function botMenu() {
	if ! botInstalled; then
		installBot
		return
	fi

	echo "Telegram-бот уже установлен (сейчас: $(systemctl is-active "${BOT_SERVICE}" 2>/dev/null || echo "не активен"))."
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
	echo "=========================================================="
	echo "  Управление AmneziaWG / WireGuard сервером"
	echo "  Репозиторий: ${REPO_URL}"
	echo "=========================================================="
	echo ""
	echo "VPN уже установлен (интерфейс: ${SERVER_WG_NIC})."
	echo ""
	echo "Что делаем?"
	echo "   1) Добавить клиента"
	echo "   2) Список клиентов"
	echo "   3) Удалить клиента"
	echo "   4) Telegram-бот: установить, перенастроить или удалить"
	echo "   5) Удалить VPN"
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

initialCheck

PARAMS_FILE="$(getParamsFile)"
if [[ -n $1 ]]; then
	if [[ ! -e "${PARAMS_FILE}" ]]; then
		echo "VPN ещё не установлен — сначала запусти скрипт без аргументов." >&2
		exit 1
	fi
	source "${PARAMS_FILE}"

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

if [[ -e "${PARAMS_FILE}" ]]; then
	source "${PARAMS_FILE}"
	manageMenu
else
	installWireGuard
fi
