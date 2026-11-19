/// Compile-time switch gating the Mac pairing option while the Mac agent is not yet ready for
/// families (UI/UX Bureau 6910845231 / 6960604329). Pass `--dart-define=ENABLE_MAC_PAIRING=true`
/// when enabling Mac pairing.
const bool kEnableMacPairing =
    bool.fromEnvironment('ENABLE_MAC_PAIRING', defaultValue: false);

/// ADR-0041 D5.1: the two computer clients the parent can pair from the child page.
///
/// The only thing the parent's choice changes is the copy on [PairingQrScreen] and the download address:
/// the code, the claim and the Allow / Deny flow are the phone flow, unchanged.
enum ComputerTarget {
  windows('windows'),
  macos('mac');

  const ComputerTarget(this.path);

  /// The platform path segment.
  final String path;

  /// What the parent sees and copies. UI/UX Bureau (6910861301): `osratech.com/windows` and `/mac`
  /// answer 404 today while `/download` answers 200, so both platforms point to `osratech.com/download`
  /// until the dedicated pages exist.
  String get address => 'osratech.com/download';
}
