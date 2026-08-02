# 自组织控制平面

## 1. 目标

控制平面负责回答：

- 当前有哪些匿名节点？
- 每个节点可承担什么角色？
- 哪些描述符新鲜且未回滚？
- 节点是否属于同一运营者、网络或攻击集群？
- 客户端如何获得足够一致但不由单点垄断的网络视图？
- 如何阻止攻击者用大量廉价身份占据路径？

控制平面不承载用户身份、联系人图、消息正文或完整路径选择结果。

## 2. 节点角色

| 角色 | 主要职责 | 稳定性要求 | 是否公开地址 |
|---|---|---:|---|
| Edge Client | 建路、发包、收包 | 可间歇在线 | 否 |
| Guard | 第一跳、稳定入口 | 高 | 是或通过 Bridge |
| Middle | Onion 中间转发 | 中 | 是 |
| Mix | 延迟、重排、cover loop | 中高 | 是 |
| Introduction | 保存匿名服务引介电路 | 高 | 是 |
| Rendezvous | 拼接双边匿名电路 | 中高 | 是 |
| Anonymous Mailbox | 保存固定/分档密文 cell | 高 | 是 |
| Bridge | 非公开入口和传输伪装 | 高 | 私下分发 |
| Directory Witness | 签署网络视图 Epoch | 高且独立 | 是 |

一个节点可以启用多个角色，但路径选择必须把同机、同密钥、同运营者和同网络族视为同一 family，不能在同一路径重复出现。

## 3. 匿名节点描述符

```rust
pub struct AnonymousNodeDescriptorV0 {
    pub anon_node_id: AnonNodeId,
    pub descriptor_sequence: u64,
    pub valid_from: UnixMillis,
    pub valid_until: UnixMillis,
    pub roles: BoundedVec<AnonymousRole, 16>,
    pub endpoints: BoundedVec<AnonymousEndpoint, 16>,
    pub protocol_versions: VersionRange,
    pub packet_classes: BoundedVec<PacketClass, 8>,
    pub capacity_class: CapacityClass,
    pub family_claims: BoundedVec<FamilyClaim, 16>,
    pub admission_proof: AdmissionProof,
    pub signature: SignatureBytes,
}
```

限制：

- 不包含 UserId、普通 NodeId、Relay 客户、会话或流量统计。
- endpoint 不内嵌 credential，不发布内网/历史地址。
- sequence 单调增加；相同 sequence 不同内容进入 equivocation quarantine。
- 角色和容量是声明，不是证明；需要本地观测和 Witness 交叉确认。
- descriptor 过期后不能继续用于新建路径，但已有电路可按安全策略 drain。

## 4. 目录 Epoch

早期推荐“分布式分发 + 多 Witness 视图”，而不是纯 DHT 真相：

```text
节点发布 descriptor
→ DHT/Gossip 广播
→ 独立 Witness 验证并形成 Epoch view
→ Witness 签名 view root
→ 客户端从多个来源取得 root/差异
→ 本地验证、合并并生成 AnonymousDirectoryView
```

```rust
pub struct DirectoryEpochViewV0 {
    pub epoch: u64,
    pub valid_from: UnixMillis,
    pub valid_until: UnixMillis,
    pub descriptor_root: DigestBytes,
    pub policy_digest: DigestBytes,
    pub previous_root: DigestBytes,
    pub witness_id: WitnessId,
    pub signature: SignatureBytes,
}
```

客户端只有在获得足够独立、相互一致的 Witness view 后才进入 `TrustedForPathSelection`。阈值是部署策略，不写死在 wire protocol；首期可采用多个独立运营者中的多数或显式用户信任集合。

## 5. Witness 的权限边界

Witness 可以：

- 验证描述符签名、版本、expiry、sequence 和 admission proof；
- 形成某 Epoch 观察到的节点集合 commitment；
- 发布角色政策和最低安全版本；
- 标记已证实的 equivocation 或密钥撤销。

Witness 不能：

- 知道某用户选了哪些节点；
- 为客户端决定完整路径；
- 看到会话、ServiceId 或 Mailbox token；
- 单独封禁全部用户或垄断 descriptor 分发；
- 把普通 NodeId 与 AnonNodeId 绑定后公开。

