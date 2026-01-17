`ifndef COMMON_TYPES_SVH
`define COMMON_TYPES_SVH

typedef enum logic [1:0] {
  MSG_ADD,
  MSG_CANCEL,
  MSG_EXEC
} msg_type_e;

typedef enum logic {
  SIDE_BID,
  SIDE_ASK
} side_e;

typedef struct packed {
  msg_type_e    mtype;
  side_e        side;
  logic [31:0]  order_id;
  logic [31:0]  price_tick;   // price * 100 (cents) or tick units
  logic [31:0]  qty;
} book_msg_t;

`endif // COMMON_TYPES_SVH