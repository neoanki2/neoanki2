#!/usr/bin/env python3
"""Build the dated architecture atlas from SwiftSyntax output and SwiftPM manifests.
No application files are changed. See README.md for scope and regeneration.
"""
import ast, base64, collections, csv, gzip, hashlib, html, json, pathlib, re, subprocess, sys
ROOT=pathlib.Path(__file__).resolve().parents[3]
OUT=pathlib.Path(__file__).resolve().parent
raw=json.loads(pathlib.Path(sys.argv[1]).read_text())
tracked=subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode().split('\0')
tracked=[p for p in tracked if p and not p.startswith('docs/audits/architecture-2026-11-17/')]
modules=[]
for manifest,prefix in [(sys.argv[2],''),(sys.argv[3],'NeoAnkiCore/')]:
    for t in json.loads(pathlib.Path(manifest).read_text())['targets']:
        deps=[]
        for dep in t['dependencies']:
            value=next(iter(dep.values()))
            deps.append(value[0])
        path=prefix+t.get('path',('Tests/' if t['type']=='test' else 'Sources/')+t['name'])
        modules.append(dict(name=t['name'],path=path,kind=t['type'],dependencies=deps,evidence=prefix+'Package.swift'))
# Parse Xcode metadata as plist, rather than guessing target membership from folders.
for project in ['Xcode/NeoAnkiiOS.xcodeproj/project.pbxproj','Xcode/NeoAnkiMac.xcodeproj/project.pbxproj','UITests/NeoAnki2UITests.xcodeproj/project.pbxproj']:
    x=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(ROOT/project)]))['objects']
    group_parent={child:key for key,value in x.items() if value.get('isa')=='PBXGroup' for child in value.get('children',[])}
    project_base=(ROOT/project).parent.parent
    def resolve_ref(key):
        value=x[key]; path=value.get('path','')
        if value.get('sourceTree')=='SOURCE_ROOT': return (project_base/path).resolve()
        if key in group_parent:return (resolve_ref(group_parent[key])/path).resolve()
        return (project_base/path).resolve()
    for oid,obj in x.items():
        if obj.get('isa')!='PBXNativeTarget': continue
        paths=[]
        for phase in obj.get('buildPhases',[]):
            p=x[phase]
            if p.get('isa')!='PBXSourcesBuildPhase': continue
            for file_id in p.get('files',[]):
                f=x[x[file_id]['fileRef']]
                paths.append(str(resolve_ref(x[file_id]['fileRef']).relative_to(ROOT)))
        # Paths above are relative to Xcode/ or UITests/ project container parent.
        deps=[x[d]['productName'] for d in obj.get('packageProductDependencies',[])]
        deps += [x[x[d]['target']]['name'] for d in obj.get('dependencies',[]) if x[d].get('target') in x]
        if obj['name'] in ('NeoAnkiMac','NeoAnki2UITests'): deps.append('NeoAnki2')  # Explicit swift build shell phase.
        modules.append(dict(name=obj['name']+' [Xcode]',path='',files=paths,kind='test' if 'test' in obj.get('productType','').lower() else 'platform',dependencies=deps,evidence=project))
modules += [dict(name='Chrome Companion',path='Extensions/Chrome',kind='extension',dependencies=['NeoAnkiAPI'],evidence='Extensions/Chrome/manifest.json')]
# Fix cross-target Xcode dependencies to the unique Xcode name when not an SPM product.
for m in modules:
    m['dependencies']=[d if any(n['name']==d for n in modules) else d+' [Xcode]' if any(n['name']==d+' [Xcode]' for n in modules) else d for d in m['dependencies']]
by_module={m['name']:m for m in modules}
def module_for(path):
    exact=[m for m in modules if path in m.get('files',[])]
    if exact: return exact[0]['name']
    matched=[m for m in modules if m['path'] and (path==m['path'] or path.startswith(m['path']+'/'))]
    return max(matched,key=lambda m:len(m['path']))['name'] if matched else 'Supporting tools / configuration'
