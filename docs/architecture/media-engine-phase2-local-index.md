# ChatFlow Media Engine Phase 2 — 本地媒体索引（设计 + 落地说明）

- 状态：**已实现**（Phase 2；Phase 3 内容仅设计，见 §10）。
- 前置：Phase 0 设计 [`media-engine-v1.md`](media-engine-v1.md)；Phase 1 报告
  [`docs/verification/2026-09-17-media-engine-v1-phase1.md`](../verification/2026-09-17-media-engine-v1-phase1.md)。
- 本阶段允许改动：本地媒体缓存 / 本地媒体索引 / 本地 LRU 与 quota / 本地 reference 管理 /
  本地 metadata / Chat·Moments·Avatar 的缓存调用适配。
- 本阶段**未**改动：Matrix 协议、event schema、E2EE/Megolm/Olm、服务端媒体上传 API、
  服务端远端去重、服务端对象存储、消息格式、好友、群聊、登录、推送。
- 未做：`git pull`、构建 APK/IPA、真机、部署、push。

---

## 1. Before：Phase 1 结束时的真实调用图

> 本节的每一行都由源码读出（不是沿用上一份报告）。Phase 1 只改了"视频封面怎么取"，
> **没有**改动对象库、配额与引用管理。

### 1.1 写路径

```
聊天图片/视频接收
  RoomTimelineAdapter.loadAttachment(eventId)
    → _SdkRoomTimelineCapability.loadAttachment / loadThumbnail
      → loadMediaWithCache(MediaCacheKey(accountId, roomId, eventId|thumb:eventId,
                                          contentSha256, sourceIdentity), decrypt)
          ├─ 内存命中（contentSha256 存在时）→ _linkMediaReference(key, bytes) → 返回
          └─ 未命中 → flight（_mediaLoads[identity] 去重）
                ├─ MediaCache.cached(roomId, eventId, contentSha256:)      ← 磁盘读
                ├─ 未命中 → mediaLoadScheduler.request(taskKey, decrypt)  ← 解密（并发上限）
                ├─ MediaCache.store(roomId, eventId, bytes, contentSha256:)
                │     → _store(): objects/<sha256(bytes)>[.mp4|.mov] 原子写 + .len
                │                refs/<sha256(jsonEncode([roomId,eventId]))>.ref
                │                → _enforceDiskQuota(file)              ← 见 1.3
                └─ _sharedMediaBytes.putIfAbsent(memoryKey, ...)         ← 内存 LRU
朋友圈
  MomentMediaCache 管理器 getFileStream
    → MediaCache.cached('moments', source.cacheKey, accountId:)          ← 同一对象库
    → 命中即 FileInfo；未命中 → HTTP 下载 → MediaCache.store('moments', ...)
相册视频首帧（非 E2EE）
  loadVideoFirstFrame(asset)
    → {docs}/video_first_frame_cache/<sha256(path|id|duration|size)>.jpg  ← 独立、无 quota、无账号
视频封面（Phase 1）
  VideoPosterPipeline
    → VideoPosterSessionCache（内存 LRU + 会话磁盘 VideoPosterDiskStore）
    → MediaCache.probeCachedObject(...)（本机持久封面缓存，<eventId>#video-poster-v1）
    → MediaCache.store(...)（同上）
```

### 1.2 读路径与哈希

```
MediaCache.cached(roomId, eventId, {accountId, contentSha256})
  ├─ contentSha256 != null → objects/<hash>[.mp4|.mov] → _valid(file)
  └─ 否则                  → refs/<digest>.ref 读文件名 → objects/<name> → _valid(file)

_valid(file) =
    exists?
    → 读 <file>.len，长度必须完全相等
    → validateContentSha256(文件名)
    → verifyMediaContentStream(file.openRead(), 文件名)   ← **整文件流式 SHA-256**
    → setLastModified(now)                                 ← 每次命中一次磁盘写
  失败 → 删除对象与 .len（当作 cache miss）
```

**问题 P0-1（本阶段修复）**：`_valid` 在**每次磁盘命中**都完整读取并哈希整个对象。
100MB / 500MB / 1GB 视频"缓存命中"= 重读+哈希整个文件才起播（`PerformanceCounter.mediaDiskHit`
统计到的"命中"实际非常昂贵）；`setLastModified` 又给每次命中加一次写盘。

