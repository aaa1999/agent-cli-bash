# a-ctx.ps1 —— L2 上下文域（harness，PowerShell 版）
# 会话存储与裁剪（$global:_A_CONV，每行一条: 类型<TAB>JSON）、消息数组组装、
# 环境采集（目录智能选取/git/终端历史）。
# 本层知道「有多个模式」，但不知道各模式的语义；模式键由产品层传入。
# 由 a.ps1 在加载时 dot-source，不单独使用。

# ---------- 会话存储（按模式分键） ----------

# 会话总仓: 模式 -> 多行文本（每行 "类型`tJSON"）。驻留在全局作用域，
# dot-source 后随 PowerShell 会话存活，a -c 清空。
$global:_A_CONV = @{}

# 模式键 -> 会话键（模式中的非法字符映射为 _）。每个模式一条独立会话。
function _a_conv_name([string]$m) {
    if (-not $m) { $m = 'run' }
    ($m -creplace '[^a-zA-Z0-9_]', '_')
}

function _a_conv_get([string]$Mode) {
    $k = _a_conv_name $Mode
    if ($global:_A_CONV.ContainsKey($k)) { return $global:_A_CONV[$k] }
    return ''
}

function _a_conv_set([string]$Mode, [string]$Value) {
    $global:_A_CONV[(_a_conv_name $Mode)] = $Value
}

function _a_conv_clear([string]$Mode) {
    $global:_A_CONV.Remove((_a_conv_name $Mode))
}

# 追加一条消息到指定模式的会话（每行一条，格式: 类型<TAB>JSON）。
# 类型: Q=用户请求 A=AI命令 R=执行结果，三者构成一轮，供裁剪时保持轮次完整。
function _a_conv_append([string]$Mode, [string]$Type, [string]$MsgJson) {
    $conv = _a_conv_get $Mode
    if ($conv) { $conv = $conv + "`n" + $Type + "`t" + $MsgJson }
    else { $conv = $Type + "`t" + $MsgJson }
    # 上限 40 条消息（约 13 轮），超出丢最早的
    $lines = @($conv -split "`n")
    if ($lines.Count -gt 40) {
        $conv = ($lines | Select-Object -Last 40) -join "`n"
    }
    _a_conv_set $Mode $conv
}

# 按字符预算从新到旧保留完整的轮(Q 行开新轮)，孤立的 A/R 头部一并丢弃；
# 至少保留最新一轮。预算由 A_MAX_CONTEXT_CHARS 控制（默认 24000 字符，约 12K token；
# bash 版按字节计，此处按字符计，中文预算更宽松，语义一致）。
function _a_conv_trim([string]$Conv) {
    $budget = 24000
    if ($env:A_MAX_CONTEXT_CHARS) { $budget = [int]$env:A_MAX_CONTEXT_CHARS }
    if (-not $Conv) { return @() }
    $lines = @($Conv -split "`n")
    $n = $lines.Count
    $types = @(); $lens = @()
    for ($i = 0; $i -lt $n; $i++) {
        $types += $lines[$i].Substring(0, 1)
        $lens += $lines[$i].Length + 1
    }
    # $start = $n 是「尚未保留任何轮」的哨兵（对应 awk 版的 n+1）；
    # 超预算但一轮都没保住时不 break，保证至少保留最新一轮；没有 Q 行则返回空
    $total = 0; $start = $n
    for ($i = $n - 1; $i -ge 0; $i--) {
        if ($types[$i] -ne 'Q') { continue }
        $rl = 0
        for ($j = $i; $j -lt $start; $j++) { $rl += $lens[$j] }
        if ($total + $rl -gt $budget -and $start -lt $n) { break }
        $total += $rl; $start = $i
    }
    if ($start -ge $n) { return @() }
    return @($lines[$start..($n - 1)])
}

# 查看会话的上下文构成（每个有内容的模式一段）
function _a_show([string[]]$Modes) {
    $any = $false
    foreach ($m in $Modes) { if (_a_conv_get $m) { $any = $true } }
    if (-not $any) {
        Write-Output '（当前会话暂无对话上下文）'
        return
    }
    $budget = 24000
    if ($env:A_MAX_CONTEXT_CHARS) { $budget = [int]$env:A_MAX_CONTEXT_CHARS }
    foreach ($m in $Modes) {
        $conv = _a_conv_get $m
        if (-not $conv) { continue }
        $allN = @($conv -split "`n").Count
        $total = $conv.Length
        $kept = _a_conv_trim $conv
        $keptN = $kept.Count
        $keptChars = ($kept -join "`n").Length
        Write-Output ('[{0}] 会话上下文: {1} 条消息 / {2} 字符，预算 {3}，下一轮将发送 {4} 条 / {5} 字符（a -c 清空）' -f `
            $m, $allN, $total, $budget, $keptN, $keptChars)
        $round = 0
        foreach ($line in $kept) {
            $idx = $line.IndexOf("`t")
            if ($idx -lt 1) { continue }
            $typ = $line.Substring(0, $idx)
            $c = _a_msg_content $line.Substring($idx + 1)
            $clines = @($c -split "`n")
            switch ($typ) {
                'Q' {
                    $round++
                    $tail = $clines[$clines.Count - 1]
                    # 对齐 bash 版 sed 's/^请求: //': 前缀「请求: 」共 4 个字符
                    if ($tail.StartsWith('请求: ')) { $tail = $tail.Substring(4) }
                    if ($tail.Length -gt 70) { $tail = $tail.Substring(0, 70) }
                    Write-Output ('  轮 {0}  {1}' -f $round, $tail)
                }
                'A' {
                    $head = $clines[0]
                    if ($head.Length -gt 70) { $head = $head.Substring(0, 70) }
                    if ($clines.Count -gt 1) { $head = $head + (' (+{0} 行)' -f ($clines.Count - 1)) }
                    Write-Output ('        命令: {0}' -f $head)
                }
                'R' {
                    $head = $clines[0]
                    if ($head.Length -gt 70) { $head = $head.Substring(0, 70) }
                    Write-Output ('        结果: {0}' -f $head)
                }
            }
        }
    }
}

