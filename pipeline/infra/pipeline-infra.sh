#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Infrastructure Pipeline Deployment Script
# =========================================================
# 一键部署 Infra Pipeline，创建环境级共享基础设施
# 使用方法: ./pipeline-infra.sh [env] [options]
# 示例: ./pipeline-infra.sh dev --dry-run
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
Infrastructure Pipeline Deployment Script

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
    local parameters_file="$SCRIPT_DIR/parameters-${ENV}.json"
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
    echo "🚀 Deploying Infrastructure Pipeline..."
    echo "   Environment: $ENV"
    echo "   Region: $AWS_REGION"
    echo "   Profile: $AWS_PROFILE"
    echo ""
    
    # 参数文件路径
    local parameters_file="$SCRIPT_DIR/parameters-${ENV}.json"
    
    # 从参数文件获取栈名
    local stack_name=$(jq -r '.[] | select(.ParameterKey=="PipelineName") | .ParameterValue' "$parameters_file")
    if [[ -z "$stack_name" || "$stack_name" == "null" ]]; then
        echo "❌ Error: PipelineName not found in parameters file"
        exit 1
    fi
    stack_name="infra-pipeline-${ENV}"
    
    # 检查栈状态
    check_stack_status "$stack_name"
    
    # 构建部署命令
    local deploy_cmd="aws cloudformation deploy \\
  --template-file $SCRIPT_DIR/pipeline-infra.yaml \\
  --stack-name $stack_name \\
  --parameters file://$parameters_file \\
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
        echo "✅ Infrastructure Pipeline deployed successfully!"
        echo ""
        echo "📋 Next steps:"
        echo "   1. Check the pipeline in AWS Console:"
        echo "      https://$AWS_REGION.console.aws.amazon.com/codesuite/codepipeline/pipelines/infra-$ENV"
        echo ""
        echo "   2. Run the pipeline manually or wait for trigger"
        echo ""
        echo "   3. Deploy Bootstrap Pipeline for services:"
        echo "      ./pipeline-boot.sh $ENV"
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
    echo "🏗️  Infrastructure Pipeline Deployment"
    echo "======================================"
    echo ""
    
    check_environment
    deploy_pipeline
    
    echo "🎉 All done!"
}

# 执行主函数
main "$@"