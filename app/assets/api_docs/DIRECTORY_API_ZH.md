# 目录工作区浏览器接口

[English](DIRECTORY_API.md)

本文记录已实现的目录浏览、下载和可选上传，不代表完整集成 API。本机“工作区”选项卡继续管理持久配置；独立集成 API 现可从本机批准来源新建、管理明确授权的工作区，并修改关闭工作区的来源／路由及工作区密码，本文浏览器 Cookie 命名空间不授予管理写权限。独立密码已实现；新的[集成 API 核心](INTEGRATION_API_ZH.md)另有权限密钥与可配置预算，不替换本文浏览器 Cookie 契约，原生策略／密钥管理已接入 API 选项卡，页内测试台已支持读取与确认上传／管理，设备／任务／缓存控制继续待办；原 `/api/localsend/v2` 端点保持不变。

## 文档提供程序工作区

Android 文档树来源复用普通目录的工作区索引、名称网址、密码 Cookie 和集成接口鉴权；私有树 URI 不作为公开文件 ID 或本地根路径返回。描述对象新增 `backend: "filesystem" | "documents"` 以及 `capabilities: {archive, capture, events, preview, resume, state}`。调用前逐项判断能力：文档工作区的预览通过下述显式描述符租约提供，其他能力按实际返回值判断，浏览器默认 `readOnly: true`、`allowUpload: false`，本地确认现有写授权后可单独开启上传。普通文件系统的既有能力不变。

文档工作区根目录的 `path` 为空，子目录的 `path` 直接使用返回的目录条目 `id`，不是用显示名称拼接路径；面包屑另外保存可读名称，不解码或伪造文档 ID。`size: null` 表示大小未知，不是零字节；`downloadable: false` 的条目不显示可用下载入口。已知大小也只是清单信息，真正打开时仍核验普通可寻址文件描述符及大小。虚拟文件、管道或不支持的提供程序明确返回错误，不先镜像整个来源冒充支持。

每请求最多读取100条提供程序记录，筛选后可能不足100条且仍有下一游标。提供程序内部可能一次物化更多数据，这不等于保证提供程序本身流式查询。加载中／错误不当成完整空目录；游标变化或过期后重取列表。`stamp` 是后端相关的不透明列表标记，不是强内容版本。访问或刷新会重新查询，首版不宣称文档后端已有实时事件和外部变更锚点保位。

文档下载采用单次原始字节响应，`Accept-Ranges: none`，不返回 ETag；不套用持久`.ls`恢复，也不假定两次请求内容版本相同。该后端已接入下述批准上传及所选文件捕获发送；事件流仍不可用；state 仅提供当前目录失效提示，不返回文件版本；预览使用下述显式短期描述符租约，API 调用方须服从来源能力。来源选择仍需本机系统授权，管理 API 不接受任意树 URI。关闭仅结束自身读取和提供程序状态，不停止其他共享，也不释放被其他应用功能使用的系统持久授权。

## 访问与身份

应用接收服务需要运行。创建目录配置后默认关闭，显式开启才共享。所有工作区复用实际监听端口与 HTTP/HTTPS 设置；使用应用复制的地址，包含端口冲突时实际回退的端口。

目录可设置为开放访问或独立密码／PIN 保护。可见性只控制公开索引：隐藏后已知路径仍可访问，并继续执行相同密码策略。本地根路径不向网页返回。关闭／销毁撤销新请求和该工作区活动下载，不删除源文件，不重启其他会话。改名／隐藏会改变配置代次，但同一根目录上已经打开的下载继续。

## 路由

| 方法 | 路径 | 返回 |
|---|---|---|
| GET | `/` | 可见工作区索引页 |
| GET | `/{slug}/` | 工作区浏览页 |
| GET | `/{slug}/?meta` | `{id, name, slug, generation, readOnly, allowUpload, uploadApproval, protected}` |
| GET | `/api/legnasend/v1/workspaces` | `{workspaces: [descriptor], temporary: boolean}`，仅含可见项 |
| GET | `/api/legnasend/v1/workspaces/{id}/files?generation=N&path=PATH&cursor=CURSOR` | 目录增量分页 |
| GET | `/api/legnasend/v1/workspaces/{id}/state?generation=N&path=PATH&ids=IDS` | 前台目录与可见条目元数据核验 |
| GET | `/api/legnasend/v1/workspaces/{id}/events?generation=N&path=PATH` | 有界目录变更提示事件流 |
| GET, HEAD | `/api/legnasend/v1/workspaces/{id}/files/{fileId}/content?generation=N` | 原始文件字节或响应头 |
| POST | `/api/legnasend/v1/workspaces/{id}/unlock` | JSON `{generation, password}`，设置 HttpOnly 授权 Cookie |
| POST | `/api/legnasend/v1/workspaces/{id}/logout` | JSON `{}`，撤销当前浏览器授权 |
| GET | `/share` | 已开启的原临时双向共享 |

清单和内容请求必须带当前描述对象中的 `generation`，不自行猜测。`path` 对文件系统为经过 URL 编码的根目录相对路径，对文档来源为不透明目录 ID，省略或空值表示根目录；首次请求省略 `cursor`。直接使用服务返回的 `fileId` 和游标，不依赖其内部编码。文件 ID 限定于工作区，不是授权令牌；隐藏名称和编码 ID 不提供鉴权。

每页返回 `{entries, cursor, generation, path, filter, scanned, stamp, offset, anchorPending, anchorMissing}`；条目含 `{id, name, directory, size}`。文件 `size` 为字节数，目录 `size` 不表示递归总量。游标非空表示可能仍有条目，即使本页为空也应继续。文件系统的有效游标可幂等重试；文档提供程序游标绑定预期偏移，重复使用已消费游标会返回409并要求重取列表，不会静默跳过条目；发生目录变化或游标失效后应重取描述对象并从头加载，不把新代次追加到旧列表。枚举顺序由文件系统决定，没有全局排序。