# 最近的 shell 历史命令（排除 a 自身的调用）。
# a 不只出现在行首——`. a.ps1; a -p x` 这类组合行也整行排除，避免上一轮的
# 标记词经历史回流污染下一轮请求；普通英文句子里的单词 a 不受影响。
# PowerShell 的 Get-History 只覆盖当前会话（跨会话历史在 PSReadLine 文件里，不混入），无则返回空。
function _a_recent_history {
    $h = @()
    try { $h = @(Get-History -Count 6 -ErrorAction SilentlyContinue | ForEach-Object { $_.CommandLine }) } catch { }
    @($h | Where-Object { $_ -and ($_.Trim() -ne '') -and ($_ -notmatch '(^|[;&|]\s*|\|\s*)a\s') })
}

# 目录条目智能选取: 与 <query> 相关的优先——从 query 提取 ASCII 词元，词元完整出现在
# 文件名中得分最高，词元最长前缀（≥3 字符）命中次之，覆盖"linuxiso"→"linuxmint-….iso"
# 这类口语缩写；剩余名额按修改时间新→旧补足，近期下载/新建的文件也能进入上下文。
# _a_pick_dir_entries <query> <limit> <items: Get-ChildItem 结果>
function _a_pick_dir_entries([string]$Query, [int]$Limit, $Items) {
    $tokens = @([regex]::Matches($Query.ToLowerInvariant(), '[a-z0-9]+') |
        ForEach-Object { $_.Value } | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
    $matched = @()
    foreach ($it in $Items) {
        $e = $it.Name.ToLowerInvariant()
        $score = 0
        foreach ($t in $tokens) {
            if ($e.Contains($t)) { $score += $t.Length + 2; continue }
            for ($L = $t.Length - 1; $L -ge 3; $L--) {
                if ($e.Contains($t.Substring(0, $L))) { $score += $L; break }
            }
        }
        if ($score -gt 0) { $matched += [pscustomobject]@{ Score = $score; Name = $it.Name } }
    }
    $picked = @($matched | Sort-Object -Property @{Expression = 'Score'; Descending = $true }, Name |
        Select-Object -First $Limit -ExpandProperty Name)
    if ($picked.Count -lt $Limit) {
        $skip = @($picked | ForEach-Object { $_ })
        $rest = @($Items | Where-Object { $skip -notcontains $_.Name } |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First ($Limit - $picked.Count) -ExpandProperty Name)
        $picked = @($picked) + @($rest)
    }
    return @($picked | Where-Object { $_ })
}

# 当前环境摘要: 工作目录 + git 分支/变更数 + 目录条目。
# 条目数不超过 A_DIR_ENTRIES（默认 15）时全部列出；超过时智能选取（_a_pick_dir_entries）
# 并在表头注明总条目数——避免大目录里截断，导致 AI 看不到用户所指的文件而编造名字。
# 输出行与 bash 版逐字一致，便于同一套测试与 prompt 复用。
function _a_env_context([string]$Query) {
    $limit = 15
    if ($env:A_DIR_ENTRIES -match '^[0-9]+$') { $limit = [int]$env:A_DIR_ENTRIES }
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('当前目录: ' + (Get-Location).Path)
    if (Get-Command git -ErrorAction SilentlyContinue) {
        git rev-parse --is-inside-work-tree 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $branch = [string](git branch --show-current 2>$null)
            if (-not $branch) { $branch = [string](git rev-parse --short HEAD 2>$null) }
            $dirty = @((git status --porcelain 2>$null) | Where-Object { $_ }).Count
            $out.Add(('git: 分支 {0}（未提交变更 {1} 项）' -f $branch, $dirty))
        }
    }
    if ($limit -eq 0) { return ($out -join "`n") }
    $items = @(Get-ChildItem -Force -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) { return ($out -join "`n") }
    $total = $items.Count
    $names = @($items | ForEach-Object { $_.Name })
    if ($total -le $limit) {
        $out.Add('目录内容（共 ' + $total + ' 项）:')
        foreach ($n in $names) { $out.Add($n) }
    } else {
        $out.Add(('目录内容（共 {0} 项，仅列 {1} 项: 与请求可能相关的优先，其余按修改时间新→旧）:' -f $total, $limit))
        foreach ($n in (_a_pick_dir_entries $Query $limit $items)) { $out.Add($n) }
    }
    return ($out -join "`n")
}

# 组装请求消息数组: system + 指定模式的会话历史（如有，经裁剪）+ 本轮用户消息
function _a_msgs_json([string]$Mode, $SysObj, $UserObj) {
    $msgs = @($SysObj)
    $conv = _a_conv_get $Mode
    if ($conv) {
        foreach ($line in (_a_conv_trim $conv)) {
            $idx = $line.IndexOf("`t")
            if ($idx -lt 1) { continue }
            $msgs += (ConvertFrom-Json -InputObject $line.Substring($idx + 1))
        }
    }
    $msgs += $UserObj
    return , @($msgs)
}
