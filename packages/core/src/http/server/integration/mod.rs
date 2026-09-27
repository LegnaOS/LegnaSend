//! Optional integration API, isolated from the original LocalSend and browser APIs.
pub(crate) mod console;
mod contract;
mod host_management;
mod key_management;
mod management;
mod native_tasks;
mod transfer_management;
pub use management::PendingManagement;
mod policy;
mod request_history;
mod router;

pub(crate) use policy::unix_time as upload_unix_time;
pub use policy::{
    ApiConfig, KeyCreation, KeyRecord, Limits, Scope, WorkspaceGrant, create_key,
    validate_configuration,
};
pub(crate) use policy::{Registry, UploadAuthority};
pub(crate) use router::route;
pub const PREFIX: &str = "/api/legnasend/v1/integration";
