# M17：Backup & Recovery

## 1. 功能与边界

创建加密、可验证、版本化的本地备份集；列出/验证/恢复事件事实、模块配置和可恢复密钥材料；以 staging + 原子切换完成灾难恢复。

不把 Relay/Mailbox 当备份，不默认备份可重建投影，不导出平台不可导出的私钥，不承担社交恢复共识。

## 2. DTO 与 Port

```rust
pub struct BackupManifestV0 {
    pub backup_set: BackupSetId,
    pub format: BackupFormatVersion,
    pub created_at: UnixMillis,
    pub modules: Vec<ModuleBackupEntry>,
    pub previous: Option<BackupSetId>,
    pub ciphertext_digest: DigestBytes,
    pub recovery_policy: RecoveryPolicySummary,
}

pub trait BackupPort: Send + Sync {
    fn create<'a>(
        &'a self, ctx: &'a RequestContext, request: CreateBackupRequest,
    ) -> BoxFuture<'a, Result<BackupSetView, ContractError>>;

    fn list<'a>(
        &'a self, ctx: &'a RequestContext, source: BackupSource,
    ) -> BoxFuture<'a, Result<Vec<BackupSetView>, ContractError>>;

    fn verify<'a>(
        &'a self, ctx: &'a RequestContext, request: VerifyBackupRequest,
    ) -> BoxFuture<'a, Result<BackupVerificationReport, ContractError>>;

    fn plan_restore<'a>(
        &'a self, ctx: &'a RequestContext, request: PlanRestoreRequest,
    ) -> BoxFuture<'a, Result<RestorePlan, ContractError>>;

    fn restore<'a>(
        &'a self, ctx: &'a RequestContext, plan: ApprovedRestorePlan,
    ) -> BoxFuture<'a, Result<RestoreSummary, ContractError>>;

    fn export_recovery_package<'a>(
        &'a self, ctx: &'a RequestContext, request: RecoveryExportRequest,
    ) -> BoxFuture<'a, Result<RecoveryPackageRef, ContractError>>;
}
```

## 3. 备份内容

必需：M01 身份授权链、M02 控制事实、M04 Event Store、M07 未完成 Job（可按新策略重建）、节点偏好和 schema 版本。

条件性：M03 可导出且经过恢复密钥二次封装的状态；M12 本地 ciphertext cache；M18 授权历史。

默认排除：M05 投影/搜索、临时 session/stream、Relay circuit、Mailbox 租约、日志、指标、push token、OS 文件句柄。

## 4. 安全与恢复语义

- 备份先压缩后认证加密；manifest 本身除最小格式头外也加密。
- 恢复秘密通过用户密码 KDF、硬件 key 或多份 recovery credential 包装；参数写入版本化头。
- `verify` 在隔离临时目录中做完整 hash/AEAD/schema/引用检查，不修改当前状态。
- `restore` 先恢复 staging，各模块运行 migration/conformance/integrity checks，再原子切换 profile。
- 现有 profile 不被覆盖；旧状态保留为可回滚快照，直到用户确认。
- 恢复后的设备默认是新 DeviceId，必须走设备授权；不得克隆已撤销设备身份。

## 5. 并发与限制

- 备份读取各模块声明的 snapshot token；不要求跨模块数据库事务，但 manifest 记录每模块一致性点。
- 单次只允许一个 create/restore；create 可与聊天并发，restore 要求 profile quiesce。
- 流式 I/O，内存窗口默认 8 MiB；取消留下不可见临时数据并可清理。
- 格式 reader 至少支持当前与前两个 major migration path；未知新格式 fail closed。

## 6. ACL

每模块实现自己的 `ModuleSnapshotPort` 导出版本化 opaque segment 和校验报告；M17 不能查询其私有表。M03/M14 adapter 只做 wrap/unwrap operation，不返回原始硬件私钥。

## 7. 测试

| 测试 | 场景 | 期望 |
|---|---|---|
| BK-001 | 备份期间持续收发 | 每模块 snapshot 自洽，manifest 可验证 |
| BK-002 | 任意 segment/manifest 位翻转 | verify 失败且不修改当前状态 |
| BK-003 | create/restore 各 kill point | 临时可清理；原 profile 可启动 |
| BK-004 | 错恢复秘密/参数篡改 | 统一安全失败，无 oracle 细节 |
| BK-005 | 从旧格式迁移 | 明确报告并通过事实哈希校验 |
| BK-006 | 恢复被撤销设备 | 不激活旧设备，要求新授权 |
| BK-007 | 投影不备份 | 恢复后可从事实重建 |
| BK-008 | 100GiB 模拟流 | 内存保持窗口上限 |
| BK-009 | cancel/磁盘满 | 无假成功、无当前状态覆盖 |
| BK-010 | 日志检查 | 无恢复秘密、文件内容或密钥材料 |

## 8. 验收

一份备份可在干净设备验证并恢复完整事实；损坏/错误凭据不会改变当前 profile；恢复不复制被撤销设备的有效身份。
