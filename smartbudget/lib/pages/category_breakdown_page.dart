import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CategoryBreakdownPage extends StatefulWidget {
  final int year;
  final int? month; // ✅ nullable to support "All Year"

  const CategoryBreakdownPage({
    super.key,
    required this.year,
    required this.month,
  });

  @override
  State<CategoryBreakdownPage> createState() => _CategoryBreakdownPageState();
}

class _CategoryBreakdownPageState extends State<CategoryBreakdownPage> {
  static const List<String> kCategories = [
    "food",
    "transport",
    "shopping",
    "bills",
    "entertainment",
    "healthcare",
    "education",
    "banking",
    "personal_care",
    "pets",
    "home",
    "income",
    "other",
  ];

  static const Set<String> kNeedsCats = {
    "food",
    "transport",
    "bills",
    "healthcare",
    "education",
    "banking",
    "personal_care",
    "pets",
    "home",
  };

  static const List<Color> kPiePalette = [
    Color(0xFF4F46E5),
    Color(0xFF06B6D4),
    Color(0xFF22C55E),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFFA855F7),
    Color(0xFF3B82F6),
    Color(0xFF14B8A6),
    Color(0xFFF97316),
    Color(0xFF84CC16),
    Color(0xFFEC4899),
    Color(0xFF64748B),
  ];

  bool loading = true;
  bool saving = false;
  String? error;

  bool isEditing = true;

  late int selectedYear;
  late int? selectedMonth;

  List<Map<String, dynamic>> txs = [];

  double monthlyBudget = 0;

  Map<String, double> categoryPct = {};
  Map<String, double> categoryAmt = {};

  bool usingDefaultFromNeeds = true;
  final budgetCtrl = TextEditingController();

  // pie tap state
  int? _touchedIndex;
  String? _touchedCat;
  double _touchedValue = 0;
  double _touchedPct = 0;

  String? get userId => Supabase.instance.client.auth.currentUser?.id;

  final _rm = NumberFormat.currency(locale: "en_MY", symbol: "RM ");

  // ---------------- helpers ----------------
  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  String _money(double v) => _rm.format(v);

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  bool _inSelectedMonth(Map<String, dynamic> t) {
    final dt = _parseDate(t['date'])?.toLocal();
    if (dt == null) return false;
    if (selectedMonth == null) return dt.year == selectedYear; // ✅ All Year
    return dt.year == selectedYear && dt.month == selectedMonth;
  }

  String _normCat(dynamic raw) {
    final s = (raw ?? "").toString().trim().toLowerCase();
    if (s.isEmpty) return "other";
    if (kCategories.contains(s)) return s;
    return "other";
  }

  String _pretty(String cat) {
    final parts = cat.split('_');
    return parts
        .map((p) => p.isEmpty ? p : (p[0].toUpperCase() + p.substring(1)))
        .join(' ');
  }

  Color _colorForCat(String cat) {
    final list = kCategories.where((c) => c != "income").toList();
    final idx = list.indexOf(cat);
    if (idx < 0) return kPiePalette.last;
    return kPiePalette[idx % kPiePalette.length];
  }

  void _ensureDefaultsIfEmpty() {
    for (final c in kCategories) {
      if (c == "income") continue;
      categoryPct[c] = (categoryPct[c] ?? 0);
      categoryAmt[c] = (categoryAmt[c] ?? 0);
    }
  }

  double _pctSum() {
    double s = 0;
    for (final c in kCategories) {
      if (c == "income") continue;
      final amt = categoryAmt[c] ?? 0;
      if (amt > 0) continue; // RM overrides %
      s += (categoryPct[c] ?? 0);
    }
    return s;
  }

  double _maxAllowedForPct(String cat) {
    final catAmt = categoryAmt[cat] ?? 0;
    if (catAmt > 0) return 0;

    double others = 0;
    for (final c in kCategories) {
      if (c == "income" || c == cat) continue;
      final amt = categoryAmt[c] ?? 0;
      if (amt > 0) continue;
      others += (categoryPct[c] ?? 0);
    }
    final maxVal = 100 - others;
    return max(0, min(100, maxVal));
  }

  double _targetForCat(String cat) {
    final a = categoryAmt[cat] ?? 0;
    if (a > 0) return a;
    final p = categoryPct[cat] ?? 0;
    return monthlyBudget * (p / 100);
  }

  double _totalTargetsRm() {
    double s = 0;
    for (final c in kCategories) {
      if (c == "income") continue;
      s += _targetForCat(c);
    }
    return s;
  }

  double _maxAllowedForAmt(String cat) {
    if (monthlyBudget <= 0) return double.infinity;

    double others = 0;
    for (final c in kCategories) {
      if (c == "income" || c == cat) continue;
      others += _targetForCat(c);
    }

    final maxVal = monthlyBudget - others;
    return max(0, maxVal);
  }

  void _setPctCapped(String cat, double newVal) {
    categoryAmt[cat] = 0;
    final capped = min(newVal.clamp(0, 100), _maxAllowedForPct(cat));
    setState(() => categoryPct[cat] = capped.toDouble());
  }

  void _setAmt(String cat, double newAmt) {
    var amt = max(0, newAmt).toDouble();
    final cap = _maxAllowedForAmt(cat);
    if (cap.isFinite) amt = min(amt, cap);

    setState(() {
      categoryAmt[cat] = amt;
      if (amt > 0) categoryPct[cat] = 0;
    });
  }

  String _monthKey() {
    if (selectedMonth == null) return "${selectedYear}-all";
    return DateTime(selectedYear, selectedMonth!, 1).toIso8601String().substring(0, 10);
  }

  double _totalIncomeForSelectedMonth() {
    return txs
        .where(_inSelectedMonth)
        .where((t) => (t['type'] ?? '').toString().toLowerCase() == 'income')
        .fold<double>(0, (sum, t) => sum + _asDouble(t['amount']));
  }

  double _needsDefaultFromIncome() => _totalIncomeForSelectedMonth() * 0.50;

  Future<double> _fallbackNeedsFromBudgets(String uid) async {
    if (selectedMonth == null) return 0;
    try {
      final directNeeds = await Supabase.instance.client
          .from('budgets')
          .select('amount')
          .eq('user_id', uid)
          .ilike('category', 'needs')
          .eq('month', _monthKey())
          .maybeSingle();

      if (directNeeds != null) {
        final v = _asDouble(directNeeds['amount']);
        if (v > 0) return v;
      }

      final rows = await Supabase.instance.client
          .from('budgets')
          .select('category, amount')
          .eq('user_id', uid)
          .eq('month', _monthKey());

      final list = List<Map<String, dynamic>>.from(rows);
      double sum = 0;
      for (final b in list) {
        final c = (b['category'] ?? '').toString().trim().toLowerCase();
        if (kNeedsCats.contains(c)) sum += _asDouble(b['amount']);
      }
      return sum;
    } catch (_) {
      return 0;
    }
  }

  void _resetAllTargetsToZero() {
    for (final c in kCategories) {
      if (c == "income") continue;
      categoryPct[c] = 0;
      categoryAmt[c] = 0;
    }
  }

  Future<void> _applyNeedsDefault({required bool showSnack}) async {
    final uid = userId;
    if (uid == null || selectedMonth == null) return;

    final needsFromIncome = _needsDefaultFromIncome();
    double needs = needsFromIncome;

    if (needs <= 0) {
      needs = await _fallbackNeedsFromBudgets(uid);
    }

    if (!mounted) return;

    if (needs <= 0) {
      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No income/budget found for this month. Add income first.")),
        );
      }
      setState(() {
        usingDefaultFromNeeds = true;
        monthlyBudget = 0;
        budgetCtrl.text = "";
        _resetAllTargetsToZero();
        isEditing = true;
      });
      return;
    }

    setState(() {
      usingDefaultFromNeeds = true;
      monthlyBudget = needs;
      budgetCtrl.text = monthlyBudget.toStringAsFixed(2);
      _resetAllTargetsToZero();
      isEditing = true;
    });

    if (showSnack) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Needs applied ✅ Budget set & targets reset")),
      );
    }
  }

  void _clearPieSelection() {
    _touchedIndex = null;
    _touchedCat = null;
    _touchedValue = 0;
    _touchedPct = 0;
  }

  // ---------------- Supabase load/save ----------------
  Future<void> loadAll({bool keepEditingState = false}) async {
    final uid = userId;
    if (uid == null) {
      setState(() {
        loading = false;
        error = "Session expired. Please login again.";
      });
      return;
    }

    setState(() {
      loading = true;
      error = null;
    });

    try {
      final res = await Supabase.instance.client
          .from('transactions')
          .select('id, amount, type, category, description, date')
          .eq('user_id', uid)
          .order('date', ascending: false);

      txs = List<Map<String, dynamic>>.from(res);

      if (selectedMonth != null) {
        final budRes = await Supabase.instance.client
            .from('category_budgets')
            .select('monthly_budget, percents, amounts')
            .eq('user_id', uid)
            .eq('year', selectedYear)
            .eq('month', selectedMonth!)
            .maybeSingle();

        if (budRes != null) {
          usingDefaultFromNeeds = false;

          monthlyBudget = _asDouble(budRes['monthly_budget']);
          budgetCtrl.text = monthlyBudget <= 0 ? "" : monthlyBudget.toStringAsFixed(2);

          final rawP = budRes['percents'];
          final Map<String, dynamic> pm = (rawP is Map<String, dynamic>) ? rawP : <String, dynamic>{};

          final rawA = budRes['amounts'];
          final Map<String, dynamic> am = (rawA is Map<String, dynamic>) ? rawA : <String, dynamic>{};

          categoryPct = {};
          categoryAmt = {};
          for (final c in kCategories) {
            if (c == "income") continue;
            categoryPct[c] = _asDouble(pm[c]);
            categoryAmt[c] = _asDouble(am[c]);
            if ((categoryAmt[c] ?? 0) > 0) categoryPct[c] = 0;
          }

          _ensureDefaultsIfEmpty();
          if (!keepEditingState) isEditing = false;
        } else {
          usingDefaultFromNeeds = true;

          categoryPct = {};
          categoryAmt = {};
          _ensureDefaultsIfEmpty();

          await _applyNeedsDefault(showSnack: false);
          if (!keepEditingState) isEditing = true;
        }
      } else {
        // ✅ All Year
        usingDefaultFromNeeds = false;
        monthlyBudget = 0;
        categoryPct = {};
        categoryAmt = {};
        isEditing = false;
        _ensureDefaultsIfEmpty();
      }

      _clearPieSelection();
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> saveTargets() async {
      final uid = userId;
      if (uid == null || selectedMonth == null) {
        setState(() => error = "Session expired or invalid mode.");
        return;
      }

      final sumPct = _pctSum();
      if (sumPct > 100.0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Total % cannot exceed 100%. Current: ${sumPct.toStringAsFixed(2)}%")),
        );
        return;
      }

      if (monthlyBudget <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Monthly budget must be greater than 0.")),
        );
        return;
      }

      final totalTargets = _totalTargetsRm();
      if (totalTargets > monthlyBudget + 0.01) {
        final over = (totalTargets - monthlyBudget).clamp(0, 999999999.0);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Targets exceed Monthly Budget by RM ${over.toStringAsFixed(2)}. Reduce targets.")),
        );
        return;
      }

      setState(() {
        saving = true;
        error = null;
      });

      try {
        final filteredPct = <String, double>{};
        final filteredAmt = <String, double>{};

        for (final c in kCategories) {
          if (c == "income") continue;
          final a = categoryAmt[c] ?? 0;
          final p = categoryPct[c] ?? 0;

          if (a > 0) {
            filteredAmt[c] = a;
          } else if (p > 0) {
            filteredPct[c] = p;
          }
        }

        final payload = <String, dynamic>{
          "user_id": uid,
          "year": selectedYear,
          "month": selectedMonth,
          "monthly_budget": monthlyBudget,
          "percents": filteredPct,
          "amounts": filteredAmt,
          "updated_at": DateTime.now().toUtc().toIso8601String(),
        };

        await Supabase.instance.client.from('category_budgets').upsert(
              payload,
              onConflict: 'user_id,year,month',
            );

        if (!mounted) return;

        setState(() {
          usingDefaultFromNeeds = false;
          isEditing = false;

          for (final c in kCategories) {
            if (c == "income") continue;
            categoryPct[c] = filteredPct[c] ?? 0;
            categoryAmt[c] = filteredAmt[c] ?? 0;
          }

          _clearPieSelection();
        });

        // ✅ FIXED: Accurately calculates remaining percentage based on RM and shows as float
        final unassignedRm = monthlyBudget - totalTargets;
        final remainingPct = monthlyBudget > 0 
            ? ((unassignedRm / monthlyBudget) * 100).clamp(0, 100).toDouble() 
            : 0.0;
            
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Saved ✅ Remaining unassigned: ${remainingPct.toStringAsFixed(2)}%")),
        );
      } catch (e) {
        setState(() => error = e.toString());
      } finally {
        if (mounted) setState(() => saving = false);
      }
    }

  Future<void> useNeedsDefault() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await _applyNeedsDefault(showSnack: true);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _toggleEdit() {
    setState(() {
      isEditing = !isEditing;
      _clearPieSelection();
    });
  }

  @override
  void initState() {
    super.initState();
    selectedYear = widget.year;
    selectedMonth = widget.month;
    loadAll();
  }

  @override
  void dispose() {
    budgetCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _ensureDefaultsIfEmpty();

    final t = Theme.of(context);
    final cs = t.colorScheme;

    final monthExpenses = txs
        .where(_inSelectedMonth)
        .where((t) => (t['type'] ?? '').toString().toLowerCase() == 'expense')
        .toList();

    final Map<String, double> totals = {};
    for (final tx in monthExpenses) {
      final cat = _normCat(tx['category']);
      if (cat == "income") continue;
      totals[cat] = (totals[cat] ?? 0) + _asDouble(tx['amount']);
    }
    totals.removeWhere((k, v) => v <= 0);

    final entries = totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final totalSpent = entries.fold<double>(0, (s, e) => s + e.value);

    final income = _totalIncomeForSelectedMonth();

    final allCats = kCategories.where((c) => c != "income").toList();
    final visibleCats = isEditing
        ? allCats
        : allCats.where((c) => (categoryPct[c] ?? 0) > 0 || (categoryAmt[c] ?? 0) > 0).toList();

    final assignedRm = _totalTargetsRm();

    final unassignedRm = monthlyBudget - assignedRm;
    final overAssignedRm = max(0.0, assignedRm - monthlyBudget);

    final remainingPct = monthlyBudget > 0
        ? ((unassignedRm / monthlyBudget) * 100).clamp(0, 100).toDouble()
        : 0.0;

    final canSave = !saving && monthlyBudget > 0 && isEditing && assignedRm <= monthlyBudget + 0.01;

    InputDecoration themedInput({
      required String labelText,
      String? helperText,
      IconData? prefixIcon,
    }) {
      return InputDecoration(
        labelText: labelText,
        helperText: helperText,
        helperMaxLines: 2,
        prefixIcon: prefixIcon == null ? null : Icon(prefixIcon),
        filled: true,
        fillColor: cs.surfaceContainerHighest.withOpacity(0.35),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: cs.primary, width: 2),
        ),
      );
    }

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text("Category Breakdown", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      bottomNavigationBar: (!loading && selectedMonth != null)
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surface,
                  boxShadow: [
                    BoxShadow(
                      color: t.shadowColor.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, -5),
                    )
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: saving ? null : _toggleEdit,
                        icon: Icon(isEditing ? Icons.visibility_rounded : Icons.edit_rounded, size: 20),
                        label: Text(isEditing ? "Preview" : "Edit Targets"),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: canSave ? saveTargets : null,
                        icon: saving
                            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.save_rounded, size: 20),
                        label: Text(saving ? "Saving..." : "Save Targets"),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline_rounded, size: 64, color: cs.error),
                        const SizedBox(height: 16),
                        Text(
                          "Something went wrong",
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: cs.error),
                        ),
                        const SizedBox(height: 8),
                        Text(error!, textAlign: TextAlign.center, style: TextStyle(color: t.hintColor)),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: () => loadAll(keepEditingState: true),
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text("Retry"),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () => loadAll(keepEditingState: true),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      _MonthYearPickerBar(
                        year: selectedYear,
                        month: selectedMonth,
                        enabled: !saving,
                        onChanged: (y, m) async {
                          if (!mounted) return;
                          setState(() {
                            selectedYear = y;
                            selectedMonth = m;
                          });
                          await loadAll(keepEditingState: true);
                        },
                      ),
                      const SizedBox(height: 24),

                      _BudgetDashboardHero(
                        monthlyBudget: monthlyBudget,
                        totalSpent: totalSpent,
                        assignedRm: assignedRm,
                        income: income,
                        isEditing: isEditing,
                        isAllYear: selectedMonth == null,
                      ),
                      const SizedBox(height: 24),

                      if (isEditing && selectedMonth != null) ...[
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: cs.surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: t.dividerColor.withOpacity(0.5)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Budget Setup",
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: cs.onSurface),
                              ),
                              const SizedBox(height: 16),
                              TextField(
                                controller: budgetCtrl,
                                enabled: isEditing && !saving,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}$'))
                                ],
                                decoration: themedInput(
                                  labelText: "Monthly budget",
                                  prefixIcon: Icons.account_balance_wallet_outlined,
                                ).copyWith(prefixText: "RM "),
                                onChanged: (v) {
                                  final n = double.tryParse(v.trim());
                                  setState(() {
                                    monthlyBudget = n ?? 0;
                                    usingDefaultFromNeeds = false;
                                  });
                                },
                              ),
                              if (usingDefaultFromNeeds)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8, left: 4),
                                  child: Text(
                                    income > 0
                                        ? "Using Default (50% of RM ${income.toStringAsFixed(2)} income)"
                                        : "Using Fallback (Needs budget)",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: t.hintColor,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 16),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: saving ? null : useNeedsDefault,
                                  icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                                  label: const Text("Auto-set to 'Needs' Default"),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),

                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: assignedRm > monthlyBudget + 0.01 ? cs.errorContainer : cs.primaryContainer,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        "Allocation Remaining",
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: assignedRm > monthlyBudget + 0.01
                                              ? cs.onErrorContainer
                                              : cs.onPrimaryContainer,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      flex: 2,
                                      child: Text(
                                        assignedRm > monthlyBudget + 0.01
                                            ? "Over: ${_money(overAssignedRm)}"
                                            : "Unassigned: ${_money(unassignedRm.clamp(0, double.infinity))} (${remainingPct.toStringAsFixed(2)}%)",
                                        textAlign: TextAlign.right,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: assignedRm > monthlyBudget + 0.01
                                              ? cs.onErrorContainer
                                              : cs.onPrimaryContainer,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],

                      if (entries.isNotEmpty && !isEditing) ...[
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: cs.surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: t.dividerColor.withOpacity(0.5)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    "Actual Expenses",
                                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: cs.onSurface),
                                  ),
                                  if (_touchedCat != null)
                                    TextButton.icon(
                                      onPressed: () => setState(_clearPieSelection),
                                      icon: const Icon(Icons.close_rounded, size: 18),
                                      label: const Text("Clear"),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              SizedBox(
                                height: 250,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    PieChart(
                                      PieChartData(
                                        sectionsSpace: 4,
                                        centerSpaceRadius: 65,
                                        pieTouchData: PieTouchData(
                                          touchCallback: (event, response) {
                                            if (!mounted) return;

                                            final isTapUp = event is FlTapUpEvent;
                                            final touched = response?.touchedSection;
                                            final idx = touched?.touchedSectionIndex ?? -1;

                                            if (!isTapUp || idx < 0 || idx >= entries.length) {
                                              setState(_clearPieSelection);
                                              return;
                                            }

                                            if (_touchedIndex == idx) {
                                              setState(_clearPieSelection);
                                              return;
                                            }

                                            final cat = entries[idx].key;
                                            final val = entries[idx].value;
                                            final pct = totalSpent <= 0 ? 0.0 : (val / totalSpent * 100);

                                            setState(() {
                                              _touchedIndex = idx;
                                              _touchedCat = cat;
                                              _touchedValue = val;
                                              _touchedPct = pct;
                                            });

                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text("${_pretty(cat)} • ${_money(val)} (${pct.toStringAsFixed(2)}%)"),
                                                behavior: SnackBarBehavior.floating,
                                                backgroundColor: cs.inverseSurface,
                                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                              ),
                                            );
                                          },
                                        ),
                                        sections: _buildSections(entries, totalSpent, 70, cs, touchedIndex: _touchedIndex),
                                      ),
                                    ),
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _touchedCat == null ? "Total" : _pretty(_touchedCat!),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _touchedCat == null
                                              ? "RM ${totalSpent.toStringAsFixed(2)}"
                                              : "RM ${_touchedValue.toStringAsFixed(2)}",
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                            color: cs.onSurface,
                                          ),
                                        ),
                                        if (_touchedCat != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            "${_touchedPct.toStringAsFixed(2)}%",
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              color: cs.primary,
                                            ),
                                          ),
                                        ],
                                      ],
                                    )
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                "Tip: Tap a slice to see the category.",
                                style: TextStyle(
                                  color: cs.onSurfaceVariant,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],

                      if (selectedMonth != null) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              isEditing ? "Edit Allocations" : "Your Targets",
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: cs.onSurface),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (visibleCats.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(32),
                            decoration: BoxDecoration(
                              color: cs.surface,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: t.dividerColor.withOpacity(0.5)),
                            ),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(Icons.tune_rounded, size: 48, color: t.hintColor),
                                  const SizedBox(height: 16),
                                  Text(
                                    isEditing ? "Start setting targets" : "No saved targets",
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    isEditing ? "Allocate funds below." : "Tap Edit to set your targets.",
                                    style: TextStyle(color: t.hintColor),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          ...visibleCats.map((cat) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: _CategoryTargetRow(
                                color: _colorForCat(cat),
                                title: _pretty(cat),
                                monthlyBudget: monthlyBudget,
                                percent: (categoryPct[cat] ?? 0).clamp(0, 100).toDouble(),
                                amountRm: (categoryAmt[cat] ?? 0).clamp(0, double.infinity),
                                maxAllowedPercent: _maxAllowedForPct(cat),
                                maxAllowedAmount: _maxAllowedForAmt(cat),
                                enabled: isEditing && !saving,
                                onPercentChanged: (newPct) => _setPctCapped(cat, newPct),
                                onAmountChanged: (newAmt) => _setAmt(cat, newAmt),
                                actual: totals[cat] ?? 0,
                                target: _targetForCat(cat),
                                unassignedRm: unassignedRm,
                                remainingPct: remainingPct,
                              ),
                            );
                          }),
                      ]
                    ],
                  ),
                ),
    );
  }

  List<PieChartSectionData> _buildSections(
    List<MapEntry<String, double>> entries,
    double total,
    double maxRadius,
    ColorScheme cs, {
    int? touchedIndex,
  }) {
    return List.generate(entries.length, (i) {
      final e = entries[i];
      final v = e.value;
      final pct = total <= 0 ? 0 : (v / total * 100);
      final isTouched = (touchedIndex != null && touchedIndex == i);

      return PieChartSectionData(
        color: _colorForCat(e.key),
        value: v,
        radius: isTouched ? maxRadius + 10 : maxRadius,
        title: (pct > 6 || isTouched) ? "${pct.toStringAsFixed(2)}%" : "",
        titleStyle: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: isTouched ? 13 : 12,
          color: cs.onPrimary,
          shadows: const [Shadow(blurRadius: 4, color: Colors.black45, offset: Offset(0, 1))],
        ),
      );
    });
  }
}

