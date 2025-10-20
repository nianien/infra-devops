#!/usr/bin/env bash
# ===========================================
# pipeline.sh (refactored with functions + robust errors)
# - 参数解析 / 校验 / 模板校验 / 日志组 / 栈处理 / Cloud Map / 部署
# - 统一错误处理：任何失败都会打印提示与出错位置，然后退出
# ===========================================
. "$(dirname "$0")/env.sh"  # 加载你的环境变量

# -------- 错误处理 --------
on_err() {
  local ec=$?
  # 只提示退出码与失败命令，不打印行号
  local where="${FUNCNAME[1]:-main}"
  echo "❌ ERROR (exit=$ec) in ${where}: ${BASH_COMMAND}" >&2
  exit "$ec"
}
on_interrupt() { echo "❌ 中断，已退出。" >&2; exit 130; }
trap on_err ERR
trap on_interrupt SIGINT SIGTERM

log() { echo "==> $*"; }
ok()  { echo "✅ $*"; }
die() { local msg="$1"; local code="${2:-1}"; echo "❌ $msg" >&2; exit "$code"; }

# -------- 可覆盖变量 --------
AUTO_DELETE="${AUTO_DELETE:-1}"
PIPELINE_TEMPLATE="${PIPELINE_TEMPLATE:-$(dirname "$0")/pipeline.yaml}"
[[ "${DEBUG:-0}" == "1" ]] && set -x

# -------- 运行时变量 --------
REPO_NAME=""
SERVICE_NAME=""
PIPELINE_NAME=""
BRANCH_NAME="master"
MODULE_PATH="."
NAMESPACE_NAME=""      # 命名空间名称（如 test.local）
NAMESPACE_ID=""
STACK_NAME=""
ECS_LOG_GROUP_NAME=""
LG_RETENTION_DAYS=30
SD_REGISTRY_ID=""
APP_ENV=""

# =========================
# 参数解析
# =========================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|--repo-name) REPO_NAME="$2"; shift 2 ;;
      --service)          SERVICE_NAME="$2"; shift 2 ;;
      --pipeline)         PIPELINE_NAME="$2"; shift 2 ;;
      --branch)           BRANCH_NAME="$2"; shift 2 ;;
      --module)           MODULE_PATH="$2"; shift 2 ;;
      --ns|--namespace)   NAMESPACE_NAME="$2"; shift 2 ;;
      --env)              APP_ENV="$2"; shift 2 ;;
      -h|--help)
        cat <<EOF
Usage: $0 --repo <org/repo> --service <name> --namespace <name> --env <name>
       [--pipeline <name>] [--branch <name>] [--module <path>]
Example:
  $0 --repo org/repo --service demo-user-rpc --namespace test.local
EOF
        exit 0 ;;
      *) log "忽略未知参数: $1"; shift ;;
    esac
  done
}

# =========================
# 基础校验与默认值
# =========================
validate_required() {
  if [[ -z "$REPO_NAME" ]]; then die "缺少 --repo"; fi
  if [[ -z "$SERVICE_NAME" ]]; then die "缺少 --service"; fi
  if [[ -z "$NAMESPACE_NAME" ]]; then die "缺少 --namespace（例如 test.local）"; fi
  if [[ -z "$APP_ENV" ]]; then die "缺少 --env"; fi

  : "${BRANCH_NAME:=master}"
  : "${MODULE_PATH:=.}"

  if [[ -z "$PIPELINE_NAME" ]]; then PIPELINE_NAME="${SERVICE_NAME}-${APP_ENV}"; fi
  STACK_NAME="${PIPELINE_NAME}-pipeline"
  ECS_LOG_GROUP_NAME="/ecs/${SERVICE_NAME}"
}

# =========================
# 环境变量校验（允许你在 env.sh 里给默认）
# =========================
validate_env() {
  if [[ -z "${AWS_REGION:-}"  ]]; then die "缺少环境变量 AWS_REGION";  fi
  if [[ -z "${AWS_PROFILE:-}" ]]; then die "缺少环境变量 AWS_PROFILE"; fi
}

# =========================
# 模板校验
# =========================
validate_template() {
  log "Validating template: $PIPELINE_TEMPLATE"
  aws cloudformation validate-template \
    --template-body "file://$PIPELINE_TEMPLATE" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" >/dev/null
  ok "Template valid"
}

# =========================
# 日志组保障
# =========================
ensure_log_group() {
  local name="$1" retention="${2:-30}"
  local exists
  exists="$(aws logs describe-log-groups \
      --log-group-name-prefix "$name" \
      --query "logGroups[?logGroupName=='$name']|length(@)" \
      --output text \
      --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || echo 0)"
  if [[ "$exists" == "0" ]]; then
    log "Creating log group: $name (retention=$retention)"
    aws logs create-log-group --log-group-name "$name" \
      --region "$AWS_REGION" --profile "$AWS_PROFILE" || true
    aws logs put-retention-policy \
      --log-group-name "$name" \
      --retention-in-days "$retention" \
      --region "$AWS_REGION" --profile "$AWS_PROFILE" || true
  else
    log "Log group exists: $name"
  fi
}

