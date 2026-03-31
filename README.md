# WSL Codex Bootstrap

[English](./README.en.md) | [简体中文](./README.md)

这是给新 Windows 机器使用的 Codex 一键引导仓库。

运行一次，就会安装 WSL、Codex，以及配置清单里的全部 32 个 skills。

脚本还会把 Codex 默认模型写成 `gpt-5.4-mini`。
安装完成后和每次自动启动前，脚本都会先检查 Codex 是否已经是最新版本；不是最新版才更新，并且还会检查订阅是否快到期或已到期，只提示，不阻断。它还会在每天首次启动前静默刷新本地 skills 和 plugins。

它负责：

- 启用并更新 WSL
- 安装 Linux 发行版
- 安装基础开发工具、`nvm`、Node.js LTS 和 `@openai/codex`
- 检查 Codex 订阅状态
- 读取独立的 skills manifest，并从上游仓库安装 Codex skills

## 快速开始

### 在线一键执行

在线安装链接： [install-wsl-codex.ps1](https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/2479c5beba311387675e5486cd9dd14489b516f2/install-wsl-codex.ps1)

请在 **Windows 主机上的 PowerShell 或 Windows Terminal** 里运行，最好用管理员权限：

```powershell
$tmp = Join-Path $env:TEMP "install-wsl-codex.ps1"; (New-Object System.Net.WebClient).DownloadFile("https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/2479c5beba311387675e5486cd9dd14489b516f2/install-wsl-codex.ps1", $tmp); powershell -NoProfile -ExecutionPolicy Bypass -File $tmp
```

不要在 WSL 里面运行这条命令。

如果你想固定使用某个 manifest 源，先修改 `skills-source.json`，或者把脚本下载到本地后再传 `-SkillsManifestUrl` / `-SkillsManifestPath`。

### 本地执行

1. 克隆或下载这个仓库。
2. 确认 `skills-source.json` 指向你要使用的 skills 清单。
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
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -InstallBubblewrap
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-codex.ps1 -SkillsManifestPath "..\Codex&WSL_all_in_one\skills.manifest.json"
```

## 生产环境配置

公开发布时，把 `skills-source.json` 改成已发布 skills 仓库的 raw manifest URL。

示例：

```json
{
  "skillsManifestUrl": "https://raw.githubusercontent.com/<owner>/codex-skills-pack/main/skills.manifest.json"
}
```

安装器仍然支持用 `-SkillsManifestPath` 和 `-SkillsManifestUrl` 覆盖配置。

## 相关仓库

skills 清单仓库是 [codex-skills-pack](https://github.com/962412311/codex-skills-pack)。

## 仓库结构

- `install-wsl-codex.ps1` - bootstrap 安装脚本
- `skills-source.json` - 外部 skills 清单指针
- `docs/bootstrap-flow.md` - 安装流程说明

## 说明

- 重新运行安装器应当是安全的。
- 如果你想在发布前测试本地 manifest 修改，最好保留一份 skills 仓库的本地克隆。
- 这个安装流程只在创建或更新 GitHub 仓库时才需要有效的 GitHub token。


## 先安装 WSL 和 Ubuntu

如果你只想先把 Windows 上的 WSL 和 Ubuntu 装好，请运行 `install-wsl-ubuntu.ps1`，也可以直接双击 `install-wsl-ubuntu.cmd`。它只负责 WSL、Ubuntu、默认发行版和首次初始化，不会安装 Codex。设置成默认发行版后，直接执行 `wsl` 就会进入 Ubuntu。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-ubuntu.ps1
```
