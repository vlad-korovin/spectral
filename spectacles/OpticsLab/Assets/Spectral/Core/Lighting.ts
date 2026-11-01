/** Portable area-light sampling shared by the runtime and host tests. */
export type LightingStyle='soft'|'spot'|'strip'|'window'|'halo';
export const LIGHTING_STYLES:readonly LightingStyle[]=['soft','spot','strip','window','halo'];

export interface ApertureSample {x:number;y:number;weight:number}

const equal=(points:readonly [number,number][]):readonly ApertureSample[]=>
 points.map(([x,y])=>({x,y,weight:1/points.length}));

/**
 * Deterministic, low-discrepancy source samples in a unit aperture. Every point
 * is traced at every wavelength; weights sum to one so a wider light does not
 * create energy from extra samples.
 */
const patterns:Record<LightingStyle,readonly ApertureSample[]>={
 spot:equal([[0,0]]),
 soft:equal([[0,0],[.62,0],[-.62,0],[0,.62],[0,-.62]]),
 strip:equal([[0,0],[-1,0],[1,0],[-.5,0],[.5,0]]),
 window:equal([[-.7,-.7],[.7,-.7],[-.7,.7],[.7,.7],[0,0]]),
 halo:equal([[1,0],[.707,.707],[0,1],[-.707,.707],[-1,0],[-.707,-.707],[0,-1],[.707,-.707]])
};

export const lightingPattern=(style:LightingStyle)=>patterns[style];
export const lightingLabel=(style:LightingStyle)=>({
 soft:'Soft area',spot:'Focused spot',strip:'Strip light',window:'Window light',halo:'Halo light'
}[style]);

/** Source aperture radius in centimetres; geometry is converted to metres before tracing. */
export const apertureRadiusCm=(style:LightingStyle)=>({soft:5.5,spot:.35,strip:7.5,window:5.5,halo:6.5}[style]);

/** Raster footprint radius in centimetres. The receiver position still comes from the ray intersection. */
export const causticRadiusCm=(style:LightingStyle)=>({soft:1.35,spot:.65,strip:.9,window:1.05,halo:.9}[style]);
