---
日期：2026-11-04
分支：main
状态：已完成
---

# 移植 deepseek-harness 核心骨架到 agent-cli-bash

## 一、目标与范围

把 dsh(deepseek-harness)定义的 harness 最小可移植核心——**turn/step agent 循环、工具注册表与执行管线、append-only 会话事件日志 + deriveMessages 投影、LLM 调用层对齐**——以纯 bash(macOS 3.2 + zsh 兼容)语义落到本项目,双平台同步(含 win/ PowerShell 镜像)。

- 现有 run/ask 模式行为零改动(129 项存量测试即回归闸门)
- 新增 `a agent <任务>` 产品模式,走工具调用循环
- 工具集对齐 dsh 工具目录中纯 bash 可实现的部分(10 个,见下)
- 版本升至 0.6.0

## 二、架构映射(dsh 概念 → 本项目落点)

| dsh 概念 | 本项目落点 |
|---|---|
| AgentLoop.turn()/step() 循环 | 新文件 lib/a-agent.sh:`_a_agent` 循环(请求→tool_calls→执行→回填→再请求,直到纯文本回答或步数上限) |
| ToolsService 注册表 + pre/execute/post 管线 | 新文件 lib/a-tools.sh:并行数组注册表(无关联数组,兼容 bash 3.2/zsh)+ `_a_tool_execute` 三段管线 |
| Session 事件日志 + deriveMessages 投影 | lib/a-ctx.sh 增事件日志原语(`_a_ev_*`,存储沿用"每行 类型<TAB>JSON"风格)+ `_a_ev_derive` 投影为 OpenAI tool-calling 消息数组 |
| LlmAdapter/prepareCall | lib/a-api.sh:抽出 `_a_api_post`(curl+重试+错误统一,流式/非流式两态),`_a_generate` 与新增 `_a_agent_request` 共用 |
| 工具结果标记约定(`[exit code: N]` 等) | a-tools 各工具输出沿用同款 marker |
| run_in_background/job/沙箱升级审批 | 不做(明确排除) |

分层与依赖方向(只许向上):a-api(L1 传输)→ a-ctx(L2 会话)→ a-exec(L3 执行原语,不动)→ **a-tools(新,工具域)**→ **a-agent(新,循环域)**→ a.sh(产品层)。a.sh source 顺序相应加两行。

## 三、分文件改动明细

### 1. lib/a-api.sh(L1,传输域)
- 抽出 `_a_api_post`:统一 curl -K 密钥文件、SSE/非流式两模式、429/5xx/网络错误指数退避重试。`_a_generate` 改为调用它,**对外行为不变**;若实现中发现抽取风险大,回退方案是 `_a_agent_request` 自带一份重试循环(零碰存量)。
- 新增 `_a_agent_request <msgs_json> <tools_json>`:非流式 POST(带 `tools`/`tool_choice:auto`),成功设全局 `_A_AGENT_CONTENT`(文本)与 `_A_AGENT_TOOL_CALLS`(compact JSON 数组,无则空)并返回 0。agent 步骤不用 SSE——tool_calls 增量聚合复杂度高,收益低,取舍写入 README;run/ask 流式保留。
- 新增 JSON 助手(沿用 jq/python3 双实现惯例):`_a_json_path <点路径>`(通用取值)、`_a_json_tool_calls`(取 `choices[0].message.tool_calls`)、单条 call 的 id/name/arguments 提取(arguments 是 JSON 字符串,需二次解析:jq `fromjson` / python3 `json.loads`)。
- `_a_load_config` 增加 `A_AGENT_MAX_STEPS`(默认 16)、`A_AGENT_MAX_TOKENS`(默认 4096)。

