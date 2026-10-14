# Cline API 逆向笔记（本沙箱环境）

> **来源**：本机 SDK 产物与运行时配置的**静态读取**，未做真实抓包。
> 结论可信度：端点/认证头为高可信（代码常量），请求体字段为中可信（minified 代码反推，可能有遗漏）。
> 适用 SDK：`@cline/core`、`@cline/llms`（`/app/node_modules/@cline/`）

---

## 1. 结论速览

| 项目 | 值 |
| --- | --- |
| API 根地址 | `https://api.cline.bot` |
| OpenAI 兼容 base path | `https://api.cline.bot/api/v1` |
| 推理端点 | `POST https://api.cline.bot/api/v1/chat/completions` |
| MCP base | `https://api.cline.bot/v1/mcp` |
| App 前端 | `https://app.cline.bot` |
| 认证方式 | `Authorization: Bearer <token>` |
| Token 来源 | 环境变量 `CLINE_API_KEY` 或 Cline 账号 OAuth（底层 WorkOS） |
| WorkOS client_id | `client_01K3A541FN8TA3EPPHTD2325AR`（公开标识） |
| 协议族 | OpenAI-compatible（`@ai-sdk/openai-compatible`） |
| 响应信封 | `success-data`（形如 `{ success, data }`） |

> 章节导航：端点/Headers/Body 见 2–4 章，**登录与取 token 见第 6 章**，本沙箱实测见第 8 章。

---

## 2. 端点与协议

`cline` provider 在 SDK 中注册为 **OpenAI 兼容** provider：

```js
// @cline/llms/dist/models.js  —— provider 工厂内部
{
  id: "cline",
  family: "cline",
  name: "Cline Usage-Billing",
  capabilities: ["reasoning", "prompt-cache", "tools", "oauth"],
  apiKeyEnv: ["CLINE_API_KEY"],
  defaults: {
    get baseUrl() { return `${Ae().apiBaseUrl}/api/v1`; }   // → https://api.cline.bot/api/v1
  },
  metadata: { imageTransport: "openrouter", responseEnvelope: "success-data" }
}
```

`@ai-sdk/openai-compatible` 固定拼接路径：

```js
path: "/chat/completions"
```

### 已知同前缀接口

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| POST | `/api/v1/chat/completions` | 推理（推测，AI SDK 拼接） |
| GET | `/api/v1/ai/cline/models` | 模型目录 |
| GET | `/api/v1/ai/cline/recommended-models` | 推荐模型 |
| POST | `/api/v1/auth/token` | 取令牌 |
| POST | `/api/v1/auth/refresh` | 刷新令牌 |
| POST | `/api/v1/auth/register` | 注册 |
| POST | `/api/v1/auth/authorize` | 授权 |
| GET | `/api/v1/connectors` | 连接器列表 |
| GET | `/api/v1/users/me` | 当前用户 |
| GET | `/api/v1/users/me/plan` | 套餐 |
| GET | `/api/v1/users/me/remote-config` | 远程配置 |
| GET | `/api/v1/users/active-account` | 活跃账号 |
| GET | `/api/v1/plans` | 套餐列表 |
| GET | `/api/v1/integrations/github/repositories` | GitHub 仓库集成 |
| GET | `/api/v1/session`、`/api/v1/session/{id}`、`/api/v1/session/{id}/status` | 云会话 |
| GET | `/api/v1/organizations/{id}` | 组织 |

### 环境配置常量（production）

```js
// @cline/llms/dist/models.js
{
  production: {
    environment:    "production",
    appBaseUrl:     "https://app.cline.bot",
    apiBaseUrl:     "https://api.cline.bot",
    mcpBaseUrl:     "https://api.cline.bot/v1/mcp",
    workOsClientId: "client_01K3A541FN8TA..."   // 已截断
  }
}
```

解析顺序（`CLINE_API_BASE_URL` 可覆盖默认值）：

```js
apiBaseUrl: ENV.CLINE_API_BASE_URL ?? "https://api.cline.bot"
```

---

## 3. 请求 Headers

### 3.1 固定基础头

```js
// 常量 ha / ya，见 @cline/llms/dist/models.js、providers.js
{
  "HTTP-Referer":   "https://cline.bot",
  "X-Title":        "Cline",
  "X-IS-MULTIROOT": "false",
  "X-CLIENT-TYPE":  "cline-sdk"
}
```

### 3.2 运行时拼接（在基础头之上覆盖）

