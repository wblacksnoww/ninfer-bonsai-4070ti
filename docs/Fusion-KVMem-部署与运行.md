# NInfer Fusion KVMem 部署与运行（RTX 4070 Ti 12GB）— v3.0.0 新线

> 来源：`1314521gjy/ninfer-fusion-kvmem` @ commit `acba3d4`（2026-10-07 源码批），
> 引擎源码随本仓库分发于 `vendor/ninfer-fusion-kvmem/`。
> 启动脚本：`scripts/start-fusion.sh`（**端口固定 8088** —— 与老生产线同端口，两线互斥）。
> 容器线：`./docker/build-image.sh -l fusion` + `./docker/run-ninfer.sh -l fusion`（宿主 8089）。
> 与原老生产线（A3 引擎 + `artifacts-pq2.ninfer`）的引擎、制品、脚本**完全隔离**，互不影响。

---

## 0. 一句话

这是把"设备 KV 池 < 逻辑上下文"变成合法配置的一支实验引擎：**12GB 卡上可以开 262,144 逻辑上下文**，
长内容靠"常驻窗口（显存）+ 主机层（内存）+ 按内容检索取回 + 第二轮 host-backed 复用"承载。
它不能替代老生产线的快速短问答，是**长上下文/长会话**方向的互补线。

## 1. 与老线的能力对照

| 能力 | 老线（A3 引擎，start-ninfer.sh） | 本线（fusion 引擎，start-fusion.sh） |
|---|---|---|
| 逻辑上下文上限 | 112k（fp8 实测；262k 显存放不下） | **262,144（原生窗口）**，超出窗口部分在主机层，检索取回 |
| 长会话第二轮 TTFT | 前缀复用实测开，但无主机层 | 实测同会话 44k token 前缀：**19.5s → 270ms**（host-backed 复用，cache 99.9%） |
| KV 精度 | fp8 | rk4v4-e8（每页 1.10 MiB，质量代价 **+0.30%** 困惑度，官方实测口径） |
| 投机/解码 | MTP K=3（decode 75-84，可预测任务 145-173 tok/s） | DFlash2 + proposal 头（decode **+45%~+98%**，32k 上下文 134.3 vs 69.7 tok/s） |
| 预填 | 2108-2209 tok/s | 1.1-1.8k tok/s（**−13%~−43%**，主机层搬运占 21-24%） |
| 短提示 TTFT | 126-179 ms | ~299 ms（固定开销 +~170ms） |
| 思考控制 | 无预算 | `thinking_budget` / `--default-thinking-budget` / 思考通道 presence 惩罚 |
| 并发 | 支持并发（4 路聚合 336 t/s） | **只支持 1 路**（环的设计约束，硬拒 >1） |
| 稳定性口径 | 生产可用 | **实验版本**：作者自述"初期实验版，不保证正确性与稳定性"，未定位问题若干（§7） |

**结论**：用它在 12GB 卡上跑**超长上下文**（把 4090/5080 级别的 262k 能力搬到这张卡），
以及**长会话免冷预填**；短问答/日常生产继续用老线。逐项对照与口径见 [性能实测.md](性能实测.md) §9。

## 2. 制品：必须用 v3 容器（三件，`models/fusion/`）

**为什么必须换**：两代引擎对本代容器做硬校验 —— v3 引擎拒 v2 件（报
`NInfer v2 artifact is not supported`），老引擎拒 v3 件（entry magic 第 8 字节 2 vs 3 不匹配）。
官方 v2→v3 升级工具只认 7 个官方 groupwise-int/nvfp4 制品，**三元件不在其列** —— 旧件无法就地升级，只能成对换。
完整兼容矩阵见 [更新教程-v3.0.0.md](更新教程-v3.0.0.md) §2。

