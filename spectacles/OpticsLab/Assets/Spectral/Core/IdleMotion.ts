export type Offset3 = [number, number, number];

export type IdleMotionFrame = {
  offset: Offset3;
  cinema: number;
  yawDelta: number;
};

const ease = (value: number): number => {
  const x = Math.min(1, Math.max(0, value));
  return x * x * x * (x * (x * 6 - 15) + 10);
};

const mix = (a: number, b: number, t: number): number => a + (b - a) * t;

/** Platform-neutral copy of the iOS IdleCrystalMotion state machine. */
export class IdleCrystalMotion {
  private lastTime: number | null = null;
  private idleSince = 0;
  private startOffset: Offset3 = [0, 0, 0];
  private startCinema = 0;
  private landingSince: number | null = null;
  offset: Offset3 = [0, 0, 0];
  cinema = 0;

  get isLanding(): boolean { return this.landingSince !== null; }
  reset(time: number): void {
    this.lastTime = time; this.idleSince = time;
    this.startOffset = [...this.offset]; this.startCinema = this.cinema;
  }
  pause(time: number): void { this.landingSince = null; this.reset(time); }
  clear(time: number): void {
    this.offset = [0, 0, 0]; this.cinema = 0; this.landingSince = null; this.reset(time);
  }
  land(time: number): void { this.reset(time); this.landingSince = time; }

  step(time: number, enabled: boolean): IdleMotionFrame {
    if (!Number.isFinite(time)) {
      this.lastTime = null;
      return {offset: [...this.offset], cinema: this.cinema, yawDelta: 0};
    }
    const previous = this.lastTime;
    if (previous === null || time < previous || time - previous > 0.25) {
      if (this.landingSince !== null) this.landingSince = time;
      this.reset(time);
      return {offset: [...this.offset], cinema: this.cinema, yawDelta: 0};
    }
    if (this.landingSince !== null) {
      const blend = ease((time - this.landingSince) / 1.2);
      this.offset = this.startOffset.map(value => value * (1 - blend)) as Offset3;
      this.cinema = this.startCinema * (1 - blend);
      this.lastTime = time;
      if (blend >= 1) { this.landingSince = null; this.reset(time); }
      return {offset: [...this.offset], cinema: this.cinema, yawDelta: 0};
    }
    if (!enabled) {
      this.reset(time);
      return {offset: [...this.offset], cinema: this.cinema, yawDelta: 0};
    }
    this.lastTime = time;
    const t = Math.max(0, time - this.idleSince - 3);
    const blend = ease(t / 3.5);
    const hover: Offset3 = [
      0.008 * Math.sin(t * 0.55),
      0.12 + 0.012 * Math.sin(t * 0.85),
      0.006 * (Math.cos(t * 0.5) - 1)
    ];
    this.offset = this.startOffset.map((value, index) => mix(value, hover[index], blend)) as Offset3;
    this.cinema = mix(this.startCinema, 1, blend);
    const angle = (timestamp: number): number => {
      const phase = Math.max(0, timestamp - this.idleSince - 3);
      return 0.075 * (phase - 3 * (1 - Math.exp(-phase / 3)));
    };
    return {offset: [...this.offset], cinema: this.cinema, yawDelta: angle(time) - angle(previous)};
  }
}
