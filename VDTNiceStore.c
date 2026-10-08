// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#else
#define _POSIX_C_SOURCE 200809L
#endif
#include "VDTNiceStore.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int knownName(const char *name) {
    return name && (!strcmp(name, VDT_NICE_JOURNAL) ||
        !strcmp(name, VDT_NICE_STATUS) || !strcmp(name, VDT_NICE_REQUEST));
}
static mode_t expectedMode(const char *name) { return !strcmp(name, VDT_NICE_STATUS) ? 0644 : 0600; }
static int safeDirectory(const struct stat *s) {
    return S_ISDIR(s->st_mode) && s->st_uid == 0 && !(s->st_mode & 0022);
}
static int safeFile(const struct stat *s, const char *name) {
    return S_ISREG(s->st_mode) && s->st_uid == 0 && s->st_nlink == 1 &&
        (s->st_mode & 07777) == expectedMode(name) && s->st_size >= 0 &&
        (uintmax_t)s->st_size <= VDT_NICE_STORE_LIMIT;
}
static int sameNode(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}
// The held descriptors and the current pathname must still reach the same
// directory. This is a guard, not a filesystem-wide topology lock.
static int currentDirectory(VDTNiceStore *store) {
    if (!store || store->directoryFD < 0 || store->parentFD < 0) return EINVAL;
    struct stat parent, reopened, held, named;
    if (fstat(store->parentFD, &parent) || fstat(store->directoryFD, &held)) return errno;
    int fd = open(store->parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno;
    int error = fstat(fd, &reopened) ? errno : 0;
    close(fd);
    if (error) return error;
    if (!sameNode(&parent, &reopened) || !safeDirectory(&held)) return ESTALE;
    if (fstatat(store->parentFD, store->leaf, &named, AT_SYMLINK_NOFOLLOW)) return errno;
    return safeDirectory(&named) && sameNode(&held, &named) ? 0 : ESTALE;
}
void VDTNiceStoreClose(VDTNiceStore *store) {
    if (!store) return;
    if (store->directoryFD >= 0) close(store->directoryFD);
    if (store->parentFD >= 0) close(store->parentFD);
    free(store->parentPath); free(store->leaf);
    *store = (VDTNiceStore){.parentFD = -1, .directoryFD = -1};
}
int VDTNiceStoreOpen(const char *path, int create, VDTNiceStore *store) {
    if (!store) return EINVAL;
    *store = (VDTNiceStore){.parentFD = -1, .directoryFD = -1};
    if (!path || path[0] != '/' || strlen(path) > 4096) return EINVAL;
    char *copy = strdup(path);
    if (!copy) return ENOMEM;
    char *slash = strrchr(copy, '/');
    if (!slash || !slash[1] || !strcmp(slash + 1, ".") || !strcmp(slash + 1, "..")) {
        free(copy); return EINVAL;
    }
    store->leaf = strdup(slash + 1);
    if (slash == copy) slash[1] = 0; else *slash = 0;
    store->parentPath = copy;
    if (!store->leaf) { VDTNiceStoreClose(store); return ENOMEM; }
    int error = 0;
    store->parentFD = open(copy, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (store->parentFD < 0) { error = errno; goto fail; }
    struct stat parent;
    if (fstat(store->parentFD, &parent)) { error = errno; goto fail; }
    if (!S_ISDIR(parent.st_mode) || parent.st_uid != 0 ||
        ((parent.st_mode & 0022) && !(parent.st_mode & 01000))) { error = EPERM; goto fail; }
    if (create && mkdirat(store->parentFD, store->leaf, 0755) && errno != EEXIST) {
        error = errno; goto fail;
    }
    store->directoryFD = openat(store->parentFD, store->leaf,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (store->directoryFD < 0) { error = errno; goto fail; }
    error = currentDirectory(store);
    if (error) goto fail;
    return 0;
fail:
    VDTNiceStoreClose(store); return error;
}
int VDTNiceStoreRead(VDTNiceStore *store, const char *name, void **bytes, size_t *length) {
    if (!knownName(name) || !bytes || !length) return EINVAL;
    *bytes = NULL; *length = 0;
    int error = currentDirectory(store);
    if (error) return error;
    int fd = openat(store->directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return errno;
    struct stat before, after;
    if (fstat(fd, &before)) { error = errno; goto done; }
    if (!safeFile(&before, name)) { error = EPERM; goto done; }
    size_t count = (size_t)before.st_size;
    unsigned char *data = malloc(count ? count : 1);
    if (!data) { error = ENOMEM; goto done; }
    size_t used = 0;
    while (used < count) {
        ssize_t n = read(fd, data + used, count - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { error = n < 0 ? errno : EIO; break; }
        used += (size_t)n;
    }
    unsigned char extra;
    if (!error) {
        ssize_t n; do { n = read(fd, &extra, 1); } while (n < 0 && errno == EINTR);
        if (n != 0) error = n < 0 ? errno : EFBIG;
    }
    if (!error && fstat(fd, &after)) error = errno;
    if (!error && (!safeFile(&after, name) || !sameNode(&before, &after) ||
        before.st_size != after.st_size || before.st_mtime != after.st_mtime)) error = ESTALE;
    if (!error) error = currentDirectory(store);
    if (error) free(data); else { *bytes = data; *length = count; }
done:
    close(fd); return error;
}
static int validateDestination(VDTNiceStore *store, const char *name) {
    struct stat s;
    if (fstatat(store->directoryFD, name, &s, AT_SYMLINK_NOFOLLOW))
        return errno == ENOENT ? 0 : errno;
    return safeFile(&s, name) ? 0 : EPERM;
}
static int syncDirectory(int fd) {
    if (fsync(fd) == 0) return 0;
    // Some Darwin filesystems do not implement directory fsync. File contents
    // were synced before rename; no claim of power-loss transactional durability.
    return errno == EINVAL || errno == ENOTSUP ? 0 : errno;
}
int VDTNiceStoreWrite(VDTNiceStore *store, const char *name, const void *bytes, size_t length) {
    if (!knownName(name) || (!bytes && length) || length > VDT_NICE_STORE_LIMIT) return EINVAL;
    if (geteuid() != 0) return EPERM;
    int error = currentDirectory(store);
    if (error) return error;
    if ((error = validateDestination(store, name))) return error;
    char temp[80]; int fd = -1;
    static unsigned counter;
    for (unsigned retry = 0; retry < 16; ++retry) {
        snprintf(temp, sizeof(temp), ".write.%ld.%u", (long)getpid(), ++counter);
        fd = openat(store->directoryFD, temp,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0 || errno != EEXIST) break;
    }
    if (fd < 0) return errno;
    size_t used = 0;
    while (used < length) {
        ssize_t n = write(fd, (const unsigned char *)bytes + used, length - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { error = n < 0 ? errno : EIO; break; }
        used += (size_t)n;
    }
    if (!error && fchmod(fd, expectedMode(name))) error = errno;
    if (!error && fsync(fd)) error = errno;
    if (close(fd) && !error) error = errno;
    if (!error) error = currentDirectory(store);
    if (!error) error = validateDestination(store, name);
    if (!error && renameat(store->directoryFD, temp, store->directoryFD, name)) error = errno;
    if (!error) error = syncDirectory(store->directoryFD);
    if (error) unlinkat(store->directoryFD, temp, 0);
    return error;
}
int VDTNiceStoreRemove(VDTNiceStore *store, const char *name) {
    if (!knownName(name)) return EINVAL;
    if (geteuid() != 0) return EPERM;
    int error = currentDirectory(store);
    if (error) return error;
    if ((error = validateDestination(store, name))) return error;
    if (unlinkat(store->directoryFD, name, 0) && errno != ENOENT) return errno;
    return syncDirectory(store->directoryFD);
}
