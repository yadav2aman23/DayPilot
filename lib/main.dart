import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const _green = Color(0xFF236844);
const _greenDark = Color(0xFF173A2A);
const _softGreen = Color(0xFFE7F3EA);
const _pinKey = 'daypilot_secure_pin';
const _lockEnabledKey = 'daypilot_lock_enabled';

final _notifications = FlutterLocalNotificationsPlugin();
final _secureStorage = const FlutterSecureStorage();
final ValueNotifier<String?> notificationPayload = ValueNotifier<String?>(null);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReminderService.initialize();
  runApp(const DayPilotApp());
}

class ReminderService {
  static const _taskChannel = AndroidNotificationChannel(
    'daypilot_task_reminders',
    'Task reminders',
    description: 'Task start, progress and overdue reminders',
    importance: Importance.max,
  );
  static const _checkinChannel = AndroidNotificationChannel(
    'daypilot_daily_checkins',
    'Daily check-ins',
    description: 'Prompts to update your current activity',
    importance: Importance.max,
  );
  static const int _checkinBase = 720000;

  static Future<void> initialize() async {
    tzdata.initializeTimeZones();
    try {
      final zoneName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zoneName));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Kolkata'));
    }
    const init = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _notifications.initialize(
      init,
      onDidReceiveNotificationResponse: (response) {
        notificationPayload.value = response.payload;
      },
    );
    final android = _notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(_taskChannel);
    await android?.createNotificationChannel(_checkinChannel);
    await android?.requestNotificationsPermission();
    try {
      final launch = await _notifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        notificationPayload.value = launch?.notificationResponse?.payload;
      }
    } catch (_) {}
  }

  static int _stableId(String value) {
    var hash = 0x811C9DC5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }

  static Future<void> _schedule({
    required int id,
    required String title,
    required String body,
    required DateTime at,
    required String payload,
    required bool checkin,
  }) async {
    if (!at.isAfter(DateTime.now())) return;
    await _notifications.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(at, tz.local),
      NotificationDetails(
        android: AndroidNotificationDetails(
          checkin ? _checkinChannel.id : _taskChannel.id,
          checkin ? _checkinChannel.name : _taskChannel.name,
          channelDescription:
              checkin ? _checkinChannel.description : _taskChannel.description,
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          styleInformation: const BigTextStyleInformation(''),
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: payload,
    );
  }

  static Future<void> scheduleTask(TaskItem task, AppSettings settings) async {
    await cancelTask(task.id);
    if (task.completed) return;
    final start = task.startAt;
    final end = task.endAt;
    final prefix = _stableId(task.id) % 300000;
    if (start.isAfter(DateTime.now())) {
      final reminderAt = start.subtract(Duration(minutes: task.advanceMinutes));
      await _schedule(
        id: prefix + 100000,
        title: 'Task coming up',
        body: '${task.title} starts in ${task.advanceMinutes} minutes.',
        at: reminderAt.isAfter(DateTime.now())
            ? reminderAt
            : DateTime.now().add(const Duration(seconds: 5)),
        payload: 'task:${task.id}',
        checkin: false,
      );
    }
    if (end.isAfter(DateTime.now())) {
      await _schedule(
        id: prefix + 400000,
        title: 'Task progress check',
        body:
            'How is “${task.title}” going? Update progress or mark it complete.',
        at: end,
        payload: 'task:${task.id}',
        checkin: false,
      );
      // Queue a first hour of follow-up alerts. Pending tasks are queued again
      // when the app starts/resumes; Android vendors may still apply battery limits.
      for (var i = 1; i <= 12; i++) {
        final at = end.add(Duration(minutes: settings.repeatMinutes * i));
        if (at.hour > settings.dayEnd.hour ||
            (at.hour == settings.dayEnd.hour &&
                at.minute > settings.dayEnd.minute)) break;
        await _schedule(
          id: _stableId('${task.id}:overdue:$i') % 2000000000,
          title: 'Task still pending',
          body:
              '“${task.title}” is not marked complete. Open DayPilot to update it.',
          at: at,
          payload: 'task:${task.id}',
          checkin: false,
        );
      }
    } else if (!task.completed && end.isBefore(DateTime.now())) {
      // Re-start a reminder batch for an overdue task when DayPilot is opened.
      for (var i = 1; i <= 12; i++) {
        final at =
            DateTime.now().add(Duration(minutes: settings.repeatMinutes * i));
        final routineEnd = DateTime(at.year, at.month, at.day,
            settings.dayEnd.hour, settings.dayEnd.minute);
        if (at.isAfter(routineEnd)) break;
        await _schedule(
          id: _stableId('${task.id}:overdue:refresh:$i') % 2000000000,
          title: 'Task still pending',
          body:
              '“${task.title}” remains incomplete. Update progress or reschedule it.',
          at: at,
          payload: 'task:${task.id}',
          checkin: false,
        );
      }
    }
  }

  static Future<void> cancelTask(String taskId) async {
    final prefix = _stableId(taskId) % 300000;
    await _notifications.cancel(prefix + 100000);
    await _notifications.cancel(prefix + 400000);
    for (var i = 1; i <= 12; i++) {
      await _notifications.cancel(_stableId('$taskId:overdue:$i') % 2000000000);
      await _notifications
          .cancel(_stableId('$taskId:overdue:refresh:$i') % 2000000000);
    }
  }

  static Future<void> cancelCheckinChain() async {
    for (var i = 0; i < 40; i++) {
      await _notifications.cancel(_checkinBase + i);
    }
  }

  static Future<void> scheduleCheckin(DateTime at, AppSettings settings) async {
    await cancelCheckinChain();
    if (!settings.checkinsEnabled) return;
    final end = DateTime(at.year, at.month, at.day, settings.dayEnd.hour,
        settings.dayEnd.minute);
    if (at.isAfter(end)) return;
    await _schedule(
      id: _checkinBase,
      title: 'DayPilot check-in',
      body:
          'What are you working on right now? Open DayPilot to submit your update.',
      at: at,
      payload: 'checkin',
      checkin: true,
    );
    for (var i = 1; i < 40; i++) {
      final repeatAt = at.add(Duration(minutes: settings.repeatMinutes * i));
      if (repeatAt.isAfter(end)) break;
      await _schedule(
        id: _checkinBase + i,
        title: 'Daily update still needed',
        body: 'Please complete your pending DayPilot check-in.',
        at: repeatAt,
        payload: 'checkin',
        checkin: true,
      );
    }
  }
}

class TaskItem {
  TaskItem({
    required this.id,
    required this.title,
    required this.date,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    this.category = 'Study',
    this.priority = 'Medium',
    this.notes = '',
    this.status = 'Pending',
    this.progress = 0,
    this.advanceMinutes = 10,
    this.actualStart,
    this.actualEnd,
    this.segmentStart,
    this.trackedSeconds = 0,
    List<String>? history,
  }) : history = history ?? <String>[];

  String id, title, category, priority, notes, status;
  DateTime date;
  int startHour, startMinute, endHour, endMinute, progress, advanceMinutes;
  DateTime? actualStart, actualEnd, segmentStart;
  int trackedSeconds;
  List<String> history;
  bool get completed => status == 'Completed';
  DateTime get startAt =>
      DateTime(date.year, date.month, date.day, startHour, startMinute);
  DateTime get endAt =>
      DateTime(date.year, date.month, date.day, endHour, endMinute);
  bool get overdue => !completed && DateTime.now().isAfter(endAt);
  Duration get actualDuration {
    var seconds = trackedSeconds;
    if (status == 'In progress' && segmentStart != null) {
      final current = DateTime.now().difference(segmentStart!).inSeconds;
      if (current > 0) seconds += current;
    }
    return Duration(seconds: seconds);
  }

  void pauseTracking() {
    final segment = segmentStart;
    if (segment != null) {
      final seconds = DateTime.now().difference(segment).inSeconds;
      if (seconds > 0) trackedSeconds += seconds;
      segmentStart = null;
    }
  }

