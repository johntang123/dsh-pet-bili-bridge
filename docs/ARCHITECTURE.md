# 两者结合分析：dsh-pet × dsh-bili-scroll

> 本文回答一个问题：这两个项目能不能拼起来，拼在哪里，为什么不能更"紧"。
> 所有结论来自两个仓库的实际源码（`dsh-pet-indesktop` v4.3.4 / `dsh-bili-scroll` v2.2.0），不是推测。

---

## 1. 先看清两者是什么

| | dsh-pet-indesktop | dsh-bili-scroll |
|---|---|---|
| 形态 | 独立桌面程序 | DSH 插件（Cordis bundle） |
| 技术栈 | Python 3.10+ / PySide6(Qt) / PyInstaller | Node.js ≥22 + 内置 Python MCP |
| 谁启动它 | 用户双击 / 开机自启 | DSH 宿主加载，或 `dsh plugin add` |
| 主要产出 | 屏幕上的动画、气泡、音效 | `out/<日期>.md` 日报 + B站评论 |
| 对外接口 | **只读** JSONL 事件文件 | 写 `duty.log`、`out/*.md`、`state.json` |
| 联网 | 除 AI 对话外不联网 | 通过 bilibili-mcp 访问 B站 |

**一句话**：一个是**呈现层**（把"正在发生什么"画出来），一个是**执行层**（真的去干活）。
它们没有功能重叠，正好互补——这是能结合的前提。

---

## 2. 三个可能的接缝，只有一个能用

### ❌ 接缝 A：把 dsh-bili-scroll 当 WorkBuddy 插件装

不行。它是 **DSH 插件**，靠 `cordis.patch.yml` 往 DSH 的插件树里 insert，依赖
`@deepseek-ai/dsh-tools`、`@deepseek-ai/schemastery`、`dsh` 宿主的注入服务。
WorkBuddy 的插件位是 Skill / Connector / Expert，没有 DSH 的 Cordis 容器。

### ❌ 接缝 B：让桌宠自带的 dsh-pet-bridge 去监听 bili 的那一轮

看起来最"正统"，实际**收不到**。

```
桌宠的 dsh-pet-bridge 装在 profile: web  →  只订阅 web 这个 dsh 进程内的事件
bili-scroll 跑一轮 = spawn 一个全新的 dsh --profile bili-duty 子进程
```

`integrations/dsh-pet-bridge/index.js` 里 `INSTANCE_FILE = dsh-${process.pid}.jsonl`，
它是**进程内插件**，订阅的是自己宿主的事件。bili-duty 是另一个 profile、另一个进程，
它里面的插件树根本不包含这个桥接插件（`profile-template/bili-duty/cordis.yml` 是空根，
只叠 bili-scroll 自己的 patch）。

> 补救办法是把 dsh-pet-bridge 也装进 bili-duty profile。代价：bili-scroll 反复强调
> 那一轮跑在"最小权限沙箱"（无 fs / 无 shell / 无 web），多插一个插件等于削弱它的安全设计。

### ✅ 接缝 C：走桌宠的「自定义 Agent 通道」（本方案）

`docs/AGENT_LINK_PROTOCOL.md` §4 明确支持：

> 不改代码即可接入**任何能写本地文件的 Agent**

```
config.json → agent_link.custom_agents[{ key, name, path }]
桌宠对 path 指向的 JSONL 做只读 tail（1.5s 轮询，byte-offset 增量，不回放历史）
```

这是**唯一**同时满足「零改动上游」「不削弱沙箱」「跨版本稳定」的接缝。

---

## 3. 信号从哪来：为什么盯 duty.log

bili-scroll 跑一轮时，唯一稳定输出到外部的是 `duty.log`，而且它的文案是硬编码的：

| 日志行（源码位置） | 含义 |
|---|---|
| `刷B站开跑（${why}）：...` | 一轮开始，子进程已 spawn |
| `刷B站结束（${why}，code=${code}）` | 一轮结束，code 是退出码 |
| `刷B站起不来：...` | spawn 失败 |
| `刷B站开跑失败（${why}）：...` | 异常抛出 |
| `这一轮没跑（${why}）` | 被锁或闸门拦住，不是错误 |
| `今天挑到 ${picked} 条` | 本日累计选中数 |

比"猜 dsh 内部事件"稳得多，也比"看进程表里有没有 bili-duty"精确。

**风险（必须知情）**：上游改文案就会失配。桥接层做了两层兜底——
1) 匹配用宽松片段（`刷B站开跑` 而非整行）；
2) 失配时 watcher 只是不写事件，**不会报错、不会影响 bili-scroll**，最坏情况是桌宠不动。

