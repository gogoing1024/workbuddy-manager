#!/usr/bin/env bash
# 在本地 Linux/WSL 执行，使用 SSH + rsync 将 workbuddy-manager 部署到 VPS。
#
# Windows: wsl -e bash /mnt/d/GolandProjects/workbuddy-manager/deploy-to-vps.sh
#
# 完全自包含：管理端与上游 workbuddy2api 都由本脚本部署，不依赖机器上已有的
# 任何 workbuddy 部署。上游源码取自 Release 包内自带的 upstream/ 快照
# （上游原仓库已被作者删除，源码随发布包分发），源码与已构建的前端一起从
# Release 包取得，因此无需 Node.js 参与构建。
#
# 两种模式：
#   · 默认      从 GitHub Release 下载并验签 —— 正式发布流程，管理端与上游一起部署
#   · --local   上传本地工作区、在 VPS 上构建 —— 自定义改造开发用，只换管理端代码
#               （上游源码不在本仓库，故只确保其容器在运行；跳过签名校验，因为改的
#               就是你自己的代码。镜像 tag 取 git 描述，便于分辨每次改动）
#
# 产物布局：
#   /opt/workbuddy2api           上游（独立 compose 项目，容器 workbuddy2api）
#   /opt/workbuddy-manager       管理端根目录
#     ├── data/                  持久化数据（数据库、用户、审计、更新状态）
#     └── releases/<时间戳>/     每次部署的源码，current 符号链接指向其一
# 镜像：workbuddy-manager:<Release 版本>（如 1.0.72），版本取自发布包的 .version
#
# 可重复执行：再次运行会新建一份 releases/<时间戳>，由 compose 重建两个容器
# （旧容器同属本项目，端口自动交接，无需先手工删除），失败时回滚到 current
# 指向的上一版。上游的 config.json / auths / data 与管理端的 data/ 全程原样保留。

set -euo pipefail

VPS_HOST="${VPS_HOST:-98.142.250.143}"
VPS_USER="${VPS_USER:-root}"
VPS_PORT="${VPS_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-/opt/workbuddy-manager}"
# 旧发布目录保留份数（含 current 指向的那份）：每次成功部署后清理多余的，
# 使 releases/ 不无限增长，同时保住回滚深度（3 = 当前 + 2 个旧版）。
KEEP_RELEASES=3
# 上游目录。**必须是 /opt/workbuddy2api**：管理端容器把宿主该目录挂到同名容器
# 路径，容器内执行 `docker compose up -d --build` 重建上游时，compose 会把
# 容器内的相对卷路径当作宿主路径解析——两者不同名时上游的 auths/data 卷会挂空。
UPSTREAM_DIR="${UPSTREAM_DIR:-/opt/workbuddy2api}"
UPSTREAM_CONTAINER="${UPSTREAM_CONTAINER:-workbuddy2api}"
# 上游端口固定 7863，**不可配置**：上游 compose 的端口映射与容器内监听都是
# 7863（第 3 步的 sed 也只认这个字面量），改成别的值必然连不上上游。它从来
# 不是一个能用的开关，故直接写死，不再从环境变量读取。
UPSTREAM_PORT=7863
MANAGER_REPO="${MANAGER_REPO:-ithtelab/workbuddy-manager}"
# Release 版本：latest 取最新发布，也可指定如 v1.0.71
RELEASE_VERSION="${RELEASE_VERSION:-latest}"
BIND_IP="${BIND_IP:-0.0.0.0}"
APP_PORT="${APP_PORT:-7864}"
# 置 1 跳过 Release 包签名校验（仅用于维护者换签名密钥等紧急情况）
SKIP_VERIFY="${SKIP_VERIFY:-0}"
# 仅 --local 有效：是否上传本地已构建的 web/out。默认 0 —— 前端在容器内用上传的
# 源码构建，这样"改了前端源码却部署了旧产物"不可能发生。本地已构建好、只想快点
# 部署时设 1（此时必须自己保证 web/out 是最新的）。
LOCAL_WEB_OUT="${LOCAL_WEB_OUT:-0}"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'HELP'
用法: ./deploy-to-vps.sh [--local]

  （无参数）从 GitHub Release 下载并验签后部署，走正式发布流程。
  --local   上传本地工作区、在 VPS 上构建镜像，用于自定义改造开发。
            跳过 Release 下载与签名校验；上游不同步源码也不重建镜像，只确保其
            容器在运行（首次安装上游仍需先跑一次正式部署）。
            镜像 tag 取 git 描述（如 workbuddy-manager:local-v1.0.72）。

在本地 Linux/WSL 执行。需要 ssh、rsync、python3；VPS 需要 root SSH、
Docker Engine 和 Docker Compose 插件（v2+）。

