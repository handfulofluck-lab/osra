using FamilyShield.Agent.MacOS.Services;

// Proven scaffolding entry point (#25): starts the placeholder status writer.
// The real worker composition (rule sync, telemetry, filtering) lands with the
// ported services documented in ../README.md.
await PortableStatus.RunAsync();
