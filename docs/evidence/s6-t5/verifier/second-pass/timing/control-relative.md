# S6-T5 second pass: head against the controls' own medians

**Computed afterwards at the orchestrator's request, for the maintainer; not part of the Verdict.** This is a
rule applied after the measurement, to the five gated runs already taken (`run1..5.jsonl`); no new run, no
build. m_X = five-run median of (X − `main`), X = head, `main2`, `ctl1`, `ctl2`; T = 0.010 ms, or 1 % of
`main`'s five-run median at 5 ms or more. (A) m_head ≥ T (clause (1), as reported); (B) (A) and m_head >
max(m_main2, m_ctl1, m_ctl2); (C) (A) and m_head > that max + T. Script: `control_relative.py`.

| Field | Cells | (A) | (B) | (C) | m_main2 ≥ T | m_ctl1 ≥ T | m_ctl2 ≥ T |
|---|---:|---:|---:|---:|---:|---:|---:|
| `content` | 45 | 0 | 0 | 0 | 0 | 0 | 0 |
| `find` | 28 | 2 | 2 | 1 | 2 | 1 | 0 |
| `filename` | 45 | 8 | 8 | 0 | 0 | 9 | 7 |
| `both` | 45 | 13 | 2 | 0 | 0 | 27 | 9 |
| all | 163 | 23 | 12 | 1 | 2 | 37 | 16 |

Every cell in (B), µs (medians of differences against `main`):

| Corpus | Cell | `main` median | T | m_head | m_main2 | m_ctl1 | m_ctl2 | m_head − max(controls) | (C) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| timing-10k | `both badamo` | 102.2 | 10.0 | +10.25 | -0.42 | +9.04 | +4.08 | +1.21 | no |
| timing-10k | `both belohu` | 102.2 | 10.0 | +10.50 | -0.13 | +8.54 | +4.50 | +1.96 | no |
| timing-10k | `find words from` | 3024.7 | 10.0 | +12.67 | +11.04 | -12.71 | -15.63 | +1.63 | no |
| prose-10k | `filename system` | 273.3 | 10.0 | +24.79 | -0.96 | +19.54 | +12.71 | +5.25 | no |
| prose-10k | `filename system systems` | 278.4 | 10.0 | +26.42 | -0.29 | +19.08 | +11.46 | +7.33 | no |
| prose-10k | `filename systems system` | 278.5 | 10.0 | +27.58 | -0.67 | +18.50 | +13.08 | +9.08 | no |
| prose-10k | `filename within` | 307.3 | 10.0 | +26.13 | +0.37 | +23.33 | +16.29 | +2.79 | no |
| prose-10k | `filename drink` | 195.0 | 10.0 | +19.79 | +0.04 | +12.87 | +8.46 | +6.92 | no |
| prose-10k | `filename the within` | 309.0 | 10.0 | +28.75 | -1.04 | +22.75 | +12.29 | +6.00 | no |
| prose-10k | `filename have drink` | 197.0 | 10.0 | +20.54 | -0.58 | +12.58 | +10.96 | +7.96 | no |
| prose-10k | `filename across lengthy seeming 04276` | 333.1 | 10.0 | +30.04 | -0.67 | +25.50 | +19.04 | +4.54 | no |
| tamil-10k | `find prefix டூகன*` | 3010.4 | 10.0 | +14.75 | -13.67 | -3.63 | -26.92 | +18.37 | yes |

