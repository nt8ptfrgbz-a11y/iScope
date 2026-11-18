#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -quiet -project iScope.xcodeproj -scheme iScope -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build
mkdir -p build
ditto build/DerivedData/Build/Products/Release/iScope.app build/iScope.app
print "App: ${PWD}/build/iScope.app"
