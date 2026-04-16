import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Assuming this is your service, left intact:
import '../services/transaction_service.dart';

class AddTransactionPage extends StatefulWidget {
  final Map<String, dynamic>? transaction; // null = add, not null = edit
  const AddTransactionPage({super.key, this.transaction});

  @override
  State<AddTransactionPage> createState() => _AddTransactionPageState();
}

class _AddTransactionPageState extends State<AddTransactionPage> {
  final txService = TransactionService();

  final descCtrl = TextEditingController();
  final amountCtrl = TextEditingController();

  String type = "expense";
  DateTime date = DateTime.now();

  bool loading = false;
  String? error;

  bool get isEdit => widget.transaction != null;

  final List<String> categories = const [
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

  // Visual mapping for the bottom sheet picker
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
    "income": Icons.attach_money_rounded,
    "other": Icons.category_rounded,
  };

  String selectedCategory = "food";

  @override
  void initState() {
    super.initState();

    final t = widget.transaction;
    if (t != null) {
      type = (t['type'] ?? 'expense').toString();
      descCtrl.text = (t['description'] ?? '').toString();
      amountCtrl.text = (t['amount'] ?? '').toString();

      final rawCat = (t['category'] ?? '').toString();
      selectedCategory = categories.contains(rawCat) ? rawCat : "other";

      final rawDate = t['date'];
      if (rawDate != null) {
        final parsed = DateTime.tryParse(rawDate.toString());
        if (parsed != null) {
          date = DateTime(parsed.year, parsed.month, parsed.day);
        }
      }
    }
  }

  @override
  void dispose() {
    descCtrl.dispose();
    amountCtrl.dispose();
    super.dispose();
  }

  Future<void> pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        date = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text("Select Category", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 0.85,
                  ),
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final cat = categories[index];
                    final isSelected = cat == selectedCategory;
                    final cs = Theme.of(context).colorScheme;

