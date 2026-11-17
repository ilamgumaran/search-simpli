
**Open, interleaved in one process, phase o (fixed before run 1): main/main2/ctl share one index copy** (12 cells)

| Corpus | Cell | main (median of 5) | head − main (median) | main2 / ctl1 / ctl2 − main | T | Rule | Band | head-v4 − main |
|---|---|---|---|---|---|---|---|---|
| j2 | open interleaved (p50 of 200) | 0.1518 | -0.0021 (-1.39 %) | +0.0004 / +0.0079 / +0.0082 | 0.0100 | pass | 0/5 | -0.0028 |
| j2 | open interleaved CPU (p50 of 200) | 0.1516 | -0.0021 (-1.40 %) | +0.0004 / +0.0079 / +0.0082 | 0.0100 | pass | 0/5 | -0.0028 |
| family | open interleaved (p50 of 200) | 1.075 | -0.0020 (-0.18 %) | +0.0015 / +0.0086 / +0.0115 | 0.0107 | pass | 0/5 | +0.0033 |
| family | open interleaved CPU (p50 of 200) | 1.075 | -0.0020 (-0.18 %) | +0.0014 / +0.0082 / +0.0118 | 0.0107 | pass | 1/5 | +0.0033 |
| fixtures | open interleaved (p50 of 200) | 2.946 | +0.0486 (+1.65 %) | -0.0018 / +0.0197 / +0.0352 | 0.0295 | at T, within controls | 3/5 | +0.0118 |
| fixtures | open interleaved CPU (p50 of 200) | 2.945 | +0.0480 (+1.63 %) | -0.0023 / +0.0202 / +0.0328 | 0.0294 | at T, within controls | 3/5 | +0.0142 |
| timing-10k | open interleaved (p50 of 200) | 5.461 | +0.0972 (+1.78 %) | +0.0236 / -0.0070 / +0.0208 | 0.0546 | **FAIL** | 5/5 | +0.0204 |
| timing-10k | open interleaved CPU (p50 of 200) | 5.458 | +0.0942 (+1.73 %) | +0.0208 / -0.0053 / +0.0192 | 0.0546 | **FAIL** | 5/5 | +0.0210 |
| prose-10k | open interleaved (p50 of 200) | 11.909 | +0.2157 (+1.81 %) | -0.0235 / -0.0042 / -0.0344 | 0.1191 | **FAIL** | 5/5 | +0.0120 |
| prose-10k | open interleaved CPU (p50 of 200) | 11.899 | +0.2145 (+1.80 %) | -0.0239 / -0.0038 / -0.0341 | 0.1190 | **FAIL** | 5/5 | +0.0101 |
| tamil-10k | open interleaved (p50 of 200) | 7.871 | +0.2319 (+2.95 %) | -0.0035 / -0.0077 / +0.0138 | 0.0787 | **FAIL** | 5/5 | +0.0289 |
| tamil-10k | open interleaved CPU (p50 of 200) | 7.864 | +0.2336 (+2.97 %) | -0.0032 / -0.0105 / +0.0139 | 0.0786 | **FAIL** | 5/5 | +0.0266 |

**Open, interleaved, phase o2 (added after the five runs, before its own): each pair its own index copy** (12 cells)