  String get scheduleLabel =>
      '${DateFormat('EEE, d MMM').format(date)} · ${timeText(startHour, startMinute)}–${timeText(endHour, endMinute)}';
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'date': date.toIso8601String(),
        'startHour': startHour,
        'startMinute': startMinute,
        'endHour': endHour,
        'endMinute': endMinute,
        'category': category,
        'priority': priority,
        'notes': notes,
        'status': status,
        'progress': progress,
        'advanceMinutes': advanceMinutes,
        'actualStart': actualStart?.toIso8601String(),
        'actualEnd': actualEnd?.toIso8601String(),
        'segmentStart': segmentStart?.toIso8601String(),
        'trackedSeconds': trackedSeconds,
        'history': history,
      };
  factory TaskItem.fromJson(Map<String, dynamic> j) => TaskItem(
        id: j['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
        title: j['title'] ?? 'Untitled task',
        date: DateTime.tryParse(j['date'] ?? '') ?? DateTime.now(),
        startHour: j['startHour'] ?? 10,
        startMinute: j['startMinute'] ?? 0,
        endHour: j['endHour'] ?? 11,
        endMinute: j['endMinute'] ?? 0,
        category: j['category'] ?? 'Study',
        priority: j['priority'] ?? 'Medium',
        notes: j['notes'] ?? '',
        status: j['status'] ?? 'Pending',
        progress: j['progress'] ?? 0,
        advanceMinutes: j['advanceMinutes'] ?? 10,
        actualStart: j['actualStart'] == null
            ? null
            : DateTime.tryParse(j['actualStart']),
        actualEnd:
            j['actualEnd'] == null ? null : DateTime.tryParse(j['actualEnd']),
        segmentStart: j['segmentStart'] == null
            ? null
            : DateTime.tryParse(j['segmentStart']),
        trackedSeconds: j['trackedSeconds'] ?? 0,
        history: (j['history'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}

class NoteItem {
  NoteItem(
      {required this.id,
      required this.title,
      required this.body,
      required this.updatedAt});
  String id, title, body;
  DateTime updatedAt;
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'updatedAt': updatedAt.toIso8601String()
      };
  factory NoteItem.fromJson(Map<String, dynamic> j) => NoteItem(
        id: j['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
        title: j['title'] ?? '',
        body: j['body'] ?? '',
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? '') ?? DateTime.now(),
      );
}

class CheckinItem {
  CheckinItem(
      {required this.activity,
      required this.status,
      required this.startedAt,
      this.endedAt,
      this.notes = ''});
  String activity, status, notes;
  DateTime startedAt;
  DateTime? endedAt;
  Map<String, dynamic> toJson() => {
        'activity': activity,
        'status': status,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt?.toIso8601String(),
        'notes': notes,
      };
  factory CheckinItem.fromJson(Map<String, dynamic> j) => CheckinItem(
        activity: j['activity'] ?? 'Activity',
        status: j['status'] ?? 'In progress',
        startedAt: DateTime.tryParse(j['startedAt'] ?? '') ?? DateTime.now(),
        endedAt: j['endedAt'] == null ? null : DateTime.tryParse(j['endedAt']),
        notes: j['notes'] ?? '',
      );
}

class AppSettings {
  int dayStartHour, dayStartMinute, dayEndHour, dayEndMinute;
  int intervalHours, repeatMinutes;
  bool checkinsEnabled, appLockEnabled;
  List<int> activeDays;
  AppSettings({
    this.dayStartHour = 7,
    this.dayStartMinute = 0,
    this.dayEndHour = 23,
    this.dayEndMinute = 0,
    this.intervalHours = 2,
    this.repeatMinutes = 5,
    this.checkinsEnabled = true,
    this.appLockEnabled = false,
    List<int>? activeDays,
  }) : activeDays = activeDays ?? [1, 2, 3, 4, 5, 6, 7];
  TimeOfDay get dayStart =>
      TimeOfDay(hour: dayStartHour, minute: dayStartMinute);
  TimeOfDay get dayEnd => TimeOfDay(hour: dayEndHour, minute: dayEndMinute);
  Map<String, dynamic> toJson() => {
        'dayStartHour': dayStartHour,
        'dayStartMinute': dayStartMinute,
        'dayEndHour': dayEndHour,
        'dayEndMinute': dayEndMinute,
        'intervalHours': intervalHours,
        'repeatMinutes': repeatMinutes,
        'checkinsEnabled': checkinsEnabled,
        'appLockEnabled': appLockEnabled,
        'activeDays': activeDays,
      };
  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        dayStartHour: j['dayStartHour'] ?? 7,
        dayStartMinute: j['dayStartMinute'] ?? 0,
        dayEndHour: j['dayEndHour'] ?? 23,
        dayEndMinute: j['dayEndMinute'] ?? 0,
        intervalHours: j['intervalHours'] ?? 2,
        repeatMinutes: j['repeatMinutes'] ?? 5,
        checkinsEnabled: j['checkinsEnabled'] ?? true,
        appLockEnabled: j['appLockEnabled'] ?? false,
        activeDays: (j['activeDays'] as List<dynamic>? ?? [1, 2, 3, 4, 5, 6, 7])
            .map((e) => e as int)
            .toList(),
      );
}

// Use a context-free 12-hour formatter for labels and notification content.
String timeText(int hour, int minute) {
  final period = hour >= 12 ? 'PM' : 'AM';
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h:${minute.toString().padLeft(2, '0')} $period';
}

String durationText(Duration duration) {
  final h = duration.inHours;
  final m = duration.inMinutes.remainder(60);
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

class DayPilotApp extends StatefulWidget {
  const DayPilotApp({super.key});
  @override
  State<DayPilotApp> createState() => _DayPilotAppState();
}

class _DayPilotAppState extends State<DayPilotApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  bool _ready = false, _locked = false;
  late SharedPreferences _prefs;
  List<TaskItem> _tasks = [];
  List<NoteItem> _notes = [];
  List<CheckinItem> _checkins = [];
  AppSettings _settings = AppSettings();
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    notificationPayload.addListener(_onNotificationTap);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    notificationPayload.removeListener(_onNotificationTap);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        _settings.appLockEnabled &&
        _ready &&
        !_locked) {
      setState(() => _locked = true);
    }
    if (state == AppLifecycleState.resumed && _ready) {
      _refreshOverdueReminders();
    }
  }

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    _tasks = _decodeList<TaskItem>(
        _prefs.getString('tasks') ?? '[]', TaskItem.fromJson);
    _notes = _decodeList<NoteItem>(
        _prefs.getString('notes') ?? '[]', NoteItem.fromJson);
    _checkins = _decodeList<CheckinItem>(
        _prefs.getString('checkins') ?? '[]', CheckinItem.fromJson);
    final settingsRaw = _prefs.getString('settings');
    if (settingsRaw != null) {
      try {
        _settings = AppSettings.fromJson(jsonDecode(settingsRaw));
      } catch (_) {}
    }
    _settings.appLockEnabled =
        _prefs.getBool(_lockEnabledKey) ?? _settings.appLockEnabled;
    final pin = await _secureStorage.read(key: _pinKey);
    _locked = _settings.appLockEnabled && pin != null;
    await _saveSettings();
    for (final task in _tasks.where((t) => !t.completed)) {
      await ReminderService.scheduleTask(task, _settings);
    }
    await _scheduleNextCheckin(initial: true);
    if (mounted) {
      setState(() => _ready = true);
      _onNotificationTap();
    }
  }

  List<T> _decodeList<T>(String raw, T Function(Map<String, dynamic>) factory) {
    try {
      final value = jsonDecode(raw) as List<dynamic>;
      return value
          .map((e) => factory(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return <T>[];
    }
  }

  Future<void> _saveTasks() async {
    await _prefs.setString(
        'tasks', jsonEncode(_tasks.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveNotes() async {
    await _prefs.setString(
        'notes', jsonEncode(_notes.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveCheckins() async {
    await _prefs.setString(
        'checkins', jsonEncode(_checkins.map((e) => e.toJson()).toList()));
  }

  Future<void> _saveSettings() async {
    await _prefs.setString('settings', jsonEncode(_settings.toJson()));
    await _prefs.setBool(_lockEnabledKey, _settings.appLockEnabled);
  }

  DateTime? _nextCheckinTime({required bool initial}) {
    if (!_settings.checkinsEnabled || _settings.activeDays.isEmpty) return null;
    final now = DateTime.now();
    for (var offset = 0; offset < 9; offset++) {
      final day =
          DateTime(now.year, now.month, now.day).add(Duration(days: offset));
      if (!_settings.activeDays.contains(day.weekday)) continue;
      final start = DateTime(day.year, day.month, day.day,
          _settings.dayStartHour, _settings.dayStartMinute);
      final end = DateTime(day.year, day.month, day.day, _settings.dayEndHour,
          _settings.dayEndMinute);
      DateTime candidate;
      if (offset > 0 || now.isAfter(end)) {
        candidate = start;
      } else if (now.isBefore(start)) {
        candidate = start;
      } else {
        candidate = now.add(Duration(hours: _settings.intervalHours));
      }
      if (candidate.isAfter(end)) continue;
      if (candidate.isAfter(now)) return candidate;
    }
    return null;
  }

  Future<void> _scheduleNextCheckin({bool initial = false}) async {
    await ReminderService.cancelCheckinChain();
    final at = _nextCheckinTime(initial: initial);
    if (at != null) await ReminderService.scheduleCheckin(at, _settings);
  }

  Future<void> _refreshOverdueReminders() async {
    for (final task in _tasks
        .where((t) => !t.completed && t.endAt.isBefore(DateTime.now()))) {
      await ReminderService.scheduleTask(task, _settings);
    }
  }

  void _onNotificationTap() {
    final payload = notificationPayload.value;
    if (payload == null || !mounted) return;
    setState(() {
      if (payload.startsWith('task:')) _tab = 1;
      if (payload.startsWith('checkin')) _tab = 2;
      if (_settings.appLockEnabled) _locked = true;
    });
    // Clear after handling so a later tap of the same notification payload is handled too.
    notificationPayload.value = null;
  }

  Future<void> _showMsg(String msg) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _addTask() async {
    final item = await showDialog<TaskItem>(
        context: _navigatorKey.currentContext!,
        builder: (_) => const TaskEditorDialog());
    if (item == null) return;
    setState(() => _tasks.add(item));
    await _saveTasks();
    await ReminderService.scheduleTask(item, _settings);
    await _showMsg('Task saved and reminders scheduled.');
  }

  Future<void> _editTask(TaskItem task) async {
    final edited = await showDialog<TaskItem>(
        context: _navigatorKey.currentContext!,
        builder: (_) => TaskEditorDialog(existing: task));
    if (edited == null) return;
    final idx = _tasks.indexWhere((t) => t.id == task.id);
    if (idx >= 0) _tasks[idx] = edited;
    setState(() {});
    await _saveTasks();
    await ReminderService.scheduleTask(edited, _settings);
    await _showMsg('Task updated.');
  }

  Future<void> _startTask(TaskItem task) async {
    task.actualStart ??= DateTime.now();
    task.segmentStart ??= DateTime.now();
    task.status = 'In progress';
    setState(() {});
    await _saveTasks();
    await _showMsg('Timer started for ${task.title}.');
  }

  Future<void> _updateTask(TaskItem task) async {
    final result = await showDialog<TaskUpdateResult>(
        context: _navigatorKey.currentContext!,
        builder: (_) => TaskUpdateDialog(task: task));
    if (result == null) return;
    task.progress = result.progress;
    task.notes = result.notes.trim().isEmpty ? task.notes : result.notes.trim();
    task.status = result.status;
    if (task.status == 'In progress') {
      task.actualStart ??= DateTime.now();
      task.segmentStart ??= DateTime.now();
    } else {
      task.pauseTracking();
    }
    if (task.status == 'Completed') {
      task.progress = 100;
      task.actualEnd = DateTime.now();
      await ReminderService.cancelTask(task.id);
    } else {
      await ReminderService.scheduleTask(task, _settings);
    }
    setState(() {});
    await _saveTasks();
    await _showMsg(task.completed
        ? 'Great work! Task completed.'
        : 'Progress saved. Task remains on your list.');
  }

  Future<void> _completeTask(TaskItem task) async {
    task.status = 'Completed';
    task.progress = 100;
    task.actualStart ??= DateTime.now();
    task.pauseTracking();
    task.actualEnd = DateTime.now();
    setState(() {});
    await _saveTasks();
    await ReminderService.cancelTask(task.id);
    await _showMsg('Marked as completed.');
  }

  Future<void> _rescheduleTask(TaskItem task) async {
    final result = await showDialog<RescheduleResult>(
        context: _navigatorKey.currentContext!,
        builder: (_) => RescheduleDialog(task: task));
    if (result == null) return;
    task.history.add(
        '${task.scheduleLabel} → ${DateFormat('EEE, d MMM').format(result.date)} · ${timeText(result.start.hour, result.start.minute)}–${timeText(result.end.hour, result.end.minute)}');
    task.pauseTracking();
    task.date = result.date;
    task.startHour = result.start.hour;
    task.startMinute = result.start.minute;
    task.endHour = result.end.hour;
    task.endMinute = result.end.minute;
    task.status = 'Pending';
    setState(() {});
    await _saveTasks();
    await ReminderService.scheduleTask(task, _settings);
    await _showMsg('Task rescheduled. Previous schedule stays in its history.');
  }

  Future<void> _deleteTask(TaskItem task) async {
    final yes = await _confirm('Delete task?',
        '“${task.title}” and its local history will be removed from this device.');
    if (!yes) return;
    setState(() => _tasks.removeWhere((t) => t.id == task.id));
    await _saveTasks();
    await ReminderService.cancelTask(task.id);
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: _navigatorKey.currentContext!,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Confirm'))
          ],
        ),
      ) ??
      false;

  Future<void> _addCheckin() async {
    final result = await showDialog<CheckinResult>(
        context: _navigatorKey.currentContext!,
        builder: (_) => const CheckinDialog());
    if (result == null) return;
    final now = DateTime.now();
    _checkins.insert(
        0,
        CheckinItem(
          activity: result.activity,
          status: result.status,
          startedAt: now,
          endedAt: result.status == 'Completed' ? now : null,
          notes: result.notes,
        ));
    await _saveCheckins();
    await _scheduleNextCheckin();
    setState(() => _tab = 2);
    await _showMsg('Daily update saved. Next check-in scheduled.');
  }

  Future<void> _addNote({NoteItem? existing}) async {
    final note = await showDialog<NoteItem>(
        context: _navigatorKey.currentContext!,
        builder: (_) => NoteEditorDialog(existing: existing));
    if (note == null) return;
    final index = _notes.indexWhere((n) => n.id == note.id);
    setState(() {
      if (index >= 0)
        _notes[index] = note;
      else
        _notes.insert(0, note);
    });
    await _saveNotes();
  }

  Future<void> _deleteNote(NoteItem note) async {
    if (!await _confirm(
        'Delete note?', 'This note will be removed from this device.')) return;
    setState(() => _notes.removeWhere((n) => n.id == note.id));
    await _saveNotes();
  }

  Future<void> _openSettings() async {
    debugPrint('DAYPILOT_SETTINGS_BUTTON_PRESSED');

    if (!mounted) return;

    final result = await showDialog<AppSettings>(
      context: _navigatorKey.currentContext!,
      builder: (_) => SettingsDialog(initial: _settings),
    );

    debugPrint('DAYPILOT_SETTINGS_DIALOG_RESULT: $result');

    if (result == null) return;

    _settings = result;
    await _saveSettings();
    await _scheduleNextCheckin(initial: true);

    for (final task in _tasks.where((t) => !t.completed)) {
      await ReminderService.scheduleTask(task, _settings);
    }

    if (!mounted) return;
    setState(() {});
    await _showMsg('Schedule settings saved.');
  }

  Future<void> _setupAppLock() async {
    final existingPin = await _secureStorage.read(key: _pinKey);
    if (_settings.appLockEnabled && existingPin != null) {
      final disable = await showDialog<bool>(
          context: _navigatorKey.currentContext!,
          builder: (ctx) => AlertDialog(
                title: const Text('App lock enabled'),
                content: const Text('Disable the PIN/biometric app lock?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Keep lock')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Disable'))
                ],
              ));
      if (disable == true) {
        await _secureStorage.delete(key: _pinKey);
        _settings.appLockEnabled = false;
        await _saveSettings();
        setState(() => _locked = false);
        await _showMsg('App lock disabled.');
      }
      return;
    }
    final pin = await showDialog<String>(
        context: _navigatorKey.currentContext!,
        builder: (_) => const PinSetupDialog());
    if (pin == null) return;
    await _secureStorage.write(key: _pinKey, value: pin);
    _settings.appLockEnabled = true;
    await _saveSettings();
    setState(() {});
    await _showMsg(
        'App lock enabled. It will lock when DayPilot goes to the background.');
  }

  int get _pending => _tasks.where((t) => !t.completed).length;
  int get _completed => _tasks.where((t) => t.completed).length;
  int get _overdue => _tasks.where((t) => t.overdue).length;
  Duration get _tracked =>
      _tasks.fold(Duration.zero, (sum, t) => sum + t.actualDuration);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'DayPilot',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _green),
        scaffoldBackgroundColor: const Color(0xFFF5F8F5),
        appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFF5F8F5), foregroundColor: _greenDark),
        cardTheme: CardThemeData(
            elevation: 0,
            color: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20))),
        inputDecorationTheme: InputDecorationTheme(
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(14))),
      ),
      home: !_ready
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : Stack(children: [
              _mainScaffold(),
              if (_locked)
                LockGate(onUnlocked: () => setState(() => _locked = false)),
            ]),
    );
  }

  Widget _mainScaffold() {
    const tabs = [
      NavigationDestination(
          icon: Icon(Icons.dashboard_outlined),
          selectedIcon: Icon(Icons.dashboard),
          label: 'Home'),
      NavigationDestination(
          icon: Icon(Icons.calendar_month_outlined),
          selectedIcon: Icon(Icons.calendar_month),
          label: 'Tasks'),
      NavigationDestination(
          icon: Icon(Icons.checklist_outlined),
          selectedIcon: Icon(Icons.checklist),
          label: 'Check-in'),
      NavigationDestination(
          icon: Icon(Icons.sticky_note_2_outlined),
          selectedIcon: Icon(Icons.sticky_note_2),
          label: 'Notes'),
      NavigationDestination(
          icon: Icon(Icons.insights_outlined),
          selectedIcon: Icon(Icons.insights),
          label: 'Reports'),
    ];
    final titles = [
      'DayPilot',
      'My Schedule',
      'Daily Updates',
      'Notes',
      'Reports'
    ];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(titles[_tab],
              style: const TextStyle(fontWeight: FontWeight.w800)),
          if (_tab == 0)
            Text(DateFormat('EEEE, d MMMM').format(DateTime.now()),
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Colors.black54)),
        ]),
        actions: [
          IconButton(
              tooltip: 'Schedule settings',
              onPressed: _openSettings,
              icon: const Icon(Icons.tune_rounded)),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(index: _tab, children: [
        _dashboard(),
        _tasksPage(),
        _checkinsPage(),
        _notesPage(),
        _reportsPage(),
      ]),
      floatingActionButton: _tab == 1
          ? FloatingActionButton.extended(
              onPressed: _addTask,
              icon: const Icon(Icons.add),
              label: const Text('Add task'))
          : _tab == 3
              ? FloatingActionButton.extended(
                  onPressed: () => _addNote(),
                  icon: const Icon(Icons.note_add_outlined),
                  label: const Text('New note'))
              : _tab == 2
                  ? FloatingActionButton.extended(
                      onPressed: _addCheckin,
                      icon: const Icon(Icons.edit_note),
                      label: const Text('Update now'))
                  : null,
      bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (v) => setState(() => _tab = v),
          destinations: tabs),
    );
  }

  Widget _dashboard() {
    final upcoming = _tasks.where((t) => !t.completed).toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    return RefreshIndicator(
      onRefresh: () async {
        await _refreshOverdueReminders();
        setState(() {});
      },
      child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
          children: [
            Container(
              decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [_greenDark, _green]),
                  borderRadius: BorderRadius.circular(24)),
              padding: const EdgeInsets.all(20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(children: [
                      Icon(Icons.waving_hand, color: Color(0xFFB8E5C5)),
                      SizedBox(width: 8),
                      Text('Make today count',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w800))
                    ]),
                    const SizedBox(height: 8),
                    Text(
                        'You have $_pending pending tasks. Take one step at a time.',
                        style: const TextStyle(color: Color(0xFFE0F0E4))),
                    const SizedBox(height: 18),
                    Row(children: [
                      Expanded(
                          child: FilledButton.icon(
                              onPressed: _addTask,
                              icon: const Icon(Icons.add),
                              label: const Text('Add task'),
                              style: FilledButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: _greenDark))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: OutlinedButton.icon(
                              onPressed: _addCheckin,
                              icon: const Icon(Icons.edit_note),
                              label: const Text('Check-in'),
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: const BorderSide(
                                      color: Colors.white70)))),
                    ]),
                  ]),
            ),
            const SizedBox(height: 16),
            GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.42,
                children: [
                  _metricCard(
                      'Tasks planned',
                      '${_tasks.length}',
                      Icons.calendar_today_rounded,
                      const Color(0xFFE5F0FF),
                      const Color(0xFF315E9D)),
                  _metricCard('Time tracked', durationText(_tracked),
                      Icons.timer_outlined, const Color(0xFFE2F4E8), _green),
                  _metricCard(
                      'Completed',
                      '$_completed',
                      Icons.task_alt_rounded,
                      const Color(0xFFE5F3F0),
                      const Color(0xFF277B68)),
                  _metricCard(
                      'Overdue',
                      '$_overdue',
                      Icons.notifications_active_outlined,
                      const Color(0xFFFFE9DF),
                      const Color(0xFFA64D2A)),
                ]),
            const SizedBox(height: 24),
            _sectionHeader('Upcoming & pending',
                trailing: TextButton(
                    onPressed: () => setState(() => _tab = 1),
                    child: const Text('View all'))),
            if (upcoming.isEmpty)
              _emptyCard(Icons.celebration_outlined, 'Nothing pending',
                  'Add your next task and DayPilot will remind you.')
            else
              ...upcoming.take(4).map(_taskCard),
            const SizedBox(height: 12),
            _sectionHeader('Daily accountability'),
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(children: [
                      Container(
                          padding: const EdgeInsets.all(12),
                          decoration: const BoxDecoration(
                              color: _softGreen, shape: BoxShape.circle),
                          child: const Icon(Icons.notifications_active_outlined,
                              color: _green)),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            const Text('Your check-in routine',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text(
                                '${timeText(_settings.dayStartHour, _settings.dayStartMinute)} – ${timeText(_settings.dayEndHour, _settings.dayEndMinute)} · Every ${_settings.intervalHours}h · Repeat ${_settings.repeatMinutes}m',
                                style: Theme.of(context).textTheme.bodySmall),
                          ])),
                      IconButton(
                          onPressed: _openSettings,
                          icon: const Icon(Icons.settings_outlined)),
                    ]))),
            const SizedBox(height: 12),
            Card(
                child: ListTile(
                    leading: const Icon(Icons.lock_outline, color: _green),
                    title: Text(_settings.appLockEnabled
                        ? 'App lock is enabled'
                        : 'Protect DayPilot with a lock'),
                    subtitle: Text(_settings.appLockEnabled
                        ? 'PIN is configured'
                        : 'Set up a PIN and optional fingerprint'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _setupAppLock)),
          ]),
    );
  }

  Widget _metricCard(String label, String value, IconData icon, Color tint,
          Color accent) =>
      Card(
        child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: tint, borderRadius: BorderRadius.circular(12)),
                      child: Icon(icon, color: accent, size: 20)),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(value,
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: _greenDark)),
                        Text(label,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54))
                      ]),
                ])),
      );

  Widget _tasksPage() {
    final tasks = [..._tasks]..sort((a, b) {
        if (a.completed != b.completed) return a.completed ? 1 : -1;
        return a.startAt.compareTo(b.startAt);
      });
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
        children: [
          Row(children: [
            Expanded(
                child: Text('${_tasks.length} tasks in your list',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700))),
            IconButton(
                onPressed: _addTask,
                icon: const Icon(Icons.add_circle_outline, color: _green))
          ]),
          if (tasks.isEmpty)
            _emptyCard(Icons.calendar_month_outlined, 'No tasks yet',
                'Tap Add task to plan your first activity.'),
          ...tasks.map(_taskCard),
        ]);
  }

  Widget _taskCard(TaskItem task) {
    final color = task.completed
        ? _green
        : task.overdue
            ? const Color(0xFFB74E34)
            : task.status == 'In progress'
                ? const Color(0xFF356FB0)
                : const Color(0xFF8D6B2E);
    final label = task.completed
        ? 'Completed'
        : task.overdue
            ? 'Overdue'
            : task.status;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                  width: 4,
                  height: 62,
                  decoration: BoxDecoration(
                      color: color, borderRadius: BorderRadius.circular(4))),
              const SizedBox(width: 12),
              Expanded(
                  child: InkWell(
                      onTap: () => _editTask(task),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(task.title,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: _greenDark)),
                            const SizedBox(height: 5),
                            Text(task.scheduleLabel,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: Colors.black54)),
                            const SizedBox(height: 5),
                            Wrap(spacing: 6, runSpacing: 5, children: [
                              _tag(label, color),
                              _tag(task.category, _green),
                              _tag(
                                  '${task.priority} priority', Colors.blueGrey),
                            ]),
                          ]))),
              PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') _editTask(task);
                    if (value == 'reschedule') _rescheduleTask(task);
                    if (value == 'delete') _deleteTask(task);
                    if (value == 'notes') _editTask(task);
                    if (value == 'history') _showHistory(task);
                  },
                  itemBuilder: (_) => const [
                        PopupMenuItem(
                            value: 'edit', child: Text('Edit task / notes')),
                        PopupMenuItem(
                            value: 'reschedule', child: Text('Reschedule')),
                        PopupMenuItem(
                            value: 'history', child: Text('Schedule history')),
                        PopupMenuItem(
                            value: 'delete', child: Text('Delete task')),
                      ]),
            ]),
            if (task.notes.trim().isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(task.notes,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Colors.black54))),
            if (!task.completed || task.progress > 0) ...[
              const SizedBox(height: 12),
              Row(children: [
                Text('Progress', style: Theme.of(context).textTheme.labelSmall),
                const Spacer(),
                Text('${task.progress}%',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(fontWeight: FontWeight.bold))
              ]),
              const SizedBox(height: 5),
              ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: LinearProgressIndicator(
                      value: task.progress / 100,
                      minHeight: 6,
                      backgroundColor: const Color(0xFFE7ECE8),
                      color: color)),
            ],
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              if (!task.completed && task.status != 'In progress')
                OutlinedButton.icon(
                    onPressed: () => _startTask(task),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Start')),
              if (!task.completed)
                OutlinedButton.icon(
                    onPressed: () => _updateTask(task),
                    icon: const Icon(Icons.trending_up, size: 18),
                    label: const Text('Progress')),
              if (!task.completed)
                FilledButton.tonalIcon(
                    onPressed: () => _completeTask(task),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Complete')),
              if (!task.completed && task.overdue)
                TextButton.icon(
                    onPressed: () => _rescheduleTask(task),
                    icon: const Icon(Icons.event_repeat, size: 18),
                    label: const Text('Next day')),
            ]),
          ])),
    );
  }

  Widget _tag(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: color.withOpacity(.10),
          borderRadius: BorderRadius.circular(99)),
      child: Text(text,
          style: TextStyle(
              fontSize: 10, color: color, fontWeight: FontWeight.w700)));

  Future<void> _showHistory(TaskItem task) async {
    await showDialog<void>(
        context: _navigatorKey.currentContext!,
        builder: (ctx) => AlertDialog(
              title: const Text('Task schedule history'),
              content: SizedBox(
                  width: 360,
                  child: task.history.isEmpty
                      ? const Text('No reschedules recorded yet.')
                      : ListView(
                          shrinkWrap: true,
                          children: task.history
                              .map((e) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Text('• $e')))
                              .toList())),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'))
              ],
            ));
  }

  Widget _checkinsPage() {
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
        children: [
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.schedule, color: _green),
                          const SizedBox(width: 8),
                          const Expanded(
                              child: Text('Your check-in routine',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16))),
                          Switch(
                              value: _settings.checkinsEnabled,
                              onChanged: (v) async {
                                _settings.checkinsEnabled = v;
                                await _saveSettings();
                                await _scheduleNextCheckin(initial: true);
                                setState(() {});
                              })
                        ]),
                        Text(
                            '${timeText(_settings.dayStartHour, _settings.dayStartMinute)}–${timeText(_settings.dayEndHour, _settings.dayEndMinute)} · Every ${_settings.intervalHours} hour(s)',
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 4),
                        Text(
                            'Pending check-in repeats every ${_settings.repeatMinutes} minutes.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Colors.black54)),
                        const SizedBox(height: 12),
                        SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                                onPressed: _addCheckin,
                                icon: const Icon(Icons.edit_note),
                                label: const Text('Submit activity update'))),
                      ]))),
          const SizedBox(height: 12),
          Text('Recent activity',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (_checkins.isEmpty)
            _emptyCard(Icons.fact_check_outlined, 'No updates recorded',
                'Use Submit activity update to log what you are doing.'),
          ..._checkins.map((entry) => Card(
                  child: ListTile(
                leading: CircleAvatar(
                    backgroundColor: _softGreen,
                    child: Icon(
                        entry.status == 'Completed'
                            ? Icons.check
                            : Icons.timelapse,
                        color: _green)),
                title: Text(entry.activity,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                    '${DateFormat('EEE, d MMM · h:mm a').format(entry.startedAt)} · ${entry.status}${entry.notes.isEmpty ? '' : '\n${entry.notes}'}'),
                isThreeLine: entry.notes.isNotEmpty,
              ))),
        ]);
  }

  Widget _notesPage() {
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
        children: [
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Container(
                        padding: const EdgeInsets.all(12),
                        decoration: const BoxDecoration(
                            color: _softGreen, shape: BoxShape.circle),
                        child: const Icon(Icons.sticky_note_2_outlined,
                            color: _green)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          const Text('Your notes',
                              style: TextStyle(
                                  fontWeight: FontWeight.w800, fontSize: 17)),
                          const SizedBox(height: 3),
                          Text(
                              'Keep ideas, blockers and reminders in one place.',
                              style: Theme.of(context).textTheme.bodySmall)
                        ])),
                    IconButton(
                        onPressed: () => _addNote(),
                        icon: const Icon(Icons.add_circle, color: _green)),
                  ]))),
          const SizedBox(height: 8),
          if (_notes.isEmpty)
            _emptyCard(Icons.note_alt_outlined, 'No notes yet',
                'Create a quick note or keep details next to a task.'),
          ..._notes.map((note) => Card(
              child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _addNote(existing: note),
                  child: Padding(
                      padding: const EdgeInsets.all(15),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                  child: Text(
                                      note.title.isEmpty
                                          ? 'Untitled note'
                                          : note.title,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 16))),
                              PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'edit') _addNote(existing: note);
                                    if (v == 'delete') _deleteNote(note);
                                  },
                                  itemBuilder: (_) => const [
                                        PopupMenuItem(
                                            value: 'edit', child: Text('Edit')),
                                        PopupMenuItem(
                                            value: 'delete',
                                            child: Text('Delete'))
                                      ])
                            ]),
                            Text(note.body,
                                maxLines: 5, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 8),
                            Text(
                                'Updated ${DateFormat('d MMM, h:mm a').format(note.updatedAt)}',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(color: Colors.black54)),
                          ]))))),
        ]);
  }

  Widget _reportsPage() {
    final total = _tasks.length;
    final completion = total == 0 ? 0.0 : _completed / total;
    final plannedMinutes = _tasks.fold<int>(0, (sum, t) {
      final minutes = t.endAt.difference(t.startAt).inMinutes;
      return sum + (minutes < 0 ? 0 : (minutes > 24 * 60 ? 24 * 60 : minutes));
    });
    final categories = <String, Duration>{};
    for (final task in _tasks) {
      categories[task.category] =
          (categories[task.category] ?? Duration.zero) + task.actualDuration;
    }
    final sorted = categories.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxMinutes =
        sorted.isEmpty ? 1 : sorted.first.value.inMinutes.clamp(1, 999999);
    final overdueTasks = _tasks.where((t) => t.overdue).toList();
    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
        children: [
          Container(
              decoration: BoxDecoration(
                  color: _greenDark, borderRadius: BorderRadius.circular(22)),
              padding: const EdgeInsets.all(20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Your productivity snapshot',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 5),
                    const Text(
                        'Your information stays stored on this device in this first version.',
                        style: TextStyle(color: Color(0xFFD8E7DC))),
                    const SizedBox(height: 20),
                    Row(children: [
                      Expanded(
                          child: _reportMetric(
                              'Tracked time', durationText(_tracked))),
                      Expanded(
                          child: _reportMetric('Planned time',
                              durationText(Duration(minutes: plannedMinutes)))),
                      Expanded(
                          child: _reportMetric(
                              'Completion', '${(completion * 100).round()}%')),
                    ]),
                  ])),
          const SizedBox(height: 18),
          Text('Task status',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _smallStat('Completed', '$_completed', _green)),
            Expanded(
                child: _smallStat(
                    'Pending', '$_pending', const Color(0xFF8D6B2E))),
            Expanded(
                child:
                    _smallStat('Overdue', '$_overdue', const Color(0xFFB74E34)))
          ]),
          const SizedBox(height: 20),
          Text('Time by category',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          if (sorted.isEmpty)
            _emptyCard(Icons.bar_chart, 'No tracked time yet',
                'Start a task and mark its progress to build your report.'),
          ...sorted.map((entry) => Padding(
              padding: const EdgeInsets.only(bottom: 13),
              child: Column(children: [
                Row(children: [
                  Expanded(
                      child: Text(entry.key,
                          style: const TextStyle(fontWeight: FontWeight.w600))),
                  Text(durationText(entry.value),
                      style: const TextStyle(color: Colors.black54))
                ]),
                const SizedBox(height: 6),
                ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                        value: entry.value.inMinutes / maxMinutes,
                        minHeight: 8,
                        backgroundColor: const Color(0xFFE6ECE7),
                        color: _green)),
              ]))),
          const SizedBox(height: 12),
          Text('Missed / overdue tasks',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (overdueTasks.isEmpty)
            _emptyCard(Icons.check_circle_outline, 'No overdue tasks',
                'Nice work. Tasks that pass their planned end time will show here.'),
          ...overdueTasks.map((task) => Card(
                  child: ListTile(
                leading: const Icon(Icons.warning_amber_rounded,
                    color: Color(0xFFB74E34)),
                title: Text(task.title),
                subtitle: Text(
                    'Planned ${task.scheduleLabel} · ${task.progress}% progress'),
                trailing: IconButton(
                    tooltip: 'Reschedule',
                    onPressed: () => _rescheduleTask(task),
                    icon: const Icon(Icons.event_repeat)),
              ))),
          const SizedBox(height: 10),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.history, color: _green),
                  title: const Text('Reschedule history'),
                  subtitle: Text(
                      '${_tasks.fold<int>(0, (sum, t) => sum + t.history.length)} reschedule event(s) recorded'),
                  onTap: () => setState(() => _tab = 1))),
        ]);
  }

  Widget _reportMetric(String label, String value) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(label,
            style: const TextStyle(color: Color(0xFFD8E7DC), fontSize: 11))
      ]);
  Widget _smallStat(String label, String value, Color color) => Card(
      child: Padding(
          padding: const EdgeInsets.all(13),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value,
                style: TextStyle(
                    color: color, fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.black54))
          ])));
  Widget _sectionHeader(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Expanded(
            child: Text(text,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800))),
        if (trailing != null) trailing
      ]));
  Widget _emptyCard(IconData icon, String title, String text) => Card(
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(children: [
            Icon(icon, size: 32, color: _green),
            const SizedBox(height: 10),
            Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(height: 4),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54))
          ])));
}

