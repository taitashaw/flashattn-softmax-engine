# ===========================================================================
# Vivado Synthesis + Implementation + Bitstream Script
# ===========================================================================
# Usage: cd vivado && mkdir -p synth_build && cd synth_build && vivado -mode batch -source ../synth.tcl
#
# Target: ZCU104 (xczu7ev-ffvc1156-2-e)
# Top: flashattn_softmax_top (standalone RTL, no block design)
#
# This synthesizes the raw RTL to get:
#   - Resource utilization (LUT, FF, DSP, BRAM)
#   - Timing report (Fmax)
#   - Power estimate
# ===========================================================================

set proj_name "flashattn_synth"
set proj_dir  "."
set part      "xczu7ev-ffvc1156-2-e"
set top       "flashattn_softmax_top"

set rtl_files [list \
    "../../rtl/pipelined_exp.sv" \
    "../../rtl/online_softmax_exact.sv" \
    "../../rtl/fp8_convert.sv" \
    "../../rtl/flashattn_softmax_top.sv" \
]

# ---- Create Project ----
create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]

# ---- Add Sources ----
foreach f $rtl_files {
    add_files -norecurse $f
}

set_property top $top [current_fileset]

# ---- Timing Constraints ----
set xdc_file "timing.xdc"
set xdc_fd [open $xdc_file w]
puts $xdc_fd "# 400 MHz clock constraint"
puts $xdc_fd "create_clock -period 2.500 -name sys_clk \[get_ports clk\]"
puts $xdc_fd ""
puts $xdc_fd "# Reset is async — false path"
puts $xdc_fd "set_false_path -from \[get_ports rst_n\]"
puts $xdc_fd ""
puts $xdc_fd "# All I/O ports are false path for standalone synthesis."
puts $xdc_fd "# In the SoC block design, these connect internally to the"
puts $xdc_fd "# AXI interconnect — not to external pads. The I/O timing"
puts $xdc_fd "# through OBUFs is irrelevant. Only register-to-register"
puts $xdc_fd "# (internal) timing matters for this IP."
puts $xdc_fd "set_false_path -to \[get_ports s_axil_*\]"
puts $xdc_fd "set_false_path -from \[get_ports s_axil_*\]"
puts $xdc_fd "set_false_path -to \[get_ports irq_done\]"
close $xdc_fd
add_files -fileset constrs_1 $xdc_file

# ---- Run Synthesis ----
puts ""
puts "============================================"
puts "  Running Synthesis (strategy: Performance)"
puts "============================================"
puts ""

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
launch_runs synth_1 -jobs 4
wait_on_run synth_1

# ---- Open Synthesized Design & Report ----
open_run synth_1 -name synth_1

puts ""
puts "============================================"
puts "  SYNTHESIS UTILIZATION REPORT"
puts "============================================"
report_utilization -file utilization_synth.rpt
puts [report_utilization -return_string]

puts ""
puts "============================================"
puts "  SYNTHESIS TIMING REPORT"
puts "============================================"
report_timing_summary -file timing_synth.rpt -max_paths 10
puts [report_timing_summary -return_string]

puts ""
puts "============================================"
puts "  SYNTHESIS POWER ESTIMATE"
puts "============================================"
report_power -file power_synth.rpt
puts [report_power -return_string]

# Save synthesis checkpoint
write_checkpoint -force ${top}_synth.dcp

# ---- Run Implementation ----
puts ""
puts "============================================"
puts "  Running Implementation"
puts "============================================"
puts ""

launch_runs impl_1 -jobs 4
wait_on_run impl_1

open_run impl_1 -name impl_1

puts ""
puts "============================================"
puts "  IMPLEMENTATION UTILIZATION REPORT"
puts "============================================"
report_utilization -file utilization_impl.rpt
puts [report_utilization -return_string]

puts ""
puts "============================================"
puts "  IMPLEMENTATION TIMING REPORT"
puts "============================================"
report_timing_summary -file timing_impl.rpt -max_paths 10
puts [report_timing_summary -return_string]

# Save implementation checkpoint
write_checkpoint -force ${top}_impl.dcp

# ---- Generate Bitstream (standalone — no PS) ----
# NOTE: For a standalone RTL test (no Zynq PS), this generates a partial bitstream.
# For full bitstream with PS, use the block design flow (block_design.tcl).
# Uncomment below if you want standalone bitstream:
#
# launch_runs impl_1 -to_step write_bitstream -jobs 4
# wait_on_run impl_1

puts ""
puts "============================================"
puts "  SYNTHESIS + IMPLEMENTATION COMPLETE"
puts "============================================"
puts ""
puts "  Reports saved:"
puts "    utilization_synth.rpt"
puts "    timing_synth.rpt"
puts "    power_synth.rpt"
puts "    utilization_impl.rpt"
puts "    timing_impl.rpt"
puts ""
puts "  Checkpoints saved:"
puts "    ${top}_synth.dcp"
puts "    ${top}_impl.dcp"
puts ""
puts "  Next: Open in Vivado GUI to inspect:"
puts "    vivado ${top}_impl.dcp"
puts ""

close_project
