package require qsys
set_module_property NAME mlkem_accel
set_module_property DISPLAY_NAME "ML-KEM component accelerator (ARM Avalon-MM)"
set_module_property VERSION 1.0
set_module_property GROUP "Cryptography"
set_module_property DESCRIPTION "Register wrapper around shared-memory ML-KEM component TOP; full KEM controller executes on ARM."
set_module_property AUTHOR "ML-KEM project"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE false
set_module_property INTERNAL false
set_module_property OPAQUE_ADDRESS_MAP true

add_parameter USE_EXTERNAL_ENTROPY INTEGER 0
set_parameter_property USE_EXTERNAL_ENTROPY DISPLAY_NAME "Use external raw entropy"
set_parameter_property USE_EXTERNAL_ENTROPY DESCRIPTION "Default 0 includes internal physical ring oscillators; 1 uses entropy_raw. Simulations define TRNG_SIM only."
set_parameter_property USE_EXTERNAL_ENTROPY ALLOWED_RANGES {0 1}
set_parameter_property USE_EXTERNAL_ENTROPY HDL_PARAMETER true

foreach fileset {QUARTUS_SYNTH SIM_VERILOG SIM_VHDL} {
    add_fileset $fileset $fileset "" ""
    set_fileset_property $fileset TOP_LEVEL mlkem_avalon_wrapper
    foreach mod {mlkem_avalon_wrapper mlkem_top mlkem_pau_engine mlkem_transcoder ram_poly pau_core pau_modmul pau_zeta_rom sha3_keccak_core trng_core trng_conditioner trng_sha3_bridge ring_osc von_neumann} {
        add_fileset_file ${mod}.v VERILOG PATH ../rtl/${mod}.v
    }
}
add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock clk clk Input 1
add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset rst_n reset_n Input 1
add_interface avalon avalon end
set_interface_property avalon associatedClock clock
set_interface_property avalon associatedReset reset
set_interface_property avalon addressUnits SYMBOLS
set_interface_property avalon bitsPerSymbol 8
set_interface_property avalon explicitAddressSpan 16384
set_interface_property avalon maximumPendingReadTransactions 1
set_interface_property avalon readLatency 0
set_interface_property avalon readWaitTime 0
set_interface_property avalon writeWaitTime 0
add_interface_port avalon avs_address address Input 14
add_interface_port avalon avs_read read Input 1
add_interface_port avalon avs_write write Input 1
add_interface_port avalon avs_writedata writedata Input 32
add_interface_port avalon avs_byteenable byteenable Input 4
add_interface_port avalon avs_readdata readdata Output 32
add_interface_port avalon avs_readdatavalid readdatavalid Output 1
add_interface_port avalon avs_waitrequest waitrequest Output 1
add_interface interrupt interrupt start
set_interface_property interrupt associatedClock clock
set_interface_property interrupt associatedReset reset
set_interface_property interrupt associatedAddressablePoint avalon
add_interface_port interrupt irq irq Output 1
add_interface entropy conduit end
set_interface_property entropy associatedClock clock
set_interface_property entropy associatedReset reset
add_interface_port entropy entropy_raw export Input 8
