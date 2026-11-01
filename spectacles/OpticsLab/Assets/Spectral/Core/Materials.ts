import {V,clamp} from './Optics';
export type MaterialID='crown'|'diamond'|'water'|'sapphire';
export const MATERIALS: readonly MaterialID[]=['crown','diamond','water','sapphire'];
// Sellmeier B and C (C already squared, micrometres²). Sources in docs/MATERIALS.md.
const curves:Record<MaterialID,{b:number[];c:number[];label:string}>={
 crown:{b:[1.03961212,.231792344,1.01046945],c:[.00600069867,.0200179144,103.560653],label:'Crown glass · N-BK7'},
 diamond:{b:[.3306,4.3356],c:[.175**2,.106**2],label:'Diamond'},
 water:{b:[.5684027565,.1726177391,.02086189578,.1130748688],c:[.005101829712,.01821153936,.02620722293,10.69792721],label:'Water · 20 °C · ideal boundary'},
 sapphire:{b:[1.4313493,.65054713,5.3414021],c:[.0726631**2,.1193242**2,18.028251**2],label:'Sapphire · ordinary ray only'}
};
export const materialLabel=(id:MaterialID)=>curves[id].label;
/** Sellmeier B/C coefficient arrays for the shader (unused slots are 0). */
export function coefficients(id:MaterialID):{b:number[];c:number[]}{
  const {b,c}=curves[id];return {b:[...b],c:[...c]};
}
export function ior(id:MaterialID,nm:number):number {
 if(!Number.isFinite(nm)||nm<420||nm>680)throw Error('Wavelength outside validated 420–680 nm domain');
 const {b,c}=curves[id],l=(nm*.001)**2;let n2=1;
 for(let i=0;i<b.length;i++)n2+=b[i]*l/(l-c[i]);return Math.sqrt(n2);
}
export const cauchy=(nm:number,a:number,b:number)=>a+b/(nm*.001)**2;
/** Same positive-primary display approximation as iPhone; NOT calibrated CIE XYZ. */
export function spectralWeight(nm:number):V {
 return [Math.exp(-.5*((nm-610)/39)**2),Math.exp(-.5*((nm-545)/32)**2),Math.exp(-.5*((nm-455)/25)**2)];
}
export type LightID='white'|'red'|'green'|'blue';
export const LIGHTS:readonly LightID[]=['white','red','green','blue'];
export function spectrum(id:LightID,nm:number):number {
 if(id==='white')return 1;return Math.exp(-.5*((nm-({red:640,green:540,blue:450}[id]))/9)**2);
}
export function samples(material:MaterialID,light:LightID,count=31) {
 if(!Number.isInteger(count)||count<2||count>31)throw Error('Expected 2–31 samples');
 const out=[];let norm:V=[0,0,0];
 for(let i=0;i<count;i++){const nm=420+i*260/(count-1),q=(i===0||i===count-1)?.5:1,w=spectralWeight(nm);norm=[norm[0]+w[0]*q,norm[1]+w[1]*q,norm[2]+w[2]*q];out.push({nm,index:ior(material,nm),weight:w,q});}
 return out.map(s=>({nm:s.nm,index:s.index,color:s.weight.map((v,i)=>v*s.q/norm[i]*spectrum(light,s.nm)) as V}));
}
