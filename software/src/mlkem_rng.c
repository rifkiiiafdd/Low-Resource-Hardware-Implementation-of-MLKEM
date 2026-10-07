#include "mlkem_rng.h"

/* THE SINGLE APPLICATION SETTING: CPU for current main simulation;
   change to MLKEM_RNG_TRNG for hardware d/z on FPGA. */
mlkem_rng_source mlkem_keygen_rng_source = MLKEM_RNG_CPU;

void mlkem_seed_rng_init(mlkem_seed_rng *rng, mlkem_accel *accel,
                         mlkem_random_fn cpu_random, void *cpu_user) {
  rng->accel = accel;
  rng->cpu_random = cpu_random;
  rng->cpu_user = cpu_user;
}
int mlkem_seed_source(void) { return (int)mlkem_keygen_rng_source; }
int mlkem_seed_random(void *user, uint8_t *out, size_t n) {
  mlkem_seed_rng *rng = (mlkem_seed_rng *)user;
  int rc = MLKEM_ERR_RANDOM;
  if (!rng || (!out && n))
    return MLKEM_ERR_INPUT;
  if (!n)
    return 0;
  if (mlkem_keygen_rng_source == MLKEM_RNG_CPU && rng->cpu_random)
    rc = rng->cpu_random(rng->cpu_user, out, n);
  else if (mlkem_keygen_rng_source == MLKEM_RNG_TRNG && rng->accel)
    rc = mlkem_accel_random(rng->accel, out, n);
  if (rc) {
    mlkem_zeroize(out, n);
    return MLKEM_ERR_RANDOM;
  }
  return 0;
}
