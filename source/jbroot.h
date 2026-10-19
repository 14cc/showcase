/*
 * jbroot.h — where the jailbreak lives at run time.
 *
 * RootHide keeps the jailbreak in a per-device random directory
 * (/var/containers/Bundle/Application/.jbroot-XXXXXXXXXXXXXXXX) instead of
 * /var/jb, so the RootHide build (SHOWCASE_ROOTHIDE) resolves it when the
 * program starts:
 *   jb_path("/usr/bin/x")    -> <jbroot>/usr/bin/x
 *   jb_fix("/var/jb/usr/x")  -> <jbroot>/usr/x   (other paths unchanged)
 * Every other build keeps its compile-time paths and jb_fix() is a no-op.
 * Results are cached per input pointer, so pass string literals.
 */
#ifndef SHOWCASE_JBROOT_H
#define SHOWCASE_JBROOT_H

#ifdef SHOWCASE_ROOTHIDE
#include <glob.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static __attribute__((unused)) char g_jb_root[PATH_MAX];

static inline __attribute__((unused)) int jb_root_looks_valid(const char *root) {
    char probe[PATH_MAX];
    snprintf(probe, sizeof(probe), "%s/usr/bin", root);
    return root[0] == '/' && access(probe, X_OK) == 0;
}

static __attribute__((unused)) void jb_root_init(void) {
    /* Our binaries all sit in <jbroot>/Applications/Showcase.app/. */
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) == 0 && realpath(exe, real)) {
        char *app = strstr(real, "/Applications/Showcase.app/");
        if (app && app != real) {
            *app = 0;
            if (jb_root_looks_valid(real)) {
                strlcpy(g_jb_root, real, sizeof(g_jb_root));
                return;
            }
        }
    }
    glob_t found;
    if (glob("/var/containers/Bundle/Application/.jbroot-*", 0, NULL, &found) == 0) {
        for (size_t i = 0; i < found.gl_pathc; i++) {
            if (realpath(found.gl_pathv[i], real) && jb_root_looks_valid(real)) {
                strlcpy(g_jb_root, real, sizeof(g_jb_root));
                break;
            }
        }
        globfree(&found);
    }
    if (!g_jb_root[0]) strlcpy(g_jb_root, "/var/jb", sizeof(g_jb_root));
}

static inline __attribute__((unused)) const char *jb_root(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, jb_root_init);
    return g_jb_root;
}

static inline __attribute__((unused)) const char *jb_cached_join(const char *key, const char *tail) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static struct { const char *key; char *value; } cache[64];
    const char *root = jb_root();
    pthread_mutex_lock(&lock);
    for (int i = 0; i < 64; i++) {
        if (cache[i].key == key) {
            pthread_mutex_unlock(&lock);
            return cache[i].value;
        }
        if (!cache[i].key) {
            size_t length = strlen(root) + strlen(tail) + 1;
            char *value = malloc(length);
            if (!value) break;
            snprintf(value, length, "%s%s", root, tail);
            cache[i].key = key;
            cache[i].value = value;
            pthread_mutex_unlock(&lock);
            return value;
        }
    }
    pthread_mutex_unlock(&lock);
    /* Cache full: hand out an uncached copy (a small, bounded leak). */
    size_t length = strlen(root) + strlen(tail) + 1;
    char *value = malloc(length);
    if (value) snprintf(value, length, "%s%s", root, tail);
    return value ? value : tail;
}

static inline __attribute__((unused)) const char *jb_path(const char *path) {
    return jb_cached_join(path, path);
}

static inline __attribute__((unused)) const char *jb_fix(const char *path) {
    if (!path || strncmp(path, "/var/jb", 7) != 0 || (path[7] != '/' && path[7] != 0))
        return path;
    return jb_cached_join(path, path + 7);
}
/* Paths handed to RootHide's own tools (launchctl, sh, killall). Those tools
 * see the jbroot as "/" and reach the real root through /rootfs, so a real
 * path under the jbroot loses its prefix and any other real path gains
 * "/rootfs". Results are cached per input pointer, so pass stable strings. */
static inline __attribute__((unused)) const char *jb_tool_path(const char *path) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static struct { const char *key; char *value; } cache[32];
    if (!path || path[0] != '/') return path;
    const char *root = jb_root();
    size_t rootLength = strlen(root);
    if (strncmp(path, root, rootLength) == 0 &&
        (path[rootLength] == '/' || path[rootLength] == 0))
        return path[rootLength] ? path + rootLength : "/";
    pthread_mutex_lock(&lock);
    for (int i = 0; i < 32; i++) {
        if (cache[i].key == path) {
            pthread_mutex_unlock(&lock);
            return cache[i].value;
        }
        if (!cache[i].key) {
            size_t length = strlen("/rootfs") + strlen(path) + 1;
            char *value = malloc(length);
            if (!value) break;
            snprintf(value, length, "/rootfs%s", path);
            cache[i].key = path;
            cache[i].value = value;
            pthread_mutex_unlock(&lock);
            return value;
        }
    }
    pthread_mutex_unlock(&lock);
    return path;
}
#else
#define jb_fix(path) (path)
#define jb_tool_path(path) (path)
#endif

#endif
