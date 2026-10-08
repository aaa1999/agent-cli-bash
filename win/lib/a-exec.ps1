# a-exec.ps1 —— L3 执行域（harness，PowerShell 版）
# 命令结构切分、风险评估、会话状态命令识别与带确认的多步执行。
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

# 把多行命令切成"完整 PowerShell 结构"的步骤，跨行结构不被拆坏:
#   - 块结构: if/foreach/while/switch/try/函数体的 { }、分组 ( )、哈希表 @{ }
#   - here-string: @" ... "@ / @' ... '@（终止符位于行首）
#   - 续行: 行尾反引号、未闭合引号、块注释 <# ... #>、行尾 | / && / ||
# 引号感知（'' 与 "" 自转义、双引号内反引号转义）；未闭合输入并入最后一步，
# 交给 Invoke-Expression 如实报错。返回各步骤（原文）的数组。
function _a_split_steps([string]$Cmd) {
    $out = New-Object System.Collections.Generic.List[string]
    $depth = 0                       # 未闭合的 { 与 ( 计数
    $q = [char]0                     # 未闭合引号（' 或 "）
    $here = ''                       # here-string 终止符（"@ 或 '@），空 = 不在体内
    $bcmt = $false                   # 块注释 <# ... #> 内
    $buf = ''
    foreach ($line in ($Cmd -split "`r?`n")) {
        $startAt = 0
        $scan = $false
        if ($here -ne '') {
            if ($line.StartsWith($here)) { $here = ''; $startAt = 2; $scan = $true }   # 终止行，其后内容恢复扫描
        } elseif ($bcmt) {
            $end = $line.IndexOf('#>')
            if ($end -ge 0) { $bcmt = $false; $startAt = $end + 2; $scan = $true }
        } else {
            $scan = $true
        }

        if (-not $scan) {
            # here-string 体 / 块注释中间行: 原样并入
            if ($buf -eq '') { $buf = $line } else { $buf = "$buf`n$line" }
            continue
        }

        # 步骤间隙的空行/纯注释行丢弃（结构内部的空行不算间隙）
        $t = $line.TrimStart()
        if ($buf -eq '' -and $depth -eq 0 -and $here -eq '' -and -not $bcmt -and ($t -eq '' -or $t.StartsWith('#'))) { continue }

        $n = $line.Length
        $lastc = [char]0; $last2 = ''
        $tbt = $false
        for ($i = $startAt; $i -lt $n; $i++) {
            $c = $line[$i]
            if ($q -ne [char]0) {                       # 引号内: 找闭合（'' / "" 自转义；" 内 ` 转义）
                if ($q -eq [char]34 -and $c -eq [char]96) { $i++; continue }
                if ($c -eq $q -and $i + 1 -lt $n -and $line[$i + 1] -eq $q) { $i++; continue }
                if ($c -eq $q) { $q = [char]0; $last2 = "$lastc$c"; $lastc = $c }
                continue
            }
            if ($c -eq [char]96) {                      # 反引号转义下一字符；行尾即续行
                if ($i -eq $n - 1) { $tbt = $true; break }
                $i++
                continue
            }
            if ($c -eq [char]39 -or $c -eq [char]34) { $q = $c; $last2 = "$lastc$c"; $lastc = $c; continue }
            if ($c -eq '@' -and $i + 1 -lt $n -and ($line[$i + 1] -eq [char]39 -or $line[$i + 1] -eq [char]34)) {
                $here = if ($line[$i + 1] -eq [char]39) { "'@" } else { '"@' }
                $i++
                continue
            }
            if ($c -eq '<' -and $i + 1 -lt $n -and $line[$i + 1] -eq '#') {    # 块注释
                if ($line.IndexOf('#>', $i + 2) -lt 0) { $bcmt = $true }
                break
            }
            if ($c -eq '#' -and ($i -eq 0 -or [char]::IsWhiteSpace($line[$i - 1]))) { break }
            if ($c -eq ' ' -or $c -eq "`t") { continue }
            $last2 = "$lastc$c"; $lastc = $c
            if ($c -eq '{' -or $c -eq '(') { $depth++ }
            elseif ($c -eq '}' -or $c -eq ')') { if ($depth -gt 0) { $depth-- } }
        }
        if ($buf -eq '') { $buf = $line } else { $buf = "$buf`n$line" }
        $incomplete = ($depth -gt 0) -or ($q -ne [char]0) -or ($here -ne '') -or $bcmt -or $tbt `
            -or ($lastc -eq '|') -or ($last2 -eq '&&') -or ($last2 -eq '||')
        if (-not $incomplete) {
            if ($buf.Trim() -ne '') { $out.Add($buf) }
            $buf = ''
        }
    }
    if ($buf.Trim() -ne '') { $out.Add($buf) }
    return $out
}

# 单步执行（超时看护）。Secs 为 0 时在当前会话 Invoke-Expression 执行（原路径，
# 输出实时显示并捕获）；大于 0 时在子进程 pwsh -NoProfile 中执行——PowerShell
# 语句无法在进程内安全中断，超时看护只能以独立进程为界，Stop-Process 即终止。
#   - 步骤文本经环境变量传入子进程、以 -EncodedCommand 启动引导脚本，无引号转义问题
#   - 子进程退出码即步骤退出码（原生命令的 $LASTEXITCODE 由引导脚本 exit 透传）
#   - 超过 Secs 未结束: Kill 整棵进程树（pwsh 7+，5.1 退化为单进程），返回 124
#     （对齐 bash 版与 GNU timeout 习惯），提示由调用方打印
#   - 输出行级流式回显（stdout 逐行、stderr 汇总在结束时），并捕获到 OutFile
# 显示一律走 [Console]::Out/Error: 不进 PowerShell 管道，函数返回值只含退出码，
# 调用方以 $rc = _a_step_run ... 赋值时也不会把显示内容吞进变量。
function _a_step_run([int]$Secs, [string]$Step, [string]$OutFile) {
    if ($Secs -le 0) {
        $global:LASTEXITCODE = 0
        try {
            Invoke-Expression $Step 2>&1 | ForEach-Object {
                [Console]::Out.WriteLine("$_")
                [System.IO.File]::AppendAllText($OutFile, "$_`n", $global:_A_UTF8)
            }
        } catch { Write-Host "$_" -ForegroundColor Red }
        return (_a_step_rc)
    }
    # 子进程宿主: 优先取当前 pwsh 的可执行文件，取不到时按 $PSHOME 推断
    $exe = $null
    try { $exe = (Get-Process -Id $PID).Path } catch { }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        foreach ($cand in @((Join-Path $PSHOME 'pwsh'), (Join-Path $PSHOME 'powershell'))) {
            if (Test-Path -LiteralPath $cand) { $exe = $cand; break }
        }
    }
    if (-not $exe) { Write-Host 'a: 无法定位子进程宿主，跳过超时看护' -ForegroundColor Red; return (_a_step_run 0 $Step $OutFile) }

    $bootstrap = @'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
