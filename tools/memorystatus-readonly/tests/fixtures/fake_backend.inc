/* Isolated host fixture. Not linked unless VDT_READONLY_FAKE is defined.
 * Supplies synthetic Apple values; never calls sysctl/proc/syscall on host.
 */
static unsigned fake_limits_calls, fake_priority_calls, fake_info_calls, fake_path_calls;
static const char *fake_case(void) {
    const char *s = getenv("VDT_MOCK_CASE");
    return s ? s : "success16";
}
static bool fake_is(const char *s) { return strcmp(fake_case(), s) == 0; }
static bool backend_abi_supported(void) { return !fake_is("unknown_abi"); }
static unsigned backend_euid(void) { return fake_is("nonroot_success") ? 501u : 0u; }
static const char *backend_source(void) { return "host_mock_no_device_evidence"; }
static void backend_finish(void) {
    fprintf(stderr, "FAKE limits=%u priority=%u info=%u path=%u\n", fake_limits_calls,
            fake_priority_calls, fake_info_calls, fake_path_calls);
}
static int backend_version(const char *name, char *out, size_t *size) {
    int darwin = 22, ios = 16;
    const char *xnu = "8792.41.9";
    if (fake_is("success15")) { darwin = 21; ios = 15; xnu = "8019.41.5"; }
    if (fake_is("success17")) { darwin = 23; ios = 17; xnu = "10002.1.13"; }
    if (fake_is("success18")) { darwin = 24; ios = 18; xnu = "11215.1.10"; }
    if (fake_is("unknown_darwin")) { darwin = 25; ios = 19; xnu = "99999.1.1"; }
    if (fake_is("unknown_kernel")) xnu = "8796.121.2";
    if (fake_is("xnu_prefix_collision")) xnu = "8792.41.90";
    if (fake_is("os_mismatch")) ios = 15;
    if (fake_is("sysctl_fail") && strcmp(name, "kern.osproductversion") == 0) {
        memcpy(out, "18.0", 5); errno = ENOENT; return -1;
    }
    char value[512];
    if (strcmp(name, "kern.ostype") == 0) snprintf(value, sizeof(value), "%s", "Darwin");
    else if (strcmp(name, "kern.osrelease") == 0) snprintf(value, sizeof(value), "%d.1.0", darwin);
    else if (strcmp(name, "kern.osproductversion") == 0) snprintf(value, sizeof(value), "%d.1", ios);
    else if (strcmp(name, "kern.version") == 0)
        snprintf(value, sizeof(value), "Darwin Kernel Version %d.1.0: fixture; root:xnu-%s~1/RELEASE_ARM64_T0000", darwin, xnu);
    else { errno = ENOENT; return -1; }
    if (fake_is("malformed_version") && strcmp(name, "kern.osrelease") == 0)
        snprintf(value, sizeof(value), "%s", "22.1oops");
    if (fake_is("kernel_version_mismatch") && strcmp(name, "kern.version") == 0)
        snprintf(value, sizeof(value), "%s", "Darwin Kernel Version 23.1.0: root:xnu-8792.41.9~1/RELEASE_ARM64");
    if (fake_is("sysctl_partial") && strcmp(name, "kern.osrelease") == 0) {
        memcpy(out, "22.1.0", 6); *size = 6; return 0; /* deliberately no NUL */
    }
    if (fake_is("sysctl_oversize") && strcmp(name, "kern.osrelease") == 0) {
        *size = 1024; return 0;
    }
    size_t length = strlen(value) + 1;
    if (*size < length) { errno = ENOMEM; return -1; }
    memcpy(out, value, length); *size = length;
    return 0;
}
static int backend_info(int32_t pid, BsdInfo *out) {
    unsigned index = fake_info_calls++;
    *out = (BsdInfo){0};
    out->pid = (uint32_t)pid;
    out->start_sec = 1000; out->start_usec = 200;
    if (fake_is("info_fail") || (fake_is("info_fail_after") && index == 2)) {
        errno = ESRCH; return -1;
    }
    if (fake_is("info_partial")) return (int)sizeof(*out) - 8;
    if (fake_is("info_pid_mismatch")) out->pid++;
    if (fake_is("zero_start")) out->start_sec = out->start_usec = 0;
    if (fake_is("bad_microseconds")) out->start_usec = 1000000;
    if (fake_is("pid_reuse_between") && index >= 1) out->start_sec++;
    if (fake_is("pid_reuse_after") && index == 2) out->start_sec++;
    errno = EBUSY; /* subsequent identity reads must not clobber GET errno */
    return (int)sizeof(*out);
}
static int backend_path(int32_t pid, char *out) {
    (void)pid;
    unsigned index = fake_path_calls++;
    if (fake_is("path_fail") || (fake_is("path_fail_after") && index == 2)) {
        memcpy(out, "/stale/path", 12); errno = EACCES; return -1;
    }
    if (fake_is("path_partial")) { memcpy(out, "/partial", 8); return 8; }
    if (fake_is("path_unterminated")) { memset(out, 'X', RO_PATH_SIZE); return (int)RO_PATH_SIZE; }
    const char *path = "/Applications/Fixture.app/Fixture";
    if (fake_is("path_changed") && index >= 1) path = "/Applications/OtherFixture.app/OtherFixture";
    if (fake_is("json_escape"))
        path = "/fixture/quote\"\\slash\n\r\t\001/\xc3\xa9/\xe4\xb8\xad/\xf0\x9f\x98\x80/\xff";
    size_t length = strlen(path);
    memcpy(out, path, length + 1);
    errno = EINTR;
    return (int)length;
}
static int backend_limits(int32_t pid, Limits *out) {
    if (pid <= 0) abort(); /* prohibit bulk/non-explicit PID even in fixture */
    fake_limits_calls++;
    *out = (Limits){512, 1, 128, 0};
    if (fake_is("all_eperm") || fake_is("mem_eperm")) { errno = EPERM; return -1; }
    if (fake_is("all_esrch")) { errno = ESRCH; return -1; }
    if (fake_is("all_einval")) { errno = EINVAL; return -1; }
    if (fake_is("mem_partial_return")) return 8;
    if (fake_is("mem_copyout_fail")) { out->inactive = 999; errno = EFAULT; return -1; }
    if (fake_is("nonpositive_limits")) { out->active = 0; out->inactive = -1; }
    if (fake_is("unknown_flags")) out->active_attr = 5;
    return 0;
}
static int backend_priority(int32_t pid, Priority *out) {
    if (pid <= 0) abort();
    fake_priority_calls++;
    *out = (Priority){pid, 100, UINT64_C(0xfedcba9876543210), 512, 3};
    if (fake_is("success15")) out->priority = 10;
    if (fake_is("all_eperm") || fake_is("priority_eperm")) { errno = EPERM; return -1; }
    if (fake_is("all_esrch")) { errno = ESRCH; return -1; }
    if (fake_is("all_einval")) { errno = EINVAL; return -1; }
    if (fake_is("priority_partial_return")) return 16;
    if (fake_is("priority_zero_return")) return 0;
    if (fake_is("priority_copyout_fail")) { out->priority = 210; errno = EFAULT; return -1; }
    if (fake_is("priority_pid_mismatch")) out->pid++;
    if (fake_is("idle_band")) out->priority = 0;
    if (fake_is("freezer_band")) out->priority = 75;
    return (int)sizeof(*out);
}
