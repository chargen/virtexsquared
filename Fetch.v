module Fetch(
	input clk,
	input Nrst,
	
	output wire [31:0] rd_addr,
	output wire rd_req,
	input rd_wait,
	input [31:0] rd_data,
	
	input stall,
	input jmp,
	input [31:0] jmppc,
	output reg bubble = 1,
	output reg [31:0] insn = 0,
	output reg [31:0] pc = 32'hFFFFFFFC);
	
	reg qjmp = 0;	/* A jump has been queued up while we were waiting. */
	reg [31:0] qjmppc;
	always @(posedge clk or negedge Nrst)
		if (!Nrst)
			qjmp <= 0;
		else if ((rd_wait || stall) && jmp)
			{qjmp,qjmppc} <= {jmp, jmppc};
		else if (!rd_wait && !stall && qjmp)	/* It has already been intoed. */
			{qjmp,qjmppc} <= {1'b0, 32'hxxxxxxxx};
	
	reg [31:0] reqpc;
	always @(*)
		if (stall)
			reqpc = pc;
		else if (qjmp)
			reqpc = qjmppc;
		else if (jmp)
			reqpc = jmppc;
		else
			reqpc = pc + 4;
	
	assign rd_addr = reqpc;
	assign rd_req = 1;
	
	always @(posedge clk or negedge Nrst)
	begin
		if (!Nrst) begin
			pc <= 32'hFFFFFFFC;
			bubble <= 1;
		end else if (!stall)
		begin
			bubble <= rd_wait;
			insn <= rd_data;
			if (!rd_wait)
				pc <= reqpc;
		end
	end
endmodule
