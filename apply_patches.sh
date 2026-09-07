#!/usr/bin/env bash
#================================================================================
# apply_patches.sh
#
# 功能：将本仓库(bm1688_sdk_patch)按目录分类、数字编号的 *.patch 文件，
#       应用到目标 SDK 仓库(bm1688_release_sdk_github)下对应的 git 仓库。
#
# 防呆核心（可重复执行、结果确定可复现）：
#   1. 根据 bm1688_release_sdk_github/gitlog.txt 中记录的每个仓库基础 commit，
#      先清理可能遗留的 am 中断，再强制回退(reset --hard)到该基线 commit，
#      并 git clean -fd 清理未跟踪残留文件（历史 git apply 遗留、构建产物等），
#      确保从干净状态出发；
#   2. 再从基线按数字编号顺序用 git am 应用 bm1688_sdk_patch 下对应目录的 *.patch，
#      每个 patch 都会完整保留为一个独立 commit（作者、提交信息、Change-Id 等）。
#
#   因此无论目标仓库当前处于何种状态（被改乱 / HEAD 漂移 / 已打过部分 patch /
#   遗留未跟踪文件 / am 中断），每次执行都会先回到干净基线再重打，结果完全一致；
#   patch 数量增减、重新编号、内容更新均无需额外处理。
#
# 目录约定：
#   bm1688_sdk_patch/<相对路径>/NNNN-xxx.patch
#       └──> bm1688_release_sdk_github/<相对路径>/     （相对路径与 git 仓库位置对应）
#   说明：相对路径既可以是顶层仓库名（build、osdrv 等），也支持嵌套仓库位置
#   （如 ubuntu/bootloader-arm64，对应 SDK 内 ubuntu/bootloader-arm64 这个 git 仓库）。
#   gitlog.txt 记录的是项目名（project_name），项目名与仓库相对路径可能不一致，
#   脚本通过「gitlog 基线 commit 是否存在于该仓库对象库」自动匹配基线，无需手工指定。
#
# 用法：
#   ./apply_patches.sh [-n] [-y] [-q] [-d <目标SDK根目录>]
#     -n, --dry-run   仅预演（检查基线 commit 是否存在、patch 是否可干净应用），
#                     不真正 reset、不修改任何文件
#     -y, --yes       跳过交互确认（默认会提示：该操作会 reset --hard 目标仓库）
#     -q, --quiet     精简输出（失败/警告仍会打印）
#     -d, --dir DIR   指定目标 SDK 根目录（默认：本目录的上一级 ../bm1688_release_sdk_github）
#     -h, --help      显示本帮助
#================================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_ROOT="$SCRIPT_DIR"
TARGET_ROOT="${TARGET_ROOT:-$PATCH_ROOT/../bm1688_release_sdk_github}"
GITLOG_FILE="$TARGET_ROOT/gitlog.txt"

DRY_RUN=0
ASSUME_YES=0
QUIET=0

# ---- 颜色（非终端自动关闭） ----
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_OFF=""
fi

