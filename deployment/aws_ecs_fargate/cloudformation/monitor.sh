#!/bin/bash
set -euo pipefail

# =============================================================================
# Onyx ECS Fargate — Health & Status Monitor
# =============================================================================
# Usage:
#   ./monitor.sh                      # full dashboard (stacks + services + ALB)
#   ./monitor.sh --logs <service>     # tail last 50 log lines for a service
#   ./monitor.sh --logs all           # tail logs for every service
#   ./monitor.sh --health             # test ALB health endpoint only
#
# Short service names (use with --logs):
#   postgres  redis  vespa  model-server-indexing  model-server-inference
#   backend-api-server  backend-background-server  web-server  nginx
# =============================================================================

# Parse arguments
MODE="dashboard"
LOG_TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --logs)
      MODE="logs"
      LOG_TARGET="${2:-}"
      if [ -z "$LOG_TARGET" ]; then
        echo "ERROR: --logs requires a service name or 'all'."
        exit 1
      fi
      shift 2
      ;;
    --health)
      MODE="health"
      shift
      ;;
    -h|--help)
      sed -n '/^# Usage/,/^# =/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
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

DOMAIN=$(remove_comments "$CONFIG_FILE" | jq -r '.DomainName // empty')

# -----------------------------------------------------------------------------
# Service registry — short name to ECS service name and CloudWatch log group
# -----------------------------------------------------------------------------
declare -A SERVICE_ECS_NAME
SERVICE_ECS_NAME["postgres"]="onyx-postgres-service"
SERVICE_ECS_NAME["redis"]="onyx-redis-service"
SERVICE_ECS_NAME["vespa"]="onyx-vespaengine-service"
SERVICE_ECS_NAME["model-server-indexing"]="onyx-model-server-indexing-service"
SERVICE_ECS_NAME["model-server-inference"]="onyx-model-server-inference-service"
SERVICE_ECS_NAME["backend-api-server"]="onyx-backend-api-server-service"
SERVICE_ECS_NAME["backend-background-server"]="onyx-backend-background-server-service"
SERVICE_ECS_NAME["web-server"]="onyx-web-server-service"
SERVICE_ECS_NAME["nginx"]="onyx-nginx-service"

# CloudWatch log groups follow the pattern set in the task definition LogConfiguration
declare -A SERVICE_LOG_GROUP
SERVICE_LOG_GROUP["postgres"]="/ecs/${ENVIRONMENT}-OnyxPostgresTaskDefinition"
SERVICE_LOG_GROUP["redis"]="/ecs/${ENVIRONMENT}-OnyxRedisTaskDefinition"
SERVICE_LOG_GROUP["vespa"]="/ecs/${ENVIRONMENT}-OnyxVespaengineTaskDefinition"
SERVICE_LOG_GROUP["model-server-indexing"]="/ecs/${ENVIRONMENT}-OnyxModelServerIndexingTaskDefinition"
SERVICE_LOG_GROUP["model-server-inference"]="/ecs/${ENVIRONMENT}-OnyxModelServerInferenceTaskDefinition"
SERVICE_LOG_GROUP["backend-api-server"]="/ecs/${ENVIRONMENT}-OnyxBackendApiServerTaskDefinition"
SERVICE_LOG_GROUP["backend-background-server"]="/ecs/${ENVIRONMENT}-OnyxBackendBackgroundServerTaskDefinition"
SERVICE_LOG_GROUP["web-server"]="/ecs/${ENVIRONMENT}-OnyxWebServerTaskDefinition"
SERVICE_LOG_GROUP["nginx"]="/ecs/${ENVIRONMENT}-OnyxNginxTaskDefinition"

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

INFRA_STACKS=(
  "${ENVIRONMENT}-onyx-efs"
  "${ENVIRONMENT}-onyx-cluster"
  "${ENVIRONMENT}-onyx-acm"
)

SERVICE_STACKS=(
  "${ENVIRONMENT}-onyx-postgres-service"
  "${ENVIRONMENT}-onyx-redis-service"
  "${ENVIRONMENT}-onyx-vespaengine-service"
  "${ENVIRONMENT}-onyx-model-server-indexing-service"
  "${ENVIRONMENT}-onyx-model-server-inference-service"
  "${ENVIRONMENT}-onyx-backend-api-server-service"
  "${ENVIRONMENT}-onyx-backend-background-server-service"
  "${ENVIRONMENT}-onyx-web-server-service"
  "${ENVIRONMENT}-onyx-nginx-service"
)

