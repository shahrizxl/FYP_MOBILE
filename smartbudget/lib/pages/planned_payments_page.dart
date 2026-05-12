import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/notification_service.dart';

class PlannedPaymentsPage extends StatefulWidget {
  const PlannedPaymentsPage({super.key});

  @override
  State<PlannedPaymentsPage> createState() => _PlannedPaymentsPageState();
}

class _PlannedPaymentsPageState extends State<PlannedPaymentsPage> {
  final supabase = Supabase.instance.client;

  bool loading = true;
  String? error;

  List<Map<String, dynamic>> items = [];

  // prevent double-tap on Done
  final Set<String> _posting = {};

  String? get userId => supabase.auth.currentUser?.id;

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

  String _prettyCat(String key) {
    final parts = key.split('_');
    return parts
        .map((p) => p.isEmpty ? p : (p[0].toUpperCase() + p.substring(1)))
        .join(' ');
  }

  String _normCatKey(String raw) {
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return "other";
    s = s.replaceAll('-', '_').replaceAll(' ', '_');

    if (s == "uncategorized") return "other";
    if (s == "health") return "healthcare";
    if (s == "personalcare") return "personal_care";

    if (!kCategories.contains(s)) return "other";
    return s;
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  String _fmtDate(DateTime d) => DateFormat("dd MMM yyyy").format(d);

  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<DateTime?> _pickDueDate(BuildContext ctx, DateTime initial) async {
    final now = DateTime.now();
    final first = DateTime(now.year - 5, 1, 1);
    final last = DateTime(now.year + 5, 12, 31);

    final picked = await showDatePicker(
      context: ctx,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: "Select due date",
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        return Theme(data: Theme.of(context), child: child);
      },
    );

    return picked == null ? null : _startOfDay(picked);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _load();
    });
  }

  Future<void> _load() async {
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
      final res = await supabase
          .from('planned_payments')
          .select('id, title, amount, due_date, category, is_posted, posted_tx_id')
          .eq('user_id', uid)
          .order('due_date', ascending: true);

      if (!mounted) return;
      setState(() => items = List<Map<String, dynamic>>.from(res));
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _markAsPaid(Map<String, dynamic> p) async {
    final uid = userId;
    if (uid == null) return;

    final ppId = (p['id'] ?? '').toString();
    final title = (p['title'] ?? '').toString().trim();
    final amount = _asDouble(p['amount']);
    final catKey = _normCatKey((p['category'] ?? 'bills').toString());
    final dueDate = _parseDate(p['due_date'])?.toLocal() ?? DateTime.now();

    if (ppId.isEmpty || title.isEmpty || amount <= 0) return;
    if ((p['is_posted'] ?? false) == true) return;

    if (_posting.contains(ppId)) return;
    if (!mounted) return;
    setState(() => _posting.add(ppId));

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text("Mark as paid?", style: TextStyle(color: cs.onSurface)),
          content: Text(
            "This will add “$title” (RM ${amount.toStringAsFixed(2)}) to your Transactions.",
            style: TextStyle(color: cs.onSurface.withOpacity(0.75)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("Cancel"),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.check_rounded),
              label: const Text("Done"),
            ),
          ],
        );
      },
    );

    if (confirm != true) {
      if (mounted) setState(() => _posting.remove(ppId));
      return;
    }

    try {
      final inserted = await supabase.from('transactions').insert({
        'user_id': uid,
        'type': 'expense',
        'amount': amount,
        'category': catKey.isEmpty ? 'bills' : catKey,
        'description': 'Planned: $title',
        'date': _startOfDay(dueDate).toIso8601String(),
      }).select('id').single();

      final txId = inserted['id'];

      await NotificationService.instance.cancelPlannedPaymentReminder(
        plannedPaymentId: ppId,
      );

      await NotificationService.instance.plannedPaymentPosted(
        plannedPaymentId: ppId,
        title: title,
        amount: amount,
        category: _prettyCat(catKey),
      );

      await supabase.from('planned_payments').update({
        'is_posted': true,
        'posted_tx_id': txId,
      }).eq('id', ppId);

      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Marked '$title' as paid 🎉"),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to post: $e")));
    } finally {
      if (mounted) setState(() => _posting.remove(ppId));
    }
  }

  Future<void> _openAddEdit({Map<String, dynamic>? existing}) async {
    final uid = userId;
    if (uid == null) return;

    final formKey = GlobalKey<FormState>();
    final titleCtrl = TextEditingController(text: (existing?['title'] ?? '').toString());
    final amountCtrl = TextEditingController(
      text: existing == null ? '' : _asDouble(existing['amount']).toStringAsFixed(2),
    );

    String selectedCat = _normCatKey((existing?['category'] ?? 'bills').toString());
    if (selectedCat.isEmpty) selectedCat = 'bills';

    DateTime due = _startOfDay(
      _parseDate(existing?['due_date'])?.toLocal() ??
          DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
    );

    bool saving = false;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        final t = Theme.of(ctx);
        final cs = t.colorScheme;

        String? amountValidator(String? v) {
          final raw = (v ?? '').trim();
          if (raw.isEmpty) return "Amount is required";
          final n = double.tryParse(raw.replaceAll(',', ''));
          if (n == null) return "Enter a valid number";
          if (n <= 0) return "Amount must be more than 0";
          return null;
        }

        String? titleValidator(String? v) {
          final s = (v ?? '').trim();
          if (s.isEmpty) return "Payment name is required";
          if (s.length < 2) return "Name is too short";
          return null;
        }

        final inputDecoration = InputDecoration(
          filled: true,
          fillColor: cs.surfaceContainerHighest.withOpacity(0.5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: cs.primary, width: 2),
          ),
        );

        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setLocal) {
              return SingleChildScrollView(
                padding: EdgeInsets.only(
                  left: 24,
                  right: 24,
                  top: 8,
                  bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
                ),
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        existing == null ? "Add Planned Payment" : "Edit Payment",
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: titleCtrl,
                        validator: titleValidator,
                        textInputAction: TextInputAction.next,
                        decoration: inputDecoration.copyWith(
                          labelText: "Payment Name",
                          hintText: "e.g., Internet Bill, Rent",
                          prefixIcon: const Icon(Icons.receipt_long_rounded),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: amountCtrl,
                        validator: amountValidator,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: inputDecoration.copyWith(
                          labelText: "Amount",
                          prefixText: "RM ",
                          prefixIcon: const Icon(Icons.payments_outlined),
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        value: selectedCat,
                        validator: (v) => (v == null || v.trim().isEmpty) ? "Category is required" : null,
                        items: kCategories
                            .map((c) => DropdownMenuItem(value: c, child: Text(_prettyCat(c))))
                            .toList(),
                        onChanged: saving ? null : (v) => setLocal(() => selectedCat = v ?? selectedCat),
                        decoration: inputDecoration.copyWith(
                          labelText: "Category",
                          prefixIcon: const Icon(Icons.category_outlined),
                        ),
                        dropdownColor: cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      const SizedBox(height: 16),
                      InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: saving
                            ? null
                            : () async {
                                final picked = await _pickDueDate(ctx, due);
                                if (picked != null) {
                                  setLocal(() => due = picked);
                                }
                              },
                        child: InputDecorator(
                          decoration: inputDecoration.copyWith(
                            labelText: "Due Date",
                            prefixIcon: const Icon(Icons.calendar_month_rounded),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _fmtDate(due),
                                style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurface),
                              ),
                              Text(
                                "Change",
                                style: TextStyle(color: cs.primary, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          onPressed: saving
                              ? null
                              : () async {
                                  if (!(formKey.currentState?.validate() ?? false)) return;
                                  setLocal(() => saving = true);
                                  Navigator.pop(ctx, true);
                                },
                          child: saving
                              ? const SizedBox(
                                  height: 24,
                                  width: 24,
                                  child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                                )
                              : Text(existing == null ? "Add Payment" : "Save Changes",
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );

    if (ok != true) {
      titleCtrl.dispose();
      amountCtrl.dispose();
      return;
    }

    final title = titleCtrl.text.trim();
    final amount = double.tryParse(amountCtrl.text.trim().replaceAll(',', '')) ?? 0;
    final catKey = _normCatKey(selectedCat);
    final dueDate = _startOfDay(due);

    if (title.isEmpty || amount <= 0 || catKey.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please fill all required fields.")));
      titleCtrl.dispose();
      amountCtrl.dispose();
      return;
    }

    try {
      String plannedPaymentId;

      if (existing == null) {
        final inserted = await supabase.from('planned_payments').insert({
          'user_id': uid,
          'title': title,
          'amount': amount,
          'due_date': dueDate.toIso8601String(),
          'category': catKey,
          'is_posted': false,
          'posted_tx_id': null,
        }).select('id').single();

        plannedPaymentId = (inserted['id'] ?? '').toString();
      } else {
        plannedPaymentId = (existing['id'] ?? '').toString();
        final alreadyPosted = (existing['is_posted'] ?? false) == true;
        if (alreadyPosted) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("This payment is already posted.")));
          return;
        }

        await supabase.from('planned_payments').update({
          'title': title,
          'amount': amount,
          'due_date': dueDate.toIso8601String(),
          'category': catKey,
        }).eq('id', plannedPaymentId);
      }

      if (plannedPaymentId.isNotEmpty) {
        await NotificationService.instance.schedulePlannedPaymentReminder(
          plannedPaymentId: plannedPaymentId,
          title: title,
          amount: amount,
          category: _prettyCat(catKey),
          dueDate: dueDate,
          remindDaysBefore: 1,
          hour: 9,
          minute: 0,
        );
      }

      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Save failed: $e")));
    } finally {
      titleCtrl.dispose();
      amountCtrl.dispose();
    }
  }

  Future<bool> _confirmDelete(String title) async {
    return (await showDialog<bool>(
          context: context,
          builder: (ctx) {
            final cs = Theme.of(ctx).colorScheme;
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Text("Delete payment?", style: TextStyle(color: cs.onSurface)),
              content: Text(
                "Delete “$title”? You can’t undo this.",
                style: TextStyle(color: cs.onSurface.withOpacity(0.75)),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text("Cancel"),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: cs.error),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text("Delete"),
                ),
              ],
            );
          },
        )) ??
        false;
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final ppId = (item['id'] ?? '').toString();
    final title = (item['title'] ?? '').toString();

    final ok = await _confirmDelete(title);
    if (!ok) return;

    try {
      if (ppId.isNotEmpty) {
        await NotificationService.instance.cancelPlannedPaymentReminder(plannedPaymentId: ppId);
      }
      await supabase.from('planned_payments').delete().eq('id', ppId);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Payment deleted.")));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Delete failed: $e")));
    }
  }

  Widget _doneButton({required bool postingNow, required VoidCallback onPressed}) {
    return FilledButton.icon(
      onPressed: postingNow ? null : onPressed,
      icon: postingNow
          ? const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
            )
          : const Icon(Icons.check_rounded, size: 18),
      label: Text(postingNow ? "Posting..." : "Mark as Paid"),
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = items.fold<double>(0, (s, p) => s + _asDouble(p['amount']));
    final postedItems = items.where((p) => (p['is_posted'] ?? false) == true).toList();
    final posted = postedItems.fold<double>(0, (s, p) => s + _asDouble(p['amount']));
    final left = (total - posted).clamp(0, double.infinity);
    final pct = total <= 0 ? 0.0 : (posted / total).clamp(0.0, 1.0);

    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text("Planned Payments", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAddEdit(),
        icon: const Icon(Icons.add_rounded),
        label: const Text("Add Payment", style: TextStyle(fontWeight: FontWeight.bold)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                        Text(error!, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text("Try again"),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    children: [
                      _PlannedHeroCard(
                        pct: pct,
                        count: items.length,
                        total: total,
                        posted: posted,
                        remaining: left.toDouble(),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        "Your Payments",
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: cs.onSurface),
                      ),
                      const SizedBox(height: 12),
                      if (items.isEmpty)
                        _PlannedEmptyState(onCreate: () => _openAddEdit())
                      else
                        ...items.map((p) {
                          final ppId = (p['id'] ?? '').toString();
                          final title = (p['title'] ?? '').toString();
                          final amount = _asDouble(p['amount']);
                          final due = _parseDate(p['due_date'])?.toLocal();
                          final dueText = due == null ? "-" : _fmtDate(due);
                          final isPosted = (p['is_posted'] ?? false) == true;
                          final postingNow = _posting.contains(ppId);

                          final catKey = _normCatKey((p['category'] ?? '').toString());
                          final catPretty = _prettyCat(catKey);

                          final now = _startOfDay(DateTime.now());
                          final dueDay = due == null ? null : _startOfDay(due);
                          final daysLeft = (dueDay == null) ? null : dueDay.difference(now).inDays;
                          final isOverdue = (daysLeft != null && daysLeft < 0 && !isPosted);
                          final isSoon = (daysLeft != null && daysLeft >= 0 && daysLeft <= 2 && !isPosted);

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: _PlannedPaymentCardHero(
                              title: title,
                              category: catPretty,
                              dueText: dueText,
                              amount: amount,
                              isPosted: isPosted,
                              isOverdue: isOverdue,
                              isSoon: isSoon,
                              postingNow: postingNow,
                              onDone: () => _markAsPaid(p),
                              onEdit: () => _openAddEdit(existing: p),
                              onDelete: () => _delete(p),
                              doneButton: _doneButton(
                                postingNow: postingNow,
                                onPressed: () => _markAsPaid(p),
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
    );
  }
}

/* ---------------- UI WIDGETS (theme-safe) ---------------- */

class _PlannedHeroCard extends StatelessWidget {
  final double pct;
  final int count;
  final double total;
  final double posted;
  final double remaining;

  const _PlannedHeroCard({
    required this.pct,
    required this.count,
    required this.total,
    required this.posted,
    required this.remaining,
  });

  String _money(double v) => v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final pctText = (pct * 100).toStringAsFixed(2);

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
          BoxShadow(
            color: cs.primary.withOpacity(0.3),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Total Planned",
                    style: TextStyle(color: cs.onPrimary.withOpacity(0.8), fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "RM ${_money(total)}",
                    style: TextStyle(color: cs.onPrimary, fontSize: 32, fontWeight: FontWeight.w900),
                  ),
                ],
              ),
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: cs.onPrimary.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    "$pctText%",
                    style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _HeroMetric(label: "Remaining", value: "RM ${_money(remaining)}", color: cs.onPrimary),
              Container(width: 1, height: 30, color: cs.onPrimary.withOpacity(0.3)),
              _HeroMetric(label: "Posted", value: "RM ${_money(posted)}", color: cs.onPrimary),
              Container(width: 1, height: 30, color: cs.onPrimary.withOpacity(0.3)),
              _HeroMetric(label: "Items", value: count.toString(), color: cs.onPrimary),
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
  final Color color;
  const _HeroMetric({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: color.withOpacity(0.8), fontSize: 11, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w900),
        ),
      ],
    );
  }
}

class _PlannedEmptyState extends StatelessWidget {
  final VoidCallback onCreate;

  const _PlannedEmptyState({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.3),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.5)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.receipt_long_rounded, size: 48, color: cs.primary),
          ),
          const SizedBox(height: 20),
          Text(
            "No planned payments yet",
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: cs.onSurface),
          ),
          const SizedBox(height: 8),
          Text(
            "Add bills like rent, electricity, and subscriptions.\nYou’ll get a reminder one day before.",
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 24),

        ],
      ),
    );
  }
}

