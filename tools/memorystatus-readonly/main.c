/* Independent M1 diagnostic. No production/UI/policy headers are included.
 * ABI references: Apple XNU tags 8019.41.5, 8792.41.9, 10002.1.13,
 * 11215.1.10, bsd/sys/kern_memorystatus.h (see README and REPORT).
 */
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MEMORYSTATUS_CMD_GET_PRIORITY_LIST 1u
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 8u
#define MEMORYSTATUS_MEMLIMIT_ATTR_FATAL 1u
#define RO_PIDTBSDINFO 3
#define RO_PATH_SIZE 4096u

/* Only v1 is requested: GET returns 0, NOT a byte count. */
typedef struct {
    int32_t active;
    uint32_t active_attr;
    int32_t inactive;
    uint32_t inactive_attr;
} Limits;
/* GET with a positive PID returns exactly one 24-byte entry. */
typedef struct {
    int32_t pid;
    int32_t priority;
    uint64_t user_data;
    int32_t limit;
    uint32_t state;
} Priority;
/* Read-only subset of proc_bsdinfo; mirrors frozen libproc_internal.h.
 * Do not include that header: it also declares unrelated write-policy APIs.
 */
typedef struct {
    uint32_t flags, status, xstatus, pid, ppid;
    uint32_t uid, gid, ruid, rgid, svuid, svgid, rfu_1;
    char comm[16], name[32];
    uint32_t nfiles, pgid, pjobc, tdev, tpgid;
    int32_t nice;
    uint64_t start_sec, start_usec;
} BsdInfo;

_Static_assert(sizeof(int32_t) == 4 && sizeof(uint64_t) == 8, "integer ABI");
_Static_assert(sizeof(void *) == 8 && sizeof(size_t) == 8, "64-bit ABI only");
_Static_assert(sizeof(Limits) == 16 && _Alignof(Limits) == 4, "memlimit v1 ABI");
_Static_assert(offsetof(Limits, active) == 0, "active offset");
_Static_assert(offsetof(Limits, active_attr) == 4, "active attr offset");
_Static_assert(offsetof(Limits, inactive) == 8, "inactive offset");
_Static_assert(offsetof(Limits, inactive_attr) == 12, "inactive attr offset");
_Static_assert(sizeof(Priority) == 24 && _Alignof(Priority) == 8, "priority ABI");
_Static_assert(offsetof(Priority, pid) == 0, "priority pid offset");
_Static_assert(offsetof(Priority, priority) == 4, "priority band offset");
_Static_assert(offsetof(Priority, user_data) == 8, "user data offset");
_Static_assert(offsetof(Priority, limit) == 16, "priority limit offset");
_Static_assert(offsetof(Priority, state) == 20, "priority state offset");
_Static_assert(sizeof(BsdInfo) == 136 && _Alignof(BsdInfo) == 8, "bsdinfo ABI");
_Static_assert(offsetof(BsdInfo, pid) == 12, "bsdinfo pid offset");
_Static_assert(offsetof(BsdInfo, start_sec) == 120, "start seconds offset");
_Static_assert(offsetof(BsdInfo, start_usec) == 128, "start useconds offset");

