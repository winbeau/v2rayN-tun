def use_direct(config):
    """Migrate the domestic outbound and resolver without changing match order."""
    dns = config["dns"]
    config["outbounds"] = [o for o in config["outbounds"] if o["tag"] != "cn-via-jp"]
    dns["servers"] = [s for s in dns["servers"] if s.get("tag") != "jp-dns"]
    for server in dns["servers"]:
        if server.get("detour") == "cn-via-jp":
            server["detour"] = "direct"
    for section, field, old, new in (
        (config["route"], "outbound", "cn-via-jp", "direct"),
        (dns, "server", "jp-dns", "direct-dns-1"),
    ):
        for rule in section.get("rules", []):
            if rule.get(field) == old:
                rule[field] = new
        if section.get("final") == old:
            section["final"] = new
