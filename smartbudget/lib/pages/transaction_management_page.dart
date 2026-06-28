import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/transaction_service.dart';
import 'add_transaction_page.dart';
import '../services/globals.dart';

class TransactionManagementPage extends StatefulWidget {
  const TransactionManagementPage({super.key});

  @override
  State<TransactionManagementPage> createState() => _TransactionManagementPageState();
}

class _TransactionManagementPageState extends State<TransactionManagementPage> {
  final txService = TransactionService();

  bool loading = true;
  String? error;
  List<Map<String, dynamic>> txs = [];

  final searchCtrl = TextEditingController();

  int selectedYear = DateTime.now().year;
  int? selectedMonth = DateTime.now().month;

  String? get userId => Supabase.instance.client.auth.currentUser?.id;

  final Map<String, IconData> categoryIcons = {
    "food": Icons.restaurant_rounded,
    "transport": Icons.directions_car_rounded,
    "shopping": Icons.shopping_bag_rounded,
    "bills": Icons.receipt_long_rounded,
    "entertainment": Icons.movie_creation_rounded,
    "healthcare": Icons.medical_services_rounded,
    "education": Icons.school_rounded,
    "banking": Icons.account_balance_rounded,
    "personal_care": Icons.spa_rounded,
    "pets": Icons.pets_rounded,
    "home": Icons.home_rounded,
    "travel": Icons.flight_rounded,
    "income": Icons.attach_money_rounded,
    "other": Icons.category_rounded,
  };

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
    return DateFormat("dd MMM yyyy").format(dt.toLocal());
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

  String _type(dynamic v) => (v ?? '').toString().trim().toLowerCase();

