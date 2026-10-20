#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v flutter >/dev/null 2>&1 || {
  echo "Flutter SDK not found. Install Flutter first: https://docs.flutter.dev/get-started/install"
  exit 1
}

if [[ ! -d "$ROOT/android" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "Generating standard Android platform files with Flutter..."
  flutter create --project-name daypilot --org com.daypilot --platforms android "$TMP/daypilot"
  cp -a "$TMP/daypilot/android" "$ROOT/android"
else
  echo "Android platform folder already exists; keeping it."
fi

python3 - "$ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
manifest = root / 'android/app/src/main/AndroidManifest.xml'
if not manifest.exists():
    raise SystemExit(f'Missing {manifest}')
s = manifest.read_text()
permissions = '''
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.VIBRATE" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.USE_BIOMETRIC" />
    <uses-permission android:name="android.permission.USE_FINGERPRINT" />
'''
for p in re.findall(r'<uses-permission[^>]+android:name="([^"]+)"[^>]*/>', permissions):
    if f'android:name="{p}"' not in s:
        s = s.replace('<application', permissions + '\n    <application', 1)
receivers = '''
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON" />
            </intent-filter>
        </receiver>
'''
if 'ScheduledNotificationReceiver' not in s:
    s = s.replace('</application>', receivers + '\n    </application>', 1)
s = re.sub(r'<application(?![^>]*android:allowBackup=)', '<application android:allowBackup="false"', s, count=1)
s = s.replace('android:label="daypilot"', 'android:label="DayPilot"')
manifest.write_text(s)

# local_auth requires a FragmentActivity for Android.
for p in (root / 'android/app/src/main').rglob('MainActivity.kt'):
    t = p.read_text().replace('io.flutter.embedding.android.FlutterActivity', 'io.flutter.embedding.android.FlutterFragmentActivity')
    t = t.replace('class MainActivity: FlutterActivity()', 'class MainActivity: FlutterFragmentActivity()')
    t = t.replace('class MainActivity : FlutterActivity()', 'class MainActivity : FlutterFragmentActivity()')
    p.write_text(t)

# AppCompat launch theme is recommended by local_auth for older Android versions.
for p in (root / 'android/app/src/main/res').rglob('styles.xml'):
    t = p.read_text()
    t = t.replace('parent="@android:style/Theme.Light.NoTitleBar"', 'parent="Theme.AppCompat.DayNight.NoActionBar"')
    t = t.replace('parent="@android:style/Theme.Black.NoTitleBar"', 'parent="Theme.AppCompat.DayNight.NoActionBar"')
    p.write_text(t)

# Add AppCompat so the launch theme is resolved at build time.
gradle = root / 'android/app/build.gradle.kts'
if gradle.exists():
    t = gradle.read_text()
    if 'androidx.appcompat:appcompat' not in t:
        if 'dependencies {' in t:
            t = t.replace('dependencies {', 'dependencies {\n    implementation("androidx.appcompat:appcompat:1.7.0")', 1)
        else:
            t += '\ndependencies { implementation("androidx.appcompat:appcompat:1.7.0") }\n'
    # Use SDK 35 or newer for Android 13 notification permission support.
    t = re.sub(r'compileSdk\s*=\s*flutter\.compileSdkVersion', 'compileSdk = 36', t)
    gradle.write_text(t)
PY

cd "$ROOT"
flutter pub get
cat <<'MSG'

Android project setup is complete.
Next steps:
  1) Connect your Android phone with USB debugging enabled, or start an emulator.
  2) Run: flutter devices
  3) Run: flutter run

To create an APK later, run: bash scripts/build_apk.sh
MSG
