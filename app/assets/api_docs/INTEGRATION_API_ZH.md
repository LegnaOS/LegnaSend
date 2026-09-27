# LegnaSend 集成 API

[English](INTEGRATION_API.md)

## 当前实现


前缀为 `/api/legnasend/v1/integration`，沿用既有监听器的**实际端口**；与浏览器 Cookie API `/api/legnasend/v1/workspaces`、原始 `/api/localsend/v2` 分开。API 策略和预算不限制后两者，原握手、证书身份校验和文件字节不变。

新配置默认使用 HTTP，HTTPS 传输开关默认关闭；明确保存过的选择继续保留。接收、网页共享、工作区与 API 共用实际监听协议，切换经确认后统一生效。对端设备的 HTTP／HTTPS 标签表示对端协议，不是本机开关。

API 默认禁用、默认要求鉴权。启用它**不改变 TLS 客户端证书策略**：未处于网页共享模式的 TLS 监听仍要求客户端证书；既有网页模式沿用原行为。需要配置设备证书信任；Bearer 密钥既不提供 TLS 信任，也不把 HTTP 变为 HTTPS。

## 原生管理流程

1. 从桌面侧栏或移动导航打开 **API**。接收监听尚未运行时使用“启动接收服务”，不另开隐藏端口。
2. 启用 API，默认保持“要求 API 密钥”；确需匿名时再确认独立匿名开放范围。禁用 API 不停止原生传送或网页工作区。
3. 生成命名密钥，选择动作与指定工作区，或显式授权全部现有／未来工作区；到期可选 30 天、90 天或不过期。显式授权包含所选隐藏／密码工作区，独立于浏览器密码。
4. 在页内模态复制一次明文。复制是明确操作，复制失败仍保留文本，关闭不自动复制；只持久保存摘要与元数据。明文丢失后撤销并重新生成，不从设置或诊断恢复。
5. 在可滚动模态同时编辑三组配额及规范跨域来源，匿名动作／工作区单独配置，匿名不含审计或上传权限。0 表示该配置维度不限额，独立资源硬上限仍生效；单个密钥可覆盖共用密钥配额；监听未启动时核心也先校验，再写偏好存储。
6. 使用接口标签对应的真实地址；本地／隧道标记不代表已经绕过 VPN。状态是带观察时间的服务回执快照，“刷新状态”不重写未变化策略。
7. 保存意图和已确认运行状态分开。禁用／撤销失败时旧策略可能仍生效，页面保留提示并提供重试；监听换代丢弃迟到回执，重新连接先读取实际 revision。离开页面和密钥改名都不重启传送。
8. 配置版本不支持／损坏时保留原文，直到重试读取或确认重置。重置移除 API 密钥并恢复默认禁用，不删除工作区或源文件。


从 API 页的“开发文档”可离线阅读本指南和目录接口契约、切换英文／简体，以及查看和复制完整 OpenAPI 快照；繁体地区的手册语言明确显示为简体，四地区 OpenAPI 保留各自翻译。静态快照不冒充当前服务策略，请以 `/capabilities` 和在线 `/openapi.json` 为准。

## 已实现操作

下表均为相对于前缀的路径。编号、字段和错误码不随语言改变。

| 方法 | 路径 | 所需权限 | 参数 |
|---|---|---|---|
| GET | `/status` | `service.read` | 无 |
| GET | `/capabilities` | `service.read` | 无 |
| GET | `/workspaces` | `workspaces.read` | 无 |
| GET | `/workspaces/{workspaceId}` | `workspaces.read` | 工作区 UUID |
| GET | `/workspaces/{workspaceId}/files` | `files.read` | 必须 `generation`；可选 `path`、`cursor` |
| GET、HEAD | `/workspaces/{workspaceId}/files/{fileId}/content` | `files.read` | 必须 `generation`；可选 `preview`、`version`；请求头 `Range`、`If-Match` |
| POST | `/workspaces/{workspaceId}/upload` | `files.upload`（仅密钥） | 必须 `generation`、`path`、准确 Content-Length 与原始正文；可选 `directory=true` |
| GET | `/managed-workspaces` | `workspaces.manage`（仅密钥） | 包括范围内已关闭配置 |
| POST | `/workspaces/{workspaceId}/manage` | `workspaces.manage`（仅密钥） | 必须 `generation`、`action`；更新字段在查询中，来源／密码使用 JSON 正文 |
| GET | `/approved-workspace-sources` | `workspaces.manage`，工作区 `*` | 本机已批准来源描述，不返回路径 |
| POST | `/managed-workspaces/create` | `workspaces.manage`，工作区 `*` | JSON `sourceId`、`name`、`slug`；可选 `visible`、`allowUpload` |
| GET | `/requests` | `requests.read` | `after` 默认 0；`limit` 为 1–100，默认 50 |
| GET | `/devices` | `devices.read` | 无 |
| GET | `/devices/{deviceId}` | `devices.read` | 已确认设备 UUID |
| POST | `/devices/scan` | `devices.scan` | 空正文 |
| GET | `/send-selection` | `transfers.read` | 无 |
| POST | `/transfers/send` | `transfers.send` | JSON：deviceId、selectionVersion、requestId；可选 channelId |
| GET | `/transfers` | `transfers.read` | 无 |
| GET | `/transfers/{transferId}` | `transfers.read` | 自有任务 UUID |
| POST | `/transfers/{transferId}/cancel` | `transfers.control` | 空正文 |
| POST | `/transfers/{transferId}/retry` | `transfers.control + transfers.send` | JSON：requestId |
| POST | `/transfers/{transferId}/remove` | `transfers.control` | 空正文 |
| GET | `/openapi.json` | `service.read` | `lang` 为 `en`、`zh-CN`、`zh-TW`、`zh-HK`，默认 `en` |

能力列表列出十五个 GET 操作及八个 POST 操作，HEAD 另在 OpenAPI 描述。OPTIONS 是受策略约束的跨域预检，不算额外业务能力。不支持的方法返回 405；未知、重复或过长查询参数返回 400，不在 URL 传递凭据。

工作区描述不包含本地目录根路径。密钥授权过滤列表和单资源访问；未分配、已关闭或不存在的工作区返回 404。`generation` 取自当前工作区描述，旧代次返回 409。文件 ID 来自清单，是不透明的 URL 安全编号，不是任意原生文件系统路径；`path` 是工作区内相对目录，详细路径／游标语义见[目录契约](DIRECTORY_API_ZH.md)。

每页最多 100 项、扫描最多 512 个候选；即使页面无可见条目，只要游标非空仍应继续。游标 120 秒过期。复用根目录约束、后代符号链接拒绝和受管 `.ls` 排除；来源变化时重新获取描述与清单，不带旧代次盲目续传。

HEAD 描述原文件，GET 支持单字节范围和后缀范围。先读取 ETag，后续请求携带 `If-Match`。ETag 是元数据／版本校验值，**不是完整文件的密码学摘要**。`preview=1` 沿用媒体／位图 MIME 白名单，下载仍返回原字节。`version` 为不能附加 `If-Match` 的原生媒体请求提供既有编码版本绑定，细节见目录契约。

## 宿主配置与密钥生命周期

仅应用内部开放的配置接口：

```rust
use localsend::http::server::integration::{ApiConfig, Scope, WorkspaceGrant, create_key};

let created = create_key(
    "Automation".into(),
    WorkspaceGrant {
        scopes: vec![Scope::Service, Scope::Workspaces, Scope::Files],
        workspaces: vec![workspace_id], // 指定工作区 UUID；["*"] 为全部。
    },
    None, // 可指定未来的 Unix 秒级到期时间。
)?;
let config = ApiConfig {
    revision: 1, // 同一运行服务的每次更新必须递增。
    enabled: true,
    keys: vec![created.record],
    ..ApiConfig::default()
};
server.configure_integration_api(&serde_json::to_string(&config)?).await?;
// 宿主只在本地界面展示一次 created.secret，不记录或导出明文。
let snapshot = server.integration_api_snapshot(); // 仅元数据，没有校验摘要。
```

`create_key` 使用 32 字节随机秘密，返回 `ls1.<UUID>.<secret>` 令牌。保存记录仅含 SHA-256 校验摘要、名称、动作／工作区授权、创建时间和可选到期时间；摘要采用恒定时间比较。快照不恢复明文，持久化和一次展示由宿主负责。以上是嵌入调用接口；原生设置页现已沿正常服务隔离链路使用同一套核心校验和策略。

密钥可重复调用直至撤销或到期；“只显示一次”不等于只能请求一次。删除记录并应用更高 revision 即撤销。更改权限／摘要／到期会取消该密钥旧响应，改显示名称则保留配额和响应；其他密钥及原生传送不受影响。禁用集成 API 取消其全部响应生产者；更改跨域策略也取消此前已准入的集成响应。已交给传输层的字节不具备撤回能力。

### 暂停、恢复与单密钥预算

本机 API 页可暂停／恢复密钥，不展示或重新生成明文。持久元数据增加 `enabled`（旧记录默认 `true`）和 `limits`（默认 `null`，表示继承）。有效但暂停的密钥返回 **403 `key_paused`**，不降级匿名。暂停取消该密钥旧的活动响应；恢复允许同一令牌发起新请求，不复活已中断正文。已被宿主接手的持久变更继续遵循下文结果不确定规则。

只改名称或单密钥配额时，保留响应和已用额度。相同校验摘要下暂停／恢复、改权限或到期时间也保留固定窗口计数，不借变更重新获得突发额度。取消单密钥覆盖后恢复共用预算。这些是本机持久策略管理，不是新增远程密钥管理端点。