### 2. lib/a-ctx.sh(L2,上下文域)
- 事件日志原语:`_a_ev_append <mode> <类型> <json>`(类型 U=user/message、A=assistant/message、T=tool/result,存 `_A_EV_<mode>` 变量)、`_a_ev_get/_a_ev_clear`。
- `_a_ev_derive <mode>`:投影为 messages 数组——U→`{"role":"user",...}`;A→assistant 原样回放(content+tool_calls 按响应原文存储,保证 id/参数分毫不差);T→`{"role":"tool","tool_call_id":...,"content":...}`。
- 裁剪:完整轮以 U 行为界,从新到旧按 `A_MAX_CONTEXT_CHARS` 预算保留(awk,复用现有 trim 思路);tool 结果在**落日志时**即截断到 4000 字符(对齐现有 R 消息做法),避免投影阶段膨胀。
- `_a_show` 增加 agent 模式渲染:轮 N 用户请求→工具调用名序列→最终回答。
- run/ask 的 Q/A/R 存储不动(事件日志只服务 agent 模式;迁移存量模式到事件日志列为后续可选,不在本轮)。

### 3. lib/a-tools.sh(新,约 350–400 行)
- 注册表:`_a_tool_register <name> <schema_json> <fn>` 写入 `_A_TOOL_NAMES/_A_TOOL_SCHEMAS/_A_TOOL_FUNCS` 三个并行数组;`_a_tools_schema_json` 汇出 `[{type:function,function:{name,description,parameters}}]`;`_a_tool_run` 用计数循环遍历派发(bash/zsh 下标差异安全写法)。
- 管线 `_a_tool_execute <name> <args_json>`(对齐 dsh 三段):
  - pre-execute:展示调用(名称+参数摘要,风险着色),确认门——bash/write/edit 按 `_a_risk` 分级:danger 恒确认(即使 -y)、caution 无 -y 时确认、只读工具自动放行;无终端时 danger 直接拒绝(与 run 模式同语义)。
  - execute:派发工具函数,捕获 stdout 与退出码。
  - post-execute:非零退出码追加 `[exit code: N]`,长输出截尾加 `[output truncated]` 头标记,产出回给模型的文本。
- 会话工作目录 `_A_AGENT_CWD`(默认 agent 启动时 $PWD),bash 工具默认在其中执行;cd 不污染用户 shell(agent 语义与 dsh 一致:每调用独立)。
- 十个工具(参数对齐 dsh 目录):
  1. `bash`{command 必, description 否, workdir 否}——复用 `_a_step_run`(A_STEP_TIMEOUT 看护)+ `_a_risk` 分级;输出含超时标记。
  2. `working_directory`{cd 否}——读/设会话工作目录。
  3. `read`{file_path 必, offset=1, limit=2000}——`N: 行`编号 + `(Showing lines X-Y of Z...)` 页脚。
  4. `write`{file_path 必, content 必}——caution 确认,mkdir -p,全量覆盖。
  5. `edit`{file_path 必, old_string 必, new_string 必, replace_all=false}——唯一性校验(0 处报未找到、多处未开 replace_all 报不唯一),python3 实现。
  6. `grep`{pattern 必, path=., include 否}——rg 可用则用,否则 grep -rEn --include;≤250 行。
  7. `glob`{pattern 必, path=.}——find -type f,≤100 条按 mtime 新→旧。
  8. `todo_write`{todos[{content,status}] 必}——全量替换 + 终端渲染清单 + 计数回执(dsh 协议:模型只看到一句摘要)。
  9. `ask_user_question`{questions[1]{question,header?,options[{label,description?}],multi_select?}}——/dev/tty 编号选择/自由输入,回传 dsh 同构 JSON `{"answers":[{"id","selected":[],"custom":""}]}`;无终端返回跳过语义(selected 空+无 custom)。v1 不做超时(dsh legacy 阻塞式)。
  10. `web_fetch`{url 必}——curl -sL --max-time + python3 html.parser 去脚本样式转文本,截断;失败回错误文本。

