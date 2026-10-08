# agent-cli-bash —— 自然语言转 bash 命令（支持多轮对话）
#
# 用法: source 本文件后，在终端输入:
#   a <自然语言>        生成命令，确认后在当前 shell 执行
#   a -p <自然语言>     只生成并打印命令，不执行
#   a -y <自然语言>     生成后直接执行，不询问（谨慎）
#   a ask <问题>        自由问答：直接给答案，不生成/执行命令
#   a -c                清空本会话的多轮对话上下文
#
# 多轮: 同一 shell 会话内，之前的问答、生成的命令、执行结果（退出码+输出尾部）、
#       当前目录/git 状态、目录条目（与请求相关的优先入选）以及最近的终端历史
#       会自动作为上下文发给 AI，支持"报错了帮我修"等追问。
#       AI 不得编造文件名: 所指目标不明确时以 ASK: 反问，按提示补充信息即可同轮继续。
#
# 兼容 bash 与 zsh。配置读取顺序: 环境变量 > ~/.config/agent-cli-bash/config
# 支持 A_PROVIDER / A_API_KEY / A_BASE_URL / A_MODEL（`a providers` 查看内置提供商）
# 旧版 DEEPSEEK_API_KEY / DEEPSEEK_BASE_URL / DEEPSEEK_MODEL 仍然兼容
#
# 结构: 本文件是入口与产品层（prompt/输出解析/UX）；通用 harness 在 lib/ 下——
#   lib/a-api.sh  传输域（提供商/配置/SSE 客户端）  lib/a-ctx.sh  上下文域（会话/环境采集）
#   lib/a-exec.sh 执行域（风险/确认执行）
# 仓库需整体携带（a.sh 与 lib/ 同级），rc 只需 source 本文件。

A_VERSION="0.5.0"

# ---------- 加载 harness ----------
# 定位本文件所在目录（兼容 bash/zsh、相对路径与异地 cwd），lib 随仓库走。
# 不做防重入: 重复 source 会重定义全部函数，便于更新后直接重新加载。
if [[ -n ${ZSH_VERSION:-} ]]; then
    _A_SELF=${(%):-%x}
else
    _A_SELF=${BASH_SOURCE[0]}
fi
_A_HOME=$(cd -- "$(dirname -- "$_A_SELF")" && pwd)
source "$_A_HOME/lib/a-api.sh"
source "$_A_HOME/lib/a-ctx.sh"
source "$_A_HOME/lib/a-exec.sh"

# ---------- 产品层 ----------

# 能力模式表: 每个模式一条独立会话（_A_CONV_<mode>），a -c 全部清空
_A_MODES=(run ask)

# 清理 AI 返回内容：去掉 markdown 代码围栏与空行
_a_clean() {
    printf '%s' "$1" | sed -e '/^```/d' -e 's/^```[a-zA-Z0-9_-]*//' -e 's/```$//' | awk 'NF'
}

