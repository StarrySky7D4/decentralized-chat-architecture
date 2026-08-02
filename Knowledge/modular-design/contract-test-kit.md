# 跨模块 Contract Test Kit

## 1. 目标

同一套行为测试运行于 Fake、内存实现、本地持久化实现和网络实现，确保上游只依赖 Port 语义，不依赖某个实现的偶然行为。

## 2. Harness

```rust
pub trait ContractHarness<P> {
    type Fixture;

    fn fresh(&self, config: ContractConfig) -> BoxFuture<'_, Self::Fixture>;
    fn port(fixture: &Self::Fixture) -> Arc<P>;
    fn clock(fixture: &Self::Fixture) -> TestClockControl;
    fn faults(fixture: &Self::Fixture) -> FaultControl;
    fn crash(fixture: Self::Fixture, point: CrashPoint) -> BoxFuture<'static, ()>;
    fn restart(&self) -> BoxFuture<'_, Self::Fixture>;
    fn inspect_resources(fixture: &Self::Fixture) -> ResourceSnapshot;
}
```

各模块暴露 `run_<module>_contract_suite(harness)`；实现不能删除测试，只能声明确实不适用且有规格依据的 capability。

## 3. 公共测试维度

### 3.1 输入边界

- 0、1、最大值、最大值+1；
- 非 canonical 编码、未知 enum/field/version；
- Unicode、空文本、超长 ID/endpoint；
- 先检查长度再分配，并验证递归深度。

### 3.2 幂等与并发

- 相同 operation 1/2/100 次顺序与并发；
- 不同 operation 竞争相同 expected version；
- cancel、timeout、commit、ACK 的所有关键竞态；
- 同分片串行、跨分片并发、公平性与无饥饿。

### 3.3 故障与恢复

每个有状态 API 必须标出：

```text
F0 调用前
F1 验证后
F2 写入开始
F3 状态已写/outbox 未写
F4 transaction durable/ACK 未发
F5 ACK 已发/调用方未收
```

在每点 kill/restart；验证“全无、可安全重试、或已提交可查询”三者之一，绝不出现未定义中间状态。

### 3.4 背压与资源

- 慢 reader、零 credit、backend stall；
- 队列满、连接满、磁盘满、文件描述符耗尽；
- 记录峰值 task、channel、heap、DB connections；
- 负载增长时资源不超过规格硬上限。

### 3.5 安全与隐私

- 日志/metric/audit snapshot 扫描敏感 canary；
- 越权、过期、撤销、重放、跨 audience token；
- malformed ciphertext/signature/cursor/proof；
- 外部可见错误不得成为用户/会话/token 枚举 oracle。

## 4. 测试基础设施 Port

```rust
pub trait ClockPort: Send + Sync {
    fn wall_now(&self) -> UnixMillis;
    fn monotonic_now(&self) -> MonotonicInstant;
    fn sleep_until<'a>(&'a self, at: MonotonicInstant)
        -> BoxFuture<'a, Result<(), Cancelled>>;
}

pub trait EntropyPort: Send + Sync {
    fn fill(&self, purpose: EntropyPurpose, out: &mut [u8])
        -> Result<(), EntropyError>;
}
```

生产密码模块必须使用安全 entropy；测试注入确定性 entropy 只允许 test build，并在类型/feature 上防止进入生产。

## 5. 网络模拟器

模拟链路至少支持：

- 延迟、抖动、带宽、MTU；
- 丢失、复制、乱序、损坏（损坏发生在认证层前）；
- 单向/双向分区、NAT mapping、地址变化；
- 半开、reset、服务进程重启；
- 虚拟时间快速推进 TTL/退避/租约。

端到端测试不能依赖真实 `sleep`，否则无法系统覆盖竞态。

## 6. Model-based 测试

至少维护以下小型参考模型：

- 身份 authorization chain 与 fork；
- 会话 control epoch reducer；
- Event DAG/heads/gaps；
- Delivery Job 单调状态机；
- Mailbox lease/ACK/TTL；
- Quota token bucket；
- Automation grant/proposal/execution。

随机命令同时输入参考模型与实现，逐步比较公开观察结果。

## 7. CI 层级

| 层级 | 触发 | 内容 | 时间目标 |
|---|---|---|---|
| PR-fast | 每 PR | lint、unit、Fake contracts、API snapshot、golden | ≤10 min |
| PR-full | 合并候选 | 全 adapter contracts、SQLite/QUIC、property | ≤30 min |
| Nightly | 每夜 | fuzz、Miri/loom 可用子集、kill matrix、长压测 | 1–4 h |
| Release | 发布 | 跨版本 interop、升级/降级、隐私日志、恢复演练 | 完整 |

## 8. 跨版本矩阵

至少测试：当前 writer↔当前 reader、前一 minor↔当前、前一 major migration reader。未知 major 明确失败；同 major minor 协商遵循 M00 声明。

## 9. 通过标准

- Fake 和真实实现公开行为一致；
- 失败可重复，test seed/trace 可保存；
- 无真实时间/网络依赖的非确定 flaky test；
- 所有写 API 覆盖 F0–F5；
- 所有 stream 覆盖慢消费者；
- 所有远程输入入口均有 fuzz target 和资源断言。

