# LibreChat 主应用 — Docker 打包说明

本目录用于把 **基于官方源码更新的 LibreChat 主应用**（当前工作区 `LibreChat/`，版本 v0.8.8-rc4）打包为自定义 Docker 镜像，
替代官方镜像 `registry.librechat.ai/librechat-ai/librechat-dev-api:latest`，
供 `deploy-compose.yml` 中的 `api` 服务使用（admin-panel 后台面板的打包见 `../LibreChat-admin-panel/docker/`）。

## 目录内容

| 文件 | 用途 |
| --- | --- |
| `Dockerfile` | 镜像构建文件（与项目根目录官方 Dockerfile 构建逻辑一致，仅加注释） |
| `build.sh` | 构建脚本（Git Bash / Linux / WSL，内置守护进程就绪等待、自动填充 git 构建元数据） |
| `build.bat` | 构建脚本（Windows CMD，适用于装有 docker.exe 的机器） |
| `docker-compose.custom.yml` | 本地构建 + 最小依赖（api + mongodb）验证用 compose |
| `verify.sh` | 镜像验证脚本：临时 mongo + 临时容器 → 轮询 `/health` → 自动清理 |
| `save.sh` | 镜像导出脚本：`docker save \| gzip` 生成 tar.gz 文件 |
| `his_images/` | 历史导出镜像归档目录（新导出的 tar.gz 放本目录，旧的移入此处） |
| `librechat-dev-api-custom.tar.gz` | 导出的镜像文件（1.1 GB，部署服务器 `docker load` 导入） |
| `README.md` | 本文档 |
| `RUN_NOTE.txt` | 日常更新操作速查（同 admin-panel docker 目录的 RUN_NOTE.txt 风格） |

## 打包范围：哪些内容进了镜像，哪些没有

**进镜像（构建期 `COPY . .` 带入，受根目录 `.dockerignore` 约束）**：

- 全部源码：`api/`、`client/`、`packages/`、`config/`、`skill/`（镜像内初始副本）、`api/app/` 客户端静态资源等
- 构建期编译产物：`packages/*` 各包 dist + `client/dist`（Vite 前端，由 `npm run frontend` 完成）
- 运行时系统组件：Node 24.16.0-alpine、jemalloc 内存分配器、Python3 + uv 0.9.5（MCP 扩展支持）

**不进镜像（运行期挂载/注入，`.dockerignore` 明确排除或 deploy-compose 以 volume/env 提供）**：

| 内容 | 提供方式 |
| --- | --- |
| `librechat.yaml`（内网大模型端点配置） | bind mount → `/app/librechat.yaml` |
| `.env`（MONGO_URI、DOMAIN_* 等） | `env_file: .env` + `environment:` 覆盖 |
| `skill/`（技能目录，会持续更新） | bind mount → `/app/skill` |
| 上传文件/图片/日志 | bind mount `./uploads`、`./images`、`./logs` |
| 自动生成的 JWT/CREDS 密钥 | `librechat-data` 卷 → `/app/data/.env.temp` |
| `.git`（被 `.dockerignore` 排除） | 版本信息只能靠构建参数 `BUILD_COMMIT` 等传入 |

> 因此：**改源码 → 必须重新构建镜像**；改 `librechat.yaml` / `.env` / `skill/` → 只需重启容器（`docker compose -f deploy-compose.yml up -d api` 或 `restart`），无需重打包。

## 镜像结构

- **应用形态**：单容器全栈。Node API 监听 3080 端口，同时提供 `/api/*` 接口与 `client/dist` 前端静态资源（`npm run backend` = `NODE_ENV=production node api/server/index.js`）
- **基础镜像**：`node:24.16.0-alpine`，非 root 用户 `node` 运行
- **构建流程**（单阶段多步骤，层缓存友好）：
  1. 先只 COPY 各 `package.json` → `npm ci --no-audit`（带 2 次重试、单次 1500s 超时，抗网络抖动）
  2. `COPY . .` → `npm run frontend`（依次构建 data-provider / data-schemas / api / client 包 + Vite 客户端，默认 6144 MB Node 堆内存）
  3. `npm prune --production` 剥离 devDependencies
