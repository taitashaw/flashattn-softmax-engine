# ===========================================================================
# Vivado Block Design — Zynq UltraScale+ SoC Integration
# ===========================================================================
# Creates a complete SoC:
#   - Zynq UltraScale+ PS (ARM Cortex-A53)
#   - AXI Interconnect
#   - flashattn_softmax_top (our IP, connected as AXI4-Lite slave)
#   - PS DDR4 (for weight/activation storage)
#   - IRQ connection (irq_done → PS GIC)
#
# Usage:
#   cd vivado && mkdir -p bd_build && cd bd_build
#   vivado -mode batch -source ../block_design.tcl
#
# OR for interactive block design editing:
#   vivado -mode gui -source ../block_design.tcl
#
# Target: ZCU104 (xczu7ev-ffvc1156-2-e)
# Output: Bitstream + XSA (for Vitis/Petalinux firmware development)
# ===========================================================================

set proj_name  "flashattn_soc"
set proj_dir   "."
set part       "xczu7ev-ffvc1156-2-e"
set board      "xilinx.com:zcu104:part0:1.1"
set bd_name    "flashattn_bd"
set top_module "flashattn_softmax_wrapper"

set rtl_files [list \
    "../../rtl/pipelined_exp.sv" \
    "../../rtl/online_softmax_exact.sv" \
    "../../rtl/fp8_convert.sv" \
    "../../rtl/flashattn_softmax_top.sv" \
    "../../rtl/flashattn_softmax_wrapper.v" \
]

# ===========================================================================
# Step 1: Create Project
# ===========================================================================
puts ""
puts "============================================"
puts "  Step 1: Creating Vivado Project"
puts "============================================"

create_project $proj_name $proj_dir -part $part -force

# Try to set board part (may fail if board files not installed)
catch {set_property board_part $board [current_project]}

set_property target_language Verilog [current_project]

# Add RTL sources
foreach f $rtl_files {
    add_files -norecurse $f
}

update_compile_order -fileset sources_1

# ===========================================================================
# Step 2: Create Block Design
# ===========================================================================
puts ""
puts "============================================"
puts "  Step 2: Creating Block Design"
puts "============================================"

create_bd_design $bd_name

# ---- Add Zynq UltraScale+ PS ----
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ps]

# Apply board preset if available, otherwise configure manually
catch {
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset "1"} $zynq
}

# Configure PS: enable M_AXI_HPM0_FPD for our IP
# GP0 → M_AXI_HPM0_FPD (Full Power Domain)
# GP2 → M_AXI_HPM0_LPD (Low Power Domain)
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0  {1} \
    CONFIG.PSU__USE__M_AXI_GP1  {0} \
    CONFIG.PSU__USE__M_AXI_GP2  {0} \
    CONFIG.PSU__USE__IRQ0       {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {400} \
] $zynq

# ---- Add our Softmax IP as RTL Module ----
# Package the RTL as a module reference in the block design
set softmax_ip [create_bd_cell -type module -reference $top_module softmax_engine]

# ---- Add AXI Interconnect ----
set axi_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0]
set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {1} \
] $axi_ic

# ---- Add Processor System Reset ----
set ps_rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

# ===========================================================================
# Step 3: Connect Block Design
# ===========================================================================
puts ""
puts "============================================"
puts "  Step 3: Wiring Block Design"
puts "============================================"

# ---- Clock connections ----
# PL clock from PS → all PL logic + FPD AXI master clock
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] \
               [get_bd_pins softmax_engine/clk] \
               [get_bd_pins axi_interconnect_0/ACLK] \
               [get_bd_pins axi_interconnect_0/S00_ACLK] \
               [get_bd_pins axi_interconnect_0/M00_ACLK] \
               [get_bd_pins proc_sys_reset_0/slowest_sync_clk]

# FPD AXI master needs its own clock connection
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] \
               [get_bd_pins zynq_ps/maxihpm0_fpd_aclk]

