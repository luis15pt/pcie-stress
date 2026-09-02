#!/usr/bin/env python3
"""Generate the GPU dropout diagnostics Grafana dashboard.

Kept as a generator rather than hand-written JSON so panel layout is computed
(no hand-maintained gridPos arithmetic) and every panel description - which is
where the investigation's conclusions are encoded - stays readable in source.

Regenerate: python3 host/gen_dashboard.py > host/grafana-dashboard-gpu-dropout.json
"""
import json

DS = {"type": "prometheus", "uid": "576oRvhVz"}
panels = []
_id = [0]
_y = [0]


def nid():
    _id[0] += 1
    return _id[0]


def row(title):
    panels.append({"type": "row", "title": title, "collapsed": False,
                   "id": nid(), "gridPos": {"h": 1, "w": 24, "x": 0, "y": _y[0]}})
    _y[0] += 1


def band(h):
    """Start a horizontal band of panels of height h; returns an x allocator."""
    y = _y[0]
    _y[0] += h
    state = {"x": 0}

    def place(w):
        x = state["x"]
        state["x"] += w
        return {"h": h, "w": w, "x": x, "y": y}
    return place


def tgt(expr, legend, **kw):
    t = {"refId": chr(65 + kw.pop("i", 0)), "expr": expr, "legendFormat": legend}
    t.update(kw)
    return t


def ts(title, desc, gp, targets, unit=None, steps=None, calcs=("last", "max"),
       overrides=(), fill=0, width=1, style=None, legend="table", stepped=False,
       maxv=None, color_thresholds=False, hide_legend=False):
    custom = {"lineWidth": width, "fillOpacity": fill, "showPoints": "never"}
    if stepped:
        custom["lineInterpolation"] = "stepAfter"
    if style:
        custom["thresholdsStyle"] = {"mode": style}
    defaults = {"custom": custom}
    if unit:
        defaults["unit"] = unit
    if maxv is not None:
        defaults["max"] = maxv
    if steps:
        defaults["thresholds"] = {"mode": "absolute", "steps": steps}
        if color_thresholds:
            defaults["color"] = {"mode": "thresholds"}
    p = {"type": "timeseries", "title": title, "description": desc,
         "id": nid(), "gridPos": gp, "datasource": DS,
         "targets": [tgt(e, l, i=n) for n, (e, l) in enumerate(targets)],
         "fieldConfig": {"defaults": defaults, "overrides": list(overrides)},
         "options": {"legend": {"displayMode": legend, "placement": "bottom",
                                "calcs": list(calcs),
                                "showLegend": not hide_legend},
                     "tooltip": {"mode": "multi", "sort": "desc"}}}
    panels.append(p)


def stat(title, desc, gp, expr, legend, unit=None, steps=None,
         mode="value", graph="none", decimals=None):
    defaults = {}
    if unit:
        defaults["unit"] = unit
    if decimals is not None:
        defaults["decimals"] = decimals
    if steps:
        defaults["thresholds"] = {"mode": "absolute", "steps": steps}
    panels.append({"type": "stat", "title": title, "description": desc,
                   "id": nid(), "gridPos": gp, "datasource": DS,
                   "targets": [tgt(expr, legend)],
                   "fieldConfig": {"defaults": defaults, "overrides": []},
                   "options": {"colorMode": mode, "graphMode": graph,
                               "textMode": "value_and_name"}})


def axis_right(regex, unit=None):
    props = [{"id": "custom.axisPlacement", "value": "right"}]
    if unit:
        props.append({"id": "unit", "value": unit})
    return {"matcher": {"id": "byRegexp", "options": regex}, "properties": props}


def unit_for(regex, unit):
    return {"matcher": {"id": "byRegexp", "options": regex},
            "properties": [{"id": "unit", "value": unit}]}


GY = [{"color": "green", "value": None}, {"color": "yellow", "value": 95},
      {"color": "red", "value": 100}]
