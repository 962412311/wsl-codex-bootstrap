# WSL Codex Bootstrap

[English](./README.en.md) | [简体中文](./README.md)

这是中文首页的快捷入口。仓库默认说明在 [README.md](./README.md)。

运行一次，就会安装 WSL、Codex，以及配置清单里的全部 32 个 skills。

脚本还会把 Codex 默认模型写成 `gpt-5.4-mini`。
安装完成后和每次自动启动前，脚本都会先检查 Codex 是否已经是最新版本；不是最新版才更新，并且还会检查订阅是否快到期或已到期，只提示，不阻断。它还会在每天首次启动前静默刷新本地 skills 和 plugins。

在线一键执行请在 Windows PowerShell 或 Windows Terminal 里运行：

在线安装链接： [install-wsl-codex.ps1](https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/b6578ececbb1778e07530f87d3f3ddcda1e7b9ae/install-wsl-codex.ps1)

```powershell
$tmp = Join-Path $env:TEMP "install-wsl-codex.ps1"; (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/b6578ececbb1778e07530f87d3f3ddcda1e7b9ae/install-wsl-codex.ps1", $tmp); powershell -NoProfile -ExecutionPolicy Bypass -File $tmp
```

本地执行也请用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1
```

如果你想直接双击运行，也可以用 `install-wsl-codex.cmd`。


## 先安装 WSL 和 Ubuntu

如果你只想先把 Windows 上的 WSL 和 Ubuntu 装好，请运行 `install-wsl-ubuntu.ps1` 或直接双击 `install-wsl-ubuntu.cmd`。它只负责 WSL、Ubuntu、默认发行版和首次初始化，不会安装 Codex。设置成默认发行版后，直接执行 `wsl` 就会进入 Ubuntu。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-ubuntu.ps1
```