# run 模式的输出解析: 去围栏 + 左端去空白（保证 ASK: 前缀检测稳定）；解析后为空则报错
_a_run_parse() {
    local c
    c=$(_a_clean "$1")
    c=${c#"${c%%[![:space:]]*}"}
    if [[ -z $c ]]; then
        _a_err "AI 返回内容为空"
        return 1
    fi
    printf '%s\n' "$c"
}

# ---------- 产品层: 帮助 ----------

_a_help() {
    cat <<'EOF'
a —— 自然语言转 bash 命令（agent-cli-bash）

用法:
  a <自然语言>       让 AI 生成命令，确认后在当前 shell 执行
  a -p <自然语言>    只打印命令，不执行
  a -y <自然语言>    生成后直接执行，不询问（谨慎使用）
  a ask <问题>       自由问答：直接回答，不生成/执行命令（支持管道输入）
  a -c               清空本会话的多轮对话上下文
  a --show           查看当前会话的上下文构成（轮次/体积/裁剪情况）
  a -h | --help      显示帮助
  a --version        显示版本
  a providers        列出内置模型提供商
  a setup            交互式配置提供商与密钥（写入 config，600 权限，立即生效）

确认时: y=执行  n=不执行(退出码130)  i=忽略(退出码0)  直接回车等同 n

多步执行:
  AI 返回多行命令时按完整 shell 结构切成步骤(跨行的 for/while/if/case、heredoc、
  续行等作为一步整体)，逐步确认，每一步都由你决策:
  y=执行此步并继续  n=终止剩余步骤  i=跳过此步继续后面的步骤
  高危/高权限命令(红色显示)必须逐条确认，即使 -y 也不会自动执行；
  写操作(黄色显示)有 ⚡ 提示。无终端环境下高危命令一律拒绝。
  AI 生成过程以流式实时显示(灰色暗淡)，正式命令以高亮颜色展示。

步骤超时:
  每步命令受 A_STEP_TIMEOUT 看护(默认 600 秒，0=禁用)，防止 tail -f 之类
  挂住不退出；超时先 TERM 后 KILL 整个命令进程组，退出码 124，超时情况会
  记入对话上下文供 AI 下一轮参考。cd/变量等 shell 状态命令不设超时。

多轮对话:
  同一 shell 会话内，之前的问答、生成的命令及其执行结果（退出码+输出尾部）、
  当前目录与 git 状态、目录条目、最近的终端历史命令，会自动作为上下文发给 AI。
  支持追问，例如:
      a 列出当前目录的图片
      a 只要 png，并且按修改时间排序
      a 刚才那条报错了，帮我修复
  a -c 可随时清空上下文重新开始。
  命令与 a ask 问答的上下文分模式隔离，互不混入（a -c 一并清空）。

上下文理解:
  目录条目与请求相关者优先入选（如"算 linuxiso 的 sha256"会优先列出 linuxmint-*.iso），
  其余按修改时间补足；AI 被要求不得编造文件名，所指文件不明确时会把问题以 ❓ 反问，
  按提示输入补充信息即可同轮继续生成命令，直接回车取消。

配置（环境变量或 ~/.config/agent-cli-bash/config）:
  A_PROVIDER         提供商: deepseek(默认) openai kimi qwen zhipu grok ollama openrouter
  A_API_KEY          API 密钥；未设时自动读取提供商对应变量（如 OPENAI_API_KEY）
  A_BASE_URL         覆盖 API 地址；A_PROVIDER=custom 时必填
  A_MODEL            覆盖模型名
  兼容: 只配 DEEPSEEK_API_KEY / DEEPSEEK_BASE_URL / DEEPSEEK_MODEL 时行为与旧版一致
  A_MAX_RETRIES      网络错误/429/5xx 自动重试次数，默认 3（0=禁用），指数退避
  A_MAX_CONTEXT_CHARS 会话上下文字符预算，默认 24000（约 12K token），超出裁掉最旧的轮次
  A_TIMEOUT          单次 API 请求超时秒数，默认 60
  A_STEP_TIMEOUT     单步命令执行超时秒数，默认 600（0=禁用）；超时终止该步，退出码 124
  A_DIR_ENTRIES      目录条目注入上限，默认 15（0=不注入）；超出时相关的优先、其余按修改时间

示例:
  a 找出当前目录下最大的 5 个文件
  a 把所有 .png 图片压缩到 50% 质量
  a -p 查看本机公网 IP
  cat error.log | a 解释这个报错          # 管道内容作为上下文发送（限 8KB）
  git diff | a 帮我写一条提交信息
  dmesg | tail -50 | a                   # 管道输入下文字描述可省略
EOF
}

# ---------- 主函数: 参数解析与模式路由 ----------

a() {
    local print_only=0 auto_yes=0
    local OPTIND opt
    while getopts ":pych-:" opt; do
        case $opt in
            p) print_only=1 ;;
            y) auto_yes=1 ;;
            c) local m; for m in "${_A_MODES[@]}"; do _a_conv_clear "$m"; done
               printf '已清空本会话的对话上下文\n' >&2; return 0 ;;
            h) _a_help; return 0 ;;
            -)
                case $OPTARG in
                    help)     _a_help; return 0 ;;
                    version)  printf 'agent-cli-bash %s\n' "$A_VERSION"; return 0 ;;
                    providers) _a_list_providers; return 0 ;;
                    setup)    _a_setup; return ;;
                    show)     _a_show "${_A_MODES[@]}"; return 0 ;;
                    clear)   local m; for m in "${_A_MODES[@]}"; do _a_conv_clear "$m"; done
                             printf '已清空本会话的对话上下文\n' >&2; return 0 ;;
                    *) _a_err "未知选项 --$OPTARG（try: a -h）"; return 2 ;;
                esac
                ;;
            *) _a_err "未知选项 -$OPTARG（try: a -h）"; return 2 ;;
        esac
    done
    shift $((OPTIND - 1))

    # 子命令形式: a providers / a setup
    if [[ ${1:-} == providers ]]; then
        _a_list_providers
        return 0
    fi
    if [[ ${1:-} == setup ]]; then
        _a_setup
        return
    fi

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

    # 子命令: a ask <问题> —— 自由问答（不生成命令、不执行、输出原样打印）
    if [[ ${1:-} == ask ]]; then
        shift
        query="$*"
        [[ -z $query ]] && query="分析以上管道输入，回答其中的问题"
        _a_mode_ask "$query" "$stdin_data"
        return $?
    fi

    [[ -z $query ]] && query="分析以上管道输入，给出下一步需要执行的 bash 命令"
    _a_run "$query" "$stdin_data" "$print_only" "$auto_yes"
}

