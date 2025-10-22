#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# AWS 认证配置
# =========================================================
export AWS_PAGER="" # 防止 CLI 卡分页
export AWS_PROFILE="${AWS_PROFILE:-nianien}"
export AWS_REGION="${AWS_REGION:-ap-southeast-2}"
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-297997107448}"

# ECS basics
export CLUSTER="${CLUSTER:-dev-cluster}"

# Cloud Map
export NAMESPACE_NAME="${NAMESPACE_NAME:-dev.local}"