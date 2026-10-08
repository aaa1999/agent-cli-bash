# a-exec.sh —— L3 执行域（harness）
# 命令风险评估、shell 状态命令识别与带确认的多步执行。
# 依赖 L2（执行结果经 _a_conv_append 回写会话）；不依赖产品层的任何约定。
# 由 a.sh 在加载时 source，不单独使用。

# 判断命令是否直接改变当前 shell 状态（cd/export/alias/source/赋值等）。
# 这类命令必须绕过管道在当前 shell 执行，否则 cd、变量、别名只在子 shell 生效。
_a_shell_state() {
    local c=$1
    printf '%s' "$c" | grep -qE '(^|[;&|(]|\||&&) *(cd|pushd|popd|export|unset|setopt|unsetopt|shopt|set|alias|unalias|source|umask|ulimit|exec|trap)([^a-zA-Z0-9_-]|$)' \
        || printf '%s' "$c" | grep -qE '(^|[;&|]|&&) *\. +[^ ]' \
        || printf '%s' "$c" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*='
}

# 命令风险评估: 输出 danger(高危: 提权/强制删除/系统级写) / caution(写操作) / 空(只读)
_a_risk() {
    local c=$1
    if printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_.-])(sudo|su|doas|pkexec|mkfs|fdisk|shutdown|reboot|halt|shred|dd)([^a-zA-Z0-9_.-]|$)' \
        || printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_-])rm +-[a-zA-Z]*[rRf]' \
        || printf '%s' "$c" | grep -qE 'git +(push +(-f|--force)|reset +--hard|clean|checkout +--|restore)' \
        || printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_-])kill +(-9|-[sSIG]*KILL)' \
        || printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_-])(chmod|chown) +-[a-zA-Z]*R' \
        || printf '%s' "$c" | grep -qE 'diskutil +(erase|partition|format)' \
        || printf '%s' "$c" | grep -qE '(curl|wget)[^|]*\| *(ba|z)?sh'; then
        printf 'danger\n'
    elif printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_.-])(rm|chmod|chown|chgrp|kill|pkill|killall|mv|truncate|tee)([^a-zA-Z0-9_.-]|$)' \
        || printf '%s' "$c" | grep -qE 'git +(push|commit|stash)' \
        || printf '%s' "$c" | grep -qE '(apt|apt-get|brew|yum|dnf|pip3?|npm|gem) +install' \
        || printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_-])(systemctl|launchctl|service) ' \
        || printf '%s' "$c" | grep -qE 'sed +-[a-zA-Z]*i' \
        || printf '%s' "$c" | grep -qE '(^|[^>2])>([^>&]|$)'; then
        printf 'caution\n'
    fi
}

# 终端上提示并读入一行回答（ASK 追问等交互复用）。
# 成功把回答存入全局 reply 并返回 0；无终端可读时打印提示、reply 置空、返回 1。
_a_prompt_answer() { # _a_prompt_answer <提示文本(不含换行)>
    printf '%s' "$1" >&2
    if IFS= read -r reply < /dev/tty 2>/dev/null; then
        return 0
    fi
    reply=
    printf '\n(无终端可交互，无法补充信息)\n' >&2
    return 1
}

