# a-exec.sh —— L3 执行域（harness）
# 命令结构切分、风险评估、shell 状态命令识别与带确认的多步执行。
# 依赖 L2（执行结果经 _a_conv_append 回写会话）；不依赖产品层的任何约定。
# 由 a.sh 在加载时 source，不单独使用。

# 判断命令是否直接改变当前 shell 状态（cd/export/alias/source/赋值等）。
# 这类命令必须绕过管道在当前 shell 执行，否则 cd、变量、别名只在子 shell 生效。
_a_shell_state() {
    local c=$1
    printf '%s' "$c" | grep -qE '(^|[;&|(]|\||&&) *(cd|pushd|popd|export|unset|setopt|unsetopt|shopt|set|alias|unalias|source|umask|ulimit|exec|trap)([^a-zA-Z0-9_-]|$)' \
        || printf '%s' "$c" | grep -qE '(^|[;&|]|&&) *\. +[^ ]' \
        || printf '%s' "$c" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*='
}

# 命令风险评估: 输出 danger(高危: 提权/强制删除/系统级写) / caution(写操作) / 空(只读)
_a_risk() {
    local c=$1
    if printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_.-])(sudo|su|doas|pkexec|mkfs|fdisk|shutdown|reboot|halt|shred|dd)([^a-zA-Z0-9_.-]|$)' \
        || printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_-])rm +-[a-zA-Z]*[rRf]' \
        || printf '%s' "$c" | grep -qE 'git +(push +(-f|--force)|reset +--hard|clean|checkout +--|restore)' \
        || printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_-])kill +(-9|-[sSIG]*KILL)' \
        || printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_-])(chmod|chown) +-[a-zA-Z]*R' \
        || printf '%s' "$c" | grep -qE 'diskutil +(erase|partition|format)' \
        || printf '%s' "$c" | grep -qE '(curl|wget)[^|]*\| *(ba|z)?sh'; then
        printf 'danger\n'
    elif printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_.-])(rm|chmod|chown|chgrp|kill|pkill|killall|mv|truncate|tee)([^a-zA-Z0-9_.-]|$)' \
        || printf '%s' "$c" | grep -qE 'git +(push|commit|stash)' \
        || printf '%s' "$c" | grep -qE '(apt|apt-get|brew|yum|dnf|pip3?|npm|gem) +install' \
        || printf '%s' "$c" | grep -qE '(^|[^a-zA-Z0-9_-])(systemctl|launchctl|service) ' \
        || printf '%s' "$c" | grep -qE 'sed +-[a-zA-Z]*i' \
        || printf '%s' "$c" | grep -qE '(^|[^>2])>([^>&]|$)'; then
        printf 'caution\n'
    fi
}

# 终端上提示并读入一行回答（ASK 追问等交互复用）。
# 成功把回答存入全局 reply 并返回 0；无终端可读时打印提示、reply 置空、返回 1。
_a_prompt_answer() { # _a_prompt_answer <提示文本(不含换行)>
    printf '%s' "$1" >&2
    if IFS= read -r reply < /dev/tty 2>/dev/null; then
        return 0
    fi
    reply=
    printf '\n(无终端可交互，无法补充信息)\n' >&2
    return 1
}

