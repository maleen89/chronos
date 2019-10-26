
#include <stdarg.h>

const int ADDR_TASK      = 0xc0000000;
const int ADDR_TASK_HINT = 0xc0000004;
const int ADDR_TASK_TTYPE= 0xc0000008;
const int ADDR_TASK_ARG  = 0xc0000100;
const int ADDR_FINISH_TASK   = 0xc0000020;
const int ADDR_UNDO_LOG_ADDR = 0xc0000030;
const int ADDR_UNDO_LOG_DATA = 0xc0000034;
const int ADDR_CUR_CYCLE     = 0xc0000050;
const int ADDR_PRINTF        = 0xc0000040;
const int ADDR_TILE_ID       = 0xc0000060;
const int ADDR_CORE_ID       = 0xc0000064;

typedef unsigned int uint;

void finish_task() {
   *(volatile int *)( ADDR_FINISH_TASK) = 0;
}

static inline void chronos_init() {

   //__asm__( "li a0, 0x80000000;");
   //__asm__( "csrw mtvec, a0;");
   __asm__( "li a0, 0x800;");
   __asm__( "csrw mie, a0;"); // external interrupts enabled
   __asm__( "csrr a0, mstatus;");
   __asm__( "ori a0, a0, 8;"); // interrupts enabled
   __asm__( "csrw mstatus, a0;");

   // Assign a separate stack area for each core
   __asm__( "lui a0, 0xc0000");
   __asm__( "lw a1, 96(a0)"); // tile_id
   __asm__( "lw a2, 100(a0)"); // core_id
   __asm__( "slli a1,a1,4");
   __asm__( "add a1,a1,a2");
   __asm__( "li a2, 0x7e00");
   __asm__( "add a1,a1,a2");
   __asm__( "slli sp,a1,16");

   register int *x asm ("sp");

}

void undo_log_write(uint* addr, uint data) {
   *(volatile int *)( ADDR_UNDO_LOG_ADDR) = (uint) addr;
   *(volatile int *)( ADDR_UNDO_LOG_DATA) = data;
}

void enq_task_arg0(uint ttype, uint ts, uint locale){
     *(volatile int *)( ADDR_TASK_HINT) = (locale);
     *(volatile int *)( ADDR_TASK_TTYPE) = (ttype);
     *(volatile int *)( ADDR_TASK) = ts;
}
void enq_task_arg1(uint ttype, uint ts, uint locale, uint arg0){
     *(volatile int *)( ADDR_TASK_ARG) = (arg0);
     enq_task_arg0(ttype, ts, locale);
}
void enq_task_arg2(uint ttype, uint ts, uint locale, uint arg0, uint arg1){
     *(volatile int *)( ADDR_TASK_ARG + 4) = (arg1);
     enq_task_arg1(ttype, ts, locale, arg0);
}
void enq_task_arg3(uint ttype, uint ts, uint locale, uint arg0, uint arg1, uint arg2){
     *(volatile int *)( ADDR_TASK_ARG + 8) = (arg2);
     enq_task_arg2(ttype, ts, locale, arg0, arg1);
}
void enq_task_arg4(uint ttype, uint ts, uint locale, uint arg0, uint arg1, uint arg2, uint arg3){
     *(volatile int *)( ADDR_TASK_ARG + 12) = (arg3);
     enq_task_arg3(ttype, ts, locale, arg0, arg1, arg2);
}

void deq_task_arg0(uint* ttype, uint* ts, uint* locale) {
      *ts = *(volatile uint *)(ADDR_TASK);
      *locale = *(volatile uint *)(ADDR_TASK_HINT);
      *ttype = *(volatile uint *)(ADDR_TASK_TTYPE);
}
void deq_task_arg1(uint* ttype, uint* ts, uint* locale, uint* arg0) {
      deq_task_arg0(ttype, ts, locale);
      *arg0 = *(volatile uint *)(ADDR_TASK_ARG);
}
void deq_task_arg2(uint* ttype, uint* ts, uint* locale, uint* arg0, uint* arg1) {
      deq_task_arg1(ttype, ts, locale, arg0);
      *arg1 = *(volatile uint *)(ADDR_TASK_ARG + 4);
}
void deq_task_arg3(uint* ttype, uint* ts, uint* locale, uint* arg0, uint* arg1, uint* arg2) {
      deq_task_arg2(ttype, ts, locale, arg0, arg1);
      *arg2 = *(volatile uint *)(ADDR_TASK_ARG + 8);
}
void deq_task_arg4(uint* ttype, uint* ts, uint* locale, uint* arg0, uint* arg1, uint* arg2, uint* arg3) {
      deq_task_arg3(ttype, ts, locale, arg0, arg1, arg2);
      *arg3 = *(volatile uint *)(ADDR_TASK_ARG + 12);
}

// backwards compatibility
void deq_task(uint* ttype, uint* ts, uint* locale, uint* arg0, uint* arg1) {
      *ts = *(volatile uint *)(ADDR_TASK);
      *locale = *(volatile uint *)(ADDR_TASK_HINT);
      *ttype = *(volatile uint *)(ADDR_TASK_TTYPE);
      *arg0 = *(volatile uint *)(ADDR_TASK_ARG);
      *arg1 = *(volatile uint *)(ADDR_TASK_ARG + 4);
}

// Needed to avoid 'undefined reference to _exit'
void exit(int a) {
}
