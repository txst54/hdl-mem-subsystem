// The LLC (Last Level Cache) is not only the slowest and largest cache in the
// system, but it also communicates the memory controller, which dispatches
// requests to SDRAM controller.

// The memory controller communicates with the DDR4 SDRAM controller over
// the memory bus. The DDR4 SDRAM controller is aware of the structure of SDRAM
// and is responsible for getting data from SDRAM and sending it over the bus.
// Data is acquired over multiple cycles, since a single read from the row
// buffer will provide less than 64 bits.

// The memory bus is fundamentally a collection of wires. Only one bit can exist
// on a wire at a given time. As far as I, Nate, can tell, the DRAM controller
// does not have a queue. Thus, it is the sole-responsibility of the memory
// controller to make smart queueing policies and performance optimizations to
// minimize latency (if it chooses to). DDR4 is supposed to be pipelined
// however, which gives good throughput.

// A comment indicates that the ready-in on from the memory bus to the LLC may
// go unused. This is because DRAM is pipelined, and the synchronization is done
// via. known latency times, rather than through handshake protocols. Handshake
// protocols do not work well with bi-directional wires anyways.

module last_level_cache #(
    parameter int A = 8,
    parameter int B = 64,
    parameter int C = 16384,
    parameter int PADDR_BITS = 19
) (
    // Generic
    input logic clk_in,
    input logic rst_N_in,  // Resets cache without flushing
    input logic cs_in,  // Chip Select (aka. enable)
    input logic flush_in,  // Flush all of the cache to memory
    // Inputs from Higher-Level Cache
    input logic hc_valid_in,  // data is ready for either lsu or next level cache
    input logic hc_ready_in,  // ready to receive input from LLC. This is priority
    input logic [PADDR_BITS-1:0] hc_addr_in,  // This address being returned may cause an eviction!
    input logic [63:0] hc_value_in,  // The write to the lower-level cache
    input logic hc_we_in,  // Higher-level cache is requesting a read/write
    // Outputs to Higher-Level Caches (remember lower is slower with caches)
    output logic hc_ready_out,  // lower cache is ready (lower is slower)
    output logic hc_valid_out,  // lower cache is sending data to this module
    output logic [PADDR_BITS-1:0] hc_addr_out,  // Address being returned may cause an eviction!
    output logic [63:0] hc_value_out,  // lower
    // Inputs from Memory Bus (SDRAM controller)
    input logic mem_bus_ready_in,  // This might go unsused...
    input logic mem_bus_valid_in,  // DRAM data is valid for LLC to consume
    // InOut on Memory Bus (SDRAM controller)
    inout logic [63:0] mem_bus_value_io,  // Load / Store value for memory module
    // Outputs to Memory Bus (SDRAM controller)
    output logic [PADDR_BITS-1:0] mem_bus_addr_out,  // Load addr for memory module
    output logic mem_bus_ready_out,  // Should ALWAYS be ready to receive data from SDRAM controller
    output logic mem_bus_valid_out
);
    // You may reuse the cache module that the L1D team will work on
    // Your main task will be talking to the DIMM on an eviction or flush.
endmodule : last_level_cache

// A signal is expected to be sent to multiple DDR4 SDRAM chips at a time. You
// do need to consider this, it is done transparently by the DIMM.

// There may be more latencies that aren't accounted for in these parameters,
// but which are needed for communication with the DIMM. Please post on Ed if
// you notice this.

// An SDRAM dimm has no valid/ready information. Data is expected exactly
// CAS_LATENCY signals after it is requested.