每页最多返回 100 项，最多检查 512 个目录条目；最多保留 128 个有效期 120 秒的游标记录。阻塞目录操作最多八个，下载响应全局最多 32 个／每工作区八个。这些是并发／资源边界，不是每秒／每分钟请求配额。内部 `.ls` 和 `.legnasend*` 名称、符号链接、特殊文件及不支持的路径组件排除，读取不跟随子路径符号链接。

目录参数始终使用 `/`，包括 Windows 宿主。相对目录参数仅 URL 编码一次；不要传绝对盘符／UNC 路径，也不要把返回文件 ID 当 URL 解码。本地根目录与移动授权引用只属于本机配置，见五平台路径约定。

## 密码授权

公开索引和已知路径的描述对象仅返回名称与 `protected` 状态，不返回校验值、本地路径或文件名。受保护清单、内容、HEAD 和 Range 在解锁前返回 401。解锁仅接受 JSON，请求体上限 4 KiB、读取限时五秒，并核对当前配置代次。密码不进入 URL 或查询参数。浏览器 Origin 必须与实际主机／协议一致，拒绝跨站提交；非浏览器客户端可省略 Origin。

成功返回 `{unlocked: true, expiresIn: 3600}`，并设置随机、仅属于该工作区的 Cookie：`HttpOnly`、`SameSite=Strict`、一小时绝对有效期，HTTPS 下附带 `Secure`。JSON 响应、localStorage、sessionStorage 不含令牌。原生 API 调用使用 Cookie 文件；不同主机／IP 的浏览器 Cookie 分开。服务重启不恢复旧浏览器授权。

修改／移除保护或关闭工作区会撤销其旧授权并中断旧下载。改名／隐藏保留当前授权，但后续请求必须使用新配置代次。锁定仅撤销请求携带的授权并停止对应下载，其他浏览器授权和工作区继续运行。过期与会话淘汰也会停止对应下载；每工作区最多 64 个授权。

解锁采用固定预算：每来源 IP／工作区每分钟五次、全局每分钟 30 次，以及两个密码工作线程。429 带 `Retry-After`，工作线程饱和时为一秒。这与新集成 API 的可配置配额独立。仅持久保存加盐 PBKDF2-HMAC-SHA256 校验值，迭代 600,000 次，不保存原始密码；本机设置接受 4–128 个 Unicode 字符，包括数字 PIN。

HTTPS 保护传输中的凭据和内容。单独密码不加密 HTTP 或保存文件；HTTP 页面明确标记差异，HTTPS 由发送端应用设置。

```sh
umask 077
BASE='http://HOST:PORT'
# 使用当前 ID 和代次；JSON 通过请求体发送。
# BASE 使用发送端显示的实际 HTTP/HTTPS 地址。
curl -c cookies.txt -H 'Content-Type: application/json' \
  --data-binary @- "$BASE/api/legnasend/v1/workspaces/ID/unlock" <<'JSON'
{"generation": GENERATION, "password": "PASSWORD"}
JSON
curl -b cookies.txt "$BASE/api/legnasend/v1/workspaces/ID/files?generation=GENERATION"
curl -b cookies.txt -c cookies.txt -H 'Content-Type: application/json' \
  --data '{}' "$BASE/api/legnasend/v1/workspaces/ID/logout"
```

## 预览与正文搜索

相同内容端点增加可选 `preview=1`，只对允许的位图、音视频和纯文本以内联类型响应。默认或 `preview=0` 仍为附件下载。HTML、SVG、脚本和未知格式保持 `application/octet-stream` 附件及 `nosniff`，不建立原始文档 iframe。浏览器按实际编解码能力播放，保留原文件下载。

1. 携带工作区 Cookie、当前配置代次和 `preview=1` 请求 HEAD。
2. 保存返回的强 ETag，包括引号；后续 HEAD／GET 的 `version` 参数使用该值，仅 URL 编码一次，同时保持 Cookie 和代次。原生媒体控件因此无需自定义请求头也能绑定版本。
3. 服务端将 `version` 转成 `If-Match` 条件，元数据变化返回 412；两者同时传入时请求头必须与绑定值相同。版本格式或预览标志错误返回 400。版本不是授权令牌，不替代工作区 Cookie。

```sh
curl -I -b cookies.txt "$BASE/api/legnasend/v1/workspaces/ID/files/FILE_ID/content?generation=GENERATION&preview=1"
# ETAG 使用 HEAD 返回的完整含引号值，不是密码。
curl -b cookies.txt --get "$BASE/api/legnasend/v1/workspaces/ID/files/FILE_ID/content" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'preview=1' \
  --data-urlencode 'version=ETAG' -H 'Range: bytes=0-1023' -o preview-chunk.bin
```

TXT／Markdown 正文搜索通过这些受保护的范围请求执行，不新增公开搜索端点或服务端全文索引。沿用 64 KiB 单次读取、4 MiB 阅读页缓存、独立 2 MiB 搜索缓存、虚拟行、编码／换行切换和 1,000 项匹配上限。较小 Markdown 保留完整排版，较大文档已按完整语法块渐进分节、虚拟渲染；离线 Mermaid／Markmap 与共用图片缩放／平移也已接入。超大单语法块继续保留源阅读／搜索；准确预算及待验范围见当前 README及其证据。

