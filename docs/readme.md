# 多泳道 ECS 持续交付架构设计

## 1. 执行摘要

本方案基于 AWS CodePipeline 和 CloudFormation 构建了一套支持多泳道并行部署的 ECS 持续交付系统。通过双仓架构设计、分层 Pipeline 架构和共享基础设施层设计，实现了 DevOps 模板集中治理、高并发、零冲突的微服务部署能力。

### 1.1 核心特性
- **双仓架构设计**：Infra 仓集中管理 DevOps 模板，App 仓专注业务代码，实现模板统一治理
- **分层 Pipeline 架构**：环境级、服务级、应用级三层 Pipeline 分离，职责清晰
- **统一 BuildSpec**：所有服务共享同一 buildspec.yaml，通过双源输入机制访问业务代码
- **并行无锁部署**：不同层级 Pipeline 独立运行，支持多泳道并行执行
- **动态泳道管理**：运行时通过变量指定泳道和分支，无需预定义泳道配置
- **基础设施共享**：VPC、Cloud Map Namespace 等环境级资源与业务层解耦
- **智能流量路由**：基于 W3C Trace Context 标准的 `tracestate` 头部进行精确流量分发
- **闭环参数传递**：CodeBuild 内完成构建和部署，确保参数传递的一致性和可靠性

## 2. 架构设计

### 2.1 双仓架构 + 统一 BuildSpec 技术方案

#### 2.1.1 问题定义

**现状**：
- 各服务的 CI/CD 模板分散在业务仓中，buildspec、pipeline.yaml、CFN 模板版本不统一
- DevOps 统一升级难、合规难、治理成本高
- 希望在保持业务仓独立开发的前提下，集中统一 CI/CD 流程逻辑

**目标**：
通过双仓结构实现 DevOps 模板集中治理、业务代码独立演进。所有服务共享统一 buildspec.yaml 与 CloudFormation 模板。

#### 2.1.2 核心方案

**仓库职责划分**：

| 仓库 | 内容 | 示例路径 |
|------|------|----------|
| Infra Repo | 统一 DevOps 模板（buildspec、pipeline、CFN 模板、通用脚本） | `ci/buildspec.yaml`、`ci/service-stack.yaml` |
| App Repo | 各服务代码（源代码、Dockerfile、配置文件等） | `src/`, `Dockerfile` |

**CodePipeline 双源输入设计**：

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

**Build 阶段关键配置**：

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

**CodeBuild 项目配置**：

```yaml
Source:
  Type: CODEPIPELINE
  BuildSpec: 'ci/buildspec.yaml'   # 从 InfraOut 获取
```

✅ 主输入 (InfraOut) 提供统一 buildspec  
✅ 副输入 (AppOut) 提供业务代码

**BuildSpec 访问业务代码**：

CodeBuild 容器中自动挂载两个目录：

| 环境变量 | 内容 |
|----------|------|
| `$CODEBUILD_SRC_DIR` | InfraOut（buildspec 所在目录） |
| `$CODEBUILD_SRC_DIR_AppOut` | AppOut（业务代码仓） |

**示例**：

```yaml
pre_build:
  commands:
    - cd $CODEBUILD_SRC_DIR_AppOut/$MODULE_PATH
    - docker build -t $SERVICE_NAME .
    - docker tag $SERVICE_NAME:$CODEBUILD_RESOLVED_SOURCE_VERSION $ECR_URI/$SERVICE_NAME:$SERVICE_VERSION
    - docker push $ECR_URI/$SERVICE_NAME:$SERVICE_VERSION
```

Infra 仓提供构建逻辑模板，业务仓只提供代码。所有服务共用同一 buildspec。

**Deploy 阶段**：
- 模板路径固定：`InfraOut::ci/service-stack.yaml`
- 制品来源：`BuildOut::cfn-params.json`
- StackName：`app-${ServiceName}-${Env}-${Lane}`

#### 2.1.3 方案优势

| 目标 | 实现 |
|------|------|
| 模板统一 | 所有服务使用同一 buildspec 与部署模板 |
| 低运维成本 | DevOps 团队集中治理模板，无需逐仓维护 |
| 业务独立 | 各服务仓仅含代码，可独立开发与部署 |
| 可扩展 | 新服务只需引入模板仓路径即可部署 |
| 可控版本 | Infra Repo 版本化；构建模板随 Tag 管理 |

