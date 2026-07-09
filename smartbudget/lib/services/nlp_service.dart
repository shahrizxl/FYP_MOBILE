import 'dart:convert';
import 'package:http/http.dart' as http;
import '../api_config.dart';


class NlpService {

  final String endpoint = ApiConfig.nlpUrl;

  Future<List<Map<String, dynamic>>> analyze(String text) async {
    final res = await http.post(
      Uri.parse(endpoint),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"text": text}),
    );

    if (res.statusCode != 200) {
      throw Exception("NLP API error: ${res.body}");
    }

    final data = jsonDecode(res.body);
    return List<Map<String, dynamic>>.from(data["results"]);
  }
}