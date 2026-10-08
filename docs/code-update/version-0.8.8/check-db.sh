#!/usr/bin/env bash
# 租户索引迁移检查脚本（DRY-RUN，只读，不修改任何数据）
# 用法：
#   ./check-db.sh local   → 检查本机开发库  (mongodb://127.0.0.1:27017/LibreChat)
#   ./check-db.sh deploy  → 检查部署栈库    (mongodb://127.0.0.1:27018/LibreChat, deploy-compose 映射端口)
#
# 说明：
# - dry-run 只列出「将被删除的过时唯一索引」，不做任何修改；输出为空 = 库无需迁移。
# - 前提：仓库已执行 npm install 与 npm run build:packages。
# - 若 dry-run 列出了索引，按 01-数据库结构变更分析.md 第 4.2 节执行正式迁移。
set -euo pipefail

TARGET="${1:-local}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

case "$TARGET" in
  local)  export MONGO_URI="mongodb://127.0.0.1:27017/LibreChat" ;;
  deploy) export MONGO_URI="mongodb://127.0.0.1:27018/LibreChat" ;;
  *) echo "用法: $0 [local|deploy]"; exit 1 ;;
esac

echo "==> 目标库: $MONGO_URI"
echo "==> 执行 tenant-index 迁移 DRY-RUN（只读）"
cd "$ROOT"
npm run migrate:tenant-indexes:dry-run
