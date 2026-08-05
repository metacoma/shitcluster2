# Миграция BIRD (hw0076) в Kubernetes namespace `network`

Статус: план (v2, обновлён по уточнениям). Дата: 2026-08-05.

## Уточнения пользователя (учтены)
1. Архитектурная схема — верна, переносим как есть.
2. **Pod получает НОВЫЙ IP из management-сети** (172.24.0.0/16) через Multus NAD — не занимаем 172.25.0.2.
3. **BIND (named) НЕ трогаем** — остаётся на hw0076 как есть, переносим только сервис bird.
4. **Образ**: использовать готовый `pierky/bird:2.15` (проверен: Debian 12, BIRD 2.15 — совпадает с установленным).
5. Статический маршрут `llama3` — **удаляем**.

---

## 1. Инспекция текущей конфигурации (`/etc/bird` на hw0076)

### Хост
- `hw0076.mgmt.mansion.shitcluster.io` — выделенный management-хост (не k8s-нода).
- BIRD 2.15.1 (пакет `bird2` 2.15.1-cznic.1~jammy), systemd `bird.service` (enabled, user `bird`).
- Интерфейсы: `br-public` 172.25.0.2/16 (основной), `br-management` 172.24.0.2/16,
  `br-internet` 172.28.0.2/16, `br-iot` 172.29.0.2/16, `br-private` 172.26.0.2/16,
  `br-san` 172.27.0.2/16, `br0` 172.23.0.2/16.
- Default route: `via 172.25.0.1` (mikrotik). `net.ipv4.ip_forward = 1`.
- BIND (`named`) слушает `172.25.0.2:53` — **НЕ переносится и НЕ изменяется**.

