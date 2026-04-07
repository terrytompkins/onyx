#!/bin/bash
set -euo pipefail

# =============================================================================
# Onyx ECS Fargate — Deployment Script
# =============================================================================
# Usage: ./deploy.sh [--skip-secrets-bootstrap]
#
# Reads all configuration from onyx_config.json, validates and deploys every
# CloudFormation stack in dependency order, and bootstraps required Secrets
# Manager entries before the first deployment.
# =============================================================================

# Parse optional flags
SKIP_SECRETS_BOOTSTRAP=false
for arg in "$@"; do
  case $arg in
    --skip-secrets-bootstrap) SKIP_SECRETS_BOOTSTRAP=true ;;
  esac
done

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$TEMPLATE_DIR/services"
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
for cmd in aws jq openssl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required tool '$cmd' is not installed. Aborting."
    exit 1
  fi
done

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

# AWS Account ID — use config value if provided, otherwise auto-detect
AWS_ACCOUNT_ID=$(remove_comments "$CONFIG_FILE" | jq -r '.AWSAccountID // empty')
if [ -z "$AWS_ACCOUNT_ID" ] || [ "$AWS_ACCOUNT_ID" = "null" ]; then
  echo "AWSAccountID not set in config — detecting via aws sts get-caller-identity..."
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  echo "Detected AWS Account ID: $AWS_ACCOUNT_ID"
fi

# S3 bucket for nginx config (cluster stack creates this bucket)
S3_BUCKET=$(remove_comments "$CONFIG_FILE" | jq -r '.S3Bucket // empty')
if [ -z "$S3_BUCKET" ] || [ "$S3_BUCKET" = "null" ]; then
  S3_BUCKET="${ENVIRONMENT}-onyx-ecs-fargate-configs"
fi

# ACM certificate ARN — populated by deploy_infra_stacks after the ACM stack
# deploys. Passed automatically to the nginx service stack as CertificateArn.
ACM_CERT_ARN=""

echo "=========================================="
echo "  Onyx Fargate Deployment"
echo "  Environment : $ENVIRONMENT"
echo "  Region      : $AWS_REGION"
echo "  Account     : $AWS_ACCOUNT_ID"
echo "  Config      : $CONFIG_FILE"
echo "=========================================="

# -----------------------------------------------------------------------------
# Deployment order
# -----------------------------------------------------------------------------
INFRA_ORDER=(
  "onyx_efs_template.yaml"
  "onyx_cluster_template.yaml"
  "onyx_acm_template.yaml"
)

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

# -----------------------------------------------------------------------------
# Secrets Manager bootstrap
# -----------------------------------------------------------------------------
# Creates required secrets if they do not already exist. Safe to run on every
# deploy — existing secrets are never overwritten.
# -----------------------------------------------------------------------------
bootstrap_secrets() {
  echo ""
  echo "--- Secrets Manager Bootstrap ---"

  local postgres_secret="${ENVIRONMENT}/postgres/user/password"
  local auth_secret="${ENVIRONMENT}/onyx/user-auth-secret"
  local openai_secret="${ENVIRONMENT}/onyx/openai-api-key"

  # Helper: check whether a secret exists
  secret_exists() {
    aws secretsmanager describe-secret \
      --secret-id "$1" \
      --region "$AWS_REGION" \
      --query 'ARN' \
      --output text 2>/dev/null | grep -q "^arn:"
  }

  # --- Postgres password ---
  if secret_exists "$postgres_secret"; then
    echo "[✓] Secret already exists: $postgres_secret"
  else
    echo "Creating secret: $postgres_secret ..."
    local pg_pass
    pg_pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    aws secretsmanager create-secret \
      --name "$postgres_secret" \
      --description "Onyx ($ENVIRONMENT) — PostgreSQL user password" \
      --secret-string "$pg_pass" \
      --region "$AWS_REGION" \
      --output text --query 'ARN'
    echo "[✓] Created: $postgres_secret"
  fi

  # --- User-auth secret ---
  if secret_exists "$auth_secret"; then
    echo "[✓] Secret already exists: $auth_secret"
  else
    echo "Creating secret: $auth_secret ..."
    local auth_val
    auth_val=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    aws secretsmanager create-secret \
      --name "$auth_secret" \
      --description "Onyx ($ENVIRONMENT) — user-auth signing secret" \
      --secret-string "$auth_val" \
      --region "$AWS_REGION" \
      --output text --query 'ARN'
    echo "[✓] Created: $auth_secret"
  fi

  # --- OpenAI API key (prompted) ---
  if secret_exists "$openai_secret"; then
    echo "[✓] Secret already exists: $openai_secret"
  else
    echo ""
    echo "Secret '$openai_secret' does not exist."
    echo "Enter your OpenAI API key (input is hidden, press Enter to skip):"
    local openai_key=""
    read -r -s openai_key
    if [ -n "$openai_key" ]; then
      aws secretsmanager create-secret \
        --name "$openai_secret" \
        --description "Onyx ($ENVIRONMENT) — OpenAI API key" \
        --secret-string "$openai_key" \
        --region "$AWS_REGION" \
        --output text --query 'ARN'
      echo "[✓] Created: $openai_secret"
    else
      echo "[!] Skipped: $openai_secret — you can create it manually later with:"
      echo "    aws secretsmanager create-secret \\"
      echo "      --name \"$openai_secret\" \\"
      echo "      --secret-string \"<YOUR_KEY>\" \\"
      echo "      --region \"$AWS_REGION\""
    fi
  fi

  echo "--- Secrets bootstrap complete ---"
  echo ""
}

