#!/usr/bin/env python3
"""Reproduce bounded architecture claims without editing app sources.
Creates a temporary Swift executable and temporary architecture-gate fixtures.
Writes confirmation results/evidence only beside this script. No GUI/network services.
"""
import csv, gzip, hashlib, json, os, pathlib, re, shutil, subprocess, tempfile
HERE=pathlib.Path(__file__).resolve().parent
ROOT=HERE.parents[3]
AUDIT=HERE.parent
results=[]
def claim(identifier,statement,details=None):
    results.append(dict(id=identifier,status='confirmed',statement=statement,details=details))
    print('PASS '+identifier+': '+statement,flush=True)
def run(argv,**kwargs):return subprocess.run(argv,cwd=ROOT,text=True,capture_output=True,check=True,**kwargs)
# Byte identity ties all checks to the actual audited tracked files.
rows=list(csv.DictReader((AUDIT/'files.tsv').open(),delimiter='\t'))
for row in rows:assert hashlib.sha256((ROOT/row['path']).read_bytes()).hexdigest()==row['sha256'],row['path']
claim('S1',f"All {len(rows)} audited tracked files still match their recorded SHA-256 digests")
with gzip.open(AUDIT/'swift-inventory.json.gz','rt') as f:index=json.load(f)
tracked=set(run(['git','ls-files','--','*.swift',':!:docs/audits/architecture-2026-11-17/**']).stdout.splitlines())
assert tracked=={f['path'] for f in index['files']}
assert not any(f['parseErrors'] for f in index['files'])
assert len(index['files'])==488 and len(index['declarations'])==28926
claim('S2','488 Swift file identities match git; saved scanner output has 28,926 declaration records and no parser errors',
      'Confirms saved-output counts and input coverage; does not independently prove SwiftSyntax traversal completeness.')
# Independently re-read both manifests with SwiftPM, compare complete target edges.
saved=json.loads((AUDIT/'module-dependencies.json').read_text())['modules']
for package,prefix in [(ROOT,''),(ROOT/'NeoAnkiCore','NeoAnkiCore/')]:
    manifest=json.loads(run(['swift','package','--package-path',str(package),'dump-package']).stdout)
    for target in manifest['targets']:
        expected=next(m for m in saved if m['name']==target['name'])
        deps=[next(iter(dep.values()))[0] for dep in target['dependencies']]
        assert deps==expected['dependencies'],target['name']
    core=next(t for t in manifest['targets'] if t['name']==('NeoAnkiApplication' if not prefix else 'NeoAnkiCore'))
    if prefix:assert any(s.get('kind',{}).get('linkedLibrary',{}).get('_0')=='sqlite3' for s in core['settings'])
claim('S3','All 37 SwiftPM target dependency lists match fresh SwiftPM output')
# Direct structural predicates use source inventory plus source text, not a quality score.
D=index['declarations']
repository=next(d for d in D if d['name']=='SQLiteLibraryRepository' and d['kind']=='actor')
assert repository['file']=='Sources/NeoAnkiApplication/LibraryRepository.swift'
assert (ROOT/'NeoAnkiCore/Sources/NeoAnkiCore/Database/SQLiteDatabase.swift').is_file()
assert (ROOT/'NeoAnkiCore/Sources/NeoAnkiCore/Models/Item.swift').is_file()
claim('S4','Application contracts and SQLite repository adapter share a target; Core includes both model and SQLite implementation')
exposed=next(d for d in D if d['name']=='library' and d['file']=='Sources/NeoAnkiFeatures/LibraryFeatureModel.swift' and d['signature'].startswith('public let'))
assert 'any LibraryRepository' in exposed['signature']
claim('S5','LibraryFeatureModel publicly exposes an aggregate LibraryRepository',f"{exposed['file']}:{exposed['line']}")
route=(ROOT/'Sources/NeoAnkiAPI/NeoAnkiAPIService.swift').read_text()
assert 'guard let endpoint = APIOpenAPI.endpoint(' in route and 'switch (request.method, request.path)' in route
assert any(d['name']=='APIEndpointHandler' and d['kind']=='enum' for d in D)
claim('S6','Typed HTTP endpoint metadata and a separate method/path execution switch coexist')
providers=(ROOT/'Sources/NeoAnkiFeatures/AppleContextProviders.swift').read_text()
assert 'import FoundationModels' in providers and 'import AVFoundation' in providers
for p,token in [('Platforms/iOS/MobilePaths.swift','try! fileManager.url('),('Platforms/iOS/NeoAnkiIOSApp.swift','try! SQLiteLibraryRepository(')]:assert token in (ROOT/p).read_text()
claim('S7','Features contains Apple provider imports; iOS filesystem/repository initialization uses try!')
functions=[d for d in D if d['kind']=='function']
for file,name,length in [('Sources/NeoAnkiAPI/NeoAnkiAPIService.swift','route',538),('NeoAnkiCore/Sources/NeoAnkiCore/Statistics/StatisticsEngine.swift','snapshot',559)]:
    d=next(d for d in functions if d['file']==file and d['name']==name)
    assert d['endLine']-d['line']+1==length
