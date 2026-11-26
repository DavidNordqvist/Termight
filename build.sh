#!/bin/zsh
# Build the Rust core + Swift app and install Termight.app to /Applications.
# Needs full Xcode (App Intents metadata extraction is not in Command Line Tools).
#
# The Xcode project builds the Rust core itself, so this is the same build as
# pressing Run in Xcode, plus the install.
#
# Signs with the team set in the Xcode project. Building your own copy: set
# your team in Xcode (Signing & Capabilities) or export TERMIGHT_TEAM=<team ID>;
# a free Apple ID added in Xcode → Settings → Accounts is enough.
set -euo pipefail
cd "${0:A:h}/Termight"

xcodebuild -project Termight.xcodeproj -scheme Termight -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates -quiet build \
  ${TERMIGHT_TEAM:+DEVELOPMENT_TEAM=$TERMIGHT_TEAM}

rm -rf /Applications/Termight.app
cp -R build/Build/Products/Release/Termight.app /Applications/
rm -rf build/Build/Products   # one registered copy only, or Spotlight may ignore the intent
open /Applications/Termight.app   # launch once so Spotlight indexes the intent
echo "Installed /Applications/Termight.app — press ⌥Space (or ⌘Space → Run Command)"
