# a-exec.ps1 —— L3 执行域（harness，PowerShell 版）
# 命令风险评估、会话状态命令识别与带确认的多步执行。
# 依赖 L2（执行结果经 _a_conv_append 回写会话）；不依赖产品层的任何约定。
# 由 a.ps1 在加载时 dot-source，不单独使用。
#
# 与 bash 版的一个重要差异: PowerShell 管道不会派生子 shell，cd（Set-Location）、
# $env: 赋值在任何分支下执行都直接影响当前会话；「会话状态命令」分支仅决定
# 是否捕获输出（赋值/别名类语句的返回值没有捕获价值）。普通 $x= 赋值发生在
# 函数作用域内，函数返回后即失效——需要驻留的值应让 AI 用 $env: 或 $global:。

# 判断命令是否直接改变当前会话状态（cd/$env: 赋值/别名/变量定义等）。
function _a_shell_state([string]$c) {
    ($c -match '(^|[;&|(]\s*|\|\s*)(cd|set-location|chdir|sl|pushd|popd)\b') -or
    ($c -match '\$env:[a-z_][a-z0-9_]*\s*=') -or
    ($c -match '^\s*\$[a-zA-Z_][a-zA-Z0-9_]*\s*=') -or
    ($c -match '\b(set-alias|new-alias|set-variable|new-variable|remove-variable|export-modulemember)\b') -or
    ($c -match '\[environment\]::setenvironmentvariable')
}

# 命令风险评估: 输出 danger(高危: 提权/强制删除/系统级写) / caution(写操作) / ''(只读)
# 覆盖 PowerShell 原生命令与别名、cmd 风格命令，以及 git-bash/wsl 场景下的 Unix 命令。
function _a_risk([string]$c) {
    $danger =
        ($c -match '(^|[^a-zA-Z0-9_.-])(sudo|doas|pkexec|runas)([^a-zA-Z0-9_-]|$)') -or
        ($c -match '(^|[^a-zA-Z0-9_.-])su([^a-zA-Z0-9_-]|$)') -or
        ($c -match '(^|[^a-zA-Z0-9_.-])rm +-?[a-zA-Z]*[rRf]') -or
        ($c -match '\b(remove-item|ri|rd|del|erase)\b[^|;&]*\s(-recurse|-force|-r\b|-f\b|-fo\b)') -or
        ($c -match '(^|[^a-zA-Z0-9_.-])(mkfs|fdisk|shred)\b') -or
        ($c -match '\bdd\s+if=') -or
        ($c -match '(^|[^a-zA-Z0-9_.-])(format-volume|clear-disk|remove-partition|initialize-disk|restore-volume|diskpart|bcdedit|takeown|icacls|cacls)\b') -or
        ($c -match '(^|\s)format\s+[a-z]:') -or
        ($c -match '\bcipher\s+/w') -or
        ($c -match '(^|[^a-zA-Z0-9_.-])(stop-computer|restart-computer|shutdown)\b') -or
        ($c -match '(^|[^a-zA-Z0-9_.-])kill +(-9|-[sSIG]*KILL)') -or
        ($c -match '\bstop-process\b[^|]*-force') -or
        ($c -match '\btaskkill\b[^|]*\s/f') -or
        ($c -match 'git +(push +(-f|--force)|reset +--hard|clean|checkout +--|restore)') -or
        ($c -match '(^|[^a-zA-Z0-9_.-])(chmod|chown) +-[a-zA-Z]*R') -or
        ($c -match '\breg +(add|delete|import|restore)\b') -or
        ($c -match 'net +(user|localgroup) +[^|]*(/delete|/add)') -or
        ($c -match '\b(curl|wget|invoke-webrequest|iwr)\b[^|]*\| *(iex|invoke-expression|(ba|z)?sh|pwsh|powershell)')
    if ($danger) { return 'danger' }
    $caution =
        ($c -match '(^|[^a-zA-Z0-9_.-])(rm|del|erase|rd|ri|remove-item|remove-itemproperty|move-item|mi|mv|move|copy-item|cpi|cp|copy|set-content|out-file|add-content|new-item|ni|tee|tee-object|clear-content|truncate|rename-item|rni|ren|set-itemproperty|stop-process|kill|killall|pkill|reg)([^a-zA-Z0-9_-]|$)') -or
        ($c -match 'git +(push|commit|stash)') -or
        ($c -match '(^|[^a-zA-Z0-9_.-])(winget|choco|scoop|npm|pip3?|gem|dotnet|cargo)\s+(install|uninstall|remove|add|update|upgrade)') -or
        ($c -match '\b(install-module|uninstall-module|set-executionpolicy)\b') -or
        ($c -match '(^|[^a-zA-Z0-9_.-])(start-service|stop-service|restart-service|set-service|suspend-service)\b') -or
        ($c -match 'net +(start|stop)\b') -or
        ($c -match '\bsc(\.exe)?\s+(start|stop|config|delete)\b') -or
        ($c -match 'sed +-[a-zA-Z]*i') -or
        ($c -match '(^|[^>2])>([^>&]|$)')
    if ($caution) { return 'caution' }
    return ''
}

# 终端上提示并读入一行回答（ASK 追问等交互复用）。
# 返回回答文本；stdin 被重定向（管道/脚本场景）或非交互宿主时打印提示并返回 $null。
# （Read-Host 在 stdin 重定向时会去读重定向流而非控制台，须先门控，对应 bash 版的 /dev/tty 检测）
function _a_prompt_answer([string]$Prompt) {
    if ([Console]::IsInputRedirected) {
        Write-Host $Prompt
        Write-Host '(无终端可交互，无法补充信息)'
        return $null
    }
    try {
        return (Read-Host -Prompt $Prompt)
    } catch {
        Write-Host ''
        Write-Host '(无终端可交互，无法补充信息)'
        return $null
    }
}

