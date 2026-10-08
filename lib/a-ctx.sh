# a-ctx.sh —— L2 上下文域（harness）
# 会话存储与裁剪（_A_CONV，每行一条: 类型<TAB>JSON）、消息数组组装、
# 环境采集（目录智能选取/git/终端历史）。
# 本层知道「有多个模式」，但不知道各模式的语义；模式键由产品层传入。
# 由 a.sh 在加载时 source，不单独使用。

# ---------- 会话存储（按模式分键） ----------

# 模式键 -> 会话变量名（模式中的非法字符映射为 _）。每个模式一条独立会话。
_a_conv_name() {
    local m=${1:-run}
    printf '_A_CONV_%s' "${m//[^a-zA-Z0-9_]/_}"
}

# 模式会话的安全读/写/清（eval 间接，兼容 bash 3.2 与 zsh，不用关联数组/nameref）
_a_conv_get() {
    eval "printf '%s' \"\${$(_a_conv_name "$1"):-}\""
}
_a_conv_set() {
    eval "$(_a_conv_name "$1")=\$2"
}
_a_conv_clear() {
    eval "unset $(_a_conv_name "$1")" 2>/dev/null || true
}

# 追加一条消息到指定模式的会话（每行一条，格式: 类型<TAB>JSON）。
# 类型: Q=用户请求 A=AI命令 R=执行结果，三者构成一轮，供裁剪时保持轮次完整。
_a_conv_append() { # _a_conv_append <mode> <类型> <消息JSON>
    local mode=$1 conv
    conv=$(_a_conv_get "$mode")
    if [[ -n $conv ]]; then
        conv="$conv
$2"$'\t'"$3"
    else
        conv="$2"$'\t'"$3"
    fi
    # 上限 40 条消息（约 13 轮），超出丢最早的
    if [[ $(printf '%s\n' "$conv" | wc -l) -gt 40 ]]; then
        conv=$(printf '%s\n' "$conv" | tail -n 40)
    fi
    _a_conv_set "$mode" "$conv"
}

# 按字符预算从新到旧保留完整的轮(Q 行开新轮)，孤立的 A/R 头部一并丢弃；
# 至少保留最新一轮。预算由 A_MAX_CONTEXT_CHARS 控制（默认 24000 字节，约 12K token）
_a_conv_trim() {
    # 注意: 用 NR 做下标——macOS awk 中未初始化变量作下标是空串而非 0
    awk -v budget="${A_MAX_CONTEXT_CHARS:-24000}" '
        { types[NR] = substr($0, 1, 1); lens[NR] = length($0) + 1; lines[NR] = $0 }
        END {
            n = NR; total = 0; start = n + 1
            for (i = n; i >= 1; i--) {
                if (types[i] != "Q") continue
                rl = 0
                for (j = i; j < start; j++) rl += lens[j]
                if (total + rl > budget && start <= n) break
                total += rl; start = i
            }
            for (i = start; i <= n; i++) print lines[i]
        }
    '
}

# 查看会话的上下文构成（每个有内容的模式一段）
_a_show() { # _a_show <mode...>
    local m conv any=0
    for m in "$@"; do
        [[ -n $(_a_conv_get "$m") ]] && any=1
    done
    if [[ $any == 0 ]]; then
        printf '（当前会话暂无对话上下文）\n'
        return 0
    fi
    local budget=${A_MAX_CONTEXT_CHARS:-24000}
    local total all_n kept_n kept_chars round c
    for m in "$@"; do
        conv=$(_a_conv_get "$m")
        [[ -n $conv ]] || continue
        total=$(printf '%s' "$conv" | wc -c | tr -d ' ')
        all_n=$(printf '%s\n' "$conv" | wc -l | tr -d ' ')
        kept=$(printf '%s\n' "$conv" | _a_conv_trim)
        kept_n=$(printf '%s\n' "$kept" | wc -l | tr -d ' ')
        kept_chars=$(printf '%s' "$kept" | wc -c | tr -d ' ')
        printf '[%s] 会话上下文: %d 条消息 / %d 字节，预算 %d，下一轮将发送 %d 条 / %d 字节（a -c 清空）\n' \
            "$m" "$all_n" "$total" "$budget" "$kept_n" "$kept_chars"
        round=0
        printf '%s\n' "$kept" | while IFS=$'\t' read -r typ json; do
            c=$(printf '%s' "$json" | _a_msg_content 2>/dev/null)
            case $typ in
                Q)
                    round=$((round + 1))
                    printf '  轮 %d  %s\n' "$round" "$(printf '%s\n' "$c" | tail -n 1 | sed 's/^请求: //' | cut -c 1-70)"
                    ;;
                A)
                    printf '        命令: %s\n' "$(printf '%s\n' "$c" | head -n 1 | cut -c 1-70)$(printf '%s\n' "$c" | awk 'END{if(NR>1)printf " (+%d 行)", NR-1}')"
                    ;;
                R)
                    printf '        结果: %s\n' "$(printf '%s\n' "$c" | head -n 1 | cut -c 1-70)"
                    ;;
            esac
        done
    done
}

