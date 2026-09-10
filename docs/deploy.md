# 部署指南（云端 Linux）

本指南面向把 Course Planner **后端**部署到一台公网 Linux 服务器。Web（Next.js）和
Flutter 可以随后单独部署/分发，两者都只依赖这里的 HTTP 地址。

设计前提（见 `docs/architecture.md` §7）：**后端只监听内网 HTTP，公网 HTTPS 由
反向代理或 Cloudflare Tunnel 终结**。不要把 `:8080` 直接暴露到公网——那意味着口令、
refresh token 和长效 MCP token 会在明文链路上传输。

## 1. 目标形态

```text
浏览器 / Flutter / MCP 客户端
        │  HTTPS
        ▼
  Caddy 或 Cloudflare Tunnel        ← TLS 在这一层终结
        │  HTTP 127.0.0.1:8080
        ▼
  courseplanner-server（单个静态二进制）
        │  仅内网
        ▼
  PostgreSQL 17
```

一台 1 核 1G 的小机器就够（Go 进程常驻约 30–60MB）。数据库和备份会随使用量增长。

## 2. 准备

需要：

- 一台 Linux 服务器（amd64 或 arm64），Debian/Ubuntu 或 Alpine 皆可
- 一个域名，且它的 A/AAAA 记录已指向服务器（交给 Caddy 自动申请证书时必需）
- 防火墙只放行 22（或你自己的 SSH 端口）和 80/443 —— **不要**放行 8080

发布包 `courseplanner-server-<版本>-linux.tar.gz` 里带了两个架构的静态二进制，服务器
上不需要 Go 工具链，容器构建也不需要联网拉取依赖。

## 3. 解包与配置

```bash
tar -xzf courseplanner-server-1.1.0-linux.tar.gz
cd courseplanner-server-1.1.0-linux
cat SHA256SUMS            # 可选：sha256sum -c SHA256SUMS

cp env.example .env
./scripts/gen-secrets.sh --write .env     # 生成 JWT_SECRET 和数据库口令
$EDITOR .env
```

`.env` 里必须过一遍的项：

| 变量 | 生产取值 | 说明 |
| --- | --- | --- |
| `JWT_SECRET` | `gen-secrets.sh` 生成 | **绝不要复用开发机上的值**，也不要提交 |
| `POSTGRES_PASSWORD` | `gen-secrets.sh` 生成 | 脚本只生成字母数字，避免口令里的 `@:/` 破坏 DATABASE_URL |
| `COOKIE_SECURE` | `true` | 生产必须 true，否则 refresh cookie 会在明文 HTTP 上传输 |
| `CORS_ALLOWED_ORIGINS` | 例如 `https://app.example.com` | 只有 Web 前端需要；MCP 和原生客户端不受影响。**不要填 `*`** |
| `CP_DOMAIN` | 例如 `cp.example.com` | 仅 Caddy 方案使用 |
| `LOG_LEVEL` | `info` | 排障时临时 `debug` |

`gen-secrets.sh` 默认只打印到标准输出，`--write .env` 会就地替换占位值。

## 4. 方案 A：Docker Compose（推荐）

服务器需要 Docker + Compose 插件。

```bash
docker compose up -d --build
docker compose ps
docker compose logs -f server
```

compose 做了这些事：

- `postgres` 只在 compose 内部网络上，**不映射任何端口**，数据落在命名卷 `pgdata`
- `server` 用 `bin/` 里的预编译二进制构建镜像（无需 Go、无需联网）
- 镜像 entrypoint 按 `uname -m` 选择 amd64 / arm64 二进制，省掉 build-arg 的坑
- `server` 只发布到 `127.0.0.1:8080`，即只有本机的反向代理能访问
- 首次启动自动执行迁移（`server/migrations` 已编译进二进制）

升级：`docker compose up -d --build`（迁移在启动时自动跑）。
回滚：把备份的旧二进制目录换回 `bin/`，重新 `--build`。

## 5. 方案 B：systemd 裸机（不装 Docker）

需要服务器上已有 PostgreSQL（例如 `apt install postgresql-17`）。

```bash
sudo ./deploy/install.sh
```

脚本会：创建系统用户 `courseplanner`、把对应架构的二进制装到
`/opt/courseplanner/bin/`、生成 `/etc/courseplanner/server.env`（含随机
`JWT_SECRET`）、安装并启动 `courseplanner.service`（含 systemd 加固，进程无
capability、只读文件系统）。重复执行是幂等的，不会覆盖已有的 `server.env`。

