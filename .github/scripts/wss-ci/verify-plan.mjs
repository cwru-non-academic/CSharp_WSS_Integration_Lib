import {readFileSync} from 'node:fs';
import {plan} from './verify.mjs';

// Same plan/schema/digest policy as the Core coordinator; no second hasher.
if (process.argv.length !== 3) throw new Error('Usage: node verify-plan.mjs plan.json');
plan(JSON.parse(readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, '')));
