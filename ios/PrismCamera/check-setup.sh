#!/usr/bin/env bash
set -u

echo "Active developer directory:"
xcode-select --print-path
echo
echo "Xcode version:"
xcodebuild -version
echo
echo "Local code-signing identities:"
security find-identity -v -p codesigning
echo
echo "Connected Apple devices:"
xcrun devicectl list devices