### 2.2 系统架构概览

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

### 2.2 命名规范

#### 2.2.1 Pipeline 命名
- **Infra Pipeline**：`infra-{env}`（环境级共享）
- **Bootstrap Pipeline**：`bootstrap-{service}-{env}`（服务级引导）
- **App Pipeline**：`{service}-{env}`（应用部署）
- **示例**：`infra-dev`, `bootstrap-user-api-dev`, `user-api-dev`
- **触发变量**：`lane`, `branch`（运行时必填）

#### 2.2.2 资源命名规范
| 资源类型 | 命名模式 | 示例 | 说明 |
|---------|---------|------|------|
| **环境级共享** | | | |
| VPC Stack | `infra-network` | `infra-network` | 网络基础设施栈 |
| Cloud Map Namespace | `infra-namespace` | `infra-namespace` | 服务发现命名空间栈 |
| Cloud Map Namespace | `{env}.local` | `dev.local` | 服务发现命名空间 |
| **服务级共享** | | | |
| Cloud Map Service Stack | `boot-sd-{service}-{env}` | `boot-sd-user-api-dev` | 服务发现栈 |
| LogGroup Stack | `boot-log-{service}-{env}` | `boot-log-user-api-dev` | 日志组栈 |
| ALB Stack | `boot-alb-{service}-{env}` | `boot-alb-user-api-dev` | 负载均衡栈 |
| Application Load Balancer | `{service}-{env}-alb` | `user-api-dev-alb` | 负载均衡器 |
| Cloud Map Service | `{service}` | `user-api` | 服务发现服务 |
| Log Group | `/ecs/{env}/{service}` | `/ecs/dev/user-api` | 日志组 |
| **应用级资源** | | | |
| Application Stack | `app-{service}-{env}-{lane}` | `app-user-api-dev-gray` | 业务应用栈 |
| Task Definition | `{service}-{lane}-{env}-task` | `user-api-gray-dev-task` | 任务定义 |
| ECS Service | `{service}-{env}-{lane}` | `user-api-dev-gray` | ECS 服务 |
| Target Group | `{service}-{env}-{lane}-tg` | `user-api-dev-gray-tg` | 目标组 |
| Listener Rule | `{service}-{env}-{lane}-rule` | `user-api-dev-gray-rule` | 监听规则 |

**设计原则**：Target Group 和 Listener Rule 归属于 Lane Stack，实现泳道级别的资源隔离，新增泳道无需修改共享基础设施。

## 3. 三层 Pipeline 架构

### 3.1 Pipeline 分层设计

系统采用三层 Pipeline 架构，实现职责清晰分离和并发无锁部署：

#### 3.1.1 Infra Pipeline（环境级共享）
- **模板文件**：`pipeline-infra.yaml`
- **命名规范**：`infra-{env}`
- **部署频率**：环境初始化时运行一次，后续很少变更
- **部署资源**：
  - VPC 网络栈（`infra-network`）
  - Cloud Map Namespace（`infra-namespace`）
- **特点**：环境级资源，所有服务共享，避免并发更新冲突

#### 3.1.2 Bootstrap Pipeline（服务级引导）
- **模板文件**：`pipeline-boot.yaml`
- **命名规范**：`bootstrap-{env}`
- **部署频率**：新服务接入或服务级基础设施变更时运行
- **部署资源**：
  - Cloud Map Service（`boot-sd-{service}-{env}`）
  - LogGroup（`boot-log-{service}-{env}`）
  - ALB 栈（`boot-alb-{service}-{env}`）
- **特点**：服务级资源，按服务隔离，支持并行部署

#### 3.1.3 App Pipeline（应用部署）
- **模板文件**：`pipeline-app.yaml`
- **命名规范**：`{service}-{env}`
- **部署频率**：日常业务发布，支持多泳道并行
- **部署资源**：
  - Lane 应用栈（`app-{service}-{env}-{lane}`）
  - Task Definition、ECS Service、Target Group、Listener Rule
