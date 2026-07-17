# [Bug] 生成方案提示「方案生成失败」，但关闭重开后方案都在 —— SegmentDubs 表缺 `CaptionLinesJson` 列（迁移顺序错 + 建表 DDL 漏列）

## 一、现象（用户原话）

生成方案时界面提示「**方案生成失败**」；但把软件关掉再打开，发现**方案其实都已经生成好了、也都在里面**。

## 二、结论（一句话）

**方案本身已经生成并成功落库了**。失败发生在「保存之后紧接着的重新加载」那一步：该查询要读 `SegmentDubs.CaptionLinesJson` 这一列，而这一列在该用户的数据库里**不存在** → 抛 SQLite 异常 → 被 `GenerateSchemesAsync` 的 catch 捕获 → 弹「方案生成失败」并把项目状态回滚。**下次启动时迁移会把这一列补上，于是自愈、方案正常显示** —— 这正是「关掉重开就都在」的原因。

## 三、根因（已用用户日志逐行确认）

### 3.1 失败点：保存成功后的 LoadSchemes 撞到不存在的列

`SchemeViewModel.GenerateSchemesAsync` 流程（`src/MixCut/ViewModels/SchemeViewModel.cs`）：

```
312  _context.SaveChanges();          // ← 方案（Strategies/Schemes/SchemeSegments）已全部落库
314  LoadSchemes(project);            // ← 保存后重新加载，这一步抛异常
...
324  catch (Exception ex) {
325      ErrorMessage = $"方案生成失败：...";   // ← 误报「生成失败」
331      RollbackGeneratingStatus(dbProject);  // ← 把项目状态回滚
     }
```

`LoadSchemes`（`:100`）eager-load 了各分镜的配音变体：

```csharp
_context.Strategies
    .Include(s => s.Schemes).ThenInclude(sc => sc.SchemeSegments).ThenInclude(ss => ss.Segment!)
        .ThenInclude(seg => seg.SegmentDubs)   // ← 带出 SegmentDubs
    .AsSplitQuery()...
```

EF 生成的 SQL 会 `SELECT "s3"."CaptionLinesJson"`，SQLite 报：

```
[ERR] SchemeViewModel: 方案生成失败: SQLite Error 1: 'no such column: s3.CaptionLinesJson'.
   at MixCut.ViewModels.SchemeViewModel.LoadSchemes(...) :line 100
   at MixCut.ViewModels.SchemeViewModel.GenerateSchemesAsync(...) :line 314
```

### 3.2 为什么 `SegmentDubs.CaptionLinesJson` 列不存在 —— 两个叠加缺陷

看启动迁移 `src/MixCut/App.xaml.cs`：

```
1007  AddColumnIfMissing(db, "SegmentDubs", "ParticipatesInCombination", "INTEGER NOT NULL DEFAULT 0");
1009  AddColumnIfMissing(db, "SegmentDubs", "CaptionLinesJson", "TEXT");   // 补列
...
1043  CreateTableIfMissing(db, "SegmentDubs", @"CREATE TABLE IF NOT EXISTS ""SegmentDubs"" ( ... )");  // 建表
```

**缺陷 A —— 补列排在建表之前（顺序错）**
对于**数据库里还没有 `SegmentDubs` 表**的用户（= 之前从没用过「配音」功能的老库用户），第 1007/1009 行执行补列时表还不存在，直接失败：

```
[ERR] [SchemaMigration] 补列失败 SegmentDubs.ParticipatesInCombination
      SqliteException: SQLite Error 1: 'no such table: SegmentDubs'.
[ERR] [SchemaMigration] 补列失败 SegmentDubs.CaptionLinesJson
      SqliteException: SQLite Error 1: 'no such table: SegmentDubs'.
```

（异常在 `AddColumnIfMissing` 内被吞掉、只记日志，不中断启动。）

**缺陷 B —— 建表 DDL 过时，漏了 `CaptionLinesJson` 列**
随后第 1043 行才建表，而这段硬编码 CREATE TABLE 的列清单是：
`Id, SegmentId, VoiceId, VoiceProvider, TextVariantIndex, RewrittenText, AudioFilePath, AudioDuration, AtempoFactor, FreezePadFrames, TrailingSilence, GeneratedForStartFrame, GeneratedForEndFrame, GeneratedForTextHash, StatusRaw, ParticipatesInCombination`
—— **有 `ParticipatesInCombination`，唯独没有 `CaptionLinesJson`**（加「逐句字幕」功能时补了 `AddColumnIfMissing`，却忘了同步进这段 CREATE TABLE）。

**叠加结果**：这类用户首次运行 → 补列失败(表没建) → 建表(没这列) → `SegmentDubs` 表建好了但**缺 `CaptionLinesJson`** → 之后任何 eager-load `SegmentDubs` 的查询（LoadSchemes）都报 `no such column`。

### 3.3 为什么「关掉重开」就好了（自愈原理）

