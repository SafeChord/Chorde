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

echo "🧹 Uninstalling $RELEASE_NAME..."
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