def production(path):
    return path.startswith(('Sources/','Platforms/iOS/','Platforms/iOSWidget/','NeoAnkiCore/Sources/','Tools/')) and '/NeoAnkiTestSupport/' not in path
D=raw['declarations']; by_id={d['id']:d for d in D}
for f in raw['files']:
    f['lines']=len((ROOT/f['path']).read_text().splitlines());f['module']=module_for(f['path']); f['production']=production(f['path'])
for d in D:
    d['module']=module_for(d['file']);d['production']=production(d['file'])
    d['local']=False; parent=d.get('parent'); names=[d['name']]
    while parent in by_id:
        p=by_id[parent]; names.insert(0,p['name'])
        if p['kind'] in ('function','initializer','deinitializer','subscript','variable'): d['local']=True
        parent=p.get('parent')
    d['qualifiedName']='.'.join(names)
# Preserve full syntax output losslessly, including tests and every occurrence.
with gzip.GzipFile(filename=str(OUT/'swift-inventory.json.gz'),mode='wb',mtime=0) as f:
    f.write(json.dumps(raw,separators=(',',':'),ensure_ascii=False).encode())
with (OUT/'symbols.tsv').open('w') as f:
    w=csv.writer(f,delimiter='\t'); w.writerow(['module','file','line','endLine','kind','qualifiedName','local','signature'])
    for d in D:w.writerow([d[k] for k in ['module','file','line','endLine','kind','qualifiedName','local','signature']])
# All tracked files, including assets, build/release tools, contracts, and tests.
with (OUT/'files.tsv').open('w') as f:
    w=csv.writer(f,delimiter='\t');w.writerow(['path','component','bytes','sha256'])
    for p in sorted(tracked):
        path=ROOT/p
        if path.is_file():
            data=path.read_bytes();w.writerow([p,module_for(p),len(data),hashlib.sha256(data).hexdigest()])
# Python function/class inventory (AST); JS and shell named declarations are a separate, explicit heuristic appendix.
aux=[]
for path in tracked:
    if path.endswith('.py'):
        try: tree=ast.parse((ROOT/path).read_text())
        except (SyntaxError,UnicodeDecodeError):continue
        def visit(node,parents=[]):
            for child in ast.iter_child_nodes(node):
                if isinstance(child,(ast.ClassDef,ast.FunctionDef,ast.AsyncFunctionDef)):
                    aux.append(dict(file=path,line=child.lineno,kind=type(child).__name__,name='.'.join(parents+[child.name]),method='Python AST'))
                    visit(child,parents+[child.name])
                else:visit(child,parents)
        visit(tree)
    elif path.endswith(('.js','.mjs','.sh')):
        for line,text in enumerate((ROOT/path).read_text().splitlines(),1):
            match=re.match(r'^\s*(?:export\s+)?(?:async\s+)?(?:function|class)\s+([\w$]+)',text) if not path.endswith('.sh') else re.match(r'^\s*(?:function\s+)?([\w_]+)\s*\(\)\s*\{',text)
            if match:aux.append(dict(file=path,line=line,kind='named declaration',name=match[1],method='line pattern; excludes anonymous callbacks and JS methods'))
(OUT/'supporting-symbols.json').write_text(json.dumps(aux,indent=2)+'\n')
# Explicit imports, including the union of conditional branches.
imports=[]
for f in raw['files']:
    for imp in f['imports']:imports.append(dict(source=f['module'],file=f['path'],target=imp,internal=imp in by_module))
(OUT/'module-dependencies.json').write_text(json.dumps(dict(modules=modules,imports=imports,notes=['SwiftPM edges from dump-package; Xcode edges from project metadata.','Chrome to API is a runtime HTTP edge, not a Swift dependency.','Imports include inactive conditional-compilation branches.']),indent=2)+'\n')
# Type references use syntax plus visible-module candidate matching. NEVER label these compiler-resolved calls.
type_kinds={'actor','class','struct','enum','protocol','typealias'}
T=[d for d in D if d['kind'] in type_kinds|{'extension'} and d['production'] and not d['local']]
type_names=collections.defaultdict(list)
for d in T:
    if d['kind']!='extension': type_names[d['name']].append(d)
