# WSL Codex Bootstrap

[English](./README.en.md) | [简体中文](./README.md)

这是中文首页的快捷入口。仓库默认说明在 [README.md](./README.md)。

运行一次，就会安装 WSL、Codex，以及配置清单里的全部 32 个 skills。

脚本还会把 Codex 默认模型写成 `gpt-5.4-mini`。
安装完成后和每次自动启动前，脚本都会先检查 Codex 是否已经是最新版本；不是最新版才更新，并且还会检查订阅是否快到期或已到期，只提示，不阻断。

在线一键执行请在 Windows PowerShell 或 Windows Terminal 里运行：

```powershell
$tmp = Join-Path $env:TEMP "install-wsl-codex.ps1"; (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/f9189f856d109a487310e0f99c174535546c60c8/install-wsl-codex.ps1", $tmp); powershell -NoProfile -ExecutionPolicy Bypass -File $tmp
```

本地执行也请用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1
```
