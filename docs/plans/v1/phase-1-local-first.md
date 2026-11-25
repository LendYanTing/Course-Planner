# Phase 1：操作全本地化与取消强制服务器同步

## 1. 阶段目标

将 Flutter 客户端从「必须登录服务器、部分核心操作强依赖服务端 API、每次修改强制后台同步」彻底改造为**「免登录开箱即用、100% 操作本地 SQLite 完成、云同步作为可选开关」**的纯本地优先架构。

本阶段需要解决以下 4 个核心问题：
1. **免登录直达首页**：首次启动或未登录时，自动创建并使用本地默认 Profile（`userId: 'local'`，默认时区 `Asia/Shanghai`，且本地模式下允许在设置中修改时区），不再强制重定向到 `/login`。
2. **调课/删课（Series Edit）全本地化**：`CalendarController.moveEvent` 与 `deleteEvent`（以及 `THIS` / `THIS_AND_FUTURE` / `ALL` 系列修改）不再调用 `services.dataApi.seriesApply(...)`，而是直接在本地 `EntityRepo` 中写入 `EntityTypes.override`（`OccurrenceOverride`）或切分/更新本地 `CourseMeeting` / `RecurringSchedule`。
3. **CSV 课程导入全本地化**：在 Dart 侧实现 CSV 解析与校验（移植 `server/internal/importcsv/parse.go` 逻辑），`ImportPage` 无需联网即可完成「解析 → 校验 → 预览 → 本地写入 `EntityRepo.createCourseWithMeetings`」。
4. **取消强制同步，改为可选云同步开关**：新增 `syncEnabledProvider`（默认 `false`）。当同步未开启或当前为本地免登录模式（`userId == 'local'`）时，**不启动 60s 定时同步、本地修改不触发自动 Push、不请求 `/meta/time`**；仅当用户在设置中登录了远端服务器并主动开启「自动云同步」或点击「立即同步」时才与服务器通信。

---

## 2. 必读现有文件

动手前请先阅读以下文件理解现状：
- `flutter/lib/state/session.dart` — 会话启动 `bootstrap()` 与登录状态管理
- `flutter/lib/app/router.dart` — `resolveAuthRedirect` 路由守卫与 `snapshotProvider` 自动触发 `schedulePush`
- `flutter/lib/state/sync_controller.dart` — `SyncCoordinatorController` 同步调度器
- `flutter/lib/state/calendar_controller.dart` — `moveEvent` / `deleteEvent` / `_seriesApply`
- `flutter/lib/sync/expander.dart` — 本地事件展开器（已完整支持 `OccurrenceOverride`）
- `flutter/lib/domain/override.dart`、`flutter/lib/domain/week_rule.dart`、`flutter/lib/core/util/week_text.dart`
- `flutter/lib/presentation/settings/import_page.dart` — 现有 CSV 导课页

---

## 3. 涉及文件清单

### 新增文件
- `flutter/lib/domain/local_series_service.dart` — 本地处理 `CourseMeeting` 与 `RecurringSchedule` 的 `THIS` / `THIS_AND_FUTURE` / `ALL` 移动、更新、取消与切分。
- `flutter/lib/domain/local_csv_import.dart` — 本地 CSV 课程表解析、字段校验、课程冲突检测与入库。
- `flutter/test/local_series_service_test.dart` — 本地调课/删课/切片单元测试。
- `flutter/test/local_csv_import_test.dart` — 本地 CSV 解析与导入单元测试。

