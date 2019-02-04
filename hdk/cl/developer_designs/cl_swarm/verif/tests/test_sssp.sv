// Amazon FPGA Hardware Development Kit
//
// Copyright 2016 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Amazon Software License (the "License"). You may not use
// this file except in compliance with the License. A copy of the License is
// located at
//
//    http://aws.amazon.com/asl/
//
// or in the "license" file accompanying this file. This file is distributed on
// an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or
// implied. See the License for the specific language governing permissions and
// limitations under the License.


module test_sssp();

import tb_type_defines_pkg::*;
import swarm::*;

// AXI ID
parameter [5:0] AXI_ID = 6'h0;

logic [31:0] rdata;

integer fid, status, timeout_count;
integer line;
integer n_lines;

logic [31:0] file[*];

logic [63:0] log_start_addr;
logic [511:0] log_entry;

logic [31:0] ocl_addr, ocl_data; 
integer dist_actual, dist_ref;
logic [31:0] target_node;
integer num_errors;

localparam HOST_SPILL_AREA = 32'h1000000;
localparam CL_SPILL_AREA = (1<<30);
   
logic [31:0] addr, data;

logic [31:0] enq_ts;
logic [31:0] enq_hint;
logic [31:0] enq_args;

integer BASE_END;

initial begin
  
   for (int i=0;i<1;i++) begin
   tb.power_up();
   
   line = 0;
   n_lines = 0;
   if (RISCV) begin
      load_riscv_program();      
   end
   if (APP_NAME == "des") begin 
      fid = $fopen("input_net", "r");
   end
   if (APP_NAME == "sssp" || APP_NAME == "sssp_hls") begin 
      fid = $fopen("input_graph", "r");
   end
   if (APP_NAME == "astar") begin 
      fid = $fopen("input_astar", "r");
   end
   if (APP_NAME == "color") begin 
      fid = $fopen("input_color", "r");
   end
   if (APP_NAME == "maxflow") begin 
      fid = $fopen("input_maxflow", "r");
   end
   while (!$feof(fid)) begin
      status = $fscanf(fid, "%8x\n", line);
      file[n_lines] = line;
      n_lines = n_lines + 1;
   end
   $display("Read %d lines from input file",n_lines);  

   // Put file in host memory       
   for (int i = 0 ; i < n_lines ; i++) begin
      tb.hm_put_byte(.addr(i*4  ), .d(file[i][ 7: 0]));
      tb.hm_put_byte(.addr(i*4+1), .d(file[i][15: 8]));
      tb.hm_put_byte(.addr(i*4+2), .d(file[i][23:16]));
      tb.hm_put_byte(.addr(i*4+3), .d(file[i][31:24]));
   end
   
   // Initialize Splitter Stack and scratchpad
   for (i=0;i<4;i++) begin
      tb.hm_put_byte(.addr(HOST_SPILL_AREA + STACK_PTR_ADDR_OFFSET + i), .d(0));
   end
   for (i=0;i< (1<<LOG_SPLITTER_STACK_SIZE) ; i++) begin
      tb.hm_put_byte(.addr(HOST_SPILL_AREA + STACK_BASE_OFFSET +  i*2  ), .d(i[ 7:0]));
      tb.hm_put_byte(.addr(HOST_SPILL_AREA + STACK_BASE_OFFSET +  i*2+1), .d(i[15:8]));
   end
   for (i=SCRATCHPAD_BASE_OFFSET; i<SCRATCHPAD_END_OFFSET;i++) begin
      tb.hm_put_byte(.addr(HOST_SPILL_AREA + i), .d(0));
   end

   target_node = file[1] - 1; // numV-1
   `ifndef SIMPLE_MEMORY
       tb.nsec_delay(1000);
       tb.poke_stat(.addr(8'h0c), .ddr_idx(0), .data(32'h0000_0000));
       tb.poke_stat(.addr(8'h0c), .ddr_idx(1), .data(32'h0000_0000));
       tb.poke_stat(.addr(8'h0c), .ddr_idx(2), .data(32'h0000_0000));
      #25us;
   `endif
   
   `ifdef FAST_MEM_INIT   
      for (int i=0;i< n_lines*4; i++) begin
         addr = {i[31:8], i[5:0]};
         data = {24'b0, tb.hm_get_byte(i)};
         case (i[7:6])
            0: tb.card.fpga.CL.\mem_ctrl[0].MEM_CTRL .memory[ addr ] = data;
            1: tb.card.fpga.CL.\mem_ctrl[1].MEM_CTRL .memory[ addr ] = data;
            2: tb.card.fpga.CL.\mem_ctrl[2].MEM_CTRL .memory[ addr ] = data;
            3: tb.card.fpga.CL.\mem_ctrl[3].MEM_CTRL .memory[ addr ] = data;
         endcase
      end
   `else
      tb.que_buffer_to_cl(.chan(0), .src_addr(0),
         .cl_addr(64'h0000_0000_0000), .len(n_lines*4) );  // move buffer to DDR 

      //$display("[%t] : starting H2C DMA channels ", $realtime);
      //Start transfers of data to CL DDR
      tb.start_que_to_cl(.chan(0));   

      // wait for dma transfers to complete
      timeout_count = 0;       
      do begin
         status = tb.is_dma_to_cl_done(.chan(0));
         #10ns;
         timeout_count++;
      end while ((status == 0) && (timeout_count < 2000));

      if (timeout_count >= 2000000) begin
         $display("[%t] : *** ERROR *** Timeout waiting for dma transfers from cl", $realtime);
      end
   `endif
   for (i=0;i<N_TILES;i++) begin
      $display("Initialing stack tile %d", i);
      tb.que_buffer_to_cl(.chan(0),
         .src_addr(HOST_SPILL_AREA),
         .cl_addr(CL_SPILL_AREA + i * TOTAL_SPILL_ALLOCATION ), 
         .len(SCRATCHPAD_END_OFFSET) );   

      tb.start_que_to_cl(.chan(0));

      do begin
         status = tb.is_dma_to_cl_done(.chan(0)); #10ns;
      end while (status == 0);
   end
   $display("Stack initiaized"); 
   // END DMA
   
   ocl_addr[31:24] = 0;
   for (i=0;i<N_TILES;i++) begin
      // set sssp base addresses
      ocl_addr[23:16] = i;
      ocl_addr[15:8] = ID_ALL_APP_CORES;

      // set splitter base addresses
      ocl_addr[15:8] = ID_COAL_AND_SPLITTER;
      ocl_addr[7:0] = SPILL_ADDR_STACK_PTR;
      tb.poke(.addr(ocl_addr), .data(  (CL_SPILL_AREA + i*TOTAL_SPILL_ALLOCATION) >> 6  ),
         .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 

      ocl_addr[7:0] = SPILL_BASE_STACK;
      tb.poke(.addr(ocl_addr), .data(
         (CL_SPILL_AREA + i*TOTAL_SPILL_ALLOCATION + STACK_BASE_OFFSET) >> 6 ) ,
         .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 

      ocl_addr[7:0] = SPILL_BASE_SCRATCHPAD;
      tb.poke(.addr(ocl_addr), .data(
         (CL_SPILL_AREA + i*TOTAL_SPILL_ALLOCATION + SCRATCHPAD_BASE_OFFSET) >> 6 ) ,
         .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      
      ocl_addr[7:0] = SPILL_BASE_TASKS;
      tb.poke(.addr(ocl_addr), .data(
         (CL_SPILL_AREA + i*TOTAL_SPILL_ALLOCATION + SPILL_TASK_BASE_OFFSET) >> 6 ) ,
         .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
/*
      ocl_addr[7:0] = TASK_UNIT_SPILL_THRESHOLD;
      ocl_data = 48;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
*/  

      // Start coalesecer early
      ocl_addr[15:8] = ID_COAL;
      ocl_addr [7:0] = CORE_START;
      ocl_data = '1;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 

      if (APP_NAME == "maxflow") begin
         ocl_addr[15:8] = ID_TASK_UNIT;
         ocl_addr[7:0] = TASK_UNIT_IS_TRANSACTIONAL;
         tb.poke(.addr(ocl_addr), .data(1),
            .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 

         // eg: valid transactional ids if INTERVAL = 10
         // 0..1023, 1040..2047, 2064:3071 etc..
         // GR is trigerred at every multiple of GLOBAL_RELABEL_INTERVAL 
         ocl_addr[7:0] = TASK_UNIT_GLOBAL_RELABEL_START_MASK;
         ocl_data = (1<< file[10]) - 1;
         tb.poke(.addr(ocl_addr), .data(ocl_data),
            .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
         
         ocl_addr[7:0] = TASK_UNIT_GLOBAL_RELABEL_START_INC;
         tb.poke(.addr(ocl_addr), .data(32'h10),
            .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 

      end

/*
      ocl_addr[15:8] = ID_TASK_UNIT;
      ocl_addr[7:0] = TASK_UNIT_TIED_CAPACITY;
      ocl_data = 16;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      ocl_addr[7:0] = TASK_UNIT_SPILL_SIZE;
      ocl_data = 16;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      ocl_addr[15:8] = ID_TASK_UNIT;
      ocl_addr[7:0] = TASK_UNIT_SPILL_THRESHOLD;
      // has to be greater than (TIED_CAPACITY + CQ_SIZE + SPILL_SIZE)
      // why: n_untied_tasks = n_tasks - n_tied_tasks
      // however upto CQ_SIZE tasks could have been dequeued
      // and the coalescer needs at least SPILL_SIZE tasks to proceed 
      ocl_data = 66;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      ocl_addr[15:8] = ID_TASK_UNIT;
      ocl_addr[7:0] = TASK_UNIT_CLEAN_THRESHOLD;
      ocl_data = 4070;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
*/

   // TODO: sanity checks
   // SPILL_THRESHOLD > (TIED_CAP + CQ_SIZE + SPILL_SIZE)
   // SPILL_SIZE % 8 ==0
   // SPILL_SIZE < 2**LOG_TQ_SPILL_SIZE
   // TIED_CAPACITY < 2**LOG_TQ_SIZE
   // CLEAN_THRESH < 2**TQ_STAGES-1
    

   end

if (APP_NAME == "des") begin
   BASE_END = file[10];
   for (i = 0;i<N_TILES;i++) begin
      ocl_addr[23:16] = i; 
      ocl_addr[15:8] = 0; // Component
      ocl_addr[ 7:0] = OCL_TASK_ENQ_TTYPE;
      tb.poke(.addr(ocl_addr), .data(1),
         .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   end
   for (i=0;i<file[11];i++) begin // numI
      enq_ts = 0;
      enq_hint = file[ file[7] + i] ; 
      enq_args = 0 ; 

      ocl_addr = 0;
      ocl_addr[23:16] = (enq_hint >> 4) % N_TILES; // tile TODO: depends on enq_hint
      ocl_addr[15:8] = 0; // Component
      ocl_addr[ 7:0] = OCL_TASK_ENQ_HINT;
      tb.poke(.addr(ocl_addr), .data(enq_hint),
         .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      ocl_addr[ 7:0] = OCL_TASK_ENQ_ARGS;
      tb.poke(.addr(ocl_addr), .data(enq_args),
         .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      ocl_addr[ 7:0]  = OCL_TASK_ENQ;
      tb.poke(.addr(ocl_addr), .data(enq_ts),
         .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      $display("Enqueued ts:%d, hint:%d, args:%d", enq_ts, enq_hint, enq_args);
   end
end
if (APP_NAME == "sssp" | APP_NAME == "sssp_hls") begin
   BASE_END = file[8];
   // Enq initial task
   ocl_addr = 0;
   ocl_addr[23:16] = 0; // tile
   ocl_addr[15:8] = 0; // Component
   ocl_addr[ 7:0] = OCL_TASK_ENQ_HINT;
   tb.poke(.addr(ocl_addr), .data(file[7]),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_TTYPE;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0]  = OCL_TASK_ENQ;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
end      
if (APP_NAME == "color") begin
   BASE_END = file[8];
   // Enq initial task
   ocl_addr = 0;
   ocl_addr[23:16] = 0; // tile
   ocl_addr[15:8] = 0; // Component
   ocl_addr[ 7:0] = OCL_TASK_ENQ_ARG_WORD;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_ARGS;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_HINT;
   tb.poke(.addr(ocl_addr), .data(32'h20000),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_TTYPE;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0]  = OCL_TASK_ENQ;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
end      
if (APP_NAME == "astar") begin
   BASE_END = file[10];
   // initial task: queue_vertex 0
   ocl_addr = 0;
   ocl_addr[23:16] = 0; // tile
   ocl_addr[15:8] = 0; // Component
   ocl_addr[ 7:0] = OCL_TASK_ENQ_ARG_WORD;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_ARGS;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_ARG_WORD;
   tb.poke(.addr(ocl_addr), .data(1),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_ARGS;
   tb.poke(.addr(ocl_addr), .data(32'hffffffff),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_HINT;
   tb.poke(.addr(ocl_addr), .data(file[7]),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_TTYPE;
   tb.poke(.addr(ocl_addr), .data(1),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0]  = OCL_TASK_ENQ;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 

end
if (APP_NAME == "maxflow") begin
   ocl_addr = 0;
   ocl_addr[23:16] = 0; // tile
   ocl_addr[15:8] = 0; // Component
   ocl_addr[ 7:0] = OCL_TASK_ENQ_HINT;
   tb.poke(.addr(ocl_addr), .data(file[7]),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_TTYPE;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0]  = OCL_TASK_ENQ;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_ARG_WORD;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   ocl_addr[ 7:0] = OCL_TASK_ENQ_ARGS;
   tb.poke(.addr(ocl_addr), .data(0),
      .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
end

   for (i=0;i<N_TILES;i++) begin 
      /*
      ocl_addr[23:16] = i;
      ocl_addr[15:8] = ID_TSB;
      ocl_addr[7:0] = TSB_LOG_N_TILES;
      ocl_data = 1;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      
      ocl_addr[23:16] = i;
      ocl_addr[15:8] = ID_CQ;
      ocl_addr[7:0] = CQ_SIZE;
      ocl_data = 32;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      */
   end

   for (i=0;i<N_TILES;i++) begin 
      /*
      ocl_addr[15:8] = ID_ALL_APP_CORES;
      ocl_addr[ 7:0] = CORE_N_DEQUEUES;
      ocl_data = 32'h1;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      */
      ocl_addr[23:16] = i;
      ocl_addr[15:8] = ID_TASK_UNIT;
      ocl_addr[7:0] = TASK_UNIT_START;
      tb.poke(.addr(ocl_addr), .data(1),
         .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      ocl_addr[15:8] = ID_ALL_CORES;
      ocl_addr [7:0] = CORE_START;
      ocl_data = '1;
      //ocl_data = 32'h183;
      tb.poke(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      #1us;
   end
   

   // Test DEBUG interface
//   for (int i=0;i<6;i++) begin
//      #10us;
//      check_log(0,ID_TASK_UNIT);
//   end

   // Wait until sssp completes
   do begin
     
      #300ns;
      if (0 & NON_SPEC) begin
         ocl_addr[23:16] = 0;
         ocl_addr[15:8] = 0;
         ocl_addr[ 7:0] = OCL_DONE;
         tb.peek(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
         ocl_data = (ocl_data == 1) ? '1 :0;
      end else begin
         ocl_addr[23:16] = 0;
         ocl_addr[15:8] = ID_CQ;
         ocl_addr[ 7:0] = CQ_GVT_TS;
         tb.peek(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      end
   end while (ocl_data!='1);

   
   $display("Run Complete. Flushing Cache ...");


   // Flush Caches
   
   // Faster simulation by capping flushing to DIST array
   tb.card.fpga.CL.\tile[0].TILE .L2.L2_STAGE_1.flush_addr_last = (file[3] >> 4);
   //tb.card.fpga.CL.\tile[1].TILE .L2.L2_STAGE_1.flush_addr_last = (file[3] >> 4);
   //tb.card.fpga.CL.\tile[2].TILE .L2.L2_STAGE_1.flush_addr_last = (file[3] >> 4);
   //tb.card.fpga.CL.\tile[3].TILE .L2.L2_STAGE_1.flush_addr_last = (file[3] >> 4);
   //tb.card.fpga.CL.\tile[4].TILE .L2.L2_STAGE_1.flush_addr_last = (file[3] >> 4);
   //tb.card.fpga.CL.\tile[5].TILE .L2.L2_STAGE_1.flush_addr_last = (file[3] >> 4);
   //tb.card.fpga.CL.\tile[6].TILE .L2.L2_STAGE_1.flush_addr_last = (file[3] >> 4);
   //tb.card.fpga.CL.\tile[7].TILE .L2.L2_STAGE_1.flush_addr_last = (file[3] >> 4);

   for (i=0;i<N_TILES;i++) begin
      ocl_addr[23:16] = i;
      ocl_addr[15:8] = ID_L2;
      ocl_addr[ 7:0] = L2_FLUSH;
      tb.poke(.addr(ocl_addr), .data(1),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   end
   do begin
      for (i=0;i<N_TILES;i++) begin
         ocl_addr[23:16] = i;
         ocl_addr[15:8] = ID_L2;
         ocl_addr[ 7:0] = L2_FLUSH;
         tb.peek(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
         if (ocl_data ==1) break;
      end
      #300ns;
   end while (ocl_data==1);

   $display("Reading results back for %3d nodes...", file[1]);
   `ifdef FAST_VERIFY
      for (int i=0;i<file[1]*4;i++) begin
         addr = file[5]*4 + i;
         case (addr[7:6])
            0: data = tb.card.fpga.CL.\mem_ctrl[0].MEM_CTRL .memory[ {addr[31:8], addr[5:0]} ];
            1: data = tb.card.fpga.CL.\mem_ctrl[1].MEM_CTRL .memory[ {addr[31:8], addr[5:0]} ];
            2: data = tb.card.fpga.CL.\mem_ctrl[2].MEM_CTRL .memory[ {addr[31:8], addr[5:0]} ];
            3: data = tb.card.fpga.CL.\mem_ctrl[3].MEM_CTRL .memory[ {addr[31:8], addr[5:0]} ];
         endcase
         tb.hm_put_byte(.addr(BASE_END* 4 + i), .d(data));
      end
   `else
      tb.que_cl_to_buffer(.chan(0), .dst_addr(BASE_END*4), .cl_addr(file[5]*4), .len(file[1]*4) );  
      tb.start_que_to_buffer(.chan(0));   
      timeout_count = 0;       
      do begin
         status = tb.is_dma_to_buffer_done(.chan(0));
         #10ns;
         timeout_count++;          
      end while ((status == 0) && (timeout_count < 3000));
      
      if (timeout_count >= 1000000) begin
         $display("[%t] : *** ERROR *** Timeout waiting for dma transfers from cl", $realtime);
      end
   `endif
   #1us;
   
   $display("Result read. comparing...");
   num_errors = 0;
if (APP_NAME == "des") begin
   for (int i=0;i<file[12];i++) begin  // numOutputs
      dist_ref = file[file[6]+i]; // [31:16] - vid, [1:0] val 
      dist_actual[31:24] = tb.hm_get_byte( (BASE_END + dist_ref[31:16] )* 4 + 3);
      if (dist_ref[1:0] != dist_actual[25:24]) num_errors++;
      $display("vid:%3d dist:%3d, ref:%3d, %s, num_errors%2d", dist_ref[31:16],
            dist_actual[25:24], dist_ref[15:0],
            dist_actual[25:24] == dist_ref[1:0] ? "MATCH" : "FAIL", num_errors); 
   end
end
if (APP_NAME == "sssp" | APP_NAME == "sssp_hls" | APP_NAME == "color" ) begin
   for (int i=0;i<file[1];i++) begin
      dist_actual[ 7: 0] = tb.hm_get_byte( (BASE_END + i)* 4);
      dist_actual[15: 8] = tb.hm_get_byte( (BASE_END + i)* 4+ 1);
      dist_actual[23:16] = tb.hm_get_byte( (BASE_END + i)* 4+ 2);
      dist_actual[31:24] = tb.hm_get_byte( (BASE_END + i)* 4+ 3);
      dist_ref = file [file[6]+i];
      if (dist_actual != dist_ref) num_errors++;
      $display("vid:%3d dist:%3d, ref:%3d, %s, num_errors%2d", i, dist_actual, dist_ref,
            dist_actual == dist_ref ? "MATCH" : "FAIL", num_errors); 
   end
end
if (APP_NAME == "astar") begin
   for (int i=0;i<file[1];i++) begin
      dist_actual[ 7: 0] = tb.hm_get_byte( (BASE_END + i)* 4);
      dist_actual[15: 8] = tb.hm_get_byte( (BASE_END + i)* 4+ 1);
      dist_actual[23:16] = tb.hm_get_byte( (BASE_END + i)* 4+ 2);
      dist_actual[31:24] = tb.hm_get_byte( (BASE_END + i)* 4+ 3);
      dist_ref = file [file[9]+i];
      if (dist_ref == '1) continue;
      if (dist_actual != dist_ref) num_errors++;
      $display("vid:%3d dist:%5d, ref:%5d, %s, num_errors%2d", i, dist_actual, dist_ref,
            dist_actual == dist_ref ? "MATCH" : "FAIL", num_errors); 
   end
end
/* 
   for (int tile=0;tile<N_TILES;tile++) begin
      $display("Tile %d", tile);
      for (int i=1;i<11;i++) begin
         ocl_addr[23:16] = tile;
         ocl_addr[15:8] = i;
         ocl_addr[7:0] = CORE_NUM_ENQ;
         tb.peek(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
         $display("Core %2d num_enqueues:%6d", i, ocl_data); 
         ocl_addr[7:0] = CORE_NUM_DEQ;
         tb.peek(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
         $display("Core %2d num_dequeues:%6d", i, ocl_data); 
      end


      for (int i=0;i<5;i++) begin
         ocl_addr[15:8] = ID_L2;
         ocl_addr[7:0] = L2_READ_HITS + (i*4);
         tb.peek(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
         $display("L2 stat %d :%6d", i, ocl_data); 
      end 
   end
*/

   //check_log(ID_L2);
   //check_log(ID_TASK_UNIT);
/* 
   //    NON-DMA Reads, Uncomment to check AXI mem read function
   $display("Reading results back for %3d nodes...", file[1]);
   ocl_addr[15:8] = 0;
   ocl_addr[7:0] = OCL_ACCESS_MEM_SET_MSB;
   tb.poke(.addr(ocl_addr), .data(0),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   num_errors = 0;
   for (int i=0;i<file[1];i++) begin
      ocl_addr[7:0] = OCL_ACCESS_MEM_SET_LSB;
      ocl_data = (file[5] +i)*4;      
      tb.poke(.addr(ocl_addr), .data(ocl_data),
                .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      ocl_addr[7:0] = OCL_ACCESS_MEM;
      tb.peek(.addr(ocl_addr), .data(ocl_data),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
      dist_ref = file [file[6]+i];
      if (ocl_data != dist_ref) num_errors++;
      $display("vid:%3d dist:%3d, ref:%3d, %s, num_errors%2d", i, ocl_data, dist_ref,
            ocl_data == dist_ref ? "MATCH" : "FAIL", num_errors); 
   end
*/

   ocl_addr[15:8] = ID_ALL_CORES;
   ocl_addr [7:0] = CORE_START;
   ocl_data = 0;
   tb.poke(.addr(ocl_addr), .data(ocl_data),
             .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   
   tb.kernel_reset();


   tb.power_down();


   end

   $display("Target Node %4d, dist:%4d", target_node, file[ file[6] + target_node] ); 

   $finish;
end

logic [63:0] cl_addr;
task check_log;
input [7:0] tile;
input [7:0] id;
begin
   ocl_addr[23:16] = tile;
   ocl_addr[15:8] = id;
   ocl_addr[7:0] = DEBUG_CAPACITY;
   tb.peek(.addr(ocl_addr), .data(ocl_data),
          .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   $display("Log %d has %d records",id, ocl_data);
   if (ocl_data == 0) begin
      return;
   end
   log_start_addr = 64'h8000_0000;
   cl_addr = (1<<36);
   cl_addr[35:28] = tile; 
   cl_addr[27:20] = id; 
   tb.que_cl_to_buffer(.chan(0), .dst_addr(log_start_addr), .cl_addr(cl_addr), .len(ocl_data*64) );  
   tb.start_que_to_buffer(.chan(0));   
   timeout_count = 0;
   do begin
      status = tb.is_dma_to_buffer_done(.chan(0));
      #10ns;
      timeout_count++;          
   end while ((status == 0) && (timeout_count < 1000));
   for (int i=0;i<ocl_data;i++) begin
      for (int j=0;j<64;j++) begin
         log_entry[j*8 +: 8] = tb.hm_get_byte(log_start_addr + i*64 + j);
      end
      $display("log %2d  (%8x, %8x), (%8x %8x)(%8x, %8x) %8x, %8x %8x", i,
         log_entry[31:0], log_entry[63:32],
         log_entry[95:64], log_entry[127:96],
         log_entry[159:128], log_entry[191:160],
         log_entry[224:192], log_entry[255:224],
         log_entry[287:256]
      );

   end
   
   ocl_addr[15:8] = id;
   ocl_addr[7:0] = DEBUG_CAPACITY;
   tb.peek(.addr(ocl_addr), .data(ocl_data),
          .id(AXI_ID), .size(DataSize::UINT16), .intf(AxiPort::PORT_OCL)); 
   $display("Log End %d has %d records",id, ocl_data);


end
endtask

//https://github.com/SpinalHDL/VexRiscv/blob/master/src/test/cpp/regression/main.cpp
task load_riscv_program;
   integer status;
   logic [31:0] offset, byteCount, nextAddr, key;
   logic [31:0] addr, data, mem_ctrl_addr;
   string line; 
   logic [31:0] _main;
   logic [31:0] boot_code [0:3];
   offset = 0;
   fid = $fopen("input_code.hex", "r");
   while (!$feof(fid)) begin
      status = $fgets(line, fid);
      if (line.getc(0) == ":") begin
         status = $sscanf( line.substr(1,2), "%x", byteCount);
         status = $sscanf( line.substr(3,6), "%x", nextAddr);
         nextAddr += offset;
         status = $sscanf( line.substr(7,8), "%x", key);
         if (key ==0 ) begin
            for (integer i=0;i<byteCount; i+=1) begin
               addr = nextAddr + i;
               status = $sscanf( line.substr(9+i*2,9+i*2+1), "%x", data);
               //$display("addr %x data %x", addr, data);
               mem_ctrl_addr = {addr[31:8], addr[5:0]};
               case (addr[7:6])
                  0: tb.card.fpga.CL.\mem_ctrl[0].MEM_CTRL .memory[ mem_ctrl_addr ] = data;
                  1: tb.card.fpga.CL.\mem_ctrl[1].MEM_CTRL .memory[ mem_ctrl_addr ] = data;
                  2: tb.card.fpga.CL.\mem_ctrl[2].MEM_CTRL .memory[ mem_ctrl_addr ] = data;
                  3: tb.card.fpga.CL.\mem_ctrl[3].MEM_CTRL .memory[ mem_ctrl_addr ] = data;
               endcase
               `ifndef FAST_MEM_INIT
                  $dislay("Code-loading supported only under FAST_MEM_INIT");
                  $finish();
               `endif
            end
         end
         if (key == 2) begin
            status = $sscanf( line.substr(9,12), "%x", offset);
            offset = offset << 4;
         end
         if (key == 4) begin
            status = $sscanf( line.substr(9,12), "%x", offset);
            offset = offset << 16;
         end
         //$display("%d %d %d", byteCount, nextAddr, key); 
      end
   end

   //assign _main = 32'h800000bc; 
   assign _main = 32'h80000074; 
   boot_code[0] = {_main[31:12], 5'd1, 7'b0110111};    // lui x1, _main[31:12]
   boot_code[1] = {_main[11:0], 5'd1, 3'b000, 5'd1, 7'b0010011};  // addi x1, x1,  _main[11:0]
   boot_code[2] = 32'h73000137; // li sp, 0x7e000
   boot_code[3] = {12'b0, 5'd1, 3'b000, 5'd0, 7'b1100111};  // jalr x1, 0
   for (integer i=0;i<4; i+=1) begin
      addr = 32'h80000000 + (i*4);
      //$display("addr %x data %x", addr, data);
      mem_ctrl_addr = {addr[31:8], addr[5:0]};
      for (integer j=0;j<4;j++) begin
         data = boot_code[i][j*8 +: 8];
         case (addr[7:6])
            0: tb.card.fpga.CL.\mem_ctrl[0].MEM_CTRL .memory[ mem_ctrl_addr +j] = data;
            1: tb.card.fpga.CL.\mem_ctrl[1].MEM_CTRL .memory[ mem_ctrl_addr +j] = data; 
            2: tb.card.fpga.CL.\mem_ctrl[2].MEM_CTRL .memory[ mem_ctrl_addr +j] = data;
            3: tb.card.fpga.CL.\mem_ctrl[3].MEM_CTRL .memory[ mem_ctrl_addr +j] = data;
         endcase
      end
   end
endtask


endmodule