| Corpus | Cell | main (median of 5) | head − main (median) | main2 / ctl1 / ctl2 − main | T | Rule | Band | head-v4 − main |
|---|---|---|---|---|---|---|---|---|
| j2 | open interleaved, own copies (p50 of 200) | 0.1684 | -0.0003 (-0.20 %) | +0.0003 / +0.0102 / +0.0118 | 0.0100 | pass | 0/5 | -0.0005 |
| j2 | open interleaved, own copies, CPU (p50 of 200) | 0.1682 | -0.0003 (-0.19 %) | +0.0003 / +0.0101 / +0.0118 | 0.0100 | pass | 0/5 | -0.0005 |
| family | open interleaved, own copies (p50 of 200) | 1.118 | -0.0080 (-0.72 %) | +0.0054 / +0.0027 / +0.0046 | 0.0112 | pass | 0/5 | -0.0035 |
| family | open interleaved, own copies, CPU (p50 of 200) | 1.117 | -0.0084 (-0.75 %) | +0.0054 / +0.0050 / +0.0051 | 0.0112 | pass | 0/5 | -0.0030 |
| fixtures | open interleaved, own copies (p50 of 200) | 3.093 | -0.0366 (-1.18 %) | +0.0212 / +0.0063 / +0.0258 | 0.0309 | pass | 0/5 | +0.0145 |
| fixtures | open interleaved, own copies, CPU (p50 of 200) | 3.091 | -0.0394 (-1.28 %) | +0.0212 / +0.0061 / +0.0242 | 0.0309 | pass | 0/5 | +0.0178 |
| timing-10k | open interleaved, own copies (p50 of 200) | 5.607 | -0.0260 (-0.46 %) | -0.0039 / +0.0443 / +0.0043 | 0.0561 | pass | 0/5 | +0.0135 |
| timing-10k | open interleaved, own copies, CPU (p50 of 200) | 5.604 | -0.0256 (-0.46 %) | -0.0045 / +0.0408 / +0.0029 | 0.0560 | pass | 0/5 | +0.0101 |
| prose-10k | open interleaved, own copies (p50 of 200) | 12.140 | +0.0170 (+0.14 %) | -0.0109 / +0.0133 / -0.0214 | 0.1214 | pass | 3/5 | +0.0159 |
| prose-10k | open interleaved, own copies, CPU (p50 of 200) | 12.130 | +0.0170 (+0.14 %) | -0.0096 / +0.0138 / -0.0220 | 0.1213 | pass | 3/5 | +0.0160 |
| tamil-10k | open interleaved, own copies (p50 of 200) | 8.092 | +0.0119 (+0.15 %) | +0.0156 / -0.0031 / -0.0300 | 0.0809 | pass | 1/5 | +0.0507 |
| tamil-10k | open interleaved, own copies, CPU (p50 of 200) | 8.082 | +0.0130 (+0.16 %) | +0.0125 / -0.0083 / -0.0320 | 0.0808 | pass | 2/5 | +0.0534 |

**Open, separate processes (bench.py p50 of 30; rbench p50 of 60)** (15 cells)

