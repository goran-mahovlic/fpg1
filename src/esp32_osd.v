// =============================================================================
// ESP32 OSD Top Module - Complete MiSTer-Compatible OSD System
// =============================================================================
// Author: Kosjenka Vukovic, FPGA Architect
// Task:   TASK-204
// Spec:   Top-level integration of ESP32 OSD system
//         - SPI slave for ESP32 communication
//         - MiSTer-compatible command decoder (0x20-0x55)
//         - Dual-port OSD buffer (4KB)
//         - Character renderer with overlay
//         - File transfer (ioctl) interface
//         - Status/Joystick registers
//
// MiSTer Command Codes:
//   0x40: OSD Disable
//   0x41: OSD Enable
//   0x20-0x2F: Write OSD buffer line 0-15
//   0x02: Joystick 0 data (2 bytes)
//   0x03: Joystick 1 data (2 bytes)
//   0x1E: Status bits (4 bytes)
//   0x53: File TX enable
//   0x54: File TX data
//   0x55: File index
// =============================================================================

module esp32_osd #(
    parameter [2:0]  OSD_COLOR     = 3'd4,     // Default: cyan
    parameter [11:0] OSD_X_OFFSET  = 12'd192,  // Center 640-256/2
    parameter [11:0] OSD_Y_OFFSET  = 12'd176   // Center 480-128/2
) (
    // System clocks
    input         clk_sys,            // 50 MHz system clock
    input         clk_video,          // 25 MHz pixel clock
    input         rst_n,

    // SPI Interface (ESP32)
    input         spi_clk,
    input         spi_mosi,
    output        spi_miso,
    input         spi_cs_n,

    // Handshake signals
    output        osd_irq,            // Interrupt to ESP32
    input         esp_ready,          // ESP32 ready signal

    // Video Input (from core)
    input  [23:0] video_in,
    input         video_de,
    input         video_hs,
    input         video_vs,

    // Video Output (with OSD overlay)
    output [23:0] video_out,
    output        video_de_out,
    output        video_hs_out,
    output        video_vs_out,

    // Control outputs
    output [31:0] status,
    output [15:0] joystick_0,
    output [15:0] joystick_1,

    // File I/O (ioctl) interface
    output        ioctl_download,
    output  [7:0] ioctl_index,
    output        ioctl_wr,
    output [24:0] ioctl_addr,
    output  [7:0] ioctl_dout,
    input         ioctl_wait
);

    // =========================================================================
    // MiSTer Command Codes
    // =========================================================================
    localparam CMD_OSD_DISABLE    = 8'h40;
    localparam CMD_OSD_ENABLE     = 8'h41;
    localparam CMD_OSD_WRITE_BASE = 8'h20;  // 0x20-0x2F
    localparam CMD_OSD_WRITE_END  = 8'h2F;
    localparam CMD_JOYSTICK_0     = 8'h02;
    localparam CMD_JOYSTICK_1     = 8'h03;
    localparam CMD_STATUS         = 8'h1E;
    localparam CMD_FILE_TX_EN     = 8'h53;
    localparam CMD_FILE_TX_DATA   = 8'h54;
    localparam CMD_FILE_INDEX     = 8'h55;

    // =========================================================================
    // Command Decoder States
    // =========================================================================
    localparam ST_IDLE       = 4'd0;
    localparam ST_OSD_DATA   = 4'd1;
    localparam ST_JOY0_LO    = 4'd2;
    localparam ST_JOY0_HI    = 4'd3;
    localparam ST_JOY1_LO    = 4'd4;
    localparam ST_JOY1_HI    = 4'd5;
    localparam ST_STATUS_0   = 4'd6;
    localparam ST_STATUS_1   = 4'd7;
    localparam ST_STATUS_2   = 4'd8;
    localparam ST_STATUS_3   = 4'd9;
    localparam ST_FILE_EN    = 4'd10;
    localparam ST_FILE_DATA  = 4'd11;
    localparam ST_FILE_INDEX = 4'd12;

    // =========================================================================
    // Internal Signals
    // =========================================================================

    // SPI Slave interface
    wire [7:0] spi_rx_data;
    wire       spi_rx_valid;
    reg  [7:0] spi_tx_data;
    reg        spi_tx_load;
    wire       spi_busy;

    // OSD buffer interface
    reg  [11:0] osd_wr_addr;
    reg   [7:0] osd_wr_data;
    reg         osd_wr_en;
    wire [11:0] osd_rd_addr;
    wire  [7:0] osd_rd_data;

    // OSD renderer interface
    reg         osd_enable;
    wire        osd_pixel;
    wire        osd_visible;

    // Command decoder state
    reg  [3:0]  cmd_state;
    reg  [7:0]  current_cmd;
    reg  [3:0]  osd_line_num;      // Line 0-15
    reg  [4:0]  osd_char_cnt;      // Char 0-31

    // Control registers
    reg  [31:0] status_reg;
    reg  [15:0] joystick_0_reg;
    reg  [15:0] joystick_1_reg;

    // File transfer registers
    reg         file_download;
    reg   [7:0] file_index;
    reg         file_wr;
    reg  [24:0] file_addr;
    reg   [7:0] file_data;

    // IRQ generation
    reg         irq_pending;

    // Pixel counters
    reg  [11:0] pixel_x;
    reg  [11:0] pixel_y;

    // =========================================================================
    // SPI Slave Instance
    // =========================================================================
    esp32_spi_slave u_spi_slave (
        .clk_sys   (clk_sys),
        .rst_n     (rst_n),
        .spi_clk   (spi_clk),
        .spi_mosi  (spi_mosi),
        .spi_miso  (spi_miso),
        .spi_cs_n  (spi_cs_n),
        .rx_data   (spi_rx_data),
        .rx_valid  (spi_rx_valid),
        .tx_data   (spi_tx_data),
        .tx_load   (spi_tx_load),
        .busy      (spi_busy)
    );

    // =========================================================================
    // OSD Buffer Instance (Dual-Port RAM)
    // =========================================================================
    esp32_osd_buffer u_osd_buffer (
        .clk_sys   (clk_sys),
        .wr_addr   (osd_wr_addr),
        .wr_data   (osd_wr_data),
        .wr_en     (osd_wr_en),
        .clk_video (clk_video),
        .rd_addr   (osd_rd_addr),
        .rd_data   (osd_rd_data)
    );

    // =========================================================================
    // OSD Renderer Instance
    // =========================================================================
    esp32_osd_renderer u_osd_renderer (
        .clk_video    (clk_video),
        .rst_n        (rst_n),
        .pixel_x      (pixel_x),
        .pixel_y      (pixel_y),
        .osd_enable   (osd_enable_sync),
        .osd_x_offset (OSD_X_OFFSET),
        .osd_y_offset (OSD_Y_OFFSET),
        .buf_addr     (osd_rd_addr),
        .buf_data     (osd_rd_data),
        .osd_pixel    (osd_pixel),
        .osd_visible  (osd_visible)
    );

    // =========================================================================
    // Clock Domain Crossing: osd_enable (clk_sys -> clk_video)
    // =========================================================================
    reg [2:0] osd_enable_sync_reg;
    wire      osd_enable_sync = osd_enable_sync_reg[2];

    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n)
            osd_enable_sync_reg <= 3'b000;
        else
            osd_enable_sync_reg <= {osd_enable_sync_reg[1:0], osd_enable};
    end

    // =========================================================================
    // Command Decoder FSM
    // =========================================================================
    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            cmd_state      <= ST_IDLE;
            current_cmd    <= 8'h00;
            osd_line_num   <= 4'd0;
            osd_char_cnt   <= 5'd0;
            osd_enable     <= 1'b0;
            osd_wr_addr    <= 12'd0;
            osd_wr_data    <= 8'd0;
            osd_wr_en      <= 1'b0;
            status_reg     <= 32'd0;
            joystick_0_reg <= 16'd0;
            joystick_1_reg <= 16'd0;
            file_download  <= 1'b0;
            file_index     <= 8'd0;
            file_wr        <= 1'b0;
            file_addr      <= 25'd0;
            file_data      <= 8'd0;
            spi_tx_data    <= 8'h00;
            spi_tx_load    <= 1'b0;
            irq_pending    <= 1'b0;
        end else begin
            // Default: clear single-cycle signals
            osd_wr_en   <= 1'b0;
            file_wr     <= 1'b0;
            spi_tx_load <= 1'b0;

            if (spi_rx_valid) begin
                case (cmd_state)
                    ST_IDLE: begin
                        current_cmd <= spi_rx_data;

                        // Decode command
                        case (spi_rx_data)
                            CMD_OSD_DISABLE: begin
                                osd_enable <= 1'b0;
                                cmd_state  <= ST_IDLE;
                            end

                            CMD_OSD_ENABLE: begin
                                osd_enable <= 1'b1;
                                cmd_state  <= ST_IDLE;
                            end

                            CMD_JOYSTICK_0: begin
                                cmd_state <= ST_JOY0_LO;
                            end

                            CMD_JOYSTICK_1: begin
                                cmd_state <= ST_JOY1_LO;
                            end

                            CMD_STATUS: begin
                                cmd_state <= ST_STATUS_0;
                            end

                            CMD_FILE_TX_EN: begin
                                cmd_state <= ST_FILE_EN;
                            end

                            CMD_FILE_TX_DATA: begin
                                cmd_state <= ST_FILE_DATA;
                            end

                            CMD_FILE_INDEX: begin
                                cmd_state <= ST_FILE_INDEX;
                            end

                            default: begin
                                // Check for OSD line write (0x20-0x2F)
                                if (spi_rx_data >= CMD_OSD_WRITE_BASE &&
                                    spi_rx_data <= CMD_OSD_WRITE_END) begin
                                    osd_line_num <= spi_rx_data[3:0];
                                    osd_char_cnt <= 5'd0;
                                    cmd_state    <= ST_OSD_DATA;
                                end else begin
                                    cmd_state <= ST_IDLE;
                                end
                            end
                        endcase
                    end

                    ST_OSD_DATA: begin
                        // Write character to OSD buffer
                        // Address = line_num * 32 + char_cnt (9-bit address, pad to 12)
                        osd_wr_addr <= {3'b000, osd_line_num, osd_char_cnt[4:0]};
                        osd_wr_data <= spi_rx_data;
                        osd_wr_en   <= 1'b1;

                        if (osd_char_cnt == 5'd31) begin
                            osd_char_cnt <= 5'd0;
                            cmd_state    <= ST_IDLE;
                        end else begin
                            osd_char_cnt <= osd_char_cnt + 5'd1;
                        end
                    end

                    ST_JOY0_LO: begin
                        joystick_0_reg[7:0] <= spi_rx_data;
                        cmd_state <= ST_JOY0_HI;
                    end

                    ST_JOY0_HI: begin
                        joystick_0_reg[15:8] <= spi_rx_data;
                        cmd_state <= ST_IDLE;
                    end

                    ST_JOY1_LO: begin
                        joystick_1_reg[7:0] <= spi_rx_data;
                        cmd_state <= ST_JOY1_HI;
                    end

                    ST_JOY1_HI: begin
                        joystick_1_reg[15:8] <= spi_rx_data;
                        cmd_state <= ST_IDLE;
                    end

                    ST_STATUS_0: begin
                        status_reg[7:0] <= spi_rx_data;
                        cmd_state <= ST_STATUS_1;
                    end

                    ST_STATUS_1: begin
                        status_reg[15:8] <= spi_rx_data;
                        cmd_state <= ST_STATUS_2;
                    end

                    ST_STATUS_2: begin
                        status_reg[23:16] <= spi_rx_data;
                        cmd_state <= ST_STATUS_3;
                    end

                    ST_STATUS_3: begin
                        status_reg[31:24] <= spi_rx_data;
                        cmd_state <= ST_IDLE;
                    end

                    ST_FILE_EN: begin
                        file_download <= spi_rx_data[0];
                        if (spi_rx_data[0] && !file_download) begin
                            // Starting new transfer
                            file_addr <= 25'd0;
                        end
                        cmd_state <= ST_IDLE;
                    end

                    ST_FILE_DATA: begin
                        if (!ioctl_wait) begin
                            file_data <= spi_rx_data;
                            file_wr   <= 1'b1;
                            file_addr <= file_addr + 25'd1;
                        end
                        // Stay in FILE_DATA for continuous transfer
                    end

                    ST_FILE_INDEX: begin
                        file_index <= spi_rx_data;
                        cmd_state  <= ST_IDLE;
                    end

                    default: begin
                        cmd_state <= ST_IDLE;
                    end
                endcase
            end

            // Reset to IDLE on CS deassertion
            if (spi_cs_n) begin
                cmd_state <= ST_IDLE;
            end
        end
    end

    // =========================================================================
    // Pixel Counter (Video Domain)
    // =========================================================================
    reg        video_hs_d1;
    reg        video_vs_d1;

    wire hs_falling = video_hs_d1 & ~video_hs;
    wire vs_falling = video_vs_d1 & ~video_vs;

    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x     <= 12'd0;
            pixel_y     <= 12'd0;
            video_hs_d1 <= 1'b1;
            video_vs_d1 <= 1'b1;
        end else begin
            video_hs_d1 <= video_hs;
            video_vs_d1 <= video_vs;

            // Horizontal counter
            if (hs_falling) begin
                pixel_x <= 12'd0;
                pixel_y <= pixel_y + 12'd1;
            end else if (video_de) begin
                pixel_x <= pixel_x + 12'd1;
            end

            // Vertical reset
            if (vs_falling) begin
                pixel_y <= 12'd0;
            end
        end
    end

    // =========================================================================
    // Video Pipeline (match renderer 2-cycle latency)
    // =========================================================================
    reg [23:0] video_d1, video_d2;
    reg        de_d1, de_d2;
    reg        hs_d1, hs_d2;
    reg        vs_d1, vs_d2;

    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            video_d1 <= 24'd0;
            video_d2 <= 24'd0;
            de_d1    <= 1'b0;
            de_d2    <= 1'b0;
            hs_d1    <= 1'b1;
            hs_d2    <= 1'b1;
            vs_d1    <= 1'b1;
            vs_d2    <= 1'b1;
        end else begin
            video_d1 <= video_in;
            video_d2 <= video_d1;
            de_d1    <= video_de;
            de_d2    <= de_d1;
            hs_d1    <= video_hs;
            hs_d2    <= hs_d1;
            vs_d1    <= video_vs;
            vs_d2    <= vs_d1;
        end
    end

    // =========================================================================
    // Video Mixer (OSD Overlay)
    // =========================================================================
    // OSD foreground color (expand 3-bit to 24-bit)
    wire [7:0] osd_r = OSD_COLOR[2] ? 8'hFF : 8'h00;
    wire [7:0] osd_g = OSD_COLOR[1] ? 8'hFF : 8'h00;
    wire [7:0] osd_b = OSD_COLOR[0] ? 8'hFF : 8'h00;
    wire [23:0] osd_fg_color = {osd_r, osd_g, osd_b};

    // OSD background (darken video by 50%)
    wire [23:0] osd_bg_blend = {1'b0, video_d2[23:17], 1'b0, video_d2[15:9], 1'b0, video_d2[7:1]};

    // Mix video with OSD
    reg [23:0] video_mixed;

    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            video_mixed <= 24'd0;
        end else begin
            if (osd_visible) begin
                if (osd_pixel) begin
                    video_mixed <= osd_fg_color;
                end else begin
                    video_mixed <= osd_bg_blend;
                end
            end else begin
                video_mixed <= video_d2;
            end
        end
    end

    // =========================================================================
    // Output Assignments
    // =========================================================================

    // Video outputs (extra pipeline for mixer)
    reg de_d3, hs_d3, vs_d3;
    always @(posedge clk_video or negedge rst_n) begin
        if (!rst_n) begin
            de_d3 <= 1'b0;
            hs_d3 <= 1'b1;
            vs_d3 <= 1'b1;
        end else begin
            de_d3 <= de_d2;
            hs_d3 <= hs_d2;
            vs_d3 <= vs_d2;
        end
    end

    assign video_out    = video_mixed;
    assign video_de_out = de_d3;
    assign video_hs_out = hs_d3;
    assign video_vs_out = vs_d3;

    // Control outputs
    assign status     = status_reg;
    assign joystick_0 = joystick_0_reg;
    assign joystick_1 = joystick_1_reg;

    // File I/O outputs
    assign ioctl_download = file_download;
    assign ioctl_index    = file_index;
    assign ioctl_wr       = file_wr;
    assign ioctl_addr     = file_addr;
    assign ioctl_dout     = file_data;

    // IRQ output
    assign osd_irq = irq_pending;

endmodule
