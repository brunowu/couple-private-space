#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

if [[ ! -d .dependencies/SignalNative.xcframework || ! -f .dependencies/CSQLCipher/sqlite3.c ]]; then
  ./scripts/bootstrap_dependencies.sh
fi

python3 scripts/generate_xcode_project.py >/dev/null
xcodebuild \
  -resolvePackageDependencies \
  -workspace CouplePrivateSpace.xcworkspace \
  -scheme CouplePrivateSpace \
  -derivedDataPath .build/xcode

open CouplePrivateSpace.xcworkspace