Invoke-Expression $env:A_STEP_SCRIPT
if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit $(if ($?) { 0 } else { 1 })
'@
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bootstrap))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.EnvironmentVariables['A_STEP_SCRIPT'] = $Step
    $p = [System.Diagnostics.Process]::Start($psi)
    $tErr = $p.StandardError.ReadToEndAsync()
    $tOut = $p.StandardOutput.ReadLineAsync()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timed = $false
    $emit = {
        param($l)
        [Console]::Out.WriteLine($l)
        [System.IO.File]::AppendAllText($OutFile, "$l`n", $global:_A_UTF8)
    }
    try {
        while ($true) {
            if ($tOut.IsCompleted -or $tOut.Wait(150)) {
                $line = $tOut.Result
                if ($null -eq $line) { break }
                & $emit $line
                $tOut = $p.StandardOutput.ReadLineAsync()
                continue
            }
            if ($p.HasExited) {
                while ($tOut.IsCompleted -or $tOut.Wait(150)) {   # 排空缓冲中的剩余输出
                    $line = $tOut.Result
                    if ($null -eq $line) { break }
                    & $emit $line
                    $tOut = $p.StandardOutput.ReadLineAsync()
                }
                break
            }
            if ($sw.ElapsedMilliseconds -ge $Secs * 1000) { $timed = $true; break }
        }
    } finally {
        if (-not $p.HasExited) {
            try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
        }
        try { $p.WaitForExit() } catch { }
    }
    $errText = ''
    try { $errText = "$($tErr.Result)".TrimEnd("`r", "`n") } catch { }
    if ($errText -ne '') {
        [Console]::Error.WriteLine($errText)
        [System.IO.File]::AppendAllText($OutFile, "$errText`n", $global:_A_UTF8)
    }
    if ($timed) { return 124 }
    return $p.ExitCode
}

# 多步确认执行: 把 <cmd> 按完整 PowerShell 结构切成步骤（_a_split_steps，跨行的
# foreach/here-string 等作为一步），逐步显示风险并询问 y/n/i；
# 高危命令即使 -y 也强制确认，无终端一律拒绝；会话状态命令在当前会话直行不捕获
# （这类命令瞬时完成，不设超时）；其余步骤受 A_STEP_TIMEOUT（默认 600s，0=禁用）
# 看护——在子进程 pwsh 中执行，超时终止后返回 124。
# 执行结果摘要（R 消息）回写到 <mode> 的会话；最后退出码写入 $global:A_LAST_RC，
# 用户终止时为 130。（PowerShell 函数没有独立退出码，a 的调用方以 $global:A_LAST_RC 取值）
function _a_exec_steps([string]$Mode, [int]$AutoYes, [string]$Cmd) {
    $steps = @(_a_split_steps $Cmd)
    $total = $steps.Count
    $n = 0; $executed = 0; $skipped = 0; $stopped_at = 0; $rc = 0; $state_executed = 0; $timed_steps = 0
    $stepSecs = 600
    if ($env:A_STEP_TIMEOUT -match '^\d+$') { $stepSecs = [int]$env:A_STEP_TIMEOUT }
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
        if (_a_shell_state $step) {
            # 会话状态命令直接在当前会话执行、输出实时显示但不捕获（cd/$env: 生效）；
            # 瞬时完成，不设超时
            try { Invoke-Expression $step 2>&1 | Out-Host } catch { Write-Host "$_" -ForegroundColor Red }
            $rc = _a_step_rc
            $state_executed++
        } else {
            $rc = _a_step_run $stepSecs $step $out_file
            if ($rc -eq 124) {
                $timed_steps++
                Write-Host "⏱  步骤超过 $stepSecs 秒未完成，已终止（A_STEP_TIMEOUT 可调大或设 0 禁用）"
            }
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
    if ($timed_steps -gt 0) {
        $summary += "（$timed_steps 步超过 $stepSecs 秒被超时终止——命令可能未完成；如需更久可让用户调大 A_STEP_TIMEOUT 或设 0 禁用后改用后台运行）"
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
