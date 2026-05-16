export function css() {
  return `
:root{
  --ink:#1d1d1f;
  --text:#1d1d1f;
  --muted:#6e6e73;
  --subtle:#86868b;
  --bg:#fbfbfd;
  --paper:#ffffff;
  --tint:#0071e3;
  --tint-hover:#0077ed;
  --tint-soft:rgba(0,113,227,.10);
  --bubble-blue:#0a84ff;
  --bubble-grey:#e9e9eb;
  --line:#d2d2d7;
  --line-soft:#f0f0f3;
  --code-bg:#1d1d1f;
  --code-fg:#f5f5f7;
  --code-inline-fg:#1d1d1f;
  --hl-comment:#9ca3af;
  --hl-keyword:#93c5fd;
  --hl-string:#86efac;
  --hl-number:#fbbf24;
  --hl-literal:#c4b5fd;
  --hl-key:#67e8f9;
  --hl-variable:#f0abfc;
  --hl-option:#fda4af;
  --pill-border:#d2d2d7;
  --shadow-card:0 1px 2px rgba(0,0,0,.04),0 6px 24px rgba(0,0,0,.06);
  --scrollbar:#c7c7cc;
  --radius-lg:18px;
  --radius-md:12px;
  --radius-sm:8px;
}
:root[data-theme="dark"]{
  --ink:#f5f5f7;
  --text:#e8e8ed;
  --muted:#a1a1a6;
  --subtle:#6e6e73;
  --bg:#000000;
  --paper:#1c1c1e;
  --tint:#0a84ff;
  --tint-hover:#409cff;
  --tint-soft:rgba(10,132,255,.16);
  --bubble-blue:#0a84ff;
  --bubble-grey:#2c2c2e;
  --line:#2c2c2e;
  --line-soft:#1c1c1e;
  --code-bg:#0a0a0a;
  --code-fg:#f5f5f7;
  --code-inline-fg:#f5f5f7;
  --hl-comment:#8b949e;
  --hl-keyword:#79c0ff;
  --hl-string:#a5d6ff;
  --hl-number:#ffa657;
  --hl-literal:#d2a8ff;
  --hl-key:#7ee787;
  --hl-variable:#ff7b72;
  --hl-option:#f2cc60;
  --pill-border:#2c2c2e;
  --shadow-card:0 1px 2px rgba(0,0,0,.4),0 8px 28px rgba(0,0,0,.5);
  --scrollbar:#3a3a3c;
}
:root{color-scheme:light}
:root[data-theme="dark"]{color-scheme:dark}
*{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:24px;-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","SF Pro Display","Inter",ui-sans-serif,system-ui,Segoe UI,sans-serif;line-height:1.6;overflow-x:hidden;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;font-feature-settings:"ss01","ss02","cv11";letter-spacing:-0.003em;transition:background-color .25s ease,color .25s ease}
::selection{background:var(--tint);color:#fff}
a{color:var(--tint);text-decoration:none;transition:color .15s ease}
a:hover{color:var(--tint-hover)}
.shell{display:grid;grid-template-columns:280px minmax(0,1fr);min-height:100vh}
.sidebar{position:sticky;top:0;height:100vh;overflow:auto;padding:28px 22px 32px;background:var(--paper);border-right:1px solid var(--line);scrollbar-width:thin;scrollbar-color:var(--line) transparent;transition:background-color .25s ease,border-color .25s ease;backdrop-filter:saturate(180%) blur(20px);-webkit-backdrop-filter:saturate(180%) blur(20px)}
.sidebar::-webkit-scrollbar{width:6px}
.sidebar::-webkit-scrollbar-thumb{background:var(--line);border-radius:6px}
.sidebar-head{display:flex;align-items:center;gap:10px;margin-bottom:24px}
.brand{display:flex;align-items:center;gap:12px;color:var(--ink);text-decoration:none;flex:1;min-width:0}
.brand:hover{color:var(--ink)}
.brand .mark{display:flex;align-items:center;justify-content:center;flex:0 0 32px;height:32px;width:32px;border-radius:9px;background:linear-gradient(135deg,#34c759 0%,#0a84ff 60%,#5e5ce6 100%);box-shadow:0 1px 1px rgba(0,0,0,.05),0 4px 10px rgba(10,132,255,.25)}
.brand .mark svg{width:18px;height:18px;color:#fff}
.brand strong{display:block;font-size:1.05rem;line-height:1.1;font-weight:600;letter-spacing:-0.01em;color:var(--ink)}
.brand small{display:block;color:var(--muted);font-size:.74rem;margin-top:3px;font-weight:400;letter-spacing:0}
.theme-toggle{display:inline-flex;align-items:center;justify-content:center;flex:0 0 auto;width:34px;height:34px;border-radius:50%;border:1px solid var(--line);background:var(--paper);color:var(--muted);cursor:pointer;padding:0;transition:border-color .15s ease,color .15s ease,background-color .18s ease,transform .12s ease}
.theme-toggle:hover{border-color:var(--ink);color:var(--ink)}
.theme-toggle:active{transform:scale(.92)}
.theme-toggle svg{width:16px;height:16px;display:block}
.theme-icon-sun{display:none}
:root[data-theme="dark"] .theme-icon-sun{display:block}
:root[data-theme="dark"] .theme-icon-moon{display:none}
.search{display:block;margin:0 0 22px}
.search span{display:block;color:var(--muted);font-size:.7rem;font-weight:600;text-transform:uppercase;letter-spacing:.04em;margin-bottom:7px}
.search input{width:100%;border:1px solid var(--line);background:var(--paper);border-radius:10px;padding:9px 14px;font:inherit;font-size:.92rem;color:var(--text);outline:none;transition:border-color .15s ease,box-shadow .15s ease,background-color .18s ease}
.search input::placeholder{color:var(--subtle)}
.search input:focus{border-color:var(--tint);box-shadow:0 0 0 4px var(--tint-soft)}
nav section{margin:0 0 18px}
nav h2{font-size:.7rem;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin:0 0 6px;font-weight:600}
.nav-link{display:block;color:var(--text);text-decoration:none;border-radius:7px;padding:6px 11px;margin:1px 0;font-size:.93rem;line-height:1.4;transition:background .15s ease,color .15s ease;letter-spacing:-0.005em}
.nav-link:hover{background:var(--line-soft);color:var(--ink)}
.nav-link.active{background:var(--tint-soft);color:var(--tint);font-weight:600}
main{min-width:0;padding:32px clamp(20px,4.5vw,64px) 96px;max-width:1200px;margin:0 auto;width:100%}
.hero{display:flex;align-items:flex-end;justify-content:space-between;gap:22px;border-bottom:1px solid var(--line);padding:8px 0 22px;margin-bottom:8px;flex-wrap:wrap}
.hero-text{min-width:0;flex:1 1 320px}
.eyebrow{margin:0 0 8px;color:var(--muted);font-weight:600;text-transform:uppercase;letter-spacing:.06em;font-size:.7rem}
.hero h1{font-size:2.4rem;line-height:1.08;letter-spacing:-0.022em;margin:0;font-weight:700;color:var(--ink)}
.hero-meta{display:flex;gap:8px;flex:0 0 auto;flex-wrap:wrap}
.repo,.edit,.btn-ghost{border:1px solid var(--line);color:var(--text);text-decoration:none;border-radius:980px;padding:6px 14px;font-weight:500;font-size:.83rem;background:var(--paper);transition:border-color .15s ease,color .15s ease,background .15s ease}
.repo:hover,.edit:hover,.btn-ghost:hover{border-color:var(--ink);color:var(--ink)}
.edit{color:var(--muted)}
.home-hero{padding:24px 0 36px;margin-bottom:8px;border-bottom:1px solid var(--line)}
.home-hero h1{font-size:clamp(2.6rem,5vw,3.75rem);line-height:1.04;letter-spacing:-0.028em;margin:0 0 .35em;font-weight:700;color:var(--ink);background:linear-gradient(180deg,var(--ink) 0%,var(--ink) 70%,var(--muted) 130%);-webkit-background-clip:text;background-clip:text}
.home-hero .lede{font-size:1.18rem;line-height:1.55;color:var(--muted);margin:0 0 1.6em;max-width:60ch;letter-spacing:-0.005em}
.home-cta{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:0 0 22px}
.home-cta .btn{display:inline-flex;align-items:center;gap:7px;border-radius:980px;padding:10px 22px;font-weight:500;font-size:.95rem;text-decoration:none;transition:background .15s ease,border-color .15s ease,color .15s ease,transform .12s ease}
.home-cta .btn-primary{background:var(--tint);color:#fff;border:1px solid var(--tint)}
.home-cta .btn-primary:hover{background:var(--tint-hover);border-color:var(--tint-hover);color:#fff}
.home-cta .btn-ghost{padding:10px 22px}
.home-install{display:flex;align-items:center;gap:12px;background:var(--code-bg);color:var(--code-fg);border-radius:14px;padding:12px 12px 12px 18px;font:500 .9rem/1.2 ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;max-width:32em;border:1px solid #2c2c2e;letter-spacing:0}
.home-install .prompt{color:#86868b;user-select:none;flex:0 0 auto}
.home-install code{flex:1;background:transparent;border:0;color:var(--code-fg);font:inherit;padding:0;white-space:pre;overflow:hidden;text-overflow:ellipsis}
.home-install .copy{flex:0 0 auto;background:rgba(255,255,255,.10);color:var(--code-fg);border:1px solid rgba(255,255,255,.18);border-radius:980px;padding:5px 13px;font:500 .72rem/1 -apple-system,"SF Pro Text",sans-serif;cursor:pointer;transition:background .15s ease,border-color .15s ease;letter-spacing:.01em}
.home-install .copy:hover{background:rgba(255,255,255,.18)}
.home-install .copy.copied{background:var(--tint);border-color:var(--tint)}
.home-services{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0 22px}
.home-services span{display:inline-block;padding:4px 12px;border:1px solid var(--line);border-radius:980px;font-size:.78rem;color:var(--muted);background:var(--paper);font-weight:500;letter-spacing:0}
.muted{color:var(--muted);font-size:.92rem}
.muted a{color:var(--tint)}
.doc-grid{display:grid;grid-template-columns:minmax(0,1fr);gap:48px;margin-top:24px}
.doc-grid-home{margin-top:8px}
@media(min-width:1180px){.doc-grid{grid-template-columns:minmax(0,72ch) 220px;justify-content:start}.doc-grid-home{grid-template-columns:minmax(0,76ch);justify-content:start}}
.doc{min-width:0;max-width:72ch;overflow-wrap:break-word}
.doc-home{max-width:76ch}
.doc h1{font-size:2.6rem;line-height:1.05;letter-spacing:-0.024em;margin:0 0 .4em;font-weight:700;color:var(--ink)}
body:not(.home) .doc>h1:first-child{display:none}
.doc h2{font-size:1.55rem;line-height:1.18;margin:2.1em 0 .55em;font-weight:600;letter-spacing:-0.018em;color:var(--ink);position:relative}
.doc h3{font-size:1.18rem;margin:1.7em 0 .4em;position:relative;font-weight:600;color:var(--ink);letter-spacing:-0.012em}
.doc h4{font-size:1rem;margin:1.4em 0 .25em;color:var(--ink);position:relative;font-weight:600;letter-spacing:-0.008em}
.doc h2:first-child,.doc h3:first-child,.doc h4:first-child{margin-top:.2em}
.doc :is(h2,h3,h4) .anchor{position:absolute;left:-1.05em;top:0;color:var(--subtle);opacity:0;text-decoration:none;font-weight:400;padding-right:.3em;transition:opacity .12s ease,color .12s ease}
.doc :is(h2,h3,h4):hover .anchor{opacity:.7}
.doc :is(h2,h3,h4) .anchor:hover{opacity:1;color:var(--tint);text-decoration:none}
.doc p{margin:0 0 1.05em;letter-spacing:-0.003em}
.doc ul,.doc ol{padding-left:1.4rem;margin:0 0 1.15em}
.doc li{margin:.3em 0}
.doc li>p{margin:0 0 .4em}
.doc strong{font-weight:600;color:var(--ink)}
.doc em{font-style:italic}
.doc code{font-family:ui-monospace,"SF Mono","JetBrains Mono",Menlo,Consolas,monospace;font-size:.86em;background:var(--line-soft);border:1px solid var(--line);border-radius:6px;padding:.1em .4em;color:var(--code-inline-fg);letter-spacing:0}
.doc pre{position:relative;overflow:auto;background:var(--code-bg);color:var(--code-fg);border-radius:12px;padding:16px 20px;margin:1.4em 0;font-size:.86em;line-height:1.62;scrollbar-width:thin;scrollbar-color:#3a3a3c transparent;border:1px solid #2c2c2e;letter-spacing:0}
.doc pre::-webkit-scrollbar{height:8px;width:8px}
.doc pre::-webkit-scrollbar-thumb{background:#3a3a3c;border-radius:8px}
.doc pre code{display:block;background:transparent;border:0;color:inherit;padding:0;font-size:1em;white-space:pre}
.doc pre .hl-comment{color:var(--hl-comment);font-style:italic}
.doc pre .hl-keyword{color:var(--hl-keyword);font-weight:500}
.doc pre .hl-string{color:var(--hl-string)}
.doc pre .hl-number{color:var(--hl-number)}
.doc pre .hl-literal{color:var(--hl-literal);font-weight:500}
.doc pre .hl-key{color:var(--hl-key)}
.doc pre .hl-variable{color:var(--hl-variable)}
.doc pre .hl-option{color:var(--hl-option)}
.doc pre .copy{position:absolute;top:10px;right:10px;background:rgba(255,255,255,.08);color:var(--code-fg);border:1px solid rgba(255,255,255,.18);border-radius:980px;padding:4px 12px;font:500 .7rem/1 -apple-system,"SF Pro Text",sans-serif;cursor:pointer;opacity:0;transition:opacity .15s ease,background .15s ease,border-color .15s ease;letter-spacing:.01em}
.doc pre:hover .copy,.doc pre .copy:focus{opacity:1}
.doc pre .copy:hover{background:rgba(255,255,255,.16)}
.doc pre .copy.copied{background:var(--tint);border-color:var(--tint);opacity:1}
.doc blockquote{margin:1.4em 0;padding:14px 18px;border-left:3px solid var(--tint);background:var(--tint-soft);border-radius:0 12px 12px 0;color:var(--text)}
.doc blockquote p:last-child{margin-bottom:0}
.doc table{width:100%;border-collapse:collapse;margin:1.3em 0;font-size:.93em}
.doc th,.doc td{border-bottom:1px solid var(--line);padding:10px 12px;text-align:left;vertical-align:top;letter-spacing:-0.003em}
.doc th{font-weight:600;color:var(--ink);background:var(--line-soft);border-bottom:1px solid var(--line)}
.doc hr{border:0;border-top:1px solid var(--line);margin:2.4em 0}
.toc{position:sticky;top:24px;align-self:start;font-size:.86rem;padding-left:14px;border-left:1px solid var(--line);max-height:calc(100vh - 48px);overflow:auto;scrollbar-width:thin;scrollbar-color:var(--line) transparent}
.toc::-webkit-scrollbar{width:5px}
.toc::-webkit-scrollbar-thumb{background:var(--line);border-radius:5px}
.toc h2{font-size:.66rem;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin:0 0 10px;font-weight:600}
.toc a{display:block;color:var(--muted);text-decoration:none;padding:4px 0 4px 10px;line-height:1.35;border-left:2px solid transparent;margin-left:-12px;transition:color .12s ease,border-color .12s ease;letter-spacing:-0.003em}
.toc a:hover{color:var(--ink)}
.toc a.active{color:var(--tint);border-left-color:var(--tint);font-weight:500}
.toc-l3{padding-left:22px!important;font-size:.94em}
@media(max-width:1179px){.toc{display:none}}
.page-nav{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:56px;border-top:1px solid var(--line);padding-top:24px}
.page-nav>a{display:block;border:1px solid var(--line);background:var(--paper);border-radius:14px;padding:14px 18px;text-decoration:none;color:var(--text);transition:border-color .15s ease,transform .15s ease,box-shadow .15s ease,background-color .18s ease}
.page-nav>a:hover{border-color:var(--tint);box-shadow:var(--shadow-card);color:var(--ink)}
.page-nav small{display:block;color:var(--muted);font-size:.7rem;text-transform:uppercase;letter-spacing:.06em;margin-bottom:6px;font-weight:600}
.page-nav span{display:block;font-weight:600;line-height:1.3;color:var(--ink);letter-spacing:-0.008em}
.page-nav-prev{text-align:left}
.page-nav-next{text-align:right;grid-column:2}
.page-nav-prev:only-child{grid-column:1}
.nav-toggle{display:none;position:fixed;top:14px;right:14px;top:calc(14px + env(safe-area-inset-top, 0px));right:calc(14px + env(safe-area-inset-right, 0px));z-index:20;width:42px;height:42px;border-radius:50%;background:var(--paper);border:1px solid var(--line);color:var(--ink);cursor:pointer;padding:11px 10px;flex-direction:column;align-items:stretch;justify-content:space-between;box-shadow:var(--shadow-card)}
.nav-toggle span{display:block;width:100%;height:2px;flex:0 0 2px;background:currentColor;border-radius:2px;transition:transform .2s ease,opacity .2s ease}
.nav-toggle[aria-expanded="true"] span:nth-child(1){transform:translateY(8px) rotate(45deg)}
.nav-toggle[aria-expanded="true"] span:nth-child(2){opacity:0}
.nav-toggle[aria-expanded="true"] span:nth-child(3){transform:translateY(-8px) rotate(-45deg)}
@media(max-width:900px){
  .shell{display:block}
  .sidebar{position:fixed;inset:0 30% 0 0;max-width:320px;height:100vh;z-index:15;transform:translateX(-100%);transition:transform .25s ease,background-color .25s ease,border-color .25s ease;box-shadow:0 18px 40px rgba(0,0,0,.18);background:var(--paper);pointer-events:none}
  .sidebar.open{transform:translateX(0);pointer-events:auto}
  .nav-toggle{display:flex}
  main{padding:64px 18px 56px}
  .hero{padding-top:6px}
  .hero h1{font-size:1.85rem}
  .home-hero h1{font-size:2.55rem}
  .doc h1{font-size:2.15rem}
  .hero-meta{width:100%;justify-content:flex-start}
  .home-hero{padding-top:8px}
  .doc{padding:0}
  .doc-grid{margin-top:18px;gap:24px}
  .doc :is(h2,h3,h4) .anchor{display:none}
}
@media(max-width:520px){
  main{padding:60px 14px 48px}
  .doc pre{margin-left:-14px;margin-right:-14px;border-radius:0;border-left:0;border-right:0}
  .home-install{flex-wrap:wrap}
}
`;
}

