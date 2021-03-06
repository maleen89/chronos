/** $lic$
 * Copyright (C) 2014-2019 by Massachusetts Institute of Technology
 *
 * This file is part of the Chronos FPGA Acceleration Framework.
 *
 * Chronos is free software; you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software
 * Foundation, version 2.
 *
 * If you use this framework in your research, we request that you reference
 * the Chronos paper ("Chronos: Efficient Speculative Parallelism for
 * Accelerators", Abeydeera and Sanchez, ASPLOS-25, March 2020), and that
 * you send us a citation of your work.
 *
 * Chronos is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 */

import chronos::*;

module conflict_serializer #( 
      parameter TILE_ID = 0
	) (
	input clk,
	input rstn,

   // from cores
	output logic           s_valid, 
	input                  s_ready, 
	output task_t          s_rdata, 
   output cq_slice_slot_t s_cq_slot,
   output thread_id_t     s_thread,

   input                  unlock_valid,
   input thread_id_t      unlock_thread,

   input                  finish_task,

   // to cq
   input task_t m_task,
   input cq_slice_slot_t m_cq_slot,
   input logic m_valid,
   output logic m_ready,

   output logic almost_full,

   input cq_full,

   output all_cores_idle,  // for termination checking
   pci_debug_bus_t.master                 pci_debug,
   reg_bus_t.master                       reg_bus

);

   // Takes Task Read requeusts from the cores, serves them while ensuring that
   // no two tasks with the same object are running at the same time.
   //
   // This module maintains a shift register of pending tasks (ready_list), as well as
   // a bit for each task indicating if it conflicts with any running task.
   // When a core makes new a request, earliest conflict-free entry 
   // that matches the request's task-type will be served. 
   // Upon a task-finish, the earliest entry in the shift register with the
   // finishing tasks's object will be set conflict-free.
   
   typedef struct packed {
      logic [LOG_READY_LIST_SIZE-1:0] id;
      logic [OBJECT_WIDTH-1:0] object;
   } task_t_ser;


   localparam READY_LIST_SIZE = 2**LOG_READY_LIST_SIZE;

   logic [LOG_READY_LIST_SIZE-1:0] task_select;

   // runtime configurable parameter on ready list
   logic [LOG_READY_LIST_SIZE-1:0] almost_full_threshold;
   logic [LOG_READY_LIST_SIZE-1:0] full_threshold;

   object_t [N_THREADS-1:0] running_task_object; // Object of the current task running on each core.
                                    // Packed array because all entries are
                                    // accessed simulataneously
   logic [N_THREADS-1:0] running_task_object_valid;

   task_t_ser [READY_LIST_SIZE-1:0] ready_list;

   task_t [READY_LIST_SIZE-1:0] ready_list_task;
   cq_slice_slot_t [READY_LIST_SIZE-1:0] ready_list_cq_slot;

   logic [READY_LIST_SIZE-1:0] ready_list_valid;
   logic [READY_LIST_SIZE-1:0] ready_list_conflict;

   logic [31:0] n_running_tasks, max_running_tasks;
   always_ff @ (posedge clk) begin
      if (!rstn) begin
         n_running_tasks <= 0;
      end else begin
         if (s_valid & s_ready & !finish_task) begin
            n_running_tasks <= n_running_tasks + 1;
         end else if (finish_task & !(s_valid & s_ready)) begin
            n_running_tasks <= n_running_tasks - 1;
         end
      end
   end


   logic [READY_LIST_SIZE-1:0] task_ready;
   
   genvar i,j;

   generate 
      for (j=0;j<READY_LIST_SIZE;j++) begin
         assign task_ready[j] = ready_list_valid[j] & !ready_list_conflict[j]; 
      end
   endgenerate

   always_comb begin
      s_valid = task_ready[task_select] & next_thread_valid & 
                           (n_running_tasks < max_running_tasks);
   end
   assign all_cores_idle = (ready_list_valid ==0) && (running_task_object_valid==0); 

   logic ready_list_free_empty;
   logic ready_list_free_full;
   logic [LOG_READY_LIST_SIZE-1:0] ready_list_next_free_id;
   logic [LOG_READY_LIST_SIZE:0] ready_list_free_occ, ready_list_size;

   logic next_thread_valid;
   logic issue_task;

   logic free_list_empty;

   assign next_thread_valid = !free_list_empty & (free_list_size > (N_THREADS - active_threads));
   assign issue_task = s_valid & s_ready;

   logic [ $clog2(N_THREADS):0] free_list_size, active_threads;
   
   task_t_ser out_entry;
   always_comb begin
      out_entry = ready_list[task_select];
   end

   free_list #(
      .LOG_DEPTH( LOG_READY_LIST_SIZE)
   ) READY_LIST_ID (
      .clk(clk),
      .rstn(rstn),

      .wr_en(s_valid & s_ready),
      .rd_en(m_valid & m_ready),
      .wr_data(out_entry.id),

      .full(ready_list_free_full), 
      .empty(ready_list_free_empty),
      .rd_data(ready_list_next_free_id),

      .size(ready_list_free_occ)
   );

   assign ready_list_size = (READY_LIST_SIZE - ready_list_free_occ);

   free_list #(
      .LOG_DEPTH( $clog2(N_THREADS) )
   ) FREE_LIST_THREAD (
      .clk(clk),
      .rstn(rstn),

      .wr_en(unlock_valid),
      .rd_en(issue_task),
      .wr_data(unlock_thread),

      .full(), 
      .empty(free_list_empty),
      .rd_data(s_thread),

      .size(free_list_size)
   );
   
   lowbit #(
      .OUT_WIDTH(LOG_READY_LIST_SIZE),
      .IN_WIDTH(READY_LIST_SIZE)   
   ) TASK_SELECT (
      .in(task_ready),
      .out(task_select)
   );



   // Stage 2: Update ready_list
   object_t finished_task_object;
   logic [READY_LIST_SIZE-1:0] finished_task_object_match;
   logic [LOG_READY_LIST_SIZE-1:0] finished_task_object_match_select;
   always_comb begin
      finished_task_object = running_task_object[unlock_thread];
   end
   generate 
      for(i=0;i<READY_LIST_SIZE;i++) begin
         assign finished_task_object_match[i] = (finished_task_object == ready_list[i].object) &
                                                unlock_valid & ready_list_valid[i];
      end
   endgenerate

   lowbit #(
      .OUT_WIDTH(LOG_READY_LIST_SIZE),
      .IN_WIDTH(READY_LIST_SIZE)   
   ) FINISHED_TASK_OBJECT_MATCH_SELECT (
      .in(finished_task_object_match),
      .out(finished_task_object_match_select)
   );
   logic [LOG_READY_LIST_SIZE-1:0] next_insert_location;
   
   lowbit #(
      .OUT_WIDTH(LOG_READY_LIST_SIZE),
      .IN_WIDTH(READY_LIST_SIZE)   
   ) NEXT_INSERT_LOC_SELECT (
      .in(~ready_list_valid),
      .out(next_insert_location)
   );

   assign m_ready = (m_valid & !ready_list_valid[next_insert_location]) & 
      (ready_list_size <= full_threshold);

   task_t new_enq_task;
   always_comb begin
      new_enq_task = m_task;
   end

   // checks if new_enq_task is in conflict with any other task, either in the ready
   // list or the running task list
   logic next_insert_task_conflict;
   logic [READY_LIST_SIZE-1:0] next_insert_task_conflict_ready_list;
   logic [N_THREADS-1:0] next_insert_task_conflict_running_tasks;

   generate 
      for (i=0;i<READY_LIST_SIZE;i++) begin
         assign next_insert_task_conflict_ready_list[i] = ready_list_valid[i] & 
                     (ready_list[i].object == new_enq_task.object);
      end
      for (i=0;i<N_THREADS;i++) begin
         assign next_insert_task_conflict_running_tasks[i] = running_task_object_valid[i] & 
                     (running_task_object[i] == new_enq_task.object) & 
                     !(unlock_valid & unlock_thread ==i) ;
      end
   endgenerate
   assign next_insert_task_conflict = m_valid & ((next_insert_task_conflict_ready_list != 0) |
                                             (next_insert_task_conflict_running_tasks != 0));

   // Shift register operations 
   generate 
   for (i=0;i<READY_LIST_SIZE;i++) begin
      always_ff @(posedge clk) begin
         if (!rstn) begin
            ready_list_valid[i] <= 1'b0;
            ready_list_conflict[i] <= 1'b0; 
            ready_list[i] <= 'x;
         end else
         if (issue_task & (i >= task_select)) begin
            // If a task dequeue and enqueue happens at the same cycle,  
            // shift right existing tasks with the incoming task going at the
            // back
            if (m_valid & m_ready & (next_insert_location== i+1)) begin
               ready_list[i].id <= ready_list_next_free_id;
               ready_list[i].object <= new_enq_task.object;
               ready_list_valid[i] <= 1'b1;
               ready_list_conflict[i] <= next_insert_task_conflict; 
            end else if (i != READY_LIST_SIZE-1) begin
               ready_list[i] <= ready_list[i+1];
               ready_list_valid[i] <= ready_list_valid[i+1];
               if ((finished_task_object_match_select == i+1) & finished_task_object_match[i+1]) begin
                  ready_list_conflict[i] <= 1'b0;
               end else begin
                  ready_list_conflict[i] <= ready_list_conflict[i+1];
               end
            end else begin
               // (i== READY_LIST_SIZE-1) and dequeue/no_enqueue -> need to
               // shift in a 0 
               ready_list[i] <= 'x;
               ready_list_valid[i] <= 1'b0;
               ready_list_conflict[i] <= 1'b0;
            end
         end else begin
            // No dequeue, only enqueue
            if (m_valid & m_ready & (next_insert_location== i)) begin
               ready_list[i].id <= ready_list_next_free_id;
               ready_list[i].object <= new_enq_task.object;
               ready_list_valid[i] <= 1'b1;
               ready_list_conflict[i] <= next_insert_task_conflict; 
            end else begin 
               if ((finished_task_object_match_select == i) & finished_task_object_match[i]) begin
                  ready_list_conflict[i] <= 1'b0;
               end
               // other fields unchanged
            end
         end

      end

   end
   endgenerate

   always_ff @(posedge clk) begin
      if (m_valid & m_ready) begin
         ready_list_task[ready_list_next_free_id] <= m_task;
         ready_list_cq_slot[ready_list_next_free_id] <= m_cq_slot;
      end
   end
   
   always_comb begin
      s_rdata = ready_list_task[out_entry.id];
      s_cq_slot = ready_list_cq_slot[out_entry.id];
   end

   assign almost_full = (ready_list_size >= almost_full_threshold);
   
   

   // update object tables
   always_ff @(posedge clk) begin
      if (!rstn) begin
         running_task_object_valid <= 0;
         for (integer j=0;j<N_THREADS;j=j+1) begin
            running_task_object[j] <= 'x;
         end
      end else begin
         for (integer j=0;j<N_THREADS;j=j+1) begin
            if (s_valid & s_ready & (j==s_thread)) begin
               running_task_object_valid[j] <= 1'b1;
               running_task_object[j] <= s_rdata.object;
            end else if (unlock_valid & (unlock_thread ==j)) begin
               running_task_object_valid[j] <= 1'b0;
               running_task_object[j] <= 'x;
            end
         end
      end
   end


   // stats
   logic [31:0] stat_no_task;
   logic [31:0] stat_cq_stall;
   logic [31:0] stat_task_issued;
   logic [31:0] stat_task_not_accepted;
   logic [31:0] stat_no_thread;
   logic [31:0] stat_cr_full; // all tasks are conflicted, but cannot new task because cr full

   logic [31:0] stat_cr_full_no_enq; // could not enq task because full

