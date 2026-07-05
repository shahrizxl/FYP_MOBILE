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
//  Currency / number-word normalization
//  Converts spoken forms like "five ringgit", "rm five", "lima ringgit",
//  "dua ratus ribu ringgit", "lima ringgit lima puluh sen" into the
//  "RM23" / "RM5.50" style your NLP already expects.
//  Covers English + Malay number words up to hundred-thousands, plus
//  sen/cents. Not a general-purpose number parser (no millions, no spoken
//  decimals like "point five") — that level of coverage is better handled
//  server-side in the NLP service where it's easier to iterate on.
// ─────────────────────────────────────────────────────────────────────────────
class CurrencyNormalizer {
  static const Map<String, int> _enOnes = {
    'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
    'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10,
    'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14,
    'fifteen': 15, 'sixteen': 16, 'seventeen': 17, 'eighteen': 18,
    'nineteen': 19,
  };
  static const Map<String, int> _enTens = {
    'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50,
    'sixty': 60, 'seventy': 70, 'eighty': 80, 'ninety': 90,
  };

  static const Map<String, int> _msOnes = {
    'kosong': 0, 'satu': 1, 'dua': 2, 'tiga': 3, 'empat': 4,
    'lima': 5, 'enam': 6, 'tujuh': 7, 'lapan': 8, 'sembilan': 9,
    'sepuluh': 10, 'sebelas': 11,
  };
  // Malay teens: "dua belas" (12) ... "sembilan belas" (19)
  // Malay tens: "dua puluh" (20) ... "sembilan puluh" (90)
  // Malay hundreds/thousands: "seratus" (100, irregular), "dua ratus" (200),
  // "seribu" (1000, irregular), "dua ribu" (2000), "dua ratus ribu"
  // (200,000 — hundreds combine with "ribu" too, this is the bit that was
  // previously broken).
  static const List<String> _connectors = ['dan', 'and'];

  /// Parses a 0-99 chunk starting at [start]. Building block for hundreds.
  static ({int? value, int consumed}) _parseUnder100(
      List<String> tokens, int start) {
    if (start >= tokens.length) return (value: null, consumed: 0);
    final w = tokens[start].toLowerCase();

    if (_enTens.containsKey(w)) {
      var total = _enTens[w]!;
      var consumed = 1;
      if (start + 1 < tokens.length &&
          _enOnes.containsKey(tokens[start + 1].toLowerCase()) &&
          _enOnes[tokens[start + 1].toLowerCase()]! < 10) {
        total += _enOnes[tokens[start + 1].toLowerCase()]!;
        consumed = 2;
      }
      return (value: total, consumed: consumed);
    }
    if (_enOnes.containsKey(w)) {
      return (value: _enOnes[w]!, consumed: 1);
    }

    if (_msOnes.containsKey(w) &&
        start + 1 < tokens.length &&
        tokens[start + 1].toLowerCase() == 'puluh') {
      var total = _msOnes[w]! * 10;
      var consumed = 2;
      if (start + 2 < tokens.length &&
          _msOnes.containsKey(tokens[start + 2].toLowerCase())) {
        total += _msOnes[tokens[start + 2].toLowerCase()]!;
        consumed = 3;
      }
      return (value: total, consumed: consumed);
    }
    if (_msOnes.containsKey(w) &&
        start + 1 < tokens.length &&
        tokens[start + 1].toLowerCase() == 'belas') {
      return (value: _msOnes[w]! + 10, consumed: 2);
    }
    if (_msOnes.containsKey(w)) {
      return (value: _msOnes[w]!, consumed: 1);
    }

    return (value: null, consumed: 0);
  }

  /// Parses a 0-999 chunk (hundreds + tens/ones), e.g. "two hundred fifty
  /// three", "dua ratus lima puluh tiga", "seratus". This is used both on
  /// its own AND as the multiplier in front of "thousand"/"ribu", which is
  /// what makes "dua ratus ribu" (200,000) resolve correctly — previously
  /// only a bare 0-99 chunk was allowed before "ribu", so anything with a
  /// "ratus" in front of "ribu" silently failed to match.
  static ({int? value, int consumed}) _parseUnder1000(
      List<String> tokens, int start) {
    if (start >= tokens.length) return (value: null, consumed: 0);
    var i = start;
    var total = 0;
    var matched = false;

    final w = tokens[i].toLowerCase();
    if (w == 'seratus') {
      total += 100;
      i += 1;
      matched = true;
    } else {
      final under100 = _parseUnder100(tokens, i);
      if (under100.value != null &&
          under100.value! < 10 &&
          i + under100.consumed < tokens.length) {
        final suffix = tokens[i + under100.consumed].toLowerCase();
        if (suffix == 'hundred' || suffix == 'ratus') {
          total += under100.value! * 100;
          i += under100.consumed + 1;
          matched = true;
        }
      }
    }

    final rest = _parseUnder100(tokens, i);
    if (rest.value != null) {
      total += rest.value!;
      i += rest.consumed;
      matched = true;
    }

    if (!matched) return (value: null, consumed: 0);
    return (value: total, consumed: i - start);
  }

