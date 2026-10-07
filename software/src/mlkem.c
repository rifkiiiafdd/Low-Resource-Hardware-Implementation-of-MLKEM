/* FIPS 203 Algorithms 13--21, canonical coefficients and normal NTT domain. */
#include "mlkem.h"
#include <string.h>
#define Q 3329u
#define TRY(call)                                                              \
  do {                                                                         \
    rc = (call);                                                               \
    if (rc)                                                                    \
      goto cleanup;                                                            \
  } while (0)
static int hash(const mlkem_ctx *c, unsigned mode, const uint8_t *in, size_t n,
                uint8_t *out, size_t count) {
  return c->backend.hash
             ? c->backend.hash(c->backend.user, mode, in, n, out, count)
             : mlkem_sw_hash(NULL, mode, in, n, out, count);
}
static int poly(const mlkem_ctx *c, unsigned op, uint16_t *out,
                const uint16_t *a, const uint16_t *b, const uint16_t *acc) {
  return c->backend.poly ? c->backend.poly(c->backend.user, op, out, a, b, acc)
                         : mlkem_sw_poly(NULL, op, out, a, b, acc);
}
static int noise(const mlkem_ctx *c, uint16_t out[256], const uint8_t seed[32],
                 uint8_t nonce, unsigned eta) {
  uint8_t in[33], bytes[192];
  int rc;
  memcpy(in, seed, 32);
  in[32] = nonce;
  rc = hash(c, 2, in, 33, bytes, 64 * eta);
  if (!rc)
    mlkem_cbd(out, bytes, eta);
  mlkem_zeroize(in, sizeof in);
  mlkem_zeroize(bytes, sizeof bytes);
  return rc;
}
int mlkem_init(mlkem_ctx *c, unsigned set, const mlkem_backend *backend) {
  if (!c || (set != 512 && set != 768 && set != 1024))
    return MLKEM_ERR_INPUT;
  memset(c, 0, sizeof *c);
  c->k = set / 256;
  c->eta1 = c->k == 2 ? 3 : 2;
  c->du = c->k == 4 ? 11 : 10;
  c->dv = c->k == 4 ? 5 : 4;
  c->ek_bytes = 384 * c->k + 32;
  c->dk_bytes = 768 * c->k + 96;
  c->ct_bytes = 32 * (c->du * c->k + c->dv);
  if (backend)
    c->backend = *backend;
  return 0;
}
int mlkem_check_ek(const mlkem_ctx *c, const uint8_t *ek, size_t n) {
  size_t i;
  unsigned a, b;
  if (!c || !ek || n != c->ek_bytes)
    return MLKEM_ERR_INPUT;
  for (i = 0; i < 384 * c->k; i += 3) {
    a = ek[i] + 256u * (ek[i + 1] & 15);
    b = (ek[i + 1] >> 4) + 16u * ek[i + 2];
    if (a >= Q || b >= Q)
      return MLKEM_ERR_INPUT;
  }
  return 0;
}
int mlkem_check_dk(const mlkem_ctx *c, const uint8_t *dk, size_t n) {
  uint8_t h[32];
  unsigned difference = 0;
  size_t i;
  int rc;
  if (!c || !dk || n != c->dk_bytes)
    return MLKEM_ERR_INPUT;
  rc = hash(c, 3, dk + 384 * c->k, c->ek_bytes, h, 32);
  if (rc)
    return rc;
  for (i = 0; i < 32; i++)
    difference |= h[i] ^ dk[n - 64 + i];
  mlkem_zeroize(h, sizeof h);
  return difference ? MLKEM_ERR_INPUT : 0;
}
int mlkem_keygen_derand(const mlkem_ctx *c, uint8_t *ek, size_t en, uint8_t *dk,
                        size_t dn, const uint8_t d[32], const uint8_t z[32]) {
  uint8_t in[33], g[64], h[32];
  uint16_t sh[4][256], e[256], a[256], t[256];
  unsigned i, j;
  int rc = 0;
  if (!c || !ek || !dk || !d || !z || en != c->ek_bytes || dn != c->dk_bytes)
    return MLKEM_ERR_INPUT;
  memcpy(in, d, 32);
  in[32] = (uint8_t)c->k;
  TRY(hash(c, 0, in, 33, g, 64));
  for (i = 0; i < c->k; i++) {
    TRY(noise(c, sh[i], g + 32, (uint8_t)i, c->eta1));
    TRY(poly(c, 0, sh[i], sh[i], NULL, NULL));
    mlkem_encode(dk + 384 * i, sh[i], 12);
  }
  for (i = 0; i < c->k; i++) {
    TRY(noise(c, e, g + 32, (uint8_t)(c->k + i), c->eta1));
    TRY(poly(c, 0, t, e, NULL, NULL));
    for (j = 0; j < c->k; j++) {
      mlkem_sample_ntt(a, g, (uint8_t)j, (uint8_t)i);
      TRY(poly(c, 3, t, a, sh[j], t));
    }
    mlkem_encode(ek + 384 * i, t, 12);
  }
  memcpy(ek + 384 * c->k, g, 32);
  TRY(hash(c, 3, ek, en, h, 32));
  memcpy(dk + 384 * c->k, ek, en);
  memcpy(dk + dn - 64, h, 32);
  memcpy(dk + dn - 32, z, 32);
cleanup:
  mlkem_zeroize(in, sizeof in);
  mlkem_zeroize(g, sizeof g);
  mlkem_zeroize(h, sizeof h);
  mlkem_zeroize(sh, sizeof sh);
  mlkem_zeroize(e, sizeof e);
  mlkem_zeroize(a, sizeof a);
  mlkem_zeroize(t, sizeof t);
  if (rc) {
    mlkem_zeroize(ek, en);
    mlkem_zeroize(dk, dn);
  }
  return rc;
}
static int encrypt(const mlkem_ctx *c, uint8_t *ct, const uint8_t *ek,
                   const uint8_t m[32], const uint8_t r[32]) {
  uint16_t yh[4][256], a[256], sum[256], tmp[256], e[256], t[256], mu[256];
  unsigned i, j, n;
  int rc = 0;
  for (i = 0; i < c->k; i++) {
    TRY(noise(c, yh[i], r, (uint8_t)i, c->eta1));
    TRY(poly(c, 0, yh[i], yh[i], NULL, NULL));
  }
  for (i = 0; i < c->k; i++) {
    memset(sum, 0, sizeof sum);
    for (j = 0; j < c->k; j++) {
      mlkem_sample_ntt(a, ek + 384 * c->k, (uint8_t)i, (uint8_t)j);
      TRY(poly(c, 3, sum, a, yh[j], sum));
    }
    TRY(poly(c, 1, tmp, sum, NULL, NULL));
    TRY(noise(c, e, r, (uint8_t)(c->k + i), 2));
    TRY(poly(c, 4, tmp, tmp, e, NULL));
    for (n = 0; n < 256; n++)
      tmp[n] = mlkem_compress(tmp[n], c->du);
    mlkem_encode(ct + 32 * c->du * i, tmp, c->du);
  }
  memset(sum, 0, sizeof sum);
  for (i = 0; i < c->k; i++) {
    mlkem_decode(t, ek + 384 * i, 12);
    TRY(poly(c, 3, sum, t, yh[i], sum));
  }
  TRY(poly(c, 1, tmp, sum, NULL, NULL));
  TRY(noise(c, e, r, (uint8_t)(2 * c->k), 2));
  TRY(poly(c, 4, tmp, tmp, e, NULL));
  mlkem_decode(mu, m, 1);
  for (n = 0; n < 256; n++)
    mu[n] = mlkem_decompress(mu[n], 1);
  TRY(poly(c, 4, tmp, tmp, mu, NULL));
  for (n = 0; n < 256; n++)
    tmp[n] = mlkem_compress(tmp[n], c->dv);
  mlkem_encode(ct + 32 * c->du * c->k, tmp, c->dv);
cleanup:
  mlkem_zeroize(yh, sizeof yh);
  mlkem_zeroize(a, sizeof a);
  mlkem_zeroize(sum, sizeof sum);
  mlkem_zeroize(tmp, sizeof tmp);
  mlkem_zeroize(e, sizeof e);
  mlkem_zeroize(t, sizeof t);
  mlkem_zeroize(mu, sizeof mu);
  return rc;
}
static int decrypt(const mlkem_ctx *c, uint8_t m[32], const uint8_t *dk,
                   const uint8_t *ct) {
  uint16_t u[256], s[256], sum[256], v[256], tmp[256];
  unsigned i, n;
  int rc = 0;
  memset(sum, 0, sizeof sum);
  for (i = 0; i < c->k; i++) {
    mlkem_decode(u, ct + 32 * c->du * i, c->du);
    for (n = 0; n < 256; n++)
      u[n] = mlkem_decompress(u[n], c->du);
    TRY(poly(c, 0, u, u, NULL, NULL));
    mlkem_decode(s, dk + 384 * i, 12);
    TRY(poly(c, 3, sum, s, u, sum));
  }
  TRY(poly(c, 1, tmp, sum, NULL, NULL));
  mlkem_decode(v, ct + 32 * c->du * c->k, c->dv);
  for (n = 0; n < 256; n++)
    v[n] = mlkem_compress(
        (uint16_t)((mlkem_decompress(v[n], c->dv) + Q - tmp[n]) % Q), 1);
  mlkem_encode(m, v, 1);
cleanup:
  mlkem_zeroize(u, sizeof u);
  mlkem_zeroize(s, sizeof s);
  mlkem_zeroize(sum, sizeof sum);
  mlkem_zeroize(v, sizeof v);
  mlkem_zeroize(tmp, sizeof tmp);
  return rc;
}
int mlkem_encaps_derand(const mlkem_ctx *c, uint8_t *ct, size_t cn,
                        uint8_t ss[32], const uint8_t *ek, size_t en,
                        const uint8_t m[32]) {
  uint8_t in[64], g[64];
  int rc = 0;
  if (!c || !ct || !ss || !m || cn != c->ct_bytes)
    return MLKEM_ERR_INPUT;
  rc = mlkem_check_ek(c, ek, en);
  if (rc)
    return rc;
  memcpy(in, m, 32);
  TRY(hash(c, 3, ek, en, in + 32, 32));
  TRY(hash(c, 0, in, 64, g, 64));
  TRY(encrypt(c, ct, ek, m, g + 32));
  memcpy(ss, g, 32);
cleanup:
  mlkem_zeroize(in, sizeof in);
  mlkem_zeroize(g, sizeof g);
  if (rc) {
    mlkem_zeroize(ss, 32);
    mlkem_zeroize(ct, cn);
  }
  return rc;
}
int mlkem_decaps(const mlkem_ctx *c, uint8_t ss[32], const uint8_t *ct,
                 size_t cn, const uint8_t *dk, size_t dn) {
  uint8_t m[32], in[64], g[64], reject_in[32 + MLKEM_MAX_CT], rejection[32],
      check[MLKEM_MAX_CT];
  unsigned diff = 0, mask;
  size_t i;
  int rc = 0;
  if (!c || !ss || !ct || cn != c->ct_bytes)
    return MLKEM_ERR_INPUT;
  rc = mlkem_check_dk(c, dk, dn);
  if (rc)
    return rc;
  TRY(decrypt(c, m, dk, ct));
  memcpy(in, m, 32);
  memcpy(in + 32, dk + dn - 64, 32);
  TRY(hash(c, 0, in, 64, g, 64));
  memcpy(reject_in, dk + dn - 32, 32);
  memcpy(reject_in + 32, ct, cn);
  TRY(hash(c, 2, reject_in, 32 + cn, rejection, 32));
  TRY(encrypt(c, check, dk + 384 * c->k, m, g + 32));
  for (i = 0; i < cn; i++)
    diff |= ct[i] ^ check[i];
  mask = 0u - ((diff | (0u - diff)) >> 31);
  for (i = 0; i < 32; i++)
    ss[i] = (uint8_t)((g[i] & ~mask) | (rejection[i] & mask));
cleanup:
  mlkem_zeroize(m, sizeof m);
  mlkem_zeroize(in, sizeof in);
  mlkem_zeroize(g, sizeof g);
  mlkem_zeroize(reject_in, sizeof reject_in);
  mlkem_zeroize(rejection, sizeof rejection);
  mlkem_zeroize(check, sizeof check);
  if (rc)
    mlkem_zeroize(ss, 32);
  return rc;
}
int mlkem_keygen(const mlkem_ctx *c, uint8_t *ek, size_t en, uint8_t *dk,
                 size_t dn, mlkem_random_fn rng, void *user) {
  uint8_t seeds[64];
  int rc;
  if (!rng)
    return MLKEM_ERR_RANDOM;
  rc = rng(user, seeds, sizeof seeds);
  if (!rc)
    rc = mlkem_keygen_derand(c, ek, en, dk, dn, seeds, seeds + 32);
  else
    rc = MLKEM_ERR_RANDOM;
  mlkem_zeroize(seeds, sizeof seeds);
  return rc;
}
int mlkem_encaps(const mlkem_ctx *c, uint8_t *ct, size_t cn, uint8_t ss[32],
                 const uint8_t *ek, size_t en, mlkem_random_fn rng,
                 void *user) {
  uint8_t m[32];
  int rc;
  if (!rng)
    return MLKEM_ERR_RANDOM;
  rc = rng(user, m, 32);
  if (!rc)
    rc = mlkem_encaps_derand(c, ct, cn, ss, ek, en, m);
  else
    rc = MLKEM_ERR_RANDOM;
  mlkem_zeroize(m, sizeof m);
  return rc;
}
