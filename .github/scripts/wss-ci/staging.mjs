// Common producer-policy interpretation for all four fanout adapters.
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {canonical,requireThat} from './verify.mjs';
const targets=JSON.parse(readFileSync(new URL('./staging-targets.json',import.meta.url),'utf8'));
export function stagingPolicy({tree,file,receiver,family}) {
  const expected=targets[family];requireThat(expected,'Unknown staged receiver');
  requireThat(receiver.schema==='wss-dev-stage-receiver/v1' && receiver.core_workflow==='.github/workflows/dev-propagation.yml' && receiver.staged_applications===true && receiver.fanout_workflow===expected.fanout && canonical([...receiver.applications].sort())===canonical([...expected.applications].sort()),'Invalid staged receiver declaration');
  requireThat(tree.truncated===false && Array.isArray(tree.tree) && /^[a-f0-9]{40}$/.test(tree.sha),'Complete verified producer tree required; lookup failure is never policy absence');
  const entries=tree.tree.filter(e=>e.path==='tools/ci/dev-propagation.json');
  if(entries.length===0) {requireThat(file===null || file===undefined,'Unexpected policy outside producer tree');return false;}
  requireThat(entries.length===1 && entries[0].type==='blob' && /^[a-f0-9]{40}$/.test(entries[0].sha),'Ambiguous/invalid immutable producer policy');
  requireThat(file?.type==='file' && file.encoding==='base64' && file.sha===entries[0].sha,'Producer policy content/tree identity mismatch');
  const policy=JSON.parse(Buffer.from(file.content,'base64').toString('utf8'));
  const matches=policy.libraries?.filter(t=>t.id===family);
  requireThat(policy.schema==='wss-dev-stage/v1' && policy.channel==='dev' && matches?.length===1,'Unsupported producer staging policy');
  const target=matches[0];
  requireThat(target.repository===expected.repository && target.fanout===expected.fanout && canonical([...target.applications].sort())===canonical([...expected.applications].sort()),'Producer staging policy does not match receiver');
  return true;
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) console.log(JSON.stringify(stagingPolicy(JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,'')))));
