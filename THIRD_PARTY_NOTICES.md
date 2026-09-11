# Third-Party Notices

## Eclipse Layout Kernel JavaScript

This distribution includes `assets/js/elk.bundled.js`, the ELK JavaScript
layout engine from the [elkjs project](https://github.com/kieler/elkjs).

The bundled file is distributed as an unmodified third-party asset. It retains
its upstream Eclipse Public License 2.0 (EPL-2.0) copyright and license notices.
It also contains a Google LLC web-worker shim under the Apache License 2.0.
The full EPL-2.0 and Apache-2.0 texts, the source-availability statement, and
the asset SHA-256 are in `assets/licenses/elkjs_LICENSES.txt`.

Under EPL-2.0 section 3.1, corresponding source for the byte-identical
elkjs 0.8.2 `lib/elk.bundled.js` is available from:

- <https://github.com/kieler/elkjs/tree/0.8.2>
- <https://registry.npmjs.org/elkjs/-/elkjs-0.8.2.tgz>

The SHA-256 of the shipped `assets/js/elk.bundled.js` is:

```text
cd56bf0ddb7ad2587583461d523fdd974dc56b59efd20cdfee954e1112ff1a49
```

### Distribution locations

- Linux and embedded Flutter consumers receive the notice through the declared
  `assets/licenses/` Flutter asset bundle.
- Standalone web builds place this file at `THIRD_PARTY_NOTICES.md` and the
  complete license text at `licenses/elkjs_LICENSES.txt`.
- The VS Code extension package includes this file and `assets/licenses/`.