# -----------------------------------------------------------------------------
# Utility: convert underscores to hyphens (for stack names)
# -----------------------------------------------------------------------------
convert_underscores_to_hyphens() {
  echo "${1//_/-}"
}

# -----------------------------------------------------------------------------
# CloudFormation template validation
# -----------------------------------------------------------------------------
validate_template() {
  local template_file=$1
  echo "Validating: $template_file ..."
  aws cloudformation validate-template \
    --template-body "file://$template_file" \
    --region "$AWS_REGION" \
    > /dev/null
  echo "  [✓] Valid"
}

# -----------------------------------------------------------------------------
# Build CloudFormation parameter overrides from onyx_config.json
# Only keys whose names match a declared parameter in the template are included;
# unknown keys are silently dropped (CloudFormation rejects extra parameters).
#
# Optional second argument: space-separated "Key=Value" pairs injected after
# the config-derived params (e.g. "CertificateArn=arn:aws:acm:..."). These
# are also filtered against the template's declared parameters.
# -----------------------------------------------------------------------------
create_parameters_from_json() {
  local template_file=$1
  local extra_params="${2:-}"  # optional "Key1=Value1 Key2=Value2 ..."
  local temp_params_file="${template_file%.yaml}_parameters.json"

  # Extract parameter keys declared in the CloudFormation template
  local template_params
  template_params=$(python3 -c "
import sys, yaml
with open('$template_file') as f:
    t = yaml.safe_load(f)
params = t.get('Parameters', {})
print(' '.join(params.keys()))
" 2>/dev/null || echo "")

  echo "[" > "$temp_params_file"
  local first=true

  remove_comments "$CONFIG_FILE" | jq -r 'to_entries[] | select(.value != null and .value != "") | "\(.key)|\(.value)"' | \
  while IFS='|' read -r key value; do
    # Skip keys not declared as Parameters in this template
    if [ -n "$template_params" ] && ! echo " $template_params " | grep -q " $key "; then
      continue
    fi
    if [ "$first" = true ]; then
      first=false
    else
      echo "," >> "$temp_params_file"
    fi
    echo "    {\"ParameterKey\": \"$key\", \"ParameterValue\": \"$value\"}" >> "$temp_params_file"
  done

  # Inject extra runtime params (e.g. CertificateArn from ACM stack output)
  if [ -n "$extra_params" ]; then
    for pair in $extra_params; do
      local ex_key="${pair%%=*}"
      local ex_value="${pair#*=}"
      # Only inject if this key is a declared Parameter in the template
      if [ -z "$template_params" ] || echo " $template_params " | grep -q " $ex_key "; then
        # Add a comma separator if any entries were already written
        if grep -q "ParameterKey" "$temp_params_file"; then
          echo "," >> "$temp_params_file"
        fi
        echo "    {\"ParameterKey\": \"$ex_key\", \"ParameterValue\": \"$ex_value\"}" >> "$temp_params_file"
      fi
    done
  fi

  echo "]" >> "$temp_params_file"

  echo "  Parameters file: $temp_params_file" >&2
  cat "$temp_params_file" >&2

  echo "$temp_params_file"
}

# -----------------------------------------------------------------------------
# Deploy a single CloudFormation stack (skip if already exists)
# Optional third argument: space-separated "Key=Value" extra parameter pairs
# forwarded to create_parameters_from_json (e.g. "CertificateArn=arn:...").
# -----------------------------------------------------------------------------
deploy_stack() {
  local stack_name=$1
  local template_file=$2
  local extra_params="${3:-}"

  echo ""
  echo "Stack: $stack_name"
  echo "Checking if stack already exists..."
  if aws cloudformation describe-stacks \
      --stack-name "$stack_name" \
      --region "$AWS_REGION" \
      > /dev/null 2>&1; then
    echo "  [→] Already exists, skipping."
    return 0
  fi

  local temp_params_file
  temp_params_file=$(create_parameters_from_json "$template_file" "$extra_params")

  echo "  Deploying..."
  aws cloudformation deploy \
    --stack-name "$stack_name" \
    --template-file "$template_file" \
    --parameter-overrides "file://$temp_params_file" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
    --region "$AWS_REGION" \
    --no-cli-auto-prompt

  rm -f "$temp_params_file"
  echo "  [✓] Deployed: $stack_name"
}

# -----------------------------------------------------------------------------
# Upload nginx config to S3 (runs after cluster stack so bucket exists)
# -----------------------------------------------------------------------------
upload_nginx_config_to_s3() {
  local nginx_config_dir="$TEMPLATE_DIR/../../../data/nginx"
  local s3_prefix="s3://${S3_BUCKET}/nginx"

  # Source paths for the nginx config files (relative to this repo)
  local conf_template="$nginx_config_dir/app.conf.template"
  local run_script="$nginx_config_dir/run-nginx.sh"

  echo ""
  echo "--- Uploading nginx config to S3 ---"

  if [ ! -f "$conf_template" ]; then
    echo "  [!] WARNING: nginx config template not found at $conf_template"
    echo "  Falling back to fetching from upstream repo..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    curl -fsSL "https://raw.githubusercontent.com/onyx-dot-app/onyx/main/deployment/data/nginx/app.conf.template" \
      -o "$tmp_dir/app.conf.template"
    curl -fsSL "https://raw.githubusercontent.com/onyx-dot-app/onyx/main/deployment/data/nginx/run-nginx.sh" \
      -o "$tmp_dir/run-nginx.sh"
    conf_template="$tmp_dir/app.conf.template"
    run_script="$tmp_dir/run-nginx.sh"
  fi

  aws s3 cp "$conf_template" "${s3_prefix}/app.conf.template" --region "$AWS_REGION"
  aws s3 cp "$run_script"    "${s3_prefix}/run-nginx.sh"      --region "$AWS_REGION"

  echo "  [✓] Nginx config uploaded to ${s3_prefix}/"
}

# -----------------------------------------------------------------------------
# Infra stack deployment loop
# -----------------------------------------------------------------------------
deploy_infra_stacks() {
  echo ""
  echo "=== Deploying Infrastructure Stacks ==="

  for template_name in "${INFRA_ORDER[@]}"; do
    # Skip ACM if HostedZoneId is not set
    if [[ "$template_name" == "onyx_acm_template.yaml" ]]; then
      local hosted_zone_id
      hosted_zone_id=$(remove_comments "$CONFIG_FILE" | jq -r '.HostedZoneId // empty')
      if [ -z "$hosted_zone_id" ] || [ "$hosted_zone_id" = "null" ]; then
        echo ""
        echo "Skipping ACM stack — HostedZoneId is not set in $CONFIG_FILE"
        continue
      fi
    fi

    local template_file="$TEMPLATE_DIR/$template_name"
    local stack_name
    stack_name=$(convert_underscores_to_hyphens "${ENVIRONMENT}-$(basename "$template_name" _template.yaml)")

    if [ -f "$template_file" ]; then
      validate_template "$template_file"
      deploy_stack "$stack_name" "$template_file"

      # After cluster stack: upload nginx config so it is ready for the nginx service
      if [[ "$template_name" == "onyx_cluster_template.yaml" ]]; then
        upload_nginx_config_to_s3
      fi

      # After ACM stack (deployed or pre-existing): capture the cert ARN so the
      # nginx service stack can wire it up as the HTTPS listener certificate.
      if [[ "$template_name" == "onyx_acm_template.yaml" ]]; then
        echo ""
        echo "--- Capturing ACM certificate ARN ---"
        ACM_CERT_ARN=$(aws cloudformation describe-stacks \
          --stack-name "$stack_name" \
          --region "$AWS_REGION" \
          --query 'Stacks[0].Outputs[?OutputKey==`OutputAcm`].OutputValue' \
          --output text 2>/dev/null || echo "")
        if [ -n "$ACM_CERT_ARN" ] && [ "$ACM_CERT_ARN" != "None" ]; then
          echo "  [✓] ACM Certificate ARN: $ACM_CERT_ARN"
          echo "  This will be passed to the nginx stack to enable HTTPS."
        else
          echo "  [!] WARNING: Could not retrieve cert ARN from ACM stack."
          echo "  The nginx service will be deployed without HTTPS."
          ACM_CERT_ARN=""
        fi
      fi
    else
      echo "WARNING: Template not found: $template_file — skipping."
    fi
  done
}

# -----------------------------------------------------------------------------
# Service stack deployment loop
# -----------------------------------------------------------------------------
deploy_service_stacks() {
  echo ""
  echo "=== Deploying Service Stacks ==="

  for template_name in "${SERVICE_ORDER[@]}"; do
    local template_file="$SERVICE_DIR/$template_name"
    local stack_name
    stack_name=$(convert_underscores_to_hyphens "${ENVIRONMENT}-$(basename "$template_name" _template.yaml)")

    # For the nginx stack, inject S3Bucket (always) and the ACM cert ARN
    # (when available) so the s3-sync-container and HTTPS listener are wired up.
    local extra_params=""
    if [[ "$template_name" == "onyx_nginx_service_template.yaml" ]]; then
      extra_params="S3Bucket=$S3_BUCKET"
      if [ -n "$ACM_CERT_ARN" ]; then
        extra_params="$extra_params CertificateArn=$ACM_CERT_ARN"
        echo "  [HTTPS] Injecting CertificateArn into nginx stack parameters."
      fi
    fi

    if [ -f "$template_file" ]; then
      validate_template "$template_file"
      deploy_stack "$stack_name" "$template_file" "$extra_params"
    else
      echo "WARNING: Template not found: $template_file — skipping."
    fi
  done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
if [ "$SKIP_SECRETS_BOOTSTRAP" = false ]; then
  bootstrap_secrets
else
  echo "[--skip-secrets-bootstrap] Skipping Secrets Manager bootstrap."
fi

deploy_infra_stacks
deploy_service_stacks

echo ""
echo "=========================================="
echo "  Deployment complete!"
echo ""

# Print the ALB DNS name and HTTPS URL if available
NGINX_STACK="${ENVIRONMENT}-onyx-nginx-service"
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name "$NGINX_STACK" \
  --region "$AWS_REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`OutputOnyxLoadBalancerDNSName`].OutputValue' \
  --output text 2>/dev/null || echo "")
if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
  echo "  HTTP  URL : http://${ALB_DNS}"
  if [ -n "$ACM_CERT_ARN" ]; then
    DOMAIN=$(remove_comments "$CONFIG_FILE" | jq -r '.DomainName // empty')
    echo "  HTTPS URL : https://${DOMAIN}"
  fi
  echo ""
fi

echo "  Next steps:"
echo "  1. Check service health:  ./monitor.sh"
echo "  2. To update a service:   ./update.sh --service <name>"
echo "  3. To tear everything down: ./uninstall.sh"
echo "=========================================="