class TaskEditorDialog extends StatefulWidget {
  const TaskEditorDialog({super.key, this.existing});
  final TaskItem? existing;
  @override
  State<TaskEditorDialog> createState() => _TaskEditorDialogState();
}

class _TaskEditorDialogState extends State<TaskEditorDialog> {
  late final TextEditingController titleController;
  late final TextEditingController notesController;
  late DateTime date;
  late TimeOfDay start, end;
  late String category, priority;
  late int advance;
  final categories = const [
    'Study',
    'Cybersecurity',
    'College',
    'Project',
    'Personal',
    'Fitness',
    'Other'
  ];
  final priorities = const ['High', 'Medium', 'Low'];
  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    titleController = TextEditingController(text: e?.title ?? '');
    notesController = TextEditingController(text: e?.notes ?? '');
    date = e?.date ?? DateTime.now();
    start = e == null
        ? const TimeOfDay(hour: 10, minute: 0)
        : TimeOfDay(hour: e.startHour, minute: e.startMinute);
    end = e == null
        ? const TimeOfDay(hour: 11, minute: 0)
        : TimeOfDay(hour: e.endHour, minute: e.endMinute);
    category = e?.category ?? 'Study';
    priority = e?.priority ?? 'Medium';
    advance = e?.advanceMinutes ?? 10;
  }

  @override
  void dispose() {
    titleController.dispose();
    notesController.dispose();
    super.dispose();
  }

  Future<void> pickDate() async {
    final picked = await showDatePicker(
        context: context,
        initialDate: date,
        firstDate: DateTime(2020),
        lastDate: DateTime(2100));
    if (picked != null) setState(() => date = picked);
  }

  Future<TimeOfDay?> pickTime(TimeOfDay current) =>
      showTimePicker(context: context, initialTime: current);
  void save() {
    final title = titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a task name.')));
      return;
    }
    final startAt =
        DateTime(date.year, date.month, date.day, start.hour, start.minute);
    final endAt =
        DateTime(date.year, date.month, date.day, end.hour, end.minute);
    if (!endAt.isAfter(startAt)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('End time must be after the start time.')));
      return;
    }
    final e = widget.existing;
    Navigator.pop(
        context,
        TaskItem(
          id: e?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
          title: title,
          date: date,
          startHour: start.hour,
          startMinute: start.minute,
          endHour: end.hour,
          endMinute: end.minute,
          category: category,
          priority: priority,
          notes: notesController.text.trim(),
          status: e?.status ?? 'Pending',
          progress: e?.progress ?? 0,
          advanceMinutes: advance,
          actualStart: e?.actualStart,
          actualEnd: e?.actualEnd,
          segmentStart: e?.segmentStart,
          trackedSeconds: e?.trackedSeconds ?? 0,
          history: e?.history.toList() ?? [],
        ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? 'Add a task' : 'Edit task'),
        content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: titleController,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'Task name',
                      prefixIcon: Icon(Icons.task_alt))),
              const SizedBox(height: 12),
              TextField(
                  controller: notesController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                      labelText: 'Task notes (optional)',
                      prefixIcon: Icon(Icons.notes))),
              const SizedBox(height: 12),
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_month),
                  title: const Text('Date'),
                  subtitle: Text(DateFormat('EEEE, d MMMM yyyy').format(date)),
                  trailing: const Icon(Icons.edit_calendar),
                  onTap: pickDate),
              Row(children: [
                Expanded(
                    child: OutlinedButton.icon(
                        onPressed: () async {
                          final p = await pickTime(start);
                          if (p != null) setState(() => start = p);
                        },
                        icon: const Icon(Icons.play_arrow),
                        label: Text(
                            'Start\n${timeText(start.hour, start.minute)}'))),
                const SizedBox(width: 8),
                Expanded(
                    child: OutlinedButton.icon(
                        onPressed: () async {
                          final p = await pickTime(end);
                          if (p != null) setState(() => end = p);
                        },
                        icon: const Icon(Icons.stop),
                        label: Text('End\n${timeText(end.hour, end.minute)}')))
              ]),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                  value: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: categories
                      .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => category = v);
                  }),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: DropdownButtonFormField<String>(
                        value: priority,
                        decoration:
                            const InputDecoration(labelText: 'Priority'),
                        items: priorities
                            .map((p) =>
                                DropdownMenuItem(value: p, child: Text(p)))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => priority = v);
                        })),
                const SizedBox(width: 8),
                Expanded(
                    child: DropdownButtonFormField<int>(
                        value: advance,
                        decoration:
                            const InputDecoration(labelText: 'Reminder before'),
                        items: const [5, 10, 15, 30]
                            .map((m) => DropdownMenuItem(
                                value: m, child: Text('$m minutes')))
                            .toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => advance = v);
                        }))
              ]),
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: save, child: const Text('Save task'))
        ],
      );
}