  /// Full number-word parser: thousands (built on _parseUnder1000, so
  /// "dua ratus ribu" / "two hundred thousand" both work) plus a trailing
  /// 0-999 remainder, e.g. "dua ribu tiga ratus lima puluh" (2350),
  /// "seribu" (1000), "seratus" (100). Handles the irregular Malay "se-"
  /// forms ("seratus" = one hundred, "seribu" = one thousand — never
  /// "satu ratus"/"satu ribu").
  static ({int? value, int consumed}) _parseNumberWords(
      List<String> tokens, int start) {
    if (start >= tokens.length) return (value: null, consumed: 0);

    var i = start;
    var total = 0;
    var matchedAny = false;

    // --- thousands part (built on a full 0-999 chunk) ---
    var thousandsVal = 0;
    if (tokens[i].toLowerCase() == 'seribu') {
      thousandsVal = 1;
      i += 1;
      matchedAny = true;
    } else {
      final under1000 = _parseUnder1000(tokens, i);
      if (under1000.value != null &&
          i + under1000.consumed < tokens.length) {
        final suffix = tokens[i + under1000.consumed].toLowerCase();
        if (suffix == 'thousand' || suffix == 'ribu') {
          thousandsVal = under1000.value!;
          i += under1000.consumed + 1;
          matchedAny = true;
        }
      }
    }
    total += thousandsVal * 1000;

    // --- remaining 0-999 part ---
    final rest = _parseUnder1000(tokens, i);
    if (rest.value != null) {
      total += rest.value!;
      i += rest.consumed;
      matchedAny = true;
    }

    if (!matchedAny) return (value: null, consumed: 0);
    return (value: total, consumed: i - start);
  }

  /// Parses a cents/sen amount: numeric ("50 sen") or word-based
  /// ("lima puluh sen", "fifty sen"). Cents only ever need 0-99, so this
  /// rides on _parseUnder100 rather than the full number parser.
  static ({int? value, int consumed}) _parseCents(
      List<String> tokens, int start) {
    if (start >= tokens.length) return (value: null, consumed: 0);

    final numMatch = RegExp(r'^\d{1,2}$').firstMatch(tokens[start]);
    if (numMatch != null &&
        start + 1 < tokens.length &&
        tokens[start + 1].toLowerCase() == 'sen') {
      return (value: int.parse(tokens[start]), consumed: 2);
    }

    final parsed = _parseUnder100(tokens, start);
    if (parsed.value != null &&
        start + parsed.consumed < tokens.length &&
        tokens[start + parsed.consumed].toLowerCase() == 'sen') {
      return (value: parsed.value, consumed: parsed.consumed + 1);
    }

    return (value: null, consumed: 0);
  }

  static int _skipConnector(List<String> tokens, int i) {
    if (i < tokens.length && _connectors.contains(tokens[i].toLowerCase())) {
      return i + 1;
    }
    return i;
  }

  static String _padCents(int v) => v.toString().padLeft(2, '0');

