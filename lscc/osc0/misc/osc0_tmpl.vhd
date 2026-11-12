component osc0 is
    port(
        hf_out_en_i: in std_logic;
        lmmi_clk_i: in std_logic;
        lmmi_resetn_i: in std_logic;
        hf_clk_out_o: out std_logic;
        smclk_rst_o: out std_logic;
        lmmi_clk_o: out std_logic;
        lmmi_resetn_o: out std_logic
    );
end component;

__: osc0 port map(
    hf_out_en_i=>,
    lmmi_clk_i=>,
    lmmi_resetn_i=>,
    hf_clk_out_o=>,
    smclk_rst_o=>,
    lmmi_clk_o=>,
    lmmi_resetn_o=>
);
