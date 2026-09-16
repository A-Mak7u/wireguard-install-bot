#!/bin/bash
# Сквозная проверка в Docker: установка на чистую систему с systemd, бот против
# поддельного Telegram API, настоящий туннель со второго контейнера, меню и удаление.
#
#   tests/run.sh [образ]     по умолчанию ubuntu:24.04, можно debian:12 и т. п.
#
# Нужен Docker с ядром, где есть WireGuard (Docker Desktop и современные Linux подходят).

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
BASE_IMAGE=${1:-ubuntu:24.04}
SUFFIX=$(tr -c 'a-z0-9\n' '-' <<<"${BASE_IMAGE}")
TAG="wg-install-bot-test:${SUFFIX}"
NET="wgib-${SUFFIX}"
SERVER="wgib-server-${SUFFIX}"
CLIENT="wgib-client-${SUFFIX}"
PORT=51820
TOKEN="123456:TESTtoken_aaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
FAILED=0
LOGS=$(mktemp -d)

remove_containers() {
	docker rm -f "${SERVER}" "${CLIENT}" &>/dev/null
	docker network rm "${NET}" &>/dev/null
}
trap 'remove_containers; rm -rf "${LOGS}"' EXIT

on_server() { docker exec "${SERVER}" bash -c "$1"; }
on_client() { docker exec "${CLIENT}" bash -c "$1"; }
section() { echo -e "\n=== $1"; }

# check <описание> <команда на сервере>
check() {
	if on_server "$2" &>/dev/null; then
		echo "OK   $1"
	else
		echo "FAIL $1"
		FAILED=1
	fi
}

section "shellcheck"
if docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:stable -S warning /mnt/wireguard-install.sh /mnt/tests/run.sh; then
	echo "OK   замечаний нет"
else
	FAILED=1
fi

section "Готовлю контейнеры (${BASE_IMAGE})"
remove_containers
docker build -q -t "${TAG}" --build-arg BASE_IMAGE="${BASE_IMAGE}" tests >/dev/null || exit 1
docker network create "${NET}" >/dev/null || exit 1
for name in "${SERVER}" "${CLIENT}"; do
	docker run -d --name "${name}" --hostname "${name}" --network "${NET}" --privileged --cgroupns=host \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock -v "$PWD:/repo:ro" "${TAG}" >/dev/null || exit 1
done
SERVER_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "${SERVER}")
for _ in $(seq 60); do
	on_server 'systemctl is-system-running 2>/dev/null' | grep -qE 'running|degraded' && break
	sleep 1
done

docker exec -d "${SERVER}" python3 /repo/tests/fake_telegram.py
until on_server 'python3 /repo/tests/tg_client.py clear' &>/dev/null; do sleep 0.5; done

section "Установка без вопросов: WireGuard + бот"
if ! on_server "AUTO_INSTALL=y SERVER_PUB_IP=${SERVER_IP} SERVER_PORT=${PORT} CLIENT_NAME=phone \
	INSTALL_BOT=y BOT_TOKEN=${TOKEN} BOT_ADMIN_IDS=555 TELEGRAM_API_URL=http://127.0.0.1:8081 \
	/repo/wireguard-install.sh" >"${LOGS}/install.log" 2>&1; then
	echo "FAIL установщик завершился с ошибкой, хвост лога:"
	tail -30 "${LOGS}/install.log"
	exit 1
fi
check "WireGuard запущен" "systemctl is-active --quiet wg-quick@wg0"
check "WireGuard в автозагрузке" "systemctl is-enabled --quiet wg-quick@wg0"
check "бот запущен" "systemctl is-active --quiet wg-bot"
check "бот в автозагрузке" "systemctl is-enabled --quiet wg-bot"
check "конфиг первого клиента доступен только root" "[[ \$(stat -c %a /root/wg0-client-phone.conf) == 600 ]]"
check "файл с токеном доступен только root" "[[ \$(stat -c %a /etc/wg-bot/bot.env) == 600 ]]"

section "Бот (поддельный Telegram)"
on_server "cd /repo/tests && EXPECTED_PORT=${PORT} python3 test_bot.py" || FAILED=1
check "токена нет в логах бота" "! journalctl -u wg-bot --no-pager | grep -q TESTtoken"

section "Команды add / list / revoke"
check "add печатает путь к конфигу" "[[ \$(/opt/wg-bot/wireguard-install.sh add cli1) == /root/wg0-client-cli1.conf ]]"
check "add с занятым именем — ошибка" "! /opt/wg-bot/wireguard-install.sh add cli1"
check "add с некорректным именем — ошибка" "! /opt/wg-bot/wireguard-install.sh add 'bad.name'"
check "add с именем длиннее 15 символов — ошибка" "! /opt/wg-bot/wireguard-install.sh add abcdefghijklmnop"
check "list показывает клиента" "/opt/wg-bot/wireguard-install.sh list | grep -qx cli1"
check "revoke несуществующего — ошибка" "! /opt/wg-bot/wireguard-install.sh revoke ghost"
check "revoke удаляет клиента" "/opt/wg-bot/wireguard-install.sh revoke cli1 && ! /opt/wg-bot/wireguard-install.sh list | grep -qx cli1"
check "revoke убирает пира из работающего WireGuard" "[[ \$(wg show wg0 peers | wc -l) == \$(grep -c '^### Client' /etc/wireguard/wg0.conf) ]]"

