-- -----------------------------------------------------------------------------
-- reconfig_core.vhd
--
-- All user logic of the NexusReconfig reference design, without device
-- primitives, so it can be simulated with a behavioural LMMI target model.
--
-- Behaviour:
--   1. After configuration, a power-on reset counter releases the logic.
--   2. The UART prints "NexusReconfig: FPGA configured", led_o(0) lights for
--      BOOT_LED_MS (a fresh-configuration indicator) and led_o(1) blinks as a
--      heartbeat.
--   3. A reconfiguration request comes from a falling edge on the debounced,
--      active-low button input, or from the auto-refresh timer after
--      AUTO_REFRESH_MS (0 disables the timer).
--   4. The UART prints "NexusReconfig: issuing LSC_REFRESH", then lmmi_refresh
--      writes LSC_REFRESH to CONFIG_LMMI. The device reconfigures from its boot
--      source and the sequence starts again at step 1.
--   5. If the device is still running after the command (refresh not
--      executed), led_o(0) flashes quickly to show the failure.
-- -----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.nexus_reconfig_pkg.all;

entity reconfig_core is
    generic (
        CLK_HZ          : positive := 25_000_000;   -- sys_clk frequency
        BAUD            : positive := 115_200;
        AUTO_REFRESH_MS : natural  := 10_000;       -- 0 = button only
        BOOT_LED_MS     : positive := 2_000;
        DEBOUNCE_MS     : positive := 20;
        POR_CYCLES      : positive := 1_024;
        LED_ACTIVE_LOW  : boolean  := false;
        LMMI_GAP_CYCLES : positive := 16
    );
    port (
        clk_i          : in  std_logic;
        rst_no         : out std_logic;             -- released power-on reset (also drives the LMMI reset)

        btn_ni         : in  std_logic;             -- reconfiguration request, active low, asynchronous
        led_o          : out std_logic_vector(1 downto 0);
        txd_o          : out std_logic;

        -- LMMI host port, connect to CONFIG_LMMI
        lmmi_request_o : out std_logic;
        lmmi_wr_rdn_o  : out std_logic;
        lmmi_offset_o  : out std_logic_vector(7 downto 0);
        lmmi_wdata_o   : out std_logic_vector(7 downto 0);
        lmmi_ready_i   : in  std_logic;

        refresh_done_o : out std_logic              -- LSC_REFRESH fully accepted
    );
end entity reconfig_core;

architecture rtl of reconfig_core is

    -- ------------------------------------------------------------------
    -- Power-on reset. Registers are cleared when configuration completes,
    -- so the counter starts at zero.
    -- ------------------------------------------------------------------
    constant POR_W : natural := clog2(POR_CYCLES + 1);
    signal por_cnt : unsigned(POR_W - 1 downto 0) := (others => '0');
    signal rst_n   : std_logic := '0';

    -- Millisecond tick
    constant MS_DIV : positive := CLK_HZ / 1000;
    constant MS_W   : natural  := clog2(MS_DIV);
    signal ms_cnt   : unsigned(MS_W - 1 downto 0);
    signal ms_tick  : std_logic;

    -- Button
    constant DB_W   : natural := clog2(DEBOUNCE_MS + 1);
    signal btn_sync  : std_logic_vector(1 downto 0);
    signal btn_db    : std_logic;                     -- debounced level, 1 = released
    signal db_cnt    : unsigned(DB_W - 1 downto 0);
    signal btn_armed : std_logic;
    signal btn_event : std_logic;

    -- UART messages
    constant MSG0_LEN : positive := 34;
    constant MSG1_LEN : positive := 36;
    constant MSG0     : string   := CR & LF & "NexusReconfig: FPGA configured" & CR & LF;
    constant MSG1     : string   := "NexusReconfig: issuing LSC_REFRESH" & CR & LF;
    constant MSG0_ROM : byte_array_t(0 to 63) := to_rom(MSG0, 64);
    constant MSG1_ROM : byte_array_t(0 to 63) := to_rom(MSG1, 64);

    signal msg_sel  : std_logic;                      -- 0 = MSG0, 1 = MSG1
    signal char_idx : unsigned(5 downto 0);
    signal tx_data  : std_logic_vector(7 downto 0);
    signal tx_valid : std_logic;
    signal tx_ready : std_logic;
    signal msg_last : std_logic;

    -- Sequencer
    type mstate_t is (M_BANNER, M_RUN, M_MSG, M_DRAIN, M_REFRESH, M_WAIT);
    signal mstate : mstate_t;

    function auto_width return natural is
    begin
        if AUTO_REFRESH_MS > 0 then
            return clog2(AUTO_REFRESH_MS + 1);
        end if;
        return 1;
    end function auto_width;

    constant AUTO_W : natural := auto_width;
    signal auto_cnt      : unsigned(AUTO_W - 1 downto 0);
    signal auto_event    : std_logic;
    signal refresh_start : std_logic;
    signal refresh_done  : std_logic;
    signal drain_cnt     : unsigned(1 downto 0);

    -- LEDs
    constant BL_W : natural := clog2(BOOT_LED_MS + 1);
    signal boot_cnt   : unsigned(BL_W - 1 downto 0);
    signal blink_cnt  : unsigned(7 downto 0);         -- ms counter for the blink patterns
    signal boot_led   : std_logic;
    signal heartbeat  : std_logic;
    signal fail_flash : std_logic;
    signal led        : std_logic_vector(1 downto 0);