RED1 = [{"color": "green", "value": None}, {"color": "red", "value": 1}]

# ---------------------------------------------------------------- at a glance
row("At a glance")
p = band(4)
stat("GPUs visible",
     "DCGM keeps reporting a dead GPU, so a drop here means the driver lost it "
     "entirely. Zhen should be 5; Juno should be 5 but is currently 4 - "
     "01:00.0 is dead pending a power cycle.",
     p(3), 'count by (host) (DCGM_FI_DEV_GPU_TEMP{host=~"$host"})', "{{host}}",
     steps=[{"color": "red", "value": None}, {"color": "yellow", "value": 4},
            {"color": "green", "value": 5}])
stat("XID now", "Non-zero = a GPU raised an Xid. 79 = 'fallen off the bus'.",
     p(3), 'max by (host) (DCGM_FI_DEV_XID_ERRORS{host=~"$host"})', "{{host}}",
     steps=RED1, mode="background")
stat("Chassis power",
     "BMC DCMI whole-chassis draw. The established death mechanism is a STEP "
     "in this value, not a high level.",
     p(3), 'sum by (host) (ipmi_dcmi_power_consumption_watts{host=~"$host"})',
     "{{host}}", unit="watt", graph="area")
stat("PSU total out",
     "Sum of PSU output from the local PMBus exporter, which sees PSUs the BMC "
     "cannot.", p(3),
     'sum by (host) (octoserver_psu_output_power_watts{host=~"$host",psu="PowerPSUTotal"})',
     "{{host}}", unit="watt", graph="area")
stat("Max junction",
     "Vendor: sustained >=100C under a DEFINED load = due for service. A "
     "legitimate soak reaches 100-110C, so never read this without load "
     "context.", p(3),
     'max by (host) (gpu_junction_temp_celsius{host=~"$host"})', "{{host}}",
     unit="celsius", steps=GY, mode="background", graph="area")
stat("12V rail (min)",
     "Power-delivery hypothesis: a sag here coincident with a power step is "
     "the smoking gun to look for.", p(3),
     'min by (host) (ipmi_voltage_volts{host=~"$host",name="12V"})', "{{host}}",
     unit="volt", decimals=2, graph="area")
stat("Uptime",
     "Short uptime after an unexplained gap means the HOST went down, not just "
     "a GPU.", p(3), 'time() - node_boot_time_seconds{host=~"$host"}',
     "{{host}}", unit="s")
stat("Exporters down",
     "If non-zero, panels below may be blank for reasons unrelated to "
     "hardware.", p(3), 'count(up{host=~"$host"} == 0) or vector(0)', "down",
     steps=RED1, mode="background")

p = band(5)
panels.append({
    "type": "text", "title": "How to use this dashboard", "id": nid(),
    "gridPos": p(24), "options": {"mode": "markdown", "content": (
        "**Established (do not re-litigate):** deaths ride host power "
        "**transients** (400-1900W steps); *ruled out* are PCIe signal "
        "integrity (zero AER, zero replays in 70 days), PCIe switches (none "
        "exist - direct root ports), ambient/diurnal timing, and PSU shelf "
        "state as a sole cause. Card **349f61c8** accounts for 14 of 27 deaths "
        "across two hosts and four slots - track cards by **UUID, never by "
        "slot**.\n\n"
        "**Workflow after a death:** find the red XID annotation, then read "
        "*Power transients* and *12V rail* at that timestamp, then *Active "
        "throttle reasons*. Temperature has never distinguished the bad card - "
        "survival time under load did.\n\n"
        "**Two limits to keep in mind.** (1) Scrape interval is 60s, so no "
        "panel here can show sub-minute rail behaviour - the host's 5Hz ring "
        "at `/var/log/gpu-recorder/telemetry.csv` and the incident bundles are "
        "the only sub-second record. (2) Junction temperature comes from a "
        "third-party BAR0 register offset whose 5090 profile is upstream-"
        "**experimental**; a gap in the junction series means *rejected or "
        "stale*, not cool. Check the **Monitoring health** row before drawing "
        "a conclusion from it.")}})

