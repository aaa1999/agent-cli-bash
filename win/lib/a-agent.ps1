# a-agent.ps1 —— L5 agent 循环域（harness，PowerShell 版）
# turn/step 循环（对齐 dsh AgentLoop.step 语义）: 组装请求(system + 事件日志投影 + 工具表)
# → 模型返回 tool_calls → 逐个经 a-tools 管线执行 → 结果回填事件日志 → 再次请求，
# 直到模型给出纯文本回答（本轮收尾）或达到步数上限。
# 依赖: L1(_a_agent_request) L2(_a_ev_*) L4(_a_tool_*)；不持有任何产品层约定。
# 由 a.ps1 在加载时 dot-source，不单独使用。
# 与 bash 版差异: 无 trap INT 对应物，Ctrl-C 直接中断当前命令（PowerShell 语义），
# 退出码经 $global:A_LAST_RC 传递。

# 取 tool_call 的 arguments: 字符串则原样，个别网关直传对象则紧凑序列化
function _a_call_args($Call) {
    $a = $Call.function.arguments
    if ($null -eq $a) { return '{}' }
    if ($a -is [string]) { return $a }
    return (ConvertTo-Json -InputObject $a -Compress -Depth 8)
}

function _a_agent([string]$Query, [string]$StdinData, [int]$AutoYes) {
    if (-not (_a_resolve_provider)) { $global:A_LAST_RC = 1; return }
    if (-not $global:_A_AGENT_CWD) { $global:_A_AGENT_CWD = (Get-Location).Path }

    if (_a_ev_get 'agent') {
        Write-Host '💬 接续本会话 agent 对话（a -c 可清空）'
    }

    $osDesc = ''
    try { $osDesc = [Environment]::OSVersion.VersionString } catch { $osDesc = 'unknown' }
    $sys_prompt = "You are an autonomous terminal agent. Complete the user's task by calling tools, then finish with a plain-text answer (no tool calls). Rules: explore first - use glob/grep/read to verify facts before acting; NEVER invent file or directory names, always confirm they exist. Each pwsh call runs in an isolated child process (cd/variable assignments do not persist); the session working directory is shared across calls via working_directory. Prefer edit over rewrite for existing files. Use todo_write to plan genuinely multi-step work, ask_user_question only when blocked on a decision only the user can make. Tool results are truthful: [exit code: N], [timed out ...], [user declined this tool call] and Error: lines tell you what actually happened - react to them instead of repeating a failed attempt. When done, summarize the outcome and the key files/commands involved. Answer in the user's language. Target shell: PowerShell $($PSVersionTable.PSVersion) on $osDesc."

    # 用户消息 = 管道输入(如有) + 环境上下文 + 本次任务（与 run/ask 模式同构）
    $user_content = ''
    if ($StdinData -ne '') {
        Write-Host ('📎 已读取管道输入 {0} 字节（超过 8KB 截断）' -f $StdinData.Length)
        $user_content = "管道输入(可能截断):`n$StdinData`n`n"
    }
    $env_ctx = _a_env_context $Query
    if ($env_ctx) { $user_content = $user_content + "当前环境:`n$env_ctx`n`n" }
    $user_content = $user_content + "任务: $Query"

    $sysObj = [ordered]@{ role = 'system'; content = $sys_prompt }
    $userObj = [ordered]@{ role = 'user'; content = $user_content }
    _a_ev_append 'agent' 'U' (ConvertTo-Json -InputObject $userObj -Compress)

    $maxSteps = 16
    if ($env:A_AGENT_MAX_STEPS -match '^\d+$') { $maxSteps = [int]$env:A_AGENT_MAX_STEPS }
    $steps = 0
    $tools = _a_tools_schemas

    while ($true) {
        # 注意: _a_ev_derive 用 , @() 防折叠返回，赋值拿到的是平铺数组;
        # 不能写 @($sysObj) + @(_a_ev_derive ...) —— @() 不展平嵌套数组，messages 会多出一层
        $msgs = @($sysObj)
        $derived = _a_ev_derive 'agent'
        if ($derived) { $msgs += @($derived) }
        if (-not (_a_agent_request $msgs $tools)) { $global:A_LAST_RC = 1; return }

        # 纯文本回答（无 tool_calls）= 本轮收尾
        if (@($global:_A_AGENT_TOOL_CALLS).Count -eq 0) {
            _a_ev_append 'agent' 'A' (ConvertTo-Json -InputObject ([ordered]@{ role = 'assistant'; content = $global:_A_AGENT_CONTENT }) -Compress)
            Write-Output $global:_A_AGENT_CONTENT
            $global:A_LAST_RC = 0
            return
        }

        Write-Host ''
        Write-Host ('—— 第 {0} 步 ——' -f ($steps + 1)) -ForegroundColor White

        # assistant 消息原样回放（content + tool_calls 按响应原文，保证 id/参数不走样）
        $aObj = [ordered]@{ role = 'assistant'; content = $global:_A_AGENT_CONTENT; tool_calls = @($global:_A_AGENT_TOOL_CALLS) }
        _a_ev_append 'agent' 'A' (ConvertTo-Json -InputObject $aObj -Compress -Depth 32)

        # 逐个执行（顺序执行: 确认 UX 决定不能并行）
        foreach ($call in @($global:_A_AGENT_TOOL_CALLS)) {
            $cid = "$($call.id)"
            $name = "$($call.function.name)"
            $cargs = _a_call_args $call
            $text = _a_tool_execute $AutoYes $name $cargs
            _a_ev_append 'agent' 'T' (ConvertTo-Json -InputObject ([ordered]@{ role = 'tool'; tool_call_id = $cid; content = $text }) -Compress)
        }

        $steps++
        if ($steps -ge $maxSteps) {
            _a_err "已达单次任务步数上限 $maxSteps（A_AGENT_MAX_STEPS 可调大后继续追问）"
            $global:A_LAST_RC = 1
            return
        }
    }
}