- **端口**：容器内 3080（`HOST=0.0.0.0` 已内置）
- **健康检查**：API 自带 `GET /health`（返回 200 `OK`）；启动为 fail-fast——Mongo 连不上、启动自检失败会直接退出进程，靠编排器重启。deploy-compose 未配置 Docker HEALTHCHECK，需要时可在 compose 里补
- **版本元数据**：`BUILD_COMMIT` / `BUILD_BRANCH` / `BUILD_DATE` 构建参数写入镜像环境变量，`build.sh` 自动从 git 填充（`.git` 不进镜像，不传则 Settings → About 无版本信息）
- 镜像体积较大（未压缩约 2.5~3.5 GB，主要是生产 node_modules + 前端产物），导出 gzip 后一般 1 GB 左右

## 构建镜像

> **构建上下文必须是项目根目录**（Dockerfile 在 `docker/` 下但 `COPY` 的是根目录内容）。

```bash
# 方式一：脚本（在项目根目录执行）
./docker/build.sh                      # 默认 TAG: librechat-dev-api:custom
./docker/build.sh v0.8.8-inner         # TAG: librechat-dev-api:v0.8.8-inner

# Windows CMD
docker\build.bat

# 方式二：原始命令（在项目根目录执行）
docker build -f docker/Dockerfile -t librechat-dev-api:custom .

# 方式三：通过 compose 构建（同时可本地起服务验证）
docker compose -f docker/docker-compose.custom.yml build
```

首次构建需完整 `npm ci` + 前端构建，约 15~40 分钟；之后源码未变时层缓存命中，仅重新 COPY + 前端构建。
**注意**：改了 `package.json` / `package-lock.json` 会击穿依赖层缓存，回到完整 `npm ci`。

## 环境变量

### 构建期（build-arg）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `NODE_MAX_OLD_SPACE_SIZE` | `6144` | 前端 Vite 构建 Node 堆内存上限（MB）。构建机内存不足 OOM 时调大，如 `8192` |
| `NPM_CI_TIMEOUT_SECONDS` | `1500` | 单次 `npm ci` 超时 |
| `NPM_CI_ATTEMPTS` | `2` | `npm ci` 失败重试次数 |
| `BUILD_COMMIT` / `BUILD_BRANCH` / `BUILD_DATE` | 空 | 版本元数据，Settings → About 展示。`build.sh` 自动填充 |

### 运行期（由 deploy-compose.yml 从项目 `.env` 注入）

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `MONGO_URI` | 是 | deploy-compose 中已写死 `mongodb://mongodb:27017/LibreChat`，指向 compose 内 mongodb 服务 |
| `LIBRECHAT_TEMP_CREDENTIALS_PATH` | 建议 | `/app/data/.env.temp`。`JWT_SECRET`/`CREDS_KEY`/`CREDS_IV` 留空时自动生成并持久化到该路径（`librechat-data` 卷）。**卷丢了 = 密钥重生成 = 已保存的供应商凭据解不开、登录态全部失效** |
| `SEARCH` | 否 | `false` 关闭 MeiliSearch（当前内网部署为关闭） |
| `RAG_API_URL` | 否 | 指向 rag_api 服务，文件检索/RAG 用 |
| `ADMIN_PANEL_URL` | 否 | `http://admin.localhost`，OAuth 管理端回跳用 |
| `HOST` / `NODE_ENV` | 否 | 镜像/compose 已设 `0.0.0.0` / `production` |

## 与 deploy-compose.yml 集成

deploy-compose.yml 中 api 服务当前使用官方镜像（附近还留着一段注释掉的 build 配置，可忽略）：

```yaml
  api:
    image: registry.librechat.ai/librechat-ai/librechat-dev-api:latest
```

替换为本地构建的镜像（**只改 image 这一行**，其余保持不变）：

```yaml
  api:
    image: librechat-dev-api:custom          # ← 只改这一行
    container_name: LibreChat-API
    ports:
      - 3080:3080
    depends_on: [mongodb, rag_api]
    # ... volumes/env 其余配置不动（librechat.yaml、skill、uploads、data 卷照旧挂载）
```

然后在 LibreChat 项目根目录：

```bash
docker compose -f deploy-compose.yml up -d api    # 用新镜像重建 api 容器
```

### 流量路径（deploy-compose 架构）

```
浏览器 ──> client(nginx :80)
             ├── server_name localhost       ──> http://api:3080          （主站，即本镜像）
             └── server_name admin.localhost ──> http://admin-panel:3000  （后台管理，独立镜像）
api ──> mongodb(mongo:8.0.20) / meilisearch(搜索，当前关闭) / rag_api + vectordb(检索)
```

nginx 配置在 `client/nginx.conf`（bind mount 进 client 容器）。

## 与离线发布包（06.发布）的关系

