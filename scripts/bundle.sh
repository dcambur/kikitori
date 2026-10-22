#!/bin/zsh
# Build Kikitori.app from the SwiftPM package: release binary, resource bundle, Info.plist,
# ad-hoc signature. Usage: scripts/bundle.sh [debug|release]   → build/Kikitori.app
set -e
cd "${0:A:h}/.."
config=${1:-release}
swift build -c $config --product Kikitori
bin=$(swift build -c $config --show-bin-path)
app=build/Kikitori.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin/Kikitori $app/Contents/MacOS/
cp -R $bin/kikitori_KikitoriCore.bundle $app/Contents/Resources/
version=$(git describe --tags --always 2>/dev/null || echo dev)
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.kikitori</string>
  <key>CFBundleName</key><string>kikitori</string>
  <key>CFBundleDisplayName</key><string>kikitori</string>
  <key>CFBundleExecutable</key><string>Kikitori</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>kikitori listens to the app you choose so it can subtitle the stream. Audio is turned into text on this Mac and never recorded or sent anywhere.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>kikitori can listen to a microphone or audio input instead of an app.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>kikitori uses on-device speech recognition to turn Japanese speech into text.</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - $app
echo "built $app ($config, $version)"
