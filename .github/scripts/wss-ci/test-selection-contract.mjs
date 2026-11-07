// Pure test-source contract shared by Core and synchronized receiver tooling.
import {canonical,digest,requireThat} from './verify.mjs';
import {channelContext} from './channels.mjs';

export const TEST_VARIABLES = Object.freeze({enabled:'WSS_USE_PIN_TESTS',repository:'WSS_PIN_TEST_REPOSITORY',commit:'WSS_PIN_TEST_COMMIT'});
const sha = value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);
const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const repository = value => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(value) && !value.includes('..') && !value.endsWith('.git');
const same = (a,b) => canonical(a) === canonical(b);
const keys = (value,expected) => value && typeof value === 'object' && !Array.isArray(value) && same(Object.keys(value).sort(),[...expected].sort());
function request(value) {
  requireThat(keys(value,['channel','campaign','targets']),'Test selection request must have exactly channel, campaign and targets');
  channelContext(value.channel);
  const c=value.campaign;
  requireThat(keys(c,['repository','commit','run_id']) && repository(c.repository) && sha(c.commit) && typeof c.run_id==='string' && /^[1-9][0-9]*$/.test(c.run_id),'Invalid immutable campaign identity');
  requireThat(Array.isArray(value.targets) && value.targets.length>0,'Test selection needs explicit targets');
  const ids=new Set(),repos=new Set();
  for(const t of value.targets) {
    requireThat(keys(t,['id','repository','default_test_repository','allowed_test_repositories','variables']),'Unexpected test target fields');
    requireThat(typeof t.id==='string' && /^[a-z][a-z0-9-]*$/.test(t.id) && repository(t.repository) && !ids.has(t.id) && !repos.has(t.repository),'Invalid or duplicate test target');
    ids.add(t.id);repos.add(t.repository);
    requireThat(Array.isArray(t.allowed_test_repositories) && t.allowed_test_repositories.length>0 && t.allowed_test_repositories.every(repository) && new Set(t.allowed_test_repositories).size===t.allowed_test_repositories.length && t.allowed_test_repositories.includes(t.default_test_repository),'Test sources must belong to an explicit reviewed repository allowlist');
    requireThat(t.variables && typeof t.variables==='object' && !Array.isArray(t.variables) && Object.keys(t.variables).every(k=>Object.values(TEST_VARIABLES).includes(k)) && Object.values(t.variables).every(v=>typeof v==='string'),'Invalid repository variable snapshot');
  }
  return value;
}
export function validateTestSelection(selection,expected) {
  request(expected);
  requireThat(keys(selection,['schema','channel','campaign','targets','selection_id']) && selection.schema==='wss-test-selection/v1','Unsupported test selection');
  const {selection_id,...body}=selection;
  requireThat(hash(selection_id) && digest(body)===selection_id,'Test selection digest mismatch');
  requireThat(selection.channel===expected.channel && same(selection.campaign,expected.campaign),'Test selection belongs to another campaign/channel');
  requireThat(keys(selection.targets,expected.targets.map(t=>t.id)),'Missing or extra selected test targets');
  for(const t of expected.targets) {
    const s=selection.targets[t.id];
    requireThat(keys(s,['repository','mode','requested_ref','tests']) && s.repository===t.repository && keys(s.tests,['repository','commit']) && t.allowed_test_repositories.includes(s.tests.repository) && sha(s.tests.commit),'Invalid selected test source');
    requireThat((s.mode==='latest' && s.tests.repository===t.default_test_repository && s.requested_ref===`refs/heads/${expected.channel}`) || (s.mode==='pinned' && s.requested_ref===s.tests.commit),'Invalid test selection mode/ref');
  }
  return selection;
}

// Call once at campaign creation, with repository variable snapshots from trusted
// inputs. The cache freezes a shared branch once even when several targets use it.
export function resolveTestSelection(input,g) {
  request(input);
  const cache=new Map(),targets={};
  for(const t of input.targets) {
    const flag=t.variables[TEST_VARIABLES.enabled] ?? '';
    requireThat(['','false','true'].includes(flag),`${TEST_VARIABLES.enabled} must be true, false or unset`);
    const pinned=flag==='true';
    const repo=pinned?t.variables[TEST_VARIABLES.repository]:t.default_test_repository;
    const ref=pinned?t.variables[TEST_VARIABLES.commit]:`refs/heads/${input.channel}`;
    requireThat(t.allowed_test_repositories.includes(repo),'Pinned test repository is missing or outside the reviewed allowlist');
    requireThat(!pinned || sha(ref),'Enabled test pin requires a full immutable commit SHA');
    const key=JSON.stringify([repo,ref]);
    if(!cache.has(key)) {
      const commit=pinned?g.get(`repos/${repo}/git/commits/${ref}`).sha:g.head(repo,input.channel);
      requireThat(sha(commit) && (!pinned || commit===ref),'Test source did not resolve to the requested immutable commit');
      cache.set(key,commit);
    }
    targets[t.id]={repository:t.repository,mode:pinned?'pinned':'latest',requested_ref:ref,tests:{repository:repo,commit:cache.get(key)}};
  }
  const body={schema:'wss-test-selection/v1',channel:input.channel,campaign:input.campaign,targets};
  return validateTestSelection({...body,selection_id:digest(body)},input);
}

// A digest is not authenticity. expectedSelectionId must come from the verified
// frozen campaign plan, never from the artifact being checked or current settings.
export function verifyTestSelection(selection,expected,expectedSelectionId) {
  requireThat(hash(expectedSelectionId) && selection?.selection_id===expectedSelectionId,'Test selection differs from the frozen campaign plan');
  return validateTestSelection(selection,expected);
}

// This assertion is additional evidence, not a substitute for existing product,
// workflow, producer, artifact, coverage, approval or release-receipt validation.
export function verifySelectedTestEvidence(selection,expected,expectedSelectionId,targetId,evidence) {
  verifyTestSelection(selection,expected,expectedSelectionId);
  const target=selection.targets[targetId];
  requireThat(target && keys(evidence,['selection_id','target_id','repository','test_repository','test_commit']),'Invalid selected-test evidence');
  requireThat(evidence.selection_id===selection.selection_id && evidence.target_id===targetId && evidence.repository===target.repository && evidence.test_repository===target.tests.repository && evidence.test_commit===target.tests.commit,'Evidence did not execute the frozen test source');
  return evidence;
}

