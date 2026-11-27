### Android Child — SafeSearch verification (#1226)

- Android uses the shared web-filter connection refresh when SafeSearch changes. The filter records the normalized search host and decision when it applies a SafeSearch rewrite. The diagnostic omits search text and URLs. The scheduled device row remains open.
