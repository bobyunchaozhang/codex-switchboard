# 上传 Codex Switchboard 到 GitHub

## 1. 创建 SSH 密钥

```sh
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -C "YOUR_GITHUB_EMAIL" -f ~/.ssh/id_ed25519_github
```

按提示设置密钥口令。**不要把私钥 `id_ed25519_github` 上传或发给别人。**

运行 `nano ~/.ssh/config`，写入以下内容；按 **Control-O、Return、Control-X** 保存退出：

```text
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/id_ed25519_github
```

```sh
chmod 600 ~/.ssh/config
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_github
```

## 2. 把公钥加入 GitHub

```sh
pbcopy < ~/.ssh/id_ed25519_github.pub
```

打开 [GitHub SSH keys](https://github.com/settings/keys) → **New SSH key** → 类型选 **Authentication Key** → 粘贴并保存。

## 3. 验证连接

```sh
ssh -T git@github.com
```

首次连接先核对 [GitHub 官方主机指纹](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)，匹配后输入 `yes`。看到 `Hi YOUR_USERNAME!` 即成功。

## 4. 创建空仓库

打开 [新建仓库](https://github.com/new)，名称填 `codex-switchboard`，建议选 **Private**。不要勾选 README、`.gitignore` 或 License。

## 5. 检查 `.gitignore`

```sh
cd /Users/x/Projects/codex-switchboard
cat .gitignore
```

本项目已忽略 `.build/`、`dist/` 等生成文件。其他项目可用 `nano .gitignore` 按实际内容创建或补充规则；**`.gitignore` 本身也要提交**。

## 6. 提交并上传

从 [GitHub 邮箱设置](https://github.com/settings/emails)复制自己的 `noreply` 邮箱，然后运行：

```sh
cd /Users/x/Projects/codex-switchboard
git config user.name "YOUR_GITHUB_NAME"
git config user.email "YOUR_GITHUB_NOREPLY_EMAIL"
git add -n .
```

确认预览列表没有不想上传的文件，再运行：

```sh
git add .
git commit -m "Initial Codex Switchboard release"
git remote add origin git@github.com:YOUR_USERNAME/codex-switchboard.git
git push -u origin main
```
