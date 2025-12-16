module CRT_TB;

    logic [7:0]    pixel_buffer_word;  //Word from frame buffer at current index
    logic [13:0]    pixel_word_index;   //Frame buffer word index
    logic           clk;                //Positive edge clk (expects 62.5MHz)
    logic           reset;              //Positive edge reset
    logic           pixel;              //Pixel data out
    logic           sync;               //SYNC signal (active low)
    
    AMSTRAD_GT65_CRT_Controller crt0 (.*);
    
    assign pixel_buffer_word = 8'hAA;
    
    initial
    begin
        clk = '0;
        reset = '0;
        
        #1ns reset = '1;
		#1ns reset = '0;
			
		forever #1ns clk = ~clk;
    end
    
    initial
    begin
        #4ns;
        
        //Just letting the CRT run for one and a bit frames (8360ns per line)
        #2610000ns;
        $stop;
    end
 
endmodule