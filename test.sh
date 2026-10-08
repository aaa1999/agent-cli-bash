#!/usr/bin/env bash
# agent-cli-bash 本地测试：用 mock HTTP 服务模拟 DeepSeek API，不访问外网。
# 用法: bash test.sh

set -u
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ✔ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✘ $1"; }
check() { # check <描述> <实际> <期望>
    if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1 (期望: $3, 实际: $2)"; fi
}

echo "== 1. JSON 转义 =="
esc=$(ESC_INPUT='a"b\c' zsh -c "source '$REPO_DIR/a.sh'; "'_a_json_escape "$ESC_INPUT"' 2>/dev/null)
check "反斜杠与引号转义" "$esc" 'a\"b\\c'

echo "== 2. 围栏清理 =="
clean=$(FENCE_INPUT=$'```bash\necho hi\n```' zsh -c "source '$REPO_DIR/a.sh'; "'_a_clean "$FENCE_INPUT"' 2>/dev/null)
check "去掉 \`\`\`bash 围栏" "$clean" "echo hi"

echo "== 3. mock API 全链路 =="
# 起 mock 服务：普通请求返回带围栏的命令；包含 AUTHFAIL 的请求返回 401
MOCK_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - "$MOCK_PORT" <<'PYEOF' &
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
                cmd = "echo RETRY_OK"
            elif "MOCK_ECHO_CWD" in last_user:
                cmd = "echo CWD_WAS_SENT"
            elif "RC7" in last_user:
                cmd = "(exit 7)"
            elif "MULTI" in last_user:
                cmd = "echo STEP_A\necho STEP_B\necho STEP_C"
            elif "DANGEROUS" in last_user:
                cmd = "sudo rm -rf /tmp/a-bad-demo"
            elif "PIPE_DATA_MARKER" in last_user:
                cmd = "echo PIPE_SEEN"
            elif "PIPE2_MARKER" in last_user:
                cmd = "echo PIPE2_SEEN"
            elif "CDTEST" in last_user:
                cmd = "cd /tmp"
            elif "VARTEST" in last_user:
                cmd = "export A_TEST_VAR=shell_state_ok"
            elif "PROVIDER" in last_user:
                cmd = "echo PROVIDER_MODEL_OK" if body.get("model") == "kimi-k2-0905-preview" else "echo MODEL_WRONG"
            elif "PWDCTX" in last_user:
                want_git = "NOGIT" not in last_user
                ok = ("当前目录:" in allc) and ("目录内容" in allc) and (("git:" in allc) == want_git)
                cmd = "echo ENVCTX_OK" if ok else "echo ENVCTX_MISSING"
            elif "DIRCTX" in last_user:
                ok = ("linuxmint-22.3-cinnamon-64bit-hwe-7.0.iso" in last_user
                      and "共 22 项" in last_user and "仅列 15 项" in last_user)
                cmd = "echo DIRCTX_OK" if ok else "echo DIRCTX_MISS"
            elif "ASKFLOW" in allc:
                if "补充:" in last_user and "ANSWER42" in last_user:
                    cmd = "echo ASKFLOW_DONE"
                else:
                    cmd = "ASK: 目录里有多个候选文件，要处理哪一个？（回答里包含 ANSWER42 即可通过）"
            elif "ASKLOOP" in allc:
                cmd = "ASK: 还是没看懂，能再说详细一点吗？"
            elif "TRIM0" in last_user:
                cmd = "echo PAD_OLD_" + "P" * 300
            elif "TRIM1" in last_user:
                cmd = "echo PAD_MID_" + "M" * 300
            elif "TRIM2" in last_user:
                # 判断第一轮的"请求"消息是否还在上下文里（命令文本会经 shell 历史回流，不可作判据）
                cmd = "echo CTX_NOT_TRIMMED" if "TRIM0 请求" in allc else "echo CTX_TRIMMED_OK"
            elif "FEEDBACK1" in last_user:
                cmd = "echo HELLO_FE"
            elif "FEEDBACK2" in last_user:
                cmd = "echo SEEN_RESULT" if "HELLO_FE" in allc else "echo NOT_SEEN"
            elif "FIRST" in last_user:
                cmd = "echo FIRST_MARKER_CMD"
            elif "SECOND" in last_user:
                cmd = "echo CTX_OK" if "FIRST_MARKER_CMD" in allc else "echo SECOND_NO_CTX"
            else:
                cmd = 'echo "mock 命令 <fence>"'
            full = "```bash\n" + cmd + "\n```"
            # SSE 流式：按 5 字节小块发送（块尾常为换行），验证增量拼接不丢换行
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
PYEOF
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null' EXIT
sleep 1
URL="http://127.0.0.1:$MOCK_PORT"

