#!/usr/bin/env bash
set -euo pipefail

# Get the absolute path to the Git repository root
REPO_ROOT=$(git rev-parse --show-toplevel)
CURRENT_DIR=$(pwd)

# Compute the relative path from the repo root to the current directory
if [[ "$CURRENT_DIR" == "$REPO_ROOT" ]]; then
  DIR=root
else
  DIR="${CURRENT_DIR#$REPO_ROOT/}"
fi

# Determine environment name (TARGET_ENV for CI, AWS_PROFILE for local)
if [[ -n "${TARGET_ENV:-}" ]]; then
  ENV_NAME="$TARGET_ENV"
elif [[ -n "${AWS_PROFILE:-}" ]]; then
  ENV_NAME="$AWS_PROFILE"
else
  echo "Either TARGET_ENV or AWS_PROFILE must be set." >&2
  exit 1
fi

# Ensure region is set
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "$AWS_REGION" ]]; then
  echo "AWS_REGION or AWS_DEFAULT_REGION must be set." >&2
  exit 1
fi

# Static vars
PREREQUISITES=(aws terraform sha256sum jq)

# Dynamic vars
ENV_NAME_LC=${ENV_NAME,,}
SUFFIX=$(echo "$ENV_NAME_LC" | sha256sum | cut -c-8)
BUCKET="${ENV_NAME_LC}-terraform-state-$SUFFIX"
LOG_BUCKET="${ENV_NAME_LC}-logs-$SUFFIX"
TFVARS_FILE="${ENV_NAME_LC}.tfvars"
TFVARS_PARAM="/${ENV_NAME_LC}/terraform/${DIR}"
LOCK_TABLE="${ENV_NAME_LC}-terraform-lock-$SUFFIX"
SCRIPT_DIR="${BASH_SOURCE%/*}"
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

# Functions
check_prerequisites() {
  for bin in "${PREREQUISITES[@]}"; do
    if ! type -P "$bin" >/dev/null 2>&1; then
      echo "ERROR: Required binary '$bin' not found." >&2
      exit 1
    fi
  done
}

get_terraform_version() {
  terraform version -json | jq -r '.terraform_version'
}

supports_native_locking() {
  local version major minor
  version=$(get_terraform_version)
  major=$(echo "$version" | cut -d. -f1)
  minor=$(echo "$version" | cut -d. -f2)
  [[ "$major" -gt 1 ]] || { [[ "$major" -eq 1 ]] && [[ "$minor" -ge 10 ]]; }
}

create_lock_table() {
  local table="$1"

  if aws dynamodb describe-table --table-name "$table" >/dev/null 2>&1; then
    echo "DynamoDB table '$table' exists."
    return
  fi

  echo "Creating DynamoDB table '$table'..."
  aws dynamodb create-table \
    --table-name "$table" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION" >/dev/null

  echo "Waiting for table '$table' to become active..."
  aws dynamodb wait table-exists --table-name "$table"
  echo "DynamoDB table '$table' created."
}

ensure_bucket() {
  local bucket="$1"

  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "Bucket '$bucket' exists."
    return 0
  else

    return 1
  fi
}

ensure_backend() {
  local tf_state=".terraform/terraform.tfstate"
  [[ ! -f "$tf_state" ]] && return

  local current_bucket current_region
  current_bucket=$(jq -r '.backend.config.bucket // empty' "$tf_state")
  current_region=$(jq -r '.backend.config.region // empty' "$tf_state")
  
  if [[ "$current_bucket" == "$BUCKET" && "$current_region" == "$AWS_REGION" ]]; then
    echo "Backend already configured for '$BUCKET'. Skipping."
    exit 0
  fi
  return
}

create_bucket() {
  local bucket="$1"
  local with_object_lock="${2:-false}"

  if ensure_bucket "$bucket"; then
    return
  fi

  echo "Creating bucket '$bucket' in region '$AWS_REGION'..."

  if [[ "$with_object_lock" == "true" ]]; then
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket \
        --bucket "$bucket" \
        --region "$AWS_REGION" \
        --object-lock-enabled-for-bucket
    else
      aws s3api create-bucket \
        --bucket "$bucket" \
        --region "$AWS_REGION" \
        --object-lock-enabled-for-bucket \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
  else
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket \
        --bucket "$bucket" \
        --region "$AWS_REGION"
    else
      aws s3api create-bucket \
        --bucket "$bucket" \
        --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
  fi

  echo "Bucket created: $bucket"
}

ensure_logging() {
  local bucket="$1"
  local target_prefix
  target_prefix="${bucket#${ENV_NAME_LC}-}"

  if aws s3api head-bucket --bucket "$LOG_BUCKET" >/dev/null 2>&1; then
    local current
    current=$(aws s3api get-bucket-logging --bucket "$bucket" --query 'LoggingEnabled' --output json)
    if [[ "$current" != "null" ]]; then
      echo "Logging already configured for bucket '$bucket'."
      return
    fi

    echo "Enabling logging to bucket '$LOG_BUCKET'..."
    aws s3api put-bucket-logging \
      --bucket "$bucket" \
      --bucket-logging-status "$(cat <<EOF
{
  "LoggingEnabled": {
    "TargetBucket": "$LOG_BUCKET",
    "TargetPrefix": "$target_prefix/"
  }
}
EOF
)"
    echo "Logging enabled for bucket '$bucket'."
  else
    echo "Log bucket '$LOG_BUCKET' does not exist."
  fi
}

ensure_versioning() {
  local bucket="$1"
  local status
  status=$(aws s3api get-bucket-versioning \
    --bucket "$bucket" \
    --query 'Status' \
    --output text || true)

  if [[ "$status" != "Enabled" ]]; then
    echo "Enabling versioning on '$bucket'..."
    aws s3api put-bucket-versioning \
      --bucket "$bucket" \
      --versioning-configuration Status=Enabled
  else
    echo "Versioning already enabled on '$bucket'."
  fi
}

