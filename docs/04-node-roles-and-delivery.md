# 节点角色与消息投递

## 节点等级

### Light Node

主要是手机：

- 收发自己的消息
- 保存本地历史
- 验证签名和密文
- 使用 Relay/Mailbox
- 不承担长期公共服务

### Full Node

主要是桌面、NAS、家庭服务器：

- Light Node 全部能力
- 局域网发现
- 可选中继
- 为自己的设备保存消息
- 自动化任务
- 加密附件缓存

### Service Node

主要是 VPS、社区服务器、组织节点：

- Bootstrap
- Relay
- Mailbox
- Directory
- Blob
- Federation
- Push Bridge
- SFU

每种角色均可独立启用。

### Seed Node

只帮助新节点发现网络，不保存聊天正文，不拥有用户账户。

## 多路径投递

```text
1. 局域网直连
2. 公网 QUIC 直连
3. NAT 打洞
4. Relay 转发
5. Mailbox 离线暂存
6. 后续联邦节点交换
```

上层只依赖统一接口：

```rust
trait DeliveryRoute {
    async fn deliver(
        &self,
        target: DeliveryTarget,
        envelope: OpaqueEnvelope,
    ) -> DeliveryOutcome;
}
```

## 单对单消息流程

```text
A 创建、签名并加密事件
  → 写入本地 Event Store
  → 尝试直接连接 B
  → 失败则通过 Relay
  → B 离线则写入其 Mailbox
  → Mailbox 返回持久化回执
  → Push Bridge 可发送无内容唤醒
  → B 上线后拉取密文
  → B 验签、解密、去重、投影
  → 发送接收回执
```

## Mailbox 信封

```rust
struct OpaqueEnvelope {
    routing_token: [u8; 32],
    envelope_id: [u8; 32],
    ciphertext: Vec<u8>,
    expires_at: u64,
    sender_proof: Vec<u8>,
}
```

Mailbox 不应知道：

- 用户名
- 房间名称
- 消息类型
- 消息正文
- 群组成员列表

## Gossip 的边界

适合：

- 公共频道
- 网络公告
- 内容可用性传播
- 公共社区缓存

不适合作为唯一方案：

- 私聊可靠送达
- 离线消息
- 严格群组成员状态
- 敏感订阅关系

推荐分工：

```text
单对单：Direct + Relay + Mailbox
小群组：成员复制 + Mailbox
大型私有群：加密 PubSub + Mailbox 补偿
公共频道：Gossip + 内容缓存节点
```
