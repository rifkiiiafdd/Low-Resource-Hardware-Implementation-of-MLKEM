#ifndef MLKEM_ACCEL_H
#define MLKEM_ACCEL_H
#include "mlkem.h"
enum {
  MLKEM_REG_ID = 0x00,
  MLKEM_REG_CONTROL = 0x04,
  MLKEM_REG_STATUS = 0x08,
  MLKEM_REG_COMMAND = 0x0c,
  MLKEM_REG_LENGTHS = 0x10,
  MLKEM_REG_SLOTS = 0x14,
  MLKEM_REG_DEBUG = 0x18,
  MLKEM_REG_IRQ_ENABLE = 0x1c,
  MLKEM_REG_BYTE_IN = 0x20,
  MLKEM_REG_BYTE_OUT = 0x24,
  MLKEM_REG_HASH_IN_LO = 0x28,
  MLKEM_REG_HASH_IN_HI = 0x2c,
  MLKEM_REG_HASH_OUT_LO = 0x30,
  MLKEM_REG_HASH_OUT_HI = 0x34,
  MLKEM_REG_HASH_META = 0x38,
  MLKEM_REG_SEED = 0x40,
  MLKEM_REG_RHO = 0x60,
  MLKEM_REG_SIGMA = 0x80,
  MLKEM_RAM_BASE = 0x1000,
  MLKEM_MMIO_SPAN = 0x3000
};
typedef int (*mlkem_bus_read_fn)(void *, uint32_t, uint32_t *);
typedef int (*mlkem_bus_write_fn)(void *, uint32_t, uint32_t);
typedef struct {
  void *user;
  mlkem_bus_read_fn read32;
  mlkem_bus_write_fn write32;
  uint32_t poll_limit;
  uint32_t last_status;
} mlkem_accel;
int mlkem_accel_init(mlkem_accel *, void *, mlkem_bus_read_fn,
                     mlkem_bus_write_fn, uint32_t);
void mlkem_accel_backend(mlkem_backend *, mlkem_accel *, int use_hash);
int mlkem_accel_reset(mlkem_accel *);
/* Fresh 32-byte seed per command 9 session; drains its SHA3 output too. */
int mlkem_accel_random(void *, uint8_t *, size_t);
int mlkem_accel_poly(void *, unsigned, uint16_t *, const uint16_t *,
                     const uint16_t *, const uint16_t *);
int mlkem_accel_hash(void *, unsigned, const uint8_t *, size_t, uint8_t *,
                     size_t);
int mlkem_accel_encode(mlkem_accel *, const uint16_t[256], uint8_t[384]);
int mlkem_accel_decode(mlkem_accel *, const uint8_t[384], uint16_t[256]);
/* user is a volatile uint32_t pointer to mapped device memory, not a physical
 * address. */
int mlkem_mmio_read32(void *, uint32_t, uint32_t *);
int mlkem_mmio_write32(void *, uint32_t, uint32_t);
#endif