# ---- Reset connections ----
connect_bd_net [get_bd_pins zynq_ps/pl_resetn0] \
               [get_bd_pins proc_sys_reset_0/ext_reset_in]

connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins softmax_engine/rst_n] \
               [get_bd_pins axi_interconnect_0/ARESETN] \
               [get_bd_pins axi_interconnect_0/S00_ARESETN] \
               [get_bd_pins axi_interconnect_0/M00_ARESETN]

# ---- AXI connections ----
# PS M_AXI_HPM0_FPD → AXI Interconnect S00 → Softmax Engine
# GP0 = FPD port, GP2 = LPD port. Try FPD first.
set ps_axi_connected 0
foreach ps_port {M_AXI_HPM0_FPD M_AXI_HPM0_LPD M_AXI_HPM1_FPD} {
    if {[catch {
        connect_bd_intf_net [get_bd_intf_pins zynq_ps/${ps_port}] \
                            [get_bd_intf_pins axi_interconnect_0/S00_AXI]
    }]} {
        puts "  PS port '${ps_port}' not found, trying next..."
    } else {
        puts "  Connected PS AXI: zynq_ps/${ps_port} → axi_interconnect_0/S00_AXI"
        set ps_axi_connected 1
        break
    }
}

if {!$ps_axi_connected} {
    puts "ERROR: Could not connect PS AXI master. Available interfaces:"
    puts [get_bd_intf_pins zynq_ps/M_AXI*]
    error "No PS AXI master port found"
}

# Try to connect as interface — Vivado may auto-infer as s_axil or s_axi
set intf_connected 0
foreach intf_name {s_axil s_axi S_AXI s_axil_0} {
    if {[catch {
        connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
                            [get_bd_intf_pins softmax_engine/${intf_name}]
    }]} {
        puts "  Interface '${intf_name}' not found, trying next..."
    } else {
        puts "  Connected AXI via interface: softmax_engine/${intf_name}"
        set intf_connected 1
        break
    }
}

