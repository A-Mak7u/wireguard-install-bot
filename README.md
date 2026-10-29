# AmneziaWG + Telegram-бот

Быстрый автоматический установщик VPN-сервера **AmneziaWG** (WireGuard с защитой от блокировок / Anti-DPI) и **Telegram-бота** для удобного управления ключами прямо с телефона.

Скрипт настраивает сервер за пару минут, оптимизирует сеть и присылает готовые конфиги и QR-коды для подключения.

---

## ⚡️ Быстрый старт

Подключись к серверу по SSH (`root` или пользователь с `sudo`) и запусти:

```bash
curl -O https://raw.githubusercontent.com/A-Mak7u/wireguard-install-bot/main/amneziawg-install.sh
chmod +x amneziawg-install.sh
sudo ./amneziawg-install.sh
```
> *(Для обратной совместимости также поддерживается вызов через `wireguard-install.sh`)*.

### Шаги установки:
1. **Параметры сети**: нажимай **Enter** для значений по умолчанию.
2. **Первый клиент**: введи имя (например, `phone`) — в терминале появится готовый QR-код.
3. **Telegram-бот**:
   - Создай бота в [@BotFather](https://t.me/BotFather) (`/newbot`), вставь полученный токен;
   - Отправь боту любое сообщение в Telegram — установщик автоматически определит твой Telegram ID;
   - Открой бота и нажми `/start`.

---

## 🚀 Ключевые возможности

- **🛡 Защита от блокировок (Anti-DPI / Obfuscation)**:
  - Псевдослучайные заголовки (`H1`–`H4`) и выравнивание длины пакетов (`S1`, `S2`);
  - Мусорные UDP-пакеты (`Jc`, `Jmin`, `Jmax`) перед handshake для обхода сигнатурных анализаторов;
  - Калиброванный MTU (1360 для мобильных/ПК, 1376 для macOS) для исключения фрагментации.
- **⚡️ Сетевая оптимизация**:
  - Контроль перегрузок **Google BBR v1** + планировщик очередей **FQ**;
  - **TCP MSS Clamping to PMTU** (устраняет зависания тяжёлых TLS 1.3 / HTTPS сайтов).
- **🤖 Управление в Telegram**:
  - `➕ Добавить ключ` — моментальная выдача файла `.conf` и QR-кода;
  - `🗑 Удалить ключ` — отзыв доступа на лету с подтверждением;
  - `👥 Клиенты WG` — мониторинг онлайна (за 10 мин) и счётчики трафика;
  - `📊 Статус сервера` — аптайм, Load Average, RAM, диск и состояние службы.
  - *Безопасность*: бот отвечает строго админам, токен хранится с правами `0600`.

---

## 🛠 Консольное управление (CLI)

```bash
sudo ./amneziawg-install.sh              # Интерактивное меню
sudo ./amneziawg-install.sh add <имя>    # Создать ключ и напечатать путь к .conf
sudo ./amneziawg-install.sh list         # Список клиентов
sudo ./amneziawg-install.sh revoke <имя> # Отозвать и удалить клиента
sudo ./amneziawg-install.sh bot          # Настройка или удаление бота
```

### Тихая установка без вопросов:

```bash
sudo AUTO_INSTALL=y CLIENT_NAME=phone \
  INSTALL_BOT=y BOT_TOKEN='123456789:AAH...' BOT_ADMIN_IDS=111111111 \
  ./amneziawg-install.sh
```

---

## 📱 Клиенты

Подходят клиенты с поддержкой параметров обфускации:
- **iOS**: [App Store](https://apps.apple.com/app/amneziawg/id6478942364)
- **macOS**: [Mac App Store](https://apps.apple.com/app/amneziawg/id6479044238)
- **Android**: [Google Play](https://play.google.com/store/apps/details?id=org.amnezia.awg)
- **Windows / Linux**: [GitHub Releases](https://github.com/amnezia-vpn/amneziawg-windows-client/releases)

> [!IMPORTANT]
> Один ключ рассчитан строго на одно устройство одновременно.

---

## 📁 Пути к файлам

| Назначение | Путь в системе |
|---|---|
| Конфигурация сервера | `/etc/amnezia/amneziawg/awg0.conf` (или `/etc/wireguard/awg0.conf`) |
| Сохранённые параметры | `/etc/wireguard/params` (и `/etc/amnezia/amneziawg/params`) |
| Клиентские файлы | `/root/awg0-client-<имя>.conf` |
| Файлы и секреты бота | `/opt/wg-bot/`, `/etc/wg-bot/bot.env` (`chmod 600`) |
| Служба бота | `systemctl status wg-bot` (логи: `journalctl -u wg-bot -f`) |

---

## 📄 Лицензия

MIT License. Основан на наработках [angristan/wireguard-install](https://github.com/angristan/wireguard-install) и открытых компонентах AmneziaWG.
