# M18：Automation & Capability（后续阶段）

## 1. 功能与边界

拥有 AgentId、细粒度 capability、触发器、提议—批准—执行状态机、WASM 沙箱调度、执行结果与审计。先支持本地 agent，后支持会话内 agent 和自选远程执行节点。

不允许万能 token，不直接访问 Event Store/数据库/Socket/文件系统/私钥，不绕过 M02 权限，也不把模型输出当已授权事实。

## 2. 状态模型

```text
ObservedTrigger → Proposed → AwaitingApproval → Approved
                                      ↘ Rejected/Expired
Approved → Executing → Succeeded/Failed/Cancelled
```

每次高风险执行必须绑定不可重放的 `ProposalId + CapabilityGrantId + input_digest`。

## 3. DTO 与 Port

```rust
pub struct CapabilityGrant {
    pub id: CapabilityGrantId,
    pub subject: AgentId,
    pub audience: CapabilityAudience,
    pub scopes: Vec<CapabilityScope>,
    pub constraints: CapabilityConstraints,
    pub issued_at: UnixMillis,
    pub expires_at: UnixMillis,
    pub nonce: [u8; 16],
    pub issuer_signature: SignatureBytes,
}

pub trait AutomationPort: Send + Sync {
    fn register_agent<'a>(
        &'a self, ctx: &'a RequestContext, request: RegisterAgentRequest,
    ) -> BoxFuture<'a, Result<AgentView, ContractError>>;

    fn grant_capability<'a>(
        &'a self, ctx: &'a RequestContext, request: GrantCapabilityRequest,
    ) -> BoxFuture<'a, Result<CapabilityGrant, ContractError>>;

    fn revoke_capability<'a>(
        &'a self, ctx: &'a RequestContext, grant: CapabilityGrantId,
        expected_version: u64,
    ) -> BoxFuture<'a, Result<RevocationView, ContractError>>;

    fn propose<'a>(
        &'a self, ctx: &'a RequestContext, request: ActionProposalRequest,
    ) -> BoxFuture<'a, Result<ActionProposalView, ContractError>>;

    fn decide<'a>(
        &'a self, ctx: &'a RequestContext, decision: ApprovalDecision,
    ) -> BoxFuture<'a, Result<ActionProposalView, ContractError>>;

    fn execute<'a>(
        &'a self, ctx: &'a RequestContext, request: ExecuteApprovedAction,
    ) -> BoxFuture<'a, Result<ExecutionHandle, ContractError>>;

    fn execution_events(
        &self, ctx: RequestContext, handle: ExecutionHandle,
    ) -> Result<BoxStream<ExecutionEvent>, ContractError>;
}

pub trait CapabilityBrokerPort: Send + Sync {
    fn invoke<'a>(
        &'a self, ctx: &'a RequestContext, call: CapabilityCall,
    ) -> BoxFuture<'a, Result<CapabilityResult, ContractError>>;
}
```

## 4. Capability 约束

scope 必须是具体动词+资源，例如：

- `conversation.read_metadata(conversation, fields, time_range)`
- `message.propose_send(conversation, max_bytes)`
- `attachment.read(blob, max_bytes)`
- `schedule.create(local_profile, max_count)`

禁止 `all:*`、任意数据库查询、任意网络域名、任意文件路径。grant 同时绑定 audience、会话/本地 profile、时间、调用次数、字节、风险级别和是否每次需批准。

## 5. 沙箱限制

- WASM 默认无网络、文件、时钟、随机和环境变量；能力均由 broker 显式注入。
- 每执行配置 fuel、wall deadline、内存、输出、并发和日志上限。
- agent 输出视为不可信数据；经过 schema/大小/策略验证后才成为 proposal。
- broker 调用再次检查 grant 当前未撤销、input digest、audience 和 M02 policy。
- 远程执行只能得到最小密文/脱敏输入和一次性 capability，不获得用户根密钥。

## 6. 并发与幂等

以 AgentId 串行更新 grant，以 ProposalId 串行推进状态。相同 execute operation 只创建一个 execution；执行 side effect 使用独立 idempotency key。批准后 grant 被撤销时，未开始执行必须失败；已开始动作按 capability 声明的撤销语义完成或协作取消。

## 7. Integration Events

- `AgentRegisteredV0`
- `CapabilityGrantedV0` / `CapabilityRevokedV0`
- `ActionProposedV0` / `ActionDecidedV0`
- `ExecutionCompletedV0`

事件含输入/输出 digest 和安全摘要，不含模型 prompt、消息正文、secret 或任意 stdout。

## 8. ACL

所有能力 adapter 位于 M18 broker，调用 M13/M02/M12 等公开 Port。Agent/WASM 不能链接这些模块实现 crate；远程 adapter 也必须执行相同 conformance suite。

## 9. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| AG-001 | scope/audience/resource 越界 | broker 拒绝，无下游调用 |
| AG-002 | grant 过期/撤销/重放 | 拒绝 |
| AG-003 | proposal input 被修改 | digest 不匹配，不能执行 |
| AG-004 | 两个并发 approval/execute | 单一状态与 side effect |
| AG-005 | WASM 无限循环/内存增长/大输出 | fuel/内存/输出上限终止 |
| AG-006 | 尝试网络/文件/env | 无 capability 时不可访问 |
| AG-007 | 执行中撤销 | 按声明语义取消或完成并审计 |
| AG-008 | broker crash/ACK 丢失 | idempotency 防止重复 side effect |
| AG-009 | prompt injection 生成越权 call | schema/policy 拒绝 |
| AG-010 | 本地/远程 executor conformance | 相同 capability 与审计语义 |

## 10. 验收

删除整个自动化模块不会影响普通聊天；任何 agent 行为都能追溯到 grant、proposal、批准与结果；无 grant 时沙箱不能产生外部副作用。

