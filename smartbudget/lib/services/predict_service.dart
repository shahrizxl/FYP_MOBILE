import 'dart:convert';
import 'package:http/http.dart' as http;
import '../api_config.dart';

Future<Map<String, dynamic>> predict(
  List<Map<String, dynamic>> txs, {
  required int anchorYear,
  required int anchorMonth,
}) async {
  final res = await http
      .post(
        Uri.parse(ApiConfig.predictUrl),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'transactions': txs,
          'days': 30,
          'anchor_year': anchorYear,
          'anchor_month': anchorMonth,
        }),
      )
      .timeout(const Duration(seconds: 20));


  if (res.statusCode < 200 || res.statusCode >= 300) {
    throw Exception(
      'API error ${res.statusCode}: ${res.body}',
    );
  }

  try {
    return jsonDecode(res.body) as Map<String, dynamic>;
  } catch (e) {
    throw Exception("Invalid JSON response");
  }
}