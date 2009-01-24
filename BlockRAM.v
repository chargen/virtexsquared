module BlockRAM(
	input clk,
	input [31:0] bus_addr,
	output wire [31:0] bus_rdata,
	input [31:0] bus_wdata,
	input bus_rd,
	input bus_wr,
	output wire bus_ready
	);
	
	/* This module is mapped in physical memory from 0x00000000 to
	 * 0x00004000.  rdata and ready must be driven to zero if the
	 * address is not within the range of this module.
	 */
	wire decode = bus_addr[31:14] == 18'b0;
	wire [13:0] ramaddr = {bus_addr[13:2], 2'b0};	/* mask off lower two bits
							 * for word alignment */

	reg [31:0] data [(16384 / 4 - 1):0];
	
	reg [31:0] temprdata = 0;
	reg [13:0] lastread = 14'h3FFF;
	assign bus_rdata = (bus_rd && decode) ? temprdata : 32'h0;
	
	assign bus_ready = decode &&
		(bus_wr || (bus_rd && (lastread == ramaddr)));
	
	initial
		$readmemh("ram.hex", data);
	
	always @(posedge clk)
	begin
		if (bus_wr && decode)
			data[ramaddr[13:2]] <= bus_wdata;
		
		/* This is not allowed to be conditional -- stupid Xilinx
		 * blockram. */
		temprdata <= (bus_wr && decode) ? bus_wdata : data[ramaddr[13:2]];
		lastread <= ramaddr;
	end
endmodule
