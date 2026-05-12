import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../main.dart';
import '../theme.dart';

import 'cpass.dart';
import '../services/streak_service.dart';
import '../services/notification_service.dart';
import '../services/noti_log.dart';
import 'notifications_page.dart';

class UserSettingsPage extends StatefulWidget {
  const UserSettingsPage({super.key});

  @override
  State<UserSettingsPage> createState() => _UserSettingsPageState();
}

class _UserSettingsPageState extends State<UserSettingsPage> {
  final supabase = Supabase.instance.client;

  User? get user => supabase.auth.currentUser;

  bool _loadingStreak = true;
  String? _streakError;
  StreakData? _streak;

  // unread badge
  int _unreadCount = 0;

  // Reminder state (persisted)
  bool _reminderOn = false;
  TimeOfDay _reminderTime = const TimeOfDay(hour: 21, minute: 0);
  bool _savingReminder = false;

  // Theme mode state (persisted)
  ThemeMode _themeMode = ThemeMode.system;
  bool _loadingTheme = true;

  // Improved formatting: proper Title Case for "john.doe" -> "John Doe"
  String get displayName {
    final email = user?.email;
    if (email == null || !email.contains('@')) return "User";
    
    final nameParts = email.split('@').first.trim().split('.');
    if (nameParts.isEmpty || nameParts.first.isEmpty) return "User";
    
    return nameParts.map((part) {
      if (part.isEmpty) return "";
      return part[0].toUpperCase() + part.substring(1).toLowerCase();
    }).join(" ");
  }

  // ===============================
  // Malaysia Time Helpers (UTC+8)
  // ===============================

  DateTime _nowMalaysia() {
    return DateTime.now().toUtc().add(const Duration(hours: 8));
  }

  DateTime? _toMalaysiaTime(String? utcString) {
    if (utcString == null) return null;

    final parsed = DateTime.tryParse(utcString);
    if (parsed == null) return null;

    return parsed.toUtc().add(const Duration(hours: 8));
  }

  int _daysSince(DateTime createdAtMalaysia) {
    final now = _nowMalaysia();

    final startDate = DateTime(
      createdAtMalaysia.year,
      createdAtMalaysia.month,
      createdAtMalaysia.day,
    );

    final todayDate = DateTime(
      now.year,
      now.month,
      now.day,
    );

    return todayDate.difference(startDate).inDays + 1;
  }