# 多步确认执行: 把 <cmd> 按行拆成步骤，逐步显示风险并询问 y/n/i；
# 高危命令即使 -y 也强制确认，无终端一律拒绝；shell 状态命令在当前 shell 执行。
# 执行结果摘要（R 消息）回写到 <mode> 的会话；返回最后一步退出码，用户终止返回 130。
_a_exec_steps() { # _a_exec_steps <mode> <auto_yes> <cmd>
    local mode=$1 auto_yes=$2 cmd=$3
    local remaining=$cmd step risk reply
    local total n=0 executed=0 skipped=0 stopped_at=0 rc=0 state_executed=0
    local out_file out_tail
    total=$(printf '%s\n' "$cmd" | awk 'NF' | wc -l | tr -d ' ')
    out_file=$(mktemp "${TMPDIR:-/tmp}/a-out.XXXXXX")

    while [[ -n $remaining ]]; do
        step=${remaining%%$'\n'*}
        if [[ $step == "$remaining" ]]; then
            remaining=
        else
            remaining=${remaining#*$'\n'}
        fi
        [[ -z ${step//[[:space:]]/} ]] && continue
        n=$((n + 1))

        if [[ $total -gt 1 ]]; then
            printf '\033[1m步骤 %d/%d:\033[0m ' "$n" "$total" >&2
        fi
        risk=$(_a_risk "$step")
        case $risk in
            danger)
                printf '\033[31m%s\033[0m\n' "$step" >&2
                printf '\033[31m⚠  高危/高权限操作（提权/强制删除/系统级写入），逐字核对命令与路径\033[0m\n' >&2
                ;;
            caution)
                printf '\033[33m%s\033[0m\n' "$step" >&2
                printf '\033[33m⚡  写操作，会修改文件或状态\033[0m\n' >&2
                ;;
            *)
                printf '\033[36m%s\033[0m\n' "$step" >&2
                ;;
        esac

        # 高危命令必须用户逐条决策：即使 -y 也不跳过；无终端时直接拒绝
        if [[ $auto_yes != 1 || $risk == danger ]]; then
            if [[ $risk == danger ]]; then
                printf '\033[31m确认执行高危命令?\033[0m [y=执行 n=终止剩余 i=跳过此步] ' >&2
            elif [[ $total -gt 1 ]]; then
                printf '执行此步? [y=执行 n=终止剩余 i=跳过此步] ' >&2
            else
                printf '执行? [y=执行 n=不执行 i=忽略] ' >&2
            fi
            if IFS= read -r reply < /dev/tty 2>/dev/null; then
                :
            else
                reply=
                printf '\n(无终端可交互，视为不执行；脚本中请使用 a -y / a -p)\n' >&2
            fi
            case $reply in
                y|Y)
                    ;;
                i|I)
                    printf '(已跳过)\n' >&2
                    skipped=$((skipped + 1))
                    continue
                    ;;
                *)
                    printf '已终止，剩余步骤不再执行\n' >&2
                    stopped_at=$n
                    break
                    ;;
            esac
        fi

        executed=$((executed + 1))
        if _a_shell_state "$step"; then
            # shell 状态命令直接在当前 shell 执行（不经管道子 shell），
            # 保证 cd/变量/别名真正生效；输出实时显示但不捕获回传
            eval "$step"
            rc=$?
            state_executed=$((state_executed + 1))
        else
            eval "$step" 2>&1 | tee -a "$out_file"
            rc=${PIPESTATUS[0]:-${pipestatus[1]:-0}}
        fi
    done

    out_tail=$(tail -n 40 "$out_file" 2>/dev/null | head -c 4000)
    rm -f "$out_file"

    # 一步未执行且是用户终止 → 130；执行过任何步骤 → 最后一步的退出码
    if [[ $executed -eq 0 && $stopped_at -gt 0 ]]; then
        rc=130
    fi

    local summary
    if [[ $total -gt 1 ]]; then
        summary="多步执行: 共 $total 步，执行 $executed 步，跳过 $skipped 步"
        [[ $stopped_at -gt 0 ]] && summary="$summary，在第 $stopped_at 步被用户终止"
        summary="$summary。最后退出码 $rc"
    elif [[ $stopped_at -gt 0 ]]; then
        summary="用户选择不执行该命令"
    else
        summary="上一条命令执行结果: 退出码 $rc"
    fi
    if [[ $state_executed -gt 0 ]]; then
        summary="$summary（其中 $state_executed 步为 shell 状态命令 cd/变量等，已在当前 shell 生效，输出未捕获）"
    fi
    _a_conv_append "$mode" R "$(printf '{"role":"user","content":"%s"}' "$(_a_json_escape "$summary
输出(可能截断):
$out_tail")")"
    return $rc
}