run_a() { # run_a <shell> <args...>
    local sh=$1; shift
    env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" \
        "$sh" -c "source '$REPO_DIR/a.sh'; a $*" 2>/dev/null
}

out=$(run_a zsh "-p '随便来个命令'")
check "zsh -p 提取命令并去围栏" "$out" 'echo "mock 命令 <fence>"'

out=$(run_a bash "-p '随便来个命令'")
check "bash -p 提取命令并去围栏" "$out" 'echo "mock 命令 <fence>"'

out=$(run_a zsh "-y 'MOCK_ECHO_CWD'")
check "zsh -y 执行返回命令" "$out" "CWD_WAS_SENT"

out=$(run_a bash "-y 'MOCK_ECHO_CWD'")
check "bash -y 执行返回命令" "$out" "CWD_WAS_SENT"

echo "== 3.1 管道输入 =="
out=$(printf 'ERROR: PIPE_DATA_MARKER boom\n' | run_a zsh "-p '解释这个报错'")
check "管道内容作为上下文发送" "$out" "echo PIPE_SEEN"

out=$(printf 'PIPE2_MARKER 数据\n' | run_a zsh "-p")
check "管道输入可省略文字描述" "$out" "echo PIPE2_SEEN"

echo "== 3.2 shell 状态命令在当前 shell 生效 =="
out=$(run_a zsh "-y 'CDTEST'; pwd")
check "zsh: cd 在当前 shell 生效" "$out" "/tmp"

out=$(run_a bash "-y 'CDTEST'; pwd")
check "bash: cd 在当前 shell 生效" "$out" "/tmp"

out=$(run_a zsh "-y 'VARTEST'; "'echo $A_TEST_VAR')
check "zsh: export 变量生效" "$out" "shell_state_ok"

out=$(run_a bash "-y 'VARTEST'; "'echo $A_TEST_VAR')
check "bash: export 变量生效" "$out" "shell_state_ok"

echo "== 3.3 自动重试 =="
out=$(run_a zsh "-p 'RETRYME 请求'")
check "503 后自动重试成功" "$out" "echo RETRY_OK"

rc=0
out=$(env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" A_MAX_RETRIES=1 \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'RATELIMIT 请求'" 2>&1) || rc=$?
check "429 重试耗尽后报错" "$rc - $(printf '%s' "$out" | grep -c '已自动重试 1 次')" "1 - 1"
if printf '%s' "$out" | grep -q 'Insufficient Balance'; then
    ok "重试耗尽保留原始错误详情"
else
    fail "重试耗尽保留原始错误详情"
fi

rc=0
out=$(env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" A_MAX_RETRIES=0 \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'RATELIMIT 请求'" 2>&1) || rc=$?
check "A_MAX_RETRIES=0 禁用重试" "$rc - $(printf '%s' "$out" | grep -c '已自动重试')" "1 - 0"

