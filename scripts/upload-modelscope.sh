#!/usr/bin/env bash
# =============================================================================
# 一键镜像本仓库（含 models/ 下 .ninfer 制品：v2 老线 + v3 三件 fusion）到魔搭 ModelScope
#
# 前置（一次性）: 魔搭 CLI 走 modelscope-hub 包（modelscope 本体已不自带入口）：
#   uvx --from modelscope-hub modelscope login --token <你的token>
#
# 用法:
#   ./scripts/upload-modelscope.sh <魔搭用户名> [仓库名，默认 ninfer-bonsai-4070ti]
#   ./scripts/upload-modelscope.sh <魔搭用户名> --sync     # 同步模式：顺带删除远端"本地已不存在"的文件
#                                                          #（用于清理历史遗留，如早期误传的 HANDOFF.md）
#
# 行为: folder 模式上传整个仓库目录（排除 .git、本地交接文件与缓存），
#       models/ 下制品随之入库（v2 一件 + v3 三件，共约 30GB；重复执行=增量同步，
#       已上传未变更的大文件会跳过）。首次上传自动建仓。
# 页面: https://modelscope.cn/models/<用户名>/<仓库名>/files
#
# 注意: 本地交接/临时文件不进魔搭（HANDOFF.md、.ms_upload_cache、__pycache__、
#       运行产物 *.log/*.pid、perf 结果 JSON 按需保留——结果 JSON 若要随库发布请加进白名单）
# =============================================================================
set -euo pipefail
MS_USER="${1:?用法: $0 <魔搭用户名> [--sync] [仓库名]}"; shift || true
SYNC=""; REPO="ninfer-bonsai-4070ti"
for a in "$@"; do
    case "$a" in
        --sync) SYNC="--sync" ;;
        *)      REPO="$a" ;;
    esac
done
SRC="$(cd "$(dirname "$0")/.." && pwd)"
MS="uvx --from modelscope-hub modelscope"

echo ">> 上传 ${SRC} → modelscope.cn/${MS_USER}/${REPO}（首次自动建仓；30GB 制品增量同步，耐心等）"
[[ -n "$SYNC" ]] && echo ">> --sync 模式：远端多余文件（本地已不存在的）将在上传后删除"
$MS upload "${MS_USER}/${REPO}" "$SRC" . \
    --exclude ".git/*" "models/*.part" "HANDOFF.md" ".ms_upload_cache" \
              "__pycache__/*" "*/__pycache__/*" "*.log" "*.pid" "*.part" \
    $SYNC \
    --commit-message "mirror: sync from GitHub $(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo local)"

echo ">> 完成: https://modelscope.cn/models/${MS_USER}/${REPO}/files"
