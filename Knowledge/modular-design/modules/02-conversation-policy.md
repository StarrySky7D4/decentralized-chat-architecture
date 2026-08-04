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
    pub fork_resolution_policy: ForkResolutionPolicyView,
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

pub enum ForkResolutionAction {
    SelectBranch { selected_root: EventId, selected_head: EventId },
    RollBackToBase,
}

pub struct ControlForkResolutionV0 {
    pub conversation_id: ConversationId,
    pub base_epoch: u64,
    pub base_head: EventId,
    pub resolution_round: [u8; 32],
    pub evidence: ControlForkEvidenceCommitment,
    pub action: ForkResolutionAction,
    pub next_control_epoch: u64,
    pub next_crypto_epoch: u64,
    pub rekey_commitment: [u8; 32],
    pub approvals: BoundedVec<ForkResolutionApproval, 64>,
}
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

    fn propose_fork_resolution<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: ForkResolutionRequest,
    ) -> BoxFuture<'a, Result<SignedForkResolutionProposal, ContractError>>;

    fn apply_fork_resolution<'a>(
        &'a self,
        ctx: &'a RequestContext,
        resolution: VerifiedForkResolution,
    ) -> BoxFuture<'a, Result<ForkResolutionOutcome, ContractError>>;
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
- 普通控制事件必须引用唯一 `control_head`；同一 parent 的两个合法子事件视为 fork。检测后有效快照回退并冻结在最后无歧义的共同祖先，所有竞争分支及后继进入隔离；不得保留“先到的赢家”。`ControlForkResolutionV0` 以选中 head（或回退时的 base）为唯一语义 parent，并另外绑定完整分叉证据。
- 内容事件可因果最终一致；策略判断使用事件声明的 epoch，不使用“当前 UI 状态”倒推。
- 被移除成员不能获得后续 epoch 的 recipient capability；历史读取权由明确历史策略决定。
- 默认最多：Direct 2、MVP Group 64、角色 32、单事件 capability proof 4 KiB。
- 未知控制事件属于安全关键未知值，停止推进；未知内容事件可显示不可解释占位。

## 5. 并发与事务

每个 `ConversationId` 单写者；`expected_epoch` 实现 CAS。查询可从不可变 snapshot 并发读取。批量 recipient 计算必须绑定 snapshot token，防止成员变更中途产生混合集合。

`fork_resolution_policy` 在会话创建时固化，之后只能由无分叉的普通控制事件修改。Direct V0 默认要求双方 `UserId` 审批；Group 必须在创建时显式给出管理员批准阈值，且阈值必须满足 `2 * threshold > eligible_approver_count`，保证任意两个合法 quorum 至少有一名共同审批者。不得在 fork 发生后降级。应用 resolution 时，控制 head、selected-path 标记、rejected tombstone 和 `rekey_pending` gate 必须作为一个原子状态转换提交。

### 5.1 控制分叉恢复协议

恢复不使用时间戳、到达顺序或 LWW，完整决定见 [ADR-0007](../../../adr/0007-control-fork-recovery.md)。V0 规则如下：

