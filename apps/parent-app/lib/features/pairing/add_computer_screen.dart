import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import 'computer_target.dart';
import 'pair_qr_screen.dart';

/// ADR-0041 D5.1: the one tap between "Add a computer" and the pairing code. Windows or Mac decides the
/// copy and the download address; the code itself is [PairingQrScreen]'s existing phone flow.
class AddComputerScreen extends StatelessWidget {
  const AddComputerScreen({super.key, required this.childId, this.clock});

  final String childId;

  /// Test seam forwarded to [PairingQrScreen]'s countdown.
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      key: const ValueKey('addComputerScreen'),
      appBar: AppBar(title: Text(l10n.addAComputer)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(l10n.computerSelectPrompt,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpace.xs),
            Text(l10n.computerAdminInstallNote,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: AppSpace.md),
            for (final target in ComputerTarget.values) ...[
              Card(
                child: ListTile(
                  key: ValueKey('addComputer-${target.name}'),
                  leading: Icon(switch (target) {
                    ComputerTarget.windows => Icons.desktop_windows_outlined,
                    ComputerTarget.macos => Icons.laptop_mac,
                  }),
                  title: Text(switch (target) {
                    ComputerTarget.windows => l10n.computerWindows,
                    ComputerTarget.macos => l10n.computerMac,
                  }),
                  subtitle: Text(target.address),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PairingQrScreen(
                        childId: childId,
                        computer: target,
                        clock: clock,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
          ],
        ),
      ),
    );
  }
}