之后先建库再启动：

```bash
sudo -u postgres psql -c "CREATE USER courseplanner WITH PASSWORD '...';"
sudo -u postgres psql -c "CREATE DATABASE courseplanner OWNER courseplanner;"
sudo editor /etc/courseplanner/server.env     # 填 DATABASE_URL
sudo systemctl restart courseplanner
journalctl -u courseplanner -f
```

> 关于时区数据：二进制已内嵌 zoneinfo 作为兜底，所以即便最小化镜像里没有
> `/usr/share/zoneinfo` 也不会因为 `INVALID_TIMEZONE` 拒绝注册。系统自带时区库时
> 仍优先使用系统库。

## 6. HTTPS 终结

### 6.1 Caddy（有公网 IP + 域名，最省事）

Caddy 自动申请并续期 Let's Encrypt 证书。

```bash
sudo cp deploy/Caddyfile /etc/caddy/Caddyfile   # 按需改域名或统一改成 CP_DOMAIN
sudo systemctl reload caddy
```

`deploy/Caddyfile` 默认把 `{$CP_DOMAIN}` 反代到 `127.0.0.1:8080`。Caddy 默认就会带
正确的 `X-Forwarded-Proto`，登录页据此显示 `https://` 的 MCP 端点地址。

### 6.2 Cloudflare Tunnel（不暴露 80/443，仓档推荐的形态）

```bash
cloudflared tunnel login
cloudflared tunnel create courseplanner
cloudflared tunnel route dns courseplanner cp.example.com
cloudflared tunnel run --url http://127.0.0.1:8080 courseplanner
```

把 `cloudflared` 装成服务（`cloudflared service install`）后它随开机启动。这种方式
服务器不需要公网入站端口，适合内网/家宽/云厂商安全组默认拒绝入站的场景。

### 6.3 nginx（已有 nginx 或用 certbot）

用 `deploy/nginx.conf` 作模板（**注意 `client_max_body_size 8m`**：后端允许 4MiB
请求体用于 CSV 导入，nginx 默认 1m 会先一步把导入请求挡掉）。

## 7. 首次初始化与验证

```bash
# 1. 存活检查
curl -s https://cp.example.com/healthz

# 2. 冒烟（健康检查 + 契约 + MCP 工具列表）；注册一个账号后带上 token 跑
./scripts/smoke.sh https://cp.example.com

# 3. 注册第一个账号：timezone 一旦创建就不可修改，请选对
curl -sX POST https://cp.example.com/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"<强口令>","timezone":"Asia/Shanghai"}'
```

> `timezone` 是永久锁定的（`docs/datetime.md` §2）。选错只能重新注册账号。

接着在浏览器打开 `https://cp.example.com/mcp/connect`，登录后拿到长效 MCP token 与
客户端配置。远程使用 helper 也可以：

```bash
node scripts/mcp-connect.js --server https://cp.example.com
```

它在本机起一个回环回调（登录页的 `redirect_uri` 白名单只允许回环地址），所以这个流程
在公网部署上同样安全可用。

## 8. 接入 Agent 客户端

| 字段 | 填什么 |
| --- | --- |
| 名称 | `course-planner` |
| 类型 / transport | `http`（streamable HTTP，**不要选 sse**） |
| URL | `https://cp.example.com/api/v1/mcp` |
| Header | `Authorization: Bearer cpmcp_...` |

```json
{
  "mcpServers": {
    "course-planner": {
      "type": "http",
      "url": "https://cp.example.com/api/v1/mcp",
      "headers": { "Authorization": "Bearer cpmcp_..." }
    }
  }
}
```

只支持 stdio 的客户端用 `npx mcp-remote https://cp.example.com/api/v1/mcp --header "Authorization: Bearer ..."` 桥接。
服务端不提供 SSE 流（`GET /mcp` 返回 405），协议版本建议在客户端侧留默认、不要手填。

## 9. 日常运维

**日志**：都写到标准输出。Compose 用 `docker compose logs`，systemd 用
`journalctl -u courseplanner`。请求日志（含状态码与耗时）在 `LOG_LEVEL=debug` 时才输出。

**备份**：

```bash
./scripts/backup-db.sh                  # docker compose 场景（pg_dump | gzip）
./scripts/backup-db.sh --local          # 裸机场景（用 pg_dump + DATABASE_URL）
```

把返回的 `backups/*.sql.gz` 同步到异地。恢复：

```bash
gunzip -c backups/courseplanner-2026-09-10.sql.gz | docker compose exec -T postgres psql -U courseplanner -d courseplanner
```

