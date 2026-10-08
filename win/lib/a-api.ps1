# a-api.ps1 —— L1 传输域（harness 最底层，PowerShell 版）
# 提供商表、配置读写、JSON 组装与 SSE 流式请求客户端。
# 本层不知道会话与模式的存在: _a_generate 只接收消息数组、返回内容。
# 由 a.ps1 在加载时 dot-source，不单独使用。
# 兼容 Windows PowerShell 5.1 与 PowerShell 7+；JSON 解析用内置 ConvertFrom-Json，
# 因此不依赖 jq / python；HTTP 用系统自带的 curl.exe（Windows 10 1803+）。

# 内置提供商: 名称|默认 base URL|默认模型|API key 环境变量
# 只要是 OpenAI /chat/completions 兼容的网关都能用 A_BASE_URL + A_MODEL 接入
$global:_A_PROVIDERS = @(
    'deepseek|https://api.deepseek.com|deepseek-chat|DEEPSEEK_API_KEY'
    'openai|https://api.openai.com/v1|gpt-4o-mini|OPENAI_API_KEY'
    'kimi|https://api.moonshot.cn/v1|kimi-k2-0905-preview|MOONSHOT_API_KEY'
    'qwen|https://dashscope.aliyuncs.com/compatible-mode/v1|qwen-plus|DASHSCOPE_API_KEY'
    'zhipu|https://open.bigmodel.cn/api/paas/v4|glm-4-flash|ZHIPU_API_KEY'
    'grok|https://api.x.ai/v1|grok-3-mini|XAI_API_KEY'
    'ollama|http://localhost:11434/v1|qwen3:8b|OLLAMA_API_KEY'
    'openrouter|https://openrouter.ai/api/v1|openai/gpt-4o-mini|OPENROUTER_API_KEY'
)

# UTF-8 无 BOM 编码对象（写 payload/内容文件用；PS 5.1 的 Out-File 默认带 BOM）
$global:_A_UTF8 = New-Object System.Text.UTF8Encoding($false)

# 临时文件: 优先 New-TemporaryFile（5.1+），老版本退回 GetTempFileName
function _a_mktemp {
    if (Get-Command New-TemporaryFile -ErrorAction SilentlyContinue) {
        (New-TemporaryFile).FullName
    } else {
        [System.IO.Path]::GetTempFileName()
    }
}

# curl 可执行名: Windows 优先 curl.exe（PS 5.1 里裸 curl 是 Invoke-WebRequest 的别名），
# 非 Windows（pwsh on macOS/Linux）用 curl。找不到返回 $null。
function _a_curl_cmd {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' }
    elseif (Get-Command curl -ErrorAction SilentlyContinue) { 'curl' }
    else { $null }
}

# 取提供商表字段: _a_provider_field <name> <字段号 2=URL 3=模型 4=key变量>
function _a_provider_field([string]$Name, [int]$Field) {
    foreach ($p in $global:_A_PROVIDERS) {
        $f = $p -split '\|'
        if ($f[0] -eq $Name) { return $f[$Field - 1] }
    }
    return ''
}

function _a_list_providers {
    '{0,-11} {1,-50} {2,-22} {3}' -f 'PROVIDER', 'DEFAULT BASE URL', 'DEFAULT MODEL', 'KEY ENV'
    foreach ($p in $global:_A_PROVIDERS) {
        $f = $p -split '\|'
        '{0,-11} {1,-50} {2,-22} {3}' -f $f[0], $f[1], $f[2], $f[3]
    }
}

