import {detachAdmission,createAdmissionRefresh,refreshProducerMetadata,refreshNormalMetadata,refreshPreflightMetadata,refreshEmitterMetadata} from './admission-context.mjs';
import {collectPreflightProof,preflightCandidate} from './preflight-proof.mjs';
import {selectionFields,collectSelectedTestArtifact} from './campaign-test-selection.mjs';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,readdirSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {allClear,bytesDigest,candidate,canonical,CORE,digest,manifest,plan,producer,requireThat} from './verify.mjs';
import {checkTagGuard} from './policy.mjs';
import {findNormalRuns,selectNormalRun} from './normal-ci.mjs';
import {channelContext,releaseFingerprint} from './channels.mjs';

// No shell expansion, caller-provided commands, implicit pagination or token output.
export class GitHub {
  constructor(token=process.env.GH_TOKEN) {this.environment={...process.env,GH_TOKEN:token};}
  command(args) { return execFileSync('gh',args,{encoding:'utf8',maxBuffer:32*1024*1024,env:this.environment}); }
  get(path) { return JSON.parse(this.command(['api',path])); }
  pages(path,key) {
    const results=[];
    for(let page=1;page<=100;page++) {
      const response=this.get(`${path}${path.includes('?')?'&':'?'}per_page=100&page=${page}`);
      const items=key ? response[key] : response;
      requireThat(Array.isArray(items),'Malformed GitHub pagination response');
      results.push(...items);
      if(items.length<100) { if(key && 'total_count' in response) requireThat(response.total_count===results.length,'Incomplete GitHub pagination'); return results; }
    }
    throw new Error('GitHub evidence pagination limit reached');
  }
  head(repo,branch='dev') { return this.get(`repos/${repo}/git/ref/heads/${branch}`).object.sha; }
  object(repo,ref,path) {
    const tree=this.get(`repos/${repo}/git/trees/${ref}?recursive=1`);
    requireThat(tree.truncated===false,'Truncated Git tree is ineligible');
    const matches=tree.tree.filter(o=>o.path===path);
    requireThat(matches.length===1 && /^[a-f0-9]{40}$/.test(matches[0].sha),'Expected unique Git object');
    return matches[0];
  }
  tree(repo,ref) { return this.get(`repos/${repo}/git/commits/${ref}`).tree.sha; }
  run(repo,id) { return this.get(`repos/${repo}/actions/runs/${id}`); }
  jobs(repo,r) { return this.pages(`repos/${repo}/actions/runs/${r.id}/attempts/${r.run_attempt}/jobs`,'jobs'); }
  artifact(repo,run,name) {
    const all=this.pages(`repos/${repo}/actions/runs/${run}/artifacts`,'artifacts').filter(a=>a.name===name);
    requireThat(all.length===1 && all[0].expired===false,`Missing/duplicate/expired ${name}`);
    const detail=this.get(`repos/${repo}/actions/artifacts/${all[0].id}`);
    requireThat(String(detail.id)===String(all[0].id)&&detail.name===name&&detail.expired===false,'Artifact detail differs from unique live inventory');return detail;
  }
  download(repo,run,name,files) {
    this.artifact(repo,run,name); // Reject ambiguous same-name artifacts before gh extraction.
    const dir=mkdtempSync(join(tmpdir(),'wss-proof-'));
    try {
      this.command(['run','download',String(run),'--repo',repo,'--name',name,'--dir',dir]);
      const entries=readdirSync(dir,{withFileTypes:true});
      requireThat(entries.every(x=>x.isFile()) && canonical(entries.map(x=>x.name).sort())===canonical([...files].sort()),'Artifact has unexpected files/directories');
      return Object.fromEntries(files.map(f=>[f,readFileSync(join(dir,f))]));
    } finally {rmSync(dir,{recursive:true,force:true});}
  }
}

