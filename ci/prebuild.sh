#!/usr/bin/env bash
set -euo pipefail

echo "== Environment variables check =="
echo "MODULE_PATH=${MODULE_PATH:-.}"
echo "SERVICE_NAME=${SERVICE_NAME:-}"
echo "APP_ENV=${APP_ENV:-}"
echo "LANE=${LANE:-}"
echo "BRANCH=${BRANCH:-}"

# --- 目录就绪性 ---
SRC_DIR="${CODEBUILD_SRC_DIR:-}"
APP_OUT_DIR="${CODEBUILD_SRC_DIR_AppOut}"

if [[ -z "$SRC_DIR" || ! -d "$SRC_DIR" ]]; then
  echo "[FATAL] Primary source dir not found: CODEBUILD_SRC_DIR='${SRC_DIR:-<empty>}'"
  exit 1
fi

if [[ -z "$APP_OUT_DIR" || ! -d "$APP_OUT_DIR" ]]; then
  echo "[FATAL] AppOut directory not found. ${APP_OUT_DIR_VAR}='${APP_OUT_DIR:-<empty>}'"
  exit 1
fi

echo "== Sources =="
echo "Primary: ${SRC_DIR}"
echo "AppOut : ${APP_OUT_DIR}"

COMMIT7="$(cd "${APP_OUT_DIR}" && git rev-parse --short=7 HEAD 2>/dev/null || echo 'latest')"
echo "== AppOut commit: ${COMMIT7}"

# --- 区域与账户兜底 ---
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "${AWS_REGION}" ]]; then
  AWS_REGION="$(aws configure get region || true)"
fi
if [[ -z "${AWS_REGION}" ]]; then
  echo "[FATAL] AWS region is empty. Set AWS_REGION or AWS_DEFAULT_REGION in environment."
  exit 1
fi

# --- 服务名校验 ---
if [[ -z "${SERVICE_NAME:-}" ]]; then
  echo "[FATAL] SERVICE_NAME is empty."
  exit 1
fi

# --- Docker 可用性检查（privileged 必须开启） ---
if ! command -v docker >/dev/null 2>&1; then
  echo "[FATAL] docker is not available. Enable Privileged mode or install docker in the image."
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "[FATAL] docker daemon not running or insufficient privilege."
  exit 1
fi

# --- 计算镜像信息 ---
ECR_REPO_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${SERVICE_NAME}"
TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"   # 用 UTC 更可复现
IMAGE_TAG="${TIMESTAMP}.${COMMIT7:-latest}"
export ECR_REPO_URI IMAGE_TAG

echo "== Ensure ECR repo & login =="
aws ecr describe-repositories --repository-names "${SERVICE_NAME}" --region "$AWS_REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${SERVICE_NAME}" --region "$AWS_REGION" >/dev/null

aws ecr get-login-password --region "$AWS_REGION" \
| docker login --username AWS --password-stdin "${ECR_REPO_URI%%/*}"

echo "==> IMAGE_TAG=$IMAGE_TAG"
echo "==> ECR_REPO_URI=$ECR_REPO_URI"

echo "Prebuild OK (no extra git operations)."