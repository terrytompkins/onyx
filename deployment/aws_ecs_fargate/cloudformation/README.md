# Onyx on AWS ECS Fargate — CloudFormation Deployment

This directory contains CloudFormation templates and operational scripts to deploy Onyx on AWS ECS Fargate inside an existing corporate VPC.

---

## Prerequisites

### VPC Requirements

The deployment requires an **existing VPC** with:

| Resource | Requirement |
|---|---|
| **Public subnets** | At least 2 subnets in **different Availability Zones** with internet-gateway routes. The Application Load Balancer (ALB) requires multi-AZ; single-subnet ALB creation fails. |
| **Private subnets** | At least 1 subnet (2 recommended for HA) with **outbound internet access via a NAT Gateway**. All ECS Fargate tasks run here — no public IPs assigned. |
| **NAT Gateway** | Placed in one of the public subnets, with a route `0.0.0.0/0 → nat-*` in the private subnet route table. Required for tasks to pull Docker images and reach AWS APIs. |

To discover your VPC and subnet IDs:
```bash
# List VPCs
aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table

# List subnets in your VPC
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<YOUR_VPC_ID>" \
  --query 'Subnets[*].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

Public subnets have `MapPublicIpOnLaunch=true` or a route table entry pointing to an internet gateway (`igw-*`). Private subnets route through a NAT gateway (`nat-*`).

### AWS Permissions

The deploying IAM user/role needs permissions to create:
- ECS clusters, task definitions, and services
- IAM roles and policies (requires `CAPABILITY_NAMED_IAM`)
- EC2 security groups
- EFS file systems and mount targets
- S3 buckets
- ALB, target groups, and listeners
- CloudWatch log groups
- Secrets Manager secrets (for `bootstrap_secrets` step)
- Route 53 records (only if `HostedZoneId` is set)
- ACM certificates (only if `HostedZoneId` is set)

---

## Configuration

All deployment parameters live in a single file: `onyx_config.json`.

Edit this file before running `deploy.sh`. Strip the `//` comments before feeding the file to any JSON tools (the deploy scripts handle this automatically).

### Required Fields

| Field | Description |
|---|---|
| `Environment` | Deployment stage label. Used as the prefix for all stack names and resource names. Example: `production`, `staging`, `dev`. |
| `AWSRegion` | AWS region to deploy into. Example: `us-east-2`. |
| `VpcID` | ID of your existing VPC. Example: `vpc-0abc1234def56789a`. |
| `PublicSubnetIDs` | Comma-separated list of **public** subnet IDs (≥2, different AZs) for the ALB. |
| `PrivateSubnetIDs` | Comma-separated list of **private** subnet IDs for ECS tasks. |

### Optional Fields

| Field | Default | Description |
|---|---|---|
| `OnyxNamespace` | `onyx` | Short identifier used in CloudMap DNS namespace names. |
| `EFSName` | `onyx-efs` | Name tag on the EFS file system. |
| `AWSAccountID` | _(auto-detected)_ | Your 12-digit AWS account number. If blank, `deploy.sh` auto-detects it via `aws sts get-caller-identity`. |
| `OnyxImageTag` | `latest` | Docker image tag applied to `onyx-backend`, `onyx-web-server`, and `onyx-model-server`. Use `latest` for the newest build or a release tag like `v0.12.0` for a pinned version. |
| `DomainName` | _(none)_ | FQDN for Onyx, e.g. `onyx.example.com`. Required only if you want HTTPS and a Route 53 DNS record. |
| `ValidationMethod` | `DNS` | ACM certificate validation method. `DNS` (recommended) or `EMAIL`. |
| `HostedZoneId` | `""` | Route 53 Hosted Zone ID for `DomainName`. If set, `deploy.sh` creates an ACM certificate and wires up the HTTPS listener on the ALB. Leave blank to skip — HTTP-only mode. Find it: `aws route53 list-hosted-zones-by-name`. |

---

## First Deploy

### 1. Configure

Copy the template values into `onyx_config.json`:
```bash
# Find your VPC/subnet IDs (see Prerequisites above), then edit:
$EDITOR onyx_config.json
```

### 2. Deploy

```bash
cd deployment/aws_ecs_fargate/cloudformation
./deploy.sh
```

