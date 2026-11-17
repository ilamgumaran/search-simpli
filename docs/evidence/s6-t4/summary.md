
### timing-10k

| Variant | Open p50 | Memory after open (MB) | after queries (MB) | content Σ | filename Σ | both Σ | find Σ | first query | first find |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| today | 7.16 / 7.17 | 33.4 / 33.4 | 43.8 / 44.0 | 1.359 / 1.365 | 0.279 / 0.279 | 3.220 / 3.230 | 4.764 / 4.749 | 4.263 / 4.315 | 9.891 / 9.863 |
| today-b | 7.16 / 7.14 | 33.4 / 33.4 | 43.9 / 43.7 | 1.356 / 1.357 | 0.280 / 0.281 | 3.213 / 3.227 | 4.763 / 4.774 | 4.280 / 4.283 | 10.114 / 10.292 |
| eager-v3 | 5.38 / 5.39 | 26.3 / 26.3 | 37.3 / 37.4 | 1.347 / 1.352 | 0.281 / 0.279 | 3.213 / 3.178 | 4.741 / 4.741 | 4.211 / 4.268 | 9.927 / 9.820 |
| lazy-nocache | 2.42 / 2.42 | 18.6 / 18.6 | 29.1 / 29.4 | 1.614 / 1.625 | 0.284 / 0.285 | 3.498 / 3.484 | 4.869 / 4.877 | 4.319 / 4.402 | 18.856 / 18.633 |
| lazy-1mib | 2.44 / 2.43 | 18.6 / 18.6 | 29.4 / 29.7 | 1.369 / 1.366 | 0.282 / 0.284 | 3.238 / 3.243 | 4.684 / 4.683 | 4.307 / 4.318 | 18.281 / 18.372 |
| lazy-keep | 2.47 / 2.45 | 18.6 / 18.6 | 29.5 / 29.7 | 1.383 / 1.374 | 0.285 / 0.284 | 3.253 / 3.241 | 4.684 / 4.679 | 4.298 / 4.335 | 18.367 / 18.550 |
| lazy-all | 2.41 / 2.45 | 18.6 / 18.6 | 37.3 / 37.3 | 1.378 / 1.373 | 0.284 / 0.283 | 3.245 / 3.240 | 4.685 / 4.707 | 7.090 / 7.211 | 10.315 / 10.304 |
| lazy-checked | 5.22 / 5.50 | 18.6 / 18.6 | 29.3 / 29.3 | 1.363 / 1.370 | 0.284 / 0.287 | 3.245 / 3.247 | 4.694 / 4.683 | 4.324 / 4.381 | 18.068 / 19.539 |

`run3`: 5-minute load 3.68–3.95.
- `today-b` − `today`: largest +0.0024 ms (find:words `from`), smallest -0.0035 ms (find:prefix `bada*`); answers identical
- `eager-v3` − `today`: largest +0.0061 ms (find:words `from badamo`), smallest -0.0129 ms (find:prefix `bada*`); answers identical
- `lazy-nocache` − `today`: largest +0.0471 ms (both `were belohu`), smallest -0.0023 ms (content `doc 00000`); answers identical
- `lazy-1mib` − `today`: largest +0.0099 ms (both `doc 00000`), smallest -0.0413 ms (find:words `from`); answers identical
- `lazy-keep` − `today`: largest +0.0088 ms (both `doc 00000`), smallest -0.0442 ms (find:words `from`); answers identical
- `lazy-all` − `today`: largest +0.0064 ms (content `system systems`), smallest -0.0413 ms (find:words `from`); answers identical
- `lazy-checked` − `today`: largest +0.0070 ms (both `doc 00000`), smallest -0.0375 ms (find:words `from`); answers identical

