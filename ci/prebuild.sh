#!/usr/bin/env bash
set -euo pipefail

# InfraOut 为主输入 → $CODEBUILD_SRC_DIR
# AppOut  为次输入 → $CODEBUILD_SRC_DIR_AppOut（需 CODEBUILD_CLONE_REF）
INFRA_ROOT="${CODEBUILD_SRC_DIR:-.}"
APP_ROOT="${CODEBUILD_SRC_DIR_AppOut:-$INFRA_ROOT}"

echo "== Environment variables check =="
: "${SERVICE_NAME:?[FATAL] Missing SERVICE_NAME}"
: "${APP_ENV:?[FATAL] Missing APP_ENV}"
: "${LANE:?[FATAL] Missing LANE}"
: "${BRANCH:?[FATAL] Missing BRANCH}"
echo "MODULE_PATH=${MODULE_PATH:-.}"
echo "SERVICE_NAME=${SERVICE_NAME}"
echo "APP_ENV=${APP_ENV}"
echo "LANE=${LANE}"
echo "BRANCH=${BRANCH}"

# --- 切分支（在 AppOut 仓库） ---
pushd "$APP_ROOT" >/dev/null
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD || echo '')"
echo "== Current branch: ${CURRENT_BRANCH}"
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
  echo "== Switching branch to ${BRANCH} =="
  git fetch --no-tags origin "$BRANCH" --depth=1 || { echo "[FATAL] Branch ${BRANCH} not found on origin"; exit 1; }
  git checkout -B "$BRANCH" "origin/$BRANCH"
fi
# 用切换后的 HEAD 生成短提交号
COMMIT7="$(git rev-parse --short=7 HEAD || true)"
git log -1 --oneline || true
popd >/dev/null

# --- 计算 ECR REPO & 登录 ---
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
ECR_REPO_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${SERVICE_NAME}"
export ECR_REPO_URI
# --- 生成镜像 TAG（时间戳.提交号） ---
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
IMAGE_TAG="${TIMESTAMP}.${COMMIT7:-latest}"
export IMAGE_TAG

echo "== Ensure ECR repo & login =="
aws ecr describe-repositories --repository-names "${SERVICE_NAME}" --region "$AWS_REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${SERVICE_NAME}" --region "$AWS_REGION" >/dev/null
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${ECR_REPO_URI%%/*}"

echo "==> IMAGE_TAG=$IMAGE_TAG"
echo "==> ECR_REPO_URI=$ECR_REPO_URI"

# 跨阶段共享（给 build / post_build 用）
{
  echo "ECR_REPO_URI=$ECR_REPO_URI"
  echo "IMAGE_TAG=$IMAGE_TAG"
} | tee -a /tmp/ci_env