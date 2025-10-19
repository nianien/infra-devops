# Pipeline 部署指南

## 架构概述

为了避免共享栈并发更新冲突，我们采用了**双 Pipeline 架构**：

1. **Infrastructure Pipeline** (`pipeline-infra.yaml`) - 管理共享基础设施
2. **Service Pipeline** (`pipeline-service.yaml`) - 管理业务服务部署

## 部署顺序

### 1. 部署 Infrastructure Pipeline（一次性）

```bash
# 部署基础设施 Pipeline
aws cloudformation deploy \
  --template-file infra/pipeline-infra.yaml \
  --stack-name infra-pipeline-dev \
  --parameter-overrides \
    PipelineName=infra-pipeline-dev \
    Env=dev \
    CloudFormationDeployRoleArn=arn:aws:iam::ACCOUNT:role/CloudFormationDeployRole \
    CodePipelineRoleArn=arn:aws:iam::ACCOUNT:role/CodePipelineRole \
  --capabilities CAPABILITY_IAM
```

### 2. 手动触发 Infrastructure Pipeline

在 AWS Console 中手动触发 `infra-pipeline-dev`，它会按顺序部署：
- `network-stack` (VPC + Subnets)
- `sd-namespace-shared` (Cloud Map Namespace)
- `sd-service-shared-dev` (Cloud Map Service)
- `log-shared-dev` (CloudWatch Log Group)
- `alb-shared-dev` (Application Load Balancer)

### 3. 部署 Service Pipeline（每个服务一个）

```bash
# 部署业务服务 Pipeline
aws cloudformation deploy \
  --template-file infra/pipeline-service.yaml \
  --stack-name user-service-pipeline-dev \
  --parameter-overrides \
    PipelineName=user-service-pipeline-dev \
    ServiceName=user-service \
    RepoName=skyfalling/user-service \
    Env=dev \
    CloudFormationDeployRoleArn=arn:aws:iam::ACCOUNT:role/CloudFormationDeployRole \
    CodePipelineRoleArn=arn:aws:iam::ACCOUNT:role/CodePipelineRole \
    CodeBuildRoleArn=arn:aws:iam::ACCOUNT:role/CodeBuildRole \
  --capabilities CAPABILITY_IAM
```

## 关键修复

### 1. ✅ Source 阶段分支引用修复
```yaml
# 修复前
BranchName: !Ref BranchName  # ❌ BranchName 参数不存在

# 修复后  
BranchName: "#{variables.BRANCH}"  # ✅ 使用 Pipeline 变量
```

### 2. ✅ ALB 栈模板路径修复
```yaml
# 修复前
TemplatePath: 'SourceOut::ci/network-stack.yaml'  # ❌ 错误模板

# 修复后
TemplatePath: 'SourceOut::ci/alb-stack.yaml'  # ✅ 正确模板
```

### 3. ✅ 共享栈并发问题解决
- **问题**: 多个业务 Pipeline 同时更新共享栈导致 CFN 栈锁冲突
- **解决**: 将共享栈迁出到独立的 Infrastructure Pipeline
- **结果**: Service Pipeline 只部署应用栈，完全避免并发冲突

## 栈命名规范

### Infrastructure Stacks
- `network-stack` - VPC + Subnets
- `sd-namespace-shared` - Cloud Map Namespace  
- `sd-service-shared-{Env}` - Cloud Map Service
- `log-shared-{Env}` - CloudWatch Log Group
- `alb-shared-{Env}` - Application Load Balancer

### Service Stacks
- `app-{ServiceName}-{Env}-{Lane}` - ECS Service + Task Definition

## 并发部署能力

✅ **支持多服务并发部署**
- 每个服务有独立的 Service Pipeline
- 共享基础设施由 Infrastructure Pipeline 统一管理
- 无栈并发更新冲突

✅ **支持多环境并发部署**  
- 每个环境有独立的 Infrastructure Pipeline
- 环境间完全隔离

## 注意事项

1. **Infrastructure Pipeline 需要先部署**，确保共享栈存在
2. **Service Pipeline 依赖共享栈的 Export**，确保 ImportValue 正确
3. **IAM 角色权限**需要覆盖所有栈的部署权限
4. **Artifact Bucket** 需要在同一 Region
