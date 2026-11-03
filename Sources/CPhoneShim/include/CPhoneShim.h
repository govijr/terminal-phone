#ifndef CPHONESHIM_H
#define CPHONESHIM_H
#include <stddef.h>

/// Creates a new POSIX shared-memory object of `size` bytes, readable only by this user.
/// Returns an open descriptor, or -1. Swift cannot call the variadic shm_open directly.
int tp_shm_create(const char *name, size_t size);
int tp_shm_unlink(const char *name);

#endif
