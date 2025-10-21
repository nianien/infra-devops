#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# fetch-eni-endpoint.sh
# - 取 ECS Service 的 RUNNING 任务 -> ENI 公网 IP
# - 从 TaskDefinition 自动解析端口（优先 hostPort，兜底 containerPort）
# - 若显式传入 PORT 且与 TD 不一致，改用 TD 端口（避免连接被拒）
# ===========================================

# 基础入参（可在 env.sh 中覆写）
. "$(dirname "$0")/env.sh"

SERVICE="$1"
PORT="${PORT:-}"  # 不给默认值；自动从 TD 读取

AWS_REGION="${AWS_REGION:?missing AWS_REGION}"
AWS_PROFILE="${AWS_PROFILE:?missing AWS_PROFILE}"
CLUSTER="${CLUSTER:?missing CLUSTER}"

echo ">>> 查 RUNNING 任务 ARN ..."
TASK_ARN=$(aws ecs list-tasks \
  --cluster "$CLUSTER" \
  --service-name "$SERVICE" \
  --desired-status RUNNING \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query 'taskArns[0]' --output text)

if [[ -z "$TASK_ARN" || "$TASK_ARN" == "None" ]]; then
  echo "❌ 没有运行中的任务（$CLUSTER / $SERVICE）"
  exit 1
fi
echo "TASK_ARN=$TASK_ARN"

echo ">>> 读取该任务的 TaskDefinition ARN ..."
TD_ARN=$(aws ecs describe-tasks \
  --cluster "$CLUSTER" \
  --tasks "$TASK_ARN" \
  --query 'tasks[0].taskDefinitionArn' \
  --output text --region "$AWS_REGION" --profile "$AWS_PROFILE")

if [[ -z "$TD_ARN" || "$TD_ARN" == "None" ]]; then
  echo "❌ 取不到 TaskDefinition ARN"
  exit 1
fi
echo "TD_ARN=$TD_ARN"

echo ">>> 解析 TaskDefinition 端口映射（优先 hostPort） ..."
TD_HOST_PORT=$(aws ecs describe-task-definition \
  --task-definition "$TD_ARN" \
  --query 'taskDefinition.containerDefinitions[0].portMappings[?hostPort!=null][0].hostPort' \
  --output text --region "$AWS_REGION" --profile "$AWS_PROFILE")
if [[ -z "$TD_HOST_PORT" || "$TD_HOST_PORT" == "None" ]]; then
  TD_HOST_PORT=$(aws ecs describe-task-definition \
    --task-definition "$TD_ARN" \
    --query 'taskDefinition.containerDefinitions[0].portMappings[0].containerPort' \
    --output text --region "$AWS_REGION" --profile "$AWS_PROFILE")
fi
if [[ -z "$TD_HOST_PORT" || "$TD_HOST_PORT" == "None" ]]; then
  echo "❌ 该 TaskDefinition 未配置端口映射（containerDefinitions[0].portMappings 为空）"
  exit 1
fi

# 若未显式指定 PORT，则使用 TD 的端口；如显式指定但不同，也以 TD 为准（避免 connection refused）
if [[ -z "${PORT:-}" || "$PORT" == "None" ]]; then
  PORT="$TD_HOST_PORT"
elif [[ "$PORT" != "$TD_HOST_PORT" ]]; then
  echo "⚠️ 你指定的 PORT=$PORT 与 TaskDefinition 端口=$TD_HOST_PORT 不一致，已改用 $TD_HOST_PORT"
  PORT="$TD_HOST_PORT"
fi
echo "PORT=$PORT"

echo ">>> 从 attachments 拿 ENI ..."
ENI_ID=$(aws ecs describe-tasks \
  --cluster "$CLUSTER" \
  --tasks "$TASK_ARN" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query "tasks[0].attachments[?type=='ElasticNetworkInterface'] | [0].details[?name=='networkInterfaceId'] | [0].value" \
  --output text)

# 兜底：从 containers[].networkInterfaces
if [[ -z "$ENI_ID" || "$ENI_ID" == "None" ]]; then
  ENI_ID=$(aws ecs describe-tasks \
    --cluster "$CLUSTER" \
    --tasks "$TASK_ARN" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "tasks[0].containers[0].networkInterfaces[0].networkInterfaceId" \
    --output text)
fi

if [[ -z "$ENI_ID" || "$ENI_ID" == "None" ]]; then
  echo "❌ 取不到 ENI（networkInterfaceId）"
  exit 2
fi
echo "ENI_ID=$ENI_ID"

echo ">>> 查 ENI 的 公网IP/DNS/安全组/私网IP ..."
read -r PUBLIC_IP PUBLIC_DNS SG_ID PRIVATE_IP <<<"$(
  aws ec2 describe-network-interfaces \
    --network-interface-ids "$ENI_ID" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "[
      NetworkInterfaces[0].Association.PublicIp,
      NetworkInterfaces[0].Association.PublicDnsName,
      NetworkInterfaces[0].Groups[0].GroupId,
      NetworkInterfaces[0].PrivateIpAddress
    ]" --output text
)"

echo "PUBLIC_IP=$PUBLIC_IP"
echo "PUBLIC_DNS=$PUBLIC_DNS"
echo "SG_ID=$SG_ID"
echo "PRIVATE_IP=$PRIVATE_IP"

if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "None" ]]; then
  echo "❌ 该任务无公网 IP（可能未开启 assignPublicIp 或子网非公有）。"
  exit 3
fi
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  echo "❌ 取不到安全组 ID"
  exit 4
fi

# 来源 IP（允许外部预先 export MY_IP 覆盖）
echo ">>> 自动探测你的公网 IP ..."
MY_IP="${MY_IP:-}"
if [[ -z "$MY_IP" ]]; then
  MY_IP=$(curl -s https://checkip.amazonaws.com || true)
  MY_IP=${MY_IP//$'\r'/}
  MY_IP=${MY_IP//$'\n'/}
fi
if [[ -z "$MY_IP" ]]; then
  echo "❌ 无法确定你的公网 IP；可先 export MY_IP=1.2.3.4 再跑"
  exit 5
fi
CIDR="$MY_IP/32"
echo "MY_IP=$MY_IP  => CIDR=$CIDR"

echo ">>> 检查是否已存在放行规则 ($CIDR -> $PORT/tcp) ..."
RULE_EXISTS=$(aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --query "length(
    SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`$PORT\` && ToPort==\`$PORT\`]
    | [].IpRanges[] | [?CidrIp=='$CIDR']
  )" \
  --output text 2>/dev/null || echo 0)

if [[ "$RULE_EXISTS" =~ ^[0-9]+$ ]] && [[ "$RULE_EXISTS" -gt 0 ]]; then
  echo "=== 已存在放行规则，跳过添加。"
else
  echo ">>> 添加临时放行 $CIDR 到 $PORT/tcp ..."
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,IpRanges=[{CidrIp=$CIDR,Description='temp open by script'}]" \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    >/dev/null 2>&1 || true
fi

echo
echo "URL:  http://$PUBLIC_IP:$PORT/   （或 http://$PUBLIC_DNS:$PORT/ ）"