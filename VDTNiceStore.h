// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#ifndef VDT_NICE_STORE_H
#define VDT_NICE_STORE_H
#include <stddef.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
#define VDT_NICE_STORE_LIMIT (2u * 1024u * 1024u)
#define VDT_NICE_JOURNAL "journal.plist"
#define VDT_NICE_STATUS "status.plist"
#define VDT_NICE_REQUEST "restore-request.plist"
typedef struct {
    int parentFD, directoryFD;
    char *parentPath, *leaf;
} VDTNiceStore;
// Root-owned dedicated directory, final components NOFOLLOW, bounded regular
// one-link files; status alone is world-readable. Returns 0 or errno.
int VDTNiceStoreOpen(const char *path, int create, VDTNiceStore *store);
void VDTNiceStoreClose(VDTNiceStore *store);
int VDTNiceStoreRead(VDTNiceStore *store, const char *name, void **bytes, size_t *length);
int VDTNiceStoreWrite(VDTNiceStore *store, const char *name, const void *bytes, size_t length);
int VDTNiceStoreRemove(VDTNiceStore *store, const char *name);
#ifdef __cplusplus
}
#endif
#endif
