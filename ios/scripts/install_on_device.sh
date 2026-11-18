#!/bin/zsh
set -euo pipefail

task_device="${1:?Usage: scripts/install_on_device.sh DEVICE_ID [DERIVED_DATA_PATH]}"
task_build_dir="${2:-/private/tmp/quill-device-build}"
task_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"

xcodebuild -project "$task_root/QuillNative.xcodeproj" \
  -scheme QuillNative -configuration Debug \
  -destination "id=$task_device" -derivedDataPath "$task_build_dir" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

xcrun devicectl device install app --device "$task_device" \
  "$task_build_dir/Build/Products/Debug-iphoneos/QuillNative.app"
xcrun devicectl device process launch --device "$task_device" \
  com.quillnative.app
