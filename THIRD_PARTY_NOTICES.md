# Third-party notices

## Google libwebp 1.6.0 — dwebp

あいこんふぁくとりー bundles the unmodified Windows x64 `dwebp.exe` from the official Google libwebp 1.6.0 distribution for offline decoding of static WebP images. No runtime download is needed.

Copyright (c) 2010, Google Inc. All rights reserved.

License: BSD-3-Clause. The complete upstream license and disclaimer are reproduced unchanged in [App/Native/LICENSE-libwebp.txt](App/Native/LICENSE-libwebp.txt). The additional patent grant is reproduced unchanged in [App/Native/PATENTS-libwebp.txt](App/Native/PATENTS-libwebp.txt). Both texts were obtained from the matching official libwebp 1.6.0 source distribution; the upstream license filename is `COPYING`.

- Project: https://developers.google.com/speed/webp/
- Official downloads: https://developers.google.com/speed/webp/docs/precompiled
- Binary archive: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0-windows-x64.zip
- Source archive: https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz
- Documentation: https://developers.google.com/speed/webp/docs/dwebp

### Provenance and integrity

- Packaged binary: `App/Native/dwebp.exe`
- Architecture: Windows x86-64 (AMD64), PE32+
- Binary size: 512,512 bytes
- Binary SHA-256: `17c1488bf84b7834e9aa908bb40afd0be2e55d57567d210e96336c56bb6ae993`
- Official Windows ZIP size: 4,106,264 bytes
- ZIP SHA-256: `48886f506b21f62e4661f0f4cbfca19800897c385128e8902542d29a950c93f1`
- Source archive SHA-256: `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`

The ZIP was downloaded over HTTPS from the link on Google's official documentation. ZIP CRC checks passed, and the archive MD5 (`e1137a78badd751a5bb27853f171691e`) matched Google's `x-goog-hash` response header and ETag. The SHA-256 hashes above were computed from the downloaded bytes. A detached GPG signature was not verified. Machine-readable details are in [App/Native/libwebp-provenance.json](App/Native/libwebp-provenance.json).

Static PE import inspection lists only Windows system libraries: `ole32.dll`, `SHLWAPI.dll`, `SHELL32.dll`, and `KERNEL32.dll`. This is an x64 utility; it is not an ARM64-native build. Static inspection does not replace Windows runtime testing.

The application uses `dwebp -pam -o - -- -` to exchange image bytes through redirected standard input/output; PAM retains the alpha channel. Animated WebP is intentionally unsupported. Google and the WebP contributors do not endorse this application.
