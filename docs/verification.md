# Проверка стенда

Команды выполняются на Ubuntu после bootstrap и deploy с kubeconfig текущего пользователя. Скрипт `./verify.sh` проверяет приложение, Gateway API, метрики и собранные логи. После десяти HTTP 200 и одного 404 он ожидает прирост счётчиков 2xx минимум на 10, 4xx минимум на 1 и числа измерений latency минимум на 11; сумма длительностей не должна уменьшаться. Выводится среднее время по новым измерениям в миллисекундах, включая возможный фоновый трафик. Проверка прекращается при первом сбое и возвращает ненулевой код.

## Приложение и Gateway API

```bash
kubectl get nodes
kubectl -n demo get pods,service,gateway,httproute
kubectl get gatewayclass mts-envoy
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -i "http://$NODE_IP:30080/"
```

Ожидаются Ready узел, две готовые копии Nginx, принятые GatewayClass и HTTPRoute, Gateway с Programmed=True. HTTP-запрос возвращает 200 и `Hello World!`. Из Windows с NAT из инструкции: `curl.exe -i http://127.0.0.1:8080/`.

## Метрики

```bash
kubectl -n monitoring port-forward service/prometheus 19090:9090
```

Во втором терминале Ubuntu:

```bash
curl -sG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=up{job="envoy-proxy"}'
curl -sG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=sum(envoy_http_downstream_rq_total)'
curl -sG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=sum by (envoy_response_code_class) (envoy_http_downstream_rq_xx)'
curl -sG http://127.0.0.1:19090/api/v1/query --data-urlencode 'query=sum(rate(envoy_http_downstream_rq_time_sum[5m])) / sum(rate(envoy_http_downstream_rq_time_count[5m]))'
```

`up` должен быть равен 1. Счётчик запросов растёт после HTTP-запросов. Указанные серии подтверждены на запущенном релизе; средняя длительность выражается в миллисекундах, rate требует нескольких измерений и трафика. Обнуление счётчика после перезапуска прокси ожидаемо.

Для интерфейса из Windows создайте SSH-туннель `ssh -i .local/vm_ed25519 -p 2222 -L 19090:127.0.0.1:19090 mts@127.0.0.1`, оставив port-forward на Ubuntu, и откройте http://127.0.0.1:19090. Prometheus не публикуется через NodePort.

## Логи

```bash
MARKER="manual-check-$(date +%s)"
curl -i "http://$NODE_IP:30080/$MARKER"
sleep 10
kubectl -n logging exec daemonset/fluentd -- sh -c "grep '$MARKER' /collected/nginx*.log"
```

Несуществующий файл возвращает 404. В JSON-записях ожидаются обе разновидности: `stream=stdout` с access-записью и `stream=stderr` с ошибкой отсутствующего файла. Записи содержат имя Pod, узел, namespace и путь исходного контейнерного лога.

Итоговые файлы находятся на Ubuntu в `/var/lib/mts-devops/logs/`, позиции чтения и буфер — `/var/lib/mts-devops/fluentd/`. Ротация выполняется системным logrotate ежедневно с семью архивами; `maxsize 10M` проверяется в момент запуска logrotate, а не непрерывно. Схема рассчитана на демонстрационный объём трафика.

## Повторная установка и восстановление

```bash
sudo ./bootstrap.sh
./deploy.sh
./verify.sh
kubectl -n demo delete pod "$(kubectl -n demo get pods -l app=nginx -o jsonpath='{.items[0].metadata.name}')"
kubectl -n demo rollout status deployment/nginx --timeout=120s
./verify.sh
```

После перезагрузки Ubuntu дождитесь готовности API (`kubectl get nodes`), затем выполните `./verify.sh`. Дополнительно воспроизведите установку на снимке чистой Ubuntu. Не используйте `kubeadm reset` для проверки идемпотентности — это уничтожает кластер и является другим сценарием.

## Диагностика

```bash
kubectl get pods -A
kubectl -n demo describe gateway demo
kubectl -n demo describe httproute nginx
kubectl -n envoy-gateway-system logs deployment/envoy-gateway --tail=100
kubectl -n monitoring logs deployment/prometheus --tail=100
kubectl -n logging logs daemonset/fluentd --tail=100
sudo journalctl -u kubelet -n 100 --no-pager
```

Не публикуйте kubeconfig, приватные ключи и полный вывод конфигураций с секретами.
