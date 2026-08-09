# Журнал работ: 2026-08-09 — opencode-agent модель и mattermost-bridge

## Задача

Пользователь попросил:
1. Переключить `opencode-agent-k8s` с `deepseek-v4-flash-q3` на `qwen36-27b` через локальный litellm
2. Отладить `opencode-mattermost-bridge` — бот в Mattermost отвечал моделью `big-pickle` (облачная встроенная) вместо локальной `qwen36-27b`

## Окружение

### Компоненты
| Компонент | Образ | Нода | Статус |
|---|---|---|---|
| opencode-agent-k8s | `ghcr.io/metacoma/opencode-agent-k8s:a4499854b5df0ba7ba2cb44be01b79aaa0e9785f` | mcmp4 | Running 1/1 |
| opencode-mattermost-bridge | `lbecchi/opencode-chat-bridge:latest` | mcmp4 | Running 1/1 |
| litellm | in-cluster | mcmp6 | Running 1/1 |

### Стек
- **LiteLLM**: `https://litellm.mansion.metacoma.org/v1` (in-cluster, master key в Vault `kv/litellm#master_key`)
- **Доступные модели на LiteLLM**: `qwen36-27b`, `qwen36-27b-uncensored`, `qwen36-35b`, `qwen36-35b-heretic`, `gemma4-31b`, `deepseek-v4-flash-q3`, `step-37-flash`, `glm-45-air`, `laguna-*`
- **PVC**: `opencode-agent-data` (20Gi, RWO, longhorn) — шарится между agent и bridge
- **GitOps**: ArgoCD app `workloads` → `gitops/workloads` → KCL CMP plugin `kcl-v1.0` → vals eval (Vault refs)
- **Opencode версия**: 1.18.15

### Архитектура bridge
```
Mattermost WS → bridge (bun connectors/mattermost.ts)
  → ACP client (spawn /root/.opencode/bin/opencode acp)
    → opencode читает config из /root/.config/opencode/opencode.json
      → provider.litellm → @ai-sdk/openai-compatible npm plugin
        → LiteLLM API → qwen36-27b
```

## Что сделано

### Шаг 1: Переключение модели opencode-agent (PR #128)
- **Файл**: `gitops/workloads/config.k`
- **Изменение**: `model = "openai/deepseek-v4-flash-q3"` → `model = "openai/qwen36-27b"`
- **Коммит**: `db3281d`
- **Результат**: `OPENCODE_MODEL_ID: openai/qwen36-27b` в env var агента

### Шаг 2: RWO PVC дедлок (PR #129)
- **Проблема**: EIO error при `mkdir '/data/sessions'` — bridge (mcmp6) и agent (mcmp4) на разных нодах, один RWO PVC
- **Файл**: `gitops/workloads/apps/opencode_mattermost_bridge.k`
- **Решение**: `podAffinity.requiredDuringSchedulingIgnoredDuringExecution` → bridge всегда на той же ноде, что и agent
- **Коммит**: `0770fe7`

### Шаг 3: Добавление provider config в opencode.json (PR #130)
- **Проблема**: `opencode.json` бриджа содержал только `agent` (permissions), без `provider` секции. Opencode не знал как подключиться к litellm → fallback на встроенную модель `big-pickle`
- **Файл**: `gitops/workloads/apps/opencode_mattermost_bridge.k`
- **Изменения**:
  - Добавил `provider.litellm` с `baseURL`, `apiKey` (`ref+vault://kv/litellm#master_key`), `models`
  - Перенёс `opencode.json` из ConfigMap в Secret (содержит API ключ)
  - Volume mount: `bridge-config` → `bridge-secrets`
- **Коммит**: `445d0c8`

### Шаг 4: Явная модель в agent config
- **Проблема**: Даже с provider config, opencode выбирал первую модель из списка (`qwen36-35b`) вместо `qwen36-27b`
- **Решение**: `"model": "litellm/openai/qwen36-27b"` в `agent.chat-bridge`
- **Формат**: `provider/model` (не просто `openai/qwen36-27b` — это вызывало ошибку)
- **Коммит**: `1d9ec4f`

### Шаг 5: Установка @ai-sdk/openai-compatible плагина
- **Проблема**: Даже с правильным конфигом, opencode всё равно использовал `big-pickle`. Root cause: npm пакет `@ai-sdk/openai-compatible` не был установлен в контейнере. Opencode не мог загрузить провайдер → fallback на встроенную модель.
- **Решение**: Оверрайд entrypoint контейнера:
  ```sh
  if [ ! -f /root/.opencode/bin/opencode ]; then
    curl -fsSL https://opencode.ai/install | bash
  fi
  mkdir -p /root/.config/opencode && \
    cd /root/.config/opencode && \
    /root/.opencode/bin/opencode plugin @ai-sdk/openai-compatible </dev/null && \
    cd /app && \
    exec bun connectors/mattermost.ts
  ```
