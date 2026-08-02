# M01：Identity & Device

## 1. 功能与边界

负责长期用户身份、设备授权链、设备撤销、公开身份材料、邀请信任建立和恢复授权记录。

不负责：保存私钥字节、实现签名算法、网络发现、联系人 UI、会话成员权限、消息加密或推送 token。M13 先通过 M03/M14 获得公钥与签名证明，再把证明传给 M01；M01 不反向调用 M03，从而避免身份—密码运行时环。

## 2. 公开 DTO

```rust
pub struct PublicIdentity {
    pub user_id: UserId,
    pub root_verify_key: PublicKeyBytes,
    pub sequence: u64,
    pub active_devices: Vec<PublicDevice>,
    pub recovery_policy: RecoveryPolicySummary,
}

pub struct PublicDevice {
    pub device_id: DeviceId,
    pub verify_key: PublicKeyBytes,
    pub encryption_key: PublicKeyBytes,
    pub authorized_at_sequence: u64,
    pub revoked_at_sequence: Option<u64>,
    pub capabilities: DeviceCapabilities,
}

pub struct DeviceAuthorization {
    pub user_id: UserId,
    pub device: PublicDevice,
    pub previous_sequence: u64,
    pub new_sequence: u64,
    pub expires_at: UnixMillis,
    pub root_signature: SignatureBytes,
}
```

## 3. Port 签名

```rust
pub trait IdentityCommandPort: Send + Sync {
    fn create_identity<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: CreateIdentityRequest,
    ) -> BoxFuture<'a, Result<CreateIdentityResult, ContractError>>;

    fn authorize_device<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: AuthorizeDeviceRequest,
    ) -> BoxFuture<'a, Result<DeviceAuthorization, ContractError>>;

    fn revoke_device<'a>(
        &'a self,
        ctx: &'a RequestContext,
        user: UserId,
        device: DeviceId,
        expected_sequence: u64,
        proof: AuthorizationProof,
    ) -> BoxFuture<'a, Result<RevocationRecord, ContractError>>;

    fn import_identity_update<'a>(
        &'a self,
        ctx: &'a RequestContext,
        update: SignedIdentityUpdate,
    ) -> BoxFuture<'a, Result<ImportIdentityOutcome, ContractError>>;

    fn create_invitation<'a>(
        &'a self,
        ctx: &'a RequestContext,
        request: InvitationRequest,
    ) -> BoxFuture<'a, Result<InvitationPackage, ContractError>>;

    fn accept_invitation<'a>(
        &'a self,
        ctx: &'a RequestContext,
        package: InvitationPackage,
        verification: OutOfBandVerification,
    ) -> BoxFuture<'a, Result<ContactTrustRecord, ContractError>>;
}

pub trait IdentityQueryPort: Send + Sync {
    fn get_public_identity<'a>(
        &'a self,
        ctx: &'a RequestContext,
        user: UserId,
        at_sequence: Option<u64>,
    ) -> BoxFuture<'a, Result<PublicIdentity, ContractError>>;

    fn resolve_device<'a>(
        &'a self,
        ctx: &'a RequestContext,
        user: UserId,
        device: DeviceId,
        at_sequence: u64,
    ) -> BoxFuture<'a, Result<DeviceTrustDecision, ContractError>>;

    fn export_public_bundle<'a>(
        &'a self,
        ctx: &'a RequestContext,
        user: UserId,
    ) -> BoxFuture<'a, Result<SignedIdentityBundle, ContractError>>;
}
```

## 4. 不变量与限制

- `UserId` 从根验证材料按 M00 规则派生；生成后不可变。
- 每次授权/撤销严格递增 `sequence`，调用方提供 `expected_sequence`；不匹配返回 `Conflict`。
- 一个 `DeviceId` 只属于一个 `UserId`，被撤销后不能重新激活；重新加入生成新 ID。
- 撤销只影响指定 sequence 之后的信任判断，不改写历史事件有效性。
- 邀请包默认 10 分钟有效、单次使用，最大 8 KiB；不包含私钥或通讯录明文。
- 一个身份默认最多 32 个未撤销设备；恢复凭据默认最多 8 份。
- 所有导入更新先验证根签名、previous hash、sequence、有效期和算法策略。

## 5. 并发与事务

以 `UserId` 为单写者分片。授权、撤销和恢复更新在一个身份事务中提交，同时写入 outbox。重复 `operation_id` 返回原结果；同一 sequence 的不同更新进入 `IdentityForkDetected` 隔离状态，不能“最后写入胜出”。

## 6. Integration Events

- `IdentityCreatedV0`
- `DeviceAuthorizedV0`
- `DeviceRevokedV0`
- `IdentityForkDetectedV0`
- `ContactTrustChangedV0`

事件只含公开材料或引用；不得含恢复秘密、平台 keystore alias 或邀请随机秘密。

## 7. ACL

- `signature_verifier_adapter`：把公开签名证明交给 M00 的受限验证 Port；不接触私钥。需要生成密钥/签名的用例由 M13 在 M01 外编排 M03/M14。
- `conversation_adapter`：把 `PrincipalId` 与身份 sequence 转为 M02 的成员事实。
- `sync_adapter`：将 signed identity bundle 作为版本化公开对象同步。

## 8. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| ID-001 | 重复 create operation | 返回同一 UserId，不生成第二身份 |
| ID-002 | 两个 authorize 使用同一 expected sequence | 一个成功，一个 `Conflict` |
| ID-003 | 导入跳跃/回退 sequence | 拒绝，不修改当前状态 |
| ID-004 | 已撤销设备验证未来事件 | `Revoked` |
| ID-005 | 撤销前历史事件 | 仍按当时 sequence 验证 |
| ID-006 | 同 sequence 不同合法签名更新 | 进入 fork quarantine 并发事件 |
| ID-007 | 邀请重放/过期 | `Forbidden`/`InvalidArgument`，无联系人记录 |
| ID-008 | 崩溃发生在状态提交后 outbox 前 | 原子恢复后事件仍可发布 |
| ID-009 | 32 设备边界 | 第 33 个返回 `QuotaExceeded` |
| ID-010 | 日志捕获 | 不出现邀请秘密、恢复材料、KeyRef 内部值 |

属性测试：任意有效授权链重放得到相同快照；打乱链顺序只会暂存缺口，不产生错误当前状态。

## 9. 验收

内存实现与持久化实现通过同一 conformance suite；设备撤销后的新消息不可由被撤销设备建立有效会话；身份 fork 不会被静默合并。
