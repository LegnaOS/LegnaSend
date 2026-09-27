# 接收缓存保留期 API

本文扩展[集成 API 设置契约](INTEGRATION_API_ZH.md#设置响应与修改)。所有示例使用现有监听的实际地址，以及 `/api/legnasend/v1/integration` 前缀。须先启用 API。调用密钥须明确拥有 `settings.read`、`settings.write` 和全局工作区授权 `*`，匿名访问不会获得这些权限；只读客户端仅需 `settings.read` 和 `*`。

## 值与作用范围

`POST /settings/update` 每次修改一个字段：

```json
{"version":"VERSION_FROM_READ","field":"receiveCacheRetentionDays","value":7}
```

`value` 必须是 **−1 至 3650** 的 JSON 整数。`-1` 表示保留已登记原生接收残留直至明确手动清理；`0` 允许立即自动清理；正整数表示保留天数。原生设置界面提供 −1、0、1、7、30 五档，API 还接受范围内其他整数。字符串 `"7"`、布尔值 `true`、浮点 JSON 写法 `7.0`、`null` 及越界值均被拒绝，不做类型转换。

此设置作用于意外退出后已登记、不可续传的原生接收暂存；普通取消和不可续传失败仍清理事务缓存。已协商的持久续传记录单独采用一天绝对租约，网络失败可保留已确认块，不由本设置延长。启动和API清理保留有效租约，本地明确手动清理可提前回收非活动自有缓存；活动、成品及身份不符内容仍受保护。汇总原因`durable_resume`表示检查了持久记录，`durable_resume_failed`表示其存储检查失败，不等于成功释放空间。详情见[持久续传](NATIVE_DURABLE_RESUME_ZH.md)。工作区上传、私有工作区导出副本和 Android 文档提供器事务分别管理。保留缓存不会为原始 LocalSend 协议增加分片续传能力。

修改只保存并同步策略，**不会执行清理**、绕过年龄、停止传输或重启监听。API `POST /cache/cleanup` 仍须 `cache.clean` 权限并遵守保留期。只有本地接收缓存管理对话框经过单独确认后才忽略年龄，身份、缓存头和活动写入保护始终保留。到期表示下一次维护时具备清理资格，不是精确时刻触发的删除计时器。

## 分别读取已保存与实际生效状态

`GET /settings` 及成功修改返回版本化设置快照，并必须包含顶层 `receiveCacheRetention` 对象。示例节选：

```json
{
  "version": "64_HEX_DIGEST_FROM_THE_HOST",
  "settings": {"receiveCacheRetentionDays": 7},
  "pendingRestart": [],
  "receiveCacheRetention": {
    "effectiveDays": 7,
    "automaticCleanupPaused": false,
    "busy": false,
    "error": null
  }
}
```

示例省略无关设置。`settings.receiveCacheRetentionDays` 是已保存的整数偏好，不代表原生配置必定成功。

| 运行状态字段 | 类型与含义 |
| --- | --- |
| `effectiveDays` | −1…3650 的整数；实际原生策略尚未确认时为 `null` |
| `automaticCleanupPaused` | 布尔值；当前是否暂停自动原生缓存清理 |
| `busy` | 布尔值；策略设置操作是否进行中 |
| `error` | `null`、`invalid`、`save`、`apply` 或 `restore` |

`invalid` 表示已保存偏好损坏，`save` 表示持久化失败，`apply` 表示同步失败，`restore` 表示偏好恢复失败。宿主在失败后尽可能查询实际原生策略，因此 `effectiveDays` 可能与已保存值不同。应读取全部字段，不能仅凭错误非空或偏好值判断自动清理是否暂停；实际原生策略未知或偏好恢复不确定时保持暂停。

`automaticCleanupPaused` 是同步安全开关，**不是保留模式**。手动保留成功应用后可以返回 `effectiveDays: -1` 与 `automaticCleanupPaused: false`：自动维护仍可运行，但手动保留策略使原生残留保留，不会绕过年龄或活动写入者检查。策略未知（`effectiveDays: null`）及修改进行中（`busy: true`）会暂停安全开关；`save`／`apply` 失败后若旧策略已核对一致，可能保留诊断但不暂停。

## 乐观并发与结果处理

1. 先读取 `GET /settings`，保留完整 `version`。
2. 核对已保存和实际生效状态，再准备一次修改。
3. 使用该版本提交一次请求，等待持久化和原生策略确认。
4. 遇到 `409 settings_changed`，重新读取并判断原意图是否仍成立，不直接替换版本后盲目重发。
5. 遇到 `409 settings_busy`，等待已有操作结束再读取状态，不自动排队修改。
6. 遇到 `503 host_operation_failed`，读取实际状态；持久化恢复或原生同步可能失败，错误不证明完全没有发生改变。
7. 网络异常、宿主超时或 `outcome_unknown` 后先查询状态，不自动重放修改。

版本包含已保存设置、待重启状态和**完整保留期运行快照**。它是内容摘要，不是单调递增历史版本；临时的 `busy` 或错误变化也可能使旧版本失效，相同快照可能产生相同版本。此类操作没有请求 ID 去重。应用内 API 测试台验证整数输入，每次写入均经页内确认，并用响应 JSON 展示实际状态诊断；支持四种界面语言。

## cURL

需要 `curl` 与 `jq`。`BASE` 使用实际监听地址；密钥通过进程环境传入，不放入 URL。HTTPS 应配置受信任的设备证书，不关闭证书验证。

```sh
BASE='http://HOST:PORT/api/legnasend/v1/integration'
DAYS=7
SNAPSHOT=$(curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $LEGNASEND_API_TOKEN" "$BASE/settings")
VERSION=$(printf '%s' "$SNAPSHOT" | jq -er '.version')
BODY=$(jq -nc --arg version "$VERSION" --argjson days "$DAYS" \
  'if ($days|type)=="number" and ($days|floor)==$days and $days>=-1 and $days<=3650
   then {version:$version,field:"receiveCacheRetentionDays",value:$days}
   else error("Expected integer -1..3650") end')
curl --include --request POST \
  -H "Authorization: Bearer $LEGNASEND_API_TOKEN" -H 'Content-Type: application/json' \
  --data-binary "$BODY" "$BASE/settings/update"
# 失败或结果不明确后读取状态，不自动重复 POST。
curl --fail-with-body -H "Authorization: Bearer $LEGNASEND_API_TOKEN" "$BASE/settings"
```

使用新版本进行负例测试时，把 JSON 值替换为 `true` 或 `"7"`，接口应返回 400，不视为整数。有效示例不要用 `--arg days` 构造字符串。jq 会把整数数值输出为整数 JSON；最终以线上的 JSON 类型而非客户端语言数值表示决定是否接受。

## JavaScript

浏览器仍遵循已配置的 CORS 与 TLS 规则。`token` 来自明确的秘密输入，不嵌入 URL 或提交到源码。

```javascript
const base = 'http://HOST:PORT/api/legnasend/v1/integration';
const headers = {Authorization: `Bearer ${token}`};
async function readSettings() {
  const response = await fetch(`${base}/settings`, {headers, credentials: 'omit'});
  if (!response.ok) throw new Error(`Read failed: ${response.status}`);
  return response.json();
}
async function setRetention(days) {
  // 不使用 Number(days)，避免把 true 或数值字符串悄悄转换。
  if (!Number.isInteger(days) || days < -1 || days > 3650) {
    throw new TypeError('Expected integer -1..3650');
  }
  const snapshot = await readSettings();
  const response = await fetch(`${base}/settings/update`, {
    method: 'POST', credentials: 'omit',
    headers: {...headers, 'Content-Type': 'application/json'},
    body: JSON.stringify({version: snapshot.version, field: 'receiveCacheRetentionDays', value: days})
  });
  console.log(response.status, await response.json());
  if (!response.ok) console.log('Current state:', await readSettings());
  // 调用者在网络失败后读取状态，不重复 POST。
}
await setRetention(7);
// setRetention(true) 与 setRetention('7') 在本地拒绝。
```

## Python

Python 的 `bool` 是 `int` 子类，应使用 `type(days) is int`，而不是只用 `isinstance(days, int)`。

```python
import json, os, urllib.request, urllib.error

BASE = 'http://HOST:PORT/api/legnasend/v1/integration'
HEADERS = {'Authorization': 'Bearer ' + os.environ['LEGNASEND_API_TOKEN']}

def call(method, route, payload=None):
    data = None if payload is None else json.dumps(payload).encode('utf-8')
    headers = {**HEADERS, **({'Content-Type': 'application/json'} if data is not None else {})}
    request = urllib.request.Request(BASE + route, data=data, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=40)
    except urllib.error.HTTPError as response_error:
        response = response_error
    with response:
        return response.status, json.loads(response.read(262144))

def set_retention(days):
    if type(days) is not int or not -1 <= days <= 3650:
        raise TypeError('Expected integer -1..3650')
    status, snapshot = call('GET', '/settings')
    if status != 200:
        raise RuntimeError(('Read failed', status, snapshot))
    result = call('POST', '/settings/update', {
        'version': snapshot['version'], 'field': 'receiveCacheRetentionDays', 'value': days})
    print(result)
    if result[0] != 200:
        print('Current state:', call('GET', '/settings'))
    # 网络异常继续上抛；重新决定操作前先读取当前状态。

set_retention(-1)
# set_retention(True)、set_retention('7')、set_retention(7.0) 在本地拒绝。
```

HTTPS 可用 `ssl.create_default_context(cafile='DEVICE_CA.pem')` 创建受信任设备 CA 上下文并传给 `urlopen`；监听要求客户端证书时再提供相应证书。原始传输协议、证书身份验证和文件格式不变。
