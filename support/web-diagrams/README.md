# Offline diagram build

This standalone Node tool creates the browser assets embedded in the Rust HTTP server. It is not part of the Dart workspace and adds no runtime package manager or CDN requirement.

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run build
```

Run here with Node 22 or newer. Direct versions and transitive integrity hashes are fixed in `package-lock.json`: Mermaid 12.0.0, Markmap library/view 0.18.12, DOMPurify 3.4.15 and esbuild 0.25.12. Build scripts from dependencies are disabled. Browser exports are used; application renderer wrappers are in `src/`.

Generated files:

- `packages/core/assets/web/vendor/diagrams/`: content-hashed bundles, linked legal notices, full dependency licenses and a manifest of sizes, SHA-256, package versions, source packages and repositories.
- `packages/core/assets/web/diagram-config.js`: local bundle URLs.
- `packages/core/src/http/server/diagram_assets.rs`: fixed compile-time asset allowlist. No request path is opened on disk.

Only files listed in the previous generated manifest are retired. Do not edit generated bundles directly. The scoped `.gitattributes` entry preserves whitespace in third-party template strings and original legal texts; artifact hashes, not whitespace rewriting, verify these bytes. Application sources retain normal whitespace checks. Regenerate and commit the lockfile, wrappers, assets, manifest and Rust allowlist together; verify `node --test packages/core/tests/web/diagram_preview.test.cjs` from the repository root.

Mermaid uses strict mode with site-controlled limits and green themes. Markmap transforms Markdown, sanitizes labels and never loads declared plugin assets. Runtime frames have opaque origins and restricted CSP; original document bytes, credentials and LocalSend wire contracts are unchanged. Source and diagram errors remain local to their blocks. Rendering is bounded to the existing complete-document Markdown view; large-document block virtualization is independent work.

Dependencies retain their own licenses; the application wrappers do not relicense them. `LICENSES.txt` includes every bundled package’s original license files. `manifest.json` identifies the npm source packages and upstream repositories. In particular, the embedded `elkjs` 0.9.3 module retains EPL-2.0 and its source is available at the [exact elkjs source revision](https://github.com/kieler/elkjs/tree/a8304cf79fde75bc2ab1a89d28320f53f8637436); its build instructions refer to the [Eclipse Layout Kernel source](https://github.com/eclipse-elk/elk). Bundling/minification does not replace those notices or source references.
