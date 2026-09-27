fn main() {
    // VERSIONINFO metadata for the Windows exe, mirroring app/windows/runner/Runner.rc.
    // Code signing expects ProductName/ProductVersion on all signed binaries.
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        let mut res = winresource::WindowsResource::new();
        res.set("ProductName", "LegnaSend");
        res.set("FileDescription", "LegnaSend CLI");
        res.set("CompanyName", "Legna");
        res.set("OriginalFilename", "localsend-cli.exe");
        res.set("InternalName", "localsend-cli");
        res.set("LegalCopyright", "Copyright (C) 2022-2026 Tien Do Nam");
        // FileVersion/ProductVersion are derived from CARGO_PKG_VERSION automatically.
        res.compile().expect("failed to compile Windows resources");
    }
}