# ------------------------------------------------------------ power delivery
row("Power delivery - the established death mechanism")
p = band(9)
ts("Per-GPU power draw",
   "10 of 11 resolvable deaths sat on a 400-1900W host power step. Look for "
   "one card's draw stepping hard, or all cards ramping together.",
   p(12), [('DCGM_FI_DEV_POWER_USAGE{host=~"$host",gpu=~"$gpu"}',
            "{{host}} gpu{{gpu}} {{pci_bus_id}}")], unit="watt", fill=8)
ts("Power budget: GPUs vs PSU output vs chassis",
   "Three independent measurements of the same power. Divergence between them "
   "is itself a finding - e.g. PSU output far exceeding GPU draw means "
   "something else is loading the rails.",
   p(12), [('sum by (host) (DCGM_FI_DEV_POWER_USAGE{host=~"$host"})',
            "{{host}} GPUs sum"),
           ('sum by (host) (octoserver_psu_output_power_watts{host=~"$host",psu="PowerPSUTotal"})',
            "{{host}} PSU out"),
           ('sum by (host) (ipmi_dcmi_power_consumption_watts{host=~"$host"})',
            "{{host}} chassis DCMI")], unit="watt", width=2)

p = band(8)
ts("Power TRANSIENTS (5m change in total GPU draw)",
   "THE key panel: deaths correlate with steps of 400-1900W. Spikes here - in "
   "either direction - are the events to line up against the red XID "
   "annotations. RESOLUTION CAVEAT: Prometheus scrapes these hosts every 60s, "
   "so a 1m window contains a single sample and this panel can only show "
   "minute-scale steps. Genuine sub-second rail transients are invisible here "
   "and exist ONLY in the recorder's 5Hz ring on the host "
   "(/var/log/gpu-recorder/telemetry.csv) - do not conclude 'no transient' "
   "from this panel alone.",
   p(8), [('sum by (host) (delta(DCGM_FI_DEV_POWER_USAGE{host=~"$host"}[5m]))',
           "{{host}} dW/5m")], unit="watt", fill=20,
   steps=[{"color": "green", "value": None}, {"color": "yellow", "value": 400},
          {"color": "red", "value": 1000}], color_thresholds=True,
   legend="list", calcs=())
ts("12V rail voltage",
   "Zoom in hard. A dip at the instant of a power step supports the "
   "power-delivery hypothesis; a flat rail through a step weakens it.",
   p(8), [('ipmi_voltage_volts{host=~"$host",name="12V"}', "{{host}} 12V")],
   unit="volt", width=2, calcs=("last", "min", "max"))
ts("Per-PSU output power",
   "Uneven sharing, or one PSU dropping its share, points at a specific unit. "
   "PSU faults here followed the HARDWARE across slots, not the slot.",
   p(8), [('octoserver_psu_output_power_watts{host=~"$host",psu!="PowerPSUTotal"}',
           "{{host}} {{psu}} slot{{slot}}")], unit="watt", fill=8)

p = band(8)
ts("PSU status OK (0 = fault)",
   "Necessary but not sufficient: a host ran 10,849 minutes on a degraded "
   "shelf with ZERO deaths, so a fault here does not by itself explain a "
   "dropout.",
   p(8), [('octoserver_psu_status_ok{host=~"$host"}',
           "{{host}} {{psu}} slot{{slot}}")], fill=15, width=2, stepped=True,
   maxv=1, calcs=("last", "min"))
ts("All board rails",
   "VCPU/VSOC/VCCM are the CPU and DRAM rails. A correlated wobble across "
   "several rails suggests an upstream (PSU/input) cause rather than one "
   "failing regulator.",
   p(8), [('ipmi_voltage_volts{host=~"$host",name=~"12V|5V|3V|1.8V|VCPU|VSOC|VCCM.*|VPPM.*"}',
           "{{host}} {{name}}")], unit="volt",
   calcs=("last", "min", "max"))
