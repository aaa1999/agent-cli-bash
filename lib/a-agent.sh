# a-agent.sh —— L5 agent 循环域（harness）
# turn/step 循环（对齐 dsh AgentLoop.step 语义）: 组装请求(system + 事件日志投影 + 工具表)
# → 模型返回 tool_calls → 逐个经 a-tools 管线执行 → 结果回填事件日志 → 再次请求，
# 直到模型给出纯文本回答（本轮收尾）或达到步数上限。
# 依赖: L1(_a_agent_request) L2(_a_ev_*) L4(_a_tool_*)；不持有任何产品层约定。
# 由 a.sh 在加载时 source，不单独使用。

# 取 tool_call 的 arguments: 字符串则原样，个别网关直传对象则紧凑序列化
_a_call_args() {
    if command -v jq >/dev/null 2>&1; then
        jq -r 'if (.function.arguments | type) == "string" then .function.arguments
               else (.function.arguments | tojson) end' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    a = json.load(sys.stdin)["function"]["arguments"]
    sys.stdout.write(a if isinstance(a, str) else json.dumps(a, ensure_ascii=False, separators=(",", ":")))
except Exception:
    pass' 2>/dev/null
    else
        return 1
    fi
}

_a_agent() { # _a_agent <query> <stdin_data> <auto_yes>
    local query=$1 stdin_data=$2 auto_yes=$3
    _a_resolve_provider || return 1
    _A_AGENT_CWD=${_A_AGENT_CWD:-$PWD}

    if [[ -n $(_a_ev_get agent) ]]; then
        printf '💬 接续本会话 agent 对话（a -c 可清空）\n' >&2
    fi

    local sys_prompt sys_json user_content="" user_json env_ctx
    sys_prompt="You are an autonomous terminal agent. Complete the user's task by calling tools, then finish with a plain-text answer (no tool calls). Rules: explore first - use glob/grep/read to verify facts before acting; NEVER invent file or directory names, always confirm they exist. Each bash call runs in an isolated subshell (cd/export do not persist); the session working directory is shared across calls via working_directory. Prefer edit over rewrite for existing files. Use todo_write to plan genuinely multi-step work, ask_user_question only when blocked on a decision only the user can make. Tool results are truthful: [exit code: N], [timed out ...], [user declined this tool call] and Error: lines tell you what actually happened - react to them instead of repeating a failed attempt. When done, summarize the outcome and the key files/commands involved. Answer in the user's language. Target OS: $(uname -s) ($(uname -m))."
    sys_json=$(printf '{"role":"system","content":"%s"}' "$(_a_json_escape "$sys_prompt")")

    # 用户消息 = 管道输入(如有) + 环境上下文 + 本次任务（与 run/ask 模式同构）
    if [[ -n $stdin_data ]]; then
        printf '📎 已读取管道输入 %d 字节（超过 8KB 截断）\n' "${#stdin_data}" >&2
        user_content="管道输入(可能截断):
$stdin_data

"
    fi
    env_ctx=$(_a_env_context "$query" 2>/dev/null)
    if [[ -n $env_ctx ]]; then
        user_content="${user_content}当前环境:
$env_ctx

"
    fi
    user_content="${user_content}任务: $query"
    user_json=$(printf '{"role":"user","content":"%s"}' "$(_a_json_escape "$user_content")")
    _a_ev_append agent U "$user_json"

    local max_steps=${A_AGENT_MAX_STEPS:-16}
    [[ $max_steps =~ ^[0-9]+$ ]] || max_steps=16
    local steps=0 msgs derived call cid name cargs text assistant_json req_rc=0
    local tools_json
    tools_json=$(_a_tools_schema_json)

    # Ctrl-C 置位标志: 当前调用结束后优雅收尾（130 语义与项目其余部分一致）
    local int_hit=0
    trap 'int_hit=1' INT

    while :; do
        derived=$(_a_ev_derive agent)
        if [[ -n $derived ]]; then
            msgs="$sys_json,$derived"
        else
            msgs="$sys_json"
        fi
        _a_agent_request "$msgs" "$tools_json"
        req_rc=$?
        if [[ $int_hit == 1 ]]; then
            trap - INT
            printf '\n已中断\n' >&2
            return 130
        fi
        if [[ $req_rc -ne 0 ]]; then
            trap - INT
            return 1
        fi

        # 纯文本回答（无 tool_calls）= 本轮收尾
        if [[ -z $_A_AGENT_TOOL_CALLS ]]; then
            _a_ev_append agent A "$(printf '{"role":"assistant","content":"%s"}' "$(_a_json_escape "$_A_AGENT_CONTENT")")"
            trap - INT
            printf '%s\n' "$_A_AGENT_CONTENT"
            return 0
        fi

        printf '\n\033[1m—— 第 %d 步 ——\033[0m\n' "$((steps + 1))" >&2

        # assistant 消息原样回放（content + tool_calls 按响应原文，保证 id/参数不走样）
        assistant_json=$(printf '{"role":"assistant","content":"%s","tool_calls":[%s]}' \
            "$(_a_json_escape "$_A_AGENT_CONTENT")" \
            "$(printf '%s\n' "$_A_AGENT_TOOL_CALLS" | paste -sd, -)")
        _a_ev_append agent A "$assistant_json"

        # 逐个执行（顺序执行：确认 UX 决定不能并行）；中断后剩余调用补占位结果，
        # 否则事件日志里 assistant 的 tool_calls 没有对应 tool 消息，下轮请求会被 API 拒绝
        while IFS= read -r call; do
            [[ -n $call ]] || continue
            cid=$(printf '%s' "$call" | _a_json_path '.id')
            name=$(printf '%s' "$call" | _a_json_path '.function.name')
            cargs=$(printf '%s' "$call" | _a_call_args)
            if [[ $int_hit == 1 ]]; then
                text='[interrupted by user before execution]'
            else
                text=$(_a_tool_execute "$auto_yes" "$name" "$cargs")
            fi
            _a_ev_append agent T "$(printf '{"role":"tool","tool_call_id":"%s","content":"%s"}' \
                "$(_a_json_escape "$cid")" "$(_a_json_escape "$text")")"
        done <<EOF
$_A_AGENT_TOOL_CALLS
EOF

        if [[ $int_hit == 1 ]]; then
            trap - INT
            printf '\n已中断\n' >&2
            return 130
        fi

        steps=$((steps + 1))
        if [[ $steps -ge $max_steps ]]; then
            trap - INT
            _a_err "已达单次任务步数上限 $max_steps（A_AGENT_MAX_STEPS 可调大后继续追问）"
            return 1
        fi
    done
}
