# M08：Transport Session

## 1. 功能与边界

提供地址解析、监听/拨号、安全传输握手、版本协商、认证后的有界双向流、连接复用和网络变化恢复。可由 QUIC、WebSocket、内存传输或后续 libp2p 实现。

不负责端到端消息加密、节点选择、长期投递重试、Relay/Mailbox 业务、身份业务状态或同步协议解释。

## 2. 句柄与 DTO

```rust
pub struct SessionHandle(pub OpaqueHandle);
pub struct StreamHandle(pub OpaqueHandle);

pub struct DialRequest {
    pub peer: ExpectedTransportPeer,
    pub endpoints: Vec<EndpointDescriptor>,
    pub auth: TransportAuthOffer,
    pub versions: VersionRange,
    pub timeout_ms: u32,
}

pub struct TransportFrame {
    pub stream_sequence: u64,
    pub kind: FrameKind,
    pub payload: BoundedBytes<1_048_576>,
}
```

句柄只在 M08 Port 有效，不能序列化、持久化或比较内部地址。

## 3. Port 签名

```rust
pub trait TransportPort: Send + Sync {
    fn listen<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: ListenRequest,
    ) -> BoxFuture<'a, Result<ListenerHandle, ContractError>>;

    fn dial<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: DialRequest,
    ) -> BoxFuture<'a, Result<AuthenticatedSession, ContractError>>;

    fn open_stream<'a>(
        &'a self,
        ctx: &'a RequestContext,
        session: SessionHandle,
        protocol: ApplicationProtocolId,
        limits: StreamLimits,
    ) -> BoxFuture<'a, Result<StreamHandle, ContractError>>;

    fn send<'a>(
        &'a self,
        ctx: &'a RequestContext,
        stream: StreamHandle,
        frame: TransportFrame,
    ) -> BoxFuture<'a, Result<SendAck, ContractError>>;

    fn receive(
        &self,
        ctx: RequestContext,
        stream: StreamHandle,
    ) -> Result<BoxStream<Result<TransportFrame, ContractError>>, ContractError>;

    fn close_stream<'a>(
        &'a self,
        ctx: &'a RequestContext,
        stream: StreamHandle,
        reason: CloseReason,
    ) -> BoxFuture<'a, Result<(), ContractError>>;

    fn close_session<'a>(
        &'a self,
        ctx: &'a RequestContext,
        session: SessionHandle,
        reason: CloseReason,
    ) -> BoxFuture<'a, Result<(), ContractError>>;

    fn events(&self, ctx: RequestContext)
        -> Result<BoxStream<TransportEvent>, ContractError>;
}
```

## 4. 握手与信任

```text
address connect
→ transport security handshake
→ remote transport key proof
→ expected NodeId/DeviceId binding check
→ application protocol version negotiation
→ limits/role capability negotiation
→ AuthenticatedSession
```

TLS/QUIC 只保护链路，不能替代 M03 E2EE。未知远端身份不得升级成 authenticated session；Bootstrap 的匿名受限协议需要独立 `AnonymousBootstrapSession` 类型。

## 5. 限制与并发

- endpoint 数最大 16；单 endpoint 字符串 512 bytes；禁止 URL credentials。
- 每 peer 默认 2 个 session、每 session 64 streams、每 stream 32 in-flight frames；配置有全局硬上限。
- receive buffer 溢出关闭该 stream 并报告 `Busy`，不拖垮其他 stream。
- write 保序范围仅单 stream；不承诺跨 stream 顺序。
- 相同 peer 并发 dial 使用 singleflight；成功连接可复用，失败结果不永久缓存。
- DNS、代理、证书和 socket 错误映射为稳定类别，不泄漏本机路径/配置。
- 不在 transport 层无限重连；上层 M07/M06 决定重试。

## 6. ACL

- `delivery_adapter` 把 opaque envelope 变成 route protocol frame。
- `sync_adapter` 把 SyncBatch 变成 sync protocol frame。
- `relay_adapter` 使用独立 application protocol ID，不能获得底层 socket。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| TR-001 | 版本有/无交集 | 最高共同版本 / 明确失败 |
| TR-002 | 伪造 peer binding | 握手拒绝，应用数据未发送 |
| TR-003 | 100 个并发相同 dial | singleflight，有限底层连接 |
| TR-004 | 单 stream 慢读 | 仅该 stream 背压/关闭 |
| TR-005 | frame 超限/截断/fuzz | 分配前拒绝，不 panic |
| TR-006 | 网络切换/半开连接 | session 事件准确，调用方可恢复 |
| TR-007 | stream reset 与 ACK 竞态 | 单一终态，无悬挂任务 |
| TR-008 | graceful shutdown | 停接收、drain、超时关闭 |
| TR-009 | 内存/QUIC 实现 conformance | 同一 Port 行为集合 |
| TR-010 | TLS 可见性检查 | Relay 仍只收到 E2EE opaque payload |

## 8. 验收

上层测试可完全替换为 memory transport；网络错误不会泄漏具体实现；任何 peer/stream 不可造成无界连接、任务或缓冲增长。