#if defined(VDT_READONLY_FAKE)
/* Compile-time fixture only; no runtime choice of backend in device builds. */
#include "tests/fixtures/fake_backend.inc"
#elif defined(__APPLE__)
#include <sys/sysctl.h>
#include <TargetConditionals.h>
/* External OS declarations are not a caller-selectable command wrapper. */
extern int memorystatus_control(uint32_t, int32_t, uint32_t, void *, size_t);
extern int proc_pidinfo(int, int, uint64_t, void *, int);
extern int proc_pidpath(int, void *, uint32_t);
static int backend_limits(int32_t pid, Limits *out) {
    return memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,
                               pid, 0, out, sizeof(*out));
}
static int backend_priority(int32_t pid, Priority *out) {
    return memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST,
                               pid, 0, out, sizeof(*out));
}
static int backend_info(int32_t pid, BsdInfo *out) {
    return proc_pidinfo(pid, RO_PIDTBSDINFO, 0, out, (int)sizeof(*out));
}
static int backend_path(int32_t pid, char *out) {
    return proc_pidpath(pid, out, RO_PATH_SIZE);
}
static int backend_version(const char *name, char *out, size_t *size) {
    return sysctlbyname(name, out, size, NULL, 0);
}
static bool backend_abi_supported(void) {
#if (defined(__arm64__) || defined(__aarch64__)) && TARGET_OS_IPHONE && \
    !TARGET_OS_SIMULATOR && !TARGET_OS_MACCATALYST
    return true;
#else
    return false;
#endif
}
static unsigned backend_euid(void) { return (unsigned)geteuid(); }
static const char *backend_source(void) { return "device_runtime_read"; }
static void backend_finish(void) {}
#else
/* Host build never reads iSH as though it were a phone, or links Apple APIs. */
static int backend_limits(int32_t pid, Limits *out) {
    (void)pid; (void)out; errno = ENOTSUP; return -1;
}
static int backend_priority(int32_t pid, Priority *out) {
    (void)pid; (void)out; errno = ENOTSUP; return -1;
}
static int backend_info(int32_t pid, BsdInfo *out) {
    (void)pid; (void)out; errno = ENOTSUP; return -1;
}
static int backend_path(int32_t pid, char *out) {
    (void)pid; (void)out; errno = ENOTSUP; return -1;
}
static int backend_version(const char *name, char *out, size_t *size) {
    (void)name; (void)out; (void)size; errno = ENOTSUP; return -1;
}
static bool backend_abi_supported(void) { return false; }
static unsigned backend_euid(void) { return (unsigned)geteuid(); }
static const char *backend_source(void) { return "unsupported_host_no_phone_evidence"; }
static void backend_finish(void) {}
#endif

/* Capture errno immediately after every call, including failed/partial reads.
 * errno is reset BEFORE each call; never reset after failure. On successful
 * calls it is diagnostic only (POSIX does not define success errno).
 */
typedef struct { bool attempted; int result, saved_errno; } Call;
typedef struct { Call call; char text[512]; bool valid; } Version;
typedef struct {
    Call info_call, path_call;
    uint32_t pid;
    uint64_t sec, usec;
    char path[RO_PATH_SIZE];
    bool token_valid, path_valid;
} Identity;
typedef struct {
    int darwin, ios, max_band;
    const char *xnu, *header_url;
} Reference;
static const Reference references[] = {
    {21, 15, 21, "8019.41.5", "https://github.com/apple-oss-distributions/xnu/blob/xnu-8019.41.5/bsd/sys/kern_memorystatus.h"},
    {22, 16, 210, "8792.41.9", "https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.41.9/bsd/sys/kern_memorystatus.h"},
    {23, 17, 210, "10002.1.13", "https://github.com/apple-oss-distributions/xnu/blob/xnu-10002.1.13/bsd/sys/kern_memorystatus.h"},
    {24, 18, 210, "11215.1.10", "https://github.com/apple-oss-distributions/xnu/blob/xnu-11215.1.10/bsd/sys/kern_memorystatus.h"}
};

static Version read_version(const char *name) {
    Version v = {0};
    size_t size = sizeof(v.text);
    memset(v.text, 0xff, sizeof(v.text));
    errno = 0;
    int rc = backend_version(name, v.text, &size);
    int err = errno;
    v.call = (Call){true, rc, err};
    v.valid = rc == 0 && size > 1 && size <= sizeof(v.text) &&
              v.text[0] != '\0' && memchr(v.text, '\0', size) != NULL;
    if (!v.valid) v.text[0] = '\0';
    return v;
}