file_imports={f['path']:{s.split('.')[0] for s in f['imports']} for f in raw['files']}
links=collections.Counter()
type_ids={d['id'] for d in T}
for r in raw['references']:
    if r['kind'] not in ('type','memberType'):continue
    source=by_id.get(r['source'])
    if not source or not source['production']:continue
    while source['kind'] not in type_kinds|{'extension'} and source.get('parent') in by_id: source=by_id[source['parent']]
    if source['kind'] not in type_kinds|{'extension'} or source['id'] not in type_ids:continue
    visible=file_imports[source['file']]|{source['module']}
    candidates=[d for d in type_names.get(r['name'],[]) if d['module'] in visible]
    local=[d for d in candidates if d['file']==source['file']]
    if local:candidates=local
    if len(candidates)==1 and candidates[0]['id']!=source['id']:
        links[source['id'],candidates[0]['id']]+=1
(OUT/'type-dependencies.json').write_text(json.dumps(dict(nodes=[d['id'] for d in T],edges=[dict(source=a,target=b,occurrences=n,certainty='unique visible-name candidate; not type checked') for (a,b),n in sorted(links.items())]),separators=(',',':'))+'\n')
# GraphML supplies one navigable graph containing every nonlocal production type/extension.
import xml.etree.ElementTree as ET
ns='http://graphml.graphdrawing.org/xmlns'
ET.register_namespace('',ns)
graphml=ET.Element('{'+ns+'}graphml')
for key in ['label','module','kind','source','relationship']:
    ET.SubElement(graphml,'{'+ns+'}key',{'id':key,'for':'all','attr.name':key,'attr.type':'string'})
graph=ET.SubElement(graphml,'{'+ns+'}graph',{'id':'types','edgedefault':'directed'})
for d in T:
    node=ET.SubElement(graph,'{'+ns+'}node',{'id':d['id']})
    for key,value in [('label',d['qualifiedName']),('module',d['module']),('kind',d['kind']),('source',d['file']+':'+str(d['line']))]:
        ET.SubElement(node,'{'+ns+'}data',{'key':key}).text=value
for i,((a,b),n) in enumerate(sorted(links.items())):
    edge=ET.SubElement(graph,'{'+ns+'}edge',{'id':'e'+str(i),'source':a,'target':b})
    ET.SubElement(edge,'{'+ns+'}data',{'key':'relationship'}).text='unique visible-name type-reference candidate; not type checked'
ET.ElementTree(graphml).write(OUT/'all-types.graphml',encoding='utf-8',xml_declaration=True)

# Full declared-target graph. All test and utility targets are included.
def mid(name):return 'm'+str(list(by_module).index(name))
mmd=['flowchart LR']
for m in modules:mmd.append(f'  {mid(m["name"])}["{m["name"]}"]')
for m in modules:
    for dep in m['dependencies']:
        if dep in by_module:mmd.append(f'  {mid(m["name"])} {"-. HTTP .->" if m["name"]=="Chrome Companion" else "-->"} {mid(dep)}')
