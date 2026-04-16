import 'dart:convert';
import 'package:http/http.dart' as http;
import '../api_config.dart';


class NlpService {
  // ✅ change to your backend URL
  // If testing on Android emulator: http://10.0.2.2:8000/analyze
  // If testing on real phone: use your PC/Laptop IP e.g. http://192.168.1.10:8000/analyze
  final String endpoint = ApiConfig.nlpUrl;
  //final String endpoint = "http://127.0.0.1:8000/analyze";

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