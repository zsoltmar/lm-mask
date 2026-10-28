#!/usr/bin/env bash
# Build (signed, Debug), copy the app into /Applications, and relaunch it.
# Usage: scripts/dev-install.sh [--generate]   (--generate runs xcodegen first; needed when files were added)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--generate" ]]; then xcodegen generate; fi

xcodebuild -project LMMask.xcodeproj -scheme LMMask -configuration Debug build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration 2>&1 | tee BUILD_LOG.txt | grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)" || true
grep -q "BUILD SUCCEEDED" BUILD_LOG.txt || { echo "Build failed — not installing."; exit 1; }

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/LMMask-*/Build/Products/Debug/"LM Mask.app" | head -1)
[[ -d "$APP" ]] || { echo "App not found in DerivedData"; exit 1; }

pkill -x "LM Mask" 2>/dev/null || true
rm -rf "/Applications/LM Mask.app"
cp -R "$APP" /Applications/
open "/Applications/LM Mask.app"
echo "Installed $(date +%H:%M:%S): /Applications/LM Mask.app"
