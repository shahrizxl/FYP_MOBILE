import '../supabase_config.dart';

class ProfileService {
  Future<Map<String, dynamic>> getProfile(String userId) async {
    return await SupabaseConfig.client
        .from('profiles')
        .select('role,is_active')
        .eq('id', userId)
        .single();
  }
}