| Corpus | Cell | main (median of 5) | head − main (median) | main2 / ctl1 / ctl2 − main | T | Rule | Band |
|---|---|---|---|---|---|---|---|
| j2 | open (rbench, p50 of 60) | 0.1538 | -0.0031 (-2.00 %) | -0.0007 / +0.0013 / -0.0020 | 0.0100 | pass | 1/5 |
| j2 | open CPU (rbench, p50 of 60) | 0.1537 | -0.0030 (-1.98 %) | -0.0007 / +0.0013 / -0.0019 | 0.0100 | pass | 1/5 |
| family | open (rbench, p50 of 60) | 1.067 | -0.0009 (-0.09 %) | +0.0065 / -0.0014 / +0.0052 | 0.0107 | pass | 2/5 |
| family | open CPU (rbench, p50 of 60) | 1.066 | -0.0018 (-0.16 %) | +0.0065 / -0.0013 / +0.0037 | 0.0107 | pass | 2/5 |
| fixtures | open (rbench, p50 of 60) | 2.895 | -0.0166 (-0.57 %) | -0.0080 / -0.0068 / +0.0100 | 0.0290 | pass | 1/5 |
| fixtures | open CPU (rbench, p50 of 60) | 2.893 | -0.0140 (-0.49 %) | -0.0092 / -0.0070 / +0.0079 | 0.0289 | pass | 1/5 |
| timing-10k | open (bench.py, p50 of 30) | 5.418 | -0.0333 (-0.62 %) | +0.0180 / -0.0327 / -0.0502 | 0.0542 | pass | 0/5 |
| timing-10k | open (rbench, p50 of 60) | 5.383 | +0.0157 (+0.29 %) | +0.0082 / -0.0107 / +0.0149 | 0.0538 | pass | 2/5 |
| timing-10k | open CPU (rbench, p50 of 60) | 5.378 | +0.0152 (+0.28 %) | +0.0087 / -0.0101 / +0.0147 | 0.0538 | pass | 2/5 |
| prose-10k | open (bench.py, p50 of 30) | 11.797 | +0.0306 (+0.26 %) | +0.0011 / +0.0160 / +0.0480 | 0.1180 | pass | 2/5 |
| prose-10k | open (rbench, p50 of 60) | 11.739 | +0.0300 (+0.26 %) | -0.0138 / +0.0019 / -0.0330 | 0.1174 | pass | 3/5 |
| prose-10k | open CPU (rbench, p50 of 60) | 11.726 | +0.0317 (+0.27 %) | -0.0140 / +0.0014 / -0.0335 | 0.1173 | pass | 3/5 |
| tamil-10k | open (bench.py, p50 of 30) | 7.803 | -0.0049 (-0.06 %) | -0.0172 / +0.0271 / -0.0137 | 0.0780 | pass | 0/5 |
| tamil-10k | open (rbench, p50 of 60) | 7.773 | -0.0182 (-0.23 %) | -0.0083 / +0.0118 / +0.0070 | 0.0777 | pass | 0/5 |
| tamil-10k | open CPU (rbench, p50 of 60) | 7.764 | -0.0212 (-0.27 %) | -0.0105 / +0.0121 / +0.0062 | 0.0776 | pass | 0/5 |

**Memory after open (bytes, phys_footprint delta / after open)** (9 cells)

| Corpus | Cell | main (median of 5) | head − main (median) | main2 / ctl1 / ctl2 − main | T | Rule | Band |
|---|---|---|---|---|---|---|---|
| j2 | memory after open (rbench) | 376,832 | -16,384 (-4.35 %) | +16,384 / +0 / +0 | – | – | 0/5 |
| family | memory after open (rbench) | 5,128,192 | -65,536 (-1.28 %) | +0 / +0 / +0 | – | – | 0/5 |
| fixtures | memory after open (rbench) | 15,237,120 | -196,608 (-1.29 %) | +0 / +0 / +0 | – | – | 0/5 |
| timing-10k | memory after open (bench.py) | 26,345,496 | -655,384 (-2.49 %) | +0 / +0 / +0 | – | – | 0/5 |
| timing-10k | memory after open (rbench) | 26,542,104 | -655,384 (-2.47 %) | +0 / +0 / +0 | – | – | 0/5 |
| prose-10k | memory after open (bench.py) | 53,723,160 | -655,360 (-1.22 %) | +0 / +0 / +0 | – | – | 0/5 |
| prose-10k | memory after open (rbench) | 53,723,160 | -458,752 (-0.85 %) | +0 / +0 / +32,768 | – | – | 0/5 |
| tamil-10k | memory after open (bench.py) | 47,546,392 | -622,592 (-1.31 %) | +0 / +0 / +0 | – | – | 0/5 |
| tamil-10k | memory after open (rbench) | 47,743,000 | -622,592 (-1.30 %) | +0 / +0 / +0 | – | – | 0/5 |

**First call on a fresh handle** (18 cells)