1. **冻结与证据。** `ControlForkEvidence` 包含会话、共同 `base_head/base_epoch`、按 EventId 排序的全部已知合法 branch roots/tips、每条从 base 到 tip 的 canonical event bytes/签名、策略验证结果及 crypto epoch/commitment。`ControlForkEvidenceCommitment` 保存 canonical manifest 的 digest、元素数量和分块/Merkle 参数，避免受信封 64 KiB 与 parents 数量限制影响；验证者必须能从 M04 按 digest 取回全部 manifest。base 之后的控制快照和引用这些分支 epoch 的内容事件均隔离；引用 `base_epoch` 或更早合法快照的内容可继续处理。
2. **发起者与授权基准。** 任何在 base snapshot 拥有 `ResolveControlFork` capability 的 principal 都可发起提案，但不能单方面生效。审批资格与阈值只按最后无歧义的 base snapshot 中 `fork_resolution_policy` 计算，不采用任一竞争分支授予或撤销的权限。每份审批由不同授权 `UserId` 的有效设备签署 canonical decision digest，并携带 base snapshot 下的设备授权证明；digest 覆盖 domain separator、resolution round、evidence commitment、action、两个 next epoch 与 rekey commitment。
3. **选择或废弃。** action 只能选择一条已完整验证的 `selected_root -> selected_head` 链，或 `RollBackToBase`。选择生效后，base 的全部后继中只有 base 到 selected head 的闭合祖先路径被采用；不在该路径内的现有及未来事件（包括 selected head 的迟到旧后继）均永久 rejected。回退则拒绝 base 的所有现有及未来旧后继。解析事件保存完整证据引用，不能删除被拒绝事实。
4. **新控制 head。** resolution 的唯一语义 parent 是 selected head，回退时则是 base；`next_control_epoch = parent.control_epoch + 1`。有效状态取 selected head 的完整状态或 base 状态，再以 resolution 作为唯一新 head。后续普通控制事件必须引用 resolution；迟到的旧分支后继即使声明更高 epoch 也不能重开分叉。
5. **密码 Epoch。** V0 对任何控制 fork 都强制 rekey。`next_crypto_epoch` 必须大于证据中所有分支及 base 的 crypto epoch，并绑定 M03 生成的 `rekey_commitment`；新密钥只发给解析后成员集合。在 rekey transition durable commit 前，禁止在解析后的控制 head 上发送内容。被拒分支的 key/commitment 永不并入新 epoch。
6. **幂等与二次冲突。** `resolution_round = hash("dchat/control-fork-resolution/v0", conversation_id, base_head)`，所以迟到 root 不会通过改变列表创建可并行批准的新 round。同一 round、同一 decision digest 的重复提交是 no-op；审批按 `UserId` 去重。若同一 round 出现两个各自满足阈值但 decision digest 不同的解析事件，说明至少一名 quorum 交集审批者发生 equivocation 或其设备已失陷。V0 将会话置为终止性的 `CompromisedControlState`，保留并导出证据，禁止再在同一 `ConversationId` 内解析或发送；参与者只能通过独立认证的带外流程创建新会话并重新验证身份。绝不按 epoch、时间或 EventId 选取。
7. **迟到证据。** 未列入 manifest、但不在所选闭合祖先路径内的 base 后继按 tombstone 确定拒绝。若后来证据证明 base 或已采用路径本身无效，则隔离 resolution，回退到更早无歧义祖先并以该祖先产生新的 round。

## 6. Integration Events

- `ConversationCreatedV0`
- `ControlEpochAdvancedV0`
- `MembershipChangedV0`
- `ConversationPolicyChangedV0`
- `ControlForkDetectedV0`
- `ControlForkResolvedV0`
- `ControlBranchRejectedV0`
- `ControlForkRekeyRequiredV0`

## 7. ACL

- `identity_adapter`：把 M01 的设备信任结果转为本地 `VerifiedPrincipal`。
- `crypto_adapter`：只传 `CryptoPolicyView/EpochTransition`，不读取密码状态。
- `delivery_adapter`：将 recipient view 映射为 M07 `DeliveryTarget`，不暴露内部角色对象。

## 8. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| CV-001 | Direct 创建 1/3 个成员 | 拒绝 |
| CV-002 | 非管理员添加成员 | `Deny`，不产生控制事件 |
| CV-003 | 两个并发 epoch n→n+1 | 两者及后继 quarantine，有效状态冻结在 epoch n |
| CV-004 | 内容事件引用旧合法 epoch | 按旧 snapshot 确定判断 |
| CV-005 | 移除与发消息乱序到达 | 结果由引用 epoch 决定，与到达顺序无关 |
| CV-006 | 未知控制类型 | 停止 control head，发出兼容性告警 |
| CV-007 | recipient 查询期间成员变化 | 返回单一 snapshot token 下的集合 |
| CV-008 | 删除投影后重放控制事件 | snapshot 字节等价 |
| CV-009 | 超过 64 成员 | `QuotaExceeded` |
| CV-010 | 属性测试任意有效控制链 | epoch 连续、成员集合确定 |
| CV-011 | base 授权不足或使用分支新授权限解析 | 拒绝，head 保持冻结 |
| CV-012 | 选择一条分支并满足 base 阈值 | resolution 成为唯一新 head，其他分支永久 rejected |
| CV-013 | 回退 base 并收到被拒分支的迟到后继 | 幂等拒绝，不重开 fork |
| CV-014 | resolution 提交/崩溃/重放 | 同 digest no-op，控制与 rekey 状态原子恢复 |
| CV-015 | 两个不同 decision 均满足阈值 | 进入终止性 `CompromisedControlState`；同一会话不可继续解析或发送 |
| CV-016 | fork 后 rekey 未 durable commit | 禁止在新 head 发送内容；旧分支 key 不可用 |
| CV-017 | Direct 只有一方批准 / Group 在 fork 后降阈值 | 不满足 base policy，保持冻结 |
| CV-018 | 33 个以上 sibling roots、分块证据乱序/缺块/篡改 | 完整 commitment 可验证；缺块或 digest 不符拒绝解析 |

## 9. 验收

任意到达顺序下，同一合法控制链及同一有效 resolution 产生同一快照；策略模块不依赖数据库、网络或密码实现；fork、冲突 resolution 和未知关键事件不会被静默接受。故障注入证明控制 head、rejected tombstone 与 rekey gate 原子恢复。
