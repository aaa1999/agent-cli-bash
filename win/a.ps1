# agent-cli-bash —— 自然语言转 PowerShell 命令（支持多轮对话）· Windows 版
#
# 用法: dot-source 本文件后，在终端输入:
#   a <自然语言>        生成命令，确认后在当前会话执行
#   a -p <自然语言>     只生成并打印命令，不执行
#   a -y <自然语言>     生成后直接执行，不询问（谨慎）
#   a ask <问题>        自由问答：直接给答案，不生成/执行命令
#   a -c                清空本会话的多轮对话上下文
#
# 多轮: 同一 PowerShell 会话内，之前的问答、生成的命令、执行结果（退出码+输出尾部）、
#       当前目录/git 状态、目录条目（与请求相关的优先入选）以及最近的会话历史
#       会自动作为上下文发给 AI，支持"报错了帮我修"等追问。
#       AI 不得编造文件名: 所指目标不明确时以 ASK: 反问，按提示补充信息即可同轮继续。
#
# 配置读取顺序: 环境变量 > ~\.config\agent-cli-bash\config（与 bash 版同格式）
# 支持 A_PROVIDER / A_API_KEY / A_BASE_URL / A_MODEL（`a providers` 查看内置提供商）
# 兼容 Windows PowerShell 5.1 与 PowerShell 7+；依赖系统自带 curl.exe，无需 jq。
#
# 结构: 本文件是入口与产品层（prompt/输出解析/UX）；通用 harness 在 lib/ 下——
#   lib/a-api.ps1  传输域（提供商/配置/SSE 客户端）  lib/a-ctx.ps1  上下文域（会话/环境采集）
#   lib/a-exec.ps1 执行域（风险/确认执行）
# 仓库需整体携带（a.ps1 与 lib/ 同级），$PROFILE 里只需一行 dot-source 本文件。
#
# 与 bash 版的差异: PowerShell 函数没有独立退出码，a 的执行结果码在 $A_LAST_RC；
# 管道不派生子 shell，cd 与 $env: 赋值天然在当前会话生效。

$global:A_VERSION = '0.5.0'

# ---------- 加载 harness ----------
# 定位本文件所在目录（$PSScriptRoot 兼容任意 cwd 与相对路径 dot-source），lib 随仓库走。
# 不做防重入: 重复 dot-source 会重定义全部函数，便于更新后直接重新加载。
. (Join-Path $PSScriptRoot 'lib/a-api.ps1')
. (Join-Path $PSScriptRoot 'lib/a-ctx.ps1')
. (Join-Path $PSScriptRoot 'lib/a-exec.ps1')

# ---------- 产品层 ----------

# 能力模式表: 每个模式一条独立会话（_A_CONV 里按模式分键），a -c 全部清空
$global:_A_MODES = @('run', 'ask')

# 清理 AI 返回内容：去掉 markdown 代码围栏行与空行
function _a_clean([string]$s) {
    (@($s -split "`r?`n" | Where-Object { $_ -notmatch '^\s*```' -and $_.Trim() -ne '' }) -join "`n")
}

# run 模式的输出解析: 去围栏 + 左端去空白（保证 ASK: 前缀检测稳定）；解析后为空则报错
function _a_run_parse([string]$Raw) {
    $c = (_a_clean $Raw).TrimStart()
    if (-not $c) { _a_err 'AI 返回内容为空'; return $null }
    return $c
}

# ---------- 产品层: 帮助 ----------

