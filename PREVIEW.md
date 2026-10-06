# 固定工作环境验证版

版本：**0.4.0-preview.1**。正式版仍为 **0.3.3**。

## 打开

应用程序 → **Codex Switchboard Preview**。

先从菜单栏退出原来的 Codex Switchboard。验证版首次打开不会切换账号；点击 **Open / Switch** 才会重启 Codex，请先结束正在运行的任务。

## 验收步骤

1. 点击 **Add Account**，分别完成 A、B 两个账号的官方登录。
2. 点击 A 的 **Open / Switch**。在 Codex 的账号菜单里核对邮箱。
3. 点击 **Show Test Project**，在 Codex 中添加这个目录，创建一个聊天，发送一句“这是账号 A 的测试”。
4. 切到 B。核对邮箱、额度；打开同一个项目、同一个聊天，发送“这是账号 B 的续聊”。
5. 切回 A。确认两条内容都在，并且能继续聊天。
6. 点击 **Refresh** 后再往返切换一次。稍后或电脑唤醒后，再重复一次。
7. 点击 **Return to Original Environment**，回到原来的 Codex 环境，然后重新打开正式版 Switchboard。

若同时验收 MCP：在测试环境中添加一个实际使用的 MCP、完成授权，再换账号调用一次。原环境的 MCP 配置和授权没有导入测试环境。

## 出错时

- 出现 **Recover Interrupted Operation**：点击恢复，然后刷新。
- 出现 **Sign In Again**：重新完成官方登录。若是当前打开的测试账号，先返回原环境，再重新登录。
- 切换启动失败时，验证版尝试恢复之前的环境；恢复也失败则保留恢复入口，不把目标标为 Current。
- 关闭验证窗口只退出工具；需要离开测试环境时，先点击 **Return to Original Environment**。

## 数据位置与边界

- 固定测试 Home：`~/Library/Application Support/Codex Switchboard Preview/Work`
- 测试项目：`~/Library/Application Support/Codex Switchboard Preview/Test Project`
- 所有测试账号使用同一份本地项目和聊天，包括项目外聊天。
- 离线账号凭据放在验证版专用 macOS 钥匙串条目中；活动凭据使用测试 Home 的 `auth.json`。额度查询产生的临时凭据在保存后清理。
- 不导入现有账号凭据，不迁移真实聊天，不覆盖正式应用。云端项目和服务仍受当前账号权限限制。
- Current 表示已核对测试 Home 和后台身份；本轮仍需在 Codex 账号菜单中人工核对实际桌面身份。

## 自动验证覆盖

11 项合成检查：固定 Home 往返、最新凭据保留、额度查询后凭据回写、失败回退、中断恢复、身份不匹配、取消登录、重新登录、并发进程保护、文件权限及单实例。

另外通过本机实际 App Server 的合成 API 凭据往返、后台项目保留及专用钥匙串读写检查。没有调用模型，没有切换或登出真实账号。

**真实 ChatGPT 登录、真实 OAuth 刷新、桌面聊天与 MCP 授权仍待上述手动验收。** 自动检查中的凭据更新是模拟事件，不作为真实 OAuth 刷新已通过的证据。

开发命令：

```sh
swift run PreviewChecks
swift run PreviewChecks --integration-cli /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex
./scripts/build-preview.sh
```

构建输出：`dist/Codex Switchboard Preview.app`。与正式应用使用不同的名称和 bundle ID。
