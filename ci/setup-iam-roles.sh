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
CB_ROLE_NAME="${CB_ROLE_NAME:-CodeBuildServiceRole}"

# ===== S3 作用域 =====
# 使用通配符覆盖所有 pipelineartifactbucket 桶
S3_ARTIFACT_BUCKET_PATTERN="*pipelineartifactbucket*"

# ===== 账号信息 =====
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text --profile "$AWS_PROFILE")"
REGION="$(aws configure get region --profile "$AWS_PROFILE" || echo "us-east-1")"
echo "==> profile=$AWS_PROFILE account=$ACCOUNT_ID region=$REGION"
echo "==> artifact buckets scope: $S3_ARTIFACT_BUCKET_PATTERN"

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
        "arn:aws:s3:::${S3_ARTIFACT_BUCKET_PATTERN}",
        "arn:aws:s3:::${S3_ARTIFACT_BUCKET_PATTERN}/*"
      ]
    }
  ]
}
JSON
)
put_inline_policy "$CP_ROLE_NAME" "S3FullAllPipelineArtifactBuckets" "$CP_S3_EXTRA_JSON"

# CodePipeline 广泛权限策略（匹配线上实际配置）
CP_EXTENSIVE_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:GetBucketLocation",
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild",
        "cloudformation:*",
        "codestar-connections:UseConnection",
        "iam:PassRole",
        "ecs:*",
        "ecr:*",
        "logs:*",
        "lambda:*",
        "sts:AssumeRole"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)
put_inline_policy "$CP_ROLE_NAME" "inline-codepipeline-policy" "$CP_EXTENSIVE_JSON"

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
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning"
      ],
      "Resource": [
        "arn:aws:s3:::codepipeline-*/*"
      ]
    },
    {
      "Sid": "S3ArtifactsList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::codepipeline-*"
      ]
    },
    {
      "Sid": "S3ArtifactsWriteOptional",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectAcl"
      ],
      "Resource": [
        "arn:aws:s3:::codepipeline-*/*"
      ]
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
        "arn:aws:s3:::${S3_ARTIFACT_BUCKET_PATTERN}",
        "arn:aws:s3:::${S3_ARTIFACT_BUCKET_PATTERN}/*"
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

# CodeBuild ECR 创建仓库权限
CB_ECR_CREATE_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrCreateRepoAll",
      "Effect": "Allow",
      "Action": [
        "ecr:CreateRepository",
        "ecr:DescribeRepositories"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)
put_inline_policy "$CB_ROLE_NAME" "CodeBuildEcrCreateRepo" "$CB_ECR_CREATE_JSON"

# CodeBuild Pipeline 访问权限
CB_PIPELINE_ACCESS_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CodePipelineAccess",
      "Effect": "Allow",
      "Action": [
        "codepipeline:GetPipeline",
        "codepipeline:GetPipelineState",
        "codepipeline:GetPipelineExecution",
        "codepipeline:ListPipelineExecutions"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)
put_inline_policy "$CB_ROLE_NAME" "CodeBuildPipelineAccess" "$CB_PIPELINE_ACCESS_JSON"

# CodeBuild KMS 访问权限
CB_KMS_ACCESS_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "KmsAccess",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*"
      ],
      "Resource": [
        "arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:alias/aws/s3",
        "arn:aws:kms:${AWS_REGION}:${ACCOUNT_ID}:key/*"
      ]
    }
  ]
}
JSON
)
put_inline_policy "$CB_ROLE_NAME" "CodeBuildKmsAccess" "$CB_KMS_ACCESS_JSON"

# CodeBuild CodeArtifact 访问权限（可选）
CB_CODEARTIFACT_JSON=$(json_file <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CodeArtifactAccess",
      "Effect": "Allow",
      "Action": [
        "codeartifact:GetAuthorizationToken",
        "codeartifact:GetRepositoryEndpoint",
        "codeartifact:ReadFromRepository",
        "codeartifact:DescribeDomain",
        "codeartifact:DescribeRepository"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)
put_inline_policy "$CB_ROLE_NAME" "CodeBuildCodeArtifactAccess" "$CB_CODEARTIFACT_JSON"

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