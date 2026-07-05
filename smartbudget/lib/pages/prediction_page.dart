import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../api_config.dart';
import '../services/transaction_service.dart';
import '../services/notification_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PREDICTION DETAILS PAGE
// ─────────────────────────────────────────────────────────────────────────────
class PredictionDetailsPage extends StatefulWidget {
  const PredictionDetailsPage({super.key});

  @override
  State<PredictionDetailsPage> createState() => _PredictionDetailsPageState();
}

class _PredictionDetailsPageState extends State<PredictionDetailsPage> {
  final _txService = TransactionService();

  // ── Loading ──────────────────────────────────────────────────────────────
  bool _txLoading = true;
  bool _predLoading = false;
  String? _txError;
  List<Map<String, dynamic>> _txs = [];

  // ── Date selection ───────────────────────────────────────────────────────
  int _selectedYear = DateTime.now().year;
  int? _selectedMonth = DateTime.now().month;

  // ── Budget ───────────────────────────────────────────────────────────────
  double _monthlyBudget = 0;

  // ── Prediction state ─────────────────────────────────────────────────────
  String? _predError;
  String? _predMessage;
  double? _predNextDay;
  double? _predNextWeek;
  double? _predNextMonth;
  double? _predNextMonthLower;
  double? _predNextMonthUpper;
  String? _predExplanationText;
  List<Map<String, dynamic>> _predFeatureImportances = [];
  Map<String, dynamic>? _predWeekendInfluence;
  List<Map<String, dynamic>> _predCategoryImpact = [];
  List<Map<String, dynamic>> _predAnomalies = [];
  Map<String, dynamic>? _predMonthlyTrend;
  double? _forecastProgress;
  double? _actualSpentSoFar;
  double? _remainingPrediction;
  int _predReqId = 0;

  // ── ML readiness (cached to prevent build jank) ───────────────────────────
  int _mlDaysCount = 0;
  double _mlProgress = 0.0;
  bool _mlReady = false;
  int _mlDaysRemaining = 30;

  // ─────────────────────────────────────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────────────────────────────────────
  String? get _userId => Supabase.instance.client.auth.currentUser?.id;

  DateTime? _parseDate(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    return null;
  }

  double _asDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  double? _numOrNull(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }

