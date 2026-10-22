#!/usr/bin/env bash
# scripts/package_app.sh
# Packages Niri on macOS into a standalone, unified, runnable macOS application bundle: dist/Niri.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/Niri.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"

echo "============================================================"
echo "Packaging Niri for macOS (Apple Silicon aarch64)"
echo "Output Bundle: ${APP_BUNDLE}"
echo "============================================================"

# 1. Clean previous bundle
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}/scripts"
mkdir -p "${RESOURCES_DIR}/vm_images"

# 2. Build the Swift/SwiftUI GUI App Launcher
echo "[BUILD] Compiling NiriApp native GUI launcher..."
swiftc -O -warnings-as-errors -parse-as-library \
    -framework SwiftUI -framework AppKit -framework Foundation -framework Combine \
    -I "${REPO_ROOT}/apps/niri_mac_gui/Libraries" -L "${REPO_ROOT}/apps/niri_mac_gui/Libraries" -lSwiftTerm \
    -plugin-path /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins \
    "${REPO_ROOT}/apps/niri_mac_gui/Sources/main.swift" \
    "${REPO_ROOT}/apps/niri_mac_gui/Sources/Models"/*.swift \
    "${REPO_ROOT}/apps/niri_mac_gui/Sources/Views"/*.swift \
    -o "${MACOS_DIR}/NiriApp"

# 3. Locate & copy Niri compositor binary
if [[ -f "${REPO_ROOT}/target/release/niri" ]]; then
    echo "[COPY] Using release niri binary..."
    cp "${REPO_ROOT}/target/release/niri" "${MACOS_DIR}/niri"
elif [[ -f "${REPO_ROOT}/target/debug/niri" ]]; then
    echo "[COPY] Using debug niri binary..."
    cp "${REPO_ROOT}/target/debug/niri" "${MACOS_DIR}/niri"
else
    echo "[ERROR] No niri binary found in target!"
    exit 1
fi
chmod 755 "${MACOS_DIR}/niri"

# 4. Build & copy Apple Virtualization MicroVM launcher
echo "[BUILD] Compiling microvm_launcher..."
swiftc -O "${REPO_ROOT}/vm/host/microvm_launcher.swift" -o "${MACOS_DIR}/microvm_launcher"
chmod 755 "${MACOS_DIR}/microvm_launcher"

# 5. Build & copy host vsock bridge
echo "[BUILD] Building niri-vsock-host bridge..."
cargo build --release --manifest-path "${REPO_ROOT}/vm/host/Cargo.toml"
cp "${REPO_ROOT}/vm/host/target/release/niri-vsock-host" "${MACOS_DIR}/niri-vsock-host"
chmod 755 "${MACOS_DIR}/niri-vsock-host"

# 6. Copy Resources & Scripts
echo "[COPY] Copying resources and configuration..."
cp "${REPO_ROOT}/resources/default-config.kdl" "${RESOURCES_DIR}/"
cp "${REPO_ROOT}/resources/cursor.rgba" "${RESOURCES_DIR}/"
cp "${REPO_ROOT}/vm/scripts/install_arch_assets.sh" "${RESOURCES_DIR}/scripts/" 2>/dev/null || true
cp "${REPO_ROOT}/vm/scripts/install_assets.sh" "${RESOURCES_DIR}/scripts/"
cp "${REPO_ROOT}/vm/scripts/launch_vz.sh" "${RESOURCES_DIR}/scripts/"
chmod 755 "${RESOURCES_DIR}/scripts"/*.sh

# Copy VM assets if available
if [[ -f "${REPO_ROOT}/vm/images/Image" ]]; then
    cp "${REPO_ROOT}/vm/images/Image" "${RESOURCES_DIR}/vm_images/"
    (cd "${RESOURCES_DIR}/vm_images" && ln -sf Image vmlinuz)
fi
if [[ -f "${REPO_ROOT}/vm/images/initramfs.cpio.gz" ]]; then
    cp "${REPO_ROOT}/vm/images/initramfs.cpio.gz" "${RESOURCES_DIR}/vm_images/"
fi

# 7. Write Info.plist and PkgInfo
cat << 'EOF' > "${CONTENTS}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NiriApp</string>
    <key>CFBundleIdentifier</key>
    <string>org.niri.NiriApp</string>
    <key>CFBundleName</key>
    <string>Niri</string>
    <key>CFBundleDisplayName</key>
    <string>Niri</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>26.4.0</string>
    <key>CFBundleVersion</key>
    <string>26.4.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo -n "APPL????" > "${CONTENTS}/PkgInfo"

# 8. Sign with Hypervisor & Virtualization Entitlements
echo "[SIGN] Signing bundle and binaries with entitlements..."
ENTITLEMENTS="${REPO_ROOT}/vm/host/entitlements.plist"
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${MACOS_DIR}/microvm_launcher"
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${MACOS_DIR}/niri-vsock-host"
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${MACOS_DIR}/niri"
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${MACOS_DIR}/NiriApp"
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP_BUNDLE}"

echo "============================================================"
echo "Niri.app successfully packaged!"
echo "Bundle Path: ${APP_BUNDLE}"
echo "Run via:     open ${APP_BUNDLE}"
echo "        or:  ${MACOS_DIR}/NiriApp"
echo "============================================================"
