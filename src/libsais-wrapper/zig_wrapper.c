// Simple C wrapper for libsais64 to ensure clean ABI for Zig
#include "libsais64.h"
#include <stddef.h>
#include <stdint.h>

// Wrapper function with explicit types and no macros
int64_t zig_libsais64_wrapper(
    const uint8_t * T,
    int64_t * SA,
    int64_t n
) {
    // Call libsais64 with default parameters
    // fs=0 means no extra space, freq=NULL means no frequency table
    return libsais64(T, SA, n, 0, NULL);
}
