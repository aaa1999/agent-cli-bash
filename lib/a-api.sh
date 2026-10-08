# a-api.sh —— L1 传输域（harness 最底层）
# 提供商表、配置读写、JSON 工具与 SSE 流式请求客户端。
# 本层不知道会话与模式的存在: _a_generate 只接收 messages JSON、返回内容。
# 由 a.sh 在加载时 source，不单独使用。

# 内置提供商: 名称|默认 base URL|默认模型|API key 环境变量
# 只要是 OpenAI /chat/completions 兼容的网关都能用 A_BASE_URL + A_MODEL 接入
_A_PROVIDERS='
deepseek|https://api.deepseek.com|deepseek-chat|DEEPSEEK_API_KEY
openai|https://api.openai.com/v1|gpt-4o-mini|OPENAI_API_KEY
kimi|https://api.moonshot.cn/v1|kimi-k2-0905-preview|MOONSHOT_API_KEY
qwen|https://dashscope.aliyuncs.com/compatible-mode/v1|qwen-plus|DASHSCOPE_API_KEY
zhipu|https://open.bigmodel.cn/api/paas/v4|glm-4-flash|ZHIPU_API_KEY
grok|https://api.x.ai/v1|grok-3-mini|XAI_API_KEY
ollama|http://localhost:11434/v1|qwen3:8b|OLLAMA_API_KEY
openrouter|https://openrouter.ai/api/v1|openai/gpt-4o-mini|OPENROUTER_API_KEY
'

# 取提供商表字段: _a_provider_field <name> <字段号 2=URL 3=模型 4=key变量>
_a_provider_field() {
    printf '%s\n' "$_A_PROVIDERS" | awk -F'|' -v p="$1" -v f="$2" '$1 == p { print $f; exit }'
}

_a_list_providers() {
    printf '%-11s %-50s %-22s %s\n' "PROVIDER" "DEFAULT BASE URL" "DEFAULT MODEL" "KEY ENV"
    printf '%s\n' "$_A_PROVIDERS" | awk -F'|' 'NF > 1 { printf "%-11s %-50s %-22s %s\n", $1, $2, $3, $4 }'
}

# 读取配置文件，仅填充尚未设置的环境变量
_a_load_config() {
    local f=${A_CONFIG_FILE:-$HOME/.config/agent-cli-bash/config}
    [[ -r $f ]] || return 0
    local line key val
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == \#* || $line != *=* ]] && continue
        key=${line%%=*}
        val=${line#*=}
        case $val in
            \"*\") val=${val#\"}; val=${val%\"} ;;
        esac
        case $key in
            A_PROVIDER) [[ -n ${A_PROVIDER:-} ]] || A_PROVIDER=$val ;;
            A_API_KEY)  [[ -n ${A_API_KEY:-}  ]] || A_API_KEY=$val ;;
            A_BASE_URL) [[ -n ${A_BASE_URL:-} ]] || A_BASE_URL=$val ;;
            A_MODEL)    [[ -n ${A_MODEL:-}    ]] || A_MODEL=$val ;;
            A_MAX_RETRIES)       [[ -n ${A_MAX_RETRIES:-}       ]] || A_MAX_RETRIES=$val ;;
            A_MAX_CONTEXT_CHARS) [[ -n ${A_MAX_CONTEXT_CHARS:-} ]] || A_MAX_CONTEXT_CHARS=$val ;;
            A_TIMEOUT)           [[ -n ${A_TIMEOUT:-}           ]] || A_TIMEOUT=$val ;;
            A_STEP_TIMEOUT)      [[ -n ${A_STEP_TIMEOUT:-}      ]] || A_STEP_TIMEOUT=$val ;;
            A_DIR_ENTRIES)       [[ -n ${A_DIR_ENTRIES:-}       ]] || A_DIR_ENTRIES=$val ;;
            DEEPSEEK_API_KEY)  [[ -n ${DEEPSEEK_API_KEY:-}  ]] || DEEPSEEK_API_KEY=$val ;;
            DEEPSEEK_BASE_URL) [[ -n ${DEEPSEEK_BASE_URL:-} ]] || DEEPSEEK_BASE_URL=$val ;;
            DEEPSEEK_MODEL)    [[ -n ${DEEPSEEK_MODEL:-}    ]] || DEEPSEEK_MODEL=$val ;;
        esac
    done < "$f"
    # 配置内含密钥: 去除组/其他用户权限（幂等，600 保持不变）
    chmod go-rwx "$f" 2>/dev/null
}

