`include "common_types.svh"

module itch_parser #(
  parameter int STREAM_W  = 64
)(
  input  logic                 clk,
  input  logic                 rst_n,

  // Avalon-ST input
  input  logic                 s_valid,
  output logic                 s_ready,
  input  logic [STREAM_W-1:0]  s_data,
  input  logic                 s_sop,
  input  logic                 s_eop,
  input  logic [2:0]           s_empty,

  // Parsed book message out
  output logic                 out_valid,
  input  logic                 out_ready,
  output book_msg_t            out_msg
);

  // Unpack 64-bit word into bytes (little-endian)
  logic [7:0] byte_array [0:7];

  always_comb begin
    for (int i = 0; i < 8; i++) begin
      byte_array[i] = s_data[8*i +: 8];
    end
  end

  // FSM
  typedef enum logic [1:0] {
    ST_IDLE,
    ST_READ,
    ST_EMIT
  } state_e;

  state_e state, state_n;

  logic [7:0] len_q;
  logic [7:0] type_q;
  logic [15:0] byte_cnt;

  // Fields being assembled
  logic [31:0] oid_q;
  logic [31:0] price_q;
  logic [31:0] qty_q;
  side_e       side_q;
  msg_type_e   mtype_q;

  // Ready whenever we're not emitting and not stalled
  assign s_ready = (state != ST_EMIT);

  // Sequential state register and reset
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= ST_IDLE;
      len_q    <= '0;
      type_q   <= '0;
      byte_cnt <= '0;
      oid_q    <= '0;
      price_q  <= '0;
      qty_q    <= '0;
      side_q   <= SIDE_BID;
      mtype_q  <= MSG_ADD;
    end else begin
      state <= state_n;
    end
  end

  // Defaults
  always_comb begin
    out_valid = 1'b0;
    out_msg   = '0;
    state_n   = state;

    case (state)
      ST_IDLE: begin
        if (s_valid && s_sop && s_ready) begin
          // first word of message
          len_q      = byte_array[0];
          type_q     = byte_array[1];
          byte_cnt   = 8;           // consumed first 8 bytes

          // init fields
          oid_q      = '0;
          price_q    = '0;
          qty_q      = '0;
          side_q     = SIDE_BID;
          mtype_q    = MSG_ADD;

          state_n    = ST_READ;
        end
      end

      ST_READ: begin
        if (s_valid && s_ready) begin
          int valid_bytes = 8;
          if (s_eop)
            valid_bytes = 8 - s_empty;

          for (int i = 0; i < valid_bytes; i++) begin
            int g = byte_cnt + i;

            // TODO: plug in real offsets from ITCH 5.0 spec.
            // Example layout for "A" (NOT exact; placeholder):
            //  g 2..9   -> order_id (8B)
            //  g 10     -> side ('B'/'S')
            //  g 11..14 -> qty (4B)
            //  g 15..18 -> price (4B)

            unique case (type_q)
              "A": begin
                if (g >= 2 && g < 10) begin
                  int bit_idx = (g - 2)*8;
                  oid_q[bit_idx +: 8] = byte_array[i];
                end else if (g == 10) begin
                  side_q = (byte_array[i] == "B") ? SIDE_BID : SIDE_ASK;
                end else if (g >= 11 && g < 15) begin
                  int bit_idx = (g - 11)*8;
                  qty_q[bit_idx +: 8] = byte_array[i];
                end else if (g >= 15 && g < 19) begin
                  int bit_idx = (g - 15)*8;
                  price_q[bit_idx +: 8] = byte_array[i];
                end
                mtype_q = MSG_ADD;
              end

              "D": begin
                if (g >= 2 && g < 10) begin
                  int bit_idx = (g - 2)*8;
                  oid_q[bit_idx +: 8] = byte_array[i];
                end
                mtype_q = MSG_CANCEL;
              end

              "X",
              "E",
              "C": begin
                if (g >= 2 && g < 10) begin
                  int bit_idx = (g - 2)*8;
                  oid_q[bit_idx +: 8] = byte_array[i];
                end else if (g >= 10 && g < 14) begin
                  int bit_idx = (g - 10)*8;
                  qty_q[bit_idx +: 8] = byte_array[i];
                end
                mtype_q = MSG_EXEC;
              end

              default: begin
                // unsupported types: ignore fields
              end
            endcase
          end

          byte_cnt = byte_cnt + valid_bytes;

          if (s_eop)
            state_n = ST_EMIT;
        end
      end

      ST_EMIT: begin
        if (out_ready) begin
          out_valid          = 1'b1;
          out_msg.mtype      = mtype_q;
          out_msg.side       = side_q;
          out_msg.order_id   = oid_q;
          out_msg.price_tick = price_q;
          out_msg.qty        = qty_q;
          state_n            = ST_IDLE;
        end
      end

      default: state_n = ST_IDLE;
    endcase
  end

endmodule