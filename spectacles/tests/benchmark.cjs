const {performance}=require('node:perf_hooks'),O=require('../.test-build/Optics'),M=require('../.test-build/Materials'),G=require('../.test-build/Lighting');
const table=M.samples('diamond','white',31);
for(const style of G.LIGHTING_STYLES){
 const pattern=G.lightingPattern(style),run=()=>{for(const aperture of pattern){const o=[-.4,aperture.y*.04+.03,aperture.x*.04+.025],d=O.unit(O.sub([0,.072,0],o));for(const s of table)O.trace(o,d,s.index);}};
 for(let i=0;i<400;i++)run();const times=[];for(let i=0;i<1000;i++){const start=performance.now();run();times.push(performance.now()-start);}times.sort((a,b)=>a-b);
 console.log(JSON.stringify({scope:'Host Node CPU optical core only; excludes Lens rendering, SIK, world query, networking and thermals',style,pathsPerUpdate:31*pattern.length,p50ms:times[499],p95ms:times[949],node:process.version,platform:process.platform,arch:process.arch}));
}
