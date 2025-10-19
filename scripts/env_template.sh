#!/usr/bin/env bash
set -euo pipefail

# AWS basics
export AWS_PROFILE="${AWS_PROFILE:-}"
export AWS_REGION="${AWS_REGION:-}"

# ECS basics
export CLUSTER="${CLUSTER:-}"

# Optional namespace for Cloud Map inspection
export NAMESPACE_NAME="${NAMESPACE_NAME:-}"