# 密钥掩码: 保留前 4 后 4 字符，过短则全遮（用于界面回显，不泄露完整密钥）
_a_mask_key() {
    local k=$1
    if [[ ${#k} -le 8 ]]; then
        printf '***'
    else
        printf '%s***%s' "${k:0:4}" "${k: -4}"
    fi
}

# 将 key=value 合并进配置文件: 已有同名行原位替换，没有则追加，其余行保持不动。
# 写入经 mktemp(600)+mv 落盘并显式 chmod 600，密钥不会以宽权限存在。
_a_config_merge() { # key=value ...
    local f=${A_CONFIG_FILE:-$HOME/.config/agent-cli-bash/config}
    local tmp
    [[ $f == */* ]] && mkdir -p "${f%/*}"
    tmp=$(mktemp "${TMPDIR:-/tmp}/a-cfg.XXXXXX")
    if [[ -f $f ]]; then
        awk -v pairs="$*" '
            BEGIN {
                n = split(pairs, kv, " ")
                for (i = 1; i <= n; i++) { split(kv[i], a, "="); upd[a[1]] = a[2]; has[a[1]] = 0 }
            }
            /^[A-Za-z_][A-Za-z0-9_]*=/ {
                k = $0; sub(/=.*/, "", k)
                if (k in upd) { print k "=" upd[k]; has[k] = 1; next }
            }
            { print }
            END { for (i = 1; i <= n; i++) { split(kv[i], a, "="); if (!has[a[1]]) print kv[i] } }
        ' "$f" > "$tmp"
    else
        printf '%s\n' "$@" > "$tmp"
    fi
    mv "$tmp" "$f"
    chmod 600 "$f"
}

# 交互式配置向导: 选提供商 -> 填密钥 -> 合并写入 config（600 权限），当前会话立即生效
_a_setup() {
    local f=${A_CONFIG_FILE:-$HOME/.config/agent-cli-bash/config}
    _a_load_config
    local cur_provider=${A_PROVIDER:-deepseek}
    local cur_key=${A_API_KEY:-}
    [[ -z $cur_key ]] && cur_key=${DEEPSEEK_API_KEY:-}

    printf 'a setup — 配置向导\n'
    if [[ -n $cur_key ]]; then
        printf '当前: 提供商 %s，密钥 %s\n' "$cur_provider" "$(_a_mask_key "$cur_key")"
    else
        printf '当前: 提供商 %s，未配置密钥\n' "$cur_provider"
    fi
    _a_list_providers
    printf '  custom = 其他 OpenAI 兼容网关（需填 base URL 与模型）\n'

    local reply name names
    names=$(printf '%s\n' "$_A_PROVIDERS" | awk -F'|' 'NF > 1 { print $1 }')
    printf '选择提供商（名称或序号，回车保持 %s）: ' "$cur_provider"
    IFS= read -r reply < /dev/tty 2>/dev/null || { _a_err '无法读取终端输入（a setup 需在交互式终端运行）'; return 1; }
    reply=$(printf '%s' "$reply" | tr -d '[:space:]')
    if [[ -z $reply ]]; then
        name=$cur_provider
    elif [[ $reply =~ ^[0-9]+$ ]]; then
        name=$(printf '%s\n' "$names" | awk -v n="$reply" 'NR == n { print; exit }')
        [[ -n $name ]] || { _a_err "无效序号: $reply"; return 1; }
    elif printf '%s\n' "$names" | grep -qx -- "$reply" || [[ $reply == custom ]]; then
        name=$reply
    else
        _a_err "未知提供商: $reply（a providers 查看）"
        return 1
    fi

    local key= base= model=
    if [[ $name == custom ]]; then
        printf 'base URL（如 https://gw.example.com/v1）: '
        IFS= read -r base < /dev/tty 2>/dev/null || return 1
        base=$(printf '%s' "$base" | tr -d '[:space:]')
        [[ -n $base ]] || { _a_err 'base URL 不能为空'; return 1; }
        printf '模型名: '
        IFS= read -r model < /dev/tty 2>/dev/null || return 1
        model=$(printf '%s' "$model" | tr -d '[:space:]')
        [[ -n $model ]] || { _a_err '模型名不能为空'; return 1; }
    fi

    if [[ $name == ollama ]]; then
        printf 'ollama 本地服务无需密钥\n'
    else
        printf '粘贴 API 密钥后回车（输入不回显，直接回车=保持不变）: '
        IFS= read -rs key < /dev/tty 2>/dev/null || return 1
        printf '\n'
        key=$(printf '%s' "$key" | tr -d '[:space:]')
        case $key in
            \"*\") key=${key#\"}; key=${key%\"} ;;
        esac
        [[ -n $key ]] && printf '已读取密钥: %s\n' "$(_a_mask_key "$key")"
    fi

    if [[ $name == custom ]]; then
        _a_config_merge "A_PROVIDER=$name" "A_BASE_URL=$base" "A_MODEL=$model" ${key:+A_API_KEY=$key}
        A_BASE_URL=$base
        A_MODEL=$model
    else
        _a_config_merge "A_PROVIDER=$name" ${key:+A_API_KEY=$key}
    fi
    A_PROVIDER=$name
    [[ -n $key ]] && A_API_KEY=$key
    printf '✅ 已写入 %s（权限 600），当前会话立即生效\n' "$f"
}

# JSON 字符串转义（覆盖 bash/zsh 常见需要转义的字符）
_a_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# 从 stdin 的 JSON 中取 choices[0].message.content；失败时返回非 0
_a_json_content() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.choices[0].message.content // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    sys.stdout.write(d["choices"][0]["message"]["content"])
except Exception:
    sys.exit(1)' 2>/dev/null
    else
        return 1
    fi
}

# 从 stdin 的 JSON 中取 choices[0].delta.content（流式增量）。
# 输出约定: content 后总是补一个哨兵换行（调用方剥掉），内容自身的换行得以保留
_a_json_delta() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.choices[0].delta.content // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    c = d["choices"][0]["delta"].get("content")
    if c: sys.stdout.write(c + "\n")
except Exception:
    pass' 2>/dev/null
    else
        return 1
    fi
}

# 从 stdin 的 JSON 中取 error.message（用于友好报错）；失败时返回非 0
_a_json_error() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.error.message // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    sys.stdout.write(d["error"]["message"])
except Exception:
    sys.exit(1)' 2>/dev/null
    else
        return 1
    fi
}