class TaskUpdateResult {
  TaskUpdateResult(this.progress, this.status, this.notes);
  int progress;
  String status, notes;
}

class TaskUpdateDialog extends StatefulWidget {
  const TaskUpdateDialog({super.key, required this.task});
  final TaskItem task;
  @override
  State<TaskUpdateDialog> createState() => _TaskUpdateDialogState();
}

class _TaskUpdateDialogState extends State<TaskUpdateDialog> {
  late double progress;
  late String status;
  late TextEditingController notes;
  @override
  void initState() {
    super.initState();
    progress = widget.task.progress.toDouble();
    status =
        widget.task.status == 'Pending' ? 'In progress' : widget.task.status;
    notes = TextEditingController(text: widget.task.notes);
  }

  @override
  void dispose() {
    notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Update task progress'),
        content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(widget.task.title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 14),
                  Row(children: [
                    const Expanded(child: Text('Completion')),
                    Text('${progress.round()}%',
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, color: _green))
                  ]),
                  Slider(
                      value: progress,
                      max: 100,
                      divisions: 10,
                      label: '${progress.round()}%',
                      onChanged: (v) => setState(() => progress = v)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                      value: status,
                      decoration:
                          const InputDecoration(labelText: 'Current status'),
                      items: const [
                        'In progress',
                        'Paused',
                        'Not completed',
                        'Completed'
                      ]
                          .map(
                              (s) => DropdownMenuItem(value: s, child: Text(s)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => status = v);
                      }),
                  const SizedBox(height: 12),
                  TextField(
                      controller: notes,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                          labelText: 'Progress notes / blocker (optional)')),
                ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context,
                  TaskUpdateResult(progress.round(), status, notes.text)),
              child: const Text('Save update'))
        ],
      );
}