class _PlannedPaymentCardHero extends StatelessWidget {
  final String title;
  final String category;
  final String dueText;
  final double amount;
  final bool isPosted;
  final bool isOverdue;
  final bool isSoon;
  final bool postingNow;

  final VoidCallback onDone;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Widget doneButton;

  const _PlannedPaymentCardHero({
    required this.title,
    required this.category,
    required this.dueText,
    required this.amount,
    required this.isPosted,
    required this.isOverdue,
    required this.isSoon,
    required this.postingNow,
    required this.onDone,
    required this.onEdit,
    required this.onDelete,
    required this.doneButton,
  });

  String _money(double v) => v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    Color statusColor;
    Color statusBgColor;
    String statusText;
    IconData statusIcon;

    if (isPosted) {
      statusColor = cs.tertiary; 
      statusBgColor = cs.tertiaryContainer;
      statusText = "Posted";
      statusIcon = Icons.check_circle_rounded;
    } else if (isOverdue) {
      statusColor = cs.error;
      statusBgColor = cs.errorContainer;
      statusText = "Overdue";
      statusIcon = Icons.warning_rounded;
    } else if (isSoon) {
      statusColor = Colors.orange.shade700; 
      statusBgColor = Colors.orange.shade100;
      statusText = "Due soon";
      statusIcon = Icons.schedule_rounded;
    } else {
      statusColor = cs.onSurfaceVariant;
      statusBgColor = cs.surfaceContainerHighest;
      statusText = "Scheduled";
      statusIcon = Icons.calendar_today_rounded;
    }

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: t.shadowColor.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: isOverdue ? cs.error.withOpacity(0.5) : t.dividerColor.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: statusBgColor,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(statusIcon, color: statusColor),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: cs.onSurface),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "$category • Due $dueText",
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_horiz_rounded, color: cs.onSurfaceVariant),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  onSelected: (value) {
                    if (value == 'edit') onEdit();
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'edit',
                      enabled: !isPosted,
                      child: Row(children: [
                        Icon(Icons.edit_outlined, size: 20, color: isPosted ? t.disabledColor : cs.onSurface),
                        const SizedBox(width: 12),
                        Text("Edit Payment", style: TextStyle(color: isPosted ? t.disabledColor : cs.onSurface))
                      ]),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(children: [
                        Icon(Icons.delete_outline, size: 20, color: cs.error),
                        const SizedBox(width: 12),
                        Text("Delete Payment", style: TextStyle(color: cs.error))
                      ]),
                    ),
                  ],
                )
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    "RM ${_money(amount)}",
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: isOverdue ? cs.error : cs.onSurface,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusBgColor.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: statusColor.withOpacity(0.2)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            if (!isPosted) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: doneButton,
              )
            ] else ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.check_circle_outline_rounded, size: 20, color: cs.tertiary),
                    const SizedBox(width: 8),
                    Text(
                      "Successfully Posted",
                      style: TextStyle(
                        color: cs.tertiary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}