export function js() {
  return `
const themeRoot=document.documentElement;
function applyTheme(mode){themeRoot.dataset.theme=mode;document.querySelectorAll('[data-theme-toggle]').forEach(b=>b.setAttribute('aria-pressed',mode==='dark'?'true':'false'))}
function storedTheme(){try{return localStorage.getItem('theme')}catch(e){return null}}
function persistTheme(mode){try{localStorage.setItem('theme',mode)}catch(e){}}
applyTheme(themeRoot.dataset.theme==='dark'?'dark':'light');
document.querySelectorAll('[data-theme-toggle]').forEach(btn=>{btn.addEventListener('click',()=>{const next=themeRoot.dataset.theme==='dark'?'light':'dark';applyTheme(next);persistTheme(next)})});
const systemDark=window.matchMedia&&matchMedia('(prefers-color-scheme: dark)');
function onSystemChange(e){if(storedTheme())return;applyTheme(e.matches?'dark':'light')}
if(systemDark){if(systemDark.addEventListener)systemDark.addEventListener('change',onSystemChange);else if(systemDark.addListener)systemDark.addListener(onSystemChange)}
const sidebar=document.querySelector('.sidebar');
const toggle=document.querySelector('.nav-toggle');
const mobileNav=window.matchMedia('(max-width: 900px)');
const sidebarFocusable='a[href],button,input,select,textarea,[tabindex]';
function setSidebarFocusable(enabled){
  sidebar?.querySelectorAll(sidebarFocusable).forEach((el)=>{
    if(enabled){
      if(el.dataset.sidebarTabindex!==undefined){
        if(el.dataset.sidebarTabindex)el.setAttribute('tabindex',el.dataset.sidebarTabindex);
        else el.removeAttribute('tabindex');
        delete el.dataset.sidebarTabindex;
      }
    }else if(el.dataset.sidebarTabindex===undefined){
      el.dataset.sidebarTabindex=el.getAttribute('tabindex')??'';
      el.setAttribute('tabindex','-1');
    }
  });
}
function setSidebarOpen(open){
  if(!sidebar||!toggle)return;
  sidebar.classList.toggle('open',open);
  toggle.setAttribute('aria-expanded',open?'true':'false');
  if(mobileNav.matches){
    sidebar.inert=!open;
    if(open)sidebar.removeAttribute('aria-hidden');
    else sidebar.setAttribute('aria-hidden','true');
    setSidebarFocusable(open);
  }else{
    sidebar.inert=false;
    sidebar.removeAttribute('aria-hidden');
    setSidebarFocusable(true);
  }
}
setSidebarOpen(false);
toggle?.addEventListener('click',()=>setSidebarOpen(!sidebar?.classList.contains('open')));
document.addEventListener('click',(e)=>{if(!sidebar?.classList.contains('open'))return;if(sidebar.contains(e.target)||toggle?.contains(e.target))return;setSidebarOpen(false)});
document.addEventListener('keydown',(e)=>{if(e.key==='Escape')setSidebarOpen(false)});
const syncSidebarForViewport=()=>setSidebarOpen(sidebar?.classList.contains('open')??false);
if(mobileNav.addEventListener)mobileNav.addEventListener('change',syncSidebarForViewport);
else mobileNav.addListener?.(syncSidebarForViewport);
const input=document.getElementById('doc-search');
input?.addEventListener('input',()=>{const q=input.value.trim().toLowerCase();document.querySelectorAll('nav section').forEach(sec=>{let any=false;sec.querySelectorAll('.nav-link').forEach(a=>{const m=!q||a.textContent.toLowerCase().includes(q);a.style.display=m?'block':'none';if(m)any=true});sec.style.display=any?'block':'none'})});
function attachCopy(target,getText){const btn=document.createElement('button');btn.type='button';btn.className='copy';btn.textContent='Copy';btn.addEventListener('click',async()=>{try{await navigator.clipboard.writeText(getText());btn.textContent='Copied';btn.classList.add('copied');setTimeout(()=>{btn.textContent='Copy';btn.classList.remove('copied')},1400)}catch{btn.textContent='Failed';setTimeout(()=>{btn.textContent='Copy'},1400)}});target.appendChild(btn)}
document.querySelectorAll('.doc pre').forEach(pre=>attachCopy(pre,()=>pre.querySelector('code')?.textContent??''));
document.querySelectorAll('.home-install').forEach(el=>attachCopy(el,()=>el.querySelector('code')?.textContent??''));
const tocLinks=document.querySelectorAll('.toc a');
if(tocLinks.length){const map=new Map();tocLinks.forEach(a=>{const id=a.getAttribute('href').slice(1);const el=document.getElementById(id);if(el)map.set(el,a)});const setActive=l=>{tocLinks.forEach(x=>x.classList.remove('active'));l.classList.add('active')};const obs=new IntersectionObserver(entries=>{const visible=entries.filter(e=>e.isIntersecting).sort((a,b)=>a.boundingClientRect.top-b.boundingClientRect.top);if(visible.length){const link=map.get(visible[0].target);if(link)setActive(link)}},{rootMargin:'-15% 0px -65% 0px',threshold:0});map.forEach((_,el)=>obs.observe(el))}
`;
}