  String _prettyCategory(String c) {
    final parts = c.split('_');
    return parts.map((p) => p.isEmpty ? p : "${p[0].toUpperCase()}${p.substring(1)}").join(' ');
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
      final list = List<Map<String, dynamic>>.from(data)
        ..sort((a, b) {
          final ad = _parseDate(a['date'])?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
          final bd = _parseDate(b['date'])?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bd.compareTo(ad);
        });

      if (!mounted) return;
      setState(() => txs = list);
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

  @override
  void initState() {
    super.initState();

    globalTransactionUpdateNotifier.addListener(_onGlobalTxUpdate);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await loadTx();
    });
  }

  Future<void> _onGlobalTxUpdate() async {
    if (!mounted) return;
    await loadTx();
  }

  @override
  void dispose() {
    globalTransactionUpdateNotifier.removeListener(_onGlobalTxUpdate);
    searchCtrl.dispose();
    super.dispose();
  }

  Widget _errorBox(String msg) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 20, color: cs.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(msg, style: TextStyle(fontWeight: FontWeight.bold, color: cs.onErrorContainer)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(Map<String, dynamic> t) async {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text("Delete Transaction?"),
        content: Text(
          "Delete this ${_type(t['type'])} of RM ${_asDouble(t['amount']).toStringAsFixed(2)} on ${_dateText(t['date'])}?",
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    try {
      setState(() {
        loading = true;
        error = null;
      });

      await txService.deleteTransaction(t['id']);

      globalTransactionUpdateNotifier.value++;

      if (!mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text("Transaction deleted"),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        )
      );
      
      await loadTx();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }
  
  Future<void> _confirmDeleteMonth() async {
    final uid = userId;

    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("User session expired."),
        ),
      );
      return;
    }

    if (selectedMonth == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Please select a specific month first.",
          ),
        ),
      );
      return;
    }

    final cs = Theme.of(context).colorScheme;

    final monthName = DateFormat("MMMM")
        .format(DateTime(selectedYear, selectedMonth!));

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: const Text("Delete Monthly Transactions?"),
        content: Text(
          "Delete all transactions for "
          "$monthName $selectedYear?\n\n"
          "This action cannot be undone.",
          style: TextStyle(
            color: cs.onSurfaceVariant,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: cs.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;

    try {
      setState(() {
        loading = true;
        error = null;
      });

      final startDate =
          DateTime(selectedYear, selectedMonth!, 1);

      final endDate =
          DateTime(selectedYear, selectedMonth! + 1, 1);

      await Supabase.instance.client
          .from('transactions')
          .delete()
          .eq('user_id', uid)
          .gte(
            'date',
            startDate.toIso8601String(),
          )
          .lt(
            'date',
            endDate.toIso8601String(),
          );

      globalTransactionUpdateNotifier.value++;

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Transactions for $monthName $selectedYear deleted.",
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );

      await loadTx();
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loading = false;
        error = e.toString();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Failed to delete transactions: $e",
          ),
        ),
      );
    }
  }

  Future<void> _openEdit(Map<String, dynamic> t) async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AddTransactionPage(transaction: t),
      ),
    );
    if (!mounted) return;
    await loadTx();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final bool isMonthMode = selectedMonth != null;

    final yearFiltered = txs.where(_inSelectedYear).toList();
    final selectionFiltered = isMonthMode ? yearFiltered.where(_inSelectedMonth).toList() : yearFiltered;

    final income = selectionFiltered
        .where((t) => _type(t['type']) == 'income')
        .fold<double>(0, (sum, t) => sum + _asDouble(t['amount']));

    final expense = selectionFiltered
        .where((t) => _type(t['type']) == 'expense')
        .fold<double>(0, (sum, t) => sum + _asDouble(t['amount']));

    final balance = income - expense;

    final q = searchCtrl.text.trim().toLowerCase();
    final filtered = (q.isEmpty
            ? selectionFiltered
            : selectionFiltered.where((t) {
                final type = _type(t['type']);
                final desc = (t['description'] ?? '').toString().toLowerCase();
                final cat = (t['category'] ?? '').toString().toLowerCase();
                final date = _dateText(t['date']).toLowerCase();
                return type.contains(q) || desc.contains(q) || cat.contains(q) || date.contains(q);
              }).toList())
        .toList()
      ..sort((a, b) {
        final ad = _parseDate(a['date'])?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
        final bd = _parseDate(b['date'])?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);
        return bd.compareTo(ad);
      });

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text(
          "Transactions",
          style: TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: "Delete Selected Month",
            icon: const Icon(
              Icons.delete_forever_rounded,
            ),
            onPressed: selectedMonth == null
                ? null
                : _confirmDeleteMonth,
          ),
        ],
      ),

      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: RefreshIndicator(
          onRefresh: loadTx,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              // Top Section (Picker, Search, Hero Summary)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    children: [
                      _MonthYearPickerBar(
                        year: selectedYear,
                        month: selectedMonth,
                        onChanged: (y, m) {
                          setState(() {
                            selectedYear = y;
                            selectedMonth = m;
                          });
                          loadTx(); // Reload transactions when date changes
                        },
                      ),
                      const SizedBox(height: 12),
                      
                      // Search Bar
                      TextField(
                        controller: searchCtrl,
                        onChanged: (_) => setState(() {}),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          prefixIcon: Icon(Icons.search_rounded, color: cs.primary),
                          hintText: "Search transactions...",
                          hintStyle: TextStyle(color: cs.onSurfaceVariant.withOpacity(0.7)),
                          filled: true,
                          fillColor: cs.surfaceContainerHighest.withOpacity(0.5),
                          contentPadding: const EdgeInsets.symmetric(vertical: 0),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                          suffixIcon: q.isEmpty
                              ? null
                              : IconButton(
                                  icon: Icon(Icons.clear_rounded, color: cs.onSurfaceVariant),
                                  onPressed: () {
                                    searchCtrl.clear();
                                    FocusScope.of(context).unfocus();
                                    setState(() {});
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      // Summary Hero
                      _SummaryHero(income: income, expense: expense, balance: balance),
                    ],
                  ),
                ),
              ),

              // Main List Content
              if (loading)
                const SliverFillRemaining(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (error != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _errorBox(error!),
                        const SizedBox(height: 16),
                        FilledButton.icon(onPressed: loadTx, icon: const Icon(Icons.refresh), label: const Text("Retry"))
                      ],
                    ),
                  ),
                )
              else if (filtered.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const SizedBox(height: 40),
                        Icon(Icons.receipt_long_rounded, size: 64, color: cs.onSurfaceVariant.withOpacity(0.5)),
                        const SizedBox(height: 16),
                        Text(
                          q.isEmpty ? "No transactions found" : "No results for '$q'",
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Try selecting a different date or clearing your search.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: t.hintColor),
                        ),
                      ],
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final tMap = filtered[i];
                        final type = _type(tMap['type']);
                        final amount = _asDouble(tMap['amount']);
                        final date = _dateText(tMap['date']);
                        final desc = (tMap['description'] ?? '').toString();
                        final cat = (tMap['category'] ?? '').toString();
                        final isIncome = type == 'income';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: cs.surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: t.dividerColor.withOpacity(0.4)),
                            boxShadow: [BoxShadow(color: t.shadowColor.withOpacity(0.02), blurRadius: 6, offset: const Offset(0, 2))],
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            leading: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isIncome ? Colors.green.shade100 : cs.primaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                categoryIcons[cat] ?? Icons.category_rounded,
                                color: isIncome ? Colors.green.shade700 : cs.primary,
                                size: 20,
                              ),
                            ),
                            title: Text(
                              desc.trim().isEmpty ? _prettyCategory(cat) : desc,
                              style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurface, fontSize: 16),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4.0), // <-- FIXED
                              child: Row(
                                children: [
                                  Text(date, style: TextStyle(fontSize: 12, color: t.hintColor, fontWeight: FontWeight.w600)),
                                  Text(" • ", style: TextStyle(fontSize: 12, color: t.hintColor)),
                                  Expanded(
                                    child: Text(
                                      _prettyCategory(cat),
                                      style: TextStyle(fontSize: 12, color: t.hintColor, fontWeight: FontWeight.w500),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  "${isIncome ? '+' : '-'} RM ${amount.toStringAsFixed(2)}",
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 16,
                                    color: isIncome ? Colors.green.shade700 : cs.onSurface,
                                  ),
                                ),
                              ],
                            ),
                            onTap: () => _openEdit(tMap),
                            onLongPress: () {
                              showModalBottomSheet(
                                context: context,
                                showDragHandle: true,
                                builder: (ctx) => SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ListTile(
                                        leading: const Icon(Icons.edit_rounded),
                                        title: const Text("Edit Transaction"),
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          _openEdit(tMap);
                                        },
                                      ),
                                      ListTile(
                                        leading: Icon(Icons.delete_outline_rounded, color: cs.error),
                                        title: Text("Delete Transaction", style: TextStyle(color: cs.error)),
                                        onTap: () {
                                          Navigator.pop(ctx);
                                          _confirmDelete(tMap);
                                        },
                                      ),
                                    ],
                                  ),
                                )
                              );
                            },
                          ),
                        );
                      },
                      childCount: filtered.length,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ===================== UI Widgets ===================== */

