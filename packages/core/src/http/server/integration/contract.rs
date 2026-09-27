use super::{PREFIX, Scope};
use serde_json::{Value, json};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Operation {
    Status,
    Capabilities,
    Workspaces,
    Workspace,
    Files,
    Content,
    Upload,
    Requests,
    OpenApi,
    ManagedWorkspaces,
    ApprovedSources,
    CreateWorkspace,
    ManageWorkspace,
    Devices,
    Device,
    ScanDevices,
    SendSelection,
    SendTransfer,
    Transfers,
    Transfer,
    CancelTransfer,
    RetryTransfer,
    RemoveTransfer,
    InspectCache,
    CleanupCache,
    ReadSettings,
    UpdateSettings,
    ListKeys,
    CreateKey,
    ManageKey,
    KeyReceipt,
    ClearRequests,
    WorkspaceSend,
    NativeTasks,
    ControlNativeTask,
    SourceEndNotices,
    RetrySourceEndNotice,
    WorkspaceState,
    PreparePreview,
    ClosePreview,
    PrepareArchive,
    CancelArchive,
    Archive,
    Unknown,
}
impl Operation {
    pub fn is_native_tasks(self) -> bool {
        matches!(
            self,
            Self::NativeTasks
                | Self::ControlNativeTask
                | Self::SourceEndNotices
                | Self::RetrySourceEndNotice
        )
    }
    pub fn is_keys(self) -> bool {
        matches!(
            self,
            Self::ListKeys | Self::CreateKey | Self::ManageKey | Self::KeyReceipt
        )
    }
    pub fn is_host(self) -> bool {
        matches!(
            self,
            Self::InspectCache | Self::CleanupCache | Self::ReadSettings | Self::UpdateSettings
        )
    }
    pub fn is_transfer(self) -> bool {
        matches!(
            self,
            Self::Devices
                | Self::Device
                | Self::ScanDevices
                | Self::SendSelection
                | Self::WorkspaceSend
                | Self::SendTransfer
                | Self::Transfers
                | Self::Transfer
                | Self::CancelTransfer
                | Self::RetryTransfer
                | Self::RemoveTransfer
        )
    }
    pub fn is_post(self) -> bool {
        matches!(
            self,
            Self::PrepareArchive
                | Self::CancelArchive
                | Self::PreparePreview
                | Self::ClosePreview
                | Self::ControlNativeTask
                | Self::RetrySourceEndNotice
                | Self::CreateKey
                | Self::ManageKey
                | Self::ClearRequests
                | Self::CleanupCache
                | Self::UpdateSettings
                | Self::Upload
                | Self::ManageWorkspace
                | Self::CreateWorkspace
                | Self::ScanDevices
                | Self::WorkspaceSend
                | Self::SendTransfer
                | Self::CancelTransfer
                | Self::RetryTransfer
                | Self::RemoveTransfer
        )
    }
    pub fn is_management(self) -> bool {
        self.is_native_tasks()
            || self.is_keys()
            || self.is_transfer()
            || self.is_host()
            || matches!(
                self,
                Self::ManagedWorkspaces
                    | Self::ManageWorkspace
                    | Self::ApprovedSources
                    | Self::CreateWorkspace
            )
    }
    pub fn identify(path: &str) -> Self {
        match path.split('/').collect::<Vec<_>>().as_slice() {
            ["native-tasks"] => Self::NativeTasks,
            ["native-tasks", "source-end"] => Self::SourceEndNotices,
            ["native-tasks", "source-end", id, "retry"] if !id.is_empty() => {
                Self::RetrySourceEndNotice
            }
            ["native-tasks", id, "control"] if !id.is_empty() => Self::ControlNativeTask,
            ["keys"] => Self::ListKeys,
            ["keys", "create"] => Self::CreateKey,
            ["keys", id, "manage"] if !id.is_empty() => Self::ManageKey,
            ["keys", "requests", id] if !id.is_empty() => Self::KeyReceipt,
            ["requests", "clear"] => Self::ClearRequests,
            ["cache"] => Self::InspectCache,
            ["cache", "cleanup"] => Self::CleanupCache,
            ["settings"] => Self::ReadSettings,
            ["settings", "update"] => Self::UpdateSettings,
            ["devices", "scan"] => Self::ScanDevices,
            ["devices"] => Self::Devices,
            ["devices", id] if !id.is_empty() => Self::Device,
            ["workspaces", id, "send"] if !id.is_empty() => Self::WorkspaceSend,
            ["send-selection"] => Self::SendSelection,
            ["transfers", "send"] => Self::SendTransfer,
            ["transfers"] => Self::Transfers,
            ["transfers", id] if !id.is_empty() => Self::Transfer,
            ["transfers", id, "cancel"] if !id.is_empty() => Self::CancelTransfer,
            ["transfers", id, "retry"] if !id.is_empty() => Self::RetryTransfer,
            ["transfers", id, "remove"] if !id.is_empty() => Self::RemoveTransfer,
            ["status"] => Self::Status,
            ["capabilities"] => Self::Capabilities,
            ["workspaces"] => Self::Workspaces,
            ["workspaces", id] if !id.is_empty() => Self::Workspace,
            ["workspaces", id, "files"] if !id.is_empty() => Self::Files,
            ["workspaces", id, "state"] if !id.is_empty() => Self::WorkspaceState,
            ["workspaces", id, "prepare-archive"] if !id.is_empty() => Self::PrepareArchive,
            ["workspaces", id, "cancel-archive"] if !id.is_empty() => Self::CancelArchive,
            ["workspaces", id, "prepare-preview"] if !id.is_empty() => Self::PreparePreview,
            ["workspaces", id, "close-preview"] if !id.is_empty() => Self::ClosePreview,
            ["workspaces", id, "archive"] if !id.is_empty() => Self::Archive,
            ["workspaces", id, "files", file, "content"] if !id.is_empty() && !file.is_empty() => {
                Self::Content
            }
            ["workspaces", id, "upload"] if !id.is_empty() => Self::Upload,
            ["approved-workspace-sources"] => Self::ApprovedSources,
            ["managed-workspaces", "create"] => Self::CreateWorkspace,
            ["managed-workspaces"] => Self::ManagedWorkspaces,
            ["workspaces", id, "manage"] if !id.is_empty() => Self::ManageWorkspace,
            ["requests"] => Self::Requests,
            ["openapi.json"] => Self::OpenApi,
            _ => Self::Unknown,
        }
    }
    pub fn id(self) -> &'static str {
        match self {
            Self::Status => "getStatus",
            Self::Capabilities => "getCapabilities",
            Self::Workspaces => "listWorkspaces",
            Self::Workspace => "getWorkspace",
            Self::Files => "listFiles",
            Self::Content => "getContent",
            Self::Upload => "uploadFile",
            Self::Requests => "listRequests",
            Self::OpenApi => "getOpenApi",
            Self::ApprovedSources => "listApprovedWorkspaceSources",
            Self::CreateWorkspace => "createWorkspace",
            Self::ManagedWorkspaces => "listManagedWorkspaces",
            Self::ManageWorkspace => "manageWorkspace",
            Self::Devices => "listDevices",
            Self::Device => "getDevice",
            Self::ScanDevices => "scanDevices",
            Self::SendSelection => "getSendSelection",
            Self::SendTransfer => "sendSelection",
            Self::Transfers => "listTransfers",
            Self::Transfer => "getTransfer",
            Self::CancelTransfer => "cancelTransfer",
            Self::RetryTransfer => "retryTransfer",
            Self::RemoveTransfer => "removeTransfer",
            Self::InspectCache => "inspectCache",
            Self::CleanupCache => "cleanupCache",
            Self::ReadSettings => "readSettings",
            Self::UpdateSettings => "updateSettings",
            Self::ListKeys => "listKeys",
            Self::CreateKey => "createKey",
            Self::ManageKey => "manageKey",
            Self::KeyReceipt => "getKeyReceipt",
            Self::ClearRequests => "clearRequests",
            Self::WorkspaceSend => "sendWorkspaceFiles",
            Self::NativeTasks => "listNativeTasks",
            Self::ControlNativeTask => "controlNativeTask",
            Self::SourceEndNotices => "listSourceEndNotices",
            Self::RetrySourceEndNotice => "retrySourceEndNotice",
            Self::WorkspaceState => "getWorkspaceState",
            Self::PrepareArchive => "prepareWorkspaceArchive",
            Self::CancelArchive => "cancelWorkspaceArchive",
            Self::PreparePreview => "prepareDocumentPreview",
            Self::ClosePreview => "closeDocumentPreview",
            Self::Archive => "downloadWorkspaceArchive",
            Self::Unknown => "unknown",
        }
    }
    pub fn scope(self) -> Scope {
        match self {
            Self::Workspaces | Self::Workspace => Scope::Workspaces,
            Self::Files
            | Self::Content
            | Self::WorkspaceState
            | Self::PreparePreview
            | Self::ClosePreview
            | Self::PrepareArchive
            | Self::CancelArchive
            | Self::Archive => Scope::Files,
            Self::Upload => Scope::Upload,
            Self::ManagedWorkspaces
            | Self::ManageWorkspace
            | Self::ApprovedSources
            | Self::CreateWorkspace => Scope::Manage,
            Self::Devices | Self::Device => Scope::DevicesRead,
            Self::ScanDevices => Scope::DevicesScan,
            Self::SendSelection | Self::Transfers | Self::Transfer => Scope::TransfersRead,
            Self::SendTransfer | Self::WorkspaceSend => Scope::TransfersSend,
            Self::CancelTransfer | Self::RetryTransfer | Self::RemoveTransfer => {
                Scope::TransfersControl
            }
            Self::InspectCache => Scope::CacheRead,
            Self::CleanupCache => Scope::CacheClean,
            Self::ReadSettings => Scope::SettingsRead,
            Self::UpdateSettings => Scope::SettingsWrite,
            Self::ListKeys | Self::CreateKey | Self::ManageKey | Self::KeyReceipt => {
                Scope::KeysManage
            }
            Self::ClearRequests => Scope::RequestsManage,
            Self::Requests => Scope::Requests,
            Self::NativeTasks | Self::SourceEndNotices => Scope::NativeTasksRead,
            Self::ControlNativeTask | Self::RetrySourceEndNotice => Scope::NativeTasksControl,
            _ => Scope::Service,
        }
    }
    pub fn path(self) -> &'static str {
        match self {
            Self::Status => "/status",
            Self::Capabilities => "/capabilities",
            Self::Workspaces => "/workspaces",
            Self::Workspace => "/workspaces/{workspaceId}",
            Self::Files => "/workspaces/{workspaceId}/files",
            Self::Content => "/workspaces/{workspaceId}/files/{fileId}/content",
            Self::Upload => "/workspaces/{workspaceId}/upload",
            Self::Requests => "/requests",
            Self::OpenApi => "/openapi.json",
            Self::ApprovedSources => "/approved-workspace-sources",
            Self::CreateWorkspace => "/managed-workspaces/create",
            Self::ManagedWorkspaces => "/managed-workspaces",
            Self::ManageWorkspace => "/workspaces/{workspaceId}/manage",
            Self::Devices => "/devices",
            Self::Device => "/devices/{deviceId}",
            Self::ScanDevices => "/devices/scan",
            Self::SendSelection => "/send-selection",
            Self::SendTransfer => "/transfers/send",
            Self::Transfers => "/transfers",
            Self::Transfer => "/transfers/{transferId}",
            Self::CancelTransfer => "/transfers/{transferId}/cancel",
            Self::RetryTransfer => "/transfers/{transferId}/retry",
            Self::RemoveTransfer => "/transfers/{transferId}/remove",
            Self::InspectCache => "/cache",
            Self::CleanupCache => "/cache/cleanup",
            Self::ReadSettings => "/settings",
            Self::UpdateSettings => "/settings/update",
            Self::ListKeys => "/keys",
            Self::CreateKey => "/keys/create",
            Self::ManageKey => "/keys/{keyId}/manage",
            Self::KeyReceipt => "/keys/requests/{requestId}",
            Self::ClearRequests => "/requests/clear",
            Self::WorkspaceSend => "/workspaces/{workspaceId}/send",
            Self::NativeTasks => "/native-tasks",
            Self::SourceEndNotices => "/native-tasks/source-end",
            Self::RetrySourceEndNotice => "/native-tasks/source-end/{noticeId}/retry",
            Self::ControlNativeTask => "/native-tasks/{taskId}/control",
            Self::WorkspaceState => "/workspaces/{workspaceId}/state",
            Self::PrepareArchive => "/workspaces/{workspaceId}/prepare-archive",
            Self::CancelArchive => "/workspaces/{workspaceId}/cancel-archive",
            Self::PreparePreview => "/workspaces/{workspaceId}/prepare-preview",
            Self::ClosePreview => "/workspaces/{workspaceId}/close-preview",
            Self::Archive => "/workspaces/{workspaceId}/archive",
            Self::Unknown => "",
        }
    }
    pub fn queries(self) -> &'static [&'static str] {
        match self {
            Self::Files => &["generation", "path", "cursor", "filter", "anchor"],
            Self::WorkspaceState => &["generation", "path", "ids"],
            Self::Content => &["generation", "preview", "version", "lease"],
            Self::PreparePreview
            | Self::ClosePreview
            | Self::PrepareArchive
            | Self::CancelArchive => &["generation"],
            Self::Archive => &["generation", "path", "ids", "selection"],
            Self::Upload => &["generation", "path", "directory", "parent"],
            Self::ManageWorkspace => &["generation", "action", "name", "visible", "allowUpload"],
            Self::Requests => &["after", "limit"],
            Self::OpenApi => &["lang"],
            _ => &[],
        }
    }
}
/// Decoded UTF-8 budgets shared by the public contract, console and HTTP query parser.
/// Larger allowances are limited to read-only directory identifiers.
pub(super) fn parameter_byte_limit(operation: Operation, name: &str) -> usize {
    match (operation, name) {
        (Operation::WorkspaceState, "ids")
        | (Operation::Archive, "ids")
        | (Operation::Files, "anchor") => 8192,
        (_, "Range" | "If-Match") => 1024,
        _ => 4096,
    }
}
pub(super) fn parameter_character_limit(operation: Operation, name: &str) -> usize {
    match name {
        "filter" => 256,
        _ => parameter_byte_limit(operation, name),
    }
}
pub(super) fn valid_parameter_text(operation: Operation, name: &str, value: &str) -> bool {
    value.len() <= parameter_byte_limit(operation, name)
        && value.chars().count() <= parameter_character_limit(operation, name)
        && !value.chars().any(char::is_control)
        && (operation != Operation::Archive || name != "ids" || {
            serde_json::from_str::<Vec<String>>(value).is_ok_and(|ids| {
                let mut unique = std::collections::HashSet::new();
                !ids.is_empty()
                    && ids.len() <= 128
                    && ids.iter().all(|id| {
                        !id.is_empty()
                            && id.len() <= 4096
                            && id
                                .bytes()
                                .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
                            && unique.insert(id)
                    })
            })
        })
        && (!matches!(name, "lease" | "selection")
            || uuid::Uuid::parse_str(value).is_ok_and(|id| id.to_string() == value))
        && (operation != Operation::WorkspaceState || name != "ids" || value.is_empty() || {
            let mut count = 0;
            value.split(',').all(|id| {
                count += 1;
                count <= 64
                    && !id.is_empty()
                    && id
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte))
            })
        })
}
pub(super) fn query_byte_limit(operation: Operation) -> usize {
    // 8192 ASCII ID bytes plus a 4096-byte relative path (up to 3x percent
    // encoding), escaped commas and generation; other API routes stay at 8 KiB.
    if matches!(operation, Operation::WorkspaceState | Operation::Files) {
        24 * 1024
    } else {
        8192
    }
}
fn parameter_limits(operation: Operation, name: &str, mut schema: Value) -> Value {
    if schema["type"] == "string" && schema.get("maxLength").is_none() {
        schema["maxLength"] = json!(parameter_character_limit(operation, name));
    }
    schema["x-legnasend-max-utf8-bytes"] = json!(parameter_byte_limit(operation, name));
    schema
}
pub(crate) const OPERATIONS: [Operation; 43] = [
    Operation::Status,
    Operation::Capabilities,
    Operation::Workspaces,
    Operation::Workspace,
    Operation::Files,
    Operation::Content,
    Operation::Requests,
    Operation::OpenApi,
    Operation::Upload,
    Operation::ManagedWorkspaces,
    Operation::ManageWorkspace,
    Operation::ApprovedSources,
    Operation::CreateWorkspace,
    Operation::Devices,
    Operation::Device,
    Operation::ScanDevices,
    Operation::SendSelection,
    Operation::SendTransfer,
    Operation::Transfers,
    Operation::Transfer,
    Operation::CancelTransfer,
    Operation::RetryTransfer,
    Operation::RemoveTransfer,
    Operation::InspectCache,
    Operation::CleanupCache,
    Operation::ReadSettings,
    Operation::UpdateSettings,
    Operation::ListKeys,
    Operation::CreateKey,
    Operation::ManageKey,
    Operation::KeyReceipt,
    Operation::ClearRequests,
    Operation::NativeTasks,
    Operation::ControlNativeTask,
    Operation::WorkspaceSend,
    Operation::WorkspaceState,
    Operation::PreparePreview,
    Operation::ClosePreview,
    Operation::Archive,
    Operation::PrepareArchive,
    Operation::CancelArchive,
    Operation::SourceEndNotices,
    Operation::RetrySourceEndNotice,
];
pub(crate) fn document(language: &str) -> Value {
    let zh = language.starts_with("zh");
    let hant = matches!(language, "zh-TW" | "zh-HK");
    let retention_days_description = if hant {
        "原生接收崩潰殘留保留期：-1 等待本機手動清理，0 在下次維護時不延遲清理，1–3650 為天數；變更策略本身不會執行清理。只處理已登記且非活動的原生殘留；不授予立即清理覆寫、不影響一般取消，也不代表可斷點續傳。"
    } else if zh {
        "原生接收崩溃残留保留期：-1 等待本地手动清理，0 在下次维护时不延迟清理，1–3650 为天数；更改策略本身不会执行清理。只处理已登记且非活动的原生残留；不授予立即清理覆盖、不影响正常取消，也不代表可断点续传。"
    } else {
        "Native receive crash-residue retention: -1 waits for explicit local cleanup, 0 adds no retention delay at the next maintenance, and 1–3650 is days. Changing policy does not itself clean files. Applies only to registered inactive native remnants; grants no immediate-cleanup override, does not alter normal cancellation and does not imply resume support."
    };
    let retention_days_schema = json!({"type":"integer","minimum":-1,"maximum":3650,"description":retention_days_description});
    let descriptions = if hant {
        [
            "服務狀態與非敏感配額",
            "目前已實作能力",
            "列出獲授權工作區",
            "讀取工作區描述",
            "分頁讀取檔案清單",
            "原始檔案與位元組範圍",
            "有界且已脫敏的請求記錄",
            "目前版本的接口契約",
            "持有上傳權限密鑰，串流建立檔案或空目錄（不覆寫）",
            "列出獲授權的持久工作區（含已停用項目）",
            "以代次比較更新、啟停、驗證或銷毀工作區設定",
            "列出本機已核准的來源參照，不顯示路徑",
            "從已核准來源建立已關閉的工作區",
            "列出已發現裝置",
            "讀取裝置與可用通道",
            "發起裝置掃描",
            "讀取本機選取的傳送檔案摘要",
            "將目前選取傳送到指定裝置",
            "列出此密鑰的傳送任務",
            "讀取傳送任務進度",
            "取消傳送任務",
            "重試已終止任務；完整重傳原選取內容，包含已完成檔案",
            "移除終止任務記錄",
            "盤點受管原生接收快取，不刪除檔案",
            "清理已核驗身分的非活動接收快取",
            "讀取不含秘密的應用設定",
            "按版本核驗修改一項受支援設定",
            "列出授權範圍內密鑰中繼資料",
            "建立不超出自身權限的密鑰，秘密只回傳一次",
            "暫停、恢復或撤銷其他密鑰",
            "查詢密鑰操作持久回執",
            "按實例與水位清除請求歷史",
            "讀取全部原生收發任務與速度",
            "按版本取消、接受、拒絕或移除原生任務",
            "將工作區內指定版本檔案傳送至已發現裝置",
            "核驗目錄狀態與最多 64 個可見檔案的版本",
            "建立文件提供者唯讀預覽租約",
            "關閉此授權的文件預覽租約",
            "串流下載工作區或選取項目的 ZIP",
            "為大型所選 ZIP 建立短期票據",
            "撤銷精確 ZIP 票據與其活動串流",
            "讀取來源結束通知狀態",
            "重試一項來源結束通知",
        ]
    } else if zh {
        [
            "服务状态与非敏感配额",
            "当前已实现能力",
            "列出已授权工作区",
            "读取工作区描述",
            "分页读取文件清单",
            "原始文件与字节范围",
            "有界且已脱敏的请求记录",
            "当前版本的接口契约",
            "持有上传权限密钥，流式创建文件或空目录（不覆盖）",
            "列出已授权的持久工作区（包含已停用项目）",
            "按代次比较更新、启停、验证或销毁工作区设置",
            "列出本机已批准的来源引用，不显示路径",
            "从已批准来源创建已关闭的工作区",
            "列出已发现设备",
            "读取设备及可用通道",
            "发起设备扫描",
            "读取本机选中的发送文件摘要",
            "将当前选择发送到指定设备",
            "列出此密钥的发送任务",
            "读取发送任务进度",
            "取消发送任务",
            "重试已终止任务；完整重传原选择内容，包括已完成文件",
            "移除终止任务记录",
            "盘点受管原生接收缓存，不删除文件",
            "清理已核验身份的非活动接收缓存",
            "读取不含秘密的应用设置",
            "按版本核验修改一项受支持设置",
            "列出授权范围内密钥元数据",
            "创建不超出自身权限的密钥，秘密只返回一次",
            "暂停、恢复或撤销其他密钥",
            "查询密钥操作持久回执",
            "按实例与水位清除请求历史",
            "读取全部原生收发任务及速度",
            "按版本取消、接受、拒绝或移除原生任务",
            "将工作区内指定版本文件发送至已发现设备",
            "核验目录状态与最多 64 个可见文件的版本",
            "创建文档提供程序只读预览租约",
            "关闭此授权的文档预览租约",
            "流式下载工作区或选中项目的 ZIP",
            "为大量选中项 ZIP 创建短期票据",
            "撤销精确 ZIP 票据及其活动流",
            "读取来源结束通知状态",
            "重试一项来源结束通知",
        ]
    } else {
        [
            "Service status and non-secret budgets",
            "Implemented capabilities",
            "List granted workspaces",
            "Read a workspace descriptor",
            "Read a file-list page",
            "Original file bytes and ranges",
            "Bounded redacted request records",
            "Current API contract",
            "Stream a new file or empty directory with an explicit upload key; never overwrite",
            "List granted persisted workspaces, including disabled entries",
            "Compare generation then update, enable, disable, validate or destroy workspace configuration",
            "List locally approved source references without paths",
            "Create a closed workspace from an approved source",
            "List discovered devices",
            "Read a device and available channels",
            "Start device discovery",
            "Read a summary of locally selected send files",
            "Send the current selection to a device",
            "List transfer tasks owned by this key",
            "Read transfer task progress",
            "Cancel a transfer task",
            "Retry a terminal task; resend the entire original selection, including completed files",
            "Remove a terminal transfer task record",
            "Inspect owned native receive caches without deleting",
            "Clean identity-verified inactive receive caches",
            "Read non-secret application settings",
            "Update one supported setting with a version check",
            "List key metadata within caller authority",
            "Create a bounded-authority key with one-time secret delivery",
            "Pause, resume or revoke another key",
            "Read a durable key operation receipt",
            "Clear request history through an observed watermark",
            "Read all native send and receive tasks and speeds",
            "Control native tasks with epoch and version checks",
            "Send versioned workspace files to a discovered device",
            "Validate directory state and versions of up to 64 visible files",
            "Prepare a read-only document-provider preview lease",
            "Close a document preview lease owned by this authority",
            "Stream a workspace or selected entries as ZIP",
            "Prepare a short-lived large-selection ZIP ticket",
            "Cancel one exact ZIP ticket and its active streams",
            "Read source-end notification states",
            "Retry one source-end notification",
        ]
    };
    let mut paths = serde_json::Map::new();
    for (i, operation) in OPERATIONS.into_iter().enumerate() {
        let mut parameters = vec![];
        for name in [
            "workspaceId",
            "fileId",
            "deviceId",
            "transferId",
            "keyId",
            "requestId",
            "taskId",
            "noticeId",
        ] {
            if operation.path().contains(&format!("{{{name}}}")) {
                parameters.push(
                    json!({"name":name,"in":"path","required":true,"schema":parameter_limits(operation,name,json!({"type":"string"}))}),
                );
            }
        }
        for name in operation.queries() {
            let schema = match *name {
                "generation" => json!({"type":"integer","minimum":1}),
                "after" => json!({"type":"integer","minimum":0,"default":0}),
                "limit" => json!({"type":"integer","minimum":1,"maximum":100,"default":50}),
                "action" => {
                    json!({"type":"string","enum":["update","enable","disable","validate","destroy","configure","password"]})
                }
                "visible" | "allowUpload" => json!({"type":"boolean"}),
                "directory" => json!({"type":"boolean","default":false}),
                "parent" if operation == Operation::Upload => {
                    json!({"type":"string","default":"","description":if hant {"文件提供者工作區的目標父目錄 ID；空值為根目錄。path 相對於此目錄，不能傳入 content URI。檔案系統工作區只能省略或為空。"} else if zh {"文档提供程序工作区的目标父目录 ID；空值为根目录。path 相对于此目录，不能传入 content URI。文件系统工作区只能省略或为空。"} else {"Target parent directory ID for document-provider workspaces; empty means the root. path is relative to this directory, never a content URI. Filesystem workspaces require this omitted or empty."}})
                }
                "preview" => json!({"type":"string","enum":["0","1"]}),
                "selection" => {
                    json!({"type":"string","format":"uuid","description":if hant {"同一授權建立的 ZIP 票據；不可與 path 或 ids 同時提供，不取代 Authorization。"} else if zh {"同一授权创建的 ZIP 票据，不与 path 或 ids 同时提供，不代替 Authorization。"} else {"ZIP ticket created by the same authority; cannot accompany path or ids and never replaces Authorization."}})
                }
                "lease" => {
                    json!({"type":"string","format":"uuid","description":if hant {"同一授權建立的預覽租約；不是下載續傳版本。"} else if zh {"同一授权创建的预览租约，不是下载续传版本。"} else {"Preview lease created by this authority; not a persistent download resume version."}})
                }
                "ids" if operation == Operation::Archive => {
                    json!({"type":"string","maxLength":8192,"description":if hant {"可省略；目前 path 下 1–128 個不重複直接子項 ID 的 JSON 陣列，並非檔案路徑。"} else if zh {"可省略；当前 path 下 1–128 个不重复直接子项 ID 的 JSON 数组，不是文件路径。"} else {"Optional JSON array of 1–128 unique direct-child IDs under path; not filesystem paths."}})
                }
                "ids" => {
                    json!({"type":"string","maxLength":8192,"pattern":"^(?:[A-Za-z0-9_-]+(?:,[A-Za-z0-9_-]+){0,63})?$","description":if hant {"目前目錄內最多 64 個標準 ASCII 檔案 ID，以逗號分隔，合計最多 8192 位元組；不是本機路徑或網址"} else if zh {"当前目录内最多 64 个标准 ASCII 文件 ID，以逗号分隔，合计最多 8192 字节；不是本地路径或网址"} else {"At most 64 comma-separated canonical ASCII file IDs in the requested directory, totaling at most 8192 bytes; not local paths or URLs"}})
                }
                "filter" => json!({"type":"string","maxLength":256,"default":""}),
                "anchor" => {
                    json!({"type":"string","maxLength":8192,"pattern":"^[A-Za-z0-9_-]+$","description":if hant {"目前目錄的檔案 ID；僅首個請求使用，後續沿用游標。有界定位位置，不是偏移或存取憑證。"} else if zh {"当前目录的文件 ID；仅首个请求使用，后续沿用游标。有界定位位置，不是偏移或访问凭证。"} else {"File ID within this directory, supplied on the initial request only; continue with returned cursors. Bounded anchor relocation, not a numeric offset or access credential."}})
                }
                "lang" => {
                    json!({"type":"string","enum":["en","zh-CN","zh-TW","zh-HK"],"default":"en"})
                }
                _ => json!({"type":"string"}),
            };
            parameters.push(
                json!({"name":name,"in":"query","required":*name=="generation" || operation==Operation::Upload && *name=="path" || operation==Operation::ManageWorkspace && *name=="action","schema":parameter_limits(operation,name,schema)}),
            );
        }
        if operation == Operation::Content {
            for name in ["Range", "If-Match"] {
                parameters.push(
                    json!({"name":name,"in":"header","required":false,"schema":parameter_limits(operation,name,json!({"type":"string"}))}),
                );
            }
        }
        let response_schema = match operation {
            Operation::Workspaces => json!({"$ref":"#/components/schemas/WorkspaceList"}),
            Operation::Workspace => json!({"$ref":"#/components/schemas/Workspace"}),
            Operation::Upload => json!({"$ref":"#/components/schemas/UploadReceipt"}),
            Operation::PrepareArchive => {
                json!({"$ref":"#/components/schemas/ArchiveSelectionTicket"})
            }
            Operation::CancelArchive => {
                json!({"type":"object","additionalProperties":false,"required":["cancelled"],"properties":{"cancelled":{"const":true}}})
            }
            Operation::PreparePreview => {
                json!({"$ref":"#/components/schemas/DocumentPreviewLease"})
            }
            Operation::ClosePreview => {
                json!({"type":"object","required":["closed"],"properties":{"closed":{"type":"boolean"}}})
            }
            Operation::Files => json!({"$ref":"#/components/schemas/FilePage"}),
            Operation::WorkspaceState => json!({"$ref":"#/components/schemas/WorkspaceState"}),
            Operation::Requests => json!({"$ref":"#/components/schemas/RequestPage"}),
            Operation::ListKeys => json!({"$ref":"#/components/schemas/KeyList"}),
            Operation::CreateKey | Operation::ManageKey | Operation::KeyReceipt => {
                json!({"$ref":"#/components/schemas/KeyResult"})
            }
            Operation::ReadSettings | Operation::UpdateSettings => {
                json!({"$ref":"#/components/schemas/HostSettings"})
            }
            Operation::InspectCache | Operation::CleanupCache => {
                json!({"$ref":"#/components/schemas/CacheReport"})
            }
            _ => json!({"type":"object"}),
        };
        let mut responses = json!({"200":{"description":"OK","content":{"application/json":{"schema":response_schema}}},"default":{"description":"Stable error code; no credentials or local paths","content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}},"429":{"description":"Fixed second/minute or concurrent-response budget","headers":{"Retry-After":{"schema":{"type":"integer","minimum":1}}},"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}}});
        if operation == Operation::Content {
            responses["200"] = json!({"description":"Original file","content":{"application/octet-stream":{"schema":{"type":"string","format":"binary"}}}});
            responses["206"] = json!({"description":"Requested byte range","headers":{"Content-Range":{"schema":{"type":"string"}},"ETag":{"schema":{"type":"string"}}},"content":{"application/octet-stream":{"schema":{"type":"string","format":"binary"}}}});
            responses["416"] = json!({"description":"Unsatisfiable byte range"});
        }
        let mut operation_value = json!({"operationId":operation.id(),"summary":descriptions[i],"x-legnasend-scope":serde_json::to_value(operation.scope()).unwrap(),"x-legnasend-max-query-bytes":query_byte_limit(operation),"parameters":parameters,"responses":responses});
        if operation == Operation::Archive {
            operation_value["responses"]["200"] = json!({"description":if hant {"逐檔串流 ZIP；不鏡像來源、不提供斷點續傳"} else if zh {"逐文件流式 ZIP，不镜像来源、不提供断点续传"} else {"Sequential streaming ZIP; no source mirror or range resume"},"content":{"application/zip":{"schema":{"type":"string","format":"binary"}}}});
        }
        if matches!(
            operation,
            Operation::PreparePreview | Operation::ClosePreview
        ) {
            let field = if operation == Operation::PreparePreview {
                "id"
            } else {
                "lease"
            };
            operation_value["requestBody"] = json!({"required":true,"content":{"application/json":{"schema":{"type":"object","additionalProperties":false,"required":[field],"properties":{field:{"type":"string","format":"uuid"}}}}}});
            operation_value["x-legnasend-max-body-bytes"] = json!(1024);
            operation_value["description"] = json!(if hant {
                "須 files.read 與目標工作區授權。僅文件提供者；最多八個描述符租約，120 秒閒置到期。HEAD/讀取續期；關閉、換代或撤權終止。固定同一 FD，不鏡像來源；ETag 是租約與元資料而非內容雜湊。"
            } else if zh {
                "须 files.read 与目标工作区授权。仅文档提供程序；最多八个描述符租约，120 秒闲置过期。HEAD/读取续期；关闭、换代或撤权终止。固定同一 FD，不镜像来源；ETag 是租约与元数据而非内容摘要。"
            } else {
                "Requires files.read and target workspace authority. Document providers only; eight descriptor leases, 120-second idle expiry renewed by HEAD/reads. Close, generation changes and revocation end the lease. Pins one FD without mirroring; ETag identifies lease/metadata, not a content digest."
            });
        }
        if matches!(
            operation,
            Operation::PrepareArchive | Operation::CancelArchive
        ) {
            operation_value["x-legnasend-max-body-bytes"] =
                json!(if operation == Operation::PrepareArchive {
                    2 * 1024 * 1024
                } else {
                    1024
                });
            operation_value["requestBody"] = json!({"required":true,"content":{"application/json":{"schema":{"$ref":if operation==Operation::PrepareArchive {"#/components/schemas/ArchiveSelectionPrepare"}else{"#/components/schemas/ArchiveSelectionCancel"}}}}});
            operation_value["description"] = json!(if hant {
                "須 files.read 與目標工作區授權。最多 20,000 個不重複直接子項 ID、2 MiB JSON；票據只保留選取資訊，不快取 ZIP。120 秒絕對期限只限制新下載准入，不中斷已開始的歸檔，同所有者與呼叫者最多四張，全域 64 張；取消會停止該票據的活動串流。遺失建立回應時不要自動重試。"
            } else if zh {
                "须 files.read 与目标工作区授权。最多 20,000 个不重复直接子项 ID、2 MiB JSON；票据仅保存选择信息，不缓存 ZIP。120 秒绝对期限仅限制新下载准入，不中断已开始的归档，同所有者与调用者最多四张，全局 64 张；取消停止该票据的活动流。丢失创建响应时不要自动重试。"
            } else {
                "Requires files.read and target workspace authority. Up to 20,000 unique direct-child IDs in 2 MiB JSON; tickets retain selectors, not ZIP bytes. The absolute 120-second admission deadline never renews and does not interrupt admitted archives; four per owner/caller, 64 globally. Cancellation stops this ticket's active streams. Do not automatically repeat a prepare whose response was lost."
            });
        }
        if operation.is_keys() {
            operation_value["x-legnasend-key-only"] = json!(true);
            operation_value["x-legnasend-workspace-grant"] = json!("*");
            operation_value["description"] = json!(if hant {
                "須有效密鑰明確授予 keys.manage 與 *。不可建立超出自身權限或到期時間的密鑰，不可管理自身。修改須版本與 requestId；相同請求重送只返回回執，不再返回秘密。未明結果以原 requestId 查詢，勿自動新增密鑰。"
            } else if zh {
                "须有效密钥明确授予 keys.manage 与 *。不可创建超出自身权限或到期时间的密钥，不可管理自身。修改须版本与 requestId；同请求重放仅返回回执，不再返回秘密。未知结果以原 requestId 查询，不自动创建新密钥。"
            } else {
                "Requires explicit keys.manage and wildcard * on a valid key. Grants and expiry cannot exceed caller authority; self-management is forbidden. Mutations require version and requestId. Replay returns only a durable receipt, never the secret again. Reconcile unknown outcomes with the original requestId."
            });
            if operation == Operation::CreateKey || operation == Operation::ManageKey {
                operation_value["requestBody"] = json!({"required":true,"content":{"application/json":{"schema":{"$ref":if operation==Operation::CreateKey {"#/components/schemas/KeyCreate"}else{"#/components/schemas/KeyManage"}}}}});
            }
            if operation == Operation::CreateKey {
                operation_value["responses"]["201"] = json!({"description":if hant {"密鑰已持久化並套用；秘密僅交付一次"} else if zh {"密钥已持久化并应用；秘密仅交付一次"} else {"Key persisted and applied; one-time secret delivery"},"content":{"application/json":{"schema":{"$ref":"#/components/schemas/KeyResult"}}}});
            }
            for code in [
                "400", "401", "403", "404", "409", "422", "500", "503", "504",
            ] {
                operation_value["responses"][code] = json!({"description":if hant {"密鑰生命週期、授權、版本或結果狀態錯誤；檢查穩定錯誤代碼，不含秘密或本機路徑"} else if zh {"密钥生命周期、授权、版本或结果状态错误；检查稳定错误代码，不含秘密或本地路径"} else {"Key lifecycle, authorization, version or outcome error; inspect the stable error code, never secrets or local paths"},"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}});
            }
        }
        if operation == Operation::ClearRequests {
            operation_value["description"] = json!(if hant {
                "須有效密鑰明確授予 requests.manage 與 *。只清除不超過已讀水位的記錄；實例與代次須一致。序號、實例、限流及活動傳輸不重置，保留清除標記與稍後完成的記錄。"
            } else if zh {
                "须有效密钥明确授予 requests.manage 与 *。只清除不超过已读水位的记录；实例与代次须一致。序号、实例、限流及活动传输不重置，保留清除标记与稍后完成的记录。"
            } else {
                "Requires explicit requests.manage and wildcard * on a valid key. Removes only records at or below the captured watermark after matching instance and generation. Does not reset sequence, instance, quotas or active transfers; retains a clear marker and later completions."
            });
            operation_value["x-legnasend-key-only"] = json!(true);
            operation_value["x-legnasend-workspace-grant"] = json!("*");
            operation_value["requestBody"] = json!({"required":true,"content":{"application/json":{"schema":{"$ref":"#/components/schemas/ClearRequest"}}}});
            operation_value["responses"]["200"] = json!({"description":"Cleared observed records only","content":{"application/json":{"schema":{"$ref":"#/components/schemas/ClearResult"}}}});
            operation_value["responses"]["409"] = json!({"description":if hant {"history_changed：歷史實例或代次已變更，重新讀取後再操作"} else if zh {"history_changed：历史实例或代次已改变，重新读取后再操作"} else {"history_changed"}});
        }
        if operation.is_host() {
            operation_value["x-legnasend-key-only"] = json!(true);
            operation_value["x-legnasend-workspace-grant"] = json!("*");
            for code in ["400", "401", "403", "404", "409", "422", "503", "504"] {
                operation_value["responses"][code] = json!({"description":if hant {"主機設定、快取、授權或結果狀態錯誤；檢查穩定錯誤代碼"} else if zh {"宿主设置、缓存、授权或结果状态错误；检查稳定错误代码"} else {"Host settings, cache, authorization or outcome error; inspect the stable error code"},"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}});
            }
            operation_value["description"] = json!(if hant {
                "須明確密鑰權限及全域 * 授權。快取僅處理已登記且核验身分的非活動暫存，未確認或使用中的內容保留；不接受本機路徑。設定只允許契約列出的欄位，不回傳秘密、路徑或密鑰。變更接手後逾時須重新查詢，不自動重試。"
            } else if zh {
                "须明确密钥权限及全局 * 授权。缓存仅处理已登记且核验身份的非活动暂存，未确认或使用中的内容保留；不接受本地路径。设置只允许契约列出的字段，不返回秘密、路径或密钥。变更接手后超时须重新查询，不自动重试。"
            } else {
                "Requires an explicit key scope and global * grant. Cache operations affect only registered, identity-verified inactive staging; unknown or active data is retained, and paths are never accepted. Settings expose only supported non-secret fields. After a claimed mutation times out, inspect current state; do not automatically retry."
            });
            if operation == Operation::UpdateSettings {
                operation_value["requestBody"] = json!({"required":true,"content":{"application/json":{"schema":{"type":"object","additionalProperties":false,"required":["version","field","value"],"properties":{"version":{"type":"string","pattern":"^[a-f0-9]{64}$"},"field":{"type":"string","enum":["alias","theme","locale","enableAnimations","autoFinish","createChecksums","verifyChecksums","receiveCacheRetentionDays"]},"value":{"oneOf":[{"type":"string","maxLength":120},{"type":"boolean"},retention_days_schema.clone()]}},"allOf":[{"if":{"properties":{"field":{"const":"receiveCacheRetentionDays"}},"required":["field"]},"then":{"properties":{"value":retention_days_schema.clone()}},"else":{"properties":{"value":{"oneOf":[{"type":"string","maxLength":120},{"type":"boolean"}]}}}}]}}}});
                operation_value["responses"]["409"] = json!({"description":if hant {"settings_busy 表示本機設定正在變更；settings_changed 表示版本已變更。重新讀取狀態，不自動重試。"} else if zh {"settings_busy 表示本地设置正在变更；settings_changed 表示版本已变更。重新读取状态，不自动重试。"} else {"settings_busy means a local settings change is in progress; settings_changed means the version changed. Read current state instead of automatically retrying."},"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}});
                operation_value["responses"]["503"] = json!({"description":if hant {"host_operation_failed：持久化、原生套用或還原失敗；重新讀取 receiveCacheRetention 的實際狀態。"} else if zh {"host_operation_failed：持久化、原生应用或恢复失败；重新读取 receiveCacheRetention 的实际状态。"} else {"host_operation_failed: persistence, native apply or restoration failed; read receiveCacheRetention again for the effective state."},"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}});
            }
        }
        if operation == Operation::Upload {
            operation_value["requestBody"] = json!({"required":true,"content":{"application/octet-stream":{"schema":{"type":"string","format":"binary"}}}});
            operation_value["description"] = json!(if hant {
                "只接受有效密鑰的 files.upload 權限與工作區授權；匿名或瀏覽器密碼不授予 API 寫入。與瀏覽器 allowUpload 獨立。要求精確 Content-Length；空目錄使用 directory=true 與零位元組。代次、密鑰或工作區撤銷中止未發佈內容。失敗後重新傳送完整檔案。"
            } else if zh {
                "仅接受有效密钥的 files.upload 权限与工作区授权；匿名或浏览器密码不授予 API 写入。与浏览器 allowUpload 独立。要求准确 Content-Length；空目录使用 directory=true 和零字节。代次、密钥或工作区撤销中止未发布内容。失败后重新传送完整文件。"
            } else {
                "Requires a valid key with files.upload and a matching workspace grant, never anonymous or browser-cookie authorization. Independent of browser allowUpload. Exact Content-Length is required; directory=true creates an empty directory with a zero-byte body. Generation/key/workspace revocation aborts unpublished data. Retry sends the whole file."
            });
            operation_value["parameters"].as_array_mut().unwrap().push(json!({"name":"Content-Length","in":"header","required":true,"schema":{"type":"integer","minimum":0}}));
            let success = operation_value["responses"]
                .as_object_mut()
                .unwrap()
                .remove("200")
                .unwrap();
            operation_value["responses"]["201"] = success;
            operation_value["responses"]["201"]["description"] = json!(if hant {
                "已建立並發佈"
            } else if zh {
                "已创建并发布"
            } else {
                "Created and published"
            });
            for (code, en, cn, tw) in [
                (
                    "400",
                    "Invalid path or body",
                    "路径或请求正文无效",
                    "路徑或請求正文無效",
                ),
                (
                    "401",
                    "Invalid, expired or revoked key",
                    "密钥无效、过期或已撤销",
                    "密鑰無效、過期或已撤銷",
                ),
                (
                    "403",
                    "Missing upload or workspace grant",
                    "缺少上传或工作区权限",
                    "缺少上傳或工作區權限",
                ),
                (
                    "404",
                    "Workspace unavailable",
                    "工作区不可用",
                    "工作區不可用",
                ),
                (
                    "409",
                    "Existing destination or stale generation",
                    "目标已存在或代次失效",
                    "目標已存在或代次失效",
                ),
                (
                    "411",
                    "Exact Content-Length required",
                    "需要准确的 Content-Length",
                    "需要準確的 Content-Length",
                ),
                (
                    "415",
                    "application/octet-stream required",
                    "需要 application/octet-stream",
                    "需要 application/octet-stream",
                ),
            ] {
                operation_value["responses"][code] = json!({"description":if hant { tw } else if zh { cn } else { en },"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}});
            }
        }
        if matches!(
            operation,
            Operation::ManagedWorkspaces
                | Operation::ApprovedSources
                | Operation::ManageWorkspace
                | Operation::CreateWorkspace
        ) {
            operation_value["description"] = json!(if hant {
                "僅有效密鑰 workspaces.manage 可用，且限授權工作區；主機持久化後才確認。接手前撤銷會取消；主機接手後即使斷線仍可完成。outcome_unknown 表示結果未知，先讀取清單核對代次，請勿自動重試。destroy 只移除分享設定，不刪本機檔案。"
            } else if zh {
                "仅有效密钥 workspaces.manage 可用，且限授权工作区；宿主持久化后才确认。接手前撤销会取消；宿主接手后即使断线仍可完成。outcome_unknown 表示结果未知，先读取清单核对代次，请勿自动重试。destroy 仅删除共享配置，不删除本地文件。"
            } else {
                "Requires an explicit workspaces.manage key and matching workspace grant. Host persistence precedes success. Revocation cancels before claim; a claimed mutation may finish after disconnect. outcome_unknown requires refreshing the catalog and comparing generation, never automatic retry. Destroy removes sharing configuration, not local files."
            });
            operation_value["responses"]["200"]["content"]["application/json"]["schema"] =
                if operation == Operation::ManagedWorkspaces {
                    json!({"$ref":"#/components/schemas/ManagedWorkspaceList"})
                } else if operation == Operation::ApprovedSources {
                    json!({"$ref":"#/components/schemas/ApprovedSourceList"})
                } else {
                    json!({"$ref":"#/components/schemas/ManagementResult"})
                };
            for code in ["400", "401", "403", "404", "409", "422", "503", "504"] {
                operation_value["responses"][code] = json!({"description":if hant { "主機、授權、代次或結果狀態；參閱穩定錯誤代碼" } else if zh { "宿主、授权、代次或结果状态；参阅稳定错误代码" } else { "Host, authorization, generation or outcome state; inspect stable error code" },"content":{"application/json":{"schema":{"$ref":"#/components/schemas/ManagementResult"}}}});
            }
        }
        if matches!(
            operation,
            Operation::ManageWorkspace | Operation::CreateWorkspace
        ) {
            operation_value["requestBody"] = json!({"required":operation==Operation::CreateWorkspace,"content":{"application/json":{"schema":if operation==Operation::CreateWorkspace { json!({"$ref":"#/components/schemas/CreateWorkspaceBody"}) } else { json!({"oneOf":[{"$ref":"#/components/schemas/ConfigureWorkspaceBody"},{"$ref":"#/components/schemas/WorkspacePasswordBody"}]}) }}}});
            operation_value["x-legnasend-body-only"] =
                json!(["sourceId", "password", "clear", "slug"]);
            operation_value["x-legnasend-no-retry"] = json!(true);
        }
        if operation.is_transfer() {
            operation_value["description"] = json!(if hant {
                "需要明確的專用密鑰權限及全域 * 授權；匿名、工作區密碼及單工作區密鑰皆無效。裝置與通道 ID 來自本機發現，檔案只能來自本機目前選取；拒絕任意路徑或主機。任務僅對建立它的密鑰可見。ID、選取版本與冪等收據在應用程式重啟後失效。send/retry 必須帶 requestId；重複同一請求返回原任務，相同 ID 不同參數回應 409。重試為原始協定的完整檔案重傳，並非位元組續傳。接手前撤銷會取消；接手後可能繼續，outcome_unknown 時以相同 requestId 核對，不要使用新 ID 重送。scan/send/retry 的 202 只表示接手，不表示發現或傳送成功。"
            } else if zh {
                "需要明确的专用密钥权限及全局 * 授权；匿名、工作区密码及单工作区密钥均无效。设备与通道 ID 来自本机发现，文件只能来自本机当前选择；拒绝任意路径或主机。任务仅对创建它的密钥可见。ID、选择版本及幂等回执在应用重启后失效。send/retry 必须带 requestId；重复相同请求返回原任务，相同 ID 不同参数返回 409。重试是原始协议的整文件重传，并非字节续传。接手前撤销会取消；接手后可能继续，outcome_unknown 时以相同 requestId 核对，不要使用新 ID 重送。scan/send/retry 的 202 仅表示接手，不代表发现或传送成功。"
            } else {
                "Requires an explicitly granted dedicated scope and wildcard * workspace grant on a valid key. Anonymous access, workspace passwords and single-workspace keys do not authorize these operations. Devices/channels must come from local discovery; files must come from the current local selection, never caller paths or hosts. Tasks are isolated by creating key. IDs, selection versions and idempotency receipts expire on app restart. send/retry require requestId: identical replay returns the original task; changed arguments with the same ID return 409. Retry uses whole-file original-protocol transfer, not byte resume. Revocation cancels before claim; claimed work can continue. On outcome_unknown, reconcile with the same requestId, never enqueue using a new ID. A 202 for scan/send/retry acknowledges acceptance, not discovery or delivery success."
            });
            let name = match operation {
                Operation::Devices => "DeviceList",
                Operation::Device => "DeviceResult",
                Operation::ScanDevices => "ScanResult",
                Operation::SendSelection => "SendSelection",
                Operation::SendTransfer | Operation::RetryTransfer | Operation::WorkspaceSend => {
                    "TransferReceipt"
                }
                Operation::Transfers => "TransferList",
                Operation::Transfer | Operation::CancelTransfer => "TransferResult",
                Operation::RemoveTransfer => "TransferRemoval",
                _ => unreachable!(),
            };
            let status = if matches!(
                operation,
                Operation::ScanDevices
                    | Operation::SendTransfer
                    | Operation::RetryTransfer
                    | Operation::WorkspaceSend
            ) {
                "202"
            } else {
                "200"
            };
            operation_value["responses"]
                .as_object_mut()
                .unwrap()
                .remove("200");
            operation_value["responses"][status] = json!({"description":if status=="202" {"Accepted, not completed"}else{"OK"},"content":{"application/json":{"schema":{"$ref":format!("#/components/schemas/{name}")}}}});
            operation_value["x-legnasend-workspace-grant"] = json!("*");
            operation_value["x-legnasend-key-only"] = json!(true);
            if operation == Operation::RetryTransfer {
                operation_value["x-legnasend-additional-scopes"] = json!(["transfers.send"]);
                let extra = if hant {
                    " 重試同時要求 transfers.control 與 transfers.send 權限，撤除傳送權限即阻止新傳送。"
                } else if zh {
                    " 重试同时要求 transfers.control 和 transfers.send 权限，移除发送权限即阻止新传送。"
                } else {
                    " Retry requires both transfers.control and transfers.send; removing send permission prevents new transmissions."
                };
                operation_value["description"] = json!(format!(
                    "{}{extra}",
                    operation_value["description"].as_str().unwrap()
                ));
            }

            if matches!(
                operation,
                Operation::SendTransfer | Operation::RetryTransfer
            ) {
                let name = if operation == Operation::SendTransfer {
                    "SendTransferBody"
                } else {
                    "RetryTransferBody"
                };
                operation_value["requestBody"] = json!({"required":true,"content":{"application/json":{"schema":{"$ref":format!("#/components/schemas/{name}")}}}});
                operation_value["x-legnasend-max-body-bytes"] = json!(8192);
            }
            for code in [
                "400", "401", "403", "404", "409", "413", "415", "422", "503", "504",
            ] {
                operation_value["responses"][code] = json!({"description":if hant {"穩定的授權、驗證、主機或任務狀態錯誤"} else if zh {"稳定的授权、校验、宿主或任务状态错误"} else {"Stable authorization, validation, host or task-state error"},"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}});
            }
        }
        if operation == Operation::WorkspaceSend {
            operation_value["description"] = json!(if hant {
                "須有效密鑰 transfers.send 與 files.read 及全域 * 授權。只接受目前服務 instanceId、工作區 generation、最多 128 個清單 fileId 與完整帶引號的 ETag version，以及已發現裝置／通道 ID。拒絕任意路徑、網址、IP 或隱式資料夾遞迴。主機先驗證並快照來源，再以原始 LocalSend 協定入列；不改動 UI 選取。202 僅表示已入列；同 requestId 重送核對原收據，禁止結果未知時換 ID。"
            } else if zh {
                "须有效密钥 transfers.send 和 files.read 及全局 * 授权。仅接受当前服务 instanceId、工作区 generation、最多 128 个清单 fileId 与完整带引号的 ETag version，以及已发现设备／通道 ID。拒绝任意路径、网址、IP 或隐式文件夹递归。宿主先验证并快照来源，再以原始 LocalSend 协议入队；不改变 UI 选择。202 仅表示已入队；相同 requestId 重放核对原回执，禁止结果未知时换 ID。"
            } else {
                "Requires transfers.send and files.read plus wildcard * on a valid key. Uses the current service instanceId, workspace generation, at most 128 listed file IDs with exact quoted ETag versions and discovered device/channel IDs. No paths, URLs, IPs or implicit folder recursion. Host verifies and snapshots sources before queuing the original LocalSend protocol, leaving UI selection untouched. 202 means queued, not delivered. Replay the same requestId to reconcile; never use a new ID after an unknown outcome."
            });
            operation_value["x-legnasend-additional-scopes"] = json!(["files.read"]);
            operation_value["x-legnasend-max-body-bytes"] = json!(65536);
            operation_value["requestBody"] = json!({"required":true,"content":{"application/json":{"schema":{"$ref":"#/components/schemas/WorkspaceSendBody"}}}});
        }
        if operation.is_native_tasks() {
            operation_value["description"] = json!(if hant {
                "須有效密鑰明確授予 nativeTasks.read 或 nativeTasks.control 與 *。此介面讀取所有本機原生任務，並非僅本密鑰的傳送記錄。控制必須使用剛讀取的 epoch、id、version；變更後須重新讀取，禁止自動重試。接受沿用本機目的地與檔名；remove 僅移除終態記錄，不刪檔案。未提供暫停與續傳。"
            } else if zh {
                "须有效密钥明确授予 nativeTasks.read 或 nativeTasks.control 与 *。本接口读取全部本机原生任务，不限此密钥创建的发送记录。控制必须使用刚读取的 epoch、id、version；变更后须重新读取，禁止自动重试。接受沿用本机目的地与文件名；remove 仅移除终态记录，不删文件。不提供暂停与续传。"
            } else {
                "Requires explicit nativeTasks.read or nativeTasks.control and wildcard * on a valid key. Reads all native tasks, not just tasks created by this key. Controls require the latest epoch, id and version. Refresh after changes; never retry automatically. Accept uses local destination and file names. Remove clears terminal records, not files. No pause or resume operation."
            });
            operation_value["x-legnasend-key-only"] = json!(true);
            operation_value["x-legnasend-workspace-grant"] = json!("*");
            operation_value["responses"]["200"]["content"]["application/json"]["schema"] = json!({"$ref":match operation { Operation::NativeTasks => "#/components/schemas/NativeTaskList", Operation::SourceEndNotices => "#/components/schemas/SourceEndNoticeList", Operation::RetrySourceEndNotice => "#/components/schemas/SourceEndRetryResult", _ => "#/components/schemas/NativeTaskControlResult" }});
            for code in [
                "400", "401", "403", "404", "409", "413", "415", "422", "503", "504",
            ] {
                operation_value["responses"][code] = json!({"description":if hant {"原生任務授權、版本或派發狀態錯誤；檢查穩定代碼"} else if zh {"原生任务授权、版本或派发状态错误；检查稳定代码"} else {"Native task authorization, version or dispatch error; inspect stable code"},"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Error"}}}});
            }
            if operation == Operation::ControlNativeTask {
                operation_value["x-legnasend-max-body-bytes"] = json!(8192);
                operation_value["x-legnasend-no-retry"] = json!(true);
                operation_value["requestBody"] = json!({"required":true,"content":{"application/json":{"schema":{"$ref":"#/components/schemas/NativeTaskControl"}}}});
            }
        }
        if matches!(
            operation,
            Operation::SourceEndNotices | Operation::RetrySourceEndNotice
        ) {
            operation_value["description"] = json!(if hant {
                "須有效密鑰、對應 nativeTasks.read/control 與 *。只提供脫敏通知，不暴露路徑或清理憑證。重試使用最新 version 與固定 requestId；相同請求可核對未知結果，變更內容須新 ID。accepted 僅表示已排程，不代表遠端檔案已清理。離線、共用來源、活動接收及未知結果保持獨立狀態；已發佈檔案不刪除。 可選 cleanup 僅在接收端確認的終態中提供回執編號、實際移除暫存檔案數與邏輯位元組數；缺失表示沒有數量回執，不表示移除零檔案。該位元組數不是實際釋放磁碟空間的測量值。"
            } else if zh {
                "须有效密钥、对应 nativeTasks.read/control 与 *。仅提供脱敏通知，不暴露路径或清理凭证。重试使用最新 version 与固定 requestId；相同请求可核对未知结果，变更内容须新 ID。accepted 仅表示已排程，不代表远端文件已清理。离线、共享来源、活动接收及未知结果保持独立状态；已发布文件不删除。 可选 cleanup 仅在接收端确认的终态中提供回执编号、实际移除临时文件数与逻辑字节数；缺失表示没有数量回执，不表示移除零文件。该字节数不是实际释放磁盘空间的测量值。"
            } else {
                "Requires a valid key, the matching nativeTasks.read/control scope and *. Returns redacted notices, never paths or cleanup credentials. Retry uses the latest version and a stable requestId; replay the exact request to reconcile an unknown outcome, use a new ID for changed input. accepted means scheduled, not remotely cleaned. Offline, shared-source, active-receive and unknown outcomes remain distinct; published files are preserved. Optional cleanup carries the receiver receipt ID, actual temporary-file removal count and logical unlinked bytes only for confirmed terminal outcomes; absence means no itemized receipt, not zero removal. These bytes do not measure physical disk space reclaimed."
            });
            if operation == Operation::RetrySourceEndNotice {
                operation_value["x-legnasend-max-body-bytes"] = json!(8192);
                operation_value["requestBody"] = json!({"required":true,"content":{"application/json":{"schema":{"$ref":"#/components/schemas/SourceEndRetry"}}}});
            }
        }
        let mut item = if operation.is_post() {
            json!({"post":operation_value})
        } else {
            json!({"get":operation_value})
        };
        if matches!(operation, Operation::Content | Operation::Archive) {
            operation_value["operationId"] = json!(if operation == Operation::Content {
                "headContent"
            } else {
                "headWorkspaceArchive"
            });
            for (_, response) in operation_value["responses"].as_object_mut().unwrap() {
                response.as_object_mut().unwrap().remove("content");
            }
            item["head"] = operation_value;
        }
        paths.insert(operation.path().into(), item);
    }
    let mut document = json!({"openapi":"3.1.0","info":{"title":"LegnaSend Integration API","version":"1.0.0","description":if hant{"依權限提供讀取、密鑰上傳、工作區管理、主機設定與快取、密鑰及原生任務控制。匿名授權獨立且不授予寫入權限；LocalSend 原始傳送協定保持不變。"}else if zh{"按权限提供读取、密钥上传、工作区管理、宿主设置与缓存、密钥及原生任务控制。匿名授权独立且不授予写入权限；LocalSend 原始传送协议保持不变。"}else{"Scoped reads, keyed uploads, workspace management, host settings and cache operations, key management and native-task controls. Anonymous grants are independent and never authorize writes; the original LocalSend transfer protocol remains unchanged."}},"servers":[{"url":PREFIX}],"security":[{"bearerAuth":[]}],"x-legnasend-anonymous-policy":"When business authentication is disabled, anonymous grants apply only to visible, unprotected workspaces. A supplied invalid token never falls back to anonymous.","paths":paths,"components":{"securitySchemes":{"bearerAuth":{"type":"http","scheme":"bearer","bearerFormat":"ls1 key"}},"schemas":{
        "Error":{"type":"object","required":["error"],"properties":{"error":{"type":"object","required":["code","requestId"],"properties":{"code":{"type":"string"},"requestId":{"type":"string"},"reason":{"type":["string","null"]}}}}},
        "Workspace":{"type":"object","required":["id","name","slug","generation","readOnly","protected"],"properties":{"id":{"type":"string"},"name":{"type":"string"},"slug":{"type":"string"},"generation":{"type":"integer"},"readOnly":{"type":"boolean"},"allowUpload":{"type":"boolean"},"protected":{"type":"boolean"}}},
        "UploadReceipt":{"type":"object","required":["path","size","sha256","directory"],"properties":{"path":{"type":"string"},"parent":{"type":"string","description":if zh {"文档工作区返回原请求的父目录 ID；文件系统不增加此字段。"} else {"Document workspaces echo the requested parent ID; absent for filesystem uploads."}},"size":{"type":"integer","minimum":0},"sha256":{"type":"string","pattern":"^[a-f0-9]{64}$"},"directory":{"type":"boolean"}}},
        "WorkspaceList":{"type":"object","required":["workspaces"],"properties":{"workspaces":{"type":"array","items":{"$ref":"#/components/schemas/Workspace"}}}},
        "Entry":{"type":"object","required":["id","name","directory","size"],"properties":{"id":{"type":"string"},"name":{"type":"string"},"directory":{"type":"boolean"},"size":{"type":"integer","minimum":0}}},
        "FilePage":{"type":"object","required":["entries","cursor","generation","path","scanned"],"properties":{"entries":{"type":"array","items":{"$ref":"#/components/schemas/Entry"}},"cursor":{"type":["string","null"]},"generation":{"type":"integer"},"path":{"type":"string"},"scanned":{"type":"integer"},"stamp":{"type":"string","pattern":"^[a-fA-F0-9]{64}$","description":if hant {"不透明目錄中繼資料驗證值，並非內容雜湊"} else if zh {"不透明目录元数据校验值，并非内容哈希"} else {"Opaque directory metadata validator; not a content hash"}}}},
        "RequestPage":{"type":"object","required":["entries","next","oldest","latest"],"properties":{"entries":{"type":"array","items":{"type":"object"}},"next":{"type":"integer"},"oldest":{"type":["integer","null"]},"latest":{"type":"integer"}}}
    }}});
    let schemas = document["components"]["schemas"].as_object_mut().unwrap();
    schemas.get_mut("Workspace").unwrap()["properties"]["backend"] =
        json!({"type":"string","enum":["filesystem","documents"]});
    let mut capability_properties = serde_json::Map::new();
    for name in ["archive", "capture", "events", "preview", "resume", "state"] {
        capability_properties.insert(name.into(), json!({"type":"boolean"}));
    }
    schemas.get_mut("Workspace").unwrap()["properties"]["capabilities"] = json!({
        "type":"object", "properties":capability_properties,
        "description": if hant {"依工作區來源提供能力；文件提供者支援唯讀列表、單次下載、明確預覽租約、有界 ZIP 及目前目錄狀態提示；不代表持久下載續傳。"}
            else if zh {"按工作区来源提供能力；文档提供程序支持只读列表、单次下载、显式预览租约、有界 ZIP 及当前目录状态提示，不代表持久下载续传。"}
            else {"Source-specific capabilities. Document providers support read-only listing, single-request downloads, explicit preview leases, bounded ZIP and current-directory state hints, not persistent download resume."}
    });
    schemas.get_mut("Entry").unwrap()["properties"]["size"] = json!({
        "type":["integer","null"], "minimum":0,
        "description": if hant {"文件提供者可能回傳未知大小 null，不是零位元組。"}
            else if zh {"文档提供程序可能返回未知大小 null，不是零字节。"}
            else {"Document providers may return null for unknown size; this does not mean zero bytes."}
    });
    schemas.get_mut("Entry").unwrap()["properties"]["downloadable"] = json!({"type":"boolean"});
    schemas.get_mut("FilePage").unwrap()["properties"]["stamp"]
        .as_object_mut()
        .unwrap()
        .remove("pattern");
    schemas.insert("ArchiveSelectionPrepare".into(),json!({"type":"object","additionalProperties":false,"required":["path","ids"],"properties":{"path":{"type":"string","maxLength":4096,"x-legnasend-max-utf8-bytes":4096},"ids":{"type":"array","minItems":1,"maxItems":20000,"uniqueItems":true,"items":{"type":"string","minLength":1,"maxLength":4096,"x-legnasend-max-utf8-bytes":4096}}}}));
    schemas.insert("ArchiveSelectionCancel".into(),json!({"type":"object","additionalProperties":false,"required":["selection"],"properties":{"selection":{"type":"string","format":"uuid"}}}));
    schemas.insert("ArchiveSelectionTicket".into(),json!({"type":"object","additionalProperties":false,"required":["selection","selectedEntries","expiresIn","downloadUrl"],"properties":{"selection":{"type":"string","format":"uuid"},"selectedEntries":{"type":"integer","minimum":1,"maximum":20000},"expiresIn":{"type":"integer","minimum":1,"maximum":120},"downloadUrl":{"type":"string","description":if hant {"同源集成 API URL；每次 HEAD/GET 仍需同一 Authorization，不含憑據。"} else if zh {"同源集成 API URL，每次 HEAD/GET 仍需同一 Authorization，不含凭据。"} else {"Same-origin integration API URL; every HEAD/GET still requires the same Authorization. Contains no credentials."}}}}));
    schemas.insert("DocumentPreviewLease".into(),json!({"type":"object","additionalProperties":false,"required":["url","size","etag","mime","lease"],"properties":{"url":{"type":"string","description":if hant {"同源集成 API 內容網址，包含代次與租約；後續請求仍須 Authorization。"} else if zh {"同源集成 API 内容网址，包含代次与租约，后续请求仍须 Authorization。"} else {"Same-origin integration content URL with generation and lease; Authorization is still required."}},"size":{"type":"integer","minimum":0,"maximum":9007199254740991_u64},"etag":{"type":"string","pattern":r#"^"[a-f0-9]{64}"$"#},"mime":{"type":"string","maxLength":256},"lease":{"type":"string","format":"uuid"}}}));
    schemas.insert("WorkspaceState".into(), json!({"type":"object","required":["generation","path","stamp","entries","missing"],"properties":{"generation":{"type":"integer"},"path":{"type":"string"},"stamp":{"type":"string"},"missing":{"type":"array","maxItems":64,"items":{"type":"string"}},"entries":{"type":"array","maxItems":64,"items":{"type":"object","required":["id","size","directory","version"],"properties":{"id":{"type":"string"},"size":{"type":"integer"},"directory":{"type":"boolean"},"version":{"type":["string","null"]}}}}}}));
    let filesystem_state = schemas.get("WorkspaceState").unwrap().clone();
    schemas.insert("WorkspaceState".into(), json!({"oneOf":[filesystem_state,{"type":"object","required":["generation","path","refreshFromStart","watchId","stamp","observing"],"properties":{"generation":{"type":"integer"},"path":{"type":"string"},"refreshFromStart":{"const":true},"watchId":{"type":"string","format":"uuid"},"stamp":{"type":"string"},"observing":{"type":"boolean"}},"description":if hant {"文件提供者目前目錄的短期變更提示；不是內容版本或增量清單。"} else if zh {"文档提供程序当前目录的短期变化提示，不是内容版本或增量清单。"} else {"Short-lived document-provider current-directory invalidation hint; not a content version or incremental file list."}}]}));
    let content_description = if hant {
        "持久保存的有限範圍中繼資料觀察狀態，不是全目錄內容雜湊或檔案驗證器。啟動、待持久化或不確定時為 unknown；通知僅提示重新核驗。下載仍使用逐檔 ETag/If-Match。"
    } else if zh {
        "持久保存的有限范围元数据观察状态，不是全目录内容哈希或文件校验值。启动、待持久化或不确定时为 unknown；通知仅提示重新核验。下载仍使用逐文件 ETag/If-Match。"
    } else {
        "Persisted metadata observations over bounded scopes, not a whole-tree hash or file validator. Startup, pending persistence and uncertainty report unknown; notifications only request revalidation. Downloads still use per-file ETag/If-Match."
    };
    let content_properties = json!({
        "contentEpoch":{"type":["string","null"],"format":"uuid","description":content_description},
        "contentRevision":{"type":"integer","minimum":0,"maximum":9007199254740991_u64,"description":content_description},
        "contentKnowledge":{"type":"string","enum":["observed","unknown"],"description":content_description},
        "lastObservedAt":{"type":["integer","null"],"minimum":0,"maximum":9007199254740991_u64,"description":if hant {"上次已持久保存的觀察時間，Unix 毫秒；null 表示尚無確認值。"} else if zh {"上次已持久保存的观察时间，Unix 毫秒；null 表示尚无确认值。"} else {"Last persisted observation time in Unix milliseconds; null when no value is confirmed."}},
        "dirty":{"type":"boolean","description":content_description}
    });
    for name in ["Workspace", "FilePage"] {
        let schema = schemas.get_mut(name).unwrap();
        for (field, property) in content_properties.as_object().unwrap() {
            schema["properties"][field] = property.clone();
            schema["required"]
                .as_array_mut()
                .unwrap()
                .push(json!(field));
        }
    }
    for schema in schemas.get_mut("WorkspaceState").unwrap()["oneOf"]
        .as_array_mut()
        .unwrap()
    {
        for (field, property) in content_properties.as_object().unwrap() {
            schema["properties"][field] = property.clone();
            schema["required"]
                .as_array_mut()
                .unwrap()
                .push(json!(field));
        }
    }
    for (name, schema) in [
        ("offset", json!({"type":"integer","minimum":0})),
        ("anchorPending", json!({"type":"boolean"})),
        ("anchorMissing", json!({"type":"boolean"})),
    ] {
        schemas.get_mut("FilePage").unwrap()["properties"][name] = schema;
    }
    schemas.get_mut("FilePage").unwrap()["properties"]["filter"] =
        json!({"type":"string","maxLength":256});
    schemas.get_mut("FilePage").unwrap()["required"]
        .as_array_mut()
        .unwrap()
        .push(json!("filter"));
    schemas.insert("WorkspaceSendBody".into(),json!({"type":"object","additionalProperties":false,"required":["instanceId","generation","deviceId","requestId","files"],"properties":{"instanceId":{"type":"string","format":"uuid"},"generation":{"type":"integer","minimum":1},"deviceId":{"type":"string","format":"uuid"},"channelId":{"type":"string","format":"uuid"},"requestId":{"type":"string","format":"uuid"},"files":{"type":"array","minItems":1,"maxItems":128,"items":{"type":"object","additionalProperties":false,"required":["id","version"],"properties":{"id":{"type":"string","maxLength":4096},"version":{"type":"string","maxLength":256}}}}}}));
    schemas.insert("SourceEndNotice".into(), json!({"type":"object","additionalProperties":false,"required":["id","version","peerLabel","name","state","attempts","updatedAtUnixMs"],"properties":{"id":{"type":"string","format":"uuid"},"version":{"type":"string","format":"uuid"},"peerLabel":{"type":"string","maxLength":120},"name":{"type":"string","maxLength":255},"state":{"enum":["pending","waitingPeer","sharedSource","busy","authorizationRequired","removed","publishedPreserved","unknown","expired","unsupported","superseded"]},"attempts":{"type":"integer","minimum":0},"updatedAtUnixMs":{"type":"integer","minimum":0}}}));
    schemas.insert("SourceEndCleanupReceipt".into(), json!({
        "type":"object","additionalProperties":false,
        "description":if hant {"接收端確認移除的暫存檔案數量與邏輯位元組數，不代表實際釋放的磁碟空間；已發布檔案保留。未確認的結果與舊通知不附帶此回執。回執編號不具有清理授權能力。"} else if zh {"接收端确认移除的临时文件数量与逻辑字节数，不代表实际释放的磁盘空间；已发布文件保留。未确认的结果与旧通知不附带此回执。回执编号不具有清理授权能力。"} else {"Receiver-confirmed removal of temporary files. Logical unlinked bytes are not measured physical disk space reclaimed; published files are preserved. Absent on unconfirmed outcomes and older stored notices. Receipt IDs carry no cleanup authority."},
        "required":["receiptId","removedFiles","unlinkedBytes"],
        "properties":{
            "receiptId":{"type":"string","format":"uuid"},
            "removedFiles":{"type":"integer","minimum":0,"maximum":2},
            "unlinkedBytes":{"type":"integer","minimum":0}
        },
        "allOf":[{"if":{"properties":{"removedFiles":{"const":0}}},"then":{"properties":{"unlinkedBytes":{"const":0}}}}]
    }));
    schemas.get_mut("SourceEndNotice").unwrap()["properties"]["cleanup"] =
        json!({"$ref":"#/components/schemas/SourceEndCleanupReceipt"});
    schemas.get_mut("SourceEndNotice").unwrap()["allOf"] = json!([{
        "if":{"required":["cleanup"]},
        "then":{"properties":{"state":{"enum":["removed","publishedPreserved"]}}}
    }]);
    schemas.insert("SourceEndNoticeList".into(), json!({"type":"object","additionalProperties":false,"required":["notices","truncated"],"properties":{"notices":{"type":"array","maxItems":512,"items":{"$ref":"#/components/schemas/SourceEndNotice"}},"truncated":{"type":"boolean"}}}));
    schemas.insert("SourceEndRetry".into(), json!({"type":"object","additionalProperties":false,"required":["version","requestId"],"properties":{"version":{"type":"string","format":"uuid"},"requestId":{"type":"string","format":"uuid"}}}));
    schemas.insert("SourceEndRetryResult".into(), json!({"type":"object","additionalProperties":false,"required":["notice","accepted"],"properties":{"notice":{"$ref":"#/components/schemas/SourceEndNotice"},"accepted":{"const":true}}}));
    schemas.insert("NativeTaskControl".into(), json!({"type":"object","additionalProperties":false,"required":["epoch","version","action"],"properties":{"epoch":{"type":"string","format":"uuid"},"version":{"type":"string","format":"uuid"},"action":{"type":"string","enum":["cancel","accept","reject","remove"]}}}));
    schemas.insert("NativeTask".into(), json!({"type":"object","additionalProperties":false,"required":["id","version","direction","phase","fileCount","totalBytes","transferredBytes","bytesPerSecond","actions"],"properties":{"id":{"type":"string","format":"uuid"},"version":{"type":"string","format":"uuid"},"direction":{"enum":["send","receive"]},"phase":{"enum":["queued","preparing","waiting","transferring","succeeded","failed","canceled"]},"fileCount":{"type":"integer","minimum":0},"totalBytes":{"type":"integer","minimum":0},"transferredBytes":{"type":"integer","minimum":0},"bytesPerSecond":{"type":"integer","minimum":0},"actions":{"type":"array","items":{"enum":["cancel","accept","reject","remove"]}}}}));
    schemas.insert("NativeTaskList".into(), json!({"type":"object","additionalProperties":false,"required":["epoch","tasks","truncated"],"properties":{"epoch":{"type":"string","format":"uuid"},"truncated":{"type":"boolean"},"tasks":{"type":"array","maxItems":512,"items":{"$ref":"#/components/schemas/NativeTask"}}}}));
    schemas.insert("NativeTaskControlResult".into(), json!({"type":"object","additionalProperties":false,"required":["epoch","id","action","dispatched"],"properties":{"epoch":{"type":"string","format":"uuid"},"id":{"type":"string","format":"uuid"},"action":{"enum":["cancel","accept","reject","remove"]},"dispatched":{"const":true}}}));
    schemas.insert("KeyMetadata".into(),json!({"type":"object","additionalProperties":false,"required":["id","name","grant","createdAt","expiresAt","enabled","limits"],"properties":{"id":{"type":"string","format":"uuid"},"name":{"type":"string"},"grant":{"type":"object"},"createdAt":{"type":"integer"},"expiresAt":{"type":["integer","null"]},"enabled":{"type":"boolean"},"limits":{"type":["object","null"]}}}));
    schemas.insert("KeyReceipt".into(),json!({"type":"object","additionalProperties":false,"required":["principal","requestId","digest","action","keyId","createdAt"],"properties":{"principal":{"type":"string","format":"uuid"},"requestId":{"type":"string","format":"uuid"},"digest":{"type":"string","pattern":"^[a-f0-9]{64}$"},"action":{"type":"string","enum":["create","pause","resume","revoke"]},"keyId":{"type":"string","format":"uuid"},"createdAt":{"type":"integer"}}}));
    schemas.insert("KeyResult".into(),json!({"type":"object","additionalProperties":false,"required":["receipt","applied","secretAvailable"],"properties":{"receipt":{"$ref":"#/components/schemas/KeyReceipt"},"applied":{"type":"boolean","description":"Current listener acknowledged persisted configuration"},"secretAvailable":{"type":"boolean"},"secret":{"type":"string","readOnly":true,"description":"Only the first successful create response. Never returned by replay or receipt lookup. Store privately, not in logs."}}}));
    schemas.insert("KeyList".into(),json!({"type":"object","additionalProperties":false,"required":["version","keys"],"properties":{"version":{"type":"string","pattern":"^[a-f0-9]{64}$"},"keys":{"type":"array","maxItems":128,"items":{"$ref":"#/components/schemas/KeyMetadata"}}}}));
    schemas.insert("KeyCreate".into(),json!({"type":"object","additionalProperties":false,"required":["version","requestId","name","grant","expiresAt"],"properties":{"version":{"type":"string","pattern":"^[a-f0-9]{64}$"},"requestId":{"type":"string","format":"uuid"},"name":{"type":"string","maxLength":256},"grant":{"type":"object","additionalProperties":false,"required":["scopes","workspaces"],"properties":{"scopes":{"type":"array","items":{"type":"string"}},"workspaces":{"type":"array","items":{"type":"string"}}}},"expiresAt":{"type":["integer","null"],"minimum":0}}}));
    schemas.insert("KeyManage".into(),json!({"type":"object","additionalProperties":false,"required":["version","requestId","action"],"properties":{"version":{"type":"string","pattern":"^[a-f0-9]{64}$"},"requestId":{"type":"string","format":"uuid"},"action":{"type":"string","enum":["pause","resume","revoke"]}}}));
    schemas.insert("ClearRequest".into(),json!({"type":"object","additionalProperties":false,"required":["instanceId","expectedGeneration","throughSequence"],"properties":{"instanceId":{"type":"string","format":"uuid"},"expectedGeneration":{"type":"integer","minimum":1},"throughSequence":{"type":"integer","minimum":0}}}));
    schemas.insert("ClearResult".into(),json!({"type":"object","required":["instanceId","generation","clearedThrough","throughSequence","removed","latest"],"properties":{"instanceId":{"type":"string"},"generation":{"type":"integer"},"clearedThrough":{"type":"integer"},"throughSequence":{"type":"integer"},"removed":{"type":"integer"},"latest":{"type":"integer"}}}));
    for field in ["generation", "clearedThrough"] {
        schemas.get_mut("RequestPage").unwrap()["required"]
            .as_array_mut()
            .unwrap()
            .push(json!(field));
        schemas.get_mut("RequestPage").unwrap()["properties"][field] =
            json!({"type":"integer","minimum":if field=="generation"{1}else{0}});
    }
    schemas.insert("ReceiveCacheRetention".into(), json!({"type":"object","additionalProperties":false,"required":["effectiveDays","automaticCleanupPaused","busy","error"],"properties":{
        "effectiveDays":{"type":["integer","null"],"minimum":-1,"maximum":3650,"description":if hant {"原生目前生效的天數編碼；null 表示尚未確認，不應以保存值猜測。"} else if zh {"原生当前生效的天数编码；null 表示尚未确认，不应以保存值猜测。"} else {"Currently effective native day encoding; null means unconfirmed, never inferred from the saved preference."}},
        "automaticCleanupPaused":{"type":"boolean","description":if hant {"僅表示原生策略同步保護是否暫停自動清理。手動保留模式可為 false，但核心仍保留檔案；Android 提供者清理另行管理。"} else if zh {"仅表示原生策略同步保护是否暂停自动清理。手动保留模式可为 false，但核心仍保留文件；Android 提供者清理独立管理。"} else {"Native-policy synchronization guard only. Manual retention may report false while core still retains files; Android provider cleanup is independent."}},
        "busy":{"type":"boolean","description":if hant {"本機保留期變更正在處理；API 不覆寫進行中的變更。"} else if zh {"本地保留期变更正在处理；API 不覆盖进行中的变更。"} else {"A local retention update is in progress; API writes do not overwrite an in-flight change."}},
        "error":{"type":["string","null"],"enum":[null,"invalid","save","apply","restore"],"description":if hant {"穩定且不含路徑的狀態原因：invalid 表示已保存的偏好損壞，而非 API 輸入校驗失敗；save、apply、restore 分別表示保存、套用、還原失敗；null 表示無錯誤。"} else if zh {"稳定且不含路径的状态原因：invalid 表示已保存的偏好损坏，而非 API 输入校验失败；save、apply、restore 分别表示保存、应用、恢复失败；null 表示无错误。"} else {"Stable path-free state reason: invalid means a damaged saved preference, not invalid API input; save, apply and restore mean persistence, native apply and restoration failures; null means no error."}}
    }}));
    schemas.get_mut("ReceiveCacheRetention").unwrap()["allOf"] = json!([
        {"if":{"properties":{"effectiveDays":{"type":"null"}},"required":["effectiveDays"]},"then":{"properties":{"automaticCleanupPaused":{"const":true}}}},
        {"if":{"properties":{"busy":{"const":true}},"required":["busy"]},"then":{"properties":{"automaticCleanupPaused":{"const":true}}}}
    ]);
    schemas.insert("HostSettings".into(), json!({"type":"object","additionalProperties":false,"required":["version","settings","pendingRestart","receiveCacheRetention"],"properties":{"pendingRestart":{"type":"array","maxItems":2,"uniqueItems":true,"items":{"type":"string","enum":["alias","verifyChecksums"]}},"version":{"type":"string","pattern":"^[a-f0-9]{64}$"},"receiveCacheRetention":{"$ref":"#/components/schemas/ReceiveCacheRetention"},"settings":{"type":"object","additionalProperties":false,"required":["alias","theme","locale","enableAnimations","autoFinish","createChecksums","verifyChecksums","receiveCacheRetentionDays"],"properties":{"alias":{"type":"string","maxLength":120},"theme":{"type":"string","enum":["system","light","dark"]},"locale":{"type":"string","description":"Supported app language tag, or system"},"enableAnimations":{"type":"boolean"},"autoFinish":{"type":"boolean"},"createChecksums":{"type":"boolean"},"verifyChecksums":{"type":"boolean"},"receiveCacheRetentionDays":retention_days_schema}}}}));
    let mut report_properties = serde_json::Map::new();
    for key in [
        "examined",
        "removedFiles",
        "removedRecords",
        "plannedBytes",
        "unlinkedBytes",
        "active",
        "retained",
        "failed",
    ] {
        report_properties.insert(key.into(), json!({"type":"integer","minimum":0}));
    }
    for key in ["budgetReached", "interrupted", "entriesTruncated"] {
        report_properties.insert(key.into(), json!({"type":"boolean"}));
    }
    report_properties.insert("entries".into(),json!({"type":"array","maxItems":128,"items":{"type":"object","additionalProperties":false,"required":["id","sourceKind","disposition","reason","plannedBytes","unlinkedBytes"],"properties":{"id":{"type":"string","pattern":"^[a-f0-9]{64}$"},"sourceKind":{"type":"string","enum":["unknown","nativeReceive","directoryUpload"]},"disposition":{"type":"string","enum":["candidate","removed","retired","retained","active","failed"]},"reason":{"type":"string","maxLength":80},"plannedBytes":{"type":"integer","minimum":0},"unlinkedBytes":{"type":"integer","minimum":0}}}}));
    schemas.insert("CacheReport".into(),json!({"type":"object","additionalProperties":false,"required":report_properties.keys().collect::<Vec<_>>(),"properties":report_properties}));

    let uuid_schema = json!({"type":"string","format":"uuid","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"});
    let count = json!({"type":"integer","minimum":0});
    schemas.insert("DeviceChannel".into(),json!({"type":"object","additionalProperties":false,"required":["id","host","port","https"],"properties":{"id":uuid_schema,"host":{"type":"string","description":"Discovered IP address with optional IPv6 scope, not a caller URL"},"port":{"type":"integer","minimum":1,"maximum":65535},"https":{"type":"boolean"}}}));
    schemas.insert("Device".into(),json!({"type":"object","additionalProperties":false,"required":["id","alias","deviceType","channels"],"properties":{"id":uuid_schema,"alias":{"type":"string","maxLength":1024},"deviceType":{"enum":["mobile","desktop","web","headless","server"]},"channels":{"type":"array","maxItems":32,"items":{"$ref":"#/components/schemas/DeviceChannel"}}}}));
    schemas.insert("DeviceList".into(),json!({"type":"object","additionalProperties":false,"required":["devices","truncated","scanState"],"properties":{"scanState":{"enum":["idle","running","failed"]},"devices":{"type":"array","maxItems":512,"items":{"$ref":"#/components/schemas/Device"}},"truncated":{"type":"boolean"}}}));
    schemas.insert("DeviceResult".into(),json!({"type":"object","additionalProperties":false,"required":["device"],"properties":{"device":{"$ref":"#/components/schemas/Device"}}}));
    schemas.insert("ScanResult".into(),json!({"type":"object","additionalProperties":false,"required":["accepted","coalesced"],"properties":{"accepted":{"const":true},"coalesced":{"type":"boolean"}}}));
    schemas.insert("SendSelection".into(),json!({"type":"object","additionalProperties":false,"required":["selectionVersion","totalCount","totalBytes","truncated","files"],"properties":{"selectionVersion":uuid_schema,"totalCount":count,"totalBytes":count,"truncated":{"type":"boolean"},"files":{"type":"array","maxItems":100,"items":{"type":"object","additionalProperties":false,"required":["name","size"],"properties":{"name":{"type":"string","maxLength":1024,"description": if hant {"僅檔案基本名稱，不含本機路徑"} else if zh {"仅文件基本名称，不含本地路径"} else {"Base name only; no native path"}},"size":count}}}}}));
    schemas.insert("SendTransferBody".into(),json!({"type":"object","additionalProperties":false,"required":["deviceId","selectionVersion","requestId"],"properties":{"deviceId":uuid_schema,"selectionVersion":uuid_schema,"requestId":uuid_schema,"channelId":uuid_schema}}));
    let route_description = if hant {
        "從 devices.read 回應的 localRoutes 選取目前 UUID；省略為自動。失效回傳 409 local_route_unavailable，不回退其他網路。重試繼承原任務選擇。androidNetwork 代表已識別系統 Network 的逐通訊端綁定；來源/介面約束不保證略過 VPN。"
    } else if zh {
        "从 devices.read 响应的 localRoutes 选择当前 UUID；省略为自动。失效返回 409 local_route_unavailable，不回退其他网络。重试继承原任务选择。androidNetwork 表示已识别系统 Network 的逐套接字绑定；来源/接口约束不保证绕过 VPN。"
    } else {
        "Choose a current UUID from localRoutes in the devices.read response; omit for automatic routing. A retired route returns 409 local_route_unavailable without fallback. Retry keeps the original task route. androidNetwork denotes per-socket binding to an identified system Network; source/interface constraints do not guarantee VPN bypass."
    };
    schemas.get_mut("SendTransferBody").unwrap()["properties"]["localRouteId"] =
        json!({"type":"string","format":"uuid","description":route_description});
    schemas.get_mut("WorkspaceSendBody").unwrap()["properties"]["localRouteId"] =
        json!({"type":"string","format":"uuid","description":route_description});
    // Keep the original versioned filesystem body exact; provider capture is
    // a distinct opt-in variant rather than a made-up content version.
    let filesystem_send = schemas["WorkspaceSendBody"].clone();
    let mut document_send = filesystem_send.clone();
    document_send["required"]
        .as_array_mut()
        .unwrap()
        .push(json!("sourceMode"));
    document_send["properties"]["sourceMode"] = json!({"const":"documentSnapshot"});
    document_send["properties"]["files"]["items"] = json!({"type":"object","additionalProperties":false,"required":["id"],"properties":{"id":{"type":"string","format":"uuid","pattern":"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"}}});
    document_send["description"] = json!(if hant {
        "明確擷取已選文件位元組並核驗後透過原始協定傳送；不是提供者原子快照，不接受偽造版本或原生路徑。"
    } else if zh {
        "明确捕获所选文档字节并核验后通过原始协议发送；不是提供程序原子快照，不接受伪造版本或原生路径。"
    } else {
        "Capture and verify selected document bytes before original-protocol sending; not a provider-atomic snapshot. No fabricated versions or native paths."
    });
    schemas.insert("WorkspaceFilesystemSendBody".into(), filesystem_send);
    schemas.insert("WorkspaceDocumentSendBody".into(), document_send);
    schemas.insert("WorkspaceSendBody".into(), json!({"oneOf":[{"$ref":"#/components/schemas/WorkspaceFilesystemSendBody"},{"$ref":"#/components/schemas/WorkspaceDocumentSendBody"}]}));
    schemas.insert("LocalRoute".into(),json!({"type":"object","additionalProperties":false,"required":["id","interfaceName","address","binding"],"properties":{"id":uuid_schema,"interfaceName":{"type":"string","maxLength":256},"address":{"type":"string","maxLength":64},"binding":{"enum":["interfaceAndSource","sourceOnly","androidNetwork"],"description":route_description}}}));
    schemas.get_mut("DeviceList").unwrap()["properties"]["localRoutes"] = json!({"type":"array","maxItems":64,"items":{"$ref":"#/components/schemas/LocalRoute"},"description":route_description});
    schemas.insert("RetryTransferBody".into(),json!({"type":"object","additionalProperties":false,"required":["requestId"],"properties":{"requestId":uuid_schema}}));
    schemas.insert("TransferTask".into(),json!({"type":"object","additionalProperties":false,"required":["id","deviceId","status","fileCount","totalBytes","transferredBytes","bytesPerSecond"],"properties":{"id":uuid_schema,"deviceId":uuid_schema,"status":{"enum":["queued","running","succeeded","failed","canceled"]},"fileCount":count,"totalBytes":count,"transferredBytes":count,"bytesPerSecond":{"type":"number","minimum":0},"retryOf":uuid_schema,"removed":{"const":true},"result":{"enum":["waiting","recipientBusy","declined","tooManyAttempts","sending","finished","finishedWithErrors","canceledBySender","canceledByReceiver"]}}}));
    schemas.get_mut("TransferTask").unwrap()["properties"]["localRouteId"] = uuid_schema.clone();
    schemas.insert("TransferReceipt".into(),json!({"type":"object","additionalProperties":false,"required":["task","replayed"],"properties":{"task":{"$ref":"#/components/schemas/TransferTask"},"replayed":{"type":"boolean"}}}));
    schemas.insert("TransferList".into(),json!({"type":"object","additionalProperties":false,"required":["tasks"],"properties":{"tasks":{"type":"array","maxItems":512,"items":{"$ref":"#/components/schemas/TransferTask"}}}}));
    schemas.insert("TransferResult".into(),json!({"type":"object","additionalProperties":false,"required":["task"],"properties":{"task":{"$ref":"#/components/schemas/TransferTask"}}}));
    schemas.insert("TransferRemoval".into(),json!({"type":"object","additionalProperties":false,"required":["removed","id"],"properties":{"removed":{"const":true},"id":uuid_schema}}));
    schemas.insert("ApprovedSourceList".into(),json!({"type":"object","required":["sources"],"properties":{"sources":{"type":"array","maxItems":64,"items":{"type":"object","additionalProperties":false,"required":["id","name","kind"],"properties":{"id":{"type":"string","format":"uuid"},"name":{"type":"string"},"kind":{"enum":["directory","androidTree","appleBookmark"]}}}}}}));
    schemas.insert("CreateWorkspaceBody".into(),json!({"type":"object","additionalProperties":false,"required":["sourceId","name","slug"],"properties":{"sourceId":{"type":"string","format":"uuid"},"name":{"type":"string","minLength":1,"maxLength":120},"slug":{"type":"string","maxLength":48},"visible":{"type":"boolean","default":true},"allowUpload":{"type":"boolean","default":false}}}));
    schemas.insert("ConfigureWorkspaceBody".into(),json!({"type":"object","additionalProperties":false,"minProperties":1,"properties":{"sourceId":{"type":"string","format":"uuid"},"slug":{"type":"string","maxLength":48}}}));
    schemas.insert("WorkspacePasswordBody".into(),json!({"oneOf":[{"type":"object","additionalProperties":false,"required":["password"],"properties":{"password":{"type":"string","format":"password","writeOnly":true,"minLength":4,"maxLength":128}}},{"type":"object","additionalProperties":false,"required":["clear"],"properties":{"clear":{"const":true}}}]}));
    schemas.insert("ManagedWorkspace".into(),json!({"type":"object","additionalProperties":false,"required":["id","name","slug","generation","enabled","visible","allowUpload","passwordProtected","invalidReason"],"properties":{"id":{"type":"string","format":"uuid"},"name":{"type":"string"},"slug":{"type":"string"},"generation":{"type":"integer","minimum":1},"enabled":{"type":"boolean"},"visible":{"type":"boolean"},"allowUpload":{"type":"boolean"},"passwordProtected":{"type":"boolean"},"invalidReason":{"type":["string","null"],"enum":[null,"missing","notDirectory","permissionDenied","grantUnavailable","ioError","timeout"]}}}));
    schemas.insert("ManagedWorkspaceList".into(),json!({"type":"object","required":["workspaces"],"properties":{"workspaces":{"type":"array","maxItems":256,"items":{"$ref":"#/components/schemas/ManagedWorkspace"}}}}));
    schemas.insert("ManagementResult".into(),json!({"type":"object","properties":{"workspace":{"$ref":"#/components/schemas/ManagedWorkspace"},"id":{"type":"string","format":"uuid"},"destroyed":{"type":"boolean"},"error":{"type":"object","required":["code","requestId"],"properties":{"code":{"type":"string"},"requestId":{"type":"string","format":"uuid"}}}}}));

    schemas.insert("Limits".into(),json!({"type":"object","required":["perSecond","perMinute","concurrent"],"properties":{"perSecond":{"type":"integer","minimum":0,"maximum":1000},"perMinute":{"type":"integer","minimum":0,"maximum":60000},"concurrent":{"type":"integer","minimum":0,"maximum":64}}}));
    schemas.get_mut("Limits").unwrap()["description"] = json!(if hant {
        "0 僅停用該維度；仍受其他配額及全域 64 個活動回應上限約束。"
    } else if zh {
        "0 仅停用该维度；仍受其他配额及全局 64 个活动响应上限约束。"
    } else {
        "0 disables only that dimension; other quotas and the global hard ceiling of 64 active responses remain enforced."
    });
    schemas.insert("Capabilities".into(),json!({"type":"object","required":["product","version","apiVersion","operations","rangeDownload","readOnly","originalProtocol"],"properties":{"product":{"const":"LegnaSend"},"version":{"type":"string"},"apiVersion":{"const":1},"operations":{"type":"array","items":{"type":"string"}},"rangeDownload":{"type":"boolean"},"readOnly":{"type":"boolean"},"originalProtocol":{"type":"string"}}}));
    schemas.insert("Status".into(),json!({"type":"object","required":["instanceId","enabled","authRequired","port","https","globalLimits","keyLimits","anonymousLimits","activeResponses","principal","scopes","fixedWindowSeconds"],"properties":{"instanceId":{"type":"string","format":"uuid"},"enabled":{"type":"boolean"},"authRequired":{"type":"boolean"},"port":{"type":"integer","minimum":1,"maximum":65535},"https":{"type":"boolean"},"globalLimits":{"$ref":"#/components/schemas/Limits"},"keyLimits":{"$ref":"#/components/schemas/Limits"},"anonymousLimits":{"$ref":"#/components/schemas/Limits"},"activeResponses":{"type":"integer","minimum":0},"principal":{"type":["string","null"]},"scopes":{"type":"array","items":{"type":"string","enum":["service.read","workspaces.read","files.read","requests.read","files.upload","workspaces.manage","devices.read","devices.scan","transfers.read","transfers.send","transfers.control","cache.read","cache.clean","settings.read","settings.write","keys.manage","requests.manage","nativeTasks.read","nativeTasks.control"]}},"fixedWindowSeconds":{"const":[1,60]}}}));
    schemas.insert("RequestRecord".into(),json!({"type":"object","required":["sequence","timestamp","requestId","operation","method","principal","status","outcome","error","reason","bytes","elapsedMs"],"properties":{"sequence":{"type":"integer","minimum":1},"timestamp":{"type":"integer","minimum":0},"requestId":{"type":"string","format":"uuid"},"operation":{"type":"string"},"method":{"type":"string","enum":["GET","HEAD","OPTIONS","POST","OTHER"]},"principal":{"type":["string","null"]},"status":{"type":"integer","minimum":100,"maximum":599},"outcome":{"type":"string"},"error":{"type":["string","null"]},"reason":{"type":["string","null"]},"bytes":{"type":"integer","minimum":0},"elapsedMs":{"type":"integer","minimum":0}}}));
    schemas.get_mut("RequestPage").unwrap()["required"]
        .as_array_mut()
        .unwrap()
        .push(json!("instanceId"));
    schemas.get_mut("RequestPage").unwrap()["properties"]["instanceId"] =
        json!({"type":"string","format":"uuid"});
    schemas.get_mut("RequestPage").unwrap()["properties"]["entries"]["items"] =
        json!({"$ref":"#/components/schemas/RequestRecord"});
    for (path, name) in [("/status", "Status"), ("/capabilities", "Capabilities")] {
        document["paths"][path]["get"]["responses"]["200"]["content"]["application/json"]["schema"] =
            json!({"$ref":format!("#/components/schemas/{name}")});
    }
    for path in document["paths"].as_object_mut().unwrap().values_mut() {
        for operation in path.as_object_mut().unwrap().values_mut() {
            let responses = operation["responses"].as_object_mut().unwrap();
            for response in responses.values_mut() {
                let headers = response
                    .as_object_mut()
                    .unwrap()
                    .entry("headers")
                    .or_insert(json!({}))
                    .as_object_mut()
                    .unwrap();
                headers.insert(
                    "X-LegnaSend-Request-Id".into(),
                    json!({"schema":{"type":"string","format":"uuid"}}),
                );
                for name in [
                    "X-LegnaSend-Remaining-Second",
                    "X-LegnaSend-Remaining-Minute",
                ] {
                    headers.insert(
                        name.into(),
                        json!({"schema":{"type":"integer","minimum":0,"maximum":4294967295u32},"description": if hant {"4294967295 表示全域與呼叫方在此維度均不限額；否則回傳最小剩餘額度。"} else if zh {"4294967295 表示全局和调用方在此维度均不限额；否则返回最小剩余额度。"} else {"4294967295 means both global and caller quotas are unlimited in this dimension; otherwise the smaller finite remainder."}}),
                    );
                }
            }
        }
    }
    let content = &mut document["paths"][Operation::Content.path()];
    for method in ["get", "head"] {
        for status in ["200", "206"] {
            let response = &mut content[method]["responses"][status];
            for name in ["ETag", "Accept-Ranges", "Content-Disposition"] {
                response["headers"][name] = json!({"schema":{"type":"string"}});
            }
            response["headers"]["Content-Length"] =
                json!({"schema":{"type":"integer","minimum":0}});
        }
        content[method]["responses"]["416"]["headers"]["Content-Range"] =
            json!({"schema":{"type":"string"}});
    }
    // Previews may have an allowlisted raster/media MIME; downloads retain octet-stream.
    for status in ["200", "206"] {
        let schema =
            content["get"]["responses"][status]["content"]["application/octet-stream"].clone();
        content["get"]["responses"][status]["content"]["*/*"] = schema;
    }
    if zh {
        document["info"]["title"] = json!(if hant {
            "LegnaSend 整合 API"
        } else {
            "LegnaSend 集成 API"
        });
        document["x-legnasend-anonymous-policy"] = json!(if hant {
            "關閉業務鑑權後，匿名授權只涵蓋可見且未受密碼保護的工作區；提供錯誤金鑰不會降級成匿名。"
        } else {
            "关闭业务鉴权后，匿名授权只涵盖可见且未受密码保护的工作区；提供错误密钥不会降级成匿名。"
        });
        for path in document["paths"].as_object_mut().unwrap().values_mut() {
            for op in path.as_object_mut().unwrap().values_mut() {
                for (status, response) in op["responses"].as_object_mut().unwrap() {
                    // Localized operation-specific errors must survive this final pass.
                    // Only generic successful responses may receive a success label.
                    response["description"] = json!(match status.as_str() {
                        "429" =>
                            if hant {
                                "固定秒／分窗口或活動回應配額"
                            } else {
                                "固定秒／分窗口或活动响应配额"
                            },
                        "default" =>
                            if hant {
                                "穩定錯誤碼，不包含憑據或本機路徑"
                            } else {
                                "稳定错误码，不包含凭据或本机路径"
                            },
                        "206" =>
                            if hant {
                                "請求的位元組範圍"
                            } else {
                                "请求的字节范围"
                            },
                        "416" =>
                            if hant {
                                "範圍超出檔案長度"
                            } else {
                                "范围超出文件长度"
                            },
                        "200" | "201" | "204" if response["description"] == "OK" => "成功",
                        "202" if response["description"] == "Accepted, not completed" =>
                            "已接手，尚未完成",
                        _ => continue,
                    });
                }
            }
        }
    }
    document
}

#[cfg(test)]
mod preview_archive_contract_tests {
    use super::*;
    #[test]
    fn all_locales_describe_actual_scoped_preview_archive_and_watch_shapes() {
        for locale in ["en", "zh-CN", "zh-TW", "zh-HK"] {
            let value = document(locale);
            assert_eq!(value["paths"].as_object().unwrap().len(), 43);
            for operation in [
                Operation::PreparePreview,
                Operation::ClosePreview,
                Operation::Archive,
            ] {
                let verb = if operation.is_post() { "post" } else { "get" };
                assert_eq!(
                    value["paths"][operation.path()][verb]["x-legnasend-scope"],
                    "files.read"
                );
            }
            let prepare = &value["paths"][Operation::PreparePreview.path()]["post"];
            assert_eq!(
                prepare["requestBody"]["content"]["application/json"]["schema"]["properties"]["id"]
                    ["format"],
                "uuid"
            );
            assert_eq!(
                value["paths"][Operation::Archive.path()]["head"]["operationId"],
                "headWorkspaceArchive"
            );
            assert_eq!(
                value["components"]["schemas"]["DocumentPreviewLease"]["properties"]["size"]["maximum"],
                9007199254740991_u64
            );
            assert_eq!(
                value["components"]["schemas"]["WorkspaceState"]["oneOf"][1]["properties"]["refreshFromStart"]
                    ["const"],
                true
            );
            assert!(
                value["paths"][Operation::Content.path()]["get"]["parameters"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|p| p["name"] == "lease")
            );
        }
        assert!(valid_parameter_text(
            Operation::Archive,
            "ids",
            r#"["a","b"]"#
        ));
        for bad in [r#"[]"#, r#"["a","a"]"#, r#"["../path"]"#, r#"{}"#] {
            assert!(!valid_parameter_text(Operation::Archive, "ids", bad));
        }
    }
}

#[cfg(test)]
mod archive_selection_contract_tests {
    use super::*;
    #[test]
    fn all_locales_expose_scoped_large_selection_bodies_and_ticket_downloads() {
        for locale in ["en", "zh-CN", "zh-TW", "zh-HK"] {
            let value = document(locale);
            assert_eq!(value["paths"].as_object().unwrap().len(), 43);
            for operation in [Operation::PrepareArchive, Operation::CancelArchive] {
                assert!(operation.is_post());
                assert_eq!(operation.scope(), Scope::Files);
                let op = &value["paths"][operation.path()]["post"];
                assert_eq!(op["x-legnasend-scope"], "files.read");
                assert!(op["requestBody"]["required"].as_bool().unwrap());
            }
            assert_eq!(
                value["paths"][Operation::PrepareArchive.path()]["post"]["x-legnasend-max-body-bytes"],
                2 * 1024 * 1024
            );
            assert_eq!(
                value["paths"][Operation::PrepareArchive.path()]["post"]["responses"]["200"]["content"]
                    ["application/json"]["schema"]["$ref"],
                "#/components/schemas/ArchiveSelectionTicket"
            );
            assert_eq!(
                value["components"]["schemas"]["ArchiveSelectionPrepare"]["properties"]["ids"]["maxItems"],
                20000
            );
            assert!(
                value["paths"][Operation::Archive.path()]["get"]["parameters"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|p| p["name"] == "selection" && p["schema"]["format"] == "uuid")
            );
        }
    }
}