info()  { [ "$QUIET" = "1" ] || printf '%s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()    { [ "$QUIET" = "1" ] || printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
skip_() { [ "$QUIET" = "1" ] || printf '%s[SKIP]%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_OFF" "$*"; }
fail()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*"; }
die()   { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit "${2:-1}"; }

usage() {
    cat <<EOF
用法: $0 [选项]

将 $PATCH_ROOT 下按仓库分类、数字编号的 *.patch 应用到目标 SDK 仓库。

流程：先按 gitlog.txt 记录的基线 commit 对目标仓库 reset --hard，
      再按数字编号顺序应用对应目录下的全部 *.patch。

选项:
  -n, --dry-run   仅预演，不 reset、不修改任何文件
  -y, --yes       跳过交互确认
  -q, --quiet     精简输出（失败/警告仍会打印）
  -d, --dir DIR   指定目标 SDK 根目录（默认: $PATCH_ROOT/../bm1688_release_sdk_github）
  -h, --help      显示本帮助
EOF
}

# ---- 解析命令行参数 ----
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        -q|--quiet)   QUIET=1 ;;
        -d|--dir)
            shift
            [ $# -gt 0 ] || die "缺少 -d/--dir 的参数"
            TARGET_ROOT="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（使用 -h 查看帮助）" ;;
    esac
    shift
done

TARGET_ROOT="$(cd "$TARGET_ROOT" 2>/dev/null && pwd)" \
    || die "目标 SDK 目录不存在或不可访问: $TARGET_ROOT"
GITLOG_FILE="$TARGET_ROOT/gitlog.txt"

command -v git >/dev/null 2>&1 \
    || die "系统中未找到 git 命令，无法执行"

# ---- 解析 gitlog.txt: repo_name -> 基础 commit_id ----
[ -f "$GITLOG_FILE" ] || die "未找到 $GITLOG_FILE，无法确定各仓库基线 commit"
declare -A GITLOG_COMMIT
cur=""
while IFS= read -r line; do
    case "$line" in
        project_name:*)
            cur="${line#project_name: }"
            cur="${cur%% (*}"
            ;;
        commit_id:*)
            id="${line#commit_id: }"
            id="${id%% *}"
            if [ -n "$cur" ] && [ -n "$id" ]; then
                GITLOG_COMMIT["$cur"]="$id"
            fi
            ;;
    esac
done < "$GITLOG_FILE"

# ---- 由目标仓库定位其 gitlog 项目名与基线 commit ----
# gitlog.txt 的项目名可能与仓库在 SDK 内的相对路径不一致（例如项目名
# bootloader-arm64，实际 git 仓库位于 ubuntu/bootloader-arm64），因此不能
# 用「目录名 = 项目名」直接查表。这里改为逐个检查 gitlog 中的基线 commit
# 是否存在于该仓库对象库，存在即视为该仓库的基线（不存在则不匹配）。
# 用法: resolve_repo_base <repo_dir> <相对路径>
# 成功: 输出 "项目名|commit_id"，返回 0
# 失败: 返回 1(未在 gitlog 记录) / 2(匹配到多个项目，无法唯一确定)
resolve_repo_base() {
    local repo_dir="$1" rel="$2" relbase nm pick=""
    local -a matches=()
    relbase="$(basename "$rel")"
    for nm in "${!GITLOG_COMMIT[@]}"; do
        if git -C "$repo_dir" cat-file -e "${GITLOG_COMMIT[$nm]}" >/dev/null 2>&1; then
            matches+=("$nm")
        fi
    done
    case "${#matches[@]}" in
        0) return 1 ;;
        1)
            printf '%s|%s' "${matches[0]}" "${GITLOG_COMMIT[${matches[0]}]}"
            return 0
            ;;
        *)
            # 多个项目包含同一 commit：优先取与目录 basename 相同的项目名
            for nm in "${matches[@]}"; do
                [ "$nm" = "$relbase" ] && pick="$nm"
            done
            if [ -n "$pick" ]; then
                printf '%s|%s' "$pick" "${GITLOG_COMMIT[$pick]}"
                return 0
            fi
            return 2
            ;;
    esac
}

# ---- 收集需要处理的仓库 ----
# 遍历 patch 根目录下所有「直接含 *.patch」的目录；目录相对 PATCH_ROOT 的
# 路径即为目标仓库相对 TARGET_ROOT 的路径，既支持顶层（build 等），也支持
# 嵌套仓库（ubuntu/bootloader-arm64 等）。
declare -a REPOS=()
declare -a REPO_PATCH_COUNT=()
while IFS= read -r -d '' d; do
    name="${d#"$PATCH_ROOT"/}"
    [ -n "$name" ] || continue
    case "$name" in
        .*|*/.?*) continue ;;   # 跳过含隐藏目录的路径（如 .git/）
    esac
    n="$(find "$d" -maxdepth 1 -type f -name '*.patch' | wc -l)"
    [ "$n" -gt 0 ] || continue
    REPOS+=("$name")
    REPO_PATCH_COUNT+=("$n")