# Status symbol helper
status_symbol() {
  case "$1" in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE) echo "✓" ;;
    CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|UPDATE_ROLLBACK_IN_PROGRESS) echo "…" ;;
    ROLLBACK_COMPLETE|CREATE_FAILED|DELETE_FAILED|UPDATE_FAILED) echo "✗" ;;
    DELETE_COMPLETE) echo "—" ;;
    *) echo "?" ;;
  esac
}

# -----------------------------------------------------------------------------
# CloudFormation stack status section
# -----------------------------------------------------------------------------
show_stack_status() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  CloudFormation Stack Status                                     ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"

  printf "  %-50s  %s\n" "Stack" "Status"
  printf "  %-50s  %s\n" "-----" "------"

  for stack in "${INFRA_STACKS[@]}" "${SERVICE_STACKS[@]}"; do
    local status
    status=$(aws cloudformation describe-stacks \
      --stack-name "$stack" \
      --region "$AWS_REGION" \
      --query 'Stacks[0].StackStatus' \
      --output text 2>/dev/null || echo "NOT_DEPLOYED")
    local sym
    sym=$(status_symbol "$status")
    printf "  [%s] %-48s  %s\n" "$sym" "$stack" "$status"
  done
}

# -----------------------------------------------------------------------------
# ECS service task counts section
# -----------------------------------------------------------------------------
show_ecs_status() {
  local cluster_stack="${ENVIRONMENT}-onyx-cluster"
  local ecs_cluster
  ecs_cluster=$(aws cloudformation describe-stacks \
    --stack-name "$cluster_stack" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`OutputEcsCluster`].OutputValue' \
    --output text 2>/dev/null || echo "")

  if [ -z "$ecs_cluster" ] || [ "$ecs_cluster" = "None" ]; then
    echo ""
    echo "  [!] ECS cluster not found — skipping service status."
    return
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  ECS Service Health  (cluster: $ecs_cluster)"
  printf "║%66s║\n" ""
  echo "╚══════════════════════════════════════════════════════════════════╝"
  printf "  %-35s  %8s  %8s  %8s\n" "Service" "Desired" "Running" "Pending"
  printf "  %-35s  %8s  %8s  %8s\n" "-------" "-------" "-------" "-------"

  for short_name in "${ALL_SERVICES[@]}"; do
    local svc_name="${ENVIRONMENT}-${SERVICE_ECS_NAME[$short_name]}"

    local result
    result=$(aws ecs describe-services \
      --cluster "$ecs_cluster" \
      --services "$svc_name" \
      --region "$AWS_REGION" \
      --query 'services[0].[desiredCount,runningCount,pendingCount,status]' \
      --output text 2>/dev/null || echo "- - - NOT_FOUND")

    read -r desired running pending svc_status <<< "$result"
    local sym="?"
    if [ "$svc_status" = "ACTIVE" ] && [ "$desired" = "$running" ] && [ "$pending" = "0" ]; then
      sym="✓"
    elif [ "$svc_status" = "ACTIVE" ]; then
      sym="…"
    elif [ "$svc_status" = "NOT_FOUND" ]; then
      sym="—"
      desired="-"; running="-"; pending="-"
    else
      sym="✗"
    fi

    printf "  [%s] %-33s  %8s  %8s  %8s\n" "$sym" "$short_name" "$desired" "$running" "$pending"
  done
}

# -----------------------------------------------------------------------------
# ALB target group health section
# -----------------------------------------------------------------------------
show_alb_health() {
  local nginx_stack="${ENVIRONMENT}-onyx-nginx-service"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  ALB Target Group Health                                         ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"

  # Find target group ARN from nginx stack outputs
  local tg_arn
  tg_arn=$(aws cloudformation describe-stacks \
    --stack-name "$nginx_stack" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`OutputOnyxTargetGroupArn`].OutputValue' \
    --output text 2>/dev/null || echo "")

  if [ -z "$tg_arn" ] || [ "$tg_arn" = "None" ]; then
    # Try discovering target groups tagged with this environment
    tg_arn=$(aws elbv2 describe-target-groups \
      --region "$AWS_REGION" \
      --query "TargetGroups[?contains(TargetGroupName, '${ENVIRONMENT}')].TargetGroupArn | [0]" \
      --output text 2>/dev/null || echo "")
  fi

  if [ -z "$tg_arn" ] || [ "$tg_arn" = "None" ]; then
    echo "  [!] Target group not found — nginx stack may not be deployed yet."
    return
  fi

  local health_output
  health_output=$(aws elbv2 describe-target-health \
    --target-group-arn "$tg_arn" \
    --region "$AWS_REGION" \
    --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Description]' \
    --output text 2>/dev/null || echo "")

  if [ -z "$health_output" ]; then
    echo "  [!] No targets registered in target group."
    return
  fi

  printf "  %-25s  %-12s  %s\n" "Target" "State" "Description"
  printf "  %-25s  %-12s  %s\n" "------" "-----" "-----------"
  while IFS=$'\t' read -r target state description; do
    local sym="?"
    case "$state" in
      healthy)   sym="✓" ;;
      unhealthy) sym="✗" ;;
      initial|draining) sym="…" ;;
    esac
    printf "  [%s] %-23s  %-12s  %s\n" "$sym" "$target" "$state" "${description:-}"
  done <<< "$health_output"
}