```js
{
  ...base,
  "User-Agent":         `Cline/${version}`,
  "X-CLIENT-TYPE":      clientName ?? "cline-sdk",
  "X-CLIENT-VERSION":   version ?? "unknown",
  "X-PLATFORM":         platform ?? clientName,
  "X-PLATFORM-VERSION": platformVersion ?? version,
  "X-CORE-VERSION":     coreVersion,
  "X-Task-ID":          sessionId,          // 仅在存在会话 id 时附加
  "X-IS-MULTIROOT":     isMultiRoot ? "true" : "false"
}
```

### 3.3 认证与内容类型

HTTP 客户端统一注入（见 `@cline/core/dist/cloud/index.js`）：

```
Authorization: Bearer <token>
Accept: application/json
Content-Type: application/json     // 仅在有 body 时
```

> 特殊头：`x-cline-minimax-thinking-disabled`（MiniMax 模型关闭 thinking 时使用）。

---

## 4. 请求体

标准 OpenAI chat-completions 结构：

```json
{
  "model": "cline-cloud/deepseek-v4.1-flash",
  "messages": [
    { "role": "system", "content": "..." },
    { "role": "user",   "content": "你好" }
  ],
  "stream": true,
  "tools": [],
  "temperature": 0,
  "max_tokens": 8192
}
```

### 4.1 非标准字段（provider options 桶）

推理 / 思考 / 缓存等能力不是 OpenAI 标准字段，SDK 把它们塞进 provider options：

```js
{ thinking:    { type: "enabled", budget_tokens: 8192 } }  // 亦有 type: "disabled"
{ reasoning:   { ... } }
{ promptCache: { ... } }
{ provider:    { allow_fallbacks: true } }                 // 路由回退
{ openaiCompatible: { ... } }
{ openai:      { ... } }
```

多 provider 分支时使用 providerId 作为 key（`cline` / `anthropic` 特判，其余用 `providerOptionsKey`）。

### 4.2 响应信封

provider 元数据声明 `responseEnvelope: "success-data"`，返回体可能包裹为：

```json
{ "success": true, "data": { ... } }
```

---

## 5. 认证流程

两条路径：

**A. 环境变量直用**

```
CLINE_API_KEY=<token>
```

SDK 对该 provider 声明的 `apiKeyEnv` 即 `["CLINE_API_KEY"]`。

**B. OAuth（Cline 账号）**

```
本地端点（hub daemon）：
  POST /api/v1/auth/authorize
  POST /api/v1/auth/token
  POST /api/v1/auth/refresh
  POST /api/v1/auth/register

底层 IdP（WorkOS）：
  base   https://api.workos.com
  POST   /user_management/authorize/device
  POST   /user_management/authenticate
```

令牌形如 `workos:<jwt>`，SDK 会剥离前缀取 `sub` 作为用户标识。

> 完整的分步流程、curl 复刻与令牌落地位置见 **第 6 章**。


---

## 6. WorkOS OAuth 登录详解与令牌获取

### 6.1 两条流程

`loginClineOAuth` 由 `useWorkOSDeviceAuth` 决定走哪条（默认 `true`）：

```js
// @cline/core/dist/hub/index.js
let t = e.useWorkOSDeviceAuth ?? true;                     // 默认 true = 设备码流程
let n = e.callbackPorts?.length ? e.callbackPorts : Gy;   // 48801..48811
let r = e.callbackPath ?? "/auth";
```

| | 设备码流程（默认） | 浏览器 PKCE 流程 |
| --- | --- | --- |
| 适用场景 | headless / 无浏览器 | 有浏览器 |
| 本地端口 | 不需要 | `48801–48811`，回调路径 `/auth` |
| 兑换端点 | `POST /api/v1/auth/register` | `POST /api/v1/auth/token` |
| 兑换参数 | `{accessToken, refreshToken}` | `{grant_type, code, client_type, redirect_uri, provider}` |
| SDK 开关 | `useWorkOSDeviceAuth: true` | `useWorkOSDeviceAuth: false` |

### 6.2 生产常量

```js
// @cline/llms/dist/models.js
production: {
  environment:    "production",
  appBaseUrl:     "https://app.cline.bot",
  apiBaseUrl:     "https://api.cline.bot",
  mcpBaseUrl:     "https://api.cline.bot/v1/mcp",
  workOsClientId: "client_01K3A541FN8TA3EPPHTD2325AR"
}
```

