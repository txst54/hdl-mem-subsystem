module request_scheduler #(
    parameter int BUS_WIDTH = 16,  // bus width per chip
    parameter int BANK_GROUPS = 2,
    parameter int BANKS_PER_GROUP = 4,       // banks per group
    parameter int ROW_BITS = 8,    // bits to address rows
    parameter int COL_BITS = 4,     // bits to address columns
    parameter int PADDR_BITS = 19,
    parameter int QUEUE_SIZE = 16, // set this, play around with it
    parameter int ACTIVATION_LATENCY = 8,
    parameter int PRECHARGE_LATENCY = 5, 
    parameter int BANKS = BANK_GROUPS * BANKS_PER_GROUP
) (
    input logic clk_in,
    input logic rst_in,
    input logic [PADDR_BITS-1:0] mem_bus_addr_in,
    input logic valid_in, // if not valid ignore
    input logic write_in, // if val is ok to write (basically write request)
    input logic [511:0] val_in, // val to write if write
    input logic cmd_ready, // is controller ready to receive command
    input logic bursting,
    output logic [PADDR_BITS-1:0] addr_out,
    output logic [$clog2(BANK_GROUPS)-1:0] bank_group_out,
    output logic [$clog2(BANKS_PER_GROUP)-1:0] bank_out,
    output logic [ROW_BITS-1:0] row_out,
    output logic [COL_BITS-1:0] col_out,
    output logic [511:0] val_out,
    output logic [2:0] cmd_out, // 0 is read, 1 is write, 2 is activate, 3 is precharge; if valid_out is 0 then block
    output logic valid_out
);

        localparam LOWER_ADDR_BITS_C = COL_BITS+$clog2(BANK_GROUPS)+$clog2(BANKS_PER_GROUP);
        localparam LOWER_ADDR_BITS_R = ROW_BITS+$clog2(BANK_GROUPS)+$clog2(BANKS_PER_GROUP);
    localparam CYCLE_START_BIT = $clog2(BANK_GROUPS) + $clog2(BANKS_PER_GROUP) + ROW_BITS + COL_BITS + 512;
    localparam CYCLE_END_BIT = CYCLE_START_BIT + 32;
    localparam REQ_SIZE = CYCLE_END_BIT + 1;
  
    typedef struct packed {
        logic [$clog2(BANK_GROUPS)-1:0] bank_group;
        logic [$clog2(BANKS_PER_GROUP)-1:0] bank;
        logic [ROW_BITS-1:0] row;
        logic [COL_BITS-1:0] col;
        logic [511:0] val_in;
        logic [31:0] cycle_count; // cycle counter of when the last state was set
        logic write;
    } mem_request_t;

    typedef struct packed {
        logic enqueue_in;
        logic dequeue_in;
        logic transfer_ready; // command is available 
        mem_request_t req_in;
        logic incoming; // if theres an incoming request into the scheduler and it needs to be placed in the queue, it takes priority over a promotion
    } mem_queue_params_in_t;

    typedef struct packed {
        mem_request_t ready_top_out;
        mem_request_t pending_top_out;
        logic ready_empty_out; // if empty then top doesnt matter
        logic pending_empty_out;
        logic promote;
    } mem_queue_params_out_t;

    typedef struct packed {
        logic [ROW_BITS-1:0] row_out;
    } bank_row_t;

    typedef struct packed {
        logic [BANKS-1:0] precharge;    // Precharge signal for each bank (1: precharge, 0: no precharge)
        logic [BANKS-1:0] activate;     // Activate signal for each bank (1: activate, 0: no activate)
        logic [BANKS-1:0][ROW_BITS-1:0] row_address; // Row address to activate
    } bank_state_params_in_t;

    typedef struct packed {
        bank_row_t [BANKS-1:0] active_row_out;  // Active row for a selected bank
        logic [BANKS-1:0] ready_to_access; // Bank ready to access (not in precharge)
        logic [BANKS-1:0] active_bank;
        logic [BANKS-1:0] blocked;
    } bank_state_params_out_t;

    // Function to set fields of a write request
    function automatic void init_mem_req(
        output mem_request_t req,
        input logic [PADDR_BITS-1:0] addr,
        input logic [$clog2(BANK_GROUPS)-1:0] bg,
        input logic [$clog2(BANKS_PER_GROUP)-1:0] b,
        input logic [ROW_BITS-1:0] r,
        input logic [COL_BITS-1:0] c,
        input logic [511:0] data,
        input logic [31:0] cycle_count,
        input logic write,
        input logic [2:0] state
    );
        req.bank_group = bg;
        req.bank = b;
        req.row = r;
        req.col = c;
        req.val_in = data;
        req.cycle_count = cycle_count;
        req.write = write;
    endfunction

    function automatic void process_bank_commands(
        input int unsigned p,
        ref mem_queue_params_in_t [BANKS-1:0] params_in,
        mem_queue_params_out_t [BANKS-1:0] params_out, // pass by value
        ref bank_state_params_in_t bank_state_params_in,
        ref bank_state_params_out_t bank_state_params_out,
        input logic [2:0] cmds[4],
        output logic done,
        output logic valid_out_t,
        output logic [2:0] cmd_out_t,
        output logic [ROW_BITS-1:0] row_out_t,
        output logic [COL_BITS-1:0] col_out_t,
        output logic [511:0] val_out_t,
        output logic [$clog2(BANKS_PER_GROUP)-1:0] bank_out_t,
        output logic [$clog2(BANK_GROUPS)-1:0] bank_group_out_t, 
        output logic [PADDR_BITS-1:0] addr_out_t
    );
        valid_out_t = 1'b0;
        done = 1'b0;
        for (int i = 0; i < BANKS; i++) begin
            if (!params_out[i].ready_empty_out && 
                !bank_state_params_out.blocked[i[$clog2(BANKS)-1:0]] && 
                (p == 2 || p == 3 || 
                params_out[i].ready_top_out.row == bank_state_params_out.active_row_out[i[$clog2(BANKS)-1:0]].row_out)) begin
                
                mem_request_t top = params_out[i].ready_top_out;
                // $display("considering cmd %d for p %d, bank idx %d and row %b", cmds[p], p, i, top.row);
                
                done = 1'b1;
                valid_out_t = 1'b1;
                cmd_out_t = cmds[p];
                row_out_t = top.row;
                col_out_t = top.col;
                bank_out_t = top.bank;
                bank_group_out_t = top.bank_group;
                // Which command are we considering sending out to DRAM bank?
                if (p == 1) begin // write command
                    val_out_t = top.val_in;
                    addr_out_t = {1'b0, 1'b1, 1'b1, 1'b0, 1'b0, bank_group_out_t, bank_out_t, {(14-LOWER_ADDR_BITS_C){1'b0}}, col_out_t};
                end else if (p == 2) begin // activate command
                    $display("activating bank %x", i);
                    addr_out_t = {1'b0, 1'b0, 3'b0, bank_group_out_t, bank_out_t, {(14-LOWER_ADDR_BITS_R){1'b0}}, row_out_t};
                    bank_state_params_in.activate = '0;
                    bank_state_params_in.activate[i] = 1'b1;
                    bank_state_params_in.row_address = top.row;
                    val_out_t = 'b0;
                end else if (p == 3) begin
                    addr_out_t = {1'b0, 1'b1, 1'b0, 1'b1, 1'b0, bank_group_out_t, bank_out_t, {(14-LOWER_ADDR_BITS_C){1'b0}}, col_out_t};
                    bank_state_params_in.precharge = '0;
                    bank_state_params_in.precharge[i] = 1'b1;
                    val_out_t = 'b0;
                end else begin // read command
                    $display("bank scheduled %x", {bank_group_out_t, bank_out_t});
                    addr_out_t = {1'b0, 1'b1, 1'b1, 1'b0, 1'b1, bank_group_out_t, bank_out_t, {(14-LOWER_ADDR_BITS_C){1'b0}}, col_out_t};
                    val_out_t = 'b0;
                end
                params_in[i].transfer_ready = 1'b1;
                break;
            end
        end
        if (!valid_out_t) begin
            addr_out_t = {PADDR_BITS{1'b1}};
        end
    endfunction

    function automatic void reset_mem_queue_params (
        output mem_queue_params_in_t [BANKS-1:0] params
    );
        for (int i = 0; i < BANKS; i++) begin
            params[i].enqueue_in = 'b0;
            params[i].dequeue_in = 'b0;
            params[i].transfer_ready = 'b0;
            params[i].req_in = incoming_req;
            params[i].incoming = 'b0;
        end
    endfunction

    logic [31:0] cycle_counter;
    logic [31:0] next_cycle_counter;
    logic [31:0] cycle_counter_t;
    logic[31:0] last_read;
    logic[31:0] last_read_t;
    logic[31:0] last_write;
    logic[31:0] last_write_t;
    logic [$clog2(BANK_GROUPS) + $clog2(BANKS_PER_GROUP) - 1:0] bank_idx;
    logic [$clog2(BANK_GROUPS) + $clog2(BANKS_PER_GROUP) - 1:0] refr_bank_idx;
    logic [$clog2(BANK_GROUPS)-1:0] bank_group_in;
    logic [$clog2(BANKS_PER_GROUP)-1:0] bank_in;
    logic [ROW_BITS-1:0] row_in;
    logic [COL_BITS-1:0] col_in;
    bank_state_params_in_t bank_state_params_in;
    bank_state_params_out_t bank_state_params_out;
    bank_state_params_out_t bank_state;

    mem_queue_params_in_t [BANKS-1:0] read_params_in;
    mem_queue_params_in_t [BANKS-1:0] write_params_in;
    mem_queue_params_in_t [BANKS-1:0] precharge_params_in;
    mem_queue_params_in_t [BANKS-1:0] activation_params_in;

    mem_queue_params_out_t [BANKS-1:0] read_params_out;
    mem_queue_params_out_t [BANKS-1:0] write_params_out;
    mem_queue_params_out_t [BANKS-1:0] precharge_params_out;
    mem_queue_params_out_t [BANKS-1:0] activation_params_out;

    logic [2:0] cmds [4];
    assign cmds = '{3'b000, 3'b001, 3'b010, 3'b011}; // Read, Write, Activate, Precharge
    logic done;
    mem_request_t incoming_req;

    // tmp holding regs
    logic [PADDR_BITS-1:0] addr_out_t;
    logic [$clog2(BANK_GROUPS)-1:0] bank_group_out_t;
    logic [$clog2(BANKS_PER_GROUP)-1:0] bank_out_t;
    logic [ROW_BITS-1:0] row_out_t;
    logic [COL_BITS-1:0] col_out_t;
    logic [511:0] val_out_t;
    logic [2:0] cmd_out_t; // 0 is read, 1 is write, 2 is activate, 3 is precharge; if valid_out is 0 then block
    logic valid_out_t;

    // refresh regs
    logic [$clog2(BANK_GROUPS)-1:0] refr_bank_group_out;
    logic [$clog2(BANKS_PER_GROUP)-1:0] refr_bank_out;
    logic [ROW_BITS-1:0] refr_row_out;
    logic refr_out;
    
    assign bank_idx = ({bank_group_in[0], bank_in});
    assign refr_bank_idx = ({refr_bank_group_out[0], refr_bank_out});
    assign cycle_counter_t = cycle_counter;

    address_parser #(
        .ROW_BITS(ROW_BITS),
        .COL_BITS(COL_BITS),
        .PADDR_BITS(PADDR_BITS),
        .BANK_GROUPS(BANK_GROUPS),
        .BANKS_PER_GROUP(BANKS_PER_GROUP)
    ) _address_parser(
        .mem_bus_addr_in(mem_bus_addr_in),
        .row_out(row_in),
        .col_out(col_in),
        .bg_out(bank_group_in),
        .ba_out(bank_in) 
    );

    sdram_bank_state #(
        .ROW_WIDTH(ROW_BITS),
        .NUM_GROUPS(BANK_GROUPS),
        .BANKS_PER_GROUP(BANKS_PER_GROUP)
    ) bank_state_reg(
        clk_in, 
        rst_in,
        bank_state_params_in.precharge, 
        bank_state_params_in.activate, 
        bank_state_params_in.row_address, 
        bank_state_params_out.active_row_out,  
        bank_state_params_out.ready_to_access, 
        bank_state_params_out.active_bank,
        bank_state_params_out.blocked 
    );

    auto_refresh #(
        .BANK_GROUPS(BANK_GROUPS),
        .BANKS_PER_GROUP(BANKS_PER_GROUP),
        .ROW_BITS(ROW_BITS),
        .ACTIVATION_LATENCY(ACTIVATION_LATENCY),
        .PRECHARGE_LATENCY(PRECHARGE_LATENCY), 
        .REFRESH_LATENCY(ACTIVATION_LATENCY + PRECHARGE_LATENCY),
        .BANKS(BANK_GROUPS * BANKS_PER_GROUP),
        .REFRESH_INTERVAL(64_000_000)
    ) _auto_refresh(
        clk_in,
        rst_in,

        refr_bank_group_out,
        refr_bank_out,
        refr_row_out,
        refr_out
    );

    // step 3b. enqueues if activation_queue is promoting its top element and not a write request. dequeues when promote is active
    genvar i;
    generate
        for (i = 0; i < BANKS; i = i + 1) begin : bank_queues
            // Read Queue
            mem_cmd_queue #(
                .QUEUE_SIZE(16), 
                .LATENCY(1), 
                .REQ_SIZE(REQ_SIZE), 
                .CYCLE_START_BIT(CYCLE_START_BIT), 
                .CYCLE_END_BIT(CYCLE_END_BIT))
            read_queue (
                .clk_in(clk_in),
                .rst_in(rst_in),
                .enqueue_in(read_params_in[i].incoming || (activation_params_out[i].promote & !activation_params_out[i].pending_top_out.write)),
                .transfer_ready(read_params_in[i].transfer_ready),
                .req_in(read_params_in[i].incoming ? read_params_in[i].req_in : activation_params_out[i].pending_top_out),
                .cycle_count(cycle_counter_t),
                .promote_ready(1'b1),
                .ready_top_out(read_params_out[i].ready_top_out),
                .pending_top_out(read_params_out[i].pending_top_out),
                .ready_empty_out(read_params_out[i].ready_empty_out),
                .pending_empty_out(read_params_out[i].pending_empty_out),
                .promote(read_params_out[i].promote)
            );

            // Write Queue
            mem_cmd_queue #(
                .QUEUE_SIZE(16), 
                .LATENCY(1),
                .REQ_SIZE(REQ_SIZE), 
                .CYCLE_START_BIT(CYCLE_START_BIT), 
                .CYCLE_END_BIT(CYCLE_END_BIT)) 
            write_queue (
                .clk_in(clk_in),
                .rst_in(rst_in),
                .enqueue_in(write_params_in[i].incoming || (activation_params_out[i].promote & activation_params_out[i].pending_top_out.write)),
                .transfer_ready(write_params_in[i].transfer_ready),
                .req_in(write_params_in[i].incoming ? write_params_in[i].req_in : activation_params_out[i].pending_top_out),
                .cycle_count(cycle_counter_t),
                .promote_ready(1'b1),
                .ready_top_out(write_params_out[i].ready_top_out),
                .pending_top_out(write_params_out[i].pending_top_out),
                .ready_empty_out(write_params_out[i].ready_empty_out),
                .pending_empty_out(write_params_out[i].pending_empty_out),
                .promote(write_params_out[i].promote)
            );

            // Precharge Queue
            mem_cmd_queue #(
                .QUEUE_SIZE(16), 
                .LATENCY(PRECHARGE_LATENCY),
                .REQ_SIZE(REQ_SIZE), 
                .CYCLE_START_BIT(CYCLE_START_BIT), 
                .CYCLE_END_BIT(CYCLE_END_BIT)) 
            precharge_queue (
                .clk_in(clk_in),
                .rst_in(rst_in),
                .enqueue_in(precharge_params_in[i].enqueue_in),
                .transfer_ready(precharge_params_in[i].transfer_ready),
                .req_in(precharge_params_in[i].req_in),
                .cycle_count(cycle_counter_t),
                .promote_ready(!activation_params_in[i].incoming),
                .ready_top_out(precharge_params_out[i].ready_top_out),
                .pending_top_out(precharge_params_out[i].pending_top_out),
                .ready_empty_out(precharge_params_out[i].ready_empty_out),
                .pending_empty_out(precharge_params_out[i].pending_empty_out),
                .promote(precharge_params_out[i].promote)
            );

            // Activation Queue
            mem_cmd_queue #(
                .QUEUE_SIZE(16), 
                .LATENCY(ACTIVATION_LATENCY),
                .REQ_SIZE(REQ_SIZE), 
                .CYCLE_START_BIT(CYCLE_START_BIT), 
                .CYCLE_END_BIT(CYCLE_END_BIT)) 
            activation_queue (
                .clk_in(clk_in),
                .rst_in(rst_in),
                .enqueue_in(activation_params_in[i].incoming || precharge_params_out[i].promote),
                .transfer_ready(activation_params_in[i].transfer_ready),
                .req_in(activation_params_in[i].incoming ? activation_params_in[i].req_in : precharge_params_out[i].pending_top_out),
                .cycle_count(cycle_counter_t),
                .promote_ready(activation_params_out[i].pending_top_out.write ? !write_params_in[i].incoming : !read_params_in[i].incoming),
                .ready_top_out(activation_params_out[i].ready_top_out),
                .pending_top_out(activation_params_out[i].pending_top_out),
                .ready_empty_out(activation_params_out[i].ready_empty_out),
                .pending_empty_out(activation_params_out[i].pending_empty_out),
                .promote(activation_params_out[i].promote)
            );
        end: bank_queues
    endgenerate

    always_ff @(posedge clk_in or posedge rst_in) begin
        if (rst_in) begin
            cycle_counter <= 0;
            // Reset other variables to prevent inferred latches
            valid_out <= 1'b0;
            cmd_out <= '0;
            row_out <= '0;
            col_out <= '0;
            val_out <= '0;
            bank_out <= '0;
            bank_group_out <= '0;
            addr_out <= {PADDR_BITS{1'b1}};
        end else begin
            cycle_counter <= next_cycle_counter;
            if (!valid_out_t) begin
                addr_out <= {PADDR_BITS{1'b1}};
            end else begin
                addr_out <= addr_out_t;
            end
            bank_group_out <= bank_group_out_t;
            bank_out <= bank_out_t;
            row_out <= row_out_t;
            col_out <= col_out_t;
            val_out <= val_out_t;
            cmd_out <= cmd_out_t;
            valid_out <= valid_out_t;
            last_read <= last_read_t;
            last_write <= last_write_t;
            if (valid_out_t) begin
                $display("[SCHEDULER] Scheduling cmd %b at row %x col %x bank %x", cmd_out_t, row_out_t, col_out_t, {bank_group_out_t, bank_out_t});
            end
        end
    end

    logic read_prio;
    generate
        logic[BANKS-1:0] read_prio_out;
        for (i = 0; i < BANKS; i++) begin: read_prio_for
            assign read_prio_out[i] = !read_params_out[i].ready_empty_out && read_params_out[i].ready_top_out.cycle_count > write_params_out[i].ready_top_out.cycle_count && read_params_out[i].ready_top_out.cycle_count < cycle_counter;
        end: read_prio_for
        assign read_prio = |read_prio_out;
    endgenerate
    always_comb begin
        next_cycle_counter = cycle_counter + 1;
        done = 1'b0;
        valid_out_t = 1'b0;
        cmd_out_t = 'b0;
        row_out_t = 'b0;
        col_out_t = 'b0;
        val_out_t = 'b0;
        bank_out_t = 'b0;
        bank_group_out_t = 'b0;
        last_read_t = last_read;
        last_write_t = last_write;
        bank_state_params_in.activate = '{default:0};
        bank_state_params_in.precharge =  '{default:0};
        bank_state = bank_state_params_out;
        addr_out_t = {PADDR_BITS{1'b1}};
        init_mem_req(
            incoming_req,
            mem_bus_addr_in,
            bank_group_in,
            bank_in,
            row_in,
            col_in,
            val_in,
            cycle_counter_t,
            write_in,
            3'b000
        );
        bank_state_params_in.row_address = 'b0;
        reset_mem_queue_params(read_params_in);
        reset_mem_queue_params(write_params_in);
        reset_mem_queue_params(precharge_params_in);
        reset_mem_queue_params(activation_params_in);
        if (valid_in) begin
            // Access enter queue algorithm
            
            // Queue selection logic
            if (bank_state_params_out.ready_to_access[bank_idx]) begin
                // Precharged but not activated
                $display("[SCHEDULER] adding to activation queue idx %d addr %x\n", bank_idx, mem_bus_addr_in);
                activation_params_in[bank_idx].enqueue_in = 1'b1;
                activation_params_in[bank_idx].incoming = 1'b1;
                activation_params_in[bank_idx].req_in = incoming_req;
            end else if (bank_state_params_out.active_bank[bank_idx] && 
                        bank_state_params_out.active_row_out[bank_idx] == row_in) begin
                // Active bank, put in respective queue
                if (write_in) begin
                    $display("[SCHEDULER] adding to write queue addr %x\n", mem_bus_addr_in);
                    write_params_in[bank_idx].enqueue_in = 1'b1;
                    write_params_in[bank_idx].incoming = 1'b1;
                    write_params_in[bank_idx].req_in = incoming_req;
                end else begin
                    $display("[SCHEDULER] adding to read queue addr %x\n", mem_bus_addr_in);
                    read_params_in[bank_idx].enqueue_in = 1'b1;
                    read_params_in[bank_idx].incoming = 1'b1;
                    read_params_in[bank_idx].req_in = incoming_req;
                end
            end else begin
                $display("[SCHEDULER] adding to precharge queue %d\n", incoming_req.bank_group * incoming_req.bank);
                precharge_params_in[bank_idx].enqueue_in = 1'b1;
                precharge_params_in[bank_idx].req_in = incoming_req;
            end
        end
        if (refr_out) begin
            $display("[SCHEDULER] refreshing bank %x", refr_bank_idx);
            done = 1'b1;
            valid_out_t = 1'b1;
            row_out_t = refr_row_out;
            bank_out_t = refr_bank_out;
            bank_group_out_t = refr_bank_group_out;
            addr_out_t = {1'b0, 1'b1, 2'b0, 1'b1, bank_group_out_t, bank_out_t, {(14-LOWER_ADDR_BITS_R){1'b0}}, row_out_t};
            bank_state_params_in.precharge = '0;
            bank_state_params_in.precharge[refr_bank_idx] = 1'b1;
            bank_state_params_in.row_address = row_out_t;
            val_out_t = 'b0;
        end
        if (cmd_ready & ~refr_out) begin // DRAM has a one cycle slot for the SDRAM controller to send out the command, let's see which bank queue to send command out
            // Update params array
            if (read_prio) begin // are there any pending read requests that are older than write reqeusts?
                if (last_read < cycle_counter_t - 4) begin // ensure that there has been at least 4 cycles since the last read command (bursting)
                    process_bank_commands(
                        0,
                        read_params_in,
                        read_params_out,
                        bank_state_params_in,
                        bank_state,
                        cmds,
                        done,
                        valid_out_t,
                        cmd_out_t,
                        row_out_t,
                        col_out_t,
                        val_out_t,
                        bank_out_t,
                        bank_group_out_t,
                        addr_out_t
                    );
                    last_read_t = cycle_counter_t;
                    // $display("deq read");
                end
            end else if (!bursting && last_write + 4 <= cycle_counter_t) begin
                process_bank_commands(
                    1,
                    write_params_in,
                    write_params_out,
                    bank_state_params_in,
                    bank_state,
                    cmds,
                    done,
                    valid_out_t,
                    cmd_out_t,
                    row_out_t,
                    col_out_t,
                    val_out_t,
                    bank_out_t,
                    bank_group_out_t,
                    addr_out_t
                );
                last_write_t = done ? cycle_counter_t : last_write;
                if (done) begin
                    // $display("deq write");
                end
                if (!done) begin
                    process_bank_commands(
                        2,
                        activation_params_in,
                        activation_params_out,
                        bank_state_params_in,
                        bank_state,
                        cmds,
                        done,
                        valid_out_t,
                        cmd_out_t,
                        row_out_t,
                        col_out_t,
                        val_out_t,
                        bank_out_t,
                        bank_group_out_t,
                        addr_out_t
                    );
                    if (done) begin
                        // $display("deq act");
                    end
                end
                if (!done) begin
                    process_bank_commands(
                        3,
                        precharge_params_in,
                        precharge_params_out,
                        bank_state_params_in,
                        bank_state,
                        cmds,
                        done,
                        valid_out_t,
                        cmd_out_t,
                        row_out_t,
                        col_out_t,
                        val_out_t,
                        bank_out_t,
                        bank_group_out_t,
                        addr_out_t
                    );
                    if (done) begin
                        // $display("deq pre");
                    end
                end
            end
        end
    end
endmodule: request_scheduler