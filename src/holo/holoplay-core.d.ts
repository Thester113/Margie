/**
 * Minimal typings for `holoplay-core` (Looking Glass Factory), which ships
 * without any. We use two things: the driver websocket client (to read the
 * display's calibration from Looking Glass Bridge) and the lenticular
 * fragment shader generator.
 */
declare module "holoplay-core" {
  /** Talks to Bridge's HoloPlay driver at ws://localhost:11222/driver. */
  export class Client {
    constructor(
      initCallback?: (msg: unknown) => void,
      errCallback?: (err: unknown) => void,
      closeCallback?: (ev: unknown) => void,
      debug?: boolean,
      appId?: string,
      isGreedy?: boolean,
      oncloseBehavior?: string,
    );
    disconnect(): void;
    isConnected: boolean;
  }

  /**
   * Builds the GLSL ES 3.00 fragment shader that maps a quilt texture onto
   * the display's subpixels. `cfg` must expose the getters of
   * `LkgConfig` (see ./lkgConfig.ts).
   */
  export function Shader(cfg: unknown): string;
}
