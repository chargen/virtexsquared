`include "ARM_Constants.v"

`define SWP_READING	2'b01
`define SWP_WRITING	2'b10

`define LSRH_MEMIO	3'b001
`define LSRH_BASEWB	3'b010
`define LSRH_WBFLUSH	3'b100

`define LSR_MEMIO	4'b0001
`define LSR_STRB_WR	4'b0010
`define LSR_BASEWB	4'b0100
`define LSR_WBFLUSH	4'b1000

`define LSM_SETUP	4'b0001
`define LSM_MEMIO	4'b0010
`define LSM_BASEWB	4'b0100
`define LSM_WBFLUSH	4'b1000


module Memory(
	input clk,
	input Nrst,

	input flush,

	/* bus interface */
	output reg [31:0] dc__addr_3a,
	output reg dc__rd_req_3a,
	output reg dc__wr_req_3a,
	input dc__rw_wait_3a,
	output reg [31:0] dc__wr_data_3a,
	input [31:0] dc__rd_data_3a,
	output reg [2:0] dc__data_size_3a,

	/* regfile interface */
	output reg [3:0] rf__read_3_3a,
	input [31:0] rf__rdata_3_3a,
	
	/* Coprocessor interface */
	output reg cp_req,
	input cp_ack,
	input cp_busy,
	output reg cp_rnw,	/* 1 = read from CP, 0 = write to CP */
	input [31:0] cp_read,
	output reg [31:0] cp_write,
	
	/* stage inputs */
	input bubble_3a,
	input [31:0] pc_3a,
	input [31:0] insn_3a,
	input [31:0] op0_3a,
	input [31:0] op1_3a,
	input [31:0] op2_3a,
	input [31:0] spsr_3a,
	input [31:0] cpsr_3a,
	input cpsrup_3a,
	input write_reg_3a,
	input [3:0] write_num_3a,
	input [31:0] write_data_3a,

	/* outputs */
	output reg outstall,
	output reg outbubble,
	output reg [31:0] outpc,
	output reg [31:0] outinsn,
	output reg out_write_reg = 1'b0,
	output reg [3:0] out_write_num = 4'bxxxx,
	output reg [31:0] out_write_data = 32'hxxxxxxxx,
	output reg [31:0] outspsr = 32'hxxxxxxxx,
	output reg [31:0] outcpsr = 32'hxxxxxxxx,
	output reg outcpsrup = 1'hx
	);

	reg [31:0] addr, raddr, prev_raddr, next_regdata, next_outcpsr;
	reg next_outcpsrup;
	reg [31:0] prevaddr;
	reg [3:0] next_regsel, cur_reg, prev_reg;
	reg next_writeback;

	reg next_outbubble;	
	reg next_write_reg;
	reg [3:0] next_write_num;
	reg [31:0] next_write_data;

	reg [3:0] lsr_state = 4'b0001, next_lsr_state;
	reg [31:0] align_s1, align_s2, align_rddata;

	reg [2:0] lsrh_state = 3'b001, next_lsrh_state;
	reg [31:0] lsrh_rddata;
	reg [15:0] lsrh_rddata_s1;
	reg [7:0] lsrh_rddata_s2;

	reg [15:0] regs, next_regs;
	reg [3:0] lsm_state = 4'b0001, next_lsm_state;
	reg [5:0] offset, prev_offset, offset_sel;

	reg [31:0] swp_oldval, next_swp_oldval;
	reg [1:0] swp_state = 2'b01, next_swp_state;
	
	reg do_rd_data_latch;
	reg [31:0] rd_data_latch = 32'hxxxxxxxx;

	always @(posedge clk)
	begin
		outpc <= pc_3a;
		outinsn <= insn_3a;
		outbubble <= next_outbubble;
		out_write_reg <= next_write_reg;
		out_write_num <= next_write_num;
		out_write_data <= next_write_data;
		if (!dc__rw_wait_3a)
			prev_offset <= offset;
		prev_raddr <= raddr;
		outcpsr <= next_outcpsr;
		outspsr <= spsr_3a;
		outcpsrup <= next_outcpsrup;
		swp_state <= next_swp_state;
		lsm_state <= next_lsm_state;
		lsr_state <= next_lsr_state;
		lsrh_state <= next_lsrh_state;
		if (do_rd_data_latch)
			rd_data_latch <= dc__rd_data_3a;
		swp_oldval <= next_swp_oldval;
		prevaddr <= addr;
	end
	
	reg delayedflush = 0;
	always @(posedge clk)
		if (flush && outstall /* halp! I can't do it now, maybe later? */)
			delayedflush <= 1;
		else if (!outstall /* anything has been handled this time around */)
			delayedflush <= 0;
	
	/* Drive the state machines and stall. */
	always @(*)
	begin
		outstall = 1'b0;
		next_lsm_state = lsm_state;
		next_lsr_state = lsr_state;
		next_lsrh_state = lsrh_state;
		next_swp_state = swp_state;
		casez(insn_3a)
		`DECODE_ALU_SWP: if(!bubble_3a) begin
			case(swp_state)
			`SWP_READING: begin
				outstall = 1'b1;
				if (!dc__rw_wait_3a)
					next_swp_state = `SWP_WRITING;
				$display("SWP: read stage");
			end
			`SWP_WRITING: begin
				outstall = dc__rw_wait_3a;
				if(!dc__rw_wait_3a)
					next_swp_state = `SWP_READING;
				$display("SWP: write stage");
			end
			default: begin
				outstall = 1'bx;
				next_swp_state = 2'bxx;
			end
			endcase
		end
		`DECODE_ALU_MULT: begin
			outstall = 1'b0;	/* XXX work around for Xilinx bug */
			next_lsrh_state = lsrh_state;
		end
		`DECODE_ALU_HDATA_REG,
		`DECODE_ALU_HDATA_IMM: if(!bubble_3a) begin
			case(lsrh_state)
			`LSRH_MEMIO: begin
				outstall = dc__rw_wait_3a;
				if(insn_3a[21] | !insn_3a[24]) begin
					outstall = 1'b1;
					if(!dc__rw_wait_3a)
						next_lsrh_state = `LSRH_BASEWB;
				end
				
				if (flush) /* special case! */ begin
					outstall = 1'b0;
					next_lsrh_state = `LSRH_MEMIO;
				end
				
				$display("ALU_LDRSTRH: rd_req %d, wr_req %d", dc__rd_req_3a, dc__wr_req_3a);
			end
			`LSRH_BASEWB: begin
				outstall = 1'b1;
				next_lsrh_state = `LSRH_WBFLUSH;
			end
			`LSRH_WBFLUSH: begin
				outstall = 1'b0;
				next_lsrh_state = `LSRH_MEMIO;
			end
			default: begin
				outstall = 1'bx;
				next_lsrh_state = 3'bxxx;
			end
			endcase
		end
		`DECODE_LDRSTR_UNDEFINED: begin end
		`DECODE_LDRSTR: if(!bubble_3a) begin
			outstall = dc__rw_wait_3a;
			case(lsr_state)
			`LSR_MEMIO: begin
				outstall = dc__rw_wait_3a;
				next_lsr_state = `LSR_MEMIO;
				if (insn_3a[22] /* B */ && !insn_3a[20] /* L */) begin	/* i.e., strb */
					outstall = 1'b1;
					if (!dc__rw_wait_3a)
						next_lsr_state = `LSR_STRB_WR;
				end else if (insn_3a[21] /* W */ || !insn_3a[24] /* P */) begin	/* writeback needed */
					outstall = 1'b1;
					if (!dc__rw_wait_3a)
						next_lsr_state = `LSR_BASEWB;
				end
				
				if (flush) begin
					outstall = 1'b0;
					next_lsr_state = `LSR_MEMIO;
				end
				$display("LDRSTR: rd_req %d, wr_req %d, raddr %08x, wait %d", dc__rd_req_3a, dc__wr_req_3a, raddr, dc__rw_wait_3a);
			end
			`LSR_STRB_WR: begin
				outstall = 1;
				if(insn_3a[21] /* W */ | !insn_3a[24] /* P */) begin
					if(!dc__rw_wait_3a)
						next_lsr_state = `LSR_BASEWB;
				end else if (!dc__rw_wait_3a)
					next_lsr_state = `LSR_WBFLUSH;
				$display("LDRSTR: Handling STRB");
			end
			`LSR_BASEWB: begin
				outstall = 1;
				next_lsr_state = `LSR_WBFLUSH;
			end
			`LSR_WBFLUSH: begin
				outstall = 0;
				next_lsr_state = `LSR_MEMIO;
			end
			default: begin
				outstall = 1'bx;
				next_lsr_state = 4'bxxxx;
			end
			endcase
			$display("LDRSTR: Decoded, bubble %d, insn %08x, lsm state %b -> %b, stall %d", bubble_3a, insn_3a, lsr_state, next_lsr_state, outstall);
		end
		`DECODE_LDMSTM: if(!bubble_3a) begin
			outstall = dc__rw_wait_3a;
			case(lsm_state)
			`LSM_SETUP: begin
				outstall = 1'b1;
				next_lsm_state = `LSM_MEMIO;
				if (flush) begin
					outstall = 1'b0;
					next_lsm_state = `LSM_SETUP;
				end
				$display("LDMSTM: Round 1: base register: %08x, reg list %b", op0_3a, op1_3a[15:0]);
			end
			`LSM_MEMIO: begin
				outstall = 1'b1;
				if(next_regs == 16'b0 && !dc__rw_wait_3a) begin
					next_lsm_state = `LSM_BASEWB;
				end
				
				$display("LDMSTM: Stage 2: Writing: regs %b, next_regs %b, reg %d, wr_data %08x, addr %08x", regs, next_regs, cur_reg, rf__rdata_3_3a, dc__addr_3a);
			end
			`LSM_BASEWB: begin
				outstall = 1;
				next_lsm_state = `LSM_WBFLUSH;
				$display("LDMSTM: Stage 3: Writing back");
			end
			`LSM_WBFLUSH: begin
				outstall = 0;
				next_lsm_state = `LSM_SETUP;
			end
			default: begin
				outstall = 1'bx;
				next_lsm_state = 4'bxxxx;
			end
			endcase
			$display("LDMSTM: Decoded, bubble %d, insn %08x, lsm state %b -> %b, stall %d", bubble_3a, insn_3a, lsm_state, next_lsm_state, outstall);
		end
		`DECODE_LDCSTC: if(!bubble_3a) begin
			$display("WARNING: Unimplemented LDCSTC");
		end
		`DECODE_CDP: if (!bubble_3a) begin
			if (cp_busy) begin
				outstall = 1;
			end
			if (!cp_ack) begin
				/* XXX undefined instruction trap */
				$display("WARNING: Possible CDP undefined instruction");
			end
		end
		`DECODE_MRCMCR: if (!bubble_3a) begin
			if (cp_busy) begin
				outstall = 1;
			end
			if (!cp_ack) begin
				$display("WARNING: Possible MRCMCR undefined instruction: cp_ack %d, cp_busy %d",cp_ack, cp_busy);
			end
			$display("MRCMCR: ack %d, busy %d", cp_ack, cp_busy);
		end
		default: begin end
		endcase
	end
	
	/* Coprocessor input. */
	always @(*)
	begin
		cp_req = 0;
		cp_rnw = 1'bx;
		cp_write = 32'hxxxxxxxx;
		casez (insn_3a)
		`DECODE_CDP: if(!bubble_3a) begin
			cp_req = 1;
		end
		`DECODE_MRCMCR: if(!bubble_3a) begin
			cp_req = 1;
			cp_rnw = insn_3a[20] /* L */;
			if (insn_3a[20] == 0 /* store to coprocessor */)
				cp_write = op0_3a;
		end
		endcase
	end
	
	/* Register output logic. */
	always @(*)
	begin
		next_write_reg = write_reg_3a;
		next_write_num = write_num_3a;
		next_write_data = write_data_3a;
		next_outcpsr = lsm_state == 4'b0010 ? outcpsr : cpsr_3a;
		next_outcpsrup = cpsrup_3a;
		
		casez(insn_3a)
		`DECODE_ALU_SWP: if (!bubble_3a) begin
			next_write_reg = 1'bx;
			next_write_num = 4'bxxxx;
			next_write_data = 32'hxxxxxxxx;
			case(swp_state)
			`SWP_READING:
				next_write_reg = 1'b0;
			`SWP_WRITING: begin
				next_write_reg = 1'b1;
				next_write_num = insn_3a[15:12];
				next_write_data = insn_3a[22] ? {24'b0, swp_oldval[7:0]} : swp_oldval;
			end
			default: begin end
			endcase
		end
		`DECODE_ALU_MULT: begin
			next_write_reg = write_reg_3a;	/* XXX workaround for ISE 10.1 bug */
			next_write_num = write_num_3a;
			next_write_data = write_data_3a;
			next_outcpsr = lsm_state == 4'b0010 ? outcpsr : cpsr_3a;
			next_outcpsrup = cpsrup_3a;
		end
		`DECODE_ALU_HDATA_REG,
		`DECODE_ALU_HDATA_IMM: if(!bubble_3a) begin
			next_write_reg = 1'bx;
			next_write_num = 4'bxxxx;
			next_write_data = 32'hxxxxxxxx;
			case(lsrh_state)
			`LSRH_MEMIO: begin
				next_write_num = insn_3a[15:12];
				next_write_data = lsrh_rddata;
				if(insn_3a[20]) begin
					next_write_reg = 1'b1;
				end
			end
			`LSRH_BASEWB: begin
				next_write_reg = 1'b1;
				next_write_num = insn_3a[19:16];
				next_write_data = addr;
			end
			`LSRH_WBFLUSH:
				next_write_reg = 1'b0;
			default: begin end
			endcase
		end
		`DECODE_LDRSTR_UNDEFINED: begin end
		`DECODE_LDRSTR: if(!bubble_3a) begin
			next_write_reg = 1'bx;
			next_write_num = 4'bxxxx;
			next_write_data = 32'hxxxxxxxx;
			case(lsr_state)
			`LSR_MEMIO: begin
				next_write_reg = insn_3a[20] /* L */;
				next_write_num = insn_3a[15:12];
				if(insn_3a[20] /* L */) begin
					next_write_data = insn_3a[22] /* B */ ? {24'h0, align_rddata[7:0]} : align_rddata;
				end
			end
			`LSR_STRB_WR:
				next_write_reg = 1'b0;
			`LSR_BASEWB: begin
				next_write_reg = 1'b1;
				next_write_num = insn_3a[19:16];
				next_write_data = addr;
			end
			`LSR_WBFLUSH:
				next_write_reg = 1'b0;
			default: begin end
			endcase
		end
		`DECODE_LDMSTM: if(!bubble_3a) begin
			next_write_reg = 1'bx;
			next_write_num = 4'bxxxx;
			next_write_data = 32'hxxxxxxxx;
			case(lsm_state)
			`LSM_SETUP:
				next_write_reg = 1'b0;
			`LSM_MEMIO: begin
				if(insn_3a[20] /* L */) begin
					next_write_reg = !dc__rw_wait_3a;
					next_write_num = cur_reg;
					next_write_data = dc__rd_data_3a;
				end else
					next_write_reg = 1'b0;
			end
			`LSM_BASEWB: begin
				next_write_reg = insn_3a[21] /* writeback */;
				next_write_num = insn_3a[19:16];
				next_write_data = insn_3a[23] ? op0_3a + {26'b0, prev_offset} : op0_3a - {26'b0, prev_offset};
				if(cur_reg == 4'hF && insn_3a[22]) begin
					next_outcpsr = spsr_3a;
					next_outcpsrup = 1;
				end
			end
			`LSM_WBFLUSH:
				next_write_reg = 1'b0;
			default: begin end
			endcase
		end
		`DECODE_MRCMCR: if(!bubble_3a) begin
			next_write_reg = 1'bx;
			next_write_num = 4'bxxxx;
			next_write_data = 32'hxxxxxxxx;
			next_outcpsr = 32'hxxxxxxxx;
			next_outcpsrup = 1'bx;
			if (insn_3a[20] == 1 /* load from coprocessor */)
				if (insn_3a[15:12] != 4'hF /* Fuck you ARM */) begin
					next_write_reg = 1'b1;
					next_write_num = insn_3a[15:12];
					next_write_data = cp_read;
				end else begin
					next_outcpsr = {cp_read[31:28], cpsr_3a[27:0]};
					next_outcpsrup = 1;
				end
		end
		endcase
	end
	
	/* Bus/address control logic. */
	always @(*)
	begin
		dc__rd_req_3a = 1'b0;
		dc__wr_req_3a = 1'b0;
		offset = prev_offset;
		addr = prevaddr;
		raddr = 32'hxxxxxxxx;
		dc__addr_3a = 32'hxxxxxxxx;
		dc__data_size_3a = 3'bxxx;
		
		casez(insn_3a)
		`DECODE_ALU_SWP: if(!bubble_3a) begin
			dc__addr_3a = {op0_3a[31:2], 2'b0};
			dc__data_size_3a = insn_3a[22] ? 3'b001 : 3'b100;
			case(swp_state)
			`SWP_READING:
				dc__rd_req_3a = 1'b1;
			`SWP_WRITING:
				dc__wr_req_3a = 1'b1;
			default: begin end
			endcase
		end
		`DECODE_ALU_MULT: begin
			dc__rd_req_3a = 1'b0;	/* XXX workaround for Xilinx bug */
			dc__wr_req_3a = 1'b0;
			offset = prev_offset;
			addr = prevaddr;
		end
		`DECODE_ALU_HDATA_REG,
		`DECODE_ALU_HDATA_IMM: if(!bubble_3a) begin
			addr = insn_3a[23] ? op0_3a + op1_3a : op0_3a - op1_3a; /* up/down select */
			raddr = insn_3a[24] ? op0_3a : addr; /* pre/post increment */
			dc__addr_3a = raddr;
			/* rotate to correct position */
			case(insn_3a[6:5])
			2'b01: /* unsigned half */
				dc__data_size_3a = 3'b010;
			2'b10: /* signed byte */
				dc__data_size_3a = 3'b001;
			2'b11: /* signed half */
				dc__data_size_3a = 3'b010;
			default: begin
				dc__data_size_3a = 3'bxxx;
			end
			endcase
			
			case(lsrh_state)
			`LSRH_MEMIO: begin
				dc__rd_req_3a = insn_3a[20];
				dc__wr_req_3a = ~insn_3a[20];
			end
			`LSRH_BASEWB: begin end
			`LSRH_WBFLUSH: begin end
			default: begin end
			endcase
		end
		`DECODE_LDRSTR_UNDEFINED: begin end
		`DECODE_LDRSTR: if(!bubble_3a) begin
			addr = insn_3a[23] ? op0_3a + op1_3a : op0_3a - op1_3a; /* up/down select */
			raddr = insn_3a[24] ? addr : op0_3a; /* pre/post increment */
			dc__addr_3a = raddr;
			dc__data_size_3a = insn_3a[22] ? 3'b001 : 3'b100;
			case (lsr_state)
			`LSR_MEMIO: begin
				dc__rd_req_3a = insn_3a[20] /* L */ || insn_3a[22] /* B */;
				dc__wr_req_3a = !insn_3a[20] /* L */ && !insn_3a[22]/* B */;
			end
			`LSR_STRB_WR:
				dc__wr_req_3a = 1;
			`LSR_BASEWB: begin end
			`LSR_WBFLUSH: begin end
			default: begin end
			endcase
		end
		`DECODE_LDMSTM: if (!bubble_3a) begin
			dc__data_size_3a = 3'b100;
			case (lsm_state)
			`LSM_SETUP:
				offset = 6'b0;
			`LSM_MEMIO: begin
				dc__rd_req_3a = insn_3a[20];
				dc__wr_req_3a = ~insn_3a[20];
				offset = prev_offset + 6'h4;
				offset_sel = insn_3a[24] ? offset : prev_offset;
				raddr = insn_3a[23] ? op0_3a + {26'b0, offset_sel} : op0_3a - {26'b0, offset_sel};
				dc__addr_3a = raddr;
			end
			`LSM_BASEWB: begin end
			`LSM_WBFLUSH: begin end
			default: begin end
			endcase
		end
		`DECODE_LDCSTC: begin end
		`DECODE_CDP: begin end
		`DECODE_MRCMCR: begin end
		default: begin end
		endcase
	end
	
	/* Bus data control logic. */
	always @(*)
	begin
		dc__wr_data_3a = 32'hxxxxxxxx;
		
		casez(insn_3a)
		`DECODE_ALU_SWP: if(!bubble_3a)
			if (swp_state == `SWP_WRITING)
				dc__wr_data_3a = insn_3a[22] ? {4{op1_3a[7:0]}} : op1_3a;
		`DECODE_ALU_MULT: begin end
		`DECODE_ALU_HDATA_REG,
		`DECODE_ALU_HDATA_IMM: if(!bubble_3a)
			case(insn_3a[6:5])
			2'b01: /* unsigned half */
				dc__wr_data_3a = {2{op2_3a[15:0]}}; /* XXX need to store halfword */
			2'b10: /* signed byte */
				dc__wr_data_3a = {4{op2_3a[7:0]}};
			2'b11: /* signed half */
				dc__wr_data_3a = {2{op2_3a[15:0]}};
			default: begin end
			endcase
		`DECODE_LDRSTR_UNDEFINED: begin end
		`DECODE_LDRSTR: if(!bubble_3a) begin
			dc__wr_data_3a = insn_3a[22] ? {24'h0, {op2_3a[7:0]}} : op2_3a;
			if (lsr_state == `LSR_STRB_WR)
				case (dc__addr_3a[1:0])
				2'b00: dc__wr_data_3a = {rd_data_latch[31:8], op2_3a[7:0]};
				2'b01: dc__wr_data_3a = {rd_data_latch[31:16], op2_3a[7:0], rd_data_latch[7:0]};
				2'b10: dc__wr_data_3a = {rd_data_latch[31:24], op2_3a[7:0], rd_data_latch[15:0]};
				2'b11: dc__wr_data_3a = {op2_3a[7:0], rd_data_latch[23:0]};
				endcase
		end
		`DECODE_LDMSTM: if (!bubble_3a)
			if (lsm_state == `LSM_MEMIO)
				dc__wr_data_3a = (cur_reg == 4'hF) ? (pc_3a + 12) : rf__rdata_3_3a;
		`DECODE_LDCSTC: begin end
		`DECODE_CDP: begin end
		`DECODE_MRCMCR: begin end
		default: begin end
		endcase
	end
	
	/* LDM/STM register control logic. */
	always @(posedge clk)
		if (!dc__rw_wait_3a || lsm_state != `LSM_MEMIO)
		begin
			prev_reg <= cur_reg;
			regs <= next_regs;
		end
	
	always @(*)
	begin
		rf__read_3_3a = 4'hx;
		cur_reg = prev_reg;
		next_regs = regs;
		
		casez(insn_3a)
		`DECODE_LDMSTM: if(!bubble_3a) begin
			case(lsm_state)
			`LSM_SETUP:
				next_regs = insn_3a[23] /* U */ ? op1_3a[15:0] : {op1_3a[0], op1_3a[1], op1_3a[2], op1_3a[3], op1_3a[4], op1_3a[5], op1_3a[6], op1_3a[7],
				                                               op1_3a[8], op1_3a[9], op1_3a[10], op1_3a[11], op1_3a[12], op1_3a[13], op1_3a[14], op1_3a[15]};
			`LSM_MEMIO: begin
				casez(regs)
				16'b???????????????1: begin
					cur_reg = 4'h0;
					next_regs = {regs[15:1], 1'b0};
				end
				16'b??????????????10: begin
					cur_reg = 4'h1;
					next_regs = {regs[15:2], 2'b0};
				end
				16'b?????????????100: begin
					cur_reg = 4'h2;
					next_regs = {regs[15:3], 3'b0};
				end
				16'b????????????1000: begin
					cur_reg = 4'h3;
					next_regs = {regs[15:4], 4'b0};
				end
				16'b???????????10000: begin
					cur_reg = 4'h4;
					next_regs = {regs[15:5], 5'b0};
				end
				16'b??????????100000: begin
					cur_reg = 4'h5;
					next_regs = {regs[15:6], 6'b0};
				end
				16'b?????????1000000: begin
					cur_reg = 4'h6;
					next_regs = {regs[15:7], 7'b0};
				end
				16'b????????10000000: begin
					cur_reg = 4'h7;
					next_regs = {regs[15:8], 8'b0};
				end
				16'b???????100000000: begin
					cur_reg = 4'h8;
					next_regs = {regs[15:9], 9'b0};
				end
				16'b??????1000000000: begin
					cur_reg = 4'h9;
					next_regs = {regs[15:10], 10'b0};
				end
				16'b?????10000000000: begin
					cur_reg = 4'hA;
					next_regs = {regs[15:11], 11'b0};
				end
				16'b????100000000000: begin
					cur_reg = 4'hB;
					next_regs = {regs[15:12], 12'b0};
				end
				16'b???1000000000000: begin
					cur_reg = 4'hC;
					next_regs = {regs[15:13], 13'b0};
				end
				16'b??10000000000000: begin
					cur_reg = 4'hD;
					next_regs = {regs[15:14], 14'b0};
				end
				16'b?100000000000000: begin
					cur_reg = 4'hE;
					next_regs = {regs[15], 15'b0};
				end
				16'b1000000000000000: begin
					cur_reg = 4'hF;
					next_regs = 16'b0;
				end
				default: begin
					cur_reg = 4'hx;
					next_regs = 16'b0;
				end
				endcase
				cur_reg = insn_3a[23] ? cur_reg : 4'hF - cur_reg;
				
				rf__read_3_3a = cur_reg;
			end
			`LSM_BASEWB: begin end
			`LSM_WBFLUSH: begin end
			default: begin end
			endcase
		end
		endcase
	end
	
	always @(*)
	begin
		do_rd_data_latch = 0;
		
		next_outbubble = bubble_3a;
		
		lsrh_rddata = 32'hxxxxxxxx;
		lsrh_rddata_s1 = 16'hxxxx;
		lsrh_rddata_s2 = 8'hxx;
		next_swp_oldval = swp_oldval;
		
		align_s1 = 32'hxxxxxxxx;
		align_s2 = 32'hxxxxxxxx;
		align_rddata = 32'hxxxxxxxx;

		/* XXX shit not given about endianness */
		casez(insn_3a)
		`DECODE_ALU_SWP: if(!bubble_3a) begin
			next_outbubble = dc__rw_wait_3a;
			case(swp_state)
			`SWP_READING:
				if(!dc__rw_wait_3a)
					next_swp_oldval = dc__rd_data_3a;
			`SWP_WRITING: begin end
			default: begin end
			endcase
		end
		`DECODE_ALU_MULT: begin
			next_outbubble = bubble_3a;	/* XXX workaround for Xilinx bug */
		end
		`DECODE_ALU_HDATA_REG,
		`DECODE_ALU_HDATA_IMM: if(!bubble_3a) begin
			next_outbubble = dc__rw_wait_3a;
			
			/* rotate to correct position */
			case(insn_3a[6:5])
			2'b01: begin /* unsigned half */
				lsrh_rddata = {16'b0, raddr[1] ? dc__rd_data_3a[31:16] : dc__rd_data_3a[15:0]};
			end
			2'b10: begin /* signed byte */
				lsrh_rddata_s1 = raddr[1] ? dc__rd_data_3a[31:16] : dc__rd_data_3a[15:0];
				lsrh_rddata_s2 = raddr[0] ? lsrh_rddata_s1[15:8] : lsrh_rddata_s1[7:0];
				lsrh_rddata = {{24{lsrh_rddata_s2[7]}}, lsrh_rddata_s2};
			end
			2'b11: begin /* signed half */
				lsrh_rddata = raddr[1] ? {{16{dc__rd_data_3a[31]}}, dc__rd_data_3a[31:16]} : {{16{dc__rd_data_3a[15]}}, dc__rd_data_3a[15:0]};
			end
			default: begin
				lsrh_rddata = 32'hxxxxxxxx;
			end
			endcase

			case(lsrh_state)
			`LSRH_MEMIO: begin end
			`LSRH_BASEWB:
				next_outbubble = 1'b0;
			`LSRH_WBFLUSH: begin end
			default: begin end
			endcase
		end
		`DECODE_LDRSTR_UNDEFINED: begin end
		`DECODE_LDRSTR: if(!bubble_3a) begin
			next_outbubble = dc__rw_wait_3a;
			/* rotate to correct position */
			align_s1 = raddr[1] ? {dc__rd_data_3a[15:0], dc__rd_data_3a[31:16]} : dc__rd_data_3a;
			align_s2 = raddr[0] ? {align_s1[7:0], align_s1[31:8]} : align_s1;
			/* select byte or word */
			align_rddata = insn_3a[22] ? {24'b0, align_s2[7:0]} : align_s2;
			case(lsr_state)
			`LSR_MEMIO:
				if (insn_3a[22] /* B */ && !insn_3a[20] /* L */)
					do_rd_data_latch = 1;
			`LSR_STRB_WR: begin end
			`LSR_BASEWB:
				next_outbubble = 0;
			`LSR_WBFLUSH: begin end
			default: begin end
			endcase
		end
		/* XXX ldm/stm incorrect in that stupid case where one of the listed regs is the base reg */
		`DECODE_LDMSTM: if(!bubble_3a) begin
			next_outbubble = dc__rw_wait_3a;
			case(lsm_state)
			`LSM_SETUP: begin end
			`LSM_MEMIO: begin end
			`LSM_BASEWB:
				next_outbubble = 0;
			`LSM_WBFLUSH: begin end
			default: $stop;
			endcase
		end
		`DECODE_LDCSTC: begin end
		`DECODE_CDP: if(!bubble_3a) begin
			if (cp_busy) begin
				next_outbubble = 1;
			end
		end
		`DECODE_MRCMCR: if(!bubble_3a) begin
			if (cp_busy) begin
				next_outbubble = 1;
			end
		end
		default: begin end
		endcase
		
		if ((flush || delayedflush) && !outstall)
			next_outbubble = 1'b1;
	end
endmodule
