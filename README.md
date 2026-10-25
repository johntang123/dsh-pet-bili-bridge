# dsh-pet-bili-bridge

**让蓝色大肥鱼知道你在干活 —— 桌宠 × B站值班 × WorkBuddy 的本地状态桥。**

<p align="center">
  <code>dsh-bili-scroll</code> · <code>dsh-pet-indesktop</code> · <code>WorkBuddy</code>
</p>

---

## 这是什么

一个**只做连接**的小工具，不重复实现任何已有功能：

- 你装了 [dsh-pet-indesktop](https://github.com/MerZlin/dsh-pet-indesktop)（桌宠）——它只会读一个 JSONL 事件文件
- 你装了 [dsh-bili-scroll](https://github.com/c1overzz/dsh-bili-scroll)（每天替你刷 B站出日报）——它只会写自己的 `duty.log`
- 你在用 WorkBuddy 干活——它有 hooks，但没人告诉桌宠

三者各说各话。本插件把话接上：

```
dsh-bili-scroll  ──写──▶  duty.log  ──tail──▶  ┐
                                              ├─▶  agents/*.jsonl  ──读──▶  dsh-pet 桌宠
WorkBuddy hooks  ──写──▶  emit.ps1   ─────────┘
```

结果：

- B站值班开跑 → 桌宠开始动起来，弹「开始干活」
- 日报写好了 → 弹「需要你看一眼～」
- 一轮报错 → error 音效 + 「好像遇到报错了…」
- 你让 WorkBuddy 干活 → 同一只桌宠同样有反应

**不联网、不改上游一行代码、不读任何正文内容。**

---

## 快速开始（Windows）

### 0. 先装好两个上游

| 上游 | 怎么装 |
|---|---|
| 桌宠 | 去 [Releases](https://github.com/MerZlin/dsh-pet-indesktop/releases) 下 `dsh-pet-standalone-webm-chat-setup.exe`，或绿色版 zip |
| B站值班 | 在 DSH 里 `dsh plugin --profile web add dsh-bili-scroll`，然后重启 DSH、进设置页装依赖、扫码登录 |

> 桌宠安装包**未做代码签名**，SmartScreen 会拦：点「更多信息 → 仍要运行」。
> 如果你是 Win11 + 150% 缩放，建议先用绿色版试水（上游 issue #286 曾报过不可见问题）。

### 1. 解压本包，双击 `install.bat`

或者命令行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Autostart
```

脚本会：

1. 把 watcher 部署到 `%LOCALAPPDATA%\dsh-pet-bili-bridge`
2. **备份**桌宠 `config.json`，然后只往 `agent_link.custom_agents` 里加两项（`bili` / `workbuddy`）
3. （加 `-Autostart` 时）注册到启动文件夹，隐藏窗口运行
4. 检查 `bili-duty` 目录在不在

### 2. 重启桌宠，勾开关

右键桌宠（或托盘图标）→ **Agent 联动** → 勾选「**B站值班**」「**WorkBuddy**」。

> 所有 Agent 联动**默认全关**，这是上游的安全默认值，必须手动勾一次。

### 3.（可选）让 WorkBuddy 也参与

把 `workbuddy-plugin` 整个目录添加为 WorkBuddy 的**本地插件市场**，然后装上 `wb-pet-bridge`。

---

## 怎么验证它真的在工作

```powershell
# 1. 手动起一轮 watcher，看看它读到什么
powershell -NoProfile -ExecutionPolicy Bypass -File bin\pet-bridge.ps1 -Once

# 2. 看事件文件
Get-Content "$HOME\.dsh-pet-bridge\agents\bili.jsonl" -Tail 10

# 3. 看 watcher 自己的日志
Get-Content "$HOME\.dsh-pet-bridge\agents\pet-bridge.log" -Tail 20

# 4. 手动喂一个状态，看桌宠有没有反应
powershell -NoProfile -ExecutionPolicy Bypass -File bin\emit.ps1 -State working -Agent bili
```

第 4 步如果桌宠没反应，问题不在本插件，检查：桌宠是否重启过、右键菜单里那个 Agent 的开关是否勾上。

---

## 目录结构

```
dsh-pet-bili-bridge/
├── install.bat / install.ps1        一键安装
├── uninstall.ps1                    干净卸载（只删自己写的）
├── bin/
│   ├── pet-bridge.ps1               常驻 watcher：tail duty.log → 六态
│   └── emit.ps1                     单次写事件（给 WorkBuddy hooks 用）
├── workbuddy-plugin/                WorkBuddy 本地插件市场
│   ├── .codebuddy-plugin/marketplace.json
│   └── plugins/wb-pet-bridge/
│       ├── .codebuddy-plugin/plugin.json
│       ├── hooks/hooks.json         SessionStart / PreToolUse / SessionEnd
│       └── scripts/emit.ps1
├── docs/
│   ├── ARCHITECTURE.md              两者结合分析（为什么这么接、为什么不能更紧）
│   ├── PET-CONFIG.md                手动配置桌宠
│   └── TROUBLESHOOT.md              故障排查
└── tools/build-package.ps1          打绿色 zip
```

---

## 系统要求

- **Windows 10 / 11**（当前主力平台，PowerShell 5.1 即可，无需装任何东西）
- 桌宠：任意版本（只要支持 `agent_link.custom_agents`，即 v4.x）
- B站值班：v2.x（日志锚点基于其硬编码文案）
- 可选：WorkBuddy（用于 WorkBuddy 侧联动）

> macOS / Linux 理论上可用（协议是跨平台的），但本包的 watcher 只实现了 PowerShell 版，
> 需自行用 bash + `tail -c` 改写。**未实机验证，标 preview。**

---

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

做四件事：停进程 → 删启动项 → 从 `config.json` 摘掉本插件那两项（先备份）→ 删程序目录。
事件与日志默认保留（里面有排障信息），加 `-Purge` 一并删除。

---

## 发布到 GitHub（给自己存档用）

`github.com:443` 在部分网络/代理下会直接 502，`git push` 根本连不上。
仓库里带了一个走 REST API 的推送脚本，不依赖 git 协议：

```powershell
$env:GITHUB_TOKEN = 'ghp_xxx'      # github.com/settings/tokens，classic 勾 repo
powershell -NoProfile -ExecutionPolicy Bypass -File tools\push-to-github.ps1 -Insecure
```

- 自动建仓（已存在则复用）、逐文件建 blob、一次提交、推 `main`
- `-Insecure` 只在公司代理做了 SSL 中间人时需要
- HTTP 层用系统自带 `curl.exe`，不是 `Invoke-RestMethod`。后者在代理环境下
  TLS 握手会直接失败（"基础连接已经关闭"），实测走不通

---

## 已知限制（请先读）

1. **依赖上游日志文案**。`刷B站开跑` / `刷B站结束` 这些是 dsh-bili-scroll 里硬编码的中文串。
   上游哪天改了措辞，桥接就会静默不触发（不报错、不影响 bili-scroll，只是桌宠不动）。
2. **WorkBuddy 只有三个钩子能用**。`SessionStart` / `PreToolUse` / `SessionEnd`。
   想要"任务真正结束"的精确信号，目前拿不到——`SessionEnd` 在会话收尾时才触发。
3. **`PreToolUse` 每次起一个 PowerShell 进程**（约 0.2–0.4s）。介意就把 `hooks.json`
   里那一段删掉，只保留开始/结束。
4. **不是"安装包"，是"连接器"**。它不含桌宠本体，也不含 bili-scroll 本体，两者按各自方式装。
5. **不改上游代码是刻意的**。patch 别人的项目意味着每次上游更新都要合并冲突，
   而走公开协议（`custom_agents` + `hooks`）可以一直免维护。
6. **桌宠侧链路已实测，WorkBuddy 侧链路未实机验证**。
   `pet-bridge.ps1` / `emit.ps1` 在 Windows PowerShell 5.1 下跑过 5 个场景（成功 / 非 0 退出 /
   spawn 失败 / 带 BOM 日志 / 被锁跳过）全部通过；`config.json` 合并做过幂等与
   "Python 能否解析"的验证。
   但 **WorkBuddy 加载本地插件市场这一步没有实机跑通**——插件清单（`marketplace.json` /
   `plugin.json` / `hooks.json`）是照 WorkBuddy 内置插件的真实结构写的，
   而"能不能从任意本地目录添加为市场"取决于客户端是否放开了这个入口。
   如果加不进去，WorkBuddy 侧可以退化成手动：把 `SessionStart` / `SessionEnd` 的写事件
   命令挂到你自己的 hook 配置里，脚本本身是通的。

---

## 为什么不做成一个完整"全家桶"

因为三个项目的更新节奏完全不同：

| 项目 | 更新重点 | 耦合进来的后果 |
|---|---|---|
| 桌宠 | Qt / 动画 / 性能，几乎每周发版 | 每次发版你都要重新打包一次 |
| B站值班 | B站接口 / 提示词 / 风控 | 接口一变全家桶全挂 |
| WorkBuddy | 客户端整体升级 | 你的包立刻过时 |

连接器模式让三者各自升级，桥不用动。**代价是**安装步骤多一点——这是有意的取舍。

---

## 致谢

- [MerZlin/dsh-pet-indesktop](https://github.com/MerZlin/dsh-pet-indesktop) — MIT，桌宠本体与其公开的事件协议（`docs/AGENT_LINK_PROTOCOL.md` 是本文档最重要的参考）
- [c1overzz/dsh-bili-scroll](https://github.com/c1overzz/dsh-bili-scroll) — MIT，B站值班插件
- 本包为独立集成层，**不包含也不二次分发**上述两个项目的任何代码。

## License

MIT