class RescheduleResult {
  RescheduleResult(this.date, this.start, this.end);
  DateTime date;
  TimeOfDay start, end;
}

class RescheduleDialog extends StatefulWidget {
  const RescheduleDialog({super.key, required this.task});
  final TaskItem task;
  @override
  State<RescheduleDialog> createState() => _RescheduleDialogState();
}

class _RescheduleDialogState extends State<RescheduleDialog> {
  late DateTime date;
  late TimeOfDay start, end;
  @override
  void initState() {
    super.initState();
    date = DateTime.now().add(const Duration(days: 1));
    start =
        TimeOfDay(hour: widget.task.startHour, minute: widget.task.startMinute);
    end = TimeOfDay(hour: widget.task.endHour, minute: widget.task.endMinute);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Reschedule incomplete task'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.task.title,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('The old schedule will stay in the task history.',
              style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calendar_today),
              title: const Text('New date'),
              subtitle: Text(DateFormat('EEEE, d MMMM').format(date)),
              onTap: () async {
                final d = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime.now(),
                    lastDate: DateTime(2100));
                if (d != null) setState(() => date = d);
              }),
          Row(children: [
            Expanded(
                child: OutlinedButton(
                    onPressed: () async {
                      final t = await showTimePicker(
                          context: context, initialTime: start);
                      if (t != null) setState(() => start = t);
                    },
                    child:
                        Text('Start\n${timeText(start.hour, start.minute)}'))),
            const SizedBox(width: 8),
            Expanded(
                child: OutlinedButton(
                    onPressed: () async {
                      final t = await showTimePicker(
                          context: context, initialTime: end);
                      if (t != null) setState(() => end = t);
                    },
                    child: Text('End\n${timeText(end.hour, end.minute)}')))
          ]),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                final s = DateTime(
                    date.year, date.month, date.day, start.hour, start.minute);
                final e = DateTime(
                    date.year, date.month, date.day, end.hour, end.minute);
                if (!e.isAfter(s)) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('End must be after start.')));
                  return;
                }
                Navigator.pop(context, RescheduleResult(date, start, end));
              },
              child: const Text('Save new time'))
        ],
      );
}

