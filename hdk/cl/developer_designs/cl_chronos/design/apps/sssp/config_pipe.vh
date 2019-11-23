`define USE_PIPELINED_TEMPLATE

parameter APP_NAME = "sssp";
parameter APP_ID = 0;
parameter RISCV = 0;

parameter ARG_WIDTH = 1;

parameter RW_WIDTH = 32;
parameter DATA_WIDTH = 64;

parameter RW_BASE_ADDR = 20;
parameter OFFSET_BASE_ADDR = 12;
parameter NEIGHBOR_BASE_ADDR = 16;
 

parameter LOG_N_SUB_TYPES = 2;


`define RO_WORKER sssp_ro
`define RW_WORKER sssp_rw

