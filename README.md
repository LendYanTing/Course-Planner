# Course Planner

跨平台课程表 / 日程规划 / Todo / 离线同步 / MCP Agent 系统。

Go 后端 + PostgreSQL，Next.js 网页端，Flutter 客户端（Windows / Android）。**离线优先**：本地 SQLite 是工作副本，联网后自动与服务端同步；同一个 App 可以切换多个服务器。

## ✨ 立即体验（免部署）

打开就能用：

| | 地址 |
| --- | --- |
| 后端 API | <https://course.lendwishes.moe> |
| 网页版 | <https://course-planner.lendwishes.moe> |

- **网页版**：打开即用，无需安装。
- **Android**：到 Releases 下载最新 APK。首次启动在「服务器地址」填 `https://course.lendwishes.moe` 即可（不带路径时会自动补 `/api/v1`）。
- 想要自己的数据？直接注册一个账号。

## Features

**双形态周视图**
- **时间轴周视图**：7×24 连续网格，可拖动/缩放时间块，当前时间橙线，截止时间红线。
- **课表（Grid）视图**：横 = 星期、竖 = 第几节，按学期节次模板裁剪事件，上午/下午双色分区。
- 两种模式一键切换，**切换状态会被记住**。手机上是滑动滚动、**长按**色块拖动/缩放。
- 中午分界点可配置（新疆等地习惯 14:00 才算下午），课表行高与月视图行高都能自己调。

**学期与节次模板**
- 一个学期 = 第一周周一 + 总周数 + 节次模板（第几节、几点上课/下课）。
- 添加节次时**编号自动顺延**，开始时间默认取「上一节下课 + 10 分钟」，不用每次重填。

**Todo 与时间块**
- 两种类型语义分明：**一次性**（临时活动、会议、购物清单：最多 1 个时间块、不设截止时间）与**项目**（多阶段：可拆多个时间块、可设截止时间）。
- 时间块带备注（写明这块具体做什么）和状态（已安排/进行中/已完成/已跳过）。
- 分类**折叠分组**展示，标签多选筛选；分类和标签可以在新建待办时直接创建。
- 颜色：课程可选色（或留默认），**时间块自动跟随所属分类的颜色**。

**离线优先 + 可解释同步**
- 所有修改先写本地镜像并立刻上屏，后台按 `pull → push → pull` 推送。
- 队列、游标、冲突都落在本地 SQLite；断网可用，恢复后自动补齐。
- 冲突逐字段对比「本次修改 vs 服务器」，并说明**这个实体来自哪里**（属于哪个待办 / 课程 / 学期），可选保留任一侧。

**多服务器**
- 登录时填服务器地址；设置里可随时切换到另一个服务器，并选择 **云端覆盖本地** 或 **本地覆盖云端**。
- 各服务器的登录凭据分开保存，切换不会串用；也不会把 A 服务器的数据推到 B。

**完整备份**
- 一键导出全部本地数据 + 登录凭据为 JSON；导入时可**按类别勾选**（服务器地址 / 登录凭据 / 学期与课程 / 待办与时间块 / 分类与标签 / 未上传改动）。
- 导入是**本地优先**：写入本地并排队上传；导入前会自动先导出一份当前数据作为安全备份。

**课程导入**
- CSV 一键导入，支持 `1-5、7-11单、12-16双` 这类周次语法；服务端解析 → 预览 → 确认 → 提交。

**时间语义**
- 用户时区由服务器固定下发（注册后不可改），**绝不使用设备时区**解释排课数据；当前时间用 `/meta/time` 的偏移估算，设备时钟不准也不影响。

## 🤖 MCP 能力

内置 MCP（Model Context Protocol）服务端，让 AI Agent 直接读改你的课表与待办。

- **端点**：`<backend>/api/v1/mcp`，**Streamable HTTP** 单一端点（服务端不提供 SSE 流，客户端 transport 请选 `http`，不要选 `sse`）。
- **24 个工具**：读取无需确认，写入走「预览 → 一次性确认 → 原子应用」。