```
WorkOS API base : https://api.workos.com
设备码有效期    : 300s
轮询间隔默认    : 5s（slow_down 时 +1s）
刷新缓冲        : 300000 ms（到期前 5 分钟刷新）
```

> `workOsClientId` 是 **PKCE 公共客户端的公开标识**，不是密钥，泄露无害。

### 6.3 设备码流程（可 curl 复刻）

**第 1 步 — 申请设备码**

```bash
curl -sS -X POST https://api.workos.com/user_management/authorize/device \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=client_01K3A541FN8TA3EPPHTD2325AR"
```

```json
{
  "device_code": "device_xxx",
  "user_code": "ABCD-1234",
  "verification_uri": "https://...",
  "verification_uri_complete": "https://...?user_code=ABCD-1234",
  "expires_in": 300,
  "interval": 5
}
```

**第 2 步** — 浏览器打开 `verification_uri`，输入 `user_code`。

**第 3 步 — 轮询换取 WorkOS 令牌**

```bash
curl -sS -X POST https://api.workos.com/user_management/authenticate \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
  -d "device_code=$DEVICE_CODE" \
  -d "client_id=client_01K3A541FN8TA3EPPHTD2325AR"
```

SDK 的轮询状态机：

```
authorization_pending  → 等待 interval 秒后重试
slow_down              → interval += 1，再等待
access_denied / expired_token / invalid_grant → 终止并报错
超时（> expires_in）    → "WorkOS device authorization timed out"
```

成功返回 `{ access_token, refresh_token, token_type }`。


### 6.4 兑换 Cline 令牌（关键一步）

拿到 WorkOS 令牌后，还要到 Cline 换**真正的 API 令牌**。

**设备码流程 → `/api/v1/auth/register`**（源码 `xM`）：

```bash
curl -sS -X POST https://api.cline.bot/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{
        "accessToken":  "<workos access_token>",
        "refreshToken": "<workos refresh_token>"
      }'
```

**浏览器 PKCE 流程 → `/api/v1/auth/token`**（源码 `MM`）：

```bash
curl -sS -X POST https://api.cline.bot/api/v1/auth/token \
  -H "Content-Type: application/json" \
  -d '{
        "grant_type":   "authorization_code",
        "code":         "<回调 code>",
        "client_type":  "extension",
        "redirect_uri": "http://localhost:48801/auth",
        "provider":     "cline"
      }'
```

两者返回结构一致（`{ success, data }` 信封）：

```json
{
  "success": true,
  "data": {
    "accessToken":  "...",
    "refreshToken": "...",
    "expiresAt":    1730000000000,
    "tokenType":    "Bearer",
    "userInfo": {
      "subject": "...", "email": "...", "name": "...",
      "clineUserId": "usr-...", "accounts": ["..."]
    }
  }
}
```

SDK 的字段映射（`Au`）：

```js
access    = data.accessToken          // ← 这才是请求模型用的 Bearer
refresh   = data.refreshToken
expires   = data.expiresAt
accountId = data.userInfo.clineUserId
email     = data.userInfo.email
```

拿到后即可：

```bash
curl https://api.cline.bot/api/v1/ai/cline/models \
  -H "Authorization: Bearer $CLINE_TOKEN"
```

### 6.5 令牌续期

```
POST https://api.cline.bot/api/v1/auth/refresh
refreshBufferMs     默认 300000   // 到期前 5 分钟即触发刷新
retryableTokenGraceMs 默认 30000
```

access token 是 JWT，SDK 解析 `exp` 判断过期；`sub` 若带 `workos:` 前缀则剥离后作为用户标识。

### 6.6 令牌落地位置

```js
// @cline/core/dist/hub/daemon/entry.js
dataDir          // 默认 ~/.cline/data
globalStatePath  = dataDir/globalState.json
secretsPath      = dataDir/secrets.json     // ← 凭证文件
```

保存逻辑（`saveProviderOAuthCredentials`）：

```js
settings.auth = { accessToken, refreshToken, accountId, expiresAt, metadata }
manager.saveProviderSettings(settings, { tokenSource: "oauth" })
```

读取优先级：

```bash
# 1) 环境变量
echo $CLINE_API_KEY

# 2) 凭证文件 / provider settings
cat "$CLINE_DATA_DIR/secrets.json"     # 默认 ~/.cline/data/secrets.json
#    或 provider settings 中的 auth.accessToken
```

### 6.7 本沙箱为何取不到

实测检查结果：

