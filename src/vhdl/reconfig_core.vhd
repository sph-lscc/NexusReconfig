-- -----------------------------------------------------------------------------
-- reconfig_core.vhd
--
-- Reconfiguration logic of the NexusReconfig reference design (sv-led-blink
-- variant: no UART, no LEDs), without device primitives, so it can be
-- simulated with a behavioural LMMI target model. VHDL-2008 conversion of
-- src/sv/reconfig_core.sv.
--
-- Behaviour:
--   1. After configuration, a power-on reset counter releases the logic.
--   2. A reconfiguration request comes from a falling edge on the debounced,
--      active-low button input, or from the auto-refresh timer AUTO_REFRESH_MS
--      after the reset release (0 disables the timer).
--   3. lmmi_refresh writes LSC_REFRESH to CONFIG_LMMI. The device reconfigures
--      from its boot source and the sequence starts again at step 1.
--   4. If the device is still running after the command (refresh not
--      executed), the sequencer stays in its final state with refresh_done_o
--      high.
-- -----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.nexus_reconfig_pkg.all;

entity reconfig_core is
    generic (
        CLK_HZ          : positive := 25_000_000;   -- sys_clk frequency
        AUTO_REFRESH_MS : natural  := 10_000;       -- 0 = button only
        DEBOUNCE_MS     : positive := 20;
        POR_CYCLES      : positive := 1_024;
        LMMI_GAP_CYCLES : positive := 16
    );
    port (
        clk_i          : in  std_logic;
        rst_no         : out std_logic;             -- released power-on reset (also drives the LMMI reset)

        btn_ni         : in  std_logic;             -- reconfiguration request, active low, asynchronous

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

    -- Sequencer
    type mstate_t is (M_RUN, M_REFRESH, M_WAIT);
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
    -- Sequencer
    -- ------------------------------------------------------------------
    g_auto : if AUTO_REFRESH_MS > 0 generate
        auto_event <= ms_tick when auto_cnt = to_unsigned(AUTO_REFRESH_MS - 1, AUTO_W) else '0';
    else generate
        auto_event <= '0';
    end generate g_auto;

    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_n = '0' then
                mstate        <= M_RUN;
                auto_cnt      <= (others => '0');
                refresh_start <= '0';
            else
                refresh_start <= '0';
                case mstate is
                    when M_RUN =>
                        if ms_tick = '1' then
                            auto_cnt <= auto_cnt + 1;
                        end if;
                        if btn_event = '1' or auto_event = '1' then
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

end architecture rtl;