done < <(find "$PATCH_ROOT" -mindepth 1 -type f -name '*.patch' -printf '%h\0' | sort -u -z)

if [ "${#REPOS[@]}" -eq 0 ]; then
    die "在 $PATCH_ROOT 下未找到任何 *.patch 文件"
fi

# ---- 打印执行计划 ----
echo
info "================== 执行计划 =================="
total_patches=0
for ((i=0; i<${#REPOS[@]}; i++)); do
    name="${REPOS[$i]}"
    n="${REPO_PATCH_COUNT[$i]}"
    total_patches=$((total_patches+n))
    repo_dir="$TARGET_ROOT/$name"
    if [ ! -d "$repo_dir" ]; then
        warn "  $name: 目标仓库不存在: $repo_dir（将跳过）"
        continue
    fi
    if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
        warn "  $name: 目标不是 git 仓库: $repo_dir（将跳过）"
        continue
    fi
    nb="$(resolve_repo_base "$repo_dir" "$name")"
    rc=$?
    if [ "$rc" -eq 2 ]; then
        warn "  $name: 匹配到多个 gitlog 项目，无法确定基线（将跳过）"
        continue
    elif [ "$rc" -ne 0 ]; then
        warn "  $name: gitlog.txt 未记录基线 commit（将跳过）"
        continue
    fi
    printf '  %-28s %4d 个 patch  基线:%s\n' "$name" "$n" "${nb#*|}"
done
printf '  共 %d 个仓库，%d 个 patch\n' "${#REPOS[@]}" "$total_patches"
echo "============================================="

# ---- 确认（reset --hard 是破坏性操作，默认需确认） ----
if [ "$DRY_RUN" = "1" ]; then
    info "预演模式：不 reset、不修改任何文件。"
elif [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; then
    printf '%s本操作将 reset --hard 上述目标仓库到基线 commit，丢弃其未提交改动及基线后的提交，是否继续？[y/N]%s ' "$C_RED" "$C_OFF"
    read -r ans
    case "$ans" in
        y|Y|yes|YES|Yes) : ;;
        *) echo "已取消。"; exit 0 ;;
    esac
elif [ "$ASSUME_YES" != "1" ]; then
    warn "非交互终端且未指定 -y，直接继续执行（如需取消请 Ctrl+C）"
fi

# ---- 执行 ----
TOTAL_APPLIED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0

for ((i=0; i<${#REPOS[@]}; i++)); do
    name="${REPOS[$i]}"
    n="${REPO_PATCH_COUNT[$i]}"
    repo_dir="$TARGET_ROOT/$name"
    patch_dir="$PATCH_ROOT/$name"
    base=""

    echo
    info "== $name（$n 个 patch） =="

    if [ ! -d "$repo_dir" ]; then
        warn "跳过：目标仓库不存在 $repo_dir"
        continue
    fi
    if ! git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
        fail "跳过：$repo_dir 不是 git 仓库"
        TOTAL_FAILED=$((TOTAL_FAILED+1))
        continue
    fi
    nb="$(resolve_repo_base "$repo_dir" "$name")"
    rc=$?
    if [ "$rc" -eq 2 ]; then
        fail "跳过：$name 匹配到多个 gitlog 项目，无法确定基线 commit"
        TOTAL_FAILED=$((TOTAL_FAILED+1))
        continue
    elif [ "$rc" -ne 0 ]; then
        fail "跳过：gitlog.txt 未记录 $name 的基线 commit"
        TOTAL_FAILED=$((TOTAL_FAILED+1))
        continue
    fi
    base="${nb#*|}"
    info "    基线 commit: $base"

    # 收集 patch，按数字编号排序
    patches=()
    while IFS= read -r -d '' pf; do
        patches+=("$pf")
    done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z -V)

    applied=0; failed=0

    if [ "$DRY_RUN" = "1" ]; then
        # 预演：在临时 index 上模拟「reset 到基线 + 逐 patch 应用」，不触碰真实仓库。
        # 用 --cached 使 index 内容随 patch 递增更新，准确反映 patch 间的顺序依赖。
        tmp_idx="$(mktemp)"
        GIT_INDEX_FILE="$tmp_idx" git -C "$repo_dir" read-tree "$base" 2>/dev/null || true
        all_ok=1
        for pf in "${patches[@]}"; do
            pname="$(basename "$pf")"
            if GIT_INDEX_FILE="$tmp_idx" git -C "$repo_dir" apply --cached -p1 "$pf" >/dev/null 2>&1; then
                [ "$QUIET" = "1" ] || info "  [DRY] 将应用 $name/$pname"
            else
                fail "  [DRY] $name/$pname 无法干净应用"
                all_ok=0
            fi
        done
        rm -f "$tmp_idx"
        [ "$all_ok" = "1" ] && ok "  $name 全部 patch 可在基线 ${base} 上干净应用"
    else
        # 正式执行：清理历史遗留状态 -> 回退到基线 -> 再逐 patch 应用
        # 1) 清理可能遗留的 am 中断状态（无中断时静默，幂等）
        git -C "$repo_dir" am --abort >/dev/null 2>&1

        # 2) 强制回退到基线 commit
        if git -C "$repo_dir" reset --hard "$base" >/dev/null 2>&1; then
            info "  已 reset --hard 到基线 $base"
        else
            fail "  reset --hard 到 $base 失败"
            TOTAL_FAILED=$((TOTAL_FAILED+1))
            continue
        fi

        # 3) 清理未跟踪残留文件（历史 git apply 遗留、构建产物等），避免挡住 git am
        #    注意：仅 -fd，保留 .gitignore 忽略的文件
        if git -C "$repo_dir" clean -fd >/dev/null 2>&1; then
            info "  已 git clean -fd 清理未跟踪残留"
        else
            warn "  git clean -fd 失败（可忽略，若后续 am 失败请检查残留）"
        fi

        for pf in "${patches[@]}"; do
            pname="$(basename "$pf")"
            # 用 git am 打 patch，完整保留每个 patch 的 commit（作者/提交信息/Change-Id 等）
            if git -C "$repo_dir" am "$pf" >/dev/null 2>&1; then
                applied=$((applied+1))
                ok "  $name/$pname"
            else
                # am 失败会进入中断状态，需 --abort 回滚，否则影响后续 patch/仓库
                git -C "$repo_dir" am --abort >/dev/null 2>&1
                failed=$((failed+1))
                fail "  $name/$pname 应用失败"
            fi
        done

        printf '  %-28s 应用:%d  失败:%d\n' "$name" "$applied" "$failed"
        TOTAL_APPLIED=$((TOTAL_APPLIED+applied))
        TOTAL_FAILED=$((TOTAL_FAILED+failed))
    fi
done

# ---- 汇总 ----
echo
info "==================== 汇总 ===================="
printf '  处理仓库数 : %d\n' "${#REPOS[@]}"
printf '  应用成功   : %d\n' "$TOTAL_APPLIED"
printf '  失败       : %d\n' "$TOTAL_FAILED"
echo "============================================="

if [ "$DRY_RUN" = "1" ]; then
    info "本次为预演模式，未修改任何文件。"
    exit 0
fi

if [ "$TOTAL_FAILED" -gt 0 ]; then
    die "有 $TOTAL_FAILED 个 patch 未能应用，请根据上方 FAIL 信息手工处理。" 1
fi

info "全部完成。请自行检查各仓库状态（git status）后再 commit。"
exit 0
