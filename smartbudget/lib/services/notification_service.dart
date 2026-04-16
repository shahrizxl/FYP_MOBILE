import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'noti_log.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  // Anti-spam (per app session) for INSTANT alerts only (popup notif)
  final Set<int> _shownIds = {};

  // ===== Notification IDs =====
  static const int _dailyId = 1001;
  static const int _testId = 999;
  static const int _monthStartId = 2001;
  static const int _monthEndId = 2002;
  static const int _salaryId = 2003;

  // ===== SharedPreferences Keys (MUST match your UserSettingsPage) =====
  static const String _kReminderOn = "daily_reminder_on";
  static const String _kReminderHour = "daily_reminder_hour";
  static const String _kReminderMinute = "daily_reminder_minute";

  // ==============================
  // INIT
  // ==============================
  Future<void> init() async {
    if (kIsWeb) return;
    if (_initialized) return;

    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation("Asia/Kuala_Lumpur"));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();

    const settings = InitializationSettings(android: android, iOS: ios);

    await _plugin.initialize(settings);
    await _requestPermissions();

    _initialized = true;
  }

  Future<void> _requestPermissions() async {
    if (kIsWeb) return;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      await androidImpl?.requestNotificationsPermission();
      await androidImpl?.requestExactAlarmsPermission();
    }

    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  // ==============================
  // COMMON DETAILS
  // ==============================
  NotificationDetails _details() {
    const android = AndroidNotificationDetails(
      'smartbudget_channel',
      'SmartBudget Alerts',
      channelDescription: 'Budget & AI financial notifications',
      importance: Importance.max,
      priority: Priority.high,
    );

    const ios = DarwinNotificationDetails();

    return const NotificationDetails(android: android, iOS: ios);
  }

  /// Logs ONCE in Supabase (no duplicates) + shows local notification (anti-spam per session)
  Future<void> _notifyOnce({
    required int id,
    required String notiKey, // unique key for NotificationPage
    required String title,
    required String body,
    String type = "info",
  }) async {
    // 1) Always log to Supabase
    try {
      await NotificationLogService.instance.createOnce(
        notiKey: notiKey,
        title: title,
        body: body,
        type: type,
      );
    } catch (_) {
      // ignore logging errors
    }

    // 2) Show local notification (mobile only)
    if (kIsWeb) return;

    // session anti-spam for popup
    if (_shownIds.contains(id)) return;

    await init();
    await _plugin.show(id, title, body, _details());
    _shownIds.add(id);
  }

  Future<bool> _exactAlarmsAllowed() async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform != TargetPlatform.android) return true;

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    return await androidImpl?.canScheduleExactNotifications() ?? false;
  }

  // ==============================
  // HELPERS (safe dates)
  // ==============================
  int _daysInMonth(int year, int month) {
    final nextMonth = (month == 12)
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    final thisMonth = DateTime(year, month, 1);
    return nextMonth.difference(thisMonth).inDays;
  }

  tz.TZDateTime _clampDayInMonth(
    int year,
    int month,
    int day,
    int hour,
    int minute,
  ) {
    final maxDay = _daysInMonth(year, month);
    final safeDay = day.clamp(1, maxDay);
    return tz.TZDateTime(tz.local, year, month, safeDay, hour, minute);
  }

  tz.TZDateTime _nextMonthSameDayTime(
    tz.TZDateTime now,
    int day,
    int hour,
    int minute,
  ) {
    final y = (now.month == 12) ? now.year + 1 : now.year;
    final m = (now.month == 12) ? 1 : now.month + 1;
    return _clampDayInMonth(y, m, day, hour, minute);
  }

  // ==============================
  // MONTH / PERIOD HELPERS
  // ==============================

  /// Returns "YYYY-MM"
  String _periodKey(int year, int month) {
    return "$year-${month.toString().padLeft(2, '0')}";
  }

  /// true if the passed (year, month) equals current device month
  bool _isCurrentMonth(int year, int month) {
    final now = DateTime.now();
    return now.year == year && now.month == month;
  }

  // ==============================
  // EDGE-TRIGGER HELPERS (persist across app restarts)
  // ==============================
  Future<int> _getIntPref(String key, {int def = 0}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(key) ?? def;
  }

  Future<void> _setIntPref(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  // ==============================
  // ENSURE SCHEDULED
  // ==============================
  Future<void> ensureScheduled({
    int salaryDay = 25,
    int salaryHour = 20,
    int monthStartHour = 9,
  }) async {
    if (kIsWeb) return;
    await init();

    final pending = await _plugin.pendingNotificationRequests();
    final pendingIds = pending.map((p) => p.id).toSet();

    await _ensureDailyFromPrefs(pendingIds);

    if (!pendingIds.contains(_monthStartId)) {
      await scheduleBeginningOfMonth(hour: monthStartHour);
    }

    if (!pendingIds.contains(_salaryId)) {
      await scheduleSalaryReminder(day: salaryDay, hour: salaryHour);
    }
  }

  Future<void> _ensureDailyFromPrefs(Set<int> pendingIds) async {
    final prefs = await SharedPreferences.getInstance();
    final on = prefs.getBool(_kReminderOn) ?? false;
    final hour = prefs.getInt(_kReminderHour) ?? 21;
    final minute = prefs.getInt(_kReminderMinute) ?? 0;

    if (!on) {
      if (pendingIds.contains(_dailyId)) {
        await cancelDailyReminder();
      }
      return;
    }

    if (!pendingIds.contains(_dailyId)) {
      await scheduleDailyReminder(
        hour: hour,
        minute: minute,
        title: "SmartBudget reminder",
        body: "Open SmartBudget and log today’s spending ✅",
      );
    }
  }

  // ==============================
  // DAILY REMINDER
  // ==============================
  Future<void> scheduleDailyReminder({
    int hour = 21,
    int minute = 0,
    String title = "SmartBudget Reminder",
    String body = "Take 30 seconds to log today’s spending ✅",
  }) async {
    if (kIsWeb) return;
    await init();

    await _plugin.cancel(_dailyId);

    final now = tz.TZDateTime.now(tz.local);
    var next =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);

    if (next.isBefore(now)) {
      next = next.add(const Duration(days: 1));
    }

    final exactOk = await _exactAlarmsAllowed();

    await _plugin.zonedSchedule(
      _dailyId,
      title,
      body,
      next,
      _details(),
      androidScheduleMode: exactOk
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  // ==============================
  // TEST NOTIFICATION
  // ==============================
  Future<void> scheduleTestNotification({int minutesFromNow = 1}) async {
    if (kIsWeb) return;
    await init();

    final now = tz.TZDateTime.now(tz.local);
    final when = now.add(Duration(minutes: minutesFromNow));

    await _plugin.zonedSchedule(
      _testId,
      "Test notification",
      "If you see this, reminders work ✅",
      when,
      _details(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // ==============================
  // BUDGET ALERTS (period aware + EDGE TRIGGERED)
  // ==============================
  int _stableIdFromString(String s, {int base = 3000, int mod = 600}) {
    int h = 0;
    for (final code in s.codeUnits) {
      h = (h * 31 + code) & 0x7fffffff;
    }
    return base + (h % mod);
  }

  /// ✅ Only alerts if the budget belongs to the CURRENT month.
  /// ✅ Edge-triggered: only pops when crossing thresholds; if spent drops, state resets.
  Future<void> checkBudgetAlert({
    required double spent,
    required double budget,
    required String category,
    required int budgetYear,
    required int budgetMonth,
  }) async {
    if (budget <= 0) return;

    // prevents Feb budget being used for March alerts
    if (!_isCurrentMonth(budgetYear, budgetMonth)) return;

    final period = _periodKey(budgetYear, budgetMonth);
    final catKey = category.trim().toLowerCase().replaceAll(' ', '_');

    // 0 = below 80%, 1 = >=80% and <100%, 2 = exceeded
    int newState = 0;
    if (spent >= budget) {
      newState = 2;
    } else if (spent >= 0.8 * budget) {
      newState = 1;
    }

    final stateKey = "budget_state-$period-$catKey";
    final oldState = await _getIntPref(stateKey, def: 0);

    // ✅ If it dropped, update stored state (reset) and do NOT notify
    if (newState < oldState) {
      await _setIntPref(stateKey, newState);
      return;
    }

    // ✅ If same state, do nothing
    if (newState == oldState) return;

    // ✅ If crossed upward, store then notify once
    await _setIntPref(stateKey, newState);

    final id80 = _stableIdFromString("80_${period}_$catKey", base: 3000);
    final idEx = _stableIdFromString("ex_${period}_$catKey", base: 3600);
    
    if (newState == 1) {
      await _notifyOnce(
        id: id80,
        notiKey: "budget80-$period-$catKey",
        title: "⚠️ Budget 80% Used",
        body: "$category budget is 80% used.",
        type: "warning",
      );
    } else if (newState == 2) {
      await _notifyOnce(
        id: idEx,
        notiKey: "budgetex-$period-$catKey",
        title: "❌ Budget Exceeded",
        body: "$category exceeded by RM${(spent - budget).toStringAsFixed(2)}",
        type: "danger",
      );
    }
  }

  // ==============================
  // PREDICTION WARNING (period aware + EDGE TRIGGERED)
  // ==============================
  /// ✅ Only alerts if the budget belongs to the CURRENT month.
  /// ✅ Edge-triggered: if becomes safe again, resets so it can pop later.
  Future<void> safeSpendingWarning({
    required double predicted,
    required double monthlyBudget,
    required int budgetYear,
    required int budgetMonth,
  }) async {
    if (monthlyBudget <= 0) return;

    // prevents Feb budget being used for March prediction warning
    if (!_isCurrentMonth(budgetYear, budgetMonth)) return;

    final period = _periodKey(budgetYear, budgetMonth);
    final key = "predict_over_state-$period";

    final isOver = predicted > monthlyBudget;

    // old: 0 = not over, 1 = over
    final old = await _getIntPref(key, def: 0);
    final nowState = isOver ? 1 : 0;

    // became over now (0 -> 1), notify once
    if (old == 0 && nowState == 1) {
      await _setIntPref(key, 1);

      await _notifyOnce(
        id: 3003,
        notiKey: "predict-overbudget-$period",
        title: "📉 Overspending Risk",
        body: "At this pace you may overspend this month.",
        type: "warning",
      );
      return;
    }

    // if it goes back safe, reset so it can pop again later
    if (old == 1 && nowState == 0) {
      await _setIntPref(key, 0);
    }
  }

  // ==============================
  // MONTH START
  // ==============================
  Future<void> scheduleBeginningOfMonth({int hour = 9, int minute = 0}) async {
    if (kIsWeb) return;
    await init();

    final now = tz.TZDateTime.now(tz.local);

    tz.TZDateTime next =
        tz.TZDateTime(tz.local, now.year, now.month, 1, hour, minute);
    if (!(now.day == 1 && now.isBefore(next))) {
      next = _nextMonthSameDayTime(now, 1, hour, minute);
    }

    await _plugin.zonedSchedule(
      _monthStartId,
      "🎯 New Month Started",
      "Set your budget and start strong!",
      next,
      _details(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime,
    );
  }

  // ==============================
  // SALARY REMINDER
  // ==============================
  Future<void> scheduleSalaryReminder({
    int day = 25,
    int hour = 20,
    int minute = 0,
  }) async {
    if (kIsWeb) return;
    await init();

    final now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime next = _clampDayInMonth(now.year, now.month, day, hour, minute);

    if (next.isBefore(now)) {
      next = _nextMonthSameDayTime(now, day, hour, minute);
    }

    await _plugin.zonedSchedule(
      _salaryId,
      "💵 Salary Reminder",
      "Plan your 50/30/20 allocation wisely.",
      next,
      _details(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime,
    );
  }

  // ==============================
  // END OF MONTH SUMMARY
  // ==============================
  Future<void> scheduleEndOfMonthSummary({required double saved}) async {
    if (kIsWeb) return;
    await init();

    final now = tz.TZDateTime.now(tz.local);
    final lastDayDate =
        tz.TZDateTime(tz.local, now.year, now.month + 1, 0, 21);

    await _plugin.zonedSchedule(
      _monthEndId,
      "🏁 Month Summary",
      "You saved RM${saved.toStringAsFixed(2)} this month 💰",
      lastDayDate,
      _details(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // ==============================
  // STREAK (EDGE TRIGGERED)
  // ==============================
  Future<void> checkStreak(int streak) async {
    // Pop only when crossing to 7+ (resets if streak drops below 7)
    const key = "streak7_state";
    final old = await _getIntPref(key, def: 0);
    final nowState = (streak >= 7) ? 1 : 0;

    if (old == 0 && nowState == 1) {
      await _setIntPref(key, 1);
      await _notifyOnce(
        id: 4001,
        notiKey: "streak-7",
        title: "🔥 7 Day Streak!",
        body: "You're building financial discipline 💪",
        type: "success",
      );
      return;
    }

    if (old == 1 && nowState == 0) {
      await _setIntPref(key, 0);
    }
  }

  // ==============================
  // INACTIVE (EDGE TRIGGERED)
  // ==============================
  Future<void> checkInactive(int daysInactive) async {
    // Buckets: 0, 3, 7, 14
    int bucket = 0;
    if (daysInactive >= 14) {
      bucket = 14;
    } else if (daysInactive >= 7) {
      bucket = 7;
    } else if (daysInactive >= 3) {
      bucket = 3;
    }

    const key = "inactive_bucket_state";
    final oldBucket = await _getIntPref(key, def: 0);

    // If bucket drops, reset (no popup on decrease)
    if (bucket < oldBucket) {
      await _setIntPref(key, bucket);
      return;
    }

    // Same bucket = no popup
    if (bucket == oldBucket) return;

    // Bucket increased: store + popup
    await _setIntPref(key, bucket);

    if (bucket == 0) return;

    await _notifyOnce(
      id: 4002,
      notiKey: "inactive-$bucket",
      title: "👋 We Miss You",
      body: "You haven’t logged expenses for $daysInactive days.",
      type: "info",
    );
  }

  // ==============================
  // SAVING MILESTONE (EDGE TRIGGERED)
  // ==============================
  Future<void> checkSavingMilestone(double totalSavings) async {
    // Level: 0 <1000, 1 >=1000, 2 >=5000, 3 >=10000
    int level = 0;
    if (totalSavings >= 10000) {
      level = 3;
    } else if (totalSavings >= 5000) {
      level = 2;
    } else if (totalSavings >= 1000) {
      level = 1;
    }

    const key = "savings_milestone_level";
    final oldLevel = await _getIntPref(key, def: 0);

    // If savings drop, reset level (no popup on decrease)
    if (level < oldLevel) {
      await _setIntPref(key, level);
      return;
    }

    // Same level = no popup
    if (level == oldLevel) return;

    // Level increased: store + popup
    await _setIntPref(key, level);

    if (level == 3) {
      await _notifyOnce(
        id: 5003,
        notiKey: "milestone-10000",
        title: "🏆 Financial Beast!",
        body: "RM10,000 saved!",
        type: "success",
      );
      return;
    }

    if (level == 2) {
      await _notifyOnce(
        id: 5002,
        notiKey: "milestone-5000",
        title: "🚀 Big Achievement!",
        body: "Savings reached RM5,000!",
        type: "success",
      );
      return;
    }

    if (level == 1) {
      await _notifyOnce(
        id: 5001,
        notiKey: "milestone-1000",
        title: "🎉 Savings Milestone!",
        body: "You reached RM1,000!",
        type: "success",
      );
    }
  }

  // ==============================
  // PLANNED PAYMENTS
  // ==============================
  Future<void> schedulePlannedPaymentReminder({
    required String plannedPaymentId,
    required String title,
    required double amount,
    required String category,
    required DateTime dueDate,
    int remindDaysBefore = 1,
    int hour = 9,
    int minute = 0,
  }) async {
    final due = dueDate.toLocal();

    final notiKey =
        "pp-rem-$plannedPaymentId-${due.year}-${due.month}-${due.day}-$remindDaysBefore";

    // Always log
    try {
      await NotificationLogService.instance.createOnce(
        notiKey: notiKey,
        title: "⏰ Planned payment reminder",
        body: "$title • RM${amount.toStringAsFixed(2)} ($category)",
        type: "info",
      );
    } catch (_) {}

    if (kIsWeb) return;

    await init();

    var remindAt = tz.TZDateTime(
      tz.local,
      due.year,
      due.month,
      due.day,
      hour,
      minute,
    ).subtract(Duration(days: remindDaysBefore));

    final now = tz.TZDateTime.now(tz.local);
    if (remindAt.isBefore(now)) {
      remindAt = now.add(const Duration(minutes: 1));
    }

    final exactOk = await _exactAlarmsAllowed();
    final id =
        _stableIdFromString("pp_rem_$plannedPaymentId", base: 8000, mod: 1500);

    await _plugin.zonedSchedule(
      id,
      "⏰ Planned payment reminder",
      "$title • RM${amount.toStringAsFixed(2)} ($category)",
      remindAt,
      _details(),
      androidScheduleMode: exactOk
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> cancelPlannedPaymentReminder({
    required String plannedPaymentId,
  }) async {
    if (kIsWeb) return;
    await init();

    final id =
        _stableIdFromString("pp_rem_$plannedPaymentId", base: 8000, mod: 1500);
    await _plugin.cancel(id);
    _shownIds.remove(id);
  }

  Future<void> plannedPaymentPosted({
    required String plannedPaymentId,
    required String title,
    required double amount,
    required String category,
  }) async {
    final id =
        _stableIdFromString("pp_post_$plannedPaymentId", base: 7000, mod: 1500);

    await _notifyOnce(
      id: id,
      notiKey: "pp-post-$plannedPaymentId",
      title: "✅ Payment deducted",
      body: "$title • RM${amount.toStringAsFixed(2)} ($category)",
      type: "info",
    );
  }

  // ==============================
  // CANCEL
  // ==============================
  Future<void> cancelDailyReminder() async {
    if (kIsWeb) return;
    await init();
    await _plugin.cancel(_dailyId);
  }

  Future<void> cancelAll() async {
    if (kIsWeb) return;
    await init();
    await _plugin.cancelAll();
    _shownIds.clear();
  }

  // ==============================
  // DEBUG HELPERS
  // ==============================
  Future<List<PendingNotificationRequest>> pending() async {
    if (kIsWeb) return <PendingNotificationRequest>[];
    await init();
    return _plugin.pendingNotificationRequests();
  }
}