export function preThemeScript() {
  return `(function(){var s;try{s=localStorage.getItem('theme')}catch(e){}var d=window.matchMedia&&matchMedia('(prefers-color-scheme: dark)').matches;document.documentElement.dataset.theme=s||(d?'dark':'light')})();`;
}

export function themeToggleHtml() {
  return `<button class="theme-toggle" type="button" aria-label="Toggle dark mode" aria-pressed="false" data-theme-toggle>
    <svg class="theme-icon-moon" viewBox="0 0 20 20" aria-hidden="true"><path d="M14.6 12.1A6.5 6.5 0 0 1 7.4 2.7a6.5 6.5 0 1 0 7.2 9.4z" fill="currentColor"/></svg>
    <svg class="theme-icon-sun" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="3.4" fill="currentColor"/><g stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><line x1="10" y1="2" x2="10" y2="4"/><line x1="10" y1="16" x2="10" y2="18"/><line x1="2" y1="10" x2="4" y2="10"/><line x1="16" y1="10" x2="18" y2="10"/><line x1="4.2" y1="4.2" x2="5.6" y2="5.6"/><line x1="14.4" y1="14.4" x2="15.8" y2="15.8"/><line x1="4.2" y1="15.8" x2="5.6" y2="14.4"/><line x1="14.4" y1="5.6" x2="15.8" y2="4.2"/></g></svg>
  </button>`;
}

export function brandMarkSvg() {
  return `<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path fill="currentColor" d="M12 3.2C6.9 3.2 2.8 6.5 2.8 10.6c0 2.4 1.4 4.5 3.6 5.9-.1 1-.4 2.2-1.1 3 1.7-.2 3.1-1 4-1.8 1 .3 1.8.4 2.7.4 5.1 0 9.2-3.3 9.2-7.5S17.1 3.2 12 3.2z"/></svg>`;
}

export function faviconSvg() {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="imsg">
<defs>
  <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0%" stop-color="#34c759"/>
    <stop offset="60%" stop-color="#0a84ff"/>
    <stop offset="100%" stop-color="#5e5ce6"/>
  </linearGradient>
</defs>
<rect width="64" height="64" rx="14" fill="url(#g)"/>
<path fill="#ffffff" d="M32 14.4c-9.9 0-17.9 6.4-17.9 14.3 0 4.7 2.8 8.8 7.1 11.5-.3 1.9-.9 4.1-2.1 5.8 3.4-.4 6.1-1.9 7.8-3.5 1.6.4 3.3.7 5.1.7 9.9 0 17.9-6.4 17.9-14.5S41.9 14.4 32 14.4z"/>
</svg>`;
}