- **第 2 次启动**：`SegmentDubs` 表上次已经建出来了（存在）→ 第 1009 行 `AddColumnIfMissing(SegmentDubs, CaptionLinesJson)` 这次**成功补上列** → LoadSchemes 正常 → 方案正常显示。

### 3.4 受影响人群

只有「本版本才首次创建 `SegmentDubs` 表」的用户会中招，即**之前从没用过配音功能**的老库用户。已经用过配音的用户表早就存在、`CaptionLinesJson` 在引入它的那个版本就补上了，不会遇到。

> 注：日志里该用户 DeepSeek 生成 4 策略 × 各 13 变体全部匹配成功、`SaveChanges` 完成，纯粹卡在保存后的 LoadSchemes。数据无损。

## 四、修复方案

### 4.1 主修复（根治，两处都改）—— `src/MixCut/App.xaml.cs`

**① 给建表 DDL 补上漏掉的列**（对齐缺陷 B）。在 `CreateTableIfMissing(db, "SegmentDubs", ...)` 的 CREATE TABLE 里，`ParticipatesInCombination` 之后加一列：

```sql
"ParticipatesInCombination" INTEGER NOT NULL DEFAULT 0,
"CaptionLinesJson" TEXT,          -- ← 新增，与 SegmentDub 实体 CaptionLinesJson(string?) 映射一致
```

**② 把所有 `AddColumnIfMissing(db, "SegmentDubs", ...)` 挪到 `CreateTableIfMissing(db, "SegmentDubs", ...)` 之后**（根治缺陷 A）。
即：**先建表、再补列**。这样即使将来 `SegmentDubs` 又加新列，也能在「表已存在」的前提下补上；而不是像现在这样先补列（表不存在→失败）再建表（用可能过时的 DDL）。

> 通用原则：**任何 `AddColumnIfMissing(表X, ...)` 都必须排在 `CreateTableIfMissing(表X, ...)` 之后**。建议顺手检查 `PhysicalShots` / `ShotVariants` 是否也有「先补列后建表」的同类隐患，一并按此规则排序。

> 二选一即可完全修复本 bug（① 让新表带列；② 让补列在建表后生效）。**推荐两个都做**：① 保证新库正确，② 保证升级路径正确、且杜绝下一个新列再踩同样的坑。

### 4.2 加固（防「已存盘却误报失败」）—— `src/MixCut/ViewModels/SchemeViewModel.cs`

即便 schema 修好了，`GenerateSchemesAsync` 现在的结构是「`SaveChanges()`(方案已存盘) → `LoadSchemes()`(重载) → 重载抛错就 catch 成『方案生成失败』+ 回滚状态」。这是把**纯展示层的重载失败**误当成生成失败、还把已存盘的方案藏起来。加固：

- 在生成循环里记录**已成功 `SaveChanges` 的策略数**（如 `persistedStrategyCount`）。
- `catch (Exception ex)` 里判断：**若已有策略落库**（`persistedStrategyCount > 0` 或重载后 `Schemes.Count > 0`）→ **不要**报「方案生成失败」、**不要**回滚到 Ready；应保持 `Completed`、重新 `LoadSchemes` 把方案显示出来，并给一个「已生成 N 个方案，但生成中途中断：{原因}」的**警告**（而非错误）。
- 只有**一个都没落库**时才走原来的「方案生成失败」+ `RollbackGeneratingStatus`。

> macOS 已做同样加固（`SchemeViewModel.swift`：`persistedStrategyCount` + catch 分支区分「部分已落库」与「彻底失败」），Windows 请对齐。

## 五、验收清单

1. **造一个没有 SegmentDubs 表的老库**（或删掉该表模拟老用户），启动后确认：`SegmentDubs` 表建出来后**含 `CaptionLinesJson` 列**（`PRAGMA table_info(SegmentDubs)` 里能看到），且启动日志**没有**「补列失败 SegmentDubs.CaptionLinesJson」。
2. 该库上**首次**生成方案 → **一次成功**，不再弹「方案生成失败」，无需重启。
3. 生成后 `LoadSchemes` 正常（不再有 `no such column: s3.CaptionLinesJson`）。
4. 已经用过配音的老库（表已存在）升级后照常，无回归。
5. 加固验证：人为让某个策略的 `SaveChanges` 抛错（或重载抛错）→ 界面显示「已生成 N 个方案，但中途中断」的**警告**、已存盘方案**可见**、项目状态**不卡在 Generating 也不误清**；只有 0 个落库时才提示「方案生成失败」。

## 六、涉及文件小结

- `src/MixCut/App.xaml.cs`：`CreateTableIfMissing(SegmentDubs)` 的 DDL 补 `CaptionLinesJson TEXT`；把 `AddColumnIfMissing(SegmentDubs, *)` 移到该建表之后（先建表后补列）。
- `src/MixCut/ViewModels/SchemeViewModel.cs`：`GenerateSchemesAsync` 增加 `persistedStrategyCount`，catch 里区分「部分已落库(警告，不回滚)」与「彻底失败(报错+回滚)」。
