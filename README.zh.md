# WSL Codex Bootstrap

[English](./README.en.md) | [简体中文](./README.md)

这是给新 Windows 机器使用的 Codex 一键引导仓库。

运行一次，就会安装 WSL、Codex，以及上游 skills 包里的全部 32 个 skills。

脚本还会把 Codex 默认模型写成 `gpt-5.4-mini`。
安装完成后和每次自动启动前，脚本都会先检查 Codex 是否已经是最新版本；不是最新版才更新，并且还会检查订阅是否快到期或已到期，只提示，不阻断。它还会在每天首次启动前静默刷新本地 skills 和 plugins。

它负责：

- 启用并更新 WSL
- 安装 Linux 发行版
- 安装基础开发工具、`nvm`、Node.js LTS 和 `@openai/codex`
- 检查 Codex 订阅状态
- 从上游 skills 包安装 Codex skills

## 快速开始

### 在线一键执行

在线安装器： [install.ps1](https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install.ps1)

请在 **Windows 主机上的 PowerShell 或 Windows Terminal** 里运行，最好用管理员权限：

```powershell
$tmp = Join-Path $env:TEMP "install.ps1"; (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install.ps1", $tmp); powershell -NoProfile -ExecutionPolicy Bypass -File $tmp
```

不要在 WSL 里面运行这条命令。

### WSL 直接在线执行

在 WSL 里直接运行下面命令，将 Codex 安装到当前 Linux 用户账号：

```bash
curl -fsSL https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install-linux-codex.sh | bash -s -- bootstrap
```

### macOS 直接在线执行

在 macOS 里直接运行下面命令，将 Codex 安装到当前 macOS 用户账号：

```bash
curl -fsSL https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install-mac-codex.sh | bash -s -- bootstrap
```

首次运行会自动安装或复用 Homebrew，并配置 `~/.local/bin/codex`、默认模型、订阅检查和 skills 同步。

首次运行安装基础包时可能会提示输入 `sudo` 密码。

### 本地执行

1. 克隆或下载这个仓库。
2. 安装器始终从上游 skills 包拉取 skills。
3. 以管理员身份打开 PowerShell。
4. 运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1
```

如果你想直接双击运行，也可以用 `install-wsl-codex.cmd`。

可选参数：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -Distro Ubuntu
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -SkipAptUpgrade
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -NoAutoLaunchCodex
```

## 相关仓库

skills 清单仓库是 [codex-skills-pack](https://github.com/962412311/codex-skills-pack)。

## 仓库结构

- `install-wsl-codex.ps1` - bootstrap 安装脚本
- `install-mac-codex.sh` - macOS bootstrap 安装脚本
- `docs/bootstrap-flow.md` - 安装流程说明

## 说明

- 重新运行安装器应当是安全的。
- 这个安装流程只在创建或更新 GitHub 仓库时才需要有效的 GitHub token。

## 先安装 WSL 和 Ubuntu

如果你只想先把 Windows 上的 WSL 和 Ubuntu 装好，请运行 `install-wsl-ubuntu.ps1`，也可以直接双击 `install-wsl-ubuntu.cmd`。它只负责 WSL、Ubuntu、默认发行版和首次初始化，不会安装 Codex。设置成默认发行版后，直接执行 `wsl` 就会进入 Ubuntu。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-ubuntu.ps1
```
