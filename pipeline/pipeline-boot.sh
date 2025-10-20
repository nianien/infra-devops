#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Service Bootstrap Pipeline Deployment Script
# =========================================================
# 一键部署 Bootstrap Pipeline，创建服务级共享基础设施
# 使用方法: ./pipeline-boot.sh [env] [options]
# 示例: ./pipeline-boot.sh dev --dry-run
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
# 帮助信息
# =========================================================
show_help() {
    cat << EOF
Service Bootstrap Pipeline Deployment Script

USAGE:
    $0 [ENV] [OPTIONS]

ARGUMENTS:
    ENV                 Environment name (dev|test|preonline|online)
                        Default: dev

OPTIONS:
    --dry-run           Show deployment command without executing
    --force             Force deployment even if stack exists
    --help, -h          Show this help message

PARAMETERS FILE:
    The script uses parameters-{ENV}.json file for deployment parameters.
    Create this file manually or let the script generate it.

EXAMPLES:
    # Deploy to dev environment
    $0 dev
    
    # Deploy to test environment with dry run
    $0 test --dry-run
    
    # Force deployment
    $0 dev --force

EOF
}

# =========================================================
# 参数解析
# =========================================================
ENV="${1:-dev}"
DRY_RUN=false
FORCE=false

# 解析命令行参数
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
    local parameters_file="$SCRIPT_DIR/boot/parameters-${ENV}.json"
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
    local main_template="$SCRIPT_DIR/boot/pipeline.yaml"
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
    
    # 校验 Bootstrap 模板
    local sd_template="$SCRIPT_DIR/../ci/boot-sd-stack.yaml"
    if [[ -f "$sd_template" ]]; then
        echo "   Validating Service Discovery template: boot-sd-stack.yaml"
        if ! aws cloudformation validate-template \
            --template-body "file://$sd_template" \
            --region "$AWS_REGION" \
            --profile "$AWS_PROFILE" >/dev/null 2>&1; then
            echo "❌ Error: Service Discovery template validation failed"
            echo "   Please check the template syntax and fix errors"
            exit 1
        fi
        echo "   ✅ Service Discovery template validation passed"
    else
        echo "   ⚠️  Service Discovery template not found: $sd_template"
    fi
    
    # 校验 Log 模板
    local log_template="$SCRIPT_DIR/../ci/boot-log-stack.yaml"
    if [[ -f "$log_template" ]]; then
        echo "   Validating Log template: boot-log-stack.yaml"
        if ! aws cloudformation validate-template \
            --template-body "file://$log_template" \
            --region "$AWS_REGION" \
            --profile "$AWS_PROFILE" >/dev/null 2>&1; then
            echo "❌ Error: Log template validation failed"
            echo "   Please check the template syntax and fix errors"
            exit 1
        fi
        echo "   ✅ Log template validation passed"
    else
        echo "   ⚠️  Log template not found: $log_template"
    fi
    
    # 校验 ALB 模板
    local alb_template="$SCRIPT_DIR/../ci/boot-alb-stack.yaml"
    if [[ -f "$alb_template" ]]; then
        echo "   Validating ALB template: boot-alb-stack.yaml"
        if ! aws cloudformation validate-template \
            --template-body "file://$alb_template" \
            --region "$AWS_REGION" \
            --profile "$AWS_PROFILE" >/dev/null 2>&1; then
            echo "❌ Error: ALB template validation failed"
            echo "   Please check the template syntax and fix errors"
            exit 1
        fi
        echo "   ✅ ALB template validation passed"
    else
        echo "   ⚠️  ALB template not found: $alb_template"
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
    echo "🚀 Deploying Service Bootstrap Pipeline..."
    echo "   Environment: $ENV"
    echo "   Region: $AWS_REGION"
    echo "   Profile: $AWS_PROFILE"
    echo ""
    
    # 参数文件路径
    local parameters_file="$SCRIPT_DIR/boot/parameters-${ENV}.json"
    
    # 从参数文件获取栈名
    local pipeline_name=$(jq -r '.[] | select(.ParameterKey=="PipelineName") | .ParameterValue' "$parameters_file")
    if [[ -z "$pipeline_name" || "$pipeline_name" == "null" ]]; then
        echo "❌ Error: PipelineName not found in parameters file"
        exit 1
    fi
    local stack_name="boot-pipeline-${ENV}"
    
    # 检查栈状态
    check_stack_status "$stack_name"
    
    # 构建部署命令
    local deploy_cmd="aws cloudformation deploy \\
  --template-file $SCRIPT_DIR/boot/pipeline.yaml \\
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
        echo "✅ Service Bootstrap Pipeline deployed successfully!"
        echo ""
        echo "📋 Next steps:"
        echo "   1. Check the pipeline in AWS Console:"
        echo "      https://$AWS_REGION.console.aws.amazon.com/codesuite/codepipeline/pipelines/$pipeline_name"
        echo ""
        echo "   2. Run the pipeline manually with variables:"
        echo "      - Service: your-service-name (e.g., demo-api)"
        echo "      - Env: $ENV"
        echo ""
        echo "   3. Deploy Application Pipeline for services:"
        echo "      ./pipeline-app.sh $ENV"
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
    echo "🔧 Service Bootstrap Pipeline Deployment"
    echo "========================================"
    echo ""
    
    check_environment
    validate_templates
    deploy_pipeline
    
    echo "🎉 All done!"
}

# 执行主函数
main "$@"