section "Выбор адреса: .3 свободен, а .30–.39 заняты"
on_server 'for i in $(seq 3 39); do /opt/wg-bot/wireguard-install.sh add n$i >/dev/null; done
	/opt/wg-bot/wireguard-install.sh revoke n3'
check "новый клиент получает освободившийся .3" "/opt/wg-bot/wireguard-install.sh add again >/dev/null && grep -q 'Address = 10.66.66.3/32' /root/wg0-client-again.conf"
on_server 'for c in again $(seq -f n%g 4 39); do /opt/wg-bot/wireguard-install.sh revoke $c; done'

section "revoke в конфиге, где при ручной правке пропали пустые строки"
on_server 'for c in x1 x2 x3; do /opt/wg-bot/wireguard-install.sh add $c >/dev/null; done
	sed -i "/^[[:space:]]*\$/d" /etc/wireguard/wg0.conf
	/opt/wg-bot/wireguard-install.sh revoke x2'
check "соседние клиенты на месте" "grep -qx '### Client x1' /etc/wireguard/wg0.conf && grep -qx '### Client x3' /etc/wireguard/wg0.conf"
check "пиров в конфиге столько же, сколько клиентов" "[[ \$(grep -c '^\[Peer\]' /etc/wireguard/wg0.conf) == \$(grep -c '^### Client' /etc/wireguard/wg0.conf) ]]"
check "и столько же в работающем WireGuard" "[[ \$(wg show wg0 peers | wc -l) == \$(grep -c '^### Client' /etc/wireguard/wg0.conf) ]]"
on_server '/opt/wg-bot/wireguard-install.sh revoke x1; /opt/wg-bot/wireguard-install.sh revoke x3'

section "Настоящий туннель со второго контейнера"
on_client 'apt-get update -qq && apt-get install -y -qq wireguard-tools iptables iputils-ping curl' >"${LOGS}/client-apt.log" 2>&1 ||
	tail -5 "${LOGS}/client-apt.log"
on_server '/opt/wg-bot/wireguard-install.sh add laptop >/dev/null && cat /root/wg0-client-laptop.conf' |
	grep -v '^DNS' | docker exec -i "${CLIENT}" bash -c 'umask 077; mkdir -p /etc/wireguard; cat >/etc/wireguard/wg0.conf'
if on_client 'wg-quick up wg0' &>"${LOGS}/client.log"; then
	echo "OK   клиент поднял туннель"
else
	echo "FAIL клиент не поднял туннель:"
	cat "${LOGS}/client.log"
	FAILED=1
fi
if on_client 'ping -c 3 -W 2 10.66.66.1' >/dev/null; then echo "OK   сервер пингуется через туннель"; else echo "FAIL пинг сервера через туннель"; FAILED=1; fi
if on_client 'curl -fsS -m 20 -o /dev/null https://www.cloudflare.com/cdn-cgi/trace'; then
	echo "OK   интернет через VPN работает"
else
	echo "FAIL нет интернета через VPN"
	FAILED=1
fi
check "трафик клиента прошёл через сервер" "wg show wg0 transfer | awk -v key=\$(grep -A2 '^### Client laptop' /etc/wireguard/wg0.conf | sed -n 's/^PublicKey = //p') '\$1 == key && \$2 + \$3 > 3000 {found = 1} END {exit !found}'"
on_client 'wg-quick down wg0' &>/dev/null

section "Меню (вопросы и ответы)"
for scenario in menu_add menu_list menu_revoke bot_reconfigure; do
	if on_server "TELEGRAM_API_URL=http://127.0.0.1:8081 expect /repo/tests/${scenario}.exp" >"${LOGS}/${scenario}.log" 2>&1; then
		echo "OK   ${scenario}"
	else
		echo "FAIL ${scenario}, хвост вывода:"
		tail -15 "${LOGS}/${scenario}.log"
		FAILED=1
	fi
done
check "после перенастройки бот слушается нового админа" "grep -qx 'ADMIN_IDS=999' /etc/wg-bot/bot.env && systemctl is-active --quiet wg-bot"

section "Бот с неверным токеном"
on_server 'sed -i "s/^TELEGRAM_TOKEN=.*/TELEGRAM_TOKEN=1:bad/" /etc/wg-bot/bot.env && systemctl restart wg-bot && sleep 10'
check "бот останавливается с кодом 2 и не перезапускается по кругу" \
	"[[ \$(systemctl show -p ActiveState --value wg-bot) == failed && \$(systemctl show -p ExecMainStatus --value wg-bot) == 2 && \$(systemctl show -p NRestarts --value wg-bot) == 0 ]]"

section "Удаление"
if on_server "expect /repo/tests/uninstall.exp" >"${LOGS}/uninstall.log" 2>&1; then
	echo "OK   uninstall"
else
	echo "FAIL uninstall, хвост вывода:"
	tail -15 "${LOGS}/uninstall.log"
	FAILED=1
fi
check "WireGuard остановлен и удалён" "! systemctl is-active --quiet wg-quick@wg0 && [[ ! -e /etc/wireguard/params ]] && ! command -v wg"
check "бот удалён" "! systemctl cat wg-bot && [[ ! -e /opt/wg-bot && ! -e /etc/wg-bot ]]"

echo
if [[ ${FAILED} == 0 ]]; then
	echo "Все проверки пройдены (${BASE_IMAGE})"
else
	echo "Есть проваленные проверки (${BASE_IMAGE})"
fi
exit "${FAILED}"