### 修改文件
- `flutter/lib/state/prefs.dart` — 新增 `syncEnabledProvider`（是否开启自动云同步，默认 `false`）与 `localTimezoneProvider`（本地模式时区，默认 `'Asia/Shanghai'`）。
- `flutter/lib/state/session.dart` — `bootstrap()` 在无远端会话时自动建立本地默认 `SessionProfile`（`userId: 'local'`, `username: '本地用户'`, `timezone: 'Asia/Shanghai'`），并提供 `updateLocalTimezone(String tz)`；`logout()` 退回本地模式而非锁死在 `/login`。
- `flutter/lib/app/router.dart` — 修改 `resolveAuthRedirect` 与 `snapshotProvider` 监听（仅在 `syncEnabled && !session.isLocalMode` 时触发 `schedulePush()`）。
- `flutter/lib/state/sync_controller.dart` — 在 `schedulePush()`、`startPeriodicSync()`、`syncClockAndPull()` 中检查是否处于已登录云端且开启同步状态；本地模式下跳过网络请求。
- `flutter/lib/state/calendar_controller.dart` — 移除 `_seriesApply` 的 `services.dataApi.seriesApply` 远端调用，改为调用 `LocalSeriesService`，并在未开启自动同步时不主动调用 `syncNow()`。
- `flutter/lib/presentation/settings/import_page.dart` — 改为使用 `LocalCsvImporter` 本地解析、预览、调用 `EntityRepo` 写入，移除「需要联网」文案与远端 API 依赖。
- `flutter/lib/presentation/home_shell.dart`、`flutter/lib/presentation/calendar/week_page.dart`、`flutter/lib/presentation/calendar/month_page.dart`、`flutter/lib/presentation/todo/todo_page.dart`、`flutter/lib/presentation/settings/settings_page.dart` — 顶栏的同步按钮（`Icons.sync`）仅在「已登录云端账号且开启云同步」时显示；本地修改保存后不再无条件调用 `syncCoordinatorProvider.notifier.syncNow()`（统一由 `router.dart` 的 `snapshotProvider` listener 根据 `syncEnabled` 决定是否 `schedulePush`）。
- `flutter/test/router_redirect_test.dart`、`flutter/test/calendar_controller_test.dart` — 更新并补充对应测试。

---

## 4. 详细设计与分步实施指南

### Step 1：扩展 `prefs.dart` 与 `SessionController` 支持免登录本地模式

1. **在 `flutter/lib/state/prefs.dart` 中新增 `SyncEnabledController`**：
   ```dart
   class SyncEnabledController extends Notifier<bool> {
     static const _key = 'sync_enabled';

     @override
     bool build() {
       _restore();
       return false; // 默认不强制与服务器同步
     }

     Future<void> _restore() async {
       try {
         final v = await ref.read(prefStoreProvider).read(_key);
         if (v != null) state = v == 'true';
       } on Object {
         // keep default false
       }
     }

     Future<void> set(bool enabled) async {
       state = enabled;
       try {
         await ref.read(prefStoreProvider).write(_key, '$enabled');
       } on Object {}
     }
   }

   final syncEnabledProvider =
       NotifierProvider<SyncEnabledController, bool>(SyncEnabledController.new);
   ```

2. **在 `flutter/lib/state/session.dart` 中定义本地默认 Profile**：
   - 在 `SessionProfile` 或 `SessionState` 上增加便捷判断：
     ```dart
     static const localUserId = 'local';
     bool get isLocalMode => profile?.userId == localUserId;
     ```
   - 修改 `SessionController.bootstrap()`：
     - 当 `meta` 中既没有缓存的云端用户、也没有可用的 `refresh` token 时，**不要进入 `AuthPhase.signedOut`**，而是自动创建并保存本地默认 `AppMetaSnapshot`：
       ```dart
       const defaultLocalProfile = SessionProfile(
         userId: SessionState.localUserId,
         username: '本地用户',
         timezone: 'Asia/Shanghai',
       );
       await services.store.saveMeta(
         (meta ?? const AppMetaSnapshot()).copyWith(
           userId: defaultLocalProfile.userId,
           username: defaultLocalProfile.username,
           timezone: defaultLocalProfile.timezone,
         ),
       );
       state = const SessionState(
         phase: AuthPhase.signedIn,
         profile: defaultLocalProfile,
       );
       bumpSessionRevision(ref);
       ```
     - 如果恢复出来的 `profile.userId != 'local'`，且 `ref.read(syncEnabledProvider)` 为 `true`，才在后台执行 `_ensureAccessToken()` 和 `syncClockAndPull()`。
   - 新增 `Future<void> enterLocalMode()` 与 `Future<void> setLocalTimezone(String timezone)`：
     - 本地模式（`isLocalMode == true`）下允许用户在设置页切换时区并写入 `store.saveMeta(...)`。
     - 当用户从设置页主动前往 `/login` 登录云端账号成功后，`_accept(session)` 会将 `userId` 更新为云端真实 UUID，并可自动开启 `syncEnabledProvider`。
   - 修改 `resolveAuthRedirect`（`flutter/lib/app/router.dart`）：
     - 允许在 `phase == AuthPhase.signedIn && isLocalMode` 时正常访问 `/login` 和 `/register`（以便本地用户随时去设置里登录云端账号），其余时刻访问 `/` 自动跳转到 `/home/week`。