| 类别 | 工具 |
| --- | --- |
| 读取 | `get_current_time` `get_user_timezone` `get_calendar` `get_courses` `get_schedule` `get_todos` `get_todo` `get_free_slots` `search_todos` `search_courses` |
| 待办 | `create_todo` `update_todo` `delete_todo` `create_todo_block` `update_todo_block` `delete_todo_block` |
| 课程 / 周期 | `create_course` `update_course` `delete_course` `create_recurring_schedule` `update_recurring_schedule` `delete_recurring_schedule` |
| 写入确认 | `preview_changes`（生成 ChangeSet，返回 `confirmationId`）→ `apply_changes`（整批一个事务，成功全提交、失败全回滚） |

**拿凭证（二选一）**

1. **App 内一键获取**：设置 → 连接到 MCP → 填名称、选是否允许写入 → 「一键获取 MCP Token」。页面会把 URL、请求头名称、请求头值以及各客户端的命令 / JSON **逐项分开**显示，每项自带复制按钮。
2. **网页换取**：浏览器打开 `<backend>/mcp/connect`，登录后签发。

凭证是 `cpmcp_` 开头的**长效不透明令牌**（默认永不过期、可随时吊销，服务端只保存 SHA-256 哈希，明文只出现一次）。`scopes` 可选 `read`（只读）或 `read,write`；只读令牌调用任何写工具都会被拒绝。

> 客户端配置里要放 MCP Token，**不要**放 15 分钟就过期的 access token。

**接入示例**（把 `<url>` `<token>` 换成上面拿到的值）

```json
{
  "mcpServers": {
    "course-planner": {
      "type": "http",
      "url": "<url>",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

```bash
# Claude Code
claude mcp add --transport http course-planner <url> --header "Authorization: Bearer <token>"
# 仅支持 stdio 的客户端
npx mcp-remote <url> --header "Authorization: Bearer <token>"
# 自检：应返回 result.tools
curl -s <url> -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

VS Code / Copilot 的 `.vscode/mcp.json` 顶层键是 `servers` 而不是 `mcpServers`，其余相同。详见 [`docs/mcp.md`](docs/mcp.md)。

## 🚀 快速上手

### 方式一：直接用云端实例

见上面的「立即体验」。网页版打开即用；Android 装好 APK 后在登录页填 `https://course.lendwishes.moe`。

### 方式二：自部署

```bash
git clone <this-repo> && cd Course-Planner
sudo ./deploy/install.sh --domain course.example.com     # 一键安装（后端 + PostgreSQL + TLS 边缘）
```

`deploy/install.sh` 会生成密钥、建库、起服务并做一次冒烟测试；另有 `deploy/gen-secrets.sh`、`deploy/backup-db.sh`、`deploy/smoke.sh`。细节见 [`docs/deploy.md`](docs/deploy.md)。

### 方式三：本地开发

```bash
./scripts/dev.sh                       # 本地起后端 + PostgreSQL
./scripts/test-all.sh                  # 全量测试（server / web / flutter）

cd web && npm ci && npm run dev        # 网页端
cd flutter && flutter run -d windows    # 桌面端
flutter build apk --release            # Android
```

Flutter 端指向本机后端：

```bash
flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:8080/api/v1
```

Android 模拟器访问宿主机要用 `http://10.0.2.2:8080/api/v1`。

### 打包 Android 发布版（签名）

```bash
keytool -genkeypair -v -keystore "$env:USERPROFILE\keys\course-planner-upload.jks" \
  -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cp flutter/android/key.properties.example flutter/android/key.properties   # 填密码与路径
cd flutter && flutter build apk --release --split-per-abi
```

完整说明见 [`flutter/android/README-signing.md`](flutter/android/README-signing.md)。

## 📥 如何导入课程

**设置 → 导入课程（CSV）**，粘贴或上传 CSV，服务端解析 → 预览 → 确认 → 提交（客户端不重复实现解析器）。