`run4`: 5-minute load 2.79–2.95.
- `today-b` − `today`: largest +0.0160 ms (find:words `from`), smallest -0.0025 ms (both `from badamo`); answers identical
- `eager-v3` − `today`: largest +0.0060 ms (find:words `from badamo`), smallest -0.0154 ms (both `were`); answers identical
- `lazy-nocache` − `today`: largest +0.0495 ms (content `were belohu`), smallest -0.0000 ms (filename `were`); answers identical
- `lazy-1mib` − `today`: largest +0.0058 ms (both `doc 00000`), smallest -0.0343 ms (find:words `from`); answers identical
- `lazy-keep` − `today`: largest +0.0071 ms (both `doc 00000`), smallest -0.0311 ms (find:words `from`); answers identical
- `lazy-all` − `today`: largest +0.0071 ms (both `doc 00000`), smallest -0.0159 ms (find:words `from`); answers identical
- `lazy-checked` − `today`: largest +0.0076 ms (filename `doc 00000`), smallest -0.0362 ms (find:words `from`); answers identical


### prose-10k

| Variant | Open p50 | Memory after open (MB) | after queries (MB) | content Σ | filename Σ | both Σ | find Σ | first query | first find |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| today | 14.28 / 14.30 | 68.8 / 68.8 | 88.3 / 88.1 | 1.809 / 1.810 | 2.226 / 2.227 | 4.718 / 4.729 | 26.955 / 26.966 | 5.001 / 4.915 | 34.620 / 34.712 |
| today-b | 14.21 / 14.27 | 68.9 / 68.9 | 88.5 / 88.5 | 1.809 / 1.806 | 2.230 / 2.230 | 4.731 / 4.730 | 26.982 / 27.027 | 4.957 / 4.885 | 35.485 / 35.481 |
| eager-v3 | 11.57 / 11.59 | 53.7 / 53.7 | 72.2 / 72.1 | 1.806 / 1.810 | 2.250 / 2.197 | 4.743 / 4.699 | 27.050 / 27.010 | 4.846 / 4.828 | 34.456 / 34.652 |
| lazy-nocache | 4.22 / 4.24 | 35.8 / 35.8 | 54.8 / 54.6 | 2.132 / 2.105 | 2.266 / 2.266 | 5.083 / 5.080 | 27.304 / 27.010 | 4.797 / 4.774 | 58.925 / 55.534 |
| lazy-1mib | 4.21 / 4.19 | 35.8 / 35.8 | 54.7 / 54.7 | 1.847 / 1.870 | 2.289 / 2.257 | 4.822 / 4.819 | 26.554 / 26.687 | 4.812 / 4.786 | 56.617 / 54.826 |
| lazy-keep | 4.18 / 4.19 | 35.8 / 35.8 | 54.8 / 54.9 | 1.860 / 1.854 | 2.283 / 2.260 | 4.830 / 4.809 | 26.740 / 26.598 | 4.766 / 4.789 | 54.876 / 57.789 |
| lazy-all | 4.27 / 4.25 | 35.8 / 35.8 | 72.9 / 72.5 | 1.852 / 1.862 | 2.257 / 2.258 | 4.826 / 4.823 | 26.861 / 26.872 | 11.440 / 11.535 | 37.142 / 37.596 |
| lazy-checked | 11.48 / 11.12 | 35.8 / 35.8 | 54.7 / 54.5 | 1.855 / 1.854 | 2.264 / 2.260 | 4.798 / 4.816 | 26.734 / 26.923 | 4.822 / 4.787 | 55.988 / 57.296 |