`deploy.sh` will:
1. **Validate prerequisites** — checks for `aws`, `jq`, `openssl` CLIs.
2. **Bootstrap secrets** — idempotently creates three Secrets Manager entries (Postgres password, auth signing secret, OpenAI API key). Safe to run multiple times; existing secrets are never overwritten.
3. **Deploy infrastructure stacks** in order: EFS → Cluster → ACM (if `HostedZoneId` is set).
4. **Upload nginx config to S3** — copies `data/nginx/app.conf.template` and `run-nginx.sh` into the S3 config bucket so the nginx container can fetch them at startup without calling GitHub.
5. **Deploy service stacks** in order: Postgres → Redis → Vespa → Model Servers → Backend API → Background Worker → Web Server → Nginx.

To skip secrets bootstrap on subsequent runs:
```bash
./deploy.sh --skip-secrets-bootstrap
```

### 3. Verify

```bash
./monitor.sh
```

All services should show `[✓]` status. The health endpoint test at the bottom confirms the ALB is reachable.

---

## Deployment Architecture

```
Internet
    │
    ▼
[ALB]  ←── public subnets (2+ AZs)
    │       port 80  → HTTP 301 to HTTPS  (when cert configured)
    │       port 443 → nginx ECS task     (when cert configured)
    │       port 80  → nginx ECS task     (HTTP-only mode)
    ▼
[nginx ECS task]  ←── private subnet, no public IP
    │  Routes /api/* → backend-api:8080
    │  Routes /    → web-server:3000
    ▼
[backend-api]  [web-server]  [background-worker]
    │                              │
    ▼                              ▼
[postgres]  [redis]  [vespa]  [model-servers]
    │                    │
    └────────────────────┘
              │
           [EFS]  ←── shared persistent storage
```

All ECS tasks run in private subnets with `AssignPublicIp: DISABLED`. Inter-service communication uses AWS CloudMap private DNS (e.g. `postgres.onyx`). Outbound internet access flows through the NAT Gateway.

---

## Stack Inventory

| Stack | Template | Purpose |
|---|---|---|
| `<env>-onyx-efs` | `onyx_efs_template.yaml` | EFS filesystem + access points + security groups |
| `<env>-onyx-cluster` | `onyx_cluster_template.yaml` | ECS cluster, IAM roles, S3 config bucket, CloudMap namespace |
| `<env>-onyx-acm` | `onyx_acm_template.yaml` | ACM TLS certificate (skipped if `HostedZoneId` is blank) |
| `<env>-onyx-postgres-service` | `services/onyx_postgres_service_template.yaml` | PostgreSQL 15 |
| `<env>-onyx-redis-service` | `services/onyx_redis_service_template.yaml` | Redis 7.4 |
| `<env>-onyx-vespaengine-service` | `services/onyx_vespaengine_service_template.yaml` | Vespa vector database |
| `<env>-onyx-model-server-indexing-service` | `services/onyx_model_server_indexing_service_template.yaml` | ML model server for document indexing |
| `<env>-onyx-model-server-inference-service` | `services/onyx_model_server_inference_service_template.yaml` | ML model server for query inference |
| `<env>-onyx-backend-api-server-service` | `services/onyx_backend_api_server_service_template.yaml` | FastAPI backend |
| `<env>-onyx-backend-background-server-service` | `services/onyx_backend_background_server_service_template.yaml` | Celery background workers |
| `<env>-onyx-web-server-service` | `services/onyx_web_server_service_template.yaml` | Next.js frontend |
| `<env>-onyx-nginx-service` | `services/onyx_nginx_service_template.yaml` | nginx reverse proxy + ALB |

---

## Day 2 Operations

### Update a service to a new image

To roll all services to a new Onyx release:
1. Update `OnyxImageTag` in `onyx_config.json` (e.g. `"v0.13.0"`).
2. Run:
```bash
./update.sh
```

To update a single service only:
```bash
./update.sh --service backend-api-server
```

Available service short names:
```
postgres  redis  vespa  model-server-indexing  model-server-inference
backend-api-server  backend-background-server  web-server  nginx
```

`update.sh` forces a new ECS deployment and waits for the service to stabilize before returning. Infrastructure images (postgres, redis, vespa, nginx) are version-pinned in the templates and are not affected by `OnyxImageTag`.

### Check service health

```bash
./monitor.sh                       # full dashboard
./monitor.sh --health              # ALB health endpoint test only
./monitor.sh --logs backend-api-server   # tail last 50 log lines
./monitor.sh --logs all            # tail logs for every service
```

### Tear down

```bash
./uninstall.sh
```

Deletes all CloudFormation stacks in reverse order. Secrets Manager entries are **not** deleted automatically — they are printed at the end for manual cleanup. The S3 config bucket must be emptied before CloudFormation can delete it; the uninstall script will prompt you if it is non-empty.

---

## Secrets Management

