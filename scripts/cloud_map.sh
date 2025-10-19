#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
. "$(dirname "$0")/env.sh"

append_json_array() {
  jq -c --argjson a "${1:-[]}" --argjson o "${2}" '$a + [$o]' <<< 'null'
}

SVC_ARNS_JSON=$(aws ecs list-services \
  --cluster "$CLUSTER" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE" \
  --query 'serviceArns' --output json)

ECS_SERVICES_JSON='[]'

for SVC_ARN in $(jq -r '.[]' <<<"$SVC_ARNS_JSON"); do
  SVC_NAME="${SVC_ARN##*/}"

  TASK_ARNS_JSON=$(aws ecs list-tasks \
    --cluster "$CLUSTER" \
    --service-name "$SVC_ARN" \
    --desired-status RUNNING \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query 'taskArns' --output json)

  if [[ "$(jq 'length' <<<"$TASK_ARNS_JSON")" -eq 0 ]]; then
    SVC_OBJ=$(jq -n --arg serviceArn "$SVC_ARN" --arg serviceName "$SVC_NAME" \
      '{serviceArn:$serviceArn, serviceName:$serviceName, tasks:[]}')
    ECS_SERVICES_JSON=$(append_json_array "$ECS_SERVICES_JSON" "$SVC_OBJ")
    continue
  fi

  TASKS_ARGS=$(jq -r '.[]' <<<"$TASK_ARNS_JSON" | tr '\n' ' ')
  DESCRIBE_JSON=$(aws ecs describe-tasks \
    --cluster "$CLUSTER" \
    --tasks $TASKS_ARGS \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --output json)

  TASKS_VIEW=$(jq -c '
    (.tasks // []) | map({
      taskArn: .taskArn,
      ip: (
        (
          (.containers // []) | .[0]? | .networkInterfaces // [] | .[0]? | .privateIpv4Address
        )
        // (
          (.attachments // [])
          | map(select(.type=="ElasticNetworkInterface"))
          | .[0]?
          | .details
          | map(select(.name=="privateIPv4Address"))
          | .[0]?
          | .value
        )
        // null
      )
    })
  ' <<<"$DESCRIBE_JSON")

  SVC_OBJ=$(jq -n \
    --arg serviceArn "$SVC_ARN" \
    --arg serviceName "$SVC_NAME" \
    --argjson tasks "$TASKS_VIEW" \
    '{serviceArn:$serviceArn, serviceName:$serviceName, tasks:$tasks}')

  ECS_SERVICES_JSON=$(append_json_array "$ECS_SERVICES_JSON" "$SVC_OBJ")
done

CLOUDMAP_JSON='null'
if [[ -n "${NAMESPACE_NAME:-}" ]]; then
  NS_ID=$(aws servicediscovery list-namespaces \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --query "Namespaces[?Name==\`$NAMESPACE_NAME\`].Id | [0]" --output text)

  if [[ "$NS_ID" != "None" && -n "$NS_ID" ]]; then
    CM_SERVS=$(aws servicediscovery list-services \
      --region "$AWS_REGION" --profile "$AWS_PROFILE" \
      --filters Name=NAMESPACE_ID,Values="$NS_ID",Condition=EQ \
      --query 'Services[].{Id:Id,Name:Name}' --output json)

    CM_SERVICES_JSON='[]'
    CM_COUNT=$(jq 'length' <<<"$CM_SERVS")

    if [[ "$CM_COUNT" -gt 0 ]]; then
      for i in $(seq 0 $((CM_COUNT-1))); do
        SID=$(jq -r ".[$i].Id" <<<"$CM_SERVS")
        SNAME=$(jq -r ".[$i].Name" <<<"$CM_SERVS")

        INST_JSON=$(aws servicediscovery list-instances \
          --service-id "$SID" \
          --region "$AWS_REGION" --profile "$AWS_PROFILE" \
          --output json)

        ONE=$(jq -n \
          --arg id "$SID" --arg name "$SNAME" --arg ns "$NAMESPACE_NAME" \
          --argjson inst "$INST_JSON" \
          '{
            serviceId:$id, name:$name, namespace:$ns,
            instances: (($inst.Instances // []) | map({
              id: .Id,
              ip: .Attributes.AWS_INSTANCE_IPV4,
              port: .Attributes.AWS_INSTANCE_PORT,
              lane: .Attributes.lane
            }))
          }')

        CM_SERVICES_JSON=$(append_json_array "$CM_SERVICES_JSON" "$ONE")
      done
    fi

    CLOUDMAP_JSON=$(jq -n --arg ns "$NAMESPACE_NAME" --argjson services "$CM_SERVICES_JSON" \
      '{namespace:$ns, services:$services}')
  fi
fi

jq -n \
  --arg cluster "$CLUSTER" \
  --arg region "$AWS_REGION" \
  --argjson ecs "$ECS_SERVICES_JSON" \
  --argjson cm "$CLOUDMAP_JSON" \
  '{ ecs: { cluster:$cluster, region:$region, services:$ecs }, cloudMap: $cm }'