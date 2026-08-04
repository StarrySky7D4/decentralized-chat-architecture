# M11：Discovery & Node Selection

## 1. 功能与边界

聚合静态配置、Bootstrap、peer exchange、后续 DHT 中的签名 NodeDescriptor；验证新鲜度与能力；维护本地健康/信誉；按用途返回多样化候选节点。

不负责用户发现、联系人图、会话成员、Transport 拨号、长期投递重试或把节点信誉当作密码学信任。

## 2. Port 签名

```rust
pub trait DiscoveryPort: Send + Sync {
    fn ingest_descriptor<'a>(
        &'a self,
        ctx: &'a RequestContext,
        source: DescriptorSource,
        descriptor: NodeDescriptorV0,
    ) -> BoxFuture<'a, Result<DescriptorOutcome, ContractError>>;

    fn query<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: NodeQuery,
    ) -> BoxFuture<'a, Result<Vec<NodeCandidate>, ContractError>>;

    fn report_observation<'a>(
        &'a self,
        ctx: &'a RequestContext,
        observation: NodeObservation,
    ) -> BoxFuture<'a, Result<(), ContractError>>;

    fn publish_local_descriptor<'a>(
        &'a self,
        ctx: &'a RequestContext,
        descriptor: SignedLocalDescriptor,
    ) -> BoxFuture<'a, Result<PublishSummary, ContractError>>;

    fn bootstrap<'a>(
        &'a self,
        ctx: &'a RequestContext,
        sources: Vec<BootstrapSource>,
    ) -> BoxFuture<'a, Result<BootstrapSummary, ContractError>>;
}
```

`NodeQuery` 只包含角色、协议、地域/网络多样性偏好、容量门槛和排除集合，不包含 ConversationId、联系人或消息类型。

## 3. 候选与评分

```rust
pub struct NodeCandidate {
    pub node_id: NodeId,
    pub role: NodeRoleDescriptor,
    pub endpoints: Vec<EndpointDescriptor>,
    pub descriptor_sequence: u64,
    pub valid_until: UnixMillis,
    pub health: HealthClass,
    pub confidence: ConfidenceClass,
    pub diversity_bucket: DiversityBucket,
}
```

不得公开精确内部信誉分，避免上层把暂时观测误当身份信任。选择至少考虑来源多样性、NodeId、网络前缀/运营者（若可用）、失败相关性和 descriptor 新鲜度。

## 4. 限制与抗攻击

- 每 descriptor 最大 64 KiB、32 roles、32 endpoints；先验签再加入可用集合。
- 旧 sequence 不覆盖新 descriptor；同 sequence 不同内容进入 equivocation quarantine。
- 自声明能力不是可用证明；需要主动 probe 或成功历史提升 confidence。
- DHT/peer exchange 输入按 source/NodeId/字节有预算，缓存有 TTL/LRU。
- Bootstrap 列表至少支持多个独立来源；默认节点关闭不应阻止使用自定义节点。
- selection 使用带上限随机化，避免所有客户端同时选择单一最高分节点。

## 5. 并发

以 NodeId 串行更新 descriptor；probe worker 有全局和每 endpoint 并发上限。query 使用 immutable snapshot，不等待 probe；report observation 通过有界队列合并，安全关键 equivocation 不可丢弃。

## 6. ACL

- `transport_probe_adapter`：M08 受限握手结果 → 本地 NodeObservation。
- `delivery_adapter`：候选摘要 → M07 RouteCandidate。
- `runtime_adapter`：M15 角色配置 → signed local descriptor；私钥仍由 M03 签名 Port 持有。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| ND-001 | descriptor 签名/过期/回滚 | 正确接受或拒绝 |
| ND-002 | 同 sequence equivocation | quarantine，不随机覆盖 |
| ND-003 | 10k 虚假节点洪泛 | 缓存/worker/带宽有界 |
| ND-004 | 单运营者声明许多 NodeId | 多样性选择不会全选同 bucket |
| ND-005 | 默认 bootstrap 全离线 | 静态自定义来源仍可工作 |
| ND-006 | query 并发 probe | 快照一致、不阻塞 |
| ND-007 | endpoint 携带 credentials/超长 | 拒绝 |
| ND-008 | 健康反馈抖动 | 有衰减/滞回，不频繁切换 |
| ND-009 | 隐私测试 | query/日志无会话/联系人信息 |
| ND-010 | static 与 DHT adapter conformance | 候选语义一致 |

## 8. 验收

在恶意 descriptor、Sybil 候选和默认节点失效时仍返回有界、多样且可验证候选；NodeId 不被当作 UserId 或 TransportPeerId。
