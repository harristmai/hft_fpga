`include "common_types.svh"

module orderbook #(
  parameter int WINDOW_SIZE  = 1024,   // Clipped window: ±512 price levels ($5.12 range @ 1¢ tick)
  parameter int QTY_BITS     = 32,
  parameter int OID_BITS     = 32,
  parameter int MAX_ORDERS   = 12288,  // Aggressive: 12K orders (~196KB BRAM)
  parameter int HASH_BITS    = $clog2(MAX_ORDERS),
  parameter int LEVEL_BITS   = $clog2(WINDOW_SIZE)
)(
  input  logic      clk,
  input  logic      rst_n,

  // Book message input (from parser)
  input  logic      in_valid,
  output logic      in_ready,
  input  book_msg_t in_msg,

  // Top-of-book outputs (registered)
  output logic [31:0] best_bid_price,
  output logic [31:0] best_bid_qty,
  output logic [31:0] best_ask_price,
  output logic [31:0] best_ask_qty
);

  // =============================================================================
  // ARCHITECTURE OVERVIEW:
  // - Clipped sliding window of price levels (WINDOW_SIZE = 1024 levels = ±$5.12)
  // - Hash table for order tracking with linear probing (12K orders)
  // - Incremental best bid/ask tracking (no linear scans)
  // - Multi-cycle pipelined state machine
  // - Memory budget: ~250KB BRAM (12K×16B orders + 8KB levels, leaves 260KB for algo)
  // =============================================================================

  // -------------------------------
  // 1) Clipped Price Window
  // -------------------------------
  // Price window is relative to a base price that moves dynamically
  logic [31:0] window_base_price;    // Lowest price in current window
  logic [QTY_BITS-1:0] bid_qty [WINDOW_SIZE];
  logic [QTY_BITS-1:0] ask_qty [WINDOW_SIZE];

  // Track best bid/ask indices within window for O(1) access
  logic [LEVEL_BITS-1:0] best_bid_idx;
  logic [LEVEL_BITS-1:0] best_ask_idx;
  logic best_bid_valid;
  logic best_ask_valid;

  // Convert absolute price to window index
  function automatic logic [LEVEL_BITS-1:0] price_to_index(
    input logic [31:0] abs_price
  );
    logic [31:0] offset;
    offset = abs_price - window_base_price;
    // Clamp to window bounds
    if (offset >= WINDOW_SIZE)
      return LEVEL_BITS'(WINDOW_SIZE - 1);
    else
      return offset[LEVEL_BITS-1:0];
  endfunction

  // -------------------------------
  // 2) Order Hash Table (BRAM-friendly)
  // -------------------------------
  typedef struct packed {
    logic                 valid;
    logic [OID_BITS-1:0]  order_id;
    side_e                side;
    logic [31:0]          price;       // Store absolute price
    logic [QTY_BITS-1:0]  qty;
  } order_entry_t;

  // Dual-port BRAM for order table (synthesis will infer BRAM)
  order_entry_t order_table_a;
  order_entry_t order_table_b;
  logic [HASH_BITS-1:0] order_addr_a;
  logic [HASH_BITS-1:0] order_addr_b;
  logic order_we_a;
  order_entry_t order_din_a;

  // BRAM inference - Port A (read/write)
  always_ff @(posedge clk) begin
    if (order_we_a) begin
      order_table_mem[order_addr_a] <= order_din_a;
    end
    order_table_a <= order_table_mem[order_addr_a];
  end

  // BRAM inference - Port B (read-only for lookups)
  always_ff @(posedge clk) begin
    order_table_b <= order_table_mem[order_addr_b];
  end

  // Actual BRAM storage
  order_entry_t order_table_mem [MAX_ORDERS];

  // Hash function
  function automatic logic [HASH_BITS-1:0] hash_oid(
    input logic [OID_BITS-1:0] oid
  );
    // Simple modulo hash with upper bits XOR for better distribution
    return oid[HASH_BITS-1:0] ^ oid[2*HASH_BITS-1:HASH_BITS];
  endfunction

  // -------------------------------
  // 3) Multi-Cycle FSM
  // -------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_HASH_LOOKUP,
    S_LINEAR_PROBE,
    S_UPDATE_QTY,
    S_UPDATE_BEST,
    S_DONE
  } state_e;

  state_e state;

  // Pipeline registers
  book_msg_t msg_reg;
  logic [HASH_BITS-1:0] probe_idx;
  logic [HASH_BITS-1:0] probe_cnt;
  logic [HASH_BITS-1:0] found_slot;
  logic slot_found;
  logic [LEVEL_BITS-1:0] level_idx;
  logic [QTY_BITS-1:0] qty_delta;
  logic update_bid;

  // Ready when idle
  assign in_ready = (state == S_IDLE);

  // -------------------------------
  // 4) Sequential State Machine
  // -------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      window_base_price <= 32'd100_00;  // Start at $100.00 (in cents)
      best_bid_idx <= '0;
      best_ask_idx <= '0;
      best_bid_valid <= 1'b0;
      best_ask_valid <= 1'b0;
      best_bid_price <= '0;
      best_bid_qty <= '0;
      best_ask_price <= '0;
      best_ask_qty <= '0;
      order_we_a <= 1'b0;
      
      // Initialize price level arrays only (BRAM initializes to zero automatically)
      for (int i = 0; i < WINDOW_SIZE; i++) begin
        bid_qty[i] <= '0;
        ask_qty[i] <= '0;
      end

    end else begin
      case (state)
        // -------------------------------------
        S_IDLE: begin
          if (in_valid && in_ready) begin
            msg_reg <= in_msg;
            
            // Check if price is outside window - adjust if needed
            if (in_msg.price_tick < window_base_price) begin
              window_base_price <= in_msg.price_tick;
            end else if (in_msg.price_tick >= (window_base_price + WINDOW_SIZE)) begin
              window_base_price <= in_msg.price_tick - WINDOW_SIZE + 32'd1;
            end
            
            // Start hash lookup
            probe_idx <= hash_oid(in_msg.order_id);
            order_addr_a <= hash_oid(in_msg.order_id);
            probe_cnt <= '0;
            slot_found <= 1'b0;
            state <= S_HASH_LOOKUP;
          end
        end

        // -------------------------------------
        S_HASH_LOOKUP: begin
          // Wait 1 cycle for BRAM read
          order_addr_b <= probe_idx;
          state <= S_LINEAR_PROBE;
        end

        // -------------------------------------
        S_LINEAR_PROBE: begin
          // Check if we found the order or an empty slot
          if (order_table_a.valid && order_table_a.order_id == msg_reg.order_id) begin
            // Found existing order
            slot_found <= 1'b1;
            found_slot <= probe_idx;
            state <= S_UPDATE_QTY;
          end else if (!order_table_a.valid) begin
            // Found empty slot for new order
            found_slot <= probe_idx;
            state <= S_UPDATE_QTY;
          end else if (probe_cnt < MAX_ORDERS - 1) begin
            // Continue probing
            probe_cnt <= probe_cnt + 1'b1;
            probe_idx <= (probe_idx + 1'b1) % MAX_ORDERS;
            order_addr_a <= (probe_idx + 1'b1) % MAX_ORDERS;
            state <= S_HASH_LOOKUP;
          end else begin
            // Hash table full - drop message
            state <= S_IDLE;
          end
        end

        // -------------------------------------
        S_UPDATE_QTY: begin
          level_idx <= price_to_index(msg_reg.price_tick);
          
          case (msg_reg.mtype)
            MSG_ADD: begin
              if (!slot_found) begin
                // Add new order
                order_we_a <= 1'b1;
                order_addr_a <= found_slot;
                order_din_a.valid <= 1'b1;
                order_din_a.order_id <= msg_reg.order_id;
                order_din_a.side <= msg_reg.side;
                order_din_a.price <= msg_reg.price_tick;
                order_din_a.qty <= msg_reg.qty;
                
                // Update price level
                if (msg_reg.side == SIDE_BID) begin
                  bid_qty[price_to_index(msg_reg.price_tick)] <= 
                    bid_qty[price_to_index(msg_reg.price_tick)] + msg_reg.qty;
                  update_bid <= 1'b1;
                end else begin
                  ask_qty[price_to_index(msg_reg.price_tick)] <= 
                    ask_qty[price_to_index(msg_reg.price_tick)] + msg_reg.qty;
                  update_bid <= 1'b0;
                end
              end
              state <= S_UPDATE_BEST;
            end

            MSG_CANCEL: begin
              if (slot_found && order_table_a.valid) begin
                // Cancel order
                qty_delta <= order_table_a.qty;
                
                order_we_a <= 1'b1;
                order_addr_a <= found_slot;
                order_din_a <= order_table_a;
                order_din_a.valid <= 1'b0;
                
                // Update price level
                if (order_table_a.side == SIDE_BID) begin
                  bid_qty[price_to_index(order_table_a.price)] <= 
                    bid_qty[price_to_index(order_table_a.price)] - order_table_a.qty;
                  update_bid <= 1'b1;
                end else begin
                  ask_qty[price_to_index(order_table_a.price)] <= 
                    ask_qty[price_to_index(order_table_a.price)] - order_table_a.qty;
                  update_bid <= 1'b0;
                end
              end
              state <= S_UPDATE_BEST;
            end

            MSG_EXEC: begin
              if (slot_found && order_table_a.valid) begin
                // Execute (partial or full)
                qty_delta <= (msg_reg.qty > order_table_a.qty) ? 
                             order_table_a.qty : msg_reg.qty;
                
                order_we_a <= 1'b1;
                order_addr_a <= found_slot;
                order_din_a <= order_table_a;
                order_din_a.qty <= order_table_a.qty - 
                  ((msg_reg.qty > order_table_a.qty) ? order_table_a.qty : msg_reg.qty);
                
                if (order_table_a.qty <= msg_reg.qty) begin
                  order_din_a.valid <= 1'b0;  // Fully executed
                end
                
                // Update price level
                if (order_table_a.side == SIDE_BID) begin
                  bid_qty[price_to_index(order_table_a.price)] <= 
                    bid_qty[price_to_index(order_table_a.price)] - 
                    ((msg_reg.qty > order_table_a.qty) ? order_table_a.qty : msg_reg.qty);
                  update_bid <= 1'b1;
                end else begin
                  ask_qty[price_to_index(order_table_a.price)] <= 
                    ask_qty[price_to_index(order_table_a.price)] - 
                    ((msg_reg.qty > order_table_a.qty) ? order_table_a.qty : msg_reg.qty);
                  update_bid <= 1'b0;
                end
              end
              state <= S_UPDATE_BEST;
            end

            default: begin
              state <= S_IDLE;
            end
          endcase
        end

        // -------------------------------------
        S_UPDATE_BEST: begin
          order_we_a <= 1'b0;
          
          // Incremental best bid/ask update
          if (update_bid) begin
            // Update best bid (highest price with qty > 0)
            if (!best_bid_valid || level_idx > best_bid_idx) begin
              if (bid_qty[level_idx] > 0) begin
                best_bid_idx <= level_idx;
                best_bid_valid <= 1'b1;
                best_bid_price <= window_base_price + {24'd0, level_idx};
                best_bid_qty <= bid_qty[level_idx];
              end
            end else if (level_idx == best_bid_idx && bid_qty[level_idx] == 0) begin
              // Current best was removed - need to find next best
              best_bid_valid <= 1'b0;
              // Simple fallback: mark invalid, could add scan logic here
            end
          end else begin
            // Update best ask (lowest price with qty > 0)
            if (!best_ask_valid || level_idx < best_ask_idx) begin
              if (ask_qty[level_idx] > 0) begin
                best_ask_idx <= level_idx;
                best_ask_valid <= 1'b1;
                best_ask_price <= window_base_price + {24'd0, level_idx};
                best_ask_qty <= ask_qty[level_idx];
              end
            end else if (level_idx == best_ask_idx && ask_qty[level_idx] == 0) begin
              // Current best was removed
              best_ask_valid <= 1'b0;
            end
          end
          
          state <= S_IDLE;
        end

        // -------------------------------------
        default: state <= S_IDLE;
      endcase
    end
  end

  // Output valid signals (optional, for downstream logic)
  logic out_valid;
  assign out_valid = best_bid_valid && best_ask_valid;

endmodule