`run3`: 5-minute load 3.25–3.68.
- `today-b` − `today`: largest +0.0265 ms (find:phrase `you get bowls`), smallest -0.0236 ms (find:prefix `with*`); answers identical
- `eager-v3` − `today`: largest +0.1267 ms (find:words `the`), smallest -0.0333 ms (find:prefix `with*`); answers identical
- `lazy-nocache` − `today`: largest +0.1083 ms (find:phrase `bottle and orchard`), smallest -0.0093 ms (find:words `within`); answers identical
- `lazy-1mib` − `today`: largest +0.0332 ms (find:phrase `bottle and orchard`), smallest -0.2598 ms (find:prefix `with*`); answers identical
- `lazy-keep` − `today`: largest +0.0327 ms (find:phrase `bottle and orchard`), smallest -0.1337 ms (find:words `the`); answers identical
- `lazy-all` − `today`: largest +0.0261 ms (content `have drink`), smallest -0.0288 ms (find:prefix `with*`); answers identical
- `lazy-checked` − `today`: largest +0.0366 ms (find:phrase `bottle and orchard`), smallest -0.1304 ms (find:words `the`); answers identical

`run4`: 5-minute load 2.53–2.79.
- `today-b` − `today`: largest +0.0362 ms (find:phrase `bottle and orchard`), smallest -0.0068 ms (find:phrase `partly all rougher`); answers identical
- `eager-v3` − `today`: largest +0.0535 ms (find:words `the`), smallest -0.0357 ms (find:prefix `with*`); answers identical
- `lazy-nocache` − `today`: largest +0.0999 ms (find:phrase `bottle and orchard`), smallest -0.0757 ms (find:prefix `with*`); answers identical
- `lazy-1mib` − `today`: largest +0.0299 ms (content `have drink`), smallest -0.1245 ms (find:words `the`); answers identical
- `lazy-keep` − `today`: largest +0.0295 ms (find:phrase `bottle and orchard`), smallest -0.2615 ms (find:prefix `with*`); answers identical
- `lazy-all` − `today`: largest +0.0295 ms (content `have drink`), smallest -0.0935 ms (find:prefix `with*`); answers identical
- `lazy-checked` − `today`: largest +0.0395 ms (find:words `the`), smallest -0.0713 ms (find:prefix `with*`); answers identical


### tamil-10k

| Variant | Open p50 | Memory after open (MB) | after queries (MB) | content Σ | filename Σ | both Σ | find Σ | first query | first find |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| today | 9.49 / 9.54 | 54.4 / 54.4 | 66.5 / 66.2 | 1.267 / 1.270 | 0.732 / 0.732 | 4.429 / 4.419 | 7.136 / 7.161 | 12.892 / 13.020 | 10.002 / 10.127 |
| today-b | 9.49 / 9.51 | 54.4 / 54.4 | 66.3 / 66.5 | 1.249 / 1.267 | 0.736 / 0.740 | 4.455 / 4.457 | 7.132 / 7.173 | 12.836 / 12.889 | 9.915 / 10.120 |
| eager-v3 | 7.83 / 7.84 | 47.5 / 47.5 | 59.5 / 59.7 | 1.269 / 1.280 | 0.740 / 0.742 | 4.452 / 4.463 | 7.150 / 7.155 | 12.794 / 12.877 | 10.110 / 10.105 |
| lazy-nocache | 4.67 / 4.64 | 39.8 / 39.8 | 51.6 / 51.7 | 1.564 / 1.565 | 0.741 / 0.740 | 4.559 / 4.543 | 7.469 / 7.479 | 13.207 / 13.120 | 18.651 / 18.091 |
| lazy-1mib | 4.64 / 4.64 | 39.8 / 39.8 | 51.7 / 51.7 | 1.411 / 1.397 | 0.739 / 0.745 | 4.384 / 4.412 | 7.105 / 7.105 | 13.152 / 13.214 | 19.316 / 19.136 |
| lazy-keep | 4.65 / 4.65 | 39.8 / 39.8 | 51.9 / 51.7 | 1.409 / 1.407 | 0.745 / 0.742 | 4.397 / 4.390 | 7.080 / 7.131 | 13.252 / 13.232 | 19.152 / 19.193 |
| lazy-all | 4.63 / 4.67 | 39.8 / 39.8 | 59.7 / 60.0 | 1.401 / 1.407 | 0.739 / 0.743 | 4.383 / 4.401 | 7.084 / 7.071 | 13.109 / 13.121 | 22.775 / 23.070 |
| lazy-checked | 7.50 / 7.53 | 39.8 / 39.8 | 51.9 / 52.0 | 1.408 / 1.412 | 0.737 / 0.738 | 4.375 / 4.386 | 7.103 / 7.108 | 13.221 / 13.280 | 18.762 / 18.960 |

