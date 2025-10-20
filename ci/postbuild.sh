#!/usr/bin/env bash
set -euo pipefail
INFRA_ROOT="${CODEBUILD_SRC_DIR:-.}"

# 产物写到主输入根目录，便于 artifacts.files 收集
cat > "${INFRA_ROOT}/cfn-params.json" <<EOF
{
  "Parameters": {
    "ImageUri": "$IMAGE_TAG_URI"
  }
}
EOF
echo "Wrote ${INFRA_ROOT}/cfn-params.json"