```csv
课程名称,星期,开始节数,结束节数,老师,地点,周数
高等数学,1,1,2,小明,逸夫楼201,1-5、7-11单、12-16双
线性代数,2,3,4,小红,理工楼110,1-16
大学英语,2,3,4,小红,文成楼125,2、5、8
```

- 星期 1–7（周一起），开始节数 ≤ 结束节数，周数不能超出学期范围。
- 周次支持区段与奇偶：`1-16`、`1-5`、`2、5、8`、`1-5、7-11单、12-16双`；分隔符 `、` `，` `,` 与空格都兼容。
- `开始节数=1, 结束节数=3` 表示**一个连堂课**（一个 CourseMeeting），不会拆成三节课。
- 校验失败会逐行返回 `line / field / code / message`。

导入前请先在**设置 → 学期管理**里建好学期与节次模板，否则没有节次可映射。

也可以让 Agent 通过 MCP 的 `create_course` 等工具建课（写入需 preview → apply 确认）。

## 🏗 架构模式

**单仓库三端 + 契约先行**

```text
Course-Planner/
├── server/     Go 后端：REST API + 同步日志 + MCP 服务端
├── web/        Next.js 网页端
├── flutter/    Flutter 客户端（Windows / Android）
├── docs/       契约与设计：openapi.yaml、领域模型、同步协议、时区、部署…
├── deploy/     部署资产：Dockerfile / compose / Caddyfile / install.sh / smoke.sh
└── scripts/    开发脚本
```

**契约是唯一真相**：`docs/openapi.yaml` 定义所有接口，三个端都按它实现。任何影响跨端通信、数据语义、时间语义或同步语义的改动，都要先改文档与契约。

**分层**（以 Flutter 端为例，各端同构）

```text
UI (presentation)  →  Riverpod state  →  Repo / SyncEngine  →  SQLite 镜像  ⇄  后端
```

**离线优先的数据流**

```text
用户操作
  → 写本地镜像 + 追加一条 pending operation（同一事务）
  → UI 立刻重绘（乐观更新）
  → 后台同步：pull（拉服务端日志）→ push（推队列）→ pull（拉回权威快照）
```

- 队列、游标、冲突都在本地；断网照常可用，联网自动补齐。
- 服务端是不可变的**日志（journal）**，客户端用游标增量拉取；推送被接受后会再拉一次，把服务端产出的权威快照落到镜像。
- 冲突按字段比对，交给用户逐条决定保留本地还是服务器。
- 「硬刷新」保留未上传的改动，清空镜像并从日志重建。

**时间语义**：所有排课数据都用用户固定 IANA 时区解释，canonical 存储仍是 UTC；设备时区不参与。

**安全**：Argon2id 存密码；access token（JWT，短效）用于鉴权，refresh token 与 MCP token 都只存哈希；客户端 token 存平台安全存储（DPAPI / Keychain / Keystore），并按服务器隔离。

## 📚 文档

| 文档 | 内容 |
| --- | --- |
| [`docs/openapi.yaml`](docs/openapi.yaml) | API 契约（唯一真相） |
| [`docs/architecture.md`](docs/architecture.md) | 架构与数据流 |
| [`docs/domain-model.md`](docs/domain-model.md) | 领域模型（课程 / 节次 / 待办 / 时间块 / 截止 / 标签） |
| [`docs/sync-protocol.md`](docs/sync-protocol.md) | 离线同步协议、冲突、硬刷新 |
| [`docs/datetime.md`](docs/datetime.md) | 时区与时间语义 |
| [`docs/mcp.md`](docs/mcp.md) | MCP 契约与客户端接入 |
| [`docs/csv-import.md`](docs/csv-import.md) | CSV 导入契约 |
| [`docs/deploy.md`](docs/deploy.md) | 部署与运维 |
| [`docs/security.md`](docs/security.md) | 安全模型 |
| [`docs/grid-view-web.md`](docs/grid-view-web.md) | 课表（Grid）视图规格 |
| [`docs/ui-interaction.md`](docs/ui-interaction.md) | 交互规格 |

