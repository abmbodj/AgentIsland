#!/usr/bin/env python3
"""Summarize exported Instruments tables without publishing trace environments.

Export with xctrace export --input run.trace --xpath
'/trace-toc/run[@number="1"]/data/table[@schema="hitches"]'
--output tables.xml; then run this script on tables.xml.
Export each schema separately: multi-table xctrace exports can omit schemas.
Frame lifetime includes pipeline latency and is NOT a frame budget measurement.
"""
import argparse, collections, json, xml.etree.ElementTree as E

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('xml');a=p.parse_args()
    root=E.parse(a.xml).getroot()
    ids={e.attrib['id']:e for e in root.iter() if 'id' in e.attrib}
    def resolve(e):
        return ids.get(e.attrib.get('ref'),e)
    def value(e):
        e=resolve(e)
        return e.attrib.get('fmt') or e.text or ''
    def number(e):
        e=resolve(e)
        try:return float(e.text or 0)
        except ValueError:return 0
    result={}
    for node in root.findall('node'):
        schema=node.find('schema')
        if schema is None:
            raise SystemExit("Missing schema: export one table per XML file so every table is identified.")
        name=schema.attrib['name'];cols=[c.findtext('mnemonic') for c in schema.findall('col')]
        rows=[{k:v for k,v in zip(cols,list(row))} for row in node.findall('row')]
        item={'rows':len(rows),'columns':cols}
        durations=sorted(number(r['duration'])/1e6 for r in rows if 'duration'in r)
        if durations:
            item.update(durationMsTotal=round(sum(durations),3),durationMsMax=round(max(durations),3),durationMsP95=round(durations[min(len(durations)-1,int(len(durations)*.95))],3),over16_7ms=sum(d>16.7 for d in durations))
        if name=='hitches':
            item['byProcess']=dict(collections.Counter(value(r['process']) for r in rows if 'process'in r))
            item['causes']=dict(collections.Counter(value(r['narrative-description']) for r in rows if 'narrative-description'in r))
        if name=='time-profile':
            stacks=collections.Counter()
            for r in rows:
                sample_frames=set()
                for k,v in r.items():
                    if 'backtrace'in k or 'stack'in k:
                        e=resolve(v)
                        for frame in e.iter('frame'):
                            label=resolve(frame).attrib.get('name') or value(frame)
                            if label:sample_frames.add(label)
                stacks.update(sample_frames)
            item['topStackFrames']=stacks.most_common(25)
        result[name]=item
    if not result:
        raise SystemExit("No tables exported: verify the requested Instruments schema and XPath.")
    print(json.dumps(result,indent=2))

if __name__=='__main__':main()
