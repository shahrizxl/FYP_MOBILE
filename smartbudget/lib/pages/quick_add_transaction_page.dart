import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/nlp_service.dart';
import '../services/transaction_service.dart';

// Helper to format amount nicely (e.g. 12.00 becomes 12, 12.50 stays 12.50)
String formatAmount(double amt) {
  return amt % 1 == 0 ? amt.toInt().toString() : amt.toStringAsFixed(2);
}

class QuickAddTransactionPage extends StatefulWidget {
  const QuickAddTransactionPage({super.key});

  @override
  State<QuickAddTransactionPage> createState() => _QuickAddTransactionPageState();
}

class _QuickAddTransactionPageState extends State<QuickAddTransactionPage> {
  final ctrl = TextEditingController();
  final nlp = NlpService();
  final txService = TransactionService();

  bool loading = false;
  String? error;

  // chat history
  final List<ChatMsg> messages = [];

  // track which bot replies have been saved
  final Set<int> savedMsgIds = {};

  // simple incremental id
  int _nextId = 1;

  // for auto-scroll
  final _scrollCtrl = ScrollController();

  // ----- Voice-to-text (HARDENED) -----
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool _speechReady = false;
  bool _listening = false;
  String _speechLocaleId = "en_US";

  String _baseTextBeforeMic = "";
  bool _userTypedWhileListening = false;

  String? get userId => Supabase.instance.client.auth.currentUser?.id;

