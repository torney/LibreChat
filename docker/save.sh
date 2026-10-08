#!/usr/bin/env bash
# 导出镜像为 tar.gz 文件（用于拷贝到部署服务器后 docker load）
# 用法:
#   ./docker/save.sh                          # 导出 librechat-dev-api:custom -> docker/librechat-dev-api-custom.tar.gz
#   ./docker/save.sh v0.8.8-inner             # 导出其他 TAG
#   ./docker/save.sh custom /tmp/out.tar.gz   # 自定义输出路径
set -euo pipefail

command -v docker >/dev/null 2>&1 || export PATH="$PATH:/snap/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${1:-custom}"
IMAGE="librechat-dev-api:${TAG}"
OUT="${2:-${SCRIPT_DIR}/librechat-dev-api-${TAG}.tar.gz}"

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

docker image inspect "$IMAGE" >/dev/null
SIZE=$(docker image inspect "$IMAGE" --format '{{.Size}}')

echo "==> 导出: ${IMAGE} ($(awk "BEGIN{printf \"%.0f\", ${SIZE}/1024/1024}") MB) -> ${OUT}"
echo "==> 提示: 镜像较大（约 2.5-3.5 GB），gzip 压缩 + 网络盘写入可能需要几分钟"
docker save "${IMAGE}" | gzip > "${OUT}"
echo "==> 完成: ${OUT} ($(du -h "${OUT}" | awk '{print $1}'))"
echo "==> 部署侧导入: docker load -i $(basename "${OUT}")"