| Corpus | Cell | main (median of 5) | head − main (median) | main2 / ctl1 / ctl2 − main | T | Rule | Band |
|---|---|---|---|---|---|---|---|
| j2 | first outline (median file) | 0.0214 | -0.0022 (-10.51 %) | -0.0005 / -0.0001 / -0.0002 | 0.0100 | pass | 0/5 |
| j2 | first read_span (median file) | 0.0181 | -0.0021 (-11.52 %) | +0.0002 / +0.0003 / -0.0002 | 0.0100 | pass | 0/5 |
| family | first outline (median file) | 0.1204 | -0.0930 (-77.23 %) | +0.0010 / -0.0011 / -0.0005 | 0.0100 | pass | 0/5 |
| family | first read_span (median file) | 0.1176 | -0.0941 (-80.01 %) | +0.0003 / -0.0023 / +0.0003 | 0.0100 | pass | 0/5 |
| fixtures | first outline (median file) | 0.4816 | -0.3872 (-80.41 %) | +0.0013 / -0.0031 / -0.0046 | 0.0100 | pass | 0/5 |
| fixtures | first read_span (median file) | 0.4936 | -0.4012 (-81.28 %) | +0.0014 / +0.0007 / -0.0083 | 0.0100 | pass | 0/5 |
| timing-10k | first find | 9.915 | -0.1300 (-1.31 %) | -0.1050 / -0.0188 / -0.0464 | 0.0991 | pass | 0/5 |
| timing-10k | first outline (median file) | 1.289 | -0.5193 (-40.28 %) | +0.0087 / +0.0129 / +0.0061 | 0.0129 | pass | 0/5 |
| timing-10k | first query | 4.321 | -0.1426 (-3.30 %) | +0.0166 / -0.0720 / +0.0444 | 0.0432 | pass | 0/5 |
| timing-10k | first read_span (median file) | 1.327 | -0.5452 (-41.09 %) | +0.0052 / +0.0069 / +0.0221 | 0.0133 | pass | 0/5 |
| prose-10k | first find | 34.777 | -0.9547 (-2.75 %) | +0.2175 / +0.1613 / +0.3814 | 0.3478 | pass | 0/5 |
| prose-10k | first outline (median file) | 2.559 | -1.4929 (-58.33 %) | +0.0036 / -0.0124 / +0.0099 | 0.0256 | pass | 0/5 |
| prose-10k | first query | 4.818 | -0.1606 (-3.33 %) | +0.0105 / +0.0329 / +0.0427 | 0.0482 | pass | 0/5 |
| prose-10k | first read_span (median file) | 2.574 | -1.5023 (-58.36 %) | -0.0071 / -0.0042 / -0.0043 | 0.0257 | pass | 0/5 |
| tamil-10k | first find | 9.923 | -0.1819 (-1.83 %) | -0.1978 / +0.0785 / -0.0900 | 0.0992 | pass | 0/5 |
| tamil-10k | first outline (median file) | 3.269 | -2.4768 (-75.77 %) | +0.0119 / +0.0138 / +0.0035 | 0.0327 | pass | 0/5 |
| tamil-10k | first query | 13.019 | -0.0263 (-0.20 %) | -0.0913 / +0.3161 / +0.1525 | 0.1302 | pass | 0/5 |
| tamil-10k | first read_span (median file) | 3.284 | -2.4872 (-75.73 %) | +0.0066 / +0.0265 / +0.0013 | 0.0328 | pass | 0/5 |

**Later read_span / outline, CPU per call** (48 cells)

