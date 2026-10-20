# DayPilot — Android starter app

DayPilot is an Android-first personal scheduler and accountability tracker. This first build is a local-first Flutter app; tasks, notes, check-ins and schedule settings are stored on the phone.

## Included in this version

- Dashboard with task totals, overdue count and tracked time.
- Task creation/editing: date, start/end times, category, priority, advance reminder and task notes.
- Start timer, progress percentage, status updates, completion, overdue reminders and rescheduling.
- Reschedule history retained on the task.
- Daily activity check-ins with status and notes.
- Configurable routine window, active weekdays, check-in interval and unanswered-reminder interval.
- Personal notes with create/edit/delete.
- Reports: planned vs tracked time, completion, category time and overdue tasks.
- App PIN lock stored using the device secure-storage service, plus fingerprint/biometric unlock where supported.
- Local notifications with Android notification channels and reboot rescheduling declarations.

## Quick setup on Kali Linux / Linux

1. Install the **Flutter SDK** and Android Studio/Android SDK. Follow the official guide: https://docs.flutter.dev/get-started/install
2. Extract this project and open a terminal in the `DayPilotMobile` folder.
3. Generate the Android platform folder and fetch packages:

   ```bash
   bash scripts/setup_android.sh
   ```

4. On your Android phone, enable **Developer options → USB debugging**, connect it with USB, and approve the computer prompt. Alternatively, start an Android emulator.
5. Check that Flutter sees the device and launch DayPilot:

   ```bash
   flutter devices
   flutter run
   ```

6. To build an installable APK:

   ```bash
   bash scripts/build_apk.sh
   ```

   Output: `build/app/outputs/flutter-apk/app-release.apk`

## First-run checklist

- Allow DayPilot notifications when Android asks.
- In Android Settings, ensure DayPilot notifications are enabled on the lock screen.
- If your phone has aggressive battery management, set DayPilot battery usage to **Unrestricted** or allow background activity. Menu wording differs by device manufacturer.
- If you want app protection, open DayPilot → lock card on the dashboard and set a 4–8 digit PIN. Fingerprint/biometrics are offered when available.
- Set your daily routine through the tuning/settings icon.

## Reminder behaviour and current limitations

- Task reminders use Android scheduled local notifications with `inexactAllowWhileIdle`. Android/OEM battery and Do Not Disturb settings can delay or silence alerts. This app does not force the display to wake or bypass Do Not Disturb.
- The first implementation queues a finite batch of reminders (12 task overdue follow-ups at your selected interval, and up to 39 check-in repeats at your selected interval). At the default 5-minute setting, that is about 1 hour of task follow-ups and 3 hours 15 minutes of check-in repeats per scheduled batch. Opening/resuming the app queues another batch for overdue tasks. An indefinitely repeating native Android scheduler/service is a separate hardening step and should be tested on the target phone.
- Exact-to-the-minute alarm delivery is not guaranteed in this version; exact alarms need additional Android permission/configuration and user approval on newer Android versions.
- App lock is an in-app gate, not device encryption. If the app is uninstalled or its app data is cleared, local app data may be lost. Do not store sensitive passwords or secrets in notes.
- The source was prepared in an environment without the Flutter SDK, so an APK could not be built or device-tested here. Run `flutter pub get` / `flutter run` on a machine with Flutter installed and address any SDK-specific build differences.

## Key files

- `lib/main.dart` — UI, local data models, task actions, settings, local notifications and app-lock flow.
- `pubspec.yaml` — Flutter package dependencies.
- `scripts/setup_android.sh` — Generates and patches Flutter's Android project files.
- `scripts/build_apk.sh` — Builds a release APK after setup.

## Data and privacy

This starter version uses local device storage only and does not send tasks or notes to a server. Shared preferences stores ordinary app data; the app PIN uses Android-backed secure storage. Cloud backup/sync is not included.