**升级**：先备份 → 换二进制/镜像 → 重启（迁移自动执行）→ 跑 `scripts/smoke.sh`。
迁移只做增量（新增表/列），所以旧二进制能读新库；但**不要用旧二进制去跑已经删列的
未来迁移**——回滚前先确认这次升级没有破坏性迁移。

**`JWT_SECRET` 轮换**：换掉它会让所有**已签发的 access token 立刻失效**；
refresh token 是不透明数据库行、不受影响，客户端走一次 `/auth/refresh` 即可恢复
（Web/Flutter 都实现了 401→refresh）。MCP token 也是数据库行，不受影响。

**监控**：`GET /healthz` 返回 `{"status":"ok"}`，不含数据库探测；要判断可用性请用
`/api/v1/meta/time`（会真正走一次请求链路）或直接看 `docker compose ps` 的健康状态。

## 10. 安全清单（上线前逐条确认）

- [ ] 8080 没有暴露到公网（`ss -ltnp | grep 8080` 应只看到 `127.0.0.1`）
- [ ] PostgreSQL 端口没有暴露（Compose 默认不映射；裸机则 `listen_addresses` 保持 localhost）
- [ ] `COOKIE_SECURE=true`
- [ ] `JWT_SECRET` 是服务器上新生成的随机值，未进过仓库
- [ ] `CORS_ALLOWED_ORIGINS` 是精确源，不是 `*`
- [ ] `.env` / `server.env` 权限 600，属主是运行用户

**注册是开放的**：`POST /api/v1/auth/register` 默认对公网可用，任何人可以自助建号
（数据按用户隔离，不会互相看到）。如果你要的是单人实例，建议二选一：

- 在 Cloudflare 侧给 `api/v1/auth/register` 加一条 WAF 规则 / Cloudflare Access 策略；
- 或在 nginx/Caddy 里对该路径限制来源 IP，建号后直接拒绝。

登录失败次数在服务端按 (来源 IP, 用户名) 节流，但**整站的暴力破解防护应该放在边缘**
（Cloudflare Rate Limiting 或 nginx `limit_req`），因为后端看到的是代理的 IP。

长效 MCP token 的处置：只显示一次、只存哈希、随时可吊销（`DELETE /api/v1/mcp-tokens/{id}`）。
给只读用途的 Agent 一律发"只读"scope——那样即使 token 泄露，也只能读不能写。

## 11. 故障排查

| 现象 | 原因与处理 |
| --- | --- |
| 启动即退出，日志 `migrate: ...` | `DATABASE_URL` 错、数据库不可达、或口令里有未转义的特殊字符 |
| 容器内 `database: ping` 失败 | 用了 `localhost` 而不是 compose 服务名 `postgres`（见 compose 里的 DATABASE_URL） |
| 浏览器打开登录页提示"请求来源不被允许" | 请求经过了会改写 `Origin` 的代理。日志里有 origin/referer/host 三元组，直接查 |
| MCP 客户端连接失败 | 先带 token `curl` 打一次 `tools/list`：401 说明 token 错/已吊销；405 说明客户端配成了 sse。不带 token 时 `GET /api/v1/mcp` 会先撞上认证墙返回 401，那是正常的，不代表传输有问题 |
| 客户端报协议不兼容 | 客户端固定了过老的 `MCP-Protocol-Version`；服务端支持 2025-06-18 / 2025-03-26 / 2024-11-05 |
| 注册返回 `INVALID_TIMEZONE` | 二进制已内嵌时区数据，基本不会；若出现请确认镜像/主机时钟与 tzdata 未被人为裁剪 |
| CSV 导入 413 | 反向代理请求体上限太小，见 §6.3 |
| 登录页显示 `http://` 而站点是 https | 代理没传 `X-Forwarded-Proto: https` |
| 升级后所有客户端 401 | 换了 `JWT_SECRET`，属预期；客户端 refresh 一次即恢复 |

## 12. Web / Flutter

- **Web**：`web/` 是独立的 Next.js 应用，`NEXT_PUBLIC_API_BASE` 指向
  `https://cp.example.com/api/v1`，部署到 Vercel 或同机 Node 服务即可；记得把它的源
  加进 `CORS_ALLOWED_ORIGINS`。它调用 `/agent/changes/preview|apply` 走的是同一套
  Domain Service，与 MCP 完全等价。
- **Flutter**：把 API base 指向同一个 https 地址即可；refresh token 走 secure storage。

后端不需要为了这两端做任何额外配置。