function _a_help {
    Write-Output @'
a —— 自然语言转 PowerShell 命令（agent-cli-bash · Windows 版）

用法:
  a <自然语言>       让 AI 生成命令，确认后在当前会话执行
  a -p <自然语言>    只打印命令，不执行
  a -y <自然语言>    生成后直接执行，不询问（谨慎使用）
  a ask <问题>       自由问答：直接回答，不生成/执行命令（支持管道输入）
  a -c               清空本会话的多轮对话上下文
  a --show           查看当前会话的上下文构成（轮次/体积/裁剪情况）
  a -h | --help      显示帮助
  a --version        显示版本
  a providers        列出内置模型提供商
  a setup            交互式配置提供商与密钥（写入 config，立即生效）

确认时: y=执行  n=不执行(码130)  i=忽略(码0)  直接回车等同 n
执行结果码写入 $A_LAST_RC（PowerShell 函数没有独立退出码）。

多步执行:
  AI 返回多行命令时按完整 PowerShell 结构切成步骤(跨行的 foreach/if/函数体、
  here-string、反引号续行等作为一步整体)，逐步确认，每一步都由你决策:
  y=执行此步并继续  n=终止剩余步骤  i=跳过此步继续后面的步骤
  高危/高权限命令(红色显示)必须逐条确认，即使 -y 也不会自动执行；
  写操作(黄色显示)有 ⚡ 提示。无终端环境下高危命令一律拒绝。
  AI 生成过程以流式实时显示(灰色暗淡)，正式命令以高亮颜色展示。

步骤超时:
  每步命令受 A_STEP_TIMEOUT 看护(默认 600 秒，0=禁用)，防止挂住不退出；
  超时终止该步，结果码 124，超时情况会记入对话上下文供 AI 下一轮参考。
  受看护的普通步骤在子进程 pwsh -NoProfile 中执行，会话内临时定义的
  函数/别名对其不可见；cd/$env: 等会话状态命令在当前会话执行、不设超时。

多轮对话:
  同一 PowerShell 会话内，之前的问答、生成的命令及其执行结果（退出码+输出尾部）、
  当前目录与 git 状态、目录条目、最近的会话历史命令，会自动作为上下文发给 AI。
  支持追问，例如:
      a 列出当前目录的图片
      a 只要 png，并且按修改时间排序
      a 刚才那条报错了，帮我修复
  a -c 可随时清空上下文重新开始。
  命令与 a ask 问答的上下文分模式隔离，互不混入（a -c 一并清空）。

会话状态:
  cd 与 $env: 赋值在当前会话直接生效；普通 $x= 赋值发生在函数作用域内，
  需要驻留的变量请让 AI 用 $env: 或 $global:。

上下文理解:
  目录条目与请求相关者优先入选（如"算 linuxiso 的 sha256"会优先列出 linuxmint-*.iso），
  其余按修改时间补足；AI 被要求不得编造文件名，所指文件不明确时会把问题以 ❓ 反问，
  按提示输入补充信息即可同轮继续生成命令，直接回车取消。

配置（环境变量或 ~\.config\agent-cli-bash\config，与 bash 版同格式）:
  A_PROVIDER         提供商: deepseek(默认) openai kimi qwen zhipu grok ollama openrouter
  A_API_KEY          API 密钥；未设时自动读取提供商对应变量（如 OPENAI_API_KEY）
  A_BASE_URL         覆盖 API 地址；A_PROVIDER=custom 时必填
  A_MODEL            覆盖模型名
  A_MAX_RETRIES      网络错误/429/5xx 自动重试次数，默认 3（0=禁用），指数退避
  A_MAX_CONTEXT_CHARS 会话上下文字符预算，默认 24000（约 12K token），超出裁掉最旧的轮次
  A_TIMEOUT          单次 API 请求超时秒数，默认 60
  A_STEP_TIMEOUT     单步命令执行超时秒数，默认 600（0=禁用）；超时终止该步，结果码 124
  A_DIR_ENTRIES      目录条目注入上限，默认 15（0=不注入）；超出时相关的优先、其余按修改时间

示例:
  a 找出当前目录下最大的 5 个文件
  a 把所有 .png 图片压缩到 50% 质量
  a -p 查看本机公网 IP
  Get-Content error.log | a 解释这个报错    # 管道内容作为上下文发送（限 8KB）
  git diff | a 帮我写一条提交信息
'@
}