ts("PSU input voltage & current",
   "Mains-side view. A sag in INPUT voltage during a load step means the "
   "problem is upstream of the PSUs entirely.",
   p(8), [('octoserver_psu_input_voltage_volts{host=~"$host"}',
           "{{host}} {{psu}} Vin"),
          ('ipmi_current_amperes{host=~"$host"}', "{{host}} {{name}} A")],
   overrides=[axis_right(r".* A$", "amp"), unit_for(r".*Vin$", "volt")],
   calcs=("last", "min"))

# --------------------------------------------------------- junction thermals
row("Junction & thermals - newest signal, verify before trusting")
p = band(9)
ts("Junction (hotspot) temperature",
   "From BAR0 MMIO - no NVIDIA interface reports this. Only emitted when the "
   "reading passes the validity gate, so a GAP means rejected or stale, NOT "
   "cool. 95C warn, 100C service.",
   p(12), [('gpu_junction_temp_celsius{host=~"$host"}',
            "{{host}} {{pci_bus_id}}")], unit="celsius", width=2, fill=5,
   steps=GY, style="dashed")
ts("Junction - core delta",
   "Best long-term 'is this card degrading' metric. Both operands share one "
   "instant. At CONSTANT power a rising trend means thermal-interface "
   "degradation (pump-out, dried paste). Compare a card against its own "
   "history, not against its siblings.",
   p(12), [('gpu_junction_core_delta_celsius{host=~"$host"}',
            "{{host}} {{pci_bus_id}}")], unit="celsius", width=2, fill=5,
   steps=[{"color": "green", "value": None}, {"color": "yellow", "value": 25}],
   style="dashed", calcs=("last", "mean", "max"))

p = band(8)
ts("Core temperature (two independent sources)",
   "gputemps vs NVML. These must agree within ~3C - that agreement is what "
   "proves junction readings are attributed to the right card. Divergence "
   "invalidates the junction panels above.",
   p(8), [('gpu_core_temp_celsius{host=~"$host"}',
           "{{host}} {{pci_bus_id}} {{source}}")], unit="celsius")
ts("GDDR max (two independent BAR readers)",
   "gddr6_* and gpu_vram_* are separate implementations reading the same "
   "sensors. They agree within 0-2C, which is the strongest evidence that the "
   "BAR mapping and 5090 profile are correct.",
   p(8), [('gddr6_vram_temp_max_celsius{host=~"$host"}',
           "{{host}} {{pci_bus_id}} reader1"),
          ('gpu_vram_temp_max_celsius{host=~"$host"}',
           "{{host}} {{pci_bus_id}} reader2")], unit="celsius")
ts("Thermal margin (T.Limit) - LOWER IS HOTTER",
   "NVIDIA's official margin. Measured to be exactly 90 - core on these "
   "cards, so it adds nothing over core temperature - but it is the designated "
   "fallback if junction ever proves untrustworthy. Alert on LOW values.",
   p(8), [('gpu_thermal_margin_celsius{host=~"$host"}',
           "{{host}} {{pci_bus_id}}")], unit="celsius", calcs=("last", "min"))

p = band(8)
ts("Per-module GDDR temperature (all modules)",
   "8 modules per card. One module consistently hotter than its siblings is a "
   "localised cooling problem (pad contact) rather than a whole-card issue.",
   p(24), [('gddr6_vram_module_temp_celsius{host=~"$host"}',
            "{{host}} {{pci_bus_id}} m{{module}}")], unit="celsius",
   hide_legend=True, calcs=())

