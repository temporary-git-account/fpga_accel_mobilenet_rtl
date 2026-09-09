#!/usr/bin/env python3
"""Build a self-contained HTML reading copy; needs markdown-it-py only to rebuild."""
from pathlib import Path
from html import escape
import re
from markdown_it import MarkdownIt
ROOT=Path(__file__).resolve().parents[1]
md=(ROOT/'DESIGN.md').read_text()
def svgbox(x,y,w,h,title,sub,fill='#eaf2f8'):
 return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}" stroke="#85a8c3"/><text x="{x+w/2}" y="{y+25}" text-anchor="middle" font-size="14" font-weight="600">{escape(title)}</text><text x="{x+w/2}" y="{y+47}" text-anchor="middle" font-size="11" fill="#536e83">{escape(sub)}</text>'
def line(x1,y1,x2,y2):return f'<path d="M{x1},{y1} L{x2},{y2}" fill="none" stroke="#376f98" stroke-width="2" marker-end="url(#arrow)"/>'
svg='<svg viewBox="0 0 770 425" role="img" aria-labelledby="arch-title" xmlns="http://www.w3.org/2000/svg"><title id="arch-title">Layer control feeds banks, vector MAC and requantizer; shared memory port connects through a cache to DDR.</title><defs><marker id="arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8" fill="#376f98"/></marker></defs><g font-family="system-ui" fill="#173a53">'
svg+=svgbox(15,20,220,66,'AXI-Lite control','descriptor • START • DONE • ACK')+svgbox(270,20,230,66,'Layer engine','coordinates • schedule • bounds')+line(235,53,270,53)
svg+=svgbox(270,125,230,66,'On-chip tile banks','4 activation banks • 8 weight banks')+line(385,86,385,125)
svg+=svgbox(270,230,230,66,'32-lane vector MAC','4 pixels × 8 output channels')+line(385,191,385,230)
svg+=svgbox(270,335,230,66,'One requantizer','serialize sums • 8 registered stages')+line(385,296,385,335)
svg+=svgbox(535,125,220,66,'128-byte read cache','8 lines • 16 bytes each')+svgbox(535,230,220,66,'AXI4 memory master','64-bit • one outstanding request')+svgbox(535,335,220,66,'DDR tensors','weights • input • output','#edf5f0')+line(645,191,645,230)+line(645,296,645,335)
svg+='<path d="M500,53 L645,53 L645,125" fill="none" stroke="#376f98" stroke-width="2" marker-end="url(#arrow)"/><path d="M500,368 L515,368 L515,263 L535,263" fill="none" stroke="#376f98" stroke-width="2" marker-end="url(#arrow)"/><text x="532" y="41" font-size="10">load requests</text><text x="513" y="314" font-size="10" transform="rotate(-90 513 314)">output writes</text>'
svg+='</g></svg>'
arch='<figure>'+svg+'<figcaption>Figure 1. Production blocks. The numerical testbench supplies descriptors and DDR contents; activation/weight fetch, convolution and output stores are driven by the RTL.</figcaption></figure>'
quant='''<section class="demo" aria-label="Exact integer requantization calculator"><h4>Try the integer datapath</h4><p>Uses exact integer arithmetic, including the two different signed tie rules. This is an equation calculator, not a cycle simulator.</p><div class="fields">'''
for key,label,val in [('qacc','Accumulator',125),('qbias','Bias',3),('qmult','Q31 multiplier',1073741824),('qshift','Right shift',2),('qzero','Output zero point',-5),('qlo','Activation minimum',-128),('qhi','Activation maximum',127)]:quant+=f'<label>{label}<input id="{key}" type="number" step="1" value="{val}"></label>'
quant+='</div><button id="qtie">Negative tie example</button> <button id="qreset">Reset worked example</button><p></p><output id="qout" aria-live="polite">Worked example output: 11. Enable JavaScript to edit the inputs.</output></section>'
tile='''<section class="demo"><h4>Explore a 4×8 tile</h4><p>Select a lane or change valid pixel/channel counts to see tail masking and operand sharing.</p><div class="fields"><label>Valid pixels<input id="tpixels" type="number" min="1" max="4" value="4"></label><label>Valid channels<input id="tchannels" type="number" min="1" max="8" value="8"></label><label>Operation<select id="tmode"><option value="regular">Regular convolution</option><option value="dw">Depthwise convolution</option></select></label></div><div class="tile">'''
for i in range(32):tile+=f'<button class="lane" id="lane{i}" aria-pressed="false">p{i//8}, c{i%8}</button>'
tile+='</div><output id="tout" aria-live="polite">32 independent output lanes. Regular convolution broadcasts a pixel activation across eight channels.</output></section>'
fsm='<figure><div class="flow">'+''.join(f'<span>{x}</span>'+('<b>→</b>' if i<7 else '') for i,x in enumerate(['Capture / validate','Load weights + parameters','Load four pixels','Read / feed MAC','Drain sums','Requantize 32 lanes','Write valid outputs','Next tile / group']))+'</div><figcaption>Figure 2. Repeated tile schedule. Loading, computing and writing are largely serialized; MREQ/MWAIT are shared substeps of the memory phases.</figcaption></figure>'
perf='''<section class="demo"><h4>Arithmetic ceiling versus useful duty factor</h4><p>A thought experiment for 567,718,400 MACs. The accepted frequency is 166.667 MHz; changing the field does not establish timing closure at another frequency.</p><div class="fields"><label>Core frequency (MHz)<input id="pfreq" type="number" min="1" max="500" value="166.667" step="0.001"></label><label>Cycles per accepted term<select id="pinterval"><option value="2">2 — current bank schedule</option><option value="1">1 — hypothetical continuous feed</option></select></label><label>Assumed feed duty (%)<input id="pduty" type="number" min="0.1" max="100" value="100" step="0.1"></label></div><output id="pout" aria-live="polite">At 166.667 MHz and two cycles/term, the feed-only arithmetic estimate is about 212.9 ms, excluding memory and control overhead.</output></section>'''
for key,value in [('ARCH_DIAGRAM',arch),('QUANT_DEMO',quant),('TILE_DEMO',tile),('FSM_DIAGRAM',fsm),('PERFORMANCE_DEMO',perf)]:md=md.replace('<!-- '+key+' -->',value)
engine=MarkdownIt('commonmark',{'html':True}).enable('table');body=engine.render(md)
toc=[]
def heading(match):
 level,text=match.groups();plain=re.sub('<[^>]+>','',text);slug=re.sub('[^a-z0-9]+','-',plain.lower()).strip('-');toc.append((level,slug,plain));return f'<h{level} id="{slug}">{text}</h{level}>'
