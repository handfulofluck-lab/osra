import ManagedSettings
import FamilyShieldAgent

/// #561: the extension's principal class is declared here, in the extension's own module, as Apple's template does,
/// and named `$(PRODUCT_MODULE_NAME).ShieldActionExtension` in Info.plist. On the iPhone 13 iOS could not load a principal class that
/// lived only in the statically linked package (SpringBoard logged `ExtensionError Code=0`), so the OSRA shield
/// never showed. The behaviour stays in `FamilyShieldShieldActionDelegate` in the package, where the unit tests reach it.
final class ShieldActionExtension: FamilyShieldShieldActionDelegate {}