# ---------- run 模式: 自然语言 -> 命令，确认后执行 ----------

_a_run() { # _a_run <query> <stdin_data> <print_only> <auto_yes>
    local query=$1 stdin_data=$2 print_only=$3 auto_yes=$4
    _a_resolve_provider || return 1

    if [[ -n $(_a_conv_get run) ]]; then
        printf '💬 接续本会话对话（a -c 可清空）\n' >&2
    fi

    local sys_prompt sys_json user_json
    sys_prompt="You convert natural language into bash/zsh command(s). Rules: reply with the command(s) ONLY - no explanation, no markdown fences, no leading \$. If the task needs multiple sequential steps, output multiple lines (one command per line) or chain with && / ;. You may receive prior conversation: earlier requests, the commands you proposed, and their execution results (exit code and output). Use them to interpret follow-up requests like 'only the first 10' or 'fix that error'. The current working directory (with a git state summary and a directory listing) and a snippet of recent shell history may also be provided as context. The directory listing may be partial (its header shows the total entry count): NEVER invent file or directory names - use only exact names that appear in the context, and interpret loose user wording against the listed names (e.g. 'linuxiso' matches a listed linuxmint-*.iso). If the file/directory the user refers to is still ambiguous or absent from the context, do NOT guess: reply with one short clarifying question, alone on a single line prefixed exactly with 'ASK: ' (example: ASK: 目录里有多个 iso 文件，要计算哪一个的 sha256？); after the user's supplementary answer, generate the command. Target OS: $(uname -s) ($(uname -m))."
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
    local env_ctx
    env_ctx=$(_a_env_context "$query" 2>/dev/null)
    if [[ -n $env_ctx ]]; then
        user_content="${user_content}当前环境:
$env_ctx

"
    fi
    if [[ -n $hist ]]; then
        user_content="${user_content}最近终端历史命令(仅作参考):
$hist

"
    fi
    user_content="${user_content}请求: $query"
    user_json=$(printf '{"role":"user","content":"%s"}' "$(_a_json_escape "$user_content")")

    local cmd raw ask_rounds=0 ask_content
    raw=$(_a_generate "$(_a_msgs_json run "$sys_json" "$user_json")" \
        "$_A_R_URL" "$_A_R_KEY" "$_A_R_TIMEOUT" "$_A_R_MODEL") || return 1
    cmd=$(_a_run_parse "$raw") || return 1

    # AI 拿不准时反问（回复以 ASK: 开头——run 模式的 prompt 约定）: 展示问题并等用户
    # 补充，把「问题+补充」并入会话后重新生成，最多 3 轮；空回答或无终端则取消。
    while [[ $cmd == ASK:* ]]; do
        if [[ $ask_rounds -ge 3 ]]; then
            _a_err "AI 连续追问已达 3 轮上限，请补充更明确的信息后重试"
            return 1
        fi
        ask_content=${cmd#ASK:}
        ask_content=${ask_content#"${ask_content%%[![:space:]]*}"}
        printf '❓ %s\n' "$ask_content" >&2
        _a_prompt_answer '补充信息(直接回车取消): ' || true
        if [[ -z $reply ]]; then
            _a_err "已取消（未补充信息）"
            return 1
        fi
        _a_conv_append run Q "$user_json"
        _a_conv_append run A "$(printf '{"role":"assistant","content":"%s"}' "$(_a_json_escape "$cmd")")"
        user_json=$(printf '{"role":"user","content":"%s"}' "$(_a_json_escape "补充: $reply")")
        ask_rounds=$((ask_rounds + 1))
        raw=$(_a_generate "$(_a_msgs_json run "$sys_json" "$user_json")" \
            "$_A_R_URL" "$_A_R_KEY" "$_A_R_TIMEOUT" "$_A_R_MODEL") || return 1
        cmd=$(_a_run_parse "$raw") || return 1
    done

    # 记入本会话对话：本次请求（或 ASK 补充后的最终请求）+ AI 给出的命令（未执行也记录，便于下一轮追问）
    _a_conv_append run Q "$user_json"
    _a_conv_append run A "$(printf '{"role":"assistant","content":"%s"}' "$(_a_json_escape "$cmd")")"

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

    # 多步逐行确认执行（风险提示、y/n/i、130 语义、R 消息回写都在其中）
    _a_exec_steps run "$auto_yes" "$cmd"
}

# ---------- ask 模式: 自由文本问答（第一个挂在 harness 上的新能力） ----------
# 复用 L1 传输（提供商/重试/流式）与 L2 上下文（独立 ask 会话）；不做命令清洗与执行。

_a_mode_ask() { # _a_mode_ask <query> <stdin_data>
    local query=$1 stdin_data=$2
    _a_resolve_provider || return 1

    if [[ -n $(_a_conv_get ask) ]]; then
        printf '💬 接续本会话问答（a -c 可清空）\n' >&2
    fi

    local sys_prompt sys_json user_json user_content=""
    sys_prompt="You are a helpful terminal assistant. Answer the user's question concisely and accurately, in the language the user writes. You may receive piped input, the current environment (working directory, git state, directory listing) and prior Q&A turns as context. This is a Q&A mode: give explanations/answers, and only show a shell command inside a fenced code block when it helps the answer."
    sys_json=$(printf '{"role":"system","content":"%s"}' "$(_a_json_escape "$sys_prompt")")

    if [[ -n $stdin_data ]]; then
        printf '📎 已读取管道输入 %d 字节（超过 8KB 截断）\n' "${#stdin_data}" >&2
        user_content="管道输入(可能截断):
$stdin_data

"
    fi
    local env_ctx
    env_ctx=$(_a_env_context "$query" 2>/dev/null)
    if [[ -n $env_ctx ]]; then
        user_content="${user_content}当前环境:
$env_ctx

"
    fi
    user_content="${user_content}问题: $query"
    user_json=$(printf '{"role":"user","content":"%s"}' "$(_a_json_escape "$user_content")")

    local raw
    raw=$(_a_generate "$(_a_msgs_json ask "$sys_json" "$user_json")" \
        "$_A_R_URL" "$_A_R_KEY" "$_A_R_TIMEOUT" "$_A_R_MODEL" 1024 0) || return 1

    _a_conv_append ask Q "$user_json"
    _a_conv_append ask A "$(printf '{"role":"assistant","content":"%s"}' "$(_a_json_escape "$raw")")"

    printf '%s\n' "$raw"
    return 0
}
