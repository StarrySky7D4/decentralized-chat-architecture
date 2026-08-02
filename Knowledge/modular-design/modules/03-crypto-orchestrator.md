# M03：Crypto Orchestrator

## 1. 功能与边界

编排成熟密码库完成设备签名、单聊会话建立、payload 加解密、密钥 Epoch 转换、sender proof 和加密附件密钥封装。

不负责自创密码算法、用户/会话权限、网络传输、明文持久化、密钥恢复 UI。内部 ratchet/MLS 对象和私钥字节不得越过 Port。

## 2. 公开 DTO

```rust
pub struct KeyRef(pub OpaqueHandle);
pub struct CryptoSessionRef(pub OpaqueHandle);

pub struct SealRequest {
    pub conversation: ConversationId,
    pub actor: PrincipalId,
    pub device: DeviceId,
    pub policy_epoch: u64,
    pub plaintext: SecretBytes,
    pub associated_data: EventAssociatedData,
}

pub struct SealedPayload {
    pub crypto_epoch: u64,
    pub algorithm: AlgorithmId,
    pub ciphertext: BoundedBytes<1_048_576>,
    pub recipient_binding: RecipientBinding,
}

pub struct OpenedPayload {
    pub bytes: SecretBytes,
    pub sender: VerifiedSender,
    pub crypto_epoch: u64,
    pub replay: ReplayStatus,
}
```

`SecretBytes` 禁止 `Clone/Debug/Serialize`，drop 时清零；只能在受控函数中借用。

## 3. Port 签名

```rust
pub trait CryptoPort: Send + Sync {
    fn create_device_keys<'a>(
        &'a self,
        ctx: &'a RequestContext,
        policy: KeyCreationPolicy,
    ) -> BoxFuture<'a, Result<PublicDeviceKeyBundle, ContractError>>;

    fn sign<'a>(
        &'a self,
        ctx: &'a RequestContext,
        key: KeyRef,
        domain: SignatureDomain,
        canonical_bytes: BoundedBytes<1_048_576>,
    ) -> BoxFuture<'a, Result<SignatureBytes, ContractError>>;

    fn verify<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: VerifyRequest,
    ) -> BoxFuture<'a, Result<VerificationDecision, ContractError>>;

    fn bootstrap_direct_session<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: DirectSessionBootstrap,
    ) -> BoxFuture<'a, Result<CryptoSessionSummary, ContractError>>;

    fn seal<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: SealRequest,
    ) -> BoxFuture<'a, Result<SealedPayload, ContractError>>;

    fn open<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: OpenRequest,
    ) -> BoxFuture<'a, Result<OpenedPayload, ContractError>>;

    fn advance_epoch<'a>(
        &'a self,
        ctx: &'a RequestContext,
        transition: AuthorizedEpochTransition,
    ) -> BoxFuture<'a, Result<CryptoEpochSummary, ContractError>>;

    fn wrap_blob_key<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: WrapBlobKeyRequest,
    ) -> BoxFuture<'a, Result<WrappedBlobKeySet, ContractError>>;
}
```

## 4. 不变量与限制

- 只使用经过维护、审计和版本锁定的协议实现；原语选择另立 ADR。
- 所有签名强制 domain separation；调用方不能传任意字符串 domain。
- associated data 至少绑定协议版本、ConversationId、EventId 输入字段、actor/device、事件类型、policy/control epoch。
- 单次明文最大 768 KiB，为信封/协议开销留预算；附件走 M12 流式加密。
- 解密先做结构、算法、epoch、发送者设备与重放检查，再返回明文。
- 不允许从错误或耗时区分“未知用户、坏签名、坏密文”的远程可观察细节。
- 密钥状态写入加密存储；事务提交后才能报告 seal/open 状态推进成功。
- Direct ratchet 操作以 session 为单写者；不得并发推进同一发送链。

## 5. 崩溃与并发语义

发送使用“预留消息号 → 加密 → 原子提交新状态与结果缓存”。相同 `operation_id` 重试返回相同 ciphertext，不能重复推进 ratchet。接收保留有界 skipped-key window；超过窗口返回 `IntegrityFailure` 并触发受控重新同步，不无限缓存。

## 6. Integration Events

- `CryptoSessionEstablishedV0`
- `CryptoEpochAdvancedV0`
- `CryptoSessionNeedsRepairV0`
- `KeyMaterialRotatedV0`

任何事件都不能包含私钥、明文、chain key、skipped message key 或平台 keystore alias。

## 7. ACL

- `identity_adapter` 验证设备公开材料与撤销 sequence。
- `conversation_adapter` 将授权 EpochTransition 转为密码库成员变化。
- `platform_keystore_adapter` 把 `KeyRef` 映射到 OS keystore；映射只存在于 infra。

## 8. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| CR-001 | 标准协议官方测试向量 | 逐字节一致 |
| CR-002 | 修改任一 associated-data 字段 | 解密/验签失败 |
| CR-003 | 同 operation 重试 seal | ciphertext 相同，ratchet 仅推进一次 |
| CR-004 | 乱序在窗口内 | 均可解密且重放第二次被标记 |
| CR-005 | 超窗口/海量序号跳跃 | 有界失败，无失控内存 |
| CR-006 | 撤销设备后的 session bootstrap | 拒绝 |
| CR-007 | epoch 并发推进 | 仅期望前序成功；另一请求 `StaleEpoch` |
| CR-008 | crash 在密文生成后状态提交前 | 重启不复用 nonce/消息号 |
| CR-009 | 日志/Debug/serde | SecretBytes 与 KeyRef 内部不可泄漏 |
| CR-010 | fuzz 坏密文 | 不 panic；错误分类稳定；资源有界 |

必须增加 side-channel 基线、内存清零检查（能力范围内）以及依赖版本安全审计；这些检查失败时禁止发布密码模块。

## 9. 验收

所有协议 conformance vectors 通过；私钥与内部会话状态不出模块；崩溃和重试不会导致 nonce/key 重用；Relay/Mailbox 测试只能看到 opaque bytes。

