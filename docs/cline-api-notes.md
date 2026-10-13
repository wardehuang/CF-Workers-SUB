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
| 协议族 | OpenAI-compatible（`@ai-sdk/openai-compatible`） |
| 响应信封 | `success-data`（形如 `{ success, data }`） |

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


---

## 6. curl 示例

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

## 7. 本沙箱实测观察到的事实

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

## 8. 复现与验证方法

本文档的 body/headers 部分来自 minified 代码反推，字段可能有遗漏。要拿到权威快照：

1. **只读验证**：调用 `/api/v1/ai/cline/models`，确认端点 + 认证可用。
2. **抓包**：用本地代理（mitmproxy）或 `NODE_OPTIONS=--http-proxy=...` 拦一次真实出站请求，dump headers 与 body（注意不要落盘 secret）。
3. **读模型目录**：从 `/api/v1/ai/cline/models` 拉取合法 model id 列表。

### 相关文件索引

```
/app/node_modules/@cline/llms/dist/models.js                 # provider 定义、端点常量、headers
/app/node_modules/@cline/llms/dist/providers.js              # headers 常量 ha/ya、provider 注册
/app/node_modules/@cline/core/dist/cloud/index.js            # HTTP 客户端、Bearer、api/v1 路径
/app/node_modules/@cline/core/dist/hub/index.js              # auth 端点表
/app/node_modules/@ai-sdk/openai-compatible/dist/index.js    # path: "/chat/completions"
/home/node/.cline/data/sessions/<id>/<id>.json               # 会话元数据（provider/model/usage）
```

---

## 9. 注意事项 / 免责

- 本文档为**本地静态分析**，非官方文档；上游变更后可能失效。
- 涉及 `Authorization` 头与 `CLINE_API_KEY`，**请勿提交真实令牌**到仓库。
- 直接构造请求会绕过官方客户端，需自行复刻 headers/参数，可能受代理鉴权与速率限制影响。
- 个人信息（`CLINE_USER_ID`、`workOsClientId`）已在文中截断。

