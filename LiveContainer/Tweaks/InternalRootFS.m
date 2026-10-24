//
//  InternalRootFS.m
//  LiveContainer
//
//  Quick-and-dirty AppleInternal filesystem compatibility PoC.
//
//  This is NOT a real mount. It overlays selected absolute paths from an
//  extracted iOS filesystem stored inside LiveContainer's sandbox.
//

@import Foundation;

#import "Tweaks.h"
#include "../../litehook/src/litehook.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static bool gInternalRootFSEnabled = false;
static char gInternalRootFSPath[PATH_MAX] = {0};
static unsigned int gInternalRootFSLogCount = 0;

// Save direct pointers before rebinding. litehook changes callsites, not these
// implementation addresses, which mirrors how LiveContainer preserves dlopen.
static int (*irfs_orig_open)(const char *, int, ...) = open;
static int (*irfs_orig_openat)(int, const char *, int, ...) = openat;
static int (*irfs_orig_stat)(const char *, struct stat *) = stat;
static int (*irfs_orig_lstat)(const char *, struct stat *) = lstat;
static int (*irfs_orig_access)(const char *, int) = access;
static FILE *(*irfs_orig_fopen)(const char *, const char *) = fopen;
static DIR *(*irfs_orig_opendir)(const char *) = opendir;
static ssize_t (*irfs_orig_readlink)(const char *, char *, size_t) = readlink;
static char *(*irfs_orig_realpath)(const char *, char *) = realpath;
static void *(*irfs_orig_dlopen)(const char *, int) = dlopen;

static bool irfs_has_prefix(const char *path, const char *prefix) {
    if (!path || !prefix) return false;
    size_t n = strlen(prefix);
    if (strncmp(path, prefix, n) != 0) return false;
    return path[n] == '\0' || path[n] == '/';
}

static bool irfs_force_virtual_path(const char *path) {
    // These roots do not exist on production iOS in the form expected by
    // AppleInternal apps, so always redirect them into the compatibility root.
    return irfs_has_prefix(path, "/AppleInternal") ||
           irfs_has_prefix(path, "/Developer");
}

static bool irfs_overlay_candidate(const char *path) {
    // Overlay-only roots: real iOS wins. The dumped filesystem is consulted
    // only when the live device does not have the requested path.
    return irfs_has_prefix(path, "/System") ||
           irfs_has_prefix(path, "/Library") ||
           irfs_has_prefix(path, "/Applications") ||
           irfs_has_prefix(path, "/usr/local") ||
           irfs_has_prefix(path, "/etc") ||
           irfs_has_prefix(path, "/private/etc");
}

static bool irfs_candidate_exists(const char *candidate) {
    struct stat st;
    return candidate && irfs_orig_lstat(candidate, &st) == 0;
}

static void irfs_log_translation(const char *source, const char *dest) {
    // Deliberately noisy enough to debug the PoC, but capped so Preferences.app
    // cannot fill the console with thousands of filesystem messages.
    if (gInternalRootFSLogCount++ < 250) {
        NSLog(@"[InternalRootFS] %s -> %s", source, dest);
    }
}

bool InternalRootFSEnabled(void) {
    return gInternalRootFSEnabled;
}

const char *InternalRootFSTranslatePath(const char *path, char *buffer, size_t bufferSize) {
    if (!gInternalRootFSEnabled || !path || path[0] != '/' || !buffer || bufferSize == 0) {
        return path;
    }

    bool force = irfs_force_virtual_path(path);
    bool overlay = irfs_overlay_candidate(path);
    if (!force && !overlay) {
        return path;
    }

    // /etc on iOS resolves into /private/etc. Preserve the on-disk root layout
    // when looking inside an extracted filesystem image.
    if (irfs_has_prefix(path, "/etc")) {
        snprintf(buffer, bufferSize, "%s/private%s", gInternalRootFSPath, path);
    } else {
        snprintf(buffer, bufferSize, "%s%s", gInternalRootFSPath, path);
    }

    if (force) {
        irfs_log_translation(path, buffer);
        return buffer;
    }

    // Overlay policy: if the current production OS has the path, use it.
    // Otherwise fall back to the dump if that path exists there.
    if (irfs_candidate_exists(path)) {
        return path;
    }
    if (irfs_candidate_exists(buffer)) {
        irfs_log_translation(path, buffer);
        return buffer;
    }
    return path;
}

static bool irfs_path_was_redirected(const char *original, const char *translated) {
    return original && translated && translated != original && strcmp(original, translated) != 0;
}

static bool irfs_open_is_write(int flags) {
    int accessMode = flags & O_ACCMODE;
    return accessMode == O_WRONLY || accessMode == O_RDWR ||
           (flags & O_CREAT) || (flags & O_TRUNC) || (flags & O_APPEND);
}

static int irfs_open(const char *path, int flags, ...) {
    char translated[PATH_MAX];
    const char *resolved = InternalRootFSTranslatePath(path, translated, sizeof(translated));

    if (irfs_path_was_redirected(path, resolved) && irfs_open_is_write(flags)) {
        errno = EROFS;
        return -1;
    }

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return irfs_orig_open(resolved, flags, mode);
    }
    return irfs_orig_open(resolved, flags);
}