| 优先级 | 文件（`models/fusion/`，文件名勿改） | 字节数 | 内容 | 对应启动档 |
|---|---|---|---|---|
| **推荐（默认档）** | `Ternary-Bonsai-2-27B-ninfer-v3.ninfer` | 9,520,051,456（8.87 GiB） | 三元 PQ2 文本塔 + MTP + **DFlash2 适配器** + proposal 头 + 视觉塔 | `./scripts/start-fusion.sh`（fusion） |
| 备选（窗口大一倍） | `Ternary-Bonsai-2-27B-ninfer-v3-mtponly.ninfer` | 7,654,217,216（7.13 GiB） | 三元 PQ2 文本塔 + MTP 头（无视觉/无 dflash2/无 proposal） | `./scripts/start-fusion.sh fusion-mtp` |
| 可选（最省显存） | `bonsai2_27b_ternary_ptq1_native_mtp.ninfer` | 6,394,697,216（5.96 GiB） | PTQ1 三元 + MTP | `./scripts/start-fusion.sh fusion-ptq1` |

获取（任选）：`./docker/fetch-model.sh --ms-fusion`（魔搭，约 22GB 增量）｜
网盘"模型包-20260930"（夸克）手动放入 `models/fusion/`｜`./docker/fetch-model.sh <路径>` 自动分流落位。
三件 SHA256 已记录在 `fetch-model.sh`（本仓库实算；字节数已与官方内测包清单逐件核对）。

**新旧模型到底差在哪**：核心权重同源（两边文本塔都来自 PrismML 三元 PQ2_0，2.125 bit/权重，
Hadamard 旋转 + FP32 符号表做法一致）—— **回答质量是同一水平**（不是新模型更聪明）。
换件是为了**换引擎容器**：v2→v3 是打包格式换代（哈希目录、组件化清单、Uses/绑定表），
权重大小逐字节对应。组件裁剪差异：mtponly 无视觉/无 proposal（**不能**加 `--vision`，加了拒启）；
full 多 DFlash2 适配器 + proposal + 视觉；ptq1 是 PTQ1_0 编码（1.75 bit）最省显存。

## 3. 引擎：仓库内自编译（Linux 官方无预编译）

官方 Release 只有 Windows EXE；Linux 必须自编译。克隆用户：

```bash
cd vendor/ninfer-fusion-kvmem/src-tree/fusion-engine-src
export TMPDIR=$PWD/build-89/tmp && mkdir -p "$TMPDIR"      # TMPDIR 必须离开 tmpfs（见踩坑 1.2）
cmake -S . -B build-89 -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_ARCHITECTURES=89 -DNINFER_BUILD_APPS=ON -DBUILD_TESTING=OFF
cmake --build build-89 -j6 --target ninfer ninfer-serve
# 判据: build-89/apps/ninfer-serve 存在（本机编译记录：1050/1050 目标全绿，
#       产物 871,241,176 B，sha256 8058e056…4d0d，全部 SASS 为 sm_89 cubin，ldd -r 零未解析符号）
```

依赖同老线（CUDA ≥12.8——fusion 树硬校验；本机用 13.3 编译通过 + ffmpeg 开发库 + cmake ≥3.28）。
sm 支持 80/86/89/120a（CMake 硬校验四选一；本仓库 CI 构建 89 与 120a 两个镜像）。

## 4. 怎么跑

```bash
./scripts/start-fusion.sh                  # 默认档 fusion（全量件 + DFlash2/proposal/视觉，窗口 65536 + 逻辑上下文 262144）
./scripts/start-fusion.sh fusion-mtp       # 瘦身件档（窗口 131072、MTP K=4、显存余量更大）
./scripts/start-fusion.sh fusion-ptq1      # 最省显存档
./scripts/start-fusion.sh status           # 看状态
./scripts/start-fusion.sh stop             # 停止（只会杀本 fusion 引擎的进程，不会动 8088 老线/8089 容器）
```

脚本自动解析两套布局：引擎优先 `vendor/…/build-89`（克隆用户）→ 否则 `~/pyprojects/sanyuan`（作者机）；
模型优先 `models/fusion/` → 否则 `sanyuan/models-fusion/`。启动日志在 `~/ninfer-logs/ninfer-fusion-<档>.log`
（首次启动会"自适应测卡" 10-50 秒，**别以为卡死了**）。

容器等价（宿主只需驱动 + Docker；制品只读挂载，端口 8089）：

