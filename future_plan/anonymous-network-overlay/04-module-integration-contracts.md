# 模块集成与概念接口

## 1. 临时模块名

匿名覆盖层暂称 `F-AN Anonymous Overlay`。在正式 ADR 接受前，不分配 M19 编号，也不修改 M00–M18 的冻结依赖矩阵。

推荐发布单元：

```text
anonymous-overlay-ports
anonymous-overlay-core
anonymous-directory
anonymous-onion
anonymous-mix
anonymous-service-descriptor
anonymous-maildrop-adapter
anonymous-arti-adapter       # 验证期，可选
```

## 2. 主 Port

```rust
pub trait AnonymousOverlayPort: Send + Sync {
    fn prepare_target<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: PrepareAnonymousTarget,
    ) -> BoxFuture<'a, Result<AnonymousTargetRef, ContractError>>;

    fn plan_route<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: AnonymousRouteRequest,
    ) -> BoxFuture<'a, Result<AnonymousRoutePlan, ContractError>>;

    fn send<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: AnonymousSendRequest,
    ) -> BoxFuture<'a, Result<AnonymousSendOutcome, ContractError>>;

    fn publish_service<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: PublishAnonymousService,
    ) -> BoxFuture<'a, Result<ServicePublishReceipt, ContractError>>;

    fn poll_maildrop<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: AnonymousPollRequest,
    ) -> BoxFuture<'a, Result<AnonymousPollOutcome, ContractError>>;

    fn status<'a>(
        &'a self,
        ctx: &'a RequestContext,
        handle: AnonymousOperationHandle,
    ) -> BoxFuture<'a, Result<AnonymousOperationView, ContractError>>;

    fn events(
        &self,
        ctx: RequestContext,
        filter: AnonymousEventFilter,
    ) -> Result<BoxStream<AnonymousOverlayEvent>, ContractError>;
}
```

## 3. 核心 DTO

```rust
pub struct AnonymousRouteRequest {
    pub target: AnonymousTargetRef,
    pub privacy: DeliveryPrivacy,
    pub isolation: IsolationProfile,
    pub purpose: CircuitPurpose,
    pub deadline: Option<UnixMillis>,
}

pub struct AnonymousSendRequest {
    pub plan: AnonymousRoutePlanRef,
    pub envelope: OpaqueEnvelopeRef,
    pub expires_at: UnixMillis,
    pub operation_id: OperationId,
}

pub struct AnonymousRoutePlan {
    pub handle: AnonymousRoutePlanRef,
    pub privacy: DeliveryPrivacy,
    pub directory_epoch: u64,
    pub packet_class: PacketClass,
    pub expires_at: UnixMillis,
    pub expected_latency: CoarseLatencyClass,
}

pub enum AnonymousSendOutcome {
    AcceptedByOverlay { operation: AnonymousOperationHandle },
    PersistedByAnonymousMailbox { receipt: OpaqueReceiptRef },
    Deferred { retry: RetryAdvice },
}
```

公开 DTO 不包含完整 hop 列表、Guard 身份、CircuitId、ServiceId 原始值、密钥、真实 endpoint 或内部延迟分布。

## 4. Directory Port

```rust
pub trait AnonymousDirectoryPort: Send + Sync {
    fn ingest_descriptor<'a>(
        &'a self,
        ctx: &'a RequestContext,
        source: AnonymousDescriptorSource,
        descriptor: AnonymousNodeDescriptorV0,
    ) -> BoxFuture<'a, Result<DescriptorOutcome, ContractError>>;

    fn ingest_epoch_view<'a>(
        &'a self,
        ctx: &'a RequestContext,
        view: DirectoryEpochViewV0,
    ) -> BoxFuture<'a, Result<EpochViewOutcome, ContractError>>;

    fn select_candidates<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: AnonymousCandidateRequest,
    ) -> BoxFuture<'a, Result<AnonymousCandidateSet, ContractError>>;

    fn report_path_observation<'a>(
        &'a self,
        ctx: &'a RequestContext,
        observation: LocalPathObservation,
    ) -> BoxFuture<'a, Result<(), ContractError>>;

    fn trust_state<'a>(
        &'a self,
        ctx: &'a RequestContext,
    ) -> BoxFuture<'a, Result<DirectoryTrustState, ContractError>>;
}
```

`select_candidates` 返回 role/family/diversity 的 opaque candidate handle；调用者不能要求指定某个匿名节点，以免上层绕过路径策略。

## 5. Service Descriptor Port

