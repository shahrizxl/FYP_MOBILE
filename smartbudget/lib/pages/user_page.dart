import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api_config.dart';
import '../services/auth_service.dart';
import '../services/transaction_service.dart';
import '../services/notification_service.dart';
import '../services/auth_gate.dart';
import 'transaction_management_page.dart';
import 'user_settings_page.dart';
import 'category_breakdown_page.dart';
import '../services/streak_service.dart';
import '../services/globals.dart';
import 'prediction_page.dart';

// =============================================================================
// USER PAGE
// =============================================================================

class UserPage extends StatefulWidget {
  const UserPage({super.key});

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  final _txService = TransactionService();

  // ── Loading / error ───────────────────────────────────────────────────────
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _txs = [];

  // ── Date selection ────────────────────────────────────────────────────────
  int _selectedYear = DateTime.now().year;
  int? _selectedMonth = DateTime.now().month;

  // ── Budget targets ────────────────────────────────────────────────────────
  bool _targetsLoading = false;
  String? _targetsError;
  double _monthlyBudget = 0;
  Map<String, double> _targetRmByCat = {};
  Map<String, double> _rawPctByCat = {};
  Map<String, double> _rawAmtByCat = {};

  // ── Live metrics ──────────────────────────────────────────────────────────
  double? _actualSpentSoFar;

  // ── Prediction state ──────────────────────────────────────────────────────
  bool _predLoading = false;
  String? _predError;
  String? _predMessage;
  double? _predNextDay;
  double? _predNextWeek;
  double? _predNextMonth;
  int _predReqId = 0;

  // ── ML training state ─────────────────────────────────────────────────────
  int _mlDaysCount = 0;
  bool _mlReady = false;

  // ── One-shot notification guards ──────────────────────────────────────────
  bool _milestoneChecked = false;
  bool _inactiveChecked = false;

  // ── Getters ───────────────────────────────────────────────────────────────

  String? get _userId => Supabase.instance.client.auth.currentUser?.id;

  String get _displayName {
    final email = Supabase.instance.client.auth.currentUser?.email;
    if (email == null || !email.contains('@')) return 'User';
    final name = email.split('@').first.trim();
    if (name.isEmpty) return 'User';
    return name[0].toUpperCase() + name.substring(1);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    globalTransactionUpdateNotifier.addListener(_onGlobalTxUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeData());
  }

  @override
  void dispose() {
    globalTransactionUpdateNotifier.removeListener(_onGlobalTxUpdate);
    super.dispose();
  }

  Future<void> _initializeData() async {
    _silentlyUpdateStreak();
    await _loadTx();
    await _loadTargets();
    _loadPrediction();
    _checkInactiveUser();
  }

  // ── Data helpers ──────────────────────────────────────────────────────────

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  String _dateText(dynamic raw) {
    final dt = _parseDate(raw);
    if (dt == null) return '-';
    return DateFormat('dd-MM-yyyy').format(dt.toLocal());
  }

  bool _inSelectedYear(Map<String, dynamic> t) {
    final dt = t['_parsedDate'] as DateTime?;
    return dt != null && dt.year == _selectedYear;
  }

  bool _inSelectedMonth(Map<String, dynamic> t) {
    if (_selectedMonth == null) return false;
    final dt = t['_parsedDate'] as DateTime?;
    return dt != null && dt.year == _selectedYear && dt.month == _selectedMonth;
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  double? _numOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }

  String _normCatKey(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return 'other';
    s = s.replaceAll('-', '_').replaceAll(' ', '_');
    if (s == 'uncategorized') return 'other';
    if (s == 'health') return 'healthcare';
    if (s == 'personalcare') return 'personal_care';
    return s;
  }

  String _prettyCat(String key) {
    return key
        .split('_')
        .map((p) => p.isEmpty ? p : p[0].toUpperCase() + p.substring(1))
        .join(' ');
  }

  Map<String, double> _spentByCategoryForMonth(
      List<Map<String, dynamic>> monthTx) {
    final Map<String, double> totals = {};
    for (final t in monthTx) {
      if ((t['type'] ?? '').toString().trim().toLowerCase() != 'expense') {
        continue;
      }
      final key = _normCatKey((t['category'] ?? '').toString());
      totals[key] = (totals[key] ?? 0) + _asDouble(t['amount']);
    }
    return totals;
  }

  // ── Prediction state reset ────────────────────────────────────────────────

  void _clearPredictionState() {
    _predNextDay = null;
    _predNextWeek = null;
    _predNextMonth = null;
    _actualSpentSoFar = null;
    _predMessage = null;
  }

  // ── Load transactions ─────────────────────────────────────────────────────