echo "== 3.4 上下文管理 =="
out=$(env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" A_MAX_CONTEXT_CHARS=300 \
    zsh -c "source '$REPO_DIR/a.sh'; a -y 'TRIM0 请求' >/dev/null 2>&1; a -y 'TRIM1 请求' >/dev/null 2>&1; a -p 'TRIM2 请求'" 2>/dev/null)
if printf '%s' "$out" | grep -q CTX_TRIMMED_OK; then
    ok "超预算时裁掉最旧的轮"
else
    fail "超预算时裁掉最旧的轮 (实际: $out)"
fi

out=$(run_a zsh "-p 'SHOW1 请求'; a --show")
if printf '%s' "$out" | grep -q '轮 1.*SHOW1' && printf '%s' "$out" | grep -q '下一轮将发送'; then
    ok "--show 展示轮次与体积"
else
    fail "--show 展示轮次与体积 (实际: $out)"
fi

out=$(printf '' | run_a zsh "--show")
check "--show 空上下文提示" "$out" "（当前会话暂无对话上下文）"

echo "== 3.5 多提供商 =="
out=$(env A_PROVIDER=kimi A_API_KEY=sk-k A_BASE_URL="$URL" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'PROVIDER 测试'" 2>/dev/null)
check "A_PROVIDER=kimi 使用默认模型" "$out" "echo PROVIDER_MODEL_OK"

rc=0
out=$(env A_PROVIDER=openai OPENAI_API_KEY=sk-o A_BASE_URL="$URL" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p '随便'" 2>/dev/null) || rc=$?
check "自动读取 OPENAI_API_KEY" "$rc - ${out:+ok}" "0 - ok"

rc=0
out=$(env A_PROVIDER=nosuch A_API_KEY=sk-x \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'hi'" 2>&1) || rc=$?
check "未知提供商报错" "$rc - $(printf '%s' "$out" | grep -c '未知提供商')" "1 - 1"

rc=0
out=$(env -u DEEPSEEK_API_KEY A_CONFIG_FILE=/nonexistent A_PROVIDER=ollama A_BASE_URL="$URL" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p '随便'" 2>/dev/null) || rc=$?
check "ollama 无密钥可用" "$rc - ${out:+ok}" "0 - ok"

out=$(printf '' | run_a zsh "providers")
if printf '%s' "$out" | grep -q openai && printf '%s' "$out" | grep -q kimi; then
    ok "providers 列表输出"
else
    fail "providers 列表输出 (实际: $out)"
fi

echo "== 3.6 配置文件解析 =="
cfg=$(mktemp "${TMPDIR:-/tmp}/a-cfg.XXXXXX")
printf 'A_PROVIDER=kimi\nA_API_KEY=sk-k\nA_BASE_URL=%s\n' "$URL" > "$cfg"
rc=0
out=$(env -u DEEPSEEK_API_KEY -u A_MAX_RETRIES A_CONFIG_FILE="$cfg" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'PROVIDER 测试'" 2>/dev/null) || rc=$?
check "config 文件配置提供商/密钥/地址" "$rc - $out" "0 - echo PROVIDER_MODEL_OK"

printf 'A_API_KEY=sk-test\nA_BASE_URL=%s\nA_MAX_RETRIES=0\n' "$URL" > "$cfg"
rc=0
out=$(env -u DEEPSEEK_API_KEY -u A_MAX_RETRIES A_CONFIG_FILE="$cfg" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'RATELIMIT 请求'" 2>&1) || rc=$?
check "config 文件中 A_MAX_RETRIES=0 禁用重试" "$rc - $(printf '%s' "$out" | grep -c '已自动重试')" "1 - 0"

chmod 644 "$cfg"
env -u DEEPSEEK_API_KEY -u A_MAX_RETRIES A_CONFIG_FILE="$cfg" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p '随便'" >/dev/null 2>&1
check "加载时自动收紧配置权限为 600" "$(ls -l "$cfg" | awk '{print $1}' | sed 's/[@+]$//')" "-rw-------"
rm -f "$cfg"

echo "== 3.7 环境上下文 =="
out=$(cd "$REPO_DIR" && env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'PWDCTX 请求'" 2>/dev/null)
check "携带当前目录/git 状态/目录条目" "$out" "echo ENVCTX_OK"

tmpd=$(mktemp -d)
touch "$tmpd/a-file.txt"
out=$(cd "$tmpd" && env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'PWDCTX NOGIT 请求'" 2>/dev/null)
check "非 git 目录不携带 git 行" "$out" "echo ENVCTX_OK"
rm -rf "$tmpd"

echo "== 3.7.1 目录条目智能选取 =="
tmpd=$(mktemp -d)
# 20 个字母序靠前的旧文件 + 目标 iso（口语"linuxiso"应命中）+ 最新的无关文件
for i in $(seq -w 1 20); do touch -t 202001010000 "$tmpd/aaa-$i.txt"; done
touch -t 202401010000 "$tmpd/linuxmint-22.3-cinnamon-64bit-hwe-7.0.iso"
touch "$tmpd/zz-new.txt"

out=$(cd "$tmpd" && zsh -c "source '$REPO_DIR/a.sh'; _a_env_context '计算linuxiso的sha256'" 2>/dev/null)
if printf '%s\n' "$out" | grep -q '^linuxmint-22.3-cinnamon-64bit-hwe-7.0.iso$'; then
    ok "口语缩写命中目标文件（字母序截断下不可见）"
else
    fail "口语缩写命中目标文件 (实际: $out)"
fi
if printf '%s\n' "$out" | grep -q '共 22 项'; then
    ok "表头注明总条目数"
else
    fail "表头注明总条目数 (实际: $out)"
fi
check "只列 15 项" "$(printf '%s\n' "$out" | grep -cE '^(aaa-|linuxmint|zz-new)')" "15"
check "命中条目排在首位" "$(printf '%s\n' "$out" | grep -E '^(aaa-|linuxmint|zz-new)' | head -1)" \
    "linuxmint-22.3-cinnamon-64bit-hwe-7.0.iso"

out=$(cd "$tmpd" && bash -c "source '$REPO_DIR/a.sh'; _a_env_context '计算linuxiso的sha256'" 2>/dev/null)
if printf '%s\n' "$out" | grep -q '^linuxmint-22.3-cinnamon-64bit-hwe-7.0.iso$'; then
    ok "bash 下同样命中"
else
    fail "bash 下同样命中 (实际: $out)"
fi

out=$(cd "$tmpd" && zsh -c "source '$REPO_DIR/a.sh'; _a_env_context '看看最新下载的东西'" 2>/dev/null)
check "无词元查询按修改时间补足（最新在前）" \
    "$(printf '%s\n' "$out" | grep -E '^(aaa-|linuxmint|zz-new)' | head -1)" "zz-new.txt"

out=$(cd "$tmpd" && A_DIR_ENTRIES=5 zsh -c "source '$REPO_DIR/a.sh'; _a_env_context '算linuxiso的'" 2>/dev/null)
check "A_DIR_ENTRIES=5 只列 5 项" "$(printf '%s\n' "$out" | grep -cE '^(aaa-|linuxmint|zz-new)')" "5"
out=$(cd "$tmpd" && A_DIR_ENTRIES=0 zsh -c "source '$REPO_DIR/a.sh'; _a_env_context '随便'" 2>/dev/null)
check "A_DIR_ENTRIES=0 不注入目录内容" "$(printf '%s\n' "$out" | grep -c '目录内容')" "0"

out=$(cd "$tmpd" && env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'DIRCTX 计算linuxiso的sha256'" 2>/dev/null)
check "e2e: 发送的消息携带目标文件而非字母序截断" "$out" "echo DIRCTX_OK"
rm -rf "$tmpd"

echo "== 3.7.2 ASK 反问与补充 =="
export DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL"
rc=0
out=$(zsh -c "source '$REPO_DIR/a.sh'; a -y 'ASKFLOW 请求'" </dev/null 2>&1) || rc=$?
check "无终端时 ASK 取消并提示" "$rc - $(printf '%s' "$out" | grep -c '无终端可交互')" "1 - 1"

if command -v expect >/dev/null 2>&1; then
    out=$(A_TEST_CMD="source '$REPO_DIR/a.sh'; a -y 'ASKFLOW 请求'" expect -c '
        set timeout 8
        spawn zsh -c $env(A_TEST_CMD)
        expect "补充信息"
        send "ANSWER42\r"
        expect eof
    ' 2>/dev/null)
    if printf '%s' "$out" | tr -d '\r' | grep -q '^ASKFLOW_DONE$'; then
        ok "ASK 补充后同轮重新生成并执行"
    else
        fail "ASK 补充后同轮重新生成并执行 (实际: $out)"
    fi

    rc=0
    A_TEST_CMD="source '$REPO_DIR/a.sh'; a -y 'ASKFLOW 请求'" expect -c '
        set timeout 8
        spawn zsh -c $env(A_TEST_CMD)
        expect "补充信息"
        send "\r"
        expect eof
        catch wait w
        exit [lindex $w 3]
    ' >/dev/null 2>&1 || rc=$?
    check "空回答取消返回 1" "$rc" "1"

    rc=0
    out=$(A_TEST_CMD="source '$REPO_DIR/a.sh'; a -y 'ASKLOOP 请求'" expect -c '
        set timeout 8
        spawn zsh -c $env(A_TEST_CMD)
        expect "补充信息"
        send "x1\r"
        expect "补充信息"
        send "x2\r"
        expect "补充信息"
        send "x3\r"
        expect eof
        catch wait w
        exit [lindex $w 3]
    ' 2>/dev/null) || rc=$?
    check "连续追问达上限返回 1" "$rc - $(printf '%s' "$out" | grep -c '上限')" "1 - 1"
else
    echo "  （未安装 expect，跳过 ASK 交互测试）"
fi

echo "== 3.8 a setup 配置向导 =="
mask=$(zsh -c "source '$REPO_DIR/a.sh'; _a_mask_key sk-abcdefgh1234" 2>/dev/null)
check "密钥掩码保留首尾" "$mask" "sk-a***1234"
mask=$(zsh -c "source '$REPO_DIR/a.sh'; _a_mask_key short" 2>/dev/null)
check "短密钥全遮" "$mask" "***"

cfgm=$(mktemp "${TMPDIR:-/tmp}/a-setup.XXXXXX")
printf '# 注释行\nA_PROVIDER=deepseek\nA_MAX_RETRIES=5\n' > "$cfgm"
zsh -c "source '$REPO_DIR/a.sh'; A_CONFIG_FILE='$cfgm' _a_config_merge A_PROVIDER=kimi A_API_KEY=sk-xyz9876543210" >/dev/null 2>&1
check "merge 原位替换提供商" "$(grep '^A_PROVIDER=' "$cfgm")" "A_PROVIDER=kimi"
check "merge 追加密钥" "$(grep '^A_API_KEY=' "$cfgm")" "A_API_KEY=sk-xyz9876543210"
check "merge 保留其他配置" "$(grep '^A_MAX_RETRIES=' "$cfgm")" "A_MAX_RETRIES=5"
grep -q '^# 注释行' "$cfgm" && ok "merge 保留注释" || fail "merge 保留注释"
check "merge 后权限 600" "$(ls -l "$cfgm" | awk '{print $1}' | sed 's/[@+]$//')" "-rw-------"
rm -f "$cfgm"

if command -v expect >/dev/null 2>&1; then
    tmpd2=$(mktemp -d "${TMPDIR:-/tmp}/a-setup.XXXXXX")
    cfgw=$tmpd2/config
    A_TEST_CMD="source '$REPO_DIR/a.sh'; A_CONFIG_FILE='$cfgw' a setup" expect -c '
        set timeout 8
        spawn zsh -c $env(A_TEST_CMD)
        expect "选择提供商"
        send "2\r"
        expect "粘贴 API 密钥"
        send "sk-setup-111122223333\r"
        expect "已写入"
        expect eof
    ' >/dev/null 2>&1
    check "向导写入提供商(openai)" "$(grep '^A_PROVIDER=' "$cfgw" 2>/dev/null)" "A_PROVIDER=openai"
    check "向导写入密钥" "$(grep '^A_API_KEY=' "$cfgw" 2>/dev/null)" "A_API_KEY=sk-setup-111122223333"
    check "向导后权限 600" "$(ls -l "$cfgw" 2>/dev/null | awk '{print $1}' | sed 's/[@+]$//')" "-rw-------"
    rm -rf "$tmpd2"
fi

echo "== 4. 错误路径 =="
rc=0
out=$(env DEEPSEEK_API_KEY=sk-BADKEY DEEPSEEK_BASE_URL="$URL" \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'hi'" 2>&1) || rc=$?
check "401 时报错且含 API 信息" "$rc - ${out#*: }" "1 - API 错误: Authentication Fails (no such user)"

rc=0
out=$(env -u DEEPSEEK_API_KEY A_CONFIG_FILE=/nonexistent \
    zsh -c "source '$REPO_DIR/a.sh'; a -p 'hi'" 2>&1) || rc=$?
check "无密钥时报错" "$rc" "1"

echo "== 5. 多轮会话与上下文 =="
out=$(run_a zsh "-p 'FIRST 请求'; a -p 'SECOND 请求'")
check "zsh 同会话第二轮携带第一轮上下文" "$out" $'echo FIRST_MARKER_CMD\necho CTX_OK'

out=$(run_a bash "-p 'FIRST 请求'; a -p 'SECOND 请求'")
check "bash 同会话第二轮携带第一轮上下文" "$out" $'echo FIRST_MARKER_CMD\necho CTX_OK'

out=$(run_a zsh "-y 'FEEDBACK1 请求'; a -p 'FEEDBACK2 请求'")
check "执行结果回传到下一轮对话" "$out" $'HELLO_FE\necho SEEN_RESULT'

out=$(run_a zsh "-p 'FIRST 请求'; a -c; a -p 'SECOND 请求'")
check "a -c 清空会话上下文" "$out" $'echo FIRST_MARKER_CMD\necho SECOND_NO_CTX'

rc=0
env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" \
    zsh -c "source '$REPO_DIR/a.sh'; a -y 'RC7 请求'" >/dev/null 2>&1 || rc=$?
check "zsh -y 透传命令退出码" "$rc" "7"

rc=0
env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" \
    bash -c "source '$REPO_DIR/a.sh'; a -y 'RC7 请求'" >/dev/null 2>&1 || rc=$?
check "bash -y 透传命令退出码" "$rc" "7"

echo "== 5.1 多步逐行确认（伪终端） =="
if command -v expect >/dev/null 2>&1; then
    ask_tty() { # ask_tty <答案序列> <完整命令>：在伪终端中运行，stdout 为全部输出，退出码透传
        A_TEST_CMD="$2" A_TEST_SEQ="$1" expect -c '
            set seq $env(A_TEST_SEQ)
            set timeout 8
            spawn zsh -c $env(A_TEST_CMD)
            foreach ans [split $seq ""] {
                expect {
                    -re {\[y=} { send "$ans\r" }
                    eof { exit 0 }
                    timeout { exit 9 }
                }
            }
            expect eof
            catch wait w
            exit [lindex $w 3]
        ' 2>/dev/null
    }
    export DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL"

    steps_of() { printf '%s' "$1" | tr -d '\r' | grep -E '^(STEP_A|STEP_B|STEP_C)$' | paste -sd, -; }

    out=$(ask_tty yyy "source '$REPO_DIR/a.sh'; a 'MULTI 请求'")
    check "三步全 y 全部执行" "$(steps_of "$out")" "STEP_A,STEP_B,STEP_C"

    out=$(ask_tty yn "source '$REPO_DIR/a.sh'; a 'MULTI 请求'")
    check "第 2 步按 n 终止剩余" "$(steps_of "$out")" "STEP_A"

    out=$(ask_tty yiy "source '$REPO_DIR/a.sh'; a 'MULTI 请求'")
    check "第 2 步按 i 跳过后继续" "$(steps_of "$out")" "STEP_A,STEP_C"

    rc=0
    ask_tty n "source '$REPO_DIR/a.sh'; a 'MULTI 请求'" >/dev/null 2>&1 || rc=$?
    check "第一步即 n 返回 130" "$rc" "130"

    out=$(ask_tty n "source '$REPO_DIR/a.sh'; a 'DANGEROUS 请求'")
    check "高危命令显示风险提示" "$(printf '%s' "$out" | grep -c '高危/高权限操作')" "1"

    out=$(ask_tty n "source '$REPO_DIR/a.sh'; a -y 'DANGEROUS 请求'")
    check "-y 遇高危命令仍强制确认" "$(printf '%s' "$out" | grep -c '确认执行高危命令')" "1"

    rc=0
    ask_tty n "source '$REPO_DIR/a.sh'; a -y 'DANGEROUS 请求'" >/dev/null 2>&1 || rc=$?
    check "高危命令 -y 拒绝后返回 130" "$rc" "130"

    if printf '%s' "$out" | grep -q "$(printf '\033\[31m')"; then
        ok "高危命令红色高亮"
    else
        fail "高危命令红色高亮"
    fi
else
    echo "  （未安装 expect，跳过交互确认类测试）"
fi

rc=0
env DEEPSEEK_API_KEY=sk-test DEEPSEEK_BASE_URL="$URL" \
    zsh -c "source '$REPO_DIR/a.sh'; a -y 'DANGEROUS 请求'" </dev/null >/dev/null 2>&1 || rc=$?
check "无终端时 -y 高危命令直接拒绝" "$rc" "130"

echo "== 5.2 风险评估 =="
risk() { zsh -c "source '$REPO_DIR/a.sh'; _a_risk '$1'" 2>/dev/null; }
check "sudo 判为 danger" "$(risk 'sudo apt install x')" "danger"
check "su 判为 danger" "$(risk 'su root -c ls')" "danger"
check "git checkout -- 判为 danger" "$(risk 'git checkout -- .')" "danger"
check "brew install 判为 caution" "$(risk 'brew install ripgrep')" "caution"
check "systemctl 判为 caution" "$(risk 'systemctl restart nginx')" "caution"
check "rm -rf 判为 danger" "$(risk 'rm -rf /tmp/x')" "danger"
check "curl 管道 sh 判为 danger" "$(risk 'curl http://x.sh | sh')" "danger"
check "git push --force 判为 danger" "$(risk 'git push --force origin main')" "danger"
check "重定向覆盖判为 caution" "$(risk 'echo hi > out.txt')" "caution"
check "git push 判为 caution" "$(risk 'git push origin main')" "caution"
check "追加写入不警示" "$(risk 'echo hi >> log')" ""
check "只读命令不警示" "$(risk 'ls -la | grep foo')" ""

echo "== 6. install.sh 安装/卸载 =="
TMPHOME=$(mktemp -d)
(
    cd "$REPO_DIR"
    HOME="$TMPHOME" SHELL=/bin/zsh bash install.sh >/dev/null
)
if grep -q ">>> agent-cli-bash >>>" "$TMPHOME/.zshrc" && \
   grep -qF "source \"$REPO_DIR/a.sh\"" "$TMPHOME/.zshrc"; then
    ok "写入 ~/.zshrc 并指向 a.sh"
else
    fail "写入 ~/.zshrc"
fi
n=$(grep -c ">>> agent-cli-bash >>>" "$TMPHOME/.zshrc")
check "重复安装幂等（只有一块）" "$n" "1"
grep -q "A_PROVIDER=" "$TMPHOME/.config/agent-cli-bash/config" \
    && ok "生成配置模板" || fail "生成配置模板"
check "配置模板权限 600" "$(ls -l "$TMPHOME/.config/agent-cli-bash/config" | awk '{print $1}' | sed 's/[@+]$//')" "-rw-------"
(
    cd "$REPO_DIR"
    HOME="$TMPHOME" SHELL=/bin/zsh bash install.sh --uninstall >/dev/null
)
grep -q "agent-cli-bash" "$TMPHOME/.zshrc" && fail "卸载残留" || ok "卸载干净"
rm -rf "$TMPHOME"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[[ $FAIL -eq 0 ]]
