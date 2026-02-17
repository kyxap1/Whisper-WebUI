#!/usr/bin/env bash
set -euo pipefail

# Logging helpers
_date=$(command -v gdate || command -v date)
log()   { printf '[%s] [INFO] %s\n' "$($_date '+%Y-%m-%d %H:%M:%S.%3N')" "$*"; }
warn()  { printf '[%s] [WARN] %s\n' "$($_date '+%Y-%m-%d %H:%M:%S.%3N')" "$*" >&2; }
error() { printf '[%s] [ERROR] %s\n' "$($_date '+%Y-%m-%d %H:%M:%S.%3N')" "$*" >&2; }

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
  error "env: TARGET_ENV or AWS_PROFILE must be set."
  exit 1
fi

# Ensure region is set
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "$AWS_REGION" ]]; then
  error "env: AWS_REGION or AWS_DEFAULT_REGION must be set."
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
      error "prereq: '$bin' not found."
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
    log "dynamodb: '$table' already exists."
    return
  fi

  log "dynamodb: creating '$table'..."
  aws dynamodb create-table \
    --table-name "$table" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION" >/dev/null

  log "dynamodb: waiting for '$table'..."
  aws dynamodb wait table-exists --table-name "$table"
  log "dynamodb: '$table' created."
}

ensure_bucket() {
  local bucket="$1"

  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    log "bucket: '$bucket' already exists."
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
    log "backend: '$BUCKET' already configured."
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

  log "bucket: creating '$bucket' in '$AWS_REGION'..."

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

  log "bucket: '$bucket' created."
}

ensure_logging() {
  local bucket="$1"
  local target_prefix
  target_prefix="${bucket#${ENV_NAME_LC}-}"

  if aws s3api head-bucket --bucket "$LOG_BUCKET" >/dev/null 2>&1; then
    local current
    current=$(aws s3api get-bucket-logging --bucket "$bucket" --query 'LoggingEnabled' --output json)
    if [[ "$current" != "null" ]]; then
      log "logging: '$bucket' already configured."
      return
    fi

    log "logging: configuring '$bucket'..."
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
    log "logging: '$bucket' configured."
  else
    warn "logging: log bucket '$LOG_BUCKET' does not exist."
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
    log "versioning: configuring '$bucket'..."
    aws s3api put-bucket-versioning \
      --bucket "$bucket" \
      --versioning-configuration Status=Enabled
  else
    log "versioning: '$bucket' already configured."
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
    log "object-lock: configuring '$bucket'..."
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
    log "object-lock: '$bucket' already configured."
  fi
}

policy_secure_transport() {
  local bucket="$1"
  jq -n \
    --arg bucket "$bucket" \
    --arg account "$ACCOUNT_ID" \
    '[
      {
        "Sid": "DenyInsecureTransport",
        "Effect": "Deny",
        "Principal": "*",
        "Action": "s3:*",
        "Resource": [
          "arn:aws:s3:::\($bucket)",
          "arn:aws:s3:::\($bucket)/*"
        ],
        "Condition": {
          "Bool": {
            "aws:SecureTransport": "false"
          }
        }
      },
      {
        "Sid": "DenyOutdatedTLS",
        "Effect": "Deny",
        "Principal": "*",
        "Action": "s3:*",
        "Resource": [
          "arn:aws:s3:::\($bucket)",
          "arn:aws:s3:::\($bucket)/*"
        ],
        "Condition": {
          "NumericLessThan": {
            "s3:TlsVersion": "1.2"
          }
        }
      }
    ]'
}

