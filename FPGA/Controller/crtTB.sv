module CRT_TB;

    logic   clk;        //Positive edge clk (expects 62.5MHz)
    logic   reset;      //Positive edge reset
    logic   pixel;      //Pixel data out
    logic   pixel_n;    //Negation of pixel data out
    logic   sync;       //SYNC signal (active low)
    logic   sync_n;     //Negation of SYNC signal
    
    AMSTRAD_GT65_CRT_Controller crt0 (.*);
    
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
        
        //Just letting the CRT run for 1 frame (8000ns per line)
        #2496000ns;
        $stop;
    end
 
endmodule