# M06：Sync & Replication

## 1. 功能与边界

比较两个已信任端点的事件库存、发现缺口、分批交换事件/公开身份更新、维护同步游标并协调重新验证。支持设备间、直连 peer 和 Mailbox 拉取后的统一入站管线。

不负责传输连接、事件解密、业务投影、节点发现、Relay/Mailbox 存储或会话权限定义。

## 2. 协议 DTO

```rust
pub struct SyncHello {
    pub protocol: VersionRange,
    pub peer: SyncPeerIdentity,
    pub inventories: Vec<ConversationInventory>,
    pub max_batch_bytes: u32,
    pub features: SyncFeatures,
}

pub struct ConversationInventory {
    pub conversation: ConversationId,
    pub policy_epoch: u64,
    pub heads: Vec<EventId>,
    pub frontier_digest: DigestBytes,
    pub count_hint: Option<u64>,
}

pub struct SyncBatch {
    pub session: SyncSessionId,
    pub sequence: u64,
    pub items: Vec<EncodedSyncItem>,
    pub final_in_window: bool,
}
```

## 3. Port 签名

```rust
pub trait SyncPort: Send + Sync {
    fn begin<'a>(
        &'a self,
        ctx: &'a RequestContext,
        remote: SyncHello,
    ) -> BoxFuture<'a, Result<SyncPlan, ContractError>>;

    fn next_outbound<'a>(
        &'a self,
        ctx: &'a RequestContext,
        session: SyncSessionId,
        credit: SyncCredit,
    ) -> BoxFuture<'a, Result<Option<SyncBatch>, ContractError>>;

    fn accept_inbound<'a>(
        &'a self,
        ctx: &'a RequestContext,
        session: SyncSessionId,
        batch: SyncBatch,
    ) -> BoxFuture<'a, Result<InboundBatchAck, ContractError>>;

    fn acknowledge<'a>(
        &'a self,
        ctx: &'a RequestContext,
        session: SyncSessionId,
        ack: SyncAck,
    ) -> BoxFuture<'a, Result<(), ContractError>>;

    fn resume<'a>(
        &'a self,
        ctx: &'a RequestContext,
        token: SyncResumeToken,
    ) -> BoxFuture<'a, Result<SyncPlan, ContractError>>;

    fn status<'a>(
        &'a self,
        ctx: &'a RequestContext,
        session: SyncSessionId,
    ) -> BoxFuture<'a, Result<SyncStatus, ContractError>>;
}
```

## 4. 入站验证管线

```text
frame limits
→ protocol decode
→ identity/device verification
→ signature/EventId verification
→ conversation epoch/policy check
→ crypto replay/integrity check
→ Event Store append
→ projection notification (outbox)
```

M06 仅编排各 Port；每个判断仍由拥有模块完成。任何失败都转换为有界、不可枚举隐私的同步结果。

## 5. 限制与并发

- 一个 batch 最大 128 items 或 8 MiB；每会话单次 inventory heads 最大 64。
- session 默认 15 分钟无活动过期；resume token 单次使用并绑定 peer、版本和 frontier。
- 每 `(peer, conversation)` 只有一个主动 reconciliation；重复 begin 合并到现有 session。
- 不同会话并发，单会话导入按依赖层次推进；不得持有 Event Store 事务等待网络。
- peer credit 控制发送量；没有 credit 不生成/缓存无限 outbound batch。
- count/digest 仅作提示，不作为完整性信任来源。

## 6. 缺口与反滥用

- 缺父采用有界 request set；每会话最多 4096 个未解析 ID。
- 远端持续发送无父垃圾事件触发 peer budget 降级和暂时隔离。
- 不向未授权 peer 暴露会话 inventory；会话存在性本身视为敏感元数据。
- 不自动接受 identity/control fork；交给 M01/M02 quarantine。

## 7. Integration Events

- `SyncStartedV0`
- `SyncGapDetectedV0`
- `SyncCompletedV0`
- `SyncPeerQuarantinedV0`

观测事件不含会话成员、IP、消息正文或完整 frontier；详细诊断仅本地受限日志。

## 8. ACL

- `store_adapter`：heads/page 与 inventory/local batch 转换。
- `validation_adapter`：串接 M01/M02/M03，产出 M04 可接收的 verified marker。
- `transport_adapter`：把 batch 转为 M08 bounded stream frame。

## 9. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| SY-001 | 两端各有独立分支 | 双向同步后 heads/事件集合一致 |
| SY-002 | batch 重复、乱序、ACK 丢失 | 最终完成，无重复事实 |
| SY-003 | 中途断线并 resume | 从持久化 checkpoint 继续 |
| SY-004 | resume token 重放/换 peer | 拒绝 |
| SY-005 | 伪造 count/digest | 不造成数据丢失或错误完成 |
| SY-006 | 大量缺父垃圾 | 预算生效、内存有界、peer 隔离 |
| SY-007 | identity/control fork | 不进入 ready store，产生 quarantine |
| SY-008 | 不同会话并发 100 路 | 公平推进，无单会话饿死 |
| SY-009 | credit=0 慢端 | 不缓存无界数据 |
| SY-010 | 模拟网络分区后恢复 | 最终收敛且状态可观测 |

模型测试以两个参考事件 DAG 随机增删连接，验证反熵最终收敛、无越权泄露和严格资源上限。

## 10. 验收

在重复、乱序、丢包、断线、恶意缺父输入下保持有界且最终收敛；M06 无数据库表跨界访问，也不能读取明文。
