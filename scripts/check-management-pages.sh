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

swiftc -I "$management_bin_dir" -I "$management_bin_dir/Modules" Sources/MacTaskManager/StartupCatalog.swift \
    Tests/MacTaskManagerTests/SystemManagementChecks.swift "${management_objects[@]}" \
    -framework IOKit -o "$management_tmp_dir/services"
"$management_tmp_dir/services"

# This optional check only creates and removes its own uniquely named user LaunchAgent.
if [[ "${1:-}" == "--user-service-lifecycle" ]]; then
    swiftc -parse-as-library -I "$management_bin_dir" -I "$management_bin_dir/Modules" Tests/MacTaskManagerTests/ServiceLifecycleChecks.swift \
        "${management_objects[@]}" -framework IOKit -o "$management_tmp_dir/lifecycle"
    "$management_tmp_dir/lifecycle"
fi
