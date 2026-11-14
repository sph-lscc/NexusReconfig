-- -----------------------------------------------------------------------------
-- lmmi_refresh.vhd
--
-- LMMI host that sends the LSC_REFRESH command (opcode 0x79) to the Nexus
-- configuration block through the CONFIG_LMMI primitive. LSC_REFRESH is
-- equivalent to toggling the PROGRAMN pin: the device clears its configuration
-- SRAM and reloads its bitstream from the configured boot source (external SPI
-- flash on Certus-NX). Once the command is accepted, this logic, and the rest
-- of the user design, ceases to exist.
--
-- Protocol (FPGA-TN-02099-3.7, Appendix D.3 and Table D.3):
--   - The configuration register has the fixed LMMI offset ADDR_CFG = 0x01.
--   - A command is one opcode byte followed by three operand bytes, written
--     back to back with lmmi_request and lmmi_wr_rdn held high. A byte is
--     accepted on a clock edge where lmmi_request and lmmi_ready are both high.
--   - LSC_REFRESH is the only Class D command and is executed as a Class C
--     command (no data bytes, no read-back).
--   - OPERAND1 = 0x00 keeps the Override ENABLE bit (bit 6) clear, so the
--     refresh uses the device's normal boot settings (Table 6.20).
--   - Wait at least four LMMI clock cycles after lmmi_ready is high before
--     issuing a command (GAP_CYCLES below, default 16).
--
-- The command sequence follows the LSC_REFRESH step of the refresh controller
-- in FPGA-RD-02294 (source/impl_1/refresh.v), without the Multi-Boot steps.
-- -----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.nexus_reconfig_pkg.all;

entity lmmi_refresh is
    generic (
        GAP_CYCLES : positive := 16     -- LMMI idle cycles (with ready high) before the command
    );
    port (
        clk_i          : in  std_logic;     -- LMMI clock (same clock as CONFIG_LMMI LMMICLK)
        rst_ni         : in  std_logic;     -- active-low synchronous reset
        start_i        : in  std_logic;     -- one-cycle pulse: issue LSC_REFRESH
        busy_o         : out std_logic;     -- command in progress
        done_o         : out std_logic;     -- all four bytes accepted (device should now reconfigure)

        -- LMMI host port, connect to CONFIG_LMMI
        lmmi_request_o : out std_logic;
        lmmi_wr_rdn_o  : out std_logic;
        lmmi_offset_o  : out std_logic_vector(7 downto 0);
        lmmi_wdata_o   : out std_logic_vector(7 downto 0);
        lmmi_ready_i   : in  std_logic
    );
end entity lmmi_refresh;

architecture rtl of lmmi_refresh is

    constant ADDR_CFG    : std_logic_vector(7 downto 0) := x"01";   -- CONFIG_LMMI configuration register offset
    constant LSC_REFRESH : std_logic_vector(7 downto 0) := x"79";   -- opcode
    constant REFRESH_OP1 : std_logic_vector(7 downto 0) := x"00";   -- OPERAND1: no boot-mode override
    constant REFRESH_OP2 : std_logic_vector(7 downto 0) := x"00";   -- OPERAND2
    constant REFRESH_OP3 : std_logic_vector(7 downto 0) := x"00";   -- OPERAND3

    constant GAP_W : natural := clog2(GAP_CYCLES + 1);

    type state_t is (S_IDLE, S_GAP, S_SEND, S_DONE);

    signal state    : state_t;
    signal byte_idx : unsigned(1 downto 0);
    signal gap_cnt  : unsigned(GAP_W - 1 downto 0);

begin

    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_ni = '0' then
                state    <= S_IDLE;
                byte_idx <= (others => '0');
                gap_cnt  <= (others => '0');
            else
                case state is
                    when S_IDLE =>
                        byte_idx <= (others => '0');
                        gap_cnt  <= (others => '0');
                        if start_i = '1' then
                            state <= S_GAP;
                        end if;
                    -- Count GAP_CYCLES consecutive cycles with lmmi_ready high.
                    when S_GAP =>
                        if lmmi_ready_i = '0' then
                            gap_cnt <= (others => '0');
                        elsif gap_cnt = to_unsigned(GAP_CYCLES, GAP_W) then
                            state <= S_SEND;
                        else
                            gap_cnt <= gap_cnt + 1;
                        end if;
                    -- Opcode and three operands, one byte per accepted transfer.
                    when S_SEND =>
                        if lmmi_ready_i = '1' then
                            if byte_idx = 3 then
                                state <= S_DONE;
                            end if;
                            byte_idx <= byte_idx + 1;
                        end if;
                    -- The device reconfigures; stay here if it does not.
                    when S_DONE =>
                        null;
                end case;
            end if;
        end if;
    end process;

    with byte_idx select lmmi_wdata_o <=
        LSC_REFRESH when "00",
        REFRESH_OP1 when "01",
        REFRESH_OP2 when "10",
        REFRESH_OP3 when others;

    lmmi_request_o <= '1' when state = S_SEND else '0';
    lmmi_wr_rdn_o  <= '1' when state = S_SEND else '0';
    lmmi_offset_o  <= ADDR_CFG;
    busy_o         <= '1' when state = S_GAP or state = S_SEND else '0';
    done_o         <= '1' when state = S_DONE else '0';

end architecture rtl;
