`define BUS_ICACHE 0

module System(input clk, output wire bubbleshield, output wire [31:0] insn, output wire [31:0] pc);
	wire [7:0] bus_req;
	wire [7:0] bus_ack;
	wire [31:0] bus_addr;
	wire [31:0] bus_rdata;
	wire [31:0] bus_wdata;
	wire bus_rd, bus_wr;
	wire bus_ready;

	wire bus_req_icache;	
	assign bus_req = {7'b0, bus_req_icache};
	wire bus_ack_icache = bus_ack[`BUS_ICACHE];
	
	wire [31:0] bus_addr_icache;
	wire [31:0] bus_wdata_icache;
	wire bus_rd_icache;
	wire bus_wr_icache;
	
	wire [31:0] bus_rdata_blockram;
	wire bus_ready_blockram;
	
	assign bus_addr = bus_addr_icache;
	assign bus_rdata = bus_rdata_blockram;
	assign bus_wdata = bus_wdata_icache;
	assign bus_rd = bus_rd_icache;
	assign bus_wr = bus_wr_icache;
	assign bus_ready = bus_ready_blockram;
	
	wire [31:0] icache_rd_addr;
	wire icache_rd_req;
	wire icache_rd_wait;
	wire [31:0] icache_rd_data;
	
	wire stall_cause_issue;
	
	wire stall_in_fetch = stall_cause_issue;
	wire stall_in_issue = 0;
	
	wire bubble_out_fetch;
	wire bubble_out_issue;
	wire [31:0] insn_out_fetch;
	wire [31:0] insn_out_issue;
	wire [31:0] pc_out_fetch;
	wire [31:0] pc_out_issue;
	
	assign bubbleshield = bubble_out_issue;
	assign insn = insn_out_issue;
	assign pc = pc_out_issue;

	BusArbiter busarbiter(.bus_req(bus_req), .bus_ack(bus_ack));

	ICache icache(
		.clk(clk),
		/* XXX reset? */
		.rd_addr(icache_rd_addr), .rd_req(icache_rd_req),
		.rd_wait(icache_rd_wait), .rd_data(icache_rd_data),
		.bus_req(bus_req_icache), .bus_ack(bus_ack_icache),
		.bus_addr(bus_addr_icache), .bus_rdata(bus_rdata),
		.bus_wdata(bus_wdata_icache), .bus_rd(bus_rd_icache),
		.bus_wr(bus_wr_icache), .bus_ready(bus_ready));
	
	BlockRAM blockram(
		.clk(clk),
		.bus_addr(bus_addr), .bus_rdata(bus_rdata_blockram),
		.bus_wdata(bus_wdata), .bus_rd(bus_rd), .bus_wr(bus_wr),
		.bus_ready(bus_ready_blockram));

	Fetch fetch(
		.clk(clk),
		.Nrst(1 /* XXX */),
		.rd_addr(icache_rd_addr), .rd_req(icache_rd_req),
		.rd_wait(icache_rd_wait), .rd_data(icache_rd_data),
		.stall(stall_in_fetch), .jmp(0 /* XXX */), .jmppc(0 /* XXX */),
		.bubble(bubble_out_fetch), .insn(insn_out_fetch),
		.pc(pc_out_fetch));
	
	Issue issue(
		.clk(clk),
		.Nrst(1 /* XXX */),
		.stall(stall_in_issue), .flush(0 /* XXX */),
		.inbubble(bubble_out_fetch), .insn(insn_out_fetch),
		.inpc(pc_out_fetch), .cpsr(0 /* XXX */),
		.outstall(stall_cause_issue), .outbubble(bubble_out_issue),
		.outpc(pc_out_issue), .outinsn(insn_out_issue));
endmodule