# ---------- 主函数: 参数解析与模式路由 ----------
# 不用 param() 绑定，$args 手工解析 —— 与 bash getopts 行为逐项对齐
# （支持 -py 合并短选项、--help 长选项、未知选项报错），管道输入走 $input。
function a {
    $printOnly = 0; $autoYes = 0
    $words = New-Object System.Collections.Generic.List[string]
    foreach ($t in $args) {
        $tok = "$t"
        if ($tok -eq '--') { continue }
        if ($tok.StartsWith('--')) {
            switch ($tok) {
                '--help'     { _a_help; return }
                '--version'  { Write-Output "agent-cli-bash $($global:A_VERSION)"; return }
                '--providers' { _a_list_providers; return }
                '--setup'    { _a_setup; return }
                '--show'     { _a_show $global:_A_MODES; return }
                '--clear'    { foreach ($m in $global:_A_MODES) { _a_conv_clear $m }
                               Write-Host '已清空本会话的对话上下文'; return }
                default      { _a_err "未知选项 $tok（try: a -h）"; $global:A_LAST_RC = 2; return }
            }
        } elseif ($tok.StartsWith('-') -and $tok.Length -gt 1) {
            foreach ($ch in $tok.Substring(1).ToCharArray()) {
                switch ($ch) {
                    'p' { $printOnly = 1 }
                    'y' { $autoYes = 1 }
                    'c' { foreach ($m in $global:_A_MODES) { _a_conv_clear $m }
                          Write-Host '已清空本会话的对话上下文'; return }
                    'h' { _a_help; return }
                    default { _a_err "未知选项 -$ch（try: a -h）"; $global:A_LAST_RC = 2; return }
                }
            }
        } else {
            $words.Add($tok)
        }
    }

    # 子命令形式: a providers / a setup
    if ($words.Count -gt 0) {
        if ($words[0] -eq 'providers') { _a_list_providers; return }
        if ($words[0] -eq 'setup') { _a_setup; return }
    }

    # 管道输入: Get-Content error.log | a 解释这个报错（或进程级 stdin 重定向）。
    # PS 对象管道经 $input 传入；stdin 被重定向时读全部内容，均限 8KB。
    $stdin_data = ''
    $piped = @($input | Where-Object { $null -ne $_ -and "$_" -ne '' })
    if ($piped.Count -gt 0) {
        $stdin_data = ($piped -join "`n")
    } elseif ([Console]::IsInputRedirected) {
        try { $stdin_data = [Console]::In.ReadToEnd() } catch { $stdin_data = '' }
    }
    if ($stdin_data.Length -gt 8192) { $stdin_data = $stdin_data.Substring(0, 8192) }

    $query = ($words -join ' ')
    if ($words.Count -eq 0 -and $stdin_data -eq '') {
        _a_help
        $global:A_LAST_RC = 2
        return
    }

    # 子命令: a ask <问题> —— 自由问答（不生成命令、不执行、输出原样打印）
    if ($words.Count -gt 0 -and $words[0] -eq 'ask') {
        $query = (($words | Select-Object -Skip 1) -join ' ')
        if (-not $query) { $query = '分析以上管道输入，回答其中的问题' }
        _a_mode_ask $query $stdin_data
        return
    }

    if (-not $query) { $query = '分析以上管道输入，给出下一步需要执行的 PowerShell 命令' }
    _a_run $query $stdin_data $printOnly $autoYes
}

# ---------- run 模式: 自然语言 -> 命令，确认后执行 ----------

