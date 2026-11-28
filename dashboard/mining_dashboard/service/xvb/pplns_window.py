from mining_dashboard.helper.utils import DEFAULT_PPLNS_WINDOW, pplns_block_time


def pplns_window_terms(p2pool_stats, p2p_stats):
    pplns_window = p2pool_stats.get("pplns_window", DEFAULT_PPLNS_WINDOW)
    block_time = pplns_block_time(p2p_stats.get("type", "Main"))
    return pplns_window, block_time, pplns_window * block_time
