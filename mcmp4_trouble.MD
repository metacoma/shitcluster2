# Отчёт: поды на mcmp4 не имеют доступа к IPv4 185.199.x (github.io) — vless-туннель на той же ноде

> Дата: 2026-08-22
> Автор: диагностическая сессия (ArgoCD → GitHub network)
> Статус: root cause найден, решение предложено, НЕ применено
> Точка входа: `seed.mgmt.mansion.shitcluster.io` (jumphost), sudo без пароля, kubeconfig + kubectl.
> Роутер: 172.25.0.1 (OpenWRT, BusyBox, мало ресурсов — НЕ нагружать). Пароль: `secrets/vault_data.sops.yaml` → `vault_data.openwrt_router.ssh_password`.

---

## 1. Симптом (что наблюдалось)

**ArgoCD не мог генерировать манифесты** — почти все Application в статусе `Unknown` / `ComparisonError`.

Ошибки:
- `repo-server` (my-plugin): `kcl run` падал с `exit status 1`
- `kcl run` не мог скачать OCI-пакеты: `dial tcp 185.199.109.154:443: i/o timeout`
- `helm pull` таймаутил на `*.github.io`: `context deadline exceeded (Client.Timeout exceeded while awaiting headers)`

**Что именно недоступно:**

| Цель | IP | Маршрут на роутере | Из кластера |
|---|---|---|---|
| `github.com` | 140.82.x.x | default → `pppoe-wan` | ✅ работает |
| `*.github.io` (grafana.github.io, prometheus-community.github.io) | 185.199.x.x | **via 172.25.220.3** (vless-шлюз) | ❌ таймаут |
| `ghcr.io` → `pkg-containers.githubusercontent.com` | 185.199.x.x | via 172.25.220.3 | ❌ таймаут |
| `release-assets.githubusercontent.com` | 185.199.x.x | via 172.25.220.3 | ❌ таймаут |

Ключ: `github.io` / `pkg-containers` / `release-assets` — всё это `185.199.x.x` (GitHub Pages / GitHub CDN). Эти IP **попадают в anti-filter BGP-таблицу** (BIRD), поэтому роутер направляет их в **vless-шлюз** (172.25.220.3), а не в default.

---

## 2. Архитектура (контекст)

### 2.1 Сеть
- Роутер OpenWRT `usadba`: 172.24.0.1 (mgmt) / 172.25.0.1 (public), AS 64513 (Quagga bgpd).
- BIRD 172.24.0.19 (AS 64512) — импортирует anti-filter таблицу (45.154.73.71, AS 65432), экспортит роутеру.
- Роутер ставит kernel-роуты с nexthop в туннель (172.25.220.3).
- Кластер: Calico no-overlay, BGP с роутером. Ноды: mcmp2-9, mgmt IP 172.24.0.x.
- Ноды имеют br-public (172.25.255.x) и маршрутизируют внешний трафик через br-public (default via 172.25.0.1).

### 2.2 Vless-туннель (gitops/workloads/apps/vless_tunnel.k)
- NAD `vless-tunnel-public`: bridge-тип, мост br-public, IP **172.25.220.3/16**.
- sing-box конфиг: TUN `singtun` 10.70.0.1/24, `auto_route`, `strict_route`, `stack: system`; outbound vless → 172.233.47.9:443 (REALITY + XHTTP); route rule: private сети direct.
- Startup-скрипт (gateway mode):
  - `ip route add 10.233.0.0/16 via 169.254.1.1 dev eth0`
  - `ip route del default via 169.254.1.1` + `ip route add default via 172.25.0.1 dev public`
  - `ip rule add priority 100 to <server> lookup main` (vpn_nl в обход tun)
  - `sysctl ip_forward=1`, `iptables -t nat -A POSTROUTING -o singtun -j MASQUERADE`
  - `ip rule add priority 150 iif public lookup 2022` (forwarded-трафик с public → в tun)

### 2.3 Где запущен vless-tunnel под
```
kubectl -n network get pods -l app=vless-tunnel -o wide
vless-tunnel-7467bf6445-p6jxz   1/1 Running   10.233.66.160   mcmp4
```
**Vless-tunnel под запущен на mcmp4.**

