// S6-T4 second rework (an investigation, not a bar run). Build: clang -O2 qloop.c -o qloop
// qloop LIBRARY INDEX FIELD TEXT SECONDS|-N
//   loops ss_query (top 10, lexical, FIELD) after 5,000 warm calls; with -N it
//   times N calls one by one (mach_absolute_time) and prints the median and the
//   25th percentile in microseconds. With SECONDS it only loops (for a profiler).
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mach/mach_time.h>
typedef void* (*open_t)(const char*);
typedef void* (*query_t)(void*, const char*, const float*, size_t, size_t, const char*);
typedef void (*free_t)(void*);
static int cmp(const void*a,const void*b){unsigned long long x=*(unsigned long long*)a,y=*(unsigned long long*)b;return x<y?-1:x>y;}
int main(int argc, char** argv) {
  void* lib = dlopen(argv[1], RTLD_NOW); if (!lib) { puts(dlerror()); return 1; }
  open_t o = (open_t)dlsym(lib, "ss_open"); query_t q = (query_t)dlsym(lib, "ss_query"); free_t f = (free_t)dlsym(lib, "ss_free");
  void* h = o(argv[2]); if (!h) { puts("open failed"); return 1; }
  char opts[256]; snprintf(opts, sizeof opts, "{\"retrieval_mode\":\"lexical\",\"search_field\":\"%s\"}", argv[3]);
  for (int i = 0; i < 5000; i++) f(q(h, argv[4], 0, 0, 10, opts));
  long n = atol(argv[5]);
  if (n < 0) {
    n = -n; unsigned long long* s = malloc(n * sizeof *s);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    for (long i = 0; i < n; i++) { unsigned long long a = mach_absolute_time(); f(q(h, argv[4], 0, 0, 10, opts)); s[i] = mach_absolute_time() - a; }
    qsort(s, n, sizeof *s, cmp);
    printf("%.4f %.4f\n", s[n/2] * tb.numer / (double)tb.denom / 1000.0, s[n/4] * tb.numer / (double)tb.denom / 1000.0);
    return 0;
  }
  time_t end = time(0) + n;
  while (time(0) < end) for (int i = 0; i < 1000; i++) f(q(h, argv[4], 0, 0, 10, opts));
  return 0;
}