export function freeze(g,m,c,{verificationOnly=false,testSelection}={}) {
  manifest(m); candidate(c);
  const selected=selectionFields(m,c,testSelection);
  const context=channelContext(m.channel);
  const guard=m.legacy_tag_guard;
  const unconfigured=guard?.ruleset_id===null && guard?.policy_sha256===null;
  if(!verificationOnly || !unconfigured) checkTagGuard(g,m);
  const target_snapshots={};
  for(const t of m.targets) {
    const head_sha=g.head(t.repository,t.branch);
    const trusted=Object.fromEntries(t.trusted_paths.map(path=>[path,g.object(t.repository,head_sha,path).sha]));
    // The receipt workflow must also be registered on the default branch.
    const w=g.get(`repos/${t.repository}/actions/workflows/release-receipt.yml`);
    requireThat(w.path==='.github/workflows/release-receipt.yml' && w.state==='active',`Receipt workflow unavailable: ${t.id}`);
    target_snapshots[t.id]={head_sha,trusted};
  }
  const body={schema:context.planSchema,channel:m.channel,candidate:c,manifest:m,manifest_sha256:digest(m),target_snapshots,...selected};
  return plan({...body,plan_id:digest(body)});
}
export function loadPlan(g,runId) {
  requireThat(/^[1-9][0-9]*$/.test(runId),'Invalid producer run');
  const data=g.download(CORE,runId,'wss-propagation-plan',['plan.json']);
  const p=plan(JSON.parse(data['plan.json']));
  requireThat(p.candidate.run_id===runId,'Plan came from another producer run');
  const r=g.run(CORE,runId);
  requireThat(r.repository?.full_name===CORE && r.head_repository?.full_name===CORE && r.path==='.github/workflows/artifacts.yml' && r.event==='push' && r.head_branch===p.channel && r.head_sha===p.candidate.commit,'Plan artifact producer is not canonical');
  const policy=g.get(`repos/${CORE}/contents/${channelContext(p.channel).targetPolicy}?ref=${p.candidate.commit}`);
  requireThat(policy.encoding==='base64' && canonical(JSON.parse(Buffer.from(policy.content,'base64')))===canonical(p.manifest),'Frozen policy is not the reviewed producer policy');
  return p;
}
export function archive(g,c) {
  const a=g.artifact(CORE,c.run_id,'universal-release-assets');
  requireThat(String(a.id)===c.artifact_id,'Wrong universal artifact');
  const files=g.download(CORE,c.run_id,a.name,[c.archive,'SHA256SUMS.txt']);
  const lines=files['SHA256SUMS.txt'].toString('utf8').trim().split(/\r?\n/);
  requireThat(lines.length===1 && lines[0]===`${c.sha256}  ${c.archive}`,'Checksum metadata differs from exact accepted ZIP');
  requireThat(bytesDigest(files[c.archive])===c.sha256,'Downloaded ZIP checksum mismatch');
  return detachAdmission({artifact:a,files});
}
export function collect(g,p) {
  const client=g;g=new Proxy(client,{get(target,key){const value=Reflect.get(target,key);return typeof value==='function'?(...args)=>detachAdmission(value.apply(client,args)):value;}});
  plan(p);
  const c=p.candidate, source=structuredClone(g.run(CORE,c.run_id)), zip=archive(g,c);
  const evidence={producer:{run:source,current_head:g.head(CORE,p.channel),jobs:g.jobs(CORE,source),artifact:zip.artifact,archive_sha256:bytesDigest(zip.files[c.archive])},targets:{}};
  for(const t of p.manifest.targets) {
    const {emitter,name}=discoverReceipt(g,p,t);
    const receipt_bytes=g.download(t.repository,String(emitter.id),name,['receipt.json'])['receipt.json'];
    const r=JSON.parse(receipt_bytes.toString('utf8'));
    requireThat(r.emitter?.run_id===String(emitter.id),'Receipt emitter identifier mismatch');
    const pr=g.get(`repos/${t.repository}/pulls/${r.merge?.pr_number}`);
    const normal=g.run(t.repository,r.normal_ci?.run_id);
    const normals=findNormalRuns(g,t,r.merge?.sha,pr.merged_at);
    requireThat(normals.length===1 && String(normals[0].id)===String(normal.id),
      'Normal post-merge CI run missing, ambiguous or different from receipt');
    const parent_gitlinks=Object.fromEntries(Object.entries(t.parents).map(([parent,path])=>{
      const link=g.object(t.repository,r.merge.sha,path);
      requireThat(link.type==='commit' && link.mode==='160000','Expected a Git submodule pin');
      return [parent,link.sha];
    }));
    const preflights=(r.preflights || []).map(d=>{
      const proof=collectPreflightProof(g,d),run=proof.run,target=p.manifest.targets.find(t=>t.repository===d.repository);
      requireThat(target,'Unknown preflight target');
      return detachAdmission({...proof,candidate:preflightCandidate(g,d),
        ...(p.test_selection?{selected_tests:collectSelectedTestArtifact(g,p,target.id,run)}:{})});
    });
    evidence.targets[t.id]=detachAdmission({receipt:r,receipt_bytes,receipt_sha256:bytesDigest(receipt_bytes),pr,current_head:g.head(t.repository,t.branch),
      merge_tree:g.tree(t.repository,r.merge.sha),tested_tree:g.tree(t.repository,normal.head_sha),
      trusted:Object.fromEntries(t.trusted_paths.map(path=>[path,g.object(t.repository,r.merge.sha,path).sha])),
      parent_gitlinks,normal_run:normal,normal_latest_run_id:String(normals[0].id),normal_jobs:g.jobs(t.repository,normal),
      ...(p.test_selection?{selected_tests:collectSelectedTestArtifact(g,p,t.id,normal)}:{}),
      emitter_run:g.run(t.repository,String(emitter.id)),artifact:g.artifact(t.repository,String(emitter.id),name),preflights});
  }
  // Finish expensive native artifact/log IO before the final admission reads.
  for(const target of Object.values(evidence.targets))for(const d of target.receipt.preflights)collectPreflightProof(g,d);
  return {record:refreshAdmission(g,p,evidence),files:zip.files,admission:evidence};
}

