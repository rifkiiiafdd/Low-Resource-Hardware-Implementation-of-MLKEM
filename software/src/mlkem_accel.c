#include "mlkem_accel.h"
static int rd(mlkem_accel *a, uint32_t reg, uint32_t *v) {
  return a->read32(a->user, reg, v) ? MLKEM_ERR_BACKEND : 0;
}
static int wr(mlkem_accel *a, uint32_t reg, uint32_t v) {
  return a->write32(a->user, reg, v) ? MLKEM_ERR_BACKEND : 0;
}
static int wait_bits(mlkem_accel *a, uint32_t mask, uint32_t expected,
                     int check_error) {
  uint32_t i, s;
  for (i = 0; i < a->poll_limit; i++) {
    if (rd(a, MLKEM_REG_STATUS, &s))
      return MLKEM_ERR_BACKEND;
    a->last_status = s;
    if (check_error && (s & 4))
      return MLKEM_ERR_BACKEND;
    if ((s & mask) == expected)
      return 0;
  }
  return MLKEM_ERR_BACKEND;
}
int mlkem_accel_init(mlkem_accel *a, void *user, mlkem_bus_read_fn r,
                     mlkem_bus_write_fn w, uint32_t limit) {
  uint32_t id;
  if (!a || !r || !w || !limit)
    return MLKEM_ERR_INPUT;
  a->user = user;
  a->read32 = r;
  a->write32 = w;
  a->poll_limit = limit;
  a->last_status = 0;
  if (rd(a, MLKEM_REG_ID, &id) || id != 0x4d4b0100u)
    return MLKEM_ERR_BACKEND;
  return mlkem_accel_reset(a);
}
int mlkem_accel_reset(mlkem_accel *a) {
  if (wr(a, MLKEM_REG_CONTROL, 2))
    return MLKEM_ERR_BACKEND;
  return wait_bits(a, 1, 0, 0);
}
void mlkem_accel_backend(mlkem_backend *b, mlkem_accel *a, int use_hash) {
  b->user = a;
  b->poly = mlkem_accel_poly;
  b->hash = use_hash ? mlkem_accel_hash : NULL;
}
static int start(mlkem_accel *a, unsigned op, unsigned sa, unsigned sb,
                 unsigned dst, unsigned mode) {
  if (wait_bits(a, 1, 0, 0) ||
      wr(a, MLKEM_REG_COMMAND,
         op | (sa << 4) | (sb << 8) | (dst << 12) | (mode << 16)))
    return MLKEM_ERR_BACKEND;
  return wr(a, MLKEM_REG_CONTROL, 1);
}
static int finish(mlkem_accel *a) {
  if (wait_bits(a, 3, 2, 1))
    return MLKEM_ERR_BACKEND;
  return wr(a, MLKEM_REG_CONTROL, 12);
}
static int trng_seed(mlkem_accel *hw, uint8_t seed[32]) {
  unsigned i, j;
  uint32_t ignored, meta, status, word;
  if (start(hw, 9, 0, 0, 0, 0))
    return MLKEM_ERR_BACKEND;
  /* Command 9 emits G(seed || 02). Drain all 8 words so busy can end.
     This digest is not used as d/z or as G(d || k) for the KEM. */
  for (i = 0; i < 8; i++) {
    if (wait_bits(hw, 128, 128, 1) || rd(hw, MLKEM_REG_HASH_OUT_LO, &ignored) ||
        rd(hw, MLKEM_REG_HASH_OUT_HI, &ignored) ||
        rd(hw, MLKEM_REG_HASH_META, &meta))
      return MLKEM_ERR_BACKEND;
    if ((meta & 255) != 255 || ((meta >> 8) & 1) != (i == 7) || !(meta & 512))
      return MLKEM_ERR_BACKEND;
  }
  if (finish(hw) || rd(hw, MLKEM_REG_STATUS, &status))
    return MLKEM_ERR_BACKEND;
  hw->last_status = status;
  if (!(status & 8) || (status & 5))
    return MLKEM_ERR_BACKEND;
  for (i = 0; i < 8; i++) {
    if (rd(hw, MLKEM_REG_SEED + 4 * i, &word))
      return MLKEM_ERR_BACKEND;
    for (j = 0; j < 4; j++)
      seed[4 * i + j] = (uint8_t)(word >> (8 * j));
  }
  return 0;
}
int mlkem_accel_random(void *user, uint8_t *out, size_t n) {
  mlkem_accel *hw = (mlkem_accel *)user;
  uint8_t seed[32];
  size_t offset, count, i;
  if (!hw || !hw->read32 || !hw->write32 || (!out && n))
    return MLKEM_ERR_INPUT;
  for (offset = 0; offset < n; offset += count) {
    if (trng_seed(hw, seed)) {
      mlkem_zeroize(seed, sizeof seed);
      mlkem_zeroize(out, n);
      return MLKEM_ERR_BACKEND;
    }
    count = n - offset < 32 ? n - offset : 32;
    for (i = 0; i < count; i++)
      out[offset + i] = seed[i];
    mlkem_zeroize(seed, sizeof seed);
  }
  return 0;
}
static int load(mlkem_accel *a, unsigned slot, const uint16_t *p) {
  unsigned i;
  for (i = 0; i < 256; i++)
    if (p[i] >= 3329)
      return MLKEM_ERR_INPUT;
  for (i = 0; i < 128; i++)
    if (wr(a, MLKEM_RAM_BASE + 512 * slot + 4 * i,
           (uint32_t)p[2 * i] | ((uint32_t)p[2 * i + 1] << 12)))
      return MLKEM_ERR_BACKEND;
  return 0;
}
static int fetch(mlkem_accel *a, unsigned slot, uint16_t *p) {
  unsigned i;
  uint32_t v;
  for (i = 0; i < 128; i++) {
    if (rd(a, MLKEM_RAM_BASE + 512 * slot + 4 * i, &v))
      return MLKEM_ERR_BACKEND;
    p[2 * i] = (uint16_t)(v & 4095);
    p[2 * i + 1] = (uint16_t)((v >> 12) & 4095);
  }
  return 0;
}
int mlkem_accel_poly(void *user, unsigned op, uint16_t *out, const uint16_t *a,
                     const uint16_t *b, const uint16_t *acc) {
  mlkem_accel *hw = (mlkem_accel *)user;
  int rc;
  if (!hw || !out || !a || op > 4 || (op >= 2 && !b) || (op == 3 && !acc))
    return MLKEM_ERR_INPUT;
  if (wait_bits(hw, 1, 0, 0))
    return MLKEM_ERR_BACKEND;
  rc = load(hw, 0, a);
  if (rc)
    return rc;
  if (op >= 2) {
    rc = load(hw, 1, b);
    if (rc)
      return rc;
  }
  if (op == 3) {
    rc = load(hw, 2, acc);
    if (rc)
      return rc;
  }
  if (start(hw, op, 0, 1, 2, 0) || finish(hw))
    return MLKEM_ERR_BACKEND;
  return fetch(hw, op < 2 ? 0 : 2, out);
}
int mlkem_accel_hash(void *user, unsigned mode, const uint8_t *in, size_t n,
                     uint8_t *out, size_t count) {
  mlkem_accel *hw = (mlkem_accel *)user;
  size_t i, j, part;
  uint32_t lo, hi, meta, w[2];
  if (!hw || mode > 3 || (!in && n) || !out || !count || n > 65535 ||
      count > 65535 || (mode == 0 && count != 64) || (mode == 3 && count != 32))
    return MLKEM_ERR_INPUT;
  if (wait_bits(hw, 1, 0, 0) ||
      wr(hw, MLKEM_REG_LENGTHS, (uint32_t)n | ((uint32_t)count << 16)) ||
      start(hw, 7, 0, 0, 0, mode))
    return MLKEM_ERR_BACKEND;
  for (i = 0; i < n; i += 8) {
    w[0] = w[1] = 0;
    part = n - i < 8 ? n - i : 8;
    for (j = 0; j < part; j++)
      w[j / 4] |= (uint32_t)in[i + j] << ((j % 4) * 8);
    if (wr(hw, MLKEM_REG_HASH_IN_LO, w[0]) || wait_bits(hw, 64, 64, 1) ||
        wr(hw, MLKEM_REG_HASH_IN_HI, w[1]))
      return MLKEM_ERR_BACKEND;
  }
  for (i = 0; i < count; i += 8) {
    if (wait_bits(hw, 128, 128, 1) || rd(hw, MLKEM_REG_HASH_OUT_LO, &lo) ||
        rd(hw, MLKEM_REG_HASH_OUT_HI, &hi) ||
        rd(hw, MLKEM_REG_HASH_META, &meta))
      return MLKEM_ERR_BACKEND;
    part = count - i < 8 ? count - i : 8;
    w[0] = lo;
    w[1] = hi;
    if ((meta & 255) != (255u >> (8 - part)) ||
        ((meta >> 8) & 1) != (i + part == count) || !(meta & 512))
      return MLKEM_ERR_BACKEND;
    for (j = 0; j < part; j++)
      out[i + j] = (uint8_t)(w[j / 4] >> ((j % 4) * 8));
  }
  return finish(hw);
}
int mlkem_accel_encode(mlkem_accel *hw, const uint16_t p[256],
                       uint8_t out[384]) {
  unsigned i;
  uint32_t v;
  int rc;
  if (!hw || !p || !out)
    return MLKEM_ERR_INPUT;
  if (wait_bits(hw, 1, 0, 0))
    return MLKEM_ERR_BACKEND;
  rc = load(hw, 0, p);
  if (rc)
    return rc;
  if (start(hw, 5, 0, 0, 0, 0))
    return MLKEM_ERR_BACKEND;
  for (i = 0; i < 384; i++) {
    if (wait_bits(hw, 32, 32, 1) || rd(hw, MLKEM_REG_BYTE_OUT, &v))
      return MLKEM_ERR_BACKEND;
    out[i] = (uint8_t)v;
  }
  return finish(hw);
}
int mlkem_accel_decode(mlkem_accel *hw, const uint8_t in[384],
                       uint16_t p[256]) {
  unsigned i;
  if (!hw || !p || !in)
    return MLKEM_ERR_INPUT;
  if (start(hw, 6, 0, 0, 0, 0))
    return MLKEM_ERR_BACKEND;
  for (i = 0; i < 384; i++)
    if (wait_bits(hw, 16, 16, 1) || wr(hw, MLKEM_REG_BYTE_IN, in[i]))
      return MLKEM_ERR_BACKEND;
  if (finish(hw))
    return MLKEM_ERR_BACKEND;
  return fetch(hw, 0, p);
}
static void barrier(void) {
#if defined(__arm__) || defined(__aarch64__)
  __asm__ volatile("dmb sy" ::: "memory");
#elif defined(__GNUC__) && !defined(__TINYC__)
  __asm__ volatile("" ::: "memory");
#endif
}
int mlkem_mmio_read32(void *base, uint32_t offset, uint32_t *out) {
  volatile uint32_t *p = (volatile uint32_t *)base;
  if (!p || !out || offset >= MLKEM_MMIO_SPAN || (offset & 3))
    return MLKEM_ERR_INPUT;
  barrier();
  *out = p[offset / 4];
  barrier();
  return 0;
}
int mlkem_mmio_write32(void *base, uint32_t offset, uint32_t value) {
  volatile uint32_t *p = (volatile uint32_t *)base;
  if (!p || offset >= MLKEM_MMIO_SPAN || (offset & 3))
    return MLKEM_ERR_INPUT;
  barrier();
  p[offset / 4] = value;
  barrier();
  return 0;
}
