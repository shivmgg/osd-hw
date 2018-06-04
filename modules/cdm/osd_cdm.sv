// Might need to be updated
// Copyright 2016 by the authors
//
// Copyright and related rights are licensed under the Solderpad
// Hardware License, Version 0.51 (the "License"); you may not use
// this file except in compliance with the License. You may obtain a
// copy of the License at http://solderpad.org/licenses/SHL-0.51.
// Unless required by applicable law or agreed to in writing,
// software, hardware and materials distributed under this License is
// distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the
// License.
//
// Authors:
//    

import dii_package::dii_flit;

module osd_cdm
  #(parameter CORE_CTRL         =  0, // logic '1' causes the CPU core to stall.
    parameter CORE_REG_UPPER    =  0 // MSB bit-set of the required SPR address
    )
   (
    input                         clk, rst,

    input dii_flit                debug_in, 
    output                        debug_in_ready,
    output dii_flit               debug_out, 
    input                         debug_out_ready,

    input [15:0]                  id,

    output reg                    du_stall_i, // Logic ‘1’ causes CPU to stall
    input                         du_stall_o, // Indicates CPU has reached breakpoint condition
    output reg                    du_stb_i, // Access to the core debug interface
    input                         du_ack_o, // Complete access to the core
    output reg [15:0]             du_adr_i, // Address of CPU register to be read or written
    output reg                    du_we_i, // Write cycle when true, read cycle when false
    output reg [31:0]             du_dat_i, // Write data
    input reg [31:0]              du_dat_o // Read data
   );


   logic        reg_request;
   logic        reg_write;
   logic [15:0] reg_addr;
   logic [1:0]  reg_size;
   logic [15:0] reg_wdata; // Here, changes need to be made for dynamically changing the size of reg_wdata
   logic        reg_ack;
   logic        reg_err;
   logic [15:0] reg_rdata; // Here, changes need to be made for dynamically changing the size of reg_wdata

   logic        stall;

   logic          packet_ready;
   logic [15:0]   packet_data;
   logic          packet_valid;
   logic [15:0]   event_dest;
       
   dii_flit     dp_out, dp_in;
   logic        dp_out_ready, dp_in_ready;

   osd_regaccess_layer
     #(.MOD_VENDOR(16'h1), .MOD_TYPE(16'h6), .MOD_VERSION(16'h0),
       .MAX_REG_SIZE(32), .CAN_STALL(0), .MOD_EVENT_DEST_DEFAULT(16'h0))
   u_regaccess(.*,
               .event_dest (),
               .module_in (dp_out),
               .module_in_ready (dp_out_ready),
               .module_out (dp_in),
               .module_out_ready (dp_in_ready));

   logic [15:0] spr_reg_addr;
   logic [15:0] core_ctrl = CORE_CTRL;
   logic [15:0] core_reg_upper = CORE_REG_UPPER;

  //Debug STALL CPU event packets
  osd_event_packetization_fixedwidth
     #(.DATA_WIDTH(16), .MAX_PKT_LEN(4))
     u_packetization(
        .clk             (clk),
        .rst             (rst),

        .debug_out       (dp_out),
        .debug_out_ready (dp_out_ready),

        .id              (id),
        .dest            (event_dest),
        .overflow        (1'b0),
        .event_available (packet_valid),
        .event_consumed  (packet_ready),

        .data            (packet_data));

  enum {
         STATE_INACTIVE, STATE_REQ, STATE_ADDR, STATE_STALL_CPU, 
         STATE_SPR_REQ, STATE_SPR_ADDR, STATE_SPR_READ, 
         STATE_SPR_WRITE, STATE_ACK
       } state, nxt_state;

   always_ff @(posedge clk) begin
      if (rst) begin
         state <= STATE_INACTIVE;
      end 
      else if (du_stall_o == 1'b1) begin 
         packet_valid <= 1'b1;
         packet_data  <= 16'h1;
      end else if (du_stall_o == 1'b0) begin
         packet_data  <= 1'b0;
         packet_valid <= 1'b0;
         state        <= nxt_state;
      end
   end  

   always_comb begin
     reg_err = 1'b0;
     reg_rdata = 16'hx;
     spr_reg_addr = 16'hx;
     case (state)
      STATE_INACTIVE: begin
           dp_in_ready = 1;
            if (dp_in.valid) begin
               nxt_state = STATE_REQ;
            end
         end //STATE_INACTIVE
      STATE_REQ: begin
            if (reg_request == 1) begin
	       du_stb_i = 1'b1;
               nxt_state = STATE_ADDR;
            end
         end //STATE_REQ
      STATE_ADDR: begin
      	    if (reg_addr[15:7] == 9'h4) begin  //0x200-0x201
              case (reg_addr) 
                 16'h200: nxt_state = STATE_STALL_CPU;  
                 16'h201: begin 
                    if (reg_write == 1'b0) begin                              
	               reg_rdata = core_reg_upper;
                    end 
                    else if (reg_write == 1'b1) begin
                       core_reg_upper = reg_wdata;
                    end
                   end  // case (16'h201)                  
		 default: reg_err = 1'b1;
              endcase // case (reg_addr[15:7])
            end    
            else if (reg_addr[15] == 1) begin //0x8000-0xFFFF
              spr_reg_addr = ((CORE_REG_UPPER << 15) | (reg_addr - 16'h8000));
              nxt_state = STATE_SPR_REQ;  
            end else begin
              reg_err = 1'b1;
              nxt_state = STATE_INACTIVE;
            end
         end //STATE_ADDR
      STATE_STALL_CPU: begin
            if (reg_write == 0) begin
               reg_rdata = core_ctrl;
            end else begin
               core_ctrl = reg_wdata;
               du_stall_i = core_ctrl;
            end
            nxt_state = STATE_ACK;
         end //STATE_STALL_CPU
      STATE_SPR_REQ: begin
            if (reg_write == 0) begin
               du_we_i = 0;
            end else begin
               du_we_i = 1;
            end
            nxt_state = STATE_SPR_ADDR;
         end //STATE_SPR_REQ
      STATE_SPR_ADDR: begin
            if (du_ack_o == 1) begin
               du_adr_i = spr_reg_addr;
               if (reg_write == 0) begin
                  nxt_state = STATE_SPR_READ;
               end else begin
                  nxt_state = STATE_SPR_WRITE;
               end
            end
         end //STATE_SPR_ADDR
      STATE_SPR_READ: begin 
            if (du_ack_o == 1) begin
               reg_rdata = du_dat_o;  //Here, reg_rdata should be 32 bits wide
               nxt_state = STATE_ACK;
            end
         end //STATE_SPR_READ         
      STATE_SPR_WRITE: begin
	    if (du_ack_o == 1) begin
               du_dat_i = reg_wdata;  //Here, reg_wdata should be 32 bits wide
               nxt_state = STATE_ACK;
            end
         end //STATE_SPR_WRITE            
      STATE_ACK: begin
            if (du_ack_o == 1) begin
               reg_ack = 1;
            end
	    nxt_state = STATE_INACTIVE;
         end //STATE_ACK               
     endcase
   end  //always_comb           
                       
endmodule // osd_cdm

