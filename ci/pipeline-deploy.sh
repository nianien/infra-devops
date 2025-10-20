#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Universal Pipeline Deployment Script
# =========================================================
# 统一部署脚本，支持 Infra、Bootstrap、App 三种管道类型
# 使用方法: ./pipeline-deploy.sh [TYPE] [ENV] [OPTIONS]
# 示例: ./pipeline-deploy.sh infra dev --dry-run
# =========================================================

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载环境变量（仅认证信息）
if [[ -f "$SCRIPT_DIR/env.sh" ]]; then
    source "$SCRIPT_DIR/env.sh"
else
    echo "❌ Error: env.sh not found in $SCRIPT_DIR"
    exit 1
fi


# =========================================================
# 自动发现模板文件
# =========================================================
discover_templates() {
    local type="$1"
    local templates_dir="$SCRIPT_DIR/$type/templates"
    
    if [[ ! -d "$templates_dir" ]]; then
        echo "❌ Error: Templates directory not found: $templates_dir"
        exit 1
    fi
    
    # 查找所有 .yaml 文件，排除 pipeline.yaml
    find "$templates_dir" -name "*.yaml" -not -name "pipeline.yaml" -exec basename {} \; | sort
}

# =========================================================
# 帮助信息
# =========================================================
show_help() {
    cat << EOF
Universal Pipeline Deployment Script

USAGE:
    $0 [TYPE] [ENV] [OPTIONS]

ARGUMENTS:
    TYPE                Pipeline type (infra|boot|app)
                        - infra: Environment-level shared infrastructure
                        - boot:  Service-level shared infrastructure  
                        - app:   Application deployment
    ENV                 Environment name (dev|test|preonline|online)
                        Default: dev

OPTIONS:
    --dry-run           Show deployment command without executing
    --force             Force deployment even if stack exists
    --help, -h          Show this help message

PARAMETERS FILE:
    The script uses parameters-{ENV}.json file for deployment parameters.
    Create this file manually in the corresponding directory.

EXAMPLES:
    # Deploy Infrastructure Pipeline to dev
    $0 infra dev
    
    # Deploy Bootstrap Pipeline to test with dry run
    $0 boot test --dry-run
    
    # Deploy Application Pipeline with force
    $0 app dev --force

PIPELINE TYPES:
    infra    Deploy environment-level shared infrastructure (VPC, Cloud Map Namespace)
    boot     Deploy service-level shared infrastructure (Cloud Map Service, LogGroup, ALB)
    app      Deploy application services (ECS Service, Task Definition, etc.)

EOF
}

# =========================================================
# 参数解析
# =========================================================
TYPE="${1:-}"
ENV="${2:-dev}"
DRY_RUN=false
FORCE=false

# 检查帮助参数
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_help
    exit 0
fi

# 验证管道类型
if [[ -z "$TYPE" ]]; then
    echo "❌ Error: Pipeline type is required"
    show_help
    exit 1
fi

if [[ "$TYPE" != "infra" && "$TYPE" != "boot" && "$TYPE" != "app" ]]; then
    echo "❌ Error: Invalid pipeline type '$TYPE'"
    echo "   Valid types: infra, boot, app"
    show_help
    exit 1
fi

# 解析命令行参数
shift 2 2>/dev/null || shift $#  # 移除前两个参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            if [[ $1 =~ ^[a-zA-Z0-9_-]+$ ]]; then
                ENV="$1"
            else
                echo "❌ Error: Unknown option '$1'"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# =========================================================
# 环境检查
# =========================================================
check_environment() {
    echo "🔍 Checking environment..."
    
    # 检查必需的环境变量
    local required_vars=("AWS_PROFILE" "AWS_REGION" "AWS_ACCOUNT_ID")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "❌ Error: Required environment variable $var is not set"
            exit 1
        fi
    done
    
    # 检查 AWS CLI 配置
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        echo "❌ Error: AWS CLI not configured or credentials invalid"
        echo "   Please run: aws configure --profile $AWS_PROFILE"
        exit 1
    fi
    
    # 检查参数文件
    local parameters_file="$SCRIPT_DIR/$TYPE/parameters/parameters-${ENV}.json"
    if [[ ! -f "$parameters_file" ]]; then
        echo "❌ Error: Parameters file not found: $parameters_file"
        echo "   Please create this file with the required parameters."
        echo "   You can copy from parameters-dev.json as a template."
        exit 1
    fi
    
    # 验证 JSON 格式
    if ! jq empty "$parameters_file" 2>/dev/null; then
        echo "❌ Error: Invalid JSON format in $parameters_file"
        exit 1
    fi
    
    echo "✅ Environment check passed"
}

# =========================================================
# 模板校验
# =========================================================
validate_templates() {
    echo "🔍 Validating CloudFormation templates..."
    
    # 校验主模板
    local main_template="$SCRIPT_DIR/$TYPE/pipeline.yaml"
    if [[ ! -f "$main_template" ]]; then
        echo "❌ Error: Main template not found: $main_template"
        exit 1
    fi
    
    echo "   Validating main template: pipeline.yaml"
    if ! aws cloudformation validate-template \
        --template-body "file://$main_template" \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" >/dev/null 2>&1; then
        echo "❌ Error: Main template validation failed"
        echo "   Please check the template syntax and fix errors"
        exit 1
    fi
    echo "   ✅ Main template validation passed"
    
    # 自动发现并校验相关模板
    local templates=$(discover_templates "$TYPE")
    if [[ -z "$templates" ]]; then
        echo "   ⚠️  No CloudFormation templates found in $SCRIPT_DIR/$TYPE/templates/"
    else
        for template in $templates; do
            local template_path="$SCRIPT_DIR/$TYPE/templates/$template"
            echo "   Validating template: $template"
            if ! aws cloudformation validate-template \
                --template-body "file://$template_path" \
                --region "$AWS_REGION" \
                --profile "$AWS_PROFILE" >/dev/null 2>&1; then
                echo "❌ Error: Template validation failed: $template"
                echo "   Please check the template syntax and fix errors"
                exit 1
            fi
            echo "   ✅ Template validation passed: $template"
        done
    fi
    
    echo "✅ All template validations passed"
}

