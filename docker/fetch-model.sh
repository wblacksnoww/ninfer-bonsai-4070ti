#!/usr/bin/env bash
# =============================================================================
# 模型制品获取/校验（.ninfer 不随 git 分发：远超 GitHub 单文件 100MB 硬限制）
#
# 两代制品（兼容新旧模型）:
#   v2（老线）: models/artifacts-pq2.ninfer            —— A3 引擎用（fp8 + MTP）
#   v3（fusion 环线）: models/fusion/ 三件             —— fusion 引擎用（rk4v4-e8 + 主机层）
#       全量件    Ternary-Bonsai-2-27B-ninfer-v3.ninfer         8.87 GiB（默认档加 dflash2/视觉）
#       瘦身件    Ternary-Bonsai-2-27B-ninfer-v3-mtponly.ninfer 7.13 GiB（窗口 131072）
#       PTQ1 件   bonsai2_27b_ternary_ptq1_native_mtp.ninfer    5.96 GiB（最省显存）
#   ⚠ 两代容器格式不同且引擎硬校验：老引擎拒 v3、fusion 引擎拒 v2，不能混用。
#
# 用法:
#   ./docker/fetch-model.sh                    # 校验 models/ 与 models/fusion/ 下制品是否就绪
#   ./docker/fetch-model.sh --ms               # 从魔搭镜像仓库下载 v2 制品（7.8GB，国内直连）
#   ./docker/fetch-model.sh --ms-fusion        # 从魔搭下载 v3 三件（约 22GB，增量；建议先看网盘）
#   ./docker/fetch-model.sh --ms-fusion full|mtponly|ptq1   # 只下某一件
#   ./docker/fetch-model.sh <制品路径>         # 复制到 models/ 并校验（自动判 v2/v3 文件名）
#   ./docker/fetch-model.sh --hf               # 下载 HF 现成制品（20.4GB，≥24GB 卡用，见下）
#
# 制品来源（详见 docker/README.md《模型制品》节）:
#   ① 魔搭镜像仓库 xiuming/ninfer-bonsai-4070ti（推荐，国内直连；含 v2 + v3 全部）
#   ② 官方交付包/新网盘（夸克手动）: v2 极速档 https://pan.quark.cn/s/ef30066ed62a
#      v3 模型包-20260930 https://pan.quark.cn/s/ab6718583f2f（三件放 models/fusion/，文件名勿改）
#   ③ 自打包（全开源，工具在 vendor/，见 docker/README.md《模型制品》节）
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO_ROOT/models/artifacts-pq2.ninfer"
SHA_PQ2="05bbbf01090c6f61113b54556daa22ad0b45036a078af6cd6f02a3fde47ad76c"
SHA_HF="0634abb07024221de141456cf04a42ab74b18bc38e1b781c6eb2e062a467eec3"
HF_FILE="qwen3_8_27b.ninfer"
HF_REPO="neroued/Qwen3.8-27B-NInfer"

# ---- v3（fusion 环线）三件：字节数与 SHA256（SHA 为本仓库落位后实算，与官方清单字节数已逐件核对）----
FUSION_DIR="$REPO_ROOT/models/fusion"
F_FULL="Ternary-Bonsai-2-27B-ninfer-v3.ninfer"
F_MTP="Ternary-Bonsai-2-27B-ninfer-v3-mtponly.ninfer"
F_PTQ1="bonsai2_27b_ternary_ptq1_native_mtp.ninfer"
SHA_FULL="cdc4810b0ff17c40d0f62cf214b6e0bcd08346e9eb05ca53371507037793c14a"
SHA_MTP="0dcd852124b88d53cb3feaa8b4886dd0471d21c3390800c21f1832cd002ee77e"
SHA_PTQ1="5c4486c8a52687e3f62072c7dd2a320546d0e00d1c019bf137eb02cc944e21b8"
MS_REPO="xiuming/ninfer-bonsai-4070ti"

verify() {  # $1=文件 $2=期望sha256 $3=标签
    echo ">> 校验 SHA256: $(basename "$1")"
    local actual; actual="$(sha256sum "$1" | cut -d' ' -f1)"
    if [[ "$actual" == "$2" ]]; then
        echo "✅ 制品就绪: $1（$3, SHA256 匹配）"
    else
        echo "❌ SHA256 不匹配（$3）" >&2
        echo "   实际: $actual" >&2
        echo "   期望: $2" >&2
        exit 1
    fi
}

fetch_fusion_one() {  # $1=文件名 $2=期望sha256 $3=标签（从魔搭增量下载）
    mkdir -p "$FUSION_DIR"
    local MS="uvx --from modelscope-hub modelscope"
    echo ">> 从魔搭下载 $MS_REPO models/fusion/$1（$3）"
    $MS download "$MS_REPO" "models/fusion/$1" --local_dir "$REPO_ROOT"
    verify "$FUSION_DIR/$1" "$2" "$3"
}