- **特点**：应用级资源，按泳道隔离，支持高并发部署

### 3.2 Pipeline 依赖关系

```
Infra Pipeline (环境级)
    ↓ 导出环境级资源
Bootstrap Pipeline (服务级)
    ↓ 导出服务级资源
App Pipeline (应用级)
    ↓ 创建应用级资源
```

### 3.3 并发控制机制

#### 3.3.1 层级隔离
- **环境级**：`infra-{env}` 独立运行，不与其他 Pipeline 冲突
- **服务级**：`bootstrap-{service}-{env}` 按服务隔离，不同服务可并行
- **应用级**：`{service}-{env}` 按泳道隔离，同服务多泳道可并行

#### 3.3.2 资源锁机制
- **CloudFormation 单栈锁**：每个栈独立锁定，不同栈可并行
- **共享资源只读**：业务发布过程中只读引用共享资源
- **栈级隔离**：不同层级使用不同栈名，避免锁冲突

## 4. 栈架构设计

### 4.1 环境级共享基础设施层

共享层负责提供基础网络、负载均衡、服务发现和日志聚合能力，采用只读引用模式，避免业务发布时的并发冲突。

#### 4.1.1 VPC 网络栈
- **栈名称**：`infra-network`
- **职责**：包装现有 VPC 资源，提供网络基础设施
- **导出资源**：
  - `VpcId`：VPC 标识符
  - `PrivateSubnets`：私有子网列表
  - `PublicSubnets`：公有子网列表
  - `SecurityGroups`：安全组列表（可选）
- **使用方**：Bootstrap Pipeline、App Pipeline（通过 ImportValue 引用）

#### 4.1.2 Cloud Map Namespace 栈
- **栈名称**：`infra-namespace`
- **创建资源**：Cloud Map Private DNS Namespace `{env}.local`
- **导出资源**：`NamespaceId`
- **使用方**：Bootstrap Pipeline（通过 ImportValue 引用）

### 4.2 服务级共享基础设施层

#### 4.2.1 Cloud Map Service 栈
- **栈名称**：`boot-sd-{service}-{env}`
- **创建资源**：Cloud Map Service `{service}`
- **导出资源**：`SdServiceId`
- **使用方**：App Pipeline（通过 ImportValue 引用）

#### 4.2.2 负载均衡栈
- **栈名称**：`boot-alb-{service}-{env}`
- **创建资源**：
  - Application Load Balancer：`{service}-{env}-alb`
  - HTTP Listener：端口 80
  - 默认 Target Group：`{service}-{env}-default-tg`
- **导出资源**：
  - `LoadBalancerArn`：负载均衡器 ARN
  - `DnsName`：负载均衡器 DNS 名称
  - `HttpListenerArn`：HTTP 监听器 ARN
- **使用方**：App Pipeline（通过 ImportValue 引用）

#### 4.2.3 日志聚合栈
- **栈名称**：`boot-log-{service}-{env}`
- **创建资源**：CloudWatch Log Group `/ecs/{env}/{service}`
- **配置**：日志保留期 30 天
- **导出资源**：`LogGroupName`
- **使用方**：App Pipeline（通过 ImportValue 引用）

### 4.3 应用级资源层

业务层采用每泳道一栈的设计，实现完全的资源隔离和并行部署能力。

#### 4.3.1 Lane 应用栈
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
  - 网络：`VpcId/Subnets`（通过 ImportValue）
  - 服务发现：`SdServiceId`（通过 ImportValue）
  - 负载均衡：`HttpListenerArn`（通过 ImportValue）
  - 日志：`LogGroupName`（通过 ImportValue）

**并发特性**：不同 Lane 使用不同的栈名称，CloudFormation 采用单栈锁机制，各 Lane 可并行部署而不产生锁冲突。

## 5. Pipeline 编排与执行流程

### 5.1 三层 Pipeline 执行策略

系统采用三层 Pipeline 架构，每层有独立的执行策略和触发机制：

#### 5.1.1 Infra Pipeline 执行
- **触发方式**：手动触发或环境初始化时自动触发
- **执行频率**：环境级变更时执行，通常很少变更
- **并发控制**：同一环境只有一个 Infra Pipeline 实例

