#ifndef MLKEM_KECCAK_H
#define MLKEM_KECCAK_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
  uint64_t s[25];
  size_t rate, pos;
} mlkem_xof;
void mlkem_xof_init(mlkem_xof *, size_t);
void mlkem_xof_absorb(mlkem_xof *, const uint8_t *, size_t);
void mlkem_xof_final(mlkem_xof *, uint8_t);
void mlkem_xof_squeeze(mlkem_xof *, uint8_t *, size_t);
#endif