| Corpus | Cell | main (median of 5) | head − main (median) | main2 / ctl1 / ctl2 − main | T | Rule | Band |
|---|---|---|---|---|---|---|---|
| j2 | outline largest CPU/call | 0.2408 | -0.0071 (-2.96 %) | -0.0009 / -0.0062 / -0.0055 | 0.0100 | pass | 1/5 |
| j2 | outline median CPU/call | 0.0072 | -0.0002 (-2.10 %) | +0.0000 / -0.0001 / -0.0001 | 0.0100 | pass | 1/5 |
| j2 | outline small CPU/call | 0.0021 | -0.0003 (-16.08 %) | +0.0000 / +0.0000 / +0.0000 | 0.0100 | pass | 0/5 |
| j2 | read_span head largest CPU/call | 0.0096 | -0.0001 (-1.25 %) | -0.0002 / +0.0000 / -0.0001 | 0.0100 | pass | 0/5 |
| j2 | read_span head median CPU/call | 0.0030 | +0.0001 (+2.81 %) | -0.0000 / +0.0000 / +0.0000 | 0.0100 | pass | 2/5 |
| j2 | read_span head small CPU/call | 0.0028 | -0.0003 (-10.21 %) | +0.0000 / +0.0000 / +0.0000 | 0.0100 | pass | 0/5 |
| j2 | read_span middle largest CPU/call | 0.0101 | +0.0002 (+1.55 %) | -0.0001 / +0.0001 / +0.0000 | 0.0100 | pass | 2/5 |
| j2 | read_span tail largest CPU/call | 0.0110 | +0.0001 (+1.05 %) | -0.0000 / +0.0001 / -0.0000 | 0.0100 | pass | 3/5 |
| family | outline largest CPU/call | 0.3885 | +0.0078 (+2.01 %) | +0.0007 / +0.0005 / +0.0001 | 0.0100 | pass | 3/5 |
| family | outline median CPU/call | 0.0073 | +0.0004 (+5.95 %) | +0.0000 / -0.0000 / -0.0000 | 0.0100 | pass | 3/5 |
| family | outline small CPU/call | 0.0019 | -0.0004 (-20.42 %) | -0.0000 / +0.0000 / +0.0000 | 0.0100 | pass | 0/5 |
| family | read_span head largest CPU/call | 0.3935 | +0.0069 (+1.76 %) | -0.0001 / +0.0010 / +0.0006 | 0.0100 | pass | 4/5 |
| family | read_span head median CPU/call | 0.0040 | +0.0001 (+2.55 %) | -0.0000 / +0.0000 / +0.0000 | 0.0100 | pass | 3/5 |
| family | read_span head small CPU/call | 0.0026 | -0.0004 (-16.38 %) | -0.0000 / +0.0000 / +0.0000 | 0.0100 | pass | 0/5 |
| family | read_span middle largest CPU/call | 0.4193 | +0.0071 (+1.69 %) | -0.0003 / +0.0013 / +0.0001 | 0.0100 | pass | 3/5 |
| family | read_span tail largest CPU/call | 0.4455 | +0.0076 (+1.71 %) | -0.0000 / +0.0015 / -0.0004 | 0.0100 | pass | 4/5 |
| fixtures | outline largest CPU/call | 0.3896 | +0.0064 (+1.65 %) | -0.0022 / -0.0017 / -0.0027 | 0.0100 | pass | 5/5 |
| fixtures | outline median CPU/call | 0.0096 | -0.0002 (-2.46 %) | +0.0001 / -0.0001 / -0.0002 | 0.0100 | pass | 2/5 |
| fixtures | outline small CPU/call | 0.0065 | +0.0007 (+10.95 %) | +0.0000 / +0.0000 / -0.0000 | 0.0100 | pass | 4/5 |
| fixtures | read_span head largest CPU/call | 0.3920 | +0.0089 (+2.27 %) | +0.0002 / -0.0000 / -0.0004 | 0.0100 | pass | 5/5 |
| fixtures | read_span head median CPU/call | 0.0060 | -0.0002 (-2.98 %) | +0.0000 / -0.0000 / -0.0000 | 0.0100 | pass | 2/5 |
| fixtures | read_span head small CPU/call | 0.0064 | +0.0007 (+10.82 %) | +0.0000 / +0.0000 / -0.0000 | 0.0100 | pass | 5/5 |
| fixtures | read_span middle largest CPU/call | 0.4184 | +0.0094 (+2.24 %) | -0.0004 / -0.0005 / -0.0008 | 0.0100 | pass | 5/5 |
| fixtures | read_span tail largest CPU/call | 0.4442 | +0.0090 (+2.03 %) | -0.0003 / -0.0001 / -0.0001 | 0.0100 | pass | 5/5 |
| timing-10k | outline largest CPU/call | 0.0522 | -0.0082 (-15.71 %) | +0.0002 / -0.0007 / -0.0004 | 0.0100 | pass | 0/5 |
| timing-10k | outline median CPU/call | 0.0387 | -0.0076 (-19.66 %) | +0.0001 / -0.0001 / -0.0001 | 0.0100 | pass | 0/5 |
| timing-10k | outline small CPU/call | 0.0247 | -0.0054 (-21.99 %) | +0.0001 / +0.0000 / +0.0003 | 0.0100 | pass | 0/5 |
| timing-10k | read_span head largest CPU/call | 0.0308 | -0.0070 (-22.74 %) | +0.0004 / +0.0001 / +0.0002 | 0.0100 | pass | 0/5 |
| timing-10k | read_span head median CPU/call | 0.0295 | -0.0076 (-25.66 %) | -0.0000 / +0.0001 / +0.0001 | 0.0100 | pass | 0/5 |
| timing-10k | read_span head small CPU/call | 0.0232 | -0.0048 (-20.76 %) | -0.0003 / -0.0001 / -0.0003 | 0.0100 | pass | 0/5 |
| timing-10k | read_span middle largest CPU/call | 0.0303 | -0.0077 (-25.55 %) | -0.0005 / +0.0001 / -0.0000 | 0.0100 | pass | 0/5 |
| timing-10k | read_span tail largest CPU/call | 0.0309 | -0.0076 (-24.59 %) | -0.0001 / -0.0001 / -0.0000 | 0.0100 | pass | 0/5 |
| prose-10k | outline largest CPU/call | 0.7289 | -0.0214 (-2.94 %) | -0.0001 / -0.0218 / -0.0146 | 0.0100 | pass | 0/5 |
| prose-10k | outline median CPU/call | 0.0285 | -0.0005 (-1.63 %) | +0.0002 / -0.0004 / -0.0005 | 0.0100 | pass | 0/5 |
| prose-10k | outline small CPU/call | 0.0235 | -0.0001 (-0.39 %) | +0.0001 / +0.0003 / +0.0004 | 0.0100 | pass | 0/5 |
| prose-10k | read_span head largest CPU/call | 0.0367 | +0.0003 (+0.86 %) | +0.0001 / +0.0000 / +0.0004 | 0.0100 | pass | 2/5 |
| prose-10k | read_span head median CPU/call | 0.0141 | -0.0001 (-1.07 %) | +0.0002 / +0.0001 / +0.0002 | 0.0100 | pass | 0/5 |
| prose-10k | read_span head small CPU/call | 0.0225 | -0.0001 (-0.47 %) | +0.0001 / +0.0003 / +0.0004 | 0.0100 | pass | 0/5 |
| prose-10k | read_span middle largest CPU/call | 0.0384 | +0.0004 (+1.01 %) | +0.0001 / +0.0002 / +0.0002 | 0.0100 | pass | 0/5 |
| prose-10k | read_span tail largest CPU/call | 0.0399 | +0.0003 (+0.70 %) | -0.0000 / +0.0003 / +0.0001 | 0.0100 | pass | 0/5 |
| tamil-10k | outline largest CPU/call | 0.0640 | -0.0021 (-3.25 %) | +0.0001 / -0.0005 / +0.0003 | 0.0100 | pass | 0/5 |
| tamil-10k | outline median CPU/call | 0.0538 | -0.0083 (-15.47 %) | +0.0004 / -0.0002 / +0.0001 | 0.0100 | pass | 0/5 |
| tamil-10k | outline small CPU/call | 0.0268 | -0.0054 (-19.95 %) | -0.0001 / -0.0001 / +0.0001 | 0.0100 | pass | 0/5 |
| tamil-10k | read_span head largest CPU/call | 0.0269 | -0.0032 (-12.05 %) | +0.0002 / +0.0001 / -0.0006 | 0.0100 | pass | 0/5 |
| tamil-10k | read_span head median CPU/call | 0.0370 | -0.0090 (-24.34 %) | -0.0003 / -0.0002 / +0.0000 | 0.0100 | pass | 0/5 |
| tamil-10k | read_span head small CPU/call | 0.0229 | -0.0051 (-22.21 %) | +0.0002 / +0.0003 / +0.0001 | 0.0100 | pass | 0/5 |
| tamil-10k | read_span middle largest CPU/call | 0.0234 | -0.0035 (-14.80 %) | +0.0002 / -0.0002 / -0.0002 | 0.0100 | pass | 0/5 |
| tamil-10k | read_span tail largest CPU/call | 0.0267 | -0.0033 (-12.20 %) | +0.0003 / -0.0003 / +0.0002 | 0.0100 | pass | 0/5 |