可通过环境变量设置 VPS_HOST、VPS_USER、VPS_PORT、REMOTE_DIR、UPSTREAM_DIR、
UPSTREAM_CONTAINER、MANAGER_REPO、RELEASE_VERSION、BIND_IP、APP_PORT、SKIP_VERIFY。
--local 下还有 LOCAL_WEB_OUT（置 1 则复用本地已构建的 web/out，跳过容器内构建；
默认 0 表示前端在容器内用上传的源码构建，改动必然生效）。

默认部署上游到 /opt/workbuddy2api、管理端到 /opt/workbuddy-manager，
服务监听 0.0.0.0:7864，即 http://<VPS_IP>:7864 可直接访问。

可重复执行：再次运行会新建一份发布目录并重建两个容器（旧容器同属本项目，
端口自动交接，无需先手工清理），失败时自动回滚到上一版；数据与上游凭据保留。
旧发布目录自动清理，保留最近 3 份（含 current 指向的那份）。
管理端镜像按 Release 版本打 tag（如 workbuddy-manager:1.0.72），便于 docker images 追溯。

**安全提醒**：管理端持有全部账号凭据与上游 api_key。直接暴露到公网时，
务必先设置强管理员密码，并尽快在反向代理后加 HTTPS（否则登录密码与
会话 Cookie 明文过网）。只想本机访问就设 BIND_IP=127.0.0.1。
HELP
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
LOCAL_MODE=0
if [ "${1:-}" = "--local" ]; then
    LOCAL_MODE=1
    shift
fi
if [ "$#" -ne 0 ]; then
    usage >&2
    exit 2
fi

for dependency in ssh rsync python3; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "缺少本地依赖: $dependency" >&2
        exit 1
    fi
done
if [ ! -f "$LOCAL_DIR/compose.vps.yaml" ]; then
    echo "本地项目文件不完整: $LOCAL_DIR/compose.vps.yaml" >&2
    exit 1
fi