module ddr4_sdram_controller #(
    parameter int CAS_LATENCY = 22,  // latency in cycles to get a response from DRAM
    parameter int ACTIVATION_LATENCY = 8,  // latency in cycles to activate row buffer
    parameter int PRECHARGE_LATENCY = 5,  // latency in cycles to precharge (clear row buffer)
    parameter int ROW_BITS = 8,  // log2(ROWS)
    parameter int COL_BITS = 4,  // log2(COLS)
    parameter int PADDR_BITS = 19
) (
    // Generic
    input clk_in,
    input rst_N_in,
    input cs_N_in,
    // Inputs from memory bus
    input logic mem_bus_ready_in,  // DRAM is ready to receive info
    input logic mem_bus_valid_in,  // DRAM data is ready for LLC to consume
    input logic [PADDR_BITS-1:0] mem_bus_addr_in,  // Address from the last-level cache
    // Inout on memory bus
    inout logic [63:0] mem_bus_value_io,  //
    // Outputs to DDR4 SDRAM
    output logic act_out,  // Activate sdram
    output logic [16:0] dram_addr_out,  // row/col or special bits.
    output logic [1:0] bg_out,  // Bank group id
    output logic [1:0] ba_out,  // Bank id
    output logic [63:0] dqm_out,  // Data mask in. Set to one to block masks
    output logic mem_bus_ready_out,  // LLC ready to receive info
    output logic mem_bus_valid_out,  // DRAM info is ready for LLC.
    // Inouts to DDR4 SDRAM
    inout logic [63:0] dqs  // Data ins/outs from all dram chips
);
endmodule : ddr4_sdram_controller


// adjust refresh param based on the actual clock, currently assuming 1 GHz clock => 64 ms = 64,000,000 ns
module autorefresh #(
    parameter int REFRESH = 64_000_000
) (
    input logic clk_in,
    input logic rst_in,
    output logic refresh
);
    localparam WIDTH = $clog2(REFRESH)
    logic [WIDTH-1:0] count;
    always_ff @(posedge clk or posedge rst_in) begin
        if (rst_in) begin
            count <= 0;
            refresh <= 0;
        end else if (count == REFRESH - 1) begin
            count <= 0;
            refresh <= ~refresh;
        end else begin
            count <= count + 1;
        end
    end 
endmodule : autorefresh


// submodule for handling memory request queues
module mem_req_queue #(
    parameter QUEUE_SIZE=16,
    type mem_request_t = logic // default placeholder
) (
    input logic clk_in,
    input logic rst_in,
    input logic enqueue_in,
    input logic dequeue_in,
    input mem_request_t req_in,
    input logic [31:0] cycle_count,
    output mem_request_t req_out,
    output logic empty,
    output logic full
);
    mem_request_t queue[QUEUE_SIZE-1:0];
    mem_request_t next_queue[QUEUE_SIZE-1:0];
    logic [$clog2(QUEUE_SIZE)-1:0] next_head;
    logic [$clog2(QUEUE_SIZE):0] next_size;
    logic [$clog2(QUEUE_SIZE)-1:0] head;
    logic [$clog2(QUEUE_SIZE):0] size;
    always_ff @(posedge clk_in or posedge rst_in) begin
        if (rst_in) begin
            head <= 0;
            size <= 0;
        end else begin
        end
    end

    always_ff @(posedge clk_in) begin
        queue <= next_queue;
    end

    always_comb begin
        next_queue = queue;
        next_size = size;
        next_head = head;
        
        if (enqueue_in && !full) begin
            next_queue[(head + size) % QUEUE_SIZE] = req_in;
            next_size = size + 1;
        end
        if (dequeue_in && !full) begin
            next_size = size - 1;
            next_head = (head + 4'b1) & {$clog2(QUEUE_SIZE){1'b1}}; // % QUEUE_SIZE
        end
    end
    // Full & Empty Flags
    assign req_out = queue[head];
    assign full = (size == QUEUE_SIZE);
    assign empty = (size == 0);
endmodule: mem_req_queue;