# --------------------------------------------------------- failure signals
row("Failure signals")
p = band(8)
ts("XID errors",
   "79 = 'GPU has fallen off the bus'. 31 = memory/illegal address. 154 = "
   "recovery action. Each occurrence is also annotated across every panel on "
   "this dashboard.",
   p(12), [('DCGM_FI_DEV_XID_ERRORS{host=~"$host",gpu=~"$gpu"}',
            "{{host}} gpu{{gpu}} {{err_msg}}")], fill=25, width=2,
   stepped=True, steps=RED1, color_thresholds=True, calcs=("max",))
ts("PCIe replay counter (5m increase)",
   "RULED OUT as a cause: zero replays on every GPU for 70 days, and zero AER "
   "through 40+ minutes of maximum DMA. Kept because any non-zero value here "
   "would overturn that conclusion.",
   p(12), [('increase(DCGM_FI_DEV_PCIE_REPLAY_COUNTER{host=~"$host",gpu=~"$gpu"}[5m])',
            "{{host}} gpu{{gpu}}")], fill=15, steps=RED1,
   color_thresholds=True, calcs=("max",))

p = band(8)
ts("Active throttle reasons",
   "HW-THERMAL / HW-SLOWDOWN firing at only 77-82C core is the anomaly that "
   "motivated the junction work. KEY CHECK: if HW-THERMAL asserts while "
   "junction reads ~80C, the junction offsets are WRONG.",
   p(12), [('DCGM_FI_DEV_CLOCKS_THROTTLE_REASON{host=~"$host",gpu=~"$gpu",reason!~"GpuIdle|ApplicationsClocksSetting"} > 0',
            "{{host}} gpu{{gpu}} {{reason}}")], fill=25, width=2,
   stepped=True, calcs=("max",))
ts("SM & memory clocks",
   "A clock collapse without a throttle reason, or clocks pinned low after an "
   "event, indicates the card never recovered.",
   p(12), [('DCGM_FI_DEV_SM_CLOCK{host=~"$host",gpu=~"$gpu"}',
            "{{host}} gpu{{gpu}} SM"),
           ('DCGM_FI_DEV_MEM_CLOCK{host=~"$host",gpu=~"$gpu"}',
            "{{host}} gpu{{gpu}} MEM")], unit="rothz",
   calcs=("last", "min"))

# ------------------------------------------------------------ load context
row("Load context - what the cards were actually doing")
p = band(8)
ts("Utilisation & engine activity",
   "There were NO idle deaths. Establishing what the card was doing at the "
   "moment of death is essential context for any thermal or power claim.",
   p(8), [('DCGM_FI_DEV_GPU_UTIL{host=~"$host",gpu=~"$gpu"}',
           "{{host}} gpu{{gpu}} util"),
          ('DCGM_FI_PROF_PIPE_TENSOR_ACTIVE{host=~"$host",gpu=~"$gpu"} * 100',
           "{{host}} gpu{{gpu}} tensor"),
          ('DCGM_FI_PROF_DRAM_ACTIVE{host=~"$host",gpu=~"$gpu"} * 100',
           "{{host}} gpu{{gpu}} dram")], unit="percent", maxv=100)
ts("PCIe throughput",
   "Heavy sustained DMA is the condition the C-Payne stress tool reproduces. "
   "Useful for correlating a death with bus activity.",
   p(8), [('DCGM_FI_PROF_PCIE_TX_BYTES{host=~"$host",gpu=~"$gpu"}',
           "{{host}} gpu{{gpu}} TX"),
          ('DCGM_FI_PROF_PCIE_RX_BYTES{host=~"$host",gpu=~"$gpu"}',
           "{{host}} gpu{{gpu}} RX")], unit="Bps")
ts("Framebuffer used",
   "A large resident footprint means the GDDR modules are genuinely being "
   "exercised, which matters when reading the VRAM temperatures above.",
   p(8), [('DCGM_FI_DEV_FB_USED{host=~"$host",gpu=~"$gpu"} * 1024 * 1024',
           "{{host}} gpu{{gpu}}")], unit="bytes", fill=8)

