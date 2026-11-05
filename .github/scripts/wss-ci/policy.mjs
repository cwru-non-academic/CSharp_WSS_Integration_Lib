import {CORE,canonical,digest,requireThat} from './verify.mjs';

// Hash only complete policy fields that determine protection, never timestamps.
// No wildcard interpretation: accept the exact reviewed all-legacy-v-tag pattern.
export function tagPolicy(r) {
  requireThat(r && String(r.id).match(/^[1-9][0-9]*$/),'Missing tag ruleset identity');
  requireThat(r.target==='tag' && r.enforcement==='active','Legacy guard must be an active tag ruleset');
  requireThat(r.source_type==='Repository' && r.source===CORE,'Legacy guard must be this repository policy');
  requireThat(canonical(r.conditions)===canonical({ref_name:{include:['refs/tags/v*'],exclude:[]}}),'Legacy tag guard must cover every v* tag without exclusions');
  requireThat(Array.isArray(r.bypass_actors) && r.bypass_actors.length===0,'Legacy tag guard cannot have bypass actors or hidden bypass metadata');
  requireThat(Array.isArray(r.rules) && canonical([...r.rules].sort((a,b)=>a.type.localeCompare(b.type)))===canonical([{type:'creation'},{type:'deletion'},{type:'update'}]),'Legacy tag creation, update and deletion must all be prohibited without extra parameters');
  return {id:String(r.id),target:r.target,enforcement:r.enforcement,source_type:r.source_type,source:r.source,
    conditions:r.conditions,bypass_actors:r.bypass_actors,rules:[...r.rules].sort((a,b)=>a.type.localeCompare(b.type))};
}
export function checkTagGuard(g,m) {
  const guard=m.legacy_tag_guard;
  requireThat(guard && typeof guard.ruleset_id==='string' && /^[1-9][0-9]*$/.test(guard.ruleset_id) && /^[0-9a-f]{64}$/.test(guard.policy_sha256 || ''),'Legacy historical-tag protection is unconfigured; publication is blocked');
  const policy=tagPolicy(g.get(`repos/${CORE}/rulesets/${guard.ruleset_id}`));
  requireThat(policy.id===guard.ruleset_id && digest(policy)===guard.policy_sha256,'Legacy tag protection changed from reviewed policy');
  return {ruleset_id:policy.id,policy_sha256:digest(policy)};
}
