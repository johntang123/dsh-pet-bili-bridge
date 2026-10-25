# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.1.0] - 2026-10-25

首个可用版本。定位是**连接器**，不含桌宠与 bili-scroll 本体。

### 新增

- `bin/pet-bridge.ps1`：常驻 watcher，只读 tail `duty.log`，把 bili-scroll 的一轮
  翻译成桌宠六态（`working` / `attention` / `error` / `idle`），带去重、1MB 轮转、
  日志轮转重置、不完整行缓冲。
- `bin/emit.ps1`：单次写事件，供 WorkBuddy hooks 调用；连续同状态直接 exit 0。
- `install.ps1` / `install.bat`：一键部署 + 幂等合并桌宠 `config.json`
  （只增改 `agent_link.custom_agents` 里的 `bili` / `workbuddy` 两项，改前备份）。
- `uninstall.ps1`：停进程、删启动项、摘配置、删目录；`-Purge` 连事件一起清。
- `workbuddy-plugin/`：WorkBuddy 本地插件市场，含 `wb-pet-bridge` 插件与
  `SessionStart` / `PreToolUse` / `SessionEnd` 三个 hooks。
- `tools/build-package.ps1`：打绿色 zip（解压即用）。
- `docs/ARCHITECTURE.md`：两者结合分析——三条接缝的取舍，为什么走文件总线。
- `docs/PET-CONFIG.md`、`docs/TROUBLESHOOT.md`。

### 设计决定（记录以免日后反复讨论）

- **不改上游一行代码**。走桌宠公开的 `agent_link.custom_agents` 协议，
  而不是把 `dsh-pet-bridge` 塞进 bili 的 `bili-duty` profile——后者会削弱那轮会话的最小权限沙箱。
- **信号源选 `duty.log` 而非 dsh 内部事件**。bili-scroll spawn 的是独立 `dsh --profile bili-duty`
  子进程，桌宠内置桥接插件（装在 `web` profile）收不到它的事件。
- **成功结束用 `attention` 而不是直接 `idle`**。日报确实需要人看一眼；
  但加了 45s 定时回落，避免桌宠永远停在注意态。
- **PowerShell 而非 Node/Python**。Windows 自带，零运行时依赖，绿色包才能做到"解压就能用"。

### 已知限制

- 依赖 bili-scroll 硬编码的中文日志锚点，上游改文案会静默失配。
- WorkBuddy 目前只确认存在 `SessionStart` / `SessionEnd` / `PreToolUse` 三个 hooks 事件。
- `PreToolUse` 每次起一个 PowerShell 进程（约 0.2–0.4s），可手动关闭。
- macOS / Linux 的 watcher 未实现（协议跨平台，但脚本只写了 PowerShell 版）。