# 读取配置文件，仅填充尚未设置的环境变量。
# 与 bash 版同路径同格式（$HOME\.config\agent-cli-bash\config）；Windows 上不做 chmod ——
# 用户配置目录默认仅本用户可读，如需更强隔离可自行配 ACL。
function _a_load_config {
    $f = if ($env:A_CONFIG_FILE) { $env:A_CONFIG_FILE } else { Join-Path $HOME '.config/agent-cli-bash/config' }
    if (-not (Test-Path -LiteralPath $f)) { return }
    $known = 'A_PROVIDER', 'A_API_KEY', 'A_BASE_URL', 'A_MODEL', 'A_MAX_RETRIES', 'A_MAX_CONTEXT_CHARS',
             'A_TIMEOUT', 'A_STEP_TIMEOUT', 'A_DIR_ENTRIES', 'DEEPSEEK_API_KEY', 'DEEPSEEK_BASE_URL', 'DEEPSEEK_MODEL'
    foreach ($line in [System.IO.File]::ReadAllLines($f)) {
        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $key = $Matches[1]; $val = $Matches[2]
        if ($val.Length -ge 2 -and $val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        if ($known -contains $key -and -not [Environment]::GetEnvironmentVariable($key)) {
            [Environment]::SetEnvironmentVariable($key, $val)
        }
    }
}

# 密钥掩码: 保留前 4 后 4 字符，过短则全遮（用于界面回显，不泄露完整密钥）
function _a_mask_key([string]$k) {
    if ($k.Length -le 8) { '***' }
    else { $k.Substring(0, 4) + '***' + $k.Substring($k.Length - 4) }
}

# 将 key=value 合并进配置文件: 已有同名行原位替换，没有则追加，其余行保持不动。
# 先写临时文件再替换落盘，避免中途失败留下半截配置。
function _a_config_merge([string[]]$Pairs) {
    $f = if ($env:A_CONFIG_FILE) { $env:A_CONFIG_FILE } else { Join-Path $HOME '.config/agent-cli-bash/config' }
    $dir = Split-Path -Parent $f
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $upd = @{}
    foreach ($p in $Pairs) {
        $k = $p.Substring(0, $p.IndexOf('='))
        $upd[$k] = $p.Substring($k.Length + 1)
    }
    $out = New-Object System.Collections.Generic.List[string]
    $has = @{}
    if (Test-Path -LiteralPath $f) {
        foreach ($line in [System.IO.File]::ReadAllLines($f)) {
            if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=' -and $upd.ContainsKey($Matches[1])) {
                $out.Add($Matches[1] + '=' + $upd[$Matches[1]])
                $has[$Matches[1]] = $true
            } else {
                $out.Add($line)
            }
        }
    }
    foreach ($k in $upd.Keys) { if (-not $has.ContainsKey($k)) { $out.Add($k + '=' + $upd[$k]) } }
    $tmp = _a_mktemp
    [System.IO.File]::WriteAllLines($tmp, [string[]]$out, $global:_A_UTF8)
    Move-Item -LiteralPath $tmp -Destination $f -Force
}

# 交互式配置向导: 选提供商 -> 填密钥 -> 合并写入 config，当前会话立即生效。
# Read-Host 走宿主控制台，stdin 被重定向时也能读；密钥用 SecureString 不回显。
function _a_setup {
    if ([Console]::IsInputRedirected) {
        _a_err 'a setup 需在交互式终端运行'
        return
    }
    $f = if ($env:A_CONFIG_FILE) { $env:A_CONFIG_FILE } else { Join-Path $HOME '.config/agent-cli-bash/config' }
    _a_load_config
    $cur_provider = if ($env:A_PROVIDER) { $env:A_PROVIDER } else { 'deepseek' }
    $cur_key = if ($env:A_API_KEY) { $env:A_API_KEY } else { $env:DEEPSEEK_API_KEY }

    Write-Host 'a setup — 配置向导'
    if ($cur_key) {
        Write-Host ('当前: 提供商 {0}，密钥 {1}' -f $cur_provider, (_a_mask_key $cur_key))
    } else {
        Write-Host ('当前: 提供商 {0}，未配置密钥' -f $cur_provider)
    }
    _a_list_providers
    Write-Host '  custom = 其他 OpenAI 兼容网关（需填 base URL 与模型）'

    $names = @($global:_A_PROVIDERS | ForEach-Object { ($_ -split '\|')[0] })
    $reply = Read-Host ('选择提供商（名称或序号，回车保持 {0}）' -f $cur_provider)
    $reply = ($reply -replace '\s', '')
    if ($reply -eq '') {
        $name = $cur_provider
    } elseif ($reply -match '^[0-9]+$') {
        $i = [int]$reply
        if ($i -ge 1 -and $i -le $names.Count) { $name = $names[$i - 1] }
        else { _a_err "无效序号: $reply"; return }
    } elseif ($names -contains $reply -or $reply -eq 'custom') {
        $name = $reply
    } else {
        _a_err "未知提供商: $reply（a providers 查看）"
        return
    }

    $key = ''; $base = ''; $model = ''
    if ($name -eq 'custom') {
        $base = (Read-Host 'base URL（如 https://gw.example.com/v1）' -replace '\s', '')
        if (-not $base) { _a_err 'base URL 不能为空'; return }
        $model = (Read-Host '模型名' -replace '\s', '')
        if (-not $model) { _a_err '模型名不能为空'; return }
    }

    if ($name -eq 'ollama') {
        Write-Host 'ollama 本地服务无需密钥'
    } else {
        Write-Host '粘贴 API 密钥后回车（输入不回显，直接回车=保持不变）: ' -NoNewline
        $ss = Read-Host -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        Write-Host ''
        $key = ($key -replace '\s', '')
        if ($key.Length -ge 2 -and $key.StartsWith('"') -and $key.EndsWith('"')) {
            $key = $key.Substring(1, $key.Length - 2)
        }
        if ($key) { Write-Host ('已读取密钥: {0}' -f (_a_mask_key $key)) }
    }

    if ($name -eq 'custom') {
        $pairs = @("A_PROVIDER=$name", "A_BASE_URL=$base", "A_MODEL=$model")
        if ($key) { $pairs += "A_API_KEY=$key" }
        _a_config_merge $pairs
        $env:A_BASE_URL = $base
        $env:A_MODEL = $model
    } else {
        $pairs = @("A_PROVIDER=$name")
        if ($key) { $pairs += "A_API_KEY=$key" }
        _a_config_merge $pairs
    }
    $env:A_PROVIDER = $name
    if ($key) { $env:A_API_KEY = $key }
    Write-Host "✅ 已写入 $f，当前会话立即生效"
}