### 4. lib/a-agent.sh(新,约 150 行)
- `_a_agent <query> <stdin_data> <auto_yes>`:env 上下文(复用 `_a_env_context`)拼进首条 user 事件 → 循环:derive(裁剪后)→ `_a_agent_request` → 无 tool_calls 则落 assistant 事件、打印最终回答、结束;有则逐个 `_a_tool_execute`(顺序执行,确认 UX 决定不能并行)、逐个落 T 事件 → 步数 +1。
- 步数上限 `A_AGENT_MAX_STEPS`(默认 16),触顶打印提示并落轮次摘要后退出。
- Ctrl-C:trap INT 中止循环,落"用户中断"事件,返回 130(沿用项目语义),trap 恢复。
- 每步终端渲染:`⚙ 步骤 n/N tool(参数摘要)` + 工具输出实时显示。

### 5. a.sh(产品层)
- `_A_MODES=(run ask agent)`(`a -c`/`a --show` 自动覆盖);source 顺序加 a-tools/a-agent。
- 子命令路由:`a agent <任务>`(支持 `-y` 前置);agent 版 system prompt(任务导向、工具使用规范、何时收尾、禁止编造文件名);stdin 管道输入沿用。
- `_a_help`、README.md/README.en.md 增 agent 模式/工具表/新配置项/非流式取舍说明;`A_VERSION=0.6.0`。

### 6. win/ PowerShell 镜像(逐文件对应)
- win/lib/a-api.ps1、a-ctx.ps1 增对应函数;新建 win/lib/a-tools.ps1、a-agent.ps1(注册表用 hashtable,更直接);win/a.ps1 加 agent 子命令/模式/帮助/版本;win/test.ps1 加同源测试。bash 工具在 win 侧执行 PowerShell 命令(与现有 win/a-exec.ps1 语义一致)。

## 四、测试计划(test.sh 现有自研框架内)

- mock 服务新增标记词:`AGENTLOOP`(依次返回 bash 工具调用→read 调用→最终文本,验证全链路)、`AGENTASK`、`AGENTTODO`、`AGENTLOOPFOREVER`(恒返 tool_calls,验证步数上限)、`AGENTDANGER`(无终端拒绝 danger)。
- 新增单元段:注册表/派发、事件日志 append+derive 消息形状(jq 断言 role/tool_call_id)、read/write/edit/grep/glob/tmp 文件用例、todo/ask_user 无终端分支、工具结果截断与退出码标记。
- 新增全链路段:多步工具循环→最终回答、上下文裁剪、-y 与确认路径(expect 走伪终端)。
- 预计新增 35–45 项断言;验收=存量 129 + 新增全绿,win 侧存量 109 + 新增全绿。

## 五、实施顺序(每阶段末跑全量测试)

1. bash:a-api(POST 抽取+agent 请求+JSON 助手)+ a-ctx(事件日志/投影)+ 单测
2. bash:a-tools(注册表+管线+10 工具)+ 单测
3. bash:a-agent 循环 + a.sh 产品层 + mock 全链路 + README/help/版本
4. win:逐文件镜像 + 测试
5. 双平台全量回归 + `bash -n a.sh && zsh -n a.sh` + 手工冒烟(真实提供商跑 `a agent "看看当前目录并统计文件数"`)

## 六、明确不做(后续批次候选)

run_code(PTC)、terminal_*/持久 shell、subagent/team/workflow/ralph、schedule_*、goal、lsp、apply_patch、read_image、web_search(需搜索 API key)、session 检索 5 件套、MCP——均依赖重型基建或常驻宿主,dsh 目录中对应条目已在调研中逐一定性;存量 run/ask 迁移到事件日志也留作后续。

## 七、风险与对策

- **提供商 tool-calling 支持参差**(ollama 取决于模型):文档标注;请求带 tools 报 400 时错误信息如实透出并提示换模型。
- **POST 抽取动 `_a_generate`**:存量重试/流式测试(RATELIMIT/RETRYME 等)是等价性闸门;不通则立即回退为独立重试循环方案。
- **bash 3.2/zsh 双兼容**:不用关联数组/nameref,数组遍历用计数循环,PIPESTATUS/pipestatus 双取(全部沿用项目既有惯例)。
- **不提交**:所有改动停留在工作区,验收后等用户明确下令再 commit(pre 纪律)。