// submodule for handling the actual commands, serves as a wrapper for a double queue
module mem_cmd_queue #(
    parameter QUEUE_SIZE = 16,
    parameter LATENCY = 0, // DEFINITELY CHANGE THIS
    type mem_request_t = logic // default placeholder
) (
    input logic clk_in,
    input logic rst_in,
    input logic enqueue_in,
    input logic transfer_ready, // command is available 
    input mem_request_t req_in,
    input logic [31:0] cycle_count,
    input logic promote_ready, // if upper queue is ready for promotion. if it is full or there are incoming requests, those take priority
    output mem_request_t ready_top_out,
    output mem_request_t pending_top_out,
    output logic ready_empty_out, // if empty then top doesnt matter
    output logic pending_empty_out,
    output logic promote // if pending_top_out needs to be dequeued and promoted to the next queue 
);
    logic transfer;
    logic ready_empty;
    logic ready_full;
    logic pending_empty;
    logic pending_full;
    mem_request_t ready_top;
    mem_request_t ready_top_reg; // register to maintain state for timing issues
    mem_request_t pending_top;

    mem_req_queue #(.QUEUE_SIZE(QUEUE_SIZE), .mem_request_t(mem_request_t)) ready(
        .clk_in(clk_in), 
        .rst_in(rst_in), 
        .enqueue_in(enqueue_in), 
        .dequeue_in(transfer), 
        .req_in(req_in), 
        .cycle_count(cycle_count), 
        .req_out(ready_top), 
        .empty(ready_empty), 
        .full(ready_full)
    );
    mem_req_queue #(.QUEUE_SIZE(QUEUE_SIZE), .mem_request_t(mem_request_t)) pending(
        .clk_in(clk_in), 
        .rst_in(rst_in), 
        .enqueue_in(transfer), 
        .dequeue_in(promote && promote_ready), 
        .req_in(ready_top_reg), 
        .cycle_count(cycle_count), 
        .req_out(pending_top), 
        .empty(pending_empty), 
        .full(pending_full)
    );

    // necessary to prevent timing issues with dequeue
    always_ff @(posedge clk_in) begin
        if (promote) begin
            pending_top_out <= pending_top;
        end
        if (transfer) begin
            ready_top_reg <= ready_top;
        end
    end

    assign ready_top_out = ready_top_reg;
    assign ready_empty_out = ready_empty;
    assign pending_empty_out = pending_empty;
    // promote to next queue
    assign promote = !pending_empty & (pending_top.cycle_count + LATENCY <= cycle_count);
    
endmodule: mem_cmd_queue;

