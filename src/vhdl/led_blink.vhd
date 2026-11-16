-- -----------------------------------------------------------------------------
-- led_blink.vhd
--
-- Free-running LED flasher, independent of the reconfiguration logic: it has
-- no reset input and no connection to reconfig_core, the button, the
-- auto-refresh timer or CONFIG_LMMI. Its registers start from their
-- configuration-time value (0), so it starts flashing as soon as the device
-- enters user mode and the clock runs.
--
-- The only thing it shares with the rest of the design is the clock. A
-- refresh reconfigures the whole device, so the flasher also restarts (LED off,
-- counter at 0) after every LSC_REFRESH; that restart is a visible sign of the
-- refresh. VHDL-2008 conversion of src/sv/led_blink.sv.
-- -----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.nexus_reconfig_pkg.all;

entity led_blink is
    generic (
        CLK_HZ     : positive := 25_000_000;    -- clk_i frequency
        HALF_MS    : positive := 500;           -- LED on time = off time (500 ms: 1 Hz)
        ACTIVE_LOW : boolean  := false          -- true if the LED lights on a low level
    );
    port (
        clk_i : in  std_logic;
        led_o : out std_logic
    );
end entity led_blink;

architecture rtl of led_blink is

    constant HALF_CYCLES : positive := CLK_HZ / 1000 * HALF_MS;
    constant CNT_W       : natural  := clog2(HALF_CYCLES);

    signal cnt : unsigned(CNT_W - 1 downto 0) := (others => '0');
    signal led : std_logic := '0';

begin

    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if cnt = to_unsigned(HALF_CYCLES - 1, CNT_W) then
                cnt <= (others => '0');
                led <= not led;
            else
                cnt <= cnt + 1;
            end if;
        end if;
    end process;

    led_o <= not led when ACTIVE_LOW else led;

end architecture rtl;
