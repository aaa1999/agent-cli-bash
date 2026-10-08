# agent-cli-bash

[English](README.en.md) | [中文](README.md)

在终端里用一句自然语言让 AI 生成 bash 命令。输入 `a` + 空格 + 你想做的事，DeepSeek 返回命令，确认后直接在**当前 shell** 里执行。

```console
$ a 找出当前目录下最大的 5 个文件
du -ah . 2>/dev/null | sort -rh | head -5
执行? [y=执行 n=不执行 i=忽略] y
...
```

纯 bash/zsh 实现，只依赖 `curl` 和 `jq`（或 `python3`），无其他运行时。

## 安装

```bash
git clone <本仓库>
cd agent-cli-bash
./install.sh          # 依据 $SHELL 写入 ~/.zshrc 或 ~/.bashrc
source ~/.zshrc       # 或重启终端
```

卸载：`./install.sh --uninstall`

安装后 `a.sh`（入口）与 `lib/`（harness）需保持在同一目录内一起携带；rc 里只有一行 `source .../a.sh`，由它自己加载 `lib/`。

## Windows（PowerShell 版）

`win/` 目录是等价的 PowerShell 移植（Windows PowerShell 5.1 与 PowerShell 7+ 均可），与 bash 版一一对应：`win/a.ps1`（入口+产品层）、`win/lib/`（a-api/a-ctx/a-exec 三域 harness）、`win/install.ps1`。零外部依赖——HTTP 用系统自带的 `curl.exe`（Windows 10 1803+），JSON 用 PowerShell 内置的 `ConvertFrom-Json`（不需要 jq）。

```powershell
git clone <本仓库>
cd agent-cli-bash\win
powershell -ExecutionPolicy Bypass -File install.ps1    # pwsh 7 同样可以
# 重开 PowerShell 后：a 找出当前目录下最大的 5 个文件
```

- 安装 = 在 `$PROFILE` 写入一行 dot-source `win\a.ps1`；卸载：`install.ps1 -Uninstall`
- 用法（`a` / `a -p` / `a -y` / `a ask` / `a -c` / `a --show` / `a setup`）、多轮对话、ASK 反问、风险分级确认与 bash 版一致；风险规则表适配了 PowerShell/cmd 命令（`Remove-Item -Recurse -Force`、`Format-Volume`、`iwr | iex` 等）
- 配置与 bash 版同路径同格式（`~\.config\agent-cli-bash\config`）
- 差异：PowerShell 函数没有独立退出码，执行结果码在 `$A_LAST_RC`；管道不派生子 shell，`cd` 与 `$env:` 赋值天然在当前会话生效（普通 `$x=` 不驻留，需要时让 AI 用 `$env:` 或 `$global:`）
- 本地测试：`pwsh -NoProfile -File win\test.ps1`（需要 python3 起 mock 服务）；`win/` 也能在 macOS/Linux 的 pwsh 里运行，测试即在此环境验证

## 配置

支持多家模型提供商，`a providers` 查看内置列表：

| 提供商 | `A_PROVIDER` | 默认模型 | 密钥环境变量 |
| --- | --- | --- | --- |
| DeepSeek（默认） | `deepseek` | `deepseek-chat` | `DEEPSEEK_API_KEY` |
| ChatGPT / OpenAI | `openai` | `gpt-4o-mini` | `OPENAI_API_KEY` |
| Kimi / Moonshot | `kimi` | `kimi-k2-0905-preview` | `MOONSHOT_API_KEY` |
| 通义千问 | `qwen` | `qwen-plus` | `DASHSCOPE_API_KEY` |
| 智谱 GLM | `zhipu` | `glm-4-flash` | `ZHIPU_API_KEY` |
| xAI Grok | `grok` | `grok-3-mini` | `XAI_API_KEY` |
| Ollama（本地） | `ollama` | `qwen3:8b` | 无需（默认空） |
| OpenRouter | `openrouter` | `openai/gpt-4o-mini` | `OPENROUTER_API_KEY` |

切换到 ChatGPT 只需：

```bash
export A_PROVIDER=openai
export OPENAI_API_KEY=sk-xxx     # 已有该变量则无需设置
```

也可运行 `a setup` 交互式配置——选提供商、粘贴密钥（不回显），自动合并写入 `~/.config/agent-cli-bash/config` 并设 600 权限，当前会话立即生效。或直接编辑该文件（`install.sh` 已生成模板）：

```ini
A_PROVIDER=kimi
A_API_KEY=sk-xxx                 # 统一密钥项；未设时自动读取上表对应的环境变量
# A_MODEL=kimi-k2-0905-preview   # 可选，覆盖默认模型
# A_BASE_URL=...                 # 可选，覆盖 API 地址；其他 OpenAI 兼容网关由此接入
# A_MAX_RETRIES=3                # 可选，网络错误/429/5xx 自动重试次数（0=禁用）
# A_MAX_CONTEXT_CHARS=24000      # 可选，会话上下文字符预算
# A_TIMEOUT=60                   # 可选，单次请求超时秒数
# A_DIR_ENTRIES=15               # 可选，目录条目注入上限（0=不注入）；超出时与请求相关的优先、其余按修改时间
```

