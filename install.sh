#!/usr/bin/env bash
# agent-cli-bash 安装/卸载脚本
# 用法:
#   ./install.sh              安装（把 source 行写入 shell 配置）
#   ./install.sh --uninstall  卸载

set -u

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MARK_BEGIN="# >>> agent-cli-bash >>>"
MARK_END="# <<< agent-cli-bash <<<"
SNIPPET="$MARK_BEGIN
source \"$REPO_DIR/a.sh\"
$MARK_END"

usage() {
    cat <<EOF
用法: $(basename "$0") [--uninstall]

  （无参数）       安装 a 命令到当前 shell 配置
  --uninstall      移除 a 命令
EOF
}

uninstall=0
[[ ${1:-} == --uninstall ]] && uninstall=1
[[ ${1:-} == -h || ${1:-} == --help ]] && { usage; exit 0; }
[[ $# -gt 0 && $uninstall == 0 ]] && { usage >&2; exit 2; }

# 根据 $SHELL 选目标 rc 文件；zsh -> ~/.zshrc, bash -> ~/.bashrc
target_rc=
case ${SHELL:-} in
    */zsh)  target_rc=$HOME/.zshrc ;;
    */bash) target_rc=$HOME/.bashrc ;;
    *)      target_rc=$HOME/.bashrc ;;
esac

[[ -f $target_rc ]] || touch "$target_rc"

remove_block() {
    local f=$1
    # 删除标记行之间的内容（含标记行）
    sed -i.bak -e "/^$MARK_BEGIN\$/,/^$MARK_END\$/d" "$f" && rm -f "$f.bak"
}

if [[ $uninstall == 1 ]]; then
    remove_block "$target_rc"
    echo "已从 $target_rc 移除 agent-cli-bash"
    exit 0
fi

# 幂等：先删旧块再追加新块（仓库移动位置后路径也能更新）
remove_block "$target_rc"
printf '\n%s\n' "$SNIPPET" >> "$target_rc"

# 生成配置文件模板（不覆盖已有的）
config_dir=$HOME/.config/agent-cli-bash
config_file=$config_dir/config
if [[ ! -f $config_file ]]; then
    mkdir -p "$config_dir"
    cat > "$config_file" <<'EOF'
# agent-cli-bash 配置。也可用环境变量覆盖同名项（运行 `a providers` 查看内置提供商）
# 提供商: deepseek(默认) openai kimi qwen zhipu grok ollama openrouter
A_PROVIDER=deepseek
# 密钥填这里（也可 export A_API_KEY=sk-xxx，或用提供商变量如 OPENAI_API_KEY）
A_API_KEY=
# 以下可选，留空用提供商默认
# A_BASE_URL=
# A_MODEL=
# A_MAX_RETRIES=3            # 网络错误/429/5xx 自动重试次数（0=禁用）
# A_MAX_CONTEXT_CHARS=24000  # 会话上下文字符预算
# A_TIMEOUT=60               # 单次请求超时秒数
# A_DIR_ENTRIES=15           # 目录条目注入上限（0=不注入）；超出时相关的优先、其余按修改时间
EOF
    chmod 600 "$config_file"
    echo "已生成配置模板 ${config_file}（权限 600，记得填入 A_API_KEY）"
fi

cat <<EOF

安装完成 ✔

  1. 重启终端，或先执行:  source $target_rc
  2. 配置密钥: 运行 a setup 交互式配置
     （或 export A_API_KEY=sk-xxx / 编辑 ${config_file}）
  3. 试用:  a 找出当前目录下最大的 5 个文件

EOF
