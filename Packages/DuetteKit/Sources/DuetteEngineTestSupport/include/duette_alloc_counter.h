/*
 * Test-only allocation counter. Linking this target replaces the global C++ operator new and
 * delete for the whole test bundle; the replacement counts calls made on a thread between
 * duette_alloc_counter_arm and duette_alloc_counter_disarm on that same thread.
 */
#ifndef DUETTE_ALLOC_COUNTER_H
#define DUETTE_ALLOC_COUNTER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Starts counting operator new calls on the calling thread, from zero.
void duette_alloc_counter_arm(void);

/// Stops counting on the calling thread and returns the number of calls seen since the arm.
uint64_t duette_alloc_counter_disarm(void);

/// Allocates and frees one int with operator new. Proves the counter is wired up.
void duette_alloc_counter_probe(void);

#ifdef __cplusplus
}
#endif

#endif /* DUETTE_ALLOC_COUNTER_H */