```
/home/node/.cline/data/       → 仅 db/ locks/ logs/ sessions/，无 secrets.json
env | grep -c CLINE_API_KEY   → 0
```

原因：沙箱内 `api.cline.bot` 走 egress MITM 代理（`/etc/mitm/api.cline.bot.key`），**凭证由代理透明注入**，本地不落盘；会话元数据里也只有 `provider`/`model`，无 token 字段。

| 场景 | 能否拿到 token |
| --- | --- |
| 在本沙箱读文件 / 环境变量 | ❌ 拿不到（代理注入） |
| 自行执行 6.3 + 6.4 设备码流程 | ✅ 可拿到 `data.accessToken` |
| 本地已装 Cline 客户端/插件 | ✅ 读 `~/.cline/data/secrets.json` |
| 从 app.cline.bot 生成 API key | ✅ 作为 `CLINE_API_KEY` 使用 |


### 6.8 配套脚本

仓库内提供可直接运行的登录脚本（Windows 11 优先）：

```
scripts/cline-device-login.ps1    # 主脚本（PowerShell 5.1 / 7 均可）
scripts/cline-login.cmd           # Windows 双击/命令行包装（自动选 pwsh 或 powershell）
```

用法：

```powershell
# 直接运行
powershell -ExecutionPolicy Bypass -File .\scripts\cline-device-login.ps1

# 保存结果到文件（可选）
.\scripts\cline-device-login.ps1 -OutFile "$env:USERPROFILE\.cline-token.json"

# 无桌面环境（不自动开浏览器）
.\scripts\cline-device-login.ps1 -NoBrowser
```

可用参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-ApiBaseUrl` | `$env:CLINE_API_BASE_URL` 或 `https://api.cline.bot` | Cline API 根地址 |
| `-WorkOsBaseUrl` | `https://api.workos.com` | WorkOS API 根地址 |
| `-ClientId` | `client_01K3A541FN8TA3EPPHTD2325AR` | WorkOS 公共客户端 ID |
| `-TimeoutSeconds` | `300` | 轮询总超时 |
| `-OutFile` | 无 | 将令牌写入 JSON 文件 |
| `-NoBrowser` | 关 | 不自动打开浏览器 |
| `-ShowWorkOsToken` | 关 | 额外打印 WorkOS 原始令牌 |

实现要点（已在 PowerShell 7.4.6 上实测）：

1. **必须处理非 2xx 响应体**——WorkOS 在未授权时返回 `400 {"error":"authorization_pending"}`，
   若直接用 `Invoke-RestMethod` 会抛异常且拿不到 `error` 字段。脚本用 `Invoke-WebRequest`
   配合 `catch` 读取响应流（PS 5.1）或 `$_.ErrorDetails.Message`（PS 7）。
2. **Windows PowerShell 5.1 需显式启用 TLS 1.2**。
3. 轮询遵循 `interval`，遇 `slow_down` 时 `interval += 1`。

实测记录：

```
[1/4] 申请设备码 ...                     → 200，取得 device_code / user_code
[2/4] 验证码 LZJG-DTLS，地址 https://authkit.cline.bot/device
[3/4] 等待授权确认 ...  ...              → 400 authorization_pending 被正确识别并继续轮询
      超时分支按预期抛出
```

> 注：第 4 步「兑换 Cline 令牌」需真实完成浏览器授权才能验证，沙箱内未覆盖。


## 7. curl 示例

```bash
curl -sS https://api.cline.bot/api/v1/chat/completions \
  -H "Authorization: Bearer $CLINE_API_KEY" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -H "HTTP-Referer: https://cline.bot" \
  -H "X-Title: Cline" \
  -H "X-IS-MULTIROOT: false" \
  -H "X-CLIENT-TYPE: cline-sdk" \
  -H "User-Agent: Cline/unknown" \
  -d '{
        "model": "cline-cloud/deepseek-v4.1-flash",
        "messages": [{"role": "user", "content": "ping"}],
        "stream": false
      }'
```

只读冒烟测试（不消耗推理额度）：

```bash
curl -sS https://api.cline.bot/api/v1/ai/cline/models \
  -H "Authorization: Bearer $CLINE_API_KEY" \
  -H "Accept: application/json"
```

---

## 8. 本沙箱实测观察到的事实

