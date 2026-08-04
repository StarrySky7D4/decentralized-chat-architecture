# 边界、防腐层与依赖规则

## 1. 模块形态

模块是逻辑所有权边界，不强制对应独立发布单元。独立开发者可以先在一个 crate 内用私有目录保持 `ports/core/infra` 方向：

```text
<module>/ports   稳定 Port、DTO、错误码、integration event schema
<module>/core    私有领域模型与用例
<module>/infra   数据库、网络、密码库等适配器
```

依赖方向不因是否分 crate 而改变：`ports` 不依赖 `core` 或 `infra`；`core` 只依赖自己的 ports、共享 primitives 和它所消费的其他 ports。可执行程序仅在 composition root 组装实现。

仅在以下任一条件成立时拆成独立 crate：需要独立版本兼容测试；外部依赖或 feature 必须隔离；同一边界出现第二个可替换实现；编译时间或多人文件所有权已形成实际冲突。不得为了模块清单完整而一次创建 18 组空 crate。

## 2. 防腐层（ACL）位置

消费者负责翻译：

```text
M07 Delivery 内部 DeliveryPlan
        │
        ▼
M07/acl/transport_adapter.rs
        │ TransportRequest DTO
        ▼
M08 TransportPort
```

规则：

- ACL 文件归消费者所有，生产者不理解消费者领域语言。
- ACL 必须显式映射每个字段；禁止 `serde_json::Value`、无类型 `Map` 或 `From` 的隐式全字段透传。
- ACL 负责单位、时间基准、枚举未知值、版本差异和错误分类转换。
- 外部返回未知枚举时映射为 `Unknown(raw)`，不得 panic。
- ACL 不执行业务决策；它只验证边界形状和翻译语义。

## 3. 允许的交互方式

| 方式 | 用途 | 保证 | 禁止 |
|---|---|---|---|
| Command Port | 请求一个模块改变其状态 | 幂等键、截止时间、稳定结果 | 跨模块事务 |
| Query Port | 获取边界快照或分页数据 | 明确一致性级别、游标 | 返回内部 ORM 实体 |
| Event Port | 广播已发生事实 | durable outbox、至少一次 | 用事件伪装同步 RPC |
| Stream Port | UI 状态、网络帧、批量结果 | 有界缓冲、lag/gap 信号 | 无界 channel |
| Blob Handle | 大字节对象 | 内容寻址、长度上限 | 在普通 DTO 复制大文件 |

## 4. 公共调用上下文

```rust
pub struct RequestContext {
    pub operation_id: OperationId,       // 幂等/追踪，不含用户可识别信息
    pub trace_id: TraceId,
    pub caller: CallerPrincipal,
    pub deadline: Option<UnixMillis>,
    pub cancellation: CancellationId,
}

pub struct PageRequest<C> {
    pub cursor: Option<C>,
    pub limit: u16,
}

pub struct Page<T, C> {
    pub items: Vec<T>,
    pub next: Option<C>,
    pub snapshot: SnapshotToken,
}
```

约束：

- 模块在执行不可逆副作用前再次检查 deadline/cancellation。
- cancellation 是协作式停止，不撤销已经提交的事实。
- `operation_id` 在重试时保持不变；新的用户动作必须使用新 ID。
- 分页 `limit` 全局硬上限 500，具体模块可更低。

## 5. 稳定错误模型

```rust
pub struct ContractError {
    pub code: ErrorCode,
    pub retry: RetryAdvice,
    pub safe_message: Option<String>,
    pub details: BTreeMap<DetailKey, DetailValue>,
}

pub enum RetryAdvice {
    Never,
    Immediate,
    After { delay_ms: u32 },
    AfterDependencyRecovery,
}

pub enum ErrorCode {
    InvalidArgument,
    UnsupportedVersion,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    StaleEpoch,
    QuotaExceeded,
    Busy,
    Timeout,
    Cancelled,
    Unavailable,
    IntegrityFailure,
    DependencyFailure,
    Internal,
    Unknown(u32),
}
```

错误约束：

- 底层库错误不得跨边界；ACL 映射为稳定错误码，原错误仅进入脱敏内部日志。
- `IntegrityFailure`、认证失败和未知密文不得自动重试。
- 只有拥有副作用的模块能决定该副作用是否安全重试。
- `safe_message` 不含路径、地址、用户名、密钥引用、消息内容或节点拓扑。

## 6. Integration Event

```rust
pub struct IntegrationEvent<E> {
    pub schema: SchemaId,
    pub event_id: IntegrationEventId,
    pub producer: ModuleId,
    pub aggregate: AggregateRef,
    pub aggregate_version: u64,
    pub occurred_at: UnixMillis,
    pub causation_id: OperationId,
    pub correlation_id: TraceId,
    pub payload: E,
}

pub trait IntegrationEventSink: Send + Sync {
    fn publish<'a>(
        &'a self,
        ctx: &'a RequestContext,
        batch: Vec<EncodedIntegrationEvent>,
    ) -> BoxFuture<'a, Result<PublishAck, ContractError>>;
}
```

语义：

- 写模型变化和 outbox 插入必须在同一个本模块事务中完成。
- 投递至少一次；消费者用 `event_id` 去重，并记录消费检查点。
- 同一 aggregate 按 `aggregate_version` 有序，不承诺跨 aggregate 全局顺序。
- 生产者保留 schema 兼容读取至少两个 minor 版本；破坏性变更使用新 `SchemaId`。

## 7. 并发与资源纪律

- 所有队列必须有容量、溢出行为和指标。
- 每个 Port 声明最大 in-flight；默认每调用方 64，网络服务按配额更低。
- 单聚合写入采用 mailbox/actor 或版本化 CAS；禁止持锁跨 `await`。
- 跨分片操作拆成可恢复 saga，不使用分布式锁或跨模块事务。
- 背压优先返回 `Busy/After`，不得静默丢弃控制事件；可丢弃的观测事件须明确标注。
- 重试使用指数退避、全抖动和最大尝试/寿命；不得在两层同时无限重试。
- 模块关闭顺序：停止接收 → drain 有界任务 → 刷新 outbox/checkpoint → 超时强停。

## 8. 数据所有权

- 一个表、目录或 key namespace 只能有一个模块写入。
- 其他模块通过 Port/事件获得副本，不创建跨模块外键。
- 跨模块只引用强类型 ID；删除采用 tombstone/撤销事件，不做级联删除。
- 持久化 schema 由拥有者迁移；启动前迁移失败则模块不进入 Ready。
- 测试可共享临时数据库进程，但必须使用独立 schema/文件和独立连接池。

## 9. 安全边界

边界绝不传递：

- 私钥字节、ratchet/MLS 内部对象；
- SQLite connection/transaction、ORM entity；
- QUIC/libp2p stream、socket、peer-store 引用；
- Flutter widget/controller、Rust FFI 指针；
- 明文消息给 Relay、Mailbox、Discovery、Blob 或 Observability。

敏感能力用不可伪造的句柄或 capability token 表示，token 必须带 audience、scope、过期时间和重放约束。

## 10. CI 边界检查

CI 应执行：

1. `cargo metadata` 生成依赖图，拒绝实现 crate 跨模块依赖和环。
2. 扫描 SQL，拒绝访问其他模块表前缀。
3. API snapshot/semver check，拒绝未声明的 breaking change。
4. wire golden vectors，逐字节比较 canonical encoding。
5. 契约 Fake 与所有实现运行同一 conformance suite。
6. 日志捕获测试，拒绝敏感字段出现在 tracing fields。
