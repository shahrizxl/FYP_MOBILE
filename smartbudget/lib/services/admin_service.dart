import '../supabase_config.dart';

class AdminService {
  Future<List<Map<String, dynamic>>> fetchAllUsers() async {
    final response = await SupabaseConfig.client
        .from('profiles')
        .select('id, email, role, is_active, created_at')
        .eq('role', 'user') // hide admins
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(response);
  }

  Future<void> setUserActive(String userId, bool active) async {
    await SupabaseConfig.client
        .from('profiles')
        .update({'is_active': active})
        .eq('id', userId);
  }

  /// Soft delete: remove transactions + disable user
  Future<void> deleteUser(String userId) async {
    // 1) delete related data first (avoid FK constraint errors)
    await SupabaseConfig.client
        .from('transactions')
        .delete()
        .eq('user_id', userId);

    await SupabaseConfig.client
        .from('budgets')
        .delete()
        .eq('user_id', userId);

    // 2) disable user (can't delete auth user from client safely)
    await SupabaseConfig.client
        .from('profiles')
        .update({'is_active': false})
        .eq('id', userId);
  }
}