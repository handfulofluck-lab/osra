import ManagedSettingsUI
import FamilyShieldAgent

/// #561: the extension's principal class is declared here, in the extension's own module, as Apple's template does,
/// and named `$(PRODUCT_MODULE_NAME).ShieldConfigurationExtension` in Info.plist. The iPhone 13 rejected a principal class that lived only
/// in the statically linked package (`does not conform to NSExtensionRequestHandling`), so the OSRA shield never
/// showed. The behaviour stays in `FamilyShieldConfigurationDataSource` in the package, where the unit tests reach it.
final class ShieldConfigurationExtension: FamilyShieldConfigurationDataSource {}
