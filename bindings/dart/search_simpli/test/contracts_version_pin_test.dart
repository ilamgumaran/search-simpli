/// docs/tasks/S1-T2.md criterion 4: `CONTRACTS_VERSION` asserted at open.
/// This test guards the other half of that: that the constant
/// `SearchSimpli.open` asserts against
/// (`lib/src/contracts_version.dart`'s `expectedContractsVersion`) has not
/// drifted from the real `contracts/CONTRACTS_VERSION` file, the same
/// pattern `simpli-helper`'s `llamadart_version_pin_test.dart` uses for its
/// own hand-kept pin (`docs/process/ENVIRONMENT.md`).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

void main() {
  test('expectedContractsVersion matches the real contracts/CONTRACTS_VERSION file', () {
    final repoRoot = p.normalize(p.join(Directory.current.path, '..', '..', '..'));
    final file = File(p.join(repoRoot, 'contracts', 'CONTRACTS_VERSION'));
    final real = file.readAsStringSync().trim();
    expect(
      expectedContractsVersion,
      real,
      reason:
          'lib/src/contracts_version.dart\'s expectedContractsVersion is stale; '
          'update it to match contracts/CONTRACTS_VERSION ($real).',
    );
  });

  test('SearchSimpli.contractsVersion is the same constant', () {
    expect(SearchSimpli.contractsVersion, expectedContractsVersion);
  });
}
