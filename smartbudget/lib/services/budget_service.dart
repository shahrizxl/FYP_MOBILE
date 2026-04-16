import 'package:supabase_flutter/supabase_flutter.dart';

class BudgetService {
  final supa = Supabase.instance.client;

  DateTime monthKey(DateTime m) => DateTime(m.year, m.month, 1);

  Future<List<Map<String, dynamic>>> getBudgets({
    required String userId,
    required DateTime month,
  }) async {
    final mk = monthKey(month).toIso8601String();

    final res = await supa
        .from('budgets')
        .select('id, category, amount, month')
        .eq('user_id', userId)
        .eq('month', mk)
        .order('category');

    return List<Map<String, dynamic>>.from(res);
  }

  Future<void> setBudget({
    required String userId,
    required DateTime month,
    required String category,
    required double amount,
  }) async {
    final mk = monthKey(month).toIso8601String();

    await supa.from('budgets').upsert({
      'user_id': userId,
      'category': category,
      'amount': amount,
      'month': mk,
    }, onConflict: 'user_id,category,month');
  }

  Future<void> deleteBudget({
    required String userId,
    required DateTime month,
    required String category,
  }) async {
    final mk = monthKey(month).toIso8601String();

    await supa
        .from('budgets')
        .delete()
        .eq('user_id', userId)
        .eq('category', category)
        .eq('month', mk);
  }
}