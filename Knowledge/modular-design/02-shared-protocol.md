# M00：共享协议内核

## 1. 职责

- 定义 ID、版本、canonical encoding、协议信封、回执和节点公开描述。
- 提供纯函数验证、编码/解码、签名输入生成和测试向量。
- 不拥有数据库、不执行网络 I/O、不生成业务事件、不管理密钥。

该模块是所有并行工作包的最小共同依赖；API 越小越好。

## 2. 基础类型与限制

```rust
pub struct UserId(pub [u8; 32]);
pub struct DeviceId(pub [u8; 32]);
pub struct AgentId(pub [u8; 32]);
pub struct ConversationId(pub [u8; 32]);
pub struct EventId(pub [u8; 32]);
pub struct NodeId(pub [u8; 32]);
pub struct TransportPeerId(pub Vec<u8>); // wire max 128 bytes
pub struct OperationId(pub [u8; 16]);

pub struct ProtocolVersion { pub major: u16, pub minor: u16 }
pub struct UnixMillis(pub i64);
pub struct LogicalTime(pub u64);
```

要求：

- ID 类型互不隐式转换，`Display/FromStr` 使用带类型前缀的 base32check。
- 文本格式最大 80 字符；解析拒绝混合大小写、非 canonical 编码和错误前缀。
- `EventId = hash(canonical_unsigned_event)`；不得使用本地自增 ID。
- `NodeId`、`UserId` 与签名公钥的绑定方式由 schema 明确，不等同 `TransportPeerId`。
- 所有长度先检查再分配；单个协议帧默认硬上限 1 MiB，控制帧 64 KiB。

## 3. 核心协议 DTO

```rust
pub struct EventEnvelopeV0 {
    pub version: ProtocolVersion,
    pub event_id: EventId,
    pub conversation_id: ConversationId,
    pub actor: PrincipalId,
    pub device_id: DeviceId,
    pub event_kind: EventKindCode,
    pub parents: BoundedVec<EventId, 32>,
    pub actor_sequence: u64,
    pub logical_time: LogicalTime,
    pub control_epoch: Option<u64>,
    pub crypto_epoch: Option<u64>,
    pub capability_proof: Option<BoundedBytes<4096>>,
    pub encrypted_payload: BoundedBytes<1_048_576>,
    pub signature: SignatureBytes,
}

pub struct OpaqueEnvelopeV0 {
    pub version: ProtocolVersion,
    pub routing_token: [u8; 32],
    pub envelope_id: [u8; 32],
    pub ciphertext: BoundedBytes<1_048_576>,
    pub expires_at: UnixMillis,
    pub sender_proof: BoundedBytes<4096>,
}

pub struct DeliveryReceiptV0 {
    pub envelope_id: [u8; 32],
    pub stage: ReceiptStage,
    pub observed_at: UnixMillis,
    pub receiver: ReceiptIssuer,
    pub proof: BoundedBytes<4096>,
}
```

`ReceiptStage` 至少区分 `AcceptedByRoute`、`PersistedByMailbox`、`ReceivedByDevice`、`AppliedToEventStore`。前两者不等同于用户设备已收到。

### 3.1 `actor_sequence` 语义

`actor_sequence` 是 `(conversation_id, device_id)` 作用域内、从 1 开始且永不复用的单调序号。选择设备而不是用户作为写入通道，是因为同一用户的多个设备可以离线并发写入；选择会话作用域则避免暴露一个可跨会话关联的全局设备计数器。它不是全局时间、控制 Epoch、密码 Epoch、投递次数或“仅一次”证明。

本地事件创建者必须遵守以下规则：

- 序号通过持久化 CAS/事务分配器原子保留；同一事务写入 `(OperationId, ConversationId, DeviceId) -> sequence` 绑定。并发创建者不得得到相同序号。
- 保留结果必须在事件签名或交给网络前 durable commit；已保留序号不得回收或分配给另一个 operation。重试同一 `OperationId` 必须恢复原绑定，而不是另取序号。
- 分配提交前崩溃等同于未分配；提交后、事件落库前崩溃可以留下缺号。缺号合法且不得阻塞接收、同步或投影，也不得用占位事件补齐。
- 序号不参与 nonce/key 派生。备份恢复必须恢复每个通道的已分配 high-water mark；无法证明 high-water mark 的旧设备身份不得继续发事件，应授权一个新的 `DeviceId`。

接收与重放规则：

- 相同 `EventId` 的重复到达是幂等重放；网络仍然是至少一次投递，本地事实写入依赖 `EventId` 唯一约束去重。
- 同一通道、同一 sequence 的两个不同且签名有效的 `EventId` 是 `SequenceEquivocation`。两者及依赖它们的事件进入隔离，保留规范化证据；不得按到达时间、logical time 或 EventId 选择赢家。
- 接收者不得因 sequence 小于本地 high-water mark 或中间有缺号而拒绝事件；这通常只是乱序或离线回补。sequence 回退只在同一事件的因果祖先关系与通道顺序矛盾、或形成环时构成无效证据。
- 设备撤销不改写历史。撤销前、按事件所引用身份/控制快照有效签署的事件仍可验证；撤销生效后新签事件拒绝准入，计数器不重置，重新授权必须使用新的 `DeviceId`。

完整决定见 [ADR-0006](../../adr/0006-event-sequence.md)。

