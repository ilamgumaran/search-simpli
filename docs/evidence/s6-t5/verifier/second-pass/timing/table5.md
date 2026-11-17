| Field | Cells | five-run median d, µs (min .. max) | clause (1) | clause (2) | both clauses pass | within the prediction (of those failing) |
|---|---:|---|---:|---:|---:|---|
| `content` | 45 | -7.38 .. +4.21 | 0 | 2 | 43 | — (code path unchanged: clause (1) decides) |
| `find` | 28 | -17.71 .. +77.29 | 2 | 4 | 23 | — (code path unchanged: clause (1) decides) |
| `filename` | 45 | +0.21 .. +30.04 | 8 | 43 | 2 | 35 of 43 |
| `both` | 45 | -12.67 .. +28.92 | 13 | 14 | 20 | 10 of 25 |

Unchanged code paths (`content`, `find`): every cell beyond clause (1) or (2)

| Corpus | Cell | `main` median, µs | head − `main`, µs | `main2` | `ctl1` | `ctl2` | runs above band | decides |
|---|---|---:|---:|---:|---:|---:|---:|---|
| timing-10k | `find words from` | 3024.7 | +12.67 | +11.00 | -12.70 | -15.60 | 2 | **fails clause (1)** |
| timing-10k | `find prefix bada*` | 802.5 | +2.00 | +0.80 | -3.70 | -6.40 | 3 | clause (2) only: reported, does not fail |
| timing-10k | `find prefix belo*` | 800.3 | +5.75 | -0.00 | -4.50 | -2.50 | 4 | clause (2) only: reported, does not fail |
| prose-10k | `content bazecha` | 10.0 | +0.13 | -0.10 | -0.00 | -0.10 | 3 | clause (2) only: reported, does not fail |
| prose-10k | `content hybrid retrieval` | 16.8 | +0.08 | -0.50 | -0.40 | -0.30 | 3 | clause (2) only: reported, does not fail |
| tamil-10k | `find words கீகசை` | 2996.5 | +4.67 | -2.10 | -10.40 | -24.20 | 4 | clause (2) only: reported, does not fail |
| tamil-10k | `find prefix டூகன*` | 3010.4 | +14.75 | -13.70 | -3.60 | -26.90 | 3 | **fails clause (1)** |

Changed code paths (`both`, `filename`): every cell failing a clause

