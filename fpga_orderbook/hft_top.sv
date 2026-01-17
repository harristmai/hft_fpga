module hft_top (
  input  logic         clk_100,
  input  logic         rst_n,

  // Avalon‑ST from HPS DMA → parser
  input  logic         s_valid,
  output logic         s_ready,
  input  logic [63:0]  s_data,
  input  logic         s_sop,
  input  logic         s_eop,
  input  logic [2:0]   s_empty,

  // Book/algo observability (to HPS or LEDs)
  output logic [31:0]  best_bid_px,
  output logic [31:0]  best_bid_qty,
  output logic [31:0]  best_ask_px,
  output logic [31:0]  best_ask_qty
);

  // 1) Parser → book message channel
  logic       msg_valid, msg_ready;
  book_msg_t  msg;

  // ITCH parser instance
  itch_parser u_parser (
    .clk      (clk_100),
    .rst_n    (rst_n),
    .s_valid  (s_valid),
    .s_ready  (s_ready),
    .s_data   (s_data),
    .s_sop    (s_sop),
    .s_eop    (s_eop),
    .s_empty  (s_empty),
    .out_valid(msg_valid),
    .out_ready(msg_ready),
    .out_msg  (msg)
  );

  // Order book instance
  orderbook #(
    .WINDOW_SIZE (1024),    // 1024-level sliding window (±$5.12 @ 1¢ tick)
    .MAX_ORDERS  (12288)    // 12K orders (~250KB BRAM total)
  ) u_book (
    .clk            (clk_100),
    .rst_n          (rst_n),
    .in_valid       (msg_valid),
    .in_ready       (msg_ready),
    .in_msg         (msg),
    .best_bid_price (best_bid_px),
    .best_bid_qty   (best_bid_qty),
    .best_ask_price (best_ask_px),
    .best_ask_qty   (best_ask_qty)
  );

endmodule