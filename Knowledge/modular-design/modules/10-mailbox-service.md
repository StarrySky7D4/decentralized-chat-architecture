# M10：Mailbox Service

## 1. 功能与边界

按不可关联的 `RoutingToken` 短期持久保存 opaque envelopes，提供幂等 put、持久化证明、分页 fetch、租约/确认删除和迁移能力。

不负责识别用户、解密、判断会话成员、投影消息、最终用户已读语义或永久历史备份。

## 2. Port 签名

```rust
pub trait MailboxClientPort: Send + Sync {
    fn put<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: MailboxPutRequest,
    ) -> BoxFuture<'a, Result<MailboxPutReceipt, ContractError>>;

    fn fetch<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: MailboxFetchRequest,
    ) -> BoxFuture<'a, Result<MailboxPage, ContractError>>;

    fn acknowledge<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: MailboxAckRequest,
    ) -> BoxFuture<'a, Result<MailboxAckOutcome, ContractError>>;

    fn inspect_lease<'a>(
        &'a self,
        ctx: &'a RequestContext,
        mailbox: MailboxRef,
    ) -> BoxFuture<'a, Result<MailboxLeaseView, ContractError>>;

    fn rotate_routing_token<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: RotateRoutingTokenRequest,
    ) -> BoxFuture<'a, Result<RoutingTokenGrant, ContractError>>;
}

pub trait MailboxServicePort: Send + Sync {
    fn store<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: VerifiedMailboxPut,
    ) -> BoxFuture<'a, Result<SignedPersistenceReceipt, ContractError>>;

    fn lease_page<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: VerifiedFetchRequest,
    ) -> BoxFuture<'a, Result<LeasedOpaquePage, ContractError>>;

    fn commit_ack<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: VerifiedAckRequest,
    ) -> BoxFuture<'a, Result<AckCommitOutcome, ContractError>>;
}
```

## 3. 语义

- `put` 幂等键为 `(RoutingToken, EnvelopeId)`；相同 ID/相同 bytes 返回同一持久化结果，不延长 TTL；不同 bytes 为 integrity failure。
- 只有数据库事务 durable commit 后才能签发 `PersistedByMailbox` receipt。
- `fetch` 返回有租约的密文页；未 ACK 的租约过期后可重新出现，因此客户端必须按 EnvelopeId 去重。
- ACK 可表示 `StoredLocally` 后删除或 `RejectPermanent`；不能用 ACK 表示用户已读。
- cursor 是 opaque、带 MAC、绑定 routing token 和 snapshot；客户端不得解释。
- 多 Mailbox 复制产生不同服务 receipt，但共享 EnvelopeId，接收端统一去重。
- Mailbox 不提供网络恰好一次：租约过期、ACK 丢失、客户端或服务重启都可以再次返回同一信封。唯一事实语义由客户端在同一事务中按 `EventId` 去重、提交 Event Store 并推进消费检查点实现。

## 4. 限制与隐私

- 单 envelope 最大 1 MiB；单页默认 32、最大 128 或 8 MiB。
- TTL 默认 7 天，服务可配置 1 小时–30 天硬范围；过期清理不提供精确时间侧信道。
- 单 routing token/主体/来源的数量、字节和速率配额独立控制。
- sender proof 只证明写入权限/成本，不暴露 UserId；无效 proof 在写盘前拒绝。
- token 可轮换且不能从 UserId/DeviceId 可逆派生；轮换迁移必须显式授权、限时。
- 服务指标不使用 routing token/envelope ID 作为标签。

## 5. 并发与崩溃

以 RoutingToken 分片；put 与 TTL 清理、fetch lease、ACK 删除使用行版本/CAS。服务崩溃后：已 receipt 的 envelope 必须存在；未 receipt 的可存在或不存在，客户端重试；ACK 提交返回成功后 envelope 不再重新租出。

## 6. ACL

- M07 adapter：put receipt → `MailboxPersisted`。
- M06 adapter：fetched opaque bytes → 完整入站验证管线；在本地 Event Store 提交后才 ACK `StoredLocally`。
- M16 adapter：假名 quota subject，不传会话/用户标识。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| MB-001 | 重复 put 相同 bytes | 单份存储、同语义 receipt |
| MB-002 | 相同 ID 不同 bytes | integrity failure |
| MB-003 | receipt 前后 kill points | receipt 成功必可恢复；否则可安全重试 |
| MB-004 | fetch 后客户端崩溃 | 租约过期再次可见 |
| MB-005 | 本地存储后 ACK 丢失 | 重复 ACK 幂等，最终删除 |
| MB-006 | 多 mailbox 重复信封 | 客户端只提交一个事实 |
| MB-007 | cursor 篡改/换 token | 拒绝，无枚举信息 |
| MB-008 | TTL/清理/put 竞态 | 状态满足参考模型 |
| MB-009 | 配额与大 envelope 攻击 | 写盘前拒绝、资源有界 |
| MB-010 | 数据/日志检查 | 仅 opaque bytes，无聊天元数据字段 |

## 8. 验收

离线接收者和 Mailbox 多次重启后仍可完整、至少一次拉取；故障注入必须证明重复投递是正常路径，客户端按 `EventId` 最终仅一次写入 Event Store；服务无法从 schema 解读聊天正文或会话成员。