# JSON 字符串转义: 返回可直接嵌入 JSON 字符串位置的转义文本（不含首尾引号）。
# 组包尽量走 ConvertTo-Json；本函数供拼接场景与测试对齐 bash 版行为。
function _a_json_escape([string]$s) {
    $j = ConvertTo-Json -InputObject $s -Compress
    if ($j.Length -ge 2) { $j.Substring(1, $j.Length - 2) } else { '' }
}

# 从一条响应 JSON 文本中取 choices[0].message.content；失败返回 $null
function _a_json_content([string]$Json) {
    try {
        $d = ConvertFrom-Json -InputObject $Json
        if ($d.choices -and $d.choices[0].message -and $d.choices[0].message.content) {
            return "$($d.choices[0].message.content)"
        }
    } catch { }
    return $null
}

# 从一条 SSE data JSON 中取 choices[0].delta.content（流式增量）；无则返回 $null
function _a_json_delta([string]$Json) {
    try {
        $d = ConvertFrom-Json -InputObject $Json
        if ($d.choices -and $d.choices[0].delta -and $d.choices[0].delta.content) {
            return "$($d.choices[0].delta.content)"
        }
    } catch { }
    return $null
}

# 从一条错误响应 JSON 中取 error.message（用于友好报错）；失败返回 $null
function _a_json_error([string]$Json) {
    try {
        $d = ConvertFrom-Json -InputObject $Json
        if ($d.error -and $d.error.message) { return "$($d.error.message)" }
    } catch { }
    return $null
}

# 从单条消息 JSON 中取 content（--show 摘要用）
function _a_msg_content([string]$Json) {
    try {
        $d = ConvertFrom-Json -InputObject $Json
        if ($null -ne $d.content) { return "$($d.content)" }
    } catch { }
    return ''
}

function _a_err([string]$msg) {
    [Console]::Error.WriteLine("a: $msg")
}