> 旁证（同一类成本，另一条路径）：`MediaMemoryCache._ownVerifiedBytes` 在**内存 put** 时也会
> 对字节做一次 sha256；同一 `Uint8List` 实例由 `Expando` 记忆避免重复。Phase 2 不改这里
> （它校验的是"键内嵌哈希 == 内容"，属内存安全约束），仅记录为 Phase 3 候选。

### 1.3 配额与淘汰

```
_enforceDiskQuota(keep):
  _files() = {docs}/chat-media 整棵树递归列出所有数据文件（排除 .len/.ref/.tmp）
  total = Σ length
  if total <= diskHardQuotaBytes(512MiB) → return                 ← 只有超过硬上限才动手
  按 mtime 升序删除，直到 total <= diskSoftQuotaBytes(384MiB)      ← 全局、跨账号
```

**问题 P1（本阶段修复）**：配额是**全设备**的——枚举范围包含**所有账号**目录；
账号 A 写入大量视频可以淘汰账号 B 的离线媒体；且"软配额"实际是硬上限的回退目标，
单账号本身没有上限约束。

### 1.4 引用与删除

```
MediaCache.removeReference(roomId, eventId)  → 只删 refs/<digest>.ref（对象保留）
回收对象的唯一途径                          → 配额 LRU（没有引用计数、没有 GC）
clearAccount(accountId)                     → 删 {docs}/chat-media/v2/<sha256(account)> 整目录
                                               + 写 clear epoch + 调各域 cleaner
```

`refs/*.ref` 内容 = 对象文件名 → 它**已经**是"逻辑引用 → 对象"的持久映射，
但没有任何反向索引（"对象 → 引用数"），因此无法安全回收，只能靠配额 LRU 兜底。

### 1.5 其它本地缓存（现状）

| 缓存 | 位置 | 账号隔离 | 淘汰 | 备注 |
| --- | --- | --- | --- | --- |
| `MediaCache` 对象库 | `{docs}/chat-media/v2/<sha256(account)>/{objects,refs}` | ✅ 目录级 | ⚠️ 全局 mtime LRU（见 1.3） | 本阶段主战场 |
| `MediaMemoryCache`（多实例） | 进程内 | ✅ 命名空间 | LRU + 字节预算 + 条目上限 | 不改 |
| `RoomImagePreviewCache` → `EncryptedEmojiPreviewStore('room-image-v1:<account>')` | 安全存储命名空间 | ✅ 键前缀 | 写入后按 mtime 删到 64MiB | 不改（已账号隔离 + 有配额） |
| `VideoPosterDiskStore`（会话） | 进程临时目录 | 进程级 | 会话销毁整体删除 | Phase 1 保留 |
| 相册视频首帧 | `{docs}/video_first_frame_cache/` | ❌ 无 | ❌ 无 | **本阶段迁移** |
| Moments 图片/视频 | `flutter_cache_manager`（7 天 / 200 对象）+ `MediaCache('moments', key)` | ✅（MediaCache 侧） | CacheManager LRU + 对象库 LRU | 已共享对象库 |
| Avatar | `flutter_cache_manager`（30 天 / 500 对象），键 `avatar:<userId>:<version>` | 设备共享（同一 Matrix 用户 = 同一头像，正确） | CacheManager LRU | **不改**（理由见 §7） |

---

## 2. After：Phase 2 目标结构

```
                       MediaCache（唯一对象库 / 配额 / 引用 / GC）
                        │            │              │
        ┌───────────────┘            │              └───────────────┐
        │                            │                              │
   Chat（E2EE 解密后）        Moments（HTTP 下载后）      相册视频首帧（设备本地抽帧）
        │                            │                              │
        └──────────────┬─────────────┴──────────────┬───────────────┘
                       │                            │
              MediaIndex（SQLite，账号隔离行）   refs/*.ref（持久引用，真相源）
                       │                            │
                 廉价命中快路径                 MediaGarbageCollector（按 refs 重算引用数）
```

关键变化：

1. **`MediaIndex`（加速层，新增）**：`reference_key → object_hash → local_path` +
   `size/variant/family/last_access`。≥ 1 MiB 的对象命中后只做**廉价校验**（命名空间、
   存在、精确大小、mtime 锚点），**不再重算整文件 SHA-256**；< 1 MiB 的对象继续完整校验
   （成本可忽略，见 §4.1）。
