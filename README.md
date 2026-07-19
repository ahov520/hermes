# Hermes Mobile

连接本地 Hermes Agent 网关（`api_server` 平台，默认端口 8642）的 Android 手机应用。
覆盖网关 HTTP API 的全部能力：流式对话、会话管理、任务（Run）提交与工具审批、定时任务（cron）管理、服务器状态/模型/技能/工具集浏览。

## 功能

| 页面 | 能力 | 对应 API |
|---|---|---|
| 聊天 | 会话列表/新建/重命名/分叉/删除，SSE 流式对话，工具调用与思考过程展示，Markdown 渲染 | `/api/sessions/*` |
| 任务 | 提交一次性 agent 任务，实时事件流，工具调用审批（允许一次/本会话/总是/拒绝），中断任务 | `/v1/runs/*` |
| 定时 | cron 任务查看/新建/编辑/暂停/恢复/立即运行/删除 | `/api/jobs/*` |
| 设置 | 连接配置与连通性测试，网关状态、模型、技能、工具集 | `/health/*`, `/v1/*` |

## 服务端前提

Hermes 网关需启用 API server（在 `~/.hermes/.env` 或 `$HERMES_HOME/.env`）：

```
API_SERVER_ENABLED=true
API_SERVER_HOST=0.0.0.0        # 手机走局域网/Wi-Fi 连接时必须
API_SERVER_PORT=8642
API_SERVER_KEY=<强随机密钥>     # 必填且 ≥16 字符，否则服务拒绝启动
```

改完后重启网关。手机与电脑在同一 Wi-Fi 下，App 设置页填
`http://<电脑局域网IP>:8642` 和上面的 Key 即可。

> 安全提示：该端点能驱动 agent 的终端/文件工具。`0.0.0.0` 仅建议可信家庭网络，
> 公网访问请改走 cloudflared tunnel / WireGuard / Tailscale，不要直接把 8642 暴露到公网。

## GitHub Actions 编译

仓库内置 `.github/workflows/build.yml`：

1. 把本项目推到 GitHub：`git init && git add -A && git commit -m init && git remote add origin <repo> && git push -u origin main`
2. Actions 自动跑：生成 Android 脚手架（`flutter create`，版本永远与 stable 匹配）→ 注入 INTERNET 权限与明文 HTTP 允许 → analyze → test → `flutter build apk --release`
3. 在 Actions 运行页的 **Artifacts** 下载 `hermes-mobile-apk`（`app-release.apk`），装到手机即可

也可在 Actions 页手动 **Run workflow** 触发。

> Release APK 使用 Flutter 模板默认的 debug 签名，仅供个人安装使用。
> 上架/正式分发请在 `android/app/build.gradle` 配置正式签名（可先本地 `flutter create` 生成 android/ 再改）。

## 本地开发

```bash
flutter create --platforms android --project-name hermes_mobile .
# 同样需要在 android/app/src/main/AndroidManifest.xml 加 INTERNET 权限和
# android:usesCleartextTraffic="true"（CI 会自动做，本地手动加一次即可）
flutter pub get
flutter run            # 调试
flutter build apk      # 出包
```

## 目录结构

```
lib/
  main.dart            # 应用外壳 + 底部导航
  api.dart             # Hermes API 客户端（REST + SSE 解析）
  models.dart          # 数据模型
  state.dart           # 连接配置（shared_preferences 持久化）
  pages/
    chat_page.dart     # 会话 + 流式对话
    runs_page.dart     # 任务 + 审批
    jobs_page.dart     # 定时任务
    settings_page.dart # 连接配置 + 服务器信息
test/                  # 解析单元测试 + 启动冒烟测试
.github/workflows/     # CI 编译 APK
```
