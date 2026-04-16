import 'package:supabase_flutter/supabase_flutter.dart';

class StreakData {
  final int streak;
  final int bestStreak;
  final int level;
  final int xp;
  final DateTime? lastActiveDate;

  const StreakData({
    required this.streak,
    required this.bestStreak,
    required this.level,
    required this.xp,
    required this.lastActiveDate,
  });

  factory StreakData.fromMap(Map<String, dynamic> m) {
    DateTime? d;
    if (m['last_active_date'] != null) {
      d = DateTime.tryParse(m['last_active_date'].toString());
    }

    return StreakData(
      streak: (m['streak_count'] ?? 0).toInt(),
      bestStreak: (m['best_streak'] ?? 0).toInt(),
      level: (m['level'] ?? 1).toInt(),
      xp: (m['xp'] ?? 0).toInt(),
      lastActiveDate: d,
    );
  }
}

class StreakService {
  final SupabaseClient supabase;
  StreakService(this.supabase);

  // ===== Main Logic Delegated to Secure DB RPC =====
  Future<StreakData> touchToday() async {
    final user = supabase.auth.currentUser;
    if (user == null) {
      throw Exception("No user logged in");
    }

    // Call the Postgres function to handle calculation securely
    final res = await supabase.rpc('increment_user_streak');
    
    return StreakData.fromMap(res as Map<String, dynamic>);
  }

  Future<StreakData?> getStreak() async {
    final user = supabase.auth.currentUser;
    if (user == null) return null;

    final res = await supabase
        .from('user_streaks')
        .select()
        .eq('user_id', user.id)
        .maybeSingle();

    if (res == null) return null;
    return StreakData.fromMap(res);
  }
}