**Update and first publish (searchd index --update, wall ms per process)** (8 cells)

| Corpus | Cell | main (median of 5) | head − main (median) | main2 / ctl1 / ctl2 − main | T | Rule | Band |
|---|---|---|---|---|---|---|---|
| family | first (median of 3) | 12.739 | +0.1025 (+0.80 %) | -0.1992 / -0.1574 / -0.2118 | 0.1274 | pass | 2/5 |
| family | update (median of 3) | 12.032 | -0.2047 (-1.70 %) | -0.1071 / -0.1958 / -0.1823 | 0.1203 | pass | 2/5 |
| timing-10k | first (median of 3) | 170.5 | +1.8955 (+1.11 %) | +0.3295 / -0.8282 / -1.5388 | 1.7054 | at T, within controls | 3/5 |
| timing-10k | update (median of 3) | 170.9 | -3.7203 (-2.18 %) | +0.5150 / -0.2824 / -0.4899 | 1.7088 | pass | 0/5 |
| prose-10k | first (median of 3) | 223.7 | -0.4124 (-0.18 %) | -3.4426 / +3.3810 / -1.8036 | 2.2373 | pass | 0/5 |
| prose-10k | update (median of 3) | 223.0 | -6.2471 (-2.80 %) | +3.4913 / +2.5266 / -0.8434 | 2.2297 | pass | 1/5 |
| tamil-10k | first (median of 3) | 232.2 | -0.6439 (-0.28 %) | -1.6592 / +1.6039 / +0.2957 | 2.3224 | pass | 0/5 |
| tamil-10k | update (median of 3) | 234.6 | -31.0741 (-13.25 %) | -3.7086 / -0.8565 / -2.7556 | 2.3457 | pass | 0/5 |

