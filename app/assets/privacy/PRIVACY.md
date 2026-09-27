# LegnaSend Privacy Policy

Updated: 26 September 2026 · Developer: Legna · Applies to LegnaSend 1.0.0

## Files go to the destinations you choose

LegnaSend shares files, text and selected folders with devices, browsers and applications that you allow to connect. Ordinary local transfers do not require an account or a developer-operated file-storage service. The current app does not include an active advertising, tracking or automatic analytics service and does not automatically upload your transferred files to the developer.

Discovery exposes your configured device name, device type/model, protocol information, listening port and a certificate-derived device identifier to reachable peers. This identifier supports connection identity, not advertising. A peer or browser receives the filenames, sizes, directory information and file bytes that its access allows. Choose an alias that does not disclose information you want to keep private.

## Your permissions and sharing controls

Local-network access enables discovery and transfers. Files and folder permissions enable the sources and destinations you select. Photo access is used when selecting media or saving received media. The system share extension uses the same application's App Group to hand selected content to the main app.

You decide whether to accept incoming transfers, enable quick-save, publish a workspace, permit browser uploads or enable the integration API. An unlisted workspace is not automatically private: anyone with a reachable link may still access it according to its access settings. Workspace passwords and API keys control access; turning on HTTPS protects transport. HTTP transport is not encrypted. A workspace password does not encrypt files at rest.

Your network, VPN, firewall and routing configuration determine who can reach a listener. A local-looking address does not guarantee that only trusted devices can access it. Closing a share or revoking access does not erase copies already received by other people.

## Information kept on your device

The app stores settings, device identity keys, favorites, workspace grants, transfer history and recovery information needed for its functions. Interrupted transfers may retain owned .ls temporary files and recovery records. Cache management removes only entries it can safely identify; completed files, active transfers and uncertain external files are preserved. Retention depends on the task, permissions and configured cleanup policy.

Integration API request history and diagnostic records are kept locally. They may contain device/file names, addresses, timings and error details. Authorized API clients can read the management information allowed by their keys. Private key material and cleanup credentials are not ordinary public task fields. Review records before choosing to export or post them.

You can remove histories and managed caches through the app where available, close or destroy workspace registrations, revoke keys, and revoke system file/photo/local-network permissions. Destroying a workspace registration does not delete its original directory. Deleting the app removes its app-managed container according to the operating system; files saved to Files, Photos, shared storage, other devices or backups may remain and must be managed there.

## External services and links

Opening project/support links uses your browser and the destination service's privacy practices. iCloud or another file provider may synchronize documents under your provider settings. Operating-system backups and diagnostics are controlled separately by your device and Apple settings.

The current release configuration disables the WebRTC/public-signaling feature. Local sharing does not automatically connect to the upstream public signaling service. If a later version enables developer-hosted signaling, relay, analytics or accounts, its privacy declarations and this policy must be updated before that change is released.

## Contact and changes

Project and support: [LegnaSend on GitHub](https://github.com/LegnaOS/LegnaSend).

You can raise a policy question through [project issues](https://github.com/LegnaOS/LegnaSend/issues). Issues are public: do not post private files, credentials or unredacted logs. Information you voluntarily submit there is handled by GitHub and visible according to that service's settings.

This policy accompanies the app. Changes to collection, recipients or sharing behavior will be reflected in the policy and release information. Store privacy answers must describe the distributed version, not a future feature or a different build.
