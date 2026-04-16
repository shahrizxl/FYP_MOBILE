import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Standalone page (no wrapper needed)

class SavingGoalsPage extends StatefulWidget {
  const SavingGoalsPage({super.key});

  @override
  State<SavingGoalsPage> createState() => _SavingGoalsPageState();
}

class _SavingGoalsPageState extends State<SavingGoalsPage> {
  bool loading = true;
  String? error;
  List<Map<String, dynamic>> goals = [];

  final _currency = NumberFormat.currency(locale: "en_MY", symbol: "RM ");

  String? get userId => Supabase.instance.client.auth.currentUser?.id;

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  String _money(double v) => _currency.format(v);

  void _snack(String msg) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: cs.inverseSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  Future<void> loadGoals() async {
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
          .from('saving_goals')
          .select('id, title, target_amount, current_amount, created_at')
          .eq('user_id', uid)
          .order('created_at', ascending: false);

      if (!mounted) return;
      setState(() {
        goals = List<Map<String, dynamic>>.from(res);
      });
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() => error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> upsertGoal({
    String? id,
    required String title,
    required double target,
    required double current,
  }) async {
    final uid = userId;
    if (uid == null) return;

    try {
      await Supabase.instance.client.from('saving_goals').upsert(
        {
          if (id != null) 'id': id,
          'user_id': uid,
          'title': title,
          'target_amount': target,
          'current_amount': current,
        },
        onConflict: 'id',
      );

      await loadGoals();
      _snack(id == null ? "Goal created successfully 🎉" : "Goal updated.");
    } on PostgrestException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<void> deleteGoal(String id) async {
    final uid = userId;
    if (uid == null) return;

    try {
      await Supabase.instance.client
          .from('saving_goals')
          .delete()
          .eq('user_id', uid)
          .eq('id', id);

      await loadGoals();
      _snack("Goal deleted.");
    } on PostgrestException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack(e.toString());
    }
  }

  Future<bool> _confirmDelete(String title) async {
    final cs = Theme.of(context).colorScheme;
    return (await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text("Delete goal?"),
            content: Text("This will permanently delete “$title”. You can’t undo this."),
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
          ),
        )) ??
        false;
  }

  double _readMoney(String raw) {
    final cleaned = raw.trim().replaceAll(',', '');
    return double.tryParse(cleaned) ?? 0;
  }

  Future<void> openGoalSheet({Map<String, dynamic>? goal}) async {
    final titleCtrl = TextEditingController(text: (goal?['title'] ?? '').toString());
    final targetCtrl = TextEditingController(
      text: goal != null ? _asDouble(goal['target_amount']).toStringAsFixed(2) : '',
    );
    final currentCtrl = TextEditingController(
      text: goal != null ? _asDouble(goal['current_amount']).toStringAsFixed(2) : '',
    );

    final titleFocus = FocusNode();
    final targetFocus = FocusNode();
    final currentFocus = FocusNode();

    bool saving = false;

    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final t = Theme.of(context);
            final cs = t.colorScheme;

            final target = _readMoney(targetCtrl.text);
            final current = _readMoney(currentCtrl.text);
            final pct = (target <= 0) ? 0.0 : (current / target).clamp(0.0, 1.0);
            final pctText = "${(pct * 100).toStringAsFixed(0)}%";
            final remaining = (target - current);
            final remainingSafe = remaining < 0 ? 0.0 : remaining;

            Future<void> doSave() async {
              final title = titleCtrl.text.trim();
              final tVal = _readMoney(targetCtrl.text);
              final cVal = _readMoney(currentCtrl.text);

              if (title.isEmpty) {
                _snack("Please give your goal a title.");
                return;
              }
              if (tVal <= 0) {
                _snack("Target must be more than RM 0.");
                return;
              }
              if (cVal < 0) {
                _snack("Current saved can’t be negative.");
                return;
              }

              setSheet(() => saving = true);

              await upsertGoal(
                id: goal?['id']?.toString(),
                title: title,
                target: tVal,
                current: cVal,
              );

              if (ctx.mounted) Navigator.pop(ctx);
            }

            final inputDecoration = InputDecoration(
              filled: true,
              fillColor: cs.surfaceContainerHighest.withOpacity(0.55),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(color: cs.primary, width: 2),
              ),
            );

            return Padding(
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 8,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        goal == null ? "Create New Goal" : "Edit Goal",
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: cs.onSurface,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          color: cs.primaryContainer,
                        ),
                        child: Text(
                          pctText,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Remaining to target: ${_money(remainingSafe)}",
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: titleCtrl,
                    focusNode: titleFocus,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => targetFocus.requestFocus(),
                    decoration: inputDecoration.copyWith(
                      labelText: "Goal Title",
                      hintText: "e.g. Emergency Fund, Vacation",
                      prefixIcon: const Icon(Icons.flag_rounded),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: targetCtrl,
                    focusNode: targetFocus,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      // allow digits + dot, and commas (so you can type 1,000.50)
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9\.,]')),
                    ],
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => currentFocus.requestFocus(),
                    onChanged: (_) => setSheet(() {}),
                    decoration: inputDecoration.copyWith(
                      labelText: "Target Amount",
                      prefixText: "RM ",
                      prefixIcon: const Icon(Icons.track_changes_rounded),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: currentCtrl,
                    focusNode: currentFocus,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9\.,]')),
                    ],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => doSave(),
                    onChanged: (_) => setSheet(() {}),
                    decoration: inputDecoration.copyWith(
                      labelText: "Currently Saved",
                      prefixText: "RM ",
                      prefixIcon: const Icon(Icons.savings_rounded),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 8,
                      backgroundColor: cs.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
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
                      onPressed: saving ? null : doSave,
                      child: saving
                          ? SizedBox(
                              height: 24,
                              width: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: cs.onPrimary,
                              ),
                            )
                          : const Text(
                              "Save Goal",
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    titleCtrl.dispose();
    targetCtrl.dispose();
    currentCtrl.dispose();
    titleFocus.dispose();
    targetFocus.dispose();
    currentFocus.dispose();
  }

  @override
  void initState() {
    super.initState();
    loadGoals();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final totalSaved = goals.fold<double>(0, (sum, g) => sum + _asDouble(g['current_amount']));
    final totalTarget = goals.fold<double>(0, (sum, g) => sum + _asDouble(g['target_amount']));
    final overallPct = (totalTarget <= 0) ? 0.0 : (totalSaved / totalTarget).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text("Saving Goals", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openGoalSheet(),
        icon: const Icon(Icons.add_rounded),
        label: const Text("New Goal", style: TextStyle(fontWeight: FontWeight.bold)),
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
                        Text(error!, textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: loadGoals,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text("Try again"),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: loadGoals,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    children: [
                      _HeroSummaryCard(
                        goalsCount: goals.length,
                        totalSaved: totalSaved,
                        totalTarget: totalTarget,
                        overallPct: overallPct,
                        money: _money,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        "Your Goals",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (goals.isEmpty)
                        _EmptyStateNice(onCreate: () => openGoalSheet())
                      else
                        ...goals.map((g) {
                          final id = (g['id'] ?? '').toString();
                          final title = (g['title'] ?? '').toString();
                          final target = _asDouble(g['target_amount']);
                          final current = _asDouble(g['current_amount']);
                          final pct = (target <= 0) ? 0.0 : (current / target).clamp(0.0, 1.0);
                          final remainingSafe = (target - current) < 0 ? 0.0 : (target - current);

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: _GoalCardNiceV2(
                              title: title,
                              target: target,
                              current: current,
                              pct: pct,
                              remaining: remainingSafe,
                              money: _money,
                              onEdit: () => openGoalSheet(goal: g),
                              onDelete: () async {
                                final ok = await _confirmDelete(title);
                                if (!ok) return;
                                await deleteGoal(id);
                              },
                            ),
                          );
                        }),
                    ],
                  ),
                ),
    );
  }
}