`deploy.sh` creates three Secrets Manager entries on first run:

| Secret path | Contents | Auto-generated |
|---|---|---|
| `<env>/postgres/user/password` | PostgreSQL `postgres` user password | Yes — 32-char random |
| `<env>/onyx/user-auth-secret` | JWT signing secret for user sessions | Yes — 32-char random |
| `<env>/onyx/openai-api-key` | OpenAI API key | No — prompted interactively |

Secrets are injected into ECS task definitions via `secrets:` in the container environment. They are never stored in the CloudFormation templates or `onyx_config.json`.

To rotate a secret:
```bash
aws secretsmanager put-secret-value \
  --secret-id "<env>/postgres/user/password" \
  --secret-string "<new-password>" \
  --region <region>
# Then force a new deployment so containers pick up the new value:
./update.sh --service postgres
./update.sh --service backend-api-server
```

---

## Known Limitations

### Postgres on Fargate + EFS (vs. RDS)

The deployment runs PostgreSQL as an ECS Fargate task with data persisted to EFS. This works for development and staging environments but has trade-offs compared to Amazon RDS:

| | Fargate + EFS | Amazon RDS |
|---|---|---|
| Automated backups | EFS backup policy (daily) | Point-in-time recovery up to 35 days |
| Failover | Manual restart | Multi-AZ automatic |
| Storage performance | EFS elastic (latency ~1-10ms) | gp3 SSD (latency <1ms) |
| Operational overhead | Low (same deploy tooling) | Low (managed service) |
| Cost (small workloads) | Lower | Higher |

**Recommended migration path to RDS:**
1. Provision an RDS PostgreSQL 15 instance in the same VPC private subnets.
2. Update the `POSTGRES_HOST` environment variable in `onyx_backend_api_server_service_template.yaml` and `onyx_backend_background_server_service_template.yaml` to point to the RDS endpoint.
3. Remove the `onyx_postgres_service_template.yaml` stack.
4. Remove the Postgres EFS access point from `onyx_efs_template.yaml`.

### Docker Hub Image Availability

All Onyx application images pull from Docker Hub (`onyxdotapp/*`). In a corporate VPC with restricted outbound internet access or Docker Hub rate limits, consider setting up an ECR pull-through cache:

```bash
# Create a pull-through cache rule for Docker Hub
aws ecr create-pull-through-cache-rule \
  --ecr-repository-prefix docker-hub \
  --upstream-registry-url registry-1.docker.io \
  --region <region>
```

Then update image URIs in the service templates from:
```
onyxdotapp/onyx-backend:${OnyxImageTag}
```
to:
```
<account>.dkr.ecr.<region>.amazonaws.com/docker-hub/onyxdotapp/onyx-backend:${OnyxImageTag}
```

This also enables ECR image scanning and eliminates Docker Hub rate-limit errors.

### No Auto-Scaling Configured

Service task counts default to `TaskDesiredCount: 1`. For production workloads, configure Application Auto Scaling on the model servers and backend API by adding `AWS::ApplicationAutoScaling::ScalableTarget` and `AWS::ApplicationAutoScaling::ScalingPolicy` resources to the relevant service templates.

---

## Troubleshooting

**ECS tasks fail to start (image pull errors)**
- Confirm private subnets have NAT Gateway access: `aws ec2 describe-route-tables --filter "Name=association.subnet-id,Values=<subnet-id>"`
- If Docker Hub is rate-limited, set up ECR pull-through cache (see above).

**ECS tasks fail to start (secrets errors)**
- Run `./deploy.sh` again — it will bootstrap any missing secrets.
- Check that `ECSTaskExecutionRole` has `secretsmanager:GetSecretValue` permission and that the secret ARN format matches (`<env>/postgres/user/password-*`).

**nginx container exits immediately**
- Check the `s3-sync-container` logs: `./monitor.sh --logs nginx`
- Confirm the S3 bucket exists and contains `nginx/app.conf.template` and `nginx/run-nginx.sh`.
- Confirm the ECS task role (`ECSTaskRole`) has `s3:GetObject` on the config bucket.

**ALB health checks failing**
- The backend API (`/api/health`) typically takes 60–90 seconds to become ready on first start.
- Check the service startup order — backend-api depends on Postgres, Redis, and Vespa being healthy.
- Increase `StartPeriod` in the health check if services are consistently timing out.

**EFS mount fails**
- Confirm the private subnets used by ECS tasks match the subnets where EFS mount targets were created.
- Confirm the `ECSTasksSecurityGroup` is attached to the failing task and that the EFS security group allows NFS (port 2049) from it.
