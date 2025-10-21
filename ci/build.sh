#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Common Functions & Variables for CI/CD Scripts
# =========================================================
# 通用函数库，提供日志输出、错误处理、AWS/ECR 登录等通用逻辑
# 使用方法：. "$(dirname "$0")/build.sh"

# ---------- 错误处理 ----------
trap 'echo "[ERR] line $LINENO: $BASH_COMMAND" >&2' ERR

# ---------- 彩色日志函数 ----------
info() { echo -e "\033[36m==>\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
fatal() {
  echo -e "\033[31m[FATAL]\033[0m $*" >&2
  exit 1
}
ok() { echo -e "\033[32m✅\033[0m $*"; }

# ---------- 路径设置 ----------
ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ROOT="${CODEBUILD_SRC_DIR_AppOut:-$ROOT}" # 应用仓库根
INFRA_ROOT="${CODEBUILD_SRC_DIR:-$ROOT}"      # 主输入根

# ---------- AWS 环境初始化 ----------
aws_init() {
  info "Initializing AWS environment..."

  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region || true)}}"
  [[ -n "$AWS_REGION" ]] || fatal "AWS region is empty"

  export ACCOUNT_ID AWS_REGION
  info "AWS Account: $ACCOUNT_ID, Region: $AWS_REGION"
}

# ---------- ECR 登录函数 ----------
ecr_login() {
  local repo_uri="$1"
  local host="${repo_uri%%/*}"

  info "Logging in to ECR: ${host}"
  aws ecr get-login-password --region "$AWS_REGION" |
    docker login --username AWS --password-stdin "$host"

  ok "ECR login successful"
}

# ---------- 通用构建时间戳 ----------
timestamp() {
  date -u +%Y%m%d%H%M%S
}

# ---------- 环境变量验证 ----------
validate_env() {
  local required_vars=("$@")

  for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      fatal "Required environment variable '$var' is not set"
    fi
  done
}

# ---------- 文件存在性检查 ----------
check_file() {
  local file="$1"
  local description="${2:-$file}"

  if [[ ! -f "$file" ]]; then
    fatal "$description not found: $file"
  fi
  info "Found $description: $file"
}

# ---------- 目录存在性检查 ----------
check_dir() {
  local dir="$1"
  local description="${2:-$dir}"

  if [[ ! -d "$dir" ]]; then
    fatal "$description not found: $dir"
  fi
  info "Found $description: $dir"
}

# ---------- 构建阶段函数 ----------
prebuild() {
  info "== Prebuild Phase =="

  # 必需环境变量检查
  : "${SERVICE_NAME:?SERVICE_NAME required}"
  : "${APP_ENV:?APP_ENV required}"

  # 可选环境变量设置默认值
  : "${MODULE_PATH:=.}"
  : "${DOCKERFILE_PATH:=ci/Dockerfile}"
  : "${SKIP_TESTS:=1}"

  # 初始化 AWS 环境
  aws_init

  # 目录存在性检查
  check_dir "$APP_ROOT" "APP_ROOT"
  check_dir "$INFRA_ROOT" "INFRA_ROOT"

  ECR_REPO_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${SERVICE_NAME}"
  TIMESTAMP="$(date +%Y%m%d%H%M%S)"
  IMAGE_TAG="${TIMESTAMP}.${COMMIT7:-latest}"
  IMAGE_TAG_URI="$ECR_REPO_URI:$IMAGE_TAG"
  # 导出变量
  export ECR_REPO_URI IMAGE_TAG_URI

  # ECR 仓库存在性检查，不存在则创建
  info "Checking ECR repository: $SERVICE_NAME"
  if ! aws ecr describe-repositories --repository-names "$SERVICE_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    info "Creating ECR repository: $SERVICE_NAME"
    aws ecr create-repository --repository-name "$SERVICE_NAME" --region "$AWS_REGION" >/dev/null
  fi

  # ECR 登录
  ecr_login "$ECR_REPO_URI"

  info "Prebuild completed successfully"
  info "Service: $SERVICE_NAME"
  info "Environment: $APP_ENV"
  info "Lane: ${LANE:-default}"
  info "ECR Repository: $ECR_REPO_URI"

}

build() {
  info "== Build Phase =="

  # 验证必需的环境变量
  validate_env "IMAGE_TAG_URI"

  # Maven 构建
  info "Building with Maven..."
  if [[ "$MODULE_PATH" == "." ]]; then
    mvn -B $([[ "$SKIP_TESTS" == "1" ]] && echo -DskipTests) -f "$APP_ROOT/pom.xml" clean package
  else
    mvn -B $([[ "$SKIP_TESTS" == "1" ]] && echo -DskipTests) -f "$APP_ROOT/pom.xml" -pl .,"$MODULE_PATH" -am clean package
  fi

  # 查找可运行的 JAR 文件
  WORK_DIR="$APP_ROOT/$MODULE_PATH"
  JAR_FILE="$(find "$WORK_DIR/target" -maxdepth 1 -type f -name '*.jar' \
    ! -name '*-sources.jar' ! -name '*-javadoc.jar' ! -name '*-tests.jar' \
    -printf '%f\n' 2>/dev/null | sort | tail -n1)"

  if [[ -z "$JAR_FILE" ]]; then
    fatal "No runnable JAR found in $WORK_DIR/target"
  fi

  REL_JAR="${MODULE_PATH}/target/${JAR_FILE}"
  info "Found JAR file: $REL_JAR"

  # Docker 构建
  DF_ABS="$APP_ROOT/$DOCKERFILE_PATH"
  check_file "$DF_ABS" "Dockerfile"

  COMMIT7="$(
    git -C "${APP_OUT_DIR:-$APP_ROOT}" rev-parse --short=7 HEAD 2>/dev/null ||
      echo "${CODEBUILD_RESOLVED_SOURCE_VERSION:-latest}" | cut -c1-7
  )"

  info "Building Docker image: $IMAGE_TAG_URI"
  docker build \
    -f "$DF_ABS" \
    --build-arg "JAR_FILE=${REL_JAR}" \
    -t "$IMAGE_TAG_URI" \
    "$APP_ROOT"

  # 推送镜像到 ECR
  info "Pushing Docker image to ECR"
  docker push "$IMAGE_TAG_URI"

  # 同步 latest 标签
  echo "== Syncing tag :latest =="
  docker tag "$IMAGE_TAG_URI" "${ECR_REPO_URI}:latest"
  docker push "${ECR_REPO_URI}:latest"

  ok "Build phase completed successfully"
  info "Image pushed to ECR: $IMAGE_TAG_URI"
}

postbuild() {
  info "== Postbuild Phase =="

  # 验证必需的环境变量
  validate_env "SERVICE_NAME" "APP_ENV" "IMAGE_TAG_URI"

  # 生成 CloudFormation 参数文件
  info "Generating CloudFormation parameters file"
  cat >cfn-params.json <<EOF
{
  "ImageUri": "${IMAGE_TAG_URI}"
}
EOF

  # 验证 JSON 格式
  if command -v jq >/dev/null 2>&1; then
    info "Generated CloudFormation parameters:"
    jq . cfn-params.json
  else
    info "Generated CloudFormation parameters:"
    cat cfn-params.json
  fi

  ok "Postbuild phase completed successfully"
  info "CloudFormation parameters file ready: cfn-params.json"
}
