/* Linux HPS example. Physical base is supplied by the actual Platform Designer
 * map. */
#define _FILE_OFFSET_BITS 64
#include "mlkem_accel.h"
#include "mlkem_rng.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
static int random_bytes(void *user, uint8_t *out, size_t n) {
  FILE *f;
  size_t got;
  (void)user;
  f = fopen("/dev/urandom", "rb");
  if (!f)
    return -1;
  got = fread(out, 1, n, f);
  fclose(f);
  return got == n ? 0 : -1;
}
int main(int argc, char **argv) {
  mlkem_ctx ctx;
  mlkem_accel hw;
  mlkem_backend backend;
  mlkem_seed_rng seed_rng;
  int rc = 1, fd = -1;
  void *mapping = MAP_FAILED;
  size_t mapping_size = 0;
  unsigned set = 512;
  char *end;
  uint8_t ek[MLKEM_MAX_EK], dk[MLKEM_MAX_DK], ct[MLKEM_MAX_CT], ss1[32],
      ss2[32];
  if (argc < 2 ||
      (strcmp(argv[1], "--software") && strcmp(argv[1], "--mmio"))) {
    fprintf(stderr,
            "Usage: %s --software [512|768|1024]\n       %s --mmio "
            "PHYSICAL_BASE [512|768|1024]\n",
            argv[0], argv[0]);
    return 1;
  }
  if (!strcmp(argv[1], "--mmio")) {
    unsigned long long physical, aligned;
    long page;
    size_t delta;
    if (argc < 3 || argc > 4)
      return 1;
    errno = 0;
    physical = strtoull(argv[2], &end, 0);
    if (errno || end == argv[2] || *end || (physical & 3u) ||
        physical > 0x100000000ULL - MLKEM_MMIO_SPAN)
      return 1;
    if (argc == 4) {
      set = (unsigned)strtoul(argv[3], &end, 10);
      if (*end)
        return 1;
    }
    page = sysconf(_SC_PAGESIZE);
    if (page <= 0)
      return 1;
    aligned = physical & ~((unsigned long long)page - 1);
    delta = (size_t)(physical - aligned);
    mapping_size =
        (MLKEM_MMIO_SPAN + delta + (size_t)page - 1) & ~((size_t)page - 1);
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
      perror("/dev/mem");
      goto cleanup;
    }
    mapping = mmap(NULL, mapping_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
                   (off_t)aligned);
    if (mapping == MAP_FAILED) {
      perror("mmap");
      goto cleanup;
    }
    if (mlkem_accel_init(&hw, (uint8_t *)mapping + delta, mlkem_mmio_read32,
                         mlkem_mmio_write32, 10000000)) {
      fprintf(stderr, "Accelerator ID/reset failed\n");
      goto cleanup;
    }
    mlkem_accel_backend(&backend, &hw, 1);
    if (mlkem_init(&ctx, set, &backend))
      goto cleanup;
  } else {
    if (argc > 3)
      return 1;
    if (argc == 3) {
      set = (unsigned)strtoul(argv[2], &end, 10);
      if (*end)
        return 1;
    }
    if (mlkem_init(&ctx, set, NULL))
      goto cleanup;
  }
  mlkem_seed_rng_init(&seed_rng, mapping != MAP_FAILED ? &hw : NULL,
                      random_bytes, NULL);
  if (mlkem_seed_source() == MLKEM_RNG_TRNG && mapping == MAP_FAILED) {
    fprintf(stderr,
            "Hardware TRNG d/z requires --mmio and the FPGA accelerator\n");
    goto cleanup;
  }
  printf("d/z source: %s\n", mlkem_seed_source() == MLKEM_RNG_TRNG
                                 ? "hardware TRNG (two fresh seed sessions)"
                                 : "CPU RNG (/dev/urandom)");
  if (mlkem_keygen(&ctx, ek, ctx.ek_bytes, dk, ctx.dk_bytes, mlkem_seed_random,
                   &seed_rng)) {
    fprintf(stderr, "KeyGen failed\n");
    goto cleanup;
  }
  if (mlkem_encaps(&ctx, ct, ctx.ct_bytes, ss1, ek, ctx.ek_bytes, random_bytes,
                   NULL)) {
    fprintf(stderr, "Encaps failed\n");
    goto cleanup;
  }
  if (mlkem_decaps(&ctx, ss2, ct, ctx.ct_bytes, dk, ctx.dk_bytes)) {
    fprintf(stderr, "Decaps failed\n");
    goto cleanup;
  }
  if (memcmp(ss1, ss2, 32)) {
    fprintf(stderr, "Shared secret mismatch\n");
    goto cleanup;
  }
  printf("PASS ML-KEM-%u: ek=%zu dk=%zu ciphertext=%zu shared-secret=32 bytes "
         "(%s)\n",
         set, ctx.ek_bytes, ctx.dk_bytes, ctx.ct_bytes, argv[1]);
  rc = 0;
cleanup:
  mlkem_zeroize(dk, sizeof dk);
  mlkem_zeroize(ss1, sizeof ss1);
  mlkem_zeroize(ss2, sizeof ss2);
  if (mapping != MAP_FAILED)
    munmap(mapping, mapping_size);
  if (fd >= 0)
    close(fd);
  return rc;
}
