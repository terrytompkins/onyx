# Onyx on AWS EC2 (simple Docker Compose demo)

This guide is for a **short-lived demo**: one EC2 instance running the **same full Docker Compose stack** as local development, so attendees can open the app in a browser over the internet. It is **not** a hardened production architecture.

For **`.env` details**, **start/stop commands**, and **demo content setup** (connectors, document sets, agents), reuse:

- [`LOCAL_DEMO_SETUP.md`](./LOCAL_DEMO_SETUP.md)

This document adds **AWS-specific** steps: sizing, networking, Docker on the instance, and pointing the app at a public URL.

---

## Is EC2 the simplest way to run Onyx in AWS?

| Approach | When it makes sense |
|----------|---------------------|
| **Single EC2 + Docker Compose** (this guide) | Fastest path that mirrors your laptop; good for **tomorrow’s demo** and POCs. You manage the VM, Docker, updates, and backups. |
| **ECS Fargate + CloudFormation** (in this repo: `deployment/aws_ecs_fargate/cloudformation/`) | More “AWS-native” and scalable, but needs a **VPC**, subnets, often a **domain** for ACM, and multiple stacks. Usually **more** setup than one EC2 box for a first demo. |
| **Terraform + EKS + Helm** (`deployment/terraform/modules/aws/`, `deployment/helm/`) | Strong **formal** / production path; **heavier** than EC2 for a quick trial (cluster, nodes, Helm values, IRSA, etc.). |
| **Onyx Cloud** | Simplest **operationally** if you are fine with a hosted product ([Onyx Cloud](https://cloud.onyx.app/signup)). |

**Bottom line:** For “get a shared URL quickly,” **EC2 + Compose** is usually the simplest **self-hosted** AWS option. Plan **Terraform/EKS** or **ECS** for the follow-on formal install.

Official overview (all methods): [Onyx deployment docs](https://docs.onyx.app/deployment/overview).

---

## 1. EC2 instance sizing

The full stack (Vespa, OpenSearch, Redis, Postgres, two model servers, Celery workers, etc.) is **memory-hungry**. Treat these as **minimums for a demo**:

| Resource | Recommendation |
|----------|----------------|
| **Instance type** | **At least 16 GiB RAM** (e.g. `t3.xlarge` or `m6i.xlarge`). **32 GiB** (`t3.2xlarge` / `m6i.2xlarge`) is safer if OpenSearch + Vespa + model servers spike. |
| **vCPUs** | 4+ |
| **Disk** | **100+ GiB** gp3 root volume (images + indexes + logs grow quickly). |
| **Architecture** | **x86_64** (amd64). Avoid Graviton unless you know all images support arm64. |

Undersized instances often **OOM** or **thrash** during indexing; prefer a larger instance over spending hours tuning swap.

---

## 2. Networking and security group

1. Create (or reuse) a **VPC** and **public subnet** if you want a public IP on the instance.
2. **Security group** (inbound)—typical **demo** rules (tighten before any real data):

   | Port | Source | Purpose |
   |------|--------|---------|
   | **22** | **Your IP /32** only | SSH (avoid open SSH to `0.0.0.0/0`). |
   | **3000** | `0.0.0.0/0` (or corporate CIDR) | Onyx UI (nginx maps host **3000** → web stack in default compose). |
   | **80** | Optional | Also exposed by default compose; you can use **80** instead of 3000 if you prefer. |

3. Assign a **public IPv4** address at launch **or** attach an **Elastic IP** so the URL does not change if you stop/start the instance (recommended for a demo URL you share in advance).

4. **DNS (optional):** Point a hostname (e.g. `onyx-demo.company.com`) at the Elastic IP so you can say “open this link” without a raw IP.

---

## 3. AMI and SSH

- **Ubuntu Server 22.04 LTS** (amd64) is a common choice; steps below use `apt`.
- **Amazon Linux 2023** also works; install Docker using [Docker’s docs for RHEL/Amazon Linux](https://docs.docker.com/engine/install/) if you prefer that path.

Create a key pair, launch the instance, then SSH in as `ubuntu` (Ubuntu) or `ec2-user` (Amazon Linux).

---

## 4. Install Docker Engine and Compose plugin (Ubuntu 22.04)

Run on the instance (from [Docker’s Ubuntu install guide](https://docs.docker.com/engine/install/ubuntu/)):

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Log out and SSH back in so **`docker`** works without `sudo`:

```bash
docker compose version
docker run --rm hello-world
```

---

## 5. Put the Compose project on the server

You need **`deployment/docker_compose`** **and** the nginx templates under **`deployment/data/nginx`** (the compose file bind-mounts `../data/nginx`).

**Option A — Git clone (if the repo is reachable from EC2)**

```bash
sudo apt-get install -y git
git clone https://github.com/onyx-dot-app/onyx.git
cd onyx/deployment/docker_compose
```

**Option B — Copy from your laptop**

```bash
# On your machine (example): sync only what Compose needs
rsync -avz --relative ./onyx/./deployment/docker_compose ./onyx/./deployment/data/nginx \
  ubuntu@YOUR_ELASTIC_IP:~/onyx-deploy/
```

Then on EC2:

```bash
cd ~/onyx-deploy/onyx/deployment/docker_compose
```

---

## 6. Configure `.env` on EC2

1. Copy the template and edit:

   ```bash
   cp env.template .env
   nano .env   # or vim
   ```

2. Set at least:

   - `USER_AUTH_SECRET` — `openssl rand -hex 32` on the instance.
   - `GEN_AI_API_KEY` — OpenAI key (or configure OpenAI only in **Admin → Language Models** after first boot).

3. Set **`WEB_DOMAIN`** to the URL attendees will use (helps redirects and links):

   ```bash
   # Examples—pick one consistent with how people connect
   WEB_DOMAIN=http://YOUR_ELASTIC_IP:3000
   # or
   WEB_DOMAIN=http://onyx-demo.yourcompany.com:3000
   ```

   If you terminate TLS in front of nginx later, switch to `https://...` and align with your load balancer / cert.

4. Keep **`COMPOSE_PROFILES=s3-filestore`**, default **`POSTGRES_HOST`**, **`VESPA_HOST`**, etc., as in [`LOCAL_DEMO_SETUP.md`](./LOCAL_DEMO_SETUP.md) unless you intentionally change storage.

---

## 7. Start and stop Onyx

From `deployment/docker_compose` on the EC2 host:

```bash
docker compose up -d
docker compose ps
```

**Stop** (keeps Docker volumes / data):

```bash
docker compose down
```

**Full reset** (destroys named volumes—Postgres, Vespa, MinIO data, etc.):

```bash
docker compose down -v
```

**Logs:**

```bash
docker compose logs -f nginx api_server background
```

Attendees open:

```text
http://YOUR_PUBLIC_IP_OR_DNS:3000
```

Use **HTTP** for this quick demo unless you add TLS (see below).

---

## 8. Demo content (RAG + OpenAI)

Follow **section 4** in [`LOCAL_DEMO_SETUP.md`](./LOCAL_DEMO_SETUP.md):

- Language Models → OpenAI  
- Add connector → index → document set → agent with knowledge → question with citations  

No change in workflow versus local; only the **base URL** is different.

---

## 9. Operational tips before the meeting

- **Warm-up:** After `up -d`, wait until `docker compose ps` shows **healthy** where applicable, then load the UI once and complete signup.
- **Firewall:** Confirm security group allows attendee networks if you did not use `0.0.0.0/0`.
- **Cost:** Stop the instance when the demo ends; snapshot or terminate per your policy.
- **Secrets:** Do not commit EC2 `.env`; rotate keys if exposed.

---

## 10. TLS (optional, not required for an internal demo)

The default Compose setup serves **HTTP** on ports **80** / **3000**. For **HTTPS** you typically add:

- An **Application Load Balancer** + ACM certificate in front of the instance, **or**
- Switch nginx to the production-style template and **Let’s Encrypt** (more moving parts on a single host).

Defer TLS until the **formal** Terraform / EKS / ECS deployment if possible.

---

## 11. After the demo: “formal” AWS install

When you move beyond a single VM:

- **EKS + Helm + Terraform:** see `deployment/terraform/modules/aws/README.md` and `deployment/helm/`.
- **ECS Fargate:** see `deployment/aws_ecs_fargate/cloudformation/README.md`.

Those paths add proper networking, scaling, and secrets management at the cost of more upfront work.