  Future<void> _logout() async {
    await supabase.auth.signOut();
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _loadUnreadCount() async {
    final c = await NotificationLogService.instance.unreadCount();
    if (!mounted) return;
    setState(() => _unreadCount = c);
  }

  Future<void> _openNotifications() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NotificationsPage()),
    );
    await _loadUnreadCount();
  }

  @override
  void initState() {
    super.initState();
    _loadStreak();
    _loadReminderPrefs();
    _loadThemeMode();
    _loadUnreadCount();
  }

  Future<void> _loadThemeMode() async {
    final m = await ThemePrefs.load();
    if (!mounted) return;
    setState(() {
      _themeMode = m;
      _loadingTheme = false;
    });
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    // Save to SharedPreferences so it persists across app restarts
    // (Assuming ThemePrefs has a save method. If not, use SharedPreferences directly here)
    try {
      await ThemePrefs.save(mode); 
    } catch (_) {
      // Fallback if ThemePrefs.save doesn't exist:
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('theme_mode', mode.name);
    }

    if (!mounted) return;
    final app = MyApp.of(context);
    app.setThemeMode(mode);

    setState(() => _themeMode = mode);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final msg = mode == ThemeMode.system
          ? "Theme set to System Default"
          : (mode == ThemeMode.dark ? "Dark Mode enabled" : "Light Mode enabled");

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    });
  }

  Future<void> _loadStreak() async {
    if (user == null) return;

    setState(() {
      _loadingStreak = true;
      _streakError = null;
    });

    try {
      final data = await StreakService(supabase).touchToday();
      if (!mounted) return;

      setState(() => _streak = data);

      await _checkStreakNotification(data.streak);
      await _loadUnreadCount();
    } catch (e) {
      if (!mounted) return;
      setState(() => _streakError = e.toString());
    } finally {
      if (!mounted) return;
      setState(() => _loadingStreak = false);
    }
  }

  // Simplified: Let NotificationService handle the "multiples of 7" business logic
  Future<void> _checkStreakNotification(int streak) async {
    if (streak <= 0) return;
    await NotificationService.instance.checkStreak(streak);
  }

  // =========================
  // Reminder Persistence
  // =========================
  static const _kReminderOn = "daily_reminder_on";
  static const _kReminderHour = "daily_reminder_hour";
  static const _kReminderMinute = "daily_reminder_minute";

  Future<void> _loadReminderPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    final on = prefs.getBool(_kReminderOn) ?? false;
    final hour = prefs.getInt(_kReminderHour) ?? 21;
    final minute = prefs.getInt(_kReminderMinute) ?? 0;

    final t = TimeOfDay(hour: hour, minute: minute);

    if (!mounted) return;
    setState(() {
      _reminderOn = on;
      _reminderTime = t;
    });

    if (on) {
      await NotificationService.instance.scheduleDailyReminder(
        hour: hour,
        minute: minute,
        title: "SmartBudget reminder",
        body: "Open SmartBudget and log today’s spending ✅",
      );
    }
  }

  Future<void> _saveReminderPrefs(bool on, TimeOfDay time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kReminderOn, on);
    await prefs.setInt(_kReminderHour, time.hour);
    await prefs.setInt(_kReminderMinute, time.minute);
  }

  Future<void> _applyReminderSchedule({
    required bool on,
    required TimeOfDay time,
  }) async {
    if (!mounted) return;
    setState(() => _savingReminder = true);

    try {
      if (on) {
        await NotificationService.instance.scheduleDailyReminder(
          hour: time.hour,
          minute: time.minute,
          title: "SmartBudget reminder",
          body: "Open SmartBudget and log today’s spending ✅",
        );
      } else {
        await NotificationService.instance.cancelDailyReminder();
      }

      await _saveReminderPrefs(on, time);

      if (!mounted) return;
      setState(() {
        _reminderOn = on;
        _reminderTime = time;
      });

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(on ? "Daily reminder set for ${time.format(context)}" : "Daily reminder turned off"),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text("Reminder error: $e"),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (!mounted) return;
      setState(() => _savingReminder = false);
    }
  }

  Future<void> _pickReminderTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _reminderTime,
    );

    if (picked == null) return;

    if (!mounted) return;
    setState(() => _reminderTime = picked);

    await _saveReminderPrefs(_reminderOn, picked);

    if (_reminderOn) {
      await _applyReminderSchedule(on: true, time: picked);
    }
  }

  String levelTitle(int bestStreak) {
    if (bestStreak >= 61) return "Master Saver 👑";
    if (bestStreak >= 31) return "Financial Focused 💼";
    if (bestStreak >= 15) return "Disciplined ✅";
    if (bestStreak >= 8) return "Consistent 🔥";
    if (bestStreak >= 4) return "Building Habit 🌱";
    return "Starter ✨";
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final createdAtMalaysia = _toMalaysiaTime(user?.createdAt);
    final activeDays =
        createdAtMalaysia != null ? _daysSince(createdAtMalaysia) : null;
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : "?";

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text("Settings", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: "Notifications",
            onPressed: _openNotifications,
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(Icons.notifications_none_rounded, color: cs.onSurface),
                if (_unreadCount > 0)
                  Positioned(
                    right: 0,
                    top: 2,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: cs.error,
                        shape: BoxShape.circle,
                        border: Border.all(color: cs.surface, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: user == null
          ? const Center(child: Text("No user logged in"))
          : RefreshIndicator(
              onRefresh: () async {
                await _loadStreak();
                await _loadUnreadCount();
              },
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                children: [
                  // --- PROFILE HERO ---
                  Column(
                    children: [
                      CircleAvatar(
                        radius: 46,
                        backgroundColor: cs.primaryContainer,
                        foregroundColor: cs.onPrimaryContainer,
                        child: Text(initial, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(height: 16),
                      Text(displayName, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: cs.onSurface)),
                      const SizedBox(height: 4),
                      Text(user!.email ?? "", style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant, fontWeight: FontWeight.w500)),
                      if (activeDays != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest.withOpacity(0.5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text("Member for $activeDays days", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: cs.primary)),
                        ),
                      ]
                    ],
                  ),
                  const SizedBox(height: 32),

                  // --- STREAK CARD ---
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      gradient: LinearGradient(
                        colors: [Colors.orange.shade400, Colors.deepOrange.shade600],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [BoxShadow(color: Colors.orange.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 6))],
                    ),
                    child: _loadingStreak
                        ? const Center(child: CircularProgressIndicator(color: Colors.white))
                        : _streakError != null
                            ? Row(
                                children: [
                                  const Icon(Icons.error_outline, color: Colors.white),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(_streakError!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
                                ],
                              )
                            : Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), shape: BoxShape.circle),
                                    child: const Icon(Icons.local_fire_department_rounded, color: Colors.white, size: 32),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          "${_streak?.streak ?? 0} Day Streak!",
                                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Colors.white),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          "Best: ${_streak?.bestStreak ?? 0} • ${levelTitle(_streak?.bestStreak ?? 0)}",
                                          style: TextStyle(color: Colors.white.withOpacity(0.9), fontWeight: FontWeight.w600, fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                  ),
                  const SizedBox(height: 24),

                  // --- PREFERENCES ---
                  Text("Preferences", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: t.dividerColor.withOpacity(0.4)),
                      boxShadow: [BoxShadow(color: t.shadowColor.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.palette_outlined, color: cs.primary, size: 22),
                                  const SizedBox(width: 12),
                                  const Text("Appearance", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                                ],
                              ),
                              const SizedBox(height: 16),
                              if (_loadingTheme)
                                const Center(child: CircularProgressIndicator())
                              else
                                Row(
                                  children: [
                                    _ThemeSegment(
                                      label: "System",
                                      icon: Icons.brightness_auto_rounded,
                                      isSelected: _themeMode == ThemeMode.system,
                                      onTap: () => _setThemeMode(ThemeMode.system),
                                    ),
                                    const SizedBox(width: 8),
                                    _ThemeSegment(
                                      label: "Light",
                                      icon: Icons.light_mode_rounded,
                                      isSelected: _themeMode == ThemeMode.light,
                                      onTap: () => _setThemeMode(ThemeMode.light),
                                    ),
                                    const SizedBox(width: 8),
                                    _ThemeSegment(
                                      label: "Dark",
                                      icon: Icons.dark_mode_rounded,
                                      isSelected: _themeMode == ThemeMode.dark,
                                      onTap: () => _setThemeMode(ThemeMode.dark),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                        Divider(height: 1, color: t.dividerColor.withOpacity(0.4)),
                        SwitchListTile(
                          value: _reminderOn,
                          onChanged: _savingReminder ? null : (v) => _applyReminderSchedule(on: v, time: _reminderTime),
                          activeColor: cs.primary,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          secondary: Icon(Icons.notifications_active_outlined, color: cs.primary, size: 22),
                          title: const Text("Daily Reminder", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          subtitle: Text("Log today's spending", style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                        ),
                        if (_reminderOn) ...[
                          Divider(height: 1, indent: 56, color: t.dividerColor.withOpacity(0.4)),
                          ListTile(
                            enabled: !_savingReminder,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                            leading: const SizedBox(width: 22), // indent alignment
                            title: const Text("Reminder Time", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(8)),
                              child: Text(_reminderTime.format(context), style: TextStyle(fontWeight: FontWeight.bold, color: cs.onPrimaryContainer)),
                            ),
                            onTap: _pickReminderTime,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // --- ACCOUNT & SECURITY ---
                  Text("Account & Security", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: t.dividerColor.withOpacity(0.4)),
                      boxShadow: [BoxShadow(color: t.shadowColor.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: Icon(Icons.lock_outline_rounded, color: cs.primary, size: 22),
                          title: const Text("Change Password", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          trailing: Icon(Icons.chevron_right_rounded, color: t.hintColor),
                          onTap: () {
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordPage()));
                          },
                        ),
                        Divider(height: 1, indent: 54, color: t.dividerColor.withOpacity(0.4)),
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: Icon(Icons.logout_rounded, color: cs.error, size: 22),
                          title: Text("Log Out", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: cs.error)),
                          onTap: _logout,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }
}

// Custom Segmented Button for Theme Selection
class _ThemeSegment extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemeSegment({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? cs.primaryContainer : cs.surfaceContainerHighest.withOpacity(0.4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isSelected ? cs.primary : Colors.transparent),
          ),
          child: Column(
            children: [
              Icon(icon, size: 20, color: isSelected ? cs.primary : cs.onSurfaceVariant),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                  color: isSelected ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}