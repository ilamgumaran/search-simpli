/// The `contracts/CONTRACTS_VERSION` this package was built against.
///
/// Kept in sync by hand (there is no Dart build step that can `@embedFile`
/// a file outside this package's own directory, the same limitation
/// `zig/build.zig`'s `contractsVersionOptions` comment records for Zig) —
/// `test/contracts_version_pin_test.dart` reads the real
/// `../../../contracts/CONTRACTS_VERSION` file and fails if it no longer
/// matches this constant, so a drift is caught by `dart test` rather than
/// silently asserted against a stale value at `SearchSimpli.open`.
const String expectedContractsVersion = '1.0.0';
