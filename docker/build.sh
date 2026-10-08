#!/usr/bin/env bash
# LibreChat 主应用镜像构建脚本（Git Bash / Linux / macOS / WSL）
# 用法:
#   ./docker/build.sh                          # 使用默认 TAG: librechat-dev-api:custom
#   ./docker/build.sh v0.8.8-inner             # 自定义 TAG: librechat-dev-api:v0.8.8-inner
#   NODE_MAX_OLD_SPACE_SIZE=8192 ./docker/build.sh   # 前端构建内存不足时调大（默认 6144 MB）
set -euo pipefail

# 兼容 WSL/snap 等非登录 shell 下 docker 不在 PATH 的情况
command -v docker >/dev/null 2>&1 || export PATH="$PATH:/snap/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TAG="${1:-custom}"
IMAGE="librechat-dev-api:${TAG}"
NODE_MAX_OLD_SPACE_SIZE="${NODE_MAX_OLD_SPACE_SIZE:-6144}"

# 构建元数据（Settings -> About 显示用；.git 被 .dockerignore 排除，必须显式传入）
# WSL 内读 /mnt/e 的 Windows git 仓库需旁路 dubious-ownership 检查（safe.directory=*），
# linux git 不可用时回退 git.exe（Windows git）
git_in() {
  git -c safe.directory='*' -C "${PROJECT_ROOT}" "$@" 2>/dev/null \
    || git.exe -C "${PROJECT_ROOT}" "$@" 2>/dev/null \
    || true
}
BUILD_COMMIT="$(git_in rev-parse --short HEAD)"
BUILD_BRANCH="$(git_in rev-parse --abbrev-ref HEAD)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -z "$BUILD_COMMIT" ]; then
  echo "==> 警告: 未能读取 git 信息（git/git.exe 均失败），BUILD_COMMIT 将为空"
fi

echo "==> 构建上下文: ${PROJECT_ROOT}"
echo "==> 镜像标签:   ${IMAGE}"
echo "==> 构建元数据: commit=${BUILD_COMMIT:-unknown} branch=${BUILD_BRANCH:-unknown} date=${BUILD_DATE}"
echo "==> NODE_MAX_OLD_SPACE_SIZE: ${NODE_MAX_OLD_SPACE_SIZE} (npm ci + Vite 前端全量构建，首次约需 15-40 分钟)"

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

docker build -f "${SCRIPT_DIR}/Dockerfile" -t "${IMAGE}" \
  --build-arg "NODE_MAX_OLD_SPACE_SIZE=${NODE_MAX_OLD_SPACE_SIZE}" \
  --build-arg "BUILD_COMMIT=${BUILD_COMMIT}" \
  --build-arg "BUILD_BRANCH=${BUILD_BRANCH}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  "${PROJECT_ROOT}"

echo "==> 构建完成: ${IMAGE}"
docker image ls "${IMAGE}"
