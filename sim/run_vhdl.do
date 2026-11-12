# Questa run script for the VHDL simulations.
# Registers without a reset value are 'U' until the power-on reset releases
# them (X in the SystemVerilog original). numeric_std reports this once at
# time 0 when concurrent statements are first evaluated, so its metavalue
# warnings are suppressed for the time-0 delta cycles only.
set NumericStdNoWarnings 1
run 0
set NumericStdNoWarnings 0
run -all
quit -f