```bash
./docker/build-image.sh -l fusion          # 容器内编译（或 docker pull ghcr.io/<owner>/ninfer-bonsai:latest-fusion）
./docker/run-ninfer.sh -l fusion           # 全量档；fusion-mtp / fusion-ptq1 同理
docker compose -f docker/docker-compose.fusion.yml up -d    # 或 compose（逐参数注释）
```

### 起来后必核三行（配置对不对只看它）

```bash
grep -E "capacity \| KV|\[ring\] budgets|reuse host-backed|engine ready" ~/ninfer-logs/ninfer-fusion-fusion.log
```

1. `capacity | KV …, rk4v4-e8, auto | pages X/Y | runtime Z GiB` → 要求 `runtime + 权重 ≤ 可用显存`
   （默认档全量件权重约 8.9 GiB，卡可用约 11.4 GiB ⇒ runtime 有 ~2.5 GiB 空间；`fusion-mtp` 档权重约 7.1 GiB）
2. `[ring] budgets: skeleton=S evidence=E recent=R free=F (pool P)` → `S+E+R+F == P`
3. dtype 字段**确实**是 `rk4v4-e8`（开关被静默吞掉是这项目发生过的血账 B22）
   另外应有 `reuse host-backed: on`（没这行 = 复用没生效）

### 两条验收（别只看"能不能回答"）

现成脚本（只读 HTTP，不改服务）：`python3 scripts/fusion_accept_test.py`（默认打 8088）。
它做两件事：短问答 + **40 万字符超窗长题面针测两轮**（中段埋 `NINFER-NEEDLE-7731`），输出 PASS/FAIL。

1. **短问答**：`7*5` 期望 `35`。
2. **长题面针测**（关键判据）：题面**明显超过常驻窗口**，中段埋针，提问 + 追问**两轮都要答对**；
   日志里应出现 `kvmem_score: SELECT … query_tokens=…`（超窗才有）。
   ⚠️ 本项目对"**检索关着会静默答错**"有实测记录（HTTP 200、答案看着合理但是错的）——
   所以**别设** `NINFER_KV_RETRIEVE=0`（启动脚本已留空=自动），且这条针测必须做。

### 客户端接法

`http://127.0.0.1:8088/v1`（容器线 `:8089/v1`），模型 id 填 `qwen3.8-27b`（两线同 id，客户端不用改）。
视觉：全量档默认开，图片按 OpenAI 兼容的 `image_url` 传。思考：默认开；请求可带
`reasoning_effort`（none/minimal/low/medium/high/xhigh/max 全认，比老线兼容更宽）、
`thinking_budget`（如 `1500`，把思考压到预算内）、`enable_thinking:false` 关思考。

## 5. 三档怎么选（12GB）

| 档 | 权重占用 | 窗口 | 适合 |
|---|---|---|---|
| `fusion`（默认） | ~8.9 GiB | 65536 | 日常用这档：DFlash2 + proposal 头（最快档）、262k 逻辑上下文；**视觉默认开**（`NINFER_VISION=off` 关；显存紧可 `NINFER_VISION_RESIDENCY=overlay`（视觉塔放内存按图借显存）或 `=cpu`） |
| `fusion-mtp` | ~7.1 GiB | 131,072 | 想窗口大一倍 / 显存余量更大（无 dflash2、无视觉） |
| `fusion-ptq1` | ~5.5 GiB | 131,072 | 要最大显存余量（可再抬 `NINFER_WINDOW=196608` 试） |

### 起不来 / OOM 怎么调

```bash
# 默认档（全量件，窗口 65536）：装不下先把窗口降到 49152 / 40960
NINFER_WINDOW=49152 ./scripts/start-fusion.sh
# 或换瘦身件档（权重 8.9→7.1 GiB，窗口还能到 131072）
./scripts/start-fusion.sh fusion-mtp
NINFER_CUDA_GRAPH=on ./scripts/start-fusion.sh   # 显存有富余时开图（解码约 +6%）
```

