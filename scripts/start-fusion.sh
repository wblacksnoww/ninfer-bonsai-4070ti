#!/usr/bin/env bash
# =============================================================================
# NInfer Fusion KVMem · 三元 Bonsai-2-27B 启动脚本（仓库版，2026-10-10）
#
# 这是什么：160 行内说完 —— 仓库 vendor/ninfer-fusion-kvmem（上游 1314521gjy/
#   ninfer-fusion-kvmem @ acba3d4，KVMem 环线）的 Linux 自编译引擎启动器。
#   · 与老生产线（A3 引擎 + artifacts-pq2.ninfer，scripts/start-ninfer.sh）完全独立。
#   · 本线固定端口 8088（与老生产线同端口：两线互斥，同时只能跑一个）。
#   · 核心能力：设备 KV 池可以小于逻辑上下文 —— 长上下文 = 常驻窗口（显存）
#     + 主机层（内存）+ 按需检索。逻辑上下文可开到 262144，设备池只花 ~2-3 GiB。
#   · 硬约束（本版引擎的设计）：
#       ① 只能载入 **v3 容器** 制品（models/fusion/ 下三件）；
#          老线 artifacts-pq2.ninfer / bonsai2_27b_ptq1.ninfer 是 v2 容器，本引擎直接拒载。
#       ② 只支持 --max-concurrency 1（环只服务一条活跃序列），--max-shared-prefixes 0 必须带。
#       ③ rk* 系 KV 精度（12GB 用 rk4v4-e8，质量代价实测 +0.30%）。
#       ④ 别设 NINFER_KV_RETRIEVE=0（超池时会静默答错）；留空即由引擎自动给检索预算。
#
# 路径解析（两套布局都能用，先命中先赢；都可用环境变量覆盖）:
#   · 引擎：仓库 vendor/ninfer-fusion-kvmem/src-tree/fusion-engine-src/build-89/apps/ninfer-serve
#           （克隆用户先自编译，见下方"自编译"）→ 否则 ~/pyprojects/sanyuan 布局（作者机）。
#   · 模型：仓库 models/fusion/（fetch-model.sh --ms-fusion 可取）→ 否则 sanyuan/models-fusion/。
#
# 自编译（克隆用户首次，与文档 docs/更新教程-v3.0.0.md 同款；宿主需 CUDA 13.1+ 与 ffmpeg 开发库）:
#   cd vendor/ninfer-fusion-kvmem/src-tree/fusion-engine-src
#   export TMPDIR=$PWD/build-89/tmp && mkdir -p "$TMPDIR"
#   cmake -S . -B build-89 -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES=89 \
#     -DNINFER_BUILD_APPS=ON -DBUILD_TESTING=OFF
#   cmake --build build-89 -j6 --target ninfer ninfer-serve   # 判据: build-89/apps/ninfer-serve 存在
#
# 用法:
#   ./scripts/start-fusion.sh [profile] [port]     # 启动（默认 profile=fusion 端口=8088）
#   ./scripts/start-fusion.sh stop   [profile]     # 停止
#   ./scripts/start-fusion.sh status [profile]     # 状态
#
# profile（4070 Ti 12GB + 核显显示）:
#   fusion      默认。**全量件**（8.87 GiB，text+mtp+dflash2+proposal+vision）：
#               窗口 65536、逻辑上下文 262144、rk4v4-e8、DFlash2 + proposal 头（最快档）。
#               **视觉默认开**（与老线同惯例，NINFER_VISION=off 可关）；显存紧：
#               约 8.9 GiB 权重 + ~1.4 GiB 运行时 + 视觉约 0.4 GiB，装不下就关视觉/降窗口。
#   fusion-mtp  瘦身件（7.13 GiB，text+mtp）：窗口 131072、MTP K=4。
#               显存余量更大、窗口大一倍；**该制品没有视觉塔**（设 --vision 会拒启，脚本自动不开）。
#   fusion-ptq1 PTQ1 制品（5.96 GiB 文件 / 5.52 GiB 常驻）—— 最省显存档，PTQ1_FAST 开；同样无视觉。
#
# 环境变量（可选）:
#   NINFER_THINKING=off           关思考（加 --no-thinking）
#   NINFER_PRESERVE_THINKING=on   保留历史思考（agent 长会话省算力，但上下文膨胀）
#   NINFER_CUDA_GRAPH=on          开 CUDA Graph（默认关；显存富裕时解码约 +6%）
#   NINFER_VISION=off             关视觉（仅 fusion 全量档有视觉，默认开）
#   NINFER_VISION_RESIDENCY=overlay|cpu  视觉驻留方式（显存紧时用）：
#                                 overlay=视觉塔放主机内存、按图借显存；cpu=纯 CPU 跑视觉
#   NINFER_WINDOW=N               覆盖常驻窗口（如 65536 / 98304 / 196608）
#   NINFER_MAX_TOKENS=N           覆盖 --default-max-tokens（默认 32768）
#   NINFER_HOSTKV_MIB=N           覆盖 --host-kv-mib（默认 8192；报 FATAL 点名 host_pages 时抬高）
#   NINFER_THINK_BUDGET=N         服务端默认思考预算（不设=不限；客户端不带 thinking_budget 时
#                                 可防"思考吃满输出、正文为空"，项目账本 B24 实测口径）
#
# 起不来怎么调（见 docs/Fusion-KVMem-部署与运行.md）:
#   OOM / 启动被拒 → 先关视觉：NINFER_VISION=off ./scripts/start-fusion.sh
#                    或视觉改驻留内存：NINFER_VISION_RESIDENCY=overlay ./scripts/start-fusion.sh
#                    或降窗口：NINFER_WINDOW=49152 ./scripts/start-fusion.sh（瘦身档反过来：默认 131072，可降 98304/65536）
#   主机层装不下 → 报 FATAL 点名 host_pages ⇒ 抬高 --host-kv-mib（NINFER_HOSTKV_MIB=…）
# =============================================================================
set -uo pipefail

