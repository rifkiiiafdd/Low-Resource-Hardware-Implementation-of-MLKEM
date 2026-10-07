#include "keccak.h"
#include "mlkem.h"
#include <string.h>
static uint64_t rol(uint64_t x, unsigned n) {
  return n ? (x << n) | (x >> (64 - n)) : x;
}
static void permutation(uint64_t a[25]) {
  static const uint64_t rc[24] = {
      UINT64_C(0x0000000000000001), UINT64_C(0x0000000000008082),
      UINT64_C(0x800000000000808a), UINT64_C(0x8000000080008000),
      UINT64_C(0x000000000000808b), UINT64_C(0x0000000080000001),
      UINT64_C(0x8000000080008081), UINT64_C(0x8000000000008009),
      UINT64_C(0x000000000000008a), UINT64_C(0x0000000000000088),
      UINT64_C(0x0000000080008009), UINT64_C(0x000000008000000a),
      UINT64_C(0x000000008000808b), UINT64_C(0x800000000000008b),
      UINT64_C(0x8000000000008089), UINT64_C(0x8000000000008003),
      UINT64_C(0x8000000000008002), UINT64_C(0x8000000000000080),
      UINT64_C(0x000000000000800a), UINT64_C(0x800000008000000a),
      UINT64_C(0x8000000080008081), UINT64_C(0x8000000000008080),
      UINT64_C(0x0000000080000001), UINT64_C(0x8000000080008008)};
  static const unsigned rotation[25] = {0,  1, 62, 28, 27, 36, 44, 6,  55,
                                        20, 3, 10, 43, 25, 39, 41, 45, 15,
                                        21, 8, 18, 2,  61, 56, 14};
  uint64_t c[5], d[5], b[25];
  unsigned r, x, y;
  for (r = 0; r < 24; r++) {
    for (x = 0; x < 5; x++)
      c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
    for (x = 0; x < 5; x++)
      d[x] = c[(x + 4) % 5] ^ rol(c[(x + 1) % 5], 1);
    for (y = 0; y < 5; y++)
      for (x = 0; x < 5; x++)
        b[y + 5 * ((2 * x + 3 * y) % 5)] =
            rol(a[x + 5 * y] ^ d[x], rotation[x + 5 * y]);
    for (y = 0; y < 5; y++)
      for (x = 0; x < 5; x++)
        a[x + 5 * y] =
            b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y]);
    a[0] ^= rc[r];
  }
  mlkem_zeroize(c, sizeof c);
  mlkem_zeroize(d, sizeof d);
  mlkem_zeroize(b, sizeof b);
}
void mlkem_xof_init(mlkem_xof *x, size_t rate) {
  memset(x, 0, sizeof *x);
  x->rate = rate;
}
void mlkem_xof_absorb(mlkem_xof *x, const uint8_t *in, size_t n) {
  size_t i;
  for (i = 0; i < n; i++) {
    x->s[x->pos / 8] ^= (uint64_t)in[i] << ((x->pos % 8) * 8);
    if (++x->pos == x->rate) {
      permutation(x->s);
      x->pos = 0;
    }
  }
}
void mlkem_xof_final(mlkem_xof *x, uint8_t suffix) {
  x->s[x->pos / 8] ^= (uint64_t)suffix << ((x->pos % 8) * 8);
  x->s[(x->rate - 1) / 8] ^= UINT64_C(0x80) << (((x->rate - 1) % 8) * 8);
  permutation(x->s);
  x->pos = 0;
}
void mlkem_xof_squeeze(mlkem_xof *x, uint8_t *out, size_t n) {
  size_t i;
  for (i = 0; i < n; i++) {
    if (x->pos == x->rate) {
      permutation(x->s);
      x->pos = 0;
    }
    out[i] = (uint8_t)(x->s[x->pos / 8] >> ((x->pos % 8) * 8));
    x->pos++;
  }
}
int mlkem_sw_hash(void *user, unsigned mode, const uint8_t *in, size_t n,
                  uint8_t *out, size_t count) {
  mlkem_xof x;
  (void)user;
  if (mode > 3 || (!in && n) || (!out && count) || (mode == 0 && count != 64) ||
      (mode == 3 && count != 32))
    return MLKEM_ERR_INPUT;
  mlkem_xof_init(&x, mode == 0 ? 72 : (mode == 1 ? 168 : 136));
  mlkem_xof_absorb(&x, in, n);
  mlkem_xof_final(&x, mode == 0 || mode == 3 ? 6 : 31);
  mlkem_xof_squeeze(&x, out, count);
  mlkem_zeroize(&x, sizeof x);
  return 0;
}