body=re.sub(r'<h([23])>(.*?)</h\1>',heading,body)
body=body.replace('<table>','<div class="table-scroll"><table>').replace('</table>','</table></div>')
chapter=body.index('id="14-the-complete-operator-inventory"');pos=body.index('<div class="table-scroll">',chapter)
body=body[:pos]+body[pos:].replace('<div class="table-scroll">','<div class="filter-row">Filter the operator inventory <input id="layer-search" placeholder="e.g. DEPTHWISE, RTL, 512" aria-label="Filter operators"></div><div class="table-scroll" id="layer-table">',1)
nav=''.join(f'<a class="{"sub" if level=="3" else "chapter"}" href="#{slug}">{escape(title)}</a>' for level,slug,title in toc)
css=(ROOT/'docs/style.css').read_text();js=(ROOT/'docs/interactive.js').read_text()
html=f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="A detailed RTL study guide for a 32-lane integer MobileNet convolution accelerator."><title>MobileNet RTL — From Integer Math to Hardware</title><style>{css}</style></head><body><div id="progress" class="progress"></div><nav aria-label="Study guide contents"><div class="brand">MOBILENET / RTL</div><div class="statusline">Arithmetic → scheduler → memory → gates</div><input id="toc-search" placeholder="Find a chapter…" aria-label="Filter contents"><div class="toc">{nav}</div><div class="statusline">Offline edition · September 2026</div></nav><main class="wrap"><div class="links"><a href="README.md">README</a><a href="GUIDE.md">Run guide</a><a href="DESIGN.md">Markdown source</a><button id="print">Print / save PDF</button></div><span class="tag">32 MAC LANES · INT8 · ZYNQ-7010</span>{body}<footer>Self-contained reading edition. No network access, remote fonts or external scripts are required. Regenerate with docs/render_guide.py after editing DESIGN.md.</footer></main><script>{js}</script></body></html>'''
(ROOT/'ARCHITECTURE-offline.html').write_text(html)
print('OFFLINE_GUIDE_RENDERED',len(html.encode()),'bytes',len(toc),'section anchors')