---

### Step 2：实现 `LocalSeriesService`（调课 / 删课全本地化）

新建 `flutter/lib/domain/local_series_service.dart`，将 `server/internal/series/service.go` 的核心逻辑在客户端基于 `EntitiesSnapshot` + `EntityRepo` 实现：

1. **方法签名**：
   ```dart
   class LocalSeriesService {
     LocalSeriesService({
       required this.repo,
       required this.userTime,
     });

     final EntityRepo repo;
     final UserTime userTime;

     /// 移动单次课程或周期安排 (Scope = THIS)
     Future<void> moveOccurrence({
       required EntitiesSnapshot snapshot,
       required String seriesType, // SeriesTypes.courseMeeting | SeriesTypes.recurringSchedule
       required String seriesId,
       required String occurrenceDateLocal, // 原发生日期 YYYY-MM-DD
       required DateTime newStartUtc,
       required DateTime newEndUtc,
       Map<String, dynamic> metadataPatch = const {},
     });

     /// 取消/删除单次课程或周期安排 (Scope = THIS)
     Future<void> cancelOccurrence({
       required EntitiesSnapshot snapshot,
       required String seriesType,
       required String seriesId,
       required String occurrenceDateLocal,
     });

     /// 修改或删除「此次及以后」(Scope = THIS_AND_FUTURE) 或「整个系列」(Scope = ALL)
     Future<void> applySeriesEdit({
       required EntitiesSnapshot snapshot,
       required String seriesType,
       required String seriesId,
       required String scope, // SeriesScopes.thisOne | thisAndFuture | all
       required String occurrenceDateLocal,
       required String operationType, // SeriesOperations.move | update | cancel | delete
       DateTime? replacementStartUtc,
       DateTime? replacementEndUtc,
       int? newWeekday,
       int? newPeriodStart,
       int? newPeriodEnd,
       WeekRule? newWeekRule,
       String? newStartLocal,
       String? newEndLocal,
       Map<String, dynamic> metadataPatch = const {},
     });
   }
   ```

