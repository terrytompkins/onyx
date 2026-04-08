#!/bin/bash
set -euo pipefail

# =============================================================================
# Onyx ECS Fargate — Service Update Script
# =============================================================================
# Usage:
#   ./update.sh                          # force-redeploy all ECS services
#   ./update.sh --service <short-name>   # redeploy one service only
#   ./update.sh --list                   # list available service short names
#
# Forces a new ECS deployment for the targeted service(s), which causes ECS to
# pull the latest Docker image (or the tag pinned by OnyxImageTag) and replace
# running tasks one-by-one. Waits for the deployment to stabilize before exiting.
#
# Short service names (use with --service):
#   postgres  redis  vespa  model-server-indexing  model-server-inference
#   backend-api-server  backend-background-server  web-server  nginx
# =============================================================================

# Parse arguments
TARGET_SERVICE=""
LIST_SERVICES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)
      TARGET_SERVICE="${2:-}"
      if [ -z "$TARGET_SERVICE" ]; then
        echo "ERROR: --service requires a service name argument."
        exit 1
      fi
      shift 2
      ;;
    --list)
      LIST_SERVICES=true
      shift
      ;;
    -h|--help)
      sed -n '/^# Usage/,/^# =/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      echo "Usage: $0 [--service <name>] [--list]"
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Paths & config
# -----------------------------------------------------------------------------
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$TEMPLATE_DIR/onyx_config.json"

remove_comments() {
  sed 's/\/\/.*$//' "$1" | grep -v '^[[:space:]]*$'
}

AWS_REGION=$(remove_comments "$CONFIG_FILE" | jq -r '.AWSRegion // "us-east-2"')
export AWS_DEFAULT_REGION="$AWS_REGION"

ENVIRONMENT=$(remove_comments "$CONFIG_FILE" | jq -r '.Environment // empty')
if [ -z "$ENVIRONMENT" ] || [ "$ENVIRONMENT" = "null" ]; then
  echo "ERROR: 'Environment' is not set in $CONFIG_FILE."
  exit 1
fi

# -----------------------------------------------------------------------------
# Service registry: short-name → ECS service name suffix (appended to
# ${Environment}- prefix by the CloudFormation templates)
# -----------------------------------------------------------------------------
declare -A SERVICE_MAP
SERVICE_MAP["postgres"]="onyx-postgres-service"
SERVICE_MAP["redis"]="onyx-redis-service"
SERVICE_MAP["vespa"]="onyx-vespaengine-service"
SERVICE_MAP["model-server-indexing"]="onyx-model-server-indexing-service"
SERVICE_MAP["model-server-inference"]="onyx-model-server-inference-service"
SERVICE_MAP["backend-api-server"]="onyx-backend-api-server-service"
SERVICE_MAP["backend-background-server"]="onyx-backend-background-server-service"
SERVICE_MAP["web-server"]="onyx-web-server-service"
SERVICE_MAP["nginx"]="onyx-nginx-service"

# Ordered list for update-all
ALL_SERVICES=(
  postgres
  redis
  vespa
  model-server-indexing
  model-server-inference
  backend-api-server
  backend-background-server
  web-server
  nginx
)

if [ "$LIST_SERVICES" = true ]; then
  echo "Available service short names:"
  for s in "${ALL_SERVICES[@]}"; do
    printf "  %-35s  → %s-%s\n" "$s" "$ENVIRONMENT" "${SERVICE_MAP[$s]}"
  done
  exit 0
fi

# -----------------------------------------------------------------------------
# Resolve the ECS cluster name from CloudFormation exports
# -----------------------------------------------------------------------------
CLUSTER_STACK="${ENVIRONMENT}-onyx-cluster"
ECS_CLUSTER=$(aws cloudformation describe-stacks \
  --stack-name "$CLUSTER_STACK" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`OutputEcsCluster`].OutputValue' \
  --output text 2>/dev/null || echo "")

if [ -z "$ECS_CLUSTER" ] || [ "$ECS_CLUSTER" = "None" ]; then
  echo "ERROR: Could not retrieve ECS cluster name from stack '$CLUSTER_STACK'."
  echo "       Has the cluster stack been deployed? Run ./deploy.sh first."
  exit 1
fi

echo "=========================================="
echo "  Onyx Service Update"
echo "  Environment : $ENVIRONMENT"
echo "  Region      : $AWS_REGION"
echo "  Cluster     : $ECS_CLUSTER"
echo "=========================================="

# -----------------------------------------------------------------------------
# Force a new ECS deployment and wait for it to stabilize
# -----------------------------------------------------------------------------
update_service() {
  local short_name="$1"
  local ecs_service_name="${ENVIRONMENT}-${SERVICE_MAP[$short_name]}"

  echo ""
  echo "--- Updating: $short_name ($ecs_service_name) ---"

  # Verify the service exists
  if ! aws ecs describe-services \
      --cluster "$ECS_CLUSTER" \
      --services "$ecs_service_name" \
      --region "$AWS_REGION" \
      --query 'services[0].status' \
      --output text 2>/dev/null | grep -q "ACTIVE"; then
    echo "  [!] Service '$ecs_service_name' not found or not ACTIVE — skipping."
    return 0
  fi

  aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$ecs_service_name" \
    --force-new-deployment \
    --region "$AWS_REGION" \
    --output text \
    --query 'service.serviceName' \
    > /dev/null

  echo "  Deployment triggered. Waiting for stabilization (this may take a few minutes)..."

  if aws ecs wait services-stable \
      --cluster "$ECS_CLUSTER" \
      --services "$ecs_service_name" \
      --region "$AWS_REGION"; then
    echo "  [✓] $short_name is stable."
  else
    echo "  [✗] $short_name did not stabilize — check the ECS console or run ./monitor.sh"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Main: update targeted service(s)
# -----------------------------------------------------------------------------
FAILED=()

if [ -n "$TARGET_SERVICE" ]; then
  if [ -z "${SERVICE_MAP[$TARGET_SERVICE]+_}" ]; then
    echo "ERROR: Unknown service '$TARGET_SERVICE'. Run with --list to see valid names."
    exit 1
  fi
  update_service "$TARGET_SERVICE" || FAILED+=("$TARGET_SERVICE")
else
  echo "Updating all services in order..."
  for svc in "${ALL_SERVICES[@]}"; do
    update_service "$svc" || FAILED+=("$svc")
  done
fi

echo ""
if [ ${#FAILED[@]} -eq 0 ]; then
  echo "=========================================="
  echo "  All updates completed successfully."
  echo "  Run ./monitor.sh to check service health."
  echo "=========================================="
else
  echo "=========================================="
  echo "  Update finished with errors."
  echo "  Failed services: ${FAILED[*]}"
  echo "  Run ./monitor.sh for details."
  echo "=========================================="
  exit 1
fi