#### 5.1.2 Bootstrap Pipeline 执行
- **触发方式**：新服务接入或服务级基础设施变更时手动触发
- **执行频率**：服务级变更时执行，相对较少
- **并发控制**：不同服务的 Bootstrap Pipeline 可并行执行

#### 5.1.3 App Pipeline 执行
- **触发方式**：日常业务发布，支持多泳道并行触发
- **执行频率**：高频执行，支持持续集成/持续部署
- **并发控制**：同服务多泳道可并行，不同服务可并行

### 5.2 触发机制与变量管理

#### 5.2.1 运行时变量
- **App Pipeline 必填变量**：`lane`, `branch`
- **Bootstrap Pipeline 变量**：`service`, `env`（通过参数传递）
- **Infra Pipeline 变量**：`env`（通过参数传递）
- **并发支持**：可同时触发多个 Lane（如 `lane=gray`, `lane=blue`），部署到不同栈实现并行执行

#### 5.2.2 变量传递链路
```
触发变量 → CodeBuild 环境变量 → 部署参数文件 → CloudFormation 参数
```

### 5.3 执行阶段设计

#### 5.3.1 Source 阶段
- **Infra Pipeline**：从 `nianien/infra-devops` 仓库获取基础设施模板
- **Bootstrap Pipeline**：从 `nianien/infra-devops` 仓库获取基础设施模板
- **App Pipeline**：从应用仓库获取应用代码，从 `nianien/infra-devops` 获取基础设施模板

#### 5.3.2 Build 阶段（仅 App Pipeline）
- **环境变量注入**：
  ```bash
  SERVICE_NAME=${service}
  MODULE_PATH=${module_path}
  ENV=${env}
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

#### 5.3.3 Deploy 阶段
- **Infra Pipeline**：部署环境级共享资源（VPC、Cloud Map Namespace）
- **Bootstrap Pipeline**：部署服务级共享资源（Cloud Map Service、LogGroup、ALB）
- **App Pipeline**：部署应用级资源（Task Definition、ECS Service、Target Group、Listener Rule）

#### 5.3.4 Verify 阶段（仅 App Pipeline）
- **健康检查**：验证目标 Target Group 健康实例数量 > 0
- **功能验证**：执行 `curl /healthz` 确认服务可用性

**设计优势**：采用分层部署模式，每层 Pipeline 职责清晰，避免跨层级资源冲突，支持高并发部署。

## 6. 参数管理与环境变量

### 6.1 参数分类与来源

#### 6.1.1 静态模板参数
**来源**：`pipeline.yaml` 配置文件
- `service`：服务名称
- `repo`：代码仓库地址
- `module_path`：模块路径
- `env`：应用环境
- `cluster_name`：ECS 集群名称
- `vpc`：VPC 标识符

#### 5.1.2 共享层导出参数
**来源**：共享基础设施栈的 Export 值
- `VpcId/Subnets`：网络配置
- `NamespaceId`：Cloud Map 命名空间 ID
- `HttpListenerArn`：负载均衡监听器 ARN
- `LogGroupName`：日志组名称

#### 5.1.3 运行时动态变量
**来源**：Pipeline 触发时提供
- `branch`：代码分支
- `lane`：部署泳道

### 5.2 环境变量注入策略

#### 5.2.1 CodeBuild 环境变量
```bash
# 构建阶段注入
SERVICE_NAME=${service}
MODULE_PATH=${module_path}
ENV=${env}
LANE=${lane}
BRANCH=${branch}
```

#### 5.2.2 容器环境变量
```bash
# Task Definition 中注入
ENV=${env}
LANE=${lane}
```

### 5.3 参数传递链路

```
Pipeline 配置 → 触发变量 → CodeBuild 环境 → 部署参数文件 → CloudFormation 栈
     ↓              ↓           ↓              ↓                ↓
  静态参数        动态变量    环境变量注入    参数文件生成      资源创建