generate 
if (SERIALIZER_STATS[TILE_ID]) begin
   always_ff @(posedge clk) begin
      if (!rstn) begin
         stat_no_task <= 0;
         stat_cq_stall <= 0;
         stat_task_issued <= 0;
         stat_task_not_accepted <= 0;
         stat_no_thread <= 0;
         stat_cr_full <=0 ;
         stat_cr_full_no_enq <= 0;
      end else begin
         if (s_valid) begin
            if (s_ready) stat_task_issued <= stat_task_issued + 1;
            else stat_task_not_accepted <= stat_task_not_accepted + 1;
         end else begin
            if (!task_ready[task_select]) begin
               if (almost_full) stat_cr_full <= stat_cr_full + 1;
               else if (cq_full) stat_cq_stall <= stat_cq_stall + 1;
               else stat_no_task <= stat_no_task + 1;
            end else begin
               stat_no_thread <= stat_no_thread + 1;
            end
         end
         if (almost_full) stat_cr_full_no_enq <= stat_cr_full_no_enq + 1;
      end
   end
end
endgenerate

   logic log_s_valid;
   
   logic [4:0] ready_list_stall_threshold;
   always_ff @(posedge clk) begin
      if (!rstn) begin
         almost_full_threshold    <= READY_LIST_SIZE - 4;
         full_threshold    <= READY_LIST_SIZE - 1;
         ready_list_stall_threshold <= READY_LIST_SIZE - 4;
         active_threads <= N_THREADS;
         max_running_tasks <= 127;
      end else begin
         if (reg_bus.wvalid) begin
            case (reg_bus.waddr) 
               SERIALIZER_SIZE_CONTROL : begin
                  almost_full_threshold <= reg_bus.wdata[7:0];
                  full_threshold <= reg_bus.wdata[15:8];
                  ready_list_stall_threshold <= reg_bus.wdata[23:16];
               end
               SERIALIZER_N_THREADS: active_threads <= reg_bus.wdata;
               SERIALIZER_LOG_S_VALID: log_s_valid <= reg_bus.wdata[0];
               SERIALIZER_N_MAX_RUNNING_TASKS : max_running_tasks <= reg_bus.wdata;
            endcase
         end
      end
   end
   logic [LOG_LOG_DEPTH:0] log_size; 
   always_ff @(posedge clk) begin
      if (!rstn) begin
         reg_bus.rvalid <= 1'b0;
         reg_bus.rdata <= 'x;
      end else
      if (reg_bus.arvalid) begin
         reg_bus.rvalid <= 1'b1;
         casex (reg_bus.araddr) 
            DEBUG_CAPACITY : reg_bus.rdata <= log_size;
            SERIALIZER_READY_LIST : reg_bus.rdata <= {ready_list_valid, ready_list_conflict};
            SERIALIZER_DEBUG_WORD  : reg_bus.rdata <= {free_list_size, s_thread, s_valid};
            SERIALIZER_S_OBJECT : reg_bus.rdata <= s_rdata.object;
            SERIALIZER_STAT + 0 : reg_bus.rdata <= stat_no_task;
            SERIALIZER_STAT + 4 : reg_bus.rdata <= stat_cq_stall;
            SERIALIZER_STAT + 8 : reg_bus.rdata <= stat_task_issued;
            SERIALIZER_STAT +12 : reg_bus.rdata <= stat_task_not_accepted;
            SERIALIZER_STAT +16 : reg_bus.rdata <= stat_no_thread;
            SERIALIZER_STAT +20 : reg_bus.rdata <= stat_cr_full;
            SERIALIZER_STAT +24 : reg_bus.rdata <= stat_cr_full_no_enq;
         endcase
      end else begin
         reg_bus.rvalid <= 1'b0;
      end
   end

