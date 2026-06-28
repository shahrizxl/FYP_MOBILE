import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:supabase_flutter/supabase_flutter.dart';



import 'noti_log.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  String get _uid => Supabase.instance.client.auth.currentUser?.id ?? 'guest';


  // ===== Notification IDs (Spaced to avoid collisions) =====
  static const int _testId = 999;
  int get _dailyId =>
    _stableIdFromString(
      "daily_$_uid",
      base: 1000,
      mod: 500,
    );
  static const int _monthStartId = 2001;
  static const int _monthEndId = 2002;
  static const int _salaryId = 2003;
  static const int _predictOverId = 2004;

// ===== SharedPreferences Keys (User Specific) =====
  String get _kReminderOn => "${_uid}_daily_reminder_on";
  String get _kReminderHour => "${_uid}_daily_reminder_hour";
  String get _kReminderMinute => "${_uid}_daily_reminder_minute";

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

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        debugPrint("Notification tapped: $payload");
      },
    );
    await _requestPermissions();

    _initialized = true;
  }

  Future<void> restorePlannedPayments() async {
  final uid =
      Supabase.instance.client.auth.currentUser?.id;

  if (uid == null) return;

  final items = await Supabase.instance.client
      .from('planned_payments')
      .select(
          'id,title,amount,due_date,category,is_posted')
      .eq('user_id', uid)
      .eq('is_posted', false);

  for (final p in items) {
    final due =
        DateTime.parse(p['due_date']).toLocal();

    await schedulePlannedPaymentReminder(
      plannedPaymentId:
          p['id'].toString(),
      title: p['title'].toString(),
      amount:
          (p['amount'] as num).toDouble(),
      category:
          p['category'].toString(),
      dueDate: due,
      remindDaysBefore: 1,
      hour: 9,
      minute: 0,
    );
  }
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


// ==============================
// UPDATED NOTIFICATION FUNCTION
// ==============================

Future<void> _notifyOnce({
  required int id,
  required String notiKey,
  required String title,
  required String body,
  String type = "info",
}) async {
  try {
    await NotificationLogService.instance.createOnce(
      notiKey: notiKey,
      title: title,
      body: body,
      type: type,
    );
  } catch (_) {}

  if (kIsWeb) return;

  await init();

  await _plugin.show(
    id,
    title,
    body,
    _details(),
    payload: notiKey,
  );
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
  // EDGE-TRIGGER HELPERS & CLEANUP
  // ==============================
  Future<int> _getIntPref(String key, {int def = 0}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(key) ?? def;
  }

  Future<void> _setIntPref(String key, int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, value);
  }

  /// Cleans up old budget state keys from SharedPreferences to prevent bloat
  Future<void> _cleanupOldBudgetKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final currentPeriod = _periodKey(now.year, now.month);
    
    final keys = prefs.getKeys();
    for (final key in keys) {
      if ((key.contains('_budget_state-') || key.contains('_predict_over_state-')) &&
          !key.contains(currentPeriod)) {
        await prefs.remove(key);
      }
    }
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

    // Clean up old keys to keep SharedPreferences light
    await _cleanupOldBudgetKeys();

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
  int _stableIdFromString(String s, {required int base, required int mod}) {
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

    if (!_isCurrentMonth(budgetYear, budgetMonth)) return;

    final period = _periodKey(budgetYear, budgetMonth);
    final catKey = category.trim().toLowerCase().replaceAll(' ', '_');

    int newState = 0;
    if (spent >= budget) {
      newState = 2;
    } else if (spent >= 0.8 * budget) {
      newState = 1;
    }

    final stateKey = "${_uid}_budget_state-$period-$catKey";
    final oldState = await _getIntPref(stateKey, def: 0);

    if (newState < oldState) {
      await _setIntPref(stateKey, newState);
      return;
    }

    if (newState == oldState) return;

    await _setIntPref(stateKey, newState);

    // Separated ranges: 3000-3999 for 80%, 4000-4999 for Exceeded
    final id80 = _stableIdFromString("80_${period}_$catKey", base: 3000, mod: 1000);
    final idEx = _stableIdFromString("ex_${period}_$catKey", base: 4000, mod: 1000);
    
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
  Future<void> safeSpendingWarning({
    required double predicted,
    required double monthlyBudget,
    required int budgetYear,
    required int budgetMonth,
  }) async {
    if (monthlyBudget <= 0) return;

    if (!_isCurrentMonth(budgetYear, budgetMonth)) return;

    final period = _periodKey(budgetYear, budgetMonth);
    final key = "${_uid}_predict_over_state-$period";

    final isOver = predicted > monthlyBudget;
    final old = await _getIntPref(key, def: 0);
    final nowState = isOver ? 1 : 0;

    if (old == 0 && nowState == 1) {
      await _setIntPref(key, 1);

      await _notifyOnce(
        id: _predictOverId,
        notiKey: "predict-overbudget-$period",
        title: "📉 Overspending Risk",
        body: "At this pace you may overspend this month.",
        type: "warning",
      );
      return;
    }

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
      // Removed matchDateTimeComponents to prevent endless repeating on clamped days like the 28th.
      // ensureScheduled() will correctly queue up the next one next month.
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
    final key = "${_uid}_streak7_state";
    final old = await _getIntPref(key, def: 0);
    final nowState = (streak >= 7) ? 1 : 0;

    if (old == 0 && nowState == 1) {
      await _setIntPref(key, 1);
      await _notifyOnce(
        id: 5001,
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
    int bucket = 0;
    if (daysInactive >= 14) {
      bucket = 14;
    } else if (daysInactive >= 7) {
      bucket = 7;
    } else if (daysInactive >= 3) {
      bucket = 3;
    }

    final key = "${_uid}_inactive_bucket_state";
    final oldBucket = await _getIntPref(key, def: 0);

    if (bucket < oldBucket) {
      await _setIntPref(key, bucket);
      return;
    }

    if (bucket == oldBucket) return;

    await _setIntPref(key, bucket);

    if (bucket == 0) return;

    await _notifyOnce(
      id: 5002, // Kept out of the 4000s collision zone
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
    int level = 0;
    if (totalSavings >= 10000) {
      level = 3;
    } else if (totalSavings >= 5000) {
      level = 2;
    } else if (totalSavings >= 1000) {
      level = 1;
    }

    final key = "${_uid}_savings_milestone_level";
    final oldLevel = await _getIntPref(key, def: 0);

    if (level < oldLevel) {
      await _setIntPref(key, level);
      return;
    }

    if (level == oldLevel) return;

    await _setIntPref(key, level);

    if (level == 3) {
      await _notifyOnce(
        id: 6003,
        notiKey: "milestone-10000",
        title: "🏆 Financial Beast!",
        body: "RM10,000 saved!",
        type: "success",
      );
      return;
    }

    if (level == 2) {
      await _notifyOnce(
        id: 6002,
        notiKey: "milestone-5000",
        title: "🚀 Big Achievement!",
        body: "Savings reached RM5,000!",
        type: "success",
      );
      return;
    }

    if (level == 1) {
      await _notifyOnce(
        id: 6001,
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
    
    // Range: 9000 - 10999
    final id =
        _stableIdFromString("pp_rem_$plannedPaymentId", base: 9000, mod: 2000);

    // NOTE: Supabase immediate logging has been removed here.
    // If you log it here, it will show up instantly in your UI instead of next week.
    // Log this event only when the payment actually fires or via a backend cron job.

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
        _stableIdFromString("pp_rem_$plannedPaymentId", base: 9000, mod: 2000);
    await _plugin.cancel(id);

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("shown_$id");
  }

  Future<void> plannedPaymentPosted({
    required String plannedPaymentId,
    required String title,
    required double amount,
    required String category,
  }) async {
    // Range: 7000 - 8999
    final id =
        _stableIdFromString("pp_post_$plannedPaymentId", base: 7000, mod: 2000);

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



    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();
    for (final key in keys) {
      if (key.startsWith("shown_")) {
        await prefs.remove(key);
      }
}
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