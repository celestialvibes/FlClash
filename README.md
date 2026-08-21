# LOOM.

Простой VPN-клиент для подписок [Loomhost](https://loomhost.ru).

Сейчас поддерживается macOS на Apple Silicon. Android вернётся после проверки macOS-версии.

## Возможности

- импорт подписки LOOM по URL или через `loomvpn://add?url=https%3A%2F%2Flmvn.pro%2FAb3dE%2Fmihomo`;
- выбор сервера и статистика текущей сессии;
- прямой маршрут для выбранных доменов, IP-адресов и CIDR;
- блокировка рекламы;
- подключение через TUN.

## Установка подписки

1. Получите подписку в [Telegram-боте LOOM](https://t.me/l00mvpn_bot).
2. Откройте LOOM и нажмите «Есть подписка?».
3. Вставьте ссылку подписки и подключитесь.

Поддержка: [@l00mvpnsupport](https://t.me/l00mvpnsupport).

## Сборка macOS

Нужны Flutter, Go и Xcode.

```bash
git submodule update --init --recursive
dart setup.dart macos
```

Тестовые сборки доступны в [GitHub Actions](https://github.com/celestialvibes/FlClash/actions). Публичные релизы публикуются только после подписи Developer ID и нотарификации Apple.

## Открытый исходный код

LOOM основан на [FlClash](https://github.com/chen08209/FlClash) и [Mihomo](https://github.com/MetaCubeX/mihomo). Код распространяется по [GNU GPLv3](LICENSE).
