### iOS child agent — the extensions' principal classes live in the extensions (#561)
- The iPhone 13 showed iOS's generic "Restricted" screen instead of the OSRA shield: the extension host rejected a
  principal class that lived only in the statically linked package ("does not conform to
  NSExtensionRequestHandling"). Each extension now declares its own class, as Apple's template does
  (`ShieldConfigurationExtension`, `ShieldActionExtension`, `DeviceActivityMonitorExtension`), named
  `$(PRODUCT_MODULE_NAME).<Class>` in its Info.plist. They subclass the package classes, now `open` and without
  `@objc` renames, so the behaviour and its tests stay in the package.
- `check-app-bundle.py` looks up the Swift class symbol in each built extension and checks, from the sources, that
  each Info.plist names an extension-module class declared in that extension's own files.
