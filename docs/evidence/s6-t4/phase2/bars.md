## Open, first find, memory

| Corpus | Run | open main / v3 (ms) | change | first find main / v3 (ms) | change | memory after open main / v3 (MB) | below main | after queries main / v3 (MB) |
|---|---|---|---|---|---|---|---|---|
| timing | 1 | 7.345 / 5.450 | -25.8 % | 10.091 / 9.933 | -1.6 % | 33.4 / 26.3 | 7.1 | 43.9 / 37.4 |
| timing | 2 | 7.357 / 5.445 | -26.0 % | 9.938 / 9.921 | -0.2 % | 33.4 / 26.3 | 7.1 | 43.7 / 37.2 |
| prose | 1 | 14.693 / 11.803 | -19.7 % | 35.531 / 35.036 | -1.4 % | 68.8 / 53.7 | 15.1 | 88.3 / 72.1 |
| prose | 2 | 14.616 / 11.864 | -18.8 % | 35.586 / 34.307 | -3.6 % | 68.8 / 53.7 | 15.1 | 88.0 / 72.3 |
| Tamil | 1 | 10.309 / 7.901 | -23.4 % | 10.606 / 9.701 | -8.5 % | 54.4 / 47.5 | 6.9 | 66.5 / 59.5 |
| Tamil | 2 | 9.724 / 7.880 | -19.0 % | 10.405 / 10.321 | -0.8 % | 54.4 / 47.5 | 6.9 | 66.4 / 59.0 |
| J2 | 1 | 0.176 / 0.143 | -18.5 % | 0.066 / 0.063 | -5.2 % | 0.3 / 0.1 | 0.1 | 0.8 / 0.3 |
| J2 | 2 | 0.174 / 0.145 | -16.9 % | 0.067 / 0.065 | -1.6 % | 0.3 / 0.1 | 0.1 | 0.6 / 0.5 |

## Warm query and find cells (v3 - main, ms; band = largest |control - main| of the run)

| Corpus | Workload | cells | band run 1 / 2 | worst v3 - main run 1 / 2 | over band both runs | +0.010 or more both runs | one run only |
|---|---|---|---|---|---|---|---|
| timing | query | 45 | 0.0158 / 0.0062 | +0.0022 / +0.0028 | none | none | none |
| timing | find | 9 | 0.0255 / 0.0072 | -0.0000 / +0.0205 | none | none | words `from` (-0.0177 / +0.0205; main 3.034); prefix `bada*` (-0.0003 / +0.0098; main 0.805) |
| prose | query | 45 | 0.0237 / 0.0180 | +0.0006 / +0.0130 | none | none | content `across lengthy seeming 04276` (-0.0007 / +0.0130; main 0.220) |
| prose | find | 9 | 0.2385 / 0.2530 | +0.0175 / +0.0111 | none | none | phrase `you get bowls` (+0.0175 / -0.0185; main 0.107) |
| Tamil | query | 45 | 0.0169 / 0.0100 | +0.0067 / +0.0068 | none | none | none |
| Tamil | find | 10 | 0.0275 / 0.0297 | +0.0244 / +0.0000 | none | none | words `கீகசை` (+0.0218 / -0.0154; main 2.972); prefix `டூகன*` (+0.0244 / -0.0135; main 2.987) |
| J2 | query | 566 | 0.0067 / 0.0204 | +0.0035 / +0.0017 | none | none | none |
| J2 | find | 7 | 0.0001 / 0.0001 | +0.0000 / +0.0001 | none | none | none |

Answer hashes differing from main's (any library, any cell, both runs): 0

## Missed

None.
