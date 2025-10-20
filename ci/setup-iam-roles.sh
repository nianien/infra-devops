#!/usr/bin/env bash
# =====================================================================================
# Idempotent IAM bootstrap
# - 角色名不变：
#   CFN: CloudFormationDeployRole
#   CP : CodePipelineRole
#   CB : CodeBuildRole
# - 新增：自动覆盖常见 Pipeline Artifact 桶命名：
#     1) 你模板里的 CFN 自动名： *-pipeline-pipelineartifactbucket-*
#     2) 早期/示例名：             codepipeline-*
#   可选：通过环境变量加入精确桶名列表：ARTIFACT_BUCKETS="a,b,c"
#   可选：启用 KMS： export KMS_KEY_ARN="arn:aws:kms:...:key/xxxx"
# =====================================================================================

set -euo pipefail
. "$(dirname "$0")/env.sh"

# ===== 角色名 =====
CFN_ROLE_NAME="${CFN_ROLE_NAME:-CloudFormationDeployRole}"
CP_ROLE_NAME="${CP_ROLE_NAME:-CodePipelineRole}"
CB_ROLE_NAME="${CB_ROLE_NAME:-CodeBuildRole}"

# ===== S3 作用域 =====
# 内置常见模式；并可通过 ARTIFACT_BUCKETS 精确追加
S3_BUCKET_PATTERNS=(
  "*-pipeline-pipelineartifactbucket-*"
  "*-pipelineartifactbucket-*"
  "codepipeline-*"
)

IFS=',' read -r -a EXTRA_BUCKETS <<< "${ARTIFACT_BUCKETS:-}"
for b in "${EXTRA_BUCKETS[@]:-}"; do
  b="${b// }"  # 去除空格
  [[ -n "$b" ]] && S3_BUCKET_PATTERNS+=("$b")
done

# 生成 Resource ARN 列表
S3_ARN_BUCKETS=()
S3_ARN_OBJECTS=()
for pat in "${S3_BUCKET_PATTERNS[@]}"; do
  S3_ARN_BUCKETS+=( "arn:aws:s3:::${pat}" )
  S3_ARN_OBJECTS+=( "arn:aws:s3:::${pat}/*" )
done

# ===== 账号信息 =====
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --profile "$AWS_PROFILE")"
REGION="$(aws configure get region --profile "$AWS_PROFILE" || echo "us-east-1")"
echo "==> profile=$AWS_PROFILE account=$ACCOUNT_ID region=$REGION"
echo "==> artifact buckets scope:"
if [[ ${#S3_ARN_BUCKETS[@]} -gt 0 ]]; then
  printf '    - %s\n' "${S3_ARN_BUCKETS[@]}"
else
  echo "    (no buckets configured)"
fi

# ===== 工具函数 =====
tmp() { mktemp -t iamjson.XXXXXX; }
json_file() { local f; f="$(tmp)"; cat >"$f"; echo "$f"; }
role_exists() { aws iam get-role --role-name "$1" --profile "$AWS_PROFILE" >/dev/null 2>&1; }
create_with_trust() { aws iam create-role --role-name "$1" --assume-role-policy-document "file://$2" --profile "$AWS_PROFILE" >/dev/null; }
put_inline_policy() { aws iam put-role-policy --role-name "$1" --policy-name "$2" --policy-document "file://$3" --profile "$AWS_PROFILE" >/dev/null; }
attach_managed_if_missing() {
  local role="$1" arn="$2"
  local has; has="$(aws iam list-attached-role-policies --role-name "$role" --profile "$AWS_PROFILE" \
           --query "AttachedPolicies[?PolicyArn=='${arn}']|length(@)" --output text 2>/dev/null || echo "0")"
  [[ "$has" == "1" ]] || aws iam attach-role-policy --role-name "$role" --policy-arn "$arn" --profile "$AWS_PROFILE" >/dev/null
}

# =====================================================================================
# 一、CloudFormationDeployRole
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
#   - 需要读/写 artifact 桶（下载上游、上传下游）
#   - 需要 PassRole -> CodeBuildRole, CloudFormationDeployRole
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

# 拼接 S3 资源数组到 JSON
to_json_array() {
  local arr_name="$1"
  local arr_ref="${arr_name}[@]"
  local arr=("${!arr_ref}")
  if [[ ${#arr[@]} -eq 0 ]]; then
    echo '[]'
  else
    printf '[%s]\n' "$(printf '"%s",' "${arr[@]}" | sed 's/,$//')"
  fi
}
CP_S3_BUCKETS_JSON="$(to_json_array S3_ARN_BUCKETS)"
CP_S3_OBJECTS_JSON="$(to_json_array S3_ARN_OBJECTS)"

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
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": ${CP_S3_BUCKETS_JSON}
    },
    {
      "Sid": "ArtifactsObjectsRW",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject","s3:GetObjectVersion",
        "s3:PutObject","s3:PutObjectAcl",
        "s3:AbortMultipartUpload"
      ],
      "Resource": ${CP_S3_OBJECTS_JSON}
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

# CodePipeline 额外 S3 权限（用于所有 Pipeline Artifacts）
CP_S3_EXTRA_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3FullAccessAllPipelineArtifactBuckets",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::*pipelineartifactbucket*",
        "arn:aws:s3:::*pipelineartifactbucket*/*"
      ]
    }
  ]
}
JSON
)
put_inline_policy "$CP_ROLE_NAME" "S3FullAllPipelineArtifactBuckets" "$CP_S3_EXTRA_JSON"