预览可见时，在上次核验结束后三秒安排前台 HEAD，单次请求五秒超时。资源变化或删除会停止旧阅读器并保留页内重试，新尝试重新获取 HEAD 身份；授权撤销会清理受保护内容并重新解锁；其他网络错误清理缓存并提供页内重试。关闭、导航或页面隐藏时终止读取、Markdown 工作线程并释放媒体源。这是前台轮询，不是即时推送撤销，也不承诺后台定时器严格运行。ETag 是元数据验证器，不是内容哈希或正在编辑文件的不可变快照。

## 下载与恢复

HEAD 提供大小、ETag 和 Range 能力；GET 接受单一字节范围、`If-Match` 和 `If-Range`。拼接分片前记录并核验 ETag，配置代次不是内容校验和。源文件变化可能拒绝条件读取或中断正在发送的流；成功必须核对实际字节数，不只看初始状态码。


```sh
BASE='http://HOST:PORT'
# 路径替换为应用内实际创建的名称。
curl "$BASE/workspace1/?meta"
curl "$BASE/api/legnasend/v1/workspaces"
# ID、GENERATION 和 FILE_ID 使用前面响应的返回值。
curl --get "$BASE/api/legnasend/v1/workspaces/ID/files" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'path='
curl -I "$BASE/api/legnasend/v1/workspaces/ID/files/FILE_ID/content?generation=GENERATION"
curl -b cookies.txt -H 'Range: bytes=0-1023' -H 'If-Match: ETAG' \
  "$BASE/api/legnasend/v1/workspaces/ID/files/FILE_ID/content?generation=GENERATION" \
  -o chunk.bin
```

| 状态 | 含义／处理 |
|---|---|
| 200／206 | 完整响应／通过条件核验的部分响应 |
| 401 | 授权缺失／过期／撤销，或密码错误 |
| 403 | 跨站提交或 Origin 不匹配 |
| 408／413／415 | 解锁请求体超时／超限／格式类型不符 |
| 400 | 缺少代次、不支持的路径、错误 ID、重复查询参数或游标／目录不匹配 |
| 404 | 工作区不存在／已关闭，来源缺失／不可读或遇到被禁止的符号链接 |
| 405 | 不支持的方法；本 Cookie 命名空间不授予管理写入 |
| 409 | 配置或目录变化，应重取描述对象／清单 |
| 410 | 游标过期／淘汰或准备期间工作区已停止 |
| 412 | ETag 条件不符，不混拼新旧内容 |
| 416 | 范围格式错误或超出文件 |
| 429 | 并发或尝试预算已满；解锁遵循 Retry-After |



## 前台更新与有界浏览

`GET /api/legnasend/v1/workspaces/{id}/state` 复用清单的代次、工作区 Cookie 和根目录路径约束。传入编码后的相对 path，以及可选逗号分隔 ids；ID 必须来自该目录，最多 64 个且不可重复，整个查询不超过 8,192 字节。返回 `{generation, path, stamp, entries: [{id, size, directory}], missing: [id]}`。只读指定项的元数据，不读文件正文、不递归扫描，沿用八路阻塞操作预算。missing 表示缺失、不可读或不再是允许的普通文件／目录，不跟随符号链接；授权撤销或来源关闭后不返回旧结果。

分页及状态中的 stamp 是 64 字符目录元数据校验值，不是文件哈希或不可变快照。目录戳变化使旧分页失效；同大小正文修改仍依赖前文 HEAD／ETag 内容检查。不同文件系统的时间精度不同，轮询因此属于启发式核验，不保证观察到每一次中间编辑。下文独立事件流增加失效提示，不提供不可变内容版本。独立集成 API 文件分页模型同步可选 stamp，但浏览器 Cookie 状态路由没有冒充新 Bearer 控制台操作。

页面按未变化次数、失败及耗时，每次完成后等待 5–30 秒再检查可见条目；隐藏／离线取消工作，恢复前台／联网立即复核，不假定后台定时器准时执行。未打开预览时变化自动刷新当前窗口；深处阅读通过有界锚点定位保留可见条目与焦点。锚点消失或超出定位预算时，刷新操作明确从头浏览，禁止拼接旧新页。撤销访问清空条目，不反复弹出密码框；删除正在浏览的子目录返回上级。列表刷新不取消其他受管下载。

向前预取参考正向滚动速度与实际请求耗时，最多提前两个视口高度，滚动触发间隔至少 200 毫秒；清单加载串行并保留手动入口。 首屏不足或为空时，最多额外请求两页，间隔 200 毫秒，避免停在全部为排除缓存的分页；失败不触发该填充循环。常驻窗口最多 1,000 项、16 页及 4 MiB 序列化 UTF-16 计费量，不等同完整 JavaScript 堆上限。淘汰页仅保留至多 64 个小型续页书签；“上一段条目”“从头浏览”与范围计数明确当前有界区段。书签遵循现有服务器游标有效期，过期／淘汰／来源变化后重新列举，不暗中混拼新旧页；共享源目录本身不受 1,000 项数量限制。

### 目录变更事件

`GET /api/legnasend/v1/workspaces/{id}/events?generation=N&path=RELATIVE_DIRECTORY` 使用**浏览器工作区 Cookie**，不使用集成 API Bearer 密钥。提供当前正整数代次；省略／空 `path` 表示根目录。只接受 `generation`、`path`，拒绝未知／重复参数和超过 8,192 字节的查询；旧代次返回 409。沿用清单的根目录约束、不安全名称和后代符号链接排除。目录不存在或无访问权返回 404；安装监听过程中目录身份变化返回 409。订阅前先检查授权。

成功响应为 `text/event-stream`、`Cache-Control: no-store`、`X-Accel-Buffering: no`，三种命名事件使用相同的最小正文：

```text
event: ready
data: {"generation":1}

event: invalidate
data: {"generation":1}

event: heartbeat
data: {"generation":1}
```