module sdram_bank_state #(
    parameter ROW_WIDTH = 14, // Number of bits to address rows (e.g., 14 bits for 16k rows)
    parameter NUM_GROUPS = 2, // Number of bank groups
    parameter BANKS_PER_GROUP = 2, // Number of banks per group
    parameter BANKS = NUM_GROUPS * BANKS_PER_GROUP, // Total number of banks
    type bank_row_t = logic
)(
    input logic clk,               // Clock
    input logic rst,               // Reset
    input logic [BANKS-1:0] bank_enable,  // Enable signal for each bank (1: enabled, 0: disabled)
    input logic [BANKS-1:0] precharge,    // Precharge signal for each bank (1: precharge, 0: no precharge)
    input logic [BANKS-1:0] activate,     // Activate signal for each bank (1: activate, 0: no activate)
    input bank_row_t row_address, // Row address to activate
    input logic [$clog2(BANKS)-1:0] request_data,  // Request data signal for a bank
    output bank_row_t [BANKS-1:0] active_row_out,  // Active row for a selected bank
    output logic [BANKS-1:0] ready_to_access, // Bank ready to access (not in precharge)
    output logic [BANKS-1:0] active_bank      // Bank currently active (activated but not precharged)
);

    // States for each bank
    bank_row_t [BANKS-1:0] active_row;  // Active row address for each bank
    logic [BANKS-1:0] active; // Active flag for each bank
    logic [BANKS-1:0] ready; // Ready flag for each bank (not in precharge)
    
    // Bank grouping logic
    // reg [NUM_GROUPS-1:0] group_active [BANKS_PER_GROUP-1:0]; // Keeps track of group activations
    // reg [BANKS_PER_GROUP-1:0] group_ready [NUM_GROUPS-1:0];  // Ready state for each group

    // Handle bank state updates on each clock cycle
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            // Reset all states to initial values
            // active_row <= {ROW_WIDTH * BANKS{1'b0}};
            active <= {BANKS{1'b0}};
            ready <= {BANKS{1'b1}}; // All banks are initially ready (not in precharge)
            // group_active <= '{default: 0};
            // group_ready <= '{default: 1}; // All groups are initially ready (not in precharge)
        end else begin
            // For each bank, handle precharge, activation, and data request
            for (int i = 0; i < BANKS; i++) begin
                if (bank_enable[i]) begin
                    if (precharge[i]) begin
                        // Precharge operation: bank is not active and ready
                        active[i] <= 0;
                        ready[i] <= 1;  // Bank is ready after precharge
                    end else if (activate[i]) begin
                        // Activate operation: store the row address and mark the bank as active
                        active_row[i] <= row_address;
                        active[i] <= 1; // Bank is active
                        ready[i] <= 0;  // Bank is not ready during activation
                    end else if (request_data[i] && active[i]) begin
                        // Data request: The bank must be active
                        // Here, you can add logic to fetch the requested data from the active row
                    end
                end
            end
        end
    end

    // Group management
    // always_ff @(posedge clk) begin
    //     for (int g = 0; g < NUM_GROUPS; g++) begin
    //         // If any bank in the group is activated, mark the group as active
    //         group_active[g] <= |(activate[g*BANKS_PER_GROUP +: BANKS_PER_GROUP]);
            
    //         // If all banks in the group are in ready state, mark the group as ready
    //         group_ready[g] <= &ready[g*BANKS_PER_GROUP +: BANKS_PER_GROUP];
    //     end
    // end

    // Outputs for each bank and group
    assign active_row_out = active_row; // Example output, can modify based on the active bank/group selection
    assign ready_to_access = ready;        // Ready to access signals for each bank
    assign active_bank = active;          // Active bank signals
    
    // Example: Optionally, you can assign the group-ready state or active state
    // based on a specific bank or group.
    // You can also output the active row of a specific group by selecting which
    // bank or group is relevant at any given time.

endmodule

module request_scheduler #(
    parameter int A = 8,
    parameter int B = 64,
    parameter int C = 16384,
    parameter int BUS_WIDTH = 16,  // bus width per chip
    parameter int BANK_GROUPS = 8,
    parameter int BANKS_PER_GROUP = 8,       // banks per group
    parameter int ROW_BITS = 8,    // bits to address rows
    parameter int COL_BITS = 4,     // bits to address columns
    parameter int QUEUE_SIZE = 16, // set this, play around with it
    parameter int ACTIVATION_LATENCY = 8,
    parameter int PRECHARGE_LATENCY = 5, 
    parameter int BANKS = BANK_GROUPS * BANKS_PER_GROUP
) (
    input logic clk_in,
    input logic rst_in,
    input logic [$clog2(BANK_GROUPS)-1:0] bank_group_in,
    input logic [$clog2(BANKS_PER_GROUP)-1:0] bank_in,
    input logic [ROW_BITS-1:0] row_in,
    input logic [COL_BITS-1:0] col_in,
    input logic valid_in, // if not valid ignore
    input logic write_in, // if val is ok to write (basically write request)
    input logic [63:0] val_in, // val to write if write
    input logic precharged, // is row already precharged?
    input logic cmd_ready, // is controller ready to receive command

    output logic [$clog2(BANK_GROUPS)-1:0] bank_group_out,
    output logic [$clog2(BANKS_PER_GROUP)-1:0] bank_out,
    output logic [ROW_BITS-1:0] row_out,
    output logic [COL_BITS-1:0] col_out,
    output logic [63:0] val_out,
    output logic [2:0] cmd_out, // 0 is read, 1 is write, 2 is activate, 3 is precharge; if valid_out is 0 then block
    output logic valid_out
);
    typedef struct packed {
        logic [$clog2(BANK_GROUPS)-1:0] bank_group;
        logic [$clog2(BANKS_PER_GROUP)-1:0] bank;
        logic [ROW_BITS-1:0] row;
        logic [COL_BITS-1:0] col;
        logic [63:0] val_in;
        logic [2:0] state; // 000 nothing (needs everything), 001 precharge pending, 010 activate ready, 011 activate pending, 100 r/w ready, 101 r/w pending, 110 r/w done
        logic [31:0] cycle_count; // cycle counter of when the last state was set
        logic write;
        logic valid; // do we need this?
    } mem_request_t;

    typedef struct packed {
        logic enqueue_in;
        logic dequeue_in;
        logic transfer_ready; // command is available 
        mem_request_t req_in;
        mem_request_t ready_top_out;
        mem_request_t pending_top_out;
        logic ready_empty_out; // if empty then top doesnt matter
        logic pending_empty_out;
        logic promote;
        logic incoming; // if theres an incoming request into the scheduler and it needs to be placed in the queue, it takes priority over a promotion
    } mem_queue_params;

    typedef struct packed {
        logic [ROW_BITS-1:0] row_out;
    } bank_row_t;

    typedef struct packed {
        logic [BANKS-1:0] bank_enable;  // Enable signal for each bank (1: enabled, 0: disabled)
        logic [BANKS-1:0] precharge;    // Precharge signal for each bank (1: precharge, 0: no precharge)
        logic [BANKS-1:0] activate;     // Activate signal for each bank (1: activate, 0: no activate)
        bank_row_t row_address; // Row address to activate
        logic [$clog2(BANKS)-1:0] request_data;  // Request data signal for each bank
        bank_row_t [BANKS-1:0] active_row_out;  // Active row for a selected bank
        logic [BANKS-1:0] ready_to_access; // Bank ready to access (not in precharge)
        logic [BANKS-1:0] active_bank;
    } bank_state_params_t;

    // Function to set fields of a write request
    function automatic void init_mem_req(
        output mem_request_t req,
        input logic [$clog2(BANK_GROUPS)-1:0] bg,
        input logic [$clog2(BANKS_PER_GROUP)-1:0] b,
        input logic [ROW_BITS-1:0] r,
        input logic [COL_BITS-1:0] c,
        input logic [63:0] data,
        input logic [31:0] cycle_count,
        input logic write,
        input logic [2:0] state
    );
        req.bank_group = bg;
        req.bank = b;
        req.row = r;
        req.col = c;
        req.val_in = data;
        req.state = state; // precharged ? skip to activation stage
        req.cycle_count = cycle_count;
        req.valid = 1'b1;
        req.write = write;
    endfunction

    logic [31:0] cycle_counter;
    logic [$clog2(BANK_GROUPS) + $clog2(BANKS_PER_GROUP) - 1:0] bank_idx;
    bank_state_params_t bank_state_params;
    mem_queue_params [BANKS-1:0] read_params;
    mem_queue_params [BANKS-1:0] write_params;
    mem_queue_params [BANKS-1:0] precharge_params;
    mem_queue_params [BANKS-1:0] activation_params;
    mem_queue_params [BANKS-1:0] params [3:0]; 
    logic [2:0] cmds [4] = {3'b000, 3'b001, 3'b010, 3'b011}; // Read, Write, Activate, Precharge
    logic done;
    mem_request_t incoming_req;
    
    assign bank_idx = bank_group_in * bank_in;

    sdram_bank_state #(
        .ROW_WIDTH(ROW_BITS),
        .NUM_GROUPS(BANK_GROUPS),
        .BANKS_PER_GROUP(BANKS_PER_GROUP),
        .bank_row_t(bank_row_t)
    ) bank_state(
        clk_in, 
        rst_in,
        bank_state_params.bank_enable, 
        bank_state_params.precharge, 
        bank_state_params.activate, 
        bank_state_params.row_address, 
        bank_state_params.request_data, 
        bank_state_params.active_row_out,  
        bank_state_params.ready_to_access, 
        bank_state_params.active_bank 
    );

    // step 3b. enqueues if activation_queue is promoting its top element and not a write request. dequeues when promote is active
    genvar i;
    generate
        for (i = 0; i < BANKS; i = i + 1) begin : bank_queues
            // Read Queue
            mem_cmd_queue #(.QUEUE_SIZE(16), .LATENCY(1), .mem_request_t(mem_request_t)) read_queue (
                .clk_in(clk_in),
                .rst_in(rst_in),
                .enqueue_in(activation_params[i].promote & !activation_params[i].pending_top_out.write),
                .transfer_ready(read_params[i].transfer_ready),
                .req_in(read_params[i].incoming ? read_params[i].req_in : activation_params[i].pending_top_out),
                .cycle_count(cycle_counter),
                .promote_ready(1'b1),
                .ready_top_out(read_params[i].ready_top_out),
                .pending_top_out(read_params[i].pending_top_out),
                .ready_empty_out(read_params[i].ready_empty_out),
                .pending_empty_out(read_params[i].pending_empty_out),
                .promote(read_params[i].promote)
            );

            // Write Queue
            mem_cmd_queue #(.QUEUE_SIZE(16), .LATENCY(1), .mem_request_t(mem_request_t)) write_queue (
                .clk_in(clk_in),
                .rst_in(rst_in),
                .enqueue_in(activation_params[i].promote & activation_params[i].pending_top_out.write),
                .transfer_ready(write_params[i].transfer_ready),
                .req_in(write_params[i].incoming ? write_params[i].req_in : activation_params[i].pending_top_out),
                .cycle_count(cycle_counter),
                .promote_ready(1'b1),
                .ready_top_out(write_params[i].ready_top_out),
                .pending_top_out(write_params[i].pending_top_out),
                .ready_empty_out(write_params[i].ready_empty_out),
                .pending_empty_out(write_params[i].pending_empty_out),
                .promote(write_params[i].promote)
            );

            // Precharge Queue
            mem_cmd_queue #(.QUEUE_SIZE(16), .LATENCY(PRECHARGE_LATENCY), .mem_request_t(mem_request_t)) precharge_queue (
                .clk_in(clk_in),
                .rst_in(rst_in),
                .enqueue_in(precharge_params[i].enqueue_in),
                .transfer_ready(precharge_params[i].transfer_ready),
                .req_in(precharge_params[i].req_in),
                .cycle_count(cycle_counter),
                .promote_ready(!activation_params[i].incoming),
                .ready_top_out(precharge_params[i].ready_top_out),
                .pending_top_out(precharge_params[i].pending_top_out),
                .ready_empty_out(precharge_params[i].ready_empty_out),
                .pending_empty_out(precharge_params[i].pending_empty_out),
                .promote(precharge_params[i].promote)
            );

            // Activation Queue
            mem_cmd_queue #(.QUEUE_SIZE(16), .LATENCY(ACTIVATION_LATENCY), .mem_request_t(mem_request_t)) activation_queue (
                .clk_in(clk_in),
                .rst_in(rst_in),
                .enqueue_in(precharge_params[i].promote),
                .transfer_ready(activation_params[i].transfer_ready),
                .req_in(activation_params[i].incoming ? activation_params[i].req_in : precharge_params[i].pending_top_out),
                .cycle_count(cycle_counter),
                .promote_ready(activation_params[i].pending_top_out.write ? !write_params[i].incoming : !read_params[i].incoming),
                .ready_top_out(activation_params[i].ready_top_out),
                .pending_top_out(activation_params[i].pending_top_out),
                .ready_empty_out(activation_params[i].ready_empty_out),
                .pending_empty_out(activation_params[i].pending_empty_out),
                .promote(activation_params[i].promote)
            );
        end
    endgenerate

    always_ff @(posedge clk_in or posedge rst_in) begin
        if (rst_in) begin
            cycle_counter <= 0;
        end else begin
            cycle_counter <= cycle_counter + 1;
        end
    end

    always_ff @(posedge clk_in or posedge rst_in) begin
        if (rst_in) begin
            cycle_counter <= 0;
            // Reset other variables to prevent inferred latches
            done <= 1'b0;
            valid_out <= 1'b0;
            cmd_out <= '0;
            row_out <= '0;
            col_out <= '0;
            val_out <= '0;
            bank_out <= '0;
            bank_group_out <= '0;
        end else if (valid_in) begin
            // Access enter queue algorithm
            init_mem_req(
                incoming_req,
                bank_group_in,
                bank_in,
                row_in,
                col_in,
                val_in,
                cycle_counter,
                write_in,
                3'b000
            );
            
            // Reset variables at the start of processing
            done <= 1'b0;
            valid_out <= 1'b0;
            
            // bank_state_params.request_data = bank_idx;
            
            // Queue selection logic
            if (bank_state_params.ready_to_access[bank_idx]) begin
                // Precharged but not activated
                activation_params[bank_idx].enqueue_in = 1'b1;
                activation_params[bank_idx].incoming = 1'b1;
                activation_params[bank_idx].req_in = incoming_req;
            end else if (bank_state_params.active_bank[bank_idx] && 
                        bank_state_params.active_row_out[bank_idx] == row_in) begin
                // Active bank, put in respective queue
                if (write_in) begin
                    write_params[bank_idx].enqueue_in = 1'b1;
                    write_params[bank_idx].incoming = 1'b1;
                    write_params[bank_idx].req_in = incoming_req;
                end else begin
                    read_params[bank_idx].enqueue_in = 1'b1;
                    read_params[bank_idx].incoming = 1'b1;
                    read_params[bank_idx].req_in = incoming_req;
                end
            end else begin
                precharge_params[bank_idx].enqueue_in = 1'b1;
                precharge_params[bank_idx].req_in = incoming_req;
            end
            
            // Update params array
            params[0] = read_params;
            params[1] = write_params;
            params[2] = activation_params;
            params[3] = precharge_params;
            
            // Command selection logic
            for (int p = 0; p < 4 && !done; p++) begin
                for (int i = 0; i < BANKS; i++) begin
                    // bank_state_params.request_data = i[$clog2(BANKS)-1:0];
                    
                    if (!params[p][i].pending_empty_out && 
                        params[p][i].ready_top_out.row == bank_state_params.active_row_out[i[$clog2(BANKS)-1:0]]) begin
                        mem_request_t top = params[p][i].ready_top_out;
                        
                        done <= 1'b1;
                        valid_out <= 1'b1;
                        cmd_out <= cmds[p];
                        row_out <= top.row;
                        col_out <= top.col;
                        
                        if (p == 1) begin
                            val_out <= top.val_in;
                        end
                        
                        bank_out <= top.bank;
                        bank_group_out <= top.bank_group;
                        
                        params[p][i].transfer_ready = 1'b1;
                        break;
                    end
                end
            end
            
            // Final fallback if no command selected
            if (!done) begin
                valid_out <= 1'b0;
            end
        end
    end

