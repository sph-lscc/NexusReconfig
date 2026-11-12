    osc0 u_osc0(.hf_out_en_i(hf_out_en_i),
        .lmmi_clk_i(lmmi_clk_i),
        .lmmi_resetn_i(lmmi_resetn_i),
        .hf_clk_out_o(hf_clk_out_o),
        .smclk_rst_o(smclk_rst_o),
        .lmmi_clk_o(lmmi_clk_o),
        .lmmi_resetn_o(lmmi_resetn_o));