# =========================
# Cloud Map：名称→ID，查/建 Service，取 ARN
# =========================
ensure_cloud_map_service() {
  log "Resolving NamespaceId for '${NAMESPACE_NAME}'..."
  local ns_id
  ns_id="$(aws servicediscovery list-namespaces \
      --query "Namespaces[?Name=='${NAMESPACE_NAME}'].Id | [0]" \
      --output text \
      --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || true)"
  if [[ -z "$ns_id" || "$ns_id" == "None" || "$ns_id" == "null" ]]; then
    die "无法找到命名空间 '${NAMESPACE_NAME}'" 2
  fi
  NAMESPACE_ID="$ns_id"
  log "Namespace resolved: id=$NAMESPACE_ID"

  log "Searching Cloud Map Service ID: ${SERVICE_NAME}"
  local next_token="" svc_id=""
  while :; do
    svc_id="$(aws servicediscovery list-services \
        --filters Name=NAMESPACE_ID,Values="$NAMESPACE_ID",Condition=EQ \
        ${next_token:+--next-token "$next_token"} \
        --max-results 100 \
        --query "Services[?Name=='${SERVICE_NAME}'].Id | [0]" \
        --output text \
        --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || echo "")"
    if [[ -n "$svc_id" && "$svc_id" != "None" && "$svc_id" != "null" ]]; then
      SD_REGISTRY_ID="$svc_id"
      log "Found existing Cloud Map Service: id=$SD_REGISTRY_ID"
      break
    fi
    next_token="$(aws servicediscovery list-services \
        --filters Name=NAMESPACE_ID,Values="$NAMESPACE_ID",Condition=EQ \
        --max-results 100 \
        --query "NextToken" --output text \
        --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || echo "")"
    if [[ -z "$next_token" || "$next_token" == "None" ]]; then break; fi
  done

  if [[ -z "$SD_REGISTRY_ID" ]]; then
    log "Not found, creating Cloud Map Service '$SERVICE_NAME' (SRV, MULTIVALUE, FailureThreshold=1)..."
    SD_REGISTRY_ID="$(aws servicediscovery create-service \
        --name "$SERVICE_NAME" \
        --namespace-id "$NAMESPACE_ID" \
        --dns-config 'RoutingPolicy=MULTIVALUE,DnsRecords=[{Type=SRV,TTL=30}]' \
        --health-check-custom-config 'FailureThreshold=1' \
        --query 'Service.Id' --output text \
        --region "$AWS_REGION" --profile "$AWS_PROFILE")"
    log "Created Cloud Map Service: id=$SD_REGISTRY_ID"
  fi

  if [[ -z "$SD_REGISTRY_ID" || "$SD_REGISTRY_ID" == "None" || "$SD_REGISTRY_ID" == "null" ]]; then
    die "无法解析/创建 SdRegistryId（namespace='${NAMESPACE_NAME}', id='${NAMESPACE_ID}', service='${SERVICE_NAME}'）" 3
  fi
}

# =========================
# 清理旧栈
# =========================
prepare_stack_state() {
  local status
  status="$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" \
      --query 'Stacks[0].StackStatus' --output text \
      --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null || echo NOT_FOUND)"
  echo "STACK_STATUS=$status"
  if [[ "$status" =~ (COMPLETE|FAILED)$ ]]; then
    if [[ "$AUTO_DELETE" == "1" ]]; then
      log "Deleting old stack: $STACK_NAME ($status)"
      aws cloudformation delete-stack --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" --profile "$AWS_PROFILE"
      aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" --profile "$AWS_PROFILE"
    else
      die "Stack in $status；AUTO_DELETE=0，已终止以保护资源" 2
    fi
  fi
}

# =========================
# 组装 CFN 参数
# =========================
assemble_params() {
  PARAMS=(
    "PipelineName=${PIPELINE_NAME}"
    "ServiceName=${SERVICE_NAME}"
    "RepoName=${REPO_NAME}"
    "BranchName=${BRANCH_NAME}"
    "ModulePath=${MODULE_PATH}"
    "SdRegistryId=${SD_REGISTRY_ID}"
    "AppEnv=${APP_ENV}"
  )
}

# =========================
# 部署
# =========================
deploy_stack() {
  set -x
  aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$PIPELINE_TEMPLATE" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --parameter-overrides "${PARAMS[@]}"
  set +x
  ok "Pipeline 部署完成：$PIPELINE_NAME"
  echo "👉 启动示例："
  echo "aws codepipeline start-pipeline-execution --name $PIPELINE_NAME --region $AWS_REGION --profile $AWS_PROFILE \\"
  echo "  --variables name=LANE,value=default name=DESIRED_COUNT,value=1"
}

# =========================
# 打印上下文
# =========================
print_context() {
  echo "============context:begin==========="
  echo "profile=${AWS_PROFILE:-} region=${AWS_REGION:-}"
  echo "service=$SERVICE_NAME env=$APP_ENV"
  echo "repo=$REPO_NAME branch=$BRANCH_NAME module=$MODULE_PATH"
  echo "namespace=$NAMESPACE_NAME id=$NAMESPACE_ID"
  echo "pipeline=$PIPELINE_NAME stack=$STACK_NAME"
  echo "ecs_log_group=$ECS_LOG_GROUP_NAME retention=$LG_RETENTION_DAYS"
  echo "============context:end==========="
}

# =========================
# 主流程
# =========================
main() {
  parse_args "$@"
  validate_required
  validate_env
  ensure_cloud_map_service
  print_context
  validate_template
  ensure_log_group "$ECS_LOG_GROUP_NAME" "$LG_RETENTION_DAYS"
  prepare_stack_state
  assemble_params
  deploy_stack
}

main "$@"