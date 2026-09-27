# Local compatibility changes

Upstream: Sindre Sorhus, Defaults 4.2.2, https://github.com/sindresorhus/Defaults/tree/v4.2.2.
The upstream license is retained in `license`; the original CocoaPods specification is retained.

- Replace two deprecated unrestricted unarchiving calls with class-constrained secure unarchiving for the existing `NSSecureCoding` overloads.
- Codable settings, key names, stored bytes and observation APIs stay unchanged.
- This pinned local pod avoids editing the CocoaPods cache or suppressing compiler warnings. Reviewed against the installed Apple SDK and compiled with warnings as errors for macOS 11.0.