`run3`: 5-minute load 2.97–3.25.
- `today-b` − `today`: largest +0.0051 ms (both `டூகனை சைகீளையில்`), smallest -0.0100 ms (content `டூகனை சைகீளையில்`); answers identical
- `eager-v3` − `today`: largest +0.0100 ms (find:phrase `டூகனை சேகணம் சூகஞம்`), smallest -0.0050 ms (content `டூகனை சைகீளையில்`); answers identical
- `lazy-nocache` − `today`: largest +0.1535 ms (find:phrase `டூகனை சேகணம் சூகஞம்`), smallest -0.0004 ms (both `system systems`); answers identical
- `lazy-1mib` − `today`: largest +0.0464 ms (content `கீகசை றூகுஞங்கள்`), smallest -0.0382 ms (find:prefix `டூகன*`); answers identical
- `lazy-keep` − `today`: largest +0.0480 ms (content `கீகசை றூகுஞங்கள்`), smallest -0.0473 ms (find:prefix `டூகன*`); answers identical
- `lazy-all` − `today`: largest +0.0489 ms (content `கீகசை றூகுஞங்கள்`), smallest -0.0493 ms (find:prefix `டூகன*`); answers identical
- `lazy-checked` − `today`: largest +0.0454 ms (content `கீகசை றூகுஞங்கள்`), smallest -0.0338 ms (find:prefix `டூகன*`); answers identical

`run4`: 5-minute load 2.34–2.53.
- `today-b` − `today`: largest +0.0128 ms (find:words `கீகசை`), smallest -0.0043 ms (content `கீகசை றூகுஞங்கள்`); answers identical
- `eager-v3` − `today`: largest +0.0119 ms (both `கீகசை றூகுஞங்கள்`), smallest -0.0188 ms (find:prefix `டூகன*`); answers identical
- `lazy-nocache` − `today`: largest +0.1502 ms (find:phrase `டூகனை சேகணம் சூகஞம்`), smallest -0.0001 ms (content `retrieval hybrid`); answers identical
- `lazy-1mib` − `today`: largest +0.0484 ms (content `டூகனை சைகீளையில்`), smallest -0.0455 ms (find:words `கீகசை`); answers identical
- `lazy-keep` − `today`: largest +0.0485 ms (content `டூகனை சைகீளையில்`), smallest -0.0430 ms (find:prefix `டூகன*`); answers identical
- `lazy-all` − `today`: largest +0.0478 ms (content `டூகனை சைகீளையில்`), smallest -0.0671 ms (find:prefix `டூகன*`); answers identical
- `lazy-checked` − `today`: largest +0.0479 ms (content `டூகனை சைகீளையில்`), smallest -0.0450 ms (find:prefix `டூகன*`); answers identical


### j2