现有离线发布包 `06.发布/01.原生images/librechat/` 使用**官方原生镜像**：
`docker/librechat-api.tar` 即 `ghcr.io/danny-avila/librechat-dev:latest`（通过
`docker-compose.override.yml` 把 deploy-compose 的 api 镜像改写到 ghcr 源），其余 mongo / meilisearch /
pgvector / rag-api / admin-panel 各 tar 均为官方镜像，配套 `DEPLOY.md` 有完整离线部署步骤。

本目录构建的 `librechat-dev-api:custom` 是**替代其中 api 一个服务**的自定义镜像：

- 部署服务器上 `docker load -i librechat-dev-api-custom.tar.gz` 后，把 api 服务的 image 改为
  `librechat-dev-api:custom`（直接改 `deploy-compose.yml`，或在 override 文件里改写均可）
- 其余 5 个镜像 tar **不用重新导出**，`mongo.tar` 等与本地构建验证用的是同一份（mongo:8.0.20）
- 本机验证镜像时无需联网拉 mongo：先 `docker load` 发布包里的 `mongo.tar`（verify.sh 默认标签即
  `mongo:8.0.20`，可用 `MONGO_IMAGE` 环境变量覆盖）

### 内网大模型端点

`librechat.yaml`（bind mount，不进镜像）定义 custom endpoint `inner-llm`：
`baseURL: http://10.25.34.211:8100/v1`，模型 `glm-52` / `Qwen3.5-122B`，标题模型 `glm-52`。
修改该文件后 `docker compose -f deploy-compose.yml restart api` 即生效，无需重新打包。

## 本地验证

```bash
# 方式一：一键验证（临时 mongo + 临时容器，隔离网络，测完自动清理，不碰现有数据）
./docker/verify.sh                        # 默认验证 librechat-dev-api:custom
./docker/verify.sh v0.8.8-inner           # 验证其他 TAG
# 期望输出: "==> 验证通过: /health 返回 OK"

# 方式二：compose 起最小栈（api + mongodb，挂真实 librechat.yaml）
docker compose -f docker/docker-compose.custom.yml up -d --build
curl http://localhost:13080/health        # 期望: OK
docker compose -f docker/docker-compose.custom.yml down   # 验证完清理
```

> 手动快速验证（等价于 verify.sh 做的事）：
> ```bash
> docker network create tmpnet
> docker run -d --name tmpmongo --network tmpnet mongo:8.0.20 mongod --noauth
> docker run -d --rm --name tmpapi --network tmpnet -p 13080:3080 \
>   -e MONGO_URI=mongodb://tmpmongo:27017/LibreChat \
>   -e LIBRECHAT_TEMP_CREDENTIALS_PATH=/app/data/.env.temp \
>   librechat-dev-api:custom
> curl http://localhost:13080/health      # 期望: OK
> docker rm -f tmpapi tmpmongo && docker network rm tmpnet
> ```

## 本机构建方式（WSL snap docker，重要）

本机（Windows）**没有安装 docker.exe**，Docker 以 snap 包形式运行在 `WSL Ubuntu-26.04` 内
（守护进程 `snap.docker.dockerd`，root 方式访问）。本机构建/验证统一通过 `wsl` 调用：

```bash
# Git Bash（需要 MSYS_NO_PATHCONV=1 防止 /mnt/e 路径被改写）
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-26.04 -u root -- \
  bash /mnt/e/Work/WXZX-2026/SVN/Agents-Projects/Branchs/DEV_20260924_nsmc_inner_agent/02.code/02.inner_agent_web/agent_web_project/LibreChat/docker/build.sh

# 验证镜像（临时 mongo + 临时容器测 /health 后自动清理）
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-26.04 -u root -- \
  bash /mnt/e/Work/WXZX-2026/SVN/Agents-Projects/Branchs/DEV_20260924_nsmc_inner_agent/02.code/02.inner_agent_web/agent_web_project/LibreChat/docker/verify.sh

# 导出镜像为 tar.gz（默认输出到本 docker/ 目录，用于部署服务器 docker load）
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-26.04 -u root -- \
  bash /mnt/e/Work/WXZX-2026/SVN/Agents-Projects/Branchs/DEV_20260924_nsmc_inner_agent/02.code/02.inner_agent_web/agent_web_project/LibreChat/docker/save.sh
```

