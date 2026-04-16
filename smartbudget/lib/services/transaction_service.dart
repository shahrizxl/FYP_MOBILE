// transaction_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

class TransactionService {
  final supabase = Supabase.instance.client;

  Future<void> addTransaction({
    required String userId,
    required DateTime date,
    required String description,
    required String type,
    required double amount,
    required String category,
  }) async {
    await supabase.from('transactions').insert({
      'user_id': userId,
      'date': _toYmd(date),
      'description': description.trim(),
      'type': type,
      'amount': amount,
      'category': category.trim(),
    });
  }

  Future<void> updateTransaction({
    required dynamic txId, // ✅ int or String
    required DateTime date,
    required String description,
    required String type,
    required double amount,
    required String category,
  }) async {
    await supabase.from('transactions').update({
      'date': _toYmd(date),
      'description': description.trim(),
      'type': type,
      'amount': amount,
      'category': category.trim(),
    }).eq('id', txId);
  }

  Future<void> deleteTransaction(dynamic txId) async {
    await supabase.from('transactions').delete().eq('id', txId);
  }

  Future<List<Map<String, dynamic>>> getMyTransactions(String userId) async {
    final res = await supabase
        .from('transactions')
        .select('id, user_id, date, description, type, amount, category')
        .eq('user_id', userId)
        .order('date', ascending: false);

    return List<Map<String, dynamic>>.from(res);
  }

  static String _toYmd(DateTime d) {
    final dd = DateTime(d.year, d.month, d.day);
    return dd.toIso8601String().substring(0, 10);
  }
}