```

## 6. 核心组件设计

### 6.1 VPC 网络共享

#### 6.1.1 设计原则
- **包装模式**：`infra-network` 仅包装现有 VPC 资源，不进行网络资源创建
- **只读引用**：业务发布过程中不修改网络配置，确保零风险
- **统一管理**：所有业务共享统一的网络基础设施

#### 6.1.2 导出资源
- `VpcId`：VPC 标识符
- `PrivateSubnets`：私有子网列表
- `PublicSubnets`：公有子网列表
- `SecurityGroups`：安全组列表

### 6.2 服务发现架构

#### 6.2.1 双层设计
- **Namespace 层**：
  - 控制开关：`initCloudMap=true`
  - 创建资源：Cloud Map Private DNS Namespace `{env}.local`
  - 导出资源：`NamespaceId`
- **Service 层**：
  - 创建资源：Cloud Map Service `{service}`
  - 导出资源：`SdServiceId`

#### 6.2.2 服务注册机制
- ECS Service 通过 `ServiceRegistries` 注册到 Cloud Map
- 实例属性：`lane`, `env`
- 客户端支持按属性过滤或全量轮询

### 6.3 负载均衡与流量路由

#### 6.3.1 ALB 共享栈
- **创建资源**：
  - Application Load Balancer：`{service}-{env}-alb`
  - HTTP Listener：端口 80
  - 默认 Target Group：`{service}-{env}-default-tg`
- **导出资源**：`LoadBalancerArn`, `DnsName`, `HttpListenerArn`

#### 6.3.2 Lane 栈路由规则
- **Target Group**：`{service}-{env}-{lane}-tg`
- **Listener Rule**：`{service}-{env}-{lane}-rule`
- **匹配条件**：HTTP Header `tracestate` 包含 `ctx=lane:{lane}`
- **转发动作**：转发到对应的 Target Group

**隔离优势**：Target Group 和 Listener Rule 归属于 Lane 栈，新增/删除泳道完全在 Lane 栈内完成，共享 ALB 仅做只读引用，避免并发更新冲突。

### 6.4 日志聚合系统

#### 6.4.1 日志架构
- **Log Group**：`/ecs/{env}/{ServiceBase}`
- **控制开关**：`initlog=true`
- **容器配置**：
  ```json
  {
    "awslogs-group": "/ecs/{env}/{ServiceBase}",
    "awslogs-stream-prefix": "{lane}"
  }
  ```

#### 6.4.2 日志分析能力
- 支持 CloudWatch Logs Insights 三维筛查：lane/环境/服务
- 便于问题定位和性能分析

## 7. 并发控制与安全保障

### 7.1 并行部署机制

#### 7.1.1 栈级隔离
- **不同 Lane 不同栈**：`app-{service}-{env}-{lane}` 使用独立栈名
- **CloudFormation 单栈锁**：各 Lane 栈并行执行，互不阻塞
- **共享层只读**：VPC/ALB/Cloud Map/LogGroup 在业务发布中保持只读状态

#### 7.1.2 资源生命周期管理
- **Lane 栈内资源**：Target Group 和 Listener Rule 与 Lane 栈生命周期一致
- **新增泳道**：完全在 Lane 栈内完成，无需修改共享基础设施
- **删除泳道**：删除 Lane 栈自动清理相关资源

### 7.2 故障处理与回滚

#### 7.2.1 自动回滚机制
- **ECS Circuit Breaker**：部署失败时自动回滚到上一个 Task Definition 修订版
- **版本回退**：重新发布上一个 `ImageTag` 实现快速回退
- **健康检查**：Target Group 健康检查确保服务可用性

#### 7.2.2 监控告警
- **ALB 监控**：5xx 错误率 > 1%（5分钟窗口）
- **ECS 监控**：`UnhealthyHostCount > 0`（3次检查）
- **容量监控**：`RunningCount < DesiredCount`（5分钟窗口）

### 7.3 权限控制与安全策略

#### 7.3.1 业务 Pipeline 权限
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
        "arn:aws:cloudformation:*:*:stack/boot-alb-*/*",
        "arn:aws:cloudformation:*:*:stack/boot-sd-*/*",
        "arn:aws:cloudformation:*:*:stack/boot-log-*/*",
        "arn:aws:cloudformation:*:*:stack/infra-network/*"
      ]
    }
  ]
}
```