# 多步确认执行: 把 <cmd> 按行拆成步骤，逐步显示风险并询问 y/n/i；
# 高危命令即使 -y 也强制确认，无终端一律拒绝；会话状态命令直行不捕获。
# 执行结果摘要（R 消息）回写到 <mode> 的会话；最后退出码写入 $global:A_LAST_RC，
# 用户终止时为 130。（PowerShell 函数没有独立退出码，a 的调用方以 $global:A_LAST_RC 取值）
function _a_exec_steps([string]$Mode, [int]$AutoYes, [string]$Cmd) {
    $steps = @($Cmd -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    $total = $steps.Count
    $n = 0; $executed = 0; $skipped = 0; $stopped_at = 0; $rc = 0; $state_executed = 0
    $out_file = _a_mktemp
    Set-Content -LiteralPath $out_file -Value '' -NoNewline

    foreach ($step in $steps) {
        $n++
        if ($total -gt 1) {
            Write-Host ('步骤 {0}/{1}: ' -f $n, $total) -NoNewline -ForegroundColor White
        }
        $risk = _a_risk $step
        if ($risk -eq 'danger') {
            Write-Host $step -ForegroundColor Red
            Write-Host '⚠  高危/高权限操作（提权/强制删除/系统级写入），逐字核对命令与路径' -ForegroundColor Red
        } elseif ($risk -eq 'caution') {
            Write-Host $step -ForegroundColor Yellow
            Write-Host '⚡  写操作，会修改文件或状态' -ForegroundColor Yellow
        } else {
            Write-Host $step -ForegroundColor Cyan
        }

        # 高危命令必须用户逐条决策：即使 -y 也不跳过；无终端时直接拒绝
        if ($AutoYes -ne 1 -or $risk -eq 'danger') {
            if ($risk -eq 'danger') {
                Write-Host '确认执行高危命令? [y=执行 n=终止剩余 i=跳过此步] ' -NoNewline -ForegroundColor Red
            } elseif ($total -gt 1) {
                Write-Host '执行此步? [y=执行 n=终止剩余 i=跳过此步] ' -NoNewline
            } else {
                Write-Host '执行? [y=执行 n=不执行 i=忽略] ' -NoNewline
            }
            $reply = $null
            if ([Console]::IsInputRedirected) {
                Write-Host ''
                Write-Host '(无终端可交互，视为不执行；脚本中请使用 a -y / a -p)'
                $reply = ''
            } else {
                try { $reply = Read-Host } catch {
                    Write-Host ''
                    Write-Host '(无终端可交互，视为不执行；脚本中请使用 a -y / a -p)'
                    $reply = ''
                }
            }
            if ($reply -eq 'y' -or $reply -eq 'Y') {
                # 执行
            } elseif ($reply -eq 'i' -or $reply -eq 'I') {
                Write-Host '(已跳过)'
                $skipped++
                continue
            } else {
                Write-Host '已终止，剩余步骤不再执行'
                $stopped_at = $n
                break
            }
        }

        $executed++
        $global:LASTEXITCODE = 0
        if (_a_shell_state $step) {
            # 会话状态命令直接执行、输出实时显示但不捕获（cd/$env: 在当前会话生效）
            try { Invoke-Expression $step 2>&1 | Out-Host } catch { Write-Host "$_" -ForegroundColor Red }
            $rc = _a_step_rc
            $state_executed++
        } else {
            try {
                Invoke-Expression $step 2>&1 | ForEach-Object {
                    "$_"
                    [System.IO.File]::AppendAllText($out_file, "$_`n", $global:_A_UTF8)
                }
            } catch { Write-Host "$_" -ForegroundColor Red }
            $rc = _a_step_rc
        }
    }

    $out_tail = ''
    if (Test-Path -LiteralPath $out_file) {
        $tl = @([System.IO.File]::ReadAllLines($out_file, $global:_A_UTF8) | Select-Object -Last 40)
        $out_tail = ($tl -join "`n")
        if ($out_tail.Length -gt 4000) { $out_tail = $out_tail.Substring(0, 4000) }
    }
    Remove-Item -LiteralPath $out_file -Force -ErrorAction SilentlyContinue

    # 一步未执行且是用户终止 → 130；执行过任何步骤 → 最后一步的退出码
    if ($executed -eq 0 -and $stopped_at -gt 0) { $rc = 130 }

    $summary = ''
    if ($total -gt 1) {
        $summary = "多步执行: 共 $total 步，执行 $executed 步，跳过 $skipped 步"
        if ($stopped_at -gt 0) { $summary += "，在第 $stopped_at 步被用户终止" }
        $summary += "。最后退出码 $rc"
    } elseif ($stopped_at -gt 0) {
        $summary = '用户选择不执行该命令'
    } else {
        $summary = "上一条命令执行结果: 退出码 $rc"
    }
    if ($state_executed -gt 0) {
        $summary += "（其中 $state_executed 步为会话状态命令 cd/`$env: 等，已在当前会话生效，输出未捕获）"
    }
    $rMsg = ConvertTo-Json -InputObject ([ordered]@{ role = 'user'; content = "$summary`n输出(可能截断):`n$out_tail" }) -Compress
    _a_conv_append $Mode 'R' $rMsg
    $global:A_LAST_RC = $rc
}

# 取刚执行步骤的退出码: 原生命令看 $LASTEXITCODE，PowerShell 语句看 $?
function _a_step_rc {
    if ($global:LASTEXITCODE -ne 0) { return $global:LASTEXITCODE }
    if ($?) { return 0 } else { return 1 }
}
