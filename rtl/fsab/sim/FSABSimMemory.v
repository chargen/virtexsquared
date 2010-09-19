module FSABSimMemory(
	input clk,
	input Nrst,
	
	input                        fsabo_valid,
	input       [FSAB_REQ_HI:0]  fsabo_mode,
	input       [FSAB_DID_HI:0]  fsabo_did,
	input       [FSAB_DID_HI:0]  fsabo_subdid,
	input       [FSAB_ADDR_HI:0] fsabo_addr,
	input       [FSAB_LEN_HI:0]  fsabo_len,
	input       [FSAB_DATA_HI:0] fsabo_data,
	input       [FSAB_MASK_HI:0] fsabo_mask,
	output wire                  fsabo_credit,
	
	output wire                  fsabi_valid,
	output wire [FSAB_DID_HI:0]  fsabi_did,
	output wire [FSAB_DID_HI:0]  fsabi_subdid,
	output wire [FSAB_DATA_HI:0] fsabi_data
	);

`include "fsab_defines.vh"

	/*** Inbound request FIFO (RFIF) ***/
`define SIMMEM_RFIF_HI (FSAB_REQ_HI+1 + FSAB_DID_HI+1 + FSAB_DID_HI+1 + FSAB_ADDR_HI+1 + FSAB_LEN_HI+1)
	reg [FSAB_CREDITS_HI:0] rfif_wpos_0a = 'h0;
	reg [FSAB_CREDITS_HI:0] rfif_rpos_0a = 'h0;
	reg [`SIMMEM_RFIF_HI:0] rfif_fifo [(FSAB_INITIAL_CREDITS-1):0];
	wire rfif_wr_0a;
	wire rfif_rd_0a;
	wire [`SIMMEM_RFIF_HI:0] rfif_wdat_0a;
	reg [`SIMMEM_RFIF_HI:0] rfif_rdat_1a;
	wire rfif_empty_0a = (rfif_rpos_0a == rfif_wpos_0a);
	wire rfif_full_0a = (rfif_wpos_0a == (rfif_rpos_0a + FSAB_INITIAL_CREDITS));
	
	always @(posedge clk or negedge Nrst)
		if (!Nrst) begin
			rfif_wpos_0a <= 'h0;
			rfif_rpos_0a <= 'h0;
		end else begin
			if (rfif_rd_0a) begin
				/* NOTE: this FIFO style will NOT port to Xilinx! */
				rfif_rdat_1a <= rfif_fifo[rfif_rpos_0a];
				rfif_rpos_0a <= rfif_rpos_0a + 'h1;
			end else begin
				rfif_rdat_1a <= {(FSAB_CREDITS_HI+1){1'hx}};
			end
			
			if (rfif_wr_0a) begin
				rfif_fifo[rfif_wpos_0a] <= rfif_wdat_0a;
				rfif_wpos_0a <= rfif_wpos_0a + 'h1;
			end
		end
	
	always @(posedge clk) begin
		if (rfif_empty_0a && rfif_rd_0a) $error("RFIF rd while empty");
		if (rfif_full_0a  && rfif_wr_0a) $error("RFIF wr while full");
	end
	
	/*** RFIF demux & control ***/
	wire [FSAB_REQ_HI:0]  rfif_mode_1a;
	wire [FSAB_DID_HI:0]  rfif_did_1a;
	wire [FSAB_DID_HI:0]  rfif_subdid_1a;
	wire [FSAB_ADDR_HI:0] rfif_addr_1a;
	wire [FSAB_LEN_HI:0]  rfif_len_1a;
	
	/* rfif_rd is assigned later */
	assign fsabo_credit = rfif_rd_0a;
	assign {rfif_mode_1a, rfif_did_1a, rfif_subdid_1a, rfif_addr_1a,
	        rfif_addr_1a, rfif_len_1a} = rfif_rdat_1a;
	assign rfif_wdat_0a = {fsabo_mode, fsabo_did, fsabo_subdid,
	                       fsabo_addr, fsabo_len};
	reg [FSAB_LEN_HI:0] fsabo_cur_req_len_rem_1a = 0;
	wire fsabo_cur_req_done_1a = (fsabo_cur_req_len_rem_1a == 0 /* we were done long ago */ || 
	                              fsabo_cur_req_len_rem_1a == 1 /* last cycle (1a) was the last word;
								       this cycle (0a), len will be 0 */);
	assign rfif_wr_0a = fsabo_valid && fsabo_cur_req_done_1a;
	
	always @(posedge clk or negedge Nrst)
		if (Nrst) begin
			fsabo_cur_req_len_rem_1a <= 0;
		end else begin
			if (fsabo_valid && fsabo_cur_req_done_1a)
				fsabo_cur_req_len_rem_1a <= fsabo_len;
			else if (fsabo_valid && fsabo_cur_req_len_rem_1a != 0)
				fsabo_cur_req_len_rem_1a <= fsabo_cur_req_len_rem_1a - 1;
		end
	
	/*** Inbound data FIFO (DFIF) ***/
`define SIMMEM_DFIF_MAX (((FSAB_CREDITS_HI+1) * FSAB_LEN_MAX) - 1)
`define SIMMEM_DFIF_HI (FSAB_CREDITS_HI+1+FSAB_LEN_MAX)
	reg [`SIMMEM_DFIF_HI:0] dfif_wpos_0a = 'h0;
	reg [`SIMMEM_DFIF_HI:0] dfif_rpos_0a = 'h0;
	reg [FSAB_DATA_HI+1 + FSAB_MASK_HI:0] dfif_fifo [`SIMMEM_DFIF_MAX:0];
	wire dfif_wr_0a;
	wire dfif_rd_0a;
	wire [FSAB_DATA_HI+1 + FSAB_MASK_HI:0] dfif_wdat_0a;
	reg [FSAB_DATA_HI+1 + FSAB_MASK_HI:0] dfif_rdat_1a;
	wire dfif_empty_0a = (dfif_rpos_0a == dfif_wpos_0a);
	wire dfif_full_0a = (dfif_wpos_0a == (dfif_rpos_0a + `SIMMEM_DFIF_MAX));
	
	always @(posedge clk or negedge Nrst)
		if (!Nrst) begin
			dfif_wpos_0a <= 'h0;
			dfif_rpos_0a <= 'h0;
		end else begin
			if (dfif_rd_0a) begin
				/* NOTE: this FIFO style will NOT port to Xilinx! */
				dfif_rdat_1a <= dfif_fifo[dfif_rpos_0a];
				dfif_rpos_0a <= dfif_rpos_0a + 'h1;
			end else begin
				dfif_rdat_1a <= {(FSAB_DATA_HI+1 + FSAB_MASK_HI+1){1'hx}};
			end
			
			if (dfif_wr_0a) begin
				dfif_fifo[dfif_wpos_0a] <= dfif_wdat_0a;
				dfif_wpos_0a <= dfif_wpos_0a + 'h1;
			end
		end
	
	always @(posedge clk) begin
		if (dfif_empty_0a && dfif_rd_0a) $error("RFIF rd while empty");
		if (dfif_full_0a  && dfif_wr_0a) $error("RFIF wr while full");
	end
	
	/*** DFIF demux & control */
	wire [FSAB_DATA_HI:0] dfif_data_1a;
	wire [FSAB_MASK_HI:0] dfif_mask_1a;
	
	/* dfif_rd is assigned later */
	assign {dfif_data_1a,dfif_mask_1a} = dfif_rdat_1a;
	assign dfif_wdat_0a = {fsabo_data,fsabo_mask};
	assign dfif_wr_0a = fsabo_valid;
	
	/*** Memory control logic ***/
	
endmodule
