# [画面替换] 占位变体绑定 taskId + 超时可重试拉取，杜绝「本地失败但平台成功且扣费」

> 对齐 macOS 已完成的改造。Windows 端按本文逐条实现，**细节已全部对齐，无需再讨论**。
> macOS 对应改动文件：`Wan25VideoEditClient.swift` / `ShotVariantService.swift` / `ShotVariant.swift` /
> `ShotEditViewModel.swift` / `ShotEditSheet.swift`。

## 一、问题现象

Windows 用户对某分镜做「画面替换（AI 重绘）」，**App 里显示「生成失败（超过 10 分钟超时）」，但阿里 DashScope 平台上任务其实成功了、并已扣费**。用户白花钱且拿不回成片。

## 二、根因（已用真实日志 + 真实 API 请求定位）

日志证据（`mixcut-20260716.log`）：

```
15:26:34  [ShotEditDiag] 提交成功 taskId=43d56718-b1c6-4403-af9a-5ecb4454c326
15:36:38  [ERR] 变体生成失败  ShotEditException: 画面替换生成超时（超过 10 分钟）   ← 正好卡 10 分钟
15:38:11  [ShotEditDiag] 提交成功 taskId=62837fc6-242d-4349-b921-a92e0fc55d92
15:48:15  [ERR] 变体生成失败（超过 10 分钟）                                        ← 又是正好 10 分钟
```

- 画面替换走阿里 `wan2.7-videoedit` **异步任务**：提交拿 `taskId` → 轮询 `GET /tasks/{id}` 直到 `SUCCEEDED`。
- **阿里按「任务成功执行完成」计费**，跟客户端有没有把结果取回来无关。任务在云端跑成功了 → 平台显示成功 + 扣费。
- 客户端 `WanVideoEditClient.EditAsync` 把轮询上限写死 `MaxPolls=40 × 15s = 10 分钟`，到点抛 `ShotEditException("超过 10 分钟")`。10 秒长的片段（下载45）编辑就要 >10 分钟，于是本地超时报「失败」，但云端继续跑完并计费。
- **致命点**：`taskId` 只是 `EditAsync` 内的局部变量，从不返回、从不落库。`ShotVariant.TaskId` 字段虽已存在（`src/MixCut/Models/ShotVariant.cs:45`），但**全仓库 0 处赋值**（`git grep -i taskid` 仅命中定义）。超时即丢弃 taskId → 无法用它查回结果 → 用户点「重试」是**重新提交一个全新任务、再扣一次费**。

## 三、阿里 API 真实行为（已用 curl 实测，务必按此实现，别猜）

| 场景 | HTTP | 响应体 | 判定 |
|---|---|---|---|
| 任务成功 | 200 | `output.task_status=SUCCEEDED` + `output.video_url` | 成功（URL 24h 过期，立即下载）|
| 任务进行中 | 200 | `output.task_status=PENDING` / `RUNNING` | 仍在跑，继续轮询 |
| 任务失败 | 200 | `output.task_status=FAILED` + `message/code` | 失败，展示原因 |
| **任务不存在 / 已过期(超24h) / 非本账户** | **200** | `output.task_status="UNKNOWN"`（无 code）| **过期**（`.expired`）|
| key 无效 | 401 | `{"code":"InvalidApiKey","message":"..."}`（无 output）| 鉴权错误 |

> 关键：**过期不是 404，是 HTTP 200 + `task_status=UNKNOWN`**。别用状态码判过期，要读 `task_status`。

## 四、目标设计：把「变体」从『成品』重构为『一个任务的句柄』

### 4.1 状态机（`ShotVariantStatus` 新增 `TimedOut` 一档，字符串存储，**零数据库迁移**）

`ShotVariant.TaskId`（字段已存在）+ `StatusRaw`（字符串）都不用改表结构，只新增枚举值。

| 状态 | 含义 | TaskId | 卡片主操作 | 是否会扣费 |
|---|---|---|---|---|
| `Generating` | 已提交、taskId 已落库、本地轮询中 | 有 | （无/转圈） | — |
| `Completed` | 查到 SUCCEEDED、结果已下载 | 有 | 无（仅删除） | — |
| **`TimedOut`（新增）** | 本地轮询到点仍无结果，云端可能还在跑 | 有 | **重试**＝同 taskId 再查（自动续查）| ❌ 不扣 |
| `Failed`·提交失败 | 提交阶段就挂了，**没拿到 taskId** | **无** | **重试**＝重新提交（之前没扣过费）| ❌ 之前没扣 |
| `Failed`·阿里FAILED | 阿里返回 FAILED，有具体原因 | 有 | **重新生成**（弱化+二次确认，会计费）| ✅ 新任务扣费 |
| `Failed`·结果过期 | `task_status=UNKNOWN`，旧结果没了 | 有 | **重新生成**（弱化+二次确认，会计费）| ✅ 新任务扣费 |

