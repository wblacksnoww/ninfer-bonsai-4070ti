# Docker 容器化部署（容器内编译 + 国内源 + 双线）

宿主机只要求: **x86_64 Linux + NVIDIA 驱动(r580+，支持 CUDA 13.x) + Docker + nvidia-container-toolkit**。
无需在宿主机安装 CUDA Toolkit、GCC、FFmpeg 开发库 —— 编译与依赖全部在容器内完成，
CUDA 用户态库随镜像走，显卡驱动用宿主的（NVIDIA 容器运行时透传，性能与宿主直跑无差别）。

**双线镜像（v3.0.0，兼容新旧模型与算法；引擎与制品硬校验成对使用）**：

| 线 | 引擎树 | 制品（容器格式） | 镜像 tag |
|---|---|---|---|
| 老线（默认 `-l old`） | `vendor/ninfer-4090w-ternary-a3`（A3） | `models/artifacts-pq2.ninfer`（v2） | `…cuda13.3-arch89` / `-arch120a` |
| fusion KVMem 环线（`-l fusion`） | `vendor/ninfer-fusion-kvmem`（@ acba3d4） | `models/fusion/` 三件（v3） | `…cuda13.3-arch89-fusion` / `-arch120a-fusion` |

## 四个脚本

| 脚本 | 作用 |
|---|---|
| `build-image.sh` | 收集本地引擎源码 → `docker build`（容器内编译 `ninfer` / `ninfer-serve`）；`-l old\|fusion` 选线 |
| `run-ninfer.sh` | 启动服务容器；`-l old \| fusion \| fusion-mtp \| fusion-ptq1` 四档（老线默认档 64k、端口 8089 与 v2.0.0 完全一致） |
| `fetch-model.sh` | 制品校验/落位：`--ms`（老线 v2）/ `--ms-fusion [full\|mtponly\|ptq1]`（v3 三件）/ `--hf`；SHA256 全验 |
| `test-serving.sh` | 冒烟测试: `/v1/models` + 一次真实生成（关思考、temp=0） |

```bash
./docker/build-image.sh                    # 老线镜像（首次含基础镜像下载，见下表）
./docker/build-image.sh -l fusion          # fusion 镜像（tag …-arch89-fusion）
./docker/fetch-model.sh --ms               # 老线 v2 制品（7.8GB）
./docker/fetch-model.sh --ms-fusion        # fusion v3 三件（约 22GB；或 full|mtponly|ptq1 单件）
./docker/run-ninfer.sh                     # 老线 work 档；-c 114688（long 档）/ -p 8088（自定端口）
./docker/run-ninfer.sh -l fusion           # fusion 全量档（窗口 65536 + 逻辑上下文 262144）
./docker/test-serving.sh                   # 冒烟（默认 8089）
./docker/run-ninfer.sh stop                # 停止（fusion 加 -l fusion）
```

不在 docker 组时脚本自动改用 sudo。`-a 120a` 由 CI 实测构建（两条线都支持：老线 A3 树 device.h
含 SM120；fusion 树 CMake 硬校验允许 89/120a）。

## 方式 B：docker compose（参数全部可见可改）

两份 compose 与 `run-ninfer.sh` 二选一（容器名不同：`ninfer-serve` / `ninfer-fusion-serve`，勿同时用）：

```bash
docker compose -f docker/docker-compose.yml up -d            # 老线（每个启动参数一行中文注释）
docker compose -f docker/docker-compose.fusion.yml up -d     # fusion 环线（逐参数注释 + 环线约束说明）
docker compose -f docker/docker-compose.fusion.yml logs -f  # 跟随日志
docker compose -f docker/docker-compose.fusion.yml down     # 停止并移除
```

`docker-compose.yml` 里**每个启动参数都带一行中文注释**，手改即可：
制品路径映射（volumes 左侧）、宿主端口（ports 左侧）、上下文档位（work 65536 /
long 114688 / fast 8192）、MTP K（draft-tokens，3 最优上限 5）、并发路数、
思考开关（删 `--no-thinking` 行首注释）、GPU 卡号（count）。
`docker-compose.fusion.yml` 同风格，另含环线三件套：**v3 制品映射、rk4v4-e8 / 主机层等环线参数、
NINFER_KV_RING 等必需环境变量**（改档前先读文件头部的硬约束小节）。

## 需要下载的镜像（构建前拉好）

| 镜像 tag | 用途 | 压缩体积(amd64) |
|---|---|---|
| `nvidia/cuda:13.3.0-devel-ubuntu24.04` | 构建层（含 nvcc） | ~3.5GB（cudnn-devel 实测 3.87GB 作参照） |
| `nvidia/cuda:13.3.0-runtime-ubuntu24.04` | 运行层（最终镜像底座） | ~0.3GB（cudnn-runtime 实测 1.85GB） |