static Identity read_identity(int32_t pid) {
    Identity i = {0};
    BsdInfo b = {0};
    errno = 0;
    int rc = backend_info(pid, &b);
    int err = errno;
    i.info_call = (Call){true, rc, err};
    if (rc == (int)sizeof(b)) {
        i.pid = b.pid; i.sec = b.start_sec; i.usec = b.start_usec;
        i.token_valid = b.pid == (uint32_t)pid &&
            (b.start_sec != 0 || b.start_usec != 0) && b.start_usec < 1000000;
    }
    memset(i.path, 0xff, sizeof(i.path));
    errno = 0;
    rc = backend_path(pid, i.path);
    err = errno;
    i.path_call = (Call){true, rc, err};
    i.path_valid = rc > 0 && rc < (int)sizeof(i.path) && i.path[0] == '/' &&
        memchr(i.path, '\0', sizeof(i.path)) != NULL;
    if (!i.path_valid) i.path[0] = '\0';
    return i;
}
static bool identity_valid(const Identity *i) { return i->token_valid && i->path_valid; }
static bool identity_same(const Identity *a, const Identity *b) {
    return identity_valid(a) && identity_valid(b) && a->pid == b->pid &&
        a->sec == b->sec && a->usec == b->usec && strcmp(a->path, b->path) == 0;
}
/* Different valid tokens/paths prove instability; unreadable identity is unknown. */
static bool identity_changed(const Identity *a, const Identity *b) {
    return (a->token_valid && b->token_valid &&
            (a->pid != b->pid || a->sec != b->sec || a->usec != b->usec)) ||
        (a->path_valid && b->path_valid && strcmp(a->path, b->path) != 0);
}

/* Strict version/PID parsing: no CLI version override or host inference. */
static int version_major(const char *s) {
    int major = 0, parts = 0;
    while (*s) {
        int value = 0, digits = 0;
        while (*s >= '0' && *s <= '9') {
            if (value > (INT_MAX - (*s - '0')) / 10) return -1;
            value = value * 10 + (*s++ - '0'); digits++;
        }
        if (!digits || ++parts > 3) return -1;
        if (parts == 1) major = value;
        if (!*s) return major;
        if (*s++ != '.' || !*s) return -1;
    }
    return -1;
}
static const Reference *find_reference(const Version *type, const Version *release,
                                       const Version *product, const Version *kernel) {
    if (!type->valid || !release->valid || !product->valid || !kernel->valid ||
        strcmp(type->text, "Darwin") != 0) return NULL;
    int darwin = version_major(release->text), ios = version_major(product->text);
    const char *prefix = "Darwin Kernel Version ";
    if (strncmp(kernel->text, prefix, strlen(prefix)) != 0) return NULL;
    const char *kv = kernel->text + strlen(prefix);
    char expected_major[16];
    snprintf(expected_major, sizeof(expected_major), "%d.", darwin);
    if (strncmp(kv, expected_major, strlen(expected_major)) != 0) return NULL;
    const char *xnu = strstr(kv, "xnu-");
    if (!xnu) return NULL;
    xnu += 4;
    for (size_t n = 0; n < sizeof(references) / sizeof(references[0]); n++) {
        const Reference *r = &references[n];
        size_t size = strlen(r->xnu);
        if (darwin == r->darwin && ios == r->ios &&
            strncmp(xnu, r->xnu, size) == 0 &&
            (xnu[size] == '~' || xnu[size] == '/' || xnu[size] == ' ' || !xnu[size]))
            return r;
    }
    return NULL;
}
static bool parse_pid(const char *s, int32_t *pid) {
    uint32_t value = 0;
    if (!s || !*s) return false;
    for (; *s; s++) {
        if (*s < '0' || *s > '9' || value > (INT32_MAX - (uint32_t)(*s - '0')) / 10u)
            return false;
        value = value * 10u + (uint32_t)(*s - '0');
    }
    if (!value) return false;
    *pid = (int32_t)value;
    return true;
}

/* ASCII JSON, preserving valid UTF-8 as codepoints. Invalid UTF-8 bytes are
 * escaped individually as U+00xx, never emitted as invalid JSON text.
 */
