# M16：Observability & Abuse Control

## 1. 功能与边界

提供低基数指标、结构化脱敏日志、审计记录、健康摘要、速率/并发/存储配额和本地封禁策略。每个服务节点独立执行策略，不形成唯一全网控制中心。

不接触消息明文、私钥、联系人图，不决定会话业务权限，不把 IP/UserId/ConversationId 作为指标 label。

## 2. Port 签名

```rust
pub trait MetricsPort: Send + Sync {
    fn counter(&self, metric: MetricId, value: u64, labels: SafeLabels)
        -> Result<(), TelemetryError>;
    fn histogram(&self, metric: MetricId, value: f64, labels: SafeLabels)
        -> Result<(), TelemetryError>;
    fn gauge(&self, metric: MetricId, value: f64, labels: SafeLabels)
        -> Result<(), TelemetryError>;
}

pub trait AuditPort: Send + Sync {
    fn record<'a>(
        &'a self, ctx: &'a RequestContext, event: SafeAuditEvent,
    ) -> BoxFuture<'a, Result<(), ContractError>>;
}

pub trait QuotaPort: Send + Sync {
    fn acquire<'a>(
        &'a self, ctx: &'a RequestContext, request: QuotaRequest,
    ) -> BoxFuture<'a, Result<QuotaLease, ContractError>>;

    fn consume<'a>(
        &'a self, ctx: &'a RequestContext, lease: QuotaLease,
        amount: ResourceAmount,
    ) -> BoxFuture<'a, Result<QuotaDecision, ContractError>>;

    fn release<'a>(
        &'a self, ctx: &'a RequestContext, lease: QuotaLease,
    ) -> BoxFuture<'a, Result<(), ContractError>>;

    fn inspect_policy<'a>(
        &'a self, ctx: &'a RequestContext, subject: PolicySubject,
    ) -> BoxFuture<'a, Result<QuotaPolicyView, ContractError>>;
}
```

## 3. 安全标签与主体

`SafeLabels` 是允许列表枚举组合，例如 module、operation、result class、protocol major、role、coarse size bucket。编译期/运行时均拒绝任意用户字符串。

`PolicySubject` 使用服务本地、轮换或 capability 派生的假名；精确 IP 如为滥用调查所需，仅进入受限短期审计存储，不能进入指标或普通日志。

## 4. 配额语义

- 维度：请求速率、并发、字节/时间窗、存储字节/对象、CPU budget（可测时）。
- `QuotaLease` 有过期与资源上限；进程崩溃后租约自动失效或由持久计数恢复。
- 拒绝返回 coarse retry advice，避免泄漏其他租户占用。
- 安全硬上限不能被租户配置放大；热更新只可收紧或在验证后放宽。
- Metrics/Audit 自身失败不得阻塞普通聊天；Quota 判定失败对公共服务 fail closed，对本地 UI 可按明确策略降级。

## 5. 保留与隐私

- 普通日志默认 7 天或更短，审计保留独立配置；文档化删除流程。
- trace correlation ID 是随机 operation ID，不编码用户或节点拓扑。
- 敏感字节类型无 `Debug`；tracing field 扫描作为 CI 门槛。
- crash dump/heap profile 在生产默认关闭或加密受控。

## 6. ACL

每个消费者 adapter 只提交预定义 Metric/Audit enum。M09/M10/M12 向 quota 传资源与假名 subject；M16 不获取其业务 DTO。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| OB-001 | label 注入高基数字符串 | 编译/API 不允许或运行拒绝 |
| OB-002 | 明文/ID/KeyRef 错误链 | 日志快照无敏感值 |
| OB-003 | token bucket 边界/时间跳变 | 参考模型一致，单调时钟 |
| OB-004 | 并发 acquire/consume | 不突破硬上限 |
| OB-005 | lease holder 崩溃 | 租约回收，无永久泄漏 |
| OB-006 | telemetry backend 离线 | 业务不中断，缓冲有界/丢弃可观测 |
| OB-007 | quota backend 离线 | 公共服务 fail closed |
| OB-008 | 多租户压力 | 公平性与隔离符合策略 |
| OB-009 | retention 清理 | 到期数据不可普通查询恢复 |
| OB-010 | fuzz audit fields | 任意输入不能绕过 allowlist |

## 8. 验收

服务可判断容量与滥用而无需读取聊天内容；指标基数有静态上限；观测后端故障不会引起内存失控或核心状态损坏。

