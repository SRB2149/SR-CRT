// Copyright (c) 2025 Stanley Booth
// amstrad_gt65_crt_controller.sv
//
// A SystemVerilog controller for the Amstrad GT65 Monochrome CRT display
// Supports a resolution of 325x256 pixels (83200 pixels) at a refresh rate
// of 50Hz (so ~4.2Mbps data transfer rate at a pixel clock of 6.25MHz)
//
// The module outputs a PIXEL and SYNC signal, as well as their complements
// for LVDS which the PCB converter requires.
//
// Vertical Counter
//  VSYNC           8
//  Top Porch       20
//  Pixel Rows      256
//  Bottom Porch    28

module AMSTRAD_GT65_CRT_Controller(
    input   logic   clk,        //Positive edge clk (expects 62.5MHz)
    input   logic   reset,      //Positive edge reset
    output  logic   pixel,      //Pixel data out
    output  logic   pixel_n,    //Negation of pixel data out
    output  logic   sync,       //SYNC signal (active low)
    output  logic   sync_n      //Negation of SYNC signal
    );
    
    enum {
        VSYNC,
        TOP_PORCH,
        VERT_PIXEL,
        BOTTOM_PORCH
        } vertical_state_e;
    
    enum {
        HSYNC,
        HORZ_PIXEL,
        BACK_PORCH
        } horizontal_state_e;
        
    logic [11:0]    horizontal_counter;
    logic [8:0]     vertical_counter;
    logic           vsync;
    logic           current_pixel;

    always_ff @ (posedge clk, posedge reset)
    begin
        if (reset)
        begin
            vertical_state_e <= VSYNC;
            horizontal_state_e <= HSYNC;
            
            horizontal_counter <= '0;
            vertical_counter <= '0;
            
            vsync <= '0;
        end
        else
        begin
            unique case(vertical_state_e)
                VSYNC : begin
                    if (vertical_counter == 9'd8)
                    begin
                        vertical_state_e <= TOP_PORCH;
                    end
                    
                    unique case (horizontal_counter)
                        12'd1 : begin //Not zero because of how vertical state switching works
                            vsync <= '1;
                        end
                        
                        12'd1746 : begin //27.3us
                            vsync <= '0;
                        end
                        
                        12'd2000 : begin //4.7us
                            vsync <= '1;
                        end
                        
                        12'd3746 : begin //27.3us
                            vsync <= '0;
                        end
                    
                        default : begin
                            vsync <= vsync;
                        end
                    endcase
                end
                
                TOP_PORCH : begin
                    if (vertical_counter == 9'd28)
                    begin
                        vertical_state_e <= VERT_PIXEL;
                    end
                end
                
                VERT_PIXEL : begin
                    if (vertical_counter == 9'd284)
                    begin
                        vertical_state_e <= BOTTOM_PORCH;
                    end
                end
                
                BOTTOM_PORCH : begin
                    if (vertical_counter == 9'd311)
                    begin
                        vertical_state_e <= VSYNC;
                    end
                end
            endcase
            
            unique case(horizontal_state_e)
                HSYNC : begin
                    if (horizontal_counter == 12'd293)
                    begin
                        horizontal_state_e <= HORZ_PIXEL;
                    end
                end
                
                HORZ_PIXEL : begin
                    if (horizontal_counter == 12'd3543)
                    begin
                        horizontal_state_e <= BACK_PORCH;
                    end
                end
                
                BACK_PORCH : begin
                    if (horizontal_counter == 12'd3999)
                    begin
                        horizontal_state_e <= HSYNC;
                    end
                end
            endcase
            
            if (horizontal_counter == 12'd3999)
            begin
                horizontal_counter <= '0;
                
                if (vertical_counter == 9'd311)
                begin
                    vertical_counter <= '0;
                end
                else
                begin
                    vertical_counter <= vertical_counter + 9'd1;
                end
            end
            else
            begin
                horizontal_counter <= horizontal_counter + 12'd1;
            end
        end
    end
    
    always_comb
    begin
        current_pixel = vertical_counter[0];
        pixel = (horizontal_state_e == HORZ_PIXEL) &&
                (vertical_state_e == VERT_PIXEL) &&
                current_pixel;
        sync = !(vsync || (horizontal_state_e == HSYNC)); //Active Low
    
        pixel_n = !pixel;
        sync_n = !sync;
    end

endmodule