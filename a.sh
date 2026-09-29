# agent-cli-bash —— 自然语言转 bash 命令（支持多轮对话）
#
# 用法: source 本文件后，在终端输入:
#   a <自然语言>        生成命令，确认后在当前 shell 执行
#   a -p <自然语言>     只生成并打印命令，不执行
#   a -y <自然语言>     生成后直接执行，不询问（谨慎）
#   a -c                清空本会话的多轮对话上下文
#
# 多轮: 同一 shell 会话内，之前的问答、生成的命令、执行结果（退出码+输出尾部）
#       以及最近的终端历史会自动作为上下文发给 AI，支持"报错了帮我修"等追问。
#
# 兼容 bash 与 zsh。配置读取顺序: 环境变量 > ~/.config/agent-cli-bash/config
# 支持 DEEPSEEK_API_KEY / DEEPSEEK_BASE_URL / DEEPSEEK_MODEL

A_VERSION="0.1.0"

# ---------- 内部工具 ----------

# 读取配置文件，仅填充尚未设置的环境变量
_a_load_config() {
    local f=${A_CONFIG_FILE:-$HOME/.config/agent-cli-bash/config}
    [[ -r $f ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == \#* || $line != *=* ]] && continue
        key=${line%%=*}
        val=${line#*=}
        case $val in
            \"*\") val=${val#\"}; val=${val%\"} ;;
        esac
        case $key in
            DEEPSEEK_API_KEY)  [[ -n ${DEEPSEEK_API_KEY:-}  ]] || DEEPSEEK_API_KEY=$val ;;
            DEEPSEEK_BASE_URL) [[ -n ${DEEPSEEK_BASE_URL:-} ]] || DEEPSEEK_BASE_URL=$val ;;
            DEEPSEEK_MODEL)    [[ -n ${DEEPSEEK_MODEL:-}    ]] || DEEPSEEK_MODEL=$val ;;
        esac
    done < "$f"
}

# JSON 字符串转义（覆盖 bash/zsh 常见需要转义的字符）
_a_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# 从 stdin 的 JSON 中取 choices[0].message.content；失败时返回非 0
_a_json_content() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.choices[0].message.content // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    sys.stdout.write(d["choices"][0]["message"]["content"])
except Exception:
    sys.exit(1)' 2>/dev/null
    else
        return 1
    fi
}

# 从 stdin 的 JSON 中取 choices[0].delta.content（流式增量）。
# 输出约定: content 后总是补一个哨兵换行（调用方剥掉），内容自身的换行得以保留
_a_json_delta() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.choices[0].delta.content // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    c = d["choices"][0]["delta"].get("content")
    if c: sys.stdout.write(c + "\n")
except Exception:
    pass' 2>/dev/null
    else
        return 1
    fi
}

# 从 stdin 的 JSON 中取 error.message（用于友好报错）；失败时返回非 0
_a_json_error() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.error.message // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    sys.stdout.write(d["error"]["message"])
except Exception:
    sys.exit(1)' 2>/dev/null
    else
        return 1
    fi
}

# 清理 AI 返回内容：去掉 markdown 代码围栏与空行
_a_clean() {
    printf '%s' "$1" | sed -e '/^```/d' -e 's/^```[a-zA-Z0-9_-]*//' -e 's/```$//' | awk 'NF'
}

# 追加一条 JSON 消息到本会话对话（全局变量 _A_CONV，每行一条消息），上限 40 条
_a_conv_append() {
    if [[ -n ${_A_CONV:-} ]]; then
        _A_CONV="$_A_CONV
$1"
    else
        _A_CONV="$1"
    fi
    if [[ $(printf '%s\n' "$_A_CONV" | wc -l) -gt 40 ]]; then
        _A_CONV=$(printf '%s\n' "$_A_CONV" | tail -n 40)
    fi
}

