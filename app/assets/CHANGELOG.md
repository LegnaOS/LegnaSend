# LegnaSend Changelog

Author: Legna


## Unreleased — 2026-09-28

- Restore an existing workspace's folder access without recreating its name, path or password.
- Prefer IPv4 and collapse alternate network addresses. Add Open beside Copy to launch the system browser.
- Default unfinished-transfer caches to one hour, preserving explicit retention settings and active or completed files.
- Use the website's green L mark across native app icons; animate the receive-page logo while active and respect reduced motion.
- Select every entry in the current web folder across unloaded pages. Show explicit ZIP cancellation targets and distinguish original-file downloads from ZIP archives.
- Replace technical cleanup wording with short results and remove the API roadmap notice from the interface.
- Correct the Windows executable name to `LegnaSend.exe`, including file properties, installer launch targets and helper display names.
- Prefill workspace names and custom paths; selecting a folder supplies its name. Keep edited names unchanged and give form labels enough vertical space.
- Show complete workspace URLs with explicit Copy buttons. Start a stopped sharing service from the workspace page.
- Remember macOS workspace folder authorization across app restarts. Older path-only entries can restore access by selecting their folder again.
- Once workspace uploads are enabled, authorized visitors can upload and retry without repeated prompts. Password protection and no-overwrite behavior remain.
- Select the current mobile album in one operation, with cancellation and a 999-item limit. Desktop media selection supports multiple image and video files.
- Simplify workspace and network hints; remove internal observation counters from workspace cards.

## 1.0.0 (2026-09-25)

### Sending and receiving

- Send files and folders from a queue, or drop them onto a device. Retry individual failed files without sending completed files again.
- Keep sending and receiving visible in one transfer panel, with progress, speed and separate controls. Leaving a page does not stop a transfer.
- Compatible devices and storage can resume interrupted large files. Reusing saved progress after an app restart requires a newly approved transfer; unsupported destinations use a whole-file retry.
- Report success only after a file finishes saving, without overwriting existing files. Delayed results no longer disturb a newer transfer or duplicate history.

### Receive folders and temporary files

- Choose and remember an iOS Files folder or an Android document folder as the receive destination. If access is lost, select the folder again; the app does not silently save elsewhere.
- On supported Android storage, check interrupted saves and recognize files that were already saved, without rewriting them.
- Automatically clean verified temporary copies after a successful receive, and retry eligible cleanup during startup or cache maintenance. Files in use, completed files and uncertain leftovers are protected.
- Inspect receive caches, choose a retention period and view cleanup results. Ending a compatible transfer can request cleanup on the receiving device; a pending request is not shown as confirmed removal.

### Browser sharing and folder workspaces

- Share files with a browser or publish named folder workspaces. Keep workspaces separately enabled, password-protected and available alongside normal device transfers.
- Browse and search file lists, select multiple items, and download files or folder ZIPs that preserve nested paths and empty folders. Supported workspaces also accept approved uploads without overwriting existing files.
- Use pause, resume and retry for downloads saved to a supported authorized browser folder. Restored tasks remain paused; ordinary browser downloads still use the browser’s own save location.
- Manage selected workspace transfers from the shared task panel. The optional integration API provides access keys, scoped permissions, request limits and an in-app reference.

### Preview and reading

- Preview supported images, audio and video without leaving the shared page, with zoom, playback controls and original-file download.
- Read and search text and Markdown, including large documents and supported diagrams. Choose text encoding when needed.
- Keep reading position and selection when refreshing a workspace. Changed files can be refreshed without stopping unrelated downloads.

### Connections and privacy

- Choose an available network entry and outgoing connection for each send task. A disconnected choice is reported rather than silently replaced; system VPN and firewall rules still apply.
- See network, VPN and proxy information, copy the actual sharing address, and choose HTTP or HTTPS transport. HTTPS uses device-generated certificates.
- Open the bundled privacy policy offline. About links to the LegnaSend website and source project; unused donation and purchase entry points have been removed.

### Usability and compatibility

- Fixed an incorrect recovery-record save error when starting the sandboxed macOS app.
- iOS remembers pending shared files and text across app restarts without sending them automatically. Dismissing a picker no longer leaves it busy.
- Transfer panels work better on smaller screens and with larger text, with clearer keyboard and accessibility controls.
- Original LocalSend transfers remain supported. Folder access, background operation and recovery depend on the device and storage provider; Android virtual files and files of unknown size are not supported for sending.
- Browser folder saving requires browser support and permission. ZIP downloads do not offer resumable archive recovery; very complex Markdown falls back to readable source text.

LegnaSend is based on LocalSend. Original licensing and attribution are retained.