(OUT/'all-targets.mmd').write_text('\n'.join(mmd)+'\n')
# One class diagram per production module; include every nonlocal type, its direct member names,
# and explicit same-module inheritance/conformance candidates. Omit external framework types.
(OUT/'types').mkdir(exist_ok=True)
for module in sorted({d['module'] for d in T}):
    ds=[d for d in T if d['module']==module]; ids={d['id']:'t'+str(i) for i,d in enumerate(ds)}
    lines=['classDiagram','direction LR']
    for d in ds:
        lines.append(f'  class {ids[d["id"]]}["{d["qualifiedName"].replace(chr(34),chr(39))}"] {{')
        lines.append('    <<'+d['kind']+'>>')
        for c in D:
            if c.get('parent')!=d['id'] or c['kind'] not in ('function','initializer','variable','subscript'):continue
            name=re.sub(r'[^\w., ]','_',c['name'])[:100]
            lines.append('    '+name+('()' if c['kind'] in ('function','initializer','subscript') else ''))
        lines.append('  }')
    for d in ds:
        for inherited in d['inherited']:
            cs=[c for c in ds if c['name']==inherited]
            if len(cs)==1:lines.append(f'  {ids[cs[0]["id"]]} <|-- {ids[d["id"]]}')
    (OUT/'types'/(module.replace(' / ','-').replace(' ','_')+'.mmd')).write_text('\n'.join(lines)+'\n')
prod_files=[f for f in raw['files'] if f['production']];prod_d=[d for d in D if d['production']]
funcs=[d for d in prod_d if d['kind']=='function']
public=[d for d in prod_d if d['kind'] in type_kinds|{'function','initializer','subscript'} and ('public' in d['modifiers'].split() or (d.get('parent') in by_id and by_id[d['parent']]['kind']=='protocol' and 'public' in by_id[d['parent']]['modifiers'].split()))]
module_stats=[]
for m in modules:
    fs=[f for f in raw['files'] if f['module']==m['name']];ds=[d for d in D if d['module']==m['name']]
    module_stats.append(dict(name=m['name'],files=len(fs),lines=sum(f['lines'] for f in fs),types=sum(d['kind'] in type_kinds-{'typealias'} for d in ds),functions=sum(d['kind']=='function' for d in ds),dependencies=m['dependencies']))
stats=dict(swiftFiles=len(raw['files']),productionSwiftFiles=len(prod_files),productionLines=sum(f['lines'] for f in prod_files),swiftDeclarations=len(D),productionDeclarations=len(prod_d),references=len(raw['references']),productionKinds=dict(collections.Counter(d['kind'] for d in prod_d)),parseErrors=[f['path'] for f in raw['files'] if f['parseErrors']],productionFilesOver500=sum(f['lines']>500 for f in prod_files),productionFilesOver1000=sum(f['lines']>1000 for f in prod_files),functionsOver50=sum(d['endLine']-d['line']+1>50 for d in funcs),functionsOver100=sum(d['endLine']-d['line']+1>100 for d in funcs),explicitPublicDeclarations=len(public),documentedPublicDeclarations=sum(d['documented'] for d in public),modules=module_stats,largestFiles=sorted(prod_files,key=lambda f:f['lines'],reverse=True)[:25],largestFunctions=sorted(funcs,key=lambda d:d['endLine']-d['line'],reverse=True)[:25])
(OUT/'metrics.json').write_text(json.dumps(stats,indent=2)+'\n')
# Compact tuples keep the self-contained viewer small. Original lossless JSON remains available separately.
fids={f['path']:i for i,f in enumerate(raw['files'])};dids={d['id']:i for i,d in enumerate(D)}
viewer=dict(modules=modules,files=raw['files'],declarations=[[d['name'],d['qualifiedName'],d['kind'],fids[d['file']],d['line'],d['endLine'],dids.get(d.get('parent'),-1),d['signature'],d['inherited'],d['local'],d['production']] for d in D],references=[[dids.get(r['source'],-1),r['name'],r['kind'],r['line'],r['expression']] for r in raw['references']],stats=stats)
compressed=base64.b64encode(gzip.compress(json.dumps(viewer,separators=(',',':'),ensure_ascii=False).encode(),mtime=0)).decode()
template=(OUT/'viewer-template.html').read_text()
(OUT/'explorer.html').write_text(template.replace('__DATA__',compressed))
print(json.dumps({k:v for k,v in stats.items() if k not in ('modules','largestFiles','largestFunctions')},indent=2))
print('Viewer bytes:',(OUT/'explorer.html').stat().st_size)
