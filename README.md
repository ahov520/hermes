# Hermes Mobile

Hermes 生态的 Android 手机应用。**主后端已切换为 Hermes Studio（hermes-web-ui，默认端口 8648）**：账号密码登录（JWT），聊天经 Socket.IO `/chat-run` 流式推送（工具追踪、思考折叠、四选项审批、模型切换、token 用量、斜杠指令、图片发送）。
任务/定时/终端页暂仍走旧版网关 api_server（8642，API Key 鉴权），将按复刻计划逐批平移到 Studio（群聊/看板/真终端/文件/技能/模型/用量/日志…），两套配置都在「设置」页管理。

## 功能

| 页面 | 能力 | 后端 |
|---|---|---|
| 聊天 | **Studio 对话**：Socket.IO 流式、工具卡片、审批、停止、模型选择、用量徽章、斜杠指令、图片、会话分组/搜索/置顶/归档/重命名/删除、草稿 | 8648 |
| 任务 | （旧版）run 提交/审批/中断/通知 | 8642 |
| 定时 | （旧版）cron 任务管理 | 8642 |
| 终端 | （旧版）伪终端，计划换成 Studio 真终端（WebSocket） | 8642→8648 |
| 设置 | **Studio 服务器**（地址/账号/登录/多配置）+ 旧版网关配置 + 外观 + 关于 | 8648+8642 |

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

### 远程访问（cloudflared 隧道）

在隧道 `config.yml` 的 ingress 里加一条指向 8642 的 hostname（放在兜底规则之前）：

```yaml
ingress:
  - hostname: ahov12.cc.cd
    service: http://127.0.0.1:8648
  - hostname: <你的API域名>
    service: http://127.0.0.1:8642
  - service: http_status:404
```

然后 `cloudflared tunnel route dns <隧道名> <你的API域名>` 并重启 cloudflared。
App 设置页新建一套配置：`https://<你的API域名>` + 同一个 API Key，
与局域网配置一键切换。隧道自带 TLS，密钥鉴权不变。

#### 隧道注意事项

1. Cloudflare Bot Fight Mode 会按 UA 拦截 API 流量（dart:io 默认 UA 实测返回
   403 / error code 1010）。App 已内置浏览器 UA，可直接穿透，无需额外配置。
2. 根治建议：Cloudflare 控制台 → 域名 → Security → WAF → Custom rules →
   新建规则 `http.host eq "api.ahov12.cc.cd"` → Action 选 **Skip** 并勾选跳过
   所有安全特性。配好 WAF 规则后 UA 伪装就不再是必须的。
3. 隧道上传大 body（>约 4MB）会被断开。App 已把发送的图片压缩到
   1280px / 70 质量，正常拍照发送不会触到该上限。

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
