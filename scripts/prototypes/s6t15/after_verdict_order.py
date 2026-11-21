"""The order after_verdict.py runs the Verdict's plants in (S6-T15 rework)."""
ORDER = ["baseline",
         "X-remove-core-row", "X-remove-fastmem-step", "X-copy-paste-ops-row", "X-remove-tests-row",
         "X-change-tests-root", "X-add-test-step",
         "A-nested-unref", "B-generic", "C-fn-named-not-called", "D-method-uncalled", "E-comptime-if-false",
         "F-comptime-not-is-test", "G-pub-const-nontest-fn", "H-path-in-other-module-test", "I-refAllDecls",
         "J-two-modules", "K-usingnamespace", "L-bench-only", "M-field-name", "R-import-in-named-struct",
         "Y-doc-ops"]