# 把多行命令切成"完整 shell 结构"的步骤，跨行结构不被拆坏:
#   - 块结构: for/while/until/select...done、if...fi、case...esac、{ }、( )、函数体
#   - heredoc: <<EOF / <<-'EOF' 体整段归入起始行（<<< here-string 不算）
#   - 续行: 行尾反斜杠、未闭合引号、行尾 | / && / ||
# 逐字符扫描（带引号/转义/注释状态），关键字只在其命令位置生效，case 内不计圆括号
# （避免模式 foo) 误减深度）。尽力而为: 输入未闭合时剩余行并入最后一个步骤，
# 交给 eval 如实报语法错误。输出: 各步骤以 \036 分隔，无换行尾。
_a_split_steps() {
    awk '
    function emit(s) { if (s ~ /[^ \t]/) printf "%s\036", s }
    function flush_word() {
        if (word == "") return
        if (wpos) {
            if (word == "if" || word == "for" || word == "while" || word == "until" \
             || word == "select" || word == "case") {
                kw++
                if (word == "case") cdep++
            } else if (word == "fi" || word == "done") {
                if (kw > 0) kw--
            } else if (word == "esac") {
                if (kw > 0) kw--
                if (cdep > 0) cdep--
            }
        }
        lastw = word
        if (fnp > 0) fnp--
        word = ""; wpos = 0
    }
    BEGIN {
        kw = 0; par = 0; br = 0; cdep = 0; q = ""; esc = 0
        hd_n = 0; buf = ""; hd_cont = 0; lastw = ""; fnp = 0
        sq = sprintf("%c", 39)                       # 单引号，避免写进本程序文本
        stop = " \t;&|<>();#\"\\\\" sq                # heredoc 裸标签的结束字符集
    }
    {
        line = $0
        # heredoc 体内: 原样收集，直到命中终止符行（<<- 剥前导空白后比较）
        if (hd_n > 0) {
            buf = buf == "" ? line : buf "\n" line
            t = line
            if (hd_strip[1]) sub(/^[ \t]+/, "", t)
            if (t == hd_tag[1]) {
                for (k = 1; k < hd_n; k++) { hd_tag[k] = hd_tag[k+1]; hd_strip[k] = hd_strip[k+1] }
                delete hd_tag[hd_n]; delete hd_strip[hd_n]
                hd_n--
                if (hd_n == 0 && !hd_cont) { emit(buf); buf = "" }
            }
            next
        }
        # 步骤间隙的空行/纯注释行丢弃（结构内部的空行不算间隙）
        if (buf == "" && kw + par + br == 0 && line ~ /^[ \t]*($|#)/) next

        n = length(line)
        i = 1; word = ""; wpos = 1; cmdpos = 1
        lastc = ""; last2 = ""; tbs = 0
        while (i <= n) {
            c = substr(line, i, 1)
            if (q != "") {                            # 引号内: 只找闭合引号（双引号内 \ 转义）
                if (q == "\"" && c == "\\") { i += 2; continue }
                if (c == q) { q = ""; last2 = lastc c; lastc = c }
                i++
                continue
            }
            if (esc) {                                # 被转义的元字符按字面并入词
                if (word == "") wpos = cmdpos
                word = word "W"
                esc = 0; i++
                continue
            }
            if (c == "\\") {
                if (i == n) { tbs = 1; break }        # 行尾反斜杠 → 续行
                esc = 1; i++
                continue
            }
            if (c == sq || c == "\"") {
                flush_word()
                q = c; last2 = lastc c; lastc = c
                i++
                continue
            }
            if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[ \t]/)) break
            if (c == " " || c == "\t") { flush_word(); i++; continue }
            last2 = lastc c; lastc = c
            if (c == ";" || c == "&" || c == "|") { flush_word(); cmdpos = 1; i++; continue }
            if (c == "(") { flush_word(); if (cdep == 0) par++; cmdpos = 1; i++; continue }
            if (c == ")") { flush_word(); if (cdep == 0 && par > 0) par--; cmdpos = 1; i++; continue }
            if (c == "{") { flush_word(); if (cmdpos || fnp > 0) br++; cmdpos = 1; i++; continue }
            if (c == "}") { flush_word(); if (cmdpos && br > 0) br--; cmdpos = 1; i++; continue }
            if (c == "<" && substr(line, i, 2) == "<<") {
                flush_word()
                if (substr(line, i, 3) == "<<<") { i += 3; continue }   # here-string 不算
                st = 0
                if (substr(line, i, 3) == "<<-") { st = 1; j = i + 3 } else j = i + 2
                while (j <= n && substr(line, j, 1) ~ /[ \t]/) j++
                qq = ""
                if (j <= n) {
                    fc = substr(line, j, 1)
                    if (fc == "\\") { j++; qq = "" }
                    else if (fc == sq || fc == "\"") { qq = fc; j++ }
                }
                t = ""
                while (j <= n) {
                    tc = substr(line, j, 1)
                    if (qq != "") {
                        if (tc == qq) { j++; break }   # 连闭合引号一起跳过
                        t = t tc
                    } else {
                        if (index(stop, tc) > 0) break
                        t = t tc
                    }
                    j++
                }
                # 标签须为纯词字符（防 $((1<<2)) 之类误判），且不在圆括号内
                if (t != "" && length(t) <= 64 && t ~ /^[A-Za-z0-9_.-]+$/ && par == 0) {
                    hd_n++; hd_tag[hd_n] = t; hd_strip[hd_n] = st
                }
                i = j
                continue
            }
            if (word == "") wpos = cmdpos
            word = word c
            cmdpos = 0
            i++
        }
        flush_word()
        buf = buf == "" ? line : buf "\n" line
        if (hd_n > 0) {                               # 体从下一行开始；记录体外的结构状态
            hd_cont = (kw + par + br > 0 || q != "" || tbs)
            next
        }
        if (kw + par + br > 0 || q != "" || tbs || lastc == "|" || last2 == "&&") next
        emit(buf); buf = ""
    }
    END { emit(buf) }
    '
}

