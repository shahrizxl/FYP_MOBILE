import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/noti_log.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() =>
      _NotificationsPageState();
}

class _NotificationsPageState
    extends State<NotificationsPage> {
  bool loading = true;
  String? error;
  List<Map<String, dynamic>> items = [];

  bool _dialogOpen = false;

  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();

    _load();
    _listenRealtime();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    WidgetsBinding.instance
        .addPostFrameCallback((_) {
      _load();
    });
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  void _listenRealtime() {
    final uid = Supabase
        .instance.client.auth.currentUser?.id;

    if (uid == null) return;

    _channel = Supabase.instance.client
        .channel('notifications-live')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: uid,
          ),
          callback: (_) async {
            await _load();
          },
        )
        .subscribe();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }

    try {
      final data =
          await NotificationLogService.instance
              .listMine(limit: 200);

      if (!mounted) return;

      setState(() {
        items = data;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        error = e
            .toString()
            .replaceAll("Exception: ", "");
      });
    } finally {
      if (!mounted) return;

      setState(() {
        loading = false;
      });
    }
  }

  DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    if (v is int) {
      return DateTime.fromMillisecondsSinceEpoch(v);
    }
    return null;
  }

  String _timeText(
      Map<String, dynamic> n) {
    final dt =
        _parseDate(n['created_at'])?.toLocal();

    if (dt == null) return "";

    final now = DateTime.now();
    final difference =
        now.difference(dt).abs();

    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        if (difference.inMinutes < 1) {
          return "Just now";
        }
        return "${difference.inMinutes}m ago";
      }

      return "${difference.inHours}h ago";
    }

    if (difference.inDays == 1) {
      return "Yesterday, "
          "${DateFormat("HH:mm").format(dt)}";
    }

    return DateFormat("dd MMM • HH:mm")
        .format(dt);
  }

  bool _isUnread(
    Map<String, dynamic> n,
  ) =>
      n['read_at'] == null;

  IconData _iconForType(String t) {
    switch (t) {
      case "success":
        return Icons.check_circle_rounded;

      case "warning":
        return Icons.warning_rounded;

      case "danger":
        return Icons.error_rounded;

      default:
        return Icons.info_rounded;
    }
  }

  Color _colorForType(
    BuildContext context,
    String t,
  ) {
    final cs =
        Theme.of(context).colorScheme;

    switch (t) {
      case "success":
        return Colors.green.shade600;

      case "warning":
        return Colors.orange.shade600;

      case "danger":
        return cs.error;

      default:
        return cs.primary;
    }
  }

  Color _bgColorForType(
    BuildContext context,
    String t,
  ) {
    final cs =
        Theme.of(context).colorScheme;

    switch (t) {
      case "success":
        return Colors.green.shade100;

      case "warning":
        return Colors.orange.shade100;

      case "danger":
        return cs.errorContainer;

      default:
        return cs.primaryContainer;
    }
  }

  Future<void> _markAllRead() async {
    try {
      await NotificationLogService.instance
          .markAllRead();

      await _load();

      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(
                Icons.checklist_rounded,
                color: Colors.white,
              ),
              SizedBox(width: 8),
              Text("All caught up!"),
            ],
          ),
          backgroundColor:
              Theme.of(context)
                  .colorScheme
                  .primary,
          behavior:
              SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(12),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text("Error: $e"),
        ),
      );
    }
  }

  Future<void> _openNotif(
      int index) async {
    if (_dialogOpen) return;
    if (index >= items.length) return;

    final n = items[index];

    final id =
        n['id']?.toString();
    final notiKey =
        n['noti_key']?.toString();

    final title =
        (n['title'] ?? '')
            .toString();

    final body =
        (n['body'] ?? '')
            .toString();

    final type =
        (n['type'] ?? 'info')
            .toString();

    if (_isUnread(n)) {
      try {
        await NotificationLogService
            .instance
            .markRead(
          id: id,
          notiKey: notiKey,
        );
      } catch (_) {}

      if (mounted) {
        setState(() {
          items[index] = {
            ...items[index],
            'read_at':
                DateTime.now()
                    .toIso8601String(),
          };
        });
      }
    }

    _dialogOpen = true;

    await showDialog(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(24),
          ),
          icon: Icon(
            _iconForType(type),
            color: _colorForType(
                context, type),
            size: 36,
          ),
          title: Text(
            title.isEmpty
                ? "Notification"
                : title,
            style: const TextStyle(
              fontWeight:
                  FontWeight.bold,
            ),
          ),
          content: Text(
            body.isEmpty
                ? "—"
                : body,
            textAlign:
                TextAlign.center,
          ),
          actionsAlignment:
              MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.pop(
                    dialogCtx);

                _dialogOpen =
                    false;

                await _delete(n);
              },
              child:
                  const Text("Delete"),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(
                      dialogCtx),
              child:
                  const Text("Got it"),
            ),
          ],
        );
      },
    );

    _dialogOpen = false;
  }

  Future<void> _delete(
    Map<String, dynamic> n,
  ) async {
    final key =
        (n['noti_key'] ?? '')
            .toString();

    if (key.isEmpty) return;

    setState(() {
      items.removeWhere(
        (e) =>
            e['noti_key'] == key,
      );
    });

    try {
      await NotificationLogService
          .instance
          .deleteByKey(key);
    } catch (e) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final unread =
        items.where(_isUnread).length;

    return Scaffold(
      backgroundColor:
          cs.surfaceContainerLowest,
      appBar: AppBar(
        centerTitle: true,
        title: Column(
          children: [
            const Text(
              "Notifications",
              style: TextStyle(
                fontWeight:
                    FontWeight.bold,
              ),
            ),
            if (unread > 0)
              Text(
                "$unread unread",
                style: TextStyle(
                  fontSize: 12,
                  color:
                      cs.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          if (unread > 0)
            TextButton.icon(
              onPressed:
                  _markAllRead,
              icon: const Icon(
                Icons.done_all_rounded,
                size: 18,
              ),
              label:
                  const Text("Read All"),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: loading
          ? const Center(
              child:
                  CircularProgressIndicator(),
            )
          : items.isEmpty
              ? Center(
                  child: Text(
                    "No notifications yet",
                    style: TextStyle(
                      color:
                          t.hintColor,
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child:
                      ListView.separated(
                    padding:
                        const EdgeInsets
                            .fromLTRB(
                      18,
                      12,
                      18,
                      100,
                    ),
                    itemCount:
                        items.length,
                    separatorBuilder:
                        (_, __) =>
                            const SizedBox(
                      height: 12,
                    ),
                    itemBuilder:
                        (context, i) {
                      final n =
                          items[i];

                      final type =
                          (n['type'] ??
                                  'info')
                              .toString();

                      final isUnread =
                          _isUnread(n);

                      return Dismissible(
                        key: Key(
                          n['noti_key']
                                  ?.toString() ??
                              '$i',
                        ),
                        direction:
                            DismissDirection
                                .endToStart,
                        onDismissed:
                            (_) =>
                                _delete(
                                    n),
                        background:
                            Container(
                          alignment:
                              Alignment
                                  .centerRight,
                          padding:
                              const EdgeInsets
                                  .only(
                                      right:
                                          24),
                          decoration:
                              BoxDecoration(
                            color:
                                cs.error,
                            borderRadius:
                                BorderRadius.circular(
                                    24),
                          ),
                          child:
                              const Icon(
                            Icons
                                .delete_outline_rounded,
                            color: Colors
                                .white,
                          ),
                        ),
                        child:
                            InkWell(
                          borderRadius:
                              BorderRadius.circular(
                                  24),
                          onTap: () =>
                              _openNotif(
                                  i),
                          child:
                              Container(
                            padding:
                                const EdgeInsets.all(
                                    18),
                            decoration:
                                BoxDecoration(
                              borderRadius:
                                  BorderRadius.circular(
                                      24),
                              color:
                                  isUnread
                                      ? cs.primaryContainer.withOpacity(
                                          0.45)
                                      : cs.surface,
                              border:
                                  Border.all(
                                color: isUnread
                                    ? cs.primary.withOpacity(
                                        0.25)
                                    : t.dividerColor.withOpacity(
                                        0.3),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: t
                                      .shadowColor
                                      .withOpacity(
                                          0.03),
                                  blurRadius:
                                      14,
                                  offset:
                                      const Offset(
                                          0,
                                          6),
                                ),
                              ],
                            ),
                            child:
                                Row(
                              children: [
                                Container(
                                  padding:
                                      const EdgeInsets.all(
                                          12),
                                  decoration:
                                      BoxDecoration(
                                    shape:
                                        BoxShape.circle,
                                    color:
                                        _bgColorForType(
                                      context,
                                      type,
                                    ),
                                  ),
                                  child:
                                      Icon(
                                    _iconForType(
                                        type),
                                    color:
                                        _colorForType(
                                      context,
                                      type,
                                    ),
                                  ),
                                ),
                                const SizedBox(
                                    width:
                                        16),
                                Expanded(
                                  child:
                                      Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        n['title'] ??
                                            'Notification',
                                        style:
                                            TextStyle(
                                          fontWeight: isUnread
                                              ? FontWeight.w800
                                              : FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(
                                          height:
                                              6),
                                      Text(
                                        n['body'] ??
                                            '',
                                        maxLines:
                                            2,
                                        overflow:
                                            TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(
                                          height:
                                              8),
                                      Text(
                                        _timeText(
                                            n),
                                        style:
                                            TextStyle(
                                          fontSize:
                                              12,
                                          color:
                                              t.hintColor,
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
                    },
                  ),
                ),
    );
  }
}
