#!/usr/bin/env bash
# =============================================================================
# NInfer 容器镜像构建 —— 容器内完整编译（apt 走清华源，无需宿主机装 CUDA/编译器）
#
# 双线（-l）:
#   old     默认。老生产线引擎树（A3: pkg2 r12 树 + P1/P2/A3 补丁），配 v2 制品
#           （models/artifacts-pq2.ninfer）—— fp8 KV + MTP。
#   fusion  fusion KVMem 环线引擎树（vendor/ninfer-fusion-kvmem @ acba3d4），配 v3 制品
#           （models/fusion/ 三件）—— rk4v4-e8 KV + 主机层 + DFlash2；单并发。
#   两线镜像互不通用（引擎不同）；制品也互不通用（v2/v3 容器硬校验）。
#
# 用法:
#   ./docker/build-image.sh                        # 默认: 老线 + CUDA 13.3.0 + RTX 40 系(arch 89)
#   ./docker/build-image.sh -l fusion              # fusion 线 → tag ninfer-bonsai:cuda13.3-arch89-fusion
#   ./docker/build-image.sh -a 120a                # RTX 50 系(Blackwell) → tag 后缀 arch120a
#   ./docker/build-image.sh -b nvidia/cuda:13.1.2  # 切回引擎官方 Dockerfile 的 CUDA 版本
#   ./docker/build-image.sh -e <引擎树> -t <镜像tag> -m 0   # 自定路径/tag、关闭国内源
#
# 前置:
#   · docker 可用（不在 docker 组时脚本自动改用 sudo）
#   · 首次构建自动拉取基础镜像 ~7GB（精确 tag 与加速方式见 docker/README.md）
# =============================================================================
set -euo pipefail

# 默认路径相对本仓库推导（vendor/），可用环境变量 NINFER_ENGINE 或 -e 覆盖
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINE="old"
ARCH="89"
BASE="nvidia/cuda:13.3.0"
SM="0"          # NINFER_SM_COUNT（仅老线树有该参数）；0=引擎按架构默认（89→128/120a→170）。4070 Ti 用 -s 60
TAG=""
MIRROR="1"
while getopts "l:e:t:a:b:m:s:" o; do case "$o" in
    l) LINE="$OPTARG" ;;
    e) ENG="$OPTARG" ;;
    t) TAG="$OPTARG" ;;
    a) ARCH="$OPTARG" ;;
    b) BASE="$OPTARG" ;;
    m) MIRROR="$OPTARG" ;;
    s) SM="$OPTARG" ;;
    *) grep '^#' "$0" | sed -n '2,17p'; exit 1 ;;
esac; done

case "$LINE" in
    old)    ENG="${ENG:-${NINFER_ENGINE:-$REPO_ROOT/vendor/ninfer-4090w-ternary-a3}}" ;;
    fusion) ENG="${ENG:-${NINFER_ENGINE:-$REPO_ROOT/vendor/ninfer-fusion-kvmem/src-tree/fusion-engine-src}}" ;;
    *) echo "错误: -l 只能是 old(老生产线) 或 fusion(KVMem 环线)" >&2; exit 1 ;;
esac

[[ "$ARCH" == "89" || "$ARCH" == "120a" ]] || {
    echo "错误: CUDA_ARCH 只能是 89(RTX 40 系) 或 120a(RTX 50 系) —— 引擎 CMakeLists 硬限制" >&2; exit 1; }
[[ -f "$ENG/CMakeLists.txt" ]] || { echo "错误: 引擎树不存在: $ENG" >&2; exit 1; }
command -v rsync >/dev/null || { echo "错误: 需要 rsync（sudo apt install rsync）" >&2; exit 1; }
CUDASHORT="$(echo "$BASE" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?$' | cut -d. -f1,2 || true)"
[[ -n "$CUDASHORT" ]] || { echo "错误: -b 需为 nvidia/cuda:<版本> 形式" >&2; exit 1; }
# tag：老线保持历史命名不变（消费方无感）；fusion 线加 -fusion 后缀
TAGSUFFIX=""; [[ "$LINE" == "fusion" ]] && TAGSUFFIX="-fusion"
TAG="${TAG:-ninfer-bonsai:cuda${CUDASHORT}-arch${ARCH}${TAGSUFFIX}}"

DOCKER="docker"; docker info >/dev/null 2>&1 || DOCKER="sudo docker"

CTX="$(mktemp -d /tmp/ninfer-docker-ctx.XXXXXX)"
trap 'rm -rf "$CTX"' EXIT
echo ">> 收集引擎源码到构建上下文: $ENG （线: $LINE）"
mkdir "$CTX/src"
rsync -a --exclude 'build/' --exclude 'build-89/' --exclude 'tmp/' --exclude 'tmp-nvcc/' \
      --exclude '*.o' --exclude '*.a' --exclude '.git/' "$ENG/" "$CTX/src/"
cp "$(cd "$(dirname "$0")" && pwd)/Dockerfile" "$CTX/"

echo ">> docker build（基础镜像 ${BASE}.x, CUDA_ARCH=$ARCH, 国内源=$MIRROR）→ $TAG"
BUILD_ARGS=(--build-arg CUDA_BASE="$BASE" --build-arg CUDA_ARCH="$ARCH"
            --build-arg NINFER_JOBS="${NINFER_JOBS:-6}" --build-arg USE_MIRROR="$MIRROR")
# NINFER_SM_COUNT 只有老线树认；fusion 树传了会触发 CMake 未用变量警告，故仅老线传
[[ "$LINE" == "old" ]] && BUILD_ARGS+=(--build-arg NINFER_SM_COUNT="$SM")
$DOCKER build "${BUILD_ARGS[@]}" -t "$TAG" "$CTX"

echo ">> 构建完成: $TAG"
if [[ "$LINE" == "fusion" ]]; then
    echo "   启动服务: ./docker/run-ninfer.sh -l fusion     （另含 -l fusion-mtp / fusion-ptq1）"
else
    echo "   启动服务: ./docker/run-ninfer.sh               （老线默认档；融合线见 -l fusion）"
fi