begin

    -- ------------------------------------------------------------------
    -- Power-on reset
    -- ------------------------------------------------------------------
    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if por_cnt /= to_unsigned(POR_CYCLES, POR_W) then
                por_cnt <= por_cnt + 1;
            end if;
            rst_n <= '1' when por_cnt = to_unsigned(POR_CYCLES, POR_W) else '0';
        end if;
    end process;
    rst_no <= rst_n;

    -- ------------------------------------------------------------------
    -- Millisecond tick
    -- ------------------------------------------------------------------
    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_n = '0' then
                ms_cnt  <= (others => '0');
                ms_tick <= '0';
            else
                if ms_cnt = to_unsigned(MS_DIV - 1, MS_W) then
                    ms_tick <= '1';
                    ms_cnt  <= (others => '0');
                else
                    ms_tick <= '0';
                    ms_cnt  <= ms_cnt + 1;
                end if;
            end if;
        end if;
    end process;

    -- ------------------------------------------------------------------
    -- Button: synchroniser, debounce, falling-edge event. The event is only
    -- armed after the input has been seen released (high), so a stuck-low
    -- input cannot cause a refresh loop.
    -- ------------------------------------------------------------------
    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_n = '0' then
                btn_sync  <= "00";
                btn_db    <= '0';
                db_cnt    <= (others => '0');
                btn_armed <= '0';
                btn_event <= '0';
            else
                btn_sync  <= btn_sync(0) & btn_ni;
                btn_event <= '0';
                if btn_sync(1) = btn_db then
                    db_cnt <= (others => '0');
                elsif ms_tick = '1' then
                    if db_cnt = to_unsigned(DEBOUNCE_MS, DB_W) then
                        btn_db <= btn_sync(1);
                        db_cnt <= (others => '0');
                        if btn_sync(1) = '1' then
                            btn_armed <= '1';               -- released
                        elsif btn_armed = '1' then
                            btn_event <= '1';               -- pressed
                        end if;
                    else
                        db_cnt <= db_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- ------------------------------------------------------------------
    -- UART messages
    -- ------------------------------------------------------------------
    tx_data  <= MSG1_ROM(to_integer(char_idx)) when msg_sel = '1' else
                MSG0_ROM(to_integer(char_idx));
    msg_last <= '1' when (msg_sel = '1' and char_idx = MSG1_LEN - 1) or
                         (msg_sel = '0' and char_idx = MSG0_LEN - 1) else '0';

    u_uart_tx : entity work.uart_tx
        generic map (
            CLK_HZ => CLK_HZ,
            BAUD   => BAUD
        )
        port map (
            clk_i   => clk_i,
            rst_ni  => rst_n,
            valid_i => tx_valid,
            data_i  => tx_data,
            ready_o => tx_ready,
            txd_o   => txd_o
        );

    -- ------------------------------------------------------------------
    -- Sequencer
    -- ------------------------------------------------------------------
    g_auto : if AUTO_REFRESH_MS > 0 generate
        auto_event <= ms_tick when auto_cnt = to_unsigned(AUTO_REFRESH_MS - 1, AUTO_W) else '0';
    else generate
        auto_event <= '0';
    end generate g_auto;

    tx_valid <= '1' when mstate = M_BANNER or mstate = M_MSG else '0';

    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_n = '0' then
                mstate        <= M_BANNER;
                msg_sel       <= '0';
                char_idx      <= (others => '0');
                auto_cnt      <= (others => '0');
                drain_cnt     <= (others => '0');
                refresh_start <= '0';
            else
                refresh_start <= '0';
                case mstate is
                    when M_BANNER | M_MSG =>
                        if tx_ready = '1' then
                            if msg_last = '1' then
                                char_idx  <= (others => '0');
                                drain_cnt <= (others => '0');
                                mstate    <= M_RUN when mstate = M_BANNER else M_DRAIN;
                            else
                                char_idx <= char_idx + 1;
                            end if;
                        end if;
                    when M_RUN =>
                        if ms_tick = '1' then
                            auto_cnt <= auto_cnt + 1;
                        end if;
                        if btn_event = '1' or auto_event = '1' then
                            msg_sel <= '1';
                            mstate  <= M_MSG;
                        end if;
                    -- Let the last character leave the UART before the device resets.
                    when M_DRAIN =>
                        if drain_cnt /= 3 then
                            drain_cnt <= drain_cnt + 1;
                        elsif tx_ready = '1' then
                            refresh_start <= '1';
                            mstate        <= M_REFRESH;
                        end if;
                    when M_REFRESH =>
                        if refresh_done = '1' then
                            mstate <= M_WAIT;
                        end if;
                    when M_WAIT =>
                        null;                           -- the device should be reconfiguring now
                end case;
            end if;
        end if;
    end process;

    u_lmmi_refresh : entity work.lmmi_refresh
        generic map (
            GAP_CYCLES => LMMI_GAP_CYCLES
        )
        port map (
            clk_i          => clk_i,
            rst_ni         => rst_n,
            start_i        => refresh_start,
            busy_o         => open,
            done_o         => refresh_done,
            lmmi_request_o => lmmi_request_o,
            lmmi_wr_rdn_o  => lmmi_wr_rdn_o,
            lmmi_offset_o  => lmmi_offset_o,
            lmmi_wdata_o   => lmmi_wdata_o,
            lmmi_ready_i   => lmmi_ready_i
        );
    refresh_done_o <= refresh_done;

    -- ------------------------------------------------------------------
    -- LEDs
    -- ------------------------------------------------------------------
    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_n = '0' then
                boot_cnt   <= (others => '0');
                blink_cnt  <= (others => '0');
                boot_led   <= '0';
                heartbeat  <= '0';
                fail_flash <= '0';
            else
                boot_led <= '1' when boot_cnt /= to_unsigned(BOOT_LED_MS, BL_W) else '0';
                if ms_tick = '1' then
                    if boot_cnt /= to_unsigned(BOOT_LED_MS, BL_W) then
                        boot_cnt <= boot_cnt + 1;
                    end if;
                    if blink_cnt = 249 then                        -- 250 ms: 2 Hz heartbeat
                        blink_cnt <= (others => '0');
                        heartbeat <= not heartbeat;
                    else
                        blink_cnt <= blink_cnt + 1;
                    end if;
                    if blink_cnt(5 downto 0) = 0 then              -- 64 ms: fast flash
                        fail_flash <= not fail_flash;
                    end if;
                end if;
            end if;
        end if;
    end process;

    led(0) <= fail_flash when mstate = M_WAIT else boot_led;
    led(1) <= heartbeat;
    led_o  <= not led when LED_ACTIVE_LOW else led;

end architecture rtl;
