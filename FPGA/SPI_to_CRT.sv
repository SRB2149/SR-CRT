// Copyright (c) 2026 Stanley Booth
// For enquiries: contact@stanleybooth.uk
//
// SPI_to_CRT.sv

module SPI_to_CRT (
    input   logic N_RESET,
    input   logic sck, 
    input   logic mosi,
    input   logic n_cs,
    output  logic PIXEL,
    output  logic PIXEL_N,
    output  logic SYNC,
    output  logic SYNC_N,
    output  logic pixel,
    output  logic sync
    );
    
    parameter                       N_CS_ERROR_BUF_SIZE = 8;         
    logic [N_CS_ERROR_BUF_SIZE-1:0] lock_n_cs_buf;
    
    logic [14:0]    rd_addr;
    logic [14:0]    wr_addr;
    logic [13:0]    buf_index;
    logic [13:0]    recvd_data_counter;
    logic [7:0]     buf_word;
    logic [7:0]     spi_wrd;
    logic [7:0]     rev_spi_wrd;
    logic           locked_n_cs; //Used to remove errors on n_cs detection.
    logic           clk;
    logic           reset;
    logic           pg_sw;
    logic           data_recvd;
    logic           page_being_read;
    logic           page_being_written;
    
    AMSTRAD_GT65_CRT_Controller crt0 (
        .pixel_buffer_word(buf_word),   //Word from frame buffer at current index
        .clk(clk),                      //Positive edge clk (expects ~ 62.5MHz)
        .reset(reset),                  //Positive edge reset
        .pixel_word_index(buf_index),   //Frame buffer word index
        .pixel(pixel),                  //Pixel data out
        .sync(sync),                    //SYNC signal (active low)
        .page_switch(pg_sw)             //Page Switch signal (active high for 1 cycle)
    );
    
    Gowin_OSC internal_clk0 (
        .oscout(clk) //output oscout @ approx. 62.5MHz
    );
    
    TLVDS_OBUF lvds_pixel (
        .I(pixel),
        .O(PIXEL),
        .OB(PIXEL_N)
    );
    
    TLVDS_OBUF lvds_sync (
        .I(sync),
        .O(SYNC),
        .OB(SYNC_N)
    );
    
    assign rd_addr = {page_being_read, buf_index};
    assign rev_spi_wrd = {<<{spi_wrd}};
    
    DPBSRAM f_buf0 (
        .douta(buf_word),   //output [7:0] douta
        .doutb(/* NC */),   //output [7:0] doutb
        .clka(clk),         //input clka
        .ocea('0),          //input ocea
        .cea('1),           //input cea
        .reseta(reset),     //input reseta
        .wrea('0),          //input wrea
        .clkb(clk),         //input clkb
        .oceb('0),          //input oceb
        .ceb('1),           //input ceb
        .resetb(reset),     //input resetb
        .wreb(data_recvd),  //input wreb
        .ada(rd_addr),      //input [14:0] ada
        .dina('0),          //input [7:0] dina
        .adb(wr_addr),      //input [14:0] adb
        .dinb(rev_spi_wrd)  //input [7:0] dinb
    );
    
    SPI_Slave #(
        .SPI_W(8)	            // The SPI word width in bits (usually 1 byte) 
	) spi_slave0 (
        .word_in('0),	        // Word to transmit to master
        .clk(clk), 		        // Clock (positive edge triggered)
        .reset(reset),		    // Reset (asynchronous active-high)
        .sclk(sck),		        // Serial clock (dual edge triggered depending on if transmitting or recieving)
        .chip_sel(~n_cs),	    // Flag to select this slave controller (active-high)
        .mosi(mosi),		    // Master out, Slave in
        .word_out(spi_wrd),	    // Word recieved from master
        .miso(/*NC*/),		    // Master in, Slave out
        .idle(/*NC*/),		    // Flag that goes high when data is ready to be read
        .data_recvd(data_recvd) // Flag that goes high for one clock cycle (clk not sclk) when data is recieved
	);
 
    assign reset = ~N_RESET;
    
    //Page swapping
    always_ff @ (posedge clk, posedge reset)
    begin
        if (reset)
        begin
            page_being_read <= '0;
        end
        else
        begin
            if (pg_sw && locked_n_cs) //Only swap pages when they are ready
            begin
                page_being_read <= !page_being_read;
            end
        end
    end
    
    assign page_being_written = !page_being_read;
    
    //SPI data counter
    always_ff @ (posedge clk, posedge reset)
    begin
        if (reset)
        begin
            recvd_data_counter <= '0;
        end
        else
        begin
            if (recvd_data_counter == 14'd9471 || locked_n_cs)
            begin
                recvd_data_counter <= '0;
            end
            else if (data_recvd)
            begin
                recvd_data_counter <= recvd_data_counter + 14'd1;
            end
        end
    end
    
    assign wr_addr = {page_being_written, recvd_data_counter};
    
    //n_cs error removal
    genvar i;
    generate
        for (i = 1; i < N_CS_ERROR_BUF_SIZE; i++)
        begin
            always_ff @ (posedge clk, posedge reset)
            begin
                if (reset)
                begin
                    lock_n_cs_buf[i] <= '0;
                end
                else
                begin
                    lock_n_cs_buf[i] <= lock_n_cs_buf[i-1];
                end
            end
        end
    endgenerate
    
    always_ff @ (posedge clk, posedge reset)
    begin
        if (reset)
        begin
            lock_n_cs_buf[0] <= '0;
        end
        else
        begin
            lock_n_cs_buf[0] <= n_cs;
        end
    end
    
    assign locked_n_cs = &lock_n_cs_buf;
    
 
endmodule

// Copyright (c) 2026 Stanley Booth
// For enquiries: contact@stanleybooth.uk
//
// spi_slave.sv
//
// Simple SPI Slave Controller implementation

module SPI_Slave #(
	parameter					SPI_W = 8	// The SPI word width in bits (usually 1 byte) 
	) (
	input	logic [SPI_W-1:0]	word_in,	// Word to transmit to master
	input 	logic 				clk, 		// Clock (positive edge triggered)
	input 	logic 				reset,		// Reset (asynchronous active-high)
	input	logic				sclk,		// Serial clock (dual edge triggered depending on if transmitting or recieving)
	input	logic				chip_sel,	// Flag to select this slave controller (active-high)
	input 	logic 				mosi,		// Master out, Slave in
	output	logic [SPI_W-1:0]	word_out,	// Word recieved from master
	output	logic				miso,		// Master in, Slave out
	output	logic				idle,		// Flag that goes high when data is ready to be read
	output	logic				data_recvd	// Flag that goes high for one clock cycle (clk not sclk) when data is recieved
	);
	
	localparam C_W = $clog2(SPI_W + 1);
	
	logic [SPI_W-1:0]	xmit_word;
	logic [SPI_W-1:0]	recv_word;
	logic [SPI_W-1:0]	word_out_internal;
	logic [SPI_W-1:0]	word_out_buf;
	logic [SPI_W-1:0]	recv_shifted;
	logic [C_W-1:0] 	spi_counter;
	logic				spi_end;
	logic				idle_internal;
	logic				idle_buf;
	logic				idle_data_ready_buf;
	
	always_ff @ (posedge sclk, posedge reset) //Note that this uses sclk
	begin : Counter
		if (reset)
		begin
			spi_counter <= '0;
			idle_internal <= '1;
		end
		else
		begin
			if (chip_sel)
			begin
				if (spi_end)
				begin
					spi_counter <= '0;
					idle_internal <= '1;
				end
				else
				begin
					spi_counter <= spi_counter + C_W'(1);
					idle_internal <= '0;
				end
			end
		end
	end
	
	always_ff @ (posedge sclk, posedge reset) //Note that this uses sclk
	begin : Reciever
		if (reset)
		begin
			recv_word <= '0;
			word_out_internal <= '0;
		end
		else
		begin
			if (spi_end)
			begin
				word_out_internal <= recv_shifted;
			end
			
			if (chip_sel)
			begin
				recv_word <= recv_shifted;
			end
		end
	end
	
	always_ff @ (negedge sclk, posedge reset) //Note that this uses the negative edge of sclk
	begin : Transmitter
		if (reset)
		begin
			xmit_word <= '0;
		end
		else
		begin
			if (chip_sel)
			begin
				if (spi_counter == C_W'(1))
				begin
					xmit_word <= word_in << 1;
				end
				else
				begin
					xmit_word <= xmit_word << 1;
				end
			end
		end
	end
	
	always_ff @ (posedge clk, posedge reset)
	begin : Output_Buffers
		if (reset)
		begin
			word_out_buf <= '0;
			word_out <= '0;
			
			idle_buf <= '1;
			idle <= '1;
			idle_data_ready_buf <= '1;
		end
		else
		begin
			word_out_buf <= word_out_internal;
			word_out <= word_out_buf;
		
			idle_buf <= idle_internal;
			idle <= idle_buf;
			idle_data_ready_buf <= idle;
		end
	end
	
	always_comb
	begin
		miso = xmit_word[SPI_W-1] && chip_sel;
		spi_end = spi_counter == SPI_W - 1;
		recv_shifted = {recv_word[SPI_W-2:0], mosi};
		
		if (spi_counter == '0)
		begin
			miso = word_in[SPI_W-1] && chip_sel;
		end
		else
		begin
			miso = xmit_word[SPI_W-1] && chip_sel;
		end
		
		data_recvd = idle && !idle_data_ready_buf;
	end
	
endmodule