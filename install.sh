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
# agent-cli-bash 配置。也可用环境变量覆盖同名项。
# 在 https://platform.deepseek.com/api_keys 创建密钥后填到下面，或 export DEEPSEEK_API_KEY=sk-xxx
DEEPSEEK_API_KEY=
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-chat
EOF
    echo "已生成配置模板 ${config_file}（记得填入 DEEPSEEK_API_KEY）"
fi

cat <<EOF

安装完成 ✔

  1. 重启终端，或先执行:  source $target_rc
  2. 配置密钥（二选一）:
       export DEEPSEEK_API_KEY=sk-xxx
     或编辑 $config_file
  3. 试用:  a 找出当前目录下最大的 5 个文件

EOF
