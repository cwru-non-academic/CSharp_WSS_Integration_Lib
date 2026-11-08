import {execFileSync} from 'node:child_process';
import {canonical,requireThat,bytesDigest} from './verify.mjs';
import {downloadVerifiedJsonArtifact,downloadVerifiedArtifactBytes} from './verified-json-artifact.mjs';
const id=x=>typeof x==='string'&&/^[1-9][0-9]*$/.test(x);
const same=(a,b)=>canonical(a)===canonical(b);
const fields=(x,keys)=>x&&same(Object.keys(x).sort(),[...keys].sort());
const ordered=xs=>[...xs].sort((a,b)=>canonical(a).localeCompare(canonical(b),'en'));
export function proofJobs(jobs) {
  requireThat(Array.isArray(jobs)&&jobs.length>0&&jobs.length<=512,'Missing/unbounded preflight jobs');
  const result=jobs.map(j=>({id:String(j.id),name:j.name,status:j.status,conclusion:j.conclusion}));
  requireThat(result.every(j=>id(j.id)&&typeof j.name==='string'&&j.name.length>0&&typeof j.status==='string'&&(j.conclusion===null||typeof j.conclusion==='string'))&&new Set(result.map(j=>j.id)).size===result.length,'Invalid/duplicate preflight job identity');
  return ordered(result);
}
function identity(run,d) {
  requireThat(String(run.id)===d.run_id&&run.run_attempt===d.attempt&&Number.isSafeInteger(d.attempt)&&d.attempt>=1&&run.repository?.full_name===d.repository&&run.head_repository?.full_name===d.repository&&run.path===d.workflow&&run.head_sha===d.source_sha&&['dev','main'].includes(run.head_branch)&&run.event==='workflow_dispatch'&&run.status==='completed'&&run.conclusion==='success','Preflight proved run/attempt changed');
}
export function proofDescriptor(d) {
  requireThat(fields(d,['repository','run_id','source_sha','workflow','attempt','jobs','artifacts','logs'])&&/^cwru-non-academic\/[A-Za-z0-9_]+$/.test(d.repository)&&id(d.run_id)&&/^[a-f0-9]{40}$/.test(d.source_sha)&&d.workflow==='.github/workflows/wss-preflight.yml'&&Number.isSafeInteger(d.attempt)&&d.attempt>=1,'Invalid authenticated native proof descriptor');
  requireThat(same(d.jobs,proofJobs(d.jobs))&&d.jobs.every(j=>fields(j,['id','name','status','conclusion'])),'Noncanonical native job snapshot');
  requireThat(Array.isArray(d.artifacts)&&d.artifacts.length>0&&d.artifacts.length<=64&&same(d.artifacts,ordered(d.artifacts))&&new Set(d.artifacts.map(a=>a.id)).size===d.artifacts.length&&new Set(d.artifacts.map(a=>a.name)).size===d.artifacts.length&&d.artifacts.every(a=>fields(a,['id','name','digest'])&&id(a.id)&&typeof a.name==='string'&&a.name.length>0&&/^sha256:[a-f0-9]{64}$/.test(a.digest)),'Invalid/duplicate native artifact bindings');
  requireThat(Array.isArray(d.logs)&&d.logs.length<=32&&same(d.logs,ordered(d.logs))&&new Set(d.logs.map(l=>l.job_id)).size===d.logs.length&&d.logs.every(l=>fields(l,['job_id','sha256'])&&d.jobs.some(j=>j.id===l.job_id)&&/^[a-f0-9]{64}$/.test(l.sha256)),'Invalid native log bindings');
  return d;
}
function artifact(g,d,name,expected) {
  const matches=g.pages(`repos/${d.repository}/actions/runs/${d.run_id}/artifacts`,'artifacts').filter(a=>a.name===name);
  requireThat(matches.length===1&&matches[0].expired===false,'Missing/duplicate/expired native artifact');
  const a=g.get(`repos/${d.repository}/actions/artifacts/${matches[0].id}`);
  requireThat(String(a.id)===String(matches[0].id)&&a.name===name&&a.expired===false&&String(a.workflow_run?.id)===d.run_id&&a.workflow_run?.head_sha===d.source_sha&&/^sha256:[a-f0-9]{64}$/.test(a.digest),'Native artifact owner/source/digest mismatch');
  const binding={id:String(a.id),name:a.name,digest:a.digest};
  requireThat(!expected||same(binding,expected),'Native artifact replaced since rich validation');
  return {metadata:a,binding};
}
export function startPreflightProof(g,{repository,run_id,source_sha,attempt}) {
  const d={repository,run_id,source_sha,attempt,workflow:'.github/workflows/wss-preflight.yml',jobs:[],artifacts:[],logs:[]};
  requireThat(/^cwru-non-academic\/[A-Za-z0-9_]+$/.test(repository)&&id(run_id)&&/^[a-f0-9]{40}$/.test(source_sha)&&Number.isSafeInteger(attempt)&&attempt>=1,'Invalid observed preflight identity');
  const run=g.run(repository,run_id);identity(run,d);
  const jobs=g.jobs(repository,run);d.jobs=proofJobs(jobs);
  identity(g.run(repository,run_id),d);
  return {descriptor:d,run,jobs};
}
export function capturePreflightArtifact(g,state,name) {
  identity(g.run(state.descriptor.repository,state.descriptor.run_id),state.descriptor);
  const {metadata,binding}=artifact(g,state.descriptor,name);
  requireThat(!state.descriptor.artifacts.some(a=>a.id===binding.id||a.name===name),'Repeated native artifact capture');
  const bytes=downloadVerifiedArtifactBytes(g,state.descriptor.repository,metadata);
  artifact(g,state.descriptor,name,binding);
  state.descriptor.artifacts=ordered([...state.descriptor.artifacts,binding]);
  return bytes;
}
export function jobLogBytes(g,repository,jobId) {
  const bytes=g.jobLogBytes?g.jobLogBytes(repository,jobId):execFileSync('gh',['api',`repos/${repository}/actions/jobs/${jobId}/logs`],{env:g.environment,maxBuffer:64*1024*1024});
  requireThat(Buffer.isBuffer(bytes)&&bytes.length<=64*1024*1024,'Invalid bounded job log bytes');return bytes;
}
export function capturePreflightLog(g,state,jobId) {
  const d=state.descriptor;
  requireThat(id(jobId)&&d.jobs.some(j=>j.id===jobId)&&!d.logs.some(l=>l.job_id===jobId),'Native log job not in observed attempt');
  const bytes=jobLogBytes(g,d.repository,jobId);
  d.logs=ordered([...d.logs,{job_id:jobId,sha256:bytesDigest(bytes)}]);return bytes;
}
export function collectPreflightProof(g,d) {
  proofDescriptor(d);
  const run=g.run(d.repository,d.run_id);identity(run,d);
  const jobs=proofJobs(g.jobs(d.repository,run));requireThat(same(jobs,d.jobs),'Native proved attempt job snapshot changed');
  const artifacts=d.artifacts.map(expected=>{
    const {metadata,binding}=artifact(g,d,expected.name,expected);
    downloadVerifiedArtifactBytes(g,d.repository,metadata);
    artifact(g,d,expected.name,expected);return binding;
  });
  const logs=d.logs.map(l=>({job_id:l.job_id,sha256:bytesDigest(jobLogBytes(g,d.repository,l.job_id))}));
  requireThat(same(logs,d.logs),'Native proved job log changed');
  identity(g.run(d.repository,d.run_id),d);
  requireThat(same(proofJobs(g.jobs(d.repository,run)),d.jobs),'Native proved jobs changed during collection');
  return {run,jobs,artifacts,logs};
}
export function verifyPreflightProof(d,e) {
  proofDescriptor(d);identity(e.run,d);
  requireThat(same(e.jobs,d.jobs)&&same(e.artifacts,d.artifacts)&&same(e.logs,d.logs),'Native proof binding differs from independent collection');
}

export function preflightCandidate(g,d) {
  const {metadata,binding}=artifact(g,d,'wss-candidate-provenance');
  const candidate=JSON.parse(downloadVerifiedJsonArtifact(g,d.repository,metadata,['candidate.json'])['candidate.json']);
  artifact(g,d,'wss-candidate-provenance',binding);return candidate;
}