// Debug

if (SERIALIZER_LOGGING[TILE_ID]) begin
   logic log_valid;
   typedef struct packed {

      logic [5:0] free_list_size;
      logic [5:0] s_thread;

      logic [15:0] s_arvalid;
      logic [15:0] s_rvalid;
      logic [31:0] s_rdata_object;
      logic [31:0] s_rdata_ts;

      // 32
      logic [6:0] s_cq_slot;
      logic [3:0] s_rdata_ttype;
      logic finished_task_valid;
      logic [5:0] finished_task_thread;
      logic [13:0] unused_1;
      logic [31:0] ready_list_valid;
      logic [31:0] ready_list_conflict;

      logic [31:0] m_ts;
      logic [31:0] m_object;

      logic [3:0] m_ttype;
      logic [6:0] m_cq_slot;
      logic m_valid;
      logic m_ready;
      logic [15:0] finished_task_object_match;
      logic [2:0] unused_2;
      
   
      

   } cq_log_t;
   cq_log_t log_word;
   always_comb begin
      log_valid = (m_valid & m_ready) | (s_valid & (s_ready | log_s_valid) ) | unlock_valid;

      log_word = '0;

      log_word.free_list_size = free_list_size;
      log_word.s_thread = s_thread;

      log_word.s_arvalid = s_valid;
      log_word.s_rvalid = s_ready;
      log_word.s_rdata_object = s_rdata.object;
      log_word.s_rdata_ts = s_rdata.ts;
      log_word.s_rdata_ttype = s_rdata.ttype;
      log_word.s_cq_slot = s_cq_slot;

      log_word.finished_task_valid = unlock_valid;
      log_word.finished_task_thread = unlock_thread;

      log_word.ready_list_valid = ready_list_valid;
      log_word.ready_list_conflict = ready_list_conflict;

      log_word.m_object = new_enq_task.object;
      log_word.m_ts = new_enq_task.ts;
      log_word.m_ttype = new_enq_task.ttype;
      log_word.m_cq_slot = m_cq_slot;

      log_word.finished_task_object_match = finished_task_object_match;

      log_word.m_valid = m_valid;
      log_word.m_ready = m_ready;
   end

   log #(
      .WIDTH($bits(log_word)),
      .LOG_DEPTH(LOG_LOG_DEPTH)
   ) SERIALIZER_LOG (
      .clk(clk),
      .rstn(rstn),

      .wvalid(log_valid),
      .wdata(log_word),

      .pci(pci_debug),

      .size(log_size)

   );
end
endmodule
