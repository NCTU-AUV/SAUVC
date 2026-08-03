#!/bin/bash
# =============================================================================
# repo 更名 —— 本機端
# =============================================================================
# 為什麼要改名：RPi 已經完全移除，兩套堆疊現在都跑在同一塊 Jetson Orin NX 上。
# 用硬體命名（-RPI / -JETSON）會直接誤導新成員，改用職責命名：
#
#   SAUVC-RPI        →  SAUVC-Control      載具控制堆疊
#   SAUVC-JETSON     →  SAUVC-Autonomy     感知與決策堆疊
#   SAUVC-Simulation →  SAUVC-Simulation   （不變）
#   SAUVC-STM32      →  SAUVC-STM32        （不變，它真的就是 STM32）
#
# 這個腳本只做**本機**的部分。GitHub 上的改名必須由有權限的人先做：
#
#   1. GitHub → 該 repo → Settings → Repository name → 改名 → Rename
#      （GitHub 會自動保留舊名的重導，既有 clone 不會立刻壞掉）
#   2. 兩個 repo 都改完之後，回來跑這個腳本
#   3. 檢查 git status，確認無誤後 commit super-repo 的 .gitmodules 變更
#
# 用法：
#   ./scripts/rename_repos.sh --dry-run   # 只印出會做什麼（預設）
#   ./scripts/rename_repos.sh --apply     # 真的執行
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )"
cd "$ROOT"

ORG="${ORCA_GITHUB_ORG:-NCTU-AUV}"
APPLY=0
for arg in "${@:-}"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --dry-run|"") ;;
        *) echo "unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# old_name:new_name
RENAMES=(
    "SAUVC-RPI:SAUVC-Control"
    "SAUVC-JETSON:SAUVC-Autonomy"
)

run() {
    if [[ $APPLY -eq 1 ]]; then
        echo "  \$ $*"
        "$@"
    else
        echo "  (dry-run) $*"
    fi
}

echo "=== 檢查 GitHub 上是否已改名 ==="
for pair in "${RENAMES[@]}"; do
    NEW="${pair#*:}"
    URL="https://github.com/${ORG}/${NEW}.git"
    printf '  %-20s ' "$NEW"
    if git ls-remote --exit-code "$URL" >/dev/null 2>&1; then
        echo "已存在 ✓"
    else
        echo "還不存在 ✗"
        echo ""
        echo "請先在 GitHub 上把 ${ORG}/${pair%%:*} 改名成 ${NEW}，再跑這個腳本。" >&2
        exit 1
    fi
done

echo ""
echo "=== 更新 submodule 的 URL 與路徑 ==="
for pair in "${RENAMES[@]}"; do
    OLD="${pair%%:*}"; NEW="${pair#*:}"
    [[ -d "$OLD" ]] || { echo "  $OLD 不存在，跳過"; continue; }

    echo "  $OLD → $NEW"
    # 先改 remote，再搬目錄，最後改 super-repo 的 submodule 註冊。
    run git -C "$OLD" remote set-url origin "https://github.com/${ORG}/${NEW}.git"
    run git submodule deinit -f "$OLD"
    run git rm -q --cached "$OLD"
    run mv "$OLD" "$NEW"
    run git submodule add -f "https://github.com/${ORG}/${NEW}.git" "$NEW"
done

echo ""
echo "=== 更新文字引用 ==="
# 只動追蹤中的文字檔，不碰 .git 內部與二進位檔。
for pair in "${RENAMES[@]}"; do
    OLD="${pair%%:*}"; NEW="${pair#*:}"
    echo "  $OLD → $NEW"
    if [[ $APPLY -eq 1 ]]; then
        git ls-files -z | xargs -0 -r grep -lZ "$OLD" 2>/dev/null \
            | xargs -0 -r sed -i "s|${OLD}|${NEW}|g" || true
    else
        COUNT=$(git ls-files -z | xargs -0 -r grep -l "$OLD" 2>/dev/null | wc -l)
        echo "  (dry-run) 會改到 ${COUNT} 個檔案"
    fi
done

echo ""
if [[ $APPLY -eq 1 ]]; then
    cat <<'EOF'
完成。接下來：
  1. git status / git diff 檢查
  2. 各 submodule 內部也有自我引用（README 標題、docs 連結），
     請分別進去檢查並 commit
  3. commit super-repo 的 .gitmodules 與 submodule 指標變更
  4. 通知所有人重新 clone，或執行：
       git submodule sync --recursive && git submodule update --init --recursive
EOF
else
    echo "這是 dry-run，什麼都沒改。確認無誤後加 --apply。"
fi
