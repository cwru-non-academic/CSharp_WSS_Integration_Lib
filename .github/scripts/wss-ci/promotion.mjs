// One promotion publication engine. Adapters stage and verify language payloads.
import {execFileSync} from 'node:child_process';
import {readFileSync,appendFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {GitHub} from './github.mjs';
import {candidate,canonical,requireThat} from './verify.mjs';
const profiles=JSON.parse(readFileSync(new URL('./receipt-targets.json',import.meta.url),'utf8'));
const nativeGit=(root,args)=>{
  try{return execFileSync('git',['-C',root,...args],{encoding:'utf8',maxBuffer:32*1024*1024}).trim();}
  catch{throw new Error('Promotion Git operation failed or is uncertain; inspect remote state before retry.');}
};
export async function publishPromotion(c,{g=new GitHub(),writer=new GitHub(process.env.WSS_PUSH_TOKEN),git=nativeGit,env=process.env}={}) {
  const profile=profiles[c.target_id];requireThat(profile,'Unknown publication target');
  const t=profile.target,root=resolve(c.repository_root);
  requireThat(env.GITHUB_ACTIONS==='true' && env.GITHUB_REF==='refs/heads/dev' && env.GITHUB_REPOSITORY===t.repository && env.WSS_PUSH_TOKEN,'Publication requires trusted dev execution and delayed scoped token');
  candidate(c.candidate);
  const expectedBranch=profile.family==='csharp'?(profile.role==='wrapper'?`automation/wss-${c.candidate.run_id}-${c.candidate.sha256}`:`automation/integration-${c.parent_heads?.['cwru-non-academic/CSharp_WSS_Integration_Lib']}`):`automation/${profile.family}-wss-${c.candidate.run_id}-${c.candidate.sha256}`;
  requireThat(c.branch===expectedBranch && /^[a-f0-9]{40}$/.test(c.source_sha),'Publication branch/source differs from registered target');
  const checkout=git(root,['rev-parse','HEAD']);
  requireThat(checkout===c.source_sha || (c.precommitted===true && /^[a-f0-9]{40}$/.test(checkout)),'Publication checkout is not validated source');
  const paths=git(root,c.precommitted?['diff','--name-only','--no-renames',c.source_sha,'HEAD']:['diff','--cached','--name-only','--no-renames']).split(/\r?\n/).filter(Boolean);
  requireThat(paths.length>0,'No-op must not publish metadata-only PR');
  requireThat(Array.isArray(c.allowed_paths) && c.allowed_paths.every(p=>typeof p==='string'&&!p.split('/').includes('..')&&!p.startsWith('/')),'Invalid publication path descriptor');
  for(const path of paths) requireThat(c.allowed_paths.includes(path)||(c.target_id==='csharp-wrapper'&&path.startsWith('lib/')),'Staged changes escape reviewed promotion allowlist');
  requireThat(git(root,['diff','--name-only','--ignore-submodules=all'])==='','Unstaged changes outside intended promotion');
  git(root,['diff','--cached','--check']);
  for(const [path,sha] of Object.entries(c.gitlinks||{})) requireThat(git(root,['ls-files','--stage','--',path])===`160000 ${sha} 0\t${path}`,'Staged application entry is not the accepted gitlink');
  const tree=git(root,['write-tree']);
  const sourceCheck=()=>{
    requireThat(g.head(t.repository)===c.source_sha,'Target dev advanced; no stale publication');
    for(const [repo,sha] of Object.entries(c.parent_heads||{})) {requireThat(Object.values(profiles).some(p=>p.target.repository===repo),'Unregistered publication parent');requireThat(g.head(repo)===sha,'Accepted parent moved before publication');}
  };
  sourceCheck();
  const pulls=g.pages(`repos/${t.repository}/pulls?state=all&base=dev&head=${encodeURIComponent('cwru-non-academic:'+c.branch)}`);
  requireThat(pulls.length<=1 && (pulls.length===0 || pulls[0].state==='open'),'Ambiguous or closed/merged candidate PR; no replacement or rollback');
  const refs=g.get(`repos/${t.repository}/git/matching-refs/heads/${c.branch}`).filter(r=>r.ref===`refs/heads/${c.branch}`);
  requireThat(refs.length<=1,'Ambiguous automation branch');
  if(pulls.length) {
    const pr=pulls[0];requireThat(refs.length===1 && pr.head?.sha===refs[0].object.sha && (!c.precommitted||checkout===pr.head.sha) && pr.head?.repo?.full_name===t.repository && pr.base?.ref==='dev','Existing PR branch/source identity conflict');
    for(const marker of c.markers) requireThat((pr.body||'').split(/\r?\n/).filter(line=>line===marker).length===1,'Existing PR has missing/ambiguous approval metadata');
    const commit=g.get(`repos/${t.repository}/git/commits/${refs[0].object.sha}`);
    requireThat(commit.tree.sha===tree && commit.parents.length===1 && commit.parents[0].sha===c.source_sha,'Existing PR is not exact intended tree/source');
    return {reused:true,url:pr.html_url};
  }
  requireThat(refs.length===0,'Orphan candidate branch exists; inspect rather than overwrite');
  requireThat(!c.precommitted,'Precommitted branch without an exact existing PR requires inspection');
  sourceCheck();
  if(git(root,['branch','--show-current'])!==c.branch) git(root,['switch','-c',c.branch]);
  git(root,['-c','user.name=WSS promotion automation','-c','user.email=wss-promotion@users.noreply.github.com','commit','-m',c.commit_message]);
  sourceCheck();
  const header=Buffer.from('x-access-token:'+env.WSS_PUSH_TOKEN).toString('base64');console.log(`::add-mask::${header}`);
  git(root,['-c',`http.https://github.com/.extraheader=AUTHORIZATION: basic ${header}`,'-c','push.followTags=false','push','origin',`HEAD:refs/heads/${c.branch}`]);
  const url=writer.command(['pr','create','--repo',t.repository,'--base','dev','--head',c.branch,'--draft','--title',c.title,'--body-file',resolve(c.body_path)]).trim();
  if(env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY,`Promotion draft: ${url}\n`);
  return {reused:false,url};
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) console.log(JSON.stringify(await publishPromotion(JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,'')))));
