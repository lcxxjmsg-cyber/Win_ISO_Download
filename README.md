# Get-RGIso

一个交互式 PowerShell 脚本，用于从 **[files.rg-adguard.net](https://files.rg-adguard.net)** 按需检索并下载微软原版镜像（Windows / Windows Server / Office / Visual Studio 等），自动完成**解压、SmartVersion 差分重建、SHA-1 校验**，并用 `aria2c` 下载。

> 本项目只是一个前端脚本，数据与文件均来自第三方站点 rg-adguard。文件本身是与微软原版**哈希一致**的纯净镜像，但下载源是 rg-adguard 的镜像 CDN，**并非微软官方服务器**。

---

## 特性

- **全站按需浏览**：`分类 → 版本 → 语言 → 文件` 树形导航，覆盖 rg-adguard 收录的全部内容（Windows XP/7/8/8.1/10/11、Windows Server 全系、Office、开发工具、MSDN Library 等）。
- **纯官方哈希校验**：下载后自动用官方 `SHA-1` 端点校验，确保与微软原版逐字节一致。
- **自动处理打包机制**：
  - `.7z` 解压（含固定密码）
  - SmartVersion 差分包（`.svf`）与 `.dvp` 的自动重建（同组交叉引用、带重试）
  - 差分组整组下载后按需保留
- **零依赖启动**：本机若缺少 `aria2c` / `7z`，自动从站点 `/tools` 拉取工具集。
- **中文界面**。
- **支持内存运行**（`irm | iex`），自动选择输出目录。
- 下载失败自动**刷新链接重试**（应对 free 档链接时效过期）。

---

## 环境要求

- Windows + **Windows PowerShell 5.1**（系统自带）
- 网络能访问 `files.rg-adguard.net` 与 `dl.rg-adguard.net`
- 磁盘空间：重建过程中会同时存在 `压缩包 + 解压件 + 成品`，峰值约为目标镜像的 **2–3 倍**

---

## 快速开始

### 方式一：一键启动（Win + R，最简单）

按下 `Win + R`，粘贴以下命令并回车（内置 gh-proxy 国内加速）：

```
powershell "& ([scriptblock]::Create((irm 'https://gh-proxy.com/https://raw.githubusercontent.com/lcxxjmsg-cyber/GitHub-Script-Entrance/main/launch.ps1'))) -r 'https://github.com/lcxxjmsg-cyber/Win_ISO_Download/blob/main/Get-RGIso.ps1'"
```

脚本在内存中运行，无需手动下载。输出目录自动设为 **桌面下的 `WinISO` 文件夹**（无桌面则回退 `D:\WinISO`，再无则系统盘根的 `WinISO`）。

### 方式二：下载文件后运行

```powershell
powershell -ExecutionPolicy Bypass -File .\Get-RGIso.ps1
```

默认输出到脚本同级的 `downloads\`，工具放在 `bin\`。

### 方式三：内存运行（irm | iex）

```powershell
irm https://raw.githubusercontent.com/lcxxjmsg-cyber/Win_ISO_Download/main/Get-RGIso.ps1 | iex
```

国内访问 GitHub 不稳时，可加 gh-proxy 前缀：

```powershell
irm https://gh-proxy.com/https://raw.githubusercontent.com/lcxxjmsg-cyber/Win_ISO_Download/main/Get-RGIso.ps1 | iex
```

需要在内存运行时传参，可用：

```powershell
& ([scriptblock]::Create((irm https://gh-proxy.com/https://raw.githubusercontent.com/lcxxjmsg-cyber/Win_ISO_Download/main/Get-RGIso.ps1))) -Connections 16
```

---

## 操作说明

在浏览菜单中：

| 输入 | 作用 |
|------|------|
| `数字` | 进入对应的目录 / 文件 |
| `/文字` | 按关键字过滤当前列表（如 `/24h2`、`/consumer`、`/professional`） |
| `.` | 清除过滤 |
| `b` | 返回上一级 |
| `q` | 退出 |

选中一个文件后：

| 输入 | 作用 |
|------|------|
| `D` | 只保留你选择的这个文件 |
| `A` | 保留同组的全部文件 |
| `B` | 返回 |

> **关于差分组**：rg-adguard 会把「同一版本的不同语言/版别」用 SmartVersion 差分打包成一组。因此 `D` 与 `A` **都会下载整组**（重建所必需），区别只是最后**保留哪些**镜像。

---

## 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-OutDir <路径>` | `.\downloads`（内存运行为 `桌面\WinISO\downloads`） | 镜像输出目录 |
| `-ToolsDir <路径>` | `.\bin` | `aria2c`/`7z` 等工具目录 |
| `-Connections <n>` | `1` | aria2c 连接数。free 档通常被服务端限制，可尝试调大 |
| `-Key <key>` | `free` | 下载档位。若拥有 rg-adguard 的付费/赞助 key 可填入以获得满速多线程 |
| `-KeepArchive` | 关闭 | 完成后保留中间的 `.7z` 压缩包 |

示例：

```powershell
.\Get-RGIso.ps1 -Connections 16
.\Get-RGIso.ps1 -OutDir D:\ISO -KeepArchive
```

---

## 工作原理

站点是纯 HTML + GUID 的树，脚本逐级抓取：

```
/category → /version/<id> → /language/<id> → /files/<id> → /file/<id>
                                                              │
                                          GET /dl/<key>/<uuid> → aria2 输入(直链 + sha-1)
```

- `/dl/<key>/<uuid>` 返回真实直链：`https://dl.rg-adguard.net/files/<uuid>.7z?...`（带时效 token）。
- 下载到的 `.7z` 用固定密码解压；内部可能是：
  - 直接的镜像文件（`.iso` / `.img` / `.exe` …），或
  - SmartVersion 差分文件（`.svf`）/ `.dvp`，需用 `smv.exe` / `dvp.exe` 以同组其它文件为基准重建。
- 重建完成后，用官方 `GET /file/<uuid>/sha1` 校验成品哈希。

---

## 覆盖范围与文件类型

- **操作系统**：Windows XP / Vista / 7 / 8 / 8.1 / 10 / 11 等，多为 `.iso` 或 `.img`。
- **服务器**：Windows Server 2003 → 2025，多为 `.iso`。
- **应用（Office / Visual Studio 等）**：较新的多为 `.iso`/`.img`，很老的可能是 `.exe`/`.msi`。

`.img` 与 `.iso` 内容等价（都是 ISO9660 光盘映像），需要 `.iso` 后缀时直接改名即可。

### 安装与激活

- ISO/IMG：Windows 8 及以上双击可直接挂载，或用 Rufus 等写入 U 盘；运行其中的 `setup.exe` 安装。
- 这些是**微软原版纯净安装介质，不含激活/破解**。安装后仍需**合法的产品密钥**才能激活（零售 Key，或在获授权的组织内使用 KMS/MAK）。

---

## 已知限制

- **Cloudflare 拦截**：`dl.rg-adguard.net` 位于 Cloudflare 之后，数据中心/VPN/代理出口 IP 可能返回 `403`。请关闭代理、使用家用宽带。（错误码 `22` 通常即为此类 HTTP 异常）
- **free 档限速**：免费档通常为单线程/限速；满速多线程需付费 key（`-Key`）。
- **磁盘占用**：见上文，峰值约镜像的 2–3 倍。
- **依赖站点结构**：本质是网页抓取，若 rg-adguard 改版页面结构，正则可能需要相应调整。
- 大差分组会整组下载，体积较大。

---

## 免责声明

- 本脚本仅为访问公开第三方服务 rg-adguard 的自动化前端，**不托管任何文件**。
- 所有镜像版权归 **Microsoft Corporation** 所有；Windows、Office 等为微软商标。
- 下载得到的是原版安装介质，**使用/激活须遵守微软相关许可条款**，请自行确保拥有合法授权。
- 使用本脚本产生的一切后果由使用者自行承担。

## 致谢

- 数据与文件服务：**[@rgadguard](https://files.rg-adguard.net)**
- 下载：[aria2](https://github.com/aria2/aria2)　解压：[7-Zip](https://www.7-zip.org/)　差分：[SmartVersion](http://www.smartversion.com/)