  // FIX 1: Bulletproof JSON parsing. whereType<Map<String, dynamic>>() fails
  // if the runtime type parsed is Map<dynamic, dynamic>. Map.from is reliable.
  List<Map<String, dynamic>> _parseJsonList(dynamic source) {
    if (source is! List) return [];
    return source.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LIFECYCLE
  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // DATA LOADERS
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadTx() async {
    final uid = _userId;
    if (uid == null || !mounted) return;

    setState(() {
      _txLoading = true;
      _txError = null;
    });

    try {
      final data = await _txService.getMyTransactions(uid);

      final parsedData = data.map((t) {
        final dt = _parseDate(t['date'])?.toLocal() ?? DateTime(0);
        return {...t, '_parsedDate': dt};
      }).toList();

      parsedData.sort((a, b) =>
          (b['_parsedDate'] as DateTime).compareTo(a['_parsedDate'] as DateTime));

      if (!mounted) return;
      _txs = parsedData;
      _calculateMlMetrics();
    } catch (e) {
      if (!mounted) return;
      setState(() => _txError = e.toString());
    } finally {
      if (mounted) setState(() => _txLoading = false);
    }
  }

  void _calculateMlMetrics() {
    // FIX (Bug 2): The backend uses MIN_UNIQUE_DAYS_FOR_ML = 30 *unique active
    // days* (days that have at least one expense). The old code measured the
    // calendar span between first and last expense and compared it against 90,
    // which is a completely different metric and caused the readiness card to
    // show "not ready" for users who already had ML running in the backend.
    const int mlThreshold = 30;

    final now = DateTime.now();
    // FIX (Bug 3 partial): Use a safe 13-month lookback that mirrors what
    // _loadPrediction now sends so the readiness count matches what the backend
    // actually sees.  DateTime handles month underflow by rolling the year back.
    int tYear  = now.year;
    int tMonth = now.month - 13;
    while (tMonth <= 0) {
      tMonth += 12;
      tYear  -= 1;
    }
    final trainStart = DateTime(tYear, tMonth, 1);

    final uniqueDays = <String>{};

    for (final tx in _txs) {
      final type = tx['type']?.toString().toLowerCase().trim() ?? 'expense';
      if (type != 'expense') continue;

      final raw = tx['_parsedDate'];
      if (raw is! DateTime) continue;
      final dt = raw;

      if (dt.isBefore(trainStart) || dt.isAfter(now)) continue;

      // Collect unique calendar dates (yyyy-MM-dd) that have an expense.
      uniqueDays.add(DateFormat('yyyy-MM-dd').format(dt));
    }

    final count = uniqueDays.length;

    setState(() {
      _mlDaysCount    = count;
      _mlDaysRemaining = (mlThreshold - count).clamp(0, mlThreshold);
      _mlProgress     = (count / mlThreshold).clamp(0.0, 1.0);
      _mlReady        = count >= mlThreshold;
    });
  }

  Future<void> _loadBudget() async {
    final uid = _userId;
    if (uid == null || _selectedMonth == null) return;
    try {
      final res = await Supabase.instance.client
          .from('category_budgets')
          .select('monthly_budget')
          .eq('user_id', uid)
          .eq('year', _selectedYear)
          .eq('month', _selectedMonth!)
          .maybeSingle();

      if (!mounted) return;
      setState(() => _monthlyBudget = _asDouble(res?['monthly_budget']));
    } catch (_) {}
  }

  void _clearPredictionState() {
    _predNextDay = null;
    _predNextWeek = null;
    _predNextMonth = null;
    _predNextMonthLower = null;
    _predNextMonthUpper = null;
    _predExplanationText = null;
    _predFeatureImportances = [];
    _predWeekendInfluence = null;
    _predCategoryImpact = [];
    _predAnomalies = [];
    _predMonthlyTrend = null;
    _forecastProgress = null;
    _actualSpentSoFar = null;
    _remainingPrediction = null;
    _predMessage = null;
  }

  Future<http.Response> _postWithRetry(
    Uri uri,
    Map<String, dynamic> body, {
    int maxAttempts = 2,
    Duration timeout = const Duration(seconds: 60),
    Duration retryDelay = const Duration(seconds: 2),
  }) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body),
            )
            .timeout(timeout);
      } on TimeoutException {
        if (attempt == maxAttempts - 1) rethrow;
        await Future.delayed(retryDelay);
      }
    }
    throw TimeoutException('Request timed out after $maxAttempts attempts.');
  }

  Future<void> _loadPrediction() async {
    if (!mounted || _txs.isEmpty) {
      if (mounted) {
        setState(() {
          _predLoading = false;
          _predError = 'No transaction data available.';
        });
      }
      return;
    }

    final int reqId = ++_predReqId;
    setState(() {
      _predLoading = true;
      _predError = null;
      _clearPredictionState();
    });

    // FIX (Bug 3): The backend's _prev_six_full_months_window() selects the
    // 6 full calendar months *before* the anchor month as its training window.
    // When Flutter only sent 6 months total, the backend had nothing left for
    // training and fell back to an even shorter window, hurting model quality.
    // We now send 13 months so the backend always has a full 6-month window
    // available regardless of which anchor month the user has selected.
    //
    // Also fixes the month-underflow bug: DateTime(year, month - 6, 1) produces
    // month = 0 or negative values in Jan–Jun which can behave unexpectedly.
    // The safe approach is to decrement year/month manually.
    final now = DateTime.now();
    int tYear  = now.year;
    int tMonth = now.month - 13;
    while (tMonth <= 0) {
      tMonth += 12;
      tYear  -= 1;
    }
    final trainStart = DateTime(tYear, tMonth, 1);

    final expenses = _txs
        .where((t) {
          if ((t['type'] ?? '').toString().trim().toLowerCase() != 'expense') {
            return false;
          }
          final raw = t['_parsedDate'];
          if (raw is! DateTime) return false;
          return !raw.isBefore(trainStart) && !raw.isAfter(now);
        })
        .map((t) {
          final dt = t['_parsedDate'] as DateTime;
          return {
            'date': DateFormat('yyyy-MM-dd').format(dt),
            'amount': _asDouble(t['amount']),
            'type': 'expense',
            'description': (t['description'] ?? '').toString(),
            'category': (t['category'] ?? '').toString(),
          };
        })
        .toList()
      ..sort((a, b) {
        final ad = DateTime.tryParse(a['date'] as String) ?? DateTime(1970);
        final bd = DateTime.tryParse(b['date'] as String) ?? DateTime(1970);
        return ad.compareTo(bd);
      });

    if (expenses.isEmpty) {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        _predLoading = false;
        _predError = 'No expense records found.';
      });
      return;
    }

    final Map<String, dynamic> body = {
      'transactions': expenses,
      'days': 60,
    };

    if (_selectedMonth != null) {
      body['anchor_year'] = _selectedYear;
      body['anchor_month'] = _selectedMonth!;
    }

    try {
      final res = await _postWithRetry(
        Uri.parse(ApiConfig.predictUrl),
        body,
      );

      if (!mounted || reqId != _predReqId) return;

      if (res.statusCode < 200 || res.statusCode >= 300) {
        setState(() {
          _predLoading = false;
          _predError = 'Prediction unavailable (HTTP ${res.statusCode}).';
        });
        return;
      }

      final decoded = jsonDecode(res.body);
      final data =
          (decoded is Map<String, dynamic>) ? decoded : <String, dynamic>{};

      final nd  = _numOrNull(data['next_day']);
      final nw  = _numOrNull(data['next_week']);
      final nm  = _numOrNull(data['next_month']);
      final nml = _numOrNull(data['next_month_lower']);
      final nmu = _numOrNull(data['next_month_upper']);
      final msg = (data['message'] ?? '').toString().trim();

      // Safely parse top level arrays
      final anomalies = _parseJsonList(data['anomalies']);

      String? explanationText;
      List<Map<String, dynamic>> featureImportances = [];
      Map<String, dynamic>? weekendInfluence;
      List<Map<String, dynamic>> categoryImpact = [];

      if (data['explainability'] is Map) {
        final expl = Map<String, dynamic>.from(data['explainability']);
        explanationText = expl['explanation_text']?.toString();

        featureImportances = _parseJsonList(expl['feature_importances']);
        categoryImpact     = _parseJsonList(expl['category_impact']);

        if (expl['weekend_influence'] is Map) {
          weekendInfluence = Map<String, dynamic>.from(expl['weekend_influence']);
        }
      }

      Map<String, dynamic>? monthlyTrend;
      if (data['monthly_trend'] is Map) {
        monthlyTrend = Map<String, dynamic>.from(data['monthly_trend']);
      }

      double? actualSpent;
      double? remainingPrediction;
      double? forecastProgress;
      if (data['live_metrics'] is Map) {
        final lm = Map<String, dynamic>.from(data['live_metrics']);
        actualSpent         = _numOrNull(lm['actual_spent']);
        remainingPrediction = _numOrNull(lm['remaining_prediction']);
        forecastProgress    = _numOrNull(lm['progress_pct']);
      }

      setState(() {
        _predNextDay         = nd;
        _predNextWeek        = nw;
        _predNextMonth       = nm;
        _predNextMonthLower  = nml;
        _predNextMonthUpper  = nmu;
        _predLoading         = false;
        _predMessage         = msg.isEmpty ? null : msg;
        _predError           = null;
        _predExplanationText = explanationText;
        _predFeatureImportances = featureImportances;
        _predWeekendInfluence   = weekendInfluence;
        _predCategoryImpact     = categoryImpact;
        _predAnomalies          = anomalies;
        _predMonthlyTrend       = monthlyTrend;
        _actualSpentSoFar       = actualSpent;
        _remainingPrediction    = remainingPrediction;
        _forecastProgress       = forecastProgress;
      });

      if (_selectedMonth != null &&
          _predNextMonth != null &&
          _monthlyBudget > 0) {
        await NotificationService.instance.safeSpendingWarning(
          predicted:     _predNextMonth!,
          monthlyBudget: _monthlyBudget,
          budgetYear:    _selectedYear,
          budgetMonth:   _selectedMonth!,
        );
      }
    } on TimeoutException {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        _predLoading = false;
        _predError = 'Prediction timed out after retrying. Please try again.';
      });
    } catch (e) {
      if (!mounted || reqId != _predReqId) return;
      setState(() {
        _predLoading = false;
        _predError = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _clearPredictionState();
    });
    await Future.wait([
      _loadTx(),
      _loadBudget(),
    ]);
    await _loadPrediction();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final t  = Theme.of(context);
    final cs = t.colorScheme;
    final isDark = t.brightness == Brightness.dark;

    final bool isMonthMode = _selectedMonth != null;
    final DateTime now = DateTime.now();
    final bool isFuture = isMonthMode
        ? (_selectedYear > now.year ||
            (_selectedYear == now.year && _selectedMonth! > now.month))
        : (_selectedYear > now.year);

    final double? displayNextDay   = isFuture ? null : _predNextDay;
    final double? displayNextWeek  = isFuture ? null : _predNextWeek;
    final double? displayNextMonth = isFuture ? null : _predNextMonth;
    final double? displayLower     = isFuture ? null : _predNextMonthLower;
    final double? displayUpper     = isFuture ? null : _predNextMonthUpper;

    final bool showExplain = !isFuture &&
        !_predLoading &&
        ((_predExplanationText?.isNotEmpty ?? false) || _predFeatureImportances.isNotEmpty);

    final bool showAnomalies =
        !isFuture && !_predLoading && _predAnomalies.isNotEmpty;

    final bool showTrend =
        !isFuture && !_predLoading && _predMonthlyTrend != null;

    final bool showLiveMetrics = !isFuture &&
        !_predLoading &&
        (_actualSpentSoFar != null ||
            _remainingPrediction != null ||
            _forecastProgress != null);

    return Scaffold(
      backgroundColor: cs.surfaceContainerLowest,
      appBar: AppBar(
        backgroundColor: cs.surfaceContainerLowest,
        centerTitle: true,
        title: const Text(
          'AI Predictions',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _txLoading
          ? const Center(child: CircularProgressIndicator())
          : _txError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 56, color: cs.error),
                        const SizedBox(height: 16),
                        Text(_txError!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.error)),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _refresh,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                    children: [
                      // ── Period Picker ──────────────────────────────────
                      _PredDetailPicker(
                        year: _selectedYear,
                        month: _selectedMonth,
                        onChanged: (y, m) async {
                          setState(() {
                            _selectedYear  = y;
                            _selectedMonth = m;
                            _predError     = null;
                            _predMessage   = null;
                            _clearPredictionState();
                          });
                          await _loadBudget();
                          await _loadPrediction();
                        },
                      ),
                      const SizedBox(height: 16),

                      // ── ML Readiness Card ──────────────────────────────
                      _MLReadinessCard(
                        daysCount:     _mlDaysCount,
                        progress:      _mlProgress,
                        mlReady:       _mlReady,
                        daysRemaining: _mlDaysRemaining,
                      ),
                      const SizedBox(height: 16),

                      // ── Forecast Cards ─────────────────────────────────
                      _PredSection(
                        title: 'Forecast',
                        icon:  Icons.auto_awesome_rounded,
                        child: _predLoading
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child:
                                    Center(child: CircularProgressIndicator()),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (_predMessage != null)
                                    _InfoBadge(
                                        message: _predMessage!,
                                        isDark:  isDark,
                                        isError: false),
                                  if (_predError != null)
                                    _InfoBadge(
                                        message: _predError!,
                                        isDark:  isDark,
                                        isError: true),
                                  if (displayNextDay == null &&
                                      displayNextWeek == null &&
                                      displayNextMonth == null)
                                    Text(
                                      'Keep logging transactions to unlock AI predictions.',
                                      style: TextStyle(color: t.hintColor),
                                    )
                                  else
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _MiniPredCard(
                                            title: 'Tomorrow',
                                            value: displayNextDay,
                                            icon:  Icons.today_rounded,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: _MiniPredCard(
                                            title: '1 Week',
                                            value: displayNextWeek,
                                            icon:  Icons.date_range_rounded,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: _MiniPredCard(
                                            title: isMonthMode
                                                ? 'This Month'
                                                : 'Month',
                                            value: displayNextMonth,
                                            icon:  Icons.calendar_month_rounded,
                                          ),
                                        ),
                                      ],
                                    ),
                                  if (displayLower != null &&
                                      displayUpper != null) ...[
                                    const SizedBox(height: 10),
                                    _ConfidenceIntervalRow(
                                        lower: displayLower,
                                        upper: displayUpper),
                                  ],
                                ],
                              ),
                      ),
                      const SizedBox(height: 16),

                      // ── Explainability ─────────────────────────────────
                      if (showExplain) ...[
                        _ExplainabilityPanel(
                          explanationText:    _predExplanationText,
                          featureImportances: _predFeatureImportances,
                          weekendInfluence:   _predWeekendInfluence,
                          categoryImpact:     _predCategoryImpact,
                        ),
                        const SizedBox(height: 16),
                      ],

                      // ── Anomalies ──────────────────────────────────────
                      if (showAnomalies) ...[
                        _AnomalyPanel(anomalies: _predAnomalies),
                        const SizedBox(height: 16),
                      ],

                      // ── Monthly Trend ──────────────────────────────────
                      if (showTrend) ...[
                        _MonthlyTrendPanel(trend: _predMonthlyTrend!),
                        const SizedBox(height: 16),
                      ],

                      // ── Live Metrics ───────────────────────────────────
                      if (showLiveMetrics) ...[
                        _PredSection(
                          title: 'This Month So Far',
                          icon:  Icons.speed_rounded,
                          child: Column(
                            children: [
                              _LiveMetricRow(
                                label:      'Spent So Far',
                                value:      'RM ${(_actualSpentSoFar ?? 0).toStringAsFixed(2)}',
                                valueColor: cs.onSurface,
                              ),
                              const SizedBox(height: 8),
                              _LiveMetricRow(
                                label:      'Expected to Spend',
                                value:      'RM ${(_remainingPrediction ?? 0).toStringAsFixed(2)}',
                                valueColor: cs.onSurface,
                              ),
                              const SizedBox(height: 8),
                              _LiveMetricRow(
                                label:      'Month Progress',
                                value:      '${(_forecastProgress ?? 0).toStringAsFixed(1)}%',
                                valueColor: cs.primary,
                              ),
                              if (_forecastProgress != null) ...[
                                const SizedBox(height: 10),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: LinearProgressIndicator(
                                    value: ((_forecastProgress ?? 0) / 100)
                                        .clamp(0.0, 1.0),
                                    minHeight:       7,
                                    backgroundColor: cs.surfaceContainerHighest,
                                    color:           cs.primary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // ── Empty state ────────────────────────────────────
                      if (!_predLoading &&
                          _predError == null &&
                          !showExplain &&
                          !showAnomalies &&
                          !showTrend &&
                          !showLiveMetrics)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 32),
                            child: Column(
                              children: [
                                Icon(Icons.auto_awesome_rounded,
                                    size:  48,
                                    color: cs.primary.withValues(alpha: 0.4)),
                                const SizedBox(height: 12),
                                Text(
                                  'Not enough data yet',
                                  style: TextStyle(
                                      fontSize:   16,
                                      fontWeight: FontWeight.bold,
                                      color:      cs.onSurface),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Log expenses across at least 30 different days\nto unlock detailed AI insights.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color:  cs.onSurfaceVariant,
                                      height: 1.5),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ML READINESS CARD
// ─────────────────────────────────────────────────────────────────────────────
class _MLReadinessCard extends StatelessWidget {
  final int daysCount;
  final double progress;
  final bool mlReady;
  final int daysRemaining;

  const _MLReadinessCard({
    required this.daysCount,
    required this.progress,
    required this.mlReady,
    required this.daysRemaining,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        cs.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width:  56,
            height: 56,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value:             progress.clamp(0.0, 1.0),
                  strokeWidth:       5,
                  backgroundColor: cs.surfaceContainerHighest,
                  color: mlReady ? Colors.green.shade500 : cs.primary,
                ),
                Icon(
                  mlReady
                      ? Icons.check_circle_outline_rounded
                      : Icons.model_training_rounded,
                  size:  22,
                  color: mlReady ? Colors.green.shade500 : cs.primary,
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mlReady ? 'Your Predictions Are Ready' : 'Learning Your Habits',
                  style: TextStyle(
                      fontSize:   15,
                      fontWeight: FontWeight.bold,
                      color:      cs.onSurface),
                ),
                const SizedBox(height: 4),
                Text(
                  mlReady
                      ? 'We\'re using your full spending history to predict what\'s next.'
                      : 'Log expenses on $daysCount out of 30 days so far — $daysRemaining more to go before predictions turn on.',
                  style: TextStyle(
                      fontSize: 12.5,
                      color:    cs.onSurfaceVariant,
                      height:   1.45),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value:             progress,
                    minHeight:       5,
                    backgroundColor: cs.surfaceContainerHighest,
                    color: mlReady ? Colors.green.shade500 : cs.primary,
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

// ─────────────────────────────────────────────────────────────────────────────
// PERIOD PICKER
// ─────────────────────────────────────────────────────────────────────────────
class _PredDetailPicker extends StatelessWidget {
  final int year;
  final int? month;
  final void Function(int year, int? month) onChanged;

  const _PredDetailPicker({
    required this.year,
    required this.month,
    required this.onChanged,
  });

  Future<void> _pickDate(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet(
      context:            context,
      isScrollControlled: true,
      showDragHandle:     true,
      backgroundColor:    cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6),
            child: DefaultTabController(
              length: 2,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const TabBar(tabs: [Tab(text: 'Month'), Tab(text: 'Year')]),
                  Expanded(
                    child: TabBarView(
                      children: [
                        // Month grid
                        GridView.builder(
                          padding: const EdgeInsets.all(16),
                          physics: const BouncingScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount:   3,
                            childAspectRatio: 2.4,
                            crossAxisSpacing: 8,
                            mainAxisSpacing:  8,
                          ),
                          itemCount: 13,
                          itemBuilder: (_, index) {
                            if (index == 0) {
                              return _PickerTile(
                                text:       'All Year',
                                isSelected: month == null,
                                onTap: () {
                                  Navigator.pop(ctx);
                                  onChanged(year, null);
                                },
                              );
                            }
                            final m = index;
                            return _PickerTile(
                              text: DateFormat('MMM')
                                  .format(DateTime(2000, m)),
                              isSelected: month == m,
                              onTap: () {
                                Navigator.pop(ctx);
                                onChanged(year, m);
                              },
                            );
                          },
                        ),
                        // Year grid: 3 past, current, 3 future
                        GridView.builder(
                          padding: const EdgeInsets.all(16),
                          physics: const BouncingScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount:   3,
                            childAspectRatio: 2.4,
                            crossAxisSpacing: 8,
                            mainAxisSpacing:  8,
                          ),
                          itemCount: 7,
                          itemBuilder: (_, index) {
                            final y = DateTime.now().year - 3 + index;
                            return _PickerTile(
                              text:       '$y',
                              isSelected: year == y,
                              onTap: () {
                                Navigator.pop(ctx);
                                onChanged(y, month);
                              },
                            );
                          },
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final monthLabel = month == null
        ? 'All Year'
        : DateFormat('MMM').format(DateTime(year, month!));

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color:        cs.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            style: IconButton.styleFrom(
                backgroundColor:
                    cs.surfaceContainerHighest.withValues(alpha: 0.5)),
            icon: const Icon(Icons.chevron_left_rounded, size: 20),
            onPressed: () {
              if (month == null) {
                onChanged(year - 1, null);
              } else {
                final prev = DateTime(year, month! - 1, 1);
                onChanged(prev.year, prev.month);
              }
            },
          ),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _pickDate(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.calendar_month_rounded,
                      size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('$monthLabel $year',
                      style: TextStyle(
                          fontSize:   16,
                          fontWeight: FontWeight.bold,
                          color:      cs.onSurface)),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down_rounded,
                      size:  20,
                      color: Theme.of(context).hintColor),
                ],
              ),
            ),
          ),
          IconButton(
            style: IconButton.styleFrom(
                backgroundColor:
                    cs.surfaceContainerHighest.withValues(alpha: 0.5)),
            icon: const Icon(Icons.chevron_right_rounded, size: 20),
            onPressed: () {
              if (month == null) {
                onChanged(year + 1, null);
              } else {
                final next = DateTime(year, month! + 1, 1);
                onChanged(next.year, next.month);
              }
            },
          ),
        ],
      ),
    );
  }
}

class _PickerTile extends StatelessWidget {
  final String text;
  final bool isSelected;
  final VoidCallback onTap;

  const _PickerTile({
    required this.text,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap:        onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected
              ? cs.primary
              : cs.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          text,
          style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
              color: isSelected ? cs.onPrimary : cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION WRAPPER
// ─────────────────────────────────────────────────────────────────────────────
class _PredSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _PredSection({
    required this.title,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color:        cs.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
              color:      Theme.of(context).shadowColor.withValues(alpha: 0.02),
              blurRadius: 10,
              offset:     const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color:        cs.primaryContainer,
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 18, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────
class _MiniPredCard extends StatelessWidget {
  final String title;
  final double? value;
  final IconData icon;

  const _MiniPredCard({
    required this.title,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.onSurface),
          const SizedBox(height: 8),
          FittedBox(
            fit:       BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              style: TextStyle(
                  color:      cs.onSurfaceVariant,
                  fontSize:   11,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit:       BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value == null ? '-' : 'RM ${value!.toStringAsFixed(2)}',
              style: TextStyle(
                  fontSize:   14,
                  fontWeight: FontWeight.bold,
                  color:      cs.onSurface),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBadge extends StatelessWidget {
  final String message;
  final bool isDark;
  final bool isError;

  const _InfoBadge({
    required this.message,
    required this.isDark,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final t  = Theme.of(context);
    final cs = t.colorScheme;
    final Color bg = isError
        ? cs.errorContainer.withValues(alpha: 0.35)
        : (isDark
            ? Colors.white10
            : Colors.black.withValues(alpha: 0.04));
    final Color fg = isError
        ? cs.onErrorContainer
        : (isDark ? Colors.white : Colors.black87);
    final IconData ico =
        isError ? Icons.error_outline_rounded : Icons.info_outline_rounded;

    return Container(
      padding: const EdgeInsets.all(12),
      margin:  const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color:        bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.dividerColor.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(ico, size: 18, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(
                    color:      fg,
                    fontSize:   12,
                    fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

class _ConfidenceIntervalRow extends StatelessWidget {
  final double lower;
  final double upper;

  const _ConfidenceIntervalRow({required this.lower, required this.upper});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.area_chart_rounded,
              size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Likely between RM ${lower.toStringAsFixed(2)} and RM ${upper.toStringAsFixed(2)}',
              style: TextStyle(
                  fontSize:   12,
                  color:      cs.onSurface,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveMetricRow extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _LiveMetricRow({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
        Text(value,
            style: TextStyle(fontWeight: FontWeight.bold, color: valueColor)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EXPLAINABILITY PANEL
// ─────────────────────────────────────────────────────────────────────────────
class _ExplainabilityPanel extends StatefulWidget {
  final String? explanationText;
  final List<Map<String, dynamic>> featureImportances;
  final Map<String, dynamic>? weekendInfluence;
  final List<Map<String, dynamic>> categoryImpact;

  const _ExplainabilityPanel({
    required this.explanationText,
    required this.featureImportances,
    required this.weekendInfluence,
    required this.categoryImpact,
  });

  @override
  State<_ExplainabilityPanel> createState() => _ExplainabilityPanelState();
}

class _ExplainabilityPanelState extends State<_ExplainabilityPanel> {
  bool _expanded = false;

  static double? _n(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  @override
  Widget build(BuildContext context) {
    final cs     = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? cs.primary.withValues(alpha: 0.08)
            : cs.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap:        () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.lightbulb_outline_rounded,
                      size: 17, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Why this forecast?',
                        style: TextStyle(
                            fontSize:   13,
                            fontWeight: FontWeight.bold,
                            color:      cs.primary)),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size:  20,
                    color: cs.primary.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
          if (widget.explanationText != null &&
              widget.explanationText!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Text(widget.explanationText!,
                  style: TextStyle(
                      fontSize: 12.5,
                      color:    cs.onSurfaceVariant,
                      height:   1.55)),
            ),
          if (_expanded) ...[
            Divider(height: 1, color: cs.primary.withValues(alpha: 0.15)),
            const SizedBox(height: 12),
            if (widget.featureImportances.isNotEmpty) ...[
              const _SubHeader(label: 'What affects your spending most'),
              ...widget.featureImportances.take(5).map((f) {
                final pct =
                    (_n(f['importance_pct']) ?? 0.0).clamp(0.0, 100.0);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 140,
                        child: Text(
                          (f['label'] ?? f['feature'] ?? '').toString(),
                          style: TextStyle(
                              fontSize: 11.5,
                              color:    cs.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value:           pct / 100,
                            minHeight:       7,
                            backgroundColor: cs.surfaceContainerHighest,
                            color:           cs.primary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 38,
                        child: Text('${pct.toStringAsFixed(0)}%',
                            style: TextStyle(
                                fontSize:   11.5,
                                fontWeight: FontWeight.w600,
                                color:      cs.onSurfaceVariant),
                            textAlign: TextAlign.right),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 12),
            ],
            if (widget.weekendInfluence != null &&
                widget.weekendInfluence!.isNotEmpty) ...[
              Divider(
                  height:    1,
                  indent:    14,
                  endIndent: 14,
                  color:     cs.primary.withValues(alpha: 0.12)),
              const SizedBox(height: 12),
              const _SubHeader(label: 'Weekend vs weekday'),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: _WeekendInfluenceRow(data: widget.weekendInfluence!),
              ),
            ],
            if (widget.categoryImpact.isNotEmpty) ...[
              Divider(
                  height:    1,
                  indent:    14,
                  endIndent: 14,
                  color:     cs.primary.withValues(alpha: 0.12)),
              const SizedBox(height: 12),
              const _SubHeader(label: 'Spending by category'),
              ...widget.categoryImpact.map((c) {
                final pct   = (_n(c['share_pct']) ?? 0.0).clamp(0.0, 100.0);
                final total = _n(c['total']) ?? 0.0;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(
                          (c['category'] ?? '').toString(),
                          style: TextStyle(
                              fontSize: 11.5,
                              color:    cs.onSurfaceVariant),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value:           pct / 100,
                            minHeight:       7,
                            backgroundColor: cs.surfaceContainerHighest,
                            color:           cs.tertiary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('RM ${total.toStringAsFixed(0)}',
                          style: TextStyle(
                              fontSize: 11,
                              color:    cs.onSurfaceVariant)),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 36,
                        child: Text('${pct.toStringAsFixed(0)}%',
                            style: TextStyle(
                                fontSize:   11,
                                fontWeight: FontWeight.w600,
                                color:      cs.onSurfaceVariant),
                            textAlign: TextAlign.right),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    );
  }
}

class _SubHeader extends StatelessWidget {
  final String label;
  const _SubHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
      child: Text(label,
          style: TextStyle(
              fontSize:      11,
              fontWeight:    FontWeight.w700,
              letterSpacing: 0.4,
              color:         cs.onSurfaceVariant)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ANOMALY PANEL
// ─────────────────────────────────────────────────────────────────────────────
class _AnomalyPanel extends StatefulWidget {
  final List<Map<String, dynamic>> anomalies;
  const _AnomalyPanel({required this.anomalies});

  @override
  State<_AnomalyPanel> createState() => _AnomalyPanelState();
}

class _AnomalyPanelState extends State<_AnomalyPanel> {
  bool _expanded = false;

  static double? _n(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color:        cs.errorContainer.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.error.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap:        () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 17, color: cs.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.anomalies.length} unusual expense'
                      '${widget.anomalies.length == 1 ? '' : 's'} spotted',
                      style: TextStyle(
                          fontSize:   13,
                          fontWeight: FontWeight.bold,
                          color:      cs.error),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size:  20,
                    color: cs.error.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: cs.error.withValues(alpha: 0.15)),
            const SizedBox(height: 8),
            ...widget.anomalies.map((a) {
              final amount   = _n(a['amount']) ?? 0.0;
              final category = (a['category'] ?? '').toString();
              final dt       = (a['date'] ?? '').toString();
              return Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.circle, size: 7, color: cs.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'RM ${amount.toStringAsFixed(2)}'
                            '${category.isNotEmpty ? ' · $category' : ''}',
                            style: TextStyle(
                                fontSize:   12.5,
                                fontWeight: FontWeight.w600,
                                color:      cs.onSurface),
                          ),
                          Text(
                            '$dt · higher than usual for this category',
                            style: TextStyle(
                                fontSize: 11,
                                color:    cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MONTHLY TREND PANEL
// ─────────────────────────────────────────────────────────────────────────────
class _MonthlyTrendPanel extends StatelessWidget {
  final Map<String, dynamic> trend;
  const _MonthlyTrendPanel({required this.trend});

  static double? _n(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final List<dynamic> monthly =
        (trend['monthly_totals'] is List)
            ? trend['monthly_totals'] as List
            : [];
    final String direction =
        (trend['trend_direction'] ?? 'stable').toString();
    final double pctChange = _n(trend['pct_change']) ?? 0.0;

    Color    dirColor;
    IconData dirIcon;
    String   dirLabel;

    switch (direction) {
      case 'increasing':
        dirColor = cs.error;
        dirIcon  = Icons.trending_up_rounded;
        dirLabel = 'Going up';
        break;
      case 'decreasing':
        dirColor = Colors.green.shade600;
        dirIcon  = Icons.trending_down_rounded;
        dirLabel = 'Going down';
        break;
      default:
        dirColor = cs.onSurfaceVariant;
        dirIcon  = Icons.trending_flat_rounded;
        dirLabel = 'Staying steady';
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(dirIcon, size: 18, color: dirColor),
              const SizedBox(width: 8),
              Text('Your spending is: ',
                  style: TextStyle(
                      fontSize:   13,
                      fontWeight: FontWeight.bold,
                      color:      cs.onSurface)),
              Text(dirLabel,
                  style: TextStyle(
                      fontSize:   13,
                      fontWeight: FontWeight.bold,
                      color:      dirColor)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            direction == 'stable'
                ? 'Your spending has stayed about the same over the last few months.'
                : 'Spending has ${direction == 'increasing' ? 'increased' : 'decreased'} '
                  'by about ${pctChange.abs().toStringAsFixed(0)}% over the last few months.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing:    8,
            runSpacing: 8,
            children: monthly.map((m) {
              final month = (m['month'] ?? '').toString();
              final total = _n(m['total']) ?? 0.0;
              return Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color:        cs.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.3)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(month,
                        style: TextStyle(
                            fontSize: 11,
                            color:    cs.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text('RM ${total.toStringAsFixed(0)}',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color:      cs.onSurface)),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WEEKEND INFLUENCE
// ─────────────────────────────────────────────────────────────────────────────
class _WeekendInfluenceRow extends StatelessWidget {
  final Map<String, dynamic> data;
  const _WeekendInfluenceRow({required this.data});

  double? _n(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final weekdayAvg = _n(data['weekday_avg']) ?? 0.0;
    final weekendAvg = _n(data['weekend_avg']) ?? 0.0;
    final direction  = (data['direction'] ?? 'similar').toString();
    final summary    = (data['summary'] ?? '').toString();

    Color    badgeColor;
    Color    badgeText;
    IconData badgeIcon;

    if (direction == 'higher') {
      badgeColor = cs.errorContainer;
      badgeText  = cs.onErrorContainer;
      badgeIcon  = Icons.arrow_upward_rounded;
    } else if (direction == 'lower') {
      badgeColor = cs.primaryContainer;
      badgeText  = cs.onPrimaryContainer;
      badgeIcon  = Icons.arrow_downward_rounded;
    } else {
      badgeColor = cs.surfaceContainerHighest;
      badgeText  = cs.onSurfaceVariant;
      badgeIcon  = Icons.remove_rounded;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: _WeekendStatChip(
                    label: 'Weekday avg',
                    value: 'RM ${weekdayAvg.toStringAsFixed(2)}')),
            const SizedBox(width: 8),
            Expanded(
                child: _WeekendStatChip(
                    label: 'Weekend avg',
                    value: 'RM ${weekendAvg.toStringAsFixed(2)}')),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
              color:        badgeColor,
              borderRadius: BorderRadius.circular(10)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(badgeIcon, size: 14, color: badgeText),
              const SizedBox(width: 4),
              Text(summary,
                  style: TextStyle(
                      fontSize:   11.5,
                      fontWeight: FontWeight.w600,
                      color:      badgeText)),
            ],
          ),
        ),
      ],
    );
  }
}

class _WeekendStatChip extends StatelessWidget {
  final String label;
  final String value;
  const _WeekendStatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color:        cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10.5, color: cs.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                  fontSize:   13,
                  fontWeight: FontWeight.bold,
                  color:      cs.onSurface)),
        ],
      ),
    );
  }
}