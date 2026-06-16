# AWG Script

Автоматическая установка AmneziaWG + wg-easy v15 на Ubuntu 22.04.

## Установка

```bash
curl -O https://raw.githubusercontent.com/LexazGit/awg-script/main/install_awg.sh && bash install_awg.sh
```

## Что делает скрипт

- Устанавливает AmneziaWG kernel module через PPA
- Устанавливает Docker
- Разворачивает wg-easy v15 с поддержкой AWG обфускации
- Настраивает iptables

## Требования

- не ниже Ubuntu 22.04 LTS, выше не тестировалось


## После установки

Открой веб-панель по адресу `http://IP_СЕРВЕРА:5000` и:
1. Выбери "Начать с нуля"
2. Задай пароль администратора
3. Настрой параметры обфускации AWG