// Internal evidence context only; frozen plans and acceptance wire schemas stay
// unchanged. Reuse receipt/producer/allClear policy after refreshing mutable CI
// metadata, then read exact accepted heads last (parents are also required targets).
// These distributed observations narrow the IO window; they are not atomic.
export function discoverReceipt(g,p,t) {
  const runs=g.pages(`repos/${t.repository}/actions/workflows/release-receipt.yml/runs?branch=${t.branch}`,'workflow_runs'),matches=[];
  for(const emitter of runs){const name=`wss-acceptance-${t.id}-${p.plan_id}-a${emitter.run_attempt}`;
    if(g.pages(`repos/${t.repository}/actions/runs/${emitter.id}/artifacts`,'artifacts').some(a=>a.name===name))matches.push({emitter,name});}
  requireThat(matches.length===1,`Missing or ambiguous actual acceptance receipt for ${t.id}`);return matches[0];
}
export function assertPublicationAbsent(g,p) {
  const tag=releaseFingerprint(p.channel,p.candidate.run_id,p.plan_id);
  requireThat(g.pages(`repos/${CORE}/git/matching-refs/tags/${tag}`).filter(t=>t.ref===`refs/tags/${tag}`).length===0&&
    g.pages(`repos/${CORE}/releases`).filter(r=>r.tag_name===tag).length===0,'Exact publication tag/release appeared before create');
}
export function refreshAdmission(g,p,captured,{publication=false}={}) {
  requireThat(captured?.producer&&captured?.targets,'Publication requires collected admission evidence');
  const evidence=detachAdmission(captured),session=createAdmissionRefresh(g);
  for(const t of p.manifest.targets) {
    const e=evidence.targets[t.id],r=e.receipt;
    const normal=refreshNormalMetadata(g,p,t,{run:e.normal_run,jobs:e.normal_jobs,selected_tests:e.selected_tests,merge_sha:r.merge.sha,merged_at:e.pr.merged_at},{session});
    e.normal_run=normal.run;e.normal_jobs=normal.jobs;e.normal_latest_run_id=String(normal.run.id);if(p.test_selection)e.selected_tests=normal.selected_tests;
    e.preflights=e.preflights.map((proof,i)=>{
      const fresh=refreshPreflightMetadata(g,p,{descriptor:r.preflights[i],proof,candidate:proof.candidate,selected_tests:proof.selected_tests},{session});
      return {...fresh.proof,candidate:fresh.candidate,...(fresh.selected_tests?{selected_tests:fresh.selected_tests}:{})};
    });
    e.emitter_run=refreshEmitterMetadata(g,p,t,e.emitter_run,{session});
    const found=discoverReceipt(g,p,t);
    requireThat(String(found.emitter.id)===r.emitter.run_id&&found.emitter.run_attempt===r.emitter.attempt,'Receipt discovery changed emitter identity/attempt');
    const artifact=detachAdmission(g.artifact(t.repository,r.emitter.run_id,found.name));
    requireThat(String(artifact.id)===String(e.artifact.id)&&artifact.digest===e.artifact.digest,'Receipt artifact replaced since authentication');e.artifact=artifact;
  }
  evidence.producer=refreshProducerMetadata(g,p,evidence.producer,{session});
  if(publication){checkTagGuard(g,p.manifest);assertPublicationAbsent(g,p);}
  session.finish();
  for(const t of p.manifest.targets)evidence.targets[t.id].current_head=g.head(t.repository,t.branch);
  evidence.producer.current_head=g.head(CORE,p.channel);
  return allClear(p,evidence);
}

export function publish(g,p,accepted,directory,reader=g) {
  const legacy_tag_guard=checkTagGuard(reader,p.manifest);
  const context=channelContext(p.channel),tag=releaseFingerprint(p.channel,p.candidate.run_id,p.plan_id);
  const record={...accepted.record,tag,legacy_tag_guard};
  const expected={...accepted.files,'plan.json':Buffer.from(canonical(p)+'\n'),'acceptance.json':Buffer.from(canonical(record)+'\n')};
  // Existing tag/release state is read first. An API error is not interpreted as absence.
  const tags=g.pages(`repos/${CORE}/git/matching-refs/tags/${tag}`);
  const exact=tags.filter(t=>t.ref===`refs/tags/${tag}`);
  const releases=g.pages(`repos/${CORE}/releases`).filter(r=>r.tag_name===tag);
  requireThat(exact.length<=1 && releases.length<=1,'Ambiguous existing tag/release');
  if(exact.length || releases.length) {
    requireThat(exact.length===1 && releases.length===1 && exact[0].object.type==='commit' && exact[0].object.sha===p.candidate.commit && releases[0].prerelease===(context.kind==='beta') && releases[0].draft===false,'Existing tag/release is incomplete or mismatched; inspect before recovery');
    requireThat(canonical(releases[0].assets.map(a=>a.name).sort())===canonical(Object.keys(expected).sort()),'Existing release asset inventory mismatch');
    const temp=mkdtempSync(join(tmpdir(),'wss-release-'));
    try {
      g.command(['release','download',tag,'--repo',CORE,'--dir',temp]);
      for(const [name,bytes] of Object.entries(expected)) requireThat(bytesDigest(readFileSync(join(temp,name)))===bytesDigest(bytes),'Existing release bytes mismatch');
    } finally {rmSync(temp,{recursive:true,force:true});}
    return {tag,state:'verified-existing'};
  }
  // Re-collect live proof immediately before the only publication mutation.
  const fresh=collect(reader,p);
  requireThat(canonical(fresh.record)===canonical(accepted.record),'Acceptance evidence changed during publication');
  requireThat(canonical(Object.keys(fresh.files).sort())===canonical(Object.keys(accepted.files).sort())&&Object.entries(fresh.files).every(([name,bytes])=>Buffer.isBuffer(accepted.files[name])&&bytesDigest(bytes)===bytesDigest(accepted.files[name])),'Captured publication bytes changed');
  checkTagGuard(reader,p.manifest);
  const paths=Object.entries(expected).map(([name,bytes])=>{const path=join(directory,name);writeFileSync(path,bytes);return path;});
  g.command(['release','create',tag,'--repo',CORE,'--target',p.candidate.commit,...(context.kind==='beta'?['--prerelease']:[]),'--title',tag,
    '--notes',`${context.channel} ${context.kind} accepted by all nine frozen targets. Candidate ${p.candidate.commit}; plan ${p.plan_id}. See acceptance.json for proof, exclusions and coverage limits.`,...paths]);
  return {tag,state:'created'};
}
