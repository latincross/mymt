# DM v8.5.7 — schema-tracker 补丁 + dm-worker 构建包（已修正）

## 问题

DM 增量同步到 **MySQL 8.0 下游** 时，schema-tracker 初始化报错：

```
Error 1231 (42000): Variable 'sql_mode' can't be set to 'NO_AUTO_CREATE_USER'
code=44016 class=schema-tracker / code=38032
```

根因（已核实）：`dm/pkg/schema/tracker.go` 的 `initDownStreamSQLModeAndParser`  
用 `mysql.DefaultSQLMode` 拼接 `SET SESSION SQL_MODE=...`。tiflow v8.5.7 锁定的  
tidb 里 `DefaultSQLMode` 常量仍含 `NO_AUTO_CREATE_USER`（见  
`pkg/parser/mysql/const.go:310`），下游 MySQL 8.0 已移除该模式，于是报 1231。

## ⚠️ 原包存在的问题（本次已修正）

原 `dm-patch` 包里的补丁和脚本对不上真实的 tiflow v8.5.7 源码，照原 README 直接执行  
**打不出有效包**，具体：

1. **补丁打不上**：原 `tracker.go.patch` 针对的是一个虚构的 `Tracker`/`setSQLMode`  
   结构。真实 v8.5.7 里该函数是 `func (dt *downstreamTracker)
   initDownStreamSQLModeAndParser(tctx *tcontext.Context) error`，且已导入 `fmt`。  
   原补丁 `+ "fmt"` 会造成重复导入。
2. **Go 版本错**：原脚本装 Go 1.21.13，但 v8.5.7 的 `go.mod` 声明 `go 1.25.10`，  
   1.21 无法构建。已改为 Go **1.26.7**。  
   ⚠️ 注意：v8.5.7 的 `go.mod` 含 `godebug tlsrsakex=1`，而 **Go 1.27 已永久删除该  
   GODEBUG**，用 1.27 会直接 `error loading go.mod`。因此必须停在 1.26.x（最后一个  
   仍支持该 GODEBUG 的大版本）。
3. **构建路径错**：原脚本 `cd dm && go build ./cmd/dm-worker`，但 dm-worker 入口在  
   仓库根目录 `./cmd/dm-worker`（见 Makefile `dm-worker:` 目标）。

修正后的补丁是**最小改动**：只新增 `fixedSQLMode` 常量（去掉  
`NO_AUTO_CREATE_USER`），并把 `setSQLMode` 那一行的 `mysql.DefaultSQLMode`  
换成 `fixedSQLMode`。不改 tidb 主仓 `DefaultSQLMode` 常量。

## 构建方式

### 方式 A：GitHub Actions 远程构建（推荐，无需本地 Linux）

1. 把本目录（含 `tracker.go.patch` 与 `.github/workflows/build-dm-worker.yml`）推到  
   一个 GitHub 仓库；
2. 在仓库 Actions 页手动触发 `build-dm-worker`；
3. 构建完成后从该次运行的 Artifacts 下载  
   `tidb-dm-worker-v8.5.7-linux-amd64.tar.gz`。

workflow 会自动：拉 tiflow v8.5.7 → `git apply` 补丁（失败即中止）→  
`go build ./cmd/dm-worker`（CGO_ENABLED=0，Go 1.26.7）→ 打包 → 上传 artifact。

### 方式 B：自有 Linux 服务器构建

```bash
sudo ./build-dm-worker.sh
# 成功后生成 tidb-dm-worker-v8.5.7-linux-amd64.tar.gz
```

脚本会自动：装 Go 1.26.7（多源 fallback）→ clone tiflow v8.5.7 → 应用补丁  
（失败即中止）→ 从仓库根目录编译 `./cmd/dm-worker` → 打包。

## 部署（热替换 dm-worker）

```bash
tiup dm patch <dm-cluster-name> ./tidb-dm-worker-v8.5.7-linux-amd64/bin/dm-worker --role dm-worker
tiup dmctl --master-addr <master>:8261 start-task ./task-test-to-mysql57-gtid.yaml
```

## 重要提醒

- 本补丁**仅解决** schema-tracker 初始化 `Error 1231 NO_AUTO_CREATE_USER`。
- 不解决全量 Lightning 的 `Unknown collation 'UTF8MB4_0900_AI_CI'`  
  （需下游手动建表 + `skip-create-schema` 或改上游表 collation）。
- 自行编译的 DM 不在 PingCAP 官方支持范围内。

## 包结构（构建产物）

```
tidb-dm-worker-v8.5.7-linux-amd64/
├── bin/
│   └── dm-worker   # 含补丁的 dm-worker（解决 Error 1231）
└── README.md
```

