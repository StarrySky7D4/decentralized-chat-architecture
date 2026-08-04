# ADR-0007：控制分叉的显式恢复

- 状态：Accepted
- 日期：2026-08-04

## 背景

控制事件改变成员、角色、复制和密码策略，不能像普通内容事件那样自然合并。只定义 fork quarantine 而没有恢复协议，会让合法的并发管理永久停摆；按到达时间、wall clock、最高 epoch 或 EventId 选择则允许网络调度替代授权决策。

## 决策

### 检测与冻结

同一控制 head 出现多个合法子事件时，所有竞争分支及后继隔离，有效状态回退到最后无歧义的 `base_head/base_epoch`。不得保留先到分支为临时赢家。base 或更早快照上的合法内容可继续处理，依赖分叉 epoch 的内容暂停。

证据包包含 base、按 EventId 排序的 branch roots/tips、完整控制链 canonical bytes 与签名、策略验证结果、涉及的 crypto epoch/commitment。解析事件携带内容寻址的 `ControlForkEvidenceCommitment`（digest、元素数量、分块/Merkle 参数）；验证者从 Event Store 取回并校验完整 manifest，因此分支数量不受信封 parents 上限约束。

### 发起与授权

base snapshot 中拥有 `ResolveControlFork` capability 的 principal 可发起。生效必须满足同一 base snapshot 的 `fork_resolution_policy`；审批按不同 `UserId` 计数，每份由当时有效设备签署同一 canonical decision digest。竞争分支新增的管理员或撤销不能改变解析资格。

默认策略由会话创建时显式固化：Direct 要求双方 UserId；Group 使用已配置且满足 `2 * threshold > eligible_approver_count` 的管理员批准阈值，使任意两个合法 quorum 必有交集。实现不得在 fork 发生后临时降低阈值。

### 解析事件

`ControlForkResolutionV0` 绑定 base、证据 commitment、解析轮次、审批、新 control/crypto epoch 和以下 action 之一：

- `SelectBranch { selected_root, selected_head }`：采用完整验证的闭合选中路径状态；
- `RollBackToBase`：废弃 base 之后所有竞争分支。

resolution 的唯一语义 parent 是 selected head，回退时则是 base；`next_control_epoch = parent.control_epoch + 1`。选择时，base 的全部后继中只有 base 到 selected head 的闭合祖先路径被采用；其余现有/未来事件（包括 selected head 的迟到旧后继）永久 rejected。回退时拒绝 base 的全部旧后继。事实与证据仍保留，新控制 head 是 resolution 本身，后续普通控制事件必须引用它。

### 密码状态

V0 对每次控制 fork 强制 rekey，因为分支期间可能已向不同成员集合分发 key material。`next_crypto_epoch` 必须大于 base 和所有证据分支的 crypto epoch，resolution 绑定 M03 的 `rekey_commitment`，新密钥只发给解析后的成员集合。在 rekey durable commit 前禁止从新控制 head 发送内容；被拒分支的 key/commitment 不并入新 epoch。控制 epoch 与 crypto epoch 保持独立编号，不假定相等。

### 幂等与冲突解析

`resolution_round = hash("dchat/control-fork-resolution/v0", conversation_id, base_head)`。它不因迟到 root 改变，避免同一 base 出现多个可并行批准的 round。同 round、同 decision digest 重放是 no-op，审批按 UserId 去重。若两个不同 decision 各自满足阈值，quorum 交集证明至少一名共同审批者发生 equivocation 或其设备已失陷。V0 不使用时间、epoch 或 EventId 选取，也不允许在同一 `ConversationId` 发起未定义的“下一轮”；会话进入终止性 `CompromisedControlState`，导出证据后只能通过独立认证的带外流程创建新会话并重新验证成员。

迟到的新 root 或旧 selected head 后继默认被“所选闭合路径之外的 base 后继均 rejected”覆盖；若新证据证明 base 或已采用路径无效，则隔离旧 resolution，回退到更早无歧义祖先，并由该祖先导出新的 round。

## 被否决方案

- **LWW/最早到达/最小 EventId：** 网络位置可影响权限历史，且不会证明成员同意。
- **永远 quarantine：** 安全但不可用，合法并发会永久冻结会话。
- **按任一分支当前管理员审批：** 攻击者可先在自己的分支授予解析权。
- **选中分支后沿用其 crypto epoch：** rejected 分支可能已泄露或分发不一致密钥。
- **删除 rejected 事件：** 破坏审计、同步诊断与重复到达的确定拒绝。

## 后果

优点：恢复由最后共同授权状态决定；所有节点可从相同证据确定收敛；迟到分支不会复活；分叉后的成员集合与密码状态重新绑定。

代价：分叉期间部分内容暂停；需要多方审批与新密钥分发；两个相互冲突且均获 quorum 的 resolution 会终止当前会话，成员必须带外建立新会话；证据和 tombstone 必须长期保存或可验证压缩。

## 验证

- 对所有 branch 到达排列，检测后均冻结在同一 base。
- 覆盖选择、回退、授权不足、分支授予权限、迟到 root/descendant 和未知关键事件。
- 以超过 32 个 sibling roots 验证分块 commitment；缺块、重复元素、错误计数和 Merkle/digest 篡改必须 fail closed。
- resolution 在写入 head、rejected tombstone、crypto gate 的每个崩溃点恢复后要么全部可见、要么全部不可见。
- 同 resolution 重放无副作用；不同有效 resolution 进入终止性受损状态，不发生 LWW，也不能在同一会话继续解析。
- rekey 前发送必失败；新 epoch 不向 rejected 成员分发；随机重建得到相同 snapshot hash。
