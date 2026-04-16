import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// Assuming this is your service, left intact:
import '../services/noti_log.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool loading = true;
  String? error;
  List<Map<String, dynamic>> items = [];

  // Prevent multiple dialogs stacking (double-tap)
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    return null;
  }

  String _timeText(Map<String, dynamic> n) {
    final dt = _parseDate(n['created_at'])?.toLocal();
    if (dt == null) return "";
    
    final now = DateTime.now();
    final difference = now.difference(dt);
    
    // Friendly time formatting
    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        if (difference.inMinutes <= 1) return "Just now";
        return "${difference.inMinutes}m ago";
      }
      return "${difference.inHours}h ago";
    } else if (difference.inDays == 1) {
      return "Yesterday, ${DateFormat("HH:mm").format(dt)}";
    }
    return DateFormat("dd MMM • HH:mm").format(dt);
  }

  bool _isUnread(Map<String, dynamic> n) => n['read_at'] == null;

  IconData _iconForType(String t) {
    switch (t) {
      case "success": return Icons.check_circle_rounded;
      case "warning": return Icons.warning_rounded;
      case "danger": return Icons.error_rounded;
      default: return Icons.info_rounded;
    }
  }

  Color _colorForType(BuildContext context, String t) {
    final cs = Theme.of(context).colorScheme;
    switch (t) {
      case "success": return Colors.green.shade600;
      case "warning": return Colors.orange.shade600;
      case "danger": return cs.error;
      default: return cs.primary;
    }
  }

  Color _bgColorForType(BuildContext context, String t) {
    final cs = Theme.of(context).colorScheme;
    switch (t) {
      case "success": return Colors.green.shade100;
      case "warning": return Colors.orange.shade100;
      case "danger": return cs.errorContainer;
      default: return cs.primaryContainer;
    }
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      final data = await NotificationLogService.instance.listMine(limit: 200);
      if (!mounted) return;
      setState(() => items = data);
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString().replaceAll("Exception: ", ""));
    } finally {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  Future<void> _markAllRead() async {
    try {
      await NotificationLogService.instance.markAllRead();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.checklist_rounded, color: Colors.white),
              SizedBox(width: 8),
              Text("All caught up!"),
            ],
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    }
  }

  Future<void> _openNotif(int index) async {
    if (_dialogOpen) return;
    if (index < 0 || index >= items.length) return;

    final n = items[index];

    final id = n['id']?.toString();
    final notiKey = n['noti_key']?.toString();
    final title = (n['title'] ?? '').toString();
    final body = (n['body'] ?? '').toString();
    final type = (n['type'] ?? 'info').toString();

    // mark as read
    if (_isUnread(n)) {
      try {
        await NotificationLogService.instance.markRead(id: id, notiKey: notiKey);
      } catch (_) {}

      if (!mounted) return;
      if (index >= 0 && index < items.length) {
        setState(() {
          items[index] = {
            ...items[index],
            'read_at': DateTime.now().toIso8601String(),
          };
        });
      }
    }

    if (!mounted) return;

    _dialogOpen = true;
    final cs = Theme.of(context).colorScheme;

    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          icon: Icon(_iconForType(type), color: _colorForType(context, type), size: 36),
          title: Text(title.isEmpty ? "Notification" : title, style: const TextStyle(fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Text(
              body.isEmpty ? "—" : body,
              style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
              textAlign: TextAlign.center,
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: cs.error),
              onPressed: () {
                Navigator.of(dialogCtx).pop();
                _delete(n); // Delete straight from dialog
              },
              child: const Text("Delete"),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text("Got it"),
            ),
          ],
        );
      },
    );

    _dialogOpen = false;
  }

  // ✅ Upgraded delete function to use notification map instead of index for safety
  Future<void> _delete(Map<String, dynamic> noti) async {
    if (_dialogOpen) return;
    
    final notiKey = (noti['noti_key'] ?? '').toString();
    if (notiKey.isEmpty) return;

    // Optimistic UI update for smooth swiping/tapping
    setState(() {
      items.removeWhere((item) => item['noti_key'] == notiKey);
    });

    try {
      await NotificationLogService.instance.deleteByKey(notiKey);
    } catch (e) {
      if (!mounted) return;
      // Revert on failure
      await _load(); 
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Delete error: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final unread = items.where(_isUnread).length;

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text("Notifications", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          if (unread > 0)
            TextButton.icon(
              onPressed: _markAllRead,
              icon: const Icon(Icons.done_all_rounded, size: 18),
              label: const Text("Read All", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          const SizedBox(width: 8),
        ],
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
                        Text("Something went wrong", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: cs.error)),
                        const SizedBox(height: 8),
                        Text(error!, textAlign: TextAlign.center, style: TextStyle(color: t.hintColor)),
                        const SizedBox(height: 24),
                        FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: const Text("Retry")),
                      ],
                    ),
                  ),
                )
              : items.isEmpty
                  ? Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
                        margin: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: t.dividerColor.withOpacity(0.5)),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(color: cs.primaryContainer, shape: BoxShape.circle),
                              child: Icon(Icons.notifications_off_outlined, size: 48, color: cs.primary),
                            ),
                            const SizedBox(height: 20),
                            const Text("No notifications yet", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Text(
                              "You’ll see budget alerts, payment reminders, and insights here.",
                              textAlign: TextAlign.center,
                              style: TextStyle(color: t.hintColor, height: 1.4),
                            ),
                            const SizedBox(height: 24),
                            OutlinedButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text("Refresh"),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, i) {
                          final n = items[i];
                          final type = (n['type'] ?? 'info').toString();
                          final title = (n['title'] ?? '').toString();
                          final body = (n['body'] ?? '').toString();
                          final time = _timeText(n);
                          final isUnread = _isUnread(n);

                          final icon = _iconForType(type);
                          final color = _colorForType(context, type);
                          final bgColor = _bgColorForType(context, type);

                          return Dismissible(
                            key: Key(n['noti_key']?.toString() ?? UniqueKey().toString()),
                            direction: DismissDirection.endToStart,
                            onDismissed: (_) => _delete(n), // ✅ Uses the map object now
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 24),
                              decoration: BoxDecoration(
                                color: cs.error,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 28),
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(20),
                              onTap: () => _openNotif(i),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: isUnread ? cs.primary.withOpacity(0.3) : t.dividerColor.withOpacity(0.4)),
                                  color: isUnread ? cs.primaryContainer.withOpacity(0.3) : cs.surface,
                                  boxShadow: [
                                    BoxShadow(color: t.shadowColor.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2))
                                  ],
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
                                      child: Icon(icon, color: color, size: 22),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            title.isEmpty ? "Notification" : title,
                                            style: TextStyle(
                                              fontWeight: isUnread ? FontWeight.w900 : FontWeight.bold,
                                              fontSize: 16,
                                              color: cs.onSurface,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            body.isEmpty ? "—" : body,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: cs.onSurfaceVariant,
                                              fontWeight: isUnread ? FontWeight.w600 : FontWeight.normal,
                                              height: 1.3,
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          Row(
                                            children: [
                                              Text(
                                                time,
                                                style: TextStyle(
                                                  color: t.hintColor,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              if (isUnread) ...[
                                                const SizedBox(width: 8),
                                                Container(
                                                  width: 8,
                                                  height: 8,
                                                  decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
                                                ),
                                              ]
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    // ✅ Explicit Delete Button
                                    IconButton(
                                      icon: Icon(Icons.close_rounded, color: t.hintColor, size: 20),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => _delete(n),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}