class CheckinResult {
  CheckinResult(this.activity, this.status, this.notes);
  String activity, status, notes;
}

class CheckinDialog extends StatefulWidget {
  const CheckinDialog({super.key});
  @override
  State<CheckinDialog> createState() => _CheckinDialogState();
}

class _CheckinDialogState extends State<CheckinDialog> {
  final activity = TextEditingController();
  final notes = TextEditingController();
  String status = 'In progress';
  @override
  void dispose() {
    activity.dispose();
    notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Daily activity check-in'),
        content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                  'What are you doing right now? This update clears the current check-in reminder.'),
              const SizedBox(height: 12),
              TextField(
                  controller: activity,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'Current activity',
                      hintText: 'e.g. Python practice')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                  value: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: const [
                    'In progress',
                    'Completed',
                    'Paused / Break',
                    'Not started'
                  ]
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => status = v);
                  }),
              const SizedBox(height: 12),
              TextField(
                  controller: notes,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'Notes / what you accomplished')),
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (activity.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Enter your current activity.')));
                  return;
                }
                Navigator.pop(
                    context,
                    CheckinResult(
                        activity.text.trim(), status, notes.text.trim()));
              },
              child: const Text('Submit update'))
        ],
      );
}

class NoteEditorDialog extends StatefulWidget {
  const NoteEditorDialog({super.key, this.existing});
  final NoteItem? existing;
  @override
  State<NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends State<NoteEditorDialog> {
  late TextEditingController title, body;
  @override
  void initState() {
    super.initState();
    title = TextEditingController(text: widget.existing?.title ?? '');
    body = TextEditingController(text: widget.existing?.body ?? '');
  }

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null ? 'New note' : 'Edit note'),
        content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: title,
                  decoration: const InputDecoration(labelText: 'Title')),
              const SizedBox(height: 12),
              TextField(
                  controller: body,
                  autofocus: widget.existing == null,
                  minLines: 5,
                  maxLines: 10,
                  decoration:
                      const InputDecoration(labelText: 'Write your note here')),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (title.text.trim().isEmpty && body.text.trim().isEmpty)
                  return;
                Navigator.pop(
                    context,
                    NoteItem(
                        id: widget.existing?.id ??
                            DateTime.now().microsecondsSinceEpoch.toString(),
                        title: title.text.trim(),
                        body: body.text.trim(),
                        updatedAt: DateTime.now()));
              },
              child: const Text('Save note'))
        ],
      );
}

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.initial});
  final AppSettings initial;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late int sh, sm, eh, em, interval, repeat;
  late bool enabled;
  late List<int> active;
  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    sh = s.dayStartHour;
    sm = s.dayStartMinute;
    eh = s.dayEndHour;
    em = s.dayEndMinute;
    interval = s.intervalHours;
    repeat = s.repeatMinutes;
    enabled = s.checkinsEnabled;
    active = s.activeDays.toList();
  }

  Future<void> _pickStart() async {
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay(hour: sh, minute: sm));
    if (t != null)
      setState(() {
        sh = t.hour;
        sm = t.minute;
      });
  }

  Future<void> _pickEnd() async {
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay(hour: eh, minute: em));
    if (t != null)
      setState(() {
        eh = t.hour;
        em = t.minute;
      });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Daily schedule settings'),
        content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Daily check-ins'),
                      subtitle:
                          const Text('Automatically ask for activity updates'),
                      value: enabled,
                      onChanged: (v) => setState(() => enabled = v)),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                        child: OutlinedButton.icon(
                            onPressed: _pickStart,
                            icon: const Icon(Icons.wb_sunny_outlined),
                            label: Text('Start\n${timeText(sh, sm)}'))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: OutlinedButton.icon(
                            onPressed: _pickEnd,
                            icon: const Icon(Icons.nights_stay_outlined),
                            label: Text('End\n${timeText(eh, em)}')))
                  ]),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<int>(
                      value: interval,
                      decoration:
                          const InputDecoration(labelText: 'Check-in interval'),
                      items: const [1, 2, 3, 4, 6]
                          .map((i) => DropdownMenuItem(
                              value: i,
                              child: Text('Every $i hour${i == 1 ? '' : 's'}')))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => interval = v);
                      }),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                      value: repeat,
                      decoration: const InputDecoration(
                          labelText: 'Repeat if unanswered'),
                      items: const [5, 10, 15, 30]
                          .map((i) => DropdownMenuItem(
                              value: i, child: Text('Every $i minutes')))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => repeat = v);
                      }),
                  const SizedBox(height: 16),
                  const Text('Active days',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(
                      spacing: 6,
                      children: List.generate(7, (i) {
                        final day = i + 1;
                        final names = [
                          'Mon',
                          'Tue',
                          'Wed',
                          'Thu',
                          'Fri',
                          'Sat',
                          'Sun'
                        ];
                        final selected = active.contains(day);
                        return FilterChip(
                            label: Text(names[i]),
                            selected: selected,
                            onSelected: (v) => setState(() {
                                  if (v) {
                                    if (!active.contains(day)) active.add(day);
                                  } else {
                                    active.remove(day);
                                  }
                                }));
                      })),
                  const SizedBox(height: 12),
                  const Text(
                      'The Android system can delay reminders because of battery restrictions or Do Not Disturb. Enable notifications for the most reliable alerts.',
                      style: TextStyle(fontSize: 12, color: Colors.black54)),
                ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (active.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Select at least one active day.')));
                  return;
                }
                final start = sh * 60 + sm;
                final end = eh * 60 + em;
                if (end <= start) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text(
                          'End time must be later than start time on the same day.')));
                  return;
                }
                Navigator.pop(
                    context,
                    AppSettings(
                        dayStartHour: sh,
                        dayStartMinute: sm,
                        dayEndHour: eh,
                        dayEndMinute: em,
                        intervalHours: interval,
                        repeatMinutes: repeat,
                        checkinsEnabled: enabled,
                        appLockEnabled: widget.initial.appLockEnabled,
                        activeDays: active));
              },
              child: const Text('Save settings'))
        ],
      );
}