优先级：环境变量 > 配置文件；`A_API_KEY` > 提供商专属变量（如 `OPENAI_API_KEY`）。只配旧版 `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL` / `DEEPSEEK_MODEL` 时行为与之前完全一致。`A_MAX_RETRIES` 可调整网络错误与 429/5xx 的自动重试次数（默认 3，指数退避并遵循 `Retry-After` 头；0 禁用；401 等客户端错误不重试）。`A_TIMEOUT` 设置单次请求超时（默认 60 秒）。`A_DIR_ENTRIES` 控制注入的目录条目上限（默认 15，0 为不注入）。

密钥安全：配置文件在加载和 `a setup` 写入时都会自动收紧为 600 权限（仅属主可读写）；请求头经 `-K` 临时文件传给 curl，密钥不会出现在进程参数中（`ps` 不可见）。

## 用法

| 命令 | 作用 |
| --- | --- |
| `a <自然语言>` | 生成命令，确认后执行 |
| `a -p <自然语言>` | 只打印命令，不执行（管道友好） |
| `a -y <自然语言>` | 跳过普通确认直接执行（高危命令仍会强制询问） |
| `a ask <问题>` | 自由问答：直接给出回答，不生成/执行命令；支持管道输入 |
| `a -c` | 清空本会话的多轮对话上下文 |
| `a --show` | 查看会话上下文构成（轮次/体积/裁剪情况） |
| `a providers` | 列出内置模型提供商 |
| `a setup` | 交互式配置提供商与密钥（写入 config，600 权限） |
| `a -h` / `a --version` | 帮助 / 版本 |

确认提示 `执行? [y=执行 n=不执行 i=忽略]`：`y` 执行；`n` 或直接回车不执行，退出码 130（明确拒绝，脚本中可被 `||` 捕获）；`i` 忽略跳过，不执行且退出码 0。执行过的命令会写入 shell 历史，按 ↑ 可找回。

**多步命令逐步确认**：AI 返回多行命令（多个连续步骤）时不会一次全部执行，而是逐步显示、每一步单独决策。切分按完整 shell 结构进行——跨行的 `for`/`while`/`if`/`case`/函数体、heredoc、行尾 `\`/`|` 续行会作为**一步整体**，不会被拆成非法片段：

```console
$ a 备份配置并清理临时文件
步骤 1/3: cp app.conf app.conf.bak
⚡  写操作，会修改文件或状态
执行此步? [y=执行 n=终止剩余 i=跳过此步] y
步骤 2/3: sudo rm -rf /tmp/cache
⚠  高危操作（提权/强制删除/系统级写入），请仔细确认
执行此步? [y=执行 n=终止剩余 i=跳过此步] n
已终止，剩余步骤不再执行
```

- `y` 执行此步并继续；`n` 终止剩余所有步骤（全部未执行时退出码 130）；`i` 跳过此步继续后面的步骤。
- 每一步执行前会做静态风险检查并高亮显示：`sudo`/`su`、`rm -rf`、`dd`、`git push --force`、`git checkout --`、`curl | sh` 等高危命令**整条红色显示**，`rm`、`mv`、覆盖重定向 `>`、`git push`、包安装等写操作**黄色显示**（基于模式匹配，不能替代人工审查）。
- **高危命令必须逐条人工确认：即使 `a -y` 也不会自动执行**，无终端环境下（脚本/CI）直接拒绝。
- AI 的生成过程以**流式实时显示**（灰色暗淡），确认前再以风险高亮颜色展示正式命令。

**流式输出**：请求以 SSE 流式发送，AI 生成命令的过程实时显示，无需等待完整响应。

## 多轮对话与会话上下文

同一个 shell 会话里，`a` 会自动携带上下文，可以像对话一样连续追问：

```console
$ a 列出当前目录的图片
find . -maxdepth 1 -name '*.png' -o -name '*.jpg'
执行? [y=执行 n=不执行 i=忽略] y
$ a 只要 png，按修改时间排序，最新的在前
ls -t *.png
执行? [y=执行 n=不执行 i=忽略] y
$ a 刚才第一条命令报错了，帮我修一下
...
```

每轮发送给 AI 的上下文包括：

- 管道输入（`cat error.log | a 解释报错` 时整个 stdin 内容，限 8KB）；
- **当前环境**：工作目录、git 分支与未提交变更数、目录条目（上限 `A_DIR_ENTRIES`，默认 15）——目录过大时不按字母序盲目截断，而是**与请求相关的条目优先**（说"算 linuxiso 的 sha256"会把 `linuxmint-*.iso` 排在最前），其余按修改时间新→旧补足，表头注明总条目数；
- 本会话之前的请求、AI 生成的命令（即使你没执行）；
- 已执行命令的**退出码和输出尾部**（最后 40 行），所以"报错了帮我修"这类追问能工作；
- 最近 6 条终端历史命令（你手动输入的，`a` 自身的除外），让 AI 了解你当前在做什么。

**AI 不编造文件名，拿不准就问**：系统提示明确要求只使用上下文中出现的确切名称来解释你的口语说法；所指文件仍不明确或不在上下文中时，AI 会以 `❓` 反问（如"目录里有多个 iso 文件，要计算哪一个的 sha256？"），按提示输入补充信息即可**在同轮继续生成命令**（最多追问 3 次），直接回车取消；无终端环境（脚本/CI）下打印问题后安全退出，不会执行任何东西。

上下文按 shell 会话隔离（不同终端窗口互不影响），`a -c` 随时清空重新开始；命令（`a`）与问答（`a ask`）的上下文按模式分开存储、互不混入，`a -c` 一并清空。体积受双重控制：最多 40 条消息，且按字符预算（`A_MAX_CONTEXT_CHARS`，默认 24000≈12K token）从新到旧保留**完整的轮次**（请求+命令+结果一组，绝不切半），超预算自动裁掉最旧的轮、始终保留最新一轮。

随时用 `a --show` 查看当前会话累积了哪些轮次、总体积、下一轮实际会发送多少：

```console
$ a --show
[run] 会话上下文: 4 条消息 / 243 字节，预算 24000，下一轮将发送 4 条 / 243 字节（a -c 清空）
  轮 1  找出最大的文件
        命令: du -ah . | sort -rh | head -5
  轮 2  只要前 3 个
        命令: du -ah . | sort -rh | head -5