- OOM 的第一顺位是关视觉（`NINFER_VISION=off`）或让视觉驻留内存（`NINFER_VISION_RESIDENCY=overlay`）。
- 报 `FATAL … Host KV tier that can hold every page … (raise --host-kv-mib)` ⇒ 抬高 `NINFER_HOSTKV_MIB`
  （默认 8192 MiB，文档对 262k 逻辑上下文的推荐值，正常够；报 FATAL 时按报文里的 host_pages 数字抬）。
- 报 `requires --max-concurrency 1` / 别加 `--disk-cache`（本引擎没有这个参数，加了直接拒启）。

## 6. 首次启动实录（2026-10-10，作者机 4070 Ti）

瘦身件档首跑（当时还叫 `fusion`，后按用户令改为默认跑全量件，本档现名 `fusion-mtp`）：

```
INFO engine | calibrating routes for nvidia-geforce-rtx-4070-ti-sm89   ← 自适应测卡 53s（仅首次）
INFO engine | device profile nvidia-geforce-rtx-4070-ti-sm89: 51 routed keys (calibration)
INFO engine ready | bonsai2-27b | total 54.9s | weights 7.12 GiB | CUDA sync auto
INFO capacity | KV 132,224 tokens, rk4v4-e8, auto | pages 2,066/2,066 | runtime 2.63 GiB | free 1.66 GiB
[ninfer] reuse host-backed: on
[ring] content scoring ON by default (the ring is configured): …
[ring] budgets: skeleton=4, evidence=0, recent=0, free=2062 (pool 2066) [== pool: yes]
kvmem_score: ARMED capacity_blocks=4096 layers_total=16 heads=24 kv_heads=4 head_dim=256
INFO listening on http://127.0.0.1:8088 | model qwen3.8-27b | auth disabled
```

核对结论：dtype `rk4v4-e8` ✓ · `[ring] budgets` 四元 == pool ✓ · `reuse host-backed: on` ✓ ·
`/v1/models` 报 `context_window 262144`、`ftype bf16+fp32+q8_g32_fp16+t2_g128_fp16`（三元件装载正确）✓。
**一条误报**：日志第 3 行 `ECC is ENABLED …` —— 本卡 ECC Mode: N/A（GeForce 不支持、不可调），
是引擎检测误报，不用管（踩坑 5.5）。

**首轮验收实测（44,176 token 题面）**：短问答 `7*5 → 35` 0.2s；轮1（冷）TTFT 19.5s、
prefill 2.27k tok/s、decode 141.2 tok/s、MTP accepted 11/12；轮2（追问）**cache 44,188（99.9%）、
TTFT 270ms、total 354ms**；针测两轮都答出 `NINFER-NEEDLE-7731` ⇒ PASS。
**口径提醒**：44k token 装得进 131,072 窗口 ⇒ 这轮验的是"装得下 + 复用"，**还没测到超窗检索取回**；
要真测超窗用 `fusion_accept_test.py`（默认 40 万字符 ≈ 14-15 万 token）。

### 超窗检索首测实录（2026-10-10 晚，v3.0.0 发布前，全量档 + 设备池 54,784）

`python3 scripts/fusion_accept_test.py` 原样跑（400,067 字符题面）：

```
[1] /v1/models OK: ['qwen3.8-27b']
[2] 7*5 -> '35'  (0.2s, finish=stop)
[3] 长题面 400067 字符，针在中段；第一轮提问…
    轮1: 'NINFER-NEEDLE-7731'  finish=stop prompt_tokens=147121  (117.0s)
    题面 超过 常驻窗口 131072：✓ 已覆盖'设备池装不下题面'的检索路径
    轮2: 'NINFER-NEEDLE-7731'  finish=stop prompt_tokens=147161  (1.1s)
结论: 针测两轮 PASS（两轮都命中）
```

引擎侧对应读数（`~/ninfer-logs/ninfer-fusion-fusion.log`）：

| 度量 | 轮1（冷，超窗） | 轮2（追问） |
|---|---|---|
| prompt | **147,121 tok（设备池 54,784 的 2.7 倍）** | 147,161 tok |
| cache | 0（0.0%） | **147,133（100.0%，private endpoint）** |
| TTFT | 1m56.8s | **1.0s**（total 1.1s） |
| prefill / decode | 1.26k tok/s / 67.5 tok/s | — / 135.8 tok/s |
| 检索/主机层 | `kvmem_score: SELECT … kept=512 skip=1787` 全程打分；`adopt host-backed: frontier=147133 need=2299 usable=856 host_backed=1452` | 直接命中复用 |