class PinSetupDialog extends StatefulWidget {
  const PinSetupDialog({super.key});
  @override
  State<PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends State<PinSetupDialog> {
  final first = TextEditingController(), second = TextEditingController();
  bool obscure = true;
  @override
  void dispose() {
    first.dispose();
    second.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Set your app PIN'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              'Use a 4–8 digit PIN. You may also use your phone fingerprint when supported.'),
          const SizedBox(height: 12),
          TextField(
              controller: first,
              keyboardType: TextInputType.number,
              obscureText: obscure,
              maxLength: 8,
              decoration: InputDecoration(
                  labelText: 'New PIN',
                  counterText: '',
                  suffixIcon: IconButton(
                      onPressed: () => setState(() => obscure = !obscure),
                      icon: Icon(
                          obscure ? Icons.visibility : Icons.visibility_off)))),
          const SizedBox(height: 8),
          TextField(
              controller: second,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              decoration: const InputDecoration(
                  labelText: 'Confirm PIN', counterText: '')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (first.text.length < 4 ||
                    first.text.length > 8 ||
                    !RegExp(r'^\d+$').hasMatch(first.text)) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('PIN must contain 4–8 digits.')));
                  return;
                }
                if (first.text != second.text) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('PINs do not match.')));
                  return;
                }
                Navigator.pop(context, first.text);
              },
              child: const Text('Enable lock'))
        ],
      );
}