function _a_run([string]$Query, [string]$StdinData, [int]$PrintOnly, [int]$AutoYes) {
    if (-not (_a_resolve_provider)) { $global:A_LAST_RC = 1; return }

    if (_a_conv_get 'run') {
        Write-Host '💬 接续本会话对话（a -c 可清空）'
    }

    $osDesc = ''
    try { $osDesc = [Environment]::OSVersion.VersionString } catch { $osDesc = 'unknown' }
    $sys_prompt = "You convert natural language into PowerShell command(s). Rules: reply with the command(s) ONLY - no explanation, no markdown fences, no leading `$ or PS>. If the task needs multiple sequential steps, output multiple lines (one command per line) or chain with `; / && (pwsh 7+). You may receive prior conversation: earlier requests, the commands you proposed, and their execution results (exit code and output). Use them to interpret follow-up requests like 'only the first 10' or 'fix that error'. The current working directory (with a git state summary and a directory listing) and a snippet of recent session history may also be provided as context. The directory listing may be partial (its header shows the total entry count): NEVER invent file or directory names - use only exact names that appear in the context, and interpret loose user wording against the listed names (e.g. 'linuxiso' matches a listed linuxmint-*.iso). If the file/directory the user refers to is still ambiguous or absent from the context, do NOT guess: reply with one short clarifying question, alone on a single line prefixed exactly with 'ASK: ' (example: ASK: 目录里有多个 iso 文件，要计算哪一个的 sha256？); after the user's supplementary answer, generate the command. Target shell: PowerShell $($PSVersionTable.PSVersion) on $osDesc. Prefer native PowerShell cmdlets over cmd/Unix commands unless the user asks otherwise."

    # 用户消息 = 管道输入(如有) + 最近会话历史(参考) + 本次请求
    $user_content = ''
    $hist = _a_recent_history
    if ($StdinData -ne '') {
        Write-Host ('📎 已读取管道输入 {0} 字节（超过 8KB 截断）' -f $StdinData.Length)
        $user_content = "管道输入(可能截断):`n$StdinData`n`n"
    }
    $env_ctx = _a_env_context $Query
    if ($env_ctx) { $user_content = $user_content + "当前环境:`n$env_ctx`n`n" }
    if ($hist) { $user_content = $user_content + "最近终端历史命令(仅作参考):`n$($hist -join "`n")`n`n" }
    $user_content = $user_content + "请求: $Query"

    $sysObj = [ordered]@{ role = 'system'; content = $sys_prompt }
    $userObj = [ordered]@{ role = 'user'; content = $user_content }

    $raw = _a_generate (_a_msgs_json 'run' $sysObj $userObj) `
        $global:_A_R_URL $global:_A_R_KEY $global:_A_R_TIMEOUT $global:_A_R_MODEL
    if (-not $raw) { $global:A_LAST_RC = 1; return }
    $cmd = _a_run_parse $raw
    if (-not $cmd) { $global:A_LAST_RC = 1; return }

    # AI 拿不准时反问（回复以 ASK: 开头——run 模式的 prompt 约定）: 展示问题并等用户
    # 补充，把「问题+补充」并入会话后重新生成，最多 3 轮；空回答或无终端则取消。
    $ask_rounds = 0
    while ($cmd.StartsWith('ASK:')) {
        if ($ask_rounds -ge 3) {
            _a_err 'AI 连续追问已达 3 轮上限，请补充更明确的信息后重试'
            $global:A_LAST_RC = 1
            return
        }
        $ask_content = $cmd.Substring(4).TrimStart()
        Write-Host "❓ $ask_content"
        $reply = _a_prompt_answer '补充信息(直接回车取消): '
        if ($null -eq $reply -or $reply -eq '') {
            _a_err '已取消（未补充信息）'
            $global:A_LAST_RC = 1
            return
        }
        _a_conv_append 'run' 'Q' (ConvertTo-Json -InputObject $userObj -Compress)
        _a_conv_append 'run' 'A' (ConvertTo-Json -InputObject ([ordered]@{ role = 'assistant'; content = $cmd }) -Compress)
        $userObj = [ordered]@{ role = 'user'; content = "补充: $reply" }
        $ask_rounds++
        $raw = _a_generate (_a_msgs_json 'run' $sysObj $userObj) `
            $global:_A_R_URL $global:_A_R_KEY $global:_A_R_TIMEOUT $global:_A_R_MODEL
        if (-not $raw) { $global:A_LAST_RC = 1; return }
        $cmd = _a_run_parse $raw
        if (-not $cmd) { $global:A_LAST_RC = 1; return }
    }

    # 记入本会话对话：本次请求（或 ASK 补充后的最终请求）+ AI 给出的命令（未执行也记录，便于下一轮追问）
    _a_conv_append 'run' 'Q' (ConvertTo-Json -InputObject $userObj -Compress)
    _a_conv_append 'run' 'A' (ConvertTo-Json -InputObject ([ordered]@{ role = 'assistant'; content = $cmd }) -Compress)

    if ($PrintOnly -eq 1) {
        Write-Output $cmd
        $global:A_LAST_RC = 0
        return
    }

    # 写入会话历史，方便 ↑/F8 找回
    try { Add-History -InputObject ([pscustomobject]@{ CommandLine = $cmd }) } catch { }

    # 多步按结构切分确认执行（风险提示、y/n/i、130 语义、R 消息回写、$A_LAST_RC 都在其中）
    _a_exec_steps 'run' $AutoYes $cmd
}

# ---------- ask 模式: 自由文本问答 ----------
# 复用 L1 传输（提供商/重试/流式）与 L2 上下文（独立 ask 会话）；不做命令清洗与执行。

function _a_mode_ask([string]$Query, [string]$StdinData) {
    if (-not (_a_resolve_provider)) { $global:A_LAST_RC = 1; return }

    if (_a_conv_get 'ask') {
        Write-Host '💬 接续本会话问答（a -c 可清空）'
    }

    $sys_prompt = "You are a helpful terminal assistant. Answer the user's question concisely and accurately, in the language the user writes. You may receive piped input, the current environment (working directory, git state, directory listing) and prior Q&A turns as context. This is a Q&A mode: give explanations/answers, and only show a shell command inside a fenced code block when it helps the answer."
    $user_content = ''
    if ($StdinData -ne '') {
        Write-Host ('📎 已读取管道输入 {0} 字节（超过 8KB 截断）' -f $StdinData.Length)
        $user_content = "管道输入(可能截断):`n$StdinData`n`n"
    }
    $env_ctx = _a_env_context $Query
    if ($env_ctx) { $user_content = $user_content + "当前环境:`n$env_ctx`n`n" }
    $user_content = $user_content + "问题: $Query"

    $sysObj = [ordered]@{ role = 'system'; content = $sys_prompt }
    $userObj = [ordered]@{ role = 'user'; content = $user_content }

    $raw = _a_generate (_a_msgs_json 'ask' $sysObj $userObj) `
        $global:_A_R_URL $global:_A_R_KEY $global:_A_R_TIMEOUT $global:_A_R_MODEL 1024 0
    if (-not $raw) { $global:A_LAST_RC = 1; return }

    _a_conv_append 'ask' 'Q' (ConvertTo-Json -InputObject $userObj -Compress)
    _a_conv_append 'ask' 'A' (ConvertTo-Json -InputObject ([ordered]@{ role = 'assistant'; content = $raw }) -Compress)

    Write-Output $raw
    $global:A_LAST_RC = 0
}