2. **两级配额**：账号内软配额 + 设备硬上限；淘汰只在账号内进行，设备上限是最后兜底。
3. **LRU 时间戳批量更新**：命中只登记内存 pending touch，合并落库（同一对象 60s 内至多一次）。
4. **引用计数 + GC**：引用数由 `refs/*.ref` **重算**（不依赖计数器漂移）；GC 只删
   "无引用 + 未 pin + 无在途写 + 超过保护期"的对象。
5. **pin/lease**：播放/解码/上传下载中的对象不被配额淘汰或 GC 删除。
6. **相册视频首帧并入对象库**：不再有独立、无配额、无账号的缓存目录。
7. **迁移**：目录**保持 `chat-media/v2`**（已经账号隔离，不做机械搬迁）；
   旧对象在**首次被访问时**完成一次校验并写入索引（lazy migrate on access），
   启动不扫描、不搬家。

---

## 3. MediaIndex schema

存储：**SQLite**（复用仓库既有 `sqflite_common_ffi`，与 `MomentsPageStore` 同一技术栈；
SharedPreferences 明确不用于大量媒体索引；不引入任何新依赖）。
数据库：`{ApplicationSupportDirectory}/chatflow_media_index_v1.db`（单文件、多账号共表、
按行隔离；账号清理时删该账号的行）。

```sql
CREATE TABLE IF NOT EXISTS media_index (
  account_namespace TEXT NOT NULL,   -- sha256(accountId)：明文账号 ID 不入库
  reference_key     TEXT NOT NULL,   -- sha256(jsonEncode([roomId, eventId]))：与 refs/*.ref 文件名同源
  object_hash       TEXT NOT NULL,   -- sha256(明文对象字节)
  object_name       TEXT NOT NULL,   -- 对象文件名（含容器后缀，如 <hash>.mp4）
  variant           TEXT NOT NULL DEFAULT 'unknown',
  family_id         TEXT,            -- 媒体族锚点（如聊天正文 content_sha256）
  size_bytes        INTEGER NOT NULL,
  mime_type         TEXT,
  width             INTEGER,
  height            INTEGER,
  duration_ms       INTEGER,
  created_at        INTEGER NOT NULL,   -- epoch ms（本机）
  last_access_at    INTEGER NOT NULL,   -- epoch ms（批量更新）
  verified_at       INTEGER NOT NULL,   -- 最后一次"内容已校验"的时间
  schema_version    INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (account_namespace, reference_key)
);
CREATE INDEX IF NOT EXISTS media_index_object
  ON media_index (account_namespace, object_hash);
CREATE INDEX IF NOT EXISTS media_index_access
  ON media_index (account_namespace, last_access_at);
```

字段取舍说明：

- **不存** userId / roomId / eventId 明文、不存明文媒体内容、不存 token / Matrix 密钥 /
  头像 URL / 文件名明文（`local_path` 由账号摘要 + 对象名拼出，落库只存 `object_name`，
  读取时按当前账号根拼路径 → 账号目录变化也不会让索引指向错误位置）。
- `variant`：`original` / `thumbnail` / `preview` / `poster` / `video` / `unknown`
  （同一原始媒体的不同字节 → **不同 `object_hash`**，这是正确行为，不是重复存储 bug）。
- `family_id`：媒体族锚点。**本阶段只建立 metadata 关联**：聊天里同一个事件的
  正文与缩略图共享 `family_id = <正文 sha256>`；没有共同锚点时留 null（绝不强行合并）。
- `verified_at`：只有"我们写入并计算过摘要"或"完整校验通过"的条目才写非零值；
  非零 = 后续命中可走廉价校验。

---

## 4. 命中路径的廉价校验（禁止"信索引不验文件"）

```
索引命中（entry）
  ├─ 1) object_hash 形状合法（64 hex）+ 账号命名空间正确（路径前缀 == 当前账号根）
  ├─ 2) 文件存在
  ├─ 3) size_bytes == 实际长度（精确匹配；长度不符 → 视为损坏）
  ├─ 4) verified_at > 0（本条目曾被写入或完整校验）
  ├─ 5) 完整性锚点：
  │       · 实际长度 < 1 MiB（_cheapPathMinBytes）→ 立即 `_valid(file)` **完整校验**
  │       · 实际长度 ≥ 1 MiB                      → 廉价锚点 `mtime <= verified_at`
  └─ 全部通过 → 返回 File（大对象 0 次哈希），并把 touch 记入内存 pending
  任一失败 → 失效该索引行 → **回退 legacy 路径**（refs → _valid 完整校验 → 重建索引）
```

