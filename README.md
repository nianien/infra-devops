# 多泳道 ECS 持续交付架构

[![AWS](https://img.shields.io/badge/AWS-CloudFormation-orange)](https://aws.amazon.com/cloudformation/)
[![Pipeline](https://img.shields.io/badge/CI/CD-CodePipeline-blue)](https://aws.amazon.com/codepipeline/)
[![ECS](https://img.shields.io/badge/Container-ECS-green)](https://aws.amazon.com/ecs/)

基于 AWS CodePipeline 和 CloudFormation 构建的支持多泳道并行部署的 ECS 持续交付系统。通过双仓架构设计、分层 Pipeline 架构和共享基础设施层设计，实现了 DevOps 模板集中治理、高并发、零冲突的微服务部署能力。

## 🚀 核心特性

- **双仓架构设计**：Infra 仓集中管理 DevOps 模板，App 仓专注业务代码，实现模板统一治理
- **分层 Pipeline 架构**：环境级、服务级、应用级三层 Pipeline 分离，职责清晰
- **统一 BuildSpec**：所有服务共享同一 buildspec.yaml，通过双源输入机制访问业务代码
- **并行无锁部署**：不同层级 Pipeline 独立运行，支持多泳道并行执行
- **动态泳道管理**：运行时通过变量指定泳道和分支，无需预定义泳道配置
- **基础设施共享**：VPC、Cloud Map Namespace 等环境级资源与业务层解耦
- **智能流量路由**：基于 W3C Trace Context 标准的 `tracestate` 头部进行精确流量分发
- **闭环参数传递**：CodeBuild 内完成构建和部署，确保参数传递的一致性和可靠性

## 📁 项目结构

```
infra-devops/
├── ci/                          # CI/CD 模板和配置
│   ├── app/                     # 应用级 Pipeline 配置
│   │   ├── parameters/          # 应用参数配置
│   │   ├── pipeline.yaml        # 应用 Pipeline 模板
│   │   └── templates/           # 应用部署模板
│   │       └── service-stack.yaml
│   ├── boot/                    # 服务级引导 Pipeline 配置
│   │   ├── parameters/          # 引导参数配置
│   │   ├── pipeline.yaml        # 引导 Pipeline 模板
│   │   └── templates/           # 引导部署模板
│   │       └── boot-stack.yaml
│   ├── infra/                   # 环境级基础设施 Pipeline 配置
│   │   ├── parameters/          # 基础设施参数配置
│   │   ├── pipeline.yaml        # 基础设施 Pipeline 模板
│   │   └── templates/           # 基础设施部署模板
│   │       └── infra-stack.yaml
│   ├── buildspec.yaml           # 统一构建规范
│   ├── Dockerfile               # 构建环境镜像
│   └── pipeline-deploy.sh       # 统一部署脚本
├── docs/                        # 项目文档
│   ├── readme.md                # 详细架构设计文档
│   └── pipeline-deployment-guide.md
├── pipeline/                    # Pipeline 管理脚本
│   ├── pipeline.sh              # 主 Pipeline 脚本
│   ├── pipeline-boot.sh         # 引导 Pipeline 脚本
│   ├── pipeline-infra.sh        # 基础设施 Pipeline 脚本
│   └── demo.sh                  # 演示脚本
└── scripts/                     # 工具脚本
    ├── cloud_map.sh             # Cloud Map 管理
    ├── ecr_build.sh             # ECR 构建脚本
    ├── ecs_services.sh          # ECS 服务管理
    ├── env.sh                   # 环境配置
    └── web_access.sh            # Web 访问管理
```

## 🏗️ 架构设计

### 双仓架构 + 统一 BuildSpec 技术方案

#### 仓库职责划分

| 仓库 | 内容 | 示例路径 |
|------|------|----------|
| Infra Repo | 统一 DevOps 模板（buildspec、pipeline、CFN 模板、通用脚本） | `ci/buildspec.yaml`、`ci/service-stack.yaml` |
| App Repo | 各服务代码（源代码、Dockerfile、配置文件等） | `src/`, `Dockerfile` |

#### CodePipeline 双源输入设计

```yaml
Stages:
  - Name: Source
    Actions:
      - Name: AppSource
        Provider: CodeStarSourceConnection
        OutputArtifacts: [ AppOut ]
      - Name: InfraSource
        Provider: CodeStarSourceConnection
        OutputArtifacts: [ InfraOut ]
```

- **AppOut**：业务代码
- **InfraOut**：CI 模板与 buildspec

#### Build 阶段关键配置

```yaml
- Name: Build
  Actions:
    - Name: CodeBuild
      InputArtifacts:
        - Name: InfraOut   # 主输入，buildspec来源
        - Name: AppOut     # 副输入，业务代码
      Configuration:
        ProjectName: !Ref CodeBuildProject
```

### 三层 Pipeline 架构

系统采用三层 Pipeline 架构，实现职责清晰分离和并发无锁部署：

#### 1. Infra Pipeline（环境级共享）
- **模板文件**：`ci/infra/pipeline.yaml`
- **命名规范**：`infra-{env}`
- **部署频率**：环境初始化时运行一次，后续很少变更
- **部署资源**：
  - VPC 网络栈（`infra-network`）
  - Cloud Map Namespace（`infra-namespace`）

#### 2. Bootstrap Pipeline（服务级引导）
- **模板文件**：`ci/boot/pipeline.yaml`
- **命名规范**：`bootstrap-{service}-{env}`
- **部署频率**：新服务接入或服务级基础设施变更时运行
- **部署资源**：
  - Cloud Map Service（`boot-sd-{service}-{env}`）
  - LogGroup（`boot-log-{service}-{env}`）
  - ALB 栈（`boot-alb-{service}-{env}`）

#### 3. App Pipeline（应用部署）
- **模板文件**：`ci/app/pipeline.yaml`
- **命名规范**：`{service}-{env}`
- **部署频率**：日常业务发布，支持多泳道并行
- **部署资源**：
  - Lane 应用栈（`app-{service}-{env}-{lane}`）
  - Task Definition、ECS Service、Target Group、Listener Rule

## 🚀 快速开始

### 环境准备

1. **配置 AWS 环境**
```bash
# 设置 AWS 配置
export AWS_PROFILE=your-profile
export AWS_REGION=us-west-2

# 或使用环境变量文件
source scripts/env.sh
```

2. **准备 IAM 角色**
```bash
# 运行 IAM 角色设置脚本
./ci/setup-iam-roles.sh
```

### 部署流程

#### 1. 部署环境级基础设施

```bash
# 部署基础设施 Pipeline
./ci/pipeline-deploy.sh infra parameters/infra-dev.json

# 手动触发基础设施 Pipeline
aws codepipeline start-pipeline-execution \
  --name infra-dev \
  --region us-west-2
```

#### 2. 部署服务级基础设施

```bash
# 部署引导 Pipeline
./ci/pipeline-deploy.sh boot parameters/boot-dev.json

# 手动触发引导 Pipeline
aws codepipeline start-pipeline-execution \
  --name bootstrap-user-api-dev \
  --region us-west-2
```

#### 3. 部署应用服务

```bash
# 部署应用 Pipeline
./ci/pipeline-deploy.sh app parameters/demo-user-rpc-dev.json

# 触发应用部署（支持多泳道）
aws codepipeline start-pipeline-execution \
  --name user-api-dev \
  --region us-west-2 \
  --variables name=LANE,value=gray name=BRANCH,value=release/1.2.3
```

## 📋 命名规范

### Pipeline 命名
- **Infra Pipeline**：`infra-{env}`（环境级共享）
- **Bootstrap Pipeline**：`bootstrap-{service}-{env}`（服务级引导）
- **App Pipeline**：`{service}-{env}`（应用部署）

### 资源命名规范

| 资源类型 | 命名模式 | 示例 | 说明 |
|---------|---------|------|------|
| **环境级共享** | | | |
| Infrastructure Stack | `infra-environment-{env}` | `infra-environment-dev` | 环境基础设施栈 |
| Cloud Map Namespace | `{env}.local` | `dev.local` | 服务发现命名空间 |
| ECS Cluster | `{env}-cluster` | `dev-cluster` | ECS 集群 |
| **服务级共享** | | | |
| Bootstrap Stack | `boot-{service}-{env}` | `boot-user-api-dev` | 服务引导栈 |
| **应用级资源** | | | |
| Application Stack | `app-{service}-{env}-{lane}` | `app-user-api-dev-gray` | 业务应用栈 |
| Task Definition | `{service}-{lane}-{env}-task` | `user-api-gray-dev-task` | 任务定义 |
| ECS Service | `{service}-{env}-{lane}` 或 `{service}-{env}-default` | `user-api-dev-gray` 或 `user-api-dev-default` | ECS 服务 |

## 🔧 核心组件

### 统一 BuildSpec

所有服务共享同一 `buildspec.yaml`：

```yaml
version: 0.2

env:
  shell: bash
  variables:
    MODULE_PATH: "."                  # 相对"应用仓库根"（AppOut）
    DOCKERFILE_PATH: "ci/Dockerfile"  # 相对"应用仓库根"（AppOut）
    SKIP_TESTS: "1"

phases:
  install:
    runtime-versions:
      java: corretto21
    commands:
      - chmod +x ci/*.sh

  pre_build:
    commands:
      - . ci/prebuild.sh

  build:
    commands:
      - . ci/build.sh

  post_build:
    commands:
      - . ci/postbuild.sh

artifacts:
  files:
    - cfn-params.json   # 从主输入根目录打包
```

### 服务栈模板

应用级资源通过 `service-stack.yaml` 部署：

```yaml
Parameters:
  ServiceName:
    Type: String
    Description: 'Service name (e.g. demo-rpc or web-api)'
  
  Lane:
    Type: String
    Default: 'default'
    Description: 'Deployment lane name (passed from pipeline variable)'
  
  ImageUri:
    Type: String
    Description: 'Container image URI (generated by buildspec.yaml)'

Resources:
  TaskDefinition:
    Type: AWS::ECS::TaskDefinition
    Properties:
      Family: !Sub '${ServiceName}-${Lane}-${Env}-task'
      # ... 任务定义配置
  
  ECSService:
    Type: AWS::ECS::Service
    Properties:
      ServiceName: !Sub '${ServiceName}-${Env}-${Lane}'
      # ... 服务配置
```

## 🌊 多泳道部署

### 泳道管理

#### 新增泳道
```bash
# 触发新泳道部署
aws codepipeline start-pipeline-execution \
  --name user-api-dev \
  --variables name=LANE,value=blue name=BRANCH,value=feature/new-feature
```

#### 删除泳道
```bash
# 删除泳道栈
aws cloudformation delete-stack \
  --stack-name app-user-api-dev-blue
```

### 流量路由

基于 W3C Trace Context 标准的流量分发：

```yaml
ListenerRule:
  Type: AWS::ElasticLoadBalancingV2::ListenerRule
  Properties:
    Actions:
      - Type: forward
        TargetGroupArn: !Ref TargetGroup
    Conditions:
      - Field: http-header
        HttpHeaderConfig:
          HttpHeaderName: tracestate
          Values: 
            - "ctx=lane:gray"
```

## 📊 监控与日志

### 日志聚合

```yaml
LogGroup:
  Type: AWS::Logs::LogGroup
  Properties:
    LogGroupName: !Sub '/ecs/${Env}/${ServiceName}'
    RetentionInDays: 30

TaskDefinition:
  Properties:
    ContainerDefinitions:
      - LogConfiguration:
          LogDriver: awslogs
          Options:
            awslogs-group: !Ref LogGroup
            awslogs-stream-prefix: !Ref Lane
```

### 健康检查

```yaml
TargetGroup:
  Type: AWS::ElasticLoadBalancingV2::TargetGroup
  Properties:
    HealthCheckPath: /health
    HealthCheckIntervalSeconds: 30
    HealthCheckTimeoutSeconds: 5
    HealthyThresholdCount: 2
    UnhealthyThresholdCount: 3
```

## 🔒 安全与权限

### IAM 权限策略

业务 Pipeline 权限示例：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "cloudformation:*",
      "Resource": "arn:aws:cloudformation:*:*:stack/app-{service}-{env}-*/*"
    },
    {
      "Effect": "Deny",
      "Action": "cloudformation:*",
      "Resource": [
        "arn:aws:cloudformation:*:*:stack/boot-alb-*/*",
        "arn:aws:cloudformation:*:*:stack/boot-sd-*/*",
        "arn:aws:cloudformation:*:*:stack/infra-network/*"
      ]
    }
  ]
}
```

## 🛠️ 运维操作

### 环境初始化

```bash
# 1. 部署环境级基础设施
./ci/pipeline-deploy.sh infra parameters/infra-dev.json

# 2. 部署服务级基础设施
./ci/pipeline-deploy.sh boot parameters/boot-dev.json

# 3. 部署应用 Pipeline
./ci/pipeline-deploy.sh app parameters/demo-user-rpc-dev.json
```

### 服务发布

```bash
# 标准发布流程
aws codepipeline start-pipeline-execution \
  --name user-api-dev \
  --variables name=LANE,value=gray name=BRANCH,value=release/1.2.3

# 多泳道并行发布
aws codepipeline start-pipeline-execution \
  --name user-api-dev \
  --variables name=LANE,value=blue name=BRANCH,value=feature/experiment
```

### 故障处理

```bash
# 查看 Pipeline 状态
aws codepipeline get-pipeline-state --name user-api-dev

# 查看 CloudFormation 栈状态
aws cloudformation describe-stacks --stack-name app-user-api-dev-gray

# 查看 ECS 服务状态
aws ecs describe-services \
  --cluster your-cluster \
  --services user-api-dev-gray
```

## 📚 详细架构设计

### 问题定义与解决方案

#### 现状问题
- 各服务的 CI/CD 模板分散在业务仓中，buildspec、pipeline.yaml、CFN 模板版本不统一
- DevOps 统一升级难、合规难、治理成本高
- 希望在保持业务仓独立开发的前提下，集中统一 CI/CD 流程逻辑

#### 目标方案
通过双仓结构实现 DevOps 模板集中治理、业务代码独立演进。所有服务共享统一 buildspec.yaml 与 CloudFormation 模板。

### 系统架构概览

系统采用三层 Pipeline 架构设计，将环境级、服务级、应用级资源完全解耦：

```
┌─────────────────────────────────────────────────────────────┐
│                    Pipeline 架构层                           │
├─────────────────────────────────────────────────────────────┤
│  Infra Pipeline    │  Bootstrap Pipeline  │  App Pipeline   │
│  (环境级共享)       │  (服务级引导)        │  (应用部署)      │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ 资源依赖关系
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    基础设施资源层                             │
├─────────────────────────────────────────────────────────────┤
│ 环境级共享          │ 服务级共享          │ 应用级资源        │
│ ├─ VPC Stack       │ ├─ Cloud Map Service│ ├─ Task Definition│
│ ├─ Cloud Map NS    │ ├─ LogGroup         │ ├─ ECS Service    │
│                    │ └─ ALB Stack        │ ├─ Target Group   │
│                    │                     │ └─ Listener Rule  │
└─────────────────────────────────────────────────────────────┘
```

### Pipeline 依赖关系

```
Infra Pipeline (环境级)
    ↓ 导出环境级资源
Bootstrap Pipeline (服务级)
    ↓ 导出服务级资源
App Pipeline (应用级)
    ↓ 创建应用级资源
```

### 并发控制机制

#### 层级隔离
- **环境级**：`infra-{env}` 独立运行，不与其他 Pipeline 冲突
- **服务级**：`bootstrap-{service}-{env}` 按服务隔离，不同服务可并行
- **应用级**：`{service}-{env}` 按泳道隔离，同服务多泳道可并行

#### 资源锁机制
- **CloudFormation 单栈锁**：每个栈独立锁定，不同栈可并行
- **共享资源只读**：业务发布过程中只读引用共享资源
- **栈级隔离**：不同层级使用不同栈名，避免锁冲突

## 🏗️ 栈架构设计

### 环境级共享基础设施层

共享层负责提供基础网络、负载均衡、服务发现和日志聚合能力，采用只读引用模式，避免业务发布时的并发冲突。

#### VPC 网络栈
- **栈名称**：`infra-environment-{env}`
- **职责**：创建完整的 VPC 网络基础设施，包括 VPC、子网、NAT 网关、Cloud Map Namespace 和 ECS 集群
- **导出资源**：
  - `infra-environment-${Env}-VpcId`：VPC 标识符
  - `infra-environment-${Env}-PrivateSubnets`：私有子网列表
  - `infra-environment-${Env}-PublicSubnets`：公有子网列表
  - `infra-environment-${Env}-ClusterName`：ECS 集群名称
  - `infra-environment-${Env}-namespace-id`：Cloud Map 命名空间 ID
- **使用方**：Bootstrap Pipeline、App Pipeline（通过 ImportValue 引用）

### 服务级共享基础设施层

#### Bootstrap 栈
- **栈名称**：`boot-{service}-{env}`
- **创建资源**：
  - Application Load Balancer：`{service}-{env}-alb`
  - HTTP Listener：端口 80
  - 默认 Target Group：`{service}-{env}-default-tg`
  - Cloud Map Service：`{service}`
  - CloudWatch Log Group：`/ecs/{env}/{service}`
- **导出资源**：
  - `boot-${ServiceName}-${Env}-LoadBalancerArn`：负载均衡器 ARN
  - `boot-${ServiceName}-${Env}-DnsName`：负载均衡器 DNS 名称
  - `boot-${ServiceName}-${Env}-HttpListenerArn`：HTTP 监听器 ARN
  - `boot-${ServiceName}-${Env}-${ServiceName}-service-arn`：Cloud Map Service ARN
  - `boot-${ServiceName}-${Env}-LogGroupName`：日志组名称
- **使用方**：App Pipeline（通过 ImportValue 引用）

### 应用级资源层

业务层采用每泳道一栈的设计，实现完全的资源隔离和并行部署能力。

#### Lane 应用栈
- **栈名称**：`app-{service}-{env}-{lane}`
- **创建资源**：
  - **Task Definition**：`{service}-{lane}-{env}-task`
    - 容器环境变量：`ENV={env}`, `LANE={lane}`
  - **ECS Service**：`{service}-{env}-{lane}`
    - 服务注册：注册到 Cloud Map Service
    - 实例属性：`lane`, `env`
  - **Target Group**：`{service}-{env}-{lane}-tg`
  - **Listener Rule**：`{service}-{env}-{lane}-rule`
    - 匹配条件：HTTP Header `tracestate` 包含 `ctx=lane:{lane}`
    - 转发动作：转发到对应的 Target Group
- **引用资源**：
  - 网络：`infra-environment-${Env}-VpcId/PrivateSubnets`（通过 ImportValue）
  - 服务发现：`boot-${ServiceName}-${Env}-${ServiceName}-service-arn`（通过 ImportValue）
  - 负载均衡：`boot-${ServiceName}-${Env}-HttpListenerArn`（通过 ImportValue）
  - 日志：`boot-${ServiceName}-${Env}-LogGroupName`（通过 ImportValue）

**并发特性**：不同 Lane 使用不同的栈名称，CloudFormation 采用单栈锁机制，各 Lane 可并行部署而不产生锁冲突。

## 🔄 Pipeline 编排与执行流程

### 三层 Pipeline 执行策略

系统采用三层 Pipeline 架构，每层有独立的执行策略和触发机制：

#### Infra Pipeline 执行
- **触发方式**：手动触发或环境初始化时自动触发
- **执行频率**：环境级变更时执行，通常很少变更
- **并发控制**：同一环境只有一个 Infra Pipeline 实例

#### Bootstrap Pipeline 执行
- **触发方式**：新服务接入或服务级基础设施变更时手动触发
- **执行频率**：服务级变更时执行，相对较少
- **并发控制**：不同服务的 Bootstrap Pipeline 可并行执行

#### App Pipeline 执行
- **触发方式**：日常业务发布，支持多泳道并行触发
- **执行频率**：高频执行，支持持续集成/持续部署
- **并发控制**：同服务多泳道可并行，不同服务可并行

### 触发机制与变量管理

#### 运行时变量
- **App Pipeline 必填变量**：`lane`, `branch`
- **Bootstrap Pipeline 变量**：`service`, `env`（通过参数传递）
- **Infra Pipeline 变量**：`env`（通过参数传递）
- **并发支持**：可同时触发多个 Lane（如 `lane=gray`, `lane=blue`），部署到不同栈实现并行执行

#### 变量传递链路
```
触发变量 → CodeBuild 环境变量 → 部署参数文件 → CloudFormation 参数
```

### 执行阶段设计

#### Source 阶段
- **Infra Pipeline**：从 `nianien/infra-devops` 仓库获取基础设施模板
- **Bootstrap Pipeline**：从 `nianien/infra-devops` 仓库获取基础设施模板
- **App Pipeline**：从应用仓库获取应用代码，从 `nianien/infra-devops` 获取基础设施模板

#### Build 阶段（仅 App Pipeline）
- **环境变量注入**：
  ```bash
  SERVICE_NAME=${service}
  MODULE_PATH=${module_path}
  APP_ENV=${env}
  LANE=${lane}
  BRANCH=${branch}
  ```
- **构建流程**：
  1. 构建 Docker 镜像
  2. 推送到 ECR
  3. 生成镜像标签：`ImageTag=commitSHA`
- **参数文件生成**：
  ```json
  {
    "ServiceName": "user-api",
    "Env": "dev", 
    "LaneName": "gray",
    "ImageTag": "sha-1a2b3c"
  }
  ```
- **部署执行**：
  ```bash
  aws cloudformation deploy \
    --stack-name app-{service}-{env}-{lane} \
    --parameter-overrides file://deploy-params.json
  ```

#### Deploy 阶段
- **Infra Pipeline**：部署环境级共享资源（VPC、Cloud Map Namespace）
- **Bootstrap Pipeline**：部署服务级共享资源（Cloud Map Service、LogGroup、ALB）
- **App Pipeline**：部署应用级资源（Task Definition、ECS Service、Target Group、Listener Rule）

#### Verify 阶段（仅 App Pipeline）
- **健康检查**：验证目标 Target Group 健康实例数量 > 0
- **功能验证**：执行 `curl /healthz` 确认服务可用性

**设计优势**：采用分层部署模式，每层 Pipeline 职责清晰，避免跨层级资源冲突，支持高并发部署。

## ⚙️ 参数管理与环境变量

### 参数分类与来源

#### 静态模板参数
**来源**：`pipeline.yaml` 配置文件
- `service`：服务名称
- `repo`：代码仓库地址
- `module_path`：模块路径
- `env`：应用环境
- `cluster_name`：ECS 集群名称
- `vpc`：VPC 标识符

#### 共享层导出参数
**来源**：共享基础设施栈的 Export 值
- `infra-environment-${Env}-VpcId/PrivateSubnets`：网络配置
- `infra-environment-${Env}-namespace-id`：Cloud Map 命名空间 ID
- `boot-${ServiceName}-${Env}-HttpListenerArn`：负载均衡监听器 ARN
- `boot-${ServiceName}-${Env}-LogGroupName`：日志组名称

#### 运行时动态变量
**来源**：Pipeline 触发时提供
- `branch`：代码分支
- `lane`：部署泳道

### 环境变量注入策略

#### CodeBuild 环境变量
```bash
# 构建阶段注入
SERVICE_NAME=${service}
MODULE_PATH=${module_path}
APP_ENV=${env}
LANE=${lane}
BRANCH=${branch}
```

#### 容器环境变量
```bash
# Task Definition 中注入
APP_ENV=${env}
LANE=${lane}
SPRING_PROFILES_ACTIVE=${env}
WEB_SERVER_PORT=8080
RPC_SERVER_PORT=8081
```

### 参数传递链路

```
Pipeline 配置 → 触发变量 → CodeBuild 环境 → 部署参数文件 → CloudFormation 栈
     ↓              ↓           ↓              ↓                ↓
  静态参数        动态变量    环境变量注入    参数文件生成      资源创建
```

## 🔧 核心组件设计

### VPC 网络共享

#### 设计原则
- **完整创建**：`infra-environment-{env}` 创建完整的 VPC 网络基础设施，包括 VPC、子网、NAT 网关、Cloud Map Namespace 和 ECS 集群
- **只读引用**：业务发布过程中不修改网络配置，确保零风险
- **统一管理**：所有业务共享统一的网络基础设施

#### 导出资源
- `infra-environment-${Env}-VpcId`：VPC 标识符
- `infra-environment-${Env}-PrivateSubnets`：私有子网列表
- `infra-environment-${Env}-PublicSubnets`：公有子网列表
- `infra-environment-${Env}-ClusterName`：ECS 集群名称

### 服务发现架构

#### 双层设计
- **Namespace 层**：
  - 创建资源：Cloud Map Private DNS Namespace `{env}.local`
  - 导出资源：`infra-environment-${Env}-namespace-id`
- **Service 层**：
  - 创建资源：Cloud Map Service `{service}`
  - 导出资源：`boot-${ServiceName}-${Env}-${ServiceName}-service-arn`

#### 服务注册机制
- ECS Service 通过 `ServiceRegistries` 注册到 Cloud Map
- 实例属性：`lane`, `env`
- 客户端支持按属性过滤或全量轮询

### 负载均衡与流量路由

#### ALB 共享栈
- **创建资源**：
  - Application Load Balancer：`{service}-{env}-alb`
  - HTTP Listener：端口 80
  - 默认 Target Group：`{service}-{env}-default-tg`
- **导出资源**：`boot-${ServiceName}-${Env}-LoadBalancerArn`, `boot-${ServiceName}-${Env}-DnsName`, `boot-${ServiceName}-${Env}-HttpListenerArn`

#### Lane 栈路由规则
- **Target Group**：`{service}-{env}-{lane}-tg`
- **Listener Rule**：`{service}-{env}-{lane}-rule`
- **匹配条件**：HTTP Header `tracestate` 包含 `ctx=lane:{lane}`
- **转发动作**：转发到对应的 Target Group

**隔离优势**：Target Group 和 Listener Rule 归属于 Lane 栈，新增/删除泳道完全在 Lane 栈内完成，共享 ALB 仅做只读引用，避免并发更新冲突。

### 日志聚合系统

#### 日志架构
- **Log Group**：`/ecs/{env}/{ServiceName}`
- **容器配置**：
  ```json
  {
    "awslogs-group": "/ecs/{env}/{ServiceName}",
    "awslogs-stream-prefix": "{lane}"
  }
  ```

#### 日志分析能力
- 支持 CloudWatch Logs Insights 三维筛查：lane/环境/服务
- 便于问题定位和性能分析

## 🔒 并发控制与安全保障

### 并行部署机制

#### 栈级隔离
- **不同 Lane 不同栈**：`app-{service}-{env}-{lane}` 使用独立栈名
- **CloudFormation 单栈锁**：各 Lane 栈并行执行，互不阻塞
- **共享层只读**：VPC/ALB/Cloud Map/LogGroup 在业务发布中保持只读状态

#### 资源生命周期管理
- **Lane 栈内资源**：Target Group 和 Listener Rule 与 Lane 栈生命周期一致
- **新增泳道**：完全在 Lane 栈内完成，无需修改共享基础设施
- **删除泳道**：删除 Lane 栈自动清理相关资源

### 故障处理与回滚

#### 自动回滚机制
- **ECS Circuit Breaker**：部署失败时自动回滚到上一个 Task Definition 修订版
- **版本回退**：重新发布上一个 `ImageTag` 实现快速回退
- **健康检查**：Target Group 健康检查确保服务可用性

#### 监控告警
- **ALB 监控**：5xx 错误率 > 1%（5分钟窗口）
- **ECS 监控**：`UnhealthyHostCount > 0`（3次检查）
- **容量监控**：`RunningCount < DesiredCount`（5分钟窗口）

### 权限控制与安全策略

#### 业务 Pipeline 权限
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "cloudformation:*",
      "Resource": "arn:aws:cloudformation:*:*:stack/app-{service}-{env}-*/*"
    },
    {
      "Effect": "Allow", 
      "Action": [
        "elasticloadbalancing:DescribeRules",
        "elasticloadbalancing:CreateRule",
        "elasticloadbalancing:ModifyRule",
        "elasticloadbalancing:DeleteRule"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Deny",
      "Action": "cloudformation:*",
      "Resource": [
        "arn:aws:cloudformation:*:*:stack/boot-*/*",
        "arn:aws:cloudformation:*:*:stack/infra-environment-*/*"
      ]
    }
  ]
}
```

#### 共享栈保护策略
- **Stack Policy**：禁止修改 Listener、证书、默认动作
- **资源锁定**：关键共享资源启用删除保护

## 🚀 端到端部署流程

### 环境初始化流程

#### 环境级基础设施部署
1. **部署 Infra Pipeline**：`infra-{env}`
2. **创建环境级资源**：
   - 环境基础设施栈（`infra-environment-{env}`）
3. **导出环境级资源**：供后续 Pipeline 引用

#### 服务级基础设施部署
1. **部署 Bootstrap Pipeline**：`bootstrap-{service}-{env}`
2. **创建服务级资源**：
   - Bootstrap 栈（`boot-{service}-{env}`）
3. **导出服务级资源**：供 App Pipeline 引用

### 标准发布流程

#### 触发阶段
1. **Pipeline 触发**：`{service}-{env}`
2. **变量设置**：`lane=gray`, `branch=release/1.2.3`
3. **代码获取**：按指定分支拉取源代码

#### 构建阶段
1. **环境变量注入**：`SERVICE_NAME`, `MODULE_PATH`, `APP_ENV`, `LANE`, `BRANCH`
2. **镜像构建**：构建 Docker 镜像并推送到 ECR
3. **标签生成**：`ImageTag=sha-xxx`
4. **参数文件生成**：`deploy-params.json`

#### 部署阶段
1. **栈部署**：`app-{service}-{env}-{lane}`
2. **资源创建**：Task Definition、ECS Service、Target Group
3. **路由配置**：Listener Rule 匹配 `tracestate: ctx=lane:gray`
4. **服务注册**：注册到 Cloud Map Service

#### 验证阶段
1. **健康检查**：验证 Target Group 健康实例
2. **功能验证**：执行 `/health` 端点检查
3. **流量验证**：确认流量正确路由

## 📋 详细部署指南

### 部署顺序

#### 1. 部署 Infrastructure Pipeline（一次性）

```bash
# 部署基础设施 Pipeline
aws cloudformation deploy \
  --template-file ci/infra/pipeline.yaml \
  --stack-name infra-pipeline-dev \
  --parameter-overrides \
    PipelineName=infra-pipeline-dev \
    Env=dev \
    CloudFormationDeployRoleArn=arn:aws:iam::ACCOUNT:role/CloudFormationDeployRole \
    CodePipelineRoleArn=arn:aws:iam::ACCOUNT:role/CodePipelineRole \
  --capabilities CAPABILITY_IAM
```

#### 2. 手动触发 Infrastructure Pipeline

在 AWS Console 中手动触发 `infra-pipeline-dev`，它会部署：
- `infra-environment-dev` (VPC + Subnets + Cloud Map Namespace + ECS Cluster)

#### 3. 部署 Bootstrap Pipeline（每个服务一个）

```bash
# 部署服务级基础设施 Pipeline
aws cloudformation deploy \
  --template-file ci/boot/pipeline.yaml \
  --stack-name bootstrap-user-api-pipeline-dev \
  --parameter-overrides \
    PipelineName=bootstrap-user-api-dev \
    ServiceName=user-api \
    Env=dev \
    CloudFormationDeployRoleArn=arn:aws:iam::ACCOUNT:role/CloudFormationDeployRole \
    CodePipelineRoleArn=arn:aws:iam::ACCOUNT:role/CodePipelineRole \
  --capabilities CAPABILITY_IAM
```

#### 4. 部署 App Pipeline（每个服务一个）

```bash
# 部署业务服务 Pipeline
aws cloudformation deploy \
  --template-file ci/app/pipeline.yaml \
  --stack-name user-service-pipeline-dev \
  --parameter-overrides \
    PipelineName=user-service-dev \
    ServiceName=user-service \
    AppRepo=skyfalling/user-service \
    InfraRepo=skyfalling/infra-devops \
    Env=dev \
    CloudFormationDeployRoleArn=arn:aws:iam::ACCOUNT:role/CloudFormationDeployRole \
    CodePipelineRoleArn=arn:aws:iam::ACCOUNT:role/CodePipelineRole \
    CodeBuildRoleArn=arn:aws:iam::ACCOUNT:role/CodeBuildRole \
  --capabilities CAPABILITY_IAM
```

### 关键修复

#### 1. ✅ Source 阶段分支引用修复
```yaml
# 修复前
BranchName: !Ref BranchName  # ❌ BranchName 参数不存在

# 修复后  
BranchName: "#{variables.BRANCH}"  # ✅ 使用 Pipeline 变量
```

#### 2. ✅ ALB 栈模板路径修复
```yaml
# 修复前
TemplatePath: 'SourceOut::ci/network-stack.yaml'  # ❌ 错误模板

# 修复后
TemplatePath: 'SourceOut::ci/alb-stack.yaml'  # ✅ 正确模板
```

#### 3. ✅ 共享栈并发问题解决
- **问题**: 多个业务 Pipeline 同时更新共享栈导致 CFN 栈锁冲突
- **解决**: 将共享栈迁出到独立的 Infrastructure Pipeline
- **结果**: Service Pipeline 只部署应用栈，完全避免并发冲突

### 并发部署能力

✅ **支持多服务并发部署**
- 每个服务有独立的 Service Pipeline
- 共享基础设施由 Infrastructure Pipeline 统一管理
- 无栈并发更新冲突

✅ **支持多环境并发部署**  
- 每个环境有独立的 Infrastructure Pipeline
- 环境间完全隔离

### 注意事项

1. **Infrastructure Pipeline 需要先部署**，确保共享栈存在
2. **Service Pipeline 依赖共享栈的 Export**，确保 ImportValue 正确
3. **IAM 角色权限**需要覆盖所有栈的部署权限
4. **Artifact Bucket** 需要在同一 Region

## 📊 需求映射与实现验证

### 核心需求实现对照

| 需求项 | 实现方案 | 验证标准 |
|--------|----------|----------|
| **多 Pipeline 并行** | 不同 Pipeline 使用不同 lane 栈和资源前缀 | 无并发更新锁冲突，支持同时部署多个泳道 |
| **多泳道部署** | TD: `{service}-{lane}-{env}-task`<br>Service: `{service}-{env}-{lane}` 或 `{service}-{env}-default` | 命名规范统一，资源隔离完整 |
| **Pipeline 参数** | 模板参数: `service, repo, branch, module_path, env, cluster_name, vpc`<br>触发变量: `branch, lane` | 参数传递链路完整，支持动态覆盖 |
| **环境变量注入** | CodeBuild: `SERVICE_NAME/MODULE_PATH/APP_ENV/LANE/BRANCH`<br>容器: `APP_ENV, LANE, SPRING_PROFILES_ACTIVE, WEB_SERVER_PORT, RPC_SERVER_PORT` | 环境变量正确注入到构建和运行时环境 |
| **VPC 共享** | Export/Import 模式导出 `infra-environment-${Env}-VpcId/PrivateSubnets` | ALB 和 lane 栈正确引用共享网络资源 |
| **Cloud Map 双层** | Namespace: `{env}.local` + Service: `{service}` | 服务发现功能正常，支持实例注册和查询 |
| **ALB 共享栈** | ALB: `{service}-{env}-alb` + Listener | 负载均衡器正确创建，导出关键资源信息 |
| **Lane 路由规则** | TG: `{service}-{env}-{lane}-tg`<br>规则: `tracestate: ctx=lane:xxx`<br>默认回退: `{service}-{env}-default-tg` | 流量正确路由到指定泳道，默认回退机制有效 |
| **日志聚合** | Log Group: `/ecs/{env}/{ServiceName}`<br>Stream Prefix: `{lane}` | 日志正确聚合，支持按泳道维度分析 |

### 架构优势总结

#### 技术优势
- **高并发能力**：支持多泳道并行部署，无锁冲突
- **资源隔离**：每个泳道独立栈，故障影响范围可控
- **动态扩展**：新增泳道无需修改共享基础设施
- **标准化路由**：基于 W3C Trace Context 标准的流量分发

#### 运维优势
- **零运维介入**：泳道管理完全自动化
- **快速回滚**：支持版本级和泳道级回滚
- **统一监控**：集中化的日志和监控体系
- **权限控制**：细粒度的权限管理和资源保护

#### 业务优势
- **灰度发布**：支持渐进式流量切换
- **A/B 测试**：多版本并行运行能力
- **快速迭代**：缩短发布周期，提高交付效率
- **风险控制**：降低发布风险，提高系统稳定性

### 双仓架构优势
- **模板统一治理**：所有服务使用统一的 buildspec 和 CloudFormation 模板
- **DevOps 集中管理**：模板升级、合规检查、版本控制集中化
- **业务代码独立**：各服务仓专注业务逻辑，可独立开发和部署
- **低运维成本**：无需逐仓维护 CI/CD 模板，大幅降低运维复杂度

### 分层 Pipeline 架构优势
- **职责清晰**：环境级、服务级、应用级 Pipeline 职责明确分离
- **并发无锁**：不同层级 Pipeline 独立运行，避免资源锁冲突
- **扩展性强**：新增服务或泳道无需修改现有 Pipeline
- **维护简单**：每层 Pipeline 独立维护，降低复杂度

### 资源管理优势
- **环境级共享**：VPC、Cloud Map Namespace 等环境级资源统一管理
- **服务级隔离**：Cloud Map Service、LogGroup、ALB 按服务隔离
- **应用级并发**：Task Definition、ECS Service 按泳道并发部署


**核心价值**：在保证系统稳定性的前提下，实现了部署效率的最大化和运维成本的显著降低，为业务快速迭代和风险控制提供了强有力的技术支撑。
