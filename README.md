# swith-codex-config

用于切换和管理 Codex CLI 的 `~/.codex/config.toml` 配置。

仓库地址：

- GitHub: `https://github.com/zz555z/swith-codex-config`

## 功能

- 交互式添加或更新 `model_providers`
- 查看当前已有的 provider 配置
- 删除指定 provider
- 设置当前使用的 `model_provider` 和 `model`
- 为多个 provider 加密保存独立 key，并在切换当前模型时解密同步到 `auth.json`

## 适用场景

当你需要在多个 Codex provider 之间切换，或者快速修改 provider 的 `base_url`、key、当前模型时，可以直接运行这个脚本。

## 文件

- `switch-codex-config.sh`: 主脚本

## 本地使用

```bash
chmod +x switch-codex-config.sh
./switch-codex-config.sh
```

## 依赖与 Windows

脚本依赖 `bash`、`openssl`、`curl`、`awk`、`sed`、`perl` 等常见命令。

在 Windows 上建议使用 Git Bash 或 WSL 运行，并确保 `openssl` 可以在 PATH 中直接调用。脚本不依赖 Ruby、Node.js 或 jq。

## 远程执行

直接运行交互菜单：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/zz555z/swith-codex-config@main/switch-codex-config.sh)
```

更稳妥的方式是先下载再执行：

```bash
curl -fsSL -o /tmp/switch-codex-config.sh https://cdn.jsdelivr.net/gh/zz555z/swith-codex-config@main/switch-codex-config.sh
bash /tmp/switch-codex-config.sh
```

## 使用示例

交互模式：

```bash
./switch-codex-config.sh
```

## 配置文件

脚本默认修改：

```bash
~/.codex/config.toml
```

脚本还会维护同目录下的两个凭据文件：

```bash
~/.codex/provider-keys.json
~/.codex/auth.json
```

`provider-keys.json` 加密保存多个 provider 对应的 key；选择当前模型时，脚本会解密当前 provider 的 key，并写入 `auth.json` 的 `OPENAI_API_KEY`。

Provider key 使用 `openssl enc -aes-256-cbc -pbkdf2` 加密，脚本内固定口令为 `switchcodex`，写入和切换当前模型时不会额外要求输入口令。

也可以通过 `CODEX_CONFIG` 指定其他配置文件：

```bash
CODEX_CONFIG=/path/to/config.toml ./switch-codex-config.sh
```

## 注意事项

- 脚本会在写入前按天创建备份文件，命名为 `原文件名.bak.YYYYMMDD`；当天已有备份时不会重复创建
- `provider-keys.json` 和 `auth.json` 会设置为 `0600` 权限
- `provider-keys.json` 的加密口令固定写在脚本里，用于避免 key 在文件中直接明文保存
- `auth.json` 仍会保存当前 provider 的明文 `OPENAI_API_KEY`，这是 Codex 读取当前 key 所需
- 修改当前 provider 或 model 后，通常需要重启 `codex` 才会生效
- 不要把你本机真实的 `auth.json`、`provider-keys.json`、token 或备份文件提交到 GitHub
- 远程执行脚本前，建议先阅读脚本内容

## 发布仓库

如果你是从本地目录继续维护这个仓库，可以使用：

```bash
cd /Users/zdd/Desktop/codex/codex-config-script
git remote add origin git@github.com:zz555z/swith-codex-config.git
git push -u origin main
```
