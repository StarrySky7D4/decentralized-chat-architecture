# M15：Node Runtime & Role Host

## 1. 功能与边界

是 composition root：加载配置、构造 adapters、启动客户端或服务节点角色、管理生命周期、健康检查、热更新安全配置和有序关闭。统一二进制可组合启用 Bootstrap/Relay/Mailbox/Blob 等角色。

不包含业务规则，不让角色通过全局单例直接调用彼此，不拥有协议 wire 类型，不以 feature flag 改变契约语义。

## 2. 配置 DTO

```rust
pub struct NodeConfigV0 {
    pub node: LocalNodeConfig,
    pub roles: Vec<RoleConfig>,
    pub storage: StorageConfig,
    pub transports: Vec<TransportConfig>,
    pub limits: GlobalLimits,
    pub observability: ObservabilityConfig,
}

pub enum RoleConfig {
    Bootstrap(BootstrapConfig),
    Relay(RelayConfig),
    Mailbox(MailboxConfig),
    Blob(BlobConfig),
    ClientCore(ClientCoreConfig),
}
```

配置不内嵌秘密；只含 `SecretRef`，由部署环境的 secret provider 解析。

## 3. Port 签名

```rust
pub trait NodeRuntimePort: Send + Sync {
    fn validate_config<'a>(
        &'a self, ctx: &'a RequestContext, config: NodeConfigV0,
    ) -> BoxFuture<'a, Result<ValidatedNodeConfig, ContractError>>;

    fn start<'a>(
        &'a self, ctx: &'a RequestContext, config: ValidatedNodeConfig,
    ) -> BoxFuture<'a, Result<NodeRuntimeHandle, ContractError>>;

    fn reload<'a>(
        &'a self, ctx: &'a RequestContext, handle: NodeRuntimeHandle,
        patch: ConfigPatch,
    ) -> BoxFuture<'a, Result<ReloadOutcome, ContractError>>;

    fn status<'a>(
        &'a self, ctx: &'a RequestContext, handle: NodeRuntimeHandle,
    ) -> BoxFuture<'a, Result<NodeRuntimeStatus, ContractError>>;

    fn shutdown<'a>(
        &'a self, ctx: &'a RequestContext, handle: NodeRuntimeHandle,
        deadline: UnixMillis,
    ) -> BoxFuture<'a, Result<ShutdownSummary, ContractError>>;
}

pub trait Role: Send + Sync {
    fn kind(&self) -> NodeRoleKind;
    fn start<'a>(&'a self, ctx: &'a RoleContext)
        -> BoxFuture<'a, Result<RoleReady, ContractError>>;
    fn health<'a>(&'a self, ctx: &'a RequestContext)
        -> BoxFuture<'a, RoleHealth>;
    fn stop<'a>(&'a self, ctx: &'a RequestContext, deadline: UnixMillis)
        -> BoxFuture<'a, Result<RoleStopSummary, ContractError>>;
}
```

## 4. 生命周期

```text
Parsed → Validated → Migrating → Starting → Ready/Degraded
                                      ↓
                              Draining → Stopped
```

- Ready 只有在必需迁移、监听器和关键依赖通过后设置。
- optional role 失败可使节点 Degraded；required role 失败导致启动回滚。
- reload 只允许白名单热参数（限额、日志级别、endpoint 发布）；密钥、存储路径、NodeId 需重启。
- shutdown：先撤销 descriptor/停止新流量，再 drain，刷新 outbox/checkpoint，最后关闭存储。

## 5. 隔离与资源

- 每角色有独立 task group、取消 token、并发 semaphore、存储 namespace 和健康状态。
- role 之间通过 Port；即便同进程也不访问内部 Arc/表。
- 全局内存、连接、文件描述符预算向角色分配；角色不能在运行时突破硬上限。
- panic 被 role supervisor 捕获并转为 unhealthy；安全关键存储 panic 默认停止节点，不盲目重启循环。
- config/schema 版本未知时 fail closed，并打印不含秘密的诊断。

## 6. ACL

Runtime composition adapters 是唯一允许同时依赖多个 infra crate 的位置。`RoleContext` 只提供它声明的 ports 和 scoped telemetry/quota，不提供 service locator。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| RT-001 | relay-only/mailbox-only/all | 仅声明角色启动且 descriptor 正确 |
| RT-002 | 配置未知字段/版本/秘密内嵌 | 按兼容规则拒绝 |
| RT-003 | required role 启动失败 | 已启动组件有序回滚 |
| RT-004 | optional role 失败 | runtime Degraded，其他角色可用 |
| RT-005 | reload 可/不可热更字段 | 原子应用 / 要求重启 |
| RT-006 | 每个 shutdown kill point | 无损坏，重启可恢复 |
| RT-007 | role panic/restart storm | 资源释放、退避、健康准确 |
| RT-008 | 角色资源超额 | 仅该角色受限，不拖垮节点 |
| RT-009 | 同进程边界测试 | 无跨表/实现依赖 |
| RT-010 | descriptor 生命周期 | Ready 后发布、drain 前撤销/过期 |

## 8. 验收

同一二进制可按配置独立运行任意角色组合；停用/故障一个角色不会越权访问或损坏另一个角色状态；健康状态与真实接流能力一致。

