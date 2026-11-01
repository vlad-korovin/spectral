import { Path, SurfaceEvent } from './Optics';
import { LIGHTS, MATERIALS, LightID, MaterialID } from './Materials';
import { LIGHTING_STYLES, LightingStyle } from './Lighting';
export type Command = { kind: 'material'; value: MaterialID } | { kind: 'light'; value: LightID } | { kind: 'style'; value: LightingStyle } | { kind: 'lesson'; value: boolean };
/** Final utterances only; exact commands with a wake phrase, no substring triggers. */
export function parseVoice(text: string, isFinal: boolean): Command | null {
    if (!isFinal) return null;
    const phrase = text.toLowerCase().replace(/[.,!?]/g, '').trim().replace(/\s+/g, ' ');
    const map: Record<string, Command> = {
        'spectral crown glass': { kind: 'material', value: 'crown' }, 'spectral diamond': { kind: 'material', value: 'diamond' },
        'spectral water': { kind: 'material', value: 'water' }, 'spectral sapphire': { kind: 'material', value: 'sapphire' },
        'spectral white light': { kind: 'light', value: 'white' }, 'spectral red light': { kind: 'light', value: 'red' },
        'spectral green light': { kind: 'light', value: 'green' }, 'spectral blue light': { kind: 'light', value: 'blue' },
        'spectral soft light': { kind: 'style', value: 'soft' }, 'spectral spot light': { kind: 'style', value: 'spot' },
        'spectral strip light': { kind: 'style', value: 'strip' }, 'spectral window light': { kind: 'style', value: 'window' },
        'spectral halo light': { kind: 'style', value: 'halo' },
        'spectral explain': { kind: 'lesson', value: true }, 'spectral hide equations': { kind: 'lesson', value: false }
    }; return Object.prototype.hasOwnProperty.call(map, phrase) ? map[phrase] : null;
}
export interface Settings { schema: 2; material: MaterialID; light: LightID; style: LightingStyle; lesson: boolean }
export const DEFAULT_SETTINGS: Settings = { schema: 2, material: 'crown', light: 'white', style: 'soft', lesson: false };
export function decodeSettings(raw: string): Settings | null {
    if (raw.length > 256) return null;
    try {
        const s = JSON.parse(raw);
        if (!s || MATERIALS.indexOf(s.material) < 0 || LIGHTS.indexOf(s.light) < 0 || typeof s.lesson !== 'boolean') return null;
        // Schema 1 sessions migrate to the iOS default light shape.
        if (s.schema === 1) return { schema: 2, material: s.material, light: s.light, style: 'soft', lesson: s.lesson };
        return s.schema === 2 && LIGHTING_STYLES.indexOf(s.style) >= 0 ? { schema: 2, material: s.material, light: s.light, style: s.style, lesson: s.lesson } : null;
    } catch { return null; }
}
const degrees = (r: number) => (r * 180 / Math.PI).toFixed(1) + '°';
export function equation(e: SurfaceEvent): string {
    const a = `θi ${degrees(e.incident)} · θt ${e.refracted === null ? 'TIR' : degrees(e.refracted)}`;
    const critical = e.critical === null ? 'No critical angle entering denser medium' : `θc = asin(nt/ni) = ${degrees(e.critical)}`;
    const snell = e.refracted === null ? 'No real transmitted angle' :
        `${(e.ni * Math.sin(e.incident)).toFixed(4)} = ${(e.nt * Math.sin(e.refracted)).toFixed(4)}`;
    return `${a}\nni sin θi = nt sin θt · ${snell}\n${critical}\nR = (rs² + rp²)/2 = ${(e.reflectance * 100).toFixed(1)}%\n
    rs=(ni cos θi − nt cos θt)/(ni cos θi + nt cos θt)\nrp=(nt cos θi − ni cos θt)/(nt cos θi + ni cos θt)`;
}
export function lessonText(path: Path, nm: number): string {
    if (path.status === 'miss') return 'Aim the light through the glass.';
    if (path.status === 'inside') return 'Move the source outside the glass.';
    const e = path.events[path.events.length - 1];
    return `${nm.toFixed(0)} nm · ${path.tir} internal reflections\n
    Entry θi ${degrees(path.events[0].incident)} · θt ${degrees(path.events[0].refracted!)}\n${path.escaped ? 'Exit' : 'Last interface'}:
    ${equation(e)}${path.status === 'budget' ? '\nPath budget reached · no exit shown' : ''}`;
}
/** Prevent late world-query callbacks from attaching old caustics to a new pose. */
export class RevisionGate {
    private revision = 0;
    next() { return ++this.revision; }
    accepts(revision: number) { return revision === this.revision; }
}
