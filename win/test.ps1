# agent-cli-bash Windows 版本地测试: 用 mock HTTP 服务模拟 DeepSeek API，不访问外网。
# 用法: pwsh -NoProfile -File win/test.ps1     （需要 python3 起本地 mock 服务）
# 与 bash 版 test.sh 同源: 同一个 Python mock、同一批标记词；交互式用例
# （ASK 补充、多步 y/n/i 逐条确认、setup 向导）需要伪终端，PowerShell 无 expect
# 对应物，此处覆盖其中的无终端分支，交互分支由人工验证。

$ErrorActionPreference = 'Continue'
$RepoDir = ($PSScriptRoot -replace '\\', '/')
$TestTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("a-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $TestTmp -Force | Out-Null
$Pass = 0; $Fail = 0

function ok([string]$name)   { $script:Pass++; Write-Host "  ✔ $name" }
function fail([string]$name) { $script:Fail++; Write-Host "  ✘ $name" }
function check([string]$name, $got, $want) {   # check <描述> <实际> <期望>
    $g = "$got".TrimEnd(); $w = "$want".TrimEnd()
    if ($g -ceq $w) { ok $name } else { fail "$name (期望: $w, 实际: $g)" }
}
function check_like([string]$name, $hay, $needle) {
    if ("$hay" -match [regex]::Escape($needle)) { ok $name }
    else { fail "$name (未包含: $needle; 实际: $(("$hay" -split "`n") -join ' | '))" }
}
function check_unlike([string]$name, $hay, $needle) {
    if ("$hay" -notmatch [regex]::Escape($needle)) { ok $name }
    else { fail "$name (不应包含: $needle)" }
}
# 子进程输出可能是行数组: 统一按换行拼回多行文本（直接 "$out" 会用空格拼接）
function astext($s) { (@($s) -join "`n") }
function lastline($s) { $t = astext $s; @(@($t -split "`r?`n") | Where-Object { $_.Trim() -ne '' })[-1] }

# 与本机真实配置隔离: 固定不存在的配置文件并清掉继承的配置变量
$env:A_CONFIG_FILE = Join-Path $TestTmp 'nonexistent-config'
foreach ($v in 'A_API_KEY', 'A_PROVIDER', 'A_BASE_URL', 'A_MODEL', 'A_MAX_RETRIES',
               'A_MAX_CONTEXT_CHARS', 'A_TIMEOUT', 'A_DIR_ENTRIES',
               'DEEPSEEK_API_KEY', 'DEEPSEEK_BASE_URL', 'DEEPSEEK_MODEL',
               'OPENAI_API_KEY', 'A_TEST_DIR') {
    Remove-Item "env:$v" -ErrorAction SilentlyContinue
}

# 进程内直接加载被测代码（单元测试用）
. "$RepoDir/a.ps1"

# ---------- mock 服务 ----------
$mockPy = Join-Path $TestTmp 'mock.py'
@'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
retry_state = {"count": 0}

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n))
        msgs = body.get("messages", [])
        last_user = next((m["content"] for m in reversed(msgs) if m["role"] == "user"), "")
        allc = " ".join(m["content"] for m in msgs)
        auth = self.headers.get("Authorization", "")
        if "BADKEY" in auth or "AUTHFAIL" in last_user:
            code, obj = 401, {"error": {"message": "Authentication Fails (no such user)"}}
        else:
            nofence = False
            if "RATELIMIT" in last_user:
                self.send_response(429)
                self.send_header("retry-after", "1")
                self.send_header("content-type", "application/json")
                data = json.dumps({"error": {"message": "Insufficient Balance"}}).encode()
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            elif "RETRYME" in last_user:
                retry_state["count"] += 1
                if retry_state["count"] == 1:
                    self.send_response(503)
                    self.send_header("content-type", "text/plain")
                    self.send_header("content-length", "13")
                    self.end_headers()
                    self.wfile.write(b"temp unavail")
                    return
                cmd = "Write-Output RETRY_OK"
            elif "MOCK_ECHO_CWD" in last_user:
                cmd = "Write-Output CWD_WAS_SENT"
            elif "RC7" in last_user:
                cmd = "$global:LASTEXITCODE = 7"
            elif "MULTI" in last_user:
                cmd = "Write-Output STEP_A\nWrite-Output STEP_B\nWrite-Output STEP_C"
            elif "DANGEROUS" in last_user:
                cmd = "sudo rm -rf /tmp/a-bad-demo"
            elif "PIPE_DATA_MARKER" in last_user:
                cmd = "Write-Output PIPE_SEEN"
            elif "PIPE2_MARKER" in last_user:
                cmd = "Write-Output PIPE2_SEEN"
            elif "CDTEST" in last_user:
                cmd = "Set-Location $env:A_TEST_DIR"
            elif "VARTEST" in last_user:
                cmd = "$env:A_TEST_VAR = 'shell_state_ok'"
            elif "PROVIDER" in last_user:
                cmd = "Write-Output PROVIDER_MODEL_OK" if body.get("model") == "kimi-k2-0905-preview" else "Write-Output MODEL_WRONG"
            elif "PWDCTX" in last_user:
                want_git = "NOGIT" not in last_user
                ok = ("当前目录:" in allc) and ("目录内容" in allc) and (("git:" in allc) == want_git)
                cmd = "Write-Output ENVCTX_OK" if ok else "Write-Output ENVCTX_MISSING"
            elif "DIRCTX" in last_user:
                ok = ("linuxmint-22.3-cinnamon-64bit-hwe-7.0.iso" in last_user
                      and "共 22 项" in last_user and "仅列 15 项" in last_user)
                cmd = "Write-Output DIRCTX_OK" if ok else "Write-Output DIRCTX_MISS"
            elif "ASKFLOW" in allc:
                if "补充:" in last_user and "ANSWER42" in last_user:
                    cmd = "Write-Output ASKFLOW_DONE"
                else:
                    cmd = "ASK: 目录里有多个候选文件，要处理哪一个？（回答里包含 ANSWER42 即可通过）"
            elif "ASKLOOP" in allc:
                cmd = "ASK: 还是没看懂，能再说详细一点吗？"
            elif "ASKMARK" in last_user:
                # ask 模式: 校验 max_tokens=1024、消息用「问题:」前缀、且不携带 run 模式会话（隔离）
                if body.get("max_tokens") != 1024 or "FIRST_MARKER_CMD" in allc or "问题:" not in last_user:
                    cmd = "回答WRONG"
                else:
                    cmd = "回答OK\n第二行含围栏:\n```bash\nls\n```"
                nofence = True
            elif "TRIM0" in last_user:
                cmd = "Write-Output PAD_OLD_" + "P" * 300
            elif "TRIM1" in last_user:
                cmd = "Write-Output PAD_MID_" + "M" * 300
            elif "TRIM2" in last_user:
                cmd = "Write-Output CTX_NOT_TRIMMED" if "TRIM0 请求" in allc else "Write-Output CTX_TRIMMED_OK"
            elif "FEEDBACK1" in last_user:
                cmd = "Write-Output HELLO_FE"
            elif "FEEDBACK2" in last_user:
                cmd = "Write-Output SEEN_RESULT" if "HELLO_FE" in allc else "Write-Output NOT_SEEN"
            elif "FIRST" in last_user:
                cmd = "Write-Output FIRST_MARKER_CMD"
            elif "SECOND" in last_user:
                cmd = "Write-Output CTX_OK" if "FIRST_MARKER_CMD" in allc else "Write-Output SECOND_NO_CTX"
            else:
                cmd = 'Write-Output "mock 命令 <fence>"'
            full = cmd if nofence else ("```powershell\n" + cmd + "\n```")
            # SSE 流式: 按 5 字节小块发送（块尾常为换行），验证增量拼接不丢换行
            chunks = [full[i:i + 5] for i in range(0, len(full), 5)]
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.end_headers()
            for ch in chunks:
                data = json.dumps({"choices": [{"delta": {"content": ch}}]})
                self.wfile.write(("data: " + data + "\n\n").encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
'@ | Set-Content -LiteralPath $mockPy -Encoding UTF8

$mockPort = [int](& python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
$mockProc = Start-Process python3 -ArgumentList "`"$mockPy`"", "$mockPort" -PassThru
Start-Sleep -Seconds 1
$Url = "http://127.0.0.1:$mockPort"

# ---------- 子进程执行器 ----------
# run_a: 常规调用（继承本进程 stdin）。输出（含 stderr）合并返回。
function run_a([string]$inner) {
    & pwsh -NoProfile -Command ('. ' + "'$RepoDir/a.ps1'" + '; ' + $inner) 2>&1
}
# run_a_rc: 同上，但把 $A_LAST_RC 作为子进程退出码返回（输出留在 $script:lastOut）
function run_a_rc([string]$inner) {
    $script:lastOut = & pwsh -NoProfile -Command ('. ' + "'$RepoDir/a.ps1'" + '; ' + $inner + '; exit $global:A_LAST_RC') 2>&1
    return $LASTEXITCODE
}
# run_a_stdin: 脚本经 stdin 注入子进程（stdin 因此是重定向的 → 无终端分支），
# 返回 @{Out=…; Rc=…}。用于 ASK/高危确认在无终端环境下的行为。
function run_a_stdin([string]$inner) {
    $cmd = ". '$RepoDir/a.ps1'; $inner; exit `$global:A_LAST_RC"
    $out = @($cmd | & pwsh -NoProfile -Command - 2>&1)
    return @{ Out = (astext $out); Rc = $LASTEXITCODE }
}

try {
    $env:DEEPSEEK_API_KEY = 'sk-test'
    $env:DEEPSEEK_BASE_URL = $Url

    Write-Host "== 1. JSON 转义与围栏清理（进程内） =="
    check '反斜杠与引号转义' (_a_json_escape 'a"b\c') 'a\"b\\c'
    $fence = @'
```bash
echo hi
```
'@
    check '去掉 ```bash 围栏' (_a_clean $fence) 'echo hi'

    Write-Host "== 2. mock API 全链路 =="
    $out = run_a 'a -p ''随便来个命令'''
    check '-p 提取命令并去围栏' (lastline $out) 'Write-Output "mock 命令 <fence>"'

    $out = run_a 'a -y ''MOCK_ECHO_CWD'''
    check_like '-y 执行返回命令' $out 'CWD_WAS_SENT'

    Write-Host "== 2.1 管道输入 =="
    $out = run_a '''ERROR: PIPE_DATA_MARKER boom'' | a -p ''解释这个报错'''
    check '管道内容作为上下文发送' (lastline $out) 'Write-Output PIPE_SEEN'
    $out = run_a '''PIPE2_MARKER 数据'' | a -p'
    check '管道输入可省略文字描述' (lastline $out) 'Write-Output PIPE2_SEEN'

    Write-Host "== 2.2 会话状态命令在当前会话生效 =="
    $tmpd = Join-Path $TestTmp 'cwdtest'
    New-Item -ItemType Directory -Path $tmpd -Force | Out-Null
    $env:A_TEST_DIR = $tmpd
    $out = run_a ('$null = a -y ''CDTEST 请求''; (Get-Location).Path')
    check 'cd（Set-Location）在当前会话生效' (lastline $out) $tmpd
    $out = run_a '$null = a -y ''VARTEST 请求''; $env:A_TEST_VAR'
    check '$env: 赋值生效' (lastline $out) 'shell_state_ok'
    Remove-Item env:A_TEST_DIR -ErrorAction SilentlyContinue

    Write-Host "== 2.3 自动重试 =="
    $out = run_a 'a -p ''RETRYME 请求'''
    check '503 后自动重试成功' (lastline $out) 'Write-Output RETRY_OK'
    $env:A_MAX_RETRIES = '1'
    $rc = run_a_rc 'a -p ''RATELIMIT 请求'''
    check '429 重试耗尽后报错' "$rc - $(@((astext $script:lastOut) -split "`n" | Where-Object { $_ -match '已自动重试 1 次' }).Count)" '1 - 1'
    check_like '重试耗尽保留原始错误详情' $script:lastOut 'Insufficient Balance'
    $env:A_MAX_RETRIES = '0'
    $rc = run_a_rc 'a -p ''RATELIMIT 请求'''
    check 'A_MAX_RETRIES=0 禁用重试' "$rc - $(@((astext $script:lastOut) -split "`n" | Where-Object { $_ -match '已自动重试' }).Count)" '1 - 0'
    Remove-Item env:A_MAX_RETRIES -ErrorAction SilentlyContinue

    Write-Host "== 2.4 上下文管理 =="
    $env:A_MAX_CONTEXT_CHARS = '300'
    $out = run_a 'a -y ''TRIM0 请求'' | Out-Null; a -y ''TRIM1 请求'' | Out-Null; a -p ''TRIM2 请求'''
    check '超预算时裁掉最旧的轮' (lastline $out) 'Write-Output CTX_TRIMMED_OK'
    Remove-Item env:A_MAX_CONTEXT_CHARS -ErrorAction SilentlyContinue

    $out = run_a 'a -p ''SHOW1 请求'' | Out-Null; a --show'
    check_like '--show 展示轮次' $out '轮 1'
    check_like '--show 展示体积' $out '下一轮将发送'
    $out = run_a 'a --show'
    check '--show 空上下文提示' (lastline $out) '（当前会话暂无对话上下文）'

    Write-Host "== 2.5 多提供商 =="
    $env:A_PROVIDER = 'kimi'; $env:A_API_KEY = 'sk-k'; $env:A_BASE_URL = $Url
    $out = run_a 'a -p ''PROVIDER 测试'''
    check 'A_PROVIDER=kimi 使用默认模型' (lastline $out) 'Write-Output PROVIDER_MODEL_OK'
    Remove-Item env:A_PROVIDER, env:A_API_KEY, env:A_BASE_URL -ErrorAction SilentlyContinue

    $env:A_PROVIDER = 'openai'; $env:OPENAI_API_KEY = 'sk-o'; $env:A_BASE_URL = $Url
    $rc = run_a_rc 'a -p ''随便'''
    check '自动读取 OPENAI_API_KEY' "$rc - $(if ($rc -eq 0) { 'ok' } else { 'fail' })" '0 - ok'
    Remove-Item env:A_PROVIDER, env:OPENAI_API_KEY, env:A_BASE_URL -ErrorAction SilentlyContinue

    $env:A_PROVIDER = 'nosuch'; $env:A_API_KEY = 'sk-x'
    $rc = run_a_rc 'a -p ''hi'''
    check '未知提供商报错' "$rc - $(@("$($script:lastOut)" -split "`n" | Where-Object { $_ -match '未知提供商' }).Count)" '1 - 1'
    Remove-Item env:A_PROVIDER, env:A_API_KEY -ErrorAction SilentlyContinue

    $env:A_PROVIDER = 'ollama'; $env:A_BASE_URL = $Url
    $rc = run_a_rc 'a -p ''随便'''
    check 'ollama 无密钥可用' "$rc - $(if ($rc -eq 0) { 'ok' } else { 'fail' })" '0 - ok'
    Remove-Item env:A_PROVIDER, env:A_BASE_URL -ErrorAction SilentlyContinue

    $out = run_a 'a providers'
    check_like 'providers 列表输出' $out 'openai'
    check_like 'providers 列表输出(kimi)' $out 'kimi'

    Write-Host "== 2.6 配置文件解析 =="
    $cfg = Join-Path $TestTmp 'config'
    "A_PROVIDER=kimi`nA_API_KEY=sk-k`nA_BASE_URL=$Url" | Set-Content -LiteralPath $cfg -Encoding UTF8
    $env:A_CONFIG_FILE = $cfg
    $rc = run_a_rc 'a -p ''PROVIDER 测试'''
    check 'config 文件配置提供商/密钥/地址' "$rc - $(lastline $script:lastOut)" '0 - Write-Output PROVIDER_MODEL_OK'

    "A_API_KEY=sk-test`nA_BASE_URL=$Url`nA_MAX_RETRIES=0" | Set-Content -LiteralPath $cfg -Encoding UTF8
    $rc = run_a_rc 'a -p ''RATELIMIT 请求'''
    check 'config 文件中 A_MAX_RETRIES=0 禁用重试' "$rc - $(@((astext $script:lastOut) -split "`n" | Where-Object { $_ -match '已自动重试' }).Count)" '1 - 0'
    Remove-Item env:A_CONFIG_FILE -ErrorAction SilentlyContinue
    $env:A_CONFIG_FILE = Join-Path $TestTmp 'nonexistent-config'

    Write-Host "== 2.7 环境上下文 =="
    $out = run_a "Set-Location '$RepoDir'; a -p 'PWDCTX 请求'"
    check '携带当前目录/git 状态/目录条目' (lastline $out) 'Write-Output ENVCTX_OK'
    $tmpd2 = Join-Path $TestTmp 'nogit'
    New-Item -ItemType Directory -Path $tmpd2 -Force | Out-Null
    Set-Content (Join-Path $tmpd2 'a-file.txt') 'x'
    $out = run_a "Set-Location '$tmpd2'; a -p 'PWDCTX NOGIT 请求'"
    check '非 git 目录不携带 git 行' (lastline $out) 'Write-Output ENVCTX_OK'

    Write-Host "== 2.7.1 目录条目智能选取 =="
    $tmpd3 = Join-Path $TestTmp 'dirs'
    New-Item -ItemType Directory -Path $tmpd3 -Force | Out-Null
    # 20 个字母序靠前的旧文件 + 目标 iso（口语"linuxiso"应命中）+ 最新的无关文件
    for ($i = 1; $i -le 20; $i++) {
        $f = Join-Path $tmpd3 ('aaa-{0:D2}.txt' -f $i)
        Set-Content $f 'x'
        (Get-Item $f).LastWriteTime = Get-Date '2020-01-01'
    }
    $iso = Join-Path $tmpd3 'linuxmint-22.3-cinnamon-64bit-hwe-7.0.iso'
    Set-Content $iso 'x'
    (Get-Item $iso).LastWriteTime = Get-Date '2024-01-01'
    Set-Content (Join-Path $tmpd3 'zz-new.txt') 'x'

    $out = run_a "Set-Location '$tmpd3'; _a_env_context '计算linuxiso的sha256'"
    $ctxLines = @((astext $out) -split "`r?`n" | Where-Object { $_ -match '^(aaa-|linuxmint|zz-new)' })
    check_like '口语缩写命中目标文件（字母序截断下不可见）' $out 'linuxmint-22.3-cinnamon-64bit-hwe-7.0.iso'
    check_like '表头注明总条目数' $out '共 22 项'
    check '只列 15 项' $ctxLines.Count '15'
    check '命中条目排在首位' $ctxLines[0] 'linuxmint-22.3-cinnamon-64bit-hwe-7.0.iso'

    $out = run_a "Set-Location '$tmpd3'; _a_env_context '看看最新下载的东西'"
    check '无词元查询按修改时间补足（最新在前）' (@((astext $out) -split "`r?`n" | Where-Object { $_ -match '^(aaa-|linuxmint|zz-new)' })[0]) 'zz-new.txt'

    $env:A_DIR_ENTRIES = '5'
    $out = run_a "Set-Location '$tmpd3'; _a_env_context '算linuxiso的'"
    check 'A_DIR_ENTRIES=5 只列 5 项' @((astext $out) -split "`r?`n" | Where-Object { $_ -match '^(aaa-|linuxmint|zz-new)' }).Count '5'
    $env:A_DIR_ENTRIES = '0'
    $out = run_a "Set-Location '$tmpd3'; _a_env_context '随便'"
    check 'A_DIR_ENTRIES=0 不注入目录内容' @((astext $out) -split "`r?`n" | Where-Object { $_ -match '目录内容' }).Count '0'
    Remove-Item env:A_DIR_ENTRIES -ErrorAction SilentlyContinue

    $out = run_a "Set-Location '$tmpd3'; a -p 'DIRCTX 计算linuxiso的sha256'"
    check 'e2e: 发送的消息携带目标文件而非字母序截断' (lastline $out) 'Write-Output DIRCTX_OK'

    Write-Host "== 2.8 a ask 模式 =="
    $out = run_a 'a ask ''ASKMARK 测试'''
    # 流式显示的行首可能残留 \r/清行空白，逐行 Trim 后再取尾部
    $lines = @((astext $out) -split "`r?`n" | ForEach-Object { $_.Trim() })
    $idx = [array]::IndexOf($lines, '回答OK')
    $tail = ($lines[$idx..($idx + 4)] -join "`n")
    check 'a ask 原样输出（含围栏）' $tail "回答OK`n第二行含围栏:`n``````bash`nls`n``````"

    $out = run_a 'a -p ''FIRST 请求'' | Out-Null; a ask ''ASKMARK 问答''; a -p ''SECOND 请求'''
    check_like 'ask 不带 run 会话' $out '回答OK'
    check 'run 上下文不受影响' (lastline $out) 'Write-Output CTX_OK'

    $out = run_a 'a -p ''FIRST 请求'' | Out-Null; a ask ''ASKMARK 问答'' | Out-Null; a -c; a --show'
    check 'a -c 清空全部模式' (lastline $out) '（当前会话暂无对话上下文）'

    $out = run_a 'a -p ''FIRST 请求'' | Out-Null; a ask ''ASKMARK 问答'' | Out-Null; a --show'
    check_like '--show 分模式展示(run)' $out '[run]'
    check_like '--show 分模式展示(ask)' $out '[ask]'

    $out = run_a '''问下这段日志的意思 ASKMARK'' | a ask'
    check_like 'ask 管道输入可省略文字描述' $out '回答OK'

    Write-Host "== 3. ASK 反问（无终端分支） =="
    $r = run_a_stdin 'a -y ''ASKFLOW 请求'''
    check '无终端时 ASK 取消并提示' "$($r.Rc) - $(@($r.Out -split "`n" | Where-Object { $_ -match '无终端可交互' }).Count)" '1 - 1'

    Write-Host "== 4. 错误路径 =="
    $oldKey = $env:DEEPSEEK_API_KEY
    $env:DEEPSEEK_API_KEY = 'sk-BADKEY'
    $rc = run_a_rc 'a -p ''hi'''
    $firstErr = @((astext $script:lastOut) -split "`n" | Where-Object { $_ -match '^a: ' })[0]
    check '401 时报错且含 API 信息' "$rc - $firstErr" '1 - a: API 错误: Authentication Fails (no such user)'
    $env:DEEPSEEK_API_KEY = $oldKey

    Remove-Item env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue
    $rc = run_a_rc 'a -p ''hi'''
    check '无密钥时报错' $rc '1'
    $env:DEEPSEEK_API_KEY = $oldKey

    Write-Host "== 5. 多轮会话与上下文 =="
    $out = run_a 'a -p ''FIRST 请求''; a -p ''SECOND 请求'''
    check '同会话第二轮携带第一轮上下文' (lastline $out) 'Write-Output CTX_OK'

    $out = run_a 'a -y ''FEEDBACK1 请求'' | Out-Null; a -p ''FEEDBACK2 请求'''
    check '执行结果回传到下一轮对话' (lastline $out) 'Write-Output SEEN_RESULT'

    $out = run_a 'a -p ''FIRST 请求''; a -c; a -p ''SECOND 请求'''
    check 'a -c 清空会话上下文' (lastline $out) 'Write-Output SECOND_NO_CTX'

    $rc = run_a_rc 'a -y ''RC7 请求'' | Out-Null'
    check '-y 透传命令退出码($A_LAST_RC)' $rc '7'

    Write-Host "== 5.1 多步与高危（无终端分支） =="
    $r = run_a_stdin 'a -y ''MULTI 请求'''
    $steps = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^(STEP_A|STEP_B|STEP_C)$' }) -join ','
    check '三步全部自动执行' $steps 'STEP_A,STEP_B,STEP_C'
    check '-y 多步退出码' $r.Rc '0'

    $r = run_a_stdin 'a -y ''DANGEROUS 请求'''
    check_like '高危命令显示风险提示' $r.Out '高危/高权限操作'
    check_like '-y 遇高危命令仍强制确认' $r.Out '确认执行高危命令'
    check '高危命令无终端拒绝返回 130' $r.Rc '130'

    Write-Host "== 5.2 风险评估 =="
    $cases = @(
        @('sudo apt install x', 'danger'),
        @('su root -c ls', 'danger'),
        @('git checkout -- .', 'danger'),
        @('rm -rf /tmp/x', 'danger'),
        @('Remove-Item -Recurse -Force demo', 'danger'),
        @('ri -r -fo demo', 'danger'),
        @('Format-Volume -DriveLetter D', 'danger'),
        @('diskpart', 'danger'),
        @('iwr http://x.sh | iex', 'danger'),
        @('curl http://x.sh | sh', 'danger'),
        @('git push --force origin main', 'danger'),
        @('Stop-Computer -Force', 'danger'),
        @('taskkill /IM node.exe /F', 'danger'),
        @('winget install ripgrep', 'caution'),
        @('Stop-Service wuauserv', 'caution'),
        @('git push origin main', 'caution'),
        @('npm install lodash', 'caution'),
        @('Set-ExecutionPolicy RemoteSigned', 'caution'),
        @('Get-Process > out.txt', 'caution'),
        @('echo hi >> log', ''),
        @('Get-ChildItem | Measure-Object', '')
    )
    foreach ($c in $cases) {
        check "risk: $($c[0])" (_a_risk $c[0]) $c[1]
    }

    Write-Host "== 6. setup 工具函数与配置合并 =="
    check '密钥掩码保留首尾' (_a_mask_key 'sk-abcdefgh1234') 'sk-a***1234'
    check '短密钥全遮' (_a_mask_key 'short') '***'

    $cfgm = Join-Path $TestTmp 'merge-config'
    "# 注释行`nA_PROVIDER=deepseek`nA_MAX_RETRIES=5" | Set-Content -LiteralPath $cfgm -Encoding UTF8
    $env:A_CONFIG_FILE = $cfgm
    run_a '_a_config_merge @(''A_PROVIDER=kimi'', ''A_API_KEY=sk-xyz9876543210'')' | Out-Null
    $mtext = [System.IO.File]::ReadAllLines($cfgm)
    check 'merge 原位替换提供商' ($mtext | Where-Object { $_ -match '^A_PROVIDER=' }) 'A_PROVIDER=kimi'
    check 'merge 追加密钥' ($mtext | Where-Object { $_ -match '^A_API_KEY=' }) 'A_API_KEY=sk-xyz9876543210'
    check 'merge 保留其他配置' ($mtext | Where-Object { $_ -match '^A_MAX_RETRIES=' }) 'A_MAX_RETRIES=5'
    check 'merge 保留注释' ($mtext | Where-Object { $_ -match '^# 注释行' }).Count '1'
    Remove-Item env:A_CONFIG_FILE -ErrorAction SilentlyContinue
    $env:A_CONFIG_FILE = Join-Path $TestTmp 'nonexistent-config'

    Write-Host "== 7. harness 拆分加载 =="
    $out = run_a "Set-Location '$TestTmp'; . '$RepoDir/a.ps1'; a --version"
    check '异地 cwd 绝对路径加载' (lastline $out) 'agent-cli-bash 0.5.0'
    $out = & pwsh -NoProfile -Command "Set-Location '$RepoDir'; . ./a.ps1; a --version" 2>&1
    check '相对路径 dot-source 加载' (lastline $out) 'agent-cli-bash 0.5.0'

    Write-Host "== 8. install.ps1 安装/卸载 =="
    $tmpHome = Join-Path $TestTmp 'home'
    New-Item -ItemType Directory -Path $tmpHome -Force | Out-Null
    $oldHome = $env:HOME
    $env:HOME = $tmpHome
    try {
        # 子进程里问 $PROFILE 路径（macOS/pwsh 跟随 $HOME；Windows 宿主跟 Documents，跳过）
        $prof = (& pwsh -NoProfile -Command '$PROFILE.CurrentUserAllHosts' | Select-Object -First 1)
        if ("$prof" -like "$tmpHome*") {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File "$RepoDir/install.ps1" *> $null
            $ptext = if (Test-Path $prof) { [System.IO.File]::ReadAllText($prof) } else { '' }
            check_like '写入 $PROFILE 并指向 a.ps1' $ptext 'a.ps1'
            check '重复安装幂等（只有一块）' ([regex]::Matches($ptext, [regex]::Escape('# >>> agent-cli-bash >>>')).Count) '1'
            $cfgtpl = Join-Path $tmpHome '.config/agent-cli-bash/config'
            check_like '生成配置模板' ([System.IO.File]::ReadAllText($cfgtpl)) 'A_PROVIDER='
            & pwsh -NoProfile -ExecutionPolicy Bypass -File "$RepoDir/install.ps1" -Uninstall *> $null
            $ptext2 = if (Test-Path $prof) { [System.IO.File]::ReadAllText($prof) } else { '' }
            check '卸载干净' ([regex]::Matches($ptext2, 'agent-cli-bash').Count) '0'
        } else {
            Write-Host '  （$PROFILE 不跟随 HOME（Windows Documents 重定向），跳过安装测试）'
        }
    } finally {
        $env:HOME = $oldHome
    }
} finally {
    if ($mockProc) { Stop-Process -Id $mockProc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $TestTmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "结果: $Pass 通过, $Fail 失败"
if ($Fail -gt 0) { exit 1 } else { exit 0 }