# =====================================================================================
# 三、CodeBuildRole
#   - 需要从 artifact 桶读取输入、写出输出；需要 ECR & Logs
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

CB_S3_BUCKETS_JSON="$(to_json_array S3_ARN_BUCKETS)"
CB_S3_OBJECTS_JSON="$(to_json_array S3_ARN_OBJECTS)"

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
      "Sid": "S3ArtifactsBucketMeta",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": ${CB_S3_BUCKETS_JSON}
    },
    {
      "Sid": "S3ArtifactsObjectsRW",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject","s3:GetObjectVersion",
        "s3:PutObject","s3:PutObjectAcl",
        "s3:AbortMultipartUpload"
      ],
      "Resource": ${CB_S3_OBJECTS_JSON}
    }
  ]
}
JSON
)
put_inline_policy "$CB_ROLE_NAME" "CodeBuildInlinePolicy" "$CB_INLINE_JSON"

# CodeBuild 额外 S3 权限（用于读取 Pipeline Artifacts）
CB_S3_EXTRA_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3FullAccessAllPipelineArtifactBuckets",
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::*pipelineartifactbucket*",
        "arn:aws:s3:::*pipelineartifactbucket*/*"
      ]
    }
  ]
}
JSON
)
put_inline_policy "$CB_ROLE_NAME" "S3FullAllPipelineArtifactBuckets" "$CB_S3_EXTRA_JSON"

# CodeBuild GitHub 连接权限
CB_GITHUB_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CodeStarConnections",
      "Effect": "Allow",
      "Action": [
        "codestar-connections:UseConnection"
      ],
      "Resource": [
        "arn:aws:codestar-connections:ap-southeast-2:297997107448:connection/c1821d00-2845-4f52-a79c-5100c0d5620a"
      ]
    }
  ]
}
JSON
)
put_inline_policy "$CB_ROLE_NAME" "CodeBuildGitHubAccess" "$CB_GITHUB_JSON"

# 可选托管策略
attach_managed_if_missing "$CB_ROLE_NAME" "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
attach_managed_if_missing "$CB_ROLE_NAME" "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"

# =====================================================================================
# 四、可选 KMS（若 ArtifactStore 用 CMK）
# =====================================================================================
if [[ -n "${KMS_KEY_ARN:-}" ]]; then
  echo "== Attach KMS policy to CP/CB for ${KMS_KEY_ARN}"
  KMS_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "KmsForArtifacts",
    "Effect": "Allow",
    "Action": [
      "kms:Decrypt","kms:Encrypt","kms:ReEncrypt*",
      "kms:GenerateDataKey*","kms:DescribeKey"
    ],
    "Resource": "${KMS_KEY_ARN}"
  }]
}
JSON
)
  put_inline_policy "$CP_ROLE_NAME" "CodePipelineKmsForArtifacts" "$KMS_JSON"
  put_inline_policy "$CB_ROLE_NAME" "CodeBuildKmsForArtifacts" "$KMS_JSON"
fi

# ===== 清理临时文件 =====
cleanup() {
  rm -f /tmp/iamjson.* 2>/dev/null || true
}
trap cleanup EXIT

# ===== 输出 =====
echo
echo "== All Roles Ready =="
for role in "$CFN_ROLE_NAME" "$CP_ROLE_NAME" "$CB_ROLE_NAME"; do
  echo "$role = arn:aws:iam::${ACCOUNT_ID}:role/${role}"
done