LOGDIR="$HOME/ninfer-logs"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANYUAN="$HOME/pyprojects/sanyuan"                 # 作者机布局；克隆用户可忽略（自动走仓库内路径）

# 引擎树：优先仓库内 vendor 自编译产物，其次 sanyuan 布局
ENG_REPO="$REPO_ROOT/vendor/ninfer-fusion-kvmem/src-tree/fusion-engine-src"
ENG_SANYUAN="$SANYUAN/ninfer-fusion-kvmem/src-tree/fusion-engine-src"
if [[ -x "$ENG_REPO/build-89/apps/ninfer-serve" ]]; then
    ENG_DIR="$ENG_REPO"
else
    ENG_DIR="$ENG_SANYUAN"
fi
ENGINE="$ENG_DIR/build-89/apps/ninfer-serve"

# 模型目录：优先仓库 models/fusion/（含 v3 全量件），其次 sanyuan/models-fusion/
MODEL_REPO="$REPO_ROOT/models/fusion"
MODEL_SANYUAN="$SANYUAN/models-fusion"
if [[ -f "$MODEL_REPO/Ternary-Bonsai-2-27B-ninfer-v3.ninfer" ]]; then
    MODEL_DIR="$MODEL_REPO"
else
    MODEL_DIR="$MODEL_SANYUAN"
fi

M_MTONLY="$MODEL_DIR/Ternary-Bonsai-2-27B-ninfer-v3-mtponly.ninfer"
M_FULL="$MODEL_DIR/Ternary-Bonsai-2-27B-ninfer-v3.ninfer"
M_PTQ1="$MODEL_DIR/bonsai2_27b_ternary_ptq1_native_mtp.ninfer"

HOSTKV_MIB="${NINFER_HOSTKV_MIB:-8192}"   # 主机层 KV 预算（RAM，非显存；8192=文档对 262144 逻辑上下文的推荐值）

PROFILE="${1:-fusion}"
ACTION="start"
if [[ "${1:-}" == "stop" || "${1:-}" == "status" ]]; then
    ACTION="$1"; PROFILE="${2:-fusion}"
    PORT="${3:-8088}"