# 最近的 shell 历史命令（排除 a 自身的调用），bash/zsh 兼容；无则返回空
_a_recent_history() {
    local h
    if [[ -n ${ZSH_VERSION:-} ]]; then
        h=$(fc -ln -6 2>/dev/null)
    elif [[ -n ${BASH_VERSION:-} ]]; then
        h=$(builtin history 6 2>/dev/null | sed -E 's/^ *[0-9]* *//')
    else
        return 0
    fi
    printf '%s\n' "$h" | grep -v '^a ' | awk 'NF'
}

# 从 stdin 读入全部目录条目，选出至多 <limit> 项输出（供 _a_env_context 注入）:
# 与 <query> 相关的优先——从 query 提取 ASCII 词元，词元完整出现在文件名中得分最高，
# 词元最长前缀（≥3 字符）命中次之，覆盖"linuxiso"→"linuxmint-….iso"这类口语缩写；
# 剩余名额按修改时间新→旧补足，近期下载/新建的文件也能进入上下文。
_a_pick_dir_entries() {
    local query=$1 limit=$2 matched n
    matched=$(awk -v q="$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')" '
        BEGIN { nt = split(q, T, /[^a-z0-9]+/) }
        NF {
            e = tolower($0)
            score = 0
            for (i = 1; i <= nt; i++) {
                t = T[i]
                if (length(t) < 3) continue
                if (index(e, t) > 0) { score += length(t) + 2; continue }
                for (L = length(t) - 1; L >= 3; L--)
                    if (index(e, substr(t, 1, L)) > 0) { score += L; break }
            }
            if (score > 0) print score "\t" $0
        }' | sort -t "$(printf '\t')" -k1,1rn -k2 | cut -f2- | head -n "$limit")
    n=$(printf '%s\n' "$matched" | awk 'NF' | wc -l | tr -d ' ')
    {
        [[ -n $matched ]] && printf '%s\n' "$matched"
        if [[ $n -lt $limit ]]; then
            ls -At 2>/dev/null | awk -v ex="$matched" '
                BEGIN { split(ex, X, "\n"); for (k in X) skip[X[k]] = 1 }
                NF && !($0 in skip)' | head -n $((limit - n))
        fi
    } | awk 'NF'
}

# 当前环境摘要: 工作目录 + git 分支/变更数 + 目录条目。
# 条目数不超过 A_DIR_ENTRIES（默认 15）时全部列出；超过时智能选取（_a_pick_dir_entries）
# 并在表头注明总条目数——避免大目录里按字母序截断，导致 AI 看不到用户所指的文件而编造名字。
_a_env_context() {
    local query=${1:-} branch dirty entries total
    local limit=${A_DIR_ENTRIES:-15}
    [[ $limit =~ ^[0-9]+$ ]] || limit=15
    printf '当前目录: %s\n' "$PWD"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        branch=$(git branch --show-current 2>/dev/null)
        [[ -n $branch ]] || branch=$(git rev-parse --short HEAD 2>/dev/null)
        dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        printf 'git: 分支 %s（未提交变更 %s 项）\n' "${branch:-unknown}" "$dirty"
    fi
    [[ $limit -eq 0 ]] && return 0
    entries=$(ls -A 2>/dev/null)
    total=$(printf '%s\n' "$entries" | awk 'NF' | wc -l | tr -d ' ')
    [[ ${total:-0} -gt 0 ]] || return 0
    if [[ $total -le $limit ]]; then
        printf '目录内容（共 %s 项）:\n%s\n' "$total" "$entries"
    else
        printf '目录内容（共 %s 项，仅列 %s 项: 与请求可能相关的优先，其余按修改时间新→旧）:\n%s\n' \
            "$total" "$limit" "$(printf '%s\n' "$entries" | _a_pick_dir_entries "$query" "$limit")"
    fi
}

# 组装请求消息数组: system + 指定模式的会话历史（如有，经裁剪）+ 本轮用户消息
_a_msgs_json() { # _a_msgs_json <mode> <sys_json> <user_json>
    local mode=$1 sys_json=$2 user_json=$3 conv
    conv=$(_a_conv_get "$mode")
    if [[ -n $conv ]]; then
        printf '%s,%s,%s' "$sys_json" \
            "$(printf '%s\n' "$conv" | _a_conv_trim | cut -f2- | paste -sd ',' -)" "$user_json"
    else
        printf '%s,%s' "$sys_json" "$user_json"
    fi
}
