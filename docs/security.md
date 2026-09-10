# Security

## 1. Password

使用 Argon2id。

禁止：

- plaintext password
- MD5
- SHA1
- SHA256(password)

## 2. Tokens

推荐：

```text
Access Token: 15-30 min
Refresh Token: 30 days or policy-defined
```

Web：

- Refresh Token 使用 HttpOnly + Secure cookie
- Access Token 尽量保存在内存

Flutter：

- Refresh Token 使用 secure storage
- Access Token 保存在内存

## 3. TLS Boundary

Backend 可以只提供 HTTP，但公网必须经过 HTTPS TLS termination。

绝不能直接把明文 Backend 暴露到公网。

## 4. Authorization

所有实体查询和修改都必须附带：

```text
authenticated_user_id
```

任何：

```text
GET /todos/{id}
```

都必须检查 Todo 是否属于当前用户。

## 5. Mass Assignment

不要直接把 JSON bind 到数据库实体后保存。

使用显式 request DTO -> domain command。

例如只允许客户端修改明确允许的字段。

## 6. Input Validation

服务端再次验证：

- timezone
- datetime
- cross-midnight
- week ranges
- period ranges
- ownership
- enum values
- string length

## 7. Security Logs

记录：

- login success/failure
- refresh/revoke
- suspicious repeated failures
- permission denial

不要把 password、refresh token、Authorization header 写进日志。

## 8. CSRF

如果 Web 使用 cookie 承载 refresh token，需要按部署方式启用合适的 SameSite / CSRF 防护。

## 9. CORS

不要使用：

```text
Access-Control-Allow-Origin: *
```

并允许凭证时保持明确 origin allowlist。

## 10. Secrets

不要提交：

- JWT secret
- database password
- refresh token signing key
- MCP credentials
- Cloudflare token

使用环境变量或 secret manager。

## 11. MCP Credentials

长效 MCP token 是典型的"高价值、长期有效"凭证，按以下规则处理：

- 明文只在创建响应中出现一次；服务端只保存 SHA-256 哈希
- 默认永不过期，因此吊销能力必须可用：`DELETE /mcp-tokens/{id}` 立即失效
- 只读 scope：`read` 令牌不能调用任何写路径（MCP write 工具、`preview_changes`、
  `apply_changes`、`/agent/changes/*`、`/sync/push`，以及其余非 GET 请求），
  越权返回 `FORBIDDEN`
- 令牌只能在 HTTPS 边界之后分发；`/mcp/connect` 的 `redirect_uri` 白名单限定
  回环地址，避免登录页变成 token 外泄渠道
- 不要写进仓库、日志或示例文件；`.mcp.json` 之类的本地客户端配置必须 gitignore
- 登录失败与越权访问写入 `auth_events`（`login_failure` / `denied`），
  日志中绝不出现 token 明文或 `Authorization` 头
