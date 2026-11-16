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

end package body nexus_reconfig_pkg;