- **不要选** `cudnn-` 变体（多带 cuDNN，引擎用不上）；`base-` 变体没有编译工具
- 国内直连慢: 用镜像站检索确认后拉取，或 daocloud 前缀
  `docker pull docker.m.daocloud.io/nvidia/cuda:13.3.0-devel-ubuntu24.04`
  然后 `docker tag` 回标准名；构建完 `sudo docker builder prune` 可清编译缓存
- 磁盘预留 ~15GB（镜像 + 构建缓存）
- **GeForce 前向兼容库已在 Dockerfile 运行时层删除**（`/usr/local/cuda*/compat`）：
  不删的话部分环境启动即 `cudaErrorCompatNotSupportedOnDevice`（踩坑 5.8，两线共用）

## CUDA 版本: 13.1 还是 13.3？

- 老线引擎 `CMakeLists.txt` 硬校验 **CUDA >= 13.1**；fusion 树硬校验 **>= 12.8** —— 13.1.2 与 13.3.0 都能编
- 本镜像默认 **13.3.0** —— 对齐官方《兜底方案-从源码自己编译》依赖表与本机 549/549 实测编译链
- 引擎树内官方 Dockerfile：老线钉 13.1.2、fusion 钉 13.1.2，需要时切回: `./docker/build-image.sh -b nvidia/cuda:13.1.2`
- KNOWN_ISSUES 里"CUDA 13.3 崩溃"是 **llama.cpp 线**（PrismML-Eng/llama.cpp #222）的问题，与 NInfer 引擎无关

## 模型制品：.ninfer 的来路与获取（能不能自己打包？）

`.ninfer` 是引擎容器格式（权重 + MTP/DFlash2 草稿头 + 元数据），由**转换器**从模型 checkpoint 生成
——它不是编译产物：编译只产出引擎二进制（已烤进镜像），制品按需获取、只读挂载进容器。
**v2 与 v3 两代容器互不通用**（引擎硬校验，见踩坑 5.1）：老线用 v2、fusion 环线用 v3。

| 路线 | 下载量 | 谁来做 | 12GB 卡可用？ |
|---|---|---|---|
| ① **魔搭镜像仓库（推荐）** | v2 7.8GB / v3 三件约 22GB（国内直连） | `fetch-model.sh --ms`（v2）/ `--ms-fusion`（v3） | ✅ |
| ② 交付包/网盘 | v2 7.8GB（夸克）；v3 三件（"模型包-20260930"夸克） | 沈三殊字节级重打包 | ✅ |
| ③ HF 现成制品 `neroued/Qwen3.8-27B-NInfer` | 20.4GB（`fetch-model.sh --hf`，走 hf-mirror） | 原引擎作者 Neroued 直转发布 | ❌ 权重 20.4GB > 12GB 显存（≥24GB 卡用） |
| ④ 自转·直转 | 底座 ~52GB（魔搭 Qwen/Qwen3.8-27B）+ DFlash2 3.6GB | 你自己：老线 `vendor/ninfer-4090w-ternary-a3/tools/convert/qwen3_8_27b` | ❌ 产出同为 20.4GB |
| ⑤ 自转·GGUF | 三元 GGUF 6.7GB（魔搭 prism-ml）+ 底座 + 模板 | 你自己：`vendor/shensanshu-guide/tools/pack.py`（产出 v2 口径 ~7-9GB） | ✅ |

> v3 三件的字节数与 SHA256 记录在 `fetch-model.sh`；与官方内测包清单逐件核对过（见更新教程 §2）。
> 三元件（PQ2 三元）不在官方 v2→v3 升级工具支持列表内，**别试图就地升级**，直接取 v3 成品。

## 适配显卡范围（能否"适配任何显卡"？）

容器化解决的是**软件栈**可移植，不改变引擎代码的显卡支持范围：

| 显卡 | 老线 | fusion 环线 | 构建参数 |
|---|---|---|---|
| RTX 40 系（Ada: 4090/4080/4070/4060 及 L40/L4） | ✅ | ✅（本机实跑验证） | `-a 89`（默认） |
| RTX 50 系（Blackwell: 5090/5080/5070） | ✅（A3 树，CI 实测） | ✅（CMake 支持 120a，CI 构建；实卡未验） | `-a 120a` |
| RTX 30 系及更早 / AMD / Intel | ❌ | ❌ | 引擎限制，与容器无关 |

- 4070 Ti 本地构建建议 `-s 60`（SM 数，仅老线树有该参数）；CI 通用镜像用架构默认值
- 老卡（SM 75~86）走官方交付包**超低显存档**的 llama.cpp 线（SM 75~120a），不是本容器
- 同代不同显存只影响档位: 老线 12GB → work 64k / long 112k；fusion 环线逻辑上下文固定 262144，
  常驻窗口按档（全量 65536 / 瘦身 131072），设备池由 `--kv-capacity auto` 按显存自适应

