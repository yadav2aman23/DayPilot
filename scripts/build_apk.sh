#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v flutter >/dev/null 2>&1 || { echo 'Flutter SDK not found.'; exit 1; }
if [[ ! -d "$ROOT/android" ]]; then
  echo 'Android platform files are missing. Run: bash scripts/setup_android.sh'
  exit 1
fi
cd "$ROOT"
flutter pub get
flutter build apk --release
echo
echo "APK built at: $ROOT/build/app/outputs/flutter-apk/app-release.apk"
