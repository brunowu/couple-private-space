#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
dependency_root="$project_root/.dependencies"
download_root="$dependency_root/downloads"
source_root="$dependency_root/src"

libsignal_version="0.102.2"
sqlcipher_version="4.19.0"
protoc_version="36.1"

mkdir -p "$download_root" "$source_root"

download_and_verify() {
  local url="$1"
  local output="$2"
  local expected="$3"
  if [[ ! -f "$output" ]]; then
    curl -fL --retry 3 "$url" -o "$output"
  fi
  local actual
  actual="$(shasum -a 256 "$output" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "Checksum mismatch: $output"
    return 1
  fi
}

download_and_verify \
  "https://github.com/signalapp/libsignal/archive/refs/tags/v${libsignal_version}.tar.gz" \
  "$download_root/libsignal-v${libsignal_version}.tar.gz" \
  "b48e33d661130f7ac764dd59d3482a081214a6748d9a25236c2dfd62f53d8f31"
download_and_verify \
  "https://github.com/signalapp/libsignal/releases/download/v${libsignal_version}/libsignal-client-ios-build-v${libsignal_version}.tar.gz" \
  "$download_root/libsignal-client-ios-build-v${libsignal_version}.tar.gz" \
  "864c8b27e220635231754719a6891e6548d11f40fe1a6d696225d08f5bd2384e"
download_and_verify \
  "https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v${sqlcipher_version}.tar.gz" \
  "$download_root/sqlcipher-v${sqlcipher_version}.tar.gz" \
  "7075f96cbabe45b4ecfc2e6b1745a625f856f695b0827a5506ce9ed85b906aa0"
download_and_verify \
  "https://github.com/protocolbuffers/protobuf/releases/download/v${protoc_version}/protoc-${protoc_version}-osx-universal_binary.zip" \
  "$download_root/protoc-${protoc_version}.zip" \
  "09cd927fd2a132e8fa5e2663f4cb6f11168126eb62cf21da68b51d74c2107a7e"

if [[ ! -d "$source_root/libsignal-${libsignal_version}" ]]; then
  tar -xzf "$download_root/libsignal-v${libsignal_version}.tar.gz" -C "$source_root"
fi
if [[ ! -d "$source_root/sqlcipher-${sqlcipher_version}" ]]; then
  tar -xzf "$download_root/sqlcipher-v${sqlcipher_version}.tar.gz" -C "$source_root"
fi
if [[ ! -x "$dependency_root/protoc/bin/protoc" ]]; then
  mkdir -p "$dependency_root/protoc"
  unzip -q "$download_root/protoc-${protoc_version}.zip" -d "$dependency_root/protoc"
  chmod +x "$dependency_root/protoc/bin/protoc"
fi

signal_source="$source_root/libsignal-${libsignal_version}"
if [[ ! -f "$signal_source/target/debug/libsignal_ffi.a" ]]; then
  (
    cd "$signal_source"
    PROTOC="$dependency_root/protoc/bin/protoc" cargo build --locked -p libsignal-ffi --features libsignal-bridge-testing
  )
fi

sqlcipher_source="$source_root/sqlcipher-${sqlcipher_version}"
if [[ ! -f "$sqlcipher_source/sqlite3.c" ]]; then
  (
    cd "$sqlcipher_source"
    ./configure --with-tempstore=always --disable-load-extension --disable-tcl
    make sqlite3.c
  )
fi
mkdir -p "$dependency_root/CSQLCipher/include"
cp "$sqlcipher_source/sqlite3.c" "$dependency_root/CSQLCipher/sqlite3.c"
cp "$sqlcipher_source/sqlite3.h" "$dependency_root/CSQLCipher/include/sqlite3.h"
printf '%s\n' '#define SQLITE_HAS_CODEC 1' '#include "sqlite3.h"' > "$dependency_root/CSQLCipher/include/shim.h"
printf '%s\n' 'module CSQLCipher {' '  header "shim.h"' '  export *' '}' > "$dependency_root/CSQLCipher/include/module.modulemap"

ios_build="$dependency_root/ios-build"
if [[ ! -f "$ios_build/target/aarch64-apple-ios/release/libsignal_ffi.a" ]]; then
  mkdir -p "$ios_build"
  tar -xzf "$download_root/libsignal-client-ios-build-v${libsignal_version}.tar.gz" -C "$ios_build"
fi

framework_work="$dependency_root/xcframework-work"
headers="$framework_work/Headers"
mkdir -p "$headers"
cp "$signal_source/swift/Sources/SignalFfi/signal_ffi.h" "$headers/"
cp "$signal_source/swift/Sources/SignalFfi/signal_ffi_testing.h" "$headers/"
cp "$signal_source/swift/Sources/SignalFfi/module.modulemap" "$headers/"
lipo -create \
  "$ios_build/target/aarch64-apple-ios-sim/release/libsignal_ffi.a" \
  "$ios_build/target/x86_64-apple-ios/release/libsignal_ffi.a" \
  -output "$framework_work/libsignal_ffi-simulator.a"

rm -rf "$dependency_root/SignalNative.xcframework"
xcframework="$dependency_root/SignalNative.xcframework"
for slice in macos-arm64 ios-arm64 ios-arm64_x86_64-simulator; do
  mkdir -p "$xcframework/$slice/Headers"
  cp "$headers/"* "$xcframework/$slice/Headers/"
done
cp "$signal_source/target/debug/libsignal_ffi.a" "$xcframework/macos-arm64/libsignal_ffi.a"
cp "$ios_build/target/aarch64-apple-ios/release/libsignal_ffi.a" "$xcframework/ios-arm64/libsignal_ffi.a"
cp "$framework_work/libsignal_ffi-simulator.a" "$xcframework/ios-arm64_x86_64-simulator/libsignal_ffi.a"
cat > "$xcframework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
    <dict>
      <key>HeadersPath</key><string>Headers</string>
      <key>LibraryIdentifier</key><string>macos-arm64</string>
      <key>LibraryPath</key><string>libsignal_ffi.a</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>macos</string>
    </dict>
    <dict>
      <key>HeadersPath</key><string>Headers</string>
      <key>LibraryIdentifier</key><string>ios-arm64</string>
      <key>LibraryPath</key><string>libsignal_ffi.a</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
    </dict>
    <dict>
      <key>HeadersPath</key><string>Headers</string>
      <key>LibraryIdentifier</key><string>ios-arm64_x86_64-simulator</string>
      <key>LibraryPath</key><string>libsignal_ffi.a</string>
      <key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
      <key>SupportedPlatformVariant</key><string>simulator</string>
    </dict>
  </array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
PLIST

print "Dependencies are ready in $dependency_root"
