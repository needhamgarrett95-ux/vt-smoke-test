# vt-smoke-test

Minimal VideoToolbox H.264 encoder smoke test for the jailbroken iPad 7
(iPadOS 18.7.10, palera1n rootless). Answers one question: does
`VTCompressionSession` create a **hardware** H.264 encoder and emit decodable
Annex-B NAL units outside a foreground app?

Usage on the iPad (as root or mobile):

```
./vt-smoke-test hw    # require hardware encoder; exits 1 if none
./vt-smoke-test any   # allow software fallback; log says which ran
```

Writes `vt-smoke-<mode>.h264` (Annex-B) in the current directory.
Exit 0 = >=10 frames encoded, output non-empty.

Built by GitHub Actions (macos-26, iphoneos SDK, arm64, ad-hoc codesign).
No entitlements — VideoToolbox is a public framework.
