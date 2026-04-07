#!/bin/bash
set -euo pipefail

# =============================================================================
# Onyx ECS Fargate — Uninstall Script
# =============================================================================
# Deletes all Onyx CloudFormation stacks in reverse dependency order.
# The S3 config bucket is emptied before the cluster stack is deleted
# (non-empty S3 buckets prevent CloudFormation from deleting them).
#
# Usage: ./uninstall.sh
# =============================================================================

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$TEMPLATE_DIR/onyx_config.json"

# -----------------------------------------------------------------------------
# Helper: strip JS-style comments from the config so jq can parse it
# -----------------------------------------------------------------------------
remove_comments() {
  sed 's/\/\/.*$//' "$1" | grep -v '^[[:space:]]*$'
}

# -----------------------------------------------------------------------------
# Validate prerequisites
# -----------------------------------------------------------------------------
if ! command -v aws &>/dev/null; then
  echo "ERROR: 'aws' CLI is not installed. Aborting."
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "ERROR: 'jq' is not installed. Aborting."
  exit 1
fi
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

# -----------------------------------------------------------------------------
# Load configuration
# -----------------------------------------------------------------------------
AWS_REGION=$(remove_comments "$CONFIG_FILE" | jq -r '.AWSRegion // "us-east-2"')
export AWS_DEFAULT_REGION="$AWS_REGION"

ENVIRONMENT=$(remove_comments "$CONFIG_FILE" | jq -r '.Environment // empty')
if [ -z "$ENVIRONMENT" ] || [ "$ENVIRONMENT" = "null" ]; then
  echo "ERROR: 'Environment' is not set in $CONFIG_FILE. Please configure it and retry."
  exit 1
fi

S3_BUCKET=$(remove_comments "$CONFIG_FILE" | jq -r '.S3Bucket // empty')
if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" = "null" ]; then
  S3_BUCKET="${ENVIRONMENT}-onyx-ecs-fargate-configs"
fi

echo "=========================================="
echo "  Onyx Fargate — Uninstall"
echo "  Environment : $ENVIRONMENT"
echo "  Region      : $AWS_REGION"
echo "=========================================="
echo ""
echo "WARNING: This will permanently delete ALL Onyx stacks in environment '$ENVIRONMENT'."
echo "         All EFS data (Postgres, Vespa, model cache) will be lost."
echo ""
read -r -p "Type the environment name to confirm ('$ENVIRONMENT'): " CONFIRM
if [ "$CONFIRM" != "$ENVIRONMENT" ]; then
  echo "Confirmation did not match. Aborting."
  exit 1
fi

# -----------------------------------------------------------------------------
# Stacks to delete (reverse dependency order)
# -----------------------------------------------------------------------------
STACK_NAMES=(
  "${ENVIRONMENT}-onyx-nginx-service"
  "${ENVIRONMENT}-onyx-web-server-service"
  "${ENVIRONMENT}-onyx-backend-background-server-service"
  "${ENVIRONMENT}-onyx-backend-api-server-service"
  "${ENVIRONMENT}-onyx-model-server-inference-service"
  "${ENVIRONMENT}-onyx-model-server-indexing-service"
  "${ENVIRONMENT}-onyx-vespaengine-service"
  "${ENVIRONMENT}-onyx-redis-service"
  "${ENVIRONMENT}-onyx-postgres-service"
  "${ENVIRONMENT}-onyx-acm"
  "${ENVIRONMENT}-onyx-cluster"
  "${ENVIRONMENT}-onyx-efs"
)

# -----------------------------------------------------------------------------
# Delete a single stack, waiting for completion
# -----------------------------------------------------------------------------
delete_stack() {
  local stack_name=$1

  # Empty the S3 config bucket before deleting the cluster stack
  if [ "$stack_name" = "${ENVIRONMENT}-onyx-cluster" ]; then
    echo "Emptying S3 config bucket: s3://${S3_BUCKET} ..."
    aws s3 rm "s3://${S3_BUCKET}" --recursive --region "$AWS_REGION" || true
    sleep 3
  fi

  echo ""
  echo "Stack: $stack_name"
  if ! aws cloudformation describe-stacks \
      --stack-name "$stack_name" \
      --region "$AWS_REGION" \
      > /dev/null 2>&1; then
    echo "  [→] Does not exist, skipping."
    return 0
  fi

  echo "  Deleting..."
  aws cloudformation delete-stack \
    --stack-name "$stack_name" \
    --region "$AWS_REGION"

  echo "  Waiting for deletion to complete..."
  aws cloudformation wait stack-delete-complete \
    --stack-name "$stack_name" \
    --region "$AWS_REGION"

  echo "  [✓] Deleted: $stack_name"
  sleep 5
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
echo ""
echo "=== Deleting stacks ==="

for stack_name in "${STACK_NAMES[@]}"; do
  delete_stack "$stack_name"
done

echo ""
echo "=========================================="
echo "  All stacks deleted successfully."
echo ""
echo "  Note: Secrets Manager entries were NOT"
echo "  deleted. To remove them, run:"
for secret in \
    "${ENVIRONMENT}/postgres/user/password" \
    "${ENVIRONMENT}/onyx/user-auth-secret" \
    "${ENVIRONMENT}/onyx/openai-api-key"; do
  echo "    aws secretsmanager delete-secret --secret-id \"$secret\" \\"
  echo "      --force-delete-without-recovery --region \"$AWS_REGION\""
done
echo "=========================================="
