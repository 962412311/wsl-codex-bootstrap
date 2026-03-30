# WSL Codex Bootstrap

[English](./README.md) | [简体中文](./README.zh.md)

这是给新 Windows 机器使用的 Codex 一键引导仓库。

它负责：

- 启用并更新 WSL
- 安装 Linux 发行版
- 安装基础开发工具、`nvm`、Node.js LTS 和 `@openai/codex`
- 读取独立的 skills manifest，并从上游仓库安装 Codex skills

## 快速开始

### 在线一键执行

请在**Windows 主机上的 PowerShell 或 Windows Terminal**里运行，最好用管理员权限：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/962412311/wsl-codex-bootstrap/main/install-wsl-codex.ps1' | iex"
```

不要在 WSL 里面运行这条命令。

如果你想固定使用某个 manifest 源，先修改 `skills-source.json`，或者把脚本下载到本地后再传 `-SkillsManifestUrl` / `-SkillsManifestPath`。

### 本地执行

1. 克隆或下载这个仓库。
2. 确认 `skills-source.json` 指向你要使用的 skills 清单。
3. 以管理员身份打开 PowerShell。
4. 运行：

```powershell
.\install-wsl-codex.ps1
```

可选参数：

```powershell
.\install-wsl-codex.ps1 -Distro Ubuntu
.\install-wsl-codex.ps1 -SkipAptUpgrade
.\install-wsl-codex.ps1 -NoAutoLaunchCodex
.\install-wsl-codex.ps1 -InstallBubblewrap
.\install-wsl-codex.ps1 -SkillsManifestPath "..\Codex&WSL_all_in_one\skills.manifest.json"
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