## 6. 路径选择

### Guard

- 从可信视图中选择少量稳定 Guard，并跨较长时间复用。
- Guard 更换由到期、长期不可达、密钥撤销或可信异常证据触发。
- 不能因为一次连接失败就在许多随机入口间快速轮换。
- Bridge Guard 与公开 Guard 使用不同发现和健康探测路径。

### Middle/Mix/Rendezvous

- 按角色、版本、容量和本地可用性筛选。
- 加权随机但不单纯追逐最高带宽，避免恶意高性能节点吸流量。
- 同一路径不重复 AnonNodeId、family、运营者、ASN 或过近网段。
- Rendezvous 由发起方随机选择，不由 Introduction 节点指定。
- 收件方入站路径和发送方路径独立选择。

### Path Bias

客户端记录不含远端身份关系的本地统计：

- 各 Guard 的建路尝试、完成、使用成功和异常关闭比例；
- 某 hop/descriptor 组合是否反复诱导重建；
- 是否只有包含特定候选的电路能成功；
- circuit 延迟或大小是否出现可疑标记。

检测到选择性失败时隔离候选并降低信任，而不是无限自动重试。

## 7. 抗 Sybil 与 Eclipse

必须组合多种弱信号，不能依赖单一评分：

- 节点身份创建和 descriptor 发布速率限制；
- 可验证资源成本或邀请/社区准入；
- 节点年龄、连续可用性和成功历史；
- 独立网络前缀、ASN、运营者和地理/司法辖区多样性；
- 多个 Witness 对同一节点的独立观察；
- DHT 邻居选择随机化和多源查询；
- 节点容量声明与外部 probe 的粗粒度一致性；
- 对突然出现的大型同质集群设置 probation。

任何 admission proof 都只是提高攻击成本，不证明节点善意。高带宽、PoW、抵押或社区签名均不能单独获得 Guard/Mix 信任。

## 8. 异构节点利用

| 设备 | 推荐贡献 | 不推荐 |
|---|---|---|
| 小型 VPS | Guard、Intro、Rendezvous、Mailbox、Witness、Bridge | 同时占据同一路径多个位置 |
| NAS/家庭服务器 | Middle、Mix、缓存、探测 | 在地址频繁变化时成为 Guard |
| 长期桌面 | opt-in Middle/Mix | 默认开启、未告知带宽/法律影响 |
| 临时桌面 | 客户端、短期探测 | Mailbox、Intro、Witness |
| 手机 | Edge Client、随机 poll | 公共中继和持续 cover relay |

弱服务器的价值是稳定地址和在线时间；普通节点的价值是扩大中间路径和运营者多样性。二者不是互相替代关系。

## 9. Bootstrap 与网络分区

- 内置多个独立 bootstrap/Witness 公钥，而不是唯一域名或服务器。
- 允许用户导入社区 bundle、离线二维码和自托管入口。
- bootstrap 只给出初始描述符/Witness 信息，不成为永久路由依赖。
- 网络分区期间维持旧的未过期可信 view；到期后停止新建强匿名路径。
- 不把“可以连到一个节点”误判为“网络视图可信”。

## 10. 隐私与观测

- Directory 查询本身优先经隔离匿名路径或使用可缓存 epoch bundle。
- probe 结果只保存在本地并使用粗粒度类别，不能形成全局用户行为数据库。
- 指标不以 AnonNodeId、CircuitId、ServiceId、Guard set 或 path 为 label。
- Witness 公布聚合网络容量和版本分布，不公布客户端查询日志。
- Bridge 描述符不进入公开 DHT/Witness 全量列表。

## 11. 控制面降级状态

```text
Empty
→ Bootstrapping
→ PartialView
→ TrustedForPathSelection
→ StaleButUsable
→ Untrusted / Expired
```

只有 `TrustedForPathSelection` 可选择新 Guard。`StaleButUsable` 仅允许在严格时间窗内使用已有 Guard/电路；`Untrusted/Expired` 必须停止匿名发送而非回退普通网络。