### 4.2 防重复扣费·铁律

1. **`TaskId != null` 的占位永不自动重提**。唯一会产生新扣费的动作叫「**重新生成**」，只在 `阿里FAILED / 结果过期 / 无taskId` 三种确实拿不回旧结果时出现，且**视觉弱化 + 二次确认弹窗（写明"会计费"）**。
2. `TimedOut` 只给「**重试**」＝用旧 taskId 查询，**绝不重提、不扣费**。
3. `TaskId` **只在提交成功那一刻写一次**（`OnTaskCreated` 回调里），失败/超时的 catch 分支**绝不清空 TaskId**（清空了就没法查回了）。「重新生成」里可以清空（旧任务已废）。

## 五、逐文件改法（对齐 macOS）

### 5.1 `Services/ShotEdit/WanVideoEditClient.cs`：把 `EditAsync` 拆成 `SubmitAsync` + `PollOnceAsync`

- 删除单一的 `EditAsync`（提交+轮询+超时揉在一起）。
- 新增：
  ```csharp
  public enum PollOutcome { Succeeded, Running, Failed, Expired }
  public readonly record struct PollResult(PollOutcome Outcome, string? VideoUrl, string? FailReason);

  // 只提交，返回 taskId（不等待结果）。缺 key / 提交 HTTP 失败 / 无 task_id → 抛 ShotEditException
  public async Task<string> SubmitAsync(string videoFilePath, string prompt, CancellationToken ct);

  // 只查一次，幂等只读、不计费
  public async Task<PollResult> PollOnceAsync(string taskId, CancellationToken ct);
  ```
- `PollOnceAsync` 内解析 `output.task_status`：
  - `SUCCEEDED` → 有 `video_url` 则 `Succeeded`（http 升 https，逻辑照旧）；无则 `Failed("任务成功但未返回结果视频地址")`
  - `FAILED` / `CANCELED` → `Failed(message ?? code ?? "task failed")`
  - **`UNKNOWN` → `Expired`**
  - 其它（`PENDING`/`RUNNING`/未知）→ `Running`
- `SubmitAsync` 保留原提交体（`resolution:720P / ratio:9:16 / duration:0 / watermark:false / prompt_extend:true`、`X-DashScope-Async:enable`、Base64 内联 media）。
- 轮询上限**从这里挪走**（交给 ShotVariantService）。

### 5.2 `Services/ShotEdit/ShotVariantService.cs`：编排提交+轮询，暴露 `GenerateAsync` / `ResumeAsync`

- 轮询参数放这里：`PollIntervalSeconds=15`，`MaxPolls=80`（**= 20 分钟**，比原来 10 分钟宽；到点转 `TimedOut`，不空耗）。
- 定义终局：
  ```csharp
  public enum VariantOutcome { Completed, Failed, Expired, TimedOut }
  public readonly record struct VariantResult(VariantOutcome Outcome, string? ResultVideoPath, string? ThumbnailPath, string? FailReason);
  ```
- `GenerateAsync(...)` 流程：切片 → `SubmitAsync` 拿 taskId → **`onTaskCreated(taskId)` 回调**（调用方立即落库）→ 进入 `PollToOutcomeAsync`。
  - **throws 只保留给「提交阶段失败」**（切片失败 / `SubmitAsync` 抛错）；这类**无 taskId、没扣费**，调用方 catch 后置 `Failed`（TaskId 保持 null）。
  - 拿到 taskId 之后一律以 `VariantResult` 返回（**不再 throw**），避免误判成「没扣费可重提」。
- `ResumeAsync(taskId, ...)`：跳过切片和提交，直接 `PollToOutcomeAsync(taskId)`——超时重试走这里。
- `PollToOutcomeAsync`：循环 `MaxPolls` 次，每次 `Delay(15s)` + `PollOnceAsync`：
  - `Succeeded` → 下载结果视频（`HttpClient`，24h 过期立即下）+ 抽首帧缩略图 → `Completed`
  - `Failed(r)` → `Failed`(r) ；`Expired` → `Expired` ；`Running` → onStatus("生成中") 继续
  - 循环结束仍没终局 → `TimedOut`

### 5.3 `Models/ShotVariant.cs`：枚举加一档

```csharp
public enum ShotVariantStatus { Pending, Uploading, Generating, Completed, TimedOut, Failed }
```
`TaskId` 字段已存在，无需动表结构。（EF Core：新增枚举值以字符串存 `StatusRaw`，无迁移。）

### 5.4 `ViewModels/ShotEditViewModel.cs`：落 taskId + 三个入口 + 状态机落库

- `GenerateVariantAsync`（首次）：新建占位（`Generating`, `TaskId=null`）→ 调 `GenerateAsync`，
  在 `onTaskCreated` 里**立刻 `variant.TaskId = tid; SaveChanges()`**（用 `variantId` 定位，别跨线程持有实体）→ `Apply(outcome)`。
  catch（提交失败）→ `Failed` + `FriendlyError="提交失败：..."`，**TaskId 保持 null**。
