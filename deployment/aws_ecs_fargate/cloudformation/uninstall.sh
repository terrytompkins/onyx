#!/bin/bash

# Strip JS-style comments so jq can parse the config (same as deploy.sh).
remove_comments() {
    sed 's/\/\/.*$//' "$1" | grep -v '^[[:space:]]*$'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/onyx_config.jsonl"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

AWS_REGION_FROM_CONFIG=$(remove_comments "$CONFIG_FILE" | jq -r '.AWSRegion // empty')
if [ -n "$AWS_REGION_FROM_CONFIG" ]; then
    AWS_REGION="$AWS_REGION_FROM_CONFIG"
else
    AWS_REGION="${AWS_REGION:-us-east-2}"
fi

# Get environment from config file (must match the stacks you are removing)
ENVIRONMENT=$(remove_comments "$CONFIG_FILE" | jq -r '.Environment')
if [ -z "$ENVIRONMENT" ] || [ "$ENVIRONMENT" == "null" ]; then
    echo "Missing Environment in $CONFIG_FILE. Please add the Environment field."
    exit 1
fi

# Try to get S3_BUCKET from config, fallback to default if not found
S3_BUCKET_FROM_CONFIG=$(remove_comments "$CONFIG_FILE" | jq -r '.S3Bucket // empty')
if [ -n "$S3_BUCKET_FROM_CONFIG" ]; then
    S3_BUCKET="$S3_BUCKET_FROM_CONFIG"
else
    S3_BUCKET="${S3_BUCKET:-onyx-ecs-fargate-configs}"
fi

echo "Uninstall: Environment=${ENVIRONMENT} Region=${AWS_REGION} (from ${CONFIG_FILE})"
echo "Deleting stacks prefixed with ${ENVIRONMENT}- ..."

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
  "${ENVIRONMENT}-onyx-cluster"
  "${ENVIRONMENT}-onyx-acm"
  "${ENVIRONMENT}-onyx-efs"
  )

delete_stack() {
  local stack_name=$1

  if [ "$stack_name" == "${ENVIRONMENT}-onyx-cluster" ]; then
      echo "Removing all objects and directories from the onyx config s3 bucket."
      aws s3 rm "s3://${ENVIRONMENT}-${S3_BUCKET}" --recursive
      sleep 5
  fi

  echo "Checking if stack $stack_name exists..."
  if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$AWS_REGION" > /dev/null 2>&1; then
  	echo "Deleting stack: $stack_name..."
  	aws cloudformation delete-stack \
		--stack-name "$stack_name" \
		--region "$AWS_REGION"
	
	echo "Waiting for stack $stack_name to be deleted..."
	if aws cloudformation wait stack-delete-complete \
		--stack-name "$stack_name" \
		--region "$AWS_REGION"; then
		echo "Stack $stack_name deleted successfully."
		sleep 10
	else
		echo "Failed to delete stack $stack_name. Exiting."
		exit 1
	fi
  else
	echo "Stack $stack_name does not exist, skipping."
	return 0
  fi	
}

for stack_name in "${STACK_NAMES[@]}"; do
  delete_stack "$stack_name"
done

echo "All stacks deleted successfully."