**Warm query and find cells:** 163 cells; 0 fail the rule; 0 at or above T but within the controls; band excursions in 3 cells on 3 or more runs.

| Corpus | Cell | main | head − main | max control − main | T | Rule |
|---|---|---|---|---|---|---|
| tamil-10k | filename doc 00000 | 0.6851 | +0.0093 (+1.36 %) | +0.0152 | 0.0100 | pass |
| tamil-10k | both doc 00000 | 0.7804 | +0.0043 (+0.56 %) | +0.0088 | 0.0100 | pass |
| tamil-10k | both சைகீளையில் | 0.3894 | +0.0040 (+1.03 %) | +0.0045 | 0.0100 | pass |
| tamil-10k | both றூகுஞங்கள் | 0.3828 | +0.0031 (+0.82 %) | +0.0044 | 0.0100 | pass |
| prose-10k | find phrase bottle and orchard | 0.1194 | +0.0028 (+2.30 %) | +0.0039 | 0.0100 | pass |
| prose-10k | find phrase you get bowls | 0.1030 | +0.0017 (+1.66 %) | +0.0237 | 0.0100 | pass |
| tamil-10k | content றூகுஞங்கள் | 0.0309 | +0.0006 (+2.02 %) | +0.0005 | 0.0100 | pass |
| tamil-10k | find phrase கேடேயி குகடம் கிகசம் | 0.0500 | +0.0005 (+1.08 %) | +0.0008 | 0.0100 | pass |

Answer hashes: 0 differences between variants or runs.