# 判断命令是否直接改变当前 shell 状态（cd/export/alias/source/赋值等）。
# 这类命令必须绕过管道在当前 shell 执行，否则 cd、变量、别名只在子 shell 生效。
_a_shell_state() {
    local c=$1
    printf '%s' "$c" | grep -qE '(^|[;&|(]|\||&&) *(cd|pushd|popd|export|unset|setopt|unsetopt|shopt|set|alias|unalias|source|umask|ulimit|exec|trap)([^a-zA-Z0-9_-]|$)' \
        || printf '%s' "$c" | grep -qE '(^|[;&|]|&&) *\. +[^ ]' \
        || printf '%s' "$c" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*='
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

_a_help() {
    cat <<'EOF'
a —— 自然语言转 bash 命令（agent-cli-bash）

用法:
  a <自然语言>       让 AI 生成命令，确认后在当前 shell 执行
  a -p <自然语言>    只打印命令，不执行
  a -y <自然语言>    生成后直接执行，不询问（谨慎使用）
  a -c               清空本会话的多轮对话上下文
  a -h | --help      显示帮助
  a --version        显示版本

确认时: y=执行  n=不执行(退出码130)  i=忽略(退出码0)  直接回车等同 n

多步执行:
  AI 返回多行命令(多个连续步骤)时逐行确认，每一步都由你决策:
  y=执行此步并继续  n=终止剩余步骤  i=跳过此步继续后面的步骤
  高危/高权限命令(红色显示)必须逐条确认，即使 -y 也不会自动执行；
  写操作(黄色显示)有 ⚡ 提示。无终端环境下高危命令一律拒绝。
  AI 生成过程以流式实时显示(灰色暗淡)，正式命令以高亮颜色展示。

多轮对话:
  同一 shell 会话内，之前的问答、生成的命令及其执行结果（退出码+输出尾部）、
  最近的终端历史命令，会自动作为上下文发给 AI。支持追问，例如:
      a 列出当前目录的图片
      a 只要 png，并且按修改时间排序
      a 刚才那条报错了，帮我修复
  a -c 可随时清空上下文重新开始。

配置（环境变量或 ~/.config/agent-cli-bash/config）:
  DEEPSEEK_API_KEY   DeepSeek API 密钥（https://platform.deepseek.com/api_keys）
  DEEPSEEK_BASE_URL  API 地址，默认 https://api.deepseek.com
  DEEPSEEK_MODEL     模型，默认 deepseek-chat

示例:
  a 找出当前目录下最大的 5 个文件
  a 把所有 .png 图片压缩到 50% 质量
  a -p 查看本机公网 IP
  cat error.log | a 解释这个报错          # 管道内容作为上下文发送（限 8KB）
  git diff | a 帮我写一条提交信息
  dmesg | tail -50 | a                   # 管道输入下文字描述可省略
EOF
}

_a_err() {
    printf 'a: %s\n' "$1" >&2
}

# ---------- 主函数 ----------

a() {
    local print_only=0 auto_yes=0
    local OPTIND opt
    while getopts ":pych-:" opt; do
        case $opt in
            p) print_only=1 ;;
            y) auto_yes=1 ;;
            c) _A_CONV=''; printf '已清空本会话的对话上下文\n' >&2; return 0 ;;
            h) _a_help; return 0 ;;
            -)
                case $OPTARG in
                    help)    _a_help; return 0 ;;
                    version) printf 'agent-cli-bash %s\n' "$A_VERSION"; return 0 ;;
                    clear)   _A_CONV=''; printf '已清空本会话的对话上下文\n' >&2; return 0 ;;
                    *) _a_err "未知选项 --$OPTARG（try: a -h）"; return 2 ;;
                esac
                ;;
            *) _a_err "未知选项 -$OPTARG（try: a -h）"; return 2 ;;
        esac
    done
    shift $((OPTIND - 1))

    # 管道输入: cat error.log | a 解释这个报错
    # stdin 非终端时读取内容作为上下文（限 8KB）；此后交互确认改从 /dev/tty 读取
    local stdin_data=
    if [[ ! -t 0 ]]; then
        stdin_data=$(head -c 8192 2>/dev/null)
    fi

    if [[ $# -eq 0 && -z $stdin_data ]]; then
        _a_help
        return 2
    fi
    local query="$*"
    [[ -z $query ]] && query="分析以上管道输入，给出下一步需要执行的 bash 命令"
    _a_load_config

    local api_key=${DEEPSEEK_API_KEY:-}
    local base_url=${DEEPSEEK_BASE_URL:-https://api.deepseek.com}
    local model=${DEEPSEEK_MODEL:-deepseek-chat}
    local timeout=${A_TIMEOUT:-60}

    if [[ -z $api_key ]]; then
        _a_err "未配置 DEEPSEEK_API_KEY"
        printf '  1) 在 https://platform.deepseek.com/api_keys 创建密钥\n' >&2
        printf '  2) export DEEPSEEK_API_KEY=sk-xxx  或写入 ~/.config/agent-cli-bash/config\n' >&2
        return 1
    fi
    command -v curl >/dev/null 2>&1 || { _a_err "需要 curl"; return 1; }
    if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        _a_err "需要 jq 或 python3 之一来解析响应"
        return 1
    fi

    if [[ -n ${_A_CONV:-} ]]; then
        printf '💬 接续本会话对话（a -c 可清空）\n' >&2
    fi

    local sys_prompt sys_json user_json msgs_json
    sys_prompt="You convert natural language into bash/zsh command(s). Rules: reply with the command(s) ONLY - no explanation, no markdown fences, no leading \$. If the task needs multiple sequential steps, output multiple lines (one command per line) or chain with && / ;. You may receive prior conversation: earlier requests, the commands you proposed, and their execution results (exit code and output). Use them to interpret follow-up requests like 'only the first 10' or 'fix that error'. A snippet of recent shell history may also be provided for context. Target OS: $(uname -s) ($(uname -m))."
    sys_json=$(printf '{"role":"system","content":"%s"}' "$(_a_json_escape "$sys_prompt")")

    # 用户消息 = 管道输入(如有) + 最近终端历史(参考) + 本次请求
    local hist user_content=""
    hist=$(_a_recent_history)
    if [[ -n $stdin_data ]]; then
        printf '📎 已读取管道输入 %d 字节（超过 8KB 截断）\n' "${#stdin_data}" >&2
        user_content="管道输入(可能截断):
$stdin_data

"
    fi
    if [[ -n $hist ]]; then
        user_content="${user_content}最近终端历史命令(仅作参考):
$hist

"
    fi
    user_content="${user_content}请求: $query"
    user_json=$(printf '{"role":"user","content":"%s"}' "$(_a_json_escape "$user_content")")

    msgs_json="$sys_json,$user_json"
    if [[ -n ${_A_CONV:-} ]]; then
        msgs_json="$sys_json,$(printf '%s\n' "$_A_CONV" | tail -n 20 | paste -sd ',' -),$user_json"
    fi

    local payload
    payload=$(printf '{"model":"%s","messages":[%s],"temperature":0,"max_tokens":512,"stream":true}' \
        "$(_a_json_escape "$model")" "$msgs_json")

    # 流式请求（SSE）：AI 生成的内容实时显示；增量与异常分别落盘，循环外汇总
    printf '🤖 思考中...\r' >&2
    local raw_file content_file err_file curl_rc=0 content
    raw_file=$(mktemp "${TMPDIR:-/tmp}/a-raw.XXXXXX")
    content_file=$(mktemp "${TMPDIR:-/tmp}/a-cc.XXXXXX")
    err_file=$(mktemp "${TMPDIR:-/tmp}/a-err.XXXXXX")

    curl -sS -N --max-time "$timeout" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $api_key" \
        -d "$payload" \
        "$base_url/chat/completions" 2>"$err_file" | tee "$raw_file" | {
        local line data delta shown=0
        while IFS= read -r line; do
            if [[ $line == data:* ]]; then
                data=${line#data: }
                [[ $data == '[DONE]' ]] && break
                # x 占位保留输出，再剥掉哨兵换行：内容内部的换行不丢、也不多出换行
                delta=$(printf '%s' "$data" | _a_json_delta; printf x)
                delta=${delta%x}
                delta=${delta%$'\n'}
                if [[ -n $delta ]]; then
                    if [[ $shown == 0 ]]; then
                        printf '\r\033[K\033[2m' >&2
                        shown=1
                    fi
                    printf '%s' "$delta" >&2
                    printf '%s' "$delta" >> "$content_file"
                fi
            else
                [[ -n $line ]] && printf '%s\n' "$line" >> "$err_file"
            fi
        done
    }
    curl_rc=${PIPESTATUS[0]:-${pipestatus[1]:-0}}
    printf '\033[0m\n' >&2

    content=$(cat "$content_file" 2>/dev/null)

    if [[ -z $content ]]; then
        # 流式失败：优先按错误 JSON 解析（如 401），其次尝试整包解析（网关忽略 stream 参数时）
        printf '\r\033[K' >&2
        local errout emsg
        errout=$(cat "$err_file" "$raw_file" 2>/dev/null | head -c 2000)
        content=$(printf '%s' "$errout" | _a_json_content)
        if [[ -z $content ]]; then
            emsg=$(printf '%s' "$errout" | _a_json_error)
            if [[ -n $emsg ]]; then
                _a_err "API 错误: $emsg"
            elif [[ $curl_rc -ne 0 ]]; then
                _a_err "请求失败 (curl 退出码 $curl_rc): $(head -c 300 "$err_file")"
            else
                _a_err "无法解析响应: ${errout:0:300}"
            fi
            rm -f "$raw_file" "$content_file" "$err_file"
            return 1
        fi
    fi
    rm -f "$raw_file" "$content_file" "$err_file"

    local cmd
    cmd=$(_a_clean "$content")
    if [[ -z $cmd ]]; then
        _a_err "AI 返回内容为空"
        return 1
    fi

    # 记入本会话对话：本次请求 + AI 给出的命令（未执行也记录，便于下一轮追问）
    _a_conv_append "$user_json"
    _a_conv_append "$(printf '{"role":"assistant","content":"%s"}' "$(_a_json_escape "$cmd")")"

    if [[ $print_only == 1 ]]; then
        printf '%s\n' "$cmd"
        return 0
    fi

    # 写入 shell 历史，方便 ↑ 找回
    if [[ -n ${ZSH_VERSION:-} ]]; then
        print -s -- "$cmd" 2>/dev/null
    elif [[ -n ${BASH_VERSION:-} ]]; then
        history -s -- "$cmd" 2>/dev/null
    fi

    # 多步逐行确认：AI 返回多行命令时逐步执行，每一步都由用户决策，
    # 涉及写/高权限的操作先显示风险提示。-y 是用户显式授权，跳过询问。
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
    _a_conv_append "$(printf '{"role":"user","content":"%s"}' "$(_a_json_escape "$summary
输出(可能截断):
$out_tail")")"
    return $rc
}
