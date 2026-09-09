#!/usr/bin/env python3
"""Fail closed on incomplete/failed full-SoC implementation reports."""
import argparse,hashlib,json,pathlib,re
p=argparse.ArgumentParser();p.add_argument('build');a=p.parse_args();b=pathlib.Path(a.build)
timing=(b/'timing.rpt').read_text();check=(b/'check_timing.rpt').read_text();drc=(b/'drc.rpt').read_text();cdc=(b/'cdc.rpt').read_text()
match=re.search(r'WNS\(ns\).*?\n\s*[- ]+\n\s*([-+\d.]+)\s+([-+\d.]+)\s+(\d+)\s+(\d+)\s+([-+\d.]+)\s+([-+\d.]+)\s+(\d+)\s+(\d+)\s+([-+\d.]+)\s+([-+\d.]+)\s+(\d+)\s+(\d+)',timing)
assert match,'missing design timing summary'
v=list(map(float,match.groups()));metrics=dict(zip(['wns_ns','tns_ns','setup_failures','setup_endpoints','whs_ns','ths_ns','hold_failures','hold_endpoints','wpws_ns','tpws_ns','pulse_failures','pulse_endpoints'],v))
checks={name:int(count) for name,count in re.findall(r'checking ([a-z_]+) \((\d+)\)',check)}
assert checks and 'unconstrained_internal_endpoints' in checks
rules=re.findall(r'\|\s*([A-Z0-9-]+)\s*\|\s*(Warning|Error|Critical Warning)\s*\|[^\n]*?\|\s*(\d+)\s*\|',drc)
cdc_rules=re.findall(r'^(CDC-\d+)\s+(Info|Warning|Critical)\s+(\d+)\s',cdc,re.M)
assert cdc_rules,'missing CDC report summary'
found=re.search(r'Checks found:\s*(\d+)',drc);assert found,'missing DRC summary'
assert sum(int(count) for rule,severity,count in rules)==int(found[1]),'unparsed DRC category'
# CDC-15 warnings are the packaged SmartConnect data handshakes; reset paths
# are CDC-3 ASYNC_REG synchronizers. A new category requires explicit review.
cdc_ok=all(rule in ('CDC-3','CDC-15') and severity!='Critical' for rule,severity,count in cdc_rules)
passed=(all(v[i]>=0 for i in (0,4,8)) and all(v[i]==0 for i in (2,6,10)) and all(v[i]>0 for i in (3,7,11)) and not any(checks.values()) and not any(severity in ('Error','Critical Warning') for rule,severity,count in rules) and cdc_ok and 'Fully Routed' in drc)
artifacts={}
for f in [*(b/'source').glob('*'),*(b/x for x in ('timing.rpt','check_timing.rpt','drc.rpt','cdc.rpt','utilization.rpt','routed.dcp','accelerator.bit'))]:
 if f.is_file():artifacts[str(f.relative_to(b))]=hashlib.sha256(f.read_bytes()).hexdigest()
clocks={name:{'period_ns':float(period),'frequency_mhz':float(freq)} for name,period,freq in re.findall(r'^(clk_\w+)\s+\{[^}]+\}\s+([\d.]+)\s+([\d.]+)',timing,re.M)}
assert clocks and 'clk_fpga_1' in clocks
result={'passed':passed,'clocks':clocks,'core_rate_hz_limit':int(1e9/clocks['clk_fpga_1']['period_ns']),'metrics':metrics,'constraint_checks':checks,'drc':rules,'cdc':cdc_rules,'cdc_review':'SmartConnect clock-enable data crossings and vendor reset synchronizers; no custom cross-domain datapath','sha256':artifacts}
(b/'timing_audit.json').write_text(json.dumps(result,indent=2)+'\n')
print('TIMING_AUDIT_'+('PASS' if passed else 'FAIL'),json.dumps({'clocks':clocks,'metrics':metrics}));raise SystemExit(0 if passed else 1)