  /// Normalizes spoken currency phrases into "RM<amount>" tokens, e.g.:
  ///   "coffee five ringgit"          -> "coffee RM5"
  ///   "rm five"                      -> "RM5"
  ///   "dua ratus ribu ringgit"       -> "RM200000"
  ///   "lima ringgit lima puluh sen"  -> "RM5.50"
  ///   "50 sen"                       -> "RM0.50"
  /// Numeric forms like "RM5", "5 RM", "5.50 ringgit" are also normalized to
  /// a consistent "RM<amount>" pattern.
  static String normalize(String input) {
    var text = input;

    // Numeric-first forms: "5 ringgit", "5 rm", "5.50 ringgit"
    text = text.replaceAllMapped(
      RegExp(r'(\d+(?:\.\d+)?)\s*(ringgit|rm)\b', caseSensitive: false),
      (m) => 'RM${m.group(1)}',
    );
    // "rm 5" / "rm5" already close to desired form; just tighten spacing.
    text = text.replaceAllMapped(
      RegExp(r'\brm\s*(\d+(?:\.\d+)?)\b', caseSensitive: false),
      (m) => 'RM${m.group(1)}',
    );

    final tokens = text.split(RegExp(r'\s+'));
    final out = <String>[];
    var i = 0;
    while (i < tokens.length) {
      final lower = tokens[i].toLowerCase();

      // Case: an already-numeric "RM5" (from the regex pass above) that
      // might still have spoken cents trailing it, e.g. "RM5 lima puluh sen".
      final rmNumeric = RegExp(r'^RM(\d+)$').firstMatch(tokens[i]);
      if (rmNumeric != null) {
        final next = _skipConnector(tokens, i + 1);
        final cents = _parseCents(tokens, next);
        if (cents.value != null) {
          out.add('RM${rmNumeric.group(1)}.${_padCents(cents.value!)}');
          i = next + cents.consumed;
          continue;
        }
        out.add(tokens[i]);
        i++;
        continue;
      }

      // "rm <words>" [dan/and <cents> sen]
      if (lower == 'rm' && i + 1 < tokens.length) {
        final parsed = _parseNumberWords(tokens, i + 1);
        if (parsed.value != null) {
          final afterAmount = i + 1 + parsed.consumed;
          final next = _skipConnector(tokens, afterAmount);
          final cents = _parseCents(tokens, next);
          if (cents.value != null) {
            out.add('RM${parsed.value}.${_padCents(cents.value!)}');
            i = next + cents.consumed;
            continue;
          }
          out.add('RM${parsed.value}');
          i = afterAmount;
          continue;
        }
      }

      // "<words> ringgit" [dan/and <cents> sen]
      final parsed = _parseNumberWords(tokens, i);
      if (parsed.value != null) {
        final after = i + parsed.consumed;
        if (after < tokens.length &&
            tokens[after].toLowerCase() == 'ringgit') {
          final afterRinggit = after + 1;
          final next = _skipConnector(tokens, afterRinggit);
          final cents = _parseCents(tokens, next);
          if (cents.value != null) {
            out.add('RM${parsed.value}.${_padCents(cents.value!)}');
            i = next + cents.consumed;
            continue;
          }
          out.add('RM${parsed.value}');
          i = afterRinggit;
          continue;
        }
      }

      // Standalone cents with no ringgit part at all, e.g. "50 sen" or
      // "lima puluh sen" on its own -> RM0.50.
      final centsOnly = _parseCents(tokens, i);
      if (centsOnly.value != null) {
        out.add('RM0.${_padCents(centsOnly.value!)}');
        i += centsOnly.consumed;
        continue;
      }

      out.add(tokens[i]);
      i++;
    }

    return out.join(' ');
  }
}

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
  // Stable id attached to each extracted transaction map (see sendMessage),
  // used as a widget key so removing one card doesn't cause Flutter to
  // reuse a stateful card's controller/state across different data when
  // list indices shift.
  int                 _nextLocalTxId = 1;
  final _scrollCtrl = ScrollController();

  // Speech
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool    _speechReady   = false;
  bool    _isListening   = false;
  String  _preSpeechText = '';
  int     _retryCount    = 0;
  static const int _maxRetries = 2;

  // 🔥 FIX: guards against a stale onResult callback landing after we've
  // already stopped listening (e.g. user pressed Enter mid-speech). Without
  // this, speech_to_text's final callback can re-populate the text field
  // right after sendMessage() cleared it.
  bool _ignoreSpeechResults = false;

  // Locale resolved from the device rather than hardcoded.
  String _enLocaleId = 'en_US';
  String _msLocaleId = 'ms_MY';
  bool   _useMalay    = false;

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

    if (_speechReady) {
      await _resolveLocales();
    }

    if (!_speechReady && mounted) {
      setState(() => error = 'Microphone permission denied. Enable it in Settings.');
    } else if (mounted) {
      setState(() {});
    }
  }

  Future<void> _resolveLocales() async {
    try {
      final locales = await _speech.locales();
      for (final l in locales) {
        final id = l.localeId.toLowerCase();
        if (id.startsWith('en')) _enLocaleId = l.localeId;
        if (id.startsWith('ms')) _msLocaleId = l.localeId;
      }
    } catch (_) {
      // Keep defaults.
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
      Future.delayed(const Duration(milliseconds: 500), () {
        // 🔥 FIX: don't auto-retry into a listening session if the user (or
        // dispose()) has since asked us to stop / ignore results.
        if (_ignoreSpeechResults) return;
        _startListening();
      });
      return;
    }

    _retryCount = 0;
    setState(() => error = 'Voice input failed. Please try again.');
  }

  // ── Start Listening ────────────────────────────────────────────────────────
  Future<void> _startListening() async {
    if (!mounted) return;
    if (!_speechReady) {
      setState(() => error = 'Microphone not available.');
      return;
    }
    // 🔥 FIX: guards a fast double-tap on the mic button. Without this,
    // two overlapping calls can both capture _preSpeechText before either
    // has updated _isListening, so the second call captures a stale value.
    if (_isListening) return;

    if (_speech.isListening) {
      await _speech.stop();
    }

    _ignoreSpeechResults = false;
    _preSpeechText = ctrl.text.trim();
    setState(() { _isListening = true; error = null; });

    await _speech.listen(
      listenMode:     stt.ListenMode.dictation,
      partialResults: true,
      listenFor:      const Duration(seconds: 30),
      pauseFor:       const Duration(seconds: 3),
      onResult:       _onSpeechResult,
      localeId:       _useMalay ? _msLocaleId : _enLocaleId,
    );
  }

  void _onSpeechResult(dynamic result) {
    // 🔥 FIX: drop any callback that arrives after we've asked to stop.
    if (_ignoreSpeechResults) return;
    if (!mounted) return;

    final spoken = (result.recognizedWords as String).trim();
    if (spoken.isEmpty) return;

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
    // 🔥 FIX: set this *before* awaiting stop(), so the trailing final
    // onResult callback that speech_to_text fires during/after stop() is
    // ignored instead of overwriting text we've already cleared/sent.
    _ignoreSpeechResults = true;

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

  // ── Toggle Speech Language ─────────────────────────────────────────────────
  void _toggleSpeechLocale() {
    HapticFeedback.selectionClick();
    setState(() => _useMalay = !_useMalay);
  }

  @override
  void dispose() {
    // 🔥 FIX: stop any in-flight retry/callback from touching state after
    // this widget is gone.
    _ignoreSpeechResults = true;
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
    // 🔥 FIX: normalize spoken/typed currency phrases ("five ringgit",
    // "lima ringgit", "rm five") into the "RM<amount>" pattern the NLP
    // service already understands, before we ever send it off.
    final rawText = ctrl.text.trim();
    if (rawText.isEmpty) { setState(() => error = 'Type or speak first.'); return; }
    final text = CurrencyNormalizer.normalize(rawText);

    setState(() {
      error = null; loading = true;
      messages.add(ChatMsg(id: _nextId++, fromUser: true, text: rawText));
    });
    ctrl.text = '';
    Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);

    try {
      final res    = await nlp.analyze(text);
      final parsed = List<Map<String, dynamic>>.from(res);
      // Tag each parsed transaction with a stable local id (not shown to
      // the user, stripped before saving) so cards can be safely removed
      // from the middle of the list without Flutter reusing state.
      for (final r in parsed) {
        r['_localTxId'] = _nextLocalTxId++;
      }
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

  // Removes a single extracted transaction from an AI reply's list, so an
  // over-eager NLP result (e.g. it split one sentence into two
  // transactions) can be corrected before saving. Once a message has been
  // saved this is disabled (see alreadySaved handling in _AiBubble).
  void _removeExtractedAt(int msgId, int index) {
    HapticFeedback.lightImpact();
    setState(() {
      final msg = messages.firstWhere((m) => m.id == msgId);
      if (msg.extracted == null || index < 0 || index >= msg.extracted!.length) {
        return;
      }
      msg.extracted!.removeAt(index);
    });
  }

  Widget _bubble(ChatMsg m) {
    final isUser       = m.fromUser;
    final alreadySaved = savedMsgIds.contains(m.id);

    return Padding(
      key: ValueKey(m.id),
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.84),
          child: isUser
              ? _UserBubble(text: m.text)
              : _AiBubble(
                  msgId:         m.id,
                  text:          m.text,
                  extracted:     m.extracted,
                  alreadySaved:  alreadySaved,
                  categoryIcons: categoryIcons,
                  loading:       loading,
                  onSave: () => saveFromReply(m.id, m.extracted!),
                  onRemoveAt: (idx) => _removeExtractedAt(m.id, idx),
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

    return Stack(
      clipBehavior: Clip.none,
      children: [
        GestureDetector(
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
        ),
        Positioned(
          right: -2,
          top: -2,
          child: GestureDetector(
            onTap: (loading || _isListening) ? null : _toggleSpeechLocale,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: cs.outlineVariant, width: 0.8),
              ),
              child: Text(
                _useMalay ? 'BM' : 'EN',
                style: TextStyle(
                  fontSize:   9,
                  fontWeight: FontWeight.w700,
                  color:      cs.onSurface,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ),
      ],
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
                          ? (_useMalay ? 'Mendengar...' : 'Listening...')
                          : (_useMalay ? 'Contoh: Nasi lemak RM8' : 'e.g. Coffee RM8'),
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
  final int                         msgId;
  final String                      text;
  final List<Map<String, dynamic>>? extracted;
  final bool                        alreadySaved;
  final Map<String, IconData>       categoryIcons;
  final bool                        loading;
  final VoidCallback                onSave;
  final void Function(int index)    onRemoveAt;

  const _AiBubble({
    required this.msgId,
    required this.text,
    required this.extracted,
    required this.alreadySaved,
    required this.categoryIcons,
    required this.loading,
    required this.onSave,
    required this.onRemoveAt,
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
            if (extracted!.length > 1 && !alreadySaved)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${extracted!.length} transactions found — remove any that don\'t belong.',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w400),
                ),
              ),
            ...extracted!.asMap().entries.map((e) =>
              EditableTransactionCard(
                // Keyed by a stable per-transaction id (not the list index)
                // so removing a card from the middle doesn't make Flutter
                // reuse another card's controller/state for different data.
                key:           ValueKey('${msgId}_${e.value['_localTxId'] ?? e.key}'),
                data:          e.value,
                categoryIcons: categoryIcons,
                onChanged:     (u) => extracted![e.key] = u,
                onRemove:      alreadySaved ? null : () => onRemoveAt(e.key),
              ),
            ),
            const SizedBox(height: 16),
            _ConfirmButton(
              saved:   alreadySaved,
              loading: loading,
              onTap:   alreadySaved || loading ? null : onSave,
            ),
          ] else if (extracted != null && extracted!.isEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'All transactions removed. Nothing to save.',
              style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w400),
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
//  Decimal amount formatter — rejects an invalid edit instead of mangling it
// ─────────────────────────────────────────────────────────────────────────────
class _DecimalInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue;
    if (RegExp(r'^\d+\.?\d{0,2}$').hasMatch(newValue.text)) return newValue;
    return oldValue;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  EDITABLE TRANSACTION CARD
// ─────────────────────────────────────────────────────────────────────────────
class EditableTransactionCard extends StatefulWidget {
  final Map<String, dynamic>          data;
  final Map<String, IconData>          categoryIcons;
  final Function(Map<String, dynamic>) onChanged;
  // Null hides the remove button entirely (e.g. once the message is saved).
  final VoidCallback?                  onRemove;

  const EditableTransactionCard({
    super.key,
    required this.data,
    required this.categoryIcons,
    required this.onChanged,
    this.onRemove,
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
    final rawAmt = widget.data['amount'];
    final numAmt = rawAmt is num
        ? rawAmt.toDouble()
        : double.tryParse(rawAmt?.toString().replaceAll(',', '') ?? '') ?? 0.0;
    _amtCtrl = TextEditingController(text: formatAmount(numAmt));
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
      _selectedDate = picked;
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

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
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
                          inputFormatters: [_DecimalInputFormatter()],
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
          ),
          // Remove button — lets you drop a transaction the NLP shouldn't
          // have split out (e.g. one sentence parsed into two entries)
          // before confirming. Hidden once the message has been saved.
          if (widget.onRemove != null)
            Positioned(
              right: -6,
              top: -6,
              child: GestureDetector(
                onTap: widget.onRemove,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.surface,
                    border: Border.all(color: cs.outlineVariant, width: 0.8),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context).shadowColor.withOpacity(0.06),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Icon(Icons.close_rounded,
                      size: 13, color: cs.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }
}