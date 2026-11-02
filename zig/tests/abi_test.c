/*
 * C ABI conformance harness for search_simpli (docs/tasks/S1-T0.md,
 * criterion 3). Built and run by `zig build test-abi`.
 *
 * It publishes the same three-document demo snapshot as `searchd init-demo`
 * (zig/src/main.zig's demoDocuments()) through ss_import_json(), opens it
 * with ss_open(), then compares ss_status()/ss_query()/ss_evidence() against
 * golden JSON captured from a real `zig build run -- init-demo` +
 * `zig build run -- serve` run (docs/tasks/S1-T0.md's Report has the exact
 * commands and full pasted output). ss_query()'s golden string is not
 * hand-written: it is the literal `result` field of that captured
 * JSON-RPC `search_knowledge` response, because zig/src/abi.zig's ss_query
 * shares its JSON-writing code (rpc.writeSearchResultValue) with the
 * JSON-RPC service, so the two are byte-for-byte identical by construction.
 *
 * Contract 2.0.0 (docs/tasks/S3-T4.md): six more checks, one per new
 * function (ss_apply_changes, ss_find, ss_outline, ss_read_span,
 * ss_list_files, ss_roots), each with its error paths; the v1 goldens are
 * kept as byte prefixes and the 2.0.0 additions checked after them.
 */

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

/* Apple's unistd.h declares mkdtemp only at the full Darwin level, which _POSIX_C_SOURCE lowers. */
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "search_simpli.h"

static int failures = 0;
static int checks = 0;

static void expect_streq(const char *label, const char *expected, const char *actual) {
    checks++;
    if (actual == NULL) {
        failures++;
        fprintf(stderr, "FAIL %s: got NULL (ss_last_error: %s)\n", label, ss_last_error());
        return;
    }
    if (strcmp(expected, actual) != 0) {
        failures++;
        fprintf(stderr, "FAIL %s:\n  expected: %s\n  actual:   %s\n", label, expected, actual);
        return;
    }
    printf("PASS %s\n", label);
}

static void expect_true(const char *label, int condition, const char *detail) {
    checks++;
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL %s (%s)\n", label, detail);
        return;
    }
    printf("PASS %s\n", label);
}

/* NULL plus an ss_last_error() naming `code` and holding `needle`. */
static int refused(const char *result, const char *code, const char *needle, char *why, size_t why_len) {
    const char *message = ss_last_error();
    if (result != NULL) {
        snprintf(why, why_len, "expected NULL for %s, got %.120s", needle, result);
        ss_free((char *)result);
        return 0;
    }
    if (strstr(message, code) == NULL || strstr(message, needle) == NULL) {
        snprintf(why, why_len, "expected %s and \"%s\", ss_last_error: %s", code, needle, message);
        return 0;
    }
    return 1;
}

/* `result` is non-NULL and holds every needle (then freed). */
static int holds(char *result, const char *const *needles, char *why, size_t why_len) {
    if (result == NULL) {
        snprintf(why, why_len, "got NULL (ss_last_error: %s)", ss_last_error());
        return 0;
    }
    for (size_t i = 0; needles[i] != NULL; i++) {
        if (strstr(result, needles[i]) == NULL) {
            snprintf(why, why_len, "missing %s in %.300s", needles[i], result);
            ss_free(result);
            return 0;
        }
    }
    ss_free(result);
    return 1;
}

static char *base64_of(const char *text) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t length = strlen(text);
    char *out = malloc(4 * ((length + 2) / 3) + 1);
    size_t o = 0;
    for (size_t i = 0; i < length; i += 3) {
        unsigned value = (unsigned char)text[i] << 16;
        if (i + 1 < length) value |= (unsigned char)text[i + 1] << 8;
        if (i + 2 < length) value |= (unsigned char)text[i + 2];
        out[o++] = alphabet[(value >> 18) & 63];
        out[o++] = alphabet[(value >> 12) & 63];
        out[o++] = i + 1 < length ? alphabet[(value >> 6) & 63] : '=';
        out[o++] = i + 2 < length ? alphabet[value & 63] : '=';
    }
    out[o] = '\0';
    return out;
}

static const char *week_md =
    "---\ntitle: Week 7\n---\n# Week 7\n\n## Spelling\nWords for Friday: harbour, island.\n\n"
    "## Dates\nBand concert: count me in, Friday 6.\n";