static void json_string(const char *s) {
    if (!s) { fputs("null", stdout); return; }
    putchar('"');
    const unsigned char *p = (const unsigned char *)s;
    size_t size = strlen(s);
    for (size_t i = 0; i < size; i++) {
        unsigned c = p[i];
        if (c == '"' || c == '\\') { putchar('\\'); putchar((int)c); }
        else if (c >= 0x20 && c < 0x7f) putchar((int)c);
        else if (c < 0x80) printf("\\u%04x", c);
        else {
            size_t count = c >= 0xc2 && c <= 0xdf ? 2u :
                c >= 0xe0 && c <= 0xef ? 3u : c >= 0xf0 && c <= 0xf4 ? 4u : 0u;
            unsigned cp = count ? c & ((1u << (7u - count)) - 1u) : c;
            bool valid = count && i + count <= size;
            for (size_t j = 1; valid && j < count; j++) {
                valid = (p[i + j] & 0xc0u) == 0x80u;
                cp = (cp << 6u) | (p[i + j] & 0x3fu);
            }
            valid = valid && !(count == 3 && cp < 0x800) &&
                !(count == 4 && cp < 0x10000) && cp <= 0x10ffff &&
                !(cp >= 0xd800 && cp <= 0xdfff);
            if (!valid) printf("\\u%04x", c);
            else {
                if (cp < 0x10000) printf("\\u%04x", cp);
                else {
                    cp -= 0x10000;
                    printf("\\u%04x\\u%04x", 0xd800u + (cp >> 10u), 0xdc00u + (cp & 0x3ffu));
                }
                i += count - 1u;
            }
        }
    }
    putchar('"');
}
static void json_bool(bool v) { fputs(v ? "true" : "false", stdout); }
static void json_int(bool valid, int64_t v) {
    if (valid) printf("%" PRId64, v); else fputs("null", stdout);
}
static void json_hex(bool valid, uint64_t v) {
    if (valid) printf("\"0x%016" PRIx64 "\"", v); else fputs("null", stdout);
}
static void print_call(const Call *c) {
    fputs("{\"attempted\":", stdout); json_bool(c->attempted);
    fputs(",\"raw_return\":", stdout); json_int(c->attempted, c->result);
    fputs(",\"errno\":", stdout); json_int(c->attempted, c->saved_errno);
    fputs(",\"errno_text\":", stdout);
    json_string(c->attempted ? strerror(c->saved_errno) : NULL);
    putchar('}');
}
static void print_version(const Version *v) {
    fputs("{\"value\":", stdout); json_string(v->valid ? v->text : NULL);
    fputs(",\"valid\":", stdout); json_bool(v->valid);
    fputs(",\"call\":", stdout); print_call(&v->call); putchar('}');
}
static void print_identity(const Identity *i) {
    fputs("{\"complete\":", stdout); json_bool(identity_valid(i));
    fputs(",\"observed_pid\":", stdout);
    json_int(i->info_call.result == (int)sizeof(BsdInfo), i->pid);
    fputs(",\"start_seconds\":", stdout); json_int(i->token_valid, (int64_t)i->sec);
    fputs(",\"start_microseconds\":", stdout); json_int(i->token_valid, (int64_t)i->usec);
    fputs(",\"path\":", stdout); json_string(i->path_valid ? i->path : NULL);
    fputs(",\"bsdinfo_call\":", stdout); print_call(&i->info_call);
    fputs(",\"path_call\":", stdout); print_call(&i->path_call); putchar('}');
}
static void print_identity_state(bool stable, bool unstable) {
    if (unstable) json_string("unstable");
    else if (stable) json_string("stable_observed_not_atomic");
    else json_string("unknown");
}
static const char *confidence(bool valid, bool stable, bool unstable) {
    if (!valid) return "unknown_read_unavailable";
    if (unstable) return "unattributed_identity_unstable";
    return stable ? "source_read_identity_stable_nonatomic" : "unattributed_identity_unknown";
}
static void print_limit_fields(bool available, int32_t value, uint32_t attr) {
    fputs("{\"mib\":", stdout); json_int(available && value > 0, value);
    fputs(",\"fatal\":", stdout);
    if (available) json_bool((attr & MEMORYSTATUS_MEMLIMIT_ATTR_FATAL) != 0);
    else fputs("null", stdout);
    fputs(",\"flags\":", stdout); json_int(available, attr);
    fputs(",\"unknown_flag_bits\":", stdout);
    json_int(available, attr & ~MEMORYSTATUS_MEMLIMIT_ATTR_FATAL);
    fputs(",\"interpretation\":", stdout);
    json_string(!available ? "unknown" : value > 0 ? "positive_mib_readback" : "nonpositive_readback_unknown");
    putchar('}');
}
static void print_limits(const Call *c, const Limits *l, const char *status,
                         bool valid, bool stable, bool unstable) {
    fputs("{\"command\":\"GET_MEMLIMIT_PROPERTIES\",\"buffer_size\":16,\"status\":", stdout);
    json_string(status); fputs(",\"call\":", stdout); print_call(c);
    fputs(",\"source_confidence\":", stdout); json_string(confidence(valid, stable, unstable));
    fputs(",\"raw_observation\":{\"active\":", stdout); json_int(valid, l->active);
    fputs(",\"active_attr\":", stdout); json_int(valid, l->active_attr);
    fputs(",\"inactive\":", stdout); json_int(valid, l->inactive);
    fputs(",\"inactive_attr\":", stdout); json_int(valid, l->inactive_attr);
    fputs("},\"active\":", stdout); print_limit_fields(valid && stable, l->active, l->active_attr);
    fputs(",\"inactive\":", stdout); print_limit_fields(valid && stable, l->inactive, l->inactive_attr);
    fputs(",\"default_sentinel\":null,\"original_mode\":\"unknown_GET_normalizes_default_sentinel\"}", stdout);
}
static void print_priority(const Call *c, const Priority *p, const char *status,
                           bool valid, bool stable, bool unstable) {
    fputs("{\"command\":\"GET_PRIORITY_LIST_single_pid\",\"buffer_size\":24,\"status\":", stdout);
    json_string(status); fputs(",\"call\":", stdout); print_call(c);
    fputs(",\"source_confidence\":", stdout); json_string(confidence(valid, stable, unstable));
    fputs(",\"raw_observation\":{\"pid\":", stdout); json_int(valid, p->pid);
    fputs(",\"effective_band\":", stdout); json_int(valid, p->priority);
    fputs(",\"user_data\":", stdout); json_hex(valid, p->user_data);
    fputs(",\"limit\":", stdout); json_int(valid, p->limit);
    fputs(",\"state_flags\":", stdout); json_int(valid, p->state);
    fputs("},\"effective_band\":", stdout); json_int(valid && stable, p->priority);
    fputs(",\"user_data\":", stdout); json_hex(valid && stable, p->user_data);
    fputs(",\"selected_limit_mib\":", stdout); json_int(valid && stable && p->limit > 0, p->limit);
    fputs(",\"requested_priority\":null,\"assertion_priority\":null,\"requested_priority_source\":\"not_exposed_by_GET\"}", stdout);
}

