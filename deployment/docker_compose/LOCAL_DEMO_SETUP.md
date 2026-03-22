# Onyx local Docker demo setup

This guide covers configuring `.env`, running the stack with Docker Compose on a **single machine**, and preparing a **RAG + OpenAI chat** demo. Use it when the app runs on one PC and you present from another machine on the same network (see [Access from another PC](#access-from-another-pc-on-the-network)).

For the **same Compose stack on AWS EC2** (public URL for attendees), see [`AWS_EC2_DEMO_SETUP.md`](./AWS_EC2_DEMO_SETUP.md).

## Prerequisites

- Docker Engine and **Docker Compose v2.24+** (the bundled `docker compose` plugin).
- Enough resources for the **full** stack (Vespa, OpenSearch, Redis, Postgres, model servers, workers): plan for roughly **10GB+ RAM** and adequate disk for images and indexes.
- Repository checkout (or copy the `deployment/docker_compose` directory **with** `docker-compose.yml`, `env.template`, and nginx templates under `deployment/data/nginx` as in the repo).

## 1. Configure `.env` for a local run

### 1.1 Create `.env`

From the `deployment/docker_compose` directory:

```bash
cd deployment/docker_compose
cp env.template .env
```

Edit `.env` in your editor.

### 1.2 Required / strongly recommended variables

| Variable | Purpose |
|----------|---------|
| `USER_AUTH_SECRET` | Required for sensible **basic auth** (password reset / verification signing). Generate with `openssl rand -hex 32` and set the value in `.env` (quotes optional). |
| `GEN_AI_API_KEY` | Your **OpenAI API key** (`sk-...`). On a **fresh** database, this helps bootstrap a default OpenAI provider. You can also configure OpenAI later under **Admin → Language Models**. |

### 1.3 Keep defaults for local Docker networking

Do **not** change these unless you know you need to—they match service names inside Compose:

- `POSTGRES_HOST=relational_db`
- `VESPA_HOST=index`
- `REDIS_HOST=cache`
- `MODEL_SERVER_HOST=inference_model_server`
- `INDEXING_MODEL_SERVER_HOST=indexing_model_server`
- `INTERNAL_URL=http://api_server:8080`

### 1.4 Full stack + MinIO (typical local demo)

For object storage via MinIO (default app behavior):

- `COMPOSE_PROFILES=s3-filestore`
- `FILE_STORE_BACKEND=s3`
- MinIO-related defaults in `env.template` are usually fine for local use.

### 1.5 Optional

- `GEN_AI_MODEL_VERSION` — e.g. `gpt-4o-mini` (if you rely on env-based bootstrap; otherwise set defaults in the UI).
- `IMAGE_TAG` — e.g. `latest` or `edge` (must match what you intend to pull).

### 1.6 Secrets hygiene

- Never commit `.env` to git.
- Rotate keys if they may have been exposed.

### 1.7 Docker CLI and the correct engine

If you use **Docker Desktop** and also have a **system** Docker daemon, `docker` might point at an **empty** context while containers run elsewhere. If `docker compose ps` shows nothing but the app responds in a browser, run:

```bash
docker context ls
```

Use **`docker context use default`** or **`desktop-linux`** consistently—the one where `docker compose ps` lists your `onyx-*` containers.

---

## 2. Start and stop the app with Docker Compose

Always run commands from the directory that contains **`docker-compose.yml`** and **`.env`**:

```bash
cd /path/to/onyx/deployment/docker_compose
```

### 2.1 Start (detached)

```bash
docker compose up -d
```

First pull can take several minutes.

### 2.2 Check status

List all services:

```bash
docker compose ps
```

To show only a few services (note: **spaces**, not commas):

```bash
docker compose ps api_server background index nginx
```

### 2.3 Stop (keep data)

```bash
docker compose down
```

### 2.4 Stop and remove named volumes (wipes DB, Vespa index, MinIO data, etc.)

```bash
docker compose down -v
```

Only use `-v` when you intend a **full reset**.

### 2.5 Logs (troubleshooting)

```bash
docker compose logs nginx --tail 50
docker compose logs api_server --tail 50
docker compose logs background --tail 100
```

---

## 3. Open the app in the browser

- Use **HTTP**, not HTTPS: `http://localhost:3000` or `http://127.0.0.1:3000`.
- You may be redirected through `/app` to **login** or **signup**. The **first user** created is typically an **admin**.

If the tab is slow to load right after `up -d`, wait briefly—containers may still be warming up.

### Access from another PC on the network

1. On the **host** running Docker, allow inbound TCP **3000** (and **80** if you use it) in the OS firewall.
2. Find the host’s LAN IP (e.g. `192.168.1.50`).
3. From the demo laptop: `http://192.168.1.50:3000` (replace with the real IP).

`WEB_DOMAIN` / production URLs are optional for a LAN demo; focus on reaching the host IP and port.

---

## 4. Demo preparation: RAG + OpenAI chat

### 4.1 Before the demo

1. **Test document** — Create a short PDF or `.txt` with a **unique fact** (codename, number, phrase) that does not appear elsewhere. You will ask the assistant for that fact to prove retrieval.
2. **Stack health** — `docker compose ps`: confirm `api_server`, `background`, `index` (Vespa), `inference_model_server`, `indexing_model_server`, `nginx`, and other services are **Up** (and healthy where healthchecks exist).

### 4.2 Confirm the LLM (OpenAI)

1. Sign in as **admin**.
2. **Admin → Language Models** (`/admin/configuration/llm`).
3. Ensure **OpenAI** is configured and a **default chat model** is set (e.g. `gpt-4o-mini` or `gpt-4o`).
4. Note the model name for the audience if helpful.

### 4.3 Load documents (indexed corpus)

**Option A — Connector (enterprise-style story)**  
- **Admin → Add Connector** (`/admin/add-connector`).  
- Pick a source you can finish quickly (e.g. **File**, **Web**).  
- Complete setup and initial sync.

**Option B — Fast controlled demo**  
- Use any connector that indexes **local files** or a **single URL** you control so indexing finishes in minutes.

Then:

- **Admin → Existing Connectors** (`/admin/indexing/status`) — wait until indexing **succeeds** and documents appear; fix errors before the demo.

### 4.4 Document set

1. **Admin → Document Sets** (`/admin/documents/sets`).
2. **Create** a set (e.g. “Demo knowledge”).
3. Attach the **connector / source** that contains your test documents.

### 4.5 Agent (“chatbot”) with knowledge

1. **Admin → Agents** (`/admin/agents`).
2. **Create** (or edit) an agent, e.g. “Demo RAG assistant”.
3. Enable **Knowledge** and select your **document set**.
4. **Save.** With knowledge enabled and the vector DB available, the app **adds the internal Search tool** automatically—you do not need a separate “RAG” toggle.
5. Optionally set **per-agent LLM overrides** if you want a fixed model for the demo.

### 4.6 Prove RAG in chat

1. Open **Chat** and **select your demo agent** (sessions tied to other assistants may not use that document set).
2. Ask a **specific** question answerable **only** from your test file.
3. **Success:** Correct answer plus **citations / sources** pointing at your document (or chunks).

If the answer is vague or unsourced, verify indexing, document set membership, and that the correct **agent** is selected.

---

## Quick reference

| Goal | Command or location |
|------|---------------------|
| Start stack | `docker compose up -d` |
| Stop stack | `docker compose down` |
| Reset all data | `docker compose down -v` |
| Status | `docker compose ps` |
| App URL (local) | `http://localhost:3000` |
| LLM settings | Admin → **Language Models** |
| Indexing | Admin → **Existing Connectors** |
| Document sets | Admin → **Document Sets** |
| Assistants | Admin → **Agents** |

---

## Optional: `install.sh` vs manual Compose

This document assumes you manage **`docker compose`** yourself in `deployment/docker_compose`. The repo’s `install.sh` script instead copies files under `onyx_data/` and can perform guided setup; shutdown must target the **same** compose project and Docker context you used to start the stack.