不做的：不因为索引命中就跳过"文件是否真的存在/大小是否对"。不做的另一面：
**不再每次命中重算整文件 SHA-256**。

### 4.1 为什么大对象用 mtime 锚点，小对象仍整文件哈希

Phase 1 的 `cached()` 每次命中都整文件校验，测试已固化一条语义：
**同尺寸原地篡改必须被发现**（长度不变、只改字节，仅靠"大小相等"无法区分）。
若对**所有**尺寸一律"索引命中即放行"，这条保证会退化。

因此 Phase 2 的廉价路径**只对达到 `_cheapPathMinBytes`（1 MiB）的对象生效**：

| 对象尺寸 | 命中成本 | 同尺寸篡改 |
| --- | --- | --- |
| < 1 MiB | 整文件流式 SHA-256（亚毫秒，成本可忽略） | **必被发现**（Phase 1 语义不变） |
| ≥ 1 MiB | 一次 `stat`（大小 + mtime），0 字节读取 | mtime 与校验时间戳不一致即被发现 |

小对象上多一次哈希对 P0-1 目标没有任何损失——P0-1 要解决的是"500MB 视频每次起播
重读+哈希整个文件"，1 MiB 以下的哈希成本与一次 `stat` 同量级。

大对象的锚点为什么成立：**已索引对象的 mtime 只在写入时设定**（LRU 走索引列，
`MediaIndex.flush()` 的 `setLastModified` 只作用于**未索引**对象）。`_indexVerified`
在对象成功落盘之后记录 `verified_at = now`，因此正常对象的 `mtime <= verified_at`；
任何"校验之后再次改写内容"都会把 mtime 推到 `verified_at` 之后。

### 4.2 残留风险（明确记录，不隐瞒）

- 毫秒粒度：`stat.modified` 与 `verified_at` 都是毫秒。若篡改**恰好落在校验同一毫秒**，
  廉价锚点无法区分。对 ≥ 1 MiB 的对象，重写整个文件本身就需要远超 1 ms，
  因此该窗口在实践中不可达；对 < 1 MiB 的对象根本走不到这条路径（§4.1 已完整校验）。
- 主动伪造：本地攻击者若在篡改后调用 `File.setLastModified` 回填 mtime，锚点会被绕过。
  本阶段把索引定位为**完整性加速器而非对抗本地沙箱写权限的安全边界**；
  真正的兜底是 §4.3 的内容摘要复核。
- 其它引用行：对象被重新落盘（同内容不会重写，只有不同 hash 才会新文件）之外的
  极端情况下，共享同一对象的其它 `reference_key` 行的 `verified_at` 可能旧于 mtime →
  它们只会**多走一次完整校验并回填**（自愈），不会误报损坏。

### 4.3 最后一道校验：内容摘要复核 + 修复

`loadMediaWithCache` 在把磁盘文件交给内存缓存之前，仍会用事件携带的可信摘要
（`contentSha256`）复核一次内容（复用已在内存中的字节，不额外读盘）：

```
读到磁盘对象 → verifyMediaContent(result, key.contentSha256)
  失败 → MediaCache._discardCorruptObject(key, file)   // 删对象 + 删 .len + 失效索引行
       → decrypt() 重新解密 → store() 原子重写 → 用新字节继续
```

因此"索引命中但内容不符"的最终表现是**自愈修复**（一次重新解密 + 落盘），
而不是把损坏字节交给 UI，也不是把异常抛给用户。

### 4.4 写入侧复用（`_storeObject`）同样分级

同内容对象已存在时，`_knownObjectValid` 先用索引 + 精确大小判定；**小于 1 MiB 时
强制回退 `_valid` 完整校验**，避免把"同尺寸被篡改"的对象当作已存在内容复用到新引用上。

---

## 5. LRU 与配额设计

### 5.1 两级配额

| 级别 | 常量 | 值 | 语义 |
| --- | --- | --- | --- |
| 账号软配额 | `accountSoftQuotaBytes` | **384 MiB**（沿用线上既有软配额值） | 超限只淘汰**本账号**最久未访问对象，直到回到软配额 |
| 设备硬上限 | `deviceHardQuotaBytes` | **1024 MiB**（集中常量，可调） | 超过才做跨账号兜底淘汰（按 last_access 全局最旧优先） |

