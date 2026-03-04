## Matrix NixOS Module

Этот модуль предназначен для полностью автоматизированного развертывания инфраструктуры Matrix на базе NixOS. Включает в себя основной сервер Synapse, веб-клиент Element, SFU-сервер LiveKit для видеовызовов и Coturn для обхода NAT.

### Основные компоненты

* **Matrix Synapse**: Основной сервер сообщений.
* **PostgreSQL**: База данных (автоматическая инициализация ролей и прав).
* **Element Web**: Фронтенд-клиент с поддержкой Element Call.
* **LiveKit & JWT Service**: Стек для организации групповых аудио и видеозвонков.
* **Coturn**: TURN/STUN сервер для корректной работы VoIP.
* **Nginx**: Реверс-прокси с автоматическим получением сертификатов Let's Encrypt (ACME).

### Использование

#### NixOS

1. Разместите файл `matrix.nix` в `/etc/nixos/`.
2. Подключите его в `configuration.nix`:
```nix
imports = [ ./matrix.nix ];

```
3. Отредактируйте блок `cfg` в начале файла `matrix.nix`, указав ваши доменные имена, IP-адрес и контактный email.
4. Примените конфигурацию:
```bash
sudo nixos-rebuild switch

```

#### VPS (Debian/Ubuntu/etc) -> NixOS
Для деплоя с использованием этого модуля на VPS/VDS необходимо сменить ОС на купленном сервере. Если хостинг не предоставляет нативной возможности установки NixOS, то можно воспользоваться скриптом [nixos-infect](https://github.com/elitak/nixos-infect). Далее будет пример установки для хостинга beget.com.

1. Скачиваем скрипт на сервер и делаем его испольняемым
```sh
git clone https://github.com/elitak/nixos-infect.git && cd nixos-infect && chmod +x ./nixos-infect
```

2. Вносим правки в скрипт под beget.com (Инструкции для других хостингов можно найти в README.md репозитория, либо корректировать его работу самостоятельно)
```sh
sed -i 's/|| \[\[ "\$PROVIDER" = "hostinger" \]\]/|| [[ "$PROVIDER" = "hostinger" ]] || [[ "$PROVIDER" = "beget" ]]/' nixos-infect
sed -i 's/for grubdev in \/dev\/vda \/dev\/sda \/dev\/xvda \/dev\/nvme0n1 ; do \[\[ -e \$grubdev \]\] \&\& break; done/bootFs=\/boot\n    for grubdev in \/dev\/vda \/dev\/sda \/dev\/xvda \/dev\/nvme0n1 ; do [[ -e $grubdev ]] \&\& break; done/' nixos-infect
```

3. В Ubuntu (EFI) раздел /boot смонтирован, и его нельзя переместить напрямую. Добавьте команду размонтирования (umount) перед перемещением (mv):
```sh
sed -i 's/mv -v \$bootFs \$bootFs\.bak/umount -l $bootFs 2>\/dev\/null || true\n  mv -v $bootFs $bootFs.bak/' nixos-infect
```

**Внимание:** Обязательно добавьте ваш публичный SSH-ключ в /root/.ssh/authorized_keys перед запуском — после установки у пользователя root не будет пароля.

4. PROVIDER=beget NO_SWAP=true ./nixos-infect


После установки производим стандартные действия для деплоя:

1. Разместите файл `matrix.nix` в `/etc/nixos/`.
2. Подключите его в `configuration.nix`:
```nix
imports = [ ./matrix.nix ];

```
3. Отредактируйте блок `cfg` в начале файла `matrix.nix`, указав ваши доменные имена, IP-адрес и контактный email.
4. Примените конфигурацию:
```bash
sudo nixos-rebuild switch

```

### Полезные команды

1. Создание пользователя
```sh
SECRET=$(awk -F'"' '/registration_shared_secret/ {print $2}' /etc/secrets/synapse-extra.yaml) && nix-shell -p matrix-synapse --run "register_new_matrix_user -k '$SECRET' http://localhost:8008"
```

2. Health check сервисов
```sh
systemctl is-active matrix-synapse nginx coturn docker-livekit docker-lk-jwt-service postgresql
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

```sh
curl -s https://matrix.shegloproject.ru/_matrix/client/versions | head -c 80
curl -s https://matrix.shegloproject.ru/.well-known/matrix/client
curl -s https://matrix.shegloproject.ru/livekit/jwt/healthz
```

3. Просмотр логов
```sh
journalctl -u nginx --no-pager -n 20
journalctl -u matrix-synapse --no-pager -n 20
journalctl -u docker-livekit --no-pager -n 20
journalctl CONTAINER_NAME=livekit --no-pager -n 20 --since "5 min ago"
docker logs livekit 2>&1 | tail -20
```

### Требуемые открытые порты
### Требуемые открытые порты
| Порт | Протокол | Назначение |
|------|----------|------------|
| 80 | TCP | ACME challenge |
| 443 | TCP | HTTPS (Matrix, Element) |
| 443 | UDP | LiveKit TURN |
| 8448 | TCP | Matrix Federation |
| 5349 | TCP | LiveKit TURN TLS |
| 7881 | TCP | LiveKit RTC |
| 7882 | UDP+UDP | LiveKit RTC |
| 50100-50200 | UDP | LiveKit media |