// ===================== UI widgets =====================

class _HeroSummaryCard extends StatelessWidget {
  final int goalsCount;
  final double totalSaved;
  final double totalTarget;
  final double overallPct;
  final String Function(double) money;

  const _HeroSummaryCard({
    required this.goalsCount,
    required this.totalSaved,
    required this.totalTarget,
    required this.overallPct,
    required this.money,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final pctText = "${(overallPct * 100).toStringAsFixed(0)}%";

    // Use subtle elevation in dark mode to avoid “too bright gradient”
    final isDark = t.brightness == Brightness.dark;
    final shadowOpacity = isDark ? 0.18 : 0.30;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          colors: [
            cs.primary,
            cs.tertiary,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withOpacity(shadowOpacity),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: DefaultTextStyle(
        style: TextStyle(color: cs.onPrimary),
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
                      "Total Savings",
                      style: TextStyle(
                        color: cs.onPrimary.withOpacity(0.85),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      money(totalSaved),
                      style: TextStyle(
                        color: cs.onPrimary,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: cs.onPrimary.withOpacity(isDark ? 0.14 : 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      pctText,
                      style: TextStyle(
                        color: cs.onPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _HeroMetric(label: "Target", value: money(totalTarget)),
                Container(width: 1, height: 30, color: cs.onPrimary.withOpacity(0.35)),
                _HeroMetric(label: "Active Goals", value: goalsCount.toString()),
              ],
            )
          ],
        ),
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
        Text(
          label,
          style: TextStyle(
            color: cs.onPrimary.withOpacity(0.85),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: cs.onPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _EmptyStateNice extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyStateNice({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.35),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
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
            child: Icon(
              Icons.savings_outlined,
              size: 48,
              color: cs.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            "No saving goals yet",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Create your first goal and track your progress.\nTip: Start with an “Emergency Fund”.",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
      
        ],
      ),
    );
  }
}

class _GoalCardNiceV2 extends StatelessWidget {
  final String title;
  final double target;
  final double current;
  final double pct;
  final double remaining;
  final String Function(double) money;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _GoalCardNiceV2({
    required this.title,
    required this.target,
    required this.current,
    required this.pct,
    required this.remaining,
    required this.money,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final pctText = "${(pct * 100).toStringAsFixed(0)}%";
    final done = pct >= 1.0;

    final accentBg = done ? cs.tertiaryContainer : cs.secondaryContainer;
    final accentFg = done ? cs.onTertiaryContainer : cs.onSecondaryContainer;
    final barColor = done ? cs.tertiary : cs.primary;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: t.shadowColor.withOpacity(t.brightness == Brightness.dark ? 0.12 : 0.06),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
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
                    color: accentBg,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    done ? Icons.emoji_events_rounded : Icons.track_changes_rounded,
                    color: accentFg,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "${money(current)} of ${money(target)}",
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
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
                    const PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(Icons.edit_outlined, size: 20),
                          SizedBox(width: 12),
                          Text("Edit Goal"),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, size: 20),
                          SizedBox(width: 12),
                          Text("Delete Goal"),
                        ],
                      ),
                    ),
                  ],
                )
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 10,
                      backgroundColor: cs.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(barColor),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  pctText,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: barColor,
                  ),
                ),
              ],
            ),
            if (!done) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.outlineVariant.withOpacity(0.6)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Remaining to save",
                      style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w500),
                    ),
                    Text(
                      money(remaining),
                      style: TextStyle(fontWeight: FontWeight.bold, color: cs.onSurface),
                    ),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    "Goal Achieved! 🎉",
                    style: TextStyle(
                      color: cs.onTertiaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}