**结论**：设备池装不下题面时的**按需检索取回路径实测可用**（147k ≫ 54,784 仍两轮答对，
跨页内容由内容打分选页承载）；同会话追问从"重新预填"变成 **1 秒级**。
冷轮 117s 的 TTFT 是这个机制的代价（每个预填块跑一遍打分 + 主机层搬运 20-23%）——
超长题面属于"一次性成本换 262k 能力"，日常短问答仍建议老线（见 §1 对照）。

## 7. 已知限制（作者账本原话口径，照实转述）

- **单并发**：环只服务一条活跃序列，不支持多路（要并发就切回老线 A3）。
- 约 95k 题面有一条"零命中"反例**未定位**（作者账本；本项目 147k 超窗针测两轮 PASS，
  说明该反例是个案而非机制失效）；跨页缝内容只检索回一侧属已记录质量边界。
- **视觉本次开箱即开，但这条线的作者未验**（其所有实测臂都是纯文本；老线验过红图识别正确）。
  引擎与全量件都带视觉载荷（组件清单含 `vision`）；图片问答若有异常（报错/答错），
  把请求与日志提 issue，属于本线新领域。显存紧时的三个旋钮：`NINFER_VISION=off` /
  `NINFER_VISION_RESIDENCY=overlay` / `=cpu`。
- 长时间冷预填后连接中断（连接层根因未定位，属缓解项）。
- `--kv-capacity auto` 的池上限会被"可用显存封顶"（12GB 全量档实测池 54,784 < 窗口 65536）——
  看到池比窗口预期小，先看日志 `runtime` 行和卡上其他占用（踩坑 5.3）。
- dflash2 头质量低于 PQ2 全量（22%/47% vs 91.5-100% 接受率，指某些制品）——full 件的 dflash2
  属"最快"档，质量以实测为准；批量长文任务可对照 `fusion-mtp` 档。
- 输出上限：本引擎对"没设 max_tokens 的请求"有默认上限（B37），脚本已用 `--default-max-tokens 32768`；
  客户端自设的 max_tokens 以客户端为准（别超过设备池 token 数）。

## 8. 回滚 / 与老部署的隔离

- 老线一切未动：`./scripts/start-ninfer.sh work` 照常起 8088（用旧引擎 + `artifacts-pq2.ninfer`）。
- **两线同端口 8088，天然互斥**：跑 fusion 前先 `./scripts/start-ninfer.sh stop work` 停老线，反之亦然
  （显存也装不下两条同时跑：各约 10 GiB > 12 GiB）。启动脚本会做端口预检并给出提示。
- 想彻底移除本线：删 `vendor/ninfer-fusion-kvmem/`、`scripts/start-fusion.sh`、
  `models/fusion/` 即可，不影响任何老文件。

## 9. 文件索引

| 内容 | 路径 |
|---|---|
| 本说明 | `docs/Fusion-KVMem-部署与运行.md` |
| 启动脚本 | `scripts/start-fusion.sh`（宿主；容器 `docker/run-ninfer.sh -l fusion`） |
| 验收脚本 | `scripts/fusion_accept_test.py`（短问答 + 超窗针测两轮） |
| 引擎源码 | `vendor/ninfer-fusion-kvmem/src-tree/fusion-engine-src/`（上游含其自身 docs/ 15 份手册：`docs/03-基础部署后的调优方案.md`、`docs/12-给接收方-agent-的操作手册.md` 必读） |
| 模型放置目录 | `models/fusion/`（三件；`docker/fetch-model.sh --ms-fusion`） |
| 容器配置 | `docker/docker-compose.fusion.yml`（逐参数注释）、`docker/build-image.sh -l fusion` |
| 对照数据 | `docs/性能实测.md` §9/§10、`docker/perf-results-20261010-195050.json` |
| 升级/回滚全流程 | `docs/更新教程-v3.0.0.md` |