case "${1:-verify}" in
    --ms)
        mkdir -p "$REPO_ROOT/models"
        MS="uvx --from modelscope-hub modelscope"
        echo ">> 从魔搭下载 $MS_REPO（v2 制品 7.8GB，国内直连）"
        $MS download "$MS_REPO" models/artifacts-pq2.ninfer --local_dir "$REPO_ROOT"
        verify "$DEST" "$SHA_PQ2" "PQ2 极速档 v2（魔搭镜像）"
        ;;
    --ms-fusion)
        case "${2:-all}" in
            all|"")
                fetch_fusion_one "$F_FULL" "$SHA_FULL" "v3 全量件（默认档）"
                fetch_fusion_one "$F_MTP"  "$SHA_MTP"  "v3 瘦身件（窗口大一倍）"
                fetch_fusion_one "$F_PTQ1" "$SHA_PTQ1" "v3 PTQ1 件（最省显存）"
                echo ">> v3 三件就绪 → $FUSION_DIR/"
                ;;
            full)   fetch_fusion_one "$F_FULL" "$SHA_FULL" "v3 全量件（默认档）" ;;
            mtponly) fetch_fusion_one "$F_MTP" "$SHA_MTP" "v3 瘦身件（窗口大一倍）" ;;
            ptq1)   fetch_fusion_one "$F_PTQ1" "$SHA_PTQ1" "v3 PTQ1 件（最省显存）" ;;
            *) echo "用法: $0 --ms-fusion [full|mtponly|ptq1]（默认 all=三件）" >&2; exit 1 ;;
        esac
        ;;
    --hf)
        mkdir -p "$REPO_ROOT/models"
        OUT="$REPO_ROOT/models/$HF_FILE"
        echo ">> 从 HF 镜像下载 $HF_REPO/$HF_FILE（20.4GB，hf-mirror 国内直连）"
        if command -v hf >/dev/null 2>&1; then
            HF_ENDPOINT=https://hf-mirror.com hf download "$HF_REPO" "$HF_FILE" --local-dir "$REPO_ROOT/models"
        else
            curl -L --fail -o "$OUT.part" \
              "https://hf-mirror.com/$HF_REPO/resolve/main/$HF_FILE"
            mv "$OUT.part" "$OUT"
        fi
        verify "$OUT" "$SHA_HF" "neroued groupwise-int（≥24GB 显存卡用）"
        echo "   ⚠ 12GB 卡放不下该制品（20.4GB 权重）；12GB 卡请用来源①的 PQ2 或 v3 三件。"
        ;;
    verify|"")
        FOUND=0
        if [[ -f "$DEST" ]]; then
            ACTUAL="$(sha256sum "$DEST" | cut -d' ' -f1)"
            if [[ "$ACTUAL" == "$SHA_PQ2" ]]; then
                echo "✅ v2 制品就绪: $DEST（PQ2 极速档, SHA256 匹配）—— 老线用"; FOUND=1
            elif [[ "$ACTUAL" == "$SHA_HF" ]]; then
                echo "✅ v2 制品就绪: $DEST（neroued groupwise-int, SHA256 匹配; ⚠ 12GB 卡放不下）"; FOUND=1
            else
                echo "❌ $DEST SHA256 不匹配，非已知制品" >&2
                echo "   实际: $ACTUAL" >&2
                exit 1
            fi
        else
            echo "（未找到 v2 制品: $DEST —— 老线需要，获取: $0 --ms）"
        fi
        FUSE_FOUND=0
        for pair in "$F_FULL:$SHA_FULL:v3 全量件（fusion 默认档）" \
                    "$F_MTP:$SHA_MTP:v3 瘦身件（fusion-mtp 档）" \
                    "$F_PTQ1:$SHA_PTQ1:v3 PTQ1 件（fusion-ptq1 档）"; do
            IFS=':' read -r fn sha label <<< "$pair"
            if [[ -f "$FUSION_DIR/$fn" ]]; then
                ACTUAL="$(sha256sum "$FUSION_DIR/$fn" | cut -d' ' -f1)"
                if [[ "$ACTUAL" == "$sha" ]]; then
                    echo "✅ $label 就绪: models/fusion/$fn（SHA256 匹配）"; FUSE_FOUND=$((FUSE_FOUND+1))
                else
                    echo "❌ models/fusion/$fn SHA256 不匹配（重下: $0 --ms-fusion …）" >&2; exit 1
                fi
            fi
        done
        [[ "$FUSE_FOUND" == 0 ]] && echo "（未找到任何 v3 制品 —— fusion 环线需要，获取: $0 --ms-fusion 或网盘）"
        if [[ "$FOUND" == 0 && "$FUSE_FOUND" == 0 ]]; then
            echo; echo "获取方式:"
            echo "  ① 魔搭镜像仓库（推荐）: 老线 $0 --ms ｜ fusion 环线 $0 --ms-fusion"
            echo "  ② 夸克网盘: v2 https://pan.quark.cn/s/ef30066ed62a ｜ v3（模型包）https://pan.quark.cn/s/ab6718583f2f"
            echo "  ③ 本机已有制品:         $0 <制品路径>"
            echo "  ④ HF 现成制品（≥24GB 卡）: $0 --hf"
            echo "  ⑤ 自打包:               见 docker/README.md《模型制品》节"
            exit 1
        fi
        ;;
    *)
        [[ -f "$1" ]] || { echo "错误: 文件不存在: $1" >&2; exit 1; }
        base="$(basename "$1")"
        case "$base" in
            "$F_FULL"|"$F_MTP"|"$F_PTQ1")
                mkdir -p "$FUSION_DIR"
                echo ">> 复制 $(du -h "$1" | cut -f1) → $FUSION_DIR/$base"
                cp "$1" "$FUSION_DIR/$base"
                ;;
            *)
                mkdir -p "$(dirname "$DEST")"
                echo ">> 复制 $(du -h "$1" | cut -f1) → $DEST"
                cp "$1" "$DEST"
                ;;
        esac
        exec "$0" verify
        ;;
esac
