#!/bin/bash
# Регистрирует App Group через Xcode Automatic Signing (нужен вход Apple ID в Xcode).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_GROUP="group.com.glassyrecord.shared"
APP_ID="com.glassyrecord.app"
EXT_ID="com.glassyrecord.app.broadcast"

echo "==> 1/4  xcodegen generate"
xcodegen generate

echo "==> 2/4  Проверка entitlements"
for file in \
  "GlassyRecord/Resources/GlassyRecord.entitlements" \
  "GlassyRecordBroadcastUpload/GlassyRecordBroadcastUpload.entitlements"
do
  if ! plutil -extract com.apple.security.application-groups raw "$file" 2>/dev/null | grep -q "$APP_GROUP"; then
    echo "ОШИБКА: $file не содержит $APP_GROUP"
    exit 1
  fi
  echo "OK: $file"
done

echo "==> 3/4  Сборка с -allowProvisioningUpdates"
echo "     (Xcode создаст App Group и профили на developer.apple.com, если вы вошли в Apple ID)"
if ! xcodebuild -scheme GlassyRecord \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build 2>&1 | tee /tmp/glassyrecord-setup-build.log | tail -20; then
  echo ""
  echo "Сборка не прошла. Частые причины:"
  echo "  • Xcode → Settings → Accounts — добавьте Apple ID"
  echo "  • Выберите Team YSSY28XABK для обоих таргетов"
  echo "  • developer.apple.com → Identifiers → App Groups → создайте $APP_GROUP"
  echo "  • Привяжите группу к $APP_ID и $EXT_ID"
  echo ""
  echo "Открываю Xcode — проверьте Signing & Capabilities вручную."
  open "$ROOT/GlassyRecord.xcodeproj"
  exit 1
fi

echo "==> 4/4  Готово"
echo "App Group $APP_GROUP настроен. Удалите приложение с iPhone и Run снова."
