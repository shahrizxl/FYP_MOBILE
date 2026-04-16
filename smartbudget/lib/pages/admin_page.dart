import 'dart:async';
import 'package:flutter/material.dart';

// Assuming these are your services, left intact:
import '../services/admin_service.dart';
import '../services/auth_service.dart';
import '../services/auth_gate.dart';

// --- Extension for cleaner null handling ---
extension NullSafeString on String? {
  String get orEmpty => this ?? "";
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  final adminService = AdminService();

  bool loading = true;
  String? error;
  List<Map<String, dynamic>> users = [];

  String? deletingUserId;

  // Search
  final searchCtrl = TextEditingController();
  String query = "";
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    loadUsers();
    
    // --- UX Improvement: Debounced Search ---
    searchCtrl.addListener(() {
      if (_debounce?.isActive ?? false) _debounce!.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          setState(() => query = searchCtrl.text.trim().toLowerCase());
        }
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    searchCtrl.dispose();
    super.dispose();
  }

  Future<void> loadUsers() async {
    if (!mounted) return;

    setState(() {
      loading = true;
      error = null;
    });

    try {
      users = await adminService.fetchAllUsers();
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _logout() async {
    await AuthService().logout();
    if (context.mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AuthGate()),
      );
    }
  }

  Future<void> confirmDelete({
    required String userId,
    required String email,
  }) async {
    final cs = Theme.of(context).colorScheme;
    
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        icon: Icon(Icons.warning_rounded, color: cs.error, size: 32),
        title: const Text("Delete user data?"),
        content: Text(
          "This will:\n"
          "• Delete all transactions\n"
          "• Disable the account\n\n"
          "User: $email",
          style: TextStyle(color: cs.onSurfaceVariant),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            icon: const Icon(Icons.delete_forever_rounded),
            onPressed: () => Navigator.pop(context, true),
            label: const Text("Confirm Delete"),
          ),
        ],
      ),
    );

    if (ok != true) return;

    if (!mounted) return;
    setState(() => deletingUserId = userId);

    // Blocking progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        content: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text("Deleting data for $email...", style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );

    // --- UX Improvement: Safely capture Navigator and Messenger before async gap ---
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      await adminService.deleteUser(userId);

      if (mounted) {
        navigator.pop(); // Safely close progress dialog
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text("Disabled and deleted: $email"),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }

      await loadUsers();
    } catch (e) {
      if (mounted) {
        navigator.pop(); // Safely close progress dialog
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text("Action failed: $e"),
            backgroundColor: cs.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => deletingUserId = null);
    }
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  List<Map<String, dynamic>> get _filteredUsers {
    final list = users.where((u) {
      final role = (u['role'] as String?) ?? 'user';
      return role != 'admin'; // hide admins
    }).toList();

    if (query.isEmpty) return list;

    return list.where((u) {
      // --- UX Improvement: Utilizing the NullSafeString extension ---
      final email = (u['email'] as String?).orEmpty.toLowerCase();
      final id = (u['id'] as String?).orEmpty.toLowerCase();
      return email.contains(query) || id.contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filteredUsers;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text("Admin Panel", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: "Refresh",
            icon: const Icon(Icons.refresh_rounded),
            onPressed: loadUsers,
          ),
          IconButton(
            tooltip: "Logout",
            icon: const Icon(Icons.logout_rounded),
            onPressed: _logout,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _AdminHeroHeader(
                  userCount: list.length,
                  searchCtrl: searchCtrl,
                  query: query,
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.errorContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline, color: cs.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              error!,
                              style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: loadUsers,
                    child: list.isEmpty
                        ? ListView(
                            padding: const EdgeInsets.all(24),
                            children: [
                              const SizedBox(height: 40),
                              Icon(Icons.people_outline_rounded, size: 64, color: cs.onSurfaceVariant.withOpacity(0.5)),
                              const SizedBox(height: 16),
                              Text(
                                query.isEmpty ? "No users found." : "No results for “$query”.",
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                              ),
                              if (query.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                Center(
                                  child: FilledButton.tonalIcon(
                                    onPressed: () {
                                      searchCtrl.clear();
                                      FocusScope.of(context).unfocus();
                                    },
                                    icon: const Icon(Icons.clear_rounded),
                                    label: const Text("Clear search"),
                                  ),
                                ),
                              ]
                            ],
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                            itemCount: list.length,
                            itemBuilder: (context, index) {
                              final u = list[index];
                              final userId = (u['id'] as String?).orEmpty;
                              final email = (u['email'] as String?).orEmpty.isEmpty ? "(no email)" : u['email'] as String;
                              final active = (u['is_active'] as bool?) ?? true;
                              final txCount = (u['tx_count'] as int?) ?? 0;
                              final totalSpend = _asDouble(u['total_spend']);
                              final isDeleting = deletingUserId == userId;

                              return _UserAdminCard(
                                userId: userId,
                                email: email,
                                active: active,
                                txCount: txCount,
                                totalSpend: totalSpend,
                                isDeleting: isDeleting,
                                onToggleStatus: isDeleting
                                    ? null
                                    : (val) async {
                                        final scaffoldMessenger = ScaffoldMessenger.of(context);
                                        try {
                                          await adminService.setUserActive(userId, val);
                                          await loadUsers();
                                        } catch (e) {
                                          if (!mounted) return;
                                          scaffoldMessenger.showSnackBar(
                                            SnackBar(content: Text("Update failed: $e")),
                                          );
                                        }
                                      },
                                onDelete: isDeleting ? null : () => confirmDelete(userId: userId, email: email),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
    );
  }
}

/* ===================== HERO HEADER ===================== */

class _AdminHeroHeader extends StatelessWidget {
  final int userCount;
  final TextEditingController searchCtrl;
  final String query;

  const _AdminHeroHeader({
    required this.userCount,
    required this.searchCtrl,
    required this.query,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primary, cs.tertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(color: cs.primary.withOpacity(0.3), blurRadius: 15, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Total Users",
                    style: TextStyle(color: cs.onPrimary.withOpacity(0.8), fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "$userCount",
                    style: TextStyle(color: cs.onPrimary, fontSize: 32, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.onPrimary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(Icons.admin_panel_settings_rounded, color: cs.onPrimary, size: 32),
              ),
            ],
          ),
          const SizedBox(height: 24),
          TextField(
            controller: searchCtrl,
            textInputAction: TextInputAction.search,
            style: TextStyle(color: cs.onSurface),
            decoration: InputDecoration(
              hintText: "Search email or ID...",
              hintStyle: TextStyle(color: cs.onSurfaceVariant.withOpacity(0.8)),
              prefixIcon: Icon(Icons.search_rounded, color: cs.primary),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: Icon(Icons.clear_rounded, color: cs.onSurfaceVariant),
                      onPressed: () {
                        searchCtrl.clear();
                        FocusScope.of(context).unfocus();
                      },
                    ),
              filled: true,
              fillColor: cs.surface,
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
            ),
          ),
        ],
      ),
    );
  }
}

/* ===================== USER CARD ===================== */

class _UserAdminCard extends StatelessWidget {
  final String userId;
  final String email;
  final bool active;
  final int txCount;
  final double totalSpend;
  final bool isDeleting;
  final ValueChanged<bool>? onToggleStatus;
  final VoidCallback? onDelete;

  const _UserAdminCard({
    required this.userId,
    required this.email,
    required this.active,
    required this.txCount,
    required this.totalSpend,
    required this.isDeleting,
    required this.onToggleStatus,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final initial = email.isNotEmpty && email != "(no email)" ? email[0].toUpperCase() : "?";

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: t.dividerColor.withOpacity(0.4)),
        boxShadow: [BoxShadow(color: t.shadowColor.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 4))],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: active ? cs.primaryContainer : cs.surfaceContainerHighest,
                  foregroundColor: active ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                  child: Text(initial, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        email,
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: cs.onSurface),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        "ID: $userId",
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: active ? cs.tertiaryContainer : cs.errorContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    active ? "Active" : "Disabled",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: active ? cs.onTertiaryContainer : cs.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          if (txCount > 0 || totalSpend > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _StatPill(icon: Icons.receipt_long_rounded, label: "Transactions", value: "$txCount"),
                  const SizedBox(width: 12),
                  _StatPill(icon: Icons.payments_rounded, label: "Total Spend", value: "RM ${totalSpend.toStringAsFixed(0)}"),
                ],
              ),
            ),
            
          const SizedBox(height: 16),
          Divider(height: 1, color: t.dividerColor.withOpacity(0.4)),
          
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Switch(
                      value: active,
                      onChanged: onToggleStatus,
                      activeColor: cs.primary,
                    ),
                    const SizedBox(width: 8),
                    Text("Account Access", style: TextStyle(fontWeight: FontWeight.w600, color: cs.onSurfaceVariant, fontSize: 13)),
                  ],
                ),
                TextButton.icon(
                  onPressed: onDelete,
                  style: TextButton.styleFrom(foregroundColor: cs.error),
                  icon: isDeleting 
                      ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: cs.error))
                      : const Icon(Icons.delete_outline_rounded, size: 20),
                  label: const Text("Delete Data", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatPill({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withOpacity(0.3),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
                  Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: cs.onSurface)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}