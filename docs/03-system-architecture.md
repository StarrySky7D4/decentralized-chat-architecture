# 系统总体架构

## 分层结构

```text
┌──────────────────────────────┐
│ Flutter UI                   │
│ 页面 / 输入 / 通知 / 媒体     │
└──────────────┬───────────────┘
               │ Commands / Streams
┌──────────────▼───────────────┐
│ Rust Application API         │
│ 会话命令 / 查询 / 状态订阅     │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ Domain Core                  │
│ Identity / Event / Policy    │
│ Conversation / Capability    │
└───────┬───────────┬──────────┘
        │           │
┌───────▼──────┐ ┌──▼──────────┐
│ Crypto       │ │ Projection  │
│ Direct/Group │ │ Timeline    │
└───────┬──────┘ └──┬──────────┘
        │           │
┌───────▼───────────▼──────────┐
│ Sync Engine + Event Store    │
│ SQLite / Jobs / Receipts     │
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐
│ Pluggable Delivery           │
│ Direct / Relay / Mailbox     │
└──────────────────────────────┘
```

## 身份层级

```text
UserRoot
├── UserId
│   ├── DeviceId
│   └── AgentId
└── RecoveryCredential

ConversationId
EventId
NodeId
TransportPeerId
```

关键约束：

```text
UserId ≠ DeviceId ≠ NodeId ≠ TransportPeerId ≠ SessionId
```

用户身份不能因为更换设备、中继或网络地址而改变。

## 统一会话模型

```rust
struct Conversation {
    id: ConversationId,
    kind: ConversationKind,
    policy: ConversationPolicy,
    crypto: CryptoPolicy,
    replication: ReplicationPolicy,
}

enum ConversationKind {
    Direct,
    Group,
    Broadcast,
    Forum,
    Workflow,
}
```

私聊、群组、频道和工作流共享事件、权限、存储和同步模型，只由策略区分。

## 事件信封

```rust
struct EventEnvelope {
    protocol_version: u16,
    event_id: EventId,
    conversation_id: ConversationId,
    actor_id: PrincipalId,
    device_id: DeviceId,
    event_type: EventType,
    parents: Vec<EventId>,
    actor_sequence: u64,
    logical_time: u64,
    crypto_epoch: Option<u64>,
    capability_proof: Option<CapabilityProof>,
    encrypted_payload: Vec<u8>,
    signature: Signature,
}
```

## 一致性

消息平面采用因果最终一致：

- EventId 去重
- ActorSequence 保证发送者局部顺序
- Parents 表达依赖
- 确定性投影

控制平面采用线性 Epoch：

- 成员加入和移除
- 设备撤销
- 密钥更新
- 角色变化
- Agent 权限变化

普通聊天消息不需要全局共识，也不需要区块链。

## 本地存储

建议逻辑表：

```text
events
event_edges
conversation_state
member_projection
message_projection
delivery_jobs
delivery_receipts
crypto_sessions
crypto_epochs
attachments
search_index
agent_state
```

Event Store 保存事实，Projection 保存可重建的查询状态。
