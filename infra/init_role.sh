#!/usr/bin/env bash
# =====================================================================================
# Idempotent IAM bootstrap —— 使用你脚本里的角色名，不乱改：
#   CFN: CloudFormationDeployRole
#   CP : CodePipelineRole
#   CB : CodeBuildRole
# 逻辑：
#   - 若角色不存在则创建并设置信任策略；
#   - 若已存在则不重建，只补齐/更新所需权限；
#   - 统一授予所有 codepipeline-* 桶所需的 S3 读/列举（可选写）权限；
# =====================================================================================

set -euo pipefail
. "$(dirname "$0")/env.sh"

# ===== 角色名（固定为你脚本约定的名称）=====
CFN_ROLE_NAME="${CFN_ROLE_NAME:-CloudFormationDeployRole}"
CP_ROLE_NAME="${CP_ROLE_NAME:-CodePipelineRole}"
CB_ROLE_NAME="${CB_ROLE_NAME:-CodeBuildRole}"

# ===== S3 作用域（所有 CodePipeline 工件桶）=====
ART_S3_ARN_BUCKET="arn:aws:s3:::codepipeline-*"
ART_S3_ARN_OBJECTS="arn:aws:s3:::codepipeline-*/*"

# ===== 账号信息（回显用）=====
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --profile "$AWS_PROFILE")"
REGION="$(aws configure get region --profile "$AWS_PROFILE" || echo "us-east-1")"
echo "==> profile=$AWS_PROFILE account=$ACCOUNT_ID region=$REGION s3Scope=$ART_S3_ARN_OBJECTS"

# ===== 工具函数 =====
tmp() { mktemp -t iamjson.XXXXXX; }
json_file() { local f; f="$(tmp)"; cat >"$f"; echo "$f"; }
role_exists() { aws iam get-role --role-name "$1" --profile "$AWS_PROFILE" >/dev/null 2>&1; }
create_with_trust() { aws iam create-role --role-name "$1" --assume-role-policy-document "file://$2" --profile "$AWS_PROFILE" >/dev/null; }
put_inline_policy() { aws iam put-role-policy --role-name "$1" --policy-name "$2" --policy-document "file://$3" --profile "$AWS_PROFILE" >/dev/null; }
attach_managed_if_missing() {
  local role="$1" arn="$2"
  local has; has="$(aws iam list-attached-role-policies --role-name "$role" --profile "$AWS_PROFILE" \
           --query "AttachedPolicies[?PolicyArn=='${arn}']|length(@)" --output text)"
  [[ "$has" == "1" ]] || aws iam attach-role-policy --role-name "$role" --policy-arn "$arn" --profile "$AWS_PROFILE" >/dev/null
}

# =====================================================================================
# 一、CloudFormationDeployRole
#   - 信任：cloudformation.amazonaws.com
#   - 权限：为简化，附加 AdministratorAccess（可后续收敛）
# =====================================================================================
CFN_TRUST_JSON=$(json_file <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "CFNAssume",
    "Effect": "Allow",
    "Principal": { "Service": "cloudformation.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
)
if role_exists "$CFN_ROLE_NAME"; then
  echo "== $CFN_ROLE_NAME exists"
else
  echo "== Creating $CFN_ROLE_NAME"
  create_with_trust "$CFN_ROLE_NAME" "$CFN_TRUST_JSON"
fi
attach_managed_if_missing "$CFN_ROLE_NAME" "arn:aws:iam::aws:policy/AdministratorAccess"

# =====================================================================================
# 二、CodePipelineRole
#   - 信任：codepipeline.amazonaws.com
#   - 内联策略：
#       * 启动/查询 CodeBuild
#       * 读/列举（必要时写）CodePipeline 工件桶
#       * PassRole -> CodeBuildRole, CloudFormationDeployRole
# =====================================================================================
CP_TRUST_JSON=$(json_file <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "CPAssume",
    "Effect": "Allow",
    "Principal": { "Service": "codepipeline.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
)
if role_exists "$CP_ROLE_NAME"; then
  echo "== $CP_ROLE_NAME exists"
else
  echo "== Creating $CP_ROLE_NAME"
  create_with_trust "$CP_ROLE_NAME" "$CP_TRUST_JSON"
fi

CP_INLINE_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartCodeBuild",
      "Effect": "Allow",
      "Action": ["codebuild:StartBuild","codebuild:BatchGetBuilds"],
      "Resource": "*"
    },
    {
      "Sid": "ArtifactsReadWrite",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion","s3:GetBucketVersioning","s3:PutObject","s3:PutObjectAcl"],
      "Resource": ["$ART_S3_ARN_OBJECTS"]
    },
    {
      "Sid": "ArtifactsList",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["$ART_S3_ARN_BUCKET"]
    },
    {
      "Sid": "PassRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::${ACCOUNT_ID}:role/${CB_ROLE_NAME}",
        "arn:aws:iam::${ACCOUNT_ID}:role/${CFN_ROLE_NAME}"
      ]
    }
  ]
}
JSON
)
put_inline_policy "$CP_ROLE_NAME" "CodePipelineInlinePolicy" "$CP_INLINE_JSON"

# =====================================================================================
# 三、CodeBuildRole
#   - 信任：codebuild.amazonaws.com
#   - 内联策略：
#       * CloudWatch Logs
#       * ECR 推/拉（常见构建场景）
#       * 从 CodePipeline 工件桶读取 & 列举（必要时写）
# =====================================================================================
CB_TRUST_JSON=$(json_file <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "CBAssume",
    "Effect": "Allow",
    "Principal": { "Service": "codebuild.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
JSON
)
if role_exists "$CB_ROLE_NAME"; then
  echo "== $CB_ROLE_NAME exists"
else
  echo "== Creating $CB_ROLE_NAME"
  create_with_trust "$CB_ROLE_NAME" "$CB_TRUST_JSON"
fi

CB_INLINE_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CWLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "*"
    },
    {
      "Sid": "ECR",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3ArtifactsRead",
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion","s3:GetBucketVersioning"],
      "Resource": ["$ART_S3_ARN_OBJECTS"]
    },
    {
      "Sid": "S3ArtifactsList",
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["$ART_S3_ARN_BUCKET"]
    },
    {
      "Sid": "S3ArtifactsWriteOptional",
      "Effect": "Allow",
      "Action": ["s3:PutObject","s3:PutObjectAcl"],
      "Resource": ["$ART_S3_ARN_OBJECTS"]
    }
  ]
}
JSON
)
put_inline_policy "$CB_ROLE_NAME" "CodeBuildInlinePolicy" "$CB_INLINE_JSON"

# 可选托管策略（便于常见场景，已存在则跳过）
attach_managed_if_missing "$CB_ROLE_NAME" "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
attach_managed_if_missing "$CB_ROLE_NAME" "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"

# ===== 输出 =====
echo
echo "== All Roles Ready =="
for role in "$CFN_ROLE_NAME" "$CP_ROLE_NAME" "$CB_ROLE_NAME"; do
  echo "$role = arn:aws:iam::${ACCOUNT_ID}:role/${role}"
done

# ===== 清理临时文件 =====
rm -f "$CFN_TRUST_JSON" "$CP_TRUST_JSON" "$CP_INLINE_JSON" "$CB_TRUST_JSON" "$CB_INLINE_JSON" 2>/dev/null || true