---

## 3. Root cause (подтверждено)

**Поды на mcmp4 (где работает vless-tunnel под) НЕ имеют доступа к IPv4 185.199.x.**

| Нода | vless-tunnel под | src (br-public) | Доступ к IPv4 185.199.x |
|---|---|---|---|
| **mcmp4** | ✅ запущен | 172.25.255.110 | ❌ поды не имеют доступа |
| mcmp6 | — | 172.25.255.108 | ✅ поды имеют доступ (ArgoCD работает) |

### 3.1 Подтверждение (mcphub на mcmp4)
```
kubectl -n mcp exec mcphub-... -- curl -4 -sI -v https://grafana.github.io
*   Trying 185.199.108.153:443...   ← зависает, не может подключиться
```
mcphub (на mcmp4) не может достучаться до IPv4 185.199.x, но может через IPv6 (2606:50c0:: → default).

### 3.2 Что происходит с трафиком от mcmp4 vs mcmp6 в vless-поде

| Этап | mcmp4 (172.25.255.110) | mcmp6 (172.25.255.108) |
|---|---|---|
| Доходит до vless-пода (public RX) | ✅ +1025 | ✅ |
| Доходит до FORWARD | ✅ +2 пакета | ✅ |
| Доходит до POSTROUTING/MASQUERADE | ✅ +1 | ✅ |
| **Выходит через singtun (tun)** | ❌ OUTPUT=0 | ✅ |
| sing-box логирует 185.199.x | ❌ нет | ✅ `outbound/vless` |
| Итог | ❌ **не туннелируется** | ✅ туннелируется |

### 3.3 Механизм
**Трафик от mcmp4 (172.25.255.110) доходит до vless-пода, но НЕ доходит до tun** — пакет отбрасывается после POSTROUTING, до выхода через singtun.

**Причина:** Vless-tunnel под (172.25.220.3) и поды на mcmp4 (172.25.255.110) находятся **на одной ноде (mcmp4) и одном br-public**. Когда vless-под получает трафик от другого пода на своей же ноде, ядро обрабатывает его как "локальный" трафик (та же нода/подсеть) и **не маршрутизирует его в tun правильно** — пакет отбрасывается после POSTROUTING.

А трафик от mcmp6 (172.25.255.108) — это трафик от **другой ноды**, и vless-под маршрутизирует его в tun нормально.

Это объясняет наблюдение: **поды на ноде, где запущен туннелирующий под, не имеют доступа в интернет.**

---

## 4. Что было сделано (диагностика)

### 4.1 BGP-коннективность роутера с mcmp4 — рабочая
```
show bgp summary (Quagga vty, пароль zebra):
172.24.0.13  4 64512  Established  12:34:58  2   ← mcmp4
```
- BGP-сессия Established, mcmp4 анонсирует pod CIDR 10.233.66.128/26, роутер принимает (valid, best), устанавливает в kernel (proto zebra).
- Маршрут к 185.199.x через vless-шлюз есть (proto zebra, fib), ARP REACHABLE.
- **BGP НЕ является проблемой.**

### 4.2 Попытка фикса (вариант A): source_ip_cidr в sing-box
Добавлено правило:
```json
{"source_ip_cidr": ["172.25.255.0/24"], "outbound": "vless-out"}
```
- **Результат:** помог mcmp6 (172.25.255.108), но НЕ mcmp4 (172.25.255.110). Причина — трафик от mcmp4 не доходит до tun (отбрасывается на роутере/ядре), поэтому route-правило sing-box не имеет значения.
- **Важно:** фикс был **перезаписан ArgoCD self-heal** (ConfigMap управляется через gitops). Для постоянного решения нужно вносить изменения в `gitops/workloads/apps/vless_tunnel.k`.

### 4.3 Текущее состояние ArgoCD
- **ArgoCD работает** (workloads Synced, KCL run OK, helm pull OK) — потому что его поды живут на **mcmp6**, которая может достучаться до 185.199.x.
- Остались OutOfSync/Unknown: `infra` (Tekton CRDs), `istiod`, `knative-operator`, `grafana-mcp` — не сетевые проблемы, а расхождения версий/дубликаты ресурсов.