| Variant | Open p50 | Memory after open (MB) | after queries (MB) | content Σ | filename Σ | both Σ | find Σ | first query | first find |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| today | 0.18 / 0.18 | 0.3 / 0.3 | 0.5 / 0.9 | 3.080 / 3.091 | – / – | 11.806 / 11.830 | 0.031 / 0.031 | 0.412 / 0.398 | 0.069 / 0.063 |
| today-b | 0.18 / 0.18 | 0.3 / 0.3 | 0.8 / 0.9 | 3.086 / 3.084 | – / – | 11.766 / 11.747 | 0.031 / 0.031 | 0.395 / 0.400 | 0.065 / 0.065 |
| eager-v3 | 0.15 / 0.15 | 0.1 / 0.2 | 0.4 / 0.7 | 3.052 / 3.045 | – / – | 11.612 / 11.656 | 0.030 / 0.031 | 0.397 / 0.412 | 0.063 / 0.068 |
| lazy-nocache | 0.14 / 0.14 | 0.1 / 0.1 | 0.6 / 0.7 | 3.261 / 3.262 | – / – | 12.068 / 12.125 | 0.035 / 0.035 | 0.448 / 0.450 | 0.157 / 0.158 |
| lazy-1mib | 0.14 / 0.14 | 0.1 / 0.1 | 0.7 / 0.6 | 3.080 / 3.077 | – / – | 11.862 / 11.822 | 0.031 / 0.031 | 0.452 / 0.434 | 0.157 / 0.142 |
| lazy-keep | 0.14 / 0.14 | 0.1 / 0.1 | 0.9 / 0.8 | 3.079 / 3.076 | – / – | 11.843 / 11.864 | 0.031 / 0.031 | 0.452 / 0.444 | 0.150 / 0.153 |
| lazy-all | 0.14 / 0.14 | 0.1 / 0.1 | 0.5 / 0.9 | 3.075 / 3.073 | – / – | 11.864 / 11.873 | 0.031 / 0.031 | 0.485 / 0.482 | 0.094 / 0.086 |
| lazy-checked | 0.16 / 0.16 | 0.2 / 0.1 | 0.7 / 0.5 | 3.081 / 3.073 | – / – | 11.865 / 11.857 | 0.031 / 0.031 | 0.450 / 0.452 | 0.154 / 0.160 |

`run3`: 5-minute load 2.95–2.98.
- `today-b` − `today`: largest +0.0016 ms (both `shedding fur`), smallest -0.0034 ms (both `november calendar`); answers identical
- `eager-v3` − `today`: largest +0.0011 ms (both `spelling words week 9`), smallest -0.0060 ms (both `november calendar`); answers identical
- `lazy-nocache` − `today`: largest +0.0040 ms (both `painting the fence`), smallest -0.0014 ms (both `recorder practice minutes`); answers identical
- `lazy-1mib` − `today`: largest +0.0027 ms (both `fractoins homework`), smallest -0.0016 ms (both `house rules`); answers identical
- `lazy-keep` − `today`: largest +0.0040 ms (both `dentist thrusday`), smallest -0.0030 ms (both `november calendar`); answers identical
- `lazy-all` − `today`: largest +0.0036 ms (both `spelling words week 9`), smallest -0.0015 ms (both `sciense fair`); answers identical
- `lazy-checked` − `today`: largest +0.0095 ms (both `the torley wheel`), smallest -0.0018 ms (both `recorder practice minutes`); answers identical

`run4`: 5-minute load 2.31–2.34.
- `today-b` − `today`: largest +0.0020 ms (both `recorder practice minutes`), smallest -0.0059 ms (both `surfing`); answers identical
- `eager-v3` − `today`: largest +0.0025 ms (both `recorder practice minutes`), smallest -0.0051 ms (both `surfing`); answers identical
- `lazy-nocache` − `today`: largest +0.0057 ms (both `painting the fence`), smallest -0.0014 ms (both `surfing`); answers identical
- `lazy-1mib` − `today`: largest +0.0028 ms (both `recorder practice minutes`), smallest -0.0023 ms (both `catchup with chips`); answers identical
- `lazy-keep` − `today`: largest +0.0075 ms (both `reading list`), smallest -0.0026 ms (both `canned`); answers identical
- `lazy-all` − `today`: largest +0.0031 ms (both `recorder practice minutes`), smallest -0.0026 ms (both `canned`); answers identical
- `lazy-checked` − `today`: largest +0.0047 ms (both `painting the fence`), smallest -0.0036 ms (both `surfing`); answers identical