# ------------------------------------------------------ chassis environment
row("Chassis environment")
p = band(8)
ts("Chassis & board temperatures",
   "'Card Side Temp' is the closest thing to a GPU inlet reading. Ambient was "
   "RULED OUT as a driver of death timing, but inlet temperature is still "
   "required context for any junction service claim.",
   p(12), [('ipmi_temperature_celsius{host=~"$host",name=~"CPU Temp|MB Temp|Card Side Temp|Onboard LAN Temp|TEMP_TR1"}',
            "{{host}} {{name}}")], unit="celsius")
ts("Chassis fan speeds",
   "Driven by gpu-fan-control (20% floor, 50% ceiling over 70-85C core). A fan "
   "stuck high often means it is tracking a DEAD GPU's frozen temperature - "
   "that exact bug has happened here.",
   p(12), [('ipmi_fan_speed_rpm{host=~"$host"}', "{{host}} {{name}}")],
   unit="rotrpm", calcs=("last", "min", "max"))

p = band(8)
ts("DIMM temperatures",
   "Zhen has an outstanding 8th-DIMM issue. A MISSING sensor here is as "
   "informative as a hot one.",
   p(12), [('ipmi_temperature_celsius{host=~"$host",name=~"TEMP_CPU1_DDR4.*"}',
            "{{host}} {{name}}")], unit="celsius")
ts("PSU temperature & fans",
   "A PSU running hot, or with a stalled fan, can trip protection under a load "
   "step without ever reporting a hard fault.",
   p(12), [('octoserver_psu_temperature_celsius{host=~"$host"}',
            "{{host}} {{psu}} temp"),
           ('ipmi_temperature_celsius{host=~"$host",name=~"PSU. TEMP"}',
            "{{host}} {{name}}"),
           ('octoserver_psu_fan_speed_rpm{host=~"$host"}',
            "{{host}} {{psu}} fan")],
   overrides=[axis_right(r".* fan$", "rotrpm"),
              unit_for(r".*(temp|TEMP)$", "celsius")])

# ------------------------------------------------- host & monitoring health
row("Host & monitoring health")
p = band(8)
ts("Host load & memory",
   "Rules out the host itself stalling as the cause of an apparent GPU "
   "disappearance.",
   p(8), [('node_load1{host=~"$host"}', "{{host}} load1"),
          ('node_memory_MemAvailable_bytes{host=~"$host"} / 1024 / 1024 / 1024',
           "{{host}} mem avail GiB")],
   overrides=[axis_right(r".*GiB$")], calcs=("last", "min"))
ts("BMC SEL log count",
   "The BMC event log records hardware faults the OS never sees. A step here "
   "at the time of a death is a strong lead - Juno's full SEL is an "
   "outstanding action, and a full log stops recording new events.",
   p(8), [('ipmi_sel_logs_count{host=~"$host"}', "{{host}} SEL entries"),
          ('ipmi_sel_free_space_bytes{host=~"$host"}', "{{host}} SEL free bytes")],
   width=2, overrides=[axis_right(r".*free bytes$", "bytes")])
ts("Monitoring health - READ THIS BEFORE TRUSTING JUNCTION",
   "junction_temp_valid 0, map_trusted 0, reader_up 0, or a rising "
   "parse_errors all mean the junction panels above are not reporting "
   "reality. The 5090 profile in the upstream tool is EXPERIMENTAL and was "
   "never maintainer-tested on a 5090.",
   p(8), [('gpu_junction_temp_valid{host=~"$host"}',
           "{{host}} {{pci_bus_id}} valid"),
          ('min by (host) (gpu_junction_map_trusted{host=~"$host"})',
           "{{host}} map trusted"),
          ('min by (host) (gpu_junction_reader_up{host=~"$host"})',
           "{{host}} readers up"),
          ('sum by (host) (gpu_junction_parse_errors_total{host=~"$host"})',
           "{{host}} parse errors"),
          ('time() - max by (host) (gddr6_vram_merge_timestamp_seconds{host=~"$host"})',
           "{{host}} exporter age s")],
   overrides=[axis_right(r".*age s$", "s")], calcs=("last", "min"))