# 提供商解析（含配置加载与依赖检查）: A_* 显式配置 > 提供商默认 > 旧 DEEPSEEK_*（仅 deepseek，向后兼容）。
# 成功设置 $global:_A_R_URL/_A_R_MODEL/_A_R_KEY/_A_R_TIMEOUT；失败向 stderr 报原因并返回 $false。
function _a_resolve_provider {
    _a_load_config
    $provider = if ($env:A_PROVIDER) { $env:A_PROVIDER } else { 'deepseek' }
    $pbase = _a_provider_field $provider 2
    $pmodel = _a_provider_field $provider 3
    $kenv = _a_provider_field $provider 4
    if ($provider -eq 'deepseek') {
        $global:_A_R_URL = if ($env:A_BASE_URL) { $env:A_BASE_URL } elseif ($env:DEEPSEEK_BASE_URL) { $env:DEEPSEEK_BASE_URL } else { $pbase }
        $global:_A_R_MODEL = if ($env:A_MODEL) { $env:A_MODEL } elseif ($env:DEEPSEEK_MODEL) { $env:DEEPSEEK_MODEL } else { $pmodel }
    } else {
        $global:_A_R_URL = if ($env:A_BASE_URL) { $env:A_BASE_URL } else { $pbase }
        $global:_A_R_MODEL = if ($env:A_MODEL) { $env:A_MODEL } else { $pmodel }
    }
    $global:_A_R_KEY = if ($env:A_API_KEY) { $env:A_API_KEY } else { '' }
    if (-not $global:_A_R_KEY -and $kenv) {
        # 读取提供商对应的环境变量（如 OPENAI_API_KEY / MOONSHOT_API_KEY）
        $global:_A_R_KEY = [Environment]::GetEnvironmentVariable($kenv)
    }
    if (-not $global:_A_R_KEY) { $global:_A_R_KEY = $env:DEEPSEEK_API_KEY }
    $global:_A_R_TIMEOUT = if ($env:A_TIMEOUT) { [int]$env:A_TIMEOUT } else { 60 }

    if (-not $global:_A_R_URL) {
        _a_err "未知提供商 '$provider'"
        [Console]::Error.WriteLine('  支持: deepseek openai kimi qwen zhipu grok ollama openrouter（a providers 查看）')
        [Console]::Error.WriteLine('  其他 OpenAI 兼容网关: 设 A_PROVIDER=custom 并配 A_BASE_URL + A_MODEL')
        return $false
    }

    # ollama 本地服务无需密钥，其余提供商必须配置
    if (-not $global:_A_R_KEY -and $provider -ne 'ollama') {
        _a_err '未配置 API 密钥'
        [Console]::Error.WriteLine('  1) 运行 a setup 交互式配置')
        [Console]::Error.WriteLine("  2) `$env:A_API_KEY = 'sk-xxx' 或 $kenv")
        [Console]::Error.WriteLine('  3) 或写入 ~\.config\agent-cli-bash\config（A_API_KEY=sk-xxx）')
        return $false
    }
    if (-not (_a_curl_cmd)) {
        _a_err '需要 curl（Windows 10 1803+ 自带 curl.exe，或安装 curl）'
        return $false
    }
    return $true
}

