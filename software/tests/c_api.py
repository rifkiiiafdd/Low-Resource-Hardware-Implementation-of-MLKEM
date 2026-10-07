"""ctypes declarations for executing the actual compiled C, never a Python KEM."""
import ctypes as C
U8=C.c_uint8;U16=C.c_uint16;U32=C.c_uint32;SZ=C.c_size_t;VP=C.c_void_p
READ=C.CFUNCTYPE(C.c_int,VP,U32,C.POINTER(U32))
WRITE=C.CFUNCTYPE(C.c_int,VP,U32,U32)
HASH=C.CFUNCTYPE(C.c_int,VP,C.c_uint,VP,SZ,VP,SZ)
POLY=C.CFUNCTYPE(C.c_int,VP,C.c_uint,VP,VP,VP,VP)
RNG=C.CFUNCTYPE(C.c_int,VP,VP,SZ)
class Backend(C.Structure):_fields_=[('user',VP),('hash',VP),('poly',VP)]
class Context(C.Structure):
    _fields_=[('k',C.c_uint),('eta1',C.c_uint),('du',C.c_uint),('dv',C.c_uint),('ek_bytes',SZ),('dk_bytes',SZ),('ct_bytes',SZ),('backend',Backend)]
class Accel(C.Structure):
    _fields_=[('user',VP),('read32',READ),('write32',WRITE),('poll_limit',U32),('last_status',U32)]
class SeedRng(C.Structure):
    _fields_=[('accel',C.POINTER(Accel)),('cpu_random',RNG),('cpu_user',VP)]
def buffer(data):
    if isinstance(data,int):return (U8*data)()
    return (U8*len(data)).from_buffer_copy(data)
def coeffs(data):return (U16*256)(*data)
def load_library(path):
    lib=C.CDLL(str(path))
    prototypes={
        'mlkem_init':[C.POINTER(Context),C.c_uint,C.POINTER(Backend)],
        'mlkem_keygen_derand':[C.POINTER(Context),VP,SZ,VP,SZ,VP,VP],
        'mlkem_encaps_derand':[C.POINTER(Context),VP,SZ,VP,VP,SZ,VP],
        'mlkem_decaps':[C.POINTER(Context),VP,VP,SZ,VP,SZ],
        'mlkem_check_ek':[C.POINTER(Context),VP,SZ],'mlkem_check_dk':[C.POINTER(Context),VP,SZ],
        'mlkem_keygen':[C.POINTER(Context),VP,SZ,VP,SZ,RNG,VP],
        'mlkem_encaps':[C.POINTER(Context),VP,SZ,VP,VP,SZ,RNG,VP],
        'mlkem_sw_hash':[VP,C.c_uint,VP,SZ,VP,SZ],
        'mlkem_sw_poly':[VP,C.c_uint,VP,VP,VP,VP],
        'mlkem_accel_init':[C.POINTER(Accel),VP,READ,WRITE,U32],
        'mlkem_accel_hash':[VP,C.c_uint,VP,SZ,VP,SZ],
        'mlkem_accel_poly':[VP,C.c_uint,VP,VP,VP,VP],
        'mlkem_accel_encode':[C.POINTER(Accel),VP,VP],
        'mlkem_accel_decode':[C.POINTER(Accel),VP,VP],
        'mlkem_accel_reset':[C.POINTER(Accel)]}
    prototypes.update({'mlkem_accel_random':[VP,VP,SZ],'mlkem_seed_random':[VP,VP,SZ],'mlkem_seed_source':[]})
    for name,args in prototypes.items():getattr(lib,name).argtypes=args;getattr(lib,name).restype=C.c_int
    lib.mlkem_accel_backend.argtypes=[C.POINTER(Backend),C.POINTER(Accel),C.c_int];lib.mlkem_accel_backend.restype=None
    lib.mlkem_seed_rng_init.argtypes=[C.POINTER(SeedRng),C.POINTER(Accel),RNG,VP];lib.mlkem_seed_rng_init.restype=None
    lib.mlkem_compress.argtypes=[U16,C.c_uint];lib.mlkem_compress.restype=U16
    lib.mlkem_decompress.argtypes=[U16,C.c_uint];lib.mlkem_decompress.restype=U16
    lib.mlkem_encode.argtypes=[VP,VP,C.c_uint];lib.mlkem_encode.restype=None
    lib.mlkem_decode.argtypes=[VP,VP,C.c_uint];lib.mlkem_decode.restype=None
    lib.mlkem_cbd.argtypes=[VP,VP,C.c_uint];lib.mlkem_cbd.restype=None
    lib.mlkem_sample_ntt.argtypes=[VP,VP,U8,U8];lib.mlkem_sample_ntt.restype=None
    return lib
