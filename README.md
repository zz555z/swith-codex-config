# codex-config-script

用于切换和管理 Codex CLI 的 `~/.codex/config.toml` 配置。

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

直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<your-name>/<your-repo>/main/switch-codex-config.sh)
```

只看帮助：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<your-name>/<your-repo>/main/switch-codex-config.sh) --help
```

更稳妥的方式是先下载再执行：

```bash
curl -fsSL -o /tmp/switch-codex-config.sh https://raw.githubusercontent.com/<your-name>/<your-repo>/main/switch-codex-config.sh
bash /tmp/switch-codex-config.sh
```

## 发布到 GitHub

```bash
cd /Users/zdd/Desktop/codex/codex-config-script
git init
git add .
git commit -m "Initial commit"
git branch -M main
git remote add origin git@github.com:<your-name>/<your-repo>.git
git push -u origin main
```

发布前把命令里的 `<your-name>` 和 `<your-repo>` 替换成你自己的 GitHub 用户名和仓库名。