`ready` 表示监听已建立；`invalidate` 提醒通过原有授权清单／状态接口重新读取。突发事件在 500 毫秒内合并，不逐项积压文件系统通知；约十五秒没有输出事件时发送心跳。事件不含文件名、本机路径、文件字节或监听器内部错误。这是当前浏览目录的**非递归**监听，不是递归变更源或持久事件日志，不提供事件编号、重放或精确一次保证；读取内容仍须使用既有 HEAD／ETag／Range 核验。

全局最多十六路、每工作区四路，超限返回 429；监听建立失败返回 503。每路约九十秒到期，工作区关闭、配置换代、浏览器授权撤销／到期时终止。流拥有监听器和配额，结束后释放；它与 API 密钥请求预算分开。

网页仅在可见／在线浏览时监听；目录、访问或导航变化关闭旧订阅，重连采用 1–30 秒有界指数间隔。错误触发现有状态核验；EventSource／监听器缺失或失败时保留 5–30 秒前台轮询。失效提示沿用阅读位置／焦点与待更新交互，不中断独立下载。不承诺通知交付和后台定时器严格实时。

```sh
curl -N -b cookies.txt --get "$BASE/api/legnasend/v1/workspaces/ID/events" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'path=relative/subfolder'
```

## 网页批量下载

以下可选浏览器接口使用**既有的已批准下载会话或工作区 Cookie**，不是集成 API 密钥。HTTP／HTTPS 均可使用，不修改原 LocalSend 设备互传。临时共享点击“全部／选中下载 · ZIP”，目录当前或子目录点击“下载文件夹 · ZIP”。单个无压缩 ZIP64 保留相对文件名、子目录和空目录；临时共享清单中没有的文件或空目录不自行推断补齐。

| 方法 | 路径 | 参数 |
|---|---|---|
| GET, HEAD, POST | `/api/legnasend/v1/web/archive` | 必填 `sessionId`；可选重复 `fileId`，或一个以 `/` 结尾的 `prefix` |
| POST | `/api/legnasend/v1/web/archive?check=1` | 兼容旧版的元数据预检，返回 `{entries: N}` |
| POST | `/api/legnasend/v1/web/archive?prepare=1` | 相同表单，返回 `{entries: N, downloadUrl: "/api/legnasend/v1/web/archive?sessionId=...&selection=..."}` |
| GET, HEAD | `/api/legnasend/v1/web/archive?sessionId=...&selection=...` | 已批准会话与准备好的选择凭据，不与 `fileId` 或 `prefix` 混用 |
| GET, HEAD | `/api/legnasend/v1/workspaces/{id}/archive` | 必填当前 `generation`；可选根目录相对 `path`，空值表示整个工作区 |

临时共享页面先准备选择，再使用带 download 属性的普通 GET 下载链接，不再通过 POST 导航当前文档；保留 /share 列表，不在页面构造 ZIP Blob。准备接口验证完整集合，只存选择元数据，每个活动共享保留八份，单份受 1 MiB 请求体限制。链接有效期 120 秒，期限内可重复下载，HEAD 不消耗凭据；过期或被淘汰返回 410，再点下载会准备新链接。凭据不替代会话／IP 校验，文件清单版本变化后失效，实际读取继续检查源。原 GET／POST 归档及 check=1 客户端保持兼容。

```javascript
// 使用已批准会话；fileIds 为实际选中的文件 ID。
const form = new URLSearchParams([['sessionId', sessionId], ...fileIds.map(id => ['fileId', id])]);
const response = await fetch('/api/legnasend/v1/web/archive?prepare=1', {
  method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: form
});
if (!response.ok) throw new Error('归档准备失败，HTTP ' + response.status);
const {downloadUrl} = await response.json();
const link = document.createElement('a');
link.href = downloadUrl; link.download = '';
document.body.append(link); link.click(); link.remove();
```

临时 GET 查询最多 8 KiB；POST 为 `application/x-www-form-urlencoded`，最多 1 MiB，请求体十秒截止。`sessionId` 只传一次，不传 `fileId` 表示全部文件；多个 ID 表示所选集合，和目录前缀互斥。会话继续绑定批准时的客户端 IP 与当前共享。浏览器 POST 的 Origin 必须匹配实际监听器，拒绝跨站提交。HEAD／预检仅检查元数据和访问权，不读取文件正文，也不是下载预留：实际请求重新授权。

目录归档沿用清单／内容的密码 Cookie 与配置代次。扫描不跟随符号链接，排除内部 `.ls`／`.legnasend*` 及特殊文件；每个文件在授权根内打开，核对计划时的元数据 ETag 和长度。这**不是原子文件系统快照**：扫描后新增文件不纳入本次归档；已列入文件被删除、元数据变化、撤销授权或短读时中断响应，不发布一个貌似成功的残缺归档。

资源预算：全局两个归档任务，输出最多 100,000 条记录、UTF-8 名称总量 16 MiB、单名称 4 KiB、目录深度 64 和扫描截止十五秒。扫描包括被排除条目在内最多检查 100,000 项。拒绝穿越、大小写不敏感重名、文件／父路径冲突和常见 Windows 保留／非法组件。每次只打开一个源，输出每块最多 64 KiB、队列两个槽位，打开或读取源等待最多三十秒。下载者断开会取消生产者；发送端不预建整包，网页不 fetch 为整包 Blob。元数据／中央目录记录与文件内容分开限额。

成功响应为 `application/zip` 附件，带精确 `Content-Length`、`Cache-Control: no-store`、`X-LegnaSend-Archive-Entries` 和 **`Accept-Ranges: none`**。每次重新生成 ZIP，失败后从头重试；不提供归档 ETag／检查点或部分恢复保证。既有单文件 Range／ETag 保持不变。预检可能返回 400 选择／路径、401／403 授权、404／410 来源消失、409 路径冲突／代次过期、413 超预算、429 活动任务已满、504 扫描超时。响应头之后的错误会让浏览器下载中断，不回报假成功。

