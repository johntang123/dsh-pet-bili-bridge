# 手动配置桌宠（不使用 install.ps1 时）

> 如果你已经跑了 `install.ps1`，这一步**已经自动做过了**，本文仅作备份与参考。

## 1. 找到 config.json

| 平台 | 路径 |
|---|---|
| Windows | `%APPDATA%\dsh-pet-standalone-<变体>\config.json` |
| macOS | `~/Library/Application Support/dsh-pet-standalone-<变体>/config.json` |
| Linux | `~/.config/dsh-pet-standalone-<变体>/config.json` |

`<变体>` 形如 `webm-chat`（带 AI 对话）或 `webm`（不带）。装的是哪个就用哪个目录。

> 注意：同一变体的新旧版本**共用同一个数据目录**，升级会就地改写。改配置前先备份。

## 2. 加这一段

在顶层对象里加入（若已有 `agent_link`，只加/改 `custom_agents` 数组，别覆盖别的键）：

```jsonc
{
  "agent_link": {
    "custom_agents": [
      {
        "key": "bili",
        "name": "B站值班",
        "path": "~/.dsh-pet-bridge/agents/bili.jsonl"
      },
      {
        "key": "workbuddy",
        "name": "WorkBuddy",
        "path": "~/.dsh-pet-bridge/agents/workbuddy.jsonl"
      }
    ]
  }
}
```

## 3. 字段约束（来自 AGENT_LINK_PROTOCOL.md）

| 字段 | 约束 |
|---|---|
| `key` | 正则 `^[a-z0-9][a-z0-9_-]{0,31}$`，**不得**与内置键 `dsh` / `claude` / `cursor` / `opencode` 重名，全局唯一 |
| `name` | 气泡和右键菜单里显示的名字，留空则用 key |
| `path` | 事件文件路径，支持 `~` 展开；**文件不必预先存在**，不存在时静默等待 |

其余限制：

- 最多 **8 个** 自定义条目
- 改动后**必须重启桌宠**（或使用它的"重新加载配置"）才生效
- 所有 Agent 联动**默认全关**，重启后要自己去勾：

  > 右键桌宠（或托盘）→ **Agent 联动** → 勾选「B站值班」「WorkBuddy」

## 4. 事件文件长什么样

正常运行时 `~/.dsh-pet-bridge/agents/bili.jsonl` 会是这样：

```jsonl
{"ts":1750000000.123,"agent":"bili","state":"working"}
{"ts":1750000180.456,"agent":"bili","state":"attention"}
{"ts":1750000225.789,"agent":"bili","state":"idle"}
```

六态取值（协议统一词汇）：`thinking` / `working` / `attention` / `error` / `idle` / `sleeping`。

## 5. 不想用默认路径

只要 `config.json` 里的 `path` 和 `pet-bridge.ps1 -EventDir` 指向同一目录即可，例如：

```jsonc
{ "key": "bili", "name": "B站值班", "path": "D:/pet-events/bili.jsonl" }
```

对应启动参数：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File pet-bridge.ps1 -EventDir "D:\pet-events"
```
