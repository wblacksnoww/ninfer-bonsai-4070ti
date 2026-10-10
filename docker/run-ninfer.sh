#!/usr/bin/env bash
# =============================================================================
# 以容器方式启动 NInfer OpenAI 兼容服务（宿主直跑 start-ninfer.sh / start-fusion.sh 的容器等价）
#
# 双线四档（-l，兼容新旧模型与算法；两线镜像与制品互不通用）:
#   old（默认）  老生产线：A3 引擎 + v2 制品（artifacts-pq2.ninfer），fp8 KV + MTP K=3
#   fusion      KVMem 环线 · 全量档：fusion 引擎 + v3 全量件，rk4v4-e8 + DFlash2 + 视觉
#   fusion-mtp  KVMem 环线 · 瘦身档：v3 mtponly 件，窗口 131072、MTP K=4（无视觉）
#   fusion-ptq1 KVMem 环线 · 最省显存档：v3 PTQ1 件（无视觉）
#
# 用法:
#   ./docker/run-ninfer.sh                  # 老线 work 档 64k 上下文，宿主端口 8089（与 v2.0.0 一致）
#   ./docker/run-ninfer.sh -c 114688        # 老线 long 档；fusion 线 -c 覆盖的是常驻窗口
#   ./docker/run-ninfer.sh -l fusion        # fusion 全量档（窗口 65536 + 逻辑上下文 262144）
#   ./docker/run-ninfer.sh -l fusion-mtp -p 8089
#   ./docker/run-ninfer.sh -p 8088          # 自定宿主端口（默认 8089 避让宿主服务）
#   ./docker/run-ninfer.sh -i <镜像tag>     # 指定镜像（50 系卡用 -arch120a tag；fusion 线 -archXX-fusion）
#   ./docker/run-ninfer.sh -a <制品路径>    # 指定 .ninfer 制品（默认按线取 models/ 下路径）
#   ./docker/run-ninfer.sh stop | logs | status      （加 -l 操作对应线的容器）
#
# 说明:
#   · 制品只读挂载不进镜像；容器内服务监听 8088，-p 映射到宿主
#   · 思考默认开启；NINFER_THINKING=off 整体关闭（两线一致）
#   · fusion 线专属旋钮：NINFER_VISION=off（关视觉）、NINFER_CUDA_GRAPH=on（开图约 +6%）
#   · 显存预算：老线 64k 需空闲 ~10GB；fusion 全量档约 8.9 GiB 权重 + ~2.5 GiB 运行时
#   · 与宿主线及另一条容器线互斥（共用一张卡 + 同一宿主端口 8089/8088）
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LINE="old"
CTX=""            # 老线=上下文；fusion 线=常驻窗口（空=按线取默认）
PORT="8089"
IMAGE=""
ART=""

ACTION="run"
if [[ "${1:-}" == "stop" || "${1:-}" == "logs" || "${1:-}" == "status" ]]; then
    ACTION="$1"; shift
fi
while getopts "l:a:c:p:i:" o; do case "$o" in
    l) LINE="$OPTARG" ;;
    a) ART="$OPTARG" ;;
    c) CTX="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    i) IMAGE="$OPTARG" ;;
    *) grep '^#' "$0" | sed -n '2,26p'; exit 1 ;;
esac; done

# ---- 按线设定：镜像 / 制品 / 容器名 / 就绪等待 / 引擎参数 / 环境变量 ----
DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