集中定义在 `MediaCache` 顶部常量区（无散落魔数）。为什么是 1024 MiB：
Phase 1 之前全设备共享 384/512 MiB；改为账号隔离后，若设备上限仍留在 512 MiB，
两个账号各 384 MiB 就会立刻触发跨账号淘汰（等于没解决 P1）。1 GiB 允许 2–3 个活跃账号
各自待在自己的软配额内而不互相驱逐，同时把最坏磁盘占用限制在可控范围。数值可集中调整。

### 5.2 淘汰算法

```
_enforceDiskQuota(accountId, keepFile):
  ① 账号内：列出 objects/ 下该账号的条目，Σsize > accountSoftQuota
       → 按 (last_access_at ?? mtime) 升序删除（跳过 keep / pinned / 在途写）
  ② 设备级：Σ(所有账号 objects) > deviceHardQuota
       → 全局按 (last_access_at ?? mtime) 升序删除到 deviceHardQuota，跳过 keep / pinned / 在途写
  metrics: eviction_ms / evicted_objects / evicted_bytes
```

`last_access_at` 来自索引（批量刷新）；未索引对象回退文件 mtime。

### 5.3 touch 批处理（禁止滚动产生大量磁盘 I/O）

实现位置：`MediaIndex`（`touch` / `touchObject` / `touchPath` / `flush`），
参数化常量：`touchDebounce = 60s`、`maxPendingTouches = 32`、`hotCapacity = 512`（进程内热 LRU）。

```
MediaCache.cached 命中（大对象廉价路径）
  → MediaIndex.touch(accountNamespace, referenceKey, objectPath)
  → MediaIndex.touchObject(accountNamespace, objectHash, objectPath)
       · 热 LRU 内直接改 lastAccessAt（纯内存）
       · 同时写入 _pendingTouches（内存 Map 覆盖写，同一 reference/object 只保留一条）
       · 未索引对象（本次是新发现）才附带 objectPath，供 flush 时补 mtime
  → 达到 32 条 或 距上次 flush ≥ 60s（由调用点 flushIfDue / 配额·GC·账号清理前显式 flush）
       · 一条 SQLite 事务批量 UPDATE last_access_at
       · 仅对"未索引"对象逐个 setLastModified（按去重后的路径）
```

关键点：**命中路径本身只做内存操作**，没有任何同步磁盘写；LRU 精度损失最多 60s，
对淘汰顺序无实质影响。`setLastModified` 只作用于未索引对象，因此**不会**破坏
§4.1 中"已索引对象 mtime 保持为写入时间"的前提。

---

## 6. 引用、引用计数与 GC

### 6.1 引用管理

- 真相源仍是 `refs/<sha256(jsonEncode([roomId,eventId]))>.ref`（内容 = 对象文件名）——
  保持既有结构，保证旧数据可读、崩溃可恢复。
- `MediaIndex` 是同一映射的加速副本（`reference_key` 就是 ref 文件名里的摘要）。
- `removeReference`：删 ref 文件 + **失效对应索引行**（不让索引继续声称引用存在）。
- **不**在删引用时删对象（对象可能被其他引用共享）。

### 6.2 引用计数可修复

GC 每次运行都**从 `refs/*.ref` 重新统计**：列出该账号 `refs/` 目录，读取每个 ref 的文件名，
构建 `objectName → refCount`。不依赖任何 `counter++/--`，因此崩溃不会造成永久漂移。

### 6.3 MediaGarbageCollector

```
collectGarbage(accountId, {dryRun=false, now, gracePeriod=60s})
  ① 拒绝条件（任一命中即跳过）：被 pin、正在写入（_atomicWrites/_storeFlights）、
     mtime 或 created_at 晚于 now-gracePeriod（保护"对象刚写、ref 还没写"的窗口）
  ② 引用数 == 0 且存在 > gracePeriod → 删除 objects/<name> + <name>.len + 索引行
  ③ 返回报告：scannedObjects / referenced / collected / kept / skippedPinned / bytes
  metrics: gc_ms
  触发：显式调用（测试/维护）+ 设备硬上限被突破时的兜底（先 GC 再淘汰）
```

### 6.4 pin / lease（禁止 GC 删正在使用的文件）

```
final lease = MediaCache.pinPath(path);   // 或 pinObject(accountId, objectName)
... 播放 / 解码 / 上传下载 ...
lease.release();                           // 或 MediaCache.unpinPath(path)
```