  Future<void> _loadTx() async {
    final uid = _userId;
    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    if (uid == null) {
      setState(() {
        _loading = false;
        _error = 'Session expired. Please login again.';
        _txs = [];
      });
      return;
    }

    try {
      final data = await _txService.getMyTransactions(uid);

      final parsedData = data.map((t) {
        final dt = _parseDate(t['date'])?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0);
        return {...t, '_parsedDate': dt};
      }).toList();

      parsedData.sort((a, b) =>
          (b['_parsedDate'] as DateTime).compareTo(a['_parsedDate'] as DateTime));

      if (!mounted) return;
      _txs = parsedData;
      _calculateMlMetrics();

      if (!_milestoneChecked) {
        final income = _txs
            .where((t) =>
                (t['type'] ?? '').toString().trim().toLowerCase() == 'income')
            .fold<double>(0, (s, t) => s + _asDouble(t['amount']));
        final expense = _txs
            .where((t) =>
                (t['type'] ?? '').toString().trim().toLowerCase() == 'expense')
            .fold<double>(0, (s, t) => s + _asDouble(t['amount']));
        final balance = income - expense;
        if (balance > 0) {
          await NotificationService.instance.checkSavingMilestone(balance);
        }
        _milestoneChecked = true;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _txs = [];
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _calculateMlMetrics() {
    final uniqueDays = <String>{};
    final now = DateTime.now();
    final trainStart = DateTime(now.year, now.month - 6, 1);

    for (final tx in _txs) {
      final type = tx['type']?.toString().toLowerCase().trim() ?? 'expense';
      if (type != 'expense') continue;

      final dt = tx['_parsedDate'] as DateTime?;
      if (dt == null || dt.isBefore(trainStart) || dt.isAfter(now)) continue;

      uniqueDays.add(
          '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}');
    }

    setState(() {
      _mlDaysCount = uniqueDays.length;
      _mlReady = _mlDaysCount >= 30;
    });
  }

  // ── Load budget targets ───────────────────────────────────────────────────

  Future<void> _loadTargets() async {
    final uid = _userId;
    if (uid == null) return;

    if (_selectedMonth == null) {
      if (mounted) {
        setState(() {
          _targetsLoading = false;
          _targetsError = null;
          _monthlyBudget = 0;
          _targetRmByCat = {};
          _rawPctByCat = {};
          _rawAmtByCat = {};
        });
      }
      return;
    }

    if (!mounted) return;
    setState(() {
      _targetsLoading = true;
      _targetsError = null;
    });

    try {
      final res = await Supabase.instance.client
          .from('category_budgets')
          .select('monthly_budget, percents, amounts')
          .eq('user_id', uid)
          .eq('year', _selectedYear)
          .eq('month', _selectedMonth!)
          .maybeSingle();

      if (!mounted) return;

      if (res == null) {
        setState(() {
          _monthlyBudget = 0;
          _targetRmByCat = {};
          _rawPctByCat = {};
          _rawAmtByCat = {};
        });
        return;
      }

      final mb = _asDouble(res['monthly_budget']);
      final perc = (res['percents'] is Map<String, dynamic>)
          ? res['percents'] as Map<String, dynamic>
          : <String, dynamic>{};
      final amts = (res['amounts'] is Map<String, dynamic>)
          ? res['amounts'] as Map<String, dynamic>
          : <String, dynamic>{};

      final Map<String, double> pctMap = {};
      final Map<String, double> amtMap = {};
      final Map<String, double> rmMap = {};

      for (final k in {...perc.keys, ...amts.keys}) {
        final key = _normCatKey(k.toString());
        final a = _asDouble(amts[k]);
        final p = _asDouble(perc[k]);
        if (a > 0) {
          amtMap[key] = a;
          pctMap[key] = 0;
          rmMap[key] = a;
        } else if (mb > 0 && p > 0) {
          pctMap[key] = p;
          amtMap[key] = 0;
          rmMap[key] = mb * (p / 100);
        }
      }

      setState(() {
        _monthlyBudget = mb;
        _rawPctByCat = pctMap;
        _rawAmtByCat = amtMap;
        _targetRmByCat = rmMap;
      });

      if (_selectedMonth != null && _targetRmByCat.isNotEmpty) {
        final monthTx = _txs.where(_inSelectedMonth).toList();
        final spentByCat = _spentByCategoryForMonth(monthTx);
        for (final entry in _targetRmByCat.entries) {
          await NotificationService.instance.checkBudgetAlert(
            spent: spentByCat[entry.key] ?? 0,
            budget: entry.value,
            category: _prettyCat(entry.key),
            budgetYear: _selectedYear,
            budgetMonth: _selectedMonth!,
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _targetsError = e.toString());
    } finally {
      if (mounted) setState(() => _targetsLoading = false);
    }
  }

  // ── Load prediction ───────────────────────────────────────────────────────

  Future<void> _loadPrediction() async {
    if (!mounted) return;

    if (_txs.isEmpty) {
      setState(() {
        _predLoading = false;
        _predError = 'No transaction data available.';
      });
      return;
    }

    final int reqId = ++_predReqId;

    setState(() {
      _predLoading = true;
      _predError = null;
      _predMessage = null;
      _clearPredictionState();
    });

    final now = DateTime.now();
    final trainStart = DateTime(now.year, now.month - 6, 1);

    final expenses = _txs
        .where((t) {
          if ((t['type'] ?? '').toString().trim().toLowerCase() != 'expense') {
            return false;
          }
          final dt = t['_parsedDate'] as DateTime?;
          if (dt == null) return false;
          final isAnchorMonth = _selectedMonth != null &&
              dt.year == _selectedYear &&
              dt.month == _selectedMonth;
          if (isAnchorMonth) return true;
          return !dt.isBefore(trainStart) && !dt.isAfter(now);
        })
        .map((t) => {
              'date': DateFormat('yyyy-MM-dd')
                  .format(t['_parsedDate'] as DateTime),
              'amount': _asDouble(t['amount']),
              'type': 'expense',
              'description': (t['description'] ?? '').toString(),
              'category': (t['category'] ?? '').toString(),
            })
        .toList()
      ..sort((a, b) {
        final ad = DateTime.tryParse(a['date'] as String) ?? DateTime(1970);
        final bd = DateTime.tryParse(b['date'] as String) ?? DateTime(1970);
        return ad.compareTo(bd);
      });

    if (expenses.isEmpty) {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        _predLoading = false;
        _predError = 'No expense records found.';
      });
      return;
    }

    final bool monthMode = _selectedMonth != null;
    final Map<String, dynamic> body = {
      'transactions': expenses,
      'days': 60,
    };
    if (monthMode) {
      body['anchor_year'] = _selectedYear;
      body['anchor_month'] = _selectedMonth!;
    }

    try {
      final res = await http
          .post(
            Uri.parse(ApiConfig.predictUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));

      if (!mounted || reqId != _predReqId) return;

      if (res.statusCode < 200 || res.statusCode >= 300) {
        setState(() {
          _predLoading = false;
          _predError = 'Prediction unavailable (HTTP ${res.statusCode}).';
        });
        return;
      }

      final decoded = jsonDecode(res.body);
      final data = (decoded is Map<String, dynamic>)
          ? decoded
          : <String, dynamic>{};

      final nd  = _numOrNull(data['next_day']);
      final nw  = _numOrNull(data['next_week']);
      final nm  = _numOrNull(data['next_month']);
      final msg = (data['message'] ?? '').toString().trim();

      double? actualSpent;
      if (data['live_metrics'] is Map<String, dynamic>) {
        final lm = data['live_metrics'] as Map<String, dynamic>;
        actualSpent = _numOrNull(lm['actual_spent']);
      }

      if (!mounted || reqId != _predReqId) return;
      setState(() {
        _predNextDay   = nd;
        _predNextWeek  = nw;
        _predNextMonth = nm;
        _predLoading   = false;
        _predMessage   = msg.isEmpty ? null : msg;
        _predError     = null;
        _actualSpentSoFar = actualSpent;
      });

      if (monthMode && _predNextMonth != null && _monthlyBudget > 0) {
        await NotificationService.instance.safeSpendingWarning(
          predicted: _predNextMonth!,
          monthlyBudget: _monthlyBudget,
          budgetYear: _selectedYear,
          budgetMonth: _selectedMonth!,
        );
      }
    } on TimeoutException {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        _predLoading = false;
        _predError = 'Prediction timed out. Please try again.';
      });
    } catch (e) {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        _predLoading = false;
        _predError = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  // ── Streak & inactive user ────────────────────────────────────────────────

  Future<void> _silentlyUpdateStreak() async {
    if (_userId == null) return;
    try {
      final data = await StreakService(Supabase.instance.client).touchToday();
      await _checkStreakNotification(data.streak);
    } catch (e) {
      debugPrint('Failed to update daily streak: $e');
    }
  }

  Future<void> _checkStreakNotification(int streak) async {
    if (streak == 0 || streak % 7 != 0) return;
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final key = 'streak_${streak}_notified_${now.year}_${now.month}';
    if (prefs.getBool(key) ?? false) return;
    await NotificationService.instance.checkStreak(streak);
    await prefs.setBool(key, true);
  }

  Future<void> _checkInactiveUser() async {
    if (!mounted || _inactiveChecked || _txs.isEmpty) return;
    _inactiveChecked = true;
    final lastDate = _txs.first['_parsedDate'] as DateTime?;
    if (lastDate == null) return;
    final daysInactive = DateTime.now().difference(lastDate).inDays;
    await NotificationService.instance.checkInactive(daysInactive);
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  Future<void> _openTargetsEditor() async {
    if (_selectedMonth == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a month to edit targets.')),
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CategoryBreakdownPage(
            year: _selectedYear, month: _selectedMonth!),
      ),
    );
    if (!mounted) return;
    _initializeData();
  }

  Future<void> _openManage() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TransactionManagementPage()),
    );
    if (!mounted) return;
    _milestoneChecked = false;
    _inactiveChecked = false;
    _initializeData();
  }

  Future<void> _onGlobalTxUpdate() async {
    if (!mounted) return;
    _initializeData();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final isDark = t.brightness == Brightness.dark;

    final bool isMonthMode = _selectedMonth != null;
    final DateTime now = DateTime.now();

    final bool isFuture = isMonthMode
        ? (_selectedYear > now.year ||
            (_selectedYear == now.year && _selectedMonth! > now.month))
        : (_selectedYear > now.year);

    final bool isPastMonth = isMonthMode &&
        (_selectedYear < now.year ||
            (_selectedYear == now.year && _selectedMonth! < now.month));

    final double? displayNextDay   = isFuture ? null : _predNextDay;
    final double? displayNextWeek  = isFuture ? null : _predNextWeek;
    final double? displayNextMonth = isFuture
        ? null
        : (isPastMonth && _actualSpentSoFar != null
            ? _actualSpentSoFar
            : _predNextMonth);

    final yearTx  = _txs.where(_inSelectedYear).toList();
    final monthTx = isMonthMode
        ? yearTx.where(_inSelectedMonth).toList()
        : <Map<String, dynamic>>[];
    final activeTx = isMonthMode ? monthTx : yearTx;

    final label = isMonthMode
        ? DateFormat('MMMM yyyy')
            .format(DateTime(_selectedYear, _selectedMonth!))
        : 'Year $_selectedYear';

    final incomeTotal = activeTx
        .where((tx) =>
            (tx['type'] ?? '').toString().trim().toLowerCase() == 'income')
        .fold<double>(0, (s, tx) => s + _asDouble(tx['amount']));
    final expenseTotal = activeTx
        .where((tx) =>
            (tx['type'] ?? '').toString().trim().toLowerCase() == 'expense')
        .fold<double>(0, (s, tx) => s + _asDouble(tx['amount']));
    final double netBalance = incomeTotal - expenseTotal;

    double totalSavings = 0;
    for (final item in _txs) {
      final type = (item['type'] ?? '').toString().trim().toLowerCase();
      final amt  = _asDouble(item['amount']);
      if (type == 'income') {
        totalSavings += amt;
      } else if (type == 'expense') {
        totalSavings -= amt;
      }
    }

    final Map<String, double> catTotals = {};
    for (final tMap in activeTx) {
      if ((tMap['type'] ?? '').toString().trim().toLowerCase() != 'expense') {
        continue;
      }
      final key = _normCatKey((tMap['category'] ?? '').toString().trim());
      catTotals[key] = (catTotals[key] ?? 0) + _asDouble(tMap['amount']);
    }

    final topExpenses = catTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top3 = topExpenses.take(3).toList();
    final last5 = activeTx.take(5).toList();

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: cs.surfaceContainerLowest,
        centerTitle: false,
        titleSpacing: 16,
        automaticallyImplyLeading: false,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hello, $_displayName 👋',
              style: TextStyle(
                  fontSize: 14,
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              'SmartBudget',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: Icon(Icons.person_outline_rounded, color: cs.onSurface),
            onPressed: () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const UserSettingsPage()));
            },
          ),
          IconButton(
            tooltip: 'Logout',
            icon: Icon(Icons.logout_rounded, color: cs.error),
            onPressed: () async {
              await NotificationService.instance.cancelAll();
              await AuthService().logout();
              if (context.mounted) {
                Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const AuthGate()));
              }
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: () async {
                    _milestoneChecked = false;
                    _inactiveChecked  = false;
                    await _initializeData();
                  },
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                    children: [
                      _MonthYearPicker(
                        year: _selectedYear,
                        month: _selectedMonth,
                        onChanged: (y, m) async {
                          setState(() {
                            _selectedYear  = y;
                            _selectedMonth = m;
                            _predError     = null;
                            _predMessage   = null;
                            _clearPredictionState();
                          });
                          await Future.wait([
                            _loadTargets(),
                            _loadPrediction(),
                          ]);
                        },
                      ),
                      const SizedBox(height: 16),
                      _DashboardHeroCard(
                        label: label,
                        income: incomeTotal,
                        expense: expenseTotal,
                        balance: netBalance,
                        totalSavings: totalSavings,
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'Predictions',
                        icon: Icons.auto_awesome_rounded,
                        headerTrailing: _MlReadinessChip(
                          daysCount: _mlDaysCount,
                          isReady: _mlReady,
                        ),
                        child: _predLoading
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                    child: CircularProgressIndicator()),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_predMessage != null)
                                    _InfoBadge(
                                        message: _predMessage!,
                                        isDark: isDark,
                                        isError: false),
                                  if (_predError != null)
                                    _InfoBadge(
                                        message: _predError!,
                                        isDark: isDark,
                                        isError: true),
                                  if (displayNextDay == null &&
                                      displayNextWeek == null &&
                                      displayNextMonth == null)
                                    Text(
                                      'Keep logging transactions to unlock AI predictions.',
                                      style: TextStyle(color: t.hintColor),
                                    )
                                  else
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _MiniPredCard(
                                            title: 'Tomorrow',
                                            value: displayNextDay?.toString(),
                                            icon: Icons.today_rounded,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: _MiniPredCard(
                                            title: '1 Week',
                                            value: displayNextWeek?.toString(),
                                            icon: Icons.date_range_rounded,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: _MiniPredCard(
                                            title: isMonthMode
                                                ? 'This Month'
                                                : 'Month',
                                            value: displayNextMonth?.toString(),
                                            icon: Icons.calendar_month_rounded,
                                          ),
                                        ),
                                      ],
                                    ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      icon: const Icon(
                                          Icons.analytics_rounded),
                                      label: const Text('More Details'),
                                      onPressed: () async {
                                        await Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  const PredictionDetailsPage()),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'Balance Trend',
                        icon: Icons.show_chart_rounded,
                        actionText: 'RM ${netBalance.toStringAsFixed(2)}',
                        child: Padding(
                          padding:
                              const EdgeInsets.only(top: 8.0, right: 16),
                          child: _BalanceTrendChart(
                            tx: _txs,
                            asDouble: _asDouble,
                            parseDate: _parseDate,
                            year: _selectedYear,
                            month: _selectedMonth,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'Top Expenses',
                        icon: Icons.pie_chart_rounded,
                        child: _TopExpensesBars(
                          top: top3
                              .map((e) =>
                                  MapEntry(_prettyCat(e.key), e.value))
                              .toList(),
                          maxValue: top3.isEmpty ? 1 : top3.first.value,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'Cash Flow',
                        icon: Icons.swap_vert_rounded,
                        child: _CashFlowBars(
                            income: incomeTotal, expense: expenseTotal),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'Monthly Targets',
                        icon: Icons.flag_rounded,
                        actionText: isMonthMode ? 'Edit' : null,
                        onAction: isMonthMode ? _openTargetsEditor : null,
                        child: !isMonthMode
                            ? Text(
                                'Targets are set monthly. Please select a specific month above.',
                                style: TextStyle(color: t.hintColor),
                              )
                            : _targetsLoading
                                ? const Center(
                                    child: CircularProgressIndicator())
                                : _targetsError != null
                                    ? Text(_targetsError!,
                                        style: TextStyle(color: cs.error))
                                    : _TargetsList(
                                        monthlyBudget: _monthlyBudget,
                                        targetRmByCat: _targetRmByCat,
                                        rawPctByCat: _rawPctByCat,
                                        rawAmtByCat: _rawAmtByCat,
                                        spentByCategory:
                                            _spentByCategoryForMonth(monthTx),
                                        prettyCat: _prettyCat,
                                      ),
                      ),
                      const SizedBox(height: 16),
                      _SectionCard(
                        title: 'Recent Transactions',
                        icon: Icons.history_rounded,
                        actionText: 'View All',
                        onAction: _openManage,
                        child: _LastRecordsList(
                          items: last5,
                          asDouble: _asDouble,
                          dateText: _dateText,
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

// =============================================================================
// ML READINESS CHIP
// =============================================================================

class _MlReadinessChip extends StatelessWidget {
  final int daysCount;
  final bool isReady;

  const _MlReadinessChip({required this.daysCount, required this.isReady});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border.all(color: cs.primary.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.calendar_month_rounded, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$daysCount / 30 days',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: cs.primary),
              ),
              Text(
                isReady ? 'ML Ready' : 'Training',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// INFO BADGE
// =============================================================================

class _InfoBadge extends StatelessWidget {
  final String message;
  final bool isDark;
  final bool isError;

  const _InfoBadge({
    required this.message,
    required this.isDark,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final t  = Theme.of(context);
    final cs = t.colorScheme;

    final Color bg = isError
        ? cs.errorContainer.withValues(alpha: 0.35)
        : (isDark
            ? Colors.white10
            : Colors.black.withValues(alpha: 0.04));
    final Color fg = isError
        ? cs.onErrorContainer
        : (isDark ? Colors.white : Colors.black87);
    final IconData icon =
        isError ? Icons.error_outline_rounded : Icons.info_outline_rounded;

    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.dividerColor.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  color: fg, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// DASHBOARD HERO CARD
// =============================================================================

class _DashboardHeroCard extends StatelessWidget {
  final String label;
  final double income;
  final double expense;
  final double balance;
  final double totalSavings;

  const _DashboardHeroCard({
    required this.label,
    required this.income,
    required this.expense,
    required this.balance,
    required this.totalSavings,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isPositive = balance >= 0;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: [cs.primary, cs.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
              color: cs.primary.withValues(alpha: 0.3),
              blurRadius: 15,
              offset: const Offset(0, 8))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(
                    color: cs.onPrimary.withValues(alpha: 0.8),
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isPositive
                      ? Colors.white.withValues(alpha: 0.2)
                      : cs.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isPositive ? 'Surplus' : 'Deficit',
                  style: TextStyle(
                      color: isPositive ? Colors.green : cs.onErrorContainer,
                      fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'RM ${balance.toStringAsFixed(2)}',
            style: TextStyle(
                color: cs.onPrimary,
                fontSize: 36,
                fontWeight: FontWeight.bold,
                height: 1.1),
          ),
          Text(
            'Balance',
            style: TextStyle(
                color: cs.onPrimary.withValues(alpha: 0.8), fontSize: 13),
          ),
          const SizedBox(height: 16), // was 12 -> before the savings badge; now before Income/Expense row
          Row(
            children: [
              Expanded(
                child: _HeroStatBox(
                  icon: Icons.arrow_downward_rounded,
                  iconColor: Colors.green.shade300,
                  label: 'Income',
                  value: income,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _HeroStatBox(
                  icon: Icons.arrow_upward_rounded,
                  iconColor: Colors.orange.shade300,
                  label: 'Expense',
                  value: expense,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12), // moved down here, after Income/Expense
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.savings_rounded, size: 16, color: cs.onPrimary),
                const SizedBox(width: 6),
                Text(
                  'All-time savings: RM ${totalSavings.toStringAsFixed(2)}',
                  style: TextStyle(
                      color: cs.onPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroStatBox extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final double value;

  const _HeroStatBox({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 16, color: iconColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                  color: cs.onPrimary.withValues(alpha: 0.9),
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            'RM ${value.toStringAsFixed(2)}',
            style: TextStyle(
                color: cs.onPrimary, fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SECTION CARD
// =============================================================================

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? headerTrailing;
  final String? actionText;
  final VoidCallback? onAction;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    this.headerTrailing,
    this.actionText,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
              color: Theme.of(context).shadowColor.withValues(alpha: 0.02),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 18, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (headerTrailing != null) ...[
                headerTrailing!,
                if (actionText != null) const SizedBox(width: 8),
              ],
              if (actionText != null)
                InkWell(
                  onTap: onAction,
                  child: Text(
                    actionText!,
                    style: TextStyle(
                        color: onAction != null
                            ? cs.primary
                            : cs.onSurfaceVariant,
                        fontWeight: FontWeight.bold,
                        fontSize: 14),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }
}

// =============================================================================
// MINI PREDICTION CARD
// =============================================================================

class _MiniPredCard extends StatelessWidget {
  final String title;
  final String? value;
  final IconData icon;

  const _MiniPredCard(
      {required this.title, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.onSurface),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 11,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value == null
                  ? '-'
                  : 'RM ${double.tryParse(value!)?.toStringAsFixed(2) ?? value}',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// TOP EXPENSES BARS
// =============================================================================

class _TopExpensesBars extends StatelessWidget {
  final List<MapEntry<String, double>> top;
  final double maxValue;

  const _TopExpensesBars({required this.top, required this.maxValue});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (top.isEmpty) {
      return Text('No expenses recorded yet.',
          style: TextStyle(color: Theme.of(context).hintColor));
    }
    return Column(
      children: top.map((e) {
        final pct = (e.value / maxValue).clamp(0.0, 1.0);
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(e.key,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('RM ${e.value.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 8,
                  backgroundColor: cs.surfaceContainerHighest,
                  color: cs.primary,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// CASH FLOW BARS
// =============================================================================

class _CashFlowBars extends StatelessWidget {
  final double income;
  final double expense;
  const _CashFlowBars({required this.income, required this.expense});

  @override
  Widget build(BuildContext context) {
    final maxV = max(1.0, max(income, expense));
    return Column(
      children: [
        _FlowRow(
          label: 'Total Income',
          value: income,
          pct: (income / maxV).clamp(0.0, 1.0),
          color: Colors.green.shade500,
          textColor: Colors.green.shade600,
        ),
        const SizedBox(height: 20),
        _FlowRow(
          label: 'Total Expenses',
          value: expense,
          pct: (expense / maxV).clamp(0.0, 1.0),
          color: Colors.orange.shade500,
          textColor: Colors.orange.shade600,
        ),
      ],
    );
  }
}

class _FlowRow extends StatelessWidget {
  final String label;
  final double value;
  final double pct;
  final Color color;
  final Color textColor;

  const _FlowRow({
    required this.label,
    required this.value,
    required this.pct,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            Text(
              'RM ${value.toStringAsFixed(2)}',
              style:
                  TextStyle(fontWeight: FontWeight.bold, color: textColor),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 8,
            backgroundColor: cs.surfaceContainerHighest,
            color: color,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// TARGETS LIST
// =============================================================================

class _TargetsList extends StatelessWidget {
  final double monthlyBudget;
  final Map<String, double> targetRmByCat;
  final Map<String, double> rawPctByCat;
  final Map<String, double> rawAmtByCat;
  final Map<String, double> spentByCategory;
  final String Function(String key) prettyCat;

  const _TargetsList({
    required this.monthlyBudget,
    required this.targetRmByCat,
    required this.rawPctByCat,
    required this.rawAmtByCat,
    required this.spentByCategory,
    required this.prettyCat,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (targetRmByCat.isEmpty) {
      return Text('No targets set for this month.',
          style: TextStyle(color: Theme.of(context).hintColor));
    }
    final entries = targetRmByCat.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      children: entries.map((e) {
        final spent = spentByCategory[e.key] ?? 0;
        final pct   = e.value <= 0 ? 0.0 : (spent / e.value);
        final over  = e.value > 0 && spent > e.value;

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(prettyCat(e.key),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(
                    'RM ${spent.toStringAsFixed(2)} / RM ${e.value.toStringAsFixed(2)}',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: over ? cs.error : cs.onSurface),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: pct.clamp(0.0, 1.0),
                  minHeight: 8,
                  backgroundColor: cs.surfaceContainerHighest,
                  color: over ? cs.error : cs.primary,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// LAST RECORDS LIST
// =============================================================================

class _LastRecordsList extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final double Function(dynamic) asDouble;
  final String Function(dynamic) dateText;

  const _LastRecordsList({
    required this.items,
    required this.asDouble,
    required this.dateText,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (items.isEmpty) {
      return Text('No recent transactions.',
          style: TextStyle(color: Theme.of(context).hintColor));
    }
    return Column(
      children: items.map((tMap) {
        final type     = (tMap['type'] ?? '').toString().trim().toLowerCase();
        final isIncome = type == 'income';
        final amount   = asDouble(tMap['amount']);
        final title    = (tMap['category'] ?? '').toString().trim().isEmpty
            ? 'Transaction'
            : tMap['category'].toString();
        final desc = (tMap['description'] ?? '').toString();
        final date = dateText(tMap['date']);

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isIncome
                      ? Colors.green.shade100
                      : cs.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isIncome
                      ? Icons.arrow_downward_rounded
                      : Icons.arrow_upward_rounded,
                  size: 16,
                  color:
                      isIncome ? Colors.green.shade700 : cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(
                      desc.isEmpty ? '—' : desc,
                      style: TextStyle(
                          color: Theme.of(context).hintColor, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${isIncome ? '+' : '-'}RM ${amount.toStringAsFixed(2)}',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color:
                            isIncome ? Colors.green.shade700 : cs.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    date,
                    style: TextStyle(
                        color: Theme.of(context).hintColor, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// =============================================================================
// MONTH / YEAR PICKER
// =============================================================================

class _MonthYearPicker extends StatelessWidget {
  final int year;
  final int? month;
  final void Function(int year, int? month) onChanged;

  const _MonthYearPicker({
    required this.year,
    required this.month,
    required this.onChanged,
  });

  Future<void> _pickDate(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6),
            child: DefaultTabController(
              length: 2,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TabBar(
                      tabs: [Tab(text: 'Month'), Tab(text: 'Year')]),
                  Expanded(
                    child: TabBarView(
                      children: [
                        GridView.builder(
                          padding: const EdgeInsets.all(16),
                          physics: const BouncingScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 2.4,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: 13,
                          itemBuilder: (_, index) {
                            if (index == 0) {
                              return _GridTile(
                                text: 'All Year',
                                isSelected: month == null,
                                onTap: () {
                                  Navigator.pop(ctx);
                                  onChanged(year, null);
                                },
                              );
                            }
                            final m = index;
                            return _GridTile(
                              text: DateFormat('MMM')
                                  .format(DateTime(2000, m)),
                              isSelected: month == m,
                              onTap: () {
                                Navigator.pop(ctx);
                                onChanged(year, m);
                              },
                            );
                          },
                        ),
                        GridView.builder(
                          padding: const EdgeInsets.all(16),
                          physics: const BouncingScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 2.4,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: 13,
                          itemBuilder: (_, index) {
                            final y = DateTime.now().year - 6 + index;
                            return _GridTile(
                              text: '$y',
                              isSelected: year == y,
                              onTap: () {
                                Navigator.pop(ctx);
                                onChanged(y, month);
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final monthLabel = month == null
        ? 'All Year'
        : DateFormat('MMM').format(DateTime(year, month!));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            style: IconButton.styleFrom(
                backgroundColor:
                    cs.surfaceContainerHighest.withValues(alpha: 0.5)),
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
            onPressed: () {
              if (month == null) {
                onChanged(year - 1, null);
              } else {
                final prev = DateTime(year, month! - 1, 1);
                onChanged(prev.year, prev.month);
              }
            },
          ),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _pickDate(context),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.calendar_month_rounded,
                      size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    '$monthLabel $year',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: cs.onSurface),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down_rounded,
                      size: 20, color: Theme.of(context).hintColor),
                ],
              ),
            ),
          ),
          IconButton(
            style: IconButton.styleFrom(
                backgroundColor:
                    cs.surfaceContainerHighest.withValues(alpha: 0.5)),
            icon: const Icon(Icons.chevron_right_rounded, size: 20),
            onPressed: () {
              if (month == null) {
                onChanged(year + 1, null);
              } else {
                final next = DateTime(year, month! + 1, 1);
                onChanged(next.year, next.month);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _GridTile extends StatelessWidget {
  final String text;
  final bool isSelected;
  final VoidCallback onTap;

  const _GridTile(
      {required this.text, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? cs.primary
              : cs.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
              color: isSelected ? cs.onPrimary : cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

// =============================================================================
// CHART WIDGETS
// =============================================================================

class _BalanceTrendChart extends StatelessWidget {
  final List<Map<String, dynamic>> tx;
  final double Function(dynamic) asDouble;
  final DateTime? Function(dynamic) parseDate;
  final int year;
  final int? month;

  const _BalanceTrendChart({
    required this.tx,
    required this.asDouble,
    required this.parseDate,
    required this.year,
    required this.month,
  });

  int _daysInMonth(int y, int m) {
    final next = (m == 12) ? DateTime(y + 1, 1, 1) : DateTime(y, m + 1, 1);
    return next.difference(DateTime(y, m, 1)).inDays;
  }

  @override
  Widget build(BuildContext context) {
    if (month == null) {
      return _YearTrend(
          tx: tx, asDouble: asDouble, parseDate: parseDate, year: year);
    }
    return _MonthTrend(
      tx: tx,
      asDouble: asDouble,
      parseDate: parseDate,
      year: year,
      month: month!,
      days: _daysInMonth(year, month!),
    );
  }
}

FlGridData _sharedGrid(BuildContext context, double maxAbs) {
  final t  = Theme.of(context);
  final cs = t.colorScheme;
  return FlGridData(
    show: true,
    drawVerticalLine: false,
    horizontalInterval: maxAbs == 0 ? 100 : maxAbs / 2,
    getDrawingHorizontalLine: (value) {
      if (value == 0) {
        return FlLine(
            color: cs.onSurface.withValues(alpha: 0.3),
            strokeWidth: 2,
            dashArray: [5, 5]);
      }
      return FlLine(
          color: t.dividerColor.withValues(alpha: 0.4),
          strokeWidth: 1,
          dashArray: [5, 5]);
    },
  );
}

LineTouchData _sharedTouchData(BuildContext context) {
  final cs     = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return LineTouchData(
    handleBuiltInTouches: true,
    getTouchedSpotIndicator: (barData, spotIndexes) => spotIndexes
        .map((_) => TouchedSpotIndicatorData(
              FlLine(
                  color: cs.primary.withValues(alpha: 0.5),
                  strokeWidth: 2,
                  dashArray: [4, 4]),
              FlDotData(
                show: true,
                getDotPainter: (spot, __, ___, ____) => FlDotCirclePainter(
                    radius: 5,
                    color: cs.primary,
                    strokeWidth: 3,
                    strokeColor: cs.surface),
              ),
            ))
        .toList(),
    touchTooltipData: LineTouchTooltipData(
      getTooltipColor: (_) => isDark ? Colors.white : Colors.black87,
      tooltipRoundedRadius: 8,
      getTooltipItems: (spots) => spots
          .map((s) => LineTooltipItem(
                'RM ${s.y.toStringAsFixed(2)}',
                TextStyle(
                    color: isDark ? Colors.black : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12),
              ))
          .toList(),
    ),
  );
}

LineChartBarData _sharedBarData(List<FlSpot> spots, BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return LineChartBarData(
    spots: spots,
    isCurved: true,
    preventCurveOverShooting: true,
    curveSmoothness: 0.25,
    color: cs.primary,
    barWidth: 3,
    isStrokeCapRound: true,
    dotData: const FlDotData(show: false),
    belowBarData: BarAreaData(
      show: true,
      cutOffY: 0,
      applyCutOffY: true,
      gradient: LinearGradient(
        colors: [
          cs.primary.withValues(alpha: 0.25),
          cs.primary.withValues(alpha: 0.0),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ),
    ),
    aboveBarData: BarAreaData(
      show: true,
      cutOffY: 0,
      applyCutOffY: true,
      gradient: LinearGradient(
        colors: [
          cs.error.withValues(alpha: 0.0),
          cs.error.withValues(alpha: 0.25),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ),
    ),
  );
}

class _YearTrend extends StatelessWidget {
  final List<Map<String, dynamic>> tx;
  final double Function(dynamic) asDouble;
  final DateTime? Function(dynamic) parseDate;
  final int year;

  const _YearTrend({
    required this.tx,
    required this.asDouble,
    required this.parseDate,
    required this.year,
  });

  @override
  Widget build(BuildContext context) {
    final now          = DateTime.now();
    final isFutureYear = year > now.year;

    double startingBalance = 0;
    final monthlyNet = List<double>.filled(12, 0);

    if (!isFutureYear) {
      final yearStart = DateTime(year, 1, 1);
      for (final t in tx) {
        final dt   = parseDate(t['date'])?.toLocal();
        if (dt == null) continue;
        final type = (t['type'] ?? '').toString().trim().toLowerCase();
        final amt  = asDouble(t['amount']);
        final net  = type == 'income'
            ? amt
            : type == 'expense'
                ? -amt
                : 0.0;
        if (dt.isBefore(yearStart)) {
          startingBalance += net;
        } else if (dt.year == year) {
          final idx = dt.month - 1;
          if (idx >= 0 && idx < 12) monthlyNet[idx] += net;
        }
      }
    }

    double running = startingBalance;
    final spots = <FlSpot>[];
    for (int i = 0; i < 12; i++) {
      if (isFutureYear) break;
      running += monthlyNet[i];
      spots.add(FlSpot(i.toDouble(), running));
      if (year == now.year && i == now.month - 1) break;
    }
    if (spots.length == 1) {
      spots.add(FlSpot(spots.first.x + 0.01, spots.first.y));
    }

    final ys     = spots.map((e) => e.y).toList();
    final rawMin = ys.isEmpty ? 0.0 : ys.reduce(min);
    final rawMax = ys.isEmpty ? 1.0 : ys.reduce(max);
    final maxAbs = max(rawMin.abs(), rawMax.abs());
    final pad    = maxAbs == 0 ? 100.0 : maxAbs * 0.2;

    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: -(maxAbs + pad),
          maxY: maxAbs + pad,
          baselineY: 0,
          lineTouchData: _sharedTouchData(context),
          gridData: _sharedGrid(context, maxAbs),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: 2,
                getTitlesWidget: (v, meta) {
                  final idx = v.toInt();
                  if (idx < 0 || idx > 11) return const SizedBox.shrink();
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 8,
                    child: Text(
                      DateFormat('MMM').format(DateTime(year, idx + 1)),
                      style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).hintColor,
                          fontWeight: FontWeight.bold),
                    ),
                  );
                },
              ),
            ),
          ),
          lineBarsData: [_sharedBarData(spots, context)],
        ),
      ),
    );
  }
}

class _MonthTrend extends StatelessWidget {
  final List<Map<String, dynamic>> tx;
  final double Function(dynamic) asDouble;
  final DateTime? Function(dynamic) parseDate;
  final int year;
  final int month;
  final int days;

  const _MonthTrend({
    required this.tx,
    required this.asDouble,
    required this.parseDate,
    required this.year,
    required this.month,
    required this.days,
  });

  @override
  Widget build(BuildContext context) {
    final now            = DateTime.now();
    final isFutureMonth  =
        year > now.year || (year == now.year && month > now.month);

    double startingBalance = 0;
    final dailyNet = List<double>.filled(days, 0);

    if (!isFutureMonth) {
      final monthStart = DateTime(year, month, 1);
      for (final t in tx) {
        final dt   = parseDate(t['date'])?.toLocal();
        if (dt == null) continue;
        final type = (t['type'] ?? '').toString().trim().toLowerCase();
        final amt  = asDouble(t['amount']);
        final net  = type == 'income'
            ? amt
            : type == 'expense'
                ? -amt
                : 0.0;
        if (dt.isBefore(monthStart)) {
          startingBalance += net;
        } else if (dt.year == year && dt.month == month) {
          final idx = dt.day - 1;
          if (idx >= 0 && idx < days) dailyNet[idx] += net;
        }
      }
    }

    double running = startingBalance;
    final spots = <FlSpot>[];
    for (int i = 0; i < days; i++) {
      if (isFutureMonth) break;
      running += dailyNet[i];
      spots.add(FlSpot(i.toDouble(), running));
      if (year == now.year && month == now.month && i == now.day - 1) break;
    }
    if (spots.length == 1) {
      spots.add(FlSpot(spots.first.x + 0.01, spots.first.y));
    }

    final ys     = spots.map((e) => e.y).toList();
    final rawMin = ys.isEmpty ? 0.0 : ys.reduce(min);
    final rawMax = ys.isEmpty ? 1.0 : ys.reduce(max);
    final maxAbs = max(rawMin.abs(), rawMax.abs());
    final pad    = maxAbs == 0 ? 100.0 : maxAbs * 0.2;

    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: -(maxAbs + pad),
          maxY: maxAbs + pad,
          baselineY: 0,
          lineTouchData: _sharedTouchData(context),
          gridData: _sharedGrid(context, maxAbs),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: 5,
                getTitlesWidget: (v, meta) {
                  final day = v.toInt() + 1;
                  if (day < 1 || day > days) return const SizedBox.shrink();
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 8,
                    child: Text(
                      '$day',
                      style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).hintColor,
                          fontWeight: FontWeight.bold),
                    ),
                  );
                },
              ),
            ),
          ),
          lineBarsData: [_sharedBarData(spots, context)],
        ),
      ),
    );
  }
}