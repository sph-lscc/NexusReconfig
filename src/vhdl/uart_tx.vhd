-- -----------------------------------------------------------------------------
-- uart_tx.vhd
--
-- Minimal UART transmitter, 8 data bits, no parity, 1 stop bit (8N1).
-- -----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.nexus_reconfig_pkg.all;

entity uart_tx is
    generic (
        CLK_HZ : positive := 25_000_000;
        BAUD   : positive := 115_200
    );
    port (
        clk_i   : in  std_logic;
        rst_ni  : in  std_logic;                     -- active-low synchronous reset
        valid_i : in  std_logic;                     -- byte available
        data_i  : in  std_logic_vector(7 downto 0);
        ready_o : out std_logic;                     -- byte taken on valid_i and ready_o
        txd_o   : out std_logic
    );
end entity uart_tx;

architecture rtl of uart_tx is

    constant DIV   : positive := (CLK_HZ + BAUD / 2) / BAUD;   -- clocks per bit, rounded
    constant DIV_W : natural  := clog2(DIV);

    signal baud_cnt : unsigned(DIV_W - 1 downto 0);
    signal bit_cnt  : unsigned(3 downto 0);                    -- 0 = idle, 1..10 = start, 8 data, stop
    signal shreg    : std_logic_vector(9 downto 0);            -- stop & data(7:0) & start

begin

    ready_o <= '1' when bit_cnt = 0 else '0';

    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_ni = '0' then
                baud_cnt <= (others => '0');
                bit_cnt  <= (others => '0');
                shreg    <= (others => '1');
                txd_o    <= '1';
            elsif bit_cnt = 0 then
                txd_o <= '1';
                if valid_i = '1' then
                    shreg    <= '1' & data_i & '0';
                    bit_cnt  <= to_unsigned(10, bit_cnt'length);
                    baud_cnt <= (others => '0');
                end if;
            else
                txd_o <= shreg(0);
                if baud_cnt = to_unsigned(DIV - 1, DIV_W) then
                    baud_cnt <= (others => '0');
                    shreg    <= '1' & shreg(9 downto 1);
                    bit_cnt  <= bit_cnt - 1;
                else
                    baud_cnt <= baud_cnt + 1;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
