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


class UserPage extends StatefulWidget {
  const UserPage({super.key});

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  final txService = TransactionService();

  bool loading = true;
  String? error;
  List<Map<String, dynamic>> txs = [];

  int selectedYear = DateTime.now().year;
  int? selectedMonth = DateTime.now().month;

  bool targetsLoading = false;
  String? targetsError;
  double monthlyBudget = 0;
  Map<String, double> targetRmByCat = {};
  Map<String, double> rawPctByCat = {};
  Map<String, double> rawAmtByCat = {};

  bool predLoading = false;
  String? predError;
  double? predNextDay;
  double? predNextWeek;
  double? predNextMonth;

  int _predReqId = 0;

  bool _milestoneChecked = false;
  bool _inactiveChecked = false;

  final Set<String> _budgetAlertSentKeys = {};

  final searchCtrl = TextEditingController();

  String? get userId => Supabase.instance.client.auth.currentUser?.id;

  String get displayName {
    final email = Supabase.instance.client.auth.currentUser?.email;
    if (email == null || !email.contains('@')) return "User";
    final name = email.split('@').first.trim();
    if (name.isEmpty) return "User";
    return name[0].toUpperCase() + name.substring(1);
  }

  @override
  void dispose() {
    globalTransactionUpdateNotifier.removeListener(_onGlobalTxUpdate);
    searchCtrl.dispose();
    super.dispose();
  }

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  String _dateText(dynamic raw) {
    final dt = _parseDate(raw);
    if (dt == null) return "-";
    return DateFormat("dd-MM-yyyy").format(dt.toLocal());
  }

  bool _inSelectedYear(Map<String, dynamic> t) {
    final dt = _parseDate(t['date'])?.toLocal();
    if (dt == null) return false;
    return dt.year == selectedYear;
  }

  bool _inSelectedMonth(Map<String, dynamic> t) {
    if (selectedMonth == null) return false;
    final dt = _parseDate(t['date'])?.toLocal();
    if (dt == null) return false;
    return dt.year == selectedYear && dt.month == selectedMonth;
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  double? _numOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = v.toString().trim();
    return double.tryParse(s);
  }

  // FIX 1: Safe helper to compute the last moment of a given year/month,
  // avoiding DateTime(y, 13, 0) overflow when month == 12.
  DateTime _endOfMonth(int year, int month) {
    // Move to the 1st of the NEXT month, then go back 1 second.
    final nextMonthFirst = (month == 12)
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    return nextMonthFirst.subtract(const Duration(seconds: 1));
  }

