// Genera el sitio para GitHub Pages (carpeta docs/) a partir de index.html:
//   docs/index.html       -> modo real con Supabase (llaves en config.real.json)
//   docs/demo/index.html  -> modo demostración (datos en el navegador, cuentas de prueba)
//   docs/tcg/ y docs/demo/tcg/ -> CharreríaTCG: la misma app con SITE 'tcg', comparte datos y sesión
// Uso: node build.mjs
import { readFileSync, writeFileSync, mkdirSync, existsSync, cpSync } from 'node:fs';

const src = readFileSync('index.html', 'utf8');
const CONFIG_RE = /const CONFIG = \{[^\n]*\};/;
if (!CONFIG_RE.test(src)) throw new Error('No encontré la línea "const CONFIG = {...};" en index.html');

const build = (dir, cfg) => {
  const line = `const CONFIG = ${JSON.stringify({ APP_NAME: 'Charrería Pro', ...cfg })};`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/index.html`, src.replace(CONFIG_RE, () => line));
  console.log(`✔ ${dir}/index.html (${cfg.MODE})`);
};

mkdirSync('docs', { recursive: true });
writeFileSync('docs/.nojekyll', '');
cpSync('formatos', 'docs/formatos', { recursive: true });   // formatos oficiales para los PDF de escaramuzas
cpSync('fotos-demo', 'docs/demo/fotos', { recursive: true });   // imágenes de ejemplo: solo existen en el demo
build('docs/demo', { MODE: 'demo', SUPABASE_URL: '', SUPABASE_ANON_KEY: '' });
build('docs/demo/tcg', { MODE: 'demo', SITE: 'tcg', SUPABASE_URL: '', SUPABASE_ANON_KEY: '' });

if (!existsSync('config.real.json')) { console.error('✘ Falta config.real.json; no se generó la versión real'); process.exit(1); }
const real = JSON.parse(readFileSync('config.real.json', 'utf8'));
if (!real.SUPABASE_URL || !real.SUPABASE_ANON_KEY || real.SUPABASE_URL.includes('TU-PROYECTO')) {
  console.error('✘ Llena SUPABASE_URL y SUPABASE_ANON_KEY en config.real.json; no se generó la versión real'); process.exit(1);
}
build('docs', { ...real, MODE: 'real' });
build('docs/tcg', { ...real, MODE: 'real', SITE: 'tcg' });