claim('S8','Router and statistics snapshot span 538 and 559 source lines respectively',
      'Span is objective. Number of responsibilities, maintainability and extraction value remain judgments.')
# Run the actual guard against sandboxed fixture files, using real rg.
gate=(ROOT/'Scripts/validate-architecture.sh').read_text()
def exercise_import(import_line):
    with tempfile.TemporaryDirectory(prefix='neoanki-guard-witness-') as name:
        root=pathlib.Path(name);(root/'Scripts').mkdir()
        script=root/'Scripts/validate-architecture.sh';script.write_text(gate)
        for sub in ['NeoAnkiApplication','NeoAnkiFeatures','NeoAnkiSharedUI','NeoAnkiCloudSync','NeoAnkiDeckBuilderCore','NeoAnkiAPI','NeoAnki2','NeoAnkiIOS']:
            (root/'Sources'/sub).mkdir(parents=True);(root/'Sources'/sub/'Empty.swift').write_text('// fixture\n')
        (root/'NeoAnkiCore/Sources/NeoAnkiCore').mkdir(parents=True)
        (root/'NeoAnkiCore/Sources/NeoAnkiCore/Empty.swift').write_text('// fixture\n')
        for file in ['ContentView.swift','NeoAnki2App.swift']:(root/'Sources/NeoAnki2'/file).write_text('// fixture\n')
        (root/'Sources/NeoAnkiFeatures/Injected.swift').write_text(import_line+'\n')
        result=subprocess.run(['bash',str(script)],capture_output=True,text=True)
        return dict(importSyntax=import_line,exitCode=result.returncode,stdout=result.stdout,stderr=result.stderr)
imports=[exercise_import(s) for s in ['import SwiftUI','@preconcurrency import SwiftUI','import struct SwiftUI.Color','import  SwiftUI']]
assert imports[0]['exitCode']==1
assert all(r['exitCode']==0 for r in imports[1:])
(HERE/'guard-witnesses.json').write_text(json.dumps(imports,indent=2)+'\n')
claim('W7','Actual guard rejects plain forbidden import but accepts attributed, selective and extra-space variants',
      'Fixture uses the unchanged script and real rg. Fixtures are text, not compiler-validated programs; confirms gate matching behavior.')
# Swift compiler and real public implementations provide witnesses, not reimplementations.
with tempfile.TemporaryDirectory(prefix='neoanki-architecture-witness-') as name:
    temp=pathlib.Path(name);(temp/'Sources/Witnesses').mkdir(parents=True)
    shutil.copyfile(HERE/'Witnesses.swift',temp/'Sources/Witnesses/Witnesses.swift')
    # JSON string literals are also valid Swift string literals for these local paths.
    manifest='''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ArchitectureWitnesses", platforms: [.macOS(.v14)], dependencies: [
.package(path: ROOT_PATH), .package(path: CORE_PATH)
], targets: [.executableTarget(name: "Witnesses", dependencies: [
.product(name: "NeoAnkiApplication", package: "neoanki2"),
.product(name: "NeoAnkiCore", package: "neoankicore")])])
'''.replace('ROOT_PATH',json.dumps(str(ROOT))).replace('CORE_PATH',json.dumps(str(ROOT/'NeoAnkiCore')))
    (temp/'Package.swift').write_text(manifest)
    result=subprocess.run(['swift','run','--package-path',str(temp),'--scratch-path',str(temp/'build'),'Witnesses'],capture_output=True,text=True,cwd=ROOT)
    (HERE/'behavioral-witnesses.log').write_text(result.stdout+'\n'+result.stderr)
    assert result.returncode==0,'Behavioral witnesses failed; see behavioral-witnesses.log'
    assert '6 behavioral witnesses passed' in result.stdout
    for line in result.stdout.splitlines():
        if line.startswith('PASS W'):
            ident,statement=line.removeprefix('PASS ').split(': ',1);claim(ident,statement)
(HERE/'results.json').write_text(json.dumps(dict(schemaVersion=1,checks=results,limits=[
    'These are bounded structural/behavioral confirmations, not theorem-prover verification.',
    'No claim of a complete compiler-resolved dependency/call graph.',
    'No universal SOLID compliance/noncompliance or correctness of a proposed redesign is proven.',
    'Saved build/test logs attest prior successful executions; this run does not repeat an unchanged full test suite.'
]),indent=2)+'\n')
print(f'{len(results)} bounded claims confirmed.',flush=True)
