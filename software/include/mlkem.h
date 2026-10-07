#ifndef MLKEM_H
#define MLKEM_H
#include <stddef.h>
#include <stdint.h>

#define MLKEM_MAX_EK 1568
#define MLKEM_MAX_DK 3168
#define MLKEM_MAX_CT 1568
#define MLKEM_OK 0
#define MLKEM_ERR_INPUT -1
#define MLKEM_ERR_BACKEND -2
#define MLKEM_ERR_RANDOM -3

/* Hash mode and polynomial command numbers match mlkem_top. */
typedef int (*mlkem_hash_fn)(void *, unsigned, const uint8_t *, size_t,
                             uint8_t *, size_t);
typedef int (*mlkem_poly_fn)(void *, unsigned, uint16_t *, const uint16_t *,
                             const uint16_t *, const uint16_t *);
typedef int (*mlkem_random_fn)(void *, uint8_t *, size_t);
typedef struct {
  void *user;
  mlkem_hash_fn hash;
  mlkem_poly_fn poly;
} mlkem_backend;
typedef struct {
  unsigned k, eta1, du, dv;
  size_t ek_bytes, dk_bytes, ct_bytes;
  mlkem_backend backend;
} mlkem_ctx;

int mlkem_init(mlkem_ctx *, unsigned parameter_set, const mlkem_backend *);
int mlkem_check_ek(const mlkem_ctx *, const uint8_t *, size_t);
int mlkem_check_dk(const mlkem_ctx *, const uint8_t *, size_t);
/* Explicit randomness APIs are for KATs or caller-supplied secure randomness.
 */
int mlkem_keygen_derand(const mlkem_ctx *, uint8_t *, size_t, uint8_t *, size_t,
                        const uint8_t d[32], const uint8_t z[32]);
int mlkem_encaps_derand(const mlkem_ctx *, uint8_t *, size_t, uint8_t ss[32],
                        const uint8_t *, size_t, const uint8_t m[32]);
int mlkem_decaps(const mlkem_ctx *, uint8_t ss[32], const uint8_t *, size_t,
                 const uint8_t *, size_t);
int mlkem_keygen(const mlkem_ctx *, uint8_t *, size_t, uint8_t *, size_t,
                 mlkem_random_fn, void *);
int mlkem_encaps(const mlkem_ctx *, uint8_t *, size_t, uint8_t ss[32],
                 const uint8_t *, size_t, mlkem_random_fn, void *);

/* Portable software primitives, also usable independently by tests. */
int mlkem_sw_hash(void *, unsigned, const uint8_t *, size_t, uint8_t *, size_t);
int mlkem_sw_poly(void *, unsigned, uint16_t *, const uint16_t *,
                  const uint16_t *, const uint16_t *);
void mlkem_sample_ntt(uint16_t out[256], const uint8_t rho[32],
                      uint8_t first_index, uint8_t second_index);
void mlkem_cbd(uint16_t out[256], const uint8_t *, unsigned eta);
uint16_t mlkem_compress(uint16_t, unsigned);
uint16_t mlkem_decompress(uint16_t, unsigned);
void mlkem_encode(uint8_t *, const uint16_t[256], unsigned bits);
void mlkem_decode(uint16_t[256], const uint8_t *, unsigned bits);
void mlkem_zeroize(void *, size_t);
#endif