- `RegenerateAsync(variant)`（重新生成，会计费）：复用同一条记录 → 清 `TaskId=null` + `FriendlyError=null` → `Generating` → 同 `GenerateAsync`。用于 `Failed`（不论有无 taskId）。
- `RetryFetchAsync(variant)`（超时重试，不计费）：`guard variant.TaskId != null` → 置 `Generating`（界面显示"云端生成中"）→ 调 `ResumeAsync(taskId)` → `Apply(outcome)`。
  catch（网络抖动）→ **回退 `TimedOut`**（保留 taskId，可再重试），置 errorMessage。
- `Apply(outcome, variant)`：
  ```
  Completed → 写 ResultVideoPath/ThumbnailPath + Completed + 清 FriendlyError
  TimedOut  → TimedOut + FriendlyError="本地等待已超过 20 分钟，任务可能仍在云端生成。点「重试」重新获取结果，不会重复扣费。"
  Failed(r) → Failed  + FriendlyError="生成失败：{r}"
  Expired   → Failed  + FriendlyError="云端结果已过期（阿里仅保留 24 小时），需重新生成（会重新计费）。"
  ```

### 5.5 `Views/ShotEditWindow.xaml(.cs)`：三档视觉 + 感叹号 tooltip + 按钮矩阵

- 占位画面（非 Completed）分三档：
  - `Generating`：转圈 + 阶段文案（切片中/上传中/生成中/下载结果）
  - `TimedOut`：**琥珀色**感叹号（`clock.badge.exclamationmark` 语义）+「已超时」，鼠标悬停 tooltip = `FriendlyError`
  - `Failed`：**红色**感叹号 +「失败」，悬停 tooltip = `FriendlyError`（提交失败原文 / 阿里 FAILED 原文 / 过期说明）
- 卡片底部按钮矩阵（对齐 macOS `variantActions`）：
  | 状态 | 按钮 | 行为 |
  |---|---|---|
  | `TimedOut` | 「重试」 | `RetryFetchAsync`（查旧任务，不计费）tooltip:"重新获取这次任务的结果，不会重复扣费" |
  | `Failed` 且 `TaskId==null` | 「重试」 | `RegenerateAsync`（重新提交，之前没扣费）tooltip:"上次没提交成功、未扣费，点此重新发起" |
  | `Failed` 且 `TaskId!=null` | 「重新生成」 | 弹**二次确认**（"会发起新任务并按次计费"）→ 确认后 `RegenerateAsync` |
  | `Completed` | 无（仅删除） | — |
- 二次确认弹窗文案："重新生成会发起一次新任务并按次计费，确定吗？"，正文带该变体的 `FriendlyError`，按钮「重新生成（计费）」/「取消」。

## 六、验收清单（Windows 端自测）

1. 正常短片段生成：提交后 DB 里 `ShotVariant.TaskId` **立刻有值**（提交成功即写，不是完成才写）。
2. 造超时：把 `MaxPolls` 临时改 2（=30s）跑一次长任务 → 卡片显示**「已超时」（琥珀感叹号）**，不是「失败」；hover 出提示；有「重试」按钮。
3. 点「重试」→ 走 `ResumeAsync` 用**同一个 taskId**（看日志 taskId 不变），查到 SUCCEEDED 直接下载成片，**平台不产生第二次扣费**。
4. 用一个查不到的 taskId（换账户/隔天）→ 卡片「失败」，tooltip 显示"结果已过期"，按钮是**「重新生成」**并弹二次确认。
5. 断网提交 → 「失败」且 `TaskId==null`，按钮「重试」＝重新提交。
6. `Completed` 卡片：只有删除，**没有**重试/重新生成按钮。
7. 切项目/重开窗口后，`TimedOut` 占位仍在、taskId 仍在、「重试」仍可用（落库生效）。

## 七、附：macOS 侧改动摘要（可对照 diff）

- `Wan25VideoEditClient`：`edit()` 拆成 `submit()` + `poll()`；`PollOutcome{succeeded/running/failed/expired}`；`UNKNOWN→expired`。
- `ShotVariantService`：`generate(onTaskCreated:)` + `resume(taskId:)`；`Outcome{completed/failed/expired/timedOut}`；`maxPolls=80`(20min)。
- `ShotVariant`：`ShotVariantStatus` 加 `timedOut`。
- `ShotEditViewModel`：`generateVariant` / `regenerate` / `retryFetch` + `persistTaskID`(提交即落库) + `apply(outcome)`。
- `ShotEditSheet`：`variantPlaceholder`(三档) + `variantActions`(按钮矩阵) + `.help()` tooltip + `confirmationDialog`(计费二次确认)。
