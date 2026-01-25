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

// Constructs the permuted longest common prefix array (PLCP)
int64_t zig_libsais64_plcp(
    const uint8_t * T,
    const int64_t * SA,
    int64_t * PLCP,
    int64_t n
) {
    return libsais64_plcp(T, SA, PLCP, n);
}

// Constructs the longest common prefix array (LCP) from PLCP
int64_t zig_libsais64_lcp(
    const int64_t * PLCP,
    const int64_t * SA,
    int64_t * LCP,
    int64_t n
) {
    return libsais64_lcp(PLCP, SA, LCP, n);
}
