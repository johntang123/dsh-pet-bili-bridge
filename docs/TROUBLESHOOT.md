# 故障排查

按"现象 → 查什么 → 怎么修"的顺序排。

---

## 桌宠完全不动

**这是最常见的，90% 是开关没勾。**

1. 右键桌宠 / 托盘 → **Agent 联动**，确认「B站值班」「WorkBuddy」是勾上的。
   > 上游默认全关，且**每次升级后可能回到默认**，升级完要重勾。
2. 确认改完 `config.json` 后**重启过桌宠**。
3. 手动喂一条事件，排除是 watcher 的问题：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File bin\emit.ps1 -State working -Agent bili
   Get-Content "$HOME\.dsh-pet-bridge\agents\bili.jsonl" -Tail 3
   ```

   - 文件里有新行、桌宠还是不动 → 问题在桌宠侧（开关 / 重启 / 该版本不支持 custom_agents）
   - 文件里没新行 → 问题在 emit.ps1（看下面）

---

## emit.ps1 写不进去

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File bin\emit.ps1 -State working -Agent bili
echo $LASTEXITCODE    # 应该是 0
```

- **exit 0 但文件没变** → 触发了去重。先看 `.bili.state` 里是不是已经是 `working`：

  ```powershell
  Get-Content "$HOME\.dsh-pet-bridge\agents\.bili.state"
  ```

  连续同一状态会被跳过，这是有意的（避免占住桌宠端换帧节流位）。
- **报"无法加载文件，因为在此系统上禁止运行脚本"** → 执行策略问题。用
  `-ExecutionPolicy Bypass` 参数调用，或（不推荐）改全局策略。

---

## watcher 起来了，但一轮跑完没有事件

```powershell
Get-Content "$HOME\.dsh-pet-bridge\agents\pet-bridge.log" -Tail 30
```

对照三件事：

1. **duty.log 路径对不对？** 日志里启动那行会打印 `biliHome=...`。
   不对就显式指定：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File bin\pet-bridge.ps1 -BiliHome "D:\your\dsh-home\bili-duty"
   ```

2. **bili-scroll 真的跑过吗？** 看 `duty.log` 里有没有 `刷B站开跑`：

   ```powershell
   Select-String -Path "$HOME\.dsh\bili-duty\duty.log" -Pattern '刷B站' | Select-Object -Last 5
   ```

   一条都没有 → 它自己没跑，与本插件无关。

3. **文案是不是变了？** 如果日志里是别的说法（上游改版），watcher 会静默失配。
   临时办法：改 `pet-bridge.ps1` 里的 `-match '刷B站开跑'` 等几处正则。

> watcher 启动时**从文件末尾开始读**，不会回放历史。想验证历史段，
> 加 `-FromStart -Once` 手工跑一次。

---

## 桌宠一直停在"工作"状态回不来

正常情况下：成功结束 → `attention` 45 秒 → `idle`；报错 → `error` 90 秒 → `idle`。

如果卡住：

- 说明 watcher 进程死了，`attention`/`error` 之后没人写 `idle`。
  查进程：`Get-CimInstance Win32_Process | Where-Object CommandLine -like '*pet-bridge.ps1*'`
- 临时手动恢复：`... -File bin\emit.ps1 -State idle -Agent bili`

---

## 提示"发现多个桌宠数据目录"

你装过多个变体（比如 `webm-chat` 和 `webm`），或者新旧版本目录并存。指定一个：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -PetConfig "$env:APPDATA\dsh-pet-standalone-webm-chat\config.json"
```

不确定哪个是正在用的：

```powershell
Get-ChildItem "$env:APPDATA\dsh-pet*" -Directory | ForEach-Object {
  "$($_.Name)`t$((Get-Item "$($_.FullName)\config.json" -ErrorAction SilentlyContinue).LastWriteTime)"
}
```

`LastWriteTime` 最新的那个就是你在用的。

---

## WorkBuddy 侧没反应

1. 插件市场加的是 `workbuddy-plugin` **目录本身**（里面要有 `.codebuddy-plugin/marketplace.json`），
   不是它的上级目录，也不是 `plugins/wb-pet-bridge`。
2. 装完插件后**开一个新会话**再试（`SessionStart` 只在会话开始时触发）。
3. 直接验脚本能不能跑：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File workbuddy-plugin\plugins\wb-pet-bridge\scripts\emit.ps1 -State working
   ```

4. 介意开销的话，把 `hooks/hooks.json` 里的 `PreToolUse` 整段删掉，只留开始/结束。

---

## 卸载后桌宠配置变成一行了

`install.ps1` / `uninstall.ps1` 用 `ConvertTo-Json` 重写文件，会把原来的多行缩进**压平**。
数据一个字节都没丢，但看着难受。

想恢复原样：每次改写前都自动备份在 `config.json.bak-<时间戳>`，直接拷回去即可：

```powershell
Copy-Item "$env:APPDATA\dsh-pet-standalone-webm-chat\config.json.bak-20261025-190000" `
          "$env:APPDATA\dsh-pet-standalone-webm-chat\config.json" -Force
```