2. **核心实现要点**：
   - **跨午夜校验**：检查 `newStartUtc` 和 `newEndUtc` 在 `userTime` 下的本地自然日必须为同一天，且 `newEndUtc.isAfter(newStartUtc)`；若跨午夜则抛出 `ApiException(code: 'CROSS_MIDNIGHT', message: '单个日程不能跨午夜', statusCode: 422)`。
   - **查找已有 Override**：在 `liveOverrides(snapshot)` 中查找是否已有同 `seriesType`、`seriesId`、`occurrenceDateLocal` 的 `OccurrenceOverride`：
     - **注意**：当用户第二次拖动已经被 `move` 过的同一个 occurrence 时，要能通过 `UiEvent.id` 或其关联的 `override` 找到原始的 `occurrenceDateLocal`（或者直接更新该条 existing override 的 `replacementStartAt` / `replacementEndAt`）！
     - 检查 `flutter/lib/sync/expander.dart` 中 `Occurrence` 是如何消费 `OccurrenceOverride` 的：
       - 若已有对应 `OccurrenceOverride`，调用 `repo.localUpdate(entityType: EntityTypes.override, entityId: existing.id, changes: ...)`；
       - 若没有，调用 `repo.localCreate(entityType: EntityTypes.override, snapshot: { 'seriesType': seriesType, 'seriesId': seriesId, 'occurrenceDateLocal': occurrenceDateLocal, 'action': OverrideAction.move.wire, 'replacementStartAt': isoInstant(newStartUtc), 'replacementEndAt': isoInstant(newEndUtc), 'metadata': metadataPatch })`。
   - **取消单次 (`cancelOccurrence`)**：
     - 同理，若已有该日的 Override 则 `localUpdate` 其 `action: 'cancel'`，否则 `localCreate` 一条 `action: 'cancel'` 的 `EntityTypes.override`。
   - **修改 `CalendarController` (`flutter/lib/state/calendar_controller.dart`)**：
     - 在 `moveEvent` 中：注意原代码第 108 行使用的是 `occurrenceLocalDate(userTime, startUtc)`（即移动后的新日期），**这在跨天拖动课程时会导致 `occurrenceDateLocal` 变成新日期而非原课程所在日期**！应当使用 `occurrenceLocalDate(userTime, event.startUtc)`（移动前的原事件日期），如果该事件本身已经是某个 override 展开出来的，则直接更新该 override 记录。
     - 将 `moveEvent` 和 `deleteEvent` 中的 `_seriesApply` 替换为调用 `LocalSeriesService`。这样在完全断网或纯本地模式下，拖动/缩放/删除课程和周期安排都能**立即生效且永不报「离线时无法修改课程/周期安排」**！

---

### Step 3：实现 `LocalCsvImporter`（CSV 导课全本地化）

1. **在 `flutter/lib/domain/week_rule.dart` 补充辅助方法**（如需要）：
   - `WeekRule restrictBefore(int week)` 与 `WeekRule restrictFrom(int week)`（用于 `THIS_AND_FUTURE` 切分周次）。
2. **新建 `flutter/lib/domain/local_csv_import.dart`**：
   - 支持 UTF-8 BOM 清理、表头别名映射（与 `server/internal/importcsv/parse.go` 一致：
     - `课程名称 / 课程名 / name / 课名` -> `name`
     - `星期 / 周几 / weekday / day` -> `weekday`（额外兼容中文 `周一`~`周日`、`星期一`~`星期日` 自动转为 `1`~`7`！）
     - `开始节数 / 起始节次 / 开始节次 / periodStart` -> `periodStart`
     - `结束节数 / 结束节次 / periodEnd` -> `periodEnd`
     - `老师 / 教师 / teacher` -> `teacher`
     - `地点 / 教室 / location` -> `location`
     - `周数 / 周次 / weeks / week` -> `weeks`
   - 校验每行数据：
     - `name` 非空且长度 <= 100
     - `weekday` 在 `1..7`
     - `periodStart >= 1` 且 `periodEnd >= periodStart`
     - 使用 `parseWeekRuleText(row['weeks'])` 解析周次，校验最大周数不超过目标学期的 `totalWeeks`
     - 校验节次是否在目标学期的 `PeriodTemplate` 中存在（提示友好：若当前学期尚未创建节次模板，可提示或自动按默认 45 分钟一节补齐所需节次模板！）
   - **同名课程合并**：
     - 如果 CSV 中有多行具有相同的 `(name, teacher, location)`（例如《高等数学》周一 1-2 节、周三 3-4 节），在提交入库时自动合并为 **1 个 `Course` + 多个 `CourseMeeting`**，调用 `repo.createCourseWithMeetings(...)` 本地入库！
