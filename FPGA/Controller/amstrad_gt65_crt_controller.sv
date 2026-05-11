// Copyright (c) 2025 Stanley Booth
// amstrad_gt65_crt_controller.sv
//
// A SystemVerilog controller for the Amstrad GT65 Monochrome CRT display
// Supports a resolution of 296x256 pixels (75776 pixels) at a refresh rate
// of 50Hz (so ~3.8Mbps data transfer rate at a pixel clock of 6.25MHz)
// HORZ_MAX may need tuning to the specific CRT and FPGA combo due to varying clock frequencies
// and ageing CRT components

// Required pixel layout:
// Pixels read from top left to bottom right and stored one after the other (for 100% packing efficiency)
// To read/write specific pixel:     pixel_index = y * xMax + x
// Word address:                     word_addr   = pixel_index >> 3     (Divide by 8)
// Bit Index:                        bit_index   = pixel_index & 0b111 (select last 3 bits)
// Within each byte the LSB is the start.

module AMSTRAD_GT65_CRT_Controller(
    input   logic [7:0]     pixel_buffer_word,  //Word from frame buffer at current index
    input   logic           clk,                //Positive edge clk (expects around 62.5MHz)
    input   logic           reset,              //Positive edge reset
    output  logic [13:0]    pixel_word_index,   //Frame buffer word index
    output  logic           pixel,              //Pixel data out
    output  logic           sync,               //SYNC signal (active low)
    output  logic           page_switch         //Page Switch signal (active high for 1 cycle)
    );
    
    enum {
        PRE_EQUAL,
        VSYNC,
        POST_EQUAL,
        TOP_PORCH,
        VERT_PIXEL,
        BOTTOM_PORCH
        } vertical_state_e;
    
    enum {
        HORZ_PIXEL,
        FRONT_PORCH,
        HSYNC,
        BACK_PORCH
        } horizontal_state_e;
        
    const logic [12:0] HORZ_MAX = 13'd4179;//4179
    const logic [12:0] HALF_HORZ_MAX = (HORZ_MAX + 13'd1) / 2 - 13'd1;
    
    logic [12:0]    horizontal_counter;
    logic [9:0]     vertical_counter;
    logic [3:0]     pixel_clock_divider;
    logic [2:0]     pixel_index_bit_counter;
    logic           vsync;
    logic           hsync;
    logic           hsync_enable;
    logic           current_pixel;
    logic           vert_pixel_enable;
    logic           horz_pixel_enable;
    logic           draw_enable;
    logic           set_current_pixel;

    always_ff @ (posedge clk, posedge reset)
    begin
        if (reset)
        begin
            vertical_state_e <= PRE_EQUAL;
            horizontal_state_e <= HSYNC;
            
            horizontal_counter <= '0;
            vertical_counter <= '0;
            
            vsync <= '0;
            
            pixel_clock_divider <= '0;
            pixel_word_index <= '0;
            pixel_index_bit_counter <= '0;
            current_pixel <= '0;
            
            page_switch <= '0;
        end
        else
        begin
            page_switch <= '0;
        
            unique case(vertical_state_e)
                PRE_EQUAL : begin
                    if (vertical_counter == 10'd5)
                    begin
                        vertical_state_e <= VSYNC;
                    end
                    
                    unique case (horizontal_counter)
                        13'd0 : begin
                            vsync <= '1;
                        end
                        
                        13'd147 : begin //2.35us
                            vsync <= '0;
                        end
                        
                        13'd2001 : begin //28.9us
                            vsync <= '1;
                        end
                        
                        13'd2147 : begin //2.35us
                            vsync <= '0;
                        end
                    
                        default : begin
                            vsync <= vsync;
                        end
                    endcase
                end
            
                VSYNC : begin
                    if (vertical_counter == 10'd10)
                    begin
                        vertical_state_e <= POST_EQUAL;
                    end
                    
                    unique case (horizontal_counter)
                        13'd0 : begin
                            vsync <= '1;
                        end
                        
                        13'd1706 : begin //27.3us
                            vsync <= '0;
                        end
                        
                        13'd2001 : begin //4.7us
                            vsync <= '1;
                        end
                        
                        13'd3706 : begin //27.3us
                            vsync <= '0;
                        end
                    
                        default : begin
                            vsync <= vsync;
                        end
                    endcase
                end
                
                POST_EQUAL : begin
                    if (vertical_counter == 10'd15)
                    begin
                        vertical_state_e <= TOP_PORCH;
                    end
                    
                    unique case (horizontal_counter)
                        13'd0 : begin
                            vsync <= '1;
                        end
                        
                        13'd147 : begin //2.35us
                            vsync <= '0;
                        end
                        
                        13'd2001 : begin //28.9us
                            vsync <= '1;
                        end
                        
                        13'd2147 : begin //2.35us
                            vsync <= '0;
                        end
                    
                        default : begin
                            vsync <= vsync;
                        end
                    endcase
                end
                
                TOP_PORCH : begin
                    vsync <= '0; //Return VSYNC low
                
                    if (vertical_counter == 10'd86)
                    begin
                        vertical_state_e <= VERT_PIXEL;
                    end
                end
                
                VERT_PIXEL : begin
                    if (vertical_counter == 10'd598)
                    begin
                        vertical_state_e <= BOTTOM_PORCH;
                    end
                end
                
                BOTTOM_PORCH : begin
                    if (vertical_counter == 10'd623 && horizontal_counter == HORZ_MAX)
                    begin
                        vertical_state_e <= PRE_EQUAL;
                        page_switch <= '1;
                    end
                end
            endcase
            
            unique case(horizontal_state_e)
                HORZ_PIXEL : begin
                    if (horizontal_counter == 13'd2959) // 296 pixels per line
                    begin                               // 10CC's per pixel
                        horizontal_state_e <= FRONT_PORCH;
                    end
                end
                
                FRONT_PORCH : begin
                    if (horizontal_counter == 13'd3043)
                    begin
                        horizontal_state_e <= HSYNC;
                    end
                end
                
                HSYNC : begin
                    if (horizontal_counter == 13'd3627)
                    begin
                        horizontal_state_e <= BACK_PORCH;
                    end
                end
                
                BACK_PORCH : begin
                    if (horizontal_counter == HORZ_MAX)
                    begin
                        horizontal_state_e <= HORZ_PIXEL;
                    end
                end
            endcase
            
            //Horizontal Counter
            if (horizontal_counter == HORZ_MAX)
            begin
                horizontal_counter <= '0;
            end
            else
            begin
                horizontal_counter <= horizontal_counter + 13'd1;
            end
            
            //Vertical Counter
            if ((horizontal_counter == HALF_HORZ_MAX) || (horizontal_counter == HORZ_MAX))
            begin
                if (vertical_counter == 10'd623)
                begin
                    vertical_counter <= '0;
                end
                else
                begin
                    vertical_counter <= vertical_counter + 10'd1;
                end
            end
            
            //Pixel Clock Divider
            if (draw_enable)
            begin
                if (pixel_clock_divider == 4'd9)
                begin
                    pixel_clock_divider <= '0;
                end
                else
                begin
                    pixel_clock_divider <= pixel_clock_divider + 4'd1;
                end
                
                //Pixel indexer
                if (pixel_clock_divider == 4'd0)
                begin
                    if (pixel_index_bit_counter == 3'd7)
                    begin
                        pixel_index_bit_counter <= '0;
                        
                        if (pixel_word_index == 14'd9471)
                        begin
                            pixel_word_index <= '0;
                        end
                        else
                        begin
                            pixel_word_index <= pixel_word_index + 14'd1;
                        end
                    end
                    else
                    begin
                        pixel_index_bit_counter <= pixel_index_bit_counter + 3'd1;
                    end
                end
            end
            
            //Pixel Register
            if (set_current_pixel)
            begin
                current_pixel <= pixel_buffer_word[pixel_index_bit_counter];
            end
        end
    end
    
    always_comb
    begin
        hsync = '0;
        hsync_enable = '0;
        vert_pixel_enable = '0;
        horz_pixel_enable = '0;
        set_current_pixel = '0;
        
        unique case(vertical_state_e)
                PRE_EQUAL : begin
                    hsync_enable = '0;
                    vert_pixel_enable = '0;
                end
            
                VSYNC : begin
                    hsync_enable = '0;
                    vert_pixel_enable = '0;
                end
                
                POST_EQUAL : begin
                    hsync_enable = '0;
                    vert_pixel_enable = '0;
                end
                
                TOP_PORCH : begin
                    hsync_enable = '1;
                    vert_pixel_enable = '0;
                    set_current_pixel = '1; // Sets current pixel to start of frame
                end                         // as otherwise would be delayed by 1 pixel
                
                VERT_PIXEL : begin
                    hsync_enable = '1;
                    vert_pixel_enable = '1;
                end
                
                BOTTOM_PORCH : begin
                    hsync_enable = '1;
                    vert_pixel_enable = '0;
                end
                
                default : begin
                    hsync_enable = '0;
                    vert_pixel_enable = '0;
                end
            endcase
            
            unique case(horizontal_state_e)
                HORZ_PIXEL : begin
                    hsync = '0;
                    horz_pixel_enable = '1;
                end
                
                FRONT_PORCH : begin
                    hsync = '0;
                    horz_pixel_enable = '0;
                end
                
                HSYNC : begin
                    hsync = '1;
                    horz_pixel_enable = '0;
                end
                
                BACK_PORCH : begin
                    hsync = '0;
                    horz_pixel_enable = '0;
                end
                
                default : begin
                    hsync = '0;
                    horz_pixel_enable = '0;
                end
            endcase
            
        if (pixel_clock_divider == 4'd9)
        begin
            set_current_pixel = '1;
        end
        
        draw_enable = vert_pixel_enable && horz_pixel_enable;
        pixel = current_pixel && draw_enable;
        sync = !(vsync || (hsync && hsync_enable));
    end

endmodule