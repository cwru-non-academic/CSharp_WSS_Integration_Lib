// Branch/release identity shared by Core and all receiver adapters. Publication
// permission remains a separate, explicit gate; channel selection cannot grant it.
import {isEntrypoint} from './entrypoint.mjs';
export function channelContext(value) {
  if(!['dev','main'].includes(value))throw Error('CI channel must be exactly dev or main');
  const stable=value==='main';
  return Object.freeze({channel:value,branch:value,ref:`refs/heads/${value}`,kind:stable?'stable':'beta',
    manifestSchema:stable?'wss-required-targets/v2':'wss-required-targets/v1',
    planSchema:stable?'wss-propagation-plan/v2':'wss-propagation-plan/v1',
    receiptSchema:stable?'wss-acceptance-receipt/v2':'wss-acceptance-receipt/v1',
    acceptanceSchema:stable?'wss-release-acceptance/v2':'wss-release-acceptance/v1',
    stageSchema:stable?'wss-main-stage/v1':'wss-dev-stage/v1',
    stagePlanSchema:stable?'wss-main-propagation-plan/v1':'wss-dev-propagation-plan/v1',
    receiverSchema:stable?'wss-main-stage-receiver/v1':'wss-dev-stage-receiver/v1',
    receiverPolicy:`.github/${value}-propagation.json`,
    targetPolicy:`tools/release/targets.${value}.json`,stagePolicy:`tools/ci/${value}-propagation.json`,
    stageWorkflow:`.github/workflows/${value}-propagation.yml`,acceptanceWorkflow:`.github/workflows/${value}-release.yml`,
    stageArtifact:stable?'wss-main-propagation-plan':'wss-dev-propagation-plan'});
}
export function targetForChannel(target,value) {const context=channelContext(value);return {...target,branch:context.branch};}
export function integrationConfiguration(family) {
  const paths={csharp:'.github/universal-bootstrap.json',unity:'.github/unity-ci.json',python:'.github/python-ci.json',matlab:'.github/matlab-ci.json'};
  if(!Object.hasOwn(paths,family))throw Error('Unknown integration configuration role');
  return paths[family];
}
export function releaseFingerprint(value,run,planId) {
  const c=channelContext(value);
  if(!/^[1-9][0-9]*$/.test(run)||!/^[a-f0-9]{64}$/.test(planId))throw Error('Fingerprint requires exact producer and frozen plan identities');
  return `${c.channel==='dev'?'dev-beta':'main-stable'}-${run}-${planId.slice(0,12)}`;
}
// macOS temporary paths can name /var while Node canonicalizes the loaded
// module to /private/var. Imported assertion sentinels are not filesystem paths.
if(isEntrypoint(import.meta.url))console.log(JSON.stringify(channelContext(process.argv[2])));
