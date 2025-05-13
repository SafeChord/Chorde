#!/bin/bash
set -e

# 載入共用變數
if [ -f .env ]; then
  source .env
else
  echo "❌ 找不到 .env 檔案"
  exit 1
fi

RELEASE_NAME=$1
if [ -z "$RELEASE_NAME" ]; then
  echo "Usage: $0 <release-name> (例如 ingress-public)"
  exit 1
fi

VALUES_FILE="$RELEASE_NAME/values-custom.yaml"
if [ ! -f "$VALUES_FILE" ]; then
  echo "❌ $VALUES_FILE 不存在，請確認資料夾結構"
  exit 1
fi

echo "🚀 Installing or upgrading $RELEASE_NAME..."

helm upgrade --install "$RELEASE_NAME" "$CHART_NAME" \
  --version "$CHART_VERSION" \
  -n "$NAMESPACE" \
  --create-namespace \
  -f values.yaml \
  -f "$VALUES_FILE"