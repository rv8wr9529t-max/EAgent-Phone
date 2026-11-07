# EAgent-Phone —— 用手机命令 AI 控制你的电脑

![License](https://img.shields.io/badge/license-GPL--3.0-blue)
![Platform](https://img.shields.io/badge/platform-Windows-0078D6)
![Language](https://img.shields.io/badge/language-PowerShell-5391FE)
![Deps](https://img.shields.io/badge/deps-0-brightgreen)

> 零依赖、纯 PowerShell 实现：电脑跑一个小服务，**手机浏览器就是你的遥控器** ——
> 聊天式下命令，由 DeepSeek 网页版驱动，AI 能执行 PowerShell、截图、读文件、模拟键鼠，全程在手机上可见、可控、可审批。
>
> 本项目是对 [EAgent](https://github.com/YaoGaoChaoLe/EAgent)（GPL-3.0）的**协议逆向 + 手机端重建**，把原版的电脑 GUI 换成了随身可用的手机网页控制台。

---

## ⚠️ 安全警告（务必先看）

**这个工具把电脑的操作权交给了「持有链接的人 + AI」。**

- Agent 拥有你电脑上几乎完整的能力：执行任意 PowerShell、截图、访问文件、模拟键鼠。
- 访问密钥 `key` = 唯一防线。**不要泄露链接，不要在公共 Wi-Fi 使用，不要裸奔映射到公网。**
- 远程控制 + 模拟键鼠 的行为特征与远控木马重合，杀软（火绒等）会拦截，属正常现象，需要在杀软里加信任。

请仅在可信局域网内、对自己拥有的设备使用。

## 架构

```
 手机浏览器 ── 局域网 HTTP ──> Agent (PowerShell, 本机服务)
                                  │ CDP (Chrome DevTools Protocol)
                                  ▼
                     chat.deepseek.com（调试模式浏览器）
                                  │ AI 输出工具标记
                                  ▼
        ┌─────────┬─────────┬──────────┬──────────┐
   PowerShell   屏幕截图   上传文件    模拟鼠标   模拟键盘
        └─────────┴──── 执行结果/文件回传给 AI ────┘
                                  ▼
                    循环直至完成，手机全程可见
```

- 与原版 EAgent 协议完全兼容：同一套系统提示词、五类工具标记、回传格式、skill 包。
- 无 Python、无 Node、无编译依赖 —— 只要 Windows 自带的 PowerShell 5.1 + Chrome/Edge。

## 功能

- 💬 **聊天式遥控**：手机上打字 → AI 在你的电脑上干活
- 📷 **实时看屏**：一键查看电脑屏幕截图
- ⚠️ **执行审批**：AI 要跑 PowerShell 时，手机弹确认框，允许/拒绝你说了算（120 秒超时自动拒绝）
- 📁 **文件收发**：AI 的成果文件在手机上直接浏览、下载
- ♻️ **会话管理**：一键新会话重建 AI 上下文
- 🧠 **skill 体系**：内置原版 152 个技能条目，AI 干专业活有现成套路
- 🛡️ **密钥鉴权**：随机 8 位 key，启动时打印在控制台

## 快速开始

> **第 0 步（国内杀软用户必做）**：把整个文件夹加入杀软信任区。
> 以火绒为例：主界面右上角「≡」→「信任区」→「添加文件夹」。

1. 双击 `start.bat`（建议右键 → 以管理员身份运行，自动放行防火墙端口）
2. 控制台会打印访问链接，例如 `http://192.168.0.106:8899/?key=xxxxxxxx`
3. 自动弹出一个**调试模式浏览器**并打开 chat.deepseek.com —— **登录一次 DeepSeek**（专用 profile，登录状态会保留）
4. 手机连**同一个 Wi-Fi**，浏览器打开上面的链接，开始下命令

手机上试试：

```
截个图看看现在屏幕
桌面上 1.docx 帮我总结一下
把下载文件夹里的图片按月份整理到子文件夹
看看 C 盘还剩多少空间
```

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-HttpPort 8899` | 8899 | 手机访问端口 |
| `-CdpPort 9222` | 9222 | 浏览器调试端口 |
| `-WorkDir "D:\某目录"` | `.\工作目录` | AI 主工作目录（手机可浏览下载） |
| `-ReplyTimeoutSec 300` | 300 | 等 AI 回复超时（秒） |
| `-MaxToolRounds 40` | 40 | 单命令最大工具链轮数 |
| `-ConfirmAll` | 关 | 截图/键鼠/上传也要手机确认 |
| `-Key "自定义"` | 随机 8 位 | 固定访问密钥 |

例：`start.bat -HttpPort 9000 -Key mysecret123`

## 出门在外也想用？

- **Tailscale / ZeroTier**（推荐）：手机电脑都装上，走虚拟内网，直接访问局域网地址，零暴露。
- frp / cpolar 等内网穿透也可以，但请务必保留密钥并自行评估风险。

## 工具协议（与原版兼容）

AI 在回复中输出带标记的代码块，本服务解析并执行：

| 标记 | 作用 | 参数 |
|---|---|---|
| `powershell_tool` | 执行 PowerShell | 识别头/尾注释之间的代码（≤4K 字符） |
| `agent_getjpg_1_star(...) _1_getjpg_end` | 截图 | `屏幕` 或窗口句柄 |
| `agent_getfile_head(...)'agent_getfile_end` | 上传文件给 AI | 单文件 ≤100MB，单轮 ≤50 个 |
| `agent_mouse_simulate_{1,2,3}_start(N)` | 模拟鼠标 | X、Y 逻辑坐标；0~3 = 左单击/左双击/右单击/右双击 |
| `agent_keyboard_simulate_{1..4}_start(N)` | 模拟键盘 | 最多 3 个虚拟键码；第 4 参 = 目标窗口句柄 |

执行结果以 `//[工具][xxx]// ... //[END]//` 模板回传给 AI，自动续接下一轮，直到任务完成。

## 文件结构

| 文件 | 作用 |
|---|---|
| `start.bat` | 启动器（内存加载方式，规避杀软落地扫描） |
| `Agent_runtime.txt` | 主程序：CDP 控制 + 工具执行器 + 主循环（`.txt` 后缀是刻意的） |
| `HttpWorker.ps1` | 手机端 HTTP 服务（独立 runspace） |
| `webui.html` | 手机控制台界面（单文件，无依赖） |
| `system_prompt.txt` | 系统提示词（来自原项目的工具协议契约） |
| `skill_all.zip` | 技能包（来自原项目，152 条目） |
| `docs/REVERSE_ENGINEERING.md` | 逆向分析笔记 |

## 与原项目的关系

- 原版：[YaoGaoChaoLe/EAgent](https://github.com/YaoGaoChaoLe/EAgent)（GPL-3.0）—— 易语言 GUI + 嵌入式 PowerShell，电脑端操作。
- 本项目：对原版进行协议逆向分析后，**用 PowerShell 完整重写了宿主层**，把交互入口从电脑 GUI 替换为手机网页，并加入命令队列、审批确认、实时看屏、文件下载等移动端能力。
- 内嵌的 `system_prompt.txt` 与 `skill_all.zip` 提取自原项目，其权利归原作者所有，遵循原项目 GPL-3.0 协议。

## License

[GPL-3.0](LICENSE)（与原项目保持一致）。

如果你想去掉内嵌的原项目资产（系统提示词、skill 包）后改用更宽松的协议（MIT 等），只需用你自己的提示词替换 `system_prompt.txt` 并删除 `skill_all.zip` 即可。

---

## English

**EAgent-Phone lets you command an AI to operate your Windows PC from your phone's browser.** A zero-dependency PowerShell service drives chat.deepseek.com via Chrome DevTools Protocol; the AI can run PowerShell, take screenshots, read files, and simulate mouse/keyboard, while you approve sensitive actions from your phone. Reverse-engineered reimplementation of [EAgent](https://github.com/YaoGaoChaoLe/EAgent)'s protocol with a mobile-first console. **Use only on your own devices, on trusted LANs.**