配置完整校验后才替换：JSON 最大 512 KiB、最多 128 密钥、每个授权最多 256 个唯一工作区编号、最多 16 个规范 HTTP(S) 来源。通配符必须独占工作区列表。未知字段、重复密钥编号、非法值及旧 revision 不部分应用，配置错误不回显秘密。

## 匿名与跨域

`authRequired=false` 时，独立匿名授权仅覆盖**可见且未受密码保护的工作区**。显式密钥可访问明确授予的隐藏／密码工作区，这是独立于浏览器解锁 Cookie 的授权。匿名不能获得 `requests.read`、`files.upload` 或 `workspaces.manage`。携带错误、过期或撤销密钥时返回 401，不降级匿名。

凭据使用 `Authorization: Bearer TOKEN`，浏览器 Cookie 不是 API 凭据。接受同源及显式名单内的规范来源；跨域需有效预检。不反射任意来源、不启用携带 Cookie 的跨域模式。预检允许 `Authorization`、`Range`、`If-Match`、`Accept`、`Content-Type`；预检无需 Bearer，但消耗匿名／全局预算。无 Origin 的命令行仍受鉴权和限流约束。来源名单不是防火墙，也不是 VPN 路由选择。

## 速率与并发语义

| 预算 | 默认每秒请求 | 默认每分钟请求 | 默认活动响应 |
|---|---:|---:|---:|
| 全局 | 30 | 600 | 16 |
| 每个密钥 | 10 | 300 | 4 |
| 每个匿名来源 | 5 | 60 | 2 |

一秒和 60 秒**固定窗口**同时执行，锚定服务启动的单调时间。不是滑动窗口，相邻窗口边界可能形成突发。全局和调用者准入原子执行；允许每秒 0–1,000、每分钟 0–60,000、活动响应 0–64。**0 表示这个配置维度不限额**，不代表服务没有边界：全局仍有独立的 64 个活动响应硬上限，超出返回 `429` 和 `server.concurrent`。密钥 `limits:null` 继承共用 `keyLimits`；非空 `{perSecond,perMinute,concurrent}` 覆盖该密钥的全部三项，仍受全局预算限制。调低限值作用于后续准入，不重置已用额度，不终止已经准入的响应。

已准入请求计一次，包括最后返回 400／401／403 的请求；每个范围／预检单独计数，不按块计数。已被拒绝的 429 不再消耗请求额度。匿名依据真实 socket 对端，不信任 `X-Forwarded-For`；最多保留 256 个近期／活动匿名来源，满额返回 429，不靠淘汰近期条目重置配额。

429 携带秒级 `Retry-After` 和稳定原因，如 `global.minute`、`key.concurrent`、`anonymous.capacity`。能读取预算时，`X-LegnaSend-Remaining-Second`、`X-LegnaSend-Remaining-Minute` 返回全局／调用者剩余值中较小者；同一维度的全局和调用者限值都为 0 时，剩余头使用数值标记 `4294967295`；只有一方有限额则返回有限一方的剩余值。这是快照，不是未来请求的预约。并发指活动处理／响应生产者，不是 TCP 连接数或接收确认。独立取消观察任务在密钥撤销／到期或来源关闭时释放停止读取的生产者。当前没有带宽限速。

## 错误与请求记录

```json
{"error":{"code":"rate_limited","requestId":"REQUEST_UUID","reason":"key.minute"}}
```

常见错误：`api_disabled`／`not_found`（404）、`unauthorized`／`revoked`／`expired`（401）、`insufficient_scope`／`origin_denied`（403）、`invalid_query`（400）、`method_not_allowed`（405）、`source_changed`（409／412）、`source_gone`（410）、`range_unsatisfiable`（416）、`rate_limited`／`storage_busy`（429）。文件中断时响应头可能已发出；把截断当作失败，重新核验来源后才重试已授权的缺失范围。HEAD 错误无响应体，范围 416 保留原 `Content-Range` 行为。

`/requests` 只保留最近 200 条已完成／被拒记录。`instanceId` 区分服务生命周期，重启会重置序号／历史。使用 `after`、`next`、`oldest`、`latest` 检测缺口，不当作永久完整审计；当前请求完成后才进入历史。记录仅含操作代号、方法类别、密钥编号或 null、状态、结束原因、稳定错误／原因、耗时和生产字节。不保存原 URL／查询、鉴权头、密钥／摘要、本地路径、文件名或内容。字节计数不是远端收妥确认，拒绝／HEAD 体可能记录 0。

### 脱敏 JSON／CSV 导出

API 接口浏览与测试页可使用具有 `requests.read` 的凭据，通过用户保存流程导出 JSON 或 CSV。导出读取真实监听器的有界历史，以首页 `instanceId`、`latest` 固定截止点，最多三页／200 条，不追逐导出请求自己生成的新记录。监听器切换使本次采集失败；发现缺口／淘汰时标记 `incomplete`。这只是有界历史快照，不是持久审计归档。

仅导出固定白名单：`sequence`、`timestamp`、`requestId`、`operation`、`method`、`principal`、`status`、`outcome`、`error`、`reason`、`bytes`、`elapsedMs`。JSON 另含 `format: "legnasend-api-history"`、`version: 1`、`instanceId`、`throughSequence`、`incomplete`、`entries`；CSV 使用固定表头、UTF-8 BOM 与 `incomplete` 列。校验拒绝异常编号／代码／数值，未知响应字段不复制。两种格式都不包含令牌、校验摘要、URL、本机路径、文件名、内容、来源定位值或密码，也不延长服务的 200 条保留范围。

## 调用示例

在调用环境设置实际地址、证书信任和新生成秘密；不把真实密钥写入共享命令历史或 URL。以下仅用占位值。

### cURL

```sh
BASE='http://HOST:PORT/api/legnasend/v1/integration'
TOKEN='TOKEN'
curl -H "Authorization: Bearer $TOKEN" "$BASE/status"
curl -H "Authorization: Bearer $TOKEN" "$BASE/workspaces"
curl -G -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'path=RELATIVE_DIRECTORY' \
  "$BASE/workspaces/WORKSPACE_UUID/files"
URL="$BASE/workspaces/WORKSPACE_UUID/files/FILE_ID/content?generation=GENERATION"
curl -I -H "Authorization: Bearer $TOKEN" "$URL"
curl -H "Authorization: Bearer $TOKEN" \
  -H 'If-Match: "ETAG_FROM_HEAD"' -H 'Range: bytes=0-65535' "$URL" -o PART.bin
```

显式开启 HTTPS 后，把 BASE 改为实际 https 地址，并在上述 cURL 请求添加 `--cacert DEVICE_CA.pem`。要求客户端证书的监听另加成对的 `--cert CLIENT_CERT.pem --key CLIENT_KEY.pem`。按真实协议使用地址，HTTP 不加密传输。

### JavaScript：逐页清单

```javascript
async function listFiles(base, token, workspaceId, generation, directory = "") {
  let cursor = null;
  do {
    const query = new URLSearchParams({ generation: String(generation), path: directory });
    if (cursor) query.set("cursor", cursor);
    const response = await fetch(`${base}/workspaces/${encodeURIComponent(workspaceId)}/files?${query}`, {
      headers: { Authorization: `Bearer ${token}` },
      credentials: "omit",
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}; retry=${response.headers.get("Retry-After")}`);
    const page = await response.json();
    consumePage(page.entries); // 应用提供有界处理，不无限累积 DOM 行。
    cursor = page.cursor;
  } while (cursor);
}
```

浏览器需要设备证书信任，跨域还需来源名单；桌面 HTTP 回环测试不等于手机已满足这些条件。

### Python：流式原字节下载

```python
import os
import urllib.request
import ssl

base = "http://HOST:PORT/api/legnasend/v1/integration"
url = base + "/workspaces/WORKSPACE_UUID/files/FILE_ID/content?generation=GENERATION"
headers = {"Authorization": "Bearer " + os.environ["LEGNASEND_API_TOKEN"]}
context = ssl.create_default_context(cafile="DEVICE_CA.pem") if base.startswith("https://") else None
# context.load_cert_chain("CLIENT_CERT.pem", "CLIENT_KEY.pem")  # 监听要求 mTLS 时添加。
with urllib.request.urlopen(urllib.request.Request(url, headers=headers, method="HEAD"), context=context) as head:
    headers["If-Match"] = head.headers["ETag"]
    expected = int(head.headers["Content-Length"])
written = 0
with urllib.request.urlopen(urllib.request.Request(url, headers=headers), context=context) as response:
    with open("OUTPUT.bin", "xb") as target:
        while chunk := response.read(65536):
            target.write(chunk)
            written += len(chunk)
if written != expected:
    raise IOError("Incomplete response; revalidate before continuing")
