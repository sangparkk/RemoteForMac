#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swift test --scratch-path build/swift-tests > build/core-tests.log 2>&1
xcodebuild -project RemoteTV.xcodeproj -scheme RemoteTVHost -configuration Debug \
  -derivedDataPath build/DerivedData build > build/mac-build.log 2>&1
xcodebuild -project RemoteTV.xcodeproj -scheme RemoteTVPhone -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/PhoneDerivedData CODE_SIGNING_ALLOWED=NO build > build/iphone-build.log 2>&1
xcodebuild -project RemoteTV.xcodeproj -scheme RemoteTVPhone -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceDerivedData CODE_SIGNING_ALLOWED=NO build > build/iphone-device-build.log 2>&1
echo 'Core tests and three build variants passed. Device installation and GUI/service tests are separate.'