# 从 stdin 的单条消息 JSON 中取 content（--show 摘要用）
_a_msg_content() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.content // empty' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    sys.stdout.write(json.load(sys.stdin).get("content") or "")
except Exception:
    pass' 2>/dev/null
    fi
}

_a_err() {
    printf 'a: %s\n' "$1" >&2
}

# 提供商解析（含配置加载与依赖检查）: A_* 显式配置 > 提供商默认 > 旧 DEEPSEEK_*（仅 deepseek，向后兼容）。
# 成功设置 _A_R_URL/_A_R_MODEL/_A_R_KEY/_A_R_TIMEOUT 四个全局；失败向 stderr 报原因并返回非 0。
_a_resolve_provider() {
    _a_load_config
    local provider=${A_PROVIDER:-deepseek}
    local pbase pmodel kenv
    pbase=$(_a_provider_field "$provider" 2)
    pmodel=$(_a_provider_field "$provider" 3)
    kenv=$(_a_provider_field "$provider" 4)
    if [[ $provider == deepseek ]]; then
        _A_R_URL=${A_BASE_URL:-${DEEPSEEK_BASE_URL:-$pbase}}
        _A_R_MODEL=${A_MODEL:-${DEEPSEEK_MODEL:-$pmodel}}
    else
        _A_R_URL=${A_BASE_URL:-$pbase}
        _A_R_MODEL=${A_MODEL:-$pmodel}
    fi
    _A_R_KEY=${A_API_KEY:-}
    if [[ -z $_A_R_KEY && -n $kenv ]]; then
        # 读取提供商对应的环境变量（如 OPENAI_API_KEY / MOONSHOT_API_KEY）
        if [[ -n ${ZSH_VERSION:-} ]]; then
            _A_R_KEY=${(P)kenv}
        else
            _A_R_KEY=${!kenv}
        fi
    fi
    [[ -z $_A_R_KEY ]] && _A_R_KEY=${DEEPSEEK_API_KEY:-}
    _A_R_TIMEOUT=${A_TIMEOUT:-60}

    if [[ -z $_A_R_URL ]]; then
        _a_err "未知提供商 '$provider'"
        printf '  支持: deepseek openai kimi qwen zhipu grok ollama openrouter（a providers 查看）\n' >&2
        printf '  其他 OpenAI 兼容网关: 设 A_PROVIDER=custom 并配 A_BASE_URL + A_MODEL\n' >&2
        return 1
    fi

    # ollama 本地服务无需密钥，其余提供商必须配置
    if [[ -z $_A_R_KEY && $provider != ollama ]]; then
        _a_err "未配置 API 密钥"
        printf '  1) 运行 a setup 交互式配置\n' >&2
        printf '  2) export A_API_KEY=sk-xxx 或 %s\n' "${kenv:-DEEPSEEK_API_KEY}" >&2
        printf '  3) 或写入 ~/.config/agent-cli-bash/config（A_API_KEY=sk-xxx）\n' >&2
        return 1
    fi
    command -v curl >/dev/null 2>&1 || { _a_err "需要 curl"; return 1; }
    if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        _a_err "需要 jq 或 python3 之一来解析响应"
        return 1
    fi
}

