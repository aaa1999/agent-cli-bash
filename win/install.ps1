# agent-cli-bash Windows 版 安装/卸载脚本
# 用法:
#   powershell -ExecutionPolicy Bypass -File install.ps1               安装
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall    卸载
#
# 安装 = 在 $PROFILE（CurrentUserAllHosts，所有宿主生效）里加一行 dot-source a.ps1，
# 并生成配置模板（与 bash 版同路径同格式: ~\.config\agent-cli-bash\config）。

param([switch]$Uninstall)

$RepoDir = $PSScriptRoot
$MarkBegin = '# >>> agent-cli-bash >>>'
$MarkEnd = '# <<< agent-cli-bash <<<'
$Line = ". `"$RepoDir\a.ps1`""

function Usage {
    Write-Output "用法: powershell -ExecutionPolicy Bypass -File install.ps1 [-Uninstall]"
    Write-Output ""
    Write-Output "  （无参数）    安装 a 命令到当前用户的 PowerShell 配置"
    Write-Output "  -Uninstall    移除 a 命令"
}

if ($Uninstall) {
    $target = $PROFILE.CurrentUserAllHosts
    if (Test-Path -LiteralPath $target) {
        $text = [System.IO.File]::ReadAllText($target)
        $pattern = "(?s)\r?\n?# >>> agent-cli-bash >>>.*?# <<< agent-cli-bash <<<\r?\n?"
        $new = [regex]::Replace($text, $pattern, '')
        [System.IO.File]::WriteAllText($target, $new, (New-Object System.Text.UTF8Encoding($true)))
        Write-Output "已从 $target 移除 agent-cli-bash"
    } else {
        Write-Output "未找到 $target，无需卸载"
    }
    exit 0
}

# 执行策略: 5.1 默认 Restricted 会连 $PROFILE 里的脚本一并拦下
$policy = Get-ExecutionPolicy
if ($policy -in 'Restricted', 'AllSigned') {
    Write-Warning "当前执行策略是 $policy，$PROFILE 中的 dot-source 行不会被执行。"
    $ans = Read-Host '是否为你设置 CurrentUser 作用域的 RemoteSigned 策略? [y/N]'
    if ($ans -eq 'y' -or $ans -eq 'Y') {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
        Write-Output '已设置 ExecutionPolicy = RemoteSigned (CurrentUser)'
    } else {
        Write-Output '跳过。之后可自行执行: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
    }
}

$target = $PROFILE.CurrentUserAllHosts
$targetDir = Split-Path -Parent $target
if (-not (Test-Path -LiteralPath $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

# 幂等: 先删旧块再追加新块（仓库移动位置后路径也能更新）
if (Test-Path -LiteralPath $target) {
    $text = [System.IO.File]::ReadAllText($target)
    $pattern = "(?s)\r?\n?# >>> agent-cli-bash >>>.*?# <<< agent-cli-bash <<<\r?\n?"
    $text = [regex]::Replace($text, $pattern, '')
    [System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($true)))
}
Add-Content -LiteralPath $target -Value "`n$MarkBegin`n$Line`n$MarkEnd" -Encoding UTF8

# 生成配置文件模板（不覆盖已有的；Windows 上不做 chmod，配置目录默认仅本用户可访问）
$configDir = Join-Path $HOME '.config/agent-cli-bash'
$configFile = Join-Path $configDir 'config'
if (-not (Test-Path -LiteralPath $configFile)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $tpl = @'
# agent-cli-bash 配置。也可用环境变量覆盖同名项（运行 `a providers` 查看内置提供商）
# 提供商: deepseek(默认) openai kimi qwen zhipu grok ollama openrouter
A_PROVIDER=deepseek
# 密钥填这里（也可 $env:A_API_KEY = 'sk-xxx'，或用提供商变量如 OPENAI_API_KEY）
A_API_KEY=
# 以下可选，留空用提供商默认
# A_BASE_URL=
# A_MODEL=
# A_MAX_RETRIES=3            # 网络错误/429/5xx 自动重试次数（0=禁用）
# A_MAX_CONTEXT_CHARS=24000  # 会话上下文字符预算
# A_TIMEOUT=60               # 单次 API 请求超时秒数
# A_DIR_ENTRIES=15           # 目录条目注入上限（0=不注入）；超出时相关的优先、其余按修改时间
'@
    [System.IO.File]::WriteAllText($configFile, $tpl, (New-Object System.Text.UTF8Encoding($true)))
    Write-Output "已生成配置模板 $configFile（记得填入 A_API_KEY）"
}

Write-Output ""
Write-Output "安装完成 ✔（宿主: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)）"
Write-Output ""
Write-Output "  1. 重开 PowerShell，或先执行:  . $target"
Write-Output "  2. 配置密钥: 运行 a setup 交互式配置"
Write-Output "     （或 `$env:A_API_KEY='sk-xxx' / 编辑 $configFile）"
Write-Output "  3. 试用:  a 找出当前目录下最大的 5 个文件"
Write-Output ""
