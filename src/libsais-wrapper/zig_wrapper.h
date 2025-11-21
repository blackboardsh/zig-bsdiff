// Simple C wrapper for libsais64 to ensure clean ABI for Zig
#ifndef ZIG_WRAPPER_H
#define ZIG_WRAPPER_H

#include <stdint.h>

// Simple wrapper with no macros or complex types
int64_t zig_libsais64_wrapper(
    const uint8_t * T,
    int64_t * SA,
    int64_t n
);

#endif
