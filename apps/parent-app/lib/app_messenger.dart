import 'package:flutter/material.dart';

/// The one messenger the app shows snackbars through, so a layer with no `BuildContext` — the mutation gate
/// answering a cancelled prompt — can speak without inventing its own overlay.
final GlobalKey<ScaffoldMessengerState> appMessengerKey = GlobalKey<ScaffoldMessengerState>();
