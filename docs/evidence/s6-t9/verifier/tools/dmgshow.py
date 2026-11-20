import json, sys
for l in open(sys.argv[1]):
    x = json.loads(l)
    if "damage" in x: print(x["corpus"], x["case"], "DAMAGE FAILED"); continue
    u = x.get("cli_update", {}).get("err", "-")
    print(f"{x['set']:5s} {x['corpus']:10s} {x['build']:4s} {x['case']:13s} cliQfn={x['cli_query_filename']['rc']}:{x['cli_query_filename']['err'][-40:]:40s} "
          f"open={x['abi_open'][-40:]:20s} fn={x.get('abi_filename','-')[-45:]:45s} cliU={u[-38:]:38s} abiU={x.get('abi_update','-')[-30:]:30s} same={x['unchanged_after_all']}")
