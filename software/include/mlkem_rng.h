#ifndef MLKEM_RNG_H
#define MLKEM_RNG_H
#include "mlkem_accel.h"
typedef enum { MLKEM_RNG_CPU = 0, MLKEM_RNG_TRNG = 1 } mlkem_rng_source;
/* Change the initializer in software/src/mlkem_rng.c, then rebuild. */
extern mlkem_rng_source mlkem_keygen_rng_source;
typedef struct {
  mlkem_accel *accel;
  mlkem_random_fn cpu_random;
  void *cpu_user;
} mlkem_seed_rng;
void mlkem_seed_rng_init(mlkem_seed_rng *, mlkem_accel *, mlkem_random_fn,
                         void *);
/* Pass this callback to mlkem_keygen. A 64-byte request obtains d || z.
   Hardware mode never falls back to CPU randomness on failure. */
int mlkem_seed_random(void *, uint8_t *, size_t);
int mlkem_seed_source(void);
#endif
