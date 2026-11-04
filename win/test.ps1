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
               'A_MAX_CONTEXT_CHARS', 'A_TIMEOUT', 'A_STEP_TIMEOUT', 'A_DIR_ENTRIES',
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
AGENT_TMP = sys.argv[2] if len(sys.argv) > 2 else "."
retry_state = {"count": 0}
agent_state = {}

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(n))
        msgs = body.get("messages", [])
        last_user = next((m["content"] for m in reversed(msgs) if m["role"] == "user"), "")
        allc = " ".join(m.get("content") or "" for m in msgs)
        auth = self.headers.get("Authorization", "")
        if "BADKEY" in auth or "AUTHFAIL" in last_user:
            code, obj = 401, {"error": {"message": "Authentication Fails (no such user)"}}
        elif body.get("tools") is not None:
            # ---- agent 模式: 非流式 + tool_calls（按标记词编排多步序列） ----
            def tc(i, name, args):
                return {"id": i, "type": "function",
                        "function": {"name": name, "arguments": json.dumps(args)}}
            def seq(key, script):
                st = agent_state.get(key, 0) + 1
                agent_state[key] = st
                return script[min(st - 1, len(script) - 1)]
            msg = None
            if "AGENTLOOPFOREVER" in last_user:
                agent_state["LF"] = agent_state.get("LF", 0) + 1
                msg = {"content": "", "tool_calls": [tc("cf_%d" % agent_state["LF"], "pwsh", {"command": "Write-Output FOREVER"})]}
            elif "AGENTLOOP2" in last_user:
                msg = seq("L2", [
                    {"content": "", "tool_calls": [tc("c2_1", "pwsh", {"command": "Write-Output AGENT2_STEP1"})]},
                    {"content": "AGENT2_DONE"},
                ])
            elif "AGENTSHOW" in last_user:
                msg = seq("SH", [
                    {"content": "", "tool_calls": [tc("cs_1", "pwsh", {"command": "Write-Output AGENT_SHOW_STEP"})]},
                    {"content": "AGENT_SHOW_DONE"},
                ])
            elif "AGENTLOOP" in last_user:
                msg = seq("L1", [
                    {"content": "", "tool_calls": [tc("call_1", "pwsh", {"command": "Write-Output AGENT_STEP1"})]},
                    {"content": "", "tool_calls": [tc("call_2", "pwsh", {"command": "Write-Output AGENT_STEP2"})]},
                    {"content": "AGENT_DONE"},
                ])
            elif "AGENTDANGER" in last_user:
                msg = seq("DG", [
                    {"content": "", "tool_calls": [tc("call_d", "pwsh", {"command": "sudo rm -rf C:/a-agent-danger"})]},
                    {"content": "DANGER_HANDLED"},
                ])
            elif "AGENTASK" in last_user:
                msg = seq("AK", [
                    {"content": "", "tool_calls": [tc("call_a", "ask_user_question",
                        {"questions": [{"id": "q1", "question": "用哪个方案?",
                                        "options": [{"label": "甲"}, {"label": "乙", "description": "保守"}]}]})]},
                    {"content": "ASK_HANDLED" if '"answers"' in allc else "ASK_MISSING"},
                ])
            elif "AGENTTODO" in last_user:
                msg = seq("TD", [
                    {"content": "", "tool_calls": [tc("call_t", "todo_write",
                        {"todos": [{"content": "第一步", "status": "completed"},
                                   {"content": "第二步", "status": "in_progress"}]})]},
                    {"content": "TODO_HANDLED" if "Updated todo list" in allc else "TODO_MISSING"},
                ])
            elif "AGENTWRITE" in last_user:
                msg = seq("WY", [
                    {"content": "", "tool_calls": [tc("call_w", "write",
                        {"file_path": AGENT_TMP + "/a-agent-write-y.txt", "content": "written-by-agent"})]},
                    {"content": "WRITE_HANDLED"},
                ])
            elif "AGENTDECLINE" in last_user:
                msg = seq("WN", [
                    {"content": "", "tool_calls": [tc("call_wn", "write",
                        {"file_path": AGENT_TMP + "/a-agent-write-n.txt", "content": "should-not-exist"})]},
                    {"content": "DECLINE_HANDLED" if "declined" in allc else "DECLINE_MISSING"},
                ])
            elif "AGENTCTX" in last_user:
                msg = {"content": "CTX_SEEN" if "AGENT_DONE" in allc else "CTX_MISSING"}
            elif "AGENTSHEMA" in last_user:
                names = sorted(t["function"]["name"] for t in body["tools"])
                ok = (len(names) == 10 and "pwsh" in names and body.get("tool_choice") == "auto" and body.get("stream") is False)
                msg = {"content": "SCHEMA_OK" if ok else "SCHEMA_BAD:%s" % names}
            elif "AGENTRETRY" in last_user:
                st = agent_state.get("AR", 0) + 1
                agent_state["AR"] = st
                if st == 1:
                    data = json.dumps({"error": {"message": "Insufficient Balance"}}).encode()
                    self.send_response(429)
                    self.send_header("retry-after", "1")
                    self.send_header("content-type", "application/json")
                    self.send_header("content-length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                msg = {"content": "RETRY_OK"}
            else:
                msg = {"content": "AGENT_DEFAULT"}
            data = json.dumps({"choices": [{"message": msg, "finish_reason": "stop"}]}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
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
            elif "BLOCKFOR" in last_user:
                cmd = "foreach ($i in 1..3) {\n  Write-Output \"BFC_$i\"\n}"
            elif "BLOCKHD" in last_user:
                cmd = "@'\nheredoc line1\nheredoc line2\n'@ | Set-Content -LiteralPath $env:A_HD_TEST"
            elif "BLOCKMIX" in last_user:
                cmd = "foreach ($f in 'a','b') {\n  Write-Output \"MX_$f\"\n}\nWrite-Output MX_TAIL"
            elif "TIMEOUT1" in last_user:
                cmd = "Start-Sleep -Seconds 8"
            elif "TIMEOUT2" in last_user:
                cmd = "Write-Output SAW_TIMEOUT" if "超时" in allc else "Write-Output NO_TIMEOUT_CTX"
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
$agentTmp = Join-Path $TestTmp 'agent'
New-Item -ItemType Directory -Path $agentTmp -Force | Out-Null
$mockProc = Start-Process python3 -ArgumentList "`"$mockPy`"", "$mockPort", "`"$agentTmp`"" -PassThru
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

    Write-Host "== 5.3 跨行结构切分与整体执行 =="
    # 切分单测: 各步骤以 %% 连接（步骤内部保留换行）
    function split_join([string]$Cmd) { (_a_split_steps $Cmd) -join '%%' }
    $si1 = @'
foreach ($i in 1..3) {
  Write-Output "BFC_$i"
}
Write-Output after
'@
    $se1 = @'
foreach ($i in 1..3) {
  Write-Output "BFC_$i"
}%%Write-Output after
'@
    check 'foreach 块整体一步' (split_join $si1) $se1

    $si2 = (@('$s = @''', 'heredoc line1', 'heredoc line2', "'@", 'Write-Output after') -join "`n")
    $se2 = (@('$s = @''', 'heredoc line1', 'heredoc line2', "'@") -join "`n") + '%%Write-Output after'
    check 'here-string 整体一步' (split_join $si2) $se2

    $si3 = @'
if (Test-Path x) {
  Write-Output yes
} elseif (Test-Path y) {
  Write-Output maybe
} else {
  Write-Output no
}
Write-Output end
'@
    $se3 = @'
if (Test-Path x) {
  Write-Output yes
} elseif (Test-Path y) {
  Write-Output maybe
} else {
  Write-Output no
}%%Write-Output end
'@
    check 'if/elseif/else 整体一步' (split_join $si3) $se3

    $si4 = @'
Get-ChildItem |
  Sort-Object LastWriteTime
Write-Host `
  continued
Write-Output end
'@
    $se4 = (@('Get-ChildItem |', '  Sort-Object LastWriteTime') -join "`n") + '%%' +
        (@('Write-Host `', '  continued') -join "`n") + '%%Write-Output end'
    check '行尾管道/反引号续行并入' (split_join $si4) $se4

    check '引号内花括号括号不误判' (split_join 'Write-Host "brace } paren ( done"
Write-Output ok') 'Write-Host "brace } paren ( done"%%Write-Output ok'

    check '单行 foreach 不误合' (split_join 'foreach ($i in 1..2) { Write-Output $i }
Write-Output next') 'foreach ($i in 1..2) { Write-Output $i }%%Write-Output next'

    check '未闭合结构并入最后一步' (split_join 'foreach ($x in 1..2) {
  Write-Output $x') 'foreach ($x in 1..2) {
  Write-Output $x'

    check '块注释跨行并入' (split_join '<# 说明
  注释 #>
Write-Output ok') '<# 说明
  注释 #>%%Write-Output ok'

    # 全链路: mock 返回跨行结构，-y 执行验证行为正确
    $r = run_a_stdin 'a -y ''BLOCKFOR 请求'''
    $bfc = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^BFC_[123]$' }) -join ','
    check 'for 循环块整体执行' $bfc 'BFC_1,BFC_2,BFC_3'

    $env:A_HD_TEST = Join-Path $TestTmp 'hd-test.txt'
    Remove-Item -LiteralPath $env:A_HD_TEST -ErrorAction SilentlyContinue
    $null = run_a_stdin 'a -y ''BLOCKHD 请求'''
    $hd = (@(Get-Content -LiteralPath $env:A_HD_TEST -ErrorAction SilentlyContinue) -join "`n")
    check 'here-string 块写入文件完整' $hd "heredoc line1`nheredoc line2"
    Remove-Item -LiteralPath $env:A_HD_TEST -ErrorAction SilentlyContinue
    Remove-Item env:A_HD_TEST -ErrorAction SilentlyContinue

    $r = run_a_stdin 'a -y ''BLOCKMIX 请求'''
    $mx = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^MX_' }) -join ','
    check '循环块与后续步骤顺序执行' $mx 'MX_a,MX_b,MX_TAIL'

    Write-Host "== 5.4 步骤超时（A_STEP_TIMEOUT） =="
    # 直连 harness: 子进程超时、退出码透传、输出捕获、secs=0 原路径
    $tf = _a_mktemp
    Set-Content -LiteralPath $tf -Value '' -NoNewline
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rcT = _a_step_run 1 'Start-Sleep -Seconds 8' $tf
    $el = $sw.Elapsed.TotalSeconds
    check '超时返回 124' $rcT 124
    if ($el -lt 5) { ok ("超时及时终止（{0:N1}s）" -f $el) } else { fail ("超时耗时过长（{0:N1}s）" -f $el) }
    check '子进程 exit 透传' (_a_step_run 5 'exit 7' $tf) 7
    check '原生命令退出码透传' (_a_step_run 5 '$global:LASTEXITCODE = 7' $tf) 7
    check '正常执行返回 0' (_a_step_run 5 'Write-Output TD1' $tf) 0
    check '输出捕获到 out_file' ([System.IO.File]::ReadAllText($tf, $global:_A_UTF8)) 'TD1'
    check 'secs=0 会话内原路径' (_a_step_run 0 'Write-Output TD2' $tf) 0
    check 'secs=0 输出同样捕获' ([System.IO.File]::ReadAllText($tf, $global:_A_UTF8)) "TD1`nTD2"
    Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue

    # 全链路: A_STEP_TIMEOUT=1 下 -y 执行挂起命令 → 124 + 提示；R 消息含超时，下一轮可见
    $env:A_STEP_TIMEOUT = '1'
    $rcT = run_a_rc 'a -y ''TIMEOUT1 请求'' | Out-Null'
    check 'a -y 挂起步骤超时返回 124' $rcT 124
    check_like '超时提示显示（含调整指引）' $script:lastOut '步骤超过 1 秒未完成'
    $out = run_a '$null = a -y ''TIMEOUT1 请求''; a -p ''TIMEOUT2 请求'''
    check '超时情况回传下一轮对话' (lastline $out) 'Write-Output SAW_TIMEOUT'
    # 会话状态命令不受超时看护（瞬时完成，走当前会话分支）
    $tmpd = Join-Path $TestTmp 'cd-timeout'
    New-Item -ItemType Directory -Path $tmpd -Force | Out-Null
    $env:A_TEST_DIR = $tmpd
    $out = run_a '$null = a -y ''CDTEST 请求''; (Get-Location).Path'
    check '会话状态命令不受超时影响' (lastline $out) $tmpd
    Remove-Item env:A_TEST_DIR -ErrorAction SilentlyContinue
    Remove-Item env:A_STEP_TIMEOUT -ErrorAction SilentlyContinue

    Write-Host "== 5.5 工具域与事件日志单测（进程内） =="
    $td = Join-Path $TestTmp 'tools'
    New-Item -ItemType Directory -Path $td -Force | Out-Null
    Push-Location $td
    try {
        $global:_A_AGENT_CWD = $td
        'l1', 'l2', 'l3' | Set-Content -LiteralPath (Join-Path $td 'sample.txt')
        Set-Content -LiteralPath (Join-Path $td 'other.log') 'other'

        check '工具注册表登记 10 个工具' @($global:_A_TOOL_NAMES).Count 10
        $sj = (_a_tools_schemas | ConvertTo-Json -Compress -Depth 8)
        check_like 'tools schema 组包合法且含 pwsh' $sj '"name":"pwsh"'

        check 'read 带行号与续读页脚' (_a_tool_dispatch 'read' '{"file_path":"sample.txt","limit":2}') `
            "1: l1`n2: l2`n(Showing lines 1-2 of 3. Use offset=3 to continue.)"
        check 'read 缺失文件报错' (_a_tool_dispatch 'read' '{"file_path":"no-such.txt"}') 'Error: file not found: no-such.txt'

        check 'write 返回 OK' (_a_tool_dispatch 'write' '{"file_path":"sub/w.txt","content":"line1\nline2\n"}') 'OK: wrote sub/w.txt'
        check 'write 内容精确(含尾部换行)' ([System.IO.File]::ReadAllText((Join-Path $td 'sub/w.txt'))) "line1`nline2`n"

        check 'edit 唯一替换' (_a_tool_dispatch 'edit' '{"file_path":"sample.txt","old_string":"l2","new_string":"L2"}') 'OK: replaced 1 occurrence(s) in sample.txt'
        check 'edit 结果落盘' ((Get-Content -LiteralPath (Join-Path $td 'sample.txt'))[1]) 'L2'
        check_like 'edit 多处未开 replace_all 报错' (_a_tool_dispatch 'edit' '{"file_path":"sample.txt","old_string":"l","new_string":"x"}') 'old_string appears 2 times'
        $null = _a_tool_dispatch 'edit' '{"file_path":"sample.txt","old_string":"l","new_string":"x","replace_all":true}'
        check 'edit replace_all 全替换' ((Get-Content -LiteralPath (Join-Path $td 'sample.txt') -First 1)) 'x1'

        check_like 'grep 命中带行号' (_a_tool_dispatch 'grep' '{"pattern":"L2"}') 'sample.txt:2:'
        check 'grep 无命中提示' (_a_tool_dispatch 'grep' '{"pattern":"nomatchhere"}') '(no matches)'
        check 'grep include 过滤' (_a_tool_dispatch 'grep' '{"pattern":"other","include":"*.log"}') ((Join-Path $td 'other.log') + ':1:other')

        check 'glob 命中文件(mtime 优先)' (_a_tool_dispatch 'glob' '{"pattern":"sample*"}') (Join-Path $td 'sample.txt')

        # macOS 上子进程 Get-Location 会把 /var 解析为 /private/var，用后缀匹配
        check_like 'pwsh 在会话工作目录执行' (_a_tool_dispatch 'pwsh' '{"command":"(Get-Location).Path"}') "/tools`n[exit code: 0]"
        $r = _a_tool_execute 1 'pwsh' '{"command":"exit 7"}'
        check_like 'pwsh 退出码标记' $r '[exit code: 7]'
        $r = _a_tool_execute 1 'pwsh' '{"command":"Write-Output (\"A\" * 6000)"}'
        check_like 'pwsh 超长输出截尾(管线 post-execute)' $r 'output truncated, showing last 4000'

        $env:A_STEP_TIMEOUT = '1'
        $r = _a_tool_dispatch 'pwsh' '{"command":"Start-Sleep -Seconds 5"}'
        check_like 'pwsh 超时标记与 124' $r 'timed out after 1 seconds'
        check_like 'pwsh 超时退出码' $r '[exit code: 124]'
        Remove-Item env:A_STEP_TIMEOUT -ErrorAction SilentlyContinue

        check 'working_directory 切换(返回绝对路径)' (_a_tool_dispatch 'working_directory' '{"cd":"sub"}') "working directory set to: $(Join-Path $td 'sub')"

        $r = _a_tool_dispatch 'todo_write' '{"todos":[{"content":"t1","status":"completed"},{"content":"t2","status":"in_progress"}]}' 6>$null
        check 'todo 计数回执' $r 'Updated todo list: 0 pending, 1 in progress, 1 completed.'
        $r = _a_tool_dispatch 'todo_write' '{"todos":[{"content":"a","status":"in_progress"},{"content":"b","status":"in_progress"}]}' 6>$null
        check 'todo 多个 in_progress 报错' $r 'Error: at most one todo may be in_progress (got 2)'

        $r = _a_tool_dispatch 'ask_user_question' '{"questions":[{"id":"q1","question":"选哪个?","options":[{"label":"A"},{"label":"B"}]}]}' 6>$null
        if ([Console]::IsInputRedirected) {
            check 'ask_user 无终端返回跳过语义' $r '{"answers":[{"id":"q1","selected":[],"custom":"(skipped: no terminal available)"}]}'
        } else {
            Write-Host '  （交互终端下跳过 ask_user 无终端分支）'
        }

        check '未知工具报错' (_a_tool_execute 1 'nosuch' '{}') 'Error: unknown tool: nosuch'

        # 事件日志: append → derive 投影
        _a_ev_clear t
        _a_ev_append t 'U' '{"role":"user","content":"任务: A"}'
        _a_ev_append t 'A' '{"role":"assistant","content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"pwsh","arguments":"{}"}}]}'
        _a_ev_append t 'T' '{"role":"tool","tool_call_id":"c1","content":"r1"}'
        $m = _a_ev_derive t
        check 'derive 投影消息形状(含 tool_calls 原样回放)' "$(@($m).Count) $($m[1].tool_calls[0].id) $($m[2].tool_call_id) $($m[2].content)" '3 c1 c1 r1'

        $env:A_MAX_CONTEXT_CHARS = '120'
        _a_ev_clear t
        foreach ($i in 1..5) {
            _a_ev_append t 'U' ('{"role":"user","content":"任务: U' + $i + ' PADPADPADPADPADPAD"}')
            _a_ev_append t 'A' ('{"role":"assistant","content":"回答' + $i + ' PADPADPADPADPADPAD"}')
        }
        $m2 = _a_ev_derive t
        check '超预算按完整轮裁剪' "$(@($m2).Count) $($m2[0].content.Split(' ')[1]) $($m2[-1].content.Split(' ')[0])" '2 U5 回答5'
        Remove-Item env:A_MAX_CONTEXT_CHARS -ErrorAction SilentlyContinue
    } finally {
        Pop-Location
    }

    # 管线拒绝路径(子进程 stdin 重定向 → 无终端分支)
    $declPath = (Join-Path $td 'declined.txt') -replace '\\', '/'
    $r = run_a_stdin ("_a_tool_execute 0 'write' '{`"file_path`":`"$declPath`",`"content`":`"x`"}'")
    check '无终端时写文件被拒并回传文本' (lastline $r.Out) '[user declined this tool call]'
    if (Test-Path (Join-Path $td 'declined.txt')) { fail '被拒调用未落盘' } else { ok '被拒调用未落盘' }

    Write-Host "== 5.6 agent 模式全链路（mock） =="
    $env:A_STEP_TIMEOUT = '30'
    $r = run_a_stdin "a agent 'AGENTLOOP 测试'"
    check 'agent 多步工具循环到最终回答' "$($r.Rc) - $(lastline $r.Out)" '0 - AGENT_DONE'
    check_like 'agent 工具输出实时展示' $r.Out 'AGENT_STEP1'

    $r = run_a_stdin "a agent 'AGENTSHEMA 校验'"
    check '请求携带 10 工具(含 pwsh)/tool_choice=auto/非流式' "$($r.Rc) - $(lastline $r.Out)" '0 - SCHEMA_OK'

    $out = run_a "a agent 'AGENTLOOP 测试' | Out-Null; a agent 'AGENTCTX 续聊'"
    check 'agent 会话多轮续接（事件日志携带上轮）' (lastline $out) 'CTX_SEEN'

    $out = run_a "a agent 'AGENTCTX 测试' | Out-Null; a --show"
    check_like '--show 渲染 agent 事件视图' $out '[agent]'
    check_like '--show 展示 agent 轮次' $out '轮 1'

    $out = run_a "a agent 'AGENTLOOP 测试' | Out-Null; a -c; a agent 'AGENTCTX 测试'"
    check 'a -c 清空 agent 事件日志' (lastline $out) 'CTX_MISSING'

    $r = run_a_stdin "a agent 'AGENTDANGER 测试'"
    check '无终端时高危工具调用被拒且循环继续' "$($r.Rc) - $(lastline $r.Out)" '0 - DANGER_HANDLED'
    check_like '拒绝提示展示' $r.Out '已拒绝本次工具调用'

    $r = run_a_stdin "a agent 'AGENTASK 测试'"
    check 'ask_user 无终端跳过后循环继续' "$($r.Rc) - $(lastline $r.Out)" '0 - ASK_HANDLED'

    $r = run_a_stdin "a agent 'AGENTTODO 测试'"
    check 'todo_write 全链路' "$($r.Rc) - $(lastline $r.Out)" '0 - TODO_HANDLED'
    check_like 'todo 清单渲染' $r.Out '任务清单'

    $wy = Join-Path $agentTmp 'a-agent-write-y.txt'
    $wn = Join-Path $agentTmp 'a-agent-write-n.txt'
    Remove-Item $wy, $wn -ErrorAction SilentlyContinue
    $r = run_a_stdin "a -y agent 'AGENTWRITE 测试'"
    check '-y 写文件自动放行并完成' "$($r.Rc) - $(lastline $r.Out) - $([System.IO.File]::ReadAllText($wy))" '0 - WRITE_HANDLED - written-by-agent'

    $r = run_a_stdin "a agent 'AGENTDECLINE 测试'"
    check '无终端写文件被拒、拒因回传模型' "$($r.Rc) - $(lastline $r.Out)" '0 - DECLINE_HANDLED'
    if (Test-Path $wn) { fail '被拒写调用未落盘' } else { ok '被拒写调用未落盘' }

    $env:A_AGENT_MAX_STEPS = '2'
    $r = run_a_stdin "a agent 'AGENTLOOPFOREVER 测试'"
    check '步数上限熔断' "$($r.Rc) - $(@($r.Out -split "`n" | Where-Object { $_ -match '步数上限' }).Count)" '1 - 1'
    Remove-Item env:A_AGENT_MAX_STEPS -ErrorAction SilentlyContinue

    $r = run_a_stdin "a agent 'AGENTRETRY 测试'"
    check 'agent 请求 429 自动重试(整包模式)' "$($r.Rc) - $(lastline $r.Out)" '0 - RETRY_OK'

    $rc = run_a_rc "a -p agent '某任务'"
    check 'agent 不支持 -p' $rc 2
    Remove-Item env:A_STEP_TIMEOUT -ErrorAction SilentlyContinue

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
    check '异地 cwd 绝对路径加载' (lastline $out) 'agent-cli-bash 0.6.0'
    $out = & pwsh -NoProfile -Command "Set-Location '$RepoDir'; . ./a.ps1; a --version" 2>&1
    check '相对路径 dot-source 加载' (lastline $out) 'agent-cli-bash 0.6.0'

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
