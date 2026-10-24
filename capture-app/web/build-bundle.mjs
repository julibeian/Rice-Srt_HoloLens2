import { readFile, writeFile } from 'node:fs/promises';
const core = await readFile(new URL('./capture-core.mjs', import.meta.url), 'utf8');
const app = await readFile(new URL('./app.mjs', import.meta.url), 'utf8');
const bundle = `/* Standalone browser client. Regenerate with node build-bundle.mjs. */\n(function () {\n'use strict';\n${core.replace(/^export /gm, '')}\n${app.replace(/^import .*?;\r?\n/, '')}\n})();\n`;
await writeFile(new URL('./app.bundle.js', import.meta.url), bundle, 'utf8');
console.log('app.bundle.js generated');