class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.onUnlocked});
  final VoidCallback onUnlocked;
  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  final pin = TextEditingController();
  bool busy = false;
  String? error;
  bool biometricAvailable = false;
  final auth = LocalAuthentication();
  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  @override
  void dispose() {
    pin.dispose();
    super.dispose();
  }

  Future<void> _checkBiometric() async {
    try {
      final supported = await auth.isDeviceSupported();
      final available = await auth.canCheckBiometrics;
      if (mounted) setState(() => biometricAvailable = supported && available);
    } catch (_) {}
  }

  Future<void> _tryBiometric() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final ok = await auth.authenticate(
          localizedReason: 'Unlock DayPilot',
          options: const AuthenticationOptions(
              biometricOnly: true, stickyAuth: true));
      if (ok) {
        widget.onUnlocked();
        return;
      }
    } catch (_) {
      error = 'Biometric authentication unavailable. Use your app PIN.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _tryPin() async {
    final stored = await _secureStorage.read(key: _pinKey);
    if (stored != null && pin.text == stored) {
      widget.onUnlocked();
      return;
    }
    setState(() {
      error = 'Incorrect PIN. Try again.';
      pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
      child: Material(
          color: const Color(0xFFF5F8F5),
          child: SafeArea(
              child: Center(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(28),
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            Container(
                                width: 84,
                                height: 84,
                                decoration: const BoxDecoration(
                                    color: _greenDark, shape: BoxShape.circle),
                                child: const Icon(Icons.lock_outline_rounded,
                                    color: Colors.white, size: 40)),
                            const SizedBox(height: 22),
                            const Text('DayPilot is locked',
                                style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    color: _greenDark)),
                            const SizedBox(height: 8),
                            const Text(
                                'Unlock to view your tasks, notes and reports.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.black54)),
                            const SizedBox(height: 26),
                            TextField(
                                controller: pin,
                                obscureText: true,
                                keyboardType: TextInputType.number,
                                maxLength: 8,
                                decoration: const InputDecoration(
                                    labelText: 'App PIN',
                                    counterText: '',
                                    prefixIcon: Icon(Icons.password),
                                    border: OutlineInputBorder()),
                                onSubmitted: (_) => _tryPin()),
                            if (error != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(error!,
                                      style:
                                          const TextStyle(color: Colors.red))),
                            const SizedBox(height: 10),
                            SizedBox(
                                width: double.infinity,
                                child: FilledButton(
                                    onPressed: busy ? null : _tryPin,
                                    child: const Text('Unlock with PIN'))),
                            if (biometricAvailable) ...[
                              const SizedBox(height: 8),
                              SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                      onPressed: busy ? null : _tryBiometric,
                                      icon: const Icon(Icons.fingerprint),
                                      label: const Text(
                                          'Use fingerprint / biometrics')))
                            ],
                          ])))))));
}
