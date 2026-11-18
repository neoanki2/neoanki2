// Headless validation of the generated atlas; no browser, window, or network use.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const dir=path.dirname(fileURLToPath(import.meta.url));
const html=fs.readFileSync(path.join(dir,'explorer.html'),'utf8');
const payload=html.match(/<script id="embedded-data"[^>]*>([\s\S]*?)<\/script>/)[1];
const script=[...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)].at(-1)[1];
new vm.Script(script);
class Element {
 constructor(id=''){this.id=id;this.value='';this.textContent='';this.innerHTML='';this.hidden=false;this.disabled=false;this.attributes={};this.options=[];this.dataset={};this.events={}}
 setAttribute(k,v){this.attributes[k]=v} append(o){this.options.push(o)} addEventListener(k,f){this.events[k]=f}
 querySelectorAll(selector){if(selector==='[data-symbol]')return [...this.innerHTML.matchAll(/data-symbol="(\d+)"/g)].map(m=>{const e=new Element();e.dataset.symbol=m[1];return e});if(selector==='[data-module]')return [];return []}
}
const ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);
assert.equal(ids.length,new Set(ids).size,'Duplicate HTML IDs');
const elements=new Map(ids.map(id=>[id,new Element(id)]));
elements.get('embedded-data').textContent=payload;elements.get('symbol-scope').value='production';
const context=vm.createContext({document:{getElementById:id=>{assert(elements.has(id),'Missing element '+id);return elements.get(id)},querySelectorAll:()=>[],createElement:()=>new Element()},window:{},Uint8Array,Blob,Response,DecompressionStream,atob,Map,Set,console});
vm.runInContext(script,context);
for(let n=0;n<100&&!context.window.architectureAtlas;n++){await new Promise(r=>setTimeout(r,50));assert(!elements.get('loading').textContent.startsWith('The source index could not load'),elements.get('loading').textContent)}
assert(context.window.architectureAtlas,'Atlas failed to initialize');
const api=context.window.architectureAtlas,data=api.data;
assert.equal(data.files.length,488);assert.equal(data.declarations.length,28926);assert.equal(data.references.length,291035);
assert(elements.get('loading').hidden);
const original=elements.get('result-count').textContent;
elements.get('search').value='StudyFeatureModel';api.search();assert.notEqual(elements.get('result-count').textContent,original);assert(elements.get('symbol-results').innerHTML.includes('StudyFeatureModel'));
const index=data.declarations.findIndex(d=>d[0]==='StudyFeatureModel'&&d[2]==='class');api.showSymbol(index);assert(elements.get('symbol-detail').innerHTML.includes('Direct members'));assert(elements.get('symbol-detail').innerHTML.includes('start'));
api.showModule('NeoAnkiApplication');assert(elements.get('module-detail').innerHTML.includes('NeoAnkiCore'));assert(elements.get('module-graph').innerHTML.includes('<svg'));
api.showModule('NeoAnki2Widget [Xcode]');assert(elements.get('module-detail').innerHTML.includes('No declared local dependencies'));
for(const d of data.declarations){assert(data.files[d[3]],'Unknown source file');assert(d[6]===-1||data.declarations[d[6]],'Unknown parent');assert(d[4]<=d[5],'Inverted source span')}
const modules=new Map(data.modules.map(m=>[m.name,m]));
function visit(name,active=new Set(),done=new Set()){assert(!active.has(name),'Target cycle '+name);if(done.has(name))return;active.add(name);for(const dep of modules.get(name).dependencies){assert(modules.has(dep),'Unknown target '+dep);visit(dep,active,done)}active.delete(name);done.add(name)}
for(const name of modules.keys())visit(name);
const types=JSON.parse(fs.readFileSync(path.join(dir,'type-dependencies.json'),'utf8')),nodes=new Set(types.nodes);for(const e of types.edges){assert(nodes.has(e.source),'Unknown type graph source');assert(nodes.has(e.target),'Unknown type graph target')}
console.log('PASS: JavaScript syntax and offline atlas initialization');console.log('PASS: symbol search, declaration drill-down, module graph and empty dependency view');console.log(`PASS: ${data.declarations.length} declaration source/parent/span identities`);console.log(`PASS: ${modules.size} components, all declared targets resolve, no target cycles`);console.log(`PASS: ${nodes.size} type/extension graph nodes and ${types.edges.length} candidate edges`);console.log('No browser or desktop was launched; visual rendering was not inspected.');