- 内存引用计数（`Map<String,int>`），同路径多次 pin 即计数累加，归零才算未 pin。
- 配额淘汰与 GC 都跳过 pinned 路径。
- 生产接线（本阶段）：视频全屏播放（`room_page._openVideoViewer`）在解析出播放文件后 pin，
  路由返回后 unpin —— 覆盖"视频播放中不被删"这条最关键的要求；图片解码在内存中完成
  （字节来自内存缓存），不持有本地文件；上传/下载在途由 `_atomicWrites`/`_storeFlights` 保护。

---

## 7. 账号隔离与跨域适配

| 关注点 | 结论 |
| --- | --- |
| 目录隔离 | **已经**是账号隔离（`chat-media/v2/<sha256(accountId)>/{objects,refs}`）→ **不做机械目录迁移** |
| 配额隔离 | Phase 2 修复：改为账号内软配额 + 设备硬上限（§5.1） |
| 索引隔离 | 单 SQLite 文件、按 `account_namespace` 列隔离；账号清理删行；账号 ID 以摘要入库 |
| Chat ↔ Moments | 已经共用对象库（Moments 通过 `MediaCache.store/cached('moments', cacheKey, accountId:)`）；本阶段二者**自动**获得索引/廉价命中，无需改 Moments 网络层 |
| Avatar | **不改**：头像只由 `flutter_cache_manager`（30 天 / 500 对象 / 版本化键）承载，不存在重复下载或重复落盘；若把最终字节再交给 `MediaCache`，会变成"同一头像两份落盘"，与去重目标相反。要真正统一，需要把 CacheManager 的 HTTP 新鲜度元数据（etag/validTill）一起搬进对象库 —— 那是 Phase 3，且明确禁止改变头像刷新语义 |
| 相册视频首帧 | Phase 2 迁移进对象库（`roomId='device-gallery'`），获得配额/LRU/原子写/完整性校验；默认设备共享命名空间（素材来自用户本机相册，不是 E2EE 媒体），需要时可传 `accountId` 做账号隔离 |
| RoomImagePreviewCache | 保留（已账号隔离 + 64MiB 配额） |

---

## 8. 崩溃恢复与原子性

| 场景 | 行为 |
| --- | --- |
| 对象写完、索引未写就被杀 | 索引缺行 → 命中走 legacy（refs → `_valid` 完整校验）→ 校验通过后**回填索引**（lazy rebuild）；旧缓存仍可读 |
| 索引有行、对象缺失 | 廉价校验第 2 步失败 → **失效该行** → 回退 legacy → 未命中则正常重新下载/解密（不因为索引损坏导致媒体永久打不开） |
| 索引有行、对象被截断 | 大小不匹配 → 同上（失效 + 回退；legacy 的 `_valid` 会删除损坏对象） |
| 索引有行、对象被同尺寸篡改 | < 1 MiB：完整校验直接发现；≥ 1 MiB：mtime 晚于 `verified_at` 被发现；两者都失效索引行 → legacy → 未命中则重新下载/解密。若廉价路径漏过（同一毫秒改写），`loadMediaWithCache` 的摘要复核兜底并**修复**（§4.3） |
| 半写对象 | 写入仍走 `tmp → 原子 rename`（既有 `_atomicBytes`），`.len` 先写；索引只在对象成功落盘后写入 |
| 索引文件本身损坏 | 打开/查询抛错 → 捕获后**降级为纯 legacy 行为**（并尝试重建索引表）；绝不让聊天不可用 |
| 引用文件损坏（名字不合法） | 与现状一致：视为未命中 |

---

## 9. 迁移与版本化

- **目录保持 `chat-media/v2`**（已账号隔离）；不新增 `v3` 目录、不做启动搬迁。
  若未来确实需要改布局，再引入 `v3` + 惰性迁移。
- 索引自带 `schema_version` 列 + `meta` 表（`index_schema_version`），
  升级时可增量迁移；不匹配时按"重建索引"处理（索引可丢弃重建，对象与 refs 不受影响）。
- **不做**启动全量扫描/全量哈希：索引按需打开、按访问增量填充。
- 旧对象（无索引行）首次访问时做一次完整校验（与 Phase 1 行为相同），随后进入廉价路径。

---

## 10. 安全考量

1. **不改加密与协议**：对象文件仍是"解密后的明文媒体"，加密 nonce / key derivation /
   Matrix media envelope / `chatflow_media` 扩展字段一律未改。
