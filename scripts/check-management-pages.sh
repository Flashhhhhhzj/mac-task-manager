#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MacSystemHelper
management_bin_dir="$(swift build -c release --show-bin-path)"
management_tmp_dir="$(mktemp -d)"
trap 'rm -rf "$management_tmp_dir"' EXIT

if [[ -f "$management_bin_dir/MacManagement.o" ]]; then
    management_objects=("$management_bin_dir/MacManagement.o" "$management_bin_dir/MacSMC.o")
else
    management_objects=("$management_bin_dir"/MacManagement.build/*.o "$management_bin_dir"/MacSMC.build/*.o)
fi

swiftc Sources/MacTaskManager/ProcessTableData.swift Sources/MacTaskManager/AppHistoryStore.swift \
    Tests/MacTaskManagerTests/HistoryChecks.swift -o "$management_tmp_dir/history"
"$management_tmp_dir/history"

swiftc -I "$management_bin_dir" -I "$management_bin_dir/Modules" -parse-as-library \
    Tests/MacTaskManagerTests/SystemManagementChecks.swift "${management_objects[@]}" \
    -framework IOKit -o "$management_tmp_dir/services"
"$management_tmp_dir/services"

swiftc -parse-as-library -I "$management_bin_dir" -I "$management_bin_dir/Modules" \
    Tests/MacTaskManagerTests/CatalogReadChecks.swift "${management_objects[@]}" \
    -framework IOKit -o "$management_tmp_dir/catalog-reads"
"$management_tmp_dir/catalog-reads" "$management_bin_dir/MacSystemHelper"

loading_app="$management_tmp_dir/LoadingChecks.app"
mkdir -p "$loading_app/Contents/MacOS"
cat > "$loading_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>LoadingChecks</string><key>CFBundleIdentifier</key><string>local.MacTaskManager.LoadingChecks</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc -parse-as-library -I "$management_bin_dir" -I "$management_bin_dir/Modules" \
    Sources/MacTaskManager/ProcessTableData.swift Sources/MacTaskManager/TaskManagerPage.swift \
    Sources/MacTaskManager/ManagementWorkspace.swift Tests/MacTaskManagerTests/ManagementLoadingChecks.swift \
    "${management_objects[@]}" -framework IOKit -o "$loading_app/Contents/MacOS/LoadingChecks"
"$loading_app/Contents/MacOS/LoadingChecks"

# This optional check only creates and removes its own uniquely named user LaunchAgent.
if [[ "${1:-}" == "--user-service-lifecycle" ]]; then
    swiftc -parse-as-library -I "$management_bin_dir" -I "$management_bin_dir/Modules" Tests/MacTaskManagerTests/ServiceLifecycleChecks.swift \
        "${management_objects[@]}" -framework IOKit -o "$management_tmp_dir/lifecycle"
    "$management_tmp_dir/lifecycle"
fi
