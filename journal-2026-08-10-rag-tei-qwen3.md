# Журнал работ: 2026-08-10 — RAG индексация репозитория rnd-service (TEI + Qwen3-Embedding)

## Задача

Настроить RAG-индексацию Ansible-репозитория `/tmp/rnd-service` (22K файлов, 942MB) на сервере mcmp10 для семантического поиска по коду и конфигам.

## Что сделано

### 1. Анализ сервера (mcmp10)

```bash
ssh bebebeka@mcmp10.mgmt.mansion.shitcluster.io
nvidia-smi
```

- **GPU**: NVIDIA RTX 4090 (48 GB)
- **Текущий процесс**: `llama-server` (qwen36-27b) — 41.5 GB VRAM
- **Свободно**: ~5.9 GB

### 2. Анализ репозитория `/tmp/rnd-service`

```bash
find /tmp/rnd-service -type f | wc -l        # 22164 файла
du -sh /tmp/rnd-service                       # 942 MB
find /tmp/rnd-service -type f -name '*.yml' | wc -l   # 13237
find /tmp/rnd-service -type f -name '*.j2' | wc -l    # 1809
find /tmp/rnd-service -type f -name '*.py' | wc -l    # 342
find /tmp/rnd-service -type f -name '*.sh' | wc -l    # 1087
```

**Состав**: Ansible-репозиторий (roles, playbooks, group_vars, host_vars). Основные форматы: YAML (13K), Jinja2 (1.8K), Shell (1K), Python (342). Бинарники (~800MB) пропускаются.

### 3. Выбор модели (исследование)

Сравнение на бенчмарках:

| Модель | MTEB English | MMTEB | Контекст | VRAM (FP16) |
|---|---|---|---|---|
| **Qwen3-Embedding-0.6B** | **70.70** | **64.33** | 32K | ~1.2 GB |
| BGE-M3 | 59.56 | 59.56 | 8K | ~1.1 GB |

**Выбор**: Qwen3-Embedding-0.6B (+18.7% на retrieval, 32K контекст, влезает в 5.9 GB)

### 4. Скачивание модели

```bash
# На mcmp10 (требует sudo — /var/lib/llama-cpp/models принадлежит root)
sudo hf download Qwen/Qwen3-Embedding-0.6B --local-dir /var/lib/llama-cpp/models/Qwen3-Embedding-0.6B
```

**Результат**: 12 файлов, 1.2 GB (`model.safetensors` — 1.19 GB)

### 5. Добавление сервиса в docker-compose.yml

Файл: `/var/lib/llama-cpp/docker-compose.yml`

```yaml
  tei-embedding:
    image: ghcr.io/huggingface/text-embeddings-inference:89-1.9
    container_name: tei-embedding
    restart: unless-stopped

    ports:
      - "8089:80"

    gpus:
      - driver: nvidia
        device_ids:
          - GPU-73118adb-af33-d14c-1b49-6ea7e4827c27
        capabilities:
          - gpu

    volumes:
      - /var/lib/llama-cpp/models:/models:ro

    environment:
      NVIDIA_DRIVER_CAPABILITIES: compute,utility
      HUGGINGFACE_HUB_CACHE: /tmp/hf-cache

    command:
      - --model-id
      - /models/Qwen3-Embedding-0.6B
      - --dtype
      - float16
      - --hostname
      - 0.0.0.0
      - --port
      - "80"
      - --max-batch-tokens
      - "4096"
      - --max-client-batch-size
      - "32"
      - --max-concurrent-requests
      - "512"
      - --json-output

    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:80/health"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s
```

**Почему 89-1.9**: RTX 4090 = Ada Lovelace (compute 8.9)

**Почему batch 4096 / 32**: При 5.9 GB свободного VRAM — безопасно (~2.6 GB потребление). С 16384/128 был бы риск OOM.

### 6. Запуск

```bash
# Pull образа (8.17 GB, медленно — ~10 минут)
sudo docker pull ghcr.io/huggingface/text-embeddings-inference:89-1.9

# Запуск через compose
sudo docker compose -f /var/lib/llama-cpp/docker-compose.yml up -d tei-embedding

# Проверка
sudo docker ps --filter name=tei-embedding
sudo docker logs tei-embedding | tail -5
```

## Нюансы и проблемы

### 1. `hf download` без sudo падает с PermissionError

`/var/lib/llama-cpp/models` принадлежит root. Нужно `sudo hf download ...` или `echo "pass" | sudo -S hf download ...`

### 2. TEI ≠ отдельная модель

TEI (Text Embeddings Inference) — это HTTP-сервер от HuggingFace, который крутит embedding-модели. Qwen3-Embedding-0.6B — сама модель. TEI нужен для API (POST /embed → вектор).

### 3. VRAM-ограничения при работающем qwen36-27b

Qwen36 занимает 41.5 GB. TEI + Qwen3-Embedding берёт ~2.6 GB. Итого 44.1/48 GB. Если qwen36 начнёт обрабатывать длинный запрос — возможен OOM. Для индексации лучше остановить LLM-сервисы.

### 4. Медленный pull образа TEI

Образ 8.17 GB, pull шёл ~10 минут через nohup в фоне. SSH-сессия обрывалась по таймауту.

### 5. Архитектура RAG

```
/tmp/rnd-service (22K файлов)
  → ЧАНКИНГ (разбивка на 256-512 токенов с overlap)
    → TEI (Qwen3-Embedding-0.6B, порт 8089) → векторы [1024 float]
      → Qdrant (порт 6333) → векторная БД
        → Open WebUI (порт 33000) → RAG-поиск
```

**Чего не хватает**: скрипт индексации (чанинг + отправка в TEI + сохранение в Qdrant).

## Итоговое состояние

| Компонент | Статус | Детали |
|---|---|---|
| Qwen3-Embedding-0.6B (модель) | ✅ Скачана | `/var/lib/llama-cpp/models/Qwen3-Embedding-0.6B/` (1.2 GB) |
| TEI (сервер) | ✅ Работает | Контейнер `tei-embedding`, порт **8089** |
| Qdrant | ✅ Работает | Порт 6333 (уже был) |
| Open WebUI | ✅ Работает | Порт 33000, RAG настроен на BAAI/bge-m3 |
| VRAM | ⚠️ На пределе | 44.1/48 GB (qwen36 + TEI) |

**Тест TEI**:
```bash
curl http://localhost:8089/embed \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"inputs": "hello world"}'
```

## Дальнейшие шаги

1. Написать скрипт индексации `/tmp/rnd-service` (чанинг → TEI → Qdrant)
2. Настроить Open WebUI на использование Qwen3-Embedding вместо BGE-M3 (`RAG_EMBEDDING_MODEL`)
3. При индексации — остановить qwen36-27b для максимальной VRAM и скорости
4. Протестировать RAG-поиск по проиндексированным данным