---

## 4. 数据流

```
┌──────────────────────────────────────────────────────────────┐
│  DSH                                                          │
│   ┌────────────────────┐                                      │
│   │ dsh-bili-scroll    │                                      │
│   │  定时 tick / 手动   │                                      │
│   └─────────┬──────────┘                                      │
│             │ spawn(dsh --profile bili-duty)                  │
│             │ + appendFileSync(duty.log)                      │
└─────────────┼────────────────────────────────────────────────┘
              ▼
      <DSH_HOME>/bili-duty/duty.log
              │
              │  只读 tail（1s，byte-offset 增量，从末尾开始）
              ▼
   ┌──────────────────────────┐
   │  pet-bridge.ps1          │   六态映射 + 去重 + 1MB 轮转
   │  （本插件，零依赖）        │
   └────────────┬─────────────┘
                │ append JSONL
                ▼
   ~/.dsh-pet-bridge/agents/bili.jsonl
                │
                │  桌宠 ByteOffsetTailer 只读 tail
                ▼
   ┌──────────────────────────┐
   │  dsh-pet（Qt 桌宠）        │  → 动画 / 气泡 / 音效
   └──────────────────────────┘

   同一条总线上的第二个写方：

   WorkBuddy hooks ── emit.ps1 ──▶ agents/workbuddy.jsonl
```

两条通道**互不干扰**：`agent` 字段不同、文件不同、桌宠侧是两个独立的监视器。
任何一条挂了，另一条照常。

---

## 5. 状态映射表

| 触发 | 桌宠看到 | 表现 |
|---|---|---|
| 一轮开跑 | `working` | 联动动作池轮换（写代码/吃 Token），可选"开始干活"气泡 |
| 本轮成功结束 | `attention` | 重要气泡"需要你看一眼～"——对应"日报写好了" |
| `attention` 保持 45s 后 | `idle` | 恢复待机；busy→idle 会触发"干完活啦"完成通知 |
| 本轮非 0 退出 / spawn 失败 | `error` | 重要气泡 + error 音效 |
| `error` 保持 90s 后 | `idle` | 恢复待机 |
| 被锁 / 闸门拦住（"这一轮没跑"） | `attention` | 轻提示，15s 后回 `idle` |
| "今天挑到 N 条" | `working` | 保持在工作态，不打断 |

设计取舍：成功结束用 `attention` 而不是直接 `idle`，因为"日报写好了"确实需要人看一眼；
但一直停在 `attention` 桌宠就不回待机，所以加了定时回落。

---

## 6. WorkBuddy 侧为什么只能用三个钩子

从应用包实测，WorkBuddy 的 hooks 格式与 Claude Code 完全一致：

```json
{"hooks": {"SessionStart": [{"hooks": [{"type":"command","command":"...","timeout":5}]}]}}
```

但**能确认存在的事件只有三个**：`SessionStart` / `SessionEnd` / `PreToolUse`
（`UserPromptSubmit`、`PostToolUse`、`PostToolUseFailure`、`SubagentStop` 在应用包里
检索不到）。所以映射只能是：

| WorkBuddy 钩子 | 写到桌宠的状态 |
|---|---|
| `SessionStart` | `thinking` |
| `PreToolUse`（无 matcher，即全部工具） | `working` |
| `SessionEnd` | `idle` |

代价：每次工具调用起一个 PowerShell 进程（约 0.2–0.4s）。
缓解：`emit.ps1` 会先去重（连续同一状态直接 exit 0，不起文件写），
且 `-NonInteractive -NoProfile` 已经是启动最快的方式。
如果你介意这点开销，删掉 `hooks.json` 里的 `PreToolUse` 段即可，只保留开始/结束。

---

## 7. 边界与红线

本插件严格遵守两个上游各自的约定：

- **只写元数据**：事件文件里只有 `ts` / `agent` / `state`，不含视频标题、字幕、命令、路径。
- **不联网**：全程本地文件读写，无任何 HTTP。
- **不改上游代码**：不改 dsh-pet 一行 Python，不改 dsh-bili-scroll 一行 JS。
- **不动上游数据**：对 `duty.log` 只读；对桌宠 `config.json` 只在安装时增改 `agent_link.custom_agents`
  里的两项，其余键原样保留，且改前自动备份。
- **失败即静默**：任何写事件失败都不抛给宿主——联动是锦上添花，不能拖慢干活的那个。
