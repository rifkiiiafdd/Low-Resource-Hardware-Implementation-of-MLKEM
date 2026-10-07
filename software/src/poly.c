#include "keccak.h"
#include "mlkem.h"
#include <string.h>
#define Q 3329u
void mlkem_zeroize(void *p, size_t n) {
  volatile uint8_t *v = (volatile uint8_t *)p;
  while (n--)
    *v++ = 0;
}
static uint16_t addq(uint16_t a, uint16_t b) {
  return (uint16_t)(((uint32_t)a + b) % Q);
}
static uint16_t subq(uint16_t a, uint16_t b) {
  return (uint16_t)(((uint32_t)a + Q - b) % Q);
}
static uint16_t mulq(uint16_t a, uint16_t b) {
  return (uint16_t)((uint32_t)a * b % Q);
}
static uint16_t halfq(uint16_t a) { return (uint16_t)((a + (a & 1u) * Q) / 2); }
static uint16_t zeta(unsigned i) {
  unsigned j, rev = 0;
  uint16_t a = 17, r = 1;
  for (j = 0; j < 7; j++) {
    rev = (rev << 1) | (i & 1);
    i >>= 1;
  }
  while (rev) {
    if (rev & 1)
      r = mulq(r, a);
    a = mulq(a, a);
    rev >>= 1;
  }
  return r;
}
int mlkem_sw_poly(void *user, unsigned op, uint16_t *out, const uint16_t *a,
                  const uint16_t *b, const uint16_t *acc) {
  unsigned i, j, len, start, k;
  uint16_t z, u, v, t;
  uint16_t temp[256];
  (void)user;
  if (!out || !a || op > 4 || (op >= 2 && !b) || (op == 3 && !acc))
    return MLKEM_ERR_INPUT;
  for (i = 0; i < 256; i++)
    if (a[i] >= Q || (op >= 2 && b[i] >= Q) || (op == 3 && acc[i] >= Q))
      return MLKEM_ERR_INPUT;
  if (op < 2) {
    memcpy(temp, a, sizeof temp);
    k = op == 0 ? 1 : 127;
    for (len = op == 0 ? 128 : 2; op == 0 ? len >= 2 : len <= 128;
         len = op == 0 ? len / 2 : len * 2) {
      for (start = 0; start < 256; start += 2 * len) {
        z = zeta(k);
        k = op == 0 ? k + 1 : k - 1;
        for (j = start; j < start + len; j++) {
          u = temp[j];
          v = temp[j + len];
          if (op == 0) {
            t = mulq(z, v);
            temp[j] = addq(u, t);
            temp[j + len] = subq(u, t);
          } else {
            temp[j] = halfq(addq(u, v));
            temp[j + len] = halfq(mulq(z, subq(v, u)));
          }
        }
      }
    }
  } else if (op == 4)
    for (i = 0; i < 256; i++)
      temp[i] = addq(a[i], b[i]);
  else
    for (i = 0; i < 128; i++) {
      z = zeta(64 + i / 2);
      if (i & 1)
        z = (uint16_t)(Q - z);
      temp[2 * i] = addq(mulq(a[2 * i], b[2 * i]),
                         mulq(z, mulq(a[2 * i + 1], b[2 * i + 1])));
      temp[2 * i + 1] =
          addq(mulq(a[2 * i], b[2 * i + 1]), mulq(a[2 * i + 1], b[2 * i]));
      if (op == 3) {
        temp[2 * i] = addq(temp[2 * i], acc[2 * i]);
        temp[2 * i + 1] = addq(temp[2 * i + 1], acc[2 * i + 1]);
      }
    }
  memcpy(out, temp, sizeof temp);
  mlkem_zeroize(temp, sizeof temp);
  return 0;
}
void mlkem_encode(uint8_t *out, const uint16_t in[256], unsigned bits) {
  unsigned i, j;
  memset(out, 0, 32 * bits);
  for (i = 0; i < 256; i++)
    for (j = 0; j < bits; j++)
      out[(i * bits + j) / 8] |=
          (uint8_t)(((in[i] >> j) & 1u) << ((i * bits + j) % 8));
}
void mlkem_decode(uint16_t out[256], const uint8_t *in, unsigned bits) {
  unsigned i, j;
  for (i = 0; i < 256; i++) {
    out[i] = 0;
    for (j = 0; j < bits; j++)
      out[i] |=
          (uint16_t)(((in[(i * bits + j) / 8] >> ((i * bits + j) % 8)) & 1u)
                     << j);
    if (bits == 12)
      out[i] = (uint16_t)(out[i] % Q);
  }
}
uint16_t mlkem_compress(uint16_t x, unsigned d) {
  return (uint16_t)(((((uint32_t)x << d) + Q / 2) / Q) & ((1u << d) - 1));
}
uint16_t mlkem_decompress(uint16_t x, unsigned d) {
  return (uint16_t)(((uint32_t)x * Q + (1u << (d - 1))) >> d);
}
void mlkem_cbd(uint16_t out[256], const uint8_t *in, unsigned eta) {
  unsigned i, j, bit;
  int v;
  for (i = 0; i < 256; i++) {
    v = 0;
    for (j = 0; j < eta; j++) {
      bit = 2 * i * eta + j;
      v += (in[bit / 8] >> (bit % 8)) & 1;
      bit += eta;
      v -= (in[bit / 8] >> (bit % 8)) & 1;
    }
    out[i] = (uint16_t)((v + (int)Q) % Q);
  }
}
void mlkem_sample_ntt(uint16_t out[256], const uint8_t rho[32], uint8_t i,
                      uint8_t j) {
  mlkem_xof x;
  uint8_t indexes[2] = {i, j}, b[3];
  unsigned n = 0, d1, d2;
  mlkem_xof_init(&x, 168);
  mlkem_xof_absorb(&x, rho, 32);
  mlkem_xof_absorb(&x, indexes, 2);
  mlkem_xof_final(&x, 31);
  while (n < 256) {
    mlkem_xof_squeeze(&x, b, 3);
    d1 = b[0] + 256u * (b[1] & 15);
    d2 = (b[1] >> 4) + 16u * b[2];
    if (d1 < Q)
      out[n++] = (uint16_t)d1;
    if (d2 < Q && n < 256)
      out[n++] = (uint16_t)d2;
  }
  mlkem_zeroize(&x, sizeof x);
}
