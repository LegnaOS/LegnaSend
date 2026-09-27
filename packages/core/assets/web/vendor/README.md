# Offline Markdown dependency

- Package: `marked` 18.0.13, MIT; original license: `marked-LICENSE.txt`.
- Upstream: https://github.com/markedjs/marked
- Official API documentation: https://marked.js.org/using_pro
- Package source: https://registry.npmjs.org/marked/-/marked-18.0.13.tgz
- Registry tarball integrity, verified before extraction: `sha512-xTxVzZsBFwunP6HDmtBkabUQEYArnP7/rMDGmPj9SlrKlQ4i8MdYVow+nJL0eOqwpUqhzBoTBRADGN6uYwPyOw==`.
- Unmodified `lib/marked.umd.js` SHA-256: `b147274a9ce27d17276587167e49483d719f6893eeca3a3667a59797661d3556`.

The bundled worker uses only the lexer. The application builds allowlisted DOM nodes from tokens instead of inserting the parser's HTML output. Raw HTML is literal text, active URL schemes are rejected, and image references do not initiate external requests. Parsing has a source limit and worker deadline; DOM generation has depth and node limits. No CDN or runtime package resolution is used. Mermaid and Markmap integration is described below.

## Diagrams

Mermaid and Markmap are bundled separately in `diagrams/`, with content-hashed local URLs, per-artifact SHA-256, package/source references and original dependency licenses. See the [reproducible build](../../../../../support/web-diagrams/README.md). Only near-viewport diagrams load a renderer; cached Mermaid SVGs use a smaller sanitizer/viewer bundle on reentry. No runtime CDN or document-declared plugin assets are loaded.
