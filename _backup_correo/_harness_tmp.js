const fs=require('fs');
const mk=()=>new Proxy(function(){},{get:(t,k)=>{if(k===Symbol.toPrimitive)return()=>'';if(k==='innerHTML')return t._html||'';if(k==='classList')return {add(){},remove(){},toggle(){},contains(){return false}};if(k==='style')return {setProperty(){}};if(k==='dataset')return {};if(k in t)return t[k];return mk()},set:(t,k,v)=>{if(k==='innerHTML'){global.__HTML=v}t[k]=v;return true},apply:()=>mk()});
global.window=global;global.self=global;
global.document=new Proxy({},{get:(t,k)=>{if(k==='querySelector')return s=>s==='#app'||s==='#toast'?mk():null;if(k==='querySelectorAll')return()=>[];if(k==='getElementById')return()=>mk();if(k==='documentElement'||k==='body'||k==='head')return mk();if(k==='hidden')return false;if(k==='createElement')return()=>mk();return ()=>mk()}});
const store={};global.localStorage={getItem:k=>store[k]??null,setItem:(k,v)=>store[k]=String(v),removeItem:k=>delete store[k]};global.sessionStorage={...global.localStorage};
global.navigator={onLine:true,serviceWorker:undefined};global.location={href:'http://x/',search:'',hash:'',origin:'http://x'};
global.addEventListener=()=>{};global.matchMedia=()=>({matches:false});global.requestAnimationFrame=f=>0;global.setInterval=()=>0;
require('./question-bank.js');require('./teo-brain.js');require('./games.js');
const src=fs.readFileSync('./app.js','utf8');
try{(new Function(src+'\n;global.__app={state,render,studentActivities,teacherActivityPage,assistant,quiz};'))()}catch(e){console.log('LOADERR',e.message)}
const A=global.__app;if(!A){process.exit(1)}
const S=A.state;Object.assign(S,{authRole:'student',page:'teacher-activity',grade:'Primero',firstName:'Sam',studentActivities:[{id:'a1',title:'Sumas',subject:'Matemáticas',topic:'Suma',grade:'Primero',teacherName:'Profe',questions:[{question:'¿Cuánto es 3 + 2?',answers:['4','5','6'],correct:1}]},{id:'a2',title:'Colores',subject:'Inglés',topic:'Los colores',grade:'Primero',teacherName:'Profe',questions:[]}],openActivityId:'a1',teacherActivitiesDone:[]});
A.render();let h=global.__HTML||'';console.log('A1 inline:',/qz-inline/.test(h),/data-inline-answer="1"/.test(h),/data-start-teacher-quiz="a1"/.test(h),(h.match(/qz-q">([^<]*)/)||[])[1]);
S.openActivityId='a2';A.render();h=global.__HTML||'';console.log('A2 bank inline:',/qz-inline/.test(h),(h.match(/qz-q">([^<]*)/)||[])[1],/data-activity="Evaluación del tema"/.test(h));
S.page='assistant';A.render();h=global.__HTML||'';console.log('Teo:',/teo-chat/.test(h),(h.match(/data-teo-chip="([^"]*)"/g)||[]).slice(0,6).join(' | '));