case "$LINE" in
    old)
        NAME="ninfer-serve"
        IMAGE="${IMAGE:-ninfer-bonsai:cuda13.3-arch89}"
        ART="${ART:-${NINFER_ARTIFACT:-$REPO_ROOT/models/artifacts-pq2.ninfer}}"
        CTX="${CTX:-65536}"
        WAIT_S=120
        ENGINE_ARGS=(--max-context "$CTX" --kv-capacity "$CTX" --kv-dtype fp8
                     --spec mtp --draft-tokens 3 --max-concurrency 1)
        ROWS_ENV="NINFER_TERNARY_SMALL_T_ROWS=16"   # A3 数值安全：rows 钉 16（上游 32 行档 PPL 缺陷）
        LINE_ENVS=(-e "$ROWS_ENV")
        ;;
    fusion|fusion-mtp|fusion-ptq1)
        NAME="ninfer-fusion-serve"
        IMAGE="${IMAGE:-ninfer-bonsai:cuda13.3-arch89-fusion}"
        case "$LINE" in
            fusion)     ART="${ART:-${NINFER_ARTIFACT:-$REPO_ROOT/models/fusion/Ternary-Bonsai-2-27B-ninfer-v3.ninfer}}"
                        CTX="${CTX:-65536}"; SPEC_ARGS=(--spec dflash2 --lm-head-draft --draft-tokens 4) ;;
            fusion-mtp) ART="${ART:-${NINFER_ARTIFACT:-$REPO_ROOT/models/fusion/Ternary-Bonsai-2-27B-ninfer-v3-mtponly.ninfer}}"
                        CTX="${CTX:-131072}"; SPEC_ARGS=(--spec mtp --draft-tokens 4) ;;
            fusion-ptq1) ART="${ART:-${NINFER_ARTIFACT:-$REPO_ROOT/models/fusion/bonsai2_27b_ternary_ptq1_native_mtp.ninfer}}"
                        CTX="${CTX:-131072}"; SPEC_ARGS=(--spec mtp --draft-tokens 4) ;;
        esac
        WAIT_S=300   # 首次启动会自适应测卡 10-50s，勿中断
        # 视觉：只有全量件有视觉塔（设 --vision 要它带塔），默认开；NINFER_VISION=off 关
        VISION_ARGS=()
        if [[ "$LINE" == "fusion" && "${NINFER_VISION:-on}" != "off" ]]; then
            VISION_ARGS=(--vision)
        elif [[ "$LINE" != "fusion" && "${NINFER_VISION:-on}" != "off" ]]; then
            echo "提示: [$LINE] 制品没有视觉塔，忽略 NINFER_VISION（视觉仅 fusion 全量档可用）" >&2
        fi
        GRAPH_ARGS=(--no-cuda-graph)   # 默认关图（12GB 显存紧）；NINFER_CUDA_GRAPH=on 开
        [[ "${NINFER_CUDA_GRAPH:-off}" == "on" ]] && GRAPH_ARGS=()
        MAXTOK="${NINFER_MAX_TOKENS:-32768}"
        HOSTKV_MIB="${NINFER_HOSTKV_MIB:-8192}"
        ENGINE_ARGS=(--max-context 262144 --kv-capacity auto --kv-headroom-mib 1024
                     --kv-dtype rk4v4-e8 --prefill-chunk 512 --host-kv-mib "$HOSTKV_MIB"
                     --max-concurrency 1 --max-shared-prefixes 0 --default-max-tokens "$MAXTOK"
                     "${SPEC_ARGS[@]}" --gdn-state-fp16 "${GRAPH_ARGS[@]}" "${VISION_ARGS[@]}")
        # 环线专属环境变量（与 start-fusion.sh 同口径；NINFER_KV_RETRIEVE 留空=自动，
        # 别设 0 —— 超池时会静默答错，项目实测血账）
        LINE_ENVS=(-e NINFER_KV_WINDOW="$CTX" -e NINFER_KV_RING=1
                   -e NINFER_HOST_PAGEABLE=1 -e NINFER_KV_REUSE_HOSTBACKED=1)
        [[ "$LINE" == "fusion-ptq1" ]] && LINE_ENVS+=(-e NINFER_TERNARY_PTQ1_FAST=1)
        ;;
    *) echo "错误: -l 只能是 old / fusion / fusion-mtp / fusion-ptq1" >&2; exit 1 ;;
esac

THINKING_FLAG=()
[[ "${NINFER_THINKING:-on}" == "off" ]] && THINKING_FLAG=(--no-thinking)

case "$ACTION" in
    stop)   $DOCKER rm -f "$NAME" && echo "[$NAME] 已停止（显存随容器释放）" ;;
    logs)   exec $DOCKER logs -f "$NAME" ;;
    status) $DOCKER ps --filter "name=$NAME" --format '{{.Names}} {{.Status}}'
            curl -s -m 3 "http://127.0.0.1:$PORT/v1/models" || echo "(接口未就绪)" ;;
    run)
        [[ -f "$ART" ]] || {
            echo "错误: 制品不存在: $ART" >&2
            if [[ "$LINE" != "old" ]]; then
                echo "  v3 制品获取: ./docker/fetch-model.sh --ms-fusion（或从网盘放入 models/fusion/）" >&2
            else
                echo "  v2 制品获取: ./docker/fetch-model.sh --ms" >&2
            fi
            exit 1; }
        $DOCKER rm -f "$NAME" >/dev/null 2>&1 || true
        if [[ "$LINE" == "old" ]]; then
            echo ">> 启动容器(老线): 镜像 $IMAGE | 上下文 $CTX | 宿主端口 $PORT"
        else
            echo ">> 启动容器($LINE): 镜像 $IMAGE | 窗口 $CTX | 宿主端口 $PORT | 首次启动会测卡 10-50s"
        fi
        $DOCKER run -d --name "$NAME" --gpus all \
            -p "$PORT:8088" \
            "${LINE_ENVS[@]}" \
            -v "$ART:/models/model.ninfer:ro" \
            "$IMAGE" \
            ninfer-serve /models/model.ninfer \
                --host 0.0.0.0 --port 8088 --model-id qwen3.8-27b \
                "${ENGINE_ARGS[@]}" "${THINKING_FLAG[@]}"
        echo -n ">> 等待就绪"
        for _ in $(seq 1 "$WAIT_S"); do
            if curl -s -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
                echo " 就绪"
                echo "  OpenAI 接口: http://127.0.0.1:$PORT/v1  (模型 id: qwen3.8-27b)"
                echo "  日志: $0 -l $LINE logs | 停止: $0 -l $LINE stop"
                if [[ "$LINE" != "old" ]]; then
                    echo "  ★ 必核: $0 -l $LINE logs | grep -E 'capacity \\| KV|\\[ring\\] budgets|reuse host-backed'"
                    echo "    要求 dtype 为 rk4v4-e8、[ring] budgets 四元 == pool、有 reuse host-backed: on"
                fi
                exit 0
            fi
            if [[ -z "$($DOCKER ps --filter "name=$NAME" -q)" ]]; then
                echo " 容器退出，日志尾部:"; $DOCKER logs --tail 20 "$NAME"; exit 1
            fi
            echo -n "."; sleep 1
        done
        echo " 超时(${WAIT_S}s)，日志: $0 -l $LINE logs"; exit 1 ;;
esac