                    return InkWell(
                      onTap: () => Navigator.pop(context, cat),
                      borderRadius: BorderRadius.circular(16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isSelected ? cs.primary : cs.surfaceContainerHighest.withOpacity(0.5),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              categoryIcons[cat] ?? Icons.category,
                              color: isSelected ? cs.onPrimary : cs.onSurfaceVariant,
                              size: 28,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _prettyCategory(cat),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              color: isSelected ? cs.primary : cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    if (picked != null && picked != selectedCategory) {
      setState(() => selectedCategory = picked);
    }
  }

  double? _parseAmount(String s) {
    final clean = s.trim().replaceAll(',', '.');
    return double.tryParse(clean);
  }

  bool _validate() {
    if (descCtrl.text.trim().isEmpty) {
      setState(() => error = "Description cannot be empty.");
      return false;
    }

    final amt = _parseAmount(amountCtrl.text);
    if (amt == null || amt <= 0) {
      setState(() => error = "Amount must be greater than 0.");
      return false;
    }

    if (selectedCategory.isEmpty) {
      setState(() => error = "Please select a category.");
      return false;
    }

    return true;
  }

  Future<void> save() async {
    if (!_validate()) {
      _showErrorSnackBar(error!);
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      _showErrorSnackBar("Session expired. Please login again.");
      return;
    }

    setState(() {
      loading = true;
      error = null;
    });

    try {
      final amt = _parseAmount(amountCtrl.text)!;

      if (isEdit) {
        await txService.updateTransaction(
          txId: widget.transaction!['id'].toString(),
          date: date,
          description: descCtrl.text.trim(),
          type: type,
          amount: amt,
          category: selectedCategory,
        );
      } else {
        await txService.addTransaction(
          userId: user.id,
          date: date,
          description: descCtrl.text.trim(),
          type: type,
          amount: amt,
          category: selectedCategory,
        );
      }

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => error = e.toString());
      _showErrorSnackBar(error!);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _showErrorSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(msg)),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  static String _prettyCategory(String c) {
    final parts = c.split('_');
    return parts.map((p) => p.isEmpty ? p : "${p[0].toUpperCase()}${p.substring(1)}").join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final isIncome = type == 'income';
    
    // Dynamic coloring based on Income/Expense
    final amountColor = isIncome ? Colors.green.shade600 : cs.primary;

    final dateText = DateFormat("dd MMM yyyy").format(date);

    InputDecoration _themedInput({required String labelText, required IconData prefixIcon}) {
      return InputDecoration(
        labelText: labelText,
        prefixIcon: Icon(prefixIcon, color: cs.primary),
        filled: true,
        fillColor: cs.surfaceContainerHighest.withOpacity(0.3),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: cs.primary, width: 2)),
      );
    }

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: Text(isEdit ? "Edit Transaction" : "Add Transaction", style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton.icon(
                  onPressed: loading ? null : save,
                  icon: loading 
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Icon(isEdit ? Icons.save_rounded : Icons.check_circle_rounded),
                  label: Text(
                    loading ? "Saving..." : (isEdit ? "Save Changes" : "Save Transaction"),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                ),
              ),
              if (isEdit) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: TextButton(
                    onPressed: loading ? null : () => Navigator.pop(context),
                    child: Text("Cancel", style: TextStyle(color: t.hintColor, fontWeight: FontWeight.bold)),
                  ),
                ),
              ]
            ],
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 10),
              
              // Segmented Toggle for Income/Expense
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() {
                          type = "expense";
                          if (selectedCategory == "income") selectedCategory = "food"; // reset category if switching
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: !isIncome ? cs.surface : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: !isIncome ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4)] : [],
                          ),
                          child: Center(
                            child: Text(
                              "Expense",
                              style: TextStyle(fontWeight: FontWeight.bold, color: !isIncome ? cs.primary : t.hintColor),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() {
                          type = "income";
                          selectedCategory = "income"; // Auto select income category
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: isIncome ? cs.surface : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: isIncome ? [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4)] : [],
                          ),
                          child: Center(
                            child: Text(
                              "Income",
                              style: TextStyle(fontWeight: FontWeight.bold, color: isIncome ? Colors.green.shade700 : t.hintColor),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 40),
              
              // Hero Amount Input
              Text("Amount", style: TextStyle(color: t.hintColor, fontWeight: FontWeight.w600)),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}$'))],
                textAlign: TextAlign.center,
                autofocus: !isEdit,
                style: TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.w900,
                  color: amountColor,
                  height: 1.2,
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: "0.00",
                  hintStyle: TextStyle(color: cs.onSurface.withOpacity(0.2)),
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(top: 8.0, left: 16, right: 8),
                    child: Text(
                      "RM",
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: amountColor.withOpacity(0.5)),
                    ),
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                ),
              ),

              const SizedBox(height: 40),

              // Details Form inside a unified Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: t.dividerColor.withOpacity(0.4)),
                  boxShadow: [BoxShadow(color: t.shadowColor.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))],
                ),
                child: Column(
                  children: [
                    TextField(
                      controller: descCtrl,
                      textInputAction: TextInputAction.done,
                      decoration: _themedInput(
                        labelText: "Description",
                        prefixIcon: Icons.notes_rounded,
                      ).copyWith(hintText: "e.g., Grocery run, Salary"),
                    ),
                    const SizedBox(height: 16),

                    // Category Bottom Sheet Trigger
                    InkWell(
                      onTap: _pickCategory,
                      borderRadius: BorderRadius.circular(16),
                      child: InputDecorator(
                        decoration: _themedInput(labelText: "Category", prefixIcon: categoryIcons[selectedCategory] ?? Icons.category_rounded),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _prettyCategory(selectedCategory),
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                            ),
                            Icon(Icons.keyboard_arrow_down_rounded, color: t.hintColor),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Date Picker Trigger
                    InkWell(
                      onTap: pickDate,
                      borderRadius: BorderRadius.circular(16),
                      child: InputDecorator(
                        decoration: _themedInput(labelText: "Date", prefixIcon: Icons.calendar_month_rounded),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              dateText,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                            ),
                            Icon(Icons.edit_calendar_rounded, color: t.hintColor, size: 20),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}