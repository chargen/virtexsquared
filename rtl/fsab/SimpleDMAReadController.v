
/* Read 64 bytes at a time through the FSAB bus */

module SimpleDMAReadController(/*AUTOARG*/
   // Outputs
   dmac__fsabo_valid, dmac__fsabo_mode, dmac__fsabo_did,
   dmac__fsabo_subdid, dmac__fsabo_addr, dmac__fsabo_len,
   dmac__fsabo_data, dmac__fsabo_mask, data, data_ready, fifo_empty,
   dmac__spami_busy_b, dmac__spami_data,
   // Inputs
   cclk, cclk_rst_b, dmac__fsabo_credit, fsabi_clk, fsabi_rst_b,
   fsabi_valid, fsabi_did, fsabi_subdid, fsabi_data, spamo_valid,
   spamo_r_nw, spamo_did, spamo_addr, spamo_data, target_clk,
   target_rst_b, request
   );

	`include "fsab_defines.vh"
	`include "spam_defines.vh"
	`include "dma_config_defines.vh"
	
	input cclk;
	input cclk_rst_b;
	
	/* FSAB interface */
	output reg                  dmac__fsabo_valid = 0;
	output reg [FSAB_REQ_HI:0]  dmac__fsabo_mode = 0;
	output reg [FSAB_DID_HI:0]  dmac__fsabo_did = 0;
	output reg [FSAB_DID_HI:0]  dmac__fsabo_subdid = 0;
	output reg [FSAB_ADDR_HI:0] dmac__fsabo_addr = 0;
	output reg [FSAB_LEN_HI:0]  dmac__fsabo_len = 0;
	output reg [FSAB_DATA_HI:0] dmac__fsabo_data = 0;
	output reg [FSAB_MASK_HI:0] dmac__fsabo_mask = 0;
	input                       dmac__fsabo_credit;
	
	input                       fsabi_clk;
	input                       fsabi_rst_b;
	input                       fsabi_valid;
	input      [FSAB_DID_HI:0]  fsabi_did;
	input      [FSAB_DID_HI:0]  fsabi_subdid;
	input      [FSAB_DATA_HI:0] fsabi_data;
	
	input                       spamo_valid;
	input                       spamo_r_nw;
	input      [SPAM_DID_HI:0]  spamo_did;
	input      [SPAM_ADDR_HI:0] spamo_addr;
	input      [SPAM_DATA_HI:0] spamo_data;

	input                       target_clk;
	input                       target_rst_b;

        /* User */
        input                       request;	       
 
        output reg [63:0]           data;
	output reg                  data_ready;
	output                      fifo_empty;


	output                      dmac__spami_busy_b;
	output reg [SPAM_DATA_HI:0] dmac__spami_data;
	
	`include "clog2.vh"
	parameter FIFO_DEPTH = 128; /* must be a power of 2 */
	parameter FIFO_HI = clog2(FIFO_DEPTH) - 2;
	
	parameter FSAB_DID = 4'hF;
	parameter FSAB_SUBDID = 4'hF;
	
	parameter SPAM_DID = 4'hx;
	parameter SPAM_ADDRPFX = 24'h000000;
	parameter SPAM_ADDRMASK = 24'hFFFFE0;

	parameter DEFAULT_ADDR = 31'h00000000;
	parameter DEFAULT_LEN = 31'h00000000;


