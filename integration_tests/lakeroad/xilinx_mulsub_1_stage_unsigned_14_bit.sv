// RUN: outfile=$(mktemp)
// RUN: racket $LAKEROAD_DIR/bin/main.rkt \
// RUN:  --solver cvc5 \
// RUN:  --verilog-module-filepath %s \
// RUN:  --architecture xilinx-ultrascale-plus \
// RUN:  --template dsp \
// RUN:  --out-format verilog \
// RUN:  --top-module-name top \
// RUN:  --verilog-module-out-signal out:14 \
// RUN:  --initiation-interval 1 \
// RUN:  --clock-name clk \
// RUN:  --module-name top \
// RUN:  --input-signal a:14 \
// RUN:  --input-signal b:14 \
// RUN:  --input-signal c:14 \
// RUN: > $outfile
// RUN: cat $outfile
// RUN: FileCheck %s < $outfile
// RUN: if [ -z ${LAKEROAD_PRIVATE_DIR+x} ]; then \
// RUN:   echo "Warning: LAKEROAD_PRIVATE_DIR is not set. Skipping simulation."; \
// RUN:   exit 0; \
// RUN: else \
// RUN:   python $LAKEROAD_DIR/bin/simulate_with_verilator.py \
// RUN:    --max_num_tests=10000 \
// RUN:    --test_module_filepath $outfile \
// RUN:    --ground_truth_module_filepath %s \
// RUN:    --clock_name clk \
// RUN:    --initiation_interval 1 \
// RUN:    --output_signal_name out \
// RUN:    --input_signal a:14 \
// RUN:    --input_signal b:14 \
// RUN:    --input_signal c:14 \
// RUN:    --verilator_include_dir "$LAKEROAD_PRIVATE_DIR/DSP48E2/" \
// RUN:    --verilator_extra_arg='-DXIL_XECLIB' \
// RUN:    --verilator_extra_arg='-Wno-UNOPTFLAT' \
// RUN:    --verilator_extra_arg='-Wno-LATCH' \
// RUN:    --verilator_extra_arg='-Wno-WIDTH' \
// RUN:    --verilator_extra_arg='-Wno-STMTDLY' \
// RUN:    --verilator_extra_arg='-Wno-CASEX' \
// RUN:    --verilator_extra_arg='-Wno-TIMESCALEMOD' \
// RUN:    --verilator_extra_arg='-Wno-PINMISSING'; \
// RUN: fi

(* use_dsp = "yes" *) module top(
	input  [13:0] a,
	input  [13:0] b,
	input  [13:0] c,
	output [13:0] out,
	input clk);

	logic  [27:0] stage0;

	always @(posedge clk) begin
	stage0 <= (a * b) - c;

	end

	assign out = stage0;
endmodule

// CHECK: module top(a, b, c, clk, out);
// CHECK:   DSP48E2 #(
// CHECK: endmodule
