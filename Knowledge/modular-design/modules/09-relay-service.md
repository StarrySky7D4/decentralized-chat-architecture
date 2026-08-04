# M09：Relay Service

## 1. 功能与边界

为不可直连的两个端点建立短期、受配额的双向密文 circuit。客户端侧提供 route adapter，服务侧提供认证、授权、连接配对、转发和滥用控制。

不负责离线持久化、消息解密、会话成员判断、全局用户账户、长期历史或可靠最终送达。

## 2. Port 签名

```rust
pub trait RelayClientPort: Send + Sync {
    fn reserve<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: RelayReservationRequest,
    ) -> BoxFuture<'a, Result<RelayReservation, ContractError>>;

    fn open_circuit<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: OpenCircuitRequest,
    ) -> BoxFuture<'a, Result<RelayCircuitHandle, ContractError>>;

    fn forward<'a>(
        &'a self,
        ctx: &'a RequestContext,
        circuit: RelayCircuitHandle,
        frame: OpaqueRouteFrame,
    ) -> BoxFuture<'a, Result<RelayForwardAck, ContractError>>;

    fn close<'a>(
        &'a self,
        ctx: &'a RequestContext,
        circuit: RelayCircuitHandle,
    ) -> BoxFuture<'a, Result<(), ContractError>>;
}

pub trait RelayServicePort: Send + Sync {
    fn create_reservation<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: VerifiedReservationRequest,
    ) -> BoxFuture<'a, Result<SignedReservationGrant, ContractError>>;

    fn attach_endpoint<'a>(
        &'a self,
        ctx: &'a RequestContext,
        grant: SignedReservationGrant,
        endpoint: AuthenticatedEndpoint,
    ) -> BoxFuture<'a, Result<AttachOutcome, ContractError>>;

    fn service_status<'a>(
        &'a self,
        ctx: &'a RequestContext,
    ) -> BoxFuture<'a, Result<RelayPublicStatus, ContractError>>;
}
```

## 3. 数据最小化

Relay 可见：其直接连接端点、circuit 随机 ID、密文字节长度、时间和配额主体。Relay 不应获得 UserId、ConversationId、EventId、消息类型、成员列表、Mailbox token 或明文。

服务日志默认不记录完整 IP、circuit ID 或相邻关系；诊断采样使用轮换 salt 的不可逆桶，且有短保留期。

## 4. 限制与生命周期

- reservation 默认 10 分钟，最长 1 小时；circuit 空闲 2 分钟关闭。
- 单 frame 最大 1 MiB；每 circuit buffer 最大 4 MiB；超限反压或关闭。
- 每认证主体 reservation/circuit/带宽由 M16 policy 控制，并有全局硬上限。
- grant 带 audience、relay NodeId、过期、单次 nonce、流量上限和签名；不可转移。
- 服务只做短暂内存转发；不得悄然落盘。需要离线保存必须显式使用 M10。
- 对双向流采用公平调度，单 circuit 不得占满 worker。

## 5. Integration Events

服务只产生低基数观测/审计事件：`RelayReservationGranted`、`RelayCircuitClosed(reason_code)`、`RelayQuotaRejected`。不发送逐帧事件到全局总线。

## 6. ACL

- M07 的 `relay_route_adapter` 把 RelayForwardAck 映射为 `RouteAccepted`，绝不能映射为设备接收。
- M08 adapter 管理 transport session；Relay core 不使用 quinn/libp2p 类型。
- M16 adapter 只接收配额 subject 的假名标识与资源数值。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| RL-001 | 两 NAT 端经 relay | 密文双向传输、顺序符合 stream |
| RL-002 | grant 过期/换 relay/重放 | 拒绝 |
| RL-003 | 慢接收端 | 有界背压，不影响其他 circuit |
| RL-004 | 单主体带宽/连接攻击 | 配额生效，服务保持可用 |
| RL-005 | 一端断线/半开 | circuit 及时关闭，资源回收 |
| RL-006 | frame 超限/fuzz | 分配前拒绝，无落盘 |
| RL-007 | 日志检查 | 无明文、UserId、ConversationId、完整拓扑 |
| RL-008 | 服务重启 | circuit 失败可由上层重建，无伪 ACK |
| RL-009 | 公平性压力 | 多租户有界延迟，无单 circuit 饿死他人 |
| RL-010 | 协议降级 | 不支持版本明确拒绝 |

## 8. 验收

Relay 数据目录不含消息帧；进程内存/任务/连接严格受限；替换任意 Relay 节点不改变用户身份、会话或加密状态。
