import {readFileSync} from 'node:fs';
import {isEntrypoint} from './entrypoint.mjs';
import {CORE_JOBS,jobs,requireThat} from './verify.mjs';

// Legacy payload inspection remains explicit. Current propagation must select
// macos-ble-v1 and therefore all current producer gates, including aggregates.
export function requiredProducerJobs(contract) {
  requireThat(['legacy-v1','macos-ble-v1'].includes(contract),'Unknown producer payload contract');
  if(contract==='macos-ble-v1') return [...CORE_JOBS];
  const added=['Build macOS universal BLE bridge','BLE consumer (macOS arm64)','BLE consumer (macOS x86_64)',
    'BLE Consumer for Windows','BLE Consumer for Linux','BLE Consumer for Mac'];
  return CORE_JOBS.filter(name=>!added.includes(name));
}
export function assertProducerJobs(actual,contract) { jobs(actual,requiredProducerJobs(contract)); }
if(isEntrypoint(import.meta.url)) {
  requireThat(process.argv.length===3,'Usage: producer-jobs.mjs context.json');
  const context=JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
  assertProducerJobs(context.jobs,context.contract);
}