static void usage(FILE *out) {
    fputs("Usage: memorystatus-readonly PID\n"
          "       memorystatus-readonly --help\n"
          "One explicit positive decimal PID only; JSON to stdout.\n"
          "Only two GET operations, no writes, no process enumeration.\n"
          "Unknown runtime OS/kernel/ABI: metadata only (exit 1).\n"
          "Readbacks do not expose default mode or requested priority.\n"
          "Identity checks are not CAS/atomic; active is not foreground.\n"
          "Manual device use requires separate explicit authorization.\n", out);
}
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--help") == 0) { usage(stdout); return 0; }
    int32_t pid = 0;
    if (argc != 2 || !parse_pid(argv[1], &pid)) { usage(stderr); return 2; }
    Version type = read_version("kern.ostype");
    Version release = read_version("kern.osrelease");
    Version product = read_version("kern.osproductversion");
    Version kernel = read_version("kern.version");
    const Reference *ref = find_reference(&type, &release, &product, &kernel);
    bool supported = backend_abi_supported() && ref != NULL;
    /* euid is informational only: entitlement/MACF may allow or reject GET. */
    unsigned euid = backend_euid();
    Identity before = read_identity(pid), between = before, after;
    Limits limits = {0}; Priority priority = {0};
    Call limits_call = {0}, priority_call = {0};
    bool limits_valid = false, priority_valid = false, returned_pid_mismatch = false;
    const char *limits_status = "skipped_unknown_kernel_or_abi";
    const char *priority_status = "skipped_unknown_kernel_or_abi";
    if (supported) {
        limits_status = "skipped_identity_unknown";
        priority_status = "skipped_identity_unknown_or_changed";
        if (identity_valid(&before)) {
            errno = 0;
            int rc = backend_limits(pid, &limits);
            int err = errno;
            limits_call = (Call){true, rc, err};
            limits_valid = rc == 0;
            limits_status = rc < 0 ? "syscall_failed" : limits_valid ? "read_success" : "invalid_return";
            between = read_identity(pid);
        }
        /* The shared boundary is the post-memlimit/pre-priority identity read. */
        if (identity_same(&before, &between)) {
            errno = 0;
            int rc = backend_priority(pid, &priority);
            int err = errno;
            priority_call = (Call){true, rc, err};
            returned_pid_mismatch = rc == (int)sizeof(Priority) && priority.pid != pid;
            priority_valid = rc == (int)sizeof(Priority) && priority.pid == pid;
            priority_status = rc < 0 ? "syscall_failed" : returned_pid_mismatch ?
                "returned_pid_mismatch" : priority_valid ? "read_success" : "invalid_return";
        }
    }
    after = read_identity(pid);
    bool unstable = returned_pid_mismatch || identity_changed(&before, &between) ||
        identity_changed(&between, &after) || identity_changed(&before, &after);
    bool stable = !unstable && identity_same(&before, &between) && identity_same(&between, &after);
    bool complete = supported && stable && limits_valid && priority_valid;

    fputs("{\"schema\":1,\"pid\":", stdout); printf("%" PRId32, pid);
    fputs(",\"read_only\":true,\"provenance\":", stdout); json_string(backend_source());
    fputs(",\"version_source\":\"runtime_backend_sysctl_only_no_host_inference\",\"versions\":{\"kern.ostype\":", stdout);
    print_version(&type); fputs(",\"kern.osrelease\":", stdout); print_version(&release);
    fputs(",\"kern.osproductversion\":", stdout); print_version(&product);
    fputs(",\"kern.version\":", stdout); print_version(&kernel);
    fputs("},\"abi_gate\":{\"allowed\":", stdout); json_bool(supported);
    fputs(",\"reason\":", stdout);
    json_string(supported ? "matched_pinned_source_reference_and_mobile_arm64_abi" : "unknown_os_kernel_or_abi_metadata_only");
    fputs(",\"reference_xnu\":", stdout); json_string(ref ? ref->xnu : NULL);
    fputs(",\"reference_header_url\":", stdout); json_string(ref ? ref->header_url : NULL);
    fputs(",\"darwin_major\":", stdout); json_int(ref != NULL, ref ? ref->darwin : 0);
    fputs(",\"ios_major\":", stdout); json_int(ref != NULL, ref ? ref->ios : 0);
    fputs(",\"reference_max_band\":", stdout); json_int(ref != NULL, ref ? ref->max_band : 0);
    fputs(",\"runtime_patch_verified\":false},\"permission\":{\"euid\":", stdout); printf("%u", euid);
    fputs(",\"is_root\":", stdout); json_bool(euid == 0);
    fputs(",\"actual_authorization\":\"see_each_GET_return_and_errno_not_inferred_from_root\"},\"identity\":{\"status\":", stdout);
    print_identity_state(stable, unstable);
    fputs(",\"stable\":", stdout); if (stable || unstable) json_bool(stable); else fputs("null", stdout);
    fputs(",\"before\":", stdout); print_identity(&before);
    fputs(",\"between\":", stdout); print_identity(&between);
    fputs(",\"after\":", stdout); print_identity(&after);
    fputs(",\"boundary_reused_when_memlimit_skipped\":", stdout); json_bool(!limits_call.attempted);
    fputs(",\"atomic_binding\":false},\"memlimit\":", stdout);
    print_limits(&limits_call, &limits, limits_status, limits_valid, stable, unstable);
    fputs(",\"priority\":", stdout);
    print_priority(&priority_call, &priority, priority_status, priority_valid, stable, unstable);
    fputs(",\"complete_observation\":", stdout); json_bool(complete);
    fputs(",\"atomic_snapshot\":false,\"stable_effective_policy\":null,\"restoration_source\":\"unknown\","
          "\"active_state_semantics\":\"kernel_active_not_equivalent_to_foreground\","
          "\"text_encoding\":\"UTF8_codepoints_invalid_bytes_as_U00xx\","
          "\"errno_semantics\":\"reset_before_call_captured_immediately_failure_authoritative\"}\n", stdout);
    backend_finish();
    if (ferror(stdout)) return 3;
    return complete ? 0 : 1;
}
