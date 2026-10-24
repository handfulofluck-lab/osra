import FamilyShieldAgent

// This extension's principal class, FamilyShieldShieldActionDelegate (named in Info.plist), is defined in
// the FamilyShieldAgent package, which is linked statically. This reference makes the linker load
// it into the extension's binary; with nothing referring to it, the extension could start with no
// principal class. `public` keeps an optimized build from removing the reference.
public let principalClass: AnyClass = FamilyShieldShieldActionDelegate.self
