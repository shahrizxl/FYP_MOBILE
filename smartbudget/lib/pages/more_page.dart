import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'category_breakdown_page.dart';
import 'saving_goals_page.dart';
import 'planned_payments_page.dart';
import '../services/globals.dart';
import 'prediction_page.dart';

class MorePage extends StatefulWidget {
  const MorePage({super.key});

  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  bool loading = true;
  String? error;

  int selectedYear = DateTime.now().year;
  int? selectedMonth = DateTime.now().month;

  List<Map<String, dynamic>> txs = [];

  String? get userId => Supabase.instance.client.auth.currentUser?.id;

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  String _type(dynamic v) => (v ?? '').toString().trim().toLowerCase();

  // FIX 2: Fast UI filtering using cached date
  bool _inSelectedYear(Map<String, dynamic> t) {
    final dt = t['_parsedDate'] as DateTime?;
    return dt != null && dt.year == selectedYear;
  }

  bool _inSelectedMonth(Map<String, dynamic> t) {
    if (selectedMonth == null) return false;
    final dt = t['_parsedDate'] as DateTime?;
    return dt != null && dt.year == selectedYear && dt.month == selectedMonth;
  }

  Future<void> loadTx() async {
    final uid = userId;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = "Session expired. Please login again.";
      });
      return;
    }

    if (!mounted) return;
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

      // FIX 2: Pre-parse and cache the DateTimes 
      final parsedData = List<Map<String, dynamic>>.from(res).map((t) {
        return {
          ...t,
          '_parsedDate': _parseDate(t['date'])?.toLocal() ?? DateTime(0),
        };
      }).toList();

      if (!mounted) return;
      setState(() {
        txs = parsedData;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  double _totalIncomeForSelection() {
    final yearTx = txs.where(_inSelectedYear).toList();
    final selectionTx = selectedMonth == null ? yearTx : yearTx.where(_inSelectedMonth).toList();

    return selectionTx
        .where((t) => _type(t['type']) == 'income')
        .fold<double>(0, (sum, t) => sum + _asDouble(t['amount']));
  }

  @override
  void initState() {
    super.initState();
    globalTransactionUpdateNotifier.addListener(_onGlobalTxUpdate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      loadTx();
    });
  }

  Future<void> _onGlobalTxUpdate() async {
    if (!mounted) return;
    await loadTx();
  }

  @override
  void dispose() {
    globalTransactionUpdateNotifier.removeListener(_onGlobalTxUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final income = _totalIncomeForSelection();
    final needs = income * 0.50;
    final wants = income * 0.30;
    final savings = income * 0.20;

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: cs.surfaceContainerLowest,
        title: const Text("Tools & Insights", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
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
                          onPressed: loadTx,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text("Retry"),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: loadTx,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                    children: [
                      _MonthYearPickerBar(
                        year: selectedYear,
                        month: selectedMonth,
                        onChanged: (y, m) async {
                          if (!mounted) return;
                          setState(() {
                            selectedYear = y;
                            selectedMonth = m;
                          });
                          await loadTx();
                        },
                      ),
                      const SizedBox(height: 28),

                      Text(
                        "Income Split (50/30/20)",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: cs.onSurface),
                      ),
                      const SizedBox(height: 14),

                      _IncomeSplitHero(
                        income: income,
                        needs: needs,
                        wants: wants,
                        savings: savings,
                      ),

                      const SizedBox(height: 32),
                      Text(
                        "Financial Toolkit",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: cs.onSurface),
                      ),
                      const SizedBox(height: 14),

                      _ToolCard(
                        icon: Icons.receipt_long_rounded,
                        iconColor: Colors.orange.shade600,
                        title: "Planned Payments",
                        subtitle: "Track bills and upcoming dues",
                        onTap: () async {
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => const PlannedPaymentsPage()));
                          await loadTx();
                        },
                      ),


                      const SizedBox(height: 12),

                        _ToolCard(
                          icon: Icons.auto_awesome_rounded,
                          iconColor: Colors.purple.shade600,
                          title: "AI Prediction Details",
                          subtitle: "View forecast insights and ML analysis",
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const PredictionDetailsPage(),
                              ),
                            );
                          },
                        ),

                      const SizedBox(height: 12),
                      
                      _ToolCard(
                        icon: Icons.pie_chart_rounded,
                        iconColor: cs.primary,
                        title: "Category Breakdown",
                        subtitle: "Analyze and adjust your budget",
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CategoryBreakdownPage(
                                year: selectedYear,
                                month: selectedMonth ?? DateTime.now().month, // keep page param int
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 12),

                      _ToolCard(
                        icon: Icons.savings_rounded,
                        iconColor: Colors.green.shade600,
                        title: "Saving Goals",
                        subtitle: "Manage your targets and milestones",
                        onTap: () async {
                          await Navigator.push(context, MaterialPageRoute(builder: (_) => const SavingGoalsPage()));
                        },
                      ),
                    ],
                  ),
                ),
    );
  }
}

/* ===================== HERO DASHBOARD ===================== */

class _IncomeSplitHero extends StatelessWidget {
  final double income;
  final double needs;
  final double wants;
  final double savings;

  const _IncomeSplitHero({
    required this.income,
    required this.needs,
    required this.wants,
    required this.savings,
  });

  String _money(double v) => NumberFormat.simpleCurrency(name: 'RM ', decimalDigits: 0).format(v);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    if (income <= 0) {
      return Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: t.dividerColor.withOpacity(0.1)),
        ),
        child: Column(
          children: [
            Icon(Icons.account_balance_wallet_outlined, size: 48, color: cs.primary.withOpacity(0.5)),
            const SizedBox(height: 16),
            Text("No Income Recorded",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(
              "Add an income transaction to see your recommended budget split.",
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
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
          colors: [cs.primary, cs.tertiary],
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
          Text("Total Income",
              style: TextStyle(color: cs.onPrimary.withOpacity(0.8), fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(_money(income),
              style: TextStyle(color: cs.onPrimary, fontSize: 32, fontWeight: FontWeight.w900)),
          const SizedBox(height: 24),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: 12,
              child: Row(
                children: [
                  Expanded(flex: 5, child: Container(color: cs.onPrimary)),
                  Expanded(flex: 3, child: Container(color: cs.onPrimary.withOpacity(0.6))),
                  Expanded(flex: 2, child: Container(color: cs.onPrimary.withOpacity(0.3))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _SplitMetric(label: "Needs", value: _money(needs), color: cs.onPrimary),
              _SplitMetric(label: "Wants", value: _money(wants), color: cs.onPrimary.withOpacity(0.8)),
              _SplitMetric(label: "Savings", value: _money(savings), color: cs.onPrimary.withOpacity(0.6)),
            ],
          )
        ],
      ),
    );
  }
}

class _SplitMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _SplitMetric({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w900)),
      ],
    );
  }
}

/* ===================== TOOL CARDS ===================== */

class _ToolCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ToolCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: t.dividerColor.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: iconColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(icon, color: iconColor, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: cs.onSurface)),
                      const SizedBox(height: 4),
                      Text(subtitle,
                          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant.withOpacity(0.4)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* ===================== SAME PICKER AS PREVIOUS CODE ===================== */

class _MonthYearPickerBar extends StatelessWidget {
  final int year;
  final int? month; // null = all year
  final void Function(int year, int? month) onChanged;

  const _MonthYearPickerBar({
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
                      // Month Grid (includes All Year)
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
                          final m = index; // 1..12
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
                      // Year Grid
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
                  Text(
                    "$monthLabel $yearLabel",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: cs.onSurface),
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