static const char *demo_interchange_json =
    "{\"format_version\":1,\"generation\":1,\"analyzer_id\":\"ascii-alnum-v1\","
    "\"embedding_model_id\":\"manual-demo-vectors-v1\",\"documents\":["
    "{\"id\":\"hybrid-guide\",\"path\":\"guides/hybrid.md\",\"start_line\":1,\"end_line\":6,"
    "\"text\":\"hybrid retrieval combines lexical and semantic ranks with reciprocal rank fusion\","
    "\"vector\":[0.9,0.1],\"required_labels\":[]},"
    "{\"id\":\"lexical-guide\",\"path\":\"guides/lexical.md\",\"start_line\":10,\"end_line\":12,"
    "\"text\":\"BM25 is an exact lexical ranking function\","
    "\"vector\":[0.1,0.9],\"required_labels\":[]},"
    "{\"id\":\"semantic-guide\",\"path\":\"guides/semantic.md\",\"start_line\":20,\"end_line\":22,"
    "\"text\":\"meaning based retrieval finds paraphrases\","
    "\"vector\":[1,0],\"required_labels\":[]}"
    "]}";

/* Captured verbatim from a real run; see docs/tasks/S1-T0.md's Report. */
static const char *golden_status_json =
    "{\"ready\":true,\"generation\":1,\"analyzer_id\":\"ascii-alnum-v1\","
    "\"embedding_model_id\":\"manual-demo-vectors-v1\",\"vector_dimensions\":2,"
    "\"documents\":3,\"terms\":21,\"postings\":23}";

static const char *golden_query_result_json =
    "{\"tool\":\"search_knowledge\",\"query\":\"hybrid ranking\",\"index\":{\"version\":2,"
    "\"generation\":1,\"analyzer_id\":\"ascii-alnum-v1\",\"embedding_model_id\":\"manual-demo-vectors-v1\"},"
    "\"retrieval\":{\"mode\":\"hybrid\",\"vector_dimensions\":2,\"authorization\":{"
    "\"semantics\":\"all-required-labels-v1\",\"principal_label_count\":0}},"
    "\"results\":[{\"chunk_id\":\"hybrid-guide\",\"citation\":{\"path\":\"guides/hybrid.md\","
    "\"start_line\":1,\"end_line\":6},\"content\":\"hybrid retrieval combines lexical and semantic "
    "ranks with reciprocal rank fusion\",\"score\":0.032258063554763794,\"ranking\":{\"lexical\":{"
    "\"rank\":2,\"score\":0.8327174186706543},\"vector\":{\"rank\":2,\"score\":0.9938837289810181}}}],"
    "\"answer_policy\":{\"ground_in_results\":true,\"cite_path_and_lines\":true,"
    "\"say_when_evidence_is_insufficient\":true}}";

static const char *golden_evidence_found_json =
    "[{\"chunk_id\":\"hybrid-guide\",\"citation\":{\"path\":\"guides/hybrid.md\","
    "\"start_line\":1,\"end_line\":6},\"content\":\"hybrid retrieval combines lexical and semantic "
    "ranks with reciprocal rank fusion\"}]";

static const char *golden_evidence_missing_json =
    "[{\"chunk_id\":\"missing-id\",\"found\":false}]";