- **Итерации**:
  1. `2fcdc67` — первый вариант (ошибка: `/root/.config/opencode` не существует при первом старте)
  2. `b730b9c` — добавил `mkdir -p` (ошибка: `cd` всё равно не работал из-за формата multiline в KCL)
  3. `9bac9ed` — финальный вариант: `mkdir -p` + `cd /app` перед `exec bun`
- **Коммит**: `9bac9ed`

## Нюансы и проблемы

### 1. Opencode читает config из глобального каталога
- Бридж копирует `/app/opencode.json` → сессию через `copyIfNewer()`
- Но opencode в ACP режиме (`opencode acp`) читает config из `/root/.config/opencode/opencode.json`
- Энтрипоинт образа копирует `/app/opencode.json` → `/root/.config/opencode/opencode.json` при старте
- **Важно**: при каждом рестарте пода глобальный конфиг перезаписывается из `/app/opencode.json`

### 2. Формат модели в agent config
- Рабочий формат: `"model": "litellm/openai/qwen36-27b"` (provider/model)
- Не работает: `"model": "openai/qwen36-27b"` (UnknownError)
- Не работает: `"model": "litellm/openai/qwen36-27b"` в `provider.litellm` (игнорируется)
- Модель задаётся в `agent.<name>.model`, а не в `provider.<name>.model`

### 3. @ai-sdk/openai-compatible — обязательный npm плагин
- Без него opencode не может загрузить кастомный провайдер
- Устанавливается через `opencode plugin @ai-sdk/openai-compatible`
- Устанавливается в `/root/.cache/opencode/packages/@ai-sdk/openai-compatible@latest/`
- Конфиг плагина пишется в `/root/.config/opencode/.opencode/opencode.json`

### 4. RWO PVC дедлок при rolling update
- Agent и bridge шарят один PVC `opencode-agent-data` (RWO)
- Rolling update: новый под не стартует (PVC занят старым), старый не убивается (maxUnavailable=25%)
- Решение: `podAffinity` держит их на одной ноде + ручное удаление старого пода при обновлении
- **Альтернатива на будущее**: RWX PVC или отдельный PVC для сессий bridge

### 5. KCL multiline strings
- В KCL нельзя использовать `+` для конкатенации строк в массиве
- Решение: вынести в отдельную переменную `_bridge_startup_cmd`

## Итоговое состояние

| Компонент | Статус | Модель |
|---|---|---|
| opencode-agent-k8s | Running 1/1 (mcmp4) | `openai/qwen36-27b` |
| opencode-mattermost-bridge | Running 1/1 (mcmp4) | `litellm/openai/qwen36-27b` |
| ArgoCD workloads | Synced, Healthy | Rev: `9bac9ed13d` |

### Финальный opencode.json (в Secret)
```json
{
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM",
      "options": {
        "baseURL": "https://litellm.mansion.metacoma.org/v1",
        "apiKey": "ref+vault://kv/litellm#master_key"
      },
      "models": {
        "openai/qwen36-27b": { "name": "Qwen 3.6 27B" },
        "openai/qwen36-35b": { "name": "Qwen 3.6 35B" },
        "openai/gemma4-31b": { "name": "Gemma 4 31B" },
        "openai/deepseek-v4-flash-q3": { "name": "DeepSeek V4 Flash Q3" }
      }
    }
  },
  "default_agent": "chat-bridge",
  "agent": {
    "chat-bridge": {
      "model": "litellm/openai/qwen36-27b",
      "mode": "primary",
      "permission": { "read": "allow", "edit": "allow", "write": "allow", "bash": "allow", "glob": "allow", "grep": "allow", "task": "allow" }
    }
  }
}
```

### Коммиты (master)
```
9bac9ed fix(opencode-mattermost-bridge): cd /app before starting connector
b730b9c fix(opencode-mattermost-bridge): mkdir -p before cd in startup cmd
2fcdc67 fix(opencode-mattermost-bridge): install @ai-sdk/openai-compatible plugin at startup
1d9ec4f fix(opencode-mattermost-bridge): set explicit model in agent config
445d0c8 fix(opencode-mattermost-bridge): add litellm provider config to opencode.json (#130)
0770fe7 fix(opencode-mattermost-bridge): add podAffinity to share node with agent (RWO PVC) (#129)
db3281d feat(opencode-agent): switch default model to qwen36-27b (#128)
```

## Дальнейшие шаги

1. **Протестировать в Mattermost** — написать боту и убедиться, что отвечает qwen36-27b (не big-pickle)
2. **Рассмотреть RWX PVC** или отдельный PVC для bridge сессий — чтобы избежать дедлоков при rolling update
3. **Добавить healthcheck** для bridge — сейчас нет readiness probe, pod считается ready сразу
4. **Опционально**: добавить `opencode-mattermost-bridge` в `config.k` как отдельный блок (сейчас только `app = cfg.config.opencode_mattermost_bridge` без полных настроек)