#### 7.3.2 共享栈保护策略
- **Stack Policy**：禁止修改 Listener、证书、默认动作
- **资源锁定**：关键共享资源启用删除保护

## 8. 端到端部署流程

### 8.1 环境初始化流程

#### 8.1.1 环境级基础设施部署
1. **部署 Infra Pipeline**：`infra-{env}`
2. **创建环境级资源**：
   - VPC 网络栈（`infra-network`）
   - Cloud Map Namespace（`infra-namespace`）
3. **导出环境级资源**：供后续 Pipeline 引用

#### 8.1.2 服务级基础设施部署
1. **部署 Bootstrap Pipeline**：`bootstrap-{service}-{env}`
2. **创建服务级资源**：
   - Cloud Map Service（`boot-sd-{service}-{env}`）
   - LogGroup（`boot-log-{service}-{env}`）
   - ALB 栈（`boot-alb-{service}-{env}`）
3. **导出服务级资源**：供 App Pipeline 引用

### 8.2 标准发布流程

#### 8.2.1 触发阶段
1. **Pipeline 触发**：`{service}-{env}`
2. **变量设置**：`lane=gray`, `branch=release/1.2.3`
3. **代码获取**：按指定分支拉取源代码

#### 8.2.2 构建阶段
1. **环境变量注入**：`service`, `module_path`, `env`, `lane`, `branch`
2. **镜像构建**：构建 Docker 镜像并推送到 ECR
3. **标签生成**：`ImageTag=sha-xxx`
4. **参数文件生成**：`deploy-params.json`

#### 8.2.3 部署阶段
1. **栈部署**：`app-{service}-{env}-{lane}`
2. **资源创建**：Task Definition、ECS Service、Target Group
3. **路由配置**：Listener Rule 匹配 `tracestate: ctx=lane:gray`
4. **服务注册**：注册到 Cloud Map Service

#### 8.2.4 验证阶段
1. **健康检查**：验证 Target Group 健康实例
2. **功能验证**：执行 `/healthz` 端点检查
3. **流量验证**：确认流量正确路由

## 9. 运维操作指南

### 9.1 环境初始化

#### 9.1.1 基础设施部署顺序
1. **环境级基础设施**：部署 `infra-{env}` Pipeline
   - 创建 VPC 网络栈（`infra-network`）
   - 创建 Cloud Map Namespace（`infra-namespace`）
2. **服务级基础设施**：部署 `bootstrap-{service}-{env}` Pipeline
   - 创建 Cloud Map Service（`boot-sd-{service}-{env}`）
   - 创建 LogGroup（`boot-log-{service}-{env}`）
   - 创建 ALB 栈（`boot-alb-{service}-{env}`）
3. **应用 Pipeline**：部署 `{service}-{env}` Pipeline
   - 支持多泳道并行部署

#### 9.1.2 配置管理
- **环境变量**：通过 SSM Parameter Store 管理共享配置
- **权限配置**：为 CodeBuild 角色配置最小权限原则

### 9.2 泳道管理

#### 9.2.1 新增泳道
- **操作方式**：触发 Pipeline，设置 `lane=new-lane`
- **自动化程度**：Lane 栈自动创建 Target Group 和 Listener Rule
- **运维介入**：零运维介入，完全自动化

#### 9.2.2 删除泳道
- **操作方式**：删除 `app-{service}-{env}-{lane}` 栈
- **资源清理**：自动清理 Target Group 和 Listener Rule
- **影响范围**：仅影响该泳道，不影响其他泳道

### 9.3 环境扩展

#### 9.3.1 新增环境
1. **Pipeline 复制**：复制 `{service}-{new_env}` Pipeline 配置
2. **共享层初始化**：部署新环境的共享基础设施
3. **配置验证**：验证环境间隔离和配置正确性

#### 9.3.2 跨环境迁移
- **配置同步**：确保配置参数一致性
- **数据迁移**：处理环境特定的数据迁移需求
- **验证测试**：执行端到端功能验证

## 10. 需求映射与实现验证

### 10.1 核心需求实现对照

