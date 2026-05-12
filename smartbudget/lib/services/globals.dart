import 'package:flutter/material.dart';

// A global notifier that broadcasts whenever a transaction is added, edited, or deleted.
final ValueNotifier<int> globalTransactionUpdateNotifier = ValueNotifier(0);