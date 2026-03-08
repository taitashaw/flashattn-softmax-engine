# ===========================================================================
# Vivado xsim Simulation Script
# ===========================================================================
# Usage: vivado -mode batch -source sim.tcl
#    OR: vivado -mode gui -source sim.tcl  (for waveform viewer)
# ===========================================================================

set proj_name "flashattn_sim"
set proj_dir  "./sim_project"
set part      "xczu7ev-ffvc1156-2-e"

# RTL sources (relative to vivado/sim_build/ working directory)
set rtl_files [list \
    "../../rtl/pipelined_exp.sv" \
    "../../rtl/online_softmax_exact.sv" \
    "../../rtl/fp8_convert.sv" \
    "../../rtl/flashattn_softmax_top.sv" \
]

# Testbench
set tb_files [list \
    "../../tb/tb_top.sv" \
]

# ---- Create Project ----
create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]
set_property simulator_language "Mixed" [current_project]

# ---- Add Sources ----
foreach f $rtl_files {
    add_files -norecurse $f
}

# ---- Add Simulation Sources ----
foreach f $tb_files {
    add_files -fileset sim_1 -norecurse $f
}

# ---- Set Top Module for Simulation ----
set_property top tb_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# ---- Configure xsim ----
set_property -name {xsim.simulate.runtime} -value {2ms} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.log_all_signals} -value {true} -objects [get_filesets sim_1]

# ---- Launch Simulation ----
puts "============================================"
puts "  Launching xsim Simulation"
puts "============================================"

launch_simulation

# Run simulation
run all

puts "============================================"
puts "  Simulation Complete"
puts "  Waveform: open sim_project/flashattn_sim.sim/sim_1/behav/xsim/tb_top.wdb"
puts "============================================"

# If running in GUI mode, the waveform viewer will stay open.
# If batch mode, close project.
# close_project
