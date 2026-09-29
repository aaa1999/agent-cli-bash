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
            if "MOCK_ECHO_CWD" in last_user:
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
grep -q "DEEPSEEK_API_KEY=" "$TMPHOME/.config/agent-cli-bash/config" \
    && ok "生成配置模板" || fail "生成配置模板"
(
    cd "$REPO_DIR"
    HOME="$TMPHOME" SHELL=/bin/zsh bash install.sh --uninstall >/dev/null
)
grep -q "agent-cli-bash" "$TMPHOME/.zshrc" && fail "卸载残留" || ok "卸载干净"
rm -rf "$TMPHOME"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[[ $FAIL -eq 0 ]]
