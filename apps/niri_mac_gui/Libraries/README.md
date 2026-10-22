# SwiftTerm Precompiled Library for Niri on macOS

This directory contains precompiled binaries for Miguel de Icaza's [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) terminal emulator library (`aarch64-apple-macos`).

### Files:
- `libSwiftTerm.a`: Static archive containing `TerminalView` and terminal emulation engine.
- `SwiftTerm.swiftmodule/`: Swift module interfaces, doc, and ABI definitions for arm64.

### Building from Source:
```bash
git clone https://github.com/migueldeicaza/SwiftTerm.git /tmp/SwiftTerm
cd /tmp/SwiftTerm
swift build -c release --arch arm64
cp .build/arm64-apple-macosx/release/libSwiftTerm.a <repo>/apps/niri_mac_gui/Libraries/
cp -R .build/arm64-apple-macosx/release/SwiftTerm.swiftmodule <repo>/apps/niri_mac_gui/Libraries/
```
