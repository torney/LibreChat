#!/usr/bin/env bash
# 镜像运行验证：临时 mongo + 临时 api 容器 -> 轮询 /health -> 输出结果 -> 清理
# 用法:
#   ./docker/verify.sh                        # 验证默认镜像 librechat-dev-api:custom
#   ./docker/verify.sh v0.8.8-inner           # 验证其他 TAG
#   VERIFY_PORT=13080 ./docker/verify.sh      # 指定宿主机端口
#
# 说明:
#   - API 启动 fail-fast：连不上 MongoDB 会直接退出，所以必须先起一个临时 mongo（8.0.20，
#     与 deploy-compose.yml 一致），通过隔离 docker 网络互联，验证完自动清理，不碰任何现有数据。
#   - /health 返回 200 "OK" 即通过（该端点在 Mongo 连接、启动自检完成后才会应答）。
#   - JWT/CREDS 密钥无需提供：留空时自动生成并写入 LIBRECHAT_TEMP_CREDENTIALS_PATH 指向的
#     /app/data/.env.temp（容器内可写，验证容器即弃，不落盘到宿主机）。
set -euo pipefail

command -v docker >/dev/null 2>&1 || export PATH="$PATH:/snap/bin:/usr/local/bin"

TAG="${1:-custom}"
IMAGE="librechat-dev-api:${TAG}"
NET="librechat-verify-net"
MONGO="librechat-verify-mongo"
API="librechat-verify-api"
PORT="${VERIFY_PORT:-13080}"
# 临时 mongo 镜像：默认与 deploy-compose.yml 一致。
# 离线机器可先 docker load 发布包里的 mongo.tar（06.发布/01.原生images/librechat/docker/mongo.tar），标签即 mongo:8.0.20。
MONGO_IMAGE="${MONGO_IMAGE:-mongo:8.0.20}"

# 等待守护进程就绪（WSL 冷启动 / 服务自启场景最长约 90 秒）
echo "==> 等待 docker 守护进程就绪..."
ready=""
for i in $(seq 1 90); do
  if docker info >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "==> 错误: docker 守护进程 90 秒内未就绪"
  exit 1
fi

cleanup() {
  docker rm -f "$API" "$MONGO" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker network create "$NET" >/dev/null
docker run -d --rm --name "$MONGO" --network "$NET" "$MONGO_IMAGE" mongod --noauth >/dev/null
echo "==> 临时 mongo 已启动: ${MONGO}（等待 10 秒初始化）"
sleep 10

docker run -d --rm --name "$API" --network "$NET" -p "${PORT}:3080" \
  -e HOST=0.0.0.0 \
  -e MONGO_URI="mongodb://${MONGO}:27017/LibreChat" \
  -e LIBRECHAT_TEMP_CREDENTIALS_PATH=/app/data/.env.temp \
  -e SEARCH=false \
  "$IMAGE" >/dev/null

echo "==> 镜像: ${IMAGE}  容器: ${API}  端口: ${PORT} -> 3080"
# LibreChat 启动（npm run backend -> 连接 Mongo -> 启动自检 -> 监听）最长约 2 分钟
for i in $(seq 1 120); do
  if curl -fsS "http://localhost:${PORT}/health" 2>/dev/null | grep -q '^OK$'; then
    echo "==> 验证通过: /health 返回 OK"
    docker logs "$API" 2>&1 | tail -5 || true
    exit 0
  fi
  # 容器中途退出则提前失败
  if [ "$(docker inspect --format '{{.State.Running}}' "$API" 2>/dev/null)" = "false" ]; then
    echo "==> 验证失败: 容器已退出，日志如下:"
    docker logs "$API" 2>&1 | tail -40 || true
    exit 1
  fi
  sleep 1
done

echo "==> 验证失败: /health 120 秒内未就绪，容器日志如下:"
docker logs "$API" 2>&1 | tail -40 || true
exit 1