```sh
BASE='http://HOST:PORT'
# 在同一客户端通过既有批准流程取得 SESSION_ID。
curl --fail --get "$BASE/api/legnasend/v1/web/archive" \
  --data-urlencode 'sessionId=SESSION_ID' -o shared.zip
# 大量所选 ID 使用 POST，避免长查询地址。
curl --fail "$BASE/api/legnasend/v1/web/archive" \
  --data-urlencode 'sessionId=SESSION_ID' \
  --data-urlencode 'fileId=FIRST_ID' --data-urlencode 'fileId=SECOND_ID' -o selected.zip
# 保护目录先按上文取得 Cookie。
curl --fail -b cookies.txt --get "$BASE/api/legnasend/v1/workspaces/ID/archive" \
  --data-urlencode 'generation=GENERATION' --data-urlencode 'path=relative/subfolder' -o folder.zip
```

### 保存位置

普通网页下载沿用浏览器配置目录（通常为 Downloads），并尊重每次询问位置设置。“保存位置”始终可见；普通局域网 HTTP 解释由浏览器管理位置，支持目录接口的安全上下文可授权目录。授权后**同一个单文件下载入口**自动使用既有 `.ls` 暂停／续传，恢复浏览器默认位置不删除旧任务，不再另设缓存下载按钮。浏览器默认的 ZIP 仍由浏览器管理；授权目录原样批量下载已按下文接入持久日志，完整移动／文件提供器验收继续单列。网页不设置任意本地路径或修改浏览器临时文件扩展名。[浏览器能力说明](https://developer.chrome.com/docs/capabilities/web-apis/file-system-access)。

## 授权目录原样批量下载

在支持目录授权、IndexedDB 和 Web Locks 的浏览器设置“保存位置”，既有全部／选中／文件夹按钮自动改为“原文件”。恢复浏览器默认位置只改变新操作，不删除旧任务。普通 LAN HTTP 仍用浏览器 ZIP，不通过任意路径字符串取得目录权限。

每批在目标下新建独立子目录并避让已有名称，保留原文件名（每组件最多 255 个 UTF-8 字节）、子目录和空目录，不覆盖已有成品。跨平台非法组件、大小写／Unicode 规范化冲突和文件／父路径冲突在规划时拒绝。元数据使用既有已批准临时清单，或按 Cookie／代次读取目录分页；不是原子文件系统快照。

清单每页最多 100 项持久化，进度使用独立小记录，不逐文件重写完整清单。最多八个保留批次、100,000 项，名称／路径树计费分别 16 MiB、序列化元数据 32 MiB、路径 64 组件，规划最多 10,000 次分页请求／五分钟。尚未规划完就刷新会重新枚举，不开始写目标文件。

每页一个活动批次，后续批次排队；可配置 1／2／4 个活动文件（默认两个）复用既有单文件 ETag／.ls 写入器与共享网络预算。每批 Web Lock 阻止两标签同时推进，完成收据及先提交游标后清理文件记录的顺序，避免进度写入中断后重复输出。完成文件不重下。

刷新后恢复为暂停，点击继续重新确认根目录权限，使用当前已批准临时清单或工作区 Cookie／代次；清单不保存密码或会话授权。重试核对未完成来源并获取缺失范围，不静默替换改变／撤销的资源。注册库限定相同主机／协议／端口。移除使用页内确认，只清理受管半下载，保留成品、用户文件和目录。这是原文件批次恢复，**不是 ZIP 的 Range 续传**。

版本 2 注册库保留既有单文件存储，新增批次与清单。完成数量、已提交／待提交字节、速度及控制支持多语言。浏览器存储测试不代替真实 Downloads 授权、后台生命周期或物理移动／文件提供器验收。

## 明确开启的目录上传

在客户端 **工作区 → 上传权限 → 允许网页上传** 开启。新建及旧版迁移的工作区默认只读；开启后，具备该工作区访问权限的浏览器可直接上传，不逐文件弹出批准。密码工作区仍需本工作区 Cookie，集成 API 密钥、可见性或 HTTPS 本身不授予上传权限。

网页可选择／拖入文件和文件夹，保存至当前目录；选择时固定工作区 ID、代次和路径。最多两路上传、队列最多 10,000 项、每页最多 24 行。拖拽接口能提供空目录时保留空目录；普通 HTTP 使用文件选择器，不依赖安全上下文的下载目录选择接口。页面关闭不保留所选文件，失败重试重新发送完整文件，不声明分片续传。

`POST /api/legnasend/v1/workspaces/{id}/upload?generation=N&path=RELATIVE_PATH`

- 必须发送 `X-LegnaSend-Upload: 1`、`Content-Type: application/octet-stream` 和准确 `Content-Length`；正文就是原始文件，浏览器按 File 自动填写长度。
- `path` 是相对工作区根目录的路径，作为查询参数仅编码一次。自动创建父目录，不跟随符号链接；拒绝绝对路径、上级跳转、保留名称和内部缓存名。
- `directory=true` 配合零长度正文创建空目录；同名返回 409，不合并或覆盖。文件上传途中可复用已存在的父目录。
- 明确正文结束、长度通过且无覆盖发布后，才返回 **201** 和 `{"path":"folder/example.txt","size":123,"sha256":"…","directory":false}`。摘要描述收到的字节，不是客户端提供的端到端摘要证明。
- 状态码：400 参数／正文错误；401 授权缺失／撤销；403 只读／跨站／存储拒绝；404 工作区不存在；409 代次失效或名称冲突；411 缺长度或使用传输编码；415 内容类型不符；429 活动上传超额；500 存储／发布失败。
- 每工作区含旧代次正在结束的工作共两路，全局八路；64 KiB 分块、每工作者最多八个排队块。下载仍使用独立预算。
- 拒绝跨站浏览器上下文和 Origin 不匹配；自定义请求头阻止普通跨域表单写入，不增加任意跨域上传。无 Origin 的命令行仍需标记及适用的工作区凭据。
- 关闭上传、变更代次、关闭／销毁工作区或撤销浏览器授权，会取消未完成操作。普通路径发布与撤销共用提交门，撤销确认后旧普通路径写入者不会再发布；已开始的提供程序发布按下文确认或未确认结果处理；此前已经提交的文件保留。普通元信息／上传许可修改不取消无关下载。

```sh
BASE='http://HOST:PORT'
# 密码工作区需先按前文解锁取得 cookies.txt；相对路径编码一次。
curl -b cookies.txt -H 'X-LegnaSend-Upload: 1' \
  -H 'Content-Type: application/octet-stream' --data-binary @example.txt \
  "$BASE/api/legnasend/v1/workspaces/ID/upload?generation=GENERATION&path=folder%2Fexample.txt"
curl -b cookies.txt -H 'X-LegnaSend-Upload: 1' \
  -H 'Content-Type: application/octet-stream' --data-binary '' \
  "$BASE/api/legnasend/v1/workspaces/ID/upload?generation=GENERATION&path=empty-folder&directory=true"
```

同名失败保留原文件，网页重新检查工作区元信息排除旧代次后，提供页内改名重试。网络、繁忙和同名错误暂停队列，不把几千项连续送去失败。成功后刷新当前目录，不清空上传队列。


### 独立密钥授权上传接口

上文浏览器上传路由继续要求自身上传许可、请求标记及适用的工作区 Cookie，Bearer 密钥不用于该路由鉴权。独立的 `POST /api/legnasend/v1/integration/workspaces/{workspaceId}/upload` 现支持明确授予目标工作区范围的 `files.upload` 密钥，即使网页上传关闭也可调用。既有只读密钥和匿名调用不获得写权限。详见[集成上传调用文档](INTEGRATION_API_ZH.md)。

### 登记上传暂存补清理

浏览器和密钥授权目录上传现在创建随机 `.legnasend-receive-<UUID>.part` 暂存，正文仍为原始上传字节，不是 `.ls` 容器。宿主配置私有接收注册库后，在接收正文前持久登记 `directory-upload-v1` 导出记录，将任务绑定到准确父目录／文件身份。应用在启动服务隔离线程前配置注册库，位置沿用应用支持目录／便携配置存储，不把注册元数据放到公开共享目录。

应用启动接收缓存维护及手动清理可回收进程崩溃留下的已登记半上传文件。注册记录和数据文件锁共同保护活动写入；清理使用不跟随链接的打开与父目录／文件身份核对。身份被替换、符号链接、活动锁、授权缺失以及不明确／失败的删除均保留，不凭文件名前缀猜测所有权。每轮最多扫描 4,096 条／两秒，报告保留／失败状态；字节数表示逻辑删除字节，不等同文件系统实际释放容量。成功清理原因是 `interrupted_directory_upload`。

只有已登记且所有权匹配的暂存文件符合条件。既有成品、源文件、任意用户 `.ls`、同前缀未登记文件和旧 `.legnasend-upload-*.part` 均保留。进程内取消可能移除本次创建的空父目录，崩溃补清理不扫描删除任意源目录。未配置私有注册库的独立核心宿主保留普通取消清理，但不会自动拥有启动崩溃补清理。原 LocalSend 端点和正文格式不变。

## 批次缓存保留

原文件批次共用下载面板的手动／1／7／30 天保留设置。在批次与文件锁内重读登记，仅清理受管未完成缓存和元数据，保留成品和用户目录。活动／排队批次、未知权限和身份变化保留。HTTP 401／403 及临时网络错误可重试；明确来源失效或版本变化后清理自有残留，并显示本地化原因。这是浏览器授权存储管理，不代表 ZIP Range 或原生跨重启续传。

## 网页上传逐批接收确认

应用发布的工作区声明 `uploadApproval: true`。`allowUpload` 只是工作区写入许可，不代表自动接受任意请求；新建工作区仍默认只读。浏览器每次选择或拖入构成一批，含数千文件的文件夹也只确认一次。明确授予 `files.upload` 的密钥请求使用独立集成命名空间，不继承浏览器批准。原版 LocalSend 接口及文件格式不变。

1. 使用当前浏览器 Cookie，向 `/api/legnasend/v1/workspaces/{id}/prepare-upload` 提交 POST JSON，带 `Content-Type: application/json`、`X-LegnaSend-Upload: 1`。正文 `{requestId, generation, files: [{path, size, directory}]}`；请求 ID 为新建规范 UUID v4，路径相对工作区根目录，目录大小为零，清单在批准后保持不变。
2. 应用悬标显示待接收批次，页内面板可查看名称、来源、数量、总大小和按需文件列表。在服务端 60 秒期限内接受或拒绝；关闭／返回仅隐藏面板，不停止共享或原生收发。
3. 批准响应 `{token, expiresIn: 1800, fileCount, totalBytes}`。已有 `/upload` 请求通过 **`X-LegnaSend-Upload-Token` 请求头**携带批准，不放入 URL。批准绑定工作区代次、来源 IP、浏览器授权 Cookie、精确路径／大小／文件目录属性，每项只用一次；原始字节继续沿有界双路上传调度发送。批准不等于文件已经传送成功。
4. 待确认或已批准的剩余项可向同工作区 `/cancel-upload-approval` POST `{requestId, generation}` 撤销，沿用上述 Cookie／请求头。网页中取消批次任一项会取消该批剩余上传，已完成文件保留。失败文件重试或改名时只为该项重新申请批准，不覆盖已有目标文件。

边界：清单最多 1 MiB、10,000 个唯一路径，总字节为安全整数，路径深度 64、每段最多 255 个 UTF-8 字节；每工作区同时待确认最多两批，全局十六批，每工作区最多十六个活动批准清单。取消使用独立有界准入，等待队列已满仍可排空。跨来源准备请求被拒绝；400 表示清单无效，401 表示失去授权，403 表示拒绝本批或没有写许可，409 表示代次变化／取消，408 表示到期，429 表示容量已满，503 表示宿主响应端不可用。实际上传缺少有效批准返回 428，尚未写入文件；拒绝本批不会关闭工作区上传许可。

工作区关闭／修改、浏览器授权失效、连接中断或待确认超时会撤销旧决定。批准只在内存中保存，重启不恢复。独立核心嵌入未声明 `uploadApproval` 时保留其明确配置的直接上传行为，属于兼容性字段默认值，不是应用发布的策略。共享 Flutter 移动布局、本机浏览器／桥接验收与 Android／iOS 真机授权、后台行为分别记录。

## 围绕可见条目的有界刷新

新的 `files` 请求可带 `anchor=FILE_ID`，使用当前目录的条目标识。标识必须解码为安全相对路径且父目录与 `path` 相同，跨目录拒绝。后续请求省略锚点，仅延续返回的 `cursor`，保持相同代次、路径和筛选条件。鉴权与根目录约束不变；独立集成命名空间也支持同一参数。

`anchorPending=true` 表示尚未找到条目，即使本页为空也继续返回游标。每请求最多扫描 512 个候选项，整次定位最多扫描 32,768 项。`anchorMissing=true` 表示条目已消失或定位超预算，应提供从头浏览，不静默展示无关位置。`offset` 是该页之前跳过的匹配可见条目数，不是可提交的偏移参数。找到锚点后按实际文件系统顺序和既有分页预算继续；它是新枚举的定位，不是旧新页合并或全局排序快照。

浏览器现在用此机制刷新深处目录，联网及页面恢复保留原窗口；预览源替换／删除保留可重试状态，重新核验身份后再建立阅读器。鉴权撤销仍清除受保护内容。

授权目录下载支持可配置 1／2／4 文件及分片并发、有界可选重连与批量控制，普通浏览器下载方式不变。完成记录达到容量时可淘汰旧收据，但成品文件保持。

## 文档提供程序预览租约

当工作区描述提供 `backend: "documents"` 和 `capabilities.preview: true` 时，先创建预览租约，不要直接给普通下载网址添加 `preview=1`：

```sh
curl -b cookies.txt -H 'Content-Type: application/json' \
  -d '{"id":"DOCUMENT_ID"}' \
  "$BASE/api/legnasend/v1/workspaces/ID/prepare-preview?generation=GENERATION"
# {url,size,etag,mime,lease}
curl -I -b cookies.txt "$BASE$URL"
curl -b cookies.txt -H 'Range: bytes=0-65535' -H 'If-Match: ETAG' "$BASE$URL"
curl -b cookies.txt -H 'Content-Type: application/json' \
  -d '{"lease":"LEASE_UUID"}' \
  "$BASE/api/legnasend/v1/workspaces/ID/close-preview?generation=GENERATION"
```

返回网址保留 `/files/DOCUMENT_ID/content`，包含 `generation`、`preview=1` 和 `lease`，支持既有预览器使用的 `version=ETAG` 及 `If-Match`。创建响应与 HEAD 的 MIME 描述相同的内联白名单表示；HTML、SVG 和脚本不属于预览类型。未知大小、虚拟文档及非普通或不可定位描述符仍不支持。

租约固定持有一个原始只读描述符，不镜像来源。最多八个活跃描述符租约，120 秒没有成功 HEAD 或读取活动即过期。每次请求核验该描述符的元数据；带引号 ETag 包含随机租约身份和元数据，不是内容摘要或不可变快照，元数据改变会拒绝旧租约。并发 Range 请求只对各自有界块串行定位和读取同一描述符，不用复制 FD 后共享文件偏移来冒充独立读取。

工作区换代、关闭、授权撤回和过期结束租约。浏览器关闭、离页或隐藏主动释放；重新打开必须新建租约，不沿用旧缓存偏移。可见页面的既有 HEAD 检查会续期。系统调用忽略取消时，真实描述符和线程预算保持到调用返回；HTTP 读取可先结束，不宣称已中断系统调用。普通附件下载仍没有跨请求版本保证，不能把预览租约当作持久下载续传。

## 文档提供程序选中项 ZIP 与当前目录状态

既有鉴权 `archive` 路由现在支持 `ids`：URL 编码的 JSON 数组，包含 `path` 内 1–128 个不重复直接子项 ID。不传 `ids` 保持整目录下载，选中文件夹递归处理。文档工作区的 `path` 为空或已签发目录 UUID，不拼接显示名称。每个文件从原始描述符依次打开并流式传送，不镜像整个提供程序目录，也不在磁盘预生成完整 ZIP。

输出为 ZIP64 STORE，保留 Unicode 路径和显式空目录，均位于安全的 `files/` 前缀下。忽略大小写后重名返回 409，非法名称返回 400，不可读、虚拟或大小未知的文档返回 501。所选文档不属于父目录返回 404，文件系统非法选择返回 400。文档扫描限制为 30 秒、100,000 条、16 MiB 名称及 64 层，并沿用两个归档、八个 I/O 和每工作区八个下载的预算。来源变化、撤权或短读会中断响应，不生成成功的中央目录。这不是快照或可续传归档，也不改变原版 LocalSend 传送协议。

文档 `state?generation=N&path=OPAQUE_ID` 返回短期观察身份与修订，以及 `refreshFromStart:true` 和 `observing`；不接受 `ids`，不返回文件版本条目。观察器数量有界，不刷新即过期；观察不可用不代表目录未改变。浏览器前台轮询先建立基线再累计分页，失效后从当前目录开头刷新，并保留显式刷新操作。`capabilities.state` 表示该后端状态提示，`capabilities.events` 仍为 false。

成功注册文档观察器也只代表获得变化提示通道，不保证提供程序可靠通知。前台观察复用有界保留的列表游标，以保持兼容 AOSP 的观察器存活；提供程序内部仍可能一次物化整个 MatrixCursor。应用限制持有句柄与对外页面，不宣称限制了提供程序私有查询成本。通知缺失或不可靠时继续使用手动刷新。

## 大量所选项目归档票据

大量选择使用 `POST /api/legnasend/v1/workspaces/{id}/prepare-archive?generation=N`，JSON 为 `{path:"",ids:[...]}`。即使是根目录也必须传 `path`。选择 1–20,000 个不重复、非空的直接子项 ID，每个 ID 最多 4,096 个 UTF-8 字节且不含控制字符；父目录最多 4,096 个 UTF-8 字节且不含 NUL。整个 JSON 正文最多 2 MiB。ID 必须来自当前目录，不是任意源路径。受约束的文件系统工作区与文档提供程序工作区均支持此流程。

结果为 `{selection,selectedEntries,expiresIn,downloadUrl}`。使用同一网页会话访问 `downloadUrl`，其对应 `archive?generation=N&selection=UUID`；不得同时传 `path` 或 `ids` 查询参数。准备阶段仅保存选择元数据，不缓存整个目录、文件内容或 ZIP。`selectedEntries` 统计显式选中项，不是递归子项总数。真正 GET 时才进行有界扫描并流式输出 ZIP，原有校验和工作预算继续生效；准备成功不保证之后每个来源仍可读取。

票据采用固定 120 秒的新 HEAD／GET 准入期限，不续期。`expiresIn` 表示剩余整秒准入时间，不是固定下载时长。已准入归档可继续超过此期限，直到正常结束、显式取消、授权到期／撤销或工作区关闭／换代。向 `POST /api/legnasend/v1/workspaces/{id}/cancel-archive?generation=N` 发送 `{selection:"UUID"}`，只取消这一票据及其活动流，包括准入期限已过但仍在运行的流。成功返回 `{cancelled:true}`；已无活动流的缺失或过期票据返回 410，其他调用者返回 403。取消不删除源文件。

每个工作区所有者与调用者最多四张票据，全局 64 张，保留元数据总预算 16 MiB。准备响应丢失后不要自动再创建，未领取的票据会到期。网页与 API 授权保持分离：API 票据使用集成地址，仍需同一 Bearer 授权。完整调用见[集成 API 示例](INTEGRATION_API_ZH.md#大量所选项目-zip-下载)。旧的内联归档选择继续支持查询预算内最多 128 个 ID。此流程是带短期元数据票据的普通流式下载，不是先在浏览器缓存整个归档，也不是原版 LocalSend 必须支持的协议扩展。

## 文档提供程序上传

本地工作区的“上传权限”可开启文档树网页写入。开启前只检查现有持久读写授权与根目录创建能力，不代表远端操作能索取新授权。授权不足时保持原只读配置；关闭工作区后通过系统选择器重新选择并授权，再开启。每次实际写入仍重新检查当前父目录及权限。

浏览器/API沿用各自现有上传端点和原始字节正文，文档工作区增加 `parent` 查询参数：空字符串为树根，否则是当前代次清单返回的目录 `id`。`path` 是相对此父目录的受校验名称／子路径，不能是目录ID、绝对路径或content URI。文件系统工作区仍以根目录为基准，只能省略parent或传空。

浏览器 `prepare-upload` 清单顶层可增加同一 `parent`；批准令牌绑定父目录、代次、来源、Cookie及逐文件路径／大小／类型。导航后已选择任务仍使用原父目录，重试重新申请相同父目录的批准。缺少批准的字节不会写入。独立集成密钥具有明确 `files.upload` 和目标工作区授权时，仍按原策略独立于浏览器上传开关，但不能绕过系统写授权。

写入采用自有`.ls`与独立导出暂存，通过字节数／摘要核验后向提供程序发布并读回验证，确认成功才返回201。响应在原字段之外增加 `parent`，例如 `{"parent":"DIRECTORY_ID","path":"子目录/文档.txt","size":123,"sha256":"…","directory":false}`。空目录沿用`directory=true`与零长度正文。既有文档不覆盖，提供程序擅自改名不当作原名称成功；只回滚已证明自有且仍为空的新建目录。

提供程序发布是异步操作，不承诺POSIX原子无覆盖。进入实际提交后，取消不阻塞控制线程，也不把已确认发布结果改成“已取消”。浏览器在保存阶段中断响应时提示结果待确认并暂停队列，应刷新目标目录核对后再重试。未知结果保留登记供核对，不伪称已清理。服务停止时仅排空已交付双描述符事务的发布／释放控制，新事务不再接受；旧调用不污染新监听。

### 捕获文档文件并原生发送

文档工作区的 `capabilities.capture` 表示可接入集成接口的来源捕获链。使用[工作区发送接口](INTEGRATION_API_ZH.md#文档工作区捕获后原生发送)明确的 `documentSnapshot` 正文，不把清单时间戳或预览租约伪造为强内容版本。此能力覆盖所选普通文件，不代表自动递归文件夹捕获或提供程序级原子内容版本。