Cells where a control or `main2` reaches T (the controls' own clause-(1) "failures"), µs:

| Corpus | Cell | `main` median | T | m_head | m_main2 | m_ctl1 | m_ctl2 |
|---|---|---:|---:|---:|---:|---:|---:|
| timing-10k | `filename doc 00000` | 241.0 | 10.0 | +8.42 | -1.87 | +13.00 | +1.71 |
| timing-10k | `both system` | 214.6 | 10.0 | +3.50 | -0.58 | +25.50 | +1.71 |
| timing-10k | `both hashing` | 190.3 | 10.0 | +4.87 | -0.42 | +22.21 | +1.75 |
| timing-10k | `both hybrid retrieval` | 154.5 | 10.0 | +5.75 | -0.13 | +19.54 | +2.17 |
| timing-10k | `both retrieval hybrid` | 154.4 | 10.0 | +5.92 | -0.25 | +19.71 | +2.75 |
| timing-10k | `both system systems` | 252.0 | 10.0 | +1.25 | -1.29 | +23.25 | -0.04 |
| timing-10k | `both systems system` | 251.0 | 10.0 | +1.71 | -0.71 | +24.63 | +0.54 |
| timing-10k | `both from` | 304.8 | 10.0 | +6.38 | -0.46 | +28.83 | +1.79 |
| timing-10k | `both were` | 306.3 | 10.0 | +5.83 | +0.46 | +32.04 | +2.75 |
| timing-10k | `both from badamo` | 312.1 | 10.0 | +7.25 | -0.96 | +31.75 | +2.75 |
| timing-10k | `both were belohu` | 320.3 | 10.0 | +7.08 | -1.00 | +33.21 | +3.08 |
| timing-10k | `both doc 00000` | 336.1 | 10.0 | +6.13 | -1.12 | +11.21 | -1.21 |
| timing-10k | `find words from` | 3024.7 | 10.0 | +12.67 | +11.04 | -12.71 | -15.63 |
| prose-10k | `filename system` | 273.3 | 10.0 | +24.79 | -0.96 | +19.54 | +12.71 |
| prose-10k | `filename system systems` | 278.4 | 10.0 | +26.42 | -0.29 | +19.08 | +11.46 |
| prose-10k | `filename systems system` | 278.5 | 10.0 | +27.58 | -0.67 | +18.50 | +13.08 |
| prose-10k | `filename within` | 307.3 | 10.0 | +26.13 | +0.37 | +23.33 | +16.29 |
| prose-10k | `filename drink` | 195.0 | 10.0 | +19.79 | +0.04 | +12.87 | +8.46 |
| prose-10k | `filename the within` | 309.0 | 10.0 | +28.75 | -1.04 | +22.75 | +12.29 |
| prose-10k | `filename have drink` | 197.0 | 10.0 | +20.54 | -0.58 | +12.58 | +10.96 |
| prose-10k | `filename across lengthy seeming 04276` | 333.1 | 10.0 | +30.04 | -0.67 | +25.50 | +19.04 |
| prose-10k | `both system` | 347.7 | 10.0 | +21.04 | +1.17 | +36.46 | +11.75 |
| prose-10k | `both hashing` | 175.0 | 10.0 | +14.25 | +0.46 | +15.83 | +7.83 |
| prose-10k | `both system systems` | 366.0 | 10.0 | +19.92 | +1.62 | +36.38 | +12.67 |
| prose-10k | `both systems system` | 367.4 | 10.0 | +20.29 | +1.54 | +36.21 | +13.17 |
| prose-10k | `both the` | 500.5 | 10.0 | +14.50 | +1.25 | +45.42 | +12.54 |
| prose-10k | `both have` | 337.5 | 10.0 | +11.12 | +1.46 | +35.42 | +7.42 |
| prose-10k | `both within` | 433.9 | 10.0 | +28.92 | +0.96 | +49.71 | +16.38 |
| prose-10k | `both drink` | 357.4 | 10.0 | +27.13 | +0.25 | +36.21 | +15.17 |
| prose-10k | `both the within` | 646.0 | 10.0 | +24.00 | +4.04 | +59.62 | +19.21 |
| prose-10k | `both have drink` | 557.5 | 10.0 | +24.12 | +2.25 | +53.83 | +19.42 |
| prose-10k | `both across lengthy seeming 04276` | 530.5 | 10.0 | +27.92 | +0.88 | +53.00 | +22.42 |
| prose-10k | `find phrase bottle and orchard` | 110.9 | 10.0 | -10.33 | +11.67 | +20.87 | +9.13 |
| tamil-10k | `both கீகசை` | 733.0 | 10.0 | -12.54 | -1.92 | +28.25 | -7.25 |
| tamil-10k | `both டூகனை` | 730.7 | 10.0 | -10.25 | -1.42 | +24.21 | -2.29 |
| tamil-10k | `both கீகசை றூகுஞங்கள்` | 683.8 | 10.0 | -12.67 | +0.04 | +25.37 | -5.50 |
| tamil-10k | `both டூகனை சைகீளையில்` | 688.5 | 10.0 | -12.58 | -0.21 | +23.79 | -9.29 |
| tamil-10k | `both doc 00000` | 780.7 | 10.0 | +3.71 | +0.37 | +10.33 | -4.92 |

## The maintainer's rule of 17 Nov 2026, applied to the same five runs

Chosen after seeing this data (recorded as such in `docs/tasks/S6-T5.md`). T17 = the larger of 0.010 ms and 1 %
of `main`'s five-run median for the cell. A cell fails only if m_head >= T17 AND m_head - max(m_main2, m_ctl1,
m_ctl2) >= T17. Every request, changed path or not.