# 单步执行（超时看护）。secs 为 0 时按原路径执行（eval | tee，输出实时流式）；
# 大于 0 时步骤转入后台独立执行，监视器计时——
#   - 正常完成: 命令退出码经 rc 文件中转回传（后台管道 $? 拿到的是 tee 的退出码）
#   - 超过 secs: 先 TERM 后 KILL 整个命令进程组；拿不到独立进程组（如非交互 zsh）
#     时退化为递归终止进程树，尽力清干净子进程。返回 124（对齐 GNU timeout 习惯）
#   - Ctrl-C: 转发给步骤进程后以 130 退出
# 进程组 id 以 ps 探测为准: zsh 交互式下 $! 是管道末端的 pid 而非组长，不能直接
# kill -- -$!；探测不到独立组（与当前组相同）则说明没有任务控制，走进程树兜底。
# 子 shell 的 stderr 全程丢弃——作业终止通知（Terminated ...）与 set -m 的报错
# 不应污染终端；用户可见的超时提示由调用方按退出码 124 打印。
_a_step_run() { # _a_step_run <secs> <step> <out_file>
    local secs=$1 step=$2 out_file=$3
    if [[ $secs -le 0 ]]; then
        eval "$step" 2>&1 | tee -a "$out_file"
        return ${PIPESTATUS[0]:-${pipestatus[1]:-0}}
    fi
    local rc_file flag
    rc_file=$(mktemp "${TMPDIR:-/tmp}/a-rc.XXXXXX"); rm -f "$rc_file"
    flag=$(mktemp "${TMPDIR:-/tmp}/a-tflag.XXXXXX"); rm -f "$flag"
    (
        # zsh 在函数上下文里 set -m 会直接终止子 shell，不能开；其交互式 shell
        # 默认 monitor 开启，后台任务本就在独立进程组。bash 则显式开启 job control
        [[ -n ${ZSH_VERSION:-} ]] || set -m 2>/dev/null || true
        { eval "$step" 2>&1 | tee -a "$out_file"
          printf '%s\n' "${PIPESTATUS[0]:-${pipestatus[1]:-0}}" > "$rc_file"; } &
        local job=$! wd rc=0 jobpg mypg grouped=0
        jobpg=$(ps -o pgid= -p "$job" 2>/dev/null | tr -d ' ')
        mypg=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
        [[ $jobpg =~ ^[0-9]+$ && $mypg =~ ^[0-9]+$ && $jobpg != "$mypg" ]] && grouped=1
        kt() { # 递归终止进程树（无独立进程组时的兜底）: 先子后己
            local c
            for c in $(pgrep -P "$1" 2>/dev/null); do kt "$c" "$2"; done
            kill -"$2" "$1" 2>/dev/null
        }
        ( sleep "$secs"
          kill -0 "$job" 2>/dev/null || exit 0
          printf x > "$flag"
          if [[ $grouped == 1 ]]; then kill -TERM -- "-$jobpg" 2>/dev/null
          else kt "$job" TERM; fi
          sleep 1
          if [[ $grouped == 1 ]]; then kill -KILL -- "-$jobpg" 2>/dev/null
          else kt "$job" KILL; fi ) &
        wd=$!
        trap 'if [[ $grouped == 1 ]]; then kill -TERM -- "-$jobpg" 2>/dev/null; else kt "$job" TERM; fi; exit 130' INT
        wait "$job"; rc=$?
        kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
        if [[ -e $flag ]]; then
            exit 124
        fi
        [[ -r $rc_file ]] && rc=$(cat "$rc_file" 2>/dev/null)
        exit "$rc"
    ) 2>/dev/null
}

