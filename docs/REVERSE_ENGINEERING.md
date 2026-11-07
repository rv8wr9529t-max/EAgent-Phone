# 逆向分析笔记：EAgent.exe 的工作原理

原版 EAgent.exe（~2.3MB，32 位 PE，易语言编译）本质上是一个**嵌入式脚本壳**。以下是其内部结构与协议（本项目据此实现了兼容宿主）。

## 1. 资源布局

| 区段 | 内容 |
|---|---|
| `.rdata`（约 1.4MB）| 以明文嵌入的 3 个 PowerShell 脚本（UTF-8 BOM）、GBK 编码的 GUI 模板串、GBK 系统提示词、一个 ZIP（中央目录 152 条目，`PK\x03\x04` @ `0xCE041` ~ EOCD @ `0x11A746`） |
| 字符串特征 | `SkinH_SetWindowAlpha`（界面皮肤库）、`Scripting.RegExp` COM（标记解析）、Gdiplus（截图） |

## 2. 内嵌脚本

| 脚本 | 职责 |
|---|---|
| `1_启动调试浏览器.ps1` | 以 `--remote-debugging-port=9222` + 专用 profile 启动 Chrome/Edge 并打开 chat.deepseek.com，轮询 `/json/version` 等待就绪 |
| `2_发送并等待回复.ps1` | CDP WebSocket：`textarea` 注入消息 → Enter 发送 → 轮询 `.ds-assistant-message-main-content` 最后一条文本至「连续 7 个 tick 不变」视为完成，写入 `reply.txt`（GBK）；支持 `DOM.setFileInputFiles` 上传附件 |
| `3_关闭浏览器.ps1` | CDP `Browser.close` |

## 3. 主循环（易语言 GUI 完成）

1. 用户输入 → Base64 → 调脚本 2（`-MessageB64`，可带 `-Files`）
2. 解析回复中的工具标记代码块（识别头/尾注释为界）：
   - `powershell_tool` → 写入临时 `ps_xxxx.ps1` 执行，输出 Tee 到 `out.txt`，截 4K 回传
   - `agent_getjpg` → GDI+ 全屏/句柄截图，存 `屏幕截图.jpg`，作为下轮附件上传
   - `agent_getfile` → 校验（单文件 ≤100MB、≤50 个），作为下轮附件上传
   - `agent_mouse_simulate` → 逻辑坐标移动 + 点击（0~3：左单/左双/右单/右双）
   - `agent_keyboard_simulate` → 虚拟键码按键，第 4 参可置前目标窗口
3. 危险操作（PowerShell）弹原生确认框：「询问：用户是否允许执行？」
4. 结果以 `//[工具][取回结果]// … //[END]//` 等模板作为新用户消息回传，循环直至 AI 不再调工具。

## 4. 系统提示词

GBK 存储，约 8.4K 字符，含 `{{WORKDIR}}` / `{{TEMP_WORKDIR}}` 占位符。核心约束：单轮只能调一个工具、代码块外不出现文字、单轮 ≤4K 字符、优先逻辑坐标、破坏性操作需确认。

## 5. 复刻时的坑

- **杀软行为检测**：远程控制 + 模拟键鼠 + 命令执行的特征组合会触发火绒等主动防御（隔离区实测命中）。对策：主程序存为 `.txt`、由启动器读入内存以 `scriptblock` 执行；运行时临时目录收进包目录，方便一条信任规则覆盖。
- **内存加载的路径发现**：`[scriptblock]::Create` 出来的脚本里 `$MyInvocation.MyCommand.Definition` 返回的是**全文文本**而非路径，必须显式注入安装目录参数。
- **跨 runspace 共享状态**：`[ArrayList]::Synchronized` 包装器在 runspace 间取值不可靠；改用普通 `ArrayList` + 锁宿主线程共享的 `SyncRoot`。
- **Chrome 136+ 限制**：默认 profile 禁用 CDP 调试端口，必须自定义 `--user-data-dir`（原版即如此，登录态保存在该 profile 内）。
