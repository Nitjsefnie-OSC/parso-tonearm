import json,sys
src=json.load(open(sys.argv[1])); plan=json.load(open(sys.argv[2]))
facts={}
for t in plan['transitions']:
    for side in ('outgoingAnalysis','incomingAnalysis'):
        a=t[side]; facts.setdefault(a['track_id'],a)
        b=facts[a['track_id']]
        assert abs(b['bpm']-a['bpm'])<1e-9 and abs(b['duration']-a['duration'])<1e-9,(a['track_id'])
ids=[x for b in src['blends'] for x in b['tracks']]
assert len(ids)==36 and len(set(ids))==36 and set(ids)==set(facts), (len(ids),len(facts))
assert len(plan['transitions'])==30
def f(x): return repr(float(x))
out=[]
out.append("// GENERATED from the starter-blends-aac-v1 release assets (starter-blend-source.json,\n// starter-transition-candidates.json). Runtime data only: no model or planner runs in the app.\n// Do not edit by hand.\n")
out.append("import Foundation\n\nextension StarterBlendPack {")
out.append("    static let trackFacts: [StarterTrackFacts] = [")
rows=[]
for i in ids:
    a=facts[i]
    rows.append(f'        .init(id: "{i}", duration: {f(a["duration"])}, bpm: {f(a["bpm"])}, period: {f(a["period"])}, phase: {f(a["phase"])}, rmsDB: {f(a["rms_db"])}, drops: {json.dumps(a["drops"])}, exits: {json.dumps(a["exits"])})')
out.append(",\n".join(rows)+"\n    ]\n")
out.append("    static let edgePlans: [StarterEdgePlan] = [")
rows=[]
for t in plan['transitions']:
    p=t['plan']; o=t['outgoingAnalysis']; i=t['incomingAnalysis']
    style={'bass-swap':'.bassSwap','double-drop':'.doubleDrop','phrase-cut':'.phraseCut'}[p['style']]
    if p['style']=='phrase-cut':
        # Cut at an outgoing beat, incoming starts on its own beat: no overlap, unit gain.
        bs=o['beats'][p['outgoingCutBeat']]
        vals=dict(gain=1.0,ob=p['outgoingCutBeat'],ib=p['incomingStartBeat'],bs=bs,sw=bs,be=bs,off=bs-i['beats'][p['incomingStartBeat']]/p['tempo'])
    else:
        vals=dict(gain=p['incomingGain'],ob=p['outgoingSwapBeat'],ib=p['incomingSwapBeat'],bs=p['blendStartSeconds'],sw=p['swapSeconds'],be=p['blendEndSeconds'],off=p['incomingOffsetSeconds'])
    rows.append(f'        .init(blendID: "{t["blendID"]}", edge: {t["edge"]}, outgoing: "{t["outgoing"]}", incoming: "{t["incoming"]}", style: {style}, reason: {json.dumps(p["reason"])}, period: {f(o["period"])}, tempo: {f(p["tempo"])}, incomingGain: {f(vals["gain"])}, overlapBeats: {p["overlapBeats"]}, outgoingBeat: {vals["ob"]}, incomingBeat: {vals["ib"]}, blendStartSeconds: {f(vals["bs"])}, swapSeconds: {f(vals["sw"])}, blendEndSeconds: {f(vals["be"])}, incomingOffsetSeconds: {f(vals["off"])})')
out.append(",\n".join(rows)+"\n    ]\n}")
print("\n".join(out))
