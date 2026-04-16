import 'package:supabase_flutter/supabase_flutter.dart';

class NotificationLogService {
  NotificationLogService._();
  static final NotificationLogService instance = NotificationLogService._();

  final _db = Supabase.instance.client;

  String? get _uid => _db.auth.currentUser?.id;

  /// Create ONCE per (user_id + noti_key). If exists -> updates same row (no duplicate).
  Future<void> createOnce({
    required String notiKey,
    required String title,
    required String body,
    String type = "info", // info | warning | danger | success
  }) async {
    final uid = _uid;
    if (uid == null) return;

    await _db.from('notifications').upsert(
      {
        'user_id': uid,
        'noti_key': notiKey,
        'title': title,
        'body': body,
        'type': type,
      },
      onConflict: 'user_id,noti_key',
    );
  }

  /// List my notifications (newest first)
  Future<List<Map<String, dynamic>>> listMine({int limit = 100}) async {
    final uid = _uid;
    if (uid == null) return [];

    final res = await _db
        .from('notifications')
        .select('id, noti_key, title, body, type, created_at, read_at')
        .eq('user_id', uid)
        .order('created_at', ascending: false)
        .limit(limit);

    return List<Map<String, dynamic>>.from(res);
  }

  /// Count unread (read_at IS NULL) — compatible with older Supabase clients
  Future<int> unreadCount() async {
    final uid = _uid;
    if (uid == null) return 0;

    final res = await _db
        .from('notifications')
        .select('id')
        .eq('user_id', uid)
        .filter('read_at', 'is', 'null'); // IMPORTANT: 'null' AS STRING

    return (res as List).length;
  }

  /// Mark one as read (by id OR noti_key)
  Future<void> markRead({String? id, String? notiKey}) async {
    final uid = _uid;
    if (uid == null) return;
    if (id == null && notiKey == null) return;

    var q = _db.from('notifications').update({
      'read_at': DateTime.now().toIso8601String(),
    }).eq('user_id', uid);

    if (id != null) q = q.eq('id', id);
    if (notiKey != null) q = q.eq('noti_key', notiKey);

    await q;
  }

  /// Mark all as read (only rows where read_at IS NULL)
  Future<void> markAllRead() async {
    final uid = _uid;
    if (uid == null) return;

    await _db
        .from('notifications')
        .update({'read_at': DateTime.now().toIso8601String()})
        .eq('user_id', uid)
        .filter('read_at', 'is', 'null'); // IMPORTANT: 'null' AS STRING
  }

  Future<void> deleteByKey(String notiKey) async {
    final uid = _uid;
    if (uid == null) return;

    await _db
        .from('notifications')
        .delete()
        .eq('user_id', uid)
        .eq('noti_key', notiKey);
  }
}