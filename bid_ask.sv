// this module is for the bid/ask processor. it maintains two packed arrays which store bids and asks
// sorted by price and time

module bid_ask #(
    parameter MAX_ORDERS = 32)
(
    input logic clk,
    input logic reset_n,
    input order_msg_t order,

    output logic [31:0] best_bid, // highest price someone is willing to buy
    output logic [31:0] best_ask // lowest price someone is welling to sell

    // still need to determine handshake io between order book table and algorithm
);

// these are the different types of orders i can receive
// subject to change: capital or lower case letters? are there more message types to keep track of?
typedef enum logic [7:0] {
    MSG_ADD = 8'h41, // 'A'
    MSG_DELETE 8'h44, // 'D'
    MSG_UPDATE 8'h55, // 'U'
    MSG_NULL = 8'hff // invalid message types
} message_type_t;

// incoming order format
typedef struct packed {
    message_type_t msg_type;
    logic          side;      // 1 = bid, 0 = ask
    logic [31:0]   order_id;
    logic [31:0]   price;
    logic [31:0]   quantity;
} order_msg_t;

// bid/ask order structs -- it looks like one 32+32+32+1 bit contiguous array
// packed syntax: struct fields become vectorized, msb to lsb in order
// any missing fields? should we combine into one struct with a flag (ie. 1 = bid, 0 = ask)
/*
typedef struct packed {
    logic [31:0] order_id;
    logic [31:0] price;
    logic [31:0] quantity;
    logic valid;
} bid_order_struct;

typedef struct packed {
    logic [31:0] order_id;
    logic [31:0] price;
    logic [31:0] quantity;
    logic valid;
} ask_order_struct;
*/
typedef struct packed {
    logic [31:0] order_id;
    logic [31:0] price;
    logic [31:0] quantity;
    logic valid;
} order_entry_t;

// creating a 16 element array with 97 bit elements
// eg. bid_orders[3].quantity is bits 1-32 of the fourth element in bid_orders
order_entry_t bid_orders [0:MAX_ORDERS-1];
order_entry_t ask_orders [0:MAX_ORDERS-1];

int free_idx;

// main order handling
always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        for (int i = 0; i < MAX_ORDERS; i++) begin
            bid_orders[i].valid <= 1'b0;
            ask_orders[i].valid <= 1'b0;
        end
    end
    else begin
        case(order.msg_type)
            // ADD ORDER
            MSG_ADD: begin
                free_idx = -1;
                if (order.side) begin : ADD_BID
                    for (int i = 0; i < MAX_ORDERS; i++)
                        if (!bid_orders[i].valid && free_idx == -1)
                            free_idx = i;

                    if (free_idx != -1) begin
                        bid_orders[free_idx].order_id <= order.order_id;
                        bid_orders[free_idx].price    <= order.price;
                        bid_orders[free_idx].quantity <= order.quantity;
                        bid_orders[free_idx].valid    <= 1'b1;
                    end
                end
                else begin : ADD_ASK
                    for (int i = 0; i < MAX_ORDERS; i++)
                        if (!ask_orders[i].valid && free_idx == -1)
                            free_idx = i;

                    if (free_idx != -1) begin
                        ask_orders[free_idx].order_id <= order.order_id;
                        ask_orders[free_idx].price    <= order.price;
                        ask_orders[free_idx].quantity <= order.quantity;
                        ask_orders[free_idx].valid    <= 1'b1;
                    end
                end
            end
            // DELETE ORDER
            MSG_DELETE: begin
                if (order.side) begin : DEL_BID
                    for (int i = 0; i < MAX_ORDERS; i++)
                        if (bid_orders[i].valid &&
                            bid_orders[i].order_id == order.order_id)
                            bid_orders[i].valid <= 1'b0;
                end
                else begin : DEL_ASK
                    for (int i = 0; i < MAX_ORDERS; i++)
                        if (ask_orders[i].valid &&
                            ask_orders[i].order_id == order.order_id)
                            ask_orders[i].valid <= 1'b0;
                end
            end
            // UPDATE ORDER
            MSG_UPDATE: begin
                if (order.side) begin : UPD_BID
                    for (int i = 0; i < MAX_ORDERS; i++)
                        if (bid_orders[i].valid &&
                            bid_orders[i].order_id == order.order_id) begin
                            bid_orders[i].price    <= order.price;
                            bid_orders[i].quantity <= order.quantity;
                        end
                end
                else begin : UPD_ASK
                    for (int i = 0; i < MAX_ORDERS; i++)
                        if (ask_orders[i].valid &&
                            ask_orders[i].order_id == order.order_id) begin
                            ask_orders[i].price    <= order.price;
                            ask_orders[i].quantity <= order.quantity;
                        end
                end
            end
            // DEFAULT
            default: begin
                // no-op
            end       
        endcase
    end
end
endmodule bid_ask