class _SummaryHero extends StatelessWidget {
  final double income;
  final double expense;
  final double balance;

  const _SummaryHero({
    required this.income,
    required this.expense,
    required this.balance,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNegative = balance < 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [cs.primary, cs.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [BoxShadow(color: cs.primary.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 6))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Total Balance", style: TextStyle(color: cs.onPrimary.withOpacity(0.8), fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    "RM ${balance.toStringAsFixed(2)}",
                    style: TextStyle(color: cs.onPrimary, fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              if (isNegative)
                 Container(
                   padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                   decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(8)),
                   child: Text("Overspent", style: TextStyle(color: cs.onErrorContainer, fontSize: 11, fontWeight: FontWeight.bold)),
                 )
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: cs.onPrimary.withOpacity(0.15), borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.arrow_downward_rounded, size: 14, color: Colors.green.shade300),
                          const SizedBox(width: 4),
                          Text("Income", style: TextStyle(color: cs.onPrimary.withOpacity(0.9), fontSize: 12, fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text("RM ${income.toStringAsFixed(2)}", style: TextStyle(color: cs.onPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: cs.onPrimary.withOpacity(0.15), borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.arrow_upward_rounded, size: 14, color: Colors.orange.shade300),
                          const SizedBox(width: 4),
                          Text("Expense", style: TextStyle(color: cs.onPrimary.withOpacity(0.9), fontSize: 12, fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text("RM ${expense.toStringAsFixed(2)}", style: TextStyle(color: cs.onPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
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
      isScrollControlled: true, // <-- FIXED: Prevents Bottom Overflow!
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
                  height: 350, // <-- FIXED: Increased height slightly for better grid fit
                  child: TabBarView(
                    children: [
                      // Month Grid
                      GridView.builder(
                        padding: const EdgeInsets.all(16),
                        physics: const BouncingScrollPhysics(), // <-- Added scrolling bounce
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 2.5,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: 13, // 12 months + "All Year"
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            final isSelected = month == null;
                            return _GridTile(
                              text: "All Year", 
                              isSelected: isSelected, 
                              onTap: () { Navigator.pop(ctx); onChanged(year, null); }
                            );
                          }
                          final m = index;
                          final isSelected = month == m;
                          return _GridTile(
                            text: DateFormat("MMM").format(DateTime(2000, m)), 
                            isSelected: isSelected, 
                            onTap: () { Navigator.pop(ctx); onChanged(year, m); }
                          );
                        },
                      ),
                      // Year Grid
                      GridView.builder(
                        padding: const EdgeInsets.all(16),
                        physics: const BouncingScrollPhysics(), // <-- Added scrolling bounce
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
                            onTap: () { Navigator.pop(ctx); onChanged(y, month); }
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