| Field | Cells | m_head >= T17 | m_head - max(controls) >= T17 | both: fails | largest m_head - max(controls), µs (its T17) |
|---|---:|---:|---:|---:|---|
| `content` | 45 | 0 | 0 | 0 | +0.42 (10.0; prose-10k `content hybrid retrieval`) |
| `find` | 28 | 0 | 0 | 0 | +18.37 (30.1; tamil-10k `find prefix டூகன*`) |
| `filename` | 45 | 8 | 0 | 0 | +9.08 (10.0; prose-10k `filename systems system`) |
| `both` | 45 | 13 | 0 | 0 | +2.46 (10.0; timing-10k `both bazecha`) |
| all | 163 | 21 | 0 | 0 | +18.37 (30.1; tamil-10k `find prefix டூகன*`) |

Cells meeting either half, µs:

| Corpus | Cell | `main` median | T17 | m_head | max(controls) | m_head - max(controls) | fails |
|---|---|---:|---:|---:|---:|---:|---|
| timing-10k | `both badamo` | 102.2 | 10.0 | +10.25 | +9.04 | +1.21 | no |
| timing-10k | `both belohu` | 102.2 | 10.0 | +10.50 | +8.54 | +1.96 | no |
| prose-10k | `filename system` | 273.3 | 10.0 | +24.79 | +19.54 | +5.25 | no |
| prose-10k | `filename system systems` | 278.4 | 10.0 | +26.42 | +19.08 | +7.33 | no |
| prose-10k | `filename systems system` | 278.5 | 10.0 | +27.58 | +18.50 | +9.08 | no |
| prose-10k | `filename within` | 307.3 | 10.0 | +26.13 | +23.33 | +2.79 | no |
| prose-10k | `filename drink` | 195.0 | 10.0 | +19.79 | +12.87 | +6.92 | no |
| prose-10k | `filename the within` | 309.0 | 10.0 | +28.75 | +22.75 | +6.00 | no |
| prose-10k | `filename have drink` | 197.0 | 10.0 | +20.54 | +12.58 | +7.96 | no |
| prose-10k | `filename across lengthy seeming 04276` | 333.1 | 10.0 | +30.04 | +25.50 | +4.54 | no |
| prose-10k | `both system` | 347.7 | 10.0 | +21.04 | +36.46 | -15.42 | no |
| prose-10k | `both hashing` | 175.0 | 10.0 | +14.25 | +15.83 | -1.58 | no |
| prose-10k | `both system systems` | 366.0 | 10.0 | +19.92 | +36.38 | -16.46 | no |
| prose-10k | `both systems system` | 367.4 | 10.0 | +20.29 | +36.21 | -15.92 | no |
| prose-10k | `both the` | 500.5 | 10.0 | +14.50 | +45.42 | -30.92 | no |
| prose-10k | `both have` | 337.5 | 10.0 | +11.12 | +35.42 | -24.29 | no |
| prose-10k | `both within` | 433.9 | 10.0 | +28.92 | +49.71 | -20.79 | no |
| prose-10k | `both drink` | 357.4 | 10.0 | +27.13 | +36.21 | -9.08 | no |
| prose-10k | `both the within` | 646.0 | 10.0 | +24.00 | +59.62 | -35.63 | no |
| prose-10k | `both have drink` | 557.5 | 10.0 | +24.12 | +53.83 | -29.71 | no |
| prose-10k | `both across lengthy seeming 04276` | 530.5 | 10.0 | +27.92 | +53.00 | -25.08 | no |

**Failing cells under the rule of 17 Nov: 0 of 163.**