else
    PORT="${2:-8088}"
fi

# —— 可选开关（都与老脚本同惯例：环境变量注入，默认给生产口径）——
THINKING_FLAG=""
[[ "${NINFER_THINKING:-on}" == "off" ]] && THINKING_FLAG="--no-thinking"
PRESERVE_FLAG=""
[[ "${NINFER_PRESERVE_THINKING:-off}" == "on" ]] && PRESERVE_FLAG="--preserve-thinking"
GRAPH_FLAG="--no-cuda-graph"                       # 默认关图（12GB 显存紧；开图约 +6% 解码）
[[ "${NINFER_CUDA_GRAPH:-off}" == "on" ]] && GRAPH_FLAG=""
MAXTOK="${NINFER_MAX_TOKENS:-32768}"
TBUDGET_FLAG=""
[[ -n "${NINFER_THINK_BUDGET:-}" ]] && TBUDGET_FLAG="--default-thinking-budget ${NINFER_THINK_BUDGET}"
# 视觉：只有 fusion（全量件）带视觉塔 ⇒ 只有该档给 --vision，默认开（NINFER_VISION=off 关）；
# 瘦身件/PTQ1 件没有视觉塔，给了会拒启，所以恒不给
VISION_FLAG=""
if [[ "$PROFILE" == "fusion" && "${NINFER_VISION:-on}" != "off" ]]; then
    VISION_FLAG="--vision"
    [[ -n "${NINFER_VISION_RESIDENCY:-}" ]] && VISION_FLAG="$VISION_FLAG --vision-residency ${NINFER_VISION_RESIDENCY}"
elif [[ "$PROFILE" != "fusion" && "${NINFER_VISION:-on}" != "off" && "$ACTION" == "start" ]]; then
    echo "提示: [$PROFILE] 制品没有视觉塔，忽略 NINFER_VISION（视觉仅 fusion 全量档可用）" >&2
fi

PIDFILE="$LOGDIR/ninfer-fusion-$PROFILE.pid"
LOGFILE="$LOGDIR/ninfer-fusion-$PROFILE.log"
mkdir -p "$LOGDIR"

# 输出: 制品|窗口|引擎参数|环境变量(空格分隔的 K=V)
profile_spec() {
    local win="${NINFER_WINDOW:-}"
    local common="--max-context 262144 --kv-capacity auto --kv-headroom-mib 1024 --kv-dtype rk4v4-e8 --prefill-chunk 512 --host-kv-mib $HOSTKV_MIB --max-concurrency 1 --max-shared-prefixes 0 --default-max-tokens $MAXTOK"
    local envs="NINFER_KV_RING=1 NINFER_HOST_PAGEABLE=1 NINFER_KV_REUSE_HOSTBACKED=1"
    case "$PROFILE" in
        fusion)
            echo "$M_FULL|${win:-65536}|$common --spec dflash2 --lm-head-draft --draft-tokens 4 --gdn-state-fp16|$envs" ;;
        fusion-mtp)
            echo "$M_MTONLY|${win:-131072}|$common --spec mtp --draft-tokens 4 --gdn-state-fp16|$envs" ;;
        fusion-ptq1)
            echo "$M_PTQ1|${win:-131072}|$common --spec mtp --draft-tokens 4 --gdn-state-fp16|$envs NINFER_TERNARY_PTQ1_FAST=1" ;;
        *)  return 1 ;;
    esac
}

is_running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

