# swith-codex-config

用于切换和管理 Codex CLI 的 `~/.codex/config.toml` 配置。

仓库地址：

- GitHub: `https://github.com/zz555z/swith-codex-config`

## 功能

- 交互式添加或更新 `model_providers`
- 查看当前已有的 provider 配置
- 删除指定 provider
- 设置当前使用的 `model_provider` 和 `model`
- 可选应用 hosts 加速配置

## 适用场景

当你需要在多个 Codex provider 之间切换，或者快速修改 `~/.codex/config.toml` 里的 `base_url`、`token`、当前模型时，可以直接运行这个脚本。

## 文件

- `switch-codex-config.sh`: 主脚本

## 本地使用

```bash
chmod +x switch-codex-config.sh
./switch-codex-config.sh
```

查看帮助：

```bash
./switch-codex-config.sh --help
```

## 远程执行

直接运行交互菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zz555z/swith-codex-config/main/switch-codex-config.sh)
```

只查看帮助：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zz555z/swith-codex-config/main/switch-codex-config.sh) --help
```

更稳妥的方式是先下载再执行：

```bash
curl -fsSL -o /tmp/switch-codex-config.sh https://raw.githubusercontent.com/zz555z/swith-codex-config/main/switch-codex-config.sh
bash /tmp/switch-codex-config.sh
```

## 使用示例

交互模式：

```bash
./switch-codex-config.sh
```

非交互模式，添加或更新一个 provider：

```bash
CODEX_TOKEN='sk-xxx' ./switch-codex-config.sh \
  --provider custom \
  --base-url https://example.com/v1 \
  --model gpt-5.5
```

只预览修改，不真正写入：

```bash
CODEX_TOKEN='sk-xxx' ./switch-codex-config.sh \
  --provider custom \
  --base-url https://example.com/v1 \
  --model gpt-5.5 \
  --dry-run
```

## 配置文件

脚本默认修改：

```bash
~/.codex/config.toml
```

也可以通过 `CODEX_CONFIG` 或 `--config` 指定其他配置文件。

## 注意事项

- 脚本会在写入前自动创建备份文件
- 修改当前 provider 或 model 后，通常需要重启 `codex` 才会生效
- 不要把你本机真实的 `config.toml`、token 或备份文件提交到 GitHub
- 远程执行脚本前，建议先阅读脚本内容

## 发布仓库

如果你是从本地目录继续维护这个仓库，可以使用：

```bash
cd /Users/zdd/Desktop/codex/codex-config-script
git remote add origin git@github.com:zz555z/swith-codex-config.git
git push -u origin main
```
