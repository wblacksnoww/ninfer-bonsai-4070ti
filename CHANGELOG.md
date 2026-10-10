# 更新记录（Changelog）

本文件按版本倒序记录每次发布的关键变更。每个版本都对应 GitHub Release 与 GHCR 镜像标签；
模型制品不随 git 分发（见 `docker/fetch-model.sh`，魔搭镜像 `xiuming/ninfer-bonsai-4070ti`）。

---

## v3.0.0 — 2026-10-10（双线：老线 A3 + fusion KVMem 环线）

**主题**：新增一整条实验引擎线（fusion KVMem 环），把"设备 KV 池 < 逻辑上下文"变成合法配置 ——
12GB 卡上开出 262,144 逻辑上下文；老线零改动、向后兼容。

### 新增（Added）

- **fusion KVMem 环线引擎**（`vendor/ninfer-fusion-kvmem/`，上游 `1314521gjy/ninfer-fusion-kvmem` @ `acba3d4`）：
  Linux 自编译（1050/1050 目标全绿，sm_89 cubin，sha256 `8058e056…4d0d`）；CMake 支持 80/86/89/120a。
  核心能力：常驻窗口（显存）+ 主机层 KV（内存）+ 按内容检索取回 + host-backed 前缀复用；
  新旋钮 `thinking_budget` / `--vision-residency` / KV 内容打分。
- **v3 容器制品三件**（`models/fusion/`，约 22 GiB；字节数与官方内测包清单逐件吻合，SHA256 实算入 `fetch-model.sh`）：
  全量件 `Ternary-Bonsai-2-27B-ninfer-v3.ninfer`（8.87 GiB，+DFlash2 适配器/proposal 头/视觉塔）、
  瘦身件 `…-v3-mtponly.ninfer`（7.13 GiB）、PTQ1 件 `bonsai2_27b_ternary_ptq1_native_mtp.ninfer`（5.96 GiB）。
- **宿主脚本**：`scripts/start-fusion.sh`（三档：fusion / fusion-mtp / fusion-ptq1；端口 8088 与老线互斥并预检；
  两套布局自动解析）、`scripts/fusion_accept_test.py`（短问答 + 40 万字符超窗针测两轮，只读 HTTP）。
- **容器双线**：`docker/build-image.sh -l old|fusion`（fusion → tag `…-archXX-fusion`）；
  `docker/run-ninfer.sh -l old|fusion|fusion-mtp|fusion-ptq1`（fusion 档自动带环线参数与环境变量）；
  新增 `docker/docker-compose.fusion.yml`（逐参数中文注释）。
- **CI 双线**：`docker-build` 四腿矩阵（89/120a × old/fusion）；`release` 双线发布
  （`$VER`/`latest` 仍为老线不变，新增 `$VER-fusion`/`latest-fusion`）。
- 文档：`docs/更新教程-v3.0.0.md`（升级全流程 + 兼容矩阵 + 回滚）、
  `docs/Fusion-KVMem-部署与运行.md`（使用说明）；`docs/性能实测.md` §9/§10、
  `docs/踩坑实录.md` §五 双线增补；本文件。

### 实测（同卡同脚本，RTX 4070 Ti 12GB；完整表见 docs/性能实测.md §9）

- 解码 **+45%~+98%**（117-184 vs 76-94 tok/s）；32k 上下文解码 **134.3 vs 69.7（+93%）**；
  思考轮墙钟 **1776 vs 3486 ms（−49%）**。
- 代价：预填 **−13%~−43%**（主机层搬运占 21-24%、每块内容打分）；短提示 TTFT **299 vs 126 ms**。
- 能力：逻辑上下文 **262,144**（老线 112k 封顶）；长会话 host-backed 复用实测
  **44k token 追问 TTFT 19.5s → 270 ms（cache 99.9%）**；**147k token 超窗题面
  （设备池 54,784 的 2.7 倍）针测两轮 PASS、追问轮 cache 100% / TTFT 1.0s**（v3.0.0 发布前首测）；
  KV rk4v4-e8（+0.30% PPL）；单并发（环的硬约束）。

### 兼容性（Compatibility）

- **引擎与制品成对使用**（硬校验）：老引擎拒 v3 件、fusion 引擎拒 v2 件
  （容器魔数第 8 字节 02/03）；无混搭路径，v2→v3 无三元件就地升级工具。
- **老线向后兼容**：引擎树、`scripts/start-ninfer.sh`、老容器 tag（`cuda13.3-arch89/120a`、`$VER`、`latest`）
  语义全部不变；升级 = 并存，不是替换。
- Dockerfile 增删 GeForce 前向兼容库（`/usr/local/cuda*/compat`，两线共用；出处见踩坑 5.8）。

### 已知问题（Known Issues）

- fusion 线为实验版本（作者口径：不保证正确性/稳定性）：单并发硬约束；约 95k 题面零命中反例未定位；
  视觉路径本线作者未验；长冷预填后连接中断为缓解项；`--kv-capacity auto` 池被显存封顶（12GB 实测 54,784）。
- [7]/[11] 两项 perf_test 脚本次次读"红"（思考吃满预算 / effort 组合无效），两代一致属脚本怪癖。

## v2.0.0 — 2026-09-28（A3 引擎世代定稿）

- **A3 引擎**：pkg2 r12 树 + P1/P2/A3 补丁 + `NINFER_SM_COUNT` 参数化；prefill **+24.6%**（2108-2209 t/s，
  pkg5 口径 A/B + sha 逐位门）；**前缀复用恢复**（账本 bug 修复，不再需要 `--no-prefix-reuse`）；
  `NINFER_TERNARY_TOKEN_GRID` 默认开（须配 `NINFER_TERNARY_SMALL_T_ROWS=16` 绕开 32 行档缺陷）。
- 高可预测任务 decode 145-173 tok/s（K=3/5）；上下文 112K（fp8 + MTP K=3）。
- Docker 去 `--no-prefix-reuse`；魔搭镜像列为第一推荐获取路径；GHCR `v2.0.0`。

## v1.0.0 — 2026-09-27（首次发布）

- 容器化部署（vendor 源码容器内编译 + 国内源 + GPU 架构参数化）、GitHub Actions 自动打包（GHCR）与
  Release 自动发布（谷歌风格模板）；双入口冒烟 83.8 / 85.2 tok/s（与宿主直跑持平）。
- 160 行内：本仓库首版为"三元 Bonsai-2-27B 在 RTX 4070 Ti 12GB Linux 上的全流程部署实录"，
  实测 decode 75-145 tok/s、prefill 2108-2209 t/s、TTFT 81-179 ms、上下文 112K。