`ifdef verilator	
	initial begin
		assert(FSAB_DID != 4'hF && FSAB_SUBDID != 4'hF && SPAM_DID != 4'hF) else $error("Unconfigured DID and SUBDID in SimpleDMAReadController");
	end
`endif

	/* FSAB Logic Begin */

	/*** Queue of all the things read so far. ***/
	reg [FSAB_DATA_HI:0] fifo [(FIFO_DEPTH-1):0];
	reg [FIFO_HI+1:0] curr_fifo_length = 0;
	reg [FIFO_HI+1:0] next_fifo_length = 0;
        reg [FIFO_HI:0] fifo_rpos = 0;
	reg [FIFO_HI:0] fifo_wpos = 0;
	reg [FSAB_ADDR_HI:0] next_fsab_addr = DEFAULT_ADDR;

	wire start_read;	
	wire fifo_almost_full;
	reg read_pending = 0;
	reg triggered = 0;

        /* Config */ 
        wire [FSAB_ADDR_HI:0] next_start_addr;
        wire [FSAB_ADDR_HI:0] next_len;

	/* Curr Start Addr */
	reg [FSAB_ADDR_HI:0] curr_start_addr_tclk;
	wire [FSAB_ADDR_HI:0] curr_start_addr_cclk;

	/* Total Bytes Delivered */
	reg [FSAB_ADDR_HI:0] total_bytes_delivered_tclk = 0;
	wire [FSAB_ADDR_HI:0] total_bytes_delivered_cclk;

	/* Bytes Read */
	reg [FSAB_ADDR_HI:0] fifo_bytes_read_tclk = 0;
	wire [FSAB_ADDR_HI:0] fifo_bytes_read_cclk;
        
        /* This is sort of gross, but oh well. */
	reg [COMMAND_REGISTER_HI:0] command_register = DMA_STOP;
	reg [COMMAND_REGISTER_HI:0] command_register_next = DMA_STOP;
	wire [COMMAND_REGISTER_HI:0] command_register_bus;
	wire command_register_bus_written;

	reg [FSAB_ADDR_HI:0] end_addr = DEFAULT_ADDR+DEFAULT_LEN;
	/*** FSAB credit availability logic ***/
	
	wire start_trans;
	
	reg [FSAB_CREDITS_HI:0] fsab_credits = FSAB_INITIAL_CREDITS;
	wire fsab_credit_avail = (fsab_credits != 0);
	always @(posedge target_clk or negedge target_rst_b) begin
		if (!target_rst_b) begin
			fsab_credits <= FSAB_INITIAL_CREDITS;
		end else begin
			if (dmac__fsabo_credit | dmac__fsabo_valid) begin
			`ifdef verilator
				$display("PRELOAD: Credits: %d (+%d, -%d)", fsab_credits, dmac__fsabo_credit, dmac__fsabo_valid);
			`endif
			end
			fsab_credits <= fsab_credits + (dmac__fsabo_credit ? 1 : 0) - (dmac__fsabo_valid ? 1 : 0);
		end
	end


	/* TODO: This is only reading 8 bytes from FSAB at a time.
	   Needs to do a batch read. (Possibly reading 64 bytes at a time like a cache?) */
	assign fifo_almost_full = ((FIFO_DEPTH-8) < curr_fifo_length);
	assign fifo_empty = (curr_fifo_length == 0);
	assign start_read = !fifo_almost_full && !read_pending && fsab_credit_avail && triggered;

	always @(*)
	begin
		dmac__fsabo_valid = 0;
		dmac__fsabo_mode = {(FSAB_REQ_HI+1){1'bx}};
		dmac__fsabo_did = {(FSAB_DID_HI+1){1'bx}};
		dmac__fsabo_subdid = {(FSAB_DID_HI+1){1'bx}};
		dmac__fsabo_addr = {(FSAB_ADDR_HI+1){1'bx}};
		dmac__fsabo_len = {{FSAB_LEN_HI+1}{1'bx}};
		dmac__fsabo_data = {{FSAB_DATA_HI+1}{1'bx}};
		dmac__fsabo_mask = {{FSAB_MASK_HI+1}{1'bx}};
		if (start_read && target_rst_b)
		begin
			dmac__fsabo_valid = 1;
			dmac__fsabo_mode = FSAB_READ;
			dmac__fsabo_did = FSAB_DID;
			dmac__fsabo_subdid = FSAB_SUBDID;
			dmac__fsabo_addr = next_fsab_addr;
			dmac__fsabo_len = 'h8; 
		end	
	end

			

	reg current_read = 0;
	reg current_read_fclk_s1 = 0;
	reg current_read_fclk = 0;
	reg completed_read_fclk = 0;
	reg completed_read_s1 = 0;
	reg completed_read = 0;

	always @(*) begin
		command_register_next = command_register;
		
		if (!triggered && (command_register == DMA_TRIGGER_ONCE))
			command_register_next = DMA_STOP;
		
		if (command_register_bus_written) begin
			command_register_next = command_register_bus;
			`ifdef verilator
				$display("DMA: command_register_bus_written");
			`endif
		end
	end


	always @(posedge target_clk or negedge target_rst_b) begin
		if (!target_rst_b) begin
			read_pending <= 0;
			current_read <= 0;
			completed_read <= 0;
			completed_read_s1 <= 0;
			curr_fifo_length <= 0;
			curr_start_addr_tclk <= DEFAULT_ADDR;
			next_fsab_addr <= DEFAULT_ADDR;
			triggered <= 0;
			command_register <= DMA_STOP;
			end_addr <= DEFAULT_ADDR+DEFAULT_LEN;
			fifo_bytes_read_tclk <= 0;
		end else begin
			completed_read_s1 <= completed_read_fclk;
			completed_read <= completed_read_s1;

			command_register <= command_register_next;

			curr_fifo_length <= next_fifo_length;

			if (!triggered) begin
				case (command_register)
					DMA_TRIGGER_ONCE: begin
						triggered <= 1;
						next_fsab_addr <= next_start_addr;
						curr_start_addr_tclk <= next_start_addr;
						end_addr <= next_start_addr+next_len;
					end
					DMA_AUTOTRIGGER: begin
						triggered <= 1;
						next_fsab_addr <= next_start_addr;
						curr_start_addr_tclk <= next_start_addr;
						end_addr <= next_start_addr+next_len;
					end
					DMA_STOP: begin
					end
					default: begin
					`ifdef verilator
						$display("DMA: Invalid command register mode");
					`endif
					end	
				endcase 
			end else begin
				if (start_read) begin
					read_pending <= 1;
					current_read <= ~current_read;
				end else if ((completed_read == current_read) && read_pending) begin
					read_pending <= 0;
					if (end_addr == next_fsab_addr + 64) begin
						triggered <= 0;
						fifo_bytes_read_tclk <= 0;
					end
					else begin
						fifo_bytes_read_tclk <= fifo_bytes_read_tclk + 64;
						next_fsab_addr <= next_fsab_addr + 64;
					end
				end
			end	
		end
	end

	always @(posedge target_clk or negedge target_rst_b) begin
		if (!target_rst_b) begin
			data_ready <= 0;
			fifo_rpos <= 0;
			total_bytes_delivered_tclk <= 0;
		end else begin
			if (request && !fifo_empty) begin
				total_bytes_delivered_tclk <= total_bytes_delivered_tclk + 8;
				data <= fifo[fifo_rpos];
				data_ready <= 1;
				fifo_rpos <= fifo_rpos + 'h1;
			end else 
				data_ready <= 0;
		end
	end

	reg [2:0] fifo_fill_pos_fclk = 0;
	reg current_read_1a_fclk = 0;
				
	always @(posedge fsabi_clk or negedge fsabi_rst_b) begin
		if (!fsabi_rst_b) begin
			current_read_fclk_s1 <= 0;
			current_read_fclk <= 0;
			completed_read_fclk <= 0;
			fifo_fill_pos_fclk <= 0;
			current_read_1a_fclk <= 0;
			fifo_wpos <= 0;
		end else begin
			current_read_fclk_s1 <= current_read;
			current_read_fclk <= current_read_fclk_s1;
			current_read_1a_fclk <= current_read_fclk;
			if (current_read_fclk ^ current_read_1a_fclk) begin
				fifo_fill_pos_fclk <= 0;
			end else if (fsabi_valid && (fsabi_did == FSAB_DID) && (fsabi_subdid == FSAB_SUBDID)) begin
				if (fifo_fill_pos_fclk == 7) /* Done? */
					completed_read_fclk <= current_read_fclk;
				fifo[fifo_wpos] <= fsabi_data;
				fifo_wpos <= fifo_wpos + 1;
				fifo_fill_pos_fclk <= fifo_fill_pos_fclk + 1;	
			end
		end
	end

	always @(*) begin
		next_fifo_length = curr_fifo_length;
		if (request && !fifo_empty) begin
			next_fifo_length = next_fifo_length - 1;
		end
		if (triggered & ((completed_read == current_read) && read_pending)) begin
			next_fifo_length = next_fifo_length + 8;
		end 
	end

	/* Config */
	
	wire wr_decode = spamo_valid && !spamo_r_nw && 
	                 ((spamo_addr & SPAM_ADDRMASK) == SPAM_ADDRPFX) &&
	                 (spamo_did == SPAM_DID);
	wire rd_decode = spamo_valid && spamo_r_nw &&
	                 ((spamo_addr & SPAM_ADDRMASK) == SPAM_ADDRPFX) &&
	                 (spamo_did == SPAM_DID);
	                 
	
	always @(*) begin
		if (wr_decode) begin
		`ifdef verilator
			$display("CSR: wr_decode, rst %d", target_rst_b);
		`endif
		end
	end

	
	wire wr_done_strobe_NEXT_START_REG;
	CSRAsyncWrite #(.WIDTH       (FSAB_ADDR_HI+1),
	               .RESET_VALUE (DEFAULT_ADDR))
		CSR_NEXT_START_REG (/* NOT AUTOINST */
		                    // Outputs
		                    .wr_wait_cclk       (),
		                    .wr_done_strobe_cclk(wr_done_strobe_NEXT_START_REG),
		                    .wr_strobe_tclk     (),
		                    .wr_data_tclk       (next_start_addr[FSAB_ADDR_HI:0]),
		                    // Inputs
		                    .cclk               (cclk),
		                    .tclk               (target_clk),
		                    .rst_b_cclk         (cclk_rst_b),
		                    .rst_b_tclk         (target_rst_b),
		                    .wr_strobe_cclk     (wr_decode && (spamo_addr[DMA_SPAM_ADDR_HI:0] == NEXT_START_REG_ADDR)),
		                    .wr_data_cclk       (spamo_data[FSAB_ADDR_HI:0]));

	wire wr_done_strobe_NEXT_LEN_REG;
	CSRAsyncWrite #(.WIDTH       (FSAB_ADDR_HI+1),
	               .RESET_VALUE (DEFAULT_LEN))
		CSR_NEXT_LEN_REG (/* NOT AUTOINST */
		                  // Outputs
		                  .wr_wait_cclk       (),
		                  .wr_done_strobe_cclk(wr_done_strobe_NEXT_LEN_REG),
		                  .wr_strobe_tclk     (),
		                  .wr_data_tclk       (next_len[FSAB_ADDR_HI:0]),
		                  // Inputs
		                  .cclk               (cclk),
		                  .tclk               (target_clk),
		                  .rst_b_cclk         (cclk_rst_b),
		                  .rst_b_tclk         (target_rst_b),
		                  .wr_strobe_cclk     (wr_decode && (spamo_addr[DMA_SPAM_ADDR_HI:0] == NEXT_LEN_REG_ADDR)),
		                  .wr_data_cclk       (spamo_data[FSAB_ADDR_HI:0]));
	
	wire wr_done_strobe_COMMAND_REG;
	CSRAsyncWrite #(.WIDTH       (COMMAND_REGISTER_HI+1),
	               .RESET_VALUE (DMA_STOP))
		CSR_COMMAND_REG (/* NOT AUTOINST */
		                 // Outputs
		                 .wr_wait_cclk       (),
		                 .wr_done_strobe_cclk(wr_done_strobe_COMMAND_REG),
		                 .wr_strobe_tclk     (command_register_bus_written),
		                 .wr_data_tclk       (command_register_bus[COMMAND_REGISTER_HI:0]),
		                 // Inputs
		                 .cclk               (cclk),
		                 .tclk               (target_clk),
		                 .rst_b_cclk         (cclk_rst_b),
		                 .rst_b_tclk         (target_rst_b),
		                 .wr_strobe_cclk     (wr_decode && (spamo_addr[DMA_SPAM_ADDR_HI:0] == COMMAND_REG_ADDR)),
		                 .wr_data_cclk       (spamo_data[COMMAND_REGISTER_HI:0]));


	wire rd_done_strobe_FIFO_BYTES_READ;
	wire rd_done_strobe_TOTAL_BYTES_DELIVERED;
	wire rd_done_strobe_CURR_START_ADDR;
	CSRAsyncRead #(.WIDTH        (FSAB_ADDR_HI+1))
		CSR_FIFO_BYTES_READ (/* NOT AUTOINST */
				     // Outputs
				     .rd_data_cclk	(fifo_bytes_read_cclk),
				     .rd_wait_cclk	(),
				     .rd_done_strobe_cclk(rd_done_strobe_FIFO_BYTES_READ),
				     .rd_strobe_tclk	(),
				     // Inputs
				     .cclk		(cclk),
				     .tclk		(target_clk),
				     .rst_b_cclk	(cclk_rst_b),
				     .rst_b_tclk	(target_rst_b),
				     .rd_strobe_cclk	(rd_decode && (spamo_addr[DMA_SPAM_ADDR_HI:0] == FIFO_BYTES_READ_REG_ADDR)),
				     .rd_data_tclk	(fifo_bytes_read_tclk));

	CSRAsyncRead #(.WIDTH        (FSAB_ADDR_HI+1))
		CSR_TOTAL_BYTES_DELIVERED (/* NOT AUTOINST */
				     // Outputs
				     .rd_data_cclk	(total_bytes_delivered_cclk),
				     .rd_wait_cclk	(),
				     .rd_done_strobe_cclk(rd_done_strobe_TOTAL_BYTES_DELIVERED),
				     .rd_strobe_tclk	(),
				     // Inputs
				     .cclk		(cclk),
				     .tclk		(target_clk),
				     .rst_b_cclk	(cclk_rst_b),
				     .rst_b_tclk	(target_rst_b),
				     .rd_strobe_cclk	(rd_decode && (spamo_addr[DMA_SPAM_ADDR_HI:0] == TOTAL_BYTES_DELIVERED_REG_ADDR)),
				     .rd_data_tclk	(total_bytes_delivered_tclk));

	CSRAsyncRead #(.WIDTH        (FSAB_ADDR_HI+1))
		CURR_START_ADDR (/* NOT AUTOINST */
				     // Outputs
				     .rd_data_cclk	(curr_start_addr_cclk),
				     .rd_wait_cclk	(),
				     .rd_done_strobe_cclk(rd_done_strobe_CURR_START_ADDR),
				     .rd_strobe_tclk	(),
				     // Inputs
				     .cclk		(cclk),
				     .tclk		(target_clk),
				     .rst_b_cclk	(cclk_rst_b),
				     .rst_b_tclk	(target_rst_b),
				     .rd_strobe_cclk	(rd_decode && (spamo_addr[DMA_SPAM_ADDR_HI:0] == CURR_START_REG_ADDR)),
				     .rd_data_tclk	(curr_start_addr_tclk));


	always @ (*) begin
		if (rd_done_strobe_FIFO_BYTES_READ) begin
			dmac__spami_data = {{(SPAM_DATA_HI-FSAB_ADDR_HI){1'b0}}, fifo_bytes_read_cclk};
		end
		else if (rd_done_strobe_TOTAL_BYTES_DELIVERED) begin
			dmac__spami_data = {{(SPAM_DATA_HI-FSAB_ADDR_HI){1'b0}}, total_bytes_delivered_cclk};
		end
		else if (rd_done_strobe_CURR_START_ADDR) begin
			dmac__spami_data = {{(SPAM_DATA_HI-FSAB_ADDR_HI){1'b0}}, curr_start_addr_cclk};
		end
		else begin
			dmac__spami_data = 0;
		end
	end

	assign dmac__spami_busy_b = wr_done_strobe_COMMAND_REG | wr_done_strobe_NEXT_LEN_REG | wr_done_strobe_NEXT_START_REG | rd_done_strobe_FIFO_BYTES_READ | rd_done_strobe_TOTAL_BYTES_DELIVERED | rd_done_strobe_CURR_START_ADDR;


	always @(posedge cclk) begin
		if (rd_done_strobe_FIFO_BYTES_READ) begin
			$display("DMA: %x bytes read", dmac__spami_data);
		end
		if (rd_done_strobe_TOTAL_BYTES_DELIVERED) begin
			$display("DMA: %x bytes delivered", dmac__spami_data);
		end
		if (rd_decode) begin
			$display("DMA: SPAMO_ADDR: %x", spamo_addr);
		end
	end


endmodule

// Local Variables:
// verilog-library-directories:("." "../console" "../core" "../fsab" "../spam" "../fsab/sim" "../util")
// End:
