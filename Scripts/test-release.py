#!/usr/bin/env python3
"""Headless release-contract tests. No Apple, GitHub, signing or installed app writes."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).parent))
import release as controller
from release_plan import AppInputs, plan, tree, next_version
from release_app_store import AppStorePublisher, Pending


def package_graph():
    def target(name, deps=(), kind='regular', path=None):
        return dict(name=name,type=kind,path=path,dependencies=[{'byName':[d,None]} for d in deps])
    targets=[target('NeoAnki2',['Shared','MacOnly','CloudSync'],'executable'),
             target('NeoAnkiMobile',['Shared'],path='Sources/NeoAnkiIOS'),
             target('Shared',['Core']),target('MacOnly'),target('CloudSync',['Shared']),target('CLIOnly',kind='executable'),
             target('MacTests',['NeoAnki2'],'test'),target('MobileTests',['NeoAnkiMobile'],'test'),
             target('SyncTests',['CloudSync'],'test')]
    root={'targets':targets,'products':[{'name':t['name'],'targets':[t['name']]} for t in targets]}
    core={'targets':[target('Core'),target('CoreCLI',['Core'],'executable')],
          'products':[{'name':'Core','targets':['Core']}]}
    return AppInputs({'':root,'NeoAnkiCore/':core},['NeoAnkiMobile','CloudSync'])


class PlanningTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.git('init','-q');self.git('config','user.name','Release tests');self.git('config','user.email','release@example.test')
        for name in ['Sources/NeoAnki2/App.swift','Sources/NeoAnkiIOS/Home.swift','Sources/Shared/Library.swift',
                     'Sources/MacOnly/API.swift','Sources/CloudSync/Sync.swift','Sources/CLIOnly/main.swift',
                     'NeoAnkiCore/Sources/Core/Item.swift','NeoAnkiCore/Sources/CoreCLI/main.swift',
                     'Platforms/iOS/Info.plist','Packaging/Info.plist','README.md']:
            self.write(name,'before')
        self.git('add','.');self.git('commit','-qm','baseline')
        self.rev=self.git('rev-parse','HEAD');self.inputs=package_graph()
        self.baseline={'version':'1.0.319','channels':{c:{'revision':self.rev,'version':'1.0.319','build':'319'} for c in ['ios','mac','homebrew']}}
    def git(self,*args):return subprocess.check_output(['git',*args],cwd=self.root,text=True).strip()
    def write(self,name,value):
        f=self.root/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(value)
    def release_plan(self):return plan(self.root,self.baseline,self.inputs)
    def test_ios_only(self):
        self.write('Sources/NeoAnkiIOS/Home.swift','after');p=self.release_plan()
        self.assertEqual(p['channels'],['ios']);self.assertEqual(p['tests'],{'':['MobileTests']})
    def test_mac_and_api_changes_always_include_both_mac_distributions(self):
        self.write('Sources/MacOnly/API.swift','after')
        self.assertEqual(self.release_plan()['channels'],['mac','homebrew'])
    def test_cloudkit_direct_ios_dependency_selects_every_distribution(self):
        self.write('Sources/CloudSync/Sync.swift','after')
        self.assertEqual(self.release_plan()['channels'],['ios','mac','homebrew'])
    def test_shared_core_changes_select_both_apps(self):
        self.write('NeoAnkiCore/Sources/Core/Item.swift','after')
        self.assertEqual(self.release_plan()['channels'],['ios','mac','homebrew'])
    def test_docs_tests_cli_and_release_workflow_do_not_publish_apps(self):
        for name in ['README.md','Scripts/release.py','Tests/MacTests/Tests.swift',
                     'Sources/CLIOnly/main.swift','NeoAnkiCore/Sources/CoreCLI/main.swift']:
            self.write(name,'after')
        self.assertEqual(self.release_plan()['channels'],[])
    def test_new_deleted_and_renamed_inputs_are_released(self):
        (self.root/'Sources/NeoAnkiIOS/Home.swift').unlink();self.write('Sources/NeoAnkiIOS/Renamed.swift','before')
        p=self.release_plan();self.assertEqual(p['channels'],['ios'])
        self.assertIn('Sources/NeoAnkiIOS/Home.swift',p['changed_paths'])
        self.assertIn('Sources/NeoAnkiIOS/Renamed.swift',p['changed_paths'])
    def test_packaging_and_manifest_changes(self):
        self.write('Packaging/AppStore/en-US.json','listing')
        self.assertEqual(self.release_plan()['channels'],['mac','homebrew'])
        self.write('Package.swift','manifest')
        self.assertEqual(self.release_plan()['channels'],['ios','mac','homebrew'])
    def test_independent_platform_baselines_do_not_forget_skipped_changes(self):
        self.write('Sources/NeoAnkiIOS/Home.swift','after')
        self.git('add','.');self.git('commit','-qm','ios release')
        self.baseline['channels']['ios']['revision']=self.git('rev-parse','HEAD')
        self.write('Sources/NeoAnki2/App.swift','mac after')
        self.assertEqual(self.release_plan()['channels'],['mac','homebrew'])
    def test_content_checkpoints_detect_reverts_despite_different_git_history(self):
        before=tree(self.root);self.baseline['channels']['ios']['inputs']=self.inputs.snapshot(before,'ios')
        self.write('Sources/NeoAnkiIOS/Home.swift','after')
        self.assertEqual(self.release_plan()['channels'],['ios'])
        self.write('Sources/NeoAnkiIOS/Home.swift','before')
        self.assertEqual(self.release_plan()['channels'],[])
    def test_dependency_closure_excludes_mac_only_code_from_ios(self):
        self.assertFalse(self.inputs.includes('Sources/MacOnly/API.swift','ios'))
        self.assertTrue(self.inputs.includes('Sources/MacOnly/API.swift','mac'))
    def test_platform_condition_is_honored(self):
        self.inputs.targets['Shared']['dependencies'].append({'byName':['MacOnly',{'platformNames':['macos']}]})
        self.assertNotIn('MacOnly',self.inputs.closure(['NeoAnkiMobile'],'ios'))
    def test_real_project_routes_cloud_sync_api_and_mobile_code_correctly(self):
        real=AppInputs.load(Path(__file__).resolve().parent.parent)
        self.assertTrue(real.includes('Sources/NeoAnkiCloudSync/OfflineFirstSyncService.swift','ios'))
        self.assertTrue(real.includes('Sources/NeoAnkiCloudSync/OfflineFirstSyncService.swift','mac'))
        self.assertFalse(real.includes('Sources/NeoAnkiAPI/NeoAnkiAPIService.swift','ios'))
        self.assertFalse(real.includes('Sources/NeoAnkiIOS/MobileRootView.swift','mac'))
    def test_noop_command_does_not_contact_apple_build_commit_or_publish(self):
        class Hub:
            def baseline(inner):return self.baseline,[]
        with patch.object(controller,'ROOT',self.root),patch.object(controller,'WORK',self.root/'.build/releases'),\
             patch.object(controller,'GitHub',Hub),patch.object(controller.AppInputs,'load',return_value=self.inputs),\
             patch.object(controller,'make_api',side_effect=AssertionError('Apple must not be contacted')):
            self.assertEqual(controller.main([]),0)
        self.assertEqual(self.git('rev-parse','HEAD'),self.rev)
    def test_one_command_releases_only_ios_then_unchanged_source_is_a_noop(self):
        self.write('Sources/NeoAnkiIOS/Home.swift','after')
        calls=[];owner=self
        class Hub:
            repository='example/app'
            def baseline(inner):return copy.deepcopy(owner.baseline),[]
            def snapshot(inner,version):
                calls.append(('snapshot',version));owner.git('add','.');owner.git('commit','-qm','release')
                return owner.git('rev-parse','HEAD'),'release/test','https://github.com/example/app/pull/1'
            def reserve(inner,state):calls.append(('reserve',state['version'],state['build']))
            def checkpoint(inner,path,state):owner.baseline=copy.deepcopy(state)
        class API:
            def list(inner,path,**filters):return []
        class Release:
            def __init__(inner,github,api,app_id,state,directory,*args):
                inner.state=state;inner.github=github;inner.path=directory/'release.json'
            def validate(inner):calls.append(('verify',inner.state['tests']))
            def build(inner,c):calls.append(('build',c,inner.state['version'],inner.state['build']))
            def export(inner,c):calls.append(('export',c))
            def save(inner,remote=False):
                controller.write_json(inner.path,inner.state)
                if remote:inner.github.checkpoint(inner.path,inner.state)
            def publish_until_ready(inner,seconds):
                calls.append(('publish',inner.state['selected']))
                inner.state['channels']['ios']={'version':inner.state['version'],'build':inner.state['build'],
                    'revision':inner.state['revision'],'inputs':inner.state['inputs']['ios']}
                inner.state['complete']=True;inner.save(remote=True)
                return {},{}
        original_run=controller.run
        def run(args,**kwargs):
            if args[:3]==['gh','pr','merge']:calls.append(('merge',));return None
            return original_run(args,**kwargs)
        # All effects are confined to this temporary Git repo and these fakes.
        with patch.object(controller,'ROOT',self.root),patch.object(controller,'WORK',self.root/'.build/releases'),\
             patch.object(controller,'GitHub',Hub),patch.object(controller,'Release',Release),\
             patch.object(controller.AppInputs,'load',return_value=self.inputs),\
             patch.object(controller,'preflight'),patch.object(controller,'make_api',return_value=(API(),'app')),\
             patch.object(controller,'status',return_value={}),patch.object(controller,'run',side_effect=run):
            self.write('.gitignore','.build/\n')
            self.assertEqual(controller.main([]),0)
            before=copy.deepcopy(calls)
            self.assertEqual(controller.main([]),0)
            self.assertEqual(calls,before)
        self.assertIn(('reserve','1.0.320','320'),calls)
        self.assertIn(('build','ios','1.0.320','320'),calls)
        self.assertIn(('verify',{'':['MobileTests']}),calls)
        self.assertEqual([c for c in calls if c[0]=='publish'],[('publish',['ios'])])


class VersionTests(unittest.TestCase):
    def test_global_version_is_above_store_brew_and_reserved_versions(self):
        class API:
            def list(self,path,**filters):
                if path=='builds':return [{'attributes':{'version':'8'}}]
                return [{'attributes':{'versionString':'1.0.2'}},{'attributes':{'versionString':'1.0.1'}}]
        baseline={'version':'1.0.319','channels':{'homebrew':{'build':'319'}}}
        self.assertEqual(controller.allocate(baseline,[],API(),'app'),('1.0.320','320'))
        self.assertEqual(controller.allocate(baseline,[{'tagName':'v1.0.321'}],API(),'app'),('1.0.322','320'))
        with self.assertRaises(ValueError):controller.allocate(baseline,[],API(),'app','1.0.2')
        baseline['build']='321'
        self.assertEqual(controller.allocate(baseline,[],API(),'app'),('1.0.320','322'))
    def test_numeric_sort_not_lexical(self):self.assertEqual(next_version(['v1.0.9','1.0.319','1.0.20']),'1.0.320')


class EntrypointTests(unittest.TestCase):
    def test_retired_publishers_cannot_publish_or_allocate_an_independent_version(self):
        root=Path(__file__).resolve().parent.parent
        for name in ('release-fast.sh','release-ios.sh','release-macos-app-store.sh','ship-release.sh',
                     'build-release-candidate.sh','publish-release-candidate.sh','release-ios.py','release-macos-app-store.py'):
            with self.subTest(name=name):
                command=['python3' if name.endswith('.py') else 'bash',str(root/'Scripts'/name)]
                result=subprocess.run(command,capture_output=True,text=True)
                self.assertEqual(result.returncode,2,result.stderr)
                self.assertIn('./Scripts/release.sh',result.stderr)


class AppleFake:
    def __init__(self):
        self.platform='IOS';self.mutations=[];self.counter=0;self.lag_version=False
        self.builds=[{'type':'builds','id':'binary','attributes':{'version':'320','processingState':'VALID'}}]
        self.versions=[{'type':'appStoreVersions','id':'version','attributes':{'platform':'IOS','versionString':'1.0.320','appStoreState':'PREPARE_FOR_SUBMISSION','releaseType':'AFTER_APPROVAL'}}]
        self.attached={'version':None};self.subs=[];self.children={};self.locale=[];self.detail=None
    def list(self,path,**filters):
        if path=='builds':return copy.deepcopy(self.builds)
        if path.endswith('/appStoreVersions'):return copy.deepcopy(self.versions)
        if path=='reviewSubmissions':return copy.deepcopy(self.subs)
        if path.endswith('/items'):return copy.deepcopy(self.children[path.split('/')[1]])
        if path.endswith('/appStoreVersionLocalizations'):return copy.deepcopy(self.locale)
        raise AssertionError(path)
    def request(self,path,method='GET',body=None):
        parts=path.split('/')
        if method=='GET':
            if path.endswith('/relationships/build'):return {'data':self.attached[parts[1]]}
            if path.endswith('/appStoreReviewDetail'):return {'data':self.detail}
            if parts[0]=='reviewSubmissions':return {'data':copy.deepcopy(next(s for s in self.subs if s['id']==parts[1]))}
            raise AssertionError(path)
        self.mutations.append((method,path,copy.deepcopy(body)))
        data=body['data'];attrs=data.get('attributes',{})
        if method=='PATCH':
            if path.endswith('/relationships/build'):
                self.attached[parts[1]]=data;return {'data':data}
            if parts[0]=='reviewSubmissions':
                sub=next(s for s in self.subs if s['id']==parts[1])
                if attrs.get('canceled'):sub['attributes']['state']='CANCELING'
                if attrs.get('submitted'):
                    sub['attributes']['state']='WAITING_FOR_REVIEW'
                    if not self.lag_version:self.versions[0]['attributes']['appStoreState']='WAITING_FOR_REVIEW'
                return {'data':copy.deepcopy(sub)}
            if parts[0]=='appStoreVersions':
                v=next(v for v in self.versions if v['id']==parts[1]);v['attributes'].update(attrs);return {'data':copy.deepcopy(v)}
            if parts[0]=='appStoreReviewDetails':self.detail['attributes'].update(attrs);return {'data':copy.deepcopy(self.detail)}
            if parts[0]=='appStoreVersionLocalizations':return {'data':data}
        if method=='POST':
            self.counter+=1;result=dict(data,id='new'+str(self.counter))
            if path=='reviewSubmissions':
                result['attributes']=dict(attrs,state='READY_FOR_REVIEW');self.subs.append(result);self.children[result['id']]=[]
            elif path=='reviewSubmissionItems':
                result['attributes']={'state':'READY_FOR_REVIEW'}
                self.children[data['relationships']['reviewSubmission']['data']['id']].append(result)
            elif path=='appStoreReviewDetails':self.detail=result
            elif path=='appStoreVersionLocalizations':self.locale.append(result)
            elif path=='appStoreVersions':
                result['attributes']=dict(attrs,appStoreState='PREPARE_FOR_SUBMISSION')
                self.versions.append(result);self.attached[result['id']]=None
            else:raise AssertionError(path)
            return {'data':copy.deepcopy(result)}
        raise AssertionError((method,path))
    def prior_review(self):
        self.versions[0]['attributes'].update(versionString='1.0.2',appStoreState='IN_REVIEW')
        self.attached['version']={'type':'builds','id':'old-binary'}
        self.subs=[{'id':'prior','attributes':{'state':'IN_REVIEW'}}]
        self.children={'prior':[{'id':'old-item','attributes':{'state':'IN_REVIEW'},'relationships':{'appStoreVersion':{'data':{'id':'version'}}}}]}


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.api=AppleFake();self.receipt={'status':'uploaded'};self.saves=[]
        self.listing=dict(copyright='2026',locale='en-US',description='Study',keywords='study',supportUrl='https://example.test/support',marketingUrl='https://example.test',reviewNotes='NeoAnki2 1.0.2 works offline',reviewContact={'firstName':'Tester'})
        self.publisher=AppStorePublisher(self.api,'app','IOS','1.0.320','320',self.receipt,lambda:self.saves.append(copy.deepcopy(self.receipt)),self.listing,'Sync fix')
    def test_processing_does_not_create_or_submit_anything(self):
        self.api.builds[0]['attributes']['processingState']='PROCESSING'
        with self.assertRaises(Pending):self.publisher.submit()
        self.assertEqual(self.api.mutations,[])
    def test_exact_build_and_automatic_release_with_no_ui_gate(self):
        self.publisher.submit()
        self.assertEqual(self.api.attached['version']['id'],'binary')
        self.assertEqual(self.receipt['status'],'submitted')
        self.assertEqual(self.receipt['apple_state'],'WAITING_FOR_REVIEW')
        self.assertEqual(self.api.versions[0]['attributes']['releaseType'],'AFTER_APPROVAL')
    def test_resume_does_not_duplicate_submissions_or_edit_reviewing_version(self):
        self.publisher.submit();before=copy.deepcopy(self.api.mutations)
        self.publisher.submit();self.assertEqual(self.api.mutations,before)
        self.assertEqual(len(self.api.subs),1)
    def test_acknowledged_submission_survives_version_state_lag(self):
        self.api.lag_version=True;self.publisher.submit();before=copy.deepcopy(self.api.mutations)
        self.publisher.submit();self.assertEqual(self.api.mutations,before)
    def test_cancellation_waits_for_parent_not_just_editable_version(self):
        self.api.prior_review()
        with self.assertRaises(Pending):self.publisher.submit()
        self.assertEqual(self.api.subs[0]['attributes']['state'],'CANCELING')
        self.api.versions[0]['attributes']['appStoreState']='DEVELOPER_REJECTED'
        self.api.children['prior'][0]['attributes']['state']='REMOVED'
        before=len(self.api.mutations)
        with self.assertRaises(Pending):self.publisher.submit()
        self.assertEqual(len(self.api.mutations),before)
        self.api.subs[0]['attributes']['state']='CANCELED'
        self.publisher.submit()
        self.assertEqual(self.api.versions[0]['attributes']['versionString'],'1.0.320')
        self.assertEqual(self.api.attached['version']['id'],'binary')
        self.assertEqual(self.receipt['status'],'submitted')
    def test_cancel_does_not_remove_other_review_items(self):
        self.api.prior_review();self.api.children['prior'].append({'attributes':{'state':'IN_REVIEW'},'relationships':{'appStoreVersion':{'data':{'id':'another'}}}})
        with self.assertRaisesRegex(ValueError,'other items'):self.publisher.submit()
        self.assertEqual(self.api.mutations,[])
    def test_apple_rejection_requires_actual_remediation(self):
        self.api.versions[0]['attributes']['appStoreState']='REJECTED'
        with self.assertRaisesRegex(ValueError,'written issues'):self.publisher.submit()
        self.assertEqual(self.api.mutations,[])
    def test_newer_store_version_cannot_be_downgraded(self):
        self.api.versions[0]['attributes']['versionString']='1.0.321'
        with self.assertRaisesRegex(ValueError,'newer'):self.publisher.submit()
        self.assertEqual(self.api.mutations,[])
    def test_invalid_or_changed_binary_cannot_be_submitted(self):
        self.api.builds[0]['attributes']['processingState']='INVALID'
        with self.assertRaises(ValueError):self.publisher.submit()
        self.api.builds[0]['attributes']['processingState']='VALID';self.receipt['build_id']='different'
        with self.assertRaises(ValueError):self.publisher.submit()
        self.assertEqual(self.api.mutations,[])
    def test_uncertain_create_response_resumes_the_owned_empty_draft(self):
        self.api.subs=[{'id':'saved','attributes':{'state':'READY_FOR_REVIEW'}}];self.api.children={'saved':[]};self.receipt['submission_id']='saved'
        self.publisher.submit();self.assertEqual(len(self.api.subs),1)
        self.assertEqual(self.receipt['submission_id'],'saved')
    def test_unrelated_active_submission_is_never_reused(self):
        self.api.subs=[{'id':'other','attributes':{'state':'READY_FOR_REVIEW'}}];self.api.children={'other':[]}
        with self.assertRaisesRegex(ValueError,'duplicate'):self.publisher.submit()
        self.assertEqual(len(self.api.subs),1)
    def test_old_public_and_replaced_versions_do_not_block_a_new_version(self):
        self.api.versions[0]['attributes'].update(versionString='1.0.319',appStoreState='READY_FOR_SALE')
        self.api.versions.append({'id':'old','attributes':{'versionString':'1.0.318','appStoreState':'REPLACED_WITH_NEW_VERSION'}})
        self.publisher.submit()
        self.assertEqual(self.receipt['status'],'submitted')
        self.assertNotEqual(self.receipt['version_id'],'version')
    def test_current_apple_state_field_takes_precedence(self):
        self.publisher.submit();before=copy.deepcopy(self.api.mutations)
        self.api.versions[0]['attributes'].update(appVersionState='PROCESSING_FOR_DISTRIBUTION',appStoreState='NOT_APPLICABLE')
        self.publisher.submit()
        self.assertEqual(self.receipt['apple_state'],'PROCESSING_FOR_DISTRIBUTION')
        self.assertEqual(self.api.mutations,before)
    def test_unknown_apple_state_is_never_edited(self):
        self.api.versions[0]['attributes']['appStoreState']='SOMETHING_NEW'
        with self.assertRaisesRegex(ValueError,'not editable'):self.publisher.submit()
        self.assertEqual(self.api.mutations,[])
    def test_review_draft_with_other_items_is_never_submitted(self):
        self.api.subs=[{'id':'saved','attributes':{'state':'READY_FOR_REVIEW'}}]
        self.api.children={'saved':[{'attributes':{'state':'READY_FOR_REVIEW'},'relationships':{'appStoreVersion':{'data':{'id':'version'}}}},
                                    {'attributes':{'state':'READY_FOR_REVIEW'},'relationships':{}}]}
        with self.assertRaisesRegex(ValueError,'other items'):self.publisher.submit()
        self.assertFalse(any(m[1]=='reviewSubmissions/saved' for m in self.api.mutations))


class RecoveryTests(unittest.TestCase):
    def release(self,selected):
        value=object.__new__(controller.Release)
        value.lock=threading.RLock();value.directory=Path('/unused');value.source=Path('/unused/source')
        value.state={'version':'1.0.320','revision':'abc','build':'320','selected':selected,'inputs':{'ios':{'phone':'a'},'mac':{'desktop':'b'}},
                     'channels':{},'phases':{c:{'status':'uploaded'} for c in selected},'notes':'Fix'}
        value.api=object();value.app_id='app';value.save=lambda remote=False:None
        value.verify_source=lambda:None
        value.github=type('Hub',(),{'history':lambda self:[{'tagName':'v1.0.320'}]})()
        return value
    def test_apple_processing_does_not_roll_back_brew_or_repeat_finished_channel(self):
        r=self.release(['ios','mac','homebrew']);calls=[]
        def store(c):
            calls.append(c)
            if c=='ios':raise Pending('processing')
            r.state['phases'][c]['status']='submitted'
        r.publish_store=store;r.publish_homebrew=lambda:r.state['phases']['homebrew'].update(status='published')
        errors,pending=r.publish();self.assertEqual(errors,{})
        self.assertEqual(pending,{'ios':'processing'})
        self.assertEqual(r.state['phases']['homebrew']['status'],'published')
        self.assertFalse(r.state['complete'])
    def test_ios_only_never_calls_mac_or_homebrew(self):
        r=self.release(['ios']);r.publish_store=lambda c:(_ for _ in ()).throw(Pending('processing'))
        r.publish_homebrew=lambda:(_ for _ in ()).throw(AssertionError('Homebrew called'))
        self.assertEqual(r.publish(),({}, {'ios':'processing'}))
    def test_uploading_phase_never_rebuilds_or_reuploads(self):
        r=self.release(['ios']);r.state['phases']['ios']['status']='uploading'
        r.builder=lambda c:(_ for _ in ()).throw(AssertionError('upload repeated'))
        r.build('ios');r.export('ios')
        class Publisher:
            def __init__(self,*args):pass
            def submit(self):raise Pending('Apple has not exposed it yet')
        with patch.object(controller,'AppStorePublisher',Publisher),patch.object(controller,'listing',return_value={}):
            with self.assertRaises(Pending):r.publish_store('ios')
    def test_a_newer_global_release_stops_old_publication(self):
        r=self.release(['ios']);r.github.history=lambda:[{'tagName':'v1.0.321'}]
        r.publish_store=lambda c:(_ for _ in ()).throw(AssertionError('stale release published'))
        with self.assertRaisesRegex(RuntimeError,'newer'):r.publish()
    def test_crash_after_submission_acknowledgment_still_advances_channel_baseline(self):
        r=self.release(['ios']);r.state['phases']['ios'].update(status='submitted',build_id='binary')
        r.builder=lambda c:(_ for _ in ()).throw(AssertionError('uploaded again'))
        r.publish_store('ios')
        self.assertEqual(r.state['channels']['ios']['inputs'],{'phone':'a'})
        self.assertEqual(r.state['channels']['ios']['version'],'1.0.320')
    def test_real_errors_are_not_polled_as_apple_readiness(self):
        r=self.release(['ios']);calls=[]
        r.publish=lambda:(calls.append('publish') or ({'ios':'invalid binary'},{}))
        with patch.object(controller.time,'sleep',side_effect=AssertionError('error retried')):
            self.assertEqual(r.publish_until_ready(600),({'ios':'invalid binary'},{}))
        self.assertEqual(calls,['publish'])
    def test_failed_verification_is_preserved_and_never_rerun(self):
        r=self.release(['ios'])
        with tempfile.TemporaryDirectory() as folder:
            r.directory=Path(folder);r.source=Path(folder)
            r.state.update(tests={'':['SyncTests']},changed_paths=[])
            def run(args,**kwargs):
                if args[0]=='xcrun':return '/SDK'
                Path(kwargs['log']).write_text('assertion failed')
                raise RuntimeError('assertion failed')
            with patch.object(controller,'run',side_effect=run):
                with self.assertRaisesRegex(RuntimeError,'assertion failed'):r.validate()
            self.assertIn('validation_failure',r.state)
            with patch.object(controller,'run',side_effect=AssertionError('failed check rerun')):
                with self.assertRaisesRegex(RuntimeError,'failed verification'):r.validate()
    def test_resume_downloads_original_homebrew_artifact_instead_of_resigning(self):
        r=self.release(['homebrew'])
        with tempfile.TemporaryDirectory() as folder:
            r.directory=Path(folder)
            content=b'original signed artifact';name='NeoAnki2-1.0.320-mac-universal.dmg'
            expected=controller.hashlib.sha256(content).hexdigest()
            r.state['phases']['homebrew'].update(status='built',artifact=name,artifact_sha256=expected)
            names=[name,name+'.sha256','notarization.json'];downloads=[]
            r.github.assets=lambda v:[{'name':n} for n in names]
            def download(v,n,path):downloads.append(n);Path(path).write_bytes(content if n==name else b'receipt')
            r.github.download=download
            with patch.object(controller,'run',side_effect=AssertionError('artifact rebuilt')):r.build('homebrew')
            self.assertEqual(downloads,names)
            self.assertEqual(controller.sha(r.directory/'homebrew'/name),expected)


if __name__=='__main__':unittest.main()