endmodule: request_scheduler

module address_parser #(
    parameter int A = 8,
    parameter int B = 64,
    parameter int C = 16384,
    parameter int BUS_WIDTH = 16,  // bus width per chip
    parameter int BANK_GROUPS = 8,
    parameter int BANKS_PER_GROUP = 8,       // banks per group
    parameter int ROW_BITS = 8,    // bits to address rows
    parameter int COL_BITS = 4     // bits to address columns
) (
    input logic [63:0]                          l1d_addr_in,
    output logic [$clog2(BANK_GROUPS)]          bank_group_out,
    output logic [$clog2(BANKS_PER_GROUP)-1:0]  bank_out,
    output logic [ROW_BITS-1:0]                 row_out,
    output logic [COL_BITS-1:0]                 col_out
);

    // Associativity: 8, block size = 16, capacity = 16384
    localparam int num_sets = C / (A * B);
    // Block offset =  bits
    localparam int block_offset_bits = $clog2(B);
    localparam int set_index_bits = $clog2(num_sets);
    localparam int tag_bits = 64 - block_offset_bits - set_index_bits;

    localparam int BANK_BITS = $clog2(BANKS);

    // Need to reevaluate after the design review. Current assumptions:
    // The bank, row, and column address are stored at the lower bits of the address in, leaving the remaining more significant bits for other info

    // Proposed mapping for now: 
    /*
    Cache:  [    52-bit Tag    ][6-bit Set Index][  6-bit Block Offset  ]
    DDR4:   [Unused][Row][BankGroup][  Bank  ][    Column    ]
                        [  44  ][ 8 ][    3    ][   6   ][      4       ]

    */

    assign bank_out = address_in[BANK_BITS + ROW_BITS + COL_BITS - 1: ROW_BITS + COL_BITS];
    assign row_out = address_in[ROW_POS + COL_BITS: COL_BITS];
    assign column_out = address_in[COL_POS: 0];


endmodule