if [[ ! "$VPS_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$VPS_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] \
   || [[ ! "$REMOTE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ ! "$UPSTREAM_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] \
   || [[ ! "$UPSTREAM_CONTAINER" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$MANAGER_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
   || [[ ! "$RELEASE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "VPS_HOST、VPS_USER、REMOTE_DIR、UPSTREAM_DIR、UPSTREAM_CONTAINER、MANAGER_REPO 或 RELEASE_VERSION 格式不正确" >&2
    exit 1
fi
for value in "$VPS_PORT" "$APP_PORT"; do
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "VPS_PORT 和 APP_PORT 必须是数字" >&2
        exit 1
    fi
done
for value in "$VPS_PORT" "$APP_PORT"; do
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        echo "端口必须在 1-65535 之间" >&2
        exit 1
    fi
done
if [ "$APP_PORT" = "$UPSTREAM_PORT" ]; then
    echo "APP_PORT 与 UPSTREAM_PORT 不能相同" >&2
    exit 1
fi
# 上游目录必须是官方默认路径，理由见文件头注释
if [ "$UPSTREAM_DIR" != "/opt/workbuddy2api" ]; then
    echo "UPSTREAM_DIR 必须是 /opt/workbuddy2api（容器内外路径需同名，否则上游卷会挂空）" >&2
    exit 1
fi
python3 - "$BIND_IP" "$REMOTE_DIR" "$UPSTREAM_DIR" <<'PY'
import ipaddress
import posixpath
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
except ipaddress.AddressValueError:
    sys.exit("BIND_IP 必须是 IPv4 地址")
for label, path in (("REMOTE_DIR", sys.argv[2]), ("UPSTREAM_DIR", sys.argv[3])):
    if path == "/" or posixpath.normpath(path) != path:
        sys.exit(f"{label} 必须是规范化的非根目录绝对路径")
if posixpath.normpath(sys.argv[2]) == posixpath.normpath(sys.argv[3]):
    sys.exit("REMOTE_DIR 不能与 UPSTREAM_DIR 相同")
PY

SSH_OPTS=(-o ControlMaster=auto -o ControlPath=/tmp/workbuddy-manager-ssh-%C -o ControlPersist=600)
cleanup() {
    ssh "${SSH_OPTS[@]}" -p "$VPS_PORT" -O exit "$VPS_USER@$VPS_HOST" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh_exec() {
    ssh "${SSH_OPTS[@]}" -p "$VPS_PORT" "$VPS_USER@$VPS_HOST" "$@"
}

rsync_exec() {
    rsync -e "ssh -o ControlMaster=auto -o ControlPath=/tmp/workbuddy-manager-ssh-%C -o ControlPersist=600 -p $VPS_PORT" "$@"
}

echo "目标: $VPS_USER@$VPS_HOST:$VPS_PORT"
echo "管理端: $REMOTE_DIR"
echo "上游:   $UPSTREAM_DIR（容器 $UPSTREAM_CONTAINER）"
echo "端口:   $BIND_IP:$APP_PORT -> 容器 7864（上游 $UPSTREAM_PORT 仅本机）"

echo "[1/6] 检查 VPS 环境..."
DOCKER_GID="$(ssh_exec "REMOTE_DIR='$REMOTE_DIR' UPSTREAM_DIR='$UPSTREAM_DIR' UPSTREAM_CONTAINER='$UPSTREAM_CONTAINER' UPSTREAM_PORT='$UPSTREAM_PORT' APP_PORT='$APP_PORT' bash -s" <<'REMOTE'
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
    echo "当前脚本需要 root SSH，以创建 /opt 下的目录并设置容器用户权限" >&2
    exit 1
fi
for dependency in docker python3 curl rsync ssh-keygen; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "VPS 缺少依赖: $dependency" >&2
        exit 1
    fi
done
if ! docker compose version >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "VPS 需要可用的 Docker Engine 和 Docker Compose 插件" >&2
    exit 1
fi
# 容器名冲突：上游容器名固定。若占用者是**本脚本上一次部署**留下的容器
# （compose 项目与工作目录都对得上），compose 重建时会接管它——这是重复部署的
# 正常路径，放行；只有属于别的 compose 项目时才拦。
if docker inspect "$UPSTREAM_CONTAINER" >/dev/null 2>&1; then
    owner="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$UPSTREAM_CONTAINER" 2>/dev/null || true)"
    workdir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$UPSTREAM_CONTAINER" 2>/dev/null || true)"
    if [ "$owner" = "$(basename "$UPSTREAM_DIR")" ] && [ "$workdir" = "$UPSTREAM_DIR" ]; then
        echo "      上游容器 $UPSTREAM_CONTAINER 是本脚本上次部署的，将由 compose 重建" >&2
    else
        echo "已存在名为 $UPSTREAM_CONTAINER 的容器（compose 项目：${owner:-未知}，工作目录：${workdir:-未知}）。" >&2
        echo "本脚本要自己部署上游并复用该容器名，请先移除它（仅 stop 不够，容器名仍被占用）：" >&2
        echo "    docker rm -f $UPSTREAM_CONTAINER" >&2
        echo "若那是别的部署（例如 workbuddy2api-panel），请先在其目录执行 docker compose down。" >&2
        exit 1
    fi
fi
# 端口占用：7863 与 APP_PORT 要么空闲，要么由本项目自己的容器占用——compose
# 重建时会自动把端口交接过去，不该拦（否则第二次部署必然中止）。只有被别的
# 进程或别的容器占着才拦。workbuddy-manager 是 compose.vps.yaml 固定的容器名。
if command -v ss >/dev/null 2>&1; then
    for port in "$UPSTREAM_PORT" "$APP_PORT"; do
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port\$" || continue
        holder="$(docker ps --filter "publish=$port" --format '{{.Names}}' 2>/dev/null | head -1)"
        case "$holder" in
            "$UPSTREAM_CONTAINER"|workbuddy-manager)
                echo "      端口 $port 由本项目容器 $holder 占用，将由 compose 重建时接管" >&2
                ;;
            *)
                echo "端口 $port 已被占用${holder:+（容器 $holder）}，请先释放（ss -lntp | grep :$port）" >&2
                exit 1
                ;;
        esac
    done
else
    echo "警告：VPS 上没有 ss 命令，已跳过端口占用检查" >&2
fi
# 管理端数据目录：首次创建并归属 10001，之后每次校验（跨 uid 读写不到会报
# 「unable to open database file」，报错既不说路径也不说原因，故提前拦住）
mkdir -p "$REMOTE_DIR/releases"
APP_UID=10001
APP_GID=10001
data_dir="$REMOTE_DIR/data"
if [ ! -e "$data_dir" ]; then
    install -d -m 700 -o "$APP_UID" -g "$APP_GID" "$data_dir"
fi
if [ ! -d "$data_dir" ] || [ -L "$data_dir" ] \
   || [ "$(stat -c %u "$data_dir")" != "$APP_UID" ] || [ "$(stat -c %g "$data_dir")" != "$APP_GID" ]; then
    echo "管理端数据目录属主不匹配: $data_dir（应为 $APP_UID:$APP_GID）" >&2
    exit 1
fi
mode="$(stat -c %a "$data_dir")"
if (( (8#$mode & 077) != 0 || (8#$mode & 0700) != 0700 )); then
    echo "管理端数据目录权限不满足要求: $data_dir ($mode)，请设置为 700" >&2
    exit 1
fi
# docker.sock 的组 gid：容器以 10001 运行，不补这个组就用不了 docker CLI
sock_gid="$(stat -c %g /var/run/docker.sock)"
if ! [[ "$sock_gid" =~ ^[0-9]+$ ]]; then
    echo "无法解析 /var/run/docker.sock 的组 gid" >&2
    exit 1
fi
printf '%s\n' "$sock_gid"
REMOTE
)"
if ! [[ "$DOCKER_GID" =~ ^[0-9]+$ ]]; then
    echo "VPS 返回的 DOCKER_GID 异常: $DOCKER_GID" >&2
    exit 1
fi
echo "      docker.sock 组 gid: $DOCKER_GID"

if [ "$LOCAL_MODE" = "1" ]; then
    echo "[2/6] 上传本地工作区（--local：跳过 Release 下载与签名校验）..."
    # 上传前自检：缺了这些，VPS 上的构建必然失败，不如现在就说清楚
    for required in Dockerfile server/main.py web/package.json web/package-lock.json; do
        if [ ! -f "$LOCAL_DIR/$required" ]; then
            echo "本地工作区不完整：缺少 $required" >&2
            exit 1
        fi
    done
    if [ "$LOCAL_WEB_OUT" = "1" ] && [ ! -f "$LOCAL_DIR/web/out/index.html" ]; then
        echo "LOCAL_WEB_OUT=1 但本地没有 web/out/index.html；请先在 web/ 下 npm run build:export" >&2
        exit 1
    fi
    release_dir="$(ssh_exec "REMOTE_DIR='$REMOTE_DIR' bash -s" <<'REMOTE'
set -euo pipefail
umask 077
mkdir -p "$REMOTE_DIR/releases"
mktemp -d "$REMOTE_DIR/releases/$(date -u +%Y%m%dT%H%M%SZ)-local-XXXXXXXX"
REMOTE
)"
else
# 这一支刻意保持顶格不缩进：下面的 heredoc 是 <<'REMOTE'（保留缩进），重排会把
# 空格注进远端脚本，连内嵌的 python 代码一起搞成 IndentationError。
echo "[2/6] 在 VPS 下载并校验 Release 包..."
release_dir="$(ssh_exec "REMOTE_DIR='$REMOTE_DIR' MANAGER_REPO='$MANAGER_REPO' RELEASE_VERSION='$RELEASE_VERSION' SKIP_VERIFY='$SKIP_VERIFY' bash -s" <<'REMOTE'
set -euo pipefail
umask 077
api="https://api.github.com/repos/${MANAGER_REPO}/releases/${RELEASE_VERSION}"
echo "  查询 Release: ${MANAGER_REPO} ${RELEASE_VERSION}" >&2
meta="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 60 "$api")" || {
    echo "查询 Release 失败：$api" >&2; exit 1; }
read -r tag tarball sig < <(printf '%s' "$meta" | python3 -c '
import json, sys
d = json.load(sys.stdin)
tag = d.get("tag_name") or ""
assets = {a["name"]: a["browser_download_url"] for a in d.get("assets") or []}
tar = next((u for n, u in assets.items() if n.endswith(".tar.gz")), "")
sig = next((u for n, u in assets.items() if n.endswith(".tar.gz.sig")), "")
print(tag, tar, sig)
')
if [ -z "$tag" ] || [ -z "$tarball" ]; then
    echo "Release 中未找到 .tar.gz 产物" >&2
    exit 1
fi
echo "  版本: $tag" >&2

stage="$(mktemp -d "$REMOTE_DIR/.stage-XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
curl -fsSL --retry 3 --retry-delay 2 --max-time 600 "$tarball" -o "$stage/pkg.tar.gz"

if [ "$SKIP_VERIFY" = "1" ]; then
    echo "  已按 SKIP_VERIFY=1 跳过签名校验" >&2
else
    if [ -z "$sig" ]; then
        echo "Release 缺少 .tar.gz.sig，无法校验发布包（确认无误可设 SKIP_VERIFY=1 跳过）" >&2
        exit 1
    fi
    curl -fsSL --retry 3 --retry-delay 2 --max-time 120 "$sig" -o "$stage/pkg.tar.gz.sig"
    # 信任锚内嵌在 update.py 里（与之一致），不从下载内容读取
    cat > "$stage/allowed_signers" <<'SIGNERS'
release ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHEGhxZQjEEK/RbtgcRLuuWji0fVB4E2dVKMnhtLlCkx workbuddy release signing
SIGNERS
    if ! ssh-keygen -Y verify -f "$stage/allowed_signers" -I release -n file \
            -s "$stage/pkg.tar.gz.sig" < "$stage/pkg.tar.gz" >/dev/null 2>&1; then
        echo "发布包签名校验失败，已中止（若确认包可信可设 SKIP_VERIFY=1）" >&2
        exit 1
    fi
    echo "  签名校验通过" >&2
fi

# 解压到独立发布目录，去掉 tar 包自带的顶层目录
release_dir="$(mktemp -d "$REMOTE_DIR/releases/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")"
tar -xzf "$stage/pkg.tar.gz" -C "$release_dir" --strip-components=1
# 注意：compose.vps.yaml 不在 Release 包内（包内只有面向本地开发的
# docker-compose.yml），由部署脚本在构建前单独上传，故此处不校验它。
for required in Dockerfile server/main.py; do
    if [ ! -f "$release_dir/$required" ]; then
        echo "发布包结构异常：缺少 $required" >&2
        exit 1
    fi
done
if [ ! -d "$release_dir/upstream" ] || [ ! -f "$release_dir/upstream/docker-compose.yml" ]; then
    echo "发布包内未找到上游源码（upstream/docker-compose.yml）" >&2
    exit 1
fi
if [ ! -f "$release_dir/web/out/index.html" ]; then
    echo "警告：发布包内没有已构建的前端（web/out），构建时将在容器内执行 npm" >&2
fi
# 部署脚本自身不进发布目录（与源码目录解耦）
rm -f "$release_dir/deploy-to-vps.sh"
printf '%s\n' "$release_dir"
REMOTE
)"
fi
if [[ "$release_dir" != "$REMOTE_DIR/releases/"* ]]; then
    echo "VPS 返回的发布目录异常: $release_dir" >&2
    exit 1
fi
echo "      发布目录: $release_dir"

# --local：把本地工作区传进刚建好的发布目录。排除清单只为省带宽；镜像内容的
# 取舍由随代码一起上传的 .dockerignore 决定（单一事实来源，不在这里抄一遍）。
if [ "$LOCAL_MODE" = "1" ]; then
    upload_opts=(-az
        --exclude=/.git/ --exclude=/.github/ --exclude=/.ref/ --exclude=/.devdata/
        --exclude=/dev/ --exclude=/docs/
        --exclude=/node_modules/ --exclude=/web/node_modules/ --exclude=/web/.next/
        --exclude=/__pycache__/ --exclude='*.pyc' --exclude=/.venv/ --exclude=/venv/
        --exclude=/data/ --exclude=/.env --exclude=/.env.local --exclude=/.env.vps
        --exclude=/.version --exclude=/users.json --exclude=/config.json
        --exclude='/*.db' --exclude='/*.db-wal' --exclude='/*.db-shm'
        --exclude=/.idea/ --exclude=/.vscode/ --exclude=/.DS_Store
        --exclude=/web/out/cache --exclude=/deploy-to-vps.sh)
    if [ "$LOCAL_WEB_OUT" != "1" ]; then
        upload_opts+=(--exclude=/web/out/)
    fi
    rsync_exec "${upload_opts[@]}" "$LOCAL_DIR/" "$VPS_USER@$VPS_HOST:$release_dir/"
    if [ "$LOCAL_WEB_OUT" = "1" ]; then
        echo "      已上传工作区（前端复用本地 web/out，跳过容器内构建）"
    else
        echo "      已上传工作区（前端将在容器内用上传的源码构建）"
    fi
fi

# 镜像 tag：本地模式用 git 描述（能看出是哪一次改动，带 -dirty 更好），正式模式
# 取发布包的版本标记（.version 存的是 v1.0.72，去掉 v 前缀）。Docker tag 不认大写，
# 统一小写；拿不到就退回 local——只影响可追溯性，不影响部署本身，故不中断。
if [ "$LOCAL_MODE" = "1" ]; then
    # 刻意不加 --dirty：Windows 检出是 CRLF、WSL 里的 git 会把它算成「所有文件
    # 都已修改」，恒为脏；何况开发迭代时工作区本来就是脏的，这后缀没有信息量。
    # tag 标识的是「哪个提交」，具体是哪一次构建看发布目录的时间戳。
    image_tag="local-$(git -C "$LOCAL_DIR" describe --tags --always 2>/dev/null \
        || date -u +%Y%m%dT%H%M%SZ)"
    image_tag="$(printf '%s' "$image_tag" | tr '[:upper:]' '[:lower:]')"
else
    release_marker="$(ssh_exec "cat '$release_dir/.version' 2>/dev/null || true")" || release_marker=""
    image_tag="$(printf '%s' "$release_marker" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    image_tag="${image_tag#v}"
fi
if [[ ! "$image_tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "      警告：拿不到版本标记，镜像 tag 退回 local" >&2
    image_tag="local"
fi
echo "      镜像 tag: workbuddy-manager:$image_tag"

if [ "$LOCAL_MODE" = "1" ]; then
    # 上游源码不在本仓库，所以本地模式**不同步源码、也不重建镜像**，只把容器
    # 拉起来（compose 仅在镜像缺失时才会构建）。要更新上游代码，跑一次不带
    # --local 的正式部署，或用面板里的「更新上游」。
    echo "[3/6] 本地模式：确保上游 workbuddy2api 在运行..."
    ssh_exec "UPSTREAM_DIR='$UPSTREAM_DIR' UPSTREAM_PORT='$UPSTREAM_PORT' bash -s" <<'REMOTE'
set -euo pipefail
if [ ! -f "$UPSTREAM_DIR/docker-compose.yml" ]; then
    echo "上游尚未安装（缺 $UPSTREAM_DIR/docker-compose.yml）。" >&2
    echo "本地模式不携带上游源码（它不在本仓库），请先跑一次不带 --local 的正式部署。" >&2
    exit 1
fi
cd "$UPSTREAM_DIR"
docker compose up -d
# 就绪判据是「HTTP 有响应」而不是「200」：上游 /healthz 返回的是**业务健康度**
# （账号池里的可用账号数），账号会话过期时会返回 503 —— 那是它的正常运行状态，
# 不该拦住管理端部署。所以这里刻意不加 curl -f。
ready=0
for _ in $(seq 1 30); do
    if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${UPSTREAM_PORT}/healthz"; then
        ready=1
        break
    fi
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    docker compose logs --tail=40 >&2 || true
    echo "上游未在预期时间内响应（http://127.0.0.1:${UPSTREAM_PORT}/healthz）；请检查：cd $UPSTREAM_DIR && docker compose logs" >&2
    exit 1
fi
echo "      上游已响应（HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${UPSTREAM_PORT}/healthz")）" >&2
REMOTE
else
# 同第 2 步：这一支也顶格不缩进（heredoc 保留缩进，重排会改坏远端脚本）。
echo "[3/6] 部署上游 workbuddy2api（用发布包内的源码快照）..."
ssh_exec "REMOTE_DIR='$REMOTE_DIR' UPSTREAM_DIR='$UPSTREAM_DIR' UPSTREAM_CONTAINER='$UPSTREAM_CONTAINER' UPSTREAM_PORT='$UPSTREAM_PORT' RELEASE_DIR='$release_dir' bash -s" <<'REMOTE'
set -euo pipefail
umask 077
src="$RELEASE_DIR/upstream"

if [ -e "$UPSTREAM_DIR" ] && [ ! -d "$UPSTREAM_DIR" ]; then
    echo "上游路径已存在且不是目录: $UPSTREAM_DIR" >&2
    exit 1
fi
mkdir -p "$UPSTREAM_DIR"

first_install=0
if [ ! -f "$UPSTREAM_DIR/config.json" ]; then
    first_install=1
fi

# 同步上游源码：只增改、不删除，且绝不动 config.json / auths / data
# （api_key、账号凭据、运行状态是持久数据，更新代码时必须原样保留）
skip_top="config.json auths data"
changed=0
added=0
while IFS= read -r -d '' file; do
    rel="${file#"$src"/}"
    top="${rel%%/*}"
    case " $skip_top " in *" $top "*) continue ;; esac
    case "$rel" in */.git/*|.git/*|*/__pycache__/*|__pycache__/*) continue ;; esac
    dst="$UPSTREAM_DIR/$rel"
    if [ -f "$dst" ]; then
        if cmp -s "$dst" "$file"; then
            continue
        fi
        changed=$((changed + 1))
    else
        added=$((added + 1))
    fi
    mkdir -p "$(dirname "$dst")"
    cp -p "$file" "$dst"
done < <(find "$src" -type f -print0)
echo "      上游源码同步：改写 $changed 个、新增 $added 个"

# 端口收敛为仅本机：上游仓库里是 "7863:7863"（公网可达），安全基线要求
# 只绑回环。管理端经 Docker 网络用服务名直连，不依赖宿主的公网端口。
compose="$UPSTREAM_DIR/docker-compose.yml"
if [ -f "$compose" ]; then
    if grep -q '"127.0.0.1:7863:7863"' "$compose"; then
        :
    elif grep -q '"7863:7863"' "$compose"; then
        sed -i 's#"7863:7863"#"127.0.0.1:7863:7863"#' "$compose"
        echo "      已将上游端口绑定收敛为 127.0.0.1:7863:7863"
    else
        echo "警告：上游 compose 未匹配到端口绑定行，请人工确认 $compose" >&2
    fi
else
    echo "上游目录缺少 docker-compose.yml: $compose" >&2
    exit 1
fi

if [ "$first_install" = "1" ]; then
    if [ ! -f "$UPSTREAM_DIR/config.example.json" ]; then
        echo "缺少 config.example.json，无法生成上游配置" >&2
        exit 1
    fi
    cp "$UPSTREAM_DIR/config.example.json" "$UPSTREAM_DIR/config.json"
    api_key="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
    python3 - "$UPSTREAM_DIR/config.json" "$api_key" <<'PY'
import json
import sys

path, key = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as source:
    config = json.load(source)
config['api_key'] = key
with open(path, 'w', encoding='utf-8') as target:
    json.dump(config, target, ensure_ascii=False, indent=2)
    target.write('\n')
PY
    echo "      已生成上游配置（api_key 随机）"
else
    echo "      已存在上游配置，保留 config.json / auths / data"
fi

# 上游目录整体归属 10001：
#   · 上游容器以 uid 10001 运行，要读凭证并回写（refresh / 落盘）；
#   · 管理端容器同样以 uid 10001 运行，且**要能写回源码目录** —— 容器版
#     「更新上游」会在本容器内同步包内源码并重建上游容器，目录若归 root
#     就会 permission denied（官方 systemd 部署以 root 运行，无此问题）。
mkdir -p "$UPSTREAM_DIR/auths" "$UPSTREAM_DIR/data"
chown -R 10001:10001 "$UPSTREAM_DIR"
chmod 600 "$UPSTREAM_DIR/config.json"
chmod 700 "$UPSTREAM_DIR/auths" "$UPSTREAM_DIR/data"

echo "      构建并启动上游容器（首次构建需数分钟）..."
cd "$UPSTREAM_DIR"
docker compose up -d --build

echo "      等待上游就绪..."
ready=0
for _ in $(seq 1 90); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${UPSTREAM_PORT}/healthz" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
if [ "$ready" -ne 1 ]; then
    docker compose logs --tail=60 >&2 || true
    echo "上游未在预期时间内就绪；请检查：cd $UPSTREAM_DIR && docker compose logs" >&2
    exit 1
fi
echo "      上游已就绪: $(curl -fsS --max-time 3 "http://127.0.0.1:${UPSTREAM_PORT}/healthz")"
REMOTE
fi

echo "[4/6] 上传管理端 compose 与部署变量，构建启动..."
{
    printf 'DEPLOY_ROOT=%s\n' "$REMOTE_DIR"
    printf 'UPSTREAM_DIR=%s\n' "$UPSTREAM_DIR"
    printf 'UPSTREAM_CONTAINER=%s\n' "$UPSTREAM_CONTAINER"
    printf 'UPSTREAM_NETWORK=%s\n' "$(basename "$UPSTREAM_DIR")_default"
    printf 'UPSTREAM_PORT=%s\n' "$UPSTREAM_PORT"
    printf 'DOCKER_GID=%s\n' "$DOCKER_GID"
    printf 'BIND_IP=%s\n' "$BIND_IP"
    printf 'APP_PORT=%s\n' "$APP_PORT"
    printf 'IMAGE_TAG=%s\n' "$image_tag"
} > "$LOCAL_DIR/.env.vps"
# compose.vps.yaml 不在 Release 包内（包内只有面向本地开发的 docker-compose.yml），
# 从本地项目上传；它包含上游目录 / 网络 / 端口等本项目专属的编排约定。
rsync_exec -az "$LOCAL_DIR/.env.vps" "$VPS_USER@$VPS_HOST:$release_dir/.env"
rsync_exec -az "$LOCAL_DIR/compose.vps.yaml" "$VPS_USER@$VPS_HOST:$release_dir/compose.vps.yaml"
rm -f "$LOCAL_DIR/.env.vps"

# 首启才会生成管理员密码并打印一次；必须**在容器启动之前**判断，否则等构建完
# users.json 早已存在，永远读不到那行密码。
users_existed="$(ssh_exec "if [ -f '$REMOTE_DIR/data/users.json' ]; then echo 1; else echo 0; fi")"
if [ "$users_existed" != "0" ] && [ "$users_existed" != "1" ]; then
    echo "VPS 返回的数据状态异常: $users_existed" >&2
    exit 1
fi

echo "[5/6] 用 Docker Compose 构建并启动管理端，验证后切换 current..."
ssh_exec "REMOTE_DIR='$REMOTE_DIR' RELEASE_DIR='$release_dir' KEEP_RELEASES='$KEEP_RELEASES' bash -s" <<'REMOTE'
set -euo pipefail
umask 077
if [ -e "$REMOTE_DIR/current" ] && [ ! -L "$REMOTE_DIR/current" ]; then
    echo "current 已存在且不是符号链接，拒绝替换" >&2
    exit 1
fi
previous_release=""
if [ -L "$REMOTE_DIR/current" ]; then
    previous_release="$(readlink -f "$REMOTE_DIR/current")"
    # 悬空链接（发布目录被外部清掉、磁盘故障等）不该卡死部署：降级为「本次无
    # 回滚」，继续往下走。切换成功时 current 会被整体替换，自动自愈。
    if [ ! -f "$previous_release/compose.vps.yaml" ]; then
        echo "警告：current 指向的上一版发布目录不存在（$previous_release），本次无法回滚" >&2
        previous_release=""
    fi
fi
rollback() {
    if [ -n "$previous_release" ]; then
        echo "正在恢复上一版: $previous_release" >&2
        (cd "$previous_release" && docker compose -f compose.vps.yaml up -d --build)
    else
        echo "没有上一版可回滚（首次部署，或上一版发布目录已缺失）；请检查当前容器和发布目录 $RELEASE_DIR" >&2
    fi
}
cd "$RELEASE_DIR"
docker compose -f compose.vps.yaml config --quiet
if ! docker compose -f compose.vps.yaml up -d --build; then
    echo "新版构建或启动失败" >&2
    rollback
    exit 1
fi

ready=0
for _ in $(seq 1 60); do
    if docker compose -f compose.vps.yaml exec -T workbuddy-manager \
        curl -fsS http://127.0.0.1:7864/api/healthz >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
docker compose -f compose.vps.yaml ps
if [ "$ready" -ne 1 ]; then
    docker compose -f compose.vps.yaml logs --tail=80 workbuddy-manager >&2
    echo "新版管理端未响应；发布目录: $RELEASE_DIR" >&2
    rollback
    exit 1
fi
next_link="$REMOTE_DIR/current.$$"
if ! ln -s "$RELEASE_DIR" "$next_link"; then
    rollback
    exit 1
fi
if ! mv -Tf "$next_link" "$REMOTE_DIR/current"; then
    rm -f "$next_link"
    rollback
    exit 1
fi

# 切换成功后清理旧发布目录：保留 current 指向的那份 + 最近 KEEP_RELEASES-1 份。
# 按名字倒序（时间戳前缀，字典序即时间序），只删 releases/ 下的一级目录并逐个
# 校验路径前缀。清理失败只告警：部署本身已经成功，不该因磁盘清理而报失败。
current_target="$(readlink -f "$REMOTE_DIR/current")"
kept=0
while IFS= read -r old_release; do
    if [ "$old_release" = "$current_target" ]; then
        continue
    fi
    if [ "$kept" -lt "$((KEEP_RELEASES - 1))" ]; then
        kept=$((kept + 1))
        continue
    fi
    case "$old_release" in
        "$REMOTE_DIR"/releases/*)
            if rm -rf -- "$old_release"; then
                echo "      已清理旧发布目录: $(basename "$old_release")" >&2
            else
                echo "警告：清理旧发布目录失败（不影响本次部署）: $old_release" >&2
            fi
            ;;
    esac
done < <(find "$REMOTE_DIR/releases" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort -r)
REMOTE

echo "[6/6] 读取初始管理员密码..."
ssh_exec "REMOTE_DIR='$REMOTE_DIR' USERS_EXISTED='$users_existed' bash -s" <<'REMOTE'
set -euo pipefail
umask 077
users="$REMOTE_DIR/data/users.json"
if [ "$USERS_EXISTED" = "1" ]; then
    echo "管理端用户文件已存在，沿用原密码：$users"
    echo "（忘记密码时删除该文件并重启容器，会重新生成随机密码并打印到日志）"
else
    # 首启由管理端生成随机密码并打印一次；这里只负责把它读出来，不再重复打印
    for _ in $(seq 1 30); do
        if [ -f "$users" ]; then
            break
        fi
        sleep 1
    done
    password="$(cd "$REMOTE_DIR/current" && docker compose -f compose.vps.yaml logs --no-log-prefix workbuddy-manager 2>/dev/null \
        | sed -n 's/^  *密码  *: *//p' | tail -1)"
    if [ -n "$password" ]; then
        echo "初始管理员密码（仅首次生成，请登录后立即修改）: $password"
    else
        echo "未能从日志中读到初始密码，请手动查看："
        echo "  ssh -p $VPS_PORT $VPS_USER@$VPS_HOST 'cd $REMOTE_DIR/current && docker compose -f compose.vps.yaml logs workbuddy-manager | grep -A3 密码'"
    fi
fi
REMOTE

echo ""
echo "部署完成。"
echo "管理端源码: $release_dir"
echo "管理端镜像: workbuddy-manager:$image_tag"
echo "管理端数据: $REMOTE_DIR/data（数据库、用户、审计、更新状态）"
echo "上游:       $UPSTREAM_DIR（容器 $UPSTREAM_CONTAINER，仅监听 127.0.0.1:$UPSTREAM_PORT）"
if [ "$BIND_IP" = "127.0.0.1" ]; then
    echo "本地访问面板: ssh -p $VPS_PORT -L $APP_PORT:127.0.0.1:$APP_PORT $VPS_USER@$VPS_HOST"
    echo "随后打开 http://127.0.0.1:$APP_PORT/"
else
    echo "访问面板: http://$VPS_HOST:$APP_PORT/"
    echo "⚠️  当前以 $BIND_IP 对外暴露（未走 HTTPS）：请立即用强密码登录并在"
    echo "   「设置 → 管理用户」中修改初始密码；条件允许时尽快改为反向代理 + HTTPS。"
fi
echo "查看管理端日志: ssh -p $VPS_PORT $VPS_USER@$VPS_HOST 'cd $REMOTE_DIR/current && docker compose -f compose.vps.yaml logs -f workbuddy-manager'"
echo "查看上游日志:   ssh -p $VPS_PORT $VPS_USER@$VPS_HOST 'cd $UPSTREAM_DIR && docker compose logs -f'"
echo "重启管理端:     ssh -p $VPS_PORT $VPS_USER@$VPS_HOST 'cd $REMOTE_DIR/current && docker compose -f compose.vps.yaml restart workbuddy-manager'"