```

这个最小示例新建输出文件，不是 `.ls` 任务管理器或自动重试器。调用方需处理自己的中断文件生命周期，不静默覆盖已有文件。

## 契约与验证

服务从操作表生成 [OpenAPI 3.1.0](https://spec.openapis.org/oas/v3.1.0)。已导出[英文](integration-openapi-en.json)、[简体](integration-openapi-zh-CN.json)、[繁体](integration-openapi-zh-TW.json)、[香港](integration-openapi-zh-HK.json)快照。这些测试快照为要求鉴权模式；实时文档仅对当前匿名获准权限加入匿名方案。429 参考 [RFC 6585](https://www.rfc-editor.org/rfc/rfc6585.html#section-4)，自定义剩余额度头按上文定义。

真实 HTTP 脚本校验四份契约、成功／错误响应模型、原字节哈希、HEAD／Range、匿名过滤、撤销和命名空间隔离。核心另测原子并发、TLS 策略、旧配置及阻塞响应。已配置 Linux／Windows CI，尚未宣称远程运行；完整控制接口与移动物理验收继续。

## 推荐接入顺序与恢复策略

1. 在应用 API 页启用服务、授予最小需要的动作／工作区并生成密钥，复制实际 `http://` 或 `https://` 地址。生产客户端从环境或凭据存储读取密钥，不硬编码进网页文件。
2. 先读 `/status`，检查 `enabled`、`authRequired`、`port`、`https` 与 `scopes`；再读 `/capabilities`，只调用当前 `operations` 中的能力。
3. 取 `/workspaces`，用返回的 `id` 和 `generation` 获取分页清单；相对 `path`、`cursor` 交给 URL 编码器，不手工拼接目录中的空格、中文或 `&`。目录项进入下一层，文件项的 `id` 用于内容路由。
4. HEAD 取得大小与完整 ETag，GET 使用 `If-Match` 和需要的单范围。206 校验 `Content-Range` 与实际字节数；200 是完整响应，不可直接追加到部分文件。416 重新核验长度，空文件单独完成。
5. 网络失败保留已经核验的完整片段；重连后重新读取工作区代次和 HEAD。409／410／412 表示来源或权限上下文变化，停止旧任务并重新列举；不要把新源字节拼到旧缓存。
6. 401 停止自动重试并更新凭据，403 检查权限／跨域；404 检查 API 开关和授权范围，不据此推断隐藏资源是否存在。400／405 修正调用参数或方法。429 遵守 `Retry-After` 并有界退避，不开启无限并发。
7. 有审计权限的客户端读取 `/requests?after=...&limit=...`，按 `instanceId` 区分服务重启，处理环形历史缺口。生产字节数不等同接收落盘成功；调用方自行校验和提交文件。

明确密钥授权上传已实现，既有工作区管理亦已接通，其他远程控制继续开发；目录网页 Cookie、PIN 与 API Bearer 不能混用。API 文档页面不自动启用接口、不生成密钥，也不发起测试请求。


## 应用内接口检索与填参测试台

打开 **API → API 接口浏览与测试**，从内置英文／简体／繁体契约查找已实现的 GET、内容 HEAD 和需确认的上传／工作区管理 POST 操作。可按服务／工作区／文件／记录分类，搜索路径或名称，查看参数、响应／错误模型及 cURL／JavaScript／Python 示例；其他应用语言明确英文回退。打开页面不会自动发送请求。

1. 先在 API 管理页单独启用并配置接口。将密钥粘贴到遮挡字段；留空可测试已经配置的匿名策略。测试台不生成密钥，不绕过权限范围。
2. 选择操作，填写必需的路径和查询参数；发送前校验数值边界和枚举。先调用工作区，再取文件清单中的真实 ID 和 generation。重置只恢复参数默认值，不更改服务设置。
3. 点击执行请求。原生执行器只访问当前监听器的 `127.0.0.1`、实际端口和协议，不使用应用 HTTP 代理；HTTPS 固定本监听器证书并提交既有本机客户端证书，不放松远程身份核验。该调用证明本机服务链路，不代表跨网／VPN 可达或浏览器跨域验收。
4. 查看真实 HTTP 状态、耗时、字节计数、选定响应头和正文；401／403／429 是服务实际返回，不伪造成功。选择请求记录接口，用 after／limit 分页读取有界脱敏记录。
5. 内容 GET 默认请求 `Range: bytes=0-4095`，可显式设置 Range／If-Match；仅展示最多 4 KiB 十六进制样本，不作为完整下载器。其他正文最多 256 KiB，超过时显示截断提示。HEAD 只显示响应头。完整文件或更大契约交给正式 API 客户端处理。

每个监听器最多一个测试请求，读取外层十二秒截止，上传使用下文按大小计算的预算，不自动重试。关闭页面释放凭据与输入状态并忽略迟到回执；停止监听器取消请求。密钥不持久化、不进入复制示例，示例仅使用 TOKEN／环境变量。主动复制响应会复制服务数据，分享时自行检查内容。所有正常鉴权、配额和脱敏记录仍然生效。

生成示例使用本机回环地址；其他设备调用应替换为 API 管理页中的实际网卡地址。HTTPS 需要设备 CA；当监听器要求双向 TLS 时，还需单独配置客户端证书／私钥，浏览器示例另遵循跨域名单。下文文件上传、空目录创建及工作区新建／配置／密码操作已接通；任务／缓存控制及远程密钥管理继续开发。

## 密钥授权文件与目录上传

给密钥明确勾选 **files.upload** 并限定工作区。已有读取权限、匿名模式（包括关闭鉴权）、浏览器 Cookie 和网页 `allowUpload` 开关都不自动授予 API 写入。被明确授权的密钥可向指定隐藏／密码工作区写入，即使网页保持只读；工作区仍须实际发布、代次有效。匿名配置拒绝写权限，错误密钥不降级为匿名。

`POST /api/legnasend/v1/integration/workspaces/{workspaceId}/upload?generation=N&path=RELATIVE_PATH`

- 请求头为 `Authorization: Bearer TOKEN`、`Content-Type: application/octet-stream`、准确 `Content-Length`；正文为原文件。无须浏览器专用标记或密码 Cookie。
- `directory=true` 加显式零长度正文创建空目录；按需创建父目录。同名正式路径返回 409，不覆盖、不追加、不删除远端路径，也不声明上传断点续传。
- 明确 EOF、长度核验及发布后才返回 **201**，JSON 包含 `path`、`size`、`sha256`、`directory`。摘要描述服务端收到的内容，调用者仍可与源摘要比较。
- 路径限制在工作区内，拒绝绝对路径、上级跳转、子路径链接及内部缓存名；工作区关闭／根目录／代次变化中止未提交操作。
- 同时执行既有全局／密钥秒、分和活动响应配额；共享写入器另限每工作区两路、全局八路、64 KiB 有界块。请求处理器取消后，工作线程清理结束前仍持有 API 配额，不提前释放而放大实际并发。
- 发布提交门内再次检查密钥撤销／到期和 API 关闭，撤销与提交串行。撤销确认之后旧请求不会再提交；此前已保存的文件保留。记录继续隐藏凭据、本地路径、名称和内容；原有字节计数仍表示响应字节，不伪称上传进度。
- 此 POST 按配置来源名单允许跨域预检；管理 POST 路由另行执行管理授权，OPTIONS 不授予写权限。原版 LocalSend 端点及浏览器配额不变。

错误沿用结构化信封：400 参数，401 密钥缺失／错误／撤销／过期，403 写权限／工作区范围，404 工作区或 API 不可用，409 旧代次／同名，411 缺长度，415 内容类型，429 配额／活动数，500 存储。接收端提前拒绝大流式正文时，客户端可能先得到传输失败而读不到 HTTP 状态；不能仅凭已发送字节当作完成。

```sh
# curl 流式读取源文件并提供长度，不把完整文件放进 JSON。
curl --request POST --upload-file FILE_PATH \
  -H 'Authorization: Bearer TOKEN' -H 'Content-Type: application/octet-stream' \
  'http://HOST:PORT/api/legnasend/v1/integration/workspaces/WORKSPACE_ID/upload?generation=GENERATION&path=folder%2Ffile.bin'
```

```javascript
// selectedFile 来自用户选择；长度由浏览器设置。
const response = await fetch('http://HOST:PORT/api/legnasend/v1/integration/workspaces/WORKSPACE_ID/upload?generation=GENERATION&path=file.bin', {
  method: 'POST', credentials: 'omit',
  headers: {Authorization: 'Bearer TOKEN', 'Content-Type': 'application/octet-stream'},
  body: selectedFile,
});
if (response.status !== 201) throw new Error(`Upload failed: ${response.status}`);
const receipt = await response.json();
```

```python
import os
import requests
with open('FILE_PATH', 'rb') as source:
    response = requests.post(
        'http://HOST:PORT/api/legnasend/v1/integration/workspaces/WORKSPACE_ID/upload',
        params={'generation': 'GENERATION', 'path': 'folder/file.bin'},
        headers={'Authorization': 'Bearer TOKEN', 'Content-Type': 'application/octet-stream',
                 'Content-Length': str(os.fstat(source.fileno()).st_size)},
        data=source, timeout=(10, 3600))
    response.raise_for_status()
    receipt = response.json()
```

### 应用内上传测试

进入 **API → 请求测试台**，选择 `uploadFile`，填写工作区、代次及相对路径，粘贴密钥并选择文件或空目录；写入前在页内模态确认目标。示例只使用占位符，不包含粘贴密钥或用户本地源路径。实际请求走当前监听器回环地址，HTTPS 固定本机证书并沿用原客户端身份，不接收任意外部地址，不走代理。

选择器仅传元数据；Android 内容 URI 在工作线程打开后，把唯一拥有的读描述符交给 Rust，URI／描述符不进入 HTTP 或记录。服务器被替换后的迟到打开先关闭，不执行请求。普通路径须为普通文件，顺序描述符须提供已知长度。每测试台只执行一项，响应预览有界；上传预算为 `min(21600, 60 + ceil(bytes/1048576))` 秒，读取继续使用 12 秒截止。关闭页面不伪报正在执行的请求已经取消或完成；提供器阻塞读取可能要等底层返回才能结束，物理提供器继续验收。