/* ------------------- HERO ------------------- */

class _BudgetDashboardHero extends StatelessWidget {
  final double monthlyBudget;
  final double totalSpent;
  final double assignedRm;
  final double income;
  final bool isEditing;
  final bool isAllYear;

  const _BudgetDashboardHero({
    required this.monthlyBudget,
    required this.totalSpent,
    required this.assignedRm,
    required this.income,
    required this.isEditing,
    required this.isAllYear,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final remaining = monthlyBudget - totalSpent;
    final isOver = remaining < 0;

    if (isAllYear) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            colors: [cs.primary, cs.secondary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(color: cs.primary.withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 8)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Yearly Overview",
              style: TextStyle(color: cs.onPrimary.withOpacity(0.8), fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _HeroMetric(label: "Total Spent", value: "RM ${totalSpent.toStringAsFixed(2)}"),
                Container(width: 1, height: 30, color: cs.onPrimary.withOpacity(0.3)),
                _HeroMetric(label: "Total Income", value: "RM ${income.toStringAsFixed(2)}"),
              ],
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: [cs.primary, cs.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(color: cs.primary.withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isEditing ? "Budget Setup" : "Monthly Overview",
            style: TextStyle(color: cs.onPrimary.withOpacity(0.8), fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEditing ? "Total Budget" : (isOver ? "Overspent By" : "Remaining"),
                    style: TextStyle(color: cs.onPrimary.withOpacity(0.9), fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    isEditing ? "RM ${monthlyBudget.toStringAsFixed(2)}" : "RM ${remaining.abs().toStringAsFixed(2)}",
                    style: TextStyle(color: cs.onPrimary, fontSize: 32, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              if (!isEditing)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isOver ? cs.errorContainer : cs.onPrimary.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isOver ? "Over Budget" : "On Track",
                    style: TextStyle(
                      color: isOver ? cs.onErrorContainer : cs.onPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _HeroMetric(
                label: isEditing ? "Assigned" : "Spent",
                value: "RM ${(isEditing ? assignedRm : totalSpent).toStringAsFixed(2)}",
              ),
              Container(width: 1, height: 30, color: cs.onPrimary.withOpacity(0.3)),
              _HeroMetric(label: "Income", value: "RM ${income.toStringAsFixed(2)}"),
              Container(width: 1, height: 30, color: cs.onPrimary.withOpacity(0.3)),
              _HeroMetric(
                label: isEditing ? "Unassigned" : "Budget",
                value: isEditing
                    ? "RM ${(monthlyBudget - assignedRm).clamp(0, double.infinity).toStringAsFixed(2)}"
                    : "RM ${monthlyBudget.toStringAsFixed(2)}",
              ),
            ],
          )
        ],
      ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  final String label;
  final String value;
  const _HeroMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: cs.onPrimary.withOpacity(0.8), fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: cs.onPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

/* ------------------- ROW (UPDATED INPUT LOGIC) ------------------- */

class _CategoryTargetRow extends StatefulWidget {
  final Color color;
  final String title;
  final double monthlyBudget;
  final double percent;
  final double amountRm;
  final double maxAllowedPercent;
  final double maxAllowedAmount;
  final bool enabled;
  final ValueChanged<double> onPercentChanged;
  final ValueChanged<double> onAmountChanged;
  final double actual;
  final double target;

  final double unassignedRm;
  final double remainingPct;

  const _CategoryTargetRow({
    required this.color,
    required this.title,
    required this.monthlyBudget,
    required this.percent,
    required this.amountRm,
    required this.maxAllowedPercent,
    required this.maxAllowedAmount,
    required this.enabled,
    required this.onPercentChanged,
    required this.onAmountChanged,
    required this.actual,
    required this.target,
    required this.unassignedRm,
    required this.remainingPct,
  });

  @override
  State<_CategoryTargetRow> createState() => _CategoryTargetRowState();
}

class _CategoryTargetRowState extends State<_CategoryTargetRow> {
  late final TextEditingController pctCtrl;
  late final TextEditingController amtCtrl;

  bool _syncing = false;
  bool _editingAmt = false;
  bool _editingPct = false;

  double _parseNum(String s) {
    final cleaned = s.replaceAll(",", "").trim();
    if (cleaned.isEmpty) return 0;
    return double.tryParse(cleaned) ?? 0;
  }

  // ✅ All numbers now strictly display with two decimal points
  String _fmtAmt(double v) {
    final s = v.toStringAsFixed(2);
    return (s == "0.00") ? "" : s;
  }

  String _fmtPct(double v) {
    final s = v.toStringAsFixed(2);
    return (s == "0.00") ? "" : s;
  }

  void _setText(TextEditingController c, String text) {
    if (c.text == text) return;
    c.value = c.value.copyWith(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: TextRange.empty,
    );
  }

  bool _looksLikePartialDecimal(String raw) {
    final s = raw.trim();
    if (s == ".") return true;
    if (s.endsWith(".")) return true;
    return false;
  }

  void _fromRM(String raw) {
    if (_syncing) return;
    _syncing = true;

    final isPartial = _looksLikePartialDecimal(raw);

    final parsed = _parseNum(raw).clamp(0, double.infinity).toDouble();
    final cap = widget.maxAllowedAmount;
    double rm = parsed;
    if (cap.isFinite) rm = min(parsed, cap);

    widget.onAmountChanged(rm);

    if (!isPartial && parsed != rm) {
      _setText(amtCtrl, _fmtAmt(rm));
    }

    if (widget.monthlyBudget > 0) {
      final pct = (rm / widget.monthlyBudget) * 100;
      final pctClamped = (pct.isFinite ? pct.clamp(0, 100) : 0).toDouble();
      if (!_editingPct) _setText(pctCtrl, _fmtPct(pctClamped));
    } else {
      if (!_editingPct) _setText(pctCtrl, "");
    }

    _syncing = false;
  }

  void _fromPct(String raw) {
    if (_syncing) return;
    _syncing = true;

    final isPartial = _looksLikePartialDecimal(raw);

    final inputPct = _parseNum(raw).clamp(0, 100).toDouble();
    final capped = inputPct.clamp(0, widget.maxAllowedPercent).toDouble();

    widget.onPercentChanged(capped);

    if (widget.monthlyBudget > 0) {
      final rm = widget.monthlyBudget * (capped / 100);
      if (!_editingAmt) _setText(amtCtrl, _fmtAmt(rm));
    } else {
      if (!_editingAmt) _setText(amtCtrl, "");
    }

    if (!isPartial && capped != inputPct && !_editingPct) {
      _setText(pctCtrl, _fmtPct(capped));
    }

    _syncing = false;
  }

  void _finalizeAmt() {
    final raw = amtCtrl.text.trim();
    if (_looksLikePartialDecimal(raw)) return;

    final parsed = _parseNum(raw).clamp(0, double.infinity).toDouble();
    final cap = widget.maxAllowedAmount;
    double rm = parsed;
    if (cap.isFinite) rm = min(parsed, cap);

    _setText(amtCtrl, _fmtAmt(rm));
    _fromRM(amtCtrl.text);
  }

  void _finalizePct() {
    final raw = pctCtrl.text.trim();
    if (_looksLikePartialDecimal(raw)) return;

    final parsed = _parseNum(raw).clamp(0, 100).toDouble();
    final capped = parsed.clamp(0, widget.maxAllowedPercent).toDouble();

    _setText(pctCtrl, _fmtPct(capped));
    _fromPct(pctCtrl.text);
  }

  @override
  void initState() {
    super.initState();

    final rmMode = widget.amountRm > 0;

    pctCtrl = TextEditingController(
      text: rmMode
          ? (widget.monthlyBudget > 0 ? _fmtPct((widget.amountRm / widget.monthlyBudget) * 100) : "")
          : _fmtPct(widget.percent),
    );

    amtCtrl = TextEditingController(
      text: rmMode
          ? _fmtAmt(widget.amountRm)
          : (widget.monthlyBudget > 0 ? _fmtAmt(widget.monthlyBudget * (widget.percent / 100)) : ""),
    );
  }

  @override
  void didUpdateWidget(covariant _CategoryTargetRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_syncing) return;

    final rmMode = widget.amountRm > 0;

    if (!_editingAmt) {
      if (rmMode) {
        _setText(amtCtrl, _fmtAmt(widget.amountRm));
      } else if (widget.monthlyBudget > 0) {
        _setText(amtCtrl, _fmtAmt(widget.monthlyBudget * (widget.percent / 100)));
      } else {
        _setText(amtCtrl, "");
      }
    }

    if (!_editingPct) {
      if (rmMode) {
        if (widget.monthlyBudget > 0) {
          _setText(pctCtrl, _fmtPct((widget.amountRm / widget.monthlyBudget) * 100));
        } else {
          _setText(pctCtrl, "");
        }
      } else {
        _setText(pctCtrl, _fmtPct(widget.percent));
      }
    }
  }

  @override
  void dispose() {
    pctCtrl.dispose();
    amtCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final liveTarget = widget.amountRm > 0
        ? widget.amountRm
        : (widget.monthlyBudget > 0 ? widget.monthlyBudget * (widget.percent / 100) : 0);

    final remaining = widget.target - widget.actual;
    final isOver = widget.target > 0 && widget.actual > widget.target;

    final ratio = widget.target <= 0 ? 0.0 : (widget.actual / widget.target).clamp(0.0, 1.0).toDouble();

    InputDecoration dec({required String label, String? prefixText, String? suffixText}) {
      return InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        fillColor: widget.enabled
            ? cs.surfaceContainerHighest.withOpacity(0.55)
            : cs.surfaceContainerHighest.withOpacity(0.25),
        prefixText: prefixText,
        suffixText: suffixText,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.primary, width: 2)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      );
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isOver && !widget.enabled ? cs.error.withOpacity(0.5) : Theme.of(context).dividerColor.withOpacity(0.4),
        ),
        color: cs.surface,
        boxShadow: [BoxShadow(color: Theme.of(context).shadowColor.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 14, height: 14, decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(widget.title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: cs.onSurface)),
              ),
              if (!widget.enabled && widget.target > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isOver ? cs.errorContainer : cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isOver) Icon(Icons.warning_amber_rounded, size: 14, color: cs.onErrorContainer),
                      if (isOver) const SizedBox(width: 4),
                      Text(
                        isOver ? "Over by RM ${(-remaining).toStringAsFixed(2)}" : "Left: RM ${remaining.toStringAsFixed(2)}",
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isOver ? cs.onErrorContainer : cs.onSecondaryContainer),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (widget.enabled) ...[
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Focus(
                    onFocusChange: (hasFocus) {
                      _editingPct = hasFocus;
                      if (!hasFocus) _finalizePct();
                    },
                    child: TextField(
                      controller: pctCtrl,
                      enabled: widget.enabled,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}$')),
                      ],
                      decoration: dec(label: "%", suffixText: "%"),
                      onChanged: (v) {
                        if (!widget.enabled) return;
                        _fromPct(v);
                      },
                      onSubmitted: (_) => _finalizePct(),
                      onTapOutside: (_) => _finalizePct(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: Focus(
                    onFocusChange: (hasFocus) {
                      _editingAmt = hasFocus;
                      if (!hasFocus) _finalizeAmt();
                    },
                    child: TextField(
                      controller: amtCtrl,
                      enabled: widget.enabled,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}$')),
                      ],
                      decoration: dec(label: "Amount", prefixText: "RM "),
                      onChanged: (v) {
                        if (!widget.enabled) return;
                        _fromRM(v);
                      },
                      onSubmitted: (_) => _finalizeAmt(),
                      onTapOutside: (_) => _finalizeAmt(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: widget.unassignedRm <= 0 ? Colors.green.withOpacity(0.1) : cs.surfaceContainerHighest.withOpacity(0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: widget.unassignedRm <= 0 ? Colors.green.withOpacity(0.4) : cs.primary.withOpacity(0.1),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.unassignedRm <= 0 ? Icons.check_circle : Icons.info_outline,
                    size: 14,
                    color: widget.unassignedRm <= 0 ? Colors.green : cs.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.monthlyBudget <= 0
                          ? "Set Monthly Budget above to calculate allocation."
                          : "Target: RM ${liveTarget.toStringAsFixed(2)} • "
                            "Unassigned: RM ${widget.unassignedRm.clamp(0, double.infinity).toStringAsFixed(2)} (${widget.remainingPct.toStringAsFixed(2)}%)",
                      style: TextStyle(
                        color: widget.unassignedRm <= 0 ? Colors.green : cs.onSurfaceVariant,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            )
          ] else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("RM ${widget.actual.toStringAsFixed(2)} spent", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                Text("of RM ${widget.target.toStringAsFixed(2)}", style: TextStyle(color: Theme.of(context).hintColor, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: ratio.isNaN ? 0.0 : ratio,
                minHeight: 8,
                backgroundColor: cs.surfaceContainerHighest.withOpacity(0.5),
                color: isOver ? cs.error : widget.color,
              ),
            ),
          ]
        ],
      ),
    );
  }
}

/* ===================== EXACT PICKER FROM MORE PAGE ===================== */

class _MonthYearPickerBar extends StatelessWidget {
  final int year;
  final int? month;
  final bool enabled; // Locks picker while saving
  final void Function(int year, int? month) onChanged;

  const _MonthYearPickerBar({
    required this.year,
    required this.month,
    this.enabled = true,
    required this.onChanged,
  });

  Future<void> _pickDate(BuildContext context) async {
    if (!enabled) return;
    final cs = Theme.of(context).colorScheme;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: cs.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) {
        return SafeArea(
          child: DefaultTabController(
            length: 2,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: "Month"),
                    Tab(text: "Year"),
                  ],
                ),
                SizedBox(
                  height: 350,
                  child: TabBarView(
                    children: [
                      GridView.builder(
                        padding: const EdgeInsets.all(16),
                        physics: const BouncingScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 2.5,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: 13,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            final isSelected = month == null;
                            return _GridTile(
                              text: "All Year",
                              isSelected: isSelected,
                              onTap: () {
                                Navigator.pop(ctx);
                                onChanged(year, null);
                              },
                            );
                          }
                          final m = index;
                          final isSelected = month == m;
                          return _GridTile(
                            text: DateFormat("MMM").format(DateTime(2000, m)),
                            isSelected: isSelected,
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
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 2.5,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: 12,
                        itemBuilder: (context, index) {
                          final y = DateTime.now().year - 5 + index;
                          final isSelected = year == y;
                          return _GridTile(
                            text: "$y",
                            isSelected: isSelected,
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final monthLabel = month == null ? "All Year" : DateFormat("MMM").format(DateTime(year, month!));
    final yearLabel = "$year";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: t.dividerColor.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            style: IconButton.styleFrom(backgroundColor: cs.surfaceContainerHighest.withOpacity(0.5)),
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
            onPressed: enabled
                ? () {
                    if (month == null) {
                      onChanged(year - 1, null);
                    } else {
                      final prev = DateTime(year, month! - 1, 1);
                      onChanged(prev.year, prev.month);
                    }
                  }
                : null,
          ),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? () => _pickDate(context) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.calendar_month_rounded, size: 18, color: enabled ? cs.primary : t.hintColor),
                  const SizedBox(width: 8),
                  Text(
                    "$monthLabel $yearLabel",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: enabled ? cs.onSurface : t.hintColor),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: t.hintColor),
                ],
              ),
            ),
          ),
          IconButton(
            style: IconButton.styleFrom(backgroundColor: cs.surfaceContainerHighest.withOpacity(0.5)),
            icon: const Icon(Icons.chevron_right_rounded, size: 20),
            onPressed: enabled
                ? () {
                    if (month == null) {
                      onChanged(year + 1, null);
                    } else {
                      final next = DateTime(year, month! + 1, 1);
                      onChanged(next.year, next.month);
                    }
                  }
                : null,
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
          color: isSelected ? cs.primary : cs.surfaceContainerHighest.withOpacity(0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
            color: isSelected ? cs.onPrimary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}