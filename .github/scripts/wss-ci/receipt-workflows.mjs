// Integration owns receiver workflow shape; Core distributes the immutable source.
import {readFileSync} from 'node:fs';
import {requireThat} from './verify.mjs';
export const receiptProfiles=JSON.parse(readFileSync(new URL('./receipt-targets.json',import.meta.url),'utf8'));
export function renderReceiptWorkflow(id,{core,engine,validator}) {
  const p=receiptProfiles[id];
  requireThat(p&&[core,engine,validator].every(x=>typeof x==='string'&&/^[a-f0-9]{40}$/.test(x)),'Receipt renderer requires known target and immutable pins');
  const wrapper=receiptProfiles[p.wrapper],app=p.role!=='wrapper';
  requireThat(app||validator===engine,'Wrapper receipt has no separate validator pin; use the engine identity');
  const values={ID:id,REPOSITORY:p.target.repository,WRAPPER:wrapper.target.repository,CORE:core,ENGINE:engine,VALIDATOR:validator,VALIDATOR_REF:app?validator:'${{ github.sha }}',IS_APP:String(app),RUNNER:p.receipt.runner,TIMEOUT:String(p.receipt.timeout_minutes),READ_REPOSITORIES:p.receipt.read_repositories.join(','),TOOLS:p.receipt.adapter_owner==='receiver'?'accepted':app?'validator':'accepted',VALIDATOR_ROOT:app?'validator':'accepted',INTEGRATION_ROOT:app?'integration':'accepted'};
  const text=readFileSync(new URL('./receipt-workflow.yml',import.meta.url),'utf8').replace(/\r\n/g,'\n').replace(/__WSS_([A-Z_]+)__/g,(_,key)=>{requireThat(Object.hasOwn(values,key),'Unknown receipt template field');return values[key];});
  requireThat(!text.includes('__WSS_'),'Unresolved receipt template field');
  return {path:'.github/workflows/release-receipt.yml',text};
}