  final Map<String, IconData> categoryIcons = {
    "food": Icons.restaurant_rounded,
    "transport": Icons.directions_car_rounded,
    "shopping": Icons.shopping_bag_rounded,
    "bills": Icons.receipt_long_rounded,
    "entertainment": Icons.movie_creation_rounded,
    "healthcare": Icons.medical_services_rounded,
    "education": Icons.school_rounded,
    "banking": Icons.account_balance_rounded,
    "personal_care": Icons.spa_rounded,
    "pets": Icons.pets_rounded,
    "home": Icons.home_rounded,
    "income": Icons.attach_money_rounded,
    "other": Icons.category_rounded,
  };

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    try {
      final ok = await _speech.initialize(
        onStatus: (status) {
          debugPrint("STT status: $status");
          if (!mounted) return;

          final isListening = status == 'listening';
          if (_listening != isListening) {
            setState(() => _listening = isListening);
          }
        },
        onError: (e) {
          debugPrint("STT error: ${e.errorMsg}");
          if (!mounted) return;

          setState(() {
            _listening = false;

            final msg = e.errorMsg.toLowerCase();
            if (msg.contains("error_server_disconnected") || msg.contains("network")) {
              error = "Voice network issue. Please check your connection.";
            } else if (msg.contains("permission") || msg.contains("not authorized")) {
              error = "Microphone permission not granted. Enable it in Settings.";
            } else if (msg.contains("language_not_supported")) {
              error = "Voice language not supported on this device.";
            } else {
              error = "Voice error: ${e.errorMsg}";
            }
          });
        },
      );

      if (!mounted) return;
      setState(() => _speechReady = ok);

      if (ok) {
        final locales = await _speech.locales();
        final system = await _speech.systemLocale();

        String? findExact(String id) {
          final want = id.toLowerCase();
          for (final l in locales) {
            if (l.localeId.toLowerCase() == want) return l.localeId;
          }
          return null;
        }

        String? findStartsWith(String prefix) {
          final p = prefix.toLowerCase();
          for (final l in locales) {
            if (l.localeId.toLowerCase().startsWith(p)) return l.localeId;
          }
          return null;
        }

        String pickLocaleId() {
          final sysId = system?.localeId;
          final sys = (sysId != null) ? findExact(sysId) : null;
          if (sys != null) return sys;

          final enMy = findExact("en_MY") ?? findExact("en-MY");
          if (enMy != null) return enMy;

          final msMy = findExact("ms_MY") ?? findExact("ms-MY");
          if (msMy != null) return msMy;

          return findStartsWith("en") ?? findStartsWith("ms") ?? "en_US";
        }

        setState(() => _speechLocaleId = pickLocaleId());
      } else {
        setState(() => error = "Voice not available. Check microphone permission.");
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _speechReady = false;
        error = "Voice init failed: $e";
      });
    }
  }

  Future<void> _stopListening() async {
    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
    } catch (_) {
      try {
        await _speech.cancel();
      } catch (_) {}
    }
  }

  Future<void> _toggleListen() async {
    HapticFeedback.mediumImpact();
    FocusScope.of(context).unfocus();

    if (!_speechReady) {
      setState(() => error = "Voice not ready. Check microphone permission.");
      return;
    }

    if (_speech.isListening || _listening) {
      await _stopListening();
      return;
    }

    setState(() {
      error = null;
      _baseTextBeforeMic = ctrl.text.trim();
      _userTypedWhileListening = false;
    });

    try {
      await _speech.listen(
        localeId: _speechLocaleId,
        listenMode: stt.ListenMode.dictation,
        partialResults: true,
        cancelOnError: true,
        onResult: (result) {
          if (!mounted || _userTypedWhileListening) return;

          final words = result.recognizedWords.trim();
          if (words.isEmpty) return;

          final newText =
              _baseTextBeforeMic.isEmpty ? words : "$_baseTextBeforeMic $words";

          ctrl.value = ctrl.value.copyWith(
            text: newText,
            selection: TextSelection.collapsed(offset: newText.length),
            composing: TextRange.empty,
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = "Could not start microphone: $e";
        _listening = false;
      });
    }
  }

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutQuart,
      );
    });
  }

  Future<void> sendMessage() async {
    await _stopListening();

    final text = ctrl.text.trim();
    if (text.isEmpty) {
      if (!mounted) return;
      setState(() => error = "Type something first. Example: Tapau rm7.50");
      return;
    }

    if (!mounted) return;
    setState(() {
      error = null;
      loading = true;
      messages.add(ChatMsg(id: _nextId++, fromUser: true, text: text));
    });

    ctrl.clear();
    _baseTextBeforeMic = "";
    _userTypedWhileListening = false;
    _scrollToBottom();

    try {
      final res = await nlp.analyze(text);
      final parsed = List<Map<String, dynamic>>.from(res);

      if (!mounted) return;
      setState(() {
        messages.add(ChatMsg(
          id: _nextId++,
          fromUser: false,
          text: parsed.isNotEmpty
              ? "I detected these transactions. Review and modify if needed before saving."
              : "I couldn't extract any transactions from that. Try: 'Food rm30' or 'Grab rm12'.",
          extracted: parsed,
        ));
      });
      _scrollToBottom();
      if (parsed.isNotEmpty) HapticFeedback.heavyImpact();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.toString();
        messages.add(ChatMsg(
          id: _nextId++,
          fromUser: false,
          text: "Oops, something went wrong processing that. Please try again.",
        ));
      });
      _scrollToBottom();
    } finally {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  Future<void> saveFromReply(
      int msgId, List<Map<String, dynamic>> extracted) async {
    final uid = userId;
    if (uid == null) {
      if (!mounted) return;
      setState(() => error = "Session expired. Please login again.");
      return;
    }

    if (extracted.isEmpty) return;

    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });

    try {
      final valid =
          extracted.where((r) => _asDouble(r["amount"]) > 0).toList();
      if (valid.isEmpty) throw Exception("No valid amount detected.");

      for (final r in valid) {
        final amt = _asDouble(r["amount"]);
        final rawDesc =
            (r["description"] ?? "Transaction").toString().trim();
        final amtStr = formatAmount(amt);
        final finalDesc = "$rawDesc - RM$amtStr";

        // Parse date from NLP result, fallback to today
        DateTime txDate;
        try {
          txDate = r["date"] != null && r["date"].toString().isNotEmpty
              ? DateTime.parse(r["date"].toString())
              : DateTime.now();
        } catch (_) {
          txDate = DateTime.now();
        }

        await txService.addTransaction(
          userId: uid,
          date: txDate,
          description: finalDesc,
          type: (r["type"] ?? "expense").toString(),
          amount: amt,
          category: (r["category"] ?? "other").toString(),
        );
      }

      HapticFeedback.lightImpact();

      if (!mounted) return;
      setState(() {
        savedMsgIds.add(msgId);
        messages.add(ChatMsg(
          id: _nextId++,
          fromUser: false,
          text:
              "✅ Saved ${valid.length} transaction(s) successfully to your records.",
        ));
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
    } finally {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    try {
      if (_speech.isListening) _speech.cancel();
    } catch (_) {}
    ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /* ---------------- UI WIDGETS ---------------- */

  Widget _errorBanner(BuildContext context, String text) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: cs.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: cs.onErrorContainer,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _typingIndicator(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomRight: Radius.circular(20),
              bottomLeft: Radius.circular(4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: cs.primary)),
              const SizedBox(width: 12),
              Text("Extracting data...",
                  style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bubble(BuildContext context, ChatMsg m) {
    final isUser = m.fromUser;
    final cs = Theme.of(context).colorScheme;

    final bubbleColor = isUser ? cs.primary : cs.surfaceContainerHigh;
    final textColor = isUser ? cs.onPrimary : cs.onSurface;
    final hasExtracted =
        (m.extracted != null && m.extracted!.isNotEmpty);
    final alreadySaved = savedMsgIds.contains(m.id);

    return Align(
      alignment:
          isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(isUser ? 20 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 20),
          ),
          boxShadow: isUser
              ? [
                  BoxShadow(
                      color: cs.primary.withOpacity(0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 4))
                ]
              : [],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(m.text,
                style: TextStyle(
                    fontSize: 15,
                    color: textColor,
                    fontWeight: isUser
                        ? FontWeight.w500
                        : FontWeight.normal,
                    height: 1.4)),
            if (hasExtracted) ...[
              const SizedBox(height: 8),

              // Render editable cards
              ...m.extracted!.asMap().entries.map((entry) {
                int idx = entry.key;
                Map<String, dynamic> r = entry.value;
                return EditableTransactionCard(
                  data: r,
                  categoryIcons: categoryIcons,
                  onChanged: (updatedMap) {
                    m.extracted![idx] = updatedMap;
                  },
                );
              }),

              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: (loading || alreadySaved)
                      ? null
                      : () => saveFromReply(m.id, m.extracted!),
                  icon: Icon(
                      alreadySaved
                          ? Icons.check_circle_rounded
                          : Icons.save_rounded,
                      size: 20),
                  label: Text(
                      alreadySaved
                          ? "Saved to Records"
                          : "Confirm & Save",
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14)),
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    disabledBackgroundColor:
                        cs.surfaceContainerHighest,
                    disabledForegroundColor: cs.onSurfaceVariant,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withOpacity(0.4),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                      color: cs.primary.withOpacity(0.1),
                      blurRadius: 40,
                      spreadRadius: 10)
                ],
              ),
              child: Icon(Icons.auto_awesome_rounded,
                  color: cs.primary, size: 56),
            ),
            const SizedBox(height: 32),
            Text("Hi $displayName,",
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text("What did you spend on today?",
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: cs.onSurface)),
            const SizedBox(height: 12),
            Text(
                "Type or speak naturally, and I'll categorize it for you.",
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontSize: 15,
                    height: 1.5)),
            const SizedBox(height: 40),
            Wrap(
              spacing: 10,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                _suggestionChip(context, "\u201cNasi Kandar RM 12\u201d",
                    Icons.restaurant_rounded),
                _suggestionChip(context, "\u201cGrab to office 25\u201d",
                    Icons.directions_car_rounded),
                _suggestionChip(
                    context,
                    "\u201cGroceries 150 yesterday\u201d",
                    Icons.shopping_bag_rounded),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _suggestionChip(
      BuildContext context, String text, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    return ActionChip(
      label: Text(text,
          style: const TextStyle(
              fontWeight: FontWeight.w600, fontSize: 13)),
      avatar: Icon(icon, size: 16, color: cs.primary),
      backgroundColor: cs.surfaceContainerHighest.withOpacity(0.5),
      side:
          BorderSide(color: cs.outlineVariant.withOpacity(0.5)),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(99)),
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      onPressed: () {
        HapticFeedback.lightImpact();
        ctrl.text =
            text.replaceAll('\u201c', '').replaceAll('\u201d', '');
      },
    );
  }

  String get displayName {
    final email =
        Supabase.instance.client.auth.currentUser?.email;
    if (email == null || !email.contains('@')) return "";
    final name = email.split('@').first.trim();
    if (name.isEmpty) return "";
    return name[0].toUpperCase() + name.substring(1);
  }

  Widget _inputBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark =
        Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 12,
          bottom: MediaQuery.of(context).padding.bottom + 12),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
            top: BorderSide(
                color: cs.outlineVariant.withOpacity(0.5))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          GestureDetector(
            onTap: loading ? null : _toggleListen,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              height: _listening ? 56 : 52,
              width: _listening ? 56 : 52,
              margin:
                  EdgeInsets.only(bottom: _listening ? 0 : 2),
              decoration: BoxDecoration(
                color: _listening
                    ? Colors.red.shade600
                    : cs.secondaryContainer,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                      color: _listening
                          ? Colors.red.shade600.withOpacity(0.5)
                          : Colors.transparent,
                      blurRadius: 16,
                      spreadRadius: 4)
                ],
              ),
              child: Icon(
                _listening
                    ? Icons.mic_rounded
                    : Icons.mic_none_rounded,
                color: _listening
                    ? Colors.white
                    : cs.onSecondaryContainer,
                size: _listening ? 28 : 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: ctrl,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onChanged: (_) {
                if (_listening) _userTypedWhileListening = true;
                setState(() {});
              },
              onSubmitted: (_) =>
                  loading ? null : sendMessage(),
              style: const TextStyle(fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: _listening
                    ? "Listening..."
                    : "Message your AI...",
                hintStyle: TextStyle(
                    color:
                        cs.onSurfaceVariant.withOpacity(0.8),
                    fontWeight: FontWeight.normal),
                filled: true,
                fillColor: isDark
                    ? cs.surfaceContainerHigh
                    : cs.surfaceContainerHighest
                        .withOpacity(0.5),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 16),
              ),
            ),
          ),
          const SizedBox(width: 12),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 52,
            width: 52,
            margin: const EdgeInsets.only(bottom: 2),
            decoration: BoxDecoration(
              color: ctrl.text.trim().isEmpty
                  ? Colors.transparent
                  : cs.primary,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              onPressed:
                  (loading || ctrl.text.trim().isEmpty)
                      ? null
                      : sendMessage,
              icon: loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white))
                  : Icon(Icons.send_rounded,
                      color: ctrl.text.trim().isEmpty
                          ? cs.onSurfaceVariant
                          : cs.onPrimary),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        title: Column(
          children: [
            const Text("AI Quick Add",
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 18)),
            Text(
              _speechReady
                  ? "Voice & Chat Enabled"
                  : "Chat Enabled",
              style: TextStyle(
                  fontSize: 12,
                  color: cs.primary,
                  fontWeight: FontWeight.w700),
            ),
          ],
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: cs.surfaceContainerLowest,
      ),
      body: Column(
        children: [
          if (error != null) _errorBanner(context, error!),
          Expanded(
            child: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              child: messages.isEmpty
                  ? _emptyState(context)
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 16),
                      itemCount: messages.length,
                      itemBuilder: (_, i) =>
                          _bubble(context, messages[i]),
                    ),
            ),
          ),
          if (loading) _typingIndicator(context),
          _inputBar(context),
        ],
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/*  DATA MODELS                                                         */
/* ------------------------------------------------------------------ */

