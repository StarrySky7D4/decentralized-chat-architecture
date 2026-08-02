# M13：Application API / FFI Facade

## 1. 功能与边界

向 Flutter 暴露粗粒度命令、查询和状态流；协调 M01–M12 完成用例 saga；把内部错误映射为稳定、可本地化的 UI 错误；维护客户端 session 与订阅生命周期。

不负责领域事实、数据库表、Socket、密码状态、widget 或业务规则。FFI 不暴露 Rust trait object、borrow、锁、raw pointer、SQLite row、libp2p/QUIC 类型。

## 2. 命令 Port

```rust
pub trait ChatApplicationPort: Send + Sync {
    fn initialize<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: InitializeClient,
    ) -> BoxFuture<'a, Result<ClientSnapshot, AppError>>;

    fn create_identity<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: CreateIdentityCommand,
    ) -> BoxFuture<'a, Result<IdentityView, AppError>>;

    fn accept_invitation<'a>(
        &'a self,
        ctx: &'a RequestContext,
        command: AcceptInvitationCommand,
    ) -> BoxFuture<'a, Result<ConversationView, AppError>>;

    fn create_conversation<'a>(
        &'a self,
        ctx: &'a RequestContext,
        command: CreateConversationCommand,
    ) -> BoxFuture<'a, Result<ConversationView, AppError>>;

    fn send_message<'a>(
        &'a self,
        ctx: &'a RequestContext,
        command: SendMessageCommand,
    ) -> BoxFuture<'a, Result<LocalMessageCommit, AppError>>;

    fn edit_message<'a>(
        &'a self,
        ctx: &'a RequestContext,
        command: EditMessageCommand,
    ) -> BoxFuture<'a, Result<LocalMessageCommit, AppError>>;

    fn retract_message<'a>(
        &'a self,
        ctx: &'a RequestContext,
        command: RetractMessageCommand,
    ) -> BoxFuture<'a, Result<LocalMessageCommit, AppError>>;

    fn retry_delivery<'a>(
        &'a self,
        ctx: &'a RequestContext,
        event: EventId,
    ) -> BoxFuture<'a, Result<DeliverySummaryView, AppError>>;

    fn update_node_preferences<'a>(
        &'a self,
        ctx: &'a RequestContext,
        command: UpdateNodePreferences,
    ) -> BoxFuture<'a, Result<NodePreferencesView, AppError>>;
}
```

## 3. 查询与流

```rust
pub trait ChatQueryPort: Send + Sync {
    fn conversations<'a>(
        &'a self, ctx: &'a RequestContext, query: ConversationPageQuery,
    ) -> BoxFuture<'a, Result<Page<ConversationView, UiCursor>, AppError>>;

    fn timeline<'a>(
        &'a self, ctx: &'a RequestContext, query: TimelinePageQuery,
    ) -> BoxFuture<'a, Result<Page<MessageView, UiCursor>, AppError>>;

    fn sync_status<'a>(
        &'a self, ctx: &'a RequestContext,
    ) -> BoxFuture<'a, Result<SyncStatusView, AppError>>;

    fn observe(
        &self, ctx: RequestContext, filter: UiSubscription,
    ) -> Result<BoxStream<UiStateEvent>, AppError>;
}
```

FFI 生成层把这些接口折叠成少量 async 函数与 stream，不为每个字段生成细粒度 getter。

## 4. `send_message` 用例

```text
验证 UI 输入/幂等 operation
→ M02 authorize + snapshot recipient policy
→ M03 seal/sign canonical event
→ M04 append 本地事实
→ 立即返回 LocalMessageCommit(pending)
→ outbox 触发 M07 enqueue
→ M05/M07 流更新 UI
```

网络失败不能让本地事实回滚。`send_message` 成功的定义是“安全写入本地 Event Store”；送达状态是后续事实。

## 5. 限制、取消与错误

- 文本 V0 最大 64 KiB UTF-8；附件引用最多 16 个；UI batch 命令最多 64 项。
- FFI 每客户端最多 16 个 active subscriptions；每流 buffer 256。
- command timeout/cancel 若发生在本地 commit 前可取消；commit 后返回 committed + background status，不能假装撤销。
- `AppError` 只含稳定 code、retry action、localization key 和安全字段；不含内部错误字符串。
- 所有客户端生成 operation ID 持久到命令完成，重启重试仍复用。
- facade 不实现自动重试网络；只发命令给 M07。

## 6. ACL

M13 为所有下游模块各维护一个 adapter，把 UI command/view 与领域 Port DTO 显式转换。M13 可以编排 saga，但不能在本地复制 M02/M03 的授权或密码规则。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| API-001 | send_message 正常 | 本地 commit 后立刻返回 pending，后台 enqueue |
| API-002 | 网络全断 | 本地消息仍存在，状态可恢复 |
| API-003 | 同 operation 重试/FFI 重连 | 单一 EventId/事实 |
| API-004 | commit 前取消 | 无事件；资源释放 |
| API-005 | commit 后取消竞态 | 返回/查询到 committed，不伪造 cancelled |
| API-006 | 下游错误矩阵 | AppError 映射稳定且脱敏 |
| API-007 | 慢 UI stream | Gap/重新查询，无内核阻塞 |
| API-008 | Flutter isolate 重启 | 订阅清理，可重新初始化 |
| API-009 | 超长文本/附件数 | 进入密码/存储前拒绝 |
| API-010 | Mock Ports call trace | 调用顺序和补偿符合 saga |

## 8. 验收

Flutter 只依赖生成 facade；断网发送、本地重启、重复点击不会产生重复消息；替换任一 infra 实现无需改 UI API。

