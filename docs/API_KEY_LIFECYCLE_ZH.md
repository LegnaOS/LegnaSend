# 远程 API 密钥生命周期

[English](API_KEY_LIFECYCLE.md)

## 权限

接口前缀为 `/api/legnasend/v1/integration`。本页全部接口要求调用密钥已启用、未到期，明确持有 `keys.manage` 权限和 `*` 工作区授权。旧密钥不会自动获得新权限；匿名访问、工作区密码及仅某个工作区的授权均不授予密钥管理能力。

只列出和管理权限范围不超过调用者的密钥。创建权限与工作区授权均须是调用者的子集；创建或恢复的目标密钥不能比有限期调用者活得更久。禁止调用者暂停、恢复或撤销自身；不开放修改权限和导入任意验证值。远程操作与本地设置编辑共用同一串行持久化所有者，不会用旧快照覆盖并发本地编辑。

## 接口

| 方法 | 路径 | 结果 |
|---|---|---|
| GET | `/keys` | `{version, keys}`，仅元数据 |
| POST | `/keys/create` | 首次成功返回 201、持久回执及一次性秘密 |
| POST | `/keys/{keyId}/manage` | 暂停、恢复或撤销，返回回执 |
| GET | `/keys/requests/{requestId}` | 查询当前调用者自己的持久回执和应用状态 |

`version` 是保存的密钥元数据与回执集合的 64 位小写十六进制版本摘要，应当作不透明值使用。元数据包含 `id`、`name`、`grant`、`createdAt`、可空 `expiresAt`、`enabled`、可空 `limits`，不含验证值或秘密。

### 创建

先读取 `/keys` 的版本，再为本次意图生成新的 UUID 请求 ID：

```json
{
  "version": "KEYS_VERSION",
  "requestId": "REQUEST_ID",
  "name": "自动化读取端",
  "grant": {"scopes": ["service.read", "files.read"], "workspaces": ["WORKSPACE_ID"]},
  "expiresAt": null
}
```

五个字段均必填。`expiresAt` 使用 Unix 秒，不是毫秒；null 表示不过期，仅无到期时间的调用者可这样创建。名称非空，最多 256 个 UTF-8 字节。总密钥数最多 128。未知字段、磁盘路径和用户传入的秘密均拒绝。

首次成功返回：

```json
{
  "receipt": {
    "principal": "CALLER_KEY_ID", "requestId": "REQUEST_ID",
    "digest": "REQUEST_DIGEST", "action": "create",
    "keyId": "NEW_KEY_ID", "createdAt": 1790000000
  },
  "applied": true,
  "secretAvailable": true,
  "secret": "ONE_TIME_SECRET"
}
```

`applied` 表示当前监听器已确认保存配置，不表示完成文件传输。只有持久化、运行配置确认及调用者最后有效性核验通过后才取出秘密。秘密不进入应用设置和请求记录。应用测试台使用独立遮蔽模态框及显式复制按钮；关闭后清空页面秘密控制器，普通结果区域只保留回执。

### 暂停、恢复和撤销

向 `/keys/KEY_ID/manage` 发送：

```json
{"version":"KEYS_VERSION","requestId":"REQUEST_ID","action":"pause"}
```

`action` 为 `pause`、`resume` 或 `revoke`。暂停保留验证值但停止认证，恢复重新启用原密钥，撤销移除密钥。运行配置确认后，暂停和撤销沿用现有运行中撤权机制。目标不得是当前调用密钥。

## 重放和未知结果

密钥变更和回执存入同一设置值。重放必须保留**原请求 ID、完整原正文（包含旧版本）和原目标密钥 ID**。拿新版本搭配旧请求 ID 属于改变正文，返回 `409 request_id_conflict`。

- 同调用者、同请求 ID、同正文：仅返回原回执和 `secretAvailable:false`，不再创建或重复变更，也不重发秘密。
- 同 ID 不同正文：`409 request_id_conflict`。
- 新意图使用旧版本：`409 keys_changed`。
- 已保存但运行配置尚未确认：回执中 `applied:false`，不返回秘密；查询回执或重放原请求可继续核对发布。
- 超时、中断或存储写入回执丢失：使用原调用密钥查询 `/keys/requests/REQUEST_ID`。写入可能已落盘但确认失败时，先回读并核对保存回执，再接收后续意图；读不出则阻断，不猜成功。
- 首次秘密丢失后不能找回。通过回执取得目标 ID，撤销旧密钥，再用新请求 ID 和新版本创建替代密钥。

回执跨应用重启保留，不含明文秘密和验证值。上限为 256 条，**不会自动淘汰旧回执**：达到上限后新远程变更返回 `409 receipt_capacity`；查询元数据、查询回执、本地密钥管理仍可用。本批没有回执修剪功能。显式完整重置 API 配置会同时移除密钥与回执，不是自动保留期策略。

## 私密保存响应示例

`LEGNASEND_API_BASE` 包含接口前缀，调用令牌由调用程序自己的秘密存储提供。创建响应写入独占私密文件，不打印至日志：

```python
import json, os, urllib.request
base = os.environ['LEGNASEND_API_BASE']
headers = {'Authorization': 'Bearer ' + os.environ['LEGNASEND_API_TOKEN'],
           'Content-Type': 'application/json'}
body = {'version': 'KEYS_VERSION', 'requestId': 'REQUEST_ID', 'name': 'Reader',
        'grant': {'scopes': ['service.read'], 'workspaces': ['*']}, 'expiresAt': None}
request = urllib.request.Request(base + '/keys/create',
    data=json.dumps(body).encode(), headers=headers, method='POST')
with urllib.request.urlopen(request, timeout=40) as response:
    payload = response.read(262144)
fd = os.open('key-response.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as target:
    target.write(payload)
```

启用 HTTPS 时使用当前监听器的可信证书配置。秘密不作为 URL 参数、日志字段或共享示例令牌。

## 稳定错误

| 错误码 | 含义 |
|---|---|
| `global_key_required`、`insufficient_scope` | 缺少专用权限或全局授权 |
| `grant_escalation` | 权限或有效期超过调用者 |
| `self_management_forbidden` | 目标是当前调用密钥 |
| `keys_changed` | 新操作前重新读取密钥版本 |
| `request_id_conflict` | 核对时应保留完整原正文 |
| `receipt_not_found` | 当前调用者没有可见的对应持久回执 |
| `receipt_capacity` | 回执已满，未自动丢弃旧回执 |
| `key_not_found`、`key_expired` | 目标不可用或不支持恢复 |
| `operation_expired`、`keys_authority_changed` | 接受点或调用者有效性变化 |
| `key_operation_failed`、`keys_unavailable` | 持久化或运行状态需要核对 |

## 验证边界

专项覆盖真实 Rust HTTP 权限和响应白名单、串行持久化与重启重放、已写入但确认丢失，以及实际原生 HTTP → 子隔离 → 应用所有者 → 私有文件 → 运行配置确认。页面覆盖英文和三种中文地区。宿主检查不替代 Android／iOS 秘密存储、后台和物理设备验收。

本批验证：Flutter 持久化、模型和页面组合专项 40/40（含密钥持久化 10 项、四地区页面 4 项）；原生完整链路 1/1；Flutter 静态分析无问题。Rust 权限专项结果单独记录在验证证据中。
