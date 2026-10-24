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
#import "../LCSharedUtils.h"
#import "../utils.h"
#include "../../litehook/src/litehook.h"

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <objc/message.h>
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


#pragma mark - Experimental pre-dyld dependency preload healer

// Pull the value following a label such as "Library not loaded: " up to the
// next newline. dyld error strings are intentionally treated as diagnostics,
// not a stable API; this is a PoC and logs loudly when parsing fails.
static bool irfs_extract_error_field(const char *errorText, const char *label,
                                     char *out, size_t outSize) {
    if (!errorText || !label || !out || outSize == 0) return false;
    const char *start = strstr(errorText, label);
    if (!start) return false;
    start += strlen(label);
    while (*start == ' ' || *start == '\t') start++;

    const char *end = start;
    while (*end && *end != '\n' && *end != '\r') end++;
    while (end > start && (end[-1] == ' ' || end[-1] == '\t')) end--;
    if (end <= start) return false;

    size_t len = (size_t)(end - start);
    if (len >= outSize) len = outSize - 1;
    memcpy(out, start, len);
    out[len] = '\0';
    return true;
}

static bool irfs_preloadable_file_exists(const char *path) {
    if (!path || !path[0]) return false;
    struct stat st;
    return irfs_orig_stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

static bool irfs_path_is_mutable_internal_image(const char *path) {
    if (!path || !gInternalRootFSPath[0]) return false;

    char appleInternalRoot[PATH_MAX];
    char developerRoot[PATH_MAX];
    snprintf(appleInternalRoot, sizeof(appleInternalRoot), "%s/AppleInternal", gInternalRootFSPath);
    snprintf(developerRoot, sizeof(developerRoot), "%s/Developer", gInternalRootFSPath);

    return irfs_has_prefix(path, appleInternalRoot) ||
           irfs_has_prefix(path, developerRoot);
}

static bool irfs_dyld_error_is_signature_failure(const char *errorText) {
    if (!errorText) return false;
    NSString *error = [[NSString stringWithUTF8String:errorText] lowercaseString];
    if (!error.length) return false;

    return [error containsString:@"code signature"] ||
           [error containsString:@"signature invalid"] ||
           [error containsString:@"invalid signature"] ||
           [error containsString:@"ct policy"] ||
           [error containsString:@"library validation"] ||
           [error containsString:@"different team id"] ||
           [error containsString:@"different team ids"];
}

// Load LiveContainer's embedded ZSign dylib, fetch the same developer
// certificate LiveContainer already uses for guest apps, and sign the selected
// RootFS Mach-O in place. The Mac-side archive is the pristine source; the
// on-device RootFS is intentionally treated as a mutable execution copy.
static bool irfs_sign_internal_image_in_place(const char *path) {
    if (!path || !irfs_path_is_mutable_internal_image(path)) {
        NSLog(@"[InternalRootFS] SIGN REFUSED outside mutable Internal roots: %s", path ?: "(null)");
        return false;
    }

    NSString *password = [LCSharedUtils certificatePassword];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    if (!defaults) defaults = NSUserDefaults.standardUserDefaults;
    NSData *certificate = [defaults objectForKey:@"LCCertificateData"];

    if (![certificate isKindOfClass:NSData.class] || certificate.length == 0 || password.length == 0) {
        NSLog(@"[InternalRootFS] SIGN FAILED: LiveContainer signing certificate/password is not configured");
        return false;
    }

    // NSBundle.mainBundle is intentionally replaced with the guest bundle by
    // LiveContainer before we get here. Likewise, @executable_path may resolve
    // relative to the guest executable (e.g. Siri Debug), which would make dyld
    // look for ZSign.dylib inside Guest.app/Frameworks. LiveContainer preserves
    // its original host bundle in NSUserDefaults.lcMainBundle; use that absolute
    // path instead.
    NSBundle *hostBundle = NSUserDefaults.lcMainBundle;
    NSString *zsignPath = [hostBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/ZSign.dylib"];
    if (!hostBundle || zsignPath.length == 0) {
        NSLog(@"[InternalRootFS] SIGN FAILED: LiveContainer host bundle is unavailable");
        return false;
    }

    NSLog(@"[InternalRootFS] host ZSign path: %@", zsignPath);
    (void)dlerror();
    void *zsignHandle = irfs_orig_dlopen(zsignPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    const char *zsignError = dlerror();
    if (!zsignHandle || (uint64_t)zsignHandle > 0xf00000000000ULL) {
        NSLog(@"[InternalRootFS] SIGN FAILED: unable to load ZSign.dylib at %@: %s",
              zsignPath, zsignError ?: "unknown dlopen error");
        return false;
    }

    Class signerClass = NSClassFromString(@"ZSigner");
    SEL selector = NSSelectorFromString(@"signMachOAtPath:bundleId:cert:pass:error:");
    if (!signerClass || ![signerClass respondsToSelector:selector]) {
        NSLog(@"[InternalRootFS] SIGN FAILED: synchronous ZSigner bridge is unavailable");
        return false;
    }

    NSString *pathString = [NSString stringWithUTF8String:path];
    NSString *bundleId = hostBundle.bundleIdentifier ?: @"com.kdt.livecontainerInternalTest";
    NSError *signError = nil;

    typedef BOOL (*IRFSSignMsgSend)(id, SEL, NSString *, NSString *, NSData *, NSString *, NSError **);
    IRFSSignMsgSend sendSign = (IRFSSignMsgSend)(void *)objc_msgSend;

    NSLog(@"[InternalRootFS] SIGN IN PLACE: %@", pathString);
    BOOL success = sendSign(signerClass, selector, pathString, bundleId, certificate, password, &signError);
    if (!success) {
        NSLog(@"[InternalRootFS] SIGN FAILED: %@", signError.localizedDescription ?: @"unknown ZSign error");
        return false;
    }

    NSLog(@"[InternalRootFS] SIGN SUCCESS: %@", pathString);
    return true;
}

// Resolve a dyld-reported dependency into a real path inside the compatibility
// root. First try the missing install name itself. If it is @rpath-based, use
// the concrete paths dyld printed in "Reason: tried:" -- that lets dyld tell us
// which LC_RPATH expansions it actually attempted rather than reimplementing
// its runpath rules here.
static bool irfs_resolve_dyld_error_candidate(const char *errorText,
                                              const char *missingPath,
                                              char *out, size_t outSize) {
    if (!errorText || !missingPath || !out || outSize == 0) return false;

    if (missingPath[0] == '/') {
        char translated[PATH_MAX];
        const char *candidate = InternalRootFSTranslatePath(missingPath, translated, sizeof(translated));
        if (candidate && irfs_preloadable_file_exists(candidate) && strcmp(candidate, missingPath) != 0) {
            strlcpy(out, candidate, outSize);
            return true;
        }
    }

    // Modern dyld errors quote every concrete attempted path. Find the first
    // one that our overlay can translate to an existing file in the dump.
    const char *cursor = errorText;
    while ((cursor = strchr(cursor, '\'')) != NULL) {
        const char *end = strchr(cursor + 1, '\'');
        if (!end) break;

        size_t len = (size_t)(end - (cursor + 1));
        if (len > 0 && len < PATH_MAX) {
            char attempted[PATH_MAX];
            memcpy(attempted, cursor + 1, len);
            attempted[len] = '\0';

            if (attempted[0] == '/') {
                char translated[PATH_MAX];
                const char *candidate = InternalRootFSTranslatePath(attempted, translated, sizeof(translated));
                if (candidate && strcmp(candidate, attempted) != 0 && irfs_preloadable_file_exists(candidate)) {
                    strlcpy(out, candidate, outSize);
                    return true;
                }
                // Also accept a path already inside our compatibility root.
                if (irfs_has_prefix(attempted, gInternalRootFSPath) && irfs_preloadable_file_exists(attempted)) {
                    strlcpy(out, attempted, outSize);
                    return true;
                }
            }
        }
        cursor = end + 1;
    }

    // Last-resort canonical locations for @rpath dependencies. This is not
    // intended to replace the real resolver; it merely makes the preload PoC
    // useful when dyld's error omits a helpful AppleInternal/Developer attempt.
    if (!strncmp(missingPath, "@rpath/", 7)) {
        const char *suffix = missingPath + 7;
        const char *roots[] = {
            "/AppleInternal/Library/Frameworks",
            "/AppleInternal/Library/PrivateFrameworks",
            "/Developer/Library/Frameworks",
            "/Developer/Library/PrivateFrameworks",
            "/AppleInternal/Developer/Library/Frameworks",
            "/AppleInternal/Developer/Library/PrivateFrameworks",
            "/AppleInternal/Developer/usr/lib",
            "/Developer/usr/lib",
            "/usr/local/lib",
            NULL
        };
        for (size_t i = 0; roots[i]; i++) {
            char virtualPath[PATH_MAX];
            snprintf(virtualPath, sizeof(virtualPath), "%s/%s", roots[i], suffix);
            char translated[PATH_MAX];
            const char *candidate = InternalRootFSTranslatePath(virtualPath, translated, sizeof(translated));
            if (candidate && strcmp(candidate, virtualPath) != 0 && irfs_preloadable_file_exists(candidate)) {
                strlcpy(out, candidate, outSize);
                return true;
            }
        }
    }

    return false;
}

static bool irfs_preload_from_error_recursive(const char *errorText,
                                              NSMutableSet<NSString *> *inProgress,
                                              NSUInteger depth) {
    if (!gInternalRootFSEnabled || !errorText || depth > 24) return false;

    char missingPath[PATH_MAX];
    if (!irfs_extract_error_field(errorText, "Library not loaded: ", missingPath, sizeof(missingPath))) {
        NSLog(@"[InternalRootFS] preload: could not parse missing dependency from dyld error");
        return false;
    }

    char candidate[PATH_MAX];
    if (!irfs_resolve_dyld_error_candidate(errorText, missingPath, candidate, sizeof(candidate))) {
        NSLog(@"[InternalRootFS] preload: no compatibility-root candidate for %s", missingPath);
        return false;
    }

    NSString *candidateString = [NSString stringWithUTF8String:candidate];
    if (!candidateString.length || [inProgress containsObject:candidateString]) {
        NSLog(@"[InternalRootFS] preload: dependency cycle/duplicate while loading %s", candidate);
        return false;
    }

    [inProgress addObject:candidateString];
    NSLog(@"[InternalRootFS] preload: %s", missingPath);
    NSLog(@"[InternalRootFS]          -> %s", candidate);

    BOOL resignAttempted = NO;
    for (NSUInteger attempt = 0; attempt < 24; attempt++) {
        (void)dlerror();
        void *handle = dlopen_nolock(candidate, RTLD_LAZY | RTLD_GLOBAL);
        const char *nestedError = dlerror();
        if (handle && (uint64_t)handle <= 0xf00000000000ULL) {
            NSLog(@"[InternalRootFS] PRELOAD SUCCESS: %s (%p)", candidate, handle);
            [inProgress removeObject:candidateString];
            return true;
        }

        NSString *nestedErrorCopy = nestedError ? [NSString stringWithUTF8String:nestedError] : nil;
        if (!nestedErrorCopy.length) {
            NSLog(@"[InternalRootFS] PRELOAD FAILED without dyld error: %s", candidate);
            [inProgress removeObject:candidateString];
            return false;
        }

        NSLog(@"[InternalRootFS] preload child failure: %@", nestedErrorCopy);

        // AppleInternal images from the dump commonly carry signatures that
        // production AMFI will not accept. Re-sign the on-device RootFS copy
        // once with LiveContainer's configured developer certificate, then
        // retry this exact physical image before treating the failure as a
        // missing child dependency.
        if (!resignAttempted && irfs_dyld_error_is_signature_failure(nestedErrorCopy.UTF8String)) {
            resignAttempted = YES;
            NSLog(@"[InternalRootFS] signature rejection detected for %s", candidate);
            if (irfs_sign_internal_image_in_place(candidate)) {
                NSLog(@"[InternalRootFS] retrying preload after in-place signing: %s", candidate);
                continue;
            }

            NSLog(@"[InternalRootFS] unable to sign rejected image: %s", candidate);
            [inProgress removeObject:candidateString];
            return false;
        }

        if (!irfs_preload_from_error_recursive(nestedErrorCopy.UTF8String, inProgress, depth + 1)) {
            NSLog(@"[InternalRootFS] unable to heal child dependency for %s", candidate);
            [inProgress removeObject:candidateString];
            return false;
        }
        NSLog(@"[InternalRootFS] retrying preload after child dependency was loaded: %s", candidate);
    }

    NSLog(@"[InternalRootFS] preload retry limit reached: %s", candidate);
    [inProgress removeObject:candidateString];
    return false;
}

bool InternalRootFSTryPreloadMissingDependency(const char *dyldError) {
    if (!gInternalRootFSEnabled || !dyldError) return false;
    NSMutableSet<NSString *> *inProgress = [NSMutableSet set];
    return irfs_preload_from_error_recursive(dyldError, inProgress, 0);
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

    NSLog(@"[InternalRootFS] enabled guest-read-only compatibility root: %s", gInternalRootFSPath);
}