### Протоколы BIRD (`/etc/bird/bird.conf`)
| Протокол | Роль |
|---|---|
| `device1` | scan time 5 |
| `direct1` | disabled |
| `kernel1` (IPv4) | `export all` — заливает всё в kernel (16801 маршрутов) |
| `kernel2` (IPv6) | `export all` |
| `static1` | пустой (default IPv4) |
| ~22 named static | пины под конкретные сервисы, почти все `via 172.25.220.2` |
| BGP `mikrotik` | local `172.25.0.2` AS 64512, neighbor `172.25.0.1` AS 64513, hold 90; IPv4 import reject / export accept (отдаёт mikrotik'у всю таблицу) |
| BGP `antifilter` | local AS 65542, neighbor `45.154.73.71` AS 65432, multihop, hold 240; IPv4 import all c `gw=172.25.220.2`, reject `2.56.206.0/24`; export reject |

### Статические пины (via 172.25.220.2, кроме отмеченных)
`goodreads`, `hrsg_nl`, `chatgpt`, `opentofu`, `terraform`, `backpackinglight`,
`hashicorp`, `challenges_cloudflare_com`, `cdn_auth0_com`, `login_docker_com`,
`docker_hub`, `youtube`, `zulip`, `images_tuyacn_com`, `discord`, `jsom`, `telegram`,
`librechat`, `openwebui`, `lichess_static_routes` — всё через NL-туннель.

Исключения:
- `twitch_hls`, `www_alpinelinux_org` — `via "br-public"` напрямую.
- `llama3` — `192.168.111.1/32 via "llama3"` — **УДАЛЯЕТСЯ** (интерфейс отсутствует, маршрут мёртвый).

### Смысл схемы
BIRD на hw0076 — анти-фильтрационный роутер:
1. Учит полную таблицу у пира `antifilter` (45.154.73.71).
2. Переписывает next-hop всех маршрутов на `172.25.220.2` — IP **ssh-tunnel-nl0 pod** (NL VPN) в namespace `network`.
3. Экспортирует всё в mikrotik (172.25.0.1), дефолтный шлюз кластера.
4. Итог: `клиент → mikrotik → 172.25.0.2 (BIRD) → 172.25.220.2 (ssh-tunnel NL) → интернет без фильтрации`.

Проверки: mikrotik/antifilter `Established`; 16801 routes / 16787 networks; пир 45.154.73.71
в ядре идёт `via 172.25.0.1` (петли нет).

## 2. Целевая архитектура в k8s (v2)

Pod `bird` в namespace `network` (replicas: 1), **без hostNetwork**.

### Сеть (Multus NAD) — НОВОЕ
- NAD `bird-public` → **`br-management`** (management-сеть, а не public!):
  ```json
  {
    "cniVersion": "0.3.1",
    "type": "bridge",
    "bridge": "br-management",
    "hairpinMode": true,
    "ipam": {
      "type": "static",
      "addresses": [{"address": "172.24.0.19/16", "gateway": "172.24.0.1"}]
    }
  }
  ```
- Выбранный IP: **`172.24.0.19/16`** (проверен свободным; заняты: .1 mikrotik/OpenWrt, .2 BIND,
  .10-.18 ноды, .48 kube-vip, .28; 172.24.1.2 cert-manager NAD, 172.24.1.3 spaceship NAD;
  MetalLB пулы 172.24.1.0/25 и 172.24.1.128/25 — не трогаем).
- Gateway: `172.24.0.1` (mikrotik, тот же MAC что 172.25.0.1 — единое устройство, есть L2).

### Почему management-сеть
- Не конфликтуем с BIND на 172.25.0.2 (уточнение #3).
- BGP-пиры mikrotik (172.24.0.1/172.25.0.1) и туннель (172.25.220.2) достижимы из
  management: проверено `ip route get ... from 172.24.0.2` и пинги с mcmp4.
- IP не в MetalLB-пулах, не в kube-vip, не в occupied.

### Образ (уточнение #4)
- **Готовый `pierky/bird:2.15`** — проверен локально:
  - Debian GNU/Linux 12 (bookworm), BIRD version 2.15 (совпадает с 2.15.1 на хосте).
  - Содержит `bird`, `birdc`, `birdcl` в `/usr/local/sbin`.
  - НЕТ `ip`/`sysctl`/`iproute2` — нужен небольшой оверлей или initContainer.
- Доп. пакеты нужны: `iproute2` (для `ip route` в командной строке запуска),
  `iputils-ping`, `procps` (опционально). Варианты:
  - **A (рекомендуется):** маленький Dockerfile поверх `pierky/bird:2.15`:
    ```dockerfile
    FROM pierky/bird:2.15
    RUN apt-get update && apt-get install -y --no-install-recommends \
        iproute2 iputils-ping procps ca-certificates \
        && rm -rf /var/lib/apt/lists/*
    ```
    → `ghcr.io/metacoma/bird:2.15` (паттерн репо — `ghcr.io/metacoma/*`).
  - B: initContainer `nicolaka/netshoot` (как в ssh_tunnel) для sysctl, main — pierky/bird.
- Использовать `pierky/bird:2.15` как базовый — версия 2.15, проверено.

### Как BIRD работает в pod (без hostNetwork)
- NAD-интерфейс `public` на `br-management` с IP 172.24.0.19.
- `kernel1/kernel2 export all` → пишет маршруты **в таблицу POD-а** (не хоста!).
- Pod форвардит сам: `sysctl net.ipv4.ip_forward=1` в pod netns.
- BGP mikrotik: local станет `172.24.0.19` (router id — тоже 172.24.0.19).
- BGP antifilter (multihop): default route в pod → `via 172.24.0.1` (mikrotik), пир достижим.
- Статические пины `via 172.25.220.2` — маршрут к 172.25.220.2 через gateway 172.24.0.1.
- Таблица ноды и Calico не затрагиваются.

### Критичное изменение для BGP-пиринга (ВАЖНО)
Сейчас mikrotik настроен на пира **172.25.0.2** (local на hw0076). После переноса BIRD
придёт с **172.24.0.19** — значит:
1. BIRD-сторона: `local 172.24.0.19 as 64512` в bird.conf (правится в ConfigMap).
2. **Mikrotik-сторона**: обновить BGP-пир на 172.24.0.19 (у mikrotik открыт SSH :22,
   доступ есть). Пока mikrotik не обновлён — BGP-сессия mikrotik не поднимется.
   (antifilter-пир multihop — проверка, не привязан ли к 172.25.0.2; если привязан —
   согласовать новый источник или оставить как есть после проверки.)

## 3. Шаги

### 3.1 Конфиг BIRD → ConfigMap
- Взять `/etc/bird/bird.conf` за основу. Правки:
  - `router id 172.24.0.19;`
  - BGP mikrotik: `local 172.24.0.19 as 64512;`
  - `llama3` static — **удалить** (уточнение #5).
  - Остальное без изменений: `kernel1/kernel2 export all`, статические пины,
    BGP antifilter (`local as 65542`, `neighbor 45.154.73.71 as 65432`, `multihop`).
- Пароль BGP закомментирован — секретов нет; если вводить — через Vault (`ref+vault://`).

### 3.2 Образ
- Базовый `pierky/bird:2.15` (готовый, проверен) + Dockerfile-оверлей с iproute2.
- Публикация: `ghcr.io/metacoma/bird:2.15`.

### 3.3 KCL-манифесты — `gitops/workloads/apps/bird.k` (по паттерну ssh_tunnel.k)
1. **NAD `bird-management`** (namespace `network`): bridge на `br-management`,
   static `172.24.0.19/16`, gateway `172.24.0.1`.
2. **ConfigMap `bird-conf`** — bird.conf из §3.1, mount в `/etc/bird/bird.conf`.
3. **Deployment `bird`** (replicas=1):
   - annotation `k8s.v1.cni.cncf.io/networks` → NAD (interface `public`);
   - `dnsPolicy: None`, `dnsConfig.nameservers: ["172.24.0.1"]`;
   - `nodeSelector: worker` (любая нода с br-management; все ноды имеют);
   - `securityContext: { privileged: true, capabilities: {add: [NET_ADMIN, NET_RAW, SYS_ADMIN]} }`;
   - command: `sh -c "sysctl -w net.ipv4.ip_forward=1 && bird -f -c /etc/bird/bird.conf"`;
   - liveness/readiness: `birdc ping` / `birdc show status`.

### 3.4 config.k / main.k
- `config.k`: секция `bird = { namespace = "network", image = "ghcr.io/metacoma/bird:2.15", ip = "172.24.0.19" }`.
- `main.k`: `import .apps.bird as bird`, добавить `bird.manifests` в `resources`.
- Валидация: `cd gitops/workloads && kcl run .` (скилл `kcl-validate`).

### 3.5 Обновить mikrotik (внешний шаг, SSH :22 доступен)
- BGP-пир: `172.25.0.2` → `172.24.0.19` (или добавить новый пир до cutover, чтобы
  было окно параллельной работы старого и нового BIRD).
- После cutover — убрать старый пир 172.25.0.2.

### 3.6 Деплой и cutover
1. Push → PR → merge → ArgoCD sync (`workloads`).
2. Проверка в кластере:
   - `kubectl -n network get pod bird` — Running;
   - `kubectl -n network exec bird -- birdc show protocols` — mikrotik/antifilter `Established`;
   - `birdc show route count` — ~16801;
   - `ip route | wc -l` — маршруты в pod netns;
   - с mcmp4: `ping 172.24.0.19` — отвечает pod; трафик mikrotik → 172.24.0.19 → 172.25.220.2.
3. Отключить BIRD на hw0076: `sudo systemctl stop bird && sudo systemctl disable bird`.
   - 172.25.0.2 на hw0076 **остаётся** (там BIND — не трогаем).
   - Маршруты proto bird уйдут из таблицы хоста автоматически.

### 3.7 Rollback
- `sudo systemctl enable --now bird` на hw0076 (BGP-пир 172.25.0.2 на mikrotik ещё
  актуален, пока не удалён), в ArgoCD — revert PR.

## 4. Риски и решения

| Риск | Решение |
|---|---|
| BGP mikrotik не поднимется, пока пир не обновлён | Шаг 3.5 обязателен; окно параллельной работы (добавить пир заранее) |
| Antifilter multihop привязан к 172.25.0.2 | Проверить на провайдере; при необходимости согласовать источник/новый IP |
| Маршрут к 172.25.220.2 (туннель) из management | Gateway 172.24.0.1 маршрутизирует в 172.25.0.0/16 (проверено ping'ами с mcmp4) |
| 16k маршрутов в pod netns | Нормально; память/таблицы pod'а достаточны |
| Нет `ip`/`sysctl` в pierky/bird | Dockerfile-оверлей (iproute2) или initContainer netshoot |
| BIND (172.25.0.2) | НЕ трогаем; dnsConfig приложений не меняется |
| Секреты BGP | Сейчас нет; при вводе — Vault + vals |
| Мониторинг | Опционально: birdc-exporter / VMServiceScrape; вне скоупа |

## 5. Что НЕ переносится
- BIND (`named`) — остаётся на hw0076 на 172.25.0.2 без изменений.
- `br-*` мосты, docker-мосты, vnet — остаются на хосте.
- `twitch_hls`/`www_alpinelinux_org` (`via "br-public"`) — конвертируются в `via`
  на NAD-интерфейс pod-а (тот же br-management/gateway путь).

## 6. Файлы, которые появятся/изменятся
- Новые: `gitops/workloads/apps/bird.k`, Dockerfile для bird (в `misc/` или отдельном репо),
  `misc/bird-migration-plan.md` (этот).
- Изменённые: `gitops/workloads/config.k`, `gitops/workloads/main.k`.
- Внешние: mikrotik BGP-пир (172.25.0.2 → 172.24.0.19).