## 自动打包（GitHub Actions）

`.github/workflows/docker-build.yml`：push 触达 `docker/` 或 `vendor/` 时，在 GitHub 云端
自动完成"容器内编译 + 发镜像"，**双线四腿矩阵**（89/120a × 老线/fusion），产物发布到 GHCR：

```
ghcr.io/<owner>/ninfer-bonsai:cuda13.3-arch89            # 老线，RTX 40 系
ghcr.io/<owner>/ninfer-bonsai:cuda13.3-arch120a          # 老线，RTX 50 系
ghcr.io/<owner>/ninfer-bonsai:cuda13.3-arch89-fusion     # fusion 环线，RTX 40 系
ghcr.io/<owner>/ninfer-bonsai:cuda13.3-arch120a-fusion   # fusion 环线，RTX 50 系
```

克隆本仓库的人**可以跳过本地构建**，直接拉取现成镜像：

```bash
docker pull ghcr.io/<owner>/ninfer-bonsai:cuda13.3-arch89            # 老线（RTX 40 系）
docker pull ghcr.io/<owner>/ninfer-bonsai:cuda13.3-arch89-fusion     # fusion 环线
# 拉取后照常: ./docker/run-ninfer.sh -i ghcr.io/<owner>/ninfer-bonsai:cuda13.3-arch89（fusion 加 -l fusion）
```

也可以在 Actions 页面手动触发（workflow_dispatch）。云端构建依赖 vendor/ 源码与
docker/Dockerfile，与本地 `build-image.sh` 完全同一套配方。

**NINFER_SM_COUNT（老线 A3 新增）**：编译期 SM 数镜像，`-s <n>` 传入（0=按架构默认
89→128 / 120a→170）。每张卡 SM 数不同（4070 Ti=60、4090=128、5090=170），
自定义 `NINFER_SM_COUNT` 可让发射策略与实卡精确一致；CI 通用镜像用架构默认值。
（fusion 树无此参数，`build-image.sh` 只对老线传。）

**魔搭（ModelScope）镜像仓库**：`scripts/upload-modelscope.sh` 可把本仓库（连同
`models/` 下全部制品：v2 一件 + v3 三件，约 30GB，CLI folder 上传免 git-lfs）一键镜像到魔搭
——国内克隆/下载免 GitHub 直连。

**Release 自动发布**（`.github/workflows/release.yml`）：推送 `v*` 标签时自动
构建**双线**镜像 → 推 GHCR（老线 `版本号`+`latest`、fusion `版本号-fusion`+`latest-fusion`，
老线 tag 语义与 v2.0.0 一致）→ 按谷歌开源风格模板（概述/亮点/修复/文档/升级说明/已知问题/制品）
创建 GitHub Release 并附自动提交清单。手动触发时填版本号输入框即可。

**已发布成品**：

```bash
docker pull ghcr.io/ygxiuming/ninfer-bonsai:cuda13.3-arch89            # 老线（RTX 40 系）
docker pull ghcr.io/ygxiuming/ninfer-bonsai:cuda13.3-arch89-fusion     # fusion 环线（RTX 40 系）
docker pull ghcr.io/ygxiuming/ninfer-bonsai:latest                     # 老线，跟随最新 Release
docker pull ghcr.io/ygxiuming/ninfer-bonsai:latest-fusion              # fusion 环线，跟随最新 Release
docker pull ghcr.io/ygxiuming/ninfer-bonsai:v3.0.0                     # 按版本（老线）
./docker/run-ninfer.sh -i ghcr.io/ygxiuming/ninfer-bonsai:latest       # 拉完即起
```

GitHub Release：`v3.0.0`（双线；谷歌风格模板 + 自动提交清单）；历史：`v2.0.0` / `v1.0.0`。
> ⚠ GHCR 包首次以 GITHUB_TOKEN 推送时默认**私有**：匿名拉取前请在 GitHub 网页
> → Packages → ninfer-bonsai → Package settings → 改为 Public（一次性）。

## 与宿主机直跑的关系

- 性能无差别（宿主驱动透传 + 容器内 CUDA 13.3 用户态库）
- 显存预算相同: 启动前 `nvidia-smi` 确认空闲（老线 64k 档需 ~10GB；fusion 全量档约 11.4GB）
- 制品 `.ninfer` 只读挂载不进镜像，镜像只含两个二进制与运行库
- **四方互斥**：宿主老线（8088）/ 宿主 fusion（8088）/ 容器老线（8089）/ 容器 fusion（8089）
  共用一张卡，任意时刻只能跑一条；切前停对方
- 服务状态（v3.0.0 发布时）：老线镜像沿用 v2.0.0 已验证产物（双入口冒烟 83.8 / 85.2 tok/s）；
  fusion 镜像由 CI 构建发布（本机容器实跑待验证，宿主直跑已验证）