p = band(9)
panels.append({
    "type": "table",
    "title": "GPU inventory - identify a card across hosts and slots",
    "description": "Card 349f61c8 accounts for 14 of 27 deaths across two "
                   "hosts and four slots, so always track a card by UUID, "
                   "never by slot.",
    "id": nid(), "gridPos": p(24), "datasource": DS,
    "targets": [{"refId": "A", "expr": 'DCGM_FI_DEV_POWER_USAGE{host=~"$host"}',
                 "format": "table", "instant": True, "legendFormat": ""}],
    "transformations": [{"id": "organize", "options": {
        "excludeByName": {"Time": True, "Value": True, "job": True,
                          "service": True, "__name__": True, "instance": True,
                          "Hostname": True, "device": True},
        "renameByName": {"host": "Host", "gpu": "Idx",
                         "pci_bus_id": "PCI slot", "UUID": "GPU UUID",
                         "modelName": "Model",
                         "DCGM_FI_DRIVER_VERSION": "Driver"}}}],
    "options": {"showHeader": True}})

dash = {
    "title": "GPU Dropout Diagnostics - Juno & Zhen",
    "uid": "gpu-dropout-diag",
    "tags": ["gpu", "dropout", "junction", "5090"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 1,
    "refresh": "30s",
    "editable": True,
    "graphTooltip": 1,
    "time": {"from": "now-6h", "to": "now"},
    "description": (
        "Every signal that could explain the RTX 5090 Xid-79 dropouts on Juno "
        "and Zhen. Established mechanism: deaths ride host power TRANSIENTS "
        "(400-1900W steps) - not thermals, and not PCIe signal integrity "
        "(zero AER and zero PCIe replays in 70 days). Junction temperature is "
        "the newest and least-proven signal: check the Monitoring health row "
        "before trusting it. RESOLUTION: Prometheus scrapes at 60s, so nothing "
        "here can show sub-minute behaviour; the 5Hz telemetry ring and "
        "incident bundles on each host are the only sub-second record."),
    "annotations": {"list": [
        {"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"},
         "enable": True, "hide": True, "name": "Annotations & Alerts",
         "iconColor": "rgba(0, 211, 255, 1)", "type": "dashboard"},
        {"datasource": DS, "enable": True, "name": "XID error",
         "expr": 'DCGM_FI_DEV_XID_ERRORS{host=~"$host"} > 0',
         "iconColor": "red", "titleFormat": "XID {{err_code}} on {{host}} gpu{{gpu}}",
         "textFormat": "{{err_msg}} ({{pci_bus_id}})", "tagKeys": "host,gpu"},
        {"datasource": DS, "enable": True, "name": "Host reboot",
         "expr": 'changes(node_boot_time_seconds{host=~"$host"}[10m]) > 0',
         "iconColor": "orange", "titleFormat": "reboot: {{host}}",
         "tagKeys": "host"}]},
    "templating": {"list": [
        {"name": "host", "label": "Host", "type": "query", "datasource": DS,
         "query": "label_values(DCGM_FI_DEV_GPU_TEMP, host)", "refresh": 1,
         "multi": True, "includeAll": True, "sort": 1,
         "current": {"text": ["All"], "value": ["$__all"]}},
        {"name": "gpu", "label": "GPU index", "type": "query", "datasource": DS,
         "query": 'label_values(DCGM_FI_DEV_GPU_TEMP{host=~"$host"}, gpu)',
         "refresh": 2, "multi": True, "includeAll": True, "sort": 1,
         "current": {"text": ["All"], "value": ["$__all"]}}]},
    "panels": panels,
}
print(json.dumps(dash, indent=2))