# 发送一轮对话请求，返回模型的原始回复文本；失败时报错并返回 $null。
# 输出解析（围栏清洗等）是产品层的职责，本函数不改动内容。
# _a_generate <messages数组> <base_url> <api_key> <timeout> <model> [max_tokens=512] [temperature=0]
function _a_generate {
    param($Messages, [string]$BaseUrl, [string]$ApiKey, [int]$Timeout, [string]$Model,
          [int]$MaxTokens = 512, [double]$Temperature = 0)

    # ConvertTo-Json 会把非 ASCII 转成 \uXXXX，payload 文件因此是纯 ASCII，无编码歧义
    $payloadObj = [ordered]@{
        model = $Model; messages = $Messages
        temperature = $Temperature; max_tokens = $MaxTokens; stream = $true
    }
    $payload = ConvertTo-Json -InputObject $payloadObj -Compress -Depth 8

    # 流式请求（SSE）: AI 生成的内容实时显示；增量与异常分别落盘，循环外汇总。
    # 网络错误与 HTTP 429/5xx 自动重试（指数退避，优先遵循 Retry-After），
    # 重试次数由 A_MAX_RETRIES 控制（默认 3，0 = 禁用）。
    # 请求体与请求头均经临时文件传递（curl -K 配置文件），密钥不进入进程列表可见的命令行。
    Write-Host "`r🤖 思考中...  " -NoNewline
    $payloadFile = _a_mktemp
    $contentFile = _a_mktemp
    $errFile = _a_mktemp
    $hdrFile = _a_mktemp
    $hdrConfFile = _a_mktemp
    $files = @($payloadFile, $contentFile, $errFile, $hdrFile, $hdrConfFile)
    [System.IO.File]::WriteAllText($payloadFile, $payload, $global:_A_UTF8)
    $hdrLines = New-Object System.Collections.Generic.List[string]
    $hdrLines.Add('header = "Content-Type: application/json"')
    if ($ApiKey) { $hdrLines.Add('header = "Authorization: Bearer ' + $ApiKey + '"') }
    [System.IO.File]::WriteAllLines($hdrConfFile, $hdrLines, $global:_A_UTF8)

    $curl = _a_curl_cmd
    # 以 UTF-8 解码 curl 输出（中文增量不乱码），完成后恢复原编码
    $oldEnc = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = $global:_A_UTF8 } catch { }

    $attempt = 0
    $max_retries = if ($env:A_MAX_RETRIES) { [int]$env:A_MAX_RETRIES } else { 3 }
    $backoff = 1
    $curlRc = 0
    $http_code = ''
    $content = $null
    try {
        while ($true) {
            # 每次请求前清空的是接收侧文件；payloadFile/hdrConfFile 是发送侧，只在循环外写一次
            foreach ($f in @($contentFile, $errFile, $hdrFile)) {
                Set-Content -LiteralPath $f -Value '' -NoNewline
            }
            $shown = $false

            & $curl -sS -N --max-time $Timeout -D $hdrFile -K $hdrConfFile `
                --data-binary "@$payloadFile" "$BaseUrl/chat/completions" 2>$errFile | ForEach-Object {
                $line = "$_"
                if ($line.StartsWith('data:')) {
                    $data = $line.Substring(5).TrimStart()
                    if ($data -eq '[DONE]') { return }
                    $delta = _a_json_delta $data
                    if ($delta) {
                        if (-not $shown) {
                            Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline
                            $shown = $true
                        }
                        Write-Host -NoNewline -ForegroundColor DarkGray $delta
                        [System.IO.File]::AppendAllText($contentFile, $delta, $global:_A_UTF8)
                    }
                } elseif ($line.Trim()) {
                    [System.IO.File]::AppendAllText($errFile, $line + "`n", $global:_A_UTF8)
                }
            }
            $curlRc = $LASTEXITCODE
            Write-Host ''
            $content = [System.IO.File]::ReadAllText($contentFile, $global:_A_UTF8)
            $http_code = ''
            $first = (Get-Content -LiteralPath $hdrFile -First 1 -ErrorAction SilentlyContinue)
            if ($first) { $http_code = ($first -split '\s+')[1] }

            $retry = $false; $reason = ''
            if (-not $content) {
                if ($curlRc -ne 0) {
                    # 可重试的网络类退出码（DNS/连接/超时/SSL/重置等）；中断类不重试
                    if (6, 7, 16, 18, 23, 26, 28, 35, 52, 55, 56 -contains $curlRc) {
                        $retry = $true; $reason = "网络错误 (curl $curlRc)"
                    }
                } else {
                    if ($http_code -eq '429') { $retry = $true; $reason = 'HTTP 429 限流' }
                    elseif ($http_code -match '^5\d\d$') { $retry = $true; $reason = "HTTP $http_code 服务端错误" }
                }
            }

            if (-not $retry) { break }
            $attempt++
            if ($attempt -gt $max_retries) { $attempt--; break }
            $ra = ''
            $m = Select-String -LiteralPath $hdrFile -Pattern '^\s*retry-after:\s*(\S+)' | Select-Object -First 1
            if ($m) { $ra = $m.Matches[0].Groups[1].Value }
            if (-not $ra) { $ra = "$backoff" }
            Write-Host ("`r" + (' ' * 40) + "`r⏳ $reason，$ra 秒后重试 ($attempt/$max_retries)")
            try { Start-Sleep -Seconds ([double]$ra) } catch { Start-Sleep -Seconds $backoff }
            $backoff = $backoff * 2
            Write-Host "`r🤖 重试中...  " -NoNewline
        }
    } finally {
        try { [Console]::OutputEncoding = $oldEnc } catch { }
    }

    if (-not $content) {
        # 流式失败：优先按错误 JSON 解析（如 401），其次尝试整包解析（网关忽略 stream 参数时）
        Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline
        if ($attempt -gt 0) { Write-Host "⏳ 已自动重试 $attempt 次仍失败" }
        $errout = [System.IO.File]::ReadAllText($errFile, $global:_A_UTF8)
        if ($errout.Length -gt 2000) { $errout = $errout.Substring(0, 2000) }
        $content = _a_json_content $errout
        if (-not $content) {
            $emsg = _a_json_error $errout
            if ($emsg) {
                _a_err "API 错误: $emsg"
            } elseif ($curlRc -ne 0) {
                _a_err "请求失败 (curl 退出码 $curlRc)"
            } elseif ($http_code -eq '429' -or $http_code -match '^5') {
                _a_err "API 错误 (HTTP $http_code): $errout"
            } else {
                _a_err "无法解析响应: $errout"
            }
            foreach ($f in $files) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            return $null
        }
    }
    foreach ($f in $files) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    return $content
}