## 4. 函数签名

```rust
pub fn encode_event_v0(value: &EventEnvelopeV0)
    -> Result<Vec<u8>, ProtocolError>;

pub fn decode_event(bytes: &[u8], limits: &DecodeLimits)
    -> Result<VersionedEventEnvelope, ProtocolError>;

pub fn unsigned_event_bytes_v0(value: &UnsignedEventV0)
    -> Result<Vec<u8>, ProtocolError>;

pub fn compute_event_id_v0(value: &UnsignedEventV0)
    -> Result<EventId, ProtocolError>;

pub fn validate_event_shape_v0(value: &EventEnvelopeV0, now: UnixMillis)
    -> Result<(), ProtocolError>;

pub fn encode_opaque_envelope_v0(value: &OpaqueEnvelopeV0)
    -> Result<Vec<u8>, ProtocolError>;

pub fn negotiate_version(
    local: &VersionRange,
    remote: &VersionRange,
) -> Result<ProtocolVersion, ProtocolError>;

pub fn parse_typed_id<T: TypedId>(text: &str) -> Result<T, IdParseError>;
pub fn format_typed_id<T: TypedId>(id: &T) -> String;

pub trait SignatureVerifierPort: Send + Sync {
    fn verify_canonical<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: CanonicalSignatureVerification,
    ) -> BoxFuture<'a, Result<VerificationDecision, ContractError>>;
}

pub trait EventAdmissionPort: Send + Sync {
    fn admit<'a>(
        &'a self,
        ctx: &'a RequestContext,
        candidate: EncodedEventCandidate,
        source: EventSource,
    ) -> BoxFuture<'a, Result<VerifiedEventEnvelope, ContractError>>;
}
```

`EventAdmissionPort` 是 composition 层的验证流水线契约：依次调用 M00 结构/ID/签名检查以及 M01、M02、M03 的设备、策略、密码检查。它不拥有状态；输出的 opaque stamp 仅用于防止工程误接线，不能替代操作系统级敌对插件隔离。

## 5. Canonical encoding 与签名覆盖

- V0 固定使用 deterministic CBOR profile；map key、整数宽度、数组顺序和未知字段处理必须写入 schema。
- 签名覆盖除 `signature` 外的全部 V0 字段，并绑定 `domain_separator = "dchat/event/v0"`。
- `event_id` 计算输入 `UnsignedEventV0` 明确排除 `event_id` 与 `signature`；签名输入包含已计算的 `event_id` 和除 `signature` 外的所有字段。验证时同时检查 ID 与签名。
- 解码器接受声明为可忽略的未知字段；重新编码不得把未知安全关键字段悄然删除后再转发。
- 禁止直接对语言对象内存、普通 JSON 或未 canonicalize 的 CBOR 签名。

## 6. NodeDescriptor

```rust
pub struct NodeDescriptorV0 {
    pub node_id: NodeId,
    pub sequence: u64,
    pub valid_until: UnixMillis,
    pub roles: BoundedVec<NodeRoleDescriptor, 32>,
    pub endpoints: BoundedVec<EndpointDescriptor, 32>,
    pub protocol_versions: VersionRange,
    pub public_keys: BoundedVec<PublicKeyDescriptor, 8>,
    pub signature: SignatureBytes,
}

pub fn validate_node_descriptor(
    descriptor: &NodeDescriptorV0,
    now: UnixMillis,
) -> Result<(), ProtocolError>;
```

限制：descriptor 总长不超过 64 KiB；endpoint 不允许内嵌凭据；过期、回滚 sequence、未知关键 role capability 必须拒绝。

## 7. 测试

### 固定向量

- 每种 ID 的全零、全一、随机、坏校验和、错误前缀、非 canonical 文本。
- EventEnvelope 的最小/最大合法样本与每个长度超限样本。
- Rust 编码结果逐字节等于仓库中的 `.cbor` golden file。
- 修改任一签名覆盖字段后验签失败；只修改 signature 不改变 EventId。
- 相同语义值在不同 map 顺序输入下 canonical bytes 相同。
- 相同 `(ConversationId, DeviceId, actor_sequence)`、不同 `EventId` 的签名样本产生 `SequenceEquivocation`；相同 `EventId` 重放幂等。
- `actor_sequence = 0` 拒绝；1、最大值、合法缺号和乱序回补有固定向量。

### 属性/模糊测试

- `decode(encode(x)) == x`（合法生成器）。
- 任意字节输入不 panic、不超预算分配、不超过解析深度。
- `parse(format(id)) == id`；任意非 canonical 形式被拒绝。
- 版本区间协商满足交换律，并选择共同支持的最高 minor。
- 序号分配崩溃点覆盖“事务前、保留提交后、事件提交后”；只允许无复用的缺号，不允许两个 operation 共用序号。
- 设备撤销与旧备份恢复生成器证明 high-water mark 不回退；无法证明时必须换新 `DeviceId`。

### 兼容性

- V0 reader 读取所有历史 V0 vectors。
- 新 minor writer 产物可被声明支持该 minor 的旧实现读取。
- 未知关键字段、未知 major 必须显式失败，不能降级为成功。

## 8. 验收

没有数据库、网络或随机时钟依赖；所有函数确定性；固定向量跨平台一致；fuzz 语料在 ASan/Miri 可用配置下无 panic、越界或失控分配。