static int irfs_openat(int fd, const char *path, int flags, ...) {
    // Absolute paths ignore fd. Relative openat paths are intentionally left
    // alone in this first PoC because translating them correctly requires
    // reconstructing the directory-fd path.
    char translated[PATH_MAX];
    const char *resolved = InternalRootFSTranslatePath(path, translated, sizeof(translated));

    if (irfs_path_was_redirected(path, resolved) && irfs_open_is_write(flags)) {
        errno = EROFS;
        return -1;
    }

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode_t mode = (mode_t)va_arg(ap, int);
        va_end(ap);
        return irfs_orig_openat(fd, resolved, flags, mode);
    }
    return irfs_orig_openat(fd, resolved, flags);
}

static int irfs_stat(const char *path, struct stat *st) {
    char translated[PATH_MAX];
    return irfs_orig_stat(InternalRootFSTranslatePath(path, translated, sizeof(translated)), st);
}

static int irfs_lstat(const char *path, struct stat *st) {
    char translated[PATH_MAX];
    return irfs_orig_lstat(InternalRootFSTranslatePath(path, translated, sizeof(translated)), st);
}

static int irfs_access(const char *path, int mode) {
    char translated[PATH_MAX];
    return irfs_orig_access(InternalRootFSTranslatePath(path, translated, sizeof(translated)), mode);
}

static FILE *irfs_fopen(const char *path, const char *mode) {
    char translated[PATH_MAX];
    const char *resolved = InternalRootFSTranslatePath(path, translated, sizeof(translated));

    if (irfs_path_was_redirected(path, resolved) && mode &&
        (strchr(mode, 'w') || strchr(mode, 'a') || strchr(mode, '+'))) {
        errno = EROFS;
        return NULL;
    }
    return irfs_orig_fopen(resolved, mode);
}

static DIR *irfs_opendir(const char *path) {
    char translated[PATH_MAX];
    return irfs_orig_opendir(InternalRootFSTranslatePath(path, translated, sizeof(translated)));
}

static ssize_t irfs_readlink(const char *path, char *buf, size_t bufSize) {
    char translated[PATH_MAX];
    return irfs_orig_readlink(InternalRootFSTranslatePath(path, translated, sizeof(translated)), buf, bufSize);
}

static char *irfs_realpath(const char *path, char *resolvedPath) {
    char translated[PATH_MAX];
    return irfs_orig_realpath(InternalRootFSTranslatePath(path, translated, sizeof(translated)), resolvedPath);
}

static void *irfs_dlopen(const char *path, int mode) {
    char translated[PATH_MAX];
    const char *resolved = InternalRootFSTranslatePath(path, translated, sizeof(translated));
    return irfs_orig_dlopen(resolved, mode);
}

void InternalRootFSInit(const char *rootPath) {
    if (gInternalRootFSEnabled || !rootPath || !rootPath[0]) {
        return;
    }

    char normalized[PATH_MAX];
    if (!irfs_orig_realpath(rootPath, normalized)) {
        NSLog(@"[InternalRootFS] root does not exist: %s", rootPath);
        return;
    }

    struct stat st;
    if (irfs_orig_stat(normalized, &st) != 0 || !S_ISDIR(st.st_mode)) {
        NSLog(@"[InternalRootFS] root is not a directory: %s", normalized);
        return;
    }

    // Require at least one characteristic directory so an unrelated folder
    // cannot accidentally activate the compatibility layer.
    char appleInternalPath[PATH_MAX];
    char developerPath[PATH_MAX];
    snprintf(appleInternalPath, sizeof(appleInternalPath), "%s/AppleInternal", normalized);
    snprintf(developerPath, sizeof(developerPath), "%s/Developer", normalized);
    if (!irfs_candidate_exists(appleInternalPath) && !irfs_candidate_exists(developerPath)) {
        NSLog(@"[InternalRootFS] %@", @"root found, but it contains neither AppleInternal nor Developer; not enabling");
        return;
    }

    strlcpy(gInternalRootFSPath, normalized, sizeof(gInternalRootFSPath));
    size_t length = strlen(gInternalRootFSPath);
    while (length > 1 && gInternalRootFSPath[length - 1] == '/') {
        gInternalRootFSPath[--length] = '\0';
    }

    gInternalRootFSEnabled = true;
    setenv("LC_INTERNAL_ROOTFS", gInternalRootFSPath, 1);

    // Install before the guest executable is dlopen()'d so initializers and
    // bundle discovery immediately see the compatibility filesystem.
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, open, irfs_open, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, openat, irfs_openat, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, stat, irfs_stat, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, lstat, irfs_lstat, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, access, irfs_access, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, fopen, irfs_fopen, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, opendir, irfs_opendir, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, readlink, irfs_readlink, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, realpath, irfs_realpath, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, dlopen, irfs_dlopen, nil);

    NSLog(@"[InternalRootFS] enabled read-only compatibility root: %s", gInternalRootFSPath);
}
