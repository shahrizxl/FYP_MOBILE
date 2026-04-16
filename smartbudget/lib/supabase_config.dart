import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseConfig {
  static const supabaseUrl = 'https://tiafmkdtljdbxuwqykjr.supabase.co';
  static const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRpYWZta2R0bGpkYnh1d3F5a2pyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE1NjY4NTUsImV4cCI6MjA4NzE0Mjg1NX0.xoOTLXc5tcp3muqOrMDeaVdYAm30V6e3kBk8GsqIPTs';

  static SupabaseClient get client => Supabase.instance.client;
}