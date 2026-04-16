import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'user_page.dart';
import 'transaction_management_page.dart';
import 'quick_add_transaction_page.dart';
import 'add_transaction_page.dart';
import 'more_page.dart';

class UserShell extends StatefulWidget {
  const UserShell({super.key});

  @override
  State<UserShell> createState() => _UserShellState();
}

class _UserShellState extends State<UserShell> {
  int _tab = 0;

  // 3 navigation stacks (Dashboard, Manage, More)
  final _navKeys = List.generate(3, (_) => GlobalKey<NavigatorState>());

  Future<bool> _onWillPop() async {
    // Determine which navigator key to check
    final activeKeyIndex = _tab > 2 ? 2 : _tab;
    final nav = _navKeys[activeKeyIndex].currentState;
    
    if (nav != null && nav.canPop()) {
      nav.pop();
      return false;
    }
    return true;
  }

  Widget _tabNavigator(int index, Widget root) {
    return Navigator(
      key: _navKeys[index],
      onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => root),
    );
  }

  Future<void> _openQuickAddMenu() async {
    final cs = Theme.of(context).colorScheme;
    HapticFeedback.mediumImpact();

    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: cs.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Add Transaction",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  "Choose your preferred logging method",
                  style: TextStyle(color: Theme.of(context).hintColor, fontSize: 14),
                ),
                const SizedBox(height: 24),
                _SheetTile(
                  icon: Icons.auto_awesome_rounded,
                  iconColor: cs.primary,
                  title: "AI Quick Add",
                  subtitle: "Type or speak naturally",
                  onTap: () => Navigator.pop(ctx, "auto"),
                ),
                const SizedBox(height: 12),
                _SheetTile(
                  icon: Icons.edit_note_rounded,
                  iconColor: Colors.blue.shade600,
                  title: "Manual Entry",
                  subtitle: "Fill in the specific details",
                  onTap: () => Navigator.pop(ctx, "manual"),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted) return;

    if (result == "auto") {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const QuickAddTransactionPage()),
      );
    } else if (result == "manual") {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AddTransactionPage()),
      );
    }
  }

  void _onTap(int i) {
    if (i == 2) {
      _openQuickAddMenu();
      return;
    }

    if (_tab == i) {
      // If tapping current tab, pop to root
      final activeKeyIndex = i > 2 ? 2 : i;
      _navKeys[activeKeyIndex].currentState?.popUntil((r) => r.isFirst);
      return;
    }

    HapticFeedback.selectionClick();
    setState(() => _tab = i);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final stackIndex = _tab > 2 ? 2 : _tab;

    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        backgroundColor: cs.surfaceContainerLowest,
        body: IndexedStack(
          index: stackIndex,
          children: [
            _tabNavigator(0, const UserPage()),
            _tabNavigator(1, const TransactionManagementPage()),
            _tabNavigator(2, const MorePage()),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: cs.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BottomNavigationBar(
                  type: BottomNavigationBarType.fixed,
                  backgroundColor: cs.surfaceContainerHigh.withOpacity(0.8),
                  elevation: 0,
                  currentIndex: _tab,
                  onTap: _onTap,
                  selectedItemColor: cs.primary,
                  unselectedItemColor: cs.onSurfaceVariant.withOpacity(0.6),
                  selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                  unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 11),
                  items: const [
                    BottomNavigationBarItem(
                      icon: Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Icon(Icons.dashboard_outlined),
                      ),
                      activeIcon: Icon(Icons.dashboard_rounded),
                      label: "Home",
                    ),
                    BottomNavigationBarItem(
                      icon: Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Icon(Icons.receipt_long_outlined),
                      ),
                      activeIcon: Icon(Icons.receipt_long_rounded),
                      label: "Transactions",
                    ),
                    BottomNavigationBarItem(
                      icon: Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Icon(Icons.add_circle_outline_rounded),
                      ),
                      activeIcon: Icon(Icons.add_circle_rounded),
                      label: "Add",
                    ),
                    BottomNavigationBarItem(
                      icon: Padding(
                        padding: EdgeInsets.only(bottom: 4),
                        child: Icon(Icons.grid_view_outlined),
                      ),
                      activeIcon: Icon(Icons.grid_view_rounded),
                      label: "More",
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SheetTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.dividerColor.withOpacity(0.1)),
          color: cs.surfaceContainerLow,
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: iconColor, size: 26),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: t.hintColor, fontSize: 13),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: t.hintColor),
          ],
        ),
      ),
    );
  }
}