| 项 | 值 | 出处 |
| --- | --- | --- |
| `CLINE_API_BASE_URL` | `https://api.cline.bot` | 环境变量 |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `https://otel.cline.bot` | 环境变量 |
| `OTEL_SERVICE_NAME` | `cline-sdk` | 环境变量 |
| `CLINE_USER_ID` | `usr-01KTMXDNY3CGC3D5…`（已截断） | 环境变量 |
| `CLINE_HUB_TOKEN_PORT` | `8081` | 环境变量 |
| provider | `cline` | 会话元数据 |
| model | `cline-cloud/deepseek-v4.1-flash` | 会话元数据 |
| thinking | `true` / reasoningEffort `high` | 会话元数据 |
| cwd / workspace | `/workspace` | 会话元数据 |

**中间人代理**：沙箱内存在

```
/etc/mitm/api.cline.bot.crt | .key | .csr
/etc/mitm/otel.cline.bot.crt | .key | .csr
```

说明 `api.cline.bot` 与 `otel.cline.bot` 出站流量经 **egress MITM 代理**，凭证由代理透明注入。因此：

- 在本机直连可能“不带 token 也通”（走代理注入）；
- 换到普通环境则必须自带 token；
- **本地测试结果不可直接外推**到其他环境。

---

## 9. 复现与验证方法

本文档的 body/headers 部分来自 minified 代码反推，字段可能有遗漏。要拿到权威快照：

1. **只读验证**：调用 `/api/v1/ai/cline/models`，确认端点 + 认证可用。
2. **抓包**：用本地代理（mitmproxy）或 `NODE_OPTIONS=--http-proxy=...` 拦一次真实出站请求，dump headers 与 body（注意不要落盘 secret）。
3. **读模型目录**：从 `/api/v1/ai/cline/models` 拉取合法 model id 列表。

### 相关文件索引

```
/app/node_modules/@cline/llms/dist/models.js                 # provider 定义、端点常量、headers
/app/node_modules/@cline/llms/dist/providers.js              # headers 常量 ha/ya、provider 注册
/app/node_modules/@cline/core/dist/cloud/index.js            # HTTP 客户端、Bearer、api/v1 路径
/app/node_modules/@cline/core/dist/hub/index.js              # auth 端点表、WorkOS 设备码/PKCE、令牌兑换
/app/node_modules/@cline/core/dist/hub/daemon/entry.js       # dataDir / secrets.json / globalState.json 路径
/app/node_modules/@cline/core/dist/auth/cline.d.ts           # loginClineOAuth / startClineDeviceAuth 签名
/app/node_modules/@ai-sdk/openai-compatible/dist/index.js    # path: "/chat/completions"
/home/node/.cline/data/sessions/<id>/<id>.json               # 会话元数据（provider/model/usage）

# 本仓库内配套产物
scripts/cline-device-login.ps1                               # 设备码登录脚本（第 6.8 节）
scripts/cline-login.cmd                                      # Windows 包装脚本
docs/cline-api-notes.md                                      # 本文档
```

---

## 10. 注意事项 / 免责

- 本文档为**本地静态分析**，非官方文档；上游变更后可能失效。
- 涉及 `Authorization` 头与 `CLINE_API_KEY`，**请勿提交真实令牌**到仓库。
- 直接构造请求会绕过官方客户端，需自行复刻 headers/参数，可能受代理鉴权与速率限制影响。
- 个人信息（`CLINE_USER_ID`）已在文中截断。
- `workOsClientId`（`client_01K3A541FN8TA3EPPHTD2325AR`）是 **PKCE 公共客户端标识，非密钥**，故完整保留；
  真正的凭证是 `accessToken` / `refreshToken`，切勿外泄。
- 第 6 章的**请求参数**为代码常量（高可信）；**返回结构**（`data` 字段名）系从解析函数反推（中可信），
  实际字段可能有出入，建议先用第 1 步设备码请求做无副作用验证。
- 令牌有效期与刷新时机由服务端 `expiresAt` 决定，本文的 300s / 300000ms 仅为 SDK 默认值。
- `scripts/cline-device-login.ps1` 的**语法与 HTTP/轮询逻辑已在 PowerShell 7.4.6 实测通过**；
  Windows 11 自带的 Windows PowerShell 5.1 走的是 `catch` + 响应流读取分支，**该分支未实测**，
  如遇问题请改用 `pwsh`（`scripts/cline-login.cmd` 会自动优先选择 `pwsh`）。
- 脚本第 4 步（兑换 Cline 令牌）需真实完成浏览器授权，未经端到端验证；若返回结构不符，
  脚本会打印原始响应体便于排查。