3. **改造 `flutter/lib/presentation/settings/import_page.dart`**：
   - 移除 `services.importApi.previewCourses` 与 `commitCourses` 的网络调用。
   - 点击「解析并预览」时直接同步调用 `LocalCsvImporter.parseAndValidate(...)`，即时展示解析出的课程列表或行级错误。
   - 如果目标学期还没有创建足够的节次（例如 CSV 用到了第 1~10 节，但当前学期只有 0 节），在预览卡片上提供「同时自动补齐第 1~N 节默认时间模板」勾选项（默认勾选）。
   - 点击「确认导入」时直接写入本地 `EntityRepo`，完全离线可用。

---

### Step 4：收敛同步触发逻辑（取消强制同步）

1. **修改 `flutter/lib/app/router.dart` 中的 `snapshotProvider` 监听**：
   ```dart
   ref.listen(snapshotProvider, (previous, next) {
     final snapshot = next.value;
     if (snapshot == null || snapshot.pendingOps.isEmpty) return;
     final session = ref.read(sessionControllerProvider);
     final syncEnabled = ref.read(syncEnabledProvider);
     if (!syncEnabled || session.isLocalMode) return;
     ref.read(syncCoordinatorProvider.notifier).schedulePush();
   });
   ```
2. **修改 `flutter/lib/state/sync_controller.dart`**：
   - 在 `schedulePush()`、`startPeriodicSync()`、`syncNow()` 中：
     - 如果 `ref.read(sessionControllerProvider).isLocalMode` 为 `true`，`schedulePush()` 直接返回，不发起网络请求。
     - `didChangeAppLifecycleState`（从后台切回前台）时，只有当 `syncEnabled && !session.isLocalMode` 时才调用 `coordinator.syncClock()` 和 `coordinator.syncNow()`。
3. **清理散落在各 UI 页面的强制 `syncNow()` 调用**：
   - 搜索 `flutter/lib/presentation/` 和 `flutter/lib/state/` 中所有 `.syncNow()` 调用（如 `settings_page.dart`、`courses_page.dart`、`schedules_page.dart`、`tags_page.dart`、`todo_controller.dart`、`calendar_controller.dart`）。
   - 业务写操作完成后**不要直接调用 `syncNow()`**（因为 `snapshotProvider` 监听到 `pendingOps` 增加后，若开启了 `syncEnabled`，会自动防抖触发 `schedulePush()`；若未开启 `syncEnabled`，则安静保存在本地 SQLite）。
   - 只有用户显式点击 UI 上的「立即同步」按钮时，才调用 `syncNow()`。

---

## 5. 测试与验收标准

完成代码修改后，必须编写并通过以下测试：

1. **本地调课/删课测试 (`flutter/test/local_series_service_test.dart`)**：
   - 测试拖动单次课程（`CourseMeeting`）后，本地 `SyncStore` 生成了 `EntityTypes.override` 记录，且 `EventProjection` 重新投影后该周课程出现在新时间、其他周课程位置不变。
   - 测试跨天拖动单次课程，再拖动第二次时，依然正确更新同一条 override 而不会报错或丢失。
   - 测试删除单次课程（`action: cancel`），投影后该次课程消失。
   - 测试 `THIS_AND_FUTURE` 切分课程与周期日程。
2. **本地 CSV 导入测试 (`flutter/test/local_csv_import_test.dart`)**：
   - 测试标准 CSV 与中文星期（`周一`）、单双周（`1-5、7-11单、12-16双`）解析成功。
   - 测试同名课程多行自动合并为 1 门 `Course` + 多条 `CourseMeeting` 写入 `EntityRepo`。
   - 测试非法节次、超出学期总周数的行级错误提示。
3. **免登录启动与路由测试 (`flutter/test/router_redirect_test.dart`)**：
   - 测试空数据库首次 `bootstrap()` 后自动进入 `AuthPhase.signedIn`（`userId == 'local'`），路由直接放行到 `/home/week`。
   - 测试 `syncEnabled == false` 时，写入本地实体不会触发网络同步请求。
4. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保所有测试 100% 绿灯。
