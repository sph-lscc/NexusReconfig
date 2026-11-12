-- -----------------------------------------------------------------------------
-- tb_reconfig_core.vhd
--
-- Self-checking VHDL-2008 testbench for reconfig_core / lmmi_refresh / uart_tx.
-- It uses only the DUT ports and binds the DUT through a component
-- declaration, so it runs unchanged against the VHDL-2008 implementation
-- (src/*.vhd) and the SystemVerilog original (commit 41439d8).
--
-- The CONFIG_LMMI primitive has no supported simulation model
-- (FPGA-TN-02099-3.7, Table D.1 note 1), so lmmi_target_model below stands in
-- for it. It implements the documented write protocol (Appendix D.3): a byte is
-- accepted on a clock edge with lmmi_request and lmmi_ready, and lmmi_ready is
-- randomly withheld to exercise back-pressure.
--
-- Three DUT instances run in parallel, with scaled timing (1 MHz clock):
--   A  auto-refresh timer, button released:  banner, refresh message,
--      LSC_REFRESH 79 00 00 00, then the failure flash on led(0) because the
--      model does not reconfigure the device.
--   B  timer disabled, button pressed once:  same sequence, triggered by the
--      button.
--   C  timer disabled, button stuck low:     banner only, no LMMI transfer.
-- -----------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Testbench helpers
-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use std.textio.all;

package tb_util_pkg is
    procedure print(s : string);
    impure function ms_now return string;           -- simulation time in ms, "%8.3f"
    constant MSG0 : string := CR & LF & "NexusReconfig: FPGA configured" & CR & LF;
    constant MSG1 : string := "NexusReconfig: issuing LSC_REFRESH" & CR & LF;
    subtype text_t is string(1 to 128);
end package tb_util_pkg;

package body tb_util_pkg is
    procedure print(s : string) is
        variable l : line;
    begin
        write(l, s);
        writeline(output, l);
    end procedure print;

    impure function ms_now return string is
    begin
        return to_string(real(now / 1 ns) / 1.0e6, "%8.3f");
    end function ms_now;
end package body tb_util_pkg;

-- ---------------------------------------------------------------------------
-- LMMI target model (CONFIG_LMMI write protocol)
-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.math_real.all;
use work.tb_util_pkg.all;

entity lmmi_target_model is
    generic (
        NAME : string   := "lmmi";
        SEED : positive := 1
    );
    port (
        clk          : in  std_logic;
        request      : in  std_logic;
        wr_rdn       : in  std_logic;
        offset       : in  std_logic_vector(7 downto 0);
        wdata        : in  std_logic_vector(7 downto 0);
        ready        : out std_logic;
        n_bytes      : out natural;
        errors       : out natural;
        refresh_seen : out boolean      -- exactly 79 00 00 00 received
    );
end entity lmmi_target_model;

architecture model of lmmi_target_model is
    signal rdy : std_logic := '1';
begin
    ready <= rdy;

    process (clk)
        type bytes_t is array (0 to 7) of std_logic_vector(7 downto 0);
        variable bytes     : bytes_t := (others => (others => '0'));
        variable nb        : natural := 0;
        variable err       : natural := 0;
        variable ready_run : natural := 0;          -- consecutive cycles with ready high
        variable prev_req  : std_logic := '0';
        variable s1        : positive := SEED;
        variable s2        : positive := 7;
        variable x         : real;
    begin
        if rising_edge(clk) then
            -- Transfer accepted on this edge?
            if request = '1' and rdy = '1' then
                if wr_rdn /= '1' then
                    print("[" & NAME & "] ERROR: read transfer, LMMIWRRD_N=" & to_string(wr_rdn));
                    err := err + 1;
                end if;
                if offset /= x"01" then
                    print("[" & NAME & "] ERROR: LMMIOFFSET=" & to_hstring(offset) & ", expected 01");
                    err := err + 1;
                end if;
                if nb < 8 then
                    bytes(nb) := wdata;
                end if;
                print("[" & NAME & "] " & ms_now & " ms: byte " & to_string(nb) & " = " & to_hstring(wdata));
                nb := nb + 1;
            end if;
            -- Start of a command: at least four ready cycles must precede it.
            if request = '1' and prev_req = '0' and ready_run < 4 then
                print("[" & NAME & "] ERROR: request after only " & to_string(ready_run) & " ready cycles");
                err := err + 1;
            end if;
            prev_req  := request;
            ready_run := ready_run + 1 when rdy = '1' else 0;
            -- Random back-pressure, about one cycle in three.
            uniform(s1, s2, x);
            rdy <= '0' when x < 1.0 / 3.0 else '1';

            n_bytes      <= nb;
            errors       <= err;
            refresh_seen <= nb = 4 and bytes(0) = x"79" and bytes(1) = x"00" and
                            bytes(2) = x"00" and bytes(3) = x"00";
        end if;
    end process;
end architecture model;

-- ---------------------------------------------------------------------------
-- UART monitor (8N1): collects the received characters
-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.tb_util_pkg.all;

entity uart_monitor is
    generic (
        NAME     : string := "uart";
        BIT_TIME : time   := 20 us
    );
    port (
        rxd  : in  std_logic;
        text : out text_t;
        len  : out natural
    );
end entity uart_monitor;

architecture model of uart_monitor is
begin
    process
        variable buf : text_t := (others => NUL);
        variable n   : natural := 0;
        variable c   : std_logic_vector(7 downto 0);
    begin
        text <= buf;
        len  <= 0;
        loop
            wait until falling_edge(rxd);
            wait for BIT_TIME / 2;
            next when rxd /= '0';                     -- glitch, not a start bit
            for i in 0 to 7 loop
                wait for BIT_TIME;
                c(i) := rxd;
            end loop;
            wait for BIT_TIME;
            if rxd /= '1' then
                print("[" & NAME & "] ERROR: framing error");
            end if;
            if n < text_t'length then
                n := n + 1;
                buf(n) := character'val(to_integer(unsigned(c)));
            end if;
            text <= buf;
            len  <= n;
        end loop;
    end process;
end architecture model;

-- ---------------------------------------------------------------------------
-- Testbench top level
-- ---------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use work.tb_util_pkg.all;

entity tb_reconfig_core is
end entity tb_reconfig_core;

architecture sim of tb_reconfig_core is

    constant CLK_HZ   : positive := 1_000_000;
    constant BAUD     : positive := 50_000;
    constant BIT_TIME : time     := 1 sec / BAUD;

    -- Component declaration (not entity instantiation), so the DUT can be
    -- either the VHDL entity or the SystemVerilog module of the same name.
    component reconfig_core is
        generic (
            CLK_HZ          : integer;
            BAUD            : integer;
            AUTO_REFRESH_MS : integer;
            BOOT_LED_MS     : integer;
            DEBOUNCE_MS     : integer;
            POR_CYCLES      : integer
        );
        port (
            clk_i          : in  std_logic;
            rst_no         : out std_logic;
            btn_ni         : in  std_logic;
            led_o          : out std_logic_vector(1 downto 0);
            txd_o          : out std_logic;
            lmmi_request_o : out std_logic;
            lmmi_wr_rdn_o  : out std_logic;
            lmmi_offset_o  : out std_logic_vector(7 downto 0);
            lmmi_wdata_o   : out std_logic_vector(7 downto 0);
            lmmi_ready_i   : in  std_logic;
            refresh_done_o : out std_logic
        );
    end component reconfig_core;

    signal clk : std_logic := '0';

    -- instance A: auto refresh
    signal a_btn : std_logic := '1';
    signal a_led : std_logic_vector(1 downto 0);
    signal a_txd, a_req, a_wr, a_rdy, a_done : std_logic;
    signal a_off, a_wd : std_logic_vector(7 downto 0);
    signal a_text : text_t;
    signal a_len, a_nb, a_err : natural;
    signal a_seen : boolean;

    -- instance B: button
    signal b_btn : std_logic := '1';
    signal b_led : std_logic_vector(1 downto 0);
    signal b_txd, b_req, b_wr, b_rdy, b_done : std_logic;
    signal b_off, b_wd : std_logic_vector(7 downto 0);
    signal b_text : text_t;
    signal b_len, b_nb, b_err : natural;
    signal b_seen : boolean;

    -- instance C: button stuck low
    signal c_btn : std_logic := '0';
    signal c_led : std_logic_vector(1 downto 0);
    signal c_txd, c_req, c_wr, c_rdy, c_done : std_logic;
    signal c_off, c_wd : std_logic_vector(7 downto 0);
    signal c_text : text_t;
    signal c_len, c_nb, c_err : natural;
    signal c_seen : boolean;

    -- error counts of the concurrent checkers
    signal err_req  : natural := 0;
    signal err_boot : natural := 0;

begin

    clk <= not clk after 500 ns;                      -- 1 MHz

    -- ---------------- instance A: auto refresh ----------------
    dut_a : reconfig_core
        generic map (CLK_HZ => CLK_HZ, BAUD => BAUD, AUTO_REFRESH_MS => 5, BOOT_LED_MS => 2,
                     DEBOUNCE_MS => 2, POR_CYCLES => 16)
        port map (clk_i => clk, rst_no => open, btn_ni => a_btn, led_o => a_led, txd_o => a_txd,
                  lmmi_request_o => a_req, lmmi_wr_rdn_o => a_wr, lmmi_offset_o => a_off,
                  lmmi_wdata_o => a_wd, lmmi_ready_i => a_rdy, refresh_done_o => a_done);
    lmmi_a : entity work.lmmi_target_model
        generic map (NAME => "A lmmi", SEED => 11)
        port map (clk => clk, request => a_req, wr_rdn => a_wr, offset => a_off, wdata => a_wd,
                  ready => a_rdy, n_bytes => a_nb, errors => a_err, refresh_seen => a_seen);
    uart_a : entity work.uart_monitor
        generic map (NAME => "A uart", BIT_TIME => BIT_TIME)
        port map (rxd => a_txd, text => a_text, len => a_len);

    -- ---------------- instance B: button ----------------
    dut_b : reconfig_core
        generic map (CLK_HZ => CLK_HZ, BAUD => BAUD, AUTO_REFRESH_MS => 0, BOOT_LED_MS => 2,
                     DEBOUNCE_MS => 2, POR_CYCLES => 16)
        port map (clk_i => clk, rst_no => open, btn_ni => b_btn, led_o => b_led, txd_o => b_txd,
                  lmmi_request_o => b_req, lmmi_wr_rdn_o => b_wr, lmmi_offset_o => b_off,
                  lmmi_wdata_o => b_wd, lmmi_ready_i => b_rdy, refresh_done_o => b_done);
    lmmi_b : entity work.lmmi_target_model
        generic map (NAME => "B lmmi", SEED => 23)
        port map (clk => clk, request => b_req, wr_rdn => b_wr, offset => b_off, wdata => b_wd,
                  ready => b_rdy, n_bytes => b_nb, errors => b_err, refresh_seen => b_seen);
    uart_b : entity work.uart_monitor
        generic map (NAME => "B uart", BIT_TIME => BIT_TIME)
        port map (rxd => b_txd, text => b_text, len => b_len);

    -- ---------------- instance C: button stuck low ----------------
    dut_c : reconfig_core
        generic map (CLK_HZ => CLK_HZ, BAUD => BAUD, AUTO_REFRESH_MS => 0, BOOT_LED_MS => 2,
                     DEBOUNCE_MS => 2, POR_CYCLES => 16)
        port map (clk_i => clk, rst_no => open, btn_ni => c_btn, led_o => c_led, txd_o => c_txd,
                  lmmi_request_o => c_req, lmmi_wr_rdn_o => c_wr, lmmi_offset_o => c_off,
                  lmmi_wdata_o => c_wd, lmmi_ready_i => c_rdy, refresh_done_o => c_done);
    lmmi_c : entity work.lmmi_target_model
        generic map (NAME => "C lmmi", SEED => 37)
        port map (clk => clk, request => c_req, wr_rdn => c_wr, offset => c_off, wdata => c_wd,
                  ready => c_rdy, n_bytes => c_nb, errors => c_err, refresh_seen => c_seen);
    uart_c : entity work.uart_monitor
        generic map (NAME => "C uart", BIT_TIME => BIT_TIME)
        port map (rxd => c_txd, text => c_text, len => c_len);

    -- ---------------- checks during the run ----------------
    -- The refresh must not start before the refresh message has fully left the UART.
    process (clk)
        variable n : natural := 0;
    begin
        if rising_edge(clk) then
            if a_req = '1' and a_text(1 to a_len) /= MSG0 & MSG1 then
                print("ERROR: A: LMMI request before the UART message completed"); n := n + 1;
            end if;
            if b_req = '1' and b_text(1 to b_len) /= MSG0 & MSG1 then
                print("ERROR: B: LMMI request before the UART message completed"); n := n + 1;
            end if;
            err_req <= n;
        end if;
    end process;

    -- Event log (time in ms), from the DUT ports only.
    process (clk)
        variable past_a, past_b : natural := 0;
        variable b_btn_q        : std_logic := '1';
    begin
        if rising_edge(clk) then
            if a_len /= past_a then
                if a_text(1 to a_len) = MSG0        then print("[A] " & ms_now & " ms: banner received"); end if;
                if a_text(1 to a_len) = MSG0 & MSG1 then print("[A] " & ms_now & " ms: refresh message received"); end if;
            end if;
            if b_len /= past_b then
                if b_text(1 to b_len) = MSG0        then print("[B] " & ms_now & " ms: banner received"); end if;
                if b_text(1 to b_len) = MSG0 & MSG1 then print("[B] " & ms_now & " ms: refresh message received"); end if;
            end if;
            if b_btn_q = '1' and b_btn = '0' then
                print("[B] " & ms_now & " ms: button pressed");
            end if;
            past_a  := a_len;
            past_b  := b_len;
            b_btn_q := b_btn;
        end if;
    end process;

    -- led(0) must be on during the boot window.
    process
        variable n : natural := 0;
    begin
        wait for 1 ms;                                -- inside BOOT_LED_MS = 2 ms
        if a_led(0) /= '1' then print("ERROR: A: boot LED not on at 1 ms"); n := n + 1; end if;
        wait for 3 ms;                                -- 4 ms: after the boot window
        if a_led(0) /= '0' then print("ERROR: A: boot LED still on at 4 ms"); n := n + 1; end if;
        err_boot <= n;
        wait;
    end process;

    -- Button press for instance B: after the banner (6.8 ms) and arming.
    process
    begin
        wait for 12 ms;
        b_btn <= '0';
        wait for 5 ms;
        b_btn <= '1';
        wait;
    end process;

    -- ---------------- final checks ----------------
    process
        variable errors : natural := 0;
        variable ta, tb : natural;

        procedure check(name : string; cond : boolean) is
        begin
            if not cond then
                print("ERROR: " & name); errors := errors + 1;
            else
                print("ok   : " & name);
            end if;
        end procedure check;

        -- Count led(0) toggles over 150 ms: the fast flash toggles every 64 ms.
        procedure count_toggles(signal led : in std_logic_vector(1 downto 0); n : out natural) is
            variable prev : std_logic;
            variable cnt  : natural := 0;
        begin
            prev := led(0);
            for i in 1 to 150_000 loop
                wait until rising_edge(clk);
                if led(0) /= prev then
                    cnt := cnt + 1;
                end if;
                prev := led(0);
            end loop;
            n := cnt;
        end procedure count_toggles;

        function known(s : std_logic) return boolean is
        begin
            return s = '0' or s = '1';
        end function known;
    begin
        wait for 40 ms;
        count_toggles(a_led, ta);
        count_toggles(b_led, tb);

        check("A: UART text = banner + refresh message", a_text(1 to a_len) = MSG0 & MSG1);
        check("A: LSC_REFRESH 79 00 00 00 written, nothing else", a_seen);
        check("A: refresh_done asserted", a_done = '1');
        check("A: led[0] fast flash after unexecuted refresh", ta >= 2);
        check("B: UART text = banner + refresh message", b_text(1 to b_len) = MSG0 & MSG1);
        check("B: LSC_REFRESH 79 00 00 00 written, nothing else", b_seen);
        check("B: refresh_done asserted", b_done = '1');
        check("B: led[0] fast flash after unexecuted refresh", tb >= 2);
        check("C: UART text = banner only", c_text(1 to c_len) = MSG0);
        check("C: no LMMI transfer with button stuck low", c_nb = 0);
        check("C: refresh_done not asserted", c_done = '0');
        check("A/B/C: heartbeat running", known(a_led(1)) and known(b_led(1)));

        errors := errors + err_req + err_boot + a_err + b_err + c_err;
        if errors = 0 then
            print("TEST PASSED");
        else
            print("TEST FAILED: " & to_string(errors) & " error(s)");
        end if;
        std.env.finish;
    end process;

    process
    begin
        wait for 400 ms;
        print("TEST FAILED: watchdog timeout");
        std.env.finish;
    end process;

end architecture sim;
