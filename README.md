# p2k: proxy через Kerberos для приложений без Kerberos

Комплект поднимает локальный HTTP-прокси через `px`, который авторизуется на
корпоративном прокси по Kerberos/Negotiate. Приложения, которые не умеют
Kerberos, запускаются через `proxychains-ng` и ходят в этот локальный прокси.

Схема:

```text
приложение -> proxychains-ng -> 127.0.0.1:18080 -> px -> proxy.ols.vniitf.ru:3128
```

## Состав

```text
px-bin/                  готовый бинарный px
px.ini                   конфиг px
proxychains-portable/    переносимый proxychains-ng
```

## Настройка

В `px.ini` замените пользователя на свой Kerberos principal:

```ini
username = user@ols.vniitf.ru
```

Текущие ключевые параметры:

```ini
server = proxy.ols.vniitf.ru:3128
listen = 127.0.0.1
port = 18080
auth = NEGOTIATE
kerberos = 1
client_auth = NONE
```

`client_auth = NONE` означает, что локальные приложения подключаются к `px` без
логина и пароля. Kerberos используется только между `px` и корпоративным прокси.

## Первый запуск

Сделайте файлы исполняемыми, если права потерялись после копирования:

```bash
chmod +x ./px-bin/px
chmod +x ./proxychains-portable/proxychains4-local
chmod +x ./proxychains-portable/bin/proxychains4
```

Сохраните пароль для пользователя из `px.ini`:

```bash
./px-bin/px --password
```

Запустите локальный прокси:

```bash
./px-bin/px
```

Оставьте этот процесс запущенным.

Если запускаете `px` не из директории комплекта, укажите конфиг явно:

```bash
./px-bin/px --config=./px.ini
```

## Запуск приложений через прокси

В другом терминале:

```bash
./proxychains-portable/proxychains4-local curl https://example.com
```

Чтобы все команды внутри shell шли через прокси:

```bash
./proxychains-portable/proxychains4-local bash
```

Конфиг `proxychains-ng` уже указывает на локальный `px`:

```ini
http 127.0.0.1 18080
```

Если меняете порт `px` в `px.ini`, поменяйте его и в
`proxychains-portable/etc/proxychains.conf`.

## Проверка

Проверить сам `px`:

```bash
./px-bin/px --test=https://example.com
```

Проверить связку `proxychains-ng -> px`:

```bash
./proxychains-portable/proxychains4-local curl -v https://example.com
```

## Частые проблемы

`permission denied`:

```bash
chmod +x ./px-bin/px ./proxychains-portable/proxychains4-local ./proxychains-portable/bin/proxychains4
```

`No credentials were supplied` или ошибка Kerberos:

- проверьте `username` в `px.ini`;
- заново выполните `./px-bin/px --password`;
- убедитесь, что корпоративный прокси доступен как `proxy.ols.vniitf.ru:3128`;
- используйте FQDN прокси, не IP-адрес.

`proxychains-ng` не влияет на программу:

- программа может быть статически собрана;
- программа может очищать или запрещать `LD_PRELOAD`;
- setuid-программы через `proxychains-ng` обычно не работают.
