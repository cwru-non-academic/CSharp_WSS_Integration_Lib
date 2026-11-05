import {execFileSync} from 'node:child_process';
import {mkdtempSync,readdirSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {allClear,bytesDigest,candidate,canonical,CORE,digest,manifest,plan,producer,requireThat} from './verify.mjs';
import {checkTagGuard} from './policy.mjs';
import {findNormalRuns} from './normal-ci.mjs';

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
    return this.get(`repos/${repo}/actions/artifacts/${all[0].id}`);
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

export function freeze(g,m,c,{verificationOnly=false}={}) {
  manifest(m); candidate(c);
  const guard=m.legacy_tag_guard;
  const unconfigured=guard?.ruleset_id===null && guard?.policy_sha256===null;
  if(!verificationOnly || !unconfigured) checkTagGuard(g,m);
  const target_snapshots={};
  for(const t of m.targets) {
    const head_sha=g.head(t.repository);
    const trusted=Object.fromEntries(t.trusted_paths.map(path=>[path,g.object(t.repository,head_sha,path).sha]));
    // The receipt workflow must also be registered on the default branch.
    const w=g.get(`repos/${t.repository}/actions/workflows/release-receipt.yml`);
    requireThat(w.path==='.github/workflows/release-receipt.yml' && w.state==='active',`Receipt workflow unavailable: ${t.id}`);
    target_snapshots[t.id]={head_sha,trusted};
  }
  const body={schema:'wss-propagation-plan/v1',channel:'dev',candidate:c,manifest:m,manifest_sha256:digest(m),target_snapshots};
  return plan({...body,plan_id:digest(body)});
}
export function loadPlan(g,runId) {
  requireThat(/^[1-9][0-9]*$/.test(runId),'Invalid producer run');
  const data=g.download(CORE,runId,'wss-propagation-plan',['plan.json']);
  const p=plan(JSON.parse(data['plan.json']));
  requireThat(p.candidate.run_id===runId,'Plan came from another producer run');
  const r=g.run(CORE,runId);
  requireThat(r.repository?.full_name===CORE && r.path==='.github/workflows/artifacts.yml' && r.event==='push' && r.head_branch==='dev' && r.head_sha===p.candidate.commit,'Plan artifact producer is not canonical');
  const policy=g.get(`repos/${CORE}/contents/tools/release/targets.dev.json?ref=${p.candidate.commit}`);
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
  return {artifact:a,files};
}
export function collect(g,p) {
  plan(p);
  const c=p.candidate, source=g.run(CORE,c.run_id), zip=archive(g,c);
  const evidence={producer:{run:source,current_head:g.head(CORE),jobs:g.jobs(CORE,source),artifact:zip.artifact,archive_sha256:bytesDigest(zip.files[c.archive])},targets:{}};
  for(const t of p.manifest.targets) {
    const runs=g.pages(`repos/${t.repository}/actions/workflows/release-receipt.yml/runs?branch=dev`,'workflow_runs');
    const matches=[];
    for(const emitter of runs) {
      const name=`wss-acceptance-${t.id}-${p.plan_id}-a${emitter.run_attempt}`;
      const artifacts=g.pages(`repos/${t.repository}/actions/runs/${emitter.id}/artifacts`,'artifacts').filter(a=>a.name===name);
      if(artifacts.length) matches.push({emitter,name});
    }
    requireThat(matches.length===1,`Missing or ambiguous actual acceptance receipt for ${t.id}`);
    const {emitter,name}=matches[0];
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
    const preflights=(r.preflights || []).map(d=>({run:g.run(d.repository,d.run_id),candidate:JSON.parse(g.download(d.repository,d.run_id,'wss-candidate-provenance',['candidate.json'])['candidate.json'])}));
    evidence.targets[t.id]={receipt:r,receipt_bytes,receipt_sha256:bytesDigest(receipt_bytes),pr,current_head:g.head(t.repository),
      merge_tree:g.tree(t.repository,r.merge.sha),tested_tree:g.tree(t.repository,normal.head_sha),
      trusted:Object.fromEntries(t.trusted_paths.map(path=>[path,g.object(t.repository,r.merge.sha,path).sha])),
      parent_gitlinks,normal_run:normal,normal_latest_run_id:String(normals[0].id),normal_jobs:g.jobs(t.repository,normal),
      emitter_run:g.run(t.repository,String(emitter.id)),artifact:g.artifact(t.repository,String(emitter.id),name),preflights};
  }
  return {record:allClear(p,evidence),files:zip.files};
}

export function publish(g,p,accepted,directory,reader=g) {
  const legacy_tag_guard=checkTagGuard(reader,p.manifest);
  const tag=`dev-beta-${p.candidate.run_id}-${p.plan_id.slice(0,12)}`;
  const record={...accepted.record,tag,legacy_tag_guard};
  const expected={...accepted.files,'plan.json':Buffer.from(canonical(p)+'\n'),'acceptance.json':Buffer.from(canonical(record)+'\n')};
  // Existing tag/release state is read first. An API error is not interpreted as absence.
  const tags=g.pages(`repos/${CORE}/git/matching-refs/tags/${tag}`);
  const exact=tags.filter(t=>t.ref===`refs/tags/${tag}`);
  const releases=g.pages(`repos/${CORE}/releases`).filter(r=>r.tag_name===tag);
  requireThat(exact.length<=1 && releases.length<=1,'Ambiguous existing tag/release');
  if(exact.length || releases.length) {
    requireThat(exact.length===1 && releases.length===1 && exact[0].object.type==='commit' && exact[0].object.sha===p.candidate.commit && releases[0].prerelease===true && releases[0].draft===false,'Existing tag/release is incomplete or mismatched; inspect before recovery');
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
  checkTagGuard(reader,p.manifest);
  const paths=Object.entries(expected).map(([name,bytes])=>{const path=join(directory,name);writeFileSync(path,bytes);return path;});
  g.command(['release','create',tag,'--repo',CORE,'--target',p.candidate.commit,'--prerelease','--title',tag,
    '--notes',`Dev beta accepted by all nine frozen targets. Candidate ${p.candidate.commit}; plan ${p.plan_id}. See acceptance.json for proof, exclusions and coverage limits.`,...paths]);
  return {tag,state:'created'};
}
