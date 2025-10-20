#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER="" # 防止 CLI 卡分页

# AWS basics
export AWS_PROFILE="${AWS_PROFILE:-nianien}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

# ECS basics
export CLUSTER="${CLUSTER:-demo-cluster}"

# Optional namespace for Cloud Map inspection
export NAMESPACE_NAME="${NAMESPACE_NAME:-test.local}"