设备发现及自有发送任务控制已接通；无关原生收发任务／缓存及远程密钥／设置控制继续开发。登记上传暂存的强杀补清理见[目录契约](DIRECTORY_API_ZH.md#登记上传暂存补清理)；Android／Apple 外部工作区根目录适配继续单列。

## 工作区持久管理

明确授予密钥 **workspaces.manage** 和目标工作区范围；通配符 `*` 必须主动选择。已有读取／上传权限以及匿名访问不自动获得管理能力。管理列表包括已关闭和失效的配置，与普通已发布工作区列表不同，不返回原生路径、平台授权引用或密码摘要。需要运行客户端宿主事件处理器；只有核心服务而无宿主时返回 `503 host_unavailable`，不伪造持久化。

| 方法 | 路径 | 参数 |
| --- | --- | --- |
| GET | `/managed-workspaces` | 无查询参数；返回密钥范围内的 `{workspaces:[...]}` |
| POST | `/workspaces/{workspaceId}/manage` | 必须 `generation`、`action`；除来源／密码 JSON 外正文为空 |
| GET | `/approved-workspace-sources` | 无查询参数，通配符管理授权；返回 `{sources:[{id,name,kind}]}` |
| POST | `/managed-workspaces/create` | 通配符管理授权；使用下文新建 JSON 正文 |

操作：
- `update`：至少指定 `name`、`visible=true|false`、`allowUpload=true|false` 之一；未提供的开关保持原值，空名称／空更新拒绝。
- `enable`：重新核验既有本地来源，通过后开启。
- `disable`：关闭这个工作区，不停止监听或其他工作区。
- `validate`：重新核验来源，但不自动开启手动关闭的工作区。来源无效时持久禁用并同步服务，再返回 `422 workspace_invalid`。
- `destroy`：删除这个工作区的共享配置，**不删除源目录和文件**。

`generation` 是持久目录的比较交换前置条件，与原生界面修改在同一串行队列内核验。旧版本返回 `409 stale_generation`，不覆盖新配置；修改会推进版本，后续操作应先获取最新描述，不盲目重试旧请求。来源／路由通过独立 `configure` 操作修改，且必须先关闭工作区；密码通过 `password` 操作修改。不接受任意原生路径、平台授权引用或调用者提供的密码摘要。

描述字段为 `id`、`name`、`slug`、`generation`、`enabled`、`visible`、`allowUpload`、`passwordProtected`、可空 `invalidReason`。这里 `enabled` 表示保存的意图，不单独证明路由正在服务。变更成功需等待持久保存及真实服务发布／撤回回执；新建／更新／来源路由／密码／启停／校验返回 `{workspace:...}`，销毁返回 `{id,destroyed:true}`。保存完成但服务同步失败返回 `503 config_saved_sync_pending` 及脱敏回执，不宣称回滚或已完全生效。应核对配置与实际发布列表，并使用客户端同步重试后再做后续变更。

### 批准来源、新建、来源路由及密码

用户先在本机 **工作区 → API 已批准来源** 选择目录并命名批准项。持久批准把随机 `sourceId` 绑定到这个本机来源；远程仅返回 `id`、`name`、`kind`，不返回路径或平台授权。只有 `workspaces.manage` 且工作区范围为 `["*"]` 的密钥可列举批准来源或新建，指定工作区密钥返回 `403 wildcard_management_required`。批准／撤销本身仅在本机操作。撤销阻止后续用该来源新建或重新指定（`404 source_not_approved`），**不**关闭或删除已使用该来源的工作区；收回既有访问时，应另行关闭／销毁对应工作区。

`POST /managed-workspaces/create` 接受 `application/json` 对象：

```json
{"sourceId":"SOURCE_UUID","name":"文档","slug":"documents","visible":true,"allowUpload":false}
```

`sourceId`、`name`、`slug` 必填；省略开关默认可见、只读。成功为 **200** `{workspace:...}`，生成新 ID，`generation:1`、`enabled:false`，没有密码。新建不会探测或开启来源；需要保护时先设密码，再用最新代次显式开启，由开启操作核验真实来源。路由规范为小写，满足 `[a-z][a-z0-9-]{0,47}`，不得以 `-` 结尾、与既有路由冲突或占用服务保留名称。不提供重试令牌／幂等键；新建结果不确定时先查目录，不盲目再建。

既有工作区调用 `POST /workspaces/{workspaceId}/manage?generation=N&action=ACTION`：

| 操作 | JSON 正文 | 条件 |
| --- | --- | --- |
| `configure` | `{"sourceId":"SOURCE_UUID","slug":"new-route"}`，至少提供一项 | 必须关闭，否则 `409 workspace_must_be_closed`；来源 ID 仍须获得本机批准。 |
| `password` | `{"password":"PASSWORD"}` **或** `{"clear":true}` | 只能选择一种；密码为 4–128 个 Unicode 字符，不含控制字符；无需关闭。 |

两项沿用串行代次 CAS 和持久保存／发布回执。配置来源路由后继续关闭并推进代次，下次开启重新核验新来源。密码仅持久保存加盐校验值，推进代次，应用生效时撤销旧浏览器授权和响应；显式 API 密钥授权仍独立于浏览器密码。JSON 正文最多 8 KiB、读取限时五秒；未知字段、空配置或同时清除／设置均拒绝。密码不放入查询、记录或复制示例。HTTP 不保护传输中的凭据，需要传输保护时应使用已建立信任的 HTTPS 监听。

```sh
curl -H "Authorization: Bearer $LEGNASEND_API_TOKEN" "$BASE/approved-workspace-sources"
curl -X POST -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"sourceId":"SOURCE_UUID","name":"文档","slug":"documents"}' \
  "$BASE/managed-workspaces/create"
# 先关闭工作区，再读取新代次：
curl -X POST -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  -H 'Content-Type: application/json' --data '{"slug":"documents-new"}' \
  "$BASE/workspaces/ID/manage?generation=GENERATION&action=configure"
```

页内接口浏览器提供这些操作、通过 JSON 正文发送的字段和变更确认，生成调用示例不复制实际密码正文。保存批准项本身不等于已实现 Android 文档树或 Apple 书签根目录；实际来源适配及物理授权继续独立验收。

### 取消与结果不确定

宿主开始排队操作前原子接手授权；撤销／到期密钥及取消／超时的未接手请求不会开始变更。接手之后，即使断联、密钥被撤销或监听切换，已经开始的持久修改仍可能完成。HTTP 三十秒期限包括排队；已接手后的超时／撤销返回 `outcome_unknown`（504／503），**不是“没有发生修改”**。先读取当前目录状态再判断下一步，不自动重复变更，也不承诺回滚。原生测试台等待三十五秒，覆盖服务三十秒回执窗口；普通读取仍最多十二秒。

核心待处理请求最多三十二个，应用活动宿主处理器最多十六个，同时受正常 API 配额约束。已接手持久操作在 HTTP 超时之后仍持有活动配额，迟到宿主回执才释放；桥接清理定时器只丢弃未接手的已关闭请求，不提前释放仍在保存的写操作。隔离任务结果流在终止错误和消费者取消后释放订阅。

### 调用示例

以下 `BASE` 包含 `/api/legnasend/v1/integration`，密钥需有 `ID` 的管理权限。HTTP 与默认监听一致，HTTPS 沿用前文证书要求。

```sh
curl --include -H "Authorization: Bearer $LEGNASEND_API_TOKEN" "$BASE/managed-workspaces"
curl --include --request POST --data-binary '' \
  -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  "$BASE/workspaces/ID/manage?generation=GENERATION&action=update&visible=false"
```

```javascript
const url = new URL(`${base}/workspaces/${workspace.id}/manage`);
url.search = new URLSearchParams({ generation: String(workspace.generation), action: 'disable' });
const response = await fetch(url, {
  method: 'POST', headers: { Authorization: `Bearer ${token}` },
  credentials: 'omit', body: '',
});
console.log(response.status, await response.json()); // 核对 409／503／504，不自动重试。
```

```python
import json, os, urllib.request, urllib.error, urllib.parse
query = urllib.parse.urlencode({'generation': generation, 'action': 'validate'})
request = urllib.request.Request(base + '/workspaces/' + workspace_id + '/manage?' + query,
    data=b'', method='POST', headers={'Authorization': 'Bearer ' + os.environ['LEGNASEND_API_TOKEN']})
try:
    response = urllib.request.urlopen(request, timeout=35)
except urllib.error.HTTPError as error:
    response = error
with response:
    print(response.status, response.read(262144))
```



## 设备发现与自有发送任务

上述十项操作沿用同一集成前缀和宿主接手回执链路。API 不接收任意本地路径、目标地址或扫描网段。发送来源为应用发送页当前已选文件，不是任意工作区目录；从工作区文件编号建立选择、控制无关原生收发会话继续另行实现。

### 权限与生命周期

五项新权限仅供密钥使用，且要求明确 `workspaces: ["*"]`，因为设备和当前选择是应用全局资源。旧密钥不自动获得权限，匿名策略拒绝这些权限；原生编辑器要求用户主动选择全部工作区，不擅自扩大受限授权。`transfers.control` 单独允许取消／移除自有任务；重试必须同时拥有 `transfers.send`。发送权限不自动附带查询权限，需要发现及选择／进度查询时另授予 `devices.read`、`transfers.read`。

任务归属创建密钥的 UUID，不按显示名称判断。其他密钥查询、取消、重试或移除时均返回 404。本机用户原有队列及无关接收／发送会话不交给这些接口控制。改名／暂停／恢复保留归属；新密钥不继承已撤销密钥的任务。关闭 API 或撤销密钥不会偷偷取消主机已经接受的原生任务，本机任务交互仍可使用。

设备／通道 ID、选择版本、任务及幂等回执只在进程内保留。进程重启后需要重读 `/status` 和设备／选择状态，不假设旧任务可以恢复；同一应用内重配监听器不会抛弃已接受的队列。接收确认及 PIN 沿用原界面，API 密钥或 202 响应不跳过接收方确认。

### 发现与选择

`GET /devices` 返回 `{devices,truncated,scanState}`。扫描状态为 `idle`／`running`／`failed`，失败不回显平台错误。最多扫描 512 个已确认 HTTP 设备，每设备最多 32 条通道，返回描述按编码后 200 KiB 限制；截断时 `truncated=true`，此有界快照不提供游标。`GET /devices/{deviceId}` 返回 `{device}`；设备字段为 `id`、`alias`、`deviceType`、`channels`，通道字段为 `id`、`host`、`port`、`https`。这些是已确认入口，不承诺绕过 VPN 系统路由。设备／通道消失再发现后 ID 可能变化，404 后应刷新设备清单。发送省略 `channelId` 时使用接手当时首条已确认通道，入队后固定该入口。

`POST /devices/scan` 使用空正文，返回 202 `{accepted:true,coalesced:boolean}`。调用原本机智能发现，合并正在执行的请求并保留五秒冷却；查询 `/devices` 获取扫描状态和结果。不允许调用方传入地址或更改网络设置。

`GET /send-selection` 返回 `{selectionVersion,totalCount,totalBytes,truncated,files}`。`files` 只含最多 100 个有界文件基本名称／大小预览，没有本地路径或消息正文。发送的是全部当前选择，即使文件多于 100 个；预览截断不代表只发这 100 个。名称按完整字符截断，受 UTF-8 字节预算约束。版本标识当前本地选择对象，**不是内容摘要或磁盘冻结快照**。选择改变时旧版本发送返回 409 `selection_changed`；源文件和校验仍由原发送器实际读取。

### 入队、进度与控制

`POST /transfers/send` 仅接受以下 JSON 正文，最大 8 KiB：

```json
{"deviceId":"DEVICE_UUID","selectionVersion":"SELECTION_UUID","requestId":"REQUEST_UUID","channelId":"CHANNEL_UUID"}
```

ID 均为小写规范 UUID v4，`channelId` 可省略。真正入队后返回 **202** `{task,replayed:false}`，不是送达完成。不引入私有聚合协议或归档替换，原文件与 v2 元数据继续经既有大小感知调度及固定对端客户端发送。所选入口消失时失败，不悄悄切换。

`GET /transfers` 返回本密钥的 `{tasks}`，`GET /transfers/{transferId}` 返回 `{task}`。任务含 `id`、`deviceId`、`status`、`fileCount`、`totalBytes`、`transferredBytes`、`bytesPerSecond`，可选 `result`、`retryOf`、`removed`。状态为 `queued`／`running`／`succeeded`／`failed`／`canceled`；字节及速度取自实际队列／会话和统一采样器。速度 0 也用于尚无有效采样或已结束，不回显原始错误文本、路径、令牌或文件内容。协议成功响应不额外证明远端用户已打开文件。

- **取消**：空 POST `/transfers/{id}/cancel`，200 `{task}`；取消排队或停止真实活动会话。已取消任务仍可能处于清理阶段，设备槽位直到清理结束才释放。
- **重试**：POST `/transfers/{id}/retry`，正文 `{"requestId":"NEW_REQUEST_UUID"}`。仅终止的自有任务可重试，须同时发送和控制权限；202 `{task,replayed:false}` 创建新尝试，保留文件与明确设备入口。这是**整文件重试**，不是分段续传。重发原任务全部文件，包括之前已完成的文件；原记录保留，成功任务也可由明确操作再次发送。
- **移除**：空 POST `/transfers/{id}/remove`，实际移除结束记录后返回 200 `{removed:true,id}`。活动任务返回 409 `transfer_not_terminal`，已取消但仍在排空的任务返回 409 `transfer_busy`。不删除文件。

### 幂等与结果不确定

每个新的发送／重试意图使用新的 `requestId`，并在调用前保存。相同密钥、相同请求 ID 和同一语义正文重复调用，返回原任务及 `replayed:true`，不重复入队；移除历史后仍保留 `removed:true` 的脱敏回执。同一 ID 改用不同发送／重试参数返回 409 `idempotency_conflict`。

主机当前进程最多保留跨所有密钥合计 512 条已接受回执，不通过悄悄淘汰已接受回执让重试变成新的发送；原队列同时最多 128 个非终止任务。任一容量达到上限返回 429 `transfer_queue_full`。移除历史不抹掉防重放状态，应用重启会重置运行期 ID／回执，必须重新读取选择与设备。限额按任务而不是文件计数。

主机接手后超时可能结果不确定，应重用同一请求 ID 和正文，不能为消除网络错误自动生成新 ID。接手前的普通权限／版本／正文错误不消耗回执。原生测试台在当前页面内切换接口或失败时保留发送／重试草稿，明确的“新请求 ID”操作需确认；离开页面或外部自动化应另行保存这些 ID。

主要错误包含缺权限／全局授权／暂停访问的 403，`device_not_found`／`channel_not_found`／`transfer_not_found` 的 404，`selection_changed`／`empty_selection`／`idempotency_conflict`／`transfer_not_terminal`／`transfer_busy` 的 409，以及 `transfer_queue_full` 的 429。既有宿主不可用和接手结果不确定错误仍适用。这十项不接受额外查询参数；凭据只在 Authorization，发送／重试正文使用 JSON。

### 调用示例

每个意图生成一次 UUID 并保存，其他 ID 从上面接口读取。`BASE` 包含集成前缀。测试台为每个接口提供对应示例。

```sh
curl -H "Authorization: Bearer $TOKEN" "$BASE/devices"
curl -H "Authorization: Bearer $TOKEN" "$BASE/send-selection"
# intent.json 只建立一次，响应丢失时复用同一正文。
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data-binary @intent.json "$BASE/transfers/send"
curl -H "Authorization: Bearer $TOKEN" "$BASE/transfers/$TASK_ID"
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Length: 0' \
  "$BASE/transfers/$TASK_ID/cancel"
```

```javascript
// 响应丢失时保持正文及请求 ID 不变。
const body = {deviceId: DEVICE_ID, selectionVersion: SELECTION_VERSION, requestId: REQUEST_ID};
const response = await fetch(`${BASE}/transfers/send`, {
  method: 'POST', headers: {Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json'},
  credentials: 'omit', body: JSON.stringify(body)
});
const receipt = await response.json(); // 使用 receipt.task 前先检查 response.status。
```

```python
import json, urllib.request
body = {"deviceId": DEVICE_ID, "selectionVersion": SELECTION_VERSION, "requestId": REQUEST_ID}
request = urllib.request.Request(BASE + "/transfers/send", data=json.dumps(body).encode(),
    headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}, method="POST")
with urllib.request.urlopen(request) as response:
    receipt = json.load(response)
# 保留请求与任务 ID，查询 /transfers/{taskId} 确认实际完成。
```


当前选择、保留的发送队列历史（包括可重试终止任务）或原生发送会话仍引用来源时，延后通用文件选择器／相册／移动临时缓存清理；受管接收缓存清理独立继续。移除不再需要的历史后再请求通用清理。此为清理启动前保守检查，不是防止已开始批量清理与新选择竞争的提供器租约；移动提供器／后台仍需单独验收。

## 受管缓存管理与应用设置

以下接口沿用可认领的宿主桥接，必须持有**明确的新密钥权限与 `workspaces: ["*"]` 全局授权**。旧密钥不会自动获得权限，匿名授权拒绝这些权限；浏览器密码授权或工作区写权限不等于宿主管理授权。

| 方法与后缀 | 权限 | 结果 |
|---|---|---|
| `GET /cache` | `cache.read` | 有界只读盘点已登记原生暂存 |
| `POST /cache/cleanup` | `cache.clean` | 身份／锁核验后清理非活动受管暂存 |
| `GET /settings` | `settings.read` | 带版本标识的非敏感设置白名单 |
| `POST /settings/update` | `settings.write` | 版本核验后持久修改一项受支持设置 |

空正文接口拒绝 JSON 正文和未知查询字段。不接收本地路径、任意通配符、缓存文件名或调用方指定删除对象；原版 LocalSend 传输不受影响。

### 缓存响应

两种缓存接口均返回 `examined`、`removedFiles`、`removedRecords`、`plannedBytes`、`unlinkedBytes`、`active`、`retained`、`failed`、`budgetReached`、`interrupted`、`entries` 和 `entriesTruncated`。最多返回 128 项明细，每项包含不透明的 64 位小写十六进制 `id`、`sourceKind`（`nativeReceive`／`directoryUpload`／`unknown`）、`disposition`（`candidate`／`removed`／`retired`／`retained`／`active`／`failed`）、稳定原因码 `reason`、`plannedBytes` 和 `unlinkedBytes`。不含文件名、路径、SAF URI、凭据或内容。

盘点不删除数据、不退休登记、不改变清理游标。盘点覆盖已登记普通路径暂存，不代表扫描任意 `.ls`、选择器缓存、浏览器临时文件或所有 Android 提供器。实际清理在适用平台复用现有 Android 提供器核验；提供器明细可以仅有汇总，不冒充普通路径条目。未知所有权、活动锁及不确定权限继续保留。

每次 API 请求一批有界处理。`budgetReached` 表示可能还有待扫描记录，`entriesTruncated` 表示响应明细被截断，二者独立；盘点与清理分别维护游标。已有原生清理执行时合并等待，不启动重复删除。字节为逻辑文件长度／已移除目录项长度，**不等于实测磁盘可用空间增加**。文件已移除但登记退休失败时，`failed` 与 `unlinkedBytes` 可以同时大于零。HTTP 200 只表示诊断操作已返回，须检查 `failed`、`interrupted` 和逐项处置，不能据此声称全部删除。

### 设置响应与修改

读取返回 `{ "version": "64位十六进制摘要", "settings": {...}, "pendingRestart": [], "receiveCacheRetention": {...} }`。设置仅包含 `alias`、`theme`、`locale`、`enableAnimations`、`autoFinish`、`createChecksums`、`verifyChecksums`、`receiveCacheRetentionDays`。主题为 `system`／`light`／`dark`；语言为应用支持的语言标签或 `system`；布尔值使用 JSON 布尔类型。别名非空、宿主最多 120 个 UTF-16 单元且无控制字符。接口不会自动重启监听。别名与接收校验仅保存配置；与当前监听不一致时，`pendingRestart` 明确列出 `alias`／`verifyChecksums`，现有服务及发现身份保持原状，等待用户主动重启服务。主题／语言／动画更新界面，发送摘要设置适用于后续发送；不暴露 API 策略、接收 PIN、密钥、保存路径、自动接收、端口或 TLS 修改。

修改正文为 `{ "version": "读取所得版本", "field": "theme", "value": "dark" }`。宿主串行处理，在认领授权前后核对版本，等待既有设置持久化方法完成后返回新快照。旧版本返回 409 `settings_changed`，字段／类型／语言不合法返回 400，存储失败返回 503 `host_operation_failed`，不回显私有异常。版本包含设置、待重启状态及保留期运行快照，是快照摘要，不是单调历史版本号；设置改回原值时版本相同。认领后发生的本地编辑是后续并发意图，远程操作不会锁死本地设置页。

`receiveCacheRetentionDays` 严格使用 −1…3650 的 JSON 整数：−1 手动保留、0 允许自动清理、正值为已登记原生异常退出残留的保留天数。必需的顶层 `receiveCacheRetention` 返回 `effectiveDays`（可空整数）、`automaticCleanupPaused`、`busy`、`error`（`null`、`invalid`、`save`、`apply`、`restore`）；已保存与实际生效策略可能不同。忙碌时修改返回 409 `settings_busy`，同步失败返回 503 `host_operation_failed`。修改不执行清理，也不授予保留期豁免；API 缓存清理继续遵守策略。[完整保留期开发指南](API_RECEIVE_RETENTION_ZH.md) 提供作用范围、严格类型的 cURL／JavaScript／Python 示例、布尔与字符串负例及失败后核对方式。

已认领的修改出现超时或断联后先查询当前状态，不自动重试；沿用宿主 30 秒处理期限与 `outcome_unknown` 语义。原生 API 测试台提供正文编辑、清理／设置修改前页内确认，以及 cURL、JavaScript、Python 示例。

```sh
curl -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  http://HOST:PORT/api/legnasend/v1/integration/settings
curl -X POST -H "Authorization: Bearer $LEGNASEND_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"version":"VERSION_FROM_READ","field":"theme","value":"dark"}' \
  http://HOST:PORT/api/legnasend/v1/integration/settings/update
curl -X POST -H "Authorization: Bearer $LEGNASEND_API_TOKEN" --data '' \
  http://HOST:PORT/api/legnasend/v1/integration/cache/cleanup
```

远程密钥生命周期、任意监听／安全设置修改仍不由这组接口实现；应用内既有本地密钥管理继续可用，不静默扩大授权来代替未完成控制。

### 当前目录名称过滤

`GET /workspaces/{workspaceId}/files` 接收可选 `filter`，以不区分大小写的字面子串匹配当前目录文件／子目录的基本名称，不递归、不使用正则，也不是文本正文搜索。最多 256 个 Unicode 字符，拒绝控制字符。响应回显 `filter`；游标同时绑定原始过滤值、工作区、代次、目录及目录戳，更换过滤值仍沿用旧游标返回 400。每页最多扫描 512 个原条目、返回 100 个匹配；即使 `entries` 为空，只要 `cursor` 非空就应继续分页。过滤与普通清单使用相同鉴权和工作区范围检查。

## 远程密钥生命周期与请求历史管理

远程密钥管理须明确 `keys.manage` 与全局 `*` 授权。完整密钥生命周期文档 说明元数据、有限授权、一次性秘密、持久回执、原正文重放及失败恢复。请求历史通过 `POST /requests/clear` 清理，要求明确 `requests.manage`，正文包含已捕获的 `instanceId`、`expectedGeneration` 和 `throughSequence`；保留晚到完成记录与脱敏清空标记，不重置序号、限流或活动传输。

## 密钥生命周期开发参考


English

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

## 全局原生任务控制

`GET /native-tasks` 要求 `nativeTasks.read`；`POST /native-tasks/{taskId}/control` 要求 **`nativeTasks.control`**。两者都需要有效密钥和全局 `workspaces: ["*"]`。旧密钥不会自动获得权限，匿名策略拒绝这两项权限。与 `/transfers` 不同，此接口能查看本地创建或其他密钥创建的原生任务；网页响应活动和网页待确认卡片不在范围内。

快照为 `{epoch, tasks, truncated}`。活动任务优先，最多返回 512 个当前保留任务。每项仅返回 `id`、`version`、`direction`、`phase`、`fileCount`、`totalBytes`、`transferredBytes`、`bytesPerSecond`、`actions`，不返回文件名、本地路径、对端地址或原始错误。身份和版本都是不透明 UUID；监听代次改变时 `epoch` 更新。字节进度本身不改变控制版本；阶段、会话尝试、接收目的地／相册设置、本地文件选择或重命名变化都会使旧版本失效。终态速度为零。这是当前保留任务视图，不是完整持久接收历史数据库。

控制正文必须恰好包含 `{epoch, version, action}`，路径使用刚读取的任务 ID。只能使用该任务 `actions` 中列出的操作：

- `accept`／`reject`：待确认的原生接收请求。接受沿用本地已选文件名及目的地，不接收 API 指定路径；消息确认沿用原生消息流程。
- `cancel`：活动原生发送或已经接受的接收，独立于相反方向。已经发布的接收文件保留。
- `remove`：仅移除普通终态任务记录。活动任务和恢复的发送记录不开放此操作，后者可能仍持有发送来源暂存。原始文件不删除。

接手和任务版本检查在派发前执行。有效控制在异步副作用前消耗版本，同一正文重复提交返回 `409 native_task_changed`。成功响应 `{epoch,id,action,dispatched:true}` 仅表示宿主已派发现有原生控制器操作，**不代表对端已确认取消或已经接收完成**。更换监听、本地编辑和新会话会拒绝旧操作。没有暂停／恢复操作，也不会伪装字节续传能力。

```sh
curl -H "Authorization: Bearer $TOKEN" "$BASE/native-tasks"
curl --request POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"epoch":"EPOCH_UUID","version":"TASK_VERSION_UUID","action":"cancel"}' \
  "$BASE/native-tasks/TASK_UUID/control"
```

示例 UUID 必须替换为首次读取的当前值。遇到 `409` 先刷新再决定。传输失败或 `outcome_unknown` 后先读取任务状态，不自动重发控制。应用 API 调试页提供四种文档语言、正文输入、显示目标及操作的页内确认，不自动重试。原始 LocalSend 端点、握手、证书检查和文件编码保持不变。

## 将指定版本工作区文件发送至已发现设备

`POST /workspaces/{workspaceId}/send` 需要同一个有效密钥具有 **`transfers.send`、`files.read` 和全局 `*`**。控制台操作名为 `sendWorkspaceFiles`。先从 `/status` 读取 `instanceId`，从工作区描述读取 `generation`，从文件清单读取规范文件 ID 及完整带引号的 ETag `version`，从 `/devices` 读取目标设备 ID，不自行构造文件路径或设备地址。

```json
{
  "instanceId": "CURRENT_SERVICE_UUID",
  "generation": 1,
  "deviceId": "DISCOVERED_DEVICE_UUID",
  "requestId": "NEW_INTENT_UUID",
  "files": [{"id": "FILE_ID", "version": "\"EXACT_ETAG\""}]
}
```

可选 `channelId` 固定一个已发现网络入口。正文最多 64 KiB，包含 1–128 个不同文件 ID；不接受隐式文件夹递归、路径、网址、覆写控制或任意 IP。宿主核验已发布工作区及来源版本，创建不可变本地暂存后经现有原生发送队列传送，不改变应用内当前文件选择。持有发送权限也必须另有文件读取权限。

`202 {task,replayed}` 复用 `/transfers/send` 的进度和密钥归属回执语义，仅表示已入队，不代表送达。通过 `/transfers/{task.id}` 查询实际状态和速度。结果未知时保留完全相同的请求 ID 与正文；相同 ID 改正文会冲突。服务 `instanceId` 不一致返回 `409 service_instance_changed`，不把旧意图悄悄当作新发送；重启后新的明确发送需重新读取来源并使用新意图。文件字节仍使用原始 LocalSend 协议传送。

### 工作区前台状态核验

`GET /workspaces/{workspaceId}/state?generation=1&path=sub&ids=FILE_ID,FILE_ID` 要求 `files.read` 与匹配的工作区授权。匿名访问沿用文件列表的可见且无密码策略。有限响应包含 `generation`、`path`、目录元数据 `stamp`、`entries` 与 `missing`；只接受请求目录内最多 64 个唯一标准 ID，查询值上限 8192 字节。普通文件包含与下载 ETag 一致的带引号 `version`，目录版本为 null。向设备发送工作区来源时使用此版本。

只在恢复前台／网络时轮询可见条目。目录校验值变化时重新分页，缺失 ID 从当前视图移除。同长度内容修改可能不改变目录校验值，因此还要比较逐文件版本。这些是元数据校验值，不是内容哈希、递归文件系统快照、监控器或持续事件流。旧工作区代次返回 409，不可访问工作区返回 404。下载或发送前再次核验版本；观察状态不等于锁定来源。

```sh
curl -H "Authorization: Bearer $TOKEN" "$BASE/workspaces/$WORKSPACE_ID/state?generation=$GENERATION&path=sub&ids=$FILE_ID"
```

本地化应用测试台已列出此操作，并生成 cURL、JavaScript 和 Python 请求。这是有界的前台增量核验，而非无限扫描。

### 参数长度计算

HTTP、原生控制台与测试页执行同一组公开边界。普通参数值最多 4096 个 UTF-8 字节；`getWorkspaceState.ids` 允许 8192 个 ASCII 字节，包含最多 64 个逗号分隔的标准 ID，此例外不接受本地路径或网址。`filter` 另外限制最多 256 个 Unicode 码点，受支持请求头值最多 1024 字节。契约中的 `minLength`、`maxLength`、`pattern` 和枚举仍须满足。

百分号转义后的整个查询另有限额：工作区状态最多 24 KiB，其他操作保持 8 KiB。状态控制台本地信封允许 24 KiB，包含 JSON 转义；其他操作信封保持既有上限。字符数合格仍可能超过 UTF-8 或转义查询预算。测试台保留已输入值并提示无效，不暗中截断 ID。这些限制不授权任意路径、不扩大权限，也不把读取变成写操作。


### 选择任务本机出口

持有 `devices.read` 与全局 `*` 的有效密钥，可读取 `GET /devices` 的 `localRoutes`。各项包含 `id`、`interfaceName`、`address`、`binding`；Apple/Linux/Windows 为 `interfaceAndSource`，Android 系统 Network 入口为 `androidNetwork`，其他仅来源绑定入口仍为 `sourceOnly`。旧宿主可能省略该可选列表。匿名状态接口不公开这些来源地址。

在 `POST /transfers/send` 或 `POST /workspaces/{workspaceId}/send` 中，将清单 UUID 作为可选 `localRouteId`。原传送权限保持，工作区发送仍额外需要 `files.read`。省略表示自动选路。不要提交自由网卡名、IP 或 `localRoute` 对象。以下片段须与对应接口的其他必填字段组合：

```json
{"localRouteId":"11111111-1111-4111-8111-111111111111"}
```

任务回执返回所选 ID。出口属于幂等参数；复用 `requestId` 却更换出口返回 `409 idempotency_conflict`。重试继承原任务出口，而非当前界面选择，也不接受覆盖出口。入口被移除时返回 `409 local_route_unavailable`，不回退成未绑定连接。观察到网络消失后退休该 ID，再发现生成新 ID；应用重启后旧 ID 失效。已经接受的幂等请求重放仍返回原回执，即便此时出口已消失。

来源快照与排队任务保留出口。原生客户端在请求前重验真实网卡并绑定来源。这不是绕过 VPN 的证明：Android 系统 Network 入口快照进程与生命周期租约，每条新套接字绑定经核验句柄；旧来源绑定入口保留较弱能力。网络丢失使租约失效，即使系统重用句柄也不恢复旧任务。恢复旧进程任务时须用户以当前入口新建任务，操作系统 VPN 与防火墙规则仍有效。应用 API 调试页支持可选字段、示例及严格 UUID 校验。

## 文档预览租约与授权归档

以下操作复用原 API 前缀、`files.read`、工作区名单、密钥或独立匿名策略、跨域规则、请求记录以及秒／分钟／活动响应限额。不增加默认匿名权限，不接受任意文档 URI。

| 方法 | 路径 | 输入 |
|---|---|---|
| POST | `/workspaces/{workspaceId}/prepare-preview?generation=N` | JSON `{id: DOCUMENT_ID}`；仅文档提供程序工作区 |
| POST | `/workspaces/{workspaceId}/close-preview?generation=N` | JSON `{lease: LEASE_UUID}` |
| GET、HEAD | `/workspaces/{workspaceId}/archive?generation=N&path=PARENT&ids=JSON_IDS` | 可选父目录及其直接子项 ID |

预览正文严格限制为 1 KiB，且只含一个标准 UUID 字段。创建返回 `{url,size,etag,mime,lease}`。`url` 使用集成 API 路径，不是浏览器 Cookie 路径；后续 HEAD、GET、关闭仍需同一 API 授权。另一把密钥、浏览器密码 Cookie 或仅知道租约 ID 都不能接管该租约。撤销密钥、工作区换代或移除会终止租约。八个 FD、120 秒闲置期限、元数据校验及取消边界见[描述符租约说明](DIRECTORY_API_ZH.md#文档提供程序预览租约)。

```javascript
async function readPreviewPrefix(base, token, workspaceId, generation, documentId) {
  const headers = {Authorization: `Bearer ${token}`, 'Content-Type': 'application/json'};
  const endpoint = `${base}/workspaces/${encodeURIComponent(workspaceId)}`;
  const prepared = await fetch(`${endpoint}/prepare-preview?generation=${generation}`, {
    method: 'POST', headers, body: JSON.stringify({id: documentId}),
  });
  if (!prepared.ok) throw new Error(`HTTP ${prepared.status}`);
  const lease = await prepared.json();
  try {
    const response = await fetch(new URL(lease.url, base), {
      headers: {Authorization: `Bearer ${token}`, Range: 'bytes=0-65535', 'If-Match': lease.etag},
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.arrayBuffer(); // 仅返回有界前缀，不镜像整个来源。
  } finally {
    await fetch(`${endpoint}/close-preview?generation=${generation}`, {
      method: 'POST', headers, body: JSON.stringify({lease: lease.lease}),
    });
  }
}
```

普通媒体元素自身不能附加 Bearer 请求头，返回的 API 网址不会绕过鉴权。产品浏览器工作区使用独立的受限 Cookie 预览接口。租约内容支持 `version=ETAG` 与 `If-Match`，但不等于持久 `.ls` 恢复或跨重启续传。

归档 `path` 标识父目录：空值根目录、文件系统相对目录，或已签发的文档目录 ID。可选 `ids` 为 URL 编码的紧凑 JSON 数组，包含该父目录内 **1–128 个不重复直接子项**；单个 ID 最多 4,096 字节，解码后数组最多 8,192 字节，编码后整个查询最多 8 KiB。选中文件夹会递归遍历，不传 `ids` 则归档该目录全部内容。不传显示名称、绝对路径或提供程序 URI。文档归档逐个打开原始描述符，不缓存整个目录。ZIP 不支持续传。测试台提供 GET 和 HEAD；GET 只显示有界二进制样本，不代表已保存完整 ZIP。

文档提供程序的 `GET /workspaces/{workspaceId}/state` 只传 `generation` 和可选不透明 `path`，不传文件系统的 `ids`。响应为 `{generation,path,refreshFromStart:true,watchId,stamp,observing}`，仅描述当前目录的短期失效提示，不提供文件 ETag 或完整差异。累计分页前先建立状态基线；观察身份或修订变化时，从当前目录开头重取。`observing:false` 不代表未发生变化，应使用显式前台刷新。既有文件系统状态响应保留为独立契约分支。

## 大量所选项目 ZIP 下载

选择数千个项目时，先创建短期选择票据，不把全部 ID 塞进网址。下面两个接口沿用 `files.read` 权限及目标工作区授权，继续受 API 鉴权、跨域、限流和请求记录约束，不额外开放匿名权限。

| 方法 | 工作区相对路径 | JSON 请求与结果 |
|---|---|---|
| POST | `/prepare-archive?generation=N` | `{path:"",ids:["FILE_ID",...]}` → `{selection,selectedEntries,expiresIn,downloadUrl}` |
| GET / HEAD | `/archive?generation=N&selection=UUID` | 所选 ZIP／响应头 |
| POST | `/cancel-archive?generation=N` | `{selection:"UUID"}` → `{cancelled:true}` |

API 前缀为 `/api/legnasend/v1/integration/workspaces/{workspaceId}`。`path` 必填，根目录也要传 `""`；使用文件系统相对父目录或已颁发的文档目录 ID，不传绝对路径或提供程序 URI。`ids` 必须包含 1–20,000 个不重复、非空的直接子项 ID。每个 ID 最多 4,096 个 UTF-8 字节且不含控制字符；父目录最多 4,096 个 UTF-8 字节且不含 NUL。整个准备请求 JSON 最多 2 MiB。更大的选择需要明确拆分，不会静默截断。

准备接口仅保存有界的选择元数据，不扫描归档，也不缓存 ZIP 字节。`selectedEntries` 是显式选中项目数量，不是递归文件数量或保存成功数量。真正 GET 时才递归所选目录，仍受原有扫描时间、层级、名称、读写和归档并发额度约束。准备成功不代表未知大小、虚拟文档或非法路径变得可下载。

```sh
# selection.json 来自当前目录列表，内容为 {"path":"","ids":[...]}。
ORIGIN='http://HOST:PORT'
BASE="$ORIGIN/api/legnasend/v1/integration"
WORKSPACE='WORKSPACE_UUID'
GENERATION='1'
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' --data-binary @selection.json \
  "$BASE/workspaces/$WORKSPACE/prepare-archive?generation=$GENERATION" > ticket.json
# 从 ticket.json 读取 selection、downloadUrl，网址不含密钥。
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  "$ORIGIN$DOWNLOAD_URL" --output selected.zip
# 取消此票据及其活动下载：
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' --data "{\"selection\":\"$SELECTION\"}" \
  "$BASE/workspaces/$WORKSPACE/cancel-archive?generation=$GENERATION"
```

`downloadUrl` 使用集成 API 命名空间，后续请求仍须携带同一 API 授权。其他密钥、另行颁发的授权或网页密码 Cookie 不会接管此 API 票据。不要把 Bearer 密钥放入网址。网页工作区使用独立的同源 Cookie 路由，拿到的是网页下载地址。

固定 120 秒期限只限制**新的 GET、HEAD 和重试准入**，不是已开始归档的最长下载时长。`expiresIn` 是剩余整秒准入时间，范围 1–120，不会续期。已准入的归档可以继续超过该期限，但显式取消、授权到期／撤销以及工作区关闭／换代仍会终止它。准入过期后，取消接口仍可取消尚在运行的流。已无活动流的过期或未知票据返回 410，其他调用者返回 403；输入错误返回 400，容量用尽会明确报错而非丢弃选择。每个工作区所有者与调用者最多四张票据，全局 64 张，选择元数据总预算 16 MiB。准备响应丢失后不要自动重发，以免创建第二张票据。

`selection` 不得与 `path` 或 `ids` 查询参数并用。旧的内联选择接口仍兼容 1–128 个 ID 和原有 8 KiB 查询预算。票据下载输出流式 ZIP，不是 ZIP 断点续传，也不改变原始 LocalSend 协议。

API 调试页提供两个操作、同等参数校验和页内确认。只有此准备操作在本地调试桥获得 2 MiB JSON 正文额度，另留有界的 16 KiB 请求封装空间；其他操作保留各自较小上限。调试页 GET 结果只是有界响应样本，不是完整 ZIP 保存，请使用实际下载客户端保存归档。HTTP/1 归档／预览控制请求被拒绝时，仅对已知不超过 64 KiB 的正文等待最多 100 毫秒并排空；更大、未知或更慢的正文明确关闭连接。HTTP/2 不添加 `Connection` 响应头。

## 文档提供程序上传父目录

带明确工作区 `files.upload` 授权的密钥可向 Android 文档树上传，不受浏览器 `allowUpload` 开关替代；系统持久写权限及创建能力仍须满足。原上传查询增加可选 `parent`：根目录留空，子目录使用当前清单返回的目录 ID；`path` 相对该父目录，不传 content URI。201 响应回显 `parent`。测试台从契约显示此字段，页内确认同时显示父目录标识，生成的 cURL／JavaScript／Python 示例保持相同查询。文件系统请求省略此字段。实际提供程序发布／取消与结果不明边界见[目录接口](DIRECTORY_API_ZH.md#文档提供程序上传)。

## 文档工作区捕获后原生发送

`POST /workspaces/{workspaceId}/send` 新增明确的文档来源模式。先读取工作区描述并检查 `capabilities.capture`，填写当前 `instanceId`、工作区 `generation`、已发现的 `deviceId`、新的幂等 `requestId`、`sourceMode: "documentSnapshot"` 及 `files: [{"id": "已颁发的文档UUID"}]`。可选 `channelId`／`localRouteId` 沿用已有选路规则。密钥仍须 `transfers.send`、`files.read` 和全局授权。API 调试台新增来源模式选择，草稿及调用示例保留该模式。

- 省略模式仍是原文件系统合同，每文件须带引号的 `version`；文档模式拒绝伪造版本、任意本地路径、重复 ID 或混合格式。每次选择 1–128 个可定位、已知大小的普通文档。此模式不接收递归文件夹、虚拟／管道来源或解析后同名的文件。
- 宿主逐文件捕获至私有受管目录，计算摘要后再次读取同一描述符验证。与原文件系统捕获共享两个真实工作额度，使用固定 256 KiB 缓冲；提供程序另保留实际操作预算。这能检出观察到的变化，不代表提供程序整树原子快照。
- 完整核验后才进入原持久发送队列。工作区／监听器变化检查贯穿到队列副本最终提交；失败等待真实描述符工作结束后仅清自有文件。队列先取得来源归属，再释放捕获暂存。原 LocalSend 握手及文件上传格式保持不变。
- 结果未知时保留相同请求 ID、模式及选择；模式变化属于不同正文，不复用旧 ID。沿用已有批准边界：宿主接纳后的断联／撤销密钥不会追溯撤销已获批发送；读取任务并显式取消。202 表示已入队，不代表对端完成。

此能力是核验后的字节副本发送，不是提供程序持久内容版本、可续传普通下载或自动递归文件夹传送。

## 来源结束通知管理

可选的原生恢复扩展在发送端取消、移除或丢弃可恢复来源时保留独立的私有待通知记录。本地任务结束和远端半文件清理确认是两个不同结果。管理接口只返回脱敏通知，不返回清理凭证、恢复键、本地路径或保存的通道地址。

| 方法和路由 | 密钥权限 | 结果 |
|---|---|---|
| `GET /native-tasks/source-end` | `nativeTasks.read` 与 `*` | `{notices: [...], truncated: boolean}` |
| `POST /native-tasks/source-end/{noticeId}/retry` | `nativeTasks.control` 与 `*` | `{notice: {...}, accepted: true}` |

即使开启匿名读取，这两个接口仍要求有效密钥。每条记录必含 `id`、`version`、`peerLabel`、`name`、`state`、`attempts`、`updatedAtUnixMs`。列表在响应字节预算内最多返回512条，省略内容时明确标记 `truncated`。标识和版本均为规范UUID；不用当前任务代次，因为待通知记录独立于任务移除并可跨宿主重启保留。

```sh
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  "$BASE/native-tasks/source-end"
# 使用列表中的 id/version；每次用户主动重试只生成一个 REQUEST_ID。
# 超时后保留完全相同的正文核对结果，不偷偷换新标识。
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"version":"NOTICE_VERSION_UUID","requestId":"REQUEST_UUID"}' \
  "$BASE/native-tasks/source-end/NOTICE_UUID/retry"
```

幂等范围是单条通知的最近一次重试：新请求会替代保存的重试引用，更早请求再重放可能返回409，不是全局永久回执表。版本过期或同一请求标识携带不同内容返回409；UUID错误、多余字段或正文不合法返回400。重试意图先持久化再接受，保存失败不算派发成功。HTTP200及 `accepted: true` 只表示已排程；刷新列表观察最终结果，不翻译成“文件已删除”。应用内API调试台提供相同正文、页内确认及四地区的cURL／JavaScript／Python示例。

状态含义：

- `pending`、`waitingPeer`：等待派发或重新发现原设备，不盲用已过时的地址。
- `sharedSource`、`busy`：其他任务仍引用相同恢复来源，或接收端仍占有活动／发布中的事务，不强制删除。
- `authorizationRequired`、`unknown`：授权或清理结果仍待确认，都不表示缓存已删除。
- `removed`：接收端已返回其自有半下载数据的持久清理回执。
- `publishedPreserved`：文件已经发布，保留原文件。
- `expired`、`unsupported`、`superseded`：通知授权到期、来源／对端未协商能力，或新附加轮次替代旧授权；都不是清理成功回执。

仅单独协商的来源结束凭证可以授权接收端清理；公共管理密钥、旧v2会话令牌或恢复UUID本身均不具备该权限。已发布文件受保护。原版LocalSend仍使用原协议与整文件重试，不隐式获得该扩展。

已确认的 `removed`／`publishedPreserved` 通知可附带 `cleanup: {receiptId, removedFiles, unlinkedBytes}`。缺失旧数据保持缺失，不补零；数量只来自真实接收端回执，不代表物理空间释放。详见[清理回执说明](SOURCE_END_CLEANUP_RECEIPTS_ZH.md)。

## 持久工作区内容观察状态

工作区描述、目录分页与目录状态响应新增五个独立的观察字段。本实现待验证；它不改变既有配置 `generation`，也不替代逐文件的条件下载协议。

| 字段 | 含义 |
|---|---|
| `contentEpoch` | 观察来源身份的UUID；宿主确认持久状态前为null |
| `contentRevision` | 持久非负观察计数，上限9007199254740991 |
| `contentKnowledge` | 已确认的有界元数据观察为 `observed`，其他情况为 `unknown` |
| `lastObservedAt` | 上次已持久保存的观察时间，Unix毫秒；尚无值时为null |
| `dirty` | 是否仍需重新核验，或持久化结果尚不确定 |

观察代次不是全树哈希、文件摘要，也不证明捕获了全部离线变化。启动及来源／监听器变化后恢复未知状态。监视通知只将范围标脏，有界前台重读检查该范围后才解除；读取开始后到达的新提示不会被旧读取清除。受控上传成功后提交已确认的变化，突发变化可合并为一次代次递增，不按文件逐个计数。

宿主先持久保存，再向HTTP服务确认。待写入或保存失败时对外显示未知状态，不乐观发布未提交代次。修改名称、可见性或访问设置不冒充内容改变；替换来源建立独立身份。文件 `ETag`／`If-Match`、目录游标、授权及下载缓存身份仍沿用原语义，不凭这些字段开启文档提供程序部分续传，也不据此推断下载缓存应被删除。

软件内工作区列表和浏览器工具栏显示紧凑观察标签。既有调用方继续使用配置 `generation`；上传和原始LocalSend协议请求不要求发送这些新增字段。