# 多步确认执行: 把 <cmd> 按完整 shell 结构切成步骤（_a_split_steps，跨行的
# for/heredoc 等作为一步），逐步显示风险并询问 y/n/i；
# 高危命令即使 -y 也强制确认，无终端一律拒绝；shell 状态命令在当前 shell 执行
# （这类命令瞬时完成，不设超时）；其余步骤受 A_STEP_TIMEOUT（默认 600s，0=禁用）
# 看护，超时终止后返回 124。
# 执行结果摘要（R 消息）回写到 <mode> 的会话；返回最后一步退出码，用户终止返回 130。
_a_exec_steps() { # _a_exec_steps <mode> <auto_yes> <cmd>
    local mode=$1 auto_yes=$2 cmd=$3
    local risk reply step
    local step_secs=${A_STEP_TIMEOUT:-600}
    [[ $step_secs =~ ^[0-9]+$ ]] || step_secs=600
    local timed_steps=0
    local -a steps
    steps=()
    while IFS= read -rd $'\036' step; do
        [[ -n ${step//[[:space:]]/} ]] && steps+=("$step")
    done < <(printf '%s\n' "$cmd" | _a_split_steps)
    local total=${#steps[@]} n=0 executed=0 skipped=0 stopped_at=0 rc=0 state_executed=0
    local out_file out_tail
    out_file=$(mktemp "${TMPDIR:-/tmp}/a-out.XXXXXX")

    for step in "${steps[@]}"; do
        n=$((n + 1))

        if [[ $total -gt 1 ]]; then
            printf '\033[1m步骤 %d/%d:\033[0m ' "$n" "$total" >&2
        fi
        risk=$(_a_risk "$step")
        case $risk in
            danger)
                printf '\033[31m%s\033[0m\n' "$step" >&2
                printf '\033[31m⚠  高危/高权限操作（提权/强制删除/系统级写入），逐字核对命令与路径\033[0m\n' >&2
                ;;
            caution)
                printf '\033[33m%s\033[0m\n' "$step" >&2
                printf '\033[33m⚡  写操作，会修改文件或状态\033[0m\n' >&2
                ;;
            *)
                printf '\033[36m%s\033[0m\n' "$step" >&2
                ;;
        esac

        # 高危命令必须用户逐条决策：即使 -y 也不跳过；无终端时直接拒绝
        if [[ $auto_yes != 1 || $risk == danger ]]; then
            if [[ $risk == danger ]]; then
                printf '\033[31m确认执行高危命令?\033[0m [y=执行 n=终止剩余 i=跳过此步] ' >&2
            elif [[ $total -gt 1 ]]; then
                printf '执行此步? [y=执行 n=终止剩余 i=跳过此步] ' >&2
            else
                printf '执行? [y=执行 n=不执行 i=忽略] ' >&2
            fi
            if IFS= read -r reply < /dev/tty 2>/dev/null; then
                :
            else
                reply=
                printf '\n(无终端可交互，视为不执行；脚本中请使用 a -y / a -p)\n' >&2
            fi
            case $reply in
                y|Y)
                    ;;
                i|I)
                    printf '(已跳过)\n' >&2
                    skipped=$((skipped + 1))
                    continue
                    ;;
                *)
                    printf '已终止，剩余步骤不再执行\n' >&2
                    stopped_at=$n
                    break
                    ;;
            esac
        fi

        executed=$((executed + 1))
        if _a_shell_state "$step"; then
            # shell 状态命令直接在当前 shell 执行（不经管道子 shell），
            # 保证 cd/变量/别名真正生效；输出实时显示但不捕获回传
            eval "$step"
            rc=$?
            state_executed=$((state_executed + 1))
        else
            _a_step_run "$step_secs" "$step" "$out_file"
            rc=$?
            if [[ $rc == 124 ]]; then
                timed_steps=$((timed_steps + 1))
                printf '⏱  步骤超过 %ss 未完成，已终止（A_STEP_TIMEOUT 可调大或设 0 禁用）\n' "$step_secs" >&2
            fi
        fi
    done

    out_tail=$(tail -n 40 "$out_file" 2>/dev/null | head -c 4000)
    rm -f "$out_file"

    # 一步未执行且是用户终止 → 130；执行过任何步骤 → 最后一步的退出码
    if [[ $executed -eq 0 && $stopped_at -gt 0 ]]; then
        rc=130
    fi

    local summary
    if [[ $total -gt 1 ]]; then
        summary="多步执行: 共 $total 步，执行 $executed 步，跳过 $skipped 步"
        [[ $stopped_at -gt 0 ]] && summary="$summary，在第 $stopped_at 步被用户终止"
        summary="$summary。最后退出码 $rc"
    elif [[ $stopped_at -gt 0 ]]; then
        summary="用户选择不执行该命令"
    else
        summary="上一条命令执行结果: 退出码 $rc"
    fi
    if [[ $state_executed -gt 0 ]]; then
        summary="$summary（其中 $state_executed 步为 shell 状态命令 cd/变量等，已在当前 shell 生效，输出未捕获）"
    fi
    if [[ $timed_steps -gt 0 ]]; then
        summary="$summary（$timed_steps 步超过 ${step_secs}s 被超时终止——命令可能未完成；如需更久可让用户调大 A_STEP_TIMEOUT 或设 0 禁用后改用 nohup/后台运行）"
    fi
    _a_conv_append "$mode" R "$(printf '{"role":"user","content":"%s"}' "$(_a_json_escape "$summary
输出(可能截断):
$out_tail")")"
    return $rc
}
