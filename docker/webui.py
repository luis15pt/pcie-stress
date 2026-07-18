#!/usr/bin/env python3
"""Flask web UI for the pcie-stress suite (default port 8080).

Live GPU cards (util/temp/power/clock/fan/VRAM + throttle badges + per-run AER
delta), Chart.js history graphs, non-GPU AER table, and the EVENT feed — all
backed by the same Tracker that feeds the terminal monitor and logs.
Usage: webui.py [port]
"""
import os
import sys
import threading
import time
from collections import deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aer_watch as aw  # noqa: E402

from flask import Flask, jsonify, render_template_string, request  # noqa: E402

app = Flask(__name__, static_folder="static")


def gpu_names() -> dict[str, str]:
    import subprocess
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=pci.bus_id,name",
                              "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=10).stdout
    except OSError:
        return {}
    names = {}
    for line in out.splitlines():
        bus, _, name = line.partition(",")
        names[bus.strip().lower().replace("00000000:", "0000:")] = name.strip()
    return names


class Sampler(threading.Thread):
    def __init__(self, interval: float = 2.0):
        super().__init__(daemon=True)
        self.interval = interval
        self.base = aw.snapshot()
        self.trk = aw.Tracker(self.base)
        self.samples: deque = deque(maxlen=1800)  # ~1h at 2s
        self.seq = 0
        self.names = gpu_names()
        self.started = time.time()
        self.lock = threading.Lock()

    def run(self):
        while True:
            try:
                self.tick()
            except Exception:
                pass
            time.sleep(self.interval)

    def tick(self):
        self.trk.tick(self.interval)
        tel = self.trk.tel
        g = {}
        for dev, port in aw.gpus():
            t = tel.get(dev.name)
            if t:
                flags = sorted(aw.throttle_flags(int(t["reasons"])) - {"sw-power-cap"})
                g[dev.name] = [t["util"], t["memutil"], t["temp"],
                               t["fan"] if t["fan"] is not None else -1,
                               t["power"], t["plimit"], t["clk"], t["clk_max"],
                               t["mem_used"], t["mem_total"],
                               self.trk.gpu_run_delta(dev, port),
                               aw.link_str(dev), flags,
                               t["vram"] if t["vram"] is not None else -1]
            else:
                g[dev.name] = None  # dropped off the bus
        for bdf in self.trk.gone:
            g.setdefault(bdf, None)
        others = []
        cur = aw.snapshot()
        gpu_bdfs = {p.name for pair in aw.gpus() for p in pair}
        for bdf in sorted(cur):
            c = cur[bdf]
            if c and bdf not in gpu_bdfs:
                others.append([bdf, c, c - self.base.get(bdf, 0), aw.lspci_name(bdf)[:60]])
        with self.lock:
            self.seq += 1
            self.samples.append({"i": self.seq, "t": time.time(), "g": g, "o": others})

    def state(self, since: int) -> dict:
        with self.lock:
            return {
                "samples": [s for s in self.samples if s["i"] > since],
                "events": list(self.trk.events),
                "names": self.names,
                "started": self.started,
            }


sampler = Sampler()

PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8"><title>pcie-stress monitor</title>
<script src="/static/chart.umd.js"></script>
<style>
:root{--bg:#0d1117;--card:#161b22;--border:#30363d;--fg:#e6edf3;--dim:#8b949e;
  --green:#3fb950;--red:#f85149;--yellow:#d29922;--blue:#58a6ff;--cyan:#39c5cf;--purple:#bc8cff}
*{box-sizing:border-box;margin:0}
body{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,'Segoe UI',Roboto,sans-serif;padding:16px}
h1{font-size:18px;font-weight:600}
#topbar{display:flex;align-items:center;gap:16px;margin-bottom:14px;flex-wrap:wrap}
#status{padding:4px 14px;border-radius:16px;font-weight:600}
#status.ok{background:#122117;color:var(--green);border:1px solid #1f4428}
#status.bad{background:#25171a;color:var(--red);border:1px solid #5c2326;animation:blink 1s infinite alternate}
@keyframes blink{from{opacity:1}to{opacity:.55}}
#meta{color:var(--dim);font-size:12.5px}
#grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(430px,1fr));gap:14px}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:12px 14px}
.card.dead{border-color:var(--red);box-shadow:0 0 12px #f8514933}
.chead{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:6px;gap:8px;flex-wrap:wrap}
.cname{font-weight:600}
.cbdf{color:var(--dim);font-size:12px}
.badge{font-size:11px;padding:1px 8px;border-radius:10px;border:1px solid var(--border);color:var(--dim)}
.badge.link{color:var(--blue);border-color:#1f3a5f}
.badge.thr{color:var(--yellow);border-color:#5c4a1e}
.badge.dead{color:var(--red);border-color:#5c2326;font-weight:700}
.stats{display:grid;grid-template-columns:repeat(6,1fr);gap:6px;margin:8px 0}
.stat b{display:block;font-size:17px;font-weight:600}
.stat span{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.04em}
.stat.hot b{color:var(--red)} .stat.warm b{color:var(--yellow)} .stat.err b{color:var(--red)}
.chartbox{height:150px}
.panel{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:12px 14px;margin-top:14px}
.panel h2{font-size:13px;color:var(--dim);text-transform:uppercase;letter-spacing:.05em;margin-bottom:8px}
#events{max-height:260px;overflow-y:auto;font:12px/1.6 ui-monospace,Menlo,monospace;white-space:pre-wrap}
#events .ev{color:var(--yellow)} #events .kdrop{color:var(--red);font-weight:700}
table{border-collapse:collapse;width:100%;font-size:13px}
td,th{padding:4px 10px;text-align:left;border-bottom:1px solid var(--border)}
th{color:var(--dim);font-weight:500;font-size:11.5px;text-transform:uppercase}
.delta-bad{color:var(--red);font-weight:600}.delta-ok{color:var(--green)}
</style></head><body>
<div id="topbar">
  <h1>pcie-stress</h1>
  <div id="status" class="ok">initialising…</div>
  <div id="meta"></div>
</div>
<div id="grid"></div>
<div class="panel"><h2>Non-GPU devices with AER errors</h2>
  <table><thead><tr><th>device</th><th>total</th><th>this run</th><th>what</th></tr></thead>
  <tbody id="others"><tr><td colspan="4" style="color:var(--dim)">none</td></tr></tbody></table></div>
<div class="panel"><h2>Events</h2><div id="events">(none yet)</div></div>
<script>
const HIST=900, hist={}, charts={}, cards={};
let lastSeq=0, names={}, started=0;
const dsStyle=(label,color,dash)=>({label,borderColor:color,borderWidth:1.6,pointRadius:0,
  tension:.25,borderDash:dash||[],data:[]});
function mkCard(bdf){
  const el=document.createElement('div'); el.className='card'; el.id='c_'+bdf;
  el.innerHTML=`<div class="chead"><div><span class="cname">${names[bdf]||'GPU'}</span>
      <span class="cbdf"> ${bdf}</span></div><div class="badges"></div></div>
    <div class="stats"></div><div class="chartbox"><canvas></canvas></div>`;
  document.getElementById('grid').appendChild(el);
  cards[bdf]=el;
  if(window.Chart){
    charts[bdf]=new Chart(el.querySelector('canvas'),{type:'line',
      data:{labels:[],datasets:[dsStyle('util %','#3fb950'),dsStyle('mem util %','#39c5cf'),
        dsStyle('temp °C','#f85149'),dsStyle('power %','#d29922'),dsStyle('clock %','#58a6ff',[4,3])]},
      options:{animation:false,responsive:true,maintainAspectRatio:false,
        interaction:{mode:'index',intersect:false},
        scales:{x:{ticks:{color:'#8b949e',maxTicksLimit:6,font:{size:10}},grid:{color:'#21262d'}},
                y:{min:0,max:110,ticks:{color:'#8b949e',font:{size:10}},grid:{color:'#21262d'}}},
        plugins:{legend:{labels:{color:'#8b949e',boxWidth:14,font:{size:10}}}}}});
  }
}
function stat(label,val,cls){return `<div class="stat ${cls||''}"><b>${val}</b><span>${label}</span></div>`}
function render(bdf,v,ts){
  if(!cards[bdf]) mkCard(bdf);
  const el=cards[bdf], badges=el.querySelector('.badges'), stats=el.querySelector('.stats');
  if(v===null){
    el.classList.add('dead');
    badges.innerHTML='<span class="badge dead">DROPPED OFF BUS</span>';
    stats.innerHTML=stat('status','LOST','err');
    return;
  }
  el.classList.remove('dead');
  const [util,mu,temp,fan,pw,pl,clk,clkm,vu,vt,aer,link,thr,vtemp]=v;
  badges.innerHTML=`<span class="badge link">${link}</span>`+
    thr.map(t=>`<span class="badge thr">${t}</span>`).join('');
  stats.innerHTML=
    stat('util',util.toFixed(0)+'%')+
    stat('temp',temp.toFixed(0)+'°C',temp>=86?'hot':temp>=75?'warm':'')+
    stat('power',pw.toFixed(0)+'W / '+pl.toFixed(0))+
    stat('sm clk',clk.toFixed(0)+'M')+
    stat('vram',(vu/1024).toFixed(1)+'/'+(vt/1024).toFixed(0)+'G')+
    stat('aer run',(aer>0?'+':'')+aer,aer>0?'err':'');
  if(charts[bdf]){
    const c=charts[bdf], t=new Date(ts*1000).toTimeString().slice(0,8);
    c.data.labels.push(t);
    const vals=[util,mu,temp,pl?pw/pl*100:0,clkm?clk/clkm*100:0];
    c.data.datasets.forEach((d,i)=>d.data.push(vals[i]));
    if(c.data.labels.length>HIST){c.data.labels.shift();c.data.datasets.forEach(d=>d.data.shift());}
  }
}
async function poll(){
  try{
    const r=await fetch('/api/state?since='+lastSeq), j=await r.json();
    names=j.names; started=j.started;
    let latest=null;
    for(const s of j.samples){lastSeq=s.i; latest=s;
      for(const[b,v] of Object.entries(s.g)) render(b,v,s.t);}
    for(const b in charts) charts[b].update('none');
    if(latest){
      const dead=Object.values(latest.g).some(v=>v===null);
      const st=document.getElementById('status');
      st.className=dead?'bad':'ok';
      st.textContent=dead?'GPU DROPPED OFF BUS':'all GPUs responding';
      const up=Math.floor((Date.now()/1000-started));
      document.getElementById('meta').textContent=
        `monitoring for ${Math.floor(up/3600)}h${String(Math.floor(up%3600/60)).padStart(2,'0')}m — ${Object.keys(latest.g).length} GPUs — updated ${new Date(latest.t*1000).toLocaleTimeString()}`;
      const ob=document.getElementById('others');
      ob.innerHTML=latest.o.length?latest.o.map(([b,c,d,n])=>
        `<tr><td>${b}</td><td>${c}</td><td class="${d>0?'delta-bad':'delta-ok'}">+${d}</td><td style="color:var(--dim)">${n}</td></tr>`).join('')
        :'<tr><td colspan="4" style="color:var(--green)">none — clean</td></tr>';
    }
    const ev=document.getElementById('events');
    if(j.events.length){
      ev.innerHTML=j.events.slice().reverse().map(e=>
        `<div class="${/DISAPPEARED|fallen off|Xid/.test(e)?'kdrop':'ev'}">${e.replace(/</g,'&lt;')}</div>`).join('');
    }
  }catch(e){ document.getElementById('status').className='bad';
    document.getElementById('status').textContent='monitor unreachable'; }
}
poll(); setInterval(poll,2000);
</script></body></html>"""


@app.route("/")
def index():
    return render_template_string(PAGE)


@app.route("/api/state")
def state():
    since = request.args.get("since", 0, type=int)
    return jsonify(sampler.state(since))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    sampler.start()
    app.run(host="0.0.0.0", port=port, threaded=True)