```rust
pub trait AnonymousServicePort: Send + Sync {
    fn create_service<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: CreateAnonymousService,
    ) -> BoxFuture<'a, Result<AnonymousServiceHandle, ContractError>>;

    fn grant_contact_access<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: GrantDescriptorAccess,
    ) -> BoxFuture<'a, Result<DescriptorAccessCapability, ContractError>>;

    fn rotate_epoch<'a>(
        &'a self,
        ctx: &'a RequestContext,
        service: AnonymousServiceHandle,
        expected_epoch: u64,
    ) -> BoxFuture<'a, Result<ServiceEpochView, ContractError>>;

    fn resolve<'a>(
        &'a self,
        ctx: &'a RequestContext,
        capability: DescriptorAccessCapability,
    ) -> BoxFuture<'a, Result<ResolvedAnonymousService, ContractError>>;

    fn revoke_access<'a>(
        &'a self,
        ctx: &'a RequestContext,
        grant: DescriptorGrantId,
    ) -> BoxFuture<'a, Result<RevocationOutcome, ContractError>>;
}
```

联系人 capability 不等于聊天授权；解析成功后，M02/M03 仍执行成员、设备和内容密码验证。

## 6. 作为 M07 RouteExecutor

F-AN 实现现有 `RouteExecutorPort`：

```text
M07 DeliveryPlan
→ delivery/acl/anonymous_route_adapter
→ AnonymousRouteRequest
→ AnonymousOverlayPort
→ AnonymousSendOutcome
→ M07 RouteAttemptOutcome
```

映射规则：

- `AcceptedByOverlay` 只映射为 `RouteAccepted`。
- 匿名 Mailbox durable receipt 才映射为 `MailboxPersisted`。
- Overlay 的 circuit/packet ACK 不能映射为 `DeviceReceived`。
- `AnonymousRouteUnavailable` 不能触发 Direct fallback。
- retry owner 仍是 M07；F-AN 只在单次 operation 内执行有界内部恢复。

## 7. 现有模块映射

| 模块 | 集成方式 | 禁止 |
|---|---|---|
| M03 Crypto | 先生成 OpaqueEnvelope；验证 descriptor/路径握手所需公开签名 | 把 conversation key 交给匿名层 |
| M04 Event Store | 无直接依赖 | 持久化 CircuitId/path |
| M06 Sync | 把 SyncBatch 放入匿名 stream/packet | 了解 hop/Guard |
| M07 Delivery | 选择 privacy、排队和重试 | 匿名失败自动走普通路由 |
| M08 Transport | 提供逐 hop bounded stream | 看到完整路径和会话 |
| M09 Relay | 可复用 infra 能力但使用独立匿名协议/密钥 | 普通 circuit 与 Onion circuit 共享 identity |
| M10 Mailbox | 复用 lease/ACK 语义；新增 anon adapter | 复用普通 RoutingToken |
| M11 Discovery | 只提供 bootstrap transport；匿名目录独立 | 用普通健康分选择 Guard |
| M12 Attachment | manifest 走匿名消息、chunk 独立电路 | 大文件直接进入 Mix packet |
| M14 Platform | UI、随机 poll、隔离设置 | Push payload携带 ServiceId/精确事件 |
| M15 Runtime | 组装匿名角色 | service locator 跨角色直连 |
| M16 Observe/Quota | 固定安全指标、匿名资源配额 | path/circuit/service ID labels |

## 8. 错误与重试

```rust
pub enum AnonymousErrorCode {
    UnsupportedPrivacyProfile,
    DirectoryViewIncomplete,
    DirectoryViewUntrusted,
    AnonymitySetTooSmall,
    NoEligibleGuard,
    NoDiversePath,
    DescriptorUnavailable,
    DescriptorInvalid,
    ServiceAccessRevoked,
    CircuitBuildFailed,
    PathBiasSuspected,
    MixQueueSaturated,
    CoverBudgetUnavailable,
    PrivacyDowngradeRequired,
    Unknown(u32),
}
```

- 目录、签名、descriptor、路径偏置错误不能由上层立即随机重试。
- 单 hop 临时不可达可在同一 plan 的有限候选内恢复。
- plan 到期后必须重新取得可信 directory epoch，不能复用旧完整路径。
- `PrivacyDowngradeRequired` 的 retry advice 永远是 `Never`；只能创建新的用户批准操作。

## 9. 持久化与崩溃

F-AN 独占：

- Guard set 与迁移历史；
- directory epoch/view cache；
- Service descriptor key handles 和发布状态；
- circuit/mix operation checkpoint；
- reply block 使用状态；
- path bias 的本地粗粒度观测。

不持久化完整历史路径。崩溃后电路全部作废；Mix send operation 使用 operation ID 和 packet replay ID 恢复，不能重复使用 reply block、nonce 或 path key。

## 10. ACL 和依赖规则

- F-AN core 只依赖自身 ports、M00 primitives、M08 transport ports 和必要的 M03 signature/keystore ports。
- M07、M10、M12 等消费者各自维护 anonymous adapter。
- Arti、Nym/Sphinx、libp2p、QUIC 类型只存在于 infra adapter。
- 任何匿名库的原始错误、路径对象、地址或 stream 不得越过 F-AN Port。