# 发送一轮对话请求，stdout 输出模型的原始回复；失败时 stderr 报错并返回非 0。
# 输出解析（围栏清洗等）是产品层的职责，本函数不改动内容。
_a_generate() { # _a_generate <msgs_json> <base_url> <api_key> <timeout> <model> [max_tokens=512] [temperature=0]
    local msgs_json=$1 base_url=$2 api_key=$3 timeout=$4 model=$5
    local max_tokens=${6:-512} temperature=${7:-0}
    local payload
    payload=$(printf '{"model":"%s","messages":[%s],"temperature":%s,"max_tokens":%s,"stream":true}' \
        "$(_a_json_escape "$model")" "$msgs_json" "$temperature" "$max_tokens")

    # 流式请求（SSE）：AI 生成的内容实时显示；增量与异常分别落盘，循环外汇总。
    # 网络错误与 HTTP 429/5xx 自动重试（指数退避，优先遵循 Retry-After），
    # 重试次数由 A_MAX_RETRIES 控制（默认 3，0 = 禁用）。
    printf '🤖 思考中...\r' >&2
    local raw_file content_file err_file hdr_file hdr_conf_file curl_rc=0 content http_code=
    raw_file=$(mktemp "${TMPDIR:-/tmp}/a-raw.XXXXXX")
    content_file=$(mktemp "${TMPDIR:-/tmp}/a-cc.XXXXXX")
    err_file=$(mktemp "${TMPDIR:-/tmp}/a-err.XXXXXX")
    hdr_file=$(mktemp "${TMPDIR:-/tmp}/a-hdr.XXXXXX")
    # 请求头写入 -K 临时文件（mktemp 权限 600）而非 -H 参数，密钥不进入 ps 可见的命令行
    hdr_conf_file=$(mktemp "${TMPDIR:-/tmp}/a-hdr-cfg.XXXXXX")
    printf 'header = "Content-Type: application/json"\n' > "$hdr_conf_file"
    [[ -n $api_key ]] && printf 'header = "Authorization: Bearer %s"\n' "$api_key" >> "$hdr_conf_file"

    local attempt=0 max_retries=${A_MAX_RETRIES:-3} backoff=1 retry= reason= ra=
    # 注意: zsh 中管道最后一段在当前 shell 执行，声明必须放在循环外并带初值，
    # 否则重试轮的重复 local 会触发 zsh 对已存在变量的"打印"行为
    local sse_line='' sse_data='' sse_delta='' sse_shown=0
    while :; do
        : > "$raw_file"; : > "$content_file"; : > "$err_file"; : > "$hdr_file"
        curl -sS -N --max-time "$timeout" -D "$hdr_file" \
            -K "$hdr_conf_file" \
            -d "$payload" \
            "$base_url/chat/completions" 2>"$err_file" | tee "$raw_file" | {
            sse_line=''; sse_data=''; sse_delta=''; sse_shown=0
            while IFS= read -r sse_line; do
                if [[ $sse_line == data:* ]]; then
                    sse_data=${sse_line#data: }
                    [[ $sse_data == '[DONE]' ]] && break
                    # x 占位保留输出，再剥掉哨兵换行：内容内部的换行不丢、也不多出换行
                    sse_delta=$(printf '%s' "$sse_data" | _a_json_delta; printf x)
                    sse_delta=${sse_delta%x}
                    sse_delta=${sse_delta%$'\n'}
                    if [[ -n $sse_delta ]]; then
                        if [[ $sse_shown == 0 ]]; then
                            printf '\r\033[K\033[2m' >&2
                            sse_shown=1
                        fi
                        printf '%s' "$sse_delta" >&2
                        printf '%s' "$sse_delta" >> "$content_file"
                    fi
                else
                    [[ -n $sse_line ]] && printf '%s\n' "$sse_line" >> "$err_file"
                fi
            done
        }
        curl_rc=${PIPESTATUS[0]:-${pipestatus[1]:-0}}
        printf '\033[0m\n' >&2
        content=$(cat "$content_file" 2>/dev/null)
        http_code=$(awk 'NR==1{print $2; exit}' "$hdr_file" 2>/dev/null)

        retry=; reason=
        if [[ -z $content ]]; then
            if [[ $curl_rc -ne 0 ]]; then
                # 可重试的网络类退出码（DNS/连接/超时/SSL/重置等）；中断类不重试
                case $curl_rc in
                    6|7|16|18|23|26|28|35|52|55|56) retry=1; reason="网络错误 (curl $curl_rc)" ;;
                esac
            else
                case $http_code in
                    429) retry=1; reason="HTTP 429 限流" ;;
                    5??) retry=1; reason="HTTP $http_code 服务端错误" ;;
                esac
            fi
        fi

        [[ $retry != 1 ]] && break
        attempt=$((attempt + 1))
        if [[ $attempt -gt $max_retries ]]; then
            attempt=$((attempt - 1))
            break
        fi
        ra=$(awk 'tolower($1)=="retry-after:"{print $2; exit}' "$hdr_file" 2>/dev/null)
        [[ -n $ra ]] || ra=$backoff
        printf '\r\033[K⏳ %s，%s 秒后重试 (%d/%d)\n' "$reason" "$ra" "$attempt" "$max_retries" >&2
        sleep "$ra"
        backoff=$((backoff * 2))
        printf '🤖 重试中...\r' >&2
    done

    if [[ -z $content ]]; then
        # 流式失败：优先按错误 JSON 解析（如 401），其次尝试整包解析（网关忽略 stream 参数时）
        printf '\r\033[K' >&2
        [[ $attempt -gt 0 ]] && printf '⏳ 已自动重试 %d 次仍失败\n' "$attempt" >&2
        local errout emsg
        errout=$(cat "$err_file" "$raw_file" 2>/dev/null | head -c 2000)
        content=$(printf '%s' "$errout" | _a_json_content)
        if [[ -z $content ]]; then
            emsg=$(printf '%s' "$errout" | _a_json_error)
            if [[ -n $emsg ]]; then
                _a_err "API 错误: $emsg"
            elif [[ $curl_rc -ne 0 ]]; then
                _a_err "请求失败 (curl 退出码 $curl_rc): $(head -c 300 "$err_file")"
            elif [[ $http_code == 429 || $http_code == 5* ]]; then
                _a_err "API 错误 (HTTP $http_code): ${errout:0:300}"
            else
                _a_err "无法解析响应: ${errout:0:300}"
            fi
            rm -f "$raw_file" "$content_file" "$err_file" "$hdr_file" "$hdr_conf_file"
            return 1
        fi
    fi
    rm -f "$raw_file" "$content_file" "$err_file" "$hdr_file" "$hdr_conf_file"
    printf '%s\n' "$content"
}