| Corpus | Cell | `main` median, µs | head − `main`, µs | `main2` | `ctl1` | `ctl2` | runs above band | clauses failed | warnings | prediction top, µs | within |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---|
| timing-10k | `filename bazecha` | 2.6 | +0.33 | +0.00 | +0.00 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| timing-10k | `filename benico` | 2.5 | +0.29 | -0.00 | +0.00 | +0.10 | 5 | (2) | 1 | 0.8 | yes |
| timing-10k | `filename system` | 2.5 | +0.33 | +0.00 | +0.10 | +0.10 | 5 | (2) | 1 | 0.8 | yes |
| timing-10k | `filename hashing` | 2.6 | +0.37 | +0.00 | +0.10 | +0.10 | 5 | (2) | 1 | 0.8 | yes |
| timing-10k | `filename hybrid retrieval` | 3.0 | +0.50 | -0.00 | +0.00 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| timing-10k | `filename retrieval hybrid` | 3.0 | +0.58 | +0.00 | +0.10 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| timing-10k | `filename system systems` | 3.0 | +0.50 | +0.00 | +0.00 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| timing-10k | `filename systems system` | 3.0 | +0.54 | +0.00 | +0.00 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| timing-10k | `filename from` | 2.5 | +0.29 | +0.00 | +0.00 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| timing-10k | `filename were` | 2.5 | +0.25 | +0.00 | +0.00 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| timing-10k | `filename badamo` | 2.5 | +0.29 | -0.00 | +0.00 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| timing-10k | `filename belohu` | 2.5 | +0.29 | -0.00 | +0.00 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| timing-10k | `filename from badamo` | 2.9 | +0.50 | +0.00 | +0.00 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| timing-10k | `filename were belohu` | 2.9 | +0.50 | +0.00 | +0.00 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| timing-10k | `both bazecha` | 105.5 | +9.71 | -0.50 | +7.20 | +3.40 | 5 | (2) | 0 | 1.0 | **no** |
| timing-10k | `both benico` | 98.3 | +9.92 | +0.10 | +8.40 | +4.00 | 5 | (2) | 0 | 1.0 | **no** |
| timing-10k | `both badamo` | 102.2 | +10.25 | -0.40 | +9.00 | +4.10 | 5 | (1)(2) | 0 | 1.0 | **no** |
| timing-10k | `both belohu` | 102.2 | +10.50 | -0.10 | +8.50 | +4.50 | 5 | (1)(2) | 0 | 1.0 | **no** |
| prose-10k | `filename bazecha` | 2.6 | +0.33 | +0.00 | +0.10 | +0.10 | 5 | (2) | 1 | 0.8 | yes |
| prose-10k | `filename benico` | 2.6 | +0.33 | -0.00 | +0.10 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| prose-10k | `filename system` | 273.3 | +24.79 | -1.00 | +19.50 | +12.70 | 5 | (1)(2) | 0 | 0.6 | **no** |
| prose-10k | `filename hashing` | 2.6 | +0.33 | -0.00 | +0.10 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| prose-10k | `filename hybrid retrieval` | 3.0 | +0.54 | +0.00 | +0.10 | +0.10 | 5 | (2) | 2 | 1.0 | yes |
| prose-10k | `filename retrieval hybrid` | 3.1 | +0.54 | -0.00 | +0.10 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| prose-10k | `filename system systems` | 278.4 | +26.42 | -0.30 | +19.10 | +11.50 | 5 | (1)(2) | 0 | 0.6 | **no** |
| prose-10k | `filename systems system` | 278.5 | +27.58 | -0.70 | +18.50 | +13.10 | 5 | (1)(2) | 0 | 0.6 | **no** |
| prose-10k | `filename the` | 2.5 | +0.25 | -0.00 | +0.00 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| prose-10k | `filename have` | 2.6 | +0.25 | -0.00 | +0.00 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| prose-10k | `filename within` | 307.3 | +26.13 | +0.40 | +23.30 | +16.30 | 4 | (1)(2) | 0 | 0.6 | **no** |
| prose-10k | `filename drink` | 195.0 | +19.79 | +0.00 | +12.90 | +8.50 | 5 | (1)(2) | 0 | 0.6 | **no** |
| prose-10k | `filename the within` | 309.0 | +28.75 | -1.00 | +22.80 | +12.30 | 5 | (1)(2) | 1 | 0.8 | **no** |
| prose-10k | `filename have drink` | 197.0 | +20.54 | -0.60 | +12.60 | +11.00 | 5 | (1)(2) | 1 | 0.8 | **no** |
| prose-10k | `filename across lengthy seeming 04276` | 333.1 | +30.04 | -0.70 | +25.50 | +19.00 | 5 | (1)(2) | 0 | 0.6 | **no** |
| prose-10k | `both bazecha` | 12.4 | +0.21 | +0.00 | -0.30 | +0.10 | 3 | (2) | 1 | 1.2 | yes |
| prose-10k | `both system` | 347.7 | +21.04 | +1.20 | +36.50 | +11.80 | 0 | (1) | 1 | 1.2 | **no** |
| prose-10k | `both hashing` | 175.0 | +14.25 | +0.50 | +15.80 | +7.80 | 0 | (1) | 2 | 1.4 | **no** |
| prose-10k | `both hybrid retrieval` | 19.7 | +0.67 | -0.60 | -0.70 | -0.80 | 3 | (2) | 2 | 1.4 | yes |
| prose-10k | `both retrieval hybrid` | 18.7 | +0.96 | +0.80 | +0.20 | +0.30 | 3 | (2) | 2 | 1.4 | yes |
| prose-10k | `both system systems` | 366.0 | +19.92 | +1.60 | +36.40 | +12.70 | 0 | (1) | 2 | 1.4 | **no** |
| prose-10k | `both systems system` | 367.4 | +20.29 | +1.50 | +36.20 | +13.20 | 0 | (1) | 2 | 1.4 | **no** |
| prose-10k | `both the` | 500.5 | +14.50 | +1.30 | +45.40 | +12.50 | 0 | (1) | 0 | 1.0 | **no** |
| prose-10k | `both have` | 337.5 | +11.12 | +1.50 | +35.40 | +7.40 | 0 | (1) | 0 | 1.0 | **no** |
| prose-10k | `both within` | 433.9 | +28.92 | +1.00 | +49.70 | +16.40 | 0 | (1) | 0 | 1.0 | **no** |
| prose-10k | `both drink` | 357.4 | +27.13 | +0.20 | +36.20 | +15.20 | 0 | (1) | 1 | 1.2 | **no** |
| prose-10k | `both the within` | 646.0 | +24.00 | +4.00 | +59.60 | +19.20 | 0 | (1) | 0 | 1.0 | **no** |
| prose-10k | `both have drink` | 557.5 | +24.12 | +2.20 | +53.80 | +19.40 | 0 | (1) | 1 | 1.2 | **no** |
| prose-10k | `both across lengthy seeming 04276` | 530.5 | +27.92 | +0.90 | +53.00 | +22.40 | 0 | (1) | 1 | 1.2 | **no** |
| tamil-10k | `filename bazecha` | 2.6 | +0.29 | +0.00 | +0.00 | +0.00 | 4 | (2) | 1 | 0.8 | yes |
| tamil-10k | `filename benico` | 2.6 | +0.29 | +0.00 | +0.00 | +0.00 | 4 | (2) | 1 | 0.8 | yes |
| tamil-10k | `filename system` | 2.6 | +0.29 | +0.00 | +0.00 | +0.00 | 4 | (2) | 1 | 0.8 | yes |
| tamil-10k | `filename hashing` | 2.6 | +0.29 | +0.00 | +0.10 | +0.00 | 4 | (2) | 1 | 0.8 | yes |
| tamil-10k | `filename hybrid retrieval` | 3.0 | +0.54 | +0.00 | +0.10 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| tamil-10k | `filename retrieval hybrid` | 3.0 | +0.58 | +0.00 | +0.10 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| tamil-10k | `filename system systems` | 3.0 | +0.50 | +0.00 | +0.10 | +0.00 | 5 | (2) | 2 | 1.0 | yes |
| tamil-10k | `filename systems system` | 3.0 | +0.54 | +0.00 | +0.10 | +0.10 | 5 | (2) | 2 | 1.0 | yes |
| tamil-10k | `filename கீகசை` | 3.0 | +0.21 | +0.00 | +0.00 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| tamil-10k | `filename டூகனை` | 2.9 | +0.25 | +0.00 | +0.00 | -0.00 | 5 | (2) | 1 | 0.8 | yes |
| tamil-10k | `filename றூகுஞங்கள்` | 4.6 | +0.21 | +0.00 | +0.00 | -0.00 | 4 | (2) | 1 | 0.8 | yes |
| tamil-10k | `filename சைகீளையில்` | 4.9 | +0.25 | +0.00 | +0.00 | +0.00 | 5 | (2) | 1 | 0.8 | yes |
| tamil-10k | `filename கீகசை றூகுஞங்கள்` | 6.2 | +0.33 | +0.00 | -0.00 | -0.10 | 5 | (2) | 2 | 1.0 | yes |
| tamil-10k | `filename டூகனை சைகீளையில்` | 6.4 | +0.46 | +0.00 | +0.00 | -0.00 | 5 | (2) | 2 | 1.0 | yes |
| tamil-10k | `both bazecha` | 5.7 | +0.29 | +0.10 | -0.10 | +0.00 | 3 | (2) | 1 | 1.2 | yes |
| tamil-10k | `both benico` | 5.5 | +0.21 | +0.00 | -0.10 | +0.00 | 4 | (2) | 1 | 1.2 | yes |
| tamil-10k | `both system` | 5.5 | +0.25 | +0.00 | -0.00 | +0.10 | 5 | (2) | 1 | 1.2 | yes |
| tamil-10k | `both hybrid retrieval` | 7.5 | +0.33 | +0.10 | -0.10 | +0.20 | 5 | (2) | 2 | 1.4 | yes |
| tamil-10k | `both retrieval hybrid` | 7.6 | +0.33 | -0.00 | -0.20 | +0.20 | 5 | (2) | 2 | 1.4 | yes |
| tamil-10k | `both system systems` | 8.1 | +0.42 | +0.00 | -0.10 | +0.20 | 5 | (2) | 2 | 1.4 | yes |
| tamil-10k | `both systems system` | 8.2 | +0.42 | +0.00 | -0.00 | +0.20 | 5 | (2) | 2 | 1.4 | yes |
