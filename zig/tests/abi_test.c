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
 */

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

    expect_streq("ss_version", "1.0.0", ss_version());

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

    char *status_json = ss_status(handle);
    expect_streq("ss_status matches the captured index_status result", golden_status_json, status_json);
    ss_free(status_json);

    float query_vector[2] = {1.0f, 0.0f};
    char *query_json = ss_query(
        handle,
        "hybrid ranking",
        query_vector,
        2,
        1,
        "{\"retrieval_mode\":\"hybrid\",\"path_prefix\":\"guides/\",\"candidate_k\":2}"
    );
    expect_streq("ss_query matches the captured search_knowledge result byte for byte", golden_query_result_json, query_json);
    ss_free(query_json);

    char *evidence_found_json = ss_evidence(handle, "{\"ids\":[\"hybrid-guide\"]}");
    expect_streq("ss_evidence matches the captured read_chunk result", golden_evidence_found_json, evidence_found_json);
    ss_free(evidence_found_json);

    char *evidence_missing_json = ss_evidence(handle, "{\"ids\":[\"missing-id\"]}");
    expect_streq("ss_evidence reports an unknown id as not found", golden_evidence_missing_json, evidence_missing_json);
    ss_free(evidence_missing_json);

    char *bad_query = ss_query(handle, "hybrid ranking", query_vector, 2, 0, NULL);
    expect_true("ss_query rejects top_k=0", bad_query == NULL, "expected NULL");

    char *bad_dims_query = ss_query(handle, "hybrid ranking", query_vector, 1, 1, NULL);
    expect_true("ss_query rejects a mismatched query_vector length", bad_dims_query == NULL, "expected NULL");

    ss_close(handle);

    /* Best-effort cleanup of the temporary snapshot directory. */
    char path[4096];
    const char *names[] = {"MANIFEST", "WRITER.LOCK", "documents-1.hybseg", "lexical-1.hyblex"};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        snprintf(path, sizeof(path), "%s/%s", dir, names[i]);
        remove(path);
    }
    rmdir(dir);

    printf("abi_test: %d/%d checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
