# AppleInternal RootFS compatibility PoC

This fork adds a deliberately small, read-only **userspace path overlay** for experimenting with AppleInternal applications in LiveContainer.

It is **not** a kernel/APFS mount and does not grant Apple entitlements. It redirects selected filesystem calls made by the guest process into a raw/extracted iOS filesystem stored inside LiveContainer's own Documents directory.

## Put the filesystem here

Create:

```
LiveContainer Documents/
└── AppleInternalRootFS/
    ├── AppleInternal/
    ├── Developer/
    ├── System/
    ├── Library/
    ├── usr/
    └── ...
```

`AppleInternalRootFS` must contain the filesystem root itself. In other words, do **not** create `AppleInternalRootFS/iPhoneOS18Internal/AppleInternal/...`.

The PoC auto-enables whenever `Documents/AppleInternalRootFS` exists and contains either `AppleInternal` or `Developer`. Rename/remove the folder to disable it.

## What gets redirected

Always virtualized:

- `/AppleInternal/...`
- `/Developer/...`

Fallback overlays (the live production OS wins; the dump is used only if the real path is absent):

- `/System/...`
- `/Library/...`
- `/Applications/...`
- `/usr/local/...`
- `/etc/...` (mapped to the dump's `/private/etc/...`)
- `/private/etc/...`

The current PoC hooks:

- `open`
- `openat` for absolute paths
- `stat`
- `lstat`
- `access`
- `fopen`
- `opendir`
- `readlink`
- `realpath`
- `dlopen`

The compatibility filesystem is intentionally **read-only**. `open`/`fopen` writes to a redirected file fail with `EROFS`.

## Important limitation: pre-dyld dependencies

This version does **not** yet replace the Python dependency resolver.

A guest whose Mach-O has an immediate load command such as:

```
/AppleInternal/Library/Frameworks/Foo.framework/Foo
```

can still fail while LiveContainer performs the initial `dlopen()` of the guest. dyld resolves `LC_LOAD_DYLIB` itself before guest code runs, and those internal dyld filesystem accesses do not necessarily pass through the normal libc hooks in this PoC.

That is intentional for the first test. It lets us answer two questions separately:

1. Does runtime AppleInternal filesystem/bundle discovery work through an overlay?
2. Which untouched apps fail early enough that the Python resolver must be ported into LiveContainer's pre-launch/signing pipeline?

`dlopen("/AppleInternal/...")` performed *after* the hooks are active is translated.

## Good first tests

1. An internal app that already launches without external AppleInternal dependencies but reads `/AppleInternal` resources at runtime.
2. `Preferences.app`, primarily to collect the earliest remaining failures and sandbox denials.
3. An **unpatched** app that previously needed the Python resolver. If it dies on `Library not loaded` before any `[InternalRootFS]` messages relevant to that library, that is expected and confirms that the next phase belongs in LiveContainer's import/signing code.

## Console logging

The first 250 translated paths are printed as:

```
[InternalRootFS] /AppleInternal/... -> /private/var/.../Documents/AppleInternalRootFS/AppleInternal/...
```

This cap is intentional because Preferences and Foundation can perform a huge number of probes.

## Files changed

- `LiveContainer/Tweaks/InternalRootFS.m` — new overlay implementation
- `LiveContainer/Tweaks/Tweaks.h` — public PoC declarations
- `LiveContainer/LCBootstrap.m` — initializes the root before guest loading
- `LiveContainer/Tweaks/Dyld.m` — applies translation to LiveContainer's JIT-less `dlopen` hook

The `Tweaks` folder is an Xcode synchronized group in this source tree, so the new `.m` file should automatically become part of the same target as the existing tweak sources.

## Next phase if this works

Port the recursive Mach-O resolver into `LCAppInfo`'s patch/sign step so an untouched internal app can be made dyld-loadable automatically. That should use the raw root as the dependency repository, then let this runtime overlay handle resources, bundles, plists, and explicit runtime `dlopen()` calls.
