module CRT_Test (
    input  logic N_RESET,
    output logic PIXEL,
    output logic PIXEL_N,
    output logic SYNC,
    output logic SYNC_N,
    output logic pixel,
    output logic sync
    );
    
    logic [13:0]    buf_index;
    logic [7:0]     buf_word;
    logic           clk;
    logic           reset;
    
    AMSTRAD_GT65_CRT_Controller crt0 (
        .pixel_buffer_word(buf_word), //Word from frame buffer at current index
        .clk(clk),                    //Positive edge clk (expects ~ 62.5MHz)
        .reset(reset),             //Positive edge reset
        .pixel_word_index(buf_index), //Frame buffer word index
        .pixel(pixel),                //Pixel data out
        .sync(sync)                   //SYNC signal (active low)
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
    
    CRT_FRAME_BUFFER_DPBSRAM f_buf0 (
        .douta(buf_word), //output [7:0] douta
        .doutb(/* NC */), //output [7:0] doutb
        .clka(clk), //input clka
        .ocea('0), //input ocea
        .cea('1), //input cea
        .reseta(reset), //input reseta
        .wrea('0), //input wrea
        .clkb('0), //input clkb
        .oceb('0), //input oceb
        .ceb('0), //input ceb
        .resetb('0), //input resetb
        .wreb('0), //input wreb
        .ada(buf_index), //input [13:0] ada
        .dina('0), //input [7:0] dina
        .adb('0), //input [13:0] adb
        .dinb('0) //input [7:0] dinb
    );
 
    assign reset = ~N_RESET;
 
endmodule