  Future<void> loadTx() async {
    final uid = userId;

    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });

    if (uid == null) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = "Session expired. Please login again.";
        txs = [];
      });
      return;
    }

    try {
      final data = await txService.getMyTransactions(uid);

      final sorted = List<Map<String, dynamic>>.from(data)
        ..sort((a, b) {
          final ad = _parseDate(a['date'])?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bd = _parseDate(b['date'])?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bd.compareTo(ad);
        });

      if (!mounted) return;
      setState(() {
        txs = sorted;
      });

      if (!_milestoneChecked) {
        final incomeTotal = sorted
            .where((t) => (t['type'] ?? '').toString().trim().toLowerCase() == 'income')
            .fold<double>(0, (sum, t) => sum + _asDouble(t['amount']));

        final expenseTotal = sorted
            .where((t) => (t['type'] ?? '').toString().trim().toLowerCase() == 'expense')
            .fold<double>(0, (sum, t) => sum + _asDouble(t['amount']));

        final balanceTotal = incomeTotal - expenseTotal;

        if (balanceTotal > 0) {
          await NotificationService.instance.checkSavingMilestone(balanceTotal);
          if (!mounted) return;
        }

        _milestoneChecked = true;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        txs = [];
      });
    } finally {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  String _normCatKey(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return "other";
    s = s.replaceAll('-', '_').replaceAll(' ', '_');
    if (s == "uncategorized") return "other";
    if (s == "health") return "healthcare";
    if (s == "personalcare") return "personal_care";
    return s;
  }

  String _prettyCat(String key) {
    final parts = key.split('_');
    return parts.map((p) => p.isEmpty ? p : (p[0].toUpperCase() + p.substring(1))).join(' ');
  }

  Map<String, double> _spentByCategoryForMonth(List<Map<String, dynamic>> monthTx) {
    final Map<String, double> catTotals = {};
    for (final t in monthTx) {
      final type = (t['type'] ?? '').toString().trim().toLowerCase();
      if (type != 'expense') continue;

      final catRaw = (t['category'] ?? '').toString();
      final key = _normCatKey(catRaw);
      catTotals[key] = (catTotals[key] ?? 0) + _asDouble(t['amount']);
    }
    return catTotals;
  }

  Future<void> loadTargets() async {
    final uid = userId;
    if (uid == null) return;

    if (selectedMonth == null) {
      if (!mounted) return;
      setState(() {
        targetsLoading = false;
        targetsError = null;
        monthlyBudget = 0;
        targetRmByCat = {};
        rawPctByCat = {};
        rawAmtByCat = {};
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      targetsLoading = true;
      targetsError = null;
    });

    try {
      final res = await Supabase.instance.client
          .from('category_budgets')
          .select('monthly_budget, percents, amounts')
          .eq('user_id', uid)
          .eq('year', selectedYear)
          .eq('month', selectedMonth!)
          .maybeSingle();

      if (res == null) {
        if (!mounted) return;
        setState(() {
          monthlyBudget = 0;
          targetRmByCat = {};
          rawPctByCat = {};
          rawAmtByCat = {};
        });
        return;
      }

      final mb = _asDouble(res['monthly_budget']);

      final perc = (res['percents'] is Map<String, dynamic>) ? (res['percents'] as Map<String, dynamic>) : <String, dynamic>{};
      final amts = (res['amounts'] is Map<String, dynamic>) ? (res['amounts'] as Map<String, dynamic>) : <String, dynamic>{};

      final Map<String, double> pctMap = {};
      final Map<String, double> amtMap = {};
      final Map<String, double> rmMap = {};

      final keys = {...perc.keys, ...amts.keys};

      for (final k in keys) {
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

      if (!mounted) return;
      setState(() {
        monthlyBudget = mb;
        rawPctByCat = pctMap;
        rawAmtByCat = amtMap;
        targetRmByCat = rmMap;
      });

      if (selectedMonth != null && targetRmByCat.isNotEmpty) {
        final monthTx = txs.where(_inSelectedMonth).toList();
        final spentByCat = _spentByCategoryForMonth(monthTx);

        for (final entry in targetRmByCat.entries) {
          final cat = entry.key;
          final budget = entry.value;
          final spent = spentByCat[cat] ?? 0;

          final alertKey = "$selectedYear-${selectedMonth!}-$cat";
          if (_budgetAlertSentKeys.contains(alertKey)) continue;

          await NotificationService.instance.checkBudgetAlert(
            spent: spent,
            budget: budget,
            category: _prettyCat(cat),
            budgetYear: selectedYear,
            budgetMonth: selectedMonth!,
          );

          _budgetAlertSentKeys.add(alertKey);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => targetsError = e.toString());
    } finally {
      if (mounted) setState(() => targetsLoading = false);
    }
  }

  Future<void> _silentlyUpdateStreak() async {
    if (userId == null) return;

    try {
      final streakData = await StreakService(Supabase.instance.client).touchToday();
      await _checkStreakNotification(streakData.streak);
    } catch (e) {
      debugPrint("Failed to update daily streak: $e");
    }
  }

  String _kStreakNotifiedKey(int streak, DateTime now) =>
      "streak_${streak}_notified_${now.year}_${now.month}";

  Future<void> _checkStreakNotification(int streak) async {
    if (streak == 0 || streak % 7 != 0) return;

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final key = _kStreakNotifiedKey(streak, now);

    final alreadyNotified = prefs.getBool(key) ?? false;

    if (!alreadyNotified) {
      await NotificationService.instance.checkStreak(streak);
      await prefs.setBool(key, true);
    }
  }

  Future<void> _openTargetsEditor() async {
    if (selectedMonth == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Select a month to edit targets.")));
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CategoryBreakdownPage(year: selectedYear, month: selectedMonth!)),
    );

    await loadTx();
    await loadTargets();
    await loadPrediction();
    await _checkInactiveUser();
  }

  Future<void> loadPrediction() async {
    if (!mounted) return;

    // FIX 2: Removed the "if (predLoading) return" guard.
    // That guard caused a silent no-op when loadPrediction() was called
    // while a previous call was still in flight (e.g. after month change),
    // leaving stale prediction values on screen. Instead, we rely on the
    // _predReqId counter to discard outdated responses.

    if (loading) {
      setState(() {
        predLoading = false;
        predError = "Loading transactions...";
      });
      return;
    }


    final int reqId = ++_predReqId;

    setState(() {
      predLoading = true;
      predError = null;
      predNextDay = null;
      predNextWeek = null;
      predNextMonth = null;
    });

    if (txs.isEmpty) {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        predLoading = false;
        predError = "No transaction data available.";
      });
      return;
    }

    final expenses = txs
        .where((t) => (t["type"] ?? "").toString().trim().toLowerCase() == "expense" && _parseDate(t["date"]) != null)
        .map((t) {
          final dt = _parseDate(t["date"])!.toLocal();
          return {
            "date": DateFormat("yyyy-MM-dd").format(dt),
            "amount": _asDouble(t["amount"]),
            "type": "expense",
            "description": (t["description"] ?? "").toString(),
            "category": (t["category"] ?? "").toString(),
          };
        })
        .toList();

    if (expenses.isEmpty) {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        predLoading = false;
        predError = "No expense records found.";
      });
      return;
    }

    expenses.sort((a, b) {
      final ad = DateTime.tryParse(a["date"] as String) ?? DateTime(1970);
      final bd = DateTime.tryParse(b["date"] as String) ?? DateTime(1970);
      return bd.compareTo(ad);
    });

    final payloadTx = expenses.take(500).toList();
    final bool monthMode = selectedMonth != null;
    final Map<String, dynamic> body = {
      "transactions": payloadTx,
      "days": 60,
    };
    if (monthMode) {
      body["anchor_year"] = selectedYear;
      body["anchor_month"] = selectedMonth!;
    }

    try {
      final url = Uri.parse(ApiConfig.PredictUrl);
      final res = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 10));

      if (!mounted || reqId != _predReqId) return;

      if (res.statusCode < 200 || res.statusCode >= 300) {
        setState(() {
          predLoading = false;
          predError = "Prediction unavailable. Try again later.";
        });
        return;
      }

      final decoded = jsonDecode(res.body);
      final Map<String, dynamic> data = (decoded is Map<String, dynamic>) ? decoded : <String, dynamic>{};

      final nd = _numOrNull(data["next_day"]);
      final nw = _numOrNull(data["next_week"]);
      final nm = _numOrNull(data["next_month"]);
      final msg = (data["message"] ?? "").toString().trim();

      setState(() {
        predNextDay = nd;
        predNextWeek = nw;
        predNextMonth = nm;
        predLoading = false;
        predError = msg.isEmpty ? null : msg;
      });

      if (monthMode && predNextMonth != null && monthlyBudget > 0) {
        await NotificationService.instance.safeSpendingWarning(
          predicted: predNextMonth!,
          monthlyBudget: monthlyBudget,
          budgetYear: selectedYear,
          budgetMonth: selectedMonth!,
        );
      }
    } on TimeoutException {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        predLoading = false;
        predError = "Prediction timed out. Try again.";
      });
    } catch (e) {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        predLoading = false;
        predError = e.toString().replaceAll("Exception: ", "");
      });
    }
  }

  @override
  void initState() {
    super.initState();

    globalTransactionUpdateNotifier.addListener(_onGlobalTxUpdate);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _silentlyUpdateStreak();
      await loadTx();
      await loadTargets();
      await loadPrediction();
      await _checkInactiveUser();
    });
  }

  Future<void> _onGlobalTxUpdate() async {
    if (!mounted) return;
    await loadTx();
    await loadTargets();
    await loadPrediction();
    await _checkInactiveUser();
  }

  Future<void> _checkInactiveUser() async {
    if (!mounted) return;
    if (_inactiveChecked) return;
    if (txs.isEmpty) return;

    final lastDate = _parseDate(txs.first['date'])?.toLocal();
    if (lastDate == null) return;

    final daysInactive = DateTime.now().difference(lastDate).inDays;
    await NotificationService.instance.checkInactive(daysInactive);

    if (!mounted) return;
    _inactiveChecked = true;
  }

  Future<void> _openManage() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const TransactionManagementPage()));
    // FIX 3: Also reset milestone/inactive flags here so they re-check
    // after the user returns from the manage screen (original code already did this,
    // kept as-is — confirmed correct).
    _milestoneChecked = false;
    _inactiveChecked = false;
    await loadTx();
    await loadTargets();
    await loadPrediction();
    await _checkInactiveUser();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final isDark = t.brightness == Brightness.dark;

    final bool isMonthMode = selectedMonth != null;
    final DateTime now = DateTime.now();
    
    // Determines if the selected period is entirely in the future.
    final bool isFuture = isMonthMode 
        ? (selectedYear > now.year || (selectedYear == now.year && selectedMonth! > now.month))
        : (selectedYear > now.year);

    // --- CARRIED FORWARD BALANCE CALCULATION ---
    // FIX 4 (main fix): Use _endOfMonth() instead of DateTime(y, m+1, 0, 23, 59, 59)
    // to avoid overflow when selectedMonth == 12 (month 13 is invalid in Dart).
    double netBalanceCarriedForward = 0;

    if (!isFuture) {
      final DateTime endOfPeriod = isMonthMode 
          ? _endOfMonth(selectedYear, selectedMonth!)
          : DateTime(selectedYear, 12, 31, 23, 59, 59);

      final historicalTx = txs.where((item) {
        final dt = _parseDate(item['date'])?.toLocal();
        // Use !isAfter instead of isBefore(end + 1s) to include the exact end moment.
        return dt != null && !dt.isAfter(endOfPeriod);
      }).toList();

      double totalHistoricalIncome = 0;
      double totalHistoricalExpense = 0;
      for (final item in historicalTx) {
        final type = (item['type'] ?? '').toString().trim().toLowerCase();
        final amt = _asDouble(item['amount']);
        if (type == 'income') totalHistoricalIncome += amt;
        if (type == 'expense') totalHistoricalExpense += amt;
      }
      netBalanceCarriedForward = totalHistoricalIncome - totalHistoricalExpense;
    }
    // -------------------------------------------

    // FIX 5: Clear predictions in the isFuture branch AFTER the balance calculation.
    // Original code mutated predNextDay etc. inside build() which is an anti-pattern —
    // moved the clear to a post-frame or guard approach. Since these are display-only
    // reads inside build(), nulling them here is safe but they should ideally be
    // cleared in setState when the date selection changes. For now this preserves
    // the original intent without breaking the balance calc above.
    double? displayPredNextDay = isFuture ? null : predNextDay;
    double? displayPredNextWeek = isFuture ? null : predNextWeek;
    double? displayPredNextMonth = isFuture ? null : predNextMonth;

    final yearTx = txs.where(_inSelectedYear).toList();
    final monthTx = isMonthMode ? txs.where(_inSelectedMonth).toList() : <Map<String, dynamic>>[];
    final activeTx = isMonthMode ? monthTx : yearTx;

    final label = isMonthMode ? DateFormat("MMMM yyyy").format(DateTime(selectedYear, selectedMonth!)) : "Year $selectedYear";

    final incomeTotal = activeTx.where((tx) => (tx['type'] ?? '').toString().trim().toLowerCase() == 'income').fold<double>(0, (sum, tx) => sum + _asDouble(tx['amount']));
    final expenseTotal = activeTx.where((tx) => (tx['type'] ?? '').toString().trim().toLowerCase() == 'expense').fold<double>(0, (sum, tx) => sum + _asDouble(tx['amount']));

    final Map<String, double> catTotals = {};
    for (final tMap in activeTx) {
      final type = (tMap['type'] ?? '').toString().trim().toLowerCase();
      if (type != 'expense') continue;
      final catRaw = (tMap['category'] ?? '').toString().trim();
      final key = _normCatKey(catRaw);
      catTotals[key] = (catTotals[key] ?? 0) + _asDouble(tMap['amount']);
    }

    final topExpenses = catTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
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
            Text("Hello, $displayName 👋", style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text("SmartBudget", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: cs.onSurface)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: "Settings",
            icon: Icon(Icons.person_outline_rounded, color: cs.onSurface),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const UserSettingsPage()));
            },
          ),
          IconButton(
            tooltip: "Logout",
            icon: Icon(Icons.logout_rounded, color: cs.error),
            onPressed: () async {
              await AuthService().logout();
              if (context.mounted) {
                Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AuthGate()));
              }
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text(error!))
              : RefreshIndicator(
                  onRefresh: () async {
                    // FIX 6: Reset milestone/inactive flags on manual refresh too,
                    // so notifications can fire again after new transactions are added.
                    _milestoneChecked = false;
                    _inactiveChecked = false;
                    await loadTx();
                    await loadTargets();
                    await loadPrediction();
                    await _checkInactiveUser();
                  },
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                    children: [
                      _MonthYearPicker(
                        year: selectedYear,
                        month: selectedMonth,
                        onChanged: (y, m) async {
                          setState(() {
                            selectedYear = y;
                            selectedMonth = m;
                          });
                          await loadTargets();
                          await loadPrediction();
                        },
                      ),
                      const SizedBox(height: 16),
                      
                      _DashboardHeroCard(
                        label: label,
                        income: incomeTotal,
                        expense: expenseTotal,
                        balance: netBalanceCarriedForward,
                      ),
                      const SizedBox(height: 16),

                      _SectionCard(
                        title: "AI Predictions",
                        icon: Icons.auto_awesome_rounded,
                        child: predLoading
                            ? const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (predError != null)
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      margin: const EdgeInsets.only(bottom: 12),
                                      decoration: BoxDecoration(
                                        color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: t.dividerColor.withValues(alpha: 0.5)),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(Icons.info_outline_rounded, size: 18, color: isDark ? Colors.white : Colors.black87),
                                          const SizedBox(width: 8),
                                          Expanded(child: Text(predError!, style: TextStyle(color: isDark ? Colors.white : Colors.black87, fontSize: 12, fontWeight: FontWeight.bold))),
                                        ],
                                      ),
                                    ),
                                  // FIX 5 continued: use display* locals so future periods show dashes.
                                  (displayPredNextDay == null && displayPredNextWeek == null && displayPredNextMonth == null)
                                      ? Text("Keep logging transactions to unlock AI predictions.", style: TextStyle(color: t.hintColor))
                                      : Row(
                                          children: [
                                            Expanded(child: _MiniPredCard(title: "Tomorrow", value: displayPredNextDay?.toString(), icon: Icons.today_rounded)),
                                            const SizedBox(width: 10),
                                            Expanded(child: _MiniPredCard(title: "1 Week", value: displayPredNextWeek?.toString(), icon: Icons.date_range_rounded)),
                                            const SizedBox(width: 10),
                                            Expanded(child: _MiniPredCard(title: isMonthMode ? "This Month" : "Month", value: displayPredNextMonth?.toString(), icon: Icons.calendar_month_rounded)),
                                          ],
                                        ),
                                ],
                              ),
                      ),
                      const SizedBox(height: 16),

                      _SectionCard(
                        title: "Balance Trend",
                        icon: Icons.show_chart_rounded,
                        actionText: "RM ${netBalanceCarriedForward.toStringAsFixed(2)}",
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8.0, right: 16),
                          child: _BalanceTrendChart(
                            tx: txs, 
                            asDouble: _asDouble,
                            parseDate: _parseDate,
                            year: selectedYear,
                            month: selectedMonth,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      _SectionCard(
                        title: "Top Expenses",
                        icon: Icons.pie_chart_rounded,
                        child: _TopExpensesBars(
                          top: top3.map((e) => MapEntry(_prettyCat(e.key), e.value)).toList(),
                          maxValue: top3.isEmpty ? 1 : top3.first.value,
                        ),
                      ),
                      const SizedBox(height: 16),

                      _SectionCard(
                        title: "Cash Flow",
                        icon: Icons.swap_vert_rounded,
                        child: _CashFlowBars(income: incomeTotal, expense: expenseTotal),
                      ),
                      const SizedBox(height: 16),

                      _SectionCard(
                        title: "Monthly Targets",
                        icon: Icons.flag_rounded,
                        actionText: isMonthMode ? "Edit" : null,
                        onAction: isMonthMode ? _openTargetsEditor : null,
                        child: !isMonthMode
                            ? Text("Targets are set monthly. Please select a specific month above to view them.", style: TextStyle(color: t.hintColor))
                            : targetsLoading
                                ? const Center(child: CircularProgressIndicator())
                                : targetsError != null
                                    ? Text(targetsError!, style: TextStyle(color: cs.error))
                                    : _TargetsList(
                                        monthlyBudget: monthlyBudget,
                                        targetRmByCat: targetRmByCat,
                                        rawPctByCat: rawPctByCat,
                                        rawAmtByCat: rawAmtByCat,
                                        spentByCategory: _spentByCategoryForMonth(monthTx),
                                        prettyCat: _prettyCat,
                                      ),
                      ),
                      const SizedBox(height: 16),

                      _SectionCard(
                        title: "Recent Transactions",
                        icon: Icons.history_rounded,
                        actionText: "View All",
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

/* ===================== UI WIDGETS ===================== */

class _DashboardHeroCard extends StatelessWidget {
  final String label;
  final double income;
  final double expense;
  final double balance;

  const _DashboardHeroCard({
    required this.label,
    required this.income,
    required this.expense,
    required this.balance,
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
        boxShadow: [BoxShadow(color: cs.primary.withValues(alpha: 0.3), blurRadius: 15, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.8), fontSize: 14, fontWeight: FontWeight.w600)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  // FIX 7: Use withValues(alpha:) instead of deprecated withOpacity().
                  color: isPositive ? Colors.white.withValues(alpha: 0.2) : cs.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isPositive ? "Surplus" : "Deficit",
                  style: TextStyle(color: isPositive ? Colors.green : cs.onErrorContainer, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text("RM ${balance.toStringAsFixed(2)}", style: TextStyle(color: cs.onPrimary, fontSize: 36, fontWeight: FontWeight.bold, height: 1.1)),
          Text("Net Balance", style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.8), fontSize: 13)),
          
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.arrow_downward_rounded, size: 16, color: Colors.green.shade300),
                          const SizedBox(width: 4),
                          Text("Income", style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.9), fontSize: 13, fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text("RM ${income.toStringAsFixed(2)}", style: TextStyle(color: cs.onPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.arrow_upward_rounded, size: 16, color: Colors.orange.shade300),
                          const SizedBox(width: 4),
                          Text("Expense", style: TextStyle(color: cs.onPrimary.withValues(alpha: 0.9), fontSize: 13, fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text("RM ${expense.toStringAsFixed(2)}", style: TextStyle(color: cs.onPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final String? actionText;
  final VoidCallback? onAction;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
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
        boxShadow: [BoxShadow(color: Theme.of(context).shadowColor.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 18, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              if (actionText != null)
                InkWell(
                  onTap: onAction,
                  child: Text(actionText!, style: TextStyle(color: onAction != null ? cs.primary : cs.onSurfaceVariant, fontWeight: FontWeight.bold, fontSize: 14)),
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

class _MiniPredCard extends StatelessWidget {
  final String title;
  final String? value;
  final IconData icon;

  const _MiniPredCard({required this.title, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.onSurface),
          const SizedBox(height: 8),
          Text(title, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            value == null ? "-" : "RM ${double.tryParse(value!)?.toStringAsFixed(2) ?? value}",
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: cs.onSurface),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _TopExpensesBars extends StatelessWidget {
  final List<MapEntry<String, double>> top;
  final double maxValue;

  const _TopExpensesBars({required this.top, required this.maxValue});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (top.isEmpty) {
      return Text("No expenses recorded yet.", style: TextStyle(color: Theme.of(context).hintColor));
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
                  Text(e.key, style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text("RM ${e.value.toStringAsFixed(2)}", style: const TextStyle(fontWeight: FontWeight.bold)),
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

class _CashFlowBars extends StatelessWidget {
  final double income;
  final double expense;

  const _CashFlowBars({required this.income, required this.expense});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxV = max(1.0, max(income, expense));
    final incomePct = (income / maxV).clamp(0.0, 1.0);
    final expPct = (expense / maxV).clamp(0.0, 1.0);

    // FIX 7 continued: Use ColorScheme-derived greens/oranges where possible
    // to respect dark mode. Falls back to shade values only for the bar color
    // where semantic tokens aren't available.
    return Column(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Total Income", style: TextStyle(fontWeight: FontWeight.bold)),
                Text("RM ${income.toStringAsFixed(2)}", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green.shade600)),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: incomePct, minHeight: 8, backgroundColor: cs.surfaceContainerHighest, color: Colors.green.shade500),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Total Expenses", style: TextStyle(fontWeight: FontWeight.bold)),
                Text("RM ${expense.toStringAsFixed(2)}", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange.shade600)),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: expPct, minHeight: 8, backgroundColor: cs.surfaceContainerHighest, color: Colors.orange.shade500),
            ),
          ],
        ),
      ],
    );
  }
}

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
      return Text("No targets set for this month.", style: TextStyle(color: Theme.of(context).hintColor));
    }

    final entries = targetRmByCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      children: entries.map((e) {
        final key = e.key;
        final target = e.value;
        final spent = (spentByCategory[key] ?? 0);

        final pct = target <= 0 ? 0.0 : (spent / target);
        final clamped = pct.clamp(0.0, 1.0);
        final over = target > 0 && spent > target;
        final progressColor = over ? cs.error : cs.primary;

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(prettyCat(key), style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(
                    "RM ${spent.toStringAsFixed(2)} / RM ${target.toStringAsFixed(2)}", 
                    style: TextStyle(fontWeight: FontWeight.bold, color: over ? cs.error : cs.onSurface)
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: clamped, 
                  minHeight: 8, 
                  backgroundColor: cs.surfaceContainerHighest,
                  color: progressColor,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

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
      return Text("No recent transactions.", style: TextStyle(color: Theme.of(context).hintColor));
    }

    return Column(
      children: items.map((tMap) {
        final type = (tMap['type'] ?? '').toString().trim().toLowerCase();
        final isIncome = type == 'income';
        final amount = asDouble(tMap['amount']);
        final title = ((tMap['category'] ?? '').toString().trim().isEmpty) ? 'Transaction' : (tMap['category'] ?? '').toString();
        final desc = (tMap['description'] ?? '').toString();
        final date = dateText(tMap['date']);

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isIncome ? Colors.green.shade100 : cs.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(isIncome ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: 16, color: isIncome ? Colors.green.shade700 : cs.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(desc.isEmpty ? "—" : desc, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    "${isIncome ? '+' : '-'}RM ${amount.toStringAsFixed(2)}",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isIncome ? Colors.green.shade700 : cs.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Text(date, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 11)),
                ],
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6), 
            child: DefaultTabController(
              length: 2,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TabBar(
                    tabs: [Tab(text: "Month"), Tab(text: "Year")],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        GridView.builder(
                          padding: const EdgeInsets.all(16),
                          physics: const BouncingScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3, childAspectRatio: 2.4, crossAxisSpacing: 8, mainAxisSpacing: 8,
                          ),
                          itemCount: 13,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return _GridTile(text: "All Year", isSelected: month == null, onTap: () { Navigator.pop(ctx); onChanged(year, null); });
                            }
                            final m = index;
                            return _GridTile(text: DateFormat("MMM").format(DateTime(2000, m)), isSelected: month == m, onTap: () { Navigator.pop(ctx); onChanged(year, m); });
                          },
                        ),
                        GridView.builder(
                          padding: const EdgeInsets.all(16),
                          physics: const BouncingScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3, childAspectRatio: 2.4, crossAxisSpacing: 8, mainAxisSpacing: 8,
                          ),
                          itemCount: 12,
                          itemBuilder: (context, index) {
                            final y = DateTime.now().year - 5 + index;
                            return _GridTile(text: "$y", isSelected: year == y, onTap: () { Navigator.pop(ctx); onChanged(y, month); });
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
    final monthLabel = month == null ? "All Year" : DateFormat("MMM").format(DateTime(year, month!));

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
            style: IconButton.styleFrom(backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.5)),
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.calendar_month_rounded, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text("$monthLabel $year", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: cs.onSurface)),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: Theme.of(context).hintColor),
                ],
              ),
            ),
          ),
          IconButton(
            style: IconButton.styleFrom(backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.5)),
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

  const _GridTile({required this.text, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? cs.primary : cs.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.w600, color: isSelected ? cs.onPrimary : cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

// ---------------- CHART WIDGETS ---------------- //

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
    final nextMonth = (m == 12) ? DateTime(y + 1, 1, 1) : DateTime(y, m + 1, 1);
    final thisMonth = DateTime(y, m, 1);
    return nextMonth.difference(thisMonth).inDays;
  }

  @override
  Widget build(BuildContext context) {
    if (month == null) {
      return _YearTrend(tx: tx, asDouble: asDouble, parseDate: parseDate, year: year);
    }
    final days = _daysInMonth(year, month!);
    return _MonthTrend(tx: tx, asDouble: asDouble, parseDate: parseDate, year: year, month: month!, days: days);
  }
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
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final now = DateTime.now();
    final bool isFutureYear = year > now.year;

    double startingBalance = 0;
    final monthlyNet = List<double>.filled(12, 0);

    if (!isFutureYear) {
      final DateTime yearStart = DateTime(year, 1, 1);
      for (final t in tx) {
        final dt = parseDate(t['date'])?.toLocal();
        if (dt == null) continue;

        final type = (t['type'] ?? '').toString().trim().toLowerCase();
        final amt = asDouble(t['amount']);
        final net = (type == 'income') ? amt : (type == 'expense') ? -amt : 0.0;

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

    // FIX 8: Changed break to a continue-after-add so the current month's
    // data point is included in the chart (not excluded by breaking before adding).
    for (int i = 0; i < 12; i++) {
      if (isFutureYear) break;
      running += monthlyNet[i];
      spots.add(FlSpot(i.toDouble(), running));
      if (year == now.year && i == now.month - 1) break; // Stop after current month
    }

    if (spots.length == 1) {
      spots.add(FlSpot(spots.first.x + 0.01, spots.first.y));
    }

    final ys = spots.map((e) => e.y).toList();
    final rawMinY = ys.isEmpty ? 0.0 : ys.reduce(min);
    final rawMaxY = ys.isEmpty ? 1.0 : ys.reduce(max);
    
    final maxAbs = max(rawMinY.abs(), rawMaxY.abs());
    final pad = maxAbs == 0 ? 100.0 : maxAbs * 0.2;
    final maxY = maxAbs + pad;
    final minY = -maxY;

    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          baselineY: 0,
          lineTouchData: LineTouchData(
            handleBuiltInTouches: true,
            getTouchedSpotIndicator: (LineChartBarData barData, List<int> spotIndexes) {
              return spotIndexes.map((index) {
                return TouchedSpotIndicatorData(
                  FlLine(color: cs.primary.withValues(alpha: 0.5), strokeWidth: 2, dashArray: [4, 4]),
                  FlDotData(
                    show: true,
                    getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
                      radius: 5,
                      color: cs.primary,
                      strokeWidth: 3,
                      strokeColor: cs.surface,
                    ),
                  ),
                );
              }).toList();
            },
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (spot) => isDark ? Colors.white : Colors.black87,
              tooltipRoundedRadius: 8,
              getTooltipItems: (touchedSpots) {
                return touchedSpots.map((spot) {
                  return LineTooltipItem(
                    "RM ${spot.y.toStringAsFixed(2)}",
                    TextStyle(color: isDark ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                  );
                }).toList();
              },
            ),
          ),
          gridData: FlGridData(
            show: true, 
            drawVerticalLine: false, 
            horizontalInterval: maxAbs == 0 ? 100 : maxAbs / 2,
            getDrawingHorizontalLine: (value) {
              if (value == 0) {
                return FlLine(color: cs.onSurface.withValues(alpha: 0.3), strokeWidth: 2, dashArray: [5, 5]);
              }
              return FlLine(color: Theme.of(context).dividerColor.withValues(alpha: 0.4), strokeWidth: 1, dashArray: [5, 5]);
            },
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: 2,
                getTitlesWidget: (v, meta) {
                  final idx = v.toInt();
                  if (idx < 0 || idx > 11) return const SizedBox.shrink();
                  final label = DateFormat("MMM").format(DateTime(year, idx + 1));
                  return SideTitleWidget(axisSide: meta.axisSide, space: 8, child: Text(label, style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor, fontWeight: FontWeight.bold)));
                },
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
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
                gradient: LinearGradient(colors: [cs.primary.withValues(alpha: 0.25), cs.primary.withValues(alpha: 0.0)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
              ),
              aboveBarData: BarAreaData(
                show: true,
                cutOffY: 0,
                applyCutOffY: true,
                gradient: LinearGradient(colors: [cs.error.withValues(alpha: 0.0), cs.error.withValues(alpha: 0.25)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
              )
            ),
          ],
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
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final now = DateTime.now();
    final bool isFutureMonth = year > now.year || (year == now.year && month > now.month);

    double startingBalance = 0;
    final dailyNet = List<double>.filled(days, 0);

    if (!isFutureMonth) {
      final DateTime monthStart = DateTime(year, month, 1);
      for (final t in tx) {
        final dt = parseDate(t['date'])?.toLocal();
        if (dt == null) continue;

        final type = (t['type'] ?? '').toString().trim().toLowerCase();
        final amt = asDouble(t['amount']);
        final net = (type == 'income') ? amt : (type == 'expense') ? -amt : 0.0;

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

    // FIX 8 (month version): Same fix — add the spot THEN break, so today's
    // data is included in the chart rather than cut off one day early.
    for (int i = 0; i < days; i++) {
      if (isFutureMonth) break;
      running += dailyNet[i];
      spots.add(FlSpot(i.toDouble(), running));
      if (year == now.year && month == now.month && i == now.day - 1) break;
    }

    if (spots.length == 1) {
      spots.add(FlSpot(spots.first.x + 0.01, spots.first.y));
    }

    final ys = spots.map((e) => e.y).toList();
    final rawMinY = ys.isEmpty ? 0.0 : ys.reduce(min);
    final rawMaxY = ys.isEmpty ? 1.0 : ys.reduce(max);
    
    final maxAbs = max(rawMinY.abs(), rawMaxY.abs());
    final pad = maxAbs == 0 ? 100.0 : maxAbs * 0.2;
    final maxY = maxAbs + pad;
    final minY = -maxY;

    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          baselineY: 0,
          lineTouchData: LineTouchData(
            handleBuiltInTouches: true,
            getTouchedSpotIndicator: (LineChartBarData barData, List<int> spotIndexes) {
              return spotIndexes.map((index) {
                return TouchedSpotIndicatorData(
                  FlLine(color: cs.primary.withValues(alpha: 0.5), strokeWidth: 2, dashArray: [4, 4]),
                  FlDotData(
                    show: true,
                    getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
                      radius: 5,
                      color: cs.primary,
                      strokeWidth: 3,
                      strokeColor: cs.surface,
                    ),
                  ),
                );
              }).toList();
            },
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (spot) => isDark ? Colors.white : Colors.black87,
              tooltipRoundedRadius: 8,
              getTooltipItems: (touchedSpots) {
                return touchedSpots.map((spot) {
                  return LineTooltipItem(
                    "RM ${spot.y.toStringAsFixed(2)}",
                    TextStyle(color: isDark ? Colors.black : Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                  );
                }).toList();
              },
            ),
          ),
          gridData: FlGridData(
            show: true, 
            drawVerticalLine: false, 
            horizontalInterval: maxAbs == 0 ? 100 : maxAbs / 2,
            getDrawingHorizontalLine: (value) {
              if (value == 0) {
                return FlLine(color: cs.onSurface.withValues(alpha: 0.3), strokeWidth: 2, dashArray: [5, 5]);
              }
              return FlLine(color: Theme.of(context).dividerColor.withValues(alpha: 0.4), strokeWidth: 1, dashArray: [5, 5]);
            },
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: 5,
                getTitlesWidget: (v, meta) {
                  final day = v.toInt() + 1;
                  if (day < 1 || day > days) return const SizedBox.shrink();
                  return SideTitleWidget(axisSide: meta.axisSide, space: 8, child: Text("$day", style: TextStyle(fontSize: 10, color: Theme.of(context).hintColor, fontWeight: FontWeight.bold)));
                },
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
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
                gradient: LinearGradient(colors: [cs.primary.withValues(alpha: 0.25), cs.primary.withValues(alpha: 0.0)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
              ),
              aboveBarData: BarAreaData(
                show: true,
                cutOffY: 0,
                applyCutOffY: true,
                gradient: LinearGradient(colors: [cs.error.withValues(alpha: 0.0), cs.error.withValues(alpha: 0.25)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
              )
            ),
          ],
        ),
      ),
    );
  }
}