# -----------------------------------------------------------------------------
# Health endpoint test
# -----------------------------------------------------------------------------
show_health_endpoints() {
  local nginx_stack="${ENVIRONMENT}-onyx-nginx-service"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  Health Endpoint Tests                                           ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"

  local alb_dns
  alb_dns=$(aws cloudformation describe-stacks \
    --stack-name "$nginx_stack" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`OutputOnyxLoadBalancerDNSName`].OutputValue' \
    --output text 2>/dev/null || echo "")

  if [ -z "$alb_dns" ] || [ "$alb_dns" = "None" ]; then
    echo "  [!] ALB DNS name not found — nginx stack may not be deployed."
    return
  fi

  # HTTP health check via ALB DNS
  local http_code
  http_code=$(curl -o /dev/null -s -w "%{http_code}" \
    --max-time 10 \
    "http://${alb_dns}/api/health" 2>/dev/null || echo "TIMEOUT")

  local sym="✗"
  if [ "$http_code" = "200" ] || [ "$http_code" = "301" ] || [ "$http_code" = "302" ]; then
    sym="✓"
  fi
  printf "  [%s] HTTP  http://%s/api/health  →  %s\n" "$sym" "$alb_dns" "$http_code"

  # HTTPS health check via domain name (if configured)
  if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ] && \
     ! echo "$DOMAIN" | grep -qi "YOUR_DOMAIN"; then
    local https_code
    https_code=$(curl -o /dev/null -s -w "%{http_code}" \
      --max-time 10 \
      "https://${DOMAIN}/api/health" 2>/dev/null || echo "TIMEOUT")

    local https_sym="✗"
    [ "$https_code" = "200" ] && https_sym="✓"
    printf "  [%s] HTTPS https://%s/api/health  →  %s\n" "$https_sym" "$DOMAIN" "$https_code"
  fi
}

# -----------------------------------------------------------------------------
# CloudWatch log tail
# -----------------------------------------------------------------------------
tail_logs() {
  local short_name="$1"
  local log_group="${SERVICE_LOG_GROUP[$short_name]}"

  echo ""
  echo "--- Logs: $short_name ($log_group) ---"

  # Find the most recent log stream
  local stream
  stream=$(aws logs describe-log-streams \
    --log-group-name "$log_group" \
    --order-by LastEventTime \
    --descending \
    --max-items 1 \
    --region "$AWS_REGION" \
    --query 'logStreams[0].logStreamName' \
    --output text 2>/dev/null || echo "")

  if [ -z "$stream" ] || [ "$stream" = "None" ]; then
    echo "  [!] No log streams found in $log_group"
    return
  fi

  echo "  Stream: $stream"
  aws logs get-log-events \
    --log-group-name "$log_group" \
    --log-stream-name "$stream" \
    --limit 50 \
    --start-from-head false \
    --region "$AWS_REGION" \
    --query 'events[*].message' \
    --output text 2>/dev/null | tail -50 || echo "  [!] Could not retrieve log events."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "  Onyx Fargate Monitor"
echo "  Environment : $ENVIRONMENT"
echo "  Region      : $AWS_REGION"
echo "  $(date)"
echo "=========================================="

case "$MODE" in
  dashboard)
    show_stack_status
    show_ecs_status
    show_alb_health
    show_health_endpoints
    echo ""
    echo "  Tip: ./monitor.sh --logs <service>   to tail service logs"
    echo "       ./monitor.sh --health           to retest health endpoints"
    echo ""
    ;;
  health)
    show_health_endpoints
    echo ""
    ;;
  logs)
    if [ "$LOG_TARGET" = "all" ]; then
      for svc in "${ALL_SERVICES[@]}"; do
        tail_logs "$svc"
      done
    else
      if [ -z "${SERVICE_ECS_NAME[$LOG_TARGET]+_}" ]; then
        echo "ERROR: Unknown service '$LOG_TARGET'."
        echo "       Valid names: ${ALL_SERVICES[*]}"
        exit 1
      fi
      tail_logs "$LOG_TARGET"
    fi
    echo ""
    ;;
esac