---

## 5. Что следует сделать (решение)

### Вариант 1 (рекомендуемый): Переместить vless-tunnel под на другую ноду
Чтобы vless-под не обрабатывал трафик от своей же ноды. Добавить в `gitops/workloads/apps/vless_tunnel.k`:
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: NotIn
          values: [mcmp4]   # или список нод, где не должно быть vless-пода
```
После изменения — редеплой vless-tunnel пода, проверить, что он переехал на другую ноду, и что поды на mcmp4 получили доступ к 185.199.x.

### Вариант 2: Разобраться, почему ядро не маршрутизирует трафик от своей ноды в tun
Нужно понять, почему пакет от 172.25.255.110 (та же нода) не выходит через singtun. Гипотезы:
- Ядро считает src=172.25.255.110 "локальным" для vless-пода (172.25.220.3/16).
- MASQUERADE не применяется к трафику от mcmp4 (нет conntrack записи).
- Пакет отбрасывается после POSTROUTING, до tun.

### Вариант 3: Добавить source_ip_cidr правило в gitops
Внести `source_ip_cidr: ["172.25.255.0/24"] → vless-out` в `vless_tunnel.k` (чтобы не перезаписывалось ArgoCD). Но это не решает, если трафик от mcmp4 не доходит до tun.

---

## 6. Ключевые команды диагностики

```bash
# где vless-tunnel под
kubectl -n network get pods -l app=vless-tunnel -o wide

# маршрут роутера для 185.199.x
ssh root@172.25.0.1 'ip route get 185.199.110.133'

# BGP summary роутера (пароль zebra)
ssh root@172.25.0.1 '(echo zebra; sleep 1; echo show bgp summary; sleep 3; echo quit) | nc 127.0.0.1 2605'

# tcpdump на роутере (SYN/RST от нод)
ssh root@172.25.0.1 'tcpdump -i br-PUBLIC -nn host 185.199.110.133'

# sing-box логи (туннелируется ли трафик)
kubectl -n network logs vless-tunnel-<pod> | grep 185.199

# mcphub (на mcmp4) тест IPv4 185.199.x
kubectl -n mcp exec mcphub-<pod> -- curl -4 -sI -v https://grafana.github.io

# vless-под: правила и маршруты
kubectl -n network exec vless-tunnel-<pod> -- ip rule show
kubectl -n network exec vless-tunnel-<pod> -- ip route show table 2022

# vless-под: счётчики (public RX, tun RX, FORWARD, POSTROUTING, OUTPUT)
kubectl -n network exec vless-tunnel-<pod> -- sh -c "cat /sys/class/net/public/statistics/rx_packets"
kubectl -n network exec vless-tunnel-<pod> -- sh -c "cat /sys/class/net/singtun/statistics/rx_packets"
kubectl -n network exec vless-tunnel-<pod> -- iptables -L FORWARD -n -v
kubectl -n network exec vless-tunnel-<pod> -- iptables -t nat -L POSTROUTING -n -v
kubectl -n network exec vless-tunnel-<pod> -- iptables -L OUTPUT -n -v
```

---

## 7. Важные замечания

1. **Роутер (172.25.0.1) — слабая железка (OpenWRT, BusyBox).** Не запускать тяжёлые команды, не делать `network restart` (пропадёт связь с кластером и LLM). Только `firewall reload` при необходимости.
2. **ArgoCD self-heal перезаписывает ConfigMap.** Любые изменения в `singbox-config` нужно вносить в gitops (`vless_tunnel.k`), иначе они будут перезаписаны.
3. **`source_ip_cidr` правило было перезаписано ArgoCD.** Текущий sing-box config — только `ip_cidr` direct-правило.
4. **BGP-коннективность роутера с mcmp4 рабочая** — проблема не в BGP.
5. **mcmp6 работает** (ArgoCD), **mcmp4 не работает** (поды на mcmp4). Разница — vless-tunnel под на mcmp4.
