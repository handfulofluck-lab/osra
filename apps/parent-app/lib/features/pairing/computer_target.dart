/// ADR-0041 D5.1: the two computer clients the parent can pair from the child page.
///
/// The only thing the parent's choice changes is the copy on [PairingQrScreen] and the download address:
/// the code, the claim and the Allow / Deny flow are the phone flow, unchanged.
enum ComputerTarget {
  windows('windows'),
  macos('macos');

  const ComputerTarget(this.path);

  /// The page path on osratech.com. `/mac`, not `/macos`: that is the address ADR-0041 D4 names, and it is
  /// the one the parent reads aloud or types on the computer.
  final String path;

  /// What the parent sees and sends. No scheme and no trailing slash: it is read and typed by hand.
  String get address => 'osratech.com/$path';
}
