# M04：Event Store

## 1. 功能与边界

拥有不可变事件、父边、每会话 heads、提交序号、写入去重和 event outbox。是事实存储，不负责 UI 投影、网络同步策略、业务授权或解密。

## 2. 公开 DTO

```rust
pub struct VerifiedEventEnvelope {
    envelope: EventEnvelopeV0,
    verification: VerificationStamp, // opaque admission attestation
}

pub struct AppendOptions {
    pub expected_heads: Option<Vec<EventId>>,
    pub allow_missing_parents: bool,
    pub source: EventSource,
}

pub enum AppendOutcome {
    Inserted { commit: StoreCommit, new_heads: Vec<EventId> },
    Duplicate { original_commit: StoreCommit },
    DeferredMissingParents { missing: Vec<EventId> },
}

pub struct StoreCursor { pub commit_sequence: u64 }
```

## 3. Port 签名

```rust
pub trait EventStorePort: Send + Sync {
    fn append<'a>(
        &'a self,
        ctx: &'a RequestContext,
        event: VerifiedEventEnvelope,
        options: AppendOptions,
    ) -> BoxFuture<'a, Result<AppendOutcome, ContractError>>;

    fn append_batch<'a>(
        &'a self,
        ctx: &'a RequestContext,
        events: Vec<VerifiedEventEnvelope>,
        mode: BatchMode,
    ) -> BoxFuture<'a, Result<BatchAppendOutcome, ContractError>>;

    fn get<'a>(
        &'a self,
        ctx: &'a RequestContext,
        id: EventId,
    ) -> BoxFuture<'a, Result<Option<StoredEvent>, ContractError>>;

    fn scan_conversation<'a>(
        &'a self,
        ctx: &'a RequestContext,
        conversation: ConversationId,
        page: PageRequest<ConversationCursor>,
    ) -> BoxFuture<'a, Result<Page<StoredEvent, ConversationCursor>, ContractError>>;

    fn scan_commits<'a>(
        &'a self,
        ctx: &'a RequestContext,
        after: StoreCursor,
        limit: u16,
    ) -> BoxFuture<'a, Result<CommitBatch, ContractError>>;

    fn heads<'a>(
        &'a self,
        ctx: &'a RequestContext,
        conversation: ConversationId,
    ) -> BoxFuture<'a, Result<HeadSnapshot, ContractError>>;

    fn missing<'a>(
        &'a self,
        ctx: &'a RequestContext,
        ids: Vec<EventId>,
    ) -> BoxFuture<'a, Result<Vec<EventId>, ContractError>>;
}
```

## 4. 不变量与限制

- `EventId` 唯一；相同 ID 不同 canonical bytes 是 `IntegrityFailure` 并隔离数据库。
- 事件行只插入不更新；撤回/编辑是新事件。可更新的只有索引、heads、缺口和 outbox 状态。
- append 在同一事务中写事件、边、heads、commit sequence、缺口和 outbox。
- Store 只接受 admission pipeline 产出的 `VerifiedEventEnvelope`；网络字节不能直接 append。字段保持私有，公共工厂要求 `EventAdmissionPort` 的 opaque attestation。该类型是进程内误用防线而非敌对插件沙箱，因此 M04 仍独立复查 EventId、canonical shape 与 stamp 版本。
- 默认单事件 1 MiB；batch 最多 256 事件或 16 MiB，先到者生效。
- `scan_*` 返回稳定 snapshot token；分页期间新提交不混入旧 snapshot。
- SQLite 使用 WAL、foreign_keys、busy timeout、integrity check；SQL 参数化。

## 5. 并发与崩溃语义

逻辑上按 `ConversationId` 串行写，物理 SQLite 可使用单 writer task；读取走快照连接池。不得持有数据库事务等待外部 Port。外部事件发布由 outbox dispatcher 在提交后进行。

`allow_missing_parents` 仅用于受控远端同步；缺父事件不能成为可投影 ready commit，直到父事件补齐并重新验证依赖。

## 6. Integration Events

- `EventCommittedV0 { event_id, conversation_id, commit_sequence }`
- `EventBecameReadyV0`
- `EventGapDetectedV0`
- `StoreIntegrityAlertV0`

Integration Event 不复制 encrypted payload；消费者用 EventId 查询。

## 7. ACL

- `crypto_validation_adapter` 接收 M03 验证后的封装，不自行构造 stamp。
- `projection_adapter` 只把 ready commit 通知 M05。
- `sync_adapter` 把分页/heads 转成 M06 inventory，不暴露 SQLite cursor。

## 8. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| ES-001 | 相同事件并发 append 100 次 | 一次 Inserted，其余 Duplicate |
| ES-002 | 相同 ID 不同 bytes | integrity alert，拒绝第二份 |
| ES-003 | child 先于 parent | deferred；parent 到达后 child ready |
| ES-004 | crash 注入各事务步骤 | 重启后全有或全无，无半更新 heads |
| ES-005 | outbox 发布失败后重启 | 事件保留并最终至少一次发布 |
| ES-006 | 删除 projection 表 | Event Store 不受影响，可供完整重建 |
| ES-007 | 分页时持续写入 | snapshot 内无重复/跳项 |
| ES-008 | WAL busy/磁盘满 | 返回可分类错误，无损坏、无假成功 |
| ES-009 | 256/16MiB 边界 | 边界值成功，超限预分配前失败 |
| ES-010 | property DAG 重放 | heads 与参考模型一致 |

## 9. 验收

通过 kill-at-every-write-point 故障测试；任意重复/乱序输入不生成重复事实；投影可仅依赖公开 Port 完整重建。