int main(void) {
    char dir_template[] = "/tmp/ss-abi-test-XXXXXX";
    char *dir = mkdtemp(dir_template);
    if (dir == NULL) {
        fprintf(stderr, "FAIL setup: mkdtemp failed\n");
        return 1;
    }

    expect_streq("ss_version", "2.2.0", ss_version());

    long long generation = ss_import_json(dir, demo_interchange_json, strlen(demo_interchange_json));
    expect_true("ss_import_json publishes generation 1", generation == 1, "unexpected generation/error code");

    long long bad = ss_import_json(dir, "not json", 8);
    expect_true("ss_import_json rejects malformed JSON with a negative code", bad < 0, "expected negative code");
    expect_true("ss_last_error is non-empty after a failure", ss_last_error()[0] != '\0', "empty ss_last_error()");

    ss_handle *handle = ss_open(dir);
    expect_true("ss_open opens the published demo snapshot", handle != NULL, ss_last_error());
    if (handle == NULL) {
        fprintf(stderr, "abi_test: %d/%d checks passed (aborted after ss_open failure)\n", checks - failures, checks);
        return 1;
    }

    expect_true("ss_open on a missing directory returns NULL", ss_open("/nonexistent/search-simpli-abi-test") == NULL, "expected NULL");

    /* Contract 2.0.0 appends the section 8 status fields after the v1 ones
     * (over the default scope: every root, no labels); contract 2.1.0
     * (S4-T1) appends "source", the source section's state ("absent": an
     * import-json snapshot binds none). */
    {
        static const char *tail =
            ",\"files\":3,\"pending\":0,\"truncated\":false,\"roots\":[{\"root_id\":\"r-legacy\","
            "\"label\":\"folder\",\"kind\":\"local\",\"files\":3,\"documents\":3,\"pending\":0}],"
            "\"pending_paths\":[],\"has_source\":false,\"has_positions\":false,\"chunkers\":[\"line-window-v1\"],"
            "\"source\":\"absent\"}";
        size_t golden_len = strlen(golden_status_json);
        char *expected = malloc(golden_len + strlen(tail) + 1);
        memcpy(expected, golden_status_json, golden_len - 1);
        strcpy(expected + golden_len - 1, tail);
        char *status_json = ss_status(handle);
        expect_streq("ss_status matches the captured index_status result, plus the 2.0.0 and 2.1.0 fields", expected, status_json);
        ss_free(status_json);
        free(expected);
    }

    float query_vector[2] = {1.0f, 0.0f};
    char *query_json = ss_query(
        handle,
        "hybrid ranking",
        query_vector,
        2,
        1,
        "{\"retrieval_mode\":\"hybrid\",\"path_prefix\":\"guides/\",\"candidate_k\":2}"
    );
    /* Contract 1.2.0 appends warnings/request (and profile on request) after
     * `answer_policy`: the captured JSON-RPC result is the report up to the
     * final brace, byte for byte, and the new keys are checked separately. */
    {
        static const char *tail =
            ",\"warnings\":[{\"code\":\"candidate_depth_cut\",\"message\":"
            "\"candidate_k 2 kept 2 of 3 vector candidates\"}],"
            "\"request\":{\"analyzer_id\":\"ascii-alnum-v1\","
            "\"retrieval_mode\":\"hybrid\",\"top_k\":1,\"candidate_k\":2,"
            "\"path_prefix\":\"guides/\"}}";
        size_t golden_len = strlen(golden_query_result_json);
        char *expected = malloc(golden_len + strlen(tail) + 1);
        memcpy(expected, golden_query_result_json, golden_len - 1);
        strcpy(expected + golden_len - 1, tail);
        expect_streq("ss_query matches the captured search_knowledge result byte for byte, plus warnings and request", expected, query_json);
        free(expected);
    }
    ss_free(query_json);

    {
        char *report = ss_query(handle, "hybrid dinosaurus", query_vector, 2, 1,
                                "{\"retrieval_mode\":\"lexical\",\"profile\":true}");
        expect_true("ss_query warns about an unmatched term",
                    report != NULL && strstr(report, "{\"code\":\"query_term_unmatched\",\"message\":\"the term was not found in the searched files\",\"term\":\"dinosaurus\"}") != NULL,
                    "missing query_term_unmatched");
        expect_true("ss_query warns that the vector was ignored in lexical mode",
                    report != NULL && strstr(report, "\"code\":\"vector_ignored\"") != NULL,
                    "missing vector_ignored");
        expect_true("ss_query adds profile only on request",
                    report != NULL && strstr(report, "\"profile\":{\"tokenize_us\":") != NULL
                       ,
                    "missing profile");
        ss_free(report);
    }

    {
        static const char *tail = ",\"root_id\":\"r-legacy\",\"section_path\":[],\"neighbours\":{\"prev\":null,\"next\":null}}]";
        size_t golden_len = strlen(golden_evidence_found_json);
        char *expected = malloc(golden_len + strlen(tail) + 1);
        memcpy(expected, golden_evidence_found_json, golden_len - 2);
        strcpy(expected + golden_len - 2, tail);
        char *evidence_found_json = ss_evidence(handle, "{\"ids\":[\"hybrid-guide\"]}");
        expect_streq("ss_evidence matches the captured read_chunk result, plus root_id, section_path, neighbours", expected, evidence_found_json);
        ss_free(evidence_found_json);
        free(expected);
    }

    char *evidence_missing_json = ss_evidence(handle, "{\"ids\":[\"missing-id\"]}");
    expect_streq("ss_evidence reports an unknown id as not found", golden_evidence_missing_json, evidence_missing_json);
    ss_free(evidence_missing_json);

    char *bad_query = ss_query(handle, "hybrid ranking", query_vector, 2, 0, NULL);
    expect_true("ss_query rejects top_k=0", bad_query == NULL, "expected NULL");

    char *bad_dims_query = ss_query(handle, "hybrid ranking", query_vector, 1, 1, NULL);
    expect_true("ss_query rejects a mismatched query_vector length", bad_dims_query == NULL, "expected NULL");

    /* S2-T11: query_text must be valid UTF-8, in every mode; rejected before analysis. */
    static const char *const bad_texts[] = {"caf\xff", "\xfe", "hybrid \x80", "\xc3"};
    static const char *const modes[] = {"{\"retrieval_mode\":\"lexical\"}", "{\"retrieval_mode\":\"vector\"}", NULL};
    int invalid_rejected = 1;
    for (size_t i = 0; i < sizeof bad_texts / sizeof bad_texts[0]; i++) {
        for (size_t m = 0; m < sizeof modes / sizeof modes[0]; m++) {
            char *invalid_query = ss_query(handle, bad_texts[i], query_vector, 2, 1, modes[m]);
            if (invalid_query != NULL || strstr(ss_last_error(), "query_text is not valid UTF-8") == NULL) {
                invalid_rejected = 0;
                ss_free(invalid_query);
            }
        }
    }
    expect_true("ss_query rejects query_text that is not valid UTF-8", invalid_rejected, "expected NULL and the UTF-8 message");

    /* ---- Contract 2.0.0: the six new functions (S3-T4) ------------------ */
    char why[1024];
    char folder_dir[4096];
    snprintf(folder_dir, sizeof folder_dir, "%s-folder", dir);
    {
        char *week64 = base64_of(week_md);
        char *long_text = malloc(450 * 12 + 1);
        long_text[0] = '\0';
        for (int line = 1; line <= 450; line++) {
            char one[16];
            snprintf(one, sizeof one, "line %d\n", line);
            strcat(long_text, one);
        }
        char *long64 = base64_of(long_text);
        size_t request_len = strlen(week64) + strlen(long64) + 512;
        char *request = malloc(request_len);
        snprintf(request, request_len,
                 "{\"roots\":[{\"root_id\":\"notes\",\"label\":\"Notes\",\"kind\":\"host\"}],\"changes\":["
                 "{\"op\":\"add\",\"root_id\":\"notes\",\"path\":\"week.md\",\"content_base64\":\"%s\"},"
                 "{\"op\":\"add\",\"root_id\":\"notes\",\"path\":\"long.txt\",\"content_base64\":\"%s\"},"
                 "{\"op\":\"pending\",\"root_id\":\"notes\",\"path\":\"later.md\",\"size\":12}]}",
                 week64, long64);
        static const char *const report_needles[] = {"\"generation\":1", "\"added\":2", "\"pending\":1", NULL};
        int ok = holds(ss_apply_changes(folder_dir, request, NULL), report_needles, why, sizeof why);
        ok = ok && refused(ss_apply_changes(folder_dir, "{\"expect_generation\":0,\"changes\":[]}", NULL), "SS_ERR_INVALID_ARGUMENT", "stale: generation is 1", why, sizeof why);
        ok = ok && refused(ss_apply_changes(folder_dir, "{\"changes\":[", NULL), "SS_ERR_INVALID_ARGUMENT", "ss_apply_changes", why, sizeof why);
        ok = ok && refused(ss_apply_changes(folder_dir, "{\"changes\":[],\"principal_labels\":[\"x\"]}", NULL), "SS_ERR_INVALID_ARGUMENT", "principal_labels", why, sizeof why);
        ok = ok && refused(ss_apply_changes(folder_dir, "{\"changes\":[]}", "{\"bogus\":1}"), "SS_ERR_INVALID_ARGUMENT", "unknown field", why, sizeof why);
        ok = ok && refused(ss_apply_changes(folder_dir, NULL, NULL), "SS_ERR_INVALID_ARGUMENT", "null changes_json", why, sizeof why);
        ok = ok && refused(ss_apply_changes(folder_dir, "{\"changes\":[{\"op\":\"add\",\"root_id\":\"notes\",\"path\":\"x.md\",\"file\":\"/x.md\",\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\"}]}", NULL),
                           "SS_ERR_INVALID_ARGUMENT", "file reads are not enabled", why, sizeof why);
        expect_true("ss_apply_changes publishes a host batch; stale generation, bad JSON, forged labels, unknown options, file reads off are refused", ok, why);
        free(week64);
        free(long_text);
        free(long64);
        free(request);
    }

    ss_handle *folder = ss_open(folder_dir);
    if (folder == NULL) {
        fprintf(stderr, "FAIL ss_open of the applied folder: %s\n", ss_last_error());
        failures++;
        checks++;
    } else {
        {
            static const char *const words[] = {"\"root_id\":\"notes\"", "\"path\":\"week.md\"", "\"section_path\":[\"Week 7\",\"Spelling\"]",
                                                "\"scope\":{\"roots\":[\"notes\"],\"labels_applied\":true}", "\"pending_files\":1", NULL};
            static const char *const phrase[] = {"\"exact_match\":true", "\"mode\":\"phrase\"", "\"section_path\":[\"Week 7\",\"Dates\"]", NULL};
            static const char *const paged[] = {"\"next_cursor\":\"1:1\"", NULL};
            int ok = holds(ss_find(folder, "{\"query\":\"harbour island\"}"), words, why, sizeof why);
            ok = ok && holds(ss_find(folder, "{\"query\":\"\\\"count me in\\\"\"}"), phrase, why, sizeof why);
            ok = ok && holds(ss_find(folder, "{\"query\":\"line\",\"page_size\":1}"), paged, why, sizeof why);
            ok = ok && refused(ss_find(folder, "{\"query\":\"line\",\"cursor\":\"7:1\"}"), "SS_ERR_INVALID_ARGUMENT", "stale cursor", why, sizeof why);
            ok = ok && refused(ss_find(folder, "{\"query\":\"line\",\"cursor\":\"x\"}"), "SS_ERR_INVALID_ARGUMENT", "malformed cursor", why, sizeof why);
            ok = ok && refused(ss_find(folder, "{\"query\":\"\"}"), "SS_ERR_INVALID_ARGUMENT", "empty query", why, sizeof why);
            ok = ok && refused(ss_find(folder, "{\"query\":\"x\",\"page_size\":101}"), "SS_ERR_INVALID_ARGUMENT", "page_size", why, sizeof why);
            ok = ok && refused(ss_find(folder, "{\"query\":\"x\",\"bogus\":true}"), "SS_ERR_INVALID_ARGUMENT", "unknown field", why, sizeof why);
            ok = ok && refused(ss_find(folder, NULL), "SS_ERR_INVALID_ARGUMENT", "query is required", why, sizeof why);
            ok = ok && refused(ss_find(NULL, "{\"query\":\"x\"}"), "SS_ERR_INVALID_ARGUMENT", "null handle", why, sizeof why);
            /* The demo snapshot (import-json, HYBLEX01) has no positions. */
            ok = ok && refused(ss_find(handle, "{\"query\":\"\\\"exact lexical\\\"\"}"), "SS_ERR_CAPACITY", "positions absent", why, sizeof why);
            expect_true("ss_find answers words, phrase and pages; stale/malformed cursor, empty query, page size, unknown field, missing query, NULL handle, absent positions are refused", ok, why);
        }
        {
            static const char *const outline[] = {
                "\"front_matter\":{\"start_line\":1,\"end_line\":3,\"fields\":{\"title\":\"Week 7\"}}",
                "\"headings\":[{\"level\":1,\"text\":\"Week 7\",\"line\":4,\"end_line\":10},{\"level\":2,\"text\":\"Spelling\",\"line\":6,\"end_line\":8}",
                "\"lines\":10,\"chunker\":\"md-section-v1\"", NULL};
            int ok = holds(ss_outline(folder, "{\"root_id\":\"notes\",\"path\":\"week.md\"}"), outline, why, sizeof why);
            ok = ok && refused(ss_outline(folder, "{\"root_id\":\"notes\",\"path\":\"nope.md\"}"), "SS_ERR_NOT_FOUND", "notes/nope.md", why, sizeof why);
            ok = ok && refused(ss_outline(folder, "{\"root_id\":\"nope\",\"path\":\"week.md\"}"), "SS_ERR_NOT_FOUND", "not indexed", why, sizeof why);
            ok = ok && refused(ss_outline(folder, "{\"path\":\"week.md\"}"), "SS_ERR_INVALID_ARGUMENT", "root_id is required", why, sizeof why);
            ok = ok && refused(ss_outline(handle, "{\"root_id\":\"r-legacy\",\"path\":\"guides/hybrid.md\"}"), "SS_ERR_CAPACITY", "source absent", why, sizeof why);
            expect_true("ss_outline gives headings and front matter; unknown path, unknown root, missing root_id, absent source are refused", ok, why);
        }
        {
            static const char *const span[] = {"\"text\":\"## Dates\\nBand concert: count me in, Friday 6.\\n\"", "\"context_before\":\"\\n\"",
                                               "\"context_after\":\"\"", "\"byte_exact\":true", "\"sha256\":\"", NULL};
            static const char *const clamped[] = {"\"code\":\"end_line_clamped\"", "\"end_line\":10", NULL};
            int ok = holds(ss_read_span(folder, "{\"root_id\":\"notes\",\"path\":\"week.md\",\"start_line\":9,\"end_line\":10,\"context_lines\":1}"), span, why, sizeof why);
            ok = ok && holds(ss_read_span(folder, "{\"root_id\":\"notes\",\"path\":\"week.md\",\"start_line\":9,\"end_line\":99}"), clamped, why, sizeof why);
            ok = ok && refused(ss_read_span(folder, "{\"root_id\":\"notes\",\"path\":\"long.txt\",\"start_line\":1,\"end_line\":401}"), "SS_ERR_CAPACITY", "401 lines", why, sizeof why);
            ok = ok && refused(ss_read_span(folder, "{\"root_id\":\"notes\",\"path\":\"week.md\",\"start_line\":1,\"end_line\":1,\"context_lines\":21}"), "SS_ERR_INVALID_ARGUMENT", "context_lines", why, sizeof why);
            ok = ok && refused(ss_read_span(folder, "{\"root_id\":\"notes\",\"path\":\"week.md\",\"start_line\":0,\"end_line\":1}"), "SS_ERR_INVALID_ARGUMENT", "start_line", why, sizeof why);
            ok = ok && refused(ss_read_span(folder, "{\"root_id\":\"notes\",\"path\":\"later.md\",\"start_line\":1,\"end_line\":1}"), "SS_ERR_NOT_FOUND", "notes/later.md", why, sizeof why);
            ok = ok && refused(ss_read_span(handle, "{\"root_id\":\"r-legacy\",\"path\":\"guides/hybrid.md\",\"start_line\":1,\"end_line\":1}"), "SS_ERR_CAPACITY", "source absent", why, sizeof why);
            expect_true("ss_read_span is byte exact with context and clamping; over 400 lines, context 21, line 0, a pending file, absent source are refused", ok, why);
        }
        {
            static const char *const all[] = {"{\"root_id\":\"notes\",\"path\":\"later.md\",\"size\":12,\"mtime_ms\":null,\"status\":\"pending\",\"chunks\":0,\"chunker\":null}",
                                              "{\"root_id\":\"notes\",\"path\":\"week.md\",\"size\":", "\"total\":3", "\"next_cursor\":null", NULL};
            static const char *const paged[] = {"\"path\":\"later.md\"", "\"next_cursor\":\"1:1\"", NULL};
            static const char *const pending[] = {"\"total\":1", NULL};
            int ok = holds(ss_list_files(folder, NULL), all, why, sizeof why);
            ok = ok && holds(ss_list_files(folder, "{\"page_size\":1}"), paged, why, sizeof why);
            ok = ok && holds(ss_list_files(folder, "{\"status\":\"pending\",\"root_id\":\"notes\"}"), pending, why, sizeof why);
            ok = ok && refused(ss_list_files(folder, "{\"cursor\":\"2:1\"}"), "SS_ERR_INVALID_ARGUMENT", "stale cursor", why, sizeof why);
            ok = ok && refused(ss_list_files(folder, "{\"status\":\"gone\"}"), "SS_ERR_INVALID_ARGUMENT", "status", why, sizeof why);
            ok = ok && refused(ss_list_files(folder, "{\"page_size\":0}"), "SS_ERR_INVALID_ARGUMENT", "page_size", why, sizeof why);
            ok = ok && refused(ss_list_files(NULL, NULL), "SS_ERR_INVALID_ARGUMENT", "null handle", why, sizeof why);
            expect_true("ss_list_files lists indexed and pending files with paging; stale cursor, bad status, page size 0, NULL handle are refused", ok, why);
        }
        {
            static const char *const all[] = {"\"roots\":[{\"root_id\":\"notes\",\"label\":\"Notes\",\"kind\":\"host\",\"files\":2,\"documents\":", "\"pending\":1}]", NULL};
            static const char *const none[] = {"\"scope\":{\"roots\":[],\"labels_applied\":true}", "\"roots\":[]}", NULL};
            static const char *const query_none[] = {"\"results\":[]", NULL};
            static const char *const query_some[] = {"\"path\":\"notes/week.md\"", NULL};
            static const char *const evidence_hidden[] = {"\"found\":false", NULL};
            int ok = holds(ss_roots(folder, NULL), all, why, sizeof why);
            ok = ok && holds(ss_roots(folder, "{\"roots\":[\"elsewhere\"]}"), none, why, sizeof why);
            ok = ok && refused(ss_roots(folder, "{\"roots\":\"notes\"}"), "SS_ERR_INVALID_ARGUMENT", "roots", why, sizeof why);
            ok = ok && refused(ss_roots(folder, "[1]"), "SS_ERR_INVALID_ARGUMENT", "JSON object", why, sizeof why);
            ok = ok && refused(ss_roots(NULL, NULL), "SS_ERR_INVALID_ARGUMENT", "null handle", why, sizeof why);
            /* roots in ss_query and ss_evidence (the scope, before candidates). */
            ok = ok && holds(ss_query(folder, "harbour", NULL, 0, 3, "{\"retrieval_mode\":\"lexical\",\"roots\":[\"elsewhere\"]}"), query_none, why, sizeof why);
            ok = ok && holds(ss_query(folder, "harbour", NULL, 0, 3, "{\"retrieval_mode\":\"lexical\",\"roots\":[\"notes\"]}"), query_some, why, sizeof why);
            char *found = ss_query(folder, "harbour", NULL, 0, 1, "{\"retrieval_mode\":\"lexical\"}");
            const char *id_at = found ? strstr(found, "\"chunk_id\":\"") : NULL;
            char evidence_request[256] = "";
            if (id_at != NULL) snprintf(evidence_request, sizeof evidence_request, "{\"ids\":[\"%.20s\"],\"roots\":[\"elsewhere\"]}", id_at + 12);
            ss_free(found);
            ok = ok && id_at != NULL && holds(ss_evidence(folder, evidence_request), evidence_hidden, why, sizeof why);
            ok = ok && refused(ss_evidence(folder, "{\"ids\":[],\"roots\":[1]}"), "SS_ERR_INVALID_ARGUMENT", "roots", why, sizeof why);
            expect_true("ss_roots counts the visible roots; roots narrows ss_roots, ss_query and ss_evidence; a bad roots, a non-object, NULL handle are refused", ok, why);
        }
        ss_close(folder);
    }

    ss_close(handle);

    /* Best-effort cleanup of the temporary snapshot directory. */
    char path[4096];
    const char *names[] = {"MANIFEST", "WRITER.LOCK", "documents-1.hybseg", "lexical-1.hyblex"};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        snprintf(path, sizeof(path), "%s/%s", dir, names[i]);
        remove(path);
    }
    rmdir(dir);
    const char *folder_names[] = {"MANIFEST", "WRITER.LOCK", "INDEX-STATE.json", "documents-1.hybseg", "lexical-1.hyblex", "source-1.hybsrc"};
    for (size_t i = 0; i < sizeof(folder_names) / sizeof(folder_names[0]); i++) {
        snprintf(path, sizeof(path), "%s/%s", folder_dir, folder_names[i]);
        remove(path);
    }
    rmdir(folder_dir);

    printf("abi_test: %d/%d checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
