#!/usr/bin/env bash
set -euo pipefail

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

# 断言 JAR 存在并打印详细信息
echo "== Checking for JAR files in $WORK_DIR/target =="
ls -la "$WORK_DIR/target/" 2>/dev/null || echo "target directory not found"

JAR_FILE=$(find "$WORK_DIR/target" -maxdepth 1 -type f -name "*.jar" \
  ! -name "*-sources.jar" ! -name "*-javadoc.jar" ! -name "*-tests.jar" \
  | head -n1)

if [[ -z "$JAR_FILE" ]]; then
  echo "[FATAL] No runnable jar found under $WORK_DIR/target"
  exit 4
fi

echo "Found JAR file: $JAR_FILE"

# 提前导出 IMAGE_TAG_URI，给 post_build 用
export IMAGE_TAG_URI="$ECR_REPO_URI:$IMAGE_TAG"

# Docker build & push - 使用仓库根作为上下文，JAR 路径作为 build-arg
DF="${DOCKERFILE_PATH:-Dockerfile}"       # 例如 ci/Dockerfile（位于仓库内）
JAR_ARG="$MODULE_PATH/target/*.jar"       # 关键：相对"仓库根"的路径

echo "Docker build context: $APP_ROOT"
echo "Dockerfile: $DF"
echo "JAR_ARG: $JAR_ARG"

docker build \
  -f "$DF" \
  --build-arg JAR_FILE="$JAR_ARG" \
  -t "$IMAGE_TAG_URI" \
  "$APP_ROOT"

docker push "$IMAGE_TAG_URI"

# 同步 latest（可选）
docker tag "$IMAGE_TAG_URI" "$ECR_REPO_URI:latest"
docker push "$ECR_REPO_URI:latest"