if {!$intf_connected} {
    puts "WARNING: Could not auto-connect AXI interface."
    puts "  Available interfaces on softmax_engine:"
    puts [get_bd_intf_pins softmax_engine/*]
    puts "  Available pins on softmax_engine:"
    puts [get_bd_pins softmax_engine/*]
    puts ""
    puts "  Attempting individual net connections..."
    
    # Fall back to individual signal connections
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_awaddr]  [get_bd_pins softmax_engine/s_axil_awaddr]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_awvalid] [get_bd_pins softmax_engine/s_axil_awvalid]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_awready] [get_bd_pins softmax_engine/s_axil_awready]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_wdata]   [get_bd_pins softmax_engine/s_axil_wdata]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_wstrb]   [get_bd_pins softmax_engine/s_axil_wstrb]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_wvalid]  [get_bd_pins softmax_engine/s_axil_wvalid]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_wready]  [get_bd_pins softmax_engine/s_axil_wready]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_bresp]   [get_bd_pins softmax_engine/s_axil_bresp]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_bvalid]  [get_bd_pins softmax_engine/s_axil_bvalid]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_bready]  [get_bd_pins softmax_engine/s_axil_bready]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_araddr]  [get_bd_pins softmax_engine/s_axil_araddr]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_arvalid] [get_bd_pins softmax_engine/s_axil_arvalid]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_arready] [get_bd_pins softmax_engine/s_axil_arready]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_rdata]   [get_bd_pins softmax_engine/s_axil_rdata]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_rresp]   [get_bd_pins softmax_engine/s_axil_rresp]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_rvalid]  [get_bd_pins softmax_engine/s_axil_rvalid]
    connect_bd_net [get_bd_pins axi_interconnect_0/M00_AXI_rready]  [get_bd_pins softmax_engine/s_axil_rready]
    puts "  Individual net connections complete."
}

# ---- Interrupt connection ----
# irq_done → PS pl_ps_irq0
connect_bd_net [get_bd_pins softmax_engine/irq_done] \
               [get_bd_pins zynq_ps/pl_ps_irq0]

# ---- Address Map ----
# Assign address to our IP
assign_bd_address
# Default: our IP gets mapped at 0x8000_0000 (first available PL address)
# You can customize:
# set_property offset 0x80000000 [get_bd_addr_segs {zynq_ps/Data/SEG_softmax_engine_*}]
# set_property range 4K [get_bd_addr_segs {zynq_ps/Data/SEG_softmax_engine_*}]

# ===========================================================================
# Step 4: Validate and Generate
# ===========================================================================
puts ""
puts "============================================"
puts "  Step 4: Validating Block Design"
puts "============================================"

validate_bd_design
save_bd_design

# Generate HDL wrapper
make_wrapper -files [get_files ${bd_name}.bd] -top
add_files -norecurse ${proj_dir}/${proj_name}.gen/sources_1/bd/${bd_name}/hdl/${bd_name}_wrapper.v

# Set wrapper as top
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ===========================================================================
# Step 5: Synthesis
# ===========================================================================
puts ""
puts "============================================"
puts "  Step 5: Running Synthesis"
puts "============================================"

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    puts [get_property STATUS [get_runs synth_1]]
    # Don't exit — let user inspect in GUI
} else {
    puts "  Synthesis completed successfully"
}

# ===========================================================================
# Step 6: Implementation
# ===========================================================================
puts ""
puts "============================================"
puts "  Step 6: Running Implementation"
puts "============================================"

launch_runs impl_1 -jobs 4
wait_on_run impl_1

if {[get_property STATUS [get_runs impl_1]] ne "route_design Complete!"} {
    puts "WARNING: Implementation may have issues"
    puts [get_property STATUS [get_runs impl_1]]
}

# ---- Reports ----
open_run impl_1
report_utilization -file utilization_bd.rpt
report_timing_summary -file timing_bd.rpt -max_paths 10
report_power -file power_bd.rpt

puts ""
puts [report_utilization -return_string]
puts ""
puts [report_timing_summary -return_string]

# ===========================================================================
# Step 7: Generate Bitstream
# ===========================================================================
puts ""
puts "============================================"
puts "  Step 7: Generating Bitstream"
puts "============================================"

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# ---- Export Hardware (XSA) for firmware development ----
puts ""
puts "============================================"
puts "  Step 8: Exporting Hardware (XSA)"
puts "============================================"

write_hw_platform -fixed -include_bit \
    -file ${proj_dir}/${proj_name}.xsa

puts ""
puts "============================================"
puts "  BLOCK DESIGN BUILD COMPLETE"
puts "============================================"
puts ""
puts "  Outputs:"
puts "    Bitstream:  ${proj_name}.runs/impl_1/${bd_name}_wrapper.bit"
puts "    XSA:        ${proj_name}.xsa"
puts "    Reports:    utilization_bd.rpt, timing_bd.rpt, power_bd.rpt"
puts ""
puts "  To program the FPGA:"
puts "    1. Connect ZCU104 via JTAG"
puts "    2. open_hw_manager"
puts "    3. connect_hw_server"
puts "    4. open_hw_target"
puts "    5. program_hw_devices [get_hw_devices xczu7ev*] \\"
puts "         -bit ${proj_name}.runs/impl_1/${bd_name}_wrapper.bit"
puts ""
puts "  To develop firmware (bare-metal or Linux):"
puts "    1. Launch Vitis: vitis -workspace fw_workspace"
puts "    2. Create platform from ${proj_name}.xsa"
puts "    3. Write C code using CSR register map from docs/ARCHITECTURE.md"
puts ""
puts "  Address Map (from PS perspective):"
puts "    softmax_engine CSR: 0x8000_0000 — 0x8000_004C"
puts "    DDR4:               0x0000_0000 — 0x7FFF_FFFF"
puts ""

# close_project
