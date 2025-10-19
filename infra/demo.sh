# =========== 参数解析完毕 ===========

# 自动补齐逻辑
case "$1" in
demo-user-rpc)
#  SD_ID="srv-g46enu54fe2bhajk"
  MODULE_PATH="test/demo-user-rpc"
  NAMESPACE_NAME="test.local"
  APP_ENV="test"
  ;;
demo-order-rpc)
#  SD_ID="srv-ws7zs275lhin423j"
  MODULE_PATH="test/demo-order-rpc"
  NAMESPACE_NAME="test.local"
  APP_ENV="test"
  ;;
demo-web-api)
#  SD_ID="srv-no4yq2jsnaitk7x2"
  MODULE_PATH="test/demo-web-api"
  NAMESPACE_NAME="test.local"
  APP_ENV="test"
  ;;
esac

sh $(dirname "$0")/pipeline.sh \
  --repo nianien/infra-experimental \
  --branch master \
  --module "$MODULE_PATH" \
  --namespace "$NAMESPACE_NAME" \
  --env "$APP_ENV" \
  --service "$1"