policy_allow_logs() {
  local bucket="$1"
  jq -n \
    --arg bucket "$bucket" \
    --arg account "$ACCOUNT_ID" \
    '[
      {
        "Sid": "AllowS3ServerAccessLogs",
        "Effect": "Allow",
        "Principal": {
          "Service": "logging.s3.amazonaws.com"
        },
        "Action": "s3:PutObject",
        "Resource": "arn:aws:s3:::\($bucket)/*",
        "Condition": {
          "StringEquals": {
            "aws:SourceAccount": $account
          }
        }
      },
      {
        "Sid": "AllowCloudTrailLogs",
        "Effect": "Allow",
        "Principal": {
          "Service": "cloudtrail.amazonaws.com"
        },
        "Action": "s3:PutObject",
        "Resource": "arn:aws:s3:::\($bucket)/*",
        "Condition": {
          "StringEquals": {
            "s3:x-amz-acl": "bucket-owner-full-control",
            "aws:SourceArn": "arn:aws:cloudtrail:*:\($account):trail/*"
          }
        }
      },
      {
        "Sid": "AllowCloudTrailAclCheck",
        "Effect": "Allow",
        "Principal": {
          "Service": "cloudtrail.amazonaws.com"
        },
        "Action": "s3:GetBucketAcl",
        "Resource": "arn:aws:s3:::\($bucket)",
        "Condition": {
          "StringEquals": {
            "aws:SourceArn": "arn:aws:cloudtrail:*:\($account):trail/*"
          }
        }
      },
      {
        "Sid": "AllowALBNLBWAFLogs",
        "Effect": "Allow",
        "Principal": {
          "Service": "delivery.logs.amazonaws.com"
        },
        "Action": "s3:PutObject",
        "Resource": "arn:aws:s3:::\($bucket)/*",
        "Condition": {
          "StringEquals": {
            "s3:x-amz-acl": "bucket-owner-full-control",
            "aws:SourceAccount": $account
          }
        }
      },
      {
        "Sid": "AllowALBNLBWAFAclCheck",
        "Effect": "Allow",
        "Principal": {
          "Service": "delivery.logs.amazonaws.com"
        },
        "Action": "s3:GetBucketAcl",
        "Resource": "arn:aws:s3:::\($bucket)",
        "Condition": {
          "StringEquals": {
            "aws:SourceAccount": $account
          }
        }
      },
      {
        "Sid": "AllowELBLogs",
        "Effect": "Allow",
        "Principal": {
          "Service": "logdelivery.elasticloadbalancing.amazonaws.com"
        },
        "Action": "s3:PutObject",
        "Resource": "arn:aws:s3:::\($bucket)/*"
      }
    ]'
}

policy_delete_protection() {
  local bucket="$1"
  jq -n \
    --arg bucket "$bucket" \
    --arg account "$ACCOUNT_ID" \
    '[
      {
        "Sid": "DenyDeleteStateExceptRoot",
        "Effect": "Deny",
        "Principal": "*",
        "Action": [
          "s3:DeleteObject",
          "s3:DeleteObjectVersion"
        ],
        "NotResource": "arn:aws:s3:::\($bucket)/*.tflock",
        "Condition": {
          "StringNotLike": {
            "aws:PrincipalArn": "arn:aws:iam::\($account):root"
          }
        }
      }
    ]'
}

build_bucket_policy() {
  jq -s '{Version: "2012-10-17", Statement: add}'
}

apply_bucket_policy() {
  local bucket="$1"
  shift

  # Build policy from statement generators
  local policy
  policy=$(for fn in "$@"; do "$fn" "$bucket"; done | build_bucket_policy)

  # Compare existing vs desired policy by Sid list (idempotency check)
  local current_policy
  current_policy=$(aws s3api get-bucket-policy --bucket "$bucket" --query 'Policy' --output text 2>/dev/null || echo "")

  local current_sids desired_sids
  current_sids=$(echo "$current_policy" | jq -r '[.Statement[].Sid] | sort | join(",")' 2>/dev/null || echo "")
  desired_sids=$(echo "$policy" | jq -r '[.Statement[].Sid] | sort | join(",")' 2>/dev/null || echo "")

  if [[ "$current_sids" == "$desired_sids" && -n "$current_sids" ]]; then
    log "policy: '$bucket' already configured."
    return
  fi

  log "policy: configuring '$bucket'..."
  aws s3api put-bucket-policy \
    --bucket "$bucket" \
    --policy "$policy"
  log "policy: '$bucket' configured."
}