**WSL 空闲自动关机的坑**：WSL 发行版空闲约 1 分钟后会自动关闭，下一次 `wsl` 调用时冷启动、
snap docker 守护进程需要几秒到几十秒才能就绪。期间执行 docker 命令会报
`cannot preserve mount namespace` 或 `failed to connect to the docker API`。
`build.sh` / `verify.sh` / `save.sh` 已内置最长 90 秒的就绪等待；单独敲 docker 命令时遇到上述报错，
等待几秒重试即可。

**/mnt/e 路径构建慢的坑**：构建上下文在 Windows 盘（9P 文件系统）上时，`npm ci` 与构建上下文传输都明显偏慢，
属正常现象；librechat 源码树较大（含大量小文件），耐心等待或先将工作区拷到 WSL 本地盘再构建。

## 构建记录

- **2026-09-29**：首次打包并构建成功。源码基线：分支 `dev_260928`（= upstream/main，commit `c8c5478cf`，
  v0.8.8-rc4，agents SDK v3.9.7）。环境：WSL Ubuntu-26.04 / Docker 29.8.0（snap）。
  - 首次全量构建约 20 分钟：`npm ci` 3003 包 4 min → Vite 前端 9730 模块 + PWA 54 项预缓存 →
    `npm prune --production` 后剩 1828 个生产包
  - 版本元数据已写入镜像：`BUILD_COMMIT=c8c5478cf`、`BUILD_BRANCH=dev_260928`、
    `BUILD_DATE=2026-09-29T08:59:17Z`（build.sh 内置 `/mnt/e` Windows git 仓库的 safe.directory
    旁路 + git.exe 回退；首次构建曾因 WSL 内 git dubious-ownership 检查导致 commit 为空，已修复重建）
  - 镜像体积：未压缩 4.69 GB（docker content size 1.1 GB）
  - 验证：verify.sh 通过——临时 `mongo:8.0.20`（离线 `docker load` 自
    `06.发布/01.原生images/librechat/docker/mongo.tar`，未联网拉取）+ 临时容器，
    `/health` 返回 OK，日志出现 "Server listening on all interfaces at port 3080"
  - 导出：`docker/librechat-dev-api-custom.tar.gz`（gzip 后 1.1 GB），
    部署侧 `docker load -i librechat-dev-api-custom.tar.gz` 导入

## 常见问题

- **容器启动即退出**：API 为 fail-fast 设计。`docker logs LibreChat-API` 排查：多数是 Mongo 连不上
  （mongodb 服务未起 / MONGO_URI 错误）或配置文件校验失败（librechat.yaml 语法错误）。
- **构建时前端 OOM / killed**：`NODE_MAX_OLD_SPACE_SIZE=8192 ./docker/build.sh`。
- **`npm ci` 网络失败**：Dockerfile 已带 2 次重试；仍失败时为 docker 配置 HTTP(S) proxy 或 registry mirror，
  或在能联网的机器上构建后 `save.sh` 导出再导入。
- **Settings → About 没有版本号**：`.git` 不进镜像；用 `build.sh` 构建即可（已内置 WSL 下读
  `/mnt/e` Windows git 仓库的 safe.directory 旁路与 git.exe 回退，自动传 `BUILD_COMMIT` 等参数）。
- **部署主机上找不到镜像**：`librechat-dev-api:custom` 是本地标签。离线部署走 `save.sh` 导出 tar.gz，
  服务器上 `docker load -i librechat-dev-api-custom.tar.gz` 导入，compose 再引用同名标签；
  走私有 registry 则构建时直接打完整前缀标签（如 `docker tag librechat-dev-api:custom <registry>/librechat-dev-api:custom`）。
- **改了代码如何更新到部署服务器**（完整流程见 RUN_NOTE.txt）：
  本机 `build.sh` → `verify.sh` → `save.sh` → 拷贝 tar.gz 到服务器 → `docker load` →
  `docker compose -f deploy-compose.yml up -d api` 重建容器。
- **`package-lock.json` 在 Windows 上出现 `libc` 字段删除的 diff**：npm 在 Windows 上会规范化平台可选依赖，
  属平台漂移，不影响 Linux 容器内 `npm ci`，无需特殊处理。

## 与官方镜像的差异

`docker/Dockerfile` 与项目根目录官方 Dockerfile 构建逻辑**完全一致**，差异仅来自
**构建时工作区源码相对官方发布镜像的状态**（当前已同步 upstream/main `c8c5478cf`，可能领先于
registry 上的 `librechat-dev-api:latest`），以及 `BUILD_COMMIT` 等构建元数据。
若根目录 Dockerfile 后续升级，请同步更新本目录副本以保持一致。
