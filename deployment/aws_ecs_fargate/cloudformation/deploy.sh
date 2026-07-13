#!/bin/bash

# Function to remove comments from JSON and output valid JSON
remove_comments() {
    sed 's/\/\/.*$//' "$1" | grep -v '^[[:space:]]*$'
}

# Variables
TEMPLATE_DIR="$(pwd)"
SERVICE_DIR="$TEMPLATE_DIR/services"

# Unified config file
CONFIG_FILE="onyx_config.jsonl"

# Try to get AWS_REGION from config, fallback to default if not found
AWS_REGION_FROM_CONFIG=$(remove_comments "$CONFIG_FILE" | jq -r '.AWSRegion // empty')
if [ -n "$AWS_REGION_FROM_CONFIG" ]; then
    AWS_REGION="$AWS_REGION_FROM_CONFIG"
else
    AWS_REGION="${AWS_REGION:-us-east-2}"
fi

# Get environment from config file
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

INFRA_ORDER=(
  "onyx_efs_template.yaml"
  "onyx_cluster_template.yaml"
  "onyx_acm_template.yaml"
)

# Deployment order for services
SERVICE_ORDER=(
  "onyx_postgres_service_template.yaml"
  "onyx_redis_service_template.yaml"
  "onyx_vespaengine_service_template.yaml"
  "onyx_model_server_indexing_service_template.yaml"
  "onyx_model_server_inference_service_template.yaml"
  "onyx_backend_api_server_service_template.yaml"
  "onyx_backend_background_server_service_template.yaml"
  "onyx_web_server_service_template.yaml"
  "onyx_nginx_service_template.yaml"
)

# Function to validate a CloudFormation template
validate_template() {
  local template_file=$1
  echo "Validating template: $template_file..."
  if ! aws cloudformation validate-template --template-body file://"$template_file" --region "$AWS_REGION" > /dev/null; then
    echo "Error: Validation failed for $template_file. Exiting."
    exit 1
  fi
  echo "Validation succeeded for $template_file."
}