class ChatMsg {
  final int id;
  final bool fromUser;
  final String text;
  final List<Map<String, dynamic>>? extracted;

  ChatMsg({
    required this.id,
    required this.fromUser,
    required this.text,
    this.extracted,
  });
}

/* ------------------------------------------------------------------ */
/*  EDITABLE TRANSACTION CARD                                           */
/* ------------------------------------------------------------------ */

class EditableTransactionCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final Map<String, IconData> categoryIcons;
  final Function(Map<String, dynamic>) onChanged;

  const EditableTransactionCard({
    super.key,
    required this.data,
    required this.categoryIcons,
    required this.onChanged,
  });

  @override
  State<EditableTransactionCard> createState() =>
      _EditableTransactionCardState();
}

class _EditableTransactionCardState
    extends State<EditableTransactionCard> {
  late TextEditingController _amtCtrl;
  late String _selectedCat;
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _amtCtrl = TextEditingController(
        text: widget.data["amount"]?.toString() ?? "0");
    _selectedCat = widget.data["category"] ?? "other";

    // Parse date from NLP or default to today
    try {
      _selectedDate =
          widget.data["date"] != null &&
                  widget.data["date"].toString().isNotEmpty
              ? DateTime.parse(widget.data["date"].toString())
              : DateTime.now();
    } catch (_) {
      _selectedDate = DateTime.now();
    }
  }

  @override
  void dispose() {
    _amtCtrl.dispose();
    super.dispose();
  }

  void _notify() {
    final updated = Map<String, dynamic>.from(widget.data);
    updated["amount"] =
        double.tryParse(_amtCtrl.text) ?? 0.0;
    updated["category"] = _selectedCat;
    // Store date as ISO date string (YYYY-MM-DD only)
    updated["date"] =
        _selectedDate.toIso8601String().split('T').first;
    widget.onChanged(updated);
    setState(() {});
  }

  /// Returns a human-friendly label for the selected date.
  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(d.year, d.month, d.day);
    final diff = target.difference(today).inDays;

    if (diff == 0) return "Today";
    if (diff == -1) return "Yesterday";
    if (diff == 1) return "Tomorrow";
    if (diff < 0 && diff >= -6) return "${diff.abs()}d ago";
    if (diff > 1 && diff <= 6) return "In ${diff}d";
    // Fallback: dd/mm/yyyy
    return "${d.day.toString().padLeft(2, '0')}/"
        "${d.month.toString().padLeft(2, '0')}/"
        "${d.year}";
  }

  Future<void> _pickDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
      _notify();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark =
        Theme.of(context).brightness == Brightness.dark;

    final rawDesc =
        (widget.data["description"] ?? "Transaction")
            .toString()
            .trim();
    final currentAmt =
        double.tryParse(_amtCtrl.text) ?? 0.0;
    final amtStr = formatAmount(currentAmt);
    final previewString = "$rawDesc - RM$amtStr";

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? cs.surface.withOpacity(0.3)
            : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: cs.outlineVariant.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Row 1: category dropdown + amount field ──
          Row(
            children: [
              // Category selector
              Expanded(
                flex: 3,
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: widget.categoryIcons
                            .containsKey(_selectedCat)
                        ? _selectedCat
                        : "other",
                    isExpanded: true,
                    style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.bold),
                    items:
                        widget.categoryIcons.keys.map((cat) {
                      return DropdownMenuItem(
                        value: cat,
                        child: Row(
                          children: [
                            Icon(
                                widget.categoryIcons[cat],
                                size: 18,
                                color: cs.primary),
                            const SizedBox(width: 8),
                            Text(cat.replaceAll('_', ' ')),
                          ],
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        _selectedCat = val;
                        _notify();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Editable amount
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _amtCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(
                          decimal: true),
                  textAlign: TextAlign.right,
                  onChanged: (_) => _notify(),
                  style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      color: cs.primary),
                  decoration: InputDecoration(
                    prefixText: "RM ",
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 8),
                    border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // ── Row 2: date badge + description preview ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Tappable date badge
              GestureDetector(
                onTap: () => _pickDate(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color:
                        cs.primaryContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: cs.primary.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.calendar_today_rounded,
                          size: 12, color: cs.primary),
                      const SizedBox(width: 4),
                      Text(
                        _formatDate(_selectedDate),
                        style: TextStyle(
                            fontSize: 12,
                            color: cs.primary,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 8),

              // Description preview
              Expanded(
                child: RichText(
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500),
                    children: [
                      const TextSpan(text: "Description: "),
                      TextSpan(
                        text: previewString,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: cs.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}