2. **索引不含隐私字段**：没有 userId / roomId / eventId / 文件名明文 / token / Matrix 密钥 /
   媒体内容；账号与引用均以 sha256 摘要入库，`local_path` 由摘要拼出。
3. **明文摘要不外传**：`object_hash` 只在本机索引中使用，不上传、不写日志（日志只出现
   加盐哈希后的短指纹，见 §11）。
4. **失败降级**：索引异常 → legacy 路径；不影响解密与消息可用性。
5. **不降低完整性要求**：索引只跳过**重复**校验，不降低"写入时校验 + 首次读校验"的要求；
   被索引标记为 verified 的条目在廉价校验失败时立即失效。低于 1 MiB 的对象不做任何
   校验豁免；大对象的残留毫秒级窗口与本地篡改风险在 §4.2 明确记录，并由 §4.3 的
   内容摘要复核兜底。
6. **不记录明文**：`MediaCacheMetrics` 只累计计数与耗时；`debugLine()` 输出仅含数字
   （如 `index_hits=12 hash_bytes_read=0`），不含账号、房间、事件、文件名。

---

## 11. 性能指标与诊断

新增 `MediaCacheMetrics`（进程内计数器，无持久化、无 PII）：

| 指标 | 含义 |
| --- | --- |
| `cache_lookup_ms` | `cached()` 总耗时 |
| `index_lookup_ms` | 索引查询耗时 |
| `hash_bytes_read` | **为校验而读取的字节数**（P0-1 的核心观测点：索引命中必须为 0 增长） |
| `disk_bytes_read` | 本地读盘字节（校验/读取对象） |
| `disk_bytes_written` | 本地写盘字节（对象 + 索引） |
| `eviction_ms` / `evicted_objects` / `evicted_bytes` | 配额淘汰 |
| `gc_ms` / `gc_collected` / `gc_bytes` | 垃圾回收 |

禁止记录：用户 ID 明文、文件名明文、token、Matrix 密钥、聊天内容。
（需要标识时使用加盐 sha256 前 12 位，与 `VideoPosterDiagnostics.fingerprint` 同一约定。）

实现约定：**计数器无条件累加**（测试与诊断不依赖 profile 开关），只有耗时类
（`*_ms`）的取时才受 `MediaCacheMetrics.enabled` 控制——`kProfileMode` 或
`--dart-define=CHATFLOW_PERFORMANCE_METRICS=true`。这样"索引命中是否真的 0 哈希字节"
在任何构建下都可断言。

---

## 12. Remaining Phase 3（只设计，不实现）

1. **服务端 SHA 查重 / 跨用户对象复用**：需要服务端提供只读查重接口；本阶段禁止改服务端。
2. **远端内容寻址**：依赖 1；客户端侧只能先做"演绎版参数归一"（会改变发送字节，需产品评估）。
3. **头像本地层统一**：把 CacheManager 的 HTTP 新鲜度（etag/validTill）与对象库合并，
   需要新的 TTL 层（不改刷新语义的前提下）。
4. **`MediaVariant` 族谱完整化 + 引用式回收全接线**：把 `release()` 接到撤回/删除/账号清理的
   所有入口（本阶段只做了索引行失效 + GC 可用）。
5. **内存 put 的 sha256 消除**（`MediaMemoryCache._ownVerifiedBytes`）：需要新的"信任来源"证明，
   否则会削弱键内嵌哈希的一致性检查。
6. **`SentVideoLocalRegistry` 指向压缩产物**：需要转码产物所有权/引用计数改造（Phase 1 已审计）。
7. **视频渐进播放（preview_video）**：需要发送端产出短片 + 播放器改造。
8. **磁盘写入 fsync 策略与 SQLite WAL 调优**：真机 I/O 剖析后再定。

---

## 13. 不变量（Phase 2 必须保持）

1. `objects/<hash>` + `refs/<logical-ref>` 结构不变：**一个对象可被多个引用共享**，
   绝不退化成"每引用一份物理文件"。
2. 同字节去重必须继续成立（Room A + Room B 同字节 → 1 对象 + 2 引用）。
3. 同一原始媒体的 original/thumbnail/preview 是不同字节 → 不同对象，**不算重复存储**。
4. 索引是加速层，**不是**真相源；删掉索引必须能靠对象 + refs 完全恢复。
5. 旧缓存（v2 目录、无索引条目）升级后仍可读。
6. E2EE 与消息格式不变；索引不承载任何明文身份或密钥。
