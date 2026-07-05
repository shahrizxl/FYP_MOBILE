import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../services/nlp_service.dart';
import '../services/transaction_service.dart';
import '../services/globals.dart';

String formatAmount(double amt) =>
    amt % 1 == 0 ? amt.toInt().toString() : amt.toStringAsFixed(2);

// ─────────────────────────────────────────────────────────────────────────────
//  Hairline divider
// ─────────────────────────────────────────────────────────────────────────────
class _Hairline extends StatelessWidget {
  final double indent;
  const _Hairline({this.indent = 0});

  @override
  Widget build(BuildContext context) => Container(
        height: 0.5,
        margin: EdgeInsets.symmetric(horizontal: indent),
        color: Theme.of(context).dividerColor.withOpacity(0.5),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
//  MALAY NUMBER WORD -> DIGIT CONVERTER
// ─────────────────────────────────────────────────────────────────────────────
//
// On-device speech recognizers occasionally spell numbers out instead of
// using digits (e.g. "lima puluh ribu" instead of "50000"). This utility
// finds runs of Malay number-words in recognized text and converts them
// to digits, so downstream NLP parsing always sees numeric amounts.
//
// Handles: units (satu..sembilan), belas (teens), puluh (tens),
// ratus (hundreds), ribu (thousands), juta (millions), and the "se-"
// prefix forms (sepuluh, sebelas, seratus, seribu, sejuta).
class MalayNumberConverter {
  static const Map<String, int> _units = {
    'kosong': 0,
    'satu': 1,
    'dua': 2,
    'tiga': 3,
    'empat': 4,
    'lima': 5,
    'enam': 6,
    'tujuh': 7,
    'lapan': 8,
    'sembilan': 9,
    'se': 1,
  };

  static const Set<String> _multiplierWords = {'puluh', 'ratus', 'ribu', 'juta'};
  static const String _teenWord = 'belas';

  static const Map<String, int> _multiplierValues = {
    'puluh': 10,
    'ratus': 100,
    'ribu': 1000,
    'juta': 1000000,
  };

  /// Splits compound words like "seratus", "seribu", "sejuta", "sepuluh",
  /// "sebelas" into "se" + the base word, so the tokenizer can treat them
  /// uniformly (se = 1, then multiplied/added by the following word).
  static String _splitSePrefix(String text) {
    final pattern = RegExp(
      r'\bse(ratus|ribu|juta|puluh|belas)\b',
      caseSensitive: false,
    );
    return text.replaceAllMapped(pattern, (m) => 'se ${m.group(1)}');
  }

  /// Returns true if a lowercase word is part of a Malay number expression.
  static bool _isNumberWord(String w) =>
      _units.containsKey(w) || _multiplierWords.contains(w) || w == _teenWord;

  /// Converts a contiguous list of number-word tokens into an integer.
  static int _resolve(List<String> tokens) {
    int total = 0;
    int current = 0;

    for (final tok in tokens) {
      if (_units.containsKey(tok)) {
        current += _units[tok]!;
      } else if (tok == _teenWord) {
        current += 10;
      } else if (_multiplierWords.contains(tok)) {
        final mult = _multiplierValues[tok]!;
        if (mult >= 1000) {
          total += (current == 0 ? 1 : current) * mult;
          current = 0;
        } else {
          current = (current == 0 ? 1 : current) * mult;
        }
      }
    }
    return total + current;
  }

  /// Scans free text, replaces runs of Malay number-words with digits.
  /// Non-number words (including "ringgit", "rm", item names) are left
  /// untouched and act as boundaries between separate number runs.
  static String normalize(String input) {
    final prepped = _splitSePrefix(input);
    final wordSplit = RegExp(r'(\s+)');
    final parts = prepped.split(wordSplit);

    final output = <String>[];
    List<String> buffer = [];

    void flushBuffer() {
      if (buffer.isEmpty) return;
      output.add(_resolve(buffer.map((w) => w.toLowerCase()).toList()).toString());
      buffer = [];
    }

    for (final part in prepped.split(' ')) {
      if (part.trim().isEmpty) {
        continue;
      }
      final clean = part.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      if (_isNumberWord(clean)) {
        buffer.add(clean);
      } else {
        flushBuffer();
        output.add(part);
      }
    }
    flushBuffer();

    return output.join(' ');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  MAIN PAGE
// ─────────────────────────────────────────────────────────────────────────────
class QuickAddTransactionPage extends StatefulWidget {
  const QuickAddTransactionPage({super.key});

  @override
  State<QuickAddTransactionPage> createState() =>
      _QuickAddTransactionPageState();
}

class _QuickAddTransactionPageState extends State<QuickAddTransactionPage>
    with TickerProviderStateMixin {
  final ctrl      = TextEditingController();
  final nlp       = NlpService();
  final txService = TransactionService();

  bool    loading = false;
  String? error;

  final List<ChatMsg> messages    = [];
  final Set<int>      savedMsgIds = {};
  int                 _nextId     = 1;
  final _scrollCtrl = ScrollController();

  // Speech
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool    _speechReady   = false;
  bool    _isListening   = false;
  String  _preSpeechText = '';
  int     _retryCount    = 0;
  static const int _maxRetries = 2;

  final Map<String, IconData> categoryIcons = {
    'food'         : Icons.restaurant_rounded,
    'transport'    : Icons.directions_car_rounded,
    'shopping'     : Icons.shopping_bag_rounded,
    'bills'        : Icons.receipt_long_rounded,
    'entertainment': Icons.movie_creation_rounded,
    'healthcare'   : Icons.medical_services_rounded,
    'education'    : Icons.school_rounded,
    'banking'      : Icons.account_balance_rounded,
    'personal_care': Icons.spa_rounded,
    'pets'         : Icons.pets_rounded,
    'home'         : Icons.home_rounded,
    'travel'       : Icons.flight_rounded,
    'income'       : Icons.attach_money_rounded,
    'other'        : Icons.category_rounded,
  };

  String? get userId => Supabase.instance.client.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  // ── STT Init ───────────────────────────────────────────────────────────────
  Future<void> _initSpeech() async {
    try {
      _speechReady = await _speech.initialize(
        onError: _onSpeechError,
        onStatus: _onSpeechStatus,
      );
    } catch (e) {
      _speechReady = false;
    }

    if (!_speechReady && mounted) {
      setState(() => error = 'Microphone permission denied. Enable it in Settings.');
    } else if (mounted) {
      setState(() {});
    }
  }

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status == 'done' || status == 'notListening') {
      setState(() => _isListening = false);
    }
  }

  void _onSpeechError(dynamic errorNotification) {
    if (!mounted) return;

    final errorMsg = errorNotification.errorMsg ?? errorNotification.toString();

    const ignoredErrors = [
      'error_speech_timeout',
      'error_no_match',
      'error_audio',
    ];

    if (ignoredErrors.any((e) => errorMsg.contains(e))) {
      setState(() => _isListening = false);
      return;
    }

    setState(() => _isListening = false);

    if (_retryCount < _maxRetries &&
        (errorMsg.contains('error_network') ||
         errorMsg.contains('error_recognizer_busy'))) {
      _retryCount++;
      Future.delayed(const Duration(milliseconds: 500), _startListening);
      return;
    }

    _retryCount = 0;
    setState(() => error = 'Voice input failed. Please try again.');
  }

  // ── Start Listening ────────────────────────────────────────────────────────
  Future<void> _startListening() async {
    if (!_speechReady) {
      setState(() => error = 'Microphone not available.');
      return;
    }

    if (_speech.isListening) {
      await _speech.stop();
    }

    _preSpeechText = ctrl.text.trim();
    setState(() { _isListening = true; error = null; });

    await _speech.listen(
      listenMode:     stt.ListenMode.dictation,
      partialResults: true,
      listenFor:      const Duration(seconds: 30),
      pauseFor:       const Duration(seconds: 3),
      onResult:       _onSpeechResult,
      // 🔥 Malaysian English handles code-switched Malay/English speech
      // ("Nasi lemak RM8", "Minyak kereta lima puluh") in a single pass
      // far better than a pure ms_MY or en_US model does.
      localeId:       'en_MY',
    );
  }

  void _onSpeechResult(dynamic result) {
    if (!mounted) return;

    final rawSpoken = (result.recognizedWords as String).trim();
    if (rawSpoken.isEmpty) return;

    // 🔥 Convert any spelled-out Malay number words (ratus, ribu, puluh,
    // belas, se- prefixes) into digits before they hit the text field.
    final spoken = MalayNumberConverter.normalize(rawSpoken);

    final base    = _preSpeechText.isEmpty ? '' : '${_preSpeechText.trimRight()} ';
    final newText = '$base$spoken';

    setState(() {
      ctrl.text      = newText;
      ctrl.selection = TextSelection.collapsed(offset: newText.length);
    });

    if (result.finalResult == true) {
      _preSpeechText = newText;
    }
  }

  // ── Stop Listening ─────────────────────────────────────────────────────────
  Future<void> _stopListening() async {
    if (_speech.isListening) {
      await _speech.stop();
    }
    _preSpeechText = ctrl.text.trim();
    if (mounted) setState(() => _isListening = false);
  }

  // ── Toggle Mic ─────────────────────────────────────────────────────────────
  Future<void> _toggleMic() async {
    HapticFeedback.mediumImpact();
    if (_isListening) {
      await _stopListening();
    } else {
      _retryCount = 0;
      await _startListening();
    }
  }

  @override
  void dispose() {
    _speech.cancel();
    ctrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve:    Curves.easeOutCubic,
      );
    });
  }

  // ── Business logic ─────────────────────────────────────────────────────────
  Future<void> sendMessage() async {
    if (_isListening) {
      await _stopListening();
    }
    final text = ctrl.text.trim();
    if (text.isEmpty) { setState(() => error = 'Type or speak first.'); return; }

    setState(() {
      error = null; loading = true;
      messages.add(ChatMsg(id: _nextId++, fromUser: true, text: text));
    });
    ctrl.text = '';
    Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);

    try {
      final res    = await nlp.analyze(text);
      final parsed = List<Map<String, dynamic>>.from(res);
      if (!mounted) return;
      setState(() {
        messages.add(ChatMsg(
          id: _nextId++, fromUser: false,
          text: parsed.isNotEmpty
              ? 'Found these transactions. Review and confirm.'
              : "Couldn't extract that. Try: 'Lunch RM15'.",
          extracted: parsed,
        ));
      });
      _scrollToBottom();
      if (parsed.isNotEmpty) HapticFeedback.heavyImpact();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = 'Analysis failed. Please try again.';
        messages.add(ChatMsg(
            id: _nextId++, fromUser: false,
            text: 'Something went wrong. Please try again.'));
      });
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> saveFromReply(
      int msgId, List<Map<String, dynamic>> extracted) async {
    final uid = userId;
    if (uid == null) { setState(() => error = 'Session expired.'); return; }
    if (extracted.isEmpty) return;
    setState(() { loading = true; error = null; });

    try {
      double asDouble(dynamic v) {
        if (v == null) return 0;
        if (v is num) return v.toDouble();
        return double.tryParse(v.toString().replaceAll(',', '')) ?? 0;
      }
      final valid = extracted.where((r) => asDouble(r['amount']) > 0).toList();
      if (valid.isEmpty) throw Exception('No valid amount detected.');

      for (final r in valid) {
        final amt       = asDouble(r['amount']);
        final rawDesc   = (r['description'] ?? 'Transaction').toString().trim();
        final finalDesc = '$rawDesc — RM${formatAmount(amt)}';
        DateTime txDate;
        try {
          txDate = r['date'] != null && r['date'].toString().isNotEmpty
              ? DateTime.parse(r['date'].toString()) : DateTime.now();
        } catch (_) { txDate = DateTime.now(); }

        await txService.addTransaction(
          userId:      uid,
          date:        txDate,
          description: finalDesc,
          type:        (r['type']     ?? 'expense').toString(),
          amount:      amt,
          category:    (r['category'] ?? 'other').toString(),
        );
      }
      globalTransactionUpdateNotifier.value++;
      HapticFeedback.lightImpact();
      if (!mounted) return;
      setState(() {
        savedMsgIds.add(msgId);
        messages.add(ChatMsg(
          id: _nextId++, fromUser: false,
          text:
              '${valid.length} transaction${valid.length > 1 ? 's' : ''} saved.',
        ));
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  UI
  // ══════════════════════════════════════════════════════════════════════════

  Widget _errorBanner(String txt) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin:  const EdgeInsets.fromLTRB(16, kToolbarHeight + 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      decoration: BoxDecoration(
        color:        cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withOpacity(0.5), width: 0.5),
      ),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, color: cs.onErrorContainer, size: 15),
        const SizedBox(width: 10),
        Expanded(
            child: Text(txt,
                style: TextStyle(
                    color: cs.onErrorContainer, fontSize: 12.5, fontWeight: FontWeight.w400))),
        GestureDetector(
          onTap: () => setState(() => error = null),
          child: Icon(Icons.close_rounded, size: 15, color: cs.onErrorContainer),
        ),
      ]),
    );
  }

  Widget _typingIndicator() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 80, bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color:        cs.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft:     Radius.circular(20),
            topRight:    Radius.circular(20),
            bottomRight: Radius.circular(20),
            bottomLeft:  Radius.circular(5),
          ),
          border: Border.all(color: cs.outlineVariant.withOpacity(0.5), width: 0.5),
        ),
        child: const _TypingDots(),
      ),
    );
  }

  Widget _bubble(ChatMsg m) {
    final isUser       = m.fromUser;
    final alreadySaved = savedMsgIds.contains(m.id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.84),
          child: isUser
              ? _UserBubble(text: m.text)
              : _AiBubble(
                  text:          m.text,
                  extracted:     m.extracted,
                  alreadySaved:  alreadySaved,
                  categoryIcons: categoryIcons,
                  loading:       loading,
                  onSave: () => saveFromReply(m.id, m.extracted!),
                ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 40, 20, 140),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 90,
              height: 90,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Center(
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 34,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'AI TRANSACTION',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurfaceVariant,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 10),
            Text('Add Transaction', style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w300,
              color: cs.onSurface,
              letterSpacing: -0.8,
              height: 1.15,
            )),
            const SizedBox(height: 14),
            Text(
              'Speak or type naturally in English or Malay.\nWe understand how you talk.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
            ),
            const SizedBox(height: 30),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                _SuggestionPill('Nasi Lemak RM8', Icons.restaurant, onTap: () {
                  ctrl.text = 'Nasi Lemak RM8';
                  setState(() {});
                }),
                _SuggestionPill('Minyak kereta RM50', Icons.directions_car, onTap: () {
                  ctrl.text = 'Minyak kereta RM50';
                  setState(() {});
                }),
                _SuggestionPill('Coffee RM5', Icons.local_cafe, onTap: () {
                  ctrl.text = 'Coffee RM5';
                  setState(() {});
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _micButton() {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: loading ? null : _toggleMic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isListening ? cs.primary : cs.surfaceContainerHighest,
          border: Border.all(
            color: _isListening ? cs.primary : cs.outlineVariant.withOpacity(0.5),
            width: 0.8,
          ),
        ),
        child: Icon(
          _isListening ? Icons.mic : Icons.mic_none,
          color: _isListening ? cs.onPrimary : cs.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _inputBar() {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final confirmed = ctrl.text.trim();
    final hasText   = confirmed.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest.withOpacity(0.96),
        border: Border(top: BorderSide(color: cs.outlineVariant.withOpacity(0.5), width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _micButton(),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color:        cs.surfaceContainerHighest.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: _isListening ? cs.primary : cs.outlineVariant.withOpacity(0.5),
                      width: 0.8,
                    ),
                  ),
                  child: TextField(
                    controller:      ctrl,
                    minLines:        1,
                    maxLines:        4,
                    textInputAction: TextInputAction.send,
                    onChanged:       (_) => setState(() {}),
                    onSubmitted: (_) {
                        if (loading) return;
                        FocusScope.of(context).unfocus();
                        sendMessage();
                      },
                    style: TextStyle(
                        fontSize:   15,
                        color:      cs.onSurface,
                        fontWeight: FontWeight.w400,
                        height:     1.45),
                    decoration: InputDecoration(
                      hintText: _isListening
                          ? 'Mendengar...'
                          : 'Contoh: Nasi lemak RM8',
                      hintStyle: TextStyle(
                          color:      t.hintColor,
                          fontSize:   15,
                          fontWeight: FontWeight.w400),
                      border:         InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: (loading || !hasText) ? null : sendMessage,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve:    Curves.easeOutBack,
                  width:    48,
                  height:   48,
                  margin:   const EdgeInsets.only(bottom: 2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hasText ? cs.primary : Colors.transparent,
                    border: Border.all(
                      color: hasText ? Colors.transparent : cs.outlineVariant.withOpacity(0.5),
                      width: 0.8,
                    ),
                  ),
                  child: Center(
                    child: loading
                        ? SizedBox(
                            width:  18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: cs.onSurfaceVariant.withOpacity(0.5)),
                          )
                        : Icon(Icons.arrow_upward_rounded,
                            size:  20,
                            color: hasText ? cs.onPrimary : t.hintColor),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusRow() {
    final cs = Theme.of(context).colorScheme;
    final label = _isListening
        ? 'Listening'
        : (_speechReady ? 'Voice Ready' : 'Text Only');
    final dotAlpha = _isListening ? 1.0 : (_speechReady ? 0.55 : 0.22);

    return Row(mainAxisSize: MainAxisSize.min, children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        width: 5, height: 5,
        margin: const EdgeInsets.only(right: 7),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.primary.withOpacity(dotAlpha),
        ),
      ),
      Text(label,
          style: TextStyle(
              fontSize: 10.5,
              color:    cs.onSurfaceVariant,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.3)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: cs.surfaceContainerLowest,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: cs.surfaceContainerLowest.withOpacity(0.90),
        elevation: 0,
        shape: Border(
          bottom: BorderSide(color: cs.outlineVariant.withOpacity(0.5), width: 0.5)
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              size: 17, color: cs.onSurfaceVariant),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Quick Add',
                style: TextStyle(
                    fontSize:   16,
                    fontWeight: FontWeight.w600,
                    color:      cs.onSurface,
                    letterSpacing: 0.1)),
            const SizedBox(height: 2),
            _statusRow(),
          ],
        ),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (error != null)
                SafeArea(bottom: false, child: _errorBanner(error!)),
              Expanded(
                child: GestureDetector(
                  onTap: () => FocusScope.of(context).unfocus(),
                  behavior: HitTestBehavior.opaque,
                  child: messages.isEmpty
                      ? _emptyState()
                      : ListView.builder(
                          controller: _scrollCtrl,
                          reverse: true,
                          padding: const EdgeInsets.only(
                              left: 16, right: 16,
                              top: 104, bottom: 180),
                          itemCount:   messages.length,
                          itemBuilder: (_, i) => _bubble(messages[messages.length - 1 - i]),
                        ),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading) _typingIndicator(),
                _inputBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Typing dots
// ─────────────────────────────────────────────────────────────────────────────
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1100))
      ..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Thinking',
              style: TextStyle(
                  fontSize: 13,
                  color:    cs.onSurfaceVariant,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.2)),
          const SizedBox(width: 7),
          ...List.generate(3, (i) {
            final phase   = i / 3;
            final t       = ((_ctrl.value - phase) % 1.0 + 1.0) % 1.0;
            final opacity = math.sin(t * math.pi).clamp(0.12, 1.0);
            final lift    = math.sin(t * math.pi) * 3.0;
            return Transform.translate(
              offset: Offset(0, -lift),
              child: Container(
                margin: const EdgeInsets.only(left: 3),
                width: 4, height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: cs.onSurfaceVariant.withOpacity(opacity),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  User bubble
// ─────────────────────────────────────────────────────────────────────────────
class _UserBubble extends StatelessWidget {
  final String text;
  const _UserBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: cs.primary,
        borderRadius: const BorderRadius.only(
          topLeft:     Radius.circular(22),
          topRight:    Radius.circular(22),
          bottomLeft:  Radius.circular(22),
          bottomRight: Radius.circular(5),
        ),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize:   15,
              color:      cs.onPrimary,
              fontWeight: FontWeight.w500,
              height:     1.5)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  AI bubble
// ─────────────────────────────────────────────────────────────────────────────
class _AiBubble extends StatelessWidget {
  final String                    text;
  final List<Map<String, dynamic>>? extracted;
  final bool                        alreadySaved;
  final Map<String, IconData>       categoryIcons;
  final bool                        loading;
  final VoidCallback                onSave;

  const _AiBubble({
    required this.text,
    required this.extracted,
    required this.alreadySaved,
    required this.categoryIcons,
    required this.loading,
    required this.onSave,
  });

  bool get hasExtracted => extracted != null && extracted!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color:        cs.surface,
        borderRadius: const BorderRadius.only(
          topLeft:     Radius.circular(5),
          topRight:    Radius.circular(22),
          bottomLeft:  Radius.circular(22),
          bottomRight: Radius.circular(22),
        ),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.5), width: 0.5),
        boxShadow: [BoxShadow(color: Theme.of(context).shadowColor.withOpacity(0.02), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('✦', style: TextStyle(color: cs.primary, fontSize: 9)),
            const SizedBox(width: 7),
            Text('AI',
                style: TextStyle(
                    fontSize:   9.5,
                    color:      cs.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.2)),
          ]),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(
              fontSize:   14.5,
              fontWeight: FontWeight.w400,
              color:      cs.onSurface,
              height:     1.55,
          )),
          if (hasExtracted) ...[
            const SizedBox(height: 14),
            ...extracted!.asMap().entries.map((e) =>
              EditableTransactionCard(
                data:          e.value,
                categoryIcons: categoryIcons,
                onChanged:     (u) => extracted![e.key] = u,
              ),
            ),
            const SizedBox(height: 16),
            _ConfirmButton(
              saved:   alreadySaved,
              loading: loading,
              onTap:   alreadySaved || loading ? null : onSave,
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Confirm & Save
// ─────────────────────────────────────────────────────────────────────────────
class _ConfirmButton extends StatelessWidget {
  final bool        saved;
  final bool        loading;
  final VoidCallback? onTap;
  const _ConfirmButton({
    required this.saved,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        height:   52,
        decoration: BoxDecoration(
          color: saved
              ? Colors.transparent
              : (onTap != null ? cs.primary : cs.surfaceContainerHighest),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: saved ? cs.outlineVariant : Colors.transparent,
            width: 0.8,
          ),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                saved ? Icons.check_rounded : Icons.save_alt_rounded,
                size:  16,
                color: saved ? cs.onSurfaceVariant : cs.onPrimary,
              ),
              const SizedBox(width: 8),
              Text(
                saved ? 'Saved' : 'Confirm & Save',
                style: TextStyle(
                    fontSize:   14.5,
                    fontWeight: FontWeight.w600,
                    color:      saved ? cs.onSurfaceVariant : cs.onPrimary,
                    letterSpacing: 0.2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Suggestion pill
// ─────────────────────────────────────────────────────────────────────────────
class _SuggestionPill extends StatelessWidget {
  final String    label;
  final IconData  icon;
  final VoidCallback onTap;
  const _SuggestionPill(this.label, this.icon, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () { HapticFeedback.lightImpact(); onTap(); },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color:        cs.surfaceContainerHighest.withOpacity(0.5),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: cs.outlineVariant.withOpacity(0.5), width: 0.8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontSize:   13,
                  color:      cs.onSurfaceVariant,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.1)),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Data model
// ─────────────────────────────────────────────────────────────────────────────
class ChatMsg {
  final int    id;
  final bool   fromUser;
  final String text;
  final List<Map<String, dynamic>>? extracted;
  ChatMsg({
    required this.id,
    required this.fromUser,
    required this.text,
    this.extracted,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
//  EDITABLE TRANSACTION CARD
// ─────────────────────────────────────────────────────────────────────────────
class EditableTransactionCard extends StatefulWidget {
  final Map<String, dynamic>          data;
  final Map<String, IconData>          categoryIcons;
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

class _EditableTransactionCardState extends State<EditableTransactionCard> {
  late TextEditingController _amtCtrl;
  late String   _selectedCat;
  late DateTime _selectedDate;

  @override
  void initState() {
    super.initState();
    _amtCtrl = TextEditingController(
        text: widget.data['amount']?.toString() ?? '0');
    _selectedCat = widget.data['category'] ?? 'other';
    try {
      _selectedDate = widget.data['date'] != null &&
              widget.data['date'].toString().isNotEmpty
          ? DateTime.parse(widget.data['date'].toString())
          : DateTime.now();
    } catch (_) { _selectedDate = DateTime.now(); }
  }

  @override
  void dispose() { _amtCtrl.dispose(); super.dispose(); }

  void _notify() {
    final u = Map<String, dynamic>.from(widget.data);
    u['amount']   = double.tryParse(_amtCtrl.text.replaceAll(',', '')) ?? 0.0;
    u['category'] = _selectedCat;
    u['date']     = _selectedDate.toIso8601String().split('T').first;
    widget.onChanged(u);
    setState(() {});
  }

  String _formatDate(DateTime d) {
    final now    = DateTime.now();
    final today  = DateTime(now.year, now.month, now.day);
    final target = DateTime(d.year, d.month, d.day);
    final diff   = target.difference(today).inDays;
    if (diff ==  0) return 'Today';
    if (diff == -1) return 'Yesterday';
    if (diff ==  1) return 'Tomorrow';
    if (diff <  0 && diff >= -6) return '${diff.abs()}d ago';
    if (diff >  1 && diff <=  6) return 'In ${diff}d';
    return '${d.day.toString().padLeft(2, '0')} / '
           '${d.month.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDate(BuildContext context) async {
    final picked = await showDatePicker(
      context:     context,
      initialDate: _selectedDate,
      firstDate:   DateTime(2020),
      lastDate:    DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
      _notify();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;

    final rawDesc  = (widget.data['description'] ?? 'Transaction').toString().trim();
    final catIcon  = widget.categoryIcons[_selectedCat] ?? Icons.category_rounded;
    final validCat = widget.categoryIcons.containsKey(_selectedCat)
        ? _selectedCat : 'other';

    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color:        cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border:       Border.all(color: cs.outlineVariant.withOpacity(0.5), width: 0.5),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color:        cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cs.outlineVariant.withOpacity(0.5), width: 0.5),
                  ),
                  child: Icon(catIcon, color: cs.onSurfaceVariant, size: 16),
                ),
                const SizedBox(width: 8),

                Expanded(
                  child: Theme(
                    data: t.copyWith(
                      splashColor: Colors.transparent,
                      highlightColor: Colors.transparent,
                    ),
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      color: cs.surface,
                      elevation: 8,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: cs.outlineVariant.withOpacity(0.5), width: 0.5),
                      ),
                      constraints: const BoxConstraints(minWidth: 160, maxHeight: 260),
                      onSelected: (val) {
                        _selectedCat = val;
                        _notify();
                      },
                      itemBuilder: (context) => widget.categoryIcons.keys.map((cat) {
                        final displayTitle = cat.split('_')
                            .map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '')
                            .join(' ');
                        return PopupMenuItem<String>(
                          value: cat,
                          height: 44,
                          child: Row(
                            children: [
                              Icon(widget.categoryIcons[cat], size: 16, color: cs.onSurfaceVariant),
                              const SizedBox(width: 10),
                              Text(
                                displayTitle,
                                style: TextStyle(
                                    color: cs.onSurface,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 14,
                                    letterSpacing: 0.3),
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        color: Colors.transparent,
                        child: Row(
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    validCat.split('_')
                                        .map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '')
                                        .join(' '),
                                    style: TextStyle(
                                        color:      cs.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                        fontSize:   12.5,
                                        letterSpacing: 0.5),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.unfold_more_rounded, size: 16, color: t.hintColor),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color:        cs.surface,
                    borderRadius: BorderRadius.circular(10),
                    border:       Border.all(color: cs.outlineVariant, width: 1.0),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text('RM',
                          style: TextStyle(
                              fontSize:   13,
                              color:      cs.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5)),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 75,
                        child: TextField(
                          controller:   _amtCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                          ],
                          textAlign: TextAlign.right,
                          onChanged:  (_) => _notify(),
                          cursorColor:  cs.primary,
                          style: TextStyle(
                              fontSize:   22,
                              fontWeight: FontWeight.w500,
                              color:      cs.onSurface,
                              height:     1.1),
                          decoration: const InputDecoration(
                            isDense:        true,
                            contentPadding: EdgeInsets.zero,
                            border:         InputBorder.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const _Hairline(),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => _pickDate(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: cs.outlineVariant, width: 0.8),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.calendar_today_outlined,
                          size: 11, color: cs.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(_formatDate(_selectedDate),
                          style: TextStyle(
                              fontSize:   12,
                              color:      cs.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.2)),
                    ]),
                  ),
                ),
                const SizedBox(width: 12),

                Expanded(
                  child: Text(
                    rawDesc,
                    overflow:  TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize:   13,
                        color:      cs.onSurfaceVariant,
                        fontWeight: FontWeight.w400),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}