# Parameter keys declared by each template (from validate-template). The shared config file
# contains keys for multiple stacks; unknown keys cause deploy/update failures.
create_parameters_from_json() {
  local template_file=$1
  local temp_params_file="${template_file%.yaml}_parameters.json"

  local template_for_validate="$template_file"
  if [[ "$template_for_validate" != /* ]]; then
    template_for_validate="$TEMPLATE_DIR/$template_for_validate"
  fi

  local allowed_keys_json
  allowed_keys_json=$(aws cloudformation validate-template \
    --template-body "file://${template_for_validate}" \
    --region "$AWS_REGION" \
    --output json | jq -c '[(.Parameters // [])[] | .ParameterKey]')

  echo "[" > "$temp_params_file"

  local first=true
  # shellcheck disable=SC2016
  # Membership must use .key as $k | any(...) — index(.key)/contains([.key]) break jq binding.
  remove_comments "$CONFIG_FILE" | jq -r --argjson allowed "$allowed_keys_json" '
    to_entries
    | map(select(
        (.key as $k | any($allowed[]; . == $k))
        and (.value != null)
        and ((if (.value | type) == "string" then .value != "" else true end))
      ))
    | .[]
    | "\(.key)|\(.value | tostring)"
  ' | while IFS='|' read -r key value; do
    if [ "$first" = true ]; then
      first=false
    else
      echo "," >> "$temp_params_file"
    fi
    echo "    {\"ParameterKey\": \"$key\", \"ParameterValue\": \"$value\"}" >> "$temp_params_file"
  done

  echo "]" >> "$temp_params_file"

  echo "Generated parameters file: $temp_params_file" >&2
  echo "Contents:" >&2
  cat "$temp_params_file" >&2

  echo "$temp_params_file"
}

# EFS requires one mount target per AZ where any ECS task (using this FS) may run. This template
# only creates two mount targets from SubnetIDs[0,1]; set ThirdEFSSubnetId when tasks use a third AZ.
inject_third_efs_mount_subnet_param() {
  local params_file=$1
  local third
  third=$(remove_comments "$CONFIG_FILE" | jq -r '.ThirdEFSSubnetId // empty')
  third=$(echo "$third" | tr -d '\r\n' | xargs)
  if [ -z "$third" ]; then
    local subnet_csv
    subnet_csv=$(remove_comments "$CONFIG_FILE" | jq -r '.SubnetIDs // empty')
    third=$(echo "$subnet_csv" | awk -F',' '{
      if (NF >= 3) {
        gsub(/^[ \t]+|[ \t]+$/, "", $3)
        print $3
      }
    }')
  fi
  jq --arg s "$third" \
    'map(select(.ParameterKey != "ThirdEFSSubnetId"))
      + if ($s | length > 0) then [{"ParameterKey":"ThirdEFSSubnetId","ParameterValue":$s}] else [] end' \
    "$params_file" > "${params_file}.tmp" && mv "${params_file}.tmp" "$params_file"
  if [ -n "$third" ]; then
    echo "EFS stack: ThirdEFSSubnetId=$third (third mount target). If AWS reports a duplicate mount target in this AZ, pick a subnet in a different AZ or set ThirdEFSSubnetId in $CONFIG_FILE." >&2
  fi
}

# ECS injects secrets at task start; missing secrets produce ResourceInitializationError after a long rollback.
verify_secretsmanager_secret_exists() {
  local secret_id=$1
  local create_hint=$2
  if ! aws secretsmanager describe-secret --secret-id "$secret_id" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "Error: Secrets Manager secret not found (or not readable): $secret_id" >&2
    echo "$create_hint" >&2
    exit 1
  fi
}

verify_prerequisite_secrets_for_template() {
  local template_file=$1
  local base
  base=$(basename "$template_file")
  case "$base" in
    onyx_postgres_service_template.yaml)
      verify_secretsmanager_secret_exists "${ENVIRONMENT}/postgres/user/password" \
        "This secret is created by the ${ENVIRONMENT}-onyx-cluster stack (deploy/update onyx_cluster_template.yaml before Postgres). If CloudFormation fails with the secret name already in use, delete or import the existing Secrets Manager secret."
      ;;
    onyx_backend_api_server_service_template.yaml|onyx_backend_background_server_service_template.yaml)
      verify_secretsmanager_secret_exists "${ENVIRONMENT}/postgres/user/password" \
        "This secret is created by the ${ENVIRONMENT}-onyx-cluster stack (deploy/update onyx_cluster_template.yaml before backend services)."
      verify_secretsmanager_secret_exists "${ENVIRONMENT}/onyx/user-auth-secret" \
        "This secret is created by the ${ENVIRONMENT}-onyx-cluster stack (deploy/update onyx_cluster_template.yaml before backend services)."
      ;;
  esac
}

# Function to deploy a CloudFormation stack
deploy_stack() {
  local stack_name=$1
  local template_file=$2

  if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$AWS_REGION" > /dev/null 2>&1; then
    echo "Stack $stack_name already exists — updating in place."
  else
    echo "Creating stack $stack_name..."
  fi

  # Create temporary parameters file for this template
  local temp_params_file
  temp_params_file=$(create_parameters_from_json "$template_file")
  if [[ "$(basename "$template_file")" == "onyx_efs_template.yaml" ]]; then
    inject_third_efs_mount_subnet_param "$temp_params_file"
  fi

  verify_prerequisite_secrets_for_template "$template_file"

  # Special handling for SubnetIDs parameter if needed
  if grep -q "SubnetIDs" "$template_file"; then
    echo "Template uses SubnetIDs parameter, ensuring it's properly formatted..."
    # Make sure we're passing SubnetIDs as a comma-separated list
    local subnet_ids
    subnet_ids=$(remove_comments "$CONFIG_FILE" | jq -r '.SubnetIDs // empty')
    if [ -n "$subnet_ids" ]; then
      echo "Using SubnetIDs from config: $subnet_ids"
    else
      echo "Warning: SubnetIDs not found in config but template requires it."
    fi
  fi
  
  echo "Deploying stack: $stack_name with template: $template_file and generated config from: $CONFIG_FILE..."
  if ! aws cloudformation deploy \
    --stack-name "$stack_name" \
    --template-file "$template_file" \
    --parameter-overrides file://"$temp_params_file" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
    --region "$AWS_REGION" \
    --no-cli-auto-prompt; then
    echo "Error: Deployment failed for $stack_name. Exiting."
    exit 1
  fi
  
  # Clean up temporary parameter file
  rm "$temp_params_file"
  
  echo "Stack deployed successfully: $stack_name."
}

convert_underscores_to_hyphens() {
  local input_string="$1"
  local converted_string="${input_string//_/-}"
  echo "$converted_string"
}

deploy_infra_stacks() {
    for template_name in "${INFRA_ORDER[@]}"; do
      # Skip ACM template if HostedZoneId is not set
      if [[ "$template_name" == "onyx_acm_template.yaml" ]]; then
        HOSTED_ZONE_ID=$(remove_comments "$CONFIG_FILE" | jq -r '.HostedZoneId')
        if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" == "" ] || [ "$HOSTED_ZONE_ID" == "null" ]; then
          echo "Skipping ACM template deployment because HostedZoneId is not set in $CONFIG_FILE"
          continue
        fi
      fi

      template_file="$template_name"
      stack_name="$ENVIRONMENT-$(basename "$template_name" _template.yaml)"
      stack_name=$(convert_underscores_to_hyphens "$stack_name")

      if [ -f "$template_file" ]; then
        validate_template "$template_file"
        deploy_stack "$stack_name" "$template_file"
      else
        echo "Warning: Template file $template_file not found. Skipping."
      fi
    done
}

deploy_services_stacks() { 
    for template_name in "${SERVICE_ORDER[@]}"; do
      template_file="$SERVICE_DIR/$template_name"
      stack_name="$ENVIRONMENT-$(basename "$template_name" _template.yaml)"
      stack_name=$(convert_underscores_to_hyphens "$stack_name")

      if [ -f "$template_file" ]; then
        validate_template "$template_file"
        deploy_stack "$stack_name" "$template_file"
      else
        echo "Warning: Template file $template_file not found. Skipping."
      fi
    done
}

echo "Starting deployment of Onyx to ECS Fargate Cluster..."
deploy_infra_stacks
deploy_services_stacks

echo "All templates validated and deployed successfully."