| 需求项 | 实现方案 | 验证标准 |
|--------|----------|----------|
| **多 Pipeline 并行** | 不同 Pipeline 使用不同 lane 栈和资源前缀 | 无并发更新锁冲突，支持同时部署多个泳道 |
| **多泳道部署** | TD: `{service}-{lane}-{env}-task`<br>Service: `{service}-{env}-{lane}` | 命名规范统一，资源隔离完整 |
| **Pipeline 参数** | 模板参数: `service, repo, branch, module_path, env, cluster_name, vpc`<br>触发变量: `branch, lane` | 参数传递链路完整，支持动态覆盖 |
| **环境变量注入** | CodeBuild: `service/module_path/branch/lane/env`<br>容器: `env, lane` | 环境变量正确注入到构建和运行时环境 |
| **VPC 共享** | Export/Import 模式导出 `Subnets/VpcId` | ALB 和 lane 栈正确引用共享网络资源 |
| **Cloud Map 双层** | Namespace: `{env}.local` + Service: `{service}`<br>控制开关: `initCloudMap` | 服务发现功能正常，支持实例注册和查询 |
| **ALB 共享栈** | ALB: `{service}-{env}-alb` + Listener<br>控制开关: `initAlb` | 负载均衡器正确创建，导出关键资源信息 |
| **Lane 路由规则** | TG: `{service}-{env}-{lane}-tg`<br>规则: `tracestate: ctx=lane:xxx`<br>默认回退: `{service}-{env-default-tg` | 流量正确路由到指定泳道，默认回退机制有效 |
| **日志聚合** | Log Group: `/ecs/{env}/{ServiceBase}`<br>Stream Prefix: `{lane}`<br>控制开关: `initlog` | 日志正确聚合，支持按泳道维度分析 |

### 10.2 架构优势总结

#### 10.2.1 技术优势
- **高并发能力**：支持多泳道并行部署，无锁冲突
- **资源隔离**：每个泳道独立栈，故障影响范围可控
- **动态扩展**：新增泳道无需修改共享基础设施
- **标准化路由**：基于 W3C Trace Context 标准的流量分发

#### 10.2.2 运维优势
- **零运维介入**：泳道管理完全自动化
- **快速回滚**：支持版本级和泳道级回滚
- **统一监控**：集中化的日志和监控体系
- **权限控制**：细粒度的权限管理和资源保护

#### 10.2.3 业务优势
- **灰度发布**：支持渐进式流量切换
- **A/B 测试**：多版本并行运行能力
- **快速迭代**：缩短发布周期，提高交付效率
- **风险控制**：降低发布风险，提高系统稳定性

---

## 结论

本方案通过双仓架构设计、三层 Pipeline 架构设计、动态泳道管理和分层基础设施解耦，构建了一套高并发、零冲突的多泳道 ECS 持续交付系统。系统具备完整的并行部署能力、智能流量路由机制和全面的运维保障体系，能够满足现代微服务架构下的复杂部署需求。

### 架构优势总结

#### 双仓架构优势
- **模板统一治理**：所有服务使用统一的 buildspec 和 CloudFormation 模板
- **DevOps 集中管理**：模板升级、合规检查、版本控制集中化
- **业务代码独立**：各服务仓专注业务逻辑，可独立开发和部署
- **低运维成本**：无需逐仓维护 CI/CD 模板，大幅降低运维复杂度

#### 分层 Pipeline 架构优势
- **职责清晰**：环境级、服务级、应用级 Pipeline 职责明确分离
- **并发无锁**：不同层级 Pipeline 独立运行，避免资源锁冲突
- **扩展性强**：新增服务或泳道无需修改现有 Pipeline
- **维护简单**：每层 Pipeline 独立维护，降低复杂度

#### 资源管理优势
- **环境级共享**：VPC、Cloud Map Namespace 等环境级资源统一管理
- **服务级隔离**：Cloud Map Service、LogGroup、ALB 按服务隔离
- **应用级并发**：Task Definition、ECS Service 按泳道并发部署

**核心价值**：在保证系统稳定性的前提下，实现了部署效率的最大化和运维成本的显著降低，为业务快速迭代和风险控制提供了强有力的技术支撑。


