#!/usr/bin/env bash
# build-dm-worker.sh (修正版)
# 一键构建打了 schema-tracker 补丁的 dm-worker (DM v8.5.7)。
# 用法: sudo ./build-dm-worker.sh
#
# 修正说明（相对原版）：
#   1. Go 版本：tiflow v8.5.7 的 go.mod 要求 go >= 1.25.10，原版 1.21.13 无法构建，
#      且 go.mod 内有 `godebug tlsrsakex=1`（Go 1.27 已永久删除该 GODEBUG，会导致
#      "error loading go.mod"）。因此固定在最后一个仍支持该 GODEBUG 的 1.26 系列：1.26.7。
#   2. 构建路径：dm-worker 入口在仓库根目录 ./cmd/dm-worker（非 dm/cmd/dm-worker）。
#   3. 补丁：tracker.go.patch 已重写为匹配真实 v8.5.7 源码的最小改动。
set -e

VERSION="v8.5.7"
REPO="https://github.com/pingcap/tiflow.git"
GO_VERSION="1.26.7"            # 需 >= 1.25.10；且 < 1.27（1.27 删除了 go.mod 里的 tlsrsakex GODEBUG）
INSTALL_DIR="/usr/local/go"
export PATH="$INSTALL_DIR/bin:$PATH"
export GOPROXY="https://goproxy.cn,https://proxy.golang.org,direct"
export GOFLAGS="-mod=mod"
export CGO_ENABLED=0
export GOTOOLCHAIN="local"     # 直接用本地安装的 Go，避免自动下载其它工具链

echo "==> [1/5] 检查/安装 Go >= 1.25"
if ! command -v go >/dev/null 2>&1 || [ "$(go version | grep -oP 'go1\.\K[0-9]+' || echo 0)" -lt 25 ]; then
  echo "    本地无合适 Go，尝试下载安装 Go ${GO_VERSION} ..."
  ARCH=$(uname -m); case "$ARCH" in x86_64) GOARCH=amd64;; aarch64|arm64) GOARCH=arm64;; *) GOARCH=amd64;; esac
  TMP=$(mktemp -d)
  # 多源 fallback
  for URL in \
    "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" \
    "https://golang.google.cn/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" \
    "https://mirrors.ustc.edu.cn/golang/go${GO_VERSION}.linux-${GOARCH}.tar.gz"; do
    echo "    try: $URL"
    if curl -sSL --connect-timeout 30 -o "$TMP/go.tar.gz" "$URL" && [ -s "$TMP/go.tar.gz" ]; then
      if tar -tzf "$TMP/go.tar.gz" >/dev/null 2>&1; then
        echo "    下载成功"
        break
      fi
    fi
  done
  if ! tar -tzf "$TMP/go.tar.gz" >/dev/null 2>&1; then
    echo "!! 无法从任何源下载 Go 安装包（当前网络可能无法访问 go.dev/golang.google.cn）。" >&2
    echo "!! 请在有外网的机器上手动安装 Go >= 1.25 后重新运行此脚本。" >&2
    exit 1
  fi
  rm -rf "$INSTALL_DIR"
  tar -C /usr/local -xzf "$TMP/go.tar.gz"
  rm -rf "$TMP"
fi
echo "    Go 版本: $(go version)"

echo "==> [2/5] 克隆 tiflow ${VERSION} 源码"
SRC="$(pwd)/tiflow-src"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "${VERSION}" "${REPO}" "${SRC}"
fi
cd "${SRC}"

echo "==> [3/5] 应用 tracker.go 补丁 (去除 NO_AUTO_CREATE_USER)"
PATCH="$(dirname "$(readlink -f "$0")")/tracker.go.patch"
if patch -p1 --dry-run -f < "${PATCH}" >/dev/null 2>&1; then
  patch -p1 --forward -r - < "${PATCH}"
  echo "    补丁已应用"
else
  echo "!! 补丁无法干净应用（源码与补丁不匹配），已中止。请检查 tiflow 版本。" >&2
  exit 1
fi

echo "==> [4/5] 编译 dm-worker"
# 入口在仓库根目录 ./cmd/dm-worker
go build -trimpath -ldflags="-s -w" -o "${SRC}/bin/dm-worker" ./cmd/dm-worker

echo "==> [5/5] 打包为 tidb-dm-worker-v8.5.7-linux-amd64.tar.gz"
OUT="$(pwd)/tidb-dm-worker-v8.5.7-linux-amd64"
mkdir -p "${OUT}/bin"
cp "${SRC}/bin/dm-worker" "${OUT}/bin/dm-worker"
cat > "${OUT}/README.md" <<'EOF'
# tidb-dm-worker v8.5.7 (schema-tracker patched)

包含打了补丁的 dm-worker 二进制，解决 DM 增量阶段 schema-tracker 初始化报错：
  Error 1231 (42000): Variable 'sql_mode' can't be set to 'NO_AUTO_CREATE_USER'
  (code=44016 schema-tracker / code=38032)

补丁内容 (dm/pkg/schema/tracker.go):
  在 initDownStreamSQLModeAndParser 中，将 SET SESSION SQL_MODE 使用的
  mysql.DefaultSQLMode 改为不含 NO_AUTO_CREATE_USER 的 fixedSQLMode。
  未修改 tidb 主仓 pkg/parser/mysql/const.go 的 DefaultSQLMode 常量。

部署 (tiup):
  tiup dm patch <dm-cluster-name> ./tidb-dm-worker-v8.5.7-linux-amd64/bin/dm-worker --role dm-worker

注意: 自行编译的 DM 不在 PingCAP 官方支持范围内。
EOF
tar -C "$(dirname "${OUT}")" -czf "tidb-dm-worker-v8.5.7-linux-amd64.tar.gz" "tidb-dm-worker-v8.5.7-linux-amd64"

echo ""
echo "构建完成:"
ls -la "tidb-dm-worker-v8.5.7-linux-amd64.tar.gz"
echo "${OUT}/bin/dm-worker:"
file "${OUT}/bin/dm-worker"