do_start() {
    local spec ART WIN ARGS ENVS
    spec="$(profile_spec)" || { echo "未知 profile: $PROFILE (fusion|fusion-mtp|fusion-ptq1)"; exit 1; }
    IFS='|' read -r ART WIN ARGS ENVS <<< "$spec"
    [[ -x "$ENGINE" ]] || { echo "错误: 引擎未编译: $ENGINE"; echo "  克隆用户先自编译（本脚本头部注释有命令）；作者机检查 sanyuan 布局"; exit 1; }
    [[ -f "$ART" ]] || { echo "错误: 制品不存在: $ART"; echo "  请先下载 v3 制品（./docker/fetch-model.sh --ms-fusion，或放入 $MODEL_DIR/）"; exit 1; }
    if is_running; then
        echo "[$PROFILE] 已在运行 (pid $(cat "$PIDFILE")), http://127.0.0.1:$PORT/v1"; exit 0
    fi
    # 端口预检（8088 与老生产线同端口，两线互斥）—— 比让引擎 bind 失败再猜要清楚
    if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
        echo "错误: 端口 $PORT 已被占用，本线起不来。"
        echo "  若占用者是 8088 老生产线：先停它 —— ./scripts/start-ninfer.sh stop work"
        echo "  若占用者是别的 fusion 实例：./scripts/start-fusion.sh stop \$profile"
        exit 1
    fi
    echo "[$PROFILE] 引擎: $ENGINE"
    echo "  制品: $ART"
    echo "  窗口: $WIN  参数: $ARGS $THINKING_FLAG $PRESERVE_FLAG $GRAPH_FLAG $VISION_FLAG"
    echo "  环境: $ENVS NINFER_KV_WINDOW=$WIN"
    (
        cd "$ENG_DIR" || exit 1
        export TMPDIR="$ENG_DIR/build-89/tmp"; mkdir -p "$TMPDIR"
        export NINFER_KV_WINDOW="$WIN" NINFER_KV_RETRIEVE=
        for kv in $ENVS; do export "$kv"; done
        nohup "$ENGINE" "$ART" \
            --host 127.0.0.1 --port "$PORT" --model-id qwen3.8-27b \
            $ARGS $THINKING_FLAG $PRESERVE_FLAG $GRAPH_FLAG $TBUDGET_FLAG $VISION_FLAG \
            > "$LOGFILE" 2>&1 & echo $! > "$PIDFILE"
    )
    echo -n "  等待就绪（首次会自适应测卡 10-50s，请勿中断）"
    for _ in $(seq 1 300); do
        if curl -s -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
            echo " 就绪"
            echo "  OpenAI 接口: http://127.0.0.1:$PORT/v1  (模型 id: qwen3.8-27b)"
            echo "  日志: $LOGFILE | 停止: $0 stop $PROFILE"
            echo "  ★ 必核三行: capacity | KV … 行 / [ring] budgets 行 / dtype 确为 rk4v4-e8 —— 见 grep 提示"
            grep -E "engine ready|capacity \| KV|\[ring\] budgets|reuse host-backed|listening on" "$LOGFILE" | tail -8
            exit 0
        fi
        if ! is_running; then
            echo " 启动失败:"; tail -12 "$LOGFILE"; rm -f "$PIDFILE"; exit 1
        fi
        echo -n "."; sleep 1
    done
    echo " 超时(300s), 日志: $LOGFILE"; exit 1
}

do_stop() {
    if is_running; then
        kill "$(cat "$PIDFILE")" 2>/dev/null && rm -f "$PIDFILE"
        echo "[$PROFILE] 已停止"
    else
        rm -f "$PIDFILE"; echo "[$PROFILE] pidfile 无效/未在运行"
    fi
    # 兜底：只清"本 fusion 引擎路径"的残留进程，绝不误伤 8088 老线/8089 容器线
    local pids
    pids=$(pgrep -f "$ENGINE" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        for _ in $(seq 1 15); do
            pids=$(pgrep -f "$ENGINE" 2>/dev/null || true)
            [[ -z "$pids" ]] && break
            kill $pids 2>/dev/null; sleep 1
        done
        echo "  显存已释放"
    fi
}

do_status() {
    if is_running; then
        echo "[$PROFILE] 运行中 (pid $(cat "$PIDFILE"))"
        curl -s -m 3 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | head -c 200; echo
    else
        echo "[$PROFILE] 未在运行"
    fi
}

case "$ACTION" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    *) echo "用法: $0 [fusion|fusion-mtp|fusion-ptq1] [port] | stop|status [profile]"; exit 1 ;;
esac