# =========================================================
# 检查栈状态
# =========================================================
check_stack_status() {
    local stack_name="$1"
    
    if aws cloudformation describe-stacks --stack-name "$stack_name" >/dev/null 2>&1; then
        local status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --query 'Stacks[0].StackStatus' --output text)
        echo "📋 Stack '$stack_name' exists with status: $status"
        
        if [[ "$FORCE" != true ]]; then
            echo "❌ Error: Stack already exists. Use --force to overwrite or choose a different name."
            exit 1
        fi
        
        echo "⚠️  Force mode enabled, will update existing stack"
    else
        echo "✅ Stack '$stack_name' does not exist, will create new stack"
    fi
}

# =========================================================
# 执行部署
# =========================================================
deploy_pipeline() {
    case $TYPE in
        infra) echo "🚀 Deploying Infrastructure Pipeline..." ;;
        boot)  echo "🚀 Deploying Service Bootstrap Pipeline..." ;;
        app)   echo "🚀 Deploying Application Pipeline..." ;;
    esac
    echo "   Type: $TYPE"
    echo "   Environment: $ENV"
    echo "   Region: $AWS_REGION"
    echo "   Profile: $AWS_PROFILE"
    echo ""
    
    # 参数文件路径
    local parameters_file="$SCRIPT_DIR/$TYPE/parameters/parameters-${ENV}.json"
    
    # 从参数文件获取栈名
    local pipeline_name=$(jq -r '.[] | select(.ParameterKey=="PipelineName") | .ParameterValue' "$parameters_file")
    if [[ -z "$pipeline_name" || "$pipeline_name" == "null" ]]; then
        echo "❌ Error: PipelineName not found in parameters file"
        exit 1
    fi
    
    # 生成栈名
    local stack_name="$pipeline_name-$ENV-pipeline"
    
    # 检查栈状态
    check_stack_status "$stack_name"
    
    # 构建部署命令
    local deploy_cmd="aws cloudformation deploy \\
  --template-file $SCRIPT_DIR/$TYPE/pipeline.yaml \\
  --stack-name $stack_name \\
  --parameter-overrides \\
    \$(jq -r '.[] | \"\\(.ParameterKey)=\\(.ParameterValue)\"' $parameters_file) \\
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \\
  --region $AWS_REGION \\
  --profile $AWS_PROFILE"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "🔍 Dry run mode - deployment command:"
        echo ""
        echo "$deploy_cmd"
        echo ""
        echo "📄 Parameters file content:"
        cat "$parameters_file"
        echo ""
        echo "✅ Dry run completed"
        return 0
    fi
    
    # 执行部署
    echo "📦 Executing deployment..."
    echo ""
    
    if eval "$deploy_cmd"; then
        echo ""
        case $TYPE in
            infra) echo "✅ Infrastructure Pipeline deployed successfully!" ;;
            boot)  echo "✅ Service Bootstrap Pipeline deployed successfully!" ;;
            app)   echo "✅ Application Pipeline deployed successfully!" ;;
        esac
        echo ""
        echo "📋 Next steps:"
        echo "   1. Check the pipeline in AWS Console:"
        echo "      https://$AWS_REGION.console.aws.amazon.com/codesuite/codepipeline/pipelines/$pipeline_name"
        echo ""
        if [[ "$TYPE" == "boot" ]]; then
            echo "   2. Run the pipeline manually with variables:"
            echo "      - Service: your-service-name (e.g., demo-api)"
            echo "      - Env: $ENV"
            echo ""
        fi
        case $TYPE in
            infra) echo "   3. Run Bootstrap Pipeline: ./pipeline-deploy.sh boot $ENV" ;;
            boot)  echo "   3. Run Application Pipeline: ./pipeline-deploy.sh app $ENV" ;;
            app)   echo "   3. Pipeline deployment completed!" ;;
        esac
        echo ""
    else
        echo ""
        echo "❌ Deployment failed!"
        echo "   Check the CloudFormation console for details:"
        echo "   https://$AWS_REGION.console.aws.amazon.com/cloudformation/home?region=$AWS_REGION#/stacks"
        exit 1
    fi
}

# =========================================================
# 主函数
# =========================================================
main() {
    case $TYPE in
        infra)
            echo "🏗️  Infrastructure Pipeline Deployment"
            echo "========================================"
            echo "📝 Environment-level shared infrastructure (VPC, Cloud Map Namespace)"
            ;;
        boot)
            echo "🔧 Service Bootstrap Pipeline Deployment"
            echo "========================================"
            echo "📝 Service-level shared infrastructure (Cloud Map Service, LogGroup, ALB)"
            ;;
        app)
            echo "🚀 Application Pipeline Deployment"
            echo "========================================"
            echo "📝 Application deployment (Task Definition, ECS Service, Target Group, Listener Rule)"
            ;;
    esac
    echo ""
    
    check_environment
    validate_templates
    deploy_pipeline
    
    echo "🎉 All done!"
}

# 执行主函数
main "$@"
