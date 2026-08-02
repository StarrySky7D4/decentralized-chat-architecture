# M07：Delivery Scheduler & Route Selection

## 1. 功能与边界

把已提交的出站 opaque envelope 转换为耐久投递 Job，选择 Direct/Relay/Mailbox 路径，执行有界重试，合并分阶段回执，并向上层报告可恢复状态。

不负责 Socket、NAT、Relay/Mailbox 服务内部逻辑、消息加密、成员权限或 UI 文案。

## 2. 状态机

```text
Queued → Attempting → RouteAccepted → MailboxPersisted
                    ↘ DeviceReceived → EventApplied → Completed
       ↘ Backoff ↗
       ↘ Expired / Cancelled / PermanentFailure
```

状态只能单调推进。`MailboxPersisted` 表示离线副本存在，不表示设备已收到；`DeviceReceived` 也不表示已成功写入事件日志。

## 3. Port 签名

```rust
pub trait DeliveryCommandPort: Send + Sync {
    fn enqueue<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: EnqueueDelivery,
    ) -> BoxFuture<'a, Result<DeliveryJobView, ContractError>>;

    fn enqueue_batch<'a>(
        &'a self,
        ctx: &'a RequestContext,
        requests: Vec<EnqueueDelivery>,
    ) -> BoxFuture<'a, Result<Vec<DeliveryJobView>, ContractError>>;

    fn accept_receipt<'a>(
        &'a self,
        ctx: &'a RequestContext,
        receipt: VerifiedDeliveryReceipt,
    ) -> BoxFuture<'a, Result<ReceiptApplyOutcome, ContractError>>;

    fn retry_now<'a>(
        &'a self,
        ctx: &'a RequestContext,
        job: DeliveryJobId,
    ) -> BoxFuture<'a, Result<DeliveryJobView, ContractError>>;

    fn cancel<'a>(
        &'a self,
        ctx: &'a RequestContext,
        job: DeliveryJobId,
        reason: CancellationReason,
    ) -> BoxFuture<'a, Result<CancelOutcome, ContractError>>;
}

pub trait DeliveryQueryPort: Send + Sync {
    fn status<'a>(
        &'a self,
        ctx: &'a RequestContext,
        job: DeliveryJobId,
    ) -> BoxFuture<'a, Result<DeliveryJobView, ContractError>>;

    fn by_event<'a>(
        &'a self,
        ctx: &'a RequestContext,
        event: EventId,
    ) -> BoxFuture<'a, Result<Vec<DeliveryJobView>, ContractError>>;

    fn subscribe(
        &self,
        ctx: RequestContext,
        filter: DeliverySubscription,
    ) -> Result<BoxStream<DeliveryDelta>, ContractError>;
}

pub trait RouteExecutorPort: Send + Sync {
    fn attempt<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: RouteAttempt,
    ) -> BoxFuture<'a, Result<RouteAttemptOutcome, ContractError>>;
}
```

## 4. Job 与幂等性

```rust
pub struct EnqueueDelivery {
    pub event: EventId,
    pub target: DeliveryTarget,
    pub envelope: OpaqueEnvelopeRef,
    pub policy: DeliveryPolicy,
    pub expires_at: UnixMillis,
}
```

- 幂等键为 `(EventId, DeliveryTargetId, EnvelopeId, policy_revision)`。
- 相同键重复 enqueue 返回同一 Job；同 EnvelopeId 不同 bytes 为 integrity failure。
- Job 状态、下一次尝试、lease、receipt 和 outbox 同属 M07 事务。
- worker 使用短租约 claim；崩溃后 lease 过期可接管。至少一次 attempt，路由端按 EnvelopeId 去重。

## 5. 路由策略

默认策略：可达直连 → 已验证 Relay → 至少一个 Mailbox。路径评分只使用 M11 的公开健康/能力摘要，不把会话或联系人信息交给 Discovery。

- 单 Job 同时最多 2 个主动短路径 attempt；Mailbox 可按 policy 复制到 1–3 个节点。
- 重试指数退避 + full jitter；默认 1s 起、5min 封顶、总寿命受 envelope TTL 限制。
- `IntegrityFailure/Forbidden/UnsupportedVersion` 永不自动重试。
- route attempt 自身不做长期重试；M07 是唯一重试 owner。
- 用户取消不撤回已经由 Mailbox 持久化的密文，只停止后续尝试并产生真实状态。

## 6. ACL

- `transport_route_adapter`：M08 direct session。
- `relay_route_adapter`：M09 circuit/forward。
- `mailbox_route_adapter`：M10 put/receipt。
- `discovery_adapter`：M11 候选节点摘要 → 本地 RouteCandidate。
- 所有 adapter 只见 opaque envelope，不见明文事件。

## 7. Integration Events

- `DeliveryQueuedV0`
- `DeliveryStageAdvancedV0`
- `DeliveryExhaustedV0`
- `DeliveryExpiredV0`

## 8. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| DL-001 | 同 Job 并发 enqueue | 仅一个 Job |
| DL-002 | Direct 失败、Relay 成功 | 自动回退且不重复完成 |
| DL-003 | Relay 与 Mailbox 同时成功 | 回执单调合并 |
| DL-004 | worker claim 后崩溃 | lease 后接管，状态不丢 |
| DL-005 | ACK 丢失导致重复 attempt | 路由去重，Job 最终一致 |
| DL-006 | 旧/伪造/降级 receipt | 拒绝或忽略，不倒退状态 |
| DL-007 | TTL 到期 | 不再 attempt，标记 Expired |
| DL-008 | 100k Job 压力 | 有界 worker/in-flight、公平分片 |
| DL-009 | 永久错误 | 不进入重试风暴 |
| DL-010 | 慢订阅者 | Gap/关闭，不阻塞 worker |

## 9. 验收

关闭 Direct、Relay 或 Mailbox 任一路径均不改变上层 API；重启后 Job 可继续；所有重复 attempt/receipt 不造成状态倒退或重复事实。

