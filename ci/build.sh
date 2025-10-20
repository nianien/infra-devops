#!/usr/bin/env bash
set -euo pipefail
# 加载上一阶段写入的变量（按构建ID隔离）
CI_ENV_FILE="/tmp/ci_env_${CODEBUILD_BUILD_ID:-default}"
[[ -f "$CI_ENV_FILE" ]] && source "$CI_ENV_FILE"

INFRA_ROOT="${CODEBUILD_SRC_DIR:-.}"
APP_ROOT="${CODEBUILD_SRC_DIR_AppOut:-$INFRA_ROOT}"

MODULE_PATH="${MODULE_PATH:-.}"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-Dockerfile}"
WORK_DIR="${APP_ROOT}/${MODULE_PATH}"
DF_ABS="${APP_ROOT}/${DOCKERFILE_PATH}"
[[ -f "$WORK_DIR/$DOCKERFILE_PATH" ]] && DF_ABS="$WORK_DIR/$DOCKERFILE_PATH"

echo "WORK_DIR=$WORK_DIR"; echo "DOCKERFILE=$DF_ABS"
[[ -d "$WORK_DIR" ]] || { echo "MODULE_PATH not found: $WORK_DIR"; exit 2; }
[[ -f "$DF_ABS"   ]] || { echo "Dockerfile not found: $DF_ABS"; exit 3; }

# 构建/打包（示例 Maven）
pushd "$APP_ROOT" >/dev/null
if [[ "$MODULE_PATH" == "." ]]; then
  mvn -B ${SKIP_TESTS:+-DskipTests} clean package
else
  mvn -B ${SKIP_TESTS:+-DskipTests} -pl .,"$MODULE_PATH" -am clean package
fi
popd >/dev/null

# Docker build & push（加入 --pull 以获取最新基础镜像；可按需移除）
IMAGE_TAG_URI="$ECR_REPO_URI:$IMAGE_TAG"
docker build --pull -f "$DF_ABS" -t "$IMAGE_TAG_URI" "$WORK_DIR"
docker push "$IMAGE_TAG_URI"

# 同步 latest（可选）
docker tag "$IMAGE_TAG_URI" "$ECR_REPO_URI:latest"
docker push "$ECR_REPO_URI:latest"

# 给 post_build 用
echo "IMAGE_TAG_URI=$IMAGE_TAG_URI" | tee -a "$CI_ENV_FILE"