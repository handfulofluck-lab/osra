import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Neutral first frame while the persisted onboarding position and the saved
/// session are read. Showing it prevents a fresh install flashing the login
/// screen, and a resumed wizard flashing the wrong step.
class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined, size: 64),
            const SizedBox(height: 12),
            Text(context.l10n.appName, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 24),
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          ],
        ),
      ),
    );
  }
}
