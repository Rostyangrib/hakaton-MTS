# Демонстрационный DevOps стенд МТС

Nginx в Kubernetes на Ubuntu 24.04. Доступ через Gateway API, метрики в Prometheus, access/error-логи собирает Fluentd. Установка: три shell-сценария и четыре файла манифестов. Результаты проверок — в [PROJECT_STATUS.md](PROJECT_STATUS.md), история — в [CHANGELOG.md](CHANGELOG.md).

## Архитектура

```mermaid
flowchart LR
    Client[HTTP клиент] --> Gateway[Envoy Proxy / Gateway API]
    Gateway --> Service[Service Nginx]
    Service --> App[2 Pod Nginx]
    Prometheus -->|метрики| Gateway
    Prometheus -->|метрики| Controller[Envoy Gateway]
    App -->|stdout / stderr| Fluentd
    Fluentd --> Logs[Файлы на Ubuntu узле]
```

Среда: Ubuntu Server 24.04.4, один узел kubeadm, containerd из репозитория Ubuntu, сеть Flannel. Gateway Controller — Envoy Gateway.

| Компонент | Версия |
| --- | --- |
| Kubernetes / kubeadm / kubelet / kubectl | 1.35.9 |
| containerd на проверенной ВМ | 2.2.1 |
| Helm | 3.18.6 |
| Flannel | 0.28.9 |
| Envoy Gateway | 1.9.2 |
| Gateway API | Поставляется с зафиксированным Helm-chart Envoy Gateway |
| Nginx | 1.28.0-alpine |
| Prometheus | 3.5.0 |
| Fluentd | 1.18.0-debian-1.0 |

Версии закреплены в config/versions.env и манифестах; версии Debian-пакетов сохраняются в `/etc/mts-devops/packages.txt`. Для установки нужны доступные внешние репозитории и registry. Теги образов могут изменяться у издателей.

## Требования

- Выделенная Ubuntu 24.04 amd64 с sudo и доступом в интернет.
- Проверенный стенд: 4 CPU, 4 ГБ RAM, 30 ГБ диска.
- Kubernetes создаётся на этой машине; существующие производственные кластеры не поддерживаются сценарием установки.
- Облачный аккаунт и коммерческий балансировщик не нужны.

## Установка

Для VirtualBox из Windows сначала выполните [подготовку ВМ](docs/virtualbox.md). На выделенной Ubuntu 24.04:

```bash
git clone --branch dev-mts-devops https://github.com/Rostyangrib/hakaton-MTS.git
cd hakaton-MTS
sudo ./bootstrap.sh
./deploy.sh
./verify.sh
```

На этапе разработки используется `dev-mts-devops`; перед сдачей проверенный результат должен находиться в `main`, а инструкция переключается на неё. Не выполняйте bootstrap на машине с чужим Kubernetes-кластером. Скрипт отказывается менять кластер без маркера проекта. Повторный запуск установки сохраняет существующий кластер.

Для поэтапной установки и диагностики доступны `./deploy.sh app`, затем `./deploy.sh gateway`, `./deploy.sh monitoring` и `./deploy.sh logging`. Вызов без аргументов устанавливает всё в этом порядке.

bootstrap создаёт кластер и сеть; deploy устанавливает компоненты; verify проверяет маршрут, метрики и доставку логов. Не запускайте несколько verify одновременно: используется локальный порт 19090.

## Проверка компонентов

- HTTP: `curl http://<IP-узла>:30080/`, ожидается `Hello World!` и код 200.
- Gateway API: ресурсы GatewayClass, Gateway, HTTPRoute, EnvoyProxy; входной Service имеет NodePort 30080.
- Prometheus: метрики прокси через `/stats/prometheus`, контроллера через `/metrics`; доступность, число запросов, HTTP-коды и время обработки.
- Fluentd: читает CRI-логи Nginx из `/var/log/containers`, сохраняет JSON в `/var/lib/mts-devops/logs/`.
- Полная проверка и команды диагностики: [docs/verification.md](docs/verification.md).

Метрики: `kubectl -n monitoring port-forward service/prometheus 19090:9090`, затем во втором терминале Ubuntu:

```bash
curl -sG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=up{job="envoy-proxy"}'
curl -sG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=sum(envoy_http_downstream_rq_total)'
```

Ожидаются `up=1` и рост счётчика после HTTP-запросов. Собираются также метрики контроллера и самого Prometheus.

Логи: запрос `curl http://<IP-узла>:30080/log-check` создаёт 404 с access/error-записями. Через 10 секунд выполните `kubectl -n logging exec daemonset/fluentd -- sh -c "grep log-check /collected/nginx*.log"`: ожидаются записи со stream stdout и stderr. Файлы сохраняются на диске Ubuntu; позиции чтения и буфер — в `/var/lib/mts-devops/fluentd/`.

## Дополнительные возможности

Две копии Nginx, readiness/liveness, запуск приложения без root с read-only файловой системой, CPU/RAM requests и limits, HTTP-метрики, автоматическая проверка маршрута и собранных access/error-логов.

Fluentd работает как root для чтения системных файлов, имеет read-only доступ к `/var/log`, отключённый токен ServiceAccount, запрет повышения привилегий и сброшенные capabilities. Prometheus получает права чтения только Pod в namespace контроллера. kubeconfig пользователя даёт административный доступ к выделенному стенду и не публикуется.

## Ограничения

- Один узел: отказ машины останавливает стенд.
- Две копии приложения показывают восстановление Pod, но не устойчивость к отказу узла.
- Логи сохраняются на узле; история Prometheus временная.
- В репозитории не должны находиться ключи, пароли, kubeconfig, ISO и диски ВМ.
- ВМ является средой проверки; экспертам предоставляются конфигурации и инструкции, а не образ ВМ.
