# search_simpli_example

A minimal Flutter app that loads `libsearch_simpli.so`/`.dylib` through the
[`search_simpli`](../README.md) package, opens a bundled demo snapshot, and
answers one query — this is the Android instrumentation smoke test for
`docs/tasks/S1-T2.md`'s criterion 3.

```sh
flutter pub get
flutter test integration_test/app_test.dart -d <device-or-emulator-id>
```

See the parent package's [README](../README.md#example-app--android-instrumentation-smoke-test)
for what this app does and why it publishes nothing on-device.