```

AI 需要多个连续步骤时可以直接返回多行命令，按完整 shell 结构切成步骤、逐步确认后依次执行（跨行结构整体作为一步，见上文"多步命令逐步确认"）。

注意事项：

- `cd`、`export`、`alias`、`source` 等会改变 shell 状态的命令**直接在当前 shell 执行**（目录切换、变量、别名真正生效），其输出不回传给 AI，回传摘要中会注明；
- 命令输出和 shell 历史会发送给 DeepSeek，敏感环境请用 `a -p` 手动把关、或避免在含密钥的会话中使用；
- 其余命令的输出经过管道捕获，`vim`、`top` 这类全屏交互程序经 `a` 运行会显示异常——这类程序请直接输入运行。

示例：

```bash
a 把所有 .png 压缩到 50% 质量
a 查看这个 git 仓库最近两周谁提交得最多
a -p 计算一段文本里出现频率最高的单词
cat error.log | a 解释这个报错          # 管道内容作为上下文发送（限 8KB）
git diff | a 帮我写一条提交信息
dmesg | tail -50 | a                   # 有管道输入时，文字描述可以省略
```

## 安全须知

- AI 生成的命令默认**先展示、人工确认**后才执行；多步命令按结构切分逐步确认，**高危/高权限命令即使 `-y` 也强制要求人工确认**，无终端环境一律拒绝。
- 命令通过 `eval` 在当前 shell 执行，`cd`、环境变量、别名都会生效——这是特性也是风险，删除类操作请仔细阅读再确认。
- 管道内容、命令输出和 shell 历史会发送给 DeepSeek，敏感环境请用 `a -p` 手动把关、或避免在含密钥的会话中使用。

## 工作原理

代码分为产品层与 harness 两部分，依赖单向向下：

- `a.sh` —— 入口与产品层：`a` 命令路由、各能力的 system prompt 与输出解析（命令模式清洗围栏、ASK 反问）、确认与执行的 UX；
- `lib/a-api.sh` —— 传输域：提供商表、配置读写（`a setup`）、SSE 流式客户端与自动重试；
- `lib/a-ctx.sh` —— 上下文域：按模式分键的会话存储与裁剪、目录智能选取、git/终端历史采集；
- `lib/a-exec.sh` —— 执行域：命令结构切分（跨行块/heredoc 聚合为一步）、风险分级、shell 状态识别、多步确认执行器与终端交互件。

运行时把你的描述 + 当前系统/目录上下文发给模型（`temperature=0`，要求只返回命令），确认后 `eval` 执行。新增一种能力 = 在产品层加一个模式函数（自己的 prompt 与输出策略），复用 harness 的传输与上下文（`a ask` 即首个例子）。

## 开发

```bash
bash -n a.sh && zsh -n a.sh            # 语法检查（bash/zsh 双兼容）
bash test.sh                            # 本地 mock API 全链路测试，不访问外网

pwsh -NoProfile -File win/test.ps1      # Windows 版同源测试（win/ 见上节）
```
