-- -----------------------------------------------------------------------------
-- nexus_reconfig_pkg.vhd
--
-- Shared helpers for the NexusReconfig VHDL-2008 sources.
-- -----------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package nexus_reconfig_pkg is

    -- Ceiling of log2(n), same result as the SystemVerilog $clog2:
    -- clog2(0) = clog2(1) = 0, clog2(2) = 1, clog2(5) = 3.
    function clog2(n : natural) return natural;

    type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

    -- Convert a string into a byte ROM of DEPTH entries, padded with 0x00.
    function to_rom(s : string; depth : positive) return byte_array_t;

end package nexus_reconfig_pkg;

package body nexus_reconfig_pkg is

    function clog2(n : natural) return natural is
        variable r : natural := 0;
        variable v : natural := 1;
    begin
        while v < n loop
            v := v * 2;
            r := r + 1;
        end loop;
        return r;
    end function clog2;

    function to_rom(s : string; depth : positive) return byte_array_t is
        variable rom : byte_array_t(0 to depth - 1) := (others => (others => '0'));
    begin
        for i in 0 to s'length - 1 loop
            rom(i) := std_logic_vector(to_unsigned(character'pos(s(s'low + i)), 8));
        end loop;
        return rom;
    end function to_rom;

end package body nexus_reconfig_pkg;