ensure_lifecycle() {
  local bucket="$1"
  local lifecycle
  lifecycle=$(aws s3api get-bucket-lifecycle-configuration \
    --bucket "$bucket" \
    --query 'Rules' \
    --output json 2>/dev/null || echo "")

  if [[ -n "$lifecycle" && "$lifecycle" != "null" ]]; then
    log "lifecycle: '$bucket' already configured."
    return
  fi

  log "lifecycle: configuring '$bucket'..."
  local config
  config=$(jq -n '{
    "Rules": [
      {
        "ID": "TerraformStateLifecycle",
        "Status": "Enabled",
        "Filter": {},
        "NoncurrentVersionTransitions": [
          {"NoncurrentDays": 30, "StorageClass": "STANDARD_IA"},
          {"NoncurrentDays": 60, "StorageClass": "GLACIER_IR"}
        ],
        "NoncurrentVersionExpiration": {"NoncurrentDays": 365},
        "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
      }
    ]
  }')

  aws s3api put-bucket-lifecycle-configuration \
    --bucket "$bucket" \
    --lifecycle-configuration "$config"
  log "lifecycle: '$bucket' configured."
}

get_tfvars() {
  local value
  log "ssm: checking '$TFVARS_PARAM'..."

  if ! aws ssm get-parameter --name "$TFVARS_PARAM" --with-decryption >/dev/null 2>&1; then
    log "ssm: parameter not found, creating..."
    aws ssm put-parameter \
      --name "$TFVARS_PARAM" \
      --type "SecureString" \
      --description "tfvars for workspace $DIR" \
      --value "empty"
    value="empty"
  else
    log "ssm: parameter found, downloading..."
    value=$(aws ssm get-parameter \
      --name "$TFVARS_PARAM" \
      --with-decryption \
      --query 'Parameter.Value' \
      --output text)
  fi

  local tfvars_file=$TFVARS_FILE
  if [[ "$value" == "empty" ]]; then
    if [[ -s $tfvars_file ]]; then
      warn "tfvars: SSM is empty but '$tfvars_file' has content, skipping."
      return
    fi
    log "tfvars: creating empty '$tfvars_file'..."
  else
    if [[ -s $tfvars_file ]]; then
      local local_sum=$(sha256sum $tfvars_file | awk '{print $1}')
      local remote_sum=$(printf '%s\n' "$value" | sha256sum | awk '{print $1}')

      if [[ $local_sum != $remote_sum ]]; then
        error "tfvars: '$tfvars_file' differs from SSM."
        error "tfvars: local=$local_sum remote=$remote_sum"
        exit 1
      else
        log "tfvars: '$tfvars_file' matches SSM."
        return
      fi
    fi
    log "tfvars: writing SSM value to '$tfvars_file'..."
  fi

  echo "$value" > $tfvars_file
}

init_backend() {
  log "terraform: initializing backend..."

  local lock_config
  if supports_native_locking; then
    log "terraform: version >= 1.10, using native S3 locking."
    lock_config="-backend-config=use_lockfile=true"
  else
    log "terraform: version < 1.10, using DynamoDB locking."
    lock_config="-backend-config=dynamodb_table=$LOCK_TABLE"
  fi

  terraform init \
    -backend-config="bucket=$BUCKET" \
    -backend-config="key=$DIR/terraform.tfstate" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="encrypt=true" \
    $lock_config

  log "terraform: backend initialized."
}

# Execute steps
check_prerequisites
get_tfvars
if ensure_bucket "$BUCKET"; then
  ensure_backend
fi

# Log bucket first (so state bucket can log to it)
log "--- log-bucket: '$LOG_BUCKET' ---"
create_bucket "$LOG_BUCKET"
ensure_versioning "$LOG_BUCKET"
apply_bucket_policy "$LOG_BUCKET" policy_secure_transport policy_allow_logs
ensure_lifecycle "$LOG_BUCKET"

# State bucket (with object-lock and logging)
log "--- state-bucket: '$BUCKET' ---"
create_bucket "$BUCKET" "true"
ensure_logging "$BUCKET"
ensure_versioning "$BUCKET"
ensure_object_lock "$BUCKET"
apply_bucket_policy "$BUCKET" policy_secure_transport policy_delete_protection
ensure_lifecycle "$BUCKET"

# Lock table (only for Terraform < 1.10)
if ! supports_native_locking; then
  create_lock_table "$LOCK_TABLE"
fi

init_backend
