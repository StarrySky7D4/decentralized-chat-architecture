# M02：Conversation & Policy

## 1. 功能与边界

拥有会话类型、成员、角色、控制 Epoch、发言/管理权限和复制策略。对任意事件给出确定性的 `PolicyDecision`。

不负责：加密密钥细节、事件持久化、实际投递、用户身份私钥、UI 成员列表投影。

## 2. 公开 DTO

```rust
pub enum ConversationKind { Direct, Group, Broadcast, Forum, Workflow, Unknown(u16) }

pub struct ConversationSnapshot {
    pub id: ConversationId,
    pub kind: ConversationKind,
    pub control_epoch: u64,
    pub control_head: EventId,
    pub members: Vec<MemberView>,
    pub roles: Vec<RoleView>,
    pub crypto_policy: CryptoPolicyView,
    pub replication_policy: ReplicationPolicyView,
}

pub struct PolicyInput {
    pub actor: PrincipalId,
    pub device: DeviceId,
    pub event_kind: EventKindCode,
    pub referenced_epoch: u64,
    pub capability: Option<CapabilitySummary>,
    pub payload_facts: BoundaryPayloadFacts,
}

pub enum PolicyDecision { Allow, Deny(DenyReason), RequireApproval(ApprovalPolicy) }
```

`BoundaryPayloadFacts` 只含策略需要的受限事实，不把解密正文复制给模块。

## 3. Port 签名

```rust
pub trait ConversationCommandPort: Send + Sync {
    fn create<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: CreateConversationRequest,
    ) -> BoxFuture<'a, Result<ConversationSnapshot, ContractError>>;

    fn propose_control_change<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: ControlChangeRequest,
    ) -> BoxFuture<'a, Result<SignedControlProposal, ContractError>>;

    fn apply_control_event<'a>(
        &'a self,
        ctx: &'a RequestContext,
        event: VerifiedControlEvent,
    ) -> BoxFuture<'a, Result<ControlApplyOutcome, ContractError>>;

    fn quarantine_fork<'a>(
        &'a self,
        ctx: &'a RequestContext,
        fork: ControlForkEvidence,
    ) -> BoxFuture<'a, Result<(), ContractError>>;
}

pub trait ConversationQueryPort: Send + Sync {
    fn snapshot<'a>(
        &'a self,
        ctx: &'a RequestContext,
        id: ConversationId,
        epoch: Option<u64>,
    ) -> BoxFuture<'a, Result<ConversationSnapshot, ContractError>>;

    fn authorize<'a>(
        &'a self,
        ctx: &'a RequestContext,
        conversation: ConversationId,
        input: PolicyInput,
    ) -> BoxFuture<'a, Result<PolicyDecision, ContractError>>;

    fn delivery_recipients<'a>(
        &'a self,
        ctx: &'a RequestContext,
        conversation: ConversationId,
        epoch: u64,
    ) -> BoxFuture<'a, Result<Vec<RecipientView>, ContractError>>;
}
```

## 4. 不变量与限制

- Direct 会话在 V0 仅允许两个 `UserId`，双方设备集合由 M01 解析。
- 所有成员、角色、权限、复制和 crypto policy 变更都是控制事件，严格从 `epoch=n` 到 `n+1`。
- 控制事件必须引用唯一 `control_head`；同一 parent 的两个合法子事件视为 fork，进入隔离而非按时间选择。
- 内容事件可因果最终一致；策略判断使用事件声明的 epoch，不使用“当前 UI 状态”倒推。
- 被移除成员不能获得后续 epoch 的 recipient capability；历史读取权由明确历史策略决定。
- 默认最多：Direct 2、MVP Group 64、角色 32、单事件 capability proof 4 KiB。
- 未知控制事件属于安全关键未知值，停止推进；未知内容事件可显示不可解释占位。

## 5. 并发与事务

每个 `ConversationId` 单写者；`expected_epoch` 实现 CAS。查询可从不可变 snapshot 并发读取。批量 recipient 计算必须绑定 snapshot token，防止成员变更中途产生混合集合。

## 6. Integration Events

- `ConversationCreatedV0`
- `ControlEpochAdvancedV0`
- `MembershipChangedV0`
- `ConversationPolicyChangedV0`
- `ControlForkDetectedV0`

## 7. ACL

- `identity_adapter`：把 M01 的设备信任结果转为本地 `VerifiedPrincipal`。
- `crypto_adapter`：只传 `CryptoPolicyView/EpochTransition`，不读取密码状态。
- `delivery_adapter`：将 recipient view 映射为 M07 `DeliveryTarget`，不暴露内部角色对象。

## 8. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| CV-001 | Direct 创建 1/3 个成员 | 拒绝 |
| CV-002 | 非管理员添加成员 | `Deny`，不产生控制事件 |
| CV-003 | 两个并发 epoch n→n+1 | 一个应用，另一个 fork quarantine |
| CV-004 | 内容事件引用旧合法 epoch | 按旧 snapshot 确定判断 |
| CV-005 | 移除与发消息乱序到达 | 结果由引用 epoch 决定，与到达顺序无关 |
| CV-006 | 未知控制类型 | 停止 control head，发出兼容性告警 |
| CV-007 | recipient 查询期间成员变化 | 返回单一 snapshot token 下的集合 |
| CV-008 | 删除投影后重放控制事件 | snapshot 字节等价 |
| CV-009 | 超过 64 成员 | `QuotaExceeded` |
| CV-010 | 属性测试任意有效控制链 | epoch 连续、成员集合确定 |

## 9. 验收

任意到达顺序下，同一合法控制链产生同一快照；策略模块不依赖数据库、网络或密码实现；fork 和未知关键事件不会被静默接受。