ensure_object_lock() {
  local bucket="$1"
  local lock
  lock=$(aws s3api get-object-lock-configuration \
    --bucket "$bucket" \
    --query 'ObjectLockConfiguration.ObjectLockEnabled' \
    --output text || true)
  if [[ "$lock" != "Enabled" ]]; then
    echo "Enabling object lock configuration on '$bucket'..."
    aws s3api put-object-lock-configuration \
      --bucket "$bucket" \
      --object-lock-configuration '{
        "ObjectLockEnabled": "Enabled",
        "Rule": {
          "DefaultRetention": {
            "Mode": "GOVERNANCE",
            "Days": 30
          }
        }
      }'
  else
    echo "Object lock already enabled on '$bucket'."
  fi
}

ensure_secure_transport() {
  local bucket="$1"
  local current_policy
  current_policy=$(aws s3api get-bucket-policy --bucket "$bucket" --query 'Policy' --output text 2>/dev/null || echo "")

  if echo "$current_policy" | grep -q '"Sid":"DenyInsecureTransport"'; then
    echo "TLS-only policy already exists on bucket '$bucket'."
    return
  fi

  echo "Applying security policy to bucket '$bucket'..."
  local policy
  policy=$(jq -n \
    --arg bucket "$bucket" \
    --arg account "$ACCOUNT_ID" \
    -f "$SCRIPT_DIR/templates/s3-bucket-policy.json.template")

  aws s3api put-bucket-policy \
    --bucket "$bucket" \
    --policy "$policy"
  echo "Security policy applied to bucket '$bucket'."
}

ensure_lifecycle() {
  local bucket="$1"
  local lifecycle
  lifecycle=$(aws s3api get-bucket-lifecycle-configuration \
    --bucket "$bucket" \
    --query 'Rules' \
    --output json 2>/dev/null || echo "")

  if [[ -n "$lifecycle" && "$lifecycle" != "null" ]]; then
    echo "Lifecycle configuration already set on bucket '$bucket'."
    return
  fi

  echo "Applying lifecycle configuration to bucket '$bucket'..."
  local config
  config=$(jq -n \
    -f "$SCRIPT_DIR/templates/s3-lifecycle.json.template")

  aws s3api put-bucket-lifecycle-configuration \
    --bucket "$bucket" \
    --lifecycle-configuration "$config"
  echo "Lifecycle configuration applied."
}

get_tfvars() {
  local value
  echo "Checking for tfvars parameter in SSM: $TFVARS_PARAM"

  if ! aws ssm get-parameter --name "$TFVARS_PARAM" --with-decryption >/dev/null 2>&1; then
    echo "SSM parameter not found. Creating new default parameter..."
    aws ssm put-parameter \
      --name "$TFVARS_PARAM" \
      --type "SecureString" \
      --description "tfvars for workspace $DIR" \
      --value "empty"
    value="empty"
  else
    echo "SSM parameter exists. Downloading value..."
    value=$(aws ssm get-parameter \
      --name "$TFVARS_PARAM" \
      --with-decryption \
      --query 'Parameter.Value' \
      --output text)
  fi

  local tfvars_file=$TFVARS_FILE
  if [[ "$value" == "empty" ]]; then
    if [[ -s $tfvars_file ]]; then
      echo "SSM parameter $TFVARS_PARAM is empty, but $tfvars_file is not empty. Not overwriting."
      return
    fi
    echo "Initializing empty $tfvars_file"
  else
    if [[ -s $tfvars_file ]]; then
      local local_sum=$(sha256sum $tfvars_file | awk '{print $1}')
      local remote_sum=$(printf '%s\n' "$value" | sha256sum | awk '{print $1}')

      if [[ $local_sum != $remote_sum ]]; then
        echo "ERROR: Local $tfvars_file differs from SSM. Aborting." >&2
        echo "Local:  $local_sum" >&2
        echo "Remote: $remote_sum" >&2
        exit 1
      else
        echo "Local $tfvars_file matches SSM. Not overwriting."
        return
      fi
    fi
    echo "Writing remote value to $tfvars_file"
  fi

  echo "$value" > $tfvars_file
}

init_backend() {
  echo "Initializing Terraform backend..."

  local lock_config
  if supports_native_locking; then
    echo "Terraform >= 1.10 detected. Using native S3 locking."
    lock_config="-backend-config=use_lockfile=true"
  else
    echo "Terraform < 1.10 detected. Using DynamoDB for state locking."
    lock_config="-backend-config=dynamodb_table=$LOCK_TABLE"
  fi

  terraform init \
    -backend-config="bucket=$BUCKET" \
    -backend-config="key=$DIR/terraform.tfstate" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="encrypt=true" \
    $lock_config

  echo "Terraform backend initialized."
}

# Execute steps
check_prerequisites
get_tfvars
if ensure_bucket "$BUCKET"; then
  ensure_backend
fi

# Log bucket first (so state bucket can log to it)
create_bucket "$LOG_BUCKET"
ensure_versioning "$LOG_BUCKET"
ensure_secure_transport "$LOG_BUCKET"
ensure_lifecycle "$LOG_BUCKET"

# State bucket (with object-lock and logging)
create_bucket "$BUCKET" "true"
ensure_logging "$BUCKET"
ensure_versioning "$BUCKET"
ensure_object_lock "$BUCKET"
ensure_secure_transport "$BUCKET"
ensure_lifecycle "$BUCKET"

# Lock table (only for Terraform < 1.10)
if ! supports_native_locking; then
  create_lock_table "$LOCK_TABLE"
fi

init_backend
